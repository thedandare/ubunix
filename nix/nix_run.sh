#!/bin/sh
#nix run --extra-experimental-features "nix-command flakes" run github:nix-community/home-manager -- switch --flake .
mkdir -p /etc/nix
echo "experimental-features = nix-command flakes" > /etc/nix/nix.conf
nix run github:nix-community/home-manager -- switch --flake .#root-ubuntu -b backup
