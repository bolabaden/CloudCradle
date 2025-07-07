#!/usr/bin/env python3
"""OCI Terraform Setup CLI"""

from __future__ import annotations

import os
from typing import Any

import click
from rich.console import Console
from rich.panel import Panel
from rich.progress import Progress, SpinnerColumn, TextColumn
from rich.prompt import Confirm
from rich.table import Table

from oci_terraform_setup.setup import OCITerraformSetup

CONSOLE = Console()


@click.command()
@click.option("--config-file", "-c", default="~/.oci/config", help="OCI config file path")
@click.option("--skip-terraform", is_flag=True, help="Skip Terraform initialization")
@click.option("--auto-approve", is_flag=True, help="Auto-approve Terraform initialization")
def main(
    config_file: os.PathLike | str,
    skip_terraform: bool,
    auto_approve: bool,
):
    """OCI Terraform Setup Tool - Complete automation for OCI + Terraform with browser authentication"""

    CONSOLE.print(
        Panel.fit(
            "[bold blue]OCI Terraform Setup Tool[/bold blue]\n"
            "Complete automation for Oracle Cloud Infrastructure + Terraform\n"
            "[green]✨ Now with browser-based authentication - no manual setup required![/green]",
            border_style="blue",
        )
    )

    try:
        setup = OCITerraformSetup(
            config_file=config_file,
            non_interactive=True,  # Always non-interactive with browser auth
        )

        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            console=CONSOLE,
        ) as progress:
            task = progress.add_task("Setting up OCI Terraform...", total=None)

            # Run the complete setup
            result = setup.run()

            progress.update(task, description="Setup completed successfully!")

        # Display results
        display_results(result)

        if not skip_terraform:
            should_init = auto_approve or Confirm.ask("Initialize Terraform now?")
            if should_init:
                with Progress(
                    SpinnerColumn(),
                    TextColumn("[progress.description]{task.description}"),
                    console=CONSOLE,
                ) as progress:
                    task = progress.add_task("Initializing Terraform...", total=None)
                    setup.initialize_terraform()

        CONSOLE.print("\n[bold green]✅ Setup completed successfully![/bold green]")
        CONSOLE.print("\n[bold cyan]Next steps:[/bold cyan]")
        CONSOLE.print("1. [white]terraform plan[/white] - Review the infrastructure changes")
        CONSOLE.print("2. [white]terraform apply[/white] - Apply the infrastructure changes")

    except Exception as e:
        CONSOLE.print(f"\n[bold red]❌ Error: {e.__class__.__name__}: {e}[/bold red]")
        raise click.Abort()


def display_results(result: dict[str, Any]):
    """Display setup results in a nice table"""
    table = Table(title="Setup Results", show_header=True, header_style="bold magenta")
    table.add_column("Component", style="cyan", width=20)
    table.add_column("Status", style="green", width=10)
    table.add_column("Details", style="white")

    for component, details in result.items():
        status = "✅ Success" if details.get("success", False) else "❌ Failed"        
        table.add_row(
            component.replace("_", " ").title(),
            status,
            str(details.get("details", "")),
        )

    CONSOLE.print("\n")
    CONSOLE.print(table)


if __name__ == "__main__":
    main()
