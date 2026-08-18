{ modulesPath, ... }: {
  imports = [ "${modulesPath}/virtualisation/google-compute-image.nix"
   ];

  # Enable services and packages natively
  networking.hostName = "nixos-gce";
  virtualisation.incus.enable = true; # If you still want to run Incus
}
