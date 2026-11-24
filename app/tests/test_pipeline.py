from __future__ import annotations

from dataclasses import replace
from pathlib import Path

import pytest

from usbcopy import pipeline
from usbcopy.config import Config, Destination
from usbcopy.pipeline import handle_drive_added
from usbcopy.planner import PlanError
from usbcopy.runs import get_run


def make_config(tmp_path: Path, **overrides: object) -> Config:
    movies = tmp_path / "dest" / "movies"
    series = tmp_path / "dest" / "series"
    movies.mkdir(parents=True, exist_ok=True)
    series.mkdir(parents=True, exist_ok=True)
    values: dict[str, object] = {
        "port": 8088,
        "username": "admin",
        "password_hash": "hash",
        "session_secret": "secret",
        "default_folder": "Movies",
        "default_mode": "review",
        "auto_enabled": False,
        "auto_destination": "movies",
        "verify_sha256": True,
        "chunk_size_mb": 8,
        "retries": 3,
        "preserve_mtime": True,
        "destinations": {
            "movies": Destination("movies", movies),
            "series": Destination("series", series),
        },
        "db_path": tmp_path / "usbcopy.db",
        "events_dir": tmp_path / "events",
        "mounts_root": tmp_path / "mnt",
        "reconcile_minutes": 0,
        "skip_hidden_root_dirs": True,
    }
    values.update(overrides)
    return Config(**values)


@pytest.fixture
def config(tmp_path: Path) -> Config:
    return make_config(tmp_path)


@pytest.fixture
def drive_row(conn) -> int:
    row = conn.execute(
        "SELECT id FROM drives WHERE uuid = 'TEST-DRIVE-0001'"
    ).fetchone()
    assert row is not None
    return int(row[0])


def _run_count(conn) -> int:
    return int(conn.execute("SELECT count(*) FROM runs").fetchone()[0])


def test_drive_added_creates_scanned_inventory(conn, config, sample_tree, drive_row):
    inv = handle_drive_added(conn, drive_row, sample_tree, config)
    assert (
        conn.execute("SELECT status FROM inventories WHERE id=?", (inv,)).fetchone()[0]
        == "complete"
    )
    assert conn.execute("SELECT root FROM inventories WHERE id=?", (inv,)).fetchone()[
        0
    ] == str(sample_tree)


def test_inventory_covers_whole_drive_not_only_auto_folder(
    conn, config, sample_tree, drive_row
):
    config = replace(config, auto_enabled=True, default_folder="Movies")
    inv = handle_drive_added(conn, drive_row, sample_tree, config)
    rel_paths = {
        row[0]
        for row in conn.execute(
            "SELECT rel_path FROM inventory_entries WHERE inventory_id=?", (inv,)
        )
    }
    assert rel_paths == {
        "Movies",
        "Movies/Heat (1995)",
        "Movies/Heat (1995)/Heat.mkv",
        "Shows",
        "Shows/The Wire",
        "Shows/The Wire/Season 2",
        "Shows/The Wire/Season 2/S02E03.mkv",
        "notes.txt",
    }


def test_auto_disabled_creates_no_run(conn, config, sample_tree, drive_row):
    config = replace(config, auto_enabled=False)
    queued: list[int] = []
    inv = handle_drive_added(
        conn, drive_row, sample_tree, config, enqueue_run=queued.append
    )
    assert _run_count(conn) == 0
    assert queued == []
    assert (
        conn.execute("SELECT status FROM inventories WHERE id=?", (inv,)).fetchone()[0]
        == "complete"
    )


def test_auto_enabled_queues_run_for_default_folder(
    conn, config, sample_tree, drive_row
):
    config = replace(
        config, auto_enabled=True, auto_destination="movies", default_folder="Movies"
    )
    queued: list[int] = []
    inv = handle_drive_added(
        conn, drive_row, sample_tree, config, enqueue_run=queued.append
    )
    run = get_run(conn, queued[0])
    assert run["mode"] == "auto" and run["destination_key"] == "movies"
    assert run["drive_id"] == drive_row
    assert run["inventory_id"] == inv
    assert run["status"] == "queued"
    assert run["files_total"] == 1
    assert run["bytes_total"] == 2
    items = conn.execute(
        "SELECT rel_path, dest_rel_path, status FROM run_items WHERE run_id=?",
        (queued[0],),
    ).fetchall()
    assert [tuple(item) for item in items] == [
        ("Movies/Heat (1995)/Heat.mkv", "Heat (1995)/Heat.mkv", "pending")
    ]


