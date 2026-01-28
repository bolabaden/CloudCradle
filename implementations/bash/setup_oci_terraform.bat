@echo off
REM Oracle Cloud Infrastructure (OCI) Terraform Setup Script
REM Idempotent, comprehensive implementation for Always Free Tier management
REM Windows Batch Script Version
REM
REM Usage:
REM   Interactive mode:        setup_oci_terraform.bat
REM   Non-interactive mode:    set NON_INTERACTIVE=true && set AUTO_USE_EXISTING=true && set AUTO_DEPLOY=true && setup_oci_terraform.bat
REM   Use existing config:     set AUTO_USE_EXISTING=true && setup_oci_terraform.bat
REM   Auto deploy only:        set AUTO_DEPLOY=true && setup_oci_terraform.bat
REM   Skip to deploy:          set SKIP_CONFIG=true && setup_oci_terraform.bat
REM
REM Key features:
REM   - Completely idempotent: safe to run multiple times
REM   - Comprehensive resource detection before any deployment
REM   - Strict Free Tier limit validation
REM   - Robust existing resource import

setlocal enabledelayedexpansion

REM ============================================================================
REM CONFIGURATION AND CONSTANTS
REM ============================================================================

REM Non-interactive mode support
if "%NON_INTERACTIVE%"=="" set NON_INTERACTIVE=false
if "%AUTO_USE_EXISTING%"=="" set AUTO_USE_EXISTING=false
if "%AUTO_DEPLOY%"=="" set AUTO_DEPLOY=false
if "%SKIP_CONFIG%"=="" set SKIP_CONFIG=false
if "%DEBUG%"=="" set DEBUG=false
if "%FORCE_REAUTH%"=="" set FORCE_REAUTH=false

REM Optional Terraform remote backend
if "%TF_BACKEND%"=="" set TF_BACKEND=local
if "%TF_BACKEND_BUCKET%"=="" set TF_BACKEND_BUCKET=
if "%TF_BACKEND_CREATE_BUCKET%"=="" set TF_BACKEND_CREATE_BUCKET=false
if "%TF_BACKEND_REGION%"=="" set TF_BACKEND_REGION=
if "%TF_BACKEND_ENDPOINT%"=="" set TF_BACKEND_ENDPOINT=
if "%TF_BACKEND_STATE_KEY%"=="" set TF_BACKEND_STATE_KEY=terraform.tfstate
if "%TF_BACKEND_ACCESS_KEY%"=="" set TF_BACKEND_ACCESS_KEY=
if "%TF_BACKEND_SECRET_KEY%"=="" set TF_BACKEND_SECRET_KEY=

REM Retry/backoff settings
if "%RETRY_MAX_ATTEMPTS%"=="" set RETRY_MAX_ATTEMPTS=8
if "%RETRY_BASE_DELAY%"=="" set RETRY_BASE_DELAY=15

REM Timeout for OCI CLI calls
if "%OCI_CMD_TIMEOUT%"=="" set OCI_CMD_TIMEOUT=20

REM OCI CLI configuration
if "%OCI_CONFIG_FILE%"=="" set OCI_CONFIG_FILE=%USERPROFILE%\.oci\config
if "%OCI_PROFILE%"=="" set OCI_PROFILE=DEFAULT
if "%OCI_AUTH_REGION%"=="" set OCI_AUTH_REGION=
if "%OCI_CLI_CONNECTION_TIMEOUT%"=="" set OCI_CLI_CONNECTION_TIMEOUT=10
if "%OCI_CLI_READ_TIMEOUT%"=="" set OCI_CLI_READ_TIMEOUT=60
if "%OCI_CLI_MAX_RETRIES%"=="" set OCI_CLI_MAX_RETRIES=3

REM Oracle Free Tier Limits
set FREE_TIER_MAX_AMD_INSTANCES=2
set FREE_TIER_AMD_SHAPE=VM.Standard.E2.1.Micro
set FREE_TIER_MAX_ARM_OCPUS=4
set FREE_TIER_MAX_ARM_MEMORY_GB=24
set FREE_TIER_ARM_SHAPE=VM.Standard.A1.Flex
set FREE_TIER_MAX_STORAGE_GB=200
set FREE_TIER_MIN_BOOT_VOLUME_GB=47
set FREE_TIER_MAX_ARM_INSTANCES=4
set FREE_TIER_MAX_VCNS=2

REM Global state tracking
set tenancy_ocid=
set user_ocid=
set region=
set fingerprint=
set availability_domain=
set ubuntu_image_ocid=
set ubuntu_arm_flex_image_ocid=
set ssh_public_key=
set auth_method=security_token

REM Instance configuration
set amd_micro_instance_count=0
set amd_micro_boot_volume_size_gb=50
set arm_flex_instance_count=0
set arm_flex_ocpus_per_instance=
set arm_flex_memory_per_instance=
set arm_flex_boot_volume_size_gb=

REM Arrays (using space-separated strings with indices)
set amd_micro_hostnames=
set arm_flex_hostnames=
set arm_flex_block_volumes=

REM Existing resource tracking (using associative array simulation)
set EXISTING_VCNS_COUNT=0
set EXISTING_SUBNETS_COUNT=0
set EXISTING_INTERNET_GATEWAYS_COUNT=0
set EXISTING_ROUTE_TABLES_COUNT=0
set EXISTING_SECURITY_LISTS_COUNT=0
set EXISTING_AMD_INSTANCES_COUNT=0
set EXISTING_ARM_INSTANCES_COUNT=0
set EXISTING_BOOT_VOLUMES_COUNT=0
set EXISTING_BLOCK_VOLUMES_COUNT=0

REM ============================================================================
REM LOGGING FUNCTIONS
REM ============================================================================

:print_status
echo [INFO] %~1
goto :eof

:print_success
echo [SUCCESS] %~1
goto :eof

:print_warning
echo [WARNING] %~1
goto :eof

:print_error
echo [ERROR] %~1
goto :eof

:print_debug
if "%DEBUG%"=="true" (
    echo [DEBUG] %~1
)
goto :eof

:prompt_with_default
setlocal enabledelayedexpansion
set "prompt=%~1"
set "default_value=%~2"
set /p "input=%prompt% [%default_value%]: "
if "!input!"=="" set "input=%default_value%"
echo !input!
endlocal
goto :eof

:prompt_int_range
setlocal enabledelayedexpansion
set "prompt=%~1"
set "default_value=%~2"
set "min_value=%~3"
set "max_value=%~4"
:prompt_int_range_loop
set /p "value=%prompt%: "
if "!value!"=="" set "value=%default_value%"
for /f "tokens=*" %%a in ('powershell -Command "if ([int]'!value!' -ge [int]'%min_value%' -and [int]'!value!' -le [int]'%max_value%') { exit 0 } else { exit 1 }"') do set "valid=%%a"
if errorlevel 1 (
    call :print_error "Please enter a number between %min_value% and %max_value% (received: '!value!')"
    goto prompt_int_range_loop
)
echo !value!
endlocal
goto :eof

:print_header
echo.
echo ============================================================================
echo   %~1
echo ============================================================================
echo.
goto :eof

:print_subheader
echo.
echo ---- %~1 ----
echo.
goto :eof

REM ============================================================================
REM UTILITY FUNCTIONS
REM ============================================================================

:command_exists
where "%~1" >nul 2>&1
if errorlevel 1 (
    exit /b 1
) else (
    exit /b 0
)

:default_region_for_host
REM Best-effort heuristic when the user doesn't specify a region
REM Uses system timezone
for /f "tokens=*" %%a in ('powershell -Command "[System.TimeZoneInfo]::Local.Id"') do set "tz=%%a"
if "%tz:Central%" neq "%tz%" set "result=us-chicago-1" && goto default_region_done
if "%tz:Eastern%" neq "%tz%" set "result=us-ashburn-1" && goto default_region_done
if "%tz:Pacific%" neq "%tz%" set "result=us-sanjose-1" && goto default_region_done
if "%tz:Mountain%" neq "%tz%" set "result=us-phoenix-1" && goto default_region_done
if "%tz:London%" neq "%tz%" set "result=uk-london-1" && goto default_region_done
if "%tz:Paris%" neq "%tz%" set "result=eu-frankfurt-1" && goto default_region_done
if "%tz:Tokyo%" neq "%tz%" set "result=ap-tokyo-1" && goto default_region_done
if "%tz:Seoul%" neq "%tz%" set "result=ap-seoul-1" && goto default_region_done
if "%tz:Singapore%" neq "%tz%" set "result=ap-singapore-1" && goto default_region_done
if "%tz:Sydney%" neq "%tz%" set "result=ap-sydney-1" && goto default_region_done
set "result=us-chicago-1"
:default_region_done
echo %result%
goto :eof

:open_url_best_effort
if "%~1"=="" exit /b 1
start "" "%~1"
exit /b 0

:read_oci_config_value
REM Read a value from OCI config file
setlocal enabledelayedexpansion
set "key=%~1"
set "file=%~2"
if "%file%"=="" set "file=%OCI_CONFIG_FILE%"
set "profile=%~3"
if "%profile%"=="" set "profile=%OCI_PROFILE%"
if not exist "%file%" exit /b 1
set "in_section=0"
for /f "usebackq tokens=*" %%a in ("%file%") do (
    set "line=%%a"
    if "!line:~0,1!"=="[" (
        if "!line!"=="[%profile%]" (
            set "in_section=1"
        ) else (
            set "in_section=0"
        )
    ) else if !in_section!==1 (
        for /f "tokens=1,* delims==" %%b in ("!line!") do (
            set "config_key=%%b"
            set "config_value=%%c"
            set "config_key=!config_key: =!"
            if /i "!config_key!"=="%key%" (
                echo !config_value!
                endlocal
                exit /b 0
            )
        )
    )
)
endlocal
exit /b 1

:is_instance_principal_available
where curl >nul 2>&1
if errorlevel 1 exit /b 1
curl -s --connect-timeout 1 --max-time 2 http://169.254.169.254/opc/v2/ >nul 2>&1
exit /b %errorlevel%

:validate_existing_oci_config
if not exist "%OCI_CONFIG_FILE%" (
    call :print_warning "OCI config not found at %OCI_CONFIG_FILE%"
    exit /b 1
)
call :read_oci_config_value "auth" "%OCI_CONFIG_FILE%" "%OCI_PROFILE%" >nul 2>&1
if errorlevel 1 (
    call :read_oci_config_value "security_token_file" "%OCI_CONFIG_FILE%" "%OCI_PROFILE%" >nul 2>&1
    if not errorlevel 1 (
        set "auth_method=security_token"
    ) else (
        call :read_oci_config_value "key_file" "%OCI_CONFIG_FILE%" "%OCI_PROFILE%" >nul 2>&1
        if not errorlevel 1 (
            set "auth_method=api_key"
        )
    )
)
if "%auth_method%"=="security_token" (
    call :read_oci_config_value "security_token_file" "%OCI_CONFIG_FILE%" "%OCI_PROFILE%" >nul 2>&1
    if errorlevel 1 (
        call :print_warning "security_token auth selected but security_token_file is missing"
        exit /b 1
    )
) else if "%auth_method%"=="api_key" (
    call :read_oci_config_value "key_file" "%OCI_CONFIG_FILE%" "%OCI_PROFILE%" >nul 2>&1
    if errorlevel 1 (
        call :print_warning "api_key auth selected but key_file is missing"
        exit /b 1
    )
) else if "%auth_method%"=="instance_principal" (
    call :is_instance_principal_available
    if errorlevel 1 (
        call :print_warning "Instance principal auth selected but OCI metadata service is unreachable"
        exit /b 1
    )
)
exit /b 0

REM ============================================================================
REM OCI COMMAND WRAPPER
REM ============================================================================

:oci_cmd
setlocal enabledelayedexpansion
set "cmd=%~1"
set "base_args=--config-file \"%OCI_CONFIG_FILE%\" --profile \"%OCI_PROFILE%\" --connection-timeout %OCI_CLI_CONNECTION_TIMEOUT% --read-timeout %OCI_CLI_READ_TIMEOUT% --max-retries %OCI_CLI_MAX_RETRIES%"
if not "%OCI_CLI_AUTH%"=="" (
    set "base_args=!base_args! --auth %OCI_CLI_AUTH%"
) else if not "%auth_method%"=="" (
    set "base_args=!base_args! --auth %auth_method%"
)
set "full_cmd=oci !base_args! !cmd!"
for /f "tokens=*" %%a in ('powershell -Command "$job = Start-Job -ScriptBlock { %full_cmd% }; Wait-Job -Job $job -Timeout %OCI_CMD_TIMEOUT% | Out-Null; if ($job.State -eq 'Running') { Stop-Job -Job $job; Remove-Job -Job $job; exit 1 } else { Receive-Job -Job $job; Remove-Job -Job $job; exit 0 }"') do set "result=%%a"
if errorlevel 1 (
    call :print_warning "OCI CLI call timed out after %OCI_CMD_TIMEOUT%s"
    endlocal
    exit /b 1
)
echo !result!
endlocal
exit /b 0

