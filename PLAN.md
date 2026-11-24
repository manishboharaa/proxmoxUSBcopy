# proxmoxUSBcopy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a one-command Proxmox LXC appliance that detects USB drives, lets the user review and select movies/series, copies them safely into local library folders, and keeps a view-only web history.

**Architecture:** Host-side udev + systemd mounts each USB filesystem read-only and writes an event file into a shared spool. A FastAPI app inside an unprivileged Debian 12 CT watches the spool with inotify, scans inventories, serves a Jinja2 dashboard, and runs a serialised copy worker against SQLite. The installer creates the CT, configures host mounts/units, installs dependencies, verifies permissions, writes a rollback manifest, and prints the dashboard URL.

**Tech Stack:** Python 3.11+, FastAPI, uvicorn, Jinja2, watchdog (inotify), passlib[bcrypt], itsdangerous, SQLite, pytest, httpx, ruff; Bash installer with shellcheck; systemd and udev on Proxmox VE 8.x.

**Spec:** `/home/jovyan/opencode/opencode/proxmoxUSBcopy/DESIGN.md`

## Global Constraints

- Python 3.11+; pinned dependencies in `app/requirements.txt`; dev tools in `app/requirements-dev.txt`.
- No filesystem polling. Drive discovery is udev → spool → inotify. A single startup scan is allowed; the reconcile timer defaults to off.
- The source drive is mounted `ro,nosuid,nodev,noexec` and bind-mounted read-only. Code must never write, rename, delete, chmod, or chown anything under the source root.
- The dashboard is read-only except the Import page (select + start) and login. No settings editor, delete, retry, scan, or shell endpoints.
- Preserve names and relative structure exactly. Selecting a folder copies its contents, not the folder itself. No drive-label wrapper.
- Skip identical files; skip conflicts; never overwrite an existing destination file in v1.
- Copy via `.usbcopy.<random>.part` in the destination directory, fsync, verify SHA-256 (default on), atomic no-clobber publish (`os.link` + unlink temp), preserve mtime. No partial file may ever carry its final name.
- Jobs run one at a time. Progress writes to SQLite at most once per second plus item transitions.
- All dashboard assets are local (no CDN, no external fonts). Embedded woff2, integer font sizes, no fractional text transforms.
- App runs as `usbcopy` in an unprivileged CT. Config at `/etc/usbcopy/config.toml` (`0640 root:usbcopy`); DB at `/var/lib/usbcopy/usbcopy.db`.
- Installer never edits `storage.cfg`, networking, or existing guests. It only adds namespaced files/units/dirs, backs up anything it would touch, and records a manifest.
- Dashboard port is user-selectable (default 8088); installer checks availability and re-prompts/offers the next free port.
- `REPO_URL` and `REPO_REF` are single variables at the top of `setup/install.sh`; placeholder until Manish publishes.
- **Commits:** Manish has not yet approved git commits. Every "Commit" step is a checkpoint: run it only after he explicitly approves git usage; otherwise record the changed files and continue. Never push.

## Review Focus

These are the five failure modes most likely to hurt a real user; each has tests in the task that owns the code.

1. **Source drive mutation.** A write, chmod, or delete reaches the USB drive (bug or compromised app). Expected: the source is mounted read-only and no code path opens it for writing; tests assert source content/mtime are unchanged after every copy path, and the smoke checklist verifies `touch` fails on the mount.
2. **Wrong destination mapping / path traversal.** Selecting `Movies/` produces `movies/Movies/`, or a crafted path escapes the destination. Expected: folder selections copy contents only; selections are validated against the inventory; `..`, absolute paths, and symlink escapes are rejected.
3. **Drive removal mid-copy.** A yanked drive leaves a `.part` or a half-written final file, or wedges the worker. Expected: temp file deleted, item marked failed/interrupted, run stopped cleanly, worker ready for the next job.
4. **Unprivileged CT UID mapping.** The app cannot read the spool or write the destination because host UID 0 appears as `nobody`. Expected: installer owns the spool and destination root by the CT's mapped app UID and verifies read/write as `usbcopy`; unreadable source files are warned about, never chmodded.
5. **Large files, disk full, odd filenames.** Free-space check misses, SQLite is hammered per chunk, or a weird filename crashes a run. Expected: preflight size check, throttled progress, per-file errors for unreadable/invalid names, run continues, temp cleaned.

---

## File Structure

```
proxmoxUSBcopy/
├─ README.md
├─ LICENSE                       # MIT
├─ DESIGN.md
├─ PLAN.md
├─ app/
│  ├─ requirements.txt
│  ├─ requirements-dev.txt
│  ├─ pytest.ini
│  ├─ config.example.toml
│  ├─ usbcopy/
│  │  ├─ __init__.py
│  │  ├─ config.py
│  │  ├─ db.py
│  │  ├─ media.py
│  │  ├─ inventory.py
│  │  ├─ planner.py
│  │  ├─ copier.py
│  │  ├─ runs.py
│  │  ├─ worker.py
│  │  ├─ events.py
│  │  ├─ pipeline.py
│  │  ├─ auth.py
│  │  ├─ api.py
│  │  ├─ app.py
│  │  ├─ web.py
│  │  └─ main.py
│  ├─ templates/
│  │  ├─ base.html
│  │  ├─ login.html
│  │  ├─ overview.html
│  │  ├─ import.html
│  │  ├─ runs.html
│  │  ├─ run_detail.html
│  │  ├─ drives.html
│  │  └─ about.html
│  ├─ static/
│  │  ├─ css/app.css
│  │  ├─ js/theme.js
│  │  ├─ js/sse.js
│  │  ├─ js/import.js
│  │  └─ fonts/*.woff2
│  └─ tests/
│     ├─ conftest.py
│     ├─ test_config.py
│     ├─ test_db.py
│     ├─ test_media.py
│     ├─ test_inventory.py
│     ├─ test_planner.py
│     ├─ test_copier.py
│     ├─ test_runs_worker.py
│     ├─ test_events.py
│     ├─ test_pipeline.py
│     ├─ test_auth.py
│     ├─ test_api.py
│     ├─ test_imports_api.py
│     ├─ test_startup.py
│     ├─ test_web.py
│     └─ test_static_assets.py
├─ setup/
│  ├─ install.sh
│  ├─ uninstall.sh
│  ├─ lib/common.sh
│  ├─ lib/preflight.sh
│  ├─ lib/prompts.sh
│  ├─ lib/ct.sh
│  ├─ lib/host.sh
│  ├─ lib/app.sh
│  ├─ lib/manifest.sh
│  ├─ lib/rollback.sh
│  ├─ host/mount-usb.sh
│  ├─ host/unmount-usb.sh
│  ├─ host/scan-usb.sh
│  ├─ host/99-usbcopy.rules
│  ├─ host/usbcopy-mount@.service
│  ├─ host/usbcopy-scan-usb.service
│  └─ tests/
│     ├─ test_host_scripts.sh
│     ├─ test_installer_dryrun.sh
│     └─ fakes/{pct,pveam,pvesm,systemctl,curl,pct-exec}
├─ docs/
│  ├─ mock/dashboard.html
│  ├─ mock/styles.css
│  └─ troubleshooting.md
└─ .github/workflows/ci.yml
```

---

## Task 1: Project skeleton and test harness

**Files:**
- Create: `app/requirements.txt`, `app/requirements-dev.txt`, `app/pytest.ini`, `app/usbcopy/__init__.py`, `app/tests/test_version.py`, `.gitignore`, `LICENSE`
- Test: `app/tests/test_version.py`

**Interfaces:**
- Produces: `usbcopy.__version__: str == "0.1.0"`

- [ ] **Step 1: Write the failing test**

