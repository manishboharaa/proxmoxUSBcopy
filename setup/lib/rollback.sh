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
# shellcheck disable=SC2016,SC2034,SC2153

RB_CT_ID=''
RB_CT_HOSTNAME=''
RB_CT_CREATED=0
RB_CT_STATE=''
RB_CT_QUERY_ERROR=''
RB_HOST_FILES=()
RB_CONTAINER_FILES=()
RB_HOST_DIRS=()
RB_PREEXISTING_DIRS=()
RB_CONTAINER_DIRS=()
RB_HOST_UNITS=()
RB_CONTAINER_UNITS=()
RB_UDEV=()
RB_BACKUPS=()
RB_BACKUP_TARGETS=()
RB_BACKUP_ROOT=''
RB_MOUNTS=()
RB_HOST_MOUNTS=()
RB_DEST_HOSTS=()
RB_DEST_CT_PATHS=()
RB_INCOMPLETE=()
RB_FAILURES=0

rb_note_failure() {
    warn "cleanup: $*"
    RB_INCOMPLETE+=("$*")
    RB_FAILURES=$((RB_FAILURES + 1))
}

rb_add_unique() {
    local target_name=$1
    local value=$2
    local -n array_ref=$target_name
    local item

    [[ -n $value ]] || return 0
    for item in "${array_ref[@]}"; do
        if [[ $item == "$value" ]]; then
            return 0
        fi
    done
    array_ref+=("$value")
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
    RB_CT_HOSTNAME=${CT_HOSTNAME:-}
    RB_CT_CREATED=${CT_CREATED:-0}
    RB_CT_STATE=''
    RB_CT_QUERY_ERROR=''
    RB_INCOMPLETE=()
    RB_FAILURES=0
    RB_BACKUP_ROOT=${USBC_BACKUP_ROOT:-}
    RB_DEST_HOSTS=()
    rb_add_unique RB_DEST_HOSTS "${DEST_MOVIES:-}"
    rb_add_unique RB_DEST_HOSTS "${DEST_SERIES:-}"
    rb_add_unique RB_DEST_HOSTS "${DEST_EXTRA:-}"
    RB_DEST_CT_PATHS=()
    rb_add_unique RB_DEST_CT_PATHS "/data/movies"
    rb_add_unique RB_DEST_CT_PATHS "/data/series"
    if [[ -n ${DEST_EXTRA:-} ]]; then
        rb_add_unique RB_DEST_CT_PATHS "/data/${DEST_EXTRA##*/}"
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
    if declare -p USBC_BACKUP_TARGETS >/dev/null 2>&1; then
        rb_copy_array USBC_BACKUP_TARGETS RB_BACKUP_TARGETS
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
print(f"HOSTNAME\t{data.get('hostname') or ''}")
print(f"BACKUP_ROOT\t{data.get('backup_root') or ''}")


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

backup_targets = data.get("backup_targets", [])
if isinstance(backup_targets, list):
    for item in backup_targets:
        if not isinstance(item, dict):
            continue
        target = str(item.get("target") or "")
        backup = str(item.get("backup") or "")
        if target and backup:
            print(f"BACKUP_TARGET\t{target}\t{backup}")

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
    RB_CT_HOSTNAME=''
    RB_CT_CREATED=0
    RB_CT_STATE=''
    RB_CT_QUERY_ERROR=''
    RB_HOST_FILES=()
    RB_CONTAINER_FILES=()
    RB_HOST_DIRS=()
    RB_PREEXISTING_DIRS=()
    RB_CONTAINER_DIRS=()
    RB_HOST_UNITS=()
    RB_CONTAINER_UNITS=()
    RB_UDEV=()
    RB_BACKUPS=()
    RB_BACKUP_TARGETS=()
    RB_BACKUP_ROOT=''
    RB_MOUNTS=()
    RB_HOST_MOUNTS=()
    RB_DEST_HOSTS=()
    RB_DEST_CT_PATHS=()
    RB_INCOMPLETE=()
    RB_FAILURES=0

    while IFS=$'\t' read -r key value; do
        case "$key" in
            CT_ID)
                RB_CT_ID=$value
                ;;
            HOSTNAME)
                RB_CT_HOSTNAME=$value
                ;;
            BACKUP_ROOT)
                RB_BACKUP_ROOT=$value
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
            BACKUP_TARGET)
                RB_BACKUP_TARGETS+=("$value")
                ;;
            MOUNT)
                RB_MOUNTS+=("$value")
                ;;
            HOST_MOUNT)
                RB_HOST_MOUNTS+=("$value")
                ;;
            DEST)
                IFS=$'\t' read -r slot host_path ct_path <<<"$value"
                rb_add_unique RB_DEST_HOSTS "$host_path"
                rb_add_unique RB_DEST_CT_PATHS "$ct_path"
                ;;
            *)
                ;;
        esac
    done <<<"$dump"

    [[ -n $RB_CT_ID ]] || die "invalid manifest $path: ct_id is missing"
}

