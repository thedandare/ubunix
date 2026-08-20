let
  nixpkgs = fetchTarball "https://github.com/NixOS/nixpkgs/tarball/nixos-24.05";
  pkgs = import nixpkgs { config = {}; overlays = []; };
in

pkgs.mkShellNoCC {
  packages = with pkgs; [
    opentofu
     git
     google-cloud-sdk
  ];

  shellHook = ''
    echo "OpenTofu: $(tofu --version | head -n 1)"
    echo "gcloud:   $(gcloud version 2>/dev/null | head -n 1)"
    echo "Run: tofu init -backend=false"
    echo "     tofu plan -var-file=terraform.tvars"
    echo "     tofu apply -var-file=terraform.tvars"
  '';
}
