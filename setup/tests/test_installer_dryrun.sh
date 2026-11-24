#!/usr/bin/env bash
# Dry-run tests for the proxmoxUSBcopy installer.
#
# The installer is exercised with fakes on PATH so nothing touches a real
# Proxmox host. Every case runs with --dry-run; the fake log proves that only
# read-only commands were invoked.
set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd -- "$REPO_ROOT"

FAKES="$REPO_ROOT/setup/tests/fakes"
INSTALL="$REPO_ROOT/setup/install.sh"
LIB_DIR="$REPO_ROOT/setup/lib"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/usbcopy-installer-test.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT

export PATH="$FAKES:$PATH"
export USBC_FAKE_LOG="$WORK/fake.log"
: >"$USBC_FAKE_LOG"

ANSWERS="101 usbcopy local-lvm 8 1024 2 dhcp /tmp/movies /tmp/series '' '' no 8088 secret"

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

assert_fails_with() {
    local needle=$1
    shift
    local out status=0
    out=$("$@" 2>&1) || status=$?
    ((status != 0)) || fail "command unexpectedly succeeded: $*"
    assert_contains "$needle" "$out" 'failure output'
}

printf '== static checks ==\n'
for script in "$INSTALL" "$LIB_DIR"/*.sh; do
    bash -n "$script" || fail "bash -n rejected $script"
done
pass "installer scripts parse with bash -n"

printf '\n== dry-run plan ==\n'
out=$(USBC_ANSWERS="$ANSWERS" "$INSTALL" --dry-run --yes 2>&1)

assert_contains 'PLAN: create CT 101' "$out"
assert_contains 'PLAN: mount /tmp/movies -> /data/movies' "$out"
assert_contains 'PLAN: mount /tmp/series -> /data/series' "$out"
assert_contains 'PLAN: dashboard http://' "$out"
assert_contains 'PLAN: dashboard http://<ct-ip>:8088' "$out"
assert_contains 'PLAN: download Debian 12 LXC template to storage local' "$out"
assert_contains 'PLAN: CT 101 settings: hostname=usbcopy storage=local-lvm disk=8GB ram=1024MB cores=2 swap=512MB bridge=vmbr0 ip=dhcp' "$out"
assert_contains 'PLAN: start CT 101' "$out"
assert_contains 'PLAN: apt-get update in CT 101' "$out"
assert_contains 'PLAN: create Python venv at /opt/usbcopy/venv in CT 101' "$out"
assert_contains 'PLAN: copy application files to /opt/usbcopy in CT 101' "$out"
assert_contains 'PLAN: create host directory /srv/usb-ingest' "$out"
assert_contains 'PLAN: create host directory /srv/usbcopy/events' "$out"
assert_contains 'PLAN: mount /srv/usb-ingest -> /mnt/usb (read-only)' "$out"
assert_contains 'PLAN: mount /srv/usbcopy/events -> /run/usbcopy/events' "$out"
assert_contains 'PLAN: install udev rule /etc/udev/rules.d/99-usbcopy.rules' "$out"
assert_contains 'PLAN: install systemd units usbcopy-mount@.service and usbcopy-scan-usb.service' "$out"
assert_contains 'PLAN: verify the usbcopy user can read a source folder and write each destination' "$out"
assert_contains 'PLAN: write install manifest /etc/usbcopy/install-manifest.json' "$out"
assert_contains 'Auto mode disabled' "$out"
assert_not_contains 'secret' "$out" 'dry-run output'
assert_not_contains 'PLAN: create CT 101 ' "$out" 'dry-run plan'
pass "dry-run prints the required plan lines without leaking the password"

assert_contains 'pveversion' "$(<"$USBC_FAKE_LOG")" 'fake log'
assert_contains 'pvesm status --content images' "$(<"$USBC_FAKE_LOG")" 'fake log'
assert_contains 'pvesm status --content vztmpl' "$(<"$USBC_FAKE_LOG")" 'fake log'
assert_contains 'pct list' "$(<"$USBC_FAKE_LOG")" 'fake log'
assert_contains 'curl ' "$(<"$USBC_FAKE_LOG")" 'fake log'
pass "dry-run performed pveversion, pvesm, pct list, and curl preflight only"

if grep -Eq '^(pct (create|start|stop|set|exec)|pveam (update|download)|systemctl (start|enable|disable|daemon-reload))' "$USBC_FAKE_LOG"; then
    fail "dry-run invoked a mutating command"
fi
pass "dry-run did not invoke pct create/start, pveam download, or systemctl"

printf '\n== dry-run purity ==\n'
: >"$USBC_FAKE_LOG"
PURITY_ANSWERS="102 usbcopy local-lvm 8 1024 2 dhcp $WORK/movies $WORK/series '' '' no 8088 secret"
out=$(USBC_ANSWERS="$PURITY_ANSWERS" "$INSTALL" --dry-run --yes 2>&1)
assert_contains "PLAN: mount $WORK/movies -> /data/movies" "$out"
[[ ! -e "$WORK/movies" ]] || fail "dry-run created the Movies destination"
[[ ! -e "$WORK/series" ]] || fail "dry-run created the Series destination"
[[ ! -e "$WORK/install-manifest.json" ]] || fail "dry-run wrote a manifest"
pass "dry-run created no host directories or manifest"

printf '\n== optional answers ==\n'
EXTRA_ANSWERS="103 usbcopy local-lvm 16 2048 4 dhcp $WORK/movies $WORK/series $WORK/other '' no 9090 secret"
out=$(USBC_ANSWERS="$EXTRA_ANSWERS" "$INSTALL" --dry-run --yes 2>&1)
assert_contains "PLAN: create destination directory $WORK/other" "$out"
assert_contains "PLAN: mount $WORK/other -> /data/other" "$out"
assert_contains 'PLAN: dashboard http://<ct-ip>:9090' "$out"
assert_not_contains "$WORK/other -> /data/other (read-only)" "$out" 'extra mount plan'
pass "extra destination is planned when supplied and blank answers mean skip"

printf '\n== prompt ordering ==\n'
STATIC_ANSWERS="104 usbcopy local-lvm 8 1024 2 static 10.0.0.5/24 10.0.0.1 1.1.1.1 $WORK/movies $WORK/series '' '' no 8088 secret"
out=$(USBC_ANSWERS="$STATIC_ANSWERS" "$INSTALL" --dry-run --yes 2>&1)
assert_contains 'ip=static 10.0.0.5/24, gateway 10.0.0.1, dns 1.1.1.1' "$out"
assert_contains 'Network:          static 10.0.0.5/24, gateway 10.0.0.1, dns 1.1.1.1 (bridge vmbr0)' "$out"
pass "static network answers map to IP, gateway, and DNS in order"

AUTO_ANSWERS="105 usbcopy local-lvm 8 1024 2 dhcp $WORK/movies $WORK/series '' Movies yes 8088 secret"
out=$(USBC_ANSWERS="$AUTO_ANSWERS" "$INSTALL" --dry-run --yes 2>&1)
assert_contains 'PLAN: enable Auto mode for source folder Movies -> movies' "$out"
assert_contains 'Auto mode:        enabled for Movies' "$out"
pass "Auto mode and default source folder are read after the extra destination"

assert_fails_with 'Auto mode requires a default source folder' \
    env USBC_ANSWERS="106 usbcopy local-lvm 8 1024 2 dhcp $WORK/movies $WORK/series '' '' yes 8088 secret" \
    "$INSTALL" --dry-run --yes
pass "Auto mode without a source folder is rejected"

printf '\n== --yes defaults ==\n'
out=$(env -u USBC_ANSWERS "$INSTALL" --dry-run --yes 2>&1) && status=0 || status=$?
((status != 0)) || fail "--yes without answers unexpectedly succeeded"
assert_contains 'Movies destination is required' "$out"
pass "--yes without answers uses defaults and fails fast on the required destination"

printf '\n== flags ==\n'
out=$(USBC_ANSWERS="$ANSWERS" "$INSTALL" --dry-run --yes \
    --repo-url https://example.test/usbcopy.git --ref v1.2.3 2>&1)
assert_contains 'PLAN: fetch https://example.test/usbcopy.git@v1.2.3' "$out"
pass "--repo-url and --ref override the placeholders"

out=$("$INSTALL" --help 2>&1)
for flag in --repo-url --ref --dry-run --yes --uninstall --help; do
    assert_contains "$flag" "$out" 'help output'
done
pass "--help documents every supported flag"

printf '\n== validation errors ==\n'
assert_fails_with '65535' env USBC_ANSWERS="101 usbcopy local-lvm 8 1024 2 dhcp /tmp/movies /tmp/series '' '' no 70000 secret" \
    "$INSTALL" --dry-run --yes
pass "out-of-range port is rejected"

assert_fails_with 'Movies destination is required' env USBC_ANSWERS="101 usbcopy local-lvm 8 1024 2 dhcp '' /tmp/series '' '' no 8088 secret" \
    "$INSTALL" --dry-run --yes
pass "missing Movies destination is rejected"

assert_fails_with 'absolute path' env USBC_ANSWERS="101 usbcopy local-lvm 8 1024 2 dhcp relative/movies /tmp/series '' '' no 8088 secret" \
    "$INSTALL" --dry-run --yes
pass "relative destination is rejected"

assert_fails_with 'already in use' env USBC_ANSWERS="100 usbcopy local-lvm 8 1024 2 dhcp /tmp/movies /tmp/series '' '' no 8088 secret" \
    "$INSTALL" --dry-run --yes
pass "in-use CT ID is rejected"

assert_fails_with 'storage' env USBC_ANSWERS="101 usbcopy fake-storage 8 1024 2 dhcp /tmp/movies /tmp/series '' '' no 8088 secret" \
    "$INSTALL" --dry-run --yes
pass "storage without images support is rejected"

assert_fails_with 'unknown argument' "$INSTALL" --bogus
pass "unknown flag is rejected"

assert_fails_with 'uninstall.sh is not available' "$INSTALL" --uninstall
pass "--uninstall fails clearly when uninstall.sh is absent"

printf '\nAll installer dry-run tests passed.\n'
