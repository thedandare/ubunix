#!/usr/bin/env bash

# Interrompe o script se qualquer comando falhar
set -e

# Configurações do TPM e do ambiente
INDEX="0x1500000"
TCTI_DEV="device:/dev/tpmrm0"
READ_SCRIPT="./tpm_ler.sh"

clear

# Título corrigido para não quebrar no gum moderno
gum style --foreground 212 --border double --align center --width 50 "Gerenciador fTPM NVRAM (NixOS Unstable)"

echo ""

# 1. Captura a string em texto claro direto na tela (deixou de ser passwordbox)
USER_STRING=$(gum input --placeholder "Digite a senha/texto em texto claro...")

# Se o usuário deixar vazio, encerra
if [ -z "$USER_STRING" ]; then
    echo "Operação cancelada. Nenhum dado foi alterado."
    exit 0
fi

# 2. Calcula o tamanho exato em bytes
BYTE_SIZE=$(echo -n "$USER_STRING" | wc -c)

echo ""
echo "-> Gravando no fTPM..."

# 3. Grava no fTPM usando a sintaxe validada oficial (-i -)
echo -n "$USER_STRING" | sudo tpm2_nvwrite -T "$TCTI_DEV" -i - "$INDEX"

# 4. Cria o script dinâmico de leitura
cat << EOF > "$READ_SCRIPT"
#!/usr/bin/env bash
echo -n "Dado lido do fTPM: "
sudo tpm2_nvread -T "$TCTI_DEV" -s $BYTE_SIZE $INDEX
echo ""
EOF
chmod +x "$READ_SCRIPT"

# 5. Faz o teste de leitura em tempo real e exibe direto na tela
TEST_READ=$(sudo tpm2_nvread -T "$TCTI_DEV" -s "$BYTE_SIZE" "$INDEX")

echo ""
gum style --foreground 46 --border rounded --padding "1 2" \
    "Sucesso! Alocado: $BYTE_SIZE bytes. Script: $READ_SCRIPT. Retorno: $TEST_READ"
echo ""
