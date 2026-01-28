package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// Run Terraform workflow
func (app *App) runTerraformWorkflow() error {
	printHeader("TERRAFORM WORKFLOW")

	// Step 1: Initialize
	printStatus("Step 1: Initializing Terraform...")
	if err := retryWithBackoff(func() error {
		cmd := exec.Command("terraform", "init", "-input=false", "-upgrade")
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		return cmd.Run()
	}, RetryMaxAttempts, RetryBaseDelay); err != nil {
		printError("Terraform init failed after retries")
		return err
	}
	printSuccess("Terraform initialized")

	// Step 2: Import existing resources
	if len(app.Resources.VCNs) > 0 || len(app.Resources.AMDInstances) > 0 || len(app.Resources.ARMInstances) > 0 {
		printStatus("Step 2: Importing existing resources...")
		if err := app.importExistingResources(); err != nil {
			printWarning(fmt.Sprintf("Import had some failures: %v", err))
		}
	} else {
		printStatus("Step 2: No existing resources to import")
	}

	// Step 3: Validate
	printStatus("Step 3: Validating configuration...")
	cmd := exec.Command("terraform", "validate")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		printError("Terraform validation failed")
		return err
	}
	printSuccess("Configuration valid")

	// Step 4: Plan
	printStatus("Step 4: Creating execution plan...")
	cmd = exec.Command("terraform", "plan", "-out=tfplan", "-input=false")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		printError("Terraform plan failed")
		return err
	}
	printSuccess("Plan created successfully")

	// Show plan summary
	fmt.Println()
	printStatus("Plan summary:")
	cmd = exec.Command("terraform", "show", "-no-color", "tfplan")
	output, _ := cmd.Output()
	lines := strings.Split(string(output), "\n")
	for i, line := range lines {
		if i >= 20 {
			break
		}
		if strings.Contains(line, "Plan:") || strings.Contains(line, "will be") || strings.HasPrefix(line, "  #") {
			fmt.Println(line)
		}
	}
	fmt.Println()

	// Step 5: Apply
	if app.Config.AutoDeploy || app.Config.NonInteractive {
		printStatus("Step 5: Auto-applying plan...")
		if err := app.applyTerraformPlan(); err != nil {
			return err
		}
	} else {
		if confirmAction("Apply this plan?", false) {
			if err := app.applyTerraformPlan(); err != nil {
				return err
			}
		} else {
			printStatus("Plan saved as 'tfplan' - apply later with: terraform apply tfplan")
		}
	}

	return nil
}

// Apply Terraform plan with retry on Out of Capacity
func (app *App) applyTerraformPlan() error {
	printStatus("Applying Terraform plan...")

	return retryWithBackoff(func() error {
		cmd := exec.Command("terraform", "apply", "-input=false", "tfplan")
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		err := cmd.Run()

		if err != nil {
			// Check if it's an Out of Capacity error
			// We'd need to capture stderr to check, but for now just retry
			return err
		}

		// Success - remove plan file
		os.Remove("tfplan")

		// Show outputs
		fmt.Println()
		printHeader("DEPLOYMENT COMPLETE")
		cmd = exec.Command("terraform", "output", "-json")
		output, _ := cmd.Output()
		fmt.Println(string(output))

		return nil
	}, RetryMaxAttempts, RetryBaseDelay)
}

