# Python Implementation

A Python-based implementation of CloudCradle with a clean, object-oriented design.

## Features

- Full Python implementation with rich CLI output
- Package-based architecture
- Cross-platform support
- Type hints for better code clarity

## Installation

```bash
cd implementations/python
pip install -r requirements.txt
```

Or install as a package:

```bash
pip install -e .
```

## Usage

### Basic Usage

```bash
python setup_oci_terraform.py
```

### As a Package

```bash
oci-terraform-setup
```

### Command Line Options

```bash
python setup_oci_terraform.py --help
```

Available options:
- `--non-interactive` - Run without prompts
- `--auto-use-existing` - Automatically use existing instances
- `--auto-deploy` - Automatically deploy
- `--force-reauth` - Force re-authentication
- `--debug` - Enable debug logging

## Requirements

- Python 3.8+
- See `requirements.txt` for dependencies

## Development

```bash
# Install development dependencies
pip install -e ".[dev]"

# Run tests (if available)
pytest

# Format code
black .

# Lint
flake8
```

## Project Structure

```
python/
├── setup_oci_terraform.py  # Main entry point
├── requirements.txt         # Dependencies
├── pyproject.toml          # Package configuration
├── setup.py                # Package setup
└── README.md               # This file
```

## See Also

- [Main README](../../README.md)
- [Free Tier Guide](../../docs/FREE_TIER.md)
