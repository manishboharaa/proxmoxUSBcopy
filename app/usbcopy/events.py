"""Drive event ingestion and startup reconciliation for usbcopy.

The host mount units write one JSON file per drive add/remove into a shared
spool directory (``/var/lib/usbcopy/events``). This module validates those files,
records drive and audit rows in SQLite, and watches the spool with inotify via
watchdog. The startup helpers are synchronous so recovery is deterministic;
the watcher only forwards event paths and leaves threading to the caller.
"""

from __future__ import annotations

import json
import logging
import os
import re
import sqlite3
from collections.abc import Callable
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Literal

from watchdog.events import FileSystemEvent, FileSystemEventHandler
from watchdog.observers import Observer

from usbcopy.runs import interrupt_active_run

EVENT_VERSION = 1

logger = logging.getLogger(__name__)

_DRIVE_REMOVED_REASON = "drive removed"
_NOW = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"
_UUID_PATTERN = re.compile(r"[A-Za-z0-9._-]+")
_REQUIRED_KEYS = (
    "version",
    "action",
    "uuid",
    "label",
    "serial",
    "device",
    "mountpoint",
    "fs_type",
    "ts",
)

DriveAddedCallback = Callable[[int, Path], None]


class EventError(ValueError):
    """Raised when an event file is missing, malformed, or unsupported."""


@dataclass(frozen=True)
class DriveEvent:
    """One processed host event.

    ``mountpoint`` is the path visible inside the CT (the host's
    ``ct_mountpoint`` when provided, else the host mount path);
    ``ct_mountpoint`` keeps the raw value for diagnostics.
    """

    action: Literal["add", "remove"]
    uuid: str
    label: str | None
    serial: str | None
    device: str
    mountpoint: str
    fs_type: str
    ts: str
    ct_mountpoint: str | None = None


def _is_valid_uuid(value: object) -> bool:
    """Return whether ``value`` is safe to use as a single path component."""
    return (
        isinstance(value, str)
        and value not in (".", "..")
        and _UUID_PATTERN.fullmatch(value) is not None
    )


def _require_text(payload: dict[str, object], key: str) -> str:
    value = payload[key]
    if not isinstance(value, str) or not value:
        raise EventError(f"event field {key!r} must be a non-empty string")
    return value


def _optional_text(payload: dict[str, object], key: str) -> str | None:
    value = payload.get(key)
    if value is not None and not isinstance(value, str):
        raise EventError(f"event field {key!r} must be a string or null")
    return value


def parse_event(path: Path) -> DriveEvent:
    """Read and validate one host event file.

    Raises ``EventError`` for unreadable files, invalid JSON, missing or
    wrongly typed fields, an unsupported ``version``, and unsafe UUIDs.
    Unknown extra keys are ignored so a newer host can add fields without
    breaking an older app.

    ``mountpoint`` resolves to the path visible inside the CT: the event's
    ``ct_mountpoint`` when present and non-blank, otherwise the host
    ``mountpoint`` written by an older host script.
    """
    path = Path(path)
    try:
        raw = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise EventError(f"cannot read event file {path}: {exc}") from exc
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise EventError(f"invalid event JSON in {path}: {exc}") from exc
    if not isinstance(payload, dict):
        raise EventError(f"event file {path} must contain a JSON object")

    missing = [key for key in _REQUIRED_KEYS if key not in payload]
    if missing:
        raise EventError(f"event file {path} is missing keys: {', '.join(missing)}")

    version = payload["version"]
    if isinstance(version, bool) or not isinstance(version, int):
        raise EventError(f"event version must be an integer in {path}: {version!r}")
    if version != EVENT_VERSION:
        raise EventError(f"unsupported event version in {path}: {version!r}")

    action = payload["action"]
    if action not in ("add", "remove") or not isinstance(action, str):
        raise EventError(
            f"event action must be 'add' or 'remove' in {path}: {action!r}"
        )

    uuid = payload["uuid"]
    if not _is_valid_uuid(uuid):
        raise EventError(f"invalid drive uuid in {path}: {uuid!r}")

    label = _optional_text(payload, "label")
    serial = _optional_text(payload, "serial")
    ct_mountpoint = _optional_text(payload, "ct_mountpoint")
    if ct_mountpoint is not None:
        ct_mountpoint = ct_mountpoint.strip() or None

    return DriveEvent(
        action=action,
        uuid=uuid,
        label=label,
        serial=serial,
        device=_require_text(payload, "device"),
        mountpoint=ct_mountpoint or _require_text(payload, "mountpoint"),
        fs_type=_require_text(payload, "fs_type"),
        ts=_require_text(payload, "ts"),
        ct_mountpoint=ct_mountpoint,
    )


