{ modulesPath, ... }: {
  imports = [
    "${modulesPath}/virtualisation/google-compute-image.nix"
    ./incus-gce.nix
  ];

  networking.hostName = "nixos-gce";
}
