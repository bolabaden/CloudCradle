"""OCI Client for interacting with Oracle Cloud Infrastructure"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import oci

from oci_terraform_setup.auth_manager import OCIAuthManager


class OCIClient:
    """OCI client wrapper with automatic browser authentication"""

    def __init__(
        self,
        config_file: os.PathLike | str = "~/.oci/config",
    ) -> None:
        self.config_file: Path = Path(os.path.normpath(config_file)).expanduser()
        self.auth_manager: OCIAuthManager = OCIAuthManager(config_file)
        
        # Ensure authentication is valid before proceeding
        if not self.auth_manager.ensure_authenticated():
            raise Exception("Failed to authenticate with OCI")
        
        self.identity_client: oci.identity.IdentityClient = oci.identity.IdentityClient(self.config)
        self.compute_client: oci.core.ComputeClient = oci.core.ComputeClient(self.config)

    def test_connectivity(self) -> bool:
        """Test OCI connectivity"""
        try:
            # Refresh session if needed
            self.auth_manager.refresh_session_if_needed()
            
            # Try to list regions
            self.identity_client.list_regions()
            return True
        except Exception as e:
            raise Exception(f"OCI connectivity test failed: {e.__class__.__name__}: {e}")

    @property
    def config(self) -> dict[str, str]:
        """Get current config values"""
        return self.auth_manager.get_config()

    def get_user_info(self) -> dict[str, str]:
        """Get authenticated user information"""
        return self.auth_manager.get_user_info()

    def get_availability_domains(self) -> list[str]:
        """Get availability domains for the tenancy"""
        try:
            self.auth_manager.refresh_session_if_needed()
            response: Any | oci.response.Response | None = self.identity_client.list_availability_domains(
                compartment_id=self.config["tenancy"]
            )
            if response is None:
                raise RuntimeError("No response from OCI")
        except Exception as e:
            raise Exception(f"Failed to fetch availability domains: {e.__class__.__name__}: {e}")
        else:
            return [ad.name for ad in response.data]

    def get_ubuntu_images(self) -> dict[str, str]:
        """Get Ubuntu images for the region"""
        try:
            self.auth_manager.refresh_session_if_needed()
            
            # List images
            response: Any | oci.response.Response | None = (
                self.compute_client.list_images(
                    compartment_id=self.config["tenancy"],
                    operating_system="Canonical Ubuntu",
                    operating_system_version="22.04",
                )
            )

            images: dict[str, str] = {}

            if response is None:
                raise RuntimeError("No response from OCI")

            for image in response.data:
                if "22.04" in image.display_name:
                    if "aarch64" in image.display_name.lower():
                        images["arm64"] = image.id
                    else:
                        images["x86_64"] = image.id

            # If no 22.04 found, try 20.04
            if not images:
                response = self.compute_client.list_images(
                    compartment_id=self.config["tenancy"],
                    operating_system="Canonical Ubuntu",
                    operating_system_version="20.04",
                )

                if response is None:
                    raise RuntimeError("No response from OCI")

                for image in response.data:
                    if "20.04" in image.display_name:
                        if "aarch64" in image.display_name.lower():
                            images["arm64"] = image.id
                        else:
                            images["x86_64"] = image.id

        except Exception as e:
            raise Exception(f"Failed to fetch Ubuntu images: {e.__class__.__name__}: {e}")
        else:
            return images
