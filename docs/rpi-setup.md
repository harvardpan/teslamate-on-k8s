# Raspberry Pi 5 Setup (CanaKit)

Hardware setup and initial configuration for running TeslaMate on a CanaKit
Raspberry Pi 5 Desktop PC.

## Hardware

The CanaKit Raspberry Pi 5 Desktop PC comes fully assembled — no hardware
setup required.

| Included in Kit | Details |
|-----------------|---------|
| Raspberry Pi 5 (8GB) | Quad-core ARM Cortex-A76, 8GB LPDDR4X |
| 256GB NVMe SSD | Pre-loaded with Raspberry Pi OS 64-bit, via M.2 HAT+ |
| Active cooler | Fan + heatsink (pre-installed in case) |
| CanaKit Turbine case | High-gloss black |
| 45W USB-C PD power supply | Included |
| 2x HDMI display cables | Micro-HDMI to HDMI |

**Not included (you provide):** USB keyboard, USB mouse, HDMI monitor (for
initial setup only — not needed after SSH is enabled), Ethernet cable
(recommended over Wi-Fi).

## Initial Boot (No Flashing Needed)

The OS is pre-installed on the NVMe SSD. No microSD card or Raspberry Pi
Imager is needed.

1. Connect a USB keyboard, USB mouse, and HDMI monitor
2. Connect Ethernet cable (recommended) or use Wi-Fi during setup
3. Plug in the USB-C power supply — the Pi boots automatically
4. Complete the **first-boot wizard**:
   - Set locale and timezone
   - Create a user account (username + password)
   - Connect to Wi-Fi (if not using Ethernet)
   - Allow the system to update (optional — the setup script does this too)

## Configure for Headless (SSH) Access

After the first-boot wizard completes:

```bash
# Enable SSH
sudo raspi-config
# → Interface Options → SSH → Enable

# Set hostname
sudo raspi-config
# → System Options → Hostname → teslamate-pi

# Switch to CLI-only (no desktop GUI — saves ~200MB RAM)
sudo raspi-config
# → System Options → Boot / Auto Login → Console
```

Reboot, then SSH in from your MacBook:

```bash
ssh <your-username>@teslamate-pi.local
```

## Automated Setup

Once connected via SSH:

```bash
git clone https://github.com/harvardpan/teslamate-on-k8s.git
cd teslamate-on-k8s
make setup-rpi
```

The script will:
- Update system packages
- Configure 2GB swap on the NVMe SSD
- Enable cgroup memory (required for k3s; reboots if needed — re-run after reboot)
- Install k3s with `--bind-address 127.0.0.1` (API server only on localhost)
- Set up kubeconfig for non-root kubectl access

### Install cloudflared

`cloudflared` is required by `make configure` to set up the Cloudflare Tunnel.
Install it before proceeding:

```bash
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb -o /tmp/cloudflared.deb
sudo dpkg -i /tmp/cloudflared.deb
```

The script does **not** format or mount any drives — the 256GB NVMe SSD is
already the boot drive and data drive. k3s PVCs are stored at
`/var/lib/rancher/k3s/storage` on the NVMe SSD by default.

## Cloudflare Tunnel Migration

The Cloudflare Tunnel was created on your MacBook when you ran `make configure`,
which used `cloudflared` to set up the tunnel. The tunnel is identified by its
UUID and credentials file — not by which machine runs it. To migrate it to the
RPi:

### Step 1: Copy credentials to the RPi

Find your tunnel credentials file on the MacBook:

```bash
# On MacBook — find the credentials file
ls ~/.cloudflared/*.json
# Example: ~/.cloudflared/a1b2c3d4-e5f6-7890-abcd-ef1234567890.json
```

Copy it to the RPi:

```bash
# On MacBook
ssh <user>@teslamate-pi.local "mkdir -p ~/.cloudflared"
scp ~/.cloudflared/<tunnel-id>.json <user>@teslamate-pi.local:~/.cloudflared/

# Optional (not recommended): copy cert.pem for future tunnel management
# (not needed for day-to-day operation, but required if you ever need to
# run cloudflared tunnel commands like create/delete/route on the RPi)
scp ~/.cloudflared/cert.pem <user>@teslamate-pi.local:~/.cloudflared/
```

### Step 2: Configure and deploy

```bash
# On RPi
cd teslamate-on-k8s

# This creates all K8s secrets, including cloudflared credentials
make configure

# Deploy the full stack
kubectl apply -k k8s/base/

# Verify pods are running
kubectl get pods -n teslamate
```

### Step 3: Tear down MacBook

Once everything works on the RPi, stop the MacBook deployment:

```bash
# On MacBook
make cluster-delete
```

The DNS CNAME (`<your-hostname> → <tunnel-uuid>.cfargotunnel.com`)
does **not** change — the RPi's cloudflared pod connects using the same
tunnel credentials and takes over.

## Storage Notes

- The 256GB NVMe SSD is both the boot drive and data drive
- NVMe over PCIe (via M.2 HAT+) is significantly faster than USB SSD or microSD
- PostgreSQL data, k3s storage, swap, and backups all live on the NVMe SSD
- No need to format, partition, or mount any additional drives

## Remote Access with Lens (Kubernetes IDE)

