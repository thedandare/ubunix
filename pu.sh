#!/bin/sh

# 1. Configurações Iniciais
export GIT_SSH_COMMAND="ssh -i ~/.ssh/tdd_id_ed25519"
OPENAI_API_KEY=$(cat leonix/secret/openai_key 2>/dev/null || cat thumbnix/secret/openai_key 2>/dev/null)

# Garante que o remote origin está correto
git remote set-url origin git@github.com:thedandare/ubunit.gix 2>/dev/null || git remote add origin git@github.com:thedandare/ubunit.gix

# 2. Adiciona os arquivos na fila
if [ -n "$1" ]; then
    git add "$1"
else
    printf "\033[0;31mNenhum arquivo passado. Adicionando todas as modificações atuais...\033[0m\n"
    git add .
fi

# 3. Verifica se realmente há algo para commitar
if git diff --cached --quiet; then
    echo "ℹ️  Nenhuma alteração detectada para commitar."
    exit 0
fi
# 4. Captura as alterações atuais e prepara o prompt para a LLM
echo "🤖 Solicitando mensagem de commit para a IA..."

# Limpa o diff deixando-o em uma única linha segura para o JSON sem quebrar a estrutura
GIT_CHANGES=$(git diff --cached | head -c 4000 | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/' | tr -d '\n' | tr -d '\r')

# Monta o JSON com o DIFF PURO (sem Base64 para a IA não se confundir)
JSON_PAYLOAD=$(cat <<EOF
{
  "model": "gpt-4o-mini",
  "input": "Escreva uma mensagem de commit curta, concisa, no imperativo e em português para este diff do Git. Não use markdown, saudações ou jargões de permissão de arquivo (como 100644). Apenas a mensagem direta. Diff:\\n\\n$GIT_CHANGES",
  "store": false
}
EOF
)

echo $JSON_PAYLOAD
# Faz a requisição HTTP usando curl para o seu endpoint /v1/responses
API_RESPONSE=$(curl -s https://api.openai.com/v1/responses\
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d "$JSON_PAYLOAD")

# 1. Extrai o texto cru do JSON com os escapes Unicode nativos (\uXXXX)
RAW_MSG=$(echo "$API_RESPONSE" | tr -d '\n' | tr -d '\r' | awk -F'"text": *"' '{print $2}' | awk -F'"' '{print $1}')

# 2. Converte os caracteres Unicode (\uXXXX) para acentos reais usando o printf nativo
IA_COMMIT_MSG=$(printf '%b' "$(echo "$RAW_MSG" | sed 's/\\u\([0-9a-fA-F]\{4\}\)/\\u\1/g; s/\\n/\n/g; s/\\"/"/g')")

# Se a API falhar por qualquer motivo, usa um fallback seguro compatível com NixOS
if [ -z "$IA_COMMIT_MSG" ] || [ "$IA_COMMIT_MSG" = "null" ]; then
    echo "⚠️  Falha ao obter resposta da LLM. Usando mensagem padrão."
    NIX_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' || hostname -i | awk '{print $1}')
    IA_COMMIT_MSG="auto-commit IP: $NIX_IP em $(date)"
fi

echo "📝 Mensagem gerada: \"$IA_COMMIT_MSG\""

# 5. Executa o Commit e faz o Push
git commit -m "$IA_COMMIT_MSG"
git push -u origin main
