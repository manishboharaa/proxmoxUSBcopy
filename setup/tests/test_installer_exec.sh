#!/usr/bin/env bash
# Function-level execution tests for the proxmoxUSBcopy installer.
#
# Everything runs with fakes on PATH and every host path redirected into a
# temp directory. No real CT is created, no host file outside the temp tree is
# touched, and the suite never runs as root.
# shellcheck disable=SC2034,SC2016,SC2317
set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd -- "$REPO_ROOT"

REAL_TAR=$(command -v tar)
export REAL_TAR

FAKES="$REPO_ROOT/setup/tests/fakes"
INSTALL="$REPO_ROOT/setup/install.sh"
LIB_DIR="$REPO_ROOT/setup/lib"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/usbcopy-installer-exec-test.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT

export PATH="$FAKES:$PATH"
export USBC_FAKE_LOG="$WORK/fake.log"
export USBC_APP_SOURCE="$REPO_ROOT/app"
export USBC_USB_INGEST_DIR="$WORK/srv/usb-ingest"
export USBC_SPOOL_DIR="$WORK/srv/usbcopy/events"
export USBC_HOST_LIB_DIR="$WORK/usr/local/lib/usbcopy"
export USBC_UDEV_RULES_DIR="$WORK/etc/udev/rules.d"
export USBC_SYSTEMD_DIR="$WORK/etc/systemd/system"
export USBC_MANIFEST_PATH="$WORK/etc/usbcopy/install-manifest.json"
export USBC_BACKUP_ROOT="$WORK/etc/usbcopy/backup"
export USBC_FAKE_PUSH_DIR="$WORK/pushed"
export USBC_FAKE_STATE_DIR="$WORK/fake-state"
export USBC_NETWORK_RETRIES=1
export USBC_NETWORK_SLEEP=0
export USBC_HEALTH_RETRIES=2
export USBC_HEALTH_SLEEP=0
: >"$USBC_FAKE_LOG"

export PROG=test
export DRY_RUN=0

# shellcheck disable=SC1091
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

DEST_MOVIES="$WORK/media/movies"
DEST_SERIES="$WORK/media/series"
DEST_EXTRA="$WORK/media/other"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    printf 'ok - %s\n' "$*"
}

assert_contains() {
    local needle=$1 haystack=$2 label=${3:-output}
    grep -qF -- "$needle" <<<"$haystack" || fail "$label does not contain: $needle"
}

assert_not_contains() {
    local needle=$1 haystack=$2 label=${3:-output}
    if grep -qF -- "$needle" <<<"$haystack"; then
        fail "$label unexpectedly contains: $needle"
    fi
}

assert_file_contains() {
    local needle=$1 path=$2 label=${3:-file}
    grep -qF -- "$needle" "$path" || fail "$label $path does not contain: $needle"
}

assert_fails_with() {
    local needle=$1
    shift
    local out status=0
    out=$("$@" 2>&1) || status=$?
    ((status != 0)) || fail "command unexpectedly succeeded: $*"
    assert_contains "$needle" "$out" 'failure output'
}

reset_fixtures() {
    DEST_MOVIES="$WORK/media/movies"
    DEST_SERIES="$WORK/media/series"
    DEST_EXTRA="$WORK/media/other"
    CT_ID=101
    CT_HOSTNAME=usbcopy
    CT_STORAGE=local-lvm
    TEMPLATE_STORAGE=local
    DISK_GB=8
    RAM_MB=1024
    CORES=2
    SWAP_MB=512
    NET_MODE=dhcp
    NET_IP=''
    NET_GW=''
    NET_DNS=''
    CT_BRIDGE=vmbr0
    SOURCE_FOLDER=''
    AUTO_MODE=no
    PORT=8088
    ADMIN_PASSWORD='secret123'
    ADMIN_PASSWORD_GENERATED=0
    EXTRA_KEY=''
    CT_IP=''
    CT_TEMPLATE=''
    CT_TEMPLATE_REF=''
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
    USBC_RO_FALLBACK_MOUNTS=()
    USBC_INSTALLER_MODE=checkout
    REPO_URL='https://example.test/example-org/proxmoxUSBcopy'
    REPO_REF='main'
    unset USBC_FAKE_USER_ABSENT USBC_FAKE_PRESENT_PACKAGES
    unset USBC_FAKE_SOURCE_UNREADABLE USBC_FAKE_CT_MISSING_MOUNT
    unset USBC_FAKE_VERIFY_FAIL_PATH USBC_FAKE_USB_ENTRY
    : >"$USBC_FAKE_LOG"
    rm -rf -- "${WORK:?}/media" "${WORK:?}/srv" "${WORK:?}/usr" "${WORK:?}/etc" "${WORK:?}/pushed" "${WORK:?}/fake-state"
}

write_fake_pct_config() {
    local file=$1
    local hostname=${2:-usbcopy}
    {
        printf 'hostname: %s\n' "$hostname"
        printf 'mp0: %s,mp=/mnt/usb,ro=1\n' "$USBC_USB_INGEST_DIR"
        printf 'mp1: %s,mp=/var/lib/usbcopy/events\n' "$USBC_SPOOL_DIR"
        printf 'mp2: %s,mp=/data/movies\n' "$WORK/media/movies"
        printf 'mp3: %s,mp=/data/series\n' "$WORK/media/series"
    } >"$file"
}

export USBC_FAKE_PCT_CONFIG="$WORK/fake-pct-config"

