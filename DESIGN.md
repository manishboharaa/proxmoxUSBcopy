# proxmoxUSBcopy — Design

Date: 2026-11-23
Status: Draft for approval
Project folder: `/home/jovyan/opencode/opencode/proxmoxUSBcopy`

## 1. What this is and why

proxmoxUSBcopy copies movies and TV series from external USB drives and HDDs into local folders on a Proxmox host, so a Jellyfin server can pick them up. It runs inside its own small Debian LXC container, detects drives the moment they are plugged in, and shows everything that is happening on a web dashboard.

The main use case is Manish's: plug in a drive full of movies or series, choose what should be imported into the Movies or Series folder, and let the tool copy it safely. Nothing on the source drive is ever changed, moved, or deleted. A second, optional Auto mode handles pre-curated "drop folders" without any interaction.

It is meant to be published as an open-source project: one command to install, no manual Proxmox configuration, and a README a normal person can follow.

## 2. Goals

- One command on the Proxmox host creates the container, installs everything, configures the host, and prints the dashboard link.
- Drives are detected by udev on insertion. No polling loops, no background CPU churn.
- Review mode is the default: scan the drive, show what is on it, let the user pick files/folders and a destination, then copy only that.
- Auto mode is available for trusted, pre-arranged folders.
- Source is mounted read-only at two levels (host mount and CT bind mount). The tool never writes to the source.
- Nothing is copied twice: identical files are skipped and shown as such; conflicts are never silently overwritten.
- Every run and every file is recorded in SQLite and survives restarts — including after the source drive is gone.
- The dashboard is read-only except for the Import review page (select + start). No settings, delete, retry, or host controls in the UI.
- The installer checks permissions for real, fixes destination ownership where needed, and never changes permissions on the USB drive.
- Installer is reversible: namespaced changes, manifest, backup of touched files, failure rollback, clean uninstall.
- Open source, MIT licensed, human-written README.

## 3. Non-goals (v1)

- Metadata scraping, renaming, or reorganising files (TMDb/TVDB lookups). Possible phase 2.
- Talking to the Jellyfin API. We only write files to the folders Jellyfin watches.
- Multi-user accounts, roles, or remote access.
- Non-Proxmox installations (a plain-Linux mode may come later).
- Deleting or mirroring destination contents.
- Copying files over the network directly (SMB/NFS sources). Destinations may live on a mounted local path, but the source is a local block device.
- Mobile app.

## 4. Anti-goals (things that would make this a failure)

- Modifying, moving, or deleting anything on the source drive.
- Running the app in a privileged container.
- Polling the filesystem every few seconds.
- Editing Proxmox `storage.cfg`, networking, or existing VMs/CTs during install.
- Half-written files appearing with their final names in the library.
- Overwriting an existing library file without the user knowing.
- Exposing destructive actions (delete, format, unmount, host shell) in the dashboard.

## 5. Users and environment

- Primary user: Manish, Proxmox administrator, also the first installer.
- Jellyfin runs elsewhere (CT/VM) and reads the same local folders through its own bind mounts.
- The tool runs on Proxmox VE 8.x, in an unprivileged Debian 12 LXC container.
- The dashboard is used from a browser on the LAN.
- Source drives may be exFAT (most common for large media), NTFS, vfat, or ext4.
- The host has internet during install (for apt packages, the LXC template, and PyPI).

## 6. Requirements

**R1 — Installer.** Single command on the Proxmox host. Creates a new unprivileged Debian 12 CT, installs missing dependencies on host and in CT, configures mounts/udev/systemd, and prints the dashboard URL and login at the end. Idempotent on re-run.

**R2 — Startup.** CT has `onboot=1`; the app runs as an enabled systemd service and restarts on failure. A Proxmox reboot brings everything back without manual steps.

**R3 — Detection.** udev detects inserted USB storage instantly; the host mounts it read-only and drops an event file into a shared spool. The app watches the spool with inotify (via a systemd path unit or a Python inotify watcher) and reacts immediately. One scan at app startup catches drives already present at boot. Optional reconciliation scan is off by default.

