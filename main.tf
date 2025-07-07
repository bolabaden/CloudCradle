# Main Oracle Cloud Infrastructure (OCI) Terraform Configuration
# Generated on: Mon Jul  7 13:41:37 CDT 2025

# ============================================================================
# NETWORKING INFRASTRUCTURE
# ============================================================================

# Main VCN
resource "oci_core_vcn" "main_vcn" {
  compartment_id = local.tenancy_ocid
  cidr_blocks    = ["10.16.0.0/16"]
  display_name   = "main-vcn"
  dns_label      = "mainvcn"
  is_ipv6enabled = true

  freeform_tags = {
    "Purpose" = "AlwaysFreeTierMaximization"
    "Type"    = "MainNetworking"
  }
}

# Main Subnet
resource "oci_core_subnet" "main_subnet" {
  compartment_id  = local.tenancy_ocid
  vcn_id          = oci_core_vcn.main_vcn.id
  cidr_block      = "10.16.1.0/24"
  display_name    = "main-subnet"
  dns_label       = "mainsubnet"
  ipv6cidr_blocks = [cidrsubnet(oci_core_vcn.main_vcn.ipv6cidr_blocks[0], 8, 1)]

  route_table_id    = oci_core_default_route_table.main_route_table.id
  security_list_ids = [oci_core_default_security_list.main_security_list.id]
  dhcp_options_id   = oci_core_vcn.main_vcn.default_dhcp_options_id

  freeform_tags = {
    "Purpose" = "AlwaysFreeTierMaximization"
    "Type"    = "MainSubnet"
  }
}

# Internet Gateway
resource "oci_core_internet_gateway" "main_internet_gateway" {
  compartment_id = local.tenancy_ocid
  vcn_id         = oci_core_vcn.main_vcn.id
  display_name   = "main-internet-gateway"
  enabled        = true

  freeform_tags = {
    "Purpose" = "AlwaysFreeTierMaximization"
    "Type"    = "InternetAccess"
  }
}

# Default Route Table
resource "oci_core_default_route_table" "main_route_table" {
  manage_default_resource_id = oci_core_vcn.main_vcn.default_route_table_id
  display_name               = "main-route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main_internet_gateway.id
  }

  route_rules {
    destination       = "::/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main_internet_gateway.id
  }

  freeform_tags = {
    "Purpose" = "AlwaysFreeTierMaximization"
    "Type"    = "MainRouting"
  }
}

# Default Security List
resource "oci_core_default_security_list" "main_security_list" {
  manage_default_resource_id = oci_core_vcn.main_vcn.default_security_list_id
  display_name               = "main-security-list"

  # Egress rules - allow all outbound
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # Ingress rules
  # SSH
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 22
      max = 22
    }
  }

  # HTTP
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 80
      max = 80
    }
  }

  # HTTPS
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 443
      max = 443
    }
  }

  # ICMP
  ingress_security_rules {
    protocol = "1" # ICMP
    source   = "0.0.0.0/0"
  }

  freeform_tags = {
    "Purpose" = "AlwaysFreeTierMaximization"
    "Type"    = "MainSecurity"
  }
}

# ARM A1 Flex Instances (Always Free Eligible)
resource "oci_core_instance" "arm_flex_instances" {
  count = local.arm_flex_instance_count

  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.tenancy_ocid
  display_name        = local.arm_flex_hostnames[count.index]
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = local.arm_flex_ocpus_per_instance[count.index]
    memory_in_gbs = local.arm_flex_memory_per_instance[count.index]
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.main_subnet.id
    display_name     = "${local.arm_flex_hostnames[count.index]}-vnic"
    assign_public_ip = true
    hostname_label   = local.arm_flex_hostnames[count.index]
  }

  source_details {
    source_type             = "image"
    source_id               = local.ubuntu2404_arm_flex_ocid
    boot_volume_size_in_gbs = local.arm_flex_boot_volume_size_gb[count.index]
  }

  metadata = {
    ssh_authorized_keys = local.ssh_pubkey_data
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
      hostname = local.arm_flex_hostnames[count.index]
    }))
  }

  freeform_tags = {
    "Purpose"      = "AlwaysFreeTierMaximization"
    "InstanceType" = "ARM-A1-AlwaysFree"
    "Architecture" = "aarch64"
    "Hostname"     = local.arm_flex_hostnames[count.index]
  }
}

# AMD x86 Micro Instances (Always Free Eligible)
resource "oci_core_instance" "amd_micro_instances" {
  count = local.amd_micro_instance_count

  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.tenancy_ocid
  display_name        = local.amd_micro_hostnames[count.index]
  shape               = "VM.Standard.E2.1.Micro"

  create_vnic_details {
    subnet_id        = oci_core_subnet.main_subnet.id
    display_name     = "${local.amd_micro_hostnames[count.index]}-vnic"
    assign_public_ip = true
    hostname_label   = local.amd_micro_hostnames[count.index]
  }

  source_details {
    source_type             = "image"
    source_id               = local.ubuntu2404ocid
    boot_volume_size_in_gbs = local.amd_micro_boot_volume_size_gb
  }

  metadata = {
    ssh_authorized_keys = local.ssh_pubkey_data
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
      hostname = local.amd_micro_hostnames[count.index]
    }))
  }

  freeform_tags = {
    "Purpose"      = "AlwaysFreeTierMaximization"
    "InstanceType" = "AMD-x86-AlwaysFree"
    "Architecture" = "x86_64"
    "Hostname"     = local.amd_micro_hostnames[count.index]
  }
}

