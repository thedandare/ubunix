#!/usr/bin/env bash
set -eo pipefail

# ==============================================================================
# inicializar-cluster-microk8s.sh
#
# Objetivo:
#   1) Escolher entre Tailscale ou Netbird para conectividade VPN
#   2) Conectar via SSH na primeira instancia selecionada (master) e executar
#        microk8s add-node --token-ttl 999999
#   3) Extrair o comando de join gerado na saida do add-node
#   4) Conectar via SSH nas demais instancias selecionadas (workers) e
#      executar esse comando de join
#
# Reaproveita a mesma infra do script de conexao SSH (describe-ips.sh, SSH_KEY,
# SSH_PORT e o dialog de selecao de nodes).
#
# Conectividade via VPN:
#   - Tailscale: SSH nos hosts usa o IP da interface tailscale0 (obtido remotamente).
#               O join cross-host do microk8s usa o IP tailscale0 do host master.
#   - Netbird:  SSH nos hosts usa o IP da interface netbird (obtido remotamente).
#               Range de IP: 100.82.0.0/16
#               O join cross-host do microk8s usa o IP netbird do host master.
# ==============================================================================

SSH_PORT=2409
SSH_KEY=/root/.ssh/root_id_ed25519
TOKEN_TTL=999999

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sshrun() {
  # sshrun <public-ip> <comando...>
  local ip="$1"; shift
  sudo ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "$SSH_PORT" \
    "root@$ip" -- bash -lc "$(printf '%q' "$*")"
}

get_tailscale_ip() {
  # get_tailscale_ip <public-ip>  ->  imprime o IP tailscale do primeiro container amnix
  local pub_ip="$1"
  echo "    [DEBUG] SSH_KEY=[$SSH_KEY] SSH_PORT=[$SSH_PORT]" >&2
  echo "    [DEBUG] Listando containers em $pub_ip..." >&2
  local which_incus
  which_incus=$(timeout 15 sudo ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "$SSH_PORT" \
    "root@$pub_ip" -- which incus 2>&1)
  echo "    [DEBUG] which incus: [$which_incus]" >&2
  local incus_version
  incus_version=$(timeout 15 sudo ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "$SSH_PORT" \
    "root@$pub_ip" -- incus version 2>&1)
  echo "    [DEBUG] incus version: [$incus_version]" >&2
  local raw_list
  raw_list=$(timeout 15 sudo ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "$SSH_PORT" \
    "root@$pub_ip" -- incus list -c n --format csv 2>&1)
  echo "    [DEBUG] raw_list (no sudo): [$raw_list]" >&2
  if [[ -z "$raw_list" ]]; then
    local raw_list_sudo
    raw_list_sudo=$(timeout 15 sudo ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "$SSH_PORT" \
      "root@$pub_ip" -- sudo incus list -c n --format csv 2>&1)
    echo "    [DEBUG] raw_list (with sudo): [$raw_list_sudo]" >&2
    if [[ -n "$raw_list_sudo" ]]; then
      raw_list="$raw_list_sudo"
    fi
  fi
  local filtered_list
  filtered_list=$(echo "$raw_list" | grep 'amnix-' | sort -V)
  echo "    [DEBUG] filtered_list: [$filtered_list]" >&2
  local first_container
  first_container=$(echo "$filtered_list" | head -1 | tr -d '\n')
  echo "    [DEBUG] first_container: [$first_container]" >&2
  if [[ -z "$first_container" ]]; then
    echo "    ERRO: Nenhum container amnix encontrado" >&2
    return 1
  fi
  echo "    Obtendo IP Tailscale do container $first_container..." >&2
  local ts_ip
  ts_ip=$(timeout 15 sudo ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "$SSH_PORT" \
    "root@$pub_ip" -- incus exec "$first_container" -- tailscale ip -4 2>&1)
  echo "    [DEBUG] tailscale ip raw: [$ts_ip]" >&2
  echo "$ts_ip" | head -1
}

