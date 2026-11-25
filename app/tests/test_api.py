from __future__ import annotations

import itertools
import json
import logging
import sqlite3
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from usbcopy import api
from usbcopy.api import _open_stream_connection, run_event_stream
from usbcopy.app import create_app
from usbcopy.auth import SessionManager, hash_password
from usbcopy.config import Config, Destination

PASSWORD = "correct horse battery staple"
SESSION_COOKIE = "usbcopy_session"


@pytest.fixture(scope="module")
def password_hash() -> str:
    return hash_password(PASSWORD)


@pytest.fixture
def config(tmp_path: Path, password_hash: str) -> Config:
    destinations = {
        "movies": Destination(key="movies", path=tmp_path / "movies"),
        "series": Destination(key="series", path=tmp_path / "series"),
    }
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
        destinations=destinations,
        db_path=tmp_path / "usbcopy.db",
        events_dir=tmp_path / "events",
        mounts_root=tmp_path / "mounts",
        reconcile_minutes=0,
        skip_hidden_root_dirs=True,
    )


@pytest.fixture
def app(config: Config, conn):
    return create_app(config, start_background=False)


@pytest.fixture
def client(app):
    with TestClient(app) as test_client:
        yield test_client


def post_login(client: TestClient, username: str = "admin", password: str = PASSWORD):
    return client.post("/api/login", json={"username": username, "password": password})


@pytest.fixture
def login(client: TestClient) -> SimpleNamespace:
    response = post_login(client)
    assert response.status_code == 200
    return SimpleNamespace(**response.json())


def insert_run(conn, *, status: str = "running", **overrides) -> int:
    values = {
        "drive_id": 1,
        "destination_key": "movies",
        "mode": "review",
        "status": status,
        "files_total": 2,
        "bytes_total": 30,
        "bytes_done": 10,
    }
    values.update(overrides)
    cursor = conn.execute(
        "INSERT INTO runs "
        "(drive_id, destination_key, mode, status, files_total, bytes_total, "
        " bytes_done) "
        "VALUES (:drive_id, :destination_key, :mode, :status, :files_total, "
        ":bytes_total, :bytes_done)",
        values,
    )
    conn.commit()
    return int(cursor.lastrowid)


@pytest.fixture
def run_id(conn) -> int:
    run_id = insert_run(conn)
    conn.executemany(
        "INSERT INTO run_items (run_id, rel_path, size, dest_rel_path, status) "
        "VALUES (?, ?, ?, ?, ?)",
        [
            (run_id, "Heat.mkv", 10, "Heat.mkv", "completed"),
            (run_id, "Notes.txt", 20, "Notes.txt", "pending"),
        ],
    )
    conn.commit()
    return run_id


def frame_payload(frame: str) -> dict:
    assert frame.startswith("data: ") and frame.endswith("\n\n")
    return json.loads(frame[len("data: ") : -2])


def test_healthz_is_public(client: TestClient):
    response = client.get("/healthz")
    assert response.status_code == 200 and response.json() == {"status": "ok"}


def test_requires_login(client: TestClient):
    assert client.get("/api/status").status_code == 401


@pytest.mark.parametrize(
    "path",
    [
        "/api/status",
        "/api/drives",
        "/api/drives/1",
        "/api/inventories/1",
        "/api/runs",
        "/api/runs/1",
        "/api/runs/1/items",
        "/api/events/stream?run_id=1",
    ],
)
def test_read_endpoints_require_login(client: TestClient, path: str):
    assert client.get(path).status_code == 401


def test_logout_without_session_clears_cookie(client: TestClient):
    response = client.post("/api/logout")
    assert response.status_code == 200
    assert response.json() == {"ok": True}

    header = response.headers["set-cookie"].lower()
    assert header.startswith(f"{SESSION_COOKIE}=")
    assert "max-age=0" in header
    assert "path=/" in header and "httponly" in header
    assert "samesite=lax" in header

    assert client.get("/api/status").status_code == 401


def test_invalid_session_cookie_is_rejected(client: TestClient):
    client.cookies.set(SESSION_COOKIE, "not-a-signed-token")
    assert client.get("/api/status").status_code == 401
    client.cookies.set(SESSION_COOKIE, "")
    assert client.get("/api/status").status_code == 401


