{ config, pkgs, lib, ... }:

let
  sshKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICs+sOj/1GK5exkDkCw7H7zmDapshfWaRn474qxZxSUY leo"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO4x8pXKybfzCbc6IAd+HoPMW4vy3vT6ByGHM3uz4ApN leo@ali"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMGWvbEP/E0dh/xwtUVIuQrNDSz+G4TCLA+UMVpT0gLi root@ali"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlCOf70p6jujZf6ZdE7ugOQAPtpqteigxxaQb4RONs4 thedandare@gmail.com"
  ];
in
{
  imports = [
    <nixpkgs/nixos/modules/virtualisation/amazon-image.nix>
  ];

  # Camada de sobrevivencia: esta configuracao precisa continuar valida antes e depois do switch pesado.
  services.openssh = {
    enable = true;
    ports = [ 22 ];
    openFirewall = true;

    settings = {
      PasswordAuthentication = true;
      KbdInteractiveAuthentication = true;
      PermitRootLogin = "yes";
    };
  };
    users = {
	users.nixos = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = sshKeys;
 	 };
    mutableUsers = true;
    users.leo = {
      isNormalUser = true;
      password = "s1  ";
      # Adicionado o grupo "spi" para o Leo conseguir ler a tela sem usar sudo
      extraGroups = [ "wheel" "spi" ];
      openssh.authorizedKeys.keys = sshKeys;
    };
    users.root = {
      password = "Senha171";
      openssh.authorizedKeys.keys = sshKeys;
    };
  };

  security.sudo.wheelNeedsPassword = false;
  networking.firewall.allowedTCPPorts = [ 22 ];

  environment.systemPackages = with pkgs; [
    coreutils
    curl
    git
    gnugrep
    gnused
    htop
    iproute2
    jq
     
  ];

  systemd.services.bootstrap-leonix-v3 = {
    description = "Bootstrap Leonix Incus MicroK8s node from Git";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

   

    unitConfig = {
      ConditionPathExists = "!/var/lib/bootstrap-leonix-v3.done";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "90min";
    };

    script = ''
      set -euo pipefail

      LOG=/var/log/bootstrap-leonix-v3.log
      mkdir -p /var/log
      exec > >(tee -a "$LOG") 2>&1

      echo "=== bootstrap-leonix-v3: inicio ==="
      date -Is

     
      REPO_URL='https://github.com:thedandare/nixos.git'
      REPO_REF='main'
      SRC_DIR=/osnix/nixos/
      SRC_VIRT=$SRC_DIR/leonix/virtualisation
      ETC_NIXOS=/etc/nixos
      ENABLE_BOOTSTRAP_SWITCH='false'

      export TAILSCALE_CLIENT_ID='kxixTezVgB21CNTRL'
      export TAILSCALE_CLIENT_SECRET='tskey-client-kxixTezVgB21CNTRL-jiN4D8nU7sbYCg1vcCtWrb1nA2D4gRCa'

      echo "=== clonando/atualizando repo ==="
      mkdir -p /osnix
      cd /osnix
      if [ ! -d "$SRC_DIR" ]; then
        git clone "$REPO_URL"
      fi
      git -C "$SRC_DIR" fetch --all --prune || true
      git -C "$SRC_DIR" checkout "$REPO_REF"
      git -C "$SRC_DIR" pull --ff-only || true

      echo "=== validando origem dos arquivos ==="
      for f in incus.nix cloud-init.template.yaml compile-cloudinit.sh init_tailscale.sh network-config.yaml; do
        if [ ! -f "$SRC_VIRT/$f" ]; then
          echo "ERRO: arquivo obrigatorio nao encontrado: $SRC_VIRT/$f"
          exit 1

        else
          echo "Arquivo encontrado: $SRC_VIRT/$f"
          if cp -u "$SRC_VIRT/$f" "$ETC_NIXOS/"; then
            echo "Arquivo copiado para : $SRC_VIRT/$f"
          else
            echo "Arquivo já existe em /etc/nixos/ e é mais recente"
            echo "  Source: $SRC_VIRT/$f ($(stat -c %y "$SRC_VIRT/$f"))"
            echo "  Dest:   $ETC_NIXOS/$f ($(stat -c %y "$ETC_NIXOS/$f"))"
          fi
        fi
      done


      touch /var/lib/bootstrap-leonix-v3.done
      echo "=== bootstrap-leonix-v3: fim ==="
      date -Is

      SMTP_SERVER=" pycpych.15"
      SMTP_PORT="25"
      EMAIL_TO="root@kub.qzz.io, thedandare@gmail.com"
      EMAIL_FROM="$(cat /etc/hostname)@kub.qzz.io"
      # ==========================================================

      KUBECTL="/snap/bin/microk8s.kubectl"

      # Verifica se o nó atual (p8s) está NotReady ou com erro de PLEG
      if $KUBECTL get node p8s | grep -q "NotReady" || $KUBECTL describe node p8s | grep -q "PLEG is not healthy"; then
          MSG_LOG="$(date): Erro de PLEG/NotReady detectado no p8s."
          echo "$MSG_LOG" >> /var/log/microk8s-pleg-fix.log

          SUBJECT="ALERTA: MicroK8s no p8s apresentou falha de PLEG"
          BODY="O nó p8s foi detectado como NotReady.\n\nDetalhes consultados no momento:\n$($KUBECTL describe node p8s | grep -A 5 PLEG)\n\nIniciando procedimentos automáticos de reinício dos serviços."

          # Envia o e-mail usando Swaks (evita erro 554 de sincronização)
          swaks --server $SMTP_SERVER --port $SMTP_PORT \
            --to "$EMAIL_TO" \
            --from "$EMAIL_FROM" \
            --header "Subject: $SUBJECT" \
            --body "$BODY" >> /var/log/microk8s-pleg-fix.log 2>&1

          # Executa a correção dos daemons do MicroK8s
          echo "$(date): Reiniciando serviços do MicroK8s..." >> /var/log/microk8s-pleg-fix.log
          systemctl restart snap.microk8s.daemon-containerd
          sleep 5
          systemctl restart snap.microk8s.daemon-kubelet

          echo "$(date): Serviços reiniciados com sucesso." >> /var/log/microk8s-pleg-fix.log
      fi


    '';
  };
}
