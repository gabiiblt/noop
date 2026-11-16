#!/usr/bin/env bash
# Consistent online backup of the receiver database (safe while the receiver is writing: uses
# SQLite's backup API, never a raw file copy of a WAL database). Keeps 14 days.
set -euo pipefail
DB="${NOOP_DB:-/var/lib/noop-selfhost/selfhost.sqlite}"
DEST="${NOOP_BACKUP_DIR:-/var/backups/noop-selfhost}"
umask 077
mkdir -p "$DEST"
sqlite3 "$DB" ".backup '$DEST/selfhost-$(date +%F).sqlite'"
find "$DEST" -name 'selfhost-*.sqlite' -mtime +14 -delete
