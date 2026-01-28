package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// Load existing configuration from variables.tf
func (app *App) loadExistingConfig() error {
	if _, err := os.Stat("variables.tf"); os.IsNotExist(err) {
		return fmt.Errorf("variables.tf not found")
	}

	printStatus("Loading existing configuration from variables.tf...")

	data, err := os.ReadFile("variables.tf")
	if err != nil {
		return fmt.Errorf("failed to read variables.tf: %w", err)
	}

	content := string(data)

	// Parse AMD instance count
	amdCountRe := regexp.MustCompile(`amd_micro_instance_count\s*=\s*(\d+)`)
	if matches := amdCountRe.FindStringSubmatch(content); len(matches) > 1 {
		if count, err := strconv.Atoi(matches[1]); err == nil {
			app.InstanceConfig.AMDMicroInstanceCount = count
		}
	}

	// Parse ARM instance count
	armCountRe := regexp.MustCompile(`arm_flex_instance_count\s*=\s*(\d+)`)
	if matches := armCountRe.FindStringSubmatch(content); len(matches) > 1 {
		if count, err := strconv.Atoi(matches[1]); err == nil {
			app.InstanceConfig.ARMFlexInstanceCount = count
		}
	}

	// Parse hostnames (simplified - would need more robust parsing)
	amdHostnamesRe := regexp.MustCompile(`amd_micro_hostnames\s*=\s*\[([^\]]+)\]`)
	if matches := amdHostnamesRe.FindStringSubmatch(content); len(matches) > 1 {
		hostnamesStr := strings.TrimSpace(matches[1])
		hostnames := strings.Split(hostnamesStr, ",")
		for _, h := range hostnames {
			h = strings.Trim(strings.TrimSpace(h), "\"")
			if h != "" {
				app.InstanceConfig.AMDMicroHostnames = append(app.InstanceConfig.AMDMicroHostnames, h)
			}
		}
	}

	armHostnamesRe := regexp.MustCompile(`arm_flex_hostnames\s*=\s*\[([^\]]+)\]`)
	if matches := armHostnamesRe.FindStringSubmatch(content); len(matches) > 1 {
		hostnamesStr := strings.TrimSpace(matches[1])
		hostnames := strings.Split(hostnamesStr, ",")
		for _, h := range hostnames {
			h = strings.Trim(strings.TrimSpace(h), "\"")
			if h != "" {
				app.InstanceConfig.ARMFlexHostnames = append(app.InstanceConfig.ARMFlexHostnames, h)
			}
		}
	}

	printSuccess(fmt.Sprintf("Loaded configuration: %dx AMD, %dx ARM", 
		app.InstanceConfig.AMDMicroInstanceCount, app.InstanceConfig.ARMFlexInstanceCount))
	return nil
}

