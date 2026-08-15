#!/usr/bin/env bash
set -eo pipefail

# ==============================================================================
# inicializar-cluster-microk8s-v4-log.sh
#
# Versão otimizada com paralelismo melhorado:
#   - Geração de token individual para cada join
#   - Paralelização de waits (aguarda todos os containers em paralelo)
#   - Paralelização de joins entre hosts (processa múltiplos hosts simultaneamente)
#   - Limite de concorrência para não sobrecarregar o master
#   - Detecção de cluster existente: pula hosts já no cluster
#   - Ingress Traefik reinstalável e validado
#   - HTTPS autoassinado com SAN para o IP público do host master
#   - Rota /serverpod -> Service Serverpod porta 8080, removendo o prefixo
#   - Rota /control -> Service Serverpod porta 8082
#   - Senha do postgres reconciliada declarativamente pelo CloudNativePG
#   - Proxy Incus TCP 443 do host EC2 para o container líder
#   - --node-ip atualizado com o IP VPN em todos os nós
#   - --advertise-address atualizado com o IP VPN em todos os voters
#   - iptables do snap forçado para nftables por bind mount persistente
#   - Correções aplicadas também aos nós que já pertenciam ao cluster
#   - Reinício rolling, um nó por vez, com validação
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
  echo "    Token gerado com sucesso."
  sleep 1

  # Configura o endereço VPN e a correção nftables antes do join.
  # O próprio join reinicia os serviços necessários; depois haverá uma
  # validação rolling de todos os membros, inclusive os já existentes.
  configure_microk8s_node "$target_ip" "$cname" "$role"

  local JOIN_CMD="sudo microk8s join ${node_token}"
  [[ "$role" == "worker" ]] && JOIN_CMD="$JOIN_CMD --worker"

  echo "    cmd: $JOIN_CMD"
  sleep 2
  if sshrun "$target_ip" "incus exec ${cname} -- $JOIN_CMD"; then
    echo "    OK: ${target_ip}/${cname} entrou como $role."
  else
    echo "    FALHA: ${target_ip}/${cname}" >&2
    return 1
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
  local existing_node

  for existing_node in $cluster_nodes; do
    [[ "$existing_node" == "$node_name" ]] && return 0
  done

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


# Retorna o papel esperado pelo índice do container.
# Índices não previstos são tratados como worker por segurança.
get_container_role() {
  local index="$1"
  echo "${CONTAINER_ROLES[$index]:-worker}"
}

