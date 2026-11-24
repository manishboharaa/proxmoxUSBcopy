from __future__ import annotations

import sqlite3
from pathlib import Path

import pytest

from usbcopy.db import SCHEMA_VERSION, init_db, open_db, table_names

EXPECTED_TABLES = {
    "destinations",
    "drives",
    "events",
    "inventories",
    "inventory_entries",
    "runs",
    "run_items",
    "audit",
    "settings",
}

EXPECTED_COLUMNS = {
    "destinations": {
        "id",
        "name",
        "path_in_ct",
        "path_on_host",
        "is_default",
        "created_at",
    },
    "drives": {
        "id",
        "uuid",
        "label",
        "serial",
        "fs_type",
        "mountpoint",
        "first_seen",
        "last_seen",
        "present",
    },
    "events": {
        "id",
        "ts",
        "level",
        "action",
        "drive_id",
        "payload_json",
        "processed",
    },
    "inventories": {
        "id",
        "drive_id",
        "root",
        "status",
        "started_at",
        "finished_at",
        "total_files",
        "total_bytes",
        "error",
    },
    "inventory_entries": {
        "id",
        "inventory_id",
        "rel_path",
        "parent_path",
        "is_dir",
        "size",
        "mtime",
        "kind",
        "media_hint",
        "duplicate_state",
    },
    "runs": {
        "id",
        "drive_id",
        "inventory_id",
        "destination_id",
        "destination_key",
        "mode",
        "status",
        "started_at",
        "finished_at",
        "files_total",
        "bytes_total",
        "bytes_done",
        "error",
    },
    "run_items": {
        "id",
        "run_id",
        "rel_path",
        "size",
        "dest_rel_path",
        "temp_path",
        "status",
        "bytes_done",
        "sha256",
        "attempts",
        "error",
        "started_at",
        "finished_at",
    },
    "audit": {"id", "ts", "actor", "action", "detail_json"},
    "settings": {"key", "value"},
}

EXPECTED_INDEXES = {
    "idx_run_items_run_id": ("run_items", ("run_id",)),
    "idx_runs_status": ("runs", ("status",)),
    "idx_inventory_entries_parent": (
        "inventory_entries",
        ("inventory_id", "parent_path"),
    ),
    "idx_drives_present": ("drives", ("present",)),
}

RUN_STATUSES = (
    "queued",
    "running",
    "completed",
    "completed_with_errors",
    "interrupted",
    "failed",
)

TIMESTAMP_COLUMNS = (
    ("destinations", "created_at"),
    ("drives", "first_seen"),
    ("drives", "last_seen"),
    ("events", "ts"),
    ("inventories", "started_at"),
    ("inventories", "finished_at"),
    ("runs", "started_at"),
    ("runs", "finished_at"),
    ("run_items", "started_at"),
    ("run_items", "finished_at"),
    ("audit", "ts"),
)


def _columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {row["name"] for row in conn.execute(f"PRAGMA table_info({table})")}


@pytest.fixture
def conn(tmp_path: Path):
    connection = open_db(tmp_path / "t.db")
    init_db(connection)
    yield connection
    connection.close()


def test_init_creates_all_tables(tmp_path):
    conn = open_db(tmp_path / "t.db")
    init_db(conn)
    assert {
        "destinations",
        "drives",
        "events",
        "inventories",
        "inventory_entries",
        "runs",
        "run_items",
        "audit",
        "settings",
    } <= table_names(conn)
    assert conn.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
    assert conn.execute("PRAGMA foreign_keys").fetchone()[0] == 1


def test_init_is_idempotent(tmp_path):
    conn = open_db(tmp_path / "t.db")
    init_db(conn)
    init_db(conn)
    row = conn.execute(
        "SELECT value FROM settings WHERE key='schema_version'"
    ).fetchone()
    assert row[0] == "1"


def test_open_db_configures_connection(tmp_path: Path):
    connection = open_db(tmp_path / "t.db")
    try:
        assert connection.row_factory is sqlite3.Row
        assert connection.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
        assert connection.execute("PRAGMA foreign_keys").fetchone()[0] == 1
        assert connection.execute("PRAGMA synchronous").fetchone()[0] == 1
        row = connection.execute("SELECT 1 AS value").fetchone()
        assert isinstance(row, sqlite3.Row)
        assert row["value"] == 1
    finally:
        connection.close()


def test_wal_mode_persists_for_new_connection(tmp_path: Path):
    path = tmp_path / "t.db"
    connection = open_db(path)
    init_db(connection)
    connection.close()

    connection = open_db(path)
    try:
        assert connection.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
    finally:
        connection.close()


def test_schema_version_is_recorded(conn: sqlite3.Connection):
    assert SCHEMA_VERSION == 1
    row = conn.execute(
        "SELECT value FROM settings WHERE key='schema_version'"
    ).fetchone()
    assert row[0] == str(SCHEMA_VERSION)


def test_table_names_lists_user_tables(conn: sqlite3.Connection):
    assert table_names(conn) == EXPECTED_TABLES


