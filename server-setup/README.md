# Debian Server Setup

`server-setup.sh` performs an interactive, nine-step Debian server setup with package-install progress percentages, validation, persistent logging, and configurable defaults.

## Setup steps

1. Configure APT sources and optionally upgrade packages.
2. Install base packages and `iptables-persistent`.
3. Configure validated passwordless sudo.
4. Initialize `authorized_keys` and add configured or interactive SSH keys.
5. Stage, validate, back up, and reload the SSH configuration.
6. Add idempotent iptables rules before enabling restrictive policies.
7. Install Docker Engine from a configured APT repository.
8. Optionally disable IPv6 using an idempotent sysctl file.
9. Create a user-owned workspace directory.

Command output is written to `/var/log/server-setup.log` by default. A failed SSH reload restores the previous configuration, and firewall allow rules are installed before restrictive policies to reduce lockout risk.

## Usage

Create the local configuration from the example and adjust it for the server:

```bash
cp .env.example .env
sudo ./server-setup.sh
```

Options:

```text
-e, --env FILE         Load another configuration file
-y, --yes              Run every step without confirmation
-n, --non-interactive  Use each step's configured default answer
-h, --help             Show help
```

The script resolves `.env` and `docker-install.sh` relative to its own directory, so it can be launched from any working directory.

## Configuration

`.env` is Bash syntax. Arrays must use Bash array syntax, for example:

```bash
PACKAGES_TO_INSTALL=(curl git htop)
IPTABLES_ALLOW_PORTS=(80 443)
SSH_PUBLIC_KEYS=(
    "ssh-ed25519 AAAA... admin@example"
)
```

The main behavior switches are:

| Variable | Default | Purpose |
| --- | --- | --- |
| `APT_RUN_UPGRADE` | `true` | Upgrade installed packages after changing sources |
| `APT_INSTALL_RECOMMENDS` | `false` | Install APT recommended packages |
| `APT_ENABLE_BACKPORTS` | `true` | Add the Debian backports source |
| `APT_ENABLE_PROPOSED` | `false` | Add proposed updates; normally leave disabled on production servers |
| `ALLOW_SSH_LOCKOUT` | `false` | Permit password auth to be disabled without a configured public key |
| `SERVER_SETUP_LOG` | `/var/log/server-setup.log` | Detailed command log |
| `WORKSPACE_DIR` | `/home/$SCRIPT_USER/workspace` | Workspace destination |

Each step has a `STEP_*_DEFAULT` variable containing `Y` or `N`. Passwordless sudo and IPv6 disabling default to `N`; see `.env.example` for the full list.

## Safety notes

- Keep an existing root or console session open while applying SSH and firewall changes.
- Put the selected SSH port in `PORT`; it is automatically allowed by the firewall step.
- Review mirror URLs and the Docker GPG URL before running the script as root.
- `--yes` opts into every step, including passwordless sudo and disabling IPv6.
