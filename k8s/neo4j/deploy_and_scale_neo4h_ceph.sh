 #!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# Neo4j Enterprise 2026.06
# Deploy + Restore + Scale para cluster de 3 servidores
# Storage: Rook/Ceph RBD
#
# Fluxo:
#
#   1. Valida MicroK8s, Helm, Ceph e dump.
#   2. Cria StorageClass dedicada para Neo4j com Retain.
#   3. Opcionalmente remove deployment anterior.
#   4. Cria Neo4j Server 1 em Ceph, inicialmente standalone/offline.
#   5. Restaura neo4j.dump no Server 1.
#   6. Inicia Server 1 como standalone.
#   7. Coloca Server 1 offline.
#   8. Faz dump do banco system.
#   9. Configura Server 1 para cluster de 3 nós.
#  10. Cria Server 2 e Server 3 em Ceph, offline.
#  11. Restaura system.dump nos Servers 2 e 3.
#  12. Inicia os três servidores.
#  13. Altera o banco neo4j para 3 primaries.
#  14. Configura 3 primaries como padrão para novos databases.
#  15. Valida cluster, PVCs, StorageClass e distribuição dos pods.
#
# IMPORTANTE:
#
# - Cada servidor Neo4j é um Helm release separado.
# - Cada servidor recebe seu próprio PVC Ceph RBD.
# - Todos compartilham o mesmo neo4j.name.
# - NÃO usamos nodeSelector.
# - podAntiAffinity=true impede membros do mesmo cluster
#   de ficarem no mesmo Kubernetes node.
# - Se um nó morrer, o PVC RBD pode ser reanexado em outro
#   nó elegível disponível.
# - A StorageClass dedicada usa Retain para evitar que a
#   remoção acidental de um PVC destrua o RBD automaticamente.
#
# ============================================================


# ============================================================
# CONFIGURAÇÃO
# ============================================================

VM="${VM:-leonk7s}"

NAMESPACE="${NAMESPACE:-neo4j}"

BASE_VALUES="${BASE_VALUES:-values.yaml}"

DUMP="${DUMP:-neo4j.dump}"
DATABASE="${DATABASE:-neo4j}"

#
# Nome lógico do cluster Neo4j.
#
# Todos os Helm releases precisam usar o MESMO neo4j.name.
#
CLUSTER_NAME="${CLUSTER_NAME:-neo4j-cluster}"

#
# Cada servidor Neo4j é um Helm release separado.
#
SERVER1="${SERVER1:-my-neo4j-release}"
SERVER2="${SERVER2:-my-neo4j-release-2}"
SERVER3="${SERVER3:-my-neo4j-release-3}"

POD1="${SERVER1}-0"
POD2="${SERVER2}-0"
POD3="${SERVER3}-0"

#
# StorageClass Ceph existente.
#
SOURCE_STORAGE_CLASS="${SOURCE_STORAGE_CLASS:-ceph-rbd}"

#
# StorageClass exclusiva criada pelo script.
#
# Será uma cópia da ceph-rbd, mas com:
#
#   reclaimPolicy: Retain
#
NEO4J_STORAGE_CLASS="${NEO4J_STORAGE_CLASS:-neo4j-ceph-rbd-retain}"

#
# Mantive 2Gi como no seu values.yaml atual.
#
# Para produção real provavelmente você vai querer aumentar:
#
#   DATA_SIZE=20Gi ./deploy_and_scale_neo4h_ceph.sh
#
DATA_SIZE="${DATA_SIZE:-2Gi}"

CHART="${CHART:-neo4j/neo4j}"

#
# Versão que você está usando atualmente:
#
#   neo4j-2026.6.0
#   app 2026.06.0
#
CHART_VERSION="${CHART_VERSION:-2026.6.0}"

#
# Tempo máximo para rollout.
#
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-900s}"

#
# Segurança:
#
# Se existir qualquer um dos releases/PVCs deste deployment,
# o script NÃO apaga nada por padrão.
#
# Para reconstruir o deployment existente:
#
#   RESET_EXISTING=1 ./deploy_and_scale_neo4h_ceph.sh
#
RESET_EXISTING="${RESET_EXISTING:-0}"


# ============================================================
# DIRETÓRIOS TEMPORÁRIOS
# ============================================================

LOCAL_TMP="$(mktemp -d)"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

REMOTE_DIR="/root/neo4j-deploy-ceph"

REMOTE_BASE_VALUES="${REMOTE_DIR}/values.yaml"
REMOTE_DUMP="${REMOTE_DIR}/${DATABASE}.dump"

