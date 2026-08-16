#!/bin/bash
set -eo pipefail

# ==============================================================================
# inicializar-cluster-microk8s.sh (GCE)
#
# Objetivo:
#   1) Escolher entre Tailscale ou Netbird para conectividade VPN
#   2) Trabalhar com as 3 instancias fixas gcnix0, gcnix1, gcnix2
#   3) Selecionar a instancia MASTER
#   4) Gerar um token por no no microk8s do host master (via add-node) e fazer join
#   5) Juntar os containers LXD (node0, node1) do proprio master e de cada host
#      worker ao cluster usando o IP VPN do master
#
# Reaproveita o mesmo padrao de conexao do multi_ssh_cli.sh (gcloud compute ssh).
# ==============================================================================

SSH_PORT=22
TOKEN_TTL=999999
ZONE_BASE="europe-southwest1"

# Instancias fixas do cluster
NAMES=("santiago0" "santiago1" "santiago2")
# NAMES=("gcnix0" "gcnix1" "gcnix2")
ZONE_LETTERS=(a b c)
ZONES=("${ZONE_BASE}-${ZONE_LETTERS[0]}" "${ZONE_BASE}-${ZONE_LETTERS[1]}" "${ZONE_BASE}-${ZONE_LETTERS[2]}")

# Containers LXD existentes dentro de cada VM GCE (conforme user_data.cloud-config.tftpl)
# Nomes serao definidos dinamicamente baseados no node_index da VM
CONTAINER_ROLES=("voter" "voter" "voter")

# Funcao para gerar nomes dos containers baseado no hostname_suffix
get_container_names() {
  local hostname_suffix="$1"
  local names=()
  for i in 1 2 3; do
    names+=("santiago-${i}")
  done
  echo "${names[@]}"
}

# Funcao para obter os nomes dos containers existentes em uma VM
get_existing_containers() {
  local vm_name="$1"
  local zone="$2"
  sshrun "$vm_name" "$zone" "lxc list -c n --format csv | grep 'amnix-' | tr '\n' ' '" 2>/dev/null || echo ""
}

sshrun() {
  # sshrun <nome-vm> <zone> <comando...>
  local name="$1"; shift
  local zone="$1"; shift
  gcloud compute ssh "$name" --zone "$zone" \
    --ssh-flag="-p $SSH_PORT" \
    --command="bash -lc $(printf '%q' "$*")"
}

get_tailscale_ip() {
  # get_tailscale_ip <nome-vm> <zone>  ->  imprime o IP tailscale do primeiro container
  local name="$1"
  local zone="$2"
  
  # Tenta obter do host primeiro
  local host_ip
  host_ip=$(gcloud compute ssh "$name" --zone "$zone" \
    --ssh-flag="-p $SSH_PORT" \
    --command="bash -lc 'tailscale ip -4 2>/dev/null'" 2>/dev/null | head -1)
  
  if [[ -n "$host_ip" ]]; then
    echo "$host_ip"
    return 0
  fi
  
  # Se não encontrar no host, busca no primeiro container
  local first_container
  first_container=$(gcloud compute ssh "$name" --zone "$zone" \
    --ssh-flag="-p $SSH_PORT" \
    --command="bash -lc 'lxc list -c n --format csv | grep amnix- | head -1 | tr -d \"\\n\"'" 2>/dev/null)
  
  if [[ -n "$first_container" ]]; then
    gcloud compute ssh "$name" --zone "$zone" \
      --ssh-flag="-p $SSH_PORT" \
      --command="bash -lc 'lxc exec $first_container -- tailscale ip -4 2>/dev/null'" 2>/dev/null | head -1
  fi
}

# ------------------------------------------------------------------------------
# 0. Escolha da VPN (Tailscale ou Netbird)
# ------------------------------------------------------------------------------
VPN_CHOICE=$(dialog --title "Escolher VPN" \
  --menu "Escolha qual VPN sera usada para conectividade do cluster:" \
  15 60 2 \
  "tailscale" "Tailscale (padrao)" \
  "netbird" "Netbird (IP range: 100.82.0.0/16)" \
  3>&1 1>&2 2>&3) || exit 0

