#!/usr/bin/env bash
#
# check_cpu_credits_tui.sh — Versão interativa (whiptail) do verificador de
# CPU credits para instâncias burstable (T2/T3/T3a/T4g).
#
# Fluxo interativo:
#   1) Tela de introdução (comentários / documentação do script)
#   2) Tela de seleção de REGIÃO (lista dinâmica via AWS, com fallback estático)
#   3) Tela para definir a janela de análise (horas)
#   4) Barra de progresso enquanto coleta métricas do CloudWatch
#   5) Relatório em textbox rolável (resumo + detalhes + legenda)
#   6) Menu final: outra região / reexecutar / sair
#
# Métricas consultadas (namespace AWS/EC2, período 300s = 5 min):
#   CPUCreditBalance         — créditos acumulados disponíveis para burst
#   CPUCreditUsage           — créditos gastos no último período
#   CPUSurplusCreditBalance  — créditos surplus gastos (modo unlimited apenas)
#   CPUSurplusCreditsCharged — créditos surplus cobrados (modo unlimited apenas)
#
# Fontes:
#   https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-credits-baseline-concepts.html
#   https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-performance-instances-monitoring-cpu-credits.html
#
set -uo pipefail

# O que significa set -euo pipefail
# São três (na verdade quatro) opções ligadas de uma vez:
# -e (errexit) — encerra o script na hora em que qualquer comando retorna status diferente de zero (ou seja, "falhou"), sem você ter tratado esse erro. O detalhe traiçoeiro: no shell, "falhar" não é só erro grave. Um grep que não acha nada retorna 1. Uma comparação aritmética falsa (( x > 10 )) retorna 1. Um aws sem credencial retorna 1. Com -e, qualquer um desses fecha tudo imediatamente.
# -u (nounset) — encerra se você usar uma variável que nunca foi definida. Ex.: se $REGION ainda não existe e você faz echo "$REGION", o script morre em vez de tratar como vazio.
# -o pipefail — num pipe A | B | C, normalmente o shell só olha o status do último comando (C). Com pipefail, se qualquer etapa falhar, o pipe inteiro é considerado falho. Combinado com -e, isso derruba o script.
# Então "fecha assim que inicia" geralmente é: logo no comecinho, algum comando retorna não-zero (um tput num terminal estranho, um aws sem permissão, uma aritmética que deu falsa), e o -e encerra tudo antes de qualquer tela aparecer.


# ── Dependências ─────────────────────────────────────────────────────────────
need() { command -v "$1" >/dev/null 2>&1 || { echo "Erro: '$1' não encontrado. $2" >&2; exit 1; }; }
need whiptail "Instale: apt install whiptail (Debian/Ubuntu) ou dnf install newt (RHEL/Fedora)."
need aws      "Instale a AWS CLI: https://docs.aws.amazon.com/cli/"
need jq        "Instale: apt install jq / dnf install jq / brew install jq."

# ── Tabela de créditos (fonte: AWS docs) ─────────────────────────────────────
# formato: tipo|credits_per_hour|max_credits|vcpus|baseline_percent
CREDIT_TABLE=(
  "t2.nano|3|72|1|5"          "t2.micro|6|144|1|10"      "t2.small|12|288|1|20"
  "t2.medium|24|576|2|20"     "t2.large|36|864|2|30"     "t2.xlarge|54|1296|4|22.5"
  "t2.2xlarge|81.6|1958.4|8|17"
  "t3.nano|6|144|2|5"         "t3.micro|12|288|2|10"     "t3.small|24|576|2|20"
  "t3.medium|24|576|2|20"     "t3.large|36|864|2|30"     "t3.xlarge|96|2304|4|40"
  "t3.2xlarge|192|4608|8|40"
  "t3a.nano|6|144|2|5"        "t3a.micro|12|288|2|10"    "t3a.small|24|576|2|20"
  "t3a.medium|24|576|2|20"    "t3a.large|36|864|2|30"    "t3a.xlarge|96|2304|4|40"
  "t3a.2xlarge|192|4608|8|40"
  "t4g.nano|6|144|2|5"        "t4g.micro|12|288|2|10"    "t4g.small|24|576|2|20"
  "t4g.medium|24|576|2|20"    "t4g.large|36|864|2|30"    "t4g.xlarge|96|2304|4|40"
  "t4g.2xlarge|192|4608|8|40"
)