REMOTE_COMMON="${REMOTE_DIR}/common.yaml"

REMOTE_STANDALONE_OFFLINE="${REMOTE_DIR}/standalone-offline.yaml"
REMOTE_STANDALONE_ONLINE="${REMOTE_DIR}/standalone-online.yaml"

REMOTE_CLUSTER_OFFLINE="${REMOTE_DIR}/cluster-offline.yaml"
REMOTE_CLUSTER_ONLINE="${REMOTE_DIR}/cluster-online.yaml"

REMOTE_SYSTEM_DUMP="${REMOTE_DIR}/system.dump"

LOCAL_SYSTEM_DUMP="system.bootstrap.${TIMESTAMP}.dump"


# ============================================================
# FUNÇÕES
# ============================================================

section()
{
    echo
    echo "============================================================"
    echo " $*"
    echo "============================================================"
}


info()
{
    echo "[INFO] $*"
}


warn()
{
    echo "[WARN] $*" >&2
}


die()
{
    echo
    echo "[ERRO] $*" >&2
    exit 1
}


kube()
{
    incus exec "$VM" -- microk8s kubectl "$@"
}


helmx()
{
    incus exec "$VM" -- microk8s helm "$@"
}


vm()
{
    incus exec "$VM" -- "$@"
}


release_exists()
{
    helmx status "$1" \
        -n "$NAMESPACE" \
        >/dev/null 2>&1
}


pvc_name()
{
    echo "data-${1}-0"
}


wait_pod_running()
{
    local pod="$1"
    local timeout="${2:-600}"
    local start="$SECONDS"

    while (( SECONDS - start < timeout ))
    do
        local phase

        phase="$(
            kube get pod "$pod" \
                -n "$NAMESPACE" \
                -o jsonpath='{.status.phase}' \
                2>/dev/null || true
        )"

        if [[ "$phase" == "Running" ]]
        then
            info "$pod está Running."
            return 0
        fi

        info "$pod: ${phase:-aguardando criação}"
        sleep 2
    done

    kube describe pod "$pod" \
        -n "$NAMESPACE" \
        2>/dev/null || true

    die "Timeout aguardando $pod ficar Running."
}


wait_pod_recreated_running()
{
    local pod="$1"
    local old_uid="$2"
    local timeout="${3:-600}"
    local start="$SECONDS"

    while (( SECONDS - start < timeout ))
    do
        local uid=""
        local phase=""

        uid="$(
            kube get pod "$pod" \
                -n "$NAMESPACE" \
                -o jsonpath='{.metadata.uid}' \
                2>/dev/null || true
        )"

        phase="$(
            kube get pod "$pod" \
                -n "$NAMESPACE" \
                -o jsonpath='{.status.phase}' \
                2>/dev/null || true
        )"

        if [[ -n "$uid" ]] &&
           [[ "$uid" != "$old_uid" ]] &&
           [[ "$phase" == "Running" ]]
        then
            info "$pod foi recriado e está Running."
            return 0
        fi

        info "$pod: aguardando restart para maintenance mode..."
        sleep 2
    done

    kube describe pod "$pod" \
        -n "$NAMESPACE" \
        2>/dev/null || true

    die "Timeout aguardando restart de $pod."
}


wait_rollout()
{
    local release="$1"

    kube rollout status \
        "statefulset/${release}" \
        -n "$NAMESPACE" \
        --watch \
        --timeout="$ROLLOUT_TIMEOUT"
}


wait_pod_deleted()
{
    local pod="$1"
    local timeout="${2:-180}"
    local start="$SECONDS"

    while (( SECONDS - start < timeout ))
    do
        if ! kube get pod "$pod" \
            -n "$NAMESPACE" \
            >/dev/null 2>&1
        then
            return 0
        fi

        sleep 2
    done

    die "Timeout aguardando remoção de $pod."
}


assert_pvc_storage_class()
{
    local release="$1"
    local pvc
    local phase
    local storage_class

    pvc="$(pvc_name "$release")"

    info "Aguardando PVC $pvc..."

    local start="$SECONDS"

    while (( SECONDS - start < 600 ))
    do
        phase="$(
            kube get pvc "$pvc" \
                -n "$NAMESPACE" \
                -o jsonpath='{.status.phase}' \
                2>/dev/null || true
        )"

        if [[ "$phase" == "Bound" ]]
        then
            break
        fi

        info "$pvc: ${phase:-aguardando provisionamento}"
        sleep 2
    done

    [[ "$phase" == "Bound" ]] ||
        die "PVC $pvc não ficou Bound."

    storage_class="$(
        kube get pvc "$pvc" \
            -n "$NAMESPACE" \
            -o jsonpath='{.spec.storageClassName}'
    )"

    if [[ "$storage_class" != "$NEO4J_STORAGE_CLASS" ]]
    then
        die \
            "PVC $pvc usa StorageClass '$storage_class', esperado '$NEO4J_STORAGE_CLASS'."
    fi

    info "$pvc -> $storage_class -> Bound"
}


