#!/usr/bin/env bash
set -euo pipefail

# Removes the Portainer Helm release and its namespaced resources.
# PVCs are preserved unless DELETE_PVC=true is set.

SSH_HOST="${SSH_HOST:-root@34.0.48.251}"
SSH_KEY="${SSH_KEY:-/mnt/c/Users/leo/.ssh/root_id_ed25519}"
if [ -f "$HOME/.ssh/root_id_ed25519" ]; then
  SSH_KEY="$HOME/.ssh/root_id_ed25519"
fi
PORT="${SSH_PORT:-22}"

NAMESPACE="${NAMESPACE:-portainer}"
RELEASE="${RELEASE:-portainer}"
DELETE_PVC="${DELETE_PVC:-false}"

SSH_KEY_POSIX=$(echo "$SSH_KEY" | sed 's/\\/\//g')
SSH=(ssh -i "$SSH_KEY_POSIX" -p "$PORT" -o StrictHostKeyChecking=no "$SSH_HOST")

echo "=== Removing Portainer release '$RELEASE' from namespace '$NAMESPACE' ==="
"${SSH[@]}" bash -s -- "$NAMESPACE" "$RELEASE" "$DELETE_PVC" <<'REMOTE'
set -euo pipefail

NAMESPACE="$1"
RELEASE="$2"
DELETE_PVC="$3"

if microk8s helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
  microk8s helm uninstall "$RELEASE" -n "$NAMESPACE"
else
  echo "Helm release '$RELEASE' is not installed; continuing"
fi

# Remove exposure routes managed outside the Helm chart.
microk8s kubectl delete ingressroute,ingressroutetcp \
  -n "$NAMESPACE" --all --ignore-not-found

# Clean up resources left by a failed or interrupted Helm install.
microk8s kubectl delete all,configmap,secret,serviceaccount,role,rolebinding \
  -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE" \
  --ignore-not-found
microk8s kubectl delete clusterrolebinding "$RELEASE" --ignore-not-found
microk8s kubectl delete serviceaccount portainer-sa-clusteradmin \
  -n "$NAMESPACE" --ignore-not-found

if [ "$DELETE_PVC" = true ]; then
  microk8s kubectl delete pvc -n "$NAMESPACE" --all --ignore-not-found
else
  echo "PVCs preserved (set DELETE_PVC=true to delete them)"
fi
REMOTE

echo "=== Portainer cleanup complete ==="