get_credit_info() {
  local itype="$1" entry t
  for entry in "${CREDIT_TABLE[@]}"; do
    t="${entry%%|*}"
    [[ "$t" == "$itype" ]] && { echo "$entry"; return 0; }
  done
  return 1
}

# ── Rótulos amigáveis de região (fallback: "região AWS") ─────────────────────
declare -A REGION_LABELS=(
  [us-east-1]="US East (N. Virginia)"      [us-east-2]="US East (Ohio)"
  [us-west-1]="US West (N. California)"     [us-west-2]="US West (Oregon)"
  [ca-central-1]="Canada (Central)"         [sa-east-1]="South America (São Paulo)"
  [eu-west-1]="Europe (Ireland)"            [eu-west-2]="Europe (London)"
  [eu-west-3]="Europe (Paris)"              [eu-central-1]="Europe (Frankfurt)"
  [eu-central-2]="Europe (Zurich)"          [eu-north-1]="Europe (Stockholm)"
  [eu-south-1]="Europe (Milan)"             [ap-south-1]="Asia Pacific (Mumbai)"
  [ap-southeast-1]="Asia Pacific (Singapore)" [ap-southeast-2]="Asia Pacific (Sydney)"
  [ap-northeast-1]="Asia Pacific (Tokyo)"   [ap-northeast-2]="Asia Pacific (Seoul)"
  [ap-northeast-3]="Asia Pacific (Osaka)"   [ap-east-1]="Asia Pacific (Hong Kong)"
  [me-south-1]="Middle East (Bahrain)"      [af-south-1]="Africa (Cape Town)"
)
STATIC_REGIONS="us-east-1 us-east-2 us-west-1 us-west-2 ca-central-1 sa-east-1
eu-west-1 eu-west-2 eu-west-3 eu-central-1 eu-north-1 ap-south-1
ap-southeast-1 ap-southeast-2 ap-northeast-1 ap-northeast-2"

# ── Dimensões adaptativas dos diálogos ───────────────────────────────────────
term_dims() {
  local L C
  L=$(tput lines 2>/dev/null || echo 24)
  C=$(tput cols  2>/dev/null || echo 80)
  BOX_H=$(( L > 12 ? L - 4 : 8 ))
  BOX_W=$(( C > 24 ? C - 6 : 72 ))
  (( BOX_W > 110 )) && BOX_W=110
}

# ── TELA 1: introdução (os comentários iniciais) ─────────────────────────────
show_intro() {
  term_dims
  local txt
  txt="check_cpu_credits — Monitor de CPU Credits (instâncias burstable)
--------------------------------------------------------------------

Este utilitário descobre instâncias T2/T3/T3a/T4g em execução na região
escolhida e mostra o balanço de CPU credits consultando o CloudWatch.

Métricas consultadas (namespace AWS/EC2, período de 5 min):

  • CPUCreditBalance         créditos disponíveis para burst
  • CPUCreditUsage           créditos gastos no último período
  • CPUSurplusCreditBalance  surplus gasto (somente modo unlimited)
  • CPUSurplusCreditsCharged surplus cobrado (somente modo unlimited)

Status calculado a partir do balanço vs. máximo acumulável:

  HEALTHY   balanço > 30% do máximo
  WARNING   balanço entre 10% e 30% do máximo
  CRITICAL  balanço < 10% do máximo (risco de throttling)

Pré-requisitos: AWS CLI configurada, jq e permissões para
ec2:DescribeInstances, ec2:DescribeInstanceCreditSpecifications e
cloudwatch:GetMetricStatistics.

Fontes:
  docs.aws.amazon.com — burstable-credits-baseline-concepts
  docs.aws.amazon.com — burstable-performance-instances-monitoring-cpu-credits

Pressione OK para escolher a região."
  whiptail --title "Sobre este script" --scrolltext --msgbox "$txt" "$BOX_H" "$BOX_W"
}

# ── Regiões: busca dinâmica + fallback ───────────────────────────────────────
fetch_regions() {
  local out
  out=$(AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}" aws ec2 describe-regions \
        --all-regions --query 'Regions[].RegionName' --output text 2>/dev/null) || out=""
  echo "$out" | tr '\t ' '\n\n' | sed '/^$/d' | sort -u
}

