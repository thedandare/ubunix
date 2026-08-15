#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# inicializar-cluster-microceph-local.sh
#
# Versao simplificada para rede local com containers Incus.
# Sem SSH, sem VPN, sem dialog - usa "incus exec" diretamente.
#
# Containers esperados:
#   leonk7s  -> master   (192.168.0.7)
#   leonk8s  -> worker1  (192.168.0.8)
#   leonk9s  -> worker2  (192.168.0.9)
# ==============================================================================

MASTER_CONTAINER="leonk7s"
WORKER_CONTAINERS=("leonk8s" "leonk9s")

BOOTSTRAP_SCRIPT_PATH="/osnix/ubunix/tofu/aws/util/microceph_bootstrap.sh"
JOIN_SCRIPT_PATH="/osnix/ubunix/tofu/aws/util/microceph_join.sh"
INTEGRATION_SCRIPT_PATH="/osnix/ubunix/tofu/aws/util/integrar-microceph-microk8s.sh"

MICROCEPH_CHANNEL="${MICROCEPH_CHANNEL:-squid/stable}"
MICROCEPH_PUBLIC_NETWORK="${MICROCEPH_PUBLIC_NETWORK:-192.168.2.0/24}"
MICROCEPH_OSD_DEVICE="${MICROCEPH_OSD_DEVICE:-loop,4G,1}"
INTEGRATE_MICROK8S="${INTEGRATE_MICROK8S:-1}"

VPN_INTERFACE="eth0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==============================================================================
# Logging
# ==============================================================================
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/microceph-local-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] AVISO: $*" >&2; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERRO: $*" >&2; exit 1; }

# ==============================================================================
# Lock de execucao unica
# ==============================================================================
LOCK_FILE="/tmp/inicializar-cluster-microceph-local.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    fail "Outro processo deste orquestrador ja esta em execucao."
fi

