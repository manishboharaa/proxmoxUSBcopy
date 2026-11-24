"""Read-only JSON API and SSE progress stream for the usbcopy dashboard.

Every read endpoint requires the signed session cookie. Login is public, and
logout is public and idempotent (it only expires the cookie). No route changes
configuration, starts work, or touches the filesystem.
"""

import json
import logging
import secrets
import sqlite3
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status
from fastapi.responses import StreamingResponse
from passlib.exc import UnknownHashError
from starlette.concurrency import run_in_threadpool

from usbcopy import __version__
from usbcopy.auth import SessionManager, verify_password
from usbcopy.config import Config
from usbcopy.db import open_db
from usbcopy.web import (
    build_require_session,
    clear_session_cookie,
    set_session_cookie,
)

logger = logging.getLogger(__name__)

TERMINAL_RUN_STATUSES = frozenset(
    {"completed", "completed_with_errors", "interrupted", "failed"}
)
_STREAM_END_STATUSES = TERMINAL_RUN_STATUSES | frozenset({"missing"})
RUN_STATUSES = frozenset(
    {
        "queued",
        "running",
        "completed",
        "completed_with_errors",
        "interrupted",
        "failed",
    }
)
ITEM_STATUSES = frozenset(
    {
        "pending",
        "queued",
        "running",
        "completed",
        "failed",
        "cancelled",
        "interrupted",
    }
)
EVENT_POLL_SECONDS = 1.0

_DRIVE_SQL = (
    "SELECT d.*, "
    "(SELECT COUNT(*) FROM inventories i1 WHERE i1.drive_id = d.id) "
    "AS inventory_count, "
    "(SELECT MAX(i2.id) FROM inventories i2 WHERE i2.drive_id = d.id) "
    "AS last_inventory_id "
    "FROM drives d"
)


def run_event_stream(
    conn: sqlite3.Connection,
    run_id: int,
    *,
    poll_interval: float = EVENT_POLL_SECONDS,
) -> Iterator[str]:
    """Yield SSE snapshots of ``run_id`` until it reaches a terminal status.

    The stream reads SQLite only; it never inspects the filesystem. A missing
    run produces a single error frame and ends rather than streaming forever.
    """
    while True:
        snapshot = _run_snapshot(conn, run_id)
        yield f"data: {json.dumps(snapshot, sort_keys=True)}\n\n"
        if snapshot["status"] in _STREAM_END_STATUSES:
            return
        time.sleep(poll_interval)


