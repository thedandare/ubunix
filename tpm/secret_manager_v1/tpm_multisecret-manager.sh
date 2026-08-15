#!/usr/bin/env bash

# Interrompe o script se houver erros
set -e

INDEX="0x1500000"
TCTI_DEV="device:/dev/tpmrm0"
READ_SCRIPT="./tpm_ler.sh"
TEMP_BLOCK=$(mktemp)
TEMP_NEW_BLOCK=$(mktemp)

# Limpeza automática ao sair
trap 'rm -f "$TEMP_BLOCK" "$TEMP_NEW_BLOCK"; clear' EXIT

clear
gum style --foreground 212 --border double --align center --width 50 "Banco de Dados fTPM NVRAM (2048 Bytes)"

echo ""

# 1. Captura o Nome/Identificador do Segredo
KEY_NAME=$(gum input --placeholder "Nome do segredo (Ex: github_token, wifi_casa)...")
if [ -z "$KEY_NAME" ]; then
    echo "Operação cancelada."
    exit 0
fi

# Remove espaços ou caracteres estranhos do nome da chave para não quebrar a lista
KEY_NAME=$(echo "$KEY_NAME" | tr -d '[:space:]=')

# 2. Captura o Valor/Conteúdo do Segredo em Texto Claro
SECRET_VAL=$(gum input --placeholder "Digite o valor/senha para guardar...")
if [ -z "$SECRET_VAL" ]; then
    echo "Operação cancelada."
    exit 0
fi

echo ""
echo "-> Acessando o fTPM para puxar a lista atual..."

# 3. Lê o bloco inteiro de 2048 bytes do chip e limpa os bytes nulos (\x00)
# Se o índice estiver vazio, o tr limpa e gera um arquivo texto vazio válido
sudo tpm2_nvread -T "$TCTI_DEV" -s 2048 "$INDEX" 2>/dev/null | tr -d '\000' > "$TEMP_BLOCK" || true

# 4. Remove a chave se ela já existia antes na lista antiga (evita duplicatas)
grep -v "^${KEY_NAME}=" "$TEMP_BLOCK" > "$TEMP_NEW_BLOCK" || true

# 5. Adiciona o novo par de segredo na lista
echo "${KEY_NAME}=${SECRET_VAL}" >> "$TEMP_NEW_BLOCK"

# 6. Valida se a lista inteira cabe no limite físico de 2048 bytes
TOTAL_BYTES=$(wc -c < "$TEMP_NEW_BLOCK")
if [ "$TOTAL_BYTES" -gt 2048 ]; then
    gum style --foreground 196 "Erro: A lista de segredos excedeu o limite físico de 2048 bytes ($TOTAL_BYTES bytes)."
    exit 1
fi

# 7. Grava o bloco consolidado atualizado no fTPM
echo "-> Gravando lista atualizada ($TOTAL_BYTES bytes) no silício..."
sudo tpm2_nvwrite -T "$TCTI_DEV" -i "$TEMP_NEW_BLOCK" "$INDEX"

# 8. Gera o script dinâmico de leitura
# Ele agora lê os 2048 bytes e faz um grep inteligente para achar o segredo quando você rodar
cat << 'EOF' > "$READ_SCRIPT"
#!/usr/bin/env bash
INDEX="0x1500000"
TCTI_DEV="device:/dev/tpmrm0"

if [ -z "$1" ]; then
    echo "Uso: $0 <nome_do_segredo>"
    echo "Segredos atualmente guardados no fTPM:"
    sudo tpm2_nvread -T "$TCTI_DEV" -s 2048 "$INDEX" 2>/dev/null | tr -d '\000' | cut -d= -f1 | sed 's/^/ - /'
    exit 0
fi

VALOR=$(sudo tpm2_nvread -T "$TCTI_DEV" -s 2048 "$INDEX" 2>/dev/null | tr -d '\000' | grep "^$1=" | cut -d= -f2-)

if [ -z "$VALOR" ]; then
    echo "Erro: Segredo '$1' não encontrado no hardware."
    exit 1
fi

echo "Chave: $1"
echo "Valor: $VALOR"
EOF
chmod +x "$READ_SCRIPT"

echo ""
# Exibe o sucesso formatado no gum moderno
gum style --foreground 46 --border rounded --padding "1 2" \
    "Sucesso! Segredo '$KEY_NAME' indexado." \
    "Espaço total ocupado na NVRAM: $TOTAL_BYTES / 2048 bytes." \
    "Script de consulta atualizado: $READ_SCRIPT"

echo ""
