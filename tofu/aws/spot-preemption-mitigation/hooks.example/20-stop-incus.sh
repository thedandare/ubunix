#!/usr/bin/env bash
#
# 20-stop-incus.sh — Hook de exemplo: para containers Incus graciosamente.
#
# Argumentos (passados pelo spot-termination-handler.sh):
#   $1 = action   (terminate | stop | hibernate)
#   $2 = time     (ISO 8601 UTC do término agendado)
#
set -euo pipefail

ACTION="${1:-unknown}"

if ! command -v incus &>/dev/null; then
  echo "Incus não encontrado — pulando"
  exit 0
fi

echo "Parando containers Incus (action=${ACTION})"

CONTAINERS=$(incus list -c n --format csv 2>/dev/null) || exit 0

for ct in $CONTAINERS; do
  echo "Parando: ${ct}"
  incus stop "$ct" --timeout 60 2>/dev/null || true
done

echo "Containers Incus parados"
