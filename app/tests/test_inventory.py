from __future__ import annotations

import errno
import os
from dataclasses import FrozenInstanceError, fields

import pytest

from usbcopy.inventory import (
    SYSTEM_DIRS,
    InventoryStats,
    create_inventory,
    get_entry,
    iter_children,
    scan_inventory,
)

EXPECTED_SYSTEM_DIRS = {
    "System Volume Information",
    "$RECYCLE.BIN",
    ".Trashes",
    "lost+found",
    ".Spotlight-V100",
    ".fseventsd",
}


def _row(conn, inventory_id):
    return conn.execute(
        "SELECT * FROM inventories WHERE id=?", (inventory_id,)
    ).fetchone()


def test_scan_records_tree_and_sizes(conn, sample_tree):
    inv = create_inventory(conn, drive_id=1, root=str(sample_tree))
    stats = scan_inventory(conn, inv, sample_tree)
    assert stats.files == 3 and stats.bytes_total == 6
    movies = get_entry(conn, inv, "Movies/Heat (1995)/Heat.mkv")
    assert movies["kind"] == "movie" and movies["size"] == 2
    assert [r["rel_path"] for r in iter_children(conn, inv, "Movies")] == [
        "Movies/Heat (1995)"
    ]


def test_system_and_hidden_root_dirs_skipped(conn, sample_tree):
    (sample_tree / "System Volume Information").mkdir()
    (sample_tree / ".Trashes").mkdir()
    stats = scan_inventory(
        conn, create_inventory(conn, 1, str(sample_tree)), sample_tree
    )
    assert stats.files == 3
    assert get_entry(conn, 1, "System Volume Information") is None


def test_unreadable_dir_recorded_and_scan_continues(conn, sample_tree):
    blocked = sample_tree / "blocked"
    blocked.mkdir()
    (blocked / "x.mkv").write_text("x")
    blocked.chmod(0o000)
    try:
        stats = scan_inventory(
            conn, create_inventory(conn, 1, str(sample_tree)), sample_tree
        )
    finally:
        blocked.chmod(0o755)
    assert stats.errors >= 1 and stats.files == 3


def test_symlinks_are_not_followed(conn, sample_tree):
    (sample_tree / "link").symlink_to(sample_tree / "Movies")
    inv = create_inventory(conn, 1, str(sample_tree))
    stats = scan_inventory(conn, inv, sample_tree)
    assert get_entry(conn, inv, "link") is None
    assert stats.files == 3


def test_unicode_filename_recorded(conn, sample_tree):
    name = "Amélie (2001) 🎬.mkv"
    (sample_tree / name).write_bytes(b"xx")
    inv = create_inventory(conn, 1, str(sample_tree))
    stats = scan_inventory(conn, inv, sample_tree)
    assert stats.files == 4
    assert get_entry(conn, inv, name) is not None


def test_undecodable_filename_does_not_crash(conn, sample_tree):
    raw = os.fsencode(str(sample_tree)) + b"/bad_\xff.mkv"
    with open(raw, "wb") as fh:
        fh.write(b"x")
    inv = create_inventory(conn, 1, str(sample_tree))
    stats = scan_inventory(conn, inv, sample_tree)
    assert stats.errors >= 1
    assert _row(conn, inv)["status"] == "complete"


def test_inventory_module_surface():
    assert isinstance(SYSTEM_DIRS, frozenset)
    assert SYSTEM_DIRS == frozenset(EXPECTED_SYSTEM_DIRS)
    assert [field.name for field in fields(InventoryStats)] == [
        "files",
        "dirs",
        "bytes_total",
        "errors",
    ]
    stats = InventoryStats(files=1, dirs=2, bytes_total=3, errors=4)
    with pytest.raises(FrozenInstanceError):
        stats.files = 5


def test_create_inventory_returns_id_and_marks_scanning(conn, sample_tree):
    inv = create_inventory(conn, drive_id=1, root=str(sample_tree))
    assert isinstance(inv, int)
    row = _row(conn, inv)
    assert row["drive_id"] == 1
    assert row["root"] == str(sample_tree)
    assert row["status"] == "scanning"
    assert row["started_at"]


