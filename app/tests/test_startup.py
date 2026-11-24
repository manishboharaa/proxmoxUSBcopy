from __future__ import annotations

import json
import logging
import threading
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from usbcopy import app as app_module
from usbcopy import main as main_module
from usbcopy.app import cleanup_recorded_temps, create_app, startup_recovery
from usbcopy.auth import hash_password
from usbcopy.config import Config, Destination
from usbcopy.db import open_db, table_names
from usbcopy.events import EventSpoolWatcher

PASSWORD = "correct horse battery staple"
EVENT_TS = "2026-11-24T10:00:00Z"


@pytest.fixture(scope="module")
def password_hash() -> str:
    return hash_password(PASSWORD)


@pytest.fixture
def config(tmp_path: Path, password_hash: str) -> Config:
    movies = tmp_path / "dest" / "movies"
    series = tmp_path / "dest" / "series"
    movies.mkdir(parents=True)
    series.mkdir(parents=True)
    return Config(
        port=8088,
        username="admin",
        password_hash=password_hash,
        session_secret="test-session-secret",
        default_folder="",
        default_mode="review",
        auto_enabled=False,
        auto_destination="movies",
        verify_sha256=True,
        chunk_size_mb=8,
        retries=3,
        preserve_mtime=True,
        destinations={
            "movies": Destination(key="movies", path=movies),
            "series": Destination(key="series", path=series),
        },
        db_path=tmp_path / "usbcopy.db",
        events_dir=tmp_path / "events",
        mounts_root=tmp_path / "mounts",
        reconcile_minutes=0,
        skip_hidden_root_dirs=True,
    )


def write_event(
    directory: Path,
    *,
    uuid: str = "ABCD-1234",
    action: str = "add",
    mountpoint: Path | None = None,
    name: str = "event.json",
) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    payload = {
        "version": 1,
        "action": action,
        "uuid": uuid,
        "label": "Test Drive",
        "serial": "SN123",
        "device": "/dev/sdb1",
        "mountpoint": str(mountpoint if mountpoint is not None else directory.parent / uuid),
        "fs_type": "ext4",
        "ts": EVENT_TS,
    }
    path = directory / name
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


def insert_run(
    conn,
    *,
    status: str = "running",
    item_status: str = "running",
    temp_path: Path | None = None,
) -> int:
    cursor = conn.execute(
        "INSERT INTO runs (drive_id, destination_key, mode, status) "
        "VALUES (1, 'movies', 'review', ?)",
        (status,),
    )
    run_id = int(cursor.lastrowid)
    conn.execute(
        "INSERT INTO run_items "
        "(run_id, rel_path, size, dest_rel_path, status, temp_path) "
        "VALUES (?, 'Movies/a.mkv', 3, 'a.mkv', ?, ?)",
        (run_id, item_status, str(temp_path) if temp_path is not None else None),
    )
    conn.commit()
    return run_id


def count(conn, sql: str) -> int:
    return int(conn.execute(sql).fetchone()[0])


# ---------------------------------------------------------------------------
# startup_recovery / cleanup_recorded_temps
# ---------------------------------------------------------------------------


def test_startup_marks_running_runs_interrupted(conn, config: Config):
    run_id = insert_run(conn, status="running", item_status="running")

    stats = startup_recovery(conn, config)

    assert stats["orphans"] == 1
    assert set(stats) == {"orphans", "temps", "events", "drives"}
    assert (
        conn.execute("SELECT status FROM runs WHERE id=?", (run_id,)).fetchone()[0]
        == "interrupted"
    )
    assert (
        conn.execute(
            "SELECT status FROM run_items WHERE run_id=?", (run_id,)
        ).fetchone()[0]
        == "interrupted"
    )


def test_startup_removes_recorded_temp_only(conn, config: Config, tmp_path: Path):
    keep = tmp_path / "unknown.part"
    keep.write_text("x")
    recorded = tmp_path / ".usbcopy.abc.part"
    recorded.write_text("x")
    insert_run(conn, status="interrupted", item_status="interrupted", temp_path=recorded)

    assert cleanup_recorded_temps(conn) == 1

    assert recorded.exists() is False
    assert keep.exists() is True


