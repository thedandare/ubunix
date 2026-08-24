#!/usr/bin/env bash
# Shared SSH/kubectl helpers for the psql scripts.
# Override with env vars, e.g. SSH_HOST=root@1.2.3.4 ./deploy.sh

SSH_HOST="${SSH_HOST:-root@34.0.220.87}"
SSH_PORT="${SSH_PORT:-22}"
CLUSTER_NAME="${CLUSTER_NAME:-postgres-server}"
NAMESPACE="${NAMESPACE:-default}"
REMOTE_DIR="${REMOTE_DIR:-/tmp2/k8s-psql}"

if [ -z "${SSH_KEY:-}" ]; then
  for candidate in "$HOME/.ssh/root_id_ed25519" /root/.ssh/root_id_ed25519 /mnt/c/Users/leo/.ssh/root_id_ed25519; do
    if [ -f "$candidate" ]; then
      SSH_KEY="$candidate"
      break
    fi
  done
fi
: "${SSH_KEY:?no ssh key found; set SSH_KEY=/path/to/root_id_ed25519}"

SSH_OPTS=(-i "$SSH_KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=15)

remote() {
  ssh "${SSH_OPTS[@]}" "$SSH_HOST" "$@"
}

copy() {
  for f in "$@"; do
    remote "rm -f \"$REMOTE_DIR/$(basename "$f")\" 2>/dev/null" || true
  done
  scp -i "$SSH_KEY" -P "$SSH_PORT" -o StrictHostKeyChecking=no "$@" "$SSH_HOST:$REMOTE_DIR/"
}
