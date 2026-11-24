from __future__ import annotations

import json
from pathlib import Path
from typing import ClassVar

import pytest
from watchdog.events import (
    DirCreatedEvent,
    FileCreatedEvent,
    FileMovedEvent,
)

from usbcopy import events as events_module
from usbcopy.events import (
    EVENT_VERSION,
    DriveEvent,
    EventError,
    EventSpoolWatcher,
    apply_event,
    parse_event,
    process_pending,
    scan_mounted,
)
from usbcopy.planner import PlanItem, RunPlan
from usbcopy.runs import create_run, get_run

EVENT_TS = "2026-11-24T10:00:00Z"


def default_payload(**overrides: object) -> dict[str, object]:
    payload: dict[str, object] = {
        "version": EVENT_VERSION,
        "action": "add",
        "uuid": "ABCD-1234",
        "label": "Test Drive",
        "serial": "SN123",
        "device": "/dev/sdb1",
        "mountpoint": "/mnt/usb/ABCD-1234",
        "fs_type": "ext4",
        "ts": EVENT_TS,
    }
    payload.update(overrides)
    return payload


def write_payload(directory: Path, payload: object, name: str = "event.json") -> Path:
    path = directory / name
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


def write_event(
    directory: Path,
    *,
    name: str | None = None,
    mountpoint: str | None = None,
    **overrides: object,
) -> Path:
    payload = default_payload(**overrides)
    payload["mountpoint"] = (
        mountpoint if mountpoint is not None else str(directory / str(payload["uuid"]))
    )
    return write_payload(
        directory,
        payload,
        name or f"{payload['action']}-{payload['uuid']}.json",
    )


def make_plan() -> RunPlan:
    return RunPlan(
        items=[PlanItem("Movies/Heat.mkv", "Heat.mkv", 2)],
        skipped=[],
        warnings=[],
        total_bytes=2,
    )


def drive_row(conn, uuid: str):
    return conn.execute("SELECT * FROM drives WHERE uuid = ?", (uuid,)).fetchone()


# ---------------------------------------------------------------------------
# parse_event
# ---------------------------------------------------------------------------


def test_parse_event_reads_valid_payload(tmp_path: Path):
    event = parse_event(write_event(tmp_path, uuid="ABCD-1234"))

    assert event == DriveEvent(
        action="add",
        uuid="ABCD-1234",
        label="Test Drive",
        serial="SN123",
        device="/dev/sdb1",
        mountpoint=str(tmp_path / "ABCD-1234"),
        fs_type="ext4",
        ts=EVENT_TS,
    )


def test_parse_event_result_is_frozen(tmp_path: Path):
    event = parse_event(write_event(tmp_path))

    with pytest.raises(AttributeError):
        event.action = "remove"  # type: ignore[misc]


def test_parse_event_accepts_null_label_and_serial(tmp_path: Path):
    event = parse_event(write_event(tmp_path, label=None, serial=None))

    assert event.label is None
    assert event.serial is None


def test_parse_event_accepts_extra_keys(tmp_path: Path):
    payload = default_payload(uuid="ABCD-1234", future_field="ignored")
    path = write_payload(tmp_path, payload)

    assert parse_event(path).uuid == "ABCD-1234"


def test_parse_event_rejects_malformed_json(tmp_path: Path):
    path = tmp_path / "bad.json"
    path.write_text("{nope", encoding="utf-8")

    with pytest.raises(EventError):
        parse_event(path)


def test_parse_event_rejects_non_object_json(tmp_path: Path):
    path = write_payload(tmp_path, ["add"])

    with pytest.raises(EventError):
        parse_event(path)


def test_parse_event_rejects_missing_file(tmp_path: Path):
    with pytest.raises(EventError):
        parse_event(tmp_path / "missing.json")


@pytest.mark.parametrize(
    "key",
    [
        "version",
        "action",
        "uuid",
        "label",
        "serial",
        "device",
        "mountpoint",
        "fs_type",
        "ts",
    ],
)
def test_parse_event_rejects_missing_key(tmp_path: Path, key: str):
    payload = default_payload()
    del payload[key]
    path = write_payload(tmp_path, payload)

    with pytest.raises(EventError):
        parse_event(path)


