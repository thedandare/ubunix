let
  nixpkgs = fetchTarball "https://github.com/NixOS/nixpkgs/tarball/nixos-24.05";
  pkgs = import nixpkgs { config = {}; overlays = []; };
in

pkgs.mkShellNoCC {
  packages = with pkgs; [
    kubectl
    google-cloud-sdk
    opentofu
    tofi
    tmux
];

shellHook = ''
  alias vi=nvim
  alias vim=nvim
'';
}