def test_login_sets_http_only_lax_cookie_and_returns_csrf(
    client: TestClient, config: Config
):
    response = post_login(client)
    assert response.status_code == 200
    body = response.json()
    assert body["username"] == "admin" and body["csrf"]

    header = response.headers["set-cookie"]
    lowered = header.lower()
    assert lowered.startswith(f"{SESSION_COOKIE}=")
    assert "httponly" in lowered and "samesite=lax" in lowered
    assert "secure" not in lowered

    token = client.cookies.get(SESSION_COOKIE)
    session = SessionManager(config.session_secret).read(token)
    assert session is not None
    assert session.username == "admin" and session.csrf == body["csrf"]


def test_login_sets_secure_cookie_over_https(app):
    with TestClient(app, base_url="https://testserver") as https_client:
        response = post_login(https_client)
        assert response.status_code == 200
        assert "secure" in response.headers["set-cookie"].lower()


def test_login_accepts_form_encoded_body(client: TestClient):
    response = client.post(
        "/api/login", data={"username": "admin", "password": PASSWORD}
    )
    assert response.status_code == 200 and response.json()["csrf"]


def test_login_rejects_wrong_credentials(client: TestClient):
    assert post_login(client, password="wrong password").status_code == 401
    assert post_login(client, username="someone").status_code == 401
    assert post_login(client, username="ádmin").status_code == 401
    assert (
        client.post(
            "/api/login",
            content=b'{"username": "\\ud800", "password": "x"}',
            headers={"content-type": "application/json"},
        ).status_code
        == 401
    )
    assert (
        client.post(
            "/api/login",
            content=b'{"username": "admin", "password": "\\ud800"}',
            headers={"content-type": "application/json"},
        ).status_code
        == 401
    )


def test_login_rejects_malformed_payloads(client: TestClient):
    assert client.post("/api/login", json={"username": "admin"}).status_code == 401
    assert client.post("/api/login", json={"password": PASSWORD}).status_code == 401
    assert (
        client.post("/api/login", json={"username": 1, "password": 2}).status_code
        == 401
    )
    assert (
        client.post(
            "/api/login",
            content=b"not json",
            headers={"content-type": "application/json"},
        ).status_code
        == 401
    )


def test_login_writes_audit_row(client: TestClient, conn):
    assert post_login(client).status_code == 200
    rows = conn.execute(
        "SELECT actor, action, detail_json FROM audit WHERE action = 'login'"
    ).fetchall()
    assert len(rows) == 1
    assert rows[0]["actor"] == "admin"
    assert json.loads(rows[0]["detail_json"]) == {"client": "testclient"}


def test_failed_login_does_not_write_audit(client: TestClient, conn):
    assert post_login(client, password="wrong password").status_code == 401
    assert conn.execute("SELECT COUNT(*) FROM audit").fetchone()[0] == 0


def test_audit_failure_does_not_block_login(config: Config, monkeypatch, caplog):
    def broken_open_db(path):
        raise sqlite3.OperationalError("unable to open database file")

    monkeypatch.setattr(api, "open_db", broken_open_db)
    with TestClient(create_app(config, start_background=False)) as broken_client:
        with caplog.at_level(logging.WARNING, logger="usbcopy.api"):
            response = post_login(broken_client)
        assert response.status_code == 200
        assert response.json()["csrf"]
        assert SESSION_COOKIE in response.cookies
    assert "could not record login audit" in caplog.text


def test_login_rejects_malformed_password_hash(config: Config):
    broken = replace(config, password_hash="not-a-bcrypt-hash")
    with TestClient(create_app(broken, start_background=False)) as broken_client:
        response = post_login(broken_client)
        assert response.status_code == 401
        assert SESSION_COOKIE not in response.cookies


def test_status_after_login(client: TestClient, login: SimpleNamespace):
    response = client.get("/api/status")
    assert response.status_code == 200
    body = response.json()
    assert body["version"] == "1.1.0"
    assert body["mode"] == "review"
    assert body["auto_enabled"] is False
    assert body["drives_present"] == 0
    assert [d["key"] for d in body["destinations"]] == ["movies", "series"]


