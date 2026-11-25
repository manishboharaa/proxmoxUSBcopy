#!/usr/bin/env bash
# Read-only preflight checks for the proxmoxUSBcopy installer.
#
# Everything here is safe to run with --dry-run: it only reads host metadata
# and never creates, downloads, starts, or modifies anything.
# shellcheck shell=bash

IMAGE_STORAGES=()
TEMPLATE_STORAGES=()
TEMPLATE_STORAGE=''
CT_BRIDGE=''
CT_IDS=()
PVE_VERSION=''

preflight_root() {
    if ((EUID == 0)); then
        return 0
    fi
    if ((DRY_RUN == 1)); then
        warn "not running as root; a real install requires root (dry-run continues)"
        return 0
    fi
    if [[ ${USBC_TEST_MODE:-0} == 1 && -n ${USBC_FAIL_AT:-${FAKE_FAIL_AT:-}} ]]; then
        warn "test mode: bypassing the root check for failure injection (never use USBC_TEST_MODE on a real host)"
        return 0
    fi
    die "must be run as root (EUID 0)"
}

preflight_commands() {
    require_cmd pveversion
    require_cmd pct
    require_cmd pvesm
    require_cmd pveam
    require_cmd curl
    require_cmd realpath
}

preflight_pve() {
    local version=''
    if ! version=$(pveversion 2>/dev/null); then
        die "pveversion failed; is this a Proxmox VE host?"
    fi
    [[ -n $version ]] || die "pveversion returned no version information"
    PVE_VERSION=$version
    log "Proxmox VE: $PVE_VERSION"
}

preflight_internet() {
    local url
    for url in https://github.com http://download.proxmox.com; do
        if ! curl -fsSL --max-time 20 -o /dev/null "$url"; then
            die "no internet access to $url; connect the host or follow the offline install notes"
        fi
    done
    log "internet reachable: github.com and download.proxmox.com"
}

