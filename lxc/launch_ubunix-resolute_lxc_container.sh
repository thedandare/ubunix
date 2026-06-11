#!/bin/sh

# 1. Cria a receita cloud-init pura para o Ubuntu
cat << 'EOF' > nix-config.yaml
#cloud-config
apt_update: true
apt_upgrade: true

packages:
  - curl
  - git
  - xz-utils
  - kubelet
  - kubeadm
  - kubectl
  - flannel

runcmd:
  # 1. Cria diretório do Nix com permissões corretas
  - mkdir -p /nix && chown root:root /nix && chmod 0755 /nix
  - mv monitorar-nix.sh monitorar-nix.sh.old
  - mv nix-config.yaml nix-config.yaml.old
  - export HOME=/root

  # 2. Executa o instalador do Nix oficial (Multi-user daemon recomendado para Ubuntu)
  - |
    cat << 'SCRIPT_EOF' > instalar_nix.sh
    #!/bin/sh
    curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install | sh -s -- --daemon --yes
    SCRIPT_EOF
  - chmod +x instalar_nix.sh
  - instalar_nix.sh >> nix-install.log 2>&1

  # 3. Carrega o ambiente do Nix no cloud-init
  - . /etc/profile.d/nix.sh

  # 4. Ativa o suporte a Flakes
  - mkdir -p /root/.config/nix
  - echo "experimental-features = nix-command flakes" >> /root/.config/nix/nix.conf

  # 5. Configuração do Home Manager
  - mkdir -p /root/.config/home-manager
  - |
    cat << 'INNER_EOF' > /root/.config/home-manager/flake.nix
    {
      description = "Home Manager Automatizado";
      inputs = {
        nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
        home-manager = {
          url = "github:nix-community/home-manager";
          inputs.nixpkgs.follows = "nixpkgs";
        };
      };
      outputs = { nixpkgs, home-manager, ... }: {
        homeConfigurations."root" = home-manager.lib.homeManagerConfiguration {
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          modules = [ ./home.nix ];
        };
      };
    }
    INNER_EOF
  - |
    cat << 'INNER_EOF' > /root/.config/home-manager/home.nix
    { pkgs, ... }: {
      home.username = "root";
      home.homeDirectory = "/root";
      home.stateVersion = "24.11";
      home.packages = [
        pkgs.htop
        pkgs.turbovnc
      ];
      programs.home-manager.enable = true;
    }
    INNER_EOF


  - cd /root/.config/home-manager && git init
  - cd /root/.config/home-manager && git add flake.nix home.nix

  # 6. Ativa o ambiente declarativo usando o binário absoluto do Nix recém-instalado
  - sudo su
  - /nix/var/nix/profiles/default/bin/nix run github:nix-community/home-manager -- switch --flake /root/.config/home-manager/#root >> nix-install.log 2>&1

  # 7. Garante persistência dos caminhos para acessos via SSH/Console
  - echo 'if [ -f /etc/profile.d/nix.sh ]; then . /etc/profile.d/nix.sh; fi' >> /etc/profile
  - echo 'export PATH=$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH' >> /root/.bashrc

EOF

# 2. Cria o monitor do log real do instalador do Nix
cat << 'EOF' > monitorar-nix.sh
#!/bin/sh
CONTAINER="teste-ubnix"
LOG_FILE="nix-install.log"

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
EOF

chmod +x monitorar-nix.sh

# 3. Executa a limpeza e configuração do repositório remoto do Ubuntu Minimal
echo "[==>] Limpando instâncias antigas..."
lxc delete teste-ubnix --force 2>/dev/null

# echo "[==>] Adicionando repositório remoto ubuntu-minimal (se não existir)..."
# lxc remote add ubuntu-minimal https://cloud-images.ubuntu.com/minimal/releases/ --protocol=simplestreams --accept-certificate 2>/dev/null || true
# sem a linha acima q deu o erro 'Error: Failed instance creation: Fetch project database object: Failed to fetch from "projects" table: Failed to fetch from "projects" table: Failed to fetch from "projects" table: sql: transaction has already been committed or rolled back'
# ele deve pegar  o padrao.

echo "[==>] Lançando novo container Ubuntu Minimal (Resolute)..."
lxc launch ubuntu-minimal:resolute teste-ubnix \
 	-c security.nesting=true \
  	-c security.privileged=true \
	--config=cloud-init.user-data="$(cat nix-config.yaml)"

# 4. Inicia o monitoramento
./monitorar-nix.sh