def test_drives_list_and_detail(client: TestClient, login: SimpleNamespace):
    listing = client.get("/api/drives")
    assert listing.status_code == 200
    drives = listing.json()["drives"]
    assert len(drives) == 1
    assert drives[0]["id"] == 1
    assert drives[0]["label"] == "Test Drive"
    assert drives[0]["present"] is False

    detail = client.get("/api/drives/1")
    assert detail.status_code == 200
    body = detail.json()
    assert body["uuid"] == "TEST-DRIVE-0001"
    assert body["inventories"] == []

    assert client.get("/api/drives/99").status_code == 404


def test_inventory_tree_paginates_by_parent(
    client: TestClient, login: SimpleNamespace, inventory: int
):
    root = client.get(f"/api/inventories/{inventory}")
    assert root.status_code == 200
    body = root.json()
    assert body["inventory"]["id"] == inventory
    assert body["parent"] == ""
    assert body["total"] == 2
    assert [e["rel_path"] for e in body["entries"]] == ["Movies", "Heat.mkv"]
    assert body["entries"][0]["is_dir"] is True
    assert body["entries"][1]["is_dir"] is False
    assert body["entries"][1]["kind"] == "movie"

    page = client.get(
        f"/api/inventories/{inventory}",
        params={"parent": "Movies", "limit": 1, "offset": 0},
    ).json()
    assert page["total"] == 1
    assert [e["rel_path"] for e in page["entries"]] == ["Movies/Heat (1995)"]

    offset = client.get(
        f"/api/inventories/{inventory}", params={"limit": 1, "offset": 1}
    ).json()
    assert [e["rel_path"] for e in offset["entries"]] == ["Heat.mkv"]

    leaves = client.get(
        f"/api/inventories/{inventory}",
        params={"parent": "/Movies/Heat (1995)/"},
    ).json()
    assert [e["rel_path"] for e in leaves["entries"]] == ["Movies/Heat (1995)/Heat.mkv"]


def test_unknown_inventory_returns_404(client: TestClient, login: SimpleNamespace):
    assert client.get("/api/inventories/999").status_code == 404


def test_runs_list_detail_and_items(
    client: TestClient, login: SimpleNamespace, run_id: int
):
    listing = client.get("/api/runs")
    assert listing.status_code == 200
    body = listing.json()
    assert body["total"] == 1
    assert body["runs"][0]["id"] == run_id
    assert body["runs"][0]["status"] == "running"
    assert body["runs"][0]["destination_key"] == "movies"

    detail = client.get(f"/api/runs/{run_id}")
    assert detail.status_code == 200
    detail_body = detail.json()
    assert detail_body["files_total"] == 2
    assert detail_body["item_counts"]["completed"] == 1
    assert detail_body["item_counts"]["pending"] == 1

    items = client.get(f"/api/runs/{run_id}/items")
    assert items.status_code == 200
    assert items.json()["total"] == 2
    assert [i["rel_path"] for i in items.json()["items"]] == [
        "Heat.mkv",
        "Notes.txt",
    ]

    pending = client.get(
        f"/api/runs/{run_id}/items", params={"status": "pending"}
    ).json()
    assert [i["rel_path"] for i in pending["items"]] == ["Notes.txt"]


def test_run_filters_and_unknown_run(
    client: TestClient, login: SimpleNamespace, run_id: int
):
    running = client.get("/api/runs", params={"status": "running"}).json()
    assert running["total"] == 1
    assert client.get("/api/runs", params={"status": "failed"}).json()["total"] == 0
    assert client.get("/api/runs", params={"status": "bogus"}).status_code == 422

    assert client.get("/api/runs/999").status_code == 404
    assert client.get("/api/runs/999/items").status_code == 404


def test_no_mutating_endpoints(
    client: TestClient, login: SimpleNamespace, run_id: int, conn
):
    paths = [f"/api/runs/{run_id}", "/api/drives/1", "/api/inventories/1"]
    for method in ("delete", "put", "patch"):
        for path in paths:
            assert getattr(client, method)(path).status_code in (404, 405)
    assert client.post("/api/status").status_code in (404, 405)
    assert client.post("/api/runs").status_code in (404, 405)

    row = conn.execute("SELECT status FROM runs WHERE id = ?", (run_id,)).fetchone()
    assert row["status"] == "running"


