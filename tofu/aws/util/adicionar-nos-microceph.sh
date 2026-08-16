#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# adicionar-nos-microceph.sh
#
# Adiciona novos containers Incus a um cluster MicroCeph existente.
# Reutiliza o script microceph_join.sh para executar o join em cada novo no.
#
# Uso:
#   ./adicionar-nos-microceph.sh <MASTER_HOST_IP> [NOVO_HOST_IP...]
#
# Exemplo:
#   ./adicionar-nos-microceph.sh 3.137.209.109 18.222.23.71 18.221.172.191
# ==============================================================================

SSH_PORT=2409
SSH_KEY=/root/.ssh/root_id_ed25519
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOIN_SCRIPT="$SCRIPT_DIR/microceph_join.sh"

MICROCEPH_CHANNEL="${MICROCEPH_CHANNEL:-squid/stable}"
OSD_DEVICE="${OSD_DEVICE:-loop,4G,1}"
PUBLIC_NETWORK="${PUBLIC_NETWORK:-}"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
fail() { log "ERRO: $*"; exit 1; }

sshrun() {
  local ip="$1"; shift
  sudo ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
    -i "$SSH_KEY" -p "$SSH_PORT" "root@$ip" "$@"
}

usage() {
  echo "Uso: $0 <MASTER_HOST_IP> [NOVO_HOST_IP...]" >&2
  echo "  MASTER_HOST_IP: IP publico do host que contem o container master do MicroCeph" >&2
  echo "  NOVO_HOST_IP:   IPs publicos dos hosts com novos containers para adicionar" >&2
  exit 1
}

AUTO_MODE=0
if [[ "$1" == "--auto" ]]; then
  AUTO_MODE=1
  shift
fi

[[ "$#" -lt 1 ]] && usage

MASTER_HOST_IP="$1"
shift
NEW_HOST_IPS=("$@")

