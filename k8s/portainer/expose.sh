#!/usr/bin/env bash
set -euo pipefail

# Publishes Portainer through Traefik on the cluster LoadBalancer IPs:
#   UI   -> :9000
#   Edge -> :8000

SSH_HOST="root@35.215.39.218"
SSH_KEY="/mnt/c/Users/leo/.ssh/root_id_ed25519"
if [ -f "/root/.ssh/root_id_ed25519" ]; then
  SSH_KEY="/root/.ssh/root_id_ed25519"
fi
PORT=22

REMOTE_DIR="/tmp/k8s-portainer"

# Convert Windows path backslashes to forward slashes for compatibility in git bash/ssh command
SSH_KEY_POSIX=$(echo "$SSH_KEY" | sed 's/\\/\//g')
SSH=(ssh -i "$SSH_KEY_POSIX" -p "$PORT" -o StrictHostKeyChecking=no "$SSH_HOST")

cd "$(dirname "$0")"

# ─── Step 1: Copy manifests ───────────────────────────────────────────────────
echo "=== Copying manifests to remote server ==="
"${SSH[@]}" "mkdir -p $REMOTE_DIR"
"${SSH[@]}" "rm -f $REMOTE_DIR/expose.yaml"
"${SSH[@]}" "cat > $REMOTE_DIR/expose.yaml" < expose.yaml

# ─── Step 2: Add entrypoints to the MicroK8s-managed Traefik DaemonSet ────────
# Traefik is installed by the MicroK8s addon, so do not use Helm here. The
# addon-managed DaemonSet is patched idempotently with the two TCP entrypoints
# and their host ports.
"${SSH[@]}" bash <<'REMOTE'
set -euo pipefail

DS=daemonset/traefik
NS=ingress

add_arg() {
  local arg="$1"
  if ! microk8s kubectl get "$DS" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -Fq -- "$arg"; then
    microk8s kubectl patch "$DS" -n "$NS" --type=json \
      -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"$arg\"}]"
  fi
}

add_port() {
  local name="$1" container_port="$2" host_port="$3"
  if ! microk8s kubectl get "$DS" -n "$NS" \
      -o jsonpath='{.spec.template.spec.containers[0].ports[*].name}' | grep -Fqw "$name"; then
    microk8s kubectl patch "$DS" -n "$NS" --type=json \
      -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/ports/-\",\"value\":{\"name\":\"$name\",\"containerPort\":$container_port,\"hostPort\":$host_port,\"protocol\":\"TCP\"}}]"
  fi
}

add_arg '--entryPoints.portainer.address=:9000/tcp'
add_arg '--entryPoints.portainer-edge.address=:8001/tcp'
add_port portainer 9000 9000
add_port portainer-edge 8001 8000

microk8s kubectl rollout status "$DS" -n "$NS" --timeout=180s
REMOTE

# ─── Step 3: Apply IngressRouteTCP ────────────────────────────────────────────
echo "=== Applying IngressRouteTCP ==="
"${SSH[@]}" "microk8s kubectl apply -f $REMOTE_DIR/expose.yaml"

# ─── Step 4: Verify ───────────────────────────────────────────────────────────
echo ""
echo "=== Verification ==="
"${SSH[@]}" bash <<'REMOTE'
echo "--- Traefik pods ---"
microk8s kubectl get pods -n ingress -o wide
echo ""
echo "--- Traefik entrypoint ports ---"
microk8s kubectl get daemonset traefik -n ingress \
  -o jsonpath='{range .spec.template.spec.containers[0].ports[*]}{.name}:host{.hostPort}->container{.containerPort}  {end}' && echo ""
echo ""
echo "--- IngressRoute / IngressRouteTCP ---"
microk8s kubectl get ingressroute,ingressroutetcp -n portainer
echo ""
echo "--- HTTPS probe via Traefik ---"
curl -sk -o /dev/null -w 'https://portainer.35.215.39.218.nip.io -> %{http_code}\n' https://portainer.35.215.39.218.nip.io/
REMOTE

echo ""
echo "=== Portainer is now exposed via Traefik ==="
echo "    UI (public, 443): https://portainer.35.215.39.218.nip.io"
echo "    UI (node-local) : http://35.215.39.218:9000"
echo "    Edge agents     : 35.215.39.218:8000"
echo "    NOTE: the cloud firewall only allows 443 from outside the cluster;"
echo "          9000/8000 are reachable from the node/VPN only."
