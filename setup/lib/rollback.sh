#!/usr/bin/env bash
# Automatic rollback and manifest-driven uninstall helpers.
#
# setup/install.sh sources this file and arms an ERR trap after the operator
# confirms a real install. setup/uninstall.sh sources it and drives the same
# bounded cleanup from the install manifest.
#
# Safety rules:
#   - Only paths, units, mounts and files recorded by the installer are
#     touched. Pre-existing directories and destination contents are never
#     removed.
#   - A container is destroyed only when this install run created it (rollback)
#     or the operator passed --destroy-ct (uninstall).
#   - Every removal is best-effort: failures are collected, reported, and turn
#     into a non-zero exit at the end.
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2153

RB_CT_ID=''
RB_CT_CREATED=0
RB_HOST_FILES=()
RB_CONTAINER_FILES=()
RB_HOST_DIRS=()
RB_PREEXISTING_DIRS=()
RB_CONTAINER_DIRS=()
RB_HOST_UNITS=()
RB_CONTAINER_UNITS=()
RB_UDEV=()
RB_BACKUPS=()
RB_MOUNTS=()
RB_HOST_MOUNTS=()
RB_DEST_HOSTS=()
RB_FAILURES=0

rb_note_failure() {
    warn "cleanup: $*"
    RB_FAILURES=$((RB_FAILURES + 1))
}