if [[ "$VPN_CHOICE" == "netbird" ]]; then
  VPN_NAME="Netbird"
  VPN_INTERFACE="wt0"
  VPN_IP_RANGE="100.82.0.0/16"
else
  VPN_NAME="Tailscale"
  VPN_INTERFACE="tailscale0"
fi

clear
echo ">>> VPN selecionada: $VPN_NAME"
if [[ "$VPN_CHOICE" == "netbird" ]]; then
  echo "    Range de IP: $VPN_IP_RANGE"
fi
echo

# ------------------------------------------------------------------------------
# 1. Obtem IP VPN de cada instancia fixa
# ------------------------------------------------------------------------------
VPNIPS=()
echo ">>> Obtendo IPs $VPN_NAME dos hosts..."
for i in "${!NAMES[@]}"; do
  if [[ "$VPN_CHOICE" == "netbird" ]]; then
    vpn_ip=$(gcloud compute ssh "${NAMES[$i]}" --zone "${ZONES[$i]}" \
      --ssh-flag="-p $SSH_PORT" \
      --command="bash -lc 'ip addr show $VPN_INTERFACE 2>/dev/null | grep \"inet \" | awk \"{print \\\$2}\" | cut -d/ -f1 | head -1'") || true
  else
    vpn_ip=$(get_tailscale_ip "${NAMES[$i]}" "${ZONES[$i]}") || true
  fi

  if [[ -z "$vpn_ip" ]]; then
    echo "ERRO: nao foi possivel obter IP $VPN_NAME do host ${NAMES[$i]} (${ZONES[$i]})" >&2
    exit 1
  fi
  VPNIPS+=("$vpn_ip")
  echo "    ${NAMES[$i]} (${ZONES[$i]})  ->  $VPN_INTERFACE: $vpn_ip"
done
echo

# ------------------------------------------------------------------------------
# 2. Seleciona o node MASTER (menu de escolha unica)
# ------------------------------------------------------------------------------
MARGS=()
for i in "${!NAMES[@]}"; do
  MARGS+=("node${i}" "${ZONES[$i]}  ${VPN_INTERFACE}=${VPNIPS[$i]}  ${NAMES[$i]}")
done

MASTER_TAG=$(dialog --title "Selecionar node MASTER" \
  --menu "Escolha a instancia que sera o master do cluster MicroK8s:" \
  20 80 12 "${MARGS[@]}" 3>&1 1>&2 2>&3) || exit 0

MASTER_IDX="${MASTER_TAG#node}"
MASTER_IDX="${MASTER_IDX//\"/}"
MASTER_NAME="${NAMES[$MASTER_IDX]}"
MASTER_ZONE="${ZONES[$MASTER_IDX]}"

# ------------------------------------------------------------------------------
# 3. Seleciona os hosts WORKER (checklist, todos marcados por padrao, exceto o master)
# ------------------------------------------------------------------------------
WARGS=()
for i in "${!NAMES[@]}"; do
  [[ "$i" == "$MASTER_IDX" ]] && continue
  WARGS+=("node${i}" "${ZONES[$i]}  ${VPN_INTERFACE}=${VPNIPS[$i]}  ${NAMES[$i]}" "on")
done

WORKERS_SELECTED=$(dialog --title "Selecionar hosts WORKER" \
  --checklist "Cada host tera: host=voter  3 containers (1 voter + 2 workers)" \
  22 80 14 "${WARGS[@]}" 3>&1 1>&2 2>&3) || exit 0

if [[ -z "$WORKERS_SELECTED" ]]; then
  echo "Nenhum host worker selecionado." >&2
  exit 1
fi

read -ra WORKER_TAGS <<< "$WORKERS_SELECTED"
WORKER_IDX=()
for tag in "${WORKER_TAGS[@]}"; do
  WORKER_IDX+=("${tag#node}")
done

# Obter containers existentes do master
MASTER_CONTAINERS=($(get_existing_containers "$MASTER_NAME" "$MASTER_ZONE"))

