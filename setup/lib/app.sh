#!/usr/bin/env bash
# Application installation inside the proxmoxUSBcopy CT.
#
# install_app is real-mode only (guarded); verify_permissions is the final
# permission probe run as the unprivileged usbcopy user.
# shellcheck shell=bash
# shellcheck disable=SC2016,SC2153

APP_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
USBC_APP_SOURCE=${USBC_APP_SOURCE:-$APP_LIB_DIR/../../app}
APP_CT_DIR=/opt/usbcopy
APP_CT_CONFIG=/etc/usbcopy/config.toml
APP_CT_DATA=/var/lib/usbcopy
APP_CT_EVENTS=/var/lib/usbcopy/events
APP_CT_MOUNTS=/mnt/usb
APP_CT_UNIT=/etc/systemd/system/usbcopy.service
EXTRA_KEY=''

CT_PACKAGES=(python3 python3-venv python3-pip ca-certificates curl)

generate_session_secret() {
    local secret
    secret=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
    [[ $secret =~ ^[0-9a-f]{64}$ ]] || die "could not generate a session secret"
    printf '%s' "$secret"
}

ct_destination_paths() {
    printf '%s\n' /data/movies /data/series
    if [[ -n $DEST_EXTRA ]]; then
        printf '/data/%s\n' "${DEST_EXTRA##*/}"
    fi
}

render_config() {
    local path=$1
    local password_hash=$2
    local session_secret=$3
    local default_mode='review'
    local auto_enabled='false'
    local destinations_tsv=''

    if [[ $AUTO_MODE == yes ]]; then
        default_mode='auto'
        auto_enabled='true'
    fi
    if [[ -n $DEST_EXTRA ]]; then
        EXTRA_KEY=$(destination_extra_key)
    fi
    destinations_tsv=$(
        printf 'movies\t%s\t%s\n' "$DEST_MOVIES" /data/movies
        printf 'series\t%s\t%s\n' "$DEST_SERIES" /data/series
        if [[ -n $DEST_EXTRA ]]; then
            printf '%s\t%s\t%s\n' "$EXTRA_KEY" "$DEST_EXTRA" "/data/${DEST_EXTRA##*/}"
        fi
    )

    USBC_CFG_PATH="$path" \
        USBC_CFG_PORT="$PORT" \
        USBC_CFG_PASSWORD_HASH="$password_hash" \
        USBC_CFG_SESSION_SECRET="$session_secret" \
        USBC_CFG_DEFAULT_FOLDER="$SOURCE_FOLDER" \
        USBC_CFG_DEFAULT_MODE="$default_mode" \
        USBC_CFG_AUTO_ENABLED="$auto_enabled" \
        USBC_CFG_DESTINATIONS="$destinations_tsv" \
        python3 - <<'PY'
import json
import os
import re

path = os.environ["USBC_CFG_PATH"]
text = os.environ["USBC_CFG_DESTINATIONS"]


def value(name):
    return os.environ[name]


def quoted(item):
    return json.dumps(item)


lines = [
    "[server]",
    'host = "0.0.0.0"',
    f"port = {int(value('USBC_CFG_PORT'))}",
    "",
    "[auth]",
    'username = "admin"',
    f"password_hash = {quoted(value('USBC_CFG_PASSWORD_HASH'))}",
    f"session_secret = {quoted(value('USBC_CFG_SESSION_SECRET'))}",
    "",
    "[source]",
    f"default_folder = {quoted(value('USBC_CFG_DEFAULT_FOLDER'))}",
    "",
    "[mode]",
    f"default = {quoted(value('USBC_CFG_DEFAULT_MODE'))}",
    f"auto_enabled = {value('USBC_CFG_AUTO_ENABLED')}",
    'auto_destination = "movies"',
    "",
    "[copy]",
    "verify_sha256 = true",
    "chunk_size_mb = 8",
    "retries = 3",
    "preserve_mtime = true",
    "",
]

for line in text.splitlines():
    key, _host_path, ct_path = line.split("\t", 2)
    name = key if re.fullmatch(r"[A-Za-z0-9_-]+", key) else quoted(key)
    lines.extend(
        [
            f"[destinations.{name}]",
            f"path = {quoted(ct_path)}",
            "",
        ]
    )

lines.extend(
    [
        "[scan]",
        "reconcile_minutes = 0",
        "skip_hidden_root_dirs = true",
        "",
        "[paths]",
        f"db_path = {quoted('/var/lib/usbcopy/usbcopy.db')}",
        f"events_dir = {quoted('/var/lib/usbcopy/events')}",
        f"mounts_root = {quoted('/mnt/usb')}",
        "",
    ]
)

fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines))
PY
}