rb_query_ct() {
    local ct=$1
    local output=''
    local status=0

    RB_CT_STATE=''
    RB_CT_QUERY_ERROR=''
    [[ -n $ct ]] || return 1
    if output=$(pct status "$ct" 2>&1); then
        status=0
    else
        status=$?
    fi
    if ((status == 0)); then
        case "$output" in
            *running*)
                RB_CT_STATE=running
                ;;
            *stopped*)
                RB_CT_STATE=stopped
                ;;
            *)
                RB_CT_QUERY_ERROR="unexpected pct status output: $output"
                return 1
                ;;
        esac
        return 0
    fi
    case "$output" in
        *"does not exist"* | *"not found"* | *"No such"* | *"no such"* | *"unable to find"*)
            RB_CT_STATE=missing
            return 0
            ;;
    esac
    RB_CT_QUERY_ERROR=$output
    return 1
}

rb_ct_running() {
    local ct=$1

    rb_query_ct "$ct" || return 1
    [[ $RB_CT_STATE == running ]]
}

rb_verify_ct_identity() {
    local ct=$1
    local config=''
    local hostname=${RB_CT_HOSTNAME:-}
    local record=''
    local slot=''
    local host_path=''
    local ct_path=''
    local mount_ok=1

    if ! config=$(pct config "$ct" 2>&1); then
        rb_note_failure "could not read the configuration of CT $ct: $config"
        return 1
    fi
    if [[ -z $hostname ]]; then
        rb_note_failure "manifest does not record the CT hostname; refusing to modify CT $ct"
        return 1
    fi
    if ! grep -qxF "hostname: $hostname" <<<"$config"; then
        rb_note_failure "CT $ct hostname does not match the recorded hostname '$hostname'"
        return 1
    fi
    for record in "${RB_MOUNTS[@]}"; do
        IFS=$'\t' read -r slot host_path ct_path _ <<<"$record"
        [[ -n $host_path && -n $ct_path ]] || continue
        if ! grep -qF -- "$host_path,mp=$ct_path" <<<"$config"; then
            rb_note_failure "CT $ct mount $slot does not match the recorded source $host_path -> $ct_path"
            mount_ok=0
        fi
    done
    ((mount_ok == 1))
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
    if rb_ct_running "$ct"; then
        return 0
    fi
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
        IFS=$'\t' read -r slot host_path ct_path _ <<<"$record"
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

rb_safe_absolute_path() {
    local path=$1
    [[ -n $path && $path == /* && $path != / && $path != *'..'* ]] || return 1
    [[ $path != *[[:cntrl:]]* ]] || return 1
    return 0
}

rb_safe_host_path() {
    local path=$1
    local prefix=''

    rb_safe_absolute_path "$path" || return 1
    for prefix in \
        "${USBC_HOST_LIB_DIR:-/usr/local/lib/usbcopy}" \
        "${USBC_UDEV_RULES_DIR:-/etc/udev/rules.d}" \
        "${USBC_SYSTEMD_DIR:-/etc/systemd/system}" \
        /etc/usbcopy; do
        if [[ $path == "$prefix" || $path == "$prefix"/* ]]; then
            return 0
        fi
    done
    return 1
}

rb_safe_host_dir() {
    local path=$1
    local destination=''
    local fixed=''

    rb_safe_absolute_path "$path" || return 1
    for destination in "${RB_DEST_HOSTS[@]}"; do
        [[ $path == "$destination" ]] && return 0
    done
    for fixed in \
        "${USBC_USB_INGEST_DIR:-/srv/usb-ingest}" \
        "${USBC_SPOOL_DIR:-/srv/usbcopy/events}" \
        "${USBC_HOST_LIB_DIR:-/usr/local/lib/usbcopy}"; do
        [[ $path == "$fixed" ]] && return 0
    done
    return 1
}

rb_safe_container_file() {
    local path=$1

    rb_safe_absolute_path "$path" || return 1
    case "$path" in
        /etc/usbcopy/* | /opt/usbcopy/* | /etc/systemd/system/usbcopy.service)
            return 0
            ;;
    esac
    return 1
}

rb_safe_container_dir() {
    local path=$1

    rb_safe_absolute_path "$path" || return 1
    case "$path" in
        /opt/usbcopy | /opt/usbcopy/* | /var/lib/usbcopy | /var/lib/usbcopy/* | \
            /etc/usbcopy | /etc/usbcopy/* | /mnt/usb | /data | /data/*)
            return 0
            ;;
    esac
    return 1
}

rb_remove_host_units() {
    local unit=''
    local name=''

    ((${#RB_HOST_UNITS[@]} > 0)) || return 0
    log "stop and disable proxmoxUSBcopy host units"
    systemctl stop 'usbcopy-mount@*.service' >/dev/null 2>&1 || true
    for unit in "${RB_HOST_UNITS[@]}"; do
        if ! rb_safe_host_path "$unit"; then
            rb_note_failure "refusing to remove unsafe host unit path '$unit'"
            continue
        fi
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
        if ! rb_safe_host_path "$rule"; then
            rb_note_failure "refusing to remove unsafe udev path '$rule'"
            continue
        fi
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
        if ! rb_safe_host_path "$file"; then
            rb_note_failure "refusing to remove unsafe host file '$file'"
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
    local contents=''

    ((${#RB_HOST_DIRS[@]} > 0)) || return 0
    for ((index = ${#RB_HOST_DIRS[@]} - 1; index >= 0; index--)); do
        dir=${RB_HOST_DIRS[index]}
        [[ -n $dir && -d $dir ]] || continue
        if ! rb_safe_host_dir "$dir"; then
            rb_note_failure "refusing to remove unexpected directory '$dir'"
            continue
        fi
        if ! contents=$(ls -A -- "$dir" 2>/dev/null); then
            rb_note_failure "could not inspect directory $dir before removal"
            continue
        fi
        if [[ -n $contents ]]; then
            log "keep non-empty directory $dir"
            continue
        fi
        if rmdir -- "$dir" 2>/dev/null; then
            log "remove created directory $dir"
        else
            rb_note_failure "could not remove empty directory $dir"
        fi
    done
}

rb_mount_host_recorded() {
    local expected=$1
    local record=''
    local slot=''
    local host_path=''
    local ct_path=''

    for record in "${RB_MOUNTS[@]}"; do
        IFS=$'\t' read -r slot host_path ct_path _ <<<"$record"
        if [[ $host_path == "$expected" ]]; then
            return 0
        fi
    done
    return 1
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
        if [[ $path != "${USBC_USB_INGEST_DIR:-/srv/usb-ingest}" ]] && ! rb_mount_host_recorded "$path"; then
            rb_note_failure "refusing to touch unexpected host mount path '$path'"
            continue
        fi
        if [[ $self_bind == true ]]; then
            if findmnt --mountpoint "$path" >/dev/null 2>&1; then
                log "unmount self-bind $path"
                umount "$path" >/dev/null 2>&1 \
                    || rb_note_failure "could not unmount self-bind $path"
            else
                local mount_status=$?
                if ((mount_status == 1)); then
                    log "self-bind $path is not mounted; nothing to unmount"
                else
                    rb_note_failure "could not query whether self-bind $path is mounted (findmnt status $mount_status)"
                fi
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
    local root=${RB_BACKUP_ROOT:-${USBC_BACKUP_ROOT:-/etc/usbcopy/backup}}
    local relative=''
    local record=''
    local target=''
    local recorded_backup=''

    for record in "${RB_BACKUP_TARGETS[@]}"; do
        IFS=$'\t' read -r target recorded_backup <<<"$record"
        if [[ $recorded_backup == "$backup" && -n $target ]]; then
            printf '%s' "$target"
            return 0
        fi
    done
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
        if ! rb_safe_host_path "$original"; then
            rb_note_failure "refusing to restore backup to unexpected path '$original'"
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

rb_expected_mount_ct_paths() {
    local destination=''
    local fixed=''

    for destination in "${RB_DEST_CT_PATHS[@]}"; do
        [[ -n $destination ]] && printf '%s\n' "$destination"
    done
    for fixed in /mnt/usb /var/lib/usbcopy/events; do
        if rb_path_in_array "$fixed" "${RB_CONTAINER_DIRS[@]}"; then
            printf '%s\n' "$fixed"
        fi
    done
}

rb_ct_mount_recorded() {
    local expected=$1
    local record=''
    local slot=''
    local host_path=''
    local ct_path=''

    for record in "${RB_MOUNTS[@]}"; do
        IFS=$'\t' read -r slot host_path ct_path _ <<<"$record"
        if [[ $ct_path == "$expected" ]]; then
            return 0
        fi
    done
    return 1
}

rb_ct_path_on_rootfs() {
    local ct=$1
    local path=$2
    local output=''
    local status=0

    if output=$(pct exec "$ct" -- sh -c '
target=$(findmnt -n -o TARGET -T "$1" 2>/dev/null) || exit 20
if [ "$target" = "/" ]; then
    exit 10
fi
printf "%s" "$target"
exit 0
' sh "$path" 2>/dev/null); then
        status=0
    else
        status=$?
    fi
    case "$status" in
        10)
            return 0
            ;;
        0)
            rb_note_failure "CT path $path is on mount '${output:-unknown}'; refusing to remove container directories"
            return 1
            ;;
        20)
            rb_note_failure "findmnt failed while checking CT path $path; refusing to remove container directories"
            return 1
            ;;
        *)
            rb_note_failure "could not query the mount for CT path $path (pct exec status $status); refusing to remove container directories"
            return 1
            ;;
    esac
}

rb_ct_mounts_clear() {
    local ct=$1
    local expected=''
    local -a expected_paths=()

    mapfile -t expected_paths < <(rb_expected_mount_ct_paths)
    if ! rb_ct_running "$ct"; then
        rb_note_failure "CT $ct is not running; refusing to remove container directories"
        return 1
    fi
    for expected in "${expected_paths[@]}"; do
        if ! rb_ct_mount_recorded "$expected"; then
            rb_note_failure "manifest has no mount record for $expected; refusing to remove container directories"
            return 1
        fi
        if ! rb_ct_path_on_rootfs "$ct" "$expected"; then
            return 1
        fi
    done
    ((${#expected_paths[@]} > 0)) || return 0
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
        if rb_safe_container_file "$path"; then
            files+=("$path")
        else
            rb_note_failure "refusing unsafe container file path '$path'"
        fi
    done
    for path in "${RB_CONTAINER_DIRS[@]}"; do
        if rb_safe_container_dir "$path"; then
            dirs+=("$path")
        else
            rb_note_failure "refusing unsafe container directory path '$path'"
        fi
    done
    if ((${#files[@]} > 0)); then
        log "remove application files in CT $ct"
        pct exec "$ct" -- rm -f -- "${files[@]}" >/dev/null 2>&1 \
            || rb_note_failure "could not remove application files in CT $ct"
    fi
    if ((${#RB_CONTAINER_UNITS[@]} > 0)); then
        log "reload systemd in CT $ct after removing the application unit"
        pct exec "$ct" -- systemctl daemon-reload >/dev/null 2>&1 \
            || rb_note_failure "systemctl daemon-reload failed in CT $ct"
    fi
    if ((${#dirs[@]} == 0)); then
        return 0
    fi
    if ! rb_ct_mounts_clear "$ct"; then
        remove_dirs=0
    fi
    if ((remove_dirs == 1)); then
        for path in "${dirs[@]}"; do
            if ! rb_ct_path_on_rootfs "$ct" "$path"; then
                remove_dirs=0
                break
            fi
        done
    fi
    if ((remove_dirs == 1)); then
        log "remove application directories in CT $ct"
        pct exec "$ct" -- rm -rf -- "${dirs[@]}" >/dev/null 2>&1 \
            || rb_note_failure "could not remove application directories in CT $ct"
    else
        warn "kept application directories in CT $ct because a bind mount is still present or could not be verified"
    fi
}

rb_warn_pending_spool() {
    local record=''
    local slot=''
    local host_path=''
    local ct_path=''
    local contents=''
    local spool=''
    local -a spools=()

    for record in "${RB_MOUNTS[@]}"; do
        IFS=$'\t' read -r slot host_path ct_path _ <<<"$record"
        if [[ $ct_path == /var/lib/usbcopy/events && -n $host_path ]]; then
            rb_add_unique spools "$host_path"
        fi
    done
    if [[ -n ${USBC_SPOOL_DIR:-} ]]; then
        rb_add_unique spools "$USBC_SPOOL_DIR"
    elif [[ -d /srv/usbcopy/events ]]; then
        rb_add_unique spools /srv/usbcopy/events
    fi
    for spool in "${spools[@]}"; do
        if [[ -d $spool ]] && contents=$(ls -A -- "$spool" 2>/dev/null) && [[ -n $contents ]]; then
            warn "event spool $spool has pending events; keeping them"
        fi
    done
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

rb_print_incomplete() {
    local step=''

    for step in "${RB_INCOMPLETE[@]}"; do
        warn "incomplete: $step"
    done
}

rb_report_manifest_kept() {
    if [[ -n ${USBC_MANIFEST_PATH:-} && -e ${USBC_MANIFEST_PATH:-} ]]; then
        warn "keeping install manifest $USBC_MANIFEST_PATH"
    fi
}

rb_finish_manifest() {
    local action=$1

    if ((RB_FAILURES == 0)); then
        rb_remove_manifest
        return 0
    fi
    if [[ -n ${USBC_MANIFEST_PATH:-} && -e ${USBC_MANIFEST_PATH:-} ]]; then
        warn "$action incomplete; keeping install manifest $USBC_MANIFEST_PATH"
    else
        warn "$action incomplete; no install manifest was written"
    fi
    rb_print_incomplete
    return 0
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
    local ct_present=0

    log "rolling back the partial install"
    if [[ -n $ct ]]; then
        if ! rb_query_ct "$ct"; then
            rb_note_failure "could not query CT $ct: ${RB_CT_QUERY_ERROR:-unknown error}"
            rb_report_manifest_kept
            rb_print_remaining
            return 1
        fi
        case "$RB_CT_STATE" in
            running | stopped)
                ct_present=1
                if ! rb_verify_ct_identity "$ct"; then
                    warn "refusing to modify CT $ct because its identity does not match this install"
                    rb_report_manifest_kept
                    rb_print_remaining
                    return 1
                fi
                ;;
            missing)
                log "CT $ct does not exist; skipping container cleanup"
                ;;
            *)
                rb_note_failure "unexpected state for CT $ct; refusing to modify it"
                rb_report_manifest_kept
                rb_print_remaining
                return 1
                ;;
        esac
    fi
    if ((ct_present == 1)); then
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
    rb_warn_pending_spool
    rb_remove_created_dirs
    rb_restore_backups
    rb_reload_host
    if [[ -n $ct ]]; then
        if ((ct_present == 1)) && [[ ${RB_CT_CREATED:-0} == 1 ]]; then
            rb_stop_ct "$ct"
            log "destroy CT $ct created by this install"
            pct destroy "$ct" >/dev/null 2>&1 \
                || rb_note_failure "could not destroy CT $ct"
        elif [[ ${RB_CT_CREATED:-0} == 1 ]]; then
            log "CT $ct is already absent; nothing to destroy"
        else
            log "CT $ct was not created by this run; keeping it"
        fi
    fi
    rb_finish_manifest "rollback"
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
    for item in "${RB_HOST_UNITS[@]}" "${RB_HOST_FILES[@]}" "${RB_UDEV[@]}" \
        "${RB_HOST_DIRS[@]}" "${RB_BACKUPS[@]}"; do
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
        if ! rb_execute_rollback; then
            warn "rollback aborted; the partial install was left in place"
            rb_print_incomplete
        fi
        exit "$status"
    fi
    rb_print_remaining
    exit "$status"
}
