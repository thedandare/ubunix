# Copie para terraform.tfvars se quiser sobrescrever.
# Nao commitar terraform.tfvars com segredo.

name = "nixos-opentofu-incus-v3"
aws_region = "us-east-2"
instance_type = "t3a.medium"
root_volume_size = 30
ssh_port = 2409
node_count = 2

# Para restringir ao seu IP depois:
# ssh_cidr_blocks = ["SEU_IP/32"]
ssh_cidr_blocks = ["0.0.0.0/0"]

ssh_public_key_files = [
  "~/.ssh/id_ed25519.pub",
  "~/.ssh/root_id_ed25519.pub",
  "~/.ssh/tdd_id_ed25519.pub",
  "~/.ssh/leo.ssh.pub"
]

repo_url = "https://github.com/thedandare/nixos.git"
repo_ref = "main"

# Comportamento de preempção de spot instances
# "stop" = para a instancia mas preserva o disco (recomendado)
# "terminate" = apaga instancia e disco (nao recomendado)
spot_instance_interruption_behavior = "stop"

# Melhor usar export TF_VAR_tailscale_client_id e TF_VAR_tailscale_client_secret.
# tailscale_client_id = ""
# tailscale_client_secret = ""
