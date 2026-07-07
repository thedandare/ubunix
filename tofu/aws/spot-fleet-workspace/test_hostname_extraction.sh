#!/bin/bash

# Script para testar extração de índice baseado no hostname/IP

echo "=== Teste de Extração de Índice ==="
echo "Hostname atual: $(hostname)"
echo

# Simula diferentes hostnames AWS
test_hostnames=("ip-10-0-1-10" "ip-10-0-1-11" "ip-10-0-1-12" "ip-10-0-1-15" "outro-hostname")

for test_hostname in "${test_hostnames[@]}"; do
    echo "Testando hostname: $test_hostname"
    
    # Tenta extrair do hostname
    if echo "$test_hostname" | grep -q "ip-10-0-1-"; then
        LAST_OCTET=$(echo "$test_hostname" | sed 's/ip-10-0-1-//')
        echo "  Último octeto extraído: $LAST_OCTET"
    else
        echo "  Hostname não corresponde ao padrão AWS"
        # Simula fallback
        LAST_OCTET="15"
    fi
    
    # Mapeia para índice
    case $LAST_OCTET in
        10) INDEX=1 ;;
        11) INDEX=2 ;;
        12) INDEX=3 ;;
        *) 
            # Usa hash do hostname
            INDEX=$(( $(echo "$test_hostname" | md5sum | cut -c1-1) % 3 + 1 ))
            echo "  Usando hash do hostname: $INDEX"
            ;;
    esac
    
    echo "  Índice determinado: $INDEX"
    echo "  Nome do container: amnix-test-uuid-$INDEX"
    echo
done

# Testa com hostname real se disponível
echo "=== Teste com hostname real ==="
REAL_HOSTNAME=$(hostname)
echo "Hostname real: $REAL_HOSTNAME"

if echo "$REAL_HOSTNAME" | grep -q "ip-10-0-1-"; then
    LAST_OCTET=$(echo "$REAL_HOSTNAME" | sed 's/ip-10-0-1-//')
    echo "Último octeto real: $LAST_OCTET"
else
    echo "Hostname real não corresponde ao padrão AWS"
    # Tenta obter IP real
    REAL_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}' 2>/dev/null || echo "fallback")
    echo "IP real: $REAL_IP"
    LAST_OCTET=$(echo $REAL_IP | cut -d. -f4)
    echo "Último octeto do IP: $LAST_OCTET"
fi

case $LAST_OCTET in
    10) INDEX=1 ;;
    11) INDEX=2 ;;
    12) INDEX=3 ;;
    *) 
        INDEX=$(( $(echo "$REAL_HOSTNAME" | md5sum | cut -c1-1) % 3 + 1 ))
        echo "Usando hash do hostname real: $INDEX"
        ;;
esac

echo "Índice real: $INDEX"
echo "Nome do container real: amnix-real-uuid-$INDEX"
