#!/usr/bin/env bash
set -euo pipefail

# Publishes Headlamp through Traefik on the cluster node IPs:
#   Headlamp -> :4466

SSH_HOST="${SSH_HOST:-root@34.0.48.251}"
SSH_KEY="${SSH_KEY:-/mnt/c/Users/leo/.ssh/root_id_ed25519}"
if [ -f "$HOME/.ssh/root_id_ed25519" ]; then
  SSH_KEY="$HOME/.ssh/root_id_ed25519"
fi
PORT="${SSH_PORT:-22}"

NAMESPACE="${NAMESPACE:-kube-system}"
SERVICE_NAME="${SERVICE_NAME:-my-headlamp}"
HEADLAMP_PORT="${HEADLAMP_PORT:-4466}"
TRAEFIK_VERSION="${TRAEFIK_VERSION:-39.0.8}"
REMOTE_DIR="${REMOTE_DIR:-/tmp/k8s-headlamp}"

SSH_KEY_POSIX=$(echo "$SSH_KEY" | sed 's/\\/\//g')
SSH=(ssh -i "$SSH_KEY_POSIX" -p "$PORT" -o StrictHostKeyChecking=no "$SSH_HOST")

cd "$(dirname "$0")"

echo "=== Checking the Headlamp service ==="
"${SSH[@]}" "microk8s kubectl get service/$SERVICE_NAME -n $NAMESPACE"

echo "=== Copying manifests to remote server ==="
"${SSH[@]}" "mkdir -p $REMOTE_DIR"
"${SSH[@]}" "cat > $REMOTE_DIR/traefik-values-headlamp.yaml" < traefik-values-headlamp.yaml
"${SSH[@]}" "cat > $REMOTE_DIR/expose.yaml" < expose.yaml

TRAEFIK_HEADLAMP_HOSTPORT=$("${SSH[@]}" \
  "microk8s kubectl get daemonset/traefik -n ingress -o jsonpath='{range .spec.template.spec.containers[0].ports[?(@.name==\"headlamp\")]}{.hostPort}{end}' 2>/dev/null || true")

if [ "${TRAEFIK_HEADLAMP_HOSTPORT:-}" != "$HEADLAMP_PORT" ] || [ -n "${FORCE_TRAEFIK_UPGRADE:-}" ]; then
  echo "=== Upgrading Traefik via Helm to add the 'headlamp' entrypoint ==="
  "${SSH[@]}" \
    "microk8s helm upgrade traefik traefik/traefik --version $TRAEFIK_VERSION -n ingress --reuse-values --skip-schema-validation -f $REMOTE_DIR/traefik-values-headlamp.yaml"

  echo "=== Waiting for Traefik DaemonSet rollout ==="
  "${SSH[@]}" "microk8s kubectl rollout status daemonset/traefik -n ingress --timeout=180s"
else
  echo "=== Traefik already has the 'headlamp' entrypoint — skipping Helm upgrade ==="
fi

echo "=== Applying IngressRouteTCP ==="
"${SSH[@]}" "microk8s kubectl apply -f $REMOTE_DIR/expose.yaml"

echo ""
echo "=== Verification ==="
"${SSH[@]}" bash <<REMOTE
echo "--- Traefik service ports ---"
microk8s kubectl get svc traefik -n ingress -o jsonpath='{range .spec.ports[*]}{.name}:{.port}  {end}' && echo ""
echo ""
echo "--- IngressRouteTCP ---"
microk8s kubectl get ingressroutetcp headlamp-tcp -n $NAMESPACE
echo ""
echo "--- Headlamp service ---"
microk8s kubectl get service $SERVICE_NAME -n $NAMESPACE
REMOTE

echo ""
echo "=== Headlamp is now exposed via Traefik ==="
echo "    external   : 34.1.25.177:$HEADLAMP_PORT / 34.1.28.21:$HEADLAMP_PORT / 34.1.17.21:$HEADLAMP_PORT"
echo "    login      : use the token printed by ./deploy-headlamp-token.sh"
echo "    NOTE: the cloud firewall must allow tcp:$HEADLAMP_PORT for the node tag."
