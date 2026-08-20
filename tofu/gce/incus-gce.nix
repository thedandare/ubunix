{ config, pkgs, ... }:

let
  provisionRaw = builtins.readFile ./incus-vm-provision-gce.sh;
  provisionScript =
    builtins.replaceStrings [ "\${pkgs.incus}" ] [ "${pkgs.incus}" ] provisionRaw;

  cloudInitRaw = builtins.readFile /etc/nixos/virtualisation/cloud-init.yaml;
in
{
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
              parent = "ens4";
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
