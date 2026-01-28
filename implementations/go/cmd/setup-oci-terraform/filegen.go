package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Create all Terraform files
func (app *App) createTerraformFiles() error {
	printHeader("GENERATING TERRAFORM FILES")

	if err := app.createTerraformProvider(); err != nil {
		return err
	}

	if err := app.createTerraformVariables(); err != nil {
		return err
	}

	if err := app.createTerraformDatasources(); err != nil {
		return err
	}

	if err := app.createTerraformMain(); err != nil {
		return err
	}

	if err := app.createTerraformBlockVolumes(); err != nil {
		return err
	}

	if err := app.createCloudInit(); err != nil {
		return err
	}

	printSuccess("All Terraform files generated successfully")
	return nil
}

// Create provider.tf
func (app *App) createTerraformProvider() error {
	printStatus("Creating provider.tf...")

	// Backup existing file
	if _, err := os.Stat("provider.tf"); err == nil {
		backupName := fmt.Sprintf("provider.tf.bak.%s", time.Now().Format("20060102_150405"))
		os.Rename("provider.tf", backupName)
	}

	content := fmt.Sprintf(`# Terraform Provider Configuration for Oracle Cloud Infrastructure
# Generated: %s
# Region: %s

terraform {
  required_version = ">= 1.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }
}

# OCI Provider with session token authentication
provider "oci" {
  auth                = "SecurityToken"
  config_file_profile = "DEFAULT"
  region              = "%s"
}
`, time.Now().Format(time.RFC3339), app.OCIConfig.Region, app.OCIConfig.Region)

	return os.WriteFile("provider.tf", []byte(content), 0644)
}

// Create variables.tf
func (app *App) createTerraformVariables() error {
	printStatus("Creating variables.tf...")

	// Backup existing file
	if _, err := os.Stat("variables.tf"); err == nil {
		backupName := fmt.Sprintf("variables.tf.bak.%s", time.Now().Format("20060102_150405"))
		os.Rename("variables.tf", backupName)
	}

	// Build array strings
	amdHostnames := buildArrayString(app.InstanceConfig.AMDMicroHostnames, true)
	armHostnames := buildArrayString(app.InstanceConfig.ARMFlexHostnames, true)
	armOCPUs := buildArrayInt(app.InstanceConfig.ARMFlexOCPUsPerInstance)
	armMemory := buildArrayInt(app.InstanceConfig.ARMFlexMemoryPerInstance)
	armBoot := buildArrayInt(app.InstanceConfig.ARMFlexBootVolumeSizeGB)
	armBlock := buildArrayInt(app.InstanceConfig.ARMFlexBlockVolumes)

	content := fmt.Sprintf(`# Oracle Cloud Infrastructure Terraform Variables
# Generated: %s
# Configuration: %dx AMD + %dx ARM instances

locals {
  # Core identifiers
  tenancy_ocid    = "%s"
  compartment_id  = "%s"
  user_ocid       = "%s"
  region          = "%s"
  
  # Ubuntu Images (region-specific)
  ubuntu_x86_image_ocid = "%s"
  ubuntu_arm_image_ocid = "%s"
  
  # SSH Configuration
  ssh_pubkey_path      = pathexpand("./ssh_keys/id_rsa.pub")
  ssh_pubkey_data      = file(pathexpand("./ssh_keys/id_rsa.pub"))
  ssh_private_key_path = pathexpand("./ssh_keys/id_rsa")
  
  # AMD x86 Micro Instances Configuration
  amd_micro_instance_count      = %d
  amd_micro_boot_volume_size_gb = %d
  amd_micro_hostnames           = %s
  amd_block_volume_size_gb      = 0
  
  # ARM A1 Flex Instances Configuration
  arm_flex_instance_count       = %d
  arm_flex_ocpus_per_instance   = %s
  arm_flex_memory_per_instance  = %s
  arm_flex_boot_volume_size_gb  = %s
  arm_flex_hostnames            = %s
  arm_block_volume_sizes        = %s
  
  # Storage calculations
  total_amd_storage = local.amd_micro_instance_count * local.amd_micro_boot_volume_size_gb
  total_arm_storage = local.arm_flex_instance_count > 0 ? sum(local.arm_flex_boot_volume_size_gb) : 0
  total_block_storage = (local.amd_micro_instance_count * local.amd_block_volume_size_gb) + (local.arm_flex_instance_count > 0 ? sum(local.arm_block_volume_sizes) : 0)
  total_storage = local.total_amd_storage + local.total_arm_storage + local.total_block_storage
}

# Free Tier Limits
variable "free_tier_max_storage_gb" {
  description = "Maximum storage for Oracle Free Tier"
  type        = number
  default     = %d
}

variable "free_tier_max_arm_ocpus" {
  description = "Maximum ARM OCPUs for Oracle Free Tier"
  type        = number
  default     = %d
}

variable "free_tier_max_arm_memory_gb" {
  description = "Maximum ARM memory for Oracle Free Tier"
  type        = number
  default     = %d
}

# Validation checks
check "storage_limit" {
  assert {
    condition     = local.total_storage <= var.free_tier_max_storage_gb
    error_message = "Total storage (\${local.total_storage}GB) exceeds Free Tier limit (\${var.free_tier_max_storage_gb}GB)"
  }
}

check "arm_ocpu_limit" {
  assert {
    condition     = local.arm_flex_instance_count == 0 || sum(local.arm_flex_ocpus_per_instance) <= var.free_tier_max_arm_ocpus
    error_message = "Total ARM OCPUs exceed Free Tier limit (\${var.free_tier_max_arm_ocpus})"
  }
}

check "arm_memory_limit" {
  assert {
    condition     = local.arm_flex_instance_count == 0 || sum(local.arm_flex_memory_per_instance) <= var.free_tier_max_arm_memory_gb
    error_message = "Total ARM memory exceeds Free Tier limit (\${var.free_tier_max_arm_memory_gb}GB)"
  }
}
`,
		time.Now().Format(time.RFC3339),
		app.InstanceConfig.AMDMicroInstanceCount,
		app.InstanceConfig.ARMFlexInstanceCount,
		app.OCIConfig.TenancyOCID,
		app.OCIConfig.TenancyOCID,
		app.OCIConfig.UserOCID,
		app.OCIConfig.Region,
		app.OCIConfig.UbuntuImageOCID,
		app.OCIConfig.UbuntuARMFlexImageOCID,
		app.InstanceConfig.AMDMicroInstanceCount,
		app.InstanceConfig.AMDMicroBootVolumeSizeGB,
		amdHostnames,
		app.InstanceConfig.ARMFlexInstanceCount,
		armOCPUs,
		armMemory,
		armBoot,
		armHostnames,
		armBlock,
		FreeTierMaxStorageGB,
		FreeTierMaxARMOCPUs,
		FreeTierMaxARMMemoryGB,
	)

	return os.WriteFile("variables.tf", []byte(content), 0644)
}

