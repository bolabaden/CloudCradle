#Requires -Version 5.1

<#
.SYNOPSIS
    Oracle Cloud Infrastructure (OCI) Terraform Setup Script for Windows
    Idempotent, comprehensive implementation for Always Free Tier management

.DESCRIPTION
    This PowerShell script manages Oracle Cloud Free Tier resources using Terraform.
    It's completely idempotent and safe to run multiple times.

.PARAMETER NonInteractive
    Run in non-interactive mode (auto-approve prompts)

.PARAMETER AutoUseExisting
    Automatically use existing instances configuration

.PARAMETER AutoDeploy
    Automatically deploy without confirmation

.PARAMETER SkipConfig
    Skip configuration prompts and use existing config

.PARAMETER Debug
    Enable debug output

.PARAMETER ForceReauth
    Force re-authentication even if config exists

.EXAMPLE
    .\setup_oci_terraform.ps1

.EXAMPLE
    .\setup_oci_terraform.ps1 -NonInteractive -AutoUseExisting -AutoDeploy
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [switch]$AutoUseExisting,
    [switch]$AutoDeploy,
    [switch]$SkipConfig,
    [switch]$Debug,
    [switch]$ForceReauth
)

# Set error handling
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ============================================================================
# CONFIGURATION AND CONSTANTS
# ============================================================================

# Non-interactive mode support
$script:NonInteractive = $NonInteractive
$script:AutoUseExisting = $AutoUseExisting
$script:AutoDeploy = $AutoDeploy
$script:SkipConfig = $SkipConfig
$script:Debug = $Debug
$script:ForceReauth = $ForceReauth

# Terraform remote backend configuration
$script:TF_BACKEND = if ($env:TF_BACKEND) { $env:TF_BACKEND } else { "local" }
$script:TF_BACKEND_BUCKET = $env:TF_BACKEND_BUCKET
$script:TF_BACKEND_CREATE_BUCKET = if ($env:TF_BACKEND_CREATE_BUCKET -eq "true") { $true } else { $false }
$script:TF_BACKEND_REGION = $env:TF_BACKEND_REGION
$script:TF_BACKEND_ENDPOINT = $env:TF_BACKEND_ENDPOINT
$script:TF_BACKEND_STATE_KEY = if ($env:TF_BACKEND_STATE_KEY) { $env:TF_BACKEND_STATE_KEY } else { "terraform.tfstate" }
$script:TF_BACKEND_ACCESS_KEY = $env:TF_BACKEND_ACCESS_KEY
$script:TF_BACKEND_SECRET_KEY = $env:TF_BACKEND_SECRET_KEY

# Retry/backoff settings
$script:RETRY_MAX_ATTEMPTS = if ($env:RETRY_MAX_ATTEMPTS) { [int]$env:RETRY_MAX_ATTEMPTS } else { 8 }
$script:RETRY_BASE_DELAY = if ($env:RETRY_BASE_DELAY) { [int]$env:RETRY_BASE_DELAY } else { 15 }

# OCI CLI configuration
$script:OCI_CONFIG_FILE = if ($env:OCI_CONFIG_FILE) { $env:OCI_CONFIG_FILE } else { "$HOME\.oci\config" }
$script:OCI_PROFILE = if ($env:OCI_PROFILE) { $env:OCI_PROFILE } else { "DEFAULT" }
$script:OCI_AUTH_REGION = $env:OCI_AUTH_REGION
$script:OCI_CMD_TIMEOUT = if ($env:OCI_CMD_TIMEOUT) { [int]$env:OCI_CMD_TIMEOUT } else { 20 }
$script:OCI_CLI_CONNECTION_TIMEOUT = if ($env:OCI_CLI_CONNECTION_TIMEOUT) { [int]$env:OCI_CLI_CONNECTION_TIMEOUT } else { 10 }
$script:OCI_CLI_READ_TIMEOUT = if ($env:OCI_CLI_READ_TIMEOUT) { [int]$env:OCI_CLI_READ_TIMEOUT } else { 60 }
$script:OCI_CLI_MAX_RETRIES = if ($env:OCI_CLI_MAX_RETRIES) { [int]$env:OCI_CLI_MAX_RETRIES } else { 3 }

# Oracle Free Tier Limits
$script:FREE_TIER_MAX_AMD_INSTANCES = 2
$script:FREE_TIER_AMD_SHAPE = "VM.Standard.E2.1.Micro"
$script:FREE_TIER_MAX_ARM_OCPUS = 4
$script:FREE_TIER_MAX_ARM_MEMORY_GB = 24
$script:FREE_TIER_ARM_SHAPE = "VM.Standard.A1.Flex"
$script:FREE_TIER_MAX_STORAGE_GB = 200
$script:FREE_TIER_MIN_BOOT_VOLUME_GB = 47
$script:FREE_TIER_MAX_ARM_INSTANCES = 4
$script:FREE_TIER_MAX_VCNS = 2

# Global state tracking
$script:tenancy_ocid = ""
$script:user_ocid = ""
$script:region = ""
$script:fingerprint = ""
$script:availability_domain = ""
$script:ubuntu_image_ocid = ""
$script:ubuntu_arm_flex_image_ocid = ""
$script:ssh_public_key = ""
$script:auth_method = "security_token"

# Existing resource tracking
$script:EXISTING_VCNS = @{}
$script:EXISTING_SUBNETS = @{}
$script:EXISTING_INTERNET_GATEWAYS = @{}
$script:EXISTING_ROUTE_TABLES = @{}
$script:EXISTING_SECURITY_LISTS = @{}
$script:EXISTING_AMD_INSTANCES = @{}
$script:EXISTING_ARM_INSTANCES = @{}
$script:EXISTING_BOOT_VOLUMES = @{}
$script:EXISTING_BLOCK_VOLUMES = @{}

# Instance configuration
$script:amd_micro_instance_count = 0
$script:amd_micro_boot_volume_size_gb = 50
$script:arm_flex_instance_count = 0
$script:arm_flex_ocpus_per_instance = @()
$script:arm_flex_memory_per_instance = @()
$script:arm_flex_boot_volume_size_gb = @()
$script:arm_flex_block_volumes = @()
$script:amd_micro_hostnames = @()
$script:arm_flex_hostnames = @()

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

function Write-Status {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Blue
}

function Write-Success {
    param([string]$Message)
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
}

