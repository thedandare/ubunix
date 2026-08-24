#!/usr/bin/env bash
set -euo pipefail

# Prints the Redis password stored in the chart's secret.

SSH_HOST="${SSH_HOST:-root@35.215.39.218}"
SSH_KEY="${SSH_KEY:-/mnt/c/Users/leo/.ssh/root_id_ed25519}"
if [ -f "$HOME/.ssh/root_id_ed25519" ]; then
  SSH_KEY="$HOME/.ssh/root_id_ed25519"
fi
PORT="${SSH_PORT:-22}"
NAMESPACE="${NAMESPACE:-redis}"

SSH_KEY_POSIX=$(echo "$SSH_KEY" | sed 's/\\/\//g')

ssh -i "$SSH_KEY_POSIX" -p "$PORT" -o StrictHostKeyChecking=no "$SSH_HOST" \
  "microk8s kubectl get secret redis -n $NAMESPACE -o jsonpath='{.data.redis-password}' | base64 -d"
echo
