#!/bin/bash

set -u

IP_MAQUINA=$(ip route get 1.1.1.1 | awk '{print $7}')
ULTIMO_OCTETO=$(echo "$IP_MAQUINA" | cut -d. -f4)

case "$ULTIMO_OCTETO" in
    17) CONTAINER_IPS=(10.42.0.18 10.42.0.19 10.42.0.20) ;;
    33) CONTAINER_IPS=(10.42.0.34 10.42.0.35 10.42.0.36) ;;
    49) CONTAINER_IPS=(10.42.0.50 10.42.0.51 10.42.0.52) ;;
    *)
        echo "[FALHA] IP privado do host inesperado: $IP_MAQUINA"
        exit 1
        ;;
esac

echo "========================================================="
echo " Verificando workers Incus na rede GCE"
echo " Host: $IP_MAQUINA"
echo "========================================================="

if ! sudo incus profile show default | grep -q 'nictype: routed'; then
    echo "[FALHA] O perfil default não está usando nictype: routed."
    exit 1
fi

sudo incus list
echo

for ip in "${CONTAINER_IPS[@]}"; do
    if ping -c 2 -W 2 "$ip" >/dev/null 2>&1; then
        echo "[ OK ] $ip está respondendo."
    else
        echo "[FALHA] $ip não respondeu."
    fi
done

echo
echo "[INFO] Endereços routed ativos na ens4:"
ip addr show dev ens4 | grep -E "inet "