function Write-Error {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Write-Debug {
    param([string]$Message)
    if ($script:Debug) {
        Write-Host "[DEBUG] $Message" -ForegroundColor Cyan
    }
}

function Write-Header {
    param([string]$Title)
    Write-Host ""
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Magenta
    Write-Host "  $Title" -ForegroundColor Magenta
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Magenta
    Write-Host ""
}

function Write-Subheader {
    param([string]$Title)
    Write-Host ""
    Write-Host "── $Title ──" -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

function Test-Command {
    param([string]$Command)
    $null = Get-Command $Command -ErrorAction SilentlyContinue
    return $?
}

function Get-DefaultRegion {
    $tz = [System.TimeZoneInfo]::Local.Id
    $tzLower = $tz.ToLower()
    
    if ($tzLower -match "chicago|central|winnipeg|mexico") { return "us-chicago-1" }
    if ($tzLower -match "new_york|toronto|montreal|eastern") { return "us-ashburn-1" }
    if ($tzLower -match "los_angeles|vancouver|pacific") { return "us-sanjose-1" }
    if ($tzLower -match "phoenix|denver|mountain") { return "us-phoenix-1" }
    if ($tzLower -match "london|dublin") { return "uk-london-1" }
    if ($tzLower -match "paris|berlin|rome|madrid|amsterdam|stockholm|zurich|europe") { return "eu-frankfurt-1" }
    if ($tzLower -match "tokyo") { return "ap-tokyo-1" }
    if ($tzLower -match "seoul") { return "ap-seoul-1" }
    if ($tzLower -match "singapore") { return "ap-singapore-1" }
    if ($tzLower -match "sydney|melbourne") { return "ap-sydney-1" }
    return "us-chicago-1"
}

function Open-Url {
    param([string]$Url)
    if ([string]::IsNullOrEmpty($Url)) { return $false }
    try {
        Start-Process $Url
        return $true
    } catch {
        return $false
    }
}

function Read-OciConfigValue {
    param(
        [string]$Key,
        [string]$File = $script:OCI_CONFIG_FILE,
        [string]$Profile = $script:OCI_PROFILE
    )
    
    if (-not (Test-Path $File)) { return $null }
    
    $inSection = $false
    $lines = Get-Content $File
    
    foreach ($line in $lines) {
        if ($line -match "^\[$Profile\]") {
            $inSection = $true
            continue
        }
        if ($line -match "^\[") {
            $inSection = $false
            continue
        }
        if ($inSection -and $line -match "^$Key\s*=\s*(.+)$") {
            return $matches[1].Trim()
        }
    }
    
    return $null
}

function Test-InstancePrincipal {
    try {
        $response = Invoke-WebRequest -Uri "http://169.254.169.254/opc/v2/" -TimeoutSec 2 -UseBasicParsing -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function Test-ExistingOciConfig {
    if (-not (Test-Path $script:OCI_CONFIG_FILE)) {
        Write-Warning "OCI config not found at $script:OCI_CONFIG_FILE"
        return $false
    }
    
    $cfgAuth = Read-OciConfigValue "auth"
    $keyFile = Read-OciConfigValue "key_file"
    $tokenFile = Read-OciConfigValue "security_token_file"
    $passPhrase = Read-OciConfigValue "pass_phrase"
    
    if ($cfgAuth) {
        $script:auth_method = $cfgAuth
    } elseif ($tokenFile) {
        $script:auth_method = "security_token"
    } elseif ($keyFile) {
        $script:auth_method = "api_key"
    }
    
    switch ($script:auth_method) {
        "security_token" {
            if (-not $tokenFile -or -not (Test-Path $tokenFile)) {
                Write-Warning "security_token auth selected but security_token_file is missing"
                return $false
            }
        }
        "api_key" {
            if (-not $keyFile -or -not (Test-Path $keyFile)) {
                Write-Warning "api_key auth selected but key_file is missing"
                return $false
            }
            if ((Get-Content $keyFile -Raw) -match "ENCRYPTED") {
                if (-not $env:OCI_CLI_PASSPHRASE -and -not $passPhrase) {
                    Write-Warning "Private key is encrypted but no passphrase provided"
                    return $false
                }
            }
        }
        { $_ -in @("instance_principal", "resource_principal", "oke_workload_identity", "instance_obo_user") } {
            if (-not (Test-InstancePrincipal)) {
                Write-Warning "Instance principal auth selected but OCI metadata service is unreachable"
                return $false
            }
        }
        default {
            if ([string]::IsNullOrEmpty($script:auth_method)) {
                Write-Warning "Unable to determine auth method from config"
            } else {
                Write-Warning "Unsupported auth method '$script:auth_method' in config"
            }
            return $false
        }
    }
    
    return $true
}

function Invoke-OciCommand {
    param([string[]]$Arguments)
    
    $baseArgs = @(
        "--config-file", "`"$script:OCI_CONFIG_FILE`"",
        "--profile", "`"$script:OCI_PROFILE`"",
        "--connection-timeout", $script:OCI_CLI_CONNECTION_TIMEOUT,
        "--read-timeout", $script:OCI_CLI_READ_TIMEOUT,
        "--max-retries", $script:OCI_CLI_MAX_RETRIES
    )
    
    if ($env:OCI_CLI_AUTH) {
        $baseArgs += "--auth", $env:OCI_CLI_AUTH
    } elseif ($script:auth_method) {
        $baseArgs += "--auth", $script:auth_method
    }
    
    $fullArgs = $baseArgs + $Arguments
    $cmd = "oci $($fullArgs -join ' ')"
    
    try {
        $result = Invoke-Expression $cmd 2>&1
        if ($LASTEXITCODE -eq 0) {
            return $result
        }
        return $null
    } catch {
        Write-Debug "OCI command failed: $_"
        return $null
    }
}

function Get-SafeJsonValue {
    param(
        [string]$Json,
        [string]$Query,
        [string]$Default = ""
    )
    
    if ([string]::IsNullOrEmpty($Json) -or $Json -eq "null") {
        return $Default
    }
    
    try {
        $obj = $Json | ConvertFrom-Json
        $result = $obj | Select-Object -ExpandProperty $Query -ErrorAction SilentlyContinue
        if ($result -eq $null -or $result -eq "null") {
            return $Default
        }
        return $result
    } catch {
        return $Default
    }
}

function Invoke-RetryWithBackoff {
    param(
        [scriptblock]$Command,
        [int]$MaxAttempts = $script:RETRY_MAX_ATTEMPTS,
        [int]$BaseDelay = $script:RETRY_BASE_DELAY
    )
    
    $attempt = 1
    $lastError = $null
    
    while ($attempt -le $MaxAttempts) {
        Write-Status "Attempt $attempt/$MaxAttempts: $Command"
        
        try {
            $result = & $Command 2>&1
            if ($LASTEXITCODE -eq 0 -or $result -is [string] -and $result -match "^\s*\{") {
                return $result
            }
        } catch {
            $lastError = $_
        }
        
        if ($result -match "out of capacity|out of host capacity|OutOfCapacity|OutOfHostCapacity") {
            Write-Warning "Detected 'Out of Capacity' condition (attempt $attempt)."
        } else {
            Write-Warning "Command failed (attempt $attempt)."
        }
        
        if ($attempt -lt $MaxAttempts) {
            $sleepTime = $BaseDelay * [Math]::Pow(2, $attempt - 1)
            Write-Status "Retrying in ${sleepTime}s..."
            Start-Sleep -Seconds $sleepTime
        }
        
        $attempt++
    }
    
    Write-Error "Command failed after $MaxAttempts attempts"
    if ($lastError) { throw $lastError }
    return $null
}

# ============================================================================
# INSTALLATION FUNCTIONS
# ============================================================================

function Install-Prerequisites {
    Write-Subheader "Installing Prerequisites"
    
    $packagesToInstall = @()
    
    if (-not (Test-Command "jq")) {
        $packagesToInstall += "jq"
    }
    if (-not (Test-Command "curl")) {
        $packagesToInstall += "curl"
    }
    if (-not (Test-Command "unzip")) {
        $packagesToInstall += "unzip"
    }
    
    if ($packagesToInstall.Count -gt 0) {
        Write-Status "Installing required packages: $($packagesToInstall -join ', ')"
        
        if (Test-Command "choco") {
            choco install -y $packagesToInstall
        } elseif (Test-Command "winget") {
            foreach ($pkg in $packagesToInstall) {
                winget install $pkg -e --silent
            }
        } else {
            Write-Warning "No package manager found (choco or winget). Please install manually: $($packagesToInstall -join ', ')"
        }
    }
    
    $requiredCommands = @("openssl", "ssh-keygen", "curl")
    foreach ($cmd in $requiredCommands) {
        if (-not (Test-Command $cmd)) {
            Write-Error "Required command '$cmd' is not available"
            return $false
        }
    }
    
    Write-Success "All prerequisites installed"
    return $true
}

function Install-OciCli {
    Write-Subheader "OCI CLI Setup"
    
    if (Test-Command "oci") {
        $version = oci --version 2>$null | Select-Object -First 1
        Write-Status "OCI CLI already installed: $version"
        return $true
    }
    
    Write-Status "Installing OCI CLI..."
    
    if (-not (Test-Command "python")) {
        Write-Status "Python not found. Please install Python 3.8+ from python.org"
        return $false
    }
    
    $venvDir = Join-Path $PWD ".venv"
    if (-not (Test-Path $venvDir)) {
        Write-Status "Creating Python virtual environment..."
        python -m venv $venvDir
    }
    
    $activateScript = Join-Path $venvDir "Scripts\Activate.ps1"
    if (Test-Path $activateScript) {
        & $activateScript
    }
    
    Write-Status "Installing OCI CLI in virtual environment..."
    pip install --upgrade pip --quiet
    pip install oci-cli --quiet
    
    Write-Success "OCI CLI installed successfully"
    return $true
}

function Install-Terraform {
    Write-Subheader "Terraform Setup"
    
    if (Test-Command "terraform") {
        $version = terraform version -json 2>$null | ConvertFrom-Json | Select-Object -ExpandProperty terraform_version
        if (-not $version) {
            $version = (terraform version | Select-Object -First 1) -replace "Terraform v", ""
        }
        Write-Status "Terraform already installed: version $version"
        return $true
    }
    
    Write-Status "Installing Terraform..."
    
    try {
        $latestVersion = (Invoke-RestMethod -Uri "https://api.github.com/repos/hashicorp/terraform/releases/latest").tag_name -replace "v", ""
    } catch {
        $latestVersion = "1.7.0"
        Write-Warning "Could not fetch latest version, using fallback: $latestVersion"
    }
    
    $arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
    $os = "windows"
    
    $tfUrl = "https://releases.hashicorp.com/terraform/${latestVersion}/terraform_${latestVersion}_${os}_${arch}.zip"
    $tempDir = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_.FullName }
    
    Write-Status "Downloading Terraform $latestVersion for ${os}_${arch}..."
    
    try {
        Invoke-WebRequest -Uri $tfUrl -OutFile "$tempDir\terraform.zip"
        Expand-Archive -Path "$tempDir\terraform.zip" -DestinationPath $tempDir -Force
        $terraformPath = Join-Path $tempDir "terraform.exe"
        
        if (Test-Path $terraformPath) {
            $targetPath = "$env:ProgramFiles\Terraform\terraform.exe"
            New-Item -ItemType Directory -Path (Split-Path $targetPath) -Force | Out-Null
            Copy-Item $terraformPath $targetPath -Force
            $env:Path += ";$env:ProgramFiles\Terraform"
            
            if (Test-Command "terraform") {
                Write-Success "Terraform installed successfully"
                Remove-Item $tempDir -Recurse -Force
                return $true
            }
        }
    } catch {
        Write-Error "Failed to install Terraform: $_"
    } finally {
        if (Test-Path $tempDir) {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    return $false
}

# ============================================================================
# OCI AUTHENTICATION FUNCTIONS
# ============================================================================

function Get-AuthMethod {
    if (Test-Path $script:OCI_CONFIG_FILE) {
        $cfgAuth = Read-OciConfigValue "auth"
        $tokenFile = Read-OciConfigValue "security_token_file"
        $keyFile = Read-OciConfigValue "key_file"
        
        if ($cfgAuth) {
            $script:auth_method = $cfgAuth
        } elseif ($tokenFile) {
            $script:auth_method = "security_token"
        } elseif ($keyFile) {
            $script:auth_method = "api_key"
        }
    }
    Write-Debug "Detected auth method: $script:auth_method (profile: $script:OCI_PROFILE, config: $script:OCI_CONFIG_FILE)"
}

function Test-OciConnectivity {
    Write-Status "Testing OCI API connectivity..."
    
    Write-Status "Checking IAM region list (timeout ${script:OCI_CMD_TIMEOUT}s)..."
    $result = Invoke-OciCommand @("iam", "region", "list")
    if ($result) {
        Write-Debug "Connectivity test passed (region list)"
        return $true
    }
    
    Write-Warning "Region list query failed or timed out"
    
    $testTenancy = (Get-Content $script:OCI_CONFIG_FILE | Select-String -Pattern "tenancy\s*=\s*(.+)" | ForEach-Object { $_.Matches.Groups[1].Value }) | Select-Object -First 1
    
    if ($testTenancy) {
        Write-Status "Checking IAM tenancy get (timeout ${script:OCI_CMD_TIMEOUT}s)..."
        $result = Invoke-OciCommand @("iam", "tenancy", "get", "--tenancy-id", $testTenancy)
        if ($result) {
            Write-Debug "Connectivity test passed (tenancy get)"
            return $true
        }
        Write-Warning "Tenancy get failed or timed out"
    }
    
    Write-Debug "All connectivity tests failed"
    return $false
}

function Set-OciConfig {
    Write-Subheader "OCI Authentication"
    
    $ociDir = Split-Path $script:OCI_CONFIG_FILE -Parent
    if (-not (Test-Path $ociDir)) {
        New-Item -ItemType Directory -Path $ociDir -Force | Out-Null
    }
    
    $existingConfigInvalid = $false
    if (Test-Path $script:OCI_CONFIG_FILE) {
        Write-Status "Existing OCI configuration found"
        Get-AuthMethod
        
        Write-Status "Validating existing OCI configuration..."
        
        if (-not (Test-ExistingOciConfig)) {
            $existingConfigInvalid = $true
            Write-Warning "Existing OCI configuration is incomplete or requires interactive input"
        } else {
            Write-Status "Testing existing OCI configuration connectivity..."
            if (Test-OciConnectivity) {
                Write-Success "Existing OCI configuration is valid"
                return $true
            }
        }
        
        Write-Warning "Existing configuration failed connectivity test (will retry with refresh)"
        
        if ($script:auth_method -eq "security_token") {
            Write-Status "Attempting to refresh session token (timeout ${script:OCI_CMD_TIMEOUT}s)..."
            $refreshResult = Invoke-OciCommand @("session", "refresh")
            if ($refreshResult -and (Test-OciConnectivity)) {
                Write-Success "Session token refreshed successfully"
                return $true
            } else {
                Write-Warning "Session refresh failed or timed out"
            }
            
            Write-Status "Session refresh did not restore connectivity, initiating interactive authentication as a fallback..."
        }
    }
    
    if ($script:NonInteractive) {
        Write-Error "Cannot perform interactive authentication in non-interactive mode. Aborting."
        return $false
    }
    
    $authRegion = Read-OciConfigValue "region" $script:OCI_CONFIG_FILE $script:OCI_PROFILE
    if (-not $authRegion) { $authRegion = $script:OCI_AUTH_REGION }
    if (-not $authRegion) { $authRegion = Get-DefaultRegion }
    
    if (-not $script:NonInteractive) {
        $authRegion = Read-Host "Region for authentication [$authRegion]"
        if ([string]::IsNullOrWhiteSpace($authRegion)) {
            $authRegion = (Get-DefaultRegion)
        }
    }
    
    if ($script:ForceReauth) {
        $newProfile = Read-Host "Enter new profile name to create/use [NEW_PROFILE]"
        if ([string]::IsNullOrWhiteSpace($newProfile)) { $newProfile = "NEW_PROFILE" }
        
        Write-Status "Starting interactive session authenticate for profile '$newProfile'..."
        Write-Status "Using region '$authRegion' for authentication"
        
        try {
            $authOut = oci session authenticate --no-browser --profile-name $newProfile --region $authRegion --session-expiration-in-minutes 60 2>&1 | Out-String
            $url = ([regex]::Match($authOut, "https://[^\s]+")).Value
            if ($url) {
                Write-Status "Opening browser for login URL..."
                Open-Url $url
            }
            
            $script:OCI_PROFILE = $newProfile
            $script:auth_method = "security_token"
            
            if ($existingConfigInvalid) {
                Write-Warning "Detected invalid or incomplete OCI config file - AUTOMATICALLY DELETING AND FORCING FRESH AUTHENTICATION"
                
                if (Test-Path $script:OCI_CONFIG_FILE) {
                    $backupPath = "$script:OCI_CONFIG_FILE.corrupted.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                    Copy-Item $script:OCI_CONFIG_FILE $backupPath -ErrorAction SilentlyContinue
                    Write-Status "Backing up corrupted config to $backupPath"
                    Write-Status "Forcibly deleting corrupted config file: $script:OCI_CONFIG_FILE"
                    Remove-Item $script:OCI_CONFIG_FILE -Force
                }
                
                Remove-Item "$HOME\.oci\config.session_auth" -ErrorAction SilentlyContinue
                
                $newProfile = "DEFAULT"
                Write-Status "Creating fresh OCI configuration with browser-based authentication for profile '$newProfile'..."
                Write-Status "This will open your browser to log into Oracle Cloud."
                Write-Status ""
                Write-Status "Using region '$authRegion' for authentication"
                Write-Status ""
                
                $script:OCI_CONFIG_FILE = "$HOME\.oci\config"
                $script:OCI_PROFILE = $newProfile
                Remove-Item Env:\OCI_CLI_CONFIG_FILE -ErrorAction SilentlyContinue
                
                $authOut = oci session authenticate --no-browser --profile-name $newProfile --region $authRegion --session-expiration-in-minutes 60 2>&1 | Out-String
                $url = ([regex]::Match($authOut, "https://[^\s]+")).Value
                if ($url) {
                    Write-Status "Opening browser for login URL..."
                    Open-Url $url
                    Write-Status ""
                    Write-Status "After completing browser authentication, press Enter to continue..."
                    Read-Host
                }
                
                $script:auth_method = "security_token"
                if (Test-OciConnectivity) {
                    Write-Success "Fresh session authentication succeeded for profile '$newProfile'"
                    return $true
                } else {
                    Write-Warning "Session auth completed but connectivity test failed"
                }
            }
        } catch {
            Write-Error "Authentication failed: $_"
            return $false
        }
    } else {
        if ($existingConfigInvalid) {
            Write-Warning "Detected invalid or incomplete OCI config file - AUTOMATICALLY DELETING AND FORCING FRESH AUTHENTICATION"
            
            if (Test-Path $script:OCI_CONFIG_FILE) {
                $backupPath = "$script:OCI_CONFIG_FILE.corrupted.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                Copy-Item $script:OCI_CONFIG_FILE $backupPath -ErrorAction SilentlyContinue
                Write-Status "Backing up corrupted config to $backupPath"
                Write-Status "Forcibly deleting corrupted config file: $script:OCI_CONFIG_FILE"
                Remove-Item $script:OCI_CONFIG_FILE -Force
            }
            
            Remove-Item "$HOME\.oci\config.session_auth" -ErrorAction SilentlyContinue
            
            $newProfile = "DEFAULT"
            Write-Status "Creating fresh OCI configuration with browser-based authentication for profile '$newProfile'..."
            Write-Status "This will open your browser to log into Oracle Cloud."
            Write-Status ""
            Write-Status "Using region '$authRegion' for authentication"
            Write-Status ""
            
            $script:OCI_CONFIG_FILE = "$HOME\.oci\config"
            $script:OCI_PROFILE = $newProfile
            Remove-Item Env:\OCI_CLI_CONFIG_FILE -ErrorAction SilentlyContinue
            
            try {
                $authOut = oci session authenticate --no-browser --profile-name $newProfile --region $authRegion --session-expiration-in-minutes 60 2>&1 | Out-String
                $url = ([regex]::Match($authOut, "https://[^\s]+")).Value
                if ($url) {
                    Write-Status "Opening browser for login URL..."
                    Open-Url $url
                    Write-Status ""
                    Write-Status "After completing browser authentication, press Enter to continue..."
                    Read-Host
                }
                
                $script:auth_method = "security_token"
                if (Test-OciConnectivity) {
                    Write-Success "Fresh session authentication succeeded for profile '$newProfile'"
                    return $true
                } else {
                    Write-Warning "Session auth completed but connectivity test failed"
                }
            } catch {
                Write-Error "Browser-based authentication failed. Please verify your Oracle Cloud credentials and try again."
                return $false
            }
        } else {
            Write-Status "Using profile '$script:OCI_PROFILE' for interactive session authenticate..."
            Write-Status "Using region '$authRegion' for authentication"
            
            try {
                $authOut = oci session authenticate --no-browser --profile-name $script:OCI_PROFILE --region $authRegion --session-expiration-in-minutes 60 2>&1 | Out-String
                $url = ([regex]::Match($authOut, "https://[^\s]+")).Value
                if ($url) {
                    Write-Status "Opening browser for login URL..."
                    Open-Url $url
                }
                
                $script:auth_method = "security_token"
            } catch {
                Write-Error "Authentication failed: $_"
                return $false
            }
        }
    }
    
    if (Test-OciConnectivity) {
        Write-Success "OCI authentication configured successfully"
        return $true
    }
    
    Write-Error "OCI configuration verification failed"
    return $false
}

# ============================================================================
# OCI RESOURCE DISCOVERY FUNCTIONS
# ============================================================================

function Get-OciConfigValues {
    Write-Subheader "Fetching OCI Configuration"
    
    $tenancyMatch = Get-Content $script:OCI_CONFIG_FILE | Select-String -Pattern "tenancy\s*=\s*(.+)" | ForEach-Object { $_.Matches.Groups[1].Value } | Select-Object -First 1
    if (-not $tenancyMatch) {
        Write-Error "Failed to fetch tenancy OCID from config"
        return $false
    }
    $script:tenancy_ocid = $tenancyMatch
    Write-Status "Tenancy OCID: $script:tenancy_ocid"
    
    $userMatch = Get-Content $script:OCI_CONFIG_FILE | Select-String -Pattern "^\s*user\s*=\s*(.+)" | ForEach-Object { $_.Matches.Groups[1].Value } | Select-Object -First 1
    if (-not $userMatch) {
        $userInfo = Invoke-OciCommand @("iam", "user", "list", "--compartment-id", $script:tenancy_ocid, "--limit", "1")
        if ($userInfo) {
            $userObj = $userInfo | ConvertFrom-Json
            $script:user_ocid = $userObj.data[0].id
        }
    } else {
        $script:user_ocid = $userMatch
    }
    Write-Status "User OCID: $(if ($script:user_ocid) { $script:user_ocid } else { 'N/A (session token auth)' })"
    
    $regionMatch = Get-Content $script:OCI_CONFIG_FILE | Select-String -Pattern "region\s*=\s*(.+)" | ForEach-Object { $_.Matches.Groups[1].Value } | Select-Object -First 1
    if (-not $regionMatch) {
        Write-Error "Failed to fetch region from config"
        return $false
    }
    $script:region = $regionMatch
    Write-Status "Region: $script:region"
    
    if ($script:auth_method -eq "security_token") {
        $script:fingerprint = "session_token_auth"
    } else {
        $fingerprintMatch = Get-Content $script:OCI_CONFIG_FILE | Select-String -Pattern "fingerprint\s*=\s*(.+)" | ForEach-Object { $_.Matches.Groups[1].Value } | Select-Object -First 1
        $script:fingerprint = $fingerprintMatch
    }
    Write-Debug "Auth fingerprint: $script:fingerprint"
    
    Write-Success "OCI configuration values fetched"
    return $true
}

function Get-AvailabilityDomains {
    Write-Status "Fetching availability domains..."
    
    $adList = Invoke-OciCommand @("iam", "availability-domain", "list", "--compartment-id", $script:tenancy_ocid, "--query", "data[].name", "--raw-output")
    
    if (-not $adList) {
        Write-Error "Failed to fetch availability domains"
        return $false
    }
    
    $adObj = $adList | ConvertFrom-Json
    if ($adObj -and $adObj.Count -gt 0) {
        $script:availability_domain = $adObj[0]
        Write-Success "Availability domain: $script:availability_domain"
        return $true
    }
    
    Write-Error "Failed to parse availability domain"
    return $false
}

function Get-UbuntuImages {
    Write-Status "Fetching Ubuntu images for region $script:region..."
    
    Write-Status "  Looking for x86 Ubuntu image..."
    $x86Images = Invoke-OciCommand @("compute", "image", "list", "--compartment-id", $script:tenancy_ocid, "--operating-system", "Canonical Ubuntu", "--shape", $script:FREE_TIER_AMD_SHAPE, "--sort-by", "TIMECREATED", "--sort-order", "DESC", "--query", "data[].{id:id,name:`"display-name`"}", "--all")
    
    if ($x86Images) {
        $x86Obj = $x86Images | ConvertFrom-Json
        if ($x86Obj -and $x86Obj.Count -gt 0) {
            $script:ubuntu_image_ocid = $x86Obj[0].id
            Write-Success "  x86 image: $($x86Obj[0].name)"
            Write-Debug "  x86 OCID: $script:ubuntu_image_ocid"
        } else {
            Write-Warning "  No x86 Ubuntu image found - AMD instances disabled"
            $script:ubuntu_image_ocid = ""
        }
    } else {
        Write-Warning "  No x86 Ubuntu image found - AMD instances disabled"
        $script:ubuntu_image_ocid = ""
    }
    
    Write-Status "  Looking for ARM Ubuntu image..."
    $armImages = Invoke-OciCommand @("compute", "image", "list", "--compartment-id", $script:tenancy_ocid, "--operating-system", "Canonical Ubuntu", "--shape", $script:FREE_TIER_ARM_SHAPE, "--sort-by", "TIMECREATED", "--sort-order", "DESC", "--query", "data[].{id:id,name:`"display-name`"}", "--all")
    
    if ($armImages) {
        $armObj = $armImages | ConvertFrom-Json
        if ($armObj -and $armObj.Count -gt 0) {
            $script:ubuntu_arm_flex_image_ocid = $armObj[0].id
            Write-Success "  ARM image: $($armObj[0].name)"
            Write-Debug "  ARM OCID: $script:ubuntu_arm_flex_image_ocid"
        } else {
            Write-Warning "  No ARM Ubuntu image found - ARM instances disabled"
            $script:ubuntu_arm_flex_image_ocid = ""
        }
    } else {
        Write-Warning "  No ARM Ubuntu image found - ARM instances disabled"
        $script:ubuntu_arm_flex_image_ocid = ""
    }
}

function New-SshKeys {
    Write-Status "Setting up SSH keys..."
    
    $sshDir = Join-Path $PWD "ssh_keys"
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }
    
    $privateKeyPath = Join-Path $sshDir "id_rsa"
    $publicKeyPath = Join-Path $sshDir "id_rsa.pub"
    
    if (-not (Test-Path $privateKeyPath)) {
        Write-Status "Generating new SSH key pair..."
        ssh-keygen -t rsa -b 4096 -f $privateKeyPath -N '""' -q
        icacls $privateKeyPath /inheritance:r /grant:r "$env:USERNAME:R" | Out-Null
        Write-Success "SSH key pair generated at $sshDir\"
    } else {
        Write-Status "Using existing SSH key pair at $sshDir\"
    }
    
    $script:ssh_public_key = Get-Content $publicKeyPath -Raw
}

# ============================================================================
# COMPREHENSIVE RESOURCE INVENTORY
# ============================================================================

function Get-AllResourcesInventory {
    Write-Header "COMPREHENSIVE RESOURCE INVENTORY"
    Write-Status "Scanning all existing OCI resources in tenancy..."
    Write-Status "This ensures we never create duplicate resources."
    Write-Host ""
    
    Get-ComputeInstancesInventory
    Get-NetworkingResourcesInventory
    Get-StorageResourcesInventory
    
    Show-ResourceInventory
}

function Get-ComputeInstancesInventory {
    Write-Status "Inventorying compute instances..."
    
    $allInstances = Invoke-OciCommand @("compute", "instance", "list", "--compartment-id", $script:tenancy_ocid, "--query", "data[?`"lifecycle-state`"!=`"TERMINATED`"].{id:id,name:`"display-name`",state:`"lifecycle-state`",shape:shape,ad:`"availability-domain`",created:`"time-created`"}", "--all")
    
    $script:EXISTING_AMD_INSTANCES = @{}
    $script:EXISTING_ARM_INSTANCES = @{}
    
    if (-not $allInstances) {
        Write-Status "  No existing compute instances found"
        return
    }
    
    $instancesObj = $allInstances | ConvertFrom-Json
    if (-not $instancesObj -or $instancesObj.Count -eq 0) {
        Write-Status "  No existing compute instances found"
        return
    }
    
    foreach ($instance in $instancesObj) {
        if (-not $instance.id) { continue }
        
        $vnicAttachments = Invoke-OciCommand @("compute", "vnic-attachment", "list", "--compartment-id", $script:tenancy_ocid, "--instance-id", $instance.id, "--query", "data[?`"lifecycle-state`"==`"ATTACHED`"]")
        
        $publicIp = "none"
        $privateIp = "none"
        
        if ($vnicAttachments) {
            $vnicObj = $vnicAttachments | ConvertFrom-Json
            if ($vnicObj -and $vnicObj.Count -gt 0) {
                $vnicId = $vnicObj[0].'vnic-id'
                if ($vnicId) {
                    $vnicDetails = Invoke-OciCommand @("network", "vnic", "get", "--vnic-id", $vnicId)
                    if ($vnicDetails) {
                        $vnicDetailsObj = $vnicDetails | ConvertFrom-Json
                        $publicIp = if ($vnicDetailsObj.data.'public-ip') { $vnicDetailsObj.data.'public-ip' } else { "none" }
                        $privateIp = if ($vnicDetailsObj.data.'private-ip') { $vnicDetailsObj.data.'private-ip' } else { "none" }
                    }
                }
            }
        }
        
        if ($instance.shape -eq $script:FREE_TIER_AMD_SHAPE) {
            $script:EXISTING_AMD_INSTANCES[$instance.id] = "$($instance.name)|$($instance.state)|$($instance.shape)|$publicIp|$privateIp"
            Write-Status "  Found AMD instance: $($instance.name) ($($instance.state)) - IP: $publicIp"
        } elseif ($instance.shape -eq $script:FREE_TIER_ARM_SHAPE) {
            $instanceDetails = Invoke-OciCommand @("compute", "instance", "get", "--instance-id", $instance.id)
            $ocpus = 0
            $memory = 0
            if ($instanceDetails) {
                $instanceDetailsObj = $instanceDetails | ConvertFrom-Json
                $ocpus = if ($instanceDetailsObj.data.'shape-config'.ocpus) { $instanceDetailsObj.data.'shape-config'.ocpus } else { 0 }
                $memory = if ($instanceDetailsObj.data.'shape-config'.'memory-in-gbs') { $instanceDetailsObj.data.'shape-config'.'memory-in-gbs' } else { 0 }
            }
            
            $script:EXISTING_ARM_INSTANCES[$instance.id] = "$($instance.name)|$($instance.state)|$($instance.shape)|$publicIp|$privateIp|$ocpus|$memory"
            Write-Status "  Found ARM instance: $($instance.name) ($($instance.state), ${ocpus}OCPUs, ${memory}GB) - IP: $publicIp"
        } else {
            Write-Debug "  Found non-free-tier instance: $($instance.name) ($($instance.shape))"
        }
    }
    
    Write-Status "  AMD instances: $($script:EXISTING_AMD_INSTANCES.Count)/$script:FREE_TIER_MAX_AMD_INSTANCES"
    Write-Status "  ARM instances: $($script:EXISTING_ARM_INSTANCES.Count)/$script:FREE_TIER_MAX_ARM_INSTANCES"
}

function Get-NetworkingResourcesInventory {
    Write-Status "Inventorying networking resources..."
    
    $script:EXISTING_VCNS = @{}
    $script:EXISTING_SUBNETS = @{}
    $script:EXISTING_INTERNET_GATEWAYS = @{}
    $script:EXISTING_ROUTE_TABLES = @{}
    $script:EXISTING_SECURITY_LISTS = @{}
    
    $vcnList = Invoke-OciCommand @("network", "vcn", "list", "--compartment-id", $script:tenancy_ocid, "--query", "data[?`"lifecycle-state`"==`"AVAILABLE`"].{id:id,name:`"display-name`",cidr:`"cidr-block`"}", "--all")
    
    if (-not $vcnList) { return }
    
    $vcnsObj = $vcnList | ConvertFrom-Json
    if (-not $vcnsObj) { return }
    
    foreach ($vcn in $vcnsObj) {
        if (-not $vcn.id) { continue }
        
        $script:EXISTING_VCNS[$vcn.id] = "$($vcn.name)|$($vcn.cidr)"
        Write-Status "  Found VCN: $($vcn.name) ($($vcn.cidr))"
        
        $subnetList = Invoke-OciCommand @("network", "subnet", "list", "--compartment-id", $script:tenancy_ocid, "--vcn-id", $vcn.id, "--query", "data[?`"lifecycle-state`"==`"AVAILABLE`"].{id:id,name:`"display-name`",cidr:`"cidr-block`"}")
        if ($subnetList) {
            $subnetsObj = $subnetList | ConvertFrom-Json
            foreach ($subnet in $subnetsObj) {
                if ($subnet.id) {
                    $script:EXISTING_SUBNETS[$subnet.id] = "$($subnet.name)|$($subnet.cidr)|$($vcn.id)"
                    Write-Debug "    Subnet: $($subnet.name) ($($subnet.cidr))"
                }
            }
        }
        
        $igList = Invoke-OciCommand @("network", "internet-gateway", "list", "--compartment-id", $script:tenancy_ocid, "--vcn-id", $vcn.id, "--query", "data[?`"lifecycle-state`"==`"AVAILABLE`"].{id:id,name:`"display-name`"}")
        if ($igList) {
            $igsObj = $igList | ConvertFrom-Json
            foreach ($ig in $igsObj) {
                if ($ig.id) {
                    $script:EXISTING_INTERNET_GATEWAYS[$ig.id] = "$($ig.name)|$($vcn.id)"
                }
            }
        }
        
        $rtList = Invoke-OciCommand @("network", "route-table", "list", "--compartment-id", $script:tenancy_ocid, "--vcn-id", $vcn.id, "--query", "data[].{id:id,name:`"display-name`"}")
        if ($rtList) {
            $rtsObj = $rtList | ConvertFrom-Json
            foreach ($rt in $rtsObj) {
                if ($rt.id) {
                    $script:EXISTING_ROUTE_TABLES[$rt.id] = "$($rt.name)|$($vcn.id)"
                }
            }
        }
        
        $slList = Invoke-OciCommand @("network", "security-list", "list", "--compartment-id", $script:tenancy_ocid, "--vcn-id", $vcn.id, "--query", "data[].{id:id,name:`"display-name`"}")
        if ($slList) {
            $slsObj = $slList | ConvertFrom-Json
            foreach ($sl in $slsObj) {
                if ($sl.id) {
                    $script:EXISTING_SECURITY_LISTS[$sl.id] = "$($sl.name)|$($vcn.id)"
                }
            }
        }
    }
    
    Write-Status "  VCNs: $($script:EXISTING_VCNS.Count)/$script:FREE_TIER_MAX_VCNS"
    Write-Status "  Subnets: $($script:EXISTING_SUBNETS.Count)"
    Write-Status "  Internet Gateways: $($script:EXISTING_INTERNET_GATEWAYS.Count)"
}

function Get-StorageResourcesInventory {
    Write-Status "Inventorying storage resources..."
    
    $script:EXISTING_BOOT_VOLUMES = @{}
    $script:EXISTING_BLOCK_VOLUMES = @{}
    
    $bootList = Invoke-OciCommand @("bv", "boot-volume", "list", "--compartment-id", $script:tenancy_ocid, "--availability-domain", $script:availability_domain, "--query", "data[?`"lifecycle-state`"==`"AVAILABLE`"].{id:id,name:`"display-name`",size:`"size-in-gbs`"}", "--all")
    
    $totalBootGb = 0
    if ($bootList) {
        $bootsObj = $bootList | ConvertFrom-Json
        foreach ($boot in $bootsObj) {
            if ($boot.id) {
                $size = if ($boot.size) { $boot.size } else { 0 }
                $script:EXISTING_BOOT_VOLUMES[$boot.id] = "$($boot.name)|$size"
                $totalBootGb += $size
            }
        }
    }
    
    $blockList = Invoke-OciCommand @("bv", "volume", "list", "--compartment-id", $script:tenancy_ocid, "--availability-domain", $script:availability_domain, "--query", "data[?`"lifecycle-state`"==`"AVAILABLE`"].{id:id,name:`"display-name`",size:`"size-in-gbs`"}", "--all")
    
    $totalBlockGb = 0
    if ($blockList) {
        $blocksObj = $blockList | ConvertFrom-Json
        foreach ($block in $blocksObj) {
            if ($block.id) {
                $size = if ($block.size) { $block.size } else { 0 }
                $script:EXISTING_BLOCK_VOLUMES[$block.id] = "$($block.name)|$size"
                $totalBlockGb += $size
            }
        }
    }
    
    $totalStorage = $totalBootGb + $totalBlockGb
    
    Write-Status "  Boot volumes: $($script:EXISTING_BOOT_VOLUMES.Count) (${totalBootGb}GB)"
    Write-Status "  Block volumes: $($script:EXISTING_BLOCK_VOLUMES.Count) (${totalBlockGb}GB)"
    Write-Status "  Total storage: ${totalStorage}GB/$script:FREE_TIER_MAX_STORAGE_GB GB"
}

function Show-ResourceInventory {
    Write-Host ""
    Write-Header "RESOURCE INVENTORY SUMMARY"
    
    $totalAmd = $script:EXISTING_AMD_INSTANCES.Count
    $totalArm = $script:EXISTING_ARM_INSTANCES.Count
    $totalArmOcpus = 0
    $totalArmMemory = 0
    
    foreach ($instanceData in $script:EXISTING_ARM_INSTANCES.Values) {
        $parts = $instanceData -split '\|'
        $totalArmOcpus += [int]$parts[5]
        $totalArmMemory += [int]$parts[6]
    }
    
    $totalBootGb = 0
    foreach ($bootData in $script:EXISTING_BOOT_VOLUMES.Values) {
        $size = [int]($bootData -split '\|')[1]
        $totalBootGb += $size
    }
    
    $totalBlockGb = 0
    foreach ($blockData in $script:EXISTING_BLOCK_VOLUMES.Values) {
        $size = [int]($blockData -split '\|')[1]
        $totalBlockGb += $size
    }
    
    $totalStorage = $totalBootGb + $totalBlockGb
    
    Write-Host "Compute Resources:" -ForegroundColor White
    Write-Host "  ┌─────────────────────────────────────────────────────────────┐"
    Write-Host "  │ AMD Micro Instances:  $totalAmd / $($script:FREE_TIER_MAX_AMD_INSTANCES) (Free Tier limit)          │"
    Write-Host "  │ ARM A1 Instances:     $totalArm / $($script:FREE_TIER_MAX_ARM_INSTANCES) (up to)                    │"
    Write-Host "  │ ARM OCPUs Used:       $totalArmOcpus / $($script:FREE_TIER_MAX_ARM_OCPUS)                           │"
    Write-Host "  │ ARM Memory Used:      ${totalArmMemory}GB / $($script:FREE_TIER_MAX_ARM_MEMORY_GB)GB                         │"
    Write-Host "  └─────────────────────────────────────────────────────────────┘"
    Write-Host ""
    Write-Host "Storage Resources:" -ForegroundColor White
    Write-Host "  ┌─────────────────────────────────────────────────────────────┐"
    Write-Host "  │ Boot Volumes:         ${totalBootGb}GB                                    │"
    Write-Host "  │ Block Volumes:        ${totalBlockGb}GB                                    │"
    Write-Host "  │ Total Storage:        $($totalStorage.ToString().PadLeft(3))GB / $($script:FREE_TIER_MAX_STORAGE_GB.ToString().PadLeft(3))GB Free Tier limit          │"
    Write-Host "  └─────────────────────────────────────────────────────────────┘"
    Write-Host ""
    Write-Host "Networking Resources:" -ForegroundColor White
    Write-Host "  ┌─────────────────────────────────────────────────────────────┐"
    Write-Host "  │ VCNs:                 $($script:EXISTING_VCNS.Count) / $($script:FREE_TIER_MAX_VCNS) (Free Tier limit)             │"
    Write-Host "  │ Subnets:              $($script:EXISTING_SUBNETS.Count)                                       │"
    Write-Host "  │ Internet Gateways:    $($script:EXISTING_INTERNET_GATEWAYS.Count)                                       │"
    Write-Host "  └─────────────────────────────────────────────────────────────┘"
    Write-Host ""
    
    if ($totalAmd -ge $script:FREE_TIER_MAX_AMD_INSTANCES) {
        Write-Warning "AMD instance limit reached - cannot create more AMD instances"
    }
    if ($totalArmOcpus -ge $script:FREE_TIER_MAX_ARM_OCPUS) {
        Write-Warning "ARM OCPU limit reached - cannot allocate more ARM OCPUs"
    }
    if ($totalArmMemory -ge $script:FREE_TIER_MAX_ARM_MEMORY_GB) {
        Write-Warning "ARM memory limit reached - cannot allocate more ARM memory"
    }
    if ($totalStorage -ge $script:FREE_TIER_MAX_STORAGE_GB) {
        Write-Warning "Storage limit reached - cannot create more volumes"
    }
    if ($script:EXISTING_VCNS.Count -ge $script:FREE_TIER_MAX_VCNS) {
        Write-Warning "VCN limit reached - cannot create more VCNs"
    }
}

# ============================================================================
# FREE TIER LIMIT VALIDATION
# ============================================================================

function Get-AvailableResources {
    $usedAmd = $script:EXISTING_AMD_INSTANCES.Count
    $usedArmOcpus = 0
    $usedArmMemory = 0
    $usedStorage = 0
    
    foreach ($instanceData in $script:EXISTING_ARM_INSTANCES.Values) {
        $parts = $instanceData -split '\|'
        $usedArmOcpus += [int]$parts[5]
        $usedArmMemory += [int]$parts[6]
    }
    
    foreach ($bootData in $script:EXISTING_BOOT_VOLUMES.Values) {
        $size = [int]($bootData -split '\|')[1]
        $usedStorage += $size
    }
    
    foreach ($blockData in $script:EXISTING_BLOCK_VOLUMES.Values) {
        $size = [int]($blockData -split '\|')[1]
        $usedStorage += $size
    }
    
    $script:AVAILABLE_AMD_INSTANCES = $script:FREE_TIER_MAX_AMD_INSTANCES - $usedAmd
    $script:AVAILABLE_ARM_OCPUS = $script:FREE_TIER_MAX_ARM_OCPUS - $usedArmOcpus
    $script:AVAILABLE_ARM_MEMORY = $script:FREE_TIER_MAX_ARM_MEMORY_GB - $usedArmMemory
    $script:AVAILABLE_STORAGE = $script:FREE_TIER_MAX_STORAGE_GB - $usedStorage
    $script:USED_ARM_INSTANCES = $script:EXISTING_ARM_INSTANCES.Count
    
    Write-Debug "Available: AMD=$($script:AVAILABLE_AMD_INSTANCES), ARM_OCPU=$($script:AVAILABLE_ARM_OCPUS), ARM_MEM=$($script:AVAILABLE_ARM_MEMORY), Storage=$($script:AVAILABLE_STORAGE)"
}

function Test-ProposedConfig {
    param(
        [int]$ProposedAmd,
        [int]$ProposedArm,
        [int]$ProposedArmOcpus,
        [int]$ProposedArmMemory,
        [int]$ProposedStorage
    )
    
    $errors = 0
    
    if ($ProposedAmd -gt $script:AVAILABLE_AMD_INSTANCES) {
        Write-Error "Cannot create $ProposedAmd AMD instances - only $($script:AVAILABLE_AMD_INSTANCES) available"
        $errors++
    }
    
    if ($ProposedArmOcpus -gt $script:AVAILABLE_ARM_OCPUS) {
        Write-Error "Cannot allocate $ProposedArmOcpus ARM OCPUs - only $($script:AVAILABLE_ARM_OCPUS) available"
        $errors++
    }
    
    if ($ProposedArmMemory -gt $script:AVAILABLE_ARM_MEMORY) {
        Write-Error "Cannot allocate ${ProposedArmMemory}GB ARM memory - only $($script:AVAILABLE_ARM_MEMORY)GB available"
        $errors++
    }
    
    if ($ProposedStorage -gt $script:AVAILABLE_STORAGE) {
        Write-Error "Cannot use ${ProposedStorage}GB storage - only $($script:AVAILABLE_STORAGE)GB available"
        $errors++
    }
    
    return $errors -eq 0
}

# ============================================================================
# CONFIGURATION FUNCTIONS
# ============================================================================

function Read-ExistingConfig {
    if (-not (Test-Path "variables.tf")) {
        return $false
    }
    
    Write-Status "Loading existing configuration from variables.tf..."
    
    $content = Get-Content "variables.tf" -Raw
    
    if ($content -match 'amd_micro_instance_count\s*=\s*(\d+)') {
        $script:amd_micro_instance_count = [int]$matches[1]
    }
    
    if ($content -match 'amd_micro_boot_volume_size_gb\s*=\s*(\d+)') {
        $script:amd_micro_boot_volume_size_gb = [int]$matches[1]
    }
    
    if ($content -match 'arm_flex_instance_count\s*=\s*(\d+)') {
        $script:arm_flex_instance_count = [int]$matches[1]
    }
    
    if ($content -match 'arm_flex_ocpus_per_instance\s*=\s*\[([^\]]+)\]') {
        $ocpusStr = $matches[1]
        $script:arm_flex_ocpus_per_instance = ($ocpusStr -split ',') | ForEach-Object { [int]($_.Trim()) }
    }
    
    if ($content -match 'arm_flex_memory_per_instance\s*=\s*\[([^\]]+)\]') {
        $memoryStr = $matches[1]
        $script:arm_flex_memory_per_instance = ($memoryStr -split ',') | ForEach-Object { [int]($_.Trim()) }
    }
    
    if ($content -match 'arm_flex_boot_volume_size_gb\s*=\s*\[([^\]]+)\]') {
        $bootStr = $matches[1]
        $script:arm_flex_boot_volume_size_gb = ($bootStr -split ',') | ForEach-Object { [int]($_.Trim()) }
    }
    
    if ($content -match 'amd_micro_hostnames\s*=\s*\[([^\]]+)\]') {
        $hostnamesStr = $matches[1]
        $script:amd_micro_hostnames = ($hostnamesStr -split ',') | ForEach-Object { $_.Trim() -replace '"', '' }
    }
    
    if ($content -match 'arm_flex_hostnames\s*=\s*\[([^\]]+)\]') {
        $hostnamesStr = $matches[1]
        $script:arm_flex_hostnames = ($hostnamesStr -split ',') | ForEach-Object { $_.Trim() -replace '"', '' }
    }
    
    Write-Success "Loaded configuration: $($script:amd_micro_instance_count)x AMD, $($script:arm_flex_instance_count)x ARM"
    return $true
}

function Request-Configuration {
    Write-Header "INSTANCE CONFIGURATION"
    
    Get-AvailableResources
    
    Write-Host "Available Free Tier Resources:" -ForegroundColor White
    Write-Host "  • AMD instances:  $($script:AVAILABLE_AMD_INSTANCES) available (max $($script:FREE_TIER_MAX_AMD_INSTANCES))"
    Write-Host "  • ARM OCPUs:      $($script:AVAILABLE_ARM_OCPUS) available (max $($script:FREE_TIER_MAX_ARM_OCPUS))"
    Write-Host "  • ARM Memory:     $($script:AVAILABLE_ARM_MEMORY)GB available (max $($script:FREE_TIER_MAX_ARM_MEMORY_GB)GB)"
    Write-Host "  • Storage:        $($script:AVAILABLE_STORAGE)GB available (max $($script:FREE_TIER_MAX_STORAGE_GB)GB)"
    Write-Host ""
    
    $hasExistingConfig = Read-ExistingConfig
    
    Write-Status "Configuration options:"
    Write-Host "  1) Use existing instances (manage what's already deployed)"
    if ($hasExistingConfig) {
        Write-Host "  2) Use saved configuration from variables.tf"
    } else {
        Write-Host "  2) Use saved configuration from variables.tf (not available)"
    }
    Write-Host "  3) Configure new instances (respecting Free Tier limits)"
    Write-Host "  4) Maximum Free Tier configuration (use all available resources)"
    Write-Host ""
    
    if ($script:AutoUseExisting) {
        $choice = 1
        Write-Status "Auto mode: Using existing instances"
    } elseif ($script:NonInteractive) {
        $choice = 1
        Write-Status "Non-interactive mode: Using existing instances"
    } else {
        $rawChoice = Read-Host "Choose configuration (1-4) [1]"
        if ([string]::IsNullOrWhiteSpace($rawChoice)) { $rawChoice = "1" }
        if (-not ([int]::TryParse($rawChoice, [ref]$choice)) -or $choice -lt 1 -or $choice -gt 4) {
            Write-Error "Please enter a number between 1 and 4 (received: '$rawChoice')"
            return
        }
    }
    
    switch ($choice) {
        1 {
            Set-ConfigurationFromExistingInstances
        }
        2 {
            if ($hasExistingConfig) {
                Write-Success "Using saved configuration"
            } else {
                Write-Error "No saved configuration available"
                Request-Configuration
            }
        }
        3 {
            Set-CustomInstancesConfiguration
        }
        4 {
            Set-MaximumFreeTierConfiguration
        }
    }
}

function Set-ConfigurationFromExistingInstances {
    Write-Status "Configuring based on existing instances..."
    
    $script:amd_micro_instance_count = $script:EXISTING_AMD_INSTANCES.Count
    $script:amd_micro_hostnames = @()
    
    foreach ($instanceData in $script:EXISTING_AMD_INSTANCES.Values) {
        $name = ($instanceData -split '\|')[0]
        $script:amd_micro_hostnames += $name
    }
    
    $script:arm_flex_instance_count = $script:EXISTING_ARM_INSTANCES.Count
    $script:arm_flex_hostnames = @()
    $script:arm_flex_ocpus_per_instance = @()
    $script:arm_flex_memory_per_instance = @()
    $script:arm_flex_boot_volume_size_gb = @()
    $script:arm_flex_block_volumes = @()
    
    foreach ($instanceData in $script:EXISTING_ARM_INSTANCES.Values) {
        $parts = $instanceData -split '\|'
        $script:arm_flex_hostnames += $parts[0]
        $script:arm_flex_ocpus_per_instance += [int]$parts[5]
        $script:arm_flex_memory_per_instance += [int]$parts[6]
        $script:arm_flex_boot_volume_size_gb += 50
        $script:arm_flex_block_volumes += 0
    }
    
    if ($script:amd_micro_instance_count -eq 0 -and $script:arm_flex_instance_count -eq 0) {
        Write-Status "No existing instances found, using default configuration"
        $script:amd_micro_instance_count = 0
        $script:arm_flex_instance_count = 1
        $script:arm_flex_ocpus_per_instance = @(4)
        $script:arm_flex_memory_per_instance = @(24)
        $script:arm_flex_boot_volume_size_gb = @(200)
        $script:arm_flex_hostnames = @("arm-instance-1")
        $script:arm_flex_block_volumes = @(0)
    }
    
    $script:amd_micro_boot_volume_size_gb = 50
    
    Write-Success "Configuration: $($script:amd_micro_instance_count)x AMD, $($script:arm_flex_instance_count)x ARM"
}

function Set-CustomInstancesConfiguration {
    Write-Status "Custom instance configuration..."
    
    $maxAmd = $script:AVAILABLE_AMD_INSTANCES
    $amdPrompt = "Number of AMD instances (0-$maxAmd) [0]"
    $amdInput = Read-Host $amdPrompt
    if ([string]::IsNullOrWhiteSpace($amdInput)) { $amdInput = "0" }
    $script:amd_micro_instance_count = [Math]::Max(0, [Math]::Min([int]$amdInput, $maxAmd))
    
    $script:amd_micro_hostnames = @()
    if ($script:amd_micro_instance_count -gt 0) {
        $bootPrompt = "AMD boot volume size GB (50-100) [50]"
        $bootInput = Read-Host $bootPrompt
        if ([string]::IsNullOrWhiteSpace($bootInput)) { $bootInput = "50" }
        $script:amd_micro_boot_volume_size_gb = [Math]::Max(50, [Math]::Min([int]$bootInput, 100))
        
        for ($i = 1; $i -le $script:amd_micro_instance_count; $i++) {
            $hostnamePrompt = "Hostname for AMD instance $i [amd-instance-$i]"
            $hostname = Read-Host $hostnamePrompt
            if ([string]::IsNullOrWhiteSpace($hostname)) { $hostname = "amd-instance-$i" }
            $script:amd_micro_hostnames += $hostname
        }
    } else {
        $script:amd_micro_boot_volume_size_gb = 50
    }
    
    if ($script:ubuntu_arm_flex_image_ocid -and $script:AVAILABLE_ARM_OCPUS -gt 0) {
        $armPrompt = "Number of ARM instances (0-4) [1]"
        $armInput = Read-Host $armPrompt
        if ([string]::IsNullOrWhiteSpace($armInput)) { $armInput = "1" }
        $script:arm_flex_instance_count = [Math]::Max(0, [Math]::Min([int]$armInput, 4))
        
        $script:arm_flex_hostnames = @()
        $script:arm_flex_ocpus_per_instance = @()
        $script:arm_flex_memory_per_instance = @()
        $script:arm_flex_boot_volume_size_gb = @()
        $script:arm_flex_block_volumes = @()
        
        $remainingOcpus = $script:AVAILABLE_ARM_OCPUS
        $remainingMemory = $script:AVAILABLE_ARM_MEMORY
        
        for ($i = 1; $i -le $script:arm_flex_instance_count; $i++) {
            Write-Host ""
            Write-Status "ARM instance $i configuration (remaining: ${remainingOcpus} OCPUs, ${remainingMemory}GB RAM):"
            
            $hostnamePrompt = "  Hostname [arm-instance-$i]"
            $hostname = Read-Host $hostnamePrompt
            if ([string]::IsNullOrWhiteSpace($hostname)) { $hostname = "arm-instance-$i" }
            $script:arm_flex_hostnames += $hostname
            
            $ocpusPrompt = "  OCPUs (1-$remainingOcpus) [$remainingOcpus]"
            $ocpusInput = Read-Host $ocpusPrompt
            if ([string]::IsNullOrWhiteSpace($ocpusInput)) { $ocpusInput = "$remainingOcpus" }
            $ocpus = [Math]::Max(1, [Math]::Min([int]$ocpusInput, $remainingOcpus))
            $script:arm_flex_ocpus_per_instance += $ocpus
            $remainingOcpus -= $ocpus
            
            $maxMemory = [Math]::Min($ocpus * 6, $remainingMemory)
            $memoryPrompt = "  Memory GB (1-$maxMemory) [$maxMemory]"
            $memoryInput = Read-Host $memoryPrompt
            if ([string]::IsNullOrWhiteSpace($memoryInput)) { $memoryInput = "$maxMemory" }
            $memory = [Math]::Max(1, [Math]::Min([int]$memoryInput, $maxMemory))
            $script:arm_flex_memory_per_instance += $memory
            $remainingMemory -= $memory
            
            $bootPrompt = "  Boot volume GB (50-200) [50]"
            $bootInput = Read-Host $bootPrompt
            if ([string]::IsNullOrWhiteSpace($bootInput)) { $bootInput = "50" }
            $boot = [Math]::Max(50, [Math]::Min([int]$bootInput, 200))
            $script:arm_flex_boot_volume_size_gb += $boot
            
            $script:arm_flex_block_volumes += 0
        }
    } else {
        $script:arm_flex_instance_count = 0
        $script:arm_flex_ocpus_per_instance = @()
        $script:arm_flex_memory_per_instance = @()
        $script:arm_flex_boot_volume_size_gb = @()
        $script:arm_flex_block_volumes = @()
        $script:arm_flex_hostnames = @()
    }
}

function Set-MaximumFreeTierConfiguration {
    Write-Status "Configuring maximum Free Tier utilization..."
    
    $script:amd_micro_instance_count = $script:AVAILABLE_AMD_INSTANCES
    $script:amd_micro_boot_volume_size_gb = 50
    $script:amd_micro_hostnames = @()
    for ($i = 1; $i -le $script:amd_micro_instance_count; $i++) {
        $script:amd_micro_hostnames += "amd-instance-$i"
    }
    
    if ($script:ubuntu_arm_flex_image_ocid -and $script:AVAILABLE_ARM_OCPUS -gt 0) {
        $script:arm_flex_instance_count = 1
        $script:arm_flex_ocpus_per_instance = @($script:AVAILABLE_ARM_OCPUS)
        $script:arm_flex_memory_per_instance = @($script:AVAILABLE_ARM_MEMORY)
        
        $usedByAmd = $script:amd_micro_instance_count * $script:amd_micro_boot_volume_size_gb
        $remainingStorage = $script:AVAILABLE_STORAGE - $usedByAmd
        if ($remainingStorage -lt $script:FREE_TIER_MIN_BOOT_VOLUME_GB) {
            $remainingStorage = $script:FREE_TIER_MIN_BOOT_VOLUME_GB
        }
        
        $script:arm_flex_boot_volume_size_gb = @($remainingStorage)
        $script:arm_flex_hostnames = @("arm-instance-1")
        $script:arm_flex_block_volumes = @(0)
    } else {
        $script:arm_flex_instance_count = 0
        $script:arm_flex_ocpus_per_instance = @()
        $script:arm_flex_memory_per_instance = @()
        $script:arm_flex_boot_volume_size_gb = @()
        $script:arm_flex_hostnames = @()
        $script:arm_flex_block_volumes = @()
    }
    
    Write-Success "Maximum config: $($script:amd_micro_instance_count)x AMD, $($script:arm_flex_instance_count)x ARM ($($script:AVAILABLE_ARM_OCPUS) OCPUs, $($script:AVAILABLE_ARM_MEMORY)GB)"
}

# ============================================================================
# TERRAFORM FILE GENERATION
# ============================================================================

function New-TerraformFiles {
    Write-Header "GENERATING TERRAFORM FILES"
    
    New-TerraformProvider
    New-TerraformVariables
    New-TerraformDatasources
    New-TerraformMain
    New-TerraformBlockVolumes
    New-CloudInit
    
    Write-Success "All Terraform files generated successfully"
}

function New-TerraformProvider {
    Write-Status "Creating provider.tf..."
    
    if (Test-Path "provider.tf") {
        $backupPath = "provider.tf.bak.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Copy-Item "provider.tf" $backupPath
    }
    
    $providerContent = @"
# Terraform Provider Configuration for Oracle Cloud Infrastructure
# Generated: $(Get-Date)
# Region: $script:region

terraform {
  required_version = ">= 1.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }
}

# OCI Provider with session token authentication
provider "oci" {
  auth                = "SecurityToken"
  config_file_profile = "DEFAULT"
  region              = "$script:region"
}
"@
    
    Set-Content -Path "provider.tf" -Value $providerContent
    Write-Success "provider.tf created"
}

function New-TerraformVariables {
    Write-Status "Creating variables.tf..."
    
    if (Test-Path "variables.tf") {
        $backupPath = "variables.tf.bak.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Copy-Item "variables.tf" $backupPath
    }
    
    $amdHostnamesTf = "[$($script:amd_micro_hostnames | ForEach-Object { "`"$_`"" } -join ', ')]"
    $armHostnamesTf = "[$($script:arm_flex_hostnames | ForEach-Object { "`"$_`"" } -join ', ')]"
    
    $armOcpusTf = "[$($script:arm_flex_ocpus_per_instance -join ', ')]"
    $armMemoryTf = "[$($script:arm_flex_memory_per_instance -join ', ')]"
    $armBootTf = "[$($script:arm_flex_boot_volume_size_gb -join ', ')]"
    $armBlockTf = "[$($script:arm_flex_block_volumes -join ', ')]"
    
    $variablesContent = @"
