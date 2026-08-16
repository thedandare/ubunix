#!/bin/bash

# 1. Captura o IP ativo e extrai o último octeto (ex: 2, 3 ou 4)
IP_MAQUINA=$(ip route get 1.1.1.1 | awk '{print $7}')
ULTIMO_OCTETO=$(echo "$IP_MAQUINA" | cut -d. -f4)

echo "========================================================="
echo " Verificando Rede Nativa GCP/28 a partir do Host: 10.42.0.$ULTIMO_OCTETO"
echo "========================================================="

# Função auxiliar para testar o ping e exibir o resultado com cores
testar_ping() {
    local alvo=$1
    local descricao=$2
    # Executa o ping: 2 pacotes, espera no máximo 2 segundos por resposta
    if ping -c 2 -W 2 "$alvo" > /dev/null 2>&1; then
        echo -e "[\e[32m OK \e[0m] $descricao ($alvo) está respondendo."
    else
        echo -e "[\e[31mFALHA\e[0m] $descricao ($alvo) NÃO respondeu!"
    fi
}

# --- TESTES PARA O HOST .2 (santiago0) - Bloco /28 (.16 a .31) ---
if [ "$ULTIMO_OCTETO" -eq 2 ]; then
    echo -e "[\e[34mINFO\e[0m] Verificando containers locais do santiago0 (Bloco .16/28):"
    testar_ping "10.42.0.17" "Container local 1"
    testar_ping "10.42.0.18" "Container local 2"
    testar_ping "10.42.0.19" "Container local 3"
else
    echo "--- Testando conexões em direção ao Host .2 (santiago0) ---"
    testar_ping "10.42.0.2" "Host Físico santiago0"
    testar_ping "10.42.0.17" "Container Remoto santiago0-1"
fi
echo ""

# --- TESTES PARA O HOST .3 (santiago1) - Bloco /28 (.32 a .47) ---
if [ "$ULTIMO_OCTETO" -eq 3 ]; then
    echo -e "[\e[34mINFO\e[0m] Verificando containers locais do santiago1 (Bloco .32/28):"
    testar_ping "10.42.0.33" "Container local 1"
    testar_ping "10.42.0.34" "Container local 2"
    testar_ping "10.42.0.35" "Container local 3"
else
    echo "--- Testando conexões em direção ao Host .3 (santiago1) ---"
    testar_ping "10.42.0.3" "Host Físico santiago1"
    testar_ping "10.42.0.33" "Container Remoto santiago1-1"
fi
echo ""

# --- TESTES PARA O HOST .4 (santiago2) - Bloco /28 (.48 a .63) ---
if [ "$ULTIMO_OCTETO" -eq 4 ]; then
    echo -e "[\e[34mINFO\e[0m] Verificando containers locais do santiago2 (Bloco .48/28):"
    testar_ping "10.42.0.49" "Container local 1"
    testar_ping "10.42.0.50" "Container local 2"
    testar_ping "10.42.0.51" "Container local 3"
else
    echo "--- Testando conexões em direção ao Host .4 (santiago2) ---"
    testar_ping "10.42.0.4" "Host Físico santiago2"
    testar_ping "10.42.0.49" "Container Remoto santiago2-1"
fi
echo "========================================================="

# Exibe os blocos Alias IP locais ativados na placa de rede para auditoria rápida
echo -e "\n[\e[34mINFO\e[0m] Endereços e sub-redes Alias ativos na ens4 do host físico atual:"
ip addr show dev ens4 | grep -E "inet " --color=always
