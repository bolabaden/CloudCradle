package main

import (
	"context"
	"fmt"
	"time"

	"github.com/oracle/oci-go-sdk/v65/common"
	"github.com/oracle/oci-go-sdk/v65/core"
)

// Initialize resources maps
func (app *App) initResources() {
	app.Resources = &ExistingResources{
		VCNs:             make(map[string]VCNInfo),
		Subnets:          make(map[string]SubnetInfo),
		InternetGateways: make(map[string]IGInfo),
		RouteTables:      make(map[string]RTInfo),
		SecurityLists:    make(map[string]SLInfo),
		AMDInstances:     make(map[string]InstanceInfo),
		ARMInstances:     make(map[string]InstanceInfo),
		BootVolumes:      make(map[string]VolumeInfo),
		BlockVolumes:     make(map[string]VolumeInfo),
	}
}

// Inventory all resources
func (app *App) inventoryAllResources() error {
	printHeader("COMPREHENSIVE RESOURCE INVENTORY")
	printStatus("Scanning all existing OCI resources in tenancy...")
	printStatus("This ensures we never create duplicate resources.")
	fmt.Println()

	if err := app.inventoryComputeInstances(); err != nil {
		return fmt.Errorf("compute inventory failed: %w", err)
	}

	if err := app.inventoryNetworkingResources(); err != nil {
		return fmt.Errorf("networking inventory failed: %w", err)
	}

	if err := app.inventoryStorageResources(); err != nil {
		return fmt.Errorf("storage inventory failed: %w", err)
	}

	app.displayResourceInventory()
	return nil
}

// Inventory compute instances
func (app *App) inventoryComputeInstances() error {
	printStatus("Inventorying compute instances...")

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(app.Config.OCIReadTimeout)*time.Second)
	defer cancel()

	req := core.ListInstancesRequest{
		CompartmentId: common.String(app.OCIConfig.TenancyOCID),
	}

	resp, err := app.ComputeClient.ListInstances(ctx, req)
	if err != nil {
		return fmt.Errorf("failed to list instances: %w", err)
	}

	app.Resources.AMDInstances = make(map[string]InstanceInfo)
	app.Resources.ARMInstances = make(map[string]InstanceInfo)

	for _, instance := range resp.Items {
		// Skip terminated instances
		if instance.LifecycleState == core.InstanceLifecycleStateTerminated {
			continue
		}

		instanceID := *instance.Id
		instanceName := *instance.DisplayName
		state := string(instance.LifecycleState)
		shape := *instance.Shape

		// Get VNIC information for IP addresses
		vnicReq := core.ListVnicAttachmentsRequest{
			CompartmentId: common.String(app.OCIConfig.TenancyOCID),
			InstanceId:    common.String(instanceID),
		}

		var publicIP, privateIP string
		vnicResp, err := app.VirtualNetworkClient.ListVnicAttachments(ctx, vnicReq)
		if err == nil && len(vnicResp.Items) > 0 {
			vnicID := *vnicResp.Items[0].VnicId
			vnicGetReq := core.GetVnicRequest{VnicId: common.String(vnicID)}
			vnicDetails, err := app.VirtualNetworkClient.GetVnic(ctx, vnicGetReq)
			if err == nil {
				if vnicDetails.PublicIp != nil {
					publicIP = *vnicDetails.PublicIp
				}
				if vnicDetails.PrivateIp != nil {
					privateIP = *vnicDetails.PrivateIp
				}
			}
		}

		// Categorize by shape
		if shape == FreeTierAMDShape {
			info := InstanceInfo{
				Name:      instanceName,
				State:     state,
				Shape:     shape,
				PublicIP:  publicIP,
				PrivateIP: privateIP,
			}
			app.Resources.AMDInstances[instanceID] = info
			printStatus(fmt.Sprintf("  Found AMD instance: %s (%s) - IP: %s", instanceName, state, publicIP))
		} else if shape == FreeTierARMShape {
			// Get shape config for ARM instances
			instanceReq := core.GetInstanceRequest{InstanceId: common.String(instanceID)}
			instanceDetails, err := app.ComputeClient.GetInstance(ctx, instanceReq)
			var ocpus, memory int
			if err == nil && instanceDetails.ShapeConfig != nil {
				if instanceDetails.ShapeConfig.Ocpus != nil {
					ocpus = int(*instanceDetails.ShapeConfig.Ocpus)
				}
				if instanceDetails.ShapeConfig.MemoryInGBs != nil {
					memory = int(*instanceDetails.ShapeConfig.MemoryInGBs)
				}
			}

			info := InstanceInfo{
				Name:      instanceName,
				State:     state,
				Shape:     shape,
				PublicIP:  publicIP,
				PrivateIP: privateIP,
				OCPUs:     ocpus,
				Memory:    memory,
			}
			app.Resources.ARMInstances[instanceID] = info
			printStatus(fmt.Sprintf("  Found ARM instance: %s (%s, %dOCPUs, %dGB) - IP: %s", instanceName, state, ocpus, memory, publicIP))
		} else {
			printDebug(fmt.Sprintf("  Found non-free-tier instance: %s (%s)", instanceName, shape), app)
		}
	}

	printStatus(fmt.Sprintf("  AMD instances: %d/%d", len(app.Resources.AMDInstances), FreeTierMaxAMDInstances))
	printStatus(fmt.Sprintf("  ARM instances: %d/%d", len(app.Resources.ARMInstances), FreeTierMaxARMInstances))
	return nil
}

