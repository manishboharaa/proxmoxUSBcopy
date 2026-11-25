#!/usr/bin/env bash
# Host-side preparation for proxmoxUSBcopy.
#
# Host paths are overridable so tests can redirect every write into a temp
# tree. Production defaults match DESIGN 11.1/11.5.
# shellcheck shell=bash
# shellcheck disable=SC2034

HOST_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
USBC_HOST_ASSET_DIR=${USBC_HOST_ASSET_DIR:-$HOST_LIB_DIR/../host}
USBC_USB_INGEST_DIR=${USBC_USB_INGEST_DIR:-/srv/usb-ingest}
USBC_SPOOL_DIR=${USBC_SPOOL_DIR:-/srv/usbcopy/events}
USBC_HOST_LIB_DIR=${USBC_HOST_LIB_DIR:-/usr/local/lib/usbcopy}
USBC_UDEV_RULES_DIR=${USBC_UDEV_RULES_DIR:-/etc/udev/rules.d}
USBC_SYSTEMD_DIR=${USBC_SYSTEMD_DIR:-/etc/systemd/system}
USBC_MANIFEST_PATH=${USBC_MANIFEST_PATH:-/etc/usbcopy/install-manifest.json}
USBC_BACKUP_ROOT=${USBC_BACKUP_ROOT:-/etc/usbcopy/backup}
USBC_BACKUP_STAMP=''

USBC_RO_FALLBACK_MOUNTS=()
USBC_HOST_MOUNTS=()

ct_mapped_id() {
    local flag=$1
    local id=''

    id=$(ct_exec id "$flag" usbcopy) || die "could not read the usbcopy $flag in CT $CT_ID"
    [[ $id =~ ^[0-9]+$ ]] || die "unexpected usbcopy $flag from CT $CT_ID: $id"
    printf '%d' "$((100000 + id))"
}

