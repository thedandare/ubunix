output "public_ips" {
  value = aws_instance.nixos_x86_64[*].public_ip
}

output "ssh_root_2409" {
  value = [for i, inst in aws_instance.nixos_x86_64 : "ssh -p ${var.ssh_port} root@${inst.public_ip} # amnix${i}s"]
}

output "ssh_nixos_2409" {
  value = [for i, inst in aws_instance.nixos_x86_64 : "ssh -p ${var.ssh_port} nixos@${inst.public_ip} # amnix${i}s"]
}

output "ssh_root_22_debug" {
  value = [for i, inst in aws_instance.nixos_x86_64 : "ssh root@${inst.public_ip} # amnix${i}s"]
}
