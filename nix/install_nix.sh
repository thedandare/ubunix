#!/bin/sh
curl -L https://nixos.org/nix/install | sh -s -- --daemon
sudo su -
nix-shell -p nix-info --run "nix-info -m"

 # - system: `"x86_64-linux"`
 # - host os: `Linux 7.0.0-22-generic, Ubuntu, 26.04 LTS (Resolute Raccoon), nobuild`
 # - multi-user?: `yes`
 # - sandbox: `yes`
 # - version: `nix-env (Nix) 2.34.7`
 # - channels(root): `"nixpkgs"`
 # - nixpkgs: `/nix/store/l3cpcx0fy79xn9ahn7s39q0n8p6l1glx-nixpkgs/nixpkgs`
