#!/usr/bin/env bash
# proxmoxUSBcopy: mount one USB block device read-only and emit a spool event.
#
# This script runs as root on the Proxmox host, normally from the
# usbcopy-mount@.service template unit. It never writes to the mounted
# filesystem: the mount options are fixed to ro,nosuid,nodev,noexec.
set -euo pipefail

PROG=${0##*/}
DEFAULT_MOUNT_ROOT=/srv/usb-ingest
DEFAULT_SPOOL=/srv/usbcopy/events
DEFAULT_STATE_DIR=/run/usbcopy/mounts
SUPPORTED_FS=(ext2 ext3 ext4 vfat exfat ntfs)

usage() {
    cat <<EOF
Usage: $PROG --device /dev/sda1 [options]

Mount a USB filesystem read-only and write one add event into the spool.

Options:
  --device PATH        Block device to mount (required, for example /dev/sda1)
  --uuid UUID          Drive uuid; derived with blkid when omitted
  --label LABEL        Filesystem label; derived with blkid when omitted
  --serial SERIAL      Drive serial; derived with udevadm when omitted
  --fs-type TYPE       ext2|ext3|ext4|vfat|exfat|ntfs; derived with blkid
  --mount-root PATH    Mount root (default: $DEFAULT_MOUNT_ROOT)
  --spool PATH         Event spool (default: $DEFAULT_SPOOL)
  --state-dir PATH     Mount state directory (default: $DEFAULT_STATE_DIR)
  --dry-run            Print the mount command and event JSON only
  -h, --help           Show this help
EOF
}

die() {
    printf '%s: %s\n' "$PROG" "$*" >&2
    exit 1
}

log() {
    printf '%s: %s\n' "$PROG" "$*" >&2
}

require_command() {
    local name=$1
    command -v "$name" >/dev/null 2>&1 || die "required command not found: $name"
}

require_root() {
    ((EUID == 0)) || die "must be run as root"
}

is_block_device() {
    [[ -b $1 ]]
}

validate_absolute_path() {
    local value=$1
    local name=$2
    [[ -n $value ]] || die "$name must not be empty"
    [[ $value == /* ]] || die "$name must be an absolute path: $value"
    [[ $value != *'..'* ]] || die "$name must not contain '..': $value"
    [[ $value != *$'\n'* ]] || die "$name must not contain a newline"
}

validate_uuid() {
    local value=$1
    [[ -n $value ]] || die "drive uuid is empty"
    [[ $value != '.' && $value != '..' ]] || die "invalid drive uuid: $value"
    [[ $value =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid drive uuid: $value"
    ((${#value} <= 128)) || die "drive uuid is too long: $value"
}

event_json() {
    local action=$1
    local timestamp=$2
    USBC_ACTION="$action" \
        USBC_UUID="$uuid" \
        USBC_LABEL="$label" \
        USBC_SERIAL="$serial" \
        USBC_DEVICE="$device" \
        USBC_MOUNTPOINT="$mountpoint" \
        USBC_FS_TYPE="$fs_type" \
        USBC_TS="$timestamp" \
        python3 - <<'PY'
import json
import os

payload = {
    "version": 1,
    "action": os.environ["USBC_ACTION"],
    "uuid": os.environ["USBC_UUID"],
    "label": os.environ["USBC_LABEL"] or None,
    "serial": os.environ["USBC_SERIAL"] or None,
    "device": os.environ["USBC_DEVICE"],
    "mountpoint": os.environ["USBC_MOUNTPOINT"],
    "fs_type": os.environ["USBC_FS_TYPE"],
    "ts": os.environ["USBC_TS"],
}
print(json.dumps(payload, separators=(",", ":")))
PY
}

write_state_once() {
    local tmp
    local final

    if [[ ! -d $state_dir ]]; then
        mkdir -p -- "$state_dir" || return 1
    fi
    tmp=$(mktemp "$state_dir/.state.XXXXXX") || return 1
    final="$state_dir/${device##*/}"
    if ! printf '%s\n' "$mountpoint" >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod 0644 -- "$tmp" || true
    if ! mv -f -- "$tmp" "$final"; then
        rm -f -- "$tmp"
        return 1
    fi
}

write_state() {
    local attempt

    for attempt in 1 2 3; do
        if write_state_once; then
            return 0
        fi
        if ((attempt < 3)); then
            log "state write attempt $attempt failed for $device; retrying"
            sleep 0.5 || true
        fi
    done
    return 1
}

write_event() {
    local action=$1
    local timestamp
    local compact
    local payload
    local tmp
    local final

    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    compact=$(date -u +%Y%m%dT%H%M%S%NZ)
    payload=$(event_json "$action" "$timestamp") || return 1

    if [[ ! -d $spool ]]; then
        mkdir -p -- "$spool" || return 1
        chmod 0750 -- "$spool" 2>/dev/null || true
        log "created spool $spool; installer should set its app ownership"
    fi

    tmp=$(mktemp "$spool/.event.XXXXXX") || return 1
    final="$spool/${compact}-${action}-${uuid}-$$.json"
    if ! printf '%s\n' "$payload" >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod 0644 -- "$tmp" || true
    if ! mv -f -- "$tmp" "$final"; then
        rm -f -- "$tmp"
        return 1
    fi
    printf '%s\n' "$payload"
}

release_mount() {
    local path=$1
    local attempt

    for attempt in 1 2 3; do
        if umount -- "$path" 2>/dev/null; then
            return 0
        fi
        log "unmount attempt $attempt failed for $path"
        if ((attempt < 3)); then
            sleep 1 || true
        fi
    done
    log "forcing lazy unmount of $path"
    if umount -l -- "$path" 2>/dev/null; then
        return 0
    fi
    log "lazy unmount failed for $path"
    return 1
}

mount_matches_device() {
    local target=$1
    local source=$2
    local fstype=$3
    local expected
    local actual

    [[ $target == "$mountpoint" ]] || return 1
    [[ ${fstype,,} == "$fs_type" ]] || return 1
    [[ -n $source ]] || return 1
    expected=$(readlink -f -- "$device" 2>/dev/null || printf '%s' "$device")
    actual=$(readlink -f -- "$source" 2>/dev/null || printf '%s' "$source")
    [[ $actual == "$expected" ]] || return 1
    [[ -d $mountpoint ]] && ls -- "$mountpoint" >/dev/null 2>&1
}

publish_add() {
    if ! write_state; then
        log "error: could not record mount state for $device; refusing to start"
        release_mount "$mountpoint" || log "warning: could not release $mountpoint"
        rmdir -- "$mountpoint" 2>/dev/null || true
        return 1
    fi
    if ! write_event add; then
        rm -f -- "$state_dir/${device##*/}"
        release_mount "$mountpoint" || log "warning: could not release $mountpoint"
        rmdir -- "$mountpoint" 2>/dev/null || true
        return 1
    fi
}

main() {
    local device=''
    local uuid=''
    local label=''
    local serial=''
    local fs_type=''
    local mount_root=$DEFAULT_MOUNT_ROOT
    local spool=$DEFAULT_SPOOL
    local state_dir=$DEFAULT_STATE_DIR
    local dry_run=0
    local have_label=0
    local have_serial=0
    local block_info=''
    local dev_properties=''
    local supported=0
    local candidate=''
    local existing_target=''
    local existing_source=''
    local existing_fs=''
    local targets=()
    local fields=()

    while (($# > 0)); do
        case "$1" in
            --device)
                (($# >= 2)) || die "--device requires a value"
                device=$2
                shift 2
                ;;
            --uuid)
                (($# >= 2)) || die "--uuid requires a value"
                uuid=$2
                shift 2
                ;;
            --label)
                (($# >= 2)) || die "--label requires a value"
                label=$2
                have_label=1
                shift 2
                ;;
            --serial)
                (($# >= 2)) || die "--serial requires a value"
                serial=$2
                have_serial=1
                shift 2
                ;;
            --fs-type)
                (($# >= 2)) || die "--fs-type requires a value"
                fs_type=$2
                shift 2
                ;;
            --mount-root)
                (($# >= 2)) || die "--mount-root requires a value"
                mount_root=$2
                shift 2
                ;;
            --spool)
                (($# >= 2)) || die "--spool requires a value"
                spool=$2
                shift 2
                ;;
            --state-dir)
                (($# >= 2)) || die "--state-dir requires a value"
                state_dir=$2
                shift 2
                ;;
            --dry-run)
                dry_run=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done

    [[ -n $device ]] || die "--device is required"
    [[ $device =~ ^/dev/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
        || die "invalid device path (expected a single /dev node): $device"
    validate_absolute_path "$mount_root" "--mount-root"
    validate_absolute_path "$spool" "--spool"
    validate_absolute_path "$state_dir" "--state-dir"
    require_command python3

    if [[ -z $uuid || -z $fs_type || $have_label -eq 0 ]]; then
        if command -v blkid >/dev/null 2>&1; then
            block_info=$(blkid -o export -- "$device" 2>/dev/null || true)
            while IFS='=' read -r key value; do
                case "$key" in
                    UUID)
                        if [[ -z $uuid ]]; then
                            uuid=$value
                        fi
                        ;;
                    LABEL)
                        if [[ $have_label -eq 0 ]]; then
                            label=$value
                        fi
                        ;;
                    TYPE)
                        if [[ -z $fs_type ]]; then
                            fs_type=$value
                        fi
                        ;;
                esac
            done <<<"$block_info"
        fi
    fi

    if [[ $have_serial -eq 0 && -z $serial ]] && command -v udevadm >/dev/null 2>&1; then
        dev_properties=$(udevadm info --query=property --name="$device" 2>/dev/null || true)
        while IFS='=' read -r key value; do
            if [[ $key == ID_SERIAL_SHORT && -z $serial ]]; then
                serial=$value
            fi
        done <<<"$dev_properties"
    fi

    [[ -n $fs_type ]] || die "cannot determine filesystem type for $device; pass --fs-type"
    fs_type=${fs_type,,}

    for candidate in "${SUPPORTED_FS[@]}"; do
        if [[ $fs_type == "$candidate" ]]; then
            supported=1
        fi
    done
    ((supported == 1)) \
        || die "unsupported filesystem on $device: $fs_type (supported: ${SUPPORTED_FS[*]})"

    if [[ -z $uuid ]]; then
        uuid=${device##*/}
    fi
    validate_uuid "$uuid"

    mountpoint="${mount_root%/}/$uuid"
    options='ro,nosuid,nodev,noexec'
    case "$fs_type" in
        exfat | vfat | ntfs)
            options+=',umask=022'
            ;;
    esac

    if ((dry_run == 1)); then
        timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        printf 'mount -o %s -t %s -- %s %s\n' "$options" "$fs_type" "$device" "$mountpoint"
        event_json add "$timestamp"
        exit 0
    fi

    require_root
    require_command findmnt
    is_block_device "$device" || die "not a block device: $device"

    targets=()
    mapfile -t targets < <(
        findmnt --noheadings --output TARGET --source "$device" 2>/dev/null || true
    )
    if ((${#targets[@]} > 0)); then
        existing_target=''
        for candidate in "${targets[@]}"; do
            if [[ $candidate == "$mountpoint" ]]; then
                existing_target=$candidate
                break
            fi
        done
        if [[ -z $existing_target ]]; then
            existing_target=${targets[0]}
        fi

        fields=()
        mapfile -t fields < <(
            findmnt --noheadings --output SOURCE --mountpoint "$existing_target" 2>/dev/null || true
        )
        existing_source=${fields[0]:-}
        fields=()
        mapfile -t fields < <(
            findmnt --noheadings --output FSTYPE --mountpoint "$existing_target" 2>/dev/null || true
        )
        existing_fs=${fields[0]:-}

        if mount_matches_device "$existing_target" "$existing_source" "$existing_fs"; then
            log "validated existing mount of $device at $mountpoint"
            if ! publish_add; then
                die "could not publish add event for existing mount at $mountpoint"
            fi
            exit 0
        fi

        if [[ $existing_target != "$mountpoint" \
            && $existing_target != "${mount_root%/}/"* ]]; then
            die "device $device is mounted outside mount root at $existing_target"
        fi

        log "stale mount for $device at $existing_target; unmounting and remounting"
        if ! release_mount "$existing_target"; then
            die "could not release stale mount at $existing_target"
        fi
        if [[ $existing_target != "$mountpoint" ]]; then
            rmdir -- "$existing_target" 2>/dev/null \
                || log "warning: stale mountpoint is not empty: $existing_target"
        fi
    fi

    if command -v mountpoint >/dev/null 2>&1 && mountpoint -q -- "$mountpoint"; then
        die "mountpoint is already in use: $mountpoint"
    fi

    mkdir -p -- "$mount_root"
    mkdir -p -- "$mountpoint"

    rm -f -- "$state_dir/${device##*/}" 2>/dev/null || true

    if ! mount -o "$options" -t "$fs_type" -- "$device" "$mountpoint"; then
        rmdir -- "$mountpoint" 2>/dev/null || true
        die "mount failed: $device on $mountpoint"
    fi

    if ! publish_add; then
        die "could not publish add event for $device at $mountpoint"
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