# Configura um nó de forma idempotente.
#
# Correções confirmadas neste ambiente:
#   1. kubelet anuncia o IP VPN por --node-ip;
#   2. voters anunciam o IP VPN por --advertise-address;
#   3. /snap/.../sbin/iptables (legacy) recebe um bind mount do iptables-nft.
#
# O bind mount é executado imediatamente e também por ExecStartPre sempre que
# containerd ou kubelite iniciarem. Assim a correção volta após reboot/restart.
configure_microk8s_node() {
  local target_ip="$1"
  local cname="$2"
  local role="$3"
  local vpn_ip

  vpn_ip=$(get_container_vpn_ip "$target_ip" "$cname")
  if [[ -z "$vpn_ip" ]]; then
    echo "    ERRO: não foi possível obter o IP VPN de ${target_ip}/${cname}" >&2
    return 1
  fi

  echo "    Configurando ${target_ip}/${cname}: role=${role}, VPN=${vpn_ip}"

  sshrun "$target_ip" \
    "incus exec ${cname} -- env VPN_IP=${vpn_ip} NODE_ROLE=${role} bash -s" <<'NODECONFIG'
set -euo pipefail

KUBELET_ARGS=/var/snap/microk8s/current/args/kubelet
APISERVER_ARGS=/var/snap/microk8s/current/args/kube-apiserver
NFT_HELPER=/usr/local/sbin/microk8s-force-iptables-nft

# Substitui qualquer valor anterior; não apenas acrescenta quando ausente.
sed -i '/^--node-ip=/d' "$KUBELET_ARGS"
printf '%s\n' "--node-ip=${VPN_IP}" >> "$KUBELET_ARGS"

if [[ "$NODE_ROLE" != "worker" ]]; then
  sed -i '/^--advertise-address=/d' "$APISERVER_ARGS"
  printf '%s\n' "--advertise-address=${VPN_IP}" >> "$APISERVER_ARGS"
fi

# Helper idempotente. O flock evita corrida quando containerd e kubelite
# iniciarem simultaneamente.
cat > "$NFT_HELPER" <<'NFTHELPER'
#!/usr/bin/env bash
set -euo pipefail

SOURCE=/snap/microk8s/current/sbin/iptables-nft
TARGET=/snap/microk8s/current/sbin/iptables
LOCK=/run/microk8s-iptables-nft.lock

exec 9>"$LOCK"
flock -x 9

[[ -x "$SOURCE" ]] || { echo "iptables-nft não encontrado: $SOURCE" >&2; exit 1; }
[[ -e "$TARGET" ]] || { echo "iptables não encontrado: $TARGET" >&2; exit 1; }

if mountpoint -q "$TARGET"; then
  if "$TARGET" --version 2>&1 | grep -q 'nf_tables'; then
    "$TARGET" -t nat -S >/dev/null
    exit 0
  fi
  umount "$TARGET"
fi

mount --bind "$SOURCE" "$TARGET"
"$TARGET" --version 2>&1 | grep -q 'nf_tables'
"$TARGET" -t nat -S >/dev/null
NFTHELPER
chmod 0755 "$NFT_HELPER"

mkdir -p \
  /etc/systemd/system/snap.microk8s.daemon-containerd.service.d \
  /etc/systemd/system/snap.microk8s.daemon-kubelite.service.d

cat > /etc/systemd/system/snap.microk8s.daemon-containerd.service.d/20-iptables-nft.conf <<'DROPIN'
[Service]
ExecStartPre=/usr/local/sbin/microk8s-force-iptables-nft
DROPIN

cat > /etc/systemd/system/snap.microk8s.daemon-kubelite.service.d/20-iptables-nft.conf <<'DROPIN'
[Service]
ExecStartPre=/usr/local/sbin/microk8s-force-iptables-nft
DROPIN

systemctl daemon-reload
"$NFT_HELPER"

grep -Fxq -- "--node-ip=${VPN_IP}" "$KUBELET_ARGS"
if [[ "$NODE_ROLE" != "worker" ]]; then
  grep -Fxq -- "--advertise-address=${VPN_IP}" "$APISERVER_ARGS"
fi

/snap/microk8s/current/sbin/iptables --version
/snap/microk8s/current/sbin/iptables -t nat -S >/dev/null
NODECONFIG
}

# Reinicia um nó isoladamente para preservar o quorum do control plane.
restart_microk8s_node() {
  local target_ip="$1"
  local cname="$2"

  echo "    Reiniciando containerd e kubelite em ${cname}..."
  sshrun "$target_ip" "incus exec ${cname} -- bash -c '
    set -e
    timeout 120 systemctl restart snap.microk8s.daemon-containerd.service
    timeout 120 systemctl restart snap.microk8s.daemon-kubelite.service
  '"
}

# Aguarda o reconciliador publicar o IP VPN do voter no Service kubernetes.
wait_apiserver_endpoint() {
  local expected_ip="$1"
  local endpoint_ips=""

  echo "    Aguardando endpoint ${expected_ip}:16443..."
  for attempt in $(seq 1 60); do
    endpoint_ips=$(sshrun "$MASTER_IP" \
      "incus exec ${MASTER_CONTAINER} -- microk8s kubectl get endpoints kubernetes -n default -o jsonpath='{.subsets[*].addresses[*].ip}'" \
      2>/dev/null || true)

    if tr ' ' '\n' <<< "$endpoint_ips" | grep -Fxq "$expected_ip"; then
      echo "    OK: endpoint ${expected_ip}:16443 publicado."
      return 0
    fi

    sleep 2
  done

  echo "    ERRO: endpoint ${expected_ip}:16443 não foi publicado." >&2
  echo "    Endpoints atuais: ${endpoint_ips:-nenhum}" >&2
  return 1
}

