# Oracle Free Tier Compute Instances
# This configuration creates instances according to Oracle's Always Free limits:
# - 2x AMD x86 instances (VM.Standard.E2.1.Micro)
# - Configurable ARM instances (VM.Standard.A1.Flex) 
# - 200GB total boot volume storage distributed across all instances

# AMD x86 instances (Always Free Eligible)
resource "oci_core_instance" "amd_micro_instance" {
  count = local.amd_micro_instance_count

  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.availability_domain
  display_name        = local.amd_micro_hostnames[count.index]
  shape               = "VM.Standard.E2.1.Micro"
  
  shape_config {
    ocpus         = 1
    memory_in_gbs = 1
  }
  
  source_details {
    source_type             = "image"
    source_id               = local.ubuntu2404ocid
    boot_volume_size_in_gbs = local.amd_micro_boot_volume_size_gb
  }

  metadata = {
    ssh_authorized_keys = local.ssh_pubkey_data
  }
  
  preserve_boot_volume = false

  create_vnic_details {
    assign_public_ip = true
    subnet_id        = oci_core_subnet.main_subnet.id
    nsg_ids = [
      oci_core_network_security_group.my_security_group_http.id,
      oci_core_network_security_group.my_security_group_ssh.id
    ]
  }

  freeform_tags = {
    "InstanceType" = "AMD-x86-AlwaysFree"
    "Purpose"      = "GeneralCompute"
  }
}

# ARM instances (Always Free Eligible - Configurable)
resource "oci_core_instance" "arm_flex_instance" {
  count = local.arm_flex_instance_count

  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.availability_domain
  display_name        = local.arm_flex_hostnames[count.index]
  shape               = "VM.Standard.A1.Flex"
  
  shape_config {
    ocpus         = local.arm_flex_ocpus_per_instance
    memory_in_gbs = local.arm_flex_memory_per_instance
  }
  
  source_details {
    source_type             = "image"
    source_id               = local.ubuntu2404_arm_flex_ocid
    boot_volume_size_in_gbs = local.arm_flex_boot_volume_size_gb
  }

  metadata = {
    ssh_authorized_keys = local.ssh_pubkey_data
  }
  
  preserve_boot_volume = false

  create_vnic_details {
    assign_public_ip = true
    subnet_id        = oci_core_subnet.main_subnet.id
    nsg_ids = [
      oci_core_network_security_group.my_security_group_http.id,
      oci_core_network_security_group.my_security_group_ssh.id,
      oci_core_network_security_group.my_security_group_wg_vpn.id
    ]
  }

  freeform_tags = {
    "InstanceType" = "ARM-A1-AlwaysFree"
    "Purpose"      = "HighPerformanceCompute"
    "OCPUs"        = tostring(local.arm_flex_ocpus_per_instance)
    "MemoryGB"     = tostring(local.arm_flex_memory_per_instance)
  }
}

# Output instance information for easy access
output "amd_micro_instances" {
  description = "AMD x86 instance details"
  value = [
    for instance in oci_core_instance.amd_micro_instance : {
      display_name      = instance.display_name
      public_ip         = instance.public_ip
      private_ip        = instance.private_ip
      shape             = instance.shape
      ocpus             = instance.shape_config[0].ocpus
      memory_gb         = instance.shape_config[0].memory_in_gbs
      boot_volume_gb    = local.amd_micro_boot_volume_size_gb
      availability_domain = instance.availability_domain
    }
  ]
}

output "arm_flex_instances" {
  description = "ARM instance details"
  value = [
    for instance in oci_core_instance.arm_flex_instance : {
      display_name      = instance.display_name
      public_ip         = instance.public_ip
      private_ip        = instance.private_ip
      shape             = instance.shape
      ocpus             = instance.shape_config[0].ocpus
      memory_gb         = instance.shape_config[0].memory_in_gbs
      boot_volume_gb    = local.arm_flex_boot_volume_size_gb
      availability_domain = instance.availability_domain
    }
  ]
}

# Free tier usage summary
output "free_tier_usage_summary" {
  description = "Oracle Free Tier resource usage summary"
  value = {
    total_instances       = local.amd_micro_instance_count + local.arm_flex_instance_count
    amd_micro_instances        = local.amd_micro_instance_count
    arm_flex_instances        = local.arm_flex_instance_count
    total_boot_volume_gb = local.total_boot_volume_gb
    boot_volume_limit_gb = var.max_free_tier_boot_volume_gb
    boot_volume_remaining_gb = var.max_free_tier_boot_volume_gb - local.total_boot_volume_gb
    arm_flex_ocpus_used       = local.arm_flex_instance_count * local.arm_flex_ocpus_per_instance
    arm_flex_memory_used_gb   = local.arm_flex_instance_count * local.arm_flex_memory_per_instance
    arm_flex_ocpus_limit      = 4
    arm_flex_memory_limit_gb  = 24
  }
}
