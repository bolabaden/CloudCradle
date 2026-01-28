package main

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/oracle/oci-go-sdk/v65/common"
	"github.com/oracle/oci-go-sdk/v65/core"
	"github.com/oracle/oci-go-sdk/v65/identity"
)

// Initialize OCI clients
func (app *App) initializeOCIClients() error {
	configProvider, err := common.ConfigurationProviderFromFileWithProfile(
		app.Config.OCIConfigFile,
		app.Config.OCIProfile,
		nil,
	)
	if err != nil {
		return fmt.Errorf("failed to load OCI config: %w", err)
	}

	// Identity client
	identityClient, err := identity.NewIdentityClientWithConfigurationProvider(configProvider)
	if err != nil {
		return fmt.Errorf("failed to create identity client: %w", err)
	}
	app.IdentityClient = identityClient

	// Compute client
	computeClient, err := core.NewComputeClientWithConfigurationProvider(configProvider)
	if err != nil {
		return fmt.Errorf("failed to create compute client: %w", err)
	}
	app.ComputeClient = computeClient

	// Virtual Network client
	virtualNetworkClient, err := core.NewVirtualNetworkClientWithConfigurationProvider(configProvider)
	if err != nil {
		return fmt.Errorf("failed to create virtual network client: %w", err)
	}
	app.VirtualNetworkClient = virtualNetworkClient

	// Block Storage client
	blockStorageClient, err := core.NewBlockstorageClientWithConfigurationProvider(configProvider)
	if err != nil {
		return fmt.Errorf("failed to create block storage client: %w", err)
	}
	app.BlockStorageClient = blockStorageClient

	return nil
}

// Read OCI config value
func readOCIConfigValue(key, configFile, profile string) (string, error) {
	file, err := os.Open(configFile)
	if err != nil {
		return "", err
	}
	defer file.Close()

	inProfile := false
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		
		// Check for profile section
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			sectionName := strings.Trim(line, "[]")
			inProfile = (sectionName == profile)
			continue
		}

		if inProfile && strings.HasPrefix(line, key+"=") {
			value := strings.TrimPrefix(line, key+"=")
			return strings.TrimSpace(value), nil
		}
	}

	return "", fmt.Errorf("key %s not found in profile %s", key, profile)
}

// Validate existing OCI config
func (app *App) validateExistingOCIConfig() error {
	if _, err := os.Stat(app.Config.OCIConfigFile); os.IsNotExist(err) {
		printWarning(fmt.Sprintf("OCI config not found at %s", app.Config.OCIConfigFile))
		return fmt.Errorf("config file not found")
	}

	// Try to initialize clients to validate config
	if err := app.initializeOCIClients(); err != nil {
		return err
	}

	// Test connectivity
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(app.Config.OCIConnectionTimeout)*time.Second)
	defer cancel()

	tenancyID, err := readOCIConfigValue("tenancy", app.Config.OCIConfigFile, app.Config.OCIProfile)
	if err != nil {
		return err
	}

	req := identity.GetTenancyRequest{
		TenancyId: common.String(tenancyID),
	}

	_, err = app.IdentityClient.GetTenancy(ctx, req)
	if err != nil {
		return fmt.Errorf("connectivity test failed: %w", err)
	}

	return nil
}

// Fetch OCI config values
func (app *App) fetchOCIConfigValues() error {
	printSubheader("Fetching OCI Configuration")

	// Tenancy OCID
	tenancyOCID, err := readOCIConfigValue("tenancy", app.Config.OCIConfigFile, app.Config.OCIProfile)
	if err != nil {
		return fmt.Errorf("failed to fetch tenancy OCID: %w", err)
	}
	app.OCIConfig.TenancyOCID = tenancyOCID
	printStatus(fmt.Sprintf("Tenancy OCID: %s", tenancyOCID))

	// User OCID
	userOCID, err := readOCIConfigValue("user", app.Config.OCIConfigFile, app.Config.OCIProfile)
	if err != nil {
		// Try to get from API for session token auth
		ctx := context.Background()
		req := identity.ListUsersRequest{
			CompartmentId: common.String(tenancyOCID),
			Limit:         common.Int(1),
		}
		resp, err := app.IdentityClient.ListUsers(ctx, req)
		if err == nil && len(resp.Items) > 0 {
			userOCID = *resp.Items[0].Id
		}
	}
	app.OCIConfig.UserOCID = userOCID
	printStatus(fmt.Sprintf("User OCID: %s", userOCID))

	// Region
	region, err := readOCIConfigValue("region", app.Config.OCIConfigFile, app.Config.OCIProfile)
	if err != nil {
		return fmt.Errorf("failed to fetch region: %w", err)
	}
	app.OCIConfig.Region = region
	printStatus(fmt.Sprintf("Region: %s", region))

	// Fingerprint
	fingerprint, err := readOCIConfigValue("fingerprint", app.Config.OCIConfigFile, app.Config.OCIProfile)
	if err != nil {
		app.OCIConfig.Fingerprint = "session_token_auth"
	} else {
		app.OCIConfig.Fingerprint = fingerprint
	}

	printSuccess("OCI configuration values fetched")
	return nil
}

