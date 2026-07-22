#!/bin/sh
set -eu

VM="leonk9s"
NAMESPACE="neo4j"
RELEASE="my-neo4j-release"
VALUES="values.yaml"

DUMP="neo4j.dump"
DATABASE="neo4j"

REMOTE_VALUES="/root/values.yaml"
REMOTE_DUMP="/root/$DUMP"

POD="${RELEASE}-0"

echo
echo "=========================================="
echo " CONFIGURAÇÃO"
echo "=========================================="
echo "VM:        $VM"
echo "Namespace: $NAMESPACE"
echo "Release:   $RELEASE"
echo "Pod:       $POD"
echo "Dump:      $DUMP"
echo

#
# 1. VALIDAR ARQUIVOS LOCAIS
#

if [ ! -f "$VALUES" ]; then
  echo "ERRO: arquivo $VALUES não encontrado."
  exit 1
fi

if [ ! -f "$DUMP" ]; then
  echo "ERRO: arquivo $DUMP não encontrado."
  exit 1
fi


#
# 2. CONFIGURAR REPOSITÓRIO HELM
#

echo
echo "=========================================="
echo " CONFIGURANDO REPOSITÓRIO HELM"
echo "=========================================="

incus exec "$VM" -- \
  microk8s helm repo add neo4j https://helm.neo4j.com/neo4j \
  >/dev/null 2>&1 || true

incus exec "$VM" -- \
  microk8s helm repo update


#
# 3. REMOVER RELEASE ANTERIOR
#

echo
echo "=========================================="
echo " REMOVENDO RELEASE ANTERIOR"
echo "=========================================="

if incus exec "$VM" -- \
  microk8s helm status "$RELEASE" \
  -n "$NAMESPACE" \
  >/dev/null 2>&1
then

  echo "Release existente encontrado: $RELEASE"

  incus exec "$VM" -- \
    microk8s helm uninstall "$RELEASE" \
    -n "$NAMESPACE"

else
  echo "Release $RELEASE não existe. Continuando."
fi


#
# 4. AGUARDAR POD ANTIGO SUMIR
#

echo
echo "=== Aguardando remoção do Pod antigo ==="

i=0

while incus exec "$VM" -- \
  microk8s kubectl get pod "$POD" \
  -n "$NAMESPACE" \
  >/dev/null 2>&1
do

  i=$((i + 1))

  if [ "$i" -gt 60 ]; then
    echo "ERRO: timeout aguardando remoção do Pod $POD"
    exit 1
  fi

  echo "Pod antigo ainda existe..."
  sleep 2
done


#
# 5. REMOVER PVC ANTIGO
#
# ATENÇÃO:
# Isto APAGA os dados persistentes existentes.
# Como este script restaura o banco a partir do dump,
# queremos começar com um volume novo.
#

echo
echo "=========================================="
echo " REMOVENDO PVC ANTIGO"
echo "=========================================="

incus exec "$VM" -- \
  microk8s kubectl delete pvc \
  -n "$NAMESPACE" \
  -l "app.kubernetes.io/instance=$RELEASE" \
  --ignore-not-found


#
# 6. CRIAR NAMESPACE
#

echo
echo "=========================================="
echo " CRIANDO NAMESPACE"
echo "=========================================="

incus exec "$VM" -- \
  microk8s kubectl create namespace "$NAMESPACE" \
  >/dev/null 2>&1 || true


#
# 7. COPIAR VALUES E DUMP PARA A VM
#

echo
echo "=========================================="
echo " COPIANDO ARQUIVOS PARA $VM"
echo "=========================================="

incus file push \
  "$VALUES" \
  "$VM$REMOTE_VALUES"

incus file push \
  "$DUMP" \
  "$VM$REMOTE_DUMP"


#
# 8. INSTALAR NEO4J EM MODO OFFLINE
#
# Forçamos offlineMaintenanceModeEnabled=true aqui,
# independentemente do valor salvo no values.yaml.
#

echo
echo "=========================================="
echo " INSTALANDO NEO4J EM MODO OFFLINE"
echo "=========================================="

incus exec "$VM" -- \
  microk8s helm install "$RELEASE" neo4j/neo4j \
  -n "$NAMESPACE" \
  -f "$REMOTE_VALUES" \
  --set neo4j.offlineMaintenanceModeEnabled=true


#
# 9. AGUARDAR POD EXISTIR
#