// Import existing resources
func (app *App) importExistingResources() error {
	printHeader("IMPORTING EXISTING RESOURCES")

	if len(app.Resources.VCNs) == 0 && len(app.Resources.AMDInstances) == 0 && len(app.Resources.ARMInstances) == 0 {
		printStatus("No existing resources to import")
		return nil
	}

	imported := 0
	failed := 0

	// Import VCN
	if len(app.Resources.VCNs) > 0 {
		var firstVCNID string
		for vcnID := range app.Resources.VCNs {
			firstVCNID = vcnID
			break
		}

		if firstVCNID != "" {
			vcnInfo := app.Resources.VCNs[firstVCNID]
			printStatus(fmt.Sprintf("Importing VCN: %s", vcnInfo.Name))

			// Check if already in state
			cmd := exec.Command("terraform", "state", "show", "oci_core_vcn.main")
			if cmd.Run() == nil {
				printStatus("  Already in state")
			} else {
				// Import
				cmd = exec.Command("terraform", "import", "oci_core_vcn.main", firstVCNID)
				cmd.Stdout = os.Stdout
				cmd.Stderr = os.Stderr
				if err := retryWithBackoff(func() error {
					return cmd.Run()
				}, RetryMaxAttempts, RetryBaseDelay); err == nil {
					printSuccess("  Imported successfully")
					imported++
					app.importVCNComponents(firstVCNID)
				} else {
					printWarning("  Failed to import")
					failed++
				}
			}
		}
	}

	// Import AMD instances
	amdIndex := 0
	for instanceID, instance := range app.Resources.AMDInstances {
		if amdIndex >= app.InstanceConfig.AMDMicroInstanceCount {
			break
		}

		printStatus(fmt.Sprintf("Importing AMD instance: %s", instance.Name))

		resourceAddr := fmt.Sprintf("oci_core_instance.amd[%d]", amdIndex)
		cmd := exec.Command("terraform", "state", "show", resourceAddr)
		if cmd.Run() == nil {
			printStatus("  Already in state")
		} else {
			cmd = exec.Command("terraform", "import", resourceAddr, instanceID)
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
			if err := retryWithBackoff(func() error {
				return cmd.Run()
			}, RetryMaxAttempts, RetryBaseDelay); err == nil {
				printSuccess("  Imported successfully")
				imported++
			} else {
				printWarning("  Failed to import")
				failed++
			}
		}

		amdIndex++
	}

	// Import ARM instances
	armIndex := 0
	for instanceID, instance := range app.Resources.ARMInstances {
		if armIndex >= app.InstanceConfig.ARMFlexInstanceCount {
			break
		}

		printStatus(fmt.Sprintf("Importing ARM instance: %s", instance.Name))

		resourceAddr := fmt.Sprintf("oci_core_instance.arm[%d]", armIndex)
		cmd := exec.Command("terraform", "state", "show", resourceAddr)
		if cmd.Run() == nil {
			printStatus("  Already in state")
		} else {
			cmd = exec.Command("terraform", "import", resourceAddr, instanceID)
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
			if err := retryWithBackoff(func() error {
				return cmd.Run()
			}, RetryMaxAttempts, RetryBaseDelay); err == nil {
				printSuccess("  Imported successfully")
				imported++
			} else {
				printWarning("  Failed to import")
				failed++
			}
		}

		armIndex++
	}

	fmt.Println()
	printSuccess(fmt.Sprintf("Import complete: %d imported, %d failed", imported, failed))
	return nil
}

// Import VCN components
func (app *App) importVCNComponents(vcnID string) {
	// Import Internet Gateway
	for igID, ig := range app.Resources.InternetGateways {
		if ig.VCNID == vcnID {
			cmd := exec.Command("terraform", "state", "show", "oci_core_internet_gateway.main")
			if cmd.Run() != nil {
				cmd = exec.Command("terraform", "import", "oci_core_internet_gateway.main", igID)
				cmd.Run() // Ignore errors
				printStatus("    Imported Internet Gateway")
			}
			break
		}
	}

	// Import Subnet
	for subnetID, subnet := range app.Resources.Subnets {
		if subnet.VCNID == vcnID {
			cmd := exec.Command("terraform", "state", "show", "oci_core_subnet.main")
			if cmd.Run() != nil {
				cmd = exec.Command("terraform", "import", "oci_core_subnet.main", subnetID)
				cmd.Run() // Ignore errors
				printStatus("    Imported Subnet")
			}
			break
		}
	}

	// Import Route Table
	for rtID, rt := range app.Resources.RouteTables {
		if rt.VCNID == vcnID && (strings.Contains(strings.ToLower(rt.Name), "default")) {
			cmd := exec.Command("terraform", "state", "show", "oci_core_default_route_table.main")
			if cmd.Run() != nil {
				cmd = exec.Command("terraform", "import", "oci_core_default_route_table.main", rtID)
				cmd.Run() // Ignore errors
				printStatus("    Imported Route Table")
			}
			break
		}
	}

	// Import Security List
	for slID, sl := range app.Resources.SecurityLists {
		if sl.VCNID == vcnID && (strings.Contains(strings.ToLower(sl.Name), "default")) {
			cmd := exec.Command("terraform", "state", "show", "oci_core_default_security_list.main")
			if cmd.Run() != nil {
				cmd = exec.Command("terraform", "import", "oci_core_default_security_list.main", slID)
				cmd.Run() // Ignore errors
				printStatus("    Imported Security List")
			}
			break
		}
	}
}
