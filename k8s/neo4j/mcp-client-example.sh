#!/bin/sh
set -eu

echo "=========================================================="
echo " EXEMPLO: COMO CONECTAR AO NEO4J MCP SERVER (SSE)"
echo "=========================================================="
echo
echo "O MCP Server está rodando em modo HTTP, o que significa que"
echo "ele não usa as credenciais embutidas na sua VM para se autenticar"
echo "com o banco. Em vez disso, o *seu client* (Claude, Cursor, etc)"
echo "deve enviar as credenciais a cada requisição HTTP usando"
echo "o cabeçalho (header) de 'Authorization: Basic'."
echo

# 1. Obter o IP da VM
VM_IP=$(incus list leonk7s -c 4 --format csv | awk '{print $1}')
NODEPORT=31488
ENDPOINT="http://${VM_IP}:${NODEPORT}/sse"

# 2. Configurar Credenciais
USER="neo4j"
PASS="F1bo6600"

# O 'Basic Auth' exige que as credenciais fiquem no formato "usuario:senha" codificadas em Base64
CREDENTIALS_B64=$(echo -n "${USER}:${PASS}" | base64)

echo "-> IP da VM: $VM_IP"
echo "-> Porta do NodePort: $NODEPORT"
echo "-> Endpoint do MCP: $ENDPOINT"
echo "-> Credenciais Base64: $CREDENTIALS_B64"
echo
echo "----------------------------------------------------------"
echo " CONFIGURAÇÃO PARA CLAUDE DESKTOP / CURSOR"
echo "----------------------------------------------------------"
echo "Na configuração do seu editor/IDE (ex: mcp.json), você deve"
echo "especificar a URL e os cabeçalhos customizados, caso suportado:"
echo
cat <<EOF
{
  "mcpServers": {
    "neo4j": {
      "command": "sse",
      "url": "$ENDPOINT",
      "headers": {
        "Authorization": "Basic $CREDENTIALS_B64"
      }
    }
  }
}
EOF
echo
echo "----------------------------------------------------------"
echo " TESTANDO CONEXÃO NA PRÁTICA (CURL)"
echo "----------------------------------------------------------"
echo "Pressione ENTER para testar a conexão SSE com o curl (Ctrl+C para sair)."
read -r dummy

echo "Executando:"
echo "curl -N -H \"Authorization: Basic $CREDENTIALS_B64\" -H \"Accept: text/event-stream\" $ENDPOINT"
echo
curl -N -H "Authorization: Basic $CREDENTIALS_B64" -H "Accept: text/event-stream" "$ENDPOINT"
