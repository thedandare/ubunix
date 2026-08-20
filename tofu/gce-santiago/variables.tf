variable "project_id" {
  description = "ID do projeto GCP."
  type        = string
  default     = "project-1ab07399-29ab-4352-8f8"
}

variable "region" {
  description = "Regiao GCP."
  type        = string
  default     = "southamerica-west1"
}

variable "zone" {
  description = "Zona GCP usada como fallback."
  type        = string
  default     = "southamerica-west1-a"
}

variable "name" {
  description = "Nome base da instancia e recursos."
  type        = string
  default     = "santnix"
}

variable "node_count" {
  description = "Quantidade de VMs."
  type        = number
  default     = 1
}

variable "machine_type" {
  description = "Tipo da VM."
  type        = string
  default     = "t2d-standard-1"
}

variable "nixos_image_self_link" {
  description = "Self link exato da imagem custom NixOS criada."
  type        = string
  default     = "projects/project-1ab07399-29ab-4352-8f8/global/images/nixos-26-05-k7-202608191945"
}

variable "boot_disk_size_gb" {
  description = "Tamanho do boot disk em GB."
  type        = number
  default     = 25
}

variable "boot_disk_type" {
  description = "Tipo do disco: pd-balanced, pd-ssd ou pd-standard."
  type        = string
  default     = "pd-balanced"
}

variable "boot_disk_auto_delete" {
  description = "Destruir boot disk junto com a VM."
  type        = bool
  default     = true
}

variable "subnet_cidr" {
  description = "CIDR da subnet."
  type        = string
  default     = "10.42.1.0/24"
}

variable "ssh_user" {
  description = "Usuario para acesso SSH via metadata ssh-keys."
  type        = string
  default     = "root"
}

variable "ssh_public_key" {
  description = "Chave publica literal. Deixe vazio para usar ssh_public_key_file."
  type        = string
  default     = ""
}

variable "ssh_public_key_file" {
  description = "Caminho do arquivo de chave publica. Ignorado se ssh_public_key for informada."
  type        = string
  default     = ""
}

variable "ssh_port" {
  description = "Porta SSH (a firewall abre 22 e esta porta)."
  type        = number
  default     = 2409
}

variable "ssh_source_ranges" {
  description = "CIDRs com acesso SSH e ICMP."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "assign_public_ip" {
  description = "Criar IP publico."
  type        = bool
  default     = true
}

variable "reserve_static_ip" {
  description = "Reservar IP externo estatico."
  type        = bool
  default     = false
}

variable "network_tier" {
  description = "Tier do IP publico: PREMIUM ou STANDARD."
  type        = string
  default     = "STANDARD"

  validation {
    condition     = contains(["PREMIUM", "STANDARD"], var.network_tier)
    error_message = "network_tier deve ser PREMIUM ou STANDARD."
  }
}

variable "allow_icmp" {
  description = "Permitir ICMP a partir dos CIDRs de SSH."
  type        = bool
  default     = true
}

variable "enable_oslogin" {
  description = "Usar Google OS Login em vez de metadata ssh-keys."
  type        = bool
  default     = false
}

variable "preemptible" {
  description = "Usar instancia preemptivel/spot."
  type        = bool
  default     = true
}

variable "spot_termination_action" {
  description = "Acao em caso de preempcao: STOP ou DELETE."
  type        = string
  default     = "STOP"

  validation {
    condition     = contains(["STOP", "DELETE"], var.spot_termination_action)
    error_message = "spot_termination_action deve ser STOP ou DELETE."
  }
}

variable "service_account_email" {
  description = "Service account da VM. Vazio nao declara."
  type        = string
  default     = ""
}

variable "service_account_scopes" {
  description = "Scopes da service account."
  type        = list(string)
  default     = ["https://www.googleapis.com/auth/cloud-platform"]
}

variable "tags" {
  description = "Tags de rede na VM."
  type        = list(string)
  default     = ["nixos-ssh"]
}

variable "labels" {
  description = "Labels GCP."
  type        = map(string)
  default     = { os = "nixos", pricing = "spot" }
}
