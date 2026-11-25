#!/usr/bin/env bash
# Tests for the installer settings menu.
#
# Sources the installer libraries directly with stubbed tty readers, so the
# interactive menu loop can be driven from canned input. Noninteractive
# behavior stays covered by test_installer_dryrun.sh and
# test_installer_exec.sh; the answer stream must never change.
set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd -- "$REPO_ROOT"

LIB_DIR="$REPO_ROOT/setup/lib"

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

# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"

IMAGE_STORAGES=(local-lvm data)
TEMPLATE_STORAGE=local
CT_BRIDGE=vmbr0
ASSUME_YES=0

printf '== validator split (check_* returns, validate_* dies) ==\n'

USBC_VALIDATE_ERROR=''
if check_int "disk" 8 1 4; then
    fail "check_int accepted 8 for range 1-4"
fi
assert_contains "between 1 and 4" "$USBC_VALIDATE_ERROR" "check_int error"
pass "check_int returns 1 with a message"

out=$(bash -c "source '$LIB_DIR/common.sh'; validate_int disk 8 1 4" 2>&1) && fail "validate_int accepted 8" || true
assert_contains "disk must be between 1 and 4 (got: 8)" "$out" "validate_int die text"
pass "validate_int dies with the same text"

USBC_VALIDATE_ERROR=''
if check_port 70000; then
    fail "check_port accepted 70000"
fi
assert_contains "between 1 and 65535" "$USBC_VALIDATE_ERROR" "check_port error"
if ! check_port 8088; then
    fail "check_port rejected 8088"
fi
pass "check_port returns 1 with a message / 0 when valid"

USBC_VALIDATE_ERROR=''
if check_hostname "bad_name"; then
    fail "check_hostname accepted bad_name"
fi
assert_contains "invalid hostname" "$USBC_VALIDATE_ERROR" "check_hostname error"
pass "check_hostname returns 1 with a message"

USBC_VALIDATE_ERROR=''
if check_destination "movies destination" "/etc/passwd/x"; then
    fail "check_destination accepted a protected path"
fi
assert_contains "protected host path" "$USBC_VALIDATE_ERROR" "check_destination error"
out=$(check_destination "movies destination" "/tmp/movies")
assert_contains "/tmp/movies" "$out" "check_destination canonical output"
pass "check_destination returns 1 with a message / prints canonical when valid"

USBC_VALIDATE_ERROR=''
if check_password ""; then
    fail "check_password accepted an empty password"
fi
assert_contains "must not be empty" "$USBC_VALIDATE_ERROR" "check_password error"
if ! check_password "long-enough-passphrase"; then
    fail "check_password rejected a valid password"
fi
pass "check_password returns 1 with a message / 0 when valid"

pass "all validator split checks passed"

printf '\n== settings menu ==\n'

# shellcheck source=../lib/prompts.sh
source "$LIB_DIR/prompts.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/usbcopy-menu-test.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT

# Input is fed from a file through a real fd: ask() and the menu loop read
# inside command substitutions, so a mutating array stub would never advance.
TEST_INPUT_FILE="$WORK/input.txt"
: >"$TEST_INPUT_FILE"
exec {TEST_FD}<"$TEST_INPUT_FILE"

read_tty() {
    local line=''
    IFS= read -r line <&"$TEST_FD" || die "test input exhausted"
    printf '%s' "$line"
}
read_tty_secret() {
    read_tty "$1"
}
ct_id_used() {
    [[ $1 == 101 ]]
}

run_menu() {
    menu_defaults local-lvm 101
    printf '%s\n' "$@" >"$TEST_INPUT_FILE"
    { exec {TEST_FD}<&-; } 2>/dev/null || true
    exec {TEST_FD}<"$TEST_INPUT_FILE"
    : >"$WORK/err.log"
    { show_settings_menu >/dev/null; } 2>"$WORK/err.log"
}

run_menu "9" "/data/movies" "10" "/data/series" ""
[[ $DEST_MOVIES == /data/movies ]] || fail "DEST_MOVIES not set: $DEST_MOVIES"[[ $DEST_SERIES == /data/series ]] || fail "DEST_SERIES not set: $DEST_SERIES"
[[ $PORT == 8088 ]] || fail "PORT not defaulted: $PORT"
((ADMIN_PASSWORD_GENERATED == 1)) || fail "password was not auto-generated"
((${#ADMIN_PASSWORD} >= 16)) || fail "generated password too short"
pass "menu accepts destinations and leaves the rest on defaults"

run_menu "" "9" "/data/movies" "10" "/data/series" ""
err=$(cat "$WORK/err.log")
assert_contains "required" "$err" "blocked-enter warning"
assert_contains "9" "$err" "blocked-enter hint numbers"
assert_contains "10" "$err" "blocked-enter hint numbers"
[[ $DEST_MOVIES == /data/movies ]] || fail "DEST_MOVIES not set after block"
pass "enter with unset destinations is blocked and names the menu numbers"

run_menu "3" "8" "data" "9" "/data/movies" "10" "/data/series" ""
err=$(cat "$WORK/err.log")
assert_contains "storage '8' does not support images" "$err" "storage typo warning"
[[ $CT_STORAGE == data ]] || fail "CT_STORAGE not set after typo"
pass "a wrong storage answer re-asks instead of dying"

run_menu "3" "fake" "data" "9" "/data/movies" "10" "/data/series" ""
err=$(cat "$WORK/err.log")
assert_contains "does not support images" "$err" "storage name warning"
pass "an unknown storage name re-asks"

run_menu "1" "101" "105" "9" "/data/movies" "10" "/data/series" ""
err=$(cat "$WORK/err.log")
assert_contains "already in use" "$err" "ct id warning"
[[ $CT_ID == 105 ]] || fail "CT_ID not set after collision"
pass "an in-use CT ID re-asks"

run_menu "8" "static" "bad" "10.0.0.5/24" "10.0.0.1" "" "9" "/data/movies" "10" "/data/series" ""
err=$(cat "$WORK/err.log")
assert_contains "invalid static IP" "$err" "static ip warning"
[[ $NET_MODE == static && $NET_IP == 10.0.0.5/24 && $NET_GW == 10.0.0.1 ]] \
    || fail "static network not set: $NET_MODE $NET_IP $NET_GW"
pass "a bad static IP re-asks inside the network editor"

run_menu "abc" "9" "/data/movies" "10" "/data/series" ""
err=$(cat "$WORK/err.log")
assert_contains "Enter a number" "$err" "junk menu input warning"
[[ $DEST_MOVIES == /data/movies ]] || fail "menu did not recover after junk input"
pass "junk menu input warns and redraws"

pass "all settings menu checks passed"