@pytest.mark.parametrize("table", sorted(EXPECTED_COLUMNS))
def test_table_columns_match_design(conn: sqlite3.Connection, table: str):
    assert _columns(conn, table) == EXPECTED_COLUMNS[table]


@pytest.mark.parametrize("table,column", TIMESTAMP_COLUMNS)
def test_timestamps_are_text(conn: sqlite3.Connection, table: str, column: str):
    types = {row["name"]: row["type"] for row in conn.execute(f"PRAGMA table_info({table})")}
    assert types[column] == "TEXT"


@pytest.mark.parametrize("index_name", sorted(EXPECTED_INDEXES))
def test_required_indexes_exist(conn: sqlite3.Connection, index_name: str):
    table, index_columns = EXPECTED_INDEXES[index_name]
    row = conn.execute(
        "SELECT tbl_name FROM sqlite_master WHERE type='index' AND name=?",
        (index_name,),
    ).fetchone()
    assert row is not None
    assert row["tbl_name"] == table
    actual = tuple(
        info["name"] for info in conn.execute(f"PRAGMA index_info({index_name})")
    )
    assert actual == index_columns


@pytest.mark.parametrize("status", RUN_STATUSES)
def test_runs_status_accepts_valid_values(conn: sqlite3.Connection, status: str):
    conn.execute(
        "INSERT INTO runs (destination_key, mode, status) VALUES ('movies', 'review', ?)",
        (status,),
    )
    conn.commit()
    row = conn.execute("SELECT status FROM runs").fetchone()
    assert row[0] == status


@pytest.mark.parametrize("status", ["cancelled", "pending", "done", ""])
def test_runs_status_rejects_invalid_values(conn: sqlite3.Connection, status: str):
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(
            "INSERT INTO runs (destination_key, mode, status) "
            "VALUES ('movies', 'review', ?)",
            (status,),
        )


def test_run_items_accept_cancelled_status(conn: sqlite3.Connection):
    run_id = conn.execute(
        "INSERT INTO runs (destination_key, mode) VALUES ('movies', 'review')"
    ).lastrowid
    conn.execute(
        "INSERT INTO run_items (run_id, rel_path, dest_rel_path, status) "
        "VALUES (?, 'Heat.mkv', 'Heat.mkv', 'cancelled')",
        (run_id,),
    )
    conn.commit()
    row = conn.execute("SELECT status FROM run_items").fetchone()
    assert row[0] == "cancelled"


def test_run_items_reject_unknown_status(conn: sqlite3.Connection):
    run_id = conn.execute(
        "INSERT INTO runs (destination_key, mode) VALUES ('movies', 'review')"
    ).lastrowid
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(
            "INSERT INTO run_items (run_id, rel_path, dest_rel_path, status) "
            "VALUES (?, 'Heat.mkv', 'Heat.mkv', 'bogus')",
            (run_id,),
        )


@pytest.mark.parametrize("level", ["info", "warning", "error"])
def test_events_level_accepts_valid_values(conn: sqlite3.Connection, level: str):
    conn.execute(
        "INSERT INTO events (ts, level, action) "
        "VALUES ('2026-01-01T00:00:00.000Z', ?, 'add')",
        (level,),
    )
    conn.commit()
    row = conn.execute("SELECT level FROM events").fetchone()
    assert row[0] == level


@pytest.mark.parametrize("level", ["debug", "WARN", ""])
def test_events_level_rejects_invalid_values(conn: sqlite3.Connection, level: str):
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(
            "INSERT INTO events (ts, level, action) "
            "VALUES ('2026-01-01T00:00:00.000Z', ?, 'add')",
            (level,),
        )


def test_foreign_keys_are_enforced(conn: sqlite3.Connection):
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(
            "INSERT INTO inventory_entries "
            "(inventory_id, rel_path, parent_path, is_dir, kind) "
            "VALUES (999, 'Heat.mkv', '', 0, 'video')"
        )


def test_inventory_entries_cascade_with_inventory(conn: sqlite3.Connection):
    drive_id = conn.execute("INSERT INTO drives (uuid) VALUES ('ABCD-1234')").lastrowid
    inventory_id = conn.execute(
        "INSERT INTO inventories (drive_id, root) VALUES (?, '/mnt/usb/ABCD-1234')",
        (drive_id,),
    ).lastrowid
    conn.execute(
        "INSERT INTO inventory_entries "
        "(inventory_id, rel_path, parent_path, is_dir, kind) "
        "VALUES (?, 'Movies', '', 1, 'other')",
        (inventory_id,),
    )
    conn.commit()

    conn.execute("DELETE FROM inventories WHERE id=?", (inventory_id,))
    conn.commit()

    assert conn.execute("SELECT count(*) FROM inventory_entries").fetchone()[0] == 0


def test_reinit_preserves_existing_rows(conn: sqlite3.Connection):
    conn.execute(
        "INSERT INTO audit (ts, actor, action) "
        "VALUES ('2026-01-01T00:00:00.000Z', 'admin', 'login')"
    )
    conn.commit()

    init_db(conn)

    assert conn.execute("SELECT count(*) FROM audit").fetchone()[0] == 1