echo
echo "=========================================="
echo " AGUARDANDO POD $POD"
echo "=========================================="

i=0

while ! incus exec "$VM" -- \
  microk8s kubectl get pod "$POD" \
  -n "$NAMESPACE" \
  >/dev/null 2>&1
do

  i=$((i + 1))

  if [ "$i" -gt 120 ]; then
    echo "ERRO: timeout aguardando criação do Pod."
    exit 1
  fi

  echo "Aguardando criação do Pod..."
  sleep 2
done


#
# 10. AGUARDAR APENAS STATUS RUNNING
#
# NÃO esperamos READY.
#
# Em offlineMaintenanceModeEnabled=true o Neo4j NÃO inicia.
# Portanto a porta Bolt 7687 permanece fechada e o Pod
# propositalmente não fica Ready.
#

echo
echo "=========================================="
echo " AGUARDANDO POD FICAR RUNNING"
echo "=========================================="

i=0

while :
do

  STATUS=$(
    incus exec "$VM" -- \
      microk8s kubectl get pod "$POD" \
      -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' \
      2>/dev/null || true
  )

  echo "Status: ${STATUS:-desconhecido}"

  if [ "$STATUS" = "Running" ]; then
    break
  fi

  i=$((i + 1))

  if [ "$i" -gt 120 ]; then
    echo
    echo "ERRO: Pod não entrou em Running."
    echo
    incus exec "$VM" -- \
      microk8s kubectl describe pod "$POD" \
      -n "$NAMESPACE" || true

    exit 1
  fi

  sleep 2
done


#
# 11. GARANTIR QUE /backups EXISTE
#

echo
echo "=========================================="
echo " PREPARANDO /backups"
echo "=========================================="

incus exec "$VM" -- \
  microk8s kubectl exec \
  -n "$NAMESPACE" \
  "$POD" \
  -- mkdir -p /backups


#
# 12. COPIAR DUMP PARA O POD
#

echo
echo "=========================================="
echo " COPIANDO DUMP PARA O POD"
echo "=========================================="

incus exec "$VM" -- \
  microk8s kubectl cp \
  "$REMOTE_DUMP" \
  "$NAMESPACE/$POD:/backups/$DUMP"


#
# 13. CONFERIR DUMP
#

echo
echo "=========================================="
echo " CONFERINDO DUMP"
echo "=========================================="

incus exec "$VM" -- \
  microk8s kubectl exec \
  -n "$NAMESPACE" \
  "$POD" \
  -- ls -lh /backups


#
# 14. RESTAURAR DATABASE
#
# --expand-commands é necessário no container criado
# pelo Helm chart do Neo4j.
#

echo
echo "=========================================="
echo " RESTAURANDO DATABASE: $DATABASE"
echo "=========================================="

incus exec "$VM" -- \
  microk8s kubectl exec \
  -n "$NAMESPACE" \
  "$POD" \
  -- neo4j-admin database load \
  --expand-commands \
  "$DATABASE" \
  --from-path=/backups \
  --overwrite-destination=true


#
# 15. RESTORE CONCLUÍDO
#

echo
echo "=========================================="
echo " RESTORE CONCLUÍDO"
echo "=========================================="


#
# 16. VOLTAR NEO4J PARA MODO ONLINE
#
# Usamos --reuse-values para preservar os valores
# usados na instalação e alteramos apenas o modo offline.
#

echo
echo "=========================================="
echo " INICIANDO NEO4J"
echo "=========================================="

incus exec "$VM" -- \
  microk8s helm upgrade "$RELEASE" neo4j/neo4j \
  -n "$NAMESPACE" \
  --reuse-values \
  --set neo4j.offlineMaintenanceModeEnabled=false


#
# 17. AGORA SIM ESPERAR READY / ROLLOUT
#

echo
echo "=========================================="
echo " AGUARDANDO NEO4J FICAR PRONTO"
echo "=========================================="

incus exec "$VM" -- \
  microk8s kubectl rollout status \
  statefulset/"$RELEASE" \
  -n "$NAMESPACE" \
  --watch \
  --timeout=600s


#
# 18. MOSTRAR STATUS FINAL
#

echo
echo "=========================================="
echo " STATUS FINAL"
echo "=========================================="

incus exec "$VM" -- \
  microk8s kubectl get pods \
  -n "$NAMESPACE" \
  -o wide

echo
echo "=========================================="
echo " NEO4J RESTAURADO COM SUCESSO"
echo "=========================================="
