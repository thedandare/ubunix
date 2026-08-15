#!/usr/bin/env bash
set -euo pipefail

# Publishes the CloudNativePG primary through Traefik on the cluster
# LoadBalancer IPs:
#   PostgreSQL -> :5432

SSH_HOST="${SSH_HOST:-root@34.0.50.126}"
SSH_KEY="${SSH_KEY:-/mnt/c/Users/leo/.ssh/root_id_ed25519}"
if [ -f "$HOME/.ssh/root_id_ed25519" ]; then
  SSH_KEY="$HOME/.ssh/root_id_ed25519"
fi
PORT="${SSH_PORT:-22}"

CLUSTER_NAME="${CLUSTER_NAME:-postgres-server}"
NAMESPACE="${NAMESPACE:-default}"
TRAEFIK_VERSION="${TRAEFIK_VERSION:-39.0.8}"
REMOTE_DIR="${REMOTE_DIR:-/tmp/k8s-psql}"

# Convert Windows path backslashes to forward slashes for compatibility in git bash/ssh command
SSH_KEY_POSIX=$(echo "$SSH_KEY" | sed 's/\\/\//g')
SSH=(ssh -i "$SSH_KEY_POSIX" -p "$PORT" -o StrictHostKeyChecking=no "$SSH_HOST")

cd "$(dirname "$0")"

# ─── Step 1: Copy manifests ───────────────────────────────────────────────────
echo "=== Copying manifests to remote server ==="
"${SSH[@]}" "mkdir -p $REMOTE_DIR"
"${SSH[@]}" "cat > $REMOTE_DIR/traefik-values-psql.yaml" < traefik-values-psql.yaml
"${SSH[@]}" "cat > $REMOTE_DIR/expose.yaml" < expose.yaml

# ─── Step 2: Helm upgrade Traefik (idempotent) ───────────────────────────────
# Only runs if the DaemonSet does not already bind hostPort 5432 for the
# 'postgres' entrypoint.
TRAEFIK_POSTGRES_HOSTPORT=$("${SSH[@]}" \
  "microk8s kubectl get daemonset/traefik -n ingress -o jsonpath='{range .spec.template.spec.containers[0].ports[?(@.name==\"postgres\")]}{.hostPort}{end}' 2>/dev/null || true")

if [ "${TRAEFIK_POSTGRES_HOSTPORT:-}" != "5432" ] || [ -n "${FORCE_TRAEFIK_UPGRADE:-}" ]; then
  echo "=== Upgrading Traefik via Helm to add the 'postgres' entrypoint ==="
  "${SSH[@]}" \
    "microk8s helm upgrade traefik traefik/traefik --version $TRAEFIK_VERSION -n ingress --reuse-values --skip-schema-validation -f $REMOTE_DIR/traefik-values-psql.yaml"

  echo "=== Waiting for Traefik DaemonSet rollout ==="
  "${SSH[@]}" "microk8s kubectl rollout status daemonset/traefik -n ingress --timeout=180s"
else
  echo "=== Traefik already has the 'postgres' entrypoint — skipping Helm upgrade ==="
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
echo "--- Primary instance ---"
microk8s kubectl get pods -n $NAMESPACE -l cnpg.io/cluster=$CLUSTER_NAME,cnpg.io/instanceRole=primary -o wide
REMOTE

echo ""
echo "=== PostgreSQL is now exposed via Traefik ==="
echo "    in-cluster : $CLUSTER_NAME-rw.$NAMESPACE.svc:5432"
echo "    external   : 34.1.25.177:5432 / 34.1.28.21:5432 / 34.1.17.21:5432"
echo "    connect    : PGPASSWORD=\$(./get_app_secret.sh) psql -h 34.1.25.177 -U postgres postgres"
echo "    NOTE: reachable from the internet only while the cloud firewall keeps"
echo "          tcp:5432 open for the node tag (gcnix-ssh on GCE)."
