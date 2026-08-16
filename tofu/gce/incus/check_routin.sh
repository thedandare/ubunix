#!/bin/bash

set -u

echo "========================================================="
echo " Verificando a bridge Incus e os containers locais"
echo "========================================================="

if ! sudo incus network show incusbr0 >/dev/null 2>&1; then
    echo "[FALHA] A rede incusbr0 não existe."
    exit 1
fi

echo "[INFO] Configuração da bridge:"
sudo incus network show incusbr0
echo

echo "[INFO] Containers:"
sudo incus list
echo

while read -r container ip; do
    [ -n "$container" ] || continue
    echo "[INFO] Testando $container ($ip)"
    if sudo incus exec "$container" -- ping -c 2 -W 2 1.1.1.1 >/dev/null 2>&1; then
        echo "[ OK ] $container tem acesso externo."
    else
        echo "[FALHA] $container não tem acesso externo."
    fi
done < <(sudo incus list --format csv -c n,4 | awk -F, '$2 != "" {print $1, $2}')