```python
def test_version_is_semver():
    import usbcopy
    assert usbcopy.__version__ == "0.1.0"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && python -m pytest tests/test_version.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'usbcopy'`

- [ ] **Step 3: Create the package and tooling**

`app/usbcopy/__init__.py`:
```python
__version__ = "0.1.0"
```
`app/requirements.txt`: `fastapi`, `uvicorn[standard]`, `jinja2`, `watchdog`, `passlib[bcrypt]`, `itsdangerous`, `python-multipart` (pin exact versions after first install).
`app/requirements-dev.txt`: `-r requirements.txt`, `pytest`, `httpx`, `ruff`.
`app/pytest.ini`: `[pytest] testpaths = tests`.
`.gitignore`: `.venv/`, `__pycache__/`, `.pytest_cache/`, `*.pyc`, `.ruff_cache/`.
`LICENSE`: MIT text with `Copyright (c) 2026 Manish Bohara`.

- [ ] **Step 4: Install and run the test**

Run: `cd app && python -m venv .venv && . .venv/bin/activate && pip install -r requirements-dev.txt && python -m pytest tests/test_version.py -v`
Expected: PASS

- [ ] **Step 5: Checkpoint**

Files changed: skeleton only. Commit only if git usage is approved: `git add ... && git commit -m "chore: project skeleton and test harness"`.

---

## Task 2: Configuration loader

**Files:**
- Create: `app/usbcopy/config.py`, `app/config.example.toml`
- Test: `app/tests/test_config.py`

**Interfaces:**
- Produces:
```python
class ConfigError(ValueError): ...

@dataclass(frozen=True)
class Destination:
    key: str
    path: Path

@dataclass(frozen=True)
class Config:
    port: int
    username: str
    password_hash: str
    session_secret: str
    default_folder: str
    default_mode: Literal["review", "auto"]
    auto_enabled: bool
    auto_destination: str
    verify_sha256: bool
    chunk_size_mb: int
    retries: int
    preserve_mtime: bool
    destinations: dict[str, Destination]
    db_path: Path
    events_dir: Path
    mounts_root: Path
    reconcile_minutes: int
    skip_hidden_root_dirs: bool

def load_config(path: Path) -> Config
```

- [ ] **Step 1: Write failing tests**

```python
def test_loads_example_config(tmp_path):
    cfg = load_config(Path("config.example.toml"))
    assert cfg.port == 8088
    assert set(cfg.destinations) == {"movies", "series"}
    assert cfg.default_mode == "review"

def test_missing_series_destination_raises(tmp_path):
    p = write_config(tmp_path, series=False)
    with pytest.raises(ConfigError, match="series"):
        load_config(p)

def test_auto_enabled_requires_source_folder(tmp_path):
    p = write_config(tmp_path, auto_enabled=True, default_folder="")
    with pytest.raises(ConfigError, match="Auto mode"):
        load_config(p)

def test_port_must_be_free_range(tmp_path):
    p = write_config(tmp_path, port=70000)
    with pytest.raises(ConfigError, match="port"):
        load_config(p)
```

- [ ] **Step 2: Run to verify failure**

Run: `cd app && python -m pytest tests/test_config.py -v`
Expected: FAIL (module/function missing)

- [ ] **Step 3: Implement `load_config`**

Use `tomllib`; validate: port 1–65535; `movies` and `series` destinations required with non-empty absolute paths; `auto_enabled` requires `default_folder`; `default_mode` in `{review, auto}`; `auto_destination` exists; `chunk_size_mb` > 0; `retries` >= 0; resolve `db_path`, `events_dir`, `mounts_root` to `Path`. Raise `ConfigError` with the field name in the message. `app/config.example.toml` mirrors DESIGN §17, with `password_hash` and `session_secret` placeholders.

- [ ] **Step 4: Run tests to verify pass**

Run: `cd app && python -m pytest tests/test_config.py -v`
Expected: PASS

- [ ] **Step 5: Checkpoint** (`config` module + example + tests)

---

## Task 3: SQLite schema and helpers

**Files:**
- Create: `app/usbcopy/db.py`
- Test: `app/tests/test_db.py`

**Interfaces:**
- Produces:
```python
SCHEMA_VERSION: int = 1
def open_db(path: Path) -> sqlite3.Connection   # row_factory=sqlite3.Row, WAL, foreign_keys=ON
def init_db(conn: sqlite3.Connection) -> None   # idempotent; stores schema_version
def table_names(conn: sqlite3.Connection) -> set[str]
```
Tables exactly per DESIGN §12, including `drives.mountpoint`, `run_items.temp_path`, and `events.level`. Indexes: `run_items(run_id)`, `runs(status)`, `inventory_entries(inventory_id, parent_path)`, `drives(present)`.

- [ ] **Step 1: Write failing tests**

```python
def test_init_creates_all_tables(tmp_path):
    conn = open_db(tmp_path / "t.db")
    init_db(conn)
    assert {"destinations","drives","events","inventories","inventory_entries",
            "runs","run_items","audit","settings"} <= table_names(conn)
    assert conn.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
    assert conn.execute("PRAGMA foreign_keys").fetchone()[0] == 1

def test_init_is_idempotent(tmp_path):
    conn = open_db(tmp_path / "t.db")
    init_db(conn); init_db(conn)
    assert conn.execute("SELECT value FROM settings WHERE key='schema_version'").fetchone()[0] == "1"
```

- [ ] **Step 2: Run to verify failure** — `cd app && python -m pytest tests/test_db.py -v` → FAIL.

- [ ] **Step 3: Implement schema**

Inline `SCHEMA_SQL` with `CREATE TABLE IF NOT EXISTS`, foreign keys, `CHECK` constraints for statuses (`queued|running|completed|completed_with_errors|interrupted|failed`), timestamps as ISO-8601 TEXT, and a `settings(key TEXT PRIMARY KEY, value TEXT)` row for schema version.

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Checkpoint.**

---

## Task 4: Media classification hints

**Files:**
- Create: `app/usbcopy/media.py`
- Test: `app/tests/test_media.py`

**Interfaces:**
- Produces:
```python
VIDEO_EXTENSIONS: frozenset[str]
TV_PATTERN: re.Pattern[str]
def classify(rel_path: str) -> Literal["movie", "series", "other"]
```

- [ ] **Step 1: Write failing tests**

```python
@pytest.mark.parametrize("path,expected", [
    ("Movies/Heat (1995)/Heat.mkv", "movie"),
    ("Shows/The Wire/Season 2/S02E03.mkv", "series"),
    ("Shows/The Wire/S02E03.MKV", "series"),
    ("Shows/1x02 - title.mp4", "series"),
    ("notes.txt", "other"),
    ("poster.jpg", "other"),
])
def test_classify(path, expected):
    assert classify(path) == expected
```

- [ ] **Step 2: Run to verify failure** → FAIL.

- [ ] **Step 3: Implement**

Extensions: `mkv, mp4, m4v, avi, mov, wmv, webm, ts, m2ts, mpg, mpeg, flv, 3gp`. TV pattern matches `[Ss]\d{1,2}[Ee]\d{1,3}`, `\d{1,2}x\d{1,3}`, or a `Season \d+` path segment. Non-video → `other`; video with TV pattern → `series`; other video → `movie`. Suggestions only.

- [ ] **Step 4: Pass** — PASS. **Step 5: Checkpoint.**

---

## Task 5: Inventory scanner

**Files:**
- Create: `app/usbcopy/inventory.py`
- Test: `app/tests/test_inventory.py`

