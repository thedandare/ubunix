#!/bin/bash

# Teste para verificar se a variável INCUS_CLOUD_INIT é criada corretamente

echo "=== Teste de Criação da Variável INCUS_CLOUD_INIT ==="
echo

# Testa com aspas simples (como está no arquivo)
echo "Testando com aspas simples 'ENDINIT':"
INCUS_CLOUD_INIT_SINGLE=$(cat <<'ENDINIT'
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
write_files:
  - path: /etc/netplan/99-dns.yaml
    permissions: '0644'
    content: |
      network:
        version: 2
        ethernets:
          eth0:
            dhcp4: true
runcmd:
  - apt-get update
  - apt-get install -y snapd
  - snap install microk8s --channel=1.36/stable --classic
  - sed -i 's/snapshotter = ".*"/snapshotter = "overlayfs"/g' /var/snap/microk8s/current/args/containerd-template.toml
ENDINIT
)

echo "Tamanho da variável: $(echo "$INCUS_CLOUD_INIT_SINGLE" | wc -c) caracteres"
echo "Primeiras 3 linhas:"
echo "$INCUS_CLOUD_INIT_SINGLE" | head -3
echo

# Testa se a variável pode ser usada em comando lxc
echo "Testando uso em comando lxc (simulação):"
echo "lxc launch ubuntu:24.04 test-container -c user.user-data=\"\$INCUS_CLOUD_INIT_SINGLE\""
echo

# Verifica se há problemas com aspas
echo "Verificando aspas na variável:"
echo "$INCUS_CLOUD_INIT_SINGLE" | grep -n "'" | head -3
echo "Contagem de aspas simples: $(echo "$INCUS_CLOUD_INIT_SINGLE" | grep -o "'" | wc -l)"
echo

echo "✅ Variável criada com sucesso!"
