# Troubleshooting

This page covers the problems that are most likely during install, drive use,
copying, and uninstall. Run commands on the Proxmox host as root unless a step
says "inside the CT". Replace `<ct-id>`, `<device>`, `<ct-ip>`, and `<port>`
with your values. The CT ID is recorded in
`/etc/usbcopy/install-manifest.json`; `pct list` also shows it.

## First checks

```bash
pct list
python3 -m json.tool /etc/usbcopy/install-manifest.json
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,TRAN,MOUNTPOINT
journalctl -u 'usbcopy-mount@*' -b --no-pager
pct exec <ct-id> -- systemctl status usbcopy --no-pager
pct exec <ct-id> -- journalctl -u usbcopy -n 200 --no-pager
curl -fsS http://<ct-ip>:<port>/healthz
```

A healthy app returns `{"status":"ok"}`. The dashboard's About page also shows
the loaded database, spool, and mount paths, plus the log commands.

## Drive not detected

1. Confirm the host sees the drive and its filesystem:

   ```bash
   lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,TRAN,MOUNTPOINT
   sudo blkid /dev/<device>
   ```

   Look for `TRAN` = `usb` and a non-empty `FSTYPE`. A drive with no filesystem,
   or one presented by a dock as a non-USB transport, will not match the udev
   rule.

2. Replug the drive while watching udev:

   ```bash
   udevadm monitor --udev
   ```

   Then check the mount unit for the device name, for example `sda1`:

   ```bash
   systemctl status 'usbcopy-mount@<device>.service' --no-pager
   journalctl -u 'usbcopy-mount@<device>.service' -b --no-pager
   ```

3. Check that the drive is mounted under the ingest root:

   ```bash
   findmnt -R /srv/usb-ingest
   ls -la /srv/usb-ingest/
   ```

   The mount script refuses to take over a device that is mounted outside
   `/srv/usb-ingest`. If another service mounted it, unmount that path when you
   are sure nothing else is using it, then replug the drive.

4. Check the udev rule and reload it if it is missing or was edited:

   ```bash
   ls -l /etc/udev/rules.d/99-usbcopy.rules
   udevadm control --reload-rules
   ```

   Replug afterwards. The rule only matches USB block devices with a
   filesystem.

5. For a drive that was connected while the host was off, run the boot-time
   scan again:

   ```bash
   systemctl start usbcopy-scan-usb.service
   journalctl -u usbcopy-scan-usb -b --no-pager
   ```

6. Check the event spool:

   ```bash
   ls -la /srv/usbcopy/events
   ```

   The host writes one JSON file per add/remove event. The app processes and
   deletes files it can apply. If files remain and the app is healthy, check the
   app log; malformed files are moved to `/srv/usbcopy/events/bad/`. Do not edit
   or delete event files unless you accept losing that notification; restarting
   the app processes pending files again, and the scan service can re-create
   notifications for mounted drives.

7. Check that the container sees the bind mount:

   ```bash
   pct exec <ct-id> -- findmnt -R /mnt/usb
   ```

8. If the host logs USB resets or I/O errors, try another cable or a direct
   USB port. Check the kernel log:

   ```bash
   dmesg -T | tail -50
   ```

## Unsupported filesystem

Supported types are ext2, ext3, ext4, vfat, exFAT, and NTFS. Other types (for
example APFS, HFS+, btrfs, or ZFS) are ignored and the mount unit logs
`unsupported filesystem`.

```bash
lsblk -f
blkid /dev/<device>
journalctl -u 'usbcopy-mount@<device>.service' -b --no-pager
```

For exFAT or NTFS, install the host helpers if they are missing:

```bash
apt-get update
apt-get install -y exfatprogs ntfs-3g
```

Test a read-only mount by hand. This does not write to the drive:

```bash
mkdir -p /mnt/usbcopy-test
mount -o ro -t exfat /dev/<device> /mnt/usbcopy-test
ls /mnt/usbcopy-test
umount /mnt/usbcopy-test
rmdir /mnt/usbcopy-test
```

