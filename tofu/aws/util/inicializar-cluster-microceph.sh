#!/usr/bin/env bash
set -eo pipefail

# ==============================================================================
# inicializar-cluster-microceph.sh
#
# Objetivo:
#   1) Escolher entre Tailscale ou Netbird para conectividade VPN
#   2) Conectar via SSH na primeira instancia selecionada (master) e executar
#      o script de bootstrap do microceph (microceph_custer_bootstrap.sh)
#   3) Extrair o token de join gerado na saida do bootstrap
#   4) Conectar via SSH nas demais instancias selecionadas (workers) e
#      executar o script de join do microceph (microceph_cluster_join.sh)
#
# Reaproveita a mesma infra do script de conexao SSH (describe-ips.sh, SSH_KEY,
# SSH_PORT e o dialog de selecao de nodes).
#
# Conectividade via VPN:
#   - Tailscale: SSH nos hosts usa o IP da interface tailscale0 (obtido remotamente).
#               O join cross-host do microceph usa o IP tailscale0 do host master.
#   - Netbird:  SSH nos hosts usa o IP da interface netbird (obtido remotamente).
#               Range de IP: 100.82.0.0/16
#               O join cross-host do microceph usa o IP netbird do host master.
# ==============================================================================

SSH_PORT=2409
SSH_KEY=/root/.ssh/root_id_ed25519
BOOTSTRAP_SCRIPT_PATH="/osnix/nixos/leonix/virtualisation/microceph_custer_bootstrap.sh"
JOIN_SCRIPT_PATH="/osnix/nixos/leonix/virtualisation/microceph_cluster_join.sh"

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

# Copia um script local para o container remoto
copy_script_to_container() {
  local host_ip="$1"
  local container_name="$2"
  local local_script="$3"
  local remote_path="$4"
  
  echo "    Copiando script $local_script para ${host_ip}/${container_name}:${remote_path}..."
  
  # Copia o arquivo para o host via SSH
  local temp_file="/tmp/$(basename "$local_script")"
  sudo scp -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -P "$SSH_PORT" \
    "$local_script" "root@${host_ip}:${temp_file}" 2>/dev/null || {
    echo "    ERRO: Falha ao copiar script para host" >&2
    return 1
  }
  
  # Move do host para dentro do container
  sshrun "$host_ip" "incus file push ${temp_file} ${container_name}${remote_path}" || {
    echo "    ERRO: Falha ao copiar script para container" >&2
    return 1
  }
  
  # Remove arquivo temporário do host
  sshrun "$host_ip" "rm -f ${temp_file}" || true
  
  echo "    OK: Script copiado para ${container_name}:${remote_path}"
}

# Aguarda microceph estar pronto dentro de um container
wait_microceph() {
  local target_ip="$1"
  local cname="$2"
  echo "    Aguardando microceph ficar pronto em ${target_ip}/${cname}..."
  for attempt in $(seq 1 30); do
    if sshrun "$target_ip" "incus exec ${cname} -- sudo microceph status" 2>/dev/null; then
      return 0
    fi
    echo "    tentativa $attempt/30 - aguardando 10s..."
    sleep 10
  done
  echo "    TIMEOUT: microceph nao ficou pronto em ${target_ip}/${cname}" >&2
  return 1
}

# Funcao auxiliar: executa bootstrap no master
do_bootstrap() {
  local target_ip="$1"
  local cname="$2"
  local first_worker_name="$3"

  echo ">>> [${target_ip}/${cname}] Bootstrap do MicroCeph"
  
  # Copia script de bootstrap
  copy_script_to_container "$target_ip" "$cname" "$BOOTSTRAP_SCRIPT_PATH" "/tmp/microceph_bootstrap.sh" || return 1
  
  echo "    Executando bootstrap com primeiro worker: $first_worker_name..."
  local bootstrap_out
  bootstrap_out=$(sshrun "$target_ip" "incus exec ${cname} -- sudo bash /tmp/microceph_bootstrap.sh '$first_worker_name'" 2>&1)
  
  if [[ -z "$bootstrap_out" ]]; then
    echo "    FALHA: bootstrap nao retornou saida" >&2
    echo "    Saida: $bootstrap_out" >&2
    return 1
  fi
  
  echo "    Bootstrap executado com sucesso"
  echo "    Saida do bootstrap:"
  echo "$bootstrap_out" | tail -20
  
  # Extrai o token de join da saida
  # O token esta na ultima linha ou proximas linhas apos "Cole o comando abaixo"
  local NODE_TOKEN
  NODE_TOKEN=$(echo "$bootstrap_out" | grep -A 5 "Cole o comando abaixo" | tail -1 | tr -d '\n' || true)
  
  if [[ -z "$NODE_TOKEN" ]]; then
    echo "    AVISO: nao foi possivel extrair token automaticamente" >&2
    echo "    Procure por 'sudo microceph cluster join' na saida acima" >&2
    return 1
  fi
  
  echo "    Token extraido: ${NODE_TOKEN:0:50}..."
  echo "$NODE_TOKEN"
}

