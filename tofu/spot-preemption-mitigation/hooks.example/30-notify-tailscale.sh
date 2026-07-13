#!/usr/bin/env bash
#
# 30-notify-tailscale.sh — Hook de exemplo: notifica via Tailscale que o node
# está sendo removido (opcional — limpa entradas stale do Tailscale).
#
# Argumentos (passados pelo spot-termination-handler.sh):
#   $1 = action   (terminate | stop | hibernate)
#   $2 = time     (ISO 8601 UTC do término agendado)
#
set -euo pipefail

ACTION="${1:-unknown}"

if ! command -v tailscale &>/dev/null; then
  echo "Tailscale não encontrado — pulando"
  exit 0
fi

echo "Notificando Tailscale (action=${ACTION})"

# Desconecta do Tailscale graciosamente
tailscale down 2>/dev/null || true

echo "Tailscale desconectado"
