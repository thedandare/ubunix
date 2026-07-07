#!/usr/bin/env bash
set -euo pipefail

# Script para converter instância OCI Ubuntu para NixOS usando nixos-anywhere
# Uso: ./convert-to-nixos.sh <IP_PUBLICO>

INSTANCE_IP="${1:-}"
NIXOS_CONFIG="${2:-$(dirname "$0")/nixos-config.nix}"

if [ -z "$INSTANCE_IP" ]; then
  echo "Uso: $0 <IP_PUBLICO> [NIXOS_CONFIG]"
  echo "Exemplo: $0 192.0.2.1"
  exit 1
fi

if [ ! -f "$NIXOS_CONFIG" ]; then
  echo "Erro: Configuração NixOS não encontrada: $NIXOS_CONFIG"
  exit 1
fi

echo "=== Convertendo instância OCI para NixOS ==="
echo "IP: $INSTANCE_IP"
echo "Config: $NIXOS_CONFIG"
echo ""

# Verificar se nixos-anywhere está instalado
if ! command -v nixos-anywhere &> /dev/null; then
  echo "Instalando nixos-anywhere..."
  nix-shell -p nixos-anywhere --run "echo 'nixos-anywhere instalado'"
fi

# Testar conexão SSH
echo "Testando conexão SSH..."
ssh-keyscan -H "$INSTANCE_IP" >> ~/.ssh/known_hosts 2>/dev/null || true

if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@"$INSTANCE_IP" echo "SSH OK"; then
  echo "Erro: Não foi possível conectar via SSH"
  exit 1
fi

echo ""
echo "Iniciando conversão para NixOS..."
echo "Isso vai REINSTALAR o sistema operacional!"
read -p "Continuar? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  exit 1
fi

# Executar nixos-anywhere
nixos-anywhere \
  --flake .#nixos-config \
  --ssh-host-addr "$INSTANCE_IP" \
  --ssh-user ubuntu \
  --ssh-options "-o StrictHostKeyChecking=no" \
  "$NIXOS_CONFIG"

echo ""
echo "=== Conversão concluída ==="
echo "A instância será reiniciada com NixOS"
echo "Após reiniciar, conecte com: ssh ubuntu@$INSTANCE_IP"
