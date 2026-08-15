# Copie para terraform.tfvars se quiser sobrescrever.
# Nao commitar terraform.tfvars com segredo.

name = "nixos-opentofu-incus-v3"
aws_region = "us-east-2"
instance_type = "t3.medium"
root_volume_size = 40
ssh_port = 2409

# Para restringir ao seu IP depois:
# ssh_cidr_blocks = ["SEU_IP/32"]
ssh_cidr_blocks = ["0.0.0.0/0"]

# Subnet IDs (do terraform.tfstate existente)
subnet_ids = ["subnet-088081aeba9052d28", "subnet-0ec2a50e0a8e6d950", "subnet-0b50156da8acd1568"]

# VPC IDs por regiao (para referencia)
# us-east-2: vpc-0c04f5f2d7063b88c
# sa-east-1: vpc-0959b0cc439c3bc2d

# VPC ID atual (selecione conforme a regiao)
vpc_id = "vpc-0c04f5f2d7063b88c"

# Numero de instancias no spot fleet
node_count = 3

ssh_public_key_files = [
  "~/.ssh/id_ed25519.pub",
  "~/.ssh/root_id_ed25519.pub",
  "~/.ssh/tdd_id_ed25519.pub",
  "~/.ssh/leo.ssh.pub"
]

repo_url = "https://github.com/thedandare/nixos.git"
repo_ref = "main"

# Melhor usar export TF_VAR_tailscale_client_id e TF_VAR_tailscale_client_secret.
# tailscale_client_id = ""
# tailscale_client_secret = ""
