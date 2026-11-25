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
assert_contains 'PLAN: CT 101 settings: hostname=usbcopy storage=local-lvm disk=8GB ram=1024MB cores=2 swap=512MB unprivileged=1 onboot=1 bridge=vmbr0 ip=dhcp' "$out"
assert_contains 'PLAN: stop CT 101 before adding bind mounts' "$out"
assert_contains 'PLAN: start CT 101 after bind mounts' "$out"
assert_contains 'PLAN: health check GET /healthz from the host' "$out"
assert_contains 'PLAN: back up any modified host files under /etc/usbcopy/backup/<timestamp>' "$out"
assert_contains 'PLAN: start CT 101' "$out"
assert_contains 'PLAN: apt-get update in CT 101' "$out"
assert_contains 'PLAN: create Python venv at /opt/usbcopy/venv in CT 101' "$out"
assert_contains 'PLAN: copy application files to /opt/usbcopy in CT 101' "$out"
assert_contains 'PLAN: create host directory /srv/usb-ingest' "$out"
assert_contains 'PLAN: create host directory /srv/usbcopy/events' "$out"

printf '\n== Proxmox VE 9 host ==\n'
out=$(USBC_FAKE_PVE_VERSION='pve-manager/9.1.6/71482d1833ded40a (running kernel: 6.17.13-2-pve)' \
    USBC_ANSWERS="$ANSWERS" "$INSTALL" --dry-run --yes 2>&1)
assert_contains 'PLAN: create CT 101' "$out"
assert_contains 'PLAN: dashboard http://' "$out"
pass "preflight accepts a Proxmox VE 9 host"
assert_contains 'PLAN: mount /srv/usb-ingest -> /mnt/usb (read-only)' "$out"
assert_contains 'PLAN: mount /srv/usbcopy/events -> /var/lib/usbcopy/events' "$out"
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
assert_contains 'PLAN: copy the local application tree' "$out"
assert_contains 'Install source:   https://example.test/usbcopy.git@v1.2.3' "$out"
pass "--repo-url and --ref override the placeholders"

