#!/usr/bin/env bash
set -euo pipefail

# TeslaMate on K8s — PostgreSQL Migration Script
#
# Migrates PostgreSQL data from the MacBook k3d cluster to the Raspberry Pi k3s cluster.
#
# This script runs on the MacBook and performs:
#   1. pg_dump from the local k3d cluster
#   2. scp the dump to the Raspberry Pi
#   3. Restore into the RPi's PostgreSQL pod via ssh + kubectl
#
# Prerequisites:
#   - MacBook k3d cluster running with TeslaMate data
#   - RPi k3s cluster running with PostgreSQL deployed (empty or fresh)
#   - SSH access to the RPi: ssh <user>@teslamate-pi.local
#
# Usage: make migrate-postgres RPI_HOST=user@teslamate-pi.local
#    or: ./scripts/migrate-postgres.sh [user@host]

NAMESPACE="teslamate"
DUMP_FILE="/tmp/teslamate-migration-$(date +%Y%m%d-%H%M%S).sql.gz"
RPI_HOST="${1:-}"

echo "=== TeslaMate PostgreSQL Migration ==="
echo ""

# --- Validate RPI_HOST ---
if [ -z "$RPI_HOST" ]; then
  read -p "Enter RPi SSH target (e.g., user@teslamate-pi.local): " RPI_HOST
fi

if [ -z "$RPI_HOST" ]; then
  echo "Error: RPi host is required."
  echo "Usage: $0 user@teslamate-pi.local"
  exit 1
fi

# k3s kubeconfig path on RPi (non-interactive SSH doesn't source .bashrc)
RPI_KUBECONFIG="\$HOME/.kube/config"
RPI_KUBECTL="KUBECONFIG=${RPI_KUBECONFIG} kubectl"

# Use SSH connection multiplexing to avoid repeated password prompts
SSH_CONTROL_PATH="/tmp/migrate-postgres-ssh-%r@%h:%p"
SSH_OPTS="-o ControlMaster=auto -o ControlPath=${SSH_CONTROL_PATH} -o ControlPersist=300"

# Override ssh/scp to use multiplexing
ssh() { command ssh $SSH_OPTS "$@"; }
scp() { command scp $SSH_OPTS "$@"; }

echo "Source:      MacBook k3d cluster (context: $(kubectl config current-context))"
echo "Destination: ${RPI_HOST}"
echo "Dump file:   ${DUMP_FILE}"
echo ""

# --- Verify MacBook cluster ---
echo "Step 1: Verifying source PostgreSQL pod..."
if ! kubectl get statefulset/postgres -n "$NAMESPACE" &>/dev/null; then
  # Try deployment (older setups may use deployment instead of statefulset)
  if ! kubectl get deploy/postgres -n "$NAMESPACE" &>/dev/null; then
    echo "Error: No postgres statefulset or deployment found in namespace '${NAMESPACE}'."
    echo "  Make sure you're using the correct kubectl context."
    echo "  Current context: $(kubectl config current-context)"
    exit 1
  fi
  PG_SOURCE="deploy/postgres"
else
  PG_SOURCE="statefulset/postgres"
fi
echo "  Found: ${PG_SOURCE}"

# Quick connectivity check
kubectl exec -n "$NAMESPACE" "$PG_SOURCE" -- pg_isready -U teslamate -q
echo "  PostgreSQL is ready."
echo ""

# --- Verify RPi connectivity ---
echo "Step 2: Verifying RPi connectivity..."
if ! ssh -o ConnectTimeout=5 "$RPI_HOST" "echo ok" &>/dev/null; then
  echo "Error: Cannot SSH to ${RPI_HOST}"
  echo "  Make sure SSH is configured and the RPi is reachable."
  exit 1
fi
echo "  SSH to ${RPI_HOST}: OK"

# Verify RPi has postgres running
if ! ssh "$RPI_HOST" "${RPI_KUBECTL} get statefulset/postgres -n ${NAMESPACE}" &>/dev/null; then
  echo "Error: No postgres statefulset found on RPi."
  echo "  Deploy first: kubectl apply -k k8s/base/"
  exit 1
