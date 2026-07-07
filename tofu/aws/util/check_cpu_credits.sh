#!/usr/bin/env bash
#
# check_cpu_credits.sh — Descobre instâncias burstable (T2/T3/T3a/T4g) e exibe
# o balanço de CPU credits via CloudWatch.
#
# Métricas consultadas (namespace AWS/EC2, período 300s = 5 min):
#   CPUCreditBalance         — créditos acumulados disponíveis para burst
#   CPUCreditUsage           — créditos gastos no último período
#   CPUSurplusCreditBalance  — créditos surplus gastos (modo unlimited apenas)
#   CPUSurplusCreditsCharged — créditos surplus cobrados (modo unlimited apenas)
#
# Tabela de créditos extraída da doc oficial:
#   https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-credits-baseline-concepts.html
#
# Uso:
#   ./check_cpu_credits.sh [horas]
#   ./check_cpu_credits.sh 12   # analisa últimas 12h (default: 6)
#
set -euo pipefail

# ── Cores ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

cecho() { printf "${1}%s${NC}\n" "$2"; }

# ── Tabela de créditos (fonte: AWS docs) ─────────────────────────────────────
# formato: tipo|credits_per_hour|max_credits|vcpus|baseline_percent
CREDIT_TABLE=(
  "t2.nano|3|72|1|5"
  "t2.micro|6|144|1|10"
  "t2.small|12|288|1|20"
  "t2.medium|24|576|2|20"
  "t2.large|36|864|2|30"
  "t2.xlarge|54|1296|4|22.5"
  "t2.2xlarge|81.6|1958.4|8|17"
  "t3.nano|6|144|2|5"
  "t3.micro|12|288|2|10"
  "t3.small|24|576|2|20"
  "t3.medium|24|576|2|20"
  "t3.large|36|864|2|30"
  "t3.xlarge|96|2304|4|40"
  "t3.2xlarge|192|4608|8|40"
  "t3a.nano|6|144|2|5"
  "t3a.micro|12|288|2|10"
  "t3a.small|24|576|2|20"
  "t3a.medium|24|576|2|20"
  "t3a.large|36|864|2|30"
  "t3a.xlarge|96|2304|4|40"
  "t3a.2xlarge|192|4608|8|40"
  "t4g.nano|6|144|2|5"
  "t4g.micro|12|288|2|10"
  "t4g.small|24|576|2|20"
  "t4g.medium|24|576|2|20"
  "t4g.large|36|864|2|30"
  "t4g.xlarge|96|2304|4|40"
  "t4g.2xlarge|192|4608|8|40"
)

get_credit_info() {
  local itype="$1"
  for entry in "${CREDIT_TABLE[@]}"; do
    local t="${entry%%|*}"
    if [[ "$t" == "$itype" ]]; then
      echo "$entry"
      return 0
    fi
  done
  return 1
}

# ── Argumentos ───────────────────────────────────────────────────────────────
HOURS="${1:-6}"
if ! [[ "$HOURS" =~ ^[0-9]+$ ]] || [[ "$HOURS" -lt 1 ]]; then
  cecho "$RED" "Erro: horas deve ser um número inteiro >= 1"
  exit 1
fi

START_TIME=$(date -u -d "${HOURS} hours ago" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -v-${HOURS}H +%Y-%m-%dT%H:%M:%S)
END_TIME=$(date -u +%Y-%m-%dT%H:%M:%S)

# ── Descobrir instâncias burstable ───────────────────────────────────────────
cecho "$CYAN" "Buscando instâncias burstable (T2/T3/T3a/T4g) na região atual..."
cecho "$CYAN" "Janela de análise: últimas ${HOURS}h (${START_TIME} → ${END_TIME} UTC)"
echo ""

INSTANCES_JSON=$(aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
            "Name=instance-type,Values=t2.*,t3.*,t3a.*,t4g.*" \
  --query 'Reservations[].Instances[]' \
  --output json 2>/dev/null || echo "[]")

INSTANCE_COUNT=$(echo "$INSTANCES_JSON" | jq 'length')

if [[ "$INSTANCE_COUNT" -eq 0 ]]; then
  cecho "$YELLOW" "Nenhuma instância burstable encontrada."
  exit 0
