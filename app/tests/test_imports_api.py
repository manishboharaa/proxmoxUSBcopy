from __future__ import annotations

import json
import logging
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from usbcopy import api
from usbcopy.app import create_app
from usbcopy.auth import hash_password
from usbcopy.config import Config, Destination
from usbcopy.db import open_db

PASSWORD = "correct horse battery staple"


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


class WorkerMock:
    """Records enqueued run ids; the default worker is a warning-only no-op."""

    def __init__(self) -> None:
        self.enqueued: list[int] = []

    def __call__(self, run_id: int) -> None:
        self.enqueued.append(run_id)


@pytest.fixture
def worker_mock() -> WorkerMock:
    return WorkerMock()


@pytest.fixture
def app(config: Config, conn, worker_mock: WorkerMock):
    return create_app(config, start_background=False, enqueue_run=worker_mock)


@pytest.fixture
def client(app):
    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture
def login(client: TestClient) -> SimpleNamespace:
    response = client.post(
        "/api/login", json={"username": "admin", "password": PASSWORD}
    )
    assert response.status_code == 200
    return SimpleNamespace(**response.json())


@pytest.fixture(autouse=True)
def disk_usage_calls(monkeypatch) -> list[Path]:
    """Make free-space checks deterministic and observable."""
    calls: list[Path] = []

    def disk_usage(path: Path):
        calls.append(Path(path))
        return SimpleNamespace(total=10**12, used=0, free=10**9)

    monkeypatch.setattr(api.shutil, "disk_usage", disk_usage)
    return calls


def post_import(
    client: TestClient,
    login: SimpleNamespace,
    **overrides: object,
):
    payload: dict[str, object] = {
        "inventory_id": 1,
        "destination": "movies",
        "paths": ["Movies"],
        "csrf": login.csrf,
    }
    payload.update(overrides)
    return client.post("/api/imports", json=payload)


def run_count(conn) -> int:
    return int(conn.execute("SELECT COUNT(*) FROM runs").fetchone()[0])


def import_audit_count(conn) -> int:
    return int(
        conn.execute(
            "SELECT COUNT(*) FROM audit WHERE action = 'import_start'"
        ).fetchone()[0]
    )


def test_import_creates_run_audit_and_enqueue(
    client: TestClient,
    login: SimpleNamespace,
    inventory: int,
    conn,
    worker_mock: WorkerMock,
):
    response = post_import(client, login, inventory_id=inventory)
    assert response.status_code == 201
    run_id = response.json()["run_id"]

    run = conn.execute("SELECT * FROM runs WHERE id = ?", (run_id,)).fetchone()
    assert run is not None
    assert run["status"] == "queued"
    assert run["mode"] == "review"
    assert run["destination_key"] == "movies"
    assert run["inventory_id"] == inventory
    assert run["drive_id"] == 1
    assert run["files_total"] == 1
    assert run["bytes_total"] == 2

    items = conn.execute(
        "SELECT rel_path, dest_rel_path, status FROM run_items WHERE run_id = ?",
        (run_id,),
    ).fetchall()
    assert [tuple(item) for item in items] == [
        ("Movies/Heat (1995)/Heat.mkv", "Heat (1995)/Heat.mkv", "pending")
    ]

    audits = conn.execute(
        "SELECT actor, detail_json FROM audit WHERE action = 'import_start'"
    ).fetchall()
    assert len(audits) == 1
    assert audits[0]["actor"] == "admin"
    assert json.loads(audits[0]["detail_json"]) == {
        "destination": "movies",
        "files": 1,
        "bytes": 2,
    }
    assert worker_mock.enqueued == [run_id]


def test_import_requires_authentication(
    client: TestClient,
    inventory: int,
    conn,
    worker_mock: WorkerMock,
):
    response = client.post(
        "/api/imports",
        json={
            "inventory_id": inventory,
            "destination": "movies",
            "paths": ["Movies"],
            "csrf": "anything",
        },
    )
    assert response.status_code == 401
    assert run_count(conn) == 0
    assert import_audit_count(conn) == 0
    assert worker_mock.enqueued == []
    assert client.post("/api/imports", json=[]).status_code == 401


