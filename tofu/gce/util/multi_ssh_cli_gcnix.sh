#!/usr/bin/env bash
set -euo pipefail

SESSION="gcnix"
ZONE_BASE="europe-southwest1"
SSH_PORT=22

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -n nodes

P0="$(tmux display-message -p -t "$SESSION:nodes" '#{pane_id}')"
P1="$(tmux split-window -h -t "$P0" -P -F '#{pane_id}')"
P2="$(tmux split-window -h -t "$P1" -P -F '#{pane_id}')"

tmux select-layout -t "$SESSION:nodes" even-horizontal

runpane() {
  local pane="$1"
  local name="$2"
  local idx="${name: -1}"
  local zone_letters=(a b c)
  local ZONE="${ZONE_BASE}-${zone_letters[$idx]}"

  if [[ $# -ge 3 ]]; then
    shift 2
    local cmd="$*"
    tmux send-keys -t "$pane" \
      "clear; echo '=== $name ==='; gcloud compute ssh $name --zone $ZONE --ssh-flag='-p $SSH_PORT' --command=$(printf '%q' "$cmd")" C-m
  else
    tmux send-keys -t "$pane" \
      "clear; echo '=== $name ==='; gcloud compute ssh $name --zone $ZONE --ssh-flag='-p $SSH_PORT'" C-m
  fi
}

if [[ $# -gt 0 ]]; then
  runpane "$P0" "gcnix0" "$@"
  runpane "$P1" "gcnix1" "$@"
  runpane "$P2" "gcnix2" "$@"
else
  runpane "$P0" "gcnix0"
  runpane "$P1" "gcnix1"
  runpane "$P2" "gcnix2"
fi

tmux attach -t "$SESSION"
