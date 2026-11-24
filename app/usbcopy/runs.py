"""Run lifecycle helpers for usbcopy.

A run is created from a validated ``RunPlan`` and executes through the copy
worker. This module owns the database transitions that are not part of the
file-copy loop itself: creation, lookup, startup recovery of orphaned runs,
and whole-drive interruption.
"""

from __future__ import annotations

import sqlite3

from usbcopy.planner import RunPlan

_NOW = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"


def create_run(
    conn: sqlite3.Connection,
    drive_id: int | None,
    inventory_id: int | None,
    destination_key: str,
    mode: str,
    plan: RunPlan,
    *,
    commit: bool = True,
) -> int:
    """Insert a queued run and its pending items, returning the run id.

    Callers that must write more rows atomically can pass ``commit=False``;
    the run, its items, and their follow-up writes then share one transaction
    and the caller commits. Default callers keep the previous behaviour.
    """
    cursor = conn.execute(
        "INSERT INTO runs "
        "(drive_id, inventory_id, destination_key, mode, status, "
        " files_total, bytes_total) "
        "VALUES (?, ?, ?, ?, 'queued', ?, ?)",
        (
            drive_id,
            inventory_id,
            destination_key,
            mode,
            len(plan.items),
            plan.total_bytes,
        ),
    )
    run_id = int(cursor.lastrowid)
    conn.executemany(
        "INSERT INTO run_items "
        "(run_id, rel_path, size, dest_rel_path, status) "
        "VALUES (?, ?, ?, ?, 'pending')",
        [(run_id, item.source_rel, item.size, item.dest_rel) for item in plan.items],
    )
    if commit:
        conn.commit()
    return run_id


def get_run(conn: sqlite3.Connection, run_id: int) -> sqlite3.Row | None:
    """Return the run row, or ``None`` when it does not exist."""
    return conn.execute("SELECT * FROM runs WHERE id = ?", (run_id,)).fetchone()


def recover_orphaned_runs(conn: sqlite3.Connection) -> int:
    """Interrupt runs left ``running`` by a crash or restart.

    In-flight items become ``interrupted``; items that never started become
    ``cancelled``. Returns the number of runs recovered.
    """
    run_ids = [
        int(row[0])
        for row in conn.execute("SELECT id FROM runs WHERE status = 'running'")
    ]
    if not run_ids:
        return 0
    for run_id in run_ids:
        conn.execute(
            "UPDATE run_items "
            f"SET status = 'interrupted', finished_at = {_NOW}, "
            "    error = 'interrupted: recovered after restart' "
            "WHERE run_id = ? AND status IN ('queued', 'running')",
            (run_id,),
        )
        conn.execute(
            "UPDATE run_items "
            f"SET status = 'cancelled', finished_at = {_NOW} "
            "WHERE run_id = ? AND status = 'pending'",
            (run_id,),
        )
        conn.execute(
            "UPDATE runs "
            f"SET status = 'interrupted', finished_at = {_NOW}, "
            "    error = 'interrupted: recovered after restart' "
            "WHERE id = ? AND status = 'running'",
            (run_id,),
        )
    conn.commit()
    return len(run_ids)


def interrupt_active_run(conn: sqlite3.Connection, drive_id: int, reason: str) -> int:
    """Interrupt queued and running runs for ``drive_id``.

    In-flight items become ``interrupted`` and remaining pending items become
    ``cancelled``. Returns the number of runs interrupted.
    """
    run_ids = [
        int(row[0])
        for row in conn.execute(
            "SELECT id FROM runs "
            "WHERE drive_id = ? AND status IN ('queued', 'running')",
            (drive_id,),
        )
    ]
    if not run_ids:
        return 0
    for run_id in run_ids:
        conn.execute(
            "UPDATE run_items "
            f"SET status = 'interrupted', finished_at = {_NOW}, error = ? "
            "WHERE run_id = ? AND status IN ('queued', 'running')",
            (reason, run_id),
        )
        conn.execute(
            "UPDATE run_items "
            f"SET status = 'cancelled', finished_at = {_NOW} "
            "WHERE run_id = ? AND status = 'pending'",
            (run_id,),
        )
        conn.execute(
            "UPDATE runs "
            f"SET status = 'interrupted', finished_at = {_NOW}, error = ? "
            "WHERE id = ? AND status IN ('queued', 'running')",
            (reason, run_id),
        )
    conn.commit()
    return len(run_ids)
