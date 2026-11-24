#!/usr/bin/env bash
# Function-level execution tests for the proxmoxUSBcopy installer.
#
# Everything runs with fakes on PATH and every host path redirected into a
# temp directory. No real CT is created, no host file outside the temp tree is
# touched, and the suite never runs as root.
# shellcheck disable=SC2034,SC2016
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
    USBC_CONTAINER_DIRS=()
    USBC_INSTALLED_UNITS=()
    USBC_INSTALLED_UDEV=()
    USBC_BACKUP_FILES=()
    USBC_MOUNTS=()
    unset USBC_FAKE_USER_ABSENT USBC_FAKE_PRESENT_PACKAGES
    : >"$USBC_FAKE_LOG"
    rm -rf -- "${WORK:?}/media" "${WORK:?}/srv" "${WORK:?}/usr" "${WORK:?}/etc" "${WORK:?}/pushed" "${WORK:?}/fake-state"
}

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
config="$USBC_FAKE_PUSH_DIR/config.toml"
[[ -f $config ]] || fail "install_app did not push config.toml"
assert_file_contains 'port = 8089' "$config" 'config'
assert_file_contains '[destinations.movies]' "$config" 'config'
assert_file_contains 'path = "/data/movies"' "$config" 'config'
assert_file_contains 'path = "/data/series"' "$config" 'config'
assert_file_contains 'path = "/data/other"' "$config" 'config'
assert_file_contains 'events_dir = "/run/usbcopy/events"' "$config" 'config'
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
assert str(cfg.events_dir) == "/run/usbcopy/events", cfg
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

printf '\n== configure_host ==\n'
reset_fixtures
mkdir -p -- "$DEST_SERIES"
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
assert_contains "mount --make-rshared $USBC_USB_INGEST_DIR" "$log" 'fake log'
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
pass "configure_host creates/chowns only destination roots, installs/backs up host assets, and binds mounts"

: >"$USBC_FAKE_LOG"
export USBC_FAKE_PCT_SET_RO_FAIL=1
add_ct_mount 0 "$USBC_USB_INGEST_DIR" /mnt/usb ro
unset USBC_FAKE_PCT_SET_RO_FAIL
log=$(<"$USBC_FAKE_LOG")
assert_contains "$USBC_USB_INGEST_DIR,mp=/mnt/usb,ro=1" "$log" 'fake log'
assert_contains "$USBC_USB_INGEST_DIR,mp=/mnt/usb" "$log" 'fake log'
pass "a rejected ro=1 bind mount falls back to a plain bind (host source is already read-only)"

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
assert_not_contains 'chown' "$log" 'fake log'
assert_not_contains 'chmod' "$log" 'fake log'
pass "verify_permissions warns about an absent drive and probes every destination as usbcopy"

: >"$USBC_FAKE_LOG"
export USBC_FAKE_USB_ENTRY='DCIM'
out=$(verify_permissions 2>&1)
assert_contains 'ls -A /mnt/usb' "$(<"$USBC_FAKE_LOG")" 'fake log'
assert_not_contains 'no USB drive is mounted' "$out" 'verify output'
pass "verify_permissions reads the mounted source when a drive is present"

export USBC_FAKE_VERIFY_FAIL_DEST='/data/movies'
assert_fails_with 'cannot create/delete files in /data/movies' verify_permissions
unset USBC_FAKE_VERIFY_FAIL_DEST
pass "a destination the app cannot write to fails the install clearly"

