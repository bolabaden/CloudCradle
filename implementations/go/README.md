# Go Implementation of OCI Terraform Setup

This is a comprehensive Go port of the bash script `setup_oci_terraform.sh`. The implementation maintains all functionality while providing better cross-platform support and type safety.

## Structure

All Go source files are in `cmd/setup-oci-terraform/`:

- `main.go` - Main entry point and CLI setup
- `oci_client.go` - OCI SDK client initialization and authentication
- `inventory.go` - Resource discovery and inventory
- `config.go` - Configuration management and user prompts
- `utils.go` - Utility functions (SSH keys, prompts, retries)
- `filegen.go` - Terraform file generation
- `terraform.go` - Terraform workflow execution

## Building

```bash
cd implementations/go
go mod download
go build -o setup-oci-terraform ./cmd/setup-oci-terraform
```

## Usage

Same as the bash script:
```bash
./setup-oci-terraform
./setup-oci-terraform --non-interactive --auto-deploy
```

## Dependencies

- github.com/oracle/oci-go-sdk/v65 - OCI SDK
- github.com/spf13/cobra - CLI framework
- golang.org/x/crypto/ssh - SSH key generation
