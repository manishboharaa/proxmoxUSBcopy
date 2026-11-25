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
USBC_PREEXISTING_DIRS=()
USBC_CONTAINER_DIRS=()
USBC_INSTALLED_UNITS=()
USBC_CONTAINER_UNITS=()
USBC_INSTALLED_UDEV=()
USBC_BACKUP_FILES=()
USBC_BACKUP_TARGETS=()
USBC_MOUNTS=()
USBC_HOST_MOUNTS=()

manifest_add_mount() {
    local slot=$1
    local host_path=$2
    local ct_path=$3
    local requested=$4
    local effective=$5

    if [[ $slot =~ ^[0-9]+$ ]]; then
        slot="mp$slot"
    fi
    USBC_MOUNTS+=(
        "$slot"$'\t'"$host_path"$'\t'"$ct_path"$'\t'"$requested"$'\t'"$effective"
    )
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

manifest_ct_id() {
    python3 - "$USBC_MANIFEST_PATH" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
value = payload.get("ct_id")
print(value if value is not None else "")
PY
}

update_preflight() {
    if [[ ${DRY_RUN:-0} == 1 ]]; then
        plan "update: read the existing install manifest and check the CT"
        return 0
    fi
    if [[ ! -e $USBC_MANIFEST_PATH ]]; then
        die "no existing install found at $USBC_MANIFEST_PATH; run the installer without --update first"
    fi
    CT_ID=$(manifest_ct_id) \
        || die "could not read the CT id from $USBC_MANIFEST_PATH"
    [[ $CT_ID =~ ^[0-9]+$ ]] \
        || die "the install manifest has no usable CT id: $USBC_MANIFEST_PATH"
    log "updating the existing installation in CT $CT_ID"
    if ! pct status "$CT_ID" >/dev/null 2>&1; then
        die "CT $CT_ID is not running; start it and retry --update"
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
    local installer_checkout=''

    if ((DRY_RUN == 1)); then
        plan "write install manifest $USBC_MANIFEST_PATH"
        return 0
    fi

    installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [[ ${USBC_INSTALLER_MODE:-checkout} != bootstrap ]]; then
        installer_checkout=${SCRIPT_DIR:-}
    fi
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
        USBC_MANIFEST_INSTALLER_MODE="${USBC_INSTALLER_MODE:-checkout}" \
        USBC_MANIFEST_INSTALLER_CHECKOUT="$installer_checkout" \
        USBC_MANIFEST_HOST_FILES="$(manifest_lines "${USBC_INSTALLED_FILES[@]}")" \
        USBC_MANIFEST_CONTAINER_FILES="$(manifest_lines "${USBC_CONTAINER_FILES[@]}")" \
        USBC_MANIFEST_HOST_DIRS="$(manifest_lines "${USBC_CREATED_DIRS[@]}")" \
        USBC_MANIFEST_PREEXISTING_DIRS="$(manifest_lines "${USBC_PREEXISTING_DIRS[@]}")" \
        USBC_MANIFEST_CONTAINER_DIRS="$(manifest_lines "${USBC_CONTAINER_DIRS[@]}")" \
        USBC_MANIFEST_HOST_UNITS="$(manifest_lines "${USBC_INSTALLED_UNITS[@]}")" \
        USBC_MANIFEST_CONTAINER_UNITS="$(manifest_lines "${USBC_CONTAINER_UNITS[@]}")" \
        USBC_MANIFEST_UDEV="$(manifest_lines "${USBC_INSTALLED_UDEV[@]}")" \
        USBC_MANIFEST_BACKUPS="$(manifest_lines "${USBC_BACKUP_FILES[@]}")" \
        USBC_MANIFEST_BACKUP_ROOT="${USBC_BACKUP_ROOT:-}" \
        USBC_MANIFEST_BACKUP_TARGETS="$(manifest_lines "${USBC_BACKUP_TARGETS[@]}")" \
        USBC_MANIFEST_MOUNTS="$(manifest_lines "${USBC_MOUNTS[@]}")" \
        USBC_MANIFEST_HOST_MOUNTS="$(manifest_lines "${USBC_HOST_MOUNTS[@]}")" \
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
    slot, host_path, ct_path, requested, effective = row.split("\t", 4)
    mounts.append(
        {
            "slot": slot,
            "host_path": host_path,
            "ct_path": ct_path,
            "read_only_requested": requested == "ro",
            "read_only_effective": effective == "ro",
            "read_only": effective == "ro",
            "access": effective,
        }
    )

host_mounts = []
for row in lines("USBC_MANIFEST_HOST_MOUNTS"):
    path, kind, self_bind, before, after = row.split("\t", 4)
    host_mounts.append(
        {
            "path": path,
            "type": kind,
            "self_bind_created": self_bind == "true",
            "propagation_before": before,
            "propagation_after": after,
        }
    )

extra = None
if text("USBC_MANIFEST_EXTRA_KEY"):
    extra = {
        "key": text("USBC_MANIFEST_EXTRA_KEY"),
        "host_path": text("USBC_MANIFEST_EXTRA_HOST"),
        "ct_path": text("USBC_MANIFEST_EXTRA_CT"),
    }

host_files = lines("USBC_MANIFEST_HOST_FILES")
container_files = lines("USBC_MANIFEST_CONTAINER_FILES")
host_dirs = lines("USBC_MANIFEST_HOST_DIRS")
container_dirs = lines("USBC_MANIFEST_CONTAINER_DIRS")
host_units = lines("USBC_MANIFEST_HOST_UNITS")
container_units = lines("USBC_MANIFEST_CONTAINER_UNITS")

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
    "installer": {
        "mode": text("USBC_MANIFEST_INSTALLER_MODE"),
        "repo_url": text("USBC_MANIFEST_REPO_URL"),
        "ref": text("USBC_MANIFEST_REPO_REF"),
        "checkout": text("USBC_MANIFEST_INSTALLER_CHECKOUT") or None,
    },
    "destinations": destinations,
    "extra": extra,
    "host_files": host_files,
    "container_files": container_files,
    "host_dirs": host_dirs,
    "pre_existing_dirs": lines("USBC_MANIFEST_PREEXISTING_DIRS"),
    "container_dirs": container_dirs,
    "host_units": host_units,
    "container_units": container_units,
    "udev": lines("USBC_MANIFEST_UDEV"),
    "mounts": mounts,
    "host_mounts": host_mounts,
    "backups": lines("USBC_MANIFEST_BACKUPS"),
    "backup_root": text("USBC_MANIFEST_BACKUP_ROOT"),
    "backup_targets": [
        {"target": row.split("\t", 1)[0], "backup": row.split("\t", 1)[1]}
        for row in lines("USBC_MANIFEST_BACKUP_TARGETS")
        if "\t" in row
    ],
    "files": host_files + container_files,
    "dirs": host_dirs + container_dirs,
    "units": host_units + container_units,
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
