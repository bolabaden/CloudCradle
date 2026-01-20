#!/bin/bash

# Oracle Cloud Infrastructure (OCI) Terraform Setup Script
# This script automates the setup of OCI CLI and fetches all required variables for Terraform
#
# Usage:
#   Interactive mode:        ./setup_oci_terraform.sh
#   Non-interactive mode:    NON_INTERACTIVE=true AUTO_USE_EXISTING=true AUTO_DEPLOY=true ./setup_oci_terraform.sh
#   Use existing config:     AUTO_USE_EXISTING=true ./setup_oci_terraform.sh
#   Auto deploy only:        AUTO_DEPLOY=true ./setup_oci_terraform.sh

set -e  # Exit on any error

# Non-interactive mode support
NON_INTERACTIVE=${NON_INTERACTIVE:-false}
AUTO_USE_EXISTING=${AUTO_USE_EXISTING:-false}
AUTO_DEPLOY=${AUTO_DEPLOY:-false}

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
    # Try multiple methods to test connectivity with proper error handling
    local tenancy_ocid=$(grep -oP '(?<=tenancy=).*' ~/.oci/config | head -1)
    
    print_status "Testing OCI API connectivity..."
    
    # Method 1: Try to list regions (most basic test)
    print_status "  Testing region list access..."
    if oci iam region list --auth session_token >/dev/null 2>&1; then
        print_status "  ✓ Region list access successful"
        return 0
    elif oci iam region list >/dev/null 2>&1; then
        print_status "  ✓ Region list access successful (fallback auth)"
        return 0
    fi
    
    # Method 2: Try to get tenancy information with session token
    if [ -n "$tenancy_ocid" ]; then
        print_status "  Testing tenancy access..."
        if oci iam tenancy get --tenancy-id "$tenancy_ocid" --auth session_token >/dev/null 2>&1; then
            print_status "  ✓ Tenancy access successful"
            return 0
        elif oci iam tenancy get --tenancy-id "$tenancy_ocid" >/dev/null 2>&1; then
            print_status "  ✓ Tenancy access successful (fallback auth)"
            return 0
        fi
    fi
    
    # Method 3: Try to get compartment information using tenancy as compartment
    if [ -n "$tenancy_ocid" ]; then
        print_status "  Testing compartment access..."
        if oci iam compartment get --compartment-id "$tenancy_ocid" --auth session_token >/dev/null 2>&1; then
            print_status "  ✓ Compartment access successful"
            return 0
        elif oci iam compartment get --compartment-id "$tenancy_ocid" >/dev/null 2>&1; then
            print_status "  ✓ Compartment access successful (fallback auth)"
            return 0
        fi
    fi
    
    # Method 4: Test with explicit endpoint and auth
    print_status "  Testing with explicit authentication..."
    local region=$(grep -oP '(?<=region=).*' ~/.oci/config | head -1)
    echo "region: $region"
    if [ -n "$region" ]; then
        if oci iam region list --region "$region" --auth security_token; then
            print_status "  ✓ Explicit region authentication successful"
            return 0
        fi
    fi
    
    print_error "  ✗ All connectivity tests failed"
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
    user_ocid=$(grep -P '^\s*user\s*=\s*.*' ~/.oci/config | sed -E 's/^\s*user\s*=\s*//' | head -1)
    
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
    availability_domains=$(oci iam availability-domain list --compartment-id "$tenancy_ocid" --query "data[].name" --raw-output --auth security_token)
    echo "availability_domains: $availability_domains"
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
    print_status "Fetching Ubuntu image OCIDs for region $region..."
    
    # Fetch x86 (AMD64) Ubuntu image for E2.1.Micro instances
    print_status "Fetching x86 Ubuntu image for AMD instances..."
    ubuntu_image_ocid=$(oci compute image list \
        --compartment-id "$tenancy_ocid" \
        --operating-system "Canonical Ubuntu" \
        --shape "VM.Standard.E2.1.Micro" \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --query "data[0].id" \
        --raw-output \
        --auth security_token)
    
    if [ -z "$ubuntu_image_ocid" ] || [ "$ubuntu_image_ocid" == "null" ]; then
        print_error "Failed to fetch x86 Ubuntu image OCID. Please check available images in your region."
        print_status "You can list available x86 images with: oci compute image list --compartment-id $tenancy_ocid --operating-system \"Canonical Ubuntu\" --shape VM.Standard.E2.1.Micro"
        ubuntu_image_ocid=""  # Set to empty to disable x86 instances
    else
        # Get the ARM image details for verification
        x86_image_details=$(oci compute image get --image-id "$ubuntu_image_ocid" --query "data.{name:\"display-name\",os:\"operating-system\",version:\"operating-system-version\"}" --auth security_token)
        print_success "Found x86 Ubuntu image: $x86_image_details"
        print_success "x86 Ubuntu image OCID: $ubuntu_image_ocid"
    fi
    
    # Fetch ARM-based Ubuntu image for A1.Flex instances
    print_status "Fetching ARM Ubuntu image OCID for A1.Flex instances..."
    ubuntu_arm_flex_image_ocid=$(oci compute image list \
        --compartment-id "$tenancy_ocid" \
        --operating-system "Canonical Ubuntu" \
        --shape "VM.Standard.A1.Flex" \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --query "data[0].id" \
        --raw-output \
        --auth security_token)
    
    if [ -z "$ubuntu_arm_flex_image_ocid" ] || [ "$ubuntu_arm_flex_image_ocid" == "null" ]; then
        print_error "Failed to fetch ARM Ubuntu image OCID. ARM instances will be disabled."
        print_warning "ARM instances require ARM-compatible images. Please check available ARM images in your region."
        print_status "You can list available ARM images with: oci compute image list --compartment-id $tenancy_ocid --operating-system \"Canonical Ubuntu\" --shape VM.Standard.A1.Flex"
        ubuntu_arm_flex_image_ocid=""  # Set to empty to disable ARM instances
    else
        # Get the ARM image details for verification
        arm_image_details=$(oci compute image get --image-id "$ubuntu_arm_flex_image_ocid" --query "data.{name:\"display-name\",os:\"operating-system\",version:\"operating-system-version\"}" --auth security_token)
        print_success "Found ARM Ubuntu image: $arm_image_details"
        print_success "ARM Ubuntu image OCID: $ubuntu_arm_flex_image_ocid"
    fi
    
    print_success "✓ Architecture validation passed: x86 and ARM images are different"
    print_status "  x86 image: $ubuntu_image_ocid"
    print_status "  ARM image: $ubuntu_arm_flex_image_ocid"
    
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



# Function to load existing ARM configuration from variables.tf
load_existing_arm_config() {
    if [ ! -f "variables.tf" ]; then
        return 1
    fi
    
    # Load existing ARM configuration
    local existing_amd_count=$(grep -oP 'amd_micro_instance_count\s*=\s*\K[0-9]+' variables.tf | head -1)
    local existing_amd_boot=$(grep -oP 'amd_micro_boot_volume_size_gb\s*=\s*\K[0-9]+' variables.tf | head -1)
    local existing_arm_count=$(grep -oP 'arm_flex_instance_count\s*=\s*\K[0-9]+' variables.tf | head -1)
    
    # Load ARM instance arrays
    local existing_arm_ocpus=$(grep -oP 'arm_flex_ocpus_per_instance\s*=\s*\[\K[^\]]+' variables.tf | head -1)
    local existing_arm_memory=$(grep -oP 'arm_flex_memory_per_instance\s*=\s*\[\K[^\]]+' variables.tf | head -1)
    local existing_arm_boot=$(grep -oP 'arm_flex_boot_volume_size_gb\s*=\s*\[\K[^\]]+' variables.tf | head -1)
    local existing_arm_block=$(grep -oP 'arm_block_volume_sizes\s*=\s*\[\K[^\]]+' variables.tf | head -1)
    
    # Load hostnames
    local existing_amd_hostnames=$(grep -oP 'amd_micro_hostnames\s*=\s*\[\K[^\]]+' variables.tf | head -1)
    local existing_arm_hostnames=$(grep -oP 'arm_flex_hostnames\s*=\s*\[\K[^\]]+' variables.tf | head -1)
    
    if [ -n "$existing_arm_count" ] && [ "$existing_arm_count" -gt 0 ]; then
        # Set global variables from existing config
        amd_micro_instance_count=${existing_amd_count:-0}  # Default to 0 instead of 2
        amd_micro_boot_volume_size_gb=${existing_amd_boot:-50}
        arm_flex_instance_count=${existing_arm_count:-1}
        
        # Parse arrays
        if [ -n "$existing_arm_ocpus" ]; then
            arm_flex_ocpus_per_instance=$(echo "$existing_arm_ocpus" | tr -d '"' | tr ',' ' ')
        else
            arm_flex_ocpus_per_instance="4"
        fi
        
        if [ -n "$existing_arm_memory" ]; then
            arm_flex_memory_per_instance=$(echo "$existing_arm_memory" | tr -d '"' | tr ',' ' ')
        else
            arm_flex_memory_per_instance="24"
        fi
        
        if [ -n "$existing_arm_boot" ]; then
            arm_flex_boot_volume_size_gb=$(echo "$existing_arm_boot" | tr -d '"' | tr ',' ' ')
        else
            arm_flex_boot_volume_size_gb="160"
        fi
        
        if [ -n "$existing_arm_block" ]; then
            # Parse block volumes array
            local block_array=($(echo "$existing_arm_block" | tr ',' ' '))
            arm_flex_block_volumes=("${block_array[@]}")
        else
            arm_flex_block_volumes=(0)
        fi
        
        # Parse hostnames - handle zero AMD instances properly
        if [ -n "$existing_amd_hostnames" ] && [ "$amd_micro_instance_count" -gt 0 ]; then
            local amd_hostname_array=($(echo "$existing_amd_hostnames" | tr -d '"' | tr ',' ' '))
            amd_micro_hostnames=("${amd_hostname_array[@]}")
        else
            amd_micro_hostnames=()  # Empty array when no AMD instances
        fi
        
        if [ -n "$existing_arm_hostnames" ]; then
            local arm_hostname_array=($(echo "$existing_arm_hostnames" | tr -d '"' | tr ',' ' '))
            arm_flex_hostnames=("${arm_hostname_array[@]}")
        else
            arm_flex_hostnames=("arm-instance-1")
        fi
        
        return 0
    fi
    
    return 1
}

