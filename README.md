# proxmoxUSBcopy

proxmoxUSBcopy copies movies and TV series from USB drives into local Movies and
Series folders on a Proxmox host, so a Jellyfin server can find them. It runs
in its own small Debian 12 LXC container and shows what is happening in a web
dashboard. The source drive is mounted read-only and is never changed.

## What it does

- Watches for USB drives on the Proxmox host. When a drive is plugged in, the
  host mounts it read-only under `/srv/usb-ingest/<uuid>` and sends an event to
  the app in the container.
- Scans the drive and shows its folders and files in **Review** mode. You pick
  what to copy, choose Movies or Series (or an optional extra folder), and
  confirm before anything is copied.
- Supports an optional **Auto** mode for trusted, pre-arranged drives. When it
  is enabled, the configured source folder is copied into the configured
  destination without interaction.
- Copies one job at a time. Each file is written under a temporary name, hashed,
  flushed to disk, and then published, so Jellyfin never sees a half-written
  final file.
- Keeps a permanent history of runs and files in SQLite, including after the
  drive is unplugged or the container restarts.
- Provides a dashboard for drives, imports, runs, history, and basic health.

It does not scrape metadata, rename or reorganise files, talk to the Jellyfin
API, delete library contents, or expose host shell controls.

### USB folder layout

A typical drive looks like this:

```text
USB drive
└── Movies
    └── The Film (2020)
        └── The Film (2020).mkv
```

Selecting `Movies` copies its contents into your Movies destination. The
selected folder's own name is not repeated, so you get
`Movies/The Film (2020)/...`, not `Movies/Movies/...`.

## Requirements

- Proxmox VE 8.x on the host, with root access.
- One Debian 12 LXC container. The installer creates it as an unprivileged
  container; you do not need to prepare one first.
- Free space on the container storage for the CT disk (8 GB by default), plus
  enough free space in the destination folders for the files you import. The
  copy preflight requires the selected size times 1.02 plus 256 MB.
- A USB drive. The source filesystem must be mountable by the Proxmox host.
  Supported filesystems are ext2, ext3, ext4, vfat, exFAT, and NTFS. For exFAT
  and NTFS, the host normally needs `exfatprogs` and `ntfs-3g`; see
  [docs/troubleshooting.md](docs/troubleshooting.md) if a mount fails.
- A browser on the same network as the dashboard.
- Internet access on the host during installation (for the LXC template, apt
  packages, and Python packages).
- Jellyfin, or another media server, that already reads the destination
  folders. This project only writes files; it does not configure Jellyfin.

## Install

### One command

Run this on the Proxmox host. Replace both instances of `<owner>` with the
GitHub account or organisation that hosts the repository:

```bash
curl -fsSL https://raw.githubusercontent.com/<owner>/proxmoxUSBcopy/main/setup/install.sh \
  | sudo bash -s -- \
      --repo-url https://github.com/<owner>/proxmoxUSBcopy \
      --ref main
```

`--ref` is the branch, tag, or commit to install and defaults to `main`; you can
leave it out. Piped installs require an `https://` repository URL and do not
accept credentials embedded in the URL.

### From a checkout

```bash
git clone https://github.com/<owner>/proxmoxUSBcopy.git
cd proxmoxUSBcopy
sudo ./setup/install.sh
```

Use this if you want to read the code first or install a local branch. The
checkout's `app/` and `setup/` directories are used directly.

### What the installer asks

The prompts appear in this order:

1. **CT ID** - defaults to the next free ID.
2. **Hostname** - defaults to `usbcopy`.
3. **Storage for the CT disk** - `local-lvm` when it supports container
   images, otherwise the first storage that does.
4. **Disk size** - 8 GB by default.
5. **RAM** - 1024 MB by default.
6. **CPU cores** - 2 by default.
7. **Swap** - 512 MB by default.
8. **Network** - DHCP by default, or a static IP with prefix, gateway, and
   optional DNS servers.
9. **Movies destination folder on the host** - required. It must be a local
   path; the installer creates it when needed and checks that it is writable.
10. **Series destination folder on the host** - required, same rules.
11. **Optional extra destination folder** - blank to skip. If set, it becomes
    another destination profile in the dashboard.
