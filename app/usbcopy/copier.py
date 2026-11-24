"""Single-file copy engine for usbcopy.

This module is the only place that writes user data. The source is opened
read-only and is never renamed, deleted, or had its mode or timestamps
changed. Data is streamed into a uniquely named temporary file in the
destination directory, verified, fsynced, and then atomically published under
the final name without overwriting an existing destination. A failure never
leaves a partial file under the final name.
"""

from __future__ import annotations

import hashlib
import logging
import os
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

DEFAULT_CHUNK_SIZE = 8 * 1024 * 1024
_VERIFY_CHUNK_SIZE = 1024 * 1024
_FILE_MODE = 0o644
_TEMP_TEMPLATE = ".usbcopy.{token}.part"

logger = logging.getLogger(__name__)


class CopyError(Exception):
    """Raised when a file cannot be copied safely."""


@dataclass(frozen=True)
class CopyResult:
    sha256: str
    bytes_copied: int


def _verify(path: Path, expected_sha256: str) -> None:
    """Re-hash ``path`` and raise ``CopyError`` when it does not match."""
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(_VERIFY_CHUNK_SIZE)
            if not chunk:
                break
            digest.update(chunk)
    if digest.hexdigest() != expected_sha256:
        raise CopyError("hash mismatch")


def _fsync_directory(directory: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    fd = os.open(directory, flags)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _temp_path(destination: Path) -> Path:
    name = _TEMP_TEMPLATE.format(token=uuid.uuid4().hex)
    return destination.parent / name


def _publish(temp_path: Path, destination: Path) -> None:
    """Publish the temp file without ever replacing an existing entry.

    ``os.link`` fails atomically with ``FileExistsError`` when the destination
    name exists, unlike ``os.replace`` which would silently replace it.
    """
    try:
        os.link(temp_path, destination)
    except FileExistsError as exc:
        raise CopyError(f"destination already exists: {destination}") from exc
    try:
        os.unlink(temp_path)
    except OSError:
        logger.warning(
            "published %s but could not remove temporary file %s",
            destination,
            temp_path,
            exc_info=True,
        )


def copy_file(
    source: Path,
    destination: Path,
    *,
    chunk_size: int = DEFAULT_CHUNK_SIZE,
    verify_sha256: bool = True,
    preserve_mtime: bool = True,
    on_temp: Callable[[Path], None] | None = None,
) -> CopyResult:
    """Copy ``source`` to ``destination`` safely and return its SHA-256.

    The destination must not already exist. The copy is written to a
    ``.usbcopy.<uuid>.part`` file in the destination directory, fsynced, and
    verified. Metadata is applied to the temp file, which is then published
    with a no-overwrite hard link. Any failure removes the temporary file and
    re-raises; the destination name is never left holding partial content.

    When ``on_temp`` is given it is called with the temporary file path
    immediately after that file is created and before streaming starts. If the
    callback raises, the temporary file is still removed before the exception
    is re-raised.
    """
    source = Path(source)
    destination = Path(destination)

    if chunk_size <= 0:
        raise ValueError("chunk_size must be positive")
    if os.path.lexists(destination):
        raise CopyError(f"destination already exists: {destination}")

    source_stat = source.stat()
    temp_path = _temp_path(destination)
    digest = hashlib.sha256()
    bytes_copied = 0

    try:
        fd = os.open(
            temp_path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            _FILE_MODE,
        )
        try:
            os.fchmod(fd, _FILE_MODE)
            temp_file = os.fdopen(fd, "wb")
            fd = -1
            with temp_file:
                if on_temp is not None:
                    on_temp(temp_path)
                with open(source, "rb") as source_file:
                    while True:
                        chunk = source_file.read(chunk_size)
                        if not chunk:
                            break
                        digest.update(chunk)
                        temp_file.write(chunk)
                        bytes_copied += len(chunk)
                temp_file.flush()
                os.fsync(temp_file.fileno())
        finally:
            if fd != -1:
                os.close(fd)

        if verify_sha256:
            _verify(temp_path, digest.hexdigest())

        if preserve_mtime:
            os.utime(
                temp_path,
                ns=(source_stat.st_atime_ns, source_stat.st_mtime_ns),
            )
        os.chmod(temp_path, _FILE_MODE)

        _publish(temp_path, destination)

        try:
            _fsync_directory(destination.parent)
        except OSError:
            logger.warning(
                "published %s but could not fsync directory %s",
                destination,
                destination.parent,
                exc_info=True,
            )
    except BaseException:
        temp_path.unlink(missing_ok=True)
        raise

    return CopyResult(sha256=digest.hexdigest(), bytes_copied=bytes_copied)
