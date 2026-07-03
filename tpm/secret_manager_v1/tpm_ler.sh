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
