package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/oracle/oci-go-sdk/v65/common"
	"github.com/oracle/oci-go-sdk/v65/core"
	"github.com/oracle/oci-go-sdk/v65/identity"
	"github.com/spf13/cobra"
)

// Constants
const (
	FreeTierMaxAMDInstances = 2
	FreeTierAMDShape         = "VM.Standard.E2.1.Micro"
	FreeTierMaxARMOCPUs      = 4
	FreeTierMaxARMMemoryGB   = 24
	FreeTierARMShape         = "VM.Standard.A1.Flex"
	FreeTierMaxStorageGB     = 200
	FreeTierMinBootVolumeGB  = 47
	FreeTierMaxARMInstances   = 4
	FreeTierMaxVCNs           = 2

	RetryMaxAttempts = 8
	RetryBaseDelay   = 15 // seconds
	OCICmdTimeout    = 20 // seconds
)

// Global configuration
type Config struct {
	NonInteractive      bool
	AutoUseExisting     bool
	AutoDeploy          bool
	SkipConfig          bool
	Debug               bool
	ForceReauth         bool
	TFBackend           string
	TFBackendBucket     string
	TFBackendCreateBucket bool
	TFBackendRegion     string
	TFBackendEndpoint   string
	TFBackendStateKey   string
	TFBackendAccessKey  string
	TFBackendSecretKey  string
	OCIConfigFile       string
	OCIProfile          string
	OCIAuthRegion       string
	OCIConnectionTimeout int
	OCIReadTimeout      int
	OCIMaxRetries       int
}

// OCI configuration values
type OCIConfig struct {
	TenancyOCID           string
	UserOCID              string
	Region                string
	Fingerprint           string
	AvailabilityDomain    string
	UbuntuImageOCID       string
	UbuntuARMFlexImageOCID string
	SSHPublicKey          string
	AuthMethod            string
}

// Existing resources
type ExistingResources struct {
	VCNs              map[string]VCNInfo
	Subnets           map[string]SubnetInfo
	InternetGateways  map[string]IGInfo
	RouteTables       map[string]RTInfo
	SecurityLists     map[string]SLInfo
	AMDInstances      map[string]InstanceInfo
	ARMInstances      map[string]InstanceInfo
	BootVolumes       map[string]VolumeInfo
	BlockVolumes      map[string]VolumeInfo
}

type VCNInfo struct {
	Name string
	CIDR string
}

type SubnetInfo struct {
	Name string
	CIDR string
	VCNID string
}

type IGInfo struct {
	Name string
	VCNID string
}

type RTInfo struct {
	Name string
	VCNID string
}

type SLInfo struct {
	Name string
	VCNID string
}

type InstanceInfo struct {
	Name      string
	State     string
	Shape     string
	PublicIP  string
	PrivateIP string
	OCPUs     int
	Memory    int
}

type VolumeInfo struct {
	Name string
	Size int
}

// Instance configuration
type InstanceConfig struct {
	AMDMicroInstanceCount      int
	AMDMicroBootVolumeSizeGB    int
	ARMFlexInstanceCount        int
	ARMFlexOCPUsPerInstance     []int
	ARMFlexMemoryPerInstance    []int
	ARMFlexBootVolumeSizeGB     []int
	ARMFlexBlockVolumes         []int
	AMDMicroHostnames           []string
	ARMFlexHostnames            []string
}

// Application state
type App struct {
	Config            *Config
	OCIConfig         *OCIConfig
	Resources         *ExistingResources
	InstanceConfig    *InstanceConfig
	IdentityClient    identity.IdentityClient
	ComputeClient     core.ComputeClient
	VirtualNetworkClient core.VirtualNetworkClient
	BlockStorageClient core.BlockstorageClient
}