# Funcao para obter os nomes dos containers existentes em um host
get_existing_containers() {
  local pub_ip="$1"
  sudo ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "$SSH_PORT" \
    "root@$pub_ip" -- incus list -c n --format csv | grep 'amnix-' | sort -V | tr '\n' ' ' 2>/dev/null || echo ""
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
# 1. Coleta zone, instance-id, ip publico e ip da VPN
# ------------------------------------------------------------------------------
ZONES=(); IDS=(); IPS=(); VPNIPS=()
while IFS=$'\t' read -r zone id ip; do
  [[ -z "$ip" || "$ip" == "None" ]] && continue
  ZONES+=("$zone")
  IDS+=("$id")
  IPS+=("$ip")
done < <("$SCRIPT_DIR/describe-ips.sh") || true

if [[ "${#IPS[@]}" -lt 2 ]]; then
  echo "E' necessario pelo menos 2 instancias (1 master + 1 worker) para formar o cluster." >&2
  exit 1
fi

echo ">>> Obtendo IPs $VPN_NAME dos hosts (PARALELO)..."
PIDS=()
TEMP_FILES=()

# Função para obter IP VPN de um host em background
get_vpn_ip_bg() {
  local idx="$1"
  local ip="$2"
  local temp_file="/tmp/vpn_ip_$idx"
  
  echo "  [PARALELO] Conectando em $ip para obter IP $VPN_NAME..."
  local vpn_ip=""
  
  if [[ "$VPN_CHOICE" == "netbird" ]]; then
    echo "  [PARALELO] Obtendo primeiro container para Netbird..."
    first_container=$(timeout 30 sudo ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "$SSH_PORT" \
      "root@$ip" -- incus list -c n --format csv | grep 'amnix-' | sort -V | head -1 | tr -d '\n' 2>/dev/null)
    echo "  [PARALELO] Container encontrado: $first_container" >&2
    vpn_ip=$(timeout 30 sudo ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "$SSH_PORT" \
      "root@$ip" -- incus exec "$first_container" -- ip addr show wt0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -1) || true
  else
    echo "  [PARALELO] Obtendo IP Tailscale..." >&2
    vpn_ip=$(SSH_KEY="$SSH_KEY" SSH_PORT="$SSH_PORT" timeout 30 bash -c "$(declare -f get_tailscale_ip); get_tailscale_ip '$ip'") || true
  fi
  
  echo "$vpn_ip" > "$temp_file"
  if [[ -n "$vpn_ip" ]]; then
    echo "  [PARALELO] $ip -> $VPN_INTERFACE: $vpn_ip" >&2
  else
    echo "  [PARALELO] ERRO: nao foi possivel obter IP $VPN_NAME do host $ip" >&2
  fi
}

# Dispara busca de IPs VPN em paralelo
for i in "${!IPS[@]}"; do
  temp_file="/tmp/vpn_ip_$i"
  TEMP_FILES+=("$temp_file")
  get_vpn_ip_bg "$i" "${IPS[$i]}" &
  PIDS+=($!)
done

# Aguarda todas as buscas terminarem
echo ">>> Aguardando obtenção de IPs VPN..."
for pid in "${PIDS[@]}"; do
  wait "$pid"
done

# Coleta os resultados
echo ">>> Coletando resultados dos IPs VPN..."
for i in "${!IPS[@]}"; do
  temp_file="/tmp/vpn_ip_$i"
  vpn_ip=$(cat "$temp_file" 2>/dev/null || echo "")
  
  if [[ -z "$vpn_ip" ]]; then
    echo "ERRO: nao foi possivel obter IP $VPN_NAME do host ${IPS[$i]}" >&2
    exit 1
  fi
  VPNIPS+=("$vpn_ip")
  echo "    ${IPS[$i]}  ->  $VPN_INTERFACE: $vpn_ip"
  rm -f "$temp_file"
done
echo

# Containers serao obtidos dinamicamente
# Papel de cada container nos hosts worker:
CONTAINER_ROLES=("voter" "voter" "worker")

# ------------------------------------------------------------------------------
# 2. Seleciona o node MASTER (menu de escolha unica)
# ------------------------------------------------------------------------------
MARGS=()
for i in "${!IPS[@]}"; do
  MARGS+=("node${i}" "${ZONES[$i]}  ${IPS[$i]}  ${VPN_INTERFACE}=${VPNIPS[$i]}  ${IDS[$i]}")
done

MASTER_TAG=$(dialog --title "Selecionar node MASTER" \
  --menu "Escolha a instancia que sera o master do cluster MicroK8s:" \
  20 80 12 "${MARGS[@]}" 3>&1 1>&2 2>&3) || exit 0

MASTER_IDX="${MASTER_TAG#node}"
MASTER_IDX="${MASTER_IDX//\"/}"
MASTER_IP="${IPS[$MASTER_IDX]}"

# ------------------------------------------------------------------------------
# 3. Seleciona os hosts WORKER (checklist, todos marcados por padrao, exceto o master)
# ------------------------------------------------------------------------------
WARGS=()
for i in "${!IPS[@]}"; do
  [[ "$i" == "$MASTER_IDX" ]] && continue
  WARGS+=("node${i}" "${ZONES[$i]}  ${IPS[$i]}  ${VPN_INTERFACE}=${VPNIPS[$i]}  ${IDS[$i]}" "on")
done

WORKERS_SELECTED=$(dialog --title "Selecionar hosts WORKER" \
  --checklist "Cada host tera: 3 containers (1=voter, 2=voter, 3=worker)" \
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
MASTER_CONTAINERS=($(get_existing_containers "$MASTER_IP"))
MASTER_CONTAINER="${MASTER_CONTAINERS[0]}"

clear
echo "=== Master selecionado: pub=${MASTER_IP}  leader=${MASTER_CONTAINER}  ${VPN_INTERFACE}=${VPNIPS[$MASTER_IDX]} ==="
echo "    Containers encontrados: ${MASTER_CONTAINERS[*]}"
echo "    ${MASTER_CONTAINERS[0]} = leader (ja inicializado)"
echo "    ${MASTER_CONTAINERS[1]} = voter  (join no proprio master)"
echo "    ${MASTER_CONTAINERS[2]} = worker (join no proprio master)"
echo "=== Hosts worker selecionados: ${#WORKER_IDX[@]} ==="
for i in "${WORKER_IDX[@]}"; do
  WORKER_CONTAINERS=($(get_existing_containers "${IPS[$i]}"))
  echo "  - pub=${IPS[$i]}  ${WORKER_CONTAINERS[0]} ${VPN_INTERFACE}=${VPNIPS[$i]}"
  echo "    Containers encontrados: ${WORKER_CONTAINERS[*]}"
  echo "    ${WORKER_CONTAINERS[0]} = voter"
  echo "    ${WORKER_CONTAINERS[1]} = voter"
  echo "    ${WORKER_CONTAINERS[2]} = worker"
done
echo

# IP da VPN do container master ja disponivel em VPNIPS[$MASTER_IDX]
MASTER_CONTAINER_VPN_IP="${VPNIPS[$MASTER_IDX]}"
echo ">>> IP $VPN_NAME do ${MASTER_CONTAINER} (join endpoint): ${MASTER_CONTAINER_VPN_IP}"
echo

# Funcao auxiliar: gera um token no master para um no especifico e faz o join
do_join() {
  local target_ip="$1"
  local cname="$2"
  local role="$3"

  echo ">>> [${target_ip}/${cname}] role=$role"
  echo "    Gerando token no master para este no..."
  local add_node_out
  add_node_out=$(sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- sudo microk8s add-node --token-ttl -1" 2>&1)
  local NODE_TOKEN
  # Procura pela linha com o IP da VPN e extrai o token
  NODE_TOKEN=$(echo "$add_node_out" | grep "${MASTER_CONTAINER_VPN_IP}:25000" | grep -oP '(?<=join )\S+:25000/\S+' | head -1)
  
  # Se não encontrar com IP da VPN, pega o primeiro token válido
  if [[ -z "$NODE_TOKEN" ]]; then
    NODE_TOKEN=$(echo "$add_node_out" | grep -oP '(?<=join )\S+:25000/\S+' | head -1)
  fi
  if [[ -z "$NODE_TOKEN" ]]; then
    echo "    FALHA: nao foi possivel extrair token do add-node" >&2
    echo "    Saida do add-node: $add_node_out" >&2
    return 1
  fi
  echo "    Token gerado: ${NODE_TOKEN}"
  sleep 1

  local JOIN_CMD="sudo microk8s join ${NODE_TOKEN}"
  [[ "$role" == "worker" ]] && JOIN_CMD="$JOIN_CMD --worker"

  echo "    cmd: $JOIN_CMD"
  sleep 2
  if sshrun "$target_ip" "incus exec ${cname} -- $JOIN_CMD"; then
    echo "    OK: ${target_ip}/${cname} entrou como $role."
  else
    echo "    FALHA: ${target_ip}/${cname}" >&2
  fi
  echo
}

# Aguarda microk8s estar pronto dentro de um container
wait_microk8s() {
  local target_ip="$1"
  local cname="$2"
  local restarted=0
  echo "    Aguardando microk8s ficar pronto em ${target_ip}/${cname}..."
  for attempt in $(seq 1 30); do
    if sshrun "$target_ip" "incus exec ${cname} -- sudo microk8s status --wait-ready --timeout 10" 2>/dev/null; then
      return 0
    fi
    if [[ $restarted -eq 0 && $attempt -ge 3 ]]; then
      echo "    microk8s nao iniciou, tentando snap restart microk8s em ${cname}..."
      sshrun "$target_ip" "incus exec ${cname} -- sudo snap restart microk8s" 2>/dev/null || true
      restarted=1
      echo "    Aguardando 60s apos restart..."
      sleep 60
      continue
    fi
    echo "    tentativa $attempt/30 - aguardando 10s..."
    sleep 10
  done
  echo "    TIMEOUT: microk8s nao ficou pronto em ${target_ip}/${cname}" >&2
  return 1
}

# ------------------------------------------------------------------------------
# 5. Join dos containers do proprio host master
# ------------------------------------------------------------------------------
echo "--- Juntando containers locais do master ---"
for j in "${!MASTER_CONTAINERS[@]}"; do
  # Pula o primeiro container (leader)
  if [[ $j -eq 0 ]]; then continue; fi
  wait_microk8s "$MASTER_IP" "${MASTER_CONTAINERS[$j]}"
  do_join "$MASTER_IP" "${MASTER_CONTAINERS[$j]}" "${CONTAINER_ROLES[$j]}"
done

# ------------------------------------------------------------------------------
# 6. Join dos containers de cada host worker
# ------------------------------------------------------------------------------
for i in "${WORKER_IDX[@]}"; do
  host_ip="${IPS[$i]}"
  WORKER_CONTAINERS=($(get_existing_containers "$host_ip"))
  echo "--- Host worker: $host_ip (${WORKER_CONTAINERS[0]} ${VPN_INTERFACE}=${VPNIPS[$i]}) ---"
  for j in "${!WORKER_CONTAINERS[@]}"; do
    wait_microk8s "$host_ip" "${WORKER_CONTAINERS[$j]}"
    do_join "$host_ip" "${WORKER_CONTAINERS[$j]}" "${CONTAINER_ROLES[$j]}"
  done
done

echo "=== Verificando status do cluster no master ==="
sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- sudo microk8s kubectl get nodes" || true

echo
echo "Concluido."