REM PowerShell-based JSON parser (replaces jq) - comprehensive implementation
:ps_json_query
setlocal enabledelayedexpansion
set "json_input=%~1"
set "jq_query=%~2"
set "default=%~3"
if "%json_input%"=="" (
    echo %default%
    endlocal
    exit /b 0
)
if "%json_input%"=="null" (
    echo %default%
    endlocal
    exit /b 0
)
REM Determine if input is file or string
set "json_file=%json_input%"
set "is_temp=0"
if not exist "%json_file%" (
    set "json_file=%TEMP%\json_%RANDOM%_%RANDOM%.json"
    echo %json_input% > "%json_file%"
    set "is_temp=1"
)
REM Build PowerShell script to parse JSON
set "ps_script=%TEMP%\ps_json_%RANDOM%.ps1"
(
echo $json = Get-Content '%json_file%' -Raw -ErrorAction SilentlyContinue ^| ConvertFrom-Json
echo if ($json -eq $null^) { Write-Output '%default%'; exit }
echo try {
echo   $query = '%jq_query%'
echo   $result = $null
echo   if ($query -eq 'length'^) {
echo     if ($json -is [Array]^) { $result = $json.Count } else { $result = 1 }
echo   } elseif ($query -match '^\^\.\[(\d+)\]$'^) {
echo     $index = [int]$matches[1]
echo     if ($json -is [Array] -and $index -lt $json.Count^) { $result = $json[$index] }
echo   } elseif ($query -match '^\^\.data\[(\d+)\]\.(\w+)$'^) {
echo     $index = [int]$matches[1]
echo     $prop = $matches[2]
echo     if ($json.data -is [Array] -and $index -lt $json.data.Count^) { $result = $json.data[$index].$prop }
echo   } elseif ($query -match '^\^\.data\.\"([^\"]+)\"$'^) {
echo     $prop = $matches[1]
echo     $result = $json.data.$prop
echo   } elseif ($query -match '^\^\.(\w+)$'^) {
echo     $prop = $matches[1]
echo     $result = $json.$prop
echo   } else {
echo     $parts = $query -split '\.'
echo     $obj = $json
echo     foreach ($part in $parts^) {
echo       if ($part -match '\[(\d+)\]'^) {
echo         $idx = [int]$matches[1]
echo         $name = $part -replace '\[\d+\]', ''
echo         if ($name^) { $obj = $obj.$name }
echo         if ($obj -is [Array] -and $idx -lt $obj.Count^) { $obj = $obj[$idx] } else { $obj = $null; break }
echo       } elseif ($part -match '\"([^\"]+)\"'^) {
echo         $name = $matches[1]
echo         $obj = $obj.$name
echo       } else {
echo         $obj = $obj.$part
echo       }
echo       if ($obj -eq $null^) { break }
echo     }
echo     $result = $obj
echo   }
echo   if ($result -eq $null -or $result -eq ''^) { Write-Output '%default%' } else { Write-Output $result }
echo } catch {
echo   Write-Output '%default%'
echo }
) > "%ps_script%"
for /f "tokens=* delims=" %%a in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%ps_script%" 2^>nul') do set "result=%%a"
del "%ps_script%" 2>nul
if "%is_temp%"=="1" del "%json_file%" 2>nul
if "!result!"=="" set "result=%default%"
if "!result!"=="null" set "result=%default%"
echo !result!
endlocal
exit /b 0

:safe_jq
REM Wrapper for jq compatibility - uses PowerShell JSON parser
setlocal enabledelayedexpansion
set "json_input=%~1"
set "jq_query=%~2"
set "default=%~3"
call :ps_json_query "%json_input%" "%jq_query%" "%default%"
endlocal
exit /b 0

REM ============================================================================
REM RETRY FUNCTIONS
REM ============================================================================

:retry_with_backoff
setlocal enabledelayedexpansion
set "cmd=%~1"
set "attempt=1"
set "rc=1"
:retry_loop
call :print_status "Attempt !attempt!/%RETRY_MAX_ATTEMPTS%: %cmd%"
for /f "tokens=*" %%a in ('%cmd% 2^>^&1') do set "out=%%a"
if not errorlevel 1 (
    echo !out!
    endlocal
    exit /b 0
)
echo !out! | findstr /i /c:"out of capacity" /c:"out of host capacity" /c:"OutOfCapacity" /c:"OutOfHostCapacity" >nul 2>&1
if not errorlevel 1 (
    call :print_warning "Detected 'Out of Capacity' condition (attempt !attempt!)."
) else (
    call :print_warning "Command failed (exit !rc!)."
)
set /a "sleep_time=%RETRY_BASE_DELAY% * (1 << (!attempt! - 1))"
call :print_status "Retrying in !sleep_time!s..."
timeout /t !sleep_time! /nobreak >nul
set /a "attempt+=1"
if !attempt! leq %RETRY_MAX_ATTEMPTS% goto retry_loop
call :print_error "Command failed after %RETRY_MAX_ATTEMPTS% attempts"
echo !out!
endlocal
exit /b %rc%

:run_cmd_with_retries_and_check
setlocal enabledelayedexpansion
set "cmd=%~1"
set "OUT_OF_CAPACITY_DETECTED=0"
call :retry_with_backoff "%cmd%" >temp_output.txt 2>&1
set "rc=!errorlevel!"
type temp_output.txt
findstr /i /c:"out of capacity" /c:"out of host capacity" /c:"OutOfCapacity" /c:"OutOfHostCapacity" temp_output.txt >nul 2>&1
if not errorlevel 1 set "OUT_OF_CAPACITY_DETECTED=1"
del temp_output.txt 2>nul
endlocal
exit /b %rc%

:out_of_capacity_auto_apply
call :print_status "Auto-retrying terraform apply until success or max attempts (%RETRY_MAX_ATTEMPTS%)..."
setlocal enabledelayedexpansion
set "attempt=1"
set "rc=1"
:apply_retry_loop
call :print_status "Apply attempt !attempt!/%RETRY_MAX_ATTEMPTS%"
terraform apply -input=false tfplan >temp_apply_output.txt 2>&1
set "rc=!errorlevel!"
type temp_apply_output.txt
if !rc!==0 (
    call :print_success "terraform apply succeeded"
    del temp_apply_output.txt 2>nul
    endlocal
    exit /b 0
)
findstr /i /c:"out of capacity" /c:"out of host capacity" /c:"OutOfCapacity" /c:"OutOfHostCapacity" temp_apply_output.txt >nul 2>&1
if not errorlevel 1 (
    call :print_warning "Apply failed with 'Out of Capacity' - will retry"
) else (
    call :print_error "terraform apply failed with non-retryable error"
    type temp_apply_output.txt
    del temp_apply_output.txt 2>nul
    endlocal
    exit /b %rc%
)
set /a "sleep_time=%RETRY_BASE_DELAY% * (1 << (!attempt! - 1))"
call :print_status "Waiting !sleep_time!s before retrying..."
timeout /t !sleep_time! /nobreak >nul
set /a "attempt+=1"
if !attempt! leq %RETRY_MAX_ATTEMPTS% goto apply_retry_loop
call :print_error "terraform apply did not succeed after %RETRY_MAX_ATTEMPTS% attempts"
type temp_apply_output.txt
del temp_apply_output.txt 2>nul
endlocal
exit /b 1

REM ============================================================================
REM BACKEND CONFIGURATION
REM ============================================================================

:create_s3_backend_bucket
setlocal enabledelayedexpansion
set "bucket_name=%~1"
if "%bucket_name%"=="" (
    call :print_error "Bucket name is empty"
    endlocal
    exit /b 1
)
call :print_status "Creating/checking OCI Object Storage bucket: %bucket_name%"
call :oci_cmd "os ns get --query 'data' --raw-output" >temp_ns.txt 2>&1
set /p "ns=" <temp_ns.txt
del temp_ns.txt 2>nul
if "%ns%"=="" (
    call :print_error "Failed to determine Object Storage namespace"
    endlocal
    exit /b 1
)
call :oci_cmd "os bucket get --namespace-name %ns% --bucket-name %bucket_name%" >nul 2>&1
if not errorlevel 1 (
    call :print_status "Bucket %bucket_name% already exists in namespace %ns%"
    endlocal
    exit /b 0
)
call :oci_cmd "os bucket create --namespace-name %ns% --compartment-id %tenancy_ocid% --name %bucket_name% --is-versioning-enabled true" >nul 2>&1
if not errorlevel 1 (
    call :print_success "Created bucket %bucket_name% in namespace %ns%"
    endlocal
    exit /b 0
)
call :print_error "Failed to create bucket %bucket_name%"
endlocal
exit /b 1

:configure_terraform_backend
if not "%TF_BACKEND%"=="oci" exit /b 0
if "%TF_BACKEND_BUCKET%"=="" (
    call :print_error "TF_BACKEND is 'oci' but TF_BACKEND_BUCKET is not set"
    exit /b 1
)
if "%TF_BACKEND_REGION%"=="" set "TF_BACKEND_REGION=%region%"
if "%TF_BACKEND_ENDPOINT%"=="" set "TF_BACKEND_ENDPOINT=https://objectstorage.%TF_BACKEND_REGION%.oraclecloud.com"
if "%TF_BACKEND_CREATE_BUCKET%"=="true" (
    call :create_s3_backend_bucket "%TF_BACKEND_BUCKET%"
    if errorlevel 1 exit /b 1
)
call :print_status "Writing backend.tf (do not commit -- contains sensitive values)"
(
echo terraform {
echo   backend "s3" {
echo     bucket     = "%TF_BACKEND_BUCKET%"
echo     key        = "%TF_BACKEND_STATE_KEY%"
echo     region     = "%TF_BACKEND_REGION%"
echo     endpoint   = "%TF_BACKEND_ENDPOINT%"
echo     access_key = "%TF_BACKEND_ACCESS_KEY%"
echo     secret_key = "%TF_BACKEND_SECRET_KEY%"
echo     skip_credentials_validation = true
echo     skip_region_validation = true
echo     skip_metadata_api_check = true
echo     force_path_style = true
echo   }
echo }
) > backend.tf
call :print_warning "backend.tf written - ensure this file is in .gitignore (contains credentials if provided)"
exit /b 0

:confirm_action
setlocal enabledelayedexpansion
set "prompt=%~1"
set "default=%~2"
if "%default%"=="" set "default=N"
if "%NON_INTERACTIVE%"=="true" (
    if "%default%"=="Y" (
        endlocal
        exit /b 0
    ) else (
        endlocal
        exit /b 1
    )
)
if "%default%"=="Y" (
    set "yn_prompt=[Y/n]"
) else (
    set "yn_prompt=[y/N]"
)
set /p "response=%prompt% !yn_prompt!: "
if "!response!"=="" set "response=%default%"
if /i "!response!"=="Y" (
    endlocal
    exit /b 0
) else (
    endlocal
    exit /b 1
)

REM ============================================================================
REM INSTALLATION FUNCTIONS
REM ============================================================================

:install_prerequisites
call :print_subheader "Installing Prerequisites"
setlocal enabledelayedexpansion
set "packages_to_install="
where curl >nul 2>&1
if errorlevel 1 set "packages_to_install=!packages_to_install! curl"
where unzip >nul 2>&1
if errorlevel 1 set "packages_to_install=!packages_to_install! unzip"
if not "!packages_to_install!"=="" (
    call :print_status "Optional packages not found:!packages_to_install!"
    call :print_warning "These are optional - script will use PowerShell for JSON parsing"
    call :print_warning "To install: choco install curl unzip"
)
REM PowerShell is preinstalled - we use it for JSON parsing instead of jq
where powershell >nul 2>&1
if errorlevel 1 (
    call :print_error "PowerShell is required but not found"
    endlocal
    exit /b 1
)
where openssl >nul 2>&1
if errorlevel 1 (
    call :print_warning "openssl not found - some features may be limited"
    call :print_warning "Install via: choco install openssl"
)
where ssh-keygen >nul 2>&1
if errorlevel 1 (
    call :print_warning "ssh-keygen not found - will attempt to use Git's ssh-keygen"
    where git >nul 2>&1
    if errorlevel 1 (
        call :print_error "ssh-keygen is required - install Git for Windows or OpenSSH"
        endlocal
        exit /b 1
    )
)
call :print_success "All prerequisites available (using PowerShell for JSON parsing)"
endlocal
exit /b 0

:install_oci_cli
call :print_subheader "OCI CLI Setup"
where oci >nul 2>&1
if not errorlevel 1 (
    for /f "tokens=*" %%a in ('oci --version 2^>nul ^| findstr /r "^oci"') do (
        call :print_status "OCI CLI already installed: %%a"
        exit /b 0
    )
)
call :print_status "Installing OCI CLI..."
where python >nul 2>&1
if errorlevel 1 (
    call :print_status "Installing Python 3..."
    call :print_warning "Please install Python 3 manually from https://www.python.org/downloads/"
    exit /b 1
)
if not exist ".venv" (
    call :print_status "Creating Python virtual environment..."
    python -m venv .venv
)
call :print_status "Installing OCI CLI in virtual environment..."
call .venv\Scripts\activate.bat
python -m pip install --upgrade pip --quiet
python -m pip install oci-cli --quiet
call :print_success "OCI CLI installed successfully"
exit /b 0