def build_api_router(config: Config, session_manager: SessionManager) -> APIRouter:
    """Build the ``/api`` router, public login plus session-protected routes."""
    require_session = build_require_session(session_manager)

    def get_conn() -> Iterator[sqlite3.Connection]:
        conn = open_db(config.db_path)
        try:
            yield conn
        finally:
            conn.close()

    router = APIRouter(prefix="/api")
    protected = APIRouter(dependencies=[Depends(require_session)])

    @router.post("/login")
    async def login(request: Request, response: Response) -> dict[str, str]:
        username, password = await _credentials(request)
        password_ok = False
        if isinstance(password, str) and password:
            password_ok = await run_in_threadpool(
                _password_matches, password, config.password_hash
            )
        username_ok = isinstance(username, str) and secrets.compare_digest(
            username.encode("utf-8", "surrogatepass"),
            config.username.encode("utf-8", "surrogatepass"),
        )
        if not (username_ok and password_ok):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="invalid username or password",
            )
        token = session_manager.create(config.username)
        session = session_manager.read(token)
        if session is None:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="could not create session",
            )
        _record_login_audit(config, request)
        set_session_cookie(response, token, secure=request.url.scheme == "https")
        return {"username": session.username, "csrf": session.csrf}

    @router.post("/logout")
    def logout(request: Request, response: Response) -> dict[str, bool]:
        clear_session_cookie(response, secure=request.url.scheme == "https")
        return {"ok": True}

    @protected.get("/status")
    def read_status(
        conn: Annotated[sqlite3.Connection, Depends(get_conn)],
    ) -> dict[str, Any]:
        return {
            "version": __version__,
            "mode": config.default_mode,
            "auto_enabled": config.auto_enabled,
            "drives_present": _scalar(
                conn, "SELECT COUNT(*) FROM drives WHERE present = 1"
            ),
            "active_runs": _scalar(
                conn,
                "SELECT COUNT(*) FROM runs WHERE status IN ('queued', 'running')",
            ),
            "runs_total": _scalar(conn, "SELECT COUNT(*) FROM runs"),
            "destinations": [
                {"key": destination.key, "path": str(destination.path)}
                for destination in config.destinations.values()
            ],
        }

    @protected.get("/drives")
    def list_drives(
        conn: Annotated[sqlite3.Connection, Depends(get_conn)],
    ) -> dict[str, Any]:
        rows = conn.execute(f"{_DRIVE_SQL} ORDER BY d.present DESC, d.id").fetchall()
        return {"drives": [_drive(row) for row in rows]}

    @protected.get("/drives/{drive_id}")
    def get_drive(
        drive_id: int, conn: Annotated[sqlite3.Connection, Depends(get_conn)]
    ) -> dict[str, Any]:
        row = conn.execute(f"{_DRIVE_SQL} WHERE d.id = ?", (drive_id,)).fetchone()
        if row is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="drive not found"
            )
        drive = _drive(row)
        drive["inventories"] = [
            dict(inventory)
            for inventory in conn.execute(
                "SELECT * FROM inventories WHERE drive_id = ? ORDER BY id DESC",
                (drive_id,),
            )
        ]
        return drive

    @protected.get("/inventories/{inventory_id}")
    def get_inventory_tree(
        inventory_id: int,
        conn: Annotated[sqlite3.Connection, Depends(get_conn)],
        parent: str = "",
        limit: int = Query(200, ge=1, le=1000),
        offset: int = Query(0, ge=0),
    ) -> dict[str, Any]:
        inventory = conn.execute(
            "SELECT * FROM inventories WHERE id = ?", (inventory_id,)
        ).fetchone()
        if inventory is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="inventory not found",
            )
        parent_path = parent.strip("/")
        total = _scalar(
            conn,
            "SELECT COUNT(*) FROM inventory_entries "
            "WHERE inventory_id = ? AND parent_path = ?",
            (inventory_id, parent_path),
        )
        rows = conn.execute(
            "SELECT * FROM inventory_entries "
            "WHERE inventory_id = ? AND parent_path = ? "
            "ORDER BY is_dir DESC, rel_path LIMIT ? OFFSET ?",
            (inventory_id, parent_path, limit, offset),
        ).fetchall()
        return {
            "inventory": dict(inventory),
            "parent": parent_path,
            "entries": [_entry(row) for row in rows],
            "total": total,
            "limit": limit,
            "offset": offset,
        }

    @protected.get("/runs")
    def list_runs(
        conn: Annotated[sqlite3.Connection, Depends(get_conn)],
        run_status: str | None = Query(None, alias="status"),
        limit: int = Query(100, ge=1, le=500),
        offset: int = Query(0, ge=0),
    ) -> dict[str, Any]:
        clauses: list[str] = []
        params: list[Any] = []
        if run_status is not None:
            if run_status not in RUN_STATUSES:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                    detail=f"invalid run status: {run_status}",
                )
            clauses.append("status = ?")
            params.append(run_status)
        where = f" WHERE {' AND '.join(clauses)}" if clauses else ""
        total = _scalar(conn, f"SELECT COUNT(*) FROM runs{where}", tuple(params))
        rows = conn.execute(
            f"SELECT * FROM runs{where} ORDER BY id DESC LIMIT ? OFFSET ?",
            (*params, limit, offset),
        ).fetchall()
        return {"runs": [dict(row) for row in rows], "total": total}

    @protected.get("/runs/{run_id}")
    def get_run_detail(
        run_id: int, conn: Annotated[sqlite3.Connection, Depends(get_conn)]
    ) -> dict[str, Any]:
        row = conn.execute("SELECT * FROM runs WHERE id = ?", (run_id,)).fetchone()
        if row is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="run not found"
            )
        run = dict(row)
        run["item_counts"] = _item_counts(conn, run_id)
        return run

    @protected.get("/runs/{run_id}/items")
    def get_run_items(
        run_id: int,
        conn: Annotated[sqlite3.Connection, Depends(get_conn)],
        item_status: str | None = Query(None, alias="status"),
    ) -> dict[str, Any]:
        if (
            conn.execute("SELECT 1 FROM runs WHERE id = ?", (run_id,)).fetchone()
            is None
        ):
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="run not found"
            )
        clauses = ["run_id = ?"]
        params: list[Any] = [run_id]
        if item_status is not None:
            if item_status not in ITEM_STATUSES:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                    detail=f"invalid item status: {item_status}",
                )
            clauses.append("status = ?")
            params.append(item_status)
        rows = conn.execute(
            f"SELECT * FROM run_items WHERE {' AND '.join(clauses)} ORDER BY id",
            tuple(params),
        ).fetchall()
        return {"items": [dict(row) for row in rows], "total": len(rows)}

    @protected.get("/events/stream")
    def events_stream(run_id: int = Query(..., ge=1)) -> StreamingResponse:
        def frames() -> Iterator[str]:
            conn = _open_stream_connection(config.db_path)
            try:
                yield from run_event_stream(conn, run_id)
            finally:
                conn.close()

        return StreamingResponse(
            frames(),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )

    router.include_router(protected)
    return router