rb_copy_array() {
    local source_name=$1
    local target_name=$2
    local -n source_ref=$source_name
    local -n target_ref=$target_name

    target_ref=()
    if ((${#source_ref[@]} > 0)); then
        target_ref=("${source_ref[@]}")
    fi
}

# Load the installer's in-memory records (the manifest may not exist yet when
# a stage fails).
rb_collect_globals() {
    RB_CT_ID=${CT_ID:-}
    RB_CT_CREATED=${CT_CREATED:-0}
    RB_DEST_HOSTS=()
    if [[ -n ${DEST_MOVIES:-} ]]; then
        RB_DEST_HOSTS+=("$DEST_MOVIES")
    fi
    if [[ -n ${DEST_SERIES:-} ]]; then
        RB_DEST_HOSTS+=("$DEST_SERIES")
    fi
    if [[ -n ${DEST_EXTRA:-} ]]; then
        RB_DEST_HOSTS+=("$DEST_EXTRA")
    fi
    if declare -p USBC_INSTALLED_FILES >/dev/null 2>&1; then
        rb_copy_array USBC_INSTALLED_FILES RB_HOST_FILES
    fi
    if declare -p USBC_CONTAINER_FILES >/dev/null 2>&1; then
        rb_copy_array USBC_CONTAINER_FILES RB_CONTAINER_FILES
    fi
    if declare -p USBC_CREATED_DIRS >/dev/null 2>&1; then
        rb_copy_array USBC_CREATED_DIRS RB_HOST_DIRS
    fi
    if declare -p USBC_PREEXISTING_DIRS >/dev/null 2>&1; then
        rb_copy_array USBC_PREEXISTING_DIRS RB_PREEXISTING_DIRS
    fi
    if declare -p USBC_CONTAINER_DIRS >/dev/null 2>&1; then
        rb_copy_array USBC_CONTAINER_DIRS RB_CONTAINER_DIRS
    fi
    if declare -p USBC_INSTALLED_UNITS >/dev/null 2>&1; then
        rb_copy_array USBC_INSTALLED_UNITS RB_HOST_UNITS
    fi
    if declare -p USBC_CONTAINER_UNITS >/dev/null 2>&1; then
        rb_copy_array USBC_CONTAINER_UNITS RB_CONTAINER_UNITS
    fi
    if declare -p USBC_INSTALLED_UDEV >/dev/null 2>&1; then
        rb_copy_array USBC_INSTALLED_UDEV RB_UDEV
    fi
    if declare -p USBC_BACKUP_FILES >/dev/null 2>&1; then
        rb_copy_array USBC_BACKUP_FILES RB_BACKUPS
    fi
    if declare -p USBC_MOUNTS >/dev/null 2>&1; then
        rb_copy_array USBC_MOUNTS RB_MOUNTS
    fi
    if declare -p USBC_HOST_MOUNTS >/dev/null 2>&1; then
        rb_copy_array USBC_HOST_MOUNTS RB_HOST_MOUNTS
    fi
}

# Read a manifest written by setup/lib/manifest.sh. Only scalar fields and
# path/mount records are extracted; the parser never evaluates manifest text.
rb_load_manifest() {
    local path=$1
    local dump=''
    local key=''
    local value=''
    local slot=''
    local host_path=''
    local ct_path=''

    if ! dump=$(python3 - "$path" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
except OSError as exc:
    print(f"cannot read manifest: {exc}", file=sys.stderr)
    raise SystemExit(1)
except json.JSONDecodeError as exc:
    print(f"invalid manifest JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)

if not isinstance(data, dict) or not isinstance(data.get("ct_id"), int):
    print("invalid manifest: ct_id is missing or not a number", file=sys.stderr)
    raise SystemExit(1)

print(f"CT_ID\t{data['ct_id']}")


def lines(name):
    value = data.get(name, [])
    if not isinstance(value, list):
        return []
    return [str(item) for item in value if str(item)]


for item in lines("host_files"):
    print(f"HOST_FILE\t{item}")
for item in lines("container_files"):
    print(f"CONTAINER_FILE\t{item}")
for item in lines("host_dirs"):
    print(f"HOST_DIR\t{item}")
for item in lines("pre_existing_dirs"):
    print(f"PREEXISTING_DIR\t{item}")
for item in lines("container_dirs"):
    print(f"CONTAINER_DIR\t{item}")
for item in lines("host_units"):
    print(f"HOST_UNIT\t{item}")
for item in lines("container_units"):
    print(f"CONTAINER_UNIT\t{item}")
for item in lines("udev"):
    print(f"UDEV\t{item}")
for item in lines("backups"):
    print(f"BACKUP\t{item}")

mounts = data.get("mounts", [])
if isinstance(mounts, list):
    for mount in mounts:
        if not isinstance(mount, dict):
            continue
        slot = str(mount.get("slot") or "")
        host_path = str(mount.get("host_path") or "")
        ct_path = str(mount.get("ct_path") or "")
        if slot and host_path and ct_path:
            print(f"MOUNT\t{slot}\t{host_path}\t{ct_path}")

host_mounts = data.get("host_mounts", [])
if isinstance(host_mounts, list):
    for mount in host_mounts:
        if not isinstance(mount, dict):
            continue
        fields = [
            str(mount.get("path") or ""),
            str(mount.get("type") or ""),
            "true" if mount.get("self_bind_created") else "false",
            str(mount.get("propagation_before") or "unknown"),
            str(mount.get("propagation_after") or "unknown"),
        ]
        if fields[0]:
            print("HOST_MOUNT\t" + "\t".join(fields))

destinations = data.get("destinations", {})
if isinstance(destinations, dict):
    for key, destination in destinations.items():
        if not isinstance(destination, dict):
            continue
        host_path = str(destination.get("host_path") or "")
        ct_path = str(destination.get("ct_path") or "")
        if host_path:
            print(f"DEST\t{key}\t{host_path}\t{ct_path}")
extra = data.get("extra")
if isinstance(extra, dict) and extra.get("host_path"):
    print(f"DEST\textra\t{extra['host_path']}\t{extra.get('ct_path', '')}")
PY
    ); then
        die "could not read install manifest $path"
    fi

    RB_CT_ID=''
    RB_CT_CREATED=0
    RB_HOST_FILES=()
    RB_CONTAINER_FILES=()
    RB_HOST_DIRS=()
    RB_PREEXISTING_DIRS=()
    RB_CONTAINER_DIRS=()
    RB_HOST_UNITS=()
    RB_CONTAINER_UNITS=()
    RB_UDEV=()
    RB_BACKUPS=()
    RB_MOUNTS=()
    RB_HOST_MOUNTS=()
    RB_DEST_HOSTS=()
    RB_FAILURES=0

    while IFS=$'\t' read -r key value; do
        case "$key" in
            CT_ID)
                RB_CT_ID=$value
                ;;
            HOST_FILE)
                RB_HOST_FILES+=("$value")
                ;;
            CONTAINER_FILE)
                RB_CONTAINER_FILES+=("$value")
                ;;
            HOST_DIR)
                RB_HOST_DIRS+=("$value")
                ;;
            PREEXISTING_DIR)
                RB_PREEXISTING_DIRS+=("$value")
                ;;
            CONTAINER_DIR)
                RB_CONTAINER_DIRS+=("$value")
                ;;
            HOST_UNIT)
                RB_HOST_UNITS+=("$value")
                ;;
            CONTAINER_UNIT)
                RB_CONTAINER_UNITS+=("$value")
                ;;
            UDEV)
                RB_UDEV+=("$value")
                ;;
            BACKUP)
                RB_BACKUPS+=("$value")
                ;;
            MOUNT)
                RB_MOUNTS+=("$value")
                ;;
            HOST_MOUNT)
                RB_HOST_MOUNTS+=("$value")
                ;;
            DEST)
                IFS=$'\t' read -r slot host_path ct_path <<<"$value"
                if [[ -n $host_path ]]; then
                    RB_DEST_HOSTS+=("$host_path")
                fi
                ;;
            *)
                ;;
        esac
    done <<<"$dump"

    [[ -n $RB_CT_ID ]] || die "invalid manifest $path: ct_id is missing"
}

