# Bash Scripts Collection

A collection of bash scripts for setting up, maintaining, and backing up Debian-based servers.

## Configuration

Scripts read their settings from Bash-syntax `.env` files. These files are gitignored, so create them from the templates:

```bash
cp .env.example .env                            # root scripts
cp server-setup/.env.example server-setup/.env  # server-setup
```

| File | Used by |
| --- | --- |
| `.env` | `jira-backup.sh`, `confluence-backup.sh`, `backup-*-postgres-db.sh`, `docker-install.sh`, `systemd-service-starter.sh` |
| `server-setup/.env` | `server-setup/server-setup.sh`, `server-setup/docker-install.sh` |

The backup scripts accept `ENV_FILE=/path/to/file` to use a different config. The server-setup scripts accept `--env FILE` or `SERVER_SETUP_ENV=/path/to/file`. `docker-install.sh` and `systemd-service-starter.sh` read `.env` from the current directory, so run them from the repo root.

The remaining scripts are interactive and take no config.

## Scripts

### Backups

| Script | Description |
| --- | --- |
| `jira-backup.sh` | Backs up a Dockerized Jira over SSH: database (`pg_dump -Fc`), Jira home, and compose config. Uses `JIRA_*` variables. |
| `confluence-backup.sh` | Same as above for Confluence. Uses `CONFLUENCE_*` variables. |
| `backup-docker-postgres-db.sh` | Dumps PostgreSQL databases running in a Docker Compose service on a remote host. Supports `--dry-run`. Uses `POSTGRES_*` variables. |
| `backup-system-postgres-db.sh` | Dumps PostgreSQL databases from a system (non-Docker) install on a remote host. Supports `--dry-run`. Uses `POSTGRES_*` variables. |
| `backup.sh` | Interactively archives a directory into a `.tgz` file. |

The Jira and Confluence backups write each run to `<BACKUP_DIR>/YYYY-MM-DD_HHMM/`, move previous runs to `<BACKUP_DIR>/old-backups/`, and delete archived files older than the retention period. Each run is built in a `.partial` directory and only renamed into place once every step succeeds.

### Server setup

| Script | Description |
| --- | --- |
| `server-setup/server-setup.sh` | Interactive Debian server setup (APT, packages, sudo, SSH hardening, firewall, Docker). See [server-setup/README.md](server-setup/README.md); it has its own `.env`. |
| `docker-install.sh` | Installs Docker Engine from Docker's APT repository. Run as root. |
| `ansible-install.sh` | Installs Ansible with `pipx`. |
| `passwordless-sudo.sh` | Enables passwordless sudo for a user. Run as root. |
| `dns.sh` | Writes nameservers to `resolv.conf` and upgrades packages. |
| `apt-sources-list/mint-apt-sourcelist.sh` | Downloads a source list from a URL into `/etc/apt/sources.list.d/` and runs `apt update`. |
| `apt-sources-list/remote-apt-sourcelist.sh` | Same as above, on a remote host from `~/.ssh/config`. |

### Operations

| Script | Description |
| --- | --- |
| `systemd-service-starter.sh` | Starts any service in `SERVICES` that is inactive or failed. |
| `service-health-checker.sh` | Checks a systemd service's status on a host from `~/.ssh/config`. |
| `password-generator.sh` | Generates a random hex or base64 password. |

## Scheduling backups

Example crontab entries:

```cron
0 2 * * * /path/to/scripts/jira-backup.sh >> /var/log/jira-backup.log 2>&1
30 2 * * * /path/to/scripts/confluence-backup.sh >> /var/log/confluence-backup.log 2>&1
```