@pytest.mark.parametrize("csrf", ["wrong", "", None, 123])
def test_import_rejects_bad_csrf(
    client: TestClient,
    login: SimpleNamespace,
    inventory: int,
    conn,
    worker_mock: WorkerMock,
    csrf: object,
):
    response = post_import(client, login, inventory_id=inventory, csrf=csrf)
    assert response.status_code == 403
    assert response.json()["detail"] == "invalid CSRF token"
    assert run_count(conn) == 0
    assert import_audit_count(conn) == 0
    assert worker_mock.enqueued == []


@pytest.mark.parametrize(
    "path",
    [
        "../../etc/passwd",
        "/etc/passwd",
        "Movies/../../secret",
        "NotInTheInventory",
    ],
)
def test_import_rejects_unknown_path(
    client: TestClient,
    login: SimpleNamespace,
    inventory: int,
    conn,
    worker_mock: WorkerMock,
    path: str,
):
    response = post_import(client, login, inventory_id=inventory, paths=[path])
    assert response.status_code == 422
    assert isinstance(response.json()["detail"], str)
    assert response.json()["detail"]
    assert run_count(conn) == 0
    assert import_audit_count(conn) == 0
    assert worker_mock.enqueued == []


def test_import_rejects_unknown_destination(
    client: TestClient,
    login: SimpleNamespace,
    inventory: int,
    conn,
    worker_mock: WorkerMock,
):
    response = post_import(client, login, inventory_id=inventory, destination="music")
    assert response.status_code == 422
    assert "music" in response.json()["detail"]
    assert run_count(conn) == 0
    assert worker_mock.enqueued == []


@pytest.mark.parametrize("paths", [[], "Movies", [1], None])
def test_import_rejects_empty_or_invalid_paths(
    client: TestClient,
    login: SimpleNamespace,
    inventory: int,
    conn,
    worker_mock: WorkerMock,
    paths: object,
):
    response = post_import(client, login, inventory_id=inventory, paths=paths)
    assert response.status_code == 422
    assert isinstance(response.json()["detail"], str)
    assert run_count(conn) == 0
    assert worker_mock.enqueued == []


def test_import_rejects_unknown_inventory(
    client: TestClient,
    login: SimpleNamespace,
    conn,
    worker_mock: WorkerMock,
):
    response = post_import(client, login, inventory_id=999)
    assert response.status_code == 422
    assert "999" in response.json()["detail"]
    assert run_count(conn) == 0
    assert worker_mock.enqueued == []


def test_import_rejects_incomplete_inventory(
    client: TestClient,
    login: SimpleNamespace,
    inventory: int,
    conn,
    worker_mock: WorkerMock,
):
    conn.execute(
        "UPDATE inventories SET status = 'scanning' WHERE id = ?", (inventory,)
    )
    conn.commit()

    response = post_import(client, login, inventory_id=inventory)
    assert response.status_code == 422
    assert "not complete" in response.json()["detail"]
    assert run_count(conn) == 0
    assert worker_mock.enqueued == []


def test_import_rejects_malformed_body(
    client: TestClient,
    login: SimpleNamespace,
    conn,
    worker_mock: WorkerMock,
):
    assert client.post("/api/imports", json=[]).status_code == 422
    assert (
        client.post(
            "/api/imports",
            content=b"not json",
            headers={"content-type": "application/json"},
        ).status_code
        == 422
    )
    assert (
        client.post(
            "/api/imports",
            json={"destination": "movies", "paths": ["Movies"], "csrf": login.csrf},
        ).status_code
        == 422
    )
    assert (
        client.post(
            "/api/imports",
            json={
                "inventory_id": True,
                "destination": "movies",
                "paths": ["Movies"],
                "csrf": login.csrf,
            },
        ).status_code
        == 422
    )
    assert run_count(conn) == 0
    assert worker_mock.enqueued == []


