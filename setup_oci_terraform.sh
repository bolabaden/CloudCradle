#!/bin/bash

# Oracle Cloud Infrastructure (OCI) Terraform Setup Script
# This script automates the setup of OCI CLI and fetches all required variables for Terraform

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install OCI CLI
install_oci_cli() {
    print_status "Installing OCI CLI..."
    
    # Check if Python is installed
    if ! command_exists python3; then
        print_status "Python 3 not found. Installing Python 3..."
        sudo apt-get update
        sudo apt-get install -y python3 python3-venv python3-pip
    fi
    
    # Create a virtual environment for OCI CLI to avoid externally-managed-environment errors
    if [ ! -d ".venv" ]; then
        print_status "Creating Python virtual environment for OCI CLI..."
        python3 -m venv .venv
    fi
    
    source .venv/bin/activate
    
    # Install OCI CLI in the virtual environment
    print_status "Installing OCI CLI in virtual environment..."
    pip install --upgrade pip
    pip install oci-cli
    
    # Add the virtual environment activation to .bashrc for future use
    if ! grep -q "source $(pwd)/.venv/bin/activate" ~/.bashrc; then
        echo "# OCI CLI virtual environment" >> ~/.bashrc
        echo "source $(pwd)/.venv/bin/activate" >> ~/.bashrc
    fi
    
    print_success "OCI CLI installed successfully."
}

# Function to setup OCI CLI config automatically
setup_oci_config() {
    print_status "Setting up OCI CLI configuration..."
    
    # Create .oci directory if it doesn't exist
    mkdir -p ~/.oci
    
    if [ ! -f ~/.oci/config ]; then
        print_status "No existing OCI config found. Setting up new configuration..."
        
        # Use browser-based authentication instead of manual API key setup
        print_status "Setting up browser-based authentication..."
        print_status "This will open a browser window for you to log in to Oracle Cloud."
        print_status "After login, the CLI will automatically configure authentication."
        
        # Run the session authenticate command
        if ! oci session authenticate; then
            print_error "Browser authentication failed. Please try again."
            exit 1
        fi
        
        print_success "Browser authentication completed successfully!"
        
        # Test the configuration
        print_status "Testing OCI CLI configuration..."
        if ! test_oci_connectivity; then
            print_error "OCI CLI configuration test failed. Please check your setup."
            exit 1
        fi
        
        print_success "OCI CLI configuration test passed!"
        
    else
        print_status "Using existing OCI configuration at ~/.oci/config"
        
        # Test existing configuration
        print_status "Testing existing OCI CLI configuration..."
        if ! test_oci_connectivity; then
            print_error "Existing OCI CLI configuration test failed."
            print_status "Attempting to refresh authentication..."
            
            # Try to refresh the session
            if oci session authenticate; then
                print_success "Authentication refreshed successfully!"
            else
                print_error "Failed to refresh authentication. Please check your setup."
                exit 1
            fi
        else
            print_success "Existing OCI CLI configuration test passed!"
        fi
    fi
}

