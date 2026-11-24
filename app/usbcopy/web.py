"""Http session helpers, authentication, and server-rendered pages."""

from __future__ import annotations

import json
import logging
import secrets
import shutil
import sqlite3
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from typing import Annotated, Any

from fastapi import APIRouter, Form, HTTPException, Request, Response, status
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from passlib.exc import UnknownHashError

from usbcopy import __version__
from usbcopy.auth import (
    DEFAULT_SESSION_MAX_AGE_SECONDS,
    Session,
    SessionManager,
    verify_password,
)
from usbcopy.config import Config
from usbcopy.db import open_db

logger = logging.getLogger(__name__)

SESSION_COOKIE = "usbcopy_session"
RUN_STATUS_LABELS = {
    "queued": ("Queued", "chip-info"),
    "running": ("Running", "chip-live"),
    "completed": ("Completed", "chip-ok"),
    "completed_with_errors": ("Completed with errors", "chip-warn"),
    "interrupted": ("Interrupted", "chip-idle"),
    "failed": ("Failed", "chip-bad"),
}
RECENT_RUNS_LIMIT = 8
QUEUE_LIMIT = 5
DRIVE_BLOCKS = 32
PROGRESS_BLOCKS = 40


def resolve_session(request: Request, session_manager: SessionManager) -> Session | None:
    """Return the signed session in the request cookie, or None when invalid."""
    token = request.cookies.get(SESSION_COOKIE)
    if not token:
        return None
    try:
        return session_manager.read(token)
    except (TypeError, ValueError):
        return None


def build_require_session(
    session_manager: SessionManager,
) -> Callable[[Request], Session]:
    """Return a dependency that resolves the signed session cookie."""

    def require_session(request: Request) -> Session:
        if not request.cookies.get(SESSION_COOKIE):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="authentication required",
            )
        session = resolve_session(request, session_manager)
        if session is None:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="invalid or expired session",
            )
        return session

    return require_session


def build_template_context(
    session_manager: SessionManager,
) -> Callable[[Request], dict[str, Any]]:
    """Return the Jinja context processor that exposes the session CSRF token."""

    def context(request: Request) -> dict[str, Any]:
        session = resolve_session(request, session_manager)
        return {
            "csrf_token": session.csrf if session is not None else "",
            "current_user": session.username if session is not None else "",
            "version": __version__,
        }

    return context


def set_session_cookie(response: Response, token: str, *, secure: bool) -> None:
    """Set the signed session cookie with HttpOnly and SameSite=Lax."""
    response.set_cookie(
        key=SESSION_COOKIE,
        value=token,
        max_age=DEFAULT_SESSION_MAX_AGE_SECONDS,
        path="/",
        httponly=True,
        samesite="lax",
        secure=secure,
    )


def clear_session_cookie(response: Response, *, secure: bool) -> None:
    """Expire the session cookie in a way that matches how it was set."""
    response.delete_cookie(
        key=SESSION_COOKIE,
        path="/",
        httponly=True,
        samesite="lax",
        secure=secure,
    )


