#!/usr/bin/env bash

set -Eeo pipefail
umask 022

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TOTAL_STEPS=9

ENV_FILE="${SERVER_SETUP_ENV:-$SCRIPT_DIR/.env}"
ASSUME_YES=false
NON_INTERACTIVE=false
COMPLETED_STEPS=0
CURRENT_STEP="initialization"
START_SECONDS=$SECONDS
APT_INDEX_REFRESHED=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Set up and harden a Debian server interactively.

Options:
  -e, --env FILE         Load configuration from FILE (default: $SCRIPT_DIR/.env)
  -y, --yes              Answer yes to every step
  -n, --non-interactive  Use each step's configured default answer
  -h, --help             Show this help text
EOF
}

while (($# > 0)); do
    case "$1" in
        -e|--env)
            [[ $# -ge 2 ]] || { printf 'Missing value for %s\n' "$1" >&2; exit 2; }
            ENV_FILE=$2
            shift 2
            ;;
        -y|--yes)
            ASSUME_YES=true
            shift
            ;;
        -n|--non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ $EUID -eq 0 ]] || { printf 'This script must be run as root (sudo).\n' >&2; exit 1; }
[[ -r $ENV_FILE ]] || { printf 'Configuration file is not readable: %s\n' "$ENV_FILE" >&2; exit 1; }

# shellcheck source=/dev/null
source "$ENV_FILE"
set -u

# Derived paths are computed here so config variable order cannot corrupt them.
SCRIPT_USER="${SCRIPT_USER:-${SUDO_USER:-}}"
REPO_NAME="${REPO_NAME:-debian}"
if [[ ${APT_TARGET:-} == /etc/apt/sources.list.d/.list ]]; then
    unset APT_TARGET
fi
APT_TARGET="${APT_TARGET:-/etc/apt/sources.list.d/${REPO_NAME}.list}"
SUDOERS_FILE="${SUDOERS_FILE:-/etc/sudoers.d/${SCRIPT_USER}}"
SSH_DIR="${SSH_DIR:-/home/${SCRIPT_USER}/.ssh}"
AUTH_KEYS="${AUTH_KEYS:-${SSH_DIR}/authorized_keys}"
SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"
BACKUP_SSHD="${BACKUP_SSHD:-${SSHD_CONFIG}.server-setup.bak}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/home/${SCRIPT_USER}/workspace}"
LOG_FILE="${SERVER_SETUP_LOG:-/var/log/server-setup.log}"

APT_RUN_UPGRADE="${APT_RUN_UPGRADE:-true}"
APT_INSTALL_RECOMMENDS="${APT_INSTALL_RECOMMENDS:-false}"
APT_ENABLE_BACKPORTS="${APT_ENABLE_BACKPORTS:-true}"
APT_ENABLE_PROPOSED="${APT_ENABLE_PROPOSED:-false}"
ALLOW_SSH_LOCKOUT="${ALLOW_SSH_LOCKOUT:-false}"
WORKSPACE_MODE="${WORKSPACE_MODE:-0755}"

STEP_APT_SOURCES_DEFAULT="${STEP_APT_SOURCES_DEFAULT:-Y}"
STEP_PACKAGES_DEFAULT="${STEP_PACKAGES_DEFAULT:-Y}"
STEP_PASSWORDLESS_SUDO_DEFAULT="${STEP_PASSWORDLESS_SUDO_DEFAULT:-N}"
STEP_SSH_KEYS_DEFAULT="${STEP_SSH_KEYS_DEFAULT:-Y}"
STEP_SSH_HARDENING_DEFAULT="${STEP_SSH_HARDENING_DEFAULT:-Y}"
STEP_FIREWALL_DEFAULT="${STEP_FIREWALL_DEFAULT:-Y}"
STEP_DOCKER_DEFAULT="${STEP_DOCKER_DEFAULT:-Y}"
STEP_DISABLE_IPV6_DEFAULT="${STEP_DISABLE_IPV6_DEFAULT:-N}"
STEP_WORKSPACE_DEFAULT="${STEP_WORKSPACE_DEFAULT:-Y}"