cypher_system()
{
    local query="$1"

    kube exec \
        -n "$NAMESPACE" \
        "$POD1" \
        -- cypher-shell \
            -a "bolt://localhost:7687" \
            -u neo4j \
            -p "$NEO4J_PASSWORD" \
            -d system \
            "$query"
}


on_error()
{
    local rc=$?

    echo
    echo "============================================================"
    echo " DEPLOY INTERROMPIDO"
    echo "============================================================"
    echo

    kube get pods \
        -n "$NAMESPACE" \
        -o wide \
        2>/dev/null || true

    echo

    kube get pvc \
        -n "$NAMESPACE" \
        2>/dev/null || true

    echo
    echo "O script NÃO fará rollback destrutivo automaticamente."
    echo "Os recursos existentes foram preservados para diagnóstico."
    echo

    exit "$rc"
}


cleanup()
{
    rm -rf "$LOCAL_TMP"
}


trap on_error ERR
trap cleanup EXIT


# ============================================================
# 1. PREFLIGHT LOCAL
# ============================================================

section "PREFLIGHT"

command -v incus >/dev/null 2>&1 ||
    die "incus não encontrado."

[[ -f "$BASE_VALUES" ]] ||
    die "Arquivo $BASE_VALUES não encontrado."

[[ -s "$DUMP" ]] ||
    die "Dump $DUMP não encontrado ou vazio."


case "$DATABASE" in
    *[!a-zA-Z0-9._-]*)
        die "Nome de database inválido: $DATABASE"
        ;;
esac


info "VM administradora:       $VM"
info "Namespace:               $NAMESPACE"
info "Cluster Neo4j:           $CLUSTER_NAME"
info "Server 1:                $SERVER1"
info "Server 2:                $SERVER2"
info "Server 3:                $SERVER3"
info "StorageClass origem:     $SOURCE_STORAGE_CLASS"
info "StorageClass Neo4j:      $NEO4J_STORAGE_CLASS"
info "Tamanho de cada PVC:     $DATA_SIZE"
info "Database:                $DATABASE"
info "Dump:                    $DUMP"

if command -v sha256sum >/dev/null 2>&1
then
    DUMP_SHA256="$(sha256sum "$DUMP" | awk '{print $1}')"
    info "SHA256 dump:             $DUMP_SHA256"
fi


# ============================================================
# 2. VALIDAR VM E MICROK8S
# ============================================================

section "VALIDANDO VM E MICROK8S"

incus info "$VM" >/dev/null 2>&1 ||
    die "VM/instância Incus $VM não encontrada."

vm microk8s status --wait-ready

vm python3 --version >/dev/null 2>&1 ||
    die "python3 não encontrado em $VM."


# ============================================================
# 3. HELM REPOSITORY
# ============================================================

section "CONFIGURANDO HELM"

helmx repo add \
    neo4j \
    https://helm.neo4j.com/neo4j \
    --force-update

helmx repo update


if ! helmx show chart \
    "$CHART" \
    --version "$CHART_VERSION" \
    >/dev/null 2>&1
then
    echo
    echo "Versões disponíveis:"
    helmx search repo neo4j/neo4j --versions | head -20 || true

    die "Chart $CHART versão $CHART_VERSION não encontrado."
fi


# ============================================================
# 4. NAMESPACE
# ============================================================

section "PREPARANDO NAMESPACE"

kube create namespace "$NAMESPACE" \
    >/dev/null 2>&1 || true


# ============================================================
# 5. VALIDAR NÚMERO DE NÓS
# ============================================================

section "VALIDANDO NÓS DO CLUSTER"

kube get nodes -o wide


READY_NODES="$(
    kube get nodes --no-headers |
        awk '$2 == "Ready" {count++} END {print count+0}'
)"


if (( READY_NODES < 3 ))
then
    die \
        "São necessários pelo menos 3 Kubernetes nodes Ready e schedulable. Encontrados: $READY_NODES"
fi


info "$READY_NODES nodes Ready disponíveis."


# ============================================================
# 6. CRIAR STORAGECLASS DEDICADA COM RETAIN
# ============================================================

section "PREPARANDO STORAGECLASS CEPH PARA NEO4J"