def build_page_router(
    config: Config,
    session_manager: SessionManager,
    templates: Jinja2Templates,
) -> APIRouter:
    """Build the login, logout, and overview page routes.

    The overview is read-only: it renders database state and live free-space
    readings, and offers no controls beyond signing out.
    """
    router = APIRouter()

    @router.get("/", response_class=HTMLResponse)
    def overview(request: Request) -> Response:
        if resolve_session(request, session_manager) is None:
            return RedirectResponse("/login", status_code=status.HTTP_303_SEE_OTHER)
        try:
            conn = open_db(config.db_path)
            try:
                context = _overview_context(conn, config)
            finally:
                conn.close()
        except (OSError, sqlite3.Error) as exc:
            logger.exception("could not load overview data")
            context = _empty_overview_context(config, f"Live data unavailable: {exc}")
        return templates.TemplateResponse(request, "overview.html", context)

    @router.get("/login", response_class=HTMLResponse)
    def login_page(request: Request) -> Response:
        next_path = _safe_next(request.query_params.get("next"))
        if resolve_session(request, session_manager) is not None:
            return RedirectResponse(next_path, status_code=status.HTTP_303_SEE_OTHER)
        return templates.TemplateResponse(
            request,
            "login.html",
            {"error": None, "next_path": "" if next_path == "/" else next_path},
        )

    @router.post("/login", response_class=HTMLResponse)
    def login_submit(
        request: Request,
        username: Annotated[str, Form()] = "",
        password: Annotated[str, Form()] = "",
        next_url: Annotated[str, Form(alias="next")] = "",
    ) -> Response:
        username_ok = secrets.compare_digest(
            username.encode("utf-8", "surrogatepass"),
            config.username.encode("utf-8", "surrogatepass"),
        )
        password_ok = _password_matches(password, config.password_hash)
        if not (username_ok and password_ok):
            return _login_error(
                request,
                templates,
                "Invalid username or password.",
                next_url,
                status_code=status.HTTP_401_UNAUTHORIZED,
            )

        token = session_manager.create(config.username)
        if session_manager.read(token) is None:
            return _login_error(
                request,
                templates,
                "Could not create a session. Try again.",
                "",
                status_code=status.HTTP_400_BAD_REQUEST,
            )
        _record_login(config, request)
        response = RedirectResponse(
            _safe_next(next_url),
            status_code=status.HTTP_303_SEE_OTHER,
        )
        set_session_cookie(response, token, secure=request.url.scheme == "https")
        return response

    @router.post("/logout")
    def logout(request: Request) -> Response:
        response = RedirectResponse(
            "/login", status_code=status.HTTP_303_SEE_OTHER
        )
        clear_session_cookie(response, secure=request.url.scheme == "https")
        return response

    return router


def _login_error(
    request: Request,
    templates: Jinja2Templates,
    message: str,
    next_url: str,
    *,
    status_code: int,
) -> Response:
    return templates.TemplateResponse(
        request,
        "login.html",
        {"error": message, "next_path": _safe_next(next_url) if next_url else ""},
        status_code=status_code,
    )


def _password_matches(password: str, password_hash: str) -> bool:
    if not password:
        return False
    try:
        return verify_password(password, password_hash)
    except (UnknownHashError, ValueError):
        return False


def _record_login(config: Config, request: Request) -> None:
    """Record a successful page login without ever blocking it."""
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


def _safe_next(value: str | None) -> str:
    """Return a local path only, so login can never become an open redirect."""
    if not value or not value.startswith("/") or value.startswith("//"):
        return "/"
    if "\\" in value or "\r" in value or "\n" in value:
        return "/"
    return value


def _overview_context(conn: sqlite3.Connection, config: Config) -> dict[str, Any]:
    drives, drive_note = _connected_drives(conn)
    active = _active_run(conn)
    queue, queue_total = _queued_runs(conn)
    destinations = _destinations(config)
    runs = _recent_runs(conn)
    return {
        "now_text": datetime.now().astimezone().strftime("%a %d %b, %H:%M"),
        "page_sub": _page_sub(drives, active),
        "drives": drives,
        "drive_note": drive_note,
        "drive_chip": _drive_chip(drives),
        "kpis": _kpis(conn, destinations),
        "active": active,
        "queue": queue,
        "queue_total": queue_total,
        "queue_chip": (
            f"{queue_total} waiting" if queue_total else "Empty"
        ),
        "destinations": destinations,
        "destinations_chip": _destinations_chip(destinations),
        "runs": runs,
        "runs_chip": f"Latest {len(runs)}" if runs else "No history",
        "error": None,
    }


