terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

locals {
  # Junta chaves publicas lidas de arquivos locais com chaves literais opcionais.
  ssh_public_keys = compact(concat(
    [for p in var.ssh_public_key_files : try(trimspace(file(p)), "")],
    var.extra_ssh_public_keys
  ))

  # Para metadata SSH do GCE, o formato e: usuario:ssh-ed25519 AAAA... comentario
  # Isso so e usado quando enable_oslogin=false. Com OS Login ligado, metadata ssh-keys e ignorado.
  metadata_ssh_keys = join("\n", [
    for key in local.ssh_public_keys : "${var.ssh_user}:${key}"
  ])

  network_tag         = "${var.name}-ssh"
  nixos_image_project = var.nixos_image_project != "" ? var.nixos_image_project : var.project_id
  nixos_source_image  = var.nixos_image_self_link != "" ? var.nixos_image_self_link : data.google_compute_image.nixos[0].self_link

  instance_metadata = merge(
    {
      # A imagem NixOS para GCE recente espera OS Login para acesso via console/gcloud.
      # Se voce embutir usuarios/chaves na imagem e quiser SSH classico, coloque false no tfvars.
      enable-oslogin         = var.enable_oslogin ? "TRUE" : "FALSE"
      block-project-ssh-keys = "TRUE"
      serial-port-enable     = "TRUE"
      enable-oslogin = "TRUE"

      # Spot pode ser preemptada. Este script apenas deixa rastro no journal/serial console.
      # A persistencia real deve estar no NixOS/servicos, nao no Terraform.
      shutdown-script = <<-SCRIPT
        #!/usr/bin/env bash
        set -euo pipefail
        echo "[gce-spot] shutdown/preemption notice at $(date --iso-8601=seconds)" | systemd-cat -t gce-spot-shutdown || true
        sync || true
      SCRIPT
    },
    var.enable_oslogin ? {} : { ssh-keys = local.metadata_ssh_keys },
    var.extra_metadata
  )
}

data "google_compute_image" "nixos" {
  count   = var.nixos_image_self_link == "" ? 1 : 0
  project = local.nixos_image_project
  family  = var.nixos_image_family
}

# Opcional, mas conveniente: registra suas chaves locais no OS Login do usuario autenticado
# pelo Application Default Credentials. So roda se enable_oslogin=true e manage_oslogin_keys=true.
data "google_client_openid_userinfo" "me" {
  count = var.enable_oslogin && var.manage_oslogin_keys ? 1 : 0
}

resource "google_os_login_ssh_public_key" "current_user" {
  for_each = var.enable_oslogin && var.manage_oslogin_keys ? {
    for idx, key in local.ssh_public_keys : tostring(idx) => key
  } : {}

  user = data.google_client_openid_userinfo.me[0].email
  key  = each.value
}

resource "google_compute_network" "nixos" {
  name                    = "${var.name}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "nixos" {
  name          = "${var.name}-subnet"
  region        = var.region
  network       = google_compute_network.nixos.id
  ip_cidr_range = var.subnet_cidr

  private_ip_google_access = true
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "${var.name}-allow-ssh"
  network = google_compute_network.nixos.name

  direction     = "INGRESS"
  source_ranges = var.ssh_source_ranges
  target_tags   = [local.network_tag]

  allow {
    protocol = "tcp"
    ports    = distinct(concat(["22"], [tostring(var.ssh_port)]))
  }
}

resource "google_compute_firewall" "allow_icmp" {
  count   = var.allow_icmp ? 1 : 0
  name    = "${var.name}-allow-icmp"
  network = google_compute_network.nixos.name

  direction     = "INGRESS"
  source_ranges = var.ssh_source_ranges
  target_tags   = [local.network_tag]

  allow {
    protocol = "icmp"
  }
}

resource "google_compute_address" "nixos" {
  count  = var.assign_public_ip && var.reserve_static_ip ? 1 : 0
  name   = "${var.name}-ip"
  region = var.region
}

resource "google_compute_instance" "nixos" {
  name         = var.name
  machine_type = var.machine_type
  zone         = var.zone

  tags = [local.network_tag]

  # Importante para Incus/Kubernetes/roteamento entre bridges, caso voce use sub-redes atras da VM.
  can_ip_forward = var.can_ip_forward

  allow_stopping_for_update = true

  boot_disk {
    auto_delete = var.boot_disk_auto_delete

    initialize_params {
      image = local.nixos_source_image
      size  = var.boot_disk_size_gb
      type  = var.boot_disk_type
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.nixos.id

    dynamic "access_config" {
      for_each = var.assign_public_ip ? [1] : []
      content {
        nat_ip       = var.reserve_static_ip ? google_compute_address.nixos[0].address : null
        network_tier = var.network_tier
      }
    }
  }

  scheduling {
    provisioning_model          = "SPOT"
    preemptible                 = true
    automatic_restart           = false
    on_host_maintenance         = "TERMINATE"
    instance_termination_action = var.spot_termination_action
  }

  shielded_instance_config {
    # Imagem NixOS custom com kernel recente pode nao estar assinada para Secure Boot.
    # Deixe false ate validar a imagem; vTPM/integrity continuam ligados por padrao.
    enable_secure_boot          = var.enable_secure_boot
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = local.instance_metadata

  dynamic "service_account" {
    for_each = var.service_account_email == "" ? [] : [1]
    content {
      email  = var.service_account_email
      scopes = var.service_account_scopes
    }
  }

  labels = var.labels

  lifecycle {
    precondition {
      condition     = var.nixos_image_self_link != "" || var.nixos_image_family != ""
      error_message = "Informe nixos_image_self_link ou nixos_image_family/nixos_image_project para achar a imagem NixOS custom no GCE."
    }
  }

  depends_on = [
    google_compute_firewall.allow_ssh,
    google_os_login_ssh_public_key.current_user
  ]
}

output "instance_name" {
  value = google_compute_instance.nixos.name
}

output "zone" {
  value = google_compute_instance.nixos.zone
}

output "public_ip" {
  value = try(google_compute_instance.nixos.network_interface[0].access_config[0].nat_ip, null)
}

output "internal_ip" {
  value = google_compute_instance.nixos.network_interface[0].network_ip
}

output "ssh_hint" {
  value = var.enable_oslogin ? "gcloud compute ssh ${google_compute_instance.nixos.name} --zone ${var.zone}" : "ssh -p ${var.ssh_port} ${var.ssh_user}@${try(google_compute_instance.nixos.network_interface[0].access_config[0].nat_ip, google_compute_instance.nixos.network_interface[0].network_ip)}"
}