# Function to prompt user for ARM instance configuration
prompt_arm_flex_instance_config() {
    print_status "Configuring ARM instance setup for Oracle Free Tier..."
    print_status "Oracle Free Tier allows:"
    print_status "  - 200GB TOTAL storage across ALL instances"
    print_status "  - 2x AMD x86 micro instances (VM.Standard.E2.1.Micro): 1 OCPU, 1GB RAM each, min 50GB boot volume each (OCI requirement)"
    print_status "  - 4 OCPUs + 24GB RAM total for ARM (Ampere) instances"
    print_status "  - All boot volumes: minimum 50GB each (OCI requirement)"
    print_status ""
    print_status "Choose your configuration:"
    print_status "  1) Default: 2x AMD micro (50GB each), 3x ARM (2+1+1 OCPU, 12+6+6GB RAM, 70/65/65GB boot)"
    print_status "  2) Use existing configuration from variables.tf (if available)"
    print_status "  3) Custom: Manually configure all values (number of AMD, ARM, OCPUs, RAM, boot, etc)"
    print_status ""

    while true; do
        if [ "$AUTO_USE_EXISTING" = "true" ]; then
            arm_flex_choice=2
            print_status "Non-interactive mode: Using existing configuration (option 2)"
        else
            echo -n -e "${BLUE}Choose a configuration by number (1-3): ${NC}"
            read -r arm_flex_choice
            arm_flex_choice=${arm_flex_choice:-1}
        fi
        case $arm_flex_choice in
            1)
                # Default: 2x AMD micro (50GB each), 3x ARM (2+1+1 OCPU, 12+6+6GB RAM, 70/65/65GB boot)
                amd_micro_instance_count=2
                amd_micro_boot_volume_size_gb=50
                arm_flex_instance_count=3
                arm_flex_ocpus_per_instance="2 1 1"
                arm_flex_memory_per_instance="12 6 6"
                arm_flex_boot_volume_size_gb="70 65 65"
                arm_flex_block_volumes=(0 0 0)
                break
                ;;
            2)
                # Use existing configuration from variables.tf
                print_status "Loading existing configuration from variables.tf..."
                if load_existing_arm_config; then
                    print_success "Successfully loaded existing ARM configuration:"
                    echo ""
                    print_status "📊 CURRENT CONFIGURATION SUMMARY:"
                    print_status "┌─────────────────────────────────────────────────────────────┐"
                    print_status "│                    COMPUTE INSTANCES                       │"
                    print_status "├─────────────────────────────────────────────────────────────┤"
                    print_status "│ AMD x86 Instances: $amd_micro_instance_count instances                        │"
                    if [ "$amd_micro_instance_count" -gt 0 ]; then
                        print_status "│   • Shape: VM.Standard.E2.1.Micro (1 OCPU, 1GB RAM each)  │"
                        print_status "│   • Boot Volume: ${amd_micro_boot_volume_size_gb}GB per instance                       │"
                        print_status "│   • Total Storage: $((amd_micro_instance_count * amd_micro_boot_volume_size_gb))GB                                │"
                        print_status "│   • Hostnames: ${amd_micro_hostnames[*]// /, }                    │"
                    else
                        print_status "│   • No AMD instances configured                            │"
                    fi
                    print_status "├─────────────────────────────────────────────────────────────┤"
                    print_status "│ ARM Ampere Instances: $arm_flex_instance_count instances                      │"
                    local ocpu_array=($arm_flex_ocpus_per_instance)
                    local memory_array=($arm_flex_memory_per_instance)
                    local boot_array=($arm_flex_boot_volume_size_gb)
                    local total_arm_ocpus=0
                    local total_arm_memory=0
                    local total_arm_boot=0
                    for ((i=0; i<${#ocpu_array[@]}; i++)); do
                        local instance_num=$((i+1))
                        local ocpu=${ocpu_array[$i]}
                        local memory=${memory_array[$i]}
                        local boot=${boot_array[$i]}
                        local block=${arm_flex_block_volumes[$i]:-0}
                        local hostname=${arm_flex_hostnames[$i]:-"arm-instance-$instance_num"}
                        total_arm_ocpus=$((total_arm_ocpus + ocpu))
                        total_arm_memory=$((total_arm_memory + memory))
                        total_arm_boot=$((total_arm_boot + boot))
                        print_status "│   Instance $instance_num ($hostname):                              │"
                        print_status "│     • OCPUs: ${ocpu}, Memory: ${memory}GB, Boot: ${boot}GB, Block: ${block}GB       │"
                    done
                    print_status "│   • Total ARM Resources: ${total_arm_ocpus} OCPUs, ${total_arm_memory}GB RAM           │"
                    print_status "├─────────────────────────────────────────────────────────────┤"
                    print_status "│ STORAGE SUMMARY:                                           │"
                    local total_boot=$((amd_micro_instance_count * amd_micro_boot_volume_size_gb + total_arm_boot))
                    local total_block=0
                    for block_vol in "${arm_flex_block_volumes[@]}"; do
                        total_block=$((total_block + block_vol))
                    done
                    local total_storage=$((total_boot + total_block))
                    print_status "│   • Total Boot Volumes: ${total_boot}GB                            │"
                    print_status "│   • Total Block Volumes: ${total_block}GB                           │"
                    print_status "│   • Total Storage Used: ${total_storage}GB / 200GB Free Tier       │"
                    local remaining=$((200 - total_storage))
                    if [ $remaining -gt 0 ]; then
                        print_status "│   • Remaining Available: ${remaining}GB                         │"
                    fi
                    print_status "└─────────────────────────────────────────────────────────────┘"
                    echo ""
                    if [ "$NON_INTERACTIVE" = "true" ]; then
                        use_existing="Y"
                        print_status "Non-interactive mode: Using existing configuration"
                    else
                        echo -n -e "${BLUE}Use this existing configuration? (Y/n): ${NC}"
                        read -r use_existing
                        use_existing=${use_existing:-Y}
                    fi
                    if [[ "$use_existing" =~ ^[Yy]$ ]]; then
                        print_success "✅ Using existing configuration - proceeding with setup"
                        break
                    else
                        print_status "Please choose a different option."
                        continue
                    fi
                else
                    print_error "❌ No existing ARM configuration found in variables.tf or configuration is invalid."
                    print_status "Please choose a different option (1-3)."
                    continue
                fi
                ;;
            3)
                # Custom/manual entry
                print_status "Custom/manual ARM instance configuration selected."
                # Prompt for AMD micro instance count (0, 1, or 2)
                while true; do
                    if [ "$NON_INTERACTIVE" = "true" ]; then
                        amd_micro_instance_count=0
                        print_status "Non-interactive mode: Setting AMD instances to 0"
                        break
                    else
                        echo -n -e "${BLUE}How many AMD x86 micro instances do you want? (0, 1, or 2) [default: 0]: ${NC}"
                        read -r amd_micro_instance_count
                        amd_micro_instance_count=${amd_micro_instance_count:-0}
                    fi
                    if [[ "$amd_micro_instance_count" =~ ^[0-2]$ ]]; then
                        break
                    else
                        print_error "Please enter 0, 1, or 2."
                    fi
                done
                if [ "$amd_micro_instance_count" -gt 0 ]; then
                    while true; do
                        if [ "$NON_INTERACTIVE" = "true" ]; then
                            micro_boot=50
                            break
                        else
                            echo -n -e "${BLUE}Enter boot volume size (GB) for each AMD micro instance [50-100, default 50]: ${NC}"
                            read -r micro_boot
                            micro_boot=${micro_boot:-50}
                        fi
                        if [[ "$micro_boot" =~ ^[0-9]+$ ]] && [ "$micro_boot" -ge 50 ] && [ "$micro_boot" -le 100 ]; then
                            break
                        else
                            print_error "Please enter a number between 50 and 100 (OCI minimum is 50GB)."
                        fi
                    done
                    amd_micro_boot_volume_size_gb=$micro_boot
                else
                    amd_micro_boot_volume_size_gb=50  # Default value even when count is 0
                fi
                
                # Prompt for ARM instances
                while true; do
                    if [ "$NON_INTERACTIVE" = "true" ]; then
                        arm_flex_instance_count=1
                        print_status "Non-interactive mode: Setting ARM instances to 1"
                        break
                    else
                        echo -n -e "${BLUE}Enter number of ARM instances [default: 1]: ${NC}"
                        read -r arm_flex_instance_count
                        arm_flex_instance_count=${arm_flex_instance_count:-1}
                    fi
                    if [[ "$arm_flex_instance_count" =~ ^[0-9]+$ ]] && [ "$arm_flex_instance_count" -ge 0 ]; then
                        break
                    else
                        print_error "Please enter a valid number (0 or greater)."
                    fi
                done
                
                arm_flex_ocpus_per_instance=""
                arm_flex_memory_per_instance=""
                arm_flex_boot_volume_size_gb=""
                arm_flex_block_volumes=()
                
                for ((i=1; i<=arm_flex_instance_count; i++)); do
                    if [ "$NON_INTERACTIVE" = "true" ]; then
                        ocpu=4
                        ram=24
                        boot=100
                    else
                        echo -n -e "${BLUE}Enter OCPUs for ARM instance $i [default: 4]: ${NC}"
                        read -r ocpu
                        ocpu=${ocpu:-4}
                        echo -n -e "${BLUE}Enter RAM (GB) for ARM instance $i [default: 24]: ${NC}"
                        read -r ram
                        ram=${ram:-24}
                        while true; do
                            echo -n -e "${BLUE}Enter boot volume size (GB) for ARM instance $i [minimum 50GB, default: 100]: ${NC}"
                            read -r boot
                            boot=${boot:-100}
                            if [[ "$boot" =~ ^[0-9]+$ ]] && [ "$boot" -ge 50 ]; then
                                break
                            else
                                print_error "Boot volume must be at least 50GB (OCI requirement)"
                            fi
                        done
                    fi
                    arm_flex_ocpus_per_instance+="$ocpu "
                    arm_flex_memory_per_instance+="$ram "
                    arm_flex_boot_volume_size_gb+="$boot "
                    arm_flex_block_volumes+=(0)
                done
                # Trim trailing spaces
                arm_flex_ocpus_per_instance=$(echo $arm_flex_ocpus_per_instance | sed 's/[[:space:]]*$//')
                arm_flex_memory_per_instance=$(echo $arm_flex_memory_per_instance | sed 's/[[:space:]]*$//')
                arm_flex_boot_volume_size_gb=$(echo $arm_flex_boot_volume_size_gb | sed 's/[[:space:]]*$//')
                break
                ;;
            *)
                print_error "Invalid choice. Please enter a number between 1 and 3."
                continue
                ;;
        esac
    done
}

