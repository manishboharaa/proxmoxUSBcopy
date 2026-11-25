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
- Keeps a persistent history of runs and attempted files in SQLite while the
  app is installed, including after the drive is unplugged or the container
  restarts.
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

- Proxmox VE 8 or higher on the host, with root access (tested on 8.2 and 9.1).
- One Debian 12 LXC container. The installer creates it as an unprivileged
  container; you do not need to prepare one first.
- An LXC-template-capable storage on the host (content type `vztmpl`, usually
  `local`) with room for the Debian 12 template.
- Free space on the container storage for the CT disk (8 GB by default), plus
  enough free space in the destination folders for the files you import. The
  copy preflight requires the selected size times 1.02 plus 256 MiB.
- A USB drive. The source filesystem must be mountable by the Proxmox host.
  Supported filesystems are ext2, ext3, ext4, vfat, exFAT, and NTFS. The
  installer installs packages inside the CT only; host filesystem helpers are
  manual. NTFS normally needs `ntfs-3g`. exFAT normally uses the host kernel's
  exFAT driver; install `exfatprogs` only if the mount helper or tools are
  missing. See [docs/troubleshooting.md](docs/troubleshooting.md) if a mount
  fails.
- Destination folders on a filesystem that supports hard links, chmod, and
  utime (ext4, XFS, Btrfs, or ZFS). FAT and exFAT destinations are not
  supported.
- A browser on the same network as the dashboard.
- Internet access on the host during installation (for the LXC template, apt
  packages, and Python packages).
- Jellyfin, or another media server, that already reads the destination
  folders. This project only writes files; it does not configure Jellyfin.

## Install

### One command

On a Proxmox host with internet access, run:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/manishboharaa/proxmoxUSBcopy/main/setup/install.sh)"
```

### From the repo folder

If you'd rather look at the code before running anything, download or copy
the repo to your Proxmox host and run the installer from inside it:

```bash
cd proxmoxUSBcopy
sudo ./setup/install.sh
```

Run `sudo ./setup/install.sh --dry-run` first if you want to see the plan
without changing anything. `--repo-url` and `--ref` only affect the piped
bootstrap; running the installer from the repo folder uses the files in
front of it.

### What the installer asks

Interactive installs start from a table of defaults instead of a wall of
questions:

```
install.sh: ready to install. These settings will be used:
  ----------------------------------------------------------------
   1. CT ID                  101
   2. Hostname               usbcopy
   3. Storage                data
   4. Disk size              8 GB
   5. RAM                    1024 MB
   6. CPU cores              2
   7. Swap                   512 MB
   8. Network                DHCP (bridge vmbr0)
   9. Movies destination     /data/movies
  10. Series destination     (not set - required)
  11. Extra destination      none
  12. Auto-mode source       whole drive
  13. Dashboard port         8088
  14. Admin password         auto-generate
  ----------------------------------------------------------------

