# This file is intentionally tiny: it gives NixOS users a reproducible
# development shell for TUINIX without requiring a global gcc installation.
#
# The application itself is pure Go.  CGO is disabled because Bubble Tea,
# Lip Gloss, git command execution, and xdg-open integration do not need C.
# This avoids the common NixOS error:
#   cgo: C compiler "gcc" not found
{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  packages = with pkgs; [
    go
    git
    xdg-utils
  ];

  shellHook = ''
    export CGO_ENABLED=0
    echo "TUINIX dev shell"
    echo "CGO_ENABLED=$CGO_ENABLED"
  '';
}
