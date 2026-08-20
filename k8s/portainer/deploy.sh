#!/usr/bin/env bash
set -euo pipefail

# Installs/upgrades Portainer CE on the remote MicroK8s cluster via 'microk8s helm'.
# Chart: https://artifacthub.io/packages/helm/portainer/portainer

SSH_HOST="root@34.0.220.87"
SSH_KEY="/mnt/c/Users/leo/.ssh/root_id_ed25519"
if [ -f "$HOME/.ssh/root_id_ed25519" ]; then
  SSH_KEY="$HOME/.ssh/root_id_ed25519"
fi
PORT=22

NAMESPACE="portainer"
RELEASE="portainer"
CHART_REPO="https://portainer.github.io/k8s/"
CHART_VERSION="${CHART_VERSION:-}"
REMOTE_DIR="/tmp/k8s-portainer"

# Convert Windows path backslashes to forward slashes for compatibility in git bash/ssh command
SSH_KEY_POSIX=$(echo "$SSH_KEY" | sed 's/\\/\//g')
SSH=(ssh -i "$SSH_KEY_POSIX" -p "$PORT" -o StrictHostKeyChecking=no "$SSH_HOST")

cd "$(dirname "$0")"

# ─── Step 1: Copy values ──────────────────────────────────────────────────────
echo "=== Copying values-portainer.yaml to remote server ==="
"${SSH[@]}" "mkdir -p $REMOTE_DIR"
scp -i "$SSH_KEY_POSIX" -P "$PORT" -o StrictHostKeyChecking=no \
  values-portainer.yaml "$SSH_HOST:$REMOTE_DIR/values-portainer.yaml"

# ─── Step 2: Helm repo ────────────────────────────────────────────────────────
echo "=== Adding/updating the portainer Helm repo ==="
"${SSH[@]}" "microk8s helm repo add portainer $CHART_REPO >/dev/null && microk8s helm repo update portainer"

# ─── Step 3: Install / upgrade ────────────────────────────────────────────────
echo "=== helm upgrade --install $RELEASE (namespace: $NAMESPACE) ==="
VERSION_ARG=""
[ -n "$CHART_VERSION" ] && VERSION_ARG="--version $CHART_VERSION"
"${SSH[@]}" "microk8s helm upgrade --install $RELEASE portainer/portainer $VERSION_ARG \
  --namespace $NAMESPACE --create-namespace \
  -f $REMOTE_DIR/values-portainer.yaml \
  --wait --timeout 10m"

# ─── Step 4: Verify ───────────────────────────────────────────────────────────
echo ""
echo "=== Verification ==="
"${SSH[@]}" bash <<REMOTE
echo "--- release ---"
microk8s helm list -n $NAMESPACE
echo ""
echo "--- pods ---"
microk8s kubectl get pods -n $NAMESPACE -o wide
echo ""
echo "--- service ---"
microk8s kubectl get svc -n $NAMESPACE
echo ""
echo "--- pvc ---"
microk8s kubectl get pvc -n $NAMESPACE
REMOTE

echo ""
echo "=== Portainer deployed ==="
echo "    NodePort HTTP : http://34.1.28.21:30777"
echo "    NodePort HTTPS: https://34.1.28.21:30779"
echo "    Run ./expose.sh to publish it through Traefik as well."
echo ""
echo "    Creating the first admin account requires the setup token printed in the pod"
echo "    logs (it changes on every pod restart):"
echo "      ssh $SSH_HOST 'microk8s kubectl logs -n $NAMESPACE deploy/portainer | grep setup_token'"
