#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: Configuration file not found: $ENV_FILE" >&2
    echo "Create it from the .env template before running this script." >&2
    exit 1
fi

source "$ENV_FILE"

: "${POSTGRES_BACKUP_DIR:?POSTGRES_BACKUP_DIR is required in $ENV_FILE}"
: "${POSTGRES_DATABASES:?POSTGRES_DATABASES is required in $ENV_FILE}"
: "${POSTGRES_SSH_TARGET:?POSTGRES_SSH_TARGET is required in $ENV_FILE}"
: "${POSTGRES_SSH_KEY_PATH:?POSTGRES_SSH_KEY_PATH is required in $ENV_FILE}"
: "${POSTGRES_SSH_KNOWN_HOSTS:?POSTGRES_SSH_KNOWN_HOSTS is required in $ENV_FILE}"

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

# PostgreSQL dump settings
POSTGRES_OS_USER="${POSTGRES_OS_USER:-postgres}"
POSTGRES_DB_USER="${POSTGRES_DB_USER:-postgres}"
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
execute() {
    local cmd="$1"
    if [ $DRY_RUN -eq 1 ]; then
        echo "[DRY RUN] Would execute: $cmd"
    else
        eval "$cmd"
    fi
}

# Preparation
echo "Ensuring backup directories exist..."
execute "sudo mkdir -p \"$OLD_BACKUP_DIR\""

echo "Moving old backups to the archive directory..."
execute "sudo find \"$BACKUP_DIR\" -maxdepth 1 -type f -name \"*.dump\" -exec mv {} \"$OLD_BACKUP_DIR/\" \;"

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
    
    # The remote pg_dump command
    PG_DUMP_CMD="sudo -u $POSTGRES_OS_USER pg_dump -U $POSTGRES_DB_USER -F $POSTGRES_DUMP_FORMAT -Z $POSTGRES_DUMP_COMPRESSION $DB"

    if [ $DRY_RUN -eq 1 ]; then
        # Use [*] to print the array elements as a single string for the log
        echo "[DRY RUN] Would test SSH: ssh ${SSH_ARGS[*]} true"
        echo "[DRY RUN] Would run: ssh ${SSH_ARGS[*]} \"$PG_DUMP_CMD\" > \"$DEST_FILE\""
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
execute "sudo find \"$OLD_BACKUP_DIR\" -type f -mtime +\"$POSTGRES_BACKUP_RETENTION_DAYS\" -name \"*.dump\" -delete"

echo "=== Backup process completed successfully. ==="