:install_terraform
call :print_subheader "Terraform Setup"
where terraform >nul 2>&1
if not errorlevel 1 (
    for /f "tokens=*" %%a in ('powershell -NoProfile -Command "try { $json = terraform version -json 2>$null | ConvertFrom-Json; Write-Output $json.terraform_version } catch { }" 2^>nul') do (
        if not "%%a"=="" (
            call :print_status "Terraform already installed: version %%a"
            exit /b 0
        )
    )
    for /f "tokens=2" %%a in ('terraform version 2^>nul ^| findstr /r "^Terraform"') do (
        call :print_status "Terraform already installed: version %%a"
        exit /b 0
    )
)
call :print_status "Installing Terraform..."
where choco >nul 2>&1
if not errorlevel 1 (
    choco install terraform -y
    if not errorlevel 1 (
        call :print_success "Terraform installed via chocolatey"
        exit /b 0
    )
)
call :print_status "Downloading latest Terraform version..."
for /f "tokens=*" %%a in ('powershell -Command "(Invoke-WebRequest -Uri 'https://api.github.com/repos/hashicorp/terraform/releases/latest' -UseBasicParsing).Content | ConvertFrom-Json | Select-Object -ExpandProperty tag_name"') do set "latest_version=%%a"
if "%latest_version%"=="" set "latest_version=v1.7.0"
set "latest_version=%latest_version:v=%"
if "%PROCESSOR_ARCHITECTURE%"=="AMD64" (
    set "arch=amd64"
) else (
    set "arch=arm64"
)
set "tf_url=https://releases.hashicorp.com/terraform/%latest_version%/terraform_%latest_version%_windows_%arch%.zip"
call :print_status "Downloading Terraform %latest_version% for windows_%arch%..."
powershell -Command "Invoke-WebRequest -Uri '%tf_url%' -OutFile 'terraform.zip'"
if not exist "terraform.zip" (
    call :print_error "Failed to download Terraform"
    exit /b 1
)
powershell -Command "Expand-Archive -Path 'terraform.zip' -DestinationPath '.' -Force"
del terraform.zip 2>nul
if exist "terraform.exe" (
    if not exist "%ProgramFiles%\Terraform" mkdir "%ProgramFiles%\Terraform"
    copy terraform.exe "%ProgramFiles%\Terraform\" >nul 2>&1
    setx PATH "%PATH%;%ProgramFiles%\Terraform" >nul 2>&1
    set "PATH=%PATH%;%ProgramFiles%\Terraform"
    del terraform.exe 2>nul
    call :print_success "Terraform installed successfully"
    exit /b 0
)
call :print_error "Failed to install Terraform"
exit /b 1

REM ============================================================================
REM OCI AUTHENTICATION FUNCTIONS
REM ============================================================================

:detect_auth_method
if exist "%OCI_CONFIG_FILE%" (
    call :read_oci_config_value "auth" "%OCI_CONFIG_FILE%" "%OCI_PROFILE%" >nul 2>&1
    if not errorlevel 1 (
        for /f "tokens=*" %%a in ('call :read_oci_config_value "auth" "%OCI_CONFIG_FILE%" "%OCI_PROFILE%"') do set "auth_method=%%a"
    ) else (
        call :read_oci_config_value "security_token_file" "%OCI_CONFIG_FILE%" "%OCI_PROFILE%" >nul 2>&1
        if not errorlevel 1 (
            set "auth_method=security_token"
        ) else (
            call :read_oci_config_value "key_file" "%OCI_CONFIG_FILE%" "%OCI_PROFILE%" >nul 2>&1
            if not errorlevel 1 (
                set "auth_method=api_key"
            )
        )
    )
)
call :print_debug "Detected auth method: %auth_method% (profile: %OCI_PROFILE%, config: %OCI_CONFIG_FILE%)"
exit /b 0

:test_oci_connectivity
call :print_status "Testing OCI API connectivity..."
call :print_status "Checking IAM region list (timeout %OCI_CMD_TIMEOUT%s)..."
call :oci_cmd "iam region list" >nul 2>&1
if not errorlevel 1 (
    call :print_debug "Connectivity test passed (region list)"
    exit /b 0
)
call :print_warning "Region list query failed or timed out"
for /f "tokens=*" %%a in ('findstr /c:"tenancy=" "%OCI_CONFIG_FILE%" 2^>nul') do (
    for /f "tokens=2 delims==" %%b in ("%%a") do set "test_tenancy=%%b"
)
if not "%test_tenancy%"=="" (
    call :print_status "Checking IAM tenancy get (timeout %OCI_CMD_TIMEOUT%s)..."
    call :oci_cmd "iam tenancy get --tenancy-id %test_tenancy%" >nul 2>&1
    if not errorlevel 1 (
        call :print_debug "Connectivity test passed (tenancy get)"
        exit /b 0
    )
    call :print_warning "Tenancy get failed or timed out"
)
call :print_debug "All connectivity tests failed"
exit /b 1

:setup_oci_config
call :print_subheader "OCI Authentication"
if not exist "%USERPROFILE%\.oci" mkdir "%USERPROFILE%\.oci"
set "existing_config_invalid=0"
if exist "%OCI_CONFIG_FILE%" (
    call :print_status "Existing OCI configuration found"
    call :detect_auth_method
    call :print_status "Validating existing OCI configuration..."
    call :validate_existing_oci_config
    if errorlevel 1 (
        set "existing_config_invalid=1"
        call :print_warning "Existing OCI configuration is incomplete or requires interactive input"
    ) else (
        call :print_status "Testing existing OCI configuration connectivity..."
        call :test_oci_connectivity
        if not errorlevel 1 (
            call :print_success "Existing OCI configuration is valid"
            exit /b 0
        )
    )
    call :print_warning "Existing configuration failed connectivity test (will retry with refresh)"
    if "%auth_method%"=="security_token" (
        call :print_status "Attempting to refresh session token (timeout %OCI_CMD_TIMEOUT%s)..."
        call :oci_cmd "session refresh" >nul 2>&1
        if not errorlevel 1 (
            call :test_oci_connectivity
            if not errorlevel 1 (
                call :print_success "Session token refreshed successfully"
                exit /b 0
            )
        ) else (
            call :print_warning "Session refresh failed or timed out"
        )
        call :print_status "Session refresh did not restore connectivity, initiating interactive authentication as a fallback..."
    )
)
call :print_status "Setting up browser-based authentication..."
call :print_status "This will open a browser window for you to log in to Oracle Cloud."
if "%NON_INTERACTIVE%"=="true" (
    call :print_error "Cannot perform interactive authentication in non-interactive mode. Aborting."
    exit /b 1
)
for /f "tokens=*" %%a in ('call :read_oci_config_value "region" "%OCI_CONFIG_FILE%" "%OCI_PROFILE%" 2^>nul') do set "auth_region=%%a"
if "%auth_region%"=="" set "auth_region=%OCI_AUTH_REGION%"
if "%auth_region%"=="" (
    for /f "tokens=*" %%a in ('call :default_region_for_host') do set "auth_region=%%a"
)
if not "%NON_INTERACTIVE%"=="true" (
    for /f "tokens=*" %%a in ('call :prompt_with_default "Region for authentication" "%auth_region%"') do set "auth_region=%%a"
)
if "%FORCE_REAUTH%"=="true" (
    for /f "tokens=*" %%a in ('call :prompt_with_default "Enter new profile name to create/use" "NEW_PROFILE"') do set "new_profile=%%a"
    call :print_status "Starting interactive session authenticate for profile '%new_profile%'..."
    call :print_status "Using region '%auth_region%' for authentication"
    oci session authenticate --no-browser --profile-name "%new_profile%" --region "%auth_region%" --session-expiration-in-minutes 60
    if errorlevel 1 (
        call :print_error "Authentication failed"
        exit /b 1
    )
    call :print_status "Authentication for profile '%new_profile%' completed. Updating OCI_PROFILE to use it."
    set "OCI_PROFILE=%new_profile%"
    set "auth_method=security_token"
    if "%existing_config_invalid%"=="1" (
        call :print_warning "Detected invalid or incomplete OCI config file during forced re-auth - AUTOMATICALLY DELETING AND FORCING FRESH AUTHENTICATION"
        if exist "%OCI_CONFIG_FILE%" (
            call :print_status "Backing up corrupted config to %OCI_CONFIG_FILE%.corrupted.%date:~-4,4%%date:~-7,2%%date:~-10,2%_%time:~0,2%%time:~3,2%%time:~6,2%"
            copy "%OCI_CONFIG_FILE%" "%OCI_CONFIG_FILE%.corrupted.%date:~-4,4%%date:~-7,2%%date:~-10,2%_%time:~0,2%%time:~3,2%%time:~6,2%" >nul 2>&1
            call :print_status "Forcibly deleting corrupted config file: %OCI_CONFIG_FILE%"
            del "%OCI_CONFIG_FILE%" 2>nul
        )
        del "%USERPROFILE%\.oci\config.session_auth" 2>nul
        set "new_profile=DEFAULT"
        call :print_status "Creating fresh OCI configuration with browser-based authentication for profile '%new_profile%'..."
        call :print_status "This will open your browser to log into Oracle Cloud."
        call :print_status ""
        call :print_status "Using region '%auth_region%' for authentication"
        call :print_status ""
        set "OCI_CONFIG_FILE=%USERPROFILE%\.oci\config"
        set "OCI_PROFILE=%new_profile%"
        set "OCI_CLI_CONFIG_FILE="
        oci session authenticate --no-browser --profile-name "%new_profile%" --region "%auth_region%" --session-expiration-in-minutes 60
        if not errorlevel 1 (
            set "OCI_PROFILE=%new_profile%"
            set "auth_method=security_token"
            call :test_oci_connectivity
            if not errorlevel 1 (
                call :print_success "Fresh session authentication succeeded for profile '%new_profile%'"
                exit /b 0
            ) else (
                call :print_warning "Session auth completed but connectivity test failed"
            )
        ) else (
            call :print_error "Browser-based authentication failed. Please verify your Oracle Cloud credentials and try again."
            exit /b 1
        )
    )
    call :test_oci_connectivity
    if not errorlevel 1 (
        call :print_success "OCI authentication configured successfully for profile '%new_profile%'"
        exit /b 0
    ) else (
        call :print_warning "Authentication succeeded but connectivity test failed for profile '%new_profile%'"
    )
) else (
    if "%existing_config_invalid%"=="1" (
        call :print_warning "Detected invalid or incomplete OCI config file - AUTOMATICALLY DELETING AND FORCING FRESH AUTHENTICATION"
        if exist "%OCI_CONFIG_FILE%" (
            call :print_status "Backing up corrupted config to %OCI_CONFIG_FILE%.corrupted.%date:~-4,4%%date:~-7,2%%date:~-10,2%_%time:~0,2%%time:~3,2%%time:~6,2%"
            copy "%OCI_CONFIG_FILE%" "%OCI_CONFIG_FILE%.corrupted.%date:~-4,4%%date:~-7,2%%date:~-10,2%_%time:~0,2%%time:~3,2%%time:~6,2%" >nul 2>&1
            call :print_status "Forcibly deleting corrupted config file: %OCI_CONFIG_FILE%"
            del "%OCI_CONFIG_FILE%" 2>nul
        )
        del "%USERPROFILE%\.oci\config.session_auth" 2>nul
        set "new_profile=DEFAULT"
        call :print_status "Creating fresh OCI configuration with browser-based authentication for profile '%new_profile%'..."
        call :print_status "This will open your browser to log into Oracle Cloud."
        call :print_status ""
        call :print_status "Using region '%auth_region%' for authentication"
        call :print_status ""
        set "OCI_CONFIG_FILE=%USERPROFILE%\.oci\config"
        set "OCI_PROFILE=%new_profile%"
        set "OCI_CLI_CONFIG_FILE="
        oci session authenticate --no-browser --profile-name "%new_profile%" --region "%auth_region%" --session-expiration-in-minutes 60
        if not errorlevel 1 (
            set "auth_method=security_token"
            call :test_oci_connectivity
            if not errorlevel 1 (
                call :print_success "Fresh session authentication succeeded for profile '%new_profile%'"
                exit /b 0
            ) else (
                call :print_warning "Session auth completed but connectivity test failed"
            )
        ) else (
            call :print_error "Browser-based authentication failed. Please verify your Oracle Cloud credentials and try again."
            exit /b 1
        )
    )
    call :print_status "Using profile '%OCI_PROFILE%' for interactive session authenticate..."
    call :print_status "Using region '%auth_region%' for authentication"
    oci session authenticate --no-browser --profile-name "%OCI_PROFILE%" --region "%auth_region%" --session-expiration-in-minutes 60
    if errorlevel 1 (
        call :print_error "Browser authentication failed or was cancelled"
        exit /b 1
    )
    set "auth_method=security_token"
    call :test_oci_connectivity
    if not errorlevel 1 (
        call :print_success "OCI authentication configured successfully"
        exit /b 0
    )
)
call :print_error "OCI configuration verification failed"
exit /b 1

REM ============================================================================
REM OCI RESOURCE DISCOVERY FUNCTIONS
REM ============================================================================

:fetch_oci_config_values
call :print_subheader "Fetching OCI Configuration"
for /f "tokens=2 delims==" %%a in ('findstr /c:"tenancy=" "%OCI_CONFIG_FILE%" 2^>nul') do set "tenancy_ocid=%%a"
if "%tenancy_ocid%"=="" (
    call :print_error "Failed to fetch tenancy OCID from config"
    exit /b 1
)
call :print_status "Tenancy OCID: %tenancy_ocid%"
for /f "tokens=2 delims==" %%a in ('findstr /c:"user=" "%OCI_CONFIG_FILE%" 2^>nul') do set "user_ocid=%%a"
if "%user_ocid%"=="" (
    call :oci_cmd "iam user list --compartment-id %tenancy_ocid% --limit 1" >temp_user.txt 2>&1
    for /f "tokens=*" %%a in ('powershell -NoProfile -Command "try { $json = Get-Content 'temp_user.txt' -Raw | ConvertFrom-Json; if ($json.data -and $json.data.Count -gt 0) { Write-Output $json.data[0].id } } catch { }" 2^>nul') do set "user_ocid=%%a"
    del temp_user.txt 2>nul
)
call :print_status "User OCID: %user_ocid%"
for /f "tokens=2 delims==" %%a in ('findstr /c:"region=" "%OCI_CONFIG_FILE%" 2^>nul') do set "region=%%a"
if "%region%"=="" (
    call :print_error "Failed to fetch region from config"
    exit /b 1
)
call :print_status "Region: %region%"
if "%auth_method%"=="security_token" (
    set "fingerprint=session_token_auth"
) else (
    for /f "tokens=2 delims==" %%a in ('findstr /c:"fingerprint=" "%OCI_CONFIG_FILE%" 2^>nul') do set "fingerprint=%%a"
)
call :print_debug "Auth fingerprint: %fingerprint%"
call :print_success "OCI configuration values fetched"
exit /b 0

:fetch_availability_domains
call :print_status "Fetching availability domains..."
call :oci_cmd "iam availability-domain list --compartment-id %tenancy_ocid% --query 'data[].name' --raw-output" >temp_ads.txt 2>&1
for /f "tokens=*" %%a in ('powershell -NoProfile -Command "try { $json = Get-Content 'temp_ads.txt' -Raw | ConvertFrom-Json; if ($json -is [Array] -and $json.Count -gt 0) { Write-Output $json[0] } } catch { }" 2^>nul') do set "availability_domain=%%a"
del temp_ads.txt 2>nul
if "%availability_domain%"=="" (
    call :print_error "Failed to fetch availability domains"
    exit /b 1
)
call :print_success "Availability domain: %availability_domain%"
exit /b 0

:fetch_ubuntu_images
call :print_status "Fetching Ubuntu images for region %region%..."
call :print_status "  Looking for x86 Ubuntu image..."
call :oci_cmd "compute image list --compartment-id %tenancy_ocid% --operating-system 'Canonical Ubuntu' --shape '%FREE_TIER_AMD_SHAPE%' --sort-by TIMECREATED --sort-order DESC --query 'data[].{id:id,name:\"display-name\"}' --all" >temp_x86_images.txt 2>&1
for /f "tokens=*" %%a in ('powershell -NoProfile -Command "try { $json = Get-Content 'temp_x86_images.txt' -Raw | ConvertFrom-Json; if ($json -is [Array] -and $json.Count -gt 0) { Write-Output $json[0].id } } catch { }" 2^>nul') do set "ubuntu_image_ocid=%%a"
for /f "tokens=*" %%a in ('powershell -NoProfile -Command "try { $json = Get-Content 'temp_x86_images.txt' -Raw | ConvertFrom-Json; if ($json -is [Array] -and $json.Count -gt 0) { Write-Output $json[0].name } } catch { }" 2^>nul') do set "x86_name=%%a"
del temp_x86_images.txt 2>nul
if not "%ubuntu_image_ocid%"=="" if not "%ubuntu_image_ocid%"=="null" (
    call :print_success "  x86 image: %x86_name%"
    call :print_debug "  x86 OCID: %ubuntu_image_ocid%"
) else (
    call :print_warning "  No x86 Ubuntu image found - AMD instances disabled"
    set "ubuntu_image_ocid="
)
call :print_status "  Looking for ARM Ubuntu image..."
call :oci_cmd "compute image list --compartment-id %tenancy_ocid% --operating-system 'Canonical Ubuntu' --shape '%FREE_TIER_ARM_SHAPE%' --sort-by TIMECREATED --sort-order DESC --query 'data[].{id:id,name:\"display-name\"}' --all" >temp_arm_images.txt 2>&1
for /f "tokens=*" %%a in ('powershell -NoProfile -Command "try { $json = Get-Content 'temp_arm_images.txt' -Raw | ConvertFrom-Json; if ($json -is [Array] -and $json.Count -gt 0) { Write-Output $json[0].id } } catch { }" 2^>nul') do set "ubuntu_arm_flex_image_ocid=%%a"
for /f "tokens=*" %%a in ('powershell -NoProfile -Command "try { $json = Get-Content 'temp_arm_images.txt' -Raw | ConvertFrom-Json; if ($json -is [Array] -and $json.Count -gt 0) { Write-Output $json[0].name } } catch { }" 2^>nul') do set "arm_name=%%a"
del temp_arm_images.txt 2>nul
if not "%ubuntu_arm_flex_image_ocid%"=="" if not "%ubuntu_arm_flex_image_ocid%"=="null" (
    call :print_success "  ARM image: %arm_name%"
    call :print_debug "  ARM OCID: %ubuntu_arm_flex_image_ocid%"
) else (
    call :print_warning "  No ARM Ubuntu image found - ARM instances disabled"
    set "ubuntu_arm_flex_image_ocid="
)
exit /b 0

:generate_ssh_keys
call :print_status "Setting up SSH keys..."
set "ssh_dir=%CD%\ssh_keys"
if not exist "%ssh_dir%" mkdir "%ssh_dir%"
if not exist "%ssh_dir%\id_rsa" (
    call :print_status "Generating new SSH key pair..."
    ssh-keygen -t rsa -b 4096 -f "%ssh_dir%\id_rsa" -N "" -q
    icacls "%ssh_dir%\id_rsa" /inheritance:r /grant:r "%USERNAME%:F" >nul 2>&1
    call :print_success "SSH key pair generated at %ssh_dir%\"
) else (
    call :print_status "Using existing SSH key pair at %ssh_dir%\"
)
for /f "tokens=*" %%a in ('type "%ssh_dir%\id_rsa.pub"') do set "ssh_public_key=%%a"
exit /b 0

REM ============================================================================
REM COMPREHENSIVE RESOURCE INVENTORY
REM ============================================================================

:inventory_all_resources
call :print_header "COMPREHENSIVE RESOURCE INVENTORY"
call :print_status "Scanning all existing OCI resources in tenancy..."
call :print_status "This ensures we never create duplicate resources."
echo.
call :inventory_compute_instances
call :inventory_networking_resources
call :inventory_storage_resources
call :display_resource_inventory
exit /b 0

:inventory_compute_instances
call :print_status "Inventorying compute instances..."
call :oci_cmd "compute instance list --compartment-id %tenancy_ocid% --query 'data[?\"lifecycle-state\"!=\`TERMINATED\`].{id:id,name:\"display-name\",state:\"lifecycle-state\",shape:shape,ad:\"availability-domain\",created:\"time-created\"}' --all" >temp_instances.txt 2>&1
for /f "tokens=*" %%a in ('powershell -NoProfile -Command "try { $json = Get-Content 'temp_instances.txt' -Raw | ConvertFrom-Json; if ($json -is [Array]) { Write-Output $json.Count } else { Write-Output 0 } } catch { Write-Output 0 }" 2^>nul') do set "instance_count=%%a"
if "%instance_count%"=="" set "instance_count=0"
if "%instance_count%"=="0" (
    call :print_status "  No existing compute instances found"
    del temp_instances.txt 2>nul
    exit /b 0
)
set "amd_index=0"
set "arm_index=0"
powershell -NoProfile -Command "$json = Get-Content 'temp_instances.txt' -Raw | ConvertFrom-Json; if ($json -is [Array]) { $json | ForEach-Object { $_.id + '|' + $_.name + '|' + $_.state + '|' + $_.shape } | Out-File 'temp_instances_parsed.txt' -Encoding ASCII }" 2>nul
if exist temp_instances_parsed.txt (
    for /f "tokens=1,2,3,4 delims=|" %%a in (temp_instances_parsed.txt) do (
        set "id=%%a"
        set "name=%%b"
        set "state=%%c"
        set "shape=%%d"
    if not "!id!"=="" if not "!id!"=="null" (
        call :oci_cmd "compute vnic-attachment list --compartment-id %tenancy_ocid% --instance-id !id! --query 'data[?\"lifecycle-state\"==\`ATTACHED\`]'" >temp_vnics.txt 2>&1
        for /f "tokens=*" %%c in ('powershell -NoProfile -Command "try { $json = Get-Content 'temp_vnics.txt' -Raw | ConvertFrom-Json; if ($json -is [Array] -and $json.Count -gt 0) { Write-Output $json[0].'vnic-id' } } catch { }" 2^>nul') do set "vnic_id=%%c"
        if not "!vnic_id!"=="" if not "!vnic_id!"=="null" (
            call :oci_cmd "network vnic get --vnic-id !vnic_id!" >temp_vnic_details.txt 2>&1
            for /f "tokens=*" %%d in ('powershell -NoProfile -Command "try { $json = Get-Content 'temp_vnic_details.txt' -Raw | ConvertFrom-Json; Write-Output $json.data.'public-ip' } catch { }" 2^>nul') do set "public_ip=%%d"
            for /f "tokens=*" %%d in ('powershell -NoProfile -Command "try { $json = Get-Content 'temp_vnic_details.txt' -Raw | ConvertFrom-Json; Write-Output $json.data.'private-ip' } catch { }" 2^>nul') do set "private_ip=%%d"
            del temp_vnic_details.txt 2>nul
        )
        del temp_vnics.txt 2>nul
        if "!shape!"=="%FREE_TIER_AMD_SHAPE%" (
            set "EXISTING_AMD_INSTANCES_!amd_index!_id=!id!"
            set "EXISTING_AMD_INSTANCES_!amd_index!_name=!name!"
            set "EXISTING_AMD_INSTANCES_!amd_index!_state=!state!"
            set "EXISTING_AMD_INSTANCES_!amd_index!_public_ip=!public_ip!"
            set "EXISTING_AMD_INSTANCES_!amd_index!_private_ip=!private_ip!"
            set /a "amd_index+=1"
            call :print_status "  Found AMD instance: !name! (!state!) - IP: !public_ip!"
        ) else if "!shape!"=="%FREE_TIER_ARM_SHAPE%" (
            call :oci_cmd "compute instance get --instance-id !id!" >temp_arm_details.txt 2>&1
            for /f "tokens=*" %%e in ('powershell -NoProfile -Command "try { $json = Get-Content 'temp_arm_details.txt' -Raw | ConvertFrom-Json; Write-Output $json.data.'shape-config'.ocpus } catch { }" 2^>nul') do set "ocpus=%%e"
            for /f "tokens=*" %%e in ('powershell -NoProfile -Command "try { $json = Get-Content 'temp_arm_details.txt' -Raw | ConvertFrom-Json; Write-Output $json.data.'shape-config'.'memory-in-gbs' } catch { }" 2^>nul') do set "memory=%%e"
            del temp_arm_details.txt 2>nul
            set "EXISTING_ARM_INSTANCES_!arm_index!_id=!id!"
            set "EXISTING_ARM_INSTANCES_!arm_index!_name=!name!"
            set "EXISTING_ARM_INSTANCES_!arm_index!_state=!state!"
            set "EXISTING_ARM_INSTANCES_!arm_index!_public_ip=!public_ip!"
            set "EXISTING_ARM_INSTANCES_!arm_index!_private_ip=!private_ip!"
            set "EXISTING_ARM_INSTANCES_!arm_index!_ocpus=!ocpus!"
            set "EXISTING_ARM_INSTANCES_!arm_index!_memory=!memory!"
            set /a "arm_index+=1"
            call :print_status "  Found ARM instance: !name! (!state!, !ocpus!OCPUs, !memory!GB) - IP: !public_ip!"
        ) else (
            call :print_debug "  Found non-free-tier instance: !name! (!shape!)"
        )
        set "public_ip="
        set "private_ip="
    )
    )
    del temp_instances_parsed.txt 2>nul
)
set "EXISTING_AMD_INSTANCES_COUNT=!amd_index!"
set "EXISTING_ARM_INSTANCES_COUNT=!arm_index!"
call :print_status "  AMD instances: !amd_index!/%FREE_TIER_MAX_AMD_INSTANCES%"
call :print_status "  ARM instances: !arm_index!/%FREE_TIER_MAX_ARM_INSTANCES%"
del temp_instances.txt 2>nul
exit /b 0

:inventory_networking_resources
call :print_status "Inventorying networking resources..."
set "vcn_index=0"
call :oci_cmd "network vcn list --compartment-id %tenancy_ocid% --query 'data[?\"lifecycle-state\"==\`AVAILABLE\`].{id:id,name:\"display-name\",cidr:\"cidr-block\"}' --all" >temp_vcns.txt 2>&1
powershell -NoProfile -Command "$json = Get-Content 'temp_vcns.txt' -Raw | ConvertFrom-Json; if ($json -is [Array]) { $json | ForEach-Object { $_.id + '|' + $_.name + '|' + $_.cidr } | Out-File 'temp_vcns_parsed.txt' -Encoding ASCII }" 2>nul
if exist temp_vcns_parsed.txt (
    for /f "tokens=1,2,3 delims=|" %%a in (temp_vcns_parsed.txt) do (
        set "vcn_id=%%a"
        set "vcn_name=%%b"
        set "vcn_cidr=%%c"
    if not "!vcn_id!"=="" if not "!vcn_id!"=="null" (
        set "EXISTING_VCNS_!vcn_index!_id=!vcn_id!"
        set "EXISTING_VCNS_!vcn_index!_name=!vcn_name!"
        set "EXISTING_VCNS_!vcn_index!_cidr=!vcn_cidr!"
        set /a "vcn_index+=1"
        call :print_status "  Found VCN: !vcn_name! (!vcn_cidr!)"
        REM Get subnets, IGs, route tables, security lists for this VCN
    )
    )
    del temp_vcns_parsed.txt 2>nul
)
set "EXISTING_VCNS_COUNT=!vcn_index!"
call :print_status "  VCNs: !vcn_index!/%FREE_TIER_MAX_VCNS%"
del temp_vcns.txt 2>nul
exit /b 0

:inventory_storage_resources
call :print_status "Inventorying storage resources..."
set "boot_index=0"
set "block_index=0"
set "total_boot_gb=0"
set "total_block_gb=0"
call :oci_cmd "bv boot-volume list --compartment-id %tenancy_ocid% --availability-domain %availability_domain% --query 'data[?\"lifecycle-state\"==\`AVAILABLE\`].{id:id,name:\"display-name\",size:\"size-in-gbs\"}' --all" >temp_boot.txt 2>&1
powershell -NoProfile -Command "$json = Get-Content 'temp_boot.txt' -Raw | ConvertFrom-Json; if ($json -is [Array]) { $json | ForEach-Object { $_.id + '|' + $_.name + '|' + $_.size } | Out-File 'temp_boot_parsed.txt' -Encoding ASCII }" 2>nul
if exist temp_boot_parsed.txt (
    for /f "tokens=1,2,3 delims=|" %%a in (temp_boot_parsed.txt) do (
        set "boot_id=%%a"
        set "boot_name=%%b"
        set "boot_size=%%c"
    if not "!boot_id!"=="" if not "!boot_id!"=="null" (
        set "EXISTING_BOOT_VOLUMES_!boot_index!_id=!boot_id!"
        set "EXISTING_BOOT_VOLUMES_!boot_index!_name=!boot_name!"
        set "EXISTING_BOOT_VOLUMES_!boot_index!_size=!boot_size!"
        set /a "total_boot_gb+=!boot_size!"
        set /a "boot_index+=1"
    )
    )
    del temp_boot_parsed.txt 2>nul
)
set "EXISTING_BOOT_VOLUMES_COUNT=!boot_index!"
call :oci_cmd "bv volume list --compartment-id %tenancy_ocid% --availability-domain %availability_domain% --query 'data[?\"lifecycle-state\"==\`AVAILABLE\`].{id:id,name:\"display-name\",size:\"size-in-gbs\"}' --all" >temp_block.txt 2>&1
powershell -NoProfile -Command "$json = Get-Content 'temp_block.txt' -Raw | ConvertFrom-Json; if ($json -is [Array]) { $json | ForEach-Object { $_.id + '|' + $_.name + '|' + $_.size } | Out-File 'temp_block_parsed.txt' -Encoding ASCII }" 2>nul
if exist temp_block_parsed.txt (
    for /f "tokens=1,2,3 delims=|" %%a in (temp_block_parsed.txt) do (
        set "block_id=%%a"
        set "block_name=%%b"
        set "block_size=%%c"
    if not "!block_id!"=="" if not "!block_id!"=="null" (
        set "EXISTING_BLOCK_VOLUMES_!block_index!_id=!block_id!"
        set "EXISTING_BLOCK_VOLUMES_!block_index!_name=!block_name!"
        set "EXISTING_BLOCK_VOLUMES_!block_index!_size=!block_size!"
        set /a "total_block_gb+=!block_size!"
        set /a "block_index+=1"
    )
    )
    del temp_block_parsed.txt 2>nul
)
set "EXISTING_BLOCK_VOLUMES_COUNT=!block_index!"
set /a "total_storage=!total_boot_gb! + !total_block_gb!"
call :print_status "  Boot volumes: !boot_index! (!total_boot_gb!GB)"
call :print_status "  Block volumes: !block_index! (!total_block_gb!GB)"
call :print_status "  Total storage: !total_storage!GB/%FREE_TIER_MAX_STORAGE_GB%GB"
del temp_boot.txt temp_block.txt 2>nul
exit /b 0

:display_resource_inventory
echo.
call :print_header "RESOURCE INVENTORY SUMMARY"
setlocal enabledelayedexpansion
set "total_amd=%EXISTING_AMD_INSTANCES_COUNT%"
set "total_arm=%EXISTING_ARM_INSTANCES_COUNT%"
set "total_arm_ocpus=0"
set "total_arm_memory=0"
for /l %%i in (0,1,%EXISTING_ARM_INSTANCES_COUNT%) do (
    if defined EXISTING_ARM_INSTANCES_%%i_ocpus (
        set /a "total_arm_ocpus+=!EXISTING_ARM_INSTANCES_%%i_ocpus!"
    )
    if defined EXISTING_ARM_INSTANCES_%%i_memory (
        set /a "total_arm_memory+=!EXISTING_ARM_INSTANCES_%%i_memory!"
    )
)
set "total_boot_gb=0"
for /l %%i in (0,1,%EXISTING_BOOT_VOLUMES_COUNT%) do (
    if defined EXISTING_BOOT_VOLUMES_%%i_size (
        set /a "total_boot_gb+=!EXISTING_BOOT_VOLUMES_%%i_size!"
    )
)
set "total_block_gb=0"
for /l %%i in (0,1,%EXISTING_BLOCK_VOLUMES_COUNT%) do (
    if defined EXISTING_BLOCK_VOLUMES_%%i_size (
        set /a "total_block_gb+=!EXISTING_BLOCK_VOLUMES_%%i_size!"
    )
)
set /a "total_storage=!total_boot_gb! + !total_block_gb!"
echo Compute Resources:
echo   +-------------------------------------------------------------+
echo   ^| AMD Micro Instances:  %total_amd% / %FREE_TIER_MAX_AMD_INSTANCES% (Free Tier limit)          ^|
echo   ^| ARM A1 Instances:     %total_arm% / %FREE_TIER_MAX_ARM_INSTANCES% (up to)                    ^|
echo   ^| ARM OCPUs Used:       %total_arm_ocpus% / %FREE_TIER_MAX_ARM_OCPUS%                           ^|
echo   ^| ARM Memory Used:      %total_arm_memory%GB / %FREE_TIER_MAX_ARM_MEMORY_GB%GB                         ^|
echo   +-------------------------------------------------------------+
echo.
echo Storage Resources:
echo   +-------------------------------------------------------------+
echo   ^| Boot Volumes:         %total_boot_gb%GB                                    ^|
echo   ^| Block Volumes:        %total_block_gb%GB                                    ^|
echo   ^| Total Storage:        %total_storage%GB / %FREE_TIER_MAX_STORAGE_GB%GB Free Tier limit          ^|
echo   +-------------------------------------------------------------+
echo.
echo Networking Resources:
echo   +-------------------------------------------------------------+
echo   ^| VCNs:                 %EXISTING_VCNS_COUNT% / %FREE_TIER_MAX_VCNS% (Free Tier limit)             ^|
echo   +-------------------------------------------------------------+
echo.
if %total_amd% geq %FREE_TIER_MAX_AMD_INSTANCES% (
    call :print_warning "AMD instance limit reached - cannot create more AMD instances"
)
if %total_arm_ocpus% geq %FREE_TIER_MAX_ARM_OCPUS% (
    call :print_warning "ARM OCPU limit reached - cannot allocate more ARM OCPUs"
)
if %total_arm_memory% geq %FREE_TIER_MAX_ARM_MEMORY_GB% (
    call :print_warning "ARM memory limit reached - cannot allocate more ARM memory"
)
if %total_storage% geq %FREE_TIER_MAX_STORAGE_GB% (
    call :print_warning "Storage limit reached - cannot create more volumes"
)
if %EXISTING_VCNS_COUNT% geq %FREE_TIER_MAX_VCNS% (
    call :print_warning "VCN limit reached - cannot create more VCNs"
)
endlocal
exit /b 0

REM ============================================================================
REM FREE TIER LIMIT VALIDATION
REM ============================================================================

:calculate_available_resources
setlocal enabledelayedexpansion
set "used_amd=%EXISTING_AMD_INSTANCES_COUNT%"
set "used_arm_ocpus=0"
set "used_arm_memory=0"
set "used_storage=0"
for /l %%i in (0,1,%EXISTING_ARM_INSTANCES_COUNT%) do (
    if defined EXISTING_ARM_INSTANCES_%%i_ocpus (
        set /a "used_arm_ocpus+=!EXISTING_ARM_INSTANCES_%%i_ocpus!"
    )
    if defined EXISTING_ARM_INSTANCES_%%i_memory (
        set /a "used_arm_memory+=!EXISTING_ARM_INSTANCES_%%i_memory!"
    )
)
for /l %%i in (0,1,%EXISTING_BOOT_VOLUMES_COUNT%) do (
    if defined EXISTING_BOOT_VOLUMES_%%i_size (
        set /a "used_storage+=!EXISTING_BOOT_VOLUMES_%%i_size!"
    )
)
for /l %%i in (0,1,%EXISTING_BLOCK_VOLUMES_COUNT%) do (
    if defined EXISTING_BLOCK_VOLUMES_%%i_size (
        set /a "used_storage+=!EXISTING_BLOCK_VOLUMES_%%i_size!"
    )
)
set /a "AVAILABLE_AMD_INSTANCES=%FREE_TIER_MAX_AMD_INSTANCES% - !used_amd!"
set /a "AVAILABLE_ARM_OCPUS=%FREE_TIER_MAX_ARM_OCPUS% - !used_arm_ocpus!"
set /a "AVAILABLE_ARM_MEMORY=%FREE_TIER_MAX_ARM_MEMORY_GB% - !used_arm_memory!"
set /a "AVAILABLE_STORAGE=%FREE_TIER_MAX_STORAGE_GB% - !used_storage!"
set "USED_ARM_INSTANCES=%EXISTING_ARM_INSTANCES_COUNT%"
call :print_debug "Available: AMD=!AVAILABLE_AMD_INSTANCES!, ARM_OCPU=!AVAILABLE_ARM_OCPUS!, ARM_MEM=!AVAILABLE_ARM_MEMORY!, Storage=!AVAILABLE_STORAGE!"
endlocal
exit /b 0

:validate_proposed_config
setlocal enabledelayedexpansion
set "proposed_amd=%~1"
set "proposed_arm=%~2"
set "proposed_arm_ocpus=%~3"
set "proposed_arm_memory=%~4"
set "proposed_storage=%~5"
set "errors=0"
call :calculate_available_resources
if !proposed_amd! gtr !AVAILABLE_AMD_INSTANCES! (
    call :print_error "Cannot create !proposed_amd! AMD instances - only !AVAILABLE_AMD_INSTANCES! available"
    set /a "errors+=1"
)
if !proposed_arm_ocpus! gtr !AVAILABLE_ARM_OCPUS! (
    call :print_error "Cannot allocate !proposed_arm_ocpus! ARM OCPUs - only !AVAILABLE_ARM_OCPUS! available"
    set /a "errors+=1"
)
if !proposed_arm_memory! gtr !AVAILABLE_ARM_MEMORY! (
    call :print_error "Cannot allocate !proposed_arm_memory!GB ARM memory - only !AVAILABLE_ARM_MEMORY!GB available"
    set /a "errors+=1"
)
if !proposed_storage! gtr !AVAILABLE_STORAGE! (
    call :print_error "Cannot use !proposed_storage!GB storage - only !AVAILABLE_STORAGE!GB available"
    set /a "errors+=1"
)
endlocal
exit /b %errors%

REM ============================================================================
REM CONFIGURATION FUNCTIONS
REM ============================================================================

:load_existing_config
if not exist "variables.tf" exit /b 1
call :print_status "Loading existing configuration from variables.tf..."
for /f "tokens=3 delims== " %%a in ('findstr /c:"amd_micro_instance_count" "variables.tf" 2^>nul') do set "amd_micro_instance_count=%%a"
if "%amd_micro_instance_count%"=="" set "amd_micro_instance_count=0"
for /f "tokens=3 delims== " %%a in ('findstr /c:"amd_micro_boot_volume_size_gb" "variables.tf" 2^>nul') do set "amd_micro_boot_volume_size_gb=%%a"
if "%amd_micro_boot_volume_size_gb%"=="" set "amd_micro_boot_volume_size_gb=50"
for /f "tokens=3 delims== " %%a in ('findstr /c:"arm_flex_instance_count" "variables.tf" 2^>nul') do set "arm_flex_instance_count=%%a"
if "%arm_flex_instance_count%"=="" set "arm_flex_instance_count=0"
call :print_success "Loaded configuration: %amd_micro_instance_count%x AMD, %arm_flex_instance_count%x ARM"
exit /b 0

:prompt_configuration
call :print_header "INSTANCE CONFIGURATION"
call :calculate_available_resources
echo Available Free Tier Resources:
echo   • AMD instances:  %AVAILABLE_AMD_INSTANCES% available (max %FREE_TIER_MAX_AMD_INSTANCES%)
echo   • ARM OCPUs:      %AVAILABLE_ARM_OCPUS% available (max %FREE_TIER_MAX_ARM_OCPUS%)
echo   • ARM Memory:     %AVAILABLE_ARM_MEMORY%GB available (max %FREE_TIER_MAX_ARM_MEMORY_GB%GB)
echo   • Storage:        %AVAILABLE_STORAGE%GB available (max %FREE_TIER_MAX_STORAGE_GB%GB)
echo.
set "has_existing_config=false"
call :load_existing_config
if not errorlevel 1 set "has_existing_config=true"
call :print_status "Configuration options:"
echo   1) Use existing instances (manage what's already deployed)
if "%has_existing_config%"=="true" (
    echo   2) Use saved configuration from variables.tf
) else (
    echo   2) Use saved configuration from variables.tf (not available)
)
echo   3) Configure new instances (respecting Free Tier limits)
echo   4) Maximum Free Tier configuration (use all available resources)
echo.
if "%AUTO_USE_EXISTING%"=="true" (
    set "choice=1"
    call :print_status "Auto mode: Using existing instances"
) else if "%NON_INTERACTIVE%"=="true" (
    set "choice=1"
    call :print_status "Non-interactive mode: Using existing instances"
) else (
    for /f "tokens=*" %%a in ('call :prompt_with_default "Choose configuration (1-4)" "1"') do set "choice=%%a"
)
if "%choice%"=="1" (
    call :configure_from_existing_instances
) else if "%choice%"=="2" (
    if "%has_existing_config%"=="true" (
        call :print_success "Using saved configuration"
    ) else (
        call :print_error "No saved configuration available"
        goto prompt_configuration
    )
) else if "%choice%"=="3" (
    call :configure_custom_instances
) else if "%choice%"=="4" (
    call :configure_maximum_free_tier
) else (
    call :print_error "Invalid choice"
    goto prompt_configuration
)
exit /b 0

