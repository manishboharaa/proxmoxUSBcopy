"""Drive-added pipeline for usbcopy.

A drive-add event always creates a metadata inventory of the whole mountpoint
so Review can browse every folder. When Auto mode is enabled, the pipeline also
plans the configured default folder into the configured auto destination and
queues the resulting run. Failures while planning Auto mode are recorded as a
warning event and never block the inventory.

The entry point is synchronous and never writes to the source; the caller
decides whether to run it inline (startup) or in a short-lived thread (live
watcher).
"""

from __future__ import annotations

import json
import shutil
import sqlite3
from collections.abc import Callable
from pathlib import Path

from usbcopy.config import Config
from usbcopy.inventory import create_inventory, scan_inventory
from usbcopy.planner import PlanError, build_run_plan
from usbcopy.runs import create_run


def handle_drive_added(
    conn: sqlite3.Connection,
    drive_id: int,
    mountpoint: Path,
    config: Config,
    enqueue_run: Callable[[int], None] | None = None,
) -> int:
    """Scan a newly added drive and optionally queue an Auto-mode run.

    The inventory root is always ``mountpoint`` (the whole drive). When
    ``config.auto_enabled`` is true, only ``config.default_folder`` is planned,
    into ``config.destinations[config.auto_destination]``, and the run is
    created with ``mode="auto"``. ``enqueue_run`` is called with the new run id
    after the run and its items are committed. A missing folder, an unavailable
    destination, or any other planning failure is recorded as a warning event
    and no run is created.

    Returns the new inventory id.
    """
    mountpoint = Path(mountpoint)
    inventory_id = create_inventory(conn, drive_id, str(mountpoint))
    scan_inventory(
        conn,
        inventory_id,
        mountpoint,
        skip_hidden_root_dirs=config.skip_hidden_root_dirs,
    )

    if not config.auto_enabled:
        return inventory_id

    destination_key = config.auto_destination
    dest_root = config.destinations[destination_key].path
    try:
        free_bytes = shutil.disk_usage(dest_root).free
        plan = build_run_plan(
            conn,
            inventory_id,
            [config.default_folder],
            dest_root,
            free_bytes,
        )
    except (PlanError, OSError) as exc:
        _record_warning(
            conn,
            drive_id=drive_id,
            action="auto_skipped",
            payload={
                "reason": str(exc),
                "inventory_id": inventory_id,
                "folder": config.default_folder,
                "destination": destination_key,
            },
        )
        return inventory_id

    run_id = create_run(conn, drive_id, inventory_id, destination_key, "auto", plan)
    if enqueue_run is not None:
        enqueue_run(run_id)
    return inventory_id


def _record_warning(
    conn: sqlite3.Connection,
    *,
    drive_id: int,
    action: str,
    payload: dict[str, object],
) -> None:
    conn.execute(
        "INSERT INTO events (level, action, drive_id, payload_json, processed) "
        "VALUES ('warning', ?, ?, ?, 1)",
        (action, drive_id, json.dumps(payload, sort_keys=True)),
    )
    conn.commit()
