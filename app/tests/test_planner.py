from __future__ import annotations

import os
from dataclasses import FrozenInstanceError, fields
from pathlib import Path

import pytest

from usbcopy.inventory import create_inventory, scan_inventory
from usbcopy.planner import (
    PlanError,
    PlanItem,
    RunPlan,
    SkippedItem,
    build_run_plan,
    normalise_selection,
)

FREE_BYTES = 10**9
SOURCE_MTIME = 1_700_000_000
MARGIN = 256 * 1024 * 1024


def _scan_tree(conn, root: Path) -> int:
    inventory_id = create_inventory(conn, drive_id=1, root=str(root))
    scan_inventory(conn, inventory_id, root)
    return inventory_id


def test_module_surface():
    assert issubclass(PlanError, ValueError)
    assert [field.name for field in fields(PlanItem)] == [
        "source_rel",
        "dest_rel",
        "size",
    ]
    assert [field.name for field in fields(SkippedItem)] == [
        "source_rel",
        "dest_rel",
        "reason",
    ]
    assert [field.name for field in fields(RunPlan)] == [
        "items",
        "skipped",
        "warnings",
        "total_bytes",
    ]
    item = PlanItem(source_rel="a", dest_rel="b", size=1)
    with pytest.raises(FrozenInstanceError):
        item.size = 2


def test_file_selection_maps_to_destination_root(conn, inventory, tmp_path):
    plan = build_run_plan(conn, inventory, ["Heat.mkv"], tmp_path, free_bytes=FREE_BYTES)
    assert [i.dest_rel for i in plan.items] == ["Heat.mkv"]
    assert plan.items[0].source_rel == "Heat.mkv"
    assert plan.items[0].size == 2
    assert plan.total_bytes == 2
    assert plan.warnings == []


def test_nested_file_selection_maps_to_basename(conn, inventory, tmp_path):
    plan = build_run_plan(
        conn,
        inventory,
        ["Movies/Heat (1995)/Heat.mkv"],
        tmp_path,
        free_bytes=FREE_BYTES,
    )
    assert [i.dest_rel for i in plan.items] == ["Heat.mkv"]


def test_folder_selection_copies_contents_not_wrapper(conn, inventory, tmp_path):
    plan = build_run_plan(conn, inventory, ["Movies"], tmp_path, free_bytes=FREE_BYTES)
    assert {i.dest_rel for i in plan.items} == {"Heat (1995)/Heat.mkv"}
    assert plan.items[0].source_rel == "Movies/Heat (1995)/Heat.mkv"


def test_folder_selection_preserves_nested_structure(conn, tmp_path):
    source = tmp_path / "nested-drive"
    series = source / "Shows" / "The Wire" / "Season 2"
    series.mkdir(parents=True)
    (series / "S02E03.mkv").write_bytes(b"hi")
    (source / "Shows" / "The Wire" / "Season 1").mkdir()
    (source / "Shows" / "The Wire" / "Season 1" / "S01E01.mkv").write_bytes(b"xx")
    inv = _scan_tree(conn, source)
    dest = tmp_path / "nested-dest"
    dest.mkdir()

    plan = build_run_plan(conn, inv, ["Shows"], dest, free_bytes=FREE_BYTES)

    assert {i.dest_rel for i in plan.items} == {
        "The Wire/Season 1/S01E01.mkv",
        "The Wire/Season 2/S02E03.mkv",
    }


def test_overlapping_selections_are_deduplicated(conn, inventory, tmp_path):
    plan = build_run_plan(
        conn,
        inventory,
        ["Movies", "Movies/Heat (1995)/Heat.mkv"],
        tmp_path,
        FREE_BYTES,
    )
    assert len(plan.items) == 1
    assert plan.items[0].source_rel == "Movies/Heat (1995)/Heat.mkv"
    assert plan.items[0].dest_rel == "Heat (1995)/Heat.mkv"
    assert plan.total_bytes == 2


def test_overlap_mapping_is_independent_of_selection_order(conn, inventory, tmp_path):
    reversed_plan = build_run_plan(
        conn,
        inventory,
        ["Movies/Heat (1995)/Heat.mkv", "Movies"],
        tmp_path,
        FREE_BYTES,
    )
    assert len(reversed_plan.items) == 1
    assert reversed_plan.items[0].dest_rel == "Heat (1995)/Heat.mkv"


def test_duplicate_selection_spellings_are_deduplicated(conn, inventory, tmp_path):
    plan = build_run_plan(
        conn, inventory, ["Movies", " ./Movies ", "./Movies"], tmp_path, FREE_BYTES
    )
    assert len(plan.items) == 1


def test_traversal_and_missing_paths_rejected(conn, inventory, tmp_path):
    for bad in ["../etc/passwd", "/etc/passwd", "Movies/../../x", "nope.mkv"]:
        with pytest.raises(PlanError):
            build_run_plan(conn, inventory, [bad], tmp_path, 10**9)