# Function to test OCI connectivity properly (updated for session tokens)
test_oci_connectivity() {
    # Try multiple methods to test connectivity
    local tenancy_ocid=$(grep -oP '(?<=tenancy=).*' ~/.oci/config | head -1)
    
    # Method 1: Try to list regions (most basic test)
    if oci iam region list >/dev/null 2>&1; then
        return 0
    fi
    
    # Method 2: Try to get tenancy information
    if [ -n "$tenancy_ocid" ] && oci iam tenancy get --tenancy-id "$tenancy_ocid" >/dev/null 2>&1; then
        return 0
    fi
    
    # Method 3: Try to get compartment information using tenancy as compartment
    if [ -n "$tenancy_ocid" ] && oci iam compartment get --compartment-id "$tenancy_ocid" >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

# Function to fetch fingerprint (updated for session tokens)
fetch_fingerprint() {
    print_status "Checking authentication method..."
    
    # For session token auth, we don't need a fingerprint
    if grep -q "security_token_file" ~/.oci/config; then
        print_status "Using session token authentication - no fingerprint needed"
        fingerprint="session_token_auth"
        return 0
    fi
    
    # Fallback for API key auth if somehow still used
    print_status "Using API key authentication - calculating fingerprint..."
    fingerprint=$(openssl rsa -pubout -outform DER -in ~/.oci/oci_api_key.pem 2>/dev/null | openssl md5 -c | awk '{print $2}')
    
    if [ -z "$fingerprint" ]; then
        print_error "Failed to calculate fingerprint"
        return 1
    fi
    
    print_success "Fingerprint: $fingerprint"
    return 0
}

# Function to fetch user OCID
fetch_user_ocid() {
    print_status "Fetching user OCID..."
    
    # Extract user OCID from config file
    user_ocid=$(grep -oP '(?<=user=).*' ~/.oci/config | head -1)
    
    if [ -z "$user_ocid" ]; then
        print_error "Failed to fetch user OCID from config. Please check your OCI CLI configuration."
        return 1
    fi
    
    print_success "User OCID: $user_ocid"
    return 0
}

# Function to fetch tenancy OCID
fetch_tenancy_ocid() {
    print_status "Fetching tenancy OCID..."
    
    # Extract tenancy OCID from config file
    tenancy_ocid=$(grep -oP '(?<=tenancy=).*' ~/.oci/config | head -1)
    
    if [ -z "$tenancy_ocid" ]; then
        print_error "Failed to fetch tenancy OCID from config. Please check your OCI CLI configuration."
        return 1
    fi
    
    print_success "Tenancy OCID: $tenancy_ocid"
    return 0
}

# Function to fetch region
fetch_region() {
    print_status "Fetching region..."
    
    # Extract region from config file
    region=$(grep -oP '(?<=region=).*' ~/.oci/config | head -1)
    
    if [ -z "$region" ]; then
        print_error "Failed to fetch region from config. Please check your OCI CLI configuration."
        return 1
    fi
    
    print_success "Region: $region"
    return 0
}

# Function to fetch availability domains
fetch_availability_domains() {
    print_status "Fetching availability domains for region $region..."
    
    # Get all availability domains in the region using tenancy as compartment
    availability_domains=$(oci iam availability-domain list --compartment-id "$tenancy_ocid" --query "data[].name" --raw-output 2>/dev/null)
    
    if [ -z "$availability_domains" ]; then
        print_error "Failed to fetch availability domains. Please check your OCI CLI configuration."
        return 1
    fi
    
    # Parse the JSON array properly - the output is a JSON array
    availability_domain=$(echo "$availability_domains" | jq -r '.[0]' 2>/dev/null || echo "$availability_domains" | head -1 | tr -d '[]"')
    
    if [ -z "$availability_domain" ] || [ "$availability_domain" == "null" ]; then
        print_error "Failed to parse availability domain from response: $availability_domains"
        return 1
    fi
    
    print_success "Selected availability domain: $availability_domain"
    return 0
}

# Function to fetch Ubuntu image OCID for the region dynamically
fetch_region_images() {
    print_status "Fetching Ubuntu image OCID for region $region..."
    
    # Try to get Ubuntu 22.04 LTS image first
    ubuntu_image_ocid=$(oci compute image list \
        --compartment-id "$tenancy_ocid" \
        --operating-system "Canonical Ubuntu" \
        --operating-system-version "22.04" \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --query "data[0].id" \
        --raw-output 2>/dev/null)
    
    # If no 22.04 found, try any Ubuntu LTS
    if [ -z "$ubuntu_image_ocid" ] || [ "$ubuntu_image_ocid" == "null" ]; then
        print_warning "Ubuntu 22.04 not found, trying Ubuntu 20.04 LTS..."
        ubuntu_image_ocid=$(oci compute image list \
            --compartment-id "$tenancy_ocid" \
            --operating-system "Canonical Ubuntu" \
            --operating-system-version "20.04" \
            --sort-by TIMECREATED \
            --sort-order DESC \
            --query "data[0].id" \
            --raw-output 2>/dev/null)
    fi
    
    # If still no LTS found, try any Ubuntu
    if [ -z "$ubuntu_image_ocid" ] || [ "$ubuntu_image_ocid" == "null" ]; then
        print_warning "Ubuntu LTS versions not found, trying any Ubuntu image..."
        ubuntu_image_ocid=$(oci compute image list \
            --compartment-id "$tenancy_ocid" \
            --operating-system "Canonical Ubuntu" \
            --sort-by TIMECREATED \
            --sort-order DESC \
            --query "data[0].id" \
            --raw-output 2>/dev/null)
    fi
    
    if [ -z "$ubuntu_image_ocid" ] || [ "$ubuntu_image_ocid" == "null" ]; then
        print_error "Failed to fetch Ubuntu image OCID. Please check available images in your region."
        print_status "You can list available images with: oci compute image list --compartment-id $tenancy_ocid"
        return 1
    fi
    
    # Get the image details for verification
    image_details=$(oci compute image get --image-id "$ubuntu_image_ocid" --query "data.{name:\"display-name\",os:\"operating-system\",version:\"operating-system-version\"}" 2>/dev/null)
    print_success "Found Ubuntu image: $image_details"
    print_success "Ubuntu image OCID: $ubuntu_image_ocid"
    
    # Also fetch ARM-based Ubuntu image for A1.Flex instances
    print_status "Fetching ARM Ubuntu image OCID for A1.Flex instances..."
    ubuntu_arm_flex_image_ocid=$(oci compute image list \
        --compartment-id "$tenancy_ocid" \
        --operating-system "Canonical Ubuntu" \
        --operating-system-version "22.04" \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --query "data[?contains(\"display-name\", 'aarch64')].id | [0]" \
        --raw-output 2>/dev/null)
    
    if [ -z "$ubuntu_arm_flex_image_ocid" ] || [ "$ubuntu_arm_flex_image_ocid" == "null" ]; then
        # Fallback to the same image if ARM-specific not found
        ubuntu_arm_flex_image_ocid="$ubuntu_image_ocid"
        print_warning "ARM-specific Ubuntu image not found, using x86 image: $ubuntu_arm_flex_image_ocid"
    else
        print_success "ARM Ubuntu image OCID: $ubuntu_arm_flex_image_ocid"
    fi
    
    return 0
}

# Function to generate SSH keys
generate_ssh_keys() {
    print_status "Generating SSH key pair for instance access..."
    
    ssh_dir="$PWD/ssh_keys"
    mkdir -p "$ssh_dir"
    
    if [ ! -f "$ssh_dir/id_rsa" ]; then
        ssh-keygen -t rsa -b 2048 -f "$ssh_dir/id_rsa" -N ""
        chmod 600 "$ssh_dir/id_rsa"
        chmod 644 "$ssh_dir/id_rsa.pub"
        print_success "SSH key pair generated at $ssh_dir/id_rsa"
    else
        print_status "Using existing SSH key pair at $ssh_dir/id_rsa"
    fi
    
    ssh_public_key=$(cat "$ssh_dir/id_rsa.pub")
    print_success "SSH public key ready for instance deployment"
    return 0
}

# Function to prompt user for ARM instance configuration
prompt_arm_flex_instance_config() {
    print_status "Configuring ARM instance setup for Oracle Free Tier..."
    print_status "Oracle Free Tier allows:"
    print_status "  - 200GB total storage across all instances"
    print_status "  - 2x AMD x86 micro instances (VM.Standard.E2.1.Micro):"
    print_status "      * 1 OCPU, 1GB RAM each"
    print_status "      * recommended split: 15-20GB boot volume each (total 30-40GB)"
    print_status "  - 4 OCPUs + 24GB RAM total for ARM (Ampere) instances"
    print_status ""
    print_status "By default, this setup will always create the 2 free AMD x86 micro instances."
    print_status "You can now choose how to allocate your ARM (Ampere) resources:"
    print_status ""
    print_status "Recommended splits (examples):"
    print_status "  1) Static Site + CMS: Micros 2x20GB, Flex 1x60GB boot + 100GB block"
    print_status "  2) CI/CD: Micros 2x15GB, Flex 1x50GB boot + 80GB block"
    print_status "  3) VPN Bastion: Micros 2x10GB, Flex 1x30GB boot + 150GB block"
    print_status "  4) Monitoring: Micros 2x10GB, Flex 1x80GB boot"
    print_status "  5) K8s: Micros 2x20GB, Flex 1x40GB boot + 120GB block"
    print_status "  6) Message Broker: Micros 2x15GB, Flex 1x30GB boot + 120GB block"
    print_status "  7) Dev Sandboxes: Micros 2x20GB, Flex 1x40GB boot + 120GB block"
    print_status "  8) API Gateway: Micros 2x20GB, Flex 1x40GB boot + 120GB block"
    print_status "  9) Reverse Proxy: Micros 2x15GB, Flex 1x30GB boot + 140GB block"
    print_status " 10) IoT Gateway: Micros 2x15GB, Flex 1x40GB boot + 145GB block"
    print_status ""
    print_status "You can also customize the split below."
    print_status ""
    print_status "ARM Instance Configuration Options:"
    print_status "  1) Single ARM instance: 4 cores, 24GB RAM, custom boot + block volume"
    print_status "  2) Two ARM instances: 2 cores, 12GB RAM each, custom boot + block volumes"
    print_status "  3) Three ARM instances (Recommended!): 2+1+1 cores, 12+6+6GB RAM, custom boot + block volumes"
    print_status "     - App & DB: 2 cores, 12GB, 60GB boot, 80GB block (default)"
    print_status "     - CI/CD & Monitoring: 1 core, 6GB, 30GB boot, 20GB block (default)"
    print_status "     - Experimental/Sandbox: 1 core, 6GB, 30GB boot, 0GB block (default)"
    print_status "  4) Custom: Fully manual entry for all values (instance count, OCPUs, RAM, boot, block)"
    print_status ""

    # Prompt for micro instance boot volume size
    while true; do
        echo -n -e "${BLUE}Enter boot volume size (GB) for each AMD micro instance [15-30, default 20]: ${NC}"
        read -r micro_boot
        micro_boot=${micro_boot:-20}
        if [[ "$micro_boot" =~ ^[0-9]+$ ]] && [ "$micro_boot" -ge 10 ] && [ "$micro_boot" -le 30 ]; then
            break
        else
            print_error "Please enter a number between 10 and 30."
        fi
    done
    amd_micro_instance_count=2
    amd_micro_boot_volume_size_gb=$micro_boot

    # ARM config prompt loop
    while true; do
        echo -n -e "${BLUE}Choose ARM configuration (1=single, 2=dual, 3=triple [default], 4=custom): ${NC}"
        read -r arm_flex_choice
        arm_flex_choice=${arm_flex_choice:-3}
        case $arm_flex_choice in
            1)
                arm_flex_instance_count=1
                arm_flex_ocpus_per_instance=4
                arm_flex_memory_per_instance=24
                echo -n -e "${BLUE}Enter boot volume size (GB) for ARM instance [30-100, default 60]: ${NC}"
                read -r arm_flex_boot
                arm_flex_boot=${arm_flex_boot:-60}
                if [ "$arm_flex_boot" -lt 30 ] || [ "$arm_flex_boot" -gt 100 ]; then arm_flex_boot=60; fi
                arm_flex_boot_volume_size_gb=$arm_flex_boot
                echo -n -e "${BLUE}Enter block volume size (GB) for ARM instance [0-170, default 100]: ${NC}"
                read -r arm_flex_block
                arm_flex_block=${arm_flex_block:-100}
                if [ "$arm_flex_block" -lt 0 ] || [ "$arm_flex_block" -gt 170 ]; then arm_flex_block=100; fi
                arm_flex_block_volumes=($arm_flex_block)
                ;;
            2)
                arm_flex_instance_count=2
                arm_flex_ocpus_per_instance="2 2"
                arm_flex_memory_per_instance="12 12"
                echo -n -e "${BLUE}Enter boot volume size (GB) for each ARM instance [20-60, default 30]: ${NC}"
                read -r arm_flex_boot
                arm_flex_boot=${arm_flex_boot:-30}
                if [ "$arm_flex_boot" -lt 20 ] || [ "$arm_flex_boot" -gt 60 ]; then arm_flex_boot=30; fi
                arm_flex_boot_volume_size_gb="$arm_flex_boot $arm_flex_boot"
                echo -n -e "${BLUE}Enter block volume size (GB) for ARM instance 1 [0-160, default 60]: ${NC}"
                read -r arm_flex_block1
                arm_flex_block1=${arm_flex_block1:-60}
                if [ "$arm_flex_block1" -lt 0 ] || [ "$arm_flex_block1" -gt 160 ]; then arm_flex_block1=60; fi
                echo -n -e "${BLUE}Enter block volume size (GB) for ARM instance 2 [0-160, default 60]: ${NC}"
                read -r arm_flex_block2
                arm_flex_block2=${arm_flex_block2:-60}
                if [ "$arm_flex_block2" -lt 0 ] || [ "$arm_flex_block2" -gt 160 ]; then arm_flex_block2=60; fi
                arm_flex_block_volumes=($arm_flex_block1 $arm_flex_block2)
                ;;
            3)
                arm_flex_instance_count=3
                arm_flex_ocpus_per_instance="2 1 1"
                arm_flex_memory_per_instance="12 6 6"
                # Pre-fill with your recommended values
                arm_flex_boot1=60; arm_flex_boot2=30; arm_flex_boot3=30
                arm_flex_block1=80; arm_flex_block2=20; arm_flex_block3=0
                echo -n -e "${BLUE}Use recommended three Flex VMs split? (Y/n): ${NC}"
                read -r use_default
                use_default=${use_default:-Y}
                if [[ ! "$use_default" =~ ^[Nn]$ ]]; then
                    arm_flex_boot_volume_size_gb="$arm_flex_boot1 $arm_flex_boot2 $arm_flex_boot3"
                    arm_flex_block_volumes=($arm_flex_block1 $arm_flex_block2 $arm_flex_block3)
                else
                    echo -n -e "${BLUE}Enter boot volume size (GB) for ARM instance 1 [20-60, default 60]: ${NC}"
                    read -r arm_flex_boot1
                    arm_flex_boot1=${arm_flex_boot1:-60}
                    if [ "$arm_flex_boot1" -lt 20 ] || [ "$arm_flex_boot1" -gt 60 ]; then arm_flex_boot1=60; fi
                    echo -n -e "${BLUE}Enter boot volume size (GB) for ARM instance 2 [20-60, default 30]: ${NC}"
                    read -r arm_flex_boot2
                    arm_flex_boot2=${arm_flex_boot2:-30}
                    if [ "$arm_flex_boot2" -lt 20 ] || [ "$arm_flex_boot2" -gt 60 ]; then arm_flex_boot2=30; fi
                    echo -n -e "${BLUE}Enter boot volume size (GB) for ARM instance 3 [20-60, default 30]: ${NC}"
                    read -r arm_flex_boot3
                    arm_flex_boot3=${arm_flex_boot3:-30}
                    if [ "$arm_flex_boot3" -lt 20 ] || [ "$arm_flex_boot3" -gt 60 ]; then arm_flex_boot3=30; fi
                    arm_flex_boot_volume_size_gb="$arm_flex_boot1 $arm_flex_boot2 $arm_flex_boot3"
                    echo -n -e "${BLUE}Enter block volume size (GB) for ARM instance 1 [0-160, default 80]: ${NC}"
                    read -r arm_flex_block1
                    arm_flex_block1=${arm_flex_block1:-80}
                    if [ "$arm_flex_block1" -lt 0 ] || [ "$arm_flex_block1" -gt 160 ]; then arm_flex_block1=80; fi
                    echo -n -e "${BLUE}Enter block volume size (GB) for ARM instance 2 [0-160, default 20]: ${NC}"
                    read -r arm_flex_block2
                    arm_flex_block2=${arm_flex_block2:-20}
                    if [ "$arm_flex_block2" -lt 0 ] || [ "$arm_flex_block2" -gt 160 ]; then arm_flex_block2=20; fi
                    echo -n -e "${BLUE}Enter block volume size (GB) for ARM instance 3 [0-160, default 0]: ${NC}"
                    read -r arm_flex_block3
                    arm_flex_block3=${arm_flex_block3:-0}
                    if [ "$arm_flex_block3" -lt 0 ] || [ "$arm_flex_block3" -gt 160 ]; then arm_flex_block3=0; fi
                    arm_flex_block_volumes=($arm_flex_block1 $arm_flex_block2 $arm_flex_block3)
                fi
                ;;
            4)
                echo -n -e "${BLUE}Enter number of ARM instances: ${NC}"
                read -r arm_flex_instance_count
                arm_flex_ocpus_per_instance=""
                arm_flex_memory_per_instance=""
                arm_flex_boot_volume_size_gb=""
                arm_flex_block_volumes=()
                for ((i=1; i<=arm_flex_instance_count; i++)); do
                    echo -n -e "${BLUE}Enter OCPUs for ARM instance $i: ${NC}"
                    read -r ocpu
                    arm_flex_ocpus_per_instance+="$ocpu "
                    echo -n -e "${BLUE}Enter RAM (GB) for ARM instance $i: ${NC}"
                    read -r ram
                    arm_flex_memory_per_instance+="$ram "
                    echo -n -e "${BLUE}Enter boot volume size (GB) for ARM instance $i: ${NC}"
                    read -r boot
                    arm_flex_boot_volume_size_gb+="$boot "
                    echo -n -e "${BLUE}Enter block volume size (GB) for ARM instance $i: ${NC}"
                    read -r block
                    arm_flex_block_volumes+=("$block")
                done
                # Trim trailing spaces
                arm_flex_ocpus_per_instance=$(echo $arm_flex_ocpus_per_instance)
                arm_flex_memory_per_instance=$(echo $arm_flex_memory_per_instance)
                arm_flex_boot_volume_size_gb=$(echo $arm_flex_boot_volume_size_gb)
                ;;
            *)
                print_error "Invalid choice. Please enter 1, 2, 3, or 4."
                continue
                ;;
        esac

        # Calculate total storage
        total_boot=0
        for b in $amd_micro_boot_volume_size_gb; do total_boot=$((total_boot + b)); done
        for b in $arm_flex_boot_volume_size_gb; do total_boot=$((total_boot + b)); done
        total_block=0
        for b in "${arm_flex_block_volumes[@]}"; do total_block=$((total_block + b)); done
        total_storage=$((total_boot + total_block))

        print_status "Final Free Tier Configuration:"
        print_status "  - 2x AMD x86 micro instances: $amd_micro_boot_volume_size_gb GB boot each"
        print_status "  - $arm_flex_instance_count ARM instance(s):"
        for ((i=1; i<=arm_flex_instance_count; i++)); do
            ocpu=$(echo $arm_flex_ocpus_per_instance | cut -d' ' -f$i)
            ram=$(echo $arm_flex_memory_per_instance | cut -d' ' -f$i)
            boot=$(echo $arm_flex_boot_volume_size_gb | cut -d' ' -f$i)
            block=${arm_flex_block_volumes[$((i-1))]}
            print_status "      * Instance $i: $ocpu OCPU, $ram GB RAM, $boot GB boot, $block GB block"
        done
        print_status "  - Total boot volume usage: $total_boot GB"
        print_status "  - Total block volume usage: $total_block GB"
        print_status "  - Total storage usage: $total_storage GB / 200 GB allowed"
        if [ "$total_storage" -gt 200 ]; then
            print_warning "WARNING: Your total storage exceeds the 200GB Free Tier limit! Please adjust your choices."
            echo -n -e "${YELLOW}Would you like to re-enter values? (Y/n): ${NC}"
            read -r retry
            retry=${retry:-Y}
            if [[ "$retry" =~ ^[Yy]$ ]]; then
                continue
            fi
        fi
        print_status ""
        break
    done
}

