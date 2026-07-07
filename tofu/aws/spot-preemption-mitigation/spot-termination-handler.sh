#!/usr/bin/env bash
#
# spot-termination-handler.sh — Detecta interrupção de Spot Instance via IMDSv2
# e executa limpeza graciosa antes do término (2 min de aviso da AWS).
#
# Baseado na doc oficial:
#   https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-instance-termination-notices.html
#   https://docs.aws.amazon.com/fsx/latest/FileCacheGuide/working-with-ec2-spot-instances.html
#
# Recomendação AWS: polling a cada 5 segundos.
#
# Instalação (NixOS via user_data ou systemd service):
#   cp spot-termination-handler.sh /usr/local/bin/
#   chmod +x /usr/local/bin/spot-termination-handler.sh
#   systemctl enable --now spot-termination-handler.service
#
set -euo pipefail

# ── Configuração ─────────────────────────────────────────────────────────────
POLL_INTERVAL="${POLL_INTERVAL:-5}"          # segundos entre checks (AWS recomenda 5)
IMDS_TOKEN_TTL="${IMDS_TOKEN_TTL:-21600}"    # TTL do token IMDSv2 (6h)
LOG_TAG="spot-termination-handler"
SHUTDOWN_HOOK_DIR="${SHUTDOWN_HOOK_DIR:-/etc/spot-termination-hooks.d}"

# ── Logging ──────────────────────────────────────────────────────────────────
log()  { logger -t "$LOG_TAG" "$1" 2>/dev/null || echo "[$(date -u +%FT%TZ)] $1"; }
warn() { logger -t "$LOG_TAG" -p user.warning "$1" 2>/dev/null || echo "[$(date -u +%FT%TZ)] WARN: $1" >&2; }
err()  { logger -t "$LOG_TAG" -p user.err "$1" 2>/dev/null || echo "[$(date -u +%FT%TZ)] ERROR: $1" >&2; }

# ── IMDSv2 token ─────────────────────────────────────────────────────────────
IMDS_BASE="http://169.254.169.254/latest"
TOKEN=""

fetch_token() {
  TOKEN=$(curl -s -X PUT "${IMDS_BASE}/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: ${IMDS_TOKEN_TTL}" 2>/dev/null) || true
  if [[ -z "$TOKEN" ]]; then
    err "Falha ao obter token IMDSv2"
    return 1
  fi
}

refresh_token_short() {
  TOKEN=$(curl -s -X PUT "${IMDS_BASE}/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 30" 2>/dev/null) || true
}

# ── Metadata helpers ─────────────────────────────────────────────────────────
get_metadata() {
  local path="$1"
  curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" "${IMDS_BASE}/meta-data/${path}" 2>/dev/null
}

get_metadata_code() {
  curl -s -w "%{http_code}" -o /dev/null \
    -H "X-aws-ec2-metadata-token: ${TOKEN}" \
    "${IMDS_BASE}/meta-data/${path}" 2>/dev/null
}

# ── Hooks de limpeza ─────────────────────────────────────────────────────────
# Scripts em /etc/spot-termination-hooks.d/ são executados em ordem alfabética.
# Cada hook tem no máximo HOOK_TIMEOUT segundos para rodar (default 30).

HOOK_TIMEOUT="${HOOK_TIMEOUT:-30}"