Change `-t exfat` to `ntfs`, `vfat`, or `ext4` as appropriate. If the mount
fails, the filesystem may be damaged or need a repair tool. This project never
repairs or formats a drive. Back up the data elsewhere before reformatting;
reformatting erases the drive.

## Permission warnings

The app runs as the `usbcopy` user inside an unprivileged container. That user
maps to a host UID and GID of `100000 + container ID`. The installer prints the
mapped UID:GID and gives the destination roots and event spool to that
UID:GID. It never changes the source drive. If you no longer have the install
output, read the container IDs with `pct exec <ct-id> -- id usbcopy` and add
100000.

Check the container side:

```bash
pct exec <ct-id> -- id usbcopy
pct exec <ct-id> -- ls -ld /data/movies /data/series
```

Check the host side:

```bash
stat -c '%u:%g %a %n' /path/to/Movies /path/to/Series /srv/usbcopy/events
```

If copies fail with permission denied, fix the destination root ownership using
the mapped UID:GID printed by the installer. Change only the root, not every
existing file:

```bash
chown <mapped-uid>:<mapped-gid> /path/to/Movies
chmod u+rwx /path/to/Movies
```

Do not run `chown -R` unless you have reviewed the existing library ownership
and accept changing it. Existing files under the destination keep their
ownership by design.

If the event spool ownership is wrong, the app cannot read or delete events:

```bash
chown <mapped-uid>:<mapped-gid> /srv/usbcopy/events
chmod 0750 /srv/usbcopy/events
```

Do not chown or chmod the source drive or anything under `/srv/usb-ingest`. The
source is mounted read-only, and changing its permissions is not supported. If
files on the source are unreadable because of Unix permissions, the app records
a per-file error and continues; copy the files to a writable disk and fix
permissions there if needed.

The installer's "no USB drive is mounted at /mnt/usb yet" message is not an
error. It means the source read test was skipped because no drive was connected.

## Dashboard port conflict

The installer checks the port inside the new container, not on the host, because
the container has its own network namespace. If the requested port is busy, it
tries the next free port from 8088 to 8188. Use the URL printed at the end of
the install; the pre-install summary can still show the requested port.

To change the port after installation, edit the config inside the CT:

```bash
pct exec <ct-id> -- vi /etc/usbcopy/config.toml
pct exec <ct-id> -- systemctl restart usbcopy
pct exec <ct-id> -- systemctl status usbcopy --no-pager
```

Change `port` under `[server]`, then update bookmarks, any reverse proxy, and
any firewall rule you added yourself. Check that the port is free inside the
container:

```bash
pct exec <ct-id> -- ss -ltnp
```

The installer does not open host firewall ports. If you cannot find a free port
in the 8088-8188 range, stop the conflicting service in the container or
reinstall with a known-free port.

## Copy conflicts and skips

- **Skipped (identical)** means the destination already has a file with the
  same name, size, and modification time (within 2 seconds).
- **Conflict** means a file exists at the destination path but the size or
  modification time differs. The file is skipped and is never overwritten in
  v1.

To import the different version, move or rename the existing destination file
outside the app, or choose another destination, then create a new import. The
app has no retry button; a new run is the supported way to try again.

- **Failed** means the file could not be copied. Open the run detail in the
  dashboard to see the error. Common causes are a full destination, destination
  permissions, a source read error, or the drive being unplugged. The preflight
  requires selected size times 1.02 plus 256 MB free. Check space with:

  ```bash
  df -h /path/to/Movies /path/to/Series
  ```

- **Interrupted** means the drive was removed during the run. The current
  temporary file is deleted and the rest of the run is cancelled. Reconnect the
  drive and create a new import.

Temporary files are named `.usbcopy.<random>.part` and live in the target
directory. A failed item removes its temporary file, and the app removes
recorded temporary files at startup. If one remains and no run is active, do
not rename it to a final name; check the run history and start a new import.

## App service health

Check the HTTP health endpoint from the host:

```bash
curl -fsS http://<ct-ip>:<port>/healthz
```