# Funcao auxiliar: executa join em um worker
do_join() {
  local target_ip="$1"
  local cname="$2"
  local token="$3"
  local master_ip="$4"

  echo ">>> [${target_ip}/${cname}] Join do MicroCeph"
  
  # Copia script de join
  copy_script_to_container "$target_ip" "$cname" "$JOIN_SCRIPT_PATH" "/tmp/microceph_join.sh" || return 1
  
  echo "    Executando join com token e master_ip=$master_ip..."
  local join_cmd="sudo bash /tmp/microceph_join.sh '$token' '$master_ip'"
  
  if sshrun "$target_ip" "incus exec ${cname} -- $join_cmd"; then
    echo "    OK: ${target_ip}/${cname} entrou no cluster."
  else
    echo "    FALHA: ${target_ip}/${cname}" >&2
    return 1
  fi
  echo
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

# ------------------------------------------------------------------------------
# 2. Seleciona o node MASTER (menu de escolha unica)
# ------------------------------------------------------------------------------
MARGS=()
for i in "${!IPS[@]}"; do
  MARGS+=("node${i}" "${ZONES[$i]}  ${IPS[$i]}  ${VPN_INTERFACE}=${VPNIPS[$i]}  ${IDS[$i]}")
done

MASTER_TAG=$(dialog --title "Selecionar node MASTER" \
  --menu "Escolha a instancia que sera o master do cluster MicroCeph:" \
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
  --checklist "Cada host tera: 1 container principal (amnix-0)" \
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
echo "=== Master selecionado: pub=${MASTER_IP}  container=${MASTER_CONTAINER}  ${VPN_INTERFACE}=${VPNIPS[$MASTER_IDX]} ==="
echo "    Containers encontrados: ${MASTER_CONTAINERS[*]}"
echo "=== Hosts worker selecionados: ${#WORKER_IDX[@]} ==="
for i in "${WORKER_IDX[@]}"; do
  WORKER_CONTAINERS=($(get_existing_containers "${IPS[$i]}"))
  echo "  - pub=${IPS[$i]}  ${WORKER_CONTAINERS[0]} ${VPN_INTERFACE}=${VPNIPS[$i]}"
  echo "    Containers encontrados: ${WORKER_CONTAINERS[*]}"
done
echo

# IP da VPN do container master ja disponivel em VPNIPS[$MASTER_IDX]
MASTER_CONTAINER_VPN_IP="${VPNIPS[$MASTER_IDX]}"
echo ">>> IP $VPN_NAME do ${MASTER_CONTAINER} (join endpoint): ${MASTER_CONTAINER_VPN_IP}"
echo

# Prepara nome do primeiro worker para o bootstrap
FIRST_WORKER_CONTAINER="${MASTER_CONTAINERS[1]}"
if [[ -z "$FIRST_WORKER_CONTAINER" ]]; then
  FIRST_WORKER_CONTAINER="amnix-1"
fi

# ------------------------------------------------------------------------------
# 4. Bootstrap do MicroCeph no master
# ------------------------------------------------------------------------------
echo "--- Executando bootstrap do MicroCeph no master ---"
wait_microceph "$MASTER_IP" "$MASTER_CONTAINER" || {
  echo "ERRO: microceph nao ficou pronto no master" >&2
  exit 1
}

BOOTSTRAP_TOKEN=$(do_bootstrap "$MASTER_IP" "$MASTER_CONTAINER" "$FIRST_WORKER_CONTAINER") || {
  echo "ERRO: bootstrap falhou" >&2
  exit 1
}

echo ">>> Token de join obtido com sucesso"
echo

# ------------------------------------------------------------------------------
# 5. Join dos workers
# ------------------------------------------------------------------------------
for i in "${WORKER_IDX[@]}"; do
  host_ip="${IPS[$i]}"
  WORKER_CONTAINERS=($(get_existing_containers "$host_ip"))
  WORKER_CONTAINER="${WORKER_CONTAINERS[0]}"
  
  echo "--- Host worker: $host_ip (${WORKER_CONTAINER} ${VPN_INTERFACE}=${VPNIPS[$i]}) ---"
  wait_microceph "$host_ip" "$WORKER_CONTAINER" || {
    echo "AVISO: microceph nao ficou pronto no worker, tentando mesmo assim..." >&2
  }
  do_join "$host_ip" "$WORKER_CONTAINER" "$BOOTSTRAP_TOKEN" "$MASTER_CONTAINER_VPN_IP" || {
    echo "AVISO: join falhou para este worker, continuando..." >&2
  }
done

echo "=== Verificando status do cluster no master ==="
sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- sudo microceph status" || true

echo
echo "Concluido."