def test_logout_clears_cookie(client: TestClient, login: SimpleNamespace):
    assert client.get("/api/status").status_code == 200
    response = client.post("/api/logout")
    assert response.status_code == 200
    assert response.json() == {"ok": True}
    assert client.get("/api/status").status_code == 401


def test_sse_emits_run_event(conn, run_id: int):
    frames = list(itertools.islice(run_event_stream(conn, run_id), 1))
    assert frames[0].startswith("data: ") and frames[0].endswith("\n\n")
    payload = frame_payload(frames[0])
    assert payload["run_id"] == run_id
    assert payload["status"] == "running"
    assert payload["bytes_total"] == 30


def test_sse_polls_until_terminal_status(conn, run_id: int):
    conn.execute("UPDATE runs SET error = 'transient failure' WHERE id = ?", (run_id,))
    conn.commit()

    stream = run_event_stream(conn, run_id, poll_interval=0.01)
    assert frame_payload(next(stream))["status"] == "running"

    conn.execute("UPDATE runs SET status = 'completed' WHERE id = ?", (run_id,))
    conn.commit()

    assert frame_payload(next(stream))["status"] == "completed"
    with pytest.raises(StopIteration):
        next(stream)


def test_stream_connection_can_resume_on_another_thread(config: Config, conn):
    stream_conn = _open_stream_connection(config.db_path)
    try:
        with ThreadPoolExecutor(max_workers=1) as executor:
            count = executor.submit(
                lambda: stream_conn.execute("SELECT COUNT(*) FROM drives").fetchone()[0]
            ).result()
        assert count == 1
    finally:
        stream_conn.close()


def test_sse_reports_missing_run(conn):
    frames = list(run_event_stream(conn, 999, poll_interval=0.01))
    assert len(frames) == 1
    assert frame_payload(frames[0])["error"] == "run not found"


def test_sse_endpoint_streams_terminal_run(
    client: TestClient, login: SimpleNamespace, conn
):
    terminal_run = insert_run(conn, status="completed", bytes_done=30)
    response = client.get("/api/events/stream", params={"run_id": terminal_run})
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/event-stream")

    frames = [part for part in response.text.split("\n\n") if part]
    assert len(frames) == 1
    assert frame_payload(frames[0] + "\n\n")["status"] == "completed"


def test_change_password_updates_config_and_allows_new_login(
    client: TestClient, config, tmp_path
):
    config_path = tmp_path / "config.toml"
    config_path.write_text(
        f'password_hash = "{config.password_hash}"\n', encoding="utf-8"
    )
    config_path.chmod(0o600)
    object.__setattr__(config, "config_path", config_path)
    new_password = "brand new stable passphrase"

    assert client.post("/api/login", json={"username": "admin", "password": PASSWORD}).status_code == 200

    response = client.post(
        "/api/account/password",
        json={"current_password": PASSWORD, "new_password": new_password},
    )
    assert response.status_code == 200, response.text
    assert config_path.read_text().startswith('password_hash = "$2')
    assert "brand new stable passphrase" not in config_path.read_text()

    verify = client.post(
        "/api/account/password",
        json={"current_password": new_password, "new_password": "another ok password"},
    )
    assert verify.status_code == 200


def test_change_password_requires_the_session_cookie(config, tmp_path):
    config_path = tmp_path / "config.toml"
    config_path.write_text(f'password_hash = "{config.password_hash}"\n')
    object.__setattr__(config, "config_path", config_path)
    app = create_app(config, start_background=False)
    client = TestClient(app)

    response = client.post(
        "/api/account/password",
        json={"current_password": PASSWORD, "new_password": "another ok password"},
    )
    assert response.status_code in (401, 303)


def test_change_password_rejects_wrong_current_password(client: TestClient, config, tmp_path):
    config_path = tmp_path / "config.toml"
    config_path.write_text(f'password_hash = "{config.password_hash}"\n')
    object.__setattr__(config, "config_path", config_path)
    post_login(client)

    response = client.post(
        "/api/account/password",
        json={"current_password": "wrong current password", "new_password": "another ok password"},
    )
    assert response.status_code == 403
    assert config_path.read_text() == f'password_hash = "{config.password_hash}"\n'


