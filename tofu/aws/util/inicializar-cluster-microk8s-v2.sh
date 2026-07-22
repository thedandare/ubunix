#!/usr/bin/env bash
set -eo pipefail

# ==============================================================================
# inicializar-cluster-microk8s-v2.sh
#
# Versão otimizada com paralelismo melhorado:
#   - Geração de tokens em batch (reutiliza token para múltiplos joins)
#   - Paralelização de waits (aguarda todos os containers em paralelo)
#   - Paralelização de joins entre hosts (processa múltiplos hosts simultaneamente)
#   - Limite de concorrência para não sobrecarregar o master
#   - Detecção de cluster existente: pula hosts já no cluster
#
# ==============================================================================

SSH_PORT=2409
SSH_KEY=/root/.ssh/root_id_ed25519
TOKEN_TTL=999999
MAX_PARALLEL_JOBS=4

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sshrun() {
  local ip="$1"; shift
  sudo ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "$SSH_PORT" \
    "root@$ip" "$*"
}

get_tailscale_ip() {
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
    "root@$pub_ip" "incus exec $first_container -- tailscale ip -4" 2>&1 | head -1)
  echo "    [DEBUG] tailscale ip raw: [$ts_ip]" >&2
  echo "$ts_ip" | head -1
}

get_existing_containers() {
  local pub_ip="$1"
  sudo ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "$SSH_PORT" \
    "root@$pub_ip" -- incus list -c n --format csv | grep 'amnix-' | sort -V | tr '\n' ' ' 2>/dev/null || echo ""
}

