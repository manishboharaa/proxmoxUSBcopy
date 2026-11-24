from __future__ import annotations

import os
from pathlib import Path

import pytest

from usbcopy.db import init_db, open_db
from usbcopy.inventory import create_inventory, scan_inventory

INVENTORY_MTIME = 1_700_000_000


@pytest.fixture
def conn(tmp_path: Path):
    connection = open_db(tmp_path / "usbcopy.db")
    init_db(connection)
    connection.execute(
        "INSERT INTO drives (id, uuid, label) VALUES (1, 'TEST-DRIVE-0001', 'Test Drive')"
    )
    connection.commit()
    try:
        yield connection
    finally:
        connection.close()


@pytest.fixture
def sample_tree(tmp_path: Path) -> Path:
    root = tmp_path / "drive"
    movie_dir = root / "Movies" / "Heat (1995)"
    movie_dir.mkdir(parents=True)
    (movie_dir / "Heat.mkv").write_bytes(b"hi")

    series_dir = root / "Shows" / "The Wire" / "Season 2"
    series_dir.mkdir(parents=True)
    (series_dir / "S02E03.mkv").write_bytes(b"hi")

    (root / "notes.txt").write_bytes(b"hi")
    return root


@pytest.fixture
def inventory(conn, tmp_path: Path) -> int:
    root = tmp_path / "inventory-drive"
    movie_dir = root / "Movies" / "Heat (1995)"
    movie_dir.mkdir(parents=True)
    for path in (root / "Heat.mkv", movie_dir / "Heat.mkv"):
        path.write_bytes(b"hi")
        os.utime(path, (INVENTORY_MTIME, INVENTORY_MTIME))
    inventory_id = create_inventory(conn, drive_id=1, root=str(root))
    scan_inventory(conn, inventory_id, root)
    return inventory_id