if ! declare -p PACKAGES_TO_INSTALL &>/dev/null; then
    PACKAGES_TO_INSTALL=()
fi
if ! declare -p IPTABLES_ALLOW_PORTS &>/dev/null; then
    IPTABLES_ALLOW_PORTS=()
fi
if ! declare -p SSH_PUBLIC_KEYS &>/dev/null; then
    SSH_PUBLIC_KEYS=()
fi

mkdir -p -- "$(dirname -- "$LOG_FILE")"
touch -- "$LOG_FILE"
chmod 0600 "$LOG_FILE"
exec 3>>"$LOG_FILE"

log() {
    printf '%s\n' "$*"
    printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*" >&3
}

warn() {
    log "WARNING: $*"
}

die() {
    log "ERROR: $*"
    exit 1
}

on_error() {
    local status=$?
    local line=$1
    log "ERROR: Step '$CURRENT_STEP' failed at line $line (exit $status)."
    log "Review the log for command output: $LOG_FILE"
    exit "$status"
}
trap 'on_error "$LINENO"' ERR

run_logged() {
    local description=$1
    shift
    log "$description"
    if "$@" >>"$LOG_FILE" 2>&1; then
        return 0
    else
        local status=$?
        log "ERROR: $description failed (exit $status). Last log lines:"
        tail -n 15 "$LOG_FILE"
        return "$status"
    fi
}

require_vars() {
    local name
    for name in "$@"; do
        [[ -n ${!name:-} ]] || die "Required configuration variable '$name' is empty."
    done
}

require_commands() {
    local command_name
    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 || die "Required command is unavailable: $command_name"
    done
}

validate_boolean() {
    local name=$1
    case "${!name,,}" in
        true|false|yes|no|1|0) ;;
        *) die "$name must be true or false (current value: ${!name})." ;;
    esac
}

is_true() {
    case "${1,,}" in
        true|yes|1) return 0 ;;
        *) return 1 ;;
    esac
}

confirm() {
    local prompt=$1
    local default=${2^^}
    local answer

    [[ $default == Y || $default == N ]] || die "Invalid prompt default '$2' for: $prompt"
    if $ASSUME_YES; then
        log "$prompt [yes: --yes]"
        return 0
    fi
    if $NON_INTERACTIVE || [[ ! -t 0 ]]; then
        log "$prompt [${default,,}: configured default]"
        [[ $default == Y ]]
        return
    fi

    while true; do
        if [[ $default == Y ]]; then
            read -r -p "$prompt [Y/n] " answer
        else
            read -r -p "$prompt [y/N] " answer
        fi
        answer=${answer:-$default}
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) log "Please answer yes or no." ;;
        esac
    done
}

run_step() {
    local label=$1
    local prompt=$2
    local default=$3
    local function_name=$4
    local step_number=$((COMPLETED_STEPS + 1))
    local result

    CURRENT_STEP=$label
    printf '\nStep %d/%d: %s\n' "$step_number" "$TOTAL_STEPS" "$label"
    if confirm "$prompt" "$default"; then
        "$function_name"
        result="completed"
    else
        result="skipped"
    fi

    COMPLETED_STEPS=$step_number
    printf 'Step %d/%d %s: %s\n' "$step_number" "$TOTAL_STEPS" "$result" "$label"
}

show_subprogress() {
    local current=$1 total=$2 label=$3
    local percent=$((current * 100 / total))
    printf '[%3d%%] %s (%d/%d)\n' "$percent" "$label" "$current" "$total"
}

