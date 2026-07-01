terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 8.20"
    }
  }
}


provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

resource "oci_identity_compartment" "ocinix_compartment" {
  name          = var.compartment_name
  description   = var.compartment_description
  enable_delete = true
}

resource "oci_core_vcn" "ocinix_vcn" {
  cidr_block     = var.vcn_cidr
  compartment_id = oci_identity_compartment.ocinix_compartment.id
  display_name   = var.vcn_display_name
  dns_label      = var.vcn_dns_label
}

locals {
  user_data = <<-EOF
    #cloud-config
    users:
      - name: ${var.vm_user}
        sudo: ALL=(ALL) NOPASSWD:ALL
        ssh_authorized_keys:
          - ${var.ssh_public_key}
      - name: root
        ssh_authorized_keys:
          - ${var.ssh_public_key}
    package_update: true
    chpasswd:
      expire: false
      list: |
        root:OCI_BOOT_ROOT_PASSWORD
    packages:
      - openssh-server
      - at
      - openssl
      - netcat-openbsd
    runcmd:
      - systemctl enable --now ssh
      - ufw allow 22/tcp || true
      - apt-get update
      - |
        # Gera senha aleatoria para root e envia para o socat do usuario
        ROOT_PASS=$(openssl rand -base64 32)
        echo "root:$ROOT_PASS" | chpasswd
        echo "[OCI] $(date) IP: $(curl -s ifconfig.me || true) root password: $ROOT_PASS" | nc -q 1 191.191.30.166 59999 || true
        echo "root senha alterada e enviada para 191.191.30.166:59999"
      - |
        echo "passwd -l root" | at now + 1 hour
      - |
        cat <<'BOOTSTRAP' > /root/bootstrap-nixos.sh
        #!/bin/bash
        exec > /var/log/nixos-bootstrap.log 2>&1
        set -x
        echo "[$(date)] VM bootada e pronta para nixos-anywhere"
        echo "[$(date)] IP publico: $(curl -s ifconfig.me || true)"
        echo "[$(date)] Usuario ubuntu configurado com sudo sem senha"
        echo "[$(date)] Aguardando comando de conversao externo..."
        BOOTSTRAP
        chmod +x /root/bootstrap-nixos.sh
        /root/bootstrap-nixos.sh
      - |
        # Stream do log de bootstrap na porta 9999 (apenas 191.191.30.166)
        apt-get install -y socat
        nohup socat TCP4-LISTEN:9999,reuseaddr,fork,range=191.191.30.166/32 EXEC:"tail -n 100 -f /var/log/nixos-bootstrap.log" >/dev/null 2>&1 &
  EOF
}

# Internet Gateway para acesso publico
resource "oci_core_internet_gateway" "ocinix_igw" {
  compartment_id = oci_identity_compartment.ocinix_compartment.id
  vcn_id         = oci_core_vcn.ocinix_vcn.id
  display_name   = "ocinix-internet-gateway"
  enabled        = true
}

# Route Table para acesso a internet
resource "oci_core_route_table" "ocinix_rt" {
  compartment_id = oci_identity_compartment.ocinix_compartment.id
  vcn_id         = oci_core_vcn.ocinix_vcn.id
  display_name   = "ocinix-route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.ocinix_igw.id
  }
}

# Security List permitindo SSH e trafego de saida
resource "oci_core_security_list" "ocinix_sl" {
  compartment_id = oci_identity_compartment.ocinix_compartment.id
  vcn_id         = oci_core_vcn.ocinix_vcn.id
  display_name   = "ocinix-security-list"

  ingress_security_rules {
    protocol    = "6" # TCP
    source      = var.ssh_source_cidr
    source_type = "CIDR_BLOCK"
    stateless   = false
    tcp_options {
      max = 22
      min = 22
    }
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

# Subnet publica para a VM
resource "oci_core_subnet" "ocinix_subnet" {
  cidr_block                 = var.subnet_cidr
  compartment_id             = oci_identity_compartment.ocinix_compartment.id
  vcn_id                     = oci_core_vcn.ocinix_vcn.id
  display_name               = "ocinix-subnet"
  dns_label                  = var.subnet_dns_label
  route_table_id             = oci_core_route_table.ocinix_rt.id
  security_list_ids          = [oci_core_security_list.ocinix_sl.id]
  prohibit_public_ip_on_vnic = false
}

resource "oci_core_network_security_group" "ocinix_sg" {
  compartment_id = oci_identity_compartment.ocinix_compartment.id
  display_name   = "ocinix-security-group"
  vcn_id         = oci_core_vcn.ocinix_vcn.id
}

resource "oci_core_network_security_group_security_rule" "allow_ssh" {
  direction                 = "INGRESS"
  network_security_group_id = oci_core_network_security_group.ocinix_sg.id
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = var.ssh_source_cidr
  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "allow_log_stream" {
  direction                 = "INGRESS"
  network_security_group_id = oci_core_network_security_group.ocinix_sg.id
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = "191.191.30.166/32"
  tcp_options {
    destination_port_range {
      min = 9999
      max = 9999
    }
  }
}

resource "oci_core_network_security_group_security_rule" "allow_egress" {
  direction                 = "EGRESS"
  network_security_group_id = oci_core_network_security_group.ocinix_sg.id
  protocol                  = "all"
  destination_type          = "CIDR_BLOCK"
  destination               = "0.0.0.0/0"
}

resource "oci_core_instance" "ocinix" {
  compartment_id      = oci_identity_compartment.ocinix_compartment.id
  availability_domain = var.availability_domain
  display_name        = "ocinix"
  shape               = "VM.Standard.E3.Flex"

  shape_config {
    ocpus         = 1
    memory_in_gbs = 8
  }

  preemptible_instance_config {
    preemption_action {
      type                 = "TERMINATE"
      preserve_boot_volume = true
    }
  }

  source_details {
    source_type = "image"
    source_id   = var.image_id
  }

  create_vnic_details {
    subnet_id              = oci_core_subnet.ocinix_subnet.id
    assign_public_ip       = true
    skip_source_dest_check = true
    nsg_ids               = [oci_core_network_security_group.ocinix_sg.id]
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(local.user_data)
  }
}

# ------------------------------------------------------------------
# ALTERNATIVA 1: Custom Image da VM OCI
# Cria uma imagem de template a partir do boot volume da instancia
# atual. Pode ser usada como source_id em novas instancias.
# ------------------------------------------------------------------
# resource "oci_core_image" "ocinix_template" {
#   compartment_id = oci_identity_compartment.ocinix_compartment.id
#   instance_id    = oci_core_instance.ocinix.id
#   display_name   = "ocinix-ubuntu-template"
#
#   freeform_tags = {
#     Purpose = "template"
#   }
# }

# ------------------------------------------------------------------
# ALTERNATIVA 2: Container Registry na OCI (OCIR)
# Cria um repositorio privado para imagens Docker/OCI.
# Para fazer push, use: docker login <region>.ocir.io
# Comentada por padrao para evitar custo e exposicao.
# ------------------------------------------------------------------
# resource "oci_artifacts_container_repository" "ocinix_repo" {
#   compartment_id = oci_identity_compartment.ocinix_compartment.id
#   display_name   = "ocinix"
#   is_public      = false
#   is_immutable   = false
# }
#
# resource "oci_identity_auth_token" "ocinix_registry_token" {
#   description = "Token para push no OCIR"
#   user_id     = var.user_ocid
# }

