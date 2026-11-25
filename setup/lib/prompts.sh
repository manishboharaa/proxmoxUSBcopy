#!/usr/bin/env bash
# Installer prompts, defaults, and confirmation summary (DESIGN 11.5).
#
# Interactive installs show a settings menu: defaults are printed up front
# and each item can be changed by number until Enter accepts them.
# The old prompt order still governs the noninteractive answer stream:
#   1 CT ID, 2 hostname, 3 storage, 4 disk/RAM/cores/swap,
#   5 network, 6 Movies, 7 Series, 8 extra destination,
#   9 default source folder, 10 Auto mode, 11 port, 12 admin password,
#   13 confirmation summary.
# shellcheck shell=bash

CT_ID=''
CT_HOSTNAME=''
CT_STORAGE=''
DISK_GB=''
RAM_MB=''
CORES=''
SWAP_MB=''
NET_MODE=''
NET_IP=''
NET_GW=''
NET_DNS=''
DEST_MOVIES=''
DEST_SERIES=''
DEST_EXTRA=''
SOURCE_FOLDER=''
AUTO_MODE=''
PORT=''
ADMIN_PASSWORD=''
ADMIN_PASSWORD_GENERATED=0

prompt_ct_id() {
    local default=$1
    ask CT_ID "CT ID" "$default"
    validate_int "CT ID" "$CT_ID" 100 999999999
    printf -v CT_ID '%d' "$((10#$CT_ID))"
    if ct_id_used "$CT_ID"; then
        die "CT ID $CT_ID is already in use"
    fi
}

prompt_hostname() {
    local default=$1
    ask CT_HOSTNAME "Hostname" "$default"
    validate_hostname "$CT_HOSTNAME"
}

prompt_storage() {
    local default=$1
    local storage
    local found=0

    ask CT_STORAGE "Storage for CT disk" "$default"
    for storage in "${IMAGE_STORAGES[@]}"; do
        if [[ $storage == "$CT_STORAGE" ]]; then
            found=1
            break
        fi
    done
    ((found == 1)) \
        || die "storage '$CT_STORAGE' does not support images; available: ${IMAGE_STORAGES[*]}"
}

prompt_int() {
    local varname=$1
    local label=$2
    local default=$3
    local min=$4
    local max=$5
    local value=''

    ask "$varname" "$label" "$default"
    value=${!varname}
    validate_int "$label" "$value" "$min" "$max"
    printf -v "$varname" '%d' "$((10#$value))"
}

prompt_sizing() {
    prompt_int DISK_GB "Disk size in GB" 8 1 4096
    prompt_int RAM_MB "RAM in MB" 1024 128 1048576
    prompt_int CORES "CPU cores" 2 1 256
    if noninteractive; then
        SWAP_MB=512
    else
        prompt_int SWAP_MB "Swap in MB" 512 0 1048576
    fi
}

prompt_network() {
    ask NET_MODE "Network mode (dhcp/static)" "dhcp"
    NET_MODE=${NET_MODE,,}
    NET_IP=''
    NET_GW=''
    NET_DNS=''

    case "$NET_MODE" in
        dhcp)
            ;;
        static)
            ask NET_IP "Static IP with prefix (e.g. 192.168.1.50/24)" ""
            is_ipv4_cidr "$NET_IP" \
                || die "invalid static IP (expected IPv4/prefix, e.g. 192.168.1.50/24): $NET_IP"
            ask NET_GW "Gateway" ""
            is_ipv4 "$NET_GW" || die "invalid gateway: $NET_GW"
            ask NET_DNS "DNS servers (comma-separated, blank = gateway)" ""
            if [[ -n $NET_DNS ]]; then
                is_dns_list "$NET_DNS" || die "invalid DNS server list: $NET_DNS"
            fi
            ;;
        *)
            die "network mode must be dhcp or static (got: $NET_MODE)"
            ;;
    esac
}

prompt_required_destination() {
    local label=$1
    local varname=$2
    local value=''

    ask "$varname" "$label destination folder on host (required)" ""
    value=${!varname}
    if [[ -z $value ]]; then
        die "$label destination is required"
    fi
    value=$(canonical_path "$label destination" "$value")
    validate_destination_safety "$label destination" "$value" >/dev/null
    printf -v "$varname" '%s' "$value"
}