clear
echo "=== Master selecionado: $MASTER_NAME (${ZONES[$MASTER_IDX]}  ${VPN_INTERFACE}=${VPNIPS[$MASTER_IDX]}) ==="
echo "    host = leader (ja inicializado)"
echo "    Containers encontrados: ${MASTER_CONTAINERS[*]}"
echo "    ${MASTER_CONTAINERS[0]} = voter  (join no proprio master)"
echo "    ${MASTER_CONTAINERS[1]} = worker (join no proprio master)"
echo "    ${MASTER_CONTAINERS[2]} = worker (join no proprio master)"
echo "=== Hosts worker selecionados: ${#WORKER_IDX[@]} ==="
for i in "${WORKER_IDX[@]}"; do
  # Obter containers existentes do worker
  WORKER_CONTAINERS=($(get_existing_containers "${NAMES[$i]}" "${ZONES[$i]}"))
  echo "  - ${NAMES[$i]} (${ZONES[$i]}  ${VPN_INTERFACE}=${VPNIPS[$i]})"
  echo "    host = voter"
  echo "    Containers encontrados: ${WORKER_CONTAINERS[*]}"
  echo "    ${WORKER_CONTAINERS[0]} = voter"
  echo "    ${WORKER_CONTAINERS[1]} = worker"
  echo "    ${WORKER_CONTAINERS[2]} = worker"
done
echo

# IP da VPN do host master
MASTER_VPN_IP="${VPNIPS[$MASTER_IDX]}"
echo ">>> IP $VPN_NAME do master (join endpoint): ${MASTER_VPN_IP}"
echo

# Funcao para verificar se um no ja esta no cluster
is_node_in_cluster() {
  local target_name="$1"
  local target_zone="$2"
  local target_type="$3"  # "host" ou nome do container
  
  local label
  if [[ "$target_type" == "host" ]]; then
    label="${target_name}/host"
    # Para hosts, verifica se o hostname aparece no kubectl get nodes
    local node_check
    node_check=$(sshrun "$MASTER_NAME" "$MASTER_ZONE" "sudo microk8s kubectl get nodes --no-headers | grep -q '^${target_name}'" 2>/dev/null && echo "yes" || echo "no")
    [[ "$node_check" == "yes" ]]
  else
    label="${target_name}/${target_type}"
    # Para containers, verifica se o container ja esta no cluster via status
    local status_check
    status_check=$(sshrun "$target_name" "$target_zone" "lxc exec ${target_type} -- sudo microk8s status --format yaml 2>/dev/null | grep -q 'high-availability: yes'" && echo "yes" || echo "no")
    [[ "$status_check" == "yes" ]]
  fi
}

# Funcao auxiliar: gera um token no master para um no especifico e faz o join
# Para o host, executa microk8s diretamente; para containers, via lxc exec.
do_join() {
  local target_name="$1"
  local target_zone="$2"
  local target_type="$3"  # "host" ou nome do container
  local role="$4"

  local label
  if [[ "$target_type" == "host" ]]; then
    label="${target_name}/host"
  else
    label="${target_name}/${target_type}"
  fi

  # Verifica se o no ja esta no cluster
  if is_node_in_cluster "$target_name" "$target_zone" "$target_type"; then
    echo ">>> [${label}] role=$role"
    echo "    SKIP: No ja esta no cluster."
    echo
    return 0
  fi

  echo ">>> [${label}] role=$role"
  echo "    Gerando token no master para este no..."
  local add_node_out
  add_node_out=$(sshrun "$MASTER_NAME" "$MASTER_ZONE" "sudo microk8s add-node --token-ttl ${TOKEN_TTL}" 2>&1)
  local NODE_TOKEN
  NODE_TOKEN=$(echo "$add_node_out" | grep -oP '(?<=join )\S+:25000/\S+' | head -1 | grep -oP '[^/]+$')
  if [[ -z "$NODE_TOKEN" ]]; then
    echo "    FALHA: nao foi possivel extrair token do add-node" >&2
    echo "    Saida do add-node: $add_node_out" >&2
    return 1
  fi
  echo "    Token gerado: ${NODE_TOKEN}"

  local JOIN_CMD="sudo microk8s join ${MASTER_VPN_IP}:25000/${NODE_TOKEN}"
  [[ "$role" == "worker" ]] && JOIN_CMD="$JOIN_CMD --worker"

  local full_cmd
  if [[ "$target_type" == "host" ]]; then
    full_cmd="$JOIN_CMD"
  else
    full_cmd="lxc exec ${target_type} -- sudo $JOIN_CMD"
  fi

  echo "    cmd: $JOIN_CMD"
  if sshrun "$target_name" "$target_zone" "$full_cmd"; then
    echo "    OK: ${label} entrou como $role."
  else
    echo "    FALHA: ${label}" >&2
  fi
  echo
}