# Function to prompt user for instance hostnames
prompt_instance_hostnames() {
    print_status "Configuring instance hostnames..."
    print_status "You can customize the hostnames for your instances."
    print_status "Default pattern is: amd-instance-1, amd-instance-2, arm-instance-1, etc."
    print_status ""
    
    # AMD instance hostnames
    amd_micro_hostnames=()
    for ((i=1; i<=amd_micro_instance_count; i++)); do
        default_hostname="amd-instance-$i"
        echo -n -e "${BLUE}Enter hostname for AMD instance $i [default: $default_hostname]: ${NC}"
        read -r hostname
        hostname=${hostname:-$default_hostname}
        # Validate hostname (basic validation)
        if [[ "$hostname" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$ ]] && [ ${#hostname} -le 63 ]; then
            amd_micro_hostnames+=("$hostname")
        else
            print_warning "Invalid hostname format. Using default: $default_hostname"
            amd_micro_hostnames+=("$default_hostname")
        fi
    done
    
    # ARM instance hostnames
    arm_flex_hostnames=()
    for ((i=1; i<=arm_flex_instance_count; i++)); do
        default_hostname="arm-instance-$i"
        echo -n -e "${BLUE}Enter hostname for ARM instance $i [default: $default_hostname]: ${NC}"
        read -r hostname
        hostname=${hostname:-$default_hostname}
        # Validate hostname (basic validation)
        if [[ "$hostname" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$ ]] && [ ${#hostname} -le 63 ]; then
            arm_flex_hostnames+=("$hostname")
        else
            print_warning "Invalid hostname format. Using default: $default_hostname"
            arm_flex_hostnames+=("$default_hostname")
        fi
    done
    
    print_success "Hostnames configured:"
    print_status "  AMD instances: ${amd_micro_hostnames[*]}"
    print_status "  ARM instances: ${arm_flex_hostnames[*]}"
}

# Function to create Terraform variables file (updated to include hostnames)
create_terraform_vars() {
    print_status "Creating variables.tf with fetched values..."
    
    # Backup existing file if it exists
    if [ -f "variables.tf" ]; then
        cp variables.tf "variables.tf.bak.$(date +%Y%m%d_%H%M%S)"
        print_status "Backed up existing variables.tf with timestamp"
    fi
    
    # Check if using session token auth
    local auth_method="api_key"
    local fingerprint_value="$fingerprint"
    local private_key_path="pathexpand(\"~/.oci/oci_api_key.pem\")"
    
    if grep -q "security_token_file" ~/.oci/config; then
        auth_method="session_token"
        fingerprint_value="session_token_auth"
        private_key_path="null"  # Not needed for session tokens
    fi
    
    # Convert hostname arrays to Terraform list format
    local amd_micro_hostnames_tf="["
    for ((i=0; i<${#amd_micro_hostnames[@]}; i++)); do
        if [ $i -gt 0 ]; then
            amd_micro_hostnames_tf+=", "
        fi
        amd_micro_hostnames_tf+="\"${amd_micro_hostnames[$i]}\""
    done
    amd_micro_hostnames_tf+="]"
    
    local arm_flex_hostnames_tf="["
    for ((i=0; i<${#arm_flex_hostnames[@]}; i++)); do
        if [ $i -gt 0 ]; then
            arm_flex_hostnames_tf+=", "
        fi
        arm_flex_hostnames_tf+="\"${arm_flex_hostnames[$i]}\""
    done
    arm_flex_hostnames_tf+="]"
    
    # Create variables.tf with all dynamically fetched values
    cat > variables.tf << EOF
# Automatically generated OCI Terraform variables
# Generated on: $(date)
# Region: $region
# Authentication: $auth_method
# ARM Configuration: ${arm_flex_instance_count}x instances with ${arm_flex_ocpus_per_instance} cores, ${arm_flex_memory_per_instance}GB RAM each

locals {
  # Per README: availability_domain == tenancy-ocid == compartment_id
  availability_domain  = "$tenancy_ocid"
  compartment_id       = "$tenancy_ocid"
  
  # Dynamically fetched Ubuntu images for region $region
  ubuntu2404ocid       = "$ubuntu_image_ocid"
  ubuntu2404_arm_flex_ocid  = "$ubuntu_arm_flex_image_ocid"
  
  # OCI Authentication
  user_ocid            = "$user_ocid"
  fingerprint          = "$fingerprint_value"
  private_api_key_path = $private_key_path
  tenancy_ocid         = "$tenancy_ocid"
  region               = "$region"
  
  # SSH Configuration
  ssh_pubkey_path      = pathexpand("./ssh_keys/id_rsa.pub")
  ssh_pubkey_data      = file(pathexpand("./ssh_keys/id_rsa.pub"))
  ssh_private_key_path = pathexpand("./ssh_keys/id_rsa")
  
  # Oracle Free Tier Instance Configuration
  # AMD x86 instances (Always Free Eligible)
  amd_micro_instance_count        = 2
  amd_micro_boot_volume_size_gb   = $amd_micro_boot_volume_size_gb
  amd_micro_hostnames             = $amd_micro_hostnames_tf
  
  # ARM instances configuration (user-selected)
  arm_flex_instance_count        = $arm_flex_instance_count
  arm_flex_ocpus_per_instance    = $arm_flex_ocpus_per_instance
  arm_flex_memory_per_instance   = $arm_flex_memory_per_instance
  arm_flex_boot_volume_size_gb   = $arm_flex_boot_volume_size_gb
  arm_flex_hostnames             = $arm_flex_hostnames_tf
  
  # Boot volume usage validation
  total_boot_volume_gb = local.amd_micro_instance_count * local.amd_micro_boot_volume_size_gb + local.arm_flex_instance_count * local.arm_flex_boot_volume_size_gb
}

# Additional variables for reference
variable "availability_domain_name" {
  description = "The availability domain name"
  type        = string
  default     = "$availability_domain"
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
    error_message = "Total boot volume usage (\${local.total_boot_volume_gb}GB) exceeds Oracle Free Tier limit (\${var.max_free_tier_boot_volume_gb}GB)."
  }
}
EOF
    
    print_success "variables.tf created successfully with all required values."
    print_status "Variables file contains:"
    print_status "  - Tenancy OCID: $tenancy_ocid"
    print_status "  - User OCID: $user_ocid"
    print_status "  - Region: $region"
    print_status "  - Ubuntu x86 Image OCID: $ubuntu_image_ocid"
    print_status "  - Ubuntu ARM Image OCID: $ubuntu_arm_flex_image_ocid"
    print_status "  - Authentication: $auth_method"
    if [ "$auth_method" = "api_key" ]; then
        print_status "  - API Key Fingerprint: $fingerprint"
    fi
    print_status "  - SSH Keys: ./ssh_keys/id_rsa"
    print_status "  - AMD Hostnames: ${amd_micro_hostnames[*]}"
    print_status "  - ARM Hostnames: ${arm_flex_hostnames[*]}"
    return 0
}

# Function to verify all requirements are met (updated for session tokens)
verify_setup() {
    print_status "Verifying complete setup..."
    
    # Check required files exist (adjusted for session tokens)
    local required_files=(
        "$HOME/.oci/config"
        "./ssh_keys/id_rsa"
        "./ssh_keys/id_rsa.pub"
        "./variables.tf"
    )
    
    # Add API key files only if not using session tokens
    if ! grep -q "security_token_file" ~/.oci/config; then
        required_files+=("$HOME/.oci/oci_api_key.pem")
        required_files+=("$HOME/.oci/oci_api_key_public.pem")
    fi
    
    for file in "${required_files[@]}"; do
        if [ ! -f "$file" ]; then
            print_error "Required file missing: $file"
            return 1
        fi
    done
    
    # Test OCI CLI connectivity
    print_status "Testing OCI CLI connectivity..."
    if ! test_oci_connectivity; then
        print_error "OCI CLI connectivity test failed"
        return 1
    fi
    
    # Verify Terraform variables are valid
    print_status "Validating Terraform variables..."
    if ! grep -q "ubuntu2404ocid.*ocid1.image" variables.tf; then
        print_error "Invalid Ubuntu image OCID in variables.tf"
        return 1
    fi
    
    if ! grep -q "ubuntu2404_arm_flex_ocid.*ocid1.image" variables.tf; then
        print_error "Invalid Ubuntu ARM image OCID in variables.tf"
        return 1
    fi
    
    print_success "All setup verification checks passed!"
    return 0
}

# Main execution
main() {
    print_status "Starting comprehensive OCI Terraform setup script..."
    print_status "This script will set up everything needed to run 'terraform init' and 'terraform apply'"
    print_status "Using browser-based authentication for simplified setup"
    
    # Install required system packages
    print_status "Installing required system packages..."
    if ! command_exists jq; then
        sudo apt-get update
        sudo apt-get install -y jq openssl curl
    fi
    if ! command_exists awk; then
        sudo apt-get update
        sudo apt-get install -y mawk
    fi
    if ! command_exists grep; then
        sudo apt-get update
        sudo apt-get install -y grep
    fi

    # Check whether required commands were installed.
    required_commands=("jq" "openssl" "ssh-keygen" "awk" "grep" "tr")
    for cmd in "${required_commands[@]}"; do
    if ! command_exists "$cmd"; then
        print_error "$cmd is required but not installed."
        exit 1
    fi
    done
    
    # Install OCI CLI
    install_oci_cli
    
    # Ensure we're in the virtual environment
    source .venv/bin/activate
    
    # Setup OCI config (this handles browser authentication)
    setup_oci_config
    
    # Fetch all required information
    fetch_fingerprint
    fetch_user_ocid
    fetch_tenancy_ocid
    fetch_region
    fetch_availability_domains
    fetch_region_images
    
    # Generate SSH keys
    generate_ssh_keys
    
    # Prompt for ARM instance configuration
    prompt_arm_flex_instance_config
    
    # Prompt for instance hostnames
    prompt_instance_hostnames
    
    # Create Terraform variables
    create_terraform_vars
    
    # Verify everything is set up correctly
    verify_setup
    
    print_success "==================== SETUP COMPLETE ===================="
    print_success "OCI Terraform setup completed successfully!"
    print_status "Next steps:"
    print_status "  1. mv ./ssh_keys/id_rsa* ~/.ssh/id_rsa*"
    print_status "  2. terraform init"
    print_status "  3. terraform plan"
    print_status "  4. terraform apply"
    print_status ""
    print_status "Files created:"
    print_status "  - ~/.oci/config (OCI CLI configuration with session token)"
    if grep -q "security_token_file" ~/.oci/config; then
        print_status "  - ~/.oci/sessions/ (Session token files)"
    else
        print_status "  - ~/.oci/oci_api_key.pem (Private API key)"
        print_status "  - ~/.oci/oci_api_key_public.pem (Public API key)"
    fi
    print_status "  - ./ssh_keys/id_rsa (SSH private key)"
    print_status "  - ./ssh_keys/id_rsa.pub (SSH public key)"
    print_status "  - ./variables.tf (Terraform variables)"
    print_status "========================================================="
}

# Execute main function
main "$@"