def test_missing_path_message_names_selection(conn, inventory, tmp_path):
    with pytest.raises(PlanError, match="nope.mkv"):
        build_run_plan(conn, inventory, ["nope.mkv"], tmp_path, FREE_BYTES)


def test_absolute_and_backslash_paths_rejected(conn, inventory, tmp_path):
    for bad in ["//etc/passwd", "Movies\\Heat.mkv", "/Movies"]:
        with pytest.raises(PlanError):
            build_run_plan(conn, inventory, [bad], tmp_path, FREE_BYTES)


@pytest.mark.parametrize(
    "path",
    [
        "Movies",
        "Movies/Heat (1995)/Heat.mkv",
        "Heat.mkv",
        "with space.mkv",
        "unicodé 🎬.mkv",
    ],
)
def test_normalise_selection_keeps_valid_paths(path):
    assert normalise_selection(path) == path


def test_normalise_selection_strips_whitespace_and_dot_prefixes():
    assert normalise_selection("  Heat.mkv  ") == "Heat.mkv"
    assert normalise_selection("./Movies") == "Movies"
    assert normalise_selection("././Movies") == "Movies"
    assert normalise_selection(" ./Movies ") == "Movies"
    assert normalise_selection("Movies/ Heat.mkv") == "Movies/ Heat.mkv"


@pytest.mark.parametrize(
    "path",
    [
        "",
        "   ",
        ".",
        "./",
        "..",
        "../etc/passwd",
        "Movies/..",
        "Movies/../x",
        "/etc/passwd",
        "//server/share",
        "Movies\\Heat.mkv",
        "bad\x00name",
    ],
)
def test_normalise_selection_rejects_unsafe_paths(path):
    with pytest.raises(PlanError):
        normalise_selection(path)


def test_normalise_selection_rejects_non_strings():
    with pytest.raises(PlanError):
        normalise_selection(None)  # type: ignore[arg-type]


def test_empty_selections_raise(conn, inventory, tmp_path):
    with pytest.raises(PlanError, match="selection"):
        build_run_plan(conn, inventory, [], tmp_path, FREE_BYTES)


def test_unknown_inventory_raises(conn, inventory, tmp_path):
    with pytest.raises(PlanError, match="inventory"):
        build_run_plan(conn, 999, ["Heat.mkv"], tmp_path, FREE_BYTES)


def test_incomplete_inventory_raises(conn, tmp_path):
    inv = create_inventory(conn, 1, str(tmp_path / "not-scanned"))
    with pytest.raises(PlanError, match="complete"):
        build_run_plan(conn, inv, ["Heat.mkv"], tmp_path, FREE_BYTES)


def test_existing_identical_skipped_and_conflict_flagged(conn, inventory, tmp_path):
    (tmp_path / "Heat (1995)").mkdir()
    target = tmp_path / "Heat (1995)/Heat.mkv"
    target.write_bytes(b"hi")
    os.utime(target, (1_700_000_000, 1_700_000_000))
    plan = build_run_plan(conn, inventory, ["Movies"], tmp_path, 10**9)
    assert plan.skipped[0].reason in {"exists", "conflict"}


def test_existing_identical_file_is_skipped_as_exists(conn, inventory, tmp_path):
    (tmp_path / "Heat (1995)").mkdir()
    target = tmp_path / "Heat (1995)/Heat.mkv"
    target.write_bytes(b"hi")
    os.utime(target, (SOURCE_MTIME + 1.9, SOURCE_MTIME + 1.9))

    plan = build_run_plan(conn, inventory, ["Movies"], tmp_path, FREE_BYTES)

    assert plan.items == []
    assert plan.total_bytes == 0
    assert [(s.source_rel, s.dest_rel, s.reason) for s in plan.skipped] == [
        ("Movies/Heat (1995)/Heat.mkv", "Heat (1995)/Heat.mkv", "exists")
    ]


def test_existing_file_with_different_size_is_conflict(conn, inventory, tmp_path):
    (tmp_path / "Heat (1995)").mkdir()
    target = tmp_path / "Heat (1995)/Heat.mkv"
    target.write_bytes(b"hello")
    os.utime(target, (SOURCE_MTIME, SOURCE_MTIME))

    plan = build_run_plan(conn, inventory, ["Movies"], tmp_path, FREE_BYTES)

    assert plan.items == []
    assert plan.skipped[0].reason == "conflict"


def test_existing_file_with_different_mtime_is_conflict(conn, inventory, tmp_path):
    (tmp_path / "Heat (1995)").mkdir()
    target = tmp_path / "Heat (1995)/Heat.mkv"
    target.write_bytes(b"hi")
    os.utime(target, (SOURCE_MTIME + 2.1, SOURCE_MTIME + 2.1))

    plan = build_run_plan(conn, inventory, ["Movies"], tmp_path, FREE_BYTES)

    assert plan.items == []
    assert plan.skipped[0].reason == "conflict"


