#!/bin/bash

sudo mkdir -p /etc/apt/keyrings/
sudo curl -fsSL https://zabbly.com \
    -o /etc/apt/keyrings/zabbly.asc

# Add the stable repository (Ubuntu 22.04/24.04)
sudo sh -c 'cat > /etc/apt/sources.list.d/zabbly-incus-stable.sources << EOF
Enabled: yes
Types: deb
URIs: https://zabbly.com
Suites: $(. /etc/os-release && echo $VERSION_CODENAME)
Components: main
Architectures: amd64 arm64
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF'

# Update and install
sudo apt-get update

if ! command -v whiptail >/dev/null 2>&1; then
    sudo apt-get install -y whiptail
fi

if ! command -v incus >/dev/null 2>&1; then
    timeout 3 whiptail --title "Detectando Incus" --msgbox "Incus não está instaladoInstalando via apt" 7 70 >&2
    clear
    sudo apt-get install -y incus bash-completion | whiptail --progressbox "Executando apt-get" 20 70
else
    timeout 2 whiptail --title "Incus 👌" --msgbox " Versao: $(sudo incus --version) --  $(uname -a)" 7 70 >&2
    timeout 1 clear
fi

if ! command -v ifconfig >/dev/null 2>&1; then
    timeout 3 whiptail --title "FINALizado!" --msgbox "ifconfig não está instalado\n\nInstalando via net-tools" 7 70 >&2
    clear
    sudo apt-get install -y net-tools
fi

export TERM="${TERM:-xterm-256color}"

answer=$(timeout --foreground 3s \
  whiptail --title "Incus init" \
    --default-item p \
    --menu "Escolha" 12 60 3 \
    p "Usar preseed (default após 3 s)" \
    y "Executar incus init" \
    n "Não inicializar" \
    3>&1 1>&2 2>&3)

exitstatus=$?

if [ "$exitstatus" -eq 124 ]; then
    answer="p"
elif [ "$exitstatus" -ne 0 ]; then
    echo "Operação cancelada. Usando preseed por segurança."
    answer="p"
fi

