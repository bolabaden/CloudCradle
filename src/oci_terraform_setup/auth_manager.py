"""OCI Authentication Manager with Browser-based Authentication"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Any

import oci
from rich.console import Console

CONSOLE: Console = Console()


class OCIAuthManager:
    """Manages OCI authentication with browser-based session tokens"""

    def __init__(self, config_file: os.PathLike | str = "~/.oci/config"):
        self.config_file: Path = Path(config_file).expanduser()
        self.session_config_file: Path = self.config_file.parent / "oci_cli_rc"
        self.session_token_file: Path = self.config_file.parent / "sessions" / "DEFAULT" / "token"

    def is_session_valid(self) -> bool:
        """Check if current session token is valid"""
        try:
            if not self.config_file.exists():
                return False

            # Try to create a client and make a simple API call
            config: dict[str, Any] = oci.config.from_file(str(self.config_file))
            identity_client = oci.identity.IdentityClient(config)
            identity_client.list_regions()
        except Exception:
            return False
        else:
            return True

    def authenticate_with_browser(self) -> bool:
        """Authenticate using browser-based session token"""
        CONSOLE.print("[yellow]Authenticating with OCI via browser...[/yellow]")

        try:
            # Run oci session authenticate command
            result: subprocess.CompletedProcess[str] = subprocess.run(
                ["oci", "session", "authenticate"],
                capture_output=True,
                text=True,
                input="\n",  # Auto-confirm prompts
            )

            if result.returncode == 0:
                CONSOLE.print("[green]✅ Browser authentication successful![/green]")
                return True
            else:
                CONSOLE.print(f"[red]❌ Authentication failed: {result.stderr.strip()}[/red]")
                return False

        except FileNotFoundError:
            CONSOLE.print("[red]❌ OCI CLI not found. Please install it first.[/red]")
            return False
        except Exception as e:
            CONSOLE.print(f"[red]❌ Authentication error: {e.__class__.__name__}: {e}[/red]")
            return False

    def setup_config_if_missing(self) -> bool:
        """Setup OCI config using browser authentication if it doesn't exist"""
        if not self.config_file.exists():
            CONSOLE.print("[yellow]No OCI config found. Setting up browser authentication...[/yellow]")

            try:
                # Run oci setup bootstrap for first-time setup
                result: subprocess.CompletedProcess[str] = subprocess.run(
                    ["oci", "setup", "bootstrap"],
                    capture_output=True,
                    text=True,
                    input="Y\nY\n",  # Answer yes to browser setup prompts
                )

                if result.returncode == 0:
                    CONSOLE.print("[green]✅ OCI config setup completed![/green]")
                    return True
                else:
                    CONSOLE.print(f"[red]❌ Config setup failed: {result.stderr.strip()}[/red]")
                    return False

            except FileNotFoundError:
                CONSOLE.print("[red]❌ OCI CLI not found. Please install it first.[/red]")
                return False
            except Exception as e:
                CONSOLE.print(f"[red]❌ Config setup error: {e.__class__.__name__}: {e}[/red]")
                return False

        return True

    def ensure_authenticated(self) -> bool:
        """Ensure we have valid authentication, setting up if needed"""
        # First, try to setup config if missing
        if not self.setup_config_if_missing():
            return False

        # Check if current session is valid
        if self.is_session_valid():
            CONSOLE.print("[green]✅ Existing OCI session is valid[/green]")
            return True

        # If not valid, authenticate with browser
        return self.authenticate_with_browser()

    def get_config(self) -> dict[str, Any]:
        """Get OCI config dictionary"""
        if not self.config_file.exists():
            raise FileNotFoundError(f"OCI config file not found: {self.config_file}")

        return oci.config.from_file(str(self.config_file))

    def get_user_info(self) -> dict[str, str]:
        """Get user information from the authenticated session"""
        try:
            config: dict[str, Any] = self.get_config()
            identity_client: oci.identity.IdentityClient = oci.identity.IdentityClient(config)

            # Get current user info
            user_response: Any | oci.response.Response | None = identity_client.get_user(config["user"])
            tenancy_response: Any | oci.response.Response | None = identity_client.get_tenancy(config["tenancy"])

            if user_response is None or tenancy_response is None:
                raise Exception("No response from OCI")

            return {
                "user_ocid": config["user"],
                "tenancy_ocid": config["tenancy"],
                "region": config["region"],
                "user_name": user_response.data.name,
                "tenancy_name": tenancy_response.data.name,
            }
        except Exception as e:
            raise Exception(f"Failed to get user info: {e.__class__.__name__}: {e}")

    def refresh_session_if_needed(self) -> bool:
        """Refresh session token if it's expired or about to expire"""
        if not self.is_session_valid():
            CONSOLE.print("[yellow]Session expired, refreshing...[/yellow]")
            return self.authenticate_with_browser()
        return True
