output "spot_fleet_id" {
  value       = aws_spot_fleet_request.nixos_spot_fleet.id
  description = "ID do spot fleet request"
}

output "spot_fleet_request_state" {
  value       = aws_spot_fleet_request.nixos_spot_fleet.spot_request_state
  description = "Estado do spot fleet request"
}# ====================================================================
# RECURSOS DO EFS (COLE NO FINAL DO SEU OUTPUTS.TF)
# ====================================================================

resource "aws_efs_file_system" "shared" {
  encrypted                       = var.efs_encrypted
  performance_mode                = var.efs_performance_mode
  throughput_mode                 = var.efs_throughput_mode
  provisioned_throughput_in_mibps = var.efs_throughput_mode == "provisioned" ? var.efs_provisioned_throughput : null
  tags = {
    Name = "microk8s-efs-storage"
  }
  lifecycle {
    prevent_destroy = true 
  }
}

resource "aws_security_group" "efs" {
   name        = "nixos-opentofu-incus-v3-efs-fd0ff9847f5c76adb8f4ddca32" # 👈 Cole o nome antigo exatamente igual
  description = "Managed by Terraform" # 👈 Volte para a descrição antiga
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = var.efs_allowed_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

    lifecycle {
    create_before_destroy = true  
  }
}

data "aws_subnets" "selected" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
}

#resource "aws_efs_mount_target" "shared" {
#  for_each        = toset(data.aws_subnets.selected.ids)
#  file_system_id  = aws_efs_file_system.shared.id
#  subnet_id       = each.value
#  security_groups = [aws_security_group.efs.id]
#}

# ====================================================================
# OUTPUTS DO EFS (VERIFIQUE SE ESTÃO DUPLICADOS ACIMA E SUBSTITUA)
# ====================================================================

output "efs_file_system_id" {
  value       = aws_efs_file_system.shared.id
  description = "ID do sistema de arquivos EFS"
}

output "efs_dns_name" {
  value       = aws_efs_file_system.shared.dns_name
  description = "Nome DNS do EFS"
}

#output "efs_mount_target_ids" {
#  value       = [for target in aws_efs_mount_target.shared : target.id]
#  description = "IDs dos mount targets do EFS"
#}