def _record_login_audit(config: Config, request: Request) -> None:
    """Record a successful login without ever blocking it.

    The audit row is best effort: a missing schema, an unavailable database,
    or any other SQLite error is logged as a warning and the caller still
    issues the session.
    """
    client_host = request.client.host if request.client is not None else None
    detail = json.dumps({"client": client_host}, sort_keys=True)
    try:
        conn = open_db(config.db_path)
        try:
            conn.execute(
                "INSERT INTO audit (actor, action, detail_json) VALUES (?, 'login', ?)",
                (config.username, detail),
            )
            conn.commit()
        finally:
            conn.close()
    except (OSError, sqlite3.Error) as exc:
        logger.warning("could not record login audit: %s", exc)


def _password_matches(password: str, password_hash: str) -> bool:
    try:
        return verify_password(password, password_hash)
    except (UnknownHashError, ValueError):
        return False


async def _credentials(request: Request) -> tuple[object, object]:
    """Read credentials from a JSON or form-encoded login body."""
    content_type = request.headers.get("content-type", "").lower()
    payload: object
    if "application/json" in content_type:
        try:
            payload = json.loads(await request.body())
        except (UnicodeDecodeError, ValueError):
            return None, None
    else:
        payload = dict(await request.form())
    if not isinstance(payload, dict):
        return None, None
    return payload.get("username"), payload.get("password")


def _open_stream_connection(db_path: Path) -> sqlite3.Connection:
    """Open the long-lived SSE connection for cross-thread generator resumes.

    Starlette iterates synchronous streaming generators in a worker thread
    pool, so a stream may resume on a different thread than it started on.
    Frames are produced one at a time, so the connection is never used
    concurrently; disabling sqlite's same-thread check prevents spurious
    ``ProgrammingError`` failures on live streams.
    """
    conn = sqlite3.connect(Path(db_path), check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout = 5000")
    return conn


def _run_snapshot(conn: sqlite3.Connection, run_id: int) -> dict[str, Any]:
    row = conn.execute("SELECT * FROM runs WHERE id = ?", (run_id,)).fetchone()
    if row is None:
        return {"run_id": run_id, "status": "missing", "error": "run not found"}
    snapshot = dict(row)
    snapshot["run_id"] = snapshot.pop("id")
    snapshot["item_counts"] = _item_counts(conn, run_id)
    snapshot["remaining_bytes"] = max(
        int(snapshot["bytes_total"]) - int(snapshot["bytes_done"]), 0
    )
    return snapshot


def _item_counts(conn: sqlite3.Connection, run_id: int) -> dict[str, int]:
    counts = {item_status: 0 for item_status in ITEM_STATUSES}
    for row in conn.execute(
        "SELECT status, COUNT(*) AS count FROM run_items "
        "WHERE run_id = ? GROUP BY status",
        (run_id,),
    ):
        if row["status"] in counts:
            counts[row["status"]] = int(row["count"])
    return counts


def _scalar(conn: sqlite3.Connection, sql: str, params: tuple[Any, ...] = ()) -> int:
    row = conn.execute(sql, params).fetchone()
    return int(row[0]) if row is not None else 0


def _drive(row: sqlite3.Row) -> dict[str, Any]:
    drive = dict(row)
    drive["present"] = bool(drive["present"])
    return drive


def _entry(row: sqlite3.Row) -> dict[str, Any]:
    entry = dict(row)
    entry["is_dir"] = bool(entry["is_dir"])
    return entry
