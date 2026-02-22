#!/usr/bin/env bash
set -euo pipefail

# TeslaMate on K8s — PostgreSQL restore script
# Usage: ./scripts/restore-postgres.sh [--yes] <backup-file>
#
# Restores a gzipped PostgreSQL dump into the running cluster.
# Scales down TeslaMate during restore to prevent writes.
# Use --yes to skip the confirmation prompt.

NAMESPACE="teslamate"
AUTO_CONFIRM=false

if [ "${1:-}" = "--yes" ] || [ "${1:-}" = "-y" ]; then
  AUTO_CONFIRM=true
  shift
fi

BACKUP_FILE="${1:-}"

if [ -z "$BACKUP_FILE" ]; then
  echo "Usage: $0 <backup-file.sql.gz>"
  echo ""
  echo "Available backups:"
  for dir in /var/backups/teslamate; do
    if [ -d "$dir" ]; then
      ls -1t "$dir"/*.sql.gz 2>/dev/null | while read -r f; do
        SIZE=$(ls -lh "$f" | awk '{print $5}')
        echo "  $f  ($SIZE)"
      done
    fi
  done
  exit 1
fi

if [ ! -f "$BACKUP_FILE" ]; then
  echo "Error: File not found: ${BACKUP_FILE}"
  exit 1
fi

FILESIZE=$(ls -lh "$BACKUP_FILE" | awk '{print $5}')

echo "=== PostgreSQL Restore ==="
echo "Backup file: ${BACKUP_FILE} (${FILESIZE})"
echo ""

# Verify postgres is running
echo "Checking PostgreSQL pod..."
if ! kubectl get statefulset/postgres -n "$NAMESPACE" &>/dev/null; then
  echo "Error: No postgres statefulset found in namespace '${NAMESPACE}'."
  exit 1
fi

kubectl exec -n "$NAMESPACE" statefulset/postgres -- pg_isready -U teslamate -q
echo "  PostgreSQL is ready."
echo ""

# Show current row count for comparison
BEFORE_COUNT=$(kubectl exec -n "$NAMESPACE" statefulset/postgres -- \
  psql -U teslamate -d teslamate -t -c "SELECT count(*) FROM positions;" 2>/dev/null | tr -d '[:space:]' || echo "unknown")
echo "Current position records: ${BEFORE_COUNT}"
echo ""

echo "=========================================="
echo "  WARNING: This will REPLACE all data in"
echo "  the PostgreSQL database."
echo "=========================================="
echo ""
if [ "$AUTO_CONFIRM" = true ]; then
  echo "Auto-confirmed (--yes flag)."
else
  read -p "Continue with restore? [y/N] " CONFIRM
  if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "Aborted."
    exit 0
  fi
fi
echo ""

# Scale down TeslaMate to prevent writes during restore
echo "Step 1: Scaling down TeslaMate..."
kubectl scale -n "$NAMESPACE" deploy/teslamate --replicas=0
echo "  TeslaMate scaled to 0 replicas."
echo "  Waiting for pod to terminate..."
kubectl wait -n "$NAMESPACE" --for=delete pod -l app=teslamate --timeout=60s 2>/dev/null || true
echo ""

# Drop and recreate the database for a clean restore
echo "Step 2: Dropping and recreating database..."
kubectl exec -n "$NAMESPACE" statefulset/postgres -- \
  psql -U teslamate -d postgres -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'teslamate' AND pid <> pg_backend_pid();" \
  --quiet 2>/dev/null || true
kubectl exec -n "$NAMESPACE" statefulset/postgres -- \
  psql -U teslamate -d postgres -c "DROP DATABASE IF EXISTS teslamate;"
kubectl exec -n "$NAMESPACE" statefulset/postgres -- \
  psql -U teslamate -d postgres -c "CREATE DATABASE teslamate OWNER teslamate;"
echo "  Database recreated."
echo ""

# Restore
echo "Step 3: Restoring database from backup..."
echo "  This may take a few minutes..."
gunzip -c "$BACKUP_FILE" | kubectl exec -i -n "$NAMESPACE" statefulset/postgres -- \
  psql -U teslamate -d teslamate --quiet --output=/dev/null
echo "  Restore complete."
echo ""

# Scale TeslaMate back up
echo "Step 4: Scaling TeslaMate back up..."
kubectl scale -n "$NAMESPACE" deploy/teslamate --replicas=1
echo "  TeslaMate scaled back to 1 replica."
echo ""

# Verify
echo "Step 5: Verifying restore..."
AFTER_COUNT=$(kubectl exec -n "$NAMESPACE" statefulset/postgres -- \
  psql -U teslamate -d teslamate -t -c "SELECT count(*) FROM positions;" 2>/dev/null | tr -d '[:space:]' || echo "unknown")
echo "  Position records before: ${BEFORE_COUNT}"
echo "  Position records after:  ${AFTER_COUNT}"
echo ""

# Wait for TeslaMate to come up
echo "Waiting for TeslaMate pod to be ready..."
kubectl wait -n "$NAMESPACE" --for=condition=Ready pod -l app=teslamate --timeout=120s
echo "  TeslaMate is running."
echo ""

echo "=== Restore Complete ==="