backup_host_file() {
    local target=$1
    local relative=${target#/}
    local backup="$USBC_BACKUP_ROOT/$USBC_BACKUP_STAMP/$relative"

    if [[ ! -e $target ]]; then
        return 0
    fi
    mkdir -p -- "${backup%/*}" || die "could not create backup directory ${backup%/*}"
    cp -a -- "$target" "$backup" || die "could not back up $target"
    USBC_BACKUP_FILES+=("$backup")
    log "backed up $target to $backup"
}

install_host_file() {
    local source=$1
    local target=$2
    local mode=$3

    [[ -f $source ]] || die "missing host asset: $source"
    if [[ -e $target ]]; then
        backup_host_file "$target"
    fi
    install -D -m "$mode" "$source" "$target" \
        || die "could not install $target"
    USBC_INSTALLED_FILES+=("$target")
    log "installed $target"
}

ensure_host_dir() {
    local path=$1
    local mode=$2

    if [[ -d $path ]]; then
        USBC_PREEXISTING_DIRS+=("$path")
        return 0
    fi
    install -d -m "$mode" "$path" || die "could not create $path"
    USBC_CREATED_DIRS+=("$path")
}

add_ct_mount() {
    local slot=$1
    local host_path=$2
    local ct_path=$3
    local access=${4:-rw}
    local value="$host_path,mp=$ct_path"
    local effective=$access

    if [[ $access == ro ]]; then
        value+=",ro=1"
    fi
    log "bind mount mp$slot: $host_path -> $ct_path${access:+ ($access)}"
    if pct set "$CT_ID" "-mp$slot" "$value"; then
        manifest_add_mount "$slot" "$host_path" "$ct_path" "$access" "$effective"
        return 0
    fi
    if [[ $access != ro ]]; then
        die "pct set failed for mount mp$slot ($host_path -> $ct_path)"
    fi
    effective=rw
    USBC_RO_FALLBACK_MOUNTS+=("$host_path")
    warn "pct set rejected ro=1 for mp$slot; retrying without it (the host source is already mounted read-only)"
    value="$host_path,mp=$ct_path"
    pct set "$CT_ID" "-mp$slot" "$value" \
        || die "pct set failed for mount mp$slot ($host_path -> $ct_path)"
    manifest_add_mount "$slot" "$host_path" "$ct_path" "$access" "$effective"
}

configure_host_propagation() {
    local self_bind=false
    local propagation_before=''
    local propagation_after=''

    if findmnt --mountpoint "$USBC_USB_INGEST_DIR" >/dev/null 2>&1; then
        log "$USBC_USB_INGEST_DIR is already a mountpoint"
    else
        mount --bind "$USBC_USB_INGEST_DIR" "$USBC_USB_INGEST_DIR" \
            || die "could not self-bind $USBC_USB_INGEST_DIR for shared propagation"
        self_bind=true
        log "self-bound $USBC_USB_INGEST_DIR so propagation changes stay local to it"
    fi
    propagation_before=$(findmnt -no PROPAGATION -T "$USBC_USB_INGEST_DIR" 2>/dev/null || printf 'unknown')
    mount --make-rshared "$USBC_USB_INGEST_DIR" \
        || die "could not make $USBC_USB_INGEST_DIR rshared"
    propagation_after=$(findmnt -no PROPAGATION -T "$USBC_USB_INGEST_DIR" 2>/dev/null || printf 'unknown')
    USBC_HOST_MOUNTS+=(
        "$USBC_USB_INGEST_DIR"$'\t'"self-bind"$'\t'"$self_bind"$'\t'"$propagation_before"$'\t'"$propagation_after"
    )
    if [[ $propagation_after != *shared* ]]; then
        warn "$USBC_USB_INGEST_DIR propagation is '$propagation_after', not 'shared'; USB hotplug may not reach CT $CT_ID"
    fi
}

configure_host() {
    local mapped_uid=''
    local mapped_gid=''
    local destination=''
    local slot=0

    if ((DRY_RUN == 1)); then
        plan "create host directories, install host assets, and add CT bind mounts"
        return 0
    fi

    for destination in "$DEST_MOVIES" "$DEST_SERIES"; do
        validate_destination_safety "Movies/Series destination" "$destination" >/dev/null
    done
    if [[ -n $DEST_EXTRA ]]; then
        validate_destination_safety "extra destination" "$DEST_EXTRA" >/dev/null
    fi

    USBC_BACKUP_STAMP=$(date -u +%Y%m%dT%H%M%SZ)
    mapped_uid=$(ct_mapped_id -u)
    mapped_gid=$(ct_mapped_id -g)

    ensure_host_dir "$USBC_USB_INGEST_DIR" 0755
    ensure_host_dir "$USBC_SPOOL_DIR" 0750
    chown "$mapped_uid:$mapped_gid" "$USBC_SPOOL_DIR" \
        || die "could not chown $USBC_SPOOL_DIR"
    chmod 0750 "$USBC_SPOOL_DIR" || die "could not chmod $USBC_SPOOL_DIR"

    for destination in "$DEST_MOVIES" "$DEST_SERIES"; do
        ensure_host_dir "$destination" 0755
        # Only the destination root is chowned: existing Jellyfin files and
        # folders inside it keep their current ownership.
        chown "$mapped_uid:$mapped_gid" "$destination" \
            || die "could not chown destination root $destination"
    done
    if [[ -n $DEST_EXTRA ]]; then
        EXTRA_KEY=$(destination_extra_key)
        ensure_host_dir "$DEST_EXTRA" 0755
        chown "$mapped_uid:$mapped_gid" "$DEST_EXTRA" \
            || die "could not chown destination root $DEST_EXTRA"
    fi

    install -d -m 0755 "$USBC_HOST_LIB_DIR" \
        || die "could not create $USBC_HOST_LIB_DIR"
    install_host_file "$USBC_HOST_ASSET_DIR/mount-usb.sh" \
        "$USBC_HOST_LIB_DIR/mount-usb.sh" 0755
    install_host_file "$USBC_HOST_ASSET_DIR/unmount-usb.sh" \
        "$USBC_HOST_LIB_DIR/unmount-usb.sh" 0755
    install_host_file "$USBC_HOST_ASSET_DIR/scan-usb.sh" \
        "$USBC_HOST_LIB_DIR/scan-usb.sh" 0755
    install -d -m 0755 "$USBC_UDEV_RULES_DIR" \
        || die "could not create $USBC_UDEV_RULES_DIR"
    install_host_file "$USBC_HOST_ASSET_DIR/99-usbcopy.rules" \
        "$USBC_UDEV_RULES_DIR/99-usbcopy.rules" 0644
    USBC_INSTALLED_UDEV+=("$USBC_UDEV_RULES_DIR/99-usbcopy.rules")

    install -d -m 0755 "$USBC_SYSTEMD_DIR" \
        || die "could not create $USBC_SYSTEMD_DIR"
    install_host_file "$USBC_HOST_ASSET_DIR/usbcopy-mount@.service" \
        "$USBC_SYSTEMD_DIR/usbcopy-mount@.service" 0644
    install_host_file "$USBC_HOST_ASSET_DIR/usbcopy-scan-usb.service" \
        "$USBC_SYSTEMD_DIR/usbcopy-scan-usb.service" 0644
    USBC_INSTALLED_UNITS+=(
        "$USBC_SYSTEMD_DIR/usbcopy-mount@.service"
        "$USBC_SYSTEMD_DIR/usbcopy-scan-usb.service"
    )

    configure_host_propagation

    systemctl daemon-reload || die "systemctl daemon-reload failed on the host"
    systemctl enable usbcopy-scan-usb.service \
        || die "could not enable usbcopy-scan-usb.service on the host"
    udevadm control --reload-rules || die "udevadm control --reload-rules failed"

    pct stop "$CT_ID" || die "could not stop CT $CT_ID before adding bind mounts"
    slot=0
    add_ct_mount "$slot" "$USBC_USB_INGEST_DIR" /mnt/usb ro
    slot=$((slot + 1))
    add_ct_mount "$slot" "$USBC_SPOOL_DIR" /var/lib/usbcopy/events rw
    slot=$((slot + 1))
    add_ct_mount "$slot" "$DEST_MOVIES" /data/movies rw
    slot=$((slot + 1))
    add_ct_mount "$slot" "$DEST_SERIES" /data/series rw
    if [[ -n $DEST_EXTRA ]]; then
        slot=$((slot + 1))
        add_ct_mount "$slot" "$DEST_EXTRA" "/data/${DEST_EXTRA##*/}" rw
    fi
    pct start "$CT_ID" || die "could not start CT $CT_ID after adding bind mounts"
    ct_exec findmnt --mountpoint /mnt/usb >/dev/null 2>&1 \
        || die "the USB bind mount is not visible inside CT $CT_ID after restart"
    ct_exec findmnt --mountpoint /var/lib/usbcopy/events >/dev/null 2>&1 \
        || die "the event spool bind mount is not visible inside CT $CT_ID after restart"
    wait_for_usbcopy_app
    log "host configuration complete; mapped UID:GID $mapped_uid:$mapped_gid"
}