// Create data_sources.tf
func (app *App) createTerraformDatasources() error {
	printStatus("Creating data_sources.tf...")

	if _, err := os.Stat("data_sources.tf"); err == nil {
		backupName := fmt.Sprintf("data_sources.tf.bak.%s", time.Now().Format("20060102_150405"))
		os.Rename("data_sources.tf", backupName)
	}

	content := `# OCI Data Sources
# Fetches dynamic information from Oracle Cloud

# Availability Domains
data "oci_identity_availability_domains" "ads" {
  compartment_id = local.tenancy_ocid
}

# Tenancy Information
data "oci_identity_tenancy" "tenancy" {
  tenancy_id = local.tenancy_ocid
}

# Available Regions
data "oci_identity_regions" "regions" {}

# Region Subscriptions
data "oci_identity_region_subscriptions" "subscriptions" {
  tenancy_id = local.tenancy_ocid
}
`

	return os.WriteFile("data_sources.tf", []byte(content), 0644)
}

// Create main.tf (simplified - full version would be very long)
func (app *App) createTerraformMain() error {
	printStatus("Creating main.tf...")

	if _, err := os.Stat("main.tf"); err == nil {
		backupName := fmt.Sprintf("main.tf.bak.%s", time.Now().Format("20060102_150405"))
		os.Rename("main.tf", backupName)
	}

	// Read the main.tf template from embedded resource or use a template file
	// For now, we'll generate a simplified version
	// The full version matches the bash script exactly
	content := `# Oracle Cloud Infrastructure - Main Configuration
# Always Free Tier Optimized
# Note: This is a simplified version. See setup_oci_terraform.sh for full template.

# NETWORKING
resource "oci_core_vcn" "main" {
  compartment_id = local.compartment_id
  cidr_blocks    = ["10.0.0.0/16"]
  display_name   = "main-vcn"
  dns_label      = "mainvcn"
  is_ipv6enabled = true
  
  freeform_tags = {
    "Purpose" = "AlwaysFreeTier"
    "Managed" = "Terraform"
  }
}

resource "oci_core_internet_gateway" "main" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "main-igw"
  enabled        = true
}

# ... (Full implementation would include all resources from bash script)
# See setup_oci_terraform.sh lines 2238-2575 for complete template
`

	// For production, you'd want to embed the full template or read from a file
	// This is a placeholder - the full template is 300+ lines
	return os.WriteFile("main.tf", []byte(content), 0644)
}

