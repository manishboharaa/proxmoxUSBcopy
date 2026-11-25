"""Serialised run execution and the background copy worker for usbcopy.

One run is executed at a time. ``execute_run`` drives the item state machine
and delegates every write of user data to :func:`usbcopy.copier.copy_file`.
The source is only ever read. ``RunWorker`` wraps that function in a single
daemon thread fed by a FIFO queue.
"""

from __future__ import annotations

import logging
import queue
import sqlite3
import threading
import time
from collections.abc import Callable
from pathlib import Path, PurePosixPath

from usbcopy.config import Config
from usbcopy.copier import CopyError, copy_file
from usbcopy.db import open_db
from usbcopy.runs import get_run

logger = logging.getLogger(__name__)

COMPLETED = "completed"
FAILED = "failed"
CANCELLED = "cancelled"

_BACKOFF_SECONDS = (2.0, 5.0, 10.0)
_PROGRESS_INTERVAL = 1.0
_NOW = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"


def sleep(seconds: float) -> None:
    """Sleep between retries.

    Kept as a module-level indirection so tests can patch this function (or
    ``time.sleep``) instead of waiting for the real backoff.
    """
    time.sleep(seconds)


def monotonic() -> float:
    """Monotonic clock used for progress throttling (patchable in tests)."""
    return time.monotonic()


class _RunProgress:
    """Persist run-level byte progress at most once per second.

    Item transitions pass ``force=True`` so every state change is recorded
    immediately; intermediate updates are coalesced.
    """

    def __init__(self, conn: sqlite3.Connection, run_id: int) -> None:
        self._conn = conn
        self._run_id = run_id
        self._last = monotonic()
        self._persisted = -1

    def persist(self, bytes_done: int, *, force: bool = False) -> None:
        now = monotonic()
        if not force and now - self._last < _PROGRESS_INTERVAL:
            return
        if bytes_done == self._persisted:
            return
        self._conn.execute(
            "UPDATE runs SET bytes_done = ? WHERE id = ?",
            (bytes_done, self._run_id),
        )
        self._conn.commit()
        self._persisted = bytes_done
        self._last = now


def execute_run(
    conn: sqlite3.Connection,
    run_id: int,
    config: Config,
    dest_roots: dict[str, Path],
    cancel_event: threading.Event,
) -> None:
    """Execute a queued run until it completes, fails, or is cancelled."""
    run = get_run(conn, run_id)
    if run is None:
        raise ValueError(f"unknown run: {run_id}")
    if run["status"] != "queued":
        logger.info("run %s is %s; nothing to execute", run_id, run["status"])
        return
    if not _mark_running(conn, run_id):
        logger.info("run %s was already claimed by another executor", run_id)
        return

    destination_key = run["destination_key"]
    dest_root = dest_roots.get(destination_key)
    source_root = _source_root(conn, run)
    progress = _RunProgress(conn, run_id)
    items = conn.execute(
        "SELECT * FROM run_items WHERE run_id = ? ORDER BY id", (run_id,)
    ).fetchall()

    bytes_done = 0
    failed_items = 0
    try:
        if dest_root is None:
            raise ValueError(f"destination {destination_key!r} is not available")
        dest_root = Path(dest_root)
        for index, item in enumerate(items):
            if cancel_event.is_set():
                _cancel_items(conn, items[index:])
                progress.persist(bytes_done, force=True)
                _finish_run(conn, run_id, "interrupted", "interrupted")
                return

            outcome, copied = _copy_item(
                conn,
                item,
                config,
                source_root,
                dest_root,
                cancel_event,
                # Bind the pre-item total now so the callback reports
                # base + in-flight bytes for exactly this item.
                progress_cb=lambda partial, base=bytes_done: progress.persist(
                    base + partial
                ),
            )
            if outcome == CANCELLED:
                _cancel_items(conn, items[index + 1 :])
                progress.persist(bytes_done, force=True)
                _finish_run(conn, run_id, "interrupted", "interrupted")
                return
            if outcome == FAILED:
                failed_items += 1
            else:
                bytes_done += copied
            progress.persist(bytes_done, force=True)

        status = "completed_with_errors" if failed_items else "completed"
        error = f"{failed_items} file(s) failed" if failed_items else None
        _finish_run(conn, run_id, status, error)
    except Exception as exc:
        try:
            conn.execute(
                "UPDATE run_items "
                f"SET status = 'failed', error = ?, finished_at = {_NOW} "
                "WHERE run_id = ? AND status = 'running'",
                (str(exc), run_id),
            )
            conn.commit()
            progress.persist(bytes_done, force=True)
            _finish_run(conn, run_id, "failed", str(exc))
        except Exception:
            logger.exception("could not record failure for run %s", run_id)
        raise


