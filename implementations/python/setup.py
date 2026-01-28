from setuptools import setup, find_packages

setup(
    name="oci-terraform-setup",
    version="1.0.0",
    packages=find_packages(where="src"),
    package_dir={"": "src"},
    install_requires=[
        "oci>=2.155.0",
        "python-terraform>=1.0.0",
        "cryptography>=3.2.1",
        "click>=8.0.0",
        "rich>=13.0.0",
        "pyyaml>=5.4",
        "jinja2>=3.0.0",
    ],
    entry_points={
        "console_scripts": [
            "oci-terraform-setup=oci_terraform_setup.cli:main",
        ],
    },
    python_requires=">=3.8",
) 