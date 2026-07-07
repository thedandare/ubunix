#!/usr/bin/env bash
#
# 10-drain-k8s.sh — Hook de exemplo: drena nodes MicroK8s antes do término.
#
# Argumentos (passados pelo spot-termination-handler.sh):
#   $1 = action   (terminate | stop | hibernate)
#   $2 = time     (ISO 8601 UTC do término agendado)
#
set -euo pipefail

ACTION="${1:-unknown}"
TERMINATION_TIME="${2:-unknown}"

MK8S="microk8s"
if ! command -v microk8s &>/dev/null; then
  MK8S="/var/snap/microk8s/current/bin/microk8s"
fi

if ! [[ -x "$MK8S" ]]; then
  echo "MicroK8s não encontrado — pulando drain"
  exit 0
fi

echo "Drenando nodes MicroK8s (action=${ACTION}, time=${TERMINATION_TIME})"

NODES=$($MK8S kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null) || exit 0

for node in $NODES; do
  echo "Cordon: ${node}"
  $MK8S kubectl cordon "$node" 2>/dev/null || true

  echo "Drain: ${node}"
  $MK8S kubectl drain "$node" \
    --force \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --timeout=60s \
    2>/dev/null || true
done

echo "Drain concluído"