:configure_from_existing_instances
call :print_status "Configuring based on existing instances..."
setlocal enabledelayedexpansion
set "amd_micro_instance_count=%EXISTING_AMD_INSTANCES_COUNT%"
set "amd_micro_hostnames="
for /l %%i in (0,1,%EXISTING_AMD_INSTANCES_COUNT%) do (
    if defined EXISTING_AMD_INSTANCES_%%i_name (
        set "amd_micro_hostnames=!amd_micro_hostnames! !EXISTING_AMD_INSTANCES_%%i_name!"
    )
)
set "arm_flex_instance_count=%EXISTING_ARM_INSTANCES_COUNT%"
set "arm_flex_hostnames="
set "arm_flex_ocpus_per_instance="
set "arm_flex_memory_per_instance="
set "arm_flex_boot_volume_size_gb="
set "arm_flex_block_volumes="
for /l %%i in (0,1,%EXISTING_ARM_INSTANCES_COUNT%) do (
    if defined EXISTING_ARM_INSTANCES_%%i_name (
        set "arm_flex_hostnames=!arm_flex_hostnames! !EXISTING_ARM_INSTANCES_%%i_name!"
    )
    if defined EXISTING_ARM_INSTANCES_%%i_ocpus (
        set "arm_flex_ocpus_per_instance=!arm_flex_ocpus_per_instance! !EXISTING_ARM_INSTANCES_%%i_ocpus!"
    )
    if defined EXISTING_ARM_INSTANCES_%%i_memory (
        set "arm_flex_memory_per_instance=!arm_flex_memory_per_instance! !EXISTING_ARM_INSTANCES_%%i_memory!"
    )
    set "arm_flex_boot_volume_size_gb=!arm_flex_boot_volume_size_gb! 50"
    set "arm_flex_block_volumes=!arm_flex_block_volumes! 0"
)
if "%amd_micro_instance_count%"=="0" if "%arm_flex_instance_count%"=="0" (
    call :print_status "No existing instances found, using default configuration"
    set "amd_micro_instance_count=0"
    set "arm_flex_instance_count=1"
    set "arm_flex_ocpus_per_instance=4"
    set "arm_flex_memory_per_instance=24"
    set "arm_flex_boot_volume_size_gb=200"
    set "arm_flex_hostnames=arm-instance-1"
    set "arm_flex_block_volumes=0"
)
set "amd_micro_boot_volume_size_gb=50"
call :print_success "Configuration: %amd_micro_instance_count%x AMD, %arm_flex_instance_count%x ARM"
endlocal
exit /b 0

