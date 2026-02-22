#!/usr/bin/env bash
set -euo pipefail

# TeslaMate on K8s — PostgreSQL backup script
# Usage: ./scripts/backup-postgres.sh [backup-directory]
#
# Creates a gzipped PostgreSQL dump and manages backup rotation.
# Keeps 7 daily + 4 weekly backups.

NAMESPACE="teslamate"
BACKUP_DIR="${1:-/var/backups/teslamate}"
DATE=$(date +%Y%m%d)
DAY_OF_WEEK=$(date +%u)
BACKUP_FILE="${BACKUP_DIR}/teslamate-backup-${DATE}.sql.gz"

if [ ! -d "$BACKUP_DIR" ]; then
  sudo mkdir -p "$BACKUP_DIR"
  sudo chown "$(id -u):$(id -g)" "$BACKUP_DIR"
fi

echo "=== PostgreSQL Backup ==="
echo "Date: ${DATE}"
echo "Destination: ${BACKUP_FILE}"
echo ""

# Run pg_dump
echo "Creating backup..."
kubectl exec -n "$NAMESPACE" statefulset/postgres -- \
  pg_dump -U teslamate teslamate | gzip > "$BACKUP_FILE"

FILESIZE=$(ls -lh "$BACKUP_FILE" | awk '{print $5}')
echo "Backup complete: ${BACKUP_FILE} (${FILESIZE})"

# Weekly backup (keep on Sundays)
if [ "$DAY_OF_WEEK" -eq 7 ]; then
  WEEKLY_FILE="${BACKUP_DIR}/teslamate-weekly-${DATE}.sql.gz"
  cp "$BACKUP_FILE" "$WEEKLY_FILE"
  echo "Weekly backup: ${WEEKLY_FILE}"
fi

# Rotate daily backups (keep last 7)
echo ""
echo "Rotating daily backups (keeping last 7)..."
ls -1t "${BACKUP_DIR}"/teslamate-backup-*.sql.gz 2>/dev/null | tail -n +8 | while read -r old; do
  echo "  Removing: $(basename "$old")"
  rm -f "$old"
done

# Rotate weekly backups (keep last 4)
echo "Rotating weekly backups (keeping last 4)..."
ls -1t "${BACKUP_DIR}"/teslamate-weekly-*.sql.gz 2>/dev/null | tail -n +5 | while read -r old; do
  echo "  Removing: $(basename "$old")"
  rm -f "$old"
done

echo ""
echo "=== Backup complete ==="
