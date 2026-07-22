#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# deploy-fibo-serverpod-local.sh
#
# Script declarativo, idempotente e validado para deploy do fibo-serverpod
# no cluster MicroK8s local (leonk9s = master).
#
# Executa via 'incus exec leonk9s' sem SSH.
# ==============================================================================

MASTER_CONTAINER="leonk9s"

IMAGE_NAME="thedandare/fibo-serverpod-genui:v1.0.1"
DB_PASSWORD="F1bo6600"

MANIFESTS_DIR="/tmp/fibo-serverpod-manifests"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERRO: $*" >&2; exit 1; }

k() { incus exec "$MASTER_CONTAINER" -- sudo microk8s kubectl "$@"; }

# ------------------------------------------------------------------------------
# Validações iniciais
# ------------------------------------------------------------------------------
log "Verificando container ${MASTER_CONTAINER}..."
state=$(incus list -c n,s --format csv 2>/dev/null | grep "^${MASTER_CONTAINER}," | cut -d',' -f2 || echo "")
[[ "$state" == "RUNNING" ]] || fail "Container ${MASTER_CONTAINER} não está RUNNING (${state:-não encontrado})"

log "Verificando MicroK8s no master..."
incus exec "$MASTER_CONTAINER" -- sudo microk8s status --wait-ready --timeout 30 >/dev/null

# ------------------------------------------------------------------------------
# 1. Addons idempotentes
# ------------------------------------------------------------------------------
log "=== [1/8] Habilitando addons MicroK8s ==="
incus exec "$MASTER_CONTAINER" -- sudo microk8s enable storage        2>&1 | tail -1
incus exec "$MASTER_CONTAINER" -- sudo microk8s enable cloudnative-pg 2>&1 | tail -1
incus exec "$MASTER_CONTAINER" -- sudo microk8s enable ingress        2>&1 | tail -1

# ------------------------------------------------------------------------------
# 2. Secret de credenciais (declarativo/idempotente via apply)
# ------------------------------------------------------------------------------
log "=== [2/8] Aplicando Secret postgres-user-password ==="
DB_USERNAME_B64=$(echo -n "postgres"      | base64)
DB_PASSWORD_B64=$(echo -n "${DB_PASSWORD}" | base64)
k apply -f - <<EOFYAML
apiVersion: v1
kind: Secret
metadata:
  name: postgres-user-password
  namespace: default
type: Opaque
data:
  username: ${DB_USERNAME_B64}
  password: ${DB_PASSWORD_B64}
EOFYAML

# ------------------------------------------------------------------------------
# 3. Gerar manifestos no container
# ------------------------------------------------------------------------------
log "=== [3/8] Gerando manifestos em ${MASTER_CONTAINER}:${MANIFESTS_DIR} ==="
incus exec "$MASTER_CONTAINER" -- mkdir -p "$MANIFESTS_DIR"

# --- postgres-cluster.yaml ---
incus exec "$MASTER_CONTAINER" -- bash -c "cat > ${MANIFESTS_DIR}/postgres-cluster.yaml" <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres
  labels:
    app: serverpod-db
spec:
  instances: 1
  enableSuperuserAccess: true
  superuserSecret:
    name: postgres-user-password
  storage:
    size: 2Gi
  bootstrap:
    initdb:
      database: postgres
      owner: postgres
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

# --- redis.yaml ---
incus exec "$MASTER_CONTAINER" -- bash -c "cat > ${MANIFESTS_DIR}/redis.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
        args: ["--requirepass", "F1bo6600"]
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: default
spec:
  selector:
    app: redis
  ports:
    - port: 6379
      targetPort: 6379
EOF

# --- deployment.yaml ---
incus exec "$MASTER_CONTAINER" -- bash -c "cat > ${MANIFESTS_DIR}/deployment.yaml" <<EOF
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
        image: ${IMAGE_NAME}
        imagePullPolicy: IfNotPresent
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
        - name: SERVERPOD_PASSWORD_database
          value: "${DB_PASSWORD}"
        - name: SERVERPOD_PASSWORD_service
          value: "${DB_PASSWORD}"
        - name: SERVERPOD_PASSWORD_redis
          value: "${DB_PASSWORD}"
        - name: SERVERPOD_REDIS_HOST
          value: "redis.default.svc.cluster.local"
        - name: SERVERPOD_REDIS_PORT
          value: "6379"
        - name: OPENAI_API_KEY
          value: "${OPENAI_API_KEY:-}"
EOF

# --- serverpod-service-exposed.yaml ---
incus exec "$MASTER_CONTAINER" -- bash -c "cat > ${MANIFESTS_DIR}/serverpod-service-exposed.yaml" <<'EOF'
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

# --- serverpod-ingress.yaml ---
incus exec "$MASTER_CONTAINER" -- bash -c "cat > ${MANIFESTS_DIR}/serverpod-ingress.yaml" <<'EOF'
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

log "  Manifestos gerados."

# ------------------------------------------------------------------------------
# 4. Apply declarativo
# ------------------------------------------------------------------------------
log "=== [4/8] Aplicando manifestos (kubectl apply) ==="
k apply -f "${MANIFESTS_DIR}/postgres-cluster.yaml"
k apply -f "${MANIFESTS_DIR}/redis.yaml"
k apply -f "${MANIFESTS_DIR}/serverpod-service-exposed.yaml"
k apply -f "${MANIFESTS_DIR}/deployment.yaml"
k apply -f "${MANIFESTS_DIR}/serverpod-ingress.yaml"

# ------------------------------------------------------------------------------
# 5. Forçar rollout do deployment
# ------------------------------------------------------------------------------
log "=== [5/8] Forçando rollout do deployment ==="
k rollout restart deployment/fibo-serverpod-deployment
k rollout status  deployment/fibo-serverpod-deployment --timeout=120s

# ------------------------------------------------------------------------------
# 6. Aguardar PostgreSQL ficar Ready
# ------------------------------------------------------------------------------
log "=== [6/8] Aguardando cluster PostgreSQL (CNPG) ficar Ready ==="
for i in $(seq 1 30); do
  phase=$(k get cluster postgres -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  ready=$(k get cluster postgres -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")
  log "  tentativa $i/30: phase=${phase:-?} readyInstances=${ready}"
  if [[ "$phase" == "Cluster in healthy state" || "$ready" == "1" ]]; then
    log "  PostgreSQL Ready."
    break
  fi
  sleep 10
done

# ------------------------------------------------------------------------------
# 7. Teste de conectividade HTTP nas 3 portas NodePort
# ------------------------------------------------------------------------------
log "=== [7/8] Testando conectividade NodePort ==="
MASTER_IP="192.168.0.9"
for port in 30080 30081 30082; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://${MASTER_IP}:${port}/" 2>/dev/null || echo "ERR")
  if [[ "$code" == "ERR" || "$code" == "000" ]]; then
    log "  AVISO: porta ${port} sem resposta (HTTP ${code}) — pod pode ainda estar iniciando"
  else
    log "  OK: porta ${port} respondeu HTTP ${code}"
  fi
done

# ------------------------------------------------------------------------------
# 8. Resumo final
# ------------------------------------------------------------------------------
log "=== [8/8] Resumo do cluster ==="
echo
k get pods      -n default
echo
k get services  -n default
echo
k get ingress   -n default
echo
k get cluster   -n default 2>/dev/null || true
echo
log "Deploy concluido. Endpoints:"
log "  API     : http://192.168.0.9:30080"
log "  Service : http://192.168.0.9:30081"
log "  Web/GUI : http://192.168.0.9:30082"
