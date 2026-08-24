# Este código é compatível com a versão 4.25.0 do Terraform e com as que têm compatibilidade com versões anteriores à 4.25.0.
# Para informações sobre como validar esse código do Terraform, consulte https://developer.hashicorp.com/terraform/tutorials/gcp-get-started/google-cloud-platform-build#format-and-validate-the-configuration

resource "google_compute_instance" "espanha0-20260822-173833" {
  boot_disk {
    auto_delete = false
    device_name = "montreal0"

    initialize_params {
      size = 35
      type = "pd-standard"
    }

    mode = "READ_WRITE"
  }

  can_ip_forward      = true
  deletion_protection = false
  enable_display      = false

  labels = {
    goog-ec-src                = "vm_add-tf"
    goog-terraform-provisioned = "true"
    os                         = "ubuntu"
    pricing                    = "spot"
  }

  machine_type = "t2d-standard-2"

  metadata = {
    block-project-ssh-keys = "true"
    enable-oslogin         = "TRUE"
    serial-port-enable     = "TRUE"
    shutdown-script        = "#!/usr/bin/env bash\nset -euo pipefail\necho \"[gce-spot] shutdown/preemption notice at $(date --iso-8601=seconds)\" | systemd-cat -t gce-spot-shutdown || true\nsync || true\n"
    user-data              = "#cloud-config\npackage_update: true\npackage_upgrade: true\nhostname: santiago0\n\nusers:\n  - name: root\n    ssh_authorized_keys:\n      - \n\nssh_pwauth: true\nchpasswd:\n  list:\n    - root:Senha171\n  expire: false\n\nwrite_files:\n  - path: /etc/sysctl.d/99-kubernetes.conf\n    permissions: '0644'\n    content: |\n      net.ipv4.ip_forward = 1\n      fs.inotify.max_user_instances = 512\n      fs.inotify.max_user_watches = 524288\n      net.bridge.bridge-nf-call-iptables = 1\n      net.bridge.bridge-nf-call-ip6tables = 1\n\n  - path: /etc/netplan/99-dns.yaml\n    permissions: '0644'\n    content: |\n      network:\n        version: 2\n        ethernets:\n          eth0:\n            dhcp4: true\n            nameservers:\n              addresses:\n                - 1.1.1.1\n                - 8.8.8.8\n\n  - path: /etc/ssh/sshd_config.d/99-custom-port.conf\n    permissions: '0644'\n    content: |\n      Port 22\n      Port 2409\n\nruncmd:\n  - echo \"=== Iniciando setup ===\" \n  - apt-get update \n  - apt-get install -y snapd jq curl libnetfilter-conntrack3 libnfnetlink0 iptables zfsutils-linux \n\n  - echo \"=== Configurando snapd ===\" \n  - systemctl unmask snapd.service snapd.socket || true \n  - systemctl enable snapd.service snapd.socket || true \n  - systemctl start snapd.service snapd.socket || true \n  - hostnamectl hostname santiago0\n\n  # - echo \"=== Instalando LXD ===\" \n  # - sleep 5\n  # - snap install lxd \n  # - sleep 5\n  # - lxd init --auto \n  # - sleep 5\n  # - echo \"=== LXD instalado com sucesso ===\" \n\n  - echo \"=== Instalando MicroK8s ===\" \n  - snap install microk8s --channel=1.36/stable --classic \n  - sleep 5\n  - snap refresh --hold microk8s \n  - echo \"=== MicroK8s instalado com sucesso ===\" \n\n  - sed -i 's/snapshotter = \".*\"/snapshotter = \"overlayfs\"/g' /var/snap/microk8s/current/args/containerd-template.toml\n  - grep -qxF -- '--protect-kernel-defaults=false' /var/snap/microk8s/current/args/kubelet || echo '--protect-kernel-defaults=false' >> /var/snap/microk8s/current/args/kubelet\n  - grep -qxF -- '--enforce-node-allocatable=\"\"' /var/snap/microk8s/current/args/kubelet || echo '--enforce-node-allocatable=\"\"' >> /var/snap/microk8s/current/args/kubelet\n\n  - mkdir -p /var/snap/microk8s/current/args/cni-network\n  - grep -qxF -- '--cni-conf-dir=/var/snap/microk8s/current/args/cni-network' /var/snap/microk8s/current/args/kubelet || echo '--cni-conf-dir=/var/snap/microk8s/current/args/cni-network' >> /var/snap/microk8s/current/args/kubelet\n\n  - sed -i '/^--proxy-mode=/d' /var/snap/microk8s/current/args/kube-proxy\n  - echo '--proxy-mode=nftables' >> /var/snap/microk8s/current/args/kube-proxy\n  - prlimit --pid=$$ --nofile=1048576:1048576 || true\n  - mkdir -p /etc/systemd/system/snap.microk8s.daemon-kubelite.service.d\n  - |\n    cat <<EOF > /etc/systemd/system/snap.microk8s.daemon-kubelite.service.d/override.conf\n    [Service]\n    LimitNOFILE=1048576\n    LimitNPROC=512000\n    EOF\n  - systemctl daemon-reload\n  - rm -f /var/snap/microk8s/current/var/kubernetes/backend/kine.sock\n  - chmod -R 777 /var/snap/microk8s/current/var/kubernetes/backend/\n\n  - sysctl --system\n  - ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf || true\n  - snap set system refresh.hold=forever\n\n  # - snap restart microk8s &\n\n  # - curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up --auth-key=tskey-auth-kge4UdNXv311CNTRL-DHhyKVw9DD1Aj7dqNCrpD1KZsdpQh2K32\n\n  # - curl -fsSL https://pkgs.netbird.io/install.sh | sh\n  # - netbird up --setup-key 0F6C131F-EEC5-4AAE-A253-24E55AE27688\n\n  - microk8s status --wait-ready\n "
  }

  name = "espanha0-20260822-173833"

  network_interface {
    access_config {
      network_tier = "STANDARD"
    }

    alias_ip_range {
      ip_cidr_range = "10.162.0.18/32"
    }

    alias_ip_range {
      ip_cidr_range = "10.162.0.19/32"
    }

    alias_ip_range {
      ip_cidr_range = "10.162.0.20/32"
    }

    queue_count = 0
    stack_type  = "IPV4_ONLY"
    subnetwork  = "projects/project-1ab07399-29ab-4352-8f8/regions/northamerica-northeast1/subnetworks/default"
  }

  reservation_affinity {
    type = "NO_RESERVATION"
  }

  scheduling {
    automatic_restart   = false
    on_host_maintenance = "TERMINATE"
    preemptible         = false
    provisioning_model  = "SPOT"
  }

  service_account {
    email  = "tofunix@project-1ab07399-29ab-4352-8f8.iam.gserviceaccount.com"
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_secure_boot          = false
    enable_vtpm                 = true
  }

  tags = ["espanha-ssh", "http-server", "https-server"]
  zone = "northamerica-northeast1-b"
}
