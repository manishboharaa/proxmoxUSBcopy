#!/usr/bin/env bash
# proxmoxUSBcopy installer.
#
# Checkout mode runs from setup/install.sh. Pipe mode (`curl ... | bash`)
# downloads the repository archive into a temp dir and re-execs that checkout.
set -euo pipefail

REPO_URL="https://github.com/manishboharaa/proxmoxUSBcopy"
REPO_REF="main"

bootstrap_usage() {
    cat <<'EOF'
Usage: install.sh [options]

Install proxmoxUSBcopy on a Proxmox VE host.

  --repo-url URL   Repository to download when run from a pipe
  --ref REF        Branch, tag, or commit to install (default: main)
  --dry-run        Print the plan without changing the host
  --yes            Accept defaults
  --uninstall      Run setup/uninstall.sh
  --destroy-ct     With --uninstall: also stop and destroy the CT
  -h, --help       Show this help

Piped installs need an https:// repository URL (no embedded credentials).
EOF
}

bootstrap_from_pipe() {
    local -a original=("$@")
    local repo_url=$REPO_URL
    local ref=$REPO_REF
    local rest=''
    local authority=''
    local archive_url=''
    local tmp_dir=''
    local archive=''
    local checkout=''
    local status=0

    while (($# > 0)); do
        case "$1" in
            --repo-url)
                (($# >= 2)) || {
                    printf 'install.sh: error: --repo-url requires a value\n' >&2
                    exit 1
                }
                repo_url=$2
                shift 2
                ;;
            --repo-url=*)
                repo_url=${1#*=}
                shift
                ;;
            --ref)
                (($# >= 2)) || {
                    printf 'install.sh: error: --ref requires a value\n' >&2
                    exit 1
                }
                ref=$2
                shift 2
                ;;
            --ref=*)
                ref=${1#*=}
                shift
                ;;
            -h | --help)
                bootstrap_usage
                exit 0
                ;;
            *)
                shift
                ;;
        esac
    done

    case "$repo_url" in
        https://*) ;;
        *)
            printf 'install.sh: error: piped installs require an https:// repository URL; run from the repo folder for http/ssh/git URLs\n' >&2
            exit 1
            ;;
    esac
    [[ $repo_url != -* ]] || {
        printf 'install.sh: error: repository URL must not start with a dash\n' >&2
        exit 1
    }
    [[ $repo_url != *' '* && $repo_url != *$'\n'* && $repo_url != *$'\r'* && $repo_url != *$'\t'* ]] || {
        printf 'install.sh: error: repository URL contains whitespace or control characters\n' >&2
        exit 1
    }
    rest=${repo_url#*://}
    authority=${rest%%/*}
    [[ -n $authority && $rest == */* ]] || {
        printf 'install.sh: error: repository URL must include a host and repository path\n' >&2
        exit 1
    }
    if [[ $authority == *@* ]]; then
        printf 'install.sh: error: repository URL must not embed credentials (user:token@host)\n' >&2
        exit 1
    fi
    repo_path=${rest#*/}
    case "/$repo_path/" in
        */OWNER/* | */owner/* | */'<owner>'/* | */OWNER.git/* | */owner.git/* | */'<owner>.git'/*)
            printf 'install.sh: error: repository URL still contains the OWNER placeholder (OWNER, owner, or <owner>); pass --repo-url with the real repository URL\n' >&2
            exit 1
            ;;
    esac
    [[ -n $ref ]] || {
        printf 'install.sh: error: --ref must not be empty\n' >&2
        exit 1
    }
    [[ $ref =~ ^[A-Za-z0-9._/-]+$ && $ref != *'..'* && $ref != -* ]] || {
        printf 'install.sh: error: --ref contains unsupported characters\n' >&2
        exit 1
    }

    archive_url="${repo_url%.git}/archive/${ref}.tar.gz"
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/usbcopy-bootstrap.XXXXXX") || {
        printf 'install.sh: error: could not create a temporary directory\n' >&2
        exit 1
    }
    archive="$tmp_dir/repo.tar.gz"
    if ! curl -fsSL --max-time 300 -o "$archive" "$archive_url"; then
        rm -rf -- "$tmp_dir"
        printf 'install.sh: error: could not download the repository archive; check network access, --repo-url, and --ref\n' >&2
        exit 1
    fi
    if ! tar -xzf "$archive" -C "$tmp_dir"; then
        rm -rf -- "$tmp_dir"
        printf 'install.sh: error: could not extract the repository archive\n' >&2
        exit 1
    fi
    checkout=$(find "$tmp_dir" -maxdepth 4 -type f -path '*/setup/install.sh' -print -quit)
    if [[ -z $checkout ]]; then
        rm -rf -- "$tmp_dir"
        printf 'install.sh: error: the repository archive does not contain setup/install.sh\n' >&2
        exit 1
    fi
    if USBC_INSTALLER_MODE=bootstrap bash "$checkout" "${original[@]}"; then
        status=0
    else
        status=$?
    fi
    rm -rf -- "$tmp_dir"
    exit "$status"
}

