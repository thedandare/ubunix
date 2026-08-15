let
  nixpkgs = fetchTarball "https://github.com/NixOS/nixpkgs/tarball/nixos-24.05";
  pkgs = import nixpkgs { config = {}; overlays = []; };
in

pkgs.mkShellNoCC {
  packages = with pkgs; [
    kubectl
    openssh
  ];

  shellHook = ''
    # Fix SSH Key CRLF line endings and permissions by copying it to WSL home directory
    WINDOWS_KEY="/mnt/c/Users/leo/.ssh/root_id_ed25519"
    WSL_KEY_DIR="$HOME/.ssh"
    WSL_KEY="$WSL_KEY_DIR/root_id_ed25519"

    if [ -f "$WINDOWS_KEY" ]; then
      mkdir -p "$WSL_KEY_DIR"
      tr -d '\r' < "$WINDOWS_KEY" > "$WSL_KEY"
      # OpenSSL 3.0's PEM decoder requires a trailing newline at the end of the file
      echo "" >> "$WSL_KEY"
      chmod 600 "$WSL_KEY"
      echo "=== SSH Key synchronized to $WSL_KEY (LF line endings & 600 permissions) ==="
    else
      echo "=== Warning: Windows SSH key not found at $WINDOWS_KEY ==="
    fi
  '';
}
