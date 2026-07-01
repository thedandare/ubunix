#!/usr/bin/env bash
set -euo pipefail

# Script para converter instância OCI Ubuntu para NixOS usando nixos-anywhere
# Uso: ./convert-to-nixos.sh <IP_PUBLICO> [NIXOS_CONFIG]

INSTANCE_IP="${1:-}"
NIXOS_CONFIG="${2:-$(dirname "$0")/nixos-config.nix}"
SSH_KEY="${3:-/root/.ssh/root_id_ed25519}"
AUTO_APPROVE="${AUTO_APPROVE:-}"

# Parse de flag --yes
if [ "${1:-}" = "--yes" ] || [ "${1:-}" = "-y" ]; then
  INSTANCE_IP="${2:-}"
  AUTO_APPROVE="1"
fi

if [ -z "$INSTANCE_IP" ]; then
  echo "Uso: $0 [--yes] <IP_PUBLICO> [NIXOS_CONFIG] [SSH_KEY]"
  echo "Exemplo: $0 203.0.113.10"
  echo "Exemplo nao interativo: AUTO_APPROVE=1 $0 203.0.113.10"
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

# Testar conexão SSH como ubuntu
echo "Testando conexão SSH com chave $SSH_KEY..."
ssh-keyscan -H "$INSTANCE_IP" >> ~/.ssh/known_hosts 2>/dev/null || true

if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$SSH_KEY" root@"$INSTANCE_IP" echo "SSH OK"; then
  echo "Erro: Não foi possível conectar via SSH como root"
  echo "Dica: certifique-se de que o usuário root tem a chave SSH autorizada"
  exit 1
fi

echo ""
echo "Iniciando conversão para NixOS..."
echo "Isso vai REINSTALAR o sistema operacional!"

# Garantir que o diretório do flake seja confiável pelo git quando rodado como root
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$(dirname "$0")")"
if [ -n "$REPO_ROOT" ]; then
  git config --global --add safe.directory "$REPO_ROOT" || true
fi

if [ -z "$AUTO_APPROVE" ]; then
  read -p "Continuar? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
else
  echo "AUTO_APPROVE ativado: continuando sem confirmacao"
fi

# Executar nixos-anywhere com sintaxe moderna.
# Se o script foi rodado como root mas o diretório do flake pertence a outro usuário,
# executa nixos-anywhere como o owner do diretório para evitar erro de git ownership.
FLAKE_DIR="$(pwd)"
FLAKE_OWNER="$(stat -c '%U' "$FLAKE_DIR" 2>/dev/null || echo "root")"
if [ "$(id -u)" -eq 0 ] && [ "$FLAKE_OWNER" != "root" ]; then
  echo "Diretório do flake pertence a $FLAKE_OWNER; executando nixos-anywhere como esse usuário"
  FLAKE_GROUP="$(id -g -n "$FLAKE_OWNER" 2>/dev/null || id -g "$FLAKE_OWNER" 2>/dev/null || echo "$FLAKE_OWNER")"
  TMP_KEY_DIR="$(mktemp -d)"
  TMP_KEY="$TMP_KEY_DIR/key"
  cp "$SSH_KEY" "$TMP_KEY"
  chown -R "$FLAKE_OWNER:$FLAKE_GROUP" "$TMP_KEY_DIR"
  chmod 600 "$TMP_KEY"
  su - "$FLAKE_OWNER" -c "
    cd '$FLAKE_DIR' &&
    nixos-anywhere \
      --generate-hardware-config nixos-generate-config ./hardware-config.nix \
      --flake '.#ocinix' \
      --impure \
      --target-host 'root@$INSTANCE_IP' \
      -i '$TMP_KEY'
  "
  rm -rf "$TMP_KEY_DIR"
else
  nixos-anywhere \
    --generate-hardware-config nixos-generate-config ./hardware-config.nix \
    --flake ".#ocinix" \
    --impure \
    --target-host "root@$INSTANCE_IP" \
    -i "$SSH_KEY"
fi

echo ""
echo "=== Conversão concluída ==="
echo "A instância será reiniciada com NixOS"
echo "Após reiniciar, conecte com: ssh root@$INSTANCE_IP"