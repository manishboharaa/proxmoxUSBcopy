#!/usr/bin/env bash
# Host-side tests for proxmoxUSBcopy.
#
# Everything runs with --dry-run against temp directories and fake devices.
# The suite never mounts, unmounts, or writes to real host paths.
set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd -- "$REPO_ROOT"

HOST_SCRIPTS="$REPO_ROOT/setup/host"
MOUNT="$HOST_SCRIPTS/mount-usb.sh"
UNMOUNT="$HOST_SCRIPTS/unmount-usb.sh"
SCAN="$HOST_SCRIPTS/scan-usb.sh"
UNITS="$HOST_SCRIPTS/usbcopy-mount@.service"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/usbcopy-host-test.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    printf 'ok - %s\n' "$*"
}

assert_contains() {
    local needle=$1 haystack=$2 label=${3:-output}
    grep -qF -- "$needle" <<<"$haystack" || fail "$label does not contain: $needle"
}

assert_not_contains() {
    local needle=$1 haystack=$2 label=${3:-output}
    if grep -qF -- "$needle" <<<"$haystack"; then
        fail "$label unexpectedly contains: $needle"
    fi
}

json_last() {
    tail -n 1 <<<"$1"
}

assert_event_json() {
    local raw=$1 expected_action=$2 expected_uuid=$3
    if ! printf '%s\n' "$raw" | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
expected_keys = {
    "version", "action", "uuid", "label", "serial",
    "device", "mountpoint", "fs_type", "ts",
}
assert set(payload) == expected_keys, payload
assert payload["version"] == 1, payload
assert payload["action"] == sys.argv[1], payload
assert payload["uuid"] == sys.argv[2], payload
for key in ("device", "mountpoint", "fs_type", "ts"):
    value = payload[key]
    assert isinstance(value, str) and value, (key, payload)
for key in ("label", "serial"):
    value = payload[key]
    assert value is None or isinstance(value, str), (key, payload)
' "$expected_action" "$expected_uuid"; then
        fail "event JSON rejected: $raw"
    fi
}

assert_app_parses_event() {
    local raw=$1
    local python="$REPO_ROOT/app/.venv/bin/python"
    if [[ -x "$python" ]]; then
        printf '%s\n' "$raw" >"$WORK/event.json"
        if ! PYTHONPATH="$REPO_ROOT/app" "$python" -c '
import sys
from pathlib import Path

from usbcopy.events import parse_event

parse_event(Path(sys.argv[1]))
' "$WORK/event.json" >/dev/null; then
            fail "app parser rejected event JSON: $raw"
        fi
    fi
}

assert_field() {
    local raw=$1 key=$2 expected=$3
    if ! printf '%s\n' "$raw" | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
assert payload[sys.argv[1]] == sys.argv[2], payload
' "$key" "$expected"; then
        fail "event field $key is not $expected: $raw"
    fi
}

printf '== mount-usb.sh ==\n'
mnt_root="$WORK/mnt"
spool="$WORK/spool"

out=$("$MOUNT" --device /dev/fake1 --uuid TEST-1234 --fs-type exfat \
    --label MEDIA --serial SN1 --mount-root "$mnt_root" --spool "$spool" --dry-run)
assert_contains 'mount -o ro,nosuid,nodev,noexec,umask=022' "$out" 'exfat dry-run'
assert_contains "-t exfat -- /dev/fake1 $mnt_root/TEST-1234" "$out" 'exfat dry-run'
assert_contains '"action":"add"' "$out" 'exfat dry-run'
assert_contains '"uuid":"TEST-1234"' "$out" 'exfat dry-run'
assert_contains '"device":"/dev/fake1"' "$out" 'exfat dry-run'
assert_contains '"fs_type":"exfat"' "$out" 'exfat dry-run'

json=$(json_last "$out")
assert_event_json "$json" add TEST-1234
assert_field "$json" label MEDIA
assert_field "$json" serial SN1
assert_field "$json" mountpoint "$mnt_root/TEST-1234"
assert_app_parses_event "$json"
[[ ! -e "$mnt_root" ]] || fail "dry-run created the mount root"
[[ ! -e "$spool" ]] || fail "dry-run created the spool"
pass "exfat dry-run prints read-only mount command and valid add event"

