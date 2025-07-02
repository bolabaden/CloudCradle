"""Terraform manager for Python"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any


class TerraformManager:
    """Manage Terraform operations"""

    def __init__(self, work_dir: os.PathLike | str) -> None:
        self.work_dir: Path = Path(os.path.normpath(work_dir))

    def init(self, upgrade: bool = True) -> str:
        """Initialize Terraform"""
        cmd = ["terraform", "init"]
        if upgrade:
            cmd.append("-upgrade")

        result: subprocess.CompletedProcess[str] = subprocess.run(
            cmd, cwd=self.work_dir, capture_output=True, text=True
        )

        if result.returncode != 0:
            raise Exception(f"Terraform init failed: {result.stderr}")

        return result.stdout

    def plan(self, var_file: str | None = None) -> str:
        """Run terraform plan"""
        cmd: list[str] = ["terraform", "plan"]
        if var_file:
            cmd.extend(["-var-file", var_file])

        result: subprocess.CompletedProcess[str] = subprocess.run(
            cmd, cwd=self.work_dir, capture_output=True, text=True
        )

        if result.returncode != 0:
            raise Exception(f"Terraform plan failed: {result.stderr}")

        return result.stdout

    def apply(self, auto_approve: bool = True, var_file: str | None = None) -> str:
        """Run terraform apply"""
        cmd: list[str] = ["terraform", "apply"]
        if auto_approve:
            cmd.append("-auto-approve")
        if var_file:
            cmd.extend(["-var-file", var_file])

        result: subprocess.CompletedProcess[str] = subprocess.run(
            cmd, cwd=self.work_dir, capture_output=True, text=True
        )

        if result.returncode != 0:
            raise Exception(f"Terraform apply failed: {result.stderr}")

        return result.stdout

    def destroy(self, auto_approve: bool = True) -> str:
        """Run terraform destroy"""
        cmd: list[str] = ["terraform", "destroy"]
        if auto_approve:
            cmd.append("-auto-approve")

        result: subprocess.CompletedProcess[str] = subprocess.run(
            cmd,
            cwd=self.work_dir,
            capture_output=True,
            text=True,
        )

        if result.returncode != 0:
            raise Exception(f"Terraform destroy failed: {result.stderr}")

        return result.stdout

    def output(self, json_format: bool = True) -> dict[str, Any] | str:
        """Get Terraform outputs"""
        cmd: list[str] = ["terraform", "output"]
        if json_format:
            cmd.append("-json")

        result: subprocess.CompletedProcess[str] = subprocess.run(
            cmd,
            cwd=self.work_dir,
            capture_output=True,
            text=True,
        )

        if result.returncode != 0:
            raise Exception(f"Terraform output failed: {result.stderr}")

        if json_format:
            return json.loads(result.stdout)
        return result.stdout