# Oracle Cloud Infrastructure Terraform Variables
# Generated: $(Get-Date)
# Configuration: $($script:amd_micro_instance_count)x AMD + $($script:arm_flex_instance_count)x ARM instances

locals {
  # Core identifiers
  tenancy_ocid    = "$script:tenancy_ocid"
  compartment_id  = "$script:tenancy_ocid"
  user_ocid       = "$script:user_ocid"
  region          = "$script:region"
  
  # Ubuntu Images (region-specific)
  ubuntu_x86_image_ocid = "$script:ubuntu_image_ocid"
  ubuntu_arm_image_ocid = "$script:ubuntu_arm_flex_image_ocid"
  
  # SSH Configuration
  ssh_pubkey_path      = pathexpand("./ssh_keys/id_rsa.pub")
  ssh_pubkey_data      = file(pathexpand("./ssh_keys/id_rsa.pub"))
  ssh_private_key_path = pathexpand("./ssh_keys/id_rsa")
  
  # AMD x86 Micro Instances Configuration
  amd_micro_instance_count      = $script:amd_micro_instance_count
  amd_micro_boot_volume_size_gb = $script:amd_micro_boot_volume_size_gb
  amd_micro_hostnames           = $amdHostnamesTf
  amd_block_volume_size_gb      = 0
  
  # ARM A1 Flex Instances Configuration
  arm_flex_instance_count       = $script:arm_flex_instance_count
  arm_flex_ocpus_per_instance   = $armOcpusTf
  arm_flex_memory_per_instance  = $armMemoryTf
  arm_flex_boot_volume_size_gb  = $armBootTf
  arm_flex_hostnames            = $armHostnamesTf
  arm_block_volume_sizes        = $armBlockTf
  
  # Storage calculations
  total_amd_storage = local.amd_micro_instance_count * local.amd_micro_boot_volume_size_gb
  total_arm_storage = local.arm_flex_instance_count > 0 ? sum(local.arm_flex_boot_volume_size_gb) : 0
  total_block_storage = (local.amd_micro_instance_count * local.amd_block_volume_size_gb) + (local.arm_flex_instance_count > 0 ? sum(local.arm_block_volume_sizes) : 0)
  total_storage = local.total_amd_storage + local.total_arm_storage + local.total_block_storage
}