preflight_storages() {
    local images_output=''
    local templates_output=''
    local storage=''

    if ! images_output=$(pvesm status --content images 2>/dev/null); then
        die "pvesm status --content images failed; cannot inspect storage support"
    fi
    mapfile -t IMAGE_STORAGES < <(
        awk 'NR > 1 && $1 != "Name" && NF > 0 { print $1 }' <<<"$images_output"
    )
    ((${#IMAGE_STORAGES[@]} > 0)) \
        || die "no storage supports images content; a CT disk cannot be created"

    if ! templates_output=$(pvesm status --content vztmpl 2>/dev/null); then
        die "pvesm status --content vztmpl failed; cannot inspect template storage"
    fi
    mapfile -t TEMPLATE_STORAGES < <(
        awk 'NR > 1 && $1 != "Name" && NF > 0 { print $1 }' <<<"$templates_output"
    )
    ((${#TEMPLATE_STORAGES[@]} > 0)) \
        || die "no storage supports vztmpl content; a Debian 12 template cannot be stored"

    for storage in "${TEMPLATE_STORAGES[@]}"; do
        if [[ $storage == local ]]; then
            TEMPLATE_STORAGE=$storage
            break
        fi
    done
    [[ -n $TEMPLATE_STORAGE ]] || TEMPLATE_STORAGE=${TEMPLATE_STORAGES[0]}

    log "image storages: ${IMAGE_STORAGES[*]}"
    log "template storage: $TEMPLATE_STORAGE"
}

default_image_storage() {
    local storage
    for storage in "${IMAGE_STORAGES[@]}"; do
        if [[ $storage == local-lvm ]]; then
            printf '%s' local-lvm
            return 0
        fi
    done
    printf '%s' "${IMAGE_STORAGES[0]}"
}

detect_bridge() {
    local bridge=''
    local path
    if [[ -r /etc/network/interfaces ]]; then
        bridge=$(awk '$1 == "iface" && $2 ~ /^vmbr[0-9]+$/ { print $2; exit }' \
            /etc/network/interfaces)
    fi
    if [[ -z $bridge ]]; then
        for path in /sys/class/net/vmbr*; do
            [[ -e $path ]] || continue
            bridge=${path##*/}
            break
        done
    fi
    printf '%s' "${bridge:-vmbr0}"
}

preflight_bridge() {
    CT_BRIDGE=$(detect_bridge)
    if [[ ! -d /sys/class/net/$CT_BRIDGE ]]; then
        if ((DRY_RUN == 1)); then
            warn "bridge $CT_BRIDGE is not present on this host; dry-run assumes it exists"
        elif [[ ${USBC_TEST_MODE:-0} == 1 && -n ${USBC_FAIL_AT:-${FAKE_FAIL_AT:-}} ]]; then
            warn "test mode: assuming bridge $CT_BRIDGE exists for failure injection (never use USBC_TEST_MODE on a real host)"
        else
            die "network bridge $CT_BRIDGE not found"
        fi
    fi
    log "VM bridge: $CT_BRIDGE"
}

preflight_ct_ids() {
    local output=''
    if ! output=$(pct list 2>/dev/null); then
        die "pct list failed; cannot determine the next free CT ID"
    fi
    mapfile -t CT_IDS < <(
        awk 'NR > 1 && $1 ~ /^[0-9]+$/ { print $1 }' <<<"$output" | sort -n
    )
}

ct_id_used() {
    local id=$1
    local used
    for used in "${CT_IDS[@]}"; do
        if [[ $used == "$id" ]]; then
            return 0
        fi
    done
    return 1
}

next_free_ct_id() {
    local id=100
    local found=0
    local used

    while :; do
        found=0
        for used in "${CT_IDS[@]}"; do
            if [[ $used == "$id" ]]; then
                found=1
                break
            fi
        done
        if ((found == 0)); then
            printf '%s' "$id"
            return 0
        fi
        id=$((id + 1))
    done
}

check_destination_ready() {
    local name=$1
    local path=$2
    local exists_var=$3
    local available=''
    local parent=''

    check_destination "$name" "$path" >/dev/null || return 1
    if [[ -e $path ]]; then
        if [[ ! -d $path ]]; then
            USBC_VALIDATE_ERROR="$name is not a directory: $path"
            return 1
        fi
        if [[ ! -w $path ]]; then
            if ((DRY_RUN == 1)); then
                warn "$name is not writable by this user; a real root install will verify: $path"
            else
                USBC_VALIDATE_ERROR="$name is not writable: $path"
                return 1
            fi
        fi
        available=$(df -Pk -- "$path" 2>/dev/null | awk 'NR == 2 { print $4 }') || true
        if [[ -n $available ]]; then
            log "$name: $path (${available} KiB free)"
        else
            log "$name: $path"
        fi
        printf -v "$exists_var" '%s' 1
    else
        parent=${path%/*}
        [[ -n $parent ]] || parent=/
        if [[ ! -d $parent ]]; then
            USBC_VALIDATE_ERROR="$name parent directory does not exist: $parent"
            return 1
        fi
        if [[ ! -w $parent ]]; then
            if ((DRY_RUN == 1)); then
                warn "$name parent is not writable by this user; a real root install will verify: $parent"
            else
                USBC_VALIDATE_ERROR="$name parent directory is not writable: $parent"
                return 1
            fi
        fi
        log "$name will be created during install: $path"
        printf -v "$exists_var" '%s' 0
    fi
    return 0
}

preflight_destination() {
    check_destination_ready "$@" || die "$USBC_VALIDATE_ERROR"
}

check_destinations() {
    USBC_VALIDATE_ERROR=''
    if [[ $DEST_MOVIES == "$DEST_SERIES" ]]; then
        USBC_VALIDATE_ERROR="Movies and Series destinations must be different folders"
        return 1
    fi
    if [[ -n $DEST_EXTRA ]]; then
        if [[ $DEST_EXTRA == "$DEST_MOVIES" || $DEST_EXTRA == "$DEST_SERIES" ]]; then
            USBC_VALIDATE_ERROR="extra destination must differ from Movies and Series"
            return 1
        fi
        case "${DEST_EXTRA##*/}" in
            [Mm][Oo][Vv][Ii][Ee][Ss] | [Ss][Ee][Rr][Ii][Ee][Ss])
                USBC_VALIDATE_ERROR="extra destination must not use the reserved Movies or Series name"
                return 1
                ;;
        esac
    fi
    if [[ $AUTO_MODE == yes && -z $SOURCE_FOLDER ]]; then
        USBC_VALIDATE_ERROR="Auto mode requires a default source folder"
        return 1
    fi
    check_destination_ready "Movies destination" "$DEST_MOVIES" DEST_MOVIES_EXISTS || return 1
    check_destination_ready "Series destination" "$DEST_SERIES" DEST_SERIES_EXISTS || return 1
    if [[ -n $DEST_EXTRA ]]; then
        check_destination_ready "extra destination" "$DEST_EXTRA" DEST_EXTRA_EXISTS || return 1
    fi
    return 0
}

preflight_destinations() {
    check_destinations || die "$USBC_VALIDATE_ERROR"
}