out=$(USBC_ANSWERS="$ANSWERS" "$INSTALL" --dry-run --yes \
    --repo-url=https://example.test/equals.git --ref=dev 2>&1)
assert_contains 'Install source:   https://example.test/equals.git@dev' "$out"
pass "--repo-url= and --ref= forms are accepted"

out=$(USBC_ANSWERS="$ANSWERS" "$INSTALL" --dry-run --yes \
    --repo-url=ssh://git@example.test/usbcopy.git 2>&1)
assert_contains 'Install source:   ssh://git@example.test/usbcopy.git@main' "$out"
out=$(USBC_ANSWERS="$ANSWERS" "$INSTALL" --dry-run --yes \
    --repo-url=git@example.test:owner/usbcopy.git 2>&1)
assert_contains 'Install source:   git@example.test:owner/usbcopy.git@main' "$out"
pass "ssh://user@ and git@host:path repository URLs are accepted"

out=$("$INSTALL" --help 2>&1)
for flag in --repo-url --ref --dry-run --yes --uninstall --destroy-ct --help; do
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

assert_fails_with 'protected host path' \
    env USBC_ANSWERS="101 usbcopy local-lvm 8 1024 2 dhcp /etc /tmp/series '' '' no 8088 secret" \
    "$INSTALL" --dry-run --yes
pass "protected system paths are rejected before planning"

assert_fails_with 'USB ingest root' \
    env USBC_ANSWERS="101 usbcopy local-lvm 8 1024 2 dhcp /srv/usb-ingest/movies /tmp/series '' '' no 8088 secret" \
    "$INSTALL" --dry-run --yes
pass "destinations overlapping the USB ingest root are rejected"

assert_fails_with 'comma' \
    env USBC_ANSWERS="101 usbcopy local-lvm 8 1024 2 dhcp /tmp/movies,evil /tmp/series '' '' no 8088 secret" \
    "$INSTALL" --dry-run --yes
pass "comma-containing destinations are rejected before planning"

assert_fails_with 'parent directory does not exist' \
    env USBC_ANSWERS="101 usbcopy local-lvm 8 1024 2 dhcp $WORK/no-parent/movies /tmp/series '' '' no 8088 secret" \
    "$INSTALL" --dry-run --yes
pass "missing destination parents are rejected before CT creation"

assert_fails_with "must not contain '='" \
    env USBC_ANSWERS="101 usbcopy local-lvm 8 1024 2 dhcp /tmp/movies=evil /tmp/series '' '' no 8088 secret" \
    "$INSTALL" --dry-run --yes
pass "equals signs in destination paths are rejected before planning"

LONG_PASSWORD=$(printf 'a%.0s' {1..73})
: >"$USBC_FAKE_LOG"
out=$(USBC_ANSWERS="101 usbcopy local-lvm 8 1024 2 dhcp /tmp/movies /tmp/series '' '' no 8088 $LONG_PASSWORD" \
    "$INSTALL" --dry-run --yes 2>&1) && status=0 || status=$?
((status != 0)) || fail "73-byte password unexpectedly succeeded"
assert_contains '72' "$out" 'password cap output'
assert_not_contains 'PLAN:' "$out" 'password cap output'
if grep -q 'pct create' "$USBC_FAKE_LOG"; then
    fail "73-byte password was rejected after pct create"
fi
pass "the 72-byte password cap is enforced before the plan and CT creation"

assert_fails_with 'no install manifest found' \
    env USBC_TEST_MODE=1 USBC_FAIL_AT=unused USBC_MANIFEST_PATH="$WORK/missing-manifest.json" \
    "$INSTALL" --uninstall
pass "--uninstall fails clearly when no install manifest exists"

printf '\n== destination canonicalisation ==\n'
for bad in '///' '//' '/.'; do
    assert_fails_with 'must not resolve to /' \
        env USBC_ANSWERS="110 usbcopy local-lvm 8 1024 2 dhcp $bad /tmp/series '' '' no 8088 secret" \
        "$INSTALL" --dry-run --yes
done
pass "root-equivalent destination paths are rejected"

assert_fails_with 'must be different folders' \
    env USBC_ANSWERS="111 usbcopy local-lvm 8 1024 2 dhcp /tmp//movies /tmp/movies '' '' no 8088 secret" \
    "$INSTALL" --dry-run --yes
pass "destinations are compared after canonicalisation"

out=$(USBC_ANSWERS="112 usbcopy local-lvm 8 1024 2 dhcp /tmp//movies /tmp/series//// '' '' no 8088 secret" \
    "$INSTALL" --dry-run --yes 2>&1)
assert_contains 'PLAN: mount /tmp/movies -> /data/movies' "$out"
assert_contains 'PLAN: mount /tmp/series -> /data/series' "$out"
pass "valid destination paths are canonicalised before planning"

printf '\n== extra destination names ==\n'
for name in Movies movies SERIES; do
    assert_fails_with 'reserved Movies or Series' \
        env USBC_ANSWERS="113 usbcopy local-lvm 8 1024 2 dhcp $WORK/movies $WORK/series $WORK/$name '' no 8088 secret" \
        "$INSTALL" --dry-run --yes
done
pass "extra destination basename cannot collide with Movies or Series"

printf '\n== destination modes ==\n'
mkdir -p "$WORK/existing-movies"
out=$(USBC_ANSWERS="114 usbcopy local-lvm 8 1024 2 dhcp $WORK/existing-movies $WORK/new-series '' '' no 8088 secret" \
    "$INSTALL" --dry-run --yes 2>&1)
assert_contains "PLAN: use existing destination directory $WORK/existing-movies" "$out"
assert_contains "PLAN: create destination directory $WORK/new-series" "$out"
[[ ! -e "$WORK/new-series" ]] || fail "dry-run created the missing destination"
pass "plan distinguishes existing and to-be-created destinations"

real_out=$(
    set -euo pipefail
    export DRY_RUN=0
    export PROG='test'
    # shellcheck disable=SC1091
    source "$LIB_DIR/common.sh"
    # shellcheck disable=SC1091
    source "$LIB_DIR/preflight.sh"
    preflight_destination "Movies destination" "$WORK/real-movies" REAL_MOVIES_EXISTS
    printf 'missing=%s\n' "$REAL_MOVIES_EXISTS"
    preflight_destination "Series destination" "$WORK/existing-movies" REAL_SERIES_EXISTS
    printf 'existing=%s\n' "$REAL_SERIES_EXISTS"
)
assert_contains 'missing=0' "$real_out" 'real-mode preflight'
assert_contains 'existing=1' "$real_out" 'real-mode preflight'
[[ ! -e "$WORK/real-movies" ]] || fail "real-mode preflight created the missing destination"
pass "real-mode preflight accepts missing destinations and marks them for creation"

out=$(USBC_ANSWERS="115 usbcopy local-lvm 8 1024 2 dhcp $WORK/real-movies $WORK/real-series '' '' no 8088 secret" \
    "$INSTALL" --yes 2>&1) && status=0 || status=$?
((status != 0)) || fail "real mode unexpectedly continued past Task 19"
assert_contains 'must be run as root' "$out"
assert_not_contains 'does not exist' "$out"
pass "real mode stops at the root gate before Task 20 execution"

printf '\n== plan ordering and completeness ==\n'
out=$(USBC_ANSWERS="$ANSWERS" "$INSTALL" --dry-run --yes 2>&1)
for needle in \
    'PLAN: create host directory /srv/usb-ingest' \
    'PLAN: create host directory /srv/usbcopy/events' \
    'PLAN: install CT packages only if missing' \
    'PLAN: install udev rule /etc/udev/rules.d/99-usbcopy.rules' \
    'PLAN: install systemd units usbcopy-mount@.service and usbcopy-scan-usb.service' \
    'PLAN: add bind mounts to CT 101' \
    'PLAN: write install manifest /etc/usbcopy/install-manifest.json' \
    'PLAN: back up any modified host files'; do
    assert_contains "$needle" "$out" 'complete plan'
done
assert_contains 'unprivileged=1 onboot=1' "$out"
assert_contains 'PLAN: health check GET /healthz from the host' "$out"
assert_contains 'PLAN: stop CT 101 before adding bind mounts' "$out"
assert_contains 'PLAN: start CT 101 after bind mounts' "$out"

plan_line=$(grep -nF 'PLAN: install udev rule' <<<"$out" | head -n 1 | cut -d: -f1)
summary_line=$(grep -nF 'Installer summary' <<<"$out" | head -n 1 | cut -d: -f1)
[[ -n $plan_line && -n $summary_line ]] || fail "plan or summary line missing"
((plan_line < summary_line)) || fail "change plan is not printed before the summary/confirmation"
pass "full change plan precedes the confirmation summary"

printf '\n== repository URL safety ==\n'
credential_url='https://user:token123@example.test/repo.git'
out=$(USBC_ANSWERS="$ANSWERS" "$INSTALL" --dry-run --yes --repo-url "$credential_url" 2>&1) \
    && status=0 || status=$?
((status != 0)) || fail "credential-bearing repository URL was accepted"
assert_contains 'must not embed credentials' "$out"
assert_not_contains 'token123' "$out"
assert_not_contains "$credential_url" "$out"
pass "credential-bearing repository URLs are rejected without echoing the secret"

out=$(USBC_ANSWERS="$ANSWERS" "$INSTALL" --dry-run --yes \
    --repo-url 'git@user:token123@example.test:repo.git' 2>&1) && status=0 || status=$?
((status != 0)) || fail "credential-bearing git@ repository URL was accepted"
assert_contains 'must not embed credentials' "$out"
assert_not_contains 'token123' "$out"
pass "credential-bearing git@ repository URLs are rejected without echoing the secret"

assert_fails_with 'must not start with' \
    env USBC_ANSWERS="$ANSWERS" "$INSTALL" --dry-run --yes --repo-url=-evil
pass "repository URL starting with a dash is rejected"

assert_fails_with 'unsupported repository URL' \
    env USBC_ANSWERS="$ANSWERS" "$INSTALL" --dry-run --yes --repo-url=ftp://example.test/repo.git
pass "unsupported repository URL schemes are rejected"

printf '\n== answer secrecy ==\n'
ENV_FAKE_DIR="$WORK/env-fake"
mkdir -p "$ENV_FAKE_DIR"
cat >"$ENV_FAKE_DIR/pveversion" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'USBC_ANSWERS=%s\n' "${USBC_ANSWERS-__unset__}" >>"${CHILD_ENV_LOG:?}"
exec "${REAL_PVEVERSION:?}" "$@"
FAKE
chmod +x "$ENV_FAKE_DIR/pveversion"
export CHILD_ENV_LOG="$WORK/child-env.log"
export REAL_PVEVERSION="$FAKES/pveversion"
: >"$CHILD_ENV_LOG"
out=$(PATH="$ENV_FAKE_DIR:$PATH" USBC_ANSWERS="$ANSWERS" "$INSTALL" --dry-run --yes 2>&1)
assert_contains 'USBC_ANSWERS=__unset__' "$(<"$CHILD_ENV_LOG")" 'child environment'
assert_not_contains 'secret' "$(<"$CHILD_ENV_LOG")" 'child environment'
pass "USBC_ANSWERS is removed from the environment before child processes run"
unset CHILD_ENV_LOG REAL_PVEVERSION

printf '\n== uninstall forwarding ==\n'
STUB_ROOT="$WORK/uninstall-stub"
cp -R "$REPO_ROOT/setup" "$STUB_ROOT"
rm -f -- "$STUB_ROOT/uninstall.sh"
: >"$USBC_FAKE_LOG"
out=$("$STUB_ROOT/install.sh" --uninstall --dry-run 2>&1) && status=0 || status=$?
((status != 0)) || fail "--uninstall without an uninstaller unexpectedly succeeded"
assert_contains 'uninstall.sh is not available' "$out"
if grep -Eq '^(pct|pveam|systemctl|curl) ' "$USBC_FAKE_LOG"; then
    fail "missing-uninstaller path ran preflight host commands"
fi
pass "--uninstall without an uninstaller fails before any host command"

cat >"$STUB_ROOT/uninstall.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"${STUB_ARGS_FILE:?}"
STUB
chmod +x "$STUB_ROOT/uninstall.sh"
export STUB_ARGS_FILE="$WORK/uninstall-args"
"$STUB_ROOT/install.sh" --uninstall --dry-run --yes --destroy-ct
args=$(<"$STUB_ARGS_FILE")
assert_contains '--dry-run' "$args" 'uninstaller args'
assert_contains '--yes' "$args" 'uninstaller args'
assert_contains '--destroy-ct' "$args" 'uninstaller args'
assert_not_contains '--uninstall' "$args" 'uninstaller args'
pass "--uninstall forwards --dry-run, --yes, and --destroy-ct to the uninstaller"
unset STUB_ARGS_FILE

assert_fails_with 'only valid with --uninstall' "$INSTALL" --destroy-ct --dry-run
pass "--destroy-ct without --uninstall is rejected"

printf '\n== no tty and piped invocation ==\n'
if command -v -- setsid >/dev/null 2>&1; then
    out=$(env -u USBC_ANSWERS setsid -w "$INSTALL" --dry-run </dev/null 2>&1) \
        && status=0 || status=$?
    ((status != 0)) || fail "installer prompted without a terminal"
    assert_contains 'no terminal available for prompts' "$out"
    pass "interactive mode fails clearly without a terminal"
else
    pass "setsid unavailable; no-TTY test skipped"
fi

# shellcheck disable=SC2002
out=$(cat "$INSTALL" | bash 2>&1) && status=0 || status=$?
((status != 0)) || fail "piped installer unexpectedly succeeded"
assert_contains 'install.sh: error:' "$out"
assert_not_contains 'unbound variable' "$out"
pass "curl | bash fails with a clean error instead of crashing under set -u"

printf '\nAll installer dry-run tests passed.\n'
