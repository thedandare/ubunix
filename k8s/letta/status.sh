#!/usr/bin/env bash
set -euo pipefail

SSH_HOST="${SSH_HOST:-root@35.215.33.107}"
SSH_KEY="${SSH_KEY:-/mnt/c/Users/leo/.ssh/root_id_ed25519}"

if [ ! -f "$SSH_KEY" ] && [ -f "/c/Users/leo/.ssh/root_id_ed25519" ]; then
  SSH_KEY="/c/Users/leo/.ssh/root_id_ed25519"
fi

if [ ! -f "$SSH_KEY" ]; then
  echo "SSH key not found: $SSH_KEY" >&2
  exit 1
fi

ssh -o PubkeyAcceptedKeyTypes=+ssh-ed25519 -i "$SSH_KEY" "$SSH_HOST" 'set +e
printf "=== Letta workload ===\n"
microk8s kubectl -n letta get deployment,pod -o wide

printf "\n=== Service and endpoints ===\n"
microk8s kubectl -n letta get service,endpoints -o wide

printf "\n=== Persistent storage ===\n"
microk8s kubectl -n letta get pvc -o wide

printf "\n=== Pod details ===\n"
microk8s kubectl -n letta describe pod -l app=letta-app-server | tail -60

printf "\n=== Node disk status ===\n"
for node in $(microk8s kubectl -n letta get pod -l app=letta-app-server -o jsonpath="{.items[*].spec.nodeName}" 2>/dev/null); do
  echo "--- $node ---"
  microk8s kubectl describe node "$node" | grep -A8 -E "Conditions:|Allocated resources:"
done

printf "\n=== Recent events ===\n"
microk8s kubectl -n letta get events --sort-by=.lastTimestamp | tail -30
'
