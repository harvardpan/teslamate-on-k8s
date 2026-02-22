# TeslaMate on Kubernetes

Deploy [TeslaMate](https://github.com/teslamate-org/teslamate) on a lightweight Kubernetes cluster (k3s), secured with Google OAuth via [oauth2-proxy](https://github.com/oauth2-proxy/oauth2-proxy), and exposed to the internet via [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/).

## Architecture

```
Raspberry Pi 5 / k3d (local dev)
├── TeslaMate        (Tesla data logger)
├── PostgreSQL 16    (database)
├── Grafana          (dashboards)
├── Mosquitto        (MQTT broker)
├── oauth2-proxy     (Google OAuth)
├── cloudflared      (Cloudflare Tunnel)
└── Traefik          (ingress, built into k3s)
```

Traffic flow: `Cloudflare Tunnel → oauth2-proxy (auth) → Traefik (routing) → TeslaMate / Grafana`

No port forwarding or public IP required.

## Prerequisites

Install the required tools via [Homebrew](https://brew.sh/):

```bash
brew install k3d kubectl kustomize tilt cloudflared
brew install --cask docker
```

You also need:
- A domain with DNS on Cloudflare (the setup auto-creates DNS records via `cloudflared tunnel route dns`; if your domain uses a different DNS provider, you can still use Cloudflare Tunnel but must manually CNAME your hostname to `<tunnel-id>.cfargotunnel.com`)
- Google OAuth credentials — see [Google OAuth Setup](docs/google-oauth-setup.md)

## Quick Start

```bash
# 1. Create a local k3s cluster
make cluster

# 2. Configure everything (domain, Cloudflare tunnel, secrets)
make configure

# 3. Deploy
make tilt-up
```

`make configure` is interactive and handles:
- Setting your hostname and timezone
- Creating a Cloudflare Tunnel and DNS route
- Generating encryption keys and database passwords
- Collecting your Google OAuth credentials
- Writing `.env` and generating Kustomize overlays
- Creating Kubernetes secrets

Re-running `make configure` is safe — existing values become defaults.

## Verify

```bash
kubectl get pods -n teslamate
```

All pods should be `Running`. Tilt automatically sets up port-forwards — access TeslaMate at `http://localhost:4000` and Grafana at `http://localhost:3000`. Once Cloudflare Tunnel is connected, they're also available at your configured hostname (e.g., `https://teslamate.example.com` and `https://teslamate.example.com/grafana`).

## Google OAuth

TeslaMate is protected by Google OAuth via oauth2-proxy. Only the email address you specify during `make configure` can access the application.

You must create OAuth credentials in the [Google Cloud Console](https://console.cloud.google.com/) before running `make configure`. See [docs/google-oauth-setup.md](docs/google-oauth-setup.md) for step-by-step instructions.

## Tesla API Connection

After deployment, connect TeslaMate to your Tesla account by generating API tokens:

```bash
make tesla-token
```

This opens a browser login. Paste the resulting tokens into the TeslaMate web UI. Tokens are encrypted at rest and automatically refreshed. See [docs/tesla-api-setup.md](docs/tesla-api-setup.md) for details.

## TeslaFi Data Import

Import historical data from TeslaFi into TeslaMate:

```bash
# Place your TeslaFi CSV exports in ./import/, then:
make import-teslafi
```

The import script validates filenames, fixes known data format issues ([teslamate-org/teslamate#4477](https://github.com/teslamate-org/teslamate/issues/4477)), and copies files into the TeslaMate pod. See [docs/teslafi-import.md](docs/teslafi-import.md) for export instructions and troubleshooting.

## Deploying to Raspberry Pi 5

For a permanent, low-power deployment (~4W), run the setup script on your RPi:

```bash
# On the RPi (via SSH)
git clone https://github.com/<your-username>/teslamate-on-k8s.git
cd teslamate-on-k8s
make setup-rpi             # installs k3s, configures SSD storage
make configure             # same interactive setup
kubectl apply -k k8s/overlays/local/
```

See [docs/rpi-setup.md](docs/rpi-setup.md) for hardware recommendations, OS installation, and storage notes.

## Backups

```bash
# Manual backup (default: /var/backups/teslamate)
make backup

# Install daily 3am backup cron job
make setup-backup-cron
```

Backups are gzipped `pg_dump` files with 7-day daily + 4-week weekly retention.

## Operations Runbook

### Check cluster health

```bash
make status                           # pod status
make logs                             # TeslaMate logs
make logs APP=grafana                 # Grafana logs
make logs APP=postgres                # PostgreSQL logs
```

### Restart a service

```bash
kubectl rollout restart -n teslamate deploy/teslamate
kubectl rollout restart -n teslamate deploy/grafana
kubectl rollout restart -n teslamate deploy/cloudflared
```

### Restore from backup

```bash
# List available backups
make restore

# Restore a specific backup (will prompt for confirmation)
make restore BACKUP_FILE=/var/backups/teslamate/teslamate-backup-20260222.sql.gz
```

The restore script:
1. Scales down TeslaMate (prevents writes)
2. Drops and recreates the database
3. Loads the backup
4. Scales TeslaMate back up
5. Verifies row counts match

### Remote kubectl from MacBook (via Lens or CLI)

The k3s API server on the RPi is firewalled to localhost only. Access it via SSH tunnel:

```bash
# Start SSH tunnel (maps RPi port 6443 to local port 16443)
ssh -f -N teslamate-pi

# Use kubectl with the RPi kubeconfig
KUBECONFIG=~/.kube/teslamate-pi-config kubectl get pods -n teslamate
```

For Lens: add `~/.kube/teslamate-pi-config` as a kubeconfig. Start the SSH tunnel before connecting.

SSH config (`~/.ssh/config`):
```
Host teslamate-pi
    HostName teslamate-pi.local
    User harvardpan
    IdentityFile ~/.ssh/id_ed25519
    LocalForward 16443 127.0.0.1:6443
```

### Update container images

1. Edit pinned versions in the deployments under `k8s/base/`
2. Apply: `kubectl apply -k k8s/base/` (or `k8s/overlays/local/` if using overlays)
3. Verify: `make status`

### Cloudflare Tunnel not connecting

```bash
make logs APP=cloudflared
# Common fix: restart cloudflared
kubectl rollout restart -n teslamate deploy/cloudflared
```

### PostgreSQL disk usage

```bash
kubectl exec -n teslamate statefulset/postgres -- \
  psql -U teslamate -c "SELECT pg_size_pretty(pg_database_size('teslamate'));"
```

## Secrets

All secrets are created by `make configure` and stored as Kubernetes Secrets. No secrets are committed to this repository. See [.env.example](.env.example) for the list of configuration values.

## Cost

| Item | Monthly |
|------|---------|
| Electricity (RPi, ~4W) | ~$0.50 |
| Domain | ~$0.75 |
| Cloudflare (free tier) | $0.00 |
| **Total** | **~$1.25** |

## License

[MIT](LICENSE)