def test_change_password_enforces_minimum_length(client: TestClient, config, tmp_path):
    config_path = tmp_path / "config.toml"
    config_path.write_text(f'password_hash = "{config.password_hash}"\n')
    object.__setattr__(config, "config_path", config_path)
    post_login(client)

    response = client.post(
        "/api/account/password",
        json={"current_password": PASSWORD, "new_password": "short"},
    )
    assert response.status_code == 422
    assert "at least 12" in response.json()["detail"]


def test_change_password_rejects_same_password(client: TestClient, config, tmp_path):
    config_path = tmp_path / "config.toml"
    config_path.write_text(f'password_hash = "{config.password_hash}"\n')
    object.__setattr__(config, "config_path", config_path)
    post_login(client)

    response = client.post(
        "/api/account/password",
        json={"current_password": PASSWORD, "new_password": PASSWORD},
    )
    assert response.status_code == 422


def test_account_page_requires_login_and_renders_when_signed_in(client: TestClient):
    anonymous = client.get("/account", follow_redirects=False)
    assert anonymous.status_code == 303
    assert anonymous.headers["location"] == "/login"

    post_login(client)
    page = client.get("/account")
    assert page.status_code == 200
    assert "Change password" in page.text


def _seed_run(conn):
    from usbcopy.planner import PlanItem, RunPlan
    from usbcopy.runs import create_run

    plan = RunPlan(
        items=[PlanItem("Movies/Heat.mkv", "Heat (1995)/Heat.mkv", 2)],
        skipped=[],
        warnings=[],
        total_bytes=2,
    )
    return create_run(conn, 1, None, "movies", "review", plan)


def _login_and_csrf(client: TestClient) -> str:
    body = post_login(client).json()
    return body["csrf"]


def test_cancel_endpoint_interrupts_a_queued_run(client: TestClient, conn):
    from usbcopy import worker as worker_module

    run_id = _seed_run(conn)
    csrf = _login_and_csrf(client)

    response = client.post(
        f"/api/runs/{run_id}/cancel", json={"csrf": csrf}
    )

    assert response.status_code == 200, response.text
    assert response.json() == {"status": "cancelled"}
    run = conn.execute("SELECT status FROM runs WHERE id = ?", (run_id,)).fetchone()
    assert run["status"] == "interrupted"
    items = conn.execute(
        "SELECT status FROM run_items WHERE run_id = ?", (run_id,)
    ).fetchall()
    assert [row["status"] for row in items] == [
        worker_module.CANCELLED.lower()
    ]


def test_cancel_endpoint_rejects_a_finished_run(client: TestClient, conn):
    run_id = _seed_run(conn)
    conn.execute(
        "UPDATE runs SET status = 'completed' WHERE id = ?", (run_id,)
    )
    conn.commit()
    csrf = _login_and_csrf(client)

    response = client.post(f"/api/runs/{run_id}/cancel", json={"csrf": csrf})

    assert response.status_code == 409


def test_cancel_endpoint_requires_csrf(client: TestClient, conn):
    run_id = _seed_run(conn)
    _login_and_csrf(client)

    response = client.post(f"/api/runs/{run_id}/cancel", json={"csrf": "nope"})

    assert response.status_code == 403


def test_update_check_endpoint_reports_status(client: TestClient, monkeypatch):
    from usbcopy import update_check as update_module

    update_module.reset_cache()
    monkeypatch.setattr(
        update_module,
        "fetch_remote_version",
        lambda repo, branch: "9.9.9",
    )
    post_login(client)

    response = client.get("/api/update/check")

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["update_available"] is True
    assert body["current_version"] == "1.1.0"
    assert body["latest_version"] == "9.9.9"
    update_module.reset_cache()


def test_update_check_endpoint_requires_login(config, tmp_path):
    app_instance = create_app(config, start_background=False)
    client = TestClient(app_instance)

    response = client.get("/api/update/check")

    assert response.status_code in (401, 303)
