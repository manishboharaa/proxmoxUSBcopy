from __future__ import annotations

import hashlib
import logging
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


def test_publish_race_refuses_existing_destination(src, dst, monkeypatch):
    real_publish = copier._publish

    def _create_then_publish(temp_path, destination):
        destination.write_text("raced")
        real_publish(temp_path, destination)

    monkeypatch.setattr(copier, "_publish", _create_then_publish)
    with pytest.raises(CopyError, match="exists"):
        copy_file(src, dst)
    assert dst.read_text() == "raced"
    assert list(dst.parent.glob(".usbcopy.*.part")) == []


def test_directory_fsync_failure_still_returns_success(src, dst, monkeypatch, caplog):
    def _boom(directory):
        raise OSError("fsync failed")

    monkeypatch.setattr(copier, "_fsync_directory", _boom)
    with caplog.at_level(logging.WARNING, logger="usbcopy.copier"):
        result = copy_file(src, dst)

    assert dst.read_bytes() == b"payload"
    assert result.bytes_copied == len(b"payload")
    assert result.sha256 == hashlib.sha256(b"payload").hexdigest()
    assert "fsync" in caplog.text.lower()


def test_verify_detects_hash_mismatch(tmp_path):
    path = tmp_path / "verified.bin"
    path.write_bytes(b"hello world")
    with pytest.raises(CopyError, match="hash mismatch"):
        copier._verify(path, "0" * 64)


def test_verify_receives_temp_path_and_source_digest(src, dst, monkeypatch):
    payload = b"spy payload"
    src.write_bytes(payload)
    seen = {}
    real_verify = copier._verify

    def _spy(path, expected_sha256):
        seen["path"] = Path(path)
        seen["sha256"] = expected_sha256
        real_verify(path, expected_sha256)

    monkeypatch.setattr(copier, "_verify", _spy)
    result = copy_file(src, dst)

    temp_path = seen["path"]
    assert temp_path.parent == dst.parent
    assert temp_path.name.startswith(".usbcopy.")
    assert temp_path.name.endswith(".part")
    assert seen["sha256"] == hashlib.sha256(payload).hexdigest() == result.sha256
    assert not temp_path.exists()


def test_verify_disabled_skips_verification(src, dst, monkeypatch):
    calls = []

    def _fail(*args, **kwargs):
        calls.append(args)
        raise CopyError("hash mismatch")

    monkeypatch.setattr(copier, "_verify", _fail)
    result = copy_file(src, dst, verify_sha256=False)

    assert calls == []
    assert dst.read_bytes() == b"payload"
    assert result.bytes_copied == len(b"payload")


def test_preserve_mtime_false_does_not_force_mtime(src, dst):
    src.write_bytes(b"no mtime")
    os.utime(src, (1_700_000_000, 1_700_000_000))
    copy_file(src, dst, preserve_mtime=False)
    assert dst.read_bytes() == b"no mtime"
    assert int(dst.stat().st_mtime) != 1_700_000_000


def test_on_temp_callback_receives_temp_path_and_success_removes_it(src, dst):
    seen: list[Path] = []

    def capture(path: Path) -> None:
        assert path.exists()
        assert path.parent == dst.parent
        seen.append(path)

    result = copy_file(src, dst, on_temp=capture)

    assert len(seen) == 1
    temp_path = seen[0]
    assert temp_path.parent == dst.parent
    assert temp_path.name.startswith(".usbcopy.")
    assert temp_path.name.endswith(".part")
    assert not temp_path.exists()
    assert dst.read_bytes() == b"payload"
    assert result.bytes_copied == len(b"payload")


def test_on_temp_failure_cleans_temp_and_reraises(src, dst):
    seen: list[Path] = []

    def boom(path: Path) -> None:
        seen.append(path)
        raise RuntimeError("callback failed")

    with pytest.raises(RuntimeError, match="callback failed"):
        copy_file(src, dst, on_temp=boom)

    assert len(seen) == 1
    assert not dst.exists()
    assert list(dst.parent.glob(".usbcopy.*.part")) == []


def test_copy_file_reports_per_chunk_progress(tmp_path):
    src = tmp_path / "src.bin"
    payload = bytes(range(256)) * 40  # 10,240 bytes
    src.write_bytes(payload)
    progress = []

    result = copy_file(src, tmp_path / "dst.bin", chunk_size=1024,
                       on_progress=progress.append)

    assert result.bytes_copied == len(payload)
    assert progress, "on_progress was never called"
    assert progress[0] == 1024
    assert progress[-1] == len(payload)
    assert progress == sorted(progress)


def test_copy_file_progress_still_publishes_without_callback(tmp_path):
    src = tmp_path / "src.bin"
    payload = b"no callback payload"
    src.write_bytes(payload)

    result = copy_file(src, tmp_path / "dst.bin", chunk_size=4)

    assert result.bytes_copied == len(payload)
    assert (tmp_path / "dst.bin").read_bytes() == payload