rb_ct_running() {
    local ct=$1
    local output=''

    [[ -n $ct ]] || return 1
    output=$(pct status "$ct" 2>/dev/null) || return 1
    [[ $output == *running* ]]
}

rb_stop_disable_ct_app() {
    local ct=$1

    [[ -n $ct ]] || return 0
    if ! rb_ct_running "$ct"; then
        return 0
    fi
    log "stop and disable usbcopy.service in CT $ct"
    pct exec "$ct" -- systemctl stop usbcopy.service >/dev/null 2>&1 \
        || rb_note_failure "could not stop usbcopy.service in CT $ct"
    pct exec "$ct" -- systemctl disable usbcopy.service >/dev/null 2>&1 \
        || rb_note_failure "could not disable usbcopy.service in CT $ct"
}

rb_stop_ct() {
    local ct=$1

    [[ -n $ct ]] || return 0
    rb_ct_running "$ct" || return 0
    log "stop CT $ct"
    pct stop "$ct" >/dev/null 2>&1 \
        || rb_note_failure "could not stop CT $ct"
}

rb_start_ct() {
    local ct=$1

    [[ -n $ct ]] || return 0
    log "start CT $ct"
    pct start "$ct" >/dev/null 2>&1 \
        || rb_note_failure "could not start CT $ct"
}