// Fetch availability domains
func (app *App) fetchAvailabilityDomains() error {
	printStatus("Fetching availability domains...")

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(app.Config.OCIConnectionTimeout)*time.Second)
	defer cancel()

	req := identity.ListAvailabilityDomainsRequest{
		CompartmentId: common.String(app.OCIConfig.TenancyOCID),
	}

	resp, err := app.IdentityClient.ListAvailabilityDomains(ctx, req)
	if err != nil {
		return fmt.Errorf("failed to fetch availability domains: %w", err)
	}

	if len(resp.Items) == 0 {
		return fmt.Errorf("no availability domains found")
	}

	app.OCIConfig.AvailabilityDomain = *resp.Items[0].Name
	printSuccess(fmt.Sprintf("Availability domain: %s", app.OCIConfig.AvailabilityDomain))
	return nil
}

// Fetch Ubuntu images
func (app *App) fetchUbuntuImages() error {
	printStatus(fmt.Sprintf("Fetching Ubuntu images for region %s...", app.OCIConfig.Region))

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(app.Config.OCIReadTimeout)*time.Second)
	defer cancel()

	// Fetch x86 (AMD64) Ubuntu image
	printStatus("  Looking for x86 Ubuntu image...")
	x86Req := core.ListImagesRequest{
		CompartmentId:          common.String(app.OCIConfig.TenancyOCID),
		OperatingSystem:       common.String("Canonical Ubuntu"),
		Shape:                  common.String(FreeTierAMDShape),
		SortBy:                core.ListImagesSortByTimecreated,
		SortOrder:             core.ListImagesSortOrderDesc,
		Limit:                  common.Int(1),
	}

	x86Resp, err := app.ComputeClient.ListImages(ctx, x86Req)
	if err == nil && len(x86Resp.Items) > 0 {
		app.OCIConfig.UbuntuImageOCID = *x86Resp.Items[0].Id
		printSuccess(fmt.Sprintf("  x86 image: %s", *x86Resp.Items[0].DisplayName))
		printDebug(fmt.Sprintf("  x86 OCID: %s", app.OCIConfig.UbuntuImageOCID), app)
	} else {
		printWarning("  No x86 Ubuntu image found - AMD instances disabled")
		app.OCIConfig.UbuntuImageOCID = ""
	}

	// Fetch ARM Ubuntu image
	printStatus("  Looking for ARM Ubuntu image...")
	armReq := core.ListImagesRequest{
		CompartmentId:          common.String(app.OCIConfig.TenancyOCID),
		OperatingSystem:       common.String("Canonical Ubuntu"),
		Shape:                  common.String(FreeTierARMShape),
		SortBy:                core.ListImagesSortByTimecreated,
		SortOrder:             core.ListImagesSortOrderDesc,
		Limit:                  common.Int(1),
	}

	armResp, err := app.ComputeClient.ListImages(ctx, armReq)
	if err == nil && len(armResp.Items) > 0 {
		app.OCIConfig.UbuntuARMFlexImageOCID = *armResp.Items[0].Id
		printSuccess(fmt.Sprintf("  ARM image: %s", *armResp.Items[0].DisplayName))
		printDebug(fmt.Sprintf("  ARM OCID: %s", app.OCIConfig.UbuntuARMFlexImageOCID), app)
	} else {
		printWarning("  No ARM Ubuntu image found - ARM instances disabled")
		app.OCIConfig.UbuntuARMFlexImageOCID = ""
	}

	return nil
}