**R4 — Source safety.** Source mounted `ro,nosuid,nodev,noexec`, and bind-mounted into the CT read-only. The app never issues write, rename, delete, or chmod operations against the source.

**R5 — Review mode (default).** On drive insert, the app builds an inventory only. The dashboard's Import page shows the drive tree, media hints, sizes, duplicate flags, and free space. The user selects files/folders, picks one destination (Movies or Series), and starts the copy. Nothing is copied before that confirmation.

**R6 — Auto mode (optional).** If enabled at install, every file inside the configured source folder is queued automatically to the chosen default destination, with the same safety and duplicate rules. Auto mode is off unless the installer enabled it.

**R7 — Destinations.** The installer asks for a Movies folder and a Series folder on local disk. Both are bind-mounted into the CT. Review mode offers them as a dropdown; Auto mode uses the configured default profile.

**R8 — Naming.** Source names and relative folder structure are preserved exactly. No renaming, no season/episode normalisation in v1.

**R9 — Duplicates.** If the target path already exists with the same size and mtime, the file is marked "already copied" and skipped. If it exists with different size/mtime, it is marked "conflict" and skipped by default (no silent overwrite). The run report shows both.

**R10 — Copy mechanics.** Recursive copy to a temporary `.part` file in the destination directory, fsync, verify, then atomic no-clobber publish (hard-link the temp into place, then remove the temp). Preserve file mtime; write files `0644` and directories `0755`. Verify SHA-256 after copy by default (configurable). Check free space before starting. Three attempts per file with backoff; one failure does not stop the run. Jobs run one at a time.

**R11 — History.** SQLite stores drives, inventories, runs, every file (source path, size, hash, destination path, status, timing), and events. Retention is forever by default; records remain after files are deleted from the source or destination. Absent drives/files are labelled "not present".

**R12 — Dashboard.** Read-only everywhere except the Import page's select-and-start action (and login). Login required. No settings editor, no delete, no retry, no scan buttons. Configuration only via installer or config file.

**R13 — Auth.** Single admin account. Password set or generated at install, stored as a hash. Signed session cookie, CSRF token on the import action, LAN-only binding by default. Audit log records each import start (who/when/what/size/destination).

**R14 — Self-installing.** Installer detects and installs only what is missing: host packages (`exfatprogs`, `ntfs-3g`, `curl`, etc.), Debian 12 LXC template, CT packages (Python 3, venv, pip), Python dependencies. Clear failure message if there is no internet; offline mode documented.

**R15 — Rollback.** Installer writes a manifest of every change and backs up any file it would modify. On failure it offers to destroy the new CT and remove its additions. `uninstall.sh` reverses the install. Copied data is kept unless explicitly deleted. Host additions are namespaced; no edits to storage.cfg or networking.

**R16 — Open source.** MIT license, human-written README, repo layout suitable for GitHub, GitHub Actions for tests and shellcheck.

## 7. Constraints and assumptions

- Proxmox VE 8.x, root access on the host, Debian 12 template available or downloadable.
- One unprivileged CT per install; one installation per Proxmox host in v1.
- Destinations are local paths on the host (local disk). If they live on a mounted NAS path, that still works as long as it is a host path, but it is not tested as a primary target.
- One source drive mounted at a time is the common case; multiple drives are supported but jobs are serialised.
- The dashboard port (default 8088) is free in the CT.
- The host and CT can reach apt/PyPI during install; runtime needs no internet.
- Source filenames are valid UTF-8 or representable in the CT locale; pathological names are logged and skipped rather than crashing the run.
- Jellyfin's own permissions are outside this tool; files are created world-readable (`0644`) so Jellyfin can read them.

## 8. Approaches considered