**Interfaces:**
- Produces:
```python
SYSTEM_DIRS: frozenset[str]
@dataclass(frozen=True)
class InventoryStats:
    files: int; dirs: int; bytes_total: int; errors: int

def create_inventory(conn, drive_id: int, root: str) -> int
def scan_inventory(conn, inventory_id: int, root: Path, *, skip_hidden_root_dirs: bool = True,
                   on_progress: Callable[[int, int], None] | None = None) -> InventoryStats
def get_entry(conn, inventory_id: int, rel_path: str) -> sqlite3.Row | None
def iter_children(conn, inventory_id: int, parent_path: str) -> list[sqlite3.Row]
```

- [ ] **Step 1: Write failing tests**

```python
def test_scan_records_tree_and_sizes(conn, sample_tree):
    inv = create_inventory(conn, drive_id=1, root=str(sample_tree))
    stats = scan_inventory(conn, inv, sample_tree)
    assert stats.files == 3 and stats.bytes_total == 6
    movies = get_entry(conn, inv, "Movies/Heat (1995)/Heat.mkv")
    assert movies["kind"] == "movie" and movies["size"] == 2
    assert [r["rel_path"] for r in iter_children(conn, inv, "Movies")] == ["Movies/Heat (1995)"]

def test_system_and_hidden_root_dirs_skipped(conn, sample_tree):
    (sample_tree / "System Volume Information").mkdir()
    (sample_tree / ".Trashes").mkdir()
    stats = scan_inventory(conn, create_inventory(conn, 1, str(sample_tree)), sample_tree)
    assert stats.files == 3
    assert get_entry(conn, 1, "System Volume Information") is None

def test_unreadable_dir_recorded_and_scan_continues(conn, sample_tree):
    blocked = sample_tree / "blocked"; blocked.mkdir(); (blocked / "x.mkv").write_text("x")
    blocked.chmod(0o000)
    stats = scan_inventory(conn, create_inventory(conn, 1, str(sample_tree)), sample_tree)
    assert stats.errors >= 1 and stats.files == 3
    blocked.chmod(0o755)

def test_symlinks_are_not_followed(conn, sample_tree):
    (sample_tree / "link").symlink_to(sample_tree / "Movies")
    stats = scan_inventory(conn, create_inventory(conn, 1, str(sample_tree)), sample_tree)
    assert get_entry(conn, 1, "link") is None

def test_unicode_filename_recorded(conn, sample_tree):
    (sample_tree / "Amélie (2001) 🎬.mkv").write_bytes(b"xx")
    stats = scan_inventory(conn, create_inventory(conn, 1, str(sample_tree)), sample_tree)
    assert stats.files == 4
    assert get_entry(conn, 1, "Amélie (2001) 🎬.mkv") is not None

def test_undecodable_filename_does_not_crash(conn, sample_tree):
    raw = os.fsencode(str(sample_tree)) + b"/bad_\xff.mkv"
    with open(raw, "wb") as fh: fh.write(b"x")
    stats = scan_inventory(conn, create_inventory(conn, 1, str(sample_tree)), sample_tree)
    assert stats.errors >= 1
```

- [ ] **Step 2: Run to verify failure** → FAIL.

- [ ] **Step 3: Implement**

`os.walk(..., followlinks=False)`; skip `SYSTEM_DIRS` at any depth and hidden root dirs when enabled; insert dirs and files with `parent_path`; skip symlinks and record an error count; `stat` each entry, catch `OSError` per entry and continue; update inventory status `scanning` → `complete` (or `failed` with error); call `on_progress(files_seen, bytes_seen)` every 500 entries.

- [ ] **Step 4: Pass** — PASS. **Step 5: Checkpoint.**

---

## Task 6: Destination mapping and run planner

**Files:**
- Create: `app/usbcopy/planner.py`
- Test: `app/tests/test_planner.py`

**Interfaces:**
- Produces:
```python
@dataclass(frozen=True)
class PlanItem: source_rel: str; dest_rel: str; size: int
@dataclass(frozen=True)
class SkippedItem: source_rel: str; dest_rel: str; reason: Literal["exists", "conflict"]
@dataclass(frozen=True)
class RunPlan: items: list[PlanItem]; skipped: list[SkippedItem]; warnings: list[str]; total_bytes: int
class PlanError(ValueError): ...

def normalise_selection(rel_path: str) -> str
def build_run_plan(conn, inventory_id: int, selections: list[str], dest_root: Path, free_bytes: int) -> RunPlan
```

- [ ] **Step 1: Write failing tests**

```python
def test_file_selection_maps_to_destination_root(conn, inventory):
    plan = build_run_plan(conn, inventory, ["Heat.mkv"], tmp_path, free_bytes=10**9)
    assert plan.items[0].dest_rel == "Heat.mkv"

def test_folder_selection_copies_contents_not_wrapper(conn, inventory):
    plan = build_run_plan(conn, inventory, ["Movies"], tmp_path, free_bytes=10**9)
    assert {i.dest_rel for i in plan.items} == {"Heat (1995)/Heat.mkv"}

def test_overlapping_selections_are_deduplicated(conn, inventory):
    plan = build_run_plan(conn, inventory, ["Movies", "Movies/Heat (1995)/Heat.mkv"], tmp_path, 10**9)
    assert len(plan.items) == 1

def test_traversal_and_missing_paths_rejected(conn, inventory):
    for bad in ["../etc/passwd", "/etc/passwd", "Movies/../../x", "nope.mkv"]:
        with pytest.raises(PlanError):
            build_run_plan(conn, inventory, [bad], tmp_path, 10**9)

def test_existing_identical_skipped_and_conflict_flagged(conn, inventory, tmp_path):
    (tmp_path / "Heat (1995)").mkdir(); target = tmp_path / "Heat (1995)/Heat.mkv"
    target.write_bytes(b"hi"); os.utime(target, (1_700_000_000, 1_700_000_000))
    plan = build_run_plan(conn, inventory, ["Movies"], tmp_path, 10**9)
    assert plan.skipped[0].reason in {"exists", "conflict"}

def test_free_space_shortfall_raises(conn, inventory):
    with pytest.raises(PlanError, match="space"):
        build_run_plan(conn, inventory, ["Movies"], tmp_path, free_bytes=1)
```

- [ ] **Step 2: Run to verify failure** → FAIL.

- [ ] **Step 3: Implement**

`normalise_selection`: strip whitespace and leading `./`/`/`; reject empty, `..` segments, backslashes, NUL. Verify the exact entry exists in `inventory_entries` for that inventory; folder selections expand to descendant files; dedupe by `source_rel`; dest rel = path relative to the selected root (for folders) or basename (for files); reject if the computed dest escapes `dest_root` (`Path.resolve()` check). Duplicate check: `dest.exists()` → same size and mtime within 2s → `exists`, else `conflict`; skipped items never enter `items`. Free space: `required = int(total * 1.02) + 256 * 1024 * 1024`; if `free_bytes < required` raise `PlanError("not enough space: need ...")`.

- [ ] **Step 4: Pass** — PASS. **Step 5: Checkpoint.**

---

## Task 7: Copy engine

**Files:**
- Create: `app/usbcopy/copier.py`
- Test: `app/tests/test_copier.py`

**Interfaces:**
- Produces:
```python
class CopyError(Exception): ...
@dataclass(frozen=True)
class CopyResult: sha256: str; bytes_copied: int
def copy_file(source: Path, destination: Path, *, chunk_size: int = 8 * 1024 * 1024,
              verify_sha256: bool = True, preserve_mtime: bool = True) -> CopyResult
```

- [ ] **Step 1: Write failing tests**