render_unit() {
    local path=$1

    cat >"$path" <<'EOF'
[Unit]
Description=proxmoxUSBcopy dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=usbcopy
Group=usbcopy
WorkingDirectory=/opt/usbcopy
Environment=PYTHONPATH=/opt/usbcopy
Environment=USBCOPY_CONFIG=/etc/usbcopy/config.toml
ExecStart=/opt/usbcopy/venv/bin/python -m usbcopy.main
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/var/lib/usbcopy /data
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

wait_for_usbcopy_app() {
    local attempts=${USBC_HEALTH_RETRIES:-60}
    local delay=${USBC_HEALTH_SLEEP:-2}
    local attempt=1

    while ((attempt <= attempts)); do
        if ct_exec systemctl is-active --quiet usbcopy.service >/dev/null 2>&1; then
            CT_IP=$(ct_exec hostname -I 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; exit }}')
            if [[ -n $CT_IP ]] \
                && curl -fsS --max-time 5 "http://$CT_IP:$PORT/healthz" >/dev/null 2>&1; then
                log "dashboard: http://$CT_IP:$PORT (username admin)"
                return 0
            fi
        fi
        if ((attempt < attempts)); then
            sleep "$delay"
        fi
        attempt=$((attempt + 1))
    done
    die "usbcopy.service did not become healthy after $attempts attempts; inspect: pct exec $CT_ID -- journalctl -u usbcopy.service -n 100"
}

