# Exemplo: criar uma Custom Image a partir da VM atual para clonar instancias.
# A imagem eh gerada a partir do boot volume da instancia oci_core_instance.ocinix.

resource "oci_core_image" "ocinix_template" {
  compartment_id = oci_identity_compartment.ocinix_compartment.id
  instance_id    = oci_core_instance.ocinix.id
  display_name   = "ocinix-ubuntu-template"

  freeform_tags = {
    Purpose = "template"
  }
}

# Exemplo: usar a imagem customizada em uma nova instancia.
# Descomente e ajuste conforme necessario.
#
# resource "oci_core_instance" "ocinix_clone" {
#   compartment_id      = oci_identity_compartment.ocinix_compartment.id
#   availability_domain = var.availability_domain
#   display_name        = "ocinix-clone"
#   shape               = "VM.Standard.E3.Flex"
#
#   shape_config {
#     ocpus         = 1
#     memory_in_gbs = 8
#   }
#
#   source_details {
#     source_type = "image"
#     source_id   = oci_core_image.ocinix_template.id
#   }
#
#   create_vnic_details {
#     subnet_id        = oci_core_subnet.ocinix_subnet.id
#     assign_public_ip = true
#     nsg_ids         = [oci_core_network_security_group.ocinix_sg.id]
#   }
# }