Press Enter to install with these settings, or type a number to change it.
You can change as many as you like, one at a time.
```

Press Enter to install with the defaults, or type a number and answer the
follow-up for that one setting; the table is shown again after every change.
In a terminal the values are coloured (green when set, red while a required
destination is still unset).

Press Enter to install with the defaults, or type a number and answer the
follow-up for that one setting; the table is shown again after every change.
A wrong answer (a storage name that does not exist, an in-use CT ID, a bad
IP) is reported and asked again instead of ending the install. Movies and
Series destinations are required; the installer points you at menu items 9
and 10 until both are set. The individual settings:

- **CT ID** - defaults to the next free ID.
- **Hostname** - defaults to `usbcopy`.
- **Storage for the CT disk** - `local-lvm` when it supports container
  images, otherwise the first storage that does.
- **Disk size, RAM, CPU cores, Swap** - 8 GB, 1024 MB, 2 cores, 512 MB.
- **Network** - DHCP by default, or a static IP with prefix, gateway, and
  optional DNS servers.
- **Movies destination folder on the host** - required. It must be a local
  path; the installer creates it when needed and checks that it is writable.
- **Series destination folder on the host** - required, same rules.
- **Optional extra destination folder** - blank to skip. If set, it becomes
  another destination profile in the dashboard.
- **Default source folder for Auto mode** - Auto mode requires a folder here.
  Review always opens at the drive root; this setting does not change Review.
- **Auto mode** - No by default. If enabled, that source folder is copied into
  the configured auto destination (Movies by default) when a drive appears.
- **Dashboard port** - 8088 by default. The installer checks that the port is
  free inside the new container and falls back to the first free port from
  8088 to 8188 if it is taken.
- **Admin password** - blank generates a random password. The password is
  printed once, immediately after you confirm the summary and before the
  container is created. Save it before continuing.
- **Confirmation summary** - after the menu, every setting and planned change
  is shown one last time. Answer no to stop without changing anything.

After confirmation, the installer creates the container, installs the app,
configures udev, systemd, and bind mounts, checks permissions, calls
`/healthz`, and prints the dashboard URL, username `admin`, log commands, and
the uninstall command.

### Flags and non-interactive use

- `--dry-run` performs the read-only preflight and prompts, prints every planned
  action, and exits without changing the host. It is safe to run first.
- `--yes` accepts defaults and skips the confirmation summary. Movies and
  Series are required and have no defaults, so `--yes` alone fails at the
  destination prompt; supply them interactively or through `USBC_ANSWERS`.
- `--repo-url URL` selects the repository for a piped bootstrap. It does
  nothing when you run the installer from the repo folder.
- `--ref REF` selects the branch, tag, or commit for a piped bootstrap (default
  `main`). It does nothing when you run the installer from the repo folder.
- `--uninstall` runs `setup/uninstall.sh` instead of installing.
- `--update` refreshes an existing install: it reinstalls the host scripts,
  udev rule, and systemd units, then pushes the newest app files into the
  existing CT and restarts the dashboard. `config.toml`, the admin password,
  and all stored data are kept. Example:
  `curl -fsSL https://raw.githubusercontent.com/manishboharaa/proxmoxUSBcopy/main/setup/install.sh | bash -s -- --update`
- `--destroy-ct` with `--uninstall` also destroys the container.
- `--help` prints the options.

`USBC_ANSWERS` supplies non-interactive answers. It is one space-separated
string consumed in prompt order:

```text
CTID hostname storage disk-GB RAM-MB cores network movies series extra source auto port [password]
```

That is 14 tokens when you supply the optional password: 13 required tokens
plus the 14th password token. Omit the password to generate one. Swap is forced to 512 MB and is not prompted.
`--yes` skips the confirmation summary without consuming an answer token.
Movies and Series are required, so `USBC_ANSWERS` must include them. For DHCP,
`network` is the single token `dhcp`. For static networking, use `static` and
then three more tokens: `IP/prefix gateway DNS` (use `''` for blank DNS). Use
`''` for a blank extra destination or source folder. Answers cannot contain
spaces. Do not put the admin password in `USBC_ANSWERS`; environment values can
leak through process inspection and shell history.

Dry-run example with DHCP and a generated password:

```bash
USBC_ANSWERS="101 usbcopy local-lvm 8 1024 2 dhcp /srv/movies /srv/series '' '' no 8088" \
  sudo -E ./setup/install.sh --dry-run --yes
```

Static network variant:

```bash
USBC_ANSWERS="102 usbcopy local-lvm 8 1024 2 static 192.168.1.50/24 192.168.1.1 1.1.1.1 /srv/movies /srv/series '' '' no 8088" \
  sudo -E ./setup/install.sh --dry-run --yes
```

The installer writes `/etc/usbcopy/install-manifest.json` at the final
write-manifest stage. If a step fails, it offers to roll back the partial
install; answering yes (the default) removes what that run created and restores
backups. If you decline before the manifest is written, there is no supported
uninstall record; clean up the printed CT and host changes manually. A later
install is blocked only when a manifest already exists.

## Dashboard