prompt_extra_destination() {
    local base
    ask DEST_EXTRA "Optional extra destination folder on host (enter to skip)" ""
    case "${DEST_EXTRA,,}" in
        '' | skip | none)
            DEST_EXTRA=''
            ;;
        *)
            DEST_EXTRA=$(canonical_path "extra destination" "$DEST_EXTRA")
            validate_destination_safety "extra destination" "$DEST_EXTRA" >/dev/null
            base=${DEST_EXTRA##*/}
            [[ $base =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
                || die "extra destination folder name must use letters, digits, dot, dash, or underscore: $base"
            case "${base,,}" in
                movies | series)
                    die "extra destination must not use the reserved Movies or Series name: $base"
                    ;;
            esac
            ;;
    esac
}

prompt_source_folder() {
    ask SOURCE_FOLDER "Default source folder for Auto mode (blank = copy the whole drive)" ""
    if [[ -n $SOURCE_FOLDER ]]; then
        [[ $SOURCE_FOLDER != *'..'* ]] \
            || die "default source folder must not contain '..': $SOURCE_FOLDER"
        [[ $SOURCE_FOLDER != *$'\n'* && $SOURCE_FOLDER != *$'\r'* ]] \
            || die "default source folder must not contain control characters"
    fi
}

prompt_auto_mode() {
    local answer=''
    ask answer "Enable Auto mode for that folder? (yes/no)" "no"
    case "${answer,,}" in
        y | yes | true | 1)
            AUTO_MODE=yes
            ;;
        '' | n | no | false | 0)
            AUTO_MODE=no
            ;;
        *)
            die "Auto mode answer must be yes or no (got: $answer)"
            ;;
    esac
}