def test_inventory_complete_with_totals(conn, sample_tree):
    inv = create_inventory(conn, 1, str(sample_tree))
    stats = scan_inventory(conn, inv, sample_tree)
    row = _row(conn, inv)
    assert row["status"] == "complete"
    assert row["total_files"] == stats.files == 3
    assert row["total_bytes"] == stats.bytes_total == 6
    assert row["started_at"] and row["finished_at"]
    assert row["error"] is None


def test_stats_count_dirs(conn, sample_tree):
    inv = create_inventory(conn, 1, str(sample_tree))
    stats = scan_inventory(conn, inv, sample_tree)
    assert stats.dirs == 5


def test_root_entry_is_not_recorded(conn, sample_tree):
    inv = create_inventory(conn, 1, str(sample_tree))
    scan_inventory(conn, inv, sample_tree)
    assert get_entry(conn, inv, "") is None


def test_entries_carry_parent_and_metadata(conn, sample_tree):
    inv = create_inventory(conn, 1, str(sample_tree))
    scan_inventory(conn, inv, sample_tree)
    movies = get_entry(conn, inv, "Movies")
    assert movies["is_dir"] == 1
    assert movies["parent_path"] == ""
    assert movies["size"] == 0
    assert movies["kind"] == "other"

    heat = get_entry(conn, inv, "Movies/Heat (1995)/Heat.mkv")
    assert heat["is_dir"] == 0
    assert heat["parent_path"] == "Movies/Heat (1995)"
    assert heat["duplicate_state"] == "none"
    expected_mtime = (sample_tree / "Movies/Heat (1995)/Heat.mkv").stat().st_mtime
    assert heat["mtime"] == pytest.approx(expected_mtime)

    series = get_entry(conn, inv, "Shows/The Wire/Season 2/S02E03.mkv")
    assert series["kind"] == "series"
    assert get_entry(conn, inv, "notes.txt")["kind"] == "other"


def test_get_entry_missing_and_other_inventory_return_none(conn, sample_tree):
    inv = create_inventory(conn, 1, str(sample_tree))
    scan_inventory(conn, inv, sample_tree)
    assert get_entry(conn, inv, "nope.mkv") is None
    assert get_entry(conn, 999, "notes.txt") is None


def test_iter_children_is_direct_and_ordered(conn, sample_tree):
    inv = create_inventory(conn, 1, str(sample_tree))
    scan_inventory(conn, inv, sample_tree)
    root_children = [row["rel_path"] for row in iter_children(conn, inv, "")]
    assert root_children == sorted(root_children)
    assert set(root_children) == {"Movies", "Shows", "notes.txt"}
    leaves = [row["rel_path"] for row in iter_children(conn, inv, "Movies/Heat (1995)")]
    assert leaves == ["Movies/Heat (1995)/Heat.mkv"]


def test_system_dirs_skipped_at_any_depth(conn, sample_tree):
    nested = sample_tree / "Movies" / "System Volume Information"
    nested.mkdir()
    (nested / "indexer.mkv").write_bytes(b"x")
    inv = create_inventory(conn, 1, str(sample_tree))
    stats = scan_inventory(conn, inv, sample_tree)
    assert stats.files == 3
    assert get_entry(conn, inv, "Movies/System Volume Information") is None
    assert get_entry(conn, inv, "Movies/System Volume Information/indexer.mkv") is None


def test_hidden_dirs_skipped_only_at_root(conn, sample_tree):
    (sample_tree / ".secret").mkdir()
    (sample_tree / ".secret" / "ignored.mkv").write_bytes(b"x")
    (sample_tree / "Movies" / ".hidden").mkdir()
    (sample_tree / "Movies" / ".hidden" / "extra.mkv").write_bytes(b"x")
    inv = create_inventory(conn, 1, str(sample_tree))
    stats = scan_inventory(conn, inv, sample_tree)
    assert stats.files == 4
    assert get_entry(conn, inv, ".secret") is None
    assert get_entry(conn, inv, "Movies/.hidden/extra.mkv") is not None


def test_hidden_root_dirs_can_be_included(conn, sample_tree):
    (sample_tree / ".secret").mkdir()
    (sample_tree / ".secret" / "extra.mkv").write_bytes(b"x")
    inv = create_inventory(conn, 1, str(sample_tree))
    stats = scan_inventory(conn, inv, sample_tree, skip_hidden_root_dirs=False)
    assert stats.files == 4
    assert get_entry(conn, inv, ".secret/extra.mkv") is not None


