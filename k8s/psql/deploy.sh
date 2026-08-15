#!/usr/bin/env bash
set -euo pipefail

# Deploys the CloudNativePG cluster on the microk8s node.
# The operator comes from the microk8s community addon:
#     microk8s enable cloudnative-pg
# Nothing here uses Helm.
#
# The postgres password is NEVER committed: pass it in PG_PASSWORD, otherwise a
# random one is generated on first deploy and kept (the secret is only created
# when it does not exist yet).

cd "$(dirname "$0")"
. ./common.sh

echo "=== Checking the CloudNativePG operator ==="
if ! remote "microk8s kubectl get deploy cnpg-controller-manager -n cnpg-system" >/dev/null 2>&1; then
  echo "operator missing, enabling the addon..."
  remote "microk8s enable cloudnative-pg"
fi
# NOTE: no `kubectl wait`/`rollout status` anywhere in this script — they rely on
# watches, which currently hang on this cluster; everything below polls instead.
wait_for() { # wait_for <description> <timeout-seconds> <remote jsonpath query> <expected>
  local what=$1 max=$2 query=$3 want=$4 waited=0 got=
  while [ "$waited" -lt "$max" ]; do
    got=$(remote "$query" 2>/dev/null || true)
    [ "$got" = "$want" ] && { echo "$what: ok"; return 0; }
    echo "waiting for $what... (${waited}s/${max}s, current: '${got:-none}')"
    sleep 10
    waited=$((waited + 10))
  done
  echo "WARNING: timed out waiting for $what"
  return 1
}

wait_for "operator ready" 180 \
  "microk8s kubectl get deploy cnpg-controller-manager -n cnpg-system -o jsonpath='{.status.readyReplicas}'" 1

echo "=== Creating the app-secret (kubernetes.io/basic-auth, required by CNPG) ==="
PG_PASSWORD="${PG_PASSWORD:-$(openssl rand -base64 32 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)}"
# An Opaque secret is silently ignored by CNPG (every login then fails with
# "password authentication failed"), so a wrongly typed one is recreated.
remote "
set -e
type=\$(microk8s kubectl get secret app-secret -n $NAMESPACE -o jsonpath='{.type}' 2>/dev/null || true)
if [ \"\$type\" = 'kubernetes.io/basic-auth' ]; then
  echo 'app-secret already present'
else
  if [ -n \"\$type\" ]; then microk8s kubectl delete secret app-secret -n $NAMESPACE; fi
  microk8s kubectl create secret generic app-secret -n $NAMESPACE \
    --type=kubernetes.io/basic-auth \
    --from-literal=username=postgres \
    --from-literal=password='$PG_PASSWORD'
fi"

echo "=== Copying manifests to remote server ==="
remote "mkdir -p $REMOTE_DIR"
copy psql-server.yaml

echo "=== Deploying PostgreSQL Cluster ==="
remote "microk8s kubectl apply -f $REMOTE_DIR/psql-server.yaml"

echo "=== Waiting for the cluster to be ready (max 10 min) ==="
wait_for "cluster $CLUSTER_NAME" 600 \
  "microk8s kubectl get cluster $CLUSTER_NAME -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" True \
  || echo "cluster not Ready yet — see the status below"

echo "=== PostgreSQL Cluster Status ==="
remote "
microk8s kubectl get cluster $CLUSTER_NAME -n $NAMESPACE
echo ''
microk8s kubectl get pods,pvc -n $NAMESPACE -l cnpg.io/cluster=$CLUSTER_NAME -o wide
echo ''
microk8s kubectl get svc -n $NAMESPACE -l cnpg.io/cluster=$CLUSTER_NAME
"

echo ""
echo "Password: ./get_app_secret.sh   (run ./expose.sh to reach it from outside)"
