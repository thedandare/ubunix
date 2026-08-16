#!/bin/bash
# ==============================================================================
# SCRIPT DE BOOTSTRAP DO MICROCEPH
# ==============================================================================
# Uso: sudo microceph_bootstrap.sh <NOME_DO_PRIMEIRO_WORKER> [OPCOES]
#
# Opcoes (variaveis de ambiente):
#   MICROCEPH_CHANNEL   canal do snap (padrao: squid/stable)
#   VPN_INTERFACE       tailscale0 | wt0 | eth1 | etc. (auto-detectado)
#   PUBLIC_NETWORK      CIDR da rede publica do Ceph (padrao: rede da VPN)
#   CLUSTER_NETWORK     CIDR da rede de cluster (opcional)
#   OSD_DEVICE          loop,N | /dev/sdb | etc. (padrao: loop,4G,1)
#   FRESH_INSTALL       1 = remove microceph existente com confirmacao
# ==============================================================================
set -euo pipefail

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
fail() { log "ERRO: $*"; exit 1; }

# -----------------------------------------------------------------------------
# Validacao de argumentos e permissao
# -----------------------------------------------------------------------------
if [[ "$#" -lt 1 ]]; then
    fail "Uso: sudo $0 <NOME_DO_PRIMEIRO_WORKER>"
fi
NOVO_NODE_NAME="$1"

if [[ "$EUID" -ne 0 ]]; then
    fail "Este script precisa ser executado como root."
fi

# -----------------------------------------------------------------------------
# Configuracoes
# -----------------------------------------------------------------------------
MICROCEPH_CHANNEL="${MICROCEPH_CHANNEL:-squid/stable}"
OSD_DEVICE="${OSD_DEVICE:-loop,4G,1}"
FRESH_INSTALL="${FRESH_INSTALL:-0}"

# -----------------------------------------------------------------------------
# Deteccao da interface VPN
# -----------------------------------------------------------------------------
VPN_INTERFACE="${VPN_INTERFACE:-}"
if [[ -z "$VPN_INTERFACE" ]]; then
    for iface in tailscale0 wt0; do
        if ip link show "$iface" >/dev/null 2>&1; then
            VPN_INTERFACE="$iface"
            break
        fi
    done
fi

if [[ -z "$VPN_INTERFACE" ]]; then
    fail "Nenhuma interface VPN detectada (tailscale0/wt0). Especifique VPN_INTERFACE."
fi

VPN_IP=$(ip -4 addr show dev "$VPN_INTERFACE" 2>/dev/null | grep -oP '(?<=inet )\d+(\.\d+){3}' | head -1)
if [[ -z "$VPN_IP" ]]; then
    fail "Interface $VPN_INTERFACE nao possui IPv4 valido."
fi
log "Interface VPN: $VPN_INTERFACE  IP: $VPN_IP"

# -----------------------------------------------------------------------------
# Redes Ceph
# -----------------------------------------------------------------------------
if [[ -z "${PUBLIC_NETWORK:-}" ]]; then
    fail "PUBLIC_NETWORK nao definido. Passe explicitamente (ex: 100.64.0.0/10 para Tailscale)."
fi
log "Public network: $PUBLIC_NETWORK"

if [[ -n "${CLUSTER_NETWORK:-}" ]]; then
    log "Cluster network: $CLUSTER_NETWORK"
fi

# Funcao para gerar token, removendo registro anterior se houver conflito
generate_token_for_node() {
    local node="$1"
    local token
    token=$(sudo microceph cluster add "$node" 2>&1) || {
        if echo "$token" | grep -q "UNIQUE constraint failed"; then
            log "Token anterior para $node ja existe. Removendo registro e gerando novo..."
            sudo microceph cluster sql "DELETE FROM core_token_records WHERE name = '${node}';" >/dev/null
            token=$(sudo microceph cluster add "$node" 2>&1) || fail "Falha ao gerar token para $node: $token"
        else
            fail "Falha ao gerar token para $node: $token"
        fi
    }
    echo "$token"
}

