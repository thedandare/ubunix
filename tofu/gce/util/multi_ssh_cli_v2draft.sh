#!/usr/bin/env bash
set -euo pipefail

SESSION="gcnix"
SSH_PORT=2409

runpane() {
  local pane="$1"
  local name="$2"
  local zone="$3"

  if [[ $# -ge 4 ]]; then
    shift 3
    local cmd="$*"
    local quoted_cmd
    quoted_cmd=$(printf '%q' "$cmd")
    tmux send-keys -t "$pane" \
      "clear; echo '=== $name ==='; gcloud compute ssh $name --zone $zone --ssh-flag='-p $SSH_PORT' --command=$quoted_cmd" C-m
  else
    tmux send-keys -t "$pane" \
      "clear; echo '=== $name ==='; gcloud compute ssh $name --zone $zone --ssh-flag='-p $SSH_PORT'" C-m
  fi
}

# Coleta nome, zone e ip via gcloud
NAMES=()
ZONES=()
IPS=()
while IFS=$'\t' read -r name zone ip; do
  [[ -z "$ip" || "$ip" == "None" ]] && continue
  NAMES+=("$name")
  ZONES+=("$zone")
  IPS+=("$ip")
done < <(gcloud compute instances list \
  --filter='status:RUNNING' \
  --format='table[no-heading](name,zone,networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null) || true

if [[ ${#IPS[@]} -eq 0 ]]; then
  echo "No public IPs found." >&2
  exit 1
fi

# Descobre regioes unicas e conta nodes por regiao
# zona -> region (remove o ultimo hifen+letra, e.g. us-east5-a -> us-east5)
declare -A REGIONS
for i in "${!ZONES[@]}"; do
  region="${ZONES[$i]%-*}"
  REGIONS["$region"]=1
done

# Monta args do dialog checklist
DARGS=()
for region in $(echo "${!REGIONS[@]}" | tr ' ' '\n' | sort); do
  count=0
  for i in "${!ZONES[@]}"; do
    [[ "${ZONES[$i]%-*}" == "$region" ]] && ((++count))
  done
  DARGS+=("all_${region}" ">> Selecionar todos (${count}) -- ${region}" "off")
done

for i in "${!IPS[@]}"; do
  DARGS+=("node${i}" "${ZONES[$i]}  ${IPS[$i]}  ${NAMES[$i]}" "off")
done

# Mostra menu de selecao
SELECTED=$(dialog --title "Selecionar nodes SSH" \
  --checklist "Marque uma regiao para selecionar todos, ou escolha nodes individuais:" \
  22 80 14 "${DARGS[@]}" 3>&1 1>&2 2>&3) || exit 0

if [[ -z "$SELECTED" ]]; then
  echo "Nenhum node selecionado." >&2
  exit 1
fi

read -ra SEL_TAGS <<< "$SELECTED"

# Processa selecao
declare -A EXPANDED
for tag in "${SEL_TAGS[@]}"; do
  if [[ "$tag" == all_* ]]; then
    region="${tag#all_}"
    for i in "${!ZONES[@]}"; do
      [[ "${ZONES[$i]%-*}" == "$region" ]] && EXPANDED[$i]=1
    done
  else
    idx="${tag#node}"
    EXPANDED[$idx]=1
  fi
done

# Lista final de indices na ordem
FINAL_IDX=()
for i in "${!IPS[@]}"; do
  [[ -n "${EXPANDED[$i]:-}" ]] && FINAL_IDX+=("$i")
done

if [[ ${#FINAL_IDX[@]} -eq 0 ]]; then
  echo "Nenhum node selecionado." >&2
  exit 1
fi

# Cria sessao tmux
tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -n nodes

# Cria panes dinamicamente
PANES=()
COUNT=${#FINAL_IDX[@]}

if [[ $COUNT -le 3 ]]; then
  PANES+=("$(tmux display-message -p -t "$SESSION:nodes" '#{pane_id}')")
  for ((j = 1; j < COUNT; j++)); do
    PANES+=("$(tmux split-window -h -t "${PANES[-1]}" -P -F '#{pane_id}')")
  done
  tmux select-layout -t "$SESSION:nodes" even-horizontal
else
  COL1=$(tmux display-message -p -t "$SESSION:nodes" '#{pane_id}')
  COL2=$(tmux split-window -h -t "$COL1" -P -F '#{pane_id}')
  COL3=$(tmux split-window -h -t "$COL2" -P -F '#{pane_id}')

  ROW1_COL1=$COL1
  ROW1_COL2=$COL2
  ROW1_COL3=$COL3

  if [[ $COUNT -gt 3 ]]; then
    ROW2_COL1=$(tmux split-window -v -t "$COL1" -P -F '#{pane_id}')
    ROW2_COL2=$(tmux split-window -v -t "$COL2" -P -F '#{pane_id}')
    ROW2_COL3=$(tmux split-window -v -t "$COL3" -P -F '#{pane_id}')
  fi

  if [[ $COUNT -gt 6 ]]; then
    ROW3_COL1=$(tmux split-window -v -t "$ROW2_COL1" -P -F '#{pane_id}')
    ROW3_COL2=$(tmux split-window -v -t "$ROW2_COL2" -P -F '#{pane_id}')
    ROW3_COL3=$(tmux split-window -v -t "$ROW2_COL3" -P -F '#{pane_id}')
  fi

  PANES=("$ROW1_COL1" "$ROW1_COL2" "$ROW1_COL3")
  [[ $COUNT -gt 3 ]] && PANES+=("$ROW2_COL1" "$ROW2_COL2" "$ROW2_COL3")
  [[ $COUNT -gt 6 ]] && PANES+=("$ROW3_COL1" "$ROW3_COL2" "$ROW3_COL3")
fi

# Conecta
for j in "${!FINAL_IDX[@]}"; do
  idx="${FINAL_IDX[$j]}"
  name="${NAMES[$idx]}"
  zone="${ZONES[$idx]}"
  if [[ $# -gt 0 ]]; then
    runpane "${PANES[$j]}" "$name" "$zone" "$@"
  else
    runpane "${PANES[$j]}" "$name" "$zone"
  fi
done

tmux attach -t "$SESSION"
