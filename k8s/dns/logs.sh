#!/usr/bin/env bash
set -euo pipefail

SSH_HOST="root@192.168.0.178"
SSH_KEY="/mnt/c/Users/leo/.ssh/root_id_ed25519"

# Convert Windows path backslashes to forward slashes for compatibility in git bash/ssh command
SSH_KEY_POSIX=$(echo "$SSH_KEY" | sed 's/\\/\//g')

echo "=== LOGS from external-dns ==="
ssh -i "$SSH_KEY_POSIX" -o StrictHostKeyChecking=no "$SSH_HOST" "microk8s kubectl logs -l app=external-dns -n default --tail=20"