if [[ -z ${BASH_SOURCE[0]:-} || ! -f ${BASH_SOURCE[0]} ]]; then
    bootstrap_from_pipe "$@"
fi

USBC_INSTALLER_MODE=${USBC_INSTALLER_MODE:-checkout}
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
UNINSTALL_DESTROY_CT=0

# The helper files are separate shellcheck inputs; cross-file globals and
# source resolution are expected here.
# shellcheck disable=SC1091,SC2034
source "$LIB_DIR/common.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/preflight.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/prompts.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/ct.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/app.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/host.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/manifest.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/rollback.sh"

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
  --destroy-ct     With --uninstall: also stop and destroy the CT
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
            --destroy-ct)
                UNINSTALL_DESTROY_CT=1
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
}

print_install_result() {
    log "installation complete"
    log "dashboard: http://${CT_IP:-<ct-ip>}:$PORT (username admin)"
    if ((ADMIN_PASSWORD_GENERATED == 1)); then
        log "admin password: use the save-now block printed before the CT was created"
    else
        log "admin password: the value supplied during install"
    fi
    log "logs: pct exec $CT_ID -- journalctl -u usbcopy.service -f"
    log "host logs: journalctl -u 'usbcopy-mount@<device>.service' -f"
    if ((${#USBC_RO_FALLBACK_MOUNTS[@]} > 0)); then
        warn "ro=1 was rejected for ${USBC_RO_FALLBACK_MOUNTS[*]}; the bind is writable at the bind layer, but the host USB source is still mounted read-only"
    fi
    log "$(installer_uninstall_hint)"
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
    if [[ ${USBC_INSTALLER_MODE:-checkout} == bootstrap ]]; then
        plan "fetch $REPO_URL@$REPO_REF and install pinned Python requirements in CT $CT_ID"
    else
        plan "copy the local application tree and install pinned Python requirements in CT $CT_ID"
    fi
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
    plan "mount /srv/usbcopy/events -> /var/lib/usbcopy/events"
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
    plan "health check GET /healthz from the host"
    if ((ADMIN_PASSWORD_GENERATED == 1)); then
        plan "generate the admin password; it will be printed once at the end of a real install"
    else
        plan "use the supplied admin password; it will not be logged"
    fi
    plan "print dashboard URL http://<ct-ip>:$PORT, username admin, log paths, and uninstall command"
    plan "dashboard http://<ct-ip>:$PORT (username admin)"
    plan "$auto_line"
}

run_stage() {
    local stage=$1

    shift
    "$stage" "$@"
    if [[ ${USBC_FAIL_AT:-${FAKE_FAIL_AT:-}} == "$stage" ]]; then
        log "simulated failure at $stage (USBC_FAIL_AT/FAKE_FAIL_AT test hook)"
        return 1
    fi
}

main() {
    local forward=()

    parse_args "$@"

    if ((UNINSTALL_DESTROY_CT == 1 && UNINSTALL == 0)); then
        die "--destroy-ct is only valid with --uninstall"
    fi

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
        if ((UNINSTALL_DESTROY_CT == 1)); then
            forward+=(--destroy-ct)
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

    if noninteractive; then
        collect_answers "$(default_image_storage)" "$(next_free_ct_id)"
        validate_admin_password "$ADMIN_PASSWORD"
        preflight_destinations
    else
        menu_defaults "$(default_image_storage)" "$(next_free_ct_id)"
        while :; do
            show_settings_menu
            if check_destinations; then
                break
            fi
            warn "${USBC_VALIDATE_ERROR}; fix it in the menu (items 9, 10, 11 or 12) and press Enter again"
        done
        validate_admin_password "$ADMIN_PASSWORD"
    fi
    print_plan
    confirm_summary

    if ((DRY_RUN == 1)); then
        log "dry-run complete; no host changes were made"
        exit 0
    fi

    manifest_check_absent
    announce_generated_password
    set -E
    # shellcheck disable=SC2034
    USBC_ERR_HANDLER=rollback_on_error
    trap 'rollback_on_error $?' ERR
    run_stage create_ct
    run_stage install_app
    run_stage configure_host
    run_stage verify_permissions
    run_stage write_manifest
    trap - ERR
    # shellcheck disable=SC2034
    USBC_ERR_HANDLER=''
    print_install_result
}

main "$@"