**A. CT app + host read-only automount + bind mounts (chosen).** Reliable hotplug (udev is the kernel's own event system), source physically read-only, app isolated in an unprivileged CT, no polling. Costs: host-side glue (udev rule, mount unit, bind mounts) and two permission layers to explain.

**B. Privileged CT with raw USB passthrough.** App mounts devices itself. Rejected: fragile hotplug, privileged container, filesystem drivers inside the CT, security risk.

**C. Run everything on the Proxmox host.** Simplest USB handling. Rejected: the requirement is a separate CT, and a host-level web service enlarges the blast radius.

**Frontend:** FastAPI + Jinja2 + vanilla JS/CSS served by the app, no Node/build step, all assets local. React/Svelte rejected for dependency and build weight in a 1 GB appliance; the JSON API leaves room to swap later.

**Database:** SQLite in WAL mode. Rejected Postgres: an extra service for a single-user tool.

## 9. Architecture

```
Proxmox host
├─ udev rule (USB block device with filesystem)
│   └─ usbcopy-mount@.service
│       ├─ mount -o ro,nosuid,nodev,noexec  /dev/sdX1  /srv/usb-ingest/<uuid>
│       └─ write event JSON → /srv/usbcopy/events/
├─ bind mounts into CT
│   ├─ /srv/usb-ingest        → /mnt/usb          (ro)
│   ├─ /srv/usbcopy/events    → /run/usbcopy/events (rw)
│   ├─ <Movies path>          → /data/movies      (rw)
│   └─ <Series path>          → /data/series      (rw)
└─ LXC CT (unprivileged, Debian 12, onboot=1)
    ├─ usbcopy.service  (uvicorn, port 8088)
    │   ├─ FastAPI app + Jinja2 dashboard + SSE
    │   ├─ inotify watcher on /run/usbcopy/events
    │   ├─ inventory scanner + media classifier
    │   ├─ single copy worker (queue)
    │   └─ SQLite (/var/lib/usbcopy/usbcopy.db)
    └─ config /etc/usbcopy/config.toml
```

Host and CT are coupled only through the shared spool directory and the bind mounts. If the app is down, events stay on disk and are processed when it comes back.

## 10. Flows

**Drive inserted**
1. udev matches a USB block device with a supported filesystem.
2. `usbcopy-mount@<id>.service` mounts it read-only at `/srv/usb-ingest/<uuid>`.
3. The unit writes `add` event JSON atomically into `/srv/usbcopy/events/`.
4. The CT app's watcher sees the file, records the drive, and starts an inventory scan (metadata only).
5. Review mode: dashboard shows the drive as "ready to review". Auto mode: a run is queued immediately.

**Review import**
1. User opens Import, expands the tree, selects files/folders, picks Movies or Series.
2. UI shows selected count/size and destination free space.
3. User confirms; `POST /api/imports` validates the selection against the current inventory, checks CSRF/auth, writes an audit record, creates a run and its items.
4. The worker copies one job at a time, updating SQLite; SSE pushes progress to the dashboard.
5. Run finishes; history keeps everything.

**Drive removed**
1. udev remove event → unmount → `remove` event JSON.
2. App marks the drive not present. Any active run is marked "interrupted (drive removed)"; the current temp file is deleted, the item is marked failed, and the run stops cleanly. No final-name half files, no stale `.part` files.

**Proxmox reboot**
1. CT starts (`onboot=1`), app starts, scans `/mnt/usb` for already-mounted drives and the spool for pending events.
2. Host mount units restore for still-connected drives; their events are processed normally.

## 11. Components

### 11.1 Host integration (`setup/host/`)

- **udev rule** (`99-usbcopy.rules`): match `SUBSYSTEM=="block"`, `ENV{ID_BUS}=="usb"`, `ENV{ID_FS_TYPE}!=""`; ignore the host's own disks; trigger the mount unit.
- **`usbcopy-mount@.service`**: template unit; waits for the device, mounts read-only with `ro,nosuid,nodev,noexec`, optional filesystem-specific options; writes event JSON; on stop, unmounts and writes a remove event.
- **Supported filesystems:** ext2/3/4, vfat, exfat (`exfatprogs`), ntfs (`ntfs-3g`). Unknown/unsupported types are ignored and logged; the dashboard shows an "unsupported filesystem" notice with the type.
- **Event JSON:** `{version, action: "add"|"remove", uuid, label, serial, device, mountpoint, fs_type, ts}`. Written temp+rename; app deletes after processing and records it in the DB.
- **Mount root:** `/srv/usb-ingest/<uuid>` (UUID from `blkid`; fallback to device name for FS without UUID).
- **Boot-time enumeration:** `usbcopy-scan-usb.service` runs at host boot, finds USB block devices with supported filesystems that are not already mounted, and starts their mount units. This covers drives connected while Proxmox was off, even if udev coldplug behaves differently.
- **Spool:** `/srv/usbcopy/events`, mode `0750`, owned by the CT's mapped app UID:GID (for example host `100999:100999`) so the app can read and delete event files; the host mount unit writes as root. Bind-mounted rw into the CT.
- **Bind mounts:** added with `pct set` while the CT is stopped: USB root ro, spool rw, destination folders rw.
- **Safety:** mount options and read-only bind mean the CT cannot write to the source even if the app is compromised.

### 11.2 CT application (`app/`)

Python 3.11+, FastAPI, uvicorn, Jinja2, watchdog (inotify), passlib[bcrypt], itsdangerous (session), tomli/tomllib for config. SQLite via stdlib `sqlite3` (WAL, foreign keys).

Modules:
- `config.py` — load/validate `/etc/usbcopy/config.toml`; paths, profiles, mode, port, auth hash, scan settings.
- `db.py` — schema, migrations, connection helpers.
- `events.py` — inotify watcher on the spool; startup catch-up scan of `/mnt/usb`; writes `drives`/`events` rows.
- `inventory.py` — metadata-only scan of a drive (or configured subfolder), skipping system dirs; stores dirs/files; progress updates; media classification hints.
- `media.py` — extension list and TV/movie name heuristics (suggestions only).
- `planner.py` — turns a validated selection + destination into run items; duplicate/conflict flags; free-space check.
- `copier.py` — single worker; temp file, chunked copy, hash, fsync, atomic no-clobber publish, mtime; retries; cancellation on drive removal.
- `jobs.py` — in-process queue; serialised execution; run lifecycle.
- `api.py` — JSON endpoints + SSE.
- `web.py` — Jinja2 routes, auth, CSRF.
- `auth.py` — password hash, sessions, audit.
- `main.py` — app factory, startup recovery (mark orphaned runs interrupted, clean stale temp files).

### 11.3 Dashboard (`app/templates/`, `app/static/`)

Pages:
- **Login** — single admin.
- **Overview** — connected drives, active run with live progress, queue, recent runs, free space per destination.
- **Import (interactive)** — drive picker, collapsible tree with checkboxes, size and media hint per item, duplicate/conflict badges, destination dropdown (Movies/Series), selected totals vs free space, confirm.
- **Runs** — filterable history (all/copied/failed/skipped/conflict), per-run detail with per-file status, source path vs destination path, hash, duration, error reason.
- **Drives** — every drive ever seen (label, serial, UUID, first/last seen, last inventory), "not present" badge when absent.
- **About** — version, config summary (no secrets), log locations, project link.

Design system:
- Hand-written CSS with tokens for colour, spacing, typography; dark and light themes; theme choice stored client-side only.
- Embedded woff2 fonts (Inter + JetBrains Mono, both OFL), subset, no external requests.
- Live updates via SSE; reconnect with backoff; no browser polling.
- Status chips: queued, scanning, copying, copied, skipped, conflict, failed, interrupted.
- Crisp-rendering rules: integer font sizes, no fractional transforms, integer SVG sizing, antialiasing, contrast checked.
- Keyboard navigable, focus states, reduced-motion support, responsive down to tablet.
- No frameworks; small vanilla JS modules. Charts (if any) drawn as inline SVG sparklines; no Chart.js dependency.

### 11.4 API

Read-only (GET): `/api/status`, `/api/drives`, `/api/drives/{id}`, `/api/inventories/{id}` (tree, paginated), `/api/runs`, `/api/runs/{id}`, `/api/runs/{id}/items`, `/api/events/stream` (SSE).

Interactive (auth + CSRF): `POST /api/imports` with `{inventory_id, destination: "movies"|"series", paths: [...]}`. `POST /api/login`, `POST /api/logout`.

No endpoints to change config, delete data, retry failures, mount/unmount, or run shell commands.

### 11.5 Installer (`setup/install.sh`)

Run on the Proxmox host as root. Supports `--repo-url`, `--ref`, `--dry-run`, `--yes` (defaults), `--uninstall`, `--help`. Prompts read `/dev/tty` so `curl … | bash` works.

Prompt list (defaults in brackets):
1. CT ID [next free]
2. Hostname [usbcopy]
3. Storage for CT disk [`local-lvm` or first with `images`]
4. Disk size [8 GB], RAM [1024 MB], cores [2], swap [512 MB]
5. Network: DHCP or static (IP/gateway/DNS) [DHCP]
6. Movies destination folder on host (must be local path) [none — required]
7. Series destination folder on host [none — required]
8. Optional extra destination (e.g. Other) [skip]
9. Default source folder on the drive, used by Auto mode and as the Review starting point [blank = browse whole drive]
10. Enable Auto mode for that folder? [No]
11. Dashboard port [8088]; the installer checks the port is free in the CT and re-prompts (or offers the next free port) if it is already in use
12. Admin password [generate and print once]
13. Confirmation summary (shows all changes)

Steps:
1. Preflight: root, `pveversion`, internet, storage support for `vztmpl`/`images`, bridge, free CT ID, destination paths (create with confirmation; validate writability; free space).
2. Download Debian 12 template if missing (`pveam update`, `pveam download`).
3. Create CT (`pct create`, unprivileged, `onboot=1`, `features` defaults), start it.
4. Wait for network; `apt-get update`; install missing packages (python3, venv, pip, ca-certificates, curl); create `usbcopy` system user; create venv; install pinned requirements from the fetched repo tarball.
5. Push app files and config; enable `usbcopy.service`.
6. Host: create `/srv/usb-ingest`, `/srv/usbcopy/events`, destination dirs; compute the CT's mapped UID for `usbcopy`; `chown` only the destination root (not its existing contents); add udev rule, mount unit, reload systemd/udev; stop CT, add bind mounts, start CT.
7. Permission test inside CT as `usbcopy`: read a source folder if a drive is present, write/remove a test file in each destination. Warn clearly if source files are unreadable; never chmod the source.
8. Health check `GET /api/status` from the host; print `http://<CT-IP>:<port>`, username `admin`, password (or note where it was generated), log paths, `uninstall` command.
9. Write manifest + backups; on any failure, offer rollback (destroy new CT, remove added files/units, reload udev/systemd).

Dependencies installed only if missing. No package is removed on uninstall unless the installer added it and the user opts in (default: leave host packages).

### 11.6 Rollback and uninstall

- Manifest: `/etc/usbcopy/install-manifest.json` — CT ID, files created, units enabled, mounts added, dirs created, template downloaded, timestamp/version.
- Backups: any pre-existing file the installer would replace goes to `/etc/usbcopy/backup/<timestamp>/`.
- Failure trap: prompts "Roll back the partial install? [Y/n]"; automatic cleanup of the new CT and added files.
- `uninstall.sh`: stop/disable units, remove udev rule and mount unit, reload, remove `/srv/usb-ingest` and spool (warn if events pending), remove bind mounts, optionally destroy CT (explicit prompt, default keep), keep destination data always unless separately confirmed. Print what was kept.

### 11.7 Repo layout

```
proxmoxUSBcopy/
├─ README.md
├─ LICENSE (MIT)
├─ DESIGN.md
├─ PLAN.md
├─ app/
│  ├─ usbcopy/            # Python package
│  ├─ templates/
│  ├─ static/
│  ├─ requirements.txt
│  └─ tests/
├─ setup/
│  ├─ install.sh
│  ├─ uninstall.sh
│  ├─ lib/                # shared bash helpers
│  └─ host/               # udev rule, mount unit, templates
├─ docs/                  # troubleshooting, screenshots
└─ .github/workflows/     # pytest, shellcheck
```

## 12. Data model (SQLite)

- `destinations(id, name, path_in_ct, path_on_host, is_default, created_at)`
- `drives(id, uuid, label, serial, fs_type, mountpoint, first_seen, last_seen, present)`
- `events(id, ts, level, action, drive_id, payload_json, processed)` — `level`: info/warning/error
- `inventories(id, drive_id, root, status, started_at, finished_at, total_files, total_bytes, error)`
- `inventory_entries(id, inventory_id, rel_path, parent_path, is_dir, size, mtime, kind, media_hint, duplicate_state)` — `kind`: video/other; `duplicate_state`: none/exists/conflict
- `runs(id, drive_id, inventory_id, destination_id, mode, status, started_at, finished_at, files_total, bytes_total, bytes_done, error)`
- `run_items(id, run_id, rel_path, size, dest_rel_path, temp_path, status, bytes_done, sha256, attempts, error, started_at, finished_at)`
- `audit(id, ts, actor, action, detail_json)`
- `settings` — schema version and small runtime flags only; user configuration stays in TOML.

Indexes on run status, drive presence, inventory entries by parent, run_items by run/status.

## 13. Copy semantics

- Destination mapping: a selected file goes to `<profile>/<basename>`; a selected folder's **contents** go to `<profile>/...`, preserving the structure below that folder (the folder's own name is not repeated). Overlapping selections (a folder plus something inside it) are de-duplicated so each path is copied once.
- No drive-label wrapper: files land directly in the chosen Movies/Series tree so Jellyfin sees the expected layout. Collisions are caught by the duplicate/conflict rules below.
- Pre-flight: destination writable, free space ≥ selected bytes × 1.02 + 256 MB margin.
- Existing target: same size and mtime (within 2s) → `skipped (exists)`; otherwise `conflict` and skipped. No overwrite in v1.
- Temp file `.usbcopy.<random>.part` in the target directory; chunked copy (8 MB); SHA-256 computed while reading; fsync; verify temp hash; set mtime/mode on the temp; atomic no-clobber publish via `os.link` (fails if the target exists) then unlink the temp; fsync the directory (a failure is logged, never a false "not copied").
- Any failure removes the temp file. No `.part` survives a failed item.
- Retries per file: 3, backoff 2s/5s/10s. Run continues after exhaustion; item marked failed with the error.
- Progress is persisted at most once per second per run, plus on every item state change, to avoid SQLite write amplification on large files.
- Whole-run cancellation on drive removal: current file fails as interrupted, temp deleted, remaining items marked cancelled; run status `interrupted`.
- Jobs are serialised (one copy at a time) to avoid disk thrash and confusing progress.
- Source read errors (permission, I/O) are recorded per file; the run continues.
- No operation ever writes, renames, deletes, or chmods anything on the source.