printf '== static checks ==\n'
for script in "$INSTALL" "$LIB_DIR"/*.sh "$REPO_ROOT"/setup/tests/fakes/*; do
    bash -n "$script" || fail "bash -n rejected $script"
done
pass "installer libs and fakes parse with bash -n"

printf '\n== create_ct ==\n'
reset_fixtures
export USBC_FAKE_TEMPLATE_ABSENT=1
export USBC_FAKE_BUSY_PORTS=8088
create_ct >"$WORK/create.out" 2>&1
out=$(<"$WORK/create.out")
log=$(<"$USBC_FAKE_LOG")
assert_contains 'pveam update' "$log" 'fake log'
assert_contains 'pveam download local debian-12-standard_12.7-1_amd64.tar.zst' "$log" 'fake log'
assert_contains 'pct create 101' "$log" 'fake log'
assert_contains '--unprivileged 1' "$log" 'fake log'
assert_contains '--onboot 1' "$log" 'fake log'
assert_contains '--cores 2' "$log" 'fake log'
assert_contains '--memory 1024' "$log" 'fake log'
assert_contains '--swap 512' "$log" 'fake log'
assert_contains '--rootfs local-lvm:8' "$log" 'fake log'
assert_contains '--hostname usbcopy' "$log" 'fake log'
assert_contains '--net0 name=eth0,bridge=vmbr0,ip=dhcp' "$log" 'fake log'
assert_contains 'pct start 101' "$log" 'fake log'
[[ $PORT == 8089 ]] || fail "port fallback did not move 8088 -> 8089 (got $PORT)"
assert_contains 'dashboard port 8088 is already in use' "$out" 'port fallback warning'
pass "create_ct downloads a missing template, creates an unprivileged CT, starts it, and falls back from a busy port"

reset_fixtures
unset USBC_FAKE_TEMPLATE_ABSENT
create_ct
log=$(<"$USBC_FAKE_LOG")
assert_not_contains 'pveam download' "$log" 'fake log'
assert_contains 'pct create 101 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst' "$log" 'fake log'
pass "create_ct reuses an already-downloaded template"

reset_fixtures
NET_MODE=static
NET_IP=10.0.0.5/24
NET_GW=10.0.0.1
NET_DNS=''
create_ct >"$WORK/create-static.out" 2>&1
log=$(<"$USBC_FAKE_LOG")
assert_contains '--net0 name=eth0,bridge=vmbr0,ip=10.0.0.5/24,gw=10.0.0.1' "$log" 'fake log'
assert_contains '--nameserver 10.0.0.1' "$log" 'fake log'
pass "static networking without DNS falls back to the gateway nameserver"

printf '\n== install_app ==\n'
reset_fixtures
unset USBC_FAKE_BUSY_PORTS
PORT=8089
export USBC_FAKE_PRESENT_PACKAGES='python3 ca-certificates'
export USBC_FAKE_USER_ABSENT=1
install_app >"$WORK/install.out" 2>&1
out=$(<"$WORK/install.out")
log=$(<"$USBC_FAKE_LOG")
assert_contains 'apt-get update' "$log" 'fake log'
assert_contains 'DEBIAN_FRONTEND=noninteractive' "$log" 'fake log'
assert_contains 'apt-get install -y --no-install-recommends python3-venv python3-pip curl' "$log" 'fake log'
assert_not_contains 'apt-get install -y --no-install-recommends python3 ' "$log" 'fake log'
assert_contains 'useradd --system' "$log" 'fake log'
assert_contains 'python3 -m venv /opt/usbcopy/venv' "$log" 'fake log'
assert_contains 'pip install' "$log" 'fake log'
assert_contains '-r /opt/usbcopy/requirements.txt' "$log" 'fake log'
assert_contains 'pct push 101' "$log" 'fake log'
assert_contains 'pct exec 101 -- tar -xzf /tmp/usbcopy-app.tar.gz -C /opt/usbcopy' "$log" 'fake log'
assert_contains 'usbcopy.service' "$log" 'fake log'
assert_contains 'systemctl enable usbcopy.service' "$log" 'fake log'
assert_contains 'systemctl start usbcopy.service' "$log" 'fake log'
assert_contains 'chown root:usbcopy /etc/usbcopy/config.toml' "$log" 'fake log'
assert_contains 'chmod 0640 /etc/usbcopy/config.toml' "$log" 'fake log'
assert_contains 'http://10.0.0.50:8089' "$out" 'install output'
assert_contains 'http://10.0.0.50:8089/healthz' "$log" 'fake log'
assert_not_contains '/api/status' "$log" 'fake log'
config="$USBC_FAKE_PUSH_DIR/config.toml"
[[ -f $config ]] || fail "install_app did not push config.toml"
assert_file_contains 'port = 8089' "$config" 'config'
assert_file_contains '[destinations.movies]' "$config" 'config'
assert_file_contains 'path = "/data/movies"' "$config" 'config'
assert_file_contains 'path = "/data/series"' "$config" 'config'
assert_file_contains 'path = "/data/other"' "$config" 'config'
assert_file_contains 'events_dir = "/var/lib/usbcopy/events"' "$config" 'config'
assert_file_contains 'db_path = "/var/lib/usbcopy/usbcopy.db"' "$config" 'config'
assert_file_contains 'session_secret = ' "$config" 'config'
assert_file_contains 'password_hash = "$2b$' "$config" 'config'
PYTHONPATH="$REPO_ROOT/app" python3 - "$config" <<'PYVALIDATE'
from pathlib import Path
import sys

from usbcopy.config import load_config

cfg = load_config(Path(sys.argv[1]))
assert cfg.port == 8089, cfg
assert str(cfg.destinations["movies"].path) == "/data/movies", cfg
assert str(cfg.destinations["series"].path) == "/data/series", cfg
assert str(cfg.destinations["other"].path) == "/data/other", cfg
assert str(cfg.events_dir) == "/var/lib/usbcopy/events", cfg
assert str(cfg.db_path) == "/var/lib/usbcopy/usbcopy.db", cfg
assert str(cfg.mounts_root) == "/mnt/usb", cfg
assert cfg.default_mode == "review", cfg
assert cfg.auto_enabled is False, cfg
PYVALIDATE
unit="$USBC_FAKE_PUSH_DIR/usbcopy.service"
[[ -f $unit ]] || fail "install_app did not push usbcopy.service"
assert_file_contains 'User=usbcopy' "$unit" 'unit'
assert_file_contains 'ExecStart=/opt/usbcopy/venv/bin/python -m usbcopy.main' "$unit" 'unit'
assert_file_contains 'Restart=on-failure' "$unit" 'unit'
pass "install_app installs only missing packages, pushes the app, renders config, and starts a healthy unit"

DEST_MOVIES="$WORK/media/Films"
DEST_SERIES="$WORK/media/TV Shows"
DEST_EXTRA=''
render_config "$WORK/custom-config.toml" '$2b$12$example' 'session-secret'
assert_file_contains 'path = "/data/movies"' "$WORK/custom-config.toml" 'custom config'
assert_file_contains 'path = "/data/series"' "$WORK/custom-config.toml" 'custom config'
assert_not_contains 'path = "/data/Films"' "$(<"$WORK/custom-config.toml")" 'custom config'
PYTHONPATH="$REPO_ROOT/app" python3 - "$WORK/custom-config.toml" <<'PYVALIDATE'
from pathlib import Path
import sys

from usbcopy.config import load_config

cfg = load_config(Path(sys.argv[1]))
assert str(cfg.destinations["movies"].path) == "/data/movies", cfg
assert str(cfg.destinations["series"].path) == "/data/series", cfg
PYVALIDATE
pass "config destinations use the CT mount paths, not the host folder basenames"

reset_fixtures
LONG_PASSWORD=$(printf 'a%.0s' {1..73})
ADMIN_PASSWORD=$LONG_PASSWORD
assert_fails_with '72' install_app
assert_not_contains 'hash_password' "$(<"$USBC_FAKE_LOG")" 'fake log'
pass "passwords longer than 72 UTF-8 bytes are rejected before hashing"

reset_fixtures
ADMIN_PASSWORD=$(printf 'é%.0s' {1..37})
assert_fails_with '72' install_app
pass "the 72-byte cap counts UTF-8 bytes, not characters"

reset_fixtures
ADMIN_PASSWORD='once-secret'
ADMIN_PASSWORD_GENERATED=1
out=$(announce_generated_password 2>&1)
assert_contains 'SAVE THIS ADMIN PASSWORD NOW' "$out" 'password announcement'
assert_contains 'once-secret' "$out" 'password announcement'
pass "the generated password is announced in a clear save-now block"

USBC_INSTALLER_MODE=bootstrap
REPO_URL='https://example.test/example-org/proxmoxUSBcopy'
REPO_REF='main'
out=$(installer_uninstall_hint)
assert_contains '--uninstall' "$out" 'uninstall hint'
assert_contains 'https://example.test/example-org/proxmoxUSBcopy@main' "$out" 'uninstall hint'
assert_not_contains '/tmp' "$out" 'uninstall hint'
USBC_INSTALLER_MODE=checkout
pass "the bootstrap uninstall hint is stable and not a temp checkout path"

printf '\n== configure_host ==\n'
reset_fixtures
mkdir -p -- "$DEST_SERIES" "$USBC_SPOOL_DIR"
printf 'keep me\n' >"$DEST_SERIES/existing.txt"
mkdir -p -- "$USBC_HOST_LIB_DIR"
printf 'OLD HOST SCRIPT\n' >"$USBC_HOST_LIB_DIR/mount-usb.sh"
configure_host
log=$(<"$USBC_FAKE_LOG")
assert_contains "chown 100999:100999 $DEST_MOVIES" "$log" 'fake log'
assert_contains "chown 100999:100999 $DEST_SERIES" "$log" 'fake log'
assert_contains "chown 100999:100999 $DEST_EXTRA" "$log" 'fake log'
assert_contains "chown 100999:100999 $USBC_SPOOL_DIR" "$log" 'fake log'
assert_not_contains 'existing.txt' "$log" 'fake log'
[[ -d $DEST_MOVIES && -d $DEST_SERIES && -d $DEST_EXTRA ]] || fail "destination roots were not created"
[[ -f $DEST_SERIES/existing.txt ]] || fail "existing destination content was removed"
assert_contains 'keep me' "$(<"$DEST_SERIES/existing.txt")" 'existing destination file'
[[ -x $USBC_HOST_LIB_DIR/mount-usb.sh ]] || fail "mount-usb.sh is not executable"
[[ -x $USBC_HOST_LIB_DIR/unmount-usb.sh ]] || fail "unmount-usb.sh is not executable"
[[ -x $USBC_HOST_LIB_DIR/scan-usb.sh ]] || fail "scan-usb.sh is not executable"
[[ -f $USBC_UDEV_RULES_DIR/99-usbcopy.rules ]] || fail "udev rule not installed"
[[ -f $USBC_SYSTEMD_DIR/usbcopy-mount@.service ]] || fail "mount unit not installed"
[[ -f $USBC_SYSTEMD_DIR/usbcopy-scan-usb.service ]] || fail "scan unit not installed"
backup=$(find "$USBC_BACKUP_ROOT" -name mount-usb.sh -print -quit)
[[ -n $backup ]] || fail "pre-existing host script was not backed up"
assert_contains 'OLD HOST SCRIPT' "$(<"$backup")" 'backup'
assert_file_contains 'proxmoxUSBcopy: mount one USB' "$USBC_HOST_LIB_DIR/mount-usb.sh" 'installed script'
assert_contains "mount --bind $USBC_USB_INGEST_DIR $USBC_USB_INGEST_DIR" "$log" 'fake log'
assert_contains "mount --make-rshared $USBC_USB_INGEST_DIR" "$log" 'fake log'
assert_contains "findmnt --mountpoint $USBC_USB_INGEST_DIR" "$log" 'fake log'
assert_contains 'findmnt -no PROPAGATION' "$log" 'fake log'
assert_contains "findmnt --mountpoint $USBC_USB_INGEST_DIR" "$(<"$USBC_FAKE_LOG")" 'fake log'
assert_contains 'pct exec 101 -- findmnt --mountpoint /mnt/usb' "$log" 'fake log'
assert_contains 'pct exec 101 -- findmnt --mountpoint /var/lib/usbcopy/events' "$log" 'fake log'
assert_contains 'systemctl daemon-reload' "$log" 'fake log'
assert_contains 'systemctl enable usbcopy-scan-usb.service' "$log" 'fake log'
assert_contains 'udevadm control --reload-rules' "$log" 'fake log'
assert_contains 'pct stop 101' "$log" 'fake log'
assert_contains 'pct start 101' "$log" 'fake log'
assert_contains "mp0: $USBC_USB_INGEST_DIR" "$log" 'fake log'
: >"$USBC_FAKE_LOG"
add_ct_mount 0 /srv/usb-ingest /mnt/usb ro
assert_contains 'mp0: /srv/usb-ingest' "$(<"$USBC_FAKE_LOG")" 'fake log'
assert_contains "mp1: $USBC_SPOOL_DIR" "$log" 'fake log'
assert_contains "mp2: $DEST_MOVIES" "$log" 'fake log'
assert_contains "mp3: $DEST_SERIES" "$log" 'fake log'
assert_contains "mp4: $DEST_EXTRA" "$log" 'fake log'
assert_contains "$USBC_USB_INGEST_DIR,mp=/mnt/usb,ro=1" "$log" 'fake log'
[[ " ${USBC_PREEXISTING_DIRS[*]} " == *" $DEST_SERIES "* ]] || fail "existing destination was not recorded as pre-existing"
[[ " ${USBC_PREEXISTING_DIRS[*]} " == *" $USBC_SPOOL_DIR "* ]] || fail "existing spool was not recorded as pre-existing"
[[ " ${USBC_CREATED_DIRS[*]} " != *" $USBC_SPOOL_DIR "* ]] || fail "pre-existing spool was recorded as created"
[[ " ${USBC_CREATED_DIRS[*]} " == *" $DEST_MOVIES "* ]] || fail "created Movies destination was not recorded"
assert_contains 'self-bind' "${USBC_HOST_MOUNTS[0]}" 'host mounts'
assert_contains 'true' "${USBC_HOST_MOUNTS[0]}" 'host mounts'
assert_contains 'shared' "${USBC_HOST_MOUNTS[0]}" 'host mounts'
pass "configure_host creates/chowns only destination roots, installs/backs up host assets, and binds mounts"

: >"$USBC_FAKE_LOG"
export USBC_FAKE_PCT_SET_RO_FAIL=1
add_ct_mount 0 "$USBC_USB_INGEST_DIR" /mnt/usb ro
unset USBC_FAKE_PCT_SET_RO_FAIL
log=$(<"$USBC_FAKE_LOG")
assert_contains "$USBC_USB_INGEST_DIR,mp=/mnt/usb,ro=1" "$log" 'fake log'
assert_contains "$USBC_USB_INGEST_DIR,mp=/mnt/usb" "$log" 'fake log'
pass "a rejected ro=1 bind mount falls back to a plain bind (host source is already read-only)"
assert_contains "$USBC_USB_INGEST_DIR" "${USBC_RO_FALLBACK_MOUNTS[0]}" 'fallback mounts'
assert_contains 'ro' "${USBC_MOUNTS[-1]}" 'fallback manifest'
assert_contains 'rw' "${USBC_MOUNTS[-1]}" 'fallback manifest'

reset_fixtures
DEST_MOVIES=/etc
assert_fails_with 'protected host path' configure_host
assert_not_contains 'chown' "$(<"$USBC_FAKE_LOG")" 'fake log'
assert_not_contains 'pct exec' "$(<"$USBC_FAKE_LOG")" 'fake log'
pass "configure_host repeats the protected-path check before any CT or chown call"

reset_fixtures
configure_host >/dev/null 2>&1
[[ " ${USBC_CREATED_DIRS[*]} " == *" $USBC_HOST_LIB_DIR "* ]] \
    || fail "configure_host did not record $USBC_HOST_LIB_DIR as created"
pass "configure_host records /usr/local/lib/usbcopy as a created directory"

printf '\n== verify_permissions ==\n'
reset_fixtures
export USBC_FAKE_USB_ENTRY=''
out=$(verify_permissions 2>&1)
log=$(<"$USBC_FAKE_LOG")
assert_contains 'verify_permissions' "$log" 'fake log'
assert_contains 'no USB drive is mounted' "$out" 'verify output'
assert_contains 'runuser -u usbcopy' "$log" 'fake log'
assert_contains '.usbcopy-permission-test' "$log" 'fake log'
assert_contains '/data/movies' "$log" 'fake log'
assert_contains '/data/series' "$log" 'fake log'
assert_contains '/data/other' "$log" 'fake log'
assert_contains '/var/lib/usbcopy/events' "$log" 'fake log'
assert_contains 'findmnt --mountpoint /mnt/usb' "$log" 'fake log'
assert_contains 'findmnt --mountpoint /var/lib/usbcopy/events' "$log" 'fake log'
assert_not_contains 'chown' "$log" 'fake log'
assert_not_contains 'chmod' "$log" 'fake log'
pass "verify_permissions checks both binds and probes every destination plus the spool as usbcopy"

: >"$USBC_FAKE_LOG"
export USBC_FAKE_USB_ENTRY='DCIM'
out=$(verify_permissions 2>&1)
assert_contains 'find /mnt/usb' "$(<"$USBC_FAKE_LOG")" 'fake log'
assert_not_contains 'no USB drive is mounted' "$out" 'verify output'
pass "verify_permissions reads the mounted source when a drive is present"

export USBC_FAKE_SOURCE_UNREADABLE=1
out=$(verify_permissions 2>&1)
assert_contains 'cannot read /mnt/usb' "$out" 'verify output'
unset USBC_FAKE_SOURCE_UNREADABLE
pass "a source read failure is reported instead of being masked by a pipeline"

export USBC_FAKE_VERIFY_FAIL_DEST='/data/movies'
assert_fails_with 'cannot create/delete files in /data/movies' verify_permissions
unset USBC_FAKE_VERIFY_FAIL_DEST
pass "a destination the app cannot write to fails the install clearly"

export USBC_FAKE_VERIFY_FAIL_PATH='/var/lib/usbcopy/events'
assert_fails_with 'cannot create/delete files in the event spool' verify_permissions
unset USBC_FAKE_VERIFY_FAIL_PATH
pass "a spool the app cannot write to fails the install clearly"

export USBC_FAKE_CT_MISSING_MOUNT='/var/lib/usbcopy/events'
assert_fails_with 'required bind mount is missing' verify_permissions
unset USBC_FAKE_CT_MISSING_MOUNT
pass "a missing spool bind mount fails the install clearly"

printf '\n== manifest ==\n'
reset_fixtures
PORT=8089
CT_TEMPLATE_REF='local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst'
CT_TEMPLATE='debian-12-standard_12.7-1_amd64.tar.zst'
USBC_INSTALLED_FILES=("$USBC_HOST_LIB_DIR/mount-usb.sh")
USBC_CONTAINER_FILES=('/etc/usbcopy/config.toml' '/etc/systemd/system/usbcopy.service')
USBC_CREATED_DIRS=("$DEST_MOVIES" "$USBC_USB_INGEST_DIR")
USBC_PREEXISTING_DIRS=("$DEST_SERIES")
USBC_CONTAINER_DIRS=('/mnt/usb' '/data/movies')
USBC_INSTALLED_UNITS=("$USBC_SYSTEMD_DIR/usbcopy-mount@.service")
USBC_CONTAINER_UNITS=('usbcopy.service')
USBC_INSTALLED_UDEV=("$USBC_UDEV_RULES_DIR/99-usbcopy.rules")
USBC_BACKUP_FILES=("$USBC_BACKUP_ROOT/stamp/usr/local/lib/usbcopy/mount-usb.sh")
USBC_BACKUP_TARGETS=("$USBC_HOST_LIB_DIR/mount-usb.sh"$'\t'"${USBC_BACKUP_FILES[0]}")
USBC_HOST_MOUNTS=("$USBC_USB_INGEST_DIR"$'\t'self-bind$'\t'true$'\t'private$'\t'shared)
USBC_INSTALLER_MODE=checkout
SCRIPT_DIR="$REPO_ROOT/setup"
manifest_add_mount 0 "$USBC_USB_INGEST_DIR" /mnt/usb ro ro
manifest_add_mount 2 "$DEST_MOVIES" /data/movies rw rw
manifest_add_mount 3 "$DEST_EXTRA" /data/other ro rw
write_manifest
[[ -f $USBC_MANIFEST_PATH ]] || fail "write_manifest did not create $USBC_MANIFEST_PATH"
python3 - "$USBC_MANIFEST_PATH" "$DEST_MOVIES" "$DEST_SERIES" "$DEST_EXTRA" "$USBC_USB_INGEST_DIR" <<'PY'
import json
import os
import sys

path, movies, series, extra, usb = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
assert data["ct_id"] == 101, data
assert data["port"] == 8089, data
assert data["template"] == "local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst", data
assert data["storages"] == {"container": "local-lvm", "template": "local"}, data
assert data["bridge"] == "vmbr0", data
assert data["resources"]["ram_mb"] == 1024, data
assert data["resources"]["unprivileged"] is True, data
assert data["destinations"]["movies"]["host_path"] == movies, data
assert data["destinations"]["movies"]["ct_path"] == "/data/movies", data
assert data["destinations"]["series"]["ct_path"] == "/data/series", data
assert data["extra"]["host_path"] == extra, data
assert data["extra"]["ct_path"] == "/data/other", data
assert data["mounts"][0] == {
    "slot": "mp0",
    "host_path": usb,
    "ct_path": "/mnt/usb",
    "read_only_requested": True,
    "read_only_effective": True,
    "read_only": True,
    "access": "ro",
}, data["mounts"]
assert data["mounts"][1]["read_only"] is False, data["mounts"]
assert data["mounts"][2]["read_only_requested"] is True, data["mounts"]
assert data["mounts"][2]["read_only_effective"] is False, data["mounts"]
assert data["mounts"][2]["access"] == "rw", data["mounts"]
assert data["host_files"] == ["%s/mount-usb.sh" % os.environ["USBC_HOST_LIB_DIR"]], data
assert data["container_files"] == [
    "/etc/usbcopy/config.toml",
    "/etc/systemd/system/usbcopy.service",
], data
assert data["host_dirs"], data
assert data["pre_existing_dirs"] == [series], data
assert data["container_dirs"], data
assert data["host_units"], data
assert data["container_units"] == ["usbcopy.service"], data
assert data["host_mounts"] == [{
    "path": usb,
    "type": "self-bind",
    "self_bind_created": True,
    "propagation_before": "private",
    "propagation_after": "shared",
}], data["host_mounts"]
assert data["installer"]["mode"] == "checkout", data
assert data["installer"]["repo_url"].startswith("https://"), data
assert data["installer"]["checkout"].endswith("/setup"), data
assert "/etc/systemd/system/usbcopy.service" in data["files"], data["files"]
assert data["units"], data
assert data["udev"], data
assert data["backups"], data
assert data["backup_root"] == os.environ["USBC_BACKUP_ROOT"], data
assert data["backup_targets"] == [{
    "target": "%s/mount-usb.sh" % os.environ["USBC_HOST_LIB_DIR"],
    "backup": os.environ["USBC_BACKUP_ROOT"] + "/stamp/usr/local/lib/usbcopy/mount-usb.sh",
}], data
assert data["installed_at"].endswith("Z"), data
PY
pass "write_manifest emits the required install metadata with escaped JSON"

assert_fails_with 'already installed; uninstall/repair first' manifest_check_absent
pass "an existing manifest aborts with the repair/uninstall message"

rm -f -- "$USBC_MANIFEST_PATH"
DRY_RUN=1
out=$(write_manifest 2>&1)
DRY_RUN=0
assert_contains 'PLAN: write install manifest' "$out" 'dry-run output'
[[ ! -e $USBC_MANIFEST_PATH ]] || fail "dry-run wrote a manifest"
pass "write_manifest is a no-op in dry-run"

printf '\n== bootstrap (curl | bash) ==\n'
BOOT_SRC="$WORK/bootstrap-src/proxmoxUSBcopy-main"
mkdir -p -- "$BOOT_SRC/setup"
cat >"$BOOT_SRC/setup/install.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"${BOOT_ARGS_FILE:?}"
printf '%s\n' "${USBC_INSTALLER_MODE:-unset}" >"${BOOT_MODE_FILE:?}"
printf 'bootstrap checkout ran\n'
STUB
chmod +x "$BOOT_SRC/setup/install.sh"
"$REAL_TAR" -C "$WORK/bootstrap-src" -czf "$WORK/repo.tar.gz" proxmoxUSBcopy-main
: >"$USBC_FAKE_LOG"
out=$(USBC_FAKE_CURL_ARCHIVE="$WORK/repo.tar.gz" BOOT_ARGS_FILE="$WORK/boot-args" \
    BOOT_MODE_FILE="$WORK/boot-mode" \
    bash -s -- --dry-run --yes --repo-url https://example.test/example-org/proxmoxUSBcopy --ref main \
    <"$INSTALL" 2>&1)
assert_contains 'bootstrap checkout ran' "$out" 'bootstrap output'
args=$(<"$WORK/boot-args")
assert_contains 'bootstrap' "$(<"$WORK/boot-mode")" 'bootstrap mode'
assert_contains '--dry-run' "$args" 'bootstrap args'
assert_contains '--yes' "$args" 'bootstrap args'
assert_contains '--repo-url' "$args" 'bootstrap args'
assert_contains '--ref' "$args" 'bootstrap args'
assert_contains 'https://example.test/example-org/proxmoxUSBcopy/archive/main.tar.gz' "$(<"$USBC_FAKE_LOG")" 'fake log'
pass "piped install downloads the archive and re-execs the checkout with the original args"

out=$(bash -s -- --repo-url https://user:token123@example.test/example-org/repo.git <"$INSTALL" 2>&1) \
    && status=0 || status=$?
((status != 0)) || fail "credential-bearing bootstrap URL was accepted"
assert_contains 'must not embed credentials' "$out" 'bootstrap failure'
assert_not_contains 'token123' "$out" 'bootstrap failure'
pass "piped install rejects credentials without echoing them"

out=$(bash <"$INSTALL" 2>&1) && status=0 || status=$?
((status != 0)) || fail "OWNER placeholder bootstrap URL was accepted"
assert_contains 'OWNER placeholder' "$out" 'bootstrap failure'
pass "piped install rejects the default OWNER placeholder"

for placeholder in '<owner>' OWNER owner; do
    out=$(bash -s -- --repo-url "https://example.test/$placeholder/proxmoxUSBcopy" \
        <"$INSTALL" 2>&1) && status=0 || status=$?
    ((status != 0)) || fail "bootstrap URL with $placeholder placeholder was accepted"
    assert_contains 'OWNER placeholder' "$out" 'bootstrap failure'
    assert_contains 'pass --repo-url' "$out" 'bootstrap failure'
done
pass "piped install rejects <owner>, OWNER, and owner placeholders"

out=$(USBC_FAKE_CURL_FAIL=1 bash -s -- --repo-url https://example.test/example-org/proxmoxUSBcopy \
    <"$INSTALL" 2>&1) && status=0 || status=$?
((status != 0)) || fail "bootstrap without a downloadable archive unexpectedly succeeded"
assert_contains 'could not download the repository archive' "$out" 'bootstrap failure'
pass "piped install fails clearly when the archive cannot be fetched"

printf '\n== automatic rollback ==\n'
reset_fixtures
mkdir -p -- "$USBC_HOST_LIB_DIR" "$WORK/media"
write_fake_pct_config "$USBC_FAKE_PCT_CONFIG"
printf 'OLD HOST SCRIPT\n' >"$USBC_HOST_LIB_DIR/mount-usb.sh"
ROLLBACK_ANSWERS="101 usbcopy local-lvm 8 1024 2 dhcp $WORK/media/movies $WORK/media/series '' '' no 8088 secret123"
out=$(USBC_ANSWERS="$ROLLBACK_ANSWERS" USBC_TEST_MODE=1 FAKE_FAIL_AT=configure_host \
    "$INSTALL" --yes 2>&1) && status=0 || status=$?
((status != 0)) || fail "installer with a simulated failure unexpectedly succeeded"
assert_contains 'Roll back' "$out" 'rollback output'
log=$(<"$USBC_FAKE_LOG")
assert_contains 'pct create 101' "$log" 'fake log'
assert_contains 'pct destroy 101' "$log" 'fake log'
assert_not_contains 'pct destroy 100' "$log" 'fake log'
assert_contains 'systemctl daemon-reload' "$log" 'fake log'
assert_contains 'udevadm control --reload-rules' "$log" 'fake log'
assert_contains 'umount ' "$log" 'fake log'
[[ ! -e $USBC_MANIFEST_PATH ]] || fail "rollback left a manifest behind"
[[ ! -e $USBC_UDEV_RULES_DIR/99-usbcopy.rules ]] || fail "rollback left the udev rule behind"
[[ ! -e $USBC_SYSTEMD_DIR/usbcopy-mount@.service ]] || fail "rollback left the mount unit behind"
[[ ! -e $USBC_SYSTEMD_DIR/usbcopy-scan-usb.service ]] || fail "rollback left the scan unit behind"
[[ ! -e $USBC_SPOOL_DIR ]] || fail "rollback left a created directory behind"
[[ -f $USBC_HOST_LIB_DIR/mount-usb.sh ]] || fail "rollback did not restore the backed-up host script"
assert_contains 'OLD HOST SCRIPT' "$(<"$USBC_HOST_LIB_DIR/mount-usb.sh")" 'restored host script'
assert_contains "Kept destination data: $WORK/media/movies" "$out" 'rollback output'
pass "rollback removes host wiring, restores backups, and destroys only the CT created by the run"

reset_fixtures
mkdir -p -- "$WORK/media"
write_fake_pct_config "$USBC_FAKE_PCT_CONFIG"
out=$(USBC_ANSWERS="$ROLLBACK_ANSWERS" USBC_TEST_MODE=1 FAKE_FAIL_AT=write_manifest \
    "$INSTALL" --yes 2>&1) && status=0 || status=$?
((status != 0)) || fail "installer with a simulated write_manifest failure unexpectedly succeeded"
assert_contains 'Roll back' "$out" 'rollback output'
assert_contains 'pct destroy 101' "$(<"$USBC_FAKE_LOG")" 'fake log'
[[ ! -e $USBC_MANIFEST_PATH ]] || fail "rollback left the manifest behind"
pass "rollback removes a manifest written by the failing stage"

reset_fixtures
mkdir -p -- "$WORK/media"
write_fake_pct_config "$USBC_FAKE_PCT_CONFIG"
export USBC_FAKE_UMOUNT_FAIL=1
out=$(USBC_ANSWERS="$ROLLBACK_ANSWERS" USBC_TEST_MODE=1 FAKE_FAIL_AT=write_manifest \
    "$INSTALL" --yes 2>&1) && status=0 || status=$?
unset USBC_FAKE_UMOUNT_FAIL
((status != 0)) || fail "rollback with a cleanup failure unexpectedly succeeded"
assert_contains 'keeping install manifest' "$out" 'rollback cleanup failure output'
[[ -f $USBC_MANIFEST_PATH ]] || fail "rollback with a cleanup failure removed the manifest"
pass "a rollback cleanup failure keeps the manifest for recovery"

reset_fixtures
mkdir -p -- "$WORK/media"
write_fake_pct_config "$USBC_FAKE_PCT_CONFIG"
out=$(USBC_ANSWERS="$ROLLBACK_ANSWERS" USBC_TEST_MODE=1 USBC_FAIL_AT=unused USBC_FAKE_ID_FAIL=1 \
    "$INSTALL" --yes 2>&1) && status=0 || status=$?
((status != 0)) || fail "installer with a failing mapped-ID lookup unexpectedly succeeded"
assert_contains 'Roll back' "$out" 'rollback output'
rollback_log=$(<"$USBC_FAKE_LOG")
assert_contains 'pct destroy 101' "$rollback_log" 'fake log'
destroy_count=$(grep -cF 'pct destroy 101' <<<"$rollback_log")
[[ $destroy_count == 1 ]] || fail "a real die failure rolled back $destroy_count times"
pass "a real die failure triggers exactly one rollback"

: >"$USBC_FAKE_LOG"
RB_CT_ID=101
RB_CT_HOSTNAME=usbcopy
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
RB_BACKUP_TARGETS=()
RB_BACKUP_ROOT=''
RB_MOUNTS=()
RB_HOST_MOUNTS=()
RB_DEST_HOSTS=()
RB_DEST_CT_PATHS=()
RB_INCOMPLETE=()
RB_FAILURES=0
unset USBC_FAKE_PCT_CONFIG
export USBC_FAKE_CT_STOPPED=1
out=$(rb_execute_rollback 2>&1)
unset USBC_FAKE_CT_STOPPED
export USBC_FAKE_PCT_CONFIG="$WORK/fake-pct-config"
assert_contains 'was not created by this run' "$out" 'rollback output'
assert_not_contains 'pct destroy' "$(<"$USBC_FAKE_LOG")" 'fake log'
pass "rollback keeps a CT it did not create"

DECLINE_ROOT="$WORK/rollback-decline"
mkdir -p -- "$DECLINE_ROOT/etc/udev/rules.d"
printf 'rule\n' >"$DECLINE_ROOT/etc/udev/rules.d/99-usbcopy.rules"
decline_out=$(
    set +e
    read_tty() { printf 'no'; }
    PROG='test'
    DRY_RUN=0
    ASSUME_YES=0
    CT_ID=101
    CT_CREATED=1
    DEST_MOVIES="$DECLINE_ROOT/movies"
    DEST_SERIES="$DECLINE_ROOT/series"
    DEST_EXTRA=''
    USBC_INSTALLED_UDEV=("$DECLINE_ROOT/etc/udev/rules.d/99-usbcopy.rules")
    USBC_INSTALLED_FILES=()
    USBC_CREATED_DIRS=()
    USBC_CONTAINER_FILES=()
    USBC_CONTAINER_DIRS=()
    USBC_INSTALLED_UNITS=()
    USBC_CONTAINER_UNITS=()
    USBC_BACKUP_FILES=()
    USBC_MOUNTS=()
    USBC_HOST_MOUNTS=()
    rollback_on_error 1
) && decline_status=0 || decline_status=$?
((decline_status != 0)) || fail "declined rollback unexpectedly exited zero"
assert_contains 'rollback declined' "$decline_out" 'decline output'
assert_contains 'kept CT 101' "$decline_out" 'decline output'
[[ -f $DECLINE_ROOT/etc/udev/rules.d/99-usbcopy.rules ]] || fail "declined rollback removed host state"
pass "declined rollback leaves state in place and exits non-zero"

printf '\n== uninstall ==\n'
write_uninstall_fixture() {
    local root=$1
    local host_lib="$root/usr/local/lib/usbcopy"
    local udev="$root/etc/udev/rules.d"
    local systemd="$root/etc/systemd/system"
    local manifest="$root/etc/usbcopy/install-manifest.json"
    local backup_root="$root/etc/usbcopy/backup"
    local backup="$backup_root/20260101T000000Z${host_lib}/mount-usb.sh"

    mkdir -p -- "$host_lib" "$udev" "$systemd" "$backup_root" "${backup%/*}" \
        "$root/srv/usb-ingest" "$root/srv/usbcopy/events" \
        "$root/media/movies" "$root/media/series"
    printf 'NEW HOST SCRIPT\n' >"$host_lib/mount-usb.sh"
    printf 'OLD HOST SCRIPT\n' >"$backup"
    printf 'unit\n' >"$systemd/usbcopy-mount@.service"
    printf 'unit\n' >"$systemd/usbcopy-scan-usb.service"
    printf 'rule\n' >"$udev/99-usbcopy.rules"
    printf 'movie data\n' >"$root/media/movies/keep.mkv"
    printf 'series data\n' >"$root/media/series/keep.s01e01.mkv"
    {
        printf 'hostname: usbcopy\n'
        printf 'mp0: %s,mp=/mnt/usb,ro=1\n' "$root/srv/usb-ingest"
        printf 'mp1: %s,mp=/var/lib/usbcopy/events\n' "$root/srv/usbcopy/events"
        printf 'mp2: %s,mp=/data/movies\n' "$root/media/movies"
        printf 'mp3: %s,mp=/data/series\n' "$root/media/series"
    } >"$root/pct-config"

    python3 - "$manifest" "$root" <<'PYFIXTURE'
import json
import sys

manifest, root = sys.argv[1], sys.argv[2]
host_lib = f"{root}/usr/local/lib/usbcopy"
udev = f"{root}/etc/udev/rules.d"
systemd = f"{root}/etc/systemd/system"
payload = {
    "version": 1,
    "ct_id": 101,
    "hostname": "usbcopy",
    "host_files": [f"{host_lib}/mount-usb.sh"],
    "container_files": [
        "/etc/usbcopy/config.toml",
        "/etc/systemd/system/usbcopy.service",
    ],
    "host_dirs": [
        f"{root}/srv/usb-ingest",
        f"{root}/srv/usbcopy/events",
        f"{root}/media/movies",
        f"{root}/media/series",
    ],
    "pre_existing_dirs": [],
    "container_dirs": [
        "/opt/usbcopy",
        "/var/lib/usbcopy",
        "/etc/usbcopy",
        "/mnt/usb",
        "/data",
        "/data/movies",
        "/data/series",
    ],
    "host_units": [
        f"{systemd}/usbcopy-mount@.service",
        f"{systemd}/usbcopy-scan-usb.service",
    ],
    "container_units": ["usbcopy.service"],
    "udev": [f"{udev}/99-usbcopy.rules"],
    "mounts": [
        {"slot": "mp0", "host_path": f"{root}/srv/usb-ingest", "ct_path": "/mnt/usb"},
        {"slot": "mp1", "host_path": f"{root}/srv/usbcopy/events", "ct_path": "/var/lib/usbcopy/events"},
        {"slot": "mp2", "host_path": f"{root}/media/movies", "ct_path": "/data/movies"},
        {"slot": "mp3", "host_path": f"{root}/media/series", "ct_path": "/data/series"},
    ],
    "host_mounts": [{
        "path": f"{root}/srv/usb-ingest",
        "type": "self-bind",
        "self_bind_created": True,
        "propagation_before": "private",
        "propagation_after": "shared",
    }],
    "backups": [f"{root}/etc/usbcopy/backup/20260101T000000Z{host_lib}/mount-usb.sh"],
    "backup_root": f"{root}/etc/usbcopy/backup",
    "backup_targets": [{
        "target": f"{host_lib}/mount-usb.sh",
        "backup": f"{root}/etc/usbcopy/backup/20260101T000000Z{host_lib}/mount-usb.sh",
    }],
    "destinations": {
        "movies": {"host_path": f"{root}/media/movies", "ct_path": "/data/movies"},
        "series": {"host_path": f"{root}/media/series", "ct_path": "/data/series"},
    },
    "extra": None,
}
with open(manifest, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PYFIXTURE
}

uninstall_case() {
    local root=$1
    shift
    rm -f -- "${USBC_FAKE_STATE_DIR:-/nonexistent}/ct-running" "${USBC_FAKE_STATE_DIR:-/nonexistent}/ct-stopped"
    env -u USBC_BACKUP_ROOT \
        USBC_MANIFEST_PATH="$root/etc/usbcopy/install-manifest.json" \
        USBC_HOST_LIB_DIR="$root/usr/local/lib/usbcopy" \
        USBC_UDEV_RULES_DIR="$root/etc/udev/rules.d" \
        USBC_SYSTEMD_DIR="$root/etc/systemd/system" \
        USBC_USB_INGEST_DIR="$root/srv/usb-ingest" \
        USBC_SPOOL_DIR="$root/srv/usbcopy/events" \
        USBC_FAKE_PCT_CONFIG="$root/pct-config" \
        USBC_FAKE_MOUNTPOINTS="$root/srv/usb-ingest" \
        USBC_TEST_MODE=1 \
        USBC_FAIL_AT=unused \
        "$UNINSTALL" "$@"
}

UNINSTALL="$REPO_ROOT/setup/uninstall.sh"
UN_ROOT="$WORK/uninstall"
write_uninstall_fixture "$UN_ROOT"
python3 - "$UN_ROOT/etc/usbcopy/install-manifest.json" <<'PYCTID'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["ct_id"] == 101, data
PYCTID
: >"$USBC_FAKE_LOG"
out=$(uninstall_case "$UN_ROOT" --yes 2>&1)
log=$(<"$USBC_FAKE_LOG")
assert_contains "Kept destination data: $UN_ROOT/media/movies" "$out" 'uninstall output'
assert_contains "Kept destination data: $UN_ROOT/media/series" "$out" 'uninstall output'
assert_contains 'Kept CT 101' "$out" 'uninstall output'
assert_contains 'pct stop 101' "$log" 'fake log'
assert_contains 'pct start 101' "$log" 'fake log'
assert_contains 'pct set 101 -delete mp0' "$log" 'fake log'
assert_contains 'pct exec 101 -- rm -f -- /etc/usbcopy/config.toml' "$log" 'fake log'
assert_contains 'pct exec 101 -- rm -rf -- /opt/usbcopy' "$log" 'fake log'
assert_contains 'pct exec 101 -- systemctl daemon-reload' "$log" 'fake log'
assert_not_contains 'pct destroy' "$log" 'fake log'
assert_contains 'umount ' "$log" 'fake log'
[[ -f $UN_ROOT/media/movies/keep.mkv ]] || fail "uninstall removed destination contents"
[[ -f $UN_ROOT/media/series/keep.s01e01.mkv ]] || fail "uninstall removed destination contents"
[[ ! -e $UN_ROOT/etc/udev/rules.d/99-usbcopy.rules ]] || fail "uninstall left the udev rule behind"
[[ ! -e $UN_ROOT/etc/systemd/system/usbcopy-mount@.service ]] || fail "uninstall left a host unit behind"
[[ ! -e $UN_ROOT/etc/usbcopy/install-manifest.json ]] || fail "uninstall left the manifest behind"
[[ ! -e $UN_ROOT/srv/usbcopy/events ]] || fail "uninstall left a created directory behind"
assert_contains 'OLD HOST SCRIPT' "$(<"$UN_ROOT/usr/local/lib/usbcopy/mount-usb.sh")" 'restored host script'
pass "default uninstall removes host wiring and app payload, restores backups without USBC_BACKUP_ROOT, and keeps the CT and destination data"

UN_ROOT="$WORK/uninstall-destroy"
write_uninstall_fixture "$UN_ROOT"
: >"$USBC_FAKE_LOG"
out=$(uninstall_case "$UN_ROOT" --yes --destroy-ct 2>&1)
log=$(<"$USBC_FAKE_LOG")
assert_contains 'pct destroy 101' "$log" 'fake log'
stop_line=$(grep -nF 'pct stop 101' <<<"$log" | head -n 1 | cut -d: -f1)
destroy_line=$(grep -nF 'pct destroy 101' <<<"$log" | head -n 1 | cut -d: -f1)
[[ -n $stop_line && -n $destroy_line ]] || fail "destroy-ct did not stop and destroy the CT"
((stop_line < destroy_line)) || fail "destroy-ct destroyed before stopping the CT"
[[ -f $UN_ROOT/media/movies/keep.mkv ]] || fail "destroy-ct removed destination contents"
pass "--destroy-ct stops the CT before destroying it and keeps destination data"

UN_ROOT="$WORK/uninstall-stuck-mount"
write_uninstall_fixture "$UN_ROOT"
: >"$USBC_FAKE_LOG"
export USBC_FAKE_CT_MOUNT_STUCK='/data/movies'
out=$(uninstall_case "$UN_ROOT" --yes 2>&1) && status=0 || status=$?
unset USBC_FAKE_CT_MOUNT_STUCK
((status != 0)) || fail "uninstall with a stuck bind mount unexpectedly exited zero"
assert_contains 'kept application directories' "$out" 'stuck-mount output'
assert_contains 'keeping install manifest' "$out" 'stuck-mount output'
[[ -f $UN_ROOT/etc/usbcopy/install-manifest.json ]] || fail "stuck-mount uninstall removed the manifest"
if grep -qF 'rm -rf -- /opt/usbcopy' "$USBC_FAKE_LOG"; then
    fail "uninstall removed container directories while a bind mount was still present"
fi
[[ -f $UN_ROOT/media/movies/keep.mkv ]] || fail "stuck-mount uninstall removed destination contents"
pass "a bind mount that cannot be removed stops container directory deletion and keeps the manifest"

UN_ROOT="$WORK/uninstall-dry"
write_uninstall_fixture "$UN_ROOT"
: >"$USBC_FAKE_LOG"
out=$(uninstall_case "$UN_ROOT" --dry-run 2>&1)
assert_contains 'PLAN:' "$out" 'uninstall dry-run'
if grep -Eq '^(pct|systemctl|udevadm|mount|umount|chown) ' "$USBC_FAKE_LOG"; then
    fail "uninstall --dry-run invoked a mutating fake"
fi
[[ -f $UN_ROOT/media/movies/keep.mkv ]] || fail "uninstall --dry-run removed destination contents"
[[ -f $UN_ROOT/etc/usbcopy/install-manifest.json ]] || fail "uninstall --dry-run removed the manifest"
[[ -f $UN_ROOT/etc/udev/rules.d/99-usbcopy.rules ]] || fail "uninstall --dry-run removed the udev rule"
pass "uninstall --dry-run prints the plan and changes nothing"


UN_ROOT="$WORK/uninstall-destroy-fail"
write_uninstall_fixture "$UN_ROOT"
: >"$USBC_FAKE_LOG"
export USBC_FAKE_PCT_DESTROY_FAIL=1
out=$(uninstall_case "$UN_ROOT" --yes --destroy-ct 2>&1) && status=0 || status=$?
unset USBC_FAKE_PCT_DESTROY_FAIL
((status != 0)) || fail "failed destroy unexpectedly exited zero"
assert_contains 'could not destroy CT 101' "$out" 'destroy failure output'
assert_contains 'keeping install manifest' "$out" 'destroy failure output'
[[ -f $UN_ROOT/etc/usbcopy/install-manifest.json ]] || fail "failed destroy removed the manifest"
[[ -f $UN_ROOT/media/movies/keep.mkv ]] || fail "failed destroy removed destination contents"
pass "a failed CT destroy keeps the manifest and destination data"

UN_ROOT="$WORK/uninstall-stopped"
write_uninstall_fixture "$UN_ROOT"
: >"$USBC_FAKE_LOG"
export USBC_FAKE_CT_STOPPED=1
out=$(uninstall_case "$UN_ROOT" --yes 2>&1)
unset USBC_FAKE_CT_STOPPED
log=$(<"$USBC_FAKE_LOG")
start_line=$(grep -nF 'pct start 101' <<<"$log" | head -n 1 | cut -d: -f1)
stop_app_line=$(grep -nF 'pct exec 101 -- systemctl stop usbcopy.service' <<<"$log" | head -n 1 | cut -d: -f1)
[[ -n $start_line && -n $stop_app_line ]] || fail "stopped-CT uninstall did not start the CT and stop the app"
((start_line < stop_app_line)) || fail "stopped-CT uninstall removed payload before stopping the app"
assert_contains 'Kept CT 101 (stopped)' "$out" 'stopped-CT output'
pass "a stopped CT is started, its app disabled, and only then cleaned"

UN_ROOT="$WORK/uninstall-stale-hostname"
write_uninstall_fixture "$UN_ROOT"
write_fake_pct_config "$UN_ROOT/pct-config" other-host
: >"$USBC_FAKE_LOG"
out=$(uninstall_case "$UN_ROOT" --yes 2>&1) && status=0 || status=$?
((status != 0)) || fail "stale hostname manifest unexpectedly succeeded"
assert_contains 'hostname does not match' "$out" 'stale manifest output'
[[ -f $UN_ROOT/etc/usbcopy/install-manifest.json ]] || fail "stale manifest was removed"
[[ -f $UN_ROOT/usr/local/lib/usbcopy/mount-usb.sh ]] || fail "stale manifest cleanup removed host files"
if grep -Eq '^pct (stop|set|exec|destroy) ' "$USBC_FAKE_LOG"; then
    fail "stale hostname manifest mutated the CT"
fi
pass "a stale manifest hostname aborts before any CT mutation and keeps the manifest"

UN_ROOT="$WORK/uninstall-stale-mounts"
write_uninstall_fixture "$UN_ROOT"
grep -v 'mp2: ' "$UN_ROOT/pct-config" >"$UN_ROOT/pct-config.stale"
mv -- "$UN_ROOT/pct-config.stale" "$UN_ROOT/pct-config"
: >"$USBC_FAKE_LOG"
out=$(uninstall_case "$UN_ROOT" --yes 2>&1) && status=0 || status=$?
((status != 0)) || fail "stale mount-source manifest unexpectedly succeeded"
assert_contains 'mount mp2 does not match' "$out" 'stale mount output'
[[ -f $UN_ROOT/etc/usbcopy/install-manifest.json ]] || fail "stale mount manifest was removed"
if grep -Eq '^pct (stop|set|exec|destroy) ' "$USBC_FAKE_LOG"; then
    fail "stale mount manifest mutated the CT"
fi
pass "a stale mount source aborts before any CT mutation and keeps the manifest"

UN_ROOT="$WORK/uninstall-missing-ct"
write_uninstall_fixture "$UN_ROOT"
: >"$USBC_FAKE_LOG"
export USBC_FAKE_CT_MISSING=1
out=$(uninstall_case "$UN_ROOT" --yes 2>&1) && status=0 || status=$?
unset USBC_FAKE_CT_MISSING
((status == 0)) || fail "missing-CT uninstall unexpectedly failed"
assert_contains 'was not found' "$out" 'missing-CT output'
assert_contains 'OLD HOST SCRIPT' "$(<"$UN_ROOT/usr/local/lib/usbcopy/mount-usb.sh")" 'missing-CT host cleanup'
[[ -f $UN_ROOT/etc/udev/rules.d/99-usbcopy.rules ]] && fail "missing-CT uninstall skipped udev cleanup"
[[ ! -e $UN_ROOT/etc/usbcopy/install-manifest.json ]] || fail "missing-CT uninstall left the manifest behind"
pass "a missing CT is distinguished from a query failure and host cleanup still completes"

UN_ROOT="$WORK/uninstall-query-fail"
write_uninstall_fixture "$UN_ROOT"
: >"$USBC_FAKE_LOG"
export USBC_FAKE_CT_QUERY_FAIL=1
out=$(uninstall_case "$UN_ROOT" --yes 2>&1) && status=0 || status=$?
unset USBC_FAKE_CT_QUERY_FAIL
((status != 0)) || fail "CT query failure unexpectedly exited zero"
assert_contains 'could not query CT 101' "$out" 'query failure output'
assert_contains 'keeping install manifest' "$out" 'query failure output'
[[ -f $UN_ROOT/etc/usbcopy/install-manifest.json ]] || fail "query failure removed the manifest"
assert_contains 'NEW HOST SCRIPT' "$(<"$UN_ROOT/usr/local/lib/usbcopy/mount-usb.sh")" 'query failure host state'
if grep -Eq '^pct (stop|set|exec|destroy) ' "$USBC_FAKE_LOG"; then
    fail "query failure mutated the CT"
fi
pass "a CT query failure aborts before host cleanup and keeps the manifest"

UN_ROOT="$WORK/uninstall-missing-mount-record"
write_uninstall_fixture "$UN_ROOT"
python3 - "$UN_ROOT/etc/usbcopy/install-manifest.json" <<'PYNOMOUNT'
import json
import sys

path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["mounts"] = [mount for mount in data["mounts"] if mount["slot"] != "mp2"]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PYNOMOUNT
: >"$USBC_FAKE_LOG"
out=$(uninstall_case "$UN_ROOT" --yes 2>&1) && status=0 || status=$?
((status != 0)) || fail "missing mount record unexpectedly succeeded"
assert_contains 'no mount record for /data/movies' "$out" 'missing mount output'
[[ -f $UN_ROOT/etc/usbcopy/install-manifest.json ]] || fail "missing mount record removed the manifest"
if grep -qF 'rm -rf -- /opt/usbcopy' "$USBC_FAKE_LOG"; then
    fail "missing mount record allowed container directory removal"
fi
pass "a missing mount record fails closed and keeps the manifest"

UN_ROOT="$WORK/uninstall-findmnt-fail"
write_uninstall_fixture "$UN_ROOT"
: >"$USBC_FAKE_LOG"
export USBC_FAKE_FINDMNT_FAIL=1
out=$(uninstall_case "$UN_ROOT" --yes 2>&1) && status=0 || status=$?
unset USBC_FAKE_FINDMNT_FAIL
((status != 0)) || fail "findmnt failure unexpectedly succeeded"
assert_contains 'findmnt failed while checking CT path' "$out" 'findmnt failure output'
[[ -f $UN_ROOT/etc/usbcopy/install-manifest.json ]] || fail "findmnt failure removed the manifest"
if grep -qF 'rm -rf -- /opt/usbcopy' "$USBC_FAKE_LOG"; then
    fail "findmnt failure allowed container directory removal"
fi
pass "a findmnt error fails closed and keeps the manifest"

UN_ROOT="$WORK/uninstall-parent-mount"
write_uninstall_fixture "$UN_ROOT"
: >"$USBC_FAKE_LOG"
export USBC_FAKE_CT_MOUNT_STUCK='/data'
out=$(uninstall_case "$UN_ROOT" --yes 2>&1) && status=0 || status=$?
unset USBC_FAKE_CT_MOUNT_STUCK
((status != 0)) || fail "parent mount unexpectedly succeeded"
assert_contains 'is on mount' "$out" 'parent mount output'
[[ -f $UN_ROOT/media/movies/keep.mkv ]] || fail "parent mount uninstall removed destination contents"
[[ -f $UN_ROOT/etc/usbcopy/install-manifest.json ]] || fail "parent mount removed the manifest"
pass "a mounted parent directory fails closed and keeps destination data"

UN_ROOT="$WORK/uninstall-umount-fail"
write_uninstall_fixture "$UN_ROOT"
: >"$USBC_FAKE_LOG"
export USBC_FAKE_UMOUNT_FAIL=1
out=$(uninstall_case "$UN_ROOT" --yes 2>&1) && status=0 || status=$?
unset USBC_FAKE_UMOUNT_FAIL
((status != 0)) || fail "self-bind unmount failure unexpectedly succeeded"
assert_contains 'could not unmount self-bind' "$out" 'unmount failure output'
assert_contains 'keeping install manifest' "$out" 'unmount failure output'
[[ -f $UN_ROOT/etc/usbcopy/install-manifest.json ]] || fail "unmount failure removed the manifest"
pass "a self-bind unmount failure is counted and keeps the manifest"

UN_ROOT="$WORK/uninstall-unsafe-paths"
write_uninstall_fixture "$UN_ROOT"
python3 - "$UN_ROOT/etc/usbcopy/install-manifest.json" <<'PYUNSAFE'
import json
import sys

path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["host_files"].append("/etc/passwd")
data["container_dirs"].append("/etc")
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PYUNSAFE
: >"$USBC_FAKE_LOG"
out=$(uninstall_case "$UN_ROOT" --yes 2>&1) && status=0 || status=$?
((status != 0)) || fail "unsafe manifest paths unexpectedly succeeded"
assert_contains 'refusing to remove unsafe host file' "$out" 'unsafe path output'
assert_contains 'refusing unsafe container directory path' "$out" 'unsafe path output'
assert_contains 'keeping install manifest' "$out" 'unsafe path output'
[[ -f $UN_ROOT/etc/usbcopy/install-manifest.json ]] || fail "unsafe path uninstall removed the manifest"
[[ -f /etc/passwd ]] || fail "unsafe manifest deleted /etc/passwd"
pass "unsafe manifest host and container paths fail closed and keep the manifest"

UN_ROOT="$WORK/uninstall-spool"
write_uninstall_fixture "$UN_ROOT"
printf '{"action":"add"}\n' >"$UN_ROOT/srv/usbcopy/events/pending.json"
out=$(uninstall_case "$UN_ROOT" --yes 2>&1)
assert_contains 'has pending events' "$out" 'spool output'
[[ -f $UN_ROOT/srv/usbcopy/events/pending.json ]] || fail "pending spool events were removed"
pass "pending spool events are kept with an explicit warning"

: >"$USBC_FAKE_LOG"
out=$(env -u USBC_TEST_MODE -u USBC_FAIL_AT -u USBC_BACKUP_ROOT \
    USBC_MANIFEST_PATH="$UN_ROOT/etc/usbcopy/install-manifest.json" \
    "$UNINSTALL" --yes 2>&1) && status=0 || status=$?
((status != 0)) || fail "non-root uninstall unexpectedly succeeded"
assert_contains 'must be run as root' "$out" 'root preflight output'
if grep -Eq '^pct ' "$USBC_FAKE_LOG"; then
    fail "non-root uninstall called pct before the root preflight"
fi
pass "non-dry-run uninstall requires root before touching the CT"

printf '\nAll installer execution tests passed.\n'