# Free Tier Limits
variable "free_tier_max_storage_gb" {
  description = "Maximum storage for Oracle Free Tier"
  type        = number
  default     = $script:FREE_TIER_MAX_STORAGE_GB
}

variable "free_tier_max_arm_ocpus" {
  description = "Maximum ARM OCPUs for Oracle Free Tier"
  type        = number
  default     = $script:FREE_TIER_MAX_ARM_OCPUS
}

variable "free_tier_max_arm_memory_gb" {
  description = "Maximum ARM memory for Oracle Free Tier"
  type        = number
  default     = $script:FREE_TIER_MAX_ARM_MEMORY_GB
}

# Validation checks
check "storage_limit" {
  assert {
    condition     = local.total_storage <= var.free_tier_max_storage_gb
    error_message = "Total storage (`${local.total_storage}GB) exceeds Free Tier limit (`${var.free_tier_max_storage_gb}GB)"
  }
}

check "arm_ocpu_limit" {
  assert {
    condition     = local.arm_flex_instance_count == 0 || sum(local.arm_flex_ocpus_per_instance) <= var.free_tier_max_arm_ocpus
    error_message = "Total ARM OCPUs exceed Free Tier limit (`${var.free_tier_max_arm_ocpus})"
  }
}

check "arm_memory_limit" {
  assert {
    condition     = local.arm_flex_instance_count == 0 || sum(local.arm_flex_memory_per_instance) <= var.free_tier_max_arm_memory_gb
    error_message = "Total ARM memory exceeds Free Tier limit (`${var.free_tier_max_arm_memory_gb}GB)"
  }
}
"@
    
    Set-Content -Path "variables.tf" -Value $variablesContent
    Write-Success "variables.tf created"
}

