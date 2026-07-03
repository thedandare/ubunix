# Variáveis OCI
variable "tenancy_ocid" { type = string }
variable "user_ocid" { type = string }
variable "fingerprint" { type = string }
variable "private_key_path" { type = string }
variable "region" { type = string }
variable "availability_domain" { type = string }

# Compartment
variable "compartment_name" { type = string }
variable "compartment_description" { type = string }

# Rede declarativa
variable "vcn_cidr" { type = string }
variable "vcn_display_name" { type = string }
variable "vcn_dns_label" { type = string }
variable "subnet_cidr" { type = string }
variable "subnet_dns_label" { type = string }

# Imagem e acesso
variable "image_id" { type = string }
variable "ssh_public_key" { type = string }
variable "ssh_source_cidr" {
  type    = string
  default = "0.0.0.0/0"
}
variable "vm_user" {
  type    = string
  default = "ubuntu"
}