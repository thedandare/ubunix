# 1. Parâmetros Globais de Autenticação da OCI
tenancy_ocid     = "ocid1.tenancy.oc1..aaaaaaaaxt7kwgoa7hysaeimumgcplk7ofum647jr5m6dtcfnc5bsrgreefq"
user_ocid        = "ocid1.user.oc1..aaaaaaaaz2t2q4ndg3ba4bew4qyrhb7h6w3axuwnxzljlisk5zjgldwpsxia"
fingerprint      = "72:73:f9:7c:c7:ee:9f:5a:41:52:a0:13:4f:95:dc:3a"
private_key_path = "/etc/nixos/secret/oci_api_key.pem"

# 2. Travamento Geográfico (Região de São Paulo)
region              = "sa-saopaulo-1"
availability_domain = "xZsm:SA-SAOPAULO-1-AD-1" # ID do data center físico em SP (GRU)

# 3. Compartment (sera criado pelo OpenTofu)
compartment_name        = "ocinix"
compartment_description = "Compartment declarativo para o host ocinix"

# 4. Rede declarativa
vcn_cidr         = "10.0.0.0/16"
vcn_display_name = "ocinix-vcn"
vcn_dns_label    = "ocinixvcn"
subnet_cidr      = "10.0.1.0/24"
subnet_dns_label = "ocinixsub"

# 5. Imagem Ubuntu
image_id = "ocid1.image.oc1.sa-saopaulo-1.aaaaaaaakvwmxajgkw5qcdsfyvzrx7q6btz6wz52npxstonpnd3cuxu4p65q"

# 6. Acesso Remoto
ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMGWvbEP/E0dh/xwtUVIuQrNDSz+G4TCLA+UMVpT0gLi root@ali"
