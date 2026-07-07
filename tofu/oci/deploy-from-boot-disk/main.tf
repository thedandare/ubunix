provider "oci" {}

resource "oci_core_instance" "generated_oci_core_instance" {
	agent_config {
		is_management_disabled = "false"
		is_monitoring_disabled = "false"
		plugins_config {
			desired_state = "DISABLED"
			name = "Vulnerability Scanning"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "OS Management Hub Agent"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "Management Agent"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "Custom Logs Monitoring"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "Compute RDMA GPU Monitoring"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "Compute Instance Monitoring"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "Compute HPC RDMA Auto-Configuration"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "Compute HPC RDMA Authentication"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "Cloud Guard Workload Protection"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "Block Volume Management"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "Bastion"
		}
	}
	availability_config {
		recovery_action = "RESTORE_INSTANCE"
	}
	availability_domain = "xZsm:SA-SAOPAULO-1-AD-1"
	compartment_id = "ocid1.compartment.oc1..aaaaaaaabbyjqgjwmfjoqqzivuakcz7c2hqkj6czj6larjjedxudjc5htrna"
	create_vnic_details {
		assign_ipv6ip = "false"
		assign_private_dns_record = "true"
		assign_public_ip = "true"
		display_name = "eth"
		hostname_label = "ocnix"
		subnet_id = "ocid1.subnet.oc1.sa-saopaulo-1.aaaaaaaawdsxbgl4pmjktkpwnojl7my2fpac2w3g62gh3dxx26hn3sxliaqa"
		skip_source_dest_check = true
		nsg_ids = ["ocid1.networksecuritygroup.oc1.sa-saopaulo-1.aaaaaaaa6x6xljveuasdgyjlmexssfk5su5vxfczej7q3zjps26lcrm2muzq"]
	}
	display_name = "ocnix"
	instance_options {
		are_legacy_imds_endpoints_disabled = "true"
	}
	metadata = {
		"ssh_authorized_keys" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICs+sOj/1GK5exkDkCw7H7zmDapshfWaRn474qxZxSUY leo\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMGWvbEP/E0dh/xwtUVIuQrNDSz+G4TCLA+UMVpT0gLi root@ali\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlCOf70p6jujZf6ZdE7ugOQAPtpqteigxxaQb4RONs4 thedandare@gmail.com\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO4x8pXKybfzCbc6IAd+HoPMW4vy3vT6ByGHM3uz4ApN leo@ali"
	}
	preemptible_instance_config {
		preemption_action {
			preserve_boot_volume = "true"
			type = "TERMINATE"
		}
	}
	shape = "VM.Standard.E3.Flex"

  shape_config {
    ocpus           = 1
    memory_in_gbs   = 4
  }
	source_details {
		source_id = "ocid1.bootvolume.oc1.sa-saopaulo-1.abtxeljryedz3bacibdlfwloazdhjxlr7gqs33fyyln4rpck5kdgfcvyso4a"
		source_type = "bootVolume"
	}
}