def test_cleanup_tolerates_missing_recorded_temp(conn, config: Config, tmp_path: Path):
    insert_run(
        conn,
        status="interrupted",
        item_status="interrupted",
        temp_path=tmp_path / "gone.part",
    )

    assert cleanup_recorded_temps(conn) == 0


def test_startup_reports_removed_temp_count(conn, config: Config, tmp_path: Path):
    recorded = tmp_path / ".usbcopy.def.part"
    recorded.write_text("x")
    insert_run(conn, status="interrupted", item_status="interrupted", temp_path=recorded)

    assert startup_recovery(conn, config)["temps"] == 1
    assert recorded.exists() is False


def test_startup_processes_pending_events(conn, config: Config, tmp_path: Path):
    mountpoint = tmp_path / "event-mount" / "ABCD-1234"
    mountpoint.mkdir(parents=True)
    (mountpoint / "movie.mkv").write_bytes(b"hi")
    write_event(config.events_dir, uuid="ABCD-1234", mountpoint=mountpoint)

    stats = startup_recovery(conn, config)

    assert stats["events"] == 1
    assert list(config.events_dir.glob("*.json")) == []
    row = conn.execute(
        "SELECT present FROM drives WHERE uuid = 'ABCD-1234'"
    ).fetchone()
    assert row is not None and row[0] == 1
    assert count(conn, "SELECT count(*) FROM inventories") == 1


def test_startup_tolerates_event_for_missing_mountpoint(conn, config: Config):
    write_event(
        config.events_dir,
        uuid="GONE-0001",
        mountpoint=config.mounts_root / "GONE-0001",
    )

    stats = startup_recovery(conn, config)

    assert stats["events"] == 1
    assert list(config.events_dir.glob("*.json")) == []


def test_drive_callback_creates_inventory(conn, config: Config, sample_tree: Path):
    config.mounts_root.mkdir(parents=True)
    (config.mounts_root / "ABCD-1234").symlink_to(sample_tree)

    stats = startup_recovery(conn, config)

    assert stats["drives"] == 1
    assert count(conn, "SELECT count(*) FROM inventories") == 1


def test_startup_scans_drive_once_when_event_and_mount_duplicate(
    conn, config: Config
):
    mountpoint = config.mounts_root / "ABCD-1234"
    mountpoint.mkdir(parents=True)
    (mountpoint / "movie.mkv").write_bytes(b"hi")
    write_event(config.events_dir, uuid="ABCD-1234", mountpoint=mountpoint)

    stats = startup_recovery(conn, config)

    assert stats == {"orphans": 0, "temps": 0, "events": 1, "drives": 1}
    assert count(conn, "SELECT count(*) FROM inventories") == 1


def test_event_written_during_recovery_is_processed_before_startup_completes(
    conn, config: Config, monkeypatch, tmp_path: Path
):
    config.events_dir.mkdir(parents=True)
    mountpoint = tmp_path / "late-mount" / "ABCD-1234"
    mountpoint.mkdir(parents=True)
    (mountpoint / "movie.mkv").write_bytes(b"hi")
    real_scan_mounted = app_module.scan_mounted

    def scan_mounted_then_write(*args, **kwargs):
        found = real_scan_mounted(*args, **kwargs)
        write_event(
            config.events_dir,
            uuid="ABCD-1234",
            mountpoint=mountpoint,
            name="late.json",
        )
        return found

    monkeypatch.setattr(app_module, "scan_mounted", scan_mounted_then_write)
    app = create_app(config)

    with TestClient(app) as client:
        assert client.get("/healthz").status_code == 200
        row = conn.execute(
            "SELECT present FROM drives WHERE uuid = 'ABCD-1234'"
        ).fetchone()
        assert row is not None and row[0] == 1
        assert count(conn, "SELECT count(*) FROM inventories") == 1
        assert app.state.startup_stats["events"] >= 1
        assert list(config.events_dir.glob("*.json")) == []


# ---------------------------------------------------------------------------
# EventSpoolWatcher miss tolerance
# ---------------------------------------------------------------------------


