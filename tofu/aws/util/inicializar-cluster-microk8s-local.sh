#!/usr/bin/env bash
set -eo pipefail

# ==============================================================================
# inicializar-cluster-microk8s-local.sh
#
# Versão para ambiente local (1 host Incus, sem SSH remoto):
#   - Usa 'incus exec' direto, sem SSH
#   - 3 containers: leonk9s (master), leonk7s e leonk8s (workers)
#   - Sem VPN: usa IPs locais (192.168.0.x) para join
#   - Detecção de cluster existente: pula hosts já no cluster
#   - Paralelização de waits e joins
# ==============================================================================

MAX_PARALLEL_JOBS=4

# ------------------------------------------------------------------------------
# Configuração dos containers
# ------------------------------------------------------------------------------
MASTER_CONTAINER="leonk9s"
MASTER_IP="192.168.0.9"

# Workers: array de "container:ip"
WORKER_ENTRIES=(
  "leonk7s:192.168.0.7"
  "leonk8s:192.168.0.8"
)

# Roles atribuídos por ordem de container no host (voter/voter/worker)
# Aqui: master=leader, workers=voter e worker
WORKER_ROLES=("voter" "worker")

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

iexec() {
  # Executa comando dentro de um container via incus exec
  local cname="$1"; shift
  incus exec "$cname" -- bash -lc "$(printf '%q' "$*")"
}

iexec_raw() {
  # Executa comando dentro de um container sem encapsular em bash -lc
  local cname="$1"; shift
  incus exec "$cname" -- "$@"
}

get_container_ip() {
  local cname="$1"
  incus list -c n,4 --format csv | grep "^${cname}," | cut -d',' -f2 | awk '{print $1}' | head -1
}

# Aguarda microk8s estar pronto dentro de um container
wait_microk8s() {
  local cname="$1"
  local restarted=0
  echo "    Aguardando microk8s ficar pronto em ${cname}..."
  for attempt in $(seq 1 30); do
    if iexec_raw "$cname" sudo microk8s status --wait-ready --timeout 10 2>/dev/null; then
      return 0
    fi
    if [[ $restarted -eq 0 && $attempt -ge 3 ]]; then
      echo "    microk8s nao iniciou, tentando snap restart microk8s em ${cname}..."
      iexec_raw "$cname" sudo snap restart microk8s 2>/dev/null || true
      restarted=1
      echo "    Aguardando 60s apos restart..."
      sleep 60
      continue
    fi
    echo "    tentativa $attempt/30 - aguardando 10s..."
    sleep 10
  done
  echo "    TIMEOUT: microk8s nao ficou pronto em ${cname}" >&2
  return 1
}

wait_microk8s_bg() {
  local cname="$1"
  local temp_file="/tmp/wait_result_${cname}"
  if wait_microk8s "$cname" > "$temp_file" 2>&1; then
    echo "OK" >> "$temp_file"
  else
    echo "FAILED" >> "$temp_file"
  fi
}

# Obtém lista de nomes de nodes no cluster (a partir do master)
get_cluster_nodes() {
  iexec_raw "$MASTER_CONTAINER" sudo microk8s kubectl get nodes \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo ""
}

# Verifica se um node já está no cluster
is_node_in_cluster() {
  local node_name="$1"
  local cluster_nodes="$2"
  [[ "$cluster_nodes" == *"$node_name"* ]]
}

# Gera token no master (token-ttl=-1 = não expira)
generate_token() {
  local add_node_out
  add_node_out=$(iexec_raw "$MASTER_CONTAINER" sudo microk8s add-node --token-ttl -1 2>/dev/null)

  local raw_token
  raw_token=$(echo "$add_node_out" | grep -oP '(?<=join )\S+:25000/\S+' | head -1)

  if [[ -z "$raw_token" ]]; then
    echo "    FALHA: nao foi possivel extrair token do add-node" >&2
    echo "    Saida do add-node: $add_node_out" >&2
    return 1
  fi

  # Substitui o IP do token pelo IP local do master
  echo "$raw_token" | sed "s|^[^:]*:25000/|${MASTER_IP}:25000/|"
}

# Executa join para um container worker
do_join() {
  local cname="$1"
  local role="$2"  # "voter" ou "worker"

  echo ">>> [${cname}] role=${role}"
  echo "    Gerando token no master para este no..."
  local node_token
  node_token=$(generate_token)
  if [[ -z "$node_token" ]]; then
    echo "    FALHA: nao foi possivel gerar token" >&2
    return 1
  fi
  echo "    Token gerado: ${node_token}"
  sleep 1

  local JOIN_CMD="sudo microk8s join ${node_token}"
  [[ "$role" == "worker" ]] && JOIN_CMD="$JOIN_CMD --worker"

  echo "    cmd: $JOIN_CMD"
  sleep 2
  if iexec_raw "$cname" bash -c "$JOIN_CMD"; then
    echo "    OK: ${cname} entrou como ${role}."
  else
    echo "    FALHA: ${cname}" >&2
  fi
  echo
}