# Configura, regenera certificado, reinicia e valida exatamente um nó.
reconcile_microk8s_node() {
  local target_ip="$1"
  local cname="$2"
  local role="$3"
  local vpn_ip

  vpn_ip=$(get_container_vpn_ip "$target_ip" "$cname")
  [[ -n "$vpn_ip" ]] || {
    echo "    ERRO: IP VPN ausente para ${target_ip}/${cname}" >&2
    return 1
  }

  configure_microk8s_node "$target_ip" "$cname" "$role"
  regenerate_kubelet_cert "$target_ip" "$cname"
  restart_microk8s_node "$target_ip" "$cname"
  wait_microk8s "$target_ip" "$cname"

  if [[ "$role" != "worker" ]]; then
    wait_apiserver_endpoint "$vpn_ip"
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
    CERTS=/var/snap/microk8s/current/certs
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
  sshrun "$target_ip" "incus exec ${cname} -- snap restart microk8s.daemon-kubelite"
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

# Configura o líder antes de gerar tokens ou executar joins.
echo ">>> Configurando rede VPN/nftables no líder..."
configure_microk8s_node "$MASTER_IP" "$MASTER_CONTAINER" "voter"
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
  do_join_bg "$MASTER_IP" "${MASTER_CONTAINERS[$j]}" "$(get_container_role "$j")" "$MASTER_CONTAINER_VPN_IP" &
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
    do_join_bg "$host_ip" "$cname" "$(get_container_role "$j")" "$MASTER_CONTAINER_VPN_IP" &
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
echo "=== Aplicando correções confirmadas em TODOS os nós (rolling) ==="
echo "    node-ip, advertise-address, certificado e iptables-nft"

# Todos os containers do host líder, inclusive membros antigos.
for j in "${!MASTER_CONTAINERS[@]}"; do
  cname="${MASTER_CONTAINERS[$j]}"
  role=$(get_container_role "$j")
  reconcile_microk8s_node "$MASTER_IP" "$cname" "$role"
done

# Todos os containers dos demais hosts, inclusive membros antigos.
for i in "${WORKER_IDX[@]}"; do
  host_ip="${IPS[$i]}"
  containers_str="${WORKER_CONTAINERS_MAP[$i]}"
  read -ra containers <<< "$containers_str"

  for j in "${!containers[@]}"; do
    cname="${containers[$j]}"
    role=$(get_container_role "$j")
    reconcile_microk8s_node "$host_ip" "$cname" "$role"
  done
done

echo
echo "=== Endpoints atuais do Service kubernetes ==="
sshrun "$MASTER_IP" \
  "incus exec ${MASTER_CONTAINER} -- microk8s kubectl get endpoints kubernetes -n default -o wide"

echo
echo "=== Aguardando Calico-node ficar pronto ==="
sshrun "$MASTER_IP" \
  "incus exec ${MASTER_CONTAINER} -- microk8s kubectl rollout status ds/calico-node -n kube-system --timeout=300s"

echo
echo "=== Verificando pods do kube-system ==="
sshrun "$MASTER_IP" \
  "incus exec ${MASTER_CONTAINER} -- microk8s kubectl wait --for=condition=Ready pod -n kube-system --all --timeout=300s"

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
ExecStart=/snap/microk8s/current/kubectl port-forward deployment/my-headlamp 4466:4466 -n kube-system --address 0.0.0.0
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

# O IP publico pertence ao host EC2. Ele será usado:
#   1. como SAN do certificado TLS;
#   2. como endereco externo mostrado ao final;
#   3. no proxy Incus host:443 -> container-lider:443.
SERVERPOD_PUBLIC_IP="$MASTER_IP"

SERVERPOD_DEPLOY_SCRIPT=$(cat <<DEPLOYEOF
#!/usr/bin/env bash
set -euo pipefail

cd /tmp

IMAGE_NAME="thedandare/fibo-serverpod-genui:v1.0.2"
PUBLIC_IP="${SERVERPOD_PUBLIC_IP}"

DEPLOYMENT_FILE="serverpod-deployment.yaml"
SERVICE_APP_FILE="serverpod-service.yaml"
INGRESS_FILE="serverpod-ingress.yaml"
DB_FILE="postgres-cluster.yaml"
TLS_OPENSSL_FILE="serverpod-openssl.cnf"
TLS_CERT_FILE="serverpod-tls.crt"
TLS_KEY_FILE="serverpod-tls.key"

echo "🚀 Validando e aplicando estado do ambiente no MicroK8s..."

kubectl_apply_retry() {
  local file="\$1"
  local attempt=0

  while [[ \$attempt -lt 10 ]]; do
    if microk8s kubectl apply -f "\$file" 2>/tmp/kubectl.err; then
      return 0
    fi

    attempt=\$((attempt + 1))
    echo "    ⚠️  Tentativa \$attempt falhou; aguardando API server..."
    cat /tmp/kubectl.err >&2
    sleep 5
  done

  echo "    ❌ Falha ao aplicar \$file apos 10 tentativas" >&2
  return 1
}

wait_for_ingress_controller() {
  echo "⏳ Aguardando o controlador Traefik do addon ingress..."

  local ready=0
  for i in \$(seq 1 60); do
    if microk8s kubectl get pods -n ingress \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' \
      2>/dev/null | grep -q ' Running'; then

      if microk8s kubectl wait \
        --namespace ingress \
        --for=condition=Ready pod \
        --all \
        --timeout=20s >/dev/null 2>&1; then
        ready=1
        break
      fi
    fi

    if [[ \$((i % 6)) -eq 0 ]]; then
      echo "    Ainda aguardando o Traefik... \$((i * 5))s"
    fi
    sleep 5
  done

  if [[ \$ready -ne 1 ]]; then
    echo "    ❌ O addon ingress esta habilitado, mas nenhum pod Traefik ficou Ready." >&2
    echo "    Recursos encontrados:" >&2
    microk8s kubectl get ingressclass >&2 || true
    microk8s kubectl get all -n ingress -o wide >&2 || true
    return 1
  fi

  echo "    ✅ Controlador Traefik pronto"
  microk8s kubectl get pods -n ingress -o wide
}

echo "🔌 Habilitando addons necessários..."
microk8s enable hostpath-storage >/dev/null
microk8s enable cloudnative-pg >/dev/null

# Workaround idempotente para o addon CloudNativePG quando o Deployment
# é criado apenas com command=["/manager"] e sem args=["controller"].
echo "🔧 Validando comando do controller CloudNativePG..."
for i in $(seq 1 60); do
  if microk8s kubectl get deployment cnpg-controller-manager -n cnpg-system >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

CNPG_ARGS=$(microk8s kubectl get deployment cnpg-controller-manager \
  -n cnpg-system \
  -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null || true)

if [[ "$CNPG_ARGS" != *controller* ]]; then
  echo "🔧 Corrigindo args do cnpg-controller-manager para: controller"
  microk8s kubectl patch deployment cnpg-controller-manager \
    -n cnpg-system \
    --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args","value":["controller"]}]'
fi

echo "⏳ Aguardando rollout do CloudNativePG..."
microk8s kubectl rollout status deployment/cnpg-controller-manager \
  -n cnpg-system \
  --timeout=180s

# O addon pode ficar registrado como enabled mesmo sem os workloads instalados.
# Primeiro tentamos habilitar normalmente. Se não surgirem pods, refazemos somente
# o addon ingress e validamos antes de continuar.
microk8s enable ingress >/dev/null || true

echo "⏳ Aguardando API server estabilizar..."
microk8s status --wait-ready --timeout 120

if ! wait_for_ingress_controller; then
  echo "♻️  Reinstalando apenas o addon ingress..."
  microk8s disable ingress || true
  microk8s enable ingress
  wait_for_ingress_controller
fi

echo "🔑 Aplicando credenciais declarativas do PostgreSQL..."
microk8s kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: postgres-superuser-credentials
  namespace: default
  labels:
    cnpg.io/reload: "true"
type: kubernetes.io/basic-auth
stringData:
  username: postgres
  password: F1bo6600
EOF

echo "📝 Gerando manifesto do cluster PostgreSQL..."
cat > "\$DB_FILE" <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres
  namespace: default
  labels:
    app: serverpod-db
spec:
  instances: 1
  # O operador passa a reconciliar continuamente a senha do superusuário
  # postgres a partir do Secret acima, inclusive em clusters já existentes.
  enableSuperuserAccess: true
  superuserSecret:
    name: postgres-superuser-credentials
  storage:
    size: 2Gi
  bootstrap:
    initdb:
      database: postgres
      owner: postgres
      secret:
        name: postgres-superuser-credentials
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-local
  namespace: default
spec:
  type: ExternalName
  externalName: postgres-rw.default.svc.cluster.local
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-nodeport
  namespace: default
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

echo "📝 Gerando manifesto da aplicacao..."
cat > "\$DEPLOYMENT_FILE" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fibo-serverpod-deployment
  namespace: default
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
          image: \$IMAGE_NAME
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
              valueFrom:
                secretKeyRef:
                  name: postgres-superuser-credentials
                  key: password
            - name: SERVERPOD_PASSWORD_database
              valueFrom:
                secretKeyRef:
                  name: postgres-superuser-credentials
                  key: password
            - name: SERVERPOD_PASSWORD_service
              valueFrom:
                secretKeyRef:
                  name: postgres-superuser-credentials
                  key: password
            - name: SERVERPOD_PASSWORD_redis
              valueFrom:
                secretKeyRef:
                  name: postgres-superuser-credentials
                  key: password
          readinessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 15
            timeoutSeconds: 6
            failureThreshold: 3

          livenessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 20
            timeoutSeconds: 6
            failureThreshold: 3
EOF

# O Ingress acessa o Service internamente. Portanto, ClusterIP é suficiente.
# /serverpod encaminha para a API na porta 8080.
# /control encaminha para a interface web na porta 8082.
echo "📝 Gerando Service interno do Serverpod..."
cat > "\$SERVICE_APP_FILE" <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: fibo-serverpod-service
  namespace: default
spec:
  type: ClusterIP
  selector:
    app: fibo-serverpod
  ports:
    - name: api
      protocol: TCP
      port: 8080
      targetPort: 8080
    - name: service
      protocol: TCP
      port: 8081
      targetPort: 8081
    - name: web
      protocol: TCP
      port: 8082
      targetPort: 8082
EOF

echo "🔐 Gerando certificado TLS autoassinado para o IP público \$PUBLIC_IP..."
cat > "\$TLS_OPENSSL_FILE" <<EOF
[req]
distinguished_name = distinguished_name
x509_extensions = v3_req
prompt = no

[distinguished_name]
CN = \$PUBLIC_IP

[v3_req]
subjectAltName = @alt_names
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
IP.1 = \$PUBLIC_IP
EOF

openssl req \
  -x509 \
  -nodes \
  -newkey rsa:2048 \
  -sha256 \
  -days 365 \
  -keyout "\$TLS_KEY_FILE" \
  -out "\$TLS_CERT_FILE" \
  -config "\$TLS_OPENSSL_FILE" >/dev/null 2>&1

microk8s kubectl create secret tls serverpod-tls \
  --namespace default \
  --cert="\$TLS_CERT_FILE" \
  --key="\$TLS_KEY_FILE" \
  --dry-run=client -o yaml |
microk8s kubectl apply -f -

# O Middleware remove /serverpod antes de entregar a requisição ao Serverpod.
# Exemplo:
#   cliente:   GET /serverpod/health
#   Serverpod: GET /health
echo "📝 Gerando Middleware e Ingress HTTPS..."
cat > "\$INGRESS_FILE" <<'EOF'
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: serverpod-strip-prefix
  namespace: default
spec:
  stripPrefix:
    prefixes:
      - /serverpod
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: fibo-serverpod-ingress
  namespace: default
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.middlewares: default-serverpod-strip-prefix@kubernetescrd
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: public
  tls:
    - secretName: serverpod-tls
  rules:
    - http:
        paths:
          - path: /serverpod
            pathType: Prefix
            backend:
              service:
                name: fibo-serverpod-service
                port:
                  name: api
          - path: /control
            pathType: Prefix
            backend:
              service:
                name: fibo-serverpod-service
                port:
                  name: web
EOF

echo "☸️  Aguardando operator e webhook do CloudNativePG..."
cnpg_ready=0
for i in \$(seq 1 120); do
  operator_ready=0
  microk8s kubectl get crd clusters.postgresql.cnpg.io >/dev/null 2>&1 || {
    sleep 5
    continue
  }

  microk8s kubectl wait \
    --for=condition=Ready pod \
    -n cnpg-system \
    --all \
    --timeout=10s >/dev/null 2>&1 && operator_ready=1

  if [[ \$operator_ready -eq 1 ]]; then
    webhook_addr=\$(microk8s kubectl get endpoints cnpg-webhook-service \
      -n cnpg-system \
      -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)

    if [[ -n "\$webhook_addr" ]]; then
      echo "    ✅ CNPG operator e webhook prontos"
      cnpg_ready=1
      break
    fi
  fi

  if [[ \$((i % 10)) -eq 0 ]]; then
    echo "    ⏳ Aguardando CNPG... \$((i * 5))s"
  fi
  sleep 5
done

if [[ \$cnpg_ready -ne 1 ]]; then
  echo "    ❌ Timeout: CNPG operator/webhook nao ficou pronto" >&2
  exit 1
fi

kubectl_apply_retry "\$DB_FILE"

echo "⏳ Aguardando hostpath-provisioner..."
microk8s kubectl wait \
  --for=condition=Ready pod \
  -l k8s-app=hostpath-provisioner \
  -n kube-system \
  --timeout=120s

echo "⏳ Aguardando PVC do PostgreSQL ficar Bound..."
pvc_bound=0
for i in \$(seq 1 60); do
  if microk8s kubectl get pvc \
    -l cnpg.io/cluster=postgres \
    -n default \
    -o jsonpath='{.items[*].status.phase}' 2>/dev/null |
    grep -q 'Bound'; then
    echo "    ✅ PVC Bound"
    pvc_bound=1
    break
  fi
  sleep 5
done

if [[ \$pvc_bound -ne 1 ]]; then
  echo "    ❌ Timeout: PVC do PostgreSQL nao ficou Bound" >&2
  exit 1
fi

kubectl_apply_retry "\$SERVICE_APP_FILE"
kubectl_apply_retry "\$DEPLOYMENT_FILE"
kubectl_apply_retry "\$INGRESS_FILE"

echo "⏳ Aguardando PostgreSQL..."
microk8s kubectl wait \
  --for=condition=Ready cluster/postgres \
  --timeout=300s

echo "⏳ Aguardando Deployment Serverpod..."
microk8s kubectl rollout status \
  deployment/fibo-serverpod-deployment \
  --namespace default \
  --timeout=300s

echo "⏳ Validando endpoints do Service..."
endpoint_ready=0
for i in \$(seq 1 60); do
  endpoints=\$(microk8s kubectl get endpointslice \
    -n default \
    -l kubernetes.io/service-name=fibo-serverpod-service \
    -o jsonpath='{.items[*].endpoints[*].addresses[*]}' 2>/dev/null || true)

  if [[ -n "\$endpoints" ]]; then
    echo "    ✅ Endpoints: \$endpoints"
    endpoint_ready=1
    break
  fi
  sleep 5
done

if [[ \$endpoint_ready -ne 1 ]]; then
  echo "    ❌ O Service fibo-serverpod-service ficou sem endpoints" >&2
  microk8s kubectl get pods -l app=fibo-serverpod -o wide >&2 || true
  microk8s kubectl describe service fibo-serverpod-service >&2 || true
  exit 1
fi

echo "⏳ Validando a rota HTTPS local do Traefik..."
https_ready=0
for i in \$(seq 1 60); do
  # Qualquer resposta HTTP comprova que TLS, Ingress e Service estão conectados.
  # 404/401/500 podem ser respostas legítimas da rota raiz do Serverpod.
  http_code=\$(curl -ksS \
    --connect-timeout 3 \
    --max-time 10 \
    -o /tmp/serverpod-ingress-response \
    -w '%{http_code}' \
    "https://127.0.0.1/serverpod/" 2>/dev/null || true)

  if [[ "\$http_code" =~ ^[1-5][0-9][0-9]\$ ]] && [[ "\$http_code" != "000" ]]; then
    echo "    ✅ Traefik respondeu localmente com HTTP \$http_code"
    https_ready=1
    break
  fi

  sleep 5
done

if [[ \$https_ready -ne 1 ]]; then
  echo "    ❌ O Traefik nao respondeu em https://127.0.0.1/serverpod/" >&2
  microk8s kubectl describe ingress fibo-serverpod-ingress >&2 || true
  microk8s kubectl get all -n ingress -o wide >&2 || true
  exit 1
fi

echo
echo "--------------------------------------------------------"
echo "✅ Aplicacao e Ingress configurados dentro do container."
echo "   Rota interna: https://127.0.0.1/serverpod/"
echo "--------------------------------------------------------"
DEPLOYEOF
)

# Executa a implantação Kubernetes dentro do container líder.
sudo ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "$SSH_PORT" \
  "root@$MASTER_IP" \
  "incus exec ${MASTER_CONTAINER} -- bash -s" \
  <<< "$SERVERPOD_DEPLOY_SCRIPT"

echo
echo "=== Expondo HTTPS do container líder no IP público do host EC2 ==="

# O proxy Incus escuta 0.0.0.0:443 no host EC2 e conecta à porta 443
# dentro do container líder. A operação é idempotente: remove a definição antiga
# e recria com o estado desejado.
sshrun "$MASTER_IP" "
  set -e
  incus config device remove '${MASTER_CONTAINER}' serverpod-https >/dev/null 2>&1 || true
  incus config device add '${MASTER_CONTAINER}' serverpod-https proxy \
    listen=tcp:0.0.0.0:443 \
    connect=tcp:127.0.0.1:443
"

echo
echo "=== Testando o endpoint público ==="

PUBLIC_HTTP_CODE=$(curl -ksS \
  --connect-timeout 5 \
  --max-time 20 \
  -o /tmp/serverpod-public-response \
  -w '%{http_code}' \
  "https://${SERVERPOD_PUBLIC_IP}/serverpod/" 2>/dev/null || true)

if [[ "$PUBLIC_HTTP_CODE" =~ ^[1-5][0-9][0-9]$ ]] && [[ "$PUBLIC_HTTP_CODE" != "000" ]]; then
  echo "✅ Endpoint público respondeu com HTTP ${PUBLIC_HTTP_CODE}"
else
  echo "⚠️  O endpoint externo ainda não respondeu." >&2
  echo "    Verifique se o Security Group da EC2 permite TCP/443." >&2
  echo "    Teste manual: curl -vk https://${SERVERPOD_PUBLIC_IP}/serverpod/" >&2
fi

echo
echo "========================================================"
echo "URL Serverpod:"
echo "  https://${SERVERPOD_PUBLIC_IP}/serverpod/"
echo
echo "Observacao:"
echo "  O certificado é autoassinado; clientes devem confiar nele ou ignorar"
echo "  temporariamente a validação durante os testes."
echo "========================================================"
echo
echo "Concluido."
