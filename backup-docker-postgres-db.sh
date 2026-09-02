#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: Configuration file not found: $ENV_FILE" >&2
    echo "Create it with the required backup settings before running this script." >&2
    exit 1
fi

source "$ENV_FILE"

: "${POSTGRES_BACKUP_DIR:?POSTGRES_BACKUP_DIR is required in $ENV_FILE}"
: "${POSTGRES_DATABASES:?POSTGRES_DATABASES is required in $ENV_FILE}"
: "${POSTGRES_SSH_TARGET:?POSTGRES_SSH_TARGET is required in $ENV_FILE}"
: "${POSTGRES_SSH_KEY_PATH:?POSTGRES_SSH_KEY_PATH is required in $ENV_FILE}"
: "${POSTGRES_SSH_KNOWN_HOSTS:?POSTGRES_SSH_KNOWN_HOSTS is required in $ENV_FILE}"
: "${POSTGRES_COMPOSE_DIR:?POSTGRES_COMPOSE_DIR is required in $ENV_FILE}"

BACKUP_DIR="$POSTGRES_BACKUP_DIR"
OLD_BACKUP_DIR="${POSTGRES_OLD_BACKUP_DIR:-$BACKUP_DIR/old-backups}"
read -r -a DB_LIST <<< "$POSTGRES_DATABASES"
DATE=$(date +"%Y-%m-%d-%Hh")

# SSH Connection Details
SSH_KEY_PATH="$POSTGRES_SSH_KEY_PATH"
SSH_HOST_KNOWN="$POSTGRES_SSH_KNOWN_HOSTS"
SSH_BASE_ARGS=(
    -F /dev/null
    -i "$SSH_KEY_PATH"
    -o "UserKnownHostsFile=$SSH_HOST_KNOWN"
    -o "BatchMode=yes"
    -o "ConnectTimeout=10"
)

# PostgreSQL dump settings. pg_dump runs inside the Compose database container,
# so the database does not need to publish port 5432 on the host.
POSTGRES_COMPOSE_FILE="${POSTGRES_COMPOSE_FILE:-compose.yml}"
POSTGRES_COMPOSE_SERVICE="${POSTGRES_COMPOSE_SERVICE:-db}"
POSTGRES_DB_USER="${POSTGRES_DB_USER:-waggy}"
POSTGRES_DUMP_FORMAT="${POSTGRES_DUMP_FORMAT:-c}"
POSTGRES_DUMP_COMPRESSION="${POSTGRES_DUMP_COMPRESSION:-4}"
POSTGRES_BACKUP_RETENTION_DAYS="${POSTGRES_BACKUP_RETENTION_DAYS:-7}"

# Argument Parsing
DRY_RUN=0
if [[ "$1" == "--dry-run" || "$1" == "-d" ]]; then
    DRY_RUN=1
    echo "=== DRY RUN MODE ENABLED. No files will be modified. ==="
fi

# Helper Functions
print_command() {
    printf '[DRY RUN] Would execute:'
    printf ' %q' "$@"
    printf '\n'
}

# Preparation
echo "Ensuring backup directories exist..."
if [ "$DRY_RUN" -eq 1 ]; then
    print_command sudo mkdir -p "$BACKUP_DIR" "$OLD_BACKUP_DIR"
else
    sudo mkdir -p "$BACKUP_DIR" "$OLD_BACKUP_DIR"
fi

echo "Moving old backups to the archive directory..."
if [ "$DRY_RUN" -eq 1 ]; then
    print_command sudo find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.dump' -exec mv '{}' "$OLD_BACKUP_DIR/" ';'
else
    sudo find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.dump' -exec mv '{}' "$OLD_BACKUP_DIR/" ';'
fi

# Backup Execution
for DB in "${DB_LIST[@]}"; do
    echo "----------------------------------------"
    echo "Starting backup for database: $DB"
    
    DEST_FILE="$BACKUP_DIR/$DB-$DATE.dump"

    # Use an array for SSH arguments to prevent quote-escaping bugs
    SSH_ARGS=(
        "${SSH_BASE_ARGS[@]}"
        "$POSTGRES_SSH_TARGET"
    )
    
    # Compose resolves the project's .env from this directory. `exec -T` makes
    # pg_dump write its custom-format archive to stdout instead of allocating a
    # TTY, allowing SSH to stream it straight into the local backup file.
    printf -v PG_DUMP_CMD \
        'cd -- %q && docker compose -f %q exec -T %q pg_dump -U %q -F %q -Z %q -- %q' \
        "$POSTGRES_COMPOSE_DIR" \
        "$POSTGRES_COMPOSE_FILE" \
        "$POSTGRES_COMPOSE_SERVICE" \
        "$POSTGRES_DB_USER" \
        "$POSTGRES_DUMP_FORMAT" \
        "$POSTGRES_DUMP_COMPRESSION" \
        "$DB"

    if [ $DRY_RUN -eq 1 ]; then
        # Use [*] to print the array elements as a single string for the log
        echo "[DRY RUN] Would test SSH: ssh ${SSH_ARGS[*]} true"
        print_command ssh "${SSH_ARGS[@]}" "$PG_DUMP_CMD"
        echo "[DRY RUN] Would stream the dump to: $DEST_FILE"
    else
        if ! ssh "${SSH_ARGS[@]}" true; then
            echo "ERROR: Cannot reach $POSTGRES_SSH_TARGET."
            echo "Check that SSH to $POSTGRES_SSH_TARGET:22 works with $SSH_KEY_PATH."
            exit 1
        fi

        set +e
        set -o pipefail
        
        # Execute using "${SSH_ARGS[@]}" which perfectly preserves arguments
        if command -v pv >/dev/null 2>&1; then
             ssh "${SSH_ARGS[@]}" "$PG_DUMP_CMD" | pv > "$DEST_FILE"
        else
             echo "(Warning: 'pv' is not installed. Progress will not be shown. Install 'pv' for a progress bar.)"
             ssh "${SSH_ARGS[@]}" "$PG_DUMP_CMD" > "$DEST_FILE"
        fi
        
        EXIT_CODE=$?
        set -e 
        set +o pipefail

        if [ $EXIT_CODE -ne 0 ]; then
            echo "ERROR: Backup pipeline failed for $DB (Exit code: $EXIT_CODE)"
            [ -f "$DEST_FILE" ] && rm -f "$DEST_FILE"
            exit 1
        fi

        if [ ! -s "$DEST_FILE" ]; then
            echo "ERROR: Backup file for $DB is empty!"
            rm -f "$DEST_FILE"
            exit 1
        fi
        
        echo "Success: $DB backed up to $DEST_FILE"
    fi
done

# Cleanup
echo "----------------------------------------"
echo "Cleaning up backups older than $POSTGRES_BACKUP_RETENTION_DAYS days..."
if [ "$DRY_RUN" -eq 1 ]; then
    print_command sudo find "$OLD_BACKUP_DIR" -type f -mtime "+$POSTGRES_BACKUP_RETENTION_DAYS" -name '*.dump' -delete
else
    sudo find "$OLD_BACKUP_DIR" -type f -mtime "+$POSTGRES_BACKUP_RETENTION_DAYS" -name '*.dump' -delete
fi

echo "=== Backup process completed successfully. ==="