def _empty_overview_context(config: Config, error: str) -> dict[str, Any]:
    destinations = _destinations(config)
    return {
        "now_text": datetime.now().astimezone().strftime("%a %d %b, %H:%M"),
        "page_sub": "Live dashboard data is unavailable.",
        "drives": [],
        "drive_note": "Live data is unavailable.",
        "drive_chip": ("chip-neutral", "Unavailable"),
        "kpis": [
            {"label": "Copied today", "value": "—", "unit": "", "note": error},
            {"label": "Average write speed", "value": "—", "unit": "", "note": error},
            {"label": "Library free", "value": "—", "unit": "", "note": error},
            {"label": "Needs attention", "value": "—", "note": error, "attention": False},
        ],
        "active": None,
        "queue": [],
        "queue_total": 0,
        "queue_chip": "Unavailable",
        "destinations": destinations,
        "destinations_chip": _destinations_chip(destinations),
        "runs": [],
        "runs_chip": "Unavailable",
        "error": error,
    }


def _connected_drives(
    conn: sqlite3.Connection,
) -> tuple[list[dict[str, Any]], str]:
    rows = conn.execute(
        "SELECT d.*, "
        "(SELECT MAX(i.id) FROM inventories i WHERE i.drive_id = d.id) "
        "AS last_inventory_id "
        "FROM drives d WHERE d.present = 1 ORDER BY d.id"
    ).fetchall()
    drives: list[dict[str, Any]] = []
    inventory_notes: list[str] = []
    for row in rows:
        inventory = None
        if row["last_inventory_id"] is not None:
            inventory = conn.execute(
                "SELECT * FROM inventories WHERE id = ?",
                (row["last_inventory_id"],),
            ).fetchone()
        contents = "Not scanned"
        if inventory is not None and inventory["status"] == "complete":
            contents = (
                f"{int(inventory['total_files']):,} files, "
                f"{format_bytes(inventory['total_bytes'])}"
            )
            inventory_notes.append(f"Inventory {inventory['id']} is complete.")
        elif inventory is not None:
            contents = f"Inventory {inventory['status']}"
            inventory_notes.append(
                f"Inventory {inventory['id']} is {inventory['status']}."
            )

        label = (row["label"] or "").strip() or "Unnamed drive"
        sub_parts = [part for part in (row["serial"], row["fs_type"]) if part]
        sub = ", ".join(sub_parts) if sub_parts else "USB drive"
        usage = _disk_usage(row["mountpoint"])
        drives.append(
            {
                "label": label,
                "sub": sub,
                "facts": [
                    {"label": "Serial", "value": row["serial"] or "—", "mono": True},
                    {"label": "UUID", "value": row["uuid"], "mono": True},
                    {
                        "label": "Mounted at",
                        "value": row["mountpoint"] or "—",
                        "mono": True,
                    },
                    {"label": "Contents", "value": contents, "mono": False},
                ],
                "capacity": _capacity(usage, DRIVE_BLOCKS, current=False),
            }
        )

    if not drives:
        note = "Nothing is mounted right now."
    elif len(drives) == 1:
        note = inventory_notes[0] if inventory_notes else "No inventory built yet."
    else:
        note = f"{len(drives)} drives are connected."
    return drives, note


def _active_run(conn: sqlite3.Connection) -> dict[str, Any] | None:
    row = conn.execute(
        "SELECT r.*, d.label AS drive_label FROM runs r "
        "LEFT JOIN drives d ON d.id = r.drive_id "
        "WHERE r.status = 'running' ORDER BY r.id DESC LIMIT 1"
    ).fetchone()
    if row is None:
        return None
    item = conn.execute(
        "SELECT * FROM run_items WHERE run_id = ? AND status = 'running' "
        "ORDER BY id LIMIT 1",
        (row["id"],),
    ).fetchone()
    if item is None:
        item = conn.execute(
            "SELECT * FROM run_items WHERE run_id = ? "
            "AND status IN ('queued', 'pending') ORDER BY id LIMIT 1",
            (row["id"],),
        ).fetchone()
    name, file_name = _split_path(item["rel_path"] if item is not None else "")
    total_bytes = int(row["bytes_total"] or 0)
    done_bytes = int(row["bytes_done"] or 0)
    percent = _percent(done_bytes, total_bytes)
    files_total = int(row["files_total"] or 0)
    position = _item_position(conn, row["id"], item["id"]) if item is not None else 0
    started = _format_when(row["started_at"])
    if position and files_total:
        foot = (
            f"File {position} of {files_total} in this run. "
            "Duplicate checks run before each copy."
        )
    else:
        foot = (
            f"{files_total} files in this run. "
            "Duplicate checks run before each copy."
        )
    return {
        "run_id": row["id"],
        "destination": _destination_name(row["destination_key"]),
        "icon": _destination_icon(row["destination_key"]),
        "drive": row["drive_label"] or "Unknown drive",
        "name": name or "Preparing copy",
        "file": file_name or "Waiting for the first file",
        "percent": percent,
        "blocks": _blocks(percent, PROGRESS_BLOCKS, current=percent < 100),
        "done_text": format_bytes(done_bytes),
        "total_text": format_bytes(total_bytes),
        "remaining_text": format_bytes(max(total_bytes - done_bytes, 0)),
        "sub": (
            f"Run {row['id']}, started {started}."
            if started
            else f"Run {row['id']} is running."
        ),
        "foot": foot,
    }


