#!/usr/bin/env bash
# Uninstall proxmoxUSBcopy using the host install manifest.
#
# Default: stop/disable the CT app, remove app files/config/data inside the
# CT, remove the CT bind mounts, remove the self-bind and host wiring, restore
# backups, and keep the CT and every destination file.
#
# --destroy-ct additionally stops and destroys the CT (never forced).
# --dry-run prints every action without changing anything.
set -euo pipefail

PROG=${0##*/}
SCRIPT_SOURCE=${BASH_SOURCE[0]}
SCRIPT_DIR=${SCRIPT_SOURCE%/*}
if [[ $SCRIPT_DIR == "$SCRIPT_SOURCE" ]]; then
    SCRIPT_DIR=.
fi
SCRIPT_DIR=$(cd -- "$SCRIPT_DIR" && pwd)
LIB_DIR="$SCRIPT_DIR/lib"

DRY_RUN=0
ASSUME_YES=0
DESTROY_CT=0
USBC_MANIFEST_PATH=${USBC_MANIFEST_PATH:-/etc/usbcopy/install-manifest.json}

# shellcheck disable=SC1091
source "$LIB_DIR/common.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/preflight.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/rollback.sh"

usage() {
    cat <<EOF
Usage: $PROG [options]

Remove proxmoxUSBcopy host wiring and the CT application. Destination data
and the CT are kept unless --destroy-ct is given.

Options:
  --yes            Do not ask for confirmation
  --destroy-ct     Stop and destroy the CT after removing the application
  --dry-run        Print every action without changing anything
  -h, --help       Show this help

Manifest: $USBC_MANIFEST_PATH (override with USBC_MANIFEST_PATH)
EOF
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --yes | -y)
                ASSUME_YES=1
                shift
                ;;
            --destroy-ct)
                DESTROY_CT=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                if [[ $1 == -* ]]; then
                    die "unknown argument: ${1%%=*} (see --help)"
                fi
                die "unexpected positional argument (see --help)"
                ;;
        esac
    done
}

print_uninstall_summary() {
    local container='keep CT and remove the application inside it'
    local destinations=''

    if ((DESTROY_CT == 1)); then
        container='remove the application, stop, and destroy the CT'
    fi
    destinations=$(printf '%s ' "${RB_DEST_HOSTS[@]}")
    cat <<EOF
Uninstall summary
  Manifest:      $USBC_MANIFEST_PATH
  CT ID:         $RB_CT_ID
  Container:     $container
  Host files:    ${#RB_HOST_FILES[@]} (plus ${#RB_UDEV[@]} udev rule(s))
  Host units:    ${#RB_HOST_UNITS[@]}
  CT mounts:     ${#RB_MOUNTS[@]}
  Backups:       ${#RB_BACKUPS[@]} to restore
  Destinations:  ${destinations% }
EOF
}

confirm_uninstall() {
    local answer=''

    if ((ASSUME_YES == 1)); then
        log "proceeding without confirmation because --yes was given"
        return 0
    fi
    if ! answer=$(read_tty "Uninstall proxmoxUSBcopy? [y/N]: "); then
        die "no terminal available for confirmation; re-run with --yes"
    fi
    case "${answer,,}" in
        y | yes)
            return 0
            ;;
        '' | n | no)
            return 1
            ;;
        *)
            die "confirmation answer must be yes or no (got: $answer)"
            ;;
    esac
}

print_uninstall_plan() {
    local record=''
    local path=''
    local slot=''
    local host_path=''
    local ct_path=''
    local kind=''
    local self_bind=''
    local before=''
    local after=''
    local backup=''
    local original=''
    local unit=''
    local rule=''
    local file=''
    local dir=''

    plan "stop and disable usbcopy.service in CT $RB_CT_ID"
    for record in "${RB_MOUNTS[@]}"; do
        IFS=$'\t' read -r slot host_path ct_path _ <<<"$record"
        plan "remove CT $RB_CT_ID bind mount $slot ($host_path -> $ct_path)"
    done
    for path in "${RB_CONTAINER_FILES[@]}" "${RB_CONTAINER_DIRS[@]}"; do
        plan "remove $path inside CT $RB_CT_ID"
    done
    for unit in "${RB_HOST_UNITS[@]}"; do
        plan "stop and remove host unit $unit"
    done
    for rule in "${RB_UDEV[@]}"; do
        plan "remove udev rule $rule"
    done
    for file in "${RB_HOST_FILES[@]}"; do
        if rb_path_in_array "$file" "${RB_UDEV[@]}"; then
            continue
        fi
        plan "remove host file $file"
    done
    for record in "${RB_HOST_MOUNTS[@]}"; do
        IFS=$'\t' read -r path kind self_bind before after <<<"$record"
        if [[ $self_bind == true ]]; then
            plan "unmount $kind $path"
        elif [[ $before != unknown && $before != "$after" ]]; then
            plan "restore $path mount propagation to $before"
        fi
    done
    for dir in "${RB_HOST_DIRS[@]}"; do
        plan "remove created directory $dir if empty"
    done
    for backup in "${RB_BACKUPS[@]}"; do
        if original=$(rb_backup_original "$backup"); then
            plan "restore backup $backup -> $original"
        else
            plan "restore backup $backup (original path unknown)"
        fi
    done
    if ((DESTROY_CT == 1)); then
        plan "stop and destroy CT $RB_CT_ID"
    else
        plan "keep CT $RB_CT_ID (pass --destroy-ct to remove it)"
    fi
    plan "reload systemd and udev rules"
    plan "remove install manifest $USBC_MANIFEST_PATH"
    for path in "${RB_DEST_HOSTS[@]}"; do
        plan "keep destination data: $path"
    done
}

rb_abort_uninstall() {
    local reason=$1

    rb_note_failure "$reason"
    warn "aborting before host cleanup; the CT and host state were not modified"
    rb_print_incomplete
    if [[ -n ${USBC_MANIFEST_PATH:-} && -e ${USBC_MANIFEST_PATH:-} ]]; then
        warn "keeping install manifest $USBC_MANIFEST_PATH"
    fi
    exit 1
}

run_uninstall() {
    local ct=$RB_CT_ID
    local ct_present=0
    local ct_was_running=0
    local destroy_ok=1

    RB_FAILURES=0
    if ! rb_query_ct "$ct"; then
        rb_abort_uninstall "could not query CT $ct: ${RB_CT_QUERY_ERROR:-unknown error}"
    fi
    case "$RB_CT_STATE" in
        running)
            ct_present=1
            ct_was_running=1
            ;;
        stopped)
            ct_present=1
            ;;
        missing)
            warn "CT $ct was not found; skipping container cleanup"
            ;;
        *)
            rb_abort_uninstall "unexpected state for CT $ct; refusing to modify it"
            ;;
    esac
    if ((ct_present == 1)); then
        if ! rb_verify_ct_identity "$ct"; then
            rb_abort_uninstall "refusing to modify CT $ct because its identity does not match the install manifest"
        fi
        if ((${#RB_CONTAINER_UNITS[@]} > 0)); then
            # Start a stopped CT first so the app can be stopped and disabled
            # before any live application files are removed.
            rb_start_ct "$ct"
            rb_stop_disable_ct_app "$ct"
        fi
        if ((${#RB_MOUNTS[@]} > 0)); then
            rb_stop_ct "$ct"
            rb_remove_ct_mounts "$ct"
        fi
        if ((${#RB_CONTAINER_FILES[@]} + ${#RB_CONTAINER_DIRS[@]} > 0)); then
            rb_start_ct "$ct"
            rb_remove_container_payload "$ct"
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

    if ((DESTROY_CT == 1)); then
        if ((ct_present == 1)); then
            rb_stop_ct "$ct"
            log "destroy CT $ct"
            if pct destroy "$ct" >/dev/null 2>&1; then
                log "destroyed CT $ct"
            else
                destroy_ok=0
                rb_note_failure "could not destroy CT $ct"
            fi
        else
            warn "CT ${ct:-<unknown>} was not found or cannot be queried; nothing to destroy"
        fi
    elif ((ct_present == 1)); then
        if ((ct_was_running == 1)); then
            log "Kept CT $ct (still running)"
        else
            rb_stop_ct "$ct"
            log "Kept CT $ct (stopped)"
        fi
    fi

    rb_finish_manifest "uninstall"
    rb_print_kept
    if ((RB_FAILURES > 0)); then
        warn "uninstall finished with $RB_FAILURES cleanup warning(s); review the output above"
        exit 1
    fi
    ((destroy_ok == 1)) || exit 1
    log "uninstall complete"
}

main() {
    parse_args "$@"
    if ((DRY_RUN == 0)); then
        preflight_root
        require_cmd pct
        require_cmd systemctl
        require_cmd udevadm
        require_cmd findmnt
        require_cmd mount
        require_cmd umount
        require_cmd python3
        require_cmd realpath
    fi
    if [[ ! -f $USBC_MANIFEST_PATH ]]; then
        die "no install manifest found at $USBC_MANIFEST_PATH; proxmoxUSBcopy does not appear to be installed (set USBC_MANIFEST_PATH to use another manifest)"
    fi
    rb_load_manifest "$USBC_MANIFEST_PATH"
    print_uninstall_summary
    if ((DRY_RUN == 1)); then
        print_uninstall_plan
        log "dry-run complete; no host changes were made"
        exit 0
    fi
    if ! confirm_uninstall; then
        log "aborted by user"
        exit 0
    fi
    run_uninstall
}

main "$@"
