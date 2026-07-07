#!/usr/bin/env bash
set -euo pipefail

# Carrega credenciais OAuth injetadas pelo cloud-init compilado no host NixOS.
if [ -f /etc/tailscale_oauth.env ]; then
  # shellcheck disable=SC1091
  source /etc/tailscale_oauth.env
fi
if [ -f /etc/environment ]; then
  # shellcheck disable=SC1091
  source /etc/environment || true
fi

: "${TAILSCALE_CLIENT_ID:=}"
: "${TAILSCALE_CLIENT_SECRET:=}"

if [ -z "$TAILSCALE_CLIENT_ID" ] || [ -z "$TAILSCALE_CLIENT_SECRET" ]; then
  echo "ERRO: TAILSCALE_CLIENT_ID/TAILSCALE_CLIENT_SECRET vazios."
  exit 1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERRO: comando obrigatorio ausente: $1"
    exit 1
  }
}

need_cmd curl
need_cmd jq
need_cmd tailscale
need_cmd ip

echo "=== 1. Solicitando Access Token via OAuth ==="
API_RESPONSE="$(curl -fsS -X POST \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=$TAILSCALE_CLIENT_ID" \
  -d "client_secret=$TAILSCALE_CLIENT_SECRET" \
  "https://api.tailscale.com/api/v2/oauth/token")"

API_TOKEN="$(echo "$API_RESPONSE" | jq -r '.access_token // empty')"
if [ -z "$API_TOKEN" ]; then
  echo "ERRO: falha ao obter access token. Resposta:"
  echo "$API_RESPONSE"
  exit 1
fi

echo "=== 2. Gerando Auth Key descartavel ==="
KEY_RESPONSE="$(curl -fsS -X POST \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "capabilities": {
      "devices": {
        "create": {
          "reusable": false,
          "ephemeral": true,
          "preauthorized": true,
          "tags": ["tag:teste", "tag:canssh"]
        }
      }
    },
    "expirySeconds": 600
  }' \
  "https://api.tailscale.com/api/v2/tailnet/-/keys")"

REQ_KEY="$(echo "$KEY_RESPONSE" | jq -r '.key // empty')"
if [ -z "$REQ_KEY" ]; then
  echo "ERRO: falha ao obter auth key. Resposta:"
  echo "$KEY_RESPONSE"
  exit 1
fi

echo "Auth Key descartavel gerada: tskey-auth-..."

echo "=== 3. Autenticando na rede Tailscale ==="
tailscale up \
  --auth-key="$REQ_KEY" \
  --accept-dns=true \
  --ssh=true \
  --stateful-filtering=false

echo "=== 4. Extraindo IP da interface tailscale0 ==="
TAILSCALE_IP=""
for tries in $(seq 1 30); do
  TAILSCALE_IP="$(ip -4 addr show dev tailscale0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)"
  if [ -n "$TAILSCALE_IP" ]; then
    break
  fi
  echo "Aguardando tailscale0 ganhar IP... ($tries/30)"
  sleep 1
done

if [ -z "$TAILSCALE_IP" ]; then
  echo "ERRO: tailscale0 subiu, mas nao recebeu IP a tempo."
  exit 1
fi

echo "IP Tailscale: $TAILSCALE_IP"
echo "MICROK8S_IP=$TAILSCALE_IP" >/etc/microk8s-node-ip.env

# Opcional: se existir um seletor externo, deixa ele ajustar o IP/cluster join.
if [ -f ./tailscale_choose_ip.sh ]; then
  # shellcheck disable=SC1091
  source ./tailscale_choose_ip.sh || true
else
  echo "Aviso: tailscale_choose_ip.sh nao localizado. Prosseguindo."
fi

sleep 5
tailscale set --webclient=true || true

# Exposicoes opcionais. Falham em tailnets sem permissao de Funnel/Serve; nao devem derrubar o boot.
tailscale funnel --bg --http 80 5252 || true
tailscale serve --bg --tcp 2409 3389 || true
tailscale serve --bg --tcp 2410 5901 || true

echo "Tailscale configurado com sucesso."
