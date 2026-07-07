output "public_ip" {
  description = "IP público da instância OCI"
  value       = oci_core_instance.ocinix.public_ip
}

output "instance_name" {
  description = "Nome da instância"
  value       = oci_core_instance.ocinix.display_name
}

output "ssh_root_22_debug" {
  value = "\nssh -i /root/.ssh/root_id_ed25519 root@${oci_core_instance.ocinix.public_ip}\n"
}