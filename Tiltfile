# TeslaMate on K8s — Tiltfile
#
# Usage:
#   make tilt-up     # start Tilt
#   make tilt-down   # stop Tilt
#
# Prerequisites:
#   1. k3d cluster running: make cluster
#   2. Environment configured: make configure

# Apply PVCs directly — these are NOT managed by Tilt so they persist across tilt down/up.
local('kubectl apply -f k8s/base/postgres/pvc.yaml -f k8s/base/teslamate/import-pvc.yaml')

# Deploy all resources from the local Kustomize overlay
overlay_dir = 'k8s/overlays/local'
if os.path.exists(os.path.join(overlay_dir, 'kustomization.yaml')):
    k8s_yaml(kustomize(overlay_dir))

    # --- Resource grouping and port-forwards ---

    k8s_resource('teslamate',
        port_forwards=['4000:4000'],
        labels=['app'])

    k8s_resource('grafana',
        port_forwards=['3000:3000'],
        labels=['app'])

    k8s_resource('postgres',
        labels=['data'])

    k8s_resource('mosquitto',
        labels=['data'])

    k8s_resource('oauth2-proxy',
        labels=['auth'])

    k8s_resource('cloudflared',
        labels=['network'])
else:
    warn('k8s/overlays/local not found. Run "make configure" to generate it.')