prompt_password() {
    ask_secret ADMIN_PASSWORD "Admin password (blank = generate): "
    if [[ -z $ADMIN_PASSWORD ]]; then
        ADMIN_PASSWORD=$(generate_password)
        ADMIN_PASSWORD_GENERATED=1
    else
        ADMIN_PASSWORD_GENERATED=0
    fi
    validate_admin_password "$ADMIN_PASSWORD"
    ((${#ADMIN_PASSWORD} >= 8)) \
        || warn "admin password is shorter than 8 characters"
}

announce_generated_password() {
    if ((ADMIN_PASSWORD_GENERATED != 1)); then
        return 0
    fi
    printf '\n'
    printf '============================================================\n'
    printf ' SAVE THIS ADMIN PASSWORD NOW (it is shown only once)\n'
    printf ' username: admin\n'
    printf ' password: %s\n' "$ADMIN_PASSWORD"
    printf '============================================================\n\n'
}

collect_answers() {
    local default_storage=$1
    local default_ct_id=$2

    prompt_ct_id "$default_ct_id"
    prompt_hostname "usbcopy"
    prompt_storage "$default_storage"
    prompt_sizing
    prompt_network
    prompt_required_destination "Movies" DEST_MOVIES
    prompt_required_destination "Series" DEST_SERIES
    prompt_extra_destination
    prompt_source_folder
    prompt_auto_mode
    ask PORT "Dashboard port" "8088"
    validate_port "$PORT"
    printf -v PORT '%d' "$((10#$PORT))"
    prompt_password
}

# ---- interactive settings menu ----
#
# Defaults are printed up front; each item can be changed by number, one at
# a time, until Enter accepts them. Validation failures warn and re-ask
# instead of aborting the install.

check_storage_name() {
    local candidate=$1
    local storage
    local found=0
    USBC_VALIDATE_ERROR=''
    for storage in "${IMAGE_STORAGES[@]}"; do
        if [[ $storage == "$candidate" ]]; then
            found=1
            break
        fi
    done
    if ((found == 0)); then
        USBC_VALIDATE_ERROR="storage '$candidate' does not support images; available: ${IMAGE_STORAGES[*]}"
        return 1
    fi
    return 0
}

check_ct_id_free() {
    USBC_VALIDATE_ERROR=''
    if ct_id_used "$1"; then
        USBC_VALIDATE_ERROR="CT ID $1 is already in use"
        return 1
    fi
    return 0
}

check_source_folder() {
    local value=$1
    USBC_VALIDATE_ERROR=''
    if [[ -n $value ]]; then
        [[ $value != *'..'* ]] \
            || { USBC_VALIDATE_ERROR="default source folder must not contain '..': $value"; return 1; }
        [[ $value != *$'\n'* && $value != *$'\r'* ]] \
            || { USBC_VALIDATE_ERROR="default source folder must not contain control characters"; return 1; }
    fi
    return 0
}

edit_int() {
    local varname=$1
    local label=$2
    local default=$3
    local min=$4
    local max=$5
    local value=''

    while :; do
        ask "$varname" "$label" "$default"
        value=${!varname}
        if check_int "$label" "$value" "$min" "$max"; then
            printf -v "$varname" '%d' "$((10#$value))"
            return 0
        fi
        warn "${USBC_VALIDATE_ERROR}; try again"
    done
}

edit_ct_id() {
    local default=$1
    while :; do
        ask CT_ID "CT ID" "$default"
        if check_int "CT ID" "$CT_ID" 100 999999999 && check_ct_id_free "$CT_ID"; then
            printf -v CT_ID '%d' "$((10#$CT_ID))"
            return 0
        fi
        warn "${USBC_VALIDATE_ERROR}; try again"
    done
}

edit_hostname() {
    local default=$1
    while :; do
        ask CT_HOSTNAME "Hostname" "$default"
        if check_hostname "$CT_HOSTNAME"; then
            return 0
        fi
        warn "${USBC_VALIDATE_ERROR}; try again"
    done
}

edit_storage() {
    local default=$1
    while :; do
        ask CT_STORAGE "Storage for CT disk" "$default"
        if check_storage_name "$CT_STORAGE"; then
            return 0
        fi
        warn "${USBC_VALIDATE_ERROR}; try again"
    done
}

edit_network() {
    local current_mode=$1
    while :; do
        ask NET_MODE "Network mode (dhcp/static)" "$current_mode"
        NET_MODE=${NET_MODE,,}
        case "$NET_MODE" in
            dhcp)
                NET_IP=''
                NET_GW=''
                NET_DNS=''
                return 0
                ;;
            static)
                break
                ;;
            *)
                warn "network mode must be dhcp or static (got: $NET_MODE); try again"
                ;;
        esac
    done
    NET_IP=''
    NET_GW=''
    NET_DNS=''
    while :; do
        ask NET_IP "Static IP with prefix (e.g. 192.168.1.50/24)" ""
        if is_ipv4_cidr "$NET_IP"; then break; fi
        warn "invalid static IP (expected IPv4/prefix, e.g. 192.168.1.50/24): $NET_IP; try again"
    done
    while :; do
        ask NET_GW "Gateway" ""
        if is_ipv4 "$NET_GW"; then break; fi
        warn "invalid gateway: $NET_GW; try again"
    done
    while :; do
        ask NET_DNS "DNS servers (comma-separated, blank = gateway)" ""
        if [[ -z $NET_DNS ]]; then break; fi
        if is_dns_list "$NET_DNS"; then break; fi
        warn "invalid DNS server list: $NET_DNS; try again"
    done
}

