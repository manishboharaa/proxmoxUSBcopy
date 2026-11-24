"""SQLite schema and connection helpers for usbcopy.

The database stores drive, inventory, run, and audit history only; user
configuration remains in ``/etc/usbcopy/config.toml``.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

SCHEMA_VERSION = 1

_NOW = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"

SCHEMA_SQL = f"""
CREATE TABLE IF NOT EXISTS destinations (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    path_in_ct TEXT NOT NULL,
    path_on_host TEXT,
    is_default INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0, 1)),
    created_at TEXT NOT NULL DEFAULT ({_NOW})
);

CREATE TABLE IF NOT EXISTS drives (
    id INTEGER PRIMARY KEY,
    uuid TEXT NOT NULL UNIQUE,
    label TEXT,
    serial TEXT,
    fs_type TEXT,
    mountpoint TEXT,
    first_seen TEXT NOT NULL DEFAULT ({_NOW}),
    last_seen TEXT NOT NULL DEFAULT ({_NOW}),
    present INTEGER NOT NULL DEFAULT 0 CHECK (present IN (0, 1))
);

CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY,
    ts TEXT NOT NULL DEFAULT ({_NOW}),
    level TEXT NOT NULL DEFAULT 'info'
        CHECK (level IN ('info', 'warning', 'error')),
    action TEXT NOT NULL,
    drive_id INTEGER REFERENCES drives(id),
    payload_json TEXT,
    processed INTEGER NOT NULL DEFAULT 0 CHECK (processed IN (0, 1))
);

CREATE TABLE IF NOT EXISTS inventories (
    id INTEGER PRIMARY KEY,
    drive_id INTEGER NOT NULL REFERENCES drives(id),
    root TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'scanning'
        CHECK (status IN ('pending', 'scanning', 'complete', 'failed')),
    started_at TEXT,
    finished_at TEXT,
    total_files INTEGER NOT NULL DEFAULT 0,
    total_bytes INTEGER NOT NULL DEFAULT 0,
    error TEXT
);

CREATE TABLE IF NOT EXISTS inventory_entries (
    id INTEGER PRIMARY KEY,
    inventory_id INTEGER NOT NULL REFERENCES inventories(id) ON DELETE CASCADE,
    rel_path TEXT NOT NULL,
    parent_path TEXT NOT NULL,
    is_dir INTEGER NOT NULL CHECK (is_dir IN (0, 1)),
    size INTEGER NOT NULL DEFAULT 0,
    mtime REAL,
    kind TEXT NOT NULL DEFAULT 'other',
    media_hint TEXT,
    duplicate_state TEXT NOT NULL DEFAULT 'none'
        CHECK (duplicate_state IN ('none', 'exists', 'conflict')),
    UNIQUE (inventory_id, rel_path)
);

CREATE TABLE IF NOT EXISTS runs (
    id INTEGER PRIMARY KEY,
    drive_id INTEGER REFERENCES drives(id),
    inventory_id INTEGER REFERENCES inventories(id),
    destination_id INTEGER REFERENCES destinations(id),
    destination_key TEXT NOT NULL,
    mode TEXT NOT NULL CHECK (mode IN ('review', 'auto')),
    status TEXT NOT NULL DEFAULT 'queued'
        CHECK (status IN ('queued', 'running', 'completed',
                          'completed_with_errors', 'interrupted', 'failed')),
    started_at TEXT,
    finished_at TEXT,
    files_total INTEGER NOT NULL DEFAULT 0,
    bytes_total INTEGER NOT NULL DEFAULT 0,
    bytes_done INTEGER NOT NULL DEFAULT 0,
    error TEXT
);

CREATE TABLE IF NOT EXISTS run_items (
    id INTEGER PRIMARY KEY,
    run_id INTEGER NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
    rel_path TEXT NOT NULL,
    size INTEGER NOT NULL DEFAULT 0,
    dest_rel_path TEXT NOT NULL,
    temp_path TEXT,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'queued', 'running', 'completed',
                          'failed', 'cancelled', 'interrupted')),
    bytes_done INTEGER NOT NULL DEFAULT 0,
    sha256 TEXT,
    attempts INTEGER NOT NULL DEFAULT 0,
    error TEXT,
    started_at TEXT,
    finished_at TEXT
);

CREATE TABLE IF NOT EXISTS audit (
    id INTEGER PRIMARY KEY,
    ts TEXT NOT NULL DEFAULT ({_NOW}),
    actor TEXT,
    action TEXT NOT NULL,
    detail_json TEXT
);

CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_run_items_run_id ON run_items(run_id);
CREATE INDEX IF NOT EXISTS idx_runs_status ON runs(status);
CREATE INDEX IF NOT EXISTS idx_inventory_entries_parent
    ON inventory_entries(inventory_id, parent_path);
CREATE INDEX IF NOT EXISTS idx_drives_present ON drives(present);
"""


def open_db(path: Path) -> sqlite3.Connection:
    """Open a connection with row access by name, WAL, and foreign keys on."""
    conn = sqlite3.connect(Path(path))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA synchronous = NORMAL")
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA busy_timeout = 5000")
    return conn


def init_db(conn: sqlite3.Connection) -> None:
    """Create the schema if needed and record the schema version."""
    conn.executescript(SCHEMA_SQL)
    conn.execute(
        "INSERT OR IGNORE INTO settings (key, value) VALUES ('schema_version', ?)",
        (str(SCHEMA_VERSION),),
    )
    conn.commit()


def table_names(conn: sqlite3.Connection) -> set[str]:
    """Return the user table names in the database."""
    rows = conn.execute(
        "SELECT name FROM sqlite_master "
        "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
    )
    return {row[0] for row in rows}
