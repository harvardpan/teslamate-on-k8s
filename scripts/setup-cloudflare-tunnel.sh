#!/usr/bin/env bash
set -euo pipefail

# TeslaMate on K8s — Cloudflare Tunnel setup helper
# Prerequisites: cloudflared CLI installed
# Install: brew install cloudflared (macOS) or see https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
#
# Note: `make configure` runs tunnel setup automatically. This script is
# provided for standalone use if you need to manage the tunnel separately.

TUNNEL_NAME="teslamate"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Read hostname from .env if available, otherwise require as argument
if [ -f "$REPO_ROOT/.env" ]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
fi
HOSTNAME="${1:-${TESLAMATE_HOSTNAME:-}}"
if [ -z "$HOSTNAME" ]; then
  echo "Error: No hostname specified."
  echo ""
  echo "Usage: $0 <hostname>"
  echo "  Or set TESLAMATE_HOSTNAME in .env (via 'make configure')"
  exit 1
fi

echo "=== Cloudflare Tunnel Setup ==="
echo ""

# Check for cloudflared
if ! command -v cloudflared &>/dev/null; then
  echo "Error: cloudflared is not installed."
  echo "Install with: brew install cloudflared"
  exit 1
fi

# --- Step 1: Authenticate ---
echo "Step 1: Authenticate with Cloudflare"
if [ -f "$HOME/.cloudflared/cert.pem" ]; then
  echo "  Already authenticated (found ~/.cloudflared/cert.pem). Skipping."
else
  echo "  Opening browser to authorize cloudflared..."
  cloudflared tunnel login
fi
echo ""

# --- Step 2: Create tunnel ---
echo "Step 2: Create tunnel '${TUNNEL_NAME}'"
if cloudflared tunnel list 2>/dev/null | grep -q "$TUNNEL_NAME"; then
  echo "  Tunnel '${TUNNEL_NAME}' already exists. Skipping creation."
else
  cloudflared tunnel create "$TUNNEL_NAME"
  echo "  Tunnel '${TUNNEL_NAME}' created."
fi
echo ""

# --- Step 3: Route DNS ---
echo "Step 3: Route DNS (${HOSTNAME} → tunnel)"
if cloudflared tunnel route dns "$TUNNEL_NAME" "$HOSTNAME" 2>&1 | grep -q "already exists"; then
  echo "  DNS route for ${HOSTNAME} already exists. Skipping."
else
  echo "  DNS route created: ${HOSTNAME} → ${TUNNEL_NAME}"
fi
echo ""

# --- Step 4: Display tunnel token ---
echo "Step 4: Tunnel credentials"
echo ""
TUNNEL_ID=$(cloudflared tunnel list -o json 2>/dev/null | python3 -c "import sys,json; tunnels=json.load(sys.stdin); print(next((t['id'] for t in tunnels if t['name']=='$TUNNEL_NAME'), ''))" 2>/dev/null || true)
if [ -n "$TUNNEL_ID" ] && [ -f "$HOME/.cloudflared/${TUNNEL_ID}.json" ]; then
  echo "Credentials file: $HOME/.cloudflared/${TUNNEL_ID}.json"
else
  echo "Tunnel token (provide this to 'make configure'):"
  echo ""
  cloudflared tunnel token "$TUNNEL_NAME"
fi
echo ""
echo "=== Tunnel setup complete ==="
