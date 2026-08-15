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

resource "aws_key_pair" "nixos" {
  key_name   = "${var.name}-key"
  public_key = local.ssh_public_keys[0]

  tags = {
    Name = "${var.name}-key"
  }
}

resource "aws_security_group" "nixos" {
  name        = "${var.name}-sg"
  description = "NixOS bootstrap SSH ports"

  # Porta 22 temporaria para bootstrap e debug.
  # Remova quando a 2409 estiver validada em todos os hosts.
  ingress {
    description = "SSH default bootstrap"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_cidr_blocks
  }

  ingress {
    description = "SSH custom port"
    from_port   = var.ssh_port
    to_port     = var.ssh_port
    protocol    = "tcp"
    cidr_blocks = var.ssh_cidr_blocks
  }

  egress {
    description = "Allow outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-sg"
  }
}

# Na AMI NixOS oficial na AWS, user_data é interpretado pelo serviço amazon-init.
# count=3 cria amnix0s, amnix1s, amnix2s — cada um com seu proprio container k8s.
resource "aws_instance" "nixos_x86_64" {
  count                       = var.node_count
  ami                         = data.aws_ami.nixos_x86_64.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  key_name                    = aws_key_pair.nixos.key_name
  vpc_security_group_ids      = [aws_security_group.nixos.id]

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  dynamic "instance_market_options" {
    for_each = var.enable_spot_instances ? [1] : []
    content {
      market_type = "spot"

      spot_options {
        max_price                     = var.spot_max_price != "" ? var.spot_max_price : null
        spot_instance_type            = "persistent"
        instance_interruption_behavior = var.spot_instance_interruption_behavior
      }
    }
  }

  tags = {
    Name = "amnix${count.index}s"
  }

  user_data = base64encode(templatefile("${path.module}/user_data.nix.tftpl", {
    ssh_port            = var.ssh_port
    ssh_public_keys_nix = local.ssh_public_keys_nix
    container_name      = "amnix"
  }))
  user_data_replace_on_change = true
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
