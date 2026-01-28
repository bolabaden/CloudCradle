# TypeScript/Node.js Implementation

A modern TypeScript/Node.js implementation of CloudCradle with full type safety and cross-platform support.

## Features

- Full TypeScript implementation with type safety
- Cross-platform (Windows, macOS, Linux, WSL)
- Rich CLI with interactive prompts
- No dependency on `jq` (uses native JSON parsing)
- Modern async/await patterns

## Prerequisites

- Node.js 16.0.0 or higher
- npm or yarn
- OCI CLI installed and configured
- Terraform installed

## Installation

```bash
cd implementations/typescript
npm install
```

## Usage

### Development Mode

```bash
npm run dev
```

### Build and Run

```bash
npm run build
npm start
```

### Non-Interactive Mode

```bash
NON_INTERACTIVE=true AUTO_USE_EXISTING=true AUTO_DEPLOY=true npm start
```

## Command Line Options

```bash
node dist/index.js --help
```

Available options:
- `--non-interactive` - Run without prompts
- `--auto-use-existing` - Automatically use existing instances
- `--auto-deploy` - Automatically deploy
- `--skip-config` - Skip configuration prompts
- `--debug` - Enable debug logging
- `--force-reauth` - Force re-authentication
- `--tf-backend <type>` - Terraform backend type (local|oci)
- `--oci-config-file <path>` - OCI config file path
- `--oci-profile <profile>` - OCI profile name

## Environment Variables

All options can also be set via environment variables:
- `NON_INTERACTIVE`
- `AUTO_USE_EXISTING`
- `AUTO_DEPLOY`
- `SKIP_CONFIG`
- `DEBUG`
- `FORCE_REAUTH`
- `TF_BACKEND`
- `OCI_CONFIG_FILE`
- `OCI_PROFILE`

## Project Structure

```
typescript/
├── src/
│   ├── index.ts              # Main entry point
│   ├── types.ts              # TypeScript type definitions
│   ├── constants.ts          # Constants and defaults
│   ├── utils/                # Utility modules
│   │   ├── logger.ts         # Logging utilities
│   │   ├── platform.ts       # Platform detection
│   │   ├── command.ts        # Command execution
│   │   ├── json.ts           # JSON parsing utilities
│   │   ├── config.ts         # OCI config parsing
│   │   └── ssh.ts            # SSH key generation
│   ├── oci/                  # OCI-related modules
│   │   ├── auth.ts           # Authentication
│   │   ├── discovery.ts       # Resource discovery
│   │   └── inventory.ts      # Resource inventory
│   ├── config/               # Configuration modules
│   │   └── prompts.ts        # Interactive prompts
│   └── terraform/            # Terraform modules
│       ├── generator.ts      # File generation
│       └── workflow.ts       # Terraform workflow
├── dist/                     # Compiled JavaScript
├── package.json
├── tsconfig.json
└── README.md
```

## Development

```bash
# Install dependencies
npm install

# Build TypeScript
npm run build

# Run in development mode
npm run dev

# Run with ts-node
npm run dev
```

## Differences from Bash Script

- Uses Node.js native APIs instead of shell commands where possible
- Type-safe with TypeScript
- Better error handling with try/catch
- Uses `inquirer` for interactive prompts
- Uses `commander` for CLI argument parsing
- Cross-platform file path handling
- No dependency on `jq` (uses native JSON parsing)

## See Also

- [Main README](../../README.md)
- [Free Tier Guide](../../docs/FREE_TIER.md)
- [Installation Guide](INSTALL.md)