install_app() {
    local tmp_dir=''
    local missing=()
    local package=''
    local destination=''
    local password_hash=''
    local session_secret=''
    local default_mode='review'
    local auto_enabled='false'

    if ((DRY_RUN == 1)); then
        plan "install the local app/ tree into /opt/usbcopy in CT $CT_ID"
        return 0
    fi
    validate_admin_password "$ADMIN_PASSWORD"

    log "apt-get update in CT $CT_ID"
    ct_exec env DEBIAN_FRONTEND=noninteractive apt-get update -q \
        || die "apt-get update failed in CT $CT_ID"

    for package in "${CT_PACKAGES[@]}"; do
        if ! ct_exec dpkg -s "$package" >/dev/null 2>&1; then
            missing+=("$package")
        fi
    done
    if ((${#missing[@]} > 0)); then
        log "installing missing CT packages: ${missing[*]}"
        ct_exec env DEBIAN_FRONTEND=noninteractive \
            apt-get install -y --no-install-recommends "${missing[@]}" \
            || die "apt-get install failed in CT $CT_ID"
    fi

    if ! ct_exec id -u usbcopy >/dev/null 2>&1; then
        ct_exec useradd --system --user-group --home-dir "$APP_CT_DIR" \
            --shell /usr/sbin/nologin usbcopy \
            || die "could not create the usbcopy system user in CT $CT_ID"
    fi

    ct_exec install -d -m 0755 "$APP_CT_DIR" || die "could not create $APP_CT_DIR"
    ct_exec install -d -m 0750 -o usbcopy -g usbcopy "$APP_CT_DATA" \
        || die "could not create $APP_CT_DATA"
    ct_exec install -d -m 0750 -o root -g usbcopy /etc/usbcopy \
        || die "could not create /etc/usbcopy"
    ct_exec install -d -m 0755 "$APP_CT_MOUNTS" /data \
        || die "could not create the container mount points"
    USBC_CONTAINER_DIRS+=("$APP_CT_DIR" "$APP_CT_DATA" "/etc/usbcopy" "$APP_CT_MOUNTS" /data)
    while IFS= read -r destination; do
        ct_exec install -d -m 0755 "$destination" \
            || die "could not create $destination in CT $CT_ID"
        USBC_CONTAINER_DIRS+=("$destination")
    done < <(ct_destination_paths)
    ct_exec install -d -m 0750 -o usbcopy -g usbcopy "$APP_CT_EVENTS" \
        || die "could not create $APP_CT_EVENTS"
    USBC_CONTAINER_DIRS+=("$APP_CT_EVENTS")

    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/usbcopy-install.XXXXXX") \
        || die "could not create a temporary directory"
    tar -C "$USBC_APP_SOURCE" -czf "$tmp_dir/app.tar.gz" \
        usbcopy templates static requirements.txt config.example.toml \
        || die "could not archive $USBC_APP_SOURCE"
    pct push "$CT_ID" "$tmp_dir/app.tar.gz" /tmp/usbcopy-app.tar.gz \
        || die "could not push the application archive to CT $CT_ID"
    ct_exec tar -xzf /tmp/usbcopy-app.tar.gz -C "$APP_CT_DIR" \
        || die "could not extract the application in CT $CT_ID"
    ct_exec rm -f /tmp/usbcopy-app.tar.gz

    ct_exec python3 -m venv "$APP_CT_DIR/venv" \
        || die "could not create the Python venv in CT $CT_ID"
    ct_exec "$APP_CT_DIR/venv/bin/pip" install --disable-pip-version-check \
        -r "$APP_CT_DIR/requirements.txt" \
        || die "pip install failed in CT $CT_ID"

    password_hash=$(
        printf '%s' "$ADMIN_PASSWORD" \
            | ct_exec env PYTHONPATH="$APP_CT_DIR" "$APP_CT_DIR/venv/bin/python" -c 'import sys
from usbcopy.auth import hash_password
sys.stdout.write(hash_password(sys.stdin.read()))'
    ) || die "could not generate the admin password hash in CT $CT_ID"
    [[ $password_hash == \$2* ]] \
        || die "the CT did not return a bcrypt password hash"
    session_secret=$(generate_session_secret)

    render_config "$tmp_dir/config.toml" "$password_hash" "$session_secret" \
        || { rm -rf -- "$tmp_dir"; die "could not render config.toml"; }
    pct push "$CT_ID" "$tmp_dir/config.toml" "$APP_CT_CONFIG" \
        || { rm -rf -- "$tmp_dir"; die "could not push config.toml to CT $CT_ID"; }
    ct_exec chown root:usbcopy "$APP_CT_CONFIG" \
        || { rm -rf -- "$tmp_dir"; die "could not set config.toml ownership"; }
    ct_exec chmod 0640 "$APP_CT_CONFIG" \
        || { rm -rf -- "$tmp_dir"; die "could not set config.toml mode"; }
    USBC_CONTAINER_FILES+=("$APP_CT_CONFIG")

    if [[ $AUTO_MODE == yes ]]; then
        default_mode='auto'
        auto_enabled='true'
    fi
    log "config: default mode $default_mode, auto $auto_enabled, port $PORT"

    render_unit "$tmp_dir/usbcopy.service" \
        || { rm -rf -- "$tmp_dir"; die "could not render usbcopy.service"; }
    pct push "$CT_ID" "$tmp_dir/usbcopy.service" "$APP_CT_UNIT" \
        || { rm -rf -- "$tmp_dir"; die "could not push usbcopy.service to CT $CT_ID"; }
    ct_exec chown root:root "$APP_CT_UNIT" \
        || { rm -rf -- "$tmp_dir"; die "could not set usbcopy.service ownership"; }
    ct_exec chmod 0644 "$APP_CT_UNIT" \
        || { rm -rf -- "$tmp_dir"; die "could not set usbcopy.service mode"; }
    USBC_CONTAINER_FILES+=("$APP_CT_UNIT")
    USBC_CONTAINER_UNITS+=("usbcopy.service")

    rm -rf -- "$tmp_dir"
    tmp_dir=''
    ct_exec systemctl daemon-reload || die "systemctl daemon-reload failed in CT $CT_ID"
    ct_exec systemctl enable usbcopy.service \
        || die "could not enable usbcopy.service in CT $CT_ID"
    ct_exec systemctl start usbcopy.service \
        || die "could not start usbcopy.service in CT $CT_ID"
    wait_for_usbcopy_app
}

update_app() {
    local tmp_dir=''

    if ((DRY_RUN == 1)); then
        plan "update: push the local app/ tree into /opt/usbcopy in CT $CT_ID"
        plan "update: pip install -r requirements.txt into the existing venv"
        plan "update: restart usbcopy.service in CT $CT_ID and check the dashboard"
        return 0
    fi

    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/usbcopy-update.XXXXXX") \
        || die "could not create a temporary directory"

    # --update never prompts, so PORT is not set by the answer flow; the real
    # port lives in the CT config written at install time.
    PORT=$(ct_exec grep -E '^port' "$APP_CT_CONFIG" | head -n 1 | tr -dc '0-9')
    if [[ ! $PORT =~ ^[0-9]+$ ]]; then
        warn "could not read the dashboard port from $APP_CT_CONFIG; assuming 8088"
        PORT=8088
    fi
    log "update: dashboard port $PORT (read from the existing config)"

    tar -C "$USBC_APP_SOURCE" -czf "$tmp_dir/app.tar.gz" \
        usbcopy templates static requirements.txt config.example.toml \
        || die "could not archive $USBC_APP_SOURCE"
    pct push "$CT_ID" "$tmp_dir/app.tar.gz" /tmp/usbcopy-app.tar.gz \
        || die "could not push the application archive to CT $CT_ID"
    ct_exec tar -xzf /tmp/usbcopy-app.tar.gz -C "$APP_CT_DIR" \
        || die "could not extract the application in CT $CT_ID"
    ct_exec rm -f /tmp/usbcopy-app.tar.gz

    ct_exec "$APP_CT_DIR/venv/bin/pip" install --disable-pip-version-check \
        -r "$APP_CT_DIR/requirements.txt" \
        || die "pip install failed in CT $CT_ID"

    ct_exec systemctl restart usbcopy.service \
        || die "could not restart usbcopy.service in CT $CT_ID"
    wait_for_usbcopy_app
    rm -rf -- "$tmp_dir"
    log "config and admin password in CT $CT_ID were left unchanged"
}

ct_probe_write() {
    local path=$1
    local probe_script='set -eu
probe="$1/.usbcopy-permission-test.$$"
trap "rm -f -- \"$probe\"" EXIT
: >"$probe"
rm -f -- "$probe"
trap - EXIT'

    ct_exec runuser -u usbcopy -- sh -c "$probe_script" sh "$path"
}

verify_permissions() {
    local failed=0
    local first_entry=''
    local destination=''
    local mount=''

    if ((DRY_RUN == 1)); then
        plan "verify the usbcopy user can read a source folder and write each destination"
        return 0
    fi

    for mount in /mnt/usb "$APP_CT_EVENTS"; do
        if ! ct_exec findmnt --mountpoint "$mount" >/dev/null 2>&1; then
            die "required bind mount is missing in CT $CT_ID: $mount"
        fi
    done

    if first_entry=$(ct_exec runuser -u usbcopy -- sh -c \
        'find /mnt/usb -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null'); then
        if [[ -z $first_entry ]]; then
            warn "no USB drive is mounted at /mnt/usb yet; skipping the source read check (connect a drive and use the dashboard)"
        fi
    else
        warn "usbcopy cannot read /mnt/usb; check the host mount permissions; source contents were not modified"
    fi

    while IFS= read -r destination; do
        if ! ct_probe_write "$destination"; then
            warn "usbcopy cannot create/delete files in $destination"
            failed=1
        fi
    done < <(ct_destination_paths)
    if ! ct_probe_write "$APP_CT_EVENTS"; then
        warn "usbcopy cannot create/delete files in the event spool $APP_CT_EVENTS"
        failed=1
    fi
    ((failed == 0)) \
        || die "permission check failed; fix the destination/spool ownership and re-run the installer (repair is not available in this build)"
    log "permission check passed for usbcopy in CT $CT_ID"
}