def _upsert_drive(
    conn: sqlite3.Connection,
    *,
    uuid: str,
    label: str | None,
    serial: str | None,
    fs_type: str | None,
    mountpoint: str,
    present: int,
) -> int:
    """Insert or update one drive by uuid and return its id."""
    conn.execute(
        "INSERT INTO drives "
        "(uuid, label, serial, fs_type, mountpoint, present, last_seen) "
        f"VALUES (?, ?, ?, ?, ?, ?, {_NOW}) "
        "ON CONFLICT(uuid) DO UPDATE SET "
        "label = COALESCE(excluded.label, drives.label), "
        "serial = COALESCE(excluded.serial, drives.serial), "
        "fs_type = COALESCE(excluded.fs_type, drives.fs_type), "
        "mountpoint = excluded.mountpoint, "
        f"last_seen = {_NOW}, "
        "present = excluded.present",
        (uuid, label, serial, fs_type, mountpoint, present),
    )
    row = conn.execute("SELECT id FROM drives WHERE uuid = ?", (uuid,)).fetchone()
    if row is None:  # pragma: no cover - the upsert above guarantees a row
        raise EventError(f"drive {uuid!r} could not be recorded")
    return int(row[0])


def _record_event(
    conn: sqlite3.Connection,
    *,
    action: str,
    level: str,
    drive_id: int | None,
    payload: dict[str, object],
) -> None:
    conn.execute(
        "INSERT INTO events (level, action, drive_id, payload_json, processed) "
        "VALUES (?, ?, ?, ?, 1)",
        (level, action, drive_id, json.dumps(payload, sort_keys=True)),
    )


def apply_event(
    conn: sqlite3.Connection,
    event: DriveEvent,
    on_drive_added: DriveAddedCallback | None = None,
) -> int:
    """Persist one drive event and return the drive id.

    The drive row is upserted on ``uuid`` (keeping ``first_seen``) with
    ``present``, ``mountpoint``, and ``last_seen`` refreshed, and a processed
    ``events`` audit row is written. After the commit, ``on_drive_added`` is
    called for ``add`` events only, so the callback always observes committed
    state. ``remove`` events mark the drive absent and interrupt its queued or
    running runs with the reason ``drive removed``.
    """
    present = 1 if event.action == "add" else 0
    drive_id = _upsert_drive(
        conn,
        uuid=event.uuid,
        label=event.label,
        serial=event.serial,
        fs_type=event.fs_type,
        mountpoint=event.mountpoint,
        present=present,
    )
    _record_event(
        conn,
        action=event.action,
        level="info",
        drive_id=drive_id,
        payload=asdict(event),
    )
    conn.commit()

    if event.action == "add":
        if on_drive_added is not None:
            on_drive_added(drive_id, Path(event.mountpoint))
    else:
        interrupt_active_run(conn, drive_id, _DRIVE_REMOVED_REASON)
    return drive_id


def _quarantine(path: Path, spool_dir: Path) -> Path | None:
    """Move a malformed event into ``spool/bad/``; return its new path.

    Returns ``None`` when the source vanished between discovery and the move,
    which only happens when another process already handled or removed it.
    """
    bad_dir = spool_dir / "bad"
    bad_dir.mkdir(parents=True, exist_ok=True)
    target = bad_dir / path.name
    try:
        os.replace(path, target)
    except FileNotFoundError:
        return None
    return target


