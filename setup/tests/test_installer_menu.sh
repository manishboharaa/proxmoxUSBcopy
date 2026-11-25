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