# Aguarda microk8s estar pronto no host ou dentro de um container LXD
wait_microk8s() {
  local target_name="$1"
  local target_zone="$2"
  local target_type="$3"  # "host" ou nome do container
  local restarted=0
  local label="${target_name}/${target_type}"
  echo "    Aguardando microk8s ficar pronto em ${label}..."

  if [[ "$target_type" == "host" ]]; then
    status_cmd="sudo microk8s status --wait-ready --timeout 10"
    restart_cmd="sudo snap restart microk8s"
  else
    status_cmd="lxc exec ${target_type} -- sudo microk8s status --wait-ready --timeout 10"
    restart_cmd="lxc exec ${target_type} -- sudo snap restart microk8s"
  fi

  for attempt in $(seq 1 30); do
    if sshrun "$target_name" "$target_zone" "$status_cmd" 2>/dev/null; then
      return 0
    fi
    if [[ $restarted -eq 0 && $attempt -ge 3 ]]; then
      echo "    microk8s nao iniciou, tentando snap restart em ${label}..."
      sshrun "$target_name" "$target_zone" "$restart_cmd" 2>/dev/null || true
      restarted=1
      echo "    Aguardando 60s apos restart..."
      sleep 60
      continue
    fi
    echo "    tentativa $attempt/30 - aguardando 10s..."
    sleep 10
  done
  echo "    TIMEOUT: microk8s nao ficou pronto em ${label}" >&2
  return 1
}

# ------------------------------------------------------------------------------
# 5. Join dos containers LXD do proprio host master
# ------------------------------------------------------------------------------
echo "--- Juntando containers locais do master ---"
# MASTER_CONTAINERS já foi obtido anteriormente
for j in "${!MASTER_CONTAINERS[@]}"; do
  wait_microk8s "$MASTER_NAME" "$MASTER_ZONE" "${MASTER_CONTAINERS[$j]}"
  do_join "$MASTER_NAME" "$MASTER_ZONE" "${MASTER_CONTAINERS[$j]}" "${CONTAINER_ROLES[$j]}"
done

# ------------------------------------------------------------------------------
# 6. Join dos hosts e containers de cada host worker
# ------------------------------------------------------------------------------
for i in "${WORKER_IDX[@]}"; do
  host_name="${NAMES[$i]}"
  host_zone="${ZONES[$i]}"
  echo "--- Host worker: $host_name (${VPN_INTERFACE}=${VPNIPS[$i]}) ---"
  do_join "$host_name" "$host_zone" "host" "voter"
  # Obter containers existentes do worker
  WORKER_CONTAINERS=($(get_existing_containers "$host_name" "$host_zone"))
  for j in "${!WORKER_CONTAINERS[@]}"; do
    wait_microk8s "$host_name" "$host_zone" "${WORKER_CONTAINERS[$j]}"
    do_join "$host_name" "$host_zone" "${WORKER_CONTAINERS[$j]}" "${CONTAINER_ROLES[$j]}"
  done
done

echo "=== Verificando status do cluster no master ==="
sshrun "$MASTER_NAME" "$MASTER_ZONE" "sudo microk8s kubectl get nodes" || true

echo
echo "Concluido."