def _queued_runs(conn: sqlite3.Connection) -> tuple[list[dict[str, Any]], int]:
    total = _scalar(conn, "SELECT COUNT(*) FROM runs WHERE status = 'queued'")
    rows = conn.execute(
        "SELECT r.*, d.label AS drive_label FROM runs r "
        "LEFT JOIN drives d ON d.id = r.drive_id "
        "WHERE r.status = 'queued' ORDER BY r.id LIMIT ?",
        (QUEUE_LIMIT,),
    ).fetchall()
    queue = []
    for row in rows:
        destination = _destination_name(row["destination_key"])
        queue.append(
            {
                "run_id": row["id"],
                "destination": destination,
                "icon": _destination_icon(row["destination_key"]),
                "drive": row["drive_label"] or "Unknown drive",
                "meta": (
                    f"{destination}, {int(row['files_total'])} files, "
                    f"{format_bytes(row['bytes_total'])}, "
                    f"{str(row['mode']).capitalize()} mode"
                ),
            }
        )
    return queue, total


def _destinations(config: Config) -> list[dict[str, Any]]:
    destinations = []
    for key, destination in config.destinations.items():
        name = key.replace("_", " ").title()
        usage = _disk_usage(destination.path)
        if usage is None:
            destinations.append(
                {
                    "name": name,
                    "path": str(destination.path),
                    "available": False,
                    "free_bytes": 0,
                    "free_text": "Space unavailable",
                    "used_text": "—",
                    "total_text": "—",
                    "percent": 0,
                }
            )
            continue
        percent = _percent(usage.used, usage.total)
        destinations.append(
            {
                "name": name,
                "path": str(destination.path),
                "available": True,
                "free_bytes": int(usage.free),
                "free_text": f"{format_bytes(usage.free)} free",
                "used_text": format_bytes(usage.used),
                "total_text": format_bytes(usage.total),
                "percent": percent,
            }
        )
    return destinations


def _recent_runs(conn: sqlite3.Connection) -> list[dict[str, Any]]:
    rows = conn.execute(
        "SELECT r.*, d.label AS drive_label FROM runs r "
        "LEFT JOIN drives d ON d.id = r.drive_id "
        "ORDER BY r.id DESC LIMIT ?",
        (RECENT_RUNS_LIMIT,),
    ).fetchall()
    runs = []
    for row in rows:
        label, chip = RUN_STATUS_LABELS.get(
            row["status"], (str(row["status"]).replace("_", " ").title(), "chip-neutral")
        )
        runs.append(
            {
                "run_id": row["id"],
                "drive": row["drive_label"] or "—",
                "destination": _destination_name(row["destination_key"]),
                "files": f"{int(row['files_total']):,}",
                "size": format_bytes(row["bytes_total"]),
                "duration": format_duration(row["started_at"], row["finished_at"]),
                "status": label,
                "chip": chip,
                "finished": _format_when(row["finished_at"] or row["started_at"])
                or "—",
            }
        )
    return runs


