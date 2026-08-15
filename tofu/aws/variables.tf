variable "aws_region" {
  type    = string
  default = "us-east-2"
}

variable "node_count" {
  type    = number
  default = 2
}

variable "name" {
  type    = string
  default = "nixos-opentofu-incus-v3"
}


# Variáveis AWS
#variable "aws_subnet_id" { type = string }
#variable "aws_key_name" { type = string }

variable "nixos_ami_name_filter" {
  type    = string
  default = "nixos/26.05*"
}

variable "instance_type" {
  type    = string
  default = "t3a.medium"
}

variable "root_volume_size" {
  type    = number
  default = 30
}

variable "ssh_port" {
  type    = number
  default = 2409
}

variable "ssh_cidr_blocks" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "ssh_public_key_files" {
  type = list(string)
  default = [
    "/home/leo/.ssh/id_ed25519.pub",
    "/home/leo/.ssh/root_id_ed25519.pub",
    "/home/leo/.ssh/tdd_id_ed25519.pub",
    "/home/leo/.ssh/leo.ssh.pub"
  ]
}

variable "extra_ssh_public_keys" {
  type = list(string)
  default = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICs+sOj/1GK5exkDkCw7H7zmDapshfWaRn474qxZxSUY leo",
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO4x8pXKybfzCbc6IAd+HoPMW4vy3vT6ByGHM3uz4ApN leo@ali",
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMGWvbEP/E0dh/xwtUVIuQrNDSz+G4TCLA+UMVpT0gLi root@ali",
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlCOf70p6jujZf6ZdE7ugOQAPtpqteigxxaQb4RONs4 thedandare@gmail.com"
  ]
}

variable "repo_url" {
  type    = string
  default = "https://github.com/thedandare/nixos.git"
}

variable "repo_ref" {
  type    = string
  default = "main"
}

# ATENCAO: valores passados via user_data podem aparecer no state e no console da instancia.
# Para laboratorio tudo bem. Para producao, trocar por SSM/Secrets Manager ou Tailscale auth key curta.
variable "tailscale_client_id" {
  type      = string
  default   = "kxixTezVgB21CNTRL"
  sensitive = true
}

variable "tailscale_client_secret" {
  type      = string
  default   = "tskey-client-kxixTezVgB21CNTRL-jiN4D8nU7sbYCg1vcCtWrb1nA2D4gRCa"
  sensitive = true
}

variable "enable_bootstrap_switch" {
  type    = bool
  default = true
}

variable "enable_spot_instances" {
  type    = bool
  default = true
}

# Vazio ("") = usa o preco on-demand atual como teto (comportamento padrao da AWS).
variable "spot_max_price" {
  type    = string
  default = ""
}

# "terminate" (padrao), "stop" ou "hibernate".
# "stop" preserva o disco quando a instancia e preemptada (recomendado).
# "terminate" apaga a instancia e o disco (nao recomendado para dados importantes).
variable "spot_instance_interruption_behavior" {
  type    = string
  default = "stop"
}