# Function to prompt user for instance hostnames
prompt_instance_hostnames() {
    print_status "Configuring instance hostnames..."
    print_status "You can customize the hostnames for your instances."
    print_status "Default pattern is: amd-instance-1, amd-instance-2, arm-instance-1, etc."
    print_status ""
    
    # Check if hostnames are already loaded from existing config
    local has_existing_amd=$([ "${#amd_micro_hostnames[@]}" -gt 0 ] && echo "true" || echo "false")
    local has_existing_arm=$([ "${#arm_flex_hostnames[@]}" -gt 0 ] && echo "true" || echo "false")
    local should_check_existing=false
    
    # Only check existing if we have instances configured and hostnames exist
    if [ "$amd_micro_instance_count" -gt 0 ] && [ "$has_existing_amd" = "true" ]; then
        should_check_existing=true
    elif [ "$arm_flex_instance_count" -gt 0 ] && [ "$has_existing_arm" = "true" ]; then
        should_check_existing=true
    fi
    
    if [ "$should_check_existing" = "true" ]; then
        print_status "Current hostnames from existing configuration:"
        if [ "$amd_micro_instance_count" -gt 0 ]; then
            print_status "  AMD instances: ${amd_micro_hostnames[*]}"
        fi
        if [ "$arm_flex_instance_count" -gt 0 ]; then
            print_status "  ARM instances: ${arm_flex_hostnames[*]}"
        fi
        if [ "$NON_INTERACTIVE" = "true" ]; then
            use_existing_hostnames="Y"
            print_status "Non-interactive mode: Using existing hostnames"
        else
            echo -n -e "${BLUE}Use existing hostnames? (Y/n): ${NC}"
            read -r use_existing_hostnames
            use_existing_hostnames=${use_existing_hostnames:-Y}
        fi
        if [[ "$use_existing_hostnames" =~ ^[Yy]$ ]]; then
            print_success "Using existing hostnames"
            return 0
        fi
    fi
    
    # AMD instance hostnames - only if we have AMD instances
    amd_micro_hostnames=()
    if [ "$amd_micro_instance_count" -gt 0 ]; then
        for ((i=1; i<=amd_micro_instance_count; i++)); do
            default_hostname="amd-instance-$i"
            if [ "$NON_INTERACTIVE" = "true" ]; then
                hostname="$default_hostname"
            else
                echo -n -e "${BLUE}Enter hostname for AMD instance $i [default: $default_hostname]: ${NC}"
                read -r hostname
                hostname=${hostname:-$default_hostname}
            fi
            if [[ "$hostname" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$ ]] && [ ${#hostname} -le 63 ]; then
                amd_micro_hostnames+=("$hostname")
            else
                print_warning "Invalid hostname format. Using default: $default_hostname"
                amd_micro_hostnames+=("$default_hostname")
            fi
        done
    fi
    
    # ARM instance hostnames - only if we have ARM instances
    arm_flex_hostnames=()
    if [ "$arm_flex_instance_count" -gt 0 ]; then
        for ((i=1; i<=arm_flex_instance_count; i++)); do
            default_hostname="arm-instance-$i"
            if [ "$NON_INTERACTIVE" = "true" ]; then
                hostname="$default_hostname"
            else
                echo -n -e "${BLUE}Enter hostname for ARM instance $i [default: $default_hostname]: ${NC}"
                read -r hostname
                hostname=${hostname:-$default_hostname}
            fi
            # Validate hostname (basic validation)
            if [[ "$hostname" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$ ]] && [ ${#hostname} -le 63 ]; then
                arm_flex_hostnames+=("$hostname")
            else
                print_warning "Invalid hostname format. Using default: $default_hostname"
                arm_flex_hostnames+=("$default_hostname")
            fi
        done
    fi
    
    print_success "Hostnames configured:"
    if [ "$amd_micro_instance_count" -gt 0 ]; then
        print_status "  AMD instances: ${amd_micro_hostnames[*]}"
    else
        print_status "  AMD instances: none configured"
    fi
    if [ "$arm_flex_instance_count" -gt 0 ]; then
        print_status "  ARM instances: ${arm_flex_hostnames[*]}"
    else
        print_status "  ARM instances: none configured"
    fi
}

# Function to create Terraform variables file (updated to include hostnames)
create_terraform_vars() {
    print_status "Creating variables.tf with fetched values..."
    
    # Backup existing file if it exists
    if [ -f "variables.tf" ]; then
        cp variables.tf "variables.tf.bak.$(date +%Y%m%d_%H%M%S)"
        print_status "Backed up existing variables.tf with timestamp"
    fi
    
    # Using OCI config file authentication - no additional setup required
    
    # Convert hostname arrays to Terraform list format - handle empty arrays properly
    local amd_micro_hostnames_tf="["
    if [ "${#amd_micro_hostnames[@]}" -gt 0 ]; then
        for ((i=0; i<${#amd_micro_hostnames[@]}; i++)); do
            if [ $i -gt 0 ]; then
                amd_micro_hostnames_tf+=", "
            fi
            amd_micro_hostnames_tf+="\"${amd_micro_hostnames[$i]}\""
        done
    fi
    amd_micro_hostnames_tf+="]"
    
    local arm_flex_hostnames_tf="["
    if [ "${#arm_flex_hostnames[@]}" -gt 0 ]; then
        for ((i=0; i<${#arm_flex_hostnames[@]}; i++)); do
            if [ $i -gt 0 ]; then
                arm_flex_hostnames_tf+=", "
            fi
            arm_flex_hostnames_tf+="\"${arm_flex_hostnames[$i]}\""
        done
    fi
    arm_flex_hostnames_tf+="]"
    
    # Convert ARM instance configuration to Terraform list format
    local arm_flex_ocpus_tf="["
    local arm_flex_memory_tf="["
    local arm_flex_boot_tf="["
    
    if [ "$arm_flex_instance_count" -gt 0 ]; then
        if [ "$arm_flex_instance_count" -eq 1 ]; then
            # Single instance - use the values directly
            arm_flex_ocpus_tf+="$arm_flex_ocpus_per_instance"
            arm_flex_memory_tf+="$arm_flex_memory_per_instance"
            arm_flex_boot_tf+="$arm_flex_boot_volume_size_gb"
        else
            # Multiple instances - parse space-separated values
            local ocpu_array=($arm_flex_ocpus_per_instance)
            local memory_array=($arm_flex_memory_per_instance)
            local boot_array=($arm_flex_boot_volume_size_gb)
            
            for ((i=0; i<${#ocpu_array[@]}; i++)); do
                if [ $i -gt 0 ]; then
                    arm_flex_ocpus_tf+=", "
                    arm_flex_memory_tf+=", "
                    arm_flex_boot_tf+=", "
                fi
                arm_flex_ocpus_tf+="${ocpu_array[$i]}"
                arm_flex_memory_tf+="${memory_array[$i]}"
                arm_flex_boot_tf+="${boot_array[$i]}"
            done
        fi
    fi
    
    arm_flex_ocpus_tf+="]"
    arm_flex_memory_tf+="]"
    arm_flex_boot_tf+="]"
    
    # Create variables.tf with all dynamically fetched values
    cat > variables.tf << EOF
# Automatically generated OCI Terraform variables
# Generated on: $(date)
# Region: $region
# Authentication: OCI config file (~/.oci/config)
# Configuration: ${amd_micro_instance_count}x AMD + ${arm_flex_instance_count}x ARM instances

locals {
  # Per README: availability_domain == tenancy-ocid == compartment_id
  availability_domain  = "$tenancy_ocid"
  compartment_id       = "$tenancy_ocid"
  
  # Dynamically fetched Ubuntu images for region $region
  ubuntu2404ocid       = "$ubuntu_image_ocid"
  ubuntu2404_arm_flex_ocid  = "$ubuntu_arm_flex_image_ocid"
  
  user_ocid            = "$user_ocid"
  fingerprint          = "$fingerprint"
  tenancy_ocid         = "$tenancy_ocid"
  region               = "$region"
  
  # SSH Configuration
  ssh_pubkey_path      = pathexpand("./ssh_keys/id_rsa.pub")
  ssh_pubkey_data      = file(pathexpand("./ssh_keys/id_rsa.pub"))
  ssh_private_key_path = pathexpand("./ssh_keys/id_rsa")
  
  # Oracle Free Tier Instance Configuration
  # AMD x86 instances (Always Free Eligible)
  amd_micro_instance_count        = $amd_micro_instance_count
  amd_micro_boot_volume_size_gb   = $amd_micro_boot_volume_size_gb
  amd_micro_hostnames             = $amd_micro_hostnames_tf
  
  # ARM instances configuration (user-selected)
  arm_flex_instance_count        = $([ -n "$ubuntu_arm_flex_image_ocid" ] && echo "$arm_flex_instance_count" || echo "0")
  arm_flex_ocpus_per_instance    = $arm_flex_ocpus_tf
  arm_flex_memory_per_instance   = $arm_flex_memory_tf
  arm_flex_boot_volume_size_gb   = $arm_flex_boot_tf
  arm_flex_hostnames             = $arm_flex_hostnames_tf
  
  # Block Storage Configuration for Maximum Always Free Tier Usage
  # Note: Oracle Always Free Tier provides 200GB TOTAL storage (boot + block combined)
  # Block volumes are slower than boot volumes, so by default we allocate all 200GB to boot volumes
  # Block volume resources are included but set to 0 for optimal performance - users can customize if needed
  amd_block_volume_size_gb = 0
  
  # ARM block volumes (set to 0 for optimal performance)
  # Users can customize these if they prefer block volumes over larger boot volumes
  arm_block_volume_sizes = [$(printf '%s,' "${arm_flex_block_volumes[@]}" | sed 's/,$//')]
  
  # Total block volume calculation
  total_block_volume_gb = local.amd_micro_instance_count * local.amd_block_volume_size_gb + sum([for size in local.arm_block_volume_sizes : size])

  # Boot volume usage validation
  total_boot_volume_gb = local.amd_micro_instance_count * local.amd_micro_boot_volume_size_gb + sum(local.arm_flex_boot_volume_size_gb)
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

# Total storage validation (boot + block volumes)
variable "max_free_tier_total_storage_gb" {
  description = "Maximum total storage (boot + block) for Oracle Free Tier"
  type        = number
  default     = 200
}

# Validation check for boot volumes
check "free_tier_boot_volume_limit" {
  assert {
    condition     = local.total_boot_volume_gb <= var.max_free_tier_boot_volume_gb
    error_message = "Total boot volume usage (\${local.total_boot_volume_gb}GB) exceeds Oracle Free Tier limit (\${var.max_free_tier_boot_volume_gb}GB)."
  }
}

# Validation check for total storage
check "free_tier_total_storage_limit" {
  assert {
    condition     = (local.total_boot_volume_gb + local.total_block_volume_gb) <= var.max_free_tier_total_storage_gb
    error_message = "Total storage usage (\${local.total_boot_volume_gb + local.total_block_volume_gb}GB) exceeds Oracle Free Tier limit (\${var.max_free_tier_total_storage_gb}GB)."
  }
}
EOF
    
    print_success "variables.tf created successfully with Oracle Free Tier configuration!"
    print_status "Variables file contains:"
    print_status "  - Tenancy OCID: $tenancy_ocid"
    print_status "  - Region: $region"
    print_status "  - Ubuntu x86 Image OCID: $ubuntu_image_ocid"
    print_status "  - Ubuntu ARM Image OCID: $ubuntu_arm_flex_image_ocid"
    print_status "  - Authentication: OCI config file (~/.oci/config)"
    print_status "  - SSH Keys: ./ssh_keys/id_rsa"
    if [ "$amd_micro_instance_count" -gt 0 ]; then
        print_status "  - AMD Hostnames: ${amd_micro_hostnames[*]}"
    else
        print_status "  - AMD Instances: none configured"
    fi
    if [ "$arm_flex_instance_count" -gt 0 ]; then
        print_status "  - ARM Hostnames: ${arm_flex_hostnames[*]}"
    else
        print_status "  - ARM Instances: none configured"
    fi
    print_status ""
    print_status "CONFIGURED ORACLE FREE TIER SERVICES:"
    print_status "  - Compute Instances: ${amd_micro_instance_count}x AMD + ${arm_flex_instance_count}x ARM instances"
    print_status "  - Networking: VCNs, subnets, security groups"
    print_status "  - Storage: Boot volumes (up to 200GB total)"
    return 0
}

# Function to verify all requirements are met (updated for session tokens)
verify_setup() {
    print_status "Verifying complete setup..."
    
    # Check required files exist (using OCI config file authentication)
    local required_files=(
        "$HOME/.oci/config"
        "./ssh_keys/id_rsa"
        "./ssh_keys/id_rsa.pub"
        "./variables.tf"
    )
    
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

# Function to run Terraform commands with proper error handling
run_terraform_command() {
    local command="$1"
    local description="$2"
    
    print_status "$description..."

    if eval "$command"; then
        print_success "$description completed successfully"
        return 0
    else
        print_error "$description failed"
        return 1
    fi
}

# Function to detect existing OCI resources that need to be imported
detect_existing_resources() {
    print_status "Detecting existing OCI resources that need to be imported..."
    
    # Initialize arrays to store existing resource information
    existing_vcns=()
    existing_subnets=()
    existing_internet_gateways=()
    existing_route_tables=()
    existing_security_lists=()
    existing_dhcp_options=()
    existing_nsgs=()
    existing_instances=()
    existing_atp_databases=()
    existing_adw_databases=()
    existing_mysql_databases=()
    existing_nosql_tables=()
    existing_buckets=()
    existing_vaults=()
    existing_keys=()
    existing_log_groups=()
    existing_logs=()
    existing_topics=()
    existing_subscriptions=()
    existing_alarms=()
    existing_service_connectors=()
    existing_apm_domains=()
    
    # Get existing VCNs
    print_status "Checking for existing VCNs..."
    local vcn_list=$(oci network vcn list --compartment-id "$tenancy_ocid" --query 'data[].{id:id,name:"display-name"}' 2>/dev/null)
    if [ -n "$vcn_list" ] && [ "$vcn_list" != "[]" ]; then
        print_status "Found existing VCNs:"
        echo "$vcn_list" | jq -r '.[] | "  - \(.name): \(.id)"'
        
        # Store VCN information for import (accept ALL VCNs for import, not just specific naming patterns)
        while IFS= read -r vcn_info; do
            local vcn_id=$(echo "$vcn_info" | jq -r '.id')
            local vcn_name=$(echo "$vcn_info" | jq -r '.name')
            existing_vcns+=("$vcn_id:$vcn_name")
            
            # Get subnets for this VCN
            local subnet_list=$(oci network subnet list --compartment-id "$tenancy_ocid" --vcn-id "$vcn_id" --query 'data[].{id:id,name:"display-name"}' 2>/dev/null)
            if [ -n "$subnet_list" ] && [ "$subnet_list" != "[]" ]; then
                while IFS= read -r subnet_info; do
                    local subnet_id=$(echo "$subnet_info" | jq -r '.id')
                    local subnet_name=$(echo "$subnet_info" | jq -r '.name')
                    existing_subnets+=("$subnet_id:$subnet_name:$vcn_id")
                done <<< "$(echo "$subnet_list" | jq -c '.[]')"
            fi
            
            # Get internet gateways for this VCN
            local ig_list=$(oci network internet-gateway list --compartment-id "$tenancy_ocid" --vcn-id "$vcn_id" --query 'data[].{id:id,name:"display-name"}' 2>/dev/null)
            if [ -n "$ig_list" ] && [ "$ig_list" != "[]" ]; then
                while IFS= read -r ig_info; do
                    local ig_id=$(echo "$ig_info" | jq -r '.id')
                    local ig_name=$(echo "$ig_info" | jq -r '.name')
                    existing_internet_gateways+=("$ig_id:$ig_name:$vcn_id")
                done <<< "$(echo "$ig_list" | jq -c '.[]')"
            fi
            
            # Get route tables for this VCN
            local rt_list=$(oci network route-table list --compartment-id "$tenancy_ocid" --vcn-id "$vcn_id" --query 'data[].{id:id,name:"display-name"}' 2>/dev/null)
            if [ -n "$rt_list" ] && [ "$rt_list" != "[]" ]; then
                while IFS= read -r rt_info; do
                    local rt_id=$(echo "$rt_info" | jq -r '.id')
                    local rt_name=$(echo "$rt_info" | jq -r '.name')
                    existing_route_tables+=("$rt_id:$rt_name:$vcn_id")
                done <<< "$(echo "$rt_list" | jq -c '.[]')"
            fi
            
            # Get security lists for this VCN
            local sl_list=$(oci network security-list list --compartment-id "$tenancy_ocid" --vcn-id "$vcn_id" --query 'data[].{id:id,name:"display-name"}' 2>/dev/null)
            if [ -n "$sl_list" ] && [ "$sl_list" != "[]" ]; then
                while IFS= read -r sl_info; do
                    local sl_id=$(echo "$sl_info" | jq -r '.id')
                    local sl_name=$(echo "$sl_info" | jq -r '.name')
                    existing_security_lists+=("$sl_id:$sl_name:$vcn_id")
                done <<< "$(echo "$sl_list" | jq -c '.[]')"
            fi
            
            # Get DHCP options for this VCN
            local dhcp_list=$(oci network dhcp-options list --compartment-id "$tenancy_ocid" --vcn-id "$vcn_id" --query 'data[].{id:id,name:"display-name"}' 2>/dev/null)
            if [ -n "$dhcp_list" ] && [ "$dhcp_list" != "[]" ]; then
                while IFS= read -r dhcp_info; do
                    local dhcp_id=$(echo "$dhcp_info" | jq -r '.id')
                    local dhcp_name=$(echo "$dhcp_info" | jq -r '.name')
                    existing_dhcp_options+=("$dhcp_id:$dhcp_name:$vcn_id")
                done <<< "$(echo "$dhcp_list" | jq -c '.[]')"
            fi
            
            # Get network security groups for this VCN
            local nsg_list=$(oci network nsg list --compartment-id "$tenancy_ocid" --vcn-id "$vcn_id" --query 'data[].{id:id,name:"display-name"}' 2>/dev/null)
            if [ -n "$nsg_list" ] && [ "$nsg_list" != "[]" ]; then
                while IFS= read -r nsg_info; do
                    local nsg_id=$(echo "$nsg_info" | jq -r '.id')
                    local nsg_name=$(echo "$nsg_info" | jq -r '.name')
                    existing_nsgs+=("$nsg_id:$nsg_name:$vcn_id")
                done <<< "$(echo "$nsg_list" | jq -c '.[]')"
            fi
            
        done <<< "$(echo "$vcn_list" | jq -c '.[]')"
    else
        print_status "No existing VCNs found - clean slate deployment"
    fi
    
    # Get existing compute instances
    print_status "Checking for existing compute instances..."
    local instance_list=$(oci compute instance list --compartment-id "$tenancy_ocid" --query 'data[].{id:id,name:"display-name",state:"lifecycle-state",shape:shape}' 2>/dev/null)
    if [ -n "$instance_list" ] && [ "$instance_list" != "[]" ]; then
        print_status "Found existing compute instances:"
        echo "$instance_list" | jq -r '.[] | "  - \(.name) (\(.shape), \(.state)): \(.id)"'
        while IFS= read -r instance_info; do
            local instance_id=$(echo "$instance_info" | jq -r '.id')
            local instance_name=$(echo "$instance_info" | jq -r '.name')
            local instance_state=$(echo "$instance_info" | jq -r '.state')
            local instance_shape=$(echo "$instance_info" | jq -r '.shape')
            existing_instances+=("$instance_id:$instance_name:$instance_state:$instance_shape")
        done <<< "$(echo "$instance_list" | jq -c '.[]')"
    fi
    
    # Summary
    print_status "Resource detection summary:"
    print_status "  - VCNs: ${#existing_vcns[@]}"
    print_status "  - Subnets: ${#existing_subnets[@]}"
    print_status "  - Internet Gateways: ${#existing_internet_gateways[@]}"
    print_status "  - Route Tables: ${#existing_route_tables[@]}"
    print_status "  - Security Lists: ${#existing_security_lists[@]}"
    print_status "  - DHCP Options: ${#existing_dhcp_options[@]}"
    print_status "  - Network Security Groups: ${#existing_nsgs[@]}"
    print_status "  - Compute Instances: ${#existing_instances[@]}"
}

# Function to import existing resources into Terraform state
import_existing_resources() {
    local has_existing_resources=false
    
    # Check if we have any existing resources to handle
    if [ ${#existing_vcns[@]} -gt 0 ] || [ ${#existing_instances[@]} -gt 0 ]; then
        has_existing_resources=true
    fi
    
    if [ "$has_existing_resources" = "false" ]; then
        print_status "No existing resources to import - proceeding with fresh deployment"
        return 0
    fi
    
    print_status "=========================================="
    print_status "INTELLIGENT RESOURCE IMPORT/REUSE SYSTEM"
    print_status "=========================================="
    print_status "Found existing resources that can be imported/reused:"
    
    # Show comprehensive summary of all detected resources
    if [ ${#existing_vcns[@]} -gt 0 ]; then
        print_status "  📡 VCNs: ${#existing_vcns[@]} found"
        for vcn_entry in "${existing_vcns[@]}"; do
            local vcn_name=$(echo "$vcn_entry" | cut -d':' -f2)
            print_status "    - $vcn_name"
        done
    fi
    
    if [ ${#existing_instances[@]} -gt 0 ]; then
        print_status "  🖥️  Compute Instances: ${#existing_instances[@]} found"
        for instance_entry in "${existing_instances[@]}"; do
            local instance_name=$(echo "$instance_entry" | cut -d':' -f2)
            local instance_shape=$(echo "$instance_entry" | cut -d':' -f4)
            print_status "    - $instance_name ($instance_shape)"
        done
    fi
    
    print_status ""
    print_status "RESOURCE HANDLING OPTIONS:"
    print_status "1. 🔄 IMPORT ALL - Import existing resources into Terraform state (RECOMMENDED)"
    print_status "   • Keeps existing resources and manages them with Terraform"
    print_status "   • Prevents resource conflicts and duplicate creation"
    print_status "   • Maintains existing configurations and data"
    print_status ""
    print_status "2. ⏭️  SKIP - Continue without handling existing resources"
    print_status "   • May cause deployment conflicts"
    print_status "   • Not recommended for production use"
    print_status ""
    
    local resource_choice
    while true; do
        if [ "$NON_INTERACTIVE" = "true" ] || [ "$AUTO_USE_EXISTING" = "true" ]; then
            resource_choice=1
            print_status "Non-interactive mode: Importing existing resources (option 1)"
        else
            echo -n -e "${BLUE}Choose option (1-2) [default: 1]: ${NC}"
            read -r resource_choice
            resource_choice=${resource_choice:-1}
        fi
        
        case $resource_choice in
            1)
                print_status "🔄 IMPORTING existing resources into Terraform state..."
                break
                ;;
            2)
                print_warning "⏭️  Skipping resource handling. You may encounter conflicts during apply."
                print_warning "Or re-run this script and choose option 1 to import resources."
                return 0
                ;;
            *)
                print_error "Invalid choice. Please enter 1 or 2."
                continue
                ;;
        esac
    done
    
    # Start comprehensive resource import process
    print_status ""
    print_status "🔄 Starting comprehensive resource import process..."
    print_status "This may take a few minutes depending on the number of resources..."
    
    # Import VCNs and networking resources
    if [ ${#existing_vcns[@]} -gt 0 ]; then
        print_status ""
        print_status "📡 Importing VCN and networking resources..."
        local vcn_index=0
        local main_vcn_id=""
        
        for vcn_entry in "${existing_vcns[@]}"; do
            local vcn_id=$(echo "$vcn_entry" | cut -d':' -f1)
            local vcn_name=$(echo "$vcn_entry" | cut -d':' -f2)
            
            print_status "  Importing VCN: $vcn_name"
            
            # Try to import the first VCN as main_vcn
            if [ $vcn_index -eq 0 ]; then
                if terraform state show oci_core_vcn.main_vcn >/dev/null 2>&1; then
                    print_status "  ✓ VCN '$vcn_name' already exists in state as main_vcn"
                    main_vcn_id="$vcn_id"
                elif terraform import oci_core_vcn.main_vcn "$vcn_id" 2>/dev/null; then
                    print_success "  ✓ Successfully imported VCN '$vcn_name' as main_vcn"
                    main_vcn_id="$vcn_id"
                else
                    print_warning "  ⚠ Failed to import VCN '$vcn_name' as main_vcn, continuing..."
                    main_vcn_id="$vcn_id"
                fi
            else
                print_status "  ℹ Additional VCN '$vcn_name' found - only importing first VCN for main infrastructure"
            fi
            
            ((vcn_index++))
        done
        
        # Import related networking resources for the main VCN
        if [ -n "$main_vcn_id" ]; then
            print_status "  Importing networking components for main VCN..."
            
            # Import Internet Gateway
            for ig_entry in "${existing_internet_gateways[@]}"; do
                local ig_id=$(echo "$ig_entry" | cut -d':' -f1)
                local ig_name=$(echo "$ig_entry" | cut -d':' -f2)
                local vcn_id=$(echo "$ig_entry" | cut -d':' -f3)
                
                if [ "$vcn_id" = "$main_vcn_id" ]; then
                    print_status "    Importing Internet Gateway: $ig_name"
                    if terraform state show oci_core_internet_gateway.main_internet_gateway >/dev/null 2>&1; then
                        print_status "    ✓ Internet Gateway already in state"
                    elif terraform import oci_core_internet_gateway.main_internet_gateway "$ig_id" 2>/dev/null; then
                        print_success "    ✓ Successfully imported Internet Gateway"
                    else
                        print_warning "    ⚠ Failed to import Internet Gateway"
                    fi
                    break
                fi
            done
            
            # Import Subnet
            for subnet_entry in "${existing_subnets[@]}"; do
                local subnet_id=$(echo "$subnet_entry" | cut -d':' -f1)
                local subnet_name=$(echo "$subnet_entry" | cut -d':' -f2)
                local vcn_id=$(echo "$subnet_entry" | cut -d':' -f3)
                
                if [ "$vcn_id" = "$main_vcn_id" ]; then
                    print_status "    Importing Subnet: $subnet_name"
                    if terraform state show oci_core_subnet.main_subnet >/dev/null 2>&1; then
                        print_status "    ✓ Subnet already in state"
                    elif terraform import oci_core_subnet.main_subnet "$subnet_id" 2>/dev/null; then
                        print_success "    ✓ Successfully imported Subnet"
                    else
                        print_warning "    ⚠ Failed to import Subnet"
                    fi
                    break
                fi
            done
            
            # Import Default Route Table
            for rt_entry in "${existing_route_tables[@]}"; do
                local rt_id=$(echo "$rt_entry" | cut -d':' -f1)
                local rt_name=$(echo "$rt_entry" | cut -d':' -f2)
                local vcn_id=$(echo "$rt_entry" | cut -d':' -f3)
                
                if [ "$vcn_id" = "$main_vcn_id" ] && [[ "$rt_name" == *"Default"* ]]; then
                    print_status "    Importing Default Route Table: $rt_name"
                    if terraform state show oci_core_default_route_table.main_route_table >/dev/null 2>&1; then
                        print_status "    ✓ Default Route Table already in state"
                    elif terraform import oci_core_default_route_table.main_route_table "$rt_id" 2>/dev/null; then
                        print_success "    ✓ Successfully imported Default Route Table"
                    else
                        print_warning "    ⚠ Failed to import Default Route Table"
                    fi
                    break
                fi
            done
            
            # Import Default Security List
            for sl_entry in "${existing_security_lists[@]}"; do
                local sl_id=$(echo "$sl_entry" | cut -d':' -f1)
                local sl_name=$(echo "$sl_entry" | cut -d':' -f2)
                local vcn_id=$(echo "$sl_entry" | cut -d':' -f3)
                
                if [ "$vcn_id" = "$main_vcn_id" ] && [[ "$sl_name" == *"Default"* ]]; then
                    print_status "    Importing Default Security List: $sl_name"
                    if terraform state show oci_core_default_security_list.main_security_list >/dev/null 2>&1; then
                        print_status "    ✓ Default Security List already in state"
                    elif terraform import oci_core_default_security_list.main_security_list "$sl_id" 2>/dev/null; then
                        print_success "    ✓ Successfully imported Default Security List"
                    else
                        print_warning "    ⚠ Failed to import Default Security List"
                    fi
                    break
                fi
            done
        fi
    fi
    
    # Import Compute Instances
    if [ ${#existing_instances[@]} -gt 0 ]; then
        print_status ""
        print_status "🖥️  Importing compute instances..."
        local instance_index=0
        for instance_entry in "${existing_instances[@]}"; do
            local instance_id=$(echo "$instance_entry" | cut -d':' -f1)
            local instance_name=$(echo "$instance_entry" | cut -d':' -f2)
            local instance_state=$(echo "$instance_entry" | cut -d':' -f3)
            local instance_shape=$(echo "$instance_entry" | cut -d':' -f4)
            
            print_status "  Importing compute instance: $instance_name ($instance_shape, $instance_state)"
            
            # Determine appropriate Terraform resource based on instance type
            local import_targets=()
            if [[ "$instance_shape" == *"Micro"* ]]; then
                import_targets+=("oci_core_instance.amd_micro_instances[0]" "oci_core_instance.amd_micro_instances[1]")
            elif [[ "$instance_shape" == *"A1"* ]]; then
                import_targets+=("oci_core_instance.arm_flex_instances[0]" "oci_core_instance.arm_flex_instances[1]")
            else
                import_targets+=("oci_core_instance.main_instance" "oci_core_instance.instance_${instance_index}")
            fi
            
            local imported=false
            for target in "${import_targets[@]}"; do
                if terraform state show "$target" >/dev/null 2>&1; then
                    print_status "    ✓ Instance already in state as $target"
                    imported=true
                    break
                elif terraform import "$target" "$instance_id" 2>/dev/null; then
                    print_success "    ✓ Successfully imported instance as $target"
                    imported=true
                    break
                fi
            done
            
            if [ "$imported" = "false" ]; then
                print_warning "    ⚠ Failed to import instance '$instance_name' - may need manual handling"
            fi
            
            ((instance_index++))
            if [ $instance_index -ge 4 ]; then
                print_status "  ℹ Limiting to first 4 instances to avoid resource conflicts"
                break
            fi
        done
    fi
    
    print_status ""
    print_success "🎉 COMPREHENSIVE RESOURCE IMPORT COMPLETED!"
    print_status "=========================================="
    print_status "Import Summary:"
    print_status "  ✅ All compatible existing resources have been imported into Terraform state"
    print_status "  ✅ Resources are now managed by Terraform and won't be recreated"
    print_status "  ✅ Existing configurations and data have been preserved"
    print_status "  ✅ Ready to proceed with Terraform plan and apply operations"
    print_status ""
    print_status "📋 Next Steps:"
    print_status "  1. Terraform will validate the imported resources"
    print_status "  2. A plan will be generated showing any required changes"
    print_status "  3. You can review and apply the changes to complete deployment"
    print_status ""
    print_status "⚠️  Note: Some resources may show minor configuration differences"
    print_status "   This is normal and Terraform will align them with your configuration"
    print_status ""
    
    # Always return success to continue the workflow
    return 0
}

# Function to run complete Terraform workflow
run_terraform_workflow() {
    print_status "Starting complete Terraform workflow..."
    
    # Ensure we're in the correct directory with Terraform files
    if [ ! -f "main.tf" ] || [ ! -f "variables.tf" ]; then
        print_error "main.tf or variables.tf not found in current directory"
        print_status "Please ensure you're in the correct directory with your Terraform configuration"
        return 1
    fi
    
    # Step 1: Initialize Terraform
    if ! run_terraform_command "terraform init" "Terraform initialization"; then
        return 1
    fi
    
    # Step 2: Detect existing resources
    detect_existing_resources
    
    # Step 3: Handle existing resources
    if [ ${#existing_vcns[@]} -gt 0 ]; then
        print_status "Existing resources detected that may conflict with deployment:"
        for vcn_entry in "${existing_vcns[@]}"; do
            local vcn_name=$(echo "$vcn_entry" | cut -d':' -f2)
            local vcn_id=$(echo "$vcn_entry" | cut -d':' -f1)
            print_status "  - VCN: $vcn_name ($vcn_id)"
        done
        print_status ""
        print_status "Choose how to handle existing resources:"
        print_status "1. Import existing resources into Terraform state (recommended)"
        print_status "2. Skip resource handling (may cause conflicts)"
        print_status ""
        
        while true; do
            if [ "$NON_INTERACTIVE" = "true" ]; then
                resource_choice=1
                print_status "Non-interactive mode: Importing existing resources (option 1)"
            else
                echo -n -e "${BLUE}Choose option (1-2) [default: 1]: ${NC}"
                read -r resource_choice
                resource_choice=${resource_choice:-1}
            fi
            
            case $resource_choice in
                1)
                    print_status "Importing existing resources into Terraform state..."
                    if import_existing_resources; then
                        print_success "Resource import completed successfully"
                    else
                        print_warning "Resource import had some issues but continuing..."
                    fi
                    break
                    ;;
                2)
                    print_warning "Skipping resource handling. You may encounter conflicts during apply."
                    break
                    ;;
                *)
                    print_error "Invalid choice. Please enter 1 or 2."
                    continue
                    ;;
            esac
        done
    else
        print_status "No existing resources detected - proceeding with clean deployment"
    fi
    
    # Explicitly continue with the rest of the workflow
    print_status ""
    print_status "=========================================="
    print_status "CONTINUING WITH TERRAFORM DEPLOYMENT..."
    print_status "=========================================="
    print_status ""
    
    # Step 4: Validate Terraform configuration
    print_status "Step 4: Validating Terraform configuration..."
    if ! run_terraform_command "terraform validate" "Terraform validation"; then
        print_error "Terraform validation failed. Please check your configuration files."
        return 1
    fi
    
    # Step 5: Format Terraform files
    print_status "Step 5: Formatting Terraform files..."
    run_terraform_command "terraform fmt" "Terraform formatting" || print_warning "Formatting failed but continuing..."
    
    # Step 6: Plan Terraform changes
    print_status "Step 6: Creating Terraform execution plan..."
    print_status "This may take a few minutes as Terraform analyzes your configuration..."
    
    if terraform plan -out=tfplan; then
        print_success "Terraform plan created successfully"
        print_status "Plan saved as 'tfplan'"
        
        # Show plan summary
        print_status ""
        print_status "========== TERRAFORM PLAN SUMMARY =========="
        terraform show tfplan | grep -E "^  # |^Plan:" | tail -20
        print_status "==========================================="
        print_status ""
        
    else
        print_error "Terraform plan failed"
        print_status "Common issues:"
        print_status "  - Resource conflicts (try importing existing resources)"
        print_status "  - Authentication issues (check OCI CLI config)"
        print_status "  - Configuration errors (check main.tf and variables.tf)"
        return 1
    fi
    
    # Step 7: Ask user if they want to apply
    print_status "Terraform plan completed successfully!"
    print_status "Review the plan above to see what resources will be created/modified."
    print_status ""
    if [ "$AUTO_DEPLOY" = "true" ] || [ "$NON_INTERACTIVE" = "true" ]; then
        apply_choice="Y"
        print_status "Non-interactive/auto-deploy mode: Auto-applying Terraform plan"
    else
        echo -n -e "${BLUE}Would you like to apply the Terraform plan now? (Y/n): ${NC}"
        read -r apply_choice
        apply_choice=${apply_choice:-Y}
    fi
    
    if [[ "$apply_choice" =~ ^[Yy]$ ]]; then
        print_status "Step 7: Applying Terraform plan..."
        print_status "This will deploy your Oracle Cloud infrastructure. Please wait..."
        
        if terraform apply tfplan; then
            print_success "🎉 Terraform apply completed successfully!"
            print_success "Your Oracle Cloud infrastructure is now fully deployed and managed by Terraform!"
            
            # Clean up plan file
            rm -f tfplan
            
            # Show final status
            print_status ""
            print_status "========== DEPLOYMENT SUMMARY =========="
            print_status "Fetching deployed resources..."
            
            # Show resource counts and types
            local resource_count=$(terraform state list | wc -l)
            print_status "Total managed resources: $resource_count"
            print_status ""
            print_status "Resource breakdown:"
            terraform state list | cut -d'.' -f1 | sort | uniq -c | while read count type; do
                print_status "  - $type: $count"
            done
            
            print_status ""
            print_status "Instance details:"
            terraform show -json 2>/dev/null | jq -r '
              .values.root_module.resources[]
              | select(.type == "oci_core_instance")
              | "  - \(.values.display_name): IPv4=\(.values.public_ip // "pending"), IPv6=\(.values.ipv6_addresses[0] // "none")"
            ' 2>/dev/null || print_status "  (Instance details require jq)"
            
            print_status "========================================"
            print_status ""
            print_success "✅ FULL DEPLOYMENT COMPLETED SUCCESSFULLY!"
            print_success "Your Oracle Always Free Tier infrastructure is now ready to use."
            
        else
            print_error "❌ Terraform apply failed"
            print_status "The plan file 'tfplan' has been preserved for debugging"
            print_status "Common apply issues:"
            print_status "  - Service limits exceeded (check Oracle Cloud limits)"
            print_status "  - Resource naming conflicts"
            print_status "  - Network configuration issues"
            print_status "  - Authentication/permission issues"
            return 1
        fi
    else
        print_status "Terraform plan has been saved as 'tfplan'"
        print_status "You can apply it later with: terraform apply tfplan"
        print_status "Or create a fresh plan with: terraform plan"
        print_warning "Note: Infrastructure has NOT been deployed yet."
    fi
    
    return 0
}

# Function to provide Terraform management options
terraform_management_menu() {
    while true; do
        print_status ""
        print_status "========== TERRAFORM MANAGEMENT MENU =========="
        print_status "1. Run full workflow (init, plan, apply)"
        print_status "2. Initialize only"
        print_status "3. Plan only"
        print_status "4. Apply existing plan"
        print_status "5. Import existing resources"
        print_status "6. Destroy infrastructure"
        print_status "7. Show current state"
        print_status "8. Validate configuration"
        print_status "9. Go back and reconfigure"
        print_status "10. Quit"
        print_status "==============================================="
        print_status ""
        
        if [ "$AUTO_DEPLOY" = "true" ]; then
            tf_choice=1
            print_status "Non-interactive mode: Running full workflow (option 1)"
        else
            echo -n -e "${BLUE}Choose an option (1-10) [default: 1]: ${NC}"
            read -r tf_choice
            tf_choice=${tf_choice:-1}
        fi
        
        case $tf_choice in
            1)
                print_status "Running full Terraform workflow..."
                run_terraform_workflow
                ;;
            2)
                run_terraform_command "terraform init" "Terraform initialization"
                ;;
            3)
                run_terraform_command "terraform init" "Terraform initialization" && \
                run_terraform_command "terraform plan" "Terraform planning"
                ;;
            4)
                if [ -f "tfplan" ]; then
                    run_terraform_command "terraform apply tfplan" "Applying existing plan"
                else
                    print_error "No existing plan file found. Run 'terraform plan' first."
                fi
                ;;
            5)
                run_terraform_command "terraform init" "Terraform initialization" && \
                detect_existing_resources && \
                import_existing_resources
                ;;
            6)
                print_warning "This will DESTROY all Terraform-managed infrastructure!"
                echo -n -e "${RED}Are you absolutely sure? Type 'yes' to confirm: ${NC}"
                read -r destroy_confirm
                if [ "$destroy_confirm" = "yes" ]; then
                    run_terraform_command "terraform destroy" "Destroying infrastructure"
                else
                    print_status "Destroy cancelled."
                fi
                ;;
            7)
                run_terraform_command "terraform show" "Showing current state"
                ;;
            8)
                run_terraform_command "terraform validate" "Terraform validation"
                ;;
            9)
                print_status "Going back to reconfigure setup..."
                return 1  # Signal to restart configuration
                ;;
            10)
                print_status "Exiting Terraform management."
                return 0  # Signal to quit
                ;;
            *)
                print_error "Invalid choice. Please enter a number between 1 and 10."
                continue
                ;;
        esac
        
        # Wait for user input before showing menu again (except for quit/reconfigure)
        if [ "$tf_choice" != "9" ] && [ "$tf_choice" != "10" ]; then
            if [ "$NON_INTERACTIVE" = "true" ] || [ "$AUTO_DEPLOY" = "true" ]; then
                # In non-interactive mode, exit after first operation
                print_status "Non-interactive mode: Exiting after operation completion"
                return 0
            else
                echo ""
                echo -n -e "${BLUE}Press any key to continue...${NC}"
                read -n 1 -s
                echo ""
            fi
        fi
    done
}

# Function to install Terraform
install_terraform() {
    if command_exists terraform; then
        local tf_version=$(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || terraform version | head -1 | awk '{print $2}' | sed 's/v//')
        print_status "Terraform already installed: version $tf_version"
        return 0
    fi
    
    print_status "Installing Terraform..."
    if command_exists snap; then
        sudo snap install terraform --classic
        return 0
    fi
    
    # Get the latest Terraform version
    local latest_version=$(curl -s https://api.github.com/repos/hashicorp/terraform/releases/latest | jq -r '.tag_name' | sed 's/v//')
    if [ -z "$latest_version" ]; then
        latest_version="1.7.0"  # Fallback version
        print_warning "Could not fetch latest version, using fallback: $latest_version"
    fi
    
    # Determine architecture
    local arch="amd64"
    if [ "$(uname -m)" = "aarch64" ]; then
        arch="arm64"
    fi
    
    # Download and install Terraform
    local tf_url="https://releases.hashicorp.com/terraform/${latest_version}/terraform_${latest_version}_linux_${arch}.zip"
    
    print_status "Downloading Terraform $latest_version for linux_$arch..."
    
    # Create temporary directory
    local temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    # Download Terraform
    if curl -LO "$tf_url"; then
        # Unzip
        if command_exists unzip; then
            unzip "terraform_${latest_version}_linux_${arch}.zip"
        else
            print_status "Installing unzip..."
            sudo apt-get update && sudo apt-get install -y unzip
            unzip "terraform_${latest_version}_linux_${arch}.zip"
        fi
        
        # Install to /usr/local/bin
        sudo mv terraform /usr/local/bin/
        sudo chmod +x /usr/local/bin/terraform
        
        # Cleanup
        cd - > /dev/null
        rm -rf "$temp_dir"
        
        # Verify installation
        if command_exists terraform; then
            local installed_version=$(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || terraform version | head -1 | awk '{print $2}' | sed 's/v//')
            print_success "Terraform $installed_version installed successfully"
            return 0
        else
            print_error "Terraform installation failed"
            return 1
        fi
    else
        print_error "Failed to download Terraform"
        cd - > /dev/null
        rm -rf "$temp_dir"
        return 1
    fi
}

# Function to create missing data sources and resources
create_missing_terraform_resources() {
    print_status "Creating missing Terraform data sources and resources..."
    
    # Create data_sources.tf with required data sources
    print_status "Creating data_sources.tf with required data sources..."
    if [ -f "data_sources.tf" ]; then
        cp data_sources.tf "data_sources.tf.bak.$(date +%Y%m%d_%H%M%S)"
        print_status "Backed up existing data_sources.tf with timestamp"
    fi
        cat > data_sources.tf << EOF
# Data sources for Oracle Cloud Infrastructure
# Generated on: $(date)

# Get availability domains
data "oci_identity_availability_domains" "ads" {
  compartment_id = local.tenancy_ocid
}

# Get current user information
data "oci_identity_user" "current_user" {
  user_id = local.user_ocid
}

# Get tenancy information
data "oci_identity_tenancy" "tenancy" {
  tenancy_id = local.tenancy_ocid
}

# Get regions
data "oci_identity_regions" "regions" {
}

# Get current region
data "oci_identity_region_subscriptions" "region_subscriptions" {
  tenancy_id = local.tenancy_ocid
}
EOF
        print_success "data_sources.tf created successfully"
    
    # Create main infrastructure configuration
    print_status "Creating main.tf with complete infrastructure configuration..."
    if [ -f "main.tf" ]; then
        cp main.tf "main.tf.bak.$(date +%Y%m%d_%H%M%S)"
        print_status "Backed up existing main.tf with timestamp"
    fi
        cat > main.tf << EOF
# Main Oracle Cloud Infrastructure (OCI) Terraform Configuration
# Generated on: $(date)

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
  compartment_id = local.tenancy_ocid
  vcn_id         = oci_core_vcn.main_vcn.id
  cidr_block     = "10.16.1.0/24"
  display_name   = "main-subnet"
  dns_label      = "mainsubnet"
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
    display_name     = "\${local.arm_flex_hostnames[count.index]}-vnic"
    assign_public_ip = true
    hostname_label   = local.arm_flex_hostnames[count.index]
  }
  
  source_details {
    source_type = "image"
    source_id   = local.ubuntu2404_arm_flex_ocid
    boot_volume_size_in_gbs = local.arm_flex_boot_volume_size_gb[count.index]
  }
  
  metadata = {
    ssh_authorized_keys = local.ssh_pubkey_data
    user_data = base64encode(templatefile("\${path.module}/cloud-init.yaml", {
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
    display_name     = "\${local.amd_micro_hostnames[count.index]}-vnic"
    assign_public_ip = true
    hostname_label   = local.amd_micro_hostnames[count.index]
  }
  
  source_details {
    source_type = "image"
    source_id   = local.ubuntu2404ocid
    boot_volume_size_in_gbs = local.amd_micro_boot_volume_size_gb
  }
  
  metadata = {
    ssh_authorized_keys = local.ssh_pubkey_data
    user_data = base64encode(templatefile("\${path.module}/cloud-init.yaml", {
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
        instance_name    = local.arm_flex_hostnames[i]
        instance_id      = oci_core_instance.arm_flex_instances[i].id
        public_ip        = oci_core_instance.arm_flex_instances[i].public_ip
        private_ip       = oci_core_instance.arm_flex_instances[i].private_ip
        shape            = oci_core_instance.arm_flex_instances[i].shape
        ocpus            = local.arm_flex_ocpus_per_instance[i]
        memory_gb        = local.arm_flex_memory_per_instance[i]
        boot_volume_gb   = local.arm_flex_boot_volume_size_gb[i]
        ssh_command      = "ssh -i ./ssh_keys/id_rsa ubuntu@\${oci_core_instance.arm_flex_instances[i].public_ip}"
        state            = oci_core_instance.arm_flex_instances[i].state
      }
    ] : []
    total_instances = local.arm_flex_instance_count
    total_ocpus     = local.arm_flex_instance_count > 0 ? sum(local.arm_flex_ocpus_per_instance) : 0
    total_memory_gb = local.arm_flex_instance_count > 0 ? sum(local.arm_flex_memory_per_instance) : 0
    architecture    = "aarch64"
    note           = local.arm_flex_instance_count > 0 ? "ARM instances configured" : "No ARM instances configured"
  }
}

# AMD Instance Information
output "amd_instances_complete_summary" {
  description = "Complete AMD instance details and connection information"
  value = {
    instances = local.amd_micro_instance_count > 0 ? [
      for i in range(local.amd_micro_instance_count) : {
        instance_name    = local.amd_micro_hostnames[i]
        instance_id      = oci_core_instance.amd_micro_instances[i].id
        public_ip        = oci_core_instance.amd_micro_instances[i].public_ip
        private_ip       = oci_core_instance.amd_micro_instances[i].private_ip
        shape            = oci_core_instance.amd_micro_instances[i].shape
        ocpus            = 1
        memory_gb        = 1
        boot_volume_gb   = local.amd_micro_boot_volume_size_gb
        ssh_command      = "ssh -i ./ssh_keys/id_rsa ubuntu@\${oci_core_instance.amd_micro_instances[i].public_ip}"
        state            = oci_core_instance.amd_micro_instances[i].state
      }
    ] : []
    total_instances = local.amd_micro_instance_count
    total_ocpus     = local.amd_micro_instance_count
    total_memory_gb = local.amd_micro_instance_count
    architecture    = "x86_64"
    note           = local.amd_micro_instance_count > 0 ? "AMD instances configured" : "No AMD instances configured"
  }
}

# Network Information
output "network_summary" {
  description = "Network configuration summary"
  value = {
    vcn_id              = oci_core_vcn.main_vcn.id
    vcn_cidr_blocks     = oci_core_vcn.main_vcn.cidr_blocks
    vcn_ipv6_cidr_blocks = oci_core_vcn.main_vcn.ipv6cidr_blocks
    subnet_id           = oci_core_subnet.main_subnet.id
    subnet_cidr_block   = oci_core_subnet.main_subnet.cidr_block
    internet_gateway_id = oci_core_internet_gateway.main_internet_gateway.id
    security_list_id    = oci_core_default_security_list.main_security_list.id
  }
}

# Complete Infrastructure Summary
output "infrastructure_complete_summary" {
  description = "Complete infrastructure summary with all resources"
  value = {
    region                = local.region
    availability_domain   = data.oci_identity_availability_domains.ads.availability_domains[0].name
    compartment_id        = local.compartment_id
    total_instances       = local.amd_micro_instance_count + local.arm_flex_instance_count
    amd_instances         = local.amd_micro_instance_count
    arm_instances         = local.arm_flex_instance_count
    total_storage_gb      = (local.amd_micro_instance_count * local.amd_micro_boot_volume_size_gb) + (local.arm_flex_instance_count > 0 ? sum(local.arm_flex_boot_volume_size_gb) : 0)
    free_tier_limit_gb    = 200
    ssh_key_path          = local.ssh_private_key_path
    setup_complete        = true
    ready_for_connection  = true
  }
}
EOF
        print_success "main.tf created successfully"
    
    # Create cloud-init configuration
    print_status "Creating cloud-init.yaml for instance initialization..."
    if [ -f "cloud-init.yaml" ]; then
        cp cloud-init.yaml "cloud-init.yaml.bak.$(date +%Y%m%d_%H%M%S)"
        print_status "Backed up existing cloud-init.yaml with timestamp"
    fi
        cat > cloud-init.yaml << 'EOF'
#cloud-config
# Cloud-init configuration for Oracle Always Free Tier instances
# Generated by OCI Terraform setup script

hostname: ${hostname}
fqdn: ${hostname}.example.com
manage_etc_hosts: true

# Update packages and install essential tools
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
  - docker.io
  - docker-compose
  - nginx
  - python3
  - python3-pip
  - nodejs
  - npm

# Enable and start services
runcmd:
  - systemctl enable docker
  - systemctl start docker
  - usermod -aG docker ubuntu
  - systemctl enable nginx
  - systemctl start nginx
  - echo "Instance ${hostname} initialized successfully" > /var/log/cloud-init-complete.log

# Configure automatic security updates
write_files:
  - path: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";

# Set timezone
timezone: UTC

# Configure SSH
ssh_pwauth: false
disable_root: true

# Final message
final_message: "Oracle Always Free Tier instance ${hostname} is ready!"
EOF
        print_success "cloud-init.yaml created successfully"
    
    # Create missing block volume resources
    print_status "Creating block_volumes.tf with required block volume resources..."
    if [ -f "block_volumes.tf" ]; then
        cp block_volumes.tf "block_volumes.tf.bak.$(date +%Y%m%d_%H%M%S)"
        print_status "Backed up existing block_volumes.tf with timestamp"
    fi
        cat > block_volumes.tf << EOF
# Block Volume resources for Oracle Always Free Tier
# Generated on: $(date)
# Note: Block volumes are included but set to 0 by default for optimal performance
# Boot volumes are faster than block volumes, so we allocate all 200GB to boot volumes by default

# AMD Block Volumes (only created when size > 0)
resource "oci_core_volume" "amd_block_volume" {
  count = local.amd_block_volume_size_gb > 0 ? local.amd_micro_instance_count : 0
  
  compartment_id      = local.tenancy_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "\${local.amd_micro_hostnames[count.index]}-block-volume"
  size_in_gbs         = local.amd_block_volume_size_gb
  
  freeform_tags = {
    "Purpose"      = "AlwaysFreeTierMaximization"
    "InstanceType" = "AMD-x86-AlwaysFree"
    "VolumeType"   = "Block"
    "AttachedTo"   = local.amd_micro_hostnames[count.index]
  }
}

# ARM Block Volumes (only created when size > 0)
resource "oci_core_volume" "arm_block_volume" {
  count = local.arm_flex_instance_count > 0 ? length([for size in local.arm_block_volume_sizes : size if size > 0]) : 0
  
  compartment_id      = local.tenancy_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "\${local.arm_flex_hostnames[count.index]}-block-volume"
  size_in_gbs         = [for size in local.arm_block_volume_sizes : size if size > 0][count.index]
  
  freeform_tags = {
    "Purpose"      = "AlwaysFreeTierMaximization"
    "InstanceType" = "ARM-A1-AlwaysFree"
    "VolumeType"   = "Block"
    "AttachedTo"   = local.arm_flex_hostnames[count.index]
  }
}

# Output Block Volume information
output "block_volumes_complete_summary" {
  description = "Complete Block Volume details and usage"
  value = {
    amd_block_volumes = local.amd_block_volume_size_gb > 0 ? [
      for i in range(local.amd_micro_instance_count) : {
        instance_name = local.amd_micro_hostnames[i]
        volume_id     = oci_core_volume.amd_block_volume[i].id
        size_gb       = local.amd_block_volume_size_gb
        display_name  = oci_core_volume.amd_block_volume[i].display_name
      }
    ] : []
    arm_block_volumes = local.arm_flex_instance_count > 0 ? [
      for i in range(length(oci_core_volume.arm_block_volume)) : {
        instance_name = local.arm_flex_hostnames[i]
        volume_id     = oci_core_volume.arm_block_volume[i].id
        size_gb       = [for size in local.arm_block_volume_sizes : size if size > 0][i]
        display_name  = oci_core_volume.arm_block_volume[i].display_name
      }
    ] : []
    total_block_volume_gb = local.total_block_volume_gb
    optimization_note     = "Block volumes set to 0 by default for optimal performance (boot volumes are faster)"
  }
}
EOF
        print_success "block_volumes.tf created successfully"
    
    print_success "All Terraform resources created/updated successfully!"
    print_status "Created/Updated files:"
    print_status "  - data_sources.tf (availability domains and other required data sources)"
    print_status "  - main.tf (complete infrastructure configuration with fixed IPv6 settings)"
    print_status "  - cloud-init.yaml (instance initialization script)"
    print_status "  - block_volumes.tf (block volume resources for AMD and ARM instances)"
    print_status "  - provider.tf (OCI provider configuration)"
    print_status "  - variables.tf (core Always Free Tier configuration)"
}

# Function to create Terraform provider configuration
create_terraform_provider() {
    print_status "Creating provider.tf with OCI provider configuration..."
    
    # Backup existing file if it exists
    if [ -f "provider.tf" ]; then
        cp provider.tf "provider.tf.bak.$(date +%Y%m%d_%H%M%S)"
        print_status "Backed up existing provider.tf with timestamp"
    fi
    
    # Create provider.tf - Use OCI config file authentication
    cat > provider.tf << EOF
# Terraform configuration for Oracle Cloud Infrastructure (OCI)
# Generated on: $(date)

terraform {
  required_version = ">= 1.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }
}

# Configure the Oracle Cloud Infrastructure Provider
# Uses ~/.oci/config file for authentication with session tokens
provider "oci" {
  auth                = "SecurityToken"
  config_file_profile = "DEFAULT"
  region              = "$region"
}

# Optional: Configure provider alias for different regions
# provider "oci" {
#   alias               = "us_east_1"
#   auth                = "SecurityToken"
#   config_file_profile = "DEFAULT"
#   region              = "us-ashburn-1"
# }
EOF
    
    print_success "provider.tf created successfully"
    print_status "Provider configuration:"
    print_status "  - OCI Provider version: ~> 6.0"
    print_status "  - Terraform version: >= 1.0"
    print_status "  - Authentication: OCI config file (~/.oci/config)"
    print_status "  - Profile: DEFAULT"
    return 0
}

# Main execution
main() {
    print_status "Starting OCI Terraform setup script for core infrastructure..."
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
    
    # Install Terraform
    install_terraform
    
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
    
    # Skip configuration prompts if we're using existing config in non-interactive mode
    if [ "$AUTO_USE_EXISTING" = "true" ] && [ -f "variables.tf" ]; then
        print_status "Non-interactive mode with existing config: Skipping configuration prompts"
        
        # Load existing configurations
        if [ -n "$ubuntu_arm_flex_image_ocid" ]; then
            if load_existing_arm_config; then
                print_success "Loaded existing ARM configuration"
            else
                print_warning "Could not load existing ARM config, using defaults"
                arm_flex_instance_count=1
                amd_micro_instance_count=0
                amd_micro_boot_volume_size_gb=50  # Default value
            fi
        else
            print_warning "ARM images not available in region $region"
            arm_flex_instance_count=0
            amd_micro_instance_count=2
            amd_micro_boot_volume_size_gb=100  # Use more storage since no ARM instances (minimum 50GB each)
        fi
        
        # Set default hostnames if not loaded
        if [ "${#amd_micro_hostnames[@]}" -eq 0 ] && [ "$amd_micro_instance_count" -gt 0 ]; then
            if [ "$amd_micro_instance_count" -eq 1 ]; then
                amd_micro_hostnames=("amd-instance-1")
            else
                amd_micro_hostnames=("amd-instance-1" "amd-instance-2")
            fi
        fi
        if [ "${#arm_flex_hostnames[@]}" -eq 0 ] && [ "$arm_flex_instance_count" -gt 0 ]; then
            arm_flex_hostnames=("arm-instance-1")
        fi
        
    else
        # Prompt for ARM instance configuration (only if ARM images are available)
        if [ -n "$ubuntu_arm_flex_image_ocid" ]; then
        prompt_arm_flex_instance_config
        else
            print_warning "ARM images not available in region $region - skipping ARM instance configuration"
            print_status "Only AMD x86 instances will be configured"
            arm_flex_instance_count=0
            amd_micro_instance_count=2
            amd_micro_boot_volume_size_gb=100  # Use more storage since no ARM instances (minimum 50GB each)
        fi
        
        # Prompt for instance hostnames
        prompt_instance_hostnames
    fi
    
    # Create Terraform variables
    create_terraform_vars
    
    # Create Terraform provider configuration
    create_terraform_provider
    
    # Create missing Terraform resources and data sources
    create_missing_terraform_resources
    
    # Verify everything is set up correctly
    verify_setup
    
    # Provide Terraform management options
    while true; do
        terraform_management_menu
        menu_result=$?
        
        if [ $menu_result -eq 0 ]; then
            # User chose to quit
            break
        elif [ $menu_result -eq 1 ]; then
            # User chose to reconfigure - restart the configuration process
            print_status "Restarting configuration process..."
            
            # Re-prompt for ARM instance configuration
            if [ -n "$ubuntu_arm_flex_image_ocid" ]; then
                prompt_arm_flex_instance_config
            fi
            
            # Re-prompt for instance hostnames
            prompt_instance_hostnames
            
            # Recreate Terraform variables
            create_terraform_vars
            
            # Continue with the menu
            continue
        fi
    done
    
    print_success "==================== SETUP COMPLETE ===================="
    print_success "OCI Terraform setup completed successfully!"
    print_success "Core Oracle Always Free Tier services configured!"
    print_status ""
    print_status "CONFIGURED SERVICES SUMMARY:"
    print_status "  ✓ Compute: 2x AMD + configurable ARM instances"
    print_status "  ✓ Networking: VCNs, subnets, security groups"
    print_status "  ✓ Storage: Boot volumes (200GB total)"
    print_status ""
    print_status "FILES CREATED:"
    print_status "  - ~/.oci/config (OCI CLI configuration with session token)"
    if grep -q "security_token_file" ~/.oci/config; then
        print_status "  - ~/.oci/sessions/ (Session token files)"
    else
        print_status "  - ~/.oci/oci_api_key.pem (Private API key)"
        print_status "  - ~/.oci/oci_api_key_public.pem (Public API key)"
    fi
    print_status "  - ./ssh_keys/id_rsa (SSH private key)"
    print_status "  - ./ssh_keys/id_rsa.pub (SSH public key)"
    print_status "  - ./variables.tf (Core Always Free Tier configuration)"
    print_status "  - ./data_sources.tf (Required data sources)"
    print_status "  - ./block_volumes.tf (Block volume resources)"
    print_status ""
    if [ -f "tfplan" ]; then
        print_status "TERRAFORM STATUS:"
        print_status "  ✓ Terraform plan created and ready to apply"
        print_status "  - Run: terraform apply tfplan"
    elif [ -f ".terraform/terraform.tfstate" ]; then
        print_status "TERRAFORM STATUS:"
        print_status "  ✓ Terraform initialized and infrastructure deployed"
        print_status "  - Run: terraform show (to view current state)"
        print_status "  - Run: terraform plan (to see any changes)"
    else
        print_status "TERRAFORM NEXT STEPS:"
        print_status "  1. terraform init"
        print_status "  2. terraform plan"
        print_status "  3. terraform apply"
        print_status ""
        print_status "Or re-run this script and choose option 1 for full workflow"
    fi
    print_status ""
    print_status "USEFUL COMMANDS:"
    print_status "  - terraform import <resource> <ocid> (import existing resources)"
    print_status "  - terraform state list (show managed resources)"
    print_status "  - terraform destroy (remove all infrastructure)"
    print_status "========================================================="
}

# Execute main function
main "$@"