validate_config() {
    [[ -f /etc/debian_version ]] || die "This script supports Debian-based systems only."
    require_vars SCRIPT_USER
    require_commands apt-get install getent
    getent passwd "$SCRIPT_USER" >/dev/null || die "Configured user does not exist: $SCRIPT_USER"

    validate_boolean APT_RUN_UPGRADE
    validate_boolean APT_INSTALL_RECOMMENDS
    validate_boolean APT_ENABLE_BACKPORTS
    validate_boolean APT_ENABLE_PROPOSED
    validate_boolean ALLOW_SSH_LOCKOUT

    [[ $(declare -p PACKAGES_TO_INSTALL 2>/dev/null) == "declare -a"* ]] || die "PACKAGES_TO_INSTALL must be a Bash array."
    [[ $(declare -p IPTABLES_ALLOW_PORTS 2>/dev/null) == "declare -a"* ]] || die "IPTABLES_ALLOW_PORTS must be a Bash array."
    [[ $(declare -p SSH_PUBLIC_KEYS 2>/dev/null) == "declare -a"* ]] || die "SSH_PUBLIC_KEYS must be a Bash array."
}

apt_update() {
    if $APT_INDEX_REFRESHED; then
        log "APT package indexes were already refreshed; skipping duplicate update."
        return 0
    fi
    run_logged "Refreshing APT package indexes..." env DEBIAN_FRONTEND=noninteractive apt-get update
    APT_INDEX_REFRESHED=true
}

step_apt_sources() {
    require_vars APT_URL APT_SECURITY_URL DEBIAN_CODENAME APT_COMPONENTS APT_TARGET

    local target_dir staged
    target_dir=$(dirname -- "$APT_TARGET")
    mkdir -p -- "$target_dir"
    staged=$(mktemp "$target_dir/.server-setup-sources.XXXXXX")

    {
        printf 'deb %s %s %s\n' "$APT_URL" "$DEBIAN_CODENAME" "$APT_COMPONENTS"
        printf 'deb %s %s-updates %s\n' "$APT_URL" "$DEBIAN_CODENAME" "$APT_COMPONENTS"
        if is_true "$APT_ENABLE_PROPOSED"; then
            printf 'deb %s %s-proposed-updates %s\n' "$APT_URL" "$DEBIAN_CODENAME" "$APT_COMPONENTS"
        fi
        if is_true "$APT_ENABLE_BACKPORTS"; then
            printf 'deb %s %s-backports %s\n' "$APT_URL" "$DEBIAN_CODENAME" "$APT_COMPONENTS"
        fi
        printf 'deb %s %s-security %s\n' "$APT_SECURITY_URL" "$DEBIAN_CODENAME" "$APT_COMPONENTS"
    } >"$staged"

    install -o root -g root -m 0644 "$staged" "$APT_TARGET"
    rm -f -- "$staged"
    log "APT sources written to $APT_TARGET"
    apt_update
    if is_true "$APT_RUN_UPGRADE"; then
        run_logged "Upgrading installed packages..." env DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
    fi
}