# ============================================================================
# OUTPUTS
# ============================================================================

# ARM Instance Information
output "arm_instances_complete_summary" {
  description = "Complete ARM instance details and connection information"
  value = {
    instances = local.arm_flex_instance_count > 0 ? [
      for i in range(local.arm_flex_instance_count) : {
        instance_name  = local.arm_flex_hostnames[i]
        instance_id    = oci_core_instance.arm_flex_instances[i].id
        public_ip      = oci_core_instance.arm_flex_instances[i].public_ip
        private_ip     = oci_core_instance.arm_flex_instances[i].private_ip
        shape          = oci_core_instance.arm_flex_instances[i].shape
        ocpus          = local.arm_flex_ocpus_per_instance[i]
        memory_gb      = local.arm_flex_memory_per_instance[i]
        boot_volume_gb = local.arm_flex_boot_volume_size_gb[i]
        ssh_command    = "ssh -i ./ssh_keys/id_rsa ubuntu@${oci_core_instance.arm_flex_instances[i].public_ip}"
        state          = oci_core_instance.arm_flex_instances[i].state
      }
    ] : []
    total_instances = local.arm_flex_instance_count
    total_ocpus     = local.arm_flex_instance_count > 0 ? sum(local.arm_flex_ocpus_per_instance) : 0
    total_memory_gb = local.arm_flex_instance_count > 0 ? sum(local.arm_flex_memory_per_instance) : 0
    architecture    = "aarch64"
    note            = local.arm_flex_instance_count > 0 ? "ARM instances configured" : "No ARM instances configured"
  }
}

# AMD Instance Information
output "amd_instances_complete_summary" {
  description = "Complete AMD instance details and connection information"
  value = {
    instances = local.amd_micro_instance_count > 0 ? [
      for i in range(local.amd_micro_instance_count) : {
        instance_name  = local.amd_micro_hostnames[i]
        instance_id    = oci_core_instance.amd_micro_instances[i].id
        public_ip      = oci_core_instance.amd_micro_instances[i].public_ip
        private_ip     = oci_core_instance.amd_micro_instances[i].private_ip
        shape          = oci_core_instance.amd_micro_instances[i].shape
        ocpus          = 1
        memory_gb      = 1
        boot_volume_gb = local.amd_micro_boot_volume_size_gb
        ssh_command    = "ssh -i ./ssh_keys/id_rsa ubuntu@${oci_core_instance.amd_micro_instances[i].public_ip}"
        state          = oci_core_instance.amd_micro_instances[i].state
      }
    ] : []
    total_instances = local.amd_micro_instance_count
    total_ocpus     = local.amd_micro_instance_count
    total_memory_gb = local.amd_micro_instance_count
    architecture    = "x86_64"
    note            = local.amd_micro_instance_count > 0 ? "AMD instances configured" : "No AMD instances configured"
  }
}

# Network Information
output "network_summary" {
  description = "Network configuration summary"
  value = {
    vcn_id               = oci_core_vcn.main_vcn.id
    vcn_cidr_blocks      = oci_core_vcn.main_vcn.cidr_blocks
    vcn_ipv6_cidr_blocks = oci_core_vcn.main_vcn.ipv6cidr_blocks
    subnet_id            = oci_core_subnet.main_subnet.id
    subnet_cidr_block    = oci_core_subnet.main_subnet.cidr_block
    internet_gateway_id  = oci_core_internet_gateway.main_internet_gateway.id
    security_list_id     = oci_core_default_security_list.main_security_list.id
  }
}

# Complete Infrastructure Summary
output "infrastructure_complete_summary" {
  description = "Complete infrastructure summary with all resources"
  value = {
    region               = local.region
    availability_domain  = data.oci_identity_availability_domains.ads.availability_domains[0].name
    compartment_id       = local.compartment_id
    total_instances      = local.amd_micro_instance_count + local.arm_flex_instance_count
    amd_instances        = local.amd_micro_instance_count
    arm_instances        = local.arm_flex_instance_count
    total_storage_gb     = (local.amd_micro_instance_count * local.amd_micro_boot_volume_size_gb) + (local.arm_flex_instance_count > 0 ? sum(local.arm_flex_boot_volume_size_gb) : 0)
    free_tier_limit_gb   = 200
    ssh_key_path         = local.ssh_private_key_path
    setup_complete       = true
    ready_for_connection = true
  }
}
