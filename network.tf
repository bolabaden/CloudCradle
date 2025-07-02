####
## MAIN ROUTING
####
resource "oci_core_vcn" "main_vcn" {
  cidr_blocks = [
    "172.16.0.0/16",
  ]
  compartment_id = local.availability_domain
  display_name   = "main-vcn"
  dns_label      = "mainvcn"
  freeform_tags = {
  }
  ipv6private_cidr_blocks = [
    "fd00::/64"
  ]
}

resource "oci_core_internet_gateway" "main_vc_Internet-Gateway" {
  compartment_id = local.availability_domain
  display_name   = "Internet Gateway main-vcn"
  enabled        = "true"
  freeform_tags = {
  }
  vcn_id = oci_core_vcn.main_vcn.id
}

resource "oci_core_subnet" "main_subnet" {
  vcn_id         = oci_core_vcn.main_vcn.id
  compartment_id = local.availability_domain
  cidr_block     = "172.16.0.0/24"
  #dhcp_options_id = oci_core_vcn.main_vcns.default_dhcp_options_id
  display_name = "main-subnet"
  dns_label    = "mainsubnet"
  freeform_tags = {
  }

  prohibit_internet_ingress  = "false"
  prohibit_public_ip_on_vnic = "false"

  # we are interested in this, allows SSH default
  security_list_ids = [
    oci_core_vcn.main_vcn.default_security_list_id,
    #oci_core_security_list.https_security_list.id
  ]
  
  # IPv6 configuration
  ipv6cidr_block = "fd00::/64"
}

resource "oci_core_default_route_table" "Default-Route-Table-for-main-vcn" {
  compartment_id = local.availability_domain
  display_name   = "Default Route Table for main-vcn"
  freeform_tags = {
  }
  manage_default_resource_id = oci_core_vcn.main_vcn.default_route_table_id
  route_rules {
    #description = <<Optional value not found in discovery>>
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main_vc_Internet-Gateway.id
  }
  route_rules {
    destination       = "::/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main_vc_Internet-Gateway.id
  }
}

## 
## SECURITY GROUPS
## 
resource "oci_core_network_security_group" "my_security_group_http" {
  compartment_id = local.availability_domain
  vcn_id         = oci_core_vcn.main_vcn.id
  display_name   = "my-security-group-http"
}

resource "oci_core_network_security_group" "my_security_group_ssh" {
  compartment_id = local.availability_domain
  vcn_id         = oci_core_vcn.main_vcn.id
  display_name   = "my-security-group-ssh"
}


resource "oci_core_network_security_group" "my_security_group_wg_vpn" {
  compartment_id = local.availability_domain
  display_name   = "my-security-group-wg"
  freeform_tags = {
  }
  vcn_id = oci_core_vcn.main_vcn.id
}

## 
## NSG Rules
## 
resource "oci_core_network_security_group_security_rule" "https_security_rule" {
  network_security_group_id = oci_core_network_security_group.my_security_group_http.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = "0.0.0.0/0"

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "ssh_security_group_rule" {
  destination_type          = ""
  direction                 = "INGRESS"
  network_security_group_id = oci_core_network_security_group.my_security_group_ssh.id
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  stateless                 = "false"
  tcp_options {
    destination_port_range {
      max = "22"
      min = "22"
    }
    #source_port_range = <<Optional value not found in discovery>>
  }
}


resource "oci_core_network_security_group_security_rule" "wg_security_group_rule" {
  #destination = <<Optional value not found in discovery>>
  destination_type          = ""
  direction                 = "INGRESS"
  network_security_group_id = oci_core_network_security_group.my_security_group_wg_vpn.id
  protocol                  = "17"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  stateless                 = "false"
  udp_options {
    destination_port_range {
      max = "51820"
      min = "51820"
    }
    #source_port_range = <<Optional value not found in discovery>>
  }
}

####
## SECURITY LISTS
####
resource "oci_core_default_security_list" "default-seclist" {
  compartment_id = local.availability_domain
  display_name   = "Default Security List for mainvcn"
  
  # Egress rule - allow all outbound traffic (IPv4)
  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    stateless        = "false"
    #icmp_options = <<Optional value not found in discovery>>
    #tcp_options = <<Optional value not found in discovery>>
    #udp_options = <<Optional value not found in discovery>>
  }
  
  # Egress rule - allow all outbound traffic (IPv6)
  egress_security_rules {
    destination      = "::/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    stateless        = "false"
  }
  
  freeform_tags = {
  }
  
  # Rule 1: SSH access from anywhere (IPv4)
  ingress_security_rules {
    #description = <<Optional value not found in discovery>>
    protocol    = "6" # TCP
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    stateless   = "false"
    tcp_options {
      min = 22
      max = 22
      #source_port_range = <<Optional value not found in discovery>>
    }
  }
  
  # Rule 1b: SSH access from anywhere (IPv6)
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "::/0"
    source_type = "CIDR_BLOCK"
    stateless   = "false"
    tcp_options {
      min = 22
      max = 22
    }
  }
  
  # Rule 2: ICMP type 3, code 4 from anywhere (IPv4) - Fragmentation Needed
  ingress_security_rules {
    protocol    = "1" # ICMP
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    stateless   = "false"
    icmp_options {
      type = 3
      code = 4
    }
  }
  
  # Rule 2b: ICMPv6 type 1 from anywhere (IPv6) - Destination Unreachable
  ingress_security_rules {
    protocol    = "58" # ICMPv6
    source      = "::/0"
    source_type = "CIDR_BLOCK"
    stateless   = "false"
    icmp_options {
      type = 1
      code = 0
    }
  }
  
  # Rule 3: ICMP type 3 from VCN subnet (IPv4) - Destination Unreachable
  ingress_security_rules {
    protocol    = "1" # ICMP
    source      = "172.16.0.0/16"
    source_type = "CIDR_BLOCK"
    stateless   = "false"
    icmp_options {
      type = 3
      code = -1 # All codes for type 3
    }
  }
  
  # Rule 3b: ICMPv6 from VCN subnet (IPv6) - Destination Unreachable
  ingress_security_rules {
    protocol    = "58" # ICMPv6
    source      = "fd00::/64"
    source_type = "CIDR_BLOCK"
    stateless   = "false"
    icmp_options {
      type = 1
      code = -1 # All codes for type 1
    }
  }
  
  # Rule 4: All protocols from anywhere (IPv4) - open all ingress traffic
  ingress_security_rules {
    protocol    = "all"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    stateless   = "false"
    #tcp_options = <<Optional value not found in discovery>>
    #udp_options = <<Optional value not found in discovery>>
  }
  
  # Rule 4b: All protocols from anywhere (IPv6) - open all ingress traffic
  ingress_security_rules {
    protocol    = "all"
    source      = "::/0"
    source_type = "CIDR_BLOCK"
    stateless   = "false"
  }
  
  manage_default_resource_id = oci_core_vcn.main_vcn.default_security_list_id
  lifecycle {
    create_before_destroy = true
  }
}


# if default open 443 is wanted
#resource "oci_core_security_list" "https_security_list" {
#  compartment_id = local.availability_domain
#  vcn_id         = oci_core_vcn.main_vcn.id
#  display_name   = "https_security_list"

#  ingress_security_rules {
#    protocol = "6"         #TCP
#    source   = "0.0.0.0/0" #Allow access from any IP address
#    tcp_options {
#      min = 443 #https port
#      max = 443 #https port
#    }
#  }
#}
