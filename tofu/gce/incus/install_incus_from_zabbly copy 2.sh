#!/bin/bash



sudo mkdir -p /etc/apt/keyrings/
sudo curl -fsSL https://pkgs.zabbly.com/key.asc \
    -o /etc/apt/keyrings/zabbly.asc

# Add the stable repository (Ubuntu 22.04/24.04)
sudo sh -c 'cat > /etc/apt/sources.list.d/zabbly-incus-stable.sources << EOF
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: $(. /etc/os-release && echo $VERSION_CODENAME)
Components: main
Architectures: amd64 arm64
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF'

# Update and install
sudo apt-get update

if ! command -v whiptail >/dev/null 2>&1; then
    apt-get install -y whiptail 
fi
if ! command -v incus >/dev/null 2>&1; then
    timeout 3 whiptail --title "Detectando Incus" --msgbox "Incus ifconfig não está instalado\n\nInstalando via apt" 7 70 >&2
    clear
    sudo apt-get install -y incus bash-completion |  whiptail --progressbox "Executando apt-get " 20 70
else
    timeout 2 whiptail --title "Incus 👌" --msgbox " Versao: $(incus --version) --  $(uname -a)" 7 70 >&2
    timeout 1 clear
fi  
  
if ! command -v ifconfig >/dev/null 2>&1; then
    timeout 3 whiptail --title "fINALizado!" --msgbox "ifconfig não está instalado\n\nInstalando via net-tools" 7 70 >&2
    clear
    sudo apt-get install -y  net-tools 
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
        cat <<EOF | sudo incus admin init --preseed
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
  description: "Perfil padrao com roteamento direto para a rede local"
  devices:
    eth0:
      name: eth0
      nictype: routed
      parent: ens4     # Usa a sua interface ens4 que tem o IP 10.42.0.X
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
      #cloud-config
      package_update: true
      package_upgrade: true

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
            set -euo pipefail

            SOURCE=/snap/microk8s/current/sbin/iptables-nft
            TARGET=/snap/microk8s/current/sbin/iptables

            [ -x "$SOURCE" ]
            [ -e "$TARGET" ]

            if "$TARGET" --version 2>&1 | grep -q 'nf_tables' && \
               "$TARGET" -t nat -S >/dev/null 2>&1; then
              exit 0
            fi

            umount "$TARGET" >/dev/null 2>&1 || true
            mount --bind "$SOURCE" "$TARGET"

            "$TARGET" --version 2>&1 | grep -q 'nf_tables'
            "$TARGET" -t nat -S >/dev/null

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
        - apt-get install -y jq curl libnetfilter-conntrack3 libnfnetlink0 iptables zfsutils-linux >> /var/log/cloud-init-debug.log 2>&1

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
        - /snap/microk8s/current/sbin/iptables -t nat -S >/dev/null
        - snap restart microk8s
        - microk8s status --wait-ready
EOF

    ;;
     n)
        echo "Skipping init"
    ;;
esac

sed -i '/incus completion/d' ~/.bashrc
sed -i '/bash_completion/d' ~/.bashrc
echo 'source /usr/share/bash-completion/bash_completion' >> ~/.bashrc
echo 'source <(incus completion bash)' >> ~/.bashrc
source /usr/share/bash-completion/bash_completion
source <(incus completion bash)

ULTIMO_CHAR=$(hostname | sed 's/.*\(.\)$/\1/')
IP_MAQUINA=$(ip route get 1.1.1.1 | awk '{print $7}')
ULTIMO_OCTETO=$(echo "$IP_MAQUINA" | cut -d. -f4)

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
    echo "Operação cancelada.  "
    clr_answr="n"
fi

case "${clr_answr,,}" in
    s|y)
        for i in {1..3}; do
             incus rm  "$(hostname)-$i" --force
        done
    ;;
     n)
        echo "Skipping clean"
    ;;
esac


# 2. Executa o loop de criação em paralelo
for i in {1..3}; do
    # Multiplica o octeto por 10 para criar a base (20, 30 ou 40)
    BASE_IP=$(( ULTIMO_OCTETO * 10 ))
    IP_FINAL="10.42.0.$((BASE_IP + i))"
    
    echo "Lancando $(hostname)-$i com o IP Roteado: $IP_FINAL"
    
    incus launch images:ubuntu/24.04/cloud "$(hostname)-$i" \
      --profile default \
      --profile microk8s \
      --device eth0,ipv4.address="$IP_FINAL" &
done


# 1. Captura o IP ativo e extrai o último octeto (ex: 2, 3 ou 4)
IP_MAQUINA=$(ip route get 1.1.1.1 | awk '{print $7}')
ULTIMO_OCTETO=$(echo "$IP_MAQUINA" | cut -d. -f4)

echo "Configurando rotas cruzadas a partir do host físico .${ULTIMO_OCTETO}..."

# Rota para os containers do Host santiago0 (.2) -> IPs .21, .22, .23
if [ "$ULTIMO_OCTETO" -ne 2 ]; then
    sudo ip route add 10.42.0.20/29 via 10.42.0.2 dev ens4 2>/dev/null || true | whiptail --progressbox "Executando ip route add em santiago0" 20 70 
    echo "-> Rota para os containers da maquina .2 adicionada com sucesso."
fi

# Rota para os containers do Host santiago1 (.3) -> IPs .31, .32, .33
if [ "$ULTIMO_OCTETO" -ne 3 ]; then
    sudo ip route add 10.42.0.30/29 via 10.42.0.3 dev ens4 2>/dev/null || true | whiptail --progressbox "Executando ip route add em santiago1" 20 70 
    echo "-> Rota para os containers da maquina .3 adicionada com sucesso."
fi

# Rota para os containers do Host santiago2 (.4) -> IPs .41, .42, .43
if [ "$ULTIMO_OCTETO" -ne 4 ]; then
    sudo ip route add 10.42.0.40/29 via 10.42.0.4 dev ens4 2>/dev/null || true | whiptail --progressbox "Executando ip route add em santiago2" 20 70
    echo "-> Rota para os containers da maquina .4 adicionada com sucesso."
fi

whiptail --title "fINALizado!" --msgbox "$(ifconfig ens4)" 18 170

