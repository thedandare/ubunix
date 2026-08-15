#!/usr/bin/env bash
set -euo pipefail

SSH_HOST="root@34.1.28.21"
SSH_KEY="C:\Users\leo\.ssh\root_id_ed25519"
if [ -f "$HOME/.ssh/root_id_ed25519" ]; then
  SSH_KEY="$HOME/.ssh/root_id_ed25519"
fi
PORT=2409

# Convert Windows path backslashes to forward slashes for compatibility in git bash/ssh command
SSH_KEY_POSIX=$(echo "$SSH_KEY" | sed 's/\\/\//g')

echo "=== Deleting Nginx Service and Deployment ==="
ssh -i "$SSH_KEY_POSIX"  -p $PORT  -o StrictHostKeyChecking=no  "$SSH_HOST" "microk8s kubectl delete -f /tmp/k8s-dns/nginx.yaml --ignore-not-found=true"

echo "=== Deleting ExternalDNS ==="
ssh -i "$SSH_KEY_POSIX"  -p $PORT  -o StrictHostKeyChecking=no  "$SSH_HOST" "microk8s kubectl delete -f /tmp/k8s-dns/external-dns-simple.yaml --ignore-not-found=true"

echo "=== Cleaning up remote files ==="
ssh -i "$SSH_KEY_POSIX"  -p $PORT  -o StrictHostKeyChecking=no  "$SSH_HOST" "rm -rf /tmp/k8s-dns"

