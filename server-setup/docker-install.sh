#!/usr/bin/env bash

set -Eeo pipefail
umask 022

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SERVER_SETUP_ENV:-$SCRIPT_DIR/.env}"

[[ $EUID -eq 0 ]] || { printf 'Docker installation must be run as root.\n' >&2; exit 1; }
[[ -r $ENV_FILE ]] || { printf 'Configuration file is not readable: %s\n' "$ENV_FILE" >&2; exit 1; }

# shellcheck source=/dev/null
source "$ENV_FILE"
set -u

SCRIPT_USER="${SCRIPT_USER:-${SUDO_USER:-}}"
DEBIAN_CODENAME="${DEBIAN_CODENAME:-$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")}"
ARCH="${ARCH:-$(dpkg --print-architecture)}"
DOCKER_GPG_KEYRING="${DOCKER_GPG_KEYRING:-/etc/apt/keyrings/docker.asc}"
DOCKER_SOURCE_FILE="${DOCKER_SOURCE_FILE:-/etc/apt/sources.list.d/docker.list}"

required=(SCRIPT_USER GPG_URL DOCKER_SOURCE_LIST_URL DOCKER_SOURCE_LIST_COMPONENT DEBIAN_CODENAME ARCH)
for name in "${required[@]}"; do
    [[ -n ${!name:-} ]] || { printf 'Required Docker configuration is empty: %s\n' "$name" >&2; exit 1; }
done

getent passwd "$SCRIPT_USER" >/dev/null || { printf 'Configured user does not exist: %s\n' "$SCRIPT_USER" >&2; exit 1; }
for command_name in apt-get curl dpkg dpkg-query getent grep groupadd install systemctl usermod; do
    command -v "$command_name" >/dev/null 2>&1 || { printf 'Required command is unavailable: %s\n' "$command_name" >&2; exit 1; }
done

packages_to_remove=(docker.io docker-doc docker-compose podman-docker containerd runc)
packages_to_install=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

export DEBIAN_FRONTEND=noninteractive
installed_conflicts=()
for package_name in "${packages_to_remove[@]}"; do
    if dpkg-query -W -f='${db:Status-Abbrev}' "$package_name" 2>/dev/null | grep -q '^ii'; then
        installed_conflicts+=("$package_name")
    fi
done
if ((${#installed_conflicts[@]} > 0)); then
    apt-get remove -y "${installed_conflicts[@]}"
fi
apt-get update
apt-get install -y ca-certificates curl

install -d -o root -g root -m 0755 "$(dirname -- "$DOCKER_GPG_KEYRING")"
curl --fail --silent --show-error --location "$GPG_URL" --output "$DOCKER_GPG_KEYRING"
chmod 0644 "$DOCKER_GPG_KEYRING"

install -d -o root -g root -m 0755 "$(dirname -- "$DOCKER_SOURCE_FILE")"
printf 'deb [arch=%s signed-by=%s] %s %s %s\n' \
    "$ARCH" "$DOCKER_GPG_KEYRING" "$DOCKER_SOURCE_LIST_URL" "$DEBIAN_CODENAME" "$DOCKER_SOURCE_LIST_COMPONENT" \
    >"$DOCKER_SOURCE_FILE"
chmod 0644 "$DOCKER_SOURCE_FILE"

apt-get update
apt-get install -y "${packages_to_install[@]}"
systemctl enable --now docker
groupadd -f docker
usermod -aG docker "$SCRIPT_USER"

command -v docker >/dev/null 2>&1 || { printf 'Docker CLI was not installed successfully.\n' >&2; exit 1; }
docker --version
docker compose version
printf 'Docker installed. User %s must log out and back in before using Docker without sudo.\n' "$SCRIPT_USER"