12. **Default source folder on the drive** - blank means Review mode starts at
    the whole drive. Auto mode requires a folder here.
13. **Auto mode** - No by default. If enabled, that source folder is copied into
    the configured auto destination (Movies by default) when a drive appears.
14. **Dashboard port** - 8088 by default. The installer checks that the port is
    free inside the new container and uses the next free port from 8088 to 8188
    if it is taken.
15. **Admin password** - blank generates a random password. The password is
    printed once, immediately after you confirm the summary and before the
    container is created. Save it before continuing.
16. **Confirmation summary** - shows every setting and planned change. Answer no
    to stop without changing anything.

After confirmation, the installer creates the container, installs the app,
configures udev, systemd, and bind mounts, checks permissions, calls
`/healthz`, and prints the dashboard URL, username `admin`, log commands, and
the uninstall command.

### Flags and non-interactive use

- `--dry-run` performs the read-only preflight and prompts, prints every planned
  action, and exits without changing the host. It is safe to run first.
- `--yes` accepts the defaults and skips the confirmation prompt.
- `--repo-url URL` selects the repository for a piped install.
- `--ref REF` selects the branch, tag, or commit (default `main`).
- `--uninstall` runs the uninstaller instead of installing.
- `--destroy-ct` with `--uninstall` also destroys the container.
- `--help` prints the options.
- `USBC_ANSWERS` can supply non-interactive answers with `--yes`. It is a single
  space-separated string, consumed one token per prompt in the order above. Use
  `''` for a blank answer. Answers cannot contain spaces. Do not put the
  admin password in `USBC_ANSWERS`; environment values can leak through process
  inspection and shell history.

The installer records what it changed in
`/etc/usbcopy/install-manifest.json`. If a step fails, it offers to roll back
the partial install; answering yes (the default) removes what that run created
and restores backups.

## Dashboard

Open `http://<ct-ip>:<dashboard-port>/` in a browser and log in as `admin` with
the password from the installer. The installer prints the actual IP and port;
the default port is 8088.

The dashboard is meant for a trusted LAN. It has no built-in HTTPS and only one
admin account. If you need remote access, put it behind a reverse proxy you
control.

Pages:

- **Overview** - connected drives, the active run with live progress, the queue,
  recent runs, and free space for each destination.
- **Import** - the drive picker and folder tree. Expand folders, tick files or
  folders, see sizes, media hints, duplicate/conflict badges, and selected
  totals against destination free space, then confirm the import.
- **Runs** - filterable history. A run detail shows each file, its status,
  source and destination paths, SHA-256, duration, and any error.
- **Drives** - every drive ever seen, with label, serial, UUID, first and last
  seen time, last inventory, and a "not present" badge when it is unplugged.
- **About** - version, configuration summary without secrets, and log commands.

Import is the only page that changes anything: it creates a copy job. Every
other page is read-only. There are no settings, delete, retry, mount, unmount,
or shell controls in the UI.

### Review mode vs Auto mode

Review is the default. You choose the drive, browse the whole drive or start at
the configured source folder, select files or folders, choose one destination,
and confirm. Selecting a folder means "copy what is inside it".

Auto mode is optional and only works with the configured source folder. When a
drive is plugged in, the app plans that folder into the configured auto
destination and queues the run without asking. It uses the same copy rules and
still records everything in history.

### How jobs progress

Runs are queued and copied one at a time. A run moves through queued, copying,
and a final state. Each file ends as copied, skipped, conflict, failed, or
interrupted. The dashboard receives live updates over server-sent events; the
database is updated at most once per second per run and on every file state
change. Closing the browser does not stop a run because the work happens in the
container. If the drive is removed during a copy, the current temporary file is
deleted, that item is marked interrupted, and the remaining items are
cancelled. No final-name half files are left behind.

### Configuration

Settings are not edited in the dashboard. The installer writes
`/etc/usbcopy/config.toml` inside the container (mode 0640, owner
`root:usbcopy`) and keeps the database at `/var/lib/usbcopy/usbcopy.db`. The
About page shows the loaded paths and log commands. If you change the config,
restart the app and keep the file private because it contains the password hash
and session secret.

