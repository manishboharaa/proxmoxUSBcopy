"""Configuration loading and validation for usbcopy.

The runtime configuration lives in ``/etc/usbcopy/config.toml`` (see
DESIGN.md section 17). Configuration is read-only at runtime: this module
only loads and validates it.
"""

from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

DEFAULT_DB_PATH = Path("/var/lib/usbcopy/usbcopy.db")
DEFAULT_EVENTS_DIR = Path("/var/lib/usbcopy/events")
DEFAULT_MOUNTS_ROOT = Path("/mnt/usb")
DEFAULT_UPDATE_REPO = "manishboharaa/proxmoxUSBcopy"
DEFAULT_UPDATE_BRANCH = "main"
DEFAULT_UPDATE_CHECK_HOURS = 6

_VALID_MODES = ("review", "auto")
_REQUIRED_DESTINATIONS = ("movies", "series")


class ConfigError(ValueError):
    """Raised when the configuration file is missing, malformed, or invalid."""


@dataclass(frozen=True)
class Destination:
    key: str
    path: Path


@dataclass(frozen=True)
class Config:
    port: int
    username: str
    password_hash: str
    session_secret: str
    default_folder: str
    default_mode: Literal["review", "auto"]
    auto_enabled: bool
    auto_destination: str
    verify_sha256: bool
    chunk_size_mb: int
    retries: int
    preserve_mtime: bool
    destinations: dict[str, Destination]
    db_path: Path
    events_dir: Path
    mounts_root: Path
    reconcile_minutes: int
    skip_hidden_root_dirs: bool
    config_path: Path | None = None
    update_repo: str = DEFAULT_UPDATE_REPO
    update_branch: str = DEFAULT_UPDATE_BRANCH
    update_check_interval_hours: int = DEFAULT_UPDATE_CHECK_HOURS
    update_enabled: bool = True


def load_config(path: Path) -> Config:
    """Load and validate a TOML configuration file."""
    try:
        with Path(path).open("rb") as handle:
            data = tomllib.load(handle)
    except FileNotFoundError as exc:
        raise ConfigError(f"config file not found: {path}") from exc
    except OSError as exc:
        raise ConfigError(f"cannot read config file {path}: {exc}") from exc
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"invalid TOML in {path}: {exc}") from exc

    server = _table(data, "server")
    auth = _table(data, "auth")
    source = _table(data, "source")
    mode = _table(data, "mode")
    copy = _table(data, "copy")
    scan = _table(data, "scan")

    port = _require_int(server, "port", "server.port")
    if not 1 <= port <= 65535:
        raise ConfigError(f"server.port must be between 1 and 65535, got {port}")

    username = _require_str(auth, "username", "auth.username")
    password_hash = _require_str(auth, "password_hash", "auth.password_hash")
    session_secret = _require_str(auth, "session_secret", "auth.session_secret")

    default_folder = _require_str(source, "default_folder", "source.default_folder")

    default_mode = _require_str(mode, "default", "mode.default")
    if default_mode not in _VALID_MODES:
        raise ConfigError(
            f"mode.default must be 'review' or 'auto', got {default_mode!r}"
        )
    auto_enabled = _require_bool(mode, "auto_enabled", "mode.auto_enabled")
    auto_destination = _require_str(mode, "auto_destination", "mode.auto_destination")

    verify_sha256 = _require_bool(copy, "verify_sha256", "copy.verify_sha256")
    chunk_size_mb = _require_int(copy, "chunk_size_mb", "copy.chunk_size_mb")
    if chunk_size_mb <= 0:
        raise ConfigError(
            f"copy.chunk_size_mb must be greater than 0, got {chunk_size_mb}"
        )
    retries = _require_int(copy, "retries", "copy.retries")
    if retries < 0:
        raise ConfigError(f"copy.retries must be 0 or greater, got {retries}")
    preserve_mtime = _require_bool(copy, "preserve_mtime", "copy.preserve_mtime")

    destinations = _parse_destinations(data)
    for key in _REQUIRED_DESTINATIONS:
        if key not in destinations:
            raise ConfigError(f"destinations.{key} is required")

    if auto_enabled and not default_folder.strip():
        raise ConfigError(
            "Auto mode requires a source folder: source.default_folder is empty"
        )
    if auto_destination not in destinations:
        raise ConfigError(
            "mode.auto_destination "
            f"{auto_destination!r} is not a configured destination"
        )

    reconcile_minutes = _require_int(
        scan, "reconcile_minutes", "scan.reconcile_minutes"
    )
    skip_hidden_root_dirs = _require_bool(
        scan, "skip_hidden_root_dirs", "scan.skip_hidden_root_dirs"
    )

    paths = _table(data, "paths")
    db_path = _optional_path(paths, "db_path", DEFAULT_DB_PATH)
    events_dir = _optional_path(paths, "events_dir", DEFAULT_EVENTS_DIR)
    mounts_root = _optional_path(paths, "mounts_root", DEFAULT_MOUNTS_ROOT)

    update = _table(data, "update")
    update_repo = _optional_str(
        update, "repo", DEFAULT_UPDATE_REPO, "update.repo"
    )
    update_branch = _optional_str(
        update, "branch", DEFAULT_UPDATE_BRANCH, "update.branch"
    )
    update_hours = _optional_int(
        update, "check_interval_hours", DEFAULT_UPDATE_CHECK_HOURS, "update.check_interval_hours"
    )
    update_enabled = _optional_bool(
        update, "enabled", True, "update.enabled"
    )

    return Config(
        port=port,
        username=username,
        password_hash=password_hash,
        session_secret=session_secret,
        default_folder=default_folder,
        default_mode=default_mode,
        auto_enabled=auto_enabled,
        auto_destination=auto_destination,
        verify_sha256=verify_sha256,
        chunk_size_mb=chunk_size_mb,
        retries=retries,
        preserve_mtime=preserve_mtime,
        destinations=destinations,
        db_path=db_path,
        events_dir=events_dir,
        mounts_root=mounts_root,
        reconcile_minutes=reconcile_minutes,
        skip_hidden_root_dirs=skip_hidden_root_dirs,
        config_path=Path(path),
        update_repo=update_repo,
        update_branch=update_branch,
        update_check_interval_hours=update_hours,
        update_enabled=update_enabled,
    )


