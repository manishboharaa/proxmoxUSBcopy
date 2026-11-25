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

log() {
    printf '%s: %s\n' "$PROG" "$*"
}

warn() {
    printf '%s: warning: %s\n' "$PROG" "$*" >&2
}

die() {
    printf '%s: error: %s\n' "$PROG" "$*" >&2
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

validate_int() {
    local name=$1
    local value=$2
    local min=$3
    local max=$4
    [[ -n $value ]] || die "$name must not be empty"
    ((${#value} <= 9)) || die "$name is out of range (got: $value)"
    [[ $value =~ ^[0-9]+$ ]] || die "$name must be a whole number (got: $value)"
    ((10#$value >= min && 10#$value <= max)) \
        || die "$name must be between $min and $max (got: $value)"
}

validate_admin_password() {
    local password=$1
    local LC_ALL=C
    local bytes=${#password}

    [[ -n $password ]] || die "admin password must not be empty"
    if ((bytes > 72)); then
        die "admin password is ${bytes} UTF-8 bytes; bcrypt accepts at most 72 bytes; choose a shorter password"
    fi
}

validate_port() {
    local value=$1
    [[ -n $value ]] || die "dashboard port must not be empty"
    ((${#value} <= 5)) || die "dashboard port is out of range: $value"
    [[ $value =~ ^[0-9]+$ ]] || die "dashboard port must be a number (got: $value)"
    ((10#$value >= 1 && 10#$value <= 65535)) \
        || die "dashboard port must be between 1 and 65535 (got: $value)"
}

validate_path() {
    local name=$1
    local value=$2
    [[ -n $value ]] || die "$name must not be empty"
    [[ $value == /* ]] || die "$name must be an absolute path: $value"
    [[ $value != '/' ]] || die "$name must not be /"
    [[ $value != *'..'* ]] || die "$name must not contain '..': $value"
    [[ $value != *$'\n'* && $value != *$'\r'* && $value != *$'\t'* ]] \
        || die "$name must not contain control characters"
}

canonical_path() {
    local name=$1
    local value=$2
    local canonical=''

    validate_path "$name" "$value"
    if ! canonical=$(realpath -m -- "$value"); then
        die "$name cannot be resolved to an absolute path: $value"
    fi
    [[ -n $canonical ]] || die "$name cannot be resolved to an absolute path: $value"
    [[ $canonical == /* ]] || die "$name must resolve to an absolute path: $value"
    [[ $canonical != '/' ]] || die "$name must not resolve to /: $value"
    [[ $canonical != *'..'* ]] || die "$name must not contain '..': $value"
    [[ $canonical != *$'\n'* && $canonical != *$'\r'* && $canonical != *$'\t'* ]] \
        || die "$name must not contain control characters"
    printf '%s' "$canonical"
}

validate_destination_safety() {
    local name=$1
    local value=$2
    local canonical=''

    canonical=$(canonical_path "$name" "$value")
    case "$canonical" in
        / | /etc | /etc/* | /usr | /usr/* | /var | /var/* | /boot | /boot/* | \
            /home | /home/* | /root | /root/* | /dev | /dev/* | /proc | /proc/* | \
            /sys | /sys/* | /run | /run/* | /opt | /opt/*)
            die "$name must not be a protected host path: $canonical"
            ;;
        /srv/usb-ingest | /srv/usb-ingest/*)
            die "$name must not overlap the USB ingest root: $canonical"
            ;;
        /srv/usbcopy/events | /srv/usbcopy/events/*)
            die "$name must not overlap the event spool: $canonical"
            ;;
    esac
    [[ $canonical != *,* ]] || die "$name must not contain a comma: $canonical"
    [[ $canonical != *=* ]] || die "$name must not contain '=': $canonical"
    [[ $canonical != *[[:cntrl:]]* ]] \
        || die "$name must not contain control characters: $canonical"
    printf '%s' "$canonical"
}

validate_hostname() {
    local value=$1
    ((${#value} >= 1 && ${#value} <= 63)) \
        || die "hostname must be 1-63 characters (got: $value)"
    [[ $value =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] \
        || die "invalid hostname (use letters, digits and inner dashes): $value"
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
        printf 'uninstall: re-run this installer with --uninstall from %s@%s (the temporary checkout is not kept)\n' \
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