function New-TerraformDatasources {
    Write-Status "Creating data_sources.tf..."
    
    if (Test-Path "data_sources.tf") {
        $backupPath = "data_sources.tf.bak.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Copy-Item "data_sources.tf" $backupPath
    }
    
    $datasourcesContent = @'
# OCI Data Sources
# Fetches dynamic information from Oracle Cloud

# Availability Domains
data "oci_identity_availability_domains" "ads" {
  compartment_id = local.tenancy_ocid
}

# Tenancy Information
data "oci_identity_tenancy" "tenancy" {
  tenancy_id = local.tenancy_ocid
}

# Available Regions
data "oci_identity_regions" "regions" {}

# Region Subscriptions
data "oci_identity_region_subscriptions" "subscriptions" {
  tenancy_id = local.tenancy_ocid
}
'@
    
    Set-Content -Path "data_sources.tf" -Value $datasourcesContent
    Write-Success "data_sources.tf created"
}

function New-TerraformMain {
    Write-Status "Creating main.tf..."
    
    if (Test-Path "main.tf") {
        $backupPath = "main.tf.bak.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Copy-Item "main.tf" $backupPath
    }
    
    # Read the main.tf template from the bash script equivalent
    $mainContent = Get-Content (Join-Path $PSScriptRoot "main.tf.template") -ErrorAction SilentlyContinue
    if (-not $mainContent) {
        # Generate inline if template doesn't exist
        $mainContent = @'
# Oracle Cloud Infrastructure - Main Configuration
# Always Free Tier Optimized

# ============================================================================
# NETWORKING
# ============================================================================

resource "oci_core_vcn" "main" {
  compartment_id = local.compartment_id
  cidr_blocks    = ["10.0.0.0/16"]
  display_name   = "main-vcn"
  dns_label      = "mainvcn"
  is_ipv6enabled = true
  
  freeform_tags = {
    "Purpose" = "AlwaysFreeTier"
    "Managed" = "Terraform"
  }
}

resource "oci_core_internet_gateway" "main" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "main-igw"
  enabled        = true
}

resource "oci_core_default_route_table" "main" {
  manage_default_resource_id = oci_core_vcn.main.default_route_table_id
  display_name               = "main-rt"
  
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }
  
  route_rules {
    destination       = "::/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }
}

resource "oci_core_default_security_list" "main" {
  manage_default_resource_id = oci_core_vcn.main.default_security_list_id
  display_name               = "main-sl"
  
  # Allow all egress
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }
  
  egress_security_rules {
    destination = "::/0"
    protocol    = "all"
  }
  
  # SSH (IPv4)
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 22
      max = 22
    }
  }
  # SSH (IPv6)
  ingress_security_rules {
    protocol = "6"
    source   = "::/0"
    tcp_options {
      min = 22
      max = 22
    }
  }
  
  # HTTP (IPv4)
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 80
      max = 80
    }
  }
  # HTTP (IPv6)
  ingress_security_rules {
    protocol = "6"
    source   = "::/0"
    tcp_options {
      min = 80
      max = 80
    }
  }
  
  # HTTPS (IPv4)
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 443
      max = 443
    }
  }
  # HTTPS (IPv6)
  ingress_security_rules {
    protocol = "6"
    source   = "::/0"
    tcp_options {
      min = 443
      max = 443
    }
  }
  
  # ICMP (IPv4)
  ingress_security_rules {
    protocol = "1"
    source   = "0.0.0.0/0"
  }
  # ICMP (IPv6)
  ingress_security_rules {
    protocol = "1"
    source   = "::/0"
  }
}