def test_import_maps_plan_errors_to_422(
    client: TestClient,
    login: SimpleNamespace,
    inventory: int,
    conn,
    worker_mock: WorkerMock,
    monkeypatch,
):
    from usbcopy.planner import PlanError

    def fail(*args: object, **kwargs: object) -> None:
        raise PlanError("not enough space: need 900 bytes, have 1")

    monkeypatch.setattr(api, "build_run_plan", fail)
    response = post_import(client, login, inventory_id=inventory)
    assert response.status_code == 422
    assert response.json()["detail"] == "not enough space: need 900 bytes, have 1"
    assert run_count(conn) == 0
    assert worker_mock.enqueued == []


def test_import_rejects_insufficient_free_space(
    client: TestClient,
    login: SimpleNamespace,
    inventory: int,
    conn,
    worker_mock: WorkerMock,
    monkeypatch,
):
    monkeypatch.setattr(
        api.shutil,
        "disk_usage",
        lambda path: SimpleNamespace(total=100, used=99, free=1),
    )
    response = post_import(client, login, inventory_id=inventory)
    assert response.status_code == 422
    assert "not enough space" in response.json()["detail"]
    assert run_count(conn) == 0
    assert worker_mock.enqueued == []


def test_import_uses_configured_destination_root_and_free_space(
    client: TestClient,
    login: SimpleNamespace,
    inventory: int,
    config: Config,
    disk_usage_calls: list[Path],
):
    response = post_import(
        client, login, inventory_id=inventory, destination="series", paths=["Movies"]
    )
    assert response.status_code == 201
    assert disk_usage_calls == [config.destinations["series"].path]
    run = client.get(f"/api/runs/{response.json()['run_id']}").json()
    assert run["destination_key"] == "series"


def test_enqueue_runs_only_after_run_and_audit_are_committed(
    config: Config,
    inventory: int,
):
    observed: dict[str, object] = {}

    def enqueue(run_id: int) -> None:
        other = open_db(config.db_path)
        try:
            run = other.execute(
                "SELECT status FROM runs WHERE id = ?", (run_id,)
            ).fetchone()
            audits = other.execute(
                "SELECT COUNT(*) FROM audit WHERE action = 'import_start'"
            ).fetchone()[0]
        finally:
            other.close()
        observed["run_id"] = run_id
        observed["status"] = None if run is None else run["status"]
        observed["audits"] = int(audits)

    app = create_app(config, start_background=False, enqueue_run=enqueue)
    with TestClient(app) as test_client:
        login = test_client.post(
            "/api/login", json={"username": "admin", "password": PASSWORD}
        ).json()
        response = test_client.post(
            "/api/imports",
            json={
                "inventory_id": inventory,
                "destination": "movies",
                "paths": ["Movies"],
                "csrf": login["csrf"],
            },
        )
        assert response.status_code == 201
        run_id = response.json()["run_id"]

    assert observed == {
        "run_id": run_id,
        "status": "queued",
        "audits": 1,
    }


def test_default_enqueue_without_worker_logs_warning(
    config: Config, inventory: int, caplog
):
    app = create_app(config, start_background=False)
    with TestClient(app) as test_client:
        login = test_client.post(
            "/api/login", json={"username": "admin", "password": PASSWORD}
        ).json()
        with caplog.at_level(logging.WARNING, logger="usbcopy.api"):
            response = test_client.post(
                "/api/imports",
                json={
                    "inventory_id": inventory,
                    "destination": "movies",
                    "paths": ["Movies"],
                    "csrf": login["csrf"],
                },
            )
        assert response.status_code == 201

    assert "no worker is attached" in caplog.text


def test_only_login_logout_and_imports_are_mutating(app):
    allowed = {"/api/login", "/api/logout", "/api/imports"}
    mutating = {
        route.path
        for route in app.routes
        for method in (getattr(route, "methods", None) or set())
        if method not in {"GET", "HEAD", "OPTIONS"}
    }
    assert mutating <= allowed
