#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# integrar-microceph-microk8s.sh
#
# Executado dentro do container master do MicroCeph para conectar o cluster
# Ceph externo ao MicroK8s via rook-ceph external, criando a StorageClass.
# ==============================================================================

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] AVISO: $*" >&2; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERRO: $*" >&2; exit 1; }

# Verifica se estamos rodando dentro do container Incus
if ! command -v microceph >/dev/null 2>&1; then
    fail "microceph nao encontrado. Este script deve ser executado dentro do container master do MicroCeph."
fi

if ! command -v microk8s >/dev/null 2>&1; then
    fail "microk8s nao encontrado. Verifique se o addon esta habilitado."
fi

# ==============================================================================
# 1. Instala dependencias Python do Ceph
# ==============================================================================
log "Instalando python3-rados e python3-rbd..."
need_install=0
for pkg in python3-rados python3-rbd; do
    if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii  $pkg"; then
        need_install=1
        break
    fi
done
if [[ "$need_install" -eq 1 ]]; then
    apt-get update -qq
    apt-get install -y -qq python3-rados python3-rbd
    log "Dependencias Ceph Python instaladas."
else
    log "Dependencias Ceph Python ja instaladas."
fi

# ==============================================================================
# 2. Habilita prometheus module no MicroCeph
# ==============================================================================
log "Habilitando modulo prometheus do Ceph (se necessario)..."
sudo microceph.ceph mgr module enable prometheus || true

# ==============================================================================
# 3. Conecta o MicroCeph externo ao MicroK8s
# ==============================================================================
log "Executando microk8s connect-external-ceph..."
if ! sudo microk8s connect-external-ceph 2>&1; then
    fail "microk8s connect-external-ceph falhou"
fi
log "connect-external-ceph concluido."

# ==============================================================================
# 4. Aguarda StorageClass
# ==============================================================================
log "Aguardando StorageClass ceph-rbd..."
for i in {1..30}; do
    if sudo microk8s kubectl get storageclass ceph-rbd >/dev/null 2>&1; then
        log "StorageClass ceph-rbd encontrada."
        break
    fi
    log "Tentativa $i/30: StorageClass ainda nao disponivel, aguardando 10s..."
    sleep 10
done

if ! sudo microk8s kubectl get storageclass ceph-rbd >/dev/null 2>&1; then
    fail "StorageClass ceph-rbd nao foi criada apos 5 minutos"
fi

# ==============================================================================
# 5. Testa provisionamento com PVC de teste
# ==============================================================================
TEST_PVC_NAME="test-microceph-pvc"
TEST_PVC_NS="default"

log "Criando PVC de teste $TEST_PVC_NAME..."
cat <<YAML | sudo microk8s kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $TEST_PVC_NAME
  namespace: $TEST_PVC_NS
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: ceph-rbd
YAML

log "Aguardando PVC $TEST_PVC_NAME ficar Bound..."
for i in {1..30}; do
    status=$(sudo microk8s kubectl get pvc "$TEST_PVC_NAME" -n "$TEST_PVC_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$status" == "Bound" ]]; then
        log "PVC $TEST_PVC_NAME esta Bound."
        break
    fi
    log "Tentativa $i/30: PVC status=$status, aguardando 10s..."
    sleep 10
done

status=$(sudo microk8s kubectl get pvc "$TEST_PVC_NAME" -n "$TEST_PVC_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [[ "$status" != "Bound" ]]; then
    fail "PVC $TEST_PVC_NAME nao ficou Bound (status: $status)"
fi

# Limpa PVC de teste
log "Removendo PVC de teste..."
sudo microk8s kubectl delete pvc "$TEST_PVC_NAME" -n "$TEST_PVC_NS" --ignore-not-found=true

# ==============================================================================
# 6. Resumo final
# ==============================================================================
log "StorageClass criada e testada com sucesso:"
sudo microk8s kubectl get storageclass
log "Integracao MicroCeph -> MicroK8s concluida."
