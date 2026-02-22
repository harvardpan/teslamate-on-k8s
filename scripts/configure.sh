#!/usr/bin/env bash
set -euo pipefail

# TeslaMate on K8s — Interactive configuration
# Creates .env, Kustomize overlay, Cloudflare tunnel, and K8s secrets.
#
# Safe to re-run: existing .env values become defaults.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
OVERLAY_DIR="$REPO_ROOT/k8s/overlays/local"
NAMESPACE="teslamate"
TUNNEL_NAME="teslamate"

echo "=== TeslaMate Configuration ==="
echo ""

# --- Load existing .env as defaults ---
if [ -f "$ENV_FILE" ]; then
  echo "Found existing .env — values will be offered as defaults."
  echo ""
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# --- Step 1: OAuth prerequisite check ---
echo "Step 1: Prerequisites"
echo ""
echo "  Before continuing, you need Google OAuth credentials."
echo "  If you haven't created them yet, see: docs/google-oauth-setup.md"
echo ""
read -p "Do you have your Google OAuth Client ID and Secret ready? (Y/n): " OAUTH_READY
if [ "$OAUTH_READY" = "n" ] || [ "$OAUTH_READY" = "N" ]; then
  echo ""
  echo "Please set up Google OAuth first:"
  echo "  1. Read docs/google-oauth-setup.md"
  echo "  2. Create credentials at https://console.cloud.google.com/"
  echo "  3. Re-run: make configure"
  exit 0
fi
echo ""

# --- Step 2: Hostname ---
echo "Step 2: Hostname"
echo ""
DEFAULT_HOSTNAME="${TESLAMATE_HOSTNAME:-}"
if [ -n "$DEFAULT_HOSTNAME" ]; then
  read -p "Enter your TeslaMate hostname [$DEFAULT_HOSTNAME]: " TESLAMATE_HOSTNAME
  TESLAMATE_HOSTNAME="${TESLAMATE_HOSTNAME:-$DEFAULT_HOSTNAME}"
else
  read -p "Enter your TeslaMate hostname (e.g., tesla.yourdomain.com): " TESLAMATE_HOSTNAME
fi
if [ -z "$TESLAMATE_HOSTNAME" ]; then
  echo "Error: Hostname is required."
  exit 1
fi

# Derive root domain (strip first subdomain label)
ROOT_DOMAIN="${TESLAMATE_HOSTNAME#*.}"
if [ "$ROOT_DOMAIN" = "$TESLAMATE_HOSTNAME" ]; then
  echo "Warning: Hostname '$TESLAMATE_HOSTNAME' has no subdomain."
  echo "  cookie-domain and whitelist-domain will use '.$TESLAMATE_HOSTNAME'"
  ROOT_DOMAIN="$TESLAMATE_HOSTNAME"
fi
echo "  Hostname:    $TESLAMATE_HOSTNAME"
echo "  Root domain: $ROOT_DOMAIN"
echo ""

# --- Step 3: Cloudflare Tunnel ---
echo "Step 3: Cloudflare Tunnel Setup"
echo ""

# Authenticate
if [ -f "$HOME/.cloudflared/cert.pem" ]; then
  echo "  Already authenticated (found ~/.cloudflared/cert.pem)."
else
  echo "  Opening browser to authorize cloudflared..."
  cloudflared tunnel login
fi

# Create tunnel
if cloudflared tunnel list 2>/dev/null | grep -q "$TUNNEL_NAME"; then
  echo "  Tunnel '$TUNNEL_NAME' already exists."
else
  cloudflared tunnel create "$TUNNEL_NAME"
  echo "  Tunnel '$TUNNEL_NAME' created."
fi

# Route DNS
if cloudflared tunnel route dns "$TUNNEL_NAME" "$TESLAMATE_HOSTNAME" 2>&1 | grep -q "already exists"; then
  echo "  DNS route for $TESLAMATE_HOSTNAME already exists."
else
  echo "  DNS route created: $TESLAMATE_HOSTNAME → $TUNNEL_NAME"
fi

# Route DNS for SSH subdomain
if cloudflared tunnel route dns "$TUNNEL_NAME" "ssh.${ROOT_DOMAIN}" 2>&1 | grep -q "already exists"; then
  echo "  DNS route for ssh.${ROOT_DOMAIN} already exists."
else
  echo "  DNS route created: ssh.${ROOT_DOMAIN} → $TUNNEL_NAME"
fi