// Inventory networking resources
func (app *App) inventoryNetworkingResources() error {
	printStatus("Inventorying networking resources...")

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(app.Config.OCIReadTimeout)*time.Second)
	defer cancel()

	// Get VCNs
	vcnReq := core.ListVcnsRequest{
		CompartmentId: common.String(app.OCIConfig.TenancyOCID),
	}

	vcnResp, err := app.VirtualNetworkClient.ListVcns(ctx, vcnReq)
	if err != nil {
		return fmt.Errorf("failed to list VCNs: %w", err)
	}

	app.Resources.VCNs = make(map[string]VCNInfo)
	app.Resources.Subnets = make(map[string]SubnetInfo)
	app.Resources.InternetGateways = make(map[string]IGInfo)
	app.Resources.RouteTables = make(map[string]RTInfo)
	app.Resources.SecurityLists = make(map[string]SLInfo)

	for _, vcn := range vcnResp.Items {
		if vcn.LifecycleState != core.VcnLifecycleStateAvailable {
			continue
		}

		vcnID := *vcn.Id
		vcnName := *vcn.DisplayName
		vcnCIDR := ""
		if len(vcn.CidrBlocks) > 0 {
			vcnCIDR = vcn.CidrBlocks[0]
		}

		app.Resources.VCNs[vcnID] = VCNInfo{
			Name: vcnName,
			CIDR: vcnCIDR,
		}
		printStatus(fmt.Sprintf("  Found VCN: %s (%s)", vcnName, vcnCIDR))

		// Get subnets for this VCN
		subnetReq := core.ListSubnetsRequest{
			CompartmentId: common.String(app.OCIConfig.TenancyOCID),
			VcnId:         common.String(vcnID),
		}

		subnetResp, err := app.VirtualNetworkClient.ListSubnets(ctx, subnetReq)
		if err == nil {
			for _, subnet := range subnetResp.Items {
				if subnet.LifecycleState == core.SubnetLifecycleStateAvailable {
					subnetID := *subnet.Id
					subnetName := *subnet.DisplayName
					subnetCIDR := *subnet.CidrBlock

					app.Resources.Subnets[subnetID] = SubnetInfo{
						Name:  subnetName,
						CIDR:  subnetCIDR,
						VCNID: vcnID,
					}
					printDebug(fmt.Sprintf("    Subnet: %s (%s)", subnetName, subnetCIDR), app)
				}
			}
		}

		// Get internet gateways
		igReq := core.ListInternetGatewaysRequest{
			CompartmentId: common.String(app.OCIConfig.TenancyOCID),
			VcnId:         common.String(vcnID),
		}

		igResp, err := app.VirtualNetworkClient.ListInternetGateways(ctx, igReq)
		if err == nil {
			for _, ig := range igResp.Items {
				if ig.LifecycleState == core.InternetGatewayLifecycleStateAvailable {
					igID := *ig.Id
					igName := *ig.DisplayName

					app.Resources.InternetGateways[igID] = IGInfo{
						Name:  igName,
						VCNID: vcnID,
					}
				}
			}
		}

		// Get route tables
		rtReq := core.ListRouteTablesRequest{
			CompartmentId: common.String(app.OCIConfig.TenancyOCID),
			VcnId:         common.String(vcnID),
		}

		rtResp, err := app.VirtualNetworkClient.ListRouteTables(ctx, rtReq)
		if err == nil {
			for _, rt := range rtResp.Items {
				rtID := *rt.Id
				rtName := *rt.DisplayName

				app.Resources.RouteTables[rtID] = RTInfo{
					Name:  rtName,
					VCNID: vcnID,
				}
			}
		}

		// Get security lists
		slReq := core.ListSecurityListsRequest{
			CompartmentId: common.String(app.OCIConfig.TenancyOCID),
			VcnId:         common.String(vcnID),
		}

		slResp, err := app.VirtualNetworkClient.ListSecurityLists(ctx, slReq)
		if err == nil {
			for _, sl := range slResp.Items {
				slID := *sl.Id
				slName := *sl.DisplayName

				app.Resources.SecurityLists[slID] = SLInfo{
					Name:  slName,
					VCNID: vcnID,
				}
			}
		}
	}

	printStatus(fmt.Sprintf("  VCNs: %d/%d", len(app.Resources.VCNs), FreeTierMaxVCNs))
	printStatus(fmt.Sprintf("  Subnets: %d", len(app.Resources.Subnets)))
	printStatus(fmt.Sprintf("  Internet Gateways: %d", len(app.Resources.InternetGateways)))
	return nil
}