:configure_custom_instances
call :print_status "Custom instance configuration..."
call :calculate_available_resources
for /f "tokens=*" %%a in ('call :prompt_int_range "Number of AMD instances (0-%AVAILABLE_AMD_INSTANCES%)" "0" "0" "%AVAILABLE_AMD_INSTANCES%"') do set "amd_micro_instance_count=%%a"
set "amd_micro_hostnames="
if "%amd_micro_instance_count%" gtr "0" (
    for /f "tokens=*" %%a in ('call :prompt_int_range "AMD boot volume size GB (50-100)" "50" "50" "100"') do set "amd_micro_boot_volume_size_gb=%%a"
    for /l %%i in (1,1,%amd_micro_instance_count%) do (
        set /p "hostname=Hostname for AMD instance %%i [amd-instance-%%i]: "
        if "!hostname!"=="" set "hostname=amd-instance-%%i"
        set "amd_micro_hostnames=!amd_micro_hostnames! !hostname!"
    )
) else (
    set "amd_micro_boot_volume_size_gb=50"
)
if not "%ubuntu_arm_flex_image_ocid%"=="" if %AVAILABLE_ARM_OCPUS% gtr 0 (
    for /f "tokens=*" %%a in ('call :prompt_int_range "Number of ARM instances (0-4)" "1" "0" "4"') do set "arm_flex_instance_count=%%a"
    set "arm_flex_hostnames="
    set "arm_flex_ocpus_per_instance="
    set "arm_flex_memory_per_instance="
    set "arm_flex_boot_volume_size_gb="
    set "arm_flex_block_volumes="
    set "remaining_ocpus=%AVAILABLE_ARM_OCPUS%"
    set "remaining_memory=%AVAILABLE_ARM_MEMORY%"
    for /l %%i in (1,1,%arm_flex_instance_count%) do (
        echo.
        call :print_status "ARM instance %%i configuration (remaining: !remaining_ocpus! OCPUs, !remaining_memory!GB RAM):"
        set /p "hostname=  Hostname [arm-instance-%%i]: "
        if "!hostname!"=="" set "hostname=arm-instance-%%i"
        set "arm_flex_hostnames=!arm_flex_hostnames! !hostname!"
        for /f "tokens=*" %%b in ('call :prompt_int_range "  OCPUs (1-!remaining_ocpus!)" "!remaining_ocpus!" "1" "!remaining_ocpus!"') do set "ocpus=%%b"
        set "arm_flex_ocpus_per_instance=!arm_flex_ocpus_per_instance! !ocpus!"
        set /a "remaining_ocpus-=!ocpus!"
        set /a "max_memory=!ocpus! * 6"
        if !max_memory! gtr !remaining_memory! set "max_memory=!remaining_memory!"
        for /f "tokens=*" %%b in ('call :prompt_int_range "  Memory GB (1-!max_memory!)" "!max_memory!" "1" "!max_memory!"') do set "memory=%%b"
        set "arm_flex_memory_per_instance=!arm_flex_memory_per_instance! !memory!"
        set /a "remaining_memory-=!memory!"
        for /f "tokens=*" %%b in ('call :prompt_int_range "  Boot volume GB (50-200)" "50" "50" "200"') do set "boot=%%b"
        set "arm_flex_boot_volume_size_gb=!arm_flex_boot_volume_size_gb! !boot!"
        set "arm_flex_block_volumes=!arm_flex_block_volumes! 0"
    )
) else (
    set "arm_flex_instance_count=0"
    set "arm_flex_ocpus_per_instance="
    set "arm_flex_memory_per_instance="
    set "arm_flex_boot_volume_size_gb="
    set "arm_flex_block_volumes="
    set "arm_flex_hostnames="
)
exit /b 0

