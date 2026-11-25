from __future__ import annotations

from pathlib import Path

import pytest

from usbcopy.config import (
    Config,
    ConfigError,
    Destination,
    load_config,
    set_password_hash,
)


def _toml_bool(value: bool) -> str:
    return "true" if value else "false"


def write_config(
    tmp_path: Path,
    *,
    movies: bool = True,
    series: bool = True,
    port: int = 8088,
    default_folder: str = "",
    default_mode: str = "review",
    auto_enabled: bool = False,
    auto_destination: str = "movies",
    chunk_size_mb: int = 8,
    retries: int = 3,
    movies_path: str = "/data/movies",
    series_path: str = "/data/series",
    paths: dict[str, str] | None = None,
) -> Path:
    lines = [
        "[server]",
        'host = "0.0.0.0"',
        f"port = {port}",
        "",
        "[auth]",
        'username = "admin"',
        'password_hash = "$2b$12$example"',
        'session_secret = "example-session-secret"',
        "",
        "[source]",
        f'default_folder = "{default_folder}"',
        "",
        "[mode]",
        f'default = "{default_mode}"',
        f"auto_enabled = {_toml_bool(auto_enabled)}",
        f'auto_destination = "{auto_destination}"',
        "",
        "[copy]",
        "verify_sha256 = true",
        f"chunk_size_mb = {chunk_size_mb}",
        f"retries = {retries}",
        "preserve_mtime = true",
        "",
    ]
    if movies:
        lines += ["[destinations.movies]", f'path = "{movies_path}"', ""]
    if series:
        lines += ["[destinations.series]", f'path = "{series_path}"', ""]
    lines += [
        "[scan]",
        "reconcile_minutes = 0",
        "skip_hidden_root_dirs = true",
        "",
    ]
    if paths is not None:
        lines.append("[paths]")
        for key, value in paths.items():
            lines.append(f'{key} = "{value}"')
        lines.append("")
    path = tmp_path / "config.toml"
    path.write_text("\n".join(lines), encoding="utf-8")
    return path


def test_loads_example_config(tmp_path):
    cfg = load_config(Path("config.example.toml"))
    assert cfg.port == 8088
    assert set(cfg.destinations) == {"movies", "series"}
    assert cfg.default_mode == "review"


def test_example_config_matches_design_defaults():
    cfg = load_config(Path("config.example.toml"))
    assert isinstance(cfg, Config)
    assert cfg.username == "admin"
    assert cfg.default_folder == ""
    assert cfg.auto_enabled is False
    assert cfg.auto_destination == "movies"
    assert cfg.verify_sha256 is True
    assert cfg.chunk_size_mb == 8
    assert cfg.retries == 3
    assert cfg.preserve_mtime is True
    assert cfg.reconcile_minutes == 0
    assert cfg.skip_hidden_root_dirs is True
    assert cfg.destinations["movies"] == Destination("movies", Path("/data/movies"))
    assert cfg.destinations["series"] == Destination("series", Path("/data/series"))


def test_paths_default_to_design_locations(tmp_path):
    cfg = load_config(write_config(tmp_path))
    assert cfg.db_path == Path("/var/lib/usbcopy/usbcopy.db")
    assert cfg.events_dir == Path("/var/lib/usbcopy/events")
    assert cfg.mounts_root == Path("/mnt/usb")


def test_paths_section_overrides_defaults(tmp_path):
    p = write_config(
        tmp_path,
        paths={
            "db_path": str(tmp_path / "usbcopy.db"),
            "events_dir": str(tmp_path / "events"),
            "mounts_root": str(tmp_path / "mnt"),
        },
    )
    cfg = load_config(p)
    assert cfg.db_path == tmp_path / "usbcopy.db"
    assert cfg.events_dir == tmp_path / "events"
    assert cfg.mounts_root == tmp_path / "mnt"


def test_missing_series_destination_raises(tmp_path):
    p = write_config(tmp_path, series=False)
    with pytest.raises(ConfigError, match="series"):
        load_config(p)


def test_missing_movies_destination_raises(tmp_path):
    p = write_config(tmp_path, movies=False)
    with pytest.raises(ConfigError, match="movies"):
        load_config(p)


def test_destination_path_must_be_absolute(tmp_path):
    p = write_config(tmp_path, movies_path="movies")
    with pytest.raises(ConfigError, match="movies"):
        load_config(p)


def test_destination_path_must_be_non_empty(tmp_path):
    p = write_config(tmp_path, series_path="")
    with pytest.raises(ConfigError, match="series"):
        load_config(p)


