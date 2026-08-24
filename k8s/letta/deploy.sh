#!/usr/bin/env bash
set -euo pipefail

LOCAL_IMAGE="${LOCAL_IMAGE:-letta-app-server:local}"
IMAGE="${IMAGE:-thedandare/fibo-letta-server:v1.0.0}"
SSH_HOST="${SSH_HOST:-root@35.215.33.107}"
SSH_KEY="${SSH_KEY:-/mnt/c/Users/leo/.ssh/root_id_ed25519}"
REMOTE_MANIFEST="${REMOTE_MANIFEST:-/tmp/letta-deployment.yaml}"

if [ ! -f "$SSH_KEY" ] && [ -f "/c/Users/leo/.ssh/root_id_ed25519" ]; then
  SSH_KEY="/c/Users/leo/.ssh/root_id_ed25519"
fi

if [ ! -f "$SSH_KEY" ]; then
  echo "SSH key not found: $SSH_KEY" >&2
  exit 1
fi

SSH=(ssh -o PubkeyAcceptedKeyTypes=+ssh-ed25519 -i "$SSH_KEY" "$SSH_HOST")
SCP=(scp -o PubkeyAcceptedKeyTypes=+ssh-ed25519 -i "$SSH_KEY")

cd "$(dirname "$0")"

echo "=== Building $LOCAL_IMAGE ==="
docker build --tag "$LOCAL_IMAGE" .

echo "=== Tagging $IMAGE ==="
docker tag "$LOCAL_IMAGE" "$IMAGE"
echo "=== Pushing $IMAGE ==="
docker push "$IMAGE"

echo "=== Copying Kubernetes manifest ==="
"${SCP[@]}" deployment.yaml "$SSH_HOST:$REMOTE_MANIFEST"

echo "=== Creating namespace and token Secret if needed ==="
"${SSH[@]}" 'set -eu
microk8s kubectl create namespace letta --dry-run=client -o yaml | microk8s kubectl apply -f -
if ! microk8s kubectl -n letta get secret letta-app-server >/dev/null 2>&1; then
  token=$(openssl rand -hex 32)
  microk8s kubectl -n letta create secret generic letta-app-server --from-literal=token="$token" >/dev/null
  echo "Created Secret letta-app-server with a generated token"
else
  echo "Secret letta-app-server already exists; keeping the existing token"
fi
microk8s kubectl apply -f "$REMOTE_MANIFEST"
'

echo "=== Waiting for rollout ==="
if "${SSH[@]}" "microk8s kubectl -n letta rollout status deployment/letta-app-server --timeout=10m"; then
  "${SSH[@]}" "microk8s kubectl -n letta get pods,svc,pvc -o wide"
else
  echo "=== Deployment diagnostics ===" >&2
  "${SSH[@]}" "microk8s kubectl -n letta get pods,svc,pvc -o wide; microk8s kubectl -n letta get events --sort-by=.lastTimestamp | tail -30" >&2 || true
  exit 1
fi