def _copy_item(
    conn: sqlite3.Connection,
    item: sqlite3.Row,
    config: Config,
    source_root: Path | None,
    dest_root: Path,
    cancel_event: threading.Event,
    progress_cb: Callable[[int], None] | None = None,
) -> tuple[str, int]:
    """Copy one item with retries; returns (outcome, bytes_copied).

    Every item transition is guarded on the item still being ``running``, so
    an external interruption can never be overwritten by this executor.

    ``progress_cb`` receives the partial byte count of the in-flight file
    after each copied chunk, so run-level progress also moves for a single
    large file.
    """
    item_id = int(item["id"])
    if not _start_item(conn, item_id):
        return CANCELLED, 0

    try:
        source = _source_path(str(item["rel_path"]), source_root)
        destination = _destination_path(dest_root, str(item["dest_rel_path"]))
    except ValueError as exc:
        if not _finish_item(conn, item_id, FAILED, error=str(exc)):
            return CANCELLED, 0
        return FAILED, 0

    try:
        destination.parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        if not _finish_item(
            conn,
            item_id,
            FAILED,
            error=f"cannot create destination directory: {exc}",
        ):
            return CANCELLED, 0
        return FAILED, 0

    attempts = max(1, int(config.retries))
    chunk_size = max(1, int(config.chunk_size_mb)) * 1024 * 1024
    last_error: Exception | None = None

    for attempt in range(1, attempts + 1):
        if cancel_event.is_set():
            _finish_item(
                conn,
                item_id,
                "interrupted",
                error=str(last_error) if last_error is not None else "cancelled",
            )
            return CANCELLED, 0

        cursor = conn.execute(
            "UPDATE run_items SET attempts = ? WHERE id = ? AND status = 'running'",
            (attempt, item_id),
        )
        conn.commit()
        if cursor.rowcount == 0:
            return CANCELLED, 0

        try:
            result = copy_file(
                source,
                destination,
                chunk_size=chunk_size,
                verify_sha256=config.verify_sha256,
                preserve_mtime=config.preserve_mtime,
                on_temp=lambda temp: _record_temp_path(conn, item_id, temp),
                on_progress=progress_cb,
            )
        except (CopyError, OSError) as exc:
            last_error = exc
            if cancel_event.is_set():
                _finish_item(conn, item_id, "interrupted", error=str(exc))
                return CANCELLED, 0
            if attempt == attempts:
                if not _finish_item(conn, item_id, FAILED, error=str(exc)):
                    return CANCELLED, 0
                return FAILED, 0
            sleep(_backoff(attempt))
        else:
            if not _finish_item(
                conn,
                item_id,
                COMPLETED,
                bytes_done=result.bytes_copied,
                sha256=result.sha256,
            ):
                return CANCELLED, 0
            return COMPLETED, int(result.bytes_copied)

    raise AssertionError("retry loop exited without an outcome")


def _backoff(failed_attempt: int) -> float:
    index = min(failed_attempt - 1, len(_BACKOFF_SECONDS) - 1)
    return _BACKOFF_SECONDS[index]


def _source_root(conn: sqlite3.Connection, run: sqlite3.Row) -> Path | None:
    inventory_id = run["inventory_id"]
    if inventory_id is not None:
        row = conn.execute(
            "SELECT root FROM inventories WHERE id = ?", (inventory_id,)
        ).fetchone()
        if row is not None and row[0]:
            return Path(row[0])
    drive_id = run["drive_id"]
    if drive_id is not None:
        row = conn.execute(
            "SELECT mountpoint FROM drives WHERE id = ?", (drive_id,)
        ).fetchone()
        if row is not None and row[0]:
            return Path(row[0])
    return None


def _source_path(rel_path: str, root: Path | None) -> Path:
    path = Path(rel_path)
    if path.is_absolute():
        return path
    if ".." in PurePosixPath(rel_path).parts:
        raise ValueError(f"unsafe source path: {rel_path!r}")
    if root is None:
        raise ValueError(
            f"cannot resolve source path {rel_path!r}: "
            "run has no inventory or drive mountpoint"
        )
    return root / path


def _destination_path(dest_root: Path, dest_rel: str) -> Path:
    rel = PurePosixPath(dest_rel)
    if not dest_rel or rel.is_absolute() or ".." in rel.parts:
        raise ValueError(f"unsafe destination path: {dest_rel!r}")
    return dest_root.joinpath(*rel.parts)


def _mark_running(conn: sqlite3.Connection, run_id: int) -> bool:
    """Claim a queued run; return False when another executor already did."""
    cursor = conn.execute(
        "UPDATE runs "
        f"SET status = 'running', started_at = {_NOW}, finished_at = NULL, "
        "error = NULL WHERE id = ? AND status = 'queued'",
        (run_id,),
    )
    conn.commit()
    return cursor.rowcount > 0


