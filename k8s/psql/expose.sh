#!/usr/bin/env bash
set -euo pipefail

# Publishes the CloudNativePG primary through Traefik on the cluster
# LoadBalancer IPs:
#   PostgreSQL -> :5432

cd "$(dirname "$0")"
. ./common.sh

TRAEFIK_VERSION="${TRAEFIK_VERSION:-39.0.8}"

# ─── Step 1: Copy manifests ───────────────────────────────────────────────────
echo "=== Copying manifests to remote server ==="
remote "mkdir -p $REMOTE_DIR"
copy traefik-values-psql.yaml expose.yaml

# ─── Step 2: Helm upgrade Traefik (idempotent) ───────────────────────────────
# Only runs if the 'postgres' entrypoint is not already in the DaemonSet args.
TRAEFIK_HAS_POSTGRES=$(remote \
  "microk8s kubectl get daemonset/traefik -n ingress -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null | grep -c entryPoints.postgres.address || true")

if [ "${TRAEFIK_HAS_POSTGRES:-0}" -eq 0 ] || [ -n "${FORCE_TRAEFIK_UPGRADE:-}" ]; then
  echo "=== Upgrading Traefik via Helm to add the 'postgres' entrypoint ==="
  remote \
    "microk8s helm upgrade traefik traefik/traefik --version $TRAEFIK_VERSION -n ingress --reuse-values --skip-schema-validation -f $REMOTE_DIR/traefik-values-psql.yaml"

  echo "=== Waiting for Traefik DaemonSet rollout ==="
  remote "microk8s kubectl rollout status daemonset/traefik -n ingress --timeout=180s"
else
  echo "=== Traefik already has the 'postgres' entrypoint — skipping Helm upgrade ==="
fi

# ─── Step 3: Apply IngressRouteTCP ────────────────────────────────────────────
echo "=== Applying IngressRouteTCP ==="
remote "microk8s kubectl apply -f $REMOTE_DIR/expose.yaml"

# ─── Step 4: Verify ───────────────────────────────────────────────────────────
echo ""
echo "=== Verification ==="
remote bash <<REMOTE
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
echo "    NOTE: the cloud firewall only allows 443 from outside the cluster;"
echo "          5432 is reachable from the node/VPN only."
