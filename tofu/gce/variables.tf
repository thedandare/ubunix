variable "project_id" {
  description = "fibodevop"
  type        = string
}

variable "region" {
  description = "Regiao GCP. Sao Paulo e southamerica-east1."
  type        = string
  default     = "southamerica-east1"
}

variable "zone" {
  description = "Zona GCP. Confirme capacidade Spot para o machine_type escolhido."
  type        = string
  default     = "southamerica-east1-b"
}

variable "name" {
  description = "Nome base da VM e dos recursos de rede."
  type        = string
  default     = "gcnix"
}

variable "machine_type" {
  description = "Tipo da instancia. Para Incus/MicroK8s, comece com pelo menos e2-standard-2 ou maior."
  type        = string
  default     = "e2-standard-2"
}

variable "subnet_cidr" {
  description = "CIDR da subnet criada para a VM."
  type        = string
  default     = "10.42.0.0/24"
}

variable "nixos_image_project" {
  description = "Projeto que contem a imagem custom do NixOS. Vazio usa project_id."
  type        = string
  default     = ""
}

variable "nixos_image_family" {
  description = "Familia da imagem custom NixOS criada no GCE, por exemplo nixos-26-05-k7. Ignorado se nixos_image_self_link for informado."
  type        = string
  default     = "nixos-26-05-k7"
}

variable "nixos_image_self_link" {
  description = "Self link de uma imagem GCE especifica. Use para pin exato/reproducivel. Se vazio, usa image_family."
  type        = string
  default     = ""
}

variable "boot_disk_size_gb" {
  description = "Tamanho do boot disk em GB."
  type        = number
  default     = 60
}

variable "boot_disk_type" {
  description = "Tipo do disco: pd-balanced, pd-ssd ou pd-standard."
  type        = string
  default     = "pd-balanced"
}

variable "boot_disk_auto_delete" {
  description = "Se true, destroi o boot disk ao destruir a VM. Para Spot com dados importantes, use false."
  type        = bool
  default     = false
}

variable "spot_termination_action" {
  description = "Acao quando a Spot for preemptada: STOP preserva disco/estado da VM; DELETE apaga a VM."
  type        = string
  default     = "STOP"

  validation {
    condition     = contains(["STOP", "DELETE"], var.spot_termination_action)
    error_message = "spot_termination_action deve ser STOP ou DELETE."
  }
}

variable "assign_public_ip" {
  description = "Se true, cria IP publico na interface."
  type        = bool
  default     = true
}

variable "reserve_static_ip" {
  description = "Se true, reserva IP regional estatico. Para Spot com STOP costuma ser conveniente."
  type        = bool
  default     = true
}

variable "network_tier" {
  description = "Network tier do IP publico: PREMIUM ou STANDARD."
  type        = string
  default     = "STANDARD"
}

variable "ssh_port" {
  description = "Porta SSH custom que sua imagem NixOS deve abrir declarativamente. A firewall abre 22 e esta porta."
  type        = number
  default     = 2409
}

variable "ssh_source_ranges" {
  description = "CIDRs autorizados a entrar por SSH. Troque 0.0.0.0/0 pelo seu IP sempre que possivel."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_user" {
  description = "Usuario usado em metadata ssh-keys quando enable_oslogin=false."
  type        = string
  default     = "leo"
}

variable "ssh_public_key_files" {
  description = "Arquivos locais de chaves publicas a registrar no OS Login ou metadata SSH. Arquivos ausentes sao ignorados."
  type        = list(string)
  default = [
    "/home/leo/.ssh/id_ed25519.pub",
    "/home/leo/.ssh/root_id_ed25519.pub",
    "/home/leo/.ssh/tdd_id_ed25519.pub",
    "/home/leo/.ssh/leo.ssh.pub"
  ]
}

variable "extra_ssh_public_keys" {
  description = "Chaves publicas literais adicionais. Nao coloque chaves privadas aqui."
  type        = list(string)
  default     = []
}

variable "enable_oslogin" {
  description = "Liga Google OS Login. Recomendado para imagens NixOS GCE recentes. Se false, usa metadata ssh-keys classico."
  type        = bool
  default     = true
}

variable "manage_oslogin_keys" {
  description = "Se true, cadastra as chaves locais no OS Login do usuario autenticado pelo gcloud ADC."
  type        = bool
  default     = true
}

variable "allow_icmp" {
  description = "Permite ICMP/ping a partir dos mesmos CIDRs do SSH."
  type        = bool
  default     = true
}

variable "can_ip_forward" {
  description = "Habilita IP forwarding na NIC da VM, util para roteamento/bridges Incus/Kubernetes."
  type        = bool
  default     = true
}

variable "enable_secure_boot" {
  description = "Secure Boot. Deixe false ate confirmar que sua imagem NixOS custom esta assinada/compativel."
  type        = bool
  default     = false
}

variable "service_account_email" {
  description = "Service Account da VM. Vazio nao declara bloco service_account."
  type        = string
  default     = "tofunix@project-1ab07399-29ab-4352-8f8.iam.gserviceaccount.com"
}

variable "service_account_scopes" {
  description = "Scopes da service account, usados apenas quando service_account_email nao esta vazio."
  type        = list(string)
  default     = ["https://www.googleapis.com/auth/cloud-platform"]
}

variable "extra_metadata" {
  description = "Metadata extra para a instancia GCE."
  type        = map(string)
  default     = {}
}

variable "labels" {
  description = "Labels GCP para a VM."
  type        = map(string)
  default = {
    os      = "nixos"
    pricing = "spot"
  }
}