```python
def test_copies_content_and_mtime(src, dst):
    src.write_bytes(b"hello world"); os.utime(src, (1_700_000_000, 1_700_000_000))
    result = copy_file(src, dst, chunk_size=4)
    assert dst.read_bytes() == b"hello world"
    assert int(dst.stat().st_mtime) == 1_700_000_000
    assert result.bytes_copied == 11

def test_refuses_existing_destination(src, dst):
    dst.write_text("keep")
    with pytest.raises(CopyError, match="exists"):
        copy_file(src, dst)
    assert dst.read_text() == "keep"

def test_failure_never_leaves_partial_or_final_file(src, dst, monkeypatch):
    monkeypatch.setattr(copier, "_verify", lambda *a, **k: (_ for _ in ()).throw(CopyError("hash")))
    with pytest.raises(CopyError):
        copy_file(src, dst)
    assert not dst.exists()
    assert list(dst.parent.glob(".usbcopy.*.part")) == []

def test_source_content_unchanged(src, dst):
    before = src.read_bytes()
    copy_file(src, dst)
    assert src.read_bytes() == before

def test_large_file_streams_in_chunks(src, dst):
    src.write_bytes(b"x" * (3 * 1024 * 1024 + 17))
    result = copy_file(src, dst, chunk_size=1024 * 1024)
    assert dst.stat().st_size == src.stat().st_size == result.bytes_copied
```

- [ ] **Step 2: Run to verify failure** → FAIL.

- [ ] **Step 3: Implement**

Open source `rb` only. Create temp in `destination.parent` named `.usbcopy.<uuid4().hex>.part` with `O_CREAT|O_EXCL`. Stream chunks; compute source SHA-256. `flush`+`os.fsync`; if verifying, hash the temp file; on mismatch raise `CopyError("hash mismatch")`. Set mtime/mode on the temp, then publish with `os.link(temp, destination)` (fails if the target exists) and unlink the temp; `fsync` the directory (log a warning if it fails). Any exception: unlink temp and re-raise. Refuse existing destination.

- [ ] **Step 4: Pass** — PASS. **Step 5: Checkpoint.**

---

## Task 8: Runs and copy worker

**Files:**
- Create: `app/usbcopy/runs.py`, `app/usbcopy/worker.py`
- Test: `app/tests/test_runs_worker.py`

**Interfaces:**
- Produces:
```python
# runs.py
def create_run(conn, drive_id: int | None, inventory_id: int | None, destination_key: str,
               mode: str, plan: RunPlan) -> int
def get_run(conn, run_id: int) -> sqlite3.Row | None
def recover_orphaned_runs(conn) -> int
def interrupt_active_run(conn, drive_id: int, reason: str) -> int

# worker.py
class RunWorker:
    def __init__(self, db_path: Path, config: Config, dest_roots: dict[str, Path],
                 cancel_event: threading.Event | None = None)
    def start(self) -> None
    def stop(self) -> None
    def enqueue(self, run_id: int) -> None
    def run_once(self) -> bool   # processes one queued run; False if queue empty
def execute_run(conn, run_id: int, config: Config, dest_roots: dict[str, Path],
                cancel_event: threading.Event) -> None
```

- [ ] **Step 1: Write failing tests**

```python
def test_execute_run_copies_items_and_records_status(conn, config, plan, dirs):
    run_id = create_run(conn, None, None, "movies", "review", plan)
    execute_run(conn, run_id, config, {"movies": dirs["movies"]}, threading.Event())
    run = get_run(conn, run_id)
    assert run["status"] == "completed"
    assert (dirs["movies"] / "Heat (1995)/Heat.mkv").read_bytes() == b"hi"

def test_retries_twice_then_succeeds(conn, config, plan, dirs, monkeypatch):
    calls = {"n": 0}
    real = copier.copy_file
    def flaky(*a, **k):
        calls["n"] += 1
        if calls["n"] < 3: raise CopyError("transient")
        return real(*a, **k)
    monkeypatch.setattr("usbcopy.worker.copy_file", flaky)
    run_id = create_run(conn, None, None, "movies", "review", plan)
    execute_run(conn, run_id, config, {"movies": dirs["movies"]}, threading.Event())
    assert calls["n"] == 3 and get_run(conn, run_id)["status"] == "completed"

def test_cancellation_cleans_temp_and_interrupts(conn, config, plan, dirs):
    cancel = threading.Event(); cancel.set()
    run_id = create_run(conn, None, None, "movies", "review", plan)
    execute_run(conn, run_id, config, {"movies": dirs["movies"]}, cancel)
    assert get_run(conn, run_id)["status"] == "interrupted"
    assert list(dirs["movies"].rglob(".usbcopy.*.part")) == []

def test_orphaned_runs_recovered(conn):
    run_id = create_run(conn, None, None, "movies", "review", plan)
    conn.execute("UPDATE runs SET status='running' WHERE id=?", (run_id,)); conn.commit()
    assert recover_orphaned_runs(conn) == 1
    assert get_run(conn, run_id)["status"] == "interrupted"

def test_worker_serialises_jobs(conn, db_path, config, plan, dirs):
    first = create_run(...); second = create_run(...)
    worker = RunWorker(db_path, config, {"movies": dirs["movies"]})
    worker.enqueue(first); worker.enqueue(second)
    assert worker.run_once() is True
    assert get_run(conn, first)["status"] == "completed"
    assert get_run(conn, second)["status"] == "queued"
```

- [ ] **Step 2: Run to verify failure** → FAIL.

- [ ] **Step 3: Implement**

`create_run`: insert run + items; total bytes; status `queued`. `execute_run`: set `running`; for each item in order: if cancel set → mark remaining `cancelled`, temp cleanup; copy with retries (`config.retries`, sleeps 2/5/10s but capped by a `sleep` function that tests can monkeypatch); update `run_items` `bytes_done`, `sha256`, `temp_path`, status; progress throttle (≥1s or item transition); final `completed` or `completed_with_errors`; exceptions mark run `failed`. `RunWorker`: single background thread with `queue.Queue`, opens a fresh connection per run via `open_db`, `run_once` non-blocking. `interrupt_active_run` marks queued/running runs for a drive interrupted.

- [ ] **Step 4: Pass** — PASS. **Step 5: Checkpoint.**

---

## Task 9: Event parsing, startup scan, and inotify watcher

**Files:**
- Create: `app/usbcopy/events.py`
- Test: `app/tests/test_events.py`

**Interfaces:**
- Produces:
```python
EVENT_VERSION = 1
@dataclass(frozen=True)
class DriveEvent:
    action: Literal["add", "remove"]; uuid: str; label: str | None; serial: str | None
    device: str; mountpoint: str; fs_type: str; ts: str

class EventError(ValueError): ...
def parse_event(path: Path) -> DriveEvent
def apply_event(conn, event: DriveEvent,
                on_drive_added: Callable[[int, Path], None] | None = None) -> int
def scan_mounted(conn, mounts_root: Path,
                 on_drive_added: Callable[[int, Path], None] | None = None) -> list[str]
def process_pending(conn, spool_dir: Path,
                    on_drive_added: Callable[[int, Path], None] | None = None) -> int
class EventSpoolWatcher:  # thin watchdog wrapper
    def __init__(self, spool_dir: Path, on_event: Callable[[Path], None])
    def start(self) -> None
    def stop(self) -> None
```

- [ ] **Step 1: Write failing tests**