resource "oci_core_subnet" "main" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.main.id
  cidr_block     = "10.0.1.0/24"
  display_name   = "main-subnet"
  dns_label      = "mainsubnet"
  
  route_table_id    = oci_core_default_route_table.main.id
  security_list_ids = [oci_core_default_security_list.main.id]
  
  # IPv6 - use first /64 block from VCN's /56
  ipv6cidr_blocks = [cidrsubnet(oci_core_vcn.main.ipv6cidr_blocks[0], 8, 0)]
}

# ============================================================================
# COMPUTE INSTANCES
# ============================================================================

# AMD x86 Micro Instances
resource "oci_core_instance" "amd" {
  count = local.amd_micro_instance_count
  
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.compartment_id
  display_name        = local.amd_micro_hostnames[count.index]
  shape               = "VM.Standard.E2.1.Micro"
  
  create_vnic_details {
    subnet_id        = oci_core_subnet.main.id
    display_name     = "${local.amd_micro_hostnames[count.index]}-vnic"
    assign_public_ip = true
    assign_ipv6ip    = true
    hostname_label   = local.amd_micro_hostnames[count.index]
  }
  
  source_details {
    source_type             = "image"
    source_id               = local.ubuntu_x86_image_ocid
    boot_volume_size_in_gbs = local.amd_micro_boot_volume_size_gb
  }
  
  metadata = {
    ssh_authorized_keys = local.ssh_pubkey_data
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
      hostname = local.amd_micro_hostnames[count.index]
    }))
  }
  
  freeform_tags = {
    "Purpose"      = "AlwaysFreeTier"
    "InstanceType" = "AMD-Micro"
    "Managed"      = "Terraform"
  }
  
  lifecycle {
    ignore_changes = [
      source_details[0].source_id,  # Ignore image updates
      defined_tags,
    ]
  }
}

