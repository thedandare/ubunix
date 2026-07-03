# Exemplo: criar uma AMI a partir da instancia atual para clonar VMs na AWS.
# A AMI eh gerada a partir do root volume da instancia aws_instance.nixos_x86_64.

resource "aws_ami_from_instance" "nixos_template" {
  name               = "nixos-template"
  source_instance_id = aws_instance.nixos_x86_64.id
  snapshot_without_reboot = false

  tags = {
    Name = "nixos-template"
  }
}

# Exemplo: usar a AMI customizada em uma nova instancia.
# Descomente e ajuste conforme necessario.
#
# resource "aws_instance" "nixos_clone" {
#   ami                         = aws_ami_from_instance.nixos_template.id
#   instance_type               = var.instance_type
#   associate_public_ip_address = true
#   key_name                    = aws_key_pair.nixos.key_name
#   vpc_security_group_ids      = [aws_security_group.nixos.id]
#
#   root_block_device {
#     volume_size = var.root_volume_size
#     volume_type = "gp3"
#   }
#
#   tags = {
#     Name = "${var.name}-clone"
#   }
# }
