terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  # Junta chaves publicas lidas de arquivos locais com chaves literais opcionais.
  ssh_public_keys = compact(concat(
    [for p in var.ssh_public_key_files : try(trimspace(file(p)), "")],
    var.extra_ssh_public_keys
  ))

  # Converte lista Terraform em lista Nix.
  ssh_public_keys_nix = join("\n    ", [
    for key in local.ssh_public_keys : "\"${key}\""
  ])

}

data "aws_ami" "nixos_x86_64" {
  owners      = ["427812963091"]
  most_recent = true

  filter {
    name   = "name"
    values = [var.nixos_ami_name_filter]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

#resource "aws_key_pair" "nixos" {
#  key_name   = "${var.name}-key"
#  public_key = local.ssh_public_keys[0]

  #tags = {
  #  Name = "${var.name}-key"
  #}
#}

resource "aws_iam_role" "spot_fleet_role" {
  name = "${var.name}-spot-fleet-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "spotfleet.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "spot_fleet_role_policy" {
  role       = aws_iam_role.spot_fleet_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetTaggingRole"
}

#resource "aws_security_group" "nixos" {
#  name        = "${var.name}-sg"
#  description = "NixOS bootstrap SSH ports"
#
#  ingress {
#    description = "SSH default bootstrap"
#    from_port   = 22
#    to_port     = 22
#    protocol    = "tcp"
#    cidr_blocks = var.ssh_cidr_blocks
#  }
#
#  ingress {
#    description = "SSH custom port"
#    from_port   = var.ssh_port
#    to_port     = var.ssh_port
#    protocol    = "tcp"
#    cidr_blocks = var.ssh_cidr_blocks
#  }
#
#  ingress {
#    description = "MicroK8s join port (entre nodes do cluster)"
#    from_port   = 25000
#    to_port     = 25000
#    protocol    = "tcp"
#    cidr_blocks = ["0.0.0.0/0"]
#  }
#
#  egress {
#    description = "Allow outbound"
#    from_port   = 0
#    to_port     = 0
#    protocol    = "-1"
#    cidr_blocks = ["0.0.0.0/0"]
#  }
#
#  tags = {
#    Name = "${var.name}-sg"
#  }
#}

# Na AMI NixOS oficial na AWS, user_data é interpretado pelo serviço amazon-init.
# Spot fleet gerencia automaticamente as instâncias spot.
resource "aws_launch_template" "nixos" {
  name_prefix   = "${var.name}-"
  image_id      = data.aws_ami.nixos_x86_64.id
  #key_name      = aws_key_pair.nixos.key_name
  instance_type = var.instance_type

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [ aws_security_group.efs.id]
  }
# aws_security_group.nixos.id,

  user_data = base64encode(templatefile("${path.module}/user_data.nix.tftpl", {
    ssh_port            = var.ssh_port
    ssh_public_keys_nix = local.ssh_public_keys_nix
    container_name      = "amnix"
    efs_dns_name        = aws_efs_file_system.shared.dns_name
    efs_mount_point     = var.efs_mount_point
          }))

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "amnix"
    }
  }
}

resource "aws_spot_fleet_request" "nixos_spot_fleet" {
  iam_fleet_role                      = aws_iam_role.spot_fleet_role.arn
  allocation_strategy                 = "priceCapacityOptimized"
  target_capacity                     = var.node_count
  #valid_until                         = timeadd(timestamp(), "8760h") # 1 ano
  terminate_instances_with_expiration = true
  fleet_type                          = "maintain"
  lifecycle {
    ignore_changes = [
      valid_until,
      valid_from
    ]
  }
  launch_template_config {
    launch_template_specification {
      version = "$Latest"
      id = aws_launch_template.nixos.id
    }

    overrides {
      subnet_id = var.subnet_ids[0]
    }
  }

  tags = {
    Name = "${var.name}-spot-fleet"
  }
}


# ------------------------------------------------------------------
# ALTERNATIVA 1: AMI customizada a partir da instancia atual
# Cria uma AMI de template para clonar a VM NixOS.
# Comentada por padrao para nao gerar snapshot/custo inesperado.
# ------------------------------------------------------------------
# resource "aws_ami_from_instance" "nixos_template" {
#   name                    = "nixos-template"
#   source_instance_id      = aws_instance.nixos_x86_64.id
#   snapshot_without_reboot = false
#
#   tags = {
#     Name = "nixos-template"
#   }
# }

# ------------------------------------------------------------------
# ALTERNATIVA 2: Container Registry na AWS (ECR)
# Cria um repositorio privado para imagens Docker/OCI.
# Comentada por padrao para evitar custo e exposicao.
# ------------------------------------------------------------------
 # data "aws_caller_identity" "current" {}
 #
 # resource "aws_ecr_repository" "nixos_repo" {
 #   name                 = "nixos"
 #   image_tag_mutability = "MUTABLE"
 #
 #   image_scanning_configuration {
 #     scan_on_push = false
 #   }
 #
 #   tags = {
 #     Name = "nixos"
 #   }
 # }
 #
 # resource "aws_ecr_repository_policy" "nixos_repo_policy" {
 #   repository = aws_ecr_repository.nixos_repo.name
 #
 #   policy = jsonencode({
 #     Version = "2012-10-17"
 #     Statement = [
 #       {
 #         Sid    = "AllowPushPull"
 #         Effect = "Allow"
 #         Principal = {
 #           AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
 #         }
 #         Action = [
 #           "ecr:BatchCheckLayerAvailability",
 #           "ecr:BatchGetImage",
 #           "ecr:CompleteLayerUpload",
 #           "ecr:GetDownloadUrlForLayer",
 #           "ecr:InitiateLayerUpload",
 #           "ecr:PutImage",
 #           "ecr:UploadLayerPart"
 #         ]
 #       }
 #     ]
 #   })
 # }
