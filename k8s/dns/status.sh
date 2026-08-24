#!/usr/bin/env bash
set -euo pipefail

# Configs
ZONE="6nix.pl"
DOMAIN="gcm.6nix.pl"
ACCOUNT_ID="177791"
TOKEN="dnsimple_a_lFuEZ1k9PPRaiJSnBUQBdg6WrmgJfEDt"

SSH_HOST="root@35.215.39.218"
SSH_KEY="/mnt/c/Users/leo/.ssh/root_id_ed25519"
if [ -f "$HOME/.ssh/roo t_id_ed25519" ]; then
  SSH_KEY="$HOME/.ssh/root_id_ed25519"
fi
PORT=2409

SSH_KEY_POSIX=$(echo "$SSH_KEY" | sed 's/\\/\//g')

echo "=== ExternalDNS Deployment Status ==="
ssh -i "$SSH_KEY_POSIX"  -p $PORT  -o StrictHostKeyChecking=no  "$SSH_HOST" "microk8s kubectl get deployment external-dns -n default"

echo -e "\n=== Nginx Service, Deployment & Ingress Status ==="
ssh -i "$SSH_KEY_POSIX"  -p $PORT  -o StrictHostKeyChecking=no  "$SSH_HOST" "microk8s kubectl get deployment/nginx service/nginx ingress/nginx-ingress -n default"

echo -e "\n=== Pods Status ==="
ssh -i "$SSH_KEY_POSIX"  -p $PORT  -o StrictHostKeyChecking=no  "$SSH_HOST" "microk8s kubectl get pods -l 'app in (external-dns, nginx)' -n default"

echo -e "\n=== ExternalDNS Latest Logs ==="
ssh -i "$SSH_KEY_POSIX"  -p $PORT  -o StrictHostKeyChecking=no  "$SSH_HOST" "microk8s kubectl logs -l app=external-dns -n default --tail=20"

echo -e "\n=== Published Records on DNSimple (Zone: $ZONE) ==="
curl -s -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' "https://api.dnsimple.com/v2/$ACCOUNT_ID/zones/$ZONE/records?name=pu" | \
  grep -oE '"name":"[^"]*"|"type":"[^"]*"|"content":"[^"]*"' || echo "No records found or API error."