def test_watcher_start_with_missing_spool_is_noop(tmp_path: Path, caplog):
    watcher = EventSpoolWatcher(tmp_path / "missing", lambda path: None)

    with caplog.at_level(logging.WARNING, logger="usbcopy.events"):
        watcher.start()

    assert watcher._observer is None
    assert "not available" in caplog.text
    watcher.stop()


# ---------------------------------------------------------------------------
# Live watcher bridge
# ---------------------------------------------------------------------------


def test_live_handler_processes_spool_event(conn, config: Config, tmp_path: Path):
    mountpoint = tmp_path / "live-mount" / "ABCD-1234"
    mountpoint.mkdir(parents=True)
    (mountpoint / "movie.mkv").write_bytes(b"hi")
    path = write_event(config.events_dir, uuid="ABCD-1234", mountpoint=mountpoint)
    handler = app_module._LiveEventHandler(config, None)

    handler.handle(path)

    assert path.exists() is False
    assert count(conn, "SELECT count(*) FROM inventories") == 1


def test_live_handler_ignores_malformed_event(config: Config, caplog):
    config.events_dir.mkdir(parents=True)
    bad = config.events_dir / "bad.json"
    bad.write_text("{not json", encoding="utf-8")
    handler = app_module._LiveEventHandler(config, None)

    with caplog.at_level(logging.WARNING, logger="usbcopy.app"):
        handler.handle(bad)

    assert bad.exists() is True
    assert "malformed" in caplog.text


def test_live_handlers_apply_same_file_once(conn, config: Config, tmp_path: Path):
    mountpoint = tmp_path / "shared-mount" / "ABCD-1234"
    mountpoint.mkdir(parents=True)
    (mountpoint / "movie.mkv").write_bytes(b"hi")
    path = write_event(config.events_dir, uuid="ABCD-1234", mountpoint=mountpoint)
    handler = app_module._LiveEventHandler(config, None)
    barrier = threading.Barrier(2)

    def run() -> None:
        barrier.wait(timeout=5)
        handler.handle(path)

    threads = [threading.Thread(target=run) for _ in range(2)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=5)

    assert path.exists() is False
    assert (
        count(conn, "SELECT count(*) FROM events WHERE action = 'add'") == 1
    )
    assert count(conn, "SELECT count(*) FROM inventories") == 1


def test_live_drive_added_dedupes_concurrent_scans(
    conn, config: Config, monkeypatch
):
    config.events_dir.mkdir(parents=True)
    first_path = write_event(
        config.events_dir,
        uuid="ABCD-1234",
        mountpoint=config.mounts_root / "ABCD-1234",
        name="first.json",
    )
    second_path = write_event(
        config.events_dir,
        uuid="ABCD-1234",
        mountpoint=config.mounts_root / "ABCD-1234",
        name="second.json",
    )
    entered = threading.Event()
    release = threading.Event()
    calls: list[int] = []

    def slow_handle(conn, drive_id, mountpoint, config, enqueue_run):
        calls.append(drive_id)
        entered.set()
        assert release.wait(timeout=5)

    monkeypatch.setattr(app_module, "handle_drive_added", slow_handle)
    handler = app_module._LiveEventHandler(config, None)
    first = threading.Thread(target=handler.handle, args=(first_path,))
    first.start()
    try:
        assert entered.wait(timeout=5)
        handler.handle(second_path)
    finally:
        release.set()
        first.join(timeout=5)

    assert first.is_alive() is False
    assert len(calls) == 1


# ---------------------------------------------------------------------------
# App factory and background wiring
# ---------------------------------------------------------------------------


def test_app_factory_initialises_schema_without_background(config: Config):
    app = create_app(config, start_background=False)

    with TestClient(app) as client:
        assert client.get("/healthz").status_code == 200
        assert app.state.worker is None
        assert app.state.watcher is None

    connection = open_db(config.db_path)
    try:
        tables = table_names(connection)
    finally:
        connection.close()
    assert {"drives", "runs", "run_items", "settings"} <= tables


