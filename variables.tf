# Automatically generated OCI Terraform variables
# Generated on: Wed Jul  2 03:25:04 CDT 2025
# Region: us-sanjose-1
# Authentication: api_key

locals {
  # Per README: availability_domain == tenancy-ocid == compartment_id
  availability_domain  = "ocid1.tenancy.oc1..aaaaaaaarrvuyzyw6rvftlxqg4dhntawapws6gogk5rwzymbqetmfb4echca"
  compartment_id       = "ocid1.tenancy.oc1..aaaaaaaarrvuyzyw6rvftlxqg4dhntawapws6gogk5rwzymbqetmfb4echca"
  
  # Dynamically fetched Ubuntu images for region us-sanjose-1
  ubuntu2404ocid       = "ocid1.image.oc1.us-sanjose-1.aaaaaaaayvpqhhkbzd4p2tlc44blbq4obmjne4uhlul7psc3qbhonrgik4ha"
  ubuntu2404_arm_flex_ocid  = "ocid1.image.oc1.us-sanjose-1.aaaaaaaayvpqhhkbzd4p2tlc44blbq4obmjne4uhlul7psc3qbhonrgik4ha"
  
  # OCI Authentication
  user_ocid            = "ocid1.user.oc1..aaaaaaaarnp4jrrbah63ql7u6xxuamna2wjdotyqd5yhw7ansblap7bqdwzq"
  fingerprint          = "6c:4f:02:12:cc:e6:22:60:d8:c7:bb:fd:79:55:40:97"
  private_api_key_path = pathexpand("~/.oci/oci_api_key.pem")
  tenancy_ocid         = "ocid1.tenancy.oc1..aaaaaaaarrvuyzyw6rvftlxqg4dhntawapws6gogk5rwzymbqetmfb4echca"
  region               = "us-sanjose-1"
  
  # SSH Configuration
  ssh_pubkey_path      = pathexpand("./ssh_keys/id_rsa.pub")
  ssh_pubkey_data      = file(pathexpand("./ssh_keys/id_rsa.pub"))
  ssh_private_key_path = pathexpand("./ssh_keys/id_rsa")
  
  # Oracle Free Tier Instance Configuration
  # AMD x86 instances (Always Free Eligible)
  amd_micro_instance_count        = 2
  amd_micro_boot_volume_size_gb   = 50
  
  # ARM instances configuration (default - will be overridden by setup script)
  arm_flex_instance_count        = 1
  arm_flex_ocpus_per_instance    = 4
  arm_flex_memory_per_instance   = 24
  arm_flex_boot_volume_size_gb   = 100

  amd_micro_hostnames = ["micro1", "micro2"]
  arm_flex_hostnames = ["flex1", "flex2", "flex3"]
  
  # Boot volume usage validation
  total_boot_volume_gb = local.amd_micro_instance_count * local.amd_micro_boot_volume_size_gb + local.arm_flex_instance_count * local.arm_flex_boot_volume_size_gb
}

# Additional variables for reference
variable "availability_domain_name" {
  description = "The availability domain name"
  type        = string
  default     = "JoOH:US-SANJOSE-1-AD-1"
}

variable "instance_shape" {
  description = "The shape of the instance"
  type        = string
  default     = "VM.Standard.E2.1.Micro"
}

variable "instance_shape_flex" {
  description = "The flexible shape configuration"
  type        = string
  default     = "VM.Standard.A1.Flex"
}

# Boot volume size validation
variable "max_free_tier_boot_volume_gb" {
  description = "Maximum boot volume storage for Oracle Free Tier"
  type        = number
  default     = 200
}

# Validation check
check "free_tier_boot_volume_limit" {
  assert {
    condition     = local.total_boot_volume_gb <= var.max_free_tier_boot_volume_gb
    error_message = "Total boot volume usage (${local.total_boot_volume_gb}GB) exceeds Oracle Free Tier limit (${var.max_free_tier_boot_volume_gb}GB)."
  }
}