# RPi static IP for SSH tunnel route
DEFAULT_RPI_IP="${RPI_STATIC_IP:-192.168.1.167}"
read -p "  Enter RPi static LAN IP [$DEFAULT_RPI_IP]: " RPI_STATIC_IP
RPI_STATIC_IP="${RPI_STATIC_IP:-$DEFAULT_RPI_IP}"
echo "  RPi static IP: $RPI_STATIC_IP"

# Auto-detect credentials file
TUNNEL_ID=$(cloudflared tunnel list -o json 2>/dev/null | python3 -c "import sys,json; tunnels=json.load(sys.stdin); print(next((t['id'] for t in tunnels if t['name']=='$TUNNEL_NAME'), ''))" 2>/dev/null || true)
DEFAULT_CF_CREDS="${CLOUDFLARE_TUNNEL_CREDENTIALS:-}"
if [ -n "$TUNNEL_ID" ] && [ -f "$HOME/.cloudflared/${TUNNEL_ID}.json" ]; then
  CLOUDFLARE_TUNNEL_CREDENTIALS="$HOME/.cloudflared/${TUNNEL_ID}.json"
  echo "  Credentials file: $CLOUDFLARE_TUNNEL_CREDENTIALS"
elif [ -n "$DEFAULT_CF_CREDS" ] && [ -f "$DEFAULT_CF_CREDS" ]; then
  CLOUDFLARE_TUNNEL_CREDENTIALS="$DEFAULT_CF_CREDS"
  echo "  Credentials file: $CLOUDFLARE_TUNNEL_CREDENTIALS"
else
  read -p "  Enter path to tunnel credentials JSON file: " CLOUDFLARE_TUNNEL_CREDENTIALS
  if [ ! -f "$CLOUDFLARE_TUNNEL_CREDENTIALS" ]; then
    echo "Error: File not found: $CLOUDFLARE_TUNNEL_CREDENTIALS"
    exit 1
  fi
fi
echo ""

# --- Step 4: Timezone ---
echo "Step 4: Timezone"
DEFAULT_TZ="${TIMEZONE:-$(python3 -c 'import subprocess; r=subprocess.run(["readlink","/etc/localtime"],capture_output=True,text=True); print(r.stdout.strip().split("zoneinfo/")[-1])' 2>/dev/null || echo "UTC")}"
read -p "Enter timezone [$DEFAULT_TZ]: " TIMEZONE
TIMEZONE="${TIMEZONE:-$DEFAULT_TZ}"
echo "  Timezone: $TIMEZONE"
echo ""

# --- Step 5: Auto-generate secrets (reuse existing if present) ---
echo "Step 5: Generating secrets"

# Helper: recover a secret value from K8s if not already set.
# Priority: .env (already sourced) → K8s secret → generate new.
k8s_secret_value() {
  local secret_name="$1" key="$2"
  if kubectl get secret "$secret_name" -n "$NAMESPACE" &>/dev/null; then
    kubectl get secret "$secret_name" -n "$NAMESPACE" -o jsonpath="{.data.$key}" | base64 -d 2>/dev/null
  fi
}

if [ -z "${ENCRYPTION_KEY:-}" ]; then
  ENCRYPTION_KEY="$(k8s_secret_value teslamate-secret ENCRYPTION_KEY)"
fi
ENCRYPTION_KEY="${ENCRYPTION_KEY:-$(openssl rand -hex 32)}"

if [ -z "${DATABASE_PASS:-}" ]; then
  DATABASE_PASS="$(k8s_secret_value teslamate-db-secret POSTGRES_PASSWORD)"
fi
DATABASE_PASS="${DATABASE_PASS:-$(openssl rand -base64 24)}"

if [ -z "${OAUTH_COOKIE_SECRET:-}" ]; then
  OAUTH_COOKIE_SECRET="$(k8s_secret_value oauth2-proxy-secret OAUTH_COOKIE_SECRET)"
fi
OAUTH_COOKIE_SECRET="${OAUTH_COOKIE_SECRET:-$(openssl rand -base64 32 | head -c 32 | base64)}"

echo "  ENCRYPTION_KEY:      (set)"
echo "  DATABASE_PASS:       (set)"
echo "  OAUTH_COOKIE_SECRET: (set)"
echo ""

