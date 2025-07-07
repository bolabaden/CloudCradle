"""OCI Terraform Setup Implementation"""

from __future__ import annotations

import os
from datetime import datetime
from pathlib import Path
from typing import Any

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.asymmetric.types import (
    PrivateKeyTypes,
    PublicKeyTypes,
)
from jinja2 import Template
from rich.console import Console

from oci_terraform_setup.oci_client import OCIClient
from oci_terraform_setup.terraform_manager import TerraformManager

CONSOLE: Console = Console()


class OCITerraformSetup:
    """Main setup class for OCI Terraform automation with browser authentication"""

    def __init__(
        self,
        config_file: os.PathLike | str = "~/.oci/config",
        region: str | None = None,
        user_ocid: str | None = None,
        tenancy_ocid: str | None = None,
        non_interactive: bool = True,  # Default to non-interactive since we use browser auth
    ):
        self.config_file: Path = Path(os.path.normpath(config_file)).expanduser()
        self.region: str | None = region
        self.user_ocid: str | None = user_ocid
        self.tenancy_ocid: str | None = tenancy_ocid
        self.non_interactive: bool = non_interactive
        self.work_dir: Path = Path.cwd()

        # Initialize components
        self.oci_client: OCIClient | None = None
        self.terraform_manager: TerraformManager = TerraformManager(self.work_dir)
        self.ubuntu_image_ocid: str | None = None
        self.ubuntu_arm_flex_image_ocid: str | None = None
        self.availability_domain: str | None = None
        self.user_info: dict[str, str] = {}

        # Setup results
        self.results: dict[str, Any] = {}

    def run(self) -> dict[str, Any]:
        """Run the complete setup process"""
        CONSOLE.print("[bold blue]Starting OCI Terraform setup with browser authentication...[/bold blue]")

        # Step 1: Setup OCI authentication (browser-based)
        self._setup_oci_authentication()

        # Step 2: Fetch OCI information
        self._fetch_oci_info()

        # Step 3: Generate SSH keys
        self._generate_ssh_keys()

        # Step 4: Create Terraform variables
        self._create_terraform_vars()

        # Step 5: Verify setup
        self._verify_setup()

        return self.results

    def _setup_oci_authentication(self):
        """Setup OCI authentication using browser-based session tokens"""
        CONSOLE.print("[yellow]Setting up OCI authentication via browser...[/yellow]")

        try:
            # Initialize OCI client (this will handle browser auth automatically)
            self.oci_client = OCIClient(str(self.config_file))
            
            # Get user info from authenticated session
            self.user_info = self.oci_client.get_user_info()
            
            CONSOLE.print(f"[green]✅ Authenticated as: {self.user_info['user_name']}[/green]")
            CONSOLE.print(f"[green]✅ Tenancy: {self.user_info['tenancy_name']}[/green]")
            CONSOLE.print(f"[green]✅ Region: {self.user_info['region']}[/green]")

            self.results["oci_authentication"] = {
                "success": True,
                "details": f"Authenticated as {self.user_info['user_name']} in {self.user_info['region']}",
            }

        except Exception as e:
            CONSOLE.print(f"[red]❌ Authentication failed: {e.__class__.__name__}: {e}[/red]")
            self.results["oci_authentication"] = {
                "success": False,
                "details": f"{e.__class__.__name__}: {e}",
            }
            raise

    def _fetch_oci_info(self):
        """Fetch OCI information"""
        CONSOLE.print("[yellow]Fetching OCI information...[/yellow]")

        try:
            if self.oci_client is None:
                raise ValueError("OCI client not initialized")

            # Test connectivity
            self.oci_client.test_connectivity()
            CONSOLE.print("✅ OCI connectivity test passed")

            # Fetch availability domains
            availability_domains: list[str] = self.oci_client.get_availability_domains()
            self.availability_domain = (
                availability_domains[0] if availability_domains else None
            )

            # Fetch Ubuntu images
            ubuntu_images: dict[str, str] = self.oci_client.get_ubuntu_images()
            self.ubuntu_image_ocid = ubuntu_images.get("x86_64")
            self.ubuntu_arm_flex_image_ocid = ubuntu_images.get(
                "arm64",
                ubuntu_images.get("x86_64"),  # Fallback to x86_64 if no ARM image found
            )

            # Ensure we have at least one image
            if self.ubuntu_image_ocid is None:
                raise ValueError("No Ubuntu x86_64 image found")

            # Ensure ARM image is set (use x86_64 as fallback)
            if self.ubuntu_arm_flex_image_ocid is None:
                self.ubuntu_arm_flex_image_ocid = self.ubuntu_image_ocid
                CONSOLE.print("[yellow]Warning: No ARM image found, using x86_64 image for ARM instances[/yellow]")
            else:
                CONSOLE.print(f"[gray]Found ARM image: {self.ubuntu_arm_flex_image_ocid}[/gray]")

            # Update instance variables from user info
            self.user_ocid = self.user_info["user_ocid"]
            self.tenancy_ocid = self.user_info["tenancy_ocid"]
            self.region = self.user_info["region"]

            self.results["oci_info"] = {
                "success": True,
                "details": f"Region: {self.region}, AD: {self.availability_domain}",
            }

        except Exception as e:
            CONSOLE.print(f"[red]❌ Failed to fetch OCI info: {e.__class__.__name__}: {e}[/red]")
            self.results["oci_info"] = {
                "success": False,
                "details": f"{e.__class__.__name__}: {e}",
            }
            raise

    def _generate_ssh_keys(self):
        """Generate SSH key pair"""
        CONSOLE.print("[yellow]Generating SSH key pair...[/yellow]")

        ssh_dir: Path = self.work_dir / "ssh_keys"
        ssh_dir.mkdir(exist_ok=True)

        private_key_path: Path = ssh_dir / "id_rsa"
        public_key_path: Path = ssh_dir / "id_rsa.pub"

        # Clean up any directory conflicts
        if private_key_path.exists() and private_key_path.is_dir():
            CONSOLE.print("WARNING: SSH key file path is a directory! Fixing now...")
            private_key_path.rmdir()
        if public_key_path.exists() and public_key_path.is_dir():
            CONSOLE.print("WARNING: SSH public key file path is a directory! Fixing now...")
            public_key_path.rmdir()

        if not private_key_path.exists():
            try:
                # Generate SSH key pair
                private_key_obj: PrivateKeyTypes = rsa.generate_private_key(
                    public_exponent=65537,
                    key_size=2048,
                )

                # Save private key in OpenSSH format
                private_key_bytes = private_key_obj.private_bytes(
                    encoding=serialization.Encoding.PEM,
                    format=serialization.PrivateFormat.OpenSSH,
                    encryption_algorithm=serialization.NoEncryption(),
                )
                private_key_path.write_bytes(private_key_bytes)

                # Save public key in OpenSSH format
                public_key: PublicKeyTypes = private_key_obj.public_key()
                public_key_bytes = public_key.public_bytes(
                    encoding=serialization.Encoding.OpenSSH,
                    format=serialization.PublicFormat.OpenSSH,
                )
                public_key_path.write_bytes(public_key_bytes)

                # Set permissions
                os.chmod(private_key_path, 0o600)
                os.chmod(public_key_path, 0o644)

                CONSOLE.print("✅ Generated new SSH key pair")

            except Exception as e:
                CONSOLE.print(f"[red]❌ Failed to generate SSH keys: {e.__class__.__name__}: {e}[/red]")
                self.results["ssh_keys"] = {
                    "success": False,
                    "details": f"{e.__class__.__name__}: {e}",
                }
                raise
        else:
            CONSOLE.print("✅ Using existing SSH key pair")

        self.results["ssh_keys"] = {
            "success": True,
            "details": f"Private: {private_key_path}, Public: {public_key_path}",
        }

    def _create_terraform_vars(self):
        """Create Terraform variables file"""
        CONSOLE.print("[yellow]Creating Terraform variables...[/yellow]")

        try:
            # Load template
            template_content: str = """# Automatically generated OCI Terraform variables
# Generated on: {{ timestamp }}
# Region: {{ region }}
# Authenticated as: {{ user_name }} ({{ user_ocid }})

locals {
  # Per README: availability_domain == tenancy-ocid == compartment_id
  availability_domain  = "{{ tenancy_ocid }}"
  compartment_id       = "{{ tenancy_ocid }}"
  
  # Dynamically fetched Ubuntu images for region {{ region }}
  ubuntu2404ocid       = "{{ ubuntu_image_ocid }}"
  ubuntu2404_arm_flex_ocid  = "{{ ubuntu_arm_flex_image_ocid }}"
  
  # OCI Authentication (using session token authentication)
  user_ocid            = "{{ user_ocid }}"
  tenancy_ocid         = "{{ tenancy_ocid }}"
  region               = "{{ region }}"
  
  # SSH Configuration
  ssh_pubkey_path      = pathexpand("./ssh_keys/id_rsa.pub")
  ssh_pubkey_data      = file(pathexpand("./ssh_keys/id_rsa.pub"))
  ssh_private_key_path = pathexpand("./ssh_keys/id_rsa")
}

# Additional variables for reference
variable "availability_domain_name" {
  description = "The availability domain name"
  type        = string
  default     = "{{ availability_domain }}"
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
"""

            template: Template = Template(template_content)

            # Render template
            variables_content: str = template.render(
                timestamp=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                region=self.region,
                tenancy_ocid=self.tenancy_ocid,
                ubuntu_image_ocid=self.ubuntu_image_ocid,
                ubuntu_arm_flex_image_ocid=self.ubuntu_arm_flex_image_ocid,
                user_ocid=self.user_ocid,
                user_name=self.user_info.get("user_name", "Unknown"),
                availability_domain=self.availability_domain,
            )

            # Write variables file
            variables_file: Path = self.work_dir / "variables.tf"
            if variables_file.exists():
                backup_file: Path = (
                    self.work_dir
                    / f"variables.tf.bak.{datetime.now().strftime('%Y%m%d_%H%M%S')}"
                )
                variables_file.replace(backup_file)
                CONSOLE.print(f"[gray]Backed up existing variables.tf to {backup_file}[/gray]")

            variables_file.write_text(variables_content)
            CONSOLE.print(f"✅ Created Terraform variables: {variables_file}")

            self.results["terraform_vars"] = {
                "success": True,
                "details": f"Created: {variables_file}",
            }

        except Exception as e:
            CONSOLE.print(f"[red]❌ Failed to create Terraform variables: {e.__class__.__name__}: {e}[/red]")
            self.results["terraform_vars"] = {
                "success": False,
                "details": f"{e.__class__.__name__}: {e}",
            }
            raise

    def _verify_setup(self):
        """Verify complete setup"""
        CONSOLE.print("[yellow]Verifying setup...[/yellow]")

        try:
            # Check required files
            required_files: list[Path] = [
                self.config_file,
                self.work_dir / "ssh_keys" / "id_rsa",
                self.work_dir / "ssh_keys" / "id_rsa.pub",
                self.work_dir / "variables.tf",
            ]

            for file_path in required_files:
                if not file_path.exists():
                    raise FileNotFoundError(f"Required file missing: '{file_path}'")

            # Test OCI connectivity again
            if self.oci_client is None:
                raise ValueError("OCI client not initialized")
            self.oci_client.test_connectivity()

            CONSOLE.print("✅ All files present and connectivity verified")

            self.results["verification"] = {
                "success": True,
                "details": "All files present and connectivity verified",
            }

        except Exception as e:
            CONSOLE.print(f"[red]❌ Verification failed: {e.__class__.__name__}: {e}[/red]")
            self.results["verification"] = {
                "success": False,
                "details": f"{e.__class__.__name__}: {e}",
            }
            raise

    def initialize_terraform(self):
        """Initialize Terraform"""
        CONSOLE.print("[yellow]Initializing Terraform...[/yellow]")

        try:
            self.terraform_manager.init()
            CONSOLE.print("✅ Terraform initialized successfully")

            # Show next steps
            CONSOLE.print("\n[bold green]Next steps:[/bold green]")
            CONSOLE.print("1. terraform plan")
            CONSOLE.print("2. terraform apply")

        except Exception as e:
            CONSOLE.print(f"[red]❌ Terraform initialization failed: {e.__class__.__name__}: {e}[/red]")
            raise