step_packages() {
    require_commands debconf-set-selections
    printf 'iptables-persistent iptables-persistent/autosave_v4 boolean %s\n' "${IPT_PERSISTENT:-true}" | debconf-set-selections
    printf 'iptables-persistent iptables-persistent/autosave_v6 boolean %s\n' "${IPT_PERSISTENT:-true}" | debconf-set-selections

    apt_update
    local apt_options=(-y)
    local packages=("${PACKAGES_TO_INSTALL[@]}" iptables-persistent)
    local failed_packages=()
    local index package_name
    if ! is_true "$APT_INSTALL_RECOMMENDS"; then
        apt_options+=(--no-install-recommends)
    fi

    for index in "${!packages[@]}"; do
        package_name=${packages[$index]}
        [[ $package_name =~ ^[a-zA-Z0-9][a-zA-Z0-9+.:~-]*$ ]] || die "Invalid APT package name: $package_name"
        show_subprogress "$((index + 1))" "${#packages[@]}" "Installing $package_name"
        if ! run_logged "Installing package: $package_name" \
            env DEBIAN_FRONTEND=noninteractive apt-get install "${apt_options[@]}" "$package_name"; then
            failed_packages+=("$package_name")
        fi
    done

    if ((${#failed_packages[@]} > 0)); then
        die "Package installation failed for: ${failed_packages[*]}"
    fi
}

step_passwordless_sudo() {
    require_commands visudo
    local target_dir staged
    target_dir=$(dirname -- "$SUDOERS_FILE")
    mkdir -p -- "$target_dir"
    staged=$(mktemp "$target_dir/.server-setup-sudoers.XXXXXX")
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$SCRIPT_USER" >"$staged"
    chmod 0440 "$staged"
    visudo -cf "$staged" >>"$LOG_FILE" 2>&1 || { rm -f -- "$staged"; die "Generated sudoers configuration is invalid."; }
    install -o root -g root -m 0440 "$staged" "$SUDOERS_FILE"
    rm -f -- "$staged"
    log "Passwordless sudo enabled in $SUDOERS_FILE"
}

add_ssh_key() {
    local key=$1
    [[ -n $key ]] || return 0
    if grep -qxF -- "$key" "$AUTH_KEYS"; then
        log "SSH key already present; skipped."
    else
        printf '%s\n' "$key" >>"$AUTH_KEYS"
        log "SSH key added."
    fi
}

step_ssh_keys() {
    local user_group key
    user_group=$(id -gn "$SCRIPT_USER")
    install -d -o "$SCRIPT_USER" -g "$user_group" -m 0700 "$SSH_DIR"
    if [[ ! -e $AUTH_KEYS ]]; then
        install -o "$SCRIPT_USER" -g "$user_group" -m 0600 /dev/null "$AUTH_KEYS"
    else
        chown "$SCRIPT_USER:$user_group" "$AUTH_KEYS"
        chmod 0600 "$AUTH_KEYS"
    fi

    for key in "${SSH_PUBLIC_KEYS[@]}"; do
        add_ssh_key "$key"
    done

    if ((${#SSH_PUBLIC_KEYS[@]} == 0)); then
        if [[ -t 0 ]] && ! $NON_INTERACTIVE && ! $ASSUME_YES; then
            log "Enter SSH public keys one at a time; type 'done' when finished."
            while true; do
                read -r -p "SSH public key: " key
                [[ ${key,,} == done ]] && break
                add_ssh_key "$key"
            done
        else
            warn "No SSH_PUBLIC_KEYS were configured; authorized_keys was only initialized."
        fi
    fi
}

set_sshd_option() {
    local file=$1 name=$2 value=$3
    local output
    output=$(mktemp "$(dirname -- "$file")/.server-setup-sshd-option.XXXXXX")
    awk -v option_name="$name" -v option_value="$value" '
        BEGIN { in_match = 0; written = 0 }
        {
            raw = $0
            sub(/^[[:space:]]*/, "", raw)
            uncommented = raw !~ /^#/
            comparable = raw
            sub(/^#[[:space:]]*/, "", comparable)
            split(comparable, fields, /[[:space:]]+/)

            if (uncommented && tolower(fields[1]) == "match") {
                if (!written) {
                    print option_name " " option_value
                    written = 1
                }
                in_match = 1
            }

            if (!in_match && tolower(fields[1]) == tolower(option_name)) {
                if (!written) {
                    print option_name " " option_value
                    written = 1
                }
                next
            }
            print
        }
        END {
            if (!written) {
                print option_name " " option_value
            }
        }
    ' "$file" >"$output"
    mv -- "$output" "$file"
}

step_ssh_hardening() {
    require_vars PORT PERMIT_ROOT_LOGIN MAX_AUTH_TRIES PUBKEY_AUTH PASSWORD_AUTH EMPTY_PASS \
        KBD_INTERACTIVE_AUTH KERBEROS_AUTH GSS_AUTH USE_PAM X11_FORWARDING PRINT_MOTD
    require_commands awk sshd systemctl
    [[ -f $SSHD_CONFIG ]] || die "SSHD configuration does not exist: $SSHD_CONFIG"
    [[ $PORT =~ ^[0-9]+$ ]] && ((PORT >= 1 && PORT <= 65535)) || die "PORT must be between 1 and 65535."
    if [[ ${PASSWORD_AUTH,,} == no ]] && ! is_true "$ALLOW_SSH_LOCKOUT"; then
        if [[ ! -s $AUTH_KEYS ]] || ! grep -Eq '^[^#[:space:]]' "$AUTH_KEYS"; then
            die "Password authentication cannot be disabled before adding a public key to $AUTH_KEYS"
        fi
    fi

    local staged config_mode
    staged=$(mktemp "$(dirname -- "$SSHD_CONFIG")/.server-setup-sshd.XXXXXX")
    cp -- "$SSHD_CONFIG" "$staged"
    set_sshd_option "$staged" Port "$PORT"
    set_sshd_option "$staged" PermitRootLogin "$PERMIT_ROOT_LOGIN"
    set_sshd_option "$staged" MaxAuthTries "$MAX_AUTH_TRIES"
    set_sshd_option "$staged" PubkeyAuthentication "$PUBKEY_AUTH"
    set_sshd_option "$staged" PasswordAuthentication "$PASSWORD_AUTH"
    set_sshd_option "$staged" PermitEmptyPasswords "$EMPTY_PASS"
    set_sshd_option "$staged" KbdInteractiveAuthentication "$KBD_INTERACTIVE_AUTH"
    set_sshd_option "$staged" KerberosAuthentication "$KERBEROS_AUTH"
    set_sshd_option "$staged" GSSAPIAuthentication "$GSS_AUTH"
    set_sshd_option "$staged" UsePAM "$USE_PAM"
    set_sshd_option "$staged" X11Forwarding "$X11_FORWARDING"
    set_sshd_option "$staged" PrintMotd "$PRINT_MOTD"

    if ! sshd -t -f "$staged" >>"$LOG_FILE" 2>&1; then
        rm -f -- "$staged"
        die "Generated SSH configuration failed validation; the active file was not changed."
    fi

    cp -a -- "$SSHD_CONFIG" "$BACKUP_SSHD"
    config_mode=$(stat -c '%a' "$SSHD_CONFIG")
    install -o root -g root -m "$config_mode" "$staged" "$SSHD_CONFIG"
    rm -f -- "$staged"

    if systemctl reload ssh >>"$LOG_FILE" 2>&1 || systemctl reload sshd >>"$LOG_FILE" 2>&1; then
        log "SSHD configuration validated and reloaded; backup: $BACKUP_SSHD"
    else
        cp -a -- "$BACKUP_SSHD" "$SSHD_CONFIG"
        die "Could not reload SSH; the previous configuration was restored."
    fi
}

add_iptables_rule() {
    local chain=$1
    shift
    if ! iptables -C "$chain" "$@" >/dev/null 2>&1; then
        iptables -A "$chain" "$@"
    fi
}

step_firewall() {
    require_vars IPTABLES_INPUT IPTABLES_FORWARD IPTABLES_OUTPUT IPTABLES_DOCKER_FORWARD PORT
    require_commands iptables iptables-save
    [[ $IPTABLES_INPUT =~ ^(ACCEPT|DROP)$ ]] || die "IPTABLES_INPUT must be ACCEPT or DROP."
    [[ $IPTABLES_FORWARD =~ ^(ACCEPT|DROP)$ ]] || die "IPTABLES_FORWARD must be ACCEPT or DROP."
    [[ $IPTABLES_OUTPUT =~ ^(ACCEPT|DROP)$ ]] || die "IPTABLES_OUTPUT must be ACCEPT or DROP."
    [[ $IPTABLES_DOCKER_FORWARD =~ ^(ACCEPT|DROP|REJECT)$ ]] || die "Invalid IPTABLES_DOCKER_FORWARD target."
    local port
    for port in "$PORT" "${IPTABLES_ALLOW_PORTS[@]}"; do
        [[ $port =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || die "Invalid TCP port in firewall config: $port"
    done

    # Install allow rules before restrictive policies to protect the active SSH session.
    add_iptables_rule INPUT -i lo -j ACCEPT
    add_iptables_rule INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    add_iptables_rule INPUT -p tcp --dport "$PORT" -j ACCEPT
    for port in "${IPTABLES_ALLOW_PORTS[@]}"; do
        [[ $port == "$PORT" ]] || add_iptables_rule INPUT -p tcp --dport "$port" -j ACCEPT
    done
    add_iptables_rule INPUT -p icmp -j ACCEPT
    add_iptables_rule FORWARD -i docker0 -o docker0 -j "$IPTABLES_DOCKER_FORWARD"
    add_iptables_rule FORWARD -i docker0 ! -o docker0 -j "$IPTABLES_DOCKER_FORWARD"
    add_iptables_rule FORWARD -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j "$IPTABLES_DOCKER_FORWARD"

    iptables -P INPUT "$IPTABLES_INPUT"
    iptables -P FORWARD "$IPTABLES_FORWARD"
    iptables -P OUTPUT "$IPTABLES_OUTPUT"

    if command -v netfilter-persistent >/dev/null 2>&1; then
        run_logged "Saving firewall rules..." netfilter-persistent save
    else
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
        if command -v ip6tables-save >/dev/null 2>&1; then
            ip6tables-save > /etc/iptables/rules.v6
        fi
    fi
    log "Firewall configured without duplicating existing managed rules."
}

step_docker() {
    [[ -r $SCRIPT_DIR/docker-install.sh ]] || die "Docker installer is missing: $SCRIPT_DIR/docker-install.sh"
    run_logged "Installing Docker Engine..." env SERVER_SETUP_ENV="$ENV_FILE" bash "$SCRIPT_DIR/docker-install.sh"
}

step_disable_ipv6() {
    require_commands sysctl
    local target=/etc/sysctl.d/99-disable-ipv6.conf
    local staged
    staged=$(mktemp /etc/sysctl.d/.server-setup-ipv6.XXXXXX)
    cat >"$staged" <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    install -o root -g root -m 0644 "$staged" "$target"
    rm -f -- "$staged"
    run_logged "Applying sysctl configuration..." sysctl --system
    log "IPv6 disable settings written to $target"
}

step_workspace() {
    local user_group
    user_group=$(id -gn "$SCRIPT_USER")
    install -d -o "$SCRIPT_USER" -g "$user_group" -m "$WORKSPACE_MODE" "$WORKSPACE_DIR"
    log "Workspace ready at $WORKSPACE_DIR"
}

validate_config
log "Debian server setup started for user '$SCRIPT_USER' using $ENV_FILE"
log "Detailed command output: $LOG_FILE"

run_step "APT sources" "Update the APT source list?" "$STEP_APT_SOURCES_DEFAULT" step_apt_sources
run_step "Base packages" "Install base packages?" "$STEP_PACKAGES_DEFAULT" step_packages
run_step "Passwordless sudo" "Enable passwordless sudo for '$SCRIPT_USER'?" "$STEP_PASSWORDLESS_SUDO_DEFAULT" step_passwordless_sudo
run_step "SSH keys" "Add SSH public keys for '$SCRIPT_USER'?" "$STEP_SSH_KEYS_DEFAULT" step_ssh_keys
run_step "SSH hardening" "Harden and reload the SSH server configuration?" "$STEP_SSH_HARDENING_DEFAULT" step_ssh_hardening
run_step "Firewall" "Configure and persist iptables rules?" "$STEP_FIREWALL_DEFAULT" step_firewall
run_step "Docker" "Install Docker Engine?" "$STEP_DOCKER_DEFAULT" step_docker
run_step "Disable IPv6" "Disable IPv6 using sysctl?" "$STEP_DISABLE_IPV6_DEFAULT" step_disable_ipv6
run_step "Workspace" "Create the workspace directory?" "$STEP_WORKSPACE_DEFAULT" step_workspace

CURRENT_STEP="finished"
log "Server setup finished in $((SECONDS - START_SECONDS)) seconds."
