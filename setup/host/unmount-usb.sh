#!/usr/bin/env bash
# proxmoxUSBcopy: unmount one USB mountpoint and emit a spool remove event.
#
# This script runs as root on the Proxmox host, normally from the ExecStop=
# of the usbcopy-mount@.service template unit.
set -euo pipefail

PROG=${0##*/}
DEFAULT_MOUNT_ROOT=/srv/usb-ingest
DEFAULT_SPOOL=/srv/usbcopy/events
DEFAULT_STATE_DIR=/run/usbcopy/mounts

usage() {
    cat <<EOF
Usage: $PROG --mountpoint /srv/usb-ingest/<uuid>
       $PROG --device /dev/sda1

Unmount a proxmoxUSBcopy mountpoint, remove the empty directory, and write
one remove event into the spool. --device lets the systemd stop job resolve
the UUID-based mountpoint even after the drive has disappeared.

Options:
  --mountpoint PATH    Mountpoint to unmount (mutually exclusive with --device)
  --device PATH        Block device whose mount should be removed
  --mount-root PATH    Mount root; resolved mountpoints must be below it
                       (default: $DEFAULT_MOUNT_ROOT)
  --ct-mount-root PATH Container-side mount root visible to the usbcopy app
                       (default: \$USBC_CT_MOUNT_ROOT or --mount-root)
  --spool PATH         Event spool (default: $DEFAULT_SPOOL)
  --state-dir PATH     Mount state directory (default: $DEFAULT_STATE_DIR)
  --dry-run            Print the umount command and event JSON only
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

validate_absolute_path() {
    local value=$1
    local name=$2
    [[ -n $value ]] || die "$name must not be empty"
    [[ $value == /* ]] || die "$name must be an absolute path: $value"
    [[ $value != *'..'* ]] || die "$name must not contain '..': $value"
    [[ $value != *$'\n'* ]] || die "$name must not contain a newline"
}

require_mountpoint_under_root() {
    local path=$1
    local root=${mount_root%/}
    [[ $path == "$root"/* ]] || die "mountpoint is outside mount root $root: $path"
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
    local ct_root=${ct_mount_root:-$mount_root}
    local ct_mountpoint
    if [[ $ct_root == "${mount_root%/}" ]]; then
        ct_mountpoint=$mountpoint
    else
        ct_mountpoint="${ct_root%/}/${mountpoint##*/}"
    fi
    USBC_ACTION="$action" \
        USBC_UUID="$uuid" \
        USBC_LABEL="$label" \
        USBC_SERIAL="$serial" \
        USBC_DEVICE="$device" \
        USBC_MOUNTPOINT="$mountpoint" \
        USBC_CT_MOUNTPOINT="$ct_mountpoint" \
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
    "ct_mountpoint": os.environ["USBC_CT_MOUNTPOINT"],
    "fs_type": os.environ["USBC_FS_TYPE"],
    "ts": os.environ["USBC_TS"],
}
print(json.dumps(payload, separators=(",", ":")))
PY
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

main() {
    local mountpoint=''
    local device_arg=''
    local mount_root=$DEFAULT_MOUNT_ROOT
    local ct_mount_root=${USBC_CT_MOUNT_ROOT:-}
    local spool=$DEFAULT_SPOOL
    local state_dir=$DEFAULT_STATE_DIR
    local dry_run=0
    local device=''
    local assumed_mountpoint=0
    local state_file=''
    local state_value=''
    local targets=()
    local selected=''
    local candidate=''
    local derived_uuid=''
    local uuid_values=()
    local sources=()
    local filesystems=()
    local fs_type=''
    local label=''
    local serial=''
    local mounted=0
    local block_info=''
    local dev_properties=''
    local device_unknown=0
    local released=1

    while (($# > 0)); do
        case "$1" in
            --mountpoint)
                (($# >= 2)) || die "--mountpoint requires a value"
                mountpoint=$2
                shift 2
                ;;
            --device)
                (($# >= 2)) || die "--device requires a value"
                device_arg=$2
                shift 2
                ;;
            --mount-root)
                (($# >= 2)) || die "--mount-root requires a value"
                mount_root=$2
                shift 2
                ;;
            --ct-mount-root)
                (($# >= 2)) || die "--ct-mount-root requires a value"
                ct_mount_root=$2
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

    validate_absolute_path "$mount_root" "--mount-root"
    if [[ -n $ct_mount_root ]]; then
        validate_absolute_path "$ct_mount_root" "--ct-mount-root"
    fi
    validate_absolute_path "$spool" "--spool"
    validate_absolute_path "$state_dir" "--state-dir"
    require_command python3

    if [[ -n $mountpoint && -n $device_arg ]]; then
        die "use either --mountpoint or --device, not both"
    elif [[ -n $mountpoint ]]; then
        validate_absolute_path "$mountpoint" "--mountpoint"
    elif [[ -n $device_arg ]]; then
        [[ $device_arg =~ ^/dev/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
            || die "invalid device path (expected a single /dev node): $device_arg"
        device=$device_arg
        state_file="$state_dir/${device##*/}"
        if [[ -r $state_file ]]; then
            state_value=''
            IFS= read -r state_value <"$state_file" || true
            if [[ -n $state_value ]]; then
                validate_absolute_path "$state_value" "state file $state_file"
                mountpoint=$state_value
            else
                log "warning: ignoring empty mount state: $state_file"
            fi
        fi
        if [[ -z $mountpoint ]] && command -v findmnt >/dev/null 2>&1; then
            targets=()
            mapfile -t targets < <(
                findmnt --noheadings --output TARGET --source "$device" 2>/dev/null || true
            )
            selected=''
            for candidate in "${targets[@]}"; do
                if [[ $candidate == "${mount_root%/}/"* ]]; then
                    selected=$candidate
                    break
                fi
            done
            if [[ -z $selected && ${#targets[@]} -gt 0 ]]; then
                die "device $device is mounted outside mount root at: ${targets[*]}"
            fi
            mountpoint=$selected
        fi
        if [[ -z $mountpoint ]] && command -v blkid >/dev/null 2>&1; then
            uuid_values=()
            mapfile -t uuid_values < <(
                blkid -s UUID -o value -- "$device" 2>/dev/null || true
            )
            derived_uuid=${uuid_values[0]:-}
            if [[ $derived_uuid != '.' && $derived_uuid != '..' ]] \
                && [[ $derived_uuid =~ ^[A-Za-z0-9._-]+$ ]]; then
                mountpoint="${mount_root%/}/$derived_uuid"
            fi
        fi
        if [[ -z $mountpoint ]]; then
            mountpoint="${mount_root%/}/${device##*/}"
            assumed_mountpoint=1
        fi
    else
        die "one of --mountpoint or --device is required"
    fi

    validate_absolute_path "$mountpoint" "--mountpoint"
    while [[ $mountpoint == */ && $mountpoint != / ]]; do
        mountpoint=${mountpoint%/}
    done
    [[ $mountpoint != / ]] || die "refusing to unmount /"
    require_mountpoint_under_root "$mountpoint"
    uuid=${mountpoint##*/}
    validate_uuid "$uuid"

    if command -v findmnt >/dev/null 2>&1 \
        && findmnt --mountpoint "$mountpoint" >/dev/null 2>&1; then
        mounted=1
        sources=()
        mapfile -t sources < <(
            findmnt --noheadings --output SOURCE --mountpoint "$mountpoint" 2>/dev/null || true
        )
        if [[ -n ${sources[0]:-} ]]; then
            device=${sources[0]}
        fi
        filesystems=()
        mapfile -t filesystems < <(
            findmnt --noheadings --output FSTYPE --mountpoint "$mountpoint" 2>/dev/null || true
        )
        if [[ -n ${filesystems[0]:-} ]]; then
            fs_type=${filesystems[0]}
        fi
    fi

    if [[ -z $device && -e /dev/disk/by-uuid/$uuid ]]; then
        device=$(readlink -f -- "/dev/disk/by-uuid/$uuid" 2>/dev/null || true)
    fi

    if [[ -n $device ]] && command -v blkid >/dev/null 2>&1; then
        block_info=$(blkid -o export -- "$device" 2>/dev/null || true)
        while IFS='=' read -r key value; do
            case "$key" in
                LABEL)
                    label=$value
                    ;;
                TYPE)
                    if [[ -z $fs_type ]]; then
                        fs_type=$value
                    fi
                    ;;
            esac
        done <<<"$block_info"
    fi

    if [[ -z $serial && -n $device ]] && command -v udevadm >/dev/null 2>&1; then
        dev_properties=$(udevadm info --query=property --name="$device" 2>/dev/null || true)
        while IFS='=' read -r key value; do
            if [[ $key == ID_SERIAL_SHORT && -z $serial ]]; then
                serial=$value
            fi
        done <<<"$dev_properties"
    fi

    if [[ -z $fs_type ]]; then
        fs_type='unknown'
    fi
    if [[ -z $device ]]; then
        device='/dev/unknown'
        device_unknown=1
    fi
    if [[ -z $state_file && $device != /dev/unknown ]]; then
        state_file="$state_dir/${device##*/}"
    fi

    if ((dry_run == 1)); then
        timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        printf 'umount -- %s\n' "$mountpoint"
        event_json remove "$timestamp"
        exit 0
    fi

    require_root

    if ((device_unknown == 1)); then
        log "warning: cannot determine device for $mountpoint; writing remove event with $device"
    fi
    if ((assumed_mountpoint == 1)); then
        log "warning: cannot locate a mount for $device; assuming $mountpoint"
    fi

    if ((mounted == 1)); then
        if ! release_mount "$mountpoint"; then
            released=0
            log "warning: could not release $mountpoint; keeping state for cleanup"
        fi
    else
        log "$mountpoint is not mounted; continuing"
    fi

    if ((released == 1)) && [[ -d $mountpoint ]]; then
        if ! rmdir -- "$mountpoint" 2>/dev/null; then
            log "warning: mountpoint is not empty, leaving it in place: $mountpoint"
        fi
    fi

    if ! write_event remove; then
        die "could not write remove event to $spool"
    fi

    if ((released == 1)); then
        if [[ -n $state_file ]]; then
            rm -f -- "$state_file" 2>/dev/null || true
        fi
    elif [[ -n $state_file && -e $state_file ]]; then
        log "warning: keeping state file $state_file for cleanup"
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
