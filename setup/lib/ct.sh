#!/usr/bin/env bash
# Container creation and readiness for the proxmoxUSBcopy installer.
#
# Everything here runs in real mode only. create_ct is also guarded so a
# direct call with DRY_RUN=1 prints the plan and touches nothing.
# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034,SC2153

CT_TEMPLATE=''
CT_TEMPLATE_REF=''
CT_IP=''
CT_CREATED=0
CT_DEBIAN12_PREFIX='debian-12-standard_'

select_debian12_template() {
    local storage=$TEMPLATE_STORAGE
    local list_output=''
    local available=''
    local line

    if ! list_output=$(pveam list "$storage" 2>/dev/null); then
        die "pveam list $storage failed; cannot inspect the template storage"
    fi
    while IFS= read -r line; do
        [[ $line == *"/${CT_DEBIAN12_PREFIX}"* ]] || continue
        CT_TEMPLATE_REF=${line%%[[:space:]]*}
        CT_TEMPLATE=${CT_TEMPLATE_REF##*/}
        return 0
    done <<<"$list_output"

    log "no Debian 12 template in $storage; refreshing the template index"
    pveam update >/dev/null || die "pveam update failed"
    if ! available=$(pveam available --section system 2>/dev/null); then
        die "pveam available --section system failed"
    fi
    CT_TEMPLATE=$(
        awk -v prefix="$CT_DEBIAN12_PREFIX" \
            '$1 ~ ("^" prefix) { print $1 }' <<<"$available" \
            | sort -V | tail -n 1
    )
    [[ -n $CT_TEMPLATE ]] || die "no Debian 12 system template is available from pveam"
    log "downloading template $CT_TEMPLATE to storage $storage"
    pveam download "$storage" "$CT_TEMPLATE" \
        || die "pveam download failed for $CT_TEMPLATE"
    CT_TEMPLATE_REF="$storage:vztmpl/$CT_TEMPLATE"
}

ct_exec() {
    pct exec "$CT_ID" -- "$@"
}

wait_for_ct_network() {
    local attempts=${USBC_NETWORK_RETRIES:-60}
    local delay=${USBC_NETWORK_SLEEP:-2}
    local attempt=1

    while ((attempt <= attempts)); do
        if ct_exec sh -c 'command -v apt-get >/dev/null 2>&1 && getent hosts deb.debian.org >/dev/null 2>&1'; then
            return 0
        fi
        if ((attempt < attempts)); then
            sleep "$delay"
        fi
        attempt=$((attempt + 1))
    done
    die "CT $CT_ID did not reach network/apt readiness after $attempts attempts; check the bridge/DNS and 'pct exec $CT_ID -- ip addr'"
}

ct_port_free() {
    local port=$1

    [[ $port =~ ^[0-9]+$ ]] || return 1
    if ! ct_exec sh -c 'command -v python3 >/dev/null 2>&1'; then
        # The Debian template may not ship python3 yet. A refused loopback
        # connection means no listener is claiming the port.
        if ct_exec timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/$0' "$port" >/dev/null 2>&1; then
            return 1
        fi
        return 0
    fi
    ct_exec python3 -c 'import socket, sys
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    sock.bind(("0.0.0.0", int(sys.argv[1])))
finally:
    sock.close()' "$port" >/dev/null 2>&1
}

select_ct_port() {
    local candidate

    if ct_port_free "$PORT"; then
        return 0
    fi
    warn "dashboard port $PORT is already in use inside CT $CT_ID"
    for candidate in {8088..8188}; do
        [[ $candidate == "$PORT" ]] && continue
        if ct_port_free "$candidate"; then
            PORT=$candidate
            warn "using dashboard port $PORT instead; the summary above still shows the requested port"
            return 0
        fi
    done
    die "no free dashboard port between 8088 and 8188 inside CT $CT_ID"
}

ct_net0() {
    if [[ $NET_MODE == static ]]; then
        printf 'name=eth0,bridge=%s,ip=%s,gw=%s' "$CT_BRIDGE" "$NET_IP" "$NET_GW"
    else
        printf 'name=eth0,bridge=%s,ip=dhcp' "$CT_BRIDGE"
    fi
}

create_ct() {
    local net0=''
    local args=()

    if ((DRY_RUN == 1)); then
        plan "create CT $CT_ID from a Debian 12 template"
        plan "start CT $CT_ID and wait for network/apt readiness"
        return 0
    fi

    net0=$(ct_net0)
    select_debian12_template
    log "creating CT $CT_ID from $CT_TEMPLATE_REF"
    args=(
        create "$CT_ID" "$CT_TEMPLATE_REF"
        --unprivileged 1
        --onboot 1
        --cores "$CORES"
        --memory "$RAM_MB"
        --swap "$SWAP_MB"
        --rootfs "$CT_STORAGE:$DISK_GB"
        --hostname "$CT_HOSTNAME"
        --net0 "$net0"
    )
    if [[ $NET_MODE == static ]]; then
        args+=(--nameserver "${NET_DNS:-$NET_GW}")
    fi
    pct "${args[@]}" || die "pct create failed for CT $CT_ID"
    CT_CREATED=1
    pct start "$CT_ID" || die "pct start failed for CT $CT_ID"
    log "waiting for CT $CT_ID network and apt readiness"
    wait_for_ct_network
    select_ct_port
    log "CT $CT_ID is ready; dashboard port $PORT"
}