## 14. Review / inventory behaviour

- Review scans the drive root by default; the configured source folder is the initial view if set. The user can navigate the whole drive tree.
- Selecting a folder means "copy what is inside it". Its own name is not added again under the destination, so selecting `Movies/` does not produce `movies/Movies/`.
- Skip system folders: `System Volume Information`, `$RECYCLE.BIN`, `.Trashes`, `lost+found`, `.Spotlight-V100`, `.fseventsd`, and hidden dot-directories at the root (shown only with an "show hidden" toggle? v1: skipped silently and listed in run notes).
- Media hints only: video extensions (`mkv, mp4, m4v, avi, mov, wmv, webm, ts, m2ts, mpg, mpeg, flv, 3gp`) plus TV regex (`S01E02`, `Season 1`, `1x02`) → "series" hint; other videos → "movie" hint; non-video → "other". Hints never change what is copied.
- Duplicate state is computed against the mapped destination path at selection time (path + size/mtime); updates live in the tree.
- One destination per import batch. A mixed selection is allowed but the user is warned if it contains both movie and series hints.
- Destination dropdown lists configured profiles; Movies and Series are always available; an optional extra profile appears if configured.
- Selection is client-side; the server re-validates every path against the inventory before creating the run (no arbitrary host paths accepted).

## 15. Security

