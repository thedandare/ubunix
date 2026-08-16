#!/bin/sh
set -eu

VM="leonk9s"
NAMESPACE="neo4j"
MANIFEST="mcp-deployment.yaml"
REMOTE_MANIFEST="/root/$MANIFEST"

echo
echo "=========================================="
echo " CONFIGURAÇÃO MCP SERVER"
echo "=========================================="
echo "VM:        $VM"
echo "Namespace: $NAMESPACE"
echo "Manifest:  $MANIFEST"
echo

if [ ! -f "$MANIFEST" ]; then
  echo "ERRO: arquivo $MANIFEST não encontrado."
  exit 1
fi

echo
echo "=========================================="
echo " COPIANDO MANIFESTO PARA $VM"
echo "=========================================="
incus file push "$MANIFEST" "$VM$REMOTE_MANIFEST"

echo
echo "=========================================="
echo " APLICANDO MANIFESTO"
echo "=========================================="
incus exec "$VM" -- microk8s kubectl apply -f "$REMOTE_MANIFEST" -n "$NAMESPACE"

echo
echo "=========================================="
echo " AGUARDANDO POD FICAR PRONTO"
echo "=========================================="
incus exec "$VM" -- microk8s kubectl rollout status deployment/neo4j-mcp -n "$NAMESPACE" --watch --timeout=300s

echo
echo "=========================================="
echo " MCP SERVER DEPLOYADO COM SUCESSO"
echo "=========================================="
NODEPORT=$(incus exec "$VM" -- microk8s kubectl get svc neo4j-mcp -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}')
echo "O servidor MCP está rodando em modo HTTP (SSE) na porta NodePort $NODEPORT."
echo "Para conectar via client MCP (Claude, Cursor, etc), use o endpoint SSE:"
echo "http://<IP-DA-VM>:$NODEPORT/sse"
echo
echo "Nota: Em modo HTTP, o neo4j-mcp exige que as credenciais do Neo4j sejam passadas"
echo "pelo client via header Authorization (Basic Auth)."