@pytest.mark.parametrize(
    "overrides",
    [
        {"version": 2},
        {"version": "1"},
        {"version": 1.0},
        {"version": True},
        {"version": None},
        {"action": "copy"},
        {"action": 1},
        {"action": None},
        {"uuid": 123},
        {"uuid": ""},
        {"uuid": "."},
        {"uuid": ".."},
        {"uuid": "a/b"},
        {"uuid": "../etc"},
        {"uuid": "..\\etc"},
        {"uuid": "has space"},
        {"label": 5},
        {"label": []},
        {"serial": {}},
        {"device": None},
        {"device": ""},
        {"mountpoint": None},
        {"mountpoint": ""},
        {"fs_type": 3},
        {"fs_type": ""},
        {"ts": None},
        {"ts": ""},
        {"ts": 1700000000},
    ],
)
def test_parse_event_rejects_invalid_payloads(tmp_path: Path, overrides: dict):
    path = write_payload(tmp_path, default_payload(**overrides))

    with pytest.raises(EventError):
        parse_event(path)


# ---------------------------------------------------------------------------
# apply_event
# ---------------------------------------------------------------------------


def test_add_event_upserts_present_drive_and_calls_back(conn, tmp_path: Path):
    event_file = write_event(tmp_path, action="add", uuid="ABCD-1234")
    calls = []
    drive_id = apply_event(
        conn, parse_event(event_file), lambda i, p: calls.append((i, p))
    )

    assert (
        conn.execute("SELECT present FROM drives WHERE id=?", (drive_id,)).fetchone()[0]
        == 1
    )
    assert calls == [(drive_id, tmp_path / "ABCD-1234")]

    row = drive_row(conn, "ABCD-1234")
    assert row["label"] == "Test Drive"
    assert row["serial"] == "SN123"
    assert row["fs_type"] == "ext4"
    assert row["mountpoint"] == str(tmp_path / "ABCD-1234")


def test_add_event_records_processed_event_row(conn, tmp_path: Path):
    event = parse_event(write_event(tmp_path, uuid="ABCD-1234"))
    drive_id = apply_event(conn, event)

    row = conn.execute(
        "SELECT action, level, drive_id, payload_json, processed "
        "FROM events ORDER BY id DESC"
    ).fetchone()
    assert row["action"] == "add"
    assert row["level"] == "info"
    assert row["drive_id"] == drive_id
    assert row["processed"] == 1
    payload = json.loads(row["payload_json"])
    assert payload["uuid"] == "ABCD-1234"
    assert payload["ts"] == EVENT_TS


def test_add_callback_runs_after_drive_state_is_committed(conn, tmp_path: Path):
    observed: list[int] = []

    def callback(drive_id: int, mountpoint: Path) -> None:
        observed.append(
            conn.execute(
                "SELECT present FROM drives WHERE id=?", (drive_id,)
            ).fetchone()[0]
        )

    apply_event(conn, parse_event(write_event(tmp_path, uuid="ABCD-1234")), callback)

    assert observed == [1]


def test_duplicate_add_keeps_one_drive_row_and_updates_last_seen(conn, tmp_path: Path):
    event_file = write_event(tmp_path, action="add", uuid="ABCD-1234")
    first_id = apply_event(conn, parse_event(event_file))
    first_seen = drive_row(conn, "ABCD-1234")["first_seen"]
    calls = []

    second_id = apply_event(
        conn, parse_event(event_file), lambda i, p: calls.append((i, p))
    )

    assert second_id == first_id
    assert (
        conn.execute("SELECT count(*) FROM drives WHERE uuid = 'ABCD-1234'").fetchone()[
            0
        ]
        == 1
    )
    assert drive_row(conn, "ABCD-1234")["present"] == 1
    assert drive_row(conn, "ABCD-1234")["first_seen"] == first_seen
    assert calls == [(first_id, tmp_path / "ABCD-1234")]
    assert (
        conn.execute("SELECT count(*) FROM events WHERE action = 'add'").fetchone()[0]
        == 2
    )


