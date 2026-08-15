#!/bin/bash
set -eo pipefail

SSH_PORT=22
SSH_KEY=/root/.ssh/root_id_ed25519
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}") && pwd)"

echo "=== Testando IPs VPN ==="

# Pega primeiro host disponível
first_ip=$("$SCRIPT_DIR/describe-ips.sh" | head -1 | cut -f3)
if [[ -z "$first_ip" ]]; then
  echo "Nenhum host encontrado"
  exit 1
fi

echo "Testando no host: $first_ip"
echo

# Testar Tailscale
echo "1. Testando Tailscale:"
sudo ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "$SSH_PORT" \
  "root@$first_ip" -- incus exec amnix-1 -- tailscale ip -4 2>/dev/null | head -1 || echo "   FALHA"
echo

# Testar Netbird
echo "2. Testando Netbird (wt0):"
sudo ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "$SSH_PORT" \
  "root@$first_ip" -- incus exec amnix-1 -- ip addr show wt0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -1 || echo "   FALHA"
echo

# Mostrar interfaces
echo "3. Interfaces disponíveis:"
sudo ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "$SSH_PORT" \
  "root@$first_ip" -- incus exec amnix-1 -- ip addr show | grep -E '^[0-9]+:' | awk -F': ' '{print $2}'
