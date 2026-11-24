"""FastAPI application factory, startup recovery, and background wiring."""

from __future__ import annotations

import logging
import sqlite3
import threading
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from usbcopy import __version__
from usbcopy.api import build_api_router
from usbcopy.auth import SessionManager
from usbcopy.config import Config
from usbcopy.db import init_db, open_db
from usbcopy.events import (
    DriveEvent,
    EventError,
    EventSpoolWatcher,
    apply_event,
    parse_event,
    process_pending,
    scan_mounted,
)
from usbcopy.pipeline import handle_drive_added
from usbcopy.runs import recover_orphaned_runs
from usbcopy.worker import RunWorker

logger = logging.getLogger(__name__)

APP_DIR = Path(__file__).resolve().parent.parent


def cleanup_recorded_temps(conn: sqlite3.Connection) -> int:
    """Remove temporary copy files recorded in ``run_items.temp_path``.

    Only paths stored in the database are touched; unknown ``.part`` files in
    destination directories are left alone. Missing files are tolerated and
    uncommon filesystem errors are logged without aborting startup. Returns
    the number of files actually removed.
    """
    rows = conn.execute(
        "SELECT id, temp_path FROM run_items "
        "WHERE temp_path IS NOT NULL AND temp_path != ''"
    ).fetchall()
    removed = 0
    for row in rows:
        path = Path(row["temp_path"])
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        except (OSError, ValueError) as exc:
            logger.warning("could not remove recorded temp file %s: %s", path, exc)
            continue
        else:
            removed += 1
        conn.execute("UPDATE run_items SET temp_path = NULL WHERE id = ?", (row["id"],))
    if rows:
        conn.commit()
    return removed


def startup_recovery(
    conn: sqlite3.Connection,
    config: Config,
    *,
    enqueue_run: Callable[[int], None] | None = None,
) -> dict[str, int]:
    """Run deterministic startup recovery and return per-step counts.

    Recorded temporary files are removed, runs orphaned by a crash are marked
    interrupted, queued event files are applied, and already mounted drives are
    inventoried. Drive scans run synchronously on ``conn`` and each drive is
    scanned at most once per call so a pending add event plus its existing
    mountpoint do not create two inventories. A failed scan is logged and
    skipped instead of aborting startup.
    """
    temps = cleanup_recorded_temps(conn)
    orphans = recover_orphaned_runs(conn)
    on_drive_added = _startup_drive_added(conn, config, enqueue_run)
    events = process_pending(conn, config.events_dir, on_drive_added)
    drives = len(scan_mounted(conn, config.mounts_root, on_drive_added))
    return {
        "orphans": orphans,
        "temps": temps,
        "events": events,
        "drives": drives,
    }


def _startup_drive_added(
    conn: sqlite3.Connection,
    config: Config,
    enqueue_run: Callable[[int], None] | None,
) -> Callable[[int, Path], None]:
    """Build a synchronous, scan-once callback for startup recovery."""
    scanned: set[int] = set()

    def handle(drive_id: int, mountpoint: Path) -> None:
        if drive_id in scanned:
            return
        try:
            handle_drive_added(conn, drive_id, mountpoint, config, enqueue_run)
        except Exception:
            logger.exception(
                "startup scan failed for drive %s at %s", drive_id, mountpoint
            )
            return
        scanned.add(drive_id)

    return handle


class _LiveEventHandler:
    """Bridge watchdog callbacks to short-lived threads with own connections.

    Watchdog calls :meth:`dispatch` from the observer thread; the real work
    (parsing, persistence, inventory scan) happens in a daemon thread that
    opens and closes its own SQLite connection. Concurrent add events for the
    same drive are de-duplicated so only one scan runs at a time, and any
    failure is logged so a single bad event cannot stop the observer.
    """

    def __init__(
        self,
        config: Config,
        enqueue_run: Callable[[int], None] | None = None,
    ) -> None:
        self._config = config
        self._enqueue_run = enqueue_run
        self._lock = threading.Lock()
        self._inflight: set[int] = set()
        self._file_lock = threading.Lock()

    def dispatch(self, path: Path) -> None:
        try:
            thread = threading.Thread(
                target=self.handle,
                args=(Path(path),),
                name="usbcopy-event",
                daemon=True,
            )
            thread.start()
        except Exception:
            logger.exception("could not dispatch spool event %s", path)

    def drain(
        self,
        conn: sqlite3.Connection,
        spool_dir: Path,
        on_drive_added: Callable[[int, Path], None] | None = None,
    ) -> int:
        """Drain pending spool files under the shared file lock."""
        with self._file_lock:
            return process_pending(conn, spool_dir, on_drive_added)

    def handle(self, path: Path) -> None:
        conn = open_db(self._config.db_path)
        try:
            event, drive_id = self._apply_file(conn, path)
            if event is None:
                return
            if event.action == "add":
                self._drive_added(conn)(drive_id, Path(event.mountpoint))
        except Exception:
            logger.exception("could not process spool event %s", path)
        finally:
            conn.close()

    def _apply_file(
        self, conn: sqlite3.Connection, path: Path
    ) -> tuple[DriveEvent | None, int]:
        """Parse, apply, and delete one spool file while holding the file lock."""
        with self._file_lock:
            if not path.exists():
                return None, 0
            try:
                event = parse_event(path)
            except EventError as exc:
                logger.warning("ignoring malformed spool event %s: %s", path, exc)
                return None, 0
            drive_id = apply_event(conn, event)
            try:
                path.unlink()
            except FileNotFoundError:
                pass
            return event, drive_id

    def _drive_added(
        self, conn: sqlite3.Connection
    ) -> Callable[[int, Path], None]:
        def handle(drive_id: int, mountpoint: Path) -> None:
            with self._lock:
                if drive_id in self._inflight:
                    logger.info(
                        "drive %s is already being scanned; ignoring duplicate add",
                        drive_id,
                    )
                    return
                self._inflight.add(drive_id)
            try:
                handle_drive_added(
                    conn,
                    drive_id,
                    mountpoint,
                    self._config,
                    self._enqueue_run,
                )
            except Exception:
                logger.exception("drive-added handling failed for drive %s", drive_id)
            finally:
                with self._lock:
                    self._inflight.discard(drive_id)

        return handle


