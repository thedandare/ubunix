#!/usr/bin/env bash
set -eo pipefail

SESSION="amnix"
SSH_PORT=2409
SSH_KEY=/root/.ssh/root_id_ed25519

runpane() {
  local pane="$1"
  local name="$2"
  local ip="$3"

  if [[ $# -ge 4 ]]; then
    shift 3
    local cmd="$*"
    local quoted_cmd
    quoted_cmd=$(printf '%q' "$cmd")
    local ssh_cmd="sudo ssh -tt -o StrictHostKeyChecking=accept-new -i $SSH_KEY -p $SSH_PORT root@$ip -- bash -lc $quoted_cmd"
    echo "[DEBUG] pane $pane -> $ssh_cmd" >&2
    tmux send-keys -t "$pane" \
      "clear; echo '=== $name ==='; echo '$ssh_cmd'; $ssh_cmd" C-m
  else
    local ssh_cmd="sudo ssh -tt -o StrictHostKeyChecking=accept-new -i $SSH_KEY -p $SSH_PORT root@$ip"
    echo "[DEBUG] pane $pane -> $ssh_cmd" >&2
    tmux send-keys -t "$pane" \
      "clear; echo '=== $name ==='; echo '$ssh_cmd'; $ssh_cmd" C-m
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Coleta zone, instance-id, ip
ZONES=(); IDS=(); IPS=()
while IFS=$'\t' read -r zone id ip; do
  [[ -z "$ip" || "$ip" == "None" ]] && continue
  ZONES+=("$zone")
  IDS+=("$id")
  IPS+=("$ip")
done < <("$SCRIPT_DIR/describe-ips.sh") || true

if [[ ${#IPS[@]} -eq 0 ]]; then
  echo "No public IPs found." >&2
  exit 1
fi

# Descobre regioes unicas e conta nodes por regiao
declare -A REGIONS
for i in "${!ZONES[@]}"; do
  region="${ZONES[$i]%?}"  # remove ultima letra da zone -> region
  REGIONS["$region"]=1
done

# Monta args do dialog checklist
# Primeiro: botoes de region (marcar todos)
DARGS=()
for region in $(echo "${!REGIONS[@]}" | tr ' ' '\n' | sort); do
  count=0
  for i in "${!ZONES[@]}"; do
    [[ "${ZONES[$i]%?}" == "$region" ]] && ((++count))
  done
  DARGS+=("all_${region}" ">> Selecionar todos (${count}) -- ${region}" "off")
done

# Depois: nodes individuais
for i in "${!IPS[@]}"; do
  DARGS+=("node${i}" "${ZONES[$i]}  ${IPS[$i]}  ${IDS[$i]}" "off")
done

# Mostra menu de selecao (dialog escreve em stderr, capturamos com 3>&1)
SELECTED=$(dialog --title "Selecionar nodes SSH" \
  --checklist "Marque uma regiao para selecionar todos, ou escolha nodes individuais:" \
  22 80 14 "${DARGS[@]}" 3>&1 1>&2 2>&3) || exit 0

if [[ -z "$SELECTED" ]]; then
  echo "Nenhum node selecionado." >&2
  exit 1
fi

read -ra SEL_TAGS <<< "$SELECTED"

# Processa selecao: expande "all_REGION" para todos os nodes daquela regiao
declare -A EXPANDED
for tag in "${SEL_TAGS[@]}"; do
  if [[ "$tag" == all_* ]]; then
    region="${tag#all_}"
    for i in "${!ZONES[@]}"; do
      [[ "${ZONES[$i]%?}" == "$region" ]] && EXPANDED[$i]=1
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
  # Layout horizontal para ate 3 VMs
  PANES+=("$(tmux display-message -p -t "$SESSION:nodes" '#{pane_id}')")
  for ((j = 1; j < COUNT; j++)); do
    PANES+=("$(tmux split-window -h -t "${PANES[-1]}" -P -F '#{pane_id}')")
  done
  tmux select-layout -t "$SESSION:nodes" even-horizontal
else
  # Layout grid para mais de 3 VMs
  # Criar 3 colunas
  COL1=$(tmux display-message -p -t "$SESSION:nodes" '#{pane_id}')
  COL2=$(tmux split-window -h -t "$COL1" -P -F '#{pane_id}')
  COL3=$(tmux split-window -h -t "$COL2" -P -F '#{pane_id}')

  # Criar linhas conforme necessario
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

  # Ordenar panes em grid (linha por linha)
  PANES=("$ROW1_COL1" "$ROW1_COL2" "$ROW1_COL3")
  [[ $COUNT -gt 3 ]] && PANES+=("$ROW2_COL1" "$ROW2_COL2" "$ROW2_COL3")
  [[ $COUNT -gt 6 ]] && PANES+=("$ROW3_COL1" "$ROW3_COL2" "$ROW3_COL3")
fi

# Conecta
for j in "${!FINAL_IDX[@]}"; do
  idx="${FINAL_IDX[$j]}"
  name="amnix${idx}"
  ip="${IPS[$idx]}"
  if [[ $# -gt 0 ]]; then
    runpane "${PANES[$j]}" "$name" "$ip" "$@"
  else
    runpane "${PANES[$j]}" "$name" "$ip"
  fi
done

tmux attach -t "$SESSION"