# ARM A1 Flex Instances
resource "oci_core_instance" "arm" {
  count = local.arm_flex_instance_count
  
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.compartment_id
  display_name        = local.arm_flex_hostnames[count.index]
  shape               = "VM.Standard.A1.Flex"
  
  shape_config {
    ocpus         = local.arm_flex_ocpus_per_instance[count.index]
    memory_in_gbs = local.arm_flex_memory_per_instance[count.index]
  }
  
  create_vnic_details {
    subnet_id        = oci_core_subnet.main.id
    display_name     = "${local.arm_flex_hostnames[count.index]}-vnic"
    assign_public_ip = true
    assign_ipv6ip    = true
    hostname_label   = local.arm_flex_hostnames[count.index]
  }
  
  source_details {
    source_type             = "image"
    source_id               = local.ubuntu_arm_image_ocid
    boot_volume_size_in_gbs = local.arm_flex_boot_volume_size_gb[count.index]
  }
  
  metadata = {
    ssh_authorized_keys = local.ssh_pubkey_data
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
      hostname = local.arm_flex_hostnames[count.index]
    }))
  }
  
  freeform_tags = {
    "Purpose"      = "AlwaysFreeTier"
    "InstanceType" = "ARM-A1-Flex"
    "Managed"      = "Terraform"
  }
  
  lifecycle {
    ignore_changes = [
      source_details[0].source_id,
      defined_tags,
    ]
  }
}

# ============================================================================
# PER-INSTANCE IPv6: Reserve an IPv6 for each instance VNIC
# ============================================================================

data "oci_core_vnic_attachments" "amd_vnics" {
  count = local.amd_micro_instance_count
  compartment_id = local.compartment_id
  instance_id    = oci_core_instance.amd[count.index].id
}

resource "oci_core_ipv6" "amd_ipv6" {
  count = local.amd_micro_instance_count
  vnic_id = data.oci_core_vnic_attachments.amd_vnics[count.index].vnic_attachments[0].vnic_id
  lifetime = "RESERVED"
  subnet_id = oci_core_subnet.main.id
  route_table_id = oci_core_default_route_table.main.id
  display_name = "amd-${local.amd_micro_hostnames[count.index]}-ipv6"
  freeform_tags = {
    "Purpose" = "AlwaysFreeTier"
    "Managed" = "Terraform"
  }
}

data "oci_core_vnic_attachments" "arm_vnics" {
  count = local.arm_flex_instance_count
  compartment_id = local.compartment_id
  instance_id    = oci_core_instance.arm[count.index].id
}

resource "oci_core_ipv6" "arm_ipv6" {
  count = local.arm_flex_instance_count
  vnic_id = data.oci_core_vnic_attachments.arm_vnics[count.index].vnic_attachments[0].vnic_id
  lifetime = "RESERVED"
  subnet_id = oci_core_subnet.main.id
  route_table_id = oci_core_default_route_table.main.id
  display_name = "arm-${local.arm_flex_hostnames[count.index]}-ipv6"
  freeform_tags = {
    "Purpose" = "AlwaysFreeTier"
    "Managed" = "Terraform"
  }
}

# ============================================================================
# OUTPUTS
# ============================================================================

output "amd_instances" {
  description = "AMD instance information"
  value = local.amd_micro_instance_count > 0 ? {
    for i in range(local.amd_micro_instance_count) : local.amd_micro_hostnames[i] => {
      id         = oci_core_instance.amd[i].id
      public_ip  = oci_core_instance.amd[i].public_ip
      private_ip = oci_core_instance.amd[i].private_ip
      ipv6       = oci_core_ipv6.amd_ipv6[i].ip_address
      state      = oci_core_instance.amd[i].state
      ssh        = "ssh -i ./ssh_keys/id_rsa ubuntu@${oci_core_instance.amd[i].public_ip}"
    }
  } : {}
}

output "arm_instances" {
  description = "ARM instance information"
  value = local.arm_flex_instance_count > 0 ? {
    for i in range(local.arm_flex_instance_count) : local.arm_flex_hostnames[i] => {
      id         = oci_core_instance.arm[i].id
      public_ip  = oci_core_instance.arm[i].public_ip
      private_ip = oci_core_instance.arm[i].private_ip
      ipv6       = oci_core_ipv6.arm_ipv6[i].ip_address
      state      = oci_core_instance.arm[i].state
      ocpus      = local.arm_flex_ocpus_per_instance[i]
      memory_gb  = local.arm_flex_memory_per_instance[i]
      ssh        = "ssh -i ./ssh_keys/id_rsa ubuntu@${oci_core_instance.arm[i].public_ip}"
    }
  } : {}
}

output "network" {
  description = "Network information"
  value = {
    vcn_id     = oci_core_vcn.main.id
    vcn_cidr   = oci_core_vcn.main.cidr_blocks[0]
    subnet_id  = oci_core_subnet.main.id
    subnet_cidr = oci_core_subnet.main.cidr_block
  }
}

output "summary" {
  description = "Infrastructure summary"
  value = {
    region          = local.region
    total_amd       = local.amd_micro_instance_count
    total_arm       = local.arm_flex_instance_count
    total_storage   = local.total_storage
    free_tier_limit = 200
  }
}
'@
    }
    
    Set-Content -Path "main.tf" -Value $mainContent
    Write-Success "main.tf created"
}

function New-TerraformBlockVolumes {
    Write-Status "Creating block_volumes.tf..."
    
    if (Test-Path "block_volumes.tf") {
        $backupPath = "block_volumes.tf.bak.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Copy-Item "block_volumes.tf" $backupPath
    }
    
    $blockVolumesContent = @'
# Block Volume Resources (Optional)
# Block volumes provide additional storage beyond boot volumes

# AMD Block Volumes
resource "oci_core_volume" "amd_block" {
  count = local.amd_block_volume_size_gb > 0 ? local.amd_micro_instance_count : 0
  
  compartment_id      = local.compartment_id
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "${local.amd_micro_hostnames[count.index]}-block"
  size_in_gbs         = local.amd_block_volume_size_gb
  
  freeform_tags = {
    "Purpose" = "AlwaysFreeTier"
    "Type"    = "BlockVolume"
    "Managed" = "Terraform"
  }
}

resource "oci_core_volume_attachment" "amd_block" {
  count = local.amd_block_volume_size_gb > 0 ? local.amd_micro_instance_count : 0
  
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.amd[count.index].id
  volume_id       = oci_core_volume.amd_block[count.index].id
}

# ARM Block Volumes
resource "oci_core_volume" "arm_block" {
  count = local.arm_flex_instance_count > 0 ? length([for s in local.arm_block_volume_sizes : s if s > 0]) : 0
  
  compartment_id      = local.compartment_id
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "${local.arm_flex_hostnames[count.index]}-block"
  size_in_gbs         = [for s in local.arm_block_volume_sizes : s if s > 0][count.index]
  
  freeform_tags = {
    "Purpose" = "AlwaysFreeTier"
    "Type"    = "BlockVolume"
    "Managed" = "Terraform"
  }
}

resource "oci_core_volume_attachment" "arm_block" {
  count = local.arm_flex_instance_count > 0 ? length([for s in local.arm_block_volume_sizes : s if s > 0]) : 0
  
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.arm[count.index].id
  volume_id       = oci_core_volume.arm_block[count.index].id
}
'@
    
    Set-Content -Path "block_volumes.tf" -Value $blockVolumesContent
    Write-Success "block_volumes.tf created"
}

function New-CloudInit {
    Write-Status "Creating cloud-init.yaml..."
    
    if (Test-Path "cloud-init.yaml") {
        $backupPath = "cloud-init.yaml.bak.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Copy-Item "cloud-init.yaml" $backupPath
    }
    
    $cloudInitContent = @'
#cloud-config
hostname: ${hostname}
fqdn: ${hostname}.local
manage_etc_hosts: true

package_update: true
package_upgrade: true

packages:
  - curl
  - wget
  - git
  - htop
  - vim
  - unzip
  - jq
  - tmux
  - net-tools
  - iotop
  - ncdu

runcmd:
  - echo "Instance ${hostname} initialized at $(date)" >> /var/log/cloud-init-complete.log
  - systemctl enable --now fail2ban || true

# Basic security hardening
write_files:
  - path: /etc/ssh/sshd_config.d/hardening.conf
    content: |
      PermitRootLogin no
      PasswordAuthentication no
      MaxAuthTries 3
      ClientAliveInterval 300
      ClientAliveCountMax 2

timezone: UTC
ssh_pwauth: false

final_message: "Instance ${hostname} ready after $UPTIME seconds"
'@
    
    Set-Content -Path "cloud-init.yaml" -Value $cloudInitContent
    Write-Success "cloud-init.yaml created"
}

# ============================================================================
# TERRAFORM WORKFLOW
# ============================================================================