fi
echo "  RPi PostgreSQL pod: OK"
echo ""

# --- Dump from MacBook ---
echo "Step 3: Dumping PostgreSQL from MacBook cluster..."
echo "  This may take a few minutes depending on data size..."
kubectl exec -n "$NAMESPACE" "$PG_SOURCE" -- \
  pg_dump -U teslamate --clean --if-exists --no-owner teslamate | gzip > "$DUMP_FILE"

FILESIZE=$(ls -lh "$DUMP_FILE" | awk '{print $5}')
echo "  Dump complete: ${DUMP_FILE} (${FILESIZE})"
echo ""

# --- Transfer to RPi ---
echo "Step 4: Transferring dump to RPi..."
scp "$DUMP_FILE" "${RPI_HOST}:/tmp/"
REMOTE_DUMP="/tmp/$(basename "$DUMP_FILE")"
echo "  Transfer complete: ${REMOTE_DUMP}"
echo ""

# --- Confirm before restore ---
echo "=========================================="
echo "  Ready to restore into RPi PostgreSQL."
echo "  This will REPLACE all data in the RPi database."
echo "=========================================="
echo ""
read -p "Continue with restore? [y/N] " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
  echo "Aborted. Dump file preserved at: ${DUMP_FILE}"
  echo "Remote copy at: ${RPI_HOST}:${REMOTE_DUMP}"
  echo ""
  echo "To restore manually later:"
  echo "  ssh ${RPI_HOST}"
  echo "  KUBECONFIG=~/.kube/config gunzip -c ${REMOTE_DUMP} | kubectl exec -i -n ${NAMESPACE} statefulset/postgres -- psql -U teslamate teslamate"
  exit 0
fi
echo ""

# --- Scale down TeslaMate on RPi (avoid writes during restore) ---
echo "Step 5: Scaling down TeslaMate on RPi (prevent writes during restore)..."
ssh "$RPI_HOST" "${RPI_KUBECTL} scale -n ${NAMESPACE} deploy/teslamate --replicas=0"
echo "  TeslaMate scaled to 0 replicas."
echo ""

# --- Restore on RPi ---
echo "Step 6: Restoring PostgreSQL on RPi..."
echo "  This may take a few minutes..."
ssh "$RPI_HOST" "gunzip -c ${REMOTE_DUMP} | ${RPI_KUBECTL} exec -i -n ${NAMESPACE} statefulset/postgres -- psql -U teslamate -d teslamate"
echo "  Restore complete."
echo ""

# --- Scale TeslaMate back up ---
echo "Step 7: Scaling TeslaMate back up..."
ssh "$RPI_HOST" "${RPI_KUBECTL} scale -n ${NAMESPACE} deploy/teslamate --replicas=1"
echo "  TeslaMate scaled back to 1 replica."
echo ""

# --- Verify ---
echo "Step 8: Verifying restore..."
ROW_COUNT=$(ssh "$RPI_HOST" "${RPI_KUBECTL} exec -n ${NAMESPACE} statefulset/postgres -- psql -U teslamate -d teslamate -t -c 'SELECT count(*) FROM positions;'" 2>/dev/null | tr -d '[:space:]')
echo "  Position records on RPi: ${ROW_COUNT:-unknown}"
echo ""

# --- Cleanup ---
echo "Cleaning up temporary files..."
rm -f "$DUMP_FILE"
ssh "$RPI_HOST" "rm -f ${REMOTE_DUMP}"
# Close SSH control connection
command ssh -O exit -o ControlPath="${SSH_CONTROL_PATH}" "$RPI_HOST" 2>/dev/null || true
echo "  Done."
echo ""

echo "=== Migration Complete ==="
echo ""
echo "Next steps:"
echo "  1. Update Cloudflare Tunnel to point to RPi instead of MacBook"
echo "  2. Verify teslamate.panfamily.org works"
echo "  3. Tear down MacBook cluster: k3d cluster delete teslamate"
