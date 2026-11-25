"""Http session helpers, authentication, and server-rendered pages."""

from __future__ import annotations

import json
import logging
import os
import secrets
import shutil
import sqlite3
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Annotated, Any

from fastapi import APIRouter, Form, HTTPException, Query, Request, Response, status
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from passlib.exc import UnknownHashError

from usbcopy import __version__
from usbcopy.auth import (
    DEFAULT_SESSION_MAX_AGE_SECONDS,
    MIN_PASSWORD_LENGTH,
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
ITEM_STATUS_LABELS = {
    "pending": ("Pending", "chip-neutral"),
    "queued": ("Queued", "chip-info"),
    "running": ("Copying", "chip-live"),
    "completed": ("Copied", "chip-ok"),
    "failed": ("Failed", "chip-bad"),
    "cancelled": ("Cancelled", "chip-idle"),
    "interrupted": ("Interrupted", "chip-idle"),
}
RUN_FILTERS = (
    ("all", "All"),
    ("completed", "Completed"),
    ("completed_with_errors", "Completed with errors"),
    ("failed", "Failed"),
    ("interrupted", "Interrupted"),
)
VALID_RUN_FILTERS = frozenset(key for key, _ in RUN_FILTERS)
RUNS_PAGE_LIMIT = 200
OUTCOME_STRIP_LIMIT = 160
DEFAULT_CONFIG_PATH = "/etc/usbcopy/config.toml"
CONFIG_PATH_ENV = "USBCOPY_CONFIG"
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

    @router.get("/import", response_class=HTMLResponse)
    def import_page(request: Request) -> Response:
        if resolve_session(request, session_manager) is None:
            return RedirectResponse("/login", status_code=status.HTTP_303_SEE_OTHER)
        try:
            conn = open_db(config.db_path)
            try:
                context = _import_context(conn, config)
            finally:
                conn.close()
        except (OSError, sqlite3.Error) as exc:
            logger.exception("could not load import page data")
            context = _empty_import_context(config, f"Live data unavailable: {exc}")
        return templates.TemplateResponse(request, "import.html", context)

    @router.get("/runs", response_class=HTMLResponse)
    def runs_page(
        request: Request,
        run_status: Annotated[str, Query(alias="status")] = "all",
    ) -> Response:
        if resolve_session(request, session_manager) is None:
            return RedirectResponse("/login", status_code=status.HTTP_303_SEE_OTHER)
        active = _normalise_run_filter(run_status)
        try:
            conn = open_db(config.db_path)
            try:
                context = _runs_context(conn, active)
            finally:
                conn.close()
        except (OSError, sqlite3.Error) as exc:
            logger.exception("could not load runs page data")
            context = _empty_runs_context(
                active, f"Live data unavailable: {exc}"
            )
        return templates.TemplateResponse(request, "runs.html", context)

    @router.get("/runs/{run_id}", response_class=HTMLResponse)
    def run_detail_page(request: Request, run_id: int) -> Response:
        if resolve_session(request, session_manager) is None:
            return RedirectResponse("/login", status_code=status.HTTP_303_SEE_OTHER)
        not_found = False
        try:
            conn = open_db(config.db_path)
            try:
                context = _run_detail_context(conn, config, run_id)
            finally:
                conn.close()
        except (OSError, sqlite3.Error) as exc:
            logger.exception("could not load run detail data")
            context = _empty_run_detail_context(f"Live data unavailable: {exc}")
        else:
            not_found = bool(context["not_found"])
        return templates.TemplateResponse(
            request,
            "run_detail.html",
            context,
            status_code=(
                status.HTTP_404_NOT_FOUND if not_found else status.HTTP_200_OK
            ),
        )

    @router.get("/drives", response_class=HTMLResponse)
    def drives_page(request: Request) -> Response:
        if resolve_session(request, session_manager) is None:
            return RedirectResponse("/login", status_code=status.HTTP_303_SEE_OTHER)
        try:
            conn = open_db(config.db_path)
            try:
                context = _drives_context(conn)
            finally:
                conn.close()
        except (OSError, sqlite3.Error) as exc:
            logger.exception("could not load drives page data")
            context = _empty_drives_context(f"Live data unavailable: {exc}")
        return templates.TemplateResponse(request, "drives.html", context)

    @router.get("/about", response_class=HTMLResponse)
    def about_page(request: Request) -> Response:
        if resolve_session(request, session_manager) is None:
            return RedirectResponse("/login", status_code=status.HTTP_303_SEE_OTHER)
        return templates.TemplateResponse(
            request, "about.html", _about_context(config)
        )

    @router.get("/account", response_class=HTMLResponse)
    def account_page(request: Request) -> Response:
        if resolve_session(request, session_manager) is None:
            return RedirectResponse("/login", status_code=status.HTTP_303_SEE_OTHER)
        return templates.TemplateResponse(
            request,
            "account.html",
            {"username": config.username, "min_password_length": MIN_PASSWORD_LENGTH},
        )

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


def _import_context(
    conn: sqlite3.Connection, config: Config
) -> dict[str, Any]:
    drives = _import_drives(conn)
    destinations = _import_destinations(config)
    initial_drive = next(
        (drive for drive in drives if drive["status"] == "complete"),
        drives[0] if drives else None,
    )
    initial_destination = next(
        (item for item in destinations if item["available"]),
        destinations[0] if destinations else None,
    )
    ready = initial_drive is not None and initial_drive["status"] == "complete"
    return {
        "drives": drives,
        "destinations": destinations,
        "initial_drive": initial_drive,
        "has_drives": bool(drives),
        "initial_drive_id": initial_drive["drive_id"] if initial_drive else "",
        "initial_inventory_id": (
            initial_drive["inventory_id"] if ready else ""
        ),
        "initial_destination": (
            initial_destination["key"] if initial_destination else ""
        ),
        "initial_destination_item": initial_destination,
        "initial_state": _import_state(initial_drive),
        "page_sub": (
            f"{initial_drive['label']} is ready to review."
            if initial_drive is not None
            else "Plug in a USB drive to review files for import."
        ),
        "error": None,
    }


def _empty_import_context(config: Config, error: str) -> dict[str, Any]:
    destinations = _import_destinations(config)
    return {
        "drives": [],
        "destinations": destinations,
        "initial_drive": None,
        "has_drives": False,
        "initial_drive_id": "",
        "initial_inventory_id": "",
        "initial_destination": (
            destinations[0]["key"] if destinations else ""
        ),
        "initial_destination_item": (
            destinations[0] if destinations else None
        ),
        "initial_state": {
            "kind": "error",
            "title": "Live data is unavailable.",
            "note": error,
        },
        "page_sub": "Import data is unavailable.",
        "error": error,
    }


def _import_drives(conn: sqlite3.Connection) -> list[dict[str, Any]]:
    rows = conn.execute(
        "SELECT d.*, "
        "(SELECT MAX(i.id) FROM inventories i WHERE i.drive_id = d.id) "
        "AS last_inventory_id "
        "FROM drives d WHERE d.present = 1 ORDER BY d.id"
    ).fetchall()
    drives: list[dict[str, Any]] = []
    for row in rows:
        inventory = None
        if row["last_inventory_id"] is not None:
            inventory = conn.execute(
                "SELECT * FROM inventories WHERE id = ?",
                (row["last_inventory_id"],),
            ).fetchone()
        status = inventory["status"] if inventory is not None else "none"
        if status == "complete":
            contents = (
                f"{int(inventory['total_files']):,} files, "
                f"{format_bytes(inventory['total_bytes'])}"
            )
        elif status == "scanning":
            contents = "Inventory scanning"
        elif status == "failed":
            contents = "Inventory failed"
        elif status == "none":
            contents = "Not inventoried"
        else:
            contents = f"Inventory {status}"
        drives.append(
            {
                "drive_id": row["id"],
                "label": (row["label"] or "").strip() or "Unnamed drive",
                "serial": row["serial"] or "",
                "mountpoint": row["mountpoint"] or "",
                "inventory_id": inventory["id"] if inventory is not None else "",
                "status": status,
                "contents": contents,
                "error": inventory["error"] if inventory is not None else None,
                "chip": _import_drive_chip(status),
            }
        )
    return drives


def _import_state(drive: dict[str, Any] | None) -> dict[str, str]:
    if drive is None:
        return {
            "kind": "no-drive",
            "title": "No drive connected.",
            "note": (
                "Plug in a USB drive; it is mounted read-only and "
                "inventoried automatically."
            ),
        }
    if drive["status"] == "complete":
        return {
            "kind": "ready",
            "title": "Loading the drive tree.",
            "note": "Folders open on demand; nothing is selected yet.",
        }
    if drive["status"] == "scanning":
        return {
            "kind": "scanning",
            "title": "Inventory is still scanning.",
            "note": "The file tree appears here when the scan finishes.",
        }
    if drive["status"] == "failed":
        return {
            "kind": "failed",
            "title": "Inventory failed.",
            "note": drive["error"] or (
                "The drive could not be read. Reconnect it to inventory it again."
            ),
        }
    if drive["status"] == "none":
        return {
            "kind": "none",
            "title": "No inventory yet.",
            "note": "The file tree appears after the drive is inventoried.",
        }
    return {
        "kind": "pending",
        "title": f"Inventory {drive['status']}.",
        "note": "The file tree appears when the inventory is complete.",
    }


def _import_drive_chip(status: str) -> tuple[str, str]:
    if status == "complete":
        return "chip-ok", "Ready"
    if status == "scanning":
        return "chip-info", "Scanning"
    if status == "failed":
        return "chip-bad", "Failed"
    return "chip-neutral", "Not ready"


def _import_destinations(config: Config) -> list[dict[str, Any]]:
    ordered = sorted(
        config.destinations.items(),
        key=lambda item: (item[0] != "movies", item[0]),
    )
    destinations = []
    for key, destination in ordered:
        usage = _disk_usage(destination.path)
        if usage is None:
            destinations.append(
                {
                    "key": key,
                    "name": _destination_name(key),
                    "path": str(destination.path),
                    "available": False,
                    "free_bytes": 0,
                    "total_bytes": 0,
                    "free_text": "Space unavailable",
                    "used_percent": 0,
                }
            )
            continue
        destinations.append(
            {
                "key": key,
                "name": _destination_name(key),
                "path": str(destination.path),
                "available": True,
                "free_bytes": int(usage.free),
                "total_bytes": int(usage.total),
                "free_text": f"{format_bytes(usage.free)} free",
                "used_percent": _percent(usage.used, usage.total),
            }
        )
    return destinations


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
    return [_run_row(row) for row in rows]


def _run_row(row: sqlite3.Row) -> dict[str, Any]:
    label, chip = RUN_STATUS_LABELS.get(
        row["status"],
        (str(row["status"]).replace("_", " ").title(), "chip-neutral"),
    )
    return {
        "run_id": row["id"],
        "raw_status": row["status"],
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


def _normalise_run_filter(value: str | None) -> str:
    """Return a supported run filter, falling back to all for junk input."""
    candidate = (value or "").strip().lower()
    return candidate if candidate in VALID_RUN_FILTERS else "all"


def _run_filters(active: str) -> list[dict[str, Any]]:
    return [
        {"key": key, "label": label, "active": key == active}
        for key, label in RUN_FILTERS
    ]


def _runs_sub(active: str) -> str:
    if active == "all":
        return (
            "Every import run, newest first. "
            "History stays after the source drive is gone."
        )
    return f"Showing {active.replace('_', ' ')} runs only."


def _runs_context(conn: sqlite3.Connection, active: str) -> dict[str, Any]:
    where = "" if active == "all" else " WHERE r.status = ?"
    params: tuple[Any, ...] = () if active == "all" else (active,)
    total = _scalar(conn, f"SELECT COUNT(*) FROM runs r{where}", params)
    rows = conn.execute(
        "SELECT r.*, d.label AS drive_label FROM runs r "
        "LEFT JOIN drives d ON d.id = r.drive_id"
        f"{where} ORDER BY r.id DESC LIMIT ?",
        (*params, RUNS_PAGE_LIMIT),
    ).fetchall()
    return {
        "filters": _run_filters(active),
        "active_filter": active,
        "runs": [_run_row(row) for row in rows],
        "total": total,
        "shown": len(rows),
        "page_sub": _runs_sub(active),
        "runs_chip": _count(total, "run") if total else "No runs",
        "error": None,
    }


def _empty_runs_context(active: str, error: str) -> dict[str, Any]:
    return {
        "filters": _run_filters(active),
        "active_filter": active,
        "runs": [],
        "total": 0,
        "shown": 0,
        "page_sub": "Live run history is unavailable.",
        "runs_chip": "Unavailable",
        "error": error,
    }


def _run_detail_context(
    conn: sqlite3.Connection, config: Config, run_id: int
) -> dict[str, Any]:
    row = conn.execute(
        "SELECT r.*, d.label AS drive_label, d.serial AS drive_serial "
        "FROM runs r LEFT JOIN drives d ON d.id = r.drive_id "
        "WHERE r.id = ?",
        (run_id,),
    ).fetchone()
    if row is None:
        return _empty_run_detail_context(None)

    destination = config.destinations.get(row["destination_key"])
    item_rows = conn.execute(
        "SELECT * FROM run_items WHERE run_id = ? ORDER BY id", (run_id,)
    ).fetchall()
    items = [_item_row(item, destination) for item in item_rows]
    counts = {item_status: 0 for item_status in ITEM_STATUS_LABELS}
    for item in items:
        counts[item["raw_status"]] = counts.get(item["raw_status"], 0) + 1

    label, chip = RUN_STATUS_LABELS.get(
        row["status"],
        (str(row["status"]).replace("_", " ").title(), "chip-neutral"),
    )
    destination_name = _destination_name(row["destination_key"])
    drive_label = row["drive_label"] or "Unknown drive"
    drive = (
        f"{drive_label} ({row['drive_serial']})"
        if row["drive_serial"]
        else drive_label
    )
    started = _format_moment(row["started_at"]) or "—"
    finished = _format_moment(row["finished_at"]) or "in progress"
    sub_started = _format_when(row["started_at"]) or "—"
    sub_finished = _format_when(row["finished_at"]) or "in progress"
    duration = format_duration(row["started_at"], row["finished_at"])
    if duration == "—" and row["status"] == "running":
        duration = "Running"
    files_total = max(int(row["files_total"] or 0), len(items))
    run = {
        "run_id": row["id"],
        "status": label,
        "chip": chip,
        "sub": (
            f"{destination_name}, {drive_label}. "
            f"Started {sub_started}, finished {sub_finished}."
        ),
        "drive": drive,
        "destination": destination_name,
        "destination_key": row["destination_key"],
        "destination_path": (
            str(destination.path) if destination is not None else "Not configured"
        ),
        "mode": str(row["mode"]).capitalize(),
        "inventory": (
            row["inventory_id"] if row["inventory_id"] is not None else "—"
        ),
        "files_total": files_total,
        "size": format_bytes(row["bytes_total"]),
        "copied_text": (
            f"{counts['completed']:,} of {files_total:,} files, "
            f"{format_bytes(row['bytes_done'])}"
        ),
        "issues": _issues_text(counts),
        "duration": duration,
        "started": started,
        "finished": finished,
        "error": row["error"] or "",
    }
    return {
        "run": run,
        "items": items,
        "not_found": False,
        "outcome": _outcome(items, counts),
        "error": None,
    }


def _empty_run_detail_context(error: str | None) -> dict[str, Any]:
    return {
        "run": None,
        "items": [],
        "not_found": error is None,
        "outcome": None,
        "error": error,
    }


def _item_row(row: sqlite3.Row, destination) -> dict[str, Any]:
    raw_status = row["status"]
    label, chip = ITEM_STATUS_LABELS.get(
        raw_status,
        (str(raw_status).replace("_", " ").title(), "chip-neutral"),
    )
    relative = row["dest_rel_path"] or ""
    if destination is not None and relative:
        destination_path = _join_destination(destination.path, relative)
    else:
        destination_path = relative or "—"
    if raw_status == "running" and row["started_at"]:
        duration = "Running"
    else:
        duration = format_duration(row["started_at"], row["finished_at"])
    return {
        "raw_status": raw_status,
        "status": label,
        "chip": chip,
        "source": row["rel_path"],
        "size": format_bytes(row["size"]),
        "progress": format_bytes(row["bytes_done"]),
        "destination": destination_path,
        "sha256": row["sha256"] or "—",
        "duration": duration,
        "attempts": int(row["attempts"] or 0),
        "error": row["error"] or "",
    }


def _issues_text(counts: dict[str, int]) -> str:
    parts = []
    if counts["failed"]:
        parts.append(_count(counts["failed"], "failed file"))
    if counts["cancelled"]:
        parts.append(_count(counts["cancelled"], "cancelled file"))
    if counts["interrupted"]:
        parts.append(_count(counts["interrupted"], "interrupted file"))
    return ", ".join(parts) if parts else "None"


def _outcome(
    items: list[dict[str, Any]], counts: dict[str, int]
) -> dict[str, Any]:
    cells = []
    for item in items[:OUTCOME_STRIP_LIMIT]:
        if item["raw_status"] == "completed":
            cells.append("is-ok")
        elif item["raw_status"] == "failed":
            cells.append("is-failed")
        else:
            cells.append("")
    legend = []
    for key, dot, text in (
        ("completed", "dot-ok", "copied"),
        ("failed", "dot-bad", "failed"),
        ("cancelled", "dot-idle", "cancelled"),
        ("interrupted", "dot-idle", "interrupted"),
    ):
        if counts[key]:
            legend.append({"dot": dot, "text": f"{counts[key]} {text}"})
    in_progress = counts["pending"] + counts["queued"] + counts["running"]
    if in_progress:
        legend.append({"dot": "dot-idle", "text": f"{in_progress} in progress"})
    texts = [entry["text"] for entry in legend]
    note = ""
    if len(items) > OUTCOME_STRIP_LIMIT:
        note = (
            f"The strip shows the first {OUTCOME_STRIP_LIMIT} "
            f"of {len(items):,} files."
        )
    return {
        "cells": cells,
        "legend": legend,
        "label": (
            f"Run outcome: {', '.join(texts)}" if texts else "Run outcome: no files"
        ),
        "note": note,
    }


def _join_destination(root: Path, rel_path: str) -> str:
    parts = [part for part in str(rel_path).replace("\\", "/").split("/") if part]
    return str(Path(root).joinpath(*parts)) if parts else str(root)


def _drives_context(conn: sqlite3.Connection) -> dict[str, Any]:
    rows = conn.execute(
        "SELECT d.*, "
        "(SELECT MAX(i.id) FROM inventories i WHERE i.drive_id = d.id) "
        "AS last_inventory_id, "
        "(SELECT COUNT(*) FROM runs r WHERE r.drive_id = d.id) AS run_count "
        "FROM drives d ORDER BY d.present DESC, d.last_seen DESC, d.id"
    ).fetchall()
    drives = [_drive_row(conn, row) for row in rows]
    present = sum(1 for drive in drives if drive["present"])
    total = len(drives)
    return {
        "drives": drives,
        "present": present,
        "page_sub": (
            f"{present} of {_count(total, 'drive')} present."
            if total
            else "Every drive that has been plugged in is listed here."
        ),
        "drives_chip": f"{present} present" if total else "No drives",
        "error": None,
    }


def _empty_drives_context(error: str) -> dict[str, Any]:
    return {
        "drives": [],
        "present": 0,
        "page_sub": "Live drive history is unavailable.",
        "drives_chip": "Unavailable",
        "error": error,
    }


def _drive_row(conn: sqlite3.Connection, row: sqlite3.Row) -> dict[str, Any]:
    inventory = None
    if row["last_inventory_id"] is not None:
        inventory = conn.execute(
            "SELECT * FROM inventories WHERE id = ?",
            (row["last_inventory_id"],),
        ).fetchone()
    if inventory is None:
        last_inventory = "Never inventoried"
    elif inventory["status"] == "complete":
        last_inventory = (
            f"Complete, {int(inventory['total_files']):,} files, "
            f"{format_bytes(inventory['total_bytes'])}"
        )
    else:
        last_inventory = str(inventory["status"]).capitalize()
    return {
        "drive_id": row["id"],
        "label": (row["label"] or "").strip() or "Unnamed drive",
        "mountpoint": row["mountpoint"] or "—",
        "serial": row["serial"] or "—",
        "uuid": row["uuid"],
        "fs_type": row["fs_type"] or "—",
        "first_seen": _format_moment(row["first_seen"]) or "—",
        "last_seen": _format_moment(row["last_seen"]) or "—",
        "last_inventory": last_inventory,
        "runs": int(row["run_count"] or 0),
        "present": bool(row["present"]),
        "status": "Present" if row["present"] else "Not present",
        "chip": "chip-ok" if row["present"] else "chip-idle",
    }


def _about_context(config: Config) -> dict[str, Any]:
    destinations = [
        {"name": _destination_name(key), "path": str(destination.path)}
        for key, destination in sorted(config.destinations.items())
    ]
    return {
        "application_facts": [
            {"label": "Version", "value": __version__, "mono": True},
            {"label": "License", "value": "MIT", "mono": False},
            {"label": "Config file", "value": _config_path_text(), "mono": True},
            {"label": "Database", "value": str(config.db_path), "mono": True},
            {"label": "Event spool", "value": str(config.events_dir), "mono": True},
            {"label": "Mounts root", "value": str(config.mounts_root), "mono": True},
            {
                "label": "Dashboard",
                "value": (
                    "Read-only; there are no settings, retry, delete, "
                    "or shell controls"
                ),
                "mono": False,
            },
        ],
        "destinations": destinations,
        "copy_facts": [
            {
                "label": "Default mode",
                "value": str(config.default_mode).capitalize(),
                "mono": False,
            },
            {
                "label": "Auto import",
                "value": "Enabled" if config.auto_enabled else "Disabled",
                "mono": False,
            },
            {
                "label": "Auto destination",
                "value": _destination_name(config.auto_destination),
                "mono": False,
            },
            {
                "label": "Verify SHA-256",
                "value": "Yes" if config.verify_sha256 else "No",
                "mono": False,
            },
            {
                "label": "Chunk size",
                "value": f"{config.chunk_size_mb} MB",
                "mono": False,
            },
            {
                "label": "Retries per file",
                "value": str(config.retries),
                "mono": False,
            },
            {
                "label": "Preserve mtime",
                "value": "Yes" if config.preserve_mtime else "No",
                "mono": False,
            },
            {
                "label": "Reconcile scan",
                "value": (
                    f"Every {config.reconcile_minutes} minutes"
                    if config.reconcile_minutes
                    else "Off"
                ),
                "mono": False,
            },
            {
                "label": "Skip hidden root folders",
                "value": "Yes" if config.skip_hidden_root_dirs else "No",
                "mono": False,
            },
            {
                "label": "Default source folder",
                "value": config.default_folder or "Whole drive",
                "mono": False,
            },
        ],
        "log_facts": [
            {
                "label": "Application",
                "value": "journalctl -u usbcopy -f",
                "mono": True,
            },
            {
                "label": "Mount units",
                "value": "journalctl -u usbcopy-mount@<device>.service -f",
                "mono": True,
            },
            {
                "label": "Since boot",
                "value": "journalctl -b -u usbcopy",
                "mono": True,
            },
        ],
        "log_note": (
            "Logs go straight to journald; there is no separate log file to "
            "rotate. Runtime paths above come from the loaded configuration, "
            "and the password hash and session secret are never rendered here."
        ),
        "error": None,
    }


def _config_path_text() -> str:
    override = os.environ.get(CONFIG_PATH_ENV, "").strip()
    return override or DEFAULT_CONFIG_PATH


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
    free_total = _free_bytes_unique_devices(available)
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


def _free_bytes_unique_devices(destinations: list[dict[str, Any]]) -> int:
    """Sum free bytes once per distinct filesystem.

    Destination folders usually share one physical disk, so a plain sum
    would report the same free space once per folder (three folders on one
    1 TB disk would read as ~3 TB). ``st_dev`` identifies the filesystem
    that actually holds each folder; a folder whose device cannot be
    stat'ed is still counted so nothing silently disappears.
    """
    total = 0
    seen_devices: set[int] = set()
    for destination in destinations:
        device = _stat_dev(str(destination["path"]))
        if device is not None:
            if device in seen_devices:
                continue
            seen_devices.add(device)
        total += int(destination["free_bytes"])
    return total


def _stat_dev(path: str | None) -> int | None:
    if not path:
        return None
    try:
        return os.stat(path).st_dev
    except OSError:
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


def _format_moment(value: str | None) -> str:
    moment = _parse_iso(value)
    if moment is None:
        return ""
    return moment.astimezone().strftime("%d %b %Y, %H:%M")


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