// Setup OCI config with authentication
func (app *App) setupOCIConfig() error {
	printSubheader("OCI Authentication")

	// Initialize clients first to validate config
	if err := app.initializeOCIClients(); err != nil {
		printWarning("Failed to initialize OCI clients, will attempt authentication")
	}

	// Check if config exists and is valid
	if _, err := os.Stat(app.Config.OCIConfigFile); err == nil {
		printStatus("Existing OCI configuration found")
		
		if err := app.validateExistingOCIConfig(); err == nil {
			printSuccess("Existing OCI configuration is valid")
			return nil
		}
		
		printWarning("Existing configuration failed validation")
	}

	// If we get here, need to set up authentication
	if app.Config.NonInteractive {
		return fmt.Errorf("cannot perform interactive authentication in non-interactive mode")
	}

	printStatus("Setting up browser-based authentication...")
	printStatus("This will open a browser window for you to log in to Oracle Cloud.")

	// Run OCI CLI session authenticate
	homeDir, _ := os.UserHomeDir()
	ociDir := filepath.Join(homeDir, ".oci")
	if err := os.MkdirAll(ociDir, 0755); err != nil {
		return fmt.Errorf("failed to create .oci directory: %w", err)
	}

	// Determine region
	authRegion := app.Config.OCIAuthRegion
	if authRegion == "" {
		authRegion = app.defaultRegionForHost()
	}

	printStatus(fmt.Sprintf("Using region '%s' for authentication", authRegion))

	// Execute oci session authenticate
	cmd := exec.Command("oci", "session", "authenticate",
		"--profile-name", app.Config.OCIProfile,
		"--region", authRegion,
		"--session-expiration-in-minutes", "60")

	if isWSL() {
		cmd.Args = append(cmd.Args, "--no-browser")
	}

	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("authentication failed: %w\nOutput: %s", err, string(output))
	}

	// Extract URL if in WSL mode
	if isWSL() {
		outputStr := string(output)
		// Try to extract URL from output
		lines := strings.Split(outputStr, "\n")
		for _, line := range lines {
			if strings.Contains(line, "https://") {
				// Open URL
				openURLBestEffort(line)
				printStatus("After completing browser authentication, press Enter to continue...")
				reader := bufio.NewReader(os.Stdin)
				reader.ReadString('\n')
				break
			}
		}
	}

	// Verify authentication
	if err := app.initializeOCIClients(); err != nil {
		return fmt.Errorf("failed to initialize clients after authentication: %w", err)
	}

	if err := app.testOCIConnectivity(); err != nil {
		return fmt.Errorf("connectivity test failed after authentication: %w", err)
	}

	app.OCIConfig.AuthMethod = "security_token"
	printSuccess("OCI authentication configured successfully")
	return nil
}

// Test OCI connectivity
func (app *App) testOCIConnectivity() error {
	printStatus("Testing OCI API connectivity...")

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(app.Config.OCIConnectionTimeout)*time.Second)
	defer cancel()

	// Try listing regions
	req := identity.ListRegionsRequest{}
	_, err := app.IdentityClient.ListRegions(ctx, req)
	if err == nil {
		printDebug("Connectivity test passed (region list)", app)
		return nil
	}

	// Try getting tenancy
	tenancyReq := identity.GetTenancyRequest{
		TenancyId: common.String(app.OCIConfig.TenancyOCID),
	}
	_, err = app.IdentityClient.GetTenancy(ctx, tenancyReq)
	if err == nil {
		printDebug("Connectivity test passed (tenancy get)", app)
		return nil
	}

	return fmt.Errorf("all connectivity tests failed")
}

// Default region for host
func (app *App) defaultRegionForHost() string {
	// Best-effort heuristic based on timezone
	tz := os.Getenv("TZ")
	if tz == "" {
		// Try to read from /etc/timezone on Linux
		if data, err := os.ReadFile("/etc/timezone"); err == nil {
			tz = strings.TrimSpace(string(data))
		}
	}

	// Map timezones to regions
	if strings.Contains(tz, "Chicago") || strings.Contains(tz, "Central") {
		return "us-chicago-1"
	}
	if strings.Contains(tz, "New_York") || strings.Contains(tz, "Eastern") {
		return "us-ashburn-1"
	}
	if strings.Contains(tz, "Los_Angeles") || strings.Contains(tz, "Pacific") {
		return "us-sanjose-1"
	}
	if strings.Contains(tz, "London") || strings.Contains(tz, "Dublin") {
		return "uk-london-1"
	}
	if strings.Contains(tz, "Paris") || strings.Contains(tz, "Berlin") {
		return "eu-frankfurt-1"
	}
	if strings.Contains(tz, "Tokyo") {
		return "ap-tokyo-1"
	}
	if strings.Contains(tz, "Singapore") {
		return "ap-singapore-1"
	}
	if strings.Contains(tz, "Sydney") || strings.Contains(tz, "Melbourne") {
		return "ap-sydney-1"
	}

	return "us-chicago-1" // Default
}

// Check if running in WSL
func isWSL() bool {
	if runtime.GOOS != "linux" {
		return false
	}
	data, err := os.ReadFile("/proc/version")
	if err != nil {
		return false
	}
	version := strings.ToLower(string(data))
	return strings.Contains(version, "microsoft") || strings.Contains(version, "wsl")
}

// Open URL best effort
func openURLBestEffort(url string) {
	url = strings.TrimSpace(url)
	if url == "" {
		return
	}

	var cmd *exec.Cmd
	if isWSL() {
		// Use PowerShell on Windows
		cmd = exec.Command("powershell.exe", "-NoProfile", "-Command", fmt.Sprintf("Start-Process '%s'", url))
	} else if runtime.GOOS == "linux" {
		cmd = exec.Command("xdg-open", url)
	} else if runtime.GOOS == "darwin" {
		cmd = exec.Command("open", url)
	} else {
		return
	}

	cmd.Run() // Ignore errors
}
