#!/usr/bin/env bash
# Shared helpers for the proxmoxUSBcopy installer.
#
# This file is sourced by setup/install.sh. It keeps logging, prompting, and
# validation in one place so preflight and prompt code stays readable.
# shellcheck shell=bash

set -euo pipefail

PROG=${PROG:-install.sh}
DRY_RUN=${DRY_RUN:-0}
ASSUME_YES=${ASSUME_YES:-0}

# Message from the last failed check_* validator. check_* functions return
# 1 and set this instead of dying, so interactive prompts can re-ask; the
# validate_* wrappers below keep the old die-on-first-error behavior for
# noninteractive runs.
USBC_VALIDATE_ERROR=''

# Ordered answer stream used by --yes and tests. Answers are space-separated;
# a literal '' (or "") token means an empty answer. The stream is consumed in
# prompt order by take_answer.
USBC_ANSWER_ITEMS=()
USBC_ANSWER_INDEX=0
USBC_ANSWER_VALUE=''
USBC_ANSWERS_SET=0
if [[ -n ${USBC_ANSWERS+set} ]]; then
    USBC_ANSWERS_SET=1
    read -r -a USBC_ANSWER_ITEMS <<<"$USBC_ANSWERS"
    # Keep answers in the non-exported array only: child processes must never
    # inherit the admin password via the environment.
    unset USBC_ANSWERS
fi

# Interactive prompts use one persistent /dev/tty descriptor. There is no
# stdin fallback: a piped installer that needs answers must fail clearly.
USBC_TTY_FD=''
USBC_TTY_OPEN=0

open_tty() {
    if ((USBC_TTY_OPEN == 1)); then
        return 0
    fi
    if { exec {USBC_TTY_FD}<>/dev/tty; } 2>/dev/null; then
        USBC_TTY_OPEN=1
        return 0
    fi
    return 1
}

require_interactive_tty() {
    if noninteractive; then
        return 0
    fi
    if ! open_tty; then
        die "no terminal available for prompts (/dev/tty could not be opened); re-run from an interactive terminal or use --yes"
    fi
}

# --- terminal accents -------------------------------------------------------
# Colours only when the stream is a terminal: captured output (tests, logs,
# pipes) stays plain, and NO_COLOR turns them off everywhere.
if [[ -z ${NO_COLOR:-} && -t 1 ]]; then
    USBC_C_RESET=$'\e[0m'
    USBC_C_HEAD=$'\e[1;36m'
    USBC_C_GOOD=$'\e[32m'
    USBC_C_BAD=$'\e[31m'
    USBC_C_DIM=$'\e[2m'
else
    # Colors are consumed through sourced copies of this block in the caller.
    # shellcheck disable=SC2034
    USBC_C_RESET='' USBC_C_HEAD='' USBC_C_GOOD='' USBC_C_BAD='' USBC_C_DIM=''
fi
if [[ -z ${NO_COLOR:-} && -t 2 ]]; then
    USBC_C_WARN=$'\e[33m'
    USBC_C_ERR=$'\e[1;31m'
else
    USBC_C_WARN='' USBC_C_ERR=''
fi

log() {
    printf '%s\n' "${USBC_C_HEAD}${PROG}:${USBC_C_RESET} $*"
}

warn() {
    printf '%s\n' "${USBC_C_WARN}${PROG}: warning:${USBC_C_RESET} $*" >&2
}

die() {
    printf '%s\n' "${USBC_C_ERR}${PROG}: error:${USBC_C_RESET} $*" >&2
    # A die inside a command substitution runs in a subshell. Let that subshell
    # exit non-zero so the parent's ERR trap performs the single rollback.
    if [[ ${BASHPID:-$$} != "$$" ]]; then
        exit 1
    fi
    if [[ -n ${USBC_ERR_HANDLER:-} ]] && [[ $(type -t "$USBC_ERR_HANDLER") == function ]]; then
        "$USBC_ERR_HANDLER" 1
    fi
    exit 1
}

