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
./scripts/setup-rpi.sh    # installs k3s, configures SSD storage
make configure             # same interactive setup
kubectl apply -k k8s/overlays/local/
```

See [docs/rpi-setup.md](docs/rpi-setup.md) for hardware recommendations, OS installation, and storage notes.

## Backups

```bash
# Manual backup (default: /mnt/ssd/backups)
make backup

# Install daily 3am backup cron job
make setup-backup-cron
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
