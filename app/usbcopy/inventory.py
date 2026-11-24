"""Metadata-only inventory scanner for usbcopy.

The scanner never writes to the source tree: it only lists directories,
reads entry metadata, and records rows in SQLite. Symbolic links are not
followed and are not recorded.
"""

from __future__ import annotations

import os
import sqlite3
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from usbcopy.media import classify

SYSTEM_DIRS: frozenset[str] = frozenset(
    {
        "System Volume Information",
        "$RECYCLE.BIN",
        ".Trashes",
        "lost+found",
        ".Spotlight-V100",
        ".fseventsd",
    }
)

PROGRESS_INTERVAL = 500

_NOW = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"

_INSERT_ENTRY = """
INSERT INTO inventory_entries
    (inventory_id, rel_path, parent_path, is_dir, size, mtime, kind,
     media_hint, duplicate_state)
VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 'none')
"""


@dataclass(frozen=True)
class InventoryStats:
    files: int
    dirs: int
    bytes_total: int
    errors: int


def create_inventory(conn: sqlite3.Connection, drive_id: int, root: str) -> int:
    """Insert a new inventory row and return its id."""
    cursor = conn.execute(
        "INSERT INTO inventories (drive_id, root, status, started_at) "
        f"VALUES (?, ?, 'scanning', {_NOW})",
        (drive_id, root),
    )
    conn.commit()
    return int(cursor.lastrowid)


def scan_inventory(
    conn: sqlite3.Connection,
    inventory_id: int,
    root: Path,
    *,
    skip_hidden_root_dirs: bool = True,
    on_progress: Callable[[int, int], None] | None = None,
) -> InventoryStats:
    """Scan ``root`` into ``inventory_entries`` and return the totals.

    A scan replaces any entries already recorded for the inventory, so
    re-scanning after a failure starts from a clean slate. Per-entry failures
    (unreadable directories, unreadable entries, symlinks, undecodable names)
    are counted in ``InventoryStats.errors`` and skipped so one bad entry
    cannot abort the whole scan. A failure to scan the root at all marks the
    inventory ``failed`` and is re-raised.
    """
    if (
        conn.execute("SELECT 1 FROM inventories WHERE id=?", (inventory_id,)).fetchone()
        is None
    ):
        raise ValueError(f"unknown inventory: {inventory_id}")

    conn.execute("DELETE FROM inventory_entries WHERE inventory_id=?", (inventory_id,))
    conn.execute(
        f"UPDATE inventories SET status='scanning', started_at={_NOW}, "
        "finished_at=NULL, error=NULL WHERE id=?",
        (inventory_id,),
    )
    conn.commit()

    try:
        stats = _scan(
            conn,
            inventory_id,
            Path(root),
            skip_hidden_root_dirs=skip_hidden_root_dirs,
            on_progress=on_progress,
        )
    except Exception as exc:
        conn.execute(
            f"UPDATE inventories SET status='failed', finished_at={_NOW}, "
            "error=? WHERE id=?",
            (str(exc), inventory_id),
        )
        conn.commit()
        raise

    conn.execute(
        f"UPDATE inventories SET status='complete', finished_at={_NOW}, "
        "total_files=?, total_bytes=?, error=NULL WHERE id=?",
        (stats.files, stats.bytes_total, inventory_id),
    )
    conn.commit()
    return stats


def get_entry(
    conn: sqlite3.Connection, inventory_id: int, rel_path: str
) -> sqlite3.Row | None:
    """Return the entry at ``rel_path`` or ``None``."""
    return conn.execute(
        "SELECT * FROM inventory_entries WHERE inventory_id=? AND rel_path=?",
        (inventory_id, rel_path),
    ).fetchone()


def iter_children(
    conn: sqlite3.Connection, inventory_id: int, parent_path: str
) -> list[sqlite3.Row]:
    """Return direct children of ``parent_path`` in deterministic order."""
    return list(
        conn.execute(
            "SELECT * FROM inventory_entries "
            "WHERE inventory_id=? AND parent_path=? ORDER BY rel_path",
            (inventory_id, parent_path),
        )
    )


def _scan(
    conn: sqlite3.Connection,
    inventory_id: int,
    root: Path,
    *,
    skip_hidden_root_dirs: bool,
    on_progress: Callable[[int, int], None] | None,
) -> InventoryStats:
    if not root.is_dir():
        raise NotADirectoryError(f"not a directory: {root}")
    with os.scandir(root):
        pass

    files = 0
    dirs = 0
    bytes_total = 0
    files_seen = 0
    bytes_seen = 0
    errors = 0
    root_path = os.fspath(root)

    def _on_error(exc: OSError) -> None:
        nonlocal errors
        if exc.filename == root_path:
            raise exc
        errors += 1

    walker = os.walk(root, topdown=True, onerror=_on_error, followlinks=False)
    for dirpath, dirnames, filenames in walker:
        current = Path(dirpath)
        parent_rel = _relative(current, root)

        descend: list[str] = []
        for name in dirnames:
            if name in SYSTEM_DIRS:
                continue
            if skip_hidden_root_dirs and parent_rel == "" and name.startswith("."):
                continue
            child = current / name
            if child.is_symlink():
                errors += 1
                continue
            rel_path = _join(parent_rel, name)
            try:
                mtime = child.stat().st_mtime
            except OSError:
                errors += 1
                mtime = None
            if not _record(
                conn, inventory_id, rel_path, parent_rel, True, 0, mtime, "other"
            ):
                errors += 1
                continue
            dirs += 1
            descend.append(name)
        dirnames[:] = descend

        for name in filenames:
            child = current / name
            if child.is_symlink():
                errors += 1
                continue
            rel_path = _join(parent_rel, name)
            try:
                info = child.stat()
            except OSError:
                errors += 1
                continue
            files_seen += 1
            bytes_seen += info.st_size
            recorded = _record(
                conn,
                inventory_id,
                rel_path,
                parent_rel,
                False,
                info.st_size,
                info.st_mtime,
                classify(rel_path),
            )
            if recorded:
                files += 1
                bytes_total += info.st_size
            else:
                errors += 1
            if on_progress is not None and files_seen % PROGRESS_INTERVAL == 0:
                on_progress(files_seen, bytes_seen)

    return InventoryStats(
        files=files, dirs=dirs, bytes_total=bytes_total, errors=errors
    )


def _record(
    conn: sqlite3.Connection,
    inventory_id: int,
    rel_path: str,
    parent_path: str,
    is_dir: bool,
    size: int,
    mtime: float | None,
    kind: str,
) -> bool:
    try:
        conn.execute(
            _INSERT_ENTRY,
            (
                inventory_id,
                rel_path,
                parent_path,
                int(is_dir),
                size,
                mtime,
                kind,
            ),
        )
    except (OSError, sqlite3.Error, UnicodeError, ValueError):
        return False
    return True


def _relative(path: Path, root: Path) -> str:
    if path == root:
        return ""
    return path.relative_to(root).as_posix()


def _join(parent: str, name: str) -> str:
    return f"{parent}/{name}" if parent else name