```python
def test_add_event_upserts_present_drive_and_calls_back(conn, tmp_path):
    event_file = write_event(tmp_path, action="add", uuid="ABCD-1234")
    calls = []
    drive_id = apply_event(conn, parse_event(event_file), lambda i, p: calls.append((i, p)))
    assert conn.execute("SELECT present FROM drives WHERE id=?", (drive_id,)).fetchone()[0] == 1
    assert calls == [(drive_id, tmp_path / "ABCD-1234")]

def test_remove_event_marks_absent_and_interrupts(conn, tmp_path):
    ... create running run for drive ...
    apply_event(conn, parse_event(write_event(tmp_path, action="remove", uuid="ABCD-1234")))
    assert conn.execute("SELECT present FROM drives").fetchone()[0] == 0
    assert get_run(conn, run_id)["status"] == "interrupted"

def test_malformed_event_is_quarantined(conn, tmp_path):
    bad = tmp_path / "bad.json"; bad.write_text("{nope")
    with pytest.raises(EventError):
        parse_event(bad)
    assert process_pending(conn, tmp_path) == 0
    assert (tmp_path / "bad" / "bad.json").exists()

def test_scan_mounted_discovers_existing_dirs(conn, tmp_path):
    (tmp_path / "ABCD-1234").mkdir()
    assert scan_mounted(conn, tmp_path) == ["ABCD-1234"]
```

- [ ] **Step 2: Run to verify failure** → FAIL.

- [ ] **Step 3: Implement**

Validate JSON keys/types and `version == 1`; UUID used only for directory names (validate `[A-Za-z0-9._-]+`, no slashes). `apply_event` upserts on `uuid`, sets `present`, `mountpoint`, `last_seen`; `on_drive_added` only for add. Remove: `present=0`, call `interrupt_active_run`. `process_pending` parses each `*.json` atomically, deletes after success, moves malformed files to `spool/bad/`. Watcher: `watchdog.observers.Observer` on the spool dir, `on_created`/`on_moved` callback; no polling. `scan_mounted` lists direct child dirs.

- [ ] **Step 4: Pass** — PASS. **Step 5: Checkpoint.**

---

## Task 9b: Drive-added pipeline and Auto mode

**Files:**
- Create: `app/usbcopy/pipeline.py`
- Test: `app/tests/test_pipeline.py`

**Interfaces:**
- Produces:
```python
def handle_drive_added(conn, drive_id: int, mountpoint: Path, config: Config,
                       enqueue_run: Callable[[int], None] | None = None) -> int
```
Returns the new inventory id. The inventory root is always the mountpoint (whole drive) so Review can browse everything; Auto mode selects only `config.default_folder`.

- [ ] **Step 1: Write failing tests**

```python
def test_drive_added_creates_scanned_inventory(conn, config, sample_tree, drive_row):
    inv = handle_drive_added(conn, drive_row, sample_tree, config)
    assert conn.execute("SELECT status FROM inventories WHERE id=?", (inv,)).fetchone()[0] == "complete"
    assert conn.execute("SELECT root FROM inventories WHERE id=?", (inv,)).fetchone()[0] == str(sample_tree)

def test_auto_disabled_creates_no_run(conn, config, sample_tree, drive_row):
    config = replace(config, auto_enabled=False)
    handle_drive_added(conn, drive_row, sample_tree, config)
    assert conn.execute("SELECT count(*) FROM runs").fetchone()[0] == 0

def test_auto_enabled_queues_run_for_default_folder(conn, config, sample_tree, drive_row):
    config = replace(config, auto_enabled=True, auto_destination="movies", default_folder="Movies")
    queued = []
    handle_drive_added(conn, drive_row, sample_tree, config, enqueue_run=queued.append)
    run = get_run(conn, queued[0])
    assert run["mode"] == "auto" and run["destination_key"] == "movies"

def test_missing_auto_folder_warns_and_skips(conn, config, sample_tree, drive_row):
    config = replace(config, auto_enabled=True, default_folder="Nope")
    queued = []
    handle_drive_added(conn, drive_row, sample_tree, config, enqueue_run=queued.append)
    assert queued == [] and conn.execute("SELECT count(*) FROM events WHERE level='warning'").fetchone()
```

- [ ] **Step 2: Run to verify failure** → FAIL.

- [ ] **Step 3: Implement**

Create the inventory with `root=str(mountpoint)` and scan the whole mountpoint. In Auto mode, build a plan with `selections=[config.default_folder]`, free bytes from `shutil.disk_usage`, create a run with `mode="auto"`, and call `enqueue_run` if provided. Missing folder or plan error writes a warning event and skips the run. Keep this function synchronous so the caller can run it in a thread.

- [ ] **Step 4: Pass** — PASS. **Step 5: Checkpoint.**

---

## Task 10: Authentication and CSRF

**Files:**
- Create: `app/usbcopy/auth.py`
- Test: `app/tests/test_auth.py`

**Interfaces:**
- Produces:
```python
def hash_password(password: str) -> str
def verify_password(password: str, password_hash: str) -> bool
@dataclass(frozen=True)
class Session:
    username: str
    csrf: str
class SessionManager:
    def __init__(self, secret: str, max_age_seconds: int = 12 * 3600)
    def create(self, username: str) -> str
    def read(self, token: str) -> Session | None
```
Uses `passlib.context.CryptContext(schemes=["bcrypt"])` and `itsdangerous.URLSafeTimedSerializer`.

- [ ] **Step 1: Write failing tests**

```python
def test_password_roundtrip():
    h = hash_password("correct horse")
    assert verify_password("correct horse", h) and not verify_password("wrong", h)

def test_session_roundtrip_and_csrf():
    sm = SessionManager("secret")
    token = sm.create("admin")
    session = sm.read(token)
    assert session.username == "admin" and len(session.csrf) >= 32

def test_tampered_session_rejected():
    sm = SessionManager("secret")
    assert sm.read(sm.create("admin") + "x") is None

def test_expired_session_rejected(monkeypatch):
    sm = SessionManager("secret", max_age_seconds=1)
    token = sm.create("admin")
    monkeypatch.setattr(time, "time", lambda: time.time() + 10)
    assert sm.read(token) is None
```

- [ ] **Step 2: Run to verify failure** → FAIL.

- [ ] **Step 3: Implement** — as above; `read` catches `BadSignature`/`SignatureExpired` and returns `None`.

- [ ] **Step 4: Pass** — PASS. **Step 5: Checkpoint.**

---

## Task 11: FastAPI app, read-only API, and SSE

**Files:**
- Create: `app/usbcopy/app.py`, `app/usbcopy/api.py`, `app/usbcopy/web.py`
- Test: `app/tests/test_api.py`

**Interfaces:**
- Produces:
```python
# app.py
def create_app(config: Config, *, start_background: bool = True) -> FastAPI

# api.py
def build_api_router(config: Config, session_manager: SessionManager) -> APIRouter
def run_event_stream(conn, run_id: int) -> Iterator[str]
```
Routes: `GET /api/status`, `/api/drives`, `/api/drives/{id}`, `/api/inventories/{id}` (JSON tree, paginated by `parent`), `/api/runs`, `/api/runs/{id}`, `/api/runs/{id}/items`, `GET /api/events/stream?run_id=`, `POST /api/login`, `POST /api/logout`. All except login require a session cookie.

- [ ] **Step 1: Write failing tests**

```python
def test_requires_login(client):
    assert client.get("/api/status").status_code == 401

def test_status_after_login(client, login):
    r = client.get("/api/status")
    assert r.status_code == 200 and r.json()["version"] == "0.1.0"

def test_no_mutating_endpoints(client, login):
    for method in ("delete", "put", "patch"):
        assert getattr(client, method)("/api/runs/1").status_code in (404, 405)

def test_sse_emits_run_event(conn, run_id):
    frames = list(itertools.islice(run_event_stream(conn, run_id), 1))
    assert frames[0].startswith("data: ") and frames[0].endswith("\n\n")
```

- [ ] **Step 2: Run to verify failure** → FAIL.

- [ ] **Step 3: Implement**

