"""Destination mapping and run planning for usbcopy.

Planning is read-only. The planner reads the inventory from SQLite and only
inspects destination paths with ``exists``/``is_file``/``stat`` calls; it never
creates, writes, renames, or deletes anything on either side.
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Literal

FREE_SPACE_FACTOR = 1.02
FREE_SPACE_MARGIN = 256 * 1024 * 1024
MTIME_TOLERANCE = 2.0

_ENTRY_SQL = (
    "SELECT rel_path, is_dir, size, mtime FROM inventory_entries "
    "WHERE inventory_id = ? AND rel_path = ?"
)

_DESCENDANTS_SQL = """
WITH RECURSIVE tree(rel_path, is_dir, size, mtime) AS (
    SELECT rel_path, is_dir, size, mtime
      FROM inventory_entries
     WHERE inventory_id = ? AND rel_path = ?
    UNION ALL
    SELECT entry.rel_path, entry.is_dir, entry.size, entry.mtime
      FROM inventory_entries AS entry
      JOIN tree ON entry.parent_path = tree.rel_path
     WHERE entry.inventory_id = ? AND tree.is_dir = 1
)
SELECT rel_path, size, mtime
  FROM tree
 WHERE is_dir = 0
 ORDER BY rel_path
"""


class PlanError(ValueError):
    """Raised when selections cannot be turned into a safe run plan."""


@dataclass(frozen=True)
class PlanItem:
    source_rel: str
    dest_rel: str
    size: int


@dataclass(frozen=True)
class SkippedItem:
    source_rel: str
    dest_rel: str
    reason: Literal["exists", "conflict"]


@dataclass(frozen=True)
class RunPlan:
    items: list[PlanItem]
    skipped: list[SkippedItem]
    warnings: list[str]
    total_bytes: int


def normalise_selection(rel_path: str) -> str:
    """Return the canonical relative inventory path for a selection.

    Surrounding whitespace and any number of leading ``./`` prefixes are
    stripped. Empty values, absolute paths, backslashes, NUL bytes, and any
    ``..`` segment are rejected: a selection must name an inventory entry
    below the drive root, never a host path.
    """
    if not isinstance(rel_path, str):
        raise PlanError(f"selection must be a string: {rel_path!r}")
    if "\x00" in rel_path:
        raise PlanError(f"selection contains a NUL byte: {rel_path!r}")
    if "\\" in rel_path:
        raise PlanError(f"selection contains a backslash: {rel_path!r}")

    path = rel_path.strip()
    if not path:
        raise PlanError("empty selection")
    while path.startswith("./"):
        path = path[2:]
    if not path or path == ".":
        raise PlanError(f"empty selection: {rel_path!r}")
    if path.startswith("/"):
        raise PlanError(f"absolute path not allowed: {rel_path!r}")
    if ".." in path.split("/"):
        raise PlanError(f"parent path segment not allowed: {rel_path!r}")
    return path


def build_run_plan(
    conn: sqlite3.Connection,
    inventory_id: int,
    selections: list[str],
    dest_root: Path,
    free_bytes: int,
) -> RunPlan:
    """Map ``selections`` from a complete inventory into a destination.

    A selected file maps to ``<dest_root>/<basename>``. A selected folder maps
    its contents (not the folder itself) below ``dest_root`` and keeps the
    structure beneath it. Overlapping selections are de-duplicated by source
    path; when a file is reachable from more than one selection, the mapping
    from the shallowest selected root wins so structure is preserved.

    Existing destinations are skipped: identical size and mtime (within two
    seconds) is ``exists``; anything else is a ``conflict``. Skipped files
    never appear in ``items`` or ``total_bytes``. Free space must cover
    ``total_bytes * 1.02`` plus a 256 MiB margin.
    """
    _require_complete_inventory(conn, inventory_id)
    if not selections:
        raise PlanError("no selections provided")

    dest_root = Path(dest_root)
    warnings: list[str] = []
    selected: list[tuple[str, bool, int, float | None]] = []
    seen: set[str] = set()
    for selection in selections:
        rel_path = normalise_selection(selection)
        if rel_path in seen:
            continue
        seen.add(rel_path)
        row = conn.execute(_ENTRY_SQL, (inventory_id, rel_path)).fetchone()
        if row is None:
            raise PlanError(f"selection not found in inventory: {rel_path!r}")
        selected.append((rel_path, bool(row[1]), int(row[2]), row[3]))

    candidates: dict[str, tuple[tuple[int, str], str, int, float | None]] = {}
    for root, is_dir, size, mtime in selected:
        root_depth = len(PurePosixPath(root).parts)
        if not is_dir:
            _remember(
                candidates,
                (root_depth, root),
                root,
                PurePosixPath(root).name,
                size,
                mtime,
            )
            continue
        descendants = conn.execute(
            _DESCENDANTS_SQL, (inventory_id, root, inventory_id)
        ).fetchall()
        if not descendants:
            warnings.append(f"selected folder has no files: {root}")
        for descendant in descendants:
            source_rel = descendant[0]
            dest_rel = _relative_to(source_rel, root)
            _remember(
                candidates,
                (root_depth, root),
                source_rel,
                dest_rel,
                int(descendant[1]),
                descendant[2],
            )

    resolved_root = _resolve(dest_root, "destination root")
    items: list[PlanItem] = []
    skipped: list[SkippedItem] = []
    claimed: dict[str, str] = {}
    for source_rel in sorted(candidates):
        _, dest_rel, size, mtime = candidates[source_rel]
        dest_path = _destination_path(dest_root, resolved_root, dest_rel)
        claimed_by = claimed.get(dest_rel)
        if claimed_by is not None:
            skipped.append(SkippedItem(source_rel, dest_rel, "conflict"))
            warnings.append(
                f"destination collision: {source_rel!r} and {claimed_by!r} "
                f"both map to {dest_rel!r}"
            )
            continue
        claimed[dest_rel] = source_rel
        reason = _duplicate_reason(dest_path, size, mtime)
        if reason is None and _blocked_ancestor(dest_path, dest_root):
            reason = "conflict"
            warnings.append(
                f"destination path is blocked by a non-directory: {dest_rel!r}"
            )
        if reason is None:
            items.append(PlanItem(source_rel, dest_rel, size))
        else:
            skipped.append(SkippedItem(source_rel, dest_rel, reason))

    total_bytes = sum(item.size for item in items)
    required = required_free_bytes(total_bytes)
    if free_bytes < required:
        raise PlanError(f"not enough space: need {required} bytes, have {free_bytes}")
    return RunPlan(
        items=items,
        skipped=skipped,
        warnings=warnings,
        total_bytes=total_bytes,
    )


def required_free_bytes(total_bytes: int) -> int:
    """Return the free space a run of ``total_bytes`` needs to start."""
    return int(total_bytes * FREE_SPACE_FACTOR) + FREE_SPACE_MARGIN


def _require_complete_inventory(conn: sqlite3.Connection, inventory_id: int) -> None:
    row = conn.execute(
        "SELECT status FROM inventories WHERE id = ?", (inventory_id,)
    ).fetchone()
    if row is None:
        raise PlanError(f"unknown inventory: {inventory_id}")
    if row[0] != "complete":
        raise PlanError(f"inventory {inventory_id} is not complete: {row[0]}")


def _relative_to(source_rel: str, root: str) -> str:
    try:
        return PurePosixPath(source_rel).relative_to(PurePosixPath(root)).as_posix()
    except ValueError as exc:
        raise PlanError(
            f"inventory entry is outside selection {root!r}: {source_rel!r}"
        ) from exc


def _remember(
    candidates: dict[str, tuple[tuple[int, str], str, int, float | None]],
    key: tuple[int, str],
    source_rel: str,
    dest_rel: str,
    size: int,
    mtime: float | None,
) -> None:
    current = candidates.get(source_rel)
    if current is None or key < current[0]:
        candidates[source_rel] = (key, dest_rel, size, mtime)


def _resolve(path: Path, label: str) -> Path:
    try:
        return path.resolve()
    except OSError as exc:
        raise PlanError(f"cannot resolve {label}: {exc}") from exc


def _destination_path(
    dest_root: Path, resolved_root: Path, dest_rel: str
) -> Path:
    rel = PurePosixPath(dest_rel)
    if not dest_rel or rel.is_absolute() or ".." in rel.parts:
        raise PlanError(f"unsafe destination path: {dest_rel!r}")
    dest_path = dest_root / rel
    resolved = _resolve(dest_path, f"destination path {dest_rel!r}")
    if resolved != resolved_root and resolved_root not in resolved.parents:
        raise PlanError(f"destination escapes root: {dest_rel!r}")
    return dest_path


def _duplicate_reason(
    dest_path: Path, size: int, mtime: float | None
) -> Literal["exists", "conflict"] | None:
    try:
        if not dest_path.exists():
            return None
        if not dest_path.is_file():
            return "conflict"
        stat = dest_path.stat()
    except OSError:
        return "conflict"
    identical = (
        int(stat.st_size) == size
        and mtime is not None
        and abs(stat.st_mtime - float(mtime)) <= MTIME_TOLERANCE
    )
    return "exists" if identical else "conflict"


def _blocked_ancestor(dest_path: Path, dest_root: Path) -> bool:
    """Return True when a parent below ``dest_root`` exists but is not a dir."""
    parent = dest_path.parent
    if parent.is_dir():
        return False
    while parent != dest_root and dest_root in parent.parents:
        if (parent.is_symlink() or parent.exists()) and not parent.is_dir():
            return True
        parent = parent.parent
    return False
