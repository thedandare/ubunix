#!/usr/bin/env bash
set -euo pipefail

MARKER=/var/lib/gce-first-boot-done
[ -f "$MARKER" ] && { echo "First boot marker already present. Skipping."; exit 0; }

PATH=/run/current-system/sw/bin:$PATH
export PATH

mkdir -p /var/lib

IP_MAQUINA=$(ip route get 1.1.1.1 | head -n1 | awk '{print $7}')
IP_PREFIX=$(echo "$IP_MAQUINA" | sed 's/\\.[0-9]\+$//')
ULTIMO_OCTETO=$(echo "$IP_MAQUINA" | awk -F. '{print $4}')

sysctl -w net.ipv4.ip_forward=1 >/dev/null || true

# Aguarda o incusd ficar pronto
for _ in {1..30}; do
  if incus list >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

cat > /tmp/microk8s-cloud-init.yaml <<'CIEOF'
#cloud-config
package_update: true
package_upgrade: true

users:
  - name: root
    ssh_authorized_keys:
      - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICs+sOj/1GK5exkDkCw7H7zmDapshfWaRn474qxZxSUY leo"
      - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMGWvbEP/E0dh/xwtUVIuQrNDSz+G4TCLA+UMVpT0gLi root@ali"
      - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlCOf70p6jujZf6ZdE7ugOQAPtpqteigxxaQb4RONs4 thedandare@gmail.com"
      - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO4x8pXKybfzCbc6IAd+HoPMW4vy3vT6ByGHM3uz4ApN leo@ali"

runcmd:
  - apt-get update
  - apt-get install -y snapd
  - systemctl unmask snapd.service snapd.socket || true
  - systemctl enable snapd.service snapd.socket || true
  - systemctl start snapd.service snapd.socket || true
  - apt-get install -y util-linux jq curl iptables net-tools
  - update-alternatives --set iptables /usr/sbin/iptables-nft || true
  - update-alternatives --set ip6tables /usr/sbin/ip6tables-nft || true
  - update-alternatives --set arptables /usr/sbin/arptables-nft || true
  - update-alternatives --set ebtables /usr/sbin/ebtables-nft || true
  - snap install microk8s --channel=1.36/stable --classic
  - snap refresh --hold microk8s
  - sed -i 's/snapshotter = "${SNAPSHOTTER}"/snapshotter = "overlayfs"/g' /var/snap/microk8s/current/args/containerd-template.toml
  - grep -qxF -- '--protect-kernel-defaults=false' /var/snap/microk8s/current/args/kubelet || echo '--protect-kernel-defaults=false' >> /var/snap/microk8s/current/args/kubelet
  - grep -qxF -- '--enforce-node-allocatable=""' /var/snap/microk8s/current/args/kubelet || echo '--enforce-node-allocatable=""' >> /var/snap/microk8s/current/args/kubelet
  - mkdir -p /var/snap/microk8s/current/args/cni-network
  - grep -qxF -- '--cni-conf-dir=/var/snap/microk8s/current/args/cni-network' /var/snap/microk8s/current/args/kubelet || echo '--cni-conf-dir=/var/snap/microk8s/current/args/cni-network' >> /var/snap/microk8s/current/args/kubelet
  - sed -i '/^--proxy-mode=/d' /var/snap/microk8s/current/args/kube-proxy
  - echo '--proxy-mode=nftables' >> /var/snap/microk8s/current/args/kube-proxy
  - prlimit --pid=$$ --nofile=1048576:1048576 || true
  - mkdir -p /etc/systemd/system/snap.microk8s.daemon-kubelite.service.d
  - |
    cat <<EOF > /etc/systemd/system/snap.microk8s.daemon-kubelite.service.d/override.conf
    [Service]
    LimitNOFILE=1048576
    LimitNPROC=512000
    EOF
  - systemctl daemon-reload
  - rm -f /var/snap/microk8s/current/var/kubernetes/backend/kine.sock
  - chmod -R 777 /var/snap/microk8s/current/var/kubernetes/backend/
  - sysctl --system
  - snap set system refresh.hold=forever
  - snap restart microk8s
  - microk8s status --wait-ready
CIEOF

incus admin init --preseed <<EOF
config: {}
networks: []
storage_pools:
- config:
    size: 15GiB
  description: "Storage em arquivo loop btrfs"
  name: default
  driver: btrfs
profiles:
- name: default
  description: "Perfil padrao com routed NIC"
  devices:
    eth0:
      name: eth0
      nictype: routed
      parent: ens4
      type: nic
    root:
      path: /
      pool: default
      type: disk
- name: microk8s
  description: "Perfil customizado para MicroK8s com Cloud-Init integrado"
  config:
    security.nesting: "true"
    security.privileged: "true"
    boot.autostart: "true"
    cloud-init.user-data: |
$(sed 's/^/      /' /tmp/microk8s-cloud-init.yaml)
  devices: {}
EOF

for i in 7 8 9; do
  NAME="santi${i}"
  IP_FINAL="${IP_PREFIX}.$((ULTIMO_OCTETO + i - 1))"

  if ! incus info "$NAME" >/dev/null 2>&1; then
    echo "Criando container $NAME com IP $IP_FINAL ..."

    incus init \
      images:ubuntu/26.04/cloud \
      "$NAME" \
      -s default \
      -p default \
      -p microk8s

    incus config set "$NAME" cloud-init.network-config - <<NETEOF
version: 2
ethernets:
  eth0:
    addresses:
      - ${IP_FINAL}/32
    routes:
      - to: default
        via: 169.254.0.1
        on-link: true
NETEOF

    incus config device override "$NAME" eth0 ipv4.address="$IP_FINAL"

    incus start "$NAME"
  else
    echo "Container $NAME ja existe."
  fi
done

touch "$MARKER"
