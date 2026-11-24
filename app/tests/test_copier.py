from __future__ import annotations

import hashlib
import os
import stat
from dataclasses import FrozenInstanceError, fields
from pathlib import Path

import pytest

from usbcopy import copier
from usbcopy.copier import CopyError, CopyResult, copy_file


@pytest.fixture
def src(tmp_path: Path) -> Path:
    path = tmp_path / "source.bin"
    path.write_bytes(b"payload")
    return path


@pytest.fixture
def dst(tmp_path: Path) -> Path:
    return tmp_path / "destination.bin"


def test_module_surface():
    assert issubclass(CopyError, Exception)
    assert [field.name for field in fields(CopyResult)] == ["sha256", "bytes_copied"]
    result = CopyResult(sha256="abc", bytes_copied=1)
    with pytest.raises(FrozenInstanceError):
        result.bytes_copied = 2


def test_copies_content_and_mtime(src, dst):
    src.write_bytes(b"hello world")
    os.utime(src, (1_700_000_000, 1_700_000_000))
    result = copy_file(src, dst, chunk_size=4)
    assert dst.read_bytes() == b"hello world"
    assert int(dst.stat().st_mtime) == 1_700_000_000
    assert result.bytes_copied == 11
    assert result.sha256 == hashlib.sha256(b"hello world").hexdigest()


def test_refuses_existing_destination(src, dst):
    dst.write_text("keep")
    with pytest.raises(CopyError, match="exists"):
        copy_file(src, dst)
    assert dst.read_text() == "keep"
    assert list(dst.parent.glob(".usbcopy.*.part")) == []


def test_failure_never_leaves_partial_or_final_file(src, dst, monkeypatch):
    def _boom(*args, **kwargs):
        raise CopyError("hash mismatch")

    monkeypatch.setattr(copier, "_verify", _boom)
    with pytest.raises(CopyError):
        copy_file(src, dst)
    assert not dst.exists()
    assert list(dst.parent.glob(".usbcopy.*.part")) == []


def test_source_content_unchanged(src, dst):
    src.write_bytes(b"source stays put")
    os.utime(src, (1_700_000_000, 1_700_000_000))
    before = src.read_bytes()
    mode_before = stat.S_IMODE(src.stat().st_mode)

    copy_file(src, dst)

    assert src.read_bytes() == before
    assert int(src.stat().st_mtime) == 1_700_000_000
    assert stat.S_IMODE(src.stat().st_mode) == mode_before


def test_large_file_streams_in_chunks(src, dst):
    payload = b"x" * (3 * 1024 * 1024 + 17)
    src.write_bytes(payload)
    result = copy_file(src, dst, chunk_size=1024 * 1024)
    assert dst.stat().st_size == src.stat().st_size == result.bytes_copied
    assert result.sha256 == hashlib.sha256(payload).hexdigest()


def test_final_mode_is_0644(src, dst):
    previous_umask = os.umask(0o077)
    try:
        copy_file(src, dst)
    finally:
        os.umask(previous_umask)

    assert stat.S_IMODE(dst.stat().st_mode) == 0o644


def test_rejects_non_positive_chunk_size(src, dst):
    with pytest.raises(ValueError):
        copy_file(src, dst, chunk_size=0)
    assert not dst.exists()
    assert list(dst.parent.glob(".usbcopy.*.part")) == []
