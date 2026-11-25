from __future__ import annotations

import pytest

from usbcopy import __version__, update_check
from usbcopy.config import load_config


@pytest.fixture(autouse=True)
def _fresh_cache():
    update_check.reset_cache()
    yield
    update_check.reset_cache()


def test_is_newer_compares_numeric_parts():
    assert update_check.is_newer("1.2.0", "1.1.0") is True
    assert update_check.is_newer("1.1.1", "1.1.0") is True
    assert update_check.is_newer("2.0.0", "1.9.9") is True
    assert update_check.is_newer("1.1.0", "1.1.0") is False
    assert update_check.is_newer("1.0.9", "1.1.0") is False


def test_is_newer_never_triggers_on_malformed_versions():
    assert update_check.is_newer("", "1.1.0") is False
    assert update_check.is_newer("oops", "1.1.0") is False
    assert update_check.is_newer("1.2.3.4", "1.1.0") is False
    assert update_check.is_newer("1.2.3", "") is False


def test_fetch_remote_version_reads_and_strips(tmp_path, monkeypatch):
    class FakeResponse:
        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

        def read(self, amount):
            return b"1.2.0\n"

    calls: list[str] = []

    def fake_urlopen(url, timeout):
        calls.append(url)
        return FakeResponse()

    monkeypatch.setattr(update_check.urllib.request, "urlopen", fake_urlopen)

    assert update_check.fetch_remote_version("some/repo", "main") == "1.2.0"
    assert calls == [update_check.remote_version_url("some/repo", "main")]


def test_fetch_remote_version_returns_none_when_unreachable(monkeypatch):
    def fake_urlopen(url, timeout):
        raise OSError("no network")

    monkeypatch.setattr(update_check.urllib.request, "urlopen", fake_urlopen)

    assert update_check.fetch_remote_version("some/repo", "main") is None


def test_check_for_update_reports_newer_version(monkeypatch):
    monkeypatch.setattr(
        update_check, "fetch_remote_version", lambda repo, branch: "9.9.9"
    )
    config = load_config("config.example.toml")

    result = update_check.check_for_update(config)

    assert result["update_available"] is True
    assert result["current_version"] == __version__
    assert result["latest_version"] == "9.9.9"
    assert result["command"].endswith("| bash -s -- --update")
    assert "githubusercontent.com/manishboharaa/proxmoxUSBcopy/main" in result["command"]


def test_check_for_update_caches_within_interval(monkeypatch):
    config = load_config("config.example.toml")
    calls: list[str] = []

    def fake_fetch(repo, branch):
        calls.append(repo)
        return "1.2.0"

    monkeypatch.setattr(update_check, "fetch_remote_version", fake_fetch)

    update_check.check_for_update(config)
    update_check.check_for_update(config)

    assert len(calls) == 1


def test_check_for_update_fails_quiet(monkeypatch):
    config = load_config("config.example.toml")
    monkeypatch.setattr(
        update_check, "fetch_remote_version", lambda repo, branch: None
    )

    result = update_check.check_for_update(config, force=True)

    assert result["update_available"] is False
    assert result["error"] is True


def test_check_for_update_disabled(monkeypatch):
    config = load_config("config.example.toml")
    config = config.__class__(
        **{
            **{f.name: getattr(config, f.name) for f in config.__dataclass_fields__.values()},
            "update_enabled": False,
        }
    )
    monkeypatch.setattr(
        update_check,
        "fetch_remote_version",
        lambda repo, branch: pytest.fail("must not fetch when disabled"),
    )

    result = update_check.check_for_update(config, force=True)

    assert result["update_available"] is False
    assert result["enabled"] is False