:configure_maximum_free_tier
call :print_status "Configuring maximum Free Tier utilization..."
call :calculate_available_resources
setlocal enabledelayedexpansion
set "amd_micro_instance_count=%AVAILABLE_AMD_INSTANCES%"
set "amd_micro_boot_volume_size_gb=50"
set "amd_micro_hostnames="
for /l %%i in (1,1,%AVAILABLE_AMD_INSTANCES%) do (
    set "amd_micro_hostnames=!amd_micro_hostnames! amd-instance-%%i"
)
if not "%ubuntu_arm_flex_image_ocid%"=="" if %AVAILABLE_ARM_OCPUS% gtr 0 (
    set "arm_flex_instance_count=1"
    set "arm_flex_ocpus_per_instance=%AVAILABLE_ARM_OCPUS%"
    set "arm_flex_memory_per_instance=%AVAILABLE_ARM_MEMORY%"
    set /a "used_by_amd=%amd_micro_instance_count% * %amd_micro_boot_volume_size_gb%"
    set /a "remaining_storage=%AVAILABLE_STORAGE% - !used_by_amd!"
    if !remaining_storage! lss %FREE_TIER_MIN_BOOT_VOLUME_GB% set "remaining_storage=%FREE_TIER_MIN_BOOT_VOLUME_GB%"
    set "arm_flex_boot_volume_size_gb=!remaining_storage!"
    set "arm_flex_hostnames=arm-instance-1"
    set "arm_flex_block_volumes=0"
) else (
    set "arm_flex_instance_count=0"
    set "arm_flex_ocpus_per_instance="
    set "arm_flex_memory_per_instance="
    set "arm_flex_boot_volume_size_gb="
    set "arm_flex_hostnames="
    set "arm_flex_block_volumes="
)
call :print_success "Maximum config: %amd_micro_instance_count%x AMD, %arm_flex_instance_count%x ARM (%AVAILABLE_ARM_OCPUS% OCPUs, %AVAILABLE_ARM_MEMORY%GB)"
endlocal
exit /b 0

REM ============================================================================
REM TERRAFORM FILE GENERATION
REM ============================================================================

:create_terraform_files
call :print_header "GENERATING TERRAFORM FILES"
call :create_terraform_provider
call :create_terraform_variables
call :create_terraform_datasources
call :create_terraform_main
call :create_terraform_block_volumes
call :create_cloud_init
call :print_success "All Terraform files generated successfully"
exit /b 0

:create_terraform_provider
call :print_status "Creating provider.tf..."
call :configure_terraform_backend
if exist "provider.tf" (
    for /f "tokens=2-4 delims=/ " %%a in ('date /t') do set "backup_date=%%c%%a%%b"
    for /f "tokens=1-2 delims=: " %%a in ('time /t') do set "backup_time=%%a%%b"
    copy "provider.tf" "provider.tf.bak.%backup_date%_%backup_time%" >nul 2>&1
)
(
echo # Terraform Provider Configuration for Oracle Cloud Infrastructure
echo # Generated: %date% %time%
echo # Region: %region%
echo.
echo terraform {
echo   required_version = "^>= 1.0"
echo   required_providers {
echo     oci = {
echo       source  = "oracle/oci"
echo       version = "~^> 6.0"
echo     }
echo   }
echo }
echo.
echo # OCI Provider with session token authentication
echo provider "oci" {
echo   auth                = "SecurityToken"
echo   config_file_profile = "DEFAULT"
echo   region              = "%region%"
echo }
) > provider.tf
call :print_success "provider.tf created"
exit /b 0

:create_terraform_variables
call :print_status "Creating variables.tf..."
if exist "variables.tf" (
    for /f "tokens=2-4 delims=/ " %%a in ('date /t') do set "backup_date=%%c%%a%%b"
    for /f "tokens=1-2 delims=: " %%a in ('time /t') do set "backup_time=%%a%%b"
    copy "variables.tf" "variables.tf.bak.%backup_date%_%backup_time%" >nul 2>&1
)
setlocal enabledelayedexpansion
set "amd_hostnames_tf=["
set "hostname_index=0"
for %%h in (%amd_micro_hostnames%) do (
    if !hostname_index! gtr 0 set "amd_hostnames_tf=!amd_hostnames_tf!, "
    set "amd_hostnames_tf=!amd_hostnames_tf!\"%%h\""
    set /a "hostname_index+=1"
)
set "amd_hostnames_tf=!amd_hostnames_tf!]"
set "arm_hostnames_tf=["
set "hostname_index=0"
for %%h in (%arm_flex_hostnames%) do (
    if !hostname_index! gtr 0 set "arm_hostnames_tf=!arm_hostnames_tf!, "
    set "arm_hostnames_tf=!arm_hostnames_tf!\"%%h\""
    set /a "hostname_index+=1"
)
set "arm_hostnames_tf=!arm_hostnames_tf!]"
set "arm_ocpus_tf=["
set "arm_memory_tf=["
set "arm_boot_tf=["
set "arm_block_tf=["
if %arm_flex_instance_count% gtr 0 (
    set "ocpu_index=0"
    for %%o in (%arm_flex_ocpus_per_instance%) do (
        if !ocpu_index! gtr 0 (
            set "arm_ocpus_tf=!arm_ocpus_tf!, "
            set "arm_memory_tf=!arm_memory_tf!, "
            set "arm_boot_tf=!arm_boot_tf!, "
            set "arm_block_tf=!arm_block_tf!, "
        )
        set "arm_ocpus_tf=!arm_ocpus_tf!%%o"
        set /a "ocpu_index+=1"
    )
    set "memory_index=0"
    for %%m in (%arm_flex_memory_per_instance%) do (
        if !memory_index! gtr 0 set "arm_memory_tf=!arm_memory_tf!, "
        set "arm_memory_tf=!arm_memory_tf!%%m"
        set /a "memory_index+=1"
    )
    set "boot_index=0"
    for %%b in (%arm_flex_boot_volume_size_gb%) do (
        if !boot_index! gtr 0 set "arm_boot_tf=!arm_boot_tf!, "
        set "arm_boot_tf=!arm_boot_tf!%%b"
        set /a "boot_index+=1"
    )
    set "block_index=0"
    for %%v in (%arm_flex_block_volumes%) do (
        if !block_index! gtr 0 set "arm_block_tf=!arm_block_tf!, "
        set "arm_block_tf=!arm_block_tf!%%v"
        set /a "block_index+=1"
    )
)
set "arm_ocpus_tf=!arm_ocpus_tf!]"
set "arm_memory_tf=!arm_memory_tf!]"
set "arm_boot_tf=!arm_boot_tf!]"
set "arm_block_tf=!arm_block_tf!]"
(
echo # Oracle Cloud Infrastructure Terraform Variables
echo # Generated: %date% %time%
echo # Configuration: %amd_micro_instance_count%x AMD + %arm_flex_instance_count%x ARM instances
echo.
echo locals {
echo   # Core identifiers
echo   tenancy_ocid    = "%tenancy_ocid%"
echo   compartment_id  = "%tenancy_ocid%"
echo   user_ocid       = "%user_ocid%"
echo   region          = "%region%"
echo.
echo   # Ubuntu Images (region-specific)
echo   ubuntu_x86_image_ocid = "%ubuntu_image_ocid%"
echo   ubuntu_arm_image_ocid = "%ubuntu_arm_flex_image_ocid%"
echo.
echo   # SSH Configuration
echo   ssh_pubkey_path      = pathexpand("./ssh_keys/id_rsa.pub")
echo   ssh_pubkey_data      = file(pathexpand("./ssh_keys/id_rsa.pub"))
echo   ssh_private_key_path = pathexpand("./ssh_keys/id_rsa")
echo.
echo   # AMD x86 Micro Instances Configuration
echo   amd_micro_instance_count      = %amd_micro_instance_count%
echo   amd_micro_boot_volume_size_gb = %amd_micro_boot_volume_size_gb%
echo   amd_micro_hostnames           = !amd_hostnames_tf!
echo   amd_block_volume_size_gb      = 0
echo.
echo   # ARM A1 Flex Instances Configuration
echo   arm_flex_instance_count       = %arm_flex_instance_count%
echo   arm_flex_ocpus_per_instance   = !arm_ocpus_tf!
echo   arm_flex_memory_per_instance  = !arm_memory_tf!
echo   arm_flex_boot_volume_size_gb  = !arm_boot_tf!
echo   arm_flex_hostnames            = !arm_hostnames_tf!
echo   arm_block_volume_sizes        = !arm_block_tf!
echo.
echo   # Storage calculations
echo   total_amd_storage = local.amd_micro_instance_count * local.amd_micro_boot_volume_size_gb
echo   total_arm_storage = local.arm_flex_instance_count ^> 0 ? sum(local.arm_flex_boot_volume_size_gb) : 0
echo   total_block_storage = (local.amd_micro_instance_count * local.amd_block_volume_size_gb) + (local.arm_flex_instance_count ^> 0 ? sum(local.arm_block_volume_sizes) : 0)
echo   total_storage = local.total_amd_storage + local.total_arm_storage + local.total_block_storage
echo }
echo.
echo # Free Tier Limits
echo variable "free_tier_max_storage_gb" {
echo   description = "Maximum storage for Oracle Free Tier"
echo   type        = number
echo   default     = %FREE_TIER_MAX_STORAGE_GB%
echo }
echo.
echo variable "free_tier_max_arm_ocpus" {
echo   description = "Maximum ARM OCPUs for Oracle Free Tier"
echo   type        = number
echo   default     = %FREE_TIER_MAX_ARM_OCPUS%
echo }
echo.
echo variable "free_tier_max_arm_memory_gb" {
echo   description = "Maximum ARM memory for Oracle Free Tier"
echo   type        = number
echo   default     = %FREE_TIER_MAX_ARM_MEMORY_GB%
echo }
echo.
echo # Validation checks
echo check "storage_limit" {
echo   assert {
echo     condition     = local.total_storage ^<= var.free_tier_max_storage_gb
echo     error_message = "Total storage (${local.total_storage}GB) exceeds Free Tier limit (${var.free_tier_max_storage_gb}GB)"
echo   }
echo }
echo.
echo check "arm_ocpu_limit" {
echo   assert {
echo     condition     = local.arm_flex_instance_count == 0 ^|^| sum(local.arm_flex_ocpus_per_instance) ^<= var.free_tier_max_arm_ocpus
echo     error_message = "Total ARM OCPUs exceed Free Tier limit (${var.free_tier_max_arm_ocpus})"
echo   }
echo }
echo.
echo check "arm_memory_limit" {
echo   assert {
echo     condition     = local.arm_flex_instance_count == 0 ^|^| sum(local.arm_flex_memory_per_instance) ^<= var.free_tier_max_arm_memory_gb
echo     error_message = "Total ARM memory exceeds Free Tier limit (${var.free_tier_max_arm_memory_gb}GB)"
echo   }
echo }
) > variables.tf
endlocal
call :print_success "variables.tf created"
exit /b 0

