#!/bin/bash
# Add the Zabbly repository for Incus

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
sudo apt-get install -y incus incus-tools

# Verify installation
incus --version


 

read -n 1 -p "Incus init??\n y - yes\n p - preseed\n n - no\n " answer
case "${answer,,}" in
    y)
        sudo incus admin init
    ;;
    p)
        cat <<EOF | sudo incus admin init --preseed
        config: {}
        networks:
        - config:
            ipv4.address: auto
            i   pv6.address: auto
        description: ""
        name: incusbr0
        type: bridge
        storage_pools:
        - config:
            size: 16GiB
        description: ""
        name: default
        driver: btrfs
        profiles:
        - config: {}
        description: ""
        devices:
            eth0:
            name: eth0
            network: incusbr0
            type: nic
            root:
            path: /
            pool: default
            type: disk
        name: default
        EOF
    ;;
     n)
        echo "Skipping init"
    ;;
esac
