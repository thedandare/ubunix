#!/bin/bash
# ==============================================================================
# SCRIPT DE JOIN DE NÓ WORKER NO MICROCEPH
# ==============================================================================
# Uso: sudo microceph_join.sh <TOKEN> <IP_DO_LIDER>
#
# Opcoes (variaveis de ambiente):
#   MICROCEPH_CHANNEL   canal do snap (padrao: squid/stable)
#   VPN_INTERFACE       tailscale0 | wt0 | etc. (auto-detectado)
#   PUBLIC_NETWORK      CIDR da rede publica do Ceph (padrao: rede da VPN)
#   OSD_DEVICE          loop,N | /dev/sdb | etc. (padrao: loop,4G,1)
#   FRESH_INSTALL       1 = remove microceph existente com confirmacao
# ==============================================================================
set -euo pipefail

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
fail() { log "ERRO: $*"; exit 1; }

# -----------------------------------------------------------------------------
# Validacao de argumentos e permissao
# -----------------------------------------------------------------------------
if [[ "$#" -ne 2 ]]; then
    fail "Uso: sudo $0 <TOKEN> <IP_DO_LIDER>"
fi
TOKEN_MICROCEPH="$1"
PRIMARY_LEADER_IP="$2"

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
    fail "Nenhuma interface VPN detectada. Especifique VPN_INTERFACE."
fi

LOCAL_VPN_IP=$(ip -4 addr show dev "$VPN_INTERFACE" 2>/dev/null | grep -oP '(?<=inet )\d+(\.\d+){3}' | head -1)
if [[ -z "$LOCAL_VPN_IP" ]]; then
    fail "Interface $VPN_INTERFACE nao possui IPv4 valido."
fi
log "Interface VPN: $VPN_INTERFACE  IP: $LOCAL_VPN_IP"

# -----------------------------------------------------------------------------
# Validacao de conectividade com o lider
# -----------------------------------------------------------------------------
log "Verificando conectividade com o lider $PRIMARY_LEADER_IP..."
if ! ping -c 2 -W 3 "$PRIMARY_LEADER_IP" >/dev/null 2>&1; then
    fail "Sem rota ICMP ate o lider $PRIMARY_LEADER_IP via VPN."
fi
log "Rota ate o lider OK."

# -----------------------------------------------------------------------------
# Redes Ceph
# -----------------------------------------------------------------------------
if [[ -z "${PUBLIC_NETWORK:-}" ]]; then
    fail "PUBLIC_NETWORK nao definido. Passe explicitamente (ex: 100.64.0.0/10 para Tailscale)."
fi
log "Public network: $PUBLIC_NETWORK"

# -----------------------------------------------------------------------------
# Idempotencia
# -----------------------------------------------------------------------------
if snap list microceph >/dev/null 2>&1; then
    if [[ "$FRESH_INSTALL" == "1" ]]; then
        log "Instalacao existente detectada. FRESH_INSTALL=1 -> removendo com --purge..."
        snap remove microceph --purge
    else
        fail "MicroCeph ja esta instalado. Use FRESH_INSTALL=1 para recriar ou reutilize a instancia existente."
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

log "Aguardando snapd terminar de carregar..."
snap wait system seed.loaded

# Verifica se o comando microceph esta disponivel
if ! command -v microceph >/dev/null 2>&1; then
    fail "Comando 'microceph' nao encontrado apos instalacao."
fi

# Verifica se o servico do microceph esta ativo antes de usar o socket de controle
if ! systemctl is-active --quiet snap.microceph.daemon.service 2>/dev/null; then
    log "Servico microceph nao esta ativo. Aguardando 30s..."
    sleep 30
    if ! systemctl is-active --quiet snap.microceph.daemon.service 2>/dev/null; then
        fail "Servico microceph nao ficou ativo apos instalacao."
    fi
fi

log "MicroCeph instalado e servico ativo."

# -----------------------------------------------------------------------------
# Join
# -----------------------------------------------------------------------------
log "Executando cluster join no lider $PRIMARY_LEADER_IP..."
sudo microceph cluster join "$TOKEN_MICROCEPH" \
    --microceph-ip "$LOCAL_VPN_IP"

log "Aguardando sincronizacao de chaves..."
sleep 5

# -----------------------------------------------------------------------------
# OSD local
# -----------------------------------------------------------------------------
if [[ -n "$OSD_DEVICE" ]]; then
    log "Adicionando dispositivo OSD: $OSD_DEVICE"
    sudo microceph disk add "$OSD_DEVICE"
fi

log "Join concluido com sucesso."
