#!/usr/bin/env bash
# proxmoxUSBcopy: start mount units for supported USB filesystems.
#
# Run at boot by usbcopy-scan-usb.service. This covers drives that were
# already connected while the Proxmox host was off, independently of udev
# coldplug behaviour. Already-mounted devices and already-active units are
# skipped, so the script is safe to run repeatedly.
set -euo pipefail

PROG=${0##*/}

usage() {
    cat <<EOF
Usage: $PROG [options]

Start usbcopy-mount@<device>.service for every unmounted USB block device
that carries a supported filesystem (ext2/3/4, vfat, exfat, ntfs).

Options:
  --dry-run              Print the systemctl commands instead of running them
  --lsblk-json PATH      Read lsblk JSON from PATH instead of running lsblk
  -h, --help             Show this help
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

dry_run=0
lsblk_json_file=''

while (($# > 0)); do
    case "$1" in
        --dry-run)
            dry_run=1
            shift
            ;;
        --lsblk-json)
            (($# >= 2)) || die "--lsblk-json requires a value"
            lsblk_json_file=$2
            shift 2
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

require_command python3

if [[ -n $lsblk_json_file ]]; then
    [[ -r $lsblk_json_file ]] || die "cannot read lsblk JSON: $lsblk_json_file"
    lsblk_json=$(<"$lsblk_json_file")
else
    require_command lsblk
    lsblk_json=$(lsblk -J --output NAME,TYPE,FSTYPE,MOUNTPOINT,TRAN)
fi

if [[ -z $lsblk_json ]]; then
    die "lsblk produced no output"
fi

devices=$(
    printf '%s\n' "$lsblk_json" | python3 -c '
import json
import sys

supported = {"ext2", "ext3", "ext4", "vfat", "exfat", "ntfs"}


def walk(node, inherited_usb=False):
    transport = (node.get("tran") or "").lower()
    usb = inherited_usb or transport == "usb"
    fstype = (node.get("fstype") or "").lower()
    name = node.get("name") or ""
    mountpoint = node.get("mountpoint")
    if (
        usb
        and node.get("type") in ("disk", "part")
        and fstype in supported
        and not mountpoint
        and name
    ):
        print(name)
    for child in node.get("children") or []:
        walk(child, usb)


try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError as exc:
    sys.exit("invalid lsblk JSON: %s" % exc)

blockdevices = payload.get("blockdevices")
if not isinstance(blockdevices, list):
    sys.exit("invalid lsblk JSON: missing blockdevices list")
for device in blockdevices:
    if isinstance(device, dict):
        walk(device)
'
)

if ((dry_run == 0)); then
    ((EUID == 0)) || die "must be run as root"
    require_command systemctl
fi

failed=0
while IFS= read -r name; do
    [[ -n $name ]] || continue
    if [[ ! $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        log "skipping unsafe block device name: $name"
        continue
    fi
    unit="usbcopy-mount@${name}.service"
    if command -v systemctl >/dev/null 2>&1 \
        && systemctl is-active --quiet "$unit" 2>/dev/null; then
        continue
    fi
    if ((dry_run == 1)); then
        printf 'systemctl start %s\n' "$unit"
    else
        if ! systemctl start "$unit"; then
            log "failed to start $unit"
            failed=1
        fi
    fi
done <<<"$devices"

if ((failed != 0)); then
    die "one or more USB mount units failed to start"
fi
