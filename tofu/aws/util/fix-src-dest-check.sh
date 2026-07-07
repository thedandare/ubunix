#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -a C_IDS C_IPS C_STATUS
while IFS=$'\t' read -r zone id ip; do
  [[ -z "$ip" || "$ip" == "None" ]] && continue
  eni_id=$(aws ec2 describe-instances --instance-ids "$id" \
    --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' \
    --output text 2>/dev/null)
  src_dst=$(aws ec2 describe-network-interfaces --network-interface-ids "$eni_id" \
    --query 'NetworkInterfaces[0].SourceDestCheck' \
    --output text 2>/dev/null)
  C_IDS+=("$id")
  C_IPS+=("$ip")
  C_STATUS+=("$src_dst")
done < <("$SCRIPT_DIR/describe-ips.sh") || true

if [[ ${#C_IDS[@]} -eq 0 ]]; then
  echo "Nenhuma instancia encontrada." >&2
  exit 1
fi

FARGS=()
for i in "${!C_IDS[@]}"; do
  status="${C_STATUS[$i]}"
  label="${C_IPS[$i]}  ${C_IDS[$i]}  src_dest=${status}"
  checked="off"
  [[ "$status" == "True" ]] && checked="on"
  FARGS+=("${C_IDS[$i]}" "$label" "$checked")
done

TO_FIX=$(dialog --title "Source/Dest Check" \
  --checklist "Instancias marcadas tem source_dest_check=True (deve ser False para bridge funcionar).\nDesmarque as que NAO quer corrigir:" \
  22 90 14 "${FARGS[@]}" 3>&1 1>&2 2>&3) || exit 0

if [[ -z "$TO_FIX" ]]; then
  echo "Nenhuma instancia selecionada para correcao."
  exit 0
fi

read -ra FIX_IDS <<< "$TO_FIX"
for iid in "${FIX_IDS[@]}"; do
  eni_id=$(aws ec2 describe-instances --instance-ids "$iid" \
    --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' \
    --output text 2>/dev/null)
  echo "Desabilitando source_dest_check em $iid (ENI: $eni_id)..."
  aws ec2 modify-network-interface-attribute \
    --network-interface-id "$eni_id" \
    --no-source-dest-check
  echo "  OK"
done
