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
# Usage: make setup-rpi

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

# --- Enable cgroups (required for k3s on Raspberry Pi) ---
echo "Step 3: Enabling cgroup memory..."

CMDLINE="/boot/firmware/cmdline.txt"
if [ -f "$CMDLINE" ]; then
  if grep -q 'cgroup_memory=1' "$CMDLINE" && grep -q 'cgroup_enable=memory' "$CMDLINE"; then
    echo "  cgroup memory already enabled. Skipping."
  else
    echo "  Adding cgroup_memory=1 cgroup_enable=memory to ${CMDLINE}"
    sudo sed -i '1 s/$/ cgroup_memory=1 cgroup_enable=memory/' "$CMDLINE"
    echo "  Rebooting to apply cgroup changes..."
    echo "  After reboot, re-run: make setup-rpi"
    sudo reboot
  fi
else
  echo "  Warning: ${CMDLINE} not found. You may need to manually enable cgroup memory."
fi
echo ""

# --- k3s installation ---
echo "Step 4: Installing k3s..."

if command -v k3s &>/dev/null; then
  echo "  k3s is already installed. Skipping."
  echo "  Version: $(k3s --version)"
else
  curl -sfL https://get.k3s.io | sh -

  echo "  Waiting for k3s to be ready..."
  sleep 10
  sudo kubectl get nodes
fi
echo ""

# --- Firewall: block k3s API from LAN ---
echo "Step 5: Securing k3s API server..."

# Block external access to port 6443 (k3s API). Only localhost and pod network
# traffic is allowed. SSH tunnel is the intended access method from the MacBook.
if ! sudo iptables -C INPUT -p tcp --dport 6443 -s 127.0.0.0/8 -j ACCEPT 2>/dev/null; then
  sudo iptables -I INPUT -p tcp --dport 6443 -s 127.0.0.0/8 -j ACCEPT
  sudo iptables -I INPUT -p tcp --dport 6443 -s 10.42.0.0/16 -j ACCEPT
  sudo iptables -I INPUT -p tcp --dport 6443 -s 10.43.0.0/16 -j ACCEPT
  sudo iptables -A INPUT -p tcp --dport 6443 -j DROP

  # Persist across reboots
  sudo apt-get install -y iptables-persistent
  sudo netfilter-persistent save
  echo "  Firewall rules added: port 6443 blocked from LAN."
else
  echo "  Firewall rules already configured. Skipping."
fi
echo ""

# --- kubeconfig for non-root access ---
echo "Step 6: Setting up kubeconfig for non-root access..."
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
echo "  2. Run: make configure"
echo "  3. Run: kubectl apply -k k8s/base/"