if ! kube get storageclass "$SOURCE_STORAGE_CLASS" \
    >/dev/null 2>&1
then
    die \
        "StorageClass de origem '$SOURCE_STORAGE_CLASS' não encontrada."
fi


SOURCE_PROVISIONER="$(
    kube get storageclass "$SOURCE_STORAGE_CLASS" \
        -o jsonpath='{.provisioner}'
)"


info \
    "StorageClass origem: $SOURCE_STORAGE_CLASS ($SOURCE_PROVISIONER)"


if kube get storageclass "$NEO4J_STORAGE_CLASS" \
    >/dev/null 2>&1
then

    info \
        "StorageClass $NEO4J_STORAGE_CLASS já existe."

else

    info \
        "Criando $NEO4J_STORAGE_CLASS a partir de $SOURCE_STORAGE_CLASS..."

    #
    # Clona a StorageClass Ceph existente.
    #
    # Preserva:
    #
    # - provisioner Rook/Ceph CSI
    # - pool
    # - clusterID
    # - secrets CSI
    # - imageFeatures
    # - volumeBindingMode
    # - allowVolumeExpansion
    #
    # Altera apenas:
    #
    # - metadata.name
    # - reclaimPolicy = Retain
    #
    # Também remove annotations da StorageClass original para que
    # a nova classe NÃO se torne default acidentalmente.
    #

    vm sh -lc "
        set -eu

        microk8s kubectl get storageclass '$SOURCE_STORAGE_CLASS' \
            -o json \
            > /tmp/neo4j-source-storageclass.json

        python3 -c '
import json
import sys

source = sys.argv[1]
target_name = sys.argv[2]