def test_auto_enabled_requires_source_folder(tmp_path):
    p = write_config(tmp_path, auto_enabled=True, default_folder="")
    with pytest.raises(ConfigError, match="Auto mode"):
        load_config(p)


def test_auto_enabled_with_source_folder_loads(tmp_path):
    p = write_config(tmp_path, auto_enabled=True, default_folder="Movies")
    assert load_config(p).auto_enabled is True


def test_port_must_be_free_range(tmp_path):
    p = write_config(tmp_path, port=70000)
    with pytest.raises(ConfigError, match="port"):
        load_config(p)


@pytest.mark.parametrize("port", [0, -1, 65536])
def test_port_out_of_range_raises(tmp_path, port):
    p = write_config(tmp_path, port=port)
    with pytest.raises(ConfigError, match="port"):
        load_config(p)


def test_invalid_default_mode_raises(tmp_path):
    p = write_config(tmp_path, default_mode="manual")
    with pytest.raises(ConfigError, match="mode"):
        load_config(p)


def test_auto_destination_must_exist(tmp_path):
    p = write_config(tmp_path, auto_destination="music")
    with pytest.raises(ConfigError, match="auto_destination"):
        load_config(p)


def test_chunk_size_must_be_positive(tmp_path):
    p = write_config(tmp_path, chunk_size_mb=0)
    with pytest.raises(ConfigError, match="chunk_size_mb"):
        load_config(p)


def test_retries_must_be_non_negative(tmp_path):
    p = write_config(tmp_path, retries=-1)
    with pytest.raises(ConfigError, match="retries"):
        load_config(p)


def test_missing_config_file_raises(tmp_path):
    with pytest.raises(ConfigError, match="not found"):
        load_config(tmp_path / "missing.toml")


def test_invalid_toml_raises(tmp_path):
    p = tmp_path / "bad.toml"
    p.write_text("[server\nport = 8088", encoding="utf-8")
    with pytest.raises(ConfigError, match="TOML"):
        load_config(p)


def test_set_password_hash_replaces_only_the_hash_line(tmp_path):
    config_path = tmp_path / "config.toml"
    config_path.write_text(
        '[auth]\nusername = "admin"\n'
        'password_hash = "$2b$12$old"\n'
        'session_secret = "keep-me"\n',
        encoding="utf-8",
    )
    new_hash = "$2b$12$" + "a" * 53

    set_password_hash(config_path, new_hash)

    text = config_path.read_text(encoding="utf-8")
    assert f'password_hash = "{new_hash}"' in text
    assert 'username = "admin"' in text
    assert 'session_secret = "keep-me"' in text
    assert "$2b$12$old" not in text


def test_set_password_hash_preserves_mode(tmp_path):
    config_path = tmp_path / "config.toml"
    config_path.write_text('password_hash = "$2b$12$old"\n', encoding="utf-8")
    config_path.chmod(0o600)

    set_password_hash(config_path, "$2b$12$" + "b" * 53)

    assert config_path.stat().st_mode & 0o777 == 0o600


def test_set_password_hash_rejects_non_bcrypt(tmp_path):
    config_path = tmp_path / "config.toml"
    config_path.write_text('password_hash = "$2b$12$old"\n', encoding="utf-8")

    with pytest.raises(ConfigError, match="non-bcrypt"):
        set_password_hash(config_path, "plaintext")


def test_set_password_hash_requires_an_existing_hash_line(tmp_path):
    config_path = tmp_path / "config.toml"
    config_path.write_text("[server]\nport = 8088\n", encoding="utf-8")

    with pytest.raises(ConfigError, match="password_hash"):
        set_password_hash(config_path, "$2b$12$" + "c" * 53)


def test_update_settings_default_when_table_missing(tmp_path):
    path = write_config(tmp_path)

    config = load_config(path)

    assert config.update_repo == "manishboharaa/proxmoxUSBcopy"
    assert config.update_branch == "main"
    assert config.update_check_interval_hours == 6
    assert config.update_enabled is True


def test_update_settings_parse_from_toml(tmp_path):
    path = write_config(tmp_path)
    path.write_text(
        path.read_text(encoding="utf-8")
        + '\n[update]\nrepo = "someone/else"\nbranch = "dev"\n'
        "check_interval_hours = 12\nenabled = false\n",
        encoding="utf-8",
    )

    config = load_config(path)

    assert config.update_repo == "someone/else"
    assert config.update_branch == "dev"
    assert config.update_check_interval_hours == 12
    assert config.update_enabled is False
