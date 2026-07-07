# Exemplo: criar um Container Registry privado na OCI (OCIR) para fazer push/pull
# de imagens Docker e depois rodar containers via Incus, LXD ou Docker na VM.

# Container Registry na OCI
resource "oci_artifacts_container_repository" "ocinix_repo" {
  compartment_id = oci_identity_compartment.ocinix_compartment.id
  display_name   = "ocinix"
  is_public      = false
  is_immutable   = false
}

# Auth token para o registry (sensivel - use vault/secret manager em producao)
resource "oci_identity_auth_token" "ocinix_registry_token" {
  description = "Token para push no OCIR"
  user_id     = var.user_ocid
}

# Exemplo de comandos para usar o registry:
# 1. Login:
#    docker login sa-saopaulo-1.ocir.io \
#      -u '<tenancy-namespace>/<user>' \
#      -p '<auth-token>'
#
# 2. Tag:
#    docker tag minha-imagem:latest \
#      sa-saopaulo-1.ocir.io/<tenancy-namespace>/ocinix/minha-imagem:latest
#
# 3. Push:
#    docker push sa-saopaulo-1.ocir.io/<tenancy-namespace>/ocinix/minha-imagem:latest
#
# 4. Pull/Incus:
#    incus image copy images:ubuntu/24.04 local: --alias ubuntu-24.04
#    ou, se for imagem OCI, use o Incus com remote do registry.
