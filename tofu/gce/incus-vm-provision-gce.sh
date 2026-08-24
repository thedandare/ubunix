#!/usr/bin/env bash
set -euo pipefail

for i in 7 8 9; do
  NAME="santi${i}"

  if ! ${pkgs.incus}/bin/incus info "$NAME" >/dev/null 2>&1; then
    echo "Container $NAME não encontrado. Criando..."

    IP_MAQUINA=$(${pkgs.iproute2}/bin/ip route get 1.1.1.1 | ${pkgs.coreutils}/bin/head -n1 | ${pkgs.gawk}/bin/awk '{print $7}')
    IP_PREFIX=$(echo "$IP_MAQUINA" | ${pkgs.gnused}/bin/sed 's/\.[0-9]\+$//')
    ULTIMO_OCTETO=$(echo "$IP_MAQUINA" | ${pkgs.gawk}/bin/awk -F. '{print $4}')
    IP_ADDRESS="${IP_PREFIX}.$((ULTIMO_OCTETO + i - 1))"

    ${pkgs.incus}/bin/incus init \
      images:ubuntu/26.04/cloud \
      "$NAME" \
      -s default \
      -p default \
      -p microk8s

    ${pkgs.incus}/bin/incus config set "$NAME" user.network-config - <<NETEOF
version: 2
ethernets:
  eth0:
    addresses:
      - ${IP_ADDRESS}/32
    routes:
      - to: default
        via: 169.254.0.1
        on-link: true
NETEOF

    ${pkgs.incus}/bin/incus config device override "$NAME" eth0 ipv4.address="$IP_ADDRESS"
    ${pkgs.incus}/bin/incus start "$NAME"
  else
    echo "Container $NAME já existe."
  fi
done
