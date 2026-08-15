#!/usr/bin/env bash
set -euo pipefail

# Check for at least one IP address
if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <server_ip_1> [server_ip_2 ...]"
  exit 1
fi

# SSH key: prefer Windows OpenSSH-compatible path (avoids libcrypto issues in Git Bash)
# Detect if running under Git Bash (MSYSTEM set) or plain WSL/Linux
if [ -n "${MSYSTEM:-}" ]; then
  # Git Bash on Windows — use the Windows path directly so native Windows ssh.exe is picked up
  SSH_KEY="C:/Users/leo/.ssh/root_id_ed25519"
  SSH_CMD="/c/Windows/System32/OpenSSH/ssh.exe"
  if [ ! -f "$SSH_CMD" ]; then
    SSH_CMD="ssh"
  fi
elif [ -f "/mnt/c/Users/leo/.ssh/root_id_ed25519" ]; then
  SSH_KEY="/mnt/c/Users/leo/.ssh/root_id_ed25519"
  SSH_CMD="ssh"
else
  SSH_KEY="$HOME/.ssh/root_id_ed25519"
  SSH_CMD="ssh"
fi

PORT=22

# Locate local directory of the script
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for IP in "$@"; do
  SSH_HOST="root@$IP"
  echo "========================================================="
  echo " Deploying Redis to $SSH_HOST"
  echo "========================================================="

  echo "=== Copying values and manifests to remote server ==="
  "$SSH_CMD" -i "$SSH_KEY" -p $PORT -o StrictHostKeyChecking=no "$SSH_HOST" "mkdir -p /tmp/k8s-redis"
  "$SSH_CMD" -i "$SSH_KEY" -p $PORT -o StrictHostKeyChecking=no "$SSH_HOST" "cat > /tmp/k8s-redis/values-redis-chart.yaml" < "$DIR/values-redis-chart.yaml"

  echo "=== Deploying Redis Chart via Helm ==="
  # Upgrade or install using OCI chart from Artifact Hub
  "$SSH_CMD" -i "$SSH_KEY" -p $PORT -o StrictHostKeyChecking=no "$SSH_HOST" \
    "microk8s helm upgrade --install redis oci://registry-1.docker.io/truebyteinnovation/redis-chart \
      --namespace redis --create-namespace \
      -f /tmp/k8s-redis/values-redis-chart.yaml"

  echo "=== Waiting for Redis StatefulSet to be ready ==="
  "$SSH_CMD" -i "$SSH_KEY" -p $PORT -o StrictHostKeyChecking=no "$SSH_HOST" \
    "microk8s kubectl rollout status statefulset/redis -n redis --timeout=600s"

  echo "=== Redis Status ==="
  "$SSH_CMD" -i "$SSH_KEY" -p $PORT -o StrictHostKeyChecking=no "$SSH_HOST" \
    "microk8s kubectl get pods -n redis -o wide"

  echo ""
  echo "=== Retrieve auto-generated password ==="
  "$SSH_CMD" -i "$SSH_KEY" -p $PORT -o StrictHostKeyChecking=no "$SSH_HOST" \
    "microk8s kubectl get secret -n redis redis -o jsonpath='{.data.redis-password}' | base64 -d && echo"
done
