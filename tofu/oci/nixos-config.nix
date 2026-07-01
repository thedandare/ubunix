{ config, pkgs, lib, ... }:

{
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
