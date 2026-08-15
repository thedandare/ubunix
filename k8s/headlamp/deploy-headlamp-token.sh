#!/usr/bin/env bash
set -euo pipefail

# Creates the never-expiring token of the headlamp-admin ServiceAccount and
# prints it, so it can be pasted into the Headlamp login screen.
#
#     ./deploy-headlamp-token.sh <server_ip_1> [server_ip_2 ...]

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <server_ip_1> [server_ip_2 ...]"
  exit 1
fi

if [ -z "${SSH_KEY:-}" ]; then
  for candidate in "$HOME/.ssh/root_id_ed25519" /root/.ssh/root_id_ed25519 /mnt/c/Users/leo/.ssh/root_id_ed25519; do
    if [ -f "$candidate" ]; then
      SSH_KEY="$candidate"
      break
    fi
  done
fi
: "${SSH_KEY:?no ssh key found; set SSH_KEY=/path/to/root_id_ed25519}"

SSH_PORT="${SSH_PORT:-22}"
NAMESPACE="${NAMESPACE:-kube-system}"
REMOTE_DIR="${REMOTE_DIR:-/tmp/k8s-headlamp}"
SSH_OPTS=(-i "$SSH_KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=15)

cd "$(dirname "$0")"

for IP in "$@"; do
  SSH_HOST="root@$IP"
  remote() { ssh "${SSH_OPTS[@]}" "$SSH_HOST" "$@"; }

  echo "========================================================="
  echo " Deploying the headlamp token to $SSH_HOST"
  echo "========================================================="

  # No ServiceAccount means the token controller has nothing to issue a token
  # for, and the secret below then stays empty forever.
  echo "=== Checking the headlamp-admin ServiceAccount ==="
  remote "
set -e
microk8s kubectl -n $NAMESPACE get serviceaccount headlamp-admin >/dev/null 2>&1 \
  || microk8s kubectl -n $NAMESPACE create serviceaccount headlamp-admin
microk8s kubectl get clusterrolebinding headlamp-admin >/dev/null 2>&1 \
  || microk8s kubectl create clusterrolebinding headlamp-admin \
       --serviceaccount=$NAMESPACE:headlamp-admin --clusterrole=cluster-admin"

  echo "=== Copying manifests to remote server ==="
  remote "mkdir -p $REMOTE_DIR"
  scp -i "$SSH_KEY" -P "$SSH_PORT" -o StrictHostKeyChecking=no \
    headlamp-token.yaml "$SSH_HOST:$REMOTE_DIR/"

  echo "=== Deploying the headlamp permanent token ==="
  remote "microk8s kubectl apply -f $REMOTE_DIR/headlamp-token.yaml"

  # The token controller fills in .data.token asynchronously, so the secret can
  # exist for a moment without one.
  echo "=== Waiting for the token to be issued ==="
  TOKEN=
  for _ in $(seq 1 30); do
    TOKEN=$(remote "microk8s kubectl -n $NAMESPACE get secret headlamp-admin-token -o jsonpath='{.data.token}'" 2>/dev/null || true)
    [ -n "$TOKEN" ] && break
    sleep 2
  done
  if [ -z "$TOKEN" ]; then
    echo "ERROR: the token controller did not populate headlamp-admin-token" >&2
    exit 1
  fi

  echo "=== Headlamp token for $IP ==="
  echo "$TOKEN" | base64 --decode
  echo
done
