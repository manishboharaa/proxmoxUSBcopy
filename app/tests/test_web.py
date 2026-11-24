"""Server-rendered page tests: login, session guard, and overview data."""

from __future__ import annotations

import re
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

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
    movies = tmp_path / "movies"
    series = tmp_path / "series"
    movies.mkdir()
    series.mkdir()
    destinations = {
        "movies": Destination(key="movies", path=movies),
        "series": Destination(key="series", path=series),
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


def post_form_login(
    client: TestClient,
    *,
    username: str = "admin",
    password: str = PASSWORD,
    next_path: str | None = None,
):
    data = {"username": username, "password": password}
    if next_path is not None:
        data["next"] = next_path
    return client.post("/login", data=data, follow_redirects=False)


@pytest.fixture
def login(client: TestClient):
    response = post_form_login(client)
    assert response.status_code == 303
    assert response.headers["location"] == "/"
    return response


@pytest.fixture
def present_drive(conn, tmp_path: Path) -> SimpleNamespace:
    """Mount drive 1 with a complete inventory holding Movies and Shows."""
    root = tmp_path / "drive-mount"
    root.mkdir()
    conn.execute(
        "UPDATE drives SET present = 1, mountpoint = ?, serial = 'ABCD-1234', "
        "fs_type = 'exFAT' WHERE id = 1",
        (str(root),),
    )
    cursor = conn.execute(
        "INSERT INTO inventories "
        "(drive_id, root, status, total_files, total_bytes) "
        "VALUES (1, ?, 'complete', 3, 4096)",
        (str(root),),
    )
    inventory_id = cursor.lastrowid
    entries = [
        ("Movies", "", 1, 0, "other"),
        ("Movies/Heat (1995)", "Movies", 1, 0, "other"),
        ("Movies/Heat (1995)/Heat.mkv", "Movies/Heat (1995)", 0, 2048, "movie"),
        ("Shows", "", 1, 0, "other"),
        ("Shows/The Wire", "Shows", 1, 0, "other"),
        (
            "Shows/The Wire/S02E03.mkv",
            "Shows/The Wire",
            0,
            2048,
            "series",
        ),
    ]
    conn.executemany(
        "INSERT INTO inventory_entries "
        "(inventory_id, rel_path, parent_path, is_dir, size, kind) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        [
            (inventory_id, rel_path, parent, is_dir, size, kind)
            for rel_path, parent, is_dir, size, kind in entries
        ],
    )
    conn.commit()
    return SimpleNamespace(inventory_id=inventory_id, root=str(root))


def needs_attention_kpi(html: str) -> tuple[str, str]:
    """Extract the Needs attention KPI value and note from the overview HTML."""
    match = re.search(
        r'<p class="kpi-label">\s*(?:<svg[^>]*>.*?</svg>\s*)?Needs attention\s*</p>'
        r'\s*<p class="kpi-value">(.*?)</p>'
        r'\s*<p class="kpi-note">(.*?)</p>',
        html,
        re.DOTALL,
    )
    assert match is not None
    value = re.sub(r"<[^>]+>", "", match.group(1)).strip()
    note = re.sub(r"<[^>]+>", "", match.group(2)).strip()
    return value, note


