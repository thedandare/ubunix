#!/usr/bin/env bash
set -euo pipefail

SESSION="amnix"

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -n nodes

P0="$(tmux display-message -p -t "$SESSION:nodes" '#{pane_id}')"
P1="$(tmux split-window -h -t "$P0" -P -F '#{pane_id}')"
P2="$(tmux split-window -h -t "$P1" -P -F '#{pane_id}')"

tmux select-layout -t "$SESSION:nodes" even-horizontal

runpane() {
  local pane="$1"
  local name="$2"
  local ip="$3"

  if [[ $# -ge 4 ]]; then
    shift 3
    local cmd="$*"
    tmux send-keys -t "$pane" \
      "clear; echo '=== $name ==='; sudo ssh -tt -i /root/.ssh/root_id_ed25519 -p 2409 root@$ip -- bash -lc $(printf '%q' "$cmd")" C-m
  else
    tmux send-keys -t "$pane" \
      "clear; echo '=== $name ==='; sudo  ssh -tt -i /root/.ssh/root_id_ed25519 -p 2409 root@$ip" C-m
  fi
}

if [[ $# -gt 0 ]]; then
  runpane "$P0" "amnix0s" "18.228.117.205" "$@"
  runpane "$P1" "amnix1s" "54.20.45.195" "$@"
  runpane "$P2" "amnix2s" "54.20.64.51" "$@"
else
  runpane "$P0" "amnix0s" "18.228.117.205"
  runpane "$P1" "amnix1s" "54.20.45.195"
  runpane "$P2" "amnix2s" "54.20.64.51"
fi

tmux attach -t "$SESSION"