def test_enqueue_is_called_only_after_run_is_created(
    conn, config, sample_tree, drive_row
):
    config = replace(config, auto_enabled=True, default_folder="Movies")
    seen: list[int] = []

    def enqueue(run_id: int) -> None:
        run = get_run(conn, run_id)
        assert run is not None
        assert run["status"] == "queued"
        seen.append(run_id)

    handle_drive_added(conn, drive_row, sample_tree, config, enqueue_run=enqueue)
    assert len(seen) == 1
    assert _run_count(conn) == 1


def test_auto_enabled_without_enqueue_still_creates_run(
    conn, config, sample_tree, drive_row
):
    config = replace(config, auto_enabled=True, default_folder="Movies")
    handle_drive_added(conn, drive_row, sample_tree, config)
    assert _run_count(conn) == 1


def test_missing_auto_folder_warns_and_skips(conn, config, sample_tree, drive_row):
    config = replace(config, auto_enabled=True, default_folder="Nope")
    queued: list[int] = []
    inv = handle_drive_added(
        conn, drive_row, sample_tree, config, enqueue_run=queued.append
    )
    assert queued == []
    assert _run_count(conn) == 0
    warnings = conn.execute(
        "SELECT action, drive_id, payload_json FROM events WHERE level='warning'"
    ).fetchall()
    assert len(warnings) == 1
    assert warnings[0]["action"] == "auto_skipped"
    assert warnings[0]["drive_id"] == drive_row
    assert "Nope" in warnings[0]["payload_json"]
    assert (
        conn.execute("SELECT status FROM inventories WHERE id=?", (inv,)).fetchone()[0]
        == "complete"
    )


def test_plan_error_warns_and_skips(conn, config, sample_tree, drive_row, monkeypatch):
    config = replace(config, auto_enabled=True, default_folder="Movies")

    def fail(*args: object, **kwargs: object) -> None:
        raise PlanError("not enough space: need 900 bytes, have 1")

    monkeypatch.setattr(pipeline, "build_run_plan", fail)
    queued: list[int] = []
    inv = handle_drive_added(
        conn, drive_row, sample_tree, config, enqueue_run=queued.append
    )
    assert queued == []
    assert _run_count(conn) == 0
    warnings = conn.execute(
        "SELECT action, payload_json FROM events WHERE level='warning'"
    ).fetchall()
    assert len(warnings) == 1
    assert warnings[0]["action"] == "auto_skipped"
    assert "not enough space" in warnings[0]["payload_json"]
    assert (
        conn.execute("SELECT status FROM inventories WHERE id=?", (inv,)).fetchone()[0]
        == "complete"
    )


def test_auto_uses_free_space_of_auto_destination(
    conn, config, sample_tree, drive_row, monkeypatch
):
    config = replace(config, auto_enabled=True, default_folder="Movies")
    asked: list[Path] = []

    def disk_usage(path: Path):
        asked.append(Path(path))
        return type("Usage", (), {"total": 1, "used": 0, "free": 10**9})()

    monkeypatch.setattr(pipeline.shutil, "disk_usage", disk_usage)
    handle_drive_added(conn, drive_row, sample_tree, config)
    assert asked == [config.destinations["movies"].path]


def test_scan_failure_propagates_and_marks_inventory_failed(
    conn, config, tmp_path, drive_row
):
    missing = tmp_path / "not-mounted"
    with pytest.raises(NotADirectoryError):
        handle_drive_added(conn, drive_row, missing, config)
    assert conn.execute("SELECT status FROM inventories").fetchone()[0] == "failed"
    assert _run_count(conn) == 0
