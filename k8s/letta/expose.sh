#!/usr/bin/env bash
set -euo pipefail

SSH_HOST="${SSH_HOST:-root@35.215.33.107}"
SSH_KEY="${SSH_KEY:-/mnt/c/Users/leo/.ssh/root_id_ed25519}"
REMOTE_DIR="${REMOTE_DIR:-/tmp/k8s-letta}"

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

echo "=== Copying Letta ingress manifest to $SSH_HOST ==="
"${SSH[@]}" "mkdir -p '$REMOTE_DIR'"
"${SCP[@]}" expose.yaml "$SSH_HOST:$REMOTE_DIR/expose.yaml"

echo "=== Applying Letta Traefik route ==="
"${SSH[@]}" "microk8s kubectl apply -f '$REMOTE_DIR/expose.yaml'"

echo "=== Verifying Letta route ==="
"${SSH[@]}" "microk8s kubectl get ingressroute -n letta; microk8s kubectl get service,endpoints -n letta -o wide"

echo "=== Letta is exposed ==="
echo "    URL: https://letta.35.215.33.107.nip.io"
