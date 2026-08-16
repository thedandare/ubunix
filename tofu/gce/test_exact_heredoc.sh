#!/bin/bash

# Teste exato como está no arquivo

echo "=== Teste Exato do Heredoc ==="
echo "Digitando exatamente como está no arquivo..."

# Simula a entrada exata do arquivo
cat > /tmp/test_input.sh << 'SCRIPT'
INCUS_CLOUD_INIT=$(cat <<'ENDINIT'
    #cloud-config
    package_update: true
    package_upgrade: false
    users:
      - name: root
        ssh_authorized_keys:
          - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICs+sOj/1GK5exkDkCw7H7zmDapshfWaRn474qxZxSUY leo"
    ssh_pwauth: true
    chpasswd:
      list:
        - root:Senha171
      expire: false
    runcmd:
      - apt-get update
      - snap install microk8s --channel=1.36/stable --classic
      - sed -i 's/snapshotter = ".*"/snapshotter = "overlayfs"/g' /var/snap/microk8s/current/args/containerd-template.toml
ENDINIT
)

echo "Tamanho: $(echo "$INCUS_CLOUD_INIT" | wc -c)"
echo "Funcionou!"
SCRIPT

chmod +x /tmp/test_input.sh
bash /tmp/test_input.sh
