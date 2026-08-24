#!/usr/bin/env bash
# reset-cluster.sh — Destroys and recreates the 3-node MicroK8s cluster
# from scratch. After running, deploy postgres with ./k8s/psql/fix-psql.sh
# and expose it with ./k8s/psql/expose.sh.
#
# Node map:
#   gcnix-0 (PRIMARY) : 34.0.220.87  (us-east5-a)
#   gcnix-1 (WORKER)  : 34.0.220.87   (us-east5-b)
#   gcnix-2 (WORKER)  : 34.1.17.21   (us-east5-c)
set -uo pipefail

SSH_KEY="${HOME}/.ssh/root_id_ed25519"
if [ ! -f "$SSH_KEY" ]; then
  SSH_KEY="/mnt/c/Users/leo/.ssh/root_id_ed25519"
fi

PRIMARY="root@34.0.220.87"
WORKER1="root@34.0.220.87"
# gcnix-2 uses gcloud ssh since root key may not be authorized there
GCNIX2_ZONE="us-east5-c"
PROJECT="project-1ab07399-29ab-4352-8f8"

SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=15"

run_primary()   { $SSH "$PRIMARY" "$@"; }
run_worker1()   { $SSH "$WORKER1" "$@"; }
run_worker2()   { gcloud compute ssh gcnix2 --zone "$GCNIX2_ZONE" --project "$PROJECT" --command "$*" --quiet; }

# ─────────────────────────────────────────────
echo "╔══════════════════════════════════════╗"
echo "║  PHASE 1 — LEAVE + RESET ALL NODES  ║"
echo "╚══════════════════════════════════════╝"

echo "--- gcnix-1: leaving cluster ---"
run_worker1 "microk8s leave 2>&1 || true"

echo "--- gcnix-2: leaving cluster (via gcloud) ---"
run_worker2 "sudo microk8s leave 2>&1 || true"

echo "Waiting 20s for primary to see nodes gone..."
sleep 20

echo "--- gcnix-0: resetting primary ---"
run_primary "microk8s reset --destroy-storage 2>&1 || true"
echo "Waiting 30s for microk8s to recover on gcnix-0..."
sleep 30

echo "--- gcnix-1: resetting worker ---"
run_worker1 "microk8s reset --destroy-storage 2>&1 || true"

echo "--- gcnix-2: resetting worker (via gcloud) ---"
run_worker2 "sudo microk8s reset --destroy-storage 2>&1 || true"

# ─────────────────────────────────────────────
echo "╔══════════════════════════════════════╗"
echo "║  PHASE 2 — SETUP PRIMARY (gcnix-0)   ║"
echo "╚══════════════════════════════════════╝"

run_primary "microk8s status --wait-ready --timeout 120"

echo "--- Enabling core addons ---"
run_primary "microk8s enable dns hostpath-storage helm3 cloudnative-pg"
echo "Waiting 30s for addons to settle..."
sleep 30

echo "--- Adding Traefik Helm repo ---"
run_primary "microk8s helm3 repo add traefik https://helm.traefik.io/traefik 2>/dev/null || true && microk8s helm3 repo update"

echo "--- Installing Traefik as DaemonSet in namespace 'ingress' ---"
run_primary "microk8s kubectl create namespace ingress --dry-run=client -o yaml | microk8s kubectl apply -f -"
run_primary "microk8s helm3 upgrade --install traefik traefik/traefik \
  --version 39.0.8 \
  --namespace ingress \
  --skip-schema-validation \
  --atomic=false \
  --set deployment.kind=DaemonSet \
  --set service.type=LoadBalancer \
  --set 'service.externalIPs={34.0.220.87,34.0.220.87,34.1.17.21}' \
  --set ports.web.hostPort=80 \
  --set ports.websecure.hostPort=443 \
  --set providers.kubernetesCRD.enabled=true \
  --set providers.kubernetesCRD.allowEmptyServices=true \
  --set providers.kubernetesIngress.enabled=true \
  --set ingressClass.enabled=true \
  --set ingressClass.isDefaultClass=true 2>&1"
echo "Waiting 30s for Traefik pods to start..."
sleep 30
run_primary "microk8s kubectl get pods -n ingress 2>&1 || true"


# ─────────────────────────────────────────────
echo "╔══════════════════════════════════════╗"
echo "║  PHASE 3 — JOIN WORKER NODES         ║"
echo "╚══════════════════════════════════════╝"

echo "--- Generating join tokens ---"
TOKEN1=$(run_primary "microk8s add-node --format short 2>/dev/null | head -1")
echo "Token for gcnix-1: $TOKEN1"
sleep 2
TOKEN2=$(run_primary "microk8s add-node --format short 2>/dev/null | head -1")
echo "Token for gcnix-2: $TOKEN2"

echo "--- Joining gcnix-1 ---"
run_worker1 "microk8s join $TOKEN1 " || true
sleep 10

echo "--- Joining gcnix-2 (via gcloud) ---"
run_worker2 "sudo microk8s join $TOKEN2 " || true
sleep 15

# ─────────────────────────────────────────────
echo "╔══════════════════════════════════════╗"
echo "║  PHASE 4 — VERIFY CLUSTER            ║"
echo "╚══════════════════════════════════════╝"

echo "Waiting 20s for nodes to join..."
sleep 20
run_primary "microk8s kubectl get nodes -o wide"
run_primary "microk8s kubectl get pods -A --field-selector=status.phase!=Running 2>/dev/null | head -20 || true"

echo ""
echo "✅ Cluster reset complete! Next steps:"
echo "   1. cd k8s/psql && ./fix-psql.sh      # redeploy postgres"
echo "   2. cd k8s/psql && ./expose.sh         # expose postgres via Traefik"
echo "   3. cd k8s/dns  && ./deploy.sh         # redeploy external-dns"