App factory loads templates/static, mounts router, sets `SessionManager`, adds `/healthz`. Auth dependency reads `usbcopy_session` cookie. SSE generator polls the DB at 1s intervals **inside the server only** (not filesystem polling) and yields JSON snapshots; terminate after run ends. Login verifies password and sets `HttpOnly`, `SameSite=Lax` cookie. Logout clears it. CSRF is embedded in the session and templates (used in Task 12).

- [ ] **Step 4: Pass** — PASS. **Step 5: Checkpoint.**

---

## Task 12: Import endpoint (the only write surface)

**Files:**
- Modify: `app/usbcopy/api.py`
- Test: `app/tests/test_imports_api.py`

**Interfaces:**
- Consumes: `build_run_plan`, `create_run`, `RunWorker.enqueue`.
- Produces: `POST /api/imports` with body `{"inventory_id": int, "destination": "movies"|"series", "paths": [str], "csrf": str}` → `201 {"run_id": int}`.

- [ ] **Step 1: Write failing tests**

```python
def test_import_creates_run_and_audit(client, login, inventory, worker_mock):
    r = client.post("/api/imports", json={"inventory_id": inventory, "destination": "movies",
                                          "paths": ["Movies"], "csrf": login.csrf})
    assert r.status_code == 201
    run_id = r.json()["run_id"]
    assert db.execute("SELECT action FROM audit WHERE action='import_start'").fetchone()
    assert worker_mock.enqueued == [run_id]

def test_import_requires_csrf(client, login):
    r = client.post("/api/imports", json={"inventory_id": 1, "destination": "movies",
                                          "paths": ["Movies"], "csrf": "wrong"})
    assert r.status_code == 403

def test_import_rejects_unknown_path(client, login, inventory):
    r = client.post("/api/imports", json={"inventory_id": inventory, "destination": "movies",
                                          "paths": ["../../etc/passwd"], "csrf": login.csrf})
    assert r.status_code == 422

def test_import_rejects_unknown_destination(client, login, inventory):
    ... destination "music" → 422 ...
```

- [ ] **Step 2: Run to verify failure** → FAIL.

- [ ] **Step 3: Implement** — validate session + CSRF; `inventory_id` exists and status `complete`; destination key in config; call `build_run_plan` (free bytes from `shutil.disk_usage(dest_root)`); map `PlanError` → 422 with message; create run with `mode="review"`; audit row with actor, destination, count, bytes; enqueue; return 201.

- [ ] **Step 4: Pass** — PASS. **Step 5: Checkpoint.**

---

## Task 13: Startup recovery and background wiring

**Files:**
- Modify: `app/usbcopy/app.py`, `app/usbcopy/main.py`
- Test: `app/tests/test_startup.py`

**Interfaces:**
- Consumes: `handle_drive_added` from Task 9b.
- Produces:
```python
def startup_recovery(conn, config: Config) -> dict[str, int]  # {"orphans": n, "temps": n, "events": n, "drives": n}
def cleanup_recorded_temps(conn) -> int
def main() -> None
```

- [ ] **Step 1: Write failing tests**

```python
def test_startup_marks_running_runs_interrupted(conn, config):
    ... run status running ...
    stats = startup_recovery(conn, config)
    assert stats["orphans"] == 1

def test_startup_removes_recorded_temp_only(conn, config, tmp_path):
    keep = tmp_path / "unknown.part"; keep.write_text("x")
    recorded = tmp_path / ".usbcopy.abc.part"; recorded.write_text("x")
    ... insert run_item with temp_path=recorded ...
    cleanup_recorded_temps(conn)
    assert recorded.exists() is False and keep.exists() is True

def test_startup_processes_pending_events(conn, config):
    write_event(config.events_dir, action="add", uuid="ABCD-1234")
    assert startup_recovery(conn, config)["events"] == 1

def test_drive_callback_creates_inventory(conn, config, sample_tree):
    (config.mounts_root / "ABCD-1234").symlink_to(sample_tree)
    startup_recovery(conn, config)
    assert conn.execute("SELECT count(*) FROM inventories").fetchone()[0] == 1
```

- [ ] **Step 2: Run to verify failure** → FAIL.

- [ ] **Step 3: Implement** — `cleanup_recorded_temps` deletes only paths stored in `run_items.temp_path` (missing paths ignored); `startup_recovery` calls it, `recover_orphaned_runs`, `process_pending`, `scan_mounted`; startup scans run synchronously so recovery is deterministic. App lifespan uses these when `start_background=True`, then starts `RunWorker` and `EventSpoolWatcher`; shutdown stops both. The live watcher's drive-added callback runs `handle_drive_added` in a short-lived background thread (never inside the watchdog callback) and passes `worker.enqueue`, so inventory scans and auto-mode runs do not block event handling. `main.py` loads config from `/etc/usbcopy/config.toml` and runs uvicorn on `config.port`.

- [ ] **Step 4: Pass** — PASS. **Step 5: Checkpoint.**

---

## Task 14: Dashboard mock and design system (review gate)

**Files:**
- Create: `docs/mock/dashboard.html`, `docs/mock/styles.css`, `app/static/fonts/` (Inter + JetBrains Mono woff2)
- Test: `app/tests/test_static_assets.py`

**Interfaces:**
- Produces: design tokens and layout that Tasks 15–17 reuse; font files.

- [ ] **Step 1: Write failing tests**

```python
def test_mock_has_no_external_assets():
    html = Path("docs/mock/dashboard.html").read_text()
    for needle in ('src="http', "src='http", 'href="http', "href='http"):
        assert needle not in html

def test_required_fonts_exist():
    names = {p.name for p in Path("app/static/fonts").glob("*.woff2")}
    assert any("inter" in n.lower() for n in names)
    assert any("jetbrains" in n.lower() for n in names)
```

- [ ] **Step 2: Run to verify failure** → FAIL.

- [ ] **Step 3: Build the mock**

One scrollable page with sample data showing: top bar, four KPI cards, connected drive card, active transfer with progress, queue, recent runs table, import tree preview, run-detail drawer. CSS tokens (colour, spacing, type scale), dark/light toggle, responsive layout, status chips, empty states. Fetch Inter and JetBrains Mono woff2 from their official GitHub releases and store them under `app/static/fonts/` (subset if practical); reference them locally from CSS. Integer font sizes only; no fractional transforms; inline SVG icons with explicit sizes.

- [ ] **Step 4: Pass tests** — PASS.

- [ ] **Step 5: Manish reviews the mock**

Open `docs/mock/dashboard.html` in a browser. Wait for explicit approval or requested changes before wiring templates. Adjust the mock and re-check.

- [ ] **Step 6: Checkpoint.**

---

## Task 15: Jinja shell, login, and overview

**Files:**
- Create: `app/templates/base.html`, `login.html`, `overview.html`; `app/static/css/app.css`; `app/static/js/theme.js`
- Modify: `app/usbcopy/web.py`
- Test: `app/tests/test_web.py`

**Interfaces:**
- Consumes: `create_app`, `SessionManager`, DB.
- Produces routes: `GET /` (overview, login required), `GET /login`, `POST /login`, `POST /logout`.

- [ ] **Step 1: Write failing tests**

```python
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
```

- [ ] **Step 2: Run to verify failure** → FAIL.

- [ ] **Step 3: Implement** — base layout with nav (Overview, Import, Runs, Drives, About), theme toggle (localStorage, client-side only), status chips, CSS from the approved mock, login form with CSRF from session, redirect handling. Overview queries drives/runs and renders cards; no actions.

- [ ] **Step 4: Pass** — PASS. **Step 5: Checkpoint.**

---

## Task 16: Import review page