fi

cecho "$GREEN" "Encontradas ${INSTANCE_COUNT} instância(s) burstable."
echo ""

# ── Função para buscar métrica do CloudWatch ─────────────────────────────────
get_metric() {
  local metric_name="$1"
  local instance_id="$2"

  aws cloudwatch get-metric-statistics \
    --namespace AWS/EC2 \
    --metric-name "$metric_name" \
    --dimensions Name=InstanceId,Value="$instance_id" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --period 300 \
    --statistics Average \
    --output json 2>/dev/null
}

get_latest_value() {
  echo "$1" | jq -r '
    if .Datapoints | length > 0 then
      [.Datapoints[] | {Timestamp, Average}]
      | sort_by(.Timestamp)
      | last
      | .Average
    else
      "N/A"
    end
  '
}

# ── Coletar dados de todas as instâncias (uma passada) ───────────────────────
TMP_DATA=$(mktemp)
trap 'rm -f "$TMP_DATA"' EXIT

echo "$INSTANCES_JSON" | jq -c '.[]' | while IFS= read -r instance; do
  INSTANCE_ID=$(echo "$instance" | jq -r '.InstanceId')
  INSTANCE_TYPE=$(echo "$instance" | jq -r '.InstanceType')
  NAME_TAG=$(echo "$instance" | jq -r '.Tags[]? | select(.Key=="Name") | .Value // empty')
  [[ -z "$NAME_TAG" ]] && NAME_TAG="-"

  CREDIT_INFO=$(get_credit_info "$INSTANCE_TYPE" || echo "")
  if [[ -n "$CREDIT_INFO" ]]; then
    IFS='|' read -r _ CREDITS_HR MAX_CREDITS VCPUS BASELINE_PCT <<< "$CREDIT_INFO"
  else
    CREDITS_HR="?" MAX_CREDITS="?" VCPUS="?" BASELINE_PCT="?"
  fi

  CREDIT_SPEC=$(aws ec2 describe-instance-credit-specifications \
    --instance-ids "$INSTANCE_ID" \
    --query 'InstanceCreditSpecifications[0].CpuCredits' \
    --output text 2>/dev/null || echo "unknown")

  BALANCE=$(get_latest_value "$(get_metric "CPUCreditBalance" "$INSTANCE_ID")")
  USAGE=$(get_latest_value "$(get_metric "CPUCreditUsage" "$INSTANCE_ID")")
  SURPLUS=$(get_latest_value "$(get_metric "CPUSurplusCreditBalance" "$INSTANCE_ID")")
  SURPLUS_CHARGED=$(get_latest_value "$(get_metric "CPUSurplusCreditsCharged" "$INSTANCE_ID")")

  STATUS="NO DATA"
  STATUS_COLOR="$YELLOW"
  BALANCE_PCT=""
  BURST_MIN=""

  if [[ "$BALANCE" != "N/A" ]] && [[ "$MAX_CREDITS" != "?" ]]; then
    BALANCE_PCT=$(awk "BEGIN {printf \"%.0f\", ($BALANCE / $MAX_CREDITS) * 100}")
    BURST_MIN=$(awk "BEGIN {printf \"%.0f\", $BALANCE / $VCPUS}")

    if [[ "$BALANCE_PCT" -le 10 ]]; then
      STATUS="CRITICAL"
      STATUS_COLOR="$RED"
    elif [[ "$BALANCE_PCT" -le 30 ]]; then
      STATUS="WARNING"
      STATUS_COLOR="$YELLOW"
    else
      STATUS="HEALTHY"
      STATUS_COLOR="$GREEN"
    fi
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$INSTANCE_ID" "$NAME_TAG" "$INSTANCE_TYPE" "$VCPUS" "$CREDITS_HR" \
    "$MAX_CREDITS" "$BASELINE_PCT" "$CREDIT_SPEC" "$BALANCE" "$USAGE" \
    "$SURPLUS" "$SURPLUS_CHARGED" "$STATUS" "$STATUS_COLOR" "$BALANCE_PCT" "$BURST_MIN" \
    >> "$TMP_DATA"
done