Expected response: `{"status":"ok"}`.

A 503 response means the database is unavailable or the schema is not
initialised. Check the service and the data directory:

```bash
pct exec <ct-id> -- systemctl status usbcopy --no-pager
pct exec <ct-id> -- journalctl -u usbcopy -n 200 --no-pager
pct exec <ct-id> -- ls -la /var/lib/usbcopy
pct exec <ct-id> -- df -h
```

The `/var/lib/usbcopy` directory should be owned by `usbcopy:usbcopy`. If the
container is out of disk space, free space or grow the CT disk before
restarting.

Restart the app after a config change or a stuck process:

```bash
pct exec <ct-id> -- systemctl restart usbcopy
pct exec <ct-id> -- systemctl is-active usbcopy
```

If it still fails, read the first error in `journalctl -u usbcopy`. Config
errors name the file and section.

## Pending spool events and rollback

The host mount and unmount scripts write JSON event files into
`/srv/usbcopy/events`. The app processes them on startup and while running,
then deletes them. A file stays in place when the app is down or when applying
the event fails; malformed files are quarantined under
`/srv/usbcopy/events/bad/`.

```bash
ls -la /srv/usbcopy/events
ls -la /srv/usbcopy/events/bad 2>/dev/null
```

Restart the app to process pending files, or run the host scan to recreate
notifications for drives that are already mounted:

```bash
pct exec <ct-id> -- systemctl restart usbcopy
systemctl start usbcopy-scan-usb.service
```

The uninstaller warns and keeps pending event files instead of deleting them.

If an install fails, the installer asks `Roll back the partial install? [Y/n]`.
Yes (the default, and automatic with `--yes`) removes the CT created by that
run, the host files and units it added, and restores backups. Destination data
and pending spool events are kept. If you decline, the installer prints what it
left in place; the manifest may remain, and a later install will refuse to run
until you uninstall or repair it.

## Uninstall and reinstall

```bash
sudo ./setup/uninstall.sh --dry-run
sudo ./setup/uninstall.sh
```

The default removes the app, config, database, host units, udev rule, and bind
mounts, restores backups, and keeps the CT and destination files. Add
`--destroy-ct` to stop and destroy the CT as well, or `--yes` to skip the
confirmation.

- The manifest is `/etc/usbcopy/install-manifest.json`. Uninstall refuses to
  run without it. Use `USBC_MANIFEST_PATH` only if you moved the manifest.
- Host file backups are under `/etc/usbcopy/backup/<timestamp>/` and are
  restored during uninstall.
- If cleanup is incomplete, the script keeps the manifest and lists the
  incomplete steps. Fix the cause and run it again.
- A successful uninstall removes the manifest, so the installer can run again.
  Because the default keeps the CT, a reinstall creates a new CT; the old one
  remains. Use `--destroy-ct` if you want the old CT removed.
- The history database is inside the CT at `/var/lib/usbcopy/usbcopy.db`. Copy
  it out before uninstalling if you want to keep the history.
- For a piped install, re-run the installer with `--uninstall`; the temporary
  checkout is deleted after the install, so there is no local script to call.

## Log locations

There are no separate log files by default; everything goes to journald.

```bash
# Host: USB mount and boot scan units
journalctl -u 'usbcopy-mount@*' -b --no-pager
journalctl -u usbcopy-scan-usb -b --no-pager
journalctl -u 'usbcopy-mount@<device>.service' -f

# Container: the application
pct exec <ct-id> -- journalctl -u usbcopy -n 200 --no-pager
pct exec <ct-id> -- journalctl -u usbcopy -f

# Kernel: USB resets, I/O errors, and disconnects
dmesg -T | tail -50
```

Paths that are useful when reading logs:

- Host USB mounts: `/srv/usb-ingest/<uuid>`
- Host event spool: `/srv/usbcopy/events`
- Container config: `/etc/usbcopy/config.toml`
- Container database: `/var/lib/usbcopy/usbcopy.db`
- Container app: `/opt/usbcopy`
- Install manifest and backups: `/etc/usbcopy/`