case "${answer,,}" in
    y)
        sudo incus admin init
    ;;
    p)
        # Rede routed: os containers usam aliases IP da NIC GCE do host
        cat <<'EOF' | sudo incus admin init --preseed
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
    linux.kernel_modules: ip_tables,ip6_tables,nf_nat,overlay,br_netfilter
    raw.lxc: |
      lxc.apparmor.profile=unconfined
      lxc.cgroup.devices.allow=a
      lxc.cap.drop=
      lxc.mount.auto=proc:rw sys:rw cgroup:rw
    cloud-init.user-data: |
      #cloud-config
      package_update: true
      package_upgrade: true

      bootcmd:
        - [ sh, -c, "[ -e /dev/kmsg ] || ln -s /dev/console /dev/kmsg" ]

      write_files:
        - path: /etc/sysctl.d/99-kubernetes.conf
          permissions: '0644'
          content: |
            net.ipv4.ip_forward = 1
            fs.inotify.max_user_instances = 512
            fs.inotify.max_user_watches = 524288
            net.bridge.bridge-nf-call-iptables = 1
            net.bridge.bridge-nf-call-ip6tables = 1

        - path: /usr/local/sbin/microk8s-bind-iptables-nft
          permissions: '0755'
          owner: root:root
          content: |
            #!/usr/bin/env bash
            set -uo pipefail

            SOURCE=/snap/microk8s/current/sbin/iptables-nft
            TARGET=/snap/microk8s/current/sbin/iptables

            # Roda como ExecStartPre dos daemons; durante a instalacao do snap o
            # caminho ainda pode nao existir e falhar aqui aborta o microk8s.
            [ -x "$SOURCE" ] || exit 0
            [ -e "$TARGET" ] || exit 0

            if "$TARGET" --version 2>&1 | grep -q 'nf_tables' && \
               "$TARGET" -t nat -S >/dev/null 2>&1; then
              exit 0
            fi

            umount "$TARGET" >/dev/null 2>&1 || true
            mount --bind "$SOURCE" "$TARGET" || exit 0

        - path: /etc/systemd/system/snap.microk8s.daemon-containerd.service.d/20-iptables-nft.conf
          permissions: '0644'
          owner: root:root
          content: |
            [Service]
            ExecStartPre=/usr/local/sbin/microk8s-bind-iptables-nft

        - path: /etc/systemd/system/snap.microk8s.daemon-kubelite.service.d/20-iptables-nft.conf
          permissions: '0644'
          owner: root:root
          content: |
            [Service]
            ExecStartPre=/usr/local/sbin/microk8s-bind-iptables-nft

        - path: /etc/systemd/system/snap.microk8s.daemon-kubelite.service.d/override.conf
          permissions: '0644'
          owner: root:root
          content: |
            [Service]
            LimitNOFILE=1048576
            LimitNPROC=512000

      runcmd:
        - echo "=== Iniciando setup ===" >> /var/log/cloud-init-debug.log
        - apt-get update >> /var/log/cloud-init-debug.log 2>&1
        - apt-get install -y snapd jq curl iptables zfsutils-linux >> /var/log/cloud-init-debug.log 2>&1

        - echo "=== Aguardando inicializacao nativa do snapd ===" >> /var/log/cloud-init-debug.log
        - snap wait system seed.loaded >> /var/log/cloud-init-debug.log 2>&1

        - echo "=== Instalando MicroK8s ===" >> /var/log/cloud-init-debug.log
        - snap install microk8s --channel=1.36/stable --classic >> /var/log/cloud-init-debug.log 2>&1
        - sleep 5
        - snap refresh --hold microk8s >> /var/log/cloud-init-debug.log 2>&1
        - echo "=== MicroK8s instalado com sucesso ===" >> /var/log/cloud-init-debug.log

        - sed -i 's/snapshotter = ".*"/snapshotter = "overlayfs"/g' /var/snap/microk8s/current/args/containerd-template.toml
        - grep -qxF -- '--protect-kernel-defaults=false' /var/snap/microk8s/current/args/kubelet || echo '--protect-kernel-defaults=false' >> /var/snap/microk8s/current/args/kubelet
        - grep -qxF -- '--enforce-node-allocatable=""' /var/snap/microk8s/current/args/kubelet || echo '--enforce-node-allocatable=""' >> /var/snap/microk8s/current/args/kubelet

        - mkdir -p /var/snap/microk8s/current/args/cni-network
        - grep -qxF -- '--cni-conf-dir=/var/snap/microk8s/current/args/cni-network' /var/snap/microk8s/current/args/kubelet || echo '--cni-conf-dir=/var/snap/microk8s/current/args/cni-network' >> /var/snap/microk8s/current/args/kubelet

        - sed -i '/^--proxy-mode=/d' /var/snap/microk8s/current/args/kube-proxy
        - echo '--proxy-mode=nftables' >> /var/snap/microk8s/current/args/kube-proxy
        - prlimit --pid=$$ --nofile=1048576:1048576 || true

        - systemctl daemon-reload
        - rm -f /var/snap/microk8s/current/var/kubernetes/backend/kine.sock
        - chmod -R 777 /var/snap/microk8s/current/var/kubernetes/backend/

        - sysctl --system
        - ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf || true
        - snap set system refresh.hold=forever

        - /usr/local/sbin/microk8s-bind-iptables-nft
        - snap restart microk8s
        - microk8s status --wait-ready
  devices:
    aadisable:
      path: /sys/module/nf_conntrack/parameters/hashsize
      source: /sys/module/nf_conntrack/parameters/hashsize
      type: disk
    aadisable2:
      path: /dev/kmsg
      source: /dev/kmsg
      type: unix-char
    aadisable3:
      path: /sys/fs/bpf
      source: /sys/fs/bpf
      type: disk
    aadisable4:
      path: /proc/sys/net/netfilter/nf_conntrack_max
      source: /proc/sys/net/netfilter/nf_conntrack_max
      type: disk