# ── Tabela resumo ────────────────────────────────────────────────────────────
printf "${BOLD}%-20s %-16s %-12s %-6s %-8s %-10s %-10s %-12s %-10s${NC}\n" \
  "Instance ID" "Name" "Type" "vCPU" "Earn/h" "MaxCred" "Balance" "Surplus" "Status"
printf '%.0s-' {1..120}
echo ""

while IFS=$'\t' read -r ID NAME TYPE VCPUS CHR MCRED BASELINE CSPEC BAL USAGE SURPLUS SCHR STATUS SCOLOR BPCT BMIN; do
  SURPLUS_DISP="$SURPLUS"
  if [[ "$SURPLUS" != "N/A" ]] && [[ "$SURPLUS" != "0" ]] && [[ "$SURPLUS" != "0.0" ]]; then
    SURPLUS_DISP="${SURPLUS}!"
  fi
  printf "%-20s %-16s %-12s %-6s %-8s %-10s %-10s %-12s " \
    "$ID" "${NAME:0:16}" "$TYPE" "$VCPUS" "$CHR" "$MCRED" "$BAL" "$SURPLUS_DISP"
  printf "${SCOLOR}%-10s${NC}\n" "$STATUS"
done < "$TMP_DATA"

echo ""
printf '%.0s-' {1..120}
echo ""

# ── Detalhes por instância ───────────────────────────────────────────────────
cecho "$BOLD" "DETALHES POR INSTÂNCIA"
echo ""

while IFS=$'\t' read -r ID NAME TYPE VCPUS CHR MCRED BASELINE CSPEC BAL USAGE SURPLUS SCHR STATUS SCOLOR BPCT BMIN; do
  printf "  ${BOLD}┌─ %s${NC} (%s)\n" "$ID" "$NAME"
  printf "  │  Tipo:            %s\n" "$TYPE"
  printf "  │  vCPUs:           %s\n" "$VCPUS"
  printf "  │  Créditos/hora:   %s\n" "$CHR"
  printf "  │  Máx. créditos:   %s\n" "$MCRED"
  printf "  │  Baseline/vCPU:   %s%%\n" "$BASELINE"
  printf "  │  Modo:            %s\n" "$CSPEC"

  if [[ "$BAL" != "N/A" ]] && [[ "$MCRED" != "?" ]]; then
    BPCT_FMT=$(awk "BEGIN {printf \"%.1f\", ($BAL / $MCRED) * 100}")
    printf "  │  Balanço atual:   %s / %s (%s%%)\n" "$BAL" "$MCRED" "$BPCT_FMT"
  else
    printf "  │  Balanço atual:   %s\n" "$BAL"
  fi

  printf "  │  Uso (5min):      %s créditos\n" "$USAGE"

  if [[ "$CSPEC" == "unlimited" ]]; then
    printf "  │  Surplus bal:     %s\n" "$SURPLUS"
    printf "  │  Surplus cobrado: %s\n" "$SCHR"
  fi

  if [[ -n "$BMIN" ]]; then
    printf "  │  Burst @ 100%%:    ~%s min restantes\n" "$BMIN"
  fi

  printf "  │  Status:          ${SCOLOR}%s${NC}\n" "$STATUS"
  printf "  ${BOLD}└─${NC}\n"
  echo ""
done < "$TMP_DATA"

# ── Legenda ──────────────────────────────────────────────────────────────────
cecho "$BOLD" "LEGENDA:"
echo "  Earn/h       — Créditos ganhos por hora (constante, mesmo em idle)"
echo "  MaxCred      — Limite máximo de créditos acumuláveis (24h de earn rate)"
echo "  Balance      — CPUCreditBalance atual (créditos disponíveis para burst)"
echo "  Surplus      — CPUSurplusCreditBalance (gasto além do balanço, modo unlimited)"
echo "  Status:"
cecho "$GREEN"  "    HEALTHY  — Balanço > 30% do máximo"
cecho "$YELLOW" "    WARNING  — Balanço 10-30% do máximo"
cecho "$RED"    "    CRITICAL — Balanço < 10% do máximo (risco de throttling)"
echo ""
echo "  Fontes:"
echo "    https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-performance-instances-monitoring-cpu-credits.html"
echo "    https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-credits-baseline-concepts.html"
