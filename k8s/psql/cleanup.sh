#!/usr/bin/env bash
set -euo pipefail

# Tears the cluster down: Cluster, PVCs, secret, Traefik TCP route, temp files.
# The 'postgres' Traefik entrypoint added by expose.sh is left in place.

cd "$(dirname "$0")"
. ./common.sh

echo "=== Deleting the Traefik TCP route ==="
remote "microk8s kubectl delete ingressroutetcp postgres-tcp -n $NAMESPACE --ignore-not-found=true"

echo "=== Deleting the PostgreSQL Cluster ==="
remote "microk8s kubectl delete cluster $CLUSTER_NAME -n $NAMESPACE --ignore-not-found=true"

echo "=== Deleting PVCs ==="
remote "microk8s kubectl delete pvc -l cnpg.io/cluster=$CLUSTER_NAME -n $NAMESPACE --ignore-not-found=true"

echo "=== Deleting the secret ==="
remote "microk8s kubectl delete secret app-secret -n $NAMESPACE --ignore-not-found=true"

echo "=== Cleaning up remote files ==="
remote "rm -rf $REMOTE_DIR"