def test_add_updates_metadata_without_erasing_missing_values(conn, tmp_path: Path):
    first = parse_event(
        write_event(
            tmp_path,
            uuid="ABCD-1234",
            name="first.json",
            label="Old Label",
            serial="KEEP-ME",
            fs_type="ext4",
        )
    )
    drive_id = apply_event(conn, first)

    second = parse_event(
        write_event(
            tmp_path,
            uuid="ABCD-1234",
            name="second.json",
            label="New Label",
            serial=None,
            fs_type="vfat",
            mountpoint="/mnt/usb/remounted",
        )
    )
    assert apply_event(conn, second) == drive_id

    row = drive_row(conn, "ABCD-1234")
    assert row["label"] == "New Label"
    assert row["serial"] == "KEEP-ME"
    assert row["fs_type"] == "vfat"
    assert row["mountpoint"] == "/mnt/usb/remounted"
    assert row["present"] == 1


def test_remove_event_marks_absent_and_interrupts(conn, tmp_path: Path):
    drive_id = apply_event(
        conn,
        parse_event(
            write_event(tmp_path, action="add", uuid="ABCD-1234", name="add.json")
        ),
    )
    run_id = create_run(conn, drive_id, None, "movies", "review", make_plan())
    conn.execute(
        "UPDATE runs SET status = 'running', "
        "started_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?",
        (run_id,),
    )
    conn.execute("UPDATE run_items SET status = 'running' WHERE run_id = ?", (run_id,))
    conn.commit()
    calls = []

    returned = apply_event(
        conn,
        parse_event(
            write_event(tmp_path, action="remove", uuid="ABCD-1234", name="remove.json")
        ),
        lambda i, p: calls.append((i, p)),
    )

    assert returned == drive_id
    assert conn.execute("SELECT present FROM drives").fetchone()[0] == 0
    assert drive_row(conn, "ABCD-1234")["present"] == 0
    assert drive_row(conn, "ABCD-1234")["mountpoint"] == str(tmp_path / "ABCD-1234")
    run = get_run(conn, run_id)
    assert run["status"] == "interrupted"
    assert run["error"] == "drive removed"
    item = conn.execute(
        "SELECT status, error FROM run_items WHERE run_id = ?", (run_id,)
    ).fetchone()
    assert item["status"] == "interrupted"
    assert item["error"] == "drive removed"
    assert calls == []
    assert (
        conn.execute("SELECT count(*) FROM drives WHERE uuid = 'ABCD-1234'").fetchone()[
            0
        ]
        == 1
    )


def test_remove_event_for_unknown_drive_creates_absent_row(conn, tmp_path: Path):
    drive_id = apply_event(
        conn,
        parse_event(write_event(tmp_path, action="remove", uuid="ZZZZ-9999")),
    )

    row = drive_row(conn, "ZZZZ-9999")
    assert row["id"] == drive_id
    assert row["present"] == 0


# ---------------------------------------------------------------------------
# process_pending
# ---------------------------------------------------------------------------


def test_malformed_event_is_quarantined(conn, tmp_path: Path):
    bad = tmp_path / "bad.json"
    bad.write_text("{nope", encoding="utf-8")
    with pytest.raises(EventError):
        parse_event(bad)
    assert process_pending(conn, tmp_path) == 0
    assert (tmp_path / "bad" / "bad.json").exists()
    assert not bad.exists()
    row = conn.execute("SELECT action, level FROM events").fetchone()
    assert row["action"] == "event_malformed"
    assert row["level"] == "error"


def test_process_pending_applies_valid_events_and_quarantines_bad(conn, tmp_path: Path):
    add_file = write_event(tmp_path, action="add", uuid="ABCD-1234", name="add.json")
    bad = write_payload(tmp_path, {"version": 2}, name="bad.json")
    noise = tmp_path / "notes.txt"
    noise.write_text("not an event", encoding="utf-8")
    calls = []

    processed = process_pending(conn, tmp_path, lambda i, p: calls.append((i, p)))

    assert processed == 1
    assert not add_file.exists()
    assert not bad.exists()
    assert (tmp_path / "bad" / "bad.json").exists()
    assert noise.exists()
    assert drive_row(conn, "ABCD-1234")["present"] == 1
    drive_id = drive_row(conn, "ABCD-1234")["id"]
    assert calls == [(drive_id, tmp_path / "ABCD-1234")]