if [[ ${#NEW_HOST_IPS[@]} -eq 0 ]]; then
  log "Nenhum host novo fornecido. Nada a fazer."
  exit 0
fi

[[ -f "$JOIN_SCRIPT" ]] || fail "Script nao encontrado: $JOIN_SCRIPT"

# ==============================================================================
# 1. Detecta container master e IP VPN do master
# ==============================================================================
log "Detectando container master em $MASTER_HOST_IP..."
MASTER_CONTAINER=$(sshrun "$MASTER_HOST_IP" "incus list -c n --format csv" 2>/dev/null | grep -E 'amnix-' | sort -V | head -1 | tr -d '\n')
[[ -n "$MASTER_CONTAINER" ]] || fail "Nenhum container amnix encontrado em $MASTER_HOST_IP"
log "Container master: $MASTER_CONTAINER"

log "Obtendo IP VPN do master..."
MASTER_VPN_IP=$(sshrun "$MASTER_HOST_IP" "incus exec $MASTER_CONTAINER -- tailscale ip -4" 2>/dev/null | head -1)
[[ -n "$MASTER_VPN_IP" ]] || fail "Nao foi possivel obter IP Tailscale do master"
log "IP VPN do master: $MASTER_VPN_IP"

# ==============================================================================
# 2. Lista membros atuais do cluster
# ==============================================================================
log "Membros atuais do cluster MicroCeph:"
sshrun "$MASTER_HOST_IP" "incus exec $MASTER_CONTAINER -- microceph status" || true

# ==============================================================================
# 3. Descobre containers RUNNING em cada host novo
# ==============================================================================
log "Obtendo lista de membros atuais do cluster..."
CURRENT_MEMBERS=$(sshrun "$MASTER_HOST_IP" "incus exec $MASTER_CONTAINER -- microceph cluster list --format json" 2>/dev/null || echo "[]")

NEW_CONTAINERS=()
for ip in "${NEW_HOST_IPS[@]}"; do
  log "Detectando containers em $ip..."
  while IFS=',' read -r cname state; do
    [[ "$state" == "RUNNING" ]] || continue
    [[ -n "$cname" ]] || continue
    # Verifica se ja esta no cluster
    if echo "$CURRENT_MEMBERS" | grep -q "$cname"; then
      log "  [SKIP] $cname ja esta no cluster MicroCeph"
      continue
    fi
    NEW_CONTAINERS+=("$ip|$cname")
  done < <(sshrun "$ip" "incus list -c n,s --format csv" 2>/dev/null | grep -E 'amnix-' | sort -V)
done

if [[ ${#NEW_CONTAINERS[@]} -eq 0 ]]; then
  log "Nenhum container novo em estado RUNNING para adicionar."
  exit 0
fi

log "Containers selecionados para join:"
for entry in "${NEW_CONTAINERS[@]}"; do
  log "  $entry"
done

SELECTED_ARR=("${NEW_CONTAINERS[@]}")

# ==============================================================================
# 5. Define PUBLIC_NETWORK se nao informado
# ==============================================================================
if [[ -z "$PUBLIC_NETWORK" ]]; then
  # Tenta inferir a rede a partir do IP VPN do master (Tailscale = 100.64.0.0/10)
  if [[ "$MASTER_VPN_IP" == 100.* ]]; then
    PUBLIC_NETWORK="100.64.0.0/10"
  else
    fail "PUBLIC_NETWORK nao definido. Informe a rede Ceph (ex: 100.64.0.0/10)."
  fi
fi
log "Public network: $PUBLIC_NETWORK"

# ==============================================================================
# 6. Gera tokens e executa join para cada container selecionado
# ==============================================================================
for entry in "${SELECTED_ARR[@]}"; do
  IFS='|' read -r target_ip cname <<< "$entry"
  cname=$(echo "$cname" | tr -d '"')
  log ">>> Processando $target_ip -> $cname"

  # Obtem hostname do container
  NEW_NODE_NAME=$(sshrun "$target_ip" "incus exec $cname -- hostname" 2>/dev/null | head -1 | tr -d '\n')
  [[ -n "$NEW_NODE_NAME" ]] || fail "Nao foi possivel obter hostname de $cname"
  log "  Nome do novo no: $NEW_NODE_NAME"

  # Gera token no master
  log "  Gerando token para $NEW_NODE_NAME no master..."
  TOKEN=$(sshrun "$MASTER_HOST_IP" "incus exec $MASTER_CONTAINER -- microceph cluster add '$NEW_NODE_NAME'" 2>/dev/null | tail -1 | tr -d '\n')
  if [[ -z "$TOKEN" ]]; then
    log "  AVISO: falha ao gerar token para $NEW_NODE_NAME. Verifique se o nome ja existe." >&2
    continue
  fi
  log "  Token gerado."

  # Copia script de join para o novo host
  log "  Copiando microceph_join.sh para $target_ip..."
  sudo scp -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "$SSH_KEY" -P "$SSH_PORT" "$JOIN_SCRIPT" "root@$target_ip:/tmp/microceph_join.sh" || {
    log "  FALHA ao copiar script para $target_ip" >&2
    continue
  }

  # Copia script para dentro do container
  sshrun "$target_ip" "incus file push /tmp/microceph_join.sh ${cname}/tmp/microceph_join.sh" || {
    log "  FALHA ao copiar script para container $cname" >&2
    continue
  }

  # Obtem IP VPN do container novo
  NEW_VPN_IP=$(sshrun "$target_ip" "incus exec $cname -- tailscale ip -4" 2>/dev/null | head -1)
  if [[ -z "$NEW_VPN_IP" ]]; then
    log "  AVISO: nao foi possivel obter IP Tailscale de $cname" >&2
    continue
  fi
  log "  IP VPN de $cname: $NEW_VPN_IP"

  # Executa join
  log "  Executando join em $cname..."
  if sshrun "$target_ip" "incus exec $cname -- bash -lc 'sudo PUBLIC_NETWORK=$PUBLIC_NETWORK VPN_INTERFACE=tailscale0 OSD_DEVICE=$OSD_DEVICE MICROCEPH_CHANNEL=$MICROCEPH_CHANNEL /tmp/microceph_join.sh $TOKEN $MASTER_VPN_IP'"; then
    log "  OK: $cname entrou no cluster."
  else
    log "  FALHA: join de $cname" >&2
    continue
  fi

done

# ==============================================================================
# 7. Verifica health final
# ==============================================================================
log "Aguardando cluster estabilizar..."
sleep 10
log "Status final do cluster:"
sshrun "$MASTER_HOST_IP" "incus exec $MASTER_CONTAINER -- microceph status" || true
sshrun "$MASTER_HOST_IP" "incus exec $MASTER_CONTAINER -- microceph.ceph status" || true

log "Concluido."