with open(source, \"r\") as f:
    data = json.load(f)

data[\"metadata\"] = {
    \"name\": target_name
}

data[\"reclaimPolicy\"] = \"Retain\"

data.pop(\"status\", None)

print(json.dumps(data))
' \
        /tmp/neo4j-source-storageclass.json \
        '$NEO4J_STORAGE_CLASS' \
        > /tmp/neo4j-target-storageclass.json

        microk8s kubectl create \
            -f /tmp/neo4j-target-storageclass.json

        rm -f \
            /tmp/neo4j-source-storageclass.json \
            /tmp/neo4j-target-storageclass.json
    "

fi


TARGET_PROVISIONER="$(
    kube get storageclass "$NEO4J_STORAGE_CLASS" \
        -o jsonpath='{.provisioner}'
)"


TARGET_RECLAIM_POLICY="$(
    kube get storageclass "$NEO4J_STORAGE_CLASS" \
        -o jsonpath='{.reclaimPolicy}'
)"


if [[ "$TARGET_PROVISIONER" != "$SOURCE_PROVISIONER" ]]
then
    die \
        "Provisioner da nova StorageClass não corresponde ao Ceph original."
fi


if [[ "$TARGET_RECLAIM_POLICY" != "Retain" ]]
then
    die \
        "StorageClass $NEO4J_STORAGE_CLASS não está configurada como Retain."
fi


kube get storageclass \
    "$SOURCE_STORAGE_CLASS" \
    "$NEO4J_STORAGE_CLASS"


# ============================================================
# 7. GERAR OVERRIDES HELM
# ============================================================

section "GERANDO CONFIGURAÇÃO HELM"


cat > "${LOCAL_TMP}/common.yaml" <<EOF
neo4j:
  name: "${CLUSTER_NAME}"

logInitialPassword: false

volumes:
  data:
    mode: "dynamic"
    dynamic:
      storageClassName: "${NEO4J_STORAGE_CLASS}"
      requests:
        storage: "${DATA_SIZE}"

podSpec:

  # O próprio Helm chart do Neo4j cria uma regra de
  # anti-affinity baseada em neo4j.name.
  #
  # Assim, dois membros deste cluster não serão agendados
  # no mesmo Kubernetes node.
  #
  # Não usamos nodeSelector.
  #
  podAntiAffinity: true
EOF


cat > "${LOCAL_TMP}/standalone-offline.yaml" <<EOF
neo4j:
  minimumClusterSize: 1
  offlineMaintenanceModeEnabled: true
EOF


cat > "${LOCAL_TMP}/standalone-online.yaml" <<EOF
neo4j:
  minimumClusterSize: 1
  offlineMaintenanceModeEnabled: false
EOF


cat > "${LOCAL_TMP}/cluster-offline.yaml" <<EOF
neo4j:
  minimumClusterSize: 3
  offlineMaintenanceModeEnabled: true
EOF


cat > "${LOCAL_TMP}/cluster-online.yaml" <<EOF
neo4j:
  minimumClusterSize: 3
  offlineMaintenanceModeEnabled: false
EOF


# ============================================================
# 8. COPIAR CONFIGURAÇÕES PARA A VM
# ============================================================

section "COPIANDO ARQUIVOS PARA $VM"


vm mkdir -p "$REMOTE_DIR"


incus file push \
    "$BASE_VALUES" \
    "$VM$REMOTE_BASE_VALUES"


incus file push \
    "$DUMP" \
    "$VM$REMOTE_DUMP"


incus file push \
    "${LOCAL_TMP}/common.yaml" \
    "$VM$REMOTE_COMMON"


incus file push \
    "${LOCAL_TMP}/standalone-offline.yaml" \
    "$VM$REMOTE_STANDALONE_OFFLINE"


incus file push \
    "${LOCAL_TMP}/standalone-online.yaml" \
    "$VM$REMOTE_STANDALONE_ONLINE"


incus file push \
    "${LOCAL_TMP}/cluster-offline.yaml" \
    "$VM$REMOTE_CLUSTER_OFFLINE"


incus file push \
    "${LOCAL_TMP}/cluster-online.yaml" \
    "$VM$REMOTE_CLUSTER_ONLINE"


# ============================================================
# 9. VALIDAR RENDERIZAÇÃO DO HELM ANTES DE APAGAR QUALQUER COISA
# ============================================================

section "VALIDANDO HELM TEMPLATE"


helmx template \
    "$SERVER1" \
    "$CHART" \
    --version "$CHART_VERSION" \
    -n "$NAMESPACE" \
    -f "$REMOTE_BASE_VALUES" \
    -f "$REMOTE_COMMON" \
    -f "$REMOTE_STANDALONE_OFFLINE" \
    --set disableLookups=true \
    >/dev/null


info "Helm template validado."


# ============================================================
# 10. DETECTAR DEPLOY ANTERIOR
# ============================================================

section "VERIFICANDO DEPLOY ANTERIOR"


EXISTING_RESOURCES=0


for release in \
    "$SERVER1" \
    "$SERVER2" \
    "$SERVER3"
do

    if release_exists "$release"
    then
        warn "Release encontrado: $release"
        EXISTING_RESOURCES=1
    fi

    pvc="$(pvc_name "$release")"

    if kube get pvc "$pvc" \
        -n "$NAMESPACE" \
        >/dev/null 2>&1
    then
        warn "PVC encontrado: $pvc"
        EXISTING_RESOURCES=1
    fi

done


if (( EXISTING_RESOURCES == 1 )) &&
   [[ "$RESET_EXISTING" != "1" ]]
then

    echo
    echo "Já existem recursos deste deployment."
    echo
    echo "Por segurança, nada foi removido."
    echo
    echo "Para reconstruir usando os novos volumes Ceph:"
    echo
    echo "  RESET_EXISTING=1 $0"
    echo

    exit 1

fi


# ============================================================
# 11. REMOVER DEPLOY ANTERIOR, SE SOLICITADO
# ============================================================

if (( EXISTING_RESOURCES == 1 ))
then

    section "REMOVENDO DEPLOY ANTERIOR"

    #
    # Primeiro remove os Helm releases.
    #
    # Ordem inversa.
    #

    for release in \
        "$SERVER3" \
        "$SERVER2" \
        "$SERVER1"
    do

        if release_exists "$release"
        then

            info "Removendo Helm release $release..."

            helmx uninstall \
                "$release" \
                -n "$NAMESPACE"

        fi

    done


    #
    # Aguarda pods desaparecerem antes de manipular PVCs.
    #

    for pod in \
        "$POD1" \
        "$POD2" \
        "$POD3"
    do

        if kube get pod "$pod" \
            -n "$NAMESPACE" \
            >/dev/null 2>&1
        then

            info "Aguardando remoção de $pod..."
            wait_pod_deleted "$pod"

        fi

    done


    #
    # Remove os PVCs.
    #
    # IMPORTANTE:
    #
    # Se o PVC já estiver usando a StorageClass Retain,
    # o PV/RBD subjacente continuará existindo.
    #
    # O script propositalmente NÃO apaga PVs Retain.
    #

    for release in \
        "$SERVER1" \
        "$SERVER2" \
        "$SERVER3"
    do

        pvc="$(pvc_name "$release")"

        if kube get pvc "$pvc" \
            -n "$NAMESPACE" \
            >/dev/null 2>&1
        then

            pv="$(
                kube get pvc "$pvc" \
                    -n "$NAMESPACE" \
                    -o jsonpath='{.spec.volumeName}'
            )"

            sc="$(
                kube get pvc "$pvc" \
                    -n "$NAMESPACE" \
                    -o jsonpath='{.spec.storageClassName}'
            )"

            info \
                "Removendo PVC $pvc (PV=$pv StorageClass=$sc)"

            kube delete pvc "$pvc" \
                -n "$NAMESPACE"

        fi

    done