// Configure from existing instances
func (app *App) configureFromExistingInstances() {
	printStatus("Configuring based on existing instances...")

	// Use existing AMD instances
	app.InstanceConfig.AMDMicroInstanceCount = len(app.Resources.AMDInstances)
	app.InstanceConfig.AMDMicroHostnames = []string{}

	for _, instance := range app.Resources.AMDInstances {
		app.InstanceConfig.AMDMicroHostnames = append(app.InstanceConfig.AMDMicroHostnames, instance.Name)
	}

	// Use existing ARM instances
	app.InstanceConfig.ARMFlexInstanceCount = len(app.Resources.ARMInstances)
	app.InstanceConfig.ARMFlexHostnames = []string{}
	app.InstanceConfig.ARMFlexOCPUsPerInstance = []int{}
	app.InstanceConfig.ARMFlexMemoryPerInstance = []int{}
	app.InstanceConfig.ARMFlexBootVolumeSizeGB = []int{}

	for _, instance := range app.Resources.ARMInstances {
		app.InstanceConfig.ARMFlexHostnames = append(app.InstanceConfig.ARMFlexHostnames, instance.Name)
		app.InstanceConfig.ARMFlexOCPUsPerInstance = append(app.InstanceConfig.ARMFlexOCPUsPerInstance, instance.OCPUs)
		app.InstanceConfig.ARMFlexMemoryPerInstance = append(app.InstanceConfig.ARMFlexMemoryPerInstance, instance.Memory)
		app.InstanceConfig.ARMFlexBootVolumeSizeGB = append(app.InstanceConfig.ARMFlexBootVolumeSizeGB, 50) // Default
	}

	// Set defaults if no instances exist
	if app.InstanceConfig.AMDMicroInstanceCount == 0 && app.InstanceConfig.ARMFlexInstanceCount == 0 {
		printStatus("No existing instances found, using default configuration")
		app.InstanceConfig.AMDMicroInstanceCount = 0
		app.InstanceConfig.ARMFlexInstanceCount = 1
		app.InstanceConfig.ARMFlexOCPUsPerInstance = []int{4}
		app.InstanceConfig.ARMFlexMemoryPerInstance = []int{24}
		app.InstanceConfig.ARMFlexBootVolumeSizeGB = []int{200}
		app.InstanceConfig.ARMFlexHostnames = []string{"arm-instance-1"}
		app.InstanceConfig.ARMFlexBlockVolumes = []int{0}
	}

	app.InstanceConfig.AMDMicroBootVolumeSizeGB = 50

	printSuccess(fmt.Sprintf("Configuration: %dx AMD, %dx ARM", 
		app.InstanceConfig.AMDMicroInstanceCount, app.InstanceConfig.ARMFlexInstanceCount))
}

// Calculate available resources
func (app *App) calculateAvailableResources() (int, int, int, int) {
	usedAMD := len(app.Resources.AMDInstances)
	usedARMOCPUs := 0
	usedARMMemory := 0
	usedStorage := 0

	for _, instance := range app.Resources.ARMInstances {
		usedARMOCPUs += instance.OCPUs
		usedARMMemory += instance.Memory
	}

	for _, boot := range app.Resources.BootVolumes {
		usedStorage += boot.Size
	}

	for _, block := range app.Resources.BlockVolumes {
		usedStorage += block.Size
	}

	availableAMD := FreeTierMaxAMDInstances - usedAMD
	availableARMOCPUs := FreeTierMaxARMOCPUs - usedARMOCPUs
	availableARMMemory := FreeTierMaxARMMemoryGB - usedARMMemory
	availableStorage := FreeTierMaxStorageGB - usedStorage

	return availableAMD, availableARMOCPUs, availableARMMemory, availableStorage
}

// Prompt configuration
func (app *App) promptConfiguration() error {
	printHeader("INSTANCE CONFIGURATION")

	availableAMD, availableARMOCPUs, availableARMMemory, availableStorage := app.calculateAvailableResources()

	fmt.Println("\033[1mAvailable Free Tier Resources:\033[0m")
	fmt.Printf("  • AMD instances:  %d available (max %d)\n", availableAMD, FreeTierMaxAMDInstances)
	fmt.Printf("  • ARM OCPUs:      %d available (max %d)\n", availableARMOCPUs, FreeTierMaxARMOCPUs)
	fmt.Printf("  • ARM Memory:     %dGB available (max %dGB)\n", availableARMMemory, FreeTierMaxARMMemoryGB)
	fmt.Printf("  • Storage:        %dGB available (max %dGB)\n", availableStorage, FreeTierMaxStorageGB)
	fmt.Println()

	// Check if we have existing config
	hasExistingConfig := false
	if err := app.loadExistingConfig(); err == nil {
		hasExistingConfig = true
	}

	printStatus("Configuration options:")
	fmt.Println("  1) Use existing instances (manage what's already deployed)")
	if hasExistingConfig {
		fmt.Println("  2) Use saved configuration from variables.tf")
	} else {
		fmt.Println("  2) Use saved configuration from variables.tf (not available)")
	}
	fmt.Println("  3) Configure new instances (respecting Free Tier limits)")
	fmt.Println("  4) Maximum Free Tier configuration (use all available resources)")
	fmt.Println()

	var choice int
	if app.Config.AutoUseExisting || app.Config.NonInteractive {
		choice = 1
		printStatus("Auto mode: Using existing instances")
	} else {
		choiceStr := promptWithDefault("Choose configuration (1-4)", "1")
		var err error
		choice, err = strconv.Atoi(choiceStr)
		if err != nil || choice < 1 || choice > 4 {
			choice = 1
		}
	}

	switch choice {
	case 1:
		app.configureFromExistingInstances()
	case 2:
		if hasExistingConfig {
			printSuccess("Using saved configuration")
		} else {
			printError("No saved configuration available")
			app.configureFromExistingInstances()
		}
	case 3:
		app.configureCustomInstances(availableAMD, availableARMOCPUs, availableARMMemory, availableStorage)
	case 4:
		app.configureMaximumFreeTier(availableAMD, availableARMOCPUs, availableARMMemory, availableStorage)
	default:
		app.configureFromExistingInstances()
	}

	return nil
}

