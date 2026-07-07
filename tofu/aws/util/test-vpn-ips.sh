#!/bin/bash
set -eo pipefail

SSH_PORT=22
SSH_KEY=/root/.ssh/root_id_ed25519
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}") && pwd)"

# Testar em todos os hosts disponíveis
echo "=== Testando detecção de IPs VPN ==="

while IFS=$'\t' read -r zone id ip; do
  [[ -z "$ip" || "$ip" == "None" ]] && continue
  
  echo "--- Host: $ip ---"
  
  # Testar Tailscale
  echo "  Tailscale:"
  ts_ip=$(sudo ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "$SSH_PORT" \
    "root@$ip" -- incus exec amnix-1 -- tailscale ip -4 2>/dev/null | head -1) || echo "    FALHA: tailscale ip -4"
  [[ -n "$ts_ip" ]] && echo "    OK: $ts_ip"
  
  # Testar Netbird (wt0)
  echo "  Netbird (wt0):"
  nb_ip=$(sudo ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "$SSH_PORT" \
    "root@$ip" -- incus exec amnix-1 -- ip addr show wt0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -1) || echo "    FALHA: ip addr show wt0"
  [[ -n "$nb_ip" ]] && echo "    OK: $nb_ip"
  
  # Mostrar todas as interfaces
  echo "  Interfaces disponíveis:"
  sudo ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "$SSH_PORT" \
    "root@$ip" -- incus exec amnix-1 -- ip addr show | grep -E '^[0-9]+:' | awk -F': ' '{print "    " $2}' || echo "    FALHA ao listar interfaces"
  
  echo
  
done < <("$SCRIPT_DIR/describe-ips.sh") || true