get_existing_containers_bg() {
  local idx="$1"
  local ip="$2"
  local temp_file="/tmp/containers_$idx"
  local containers
  containers=$(get_existing_containers "$ip")
  echo "$containers" > "$temp_file"
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

wait_microk8s_bg() {
  local target_ip="$1"
  local cname="$2"
  local temp_file="/tmp/wait_result_${target_ip//./}_${cname}"
  if wait_microk8s "$target_ip" "$cname" 2>&1 | tee "$temp_file"; then
    echo "OK" > "$temp_file"
  else
    echo "FAILED" > "$temp_file"
  fi
}

# Gera um token no master (reutilizável para múltiplos joins)
generate_token() {
  local master_vpn_ip="$1"
  local add_node_out
  add_node_out=$(sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- sudo microk8s add-node --token-ttl -1" 2>/dev/null)
  
  local NODE_TOKEN
  local raw_token
  raw_token=$(echo "$add_node_out" | grep -oP '(?<=join )\S+:25000/\S+' | head -1)
  
  if [[ -z "$raw_token" ]]; then
    echo "    FALHA: nao foi possivel extrair token do add-node" >&2
    echo "    Saida do add-node: $add_node_out" >&2
    return 1
  fi
  
  NODE_TOKEN=$(echo "$raw_token" | sed "s|^[^:]*:25000/|${master_vpn_ip}:25000/|")
  
  echo "$NODE_TOKEN"
}

# Executa join gerando token fresco (evita expiração)
do_join() {
  local target_ip="$1"
  local cname="$2"
  local role="$3"
  local master_vpn_ip="$4"

  echo ">>> [${target_ip}/${cname}] role=$role"
  echo "    Gerando token no master para este no..."
  local node_token
  node_token=$(generate_token "$master_vpn_ip")
  if [[ -z "$node_token" ]]; then
    echo "    FALHA: nao foi possivel gerar token" >&2
    return 1
  fi
  echo "    Token gerado: ${node_token}"
  sleep 1

  local container_vpn_ip
  container_vpn_ip=$(get_container_vpn_ip "$target_ip" "$cname")
  if [[ -n "$container_vpn_ip" ]]; then
    echo "    Configurando --node-ip=${container_vpn_ip} no kubelet..."
    sshrun "$target_ip" "incus exec ${cname} -- bash -c 'grep -q \"^--node-ip=\" /var/snap/microk8s/current/args/kubelet || echo --node-ip=${container_vpn_ip} >> /var/snap/microk8s/current/args/kubelet'"
  else
    echo "    AVISO: nao foi possivel obter IP VPN do container, join sem --node-ip" >&2
  fi

  local JOIN_CMD="sudo microk8s join ${node_token}"
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

do_join_bg() {
  local target_ip="$1"
  local cname="$2"
  local role="$3"
  local master_vpn_ip="$4"
  local temp_file="/tmp/join_result_${target_ip//./}_${cname}"
  
  if do_join "$target_ip" "$cname" "$role" "$master_vpn_ip" 2>&1 | tee "$temp_file"; then
    echo "OK" > "$temp_file"
  else
    echo "FAILED" > "$temp_file"
  fi
}

# Aguarda até MAX_PARALLEL_JOBS jobs em background
wait_for_slot() {
  while [[ $(jobs -r | wc -l) -ge $MAX_PARALLEL_JOBS ]]; do
    sleep 1
  done
}

# Verifica se um container já está no cluster
is_container_in_cluster() {
  local target_ip="$1"
  local cname="$2"
  
  if sshrun "$target_ip" "incus exec ${cname} -- sudo microk8s kubectl get nodes 2>/dev/null | grep -q ." 2>/dev/null; then
    return 0
  fi
  return 1
}

# Obtém lista de nodes no cluster
get_cluster_nodes() {
  sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- sudo microk8s kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null" 2>/dev/null || echo ""
}

# Verifica se um container já está no cluster (por nome)
is_node_in_cluster() {
  local node_name="$1"
  local cluster_nodes="$2"
  
  if [[ "$cluster_nodes" == *"$node_name"* ]]; then
    return 0
  fi
  return 1
}

# Obtém IP da VPN dentro de um container (tailscale ou netbird)
get_container_vpn_ip() {
  local target_ip="$1"
  local cname="$2"
  if [[ "$VPN_CHOICE" == "netbird" ]]; then
    sshrun "$target_ip" "incus exec ${cname} -- ip addr show wt0" 2>/dev/null \
      | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -1
  else
    sshrun "$target_ip" "incus exec ${cname} -- tailscale ip -4" 2>/dev/null | head -1
  fi
}

# Regenera certificado kubelet do container incluindo o IP VPN como SAN
regenerate_kubelet_cert() {
  local target_ip="$1"
  local cname="$2"
  local vpn_ip
  vpn_ip=$(get_container_vpn_ip "$target_ip" "$cname")
  if [[ -z "$vpn_ip" ]]; then
    echo "    AVISO: nao foi possivel obter IP VPN para regenerar certificado de ${cname}" >&2
    return 0
  fi
  echo "    Regenerando certificado kubelet de ${cname} (VPN IP: ${vpn_ip})..."
  sshrun "$target_ip" "incus exec ${cname} -- bash -c '
    CERTS=/var/snap/microk8s/9092/certs
    HOSTNAME=\$(hostname)
    VPN_IP=${vpn_ip}
    rm -f \${CERTS}/kubelet.crt \${CERTS}/kubelet.key
    openssl req -new -newkey rsa:2048 -nodes -keyout \${CERTS}/kubelet.key -out \${CERTS}/kubelet.csr -subj \"/CN=system:node:\${HOSTNAME}/O=system:nodes\" -addext \"subjectAltName = DNS:\${HOSTNAME},IP:\${VPN_IP},IP:127.0.0.1\" 2>/dev/null
    openssl x509 -req -in \${CERTS}/kubelet.csr -CA \${CERTS}/ca.crt -CAkey \${CERTS}/ca.key -CAcreateserial -out \${CERTS}/kubelet.crt -days 365 -extfile <(printf \"subjectAltName=DNS:%s,IP:%s,IP:127.0.0.1\\n\" \"\${HOSTNAME}\" \"\${VPN_IP}\") 2>/dev/null
    rm -f \${CERTS}/kubelet.csr
  '"
}

# Reinicia o kubelite em um container
restart_kubelite() {
  local target_ip="$1"
  local cname="$2"
  echo "    Reiniciando kubelite em ${cname}..."
  sshrun "$target_ip" "incus exec ${cname} -- snap restart microk8s.daemon-kubelite" 2>/dev/null || true
}

# ==============================================================================
# 0. Escolha da VPN (Tailscale ou Netbird)
# ==============================================================================
VPN_CHOICE=$(dialog --title "Escolher VPN" \
  --menu "Escolha qual VPN sera usada para conectividade do cluster:" \
  15 60 2 \
  "tailscale" "Tailscale (padrao)" \
  "netbird" "Netbird (IP range: 100.82.0.0/16)" \
  3>&1 1>&2 2>&3) || exit 0
export VPN_CHOICE

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

# ==============================================================================
# 1. Coleta zone, instance-id, ip publico e ip da VPN
# ==============================================================================
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
    vpn_ip=$(get_tailscale_ip "$ip") || true
  fi
  
  echo "$vpn_ip" > "$temp_file"
  if [[ -n "$vpn_ip" ]]; then
    echo "  [PARALELO] $ip -> $VPN_INTERFACE: $vpn_ip" >&2
  else
    echo "  [PARALELO] ERRO: nao foi possivel obter IP $VPN_NAME do host $ip" >&2
  fi
}

for i in "${!IPS[@]}"; do
  temp_file="/tmp/vpn_ip_$i"
  TEMP_FILES+=("$temp_file")
  get_vpn_ip_bg "$i" "${IPS[$i]}" &
  PIDS+=($!)
done

echo ">>> Aguardando obtenção de IPs VPN..."
for pid in "${PIDS[@]}"; do
  wait "$pid"
done

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

CONTAINER_ROLES=("voter" "voter" "worker")

# ==============================================================================
# 2. Seleciona o node MASTER (menu de escolha unica)
# ==============================================================================
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

# ==============================================================================
# 3. Seleciona os hosts WORKER (checklist, todos marcados por padrao, exceto o master)
# ==============================================================================
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

# Obter containers de todos os workers em paralelo
echo ">>> Obtendo containers dos hosts worker (PARALELO)..."
PIDS=()
WORKER_CONTAINERS_MAP=()
for i in "${WORKER_IDX[@]}"; do
  temp_file="/tmp/containers_$i"
  get_existing_containers_bg "$i" "${IPS[$i]}" &
  PIDS+=($!)
done

for pid in "${PIDS[@]}"; do
  wait "$pid"
done

for i in "${WORKER_IDX[@]}"; do
  temp_file="/tmp/containers_$i"
  containers=$(cat "$temp_file" 2>/dev/null || echo "")
  WORKER_CONTAINERS_MAP[$i]="$containers"
  echo "  - pub=${IPS[$i]}  ${containers%% *} ${VPN_INTERFACE}=${VPNIPS[$i]}"
  echo "    Containers encontrados: $containers"
  rm -f "$temp_file"
done
echo

MASTER_CONTAINER_VPN_IP="${VPNIPS[$MASTER_IDX]}"
echo ">>> IP $VPN_NAME do ${MASTER_CONTAINER} (join endpoint): ${MASTER_CONTAINER_VPN_IP}"

# Configura --node-ip no master para usar a VPN como underlay
MASTER_CONTAINER_ACTUAL_VPN_IP=$(get_container_vpn_ip "$MASTER_IP" "$MASTER_CONTAINER")
if [[ -n "$MASTER_CONTAINER_ACTUAL_VPN_IP" ]]; then
  echo ">>> Configurando --node-ip=${MASTER_CONTAINER_ACTUAL_VPN_IP} no kubelet do master..."
  sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- bash -c 'grep -q \"^--node-ip=\" /var/snap/microk8s/current/args/kubelet || echo --node-ip=${MASTER_CONTAINER_ACTUAL_VPN_IP} >> /var/snap/microk8s/current/args/kubelet'"
else
  echo "    AVISO: nao foi possivel obter IP VPN do master" >&2
fi
echo

# ==============================================================================
# 3. Verificar cluster existente e filtrar hosts já no cluster
# ==============================================================================
echo ">>> Verificando cluster existente no master..."

CLUSTER_NODES=$(get_cluster_nodes)
echo "    Nodes no cluster: ${CLUSTER_NODES:-"(nenhum)"}"
echo

# Filtrar containers do master que já estão no cluster
MASTER_CONTAINERS_TO_JOIN=()
for j in "${!MASTER_CONTAINERS[@]}"; do
  if [[ $j -eq 0 ]]; then continue; fi
  cname="${MASTER_CONTAINERS[$j]}"
  if is_node_in_cluster "$cname" "$CLUSTER_NODES"; then
    echo "    [SKIP] ${MASTER_IP}/${cname} já está no cluster"
  else
    MASTER_CONTAINERS_TO_JOIN+=("$j")
  fi
done
echo

# Filtrar containers dos workers que já estão no cluster
declare -A WORKER_CONTAINERS_TO_JOIN
for i in "${WORKER_IDX[@]}"; do
  host_ip="${IPS[$i]}"
  containers_str="${WORKER_CONTAINERS_MAP[$i]}"
  read -ra containers <<< "$containers_str"
  
  WORKER_CONTAINERS_TO_JOIN[$i]=""
  for j in "${!containers[@]}"; do
    cname="${containers[$j]}"
    if is_node_in_cluster "$cname" "$CLUSTER_NODES"; then
      echo "    [SKIP] ${host_ip}/${cname} já está no cluster"
    else
      WORKER_CONTAINERS_TO_JOIN[$i]="${WORKER_CONTAINERS_TO_JOIN[$i]} $j"
    fi
  done
done
echo

# ==============================================================================
# 5. Preparar para gerar tokens (será gerado um por join para evitar expiração)
# ==============================================================================
echo ">>> Tokens serão gerados individualmente para cada join (evita expiração)"
echo

# ==============================================================================
# 6. Aguardar todos os containers ficarem prontos (PARALELO)
# ==============================================================================
echo "--- Aguardando microk8s em containers que serão adicionados (PARALELO) ---"
PIDS=()

for j in ${MASTER_CONTAINERS_TO_JOIN[@]}; do
  wait_for_slot
  wait_microk8s_bg "$MASTER_IP" "${MASTER_CONTAINERS[$j]}" &
  PIDS+=($!)
done

for i in "${WORKER_IDX[@]}"; do
  host_ip="${IPS[$i]}"
  containers_str="${WORKER_CONTAINERS_MAP[$i]}"
  read -ra containers <<< "$containers_str"
  for j in ${WORKER_CONTAINERS_TO_JOIN[$i]}; do
    cname="${containers[$j]}"
    wait_for_slot
    wait_microk8s_bg "$host_ip" "$cname" &
    PIDS+=($!)
  done
done

if [[ ${#PIDS[@]} -gt 0 ]]; then
  echo ">>> Aguardando conclusão de todos os waits..."
  for pid in "${PIDS[@]}"; do
    wait "$pid"
  done
else
  echo ">>> Nenhum container para aguardar (todos já estão no cluster)"
fi
echo

# ==============================================================================
# 7. Executar joins (PARALELO com limite de concorrência)
# ==============================================================================
echo "--- Executando joins em containers que serão adicionados (PARALELO) ---"
PIDS=()

for j in ${MASTER_CONTAINERS_TO_JOIN[@]}; do
  wait_for_slot
  do_join_bg "$MASTER_IP" "${MASTER_CONTAINERS[$j]}" "${CONTAINER_ROLES[$j]}" "$MASTER_CONTAINER_VPN_IP" &
  PIDS+=($!)
  sleep 1
done

for i in "${WORKER_IDX[@]}"; do
  host_ip="${IPS[$i]}"
  containers_str="${WORKER_CONTAINERS_MAP[$i]}"
  read -ra containers <<< "$containers_str"
  for j in ${WORKER_CONTAINERS_TO_JOIN[$i]}; do
    cname="${containers[$j]}"
    wait_for_slot
    do_join_bg "$host_ip" "$cname" "${CONTAINER_ROLES[$j]}" "$MASTER_CONTAINER_VPN_IP" &
    PIDS+=($!)
    sleep 1
  done
done

if [[ ${#PIDS[@]} -gt 0 ]]; then
  echo ">>> Aguardando conclusão de todos os joins..."
  for pid in "${PIDS[@]}"; do
    wait "$pid"
  done
else
  echo ">>> Nenhum container para adicionar (todos já estão no cluster)"
fi
echo

echo "=== Verificando status do cluster no master ==="
sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- sudo microk8s kubectl get nodes" || true

echo
echo "=== Regenerando certificados kubelet com IP VPN ==="
regenerate_kubelet_cert "$MASTER_IP" "$MASTER_CONTAINER"
for j in ${MASTER_CONTAINERS_TO_JOIN[@]}; do
  regenerate_kubelet_cert "$MASTER_IP" "${MASTER_CONTAINERS[$j]}"
done
for i in "${WORKER_IDX[@]}"; do
  host_ip="${IPS[$i]}"
  containers_str="${WORKER_CONTAINERS_MAP[$i]}"
  read -ra containers <<< "$containers_str"
  for j in ${WORKER_CONTAINERS_TO_JOIN[$i]}; do
    regenerate_kubelet_cert "$host_ip" "${containers[$j]}"
  done
done

echo
echo "=== Reiniciando kubelite em todos os containers ==="
restart_kubelite "$MASTER_IP" "$MASTER_CONTAINER"
for j in ${MASTER_CONTAINERS_TO_JOIN[@]}; do
  restart_kubelite "$MASTER_IP" "${MASTER_CONTAINERS[$j]}"
done
for i in "${WORKER_IDX[@]}"; do
  host_ip="${IPS[$i]}"
  containers_str="${WORKER_CONTAINERS_MAP[$i]}"
  read -ra containers <<< "$containers_str"
  for j in ${WORKER_CONTAINERS_TO_JOIN[$i]}; do
    restart_kubelite "$host_ip" "${containers[$j]}"
  done
done

echo
echo "Aguardando cluster estabilizar..."
sleep 120

echo
echo "=== Aguardando Calico-node ficar pronto ==="
wait_calico_ready() {
  local target_ip="$1"
  local cname="$2"
  echo "    Aguardando calico-node em ${cname}..."
  sshrun "$target_ip" "incus exec ${cname} -- bash -c 'microk8s kubectl rollout status ds/calico-node -n kube-system --timeout=300s'"
}
wait_calico_ready "$MASTER_IP" "$MASTER_CONTAINER"
for j in ${MASTER_CONTAINERS_TO_JOIN[@]}; do
  wait_calico_ready "$MASTER_IP" "${MASTER_CONTAINERS[$j]}"
done
for i in "${WORKER_IDX[@]}"; do
  host_ip="${IPS[$i]}"
  containers_str="${WORKER_CONTAINERS_MAP[$i]}"
  read -ra containers <<< "$containers_str"
  for j in ${WORKER_CONTAINERS_TO_JOIN[$i]}; do
    wait_calico_ready "$host_ip" "${containers[$j]}"
  done
done

echo
echo "=== Verificando pods do kube-system ==="
sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- bash -c 'microk8s kubectl wait --for=condition=Ready pod -n kube-system --all --timeout=180s'"

echo
echo "=== Configurando aliases kubectl/helm no leader ==="
sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- bash -c '
  grep -q \"alias kubectl=\" ~/.bashrc || echo \"alias kubectl=\\\"microk8s kubectl\\\"\" >> ~/.bashrc
  grep -q \"alias helm=\" ~/.bashrc    || echo \"alias helm=\\\"microk8s helm\\\"\"       >> ~/.bashrc
'" || true

echo
echo "=== Habilitando addons community e rook-ceph ==="
sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- sudo microk8s enable community" || true
sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- sudo microk8s enable hostpath-storage" || true
# sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- sudo microk8s enable rook-ceph" || true

echo
echo "=== Instalando Headlamp via Helm ==="
sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- sudo microk8s helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/" || true
sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- sudo microk8s helm repo update" || true
sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- sudo microk8s helm install my-headlamp headlamp/headlamp --namespace kube-system" || true

echo
echo "=== Expondo Headlamp via port-forward persistente ==="
sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- bash -c 'cat > /etc/systemd/system/headlamp-portforward.service <<\"EOF\"
[Unit]
Description=Headlamp port-forward
After=network.target

[Service]
Type=simple
Restart=always
RestartSec=5
Environment=KUBECONFIG=/var/snap/microk8s/current/credentials/client.config
ExecStart=/snap/microk8s/9092/kubectl port-forward deployment/my-headlamp 4466:4466 -n kube-system --address 0.0.0.0
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
'" || true
sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- bash -c 'systemctl daemon-reload; systemctl enable --now headlamp-portforward'" || true

echo "    Acesse: http://${MASTER_CONTAINER_VPN_IP}:4466"
echo "    Token de acesso gerado abaixo."

echo
echo "=== Token de acesso ao Headlamp ==="
HEADLAMP_TOKEN=$(sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- sudo microk8s kubectl create token my-headlamp -n kube-system" 2>/dev/null) || true
if [[ -n "$HEADLAMP_TOKEN" ]]; then
  echo "    Token:"
  echo "$HEADLAMP_TOKEN"
else
  echo "    AVISO: nao foi possivel gerar token (deployment pode ainda estar inicializando)" >&2
  echo "    Gere manualmente: microk8s kubectl create token my-headlamp -n kube-system"
fi

echo
echo "Concluido."

echo
echo "=== Implantando aplicacao Serverpod no cluster ==="

SERVERPOD_DEPLOY_SCRIPT=$(cat <<'DEPLOYEOF'
#!/bin/bash
set -eo pipefail

cd /tmp

IMAGE_NAME="thedandare/fibo-serverpod-genui:v1.0.2"
DEPLOYMENT_FILE="serverpod-deployment.yaml"
SERVICE_APP_FILE="serverpod-service-exposed.yaml"
INGRESS_FILE="serverpod-ingress.yaml"
DB_FILE="postgres-cluster.yaml"

echo "🚀 Validando e aplicando estado do ambiente no MicroK8s..."

# Funcao auxiliar: aplica com retry para contornar "database is locked" do dqlite
kubectl_apply_retry() {
  local file="$1"
  local attempt=0
  while [[ $attempt -lt 10 ]]; do
    if microk8s kubectl apply -f "$file" 2>/tmp/kubectl.err; then
      return 0
    fi
    attempt=$((attempt + 1))
    echo "    ⚠️  Tentativa $attempt falhou, aguardando API server..."
    cat /tmp/kubectl.err >&2
    sleep 5
  done
  echo "    ❌ Falha ao aplicar $file apos 10 tentativas" >&2
  return 1
}

# 1. Ativacao idempotente de componentes nativos do MicroK8s
microk8s enable hostpath-storage > /dev/null
microk8s enable cloudnative-pg > /dev/null
microk8s enable ingress > /dev/null

# Aguarda addons estabilizarem antes de aplicar manifests
echo "⏳ Aguardando addons e API server estabilizarem..."
sleep 10
microk8s status --wait-ready --timeout 120

# 2. Criacao da Secret com chaves explicitas exigidas pelo CNPG
if ! microk8s kubectl get secret postgres-user-password &>/dev/null; then
  echo "🔑 Criando estrutura de credenciais..."
  microk8s kubectl create secret generic postgres-user-password \
    --from-literal=username="postgres" \
    --from-literal=password="F1bo6600"
fi

# 3. Geracao do manifesto do Cluster PostgreSQL e Servicos de Rede
echo "📝 Gerando manifesto do cluster PostgreSQL..."
cat <<EOF > $DB_FILE
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres
  labels:
    app: serverpod-db
spec:
  instances: 1
  storage:
    size: 2Gi
  bootstrap:
    initdb:
      database: postgres
      secret:
        name: postgres-user-password
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-local
spec:
  type: ExternalName
  externalName: postgres-rw.default.svc.cluster.local
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-nodeport
  labels:
    app: serverpod-db
spec:
  type: NodePort
  selector:
    cnpg.io/cluster: postgres
    cnpg.io/instanceRole: primary
  ports:
    - name: postgres
      protocol: TCP
      port: 5432
      targetPort: 5432
      nodePort: 30432
EOF

# 4. Geracao do manifesto de Deployment
echo "📝 Gerando manifesto da aplicacao: $DEPLOYMENT_FILE..."
cat <<EOF > $DEPLOYMENT_FILE
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fibo-serverpod-deployment
  labels:
    app: fibo-serverpod
spec:
  replicas: 2
  selector:
    matchLabels:
      app: fibo-serverpod
  template:
    metadata:
      labels:
        app: fibo-serverpod
    spec:
      containers:
      - name: serverpod-container
        image: $IMAGE_NAME
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
          name: api-port
        - containerPort: 8081
          name: service-port
        - containerPort: 8082
          name: web-port
        env:
        - name: RUN_MODE
          value: "production"
        - name: SERVERPOD_ROLE
          value: "monolith"
        - name: SERVERPOD_DATABASE_HOST
          value: "postgres-rw.default.svc.cluster.local"
        - name: SERVERPOD_DATABASE_PORT
          value: "5432"
        - name: SERVERPOD_DATABASE_NAME
          value: "postgres"
        - name: SERVERPOD_DATABASE_USER
          value: "postgres"
        - name: SERVERPOD_DATABASE_PASSWORD
          value: "F1bo6600"
        # Todas as chaves de senhas mapeadas explicitamente para evitar travamento do boot do Serverpod
        - name: SERVERPOD_PASSWORD_database
          value: "F1bo6600"
        - name: SERVERPOD_PASSWORD_service
          value: "F1bo6600"
        - name: SERVERPOD_PASSWORD_redis
          value: "F1bo6600"
EOF

# 5. Geracao do Service do Serverpod
echo "📝 Gerando o manifesto de Service com NodePorts fixos..."
cat <<EOF > $SERVICE_APP_FILE
apiVersion: v1
kind: Service
metadata:
  name: fibo-serverpod-service
  namespace: default
spec:
  type: NodePort
  selector:
    app: fibo-serverpod
  ports:
    - name: api
      protocol: TCP
      port: 8080
      targetPort: 8080
      nodePort: 30080
    - name: service
      protocol: TCP
      port: 8081
      targetPort: 8081
      nodePort: 30081
    - name: web
      protocol: TCP
      port: 8082
      targetPort: 8082
      nodePort: 30082
EOF

# 6. Geracao do manifesto de Ingress
echo "📝 Gerando manifesto declarativo de Ingress: $INGRESS_FILE..."
cat <<EOF > $INGRESS_FILE
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: fibo-serverpod-ingress
  namespace: default
  annotations:
    traefik.ingress.kubernetes.io/router.tls: "false"
spec:
  ingressClassName: public
  rules:
  - http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: fibo-serverpod-service
            port:
              number: 8080
      - path: /service
        pathType: Prefix
        backend:
          service:
            name: fibo-serverpod-service
            port:
              number: 8081
      - path: /web
        pathType: Prefix
        backend:
          service:
            name: fibo-serverpod-service
            port:
              number: 8082
EOF

# 7. Sincronizacao dos manifestos no cluster
echo "☸️  Sincronizando estado desejado com os manifestos (kubectl apply)..."

# Aguarda operator e webhook do CNPG ficarem prontos antes de aplicar o cluster
echo "    Verificando operator e webhook do CloudNative PG..."
cnpg_ready=0
for i in $(seq 1 120); do
  operator_ready=0
  microk8s kubectl get crd clusters.postgresql.cnpg.io &>/dev/null || continue
  microk8s kubectl wait --for=condition=Ready pod -n cnpg-system --all --timeout=10s &>/dev/null && operator_ready=1
  if [[ $operator_ready -eq 1 ]]; then
    webhook_addr=$(microk8s kubectl get endpoints cnpg-webhook-service -n cnpg-system -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
    if [[ -n "$webhook_addr" ]]; then
      echo "    ✅ CNPG operator e webhook prontos"
      cnpg_ready=1
      break
    fi
  fi
  if [[ $((i % 10)) -eq 0 ]]; then
    echo "    ⏳ Aguardando CNPG... ($((i * 5))s)" >&2
  fi
  sleep 5
done
if [[ $cnpg_ready -ne 1 ]]; then
  echo "    ❌ Timeout: CNPG operator/webhook nao ficou pronto" >&2
  exit 1
fi

kubectl_apply_retry "$DB_FILE"
sleep 2

# Aguarda o hostpath-provisioner estar Running para o PVC do Postgres ser provisionado
echo "⏳ Aguardando hostpath-provisioner..."
microk8s kubectl wait --for=condition=Ready pod -l k8s-app=hostpath-provisioner -n kube-system --timeout=120s

# Aguarda PVC do postgres ficar Bound
echo "⏳ Aguardando PVC do PostgreSQL ficar Bound..."
pvc_bound=0
for i in $(seq 1 60); do
  if microk8s kubectl get pvc -l cnpg.io/cluster=postgres -n default -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -q 'Bound'; then
    echo "    ✅ PVC Bound"
    pvc_bound=1
    break
  fi
  sleep 5
done
if [[ $pvc_bound -ne 1 ]]; then
  echo "    ❌ Timeout: PVC do PostgreSQL nao ficou Bound" >&2
  exit 1
fi

kubectl_apply_retry "$SERVICE_APP_FILE"
sleep 2
kubectl_apply_retry "$DEPLOYMENT_FILE"
sleep 2
kubectl_apply_retry "$INGRESS_FILE"

# 8. Aguarda o cluster PostgreSQL ficar pronto antes de forcar rollout
echo "⏳ Aguardando o PostgreSQL ficar pronto..."
microk8s kubectl wait --for=condition=Ready cluster/postgres --timeout=300s

# 9. Forcar atualizacao imediata dos pods do Serverpod
echo "🔄 Forcando a reciclagem limpa dos pods da aplicacao..."
microk8s kubectl rollout restart deployment/fibo-serverpod-deployment > /dev/null

echo "--------------------------------------------------------"
echo "✅ Estado do cluster garantido com sucesso de forma 100% estavel!"
DEPLOYEOF
)

# Executa o script de deploy dentro do container master via SSH + incus exec
sudo ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "$SSH_PORT" \
  "root@$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- bash -s" <<< "$SERVERPOD_DEPLOY_SCRIPT"

echo
echo "Concluido."