You can manage the RPi cluster from your MacBook using
[Lens](https://k8slens.dev/). Since the k3s API server is bound to
`127.0.0.1` (not reachable from the LAN), you connect through an SSH tunnel.

There are two options depending on where you are:

| Location | Method |
|----------|--------|
| Home LAN | SSH tunnel directly to `teslamate-pi.local` (simple) |
| Away from home | SSH through Cloudflare Tunnel (requires one-time Access setup) |

Both methods use the same kubeconfig and kubectl/Lens workflow — only the
SSH connection method differs.

### Step 1: Copy the kubeconfig from the RPi

```bash
# On MacBook
ssh teslamate-pi.local "sudo cat /etc/rancher/k3s/k3s.yaml" \
  > ~/.kube/k3s-teslamate-pi.yaml
chmod 600 ~/.kube/k3s-teslamate-pi.yaml
```

### Step 2: Rename the context to avoid conflicts

The default k3s.yaml uses `default` for everything, which will collide with
other clusters. Edit `~/.kube/k3s-teslamate-pi.yaml` and rename:

```yaml
clusters:
- cluster:
    server: https://127.0.0.1:6443      # ← keep as-is (tunnel target)
    certificate-authority-data: <...>
  name: teslamate-pi                     # ← rename from "default"
contexts:
- context:
    cluster: teslamate-pi                # ← rename
    user: teslamate-pi-admin             # ← rename
  name: teslamate-pi                     # ← rename
current-context: teslamate-pi            # ← rename
users:
- name: teslamate-pi-admin              # ← rename
  user:
    client-certificate-data: <...>
    client-key-data: <...>
```

> The `server: https://127.0.0.1:6443` stays as-is — the SSH tunnel will
> forward your local port 6443 to the RPi's localhost:6443, so the TLS
> certificate SAN matches and everything works cleanly.

### Step 3: Start the SSH tunnel

```bash
ssh -f -N -L 6443:127.0.0.1:6443 teslamate-pi.local
```

- `-f` — run in background
- `-N` — no remote command (tunnel only)
- `-L 6443:127.0.0.1:6443` — forward local 6443 → RPi localhost 6443

### Step 4: Verify with kubectl

```bash
kubectl --kubeconfig ~/.kube/k3s-teslamate-pi.yaml get nodes
```

### Step 5: Add to Lens

1. Open Lens
2. **File → Add Cluster** (or click **+** in the catalog)
3. Browse to `~/.kube/k3s-teslamate-pi.yaml` or paste its contents
4. Connect to the `teslamate-pi` context

### Keeping the tunnel alive

Add this to `~/.ssh/config` so the tunnel auto-reconnects:

```
Host teslamate-pi-tunnel
    HostName teslamate-pi.local
    User <your-username>
    LocalForward 6443 127.0.0.1:6443
    ServerAliveInterval 60
    ServerAliveCountMax 3
```

Then start with: `ssh -f -N teslamate-pi-tunnel`

> **Note:** The tunnel must be running before Lens (or kubectl) can connect.
> If it drops, Lens will show the cluster as disconnected until you restart it.

### Remote access from outside the home (SSH over Cloudflare Tunnel)

When you're away from home, `teslamate-pi.local` doesn't resolve (mDNS is
LAN-only). You can expose SSH through your existing Cloudflare Tunnel so you
can connect from anywhere, protected by the same Google OAuth you use for
TeslaMate.

**This uses the free Cloudflare Zero Trust plan (up to 50 users).**

#### Prerequisites

- Give your RPi a **static IP** (set a DHCP reservation in your router).
  `make configure` already asked for this IP and configured the cloudflared
  SSH ingress route and DNS record automatically.
- Install `cloudflared` on your MacBook: `brew install cloudflared`

#### 1. Create a Cloudflare Access application

1. Go to the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com/)
   (sign up if you haven't — the free plan covers this)
2. **Access → Applications → Add an Application**
3. Choose **Self-hosted**
4. Configure:
   - **Application name:** `RPi SSH`
   - **Subdomain:** `ssh` | **Domain:** `<your-domain>`
5. Add a policy:
   - **Policy name:** `Google OAuth`
   - **Action:** Allow
   - **Include rule:** Emails — `<your-email>`
6. Save

This ensures only your Google account can access the SSH endpoint.

#### 2. Configure SSH on your MacBook

Add this to `~/.ssh/config`:

```
Host teslamate-pi-remote
    HostName ssh.<your-domain>
    User <your-rpi-username>
    ProxyCommand cloudflared access ssh --hostname %h
    LocalForward 6443 127.0.0.1:6443
    ServerAliveInterval 60
    ServerAliveCountMax 3
```

#### 3. Connect from anywhere

```bash
# Opens browser for Google OAuth, then connects via Cloudflare Tunnel
ssh -f -N teslamate-pi-remote
```

After authenticating, this creates:
1. An SSH connection through Cloudflare Tunnel to the RPi
2. A port forward from local 6443 → RPi localhost 6443

Then kubectl and Lens work exactly as they do on the home LAN:

```bash
kubectl --kubeconfig ~/.kube/k3s-teslamate-pi.yaml get nodes
```

> **How it works:** MacBook → `cloudflared access ssh` (local proxy) →
> Cloudflare edge (Access auth) → Cloudflare Tunnel → cloudflared pod (RPi)
> → RPi SSH (port 22) → SSH tunnel → k3s API (127.0.0.1:6443)

## Monitoring

```bash
# Check resource usage
kubectl top pods -n teslamate

# Check disk usage
df -h /

# Check memory and swap
free -h

# View TeslaMate logs
make logs

# View Grafana logs
make logs APP=grafana

# View all pod status
make status
```