def _table(data: dict[str, Any], name: str) -> dict[str, Any]:
    value = data.get(name, {})
    if not isinstance(value, dict):
        raise ConfigError(f"{name} must be a TOML table")
    return value


def _require_str(table: dict[str, Any], key: str, field: str) -> str:
    if key not in table:
        raise ConfigError(f"missing required option: {field}")
    value = table[key]
    if not isinstance(value, str):
        raise ConfigError(f"{field} must be a string")
    return value


def _require_bool(table: dict[str, Any], key: str, field: str) -> bool:
    if key not in table:
        raise ConfigError(f"missing required option: {field}")
    value = table[key]
    if not isinstance(value, bool):
        raise ConfigError(f"{field} must be a boolean")
    return value


def _require_int(table: dict[str, Any], key: str, field: str) -> int:
    if key not in table:
        raise ConfigError(f"missing required option: {field}")
    value = table[key]
    if isinstance(value, bool) or not isinstance(value, int):
        raise ConfigError(f"{field} must be an integer")
    return value


def _parse_destinations(data: dict[str, Any]) -> dict[str, Destination]:
    raw_destinations = _table(data, "destinations")
    destinations: dict[str, Destination] = {}
    for key, value in raw_destinations.items():
        if not isinstance(value, dict):
            raise ConfigError(f"destinations.{key} must be a TOML table")
        raw_path = value.get("path")
        if not isinstance(raw_path, str) or not raw_path.strip():
            raise ConfigError(
                f"destinations.{key}.path must be a non-empty absolute path"
            )
        destination_path = Path(raw_path)
        if not destination_path.is_absolute():
            raise ConfigError(
                f"destinations.{key}.path must be an absolute path, got {raw_path!r}"
            )
        destinations[key] = Destination(key=key, path=destination_path)
    return destinations


def _optional_path(table: dict[str, Any], key: str, default: Path) -> Path:
    if key not in table:
        return default
    value = table[key]
    if not isinstance(value, str) or not value.strip():
        raise ConfigError(f"paths.{key} must be a non-empty string")
    return Path(value)


def set_password_hash(path: Path, new_hash: str) -> None:
    """Replace the ``auth.password_hash`` line in a config file atomically.

    Only that one line changes; every other byte of the file is preserved so
    comments and ordering survive. The file must be writable by the calling
    user, which the installer arranges by owning it with the ``usbcopy``
    account. The replacement file is written next to the target and renamed
    into place, so a crash can never leave a half-written config.
    """
    path = Path(path)
    if not new_hash.startswith("$2"):
        raise ConfigError("refusing to store a non-bcrypt password hash")
    try:
        raw = path.read_text(encoding="utf-8")
        mode = path.stat().st_mode & 0o777
    except (OSError, UnicodeDecodeError) as exc:
        raise ConfigError(f"cannot read config file {path}: {exc}") from exc

    replaced = False
    lines = raw.splitlines(keepends=True)
    for index, line in enumerate(lines):
        if line.lstrip().startswith("password_hash"):
            newline = "\n" if line.endswith("\n") else ""
            lines[index] = f'password_hash = "{new_hash}"{newline}'
            replaced = True
            break
    if not replaced:
        raise ConfigError(f"config file {path} has no auth.password_hash line")

    tmp_path = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        with open(tmp_path, "w", encoding="utf-8") as handle:
            handle.write("".join(lines))
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_path, mode)
        os.replace(tmp_path, path)
    except OSError as exc:
        tmp_path.unlink(missing_ok=True)
        raise ConfigError(f"cannot write config file {path}: {exc}") from exc


def _optional_str(
    table: dict[str, Any], key: str, default: str, field: str
) -> str:
    if key not in table:
        return default
    value = table[key]
    if not isinstance(value, str) or not value.strip():
        raise ConfigError(f"{field} must be a non-empty string")
    return value


def _optional_int(
    table: dict[str, Any], key: str, default: int, field: str
) -> int:
    if key not in table:
        return default
    value = table[key]
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ConfigError(f"{field} must be a non-negative integer")
    return value


def _optional_bool(
    table: dict[str, Any], key: str, default: bool, field: str
) -> bool:
    if key not in table:
        return default
    value = table[key]
    if not isinstance(value, bool):
        raise ConfigError(f"{field} must be true or false")
    return value