// Inventory storage resources
func (app *App) inventoryStorageResources() error {
	printStatus("Inventorying storage resources...")

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(app.Config.OCIReadTimeout)*time.Second)
	defer cancel()

	// Get boot volumes
	bootReq := core.ListBootVolumesRequest{
		CompartmentId:      common.String(app.OCIConfig.TenancyOCID),
		AvailabilityDomain: common.String(app.OCIConfig.AvailabilityDomain),
	}

	bootResp, err := app.BlockStorageClient.ListBootVolumes(ctx, bootReq)
	if err != nil {
		return fmt.Errorf("failed to list boot volumes: %w", err)
	}

	app.Resources.BootVolumes = make(map[string]VolumeInfo)
	totalBootGB := 0

	for _, boot := range bootResp.Items {
		if boot.LifecycleState == core.BootVolumeLifecycleStateAvailable {
			bootID := *boot.Id
			bootName := *boot.DisplayName
			bootSize := int(*boot.SizeInGBs)

			app.Resources.BootVolumes[bootID] = VolumeInfo{
				Name: bootName,
				Size: bootSize,
			}
			totalBootGB += bootSize
		}
	}

	// Get block volumes
	blockReq := core.ListVolumesRequest{
		CompartmentId:      common.String(app.OCIConfig.TenancyOCID),
		AvailabilityDomain: common.String(app.OCIConfig.AvailabilityDomain),
	}

	blockResp, err := app.BlockStorageClient.ListVolumes(ctx, blockReq)
	if err != nil {
		return fmt.Errorf("failed to list block volumes: %w", err)
	}

	app.Resources.BlockVolumes = make(map[string]VolumeInfo)
	totalBlockGB := 0

	for _, block := range blockResp.Items {
		if block.LifecycleState == core.VolumeLifecycleStateAvailable {
			blockID := *block.Id
			blockName := *block.DisplayName
			blockSize := int(*block.SizeInGBs)

			app.Resources.BlockVolumes[blockID] = VolumeInfo{
				Name: blockName,
				Size: blockSize,
			}
			totalBlockGB += blockSize
		}
	}

	totalStorage := totalBootGB + totalBlockGB

	printStatus(fmt.Sprintf("  Boot volumes: %d (%dGB)", len(app.Resources.BootVolumes), totalBootGB))
	printStatus(fmt.Sprintf("  Block volumes: %d (%dGB)", len(app.Resources.BlockVolumes), totalBlockGB))
	printStatus(fmt.Sprintf("  Total storage: %dGB/%dGB", totalStorage, FreeTierMaxStorageGB))
	return nil
}