fi


# ============================================================
# 12. INSTALAR SERVER 1 EM CEPH / STANDALONE / OFFLINE
# ============================================================

section "INSTALANDO SERVER 1 EM CEPH"


helmx install \
    "$SERVER1" \
    "$CHART" \
    --version "$CHART_VERSION" \
    -n "$NAMESPACE" \
    -f "$REMOTE_BASE_VALUES" \
    -f "$REMOTE_COMMON" \
    -f "$REMOTE_STANDALONE_OFFLINE"


wait_pod_running "$POD1"

assert_pvc_storage_class "$SERVER1"


# ============================================================
# 13. RESTAURAR NEO4J.DUMP
# ============================================================

section "RESTAURANDO $DATABASE.DUMP"


kube exec \
    -n "$NAMESPACE" \
    "$POD1" \
    -- rm -f "/backups/${DATABASE}.dump"


kube cp \
    "$REMOTE_DUMP" \
    "$NAMESPACE/$POD1:/backups/${DATABASE}.dump"


kube exec \
    -n "$NAMESPACE" \
    "$POD1" \
    -- ls -lh /backups


kube exec \
    -n "$NAMESPACE" \
    "$POD1" \
    -- neo4j-admin database load \
        --expand-commands \
        "$DATABASE" \
        --from-path=/backups \
        --overwrite-destination=true


info "Database $DATABASE restaurado."


# ============================================================
# 14. INICIAR SERVER 1 COMO STANDALONE
# ============================================================

section "INICIANDO SERVER 1 COMO STANDALONE"


helmx upgrade \
    "$SERVER1" \
    "$CHART" \
    --version "$CHART_VERSION" \
    -n "$NAMESPACE" \
    -f "$REMOTE_BASE_VALUES" \
    -f "$REMOTE_COMMON" \
    -f "$REMOTE_STANDALONE_ONLINE"


wait_rollout "$SERVER1"


# ============================================================
# 15. OBTER PASSWORD DO SECRET CRIADO PELO HELM
# ============================================================

section "VALIDANDO SERVER 1"


NEO4J_AUTH="$(
    vm sh -lc "
        microk8s kubectl get secret '${SERVER1}-auth' \
            -n '$NAMESPACE' \
            -o jsonpath='{.data.NEO4J_AUTH}' |
        base64 -d
    "
)"


NEO4J_PASSWORD="${NEO4J_AUTH#*/}"


[[ -n "$NEO4J_PASSWORD" ]] ||
    die "Não foi possível obter a senha Neo4j do Secret."


cypher_system \
    "RETURN 1 AS ok;"


# ============================================================
# 16. CONVERTER SERVER 1 PARA CONFIGURAÇÃO DE CLUSTER / OFFLINE
# ============================================================

section "PREPARANDO SERVER 1 PARA CLUSTER"


OLD_UID="$(
    kube get pod "$POD1" \
        -n "$NAMESPACE" \
        -o jsonpath='{.metadata.uid}'
)"


helmx upgrade \
    "$SERVER1" \
    "$CHART" \
    --version "$CHART_VERSION" \
    -n "$NAMESPACE" \
    -f "$REMOTE_BASE_VALUES" \
    -f "$REMOTE_COMMON" \
    -f "$REMOTE_CLUSTER_OFFLINE"


wait_pod_recreated_running \
    "$POD1" \
    "$OLD_UID"


# ============================================================
# 17. DUMP DO SYSTEM DATABASE
# ============================================================

section "CRIANDO SYSTEM.DUMP"


kube exec \
    -n "$NAMESPACE" \
    "$POD1" \
    -- rm -f /backups/system.dump


kube exec \
    -n "$NAMESPACE" \
    "$POD1" \
    -- neo4j-admin database dump \
        --expand-commands \
        system \
        --to-path=/backups


kube exec \
    -n "$NAMESPACE" \
    "$POD1" \
    -- ls -lh /backups/system.dump


kube cp \
    "$NAMESPACE/$POD1:/backups/system.dump" \
    "$REMOTE_SYSTEM_DUMP"


