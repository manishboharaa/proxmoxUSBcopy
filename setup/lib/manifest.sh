#!/usr/bin/env bash
# Install manifest for proxmoxUSBcopy.
#
# The manifest is the contract uninstall/repair read (Task 21). It is written
# on the host at /etc/usbcopy/install-manifest.json with python3 so every
# path/value is escaped correctly.
# shellcheck shell=bash

USBC_INSTALLED_FILES=()
USBC_CONTAINER_FILES=()
USBC_CREATED_DIRS=()
USBC_CONTAINER_DIRS=()
USBC_INSTALLED_UNITS=()
USBC_CONTAINER_UNITS=()
USBC_INSTALLED_UDEV=()
USBC_BACKUP_FILES=()
USBC_MOUNTS=()

manifest_add_mount() {
    local slot=$1
    local host_path=$2
    local ct_path=$3
    local access=$4
    if [[ $slot =~ ^[0-9]+$ ]]; then
        slot="mp$slot"
    fi
    USBC_MOUNTS+=("$slot"$'\t'"$host_path"$'\t'"$ct_path"$'\t'"$access")
}

manifest_check_absent() {
    if [[ -e $USBC_MANIFEST_PATH ]]; then
        if ((DRY_RUN == 1)); then
            warn "an existing install manifest was found at $USBC_MANIFEST_PATH; dry-run will not modify it"
            return 0
        fi
        die "already installed; uninstall/repair first (manifest: $USBC_MANIFEST_PATH)"
    fi
}

manifest_lines() {
    printf '%s\n' "$@"
}

