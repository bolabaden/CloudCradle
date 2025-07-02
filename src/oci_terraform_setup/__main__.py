"""Entry point for running oci_terraform_setup as a module"""

import importlib.util
if not importlib.util.find_spec("oci_terraform_setup"):
    import sys
    sys.path.append(".")

from oci_terraform_setup.cli import main

if __name__ == "__main__":
    main() 