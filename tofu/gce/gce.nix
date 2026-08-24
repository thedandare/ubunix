{ modulesPath, pkgs, ... }: {
  imports = [
    "${modulesPath}/virtualisation/google-compute-image.nix"
    ./incus-gce.nix
  ];

  networking.hostName = "nixos-gce";

  # Desativar google-guest-agent para evitar interferencia no roteamento
  # e na gestao de contas da VM
  systemd.services.google-guest-agent.enable = false;
  systemd.services.google-guest-configs.enable = false;
  systemd.services.google-guest-shutdown-scripts.enable = false;

  # Garantir que o root tenha chave SSH e um shell funcional
  # sem ser modificado pelos servicos do Google Guest Agent
  users.mutableUsers = false;
  users.users.root = {
    isSystemUser = false;
    shell = pkgs.bash;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMGWvbEP/E0dh/xwtUVIuQrNDSz+G4TCLA+UMVpT0gLi root@ali"
    ];
  };

  services.openssh = {
    settings.PermitRootLogin = "yes";
    settings.PasswordAuthentication = false;
    settings.PermitEmptyPasswords = "no";
  };
}
