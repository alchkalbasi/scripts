#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
source "$ENV_FILE"

: "${CONFLUENCE_SSH_TARGET:?required in $ENV_FILE}"
: "${CONFLUENCE_SSH_KEY:?required in $ENV_FILE}"
: "${CONFLUENCE_APP_CONTAINER:?required in $ENV_FILE}"
: "${CONFLUENCE_DB_CONTAINER:?required in $ENV_FILE}"
: "${CONFLUENCE_DATA_PATH:?required in $ENV_FILE}"
: "${CONFLUENCE_COMPOSE_DIR:?required in $ENV_FILE}"
: "${CONFLUENCE_BACKUP_DIR:?required in $ENV_FILE}"
: "${CONFLUENCE_BACKUP_RETENTION_DAYS:?required in $ENV_FILE}"

TARGET_DIR="$CONFLUENCE_BACKUP_DIR/$(date +%F_%H%M)"
WORK_DIR="$TARGET_DIR.partial"
OLD_BACKUP_DIR="$CONFLUENCE_BACKUP_DIR/old-backups"

log() { echo "[$(date '+%F %T')] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

remote() {
    ssh -i "$CONFLUENCE_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 \
        "$CONFLUENCE_SSH_TARGET" "$@"
}

trap 'rm -rf "$WORK_DIR"' EXIT

remote true || die "cannot connect to $CONFLUENCE_SSH_TARGET"
mkdir -p "$WORK_DIR"

log "Dumping database from $CONFLUENCE_DB_CONTAINER"
remote "docker exec $CONFLUENCE_DB_CONTAINER sh -c 'pg_dump -U \"\$POSTGRES_USER\" -Fc \"\$POSTGRES_DB\"'" \
    > "$WORK_DIR/database.dump"
[[ "$(head -c 5 "$WORK_DIR/database.dump")" == "PGDMP" ]] || die "database dump is invalid"

log "Archiving Confluence home from $CONFLUENCE_APP_CONTAINER"
# tar exits 1 when files change while being read, which is expected on a live instance
remote "docker exec $CONFLUENCE_APP_CONTAINER sh -c 'tar -czf - --warning=no-file-changed --exclude=./temp --exclude=./logs -C $CONFLUENCE_DATA_PATH . ; [ \$? -le 1 ]'" \
    > "$WORK_DIR/confluence-home.tar.gz"
gzip -t "$WORK_DIR/confluence-home.tar.gz" || die "home archive is corrupted"

log "Archiving compose config from $CONFLUENCE_COMPOSE_DIR"
remote "tar -czf - -C $CONFLUENCE_COMPOSE_DIR ." > "$WORK_DIR/config.tar.gz"

log "Rotating previous backups to $OLD_BACKUP_DIR"
mkdir -p "$OLD_BACKUP_DIR"
find "$CONFLUENCE_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' ! -name '*.partial' \
    -exec mv {} "$OLD_BACKUP_DIR/" \;
mv "$WORK_DIR" "$TARGET_DIR"

log "Removing backups older than $CONFLUENCE_BACKUP_RETENTION_DAYS days"
find "$OLD_BACKUP_DIR" -type f -mtime "+$CONFLUENCE_BACKUP_RETENTION_DAYS" -delete
find "$OLD_BACKUP_DIR" -mindepth 1 -type d -empty -delete

log "Backup completed: $TARGET_DIR ($(du -sh "$TARGET_DIR" | cut -f1))"