def _kpis(
    conn: sqlite3.Connection, destinations: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    cutoff = _iso_cutoff()
    copied = conn.execute(
        "SELECT COUNT(*), COALESCE(SUM(bytes_done), 0), "
        "COUNT(DISTINCT run_id) FROM run_items "
        "WHERE status = 'completed' AND finished_at >= ?",
        (cutoff,),
    ).fetchone()
    files = int(copied[0] or 0)
    copied_bytes = int(copied[1] or 0)
    copied_runs = int(copied[2] or 0)
    copied_note = (
        f"{format_bytes(copied_bytes)} across "
        f"{_count(copied_runs, 'completed run')} in the last 24 hours."
        if files
        else "Nothing copied in the last 24 hours."
    )

    speed_row = conn.execute(
        "SELECT COUNT(*), COALESCE(SUM(bytes_done), 0), "
        "COALESCE(SUM((julianday(finished_at) - julianday(started_at)) "
        "  * 86400.0), 0) "
        "FROM runs WHERE status IN ('completed', 'completed_with_errors') "
        "AND finished_at >= ? AND started_at IS NOT NULL AND finished_at IS NOT NULL",
        (cutoff,),
    ).fetchone()
    timed_runs = int(speed_row[0] or 0)
    timed_bytes = int(speed_row[1] or 0)
    timed_seconds = float(speed_row[2] or 0)
    speed = (
        round(timed_bytes / timed_seconds / 1_000_000)
        if timed_seconds >= 1 and timed_bytes > 0
        else None
    )

    available = [destination for destination in destinations if destination["available"]]
    free_total = sum(destination["free_bytes"] for destination in available)
    if available:
        free_value, free_unit = _split_size(free_total)
        free_note = " · ".join(
            f"{destination['name']} {destination['free_text']}"
            for destination in available
        )
    else:
        free_value, free_unit = "—", ""
        free_note = "Destination space is unavailable."

    failed_items = _scalar(
        conn,
        "SELECT COUNT(*) FROM run_items "
        "WHERE status = 'failed' AND COALESCE(finished_at, started_at) >= ?",
        (cutoff,),
    )
    interrupted = _scalar(
        conn,
        "SELECT COUNT(*) FROM runs WHERE status IN ('interrupted', 'failed') "
        "AND COALESCE(finished_at, started_at) >= ?",
        (cutoff,),
    )
    attention = failed_items + interrupted
    attention_note = (
        f"{_count(failed_items, 'failed file')}, "
        f"{_count(interrupted, 'interrupted or failed run')}."
        if attention
        else "No failed files or interrupted runs in the last 24 hours."
    )

    return [
        {
            "label": "Copied today",
            "value": f"{files:,}",
            "unit": "files",
            "note": copied_note,
        },
        {
            "label": "Average write speed",
            "value": f"{speed:,}" if speed is not None else "—",
            "unit": "MB/s" if speed is not None else "",
            "note": (
                f"Across {_count(timed_runs, 'completed run')} "
                "in the last 24 hours."
                if speed is not None
                else "No completed runs to measure in the last 24 hours."
            ),
        },
        {
            "label": "Library free",
            "value": free_value,
            "unit": free_unit,
            "note": free_note,
        },
        {
            "label": "Needs attention",
            "value": f"{attention:,}",
            "note": attention_note,
            "attention": attention > 0,
        },
    ]


def _drive_chip(drives: list[dict[str, Any]]) -> tuple[str, str]:
    if drives:
        return "chip-ok", "Mounted read-only"
    return "chip-neutral", "No drive"


def _destinations_chip(destinations: list[dict[str, Any]]) -> tuple[str, str]:
    available = sum(1 for destination in destinations if destination["available"])
    if destinations and available == len(destinations):
        return "chip-ok", "Writable"
    if available:
        return "chip-warn", "Partial"
    return "chip-bad", "Unavailable"


def _page_sub(drives: list[dict[str, Any]], active: dict[str, Any] | None) -> str:
    if active is not None:
        return (
            f"{active['drive']} is mounted. Run {active['run_id']} "
            f"is copying to {active['destination']}."
        )
    if len(drives) == 1:
        return f"{drives[0]['label']} is mounted and ready to review."
    if drives:
        return f"{len(drives)} drives are mounted and ready to review."
    return "No drive is connected. Plug in a USB drive to begin."


def _capacity(usage, blocks: int, *, current: bool) -> dict[str, Any] | None:
    if usage is None or usage.total <= 0:
        return None
    percent = _percent(usage.used, usage.total)
    return {
        "blocks": _blocks(percent, blocks, current=current),
        "label": f"Drive is {percent} percent full",
        "head_right": f"{format_bytes(usage.used)} of {format_bytes(usage.total)}",
        "used_text": f"{percent}% used",
        "free_text": f"{format_bytes(usage.free)} free",
    }


def _disk_usage(path: str | None):
    if not path:
        return None
    try:
        return shutil.disk_usage(path)
    except (OSError, ValueError):
        return None


def _blocks(percent: int, total: int, *, current: bool) -> list[str]:
    filled = max(0, min(total, int(percent * total / 100)))
    blocks = []
    for index in range(total):
        if index < filled:
            blocks.append("is-on")
        elif current and index == filled and percent < 100:
            blocks.append("is-current")
        else:
            blocks.append("")
    return blocks


def _percent(used: int, total: int) -> int:
    if total <= 0:
        return 0
    return max(0, min(100, round(used * 100 / total)))


def _item_position(conn: sqlite3.Connection, run_id: int, item_id: int) -> int:
    return _scalar(
        conn,
        "SELECT COUNT(*) FROM run_items WHERE run_id = ? AND id <= ?",
        (run_id, item_id),
    )


def _split_path(rel_path: str) -> tuple[str, str]:
    parts = [part for part in rel_path.replace("\\", "/").split("/") if part]
    if not parts:
        return "", ""
    if len(parts) == 1:
        return parts[0], parts[0]
    return parts[-2], parts[-1]


def _destination_name(key: str) -> str:
    return str(key).replace("_", " ").title()


def _destination_icon(key: str) -> str:
    return "i-series" if key == "series" else "i-film"


def _iso_cutoff(hours: int = 24) -> str:
    moment = datetime.now(UTC) - timedelta(hours=hours)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.000Z")


def _parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value))
    except ValueError:
        return None


