#!/usr/bin/env python3
"""
Oracle Cloud Infrastructure (OCI) Terraform Setup Script
Cross-platform Python implementation for Always Free Tier management

Usage:
    Interactive mode:        python setup_oci_terraform.py
    Non-interactive mode:    NON_INTERACTIVE=true AUTO_USE_EXISTING=true AUTO_DEPLOY=true python setup_oci_terraform.py
    Use existing config:     AUTO_USE_EXISTING=true python setup_oci_terraform.py
    Auto deploy only:        AUTO_DEPLOY=true python setup_oci_terraform.py
    Skip to deploy:          SKIP_CONFIG=true python setup_oci_terraform.py

Key features:
    - Completely idempotent: safe to run multiple times
    - Comprehensive resource detection before any deployment
    - Strict Free Tier limit validation
    - Robust existing resource import
    - Cross-platform (Windows, Linux, macOS)
"""

import os
import sys
import json
import subprocess
import shutil
import time
import re
import platform
import tempfile
import zipfile
import urllib.request
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Any, Union
from dataclasses import dataclass, field
from enum import Enum
import configparser
import base64
from collections import defaultdict

try:
    import click
    from rich.console import Console
    from rich.panel import Panel
    from rich.table import Table
    from rich.prompt import Prompt, Confirm, IntPrompt
    from rich.text import Text
    from rich import print as rprint
except ImportError:
    print("ERROR: Required packages not installed. Run: pip install -r requirements.txt")
    sys.exit(1)

# ============================================================================
# CONFIGURATION AND CONSTANTS
# ============================================================================

# Non-interactive mode support
NON_INTERACTIVE = os.getenv("NON_INTERACTIVE", "false").lower() == "true"
AUTO_USE_EXISTING = os.getenv("AUTO_USE_EXISTING", "false").lower() == "true"
AUTO_DEPLOY = os.getenv("AUTO_DEPLOY", "false").lower() == "true"
SKIP_CONFIG = os.getenv("SKIP_CONFIG", "false").lower() == "true"
DEBUG = os.getenv("DEBUG", "false").lower() == "true"
FORCE_REAUTH = os.getenv("FORCE_REAUTH", "false").lower() == "true"

# Optional Terraform remote backend
TF_BACKEND = os.getenv("TF_BACKEND", "local")  # values: local | oci
TF_BACKEND_BUCKET = os.getenv("TF_BACKEND_BUCKET", "")
TF_BACKEND_CREATE_BUCKET = os.getenv("TF_BACKEND_CREATE_BUCKET", "false").lower() == "true"
TF_BACKEND_REGION = os.getenv("TF_BACKEND_REGION", "")
TF_BACKEND_ENDPOINT = os.getenv("TF_BACKEND_ENDPOINT", "")
TF_BACKEND_STATE_KEY = os.getenv("TF_BACKEND_STATE_KEY", "terraform.tfstate")
TF_BACKEND_ACCESS_KEY = os.getenv("TF_BACKEND_ACCESS_KEY", "")
TF_BACKEND_SECRET_KEY = os.getenv("TF_BACKEND_SECRET_KEY", "")

# Retry/backoff settings for transient errors like 'Out of Capacity'
RETRY_MAX_ATTEMPTS = int(os.getenv("RETRY_MAX_ATTEMPTS", "8"))
RETRY_BASE_DELAY = int(os.getenv("RETRY_BASE_DELAY", "15"))  # seconds

# Timeout for OCI CLI calls (seconds)
OCI_CMD_TIMEOUT = int(os.getenv("OCI_CMD_TIMEOUT", "20"))

# OCI CLI configuration
OCI_CONFIG_FILE = os.getenv("OCI_CONFIG_FILE", str(Path.home() / ".oci" / "config"))
OCI_PROFILE = os.getenv("OCI_PROFILE", "DEFAULT")
OCI_AUTH_REGION = os.getenv("OCI_AUTH_REGION", "")
OCI_CLI_CONNECTION_TIMEOUT = int(os.getenv("OCI_CLI_CONNECTION_TIMEOUT", "10"))
OCI_CLI_READ_TIMEOUT = int(os.getenv("OCI_CLI_READ_TIMEOUT", "60"))
OCI_CLI_MAX_RETRIES = int(os.getenv("OCI_CLI_MAX_RETRIES", "3"))

# Oracle Free Tier Limits (as of 2025)
FREE_TIER_MAX_AMD_INSTANCES = 2
FREE_TIER_AMD_SHAPE = "VM.Standard.E2.1.Micro"
FREE_TIER_MAX_ARM_OCPUS = 4
FREE_TIER_MAX_ARM_MEMORY_GB = 24
FREE_TIER_ARM_SHAPE = "VM.Standard.A1.Flex"
FREE_TIER_MAX_STORAGE_GB = 200
FREE_TIER_MIN_BOOT_VOLUME_GB = 47
FREE_TIER_MAX_ARM_INSTANCES = 4
FREE_TIER_MAX_VCNS = 2

# Global console for rich output
console = Console()

# ============================================================================
# DATA STRUCTURES
# ============================================================================

@dataclass
class OciConfig:
    """OCI configuration values"""
    tenancy_ocid: str = ""
    user_ocid: str = ""
    region: str = ""
    fingerprint: str = ""
    availability_domain: str = ""
    ubuntu_image_ocid: str = ""
    ubuntu_arm_flex_image_ocid: str = ""
    ssh_public_key: str = ""
    auth_method: str = "security_token"

@dataclass
class InstanceConfig:
    """Instance configuration"""
    amd_micro_instance_count: int = 0
    amd_micro_boot_volume_size_gb: int = 50
    arm_flex_instance_count: int = 0
    arm_flex_ocpus_per_instance: List[int] = field(default_factory=list)
    arm_flex_memory_per_instance: List[int] = field(default_factory=list)
    arm_flex_boot_volume_size_gb: List[int] = field(default_factory=list)
    arm_flex_block_volumes: List[int] = field(default_factory=list)
    amd_micro_hostnames: List[str] = field(default_factory=list)
    arm_flex_hostnames: List[str] = field(default_factory=list)

@dataclass
class ExistingResource:
    """Existing resource information"""
    id: str
    name: str
    state: str = ""
    additional_info: Dict[str, Any] = field(default_factory=dict)

# Global state
oci_config = OciConfig()
instance_config = InstanceConfig()
existing_vcns: Dict[str, ExistingResource] = {}
existing_subnets: Dict[str, ExistingResource] = {}
existing_internet_gateways: Dict[str, ExistingResource] = {}
existing_route_tables: Dict[str, ExistingResource] = {}
existing_security_lists: Dict[str, ExistingResource] = {}
existing_amd_instances: Dict[str, ExistingResource] = {}
existing_arm_instances: Dict[str, ExistingResource] = {}
existing_boot_volumes: Dict[str, ExistingResource] = {}
existing_block_volumes: Dict[str, ExistingResource] = {}

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

def print_status(message: str) -> None:
    """Print status message"""
    console.print(f"[blue][INFO][/blue] {message}")

def print_success(message: str) -> None:
    """Print success message"""
    console.print(f"[green][SUCCESS][/green] {message}")

def print_warning(message: str) -> None:
    """Print warning message"""
    console.print(f"[yellow][WARNING][/yellow] {message}")

def print_error(message: str) -> None:
    """Print error message"""
    console.print(f"[red][ERROR][/red] {message}")

def print_debug(message: str) -> None:
    """Print debug message"""
    if DEBUG:
        console.print(f"[cyan][DEBUG][/cyan] {message}")

def print_header(title: str) -> None:
    """Print header"""
    console.print()
    console.print(Panel(title, style="bold magenta", expand=False))
    console.print()

def print_subheader(title: str) -> None:
    """Print subheader"""
    console.print()
    console.print(f"[bold cyan]── {title} ──[/bold cyan]")
    console.print()

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

def command_exists(command: str) -> bool:
    """Check if a command exists in PATH"""
    return shutil.which(command) is not None

def is_wsl() -> bool:
    """Check if running in WSL"""
    try:
        with open("/proc/version", "r") as f:
            return "microsoft" in f.read().lower() or "wsl" in f.read().lower()
    except (FileNotFoundError, IOError):
        return False

def is_windows() -> bool:
    """Check if running on Windows"""
    return platform.system() == "Windows"

def default_region_for_host() -> str:
    """Best-effort heuristic when the user doesn't specify a region"""
    tz_str = ""
    
    # Try to get timezone
    if is_windows():
        try:
            import winreg
            key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Control\TimeZoneInformation")
            tz_str = winreg.QueryValueEx(key, "TimeZoneKeyName")[0]
            winreg.CloseKey(key)
        except Exception:
            try:
                # Alternative: use environment variable
                tz_str = os.getenv("TZ", "")
            except Exception:
                pass
    else:
        try:
            tz_str = Path("/etc/timezone").read_text().strip()
        except Exception:
            try:
                # Try /etc/localtime symlink
                if Path("/etc/localtime").is_symlink():
                    tz_str = str(Path("/etc/localtime").readlink())
            except Exception:
                tz_str = os.getenv("TZ", "")

    # Map timezone to region
    tz_lower = tz_str.lower()
    if any(x in tz_lower for x in ["chicago", "central", "winnipeg", "mexico_city"]):
        return "us-chicago-1"
    elif any(x in tz_lower for x in ["new_york", "toronto", "montreal", "eastern"]):
        return "us-ashburn-1"
    elif any(x in tz_lower for x in ["los_angeles", "vancouver", "pacific"]):
        return "us-sanjose-1"
    elif any(x in tz_lower for x in ["phoenix", "denver", "mountain"]):
        return "us-phoenix-1"
    elif any(x in tz_lower for x in ["london", "dublin"]):
        return "uk-london-1"
    elif any(x in tz_lower for x in ["paris", "berlin", "rome", "madrid", "amsterdam", "stockholm", "zurich", "europe"]):
        return "eu-frankfurt-1"
    elif "tokyo" in tz_lower:
        return "ap-tokyo-1"
    elif "seoul" in tz_lower:
        return "ap-seoul-1"
    elif "singapore" in tz_lower:
        return "ap-singapore-1"
    elif any(x in tz_lower for x in ["sydney", "melbourne"]):
        return "ap-sydney-1"
    else:
        return "us-chicago-1"