vm test -s "$REMOTE_SYSTEM_DUMP" ||
    die "system.dump não foi copiado corretamente."


#
# Mantém uma cópia local do system.dump usado para bootstrap.
#

incus file pull \
    "$VM$REMOTE_SYSTEM_DUMP" \
    "$LOCAL_SYSTEM_DUMP"


info \
    "Cópia local do system database: $LOCAL_SYSTEM_DUMP"


# ============================================================
# 18. INSTALAR SERVER 2 OFFLINE
# ============================================================

section "INSTALANDO SERVER 2"


helmx install \
    "$SERVER2" \
    "$CHART" \
    --version "$CHART_VERSION" \
    -n "$NAMESPACE" \
    -f "$REMOTE_BASE_VALUES" \
    -f "$REMOTE_COMMON" \
    -f "$REMOTE_CLUSTER_OFFLINE"


wait_pod_running "$POD2"

assert_pvc_storage_class "$SERVER2"


# ============================================================
# 19. INSTALAR SERVER 3 OFFLINE
# ============================================================

section "INSTALANDO SERVER 3"


helmx install \
    "$SERVER3" \
    "$CHART" \
    --version "$CHART_VERSION" \
    -n "$NAMESPACE" \
    -f "$REMOTE_BASE_VALUES" \
    -f "$REMOTE_COMMON" \
    -f "$REMOTE_CLUSTER_OFFLINE"


wait_pod_running "$POD3"

assert_pvc_storage_class "$SERVER3"


# ============================================================
# 20. RESTAURAR SYSTEM DATABASE NO SERVER 2
# ============================================================

section "RESTAURANDO SYSTEM DATABASE NO SERVER 2"


kube exec \
    -n "$NAMESPACE" \
    "$POD2" \
    -- rm -f /backups/system.dump


kube cp \
    "$REMOTE_SYSTEM_DUMP" \
    "$NAMESPACE/$POD2:/backups/system.dump"


kube exec \
    -n "$NAMESPACE" \
    "$POD2" \
    -- neo4j-admin database load \
        --expand-commands \
        system \
        --from-path=/backups \
        --overwrite-destination=true


# ============================================================
# 21. RESTAURAR SYSTEM DATABASE NO SERVER 3
# ============================================================

section "RESTAURANDO SYSTEM DATABASE NO SERVER 3"


kube exec \
    -n "$NAMESPACE" \
    "$POD3" \
    -- rm -f /backups/system.dump


kube cp \
    "$REMOTE_SYSTEM_DUMP" \
    "$NAMESPACE/$POD3:/backups/system.dump"


kube exec \
    -n "$NAMESPACE" \
    "$POD3" \
    -- neo4j-admin database load \
        --expand-commands \
        system \
        --from-path=/backups \
        --overwrite-destination=true


# ============================================================
# 22. INICIAR OS TRÊS SERVIDORES
# ============================================================

section "INICIANDO CLUSTER DE 3 SERVIDORES"


#
# Não aguardamos rollout individual aqui.
#
# minimumClusterSize=3 significa que os primeiros servidores
# podem esperar pelos demais.
#
# Primeiro colocamos TODOS online.
# Depois aguardamos os rollouts.
#


info "Iniciando $SERVER1..."

helmx upgrade \
    "$SERVER1" \
    "$CHART" \
    --version "$CHART_VERSION" \
    -n "$NAMESPACE" \
    -f "$REMOTE_BASE_VALUES" \
    -f "$REMOTE_COMMON" \
    -f "$REMOTE_CLUSTER_ONLINE"


info "Iniciando $SERVER2..."

helmx upgrade \
    "$SERVER2" \
    "$CHART" \
    --version "$CHART_VERSION" \
    -n "$NAMESPACE" \
    -f "$REMOTE_BASE_VALUES" \
    -f "$REMOTE_COMMON" \
    -f "$REMOTE_CLUSTER_ONLINE"


info "Iniciando $SERVER3..."

helmx upgrade \
    "$SERVER3" \
    "$CHART" \
    --version "$CHART_VERSION" \
    -n "$NAMESPACE" \
    -f "$REMOTE_BASE_VALUES" \
    -f "$REMOTE_COMMON" \
    -f "$REMOTE_CLUSTER_ONLINE"


# ============================================================
# 23. AGUARDAR FORMAÇÃO DO CLUSTER
# ============================================================

section "AGUARDANDO CLUSTER"


wait_rollout "$SERVER1"
wait_rollout "$SERVER2"
wait_rollout "$SERVER3"


# ============================================================
# 24. VALIDAR DISTRIBUIÇÃO DOS PODS
# ============================================================