plan() {
    printf 'PLAN: %s\n' "$*"
}

require_cmd() {
    local name=$1
    command -v -- "$name" >/dev/null 2>&1 || die "required command not found: $name"
}

noninteractive() {
    ((ASSUME_YES == 1)) || ((USBC_ANSWERS_SET == 1))
}

take_answer() {
    USBC_ANSWER_VALUE=''
    if ((USBC_ANSWER_INDEX >= ${#USBC_ANSWER_ITEMS[@]})); then
        return 1
    fi
    USBC_ANSWER_VALUE=${USBC_ANSWER_ITEMS[USBC_ANSWER_INDEX]}
    USBC_ANSWER_INDEX=$((USBC_ANSWER_INDEX + 1))
    case "$USBC_ANSWER_VALUE" in
        "''" | '""')
            USBC_ANSWER_VALUE=''
            ;;
    esac
    return 0
}

format_prompt() {
    local prompt=$1
    local default=$2
    if [[ -n $default ]]; then
        printf '%s [%s]: ' "$prompt" "$default"
    else
        printf '%s: ' "$prompt"
    fi
}

read_tty() {
    local prompt=$1
    local value=''

    if ! open_tty; then
        return 1
    fi
    if ! printf '%s' "$prompt" >&"$USBC_TTY_FD"; then
        return 1
    fi
    if ! IFS= read -r value <&"$USBC_TTY_FD"; then
        return 1
    fi
    printf '%s' "$value"
}

read_tty_secret() {
    local prompt=$1
    local value=''
    local echo_disabled=0

    if ! open_tty; then
        return 1
    fi
    if command -v -- stty >/dev/null 2>&1; then
        if stty -echo <&"$USBC_TTY_FD" 2>/dev/null; then
            echo_disabled=1
        fi
    fi
    if ! printf '%s' "$prompt" >&"$USBC_TTY_FD"; then
        if ((echo_disabled == 1)); then
            stty echo <&"$USBC_TTY_FD" 2>/dev/null || true
        fi
        return 1
    fi
    if ! IFS= read -r value <&"$USBC_TTY_FD"; then
        if ((echo_disabled == 1)); then
            stty echo <&"$USBC_TTY_FD" 2>/dev/null || true
        fi
        return 1
    fi
    if ((echo_disabled == 1)); then
        stty echo <&"$USBC_TTY_FD" 2>/dev/null || true
    fi
    printf '\n' >&"$USBC_TTY_FD"
    printf '%s' "$value"
}

ask() {
    local varname=$1
    local prompt=$2
    local default=${3:-}
    local value=''

    if noninteractive; then
        if take_answer; then
            value=$USBC_ANSWER_VALUE
        fi
        if [[ -z $value ]]; then
            value=$default
        fi
    else
        if ! value=$(read_tty "$(format_prompt "$prompt" "$default")"); then
            die "could not read an answer from the terminal"
        fi
        if [[ -z $value ]]; then
            value=$default
        fi
    fi
    printf -v "$varname" '%s' "$value"
}

ask_secret() {
    local varname=$1
    local prompt=$2
    local value=''

    if noninteractive; then
        if take_answer; then
            value=$USBC_ANSWER_VALUE
        fi
    else
        if ! value=$(read_tty_secret "$prompt"); then
            die "could not read the admin password from the terminal"
        fi
    fi
    printf -v "$varname" '%s' "$value"
}

check_int() {
    local name=$1
    local value=$2
    local min=$3
    local max=$4
    USBC_VALIDATE_ERROR=''
    [[ -n $value ]] || { USBC_VALIDATE_ERROR="$name must not be empty"; return 1; }
    ((${#value} <= 9)) || { USBC_VALIDATE_ERROR="$name is out of range (got: $value)"; return 1; }
    [[ $value =~ ^[0-9]+$ ]] || { USBC_VALIDATE_ERROR="$name must be a whole number (got: $value)"; return 1; }
    ((10#$value >= min && 10#$value <= max)) \
        || { USBC_VALIDATE_ERROR="$name must be between $min and $max (got: $value)"; return 1; }
    return 0
}

validate_int() {
    check_int "$@" || die "$USBC_VALIDATE_ERROR"
}

check_password() {
    local password=$1
    local LC_ALL=C
    local bytes=${#password}

    USBC_VALIDATE_ERROR=''
    [[ -n $password ]] || { USBC_VALIDATE_ERROR="admin password must not be empty"; return 1; }
    if ((bytes > 72)); then
        USBC_VALIDATE_ERROR="admin password is ${bytes} UTF-8 bytes; bcrypt accepts at most 72 bytes; choose a shorter password"
        return 1
    fi
    return 0
}

validate_admin_password() {
    check_password "$@" || die "$USBC_VALIDATE_ERROR"
}

check_port() {
    local value=$1
    USBC_VALIDATE_ERROR=''
    [[ -n $value ]] || { USBC_VALIDATE_ERROR="dashboard port must not be empty"; return 1; }
    ((${#value} <= 5)) || { USBC_VALIDATE_ERROR="dashboard port is out of range: $value"; return 1; }
    [[ $value =~ ^[0-9]+$ ]] || { USBC_VALIDATE_ERROR="dashboard port must be a number (got: $value)"; return 1; }
    ((10#$value >= 1 && 10#$value <= 65535)) \
        || { USBC_VALIDATE_ERROR="dashboard port must be between 1 and 65535 (got: $value)"; return 1; }
    return 0
}

validate_port() {
    check_port "$@" || die "$USBC_VALIDATE_ERROR"
}

check_path() {
    local name=$1
    local value=$2
    USBC_VALIDATE_ERROR=''
    [[ -n $value ]] || { USBC_VALIDATE_ERROR="$name must not be empty"; return 1; }
    [[ $value == /* ]] || { USBC_VALIDATE_ERROR="$name must be an absolute path: $value"; return 1; }
    [[ $value != '/' ]] || { USBC_VALIDATE_ERROR="$name must not be /"; return 1; }
    [[ $value != *'..'* ]] || { USBC_VALIDATE_ERROR="$name must not contain '..': $value"; return 1; }
    [[ $value != *$'\n'* && $value != *$'\r'* && $value != *$'\t'* ]] \
        || { USBC_VALIDATE_ERROR="$name must not contain control characters"; return 1; }
    return 0
}

validate_path() {
    check_path "$@" || die "$USBC_VALIDATE_ERROR"
}

check_canonical() {
    local name=$1
    local value=$2
    local canonical=''

    check_path "$name" "$value" || return 1
    if ! canonical=$(realpath -m -- "$value"); then
        USBC_VALIDATE_ERROR="$name cannot be resolved to an absolute path: $value"
        return 1
    fi
    [[ -n $canonical ]] || { USBC_VALIDATE_ERROR="$name cannot be resolved to an absolute path: $value"; return 1; }
    [[ $canonical == /* ]] || { USBC_VALIDATE_ERROR="$name must resolve to an absolute path: $value"; return 1; }
    [[ $canonical != '/' ]] || { USBC_VALIDATE_ERROR="$name must not resolve to /: $value"; return 1; }
    [[ $canonical != *'..'* ]] || { USBC_VALIDATE_ERROR="$name must not contain '..': $value"; return 1; }
    [[ $canonical != *$'\n'* && $canonical != *$'\r'* && $canonical != *$'\t'* ]] \
        || { USBC_VALIDATE_ERROR="$name must not contain control characters"; return 1; }
    printf '%s' "$canonical"
}

canonical_path() {
    check_canonical "$@" || die "$USBC_VALIDATE_ERROR"
}

check_destination() {
    local name=$1
    local value=$2
    local canonical=''

    USBC_VALIDATE_ERROR=''
    canonical=$(check_canonical "$name" "$value") || return 1
    case "$canonical" in
        / | /etc | /etc/* | /usr | /usr/* | /var | /var/* | /boot | /boot/* | \
            /home | /home/* | /root | /root/* | /dev | /dev/* | /proc | /proc/* | \
            /sys | /sys/* | /run | /run/* | /opt | /opt/*)
            USBC_VALIDATE_ERROR="$name must not be a protected host path: $canonical"
            return 1
            ;;
        /srv/usb-ingest | /srv/usb-ingest/*)
            USBC_VALIDATE_ERROR="$name must not overlap the USB ingest root: $canonical"
            return 1
            ;;
        /srv/usbcopy/events | /srv/usbcopy/events/*)
            USBC_VALIDATE_ERROR="$name must not overlap the event spool: $canonical"
            return 1
            ;;
    esac
    [[ $canonical != *,* ]] || { USBC_VALIDATE_ERROR="$name must not contain a comma: $canonical"; return 1; }
    [[ $canonical != *=* ]] || { USBC_VALIDATE_ERROR="$name must not contain '=': $canonical"; return 1; }
    [[ $canonical != *[[:cntrl:]]* ]] \
        || { USBC_VALIDATE_ERROR="$name must not contain control characters: $canonical"; return 1; }
    printf '%s' "$canonical"
}

validate_destination_safety() {
    check_destination "$@" || die "$USBC_VALIDATE_ERROR"
}

check_hostname() {
    local value=$1
    USBC_VALIDATE_ERROR=''
    ((${#value} >= 1 && ${#value} <= 63)) \
        || { USBC_VALIDATE_ERROR="hostname must be 1-63 characters (got: $value)"; return 1; }
    [[ $value =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] \
        || { USBC_VALIDATE_ERROR="invalid hostname (use letters, digits and inner dashes): $value"; return 1; }
    return 0
}

validate_hostname() {
    check_hostname "$@" || die "$USBC_VALIDATE_ERROR"
}

is_ipv4() {
    local value=$1
    local octet
    [[ $value =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] \
        || return 1
    for octet in "${BASH_REMATCH[@]:1}"; do
        ((10#$octet <= 255)) || return 1
    done
    return 0
}

is_ipv4_cidr() {
    local value=$1
    local ip=''
    local prefix=''
    [[ $value == */* ]] || return 1
    ip=${value%/*}
    prefix=${value#*/}
    [[ $prefix =~ ^[0-9]{1,2}$ ]] || return 1
    ((10#$prefix >= 1 && 10#$prefix <= 32)) || return 1
    is_ipv4 "$ip"
}

is_dns_list() {
    local value=$1
    local entry
    local IFS=','
    for entry in $value; do
        entry=${entry# }
        entry=${entry% }
        [[ $entry =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
    done
    return 0
}

generate_password() {
    local value=''
    value=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)
    ((${#value} >= 16)) || die "could not generate an admin password"
    printf '%s' "$value"
}

destination_extra_key() {
    local base=${DEST_EXTRA##*/}
    local key=${base,,}
    key=${key//[^a-z0-9_]/_}
    printf '%s' "$key"
}

installer_uninstall_hint() {
    if [[ ${USBC_INSTALLER_MODE:-checkout} == bootstrap ]]; then
        printf 'uninstall: re-run this installer with --uninstall from %s@%s (the temporary download is not kept)\n' \
            "${REPO_URL:-the original repository}" "${REPO_REF:-main}"
        return 0
    fi
    printf 'uninstall: %s/uninstall.sh\n' "${SCRIPT_DIR:-.}"
}

is_port_free() {
    local port=$1
    if command -v -- ss >/dev/null 2>&1; then
        if ss -ltnH "sport = :$port" 2>/dev/null | grep -q .; then
            return 1
        fi
        return 0
    fi
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
        return 1
    fi
    return 0
}