# ── TELA 2: seleção de região ────────────────────────────────────────────────
select_region() {
  local regions r
  regions=$(fetch_regions)
  [[ -z "$regions" ]] && regions="$STATIC_REGIONS"

  local menu=()
  while IFS= read -r r; do
    [[ -z "$r" ]] && continue
    menu+=( "$r" "${REGION_LABELS[$r]:-região AWS}" )
  done < <(echo "$regions" | tr ' ' '\n' | sed '/^$/d')

  # regra prática de altura de lista
  local n=$(( ${#menu[@]} / 2 ))
  local lh=$(( n < 14 ? n : 14 ))

  if REGION=$(whiptail --title "Selecione a região AWS" \
        --menu "Escolha a região onde procurar instâncias burstable:" \
        22 74 "$lh" "${menu[@]}" 3>&1 1>&2 2>&3); then
    return 0
  fi
  return 1  # cancelado
}

# ── TELA 3: janela de análise (horas) ────────────────────────────────────────
ask_hours() {
  while true; do
    local h
    if h=$(whiptail --title "Janela de análise" \
          --inputbox "Analisar métricas das últimas quantas horas?\n(inteiro >= 1)" \
          10 60 "6" 3>&1 1>&2 2>&3); then
      if [[ "$h" =~ ^[0-9]+$ ]] && (( h >= 1 )); then
        HOURS="$h"
        return 0
      fi
      whiptail --title "Valor inválido" --msgbox "Informe um número inteiro >= 1." 8 50
    else
      return 1  # cancelado -> volta ao menu anterior
    fi
  done
}

compute_times() {
  START_TIME=$(date -u -d "${HOURS} hours ago" +%Y-%m-%dT%H:%M:%S 2>/dev/null \
             || date -u -v-"${HOURS}"H +%Y-%m-%dT%H:%M:%S)
  END_TIME=$(date -u +%Y-%m-%dT%H:%M:%S)
}

# ── Descobrir instâncias burstable na região selecionada ─────────────────────
discover_instances() {
  INSTANCES_JSON=$(aws ec2 describe-instances \
    --filters "Name=instance-state-name,Values=running" \
              "Name=instance-type,Values=t2.*,t3.*,t3a.*,t4g.*" \
    --query 'Reservations[].Instances[]' \
    --output json 2>/dev/null || echo "[]")
  INSTANCE_COUNT=$(echo "$INSTANCES_JSON" | jq 'length')
}

# ── CloudWatch helpers ───────────────────────────────────────────────────────
get_metric() {
  local metric_name="$1" instance_id="$2"
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
      [.Datapoints[] | {Timestamp, Average}] | sort_by(.Timestamp) | last | .Average
    else "N/A" end'
}

# ── Processa UMA instância e grava linha (TAB) no TMP_DATA ────────────────────
# IMPORTANTE: não escreve nada em stdout (stdout alimenta o gauge).
process_instance() {
  local instance="$1"
  local INSTANCE_ID INSTANCE_TYPE NAME_TAG CREDIT_INFO
  local CREDITS_HR MAX_CREDITS VCPUS BASELINE_PCT CREDIT_SPEC
  local BALANCE USAGE SURPLUS SURPLUS_CHARGED
  local STATUS BALANCE_PCT BURST_MIN

  INSTANCE_ID=$(echo "$instance"   | jq -r '.InstanceId')
  INSTANCE_TYPE=$(echo "$instance" | jq -r '.InstanceType')
  NAME_TAG=$(echo "$instance" | jq -r '.Tags[]? | select(.Key=="Name") | .Value // empty')
  [[ -z "$NAME_TAG" ]] && NAME_TAG="-"

  if CREDIT_INFO=$(get_credit_info "$INSTANCE_TYPE"); then
    IFS='|' read -r _ CREDITS_HR MAX_CREDITS VCPUS BASELINE_PCT <<< "$CREDIT_INFO"
  else
    CREDITS_HR="?"; MAX_CREDITS="?"; VCPUS="?"; BASELINE_PCT="?"
  fi

  CREDIT_SPEC=$(aws ec2 describe-instance-credit-specifications \
    --instance-ids "$INSTANCE_ID" \
    --query 'InstanceCreditSpecifications[0].CpuCredits' \
    --output text 2>/dev/null || echo "unknown")

  BALANCE=$(get_latest_value "$(get_metric "CPUCreditBalance" "$INSTANCE_ID")")
  USAGE=$(get_latest_value "$(get_metric "CPUCreditUsage" "$INSTANCE_ID")")
  SURPLUS=$(get_latest_value "$(get_metric "CPUSurplusCreditBalance" "$INSTANCE_ID")")
  SURPLUS_CHARGED=$(get_latest_value "$(get_metric "CPUSurplusCreditsCharged" "$INSTANCE_ID")")

  STATUS="NO DATA"; BALANCE_PCT=""; BURST_MIN=""
  if [[ "$BALANCE" != "N/A" && "$MAX_CREDITS" != "?" ]]; then
    BALANCE_PCT=$(awk "BEGIN {printf \"%.0f\", ($BALANCE / $MAX_CREDITS) * 100}")
    BURST_MIN=$(awk "BEGIN {printf \"%.0f\", $BALANCE / $VCPUS}")
    if   (( BALANCE_PCT <= 10 )); then STATUS="CRITICAL"
    elif (( BALANCE_PCT <= 30 )); then STATUS="WARNING"
    else                               STATUS="HEALTHY"
    fi
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$INSTANCE_ID" "$NAME_TAG" "$INSTANCE_TYPE" "$VCPUS" "$CREDITS_HR" \
    "$MAX_CREDITS" "$BASELINE_PCT" "$CREDIT_SPEC" "$BALANCE" "$USAGE" \
    "$SURPLUS" "$SURPLUS_CHARGED" "$STATUS" "$BALANCE_PCT" "$BURST_MIN" \
    >> "$TMP_DATA"
}

# ── TELA 4: coleta com barra de progresso ────────────────────────────────────
collect_data() {
  : > "$TMP_DATA"
  local total="$INSTANCE_COUNT"
  {
    local i=0 pct iid
    echo "$INSTANCES_JSON" | jq -c '.[]' | while IFS= read -r instance; do
      i=$((i + 1))
      pct=$(( (i - 1) * 100 / total ))
      iid=$(echo "$instance" | jq -r '.InstanceId')
      echo "$pct"
      echo "XXX"; echo "Analisando ${iid}  (${i}/${total})"; echo "XXX"
      process_instance "$instance"
    done
    echo 100
  } | whiptail --title "Coletando" --gauge "Consultando CloudWatch..." 8 74 0
}

# ── TELA 5: relatório em texto simples (sem ANSI, para o textbox) ─────────────
build_report() {
  local report="$1"
  {
    echo "RELATÓRIO DE CPU CREDITS"
    echo "Região:  ${AWS_DEFAULT_REGION}"
    echo "Janela:  últimas ${HOURS}h  (${START_TIME} -> ${END_TIME} UTC)"
    echo "Instâncias burstable em execução: ${INSTANCE_COUNT}"
    echo ""
    printf "%-20s %-16s %-11s %-5s %-7s %-8s %-9s %-9s %-9s\n" \
      "Instance ID" "Name" "Type" "vCPU" "Earn/h" "MaxCred" "Balance" "Surplus" "Status"
    printf '%.0s-' {1..100}; echo ""

    while IFS=$'\t' read -r ID NAME TYPE VCPUS CHR MCRED BASELINE CSPEC \
                            BAL USAGE SURPLUS SCHR STATUS BPCT BMIN; do
      local sdisp="$SURPLUS"
      if [[ "$SURPLUS" != "N/A" && "$SURPLUS" != "0" && "$SURPLUS" != "0.0" ]]; then
        sdisp="${SURPLUS}!"
      fi
      printf "%-20s %-16s %-11s %-5s %-7s %-8s %-9s %-9s %-9s\n" \
        "$ID" "${NAME:0:16}" "$TYPE" "$VCPUS" "$CHR" "$MCRED" "$BAL" "$sdisp" "$STATUS"
    done < "$TMP_DATA"

    echo ""
    printf '%.0s=' {1..100}; echo ""
    echo "DETALHES POR INSTÂNCIA"
    echo ""

    while IFS=$'\t' read -r ID NAME TYPE VCPUS CHR MCRED BASELINE CSPEC \
                            BAL USAGE SURPLUS SCHR STATUS BPCT BMIN; do
      printf "  +- %s (%s)\n" "$ID" "$NAME"
      printf "  |  Tipo:            %s\n" "$TYPE"
      printf "  |  vCPUs:           %s\n" "$VCPUS"
      printf "  |  Créditos/hora:   %s\n" "$CHR"
      printf "  |  Máx. créditos:   %s\n" "$MCRED"
      printf "  |  Baseline/vCPU:   %s%%\n" "$BASELINE"
      printf "  |  Modo:            %s\n" "$CSPEC"
      if [[ "$BAL" != "N/A" && "$MCRED" != "?" ]]; then
        local pf; pf=$(awk "BEGIN {printf \"%.1f\", ($BAL / $MCRED) * 100}")
        printf "  |  Balanço atual:   %s / %s (%s%%)\n" "$BAL" "$MCRED" "$pf"
      else
        printf "  |  Balanço atual:   %s\n" "$BAL"
      fi
      printf "  |  Uso (5min):      %s créditos\n" "$USAGE"
      if [[ "$CSPEC" == "unlimited" ]]; then
        printf "  |  Surplus bal:     %s\n" "$SURPLUS"
        printf "  |  Surplus cobrado: %s\n" "$SCHR"
      fi
      [[ -n "$BMIN" ]] && printf "  |  Burst @ 100%%:    ~%s min restantes\n" "$BMIN"
      printf "  |  Status:          %s\n" "$STATUS"
      printf "  +-\n\n"
    done < "$TMP_DATA"

    echo "LEGENDA"
    echo "  Earn/h    Créditos ganhos por hora (constante, mesmo em idle)"
    echo "  MaxCred   Limite máximo acumulável (24h de earn rate)"
    echo "  Balance   CPUCreditBalance atual (disponível para burst)"
    echo "  Surplus   CPUSurplusCreditBalance ( '!' = > 0, modo unlimited)"
    echo "  Status    HEALTHY >30%  |  WARNING 10-30%  |  CRITICAL <10%"
  } > "$report"
}

show_report() {
  term_dims
  whiptail --title "CPU Credits — ${AWS_DEFAULT_REGION}" \
    --scrolltext --textbox "$1" "$BOX_H" "$BOX_W"
}

# ── Menu pós-relatório ───────────────────────────────────────────────────────
post_menu() {
  local c
  c=$(whiptail --title "Próximo passo" --menu "O que deseja fazer?" 12 60 3 \
        "1" "Escolher outra região" \
        "2" "Reexecutar nesta região" \
        "3" "Sair" 3>&1 1>&2 2>&3) || c="3"
  echo "$c"
}

# ── Temp + limpeza ───────────────────────────────────────────────────────────
TMP_DATA=$(mktemp)
REPORT=$(mktemp)
trap 'rm -f "$TMP_DATA" "$REPORT"; clear 2>/dev/null || true' EXIT

# ── Fluxo principal ──────────────────────────────────────────────────────────
show_intro

while true; do
  select_region || { echo "Cancelado."; exit 0; }
  export AWS_DEFAULT_REGION="$REGION"

  ask_hours || continue      # cancelou horas -> volta a escolher região
  compute_times

  discover_instances
  if [[ "$INSTANCE_COUNT" -eq 0 ]]; then
    whiptail --title "Sem resultados" \
      --msgbox "Nenhuma instância burstable (T2/T3/T3a/T4g) em execução na região ${REGION}." 9 60
    case "$(post_menu)" in
      1) continue ;;
      2) continue ;;   # sem instâncias, reexecutar recai em escolher horas/região
      *) exit 0 ;;
    esac
  fi

  collect_data
  build_report "$REPORT"
  show_report "$REPORT"

  case "$(post_menu)" in
    1) continue ;;                                   # outra região
    2) ask_hours || continue; compute_times          # reexecuta nesta região
       discover_instances; collect_data
       build_report "$REPORT"; show_report "$REPORT"
       # após reexecução, volta ao topo do loop para novo menu
       ;;
    *) exit 0 ;;
  esac
done