out=$("$MOUNT" --device /dev/fake2 --uuid TEST-EXT4 --fs-type ext4 \
    --mount-root "$mnt_root" --spool "$spool" --dry-run)
assert_contains 'mount -o ro,nosuid,nodev,noexec -t ext4' "$out" 'ext4 dry-run'
assert_not_contains 'umask=' "$out" 'ext4 dry-run'
assert_event_json "$(json_last "$out")" add TEST-EXT4
pass "ext4 dry-run omits vfat/exfat/ntfs-only options"

for fs in vfat ntfs; do
    out=$("$MOUNT" --device /dev/fake3 --uuid "TEST-${fs}" --fs-type "$fs" \
        --mount-root "$mnt_root" --spool "$spool" --dry-run)
    assert_contains "mount -o ro,nosuid,nodev,noexec,umask=022 -t $fs " "$out" "$fs dry-run"
    assert_event_json "$(json_last "$out")" add "TEST-${fs}"
done
pass "vfat and ntfs dry-runs add umask"

if "$MOUNT" --device /dev/fake1 --uuid TEST-BAD --fs-type iso9660 \
    --mount-root "$mnt_root" --spool "$spool" --dry-run \
    >"$WORK/unsupported.out" 2>"$WORK/unsupported.err"; then
    fail "unsupported filesystem was accepted"
fi
grep -qi 'unsupported filesystem' "$WORK/unsupported.err" \
    || fail "unsupported filesystem error is not explanatory"
pass "unsupported filesystem is rejected"

for bad_uuid in '..' '.' 'BAD/UUID' 'bad uuid' 'x;y'; do
    if "$MOUNT" --device /dev/fake1 --uuid "$bad_uuid" --fs-type exfat \
        --mount-root "$mnt_root" --spool "$spool" --dry-run >/dev/null 2>&1; then
        fail "invalid uuid was accepted: $bad_uuid"
    fi
done
pass "unsafe UUID values are rejected"

for bad_device in 'sda1' '/dev/../etc/passwd' '/dev/sda1;id' '/dev/disk/by-uuid/x'; do
    if "$MOUNT" --device "$bad_device" --uuid TEST-1234 --fs-type exfat \
        --mount-root "$mnt_root" --spool "$spool" --dry-run >/dev/null 2>&1; then
        fail "invalid device was accepted: $bad_device"
    fi
done
if "$MOUNT" --uuid TEST-1234 --fs-type exfat --dry-run >/dev/null 2>&1; then
    fail "missing --device was accepted"
fi
pass "invalid device paths and missing arguments are rejected"

out=$("$MOUNT" --device /dev/fake1 --uuid TEST-EVIL --fs-type exfat \
    --label 'EVIL","action":"remove' --serial 'x","uuid":"pwn' \
    --mount-root "$mnt_root" --spool "$spool" --dry-run)
json=$(json_last "$out")
assert_event_json "$json" add TEST-EVIL
assert_field "$json" label 'EVIL","action":"remove'
assert_field "$json" serial 'x","uuid":"pwn'
pass "labels and serials cannot inject JSON fields"

printf '\n== unmount-usb.sh ==\n'
mountpoint="$mnt_root/TEST-1234"
out=$("$UNMOUNT" --mountpoint "$mountpoint" --spool "$spool" --dry-run)
assert_contains "umount -- $mountpoint" "$out" 'unmount dry-run'
json=$(json_last "$out")
assert_event_json "$json" remove TEST-1234
assert_field "$json" mountpoint "$mountpoint"
assert_app_parses_event "$json"
[[ ! -e "$mnt_root" ]] || fail "unmount dry-run created the mount root"
[[ ! -e "$spool" ]] || fail "unmount dry-run created the spool"
pass "unmount dry-run prints umount command and valid remove event"

for bad in 'relative/path' '/' '/srv/usb-ingest/..'; do
    if "$UNMOUNT" --mountpoint "$bad" --spool "$spool" --dry-run >/dev/null 2>&1; then
        fail "invalid mountpoint was accepted: $bad"
    fi
done
if "$UNMOUNT" --mountpoint "$mountpoint" --device /dev/fake1 --dry-run >/dev/null 2>&1; then
    fail "unmount accepted both --mountpoint and --device"