**Files:**
- Create: `app/templates/import.html`, `app/static/js/import.js`; modify `app/usbcopy/web.py`, `app/static/css/app.css`
- Test: `app/tests/test_web.py` (add cases)

**Interfaces:**
- Consumes: `GET /api/drives`, `/api/inventories/{id}`, `POST /api/imports`.
- Produces route `GET /import`.

- [ ] **Step 1: Write failing tests**

```python
def test_import_page_shows_drive_and_destinations(client, login, present_drive):
    html = client.get("/import").text
    assert "Movies" in html and "Series" in html and "ABCD-1234" in html

def test_import_page_has_csrf(client, login):
    html = client.get("/import").text
    assert 'name="csrf"' in html or "data-csrf" in html

def test_import_page_has_no_settings_controls(client, login):
    html = client.get("/import").text
    assert "Save settings" not in html and "Delete" not in html
```

- [ ] **Step 2: Run to verify failure** → FAIL.

- [ ] **Step 3: Implement** — server renders drives and destination names; JS fetches the inventory tree lazily (`?parent=`), renders checkboxes, maintains selection and total size, fetches duplicate state from the tree payload, shows destination dropdown (Movies/Series), free-space bar, confirm button disabled until selection; POST with CSRF; on success show link to run detail; SSE updates run progress. No other mutating controls.

- [ ] **Step 4: Pass** — PASS. **Step 5: Checkpoint.**

---

## Task 17: Runs, run detail, drives, and about pages

**Files:**
- Create: `app/templates/runs.html`, `run_detail.html`, `drives.html`, `about.html`; modify `app/usbcopy/web.py`
- Test: `app/tests/test_web.py` (add cases)

**Interfaces:**
- Produces routes: `GET /runs`, `/runs/{id}`, `/drives`, `/about`.

- [ ] **Step 1: Write failing tests**

```python
def test_runs_filters(client, login, sample_runs):
    assert "failed" in client.get("/runs?status=failed").text
    assert "completed" in client.get("/runs?status=completed").text

def test_run_detail_shows_items_and_errors(client, login, failed_run):
    html = client.get(f"/runs/{failed_run}").text
    assert "Heat.mkv" in html and "permission denied" in html.lower()

def test_drives_shows_not_present(client, login, absent_drive):
    assert "not present" in client.get("/drives").text.lower()

def test_about_shows_version_and_paths(client, login):
    html = client.get("/about").text
    assert "0.1.0" in html and "/data/movies" in html
```

- [ ] **Step 2: Run to verify failure** → FAIL.

- [ ] **Step 3: Implement** — read-only lists, filters via query params, per-file status table, hashes/durations/errors, drive history with presence badges, About page with version/config summary (no secrets) and log paths.

- [ ] **Step 4: Pass** — PASS. **Step 5: Checkpoint.**

---

## Task 18: Host mount/unmount scripts, units, and udev rule

**Files:**
- Create: `setup/host/mount-usb.sh`, `unmount-usb.sh`, `scan-usb.sh`, `99-usbcopy.rules`, `usbcopy-mount@.service`, `usbcopy-scan-usb.service`
- Test: `setup/tests/test_host_scripts.sh`

**Interfaces:**
- Produces:
  - `mount-usb.sh --device /dev/sda1 [--mount-root /srv/usb-ingest] [--spool /srv/usbcopy/events] [--dry-run]` → mounts ro, prints/writes event JSON.
  - `unmount-usb.sh --mountpoint <path> [--spool ...] [--dry-run]` → unmounts, writes remove event.
  - `scan-usb.sh` → starts `usbcopy-mount@<dev>.service` for USB block devices with supported FS.
  - Event JSON exactly: `{"version":1,"action":"add","uuid":"...","label":"...","serial":"...","device":"/dev/sda1","mountpoint":"...","fs_type":"exfat","ts":"..."}`.

- [ ] **Step 1: Write failing test script**

`setup/tests/test_host_scripts.sh` (plain bash, exits non-zero on failure):
```bash
#!/usr/bin/env bash
set -euo pipefail
out=$(./setup/host/mount-usb.sh --device /dev/fake1 --uuid TEST-1234 --fs-type exfat \
      --label MEDIA --serial SN1 --mount-root /tmp/usbcopy-test/mnt \
      --spool /tmp/usbcopy-test/spool --dry-run)
grep -q 'mount -o ro,nosuid,nodev,noexec' <<<"$out"
grep -q '"action":"add"' <<<"$out"
grep -q '"uuid":"TEST-1234"' <<<"$out"
python3 - <<'PY'
import json, os
raw = os.popen("./setup/host/mount-usb.sh --device /dev/fake1 --uuid TEST-1234 --fs-type exfat --label MEDIA --serial SN1 --mount-root /tmp/usbcopy-test/mnt --spool /tmp/usbcopy-test/spool --dry-run | tail -1").read()
json.loads(raw)
PY
```

- [ ] **Step 2: Run to verify failure** → `bash setup/tests/test_host_scripts.sh` fails (script missing).

- [ ] **Step 3: Implement**

`mount-usb.sh`: `set -euo pipefail`; validate args; derive UUID/label/serial/FS with `blkid -o export` when not passed; refuse unsupported FS; mkdir mountpoint; `mount -t <fs> -o ro,nosuid,nodev,noexec[,uid=0]` (for exfat/vfat/ntfs add `umask=022`); write event JSON atomically (`mktemp` + `mv`) to spool; `--dry-run` prints the mount command and JSON only. `unmount-usb.sh`: `umount`, write remove event, remove mountpoint dir. `scan-usb.sh`: `lsblk -J` parse via python3, start units for `ID_BUS=usb` devices with FS. udev rule uses `TAG+="systemd", ENV{SYSTEMD_WANTS}+="usbcopy-mount@%k.service"`. Units as described in DESIGN §11.1; `usbcopy-scan-usb.service` enabled at boot.

- [ ] **Step 4: Pass tests**

Run: `bash setup/tests/test_host_scripts.sh && shellcheck setup/host/*.sh && bash -n setup/host/*.sh`
Expected: exit 0.

- [ ] **Step 5: Checkpoint.**

---

## Task 19: Installer preflight, prompts, and dry-run

**Files:**
- Create: `setup/install.sh`, `setup/lib/common.sh`, `setup/lib/preflight.sh`, `setup/lib/prompts.sh`
- Test: `setup/tests/test_installer_dryrun.sh`, fakes in `setup/tests/fakes/`

**Interfaces:**
- Produces: `install.sh` flags `--repo-url`, `--ref`, `--dry-run`, `--yes`, `--uninstall`, `--help`; prompts exactly per DESIGN §11.5; port check; exit 0 in dry-run with a printed plan.

- [ ] **Step 1: Write failing test**

```bash
#!/usr/bin/env bash
set -euo pipefail
export PATH="$PWD/setup/tests/fakes:$PATH"
export USBC_ANSWERS="101 usbcopy local-lvm 8 1024 2 dhcp /tmp/movies /tmp/series '' '' no 8088 secret"
out=$(./setup/install.sh --dry-run --yes 2>&1)
grep -q 'PLAN: create CT 101' <<<"$out"
grep -q 'PLAN: mount /tmp/movies -> /data/movies' <<<"$out"
grep -q 'PLAN: dashboard http://' <<<"$out"
```

- [ ] **Step 2: Run to verify failure** → FAIL.

- [ ] **Step 3: Implement**

