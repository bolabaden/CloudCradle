package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

// Install prerequisites
func (app *App) installPrerequisites() error {
	printSubheader("Installing Prerequisites")

	// Check for required commands
	requiredCommands := []string{"jq", "curl", "terraform", "oci"}
	missingCommands := []string{}

	for _, cmd := range requiredCommands {
		if !commandExists(cmd) {
			missingCommands = append(missingCommands, cmd)
		}
	}

	if len(missingCommands) > 0 {
		printWarning(fmt.Sprintf("Missing commands: %s", strings.Join(missingCommands, ", ")))
		printStatus("Please install missing commands before continuing")
		// On Linux, we could try to install, but for cross-platform, just warn
	}

	printSuccess("All prerequisites installed")
	return nil
}

// Check if command exists
func commandExists(cmd string) bool {
	_, err := exec.LookPath(cmd)
	return err == nil
}

// Generate SSH keys
func (app *App) generateSSHKeys() error {
	printStatus("Setting up SSH keys...")

	sshDir := filepath.Join(".", "ssh_keys")
	if err := os.MkdirAll(sshDir, 0700); err != nil {
		return fmt.Errorf("failed to create ssh_keys directory: %w", err)
	}

	privateKeyPath := filepath.Join(sshDir, "id_rsa")
	publicKeyPath := filepath.Join(sshDir, "id_rsa.pub")

	// Check if keys already exist
	if _, err := os.Stat(privateKeyPath); err == nil {
		printStatus("Using existing SSH key pair")
		// Read public key
		publicKeyData, err := os.ReadFile(publicKeyPath)
		if err == nil {
			app.OCIConfig.SSHPublicKey = strings.TrimSpace(string(publicKeyData))
		}
		return nil
	}

	printStatus("Generating new SSH key pair...")

	// Generate private key
	privateKey, err := rsa.GenerateKey(rand.Reader, 4096)
	if err != nil {
		return fmt.Errorf("failed to generate private key: %w", err)
	}

	// Encode private key to PEM
	privateKeyPEM := &pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(privateKey),
	}

	privateKeyFile, err := os.OpenFile(privateKeyPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return fmt.Errorf("failed to create private key file: %w", err)
	}
	defer privateKeyFile.Close()

	if err := pem.Encode(privateKeyFile, privateKeyPEM); err != nil {
		return fmt.Errorf("failed to encode private key: %w", err)
	}

	// Generate public key
	publicKey, err := ssh.NewPublicKey(&privateKey.PublicKey)
	if err != nil {
		return fmt.Errorf("failed to generate public key: %w", err)
	}

	publicKeyFile, err := os.OpenFile(publicKeyPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0644)
	if err != nil {
		return fmt.Errorf("failed to create public key file: %w", err)
	}
	defer publicKeyFile.Close()

	publicKeyBytes := ssh.MarshalAuthorizedKey(publicKey)
	if _, err := publicKeyFile.Write(publicKeyBytes); err != nil {
		return fmt.Errorf("failed to write public key: %w", err)
	}

	app.OCIConfig.SSHPublicKey = strings.TrimSpace(string(publicKeyBytes))
	printSuccess(fmt.Sprintf("SSH key pair generated at %s/", sshDir))
	return nil
}

// Prompt with default
func promptWithDefault(prompt, defaultValue string) string {
	fmt.Printf("\033[0;34m%s [%s]: \033[0m", prompt, defaultValue)
	reader := bufio.NewReader(os.Stdin)
	input, _ := reader.ReadString('\n')
	input = strings.TrimSpace(input)
	if input == "" {
		return defaultValue
	}
	return input
}

// Prompt for integer in range
func promptIntRange(prompt, defaultValue string, min, max int) (int, error) {
	for {
		valueStr := promptWithDefault(prompt, defaultValue)
		value, err := strconv.Atoi(valueStr)
		if err != nil {
			printError(fmt.Sprintf("Please enter a number between %d and %d (received: '%s')", min, max, valueStr))
			continue
		}
		if value < min || value > max {
			printError(fmt.Sprintf("Please enter a number between %d and %d (received: %d)", min, max, value))
			continue
		}
		return value, nil
	}
}

// Confirm action
func confirmAction(prompt string, defaultYes bool) bool {
	defaultStr := "N"
	if defaultYes {
		defaultStr = "Y"
	}

	promptStr := "[y/N]"
	if defaultYes {
		promptStr = "[Y/n]"
	}

	fmt.Printf("\033[0;34m%s %s: \033[0m", prompt, promptStr)
	reader := bufio.NewReader(os.Stdin)
	response, _ := reader.ReadString('\n')
	response = strings.TrimSpace(strings.ToLower(response))

	if response == "" {
		return defaultYes
	}

	return response == "y" || response == "yes"
}

// Retry with backoff
func retryWithBackoff(fn func() error, maxAttempts int, baseDelay int) error {
	var lastErr error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		printStatus(fmt.Sprintf("Attempt %d/%d", attempt, maxAttempts))
		err := fn()
		if err == nil {
			return nil
		}

		lastErr = err
		errStr := err.Error()

		// Check for Out of Capacity
		if strings.Contains(strings.ToLower(errStr), "out of capacity") ||
			strings.Contains(strings.ToLower(errStr), "outofcapacity") {
			printWarning(fmt.Sprintf("Detected 'Out of Capacity' condition (attempt %d)", attempt))
		} else {
			printWarning(fmt.Sprintf("Command failed (attempt %d): %v", attempt, err))
		}

		if attempt < maxAttempts {
			sleepTime := baseDelay * (1 << (attempt - 1)) // Exponential backoff
			printStatus(fmt.Sprintf("Retrying in %ds...", sleepTime))
			time.Sleep(time.Duration(sleepTime) * time.Second)
		}
	}

	printError(fmt.Sprintf("Command failed after %d attempts", maxAttempts))
	return lastErr
}

// Run command with timeout
func runCommandWithTimeout(cmd *exec.Cmd, timeoutSeconds int) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutSeconds)*time.Second)
	defer cancel()

	cmd = exec.CommandContext(ctx, cmd.Path, cmd.Args[1:]...)
	return cmd.CombinedOutput()
}