def _finish_run(
    conn: sqlite3.Connection,
    run_id: int,
    status: str,
    error: str | None,
) -> bool:
    """Record a terminal run status without overwriting an interrupted run."""
    cursor = conn.execute(
        f"UPDATE runs SET status = ?, finished_at = {_NOW}, error = ? "
        "WHERE id = ? AND status = 'running'",
        (status, error, run_id),
    )
    conn.commit()
    return cursor.rowcount > 0


def _start_item(conn: sqlite3.Connection, item_id: int) -> bool:
    """Move a pending item to running; return False when it is not startable."""
    cursor = conn.execute(
        "UPDATE run_items "
        f"SET status = 'running', started_at = {_NOW}, finished_at = NULL, "
        "error = NULL, temp_path = NULL "
        "WHERE id = ? AND status IN ('pending', 'queued')",
        (item_id,),
    )
    conn.commit()
    return cursor.rowcount > 0


def _record_temp_path(conn: sqlite3.Connection, item_id: int, temp_path: Path) -> None:
    """Record the copy engine's temporary file for startup cleanup."""
    conn.execute(
        "UPDATE run_items SET temp_path = ? WHERE id = ?",
        (str(temp_path), item_id),
    )
    conn.commit()


def _finish_item(
    conn: sqlite3.Connection,
    item_id: int,
    status: str,
    *,
    bytes_done: int | None = None,
    sha256: str | None = None,
    error: str | None = None,
) -> bool:
    """Record a terminal item status only while the item is still running."""
    assignments = ["status = ?", f"finished_at = {_NOW}", "error = ?"]
    values: list[object] = [status, error]
    if status == COMPLETED:
        assignments.append("temp_path = NULL")
    if bytes_done is not None:
        assignments.append("bytes_done = ?")
        values.append(bytes_done)
    if sha256 is not None:
        assignments.append("sha256 = ?")
        values.append(sha256)
    values.append(item_id)
    cursor = conn.execute(
        f"UPDATE run_items SET {', '.join(assignments)} "
        "WHERE id = ? AND status = 'running'",
        values,
    )
    conn.commit()
    return cursor.rowcount > 0


def _cancel_items(conn: sqlite3.Connection, items: list[sqlite3.Row]) -> None:
    for item in items:
        conn.execute(
            "UPDATE run_items "
            f"SET status = 'cancelled', finished_at = {_NOW} "
            "WHERE id = ? AND status IN ('pending', 'queued')",
            (item["id"],),
        )
    conn.commit()


class RunWorker:
    """Single-threaded FIFO worker that executes one run at a time."""

    def __init__(
        self,
        db_path: Path,
        config: Config,
        dest_roots: dict[str, Path],
        cancel_event: threading.Event | None = None,
    ) -> None:
        self.db_path = Path(db_path)
        self.config = config
        self.dest_roots = dict(dest_roots)
        self.cancel_event = (
            cancel_event if cancel_event is not None else threading.Event()
        )
        self._queue: queue.Queue[int] = queue.Queue()
        self._stopping = threading.Event()
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()
        self._run_lock = threading.Lock()

    def start(self) -> None:
        with self._lock:
            if self._thread is not None and self._thread.is_alive():
                return
            self._stopping.clear()
            self._thread = threading.Thread(
                target=self._loop, name="usbcopy-worker", daemon=True
            )
            self._thread.start()

    def stop(self) -> None:
        self._stopping.set()
        with self._lock:
            thread = self._thread
            self._thread = None
        if thread is not None:
            thread.join()

    def enqueue(self, run_id: int) -> None:
        self._queue.put(int(run_id))

    def run_once(self) -> bool:
        """Process the next queued run; return ``False`` when the queue is empty."""
        try:
            run_id = self._queue.get_nowait()
        except queue.Empty:
            return False
        self._process(run_id)
        return True

    def _loop(self) -> None:
        while not self._stopping.is_set():
            try:
                run_id = self._queue.get(timeout=0.1)
            except queue.Empty:
                continue
            if self._stopping.is_set():
                self._queue.put(run_id)
                break
            self._process(run_id)

    def _process(self, run_id: int) -> None:
        with self._run_lock:
            try:
                conn = open_db(self.db_path)
            except Exception:
                logger.exception(
                    "cannot open database %s for run %s", self.db_path, run_id
                )
                return
            try:
                execute_run(
                    conn,
                    run_id,
                    self.config,
                    self.dest_roots,
                    self.cancel_event,
                )
            except Exception:
                logger.exception("run %s failed", run_id)
            finally:
                conn.close()
