#!/usr/bin/env bash
set -euo pipefail

# Check for at least one IP address
if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <server_ip_1> [server_ip_2 ...]"
  exit 1
fi

# SSH key: prefer Windows OpenSSH-compatible path (avoids libcrypto issues in Git Bash)
# Detect if running under Git Bash (MSYSTEM set) or plain WSL/Linux
# if [ -n "${MSYSTEM:-}" ]; then
#   # Git Bash on Windows — use the Windows path directly so native Windows ssh.exe is picked up
#   SSH_KEY="C:/Users/leo/.ssh/root_id_ed25519"
#   SSH_CMD="/c/Windows/System32/OpenSSH/ssh.exe"
#   if [ ! -f "$SSH_CMD" ]; then
#     SSH_CMD="ssh"
#   fi
# el
if [ -f "/root/.ssh/root_id_ed25519" ]; then
  SSH_KEY="/root/.ssh/root_id_ed25519"
  SSH_CMD="ssh"
else
  exit 1
fi
# Convert Windows path backslashes to forward slashes for compatibility in git bash/ssh command
SSH_KEY_POSIX=$(echo "$SSH_KEY" | sed 's/\\/\//g')

PORT=22

# Locate local directory of the script
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for IP in "$@"; do
  SSH_HOST="root@$IP"
  echo "========================================================="
  echo " Deploying headlamp to $SSH_HOST"
  echo "========================================================="

  echo "=== Copying values and manifests to remote server ==="
  "$SSH_CMD" -i "$SSH_KEY_POSIX" -p $PORT -o StrictHostKeyChecking=no "$SSH_HOST" "mkdir -p /tmp/k8s-headlamp"
  "$SSH_CMD" -i "$SSH_KEY_POSIX" -p $PORT -o StrictHostKeyChecking=no "$SSH_HOST" "cat > /tmp/k8s-headlamp/headlamp-token.yaml" < "$DIR/headlamp-token.yaml"

  echo "=== Deploying headlamp permanent token  ==="
  # Upgrade or install using OCI chart from Artifact Hub
  "$SSH_CMD" -i "$SSH_KEY_POSIX" -p $PORT -o StrictHostKeyChecking=no "$SSH_HOST" \
    "microk8s kubectl apply -f /tmp/k8s-headlamp/headlamp-token.yaml"

  "$SSH_CMD" -i "$SSH_KEY_POSIX" -p $PORT -o StrictHostKeyChecking=no "$SSH_HOST" \
    "microk8s kubectl -n kube-system get secret headlamp-admin-token -o jsonpath='{.data.token}' | base64 --decode"
done
