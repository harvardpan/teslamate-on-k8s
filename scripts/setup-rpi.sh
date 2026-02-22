#!/usr/bin/env bash
set -euo pipefail

# TeslaMate on K8s — Raspberry Pi 5 setup script (CanaKit edition)
#
# Run this on a CanaKit Raspberry Pi 5 after completing the first-boot wizard.
# The CanaKit comes with Raspberry Pi OS 64-bit pre-installed on the 256GB
# NVMe SSD — no microSD card or flashing needed.
#
# Prerequisites:
#   - CanaKit first-boot wizard completed (user account, locale, network)
#   - SSH enabled via raspi-config
#   - Hostname set to teslamate-pi (or your preferred name)
#   - Connected via SSH from your MacBook
#
# Usage: ./scripts/setup-rpi.sh

SWAP_SIZE="2G"
SWAP_FILE="/swapfile"

echo "=== Raspberry Pi 5 Setup for TeslaMate (CanaKit) ==="
echo ""

# --- Verify we're on a Pi ---
if [ ! -f /proc/device-tree/model ]; then
  echo "Warning: Cannot detect Raspberry Pi model. Continuing anyway..."
else
  MODEL=$(tr -d '\0' < /proc/device-tree/model)
  echo "Detected: ${MODEL}"
fi
echo ""

# --- System update ---
echo "Step 1: Updating system packages..."
sudo apt update && sudo apt upgrade -y
echo ""

# --- Swap setup ---
echo "Step 2: Setting up ${SWAP_SIZE} swap..."

if [ -f "$SWAP_FILE" ]; then
  echo "  Swap file already exists at ${SWAP_FILE}. Skipping."
else
  sudo fallocate -l "$SWAP_SIZE" "$SWAP_FILE"
  sudo chmod 600 "$SWAP_FILE"
  sudo mkswap "$SWAP_FILE"
  sudo swapon "$SWAP_FILE"

  if ! grep -q "$SWAP_FILE" /etc/fstab; then
    echo "${SWAP_FILE} none swap sw 0 0" | sudo tee -a /etc/fstab
    echo "  Added swap to /etc/fstab"
  fi
  echo "  Swap configured: ${SWAP_SIZE}"
fi
echo ""

# --- k3s installation ---
echo "Step 3: Installing k3s..."

if command -v k3s &>/dev/null; then
  echo "  k3s is already installed. Skipping."
  echo "  Version: $(k3s --version)"
else
  # --bind-address 127.0.0.1: prevents LAN exposure of the API server
  # Only accessible via SSH to the Pi (see PLAN.md §12.3)
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--bind-address 127.0.0.1" sh -

  echo "  Waiting for k3s to be ready..."
  sleep 10
  sudo kubectl get nodes
fi
echo ""

# --- kubeconfig for non-root access ---
echo "Step 4: Setting up kubeconfig for non-root access..."
mkdir -p "$HOME/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
export KUBECONFIG="$HOME/.kube/config"

# Add to shell rc if not already there
SHELL_RC="$HOME/.bashrc"
if [ -n "${ZSH_VERSION:-}" ] || [ "$(basename "$SHELL")" = "zsh" ]; then
  SHELL_RC="$HOME/.zshrc"
fi
if ! grep -q 'KUBECONFIG' "$SHELL_RC" 2>/dev/null; then
  echo 'export KUBECONFIG="$HOME/.kube/config"' >> "$SHELL_RC"
fi
echo ""

# --- Verify ---
echo "=== Raspberry Pi setup complete ==="
echo ""
echo "Storage:"
echo "  NVMe SSD is the boot + data drive (no separate SSD needed)"
echo "  k3s PVCs stored at /var/lib/rancher/k3s/storage (on NVMe SSD)"
echo ""
echo "  Disk usage:"
df -h / | tail -1 | awk '{printf "    Total: %s  Used: %s  Free: %s\n", $2, $3, $4}'
echo ""
echo "  Swap:"
free -h | grep Swap | awk '{printf "    Total: %s  Used: %s  Free: %s\n", $2, $3, $4}'
echo ""
echo "  k3s:"
kubectl get nodes
echo ""
echo "Next steps:"
echo "  1. Copy Cloudflare Tunnel credentials from MacBook:"
echo "     scp ~/.cloudflared/<tunnel-id>.json $(whoami)@teslamate-pi.local:~/.cloudflared/"
echo "  2. Clone the repo: git clone https://github.com/<your-username>/teslamate-on-k8s.git"
echo "  3. Run: make configure"
echo "  4. Run: kubectl apply -k k8s/base/"
echo "  5. Tear down MacBook cluster: k3d cluster delete teslamate"
