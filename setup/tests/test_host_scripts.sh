#!/usr/bin/env bash
# Host-side tests for proxmoxUSBcopy.
#
# CLI paths run with --dry-run. Real-mode branches are tested with function
# stubs after sourcing the scripts, so no real mount or host path is touched.
# Stub functions are invoked indirectly by the sourced scripts.
# shellcheck disable=SC2317
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

STUB_LOG="$WORK/stub.log"

reset_stubs() {
    : >"$STUB_LOG"
    FAKE_TARGET=''
    FAKE_SOURCE=''
    FAKE_FSTYPE=''
    FAKE_MOUNTED=0
    FAKE_LS_FAIL=0
    UMOUNT_FAILS=0
    LAZY_RESULT=0
}

load_single_event() {
    local dir=$1
    local matches=()
    mapfile -t matches < <(find "$dir" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null || true)
    ((${#matches[@]} == 1))
}

run_mount_with_stubs() {
    (
        set -euo pipefail
        # shellcheck disable=SC1090
        source "$MOUNT"
        require_root() { :; }
        is_block_device() { return 0; }
        findmnt() {
            local joined="$*"
            if [[ $joined == *"--output TARGET --source"* ]]; then
                [[ -n ${FAKE_TARGET:-} ]] || return 1
                printf '%s\n' "$FAKE_TARGET"
                return 0
            fi
            if [[ $joined == *"--output SOURCE --mountpoint"* ]]; then
                [[ -n ${FAKE_SOURCE:-} ]] || return 1
                printf '%s\n' "$FAKE_SOURCE"
                return 0
            fi
            if [[ $joined == *"--output FSTYPE --mountpoint"* ]]; then
                [[ -n ${FAKE_FSTYPE:-} ]] || return 1
                printf '%s\n' "$FAKE_FSTYPE"
                return 0
            fi
            if [[ $joined == *"--mountpoint"* ]]; then
                [[ ${FAKE_MOUNTED:-0} == 1 ]]
                return
            fi
            return 1
        }
        mountpoint() { return 1; }
        mount() {
            printf 'mount %s\n' "$*" >>"$STUB_LOG"
            return 0
        }
        umount() {
            printf 'umount %s\n' "$*" >>"$STUB_LOG"
            return 0
        }
        blkid() { return 1; }
        udevadm() { return 1; }
        sleep() { :; }
        ls() {
            if [[ ${FAKE_LS_FAIL:-0} == 1 ]]; then
                return 1
            fi
            command ls "$@"
        }
        main "$@"
    )
}

run_unmount_with_stubs() {
    (
        set -euo pipefail
        # shellcheck disable=SC1090
        source "$UNMOUNT"
        require_root() { :; }
        findmnt() {
            local joined="$*"
            if [[ $joined == *"--output TARGET --source"* ]]; then
                [[ -n ${FAKE_TARGET:-} ]] || return 1
                printf '%s\n' "$FAKE_TARGET"
                return 0
            fi
            if [[ $joined == *"--output SOURCE --mountpoint"* ]]; then
                [[ -n ${FAKE_SOURCE:-} ]] || return 1
                printf '%s\n' "$FAKE_SOURCE"
                return 0
            fi
            if [[ $joined == *"--output FSTYPE --mountpoint"* ]]; then
                [[ -n ${FAKE_FSTYPE:-} ]] || return 1
                printf '%s\n' "$FAKE_FSTYPE"
                return 0
            fi
            if [[ $joined == *"--mountpoint"* ]]; then
                [[ ${FAKE_MOUNTED:-0} == 1 ]]
                return
            fi
            return 1
        }
        umount() {
            printf 'umount %s\n' "$*" >>"$STUB_LOG"
            if [[ ${1:-} == -l ]]; then
                [[ ${LAZY_RESULT:-0} == 0 ]]
                return
            fi
            local count
            count=$(grep -c '^umount ' "$STUB_LOG" || true)
            if ((count <= ${UMOUNT_FAILS:-0})); then
                return 1
            fi
            return 0
        }
        blkid() { return 1; }
        udevadm() { return 1; }
        sleep() { :; }
        main "$@"
    )
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

reset_stubs
state_ok="$WORK/state-ok"
mnt_state_ok="$WORK/mnt-state-ok"
spool_state_ok="$WORK/spool-state-ok"
out=$(run_mount_with_stubs --device /dev/fake1 --uuid TEST-STATE --fs-type ext4 \
    --label L --serial S --mount-root "$mnt_state_ok" --spool "$spool_state_ok" \
    --state-dir "$state_ok")
[[ -f "$state_ok/fake1" ]] || fail "state file was not written under --state-dir"
state_value=$(<"$state_ok/fake1")
[[ $state_value == "$mnt_state_ok/TEST-STATE" ]] || fail "state file has wrong mountpoint: $state_value"
assert_event_json "$(json_last "$out")" add TEST-STATE
assert_contains 'mount -o ro,nosuid,nodev,noexec -t ext4' "$(<"$STUB_LOG")" 'stub log'
pass "fresh mount writes state under --state-dir and emits add"

reset_stubs
blocker="$WORK/state-blocker"
printf 'not a directory\n' >"$blocker"
mnt_state_bad="$WORK/mnt-state-bad"
spool_state_bad="$WORK/spool-state-bad"
if run_mount_with_stubs --device /dev/fake1 --uuid TEST-STATE --fs-type ext4 \
    --label L --serial S --mount-root "$mnt_state_bad" --spool "$spool_state_bad" \
    --state-dir "$blocker/mounts" >/dev/null 2>&1; then
    fail "mount succeeded even though the state file could not be written"
fi
if load_single_event "$spool_state_bad"; then
    fail "add event was written despite a state-write failure"
fi
grep -q '^umount ' "$STUB_LOG" || fail "state-write failure did not unmount the fresh mount"
[[ ! -e "$mnt_state_bad/TEST-STATE" ]] || fail "state-write failure left the mountpoint behind"
[[ ! -e "$blocker/mounts" ]] || fail "state-write failure created a state directory"
pass "state-write failure unmounts and refuses to publish an add event"

reset_stubs
mnt_fast="$WORK/mnt-fast"
FAKE_TARGET="$mnt_fast/TEST-FAST"
FAKE_SOURCE=/dev/fake1
FAKE_FSTYPE=ext4
mkdir -p "$FAKE_TARGET"
spool_fast="$WORK/spool-fast"
state_fast="$WORK/state-fast"
out=$(run_mount_with_stubs --device /dev/fake1 --uuid TEST-FAST --fs-type ext4 \
    --label L --serial S --mount-root "$mnt_fast" --spool "$spool_fast" \
    --state-dir "$state_fast")
assert_event_json "$(json_last "$out")" add TEST-FAST
if grep -q '^mount ' "$STUB_LOG"; then
    fail "validated existing mount was remounted unnecessarily"
fi
if grep -q '^umount ' "$STUB_LOG"; then
    fail "validated existing mount was unmounted unnecessarily"
fi
[[ -f "$state_fast/fake1" ]] || fail "validated existing mount did not write state"
pass "already-mounted fast path validates and still emits an add event"

reset_stubs
mnt_dead="$WORK/mnt-dead"
FAKE_TARGET="$mnt_dead/TEST-DEAD"
FAKE_SOURCE=/dev/fake1
FAKE_FSTYPE=ext4
FAKE_LS_FAIL=1
mkdir -p "$FAKE_TARGET"
spool_dead="$WORK/spool-dead"
state_dead="$WORK/state-dead"
out=$(run_mount_with_stubs --device /dev/fake1 --uuid TEST-DEAD --fs-type ext4 \
    --label L --serial S --mount-root "$mnt_dead" --spool "$spool_dead" \
    --state-dir "$state_dead")
assert_event_json "$(json_last "$out")" add TEST-DEAD
grep -q '^umount ' "$STUB_LOG" || fail "unreadable existing mount was not unmounted"
grep -q '^mount ' "$STUB_LOG" || fail "unreadable existing mount was not replaced"
pass "existing mount with matching findmnt fields but failed reads is replaced"

reset_stubs
mnt_stale="$WORK/mnt-stale"
FAKE_TARGET="$mnt_stale/OLD-UUID"
FAKE_SOURCE=/dev/fake1
FAKE_FSTYPE=ext4
mkdir -p "$FAKE_TARGET"
spool_stale="$WORK/spool-stale"
state_stale="$WORK/state-stale"
out=$(run_mount_with_stubs --device /dev/fake1 --uuid TEST-NEW --fs-type ext4 \
    --label L --serial S --mount-root "$mnt_stale" --spool "$spool_stale" \
    --state-dir "$state_stale")
assert_event_json "$(json_last "$out")" add TEST-NEW
grep -q '^umount ' "$STUB_LOG" || fail "stale mount was not unmounted"
grep -q '^mount ' "$STUB_LOG" || fail "stale mount was not replaced"
[[ ! -e "$FAKE_TARGET" ]] || fail "stale mountpoint directory was not removed"
[[ -d "$mnt_stale/TEST-NEW" ]] || fail "new mountpoint was not created"
pass "stale mount at another UUID path is replaced and add is emitted"

reset_stubs
mnt_wrong="$WORK/mnt-wrong"
FAKE_TARGET="$mnt_wrong/TEST-WRONG"
FAKE_SOURCE=/dev/other
FAKE_FSTYPE=ext4
mkdir -p "$FAKE_TARGET"
spool_wrong="$WORK/spool-wrong"
state_wrong="$WORK/state-wrong"
out=$(run_mount_with_stubs --device /dev/fake1 --uuid TEST-WRONG --fs-type ext4 \
    --label L --serial S --mount-root "$mnt_wrong" --spool "$spool_wrong" \
    --state-dir "$state_wrong")
assert_event_json "$(json_last "$out")" add TEST-WRONG
grep -q '^umount ' "$STUB_LOG" || fail "mount with wrong source device was not unmounted"
grep -q '^mount ' "$STUB_LOG" || fail "mount with wrong source device was not replaced"
pass "mount at the right path but wrong source device is replaced"

reset_stubs
mnt_fs="$WORK/mnt-fs"
FAKE_TARGET="$mnt_fs/TEST-FS"
FAKE_SOURCE=/dev/fake1
FAKE_FSTYPE=vfat
mkdir -p "$FAKE_TARGET"
spool_fs="$WORK/spool-fs"
state_fs="$WORK/state-fs"
out=$(run_mount_with_stubs --device /dev/fake1 --uuid TEST-FS --fs-type ext4 \
    --label L --serial S --mount-root "$mnt_fs" --spool "$spool_fs" \
    --state-dir "$state_fs")
assert_event_json "$(json_last "$out")" add TEST-FS
grep -q '^umount ' "$STUB_LOG" || fail "mount with wrong filesystem was not unmounted"
grep -q '^mount ' "$STUB_LOG" || fail "mount with wrong filesystem was not replaced"
pass "mount with a different filesystem type is replaced"

printf '\n== unmount-usb.sh ==\n'

mountpoint="$mnt_root/TEST-1234"
out=$("$UNMOUNT" --mountpoint "$mountpoint" --mount-root "$mnt_root" --spool "$spool" --dry-run)
assert_contains "umount -- $mountpoint" "$out" 'unmount dry-run'
json=$(json_last "$out")
assert_event_json "$json" remove TEST-1234
assert_field "$json" mountpoint "$mountpoint"
assert_app_parses_event "$json"
[[ ! -e "$mnt_root" ]] || fail "unmount dry-run created the mount root"
[[ ! -e "$spool" ]] || fail "unmount dry-run created the spool"
pass "unmount dry-run prints umount command and valid remove event"

for bad in 'relative/path' '/' '/srv/usb-ingest/..' "$WORK/outside/TEST-1234"; do
    if "$UNMOUNT" --mountpoint "$bad" --mount-root "$mnt_root" \
        --spool "$spool" --dry-run >/dev/null 2>&1; then
        fail "invalid mountpoint was accepted: $bad"
    fi
done
if "$UNMOUNT" --mountpoint "$mountpoint" --device /dev/fake1 \
    --mount-root "$mnt_root" --dry-run >/dev/null 2>&1; then
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

reset_stubs
umnt_live="$WORK/umnt-live"
um_state_live="$WORK/um-state-live"
um_spool_live="$WORK/um-spool-live"
mkdir -p "$umnt_live/LIVE-UUID" "$um_state_live"
printf '%s\n' "$umnt_live/LIVE-UUID" >"$um_state_live/fake1"
FAKE_MOUNTED=1
FAKE_SOURCE=/dev/fake1
FAKE_FSTYPE=exfat
out=$(run_unmount_with_stubs --device /dev/fake1 --mount-root "$umnt_live" \
    --state-dir "$um_state_live" --spool "$um_spool_live")
assert_event_json "$(json_last "$out")" remove LIVE-UUID
assert_field "$(json_last "$out")" mountpoint "$umnt_live/LIVE-UUID"
[[ ! -e "$um_state_live/fake1" ]] || fail "live state file was not removed"
[[ ! -e "$umnt_live/LIVE-UUID" ]] || fail "live mountpoint directory was not removed"
[[ $(grep -c '^umount -- ' "$STUB_LOG" || true) -eq 1 ]] || fail "live state did not cause one unmount"
pass "device mode resolves a live state mountpoint, removes the live state file, and emits remove"

reset_stubs
umnt_stale="$WORK/umnt-stale"
um_state_stale="$WORK/um-state-stale"
um_spool_stale="$WORK/um-spool-stale"
mkdir -p "$umnt_stale/STALE-UUID" "$um_state_stale"
printf '%s\n' "$umnt_stale/STALE-UUID" >"$um_state_stale/fake1"
FAKE_MOUNTED=0
out=$(run_unmount_with_stubs --device /dev/fake1 --mount-root "$umnt_stale" \
    --state-dir "$um_state_stale" --spool "$um_spool_stale")
assert_event_json "$(json_last "$out")" remove STALE-UUID
[[ ! -e "$um_state_stale/fake1" ]] || fail "stale state file was not removed"
[[ ! -e "$umnt_stale/STALE-UUID" ]] || fail "stale mountpoint directory was not removed"
if grep -q '^umount ' "$STUB_LOG"; then
    fail "stale state triggered an unmount of a non-mounted path"
fi
pass "stale state entry still emits remove and is cleaned up"

reset_stubs
umnt_retry="$WORK/umnt-retry"
um_state_retry="$WORK/um-state-retry"
um_spool_retry="$WORK/um-spool-retry"
mkdir -p "$umnt_retry/RETRY-UUID" "$um_state_retry"
printf '%s\n' "$umnt_retry/RETRY-UUID" >"$um_state_retry/fake1"
FAKE_MOUNTED=1
FAKE_SOURCE=/dev/fake1
FAKE_FSTYPE=exfat
UMOUNT_FAILS=3
LAZY_RESULT=0
out=$(run_unmount_with_stubs --device /dev/fake1 --mount-root "$umnt_retry" \
    --state-dir "$um_state_retry" --spool "$um_spool_retry")
assert_event_json "$(json_last "$out")" remove RETRY-UUID
[[ $(grep -c '^umount -- ' "$STUB_LOG" || true) -eq 3 ]] || fail "busy mount did not retry three times"
[[ $(grep -c '^umount -l ' "$STUB_LOG" || true) -eq 1 ]] || fail "busy mount did not fall back to lazy unmount"
[[ ! -e "$um_state_retry/fake1" ]] || fail "retry/lazy success did not clear state"
[[ ! -e "$umnt_retry/RETRY-UUID" ]] || fail "retry/lazy success did not remove mountpoint"
pass "busy unmount retries, falls back to lazy unmount, then emits remove"

reset_stubs
umnt_stuck="$WORK/umnt-stuck"
um_state_stuck="$WORK/um-state-stuck"
um_spool_stuck="$WORK/um-spool-stuck"
mkdir -p "$umnt_stuck/STUCK-UUID" "$um_state_stuck"
printf '%s\n' "$umnt_stuck/STUCK-UUID" >"$um_state_stuck/fake1"
FAKE_MOUNTED=1
FAKE_SOURCE=/dev/fake1
FAKE_FSTYPE=exfat
UMOUNT_FAILS=3
LAZY_RESULT=1
out=$(run_unmount_with_stubs --device /dev/fake1 --mount-root "$umnt_stuck" \
    --state-dir "$um_state_stuck" --spool "$um_spool_stuck")
assert_event_json "$(json_last "$out")" remove STUCK-UUID
[[ -e "$um_state_stuck/fake1" ]] || fail "unreleased mount did not keep its state file"
[[ -e "$umnt_stuck/STUCK-UUID" ]] || fail "unreleased mount removed its mountpoint directory"
pass "remove event is emitted and state is kept when the mount cannot be released"

reset_stubs
outside_root="$WORK/outside-root"
um_state_outside="$WORK/um-state-outside"
um_spool_outside="$WORK/um-spool-outside"
mkdir -p "$outside_root/OUTSIDE-UUID" "$um_state_outside"
printf '%s\n' "$outside_root/OUTSIDE-UUID" >"$um_state_outside/fake1"
if run_unmount_with_stubs --device /dev/fake1 --mount-root "$WORK/umnt-root-only" \
    --state-dir "$um_state_outside" --spool "$um_spool_outside" >/dev/null 2>&1; then
    fail "state pointing outside the mount root was accepted"
fi
if load_single_event "$um_spool_outside"; then
    fail "outside-root state wrote a remove event"
fi
[[ -e "$um_state_outside/fake1" ]] || fail "outside-root state was removed"
pass "state mountpoints outside the configured mount root are rejected"

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