do_join_bg() {
  local cname="$1"
  local role="$2"
  local temp_file="/tmp/join_result_${cname}"
  if do_join "$cname" "$role" > "$temp_file" 2>&1; then
    echo "OK" >> "$temp_file"
  else
    echo "FAILED" >> "$temp_file"
  fi
}

# Aguarda até MAX_PARALLEL_JOBS jobs em background
wait_for_slot() {
  while [[ $(jobs -r | wc -l) -ge $MAX_PARALLEL_JOBS ]]; do
    sleep 1
  done
}

# ==============================================================================
# 1. Mostrar configuração
# ==============================================================================
echo "=== Cluster MicroK8s - Ambiente Local Incus ==="
echo "    Master : ${MASTER_CONTAINER} (${MASTER_IP})"
for entry in "${WORKER_ENTRIES[@]}"; do
  cname="${entry%%:*}"
  ip="${entry##*:}"
  echo "    Worker : ${cname} (${ip})"
done
echo

# ==============================================================================
# 2. Verificar containers em execução
# ==============================================================================
echo ">>> Verificando containers..."
MISSING=()
for cname in "$MASTER_CONTAINER" $(printf '%s\n' "${WORKER_ENTRIES[@]}" | cut -d: -f1); do
  state=$(incus list -c n,s --format csv | grep "^${cname}," | cut -d',' -f2 | tr '[:upper:]' '[:lower:]')
  if [[ "$state" == "running" ]]; then
    echo "    [OK] ${cname} - RUNNING"
  else
    echo "    [ERRO] ${cname} - state='${state:-nao encontrado}'"
    MISSING+=("$cname")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERRO: containers nao encontrados ou nao em execucao: ${MISSING[*]}" >&2
  exit 1
fi
echo

# ==============================================================================
# 3. Aguardar microk8s no master
# ==============================================================================
echo ">>> Aguardando microk8s no master (${MASTER_CONTAINER})..."
wait_microk8s "$MASTER_CONTAINER"
echo

# ==============================================================================
# 4. Verificar cluster existente e filtrar já presentes
# ==============================================================================
echo ">>> Verificando nodes existentes no cluster..."
CLUSTER_NODES=$(get_cluster_nodes)
echo "    Nodes no cluster: ${CLUSTER_NODES:-"(nenhum)"}"
echo

WORKERS_TO_JOIN=()   # array de "cname:role"
for i in "${!WORKER_ENTRIES[@]}"; do
  entry="${WORKER_ENTRIES[$i]}"
  cname="${entry%%:*}"
  role="${WORKER_ROLES[$i]}"
  if is_node_in_cluster "$cname" "$CLUSTER_NODES"; then
    echo "    [SKIP] ${cname} já está no cluster"
  else
    echo "    [PENDENTE] ${cname} role=${role}"
    WORKERS_TO_JOIN+=("${cname}:${role}")
  fi
done
echo