`common.sh`: `set -euo pipefail`, logging, `die`, `require_cmd`, `ask` (reads `/dev/tty`, honours `USBC_ANSWERS` for tests), `ask_secret`, `validate_path`, `is_port_free`. `preflight.sh`: root, `pveversion`, internet, `pveam` storages, bridge, next free CT ID, destination paths, port. `prompts.sh`: the 13 prompts with defaults; if `--yes`, use defaults + env/answers; summary. `install.sh`: parse flags, source libs, run preflight/prompts, and with `--dry-run` print each planned action (`PLAN: ...`) and exit 0. Placeholder `REPO_URL="https://github.com/OWNER/proxmoxUSBcopy"` and `REPO_REF="main"`.

- [ ] **Step 4: Pass tests** — `bash setup/tests/test_installer_dryrun.sh && shellcheck setup/install.sh setup/lib/*.sh` → exit 0.

- [ ] **Step 5: Checkpoint.**

---

## Task 20: Installer execution, permissions, and manifest

**Files:**
- Create: `setup/lib/ct.sh`, `setup/lib/host.sh`, `setup/lib/app.sh`, `setup/lib/manifest.sh`; modify `setup/install.sh`
- Test: extend `setup/tests/test_installer_dryrun.sh` with fake-call assertions

**Interfaces:**
- Produces functions: `create_ct`, `install_app`, `configure_host`, `verify_permissions`, `write_manifest`; dry-run prints every command; real mode executes.

- [ ] **Step 1: Write failing assertions**

```bash
grep -q 'pct create 101' "$FAKE_LOG"
grep -q -- '--unprivileged 1' "$FAKE_LOG"
grep -q 'mp0: /srv/usb-ingest' "$FAKE_LOG"
grep -q 'usbcopy.service' "$FAKE_LOG"
grep -q 'chown 100999:100999 /tmp/movies' "$FAKE_LOG"
grep -q 'verify_permissions' "$FAKE_LOG"
```

- [ ] **Step 2: Run to verify failure** → FAIL.

- [ ] **Step 3: Implement**

- `create_ct`: find/download Debian 12 template; `pct create` with `--unprivileged 1 --onboot 1 --cores --memory --swap --rootfs <storage>:<size> --net0 name=eth0,bridge=<bridge>,ip=dhcp` (or static); start.
- `install_app`: wait for network; apt update/install only missing (`python3`, `python3-venv`, `python3-pip`, `ca-certificates`, `curl`); create `usbcopy` user; venv; `pip install -r requirements.txt`; `pct push` app tarball; render config with generated password hash/session secret; install/enable `usbcopy.service`.
- `configure_host`: create `/srv/usb-ingest`, `/srv/usbcopy/events` (owned by mapped UID), destination dirs (create with confirmation; chown only root dir); install host scripts to `/usr/local/lib/usbcopy/`, udev rule, units; `systemctl daemon-reload`; `udevadm control --reload-rules`; stop CT, `pct set -mp0 ...` (USB ro, spool rw, movies rw, series rw), start CT.
- `verify_permissions`: `pct exec` as `usbcopy` to read source (if drive present) and create/delete a test file in each destination; warn, never chmod source.
- `write_manifest`: `/etc/usbcopy/install-manifest.json` with CT ID, created files/dirs, units, mounts, template; backups for any pre-existing file.
- `--dry-run` must not execute any of it.

- [ ] **Step 4: Pass tests** — dry-run + fakes + shellcheck. **Step 5: Manual smoke test placeholder** — record checklist for Manish's host. **Step 6: Checkpoint.**

---

## Task 21: Rollback and uninstall

**Files:**
- Create: `setup/lib/rollback.sh`, `setup/uninstall.sh`; modify `setup/install.sh` (trap)
- Test: extend `setup/tests/test_installer_dryrun.sh`

**Interfaces:**
- Produces: automatic rollback on installer failure (prompt, default yes); `uninstall.sh [--yes] [--destroy-ct]`; keeps destination data by default.

- [ ] **Step 1: Write failing assertions**

```bash
FAKE_FAIL_AT=configure_host ./setup/install.sh --yes 2>&1 | grep -q 'Roll back'
python3 -c "import json; assert json.load(open('/tmp/fake-manifest.json'))['ct_id'] == 101"
./setup/uninstall.sh --yes 2>&1 | grep -q 'Kept destination data'
```

- [ ] **Step 2: Run to verify failure** → FAIL.

- [ ] **Step 3: Implement** — `trap 'rollback_on_error' ERR`; rollback reads manifest, removes added files/units, reloads systemd/udev, destroys the new CT only if it was created by this run; `uninstall.sh` stops/disables, removes host additions, removes bind mounts, optional CT destroy, never removes destination contents, prints kept paths.

- [ ] **Step 4: Pass** — tests + shellcheck. **Step 5: Checkpoint.**

---

## Task 22: README, docs, and CI

**Files:**
- Create: `README.md` (replace stub), `docs/troubleshooting.md`, `.github/workflows/ci.yml`
- Test: `app/tests/test_static_assets.py` (README sections)

**Interfaces:**
- Produces: human-written README and CI running `pytest`, `ruff check`, `shellcheck`, `bash -n`.

- [ ] **Step 1: Write failing test**

```python
def test_readme_has_required_sections():
    text = Path("README.md").read_text().lower()
    for heading in ("what it does", "requirements", "install", "dashboard", "safety",
                    "troubleshooting", "uninstall", "license"):
        assert heading in text
```

- [ ] **Step 2: Run to verify failure** → FAIL.

- [ ] **Step 3: Write human docs**

README in plain language: what it does and why, requirements, one-command install, exactly what the installer asks, dashboard walkthrough, USB folder layout, safety guarantees (read-only source, copy-only, no deletions), configuration, troubleshooting, uninstall, FAQ, license. No marketing tone. `docs/troubleshooting.md`: unsupported FS, permission warnings, port conflicts, drive not detected, rollback. CI workflow:
```yaml
name: ci
on: [push, pull_request]
jobs:
  python:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: {python-version: "3.11"}
      - run: pip install -r app/requirements-dev.txt
      - run: cd app && pytest -q && ruff check .
  shell:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get update && sudo apt-get install -y shellcheck
      - run: shellcheck setup/*.sh setup/lib/*.sh setup/host/*.sh
      - run: bash -n setup/*.sh setup/lib/*.sh setup/host/*.sh
```

- [ ] **Step 4: Pass** — README test + workflow YAML parses (`python -c "import yaml"` if PyYAML available in dev deps). **Step 5: Checkpoint.**

---

## Task 23: Full verification and polish

**Files:**
- Modify: any file with failures; update `DESIGN.md` only if reality diverges.
- Test: entire suite + shell tests.

**Interfaces:** none new.

- [ ] **Step 1: Run Python suite**

Run: `cd app && python -m pytest -q`
Expected: all pass; fix failures (never weaken a test to pass).

- [ ] **Step 2: Run lint and shell checks**

Run: `cd app && ruff check . && cd .. && shellcheck setup/*.sh setup/lib/*.sh setup/host/*.sh && bash -n setup/*.sh setup/lib/*.sh setup/host/*.sh`
Expected: exit 0.

- [ ] **Step 3: Installer dry-run**

Run: `bash setup/tests/test_installer_dryrun.sh && ./setup/install.sh --dry-run --yes`
Expected: plan printed, no host changes.

- [ ] **Step 4: Static/mock checks**

Run: `cd app && python -m pytest tests/test_static_assets.py -q`
Expected: pass; no external URLs; fonts present.

- [ ] **Step 5: Update the manual Proxmox checklist**

Confirm `docs/troubleshooting.md` contains the smoke checklist from DESIGN §18: fresh CT, insert/remove exFAT and NTFS, reboot persistence, permission warning, LAN dashboard, uninstall/reinstall, `touch` fails on source mount.

- [ ] **Step 6: Final checkpoint**

Record test output summary and remaining risks. Commit only if git usage is approved.
