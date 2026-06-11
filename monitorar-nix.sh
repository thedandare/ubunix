#!/bin/sh
CONTAINER="teste-nix"
LOG_FILE="/var/log/nix-install.log"

echo -e "\e[1;34m[==>] Iniciando monitoring do Nix no container Ubuntu: $CONTAINER\e[0m"

echo -n "Aguardando o container iniciar..."
until lxc info "$CONTAINER" 2>/dev/null | grep -q "Status: RUNNING"; do
    sleep 1
    echo -n "."
done
echo -e " \e[1;32m[OK]\e[0m"

echo -n "Aguardando o instalador do Nix iniciar..."
until lxc exec "$CONTAINER" -- test -f "$LOG_FILE" 2>/dev/null; do
    sleep 1
    echo -n "."
done
echo -e " \e[1;32m[Criado]\e[0m"

echo -e "\e[1;33m[==>] Lendo o progresso do Nix (Pressione CTRL+C para sair):\e[0m"
echo "----------------------------------------------------------------------"
lxc exec "$CONTAINER" -- tail -f "$LOG_FILE"