def _now_iso() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def test_root_redirects_to_login(client):
    r = client.get("/", follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"] == "/login"


def test_login_page_renders(client):
    html = client.get("/login").text
    assert "<form" in html and "password" in html


def test_overview_renders_after_login(client, login):
    html = client.get("/").text
    assert "Overview" in html and "Connected drives" in html


def test_pages_have_no_external_assets(client, login):
    for path in ("/", "/login"):
        body = client.get(path).text
        for needle in ('<script src="http', '<link href="http', '<img src="http'):
            assert needle not in body


def test_login_sets_hardened_session_cookie(client):
    response = post_form_login(client)
    assert response.status_code == 303
    assert response.headers["location"] == "/"
    cookie = response.headers["set-cookie"].lower()
    assert SESSION_COOKIE in cookie
    assert "httponly" in cookie
    assert "samesite=lax" in cookie
    assert "path=/" in cookie
    assert "secure" not in cookie


def test_login_rejects_wrong_password(client):
    response = post_form_login(client, password="wrong password")
    assert response.status_code == 401
    assert "Invalid username or password" in response.text
    assert SESSION_COOKIE not in response.cookies


def test_login_marks_cookie_secure_over_https(config: Config):
    with TestClient(
        create_app(config, start_background=False),
        base_url="https://testserver",
    ) as secure_client:
        response = post_form_login(secure_client)
        assert response.status_code == 303
        assert "secure" in response.headers["set-cookie"].lower()


def test_login_rejects_malformed_stored_hash(config: Config):
    broken = replace(config, password_hash="not-a-bcrypt-hash")
    with TestClient(create_app(broken, start_background=False)) as broken_client:
        response = post_form_login(broken_client)
        assert response.status_code < 500
        assert response.status_code == 401
        assert SESSION_COOKIE not in response.cookies


def test_login_handles_null_session(app, client, monkeypatch):
    monkeypatch.setattr(app.state.session_manager, "read", lambda token: None)
    response = post_form_login(client)
    assert response.status_code == 400
    assert "Try again" in response.text


def test_root_rejects_invalid_session_cookie(client):
    client.cookies.set(SESSION_COOKIE, "garbage")
    response = client.get("/", follow_redirects=False)
    assert response.status_code == 303
    assert response.headers["location"] == "/login"


def test_logout_clears_cookie_and_requires_login(client, login):
    response = client.post("/logout", follow_redirects=False)
    assert response.status_code == 303
    assert response.headers["location"] == "/login"
    assert SESSION_COOKIE in response.headers["set-cookie"]
    assert client.get("/", follow_redirects=False).headers["location"] == "/login"


def test_login_redirects_authenticated_visitor(client, login):
    response = client.get("/login", follow_redirects=False)
    assert response.status_code == 303
    assert response.headers["location"] == "/"


def test_login_honours_only_local_next_paths(client):
    response = post_form_login(client, next_path="/import")
    assert response.headers["location"] == "/import"
    client.cookies.clear()
    response = post_form_login(client, next_path="//evil.example/steal")
    assert response.headers["location"] == "/"


def test_overview_exposes_session_csrf(client, login, config):
    token = client.cookies.get(SESSION_COOKIE)
    session = SessionManager(config.session_secret).read(token)
    assert session is not None
    html = client.get("/").text
    assert f'name="csrf-token" content="{session.csrf}"' in html
    assert f'data-csrf="{session.csrf}"' in html


def test_overview_renders_seeded_drive_inventory_and_run(
    client, login, conn, tmp_path
):
    drive_root = tmp_path / "drive"
    drive_root.mkdir()
    conn.execute(
        "UPDATE drives SET present = 1, mountpoint = ?, serial = ?, "
        "fs_type = 'exFAT' WHERE id = 1",
        (str(drive_root), "S6B9NJ0T512384K"),
    )
    cursor = conn.execute(
        "INSERT INTO inventories "
        "(drive_id, root, status, total_files, total_bytes) "
        "VALUES (1, ?, 'complete', 312, 1380000000000)",
        (str(drive_root),),
    )
    inventory_id = cursor.lastrowid
    conn.execute(
        "INSERT INTO runs "
        "(drive_id, inventory_id, destination_key, mode, status, "
        " files_total, bytes_total, bytes_done, started_at, finished_at) "
        "VALUES (1, ?, 'movies', 'review', 'completed', 6, 194100000000, "
        "        194100000000, '2026-11-24T19:17:00.000Z', "
        "        '2026-11-24T19:31:00.000Z')",
        (inventory_id,),
    )
    conn.commit()

    html = client.get("/").text
    assert "Connected drives" in html
    assert "Test Drive" in html
    assert "S6B9NJ0T512384K" in html
    assert "312 files, 1.38 TB" in html
    assert "Recent runs" in html
    assert "Completed" in html
    assert "Movies" in html


def test_overview_empty_states(client, login):
    html = client.get("/").text
    assert "No drive connected." in html
    assert "No transfer is running." in html
    assert "Queue is empty." in html
    assert "No recent runs." in html


def test_needs_attention_does_not_report_duplicate_conflicts(client, login, conn):
    conn.execute("UPDATE drives SET present = 1 WHERE id = 1")
    cursor = conn.execute(
        "INSERT INTO inventories (drive_id, root, status) "
        "VALUES (1, '/mnt/usb', 'complete')"
    )
    inventory_id = cursor.lastrowid
    conn.execute(
        "INSERT INTO inventory_entries "
        "(inventory_id, rel_path, parent_path, is_dir, size, kind, duplicate_state) "
        "VALUES (?, 'Movies/Heat (1995)/Heat.mkv', 'Movies/Heat (1995)', "
        "        0, 10, 'video', 'conflict')",
        (inventory_id,),
    )
    conn.commit()

    html = client.get("/").text
    value, note = needs_attention_kpi(html)
    assert value == "0"
    assert "conflict" not in note.lower()


def test_needs_attention_counts_failed_files_and_runs(client, login, conn):
    now = _now_iso()
    cursor = conn.execute(
        "INSERT INTO runs "
        "(drive_id, destination_key, mode, status, started_at, finished_at, "
        " files_total, bytes_total) "
        "VALUES (1, 'movies', 'review', 'interrupted', ?, ?, 1, 100)",
        (now, now),
    )
    run_id = cursor.lastrowid
    conn.execute(
        "INSERT INTO run_items "
        "(run_id, rel_path, size, dest_rel_path, status, finished_at, error) "
        "VALUES (?, 'Movies/X.mkv', 100, 'X.mkv', 'failed', ?, "
        "        'permission denied')",
        (run_id, now),
    )
    conn.commit()

    html = client.get("/").text
    value, note = needs_attention_kpi(html)
    assert value == "2"
    assert "1 failed file" in note
    assert "1 interrupted or failed run" in note
    assert "conflict" not in note.lower()


def test_needs_attention_ignores_issues_older_than_24_hours(client, login, conn):
    old = "2020-01-01T00:00:00.000Z"
    cursor = conn.execute(
        "INSERT INTO runs "
        "(drive_id, destination_key, mode, status, started_at, finished_at, "
        " files_total, bytes_total) "
        "VALUES (1, 'movies', 'review', 'interrupted', ?, ?, 1, 100)",
        (old, old),
    )
    run_id = cursor.lastrowid
    conn.execute(
        "INSERT INTO run_items "
        "(run_id, rel_path, size, dest_rel_path, status, finished_at, error) "
        "VALUES (?, 'Movies/Old.mkv', 100, 'Old.mkv', 'failed', ?, 'old')",
        (run_id, old),
    )
    conn.commit()

    html = client.get("/").text
    value, note = needs_attention_kpi(html)
    assert value == "0"
    assert note == "No failed files or interrupted runs in the last 24 hours."


def test_overview_escapes_drive_label(client, login, conn):
    conn.execute(
        "UPDATE drives SET present = 1, label = '<script>alert(1)</script>' "
        "WHERE id = 1"
    )
    conn.commit()
    html = client.get("/").text
    assert "<script>alert(1)</script>" not in html
    assert "&lt;script&gt;alert(1)&lt;/script&gt;" in html


def test_overview_has_no_write_controls(client, login):
    html = client.get("/").text
    for control in (
        "Start import",
        "Save settings",
        "Delete",
        "Retry",
        "Unmount",
        "Scan now",
    ):
        assert control not in html


def test_login_writes_audit_row(client, conn):
    assert post_form_login(client).status_code == 303
    rows = conn.execute(
        "SELECT actor, action FROM audit WHERE action = 'login'"
    ).fetchall()
    assert len(rows) == 1
    assert rows[0]["actor"] == "admin"


def test_overview_uses_local_css_and_theme_script(client, login):
    html = client.get("/").text
    assert 'href="/static/css/app.css"' in html
    assert 'src="/static/js/theme.js"' in html
    assert 'id="theme-toggle"' in html

    css = client.get("/static/css/app.css")
    assert css.status_code == 200
    assert "../fonts/InterVariable.woff2" in css.text
    assert "../../app/static/fonts" not in css.text

    theme = client.get("/static/js/theme.js")
    assert theme.status_code == 200
    assert "usbcopy-theme" in theme.text


def test_import_page_requires_login(client):
    response = client.get("/import", follow_redirects=False)
    assert response.status_code == 303
    assert response.headers["location"] == "/login"


def test_import_page_shows_drive_and_destinations(
    client, login, present_drive: SimpleNamespace
):
    html = client.get("/import").text
    assert "Import review" in html
    assert "Movies" in html and "Series" in html
    assert "Test Drive" in html and "ABCD-1234" in html


def test_import_page_has_csrf(client, login, config, present_drive):
    token = client.cookies.get(SESSION_COOKIE)
    session = SessionManager(config.session_secret).read(token)
    assert session is not None
    html = client.get("/import").text
    assert f'name="csrf-token" content="{session.csrf}"' in html
    assert f'data-csrf="{session.csrf}"' in html


def test_import_page_has_no_settings_controls(client, login, present_drive):
    html = client.get("/import").text
    for control in (
        "Save settings",
        "Delete",
        "Retry",
        "Unmount",
        "Scan now",
    ):
        assert control not in html


def test_import_page_has_no_external_assets(client, login, present_drive):
    body = client.get("/import").text
    for needle in ('<script src="http', '<link href="http', '<img src="http'):
        assert needle not in body
    assert 'href="/static/css/app.css"' in body
    assert 'src="/static/js/import.js"' in body


def test_import_page_empty_state_without_drive(client, login):
    html = client.get("/import").text
    assert "No drive connected." in html
    assert "No files selected." in html
    assert re.search(r'<button[^>]*id="start-import"[^>]*disabled', html)


def test_import_page_reports_scanning_inventory(client, login, conn):
    conn.execute(
        "UPDATE drives SET present = 1, serial = 'ABCD-1234' WHERE id = 1"
    )
    conn.execute(
        "INSERT INTO inventories (drive_id, root, status) "
        "VALUES (1, '/mnt/usb', 'scanning')"
    )
    conn.commit()

    html = client.get("/import").text
    assert "Inventory is still scanning." in html
    assert re.search(r'<button[^>]*id="start-import"[^>]*disabled', html)


def test_import_page_reports_failed_inventory(client, login, conn):
    conn.execute(
        "UPDATE drives SET present = 1, serial = 'ABCD-1234' WHERE id = 1"
    )
    conn.execute(
        "INSERT INTO inventories (drive_id, root, status, error) "
        "VALUES (1, '/mnt/usb', 'failed', 'permission denied')"
    )
    conn.commit()

    html = client.get("/import").text
    assert "Inventory failed." in html
    assert "permission denied" in html


def test_import_page_lists_only_present_drives(
    client, login, conn, present_drive
):
    conn.execute(
        "INSERT INTO drives (id, uuid, label, present) "
        "VALUES (2, 'GONE-0001', 'Gone Drive', 0)"
    )
    conn.commit()

    html = client.get("/import").text
    assert "Test Drive" in html
    assert "Gone Drive" not in html


def test_import_page_escapes_drive_label(client, login, conn):
    conn.execute(
        "UPDATE drives SET present = 1, serial = 'ABCD-1234', "
        "label = '<script>alert(1)</script>' WHERE id = 1"
    )
    conn.commit()
    html = client.get("/import").text
    assert "<script>alert(1)</script>" not in html
    assert "&lt;script&gt;alert(1)&lt;/script&gt;" in html


def test_import_page_uses_local_import_script(client, login, present_drive):
    html = client.get("/import").text
    assert 'id="import-app"' in html
    assert 'src="/static/js/import.js"' in html
    script = client.get("/static/js/import.js")
    assert script.status_code == 200
    assert "/api/imports/preview" in script.text
    assert "EventSource" in script.text