def test_directory_at_target_path_is_conflict(conn, inventory, tmp_path):
    (tmp_path / "Heat (1995)" / "Heat.mkv").mkdir(parents=True)

    plan = build_run_plan(conn, inventory, ["Movies"], tmp_path, FREE_BYTES)

    assert plan.items == []
    assert plan.skipped[0].reason == "conflict"


def test_non_directory_ancestor_is_conflict(conn, inventory, tmp_path):
    (tmp_path / "Heat (1995)").write_bytes(b"blocker")

    plan = build_run_plan(conn, inventory, ["Movies"], tmp_path, FREE_BYTES)

    assert plan.items == []
    assert plan.skipped[0].reason == "conflict"
    assert any("blocked" in warning for warning in plan.warnings)


def test_free_space_shortfall_raises(conn, inventory, tmp_path):
    with pytest.raises(PlanError, match="space"):
        build_run_plan(conn, inventory, ["Movies"], tmp_path, free_bytes=1)


def test_free_space_boundary(conn, inventory, tmp_path):
    required = int(2 * 1.02) + MARGIN
    plan = build_run_plan(conn, inventory, ["Heat.mkv"], tmp_path, required)
    assert plan.total_bytes == 2
    with pytest.raises(PlanError, match="space"):
        build_run_plan(conn, inventory, ["Heat.mkv"], tmp_path, required - 1)


def test_free_space_margin_applies_even_when_nothing_is_copied(
    conn, inventory, tmp_path
):
    (tmp_path / "Heat (1995)").mkdir()
    target = tmp_path / "Heat (1995)/Heat.mkv"
    target.write_bytes(b"hi")
    os.utime(target, (SOURCE_MTIME, SOURCE_MTIME))

    with pytest.raises(PlanError, match="space"):
        build_run_plan(conn, inventory, ["Movies"], tmp_path, MARGIN - 1)


def test_duplicate_destination_within_plan_is_skipped_as_conflict(conn, tmp_path):
    source = tmp_path / "collision-drive"
    (source / "A").mkdir(parents=True)
    (source / "B").mkdir(parents=True)
    (source / "A" / "Heat.mkv").write_bytes(b"aa")
    (source / "B" / "Heat.mkv").write_bytes(b"bb")
    inv = _scan_tree(conn, source)
    dest = tmp_path / "collision-dest"
    dest.mkdir()

    plan = build_run_plan(
        conn, inv, ["A/Heat.mkv", "B/Heat.mkv"], dest, free_bytes=FREE_BYTES
    )

    assert [i.source_rel for i in plan.items] == ["A/Heat.mkv"]
    assert [i.dest_rel for i in plan.items] == ["Heat.mkv"]
    assert [(s.source_rel, s.reason) for s in plan.skipped] == [
        ("B/Heat.mkv", "conflict")
    ]
    assert any("both map to" in warning for warning in plan.warnings)


def test_empty_folder_selection_warns_without_items(conn, tmp_path):
    source = tmp_path / "empty-drive"
    (source / "Empty").mkdir(parents=True)
    inv = _scan_tree(conn, source)

    plan = build_run_plan(conn, inv, ["Empty"], tmp_path, free_bytes=FREE_BYTES)

    assert plan.items == []
    assert plan.total_bytes == 0
    assert any("no files" in warning for warning in plan.warnings)


def test_destination_escape_via_symlink_is_rejected(conn, tmp_path):
    source = tmp_path / "escape-drive"
    (source / "A" / "link").mkdir(parents=True)
    (source / "A" / "link" / "x.mkv").write_bytes(b"hi")
    inv = _scan_tree(conn, source)

    dest = tmp_path / "escape-dest"
    outside = tmp_path / "outside"
    dest.mkdir()
    outside.mkdir()
    (dest / "link").symlink_to(outside, target_is_directory=True)

    with pytest.raises(PlanError, match="escape"):
        build_run_plan(conn, inv, ["A"], dest, free_bytes=FREE_BYTES)


def test_planning_is_read_only(conn, inventory, tmp_path):
    dest = tmp_path / "readonly-dest"
    dest.mkdir()
    source_root = tmp_path / "inventory-drive"
    before_dest = sorted(str(p.relative_to(dest)) for p in dest.rglob("*"))
    before_source = {
        p.relative_to(source_root).as_posix(): (p.stat().st_size, p.stat().st_mtime)
        for p in source_root.rglob("*")
    }

    plan = build_run_plan(conn, inventory, ["Movies"], dest, free_bytes=FREE_BYTES)

    assert len(plan.items) == 1
    assert sorted(str(p.relative_to(dest)) for p in dest.rglob("*")) == before_dest
    after_source = {
        p.relative_to(source_root).as_posix(): (p.stat().st_size, p.stat().st_mtime)
        for p in source_root.rglob("*")
    }
    assert after_source == before_source