write_manifest() {
    local installed_at=''
    local destinations_tsv=''
    local extra_key=''
    local extra_host=''
    local extra_ct=''

    if ((DRY_RUN == 1)); then
        plan "write install manifest $USBC_MANIFEST_PATH"
        return 0
    fi

    installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    destinations_tsv=$(
        printf 'movies\t%s\t%s\n' "$DEST_MOVIES" /data/movies
        printf 'series\t%s\t%s\n' "$DEST_SERIES" /data/series
    )
    if [[ -n $DEST_EXTRA ]]; then
        extra_key=${EXTRA_KEY:-$(destination_extra_key)}
        extra_host=$DEST_EXTRA
        extra_ct="/data/${DEST_EXTRA##*/}"
        destinations_tsv+=$'\n'$(printf '%s\t%s\t%s' "$extra_key" "$extra_host" "$extra_ct")
    fi

    USBC_MANIFEST_PATH="$USBC_MANIFEST_PATH" \
        USBC_MANIFEST_INSTALLED_AT="$installed_at" \
        USBC_MANIFEST_CT_ID="$CT_ID" \
        USBC_MANIFEST_HOSTNAME="$CT_HOSTNAME" \
        USBC_MANIFEST_TEMPLATE="$CT_TEMPLATE_REF" \
        USBC_MANIFEST_TEMPLATE_STORAGE="$TEMPLATE_STORAGE" \
        USBC_MANIFEST_CT_STORAGE="$CT_STORAGE" \
        USBC_MANIFEST_BRIDGE="$CT_BRIDGE" \
        USBC_MANIFEST_PORT="$PORT" \
        USBC_MANIFEST_DISK_GB="$DISK_GB" \
        USBC_MANIFEST_RAM_MB="$RAM_MB" \
        USBC_MANIFEST_CORES="$CORES" \
        USBC_MANIFEST_SWAP_MB="$SWAP_MB" \
        USBC_MANIFEST_DESTINATIONS="$destinations_tsv" \
        USBC_MANIFEST_EXTRA_KEY="$extra_key" \
        USBC_MANIFEST_EXTRA_HOST="$extra_host" \
        USBC_MANIFEST_EXTRA_CT="$extra_ct" \
        USBC_MANIFEST_REPO_URL="${REPO_URL:-}" \
        USBC_MANIFEST_REPO_REF="${REPO_REF:-}" \
        USBC_MANIFEST_FILES="$(manifest_lines "${USBC_INSTALLED_FILES[@]}" "${USBC_CONTAINER_FILES[@]}")" \
        USBC_MANIFEST_DIRS="$(manifest_lines "${USBC_CREATED_DIRS[@]}" "${USBC_CONTAINER_DIRS[@]}")" \
        USBC_MANIFEST_UNITS="$(manifest_lines "${USBC_INSTALLED_UNITS[@]}" "${USBC_CONTAINER_UNITS[@]}")" \
        USBC_MANIFEST_UDEV="$(manifest_lines "${USBC_INSTALLED_UDEV[@]}")" \
        USBC_MANIFEST_BACKUPS="$(manifest_lines "${USBC_BACKUP_FILES[@]}")" \
        USBC_MANIFEST_MOUNTS="$(manifest_lines "${USBC_MOUNTS[@]}")" \
        python3 - <<'PY'
import json
import os
import tempfile


def text(name):
    return os.environ.get(name, "")


def lines(name):
    return [line for line in text(name).splitlines() if line]


destinations = {}
for row in lines("USBC_MANIFEST_DESTINATIONS"):
    key, host_path, ct_path = row.split("\t", 2)
    destinations[key] = {"host_path": host_path, "ct_path": ct_path}

mounts = []
for row in lines("USBC_MANIFEST_MOUNTS"):
    slot, host_path, ct_path, access = row.split("\t", 3)
    mounts.append(
        {
            "slot": slot,
            "host_path": host_path,
            "ct_path": ct_path,
            "read_only": access == "ro",
        }
    )

extra = None
if text("USBC_MANIFEST_EXTRA_KEY"):
    extra = {
        "key": text("USBC_MANIFEST_EXTRA_KEY"),
        "host_path": text("USBC_MANIFEST_EXTRA_HOST"),
        "ct_path": text("USBC_MANIFEST_EXTRA_CT"),
    }

payload = {
    "version": 1,
    "installed_at": text("USBC_MANIFEST_INSTALLED_AT"),
    "ct_id": int(text("USBC_MANIFEST_CT_ID")),
    "hostname": text("USBC_MANIFEST_HOSTNAME"),
    "template": text("USBC_MANIFEST_TEMPLATE"),
    "storages": {
        "template": text("USBC_MANIFEST_TEMPLATE_STORAGE"),
        "container": text("USBC_MANIFEST_CT_STORAGE"),
    },
    "bridge": text("USBC_MANIFEST_BRIDGE"),
    "port": int(text("USBC_MANIFEST_PORT")),
    "resources": {
        "disk_gb": int(text("USBC_MANIFEST_DISK_GB")),
        "ram_mb": int(text("USBC_MANIFEST_RAM_MB")),
        "cores": int(text("USBC_MANIFEST_CORES")),
        "swap_mb": int(text("USBC_MANIFEST_SWAP_MB")),
        "unprivileged": True,
        "onboot": True,
    },
    "source": {
        "repo_url": text("USBC_MANIFEST_REPO_URL"),
        "ref": text("USBC_MANIFEST_REPO_REF"),
    },
    "destinations": destinations,
    "extra": extra,
    "files": lines("USBC_MANIFEST_FILES"),
    "dirs": lines("USBC_MANIFEST_DIRS"),
    "units": lines("USBC_MANIFEST_UNITS"),
    "udev": lines("USBC_MANIFEST_UDEV"),
    "mounts": mounts,
    "backups": lines("USBC_MANIFEST_BACKUPS"),
    "logs": {
        "container": "journalctl -u usbcopy",
        "host": "journalctl -u usbcopy-mount@<device>.service",
    },
}

path = text("USBC_MANIFEST_PATH")
directory = os.path.dirname(path)
os.makedirs(directory, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=".install-manifest.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.chmod(temporary, 0o644)
    os.replace(temporary, path)
except BaseException:
    try:
        os.unlink(temporary)
    except OSError:
        pass
    raise
PY
    log "wrote install manifest $USBC_MANIFEST_PATH"
}
