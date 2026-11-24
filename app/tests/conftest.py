from __future__ import annotations

from pathlib import Path

import pytest

from usbcopy.db import init_db, open_db


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
