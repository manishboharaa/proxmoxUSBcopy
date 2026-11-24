from __future__ import annotations

import hashlib
import threading
import time
from pathlib import Path

import pytest

from usbcopy import worker as worker_module
from usbcopy.config import Config, Destination
from usbcopy.copier import CopyError
from usbcopy.planner import PlanItem, RunPlan, build_run_plan
from usbcopy.runs import (
    create_run,
    get_run,
    interrupt_active_run,
    recover_orphaned_runs,
)
from usbcopy.worker import RunWorker, execute_run

EMPTY_SHA256 = hashlib.sha256(b"hi").hexdigest()


def make_config(**overrides) -> Config:
    values = {
        "port": 8088,
        "username": "admin",
        "password_hash": "hash",
        "session_secret": "secret",
        "default_folder": "",
        "default_mode": "review",
        "auto_enabled": False,
        "auto_destination": "movies",
        "verify_sha256": True,
        "chunk_size_mb": 8,
        "retries": 3,
        "preserve_mtime": True,
        "destinations": {
            "movies": Destination("movies", Path("/data/movies")),
            "series": Destination("series", Path("/data/series")),
        },
        "db_path": Path("/tmp/usbcopy.db"),
        "events_dir": Path("/tmp/events"),
        "mounts_root": Path("/mnt/usb"),
        "reconcile_minutes": 0,
        "skip_hidden_root_dirs": True,
    }
    values.update(overrides)
    return Config(**values)


@pytest.fixture(autouse=True)
def _no_retry_sleep(monkeypatch):
    monkeypatch.setattr(worker_module, "sleep", lambda seconds: None)


@pytest.fixture
def config() -> Config:
    return make_config()


@pytest.fixture
def dirs(tmp_path: Path) -> dict[str, Path]:
    source = tmp_path / "source"
    movie_dir = source / "Movies" / "Heat (1995)"
    movie_dir.mkdir(parents=True)
    (movie_dir / "Heat.mkv").write_bytes(b"hi")
    movies = tmp_path / "movies"
    series = tmp_path / "series"
    movies.mkdir()
    series.mkdir()
    return {"source": source, "movies": movies, "series": series}


@pytest.fixture
def plan(dirs: dict[str, Path]) -> RunPlan:
    source = dirs["source"] / "Movies" / "Heat (1995)" / "Heat.mkv"
    return RunPlan(
        items=[PlanItem(str(source), "Heat (1995)/Heat.mkv", 2)],
        skipped=[],
        warnings=[],
        total_bytes=2,
    )


@pytest.fixture
def db_path(tmp_path: Path) -> Path:
    return tmp_path / "usbcopy.db"


def _plan_for(dirs: dict[str, Path], pairs: list[tuple[str, str]]) -> RunPlan:
    items = []
    total = 0
    for source_rel, dest_rel in pairs:
        source = dirs["source"] / source_rel
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_bytes(b"hi")
        items.append(PlanItem(str(source), dest_rel, 2))
        total += 2
    return RunPlan(items=items, skipped=[], warnings=[], total_bytes=total)


def _items(conn, run_id: int):
    return conn.execute(
        "SELECT * FROM run_items WHERE run_id = ? ORDER BY id", (run_id,)
    ).fetchall()