EOF
        sudo incus profile device remove default eth0 >/dev/null 2>&1 || true
        sudo incus profile device add default eth0 nic \
            nictype=routed parent=ens4
    ;;
     n)
        echo "Skipping init"
    ;;
esac

sed -i '/incus completion/d' ~/.bashrc
sed -i '/bash_completion/d' ~/.bashrc
echo 'source /usr/share/bash-completion/bash_completion' >> ~/.bashrc
echo 'source <(sudo incus completion bash)' >> ~/.bashrc
source /usr/share/bash-completion/bash_completion 2>/dev/null || true
source <(sudo incus completion bash) 2>/dev/null || true

clr_answr=$(timeout --foreground 5s \
whiptail --title "Incus clean" \
--default-item s \
--menu "Escolha" 12 60 3 \
s "SIM (default após 5 s)" \
n "Não " \
3>&1 1>&2 2>&3)

exitstatus=$?

if [ "$exitstatus" -eq 124 ]; then
    clr_answr="s"
elif [ "$exitstatus" -ne 0 ]; then
    echo "Operação cancelada. Não limpando."
    clr_answr="n"
fi

case "${clr_answr,,}" in
    s|y)
        for i in {2..4}; do
             sudo incus delete -f "$(hostname)-$i" 2>/dev/null || true
        done
    ;;
     n)
        echo "Skipping clean"
    ;;
esac

sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null

IP_MAQUINA=$(ip route get 1.1.1.1 | awk '{print $7}')
ULTIMO_OCTETO=$(echo "$IP_MAQUINA" | cut -d. -f4)

case "$ULTIMO_OCTETO" in
    17) BASE_IP=17; ALIAS_CIDR=10.42.0.16/28 ;;
    33) BASE_IP=33; ALIAS_CIDR=10.42.0.32/28 ;;
    49) BASE_IP=49; ALIAS_CIDR=10.42.0.48/28 ;;
    *)
        echo "IP privado do host inesperado: $IP_MAQUINA" >&2
        exit 1
        ;;
esac

# O google-guest-agent instala os alias IPs como enderecos locais em ens4, o que
# faz o kernel descartar o ARP dos containers como "martian source".
printf '[IpForwarding]\nip_aliases = false\ntarget_instance_ips = false\n' \
    | sudo tee /etc/default/instance_configs.cfg >/dev/null
sudo systemctl restart google-guest-agent
for offset in $(seq 1 3); do
    sudo ip route del local "10.42.0.$((BASE_IP + offset))" dev ens4 table local 2>/dev/null || true
done

# Os alias IPs nao tem saida externa propria; o trafego de internet sai NATeado
# pelo IP primario do host, preservando o acesso direto dentro de 10.42.0.0/24.
sudo iptables -t nat -C POSTROUTING -s "$ALIAS_CIDR" ! -d 10.42.0.0/24 -j MASQUERADE 2>/dev/null \
    || sudo iptables -t nat -A POSTROUTING -s "$ALIAS_CIDR" ! -d 10.42.0.0/24 -j MASQUERADE

# --- LOOP DE CRIAÇÃO PARALELA NA REDE GCE ---
echo "Disparando a criacao dos containers routed..."
for i in {2..4}; do
    IP_FINAL="10.42.0.$((BASE_IP + i - 1))"
    CONTAINER_NAME="$(hostname)-$i"
    echo "Lancando $CONTAINER_NAME com o IP $IP_FINAL"

    NETWORK_CONFIG=$(cat <<EOF
version: 2
ethernets:
  eth0:
    addresses:
      - $IP_FINAL/32
    routes:
      - to: default
        via: 169.254.0.1
        on-link: true
    nameservers:
      addresses:
        - 8.8.8.8
        - 1.1.1.1
EOF
)

    if ! sudo incus launch images:ubuntu/26.04/cloud "$CONTAINER_NAME" \
      --profile default \
      --profile microk8s \
      --device eth0,ipv4.address="$IP_FINAL" \
      --config cloud-init.network-config="$NETWORK_CONFIG"; then
        echo "Falha ao lancar $CONTAINER_NAME" >&2
    fi
done

echo "Processo concluído com sucesso!"