section "VALIDANDO ANTI-AFFINITY"


NODE1="$(
    kube get pod "$POD1" \
        -n "$NAMESPACE" \
        -o jsonpath='{.spec.nodeName}'
)"


NODE2="$(
    kube get pod "$POD2" \
        -n "$NAMESPACE" \
        -o jsonpath='{.spec.nodeName}'
)"


NODE3="$(
    kube get pod "$POD3" \
        -n "$NAMESPACE" \
        -o jsonpath='{.spec.nodeName}'
)"


echo
echo "$POD1 -> $NODE1"
echo "$POD2 -> $NODE2"
echo "$POD3 -> $NODE3"
echo


if [[ "$NODE1" == "$NODE2" ]] ||
   [[ "$NODE1" == "$NODE3" ]] ||
   [[ "$NODE2" == "$NODE3" ]]
then
    die \
        "Dois membros Neo4j foram agendados no mesmo Kubernetes node."
fi


info "Os três membros estão em nodes distintos."


# ============================================================
# 25. VALIDAR CLUSTER NEO4J
# ============================================================

section "SHOW SERVERS"


cypher_system \
    "SHOW SERVERS;"


# ============================================================
# 26. TRANSFORMAR DATABASE NEO4J EM 3 PRIMARIES
# ============================================================

section "CONFIGURANDO TOPOLOGIA DO DATABASE $DATABASE"


cypher_system \
    "ALTER DATABASE ${DATABASE} SET TOPOLOGY 3 PRIMARIES 0 SECONDARIES WAIT 300 SECONDS;"


# ============================================================
# 27. DEFINIR TOPOLOGIA PADRÃO PARA NOVOS DATABASES
# ============================================================

section "CONFIGURANDO DEFAULT ALLOCATION"


#
# Neo4j 2026.06:
#
# dbms.setDefaultAllocationNumbers(
#     primaries,
#     secondaries,
#     propertyShardReplicas
# )
#
# Para este cluster:
#
#   primaries             = 3
#   secondaries           = 0
#   propertyShardReplicas = 1
#

cypher_system \
    "CALL dbms.setDefaultAllocationNumbers(3, 0, 1);"


# ============================================================
# 28. VALIDAR DATABASES
# ============================================================

section "SHOW DATABASES"


cypher_system \
    "SHOW DATABASES;"


# ============================================================
# 29. VALIDAR PVCS CEPH
# ============================================================

section "VALIDANDO STORAGE"


assert_pvc_storage_class "$SERVER1"
assert_pvc_storage_class "$SERVER2"
assert_pvc_storage_class "$SERVER3"


kube get pvc \
    -n "$NAMESPACE" \
    -o wide


# ============================================================
# 30. STATUS FINAL
# ============================================================

section "STATUS FINAL"


kube get pods \
    -n "$NAMESPACE" \
    -o wide


echo


kube get services \
    -n "$NAMESPACE"


echo


kube get storageclass \
    "$NEO4J_STORAGE_CLASS"


# ============================================================
# 31. LIMPAR DUMPS TEMPORÁRIOS DOS PODS
# ============================================================

section "LIMPANDO ARQUIVOS TEMPORÁRIOS"


for pod in \
    "$POD1" \
    "$POD2" \
    "$POD3"
do

    kube exec \
        -n "$NAMESPACE" \
        "$pod" \
        -- rm -f \
            "/backups/${DATABASE}.dump" \
            "/backups/system.dump" \
        2>/dev/null || true

done


vm rm -f \
    "$REMOTE_DUMP" \
    "$REMOTE_SYSTEM_DUMP"


# ============================================================
# 32. RESULTADO
# ============================================================

section "DEPLOY CONCLUÍDO COM SUCESSO"


echo
echo "Cluster Neo4j:"
echo
echo "  Nome lógico:    $CLUSTER_NAME"
echo
echo "  Server 1:       $SERVER1 -> $NODE1"
echo "  Server 2:       $SERVER2 -> $NODE2"
echo "  Server 3:       $SERVER3 -> $NODE3"
echo
echo "Storage:"
echo
echo "  Backend:        Ceph RBD"
echo "  StorageClass:   $NEO4J_STORAGE_CLASS"
echo "  ReclaimPolicy:  Retain"
echo "  PVC por membro: $DATA_SIZE"
echo
echo "Database:"
echo
echo "  Nome:           $DATABASE"
echo "  Topologia:      3 primaries / 0 secondaries"
echo
echo "Bootstrap backup:"
echo
echo "  $LOCAL_SYSTEM_DUMP"
echo
echo "============================================================"