edit_destination() {
    local label=$1
    local varname=$2
    local value=''
    local canonical=''
    local parent=''

    while :; do
        ask "$varname" "$label destination folder on host (required)" ""
        value=${!varname}
        if [[ -z $value ]]; then
            warn "$label destination is required"
            continue
        fi
        if ! canonical=$(check_destination "$label destination" "$value"); then
            warn "${USBC_VALIDATE_ERROR}; try again"
            continue
        fi
        if [[ -e $canonical && ! -d $canonical ]]; then
            warn "$label destination is not a directory: $canonical; try again"
            continue
        fi
        if [[ ! -e $canonical ]]; then
            parent=${canonical%/*}
            [[ -n $parent ]] || parent=/
            if [[ ! -d $parent ]]; then
                warn "$label destination parent directory does not exist: $parent (create it first or pick another folder); try again"
                continue
            fi
        fi
        printf -v "$varname" '%s' "$canonical"
        return 0
    done
}

edit_extra_destination() {
    local base=''
    local canonical=''

    while :; do
        ask DEST_EXTRA "Optional extra destination folder on host (enter to skip)" ""
        case "${DEST_EXTRA,,}" in
            '' | skip | none)
                DEST_EXTRA=''
                return 0
                ;;
        esac
        if ! canonical=$(check_destination "extra destination" "$DEST_EXTRA"); then
            warn "${USBC_VALIDATE_ERROR}; try again"
            continue
        fi
        if [[ -e $canonical && ! -d $canonical ]]; then
            warn "extra destination is not a directory: $canonical; try again"
            continue
        fi
        if [[ ! -e $canonical ]]; then
            parent=${canonical%/*}
            [[ -n $parent ]] || parent=/
            if [[ ! -d $parent ]]; then
                warn "extra destination parent directory does not exist: $parent (create it first or pick another folder); try again"
                continue
            fi
        fi
        base=${canonical##*/}
        if [[ ! $base =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
            warn "extra destination folder name must use letters, digits, dot, dash, or underscore: $base; try again"
            continue
        fi
        case "${base,,}" in
            movies | series)
                warn "extra destination must not use the reserved Movies or Series name: $base; try again"
                continue
                ;;
        esac
        DEST_EXTRA=$canonical
        return 0
    done
}

edit_source_folder() {
    local auto_default=$1
    local answer=''

    while :; do
        ask SOURCE_FOLDER "Default source folder for Auto mode (blank = copy the whole drive)" "$SOURCE_FOLDER"
        if check_source_folder "$SOURCE_FOLDER"; then
            break
        fi
        warn "${USBC_VALIDATE_ERROR}; try again"
    done
    while :; do
        ask answer "Enable Auto mode for that folder? (yes/no)" "$auto_default"
        case "${answer,,}" in
            y | yes | true | 1)
                AUTO_MODE=yes
                break
                ;;
            '' | n | no | false | 0)
                AUTO_MODE=no
                return 0
                ;;
            *)
                warn "Auto mode answer must be yes or no (got: $answer); try again"
                ;;
        esac
    done
    if [[ -z $SOURCE_FOLDER ]]; then
        warn "Auto mode requires a default source folder"
        while :; do
            ask SOURCE_FOLDER "Default source folder for Auto mode (required for Auto mode)" ""
            if [[ -n $SOURCE_FOLDER ]] && check_source_folder "$SOURCE_FOLDER"; then
                break
            fi
            warn "Auto mode requires a default source folder; try again"
        done
    fi
}

edit_port() {
    local default=$1
    while :; do
        ask PORT "Dashboard port" "$default"
        if check_port "$PORT"; then
            printf -v PORT '%d' "$((10#$PORT))"
            return 0
        fi
        warn "${USBC_VALIDATE_ERROR}; try again"
    done
}

edit_password() {
    while :; do
        ask_secret ADMIN_PASSWORD "Admin password (blank = auto-generate): "
        if [[ -z $ADMIN_PASSWORD ]]; then return 0; fi
        if check_password "$ADMIN_PASSWORD"; then
            return 0
        fi
        warn "${USBC_VALIDATE_ERROR}; try again"
    done
}

menu_defaults() {
    local default_storage=$1
    local default_ct_id=$2

    CT_ID=$default_ct_id
    CT_HOSTNAME='usbcopy'
    CT_STORAGE=$default_storage
    DISK_GB=8
    RAM_MB=1024
    CORES=2
    SWAP_MB=512
    NET_MODE='dhcp'
    NET_IP=''
    NET_GW=''
    NET_DNS=''
    DEST_MOVIES=''
    DEST_SERIES=''
    DEST_EXTRA=''
    SOURCE_FOLDER=''
    AUTO_MODE='no'
    PORT=8088
    ADMIN_PASSWORD=''
    ADMIN_PASSWORD_GENERATED=0
}