// Configure custom instances
func (app *App) configureCustomInstances(availableAMD, availableARMOCPUs, availableARMMemory, availableStorage int) {
	printStatus("Custom instance configuration...")

	// AMD instances
	if availableAMD > 0 && !app.Config.NonInteractive {
		count, err := promptIntRange(fmt.Sprintf("Number of AMD instances (0-%d)", availableAMD), "0", 0, availableAMD)
		if err == nil {
			app.InstanceConfig.AMDMicroInstanceCount = count
		}
	} else {
		app.InstanceConfig.AMDMicroInstanceCount = 0
	}

	app.InstanceConfig.AMDMicroHostnames = []string{}
	if app.InstanceConfig.AMDMicroInstanceCount > 0 {
		app.InstanceConfig.AMDMicroBootVolumeSizeGB = 50
		for i := 1; i <= app.InstanceConfig.AMDMicroInstanceCount; i++ {
			hostname := fmt.Sprintf("amd-instance-%d", i)
			if !app.Config.NonInteractive {
				hostname = promptWithDefault(fmt.Sprintf("Hostname for AMD instance %d", i), hostname)
			}
			app.InstanceConfig.AMDMicroHostnames = append(app.InstanceConfig.AMDMicroHostnames, hostname)
		}
	}

	// ARM instances
	if app.OCIConfig.UbuntuARMFlexImageOCID != "" && availableARMOCPUs > 0 {
		if !app.Config.NonInteractive {
			count, err := promptIntRange("Number of ARM instances (0-4)", "1", 0, 4)
			if err == nil {
				app.InstanceConfig.ARMFlexInstanceCount = count
			} else {
				app.InstanceConfig.ARMFlexInstanceCount = 1
			}
		} else {
			app.InstanceConfig.ARMFlexInstanceCount = 1
		}

		app.InstanceConfig.ARMFlexHostnames = []string{}
		app.InstanceConfig.ARMFlexOCPUsPerInstance = []int{}
		app.InstanceConfig.ARMFlexMemoryPerInstance = []int{}
		app.InstanceConfig.ARMFlexBootVolumeSizeGB = []int{}
		app.InstanceConfig.ARMFlexBlockVolumes = []int{}

		remainingOCPUs := availableARMOCPUs
		remainingMemory := availableARMMemory

		for i := 1; i <= app.InstanceConfig.ARMFlexInstanceCount; i++ {
			hostname := fmt.Sprintf("arm-instance-%d", i)
			if !app.Config.NonInteractive {
				hostname = promptWithDefault(fmt.Sprintf("Hostname for ARM instance %d", i), hostname)
			}
			app.InstanceConfig.ARMFlexHostnames = append(app.InstanceConfig.ARMFlexHostnames, hostname)

			ocpus := remainingOCPUs
			if !app.Config.NonInteractive {
				ocpus, _ = promptIntRange(fmt.Sprintf("  OCPUs (1-%d)", remainingOCPUs), 
					fmt.Sprintf("%d", remainingOCPUs), 1, remainingOCPUs)
			}
			app.InstanceConfig.ARMFlexOCPUsPerInstance = append(app.InstanceConfig.ARMFlexOCPUsPerInstance, ocpus)
			remainingOCPUs -= ocpus

			maxMemory := ocpus * 6
			if maxMemory > remainingMemory {
				maxMemory = remainingMemory
			}
			memory := maxMemory
			if !app.Config.NonInteractive {
				memory, _ = promptIntRange(fmt.Sprintf("  Memory GB (1-%d)", maxMemory), 
					fmt.Sprintf("%d", maxMemory), 1, maxMemory)
			}
			app.InstanceConfig.ARMFlexMemoryPerInstance = append(app.InstanceConfig.ARMFlexMemoryPerInstance, memory)
			remainingMemory -= memory

			boot := 50
			if !app.Config.NonInteractive {
				boot, _ = promptIntRange("  Boot volume GB (50-200)", "50", 50, 200)
			}
			app.InstanceConfig.ARMFlexBootVolumeSizeGB = append(app.InstanceConfig.ARMFlexBootVolumeSizeGB, boot)
			app.InstanceConfig.ARMFlexBlockVolumes = append(app.InstanceConfig.ARMFlexBlockVolumes, 0)
		}
	} else {
		app.InstanceConfig.ARMFlexInstanceCount = 0
	}
}

