#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# integrar-microceph-microk8s-local.sh
#
# Versão local (host Incus, sem SSH) do integrar-microceph-microk8s.sh.
# Executa os passos de integração via 'incus exec' direto no container master.
#
# Uso:
#   ./integrar-microceph-microk8s-local.sh [nome-do-container-master]
#
# Se o nome do container não for informado, detecta o primeiro container
# amnix-XXXX em estado RUNNING.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTEGRATION_SCRIPT_PATH="$SCRIPT_DIR/integrar-microceph-microk8s.sh"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] AVISO: $*" >&2; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERRO: $*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Container master
# ------------------------------------------------------------------------------
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    MASTER_CONTAINER="$1"
    log "Container master informado: $MASTER_CONTAINER"
else
    MASTER_CONTAINER=$(incus list -c n,s --format csv 2>/dev/null \
        | grep ',RUNNING$' \
        | grep -m1 'amnix-' \
        | cut -d',' -f1 \
        | tr -d '\n' || echo "")
    if [[ -z "$MASTER_CONTAINER" ]]; then
        fail "Nenhum container amnix RUNNING encontrado. Passe o nome do container master como argumento."
    fi
    log "Container master detectado: $MASTER_CONTAINER"
fi

# ------------------------------------------------------------------------------
# Validações
# ------------------------------------------------------------------------------
if [[ ! -f "$INTEGRATION_SCRIPT_PATH" ]]; then
    fail "Script de integração não encontrado: $INTEGRATION_SCRIPT_PATH"
fi

state=$(incus list -c n,s --format csv 2>/dev/null | grep "^${MASTER_CONTAINER}," | cut -d',' -f2 || echo "")
if [[ "$state" != "RUNNING" ]]; then
    fail "Container $MASTER_CONTAINER não está RUNNING (estado: ${state:-não encontrado})"
fi

# ------------------------------------------------------------------------------
# Copia o script original para dentro do container e executa
# ------------------------------------------------------------------------------
log "Copiando integrar-microceph-microk8s.sh para ${MASTER_CONTAINER}:/root/"
incus file push "$INTEGRATION_SCRIPT_PATH" "${MASTER_CONTAINER}/root/integrar-microceph-microk8s.sh"
incus exec "$MASTER_CONTAINER" -- chmod 700 /root/integrar-microceph-microk8s.sh

log "Executando integração dentro de ${MASTER_CONTAINER}..."
incus exec "$MASTER_CONTAINER" -- bash /root/integrar-microceph-microk8s.sh

log "Integração concluída."