def _format_when(value: str | None) -> str:
    moment = _parse_iso(value)
    if moment is None:
        return ""
    local = moment.astimezone()
    now = datetime.now().astimezone()
    if local.date() == now.date():
        return local.strftime("%H:%M")
    return local.strftime("%d %b %H:%M")


def format_duration(start: str | None, end: str | None) -> str:
    started = _parse_iso(start)
    finished = _parse_iso(end)
    if started is None or finished is None:
        return "—"
    seconds = max(int((finished - started).total_seconds()), 0)
    if seconds < 60:
        return f"{seconds}s"
    minutes, remaining = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours}h {minutes:02d}m"
    return f"{minutes}m {remaining:02d}s"


def format_bytes(value: int | None) -> str:
    if value is None:
        return "—"
    size = max(int(value), 0)
    if size == 0:
        return "0 B"
    amount = float(size)
    for unit in ("B", "KB", "MB", "GB", "TB", "PB"):
        if amount < 1000 or unit == "PB":
            if unit == "B":
                return f"{int(amount)} B"
            precision = 2 if unit in ("TB", "PB") else 1
            text = f"{amount:.{precision}f}".rstrip("0").rstrip(".")
            return f"{text} {unit}"
        amount /= 1000
    return f"{size} B"


def _split_size(value: int | None) -> tuple[str, str]:
    text = format_bytes(value)
    number, _, unit = text.rpartition(" ")
    if not number:
        return text, ""
    return number, unit


def _count(value: int, singular: str) -> str:
    return f"{value} {singular}" if value == 1 else f"{value} {singular}s"


def _scalar(
    conn: sqlite3.Connection, sql: str, params: tuple[Any, ...] = ()
) -> int:
    row = conn.execute(sql, params).fetchone()
    return int(row[0]) if row is not None else 0
