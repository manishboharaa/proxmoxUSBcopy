#!/usr/bin/env bash
# proxmoxUSBcopy installer.
#
# Task 19 scope: read-only preflight, the DESIGN 11.5 prompt flow, and a
# complete --dry-run plan. Real installation steps arrive in Task 20.
set -euo pipefail

# Task 19 is checkout-only. The self-contained curl|bash bootstrap belongs to
# Task 20; fail with an actionable message instead of a source-path error.
if [[ -z ${BASH_SOURCE[0]:-} || ! -f ${BASH_SOURCE[0]} ]]; then
    printf 'install.sh: error: run this installer from a repository checkout (setup/install.sh); curl | bash is not supported by this build\n' >&2
    exit 1
fi

REPO_URL="https://github.com/OWNER/proxmoxUSBcopy"
REPO_REF="main"

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
UNINSTALL=0

# The helper files are separate shellcheck inputs; cross-file globals and
# source resolution are expected here.
# shellcheck disable=SC1091
source "$LIB_DIR/common.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/preflight.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/prompts.sh"

usage() {
    cat <<EOF
Usage: $PROG [options]

Install proxmoxUSBcopy on a Proxmox VE host as an unprivileged Debian 12 CT.

Options:
  --repo-url URL   Git repository to fetch (default: $REPO_URL)
  --ref REF        Branch, tag, or commit to install (default: $REPO_REF)
  --dry-run        Run read-only preflight, prompts, and print the plan only
  --yes            Accept defaults; read answers from USBC_ANSWERS when set
  --uninstall      Run setup/uninstall.sh instead of installing
  -h, --help       Show this help
EOF
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --repo-url)
                (($# >= 2)) || die "--repo-url requires a value"
                REPO_URL=$2
                shift 2
                ;;
            --repo-url=*)
                REPO_URL=${1#*=}
                shift
                ;;
            --ref)
                (($# >= 2)) || die "--ref requires a value"
                REPO_REF=$2
                shift 2
                ;;
            --ref=*)
                REPO_REF=${1#*=}
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --yes | -y)
                export ASSUME_YES=1
                shift
                ;;
            --uninstall)
                UNINSTALL=1
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

validate_repo_url() {
    local url=$1
    local rest=''
    local authority=''
    local userinfo=''

    [[ -n $url ]] || die "--repo-url must not be empty"
    [[ $url != -* ]] || die "repository URL must not start with '-'"
    [[ $url != *' '* && $url != *$'\n'* && $url != *$'\r'* && $url != *$'\t'* ]] \
        || die "repository URL must not contain whitespace or control characters"

    case "$url" in
        git@*)
            [[ $url == git@*:* ]] \
                || die "repository URL must look like git@host:path"
            [[ ${url#git@} != *@* ]] \
                || die "repository URL must not embed credentials (user:token@host)"
            ;;
        http://* | https://* | ssh://*)
            rest=${url#*://}
            authority=${rest%%/*}
            [[ -n $authority && $rest == */* ]] \
                || die "repository URL must include a host and repository path"
            if [[ $authority == *@* ]]; then
                userinfo=${authority%@*}
                if [[ $userinfo == *:* ]]; then
                    die "repository URL must not embed credentials (user:token@host)"
                fi
                if [[ $url != ssh://* ]]; then
                    die "repository URL must not embed credentials; use a credential helper"
                fi
            fi
            ;;
        *)
            die "unsupported repository URL; use https://, http://, ssh://, or git@host:path"
            ;;
    esac
}

validate_install_source() {
    validate_repo_url "$REPO_URL"
    [[ -n $REPO_REF ]] || die "--ref must not be empty"
    [[ $REPO_REF =~ ^[A-Za-z0-9._/-]+$ ]] \
        || die "--ref contains unsupported characters"
    [[ $REPO_REF != *'..'* ]] || die "--ref must not contain '..'"
    [[ $REPO_REF != -* ]] || die "--ref must not start with '-'"
    if [[ $REPO_URL == *'/OWNER/'* ]]; then
        warn "REPO_URL still contains the OWNER placeholder; pass --repo-url before a real install"
    fi
}

print_plan() {
    local network='dhcp'
    local extra_name=''
    local auto_line='Auto mode disabled'

    if [[ $NET_MODE == static ]]; then
        network="static $NET_IP, gateway $NET_GW"
        if [[ -n $NET_DNS ]]; then
            network+=", dns $NET_DNS"
        fi
    fi
    if [[ $AUTO_MODE == yes ]]; then
        auto_line="enable Auto mode for source folder $SOURCE_FOLDER -> movies"
    fi

    plan "download Debian 12 LXC template to storage $TEMPLATE_STORAGE if missing (pveam update; pveam download)"
    plan "create CT $CT_ID"
    plan "CT $CT_ID settings: hostname=$CT_HOSTNAME storage=$CT_STORAGE disk=${DISK_GB}GB ram=${RAM_MB}MB cores=$CORES swap=${SWAP_MB}MB unprivileged=1 onboot=1 bridge=$CT_BRIDGE ip=$network"
    plan "start CT $CT_ID"
    plan "wait for CT $CT_ID network"
    plan "apt-get update in CT $CT_ID"
    plan "install CT packages only if missing: python3 python3-venv python3-pip ca-certificates curl"
    plan "create system user usbcopy in CT $CT_ID"
    plan "create Python venv at /opt/usbcopy/venv in CT $CT_ID"
    plan "fetch $REPO_URL@$REPO_REF and install pinned Python requirements in CT $CT_ID"
    plan "copy application files to /opt/usbcopy in CT $CT_ID"
    plan "write /etc/usbcopy/config.toml in CT $CT_ID (port $PORT, default mode review, auto $AUTO_MODE)"
    plan "install and enable usbcopy.service in CT $CT_ID"
    plan "create host directory /srv/usb-ingest"
    plan "create host directory /srv/usbcopy/events"
    if ((DEST_MOVIES_EXISTS == 1)); then
        plan "use existing destination directory $DEST_MOVIES"
    else
        plan "create destination directory $DEST_MOVIES"
    fi
    if ((DEST_SERIES_EXISTS == 1)); then
        plan "use existing destination directory $DEST_SERIES"
    else
        plan "create destination directory $DEST_SERIES"
    fi
    if [[ -n $DEST_EXTRA ]]; then
        if ((DEST_EXTRA_EXISTS == 1)); then
            plan "use existing destination directory $DEST_EXTRA"
        else
            plan "create destination directory $DEST_EXTRA"
        fi
    fi
    plan "stop CT $CT_ID before adding bind mounts"
    plan "add bind mounts to CT $CT_ID: USB root read-only, spool read-write, destinations read-write"
    plan "mount /srv/usb-ingest -> /mnt/usb (read-only)"
    plan "mount /srv/usbcopy/events -> /run/usbcopy/events"
    plan "mount $DEST_MOVIES -> /data/movies"
    plan "mount $DEST_SERIES -> /data/series"
    if [[ -n $DEST_EXTRA ]]; then
        extra_name=${DEST_EXTRA##*/}
        plan "mount $DEST_EXTRA -> /data/$extra_name"
    fi
    plan "start CT $CT_ID after bind mounts"
    plan "install udev rule /etc/udev/rules.d/99-usbcopy.rules"
    plan "install systemd units usbcopy-mount@.service and usbcopy-scan-usb.service"
    plan "reload systemd and udev rules"
    plan "compute the CT mapped UID for usbcopy and chown destination roots and spool"
    plan "verify the usbcopy user can read a source folder and write each destination"
    plan "write install manifest /etc/usbcopy/install-manifest.json"
    plan "back up any modified host files under /etc/usbcopy/backup/<timestamp>"
    plan "health check GET /api/status from the host"
    if ((ADMIN_PASSWORD_GENERATED == 1)); then
        plan "generate the admin password; it will be printed once at the end of a real install"
    else
        plan "use the supplied admin password; it will not be logged"
    fi
    plan "print dashboard URL http://<ct-ip>:$PORT, username admin, log paths, and uninstall command"
    plan "dashboard http://<ct-ip>:$PORT (username admin)"
    plan "$auto_line"
}

main() {
    local forward=()

    parse_args "$@"

    if ((UNINSTALL == 1)); then
        if [[ ! -x $SCRIPT_DIR/uninstall.sh ]]; then
            die "uninstall.sh is not available in this build (expected $SCRIPT_DIR/uninstall.sh); Task 21 provides it"
        fi
        if ((DRY_RUN == 1)); then
            forward+=(--dry-run)
        fi
        if ((ASSUME_YES == 1)); then
            forward+=(--yes)
        fi
        exec "$SCRIPT_DIR/uninstall.sh" "${forward[@]}"
    fi

    validate_install_source
    require_interactive_tty
    log "proxmoxUSBcopy installer"
    log "source: $REPO_URL@$REPO_REF"

    preflight_root
    preflight_commands
    preflight_pve
    preflight_internet
    preflight_storages
    preflight_bridge
    preflight_ct_ids

    collect_answers "$(default_image_storage)" "$(next_free_ct_id)"
    preflight_destinations
    print_plan
    confirm_summary

    if ((DRY_RUN == 1)); then
        log "dry-run complete; no host changes were made"
        exit 0
    fi

    die "real installation is not implemented in this build; re-run with --dry-run"
}

main "$@"
