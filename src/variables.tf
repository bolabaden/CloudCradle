# Automatically generated OCI Terraform variables
# Generated on: 2025-07-02 03:29:53
# Region: us-sanjose-1
# Authenticated as: athenajaguiar@gmail.com (ocid1.user.oc1..aaaaaaaarnp4jrrbah63ql7u6xxuamna2wjdotyqd5yhw7ansblap7bqdwzq)

locals {
  # Per README: availability_domain == tenancy-ocid == compartment_id
  availability_domain  = "ocid1.tenancy.oc1..aaaaaaaarrvuyzyw6rvftlxqg4dhntawapws6gogk5rwzymbqetmfb4echca"
  compartment_id       = "ocid1.tenancy.oc1..aaaaaaaarrvuyzyw6rvftlxqg4dhntawapws6gogk5rwzymbqetmfb4echca"
  
  # Dynamically fetched Ubuntu images for region us-sanjose-1
  ubuntu2404ocid       = "ocid1.image.oc1.us-sanjose-1.aaaaaaaappswsfuaodghkbps5kjh3bhjxxpaig56wiirxhjlo5tktsuypkha"
  ubuntu2404_arm_flex_ocid  = "ocid1.image.oc1.us-sanjose-1.aaaaaaaax6vsn7c34viq7yfu3j3v554x6dulorapywrorheltorxoi5on4dq"
  
  # OCI Authentication (using session token authentication)
  user_ocid            = "ocid1.user.oc1..aaaaaaaarnp4jrrbah63ql7u6xxuamna2wjdotyqd5yhw7ansblap7bqdwzq"
  tenancy_ocid         = "ocid1.tenancy.oc1..aaaaaaaarrvuyzyw6rvftlxqg4dhntawapws6gogk5rwzymbqetmfb4echca"
  region               = "us-sanjose-1"
  
  # SSH Configuration
  ssh_pubkey_path      = pathexpand("./ssh_keys/id_rsa.pub")
  ssh_pubkey_data      = file(pathexpand("./ssh_keys/id_rsa.pub"))
  ssh_private_key_path = pathexpand("./ssh_keys/id_rsa")
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