function Start-TerraformWorkflow {
    Write-Header "TERRAFORM WORKFLOW"
    
    Write-Status "Step 1: Initializing Terraform..."
    $initResult = Invoke-RetryWithBackoff { terraform init -input=false -upgrade 2>&1 | Out-String }
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Terraform init failed after retries"
        return $false
    }
    Write-Success "Terraform initialized"
    
    if ($script:EXISTING_VCNS.Count -gt 0 -or $script:EXISTING_AMD_INSTANCES.Count -gt 0 -or $script:EXISTING_ARM_INSTANCES.Count -gt 0) {
        Write-Status "Step 2: Importing existing resources..."
        Import-ExistingResources
    } else {
        Write-Status "Step 2: No existing resources to import"
    }
    
    Write-Status "Step 3: Validating configuration..."
    $validateResult = terraform validate 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Terraform validation failed"
        return $false
    }
    Write-Success "Configuration valid"
    
    Write-Status "Step 4: Creating execution plan..."
    $planResult = terraform plan -out=tfplan -input=false 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Terraform plan failed"
        return $false
    }
    Write-Success "Plan created successfully"
    
    Write-Host ""
    Write-Status "Plan summary:"
    terraform show -no-color tfplan | Select-String -Pattern "^(Plan:|  #|will be)" | Select-Object -First 20
    Write-Host ""
    
    if ($script:AutoDeploy -or $script:NonInteractive) {
        Write-Status "Step 5: Auto-applying plan..."
        $applyChoice = "Y"
    } else {
        $applyChoice = Read-Host "Apply this plan? [y/N]"
        if ([string]::IsNullOrWhiteSpace($applyChoice)) { $applyChoice = "N" }
    }
    
    if ($applyChoice -match "^[Yy]$") {
        Write-Status "Applying Terraform plan..."
        $applyResult = Start-OutOfCapacityAutoApply
        if ($applyResult) {
            Write-Success "Infrastructure deployed successfully!"
            Remove-Item "tfplan" -ErrorAction SilentlyContinue
            
            Write-Host ""
            Write-Header "DEPLOYMENT COMPLETE"
            $output = terraform output -json 2>&1
            if ($output) {
                try {
                    $outputObj = $output | ConvertFrom-Json
                    $outputObj | ConvertTo-Json -Depth 10
                } catch {
                    terraform output
                }
            } else {
                terraform output
            }
            return $true
        } else {
            Write-Error "Terraform apply failed"
            return $false
        }
    } else {
        Write-Status "Plan saved as 'tfplan' - apply later with: terraform apply tfplan"
    }
    
    return $true
}

function Start-OutOfCapacityAutoApply {
    Write-Status "Auto-retrying terraform apply until success or max attempts ($($script:RETRY_MAX_ATTEMPTS))..."
    $attempt = 1
    
    while ($attempt -le $script:RETRY_MAX_ATTEMPTS) {
        Write-Status "Apply attempt $attempt/$($script:RETRY_MAX_ATTEMPTS)"
        
        $applyOutput = terraform apply -input=false tfplan 2>&1 | Out-String
        
        if ($LASTEXITCODE -eq 0) {
            Write-Success "terraform apply succeeded"
            return $true
        }
        
        if ($applyOutput -match "out of capacity|out of host capacity|OutOfCapacity|OutOfHostCapacity") {
            Write-Warning "Apply failed with 'Out of Capacity' - will retry"
        } else {
            Write-Error "terraform apply failed with non-retryable error"
            Write-Host $applyOutput
            return $false
        }
        
        if ($attempt -lt $script:RETRY_MAX_ATTEMPTS) {
            $sleepTime = $script:RETRY_BASE_DELAY * [Math]::Pow(2, $attempt - 1)
            Write-Status "Waiting ${sleepTime}s before retrying..."
            Start-Sleep -Seconds $sleepTime
        }
        
        $attempt++
    }
    
    Write-Error "terraform apply did not succeed after $($script:RETRY_MAX_ATTEMPTS) attempts"
    return $false
}

function Import-ExistingResources {
    Write-Header "IMPORTING EXISTING RESOURCES"
    
    if ($script:EXISTING_VCNS.Count -eq 0 -and $script:EXISTING_AMD_INSTANCES.Count -eq 0 -and $script:EXISTING_ARM_INSTANCES.Count -eq 0) {
        Write-Status "No existing resources to import"
        return
    }
    
    Write-Status "Initializing Terraform..."
    $initResult = Invoke-RetryWithBackoff { terraform init -input=false 2>&1 | Out-String }
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Terraform init failed after retries"
        return
    }
    
    $imported = 0
    $failed = 0
    
    if ($script:EXISTING_VCNS.Count -gt 0) {
        $firstVcnId = ($script:EXISTING_VCNS.Keys | Select-Object -First 1)
        $vcnName = ($script:EXISTING_VCNS[$firstVcnId] -split '\|')[0]
        Write-Status "Importing VCN: $vcnName"
        
        $stateCheck = terraform state show "oci_core_vcn.main" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Status "  Already in state"
        } else {
            $importResult = Invoke-RetryWithBackoff { terraform import "oci_core_vcn.main" "`"$firstVcnId`"" 2>&1 | Out-String }
            if ($LASTEXITCODE -eq 0) {
                Write-Success "  Imported successfully"
                $imported++
                Import-VcnComponents $firstVcnId
            } else {
                Write-Warning "  Failed to import (see logs above)"
                $failed++
            }
        }
    }
    
    $amdIndex = 0
    foreach ($instanceId in $script:EXISTING_AMD_INSTANCES.Keys) {
        $instanceName = ($script:EXISTING_AMD_INSTANCES[$instanceId] -split '\|')[0]
        Write-Status "Importing AMD instance: $instanceName"
        
        $stateCheck = terraform state show "oci_core_instance.amd[$amdIndex]" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Status "  Already in state"
        } else {
            $importResult = Invoke-RetryWithBackoff { terraform import "oci_core_instance.amd[$amdIndex]" "`"$instanceId`"" 2>&1 | Out-String }
            if ($LASTEXITCODE -eq 0) {
                Write-Success "  Imported successfully"
                $imported++
            } else {
                Write-Warning "  Failed to import (see logs above)"
                $failed++
            }
        }
        
        $amdIndex++
        if ($amdIndex -ge $script:amd_micro_instance_count) { break }
    }
    
    $armIndex = 0
    foreach ($instanceId in $script:EXISTING_ARM_INSTANCES.Keys) {
        $instanceName = ($script:EXISTING_ARM_INSTANCES[$instanceId] -split '\|')[0]
        Write-Status "Importing ARM instance: $instanceName"
        
        $stateCheck = terraform state show "oci_core_instance.arm[$armIndex]" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Status "  Already in state"
        } else {
            $importResult = Invoke-RetryWithBackoff { terraform import "oci_core_instance.arm[$armIndex]" "`"$instanceId`"" 2>&1 | Out-String }
            if ($LASTEXITCODE -eq 0) {
                Write-Success "  Imported successfully"
                $imported++
            } else {
                Write-Warning "  Failed to import (see logs above)"
                $failed++
            }
        }
        
        $armIndex++
        if ($armIndex -ge $script:arm_flex_instance_count) { break }
    }
    
    Write-Host ""
    Write-Success "Import complete: $imported imported, $failed failed"
}

function Import-VcnComponents {
    param([string]$VcnId)
    
    foreach ($igId in $script:EXISTING_INTERNET_GATEWAYS.Keys) {
        $igVcn = ($script:EXISTING_INTERNET_GATEWAYS[$igId] -split '\|')[1]
        if ($igVcn -eq $VcnId) {
            $stateCheck = terraform state show "oci_core_internet_gateway.main" 2>&1
            if ($LASTEXITCODE -ne 0) {
                terraform import "oci_core_internet_gateway.main" $igId 2>&1 | Out-Null
                Write-Status "    Imported Internet Gateway"
            }
            break
        }
    }
    
    foreach ($subnetId in $script:EXISTING_SUBNETS.Keys) {
        $subnetVcn = ($script:EXISTING_SUBNETS[$subnetId] -split '\|')[2]
        if ($subnetVcn -eq $VcnId) {
            $stateCheck = terraform state show "oci_core_subnet.main" 2>&1
            if ($LASTEXITCODE -ne 0) {
                terraform import "oci_core_subnet.main" $subnetId 2>&1 | Out-Null
                Write-Status "    Imported Subnet"
            }
            break
        }
    }
}

function Show-TerraformMenu {
    while ($true) {
        Write-Host ""
        Write-Header "TERRAFORM MANAGEMENT"
        Write-Host "  1) Full workflow (init → import → plan → apply)"
        Write-Host "  2) Plan only"
        Write-Host "  3) Apply existing plan"
        Write-Host "  4) Import existing resources"
        Write-Host "  5) Show current state"
        Write-Host "  6) Destroy infrastructure"
        Write-Host "  7) Reconfigure"
        Write-Host "  8) Exit"
        Write-Host ""
        
        if ($script:AutoDeploy -or $script:NonInteractive) {
            $choice = 1
            Write-Status "Auto mode: Running full workflow"
        } else {
            $choiceInput = Read-Host "Choose option [1]"
            if ([string]::IsNullOrWhiteSpace($choiceInput)) { $choiceInput = "1" }
            if (-not ([int]::TryParse($choiceInput, [ref]$choice))) {
                Write-Error "Invalid choice"
                continue
            }
        }
        
        switch ($choice) {
            1 {
                $result = Start-TerraformWorkflow
                if ($script:AutoDeploy) { return $true }
            }
            2 {
                terraform init -input=false
                terraform plan
            }
            3 {
                if (Test-Path "tfplan") {
                    terraform apply tfplan
                } else {
                    Write-Error "No plan file found"
                }
            }
            4 {
                Import-ExistingResources
            }
            5 {
                $stateList = terraform state list 2>&1
                $output = terraform output 2>&1
                if ($LASTEXITCODE -eq 0) {
                    # State exists
                } else {
                    Write-Status "No state found"
                }
            }
            6 {
                $confirm = Read-Host "DESTROY all infrastructure? [y/N]"
                if ($confirm -match "^[Yy]$") {
                    terraform destroy
                }
            }
            7 {
                return $false  # Signal to reconfigure
            }
            8 {
                return $true
            }
            default {
                Write-Error "Invalid choice"
            }
        }
        
        if ($script:NonInteractive) {
            return $true
        }
        
        Write-Host ""
        Read-Host "Press Enter to continue..."
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

function Main {
    Write-Header "OCI TERRAFORM SETUP - IDEMPOTENT EDITION"
    Write-Status "This script safely manages Oracle Cloud Free Tier resources"
    Write-Status "Safe to run multiple times - will detect and reuse existing resources"
    Write-Host ""
    
    # Phase 1: Prerequisites
    if (-not (Install-Prerequisites)) { return }
    if (-not (Install-Terraform)) { return }
    if (-not (Install-OciCli)) { return }
    
    # Activate virtual environment if it exists
    $venvActivate = Join-Path $PWD ".venv\Scripts\Activate.ps1"
    if (Test-Path $venvActivate) {
        & $venvActivate
    }
    
    # Phase 2: Authentication
    if (-not (Set-OciConfig)) { return }
    
    # Phase 3: Fetch OCI information
    if (-not (Get-OciConfigValues)) { return }
    if (-not (Get-AvailabilityDomains)) { return }
    Get-UbuntuImages
    New-SshKeys
    
    # Phase 4: Resource inventory (CRITICAL for idempotency)
    Get-AllResourcesInventory
    
    # Phase 5: Configuration
    if (-not $script:SkipConfig) {
        Request-Configuration
    } else {
        if (-not (Read-ExistingConfig)) {
            Set-ConfigurationFromExistingInstances
        }
    }
    
    # Phase 6: Generate Terraform files
    New-TerraformFiles
    
    # Phase 7: Terraform management
    while ($true) {
        $shouldExit = Show-TerraformMenu
        if ($shouldExit) {
            break
        }
        
        # Reconfigure requested
        Request-Configuration
        New-TerraformFiles
    }
    
    Write-Header "SETUP COMPLETE"
    Write-Success "Oracle Cloud Free Tier infrastructure managed successfully"
    Write-Host ""
    Write-Status "Files created/updated:"
    Write-Status "  • provider.tf - OCI provider configuration"
    Write-Status "  • variables.tf - Instance configuration"
    Write-Status "  • main.tf - Infrastructure resources"
    Write-Status "  • data_sources.tf - OCI data sources"
    Write-Status "  • block_volumes.tf - Storage volumes"
    Write-Status "  • cloud-init.yaml - Instance initialization"
    Write-Host ""
    Write-Status "To manage your infrastructure:"
    Write-Status "  terraform plan    - Preview changes"
    Write-Status "  terraform apply   - Apply changes"
    Write-Status "  terraform destroy - Remove all resources"
}

# Execute
Main