def _wait_for(predicate, timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return False


def test_create_run_records_plan(conn, plan):
    run_id = create_run(conn, 1, None, "movies", "review", plan)

    run = get_run(conn, run_id)
    assert run["status"] == "queued"
    assert run["drive_id"] == 1
    assert run["inventory_id"] is None
    assert run["destination_id"] is None
    assert run["destination_key"] == "movies"
    assert run["mode"] == "review"
    assert run["files_total"] == 1
    assert run["bytes_total"] == 2
    assert run["bytes_done"] == 0
    assert run["started_at"] is None
    assert run["finished_at"] is None
    assert run["error"] is None

    items = _items(conn, run_id)
    assert len(items) == 1
    assert items[0]["rel_path"] == plan.items[0].source_rel
    assert items[0]["dest_rel_path"] == "Heat (1995)/Heat.mkv"
    assert items[0]["size"] == 2
    assert items[0]["status"] == "pending"
    assert items[0]["bytes_done"] == 0
    assert items[0]["attempts"] == 0


def test_create_run_preserves_item_order(conn, dirs):
    plan = _plan_for(dirs, [("b.mkv", "one/b.mkv"), ("a.mkv", "two/a.mkv")])
    run_id = create_run(conn, None, None, "movies", "review", plan)
    assert [item["dest_rel_path"] for item in _items(conn, run_id)] == [
        "one/b.mkv",
        "two/a.mkv",
    ]


def test_get_run_returns_none_for_unknown_id(conn):
    assert get_run(conn, 9999) is None


def test_execute_run_copies_items_and_records_status(conn, config, plan, dirs):
    run_id = create_run(conn, None, None, "movies", "review", plan)

    execute_run(conn, run_id, config, {"movies": dirs["movies"]}, threading.Event())

    run = get_run(conn, run_id)
    assert run["status"] == "completed"
    assert run["bytes_done"] == 2
    assert run["error"] is None
    assert run["started_at"] is not None
    assert run["finished_at"] is not None
    assert (dirs["movies"] / "Heat (1995)/Heat.mkv").read_bytes() == b"hi"

    item = _items(conn, run_id)[0]
    assert item["status"] == "completed"
    assert item["bytes_done"] == 2
    assert item["sha256"] == EMPTY_SHA256
    assert item["attempts"] == 1
    assert item["temp_path"] is None
    assert item["error"] is None
    assert item["started_at"] is not None
    assert item["finished_at"] is not None
    assert list(dirs["movies"].rglob(".usbcopy.*.part")) == []


def test_execute_run_creates_nested_destination_dirs(conn, config, dirs):
    plan = _plan_for(dirs, [("Movies/Heat (1995)/Heat.mkv", "Heat (1995)/Heat.mkv")])
    run_id = create_run(conn, None, None, "movies", "review", plan)
    execute_run(conn, run_id, config, {"movies": dirs["movies"]}, threading.Event())
    assert get_run(conn, run_id)["status"] == "completed"
    assert (dirs["movies"] / "Heat (1995)").is_dir()


def test_execute_run_copies_items_in_plan_order(conn, config, dirs, monkeypatch):
    plan = _plan_for(dirs, [("b.mkv", "b.mkv"), ("a.mkv", "a.mkv")])
    real = worker_module.copy_file
    calls: list[str] = []

    def recording(source, destination, **kwargs):
        calls.append(Path(destination).name)
        return real(source, destination, **kwargs)

    monkeypatch.setattr(worker_module, "copy_file", recording)
    run_id = create_run(conn, None, None, "movies", "review", plan)
    execute_run(conn, run_id, config, {"movies": dirs["movies"]}, threading.Event())

    assert calls == ["b.mkv", "a.mkv"]
    assert get_run(conn, run_id)["status"] == "completed"


def test_execute_run_resolves_relative_sources_from_inventory(conn, inventory, dirs):
    plan = build_run_plan(conn, inventory, ["Movies"], dirs["movies"], free_bytes=10**9)
    run_id = create_run(conn, 1, inventory, "movies", "review", plan)
    execute_run(
        conn, run_id, make_config(), {"movies": dirs["movies"]}, threading.Event()
    )
    run = get_run(conn, run_id)
    assert run["status"] == "completed"
    assert (dirs["movies"] / "Heat (1995)/Heat.mkv").read_bytes() == b"hi"


def test_execute_run_leaves_source_unchanged(conn, config, plan, dirs):
    source = Path(plan.items[0].source_rel)
    before = source.read_bytes()
    run_id = create_run(conn, None, None, "movies", "review", plan)
    execute_run(conn, run_id, config, {"movies": dirs["movies"]}, threading.Event())
    assert source.read_bytes() == before


def test_retries_twice_then_succeeds(conn, config, plan, dirs, monkeypatch):
    calls = {"n": 0}
    real = worker_module.copy_file
    sleeps: list[float] = []

    def flaky(*args, **kwargs):
        calls["n"] += 1
        if calls["n"] < 3:
            raise CopyError("transient")
        return real(*args, **kwargs)

    monkeypatch.setattr(worker_module, "copy_file", flaky)
    monkeypatch.setattr(worker_module, "sleep", sleeps.append)

    run_id = create_run(conn, None, None, "movies", "review", plan)
    execute_run(conn, run_id, config, {"movies": dirs["movies"]}, threading.Event())

    assert calls["n"] == 3
    assert sleeps == [2, 5]
    assert get_run(conn, run_id)["status"] == "completed"
    assert _items(conn, run_id)[0]["attempts"] == 3


def test_retry_exhaustion_fails_item_and_continues(conn, config, dirs, monkeypatch):
    plan = _plan_for(dirs, [("bad.mkv", "bad.mkv"), ("good.mkv", "good.mkv")])
    real = worker_module.copy_file
    sleeps: list[float] = []

    def flaky(source, destination, **kwargs):
        if Path(destination).name == "bad.mkv":
            raise CopyError("transient")
        return real(source, destination, **kwargs)

    monkeypatch.setattr(worker_module, "copy_file", flaky)
    monkeypatch.setattr(worker_module, "sleep", sleeps.append)

    run_id = create_run(conn, None, None, "movies", "review", plan)
    execute_run(conn, run_id, config, {"movies": dirs["movies"]}, threading.Event())

    run = get_run(conn, run_id)
    assert run["status"] == "completed_with_errors"
    assert "1" in run["error"]
    bad, good = _items(conn, run_id)
    assert bad["status"] == "failed"
    assert bad["attempts"] == 3
    assert "transient" in bad["error"]
    assert good["status"] == "completed"
    assert sleeps == [2, 5]
    assert (dirs["movies"] / "good.mkv").read_bytes() == b"hi"
    assert not (dirs["movies"] / "bad.mkv").exists()
    assert list(dirs["movies"].rglob(".usbcopy.*.part")) == []


def test_backoff_is_capped_at_ten_seconds(conn, dirs, monkeypatch):
    plan = _plan_for(dirs, [("bad.mkv", "bad.mkv")])
    sleeps: list[float] = []

    def always_fails(*args, **kwargs):
        raise CopyError("transient")

    monkeypatch.setattr(worker_module, "copy_file", always_fails)
    monkeypatch.setattr(worker_module, "sleep", sleeps.append)

    run_id = create_run(conn, None, None, "movies", "review", plan)
    execute_run(
        conn,
        run_id,
        make_config(retries=5),
        {"movies": dirs["movies"]},
        threading.Event(),
    )

    assert sleeps == [2, 5, 10, 10]
    assert _items(conn, run_id)[0]["attempts"] == 5


def test_zero_retries_still_attempts_once(conn, dirs):
    plan = _plan_for(dirs, [("one.mkv", "one.mkv")])
    run_id = create_run(conn, None, None, "movies", "review", plan)
    execute_run(
        conn,
        run_id,
        make_config(retries=0),
        {"movies": dirs["movies"]},
        threading.Event(),
    )
    assert get_run(conn, run_id)["status"] == "completed"
    assert (dirs["movies"] / "one.mkv").read_bytes() == b"hi"


def test_cancellation_cleans_temp_and_interrupts(conn, config, plan, dirs):
    cancel = threading.Event()
    cancel.set()
    run_id = create_run(conn, None, None, "movies", "review", plan)

    execute_run(conn, run_id, config, {"movies": dirs["movies"]}, cancel)

    assert get_run(conn, run_id)["status"] == "interrupted"
    assert [item["status"] for item in _items(conn, run_id)] == ["cancelled"]
    assert list(dirs["movies"].rglob(".usbcopy.*.part")) == []
    assert not (dirs["movies"] / "Heat (1995)/Heat.mkv").exists()


def test_cancellation_after_first_item_cancels_remaining(
    conn, config, dirs, monkeypatch
):
    plan = _plan_for(dirs, [("one.mkv", "one.mkv"), ("two.mkv", "two.mkv")])
    real = worker_module.copy_file
    cancel = threading.Event()

    def first_then_cancel(source, destination, **kwargs):
        result = real(source, destination, **kwargs)
        cancel.set()
        return result

    monkeypatch.setattr(worker_module, "copy_file", first_then_cancel)

    run_id = create_run(conn, None, None, "movies", "review", plan)
    execute_run(conn, run_id, config, {"movies": dirs["movies"]}, cancel)

    assert get_run(conn, run_id)["status"] == "interrupted"
    first, second = _items(conn, run_id)
    assert first["status"] == "completed"
    assert second["status"] == "cancelled"
    assert (dirs["movies"] / "one.mkv").read_bytes() == b"hi"
    assert not (dirs["movies"] / "two.mkv").exists()
    assert list(dirs["movies"].rglob(".usbcopy.*.part")) == []


def test_cancellation_during_retries_marks_item_interrupted(
    conn, config, plan, dirs, monkeypatch
):
    cancel = threading.Event()
    sleeps: list[float] = []

    def fails_then_cancels(*args, **kwargs):
        cancel.set()
        raise CopyError("drive removed")

    monkeypatch.setattr(worker_module, "copy_file", fails_then_cancels)
    monkeypatch.setattr(worker_module, "sleep", sleeps.append)

    run_id = create_run(conn, None, None, "movies", "review", plan)
    execute_run(conn, run_id, config, {"movies": dirs["movies"]}, cancel)

    assert get_run(conn, run_id)["status"] == "interrupted"
    item = _items(conn, run_id)[0]
    assert item["status"] == "interrupted"
    assert item["attempts"] == 1
    assert sleeps == []
    assert list(dirs["movies"].rglob(".usbcopy.*.part")) == []


def test_unexpected_error_marks_run_failed(conn, config, plan, dirs, monkeypatch):
    def boom(*args, **kwargs):
        raise RuntimeError("boom")

    monkeypatch.setattr(worker_module, "copy_file", boom)

    run_id = create_run(conn, None, None, "movies", "review", plan)
    with pytest.raises(RuntimeError, match="boom"):
        execute_run(conn, run_id, config, {"movies": dirs["movies"]}, threading.Event())

    run = get_run(conn, run_id)
    assert run["status"] == "failed"
    assert run["error"] == "boom"
    assert run["finished_at"] is not None
    assert _items(conn, run_id)[0]["status"] == "failed"


def test_unknown_destination_key_fails_run(conn, config, plan):
    run_id = create_run(conn, None, None, "movies", "review", plan)
    with pytest.raises(ValueError, match="destination"):
        execute_run(conn, run_id, config, {}, threading.Event())
    run = get_run(conn, run_id)
    assert run["status"] == "failed"
    assert "movies" in run["error"]


def test_execute_run_skips_non_queued_run(conn, config, plan, dirs):
    run_id = create_run(conn, None, None, "movies", "review", plan)
    conn.execute("UPDATE runs SET status = 'completed' WHERE id = ?", (run_id,))
    conn.commit()

    execute_run(conn, run_id, config, {"movies": dirs["movies"]}, threading.Event())

    assert get_run(conn, run_id)["status"] == "completed"
    assert _items(conn, run_id)[0]["status"] == "pending"


def test_progress_persists_on_item_transitions_with_frozen_clock(
    conn, config, dirs, monkeypatch
):
    plan = _plan_for(dirs, [("one.mkv", "one.mkv"), ("two.mkv", "two.mkv")])
    monkeypatch.setattr(worker_module, "monotonic", lambda: 100.0)

    run_id = create_run(conn, None, None, "movies", "review", plan)
    execute_run(conn, run_id, config, {"movies": dirs["movies"]}, threading.Event())

    assert get_run(conn, run_id)["bytes_done"] == 4


def test_progress_throttles_between_transitions(conn, plan, monkeypatch):
    ticks = iter([10.0, 10.5, 11.0, 11.5, 12.2])
    monkeypatch.setattr(worker_module, "monotonic", lambda: next(ticks))
    run_id = create_run(conn, None, None, "movies", "review", plan)

    progress = worker_module._RunProgress(conn, run_id)
    progress.persist(1)
    assert get_run(conn, run_id)["bytes_done"] == 0

    progress.persist(1, force=True)
    assert get_run(conn, run_id)["bytes_done"] == 1

    progress.persist(2)
    assert get_run(conn, run_id)["bytes_done"] == 1

    progress.persist(2)
    assert get_run(conn, run_id)["bytes_done"] == 2


def test_orphaned_runs_recovered(conn, plan):
    run_id = create_run(conn, None, None, "movies", "review", plan)
    conn.execute(
        "UPDATE runs SET status = 'running', started_at = 'now' WHERE id = ?",
        (run_id,),
    )
    conn.execute("UPDATE run_items SET status = 'running' WHERE run_id = ?", (run_id,))
    conn.commit()

    assert recover_orphaned_runs(conn) == 1

    run = get_run(conn, run_id)
    assert run["status"] == "interrupted"
    assert run["finished_at"] is not None
    assert "recovered" in run["error"]
    assert _items(conn, run_id)[0]["status"] == "interrupted"


def test_recover_orphans_cancels_pending_items(conn, dirs):
    plan = _plan_for(dirs, [("one.mkv", "one.mkv"), ("two.mkv", "two.mkv")])
    run_id = create_run(conn, None, None, "movies", "review", plan)
    conn.execute("UPDATE runs SET status = 'running' WHERE id = ?", (run_id,))
    first_item = _items(conn, run_id)[0]["id"]
    conn.execute("UPDATE run_items SET status = 'running' WHERE id = ?", (first_item,))
    conn.commit()

    assert recover_orphaned_runs(conn) == 1
    assert [item["status"] for item in _items(conn, run_id)] == [
        "interrupted",
        "cancelled",
    ]


def test_recover_orphans_ignores_other_statuses(conn, plan):
    queued = create_run(conn, None, None, "movies", "review", plan)
    completed = create_run(conn, None, None, "movies", "review", plan)
    conn.execute("UPDATE runs SET status = 'completed' WHERE id = ?", (completed,))
    conn.commit()

    assert recover_orphaned_runs(conn) == 0
    assert get_run(conn, queued)["status"] == "queued"
    assert get_run(conn, completed)["status"] == "completed"


def test_interrupt_active_run_marks_drive_runs(conn, dirs):
    conn.execute("INSERT INTO drives (id, uuid, label) VALUES (2, 'OTHER', 'Other')")
    queued = create_run(
        conn, 1, None, "movies", "review", _plan_for(dirs, [("q.mkv", "q.mkv")])
    )
    running = create_run(
        conn,
        1,
        None,
        "movies",
        "review",
        _plan_for(dirs, [("r1.mkv", "r1.mkv"), ("r2.mkv", "r2.mkv")]),
    )
    finished = create_run(
        conn, 1, None, "movies", "review", _plan_for(dirs, [("f.mkv", "f.mkv")])
    )
    other = create_run(
        conn, 2, None, "movies", "review", _plan_for(dirs, [("o.mkv", "o.mkv")])
    )

    conn.execute("UPDATE runs SET status = 'running' WHERE id = ?", (running,))
    conn.execute("UPDATE runs SET status = 'completed' WHERE id = ?", (finished,))
    conn.execute("UPDATE runs SET status = 'running' WHERE id = ?", (other,))
    first = _items(conn, running)[0]["id"]
    conn.execute("UPDATE run_items SET status = 'running' WHERE id = ?", (first,))
    conn.commit()

    assert interrupt_active_run(conn, 1, "drive removed") == 2

    assert get_run(conn, queued)["status"] == "interrupted"
    assert get_run(conn, queued)["error"] == "drive removed"
    assert get_run(conn, queued)["finished_at"] is not None
    assert get_run(conn, running)["status"] == "interrupted"
    assert get_run(conn, running)["error"] == "drive removed"
    assert get_run(conn, finished)["status"] == "completed"
    assert get_run(conn, other)["status"] == "running"

    assert [item["status"] for item in _items(conn, queued)] == ["cancelled"]
    assert [item["status"] for item in _items(conn, running)] == [
        "interrupted",
        "cancelled",
    ]
    assert _items(conn, running)[0]["error"] == "drive removed"
    assert [item["status"] for item in _items(conn, finished)] == ["pending"]
    assert [item["status"] for item in _items(conn, other)] == ["pending"]


def test_interrupt_active_run_returns_zero_without_active_runs(conn, plan):
    completed = create_run(conn, 1, None, "movies", "review", plan)
    conn.execute("UPDATE runs SET status = 'completed' WHERE id = ?", (completed,))
    conn.commit()
    assert interrupt_active_run(conn, 1, "drive removed") == 0
    assert get_run(conn, completed)["status"] == "completed"


def test_worker_serialises_jobs(conn, db_path, config, plan, dirs):
    first = create_run(conn, None, None, "movies", "review", plan)
    second = create_run(conn, None, None, "movies", "review", plan)
    worker = RunWorker(db_path, config, {"movies": dirs["movies"]})

    worker.enqueue(first)
    worker.enqueue(second)

    assert worker.run_once() is True
    assert get_run(conn, first)["status"] == "completed"
    assert get_run(conn, second)["status"] == "queued"


def test_worker_run_once_returns_false_when_empty(db_path, config):
    worker = RunWorker(db_path, config, {})
    assert worker.run_once() is False


def test_worker_processes_each_queued_run_once(conn, db_path, config, plan, dirs):
    first = create_run(conn, None, None, "movies", "review", plan)
    second = create_run(conn, None, None, "series", "review", plan)
    worker = RunWorker(
        db_path, config, {"movies": dirs["movies"], "series": dirs["series"]}
    )
    worker.enqueue(first)
    worker.enqueue(second)

    assert worker.run_once() is True
    assert get_run(conn, second)["status"] == "queued"
    assert worker.run_once() is True
    assert get_run(conn, second)["status"] == "completed"
    assert (dirs["series"] / "Heat (1995)/Heat.mkv").read_bytes() == b"hi"
    assert worker.run_once() is False


def test_worker_opens_a_fresh_connection_per_run(
    conn, db_path, config, plan, dirs, monkeypatch
):
    opened: list[Path] = []
    real_open = worker_module.open_db

    def counting_open(path):
        opened.append(Path(path))
        return real_open(path)

    monkeypatch.setattr(worker_module, "open_db", counting_open)
    run_id = create_run(conn, None, None, "movies", "review", plan)
    worker = RunWorker(db_path, config, {"movies": dirs["movies"]})
    worker.enqueue(run_id)

    assert worker.run_once() is True
    assert opened == [db_path]


def test_worker_background_thread_processes_queue(conn, db_path, config, plan, dirs):
    run_id = create_run(conn, None, None, "movies", "review", plan)
    worker = RunWorker(db_path, config, {"movies": dirs["movies"]})
    worker.start()
    try:
        worker.enqueue(run_id)
        assert _wait_for(lambda: get_run(conn, run_id)["status"] == "completed")
    finally:
        worker.stop()
    assert (dirs["movies"] / "Heat (1995)/Heat.mkv").read_bytes() == b"hi"


def test_worker_start_and_stop_are_idempotent(db_path, config):
    worker = RunWorker(db_path, config, {})
    worker.start()
    worker.start()
    worker.stop()
    worker.stop()
