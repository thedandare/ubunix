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

data "google_compute_zones" "available" {
  region = var.region
  status = "UP"
}

locals {
  zones = length(data.google_compute_zones.available.names) > 0 ? data.google_compute_zones.available.names : [var.zone]

  ssh_public_key = var.ssh_public_key != "" ? var.ssh_public_key : (
    var.ssh_public_key_file != "" ? try(trimspace(file(var.ssh_public_key_file)), "") : ""
  )

  metadata = merge(
    {
      enable-oslogin         = var.enable_oslogin ? "TRUE" : "FALSE"
      block-project-ssh-keys = "TRUE"
      serial-port-enable     = "TRUE"
    },
    var.enable_oslogin ? {} : { ssh-keys = "${var.ssh_user}:${local.ssh_public_key}" },
  )
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
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "${var.name}-allow-ssh"
  network = google_compute_network.nixos.name

  direction     = "INGRESS"
  source_ranges = var.ssh_source_ranges
  target_tags   = var.tags

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
  target_tags   = var.tags

  allow {
    protocol = "icmp"
  }
}

resource "google_compute_address" "nixos" {
  count        = var.assign_public_ip && var.reserve_static_ip ? var.node_count : 0
  name         = "${var.name}${count.index}-ip"
  region       = var.region
  network_tier = var.network_tier
}

resource "google_compute_instance" "nixos" {
  count        = var.node_count
  name         = "${var.name}${count.index}"
  machine_type = var.machine_type
  zone         = element(local.zones, count.index)

  tags = var.tags

  boot_disk {
    auto_delete = var.boot_disk_auto_delete

    initialize_params {
      image = var.nixos_image_self_link
      size  = var.boot_disk_size_gb
      type  = var.boot_disk_type
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.nixos.id

    dynamic "access_config" {
      for_each = var.assign_public_ip ? [1] : []
      content {
        nat_ip       = var.reserve_static_ip ? google_compute_address.nixos[count.index].address : null
        network_tier = var.network_tier
      }
    }
  }

  scheduling {
    preemptible                 = var.preemptible
    provisioning_model          = var.preemptible ? "SPOT" : "STANDARD"
    automatic_restart           = !var.preemptible
    on_host_maintenance         = var.preemptible ? "TERMINATE" : "MIGRATE"
    instance_termination_action = var.preemptible ? var.spot_termination_action : null
  }

  metadata = local.metadata

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
      condition     = var.enable_oslogin || local.ssh_public_key != ""
      error_message = "Informe ssh_public_key ou ssh_public_key_file (ou habilite enable_oslogin)."
    }
  }

  depends_on = [
    google_compute_firewall.allow_ssh,
  ]
}

output "instance_names" {
  value = google_compute_instance.nixos[*].name
}

output "zones" {
  value = google_compute_instance.nixos[*].zone
}

output "public_ips" {
  value = [for inst in google_compute_instance.nixos : try(inst.network_interface[0].access_config[0].nat_ip, null)]
}

output "ssh_hints" {
  value = [
    for i, inst in google_compute_instance.nixos :
    var.enable_oslogin
    ? "gcloud compute ssh ${inst.name} --zone ${inst.zone}"
    : "ssh -p ${var.ssh_port} ${var.ssh_user}@${try(inst.network_interface[0].access_config[0].nat_ip, inst.network_interface[0].network_ip)}"
  ]
}