Open `http://<ct-ip>:<dashboard-port>/` in a browser and log in as `admin` with
the password from the installer. The installer prints the actual IP and port;
the default port is 8088. Change the password any time on the **Account** page
(current password plus the new one, minimum 12 characters).

The dashboard is meant for a trusted LAN. It has no built-in HTTPS and only one
admin account. If you need remote access, put it behind a reverse proxy you
control. A run that is queued or copying can be cancelled from its run page
under **Runs**; already-copied files stay, the rest is marked as interrupted.

Pages:

- **Overview** - connected drives, the active run with live progress, the queue,
  recent runs, and free space for each destination.
- **Import** - the drive picker and folder tree. Expand folders, tick files or
  folders, see sizes, media hints, duplicate/conflict badges, and selected
  totals against destination free space, then confirm the import.
- **Runs** - filterable history. A run detail shows each attempted file, its
  status, source and destination paths, SHA-256, duration, and any error.
- **Drives** - every drive ever seen, with label, serial, UUID, first and last
  seen time, last inventory, and a "not present" badge when it is unplugged.
- **About** - version, configuration summary without secrets, and log commands.

Import is the only page that changes anything: it creates a copy job. Every
other page is read-only. There are no settings, delete, retry, mount, unmount,
or shell controls in the UI.

### Review mode vs Auto mode

Review is the default. You choose the drive, browse from the drive root, select
files or folders, choose one destination, and confirm. Selecting a folder means
"copy what is inside it".

Auto mode is optional and only works with the configured source folder. When a
drive is plugged in, the app plans that folder into the configured auto
destination and queues the run without asking. It uses the same copy rules and
still records its runs and attempted files in history.

### How jobs progress

Runs are queued and copied one at a time. A run moves through queued, running,
and a final state. Each attempted file ends as copied, failed, cancelled, or
interrupted. Identical and conflict entries are shown in the Import preview;
they are not stored as per-file run items. The dashboard receives live updates
over server-sent events; the database is updated at most once per second per run
and on every file state change. Closing the browser does not stop a run because
the work happens in the container. If the drive is removed during a copy, the
current temporary file is deleted, that item is marked interrupted, and the
remaining items are cancelled. No final-name half files are left behind.

### Configuration

Settings are not edited in the dashboard. The installer writes
`/etc/usbcopy/config.toml` inside the container (mode 0600, owner
`usbcopy:usbcopy`) and keeps the database at `/var/lib/usbcopy/usbcopy.db`. The
About page shows the loaded paths and log commands. If you change the config,
restart the app and keep the file private because it contains the password hash
and session secret.

### Update notifications

The dashboard checks the GitHub repository for a newer version every 6 hours
(configurable under `[update]` in `config.toml`; the check only reads a small
`VERSION` file and fails quietly when offline). When an update exists, a banner
appears at the top of every page with the installed and latest versions and a
**Copy update command** button. The dashboard runs inside the unprivileged CT,
so it cannot update itself: the button copies the one-line installer command
(`curl … | bash -s -- --update`) and you paste it into the Proxmox host shell.
The update keeps your config, password, and data.

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
- Destination folders must be on a filesystem that supports hard links,
  chmod, and utime (ext4, XFS, Btrfs, or ZFS). FAT and exFAT destinations are
  not supported.
- Every run and attempted file is stored in a SQLite history that persists while
  the app is installed, including after a drive removal or restart. Identical
  and conflict files are preview-only and are not per-file run history.
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

From the repo folder:

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

`sudo ./setup/install.sh --uninstall` forwards to the same script if you prefer
using the installer entry point; add `--destroy-ct` to remove the CT as well.

The installer uses `/etc/usbcopy/install-manifest.json` and refuses to
uninstall without it. Backups of any host files it replaced are under
`/etc/usbcopy/backup/<timestamp>/`. After a completed install, reinstalling
requires a successful uninstall first. Because the default keeps the CT, a
later install creates a new CT; pass `--destroy-ct` during uninstall if you
want the old one removed.

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