:create_terraform_datasources
call :print_status "Creating data_sources.tf..."
if exist "data_sources.tf" (
    for /f "tokens=2-4 delims=/ " %%a in ('date /t') do set "backup_date=%%c%%a%%b"
    for /f "tokens=1-2 delims=: " %%a in ('time /t') do set "backup_time=%%a%%b"
    copy "data_sources.tf" "data_sources.tf.bak.%backup_date%_%backup_time%" >nul 2>&1
)
(
echo # OCI Data Sources
echo # Fetches dynamic information from Oracle Cloud
echo.
echo # Availability Domains
echo data "oci_identity_availability_domains" "ads" {
echo   compartment_id = local.tenancy_ocid
echo }
echo.
echo # Tenancy Information
echo data "oci_identity_tenancy" "tenancy" {
echo   tenancy_id = local.tenancy_ocid
echo }
echo.
echo # Available Regions
echo data "oci_identity_regions" "regions" {}
echo.
echo # Region Subscriptions
echo data "oci_identity_region_subscriptions" "subscriptions" {
echo   tenancy_id = local.tenancy_ocid
echo }
) > data_sources.tf
call :print_success "data_sources.tf created"
exit /b 0

:create_terraform_main
call :print_status "Creating main.tf..."
if exist "main.tf" (
    for /f "tokens=2-4 delims=/ " %%a in ('date /t') do set "backup_date=%%c%%a%%b"
    for /f "tokens=1-2 delims=: " %%a in ('time /t') do set "backup_time=%%a%%b"
    copy "main.tf" "main.tf.bak.%backup_date%_%backup_time%" >nul 2>&1
)
REM Main.tf is very large - using a here-document equivalent via PowerShell
powershell -Command "$content = @'
# Oracle Cloud Infrastructure - Main Configuration
# Always Free Tier Optimized

# ============================================================================
# NETWORKING
# ============================================================================

resource \"oci_core_vcn\" \"main\" {
  compartment_id = local.compartment_id
  cidr_blocks    = [\"10.0.0.0/16\"]
  display_name   = \"main-vcn\"
  dns_label      = \"mainvcn\"
  is_ipv6enabled = true
  
  freeform_tags = {
    \"Purpose\" = \"AlwaysFreeTier\"
    \"Managed\" = \"Terraform\"
  }
}

resource \"oci_core_internet_gateway\" \"main\" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = \"main-igw\"
  enabled        = true
}

resource \"oci_core_default_route_table\" \"main\" {
  manage_default_resource_id = oci_core_vcn.main.default_route_table_id
  display_name               = \"main-rt\"
  
  route_rules {
    destination       = \"0.0.0.0/0\"
    destination_type  = \"CIDR_BLOCK\"
    network_entity_id = oci_core_internet_gateway.main.id
  }
  
  route_rules {
    destination       = \"::/0\"
    destination_type  = \"CIDR_BLOCK\"
    network_entity_id = oci_core_internet_gateway.main.id
  }
}

resource \"oci_core_default_security_list\" \"main\" {
  manage_default_resource_id = oci_core_vcn.main.default_security_list_id
  display_name               = \"main-sl\"
  
  # Allow all egress
  egress_security_rules {
    destination = \"0.0.0.0/0\"
    protocol    = \"all\"
  }
  
  egress_security_rules {
    destination = \"::/0\"
    protocol    = \"all\"
  }
  
  # SSH (IPv4)
  ingress_security_rules {
    protocol = \"6\"
    source   = \"0.0.0.0/0\"
    tcp_options {
      min = 22
      max = 22
    }
  }
  # SSH (IPv6)
  ingress_security_rules {
    protocol = \"6\"
    source   = \"::/0\"
    tcp_options {
      min = 22
      max = 22
    }
  }
  
  # HTTP (IPv4)
  ingress_security_rules {
    protocol = \"6\"
    source   = \"0.0.0.0/0\"
    tcp_options {
      min = 80
      max = 80
    }
  }
  # HTTP (IPv6)
  ingress_security_rules {
    protocol = \"6\"
    source   = \"::/0\"
    tcp_options {
      min = 80
      max = 80
    }
  }
  
  # HTTPS (IPv4)
  ingress_security_rules {
    protocol = \"6\"
    source   = \"0.0.0.0/0\"
    tcp_options {
      min = 443
      max = 443
    }
  }
  # HTTPS (IPv6)
  ingress_security_rules {
    protocol = \"6\"
    source   = \"::/0\"
    tcp_options {
      min = 443
      max = 443
    }
  }
  
  # ICMP (IPv4)
  ingress_security_rules {
    protocol = \"1\"
    source   = \"0.0.0.0/0\"
  }
  # ICMP (IPv6)
  ingress_security_rules {
    protocol = \"1\"
    source   = \"::/0\"
  }
}

resource \"oci_core_subnet\" \"main\" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.main.id
  cidr_block     = \"10.0.1.0/24\"
  display_name   = \"main-subnet\"
  dns_label      = \"mainsubnet\"
  
  route_table_id    = oci_core_default_route_table.main.id
  security_list_ids = [oci_core_default_security_list.main.id]
  
  # IPv6 - use first /64 block from VCN's /56
  ipv6cidr_blocks = [cidrsubnet(oci_core_vcn.main.ipv6cidr_blocks[0], 8, 0)]
}

# ============================================================================
# COMPUTE INSTANCES
# ============================================================================

# AMD x86 Micro Instances
resource \"oci_core_instance\" \"amd\" {
  count = local.amd_micro_instance_count
  
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.compartment_id
  display_name        = local.amd_micro_hostnames[count.index]
  shape               = \"VM.Standard.E2.1.Micro\"
  
  create_vnic_details {
    subnet_id        = oci_core_subnet.main.id
    display_name     = \"${local.amd_micro_hostnames[count.index]}-vnic\"
    assign_public_ip = true
    assign_ipv6ip    = true
    hostname_label   = local.amd_micro_hostnames[count.index]
  }
  
  source_details {
    source_type             = \"image\"
    source_id               = local.ubuntu_x86_image_ocid
    boot_volume_size_in_gbs = local.amd_micro_boot_volume_size_gb
  }
  
  metadata = {
    ssh_authorized_keys = local.ssh_pubkey_data
    user_data = base64encode(templatefile(\"${path.module}/cloud-init.yaml\", {
      hostname = local.amd_micro_hostnames[count.index]
    }))
  }
  
  freeform_tags = {
    \"Purpose\"      = \"AlwaysFreeTier\"
    \"InstanceType\" = \"AMD-Micro\"
    \"Managed\"      = \"Terraform\"
  }
  
  lifecycle {
    ignore_changes = [
      source_details[0].source_id,  # Ignore image updates
      defined_tags,
    ]
  }
}

# ARM A1 Flex Instances
resource \"oci_core_instance\" \"arm\" {
  count = local.arm_flex_instance_count
  
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.compartment_id
  display_name        = local.arm_flex_hostnames[count.index]
  shape               = \"VM.Standard.A1.Flex\"
  
  shape_config {
    ocpus         = local.arm_flex_ocpus_per_instance[count.index]
    memory_in_gbs = local.arm_flex_memory_per_instance[count.index]
  }
  
  create_vnic_details {
    subnet_id        = oci_core_subnet.main.id
    display_name     = \"${local.arm_flex_hostnames[count.index]}-vnic\"
    assign_public_ip = true
    assign_ipv6ip    = true
    hostname_label   = local.arm_flex_hostnames[count.index]
  }
  
  source_details {
    source_type             = \"image\"
    source_id               = local.ubuntu_arm_image_ocid
    boot_volume_size_in_gbs = local.arm_flex_boot_volume_size_gb[count.index]
  }
  
  metadata = {
    ssh_authorized_keys = local.ssh_pubkey_data
    user_data = base64encode(templatefile(\"${path.module}/cloud-init.yaml\", {
      hostname = local.arm_flex_hostnames[count.index]
    }))
  }
  
  freeform_tags = {
    \"Purpose\"      = \"AlwaysFreeTier\"
    \"InstanceType\" = \"ARM-A1-Flex\"
    \"Managed\"      = \"Terraform\"
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

data \"oci_core_vnic_attachments\" \"amd_vnics\" {
  count = local.amd_micro_instance_count
  compartment_id = local.compartment_id
  instance_id    = oci_core_instance.amd[count.index].id
}

resource \"oci_core_ipv6\" \"amd_ipv6\" {
  count = local.amd_micro_instance_count
  vnic_id = data.oci_core_vnic_attachments.amd_vnics[count.index].vnic_attachments[0].vnic_id
  lifetime = \"RESERVED\"
  subnet_id = oci_core_subnet.main.id
  route_table_id = oci_core_default_route_table.main.id
  display_name = \"amd-${local.amd_micro_hostnames[count.index]}-ipv6\"
  freeform_tags = {
    \"Purpose\" = \"AlwaysFreeTier\"
    \"Managed\" = \"Terraform\"
  }
}

data \"oci_core_vnic_attachments\" \"arm_vnics\" {
  count = local.arm_flex_instance_count
  compartment_id = local.compartment_id
  instance_id    = oci_core_instance.arm[count.index].id
}

resource \"oci_core_ipv6\" \"arm_ipv6\" {
  count = local.arm_flex_instance_count
  vnic_id = data.oci_core_vnic_attachments.arm_vnics[count.index].vnic_attachments[0].vnic_id
  lifetime = \"RESERVED\"
  subnet_id = oci_core_subnet.main.id
  route_table_id = oci_core_default_route_table.main.id
  display_name = \"arm-${local.arm_flex_hostnames[count.index]}-ipv6\"
  freeform_tags = {
    \"Purpose\" = \"AlwaysFreeTier\"
    \"Managed\" = \"Terraform\"
  }
}

# ============================================================================
# OUTPUTS
# ============================================================================

output \"amd_instances\" {
  description = \"AMD instance information\"
  value = local.amd_micro_instance_count ^> 0 ? {
    for i in range(local.amd_micro_instance_count) : local.amd_micro_hostnames[i] =^> {
      id         = oci_core_instance.amd[i].id
      public_ip  = oci_core_instance.amd[i].public_ip
      private_ip = oci_core_instance.amd[i].private_ip
      ipv6       = oci_core_ipv6.amd_ipv6[i].ip_address
      state      = oci_core_instance.amd[i].state
      ssh        = \"ssh -i ./ssh_keys/id_rsa ubuntu@${oci_core_instance.amd[i].public_ip}\"
    }
  } : {}
}

output \"arm_instances\" {
  description = \"ARM instance information\"
  value = local.arm_flex_instance_count ^> 0 ? {
    for i in range(local.arm_flex_instance_count) : local.arm_flex_hostnames[i] =^> {
      id         = oci_core_instance.arm[i].id
      public_ip  = oci_core_instance.arm[i].public_ip
      private_ip = oci_core_instance.arm[i].private_ip
      ipv6       = oci_core_ipv6.arm_ipv6[i].ip_address
      state      = oci_core_instance.arm[i].state
      ocpus      = local.arm_flex_ocpus_per_instance[i]
      memory_gb  = local.arm_flex_memory_per_instance[i]
      ssh        = \"ssh -i ./ssh_keys/id_rsa ubuntu@${oci_core_instance.arm[i].public_ip}\"
    }
  } : {}
}

output \"network\" {
  description = \"Network information\"
  value = {
    vcn_id     = oci_core_vcn.main.id
    vcn_cidr   = oci_core_vcn.main.cidr_blocks[0]
    subnet_id  = oci_core_subnet.main.id
    subnet_cidr = oci_core_subnet.main.cidr_block
  }
}

output \"summary\" {
  description = \"Infrastructure summary\"
  value = {
    region          = local.region
    total_amd       = local.amd_micro_instance_count
    total_arm       = local.arm_flex_instance_count
    total_storage   = local.total_storage
    free_tier_limit = 200
  }
}
'@; Set-Content -Path 'main.tf' -Value $content"
call :print_success "main.tf created"
exit /b 0

