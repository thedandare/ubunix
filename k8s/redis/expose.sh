#!/usr/bin/env bash
set -euo pipefail

# Publishes Redis through Traefik on the cluster node IPs:
#   Redis    -> :18494
#   Sentinel -> :26379

SSH_HOST="${SSH_HOST:-root@35.215.39.218}"
SSH_KEY="${SSH_KEY:-/mnt/c/Users/leo/.ssh/root_id_ed25519}"
if [ -f "/root/.ssh/root_id_ed25519" ]; then
  SSH_KEY="/root/.ssh/root_id_ed25519"
fi
PORT="${SSH_PORT:-22}"

NAMESPACE="${NAMESPACE:-redis}"
TRAEFIK_VERSION="${TRAEFIK_VERSION:-39.0.8}"
REMOTE_DIR="${REMOTE_DIR:-/tmp/k8s-redis}"

# Convert Windows path backslashes to forward slashes for compatibility in git bash/ssh command
SSH_KEY_POSIX=$(echo "$SSH_KEY" | sed 's/\\/\//g')
SSH=(ssh -i "$SSH_KEY_POSIX" -p "$PORT" -o StrictHostKeyChecking=no "$SSH_HOST")

cd "$(dirname "$0")"

# ─── Step 1: Copy manifests ───────────────────────────────────────────────────
echo "=== Copying manifests to remote server ==="
"${SSH[@]}" "mkdir -p $REMOTE_DIR"
"${SSH[@]}" "rm -f $REMOTE_DIR/traefik-values-redis.yaml $REMOTE_DIR/expose.yaml"
"${SSH[@]}" "cat > $REMOTE_DIR/traefik-values-redis.yaml" < traefik-values-redis.yaml
"${SSH[@]}" "cat > $REMOTE_DIR/expose.yaml" < expose.yaml

# ─── Step 2: Helm upgrade Traefik (idempotent) ───────────────────────────────
# Only runs if the DaemonSet does not already bind hostPort 18494 for the
# 'redis' entrypoint.
TRAEFIK_REDIS_HOSTPORT=$("${SSH[@]}" \
  "microk8s kubectl get daemonset/traefik -n ingress -o jsonpath='{range .spec.template.spec.containers[0].ports[?(@.name==\"redis\")]}{.hostPort}{end}' 2>/dev/null || true")

if [ "${TRAEFIK_REDIS_HOSTPORT:-}" != "18494" ] || [ -n "${FORCE_TRAEFIK_UPGRADE:-}" ]; then
  echo "=== Upgrading Traefik via Helm to add the 'redis' entrypoints ==="
  "${SSH[@]}" \
    "microk8s helm upgrade traefik traefik/traefik --version $TRAEFIK_VERSION -n ingress --reuse-values --skip-schema-validation -f $REMOTE_DIR/traefik-values-redis.yaml"

  echo "=== Waiting for Traefik DaemonSet rollout ==="
  "${SSH[@]}" "microk8s kubectl rollout status daemonset/traefik -n ingress --timeout=180s"
else
  echo "=== Traefik already has the 'redis' entrypoints — skipping Helm upgrade ==="
fi

# ─── Step 3: Apply IngressRouteTCP ────────────────────────────────────────────
echo "=== Applying IngressRouteTCP ==="
"${SSH[@]}" "microk8s kubectl apply -f $REMOTE_DIR/expose.yaml"

# ─── Step 4: Verify ───────────────────────────────────────────────────────────
echo ""
echo "=== Verification ==="
"${SSH[@]}" bash <<REMOTE
echo "--- Traefik pods ---"
microk8s kubectl get pods -n ingress -o wide
echo ""
echo "--- Traefik service ports ---"
microk8s kubectl get svc traefik -n ingress -o jsonpath='{range .spec.ports[*]}{.name}:{.port}  {end}' && echo ""
echo ""
echo "--- IngressRouteTCP ---"
microk8s kubectl get ingressroutetcp -n $NAMESPACE
echo ""
echo "--- Redis pods ---"
microk8s kubectl get pods -n $NAMESPACE -o wide
REMOTE

echo ""
echo "=== Redis is now exposed via Traefik ==="
echo "    in-cluster : redis.$NAMESPACE.svc:18494 (sentinel :26379)"
echo "    external   : 35.215.39.218 / 35.215.39.218 / 34.1.17.21 on 18494 and 26379"
echo "    password   : ./get_password.sh"
echo "    connect    : redis-cli -h 35.215.39.218 -p 18494 -a \$(./get_password.sh)"
echo "    NOTE: the cloud firewall must allow tcp:18494 and tcp:26379 for the"
echo "          node tag (gcnix-ssh on GCE), otherwise this only works from the"
echo "          node/VPN. Connections on 18494 are load balanced across the"
echo "          sentinel group, so writes may hit a replica (-READONLY)."