fi
if "$UNMOUNT" --spool "$spool" --dry-run >/dev/null 2>&1; then
    fail "unmount accepted no mountpoint or device"
fi
pass "invalid mountpoints are rejected"

out=$("$UNMOUNT" --device /dev/fake9 --mount-root "$mnt_root" --spool "$spool" --dry-run)
assert_contains "umount -- $mnt_root/fake9" "$out" 'device-mode dry-run'
assert_event_json "$(json_last "$out")" remove fake9
pass "device mode resolves a mountpoint without requiring a real device"

printf '\n== scan-usb.sh ==\n'
cat >"$WORK/lsblk.json" <<'JSON'
{
  "blockdevices": [
    {
      "name": "sda",
      "type": "disk",
      "fstype": null,
      "mountpoint": null,
      "tran": "usb",
      "children": [
        {"name": "sda1", "type": "part", "fstype": "exfat", "mountpoint": null, "tran": null},
        {"name": "sda2", "type": "part", "fstype": "ext4", "mountpoint": "/media/other", "tran": null},
        {"name": "sda3", "type": "part", "fstype": "iso9660", "mountpoint": null, "tran": null}
      ]
    },
    {
      "name": "sdb",
      "type": "disk",
      "fstype": "ntfs",
      "mountpoint": null,
      "tran": "usb",
      "children": []
    },
    {
      "name": "nvme0n1",
      "type": "disk",
      "fstype": "ext4",
      "mountpoint": "/",
      "tran": "nvme",
      "children": []
    }
  ]
}
JSON

out=$("$SCAN" --lsblk-json "$WORK/lsblk.json" --dry-run)
assert_contains 'systemctl start usbcopy-mount@sda1.service' "$out" 'scan dry-run'
assert_contains 'systemctl start usbcopy-mount@sdb.service' "$out" 'scan dry-run'
assert_not_contains 'sda2' "$out" 'scan dry-run'
assert_not_contains 'sda3' "$out" 'scan dry-run'
assert_not_contains 'nvme0n1' "$out" 'scan dry-run'
[[ $(grep -c '^systemctl start ' <<<"$out") -eq 2 ]] || fail "scan started wrong number of units"

out_again=$("$SCAN" --lsblk-json "$WORK/lsblk.json" --dry-run)
[[ $out == "$out_again" ]] || fail "repeated scan output is not identical"
pass "scan starts supported unmounted USB filesystems only and is idempotent"

printf '{"blockdevices": [}\n' >"$WORK/bad.json"
if "$SCAN" --lsblk-json "$WORK/bad.json" --dry-run >/dev/null 2>&1; then
    fail "malformed lsblk JSON was accepted"
fi
pass "malformed lsblk JSON is rejected"

printf '\n== unit and udev files ==\n'
[[ -f "$UNITS" ]] || fail "missing template unit"
grep -qF 'BindsTo=dev-%i.device' "$UNITS" || fail "template unit misses BindsTo"
grep -qF 'After=dev-%i.device' "$UNITS" || fail "template unit misses After"
grep -qF 'RemainAfterExit=yes' "$UNITS" || fail "template unit misses RemainAfterExit"
if grep -qF 'setup/host' "$UNITS"; then
    fail "template unit points at the repo instead of /usr/local/lib"
fi
grep -qF '/usr/local/lib/usbcopy/mount-usb.sh' "$UNITS" || fail "template unit misses mount script path"
grep -qF '/usr/local/lib/usbcopy/unmount-usb.sh' "$UNITS" || fail "template unit misses unmount script path"
grep -qF 'ExecStop=/usr/local/lib/usbcopy/unmount-usb.sh --device /dev/%i' "$UNITS" \
    || fail "template unit stop does not pass the device"
grep -qF 'ENV{SYSTEMD_WANTS}+="usbcopy-mount@%k.service"' "$HOST_SCRIPTS/99-usbcopy.rules" \
    || fail "udev rule misses SYSTEMD_WANTS"
grep -qF 'ENV{ID_BUS}=="usb"' "$HOST_SCRIPTS/99-usbcopy.rules" || fail "udev rule misses USB match"
pass "unit and udev rule contain the required wiring"

printf '\nAll host script tests passed.\n'