## Safety

- The source is mounted read-only at the host level with
  `ro,nosuid,nodev,noexec`, and the container gets a read-only bind mount when
  Proxmox accepts the read-only bind flag. If Proxmox rejects that flag, the
  installer warns; the host mount is still read-only and the app does not write
  to the drive.
- Copying is copy-only. The app never writes, moves, or deletes source files and
  never changes source permissions.
- Existing library files are never overwritten. If the target already has the
  same name, size, and modification time (within 2 seconds), the file is
  skipped as identical. A different file at the same path is reported as a
  conflict and skipped.
- Each copy uses a temporary `.usbcopy.<random>.part` file in the target
  directory. The app hashes and flushes it, then publishes it with an atomic
  no-clobber link. A failed copy removes its temporary file.
- Every run and file is recorded in a permanent SQLite history while the app is
  installed, including after a drive removal or restart.
- Uninstalling keeps the CT and your destination files by default. It does
  remove the app and its database inside the CT, so copy the history database
  out first if you want to keep it.
- The app runs as the `usbcopy` user, not root, in an unprivileged container.
  The installer chowns only the destination roots (not their existing contents)
  and the event spool to the container's mapped UID. It never changes ownership
  or permissions on the source.
- The installer does not change host networking, SSH, or firewall rules. The
  dashboard listens on its container port. The web app does not run shell
  commands, and import paths are validated against the scanned inventory.

## Troubleshooting

Start with [docs/troubleshooting.md](docs/troubleshooting.md). It covers drives
that are not detected, unsupported filesystems, permission warnings, dashboard
port conflicts, copy conflicts and skips, service health, pending spool events,
rollback, and uninstall/reinstall.

Quick checks on the host:

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,TRAN,MOUNTPOINT
journalctl -u 'usbcopy-mount@*' -b --no-pager
pct exec <ct-id> -- systemctl status usbcopy --no-pager
curl -fsS http://<ct-ip>:<port>/healthz
```

A healthy app returns `{"status":"ok"}` from `/healthz`. Application and mount
logs go to journald; there are no separate log files to rotate.

## Uninstall

From a checkout:

```bash
cd proxmoxUSBcopy
sudo ./setup/uninstall.sh
```

By default this stops and disables the app, removes the app files, config, and
database inside the CT, removes the host wiring and bind mounts, restores
backups, and keeps the CT and every destination file. It prints what was kept.

- `--dry-run` prints every action without changing anything.
- `--yes` skips the confirmation prompt.
- `--destroy-ct` also stops and destroys the CT. Destination files are still
  kept.

If you installed with the piped command, re-run it with `--uninstall` (and
optionally `--destroy-ct`); the temporary checkout is not kept:

```bash
curl -fsSL https://raw.githubusercontent.com/<owner>/proxmoxUSBcopy/main/setup/install.sh \
  | sudo bash -s -- \
      --repo-url https://github.com/<owner>/proxmoxUSBcopy \
      --uninstall
```

The installer uses `/etc/usbcopy/install-manifest.json` and refuses to
uninstall without it. Backups of any host files it replaced are under
`/etc/usbcopy/backup/<timestamp>/`. Reinstalling requires a successful uninstall
first. Because the default keeps the CT, a later install creates a new CT; pass
`--destroy-ct` during uninstall if you want the old one removed.

## FAQ

**Does it delete or move anything on the USB drive?**
No. The source is read-only, and copying is copy-only.

**Does it rename or clean up my library?**
No. Files are copied with their names and folder structure below the selected
folder. Metadata scraping and renaming are not part of v1.

**What happens if I import the same drive twice?**
Identical files are skipped and conflicts are reported; nothing is overwritten.

**Does it talk to Jellyfin?**
No. It writes to the folders Jellyfin watches. Trigger a library scan in
Jellyfin after an import.

**Can two imports run at once?**
No. Jobs are queued and copied one at a time.

**What happens if I unplug the drive during a copy?**
The current temporary file is removed, that item is marked interrupted, and the
rest of the run is cancelled. Reconnect the drive and create a new import.

## License

MIT. See [LICENSE](LICENSE).

Copyright (c) 2026 Manish Bohara
