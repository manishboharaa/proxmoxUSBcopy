"""Check GitHub for a newer dashboard version.

The dashboard runs inside the unprivileged CT, so it can never run the host
installer itself. What it can do is notice that a newer version was pushed
and tell the admin which command to run on the Proxmox host. The check only
reads a small ``VERSION`` text file from the repository and is cached so a
page refresh never triggers a request storm.

Everything here fails quiet: an unreachable network must never break the
dashboard or nag the admin.
"""

from __future__ import annotations

import logging
import threading
import time
import urllib.error
import urllib.request

from usbcopy.config import Config

logger = logging.getLogger(__name__)

_VERSION_TIMEOUT_SECONDS = 3.0
_CHECK_INTERVAL_SECONDS = 60.0  # floor for repeated checks within one process

_UPDATE_COMMAND_TEMPLATE = (
    "curl -fsSL https://raw.githubusercontent.com/{repo}/{branch}"
    "/setup/install.sh | bash -s -- --update"
)

_lock = threading.Lock()
_cached_result: dict | None = None
_checked_at: float = 0.0


def remote_version_url(repo: str, branch: str) -> str:
    """Return the raw URL of the ``VERSION`` file on the given branch."""
    return (
        f"https://raw.githubusercontent.com/{repo}/{branch}"
        "/app/usbcopy/VERSION"
    )


def update_command(repo: str, branch: str) -> str:
    """Return the one-line installer command for the Proxmox host shell."""
    return _UPDATE_COMMAND_TEMPLATE.format(repo=repo, branch=branch)


def is_newer(candidate: str, current: str) -> bool:
    """Return whether ``candidate`` is a strictly higher dotted version.

    Non-numeric parts compare equal-safe: a malformed remote version never
    triggers an update notice.
    """
    candidate = candidate.strip()
    current = current.strip()
    if not candidate or not current:
        return False
    candidate_parts = candidate.split(".")
    current_parts = current.split(".")
    if len(candidate_parts) != 3 or len(current_parts) != 3:
        return False
    if not all(part.isdigit() for part in candidate_parts + current_parts):
        return False
    return [int(part) for part in candidate_parts] > [
        int(part) for part in current_parts
    ]


def fetch_remote_version(
    repo: str, branch: str, *, timeout: float = _VERSION_TIMEOUT_SECONDS
) -> str | None:
    """Read the remote ``VERSION`` file; ``None`` when unreachable."""
    url = remote_version_url(repo, branch)
    try:
        with urllib.request.urlopen(
            url, timeout=timeout
        ) as response:
            text = response.read(64).decode("utf-8", errors="replace")
    except (urllib.error.URLError, OSError, ValueError) as exc:
        logger.info("update check failed: %s", exc)
        return None
    candidate = text.strip()
    if not candidate or len(candidate.split(".")) != 3:
        logger.info("update check ignored malformed remote version: %r", text)
        return None
    return candidate


def check_for_update(config: Config, *, force: bool = False) -> dict:
    """Return the update status, using the cache within the check interval.

    The response never raises: network problems produce
    ``update_available: false`` with an ``error`` note, and the last good
    answer is reused until the interval expires.
    """
    global _cached_result, _checked_at

    if not config.update_enabled:
        return {
            "update_available": False,
            "enabled": False,
            "current_version": _current_version(),
        }

    from usbcopy import __version__

    now = time.monotonic()
    with _lock:
        max_age = max(
            float(config.update_check_interval_hours) * 3600.0,
            _CHECK_INTERVAL_SECONDS,
        )
        if (
            not force
            and _cached_result is not None
            and now - _checked_at < max_age
        ):
            return _cached_result

    remote = fetch_remote_version(config.update_repo, config.update_branch)
    result = {
        "update_available": remote is not None
        and is_newer(remote, __version__),
        "enabled": True,
        "current_version": __version__,
        "latest_version": remote,
        "command": update_command(config.update_repo, config.update_branch),
        "error": remote is None,
    }
    with _lock:
        _cached_result = result
        _checked_at = time.monotonic()
    return result


def reset_cache() -> None:
    """Drop the cached answer (used by tests)."""
    global _cached_result, _checked_at
    with _lock:
        _cached_result = None
        _checked_at = 0.0


def _current_version() -> str:
    from usbcopy import __version__

    return __version__