if [[ ${#WORKERS_TO_JOIN[@]} -eq 0 ]]; then
  echo ">>> Todos os workers já estão no cluster. Pulando joins."
fi

# ==============================================================================
# 5. Aguardar microk8s nos workers que serão adicionados (PARALELO)
# ==============================================================================
echo "--- Aguardando microk8s nos workers pendentes (PARALELO) ---"
PIDS=()
for entry in "${WORKERS_TO_JOIN[@]}"; do
  cname="${entry%%:*}"
  wait_for_slot
  wait_microk8s_bg "$cname" &
  PIDS+=($!)
done

echo ">>> Aguardando conclusao dos waits..."
for pid in "${PIDS[@]}"; do
  wait "$pid"
done

# Exibir resultados dos waits
for entry in "${WORKERS_TO_JOIN[@]}"; do
  cname="${entry%%:*}"
  temp_file="/tmp/wait_result_${cname}"
  echo "--- Resultado wait ${cname} ---"
  cat "$temp_file" 2>/dev/null || true
  rm -f "$temp_file"
done
echo

# ==============================================================================
# 6. Executar joins (sequencial para evitar race no master ao gerar tokens)
# ==============================================================================
echo "--- Executando joins ---"
for entry in "${WORKERS_TO_JOIN[@]}"; do
  cname="${entry%%:*}"
  role="${entry##*:}"
  do_join "$cname" "$role"
  sleep 2
done
echo

# ==============================================================================
# 7. Status final
# ==============================================================================
echo "=== Status final do cluster ==="
iexec_raw "$MASTER_CONTAINER" sudo microk8s kubectl get nodes || true

echo
echo "=== Configurando aliases kubectl/helm no master ==="
iexec_raw "$MASTER_CONTAINER" bash -c '
  grep -q "alias kubectl=" ~/.bashrc || echo "alias kubectl=\"microk8s kubectl\"" >> ~/.bashrc
  grep -q "alias helm=" ~/.bashrc    || echo "alias helm=\"microk8s helm\""       >> ~/.bashrc
' || true

echo
echo "=== Configurando Calico IP_AUTODETECTION_METHOD para range local ==="
CALICO_CIDR="192.168.0.0/24"
echo "    CIDR: $CALICO_CIDR"
CALICO_ENV_IDX=$(iexec_raw "$MASTER_CONTAINER" sudo microk8s kubectl get daemonset calico-node -n kube-system \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}' 2>/dev/null \
  | grep -n 'IP_AUTODETECTION_METHOD' | cut -d: -f1 | head -1 || true)
if [[ -n "$CALICO_ENV_IDX" ]]; then
  CALICO_ARRAY_IDX=$(( CALICO_ENV_IDX - 1 ))
  echo "    IP_AUTODETECTION_METHOD ja existe no indice $CALICO_ARRAY_IDX, atualizando..."
  CALICO_PATCH="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env/${CALICO_ARRAY_IDX}/value\",\"value\":\"cidr=${CALICO_CIDR}\"}]"
else
  echo "    IP_AUTODETECTION_METHOD nao encontrado, adicionando..."
  CALICO_PATCH="[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env/-\",\"value\":{\"name\":\"IP_AUTODETECTION_METHOD\",\"value\":\"cidr=${CALICO_CIDR}\"}}]"
fi
iexec_raw "$MASTER_CONTAINER" sudo microk8s kubectl patch daemonset calico-node -n kube-system \
  --type=json -p "${CALICO_PATCH}" || true

echo
echo "=== Habilitando addons community e rook-ceph ==="
iexec_raw "$MASTER_CONTAINER" sudo microk8s enable community || true
iexec_raw "$MASTER_CONTAINER" sudo microk8s enable rook-ceph || true

echo
echo "=== Instalando Headlamp via Helm ==="
iexec_raw "$MASTER_CONTAINER" sudo microk8s helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ || true
iexec_raw "$MASTER_CONTAINER" sudo microk8s helm repo update || true
iexec_raw "$MASTER_CONTAINER" sudo microk8s helm upgrade --install my-headlamp headlamp/headlamp --namespace kube-system || true

echo
echo "=== Expondo Headlamp na porta 4466 ==="
iexec_raw "$MASTER_CONTAINER" sudo microk8s kubectl expose deployment my-headlamp \
  --port=4466 --target-port=4466 --name=my-headlamp-service -n kube-system || true

echo
echo "=== Iniciando port-forward do Headlamp em background ==="
pkill -f "port-forward.*my-headlamp" 2>/dev/null || true
nohup incus exec "$MASTER_CONTAINER" -- sudo microk8s kubectl port-forward \
  deployment/my-headlamp 4466:4466 -n kube-system --address 0.0.0.0 \
  > /tmp/headlamp-portforward.log 2>&1 &
sleep 3
echo "    port-forward rodando em background (PID $!)"
echo "    log: /tmp/headlamp-portforward.log (no host)"
cat /tmp/headlamp-portforward.log 2>/dev/null || true

echo
echo "=== Acesso ao Headlamp ==="
iexec_raw "$MASTER_CONTAINER" sudo microk8s kubectl apply -f - <<'EOFYAML' || true
apiVersion: v1
kind: Secret
metadata:
  name: my-headlamp-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: my-headlamp
type: kubernetes.io/service-account-token
EOFYAML
sleep 2
HEADLAMP_TOKEN=$(iexec_raw "$MASTER_CONTAINER" sudo microk8s kubectl get secret my-headlamp-token \
  -n kube-system -o jsonpath='{.data.token}' 2>/dev/null | base64 -d) || true
if [[ -n "$HEADLAMP_TOKEN" ]]; then
  echo
  echo "    URL   : http://${MASTER_IP}:4466"
  echo
  echo "    Token (permanente, sem expiracao):"
  echo "$HEADLAMP_TOKEN"
else
  echo "    AVISO: nao foi possivel obter token (deployment pode ainda estar inicializando)" >&2
  echo "    URL   : http://${MASTER_IP}:4466"
  echo "    Gere manualmente: microk8s kubectl get secret my-headlamp-token -n kube-system -o jsonpath='{.data.token}' | base64 -d"
fi

echo
echo "Concluido."
