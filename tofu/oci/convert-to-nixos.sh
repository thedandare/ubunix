#!/usr/bin/env bash
set -euo pipefail

# Script para converter instância OCI Ubuntu para NixOS usando nixos-anywhere
# Uso: ./convert-to-nixos.sh [--port PORT] [--post-kexec-port PORT] [--user USER] [--yes] <IP_PUBLICO> [NIXOS_CONFIG] [SSH_KEY]

INSTANCE_IP=""
NIXOS_CONFIG="$(dirname "$0")/nixos-config.nix"
SSH_KEY="/root/.ssh/root_id_ed25519"
SSH_PORT="${SSH_PORT:-22}"
POST_KEXEC_PORT="${POST_KEXEC_PORT:-22}"
SSH_USER="${SSH_USER:-ubuntu}"
AUTO_APPROVE="${AUTO_APPROVE:-}"

# Parse de argumentos
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)
      AUTO_APPROVE="1"
      shift
      ;;
    --port|-p)
      SSH_PORT="${2:?porta não especificada}"
      shift 2
      ;;
    --port=*)
      SSH_PORT="${1#*=}"
      shift
      ;;
    --user|-u)
      SSH_USER="${2:?usuário não especificado}"
      shift 2
      ;;
    --user=*)
      SSH_USER="${1#*=}"
      shift
      ;;
    --post-kexec-port)
      POST_KEXEC_PORT="${2:?porta pós-kexec não especificada}"
      shift 2
      ;;
    --post-kexec-port=*)
      POST_KEXEC_PORT="${1#*=}"
      shift
      ;;
    *)
      if [ -z "$INSTANCE_IP" ]; then
        INSTANCE_IP="$1"
      elif [ "$NIXOS_CONFIG" = "$(dirname "$0")/nixos-config.nix" ]; then
        NIXOS_CONFIG="$1"
      elif [ "$SSH_KEY" = "/root/.ssh/root_id_ed25519" ]; then
        SSH_KEY="$1"
      else
        echo "Erro: argumento desconhecido: $1"
        exit 1
      fi
      shift
      ;;
  esac
done

if [ -z "$INSTANCE_IP" ]; then
  echo "Uso: $0 [--port PORT] [--post-kexec-port PORT] [--user USER] [--yes] <IP_PUBLICO> [NIXOS_CONFIG] [SSH_KEY]"
  echo "Exemplo: $0 203.0.113.10"
  echo "Exemplo com porta: $0 --port 2222 203.0.113.10"
  echo "Exemplo com usuário: $0 --user myuser 203.0.113.10"
  echo "Exemplo nao interativo: AUTO_APPROVE=1 $0 203.0.113.10"
  exit 1
fi

if [ ! -f "$NIXOS_CONFIG" ]; then
  echo "Erro: Configuração NixOS não encontrada: $NIXOS_CONFIG"
  exit 1
fi

echo "=== Convertendo instância OCI para NixOS ==="
echo "IP: $INSTANCE_IP"
echo "Porta SSH: $SSH_PORT"
echo "Porta pós-kexec: $POST_KEXEC_PORT"
echo "Usuário SSH: $SSH_USER"
echo "Config: $NIXOS_CONFIG"
echo ""

# Verificar se nixos-anywhere está instalado
if ! command -v nixos-anywhere &> /dev/null; then
  echo "Instalando nixos-anywhere..."
  nix-shell -p nixos-anywhere --run "echo 'nixos-anywhere instalado'"
fi

# Testar conexão SSH
echo "Testando conexão SSH com chave $SSH_KEY..."
ssh-keyscan -p "$SSH_PORT" -H "$INSTANCE_IP" >> ~/.ssh/known_hosts 2>/dev/null || true

if ! ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $SSH_KEY "$SSH_USER@$INSTANCE_IP" echo "SSH OK"; then
  echo "Erro: Não foi possível conectar via SSH como $SSH_USER"
  echo "Dica: certifique-se de que o usuário $SSH_USER tem a chave SSH autorizada"
  exit 1
fi

echo ""
echo "Iniciando conversão para NixOS..."
echo "Isso vai REINSTALAR o sistema operacional!"

# Garantir que o diretório do flake seja confiável pelo git quando rodado como root
#REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$(dirname "$0")")"
REPO_ROOT="/osnix"
if [ -n "$REPO_ROOT" ]; then
  git config --global --add safe.directory "$REPO_ROOT" || true
fi

if [ -z "$AUTO_APPROVE" ]; then
  read -p "Continuar? " -n 1 -r
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
  TMP_EXTRA="$(mktemp -d)"
  mkdir -p "$TMP_EXTRA/etc/nixos"
  cp -r "$REPO_ROOT/nixos/ocnix/." "$TMP_EXTRA/etc/nixos/"
  chown -R "$FLAKE_OWNER:$FLAKE_GROUP" "$TMP_EXTRA"
  su - "$FLAKE_OWNER" -c "
    cd '$FLAKE_DIR' &&
    nixos-anywhere \
      --generate-hardware-config nixos-generate-config ./hardware-config.nix \
      --flake '.#ocinix' \
      --impure \
      --extra-files '$TMP_EXTRA' \
      --ssh-port '$SSH_PORT' \
      --post-kexec-ssh-port '$POST_KEXEC_PORT' \
      --target-host '$SSH_USER@$INSTANCE_IP' \
      -i '$TMP_KEY'
  "
  rm -rf "$TMP_EXTRA"
  rm -rf "$TMP_KEY_DIR"
else
  TMP_EXTRA="$(mktemp -d)"
  mkdir -p "$TMP_EXTRA/etc/nixos"
  cp -r "$REPO_ROOT/nixos/ocnix/." "$TMP_EXTRA/etc/nixos/"
  nixos-anywhere \
    --generate-hardware-config nixos-generate-config ./hardware-config.nix \
    --flake ".#ocinix" \
    --impure \
    --extra-files "$TMP_EXTRA" \
    --ssh-port "$SSH_PORT" \
    --post-kexec-ssh-port "$POST_KEXEC_PORT" \
    --target-host "$SSH_USER@$INSTANCE_IP" \
    -i "$SSH_KEY"
  rm -rf "$TMP_EXTRA"
fi

echo ""
echo "=== Conversão concluída ==="
echo "A instância será reiniciada com NixOS"
if [ "$SSH_PORT" -ne 22 ]; then
  echo "Após reiniciar, conecte com: ssh -p $SSH_PORT $SSH_USER@$INSTANCE_IP"
else
  echo "Após reiniciar, conecte com: ssh $SSH_USER@$INSTANCE_IP"
fi