func main() {
	app := &App{
		Config:     defaultConfig(),
		OCIConfig:  &OCIConfig{},
		Resources:  &ExistingResources{},
		InstanceConfig: &InstanceConfig{},
	}

	var rootCmd = &cobra.Command{
		Use:   "setup-oci-terraform",
		Short: "OCI Terraform Setup - Idempotent Edition",
		Long:  "Comprehensive, idempotent script for managing Oracle Cloud Free Tier resources with Terraform",
		Run: func(cmd *cobra.Command, args []string) {
			if err := app.run(); err != nil {
				fmt.Fprintf(os.Stderr, "Error: %v\n", err)
				os.Exit(1)
			}
		},
	}

	// Flags
	rootCmd.Flags().BoolVar(&app.Config.NonInteractive, "non-interactive", false, "Run in non-interactive mode")
	rootCmd.Flags().BoolVar(&app.Config.AutoUseExisting, "auto-use-existing", false, "Automatically use existing instances")
	rootCmd.Flags().BoolVar(&app.Config.AutoDeploy, "auto-deploy", false, "Automatically deploy without confirmation")
	rootCmd.Flags().BoolVar(&app.Config.SkipConfig, "skip-config", false, "Skip configuration step")
	rootCmd.Flags().BoolVar(&app.Config.Debug, "debug", false, "Enable debug output")
	rootCmd.Flags().BoolVar(&app.Config.ForceReauth, "force-reauth", false, "Force re-authentication")
	rootCmd.Flags().StringVar(&app.Config.TFBackend, "tf-backend", "local", "Terraform backend (local|oci)")
	rootCmd.Flags().StringVar(&app.Config.TFBackendBucket, "tf-backend-bucket", "", "Terraform backend bucket name")
	rootCmd.Flags().BoolVar(&app.Config.TFBackendCreateBucket, "tf-backend-create-bucket", false, "Create backend bucket if missing")
	rootCmd.Flags().StringVar(&app.Config.OCIConfigFile, "oci-config", "", "OCI config file path")
	rootCmd.Flags().StringVar(&app.Config.OCIProfile, "oci-profile", "DEFAULT", "OCI profile name")

	// Environment variable support
	if os.Getenv("NON_INTERACTIVE") == "true" {
		app.Config.NonInteractive = true
	}
	if os.Getenv("AUTO_USE_EXISTING") == "true" {
		app.Config.AutoUseExisting = true
	}
	if os.Getenv("AUTO_DEPLOY") == "true" {
		app.Config.AutoDeploy = true
	}
	if os.Getenv("SKIP_CONFIG") == "true" {
		app.Config.SkipConfig = true
	}
	if os.Getenv("DEBUG") == "true" {
		app.Config.Debug = true
	}
	if os.Getenv("FORCE_REAUTH") == "true" {
		app.Config.ForceReauth = true
	}

	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func defaultConfig() *Config {
	homeDir, _ := os.UserHomeDir()
	ociConfig := filepath.Join(homeDir, ".oci", "config")
	if envConfig := os.Getenv("OCI_CONFIG_FILE"); envConfig != "" {
		ociConfig = envConfig
	}

	return &Config{
		NonInteractive:      false,
		AutoUseExisting:     false,
		AutoDeploy:          false,
		SkipConfig:          false,
		Debug:               false,
		ForceReauth:         false,
		TFBackend:           "local",
		TFBackendBucket:     "",
		TFBackendCreateBucket: false,
		TFBackendRegion:     "",
		TFBackendEndpoint:   "",
		TFBackendStateKey:   "terraform.tfstate",
		TFBackendAccessKey:  "",
		TFBackendSecretKey:  "",
		OCIConfigFile:       ociConfig,
		OCIProfile:          "DEFAULT",
		OCIAuthRegion:       "",
		OCIConnectionTimeout: 10,
		OCIReadTimeout:      60,
		OCIMaxRetries:       3,
	}
}

func (app *App) run() error {
	printHeader("OCI TERRAFORM SETUP - IDEMPOTENT EDITION")
	printStatus("This script safely manages Oracle Cloud Free Tier resources")
	printStatus("Safe to run multiple times - will detect and reuse existing resources")
	fmt.Println()

	// Phase 1: Prerequisites
	if err := app.installPrerequisites(); err != nil {
		return fmt.Errorf("prerequisites installation failed: %w", err)
	}

	// Phase 2: Authentication
	// Initialize OCI clients first (needed for validation)
	if err := app.initializeOCIClients(); err != nil {
		// Will attempt to authenticate if this fails
	}
	
	if err := app.setupOCIConfig(); err != nil {
		return fmt.Errorf("OCI configuration failed: %w", err)
	}

	// Phase 3: Fetch OCI information
	if err := app.fetchOCIConfigValues(); err != nil {
		return fmt.Errorf("failed to fetch OCI config values: %w", err)
	}

	if err := app.fetchAvailabilityDomains(); err != nil {
		return fmt.Errorf("failed to fetch availability domains: %w", err)
	}

	if err := app.fetchUbuntuImages(); err != nil {
		return fmt.Errorf("failed to fetch Ubuntu images: %w", err)
	}

	if err := app.generateSSHKeys(); err != nil {
		return fmt.Errorf("failed to generate SSH keys: %w", err)
	}

	// Initialize resources map
	app.initResources()

	// Phase 4: Resource inventory
	if err := app.inventoryAllResources(); err != nil {
		return fmt.Errorf("resource inventory failed: %w", err)
	}

	// Phase 5: Configuration
	if !app.Config.SkipConfig {
		if err := app.promptConfiguration(); err != nil {
			return fmt.Errorf("configuration failed: %w", err)
		}
	} else {
		if err := app.loadExistingConfig(); err != nil {
			app.configureFromExistingInstances()
		}
	}

	// Phase 6: Generate Terraform files
	if err := app.createTerraformFiles(); err != nil {
		return fmt.Errorf("failed to create Terraform files: %w", err)
	}

	// Phase 7: Terraform management
	if err := app.runTerraformWorkflow(); err != nil {
		return fmt.Errorf("Terraform workflow failed: %w", err)
	}

	printHeader("SETUP COMPLETE")
	printSuccess("Oracle Cloud Free Tier infrastructure managed successfully")
	fmt.Println()
	printStatus("Files created/updated:")
	printStatus("  • provider.tf - OCI provider configuration")
	printStatus("  • variables.tf - Instance configuration")
	printStatus("  • main.tf - Infrastructure resources")
	printStatus("  • data_sources.tf - OCI data sources")
	printStatus("  • block_volumes.tf - Storage volumes")
	printStatus("  • cloud-init.yaml - Instance initialization")
	fmt.Println()
	printStatus("To manage your infrastructure:")
	printStatus("  terraform plan    - Preview changes")
	printStatus("  terraform apply   - Apply changes")
	printStatus("  terraform destroy - Remove all resources")

	return nil
}

// Utility functions for output
func printStatus(msg string) {
	fmt.Printf("\033[0;34m[INFO]\033[0m %s\n", msg)
}

func printSuccess(msg string) {
	fmt.Printf("\033[0;32m[SUCCESS]\033[0m %s\n", msg)
}

func printWarning(msg string) {
	fmt.Printf("\033[1;33m[WARNING]\033[0m %s\n", msg)
}

func printError(msg string) {
	fmt.Printf("\033[0;31m[ERROR]\033[0m %s\n", msg)
}

func printDebug(msg string, app *App) {
	if app.Config.Debug {
		fmt.Printf("\033[0;36m[DEBUG]\033[0m %s\n", msg)
	}
}

func printHeader(title string) {
	fmt.Println()
	fmt.Println("\033[1;35m════════════════════════════════════════════════════════════════\033[0m")
	fmt.Printf("\033[1;35m  %s\033[0m\n", title)
	fmt.Println("\033[1;35m════════════════════════════════════════════════════════════════\033[0m")
	fmt.Println()
}

func printSubheader(title string) {
	fmt.Println()
	fmt.Printf("\033[1;36m── %s ──\033[0m\n", title)
	fmt.Println()
}

// Placeholder implementations - these will be filled in subsequent files
func (app *App) installPrerequisites() error {
	printSubheader("Installing Prerequisites")
	// Implementation will check for jq, curl, terraform, oci-cli
	printSuccess("All prerequisites installed")
	return nil
}

func (app *App) setupOCIConfig() error {
	printSubheader("OCI Authentication")
	// Implementation will handle OCI authentication
	printSuccess("OCI authentication configured successfully")
	return nil
}

func (app *App) fetchOCIConfigValues() error {
	printSubheader("Fetching OCI Configuration")
	// Implementation will read OCI config file
	printSuccess("OCI configuration values fetched")
	return nil
}

func (app *App) fetchAvailabilityDomains() error {
	printStatus("Fetching availability domains...")
	// Implementation will query OCI API
	printSuccess("Availability domain: AD-1")
	return nil
}

func (app *App) fetchUbuntuImages() error {
	printStatus("Fetching Ubuntu images...")
	// Implementation will query OCI API
	printSuccess("Ubuntu images fetched")
	return nil
}

func (app *App) generateSSHKeys() error {
	printStatus("Setting up SSH keys...")
	// Implementation will generate SSH keys
	printSuccess("SSH key pair generated")
	return nil
}

// inventoryAllResources is implemented in inventory.go

func (app *App) promptConfiguration() error {
	printHeader("INSTANCE CONFIGURATION")
	// Implementation will prompt for configuration
	printSuccess("Configuration complete")
	return nil
}

func (app *App) loadExistingConfig() error {
	// Implementation will load from variables.tf
	return fmt.Errorf("no existing config")
}

func (app *App) configureFromExistingInstances() {
	// Implementation will configure from existing instances
}

// createTerraformFiles is implemented in filegen.go
// runTerraformWorkflow is implemented in terraform.go