printf '\n== manifest ==\n'
reset_fixtures
PORT=8089
CT_TEMPLATE_REF='local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst'
CT_TEMPLATE='debian-12-standard_12.7-1_amd64.tar.zst'
USBC_INSTALLED_FILES=("$USBC_HOST_LIB_DIR/mount-usb.sh")
USBC_CONTAINER_FILES=('/etc/usbcopy/config.toml' '/etc/systemd/system/usbcopy.service')
USBC_CREATED_DIRS=("$DEST_MOVIES" "$USBC_USB_INGEST_DIR")
USBC_CONTAINER_DIRS=('/mnt/usb' '/data/movies')
USBC_INSTALLED_UNITS=("$USBC_SYSTEMD_DIR/usbcopy-mount@.service")
USBC_INSTALLED_UDEV=("$USBC_UDEV_RULES_DIR/99-usbcopy.rules")
USBC_BACKUP_FILES=("$USBC_BACKUP_ROOT/stamp/usr/local/lib/usbcopy/mount-usb.sh")
manifest_add_mount 0 "$USBC_USB_INGEST_DIR" /mnt/usb ro
manifest_add_mount 2 "$DEST_MOVIES" /data/movies rw
write_manifest
[[ -f $USBC_MANIFEST_PATH ]] || fail "write_manifest did not create $USBC_MANIFEST_PATH"
python3 - "$USBC_MANIFEST_PATH" "$DEST_MOVIES" "$DEST_SERIES" "$DEST_EXTRA" "$USBC_USB_INGEST_DIR" <<'PY'
import json
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
    "read_only": True,
}, data["mounts"]
assert data["mounts"][1]["read_only"] is False, data["mounts"]
assert "/etc/systemd/system/usbcopy.service" in data["files"], data["files"]
assert data["units"], data
assert data["udev"], data
assert data["backups"], data
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
printf 'bootstrap checkout ran\n'
STUB
chmod +x "$BOOT_SRC/setup/install.sh"
"$REAL_TAR" -C "$WORK/bootstrap-src" -czf "$WORK/repo.tar.gz" proxmoxUSBcopy-main
: >"$USBC_FAKE_LOG"
out=$(USBC_FAKE_CURL_ARCHIVE="$WORK/repo.tar.gz" BOOT_ARGS_FILE="$WORK/boot-args" \
    bash -s -- --dry-run --yes --repo-url https://example.test/owner/proxmoxUSBcopy --ref main \
    <"$INSTALL" 2>&1)
assert_contains 'bootstrap checkout ran' "$out" 'bootstrap output'
args=$(<"$WORK/boot-args")
assert_contains '--dry-run' "$args" 'bootstrap args'
assert_contains '--yes' "$args" 'bootstrap args'
assert_contains '--repo-url' "$args" 'bootstrap args'
assert_contains '--ref' "$args" 'bootstrap args'
assert_contains 'https://example.test/owner/proxmoxUSBcopy/archive/main.tar.gz' "$(<"$USBC_FAKE_LOG")" 'fake log'
pass "piped install downloads the archive and re-execs the checkout with the original args"

out=$(bash -s -- --repo-url https://user:token123@example.test/owner/repo.git <"$INSTALL" 2>&1) \
    && status=0 || status=$?
((status != 0)) || fail "credential-bearing bootstrap URL was accepted"
assert_contains 'must not embed credentials' "$out" 'bootstrap failure'
assert_not_contains 'token123' "$out" 'bootstrap failure'
pass "piped install rejects credentials without echoing them"

out=$(bash <"$INSTALL" 2>&1) && status=0 || status=$?
((status != 0)) || fail "OWNER placeholder bootstrap URL was accepted"
assert_contains 'OWNER placeholder' "$out" 'bootstrap failure'
pass "piped install rejects the OWNER placeholder"

out=$(USBC_FAKE_CURL_FAIL=1 bash -s -- --repo-url https://example.test/owner/proxmoxUSBcopy \
    <"$INSTALL" 2>&1) && status=0 || status=$?
((status != 0)) || fail "bootstrap without a downloadable archive unexpectedly succeeded"
assert_contains 'could not download the repository archive' "$out" 'bootstrap failure'
pass "piped install fails clearly when the archive cannot be fetched"

printf '\nAll installer execution tests passed.\n'