# --- Step 6: OAuth credentials ---
echo "Step 6: OAuth credentials"
echo ""
DEFAULT_CLIENT_ID="${OAUTH_CLIENT_ID:-}"
if [ -n "$DEFAULT_CLIENT_ID" ]; then
  read -p "Enter OAuth Client ID [$DEFAULT_CLIENT_ID]: " OAUTH_CLIENT_ID
  OAUTH_CLIENT_ID="${OAUTH_CLIENT_ID:-$DEFAULT_CLIENT_ID}"
else
  read -p "Enter OAuth Client ID: " OAUTH_CLIENT_ID
fi
if [ -z "$OAUTH_CLIENT_ID" ]; then
  echo "Error: OAuth Client ID is required."
  exit 1
fi

DEFAULT_CLIENT_SECRET="${OAUTH_CLIENT_SECRET:-}"
if [ -n "$DEFAULT_CLIENT_SECRET" ]; then
  read -s -p "Enter OAuth Client Secret [****]: " OAUTH_CLIENT_SECRET_INPUT
  echo ""
  OAUTH_CLIENT_SECRET="${OAUTH_CLIENT_SECRET_INPUT:-$DEFAULT_CLIENT_SECRET}"
else
  read -s -p "Enter OAuth Client Secret: " OAUTH_CLIENT_SECRET
  echo ""
fi
if [ -z "$OAUTH_CLIENT_SECRET" ]; then
  echo "Error: OAuth Client Secret is required."
  exit 1
fi
echo ""

# --- Step 7: Authenticated email ---
echo "Step 7: Authenticated email"
DEFAULT_EMAIL="${AUTHENTICATED_EMAIL:-}"
if [ -n "$DEFAULT_EMAIL" ]; then
  read -p "Enter your Google email (only this email can access TeslaMate) [$DEFAULT_EMAIL]: " AUTHENTICATED_EMAIL
  AUTHENTICATED_EMAIL="${AUTHENTICATED_EMAIL:-$DEFAULT_EMAIL}"
else
  read -p "Enter your Google email (only this email can access TeslaMate): " AUTHENTICATED_EMAIL
fi
if [ -z "$AUTHENTICATED_EMAIL" ]; then
  echo "Error: Email is required."
  exit 1
fi
echo ""

# --- Step 8: Write .env ---
echo "Step 8: Writing .env"
cat > "$ENV_FILE" <<EOF
# TeslaMate on Kubernetes — Generated by: make configure
# DO NOT commit this file to the repository.

TESLAMATE_HOSTNAME='$TESLAMATE_HOSTNAME'
TIMEZONE='$TIMEZONE'

ENCRYPTION_KEY='$ENCRYPTION_KEY'
DATABASE_PASS='$DATABASE_PASS'

OAUTH_CLIENT_ID='$OAUTH_CLIENT_ID'
OAUTH_CLIENT_SECRET='$OAUTH_CLIENT_SECRET'
OAUTH_COOKIE_SECRET='$OAUTH_COOKIE_SECRET'

CLOUDFLARE_TUNNEL_CREDENTIALS='$CLOUDFLARE_TUNNEL_CREDENTIALS'

RPI_STATIC_IP='$RPI_STATIC_IP'

AUTHENTICATED_EMAIL='$AUTHENTICATED_EMAIL'
EOF
echo "  Written: .env"
echo ""

# --- Step 9: Generate Kustomize overlay ---
echo "Step 9: Generating Kustomize overlay"
mkdir -p "$OVERLAY_DIR/patches"

# kustomization.yaml
cat > "$OVERLAY_DIR/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

patches:
  - path: patches/teslamate-ingress.yaml
  - path: patches/grafana-ingress.yaml
  - path: patches/teslamate-config.yaml
  - path: patches/grafana-config.yaml
  - path: patches/oauth2-proxy-config.yaml
  - path: patches/cloudflared-config.yaml
EOF

# Ingress patches
cat > "$OVERLAY_DIR/patches/teslamate-ingress.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: teslamate
  namespace: teslamate
spec:
  rules:
    - host: ${TESLAMATE_HOSTNAME}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: teslamate
                port:
                  number: 4000
EOF

cat > "$OVERLAY_DIR/patches/grafana-ingress.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: teslamate
spec:
  rules:
    - host: ${TESLAMATE_HOSTNAME}
      http:
        paths:
          - path: /grafana
            pathType: Prefix
            backend:
              service:
                name: grafana
                port:
                  number: 3000
EOF

# TeslaMate deployment patch (TZ + GRAFANA_HOST)
cat > "$OVERLAY_DIR/patches/teslamate-config.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: teslamate
  namespace: teslamate
