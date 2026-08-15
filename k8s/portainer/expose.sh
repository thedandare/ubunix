#!/usr/bin/env bash
set -euo pipefail

# Publishes Portainer through Traefik on the cluster LoadBalancer IPs:
#   UI   -> :9000
#   Edge -> :8000

SSH_HOST="root@34.0.50.126"
SSH_KEY="/mnt/c/Users/leo/.ssh/root_id_ed25519"
if [ -f "$HOME/.ssh/root_id_ed25519" ]; then
  SSH_KEY="$HOME/.ssh/root_id_ed25519"
fi
PORT=22

TRAEFIK_VERSION="${TRAEFIK_VERSION:-39.0.8}"
REMOTE_DIR="/tmp/k8s-portainer"

# Convert Windows path backslashes to forward slashes for compatibility in git bash/ssh command
SSH_KEY_POSIX=$(echo "$SSH_KEY" | sed 's/\\/\//g')
SSH=(ssh -i "$SSH_KEY_POSIX" -p "$PORT" -o StrictHostKeyChecking=no "$SSH_HOST")

cd "$(dirname "$0")"

# ─── Step 1: Copy manifests ───────────────────────────────────────────────────
echo "=== Copying manifests to remote server ==="
"${SSH[@]}" "mkdir -p $REMOTE_DIR"
"${SSH[@]}" "cat > $REMOTE_DIR/traefik-values-portainer.yaml" < traefik-values-portainer.yaml
"${SSH[@]}" "cat > $REMOTE_DIR/expose.yaml" < expose.yaml

# ─── Step 2: Helm upgrade Traefik (idempotent) ───────────────────────────────
# Only runs if the 'portainer' entrypoint is not already in the DaemonSet args.
TRAEFIK_HAS_PORTAINER=$("${SSH[@]}" \
  "microk8s kubectl get daemonset/traefik -n ingress -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null | grep -c entryPoints.portainer.address || true")

if [ "${TRAEFIK_HAS_PORTAINER:-0}" -eq 0 ] || [ -n "${FORCE_TRAEFIK_UPGRADE:-}" ]; then
  echo "=== Upgrading Traefik via Helm to add 'portainer' entrypoints ==="
  "${SSH[@]}" \
    "microk8s helm upgrade traefik traefik/traefik --version $TRAEFIK_VERSION -n ingress --reuse-values --skip-schema-validation -f $REMOTE_DIR/traefik-values-portainer.yaml"

  echo "=== Waiting for Traefik DaemonSet rollout ==="
  "${SSH[@]}" "microk8s kubectl rollout status daemonset/traefik -n ingress --timeout=180s"
else
  echo "=== Traefik already has 'portainer' entrypoints — skipping Helm upgrade ==="
fi

# ─── Step 3: Apply IngressRouteTCP ────────────────────────────────────────────
echo "=== Applying IngressRouteTCP ==="
"${SSH[@]}" "microk8s kubectl apply -f $REMOTE_DIR/expose.yaml"

# ─── Step 4: Verify ───────────────────────────────────────────────────────────
echo ""
echo "=== Verification ==="
"${SSH[@]}" bash <<'REMOTE'
echo "--- Traefik pods ---"
microk8s kubectl get pods -n ingress -o wide
echo ""
echo "--- Traefik service ports ---"
microk8s kubectl get svc traefik -n ingress -o jsonpath='{range .spec.ports[*]}{.name}:{.port}  {end}' && echo ""
echo ""
echo "--- IngressRoute / IngressRouteTCP ---"
microk8s kubectl get ingressroute,ingressroutetcp -n portainer
echo ""
echo "--- HTTPS probe via Traefik ---"
curl -sk -o /dev/null -w 'https://portainer.34.1.28.21.nip.io -> %{http_code}\n' https://portainer.34.1.28.21.nip.io/
REMOTE

echo ""
echo "=== Portainer is now exposed via Traefik ==="
echo "    UI (public, 443): https://portainer.34.1.28.21.nip.io"
echo "    UI (node-local) : http://34.1.28.21:9000"
echo "    Edge agents     : 34.1.28.21:8000"
echo "    NOTE: the cloud firewall only allows 443 from outside the cluster;"
echo "          9000/8000 are reachable from the node/VPN only."