def test_process_pending_empty_spool_returns_zero(conn, tmp_path: Path):
    assert process_pending(conn, tmp_path) == 0
    assert process_pending(conn, tmp_path) == 0


def test_process_pending_missing_spool_returns_zero(conn, tmp_path: Path):
    assert process_pending(conn, tmp_path / "missing") == 0


def test_process_pending_keeps_event_file_when_callback_fails(conn, tmp_path: Path):
    add_file = write_event(tmp_path, action="add", uuid="ABCD-1234")

    def failing_callback(drive_id: int, mountpoint: Path) -> None:
        raise RuntimeError("pipeline unavailable")

    with pytest.raises(RuntimeError, match="pipeline unavailable"):
        process_pending(conn, tmp_path, failing_callback)

    assert add_file.exists()
    assert drive_row(conn, "ABCD-1234")["present"] == 1


def test_process_pending_quarantine_preserves_bad_file_content(conn, tmp_path: Path):
    bad = tmp_path / "broken.json"
    bad.write_text("{nope", encoding="utf-8")

    assert process_pending(conn, tmp_path) == 0

    quarantined = tmp_path / "bad" / "broken.json"
    assert quarantined.read_text(encoding="utf-8") == "{nope"


# ---------------------------------------------------------------------------
# scan_mounted
# ---------------------------------------------------------------------------


def test_scan_mounted_discovers_existing_dirs(conn, tmp_path: Path):
    (tmp_path / "ABCD-1234").mkdir()

    assert scan_mounted(conn, tmp_path) == ["ABCD-1234"]


def test_scan_mounted_registers_present_drives_and_calls_back(conn, tmp_path: Path):
    (tmp_path / "BBBB-2222").mkdir()
    (tmp_path / "AAAA-1111").mkdir()
    calls = []

    found = scan_mounted(conn, tmp_path, lambda i, p: calls.append((i, p)))

    assert found == ["AAAA-1111", "BBBB-2222"]
    assert [path.name for _, path in calls] == ["AAAA-1111", "BBBB-2222"]
    for uuid, (drive_id, path) in zip(found, calls):
        row = drive_row(conn, uuid)
        assert row["id"] == drive_id
        assert row["present"] == 1
        assert row["mountpoint"] == str(path)
        assert row["label"] is None
        assert row["fs_type"] is None


def test_scan_mounted_callback_sees_committed_present_row(conn, tmp_path: Path):
    (tmp_path / "ABCD-1234").mkdir()
    observed: list[int] = []

    scan_mounted(
        conn,
        tmp_path,
        lambda drive_id, path: observed.append(
            conn.execute(
                "SELECT present FROM drives WHERE id=?", (drive_id,)
            ).fetchone()[0]
        ),
    )

    assert observed == [1]


def test_scan_mounted_ignores_files_and_invalid_names(conn, tmp_path: Path):
    (tmp_path / "GOOD-UUID").mkdir()
    (tmp_path / "bad name").mkdir()
    (tmp_path / "bad+name").mkdir()
    (tmp_path / "FILE.JSON").write_text("x", encoding="utf-8")
    (tmp_path / ".hidden").mkdir()

    found = scan_mounted(conn, tmp_path)

    assert found == [".hidden", "GOOD-UUID"]
    assert drive_row(conn, "bad name") is None
    assert drive_row(conn, "bad+name") is None


def test_scan_mounted_follows_mounted_symlink(conn, tmp_path: Path):
    target = tmp_path / "target"
    target.mkdir()
    mounts = tmp_path / "mounts"
    mounts.mkdir()
    (mounts / "ABCD-1234").symlink_to(target)

    assert scan_mounted(conn, mounts) == ["ABCD-1234"]
    assert drive_row(conn, "ABCD-1234")["mountpoint"] == str(mounts / "ABCD-1234")