rb_remove_ct_mounts() {
    local ct=$1
    local record=''
    local slot=''
    local host_path=''
    local ct_path=''

    ((${#RB_MOUNTS[@]} > 0)) || return 0
    if [[ -z $ct ]]; then
        rb_note_failure "cannot remove CT bind mounts: no CT ID recorded"
        return 0
    fi
    for record in "${RB_MOUNTS[@]}"; do
        IFS=$'\t' read -r slot host_path ct_path <<<"$record"
        [[ -n $slot ]] || continue
        log "remove CT $ct bind mount $slot ($host_path -> $ct_path)"
        pct set "$ct" -delete "$slot" >/dev/null 2>&1 \
            || rb_note_failure "could not remove CT mount $slot from CT $ct"
    done
}

rb_path_in_array() {
    local needle=$1
    shift
    local item
    for item in "$@"; do
        if [[ $item == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

rb_remove_host_units() {
    local unit=''
    local name=''

    ((${#RB_HOST_UNITS[@]} > 0)) || return 0
    log "stop and disable proxmoxUSBcopy host units"
    systemctl stop 'usbcopy-mount@*.service' >/dev/null 2>&1 || true
    for unit in "${RB_HOST_UNITS[@]}"; do
        name=${unit##*/}
        if [[ $name != *@.* ]]; then
            systemctl disable --now "$name" >/dev/null 2>&1 \
                || rb_note_failure "could not disable $name"
        fi
        log "remove host unit $unit"
        rm -f -- "$unit" || rb_note_failure "could not remove $unit"
    done
    systemctl daemon-reload >/dev/null 2>&1 \
        || rb_note_failure "systemctl daemon-reload failed"
}

rb_remove_udev_rules() {
    local rule=''

    ((${#RB_UDEV[@]} > 0)) || return 0
    for rule in "${RB_UDEV[@]}"; do
        log "remove udev rule $rule"
        rm -f -- "$rule" || rb_note_failure "could not remove $rule"
    done
    udevadm control --reload-rules >/dev/null 2>&1 \
        || rb_note_failure "udevadm control --reload-rules failed"
}

rb_remove_host_files() {
    local file=''

    ((${#RB_HOST_FILES[@]} > 0)) || return 0
    for file in "${RB_HOST_FILES[@]}"; do
        if rb_path_in_array "$file" "${RB_UDEV[@]}"; then
            continue
        fi
        [[ -e $file ]] || continue
        log "remove host file $file"
        rm -f -- "$file" || rb_note_failure "could not remove $file"
    done
}

rb_remove_created_dirs() {
    local index=0
    local dir=''

    ((${#RB_HOST_DIRS[@]} > 0)) || return 0
    for ((index = ${#RB_HOST_DIRS[@]} - 1; index >= 0; index--)); do
        dir=${RB_HOST_DIRS[index]}
        [[ -n $dir && -d $dir ]] || continue
        if rmdir -- "$dir" 2>/dev/null; then
            log "remove created directory $dir"
        else
            log "keep non-empty directory $dir"
        fi
    done
}

rb_remove_host_mounts() {
    local record=''
    local path=''
    local kind=''
    local self_bind=''
    local before=''
    local after=''
    local flag=''

    ((${#RB_HOST_MOUNTS[@]} > 0)) || return 0
    for record in "${RB_HOST_MOUNTS[@]}"; do
        IFS=$'\t' read -r path kind self_bind before after <<<"$record"
        [[ -n $path ]] || continue
        if [[ $self_bind == true ]]; then
            if findmnt --mountpoint "$path" >/dev/null 2>&1; then
                log "unmount self-bind $path"
                umount "$path" >/dev/null 2>&1 \
                    || rb_note_failure "could not unmount self-bind $path"
            else
                log "self-bind $path is not mounted; nothing to unmount"
            fi
            continue
        fi
        if [[ $before == unknown || $before == "$after" ]]; then
            continue
        fi
        case "$before" in
            private | shared | slave | unbindable)
                flag="--make-${before}"
                if [[ $before == shared ]]; then
                    flag='--make-rshared'
                elif [[ $before == slave ]]; then
                    flag='--make-rslave'
                elif [[ $before == unbindable ]]; then
                    flag='--make-runbindable'
                fi
                log "restore $path propagation to $before"
                mount "$flag" "$path" >/dev/null 2>&1 \
                    || rb_note_failure "could not restore propagation on $path"
                ;;
            *)
                rb_note_failure "cannot restore unknown propagation '$before' on $path"
                ;;
        esac
    done
}

rb_backup_original() {
    local backup=$1
    local root=${USBC_BACKUP_ROOT:-/etc/usbcopy/backup}
    local relative=''

    root=${root%/}
    [[ $backup == "$root"/* ]] || return 1
    relative=${backup#"$root"/}
    relative=${relative#*/}
    [[ -n $relative && $relative != *'..'* && $relative != *$'\n'* ]] || return 1
    printf '/%s' "$relative"
}

rb_prune_backup_dirs() {
    local backup=$1
    local root=${USBC_BACKUP_ROOT:-/etc/usbcopy/backup}
    local dir=${backup%/*}

    root=${root%/}
    while [[ $dir == "$root"/* ]]; do
        rmdir -- "$dir" 2>/dev/null || break
        dir=${dir%/*}
    done
}

rb_restore_backups() {
    local backup=''
    local original=''

    ((${#RB_BACKUPS[@]} > 0)) || return 0
    for backup in "${RB_BACKUPS[@]}"; do
        if [[ ! -e $backup ]]; then
            rb_note_failure "backup is missing: $backup"
            continue
        fi
        if ! original=$(rb_backup_original "$backup"); then
            rb_note_failure "cannot derive the original path for backup $backup"
            continue
        fi
        log "restore $original from backup"
        mkdir -p -- "$(dirname -- "$original")" \
            || { rb_note_failure "could not create $(dirname -- "$original")"; continue; }
        if cp -a -- "$backup" "$original"; then
            rm -f -- "$backup"
            rb_prune_backup_dirs "$backup"
        else
            rb_note_failure "could not restore $original from $backup"
        fi
    done
}

rb_reload_host() {
    if ((${#RB_HOST_UNITS[@]} + ${#RB_UDEV[@]} + ${#RB_BACKUPS[@]} == 0)); then
        return 0
    fi
    systemctl daemon-reload >/dev/null 2>&1 \
        || rb_note_failure "systemctl daemon-reload failed after restoring backups"
    udevadm control --reload-rules >/dev/null 2>&1 \
        || rb_note_failure "udevadm control --reload-rules failed after restoring backups"
}

rb_safe_container_path() {
    local path=$1
    [[ -n $path && $path == /* && $path != / && $path != *'..'* ]] || return 1
    [[ $path != *[[:cntrl:]]* ]] || return 1
    return 0
}

rb_ct_mounts_clear() {
    local ct=$1
    local record=''
    local slot=''
    local host_path=''
    local ct_path=''
    local clear=1
    local mount_status=0

    ((${#RB_MOUNTS[@]} > 0)) || return 0
    if ! rb_ct_running "$ct"; then
        rb_note_failure "CT $ct is not running; refusing to remove container directories"
        return 1
    fi
    for record in "${RB_MOUNTS[@]}"; do
        IFS=$'\t' read -r slot host_path ct_path <<<"$record"
        [[ -n $ct_path ]] || continue
        if pct exec "$ct" -- findmnt --mountpoint "$ct_path" >/dev/null 2>&1; then
            rb_note_failure "CT mount $ct_path is still present; refusing to remove container directories"
            clear=0
        else
            mount_status=$?
            if ((mount_status != 1)); then
                rb_note_failure "could not verify that $ct_path is unmounted (status $mount_status); refusing to remove container directories"
                clear=0
            fi
        fi
    done
    ((clear == 1))
}

rb_remove_container_payload() {
    local ct=$1
    local path=''
    local remove_dirs=1
    local -a files=()
    local -a dirs=()

    [[ -n $ct ]] || {
        rb_note_failure "cannot remove container files: no CT ID recorded"
        return 0
    }
    for path in "${RB_CONTAINER_FILES[@]}"; do
        if rb_safe_container_path "$path"; then
            files+=("$path")
        else
            rb_note_failure "refusing unsafe container path '$path'"
        fi
    done
    for path in "${RB_CONTAINER_DIRS[@]}"; do
        if rb_safe_container_path "$path"; then
            dirs+=("$path")
        else
            rb_note_failure "refusing unsafe container path '$path'"
        fi
    done
    if ((${#files[@]} > 0)); then
        log "remove application files in CT $ct"
        pct exec "$ct" -- rm -f -- "${files[@]}" >/dev/null 2>&1 \
            || rb_note_failure "could not remove application files in CT $ct"
    fi
    if ((${#dirs[@]} == 0)); then
        return 0
    fi
    if ! rb_ct_mounts_clear "$ct"; then
        remove_dirs=0
    fi
    if ((remove_dirs == 1)); then
        log "remove application directories in CT $ct"
        pct exec "$ct" -- rm -rf -- "${dirs[@]}" >/dev/null 2>&1 \
            || rb_note_failure "could not remove application directories in CT $ct"
    else
        warn "kept application directories in CT $ct because a bind mount is still present"
    fi
}

rb_remove_manifest() {
    local path=${USBC_MANIFEST_PATH:-}

    [[ -n $path ]] || return 0
    [[ -e $path ]] || return 0
    log "remove install manifest $path"
    rm -f -- "$path" || rb_note_failure "could not remove $path"
}

rb_print_kept() {
    local path=''

    for path in "${RB_DEST_HOSTS[@]}"; do
        printf 'Kept destination data: %s\n' "$path"
    done
}

# Automatic rollback used by the installer ERR trap. Returns by exiting with
# the original failure status.
rollback_should_run() {
    local answer=''

    if ((ASSUME_YES == 1)); then
        log "Roll back the partial install? [Y/n]: yes (--yes)"
        return 0
    fi
    if ! answer=$(read_tty "Roll back the partial install? [Y/n]: "); then
        warn "could not read a terminal answer; rolling back by default"
        return 0
    fi
    case "${answer,,}" in
        '' | y | yes)
            return 0
            ;;
        n | no)
            return 1
            ;;
        *)
            warn "unrecognized answer '$answer'; rolling back by default"
            return 0
            ;;
    esac
}

rb_execute_rollback() {
    local ct=${RB_CT_ID:-}

    log "rolling back the partial install"
    if [[ -n $ct ]]; then
        if ((${#RB_CONTAINER_UNITS[@]} > 0)); then
            rb_stop_disable_ct_app "$ct"
        fi
        if ((${#RB_MOUNTS[@]} > 0)); then
            rb_stop_ct "$ct"
            rb_remove_ct_mounts "$ct"
        fi
    fi
    rb_remove_host_units
    rb_remove_udev_rules
    rb_remove_host_files
    rb_remove_host_mounts
    rb_remove_created_dirs
    rb_restore_backups
    rb_reload_host
    if [[ -n $ct ]]; then
        if [[ ${RB_CT_CREATED:-0} == 1 ]]; then
            rb_stop_ct "$ct"
            log "destroy CT $ct created by this install"
            pct destroy "$ct" >/dev/null 2>&1 \
                || rb_note_failure "could not destroy CT $ct"
        else
            log "CT $ct was not created by this run; keeping it"
        fi
    fi
    rb_remove_manifest
    rb_print_kept
    if ((RB_FAILURES > 0)); then
        warn "rollback finished with $RB_FAILURES cleanup warning(s); review the output above"
    else
        log "rollback complete"
    fi
}

rb_print_remaining() {
    local item=''

    log "rollback declined; the partial install was left in place"
    if [[ -n ${RB_CT_ID:-} ]]; then
        log "kept CT $RB_CT_ID"
    fi
    for item in "${RB_HOST_UNITS[@]}" "${RB_HOST_FILES[@]}" "${RB_UDEV[@]}"; do
        [[ -n $item ]] && log "kept $item"
    done
    for item in "${RB_MOUNTS[@]}"; do
        [[ -n $item ]] && log "kept CT bind mount $item"
    done
    rb_print_kept
}

rollback_on_error() {
    local status=${1:-1}

    trap - ERR
    set +e
    printf '%s: error: installation failed (exit %s)\n' "${PROG:-install.sh}" "$status" >&2
    if ((DRY_RUN == 1)); then
        exit "$status"
    fi
    rb_collect_globals
    if rollback_should_run; then
        rb_execute_rollback
        exit "$status"
    fi
    rb_print_remaining
    exit "$status"
}
