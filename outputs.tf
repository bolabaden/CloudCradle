# The "name" of the availability domain to be used for the compute instance.
output "name-of-first-availability-domain" {
  value = data.oci_identity_availability_domains.ads.availability_domains[0]
}

output "objectstorage-namesace" {
  value = data.oci_objectstorage_namespace.state_namespace
}

# Combined VM list for all instances (AMD + ARM)
output "vm_list" {
  description = "All instances with connection details"
  value = concat(
    [
      for instance in oci_core_instance.amd_micro_instance : {
        hostname     = instance.display_name
        ip_address   = instance.public_ip
        private_ip   = instance.private_ip
        user         = "ubuntu"
        instance_type = "AMD-x86"
        shape        = instance.shape
        ocpus        = instance.shape_config[0].ocpus
        memory_gb    = instance.shape_config[0].memory_in_gbs
        boot_volume_gb = local.amd_micro_boot_volume_size_gb
      }
    ],
    [
      for instance in oci_core_instance.arm_flex_instance : {
        hostname     = instance.display_name
        ip_address   = instance.public_ip
        private_ip   = instance.private_ip
        user         = "ubuntu"
        instance_type = "ARM-A1"
        shape        = instance.shape
        ocpus        = instance.shape_config[0].ocpus
        memory_gb    = instance.shape_config[0].memory_in_gbs
        boot_volume_gb = local.arm_flex_boot_volume_size_gb
      }
    ]
  )
}

# SSH connection commands
output "ssh_commands" {
  description = "SSH commands to connect to all instances"
  value = concat(
    [
      for instance in oci_core_instance.amd_micro_instance : 
      "ssh -i ${local.ssh_private_key_path} ubuntu@${instance.public_ip}  # ${instance.display_name} (AMD x86)"
    ],
    [
      for instance in oci_core_instance.arm_flex_instance : 
      "ssh -i ${local.ssh_private_key_path} ubuntu@${instance.public_ip}  # ${instance.display_name} (ARM A1)"
    ]
  )
}

# Generate Ansible inventory file
resource "local_file" "ansible_inventory" {
  filename = "ansible/inventory.ini"
  content = <<-EOT
[oracle-instances]
%{~ for instance in oci_core_instance.amd_micro_instance ~}
${instance.display_name} ansible_host=${instance.public_ip} ansible_user=ubuntu ansible_ssh_private_key_file=${local.ssh_private_key_path} instance_type=amd-x86
%{~ endfor ~}
%{~ for instance in oci_core_instance.arm_flex_instance ~}
${instance.display_name} ansible_host=${instance.public_ip} ansible_user=ubuntu ansible_ssh_private_key_file=${local.ssh_private_key_path} instance_type=arm-a1
%{~ endfor ~}

[amd-instances]
%{~ for instance in oci_core_instance.amd_micro_instance ~}
${instance.display_name} ansible_host=${instance.public_ip} ansible_user=ubuntu ansible_ssh_private_key_file=${local.ssh_private_key_path}
%{~ endfor ~}

[arm-instances]
%{~ for instance in oci_core_instance.arm_flex_instance ~}
${instance.display_name} ansible_host=${instance.public_ip} ansible_user=ubuntu ansible_ssh_private_key_file=${local.ssh_private_key_path}
%{~ endfor ~}
  EOT
}
