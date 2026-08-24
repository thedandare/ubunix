#!/usr/bin/env bash
set -euo pipefail

# Configs
ZONE="6nix.pl"
DOMAIN="gcm.6nix.pl"
ACCOUNT_ID="177791"
TOKEN="dnsimple_a_lFuEZ1k9PPRaiJSnBUQBdg6WrmgJfEDt"
SSH_HOST="root@35.215.39.218"
SSH_KEY="/mnt/c/Users/leo/.ssh/root_id_ed25519"
if [ -f "/root/.ssh/root_id_ed25519" ]; then
  SSH_KEY="/root/.ssh/root_id_ed25519"
fi
PORT=22

# Convert Windows path backslashes to forward slashes for compatibility in git bash/ssh command
SSH_KEY_POSIX=$(echo "$SSH_KEY" | sed 's/\\/\//g')

echo "=== Copying manifests to remote server ==="
ssh -i "$SSH_KEY_POSIX" -p $PORT  -o StrictHostKeyChecking=no "$SSH_HOST" "mkdir -p /var/tmp4/k8s-dns"
ssh -i "$SSH_KEY_POSIX" -p $PORT  -o StrictHostKeyChecking=no "$SSH_HOST" "rm -f /var/tmp4/k8s-dns/external-dns-simple.yaml /var/tmp4/k8s-dns/nginx.yaml"
ssh -i "$SSH_KEY_POSIX" -p $PORT  -o StrictHostKeyChecking=no "$SSH_HOST" "cat > /var/tmp4/k8s-dns/external-dns-simple.yaml" < external-dns-simple.yaml
ssh -i "$SSH_KEY_POSIX" -p $PORT  -o StrictHostKeyChecking=no "$SSH_HOST" "cat > /var/tmp4/k8s-dns/nginx.yaml" < nginx.yaml

echo "=== Deploying ExternalDNS ==="
ssh -i "$SSH_KEY_POSIX" -p $PORT  -o StrictHostKeyChecking=no "$SSH_HOST" "microk8s kubectl apply -f /var/tmp4/k8s-dns/external-dns-simple.yaml"

echo "=== Deploying Nginx Service ==="
ssh -i "$SSH_KEY_POSIX" -p $PORT  -o StrictHostKeyChecking=no "$SSH_HOST" "microk8s kubectl apply -f /var/tmp4/k8s-dns/nginx.yaml"

echo "=== Waiting for Ingress to be created ==="
while true; do
  ING_HOST=$(ssh -i "$SSH_KEY_POSIX" -p $PORT  -o StrictHostKeyChecking=no "$SSH_HOST" "microk8s kubectl get ingress nginx-ingress -o jsonpath='{.spec.rules[0].host}'" 2>/dev/null || true)
  if [ -n "$ING_HOST" ]; then
    echo "Ingress is ready for host: $ING_HOST"
    break
  fi
  echo "Still waiting for Ingress..."
  sleep 5
done

echo "=== DNSimple Verification endpoints ==="
echo "Identity API (Whoami):"
echo "  curl -H \"Authorization: Bearer $TOKEN\" -H 'Accept: application/json' https://api.dnsimple.com/v2/whoami"
echo ""
echo "List records for zone $ZONE:"
echo "  curl -H \"Authorization: Bearer $TOKEN\" -H 'Accept: application/json' 'https://api.dnsimple.com/v2/$ACCOUNT_ID/zones/$ZONE/records?name=pu'"
echo ""
echo "DNSimple Dashboard Record Editor:"
echo "  https://dnsimple.com/a/$ACCOUNT_ID/domains/$ZONE/records"