// Configure maximum free tier
func (app *App) configureMaximumFreeTier(availableAMD, availableARMOCPUs, availableARMMemory, availableStorage int) {
	printStatus("Configuring maximum Free Tier utilization...")

	// Use all available AMD instances
	app.InstanceConfig.AMDMicroInstanceCount = availableAMD
	app.InstanceConfig.AMDMicroBootVolumeSizeGB = 50
	app.InstanceConfig.AMDMicroHostnames = []string{}
	for i := 1; i <= app.InstanceConfig.AMDMicroInstanceCount; i++ {
		app.InstanceConfig.AMDMicroHostnames = append(app.InstanceConfig.AMDMicroHostnames, fmt.Sprintf("amd-instance-%d", i))
	}

	// Use all available ARM resources
	if app.OCIConfig.UbuntuARMFlexImageOCID != "" && availableARMOCPUs > 0 {
		app.InstanceConfig.ARMFlexInstanceCount = 1
		app.InstanceConfig.ARMFlexOCPUsPerInstance = []int{availableARMOCPUs}
		app.InstanceConfig.ARMFlexMemoryPerInstance = []int{availableARMMemory}

		// Calculate boot volume size to use remaining storage
		usedByAMD := app.InstanceConfig.AMDMicroInstanceCount * app.InstanceConfig.AMDMicroBootVolumeSizeGB
		remainingStorage := availableStorage - usedByAMD
		if remainingStorage < FreeTierMinBootVolumeGB {
			remainingStorage = FreeTierMinBootVolumeGB
		}

		app.InstanceConfig.ARMFlexBootVolumeSizeGB = []int{remainingStorage}
		app.InstanceConfig.ARMFlexHostnames = []string{"arm-instance-1"}
		app.InstanceConfig.ARMFlexBlockVolumes = []int{0}
	} else {
		app.InstanceConfig.ARMFlexInstanceCount = 0
	}

	printSuccess(fmt.Sprintf("Maximum config: %dx AMD, %dx ARM (%d OCPUs, %dGB)", 
		app.InstanceConfig.AMDMicroInstanceCount, app.InstanceConfig.ARMFlexInstanceCount,
		availableARMOCPUs, availableARMMemory))
}