:create_terraform_block_volumes
call :print_status "Creating block_volumes.tf..."
if exist "block_volumes.tf" (
    for /f "tokens=2-4 delims=/ " %%a in ('date /t') do set "backup_date=%%c%%a%%b"
    for /f "tokens=1-2 delims=: " %%a in ('time /t') do set "backup_time=%%a%%b"
    copy "block_volumes.tf" "block_volumes.tf.bak.%backup_date%_%backup_time%" >nul 2>&1
)
(
echo # Block Volume Resources (Optional)
echo # Block volumes provide additional storage beyond boot volumes
echo.
echo # AMD Block Volumes
echo resource "oci_core_volume" "amd_block" {
echo   count = local.amd_block_volume_size_gb ^> 0 ? local.amd_micro_instance_count : 0
echo.
echo   compartment_id      = local.compartment_id
echo   availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
echo   display_name        = "${local.amd_micro_hostnames[count.index]}-block"
echo   size_in_gbs         = local.amd_block_volume_size_gb
echo.
echo   freeform_tags = {
echo     "Purpose" = "AlwaysFreeTier"
echo     "Type"    = "BlockVolume"
echo     "Managed" = "Terraform"
echo   }
echo }
echo.
echo resource "oci_core_volume_attachment" "amd_block" {
echo   count = local.amd_block_volume_size_gb ^> 0 ? local.amd_micro_instance_count : 0
echo.
echo   attachment_type = "paravirtualized"
echo   instance_id     = oci_core_instance.amd[count.index].id
echo   volume_id       = oci_core_volume.amd_block[count.index].id
echo }
echo.
echo # ARM Block Volumes
echo resource "oci_core_volume" "arm_block" {
echo   count = local.arm_flex_instance_count ^> 0 ? length([for s in local.arm_block_volume_sizes : s if s ^> 0]) : 0
echo.
echo   compartment_id      = local.compartment_id
echo   availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
echo   display_name        = "${local.arm_flex_hostnames[count.index]}-block"
echo   size_in_gbs         = [for s in local.arm_block_volume_sizes : s if s ^> 0][count.index]
echo.
echo   freeform_tags = {
echo     "Purpose" = "AlwaysFreeTier"
echo     "Type"    = "BlockVolume"
echo     "Managed" = "Terraform"
echo   }
echo }
echo.
echo resource "oci_core_volume_attachment" "arm_block" {
echo   count = local.arm_flex_instance_count ^> 0 ? length([for s in local.arm_block_volume_sizes : s if s ^> 0]) : 0
echo.
echo   attachment_type = "paravirtualized"
echo   instance_id     = oci_core_instance.arm[count.index].id
echo   volume_id       = oci_core_volume.arm_block[count.index].id
echo }
) > block_volumes.tf
call :print_success "block_volumes.tf created"
exit /b 0

:create_cloud_init
call :print_status "Creating cloud-init.yaml..."
if exist "cloud-init.yaml" (
    for /f "tokens=2-4 delims=/ " %%a in ('date /t') do set "backup_date=%%c%%a%%b"
    for /f "tokens=1-2 delims=: " %%a in ('time /t') do set "backup_time=%%a%%b"
    copy "cloud-init.yaml" "cloud-init.yaml.bak.%backup_date%_%backup_time%" >nul 2>&1
)
(
echo #cloud-config
echo hostname: ${hostname}
echo fqdn: ${hostname}.local
echo manage_etc_hosts: true
echo.
echo package_update: true
echo package_upgrade: true
echo.
echo packages:
echo   - curl
echo   - wget
echo   - git
echo   - htop
echo   - vim
echo   - unzip
echo   - jq
echo   - tmux
echo   - net-tools
echo   - iotop
echo   - ncdu
echo.
echo runcmd:
echo   - echo "Instance ${hostname} initialized at $(date)" ^>^> /var/log/cloud-init-complete.log
echo   - systemctl enable --now fail2ban ^|^| true
echo.
echo # Basic security hardening
echo write_files:
echo   - path: /etc/ssh/sshd_config.d/hardening.conf
echo     content: ^|
echo       PermitRootLogin no
echo       PasswordAuthentication no
echo       MaxAuthTries 3
echo       ClientAliveInterval 300
echo       ClientAliveCountMax 2
echo.
echo timezone: UTC
echo ssh_pwauth: false
echo.
echo final_message: "Instance ${hostname} ready after $UPTIME seconds"
) > cloud-init.yaml
call :print_success "cloud-init.yaml created"
exit /b 0

REM ============================================================================
REM TERRAFORM IMPORT AND STATE MANAGEMENT
REM ============================================================================

:import_existing_resources
call :print_header "IMPORTING EXISTING RESOURCES"
if %EXISTING_VCNS_COUNT%==0 if %EXISTING_AMD_INSTANCES_COUNT%==0 if %EXISTING_ARM_INSTANCES_COUNT%==0 (
    call :print_status "No existing resources to import"
    exit /b 0
)
call :print_status "Initializing Terraform..."
call :retry_with_backoff "terraform init -input=false" >nul 2>&1
if errorlevel 1 (
    call :print_error "Terraform init failed after retries"
    exit /b 1
)
setlocal enabledelayedexpansion
set "imported=0"
set "failed=0"
if %EXISTING_VCNS_COUNT% gtr 0 (
    set "first_vcn_id=!EXISTING_VCNS_0_id!"
    if not "!first_vcn_id!"=="" (
        set "vcn_name=!EXISTING_VCNS_0_name!"
        call :print_status "Importing VCN: !vcn_name!"
        terraform state show oci_core_vcn.main >nul 2>&1
        if not errorlevel 1 (
            call :print_status "  Already in state"
        ) else (
            call :run_cmd_with_retries_and_check "terraform import oci_core_vcn.main \"!first_vcn_id!\"" >nul 2>&1
            if not errorlevel 1 (
                call :print_success "  Imported successfully"
                set /a "imported+=1"
                call :import_vcn_components "!first_vcn_id!"
            ) else (
                call :print_warning "  Failed to import (see logs above)"
                set /a "failed+=1"
            )
        )
    )
)
set "amd_index=0"
for /l %%i in (0,1,%EXISTING_AMD_INSTANCES_COUNT%) do (
    if defined EXISTING_AMD_INSTANCES_%%i_id (
        set "instance_id=!EXISTING_AMD_INSTANCES_%%i_id!"
        set "instance_name=!EXISTING_AMD_INSTANCES_%%i_name!"
        call :print_status "Importing AMD instance: !instance_name!"
        terraform state show "oci_core_instance.amd[!amd_index!]" >nul 2>&1
        if not errorlevel 1 (
            call :print_status "  Already in state"
        ) else (
            call :run_cmd_with_retries_and_check "terraform import \"oci_core_instance.amd[!amd_index!]\" \"!instance_id!\"" >nul 2>&1
            if not errorlevel 1 (
                call :print_success "  Imported successfully"
                set /a "imported+=1"
            ) else (
                call :print_warning "  Failed to import (see logs above)"
                set /a "failed+=1"
            )
        )
        set /a "amd_index+=1"
        if !amd_index! geq %amd_micro_instance_count% goto amd_import_done
    )
)
:amd_import_done
set "arm_index=0"
for /l %%i in (0,1,%EXISTING_ARM_INSTANCES_COUNT%) do (
    if defined EXISTING_ARM_INSTANCES_%%i_id (
        set "instance_id=!EXISTING_ARM_INSTANCES_%%i_id!"
        set "instance_name=!EXISTING_ARM_INSTANCES_%%i_name!"
        call :print_status "Importing ARM instance: !instance_name!"
        terraform state show "oci_core_instance.arm[!arm_index!]" >nul 2>&1
        if not errorlevel 1 (
            call :print_status "  Already in state"
        ) else (
            call :run_cmd_with_retries_and_check "terraform import \"oci_core_instance.arm[!arm_index!]\" \"!instance_id!\"" >nul 2>&1
            if not errorlevel 1 (
                call :print_success "  Imported successfully"
                set /a "imported+=1"
            ) else (
                call :print_warning "  Failed to import (see logs above)"
                set /a "failed+=1"
            )
        )
        set /a "arm_index+=1"
        if !arm_index! geq %arm_flex_instance_count% goto arm_import_done
    )
)
:arm_import_done
echo.
call :print_success "Import complete: !imported! imported, !failed! failed"
endlocal
exit /b 0

:import_vcn_components
setlocal enabledelayedexpansion
set "vcn_id=%~1"
REM Import Internet Gateway, Subnet, Route Table, Security List if needed
endlocal
exit /b 0

REM ============================================================================
REM TERRAFORM WORKFLOW
REM ============================================================================

:run_terraform_workflow
call :print_header "TERRAFORM WORKFLOW"
call :print_status "Step 1: Initializing Terraform..."
call :retry_with_backoff "terraform init -input=false -upgrade" >nul 2>&1
if errorlevel 1 (
    call :print_error "Terraform init failed after retries"
    exit /b 1
)
call :print_success "Terraform initialized"
if %EXISTING_VCNS_COUNT% gtr 0 (
    call :print_status "Step 2: Importing existing resources..."
    call :import_existing_resources
) else if %EXISTING_AMD_INSTANCES_COUNT% gtr 0 (
    call :print_status "Step 2: Importing existing resources..."
    call :import_existing_resources
) else if %EXISTING_ARM_INSTANCES_COUNT% gtr 0 (
    call :print_status "Step 2: Importing existing resources..."
    call :import_existing_resources
) else (
    call :print_status "Step 2: No existing resources to import"
)
call :print_status "Step 3: Validating configuration..."
terraform validate
if errorlevel 1 (
    call :print_error "Terraform validation failed"
    exit /b 1
)
call :print_success "Configuration valid"
call :print_status "Step 4: Creating execution plan..."
terraform plan -out=tfplan -input=false
if errorlevel 1 (
    call :print_error "Terraform plan failed"
    exit /b 1
)
call :print_success "Plan created successfully"
echo.
call :print_status "Plan summary:"
terraform show -no-color tfplan | findstr /r "^Plan: ^# will be" | more
echo.
if "%AUTO_DEPLOY%"=="true" (
    set "apply_choice=Y"
) else if "%NON_INTERACTIVE%"=="true" (
    set "apply_choice=Y"
) else (
    set /p "apply_choice=Apply this plan? [y/N]: "
    if "%apply_choice%"=="" set "apply_choice=N"
)
if /i "%apply_choice%"=="Y" (
    call :print_status "Applying Terraform plan..."
    call :out_of_capacity_auto_apply
    if not errorlevel 1 (
        call :print_success "Infrastructure deployed successfully!"
        del tfplan 2>nul
        echo.
        call :print_header "DEPLOYMENT COMPLETE"
        terraform output -json 2>nul >temp_tf_output.json
        if exist temp_tf_output.json (
            powershell -NoProfile -Command "try { $json = Get-Content 'temp_tf_output.json' -Raw | ConvertFrom-Json; $json | ConvertTo-Json -Depth 10 | Write-Output } catch { }"
            del temp_tf_output.json 2>nul
        ) else (
            terraform output
        )
    ) else (
        call :print_error "Terraform apply failed"
        exit /b 1
    )
) else (
    call :print_status "Plan saved as 'tfplan' - apply later with: terraform apply tfplan"
)
exit /b 0

:terraform_menu
:terraform_menu_loop
echo.
call :print_header "TERRAFORM MANAGEMENT"
echo   1) Full workflow (init → import → plan → apply)
echo   2) Plan only
echo   3) Apply existing plan
echo   4) Import existing resources
echo   5) Show current state
echo   6) Destroy infrastructure
echo   7) Reconfigure
echo   8) Exit
echo.
if "%AUTO_DEPLOY%"=="true" (
    set "choice=1"
    call :print_status "Auto mode: Running full workflow"
) else if "%NON_INTERACTIVE%"=="true" (
    set "choice=1"
    call :print_status "Auto mode: Running full workflow"
) else (
    set /p "choice=Choose option [1]: "
    if "%choice%"=="" set "choice=1"
)
if "%choice%"=="1" (
    call :run_terraform_workflow
    if "%AUTO_DEPLOY%"=="true" exit /b 0
) else if "%choice%"=="2" (
    terraform init -input=false && terraform plan
) else if "%choice%"=="3" (
    if exist "tfplan" (
        terraform apply tfplan
    ) else (
        call :print_error "No plan file found"
    )
) else if "%choice%"=="4" (
    call :import_existing_resources
) else if "%choice%"=="5" (
    terraform state list 2>nul && terraform output 2>nul || call :print_status "No state found"
) else if "%choice%"=="6" (
    call :confirm_action "DESTROY all infrastructure?" "N"
    if not errorlevel 1 (
        terraform destroy
    )
) else if "%choice%"=="7" (
    exit /b 1
) else if "%choice%"=="8" (
    exit /b 0
) else (
    call :print_error "Invalid choice"
)
if "%NON_INTERACTIVE%"=="true" exit /b 0
echo.
set /p "dummy=Press Enter to continue..."
goto terraform_menu_loop

REM ============================================================================
REM MAIN EXECUTION
REM ============================================================================

:main
call :print_header "OCI TERRAFORM SETUP - IDEMPOTENT EDITION"
call :print_status "This script safely manages Oracle Cloud Free Tier resources"
call :print_status "Safe to run multiple times - will detect and reuse existing resources"
echo.
call :install_prerequisites
call :install_terraform
call :install_oci_cli
if exist ".venv\Scripts\activate.bat" call .venv\Scripts\activate.bat
call :setup_oci_config
call :fetch_oci_config_values
call :fetch_availability_domains
call :fetch_ubuntu_images
call :generate_ssh_keys
call :inventory_all_resources
if not "%SKIP_CONFIG%"=="true" (
    call :prompt_configuration
) else (
    call :load_existing_config || call :configure_from_existing_instances
)
call :create_terraform_files
:terraform_menu_loop_main
call :terraform_menu
if errorlevel 1 (
    call :prompt_configuration
    call :create_terraform_files
    goto terraform_menu_loop_main
)
call :print_header "SETUP COMPLETE"
call :print_success "Oracle Cloud Free Tier infrastructure managed successfully"
echo.
call :print_status "Files created/updated:"
call :print_status "  • provider.tf - OCI provider configuration"
call :print_status "  • variables.tf - Instance configuration"
call :print_status "  • main.tf - Infrastructure resources"
call :print_status "  • data_sources.tf - OCI data sources"
call :print_status "  • block_volumes.tf - Storage volumes"
call :print_status "  • cloud-init.yaml - Instance initialization"
echo.
call :print_status "To manage your infrastructure:"
call :print_status "  terraform plan    - Preview changes"
call :print_status "  terraform apply   - Apply changes"
call :print_status "  terraform destroy - Remove all resources"
exit /b 0

REM Execute main
call :main
endlocal