# -----------------------------------------------------------------------------
# Idempotencia: nao destruir instalacao existente sem explicitar
# -----------------------------------------------------------------------------
if snap list microceph >/dev/null 2>&1; then
    if microceph status >/dev/null 2>&1; then
        if [[ "$FRESH_INSTALL" == "1" ]]; then
            log "Cluster MicroCeph ativo detectado. FRESH_INSTALL=1 -> removendo com --purge..."
            snap remove microceph --purge
        else
            log "Cluster MicroCeph ja ativo. Reutilizando e gerando token para $NOVO_NODE_NAME."
            TOKEN_SAIDA=$(generate_token_for_node "$NOVO_NODE_NAME")
            echo "$TOKEN_SAIDA"
            exit 0
        fi
    else
        if [[ "$FRESH_INSTALL" == "1" ]]; then
            log "Instalacao incompleta detectada. FRESH_INSTALL=1 -> removendo com --purge..."
            snap remove microceph --purge
        else
            fail "MicroCeph instalado, mas cluster nao inicializado. Use FRESH_INSTALL=1."
        fi
    fi
fi

# Aguarda snapd terminar a remocao antes de instalar novamente
for attempt in $(seq 1 30); do
    if ! snap list microceph >/dev/null 2>&1; then
        break
    fi
    log "Aguardando snapd finalizar remocao do microceph (tentativa $attempt/30)..."
    sleep 2
done
if snap list microceph >/dev/null 2>&1; then
    fail "Snap microceph ainda presente apos tentativa de remocao."
fi

# -----------------------------------------------------------------------------
# Instalacao
# -----------------------------------------------------------------------------
log "Instalando MicroCeph pelo canal $MICROCEPH_CHANNEL..."
snap install microceph --channel="$MICROCEPH_CHANNEL"
snap refresh --hold microceph

log "Aguardando servico microceph ficar ativo..."
for attempt in $(seq 1 30); do
    if systemctl is-active --quiet snap.microceph.daemon.service 2>/dev/null; then
        break
    fi
    log "Servico microceph nao ativo (tentativa $attempt/30). Aguardando 10s..."
    sleep 10
done
if ! systemctl is-active --quiet snap.microceph.daemon.service 2>/dev/null; then
    fail "Servico microceph nao ficou ativo apos instalacao."
fi

log "MicroCeph instalado e servico ativo."

# -----------------------------------------------------------------------------
# Bootstrap
# -----------------------------------------------------------------------------
log "Executando bootstrap..."

BOOTSTRAP_ARGS=(
    --microceph-ip "$VPN_IP"
    --mon-ip "$VPN_IP"
    --public-network "$PUBLIC_NETWORK"
)
if [[ -n "${CLUSTER_NETWORK:-}" ]]; then
    BOOTSTRAP_ARGS+=(--cluster-network "$CLUSTER_NETWORK")
fi

# Executa bootstrap com retry; em alguns ambientes ocorre timeout por carga
BOOTSTRAP_OUT=$(sudo microceph cluster bootstrap "${BOOTSTRAP_ARGS[@]}" 2>&1) || {
    if echo "$BOOTSTRAP_OUT" | grep -qi "context deadline exceeded"; then
        log "Bootstrap retornou timeout. Aguardando daemon estabilizar para verificar..."
        for attempt in $(seq 1 12); do
            sleep 10
            if sudo microceph status >/dev/null 2>&1; then
                log "Cluster ativo apesar do timeout."
                break
            fi
            log "Aguardando cluster (tentativa $attempt/12)..."
        done
        if ! sudo microceph status >/dev/null 2>&1; then
            fail "Bootstrap falhou e cluster nao ficou ativo: $BOOTSTRAP_OUT"
        fi
    else
        fail "Bootstrap falhou: $BOOTSTRAP_OUT"
    fi
}

log "Aguardando daemon estabilizar..."
sleep 5

# -----------------------------------------------------------------------------
# OSD local (configuravel)
# -----------------------------------------------------------------------------
if [[ -n "$OSD_DEVICE" ]]; then
    log "Adicionando dispositivo OSD: $OSD_DEVICE"
    sudo microceph disk add "$OSD_DEVICE"
fi

# -----------------------------------------------------------------------------
# Ajusta configuracoes do Ceph para cluster pequeno (2 OSDs)
# -----------------------------------------------------------------------------
log "Ajustando osd_pool_default_size e tolerancia a clock skew..."
sudo microceph.ceph config set mon mon_clock_drift_allowed 0.5 || true
sudo microceph.ceph config set mon mon_clock_drift_warn_backoff 5 || true
sudo microceph.ceph config set global osd_pool_default_size 2 || true
sudo microceph.ceph config set global osd_pool_default_min_size 1 || true

# -----------------------------------------------------------------------------
# Token de join para o primeiro worker
# -----------------------------------------------------------------------------
TOKEN_SAIDA=$(generate_token_for_node "$NOVO_NODE_NAME")

log "Bootstrap concluido."
# Apenas o token vai para stdout (orquestrador o captura)
echo "$TOKEN_SAIDA"