// Display resource inventory summary
func (app *App) displayResourceInventory() {
	fmt.Println()
	printHeader("RESOURCE INVENTORY SUMMARY")

	// Calculate totals
	totalAMD := len(app.Resources.AMDInstances)
	totalARM := len(app.Resources.ARMInstances)
	totalARMOCPUs := 0
	totalARMMemory := 0

	for _, instance := range app.Resources.ARMInstances {
		totalARMOCPUs += instance.OCPUs
		totalARMMemory += instance.Memory
	}

	totalBootGB := 0
	for _, boot := range app.Resources.BootVolumes {
		totalBootGB += boot.Size
	}

	totalBlockGB := 0
	for _, block := range app.Resources.BlockVolumes {
		totalBlockGB += block.Size
	}

	totalStorage := totalBootGB + totalBlockGB

	fmt.Println("\033[1mCompute Resources:\033[0m")
	fmt.Printf("  ┌─────────────────────────────────────────────────────────────┐\n")
	fmt.Printf("  │ AMD Micro Instances:  %2d / %2d (Free Tier limit)          │\n", totalAMD, FreeTierMaxAMDInstances)
	fmt.Printf("  │ ARM A1 Instances:     %2d / %2d (up to)                    │\n", totalARM, FreeTierMaxARMInstances)
	fmt.Printf("  │ ARM OCPUs Used:       %2d / %2d                           │\n", totalARMOCPUs, FreeTierMaxARMOCPUs)
	fmt.Printf("  │ ARM Memory Used:      %2dGB / %2dGB                         │\n", totalARMMemory, FreeTierMaxARMMemoryGB)
	fmt.Printf("  └─────────────────────────────────────────────────────────────┘\n")
	fmt.Println()

	fmt.Println("\033[1mStorage Resources:\033[0m")
	fmt.Printf("  ┌─────────────────────────────────────────────────────────────┐\n")
	fmt.Printf("  │ Boot Volumes:         %3dGB                                    │\n", totalBootGB)
	fmt.Printf("  │ Block Volumes:        %3dGB                                    │\n", totalBlockGB)
	fmt.Printf("  │ Total Storage:        %3dGB / %3dGB Free Tier limit          │\n", totalStorage, FreeTierMaxStorageGB)
	fmt.Printf("  └─────────────────────────────────────────────────────────────┘\n")
	fmt.Println()

	fmt.Println("\033[1mNetworking Resources:\033[0m")
	fmt.Printf("  ┌─────────────────────────────────────────────────────────────┐\n")
	fmt.Printf("  │ VCNs:                 %2d / %2d (Free Tier limit)             │\n", len(app.Resources.VCNs), FreeTierMaxVCNs)
	fmt.Printf("  │ Subnets:              %2d                                       │\n", len(app.Resources.Subnets))
	fmt.Printf("  │ Internet Gateways:    %2d                                       │\n", len(app.Resources.InternetGateways))
	fmt.Printf("  └─────────────────────────────────────────────────────────────┘\n")
	fmt.Println()

	// Warnings for near-limit resources
	if totalAMD >= FreeTierMaxAMDInstances {
		printWarning("AMD instance limit reached - cannot create more AMD instances")
	}
	if totalARMOCPUs >= FreeTierMaxARMOCPUs {
		printWarning("ARM OCPU limit reached - cannot allocate more ARM OCPUs")
	}
	if totalARMMemory >= FreeTierMaxARMMemoryGB {
		printWarning("ARM memory limit reached - cannot allocate more ARM memory")
	}
	if totalStorage >= FreeTierMaxStorageGB {
		printWarning("Storage limit reached - cannot create more volumes")
	}
	if len(app.Resources.VCNs) >= FreeTierMaxVCNs {
		printWarning("VCN limit reached - cannot create more VCNs")
	}
}