def process_pending(
    conn: sqlite3.Connection,
    spool_dir: Path,
    on_drive_added: DriveAddedCallback | None = None,
) -> int:
    """Apply every pending ``*.json`` event in the spool and return the count.

    Files are deleted only after a successful apply. Malformed files are moved
    to ``spool/bad/`` and logged as an ``error`` event row. An exception from
    ``apply_event`` (for example a failing drive-added callback) propagates and
    leaves that file in place for a later retry; already processed files stay
    deleted.
    """
    spool_dir = Path(spool_dir)
    if not spool_dir.is_dir():
        return 0

    processed = 0
    for path in sorted(spool_dir.glob("*.json")):
        if not path.is_file():
            continue
        try:
            event = parse_event(path)
        except EventError as exc:
            quarantined = _quarantine(path, spool_dir)
            if quarantined is not None:
                _record_event(
                    conn,
                    action="event_malformed",
                    level="error",
                    drive_id=None,
                    payload={
                        "file": path.name,
                        "quarantined": str(quarantined),
                        "error": str(exc),
                    },
                )
                conn.commit()
            continue
        apply_event(conn, event, on_drive_added)
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        processed += 1
    return processed


def scan_mounted(
    conn: sqlite3.Connection,
    mounts_root: Path,
    on_drive_added: DriveAddedCallback | None = None,
) -> list[str]:
    """Register drives already mounted at startup and return their uuids.

    Each safe direct child directory of ``mounts_root`` is an already mounted
    drive: it is upserted as present and passed to ``on_drive_added`` with its
    mountpoint, after the row is committed. Names that are not valid single
    path components are skipped. This is a positive-only reconciliation scan;
    absent directories do not clear other drives' ``present`` flag.
    """
    mounts_root = Path(mounts_root)
    if not mounts_root.is_dir():
        return []

    found: list[str] = []
    for entry in sorted(mounts_root.iterdir(), key=lambda path: path.name):
        if not entry.is_dir() or not _is_valid_uuid(entry.name):
            continue
        drive_id = _upsert_drive(
            conn,
            uuid=entry.name,
            label=None,
            serial=None,
            fs_type=None,
            mountpoint=str(entry),
            present=1,
        )
        conn.commit()
        if on_drive_added is not None:
            on_drive_added(drive_id, entry)
        found.append(entry.name)
    return found


class _SpoolEventHandler(FileSystemEventHandler):
    """Forward completed ``*.json`` spool files to the watcher callback."""

    def __init__(self, spool_dir: Path, on_event: Callable[[Path], None]) -> None:
        self._spool_dir = spool_dir
        self._on_event = on_event

    def _dispatch(self, path: str | bytes) -> None:
        candidate = Path(os.fsdecode(path))
        if candidate.parent != self._spool_dir or candidate.suffix != ".json":
            return
        self._on_event(candidate)

    def on_created(self, event: FileSystemEvent) -> None:
        if not event.is_directory:
            self._dispatch(event.src_path)

    def on_moved(self, event: FileSystemEvent) -> None:
        if not event.is_directory:
            self._dispatch(event.dest_path)


class EventSpoolWatcher:
    """Thin inotify wrapper over the event spool directory.

    ``on_event`` is called from the watchdog observer thread with the path of
    each newly created or atomically renamed ``*.json`` file; callers that need
    isolation or slow work must dispatch it themselves.
    """

    def __init__(self, spool_dir: Path, on_event: Callable[[Path], None]) -> None:
        self._spool_dir = Path(spool_dir).absolute()
        self._handler = _SpoolEventHandler(self._spool_dir, on_event)
        self._observer: Observer | None = None

    def start(self) -> None:
        if self._observer is not None:
            return
        if not self._spool_dir.is_dir():
            logger.warning(
                "event spool directory %s is not available; watcher not started",
                self._spool_dir,
            )
            return
        observer = Observer()
        observer.schedule(self._handler, str(self._spool_dir), recursive=False)
        observer.start()
        self._observer = observer

    def stop(self) -> None:
        observer = self._observer
        if observer is None:
            return
        self._observer = None
        observer.stop()
        observer.join()