def _ensure_dir(path: Path) -> None:
    try:
        path.mkdir(parents=True, exist_ok=True)
    except OSError:
        logger.exception("cannot create directory %s", path)
        raise


def create_app(
    config: Config,
    *,
    start_background: bool = True,
    enqueue_run: Callable[[int], None] | None = None,
) -> FastAPI:
    """Build the dashboard application.

    The schema is always initialised during startup. With
    ``start_background=True`` startup recovery also runs synchronously and the
    copy worker and inotify spool watcher start for the lifetime of the app;
    the worker owns the enqueue callable passed to the API. With
    ``start_background=False`` no threads are started and an explicit
    ``enqueue_run`` may be injected for tests.
    """
    worker = _build_worker(config) if start_background else None
    api_enqueue = worker.enqueue if worker is not None else enqueue_run

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        _ensure_dir(config.db_path.parent)
        _ensure_dir(config.events_dir.parent)
        conn = open_db(config.db_path)
        watcher: EventSpoolWatcher | None = None
        try:
            init_db(conn)
            if start_background:
                assert worker is not None
                stats = startup_recovery(
                    conn, config, enqueue_run=worker.enqueue
                )
                worker.start()
                handler = _LiveEventHandler(config, worker.enqueue)
                watcher = EventSpoolWatcher(config.events_dir, handler.dispatch)
                app.state.watcher = watcher
                watcher.start()
                late = handler.drain(
                    conn,
                    config.events_dir,
                    _startup_drive_added(conn, config, worker.enqueue),
                )
                if late:
                    stats["events"] += late
                    logger.info(
                        "processed %s event(s) written during startup recovery",
                        late,
                    )
                app.state.startup_stats = stats
                logger.info("startup recovery complete: %s", stats)
        except BaseException:
            if watcher is not None:
                watcher.stop()
            if worker is not None:
                worker.stop()
            raise
        finally:
            conn.close()
        try:
            yield
        finally:
            if watcher is not None:
                watcher.stop()
            if worker is not None:
                worker.stop()
            app.state.watcher = None

    app = FastAPI(
        title="usbcopy",
        version=__version__,
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        lifespan=lifespan,
    )
    session_manager = SessionManager(config.session_secret)
    app.state.config = config
    app.state.session_manager = session_manager
    app.state.start_background = start_background
    app.state.enqueue_run = api_enqueue
    app.state.worker = worker
    app.state.watcher = None
    app.state.startup_stats = None
    app.state.templates = Jinja2Templates(directory=str(APP_DIR / "templates"))
    app.mount(
        "/static",
        StaticFiles(directory=str(APP_DIR / "static")),
        name="static",
    )
    app.include_router(
        build_api_router(config, session_manager, enqueue_run=api_enqueue)
    )

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        try:
            conn = open_db(config.db_path)
            try:
                row = conn.execute(
                    "SELECT value FROM settings WHERE key = 'schema_version'"
                ).fetchone()
            finally:
                conn.close()
        except (OSError, sqlite3.Error) as exc:
            raise HTTPException(
                status_code=503, detail="database unavailable"
            ) from exc
        if row is None:
            raise HTTPException(
                status_code=503, detail="database schema is not initialised"
            )
        return {"status": "ok"}

    return app


def _build_worker(config: Config) -> RunWorker:
    dest_roots = {
        key: destination.path for key, destination in config.destinations.items()
    }
    return RunWorker(config.db_path, config, dest_roots)