def test_hidden_root_files_are_kept(conn, sample_tree):
    (sample_tree / ".hiddenfile.mkv").write_bytes(b"zz")
    inv = create_inventory(conn, 1, str(sample_tree))
    stats = scan_inventory(conn, inv, sample_tree)
    assert stats.files == 4
    assert get_entry(conn, inv, ".hiddenfile.mkv") is not None


def test_symlink_to_file_not_recorded(conn, sample_tree):
    target = sample_tree / "real.mkv"
    target.write_bytes(b"hi")
    (sample_tree / "alias.mkv").symlink_to(target)
    inv = create_inventory(conn, 1, str(sample_tree))
    stats = scan_inventory(conn, inv, sample_tree)
    assert stats.files == 4
    assert stats.errors >= 1
    assert get_entry(conn, inv, "alias.mkv") is None


def test_progress_callback_every_500_files(conn, tmp_path):
    root = tmp_path / "many"
    root.mkdir()
    for index in range(500):
        (root / f"file_{index:03d}.mkv").write_bytes(b"x")
    inv = create_inventory(conn, 1, str(root))
    calls = []
    stats = scan_inventory(
        conn, inv, root, on_progress=lambda files, size: calls.append((files, size))
    )
    assert stats.files == 500 and stats.bytes_total == 500
    assert calls == [(500, 500)]


def test_missing_root_marks_inventory_failed(conn, tmp_path):
    missing = tmp_path / "gone"
    inv = create_inventory(conn, 1, str(missing))
    with pytest.raises(OSError):
        scan_inventory(conn, inv, missing)
    row = _row(conn, inv)
    assert row["status"] == "failed"
    assert row["error"]
    assert row["finished_at"]


def test_unreadable_root_marks_inventory_failed(conn, sample_tree, monkeypatch):
    inv = create_inventory(conn, 1, str(sample_tree))
    sample_tree.chmod(0o000)
    try:
        if os.access(sample_tree, os.R_OK):

            def _deny(path):
                raise PermissionError(errno.EACCES, "Permission denied", str(path))

            monkeypatch.setattr(os, "scandir", _deny)
        with pytest.raises(OSError):
            scan_inventory(conn, inv, sample_tree)
    finally:
        sample_tree.chmod(0o755)
    row = _row(conn, inv)
    assert row["status"] == "failed"
    assert row["error"]
    assert row["finished_at"]


def test_rescan_same_inventory_replaces_entries(conn, sample_tree):
    inv = create_inventory(conn, 1, str(sample_tree))
    first = scan_inventory(conn, inv, sample_tree)
    assert first.files == 3 and first.errors == 0

    (sample_tree / "notes.txt").unlink()
    (sample_tree / "Movies" / "Heat (1995)" / "Featurette.mkv").write_bytes(b"zz")

    second = scan_inventory(conn, inv, sample_tree)
    assert second.files == 3 and second.bytes_total == 6
    assert second.errors == 0
    assert get_entry(conn, inv, "notes.txt") is None
    assert get_entry(conn, inv, "Movies/Heat (1995)/Featurette.mkv") is not None
    total = conn.execute(
        "SELECT count(*) FROM inventory_entries WHERE inventory_id=?", (inv,)
    ).fetchone()[0]
    assert total == 8
    row = _row(conn, inv)
    assert row["status"] == "complete"
    assert row["total_files"] == 3 and row["total_bytes"] == 6


def test_unknown_inventory_raises(conn, sample_tree):
    with pytest.raises(ValueError):
        scan_inventory(conn, 999, sample_tree)


def test_scan_does_not_modify_source(conn, sample_tree):
    before = {
        str(path.relative_to(sample_tree)): (path.stat().st_mtime, path.stat().st_size)
        for path in sample_tree.rglob("*")
    }
    inv = create_inventory(conn, 1, str(sample_tree))
    scan_inventory(conn, inv, sample_tree)
    after = {
        str(path.relative_to(sample_tree)): (path.stat().st_mtime, path.stat().st_size)
        for path in sample_tree.rglob("*")
    }
    assert before == after
