{ config, pkgs, lib, ... }:
{
  environment.systemPackages = with pkgs; [
  git vim 
    coreutils   # utilitários POSIX essenciais; binários: ls, cp, mv, rm, cat, echo, mkdir, chmod, chown, date, head, tail, wc, sort, uniq, cut, tr, tee, pwd, touch, ln, stat, df, du, id, whoami, env, sleep, kill, …
    findutils   # busca de arquivos no sistema; binários: find, xargs, locate, updatedb
    gnugrep     # busca de padrões em texto (regex); binários: grep, egrep, fgrep
    gnused      # editor de fluxo para substituição/transformação de texto; binários: sed
    htop        # monitor de processos interativo (top melhorado); binários: htop
    iproute2    # configuração de rede moderna (substitui net-tools); binários: ip, ss, tc, bridge, nstat, routel
    jq          # processamento e filtragem de JSON na linha de comando; binários: jq
  ];
  # Configuração de usuários
  users.users.ubuntu = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    password = "Senha171";
  };

  users.users.root = {
    password = "Senha171";
  };

  # SSH
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = true;
    };
  };

  # Firewall
  networking.firewall.allowedTCPPorts = [ 22 ];

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Sistema
  system.stateVersion = "24.11";
}
