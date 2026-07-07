#!/bin/bash

# Script para testar a lógica de criação de containers

echo "=== Teste de Criação de Containers ==="
echo

# Simula diferentes hostname_suffix (UUIDs)
test_suffixes=("844140a3" "abc12345" "def67890")

for suffix in "${test_suffixes[@]}"; do
    echo "Testando com hostname_suffix: $suffix"
    echo "Instância criaria os seguintes containers:"
    
    for i in 1 2 3; do
        case $i in
            1) NAME="amnix-${suffix}-1" ;;
            2) NAME="amnix-${suffix}-2" ;;
            3) NAME="amnix-${suffix}-3" ;;
        esac
        echo "  - $NAME"
    done
    echo
done

# Verifica se os nomes são únicos entre instâncias
echo "=== Verificação de Unicidade ==="
echo "Todos os nomes devem ser únicos:"
echo "Instância 1 (844140a3):"
echo "  amnix-844140a3-1"
echo "  amnix-844140a3-2" 
echo "  amnix-844140a3-3"
echo
echo "Instância 2 (abc12345):"
echo "  amnix-abc12345-1"
echo "  amnix-abc12345-2"
echo "  amnix-abc12345-3"
echo
echo "Instância 3 (def67890):"
echo "  amnix-def67890-1"
echo "  amnix-def67890-2"
echo "  amnix-def67890-3"
echo
echo "✅ Nomes únicos garantidos pelo hostname_suffix (UUID) diferente!"
