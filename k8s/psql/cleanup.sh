#!/usr/bin/env bash
set -euo pipefail

# Tears the cluster down: Cluster, PVCs, secret, NodePort Service, temp files.

cd "$(dirname "$0")"
. ./common.sh

echo "=== Deleting the NodePort Service ==="
remote "microk8s kubectl delete -f $REMOTE_DIR/expose.yaml --ignore-not-found=true 2>/dev/null \
  || microk8s kubectl delete svc postgres-server-ext -n $NAMESPACE --ignore-not-found=true"

echo "=== Deleting the PostgreSQL Cluster ==="
remote "microk8s kubectl delete cluster $CLUSTER_NAME -n $NAMESPACE --ignore-not-found=true"

echo "=== Deleting PVCs ==="
remote "microk8s kubectl delete pvc -l cnpg.io/cluster=$CLUSTER_NAME -n $NAMESPACE --ignore-not-found=true"

echo "=== Deleting the secret ==="
remote "microk8s kubectl delete secret app-secret -n $NAMESPACE --ignore-not-found=true"

echo "=== Cleaning up remote files ==="
remote "rm -rf $REMOTE_DIR"