- Unprivileged CT; app runs as `usbcopy`, not root.
- Dashboard binds LAN; login required for all pages; session cookie `HttpOnly`, `SameSite=Lax`, `Secure` when served over HTTPS (optional reverse proxy).
- CSRF token on `POST /api/imports`; origin checked.
- File paths from the UI must match inventory entries; reject traversal (`..`, absolute paths, symlink escapes). Source paths are resolved under the mount root; destination under the profile root.
- No shell execution from the web app. Installer avoids `eval`; uses quoted variables and `set -euo pipefail` (shellcheck-clean).
- Secrets (session key, password hash) in `/etc/usbcopy/config.toml` mode `0640`, owner `root:usbcopy`.
- Spool is host-owned; app can read/delete entries but cannot write arbitrary files there (bind mount is rw for event cleanup; acceptable, app is trusted).
- Audit log for import starts and logins.
- Source read-only at host mount and CT bind; even a compromised app cannot alter the drive.
- Installer never enables SSH, never opens firewall ports beyond the CT's dashboard port, never changes host networking.

## 16. Reliability and error handling

- SQLite WAL, `synchronous=NORMAL`, foreign keys on; DB in `/var/lib/usbcopy/`, owned by `usbcopy`.
- Startup recovery: runs left `running` are marked `interrupted`; stale `.part` files in destinations are removed only when recorded in the DB; unknown `.usbcopy.*.part` older than 24h are logged, not deleted.
- systemd `Restart=on-failure` with `RestartSec=5`.
- Logs to journald; log level configurable.
- Unsupported filesystem, unreadable source, full destination, drive removal, and DB errors all surface in the dashboard and in run history with a human-readable reason.
- Health endpoint for the installer and for the dashboard banner.
- Clock/timezone: timestamps stored UTC; UI renders local time.

