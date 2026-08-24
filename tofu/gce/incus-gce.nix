{ config, lib, pkgs, ... }:

let
  provisionRaw = builtins.readFile ./incus-vm-provision-gce.sh;
  provisionScript =
    builtins.replaceStrings 
      [ "\${pkgs.incus}" "\${pkgs.iproute2}" "\${pkgs.coreutils}" "\${pkgs.gawk}" "\${pkgs.gnused}" ]
      [ "${pkgs.incus}" "${pkgs.iproute2}" "${pkgs.coreutils}" "${pkgs.gawk}" "${pkgs.gnused}" ]
      provisionRaw;

  cloudInitRaw = builtins.readFile ./cloud-init.yaml;
in
{
  # Enable IP forwarding for Incus routed containers
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.forwarding" = 1;
    "net.ipv4.conf.eth0.forwarding" = 1;
  };

  virtualisation.incus = {
    enable = true;

    preseed = {
      config = {};
      networks = [ ];
      storage_pools = [
        {
          name = "default";
          driver = "dir";
          config = {
            source = "/var/lib/incus/storage-pools/default";
          };
        }
      ];
      profiles = [
        {
          name = "default";
          devices = {
            eth0 = {
              name = "eth0";
              nictype = "routed";
              parent = "eth0";
              type = "nic";
            };
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
            "linux.kernel_modules" = "rbd,ip_vs,ip_vs_rr,ip_vs_wrr,ip_vs_sh,nf_nat,overlay,br_netfilter";

            "raw.lxc" = ''
              lxc.apparmor.profile = unconfined
              lxc.apparmor.allow_nesting = 1
              lxc.cap.drop=
              lxc.mount.auto=proc:rw sys:rw
            '';

            "user.user-data" = cloudInitRaw;
          };
          devices = {
            kmsg = {
              path = "/dev/kmsg";
              source = "/dev/kmsg";
              type = "unix-char";
            };
          };
        }
      ];
    };
  };

  systemd.services.init-incus-santi = {
    description = "Garante a existencia e execucao dos containers santi7 santi8 santi9";

    after = [
      "incus.service"
      "incus-preseed.service"
      "network.target"
    ];
    wants = [ "network.target" ];
    bindsTo = [ "incus-preseed.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = provisionScript;
  };
}