def test_background_app_starts_and_stops_worker_and_watcher(conn, config: Config):
    config.events_dir.mkdir(parents=True)
    run_id = insert_run(conn, status="running", item_status="running")

    app = create_app(config)
    with TestClient(app) as client:
        assert client.get("/healthz").status_code == 200
        worker = app.state.worker
        watcher = app.state.watcher
        assert worker is not None
        assert worker._thread is not None and worker._thread.is_alive()
        assert watcher is not None
        assert watcher._observer is not None
        assert (
            conn.execute("SELECT status FROM runs WHERE id=?", (run_id,)).fetchone()[0]
            == "interrupted"
        )

    assert worker._thread is None
    assert watcher._observer is None


def test_background_start_tolerates_missing_spool(config: Config, caplog):
    config = replace(
        config,
        events_dir=config.events_dir / "not-mounted",
        mounts_root=config.mounts_root / "not-mounted",
    )
    app = create_app(config)

    with (
        caplog.at_level(logging.WARNING, logger="usbcopy.events"),
        TestClient(app) as client,
    ):
        assert client.get("/healthz").status_code == 200
        assert app.state.watcher is not None
        assert app.state.watcher._observer is None

    assert "not available" in caplog.text


def test_import_route_uses_worker_enqueue(
    config: Config, conn, inventory, monkeypatch
):
    calls: list[int] = []
    monkeypatch.setattr(
        app_module.RunWorker, "enqueue", lambda self, run_id: calls.append(int(run_id))
    )
    app = create_app(config)
    worker = app.state.worker
    assert worker is not None
    import_conn = open_db(config.db_path)
    try:
        item = import_conn.execute(
            "SELECT rel_path FROM inventory_entries "
            "WHERE inventory_id = ? AND is_dir = 0 LIMIT 1",
            (inventory,),
        ).fetchone()
    finally:
        import_conn.close()
    assert item is not None

    with TestClient(app) as client:
        login = client.post(
            "/api/login", json={"username": config.username, "password": PASSWORD}
        )
        assert login.status_code == 200
        response = client.post(
            "/api/imports",
            json={
                "inventory_id": inventory,
                "destination": "movies",
                "paths": [item["rel_path"]],
                "csrf": login.json()["csrf"],
            },
        )

    assert response.status_code == 201
    assert calls == [response.json()["run_id"]]


# ---------------------------------------------------------------------------
# main()
# ---------------------------------------------------------------------------


def test_main_uses_config_env_override_and_configured_port(
    tmp_path: Path, monkeypatch
):
    seen: dict[str, object] = {}
    fake_config = SimpleNamespace(port=9123)
    env_path = tmp_path / "custom.toml"

    def fake_load_config(path: Path) -> SimpleNamespace:
        seen["load_path"] = path
        return fake_config

    def fake_create_app(config: Config) -> str:
        seen["config"] = config
        return "application"

    def fake_run(app, **kwargs) -> None:
        seen["served_app"] = app
        seen["run_kwargs"] = kwargs

    monkeypatch.setenv("USBCOPY_CONFIG", str(env_path))
    monkeypatch.setattr(main_module, "load_config", fake_load_config)
    monkeypatch.setattr(main_module, "create_app", fake_create_app)
    monkeypatch.setattr(main_module.uvicorn, "run", fake_run)

    main_module.main()

    assert seen["load_path"] == env_path
    assert seen["config"] is fake_config
    assert seen["served_app"] == "application"
    assert seen["run_kwargs"]["port"] == 9123


def test_main_defaults_to_etc_config(monkeypatch):
    seen: dict[str, object] = {}
    fake_config = SimpleNamespace(port=8088)

    def fake_load_config(path: Path) -> SimpleNamespace:
        seen["load_path"] = path
        return fake_config

    def fake_run(app, **kwargs) -> None:
        seen["served_app"] = app

    monkeypatch.delenv("USBCOPY_CONFIG", raising=False)
    monkeypatch.setattr(main_module, "load_config", fake_load_config)
    monkeypatch.setattr(main_module, "create_app", lambda config: "application")
    monkeypatch.setattr(main_module.uvicorn, "run", fake_run)

    main_module.main()

    assert seen["load_path"] == Path("/etc/usbcopy/config.toml")
    assert seen["served_app"] == "application"