## 17. Configuration (`/etc/usbcopy/config.toml`)

```toml
[server]
host = "0.0.0.0"
port = 8088

[auth]
username = "admin"
password_hash = "..."

[source]
# Empty means "browse the whole drive" in Review mode.
default_folder = ""

[mode]
default = "review"        # review | auto
auto_enabled = false
auto_destination = "movies"

[copy]
verify_sha256 = true
chunk_size_mb = 8
retries = 3
preserve_mtime = true

[destinations.movies]
path = "/data/movies"
[destinations.series]
path = "/data/series"

[scan]
reconcile_minutes = 0     # 0 = off
skip_hidden_root_dirs = true
```

## 18. Testing and verification

- Unit tests: path validation, planner/duplicate logic, media hints, copy+hash+atomic no-clobber publish, retry, conflict handling, inventory skipping, DB migrations, auth/CSRF.
- Integration tests: temp source/destination trees; simulate an event file and a fake mount; full review → run → history; interrupted run recovery; stale temp cleanup.
- API tests with FastAPI TestClient; SSE smoke test.
- Shell: `shellcheck`, `bash -n`; installer `--dry-run` test that performs all checks and prints the plan without changes.
- CI: GitHub Actions running pytest and shellcheck on push/PR.
- Manual Proxmox checklist (documented, not automatable here): fresh CT creation, drive insert/remove, exFAT and NTFS mounts, reboot persistence, permission warnings, dashboard from LAN, uninstall + reinstall.
- Acceptance: a plugged-in exFAT drive appears in Review within seconds; selecting a movie folder copies to Movies with correct structure and hash; history survives a drive removal and app restart; no write occurs on the source (verified by mount flags and `touch` failure).

## 19. Decisions left to the builder

- Exact Python package versions and whether to add `uvloop`.
- Template strategy for small JS helpers (vanilla modules vs a tiny vendored library).
- Whether the inventory tree is rendered server-side per node or fetched lazily as JSON.
- Exact CSS token values and font subsetting details.
- Log rotation policy beyond journald defaults.
- Implementation order within the plan.

## 20. Sign-off decisions (resolved 2026-11-23)

1. Import page is the only interactive surface (select + start); everything else is view-only. **Confirmed.**
2. GitHub owner/repo URL: **Manish will provide later**; the installer uses one `REPO_URL` variable with a placeholder until then.
3. CT defaults: 2 vCPU / 1 GB RAM / 8 GB disk / DHCP. **Confirmed.**
4. Optional "Other" destination profile: **not included**; Movies and Series only in v1.
5. Default source folder: **blank = browse the whole drive** in Review mode. **Confirmed.**
6. Existing files: **skip conflicts, never overwrite in v1.** **Confirmed.**
7. Dashboard port: user-selectable at install, default 8088; installer checks availability and re-prompts/offers the next free port if taken. **Confirmed.**