def open_url_best_effort(url: str) -> bool:
    """Open URL in default browser"""
    if not url:
        return False

    try:
        if is_wsl() and command_exists("powershell.exe"):
            subprocess.run(
                ["powershell.exe", "-NoProfile", "-Command", f"Start-Process '{url}'"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
            return True
        elif is_windows():
            os.startfile(url)
            return True
        elif command_exists("xdg-open"):
            subprocess.run(
                ["xdg-open", url],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
            return True
        elif command_exists("open"):
            subprocess.run(
                ["open", url],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
            return True
    except Exception:
        pass

    return False

def read_oci_config_value(key: str, file_path: Optional[str] = None, profile: Optional[str] = None) -> Optional[str]:
    """Read a value from OCI config file"""
    config_file = Path(file_path or OCI_CONFIG_FILE)
    profile_name = profile or OCI_PROFILE

    if not config_file.exists():
        return None

    try:
        config = configparser.ConfigParser()
        config.read(config_file)

        if profile_name in config:
            return config[profile_name].get(key, None)
    except Exception as e:
        print_debug(f"Error reading config: {e}")

    return None

def is_instance_principal_available() -> bool:
    """Check if OCI metadata service is reachable"""
    if not command_exists("curl"):
        return False

    try:
        result = subprocess.run(
            ["curl", "-s", "--connect-timeout", "1", "--max-time", "2", "http://169.254.169.254/opc/v2/"],
            capture_output=True,
            timeout=3
        )
        return result.returncode == 0
    except Exception:
        return False

def validate_existing_oci_config() -> bool:
    """Validate existing OCI configuration"""
    config_file = Path(OCI_CONFIG_FILE)
    if not config_file.exists():
        print_warning(f"OCI config not found at {OCI_CONFIG_FILE}")
        return False

    cfg_auth = read_oci_config_value("auth")
    key_file = read_oci_config_value("key_file")
    token_file = read_oci_config_value("security_token_file")
    pass_phrase = read_oci_config_value("pass_phrase")

    if cfg_auth:
        oci_config.auth_method = cfg_auth
    elif token_file:
        oci_config.auth_method = "security_token"
    elif key_file:
        oci_config.auth_method = "api_key"

    auth_method = oci_config.auth_method

    if auth_method == "security_token":
        if not token_file or not Path(token_file).exists():
            print_warning("security_token auth selected but security_token_file is missing")
            return False
    elif auth_method == "api_key":
        if not key_file or not Path(key_file).exists():
            print_warning("api_key auth selected but key_file is missing")
            return False
        # Check if key is encrypted
        try:
            key_content = Path(key_file).read_text()
            if "ENCRYPTED" in key_content:
                if not os.getenv("OCI_CLI_PASSPHRASE") and not pass_phrase:
                    print_warning("Private key is encrypted but no passphrase provided")
                    return False
        except Exception:
            pass
    elif auth_method in ["instance_principal", "resource_principal", "oke_workload_identity", "instance_obo_user"]:
        if not is_instance_principal_available():
            print_warning("Instance principal auth selected but OCI metadata service is unreachable")
            return False
    elif not auth_method:
        print_warning("Unable to determine auth method from config")
        return False
    else:
        print_warning(f"Unsupported auth method '{auth_method}' in config")
        return False

    return True

def run_command(cmd: Union[str, List[str]], capture_output: bool = True, timeout: Optional[int] = None, check: bool = False) -> subprocess.CompletedProcess:
    """Run a command with proper error handling"""
    if isinstance(cmd, str):
        cmd = cmd.split()

    try:
        result = subprocess.run(
            cmd,
            capture_output=capture_output,
            text=True,
            timeout=timeout,
            check=check
        )
        return result
    except subprocess.TimeoutExpired:
        print_warning(f"Command timed out after {timeout}s: {' '.join(cmd)}")
        raise
    except Exception as e:
        print_debug(f"Command execution error: {e}")
        raise

def oci_cmd(cmd: str) -> Optional[str]:
    """Run OCI command with proper authentication handling"""
    base_args = [
        "oci",
        "--config-file", OCI_CONFIG_FILE,
        "--profile", OCI_PROFILE,
        "--connection-timeout", str(OCI_CLI_CONNECTION_TIMEOUT),
        "--read-timeout", str(OCI_CLI_READ_TIMEOUT),
        "--max-retries", str(OCI_CLI_MAX_RETRIES)
    ]

    if os.getenv("OCI_CLI_AUTH"):
        base_args.extend(["--auth", os.getenv("OCI_CLI_AUTH")])
    elif oci_config.auth_method:
        base_args.extend(["--auth", oci_config.auth_method])

    full_cmd = base_args + cmd.split()

    try:
        result = run_command(full_cmd, timeout=OCI_CMD_TIMEOUT, check=False)
        if result.returncode == 0:
            return result.stdout
        else:
            print_debug(f"OCI command failed: {result.stderr}")
            return None
    except subprocess.TimeoutExpired:
        print_warning(f"OCI CLI call timed out after {OCI_CMD_TIMEOUT}s")
        return None
    except Exception as e:
        print_debug(f"OCI command error: {e}")
        return None

def safe_jq(json_str: Optional[str], query: str, default: Any = None) -> Any:
    """Safe JSON parsing with jq-like query"""
    if not json_str or json_str.strip() == "null" or not json_str.strip():
        return default

    try:
        data = json.loads(json_str)
        # Simple path query (e.g., "data[0].id" or ".data.id")
        if query.startswith("."):
            query = query[1:]

        # Handle direct array access like "[0]"
        if query.startswith("["):
            index = int(query.strip("[]"))
            if isinstance(data, list) and 0 <= index < len(data):
                result = data[index]
            else:
                return default
        else:
            parts = query.split(".")
            result = data
            for part in parts:
                if not part:
                    continue
                if "[" in part:
                    # Handle array access like "data[0]"
                    key, index_str = part.split("[", 1)
                    index = int(index_str.rstrip("]"))
                    if key:
                        result = result[key]
                    if isinstance(result, list) and 0 <= index < len(result):
                        result = result[index]
                    else:
                        return default
                else:
                    if isinstance(result, dict):
                        result = result.get(part)
                    else:
                        return default

        if result is None or result == "null":
            return default
        return result
    except Exception as e:
        print_debug(f"JSON parsing error: {e}")
        return default

def retry_with_backoff(func, *args, max_attempts: int = RETRY_MAX_ATTEMPTS, base_delay: int = RETRY_BASE_DELAY, **kwargs) -> Any:
    """Run a function with retry/backoff, detect Out-of-Capacity signals"""
    attempt = 1
    last_error = None

    while attempt <= max_attempts:
        print_status(f"Attempt {attempt}/{max_attempts}: {func.__name__}")
        try:
            result = func(*args, **kwargs)
            return result
        except Exception as e:
            error_str = str(e)
            if any(term in error_str.lower() for term in ["out of capacity", "out of host capacity", "outofcapacity", "outofhostcapacity"]):
                print_warning(f"Detected 'Out of Capacity' condition (attempt {attempt}).")
            else:
                print_warning(f"Command failed: {error_str}")

            last_error = e

            if attempt < max_attempts:
                sleep_time = base_delay * (2 ** (attempt - 1))
                print_status(f"Retrying in {sleep_time}s...")
                time.sleep(sleep_time)
                attempt += 1
            else:
                break

    print_error(f"Command failed after {max_attempts} attempts")
    raise last_error

def run_cmd_with_retries_and_check(cmd: Union[str, List[str]]) -> Tuple[bool, bool]:
    """Run command with retries and check for Out of Capacity"""
    out_of_capacity_detected = False

    def _run():
        result = run_command(cmd, check=False)
        if result.returncode != 0:
            error_output = result.stderr or result.stdout or ""
            if any(term in error_output.lower() for term in ["out of capacity", "out of host capacity", "outofcapacity", "outofhostcapacity"]):
                nonlocal out_of_capacity_detected
                out_of_capacity_detected = True
            raise subprocess.CalledProcessError(result.returncode, cmd, result.stdout, result.stderr)
        return result.stdout

    try:
        output = retry_with_backoff(_run)
        # Check if output is valid JSON
        try:
            json.loads(output)
            return True, out_of_capacity_detected
        except json.JSONDecodeError:
            return output.strip() != "", out_of_capacity_detected
    except Exception:
        return False, out_of_capacity_detected

# ============================================================================
# INSTALLATION FUNCTIONS
# ============================================================================

def install_prerequisites() -> bool:
    """Install required prerequisites"""
    print_subheader("Installing Prerequisites")

    packages_to_install = []

    # Check for required commands
    if not command_exists("jq"):
        packages_to_install.append("jq")
    if not command_exists("curl"):
        packages_to_install.append("curl")
    if not command_exists("unzip"):
        packages_to_install.append("unzip")

    if packages_to_install:
        print_status(f"Installing required packages: {', '.join(packages_to_install)}")
        if is_windows():
            print_warning("Please install packages manually on Windows:")
            print_warning(f"  - jq: https://stedolan.github.io/jq/download/")
            print_warning(f"  - curl: Included with Windows 10+")
            print_warning(f"  - unzip: Included with Windows 10+")
        elif command_exists("apt-get"):
            try:
                subprocess.run(["sudo", "apt-get", "update", "-qq"], check=True)
                subprocess.run(["sudo", "apt-get", "install", "-y", "-qq"] + packages_to_install, check=True)
            except subprocess.CalledProcessError:
                print_error("Failed to install packages")
                return False
        elif command_exists("yum"):
            try:
                subprocess.run(["sudo", "yum", "install", "-y", "-q"] + packages_to_install, check=True)
            except subprocess.CalledProcessError:
                print_error("Failed to install packages")
                return False
        elif command_exists("dnf"):
            try:
                subprocess.run(["sudo", "dnf", "install", "-y", "-q"] + packages_to_install, check=True)
            except subprocess.CalledProcessError:
                print_error("Failed to install packages")
                return False
        else:
            print_error("Cannot install packages: no supported package manager found")
            return False

    # Verify all required commands exist
    required_commands = ["jq", "openssl", "ssh-keygen", "curl"]
    for cmd in required_commands:
        if not command_exists(cmd):
            print_error(f"Required command '{cmd}' is not available")
            if is_windows():
                print_warning(f"Please install {cmd} manually")
            return False

    print_success("All prerequisites installed")
    return True

def install_oci_cli() -> bool:
    """Install OCI CLI"""
    print_subheader("OCI CLI Setup")

    # Check if OCI CLI is already installed and working
    if command_exists("oci"):
        try:
            result = run_command(["oci", "--version"], check=False)
            if result.returncode == 0:
                version = result.stdout.split("\n")[0] if result.stdout else "unknown"
                print_status(f"OCI CLI already installed: {version}")
                return True
        except Exception:
            pass

    print_status("Installing OCI CLI...")

    # Check if Python is installed (we're running Python, so it's available)
    # Create virtual environment for OCI CLI
    venv_dir = Path.cwd() / ".venv"
    if not venv_dir.exists():
        print_status("Creating Python virtual environment...")
        try:
            subprocess.run([sys.executable, "-m", "venv", str(venv_dir)], check=True)
        except subprocess.CalledProcessError:
            print_error("Failed to create virtual environment")
            return False

    # Determine activation script
    if is_windows():
        activate_script = venv_dir / "Scripts" / "activate.bat"
        pip_cmd = [str(venv_dir / "Scripts" / "pip.exe")]
    else:
        activate_script = venv_dir / "bin" / "activate"
        pip_cmd = [str(venv_dir / "bin" / "pip")]

    print_status("Installing OCI CLI in virtual environment...")
    try:
        subprocess.run(pip_cmd + ["install", "--upgrade", "pip", "--quiet"], check=True)
        subprocess.run(pip_cmd + ["install", "oci-cli", "--quiet"], check=True)
    except subprocess.CalledProcessError:
        print_error("Failed to install OCI CLI")
        return False

    print_success("OCI CLI installed successfully")
    return True

def install_terraform() -> bool:
    """Install Terraform"""
    print_subheader("Terraform Setup")

    if command_exists("terraform"):
        try:
            result = run_command(["terraform", "version", "-json"], check=False)
            if result.returncode == 0:
                try:
                    version_data = json.loads(result.stdout)
                    version = version_data.get("terraform_version", "unknown")
                except json.JSONDecodeError:
                    # Fallback to text parsing
                    result = run_command(["terraform", "version"], check=False)
                    version = result.stdout.split("\n")[0].split()[1].lstrip("v") if result.stdout else "unknown"
                print_status(f"Terraform already installed: version {version}")
                return True
        except Exception:
            pass

    print_status("Installing Terraform...")

    # Try snap first on Linux
    if not is_windows() and command_exists("snap"):
        try:
            subprocess.run(["sudo", "snap", "install", "terraform", "--classic"], check=True)
            print_success("Terraform installed via snap")
            return True
        except subprocess.CalledProcessError:
            pass

    # Manual installation
    try:
        # Get latest version
        with urllib.request.urlopen("https://api.github.com/repos/hashicorp/terraform/releases/latest", timeout=10) as response:
            data = json.loads(response.read())
            latest_version = data.get("tag_name", "1.7.0").lstrip("v")
    except Exception:
        latest_version = "1.7.0"
        print_warning(f"Could not fetch latest version, using fallback: {latest_version}")

    # Determine architecture
    arch = platform.machine().lower()
    if arch in ["x86_64", "amd64"]:
        arch = "amd64"
    elif arch in ["aarch64", "arm64"]:
        arch = "arm64"
    else:
        arch = "amd64"

    # Determine OS
    os_name = platform.system().lower()
    if os_name == "windows":
        os_name = "windows"
        ext = ".zip"
        bin_name = "terraform.exe"
    elif os_name == "darwin":
        os_name = "darwin"
        ext = ".zip"
        bin_name = "terraform"
    else:
        os_name = "linux"
        ext = ".zip"
        bin_name = "terraform"

    tf_url = f"https://releases.hashicorp.com/terraform/{latest_version}/terraform_{latest_version}_{os_name}_{arch}{ext}"

    print_status(f"Downloading Terraform {latest_version} for {os_name}_{arch}...")

    try:
        with tempfile.TemporaryDirectory() as temp_dir:
            zip_path = Path(temp_dir) / f"terraform{ext}"
            with urllib.request.urlopen(tf_url, timeout=30) as response:
                with open(zip_path, "wb") as f:
                    f.write(response.read())

            # Extract
            extract_dir = Path(temp_dir) / "extract"
            extract_dir.mkdir()
            with zipfile.ZipFile(zip_path, "r") as zip_ref:
                zip_ref.extractall(extract_dir)

            # Install
            terraform_bin = extract_dir / bin_name
            if is_windows():
                install_path = Path("C:/Windows/System32") / bin_name
                # Try user-local install instead
                install_path = Path.home() / "AppData" / "Local" / "Microsoft" / "WindowsApps" / bin_name
                install_path.parent.mkdir(parents=True, exist_ok=True)
            else:
                install_path = Path("/usr/local/bin") / bin_name

            # Copy to install location
            if is_windows():
                shutil.copy2(terraform_bin, install_path)
            else:
                subprocess.run(["sudo", "cp", str(terraform_bin), str(install_path)], check=True)
                subprocess.run(["sudo", "chmod", "+x", str(install_path)], check=True)

            # Verify installation
            if command_exists("terraform"):
                print_success("Terraform installed successfully")
                return True
    except Exception as e:
        print_error(f"Failed to install Terraform: {e}")
        return False

    return False

# ============================================================================
# OCI AUTHENTICATION FUNCTIONS
# ============================================================================

def detect_auth_method() -> None:
    """Detect authentication method from config"""
    config_file = Path(OCI_CONFIG_FILE)
    if config_file.exists():
        cfg_auth = read_oci_config_value("auth")
        token_file = read_oci_config_value("security_token_file")
        key_file = read_oci_config_value("key_file")

        if cfg_auth:
            oci_config.auth_method = cfg_auth
        elif token_file:
            oci_config.auth_method = "security_token"
        elif key_file:
            oci_config.auth_method = "api_key"

    print_debug(f"Detected auth method: {oci_config.auth_method} (profile: {OCI_PROFILE}, config: {OCI_CONFIG_FILE})")

def test_oci_connectivity() -> bool:
    """Test OCI API connectivity"""
    print_status("Testing OCI API connectivity...")

    # Method 1: List regions (simplest test)
    print_status(f"Checking IAM region list (timeout {OCI_CMD_TIMEOUT}s)...")
    result = oci_cmd("iam region list")
    if result:
        print_debug("Connectivity test passed (region list)")
        return True
    else:
        print_warning("Region list query failed or timed out")

    # Method 2: Get tenancy info if we have it
    test_tenancy = read_oci_config_value("tenancy")
    if test_tenancy:
        print_status(f"Checking IAM tenancy get (timeout {OCI_CMD_TIMEOUT}s)...")
        result = oci_cmd(f"iam tenancy get --tenancy-id {test_tenancy}")
        if result:
            print_debug("Connectivity test passed (tenancy get)")
            return True
        else:
            print_warning("Tenancy get failed or timed out")

    print_debug("All connectivity tests failed")
    return False

def setup_oci_config() -> bool:
    """Setup OCI configuration"""
    global OCI_CONFIG_FILE, OCI_PROFILE
    
    print_subheader("OCI Authentication")

    config_file = Path(OCI_CONFIG_FILE)
    config_file.parent.mkdir(parents=True, exist_ok=True)

    existing_config_invalid = False
    if config_file.exists():
        print_status("Existing OCI configuration found")
        detect_auth_method()

        print_status("Validating existing OCI configuration...")
        if not validate_existing_oci_config():
            existing_config_invalid = True
            print_warning("Existing OCI configuration is incomplete or requires interactive input")
        else:
            # Test existing configuration
            print_status("Testing existing OCI configuration connectivity...")
            if test_oci_connectivity():
                print_success("Existing OCI configuration is valid")
                return True

        print_warning("Existing configuration failed connectivity test (will retry with refresh)")

        # Check if session token expired
        if oci_config.auth_method == "security_token":
            print_status(f"Attempting to refresh session token (timeout {OCI_CMD_TIMEOUT}s)...")
            result = oci_cmd("session refresh")
            if result and test_oci_connectivity():
                print_success("Session token refreshed successfully")
                return True
            else:
                print_warning("Session refresh failed or timed out")
                print_status("Session refresh did not restore connectivity, initiating interactive authentication as a fallback...")

    # Setup new authentication
    print_status("Setting up browser-based authentication...")
    print_status("This will open a browser window for you to log in to Oracle Cloud.")

    if NON_INTERACTIVE:
        print_error("Cannot perform interactive authentication in non-interactive mode. Aborting.")
        return False

    # Determine region to use for browser login
    auth_region = read_oci_config_value("region") or OCI_AUTH_REGION or default_region_for_host()

    if not NON_INTERACTIVE:
        auth_region = Prompt.ask("Region for authentication", default=auth_region)

    # Allow forcing re-auth / new profile
    if FORCE_REAUTH:
        new_profile = Prompt.ask("Enter new profile name to create/use", default="NEW_PROFILE")
        print_status(f"Starting interactive session authenticate for profile '{new_profile}'...")
        print_status(f"Using region '{auth_region}' for authentication")

        cmd = [
            "oci", "session", "authenticate",
            "--no-browser" if is_wsl() else None,
            "--profile-name", new_profile,
            "--region", auth_region,
            "--session-expiration-in-minutes", "60"
        ]
        cmd = [c for c in cmd if c is not None]

        try:
            result = run_command(cmd, check=False)
            if result.returncode != 0:
                error_output = result.stderr or result.stdout or ""
                if any(term in error_output.lower() for term in ["config file", "is invalid", "config errors", "user", "missing"]):
                    print_warning("OCI CLI reports the config file is invalid or missing required fields. Offering repair options...")
                    existing_config_invalid = True
                else:
                    print_error("Authentication failed")
                    return False
            else:
                # Extract URL if in WSL
                if is_wsl():
                    output = result.stdout or ""
                    url_match = re.search(r"https://[^\s]+", output)
                    if url_match:
                        url = url_match.group(0)
                        print_status("Opening browser for login URL (WSL)...")
                        open_url_best_effort(url)
        except Exception as e:
            print_error(f"Authentication error: {e}")
            return False

        OCI_PROFILE = new_profile
        oci_config.auth_method = "security_token"

    # Handle invalid config repair
    if existing_config_invalid:
        print_warning("Detected invalid or incomplete OCI config file - AUTOMATICALLY DELETING AND FORCING FRESH AUTHENTICATION")

        # Backup and delete corrupted config
        if config_file.exists():
            backup_name = f"{config_file}.corrupted.{time.strftime('%Y%m%d_%H%M%S')}"
            print_status(f"Backing up corrupted config to {backup_name}")
            try:
                shutil.copy2(config_file, backup_name)
            except Exception:
                pass
            print_status(f"Forcibly deleting corrupted config file: {config_file}")
            config_file.unlink()

        # Delete temp config files
        temp_config = Path.home() / ".oci" / "config.session_auth"
        if temp_config.exists():
            temp_config.unlink(missing_ok=True)

        # Create completely new profile with session auth
        new_profile = "DEFAULT"
        print_status(f"Creating fresh OCI configuration with browser-based authentication for profile '{new_profile}'...")
        print_status("This will open your browser to log into Oracle Cloud.")
        print_status("")
        print_status(f"Using region '{auth_region}' for authentication")
        print_status("")

        OCI_CONFIG_FILE = str(Path.home() / ".oci" / "config")
        OCI_PROFILE = new_profile
        if "OCI_CLI_CONFIG_FILE" in os.environ:
            del os.environ["OCI_CLI_CONFIG_FILE"]

        cmd = [
            "oci", "session", "authenticate",
            "--no-browser" if is_wsl() else None,
            "--profile-name", new_profile,
            "--region", auth_region,
            "--session-expiration-in-minutes", "60"
        ]
        cmd = [c for c in cmd if c is not None]

        try:
            result = run_command(cmd, check=False)
            if result.returncode == 0:
                output = result.stdout or ""
                if is_wsl():
                    url_match = re.search(r"https://[^\s]+", output)
                    if url_match:
                        url = url_match.group(0)
                        print_status("Opening browser for login URL (WSL)...")
                        open_url_best_effort(url)
                        print_status("")
                        print_status("After completing browser authentication, press Enter to continue...")
                        input()
                oci_config.auth_method = "security_token"
                if test_oci_connectivity():
                    print_success(f"Fresh session authentication succeeded for profile '{new_profile}'")
                    return True
                else:
                    print_warning("Session auth completed but connectivity test failed")
            else:
                print_error("Browser-based authentication failed. Please verify your Oracle Cloud credentials and try again.")
                return False
        except Exception as e:
            print_error(f"Authentication error: {e}")
            return False

    # Interactive authenticate (may open browser)
    if not FORCE_REAUTH:
        print_status(f"Using profile '{OCI_PROFILE}' for interactive session authenticate...")
        print_status(f"Using region '{auth_region}' for authentication")

        cmd = [
            "oci", "session", "authenticate",
            "--no-browser" if is_wsl() else None,
            "--profile-name", OCI_PROFILE,
            "--region", auth_region,
            "--session-expiration-in-minutes", "60"
        ]
        cmd = [c for c in cmd if c is not None]

        try:
            result = run_command(cmd, check=False)
            if result.returncode != 0:
                error_output = result.stderr or result.stdout or ""
                if any(term in error_output.lower() for term in ["config file", "is invalid", "config errors", "user", "missing"]):
                    print_warning("OCI CLI reports the config file is invalid or missing required fields.")
                    existing_config_invalid = True
                else:
                    print_error("Browser authentication failed or was cancelled")
                    return False
            else:
                if is_wsl():
                    output = result.stdout or ""
                    url_match = re.search(r"https://[^\s]+", output)
                    if url_match:
                        url = url_match.group(0)
                        print_status("Opening browser for login URL (WSL)...")
                        open_url_best_effort(url)
        except Exception as e:
            print_error(f"Authentication error: {e}")
            return False

        oci_config.auth_method = "security_token"

        # Verify the new configuration
        if test_oci_connectivity():
            print_success("OCI authentication configured successfully")
            return True

    print_error("OCI configuration verification failed")
    return False

# ============================================================================
# OCI RESOURCE DISCOVERY FUNCTIONS
# ============================================================================

def fetch_oci_config_values() -> bool:
    """Fetch OCI configuration values"""
    print_subheader("Fetching OCI Configuration")

    # Tenancy OCID
    tenancy_ocid = read_oci_config_value("tenancy")
    if not tenancy_ocid:
        print_error("Failed to fetch tenancy OCID from config")
        return False
    oci_config.tenancy_ocid = tenancy_ocid
    print_status(f"Tenancy OCID: {tenancy_ocid}")

    # User OCID
    user_ocid = read_oci_config_value("user")
    if not user_ocid:
        # Try to get from API for session token auth
        result = oci_cmd(f"iam user list --compartment-id {tenancy_ocid} --limit 1")
        if result:
            data = json.loads(result)
            if data.get("data") and len(data["data"]) > 0:
                user_ocid = data["data"][0].get("id", "")
    oci_config.user_ocid = user_ocid or "N/A (session token auth)"
    print_status(f"User OCID: {oci_config.user_ocid}")

    # Region
    region = read_oci_config_value("region")
    if not region:
        print_error("Failed to fetch region from config")
        return False
    oci_config.region = region
    print_status(f"Region: {region}")

    # Fingerprint (only for API key auth)
    if oci_config.auth_method == "security_token":
        oci_config.fingerprint = "session_token_auth"
    else:
        oci_config.fingerprint = read_oci_config_value("fingerprint") or ""

    print_debug(f"Auth fingerprint: {oci_config.fingerprint}")

    print_success("OCI configuration values fetched")
    return True

def fetch_availability_domains() -> bool:
    """Fetch availability domains"""
    print_status("Fetching availability domains...")

    result = oci_cmd(f"iam availability-domain list --compartment-id {oci_config.tenancy_ocid} --query 'data[].name' --raw-output")
    if not result:
        print_error("Failed to fetch availability domains")
        return False

    try:
        data = json.loads(result)
        if data and len(data) > 0:
            oci_config.availability_domain = data[0]
            print_success(f"Availability domain: {oci_config.availability_domain}")
            return True
    except json.JSONDecodeError:
        pass

    print_error("Failed to parse availability domain")
    return False

def fetch_ubuntu_images() -> bool:
    """Fetch Ubuntu images for region"""
    print_status(f"Fetching Ubuntu images for region {oci_config.region}...")

    # Fetch x86 (AMD64) Ubuntu image
    print_status("  Looking for x86 Ubuntu image...")
    result = oci_cmd(
        f"compute image list "
        f"--compartment-id {oci_config.tenancy_ocid} "
        f"--operating-system 'Canonical Ubuntu' "
        f"--shape '{FREE_TIER_AMD_SHAPE}' "
        f"--sort-by TIMECREATED "
        f"--sort-order DESC "
        f"--query 'data[].{{id:id,name:\"display-name\"}}' "
        f"--all"
    )

    if result:
        try:
            data = json.loads(result)
            if data and len(data) > 0:
                oci_config.ubuntu_image_ocid = data[0].get("id", "")
                x86_name = data[0].get("name", "")
                if oci_config.ubuntu_image_ocid:
                    print_success(f"  x86 image: {x86_name}")
                    print_debug(f"  x86 OCID: {oci_config.ubuntu_image_ocid}")
        except json.JSONDecodeError:
            pass

    if not oci_config.ubuntu_image_ocid:
        print_warning("  No x86 Ubuntu image found - AMD instances disabled")

    # Fetch ARM Ubuntu image
    print_status("  Looking for ARM Ubuntu image...")
    result = oci_cmd(
        f"compute image list "
        f"--compartment-id {oci_config.tenancy_ocid} "
        f"--operating-system 'Canonical Ubuntu' "
        f"--shape '{FREE_TIER_ARM_SHAPE}' "
        f"--sort-by TIMECREATED "
        f"--sort-order DESC "
        f"--query 'data[].{{id:id,name:\"display-name\"}}' "
        f"--all"
    )

    if result:
        try:
            data = json.loads(result)
            if data and len(data) > 0:
                oci_config.ubuntu_arm_flex_image_ocid = data[0].get("id", "")
                arm_name = data[0].get("name", "")
                if oci_config.ubuntu_arm_flex_image_ocid:
                    print_success(f"  ARM image: {arm_name}")
                    print_debug(f"  ARM OCID: {oci_config.ubuntu_arm_flex_image_ocid}")
        except json.JSONDecodeError:
            pass

    if not oci_config.ubuntu_arm_flex_image_ocid:
        print_warning("  No ARM Ubuntu image found - ARM instances disabled")

    return True

def generate_ssh_keys() -> bool:
    """Generate SSH keys"""
    print_status("Setting up SSH keys...")

    ssh_dir = Path.cwd() / "ssh_keys"
    ssh_dir.mkdir(exist_ok=True)

    private_key = ssh_dir / "id_rsa"
    public_key = ssh_dir / "id_rsa.pub"

    if not private_key.exists():
        print_status("Generating new SSH key pair...")
        try:
            subprocess.run(
                ["ssh-keygen", "-t", "rsa", "-b", "4096", "-f", str(private_key), "-N", "", "-q"],
                check=True
            )
            # Set permissions
            if not is_windows():
                os.chmod(private_key, 0o600)
                os.chmod(public_key, 0o644)
            print_success(f"SSH key pair generated at {ssh_dir}/")
        except subprocess.CalledProcessError:
            print_error("Failed to generate SSH key pair")
            return False
    else:
        print_status(f"Using existing SSH key pair at {ssh_dir}/")

    # Read public key
    try:
        oci_config.ssh_public_key = public_key.read_text().strip()
    except Exception as e:
        print_error(f"Failed to read SSH public key: {e}")
        return False

    return True

# ============================================================================
# COMPREHENSIVE RESOURCE INVENTORY
# ============================================================================

def inventory_all_resources() -> None:
    """Inventory all existing OCI resources"""
    print_header("COMPREHENSIVE RESOURCE INVENTORY")
    print_status("Scanning all existing OCI resources in tenancy...")
    print_status("This ensures we never create duplicate resources.")
    print()

    inventory_compute_instances()
    inventory_networking_resources()
    inventory_storage_resources()

    display_resource_inventory()

def inventory_compute_instances() -> None:
    """Inventory compute instances"""
    print_status("Inventorying compute instances...")

    global existing_amd_instances, existing_arm_instances
    existing_amd_instances = {}
    existing_arm_instances = {}

    result = oci_cmd(
        f"compute instance list "
        f"--compartment-id {oci_config.tenancy_ocid} "
        f"--query 'data[?\"lifecycle-state\"!=\\`TERMINATED\\`].{{id:id,name:\"display-name\",state:\"lifecycle-state\",shape:shape,ad:\"availability-domain\",created:\"time-created\"}}' "
        f"--all"
    )

    if not result:
        print_status("  No existing compute instances found")
        return

    try:
        data = json.loads(result)
        if not data or not isinstance(data, list):
            print_status("  No existing compute instances found")
            return

        for instance in data:
            instance_id = instance.get("id")
            if not instance_id:
                continue

            name = instance.get("name", "")
            state = instance.get("state", "")
            shape = instance.get("shape", "")

            # Get VNIC information for IP addresses
            vnic_result = oci_cmd(
                f"compute vnic-attachment list "
                f"--compartment-id {oci_config.tenancy_ocid} "
                f"--instance-id {instance_id} "
                f"--query 'data[?\"lifecycle-state\"==\\`ATTACHED\\`]'"
            )

            public_ip = "none"
            private_ip = "none"
            if vnic_result:
                try:
                    vnic_data = json.loads(vnic_result)
                    if vnic_data and len(vnic_data) > 0:
                        vnic_id = vnic_data[0].get("vnic-id")
                        if vnic_id:
                            vnic_details = oci_cmd(f"network vnic get --vnic-id {vnic_id}")
                            if vnic_details:
                                vnic_info = json.loads(vnic_details)
                                public_ip = vnic_info.get("data", {}).get("public-ip", "none")
                                private_ip = vnic_info.get("data", {}).get("private-ip", "none")
                except json.JSONDecodeError:
                    pass

            # Categorize by shape
            if shape == FREE_TIER_AMD_SHAPE:
                existing_amd_instances[instance_id] = ExistingResource(
                    id=instance_id,
                    name=name,
                    state=state,
                    additional_info={"shape": shape, "public_ip": public_ip, "private_ip": private_ip}
                )
                print_status(f"  Found AMD instance: {name} ({state}) - IP: {public_ip}")
            elif shape == FREE_TIER_ARM_SHAPE:
                # Get shape config for ARM instances
                instance_details = oci_cmd(f"compute instance get --instance-id {instance_id}")
                ocpus = 0
                memory = 0
                if instance_details:
                    try:
                        inst_data = json.loads(instance_details)
                        shape_config = inst_data.get("data", {}).get("shape-config", {})
                        ocpus = shape_config.get("ocpus", 0)
                        memory = shape_config.get("memory-in-gbs", 0)
                    except json.JSONDecodeError:
                        pass

                existing_arm_instances[instance_id] = ExistingResource(
                    id=instance_id,
                    name=name,
                    state=state,
                    additional_info={"shape": shape, "public_ip": public_ip, "private_ip": private_ip, "ocpus": ocpus, "memory": memory}
                )
                print_status(f"  Found ARM instance: {name} ({state}, {ocpus}OCPUs, {memory}GB) - IP: {public_ip}")
            else:
                print_debug(f"  Found non-free-tier instance: {name} ({shape})")

        print_status(f"  AMD instances: {len(existing_amd_instances)}/{FREE_TIER_MAX_AMD_INSTANCES}")
        print_status(f"  ARM instances: {len(existing_arm_instances)}/{FREE_TIER_MAX_ARM_INSTANCES}")
    except json.JSONDecodeError as e:
        print_debug(f"Error parsing instance data: {e}")

def inventory_networking_resources() -> None:
    """Inventory networking resources"""
    print_status("Inventorying networking resources...")

    global existing_vcns, existing_subnets, existing_internet_gateways, existing_route_tables, existing_security_lists
    existing_vcns = {}
    existing_subnets = {}
    existing_internet_gateways = {}
    existing_route_tables = {}
    existing_security_lists = {}

    # Get VCNs
    result = oci_cmd(
        f"network vcn list "
        f"--compartment-id {oci_config.tenancy_ocid} "
        f"--query 'data[?\"lifecycle-state\"==\\`AVAILABLE\\`].{{id:id,name:\"display-name\",cidr:\"cidr-block\"}}' "
        f"--all"
    )

    if not result:
        print_status("  No VCNs found")
        return

    try:
        vcn_list = json.loads(result)
        if not vcn_list or not isinstance(vcn_list, list):
            print_status("  No VCNs found")
            return

        for vcn in vcn_list:
            vcn_id = vcn.get("id")
            if not vcn_id:
                continue

            vcn_name = vcn.get("name", "")
            vcn_cidr = vcn.get("cidr", "")

            existing_vcns[vcn_id] = ExistingResource(
                id=vcn_id,
                name=vcn_name,
                additional_info={"cidr": vcn_cidr}
            )
            print_status(f"  Found VCN: {vcn_name} ({vcn_cidr})")

            # Get subnets for this VCN
            subnet_result = oci_cmd(
                f"network subnet list "
                f"--compartment-id {oci_config.tenancy_ocid} "
                f"--vcn-id {vcn_id} "
                f"--query 'data[?\"lifecycle-state\"==\\`AVAILABLE\\`].{{id:id,name:\"display-name\",cidr:\"cidr-block\"}}'"
            )

            if subnet_result:
                try:
                    subnet_list = json.loads(subnet_result)
                    for subnet in subnet_list:
                        subnet_id = subnet.get("id")
                        if subnet_id:
                            existing_subnets[subnet_id] = ExistingResource(
                                id=subnet_id,
                                name=subnet.get("name", ""),
                                additional_info={"cidr": subnet.get("cidr", ""), "vcn_id": vcn_id}
                            )
                except json.JSONDecodeError:
                    pass

            # Get internet gateways
            ig_result = oci_cmd(
                f"network internet-gateway list "
                f"--compartment-id {oci_config.tenancy_ocid} "
                f"--vcn-id {vcn_id} "
                f"--query 'data[?\"lifecycle-state\"==\\`AVAILABLE\\`].{{id:id,name:\"display-name\"}}'"
            )

            if ig_result:
                try:
                    ig_list = json.loads(ig_result)
                    for ig in ig_list:
                        ig_id = ig.get("id")
                        if ig_id:
                            existing_internet_gateways[ig_id] = ExistingResource(
                                id=ig_id,
                                name=ig.get("name", ""),
                                additional_info={"vcn_id": vcn_id}
                            )
                except json.JSONDecodeError:
                    pass

            # Get route tables
            rt_result = oci_cmd(
                f"network route-table list "
                f"--compartment-id {oci_config.tenancy_ocid} "
                f"--vcn-id {vcn_id} "
                f"--query 'data[].{{id:id,name:\"display-name\"}}'"
            )

            if rt_result:
                try:
                    rt_list = json.loads(rt_result)
                    for rt in rt_list:
                        rt_id = rt.get("id")
                        if rt_id:
                            existing_route_tables[rt_id] = ExistingResource(
                                id=rt_id,
                                name=rt.get("name", ""),
                                additional_info={"vcn_id": vcn_id}
                            )
                except json.JSONDecodeError:
                    pass

            # Get security lists
            sl_result = oci_cmd(
                f"network security-list list "
                f"--compartment-id {oci_config.tenancy_ocid} "
                f"--vcn-id {vcn_id} "
                f"--query 'data[].{{id:id,name:\"display-name\"}}'"
            )

            if sl_result:
                try:
                    sl_list = json.loads(sl_result)
                    for sl in sl_list:
                        sl_id = sl.get("id")
                        if sl_id:
                            existing_security_lists[sl_id] = ExistingResource(
                                id=sl_id,
                                name=sl.get("name", ""),
                                additional_info={"vcn_id": vcn_id}
                            )
                except json.JSONDecodeError:
                    pass

        print_status(f"  VCNs: {len(existing_vcns)}/{FREE_TIER_MAX_VCNS}")
        print_status(f"  Subnets: {len(existing_subnets)}")
        print_status(f"  Internet Gateways: {len(existing_internet_gateways)}")
    except json.JSONDecodeError as e:
        print_debug(f"Error parsing networking data: {e}")

def inventory_storage_resources() -> None:
    """Inventory storage resources"""
    print_status("Inventorying storage resources...")

    global existing_boot_volumes, existing_block_volumes
    existing_boot_volumes = {}
    existing_block_volumes = {}

    # Get boot volumes
    result = oci_cmd(
        f"bv boot-volume list "
        f"--compartment-id {oci_config.tenancy_ocid} "
        f"--availability-domain {oci_config.availability_domain} "
        f"--query 'data[?\"lifecycle-state\"==\\`AVAILABLE\\`].{{id:id,name:\"display-name\",size:\"size-in-gbs\"}}' "
        f"--all"
    )

    total_boot_gb = 0
    if result:
        try:
            boot_list = json.loads(result)
            if boot_list and isinstance(boot_list, list):
                for boot in boot_list:
                    boot_id = boot.get("id")
                    if boot_id:
                        size = boot.get("size", 0)
                        existing_boot_volumes[boot_id] = ExistingResource(
                            id=boot_id,
                            name=boot.get("name", ""),
                            additional_info={"size": size}
                        )
                        total_boot_gb += size
        except json.JSONDecodeError:
            pass

    # Get block volumes
    result = oci_cmd(
        f"bv volume list "
        f"--compartment-id {oci_config.tenancy_ocid} "
        f"--availability-domain {oci_config.availability_domain} "
        f"--query 'data[?\"lifecycle-state\"==\\`AVAILABLE\\`].{{id:id,name:\"display-name\",size:\"size-in-gbs\"}}' "
        f"--all"
    )

    total_block_gb = 0
    if result:
        try:
            block_list = json.loads(result)
            if block_list and isinstance(block_list, list):
                for block in block_list:
                    block_id = block.get("id")
                    if block_id:
                        size = block.get("size", 0)
                        existing_block_volumes[block_id] = ExistingResource(
                            id=block_id,
                            name=block.get("name", ""),
                            additional_info={"size": size}
                        )
                        total_block_gb += size
        except json.JSONDecodeError:
            pass

    total_storage = total_boot_gb + total_block_gb

    print_status(f"  Boot volumes: {len(existing_boot_volumes)} ({total_boot_gb}GB)")
    print_status(f"  Block volumes: {len(existing_block_volumes)} ({total_block_gb}GB)")
    print_status(f"  Total storage: {total_storage}GB/{FREE_TIER_MAX_STORAGE_GB}GB")

def display_resource_inventory() -> None:
    """Display resource inventory summary"""
    print()
    print_header("RESOURCE INVENTORY SUMMARY")

    # Calculate totals
    total_amd = len(existing_amd_instances)
    total_arm = len(existing_arm_instances)
    total_arm_ocpus = sum(inst.additional_info.get("ocpus", 0) for inst in existing_arm_instances.values())
    total_arm_memory = sum(inst.additional_info.get("memory", 0) for inst in existing_arm_instances.values())

    total_boot_gb = sum(vol.additional_info.get("size", 0) for vol in existing_boot_volumes.values())
    total_block_gb = sum(vol.additional_info.get("size", 0) for vol in existing_block_volumes.values())
    total_storage = total_boot_gb + total_block_gb

    # Create table for compute resources
    compute_table = Table(title="Compute Resources", show_header=True, header_style="bold")
    compute_table.add_column("Resource", style="cyan")
    compute_table.add_column("Used", justify="right")
    compute_table.add_column("Limit", justify="right")
    compute_table.add_row("AMD Micro Instances", str(total_amd), str(FREE_TIER_MAX_AMD_INSTANCES))
    compute_table.add_row("ARM A1 Instances", str(total_arm), str(FREE_TIER_MAX_ARM_INSTANCES))
    compute_table.add_row("ARM OCPUs Used", str(total_arm_ocpus), str(FREE_TIER_MAX_ARM_OCPUS))
    compute_table.add_row("ARM Memory Used", f"{total_arm_memory}GB", f"{FREE_TIER_MAX_ARM_MEMORY_GB}GB")
    console.print(compute_table)

    # Create table for storage resources
    storage_table = Table(title="Storage Resources", show_header=True, header_style="bold")
    storage_table.add_column("Resource", style="cyan")
    storage_table.add_column("Size", justify="right")
    storage_table.add_row("Boot Volumes", f"{total_boot_gb}GB")
    storage_table.add_row("Block Volumes", f"{total_block_gb}GB")
    storage_table.add_row("Total Storage", f"{total_storage}GB / {FREE_TIER_MAX_STORAGE_GB}GB")
    console.print(storage_table)

    # Create table for networking resources
    network_table = Table(title="Networking Resources", show_header=True, header_style="bold")
    network_table.add_column("Resource", style="cyan")
    network_table.add_column("Count", justify="right")
    network_table.add_row("VCNs", f"{len(existing_vcns)} / {FREE_TIER_MAX_VCNS}")
    network_table.add_row("Subnets", str(len(existing_subnets)))
    network_table.add_row("Internet Gateways", str(len(existing_internet_gateways)))
    console.print(network_table)

    # Warnings for near-limit resources
    if total_amd >= FREE_TIER_MAX_AMD_INSTANCES:
        print_warning("AMD instance limit reached - cannot create more AMD instances")
    if total_arm_ocpus >= FREE_TIER_MAX_ARM_OCPUS:
        print_warning("ARM OCPU limit reached - cannot allocate more ARM OCPUs")
    if total_arm_memory >= FREE_TIER_MAX_ARM_MEMORY_GB:
        print_warning("ARM memory limit reached - cannot allocate more ARM memory")
    if total_storage >= FREE_TIER_MAX_STORAGE_GB:
        print_warning("Storage limit reached - cannot create more volumes")
    if len(existing_vcns) >= FREE_TIER_MAX_VCNS:
        print_warning("VCN limit reached - cannot create more VCNs")

# ============================================================================
# FREE TIER LIMIT VALIDATION
# ============================================================================

def calculate_available_resources() -> Dict[str, int]:
    """Calculate what's still available within Free Tier limits"""
    used_amd = len(existing_amd_instances)
    used_arm_ocpus = sum(inst.additional_info.get("ocpus", 0) for inst in existing_arm_instances.values())
    used_arm_memory = sum(inst.additional_info.get("memory", 0) for inst in existing_arm_instances.values())
    used_storage = (
        sum(vol.additional_info.get("size", 0) for vol in existing_boot_volumes.values()) +
        sum(vol.additional_info.get("size", 0) for vol in existing_block_volumes.values())
    )

    available = {
        "amd_instances": FREE_TIER_MAX_AMD_INSTANCES - used_amd,
        "arm_ocpus": FREE_TIER_MAX_ARM_OCPUS - used_arm_ocpus,
        "arm_memory": FREE_TIER_MAX_ARM_MEMORY_GB - used_arm_memory,
        "storage": FREE_TIER_MAX_STORAGE_GB - used_storage,
        "used_arm_instances": len(existing_arm_instances)
    }

    print_debug(f"Available: AMD={available['amd_instances']}, ARM_OCPU={available['arm_ocpus']}, ARM_MEM={available['arm_memory']}, Storage={available['storage']}")
    return available

def validate_proposed_config(proposed_amd: int, proposed_arm: int, proposed_arm_ocpus: int, proposed_arm_memory: int, proposed_storage: int) -> bool:
    """Validate proposed configuration against Free Tier limits"""
    available = calculate_available_resources()
    errors = 0

    if proposed_amd > available["amd_instances"]:
        print_error(f"Cannot create {proposed_amd} AMD instances - only {available['amd_instances']} available")
        errors += 1

    if proposed_arm_ocpus > available["arm_ocpus"]:
        print_error(f"Cannot allocate {proposed_arm_ocpus} ARM OCPUs - only {available['arm_ocpus']} available")
        errors += 1

    if proposed_arm_memory > available["arm_memory"]:
        print_error(f"Cannot allocate {proposed_arm_memory}GB ARM memory - only {available['arm_memory']}GB available")
        errors += 1

    if proposed_storage > available["storage"]:
        print_error(f"Cannot use {proposed_storage}GB storage - only {available['storage']}GB available")
        errors += 1

    return errors == 0

# ============================================================================
# CONFIGURATION FUNCTIONS
# ============================================================================

def load_existing_config() -> bool:
    """Load existing configuration from variables.tf"""
    variables_tf = Path("variables.tf")
    if not variables_tf.exists():
        return False

    print_status("Loading existing configuration from variables.tf...")

    content = variables_tf.read_text()

    # Load basic counts using regex
    amd_match = re.search(r'amd_micro_instance_count\s*=\s*(\d+)', content)
    instance_config.amd_micro_instance_count = int(amd_match.group(1)) if amd_match else 0

    boot_match = re.search(r'amd_micro_boot_volume_size_gb\s*=\s*(\d+)', content)
    instance_config.amd_micro_boot_volume_size_gb = int(boot_match.group(1)) if boot_match else 50

    arm_match = re.search(r'arm_flex_instance_count\s*=\s*(\d+)', content)
    instance_config.arm_flex_instance_count = int(arm_match.group(1)) if arm_match else 0

    # Load ARM arrays
    ocpus_match = re.search(r'arm_flex_ocpus_per_instance\s*=\s*\[([^\]]+)\]', content)
    if ocpus_match:
        instance_config.arm_flex_ocpus_per_instance = [
            int(x.strip()) for x in ocpus_match.group(1).split(",") if x.strip().isdigit()
        ]

    memory_match = re.search(r'arm_flex_memory_per_instance\s*=\s*\[([^\]]+)\]', content)
    if memory_match:
        instance_config.arm_flex_memory_per_instance = [
            int(x.strip()) for x in memory_match.group(1).split(",") if x.strip().isdigit()
        ]

    boot_match = re.search(r'arm_flex_boot_volume_size_gb\s*=\s*\[([^\]]+)\]', content)
    if boot_match:
        instance_config.arm_flex_boot_volume_size_gb = [
            int(x.strip()) for x in boot_match.group(1).split(",") if x.strip().isdigit()
        ]

    # Load hostnames
    amd_hostnames_match = re.search(r'amd_micro_hostnames\s*=\s*\[([^\]]+)\]', content)
    if amd_hostnames_match:
        instance_config.amd_micro_hostnames = [
            x.strip().strip('"').strip("'") for x in amd_hostnames_match.group(1).split(",")
        ]

    arm_hostnames_match = re.search(r'arm_flex_hostnames\s*=\s*\[([^\]]+)\]', content)
    if arm_hostnames_match:
        instance_config.arm_flex_hostnames = [
            x.strip().strip('"').strip("'") for x in arm_hostnames_match.group(1).split(",")
        ]

    print_success(f"Loaded configuration: {instance_config.amd_micro_instance_count}x AMD, {instance_config.arm_flex_instance_count}x ARM")
    return True

def prompt_configuration() -> None:
    """Prompt for instance configuration"""
    print_header("INSTANCE CONFIGURATION")

    available = calculate_available_resources()

    console.print("[bold]Available Free Tier Resources:[/bold]")
    console.print(f"  • AMD instances:  {available['amd_instances']} available (max {FREE_TIER_MAX_AMD_INSTANCES})")
    console.print(f"  • ARM OCPUs:      {available['arm_ocpus']} available (max {FREE_TIER_MAX_ARM_OCPUS})")
    console.print(f"  • ARM Memory:     {available['arm_memory']}GB available (max {FREE_TIER_MAX_ARM_MEMORY_GB}GB)")
    console.print(f"  • Storage:        {available['storage']}GB available (max {FREE_TIER_MAX_STORAGE_GB}GB)")
    print()

    # Check if we have existing config
    has_existing_config = load_existing_config()

    print_status("Configuration options:")
    console.print("  1) Use existing instances (manage what's already deployed)")
    if has_existing_config:
        console.print("  2) Use saved configuration from variables.tf")
    else:
        console.print("  2) Use saved configuration from variables.tf (not available)")
    console.print("  3) Configure new instances (respecting Free Tier limits)")
    console.print("  4) Maximum Free Tier configuration (use all available resources)")
    print()

    if AUTO_USE_EXISTING or NON_INTERACTIVE:
        choice = 1
        print_status("Auto mode: Using existing instances")
    else:
        choice = IntPrompt.ask("Choose configuration (1-4)", default=1, choices=["1", "2", "3", "4"])

    if choice == 1:
        configure_from_existing_instances()
    elif choice == 2:
        if has_existing_config:
            print_success("Using saved configuration")
        else:
            print_error("No saved configuration available")
            prompt_configuration()
    elif choice == 3:
        configure_custom_instances()
    elif choice == 4:
        configure_maximum_free_tier()

def configure_from_existing_instances() -> None:
    """Configure based on existing instances"""
    print_status("Configuring based on existing instances...")

    instance_config.amd_micro_instance_count = len(existing_amd_instances)
    instance_config.amd_micro_hostnames = [inst.name for inst in existing_amd_instances.values()]

    instance_config.arm_flex_instance_count = len(existing_arm_instances)
    instance_config.arm_flex_hostnames = [inst.name for inst in existing_arm_instances.values()]
    instance_config.arm_flex_ocpus_per_instance = [
        inst.additional_info.get("ocpus", 0) for inst in existing_arm_instances.values()
    ]
    instance_config.arm_flex_memory_per_instance = [
        inst.additional_info.get("memory", 0) for inst in existing_arm_instances.values()
    ]
    instance_config.arm_flex_boot_volume_size_gb = [50] * len(existing_arm_instances)  # Default, will be updated from state
    instance_config.arm_flex_block_volumes = [0] * len(existing_arm_instances)

    # Set defaults if no instances exist
    if instance_config.amd_micro_instance_count == 0 and instance_config.arm_flex_instance_count == 0:
        print_status("No existing instances found, using default configuration")
        instance_config.amd_micro_instance_count = 0
        instance_config.arm_flex_instance_count = 1
        instance_config.arm_flex_ocpus_per_instance = [4]
        instance_config.arm_flex_memory_per_instance = [24]
        instance_config.arm_flex_boot_volume_size_gb = [200]
        instance_config.arm_flex_hostnames = ["arm-instance-1"]
        instance_config.arm_flex_block_volumes = [0]

    instance_config.amd_micro_boot_volume_size_gb = 50

    print_success(f"Configuration: {instance_config.amd_micro_instance_count}x AMD, {instance_config.arm_flex_instance_count}x ARM")

def configure_custom_instances() -> None:
    """Configure custom instances"""
    print_status("Custom instance configuration...")

    available = calculate_available_resources()

    # AMD instances
    instance_config.amd_micro_instance_count = IntPrompt.ask(
        f"Number of AMD instances (0-{available['amd_instances']})",
        default=0
    )
    instance_config.amd_micro_instance_count = max(0, min(instance_config.amd_micro_instance_count, available["amd_instances"]))

    instance_config.amd_micro_hostnames = []
    if instance_config.amd_micro_instance_count > 0:
        instance_config.amd_micro_boot_volume_size_gb = IntPrompt.ask(
            "AMD boot volume size GB (50-100)",
            default=50
        )
        instance_config.amd_micro_boot_volume_size_gb = max(50, min(instance_config.amd_micro_boot_volume_size_gb, 100))

        for i in range(1, instance_config.amd_micro_instance_count + 1):
            hostname = Prompt.ask(f"Hostname for AMD instance {i}", default=f"amd-instance-{i}")
            instance_config.amd_micro_hostnames.append(hostname)
    else:
        instance_config.amd_micro_boot_volume_size_gb = 50

    # ARM instances
    if oci_config.ubuntu_arm_flex_image_ocid and available["arm_ocpus"] > 0:
        instance_config.arm_flex_instance_count = IntPrompt.ask(
            "Number of ARM instances (0-4)",
            default=1
        )
        instance_config.arm_flex_instance_count = max(0, min(instance_config.arm_flex_instance_count, 4))

        instance_config.arm_flex_hostnames = []
        instance_config.arm_flex_ocpus_per_instance = []
        instance_config.arm_flex_memory_per_instance = []
        instance_config.arm_flex_boot_volume_size_gb = []
        instance_config.arm_flex_block_volumes = []

        remaining_ocpus = available["arm_ocpus"]
        remaining_memory = available["arm_memory"]

        for i in range(1, instance_config.arm_flex_instance_count + 1):
            print()
            print_status(f"ARM instance {i} configuration (remaining: {remaining_ocpus} OCPUs, {remaining_memory}GB RAM):")

            hostname = Prompt.ask(f"  Hostname", default=f"arm-instance-{i}")
            instance_config.arm_flex_hostnames.append(hostname)

            ocpus = IntPrompt.ask(f"  OCPUs (1-{remaining_ocpus})", default=remaining_ocpus)
            ocpus = max(1, min(ocpus, remaining_ocpus))
            instance_config.arm_flex_ocpus_per_instance.append(ocpus)
            remaining_ocpus -= ocpus

            max_memory = min(ocpus * 6, remaining_memory)  # 6GB per OCPU max
            memory = IntPrompt.ask(f"  Memory GB (1-{max_memory})", default=max_memory)
            memory = max(1, min(memory, max_memory))
            instance_config.arm_flex_memory_per_instance.append(memory)
            remaining_memory -= memory

            boot = IntPrompt.ask("  Boot volume GB (50-200)", default=50)
            boot = max(50, min(boot, 200))
            instance_config.arm_flex_boot_volume_size_gb.append(boot)

            instance_config.arm_flex_block_volumes.append(0)
    else:
        instance_config.arm_flex_instance_count = 0
        instance_config.arm_flex_ocpus_per_instance = []
        instance_config.arm_flex_memory_per_instance = []
        instance_config.arm_flex_boot_volume_size_gb = []
        instance_config.arm_flex_block_volumes = []
        instance_config.arm_flex_hostnames = []

def configure_maximum_free_tier() -> None:
    """Configure maximum Free Tier utilization"""
    print_status("Configuring maximum Free Tier utilization...")

    available = calculate_available_resources()

    # Use all available AMD instances
    instance_config.amd_micro_instance_count = available["amd_instances"]
    instance_config.amd_micro_boot_volume_size_gb = 50
    instance_config.amd_micro_hostnames = [f"amd-instance-{i}" for i in range(1, instance_config.amd_micro_instance_count + 1)]

    # Use all available ARM resources
    if oci_config.ubuntu_arm_flex_image_ocid and available["arm_ocpus"] > 0:
        instance_config.arm_flex_instance_count = 1
        instance_config.arm_flex_ocpus_per_instance = [available["arm_ocpus"]]
        instance_config.arm_flex_memory_per_instance = [available["arm_memory"]]

        # Calculate boot volume size to use remaining storage
        used_by_amd = instance_config.amd_micro_instance_count * instance_config.amd_micro_boot_volume_size_gb
        remaining_storage = available["storage"] - used_by_amd
        if remaining_storage < FREE_TIER_MIN_BOOT_VOLUME_GB:
            remaining_storage = FREE_TIER_MIN_BOOT_VOLUME_GB

        instance_config.arm_flex_boot_volume_size_gb = [remaining_storage]
        instance_config.arm_flex_hostnames = ["arm-instance-1"]
        instance_config.arm_flex_block_volumes = [0]
    else:
        instance_config.arm_flex_instance_count = 0
        instance_config.arm_flex_ocpus_per_instance = []
        instance_config.arm_flex_memory_per_instance = []
        instance_config.arm_flex_boot_volume_size_gb = []
        instance_config.arm_flex_hostnames = []
        instance_config.arm_flex_block_volumes = []

    print_success(
        f"Maximum config: {instance_config.amd_micro_instance_count}x AMD, "
        f"{instance_config.arm_flex_instance_count}x ARM "
        f"({available['arm_ocpus']} OCPUs, {available['arm_memory']}GB)"
    )

# ============================================================================
# TERRAFORM FILE GENERATION
# ============================================================================

def configure_terraform_backend() -> bool:
    """Configure terraform backend if TF_BACKEND=oci"""
    if TF_BACKEND != "oci":
        return True

    if not TF_BACKEND_BUCKET:
        print_error("TF_BACKEND is 'oci' but TF_BACKEND_BUCKET is not set")
        return False

    backend_region = TF_BACKEND_REGION or oci_config.region
    backend_endpoint = TF_BACKEND_ENDPOINT or f"https://objectstorage.{backend_region}.oraclecloud.com"

    if TF_BACKEND_CREATE_BUCKET:
        print_status(f"Creating/checking OCI Object Storage bucket: {TF_BACKEND_BUCKET}")
        ns_result = oci_cmd("os ns get --query 'data' --raw-output")
        if not ns_result:
            print_error("Failed to determine Object Storage namespace")
            return False

        try:
            ns = json.loads(ns_result)
            bucket_check = oci_cmd(f"os bucket get --namespace-name {ns} --bucket-name {TF_BACKEND_BUCKET}")
            if not bucket_check:
                create_result = oci_cmd(
                    f"os bucket create --namespace-name {ns} --compartment-id {oci_config.tenancy_ocid} "
                    f"--name {TF_BACKEND_BUCKET} --is-versioning-enabled true"
                )
                if create_result:
                    print_success(f"Created bucket {TF_BACKEND_BUCKET} in namespace {ns}")
                else:
                    print_error(f"Failed to create bucket {TF_BACKEND_BUCKET}")
                    return False
            else:
                print_status(f"Bucket {TF_BACKEND_BUCKET} already exists in namespace {ns}")
        except json.JSONDecodeError:
            print_error("Failed to parse namespace response")
            return False

    print_status("Writing backend.tf (do not commit -- contains sensitive values)")
    backend_tf = Path("backend.tf")
    if backend_tf.exists():
        backup_name = f"backend.tf.bak.{time.strftime('%Y%m%d_%H%M%S')}"
        shutil.copy2(backend_tf, backup_name)

    backend_content = f'''terraform {{
  backend "s3" {{
    bucket     = "{TF_BACKEND_BUCKET}"
    key        = "{TF_BACKEND_STATE_KEY}"
    region     = "{backend_region}"
    endpoint   = "{backend_endpoint}"
    access_key = "{TF_BACKEND_ACCESS_KEY}"
    secret_key = "{TF_BACKEND_SECRET_KEY}"
    skip_credentials_validation = true
    skip_region_validation = true
    skip_metadata_api_check = true
    force_path_style = true
  }}
}}
'''
    backend_tf.write_text(backend_content)
    print_warning("backend.tf written - ensure this file is in .gitignore (contains credentials if provided)")
    return True

def create_terraform_files() -> None:
    """Create all Terraform files"""
    print_header("GENERATING TERRAFORM FILES")

    create_terraform_provider()
    create_terraform_variables()
    create_terraform_datasources()
    create_terraform_main()
    create_terraform_block_volumes()
    create_cloud_init()

    print_success("All Terraform files generated successfully")

def create_terraform_provider() -> None:
    """Create provider.tf"""
    print_status("Creating provider.tf...")

    configure_terraform_backend()

    provider_tf = Path("provider.tf")
    if provider_tf.exists():
        backup_name = f"provider.tf.bak.{time.strftime('%Y%m%d_%H%M%S')}"
        shutil.copy2(provider_tf, backup_name)

    provider_content = f'''# Terraform Provider Configuration for Oracle Cloud Infrastructure
# Generated: {time.strftime('%Y-%m-%d %H:%M:%S')}
# Region: {oci_config.region}

terraform {{
  required_version = ">= 1.0"
  required_providers {{
    oci = {{
      source  = "oracle/oci"
      version = "~> 6.0"
    }}
  }}
}}

# OCI Provider with session token authentication
provider "oci" {{
  auth                = "SecurityToken"
  config_file_profile = "DEFAULT"
  region              = "{oci_config.region}"
}}
'''
    provider_tf.write_text(provider_content)
    print_success("provider.tf created")

def create_terraform_variables() -> None:
    """Create variables.tf"""
    print_status("Creating variables.tf...")

    variables_tf = Path("variables.tf")
    if variables_tf.exists():
        backup_name = f"variables.tf.bak.{time.strftime('%Y%m%d_%H%M%S')}"
        shutil.copy2(variables_tf, backup_name)

    amd_hostnames_tf = "[" + ", ".join(f'"{h}"' for h in instance_config.amd_micro_hostnames) + "]"
    arm_hostnames_tf = "[" + ", ".join(f'"{h}"' for h in instance_config.arm_flex_hostnames) + "]"
    arm_ocpus_tf = "[" + ", ".join(str(o) for o in instance_config.arm_flex_ocpus_per_instance) + "]"
    arm_memory_tf = "[" + ", ".join(str(m) for m in instance_config.arm_flex_memory_per_instance) + "]"
    arm_boot_tf = "[" + ", ".join(str(b) for b in instance_config.arm_flex_boot_volume_size_gb) + "]"
    arm_block_tf = "[" + ", ".join(str(b) for b in instance_config.arm_flex_block_volumes) + "]"

    variables_content = f'''# Oracle Cloud Infrastructure Terraform Variables
# Generated: {time.strftime('%Y-%m-%d %H:%M:%S')}
# Configuration: {instance_config.amd_micro_instance_count}x AMD + {instance_config.arm_flex_instance_count}x ARM instances

locals {{
  # Core identifiers
  tenancy_ocid    = "{oci_config.tenancy_ocid}"
  compartment_id  = "{oci_config.tenancy_ocid}"
  user_ocid       = "{oci_config.user_ocid}"
  region          = "{oci_config.region}"
  
  # Ubuntu Images (region-specific)
  ubuntu_x86_image_ocid = "{oci_config.ubuntu_image_ocid}"
  ubuntu_arm_image_ocid = "{oci_config.ubuntu_arm_flex_image_ocid}"
  
  # SSH Configuration
  ssh_pubkey_path      = pathexpand("./ssh_keys/id_rsa.pub")
  ssh_pubkey_data      = file(pathexpand("./ssh_keys/id_rsa.pub"))
  ssh_private_key_path = pathexpand("./ssh_keys/id_rsa")
  
  # AMD x86 Micro Instances Configuration
  amd_micro_instance_count      = {instance_config.amd_micro_instance_count}
  amd_micro_boot_volume_size_gb = {instance_config.amd_micro_boot_volume_size_gb}
  amd_micro_hostnames           = {amd_hostnames_tf}
  amd_block_volume_size_gb      = 0
  
  # ARM A1 Flex Instances Configuration
  arm_flex_instance_count       = {instance_config.arm_flex_instance_count}
  arm_flex_ocpus_per_instance   = {arm_ocpus_tf}
  arm_flex_memory_per_instance  = {arm_memory_tf}
  arm_flex_boot_volume_size_gb  = {arm_boot_tf}
  arm_flex_hostnames            = {arm_hostnames_tf}
  arm_block_volume_sizes        = {arm_block_tf}
  
  # Storage calculations
  total_amd_storage = local.amd_micro_instance_count * local.amd_micro_boot_volume_size_gb
  total_arm_storage = local.arm_flex_instance_count > 0 ? sum(local.arm_flex_boot_volume_size_gb) : 0
  total_block_storage = (local.amd_micro_instance_count * local.amd_block_volume_size_gb) + (local.arm_flex_instance_count > 0 ? sum(local.arm_block_volume_sizes) : 0)
  total_storage = local.total_amd_storage + local.total_arm_storage + local.total_block_storage
}}

# Free Tier Limits
variable "free_tier_max_storage_gb" {{
  description = "Maximum storage for Oracle Free Tier"
  type        = number
  default     = {FREE_TIER_MAX_STORAGE_GB}
}}

variable "free_tier_max_arm_ocpus" {{
  description = "Maximum ARM OCPUs for Oracle Free Tier"
  type        = number
  default     = {FREE_TIER_MAX_ARM_OCPUS}
}}

variable "free_tier_max_arm_memory_gb" {{
  description = "Maximum ARM memory for Oracle Free Tier"
  type        = number
  default     = {FREE_TIER_MAX_ARM_MEMORY_GB}
}}

# Validation checks
check "storage_limit" {{
  assert {{
    condition     = local.total_storage <= var.free_tier_max_storage_gb
    error_message = "Total storage (${{local.total_storage}}GB) exceeds Free Tier limit (${{var.free_tier_max_storage_gb}}GB)"
  }}
}}

check "arm_ocpu_limit" {{
  assert {{
    condition     = local.arm_flex_instance_count == 0 || sum(local.arm_flex_ocpus_per_instance) <= var.free_tier_max_arm_ocpus
    error_message = "Total ARM OCPUs exceed Free Tier limit (${{var.free_tier_max_arm_ocpus}})"
  }}
}}

check "arm_memory_limit" {{
  assert {{
    condition     = local.arm_flex_instance_count == 0 || sum(local.arm_flex_memory_per_instance) <= var.free_tier_max_arm_memory_gb
    error_message = "Total ARM memory exceeds Free Tier limit (${{var.free_tier_max_arm_memory_gb}}GB)"
  }}
}}
'''
    variables_tf.write_text(variables_content)
    print_success("variables.tf created")

def create_terraform_datasources() -> None:
    """Create data_sources.tf"""
    print_status("Creating data_sources.tf...")

    data_sources_tf = Path("data_sources.tf")
    if data_sources_tf.exists():
        backup_name = f"data_sources.tf.bak.{time.strftime('%Y%m%d_%H%M%S')}"
        shutil.copy2(data_sources_tf, backup_name)

    data_sources_content = '''# OCI Data Sources
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
'''
    data_sources_tf.write_text(data_sources_content)
    print_success("data_sources.tf created")

def create_terraform_main() -> None:
    """Create main.tf with complete infrastructure"""
    print_status("Creating main.tf...")

    main_tf = Path("main.tf")
    if main_tf.exists():
        backup_name = f"main.tf.bak.{time.strftime('%Y%m%d_%H%M%S')}"
        shutil.copy2(main_tf, backup_name)

    # Due to size, reading the main.tf template from the complete file
    # For brevity, including the essential parts here
    main_content = Path("setup_oci_terraform_complete.py").read_text() if Path("setup_oci_terraform_complete.py").exists() else ""
    # Extract main.tf content from the complete file or use inline template
    # For now, using a simplified version - the full template is in setup_oci_terraform_complete.py
    
    # Reading the full main.tf template from the bash script reference
    main_content = '''# Oracle Cloud Infrastructure - Main Configuration
# Always Free Tier Optimized

# ============================================================================
# NETWORKING
# ============================================================================

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

resource "oci_core_default_route_table" "main" {
  manage_default_resource_id = oci_core_vcn.main.default_route_table_id
  display_name               = "main-rt"
  
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }
  
  route_rules {
    destination       = "::/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }
}

resource "oci_core_default_security_list" "main" {
  manage_default_resource_id = oci_core_vcn.main.default_security_list_id
  display_name               = "main-sl"
  
  # Allow all egress
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }
  
  egress_security_rules {
    destination = "::/0"
    protocol    = "all"
  }
  
  # SSH (IPv4 & IPv6)
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 22
      max = 22
    }
  }
  ingress_security_rules {
    protocol = "6"
    source   = "::/0"
    tcp_options {
      min = 22
      max = 22
    }
  }
  
  # HTTP (IPv4 & IPv6)
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 80
      max = 80
    }
  }
  ingress_security_rules {
    protocol = "6"
    source   = "::/0"
    tcp_options {
      min = 80
      max = 80
    }
  }
  
  # HTTPS (IPv4 & IPv6)
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 443
      max = 443
    }
  }
  ingress_security_rules {
    protocol = "6"
    source   = "::/0"
    tcp_options {
      min = 443
      max = 443
    }
  }
  
  # ICMP (IPv4 & IPv6)
  ingress_security_rules {
    protocol = "1"
    source   = "0.0.0.0/0"
  }
  ingress_security_rules {
    protocol = "1"
    source   = "::/0"
  }
}

resource "oci_core_subnet" "main" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.main.id
  cidr_block     = "10.0.1.0/24"
  display_name   = "main-subnet"
  dns_label      = "mainsubnet"
  
  route_table_id    = oci_core_default_route_table.main.id
  security_list_ids = [oci_core_default_security_list.main.id]
  
  ipv6cidr_blocks = [cidrsubnet(oci_core_vcn.main.ipv6cidr_blocks[0], 8, 0)]
}

# ============================================================================
# COMPUTE INSTANCES
# ============================================================================

resource "oci_core_instance" "amd" {
  count = local.amd_micro_instance_count
  
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.compartment_id
  display_name        = local.amd_micro_hostnames[count.index]
  shape               = "VM.Standard.E2.1.Micro"
  
  create_vnic_details {
    subnet_id        = oci_core_subnet.main.id
    display_name     = "${local.amd_micro_hostnames[count.index]}-vnic"
    assign_public_ip = true
    assign_ipv6ip    = true
    hostname_label   = local.amd_micro_hostnames[count.index]
  }
  
  source_details {
    source_type             = "image"
    source_id               = local.ubuntu_x86_image_ocid
    boot_volume_size_in_gbs = local.amd_micro_boot_volume_size_gb
  }
  
  metadata = {
    ssh_authorized_keys = local.ssh_pubkey_data
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
      hostname = local.amd_micro_hostnames[count.index]
    }))
  }
  
  freeform_tags = {
    "Purpose"      = "AlwaysFreeTier"
    "InstanceType" = "AMD-Micro"
    "Managed"      = "Terraform"
  }
  
  lifecycle {
    ignore_changes = [source_details[0].source_id, defined_tags]
  }
}

resource "oci_core_instance" "arm" {
  count = local.arm_flex_instance_count
  
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.compartment_id
  display_name        = local.arm_flex_hostnames[count.index]
  shape               = "VM.Standard.A1.Flex"
  
  shape_config {
    ocpus         = local.arm_flex_ocpus_per_instance[count.index]
    memory_in_gbs = local.arm_flex_memory_per_instance[count.index]
  }
  
  create_vnic_details {
    subnet_id        = oci_core_subnet.main.id
    display_name     = "${local.arm_flex_hostnames[count.index]}-vnic"
    assign_public_ip = true
    assign_ipv6ip    = true
    hostname_label   = local.arm_flex_hostnames[count.index]
  }
  
  source_details {
    source_type             = "image"
    source_id               = local.ubuntu_arm_image_ocid
    boot_volume_size_in_gbs = local.arm_flex_boot_volume_size_gb[count.index]
  }
  
  metadata = {
    ssh_authorized_keys = local.ssh_pubkey_data
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
      hostname = local.arm_flex_hostnames[count.index]
    }))
  }
  
  freeform_tags = {
    "Purpose"      = "AlwaysFreeTier"
    "InstanceType" = "ARM-A1-Flex"
    "Managed"      = "Terraform"
  }
  
  lifecycle {
    ignore_changes = [source_details[0].source_id, defined_tags]
  }
}

data "oci_core_vnic_attachments" "amd_vnics" {
  count = local.amd_micro_instance_count
  compartment_id = local.compartment_id
  instance_id    = oci_core_instance.amd[count.index].id
}

resource "oci_core_ipv6" "amd_ipv6" {
  count = local.amd_micro_instance_count
  vnic_id = data.oci_core_vnic_attachments.amd_vnics[count.index].vnic_attachments[0].vnic_id
  lifetime = "RESERVED"
  subnet_id = oci_core_subnet.main.id
  route_table_id = oci_core_default_route_table.main.id
  display_name = "amd-${local.amd_micro_hostnames[count.index]}-ipv6"
  freeform_tags = {
    "Purpose" = "AlwaysFreeTier"
    "Managed" = "Terraform"
  }
}

data "oci_core_vnic_attachments" "arm_vnics" {
  count = local.arm_flex_instance_count
  compartment_id = local.compartment_id
  instance_id    = oci_core_instance.arm[count.index].id
}

resource "oci_core_ipv6" "arm_ipv6" {
  count = local.arm_flex_instance_count
  vnic_id = data.oci_core_vnic_attachments.arm_vnics[count.index].vnic_attachments[0].vnic_id
  lifetime = "RESERVED"
  subnet_id = oci_core_subnet.main.id
  route_table_id = oci_core_default_route_table.main.id
  display_name = "arm-${local.arm_flex_hostnames[count.index]}-ipv6"
  freeform_tags = {
    "Purpose" = "AlwaysFreeTier"
    "Managed" = "Terraform"
  }
}

output "amd_instances" {
  description = "AMD instance information"
  value = local.amd_micro_instance_count > 0 ? {
    for i in range(local.amd_micro_instance_count) : local.amd_micro_hostnames[i] => {
      id         = oci_core_instance.amd[i].id
      public_ip  = oci_core_instance.amd[i].public_ip
      private_ip = oci_core_instance.amd[i].private_ip
      ipv6       = oci_core_ipv6.amd_ipv6[i].ip_address
      state      = oci_core_instance.amd[i].state
      ssh        = "ssh -i ./ssh_keys/id_rsa ubuntu@${oci_core_instance.amd[i].public_ip}"
    }
  } : {}
}

output "arm_instances" {
  description = "ARM instance information"
  value = local.arm_flex_instance_count > 0 ? {
    for i in range(local.arm_flex_instance_count) : local.arm_flex_hostnames[i] => {
      id         = oci_core_instance.arm[i].id
      public_ip  = oci_core_instance.arm[i].public_ip
      private_ip = oci_core_instance.arm[i].private_ip
      ipv6       = oci_core_ipv6.arm_ipv6[i].ip_address
      state      = oci_core_instance.arm[i].state
      ocpus      = local.arm_flex_ocpus_per_instance[i]
      memory_gb  = local.arm_flex_memory_per_instance[i]
      ssh        = "ssh -i ./ssh_keys/id_rsa ubuntu@${oci_core_instance.arm[i].public_ip}"
    }
  } : {}
}

output "network" {
  description = "Network information"
  value = {
    vcn_id     = oci_core_vcn.main.id
    vcn_cidr   = oci_core_vcn.main.cidr_blocks[0]
    subnet_id  = oci_core_subnet.main.id
    subnet_cidr = oci_core_subnet.main.cidr_block
  }
}

output "summary" {
  description = "Infrastructure summary"
  value = {
    region          = local.region
    total_amd       = local.amd_micro_instance_count
    total_arm       = local.arm_flex_instance_count
    total_storage   = local.total_storage
    free_tier_limit = 200
  }
}
'''
    main_tf.write_text(main_content)
    print_success("main.tf created")

def create_terraform_block_volumes() -> None:
    """Create block_volumes.tf"""
    print_status("Creating block_volumes.tf...")

    block_volumes_tf = Path("block_volumes.tf")
    if block_volumes_tf.exists():
        backup_name = f"block_volumes.tf.bak.{time.strftime('%Y%m%d_%H%M%S')}"
        shutil.copy2(block_volumes_tf, backup_name)

    block_volumes_content = '''# Block Volume Resources (Optional)
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
'''
    block_volumes_tf.write_text(block_volumes_content)
    print_success("block_volumes.tf created")

def create_cloud_init() -> None:
    """Create cloud-init.yaml"""
    print_status("Creating cloud-init.yaml...")

    cloud_init_yaml = Path("cloud-init.yaml")
    if cloud_init_yaml.exists():
        backup_name = f"cloud-init.yaml.bak.{time.strftime('%Y%m%d_%H%M%S')}"
        shutil.copy2(cloud_init_yaml, backup_name)

    cloud_init_content = '''#cloud-config
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
'''
    cloud_init_yaml.write_text(cloud_init_content)
    print_success("cloud-init.yaml created")

# ============================================================================
# TERRAFORM IMPORT AND STATE MANAGEMENT
# ============================================================================

def import_existing_resources() -> bool:
    """Import existing resources into Terraform state"""
    print_header("IMPORTING EXISTING RESOURCES")

    if not existing_vcns and not existing_amd_instances and not existing_arm_instances:
        print_status("No existing resources to import")
        return True

    print_status("Initializing Terraform...")
    try:
        def _init():
            result = run_command(["terraform", "init", "-input=false"], check=False)
            if result.returncode != 0:
                raise subprocess.CalledProcessError(result.returncode, "terraform init")
            return result

        retry_with_backoff(_init)
    except Exception as e:
        print_error(f"Terraform init failed after retries: {e}")
        return False

    imported = 0
    failed = 0

    # Import VCN
    if existing_vcns:
        first_vcn_id = list(existing_vcns.keys())[0]
        vcn_name = existing_vcns[first_vcn_id].name
        print_status(f"Importing VCN: {vcn_name}")

        result = run_command(["terraform", "state", "show", "oci_core_vcn.main"], check=False)
        if result.returncode == 0:
            print_status("  Already in state")
        else:
            success, _ = run_cmd_with_retries_and_check(
                ["terraform", "import", "oci_core_vcn.main", first_vcn_id]
            )
            if success:
                print_success("  Imported successfully")
                imported += 1
                import_vcn_components(first_vcn_id)
            else:
                print_warning("  Failed to import (see logs above)")
                failed += 1

    # Import AMD instances
    amd_index = 0
    for instance_id, instance in existing_amd_instances.items():
        if amd_index >= instance_config.amd_micro_instance_count:
            break

        print_status(f"Importing AMD instance: {instance.name}")

        result = run_command(
            ["terraform", "state", "show", f"oci_core_instance.amd[{amd_index}]"],
            check=False
        )
        if result.returncode == 0:
            print_status("  Already in state")
        else:
            success, _ = run_cmd_with_retries_and_check(
                ["terraform", "import", f"oci_core_instance.amd[{amd_index}]", instance_id]
            )
            if success:
                print_success("  Imported successfully")
                imported += 1
            else:
                print_warning("  Failed to import (see logs above)")
                failed += 1

        amd_index += 1

    # Import ARM instances
    arm_index = 0
    for instance_id, instance in existing_arm_instances.items():
        if arm_index >= instance_config.arm_flex_instance_count:
            break

        print_status(f"Importing ARM instance: {instance.name}")

        result = run_command(
            ["terraform", "state", "show", f"oci_core_instance.arm[{arm_index}]"],
            check=False
        )
        if result.returncode == 0:
            print_status("  Already in state")
        else:
            success, _ = run_cmd_with_retries_and_check(
                ["terraform", "import", f"oci_core_instance.arm[{arm_index}]", instance_id]
            )
            if success:
                print_success("  Imported successfully")
                imported += 1
            else:
                print_warning("  Failed to import (see logs above)")
                failed += 1

        arm_index += 1

    print()
    print_success(f"Import complete: {imported} imported, {failed} failed")
    return True

def import_vcn_components(vcn_id: str) -> None:
    """Import VCN-related components"""
    for ig_id, ig in existing_internet_gateways.items():
        if ig.additional_info.get("vcn_id") == vcn_id:
            result = run_command(
                ["terraform", "state", "show", "oci_core_internet_gateway.main"],
                check=False
            )
            if result.returncode != 0:
                result = run_command(
                    ["terraform", "import", "oci_core_internet_gateway.main", ig_id],
                    check=False
                )
                if result.returncode == 0:
                    print_status("    Imported Internet Gateway")
            break

    for subnet_id, subnet in existing_subnets.items():
        if subnet.additional_info.get("vcn_id") == vcn_id:
            result = run_command(
                ["terraform", "state", "show", "oci_core_subnet.main"],
                check=False
            )
            if result.returncode != 0:
                result = run_command(
                    ["terraform", "import", "oci_core_subnet.main", subnet_id],
                    check=False
                )
                if result.returncode == 0:
                    print_status("    Imported Subnet")
            break

    for rt_id, rt in existing_route_tables.items():
        if rt.additional_info.get("vcn_id") == vcn_id and ("Default" in rt.name or "default" in rt.name):
            result = run_command(
                ["terraform", "state", "show", "oci_core_default_route_table.main"],
                check=False
            )
            if result.returncode != 0:
                result = run_command(
                    ["terraform", "import", "oci_core_default_route_table.main", rt_id],
                    check=False
                )
                if result.returncode == 0:
                    print_status("    Imported Route Table")
            break

    for sl_id, sl in existing_security_lists.items():
        if sl.additional_info.get("vcn_id") == vcn_id and ("Default" in sl.name or "default" in sl.name):
            result = run_command(
                ["terraform", "state", "show", "oci_core_default_security_list.main"],
                check=False
            )
            if result.returncode != 0:
                result = run_command(
                    ["terraform", "import", "oci_core_default_security_list.main", sl_id],
                    check=False
                )
                if result.returncode == 0:
                    print_status("    Imported Security List")
            break

# ============================================================================
# TERRAFORM WORKFLOW
# ============================================================================

def out_of_capacity_auto_apply() -> bool:
    """Automatically re-run terraform apply until success on 'Out of Capacity', with backoff"""
    print_status(f"Auto-retrying terraform apply until success or max attempts ({RETRY_MAX_ATTEMPTS})...")
    attempt = 1

    while attempt <= RETRY_MAX_ATTEMPTS:
        print_status(f"Apply attempt {attempt}/{RETRY_MAX_ATTEMPTS}")
        result = run_command(["terraform", "apply", "-input=false", "tfplan"], check=False)

        if result.returncode == 0:
            print_success("terraform apply succeeded")
            return True

        output = result.stdout + result.stderr
        if any(term in output.lower() for term in ["out of capacity", "out of host capacity", "outofcapacity", "outofhostcapacity"]):
            print_warning("Apply failed with 'Out of Capacity' - will retry")
        else:
            print_error("terraform apply failed with non-retryable error")
            console.print(output)
            return False

        if attempt < RETRY_MAX_ATTEMPTS:
            sleep_time = RETRY_BASE_DELAY * (2 ** (attempt - 1))
            print_status(f"Waiting {sleep_time}s before retrying...")
            time.sleep(sleep_time)
            attempt += 1
        else:
            break

    print_error(f"terraform apply did not succeed after {RETRY_MAX_ATTEMPTS} attempts")
    return False

def run_terraform_workflow() -> bool:
    """Run complete Terraform workflow"""
    print_header("TERRAFORM WORKFLOW")

    # Step 1: Initialize
    print_status("Step 1: Initializing Terraform...")
    try:
        def _init():
            result = run_command(["terraform", "init", "-input=false", "-upgrade"], check=False)
            if result.returncode != 0:
                raise subprocess.CalledProcessError(result.returncode, "terraform init")
            return result

        retry_with_backoff(_init)
        print_success("Terraform initialized")
    except Exception as e:
        print_error(f"Terraform init failed after retries: {e}")
        return False

    # Step 2: Import existing resources
    if existing_vcns or existing_amd_instances or existing_arm_instances:
        print_status("Step 2: Importing existing resources...")
        import_existing_resources()
    else:
        print_status("Step 2: No existing resources to import")

    # Step 3: Validate
    print_status("Step 3: Validating configuration...")
    result = run_command(["terraform", "validate"], check=False)
    if result.returncode != 0:
        print_error("Terraform validation failed")
        console.print(result.stderr)
        return False
    print_success("Configuration valid")

    # Step 4: Plan
    print_status("Step 4: Creating execution plan...")
    result = run_command(["terraform", "plan", "-out=tfplan", "-input=false"], check=False)
    if result.returncode != 0:
        print_error("Terraform plan failed")
        console.print(result.stderr)
        return False
    print_success("Plan created successfully")

    # Show plan summary
    print()
    print_status("Plan summary:")
    result = run_command(["terraform", "show", "-no-color", "tfplan"], check=False)
    if result.returncode == 0:
        lines = result.stdout.split("\n")
        for line in lines[:20]:
            if any(keyword in line for keyword in ["Plan:", "#", "will be"]):
                console.print(line)

    # Step 5: Apply (with confirmation)
    if AUTO_DEPLOY or NON_INTERACTIVE:
        print_status("Step 5: Auto-applying plan...")
        apply_choice = "Y"
    else:
        apply_choice = Confirm.ask("Apply this plan?", default=False)
        apply_choice = "Y" if apply_choice else "N"

    if apply_choice == "Y":
        print_status("Applying Terraform plan...")
        if out_of_capacity_auto_apply():
            print_success("Infrastructure deployed successfully!")
            tfplan = Path("tfplan")
            if tfplan.exists():
                tfplan.unlink()

            # Show outputs
            print()
            print_header("DEPLOYMENT COMPLETE")
            result = run_command(["terraform", "output", "-json"], check=False)
            if result.returncode == 0:
                try:
                    outputs = json.loads(result.stdout)
                    console.print_json(json.dumps(outputs, indent=2))
                except json.JSONDecodeError:
                    result = run_command(["terraform", "output"], check=False)
                    console.print(result.stdout)
            else:
                result = run_command(["terraform", "output"], check=False)
                console.print(result.stdout)
        else:
            print_error("Terraform apply failed")
            return False
    else:
        print_status("Plan saved as 'tfplan' - apply later with: terraform apply tfplan")

    return True

def terraform_menu() -> bool:
    """Terraform management menu"""
    while True:
        print()
        print_header("TERRAFORM MANAGEMENT")
        console.print("  1) Full workflow (init → import → plan → apply)")
        console.print("  2) Plan only")
        console.print("  3) Apply existing plan")
        console.print("  4) Import existing resources")
        console.print("  5) Show current state")
        console.print("  6) Destroy infrastructure")
        console.print("  7) Reconfigure")
        console.print("  8) Exit")
        print()

        if AUTO_DEPLOY or NON_INTERACTIVE:
            choice = 1
            print_status("Auto mode: Running full workflow")
        else:
            choice = IntPrompt.ask("Choose option", default=1, choices=["1", "2", "3", "4", "5", "6", "7", "8"])

        if choice == 1:
            if run_terraform_workflow():
                if AUTO_DEPLOY:
                    return True
        elif choice == 2:
            run_command(["terraform", "init", "-input=false"], check=False)
            run_command(["terraform", "plan"], check=False)
        elif choice == 3:
            if Path("tfplan").exists():
                run_command(["terraform", "apply", "tfplan"], check=False)
            else:
                print_error("No plan file found")
        elif choice == 4:
            import_existing_resources()
        elif choice == 5:
            result1 = run_command(["terraform", "state", "list"], check=False)
            result2 = run_command(["terraform", "output"], check=False)
            if result1.returncode == 0 or result2.returncode == 0:
                console.print(result1.stdout)
                console.print(result2.stdout)
            else:
                print_status("No state found")
        elif choice == 6:
            if Confirm.ask("DESTROY all infrastructure?", default=False):
                run_command(["terraform", "destroy"], check=False)
        elif choice == 7:
            return False  # Signal to reconfigure
        elif choice == 8:
            return True
        else:
            print_error("Invalid choice")

        if NON_INTERACTIVE:
            return True

        print()
        input("Press Enter to continue...")

# ============================================================================
# MAIN EXECUTION
# ============================================================================

def main() -> None:
    """Main execution function"""
    print_header("OCI TERRAFORM SETUP - IDEMPOTENT EDITION")
    print_status("This script safely manages Oracle Cloud Free Tier resources")
    print_status("Safe to run multiple times - will detect and reuse existing resources")
    print()

    # Phase 1: Prerequisites
    if not install_prerequisites():
        print_error("Failed to install prerequisites")
        sys.exit(1)

    if not install_terraform():
        print_error("Failed to install Terraform")
        sys.exit(1)

    if not install_oci_cli():
        print_error("Failed to install OCI CLI")
        sys.exit(1)

    # Phase 2: Authentication
    if not setup_oci_config():
        print_error("Failed to setup OCI configuration")
        sys.exit(1)

    # Phase 3: Fetch OCI information
    if not fetch_oci_config_values():
        print_error("Failed to fetch OCI configuration values")
        sys.exit(1)

    if not fetch_availability_domains():
        print_error("Failed to fetch availability domains")
        sys.exit(1)

    if not fetch_ubuntu_images():
        print_warning("Failed to fetch some Ubuntu images - continuing anyway")

    if not generate_ssh_keys():
        print_error("Failed to generate SSH keys")
        sys.exit(1)

    # Phase 4: Resource inventory (CRITICAL for idempotency)
    inventory_all_resources()

    # Phase 5: Configuration
    if SKIP_CONFIG:
        if not load_existing_config():
            configure_from_existing_instances()
    else:
        prompt_configuration()

    # Phase 6: Generate Terraform files
    create_terraform_files()

    # Phase 7: Terraform management
    while True:
        if terraform_menu():
            break

        # Reconfigure requested
        prompt_configuration()
        create_terraform_files()

    print_header("SETUP COMPLETE")
    print_success("Oracle Cloud Free Tier infrastructure managed successfully")
    print()
    print_status("Files created/updated:")
    print_status("  • provider.tf - OCI provider configuration")
    print_status("  • variables.tf - Instance configuration")
    print_status("  • main.tf - Infrastructure resources")
    print_status("  • data_sources.tf - OCI data sources")
    print_status("  • block_volumes.tf - Storage volumes")
    print_status("  • cloud-init.yaml - Instance initialization")
    print()
    print_status("To manage your infrastructure:")
    print_status("  terraform plan    - Preview changes")
    print_status("  terraform apply   - Apply changes")
    print_status("  terraform destroy - Remove all resources")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print()
        print_warning("Interrupted by user")
        sys.exit(1)
    except Exception as e:
        print_error(f"Unexpected error: {e}")
        if DEBUG:
            import traceback
            traceback.print_exc()
        sys.exit(1)
