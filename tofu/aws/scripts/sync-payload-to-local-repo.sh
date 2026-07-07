#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${1:-}"
if [ -z "$REPO_DIR" ]; then
  echo "uso: $0 /caminho/para/repositorio/nixos"
  exit 1
fi

TARGET="$REPO_DIR/leonix/virtualisation"
mkdir -p "$TARGET"
cp -v payload/leonix/virtualisation/incus.nix "$TARGET/"
cp -v payload/leonix/virtualisation/cloud-init.template.yaml "$TARGET/"
cp -v payload/leonix/virtualisation/compile-cloudinit.sh "$TARGET/"
cp -v payload/leonix/virtualisation/init_tailscale.sh "$TARGET/"
cp -v payload/leonix/virtualisation/network-config.yaml "$TARGET/"
cp -v payload/leonix/virtualisation/microceph_cluster_join.sh "$TARGET/"
chmod +x "$TARGET/compile-cloudinit.sh" "$TARGET/init_tailscale.sh" "$TARGET/microceph_cluster_join.sh"

echo "Arquivos sincronizados para $TARGET"
echo "Revise, commit e push antes do tofu apply."