run_hooks() {
  local action="$1"
  local termination_time="$2"

  log "Executando hooks de limpeza (action=${action}, time=${termination_time})..."

  if [[ ! -d "$SHUTDOWN_HOOK_DIR" ]]; then
    log "Diretório de hooks ${SHUTDOWN_HOOK_DIR} não existe — pulando hooks customizados"
    return 0
  fi

  local hooks=()
  local hook
  while IFS= read -r -d '' hook; do
    hooks+=("$hook")
  done < <(find "$SHUTDOWN_HOOK_DIR" -maxdepth 1 -type f -executable -name '*.sh' -print0 2>/dev/null | sort -z || true)

  if [[ ${#hooks[@]} -eq 0 ]]; then
    log "Nenhum hook encontrado em ${SHUTDOWN_HOOK_DIR}"
    return 0
  fi

  for hook in "${hooks[@]}"; do
    local name
    name=$(basename "$hook")
    log "Executando hook: ${name}"

    local hook_rc=0
    local hook_log
    hook_log=$(mktemp)
    timeout "$HOOK_TIMEOUT" "$hook" "$action" "$termination_time" > "$hook_log" 2>&1 || hook_rc=$?
    logger -t "$LOG_TAG" -f "$hook_log" 2>/dev/null || true
    cat "$hook_log" 2>/dev/null || true
    rm -f "$hook_log"

    if [[ $hook_rc -eq 0 ]]; then
      log "Hook ${name} concluído"
    elif [[ $hook_rc -eq 124 ]]; then
      warn "Hook ${name} excedeu timeout de ${HOOK_TIMEOUT}s — continuando"
    else
      warn "Hook ${name} falhou (exit=${hook_rc}) — continuando"
    fi
  done
}

# ── Ações de limpeza padrão (built-in) ───────────────────────────────────────
drain_microk8s() {
  if ! command -v microk8s &>/dev/null && ! [[ -x /var/snap/microk8s/current/bin/microk8s ]]; then
    return 0
  fi

  local MK8S="microk8s"
  if ! command -v microk8s &>/dev/null; then
    MK8S="/var/snap/microk8s/current/bin/microk8s"
  fi

  log "Drenando nodes MicroK8s..."

  # Drena cada node — cordon + drain
  local nodes
  nodes=$($MK8S kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null) || return 0
  for node in $nodes; do
    log "Cordon + drain node: ${node}"
    $MK8S kubectl cordon "$node" 2>/dev/null || true
    $MK8S kubectl drain "$node" --force --ignore-daemonsets --delete-emptydir-data --timeout=60s 2>/dev/null || true
  done
}

stop_incus_containers() {
  if ! command -v incus &>/dev/null; then
    return 0
  fi

  log "Parando containers Incus graciosamente..."

  local containers
  containers=$(incus list -c n --format csv 2>/dev/null) || return 0
  for ct in $containers; do
    log "Parando container Incus: ${ct}"
    incus stop "$ct" --timeout 60 2>/dev/null || true
  done
}

run_builtin_cleanup() {
  local action="$1"

  # 1. Drenar MicroK8s (cordon + drain)
  drain_microk8s

  # 2. Parar containers Incus
  stop_incus_containers

  # 3. Desmontar filesystems remotos se houver
  log "Desmontando filesystems NFS/Lustre/FSx se houver..."
  while read -r mnt fstype; do
    case "$fstype" in
      nfs|nfs4|lustre|fsx)
        log "Desmontando ${mnt} (${fstype})"
        umount -l "$mnt" 2>/dev/null || true
        ;;
    esac
  done < <(awk '{print $2, $3}' /proc/mounts 2>/dev/null)
}

# ── Loop principal ───────────────────────────────────────────────────────────
main() {
  log "Iniciando monitor de interrupção Spot (poll a cada ${POLL_INTERVAL}s)"

  if ! fetch_token; then
    err "Não foi possível obter token IMDSv2 — abortando"
    exit 1
  fi

  # Identificar a instância para log
  local instance_id
  instance_id=$(get_metadata "instance-id" 2>/dev/null) || instance_id="unknown"
  log "Monitorando instância: ${instance_id}"

  while true; do
    sleep "$POLL_INTERVAL"

    # Verificar spot/instance-action (endpoint recomendado pela AWS)
    local http_code
    http_code=$(curl -s -w "%{http_code}" -o /tmp/.spot-action \
      -H "X-aws-ec2-metadata-token: ${TOKEN}" \
      "${IMDS_BASE}/meta-data/spot/instance-action" 2>/dev/null)

    # HTTP 401 = token expirado, renovar
    if [[ "$http_code" == "401" ]]; then
      refresh_token_short
      continue
    fi

    # HTTP 404 = sem interrupção pendente
    if [[ "$http_code" != "200" ]]; then
      continue
    fi

    # HTTP 200 = interrupção detectada!
    local action_json
    action_json=$(cat /tmp/.spot-action 2>/dev/null)
    rm -f /tmp/.spot-action

    local action termination_time
    action=$(echo "$action_json" | jq -r '.action // "unknown"' 2>/dev/null || echo "unknown")
    termination_time=$(echo "$action_json" | jq -r '.time // "unknown"' 2>/dev/null || echo "unknown")

    log "INTERRUPÇÃO DETECTADA — action=${action}, time=${termination_time}"

    if [[ "$action" == "terminate" ]] || [[ "$action" == "stop" ]]; then
      # ── Executar limpeza built-in ──
      run_builtin_cleanup "$action"

      # ── Executar hooks customizados ──
      run_hooks "$action" "$termination_time"

      log "Limpeza concluída — iniciando shutdown"

      # Shutdown gracoso
      if [[ "$action" == "terminate" ]]; then
        shutdown now 2>/dev/null || poweroff 2>/dev/null || true
      elif [[ "$action" == "stop" ]]; then
        shutdown -h now 2>/dev/null || true
      fi
    elif [[ "$action" == "hibernate" ]]; then
      # Hibernação não tem aviso de 2 min — processo começa imediatamente
      warn "Hibernação detectada — tempo limitado para limpeza"
      run_builtin_cleanup "hibernate"
      run_hooks "hibernate" "$termination_time"
    fi

    # Após detectar e agir, sair do loop
    break
  done

  log "Monitor de interrupção Spot finalizado"
}

# Executa main apenas quando o script é chamado diretamente (não via source)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