print_settings_table() {
    local network
    network=$(network_summary)
    local password_display="${USBC_C_DIM}auto-generate${USBC_C_RESET}"
    if [[ -n $ADMIN_PASSWORD ]]; then
        password_display="${USBC_C_GOOD}(set)${USBC_C_RESET}"
    fi
    local movies_display="${USBC_C_BAD}(not set - required)${USBC_C_RESET}"
    if [[ -n $DEST_MOVIES ]]; then
        movies_display="${USBC_C_GOOD}${DEST_MOVIES}${USBC_C_RESET}"
    fi
    local series_display="${USBC_C_BAD}(not set - required)${USBC_C_RESET}"
    if [[ -n $DEST_SERIES ]]; then
        series_display="${USBC_C_GOOD}${DEST_SERIES}${USBC_C_RESET}"
    fi
    local extra_display="${USBC_C_DIM}none${USBC_C_RESET}"
    if [[ -n $DEST_EXTRA ]]; then
        extra_display="${USBC_C_GOOD}${DEST_EXTRA}${USBC_C_RESET}"
    fi
    local source_display="${USBC_C_DIM}whole drive${USBC_C_RESET}"
    if [[ -n $SOURCE_FOLDER ]]; then
        source_display="${USBC_C_GOOD}${SOURCE_FOLDER}${USBC_C_RESET}"
    fi
    if [[ $AUTO_MODE == yes ]]; then
        source_display+=" ${USBC_C_GOOD}(Auto mode on)${USBC_C_RESET}"
    fi

    printf '\n'
    log "ready to install. These settings will be used:"
    printf '%s\n' "${USBC_C_DIM}  ----------------------------------------------------------------${USBC_C_RESET}"
    printf '  %2d. %-21s %s\n' 1 'CT ID' "${USBC_C_GOOD}${CT_ID}${USBC_C_RESET}"
    printf '  %2d. %-21s %s\n' 2 'Hostname' "${USBC_C_GOOD}${CT_HOSTNAME}${USBC_C_RESET}"
    printf '  %2d. %-21s %s\n' 3 'Storage' "${USBC_C_GOOD}${CT_STORAGE}${USBC_C_RESET}"
    printf '  %2d. %-21s %s\n' 4 'Disk size' "${USBC_C_GOOD}${DISK_GB} GB${USBC_C_RESET}"
    printf '  %2d. %-21s %s\n' 5 'RAM' "${USBC_C_GOOD}${RAM_MB} MB${USBC_C_RESET}"
    printf '  %2d. %-21s %s\n' 6 'CPU cores' "${USBC_C_GOOD}${CORES}${USBC_C_RESET}"
    printf '  %2d. %-21s %s\n' 7 'Swap' "${USBC_C_GOOD}${SWAP_MB} MB${USBC_C_RESET}"
    printf '  %2d. %-21s %s\n' 8 'Network' "${USBC_C_GOOD}${network}${USBC_C_RESET} (bridge ${CT_BRIDGE})"
    printf '  %2d. %-21s %s\n' 9 'Movies destination' "$movies_display"
    printf '  %2d. %-21s %s\n' 10 'Series destination' "$series_display"
    printf '  %2d. %-21s %s\n' 11 'Extra destination' "$extra_display"
    printf '  %2d. %-21s %s\n' 12 'Auto-mode source' "$source_display"
    printf '  %2d. %-21s %s\n' 13 'Dashboard port' "${USBC_C_GOOD}${PORT}${USBC_C_RESET}"
    printf '  %2d. %-21s %s\n' 14 'Admin password' "$password_display"
    printf '%s\n' "${USBC_C_DIM}  ----------------------------------------------------------------${USBC_C_RESET}"
    printf '\n'
    printf 'Press %s to install with these settings, or type a number to change it.\n' "${USBC_C_GOOD}Enter${USBC_C_RESET}"
    printf 'You can change as many as you like, one at a time.\n\n'
}

