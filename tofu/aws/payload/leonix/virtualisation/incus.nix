{ config, pkgs, lib, ... }:

let
  cloudInitConfig = builtins.readFile ./cloud-init.yaml;
  networkConfig = builtins.readFile ./network-config.yaml;
in
{
  virtualisation.incus = {
    enable = true;

    ui.enable = true;
    agent.enable = true;

    preseed = {
      storage_pools = [
        {
          name = "default";
          driver = "dir";
        }
      ];

      # Cloud-safe: nao depende de br0/LAN fisica. O Ubuntu ganha DHCP em NAT local.
      networks = [
        {
          name = "incusbr0";
          type = "bridge";
          config = {
            "ipv4.address" = "auto";
            "ipv4.nat" = "true";
            "ipv6.address" = "none";
          };
        }
      ];

      profiles = [
        {
          name = "default";
          devices = {
            root = {
              path = "/";
              pool = "default";
              type = "disk";
            };
          };
        }

        {
          name = "microk8s";
          config = {
            "boot.autostart" = "true";
            "security.nesting" = "true";
            "security.privileged" = "true";
            "linux.kernel_modules" = "ip_vs,ip_vs_rr,ip_vs_wrr,ip_vs_sh,nf_nat,overlay,br_netfilter";

            "raw.lxc" = ''
              lxc.apparmor.profile = unconfined
              lxc.apparmor.allow_nesting = 1
            '';

            "user.user-data" = cloudInitConfig;
            "user.network-config" = networkConfig;
          };

          devices = {
            kmsg = {
              path = "/dev/kmsg";
              source = "/dev/kmsg";
              type = "unix-char";
            };

            eth0 = {
              name = "eth0";
              nictype = "bridged";
              parent = "incusbr0";
              type = "nic";
            };
          };
        }
      ];
    };
  };

  systemd.services.init-incus-leonk8s = {
    description = "Garante a existencia e execucao do container MicroK8s leonk8s";

    after = [
      "incus.service"
      "incus-preseed.service"
      "network-online.target"
    ];
    wants = [
      "incus.service"
      "incus-preseed.service"
      "network-online.target"
    ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
      TimeoutStartSec = "45min";
    };

    path = with pkgs; [ incus coreutils gnugrep systemd ];

    script = ''
      set -euo pipefail

      echo "=== init-incus-leonk8s: aguardando Incus responder ==="
      for i in $(seq 1 60); do
        if incus list >/dev/null 2>&1; then
          break
        fi
        echo "Aguardando Incus... $i/60"
        sleep 2
      done

      if ! incus info leonk8s >/dev/null 2>&1; then
        echo "Container leonk8s nao encontrado. Criando..."
        incus launch images:ubuntu/26.04/cloud leonk8s -p default -p microk8s
      else
        echo "Container leonk8s ja existe. Garantindo estado running..."
        incus start leonk8s || true
      fi

      echo "=== init-incus-leonk8s: estado atual ==="
      incus list
    '';
  };
}
