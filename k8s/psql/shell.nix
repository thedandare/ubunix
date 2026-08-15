let
  nixpkgs = fetchTarball "https://github.com/NixOS/nixpkgs/tarball/nixos-24.05";
  pkgs = import nixpkgs { config = {}; overlays = []; };
in

pkgs.mkShellNoCC {
  packages = with pkgs; [
    kubectl
    
  ];

  shellHook = ''
'';

#scp /th/pato/local/file username@remote_host:/path/to/remote/destination
}