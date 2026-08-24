#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# Enable HTTPS (Let's Encrypt) for specific subdomains of an Ingress.
# ------------------------------------------------------------------
# Usage examples:
#   # Use all existing hosts in the ingress
#   ./create_certs_for_subdomains.sh serverpod-ingress stream-server
#
#   # Use only specific subdomains
#   ./create_certs_for_subdomains.sh nginx-ingress default gcm.6nix.pl
#
#   # Multiple subdomains
#   ./create_certs_for_subdomains.sh serverpod-ingress stream-server \
#       api.sp.gcm.6nix.pl web.sp.gcm.6nix.pl insights.sp.gcm.6nix.pl
# ------------------------------------------------------------------

# SSH / cluster settings
SSH_HOST="root@35.215.39.218"
SSH_KEY="/mnt/c/Users/leo/.ssh/root_id_ed25519"
if [ -f "/root/.ssh/root_id_ed25519" ]; then
  SSH_KEY="/root/.ssh/root_id_ed25519"
fi
PORT=22
SSH_KEY_POSIX=$(echo "$SSH_KEY" | sed 's/\\/\//g')

usage() {
  echo "Usage: $0 <ingress-name> <namespace> [host1 host2 ...]"
  echo ""
  echo "If no hosts are provided, all existing hosts from the ingress are used."
  echo ""
  echo "Examples:"
  echo "  $0 nginx-ingress default gcm.6nix.pl"
  echo "  $0 serverpod-ingress stream-server api.sp.gcm.6nix.pl web.sp.gcm.6nix.pl"
  exit 1
}

if [ $# -lt 2 ]; then
  usage
fi

INGRESS_NAME="$1"
NAMESPACE="$2"
shift 2
HOSTS=("$@")

SSH_CMD="ssh -i $SSH_KEY_POSIX -p $PORT -o StrictHostKeyChecking=no $SSH_HOST"
KUBECTL="microk8s kubectl"

# If no hosts were provided, fetch them from the existing ingress.
if [ ${#HOSTS[@]} -eq 0 ]; then
  echo "=== Reading existing hosts from $INGRESS_NAME/$NAMESPACE ==="
  mapfile -t HOSTS < <($SSH_CMD "$KUBECTL get ingress $INGRESS_NAME -n $NAMESPACE -o jsonpath='{range .spec.rules[*]}{.host}{\\\"\\n\\\"}{end}'")

  if [ ${#HOSTS[@]} -eq 0 ]; then
    echo "ERROR: No hosts found in ingress $INGRESS_NAME/$NAMESPACE"
    exit 1
  fi
fi

echo "=== Enabling HTTPS for hosts: ${HOSTS[*]} ==="

SECRET_NAME="${INGRESS_NAME}-tls"

# Build the TLS hosts list for the patch YAML.
TLS_HOSTS=""
for host in "${HOSTS[@]}"; do
  TLS_HOSTS="${TLS_HOSTS}        - ${host}"$'\n'
done

PATCH_FILE=$(mktemp)
cat > "$PATCH_FILE" <<EOF
metadata:
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: "web,websecure"
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.tls.certresolver: "le"
spec:
  tls:
    - hosts:
$TLS_HOSTS      secretName: $SECRET_NAME
EOF

REMOTE_PATCH="/tmp/${INGRESS_NAME}-tls-patch.yaml"

echo "=== Copying patch to remote server ==="
$SSH_CMD "cat > $REMOTE_PATCH" < "$PATCH_FILE"

rm -f "$PATCH_FILE"

echo "=== Patching ingress $INGRESS_NAME/$NAMESPACE ==="
$SSH_CMD "$KUBECTL patch ingress $INGRESS_NAME -n $NAMESPACE --type=merge --patch-file $REMOTE_PATCH"

$SSH_CMD "rm -f $REMOTE_PATCH"

echo "=== Waiting for certificate (up to 5 minutes) ==="
for i in $(seq 1 30); do
  if $SSH_CMD "$KUBECTL get secret $SECRET_NAME -n $NAMESPACE >/dev/null 2>&1"; then
    echo "TLS secret $SECRET_NAME/$NAMESPACE is ready."
    break
  fi
  echo "  certificate not ready yet... waiting 10s"
  sleep 10
done

echo ""
echo "Done. Enabled HTTPS for: ${HOSTS[*]}"
echo "TLS secret: $SECRET_NAME in namespace $NAMESPACE"