show_settings_menu() {
    local line=''

    while :; do
        print_settings_table
        if ! line=$(read_tty "${USBC_C_HEAD}Change a setting (1-14) or press Enter to install${USBC_C_RESET}: "); then
            die "could not read from the terminal"
        fi
        case "$line" in
            '')
                if [[ -z $DEST_MOVIES || -z $DEST_SERIES ]]; then
                    warn "the Movies and Series destinations are required; pick 9 and 10 from the menu first"
                    continue
                fi
                break
                ;;
            1) edit_ct_id "$CT_ID" ;;
            2) edit_hostname "$CT_HOSTNAME" ;;
            3) edit_storage "$CT_STORAGE" ;;
            4) edit_int DISK_GB "Disk size in GB" "$DISK_GB" 1 4096 ;;
            5) edit_int RAM_MB "RAM in MB" "$RAM_MB" 128 1048576 ;;
            6) edit_int CORES "CPU cores" "$CORES" 1 256 ;;
            7) edit_int SWAP_MB "Swap in MB" "$SWAP_MB" 0 1048576 ;;
            8) edit_network "$NET_MODE" ;;
            9) edit_destination "Movies" DEST_MOVIES ;;
            10) edit_destination "Series" DEST_SERIES ;;
            11) edit_extra_destination ;;
            12) edit_source_folder "$AUTO_MODE" ;;
            13) edit_port "$PORT" ;;
            14) edit_password ;;
            *)
                warn "Enter a number from 1 to 14 (or press Enter to install)"
                ;;
        esac
    done

    if [[ -z $ADMIN_PASSWORD ]]; then
        ADMIN_PASSWORD=$(generate_password)
        ADMIN_PASSWORD_GENERATED=1
    else
        ADMIN_PASSWORD_GENERATED=0
    fi
    validate_admin_password "$ADMIN_PASSWORD"
    ((${#ADMIN_PASSWORD} >= 8)) \
        || warn "admin password is shorter than 8 characters"
}

network_summary() {
    if [[ $NET_MODE == static ]]; then
        local text="static $NET_IP, gateway $NET_GW"
        if [[ -n $NET_DNS ]]; then
            text+=", dns $NET_DNS"
        fi
        printf '%s' "$text"
    else
        printf '%s' "DHCP"
    fi
}

print_summary() {
    local password_display='********'
    local auto_display='disabled'
    local extra_display='(none)'
    local source_display='(blank = whole drive in Auto mode)'
    local network

    if ((ADMIN_PASSWORD_GENERATED == 1)); then
        password_display='<generated>'
    fi
    if [[ $AUTO_MODE == yes ]]; then
        auto_display="enabled for ${SOURCE_FOLDER}"
    fi
    if [[ -n $DEST_EXTRA ]]; then
        extra_display=$DEST_EXTRA
    fi
    if [[ -n $SOURCE_FOLDER ]]; then
        source_display=$SOURCE_FOLDER
    fi
    network=$(network_summary)

    cat <<EOF
Installer summary
  CT ID:            $CT_ID
  Hostname:         $CT_HOSTNAME
  Storage:          $CT_STORAGE (template storage: $TEMPLATE_STORAGE)
  Resources:        ${DISK_GB} GB disk, ${RAM_MB} MB RAM, ${CORES} cores, ${SWAP_MB} MB swap
  Network:          $network (bridge $CT_BRIDGE)
  Movies:           $DEST_MOVIES
  Series:           $DEST_SERIES
  Extra destination: $extra_display
  Default source:   $source_display
  Auto mode:        $auto_display
  Dashboard port:   $PORT
  Admin user:       admin
  Admin password:   $password_display
  Install source:   $REPO_URL@$REPO_REF
EOF
}

confirm_summary() {
    local answer=''

    print_summary
    if ((ASSUME_YES == 1)); then
        log "proceeding without confirmation because --yes was given"
        return 0
    fi
    if ((USBC_ANSWERS_SET == 1)); then
        if ! take_answer; then
            return 0
        fi
        case "${USBC_ANSWER_VALUE,,}" in
            '' | y | yes)
                return 0
                ;;
            n | no)
                log "aborted by user"
                exit 0
                ;;
            *)
                die "confirmation answer must be yes or no (got: $USBC_ANSWER_VALUE)"
                ;;
        esac
    fi
    if ! answer=$(read_tty "Proceed with these settings? [Y/n]: "); then
        die "confirmation failed: could not read from the terminal"
    fi
    case "${answer,,}" in
        '' | y | yes)
            return 0
            ;;
        n | no)
            log "aborted by user"
            exit 0
            ;;
        *)
            die "confirmation answer must be yes or no (got: $answer)"
            ;;
    esac
}