# ==============================================================================
# Arquivos temporarios
# ==============================================================================
TMP_DIR=$(mktemp -d)
cleanup() {
    log "Limpando arquivos temporarios..."
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

# ==============================================================================
# Validacao de dependencias locais
# ==============================================================================
log "Validando dependencias locais..."
for cmd in incus grep sed awk mktemp flock tee; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        fail "Dependencia local ausente: $cmd"
    fi
done

if [[ ! -f "$BOOTSTRAP_SCRIPT_PATH" || ! -f "$JOIN_SCRIPT_PATH" ]]; then
    fail "Scripts remotos nao encontrados: $BOOTSTRAP_SCRIPT_PATH ou $JOIN_SCRIPT_PATH"
fi

# ==============================================================================
# Execucao local via incus exec
# ==============================================================================
cexec() {
    local cname="$1"; shift
    incus exec "$cname" -- bash -lc "$*"
}

# ==============================================================================
# Copia de scripts para container
# ==============================================================================
copy_script_to_container() {
    local cname="$1"
    local local_script="$2"
    local remote_path="$3"

    log "Copiando $(basename "$local_script") para ${cname}:${remote_path}"
    incus file push "$local_script" "${cname}${remote_path}" >&2 || {
        fail "Falha ao copiar script para container ${cname}"
    }
    cexec "$cname" "chmod 700 ${remote_path}" >&2 || {
        fail "Falha ao ajustar permissoes de ${remote_path}"
    }
    log "Script copiado e permissao 700 aplicada."
}

# ==============================================================================
# Obtem hostname de um container
# ==============================================================================
get_container_hostname() {
    local cname="$1"
    cexec "$cname" "hostname" 2>/dev/null | head -1
}

# ==============================================================================
# Extrai token de join do stdout do bootstrap
# ==============================================================================
extract_join_token() {
    grep -oE '^[A-Za-z0-9+/]+={0,2}$' | tail -n1
}

# ==============================================================================
# Gera token no master para um worker
# ==============================================================================
generate_join_token() {
    local worker_name="$1"
    local token
    token=$(cexec "$MASTER_CONTAINER" "sudo microceph cluster add '$(printf '%q' "$worker_name")'" 2>/dev/null | extract_join_token)
    if [[ -z "$token" ]]; then
        fail "Nao foi possivel gerar token para $worker_name"
    fi
    log "Token gerado para $worker_name: ${token:0:16}..."
    echo "$token"
}

# ==============================================================================
# Bootstrap
# ==============================================================================
do_bootstrap() {
    local first_worker_name="$1"

    log ">>> [$MASTER_CONTAINER] Bootstrap do MicroCeph"
    copy_script_to_container "$MASTER_CONTAINER" "$BOOTSTRAP_SCRIPT_PATH" "/tmp/microceph_bootstrap.sh"

    local env_vars
    env_vars="MICROCEPH_CHANNEL='${MICROCEPH_CHANNEL}' OSD_DEVICE='${MICROCEPH_OSD_DEVICE}' FRESH_INSTALL='${FRESH_INSTALL:-0}' VPN_INTERFACE='${VPN_INTERFACE}' PUBLIC_NETWORK='${MICROCEPH_PUBLIC_NETWORK}'"

    log "Executando bootstrap com primeiro worker: $first_worker_name"
    local bootstrap_out
    bootstrap_out=$(cexec "$MASTER_CONTAINER" "${env_vars} /tmp/microceph_bootstrap.sh '$(printf '%q' "$first_worker_name")'")

    if [[ -z "$bootstrap_out" ]]; then
        fail "Bootstrap nao retornou token em stdout"
    fi

    local NODE_TOKEN
    NODE_TOKEN=$(printf '%s\n' "$bootstrap_out" | extract_join_token)

    if [[ -z "$NODE_TOKEN" ]]; then
        fail "Token de join vazio"
    fi

    log "Token extraido: ${NODE_TOKEN:0:16}..."
    echo "$NODE_TOKEN"
}

# ==============================================================================
# Join
# ==============================================================================
do_join() {
    local cname="$1"
    local token="$2"
    local master_ip="$3"

    log ">>> [$cname] Join do MicroCeph"
    copy_script_to_container "$cname" "$JOIN_SCRIPT_PATH" "/tmp/microceph_join.sh"

    local env_vars
    env_vars="MICROCEPH_CHANNEL='${MICROCEPH_CHANNEL}' OSD_DEVICE='${MICROCEPH_OSD_DEVICE}' FRESH_INSTALL='${FRESH_INSTALL:-0}' VPN_INTERFACE='${VPN_INTERFACE}' PUBLIC_NETWORK='${MICROCEPH_PUBLIC_NETWORK}'"

    local join_cmd="${env_vars} /tmp/microceph_join.sh '$(printf '%q' "$token")' '$(printf '%q' "$master_ip")'"

    if cexec "$cname" "$join_cmd"; then
        log "OK: $cname entrou no cluster."
    else
        warn "Join falhou para $cname"
        return 1
    fi
}

# ==============================================================================
# Integracao MicroCeph -> MicroK8s
# ==============================================================================
do_integrate_microk8s() {
    local cname="$1"

    log ">>> [$cname] Integrando MicroCeph com MicroK8s"
    if [[ ! -f "$INTEGRATION_SCRIPT_PATH" ]]; then
        warn "Script de integracao nao encontrado: $INTEGRATION_SCRIPT_PATH"
        return 1
    fi

    copy_script_to_container "$cname" "$INTEGRATION_SCRIPT_PATH" "/tmp/integrar-microceph-microk8s.sh"

    if cexec "$cname" "/tmp/integrar-microceph-microk8s.sh"; then
        log "Integracao MicroCeph -> MicroK8s concluida com sucesso."
    else
        warn "Integracao MicroCeph -> MicroK8s falhou"
        return 1
    fi
}

# ==============================================================================
# 1. Verificacao dos containers
# ==============================================================================
log "Verificando containers Incus..."
ALL_CONTAINERS=("$MASTER_CONTAINER" "${WORKER_CONTAINERS[@]}")
for c in "${ALL_CONTAINERS[@]}"; do
    state=$(incus list -c n,s --format csv 2>/dev/null | grep "^${c}," | cut -d',' -f2 || echo "")
    if [[ "$state" != "RUNNING" ]]; then
        fail "Container $c nao esta em estado RUNNING (estado atual: ${state:-nao encontrado})"
    fi
    log "  $c: RUNNING"
done

# ==============================================================================
# 2. Obter IPs locais dos containers
# ==============================================================================
log "Obtendo IPs locais dos containers via $VPN_INTERFACE..."
get_container_ip() {
    local cname="$1"
    incus list -c n,4 --format csv 2>/dev/null \
        | grep "^${cname}," | cut -d',' -f2 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

MASTER_IP=$(get_container_ip "$MASTER_CONTAINER")
if [[ -z "$MASTER_IP" ]]; then
    fail "Nao foi possivel obter IP do master $MASTER_CONTAINER"
fi
log "  $MASTER_CONTAINER -> $MASTER_IP"

declare -A WORKER_IPS
for c in "${WORKER_CONTAINERS[@]}"; do
    ip=$(get_container_ip "$c")
    if [[ -z "$ip" ]]; then
        fail "Nao foi possivel obter IP do worker $c"
    fi
    WORKER_IPS[$c]="$ip"
    log "  $c -> $ip"
done

# ==============================================================================
# 3. Obter hostnames
# ==============================================================================
log "Obtendo hostnames dos containers..."
MASTER_HOSTNAME=$(get_container_hostname "$MASTER_CONTAINER")
if [[ -z "$MASTER_HOSTNAME" ]]; then
    fail "Nao foi possivel obter hostname do master"
fi
log "  $MASTER_CONTAINER hostname: $MASTER_HOSTNAME"

declare -A WORKER_HOSTNAMES
for c in "${WORKER_CONTAINERS[@]}"; do
    h=$(get_container_hostname "$c")
    if [[ -z "$h" ]]; then
        fail "Nao foi possivel obter hostname de $c"
    fi
    WORKER_HOSTNAMES[$c]="$h"
    log "  $c hostname: $h"
done

FIRST_WORKER="${WORKER_CONTAINERS[0]}"
FIRST_WORKER_HOSTNAME="${WORKER_HOSTNAMES[$FIRST_WORKER]}"

# ==============================================================================
# 4. Verificacao de cluster existente (skip se ja membro)
# ==============================================================================
log "Verificando cluster MicroCeph existente no master..."
CLUSTER_MEMBERS=$(cexec "$MASTER_CONTAINER" "sudo microceph cluster list --format json" 2>/dev/null || echo "[]")
log "Membros atuais: ${CLUSTER_MEMBERS:-"(nenhum/nao inicializado)"}"

# ==============================================================================
# 5. Bootstrap no master
# ==============================================================================
if echo "$CLUSTER_MEMBERS" | grep -q "$MASTER_HOSTNAME"; then
    log "[SKIP] Master $MASTER_CONTAINER ($MASTER_HOSTNAME) ja esta no cluster"
    BOOTSTRAP_TOKEN=""
else
    log "--- Executando bootstrap do MicroCeph no master ---"
    BOOTSTRAP_TOKEN=$(do_bootstrap "$FIRST_WORKER_HOSTNAME") || {
        fail "Bootstrap falhou"
    }
    log "Token inicial obtido com sucesso."
fi

# ==============================================================================
# 6. Join dos workers
# ==============================================================================
log "--- Executando join dos workers ---"
FAILED_WORKERS=()
FIRST_WORKER_DONE=0

for c in "${WORKER_CONTAINERS[@]}"; do
    worker_hostname="${WORKER_HOSTNAMES[$c]}"

    if echo "$CLUSTER_MEMBERS" | grep -q "$worker_hostname"; then
        log "[SKIP] $c ($worker_hostname) ja esta no cluster"
        continue
    fi

    if [[ "$FIRST_WORKER_DONE" -eq 0 ]]; then
        if [[ -z "$BOOTSTRAP_TOKEN" ]]; then
            worker_token=$(generate_join_token "$worker_hostname") || {
                warn "Nao foi possivel gerar token para $worker_hostname"
                FAILED_WORKERS+=("$c")
                continue
            }
        else
            worker_token="$BOOTSTRAP_TOKEN"
        fi
        FIRST_WORKER_DONE=1
    else
        worker_token=$(generate_join_token "$worker_hostname") || {
            warn "Nao foi possivel gerar token para $worker_hostname"
            FAILED_WORKERS+=("$c")
            continue
        }
    fi

    if do_join "$c" "$worker_token" "$MASTER_IP"; then
        log "Join OK: $c"
    else
        warn "Join falhou: $c"
        FAILED_WORKERS+=("$c")
    fi
done

# ==============================================================================
# 7. Health check final
# ==============================================================================
log "=== Verificando saude do cluster ==="
cexec "$MASTER_CONTAINER" "sudo microceph status"        || true
cexec "$MASTER_CONTAINER" "sudo microceph cluster list"  || true
cexec "$MASTER_CONTAINER" "sudo microceph disk list"     || true
cexec "$MASTER_CONTAINER" "sudo microceph.ceph status"   || true
cexec "$MASTER_CONTAINER" "sudo microceph.ceph osd tree" || true

if [[ ${#FAILED_WORKERS[@]} -gt 0 ]]; then
    warn "Workers que falharam: ${FAILED_WORKERS[*]}"
    exit 2
fi

# ==============================================================================
# 8. Integracao MicroCeph -> MicroK8s
# ==============================================================================
if [[ "$INTEGRATE_MICROK8S" == "1" ]]; then
    log "=== Integrando MicroCeph com MicroK8s ==="
    do_integrate_microk8s "$MASTER_CONTAINER" || true
else
    log "Pulando integracao com MicroK8s (INTEGRATE_MICROK8S=$INTEGRATE_MICROK8S)"
fi

log "Concluido. Log salvo em: $LOG_FILE"