def test_scan_mounted_is_idempotent(conn, tmp_path: Path):
    (tmp_path / "ABCD-1234").mkdir()
    calls = []

    first = scan_mounted(conn, tmp_path, lambda i, p: calls.append((i, p)))
    second = scan_mounted(conn, tmp_path, lambda i, p: calls.append((i, p)))

    assert first == second == ["ABCD-1234"]
    assert calls[0][0] == calls[1][0]
    assert (
        conn.execute("SELECT count(*) FROM drives WHERE uuid = 'ABCD-1234'").fetchone()[
            0
        ]
        == 1
    )


def test_scan_mounted_missing_root_returns_empty(conn, tmp_path: Path):
    assert scan_mounted(conn, tmp_path / "missing") == []


def test_scan_mounted_does_not_clear_drives_outside_the_mount_root(
    conn, tmp_path: Path
):
    conn.execute("UPDATE drives SET present = 1 WHERE id = 1")
    conn.commit()

    assert scan_mounted(conn, tmp_path) == []
    assert conn.execute("SELECT present FROM drives WHERE id = 1").fetchone()[0] == 1


# ---------------------------------------------------------------------------
# EventSpoolWatcher
# ---------------------------------------------------------------------------


class FakeObserver:
    instances: ClassVar[list[FakeObserver]] = []

    def __init__(self) -> None:
        self.scheduled: list[tuple[object, str, bool]] = []
        self.started = False
        self.stopped = False
        self.joined = False
        FakeObserver.instances.append(self)

    def schedule(self, handler, path, *, recursive: bool) -> None:
        self.scheduled.append((handler, path, recursive))

    def start(self) -> None:
        self.started = True

    def stop(self) -> None:
        self.stopped = True

    def join(self, timeout=None) -> None:
        self.joined = True


@pytest.fixture
def fake_observers(monkeypatch):
    FakeObserver.instances = []
    monkeypatch.setattr(events_module, "Observer", FakeObserver)
    return FakeObserver.instances


def test_watcher_start_schedules_spool_dir_without_recursion(
    fake_observers, tmp_path: Path
):
    watcher = EventSpoolWatcher(tmp_path, lambda path: None)

    watcher.start()

    assert len(fake_observers) == 1
    observer = fake_observers[0]
    assert observer.started is True
    assert len(observer.scheduled) == 1
    handler, path, recursive = observer.scheduled[0]
    assert isinstance(handler, events_module.FileSystemEventHandler)
    assert path == str(tmp_path)
    assert recursive is False


def test_watcher_start_and_stop_are_idempotent(fake_observers, tmp_path: Path):
    watcher = EventSpoolWatcher(tmp_path, lambda path: None)

    watcher.stop()
    watcher.start()
    watcher.start()
    assert len(fake_observers) == 1

    watcher.stop()
    watcher.stop()
    observer = fake_observers[0]
    assert observer.stopped is True
    assert observer.joined is True


def test_watcher_dispatches_created_and_moved_json_files(
    fake_observers, tmp_path: Path
):
    seen: list[Path] = []
    watcher = EventSpoolWatcher(tmp_path, seen.append)
    watcher.start()
    handler = fake_observers[0].scheduled[0][0]

    created = tmp_path / "created.json"
    moved_in = tmp_path / "moved.json"
    handler.dispatch(FileCreatedEvent(str(created)))
    handler.dispatch(FileMovedEvent(str(tmp_path / "staging.json"), str(moved_in)))

    assert seen == [created, moved_in]


def test_watcher_ignores_non_json_directories_and_moves_out(
    fake_observers, tmp_path: Path
):
    seen: list[Path] = []
    watcher = EventSpoolWatcher(tmp_path, seen.append)
    watcher.start()
    handler = fake_observers[0].scheduled[0][0]

    handler.dispatch(FileCreatedEvent(str(tmp_path / "note.txt")))
    handler.dispatch(DirCreatedEvent(str(tmp_path / "dir.json")))
    handler.dispatch(
        FileMovedEvent(str(tmp_path / "event.json"), str(tmp_path.parent / "away.json"))
    )

    assert seen == []