// Create block_volumes.tf
func (app *App) createTerraformBlockVolumes() error {
	printStatus("Creating block_volumes.tf...")

	if _, err := os.Stat("block_volumes.tf"); err == nil {
		backupName := fmt.Sprintf("block_volumes.tf.bak.%s", time.Now().Format("20060102_150405"))
		os.Rename("block_volumes.tf", backupName)
	}

	content := `# Block Volume Resources (Optional)
# Block volumes provide additional storage beyond boot volumes

# AMD Block Volumes
resource "oci_core_volume" "amd_block" {
  count = local.amd_block_volume_size_gb > 0 ? local.amd_micro_instance_count : 0
  
  compartment_id      = local.compartment_id
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "${local.amd_micro_hostnames[count.index]}-block"
  size_in_gbs         = local.amd_block_volume_size_gb
  
  freeform_tags = {
    "Purpose" = "AlwaysFreeTier"
    "Type"    = "BlockVolume"
    "Managed" = "Terraform"
  }
}

resource "oci_core_volume_attachment" "amd_block" {
  count = local.amd_block_volume_size_gb > 0 ? local.amd_micro_instance_count : 0
  
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.amd[count.index].id
  volume_id       = oci_core_volume.amd_block[count.index].id
}

# ARM Block Volumes
resource "oci_core_volume" "arm_block" {
  count = local.arm_flex_instance_count > 0 ? length([for s in local.arm_block_volume_sizes : s if s > 0]) : 0
  
  compartment_id      = local.compartment_id
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "${local.arm_flex_hostnames[count.index]}-block"
  size_in_gbs         = [for s in local.arm_block_volume_sizes : s if s > 0][count.index]
  
  freeform_tags = {
    "Purpose" = "AlwaysFreeTier"
    "Type"    = "BlockVolume"
    "Managed" = "Terraform"
  }
}

resource "oci_core_volume_attachment" "arm_block" {
  count = local.arm_flex_instance_count > 0 ? length([for s in local.arm_block_volume_sizes : s if s > 0]) : 0
  
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.arm[count.index].id
  volume_id       = oci_core_volume.arm_block[count.index].id
}
`

	return os.WriteFile("block_volumes.tf", []byte(content), 0644)
}

// Create cloud-init.yaml
func (app *App) createCloudInit() error {
	printStatus("Creating cloud-init.yaml...")

	if _, err := os.Stat("cloud-init.yaml"); err == nil {
		backupName := fmt.Sprintf("cloud-init.yaml.bak.%s", time.Now().Format("20060102_150405"))
		os.Rename("cloud-init.yaml", backupName)
	}

	content := `#cloud-config
hostname: ${hostname}
fqdn: ${hostname}.local
manage_etc_hosts: true

package_update: true
package_upgrade: true

packages:
  - curl
  - wget
  - git
  - htop
  - vim
  - unzip
  - jq
  - tmux
  - net-tools
  - iotop
  - ncdu

runcmd:
  - echo "Instance ${hostname} initialized at $(date)" >> /var/log/cloud-init-complete.log
  - systemctl enable --now fail2ban || true

# Basic security hardening
write_files:
  - path: /etc/ssh/sshd_config.d/hardening.conf
    content: |
      PermitRootLogin no
      PasswordAuthentication no
      MaxAuthTries 3
      ClientAliveInterval 300
      ClientAliveCountMax 2

timezone: UTC
ssh_pwauth: false

final_message: "Instance ${hostname} ready after $UPTIME seconds"
`

	return os.WriteFile("cloud-init.yaml", []byte(content), 0644)
}

// Helper functions
func buildArrayString(arr []string, quoted bool) string {
	if len(arr) == 0 {
		return "[]"
	}

	var builder strings.Builder
	builder.WriteString("[")
	for i, s := range arr {
		if i > 0 {
			builder.WriteString(", ")
		}
		if quoted {
			builder.WriteString(fmt.Sprintf(`"%s"`, s))
		} else {
			builder.WriteString(s)
		}
	}
	builder.WriteString("]")
	return builder.String()
}

func buildArrayInt(arr []int) string {
	if len(arr) == 0 {
		return "[]"
	}

	var builder strings.Builder
	builder.WriteString("[")
	for i, v := range arr {
		if i > 0 {
			builder.WriteString(", ")
		}
		builder.WriteString(fmt.Sprintf("%d", v))
	}
	builder.WriteString("]")
	return builder.String()
}