spec:
  template:
    spec:
      containers:
        - name: teslamate
          env:
            - name: TZ
              value: "${TIMEZONE}"
            - name: GRAFANA_HOST
              value: "${TESLAMATE_HOSTNAME}/grafana"
EOF

# Grafana deployment patch (GF_SERVER_ROOT_URL)
cat > "$OVERLAY_DIR/patches/grafana-config.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: teslamate
spec:
  template:
    spec:
      containers:
        - name: grafana
          env:
            - name: GF_SERVER_ROOT_URL
              value: "https://${TESLAMATE_HOSTNAME}/grafana"
EOF

# oauth2-proxy deployment patch (args with domain-specific values)
cat > "$OVERLAY_DIR/patches/oauth2-proxy-config.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: oauth2-proxy
  namespace: teslamate
spec:
  template:
    spec:
      containers:
        - name: oauth2-proxy
          args:
            - --http-address=0.0.0.0:4180
            - --provider=google
            - --authenticated-emails-file=/etc/oauth2-proxy/authenticated-emails.txt
            - --cookie-secure=true
            - --cookie-httponly=true
            - --cookie-samesite=lax
            - --reverse-proxy=true
            - --set-xauthrequest=true
            - --upstream=http://traefik.kube-system.svc.cluster.local:80
            - --email-domain=*
            - --skip-provider-button=true
            - --redirect-url=https://${TESLAMATE_HOSTNAME}/oauth2/callback
            - --cookie-domain=.${ROOT_DOMAIN}
            - --whitelist-domain=.${ROOT_DOMAIN}
            - --pass-host-header=true
EOF

# cloudflared ConfigMap (full replacement — embedded YAML can't be strategically merged)
cat > "$OVERLAY_DIR/patches/cloudflared-config.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflared-config
  namespace: teslamate
data:
  config.yaml: |
    tunnel: ${TUNNEL_NAME}
    credentials-file: /etc/cloudflared/credentials.json
    no-autoupdate: true
    ingress:
      - hostname: ssh.${ROOT_DOMAIN}
        service: ssh://${RPI_STATIC_IP}:22
      - hostname: ${TESLAMATE_HOSTNAME}
        service: http://oauth2-proxy.teslamate.svc.cluster.local:4180
      - service: http_status:404
EOF

echo "  Generated: k8s/overlays/local/"
echo ""

# --- Step 10: Create K8s secrets ---
echo "Step 10: Creating Kubernetes secrets"

# Check if cluster is reachable
if ! kubectl cluster-info &>/dev/null; then
  echo "  Warning: Kubernetes cluster not reachable. Skipping secret creation."
  echo "  Run 'make configure' again after the cluster is running."
  echo "  (macOS: make cluster | RPi: make setup-rpi)"
  echo ""
else
  # Ensure namespace exists
  kubectl get namespace "$NAMESPACE" &>/dev/null || kubectl create namespace "$NAMESPACE"

  kubectl create secret generic teslamate-db-secret \
    --from-literal=POSTGRES_PASSWORD="$DATABASE_PASS" \
    -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  echo "  Created: teslamate-db-secret"

  kubectl create secret generic teslamate-secret \
    --from-literal=ENCRYPTION_KEY="$ENCRYPTION_KEY" \
    -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  echo "  Created: teslamate-secret"

  kubectl create secret generic oauth2-proxy-secret \
    --from-literal=OAUTH_CLIENT_ID="$OAUTH_CLIENT_ID" \
    --from-literal=OAUTH_CLIENT_SECRET="$OAUTH_CLIENT_SECRET" \
    --from-literal=OAUTH_COOKIE_SECRET="$OAUTH_COOKIE_SECRET" \
    -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  echo "  Created: oauth2-proxy-secret"

  kubectl create secret generic oauth2-proxy-emails \
    --from-literal=authenticated-emails.txt="$AUTHENTICATED_EMAIL" \
    -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  echo "  Created: oauth2-proxy-emails"

  kubectl create secret generic cloudflared-secret \
    --from-file=credentials.json="$CLOUDFLARE_TUNNEL_CREDENTIALS" \
    -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  echo "  Created: cloudflared-secret"
fi
echo ""

echo "=== Configuration complete ==="
echo ""
echo "Next steps:"
if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "  make tilt-up                        # deploy the full stack"
else
  echo "  kubectl apply -k k8s/overlays/local/  # deploy the full stack"
fi
echo ""
echo "To reconfigure, re-run: make configure"
