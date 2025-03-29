#Requires -Version 7.0
#Requires -Modules PSToml

#region Functions
function Test-EnvironmentVariable {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Process', 'User', 'Machine')]
        [string]$Scope = 'Process'
    )

    try {
        # Get the environment variable based on scope
        $variable = switch ($Scope) {
            'Process' { [Environment]::GetEnvironmentVariable($Name) }
            'User'    { [Environment]::GetEnvironmentVariable($Name, 'User') }
            'Machine' { [Environment]::GetEnvironmentVariable($Name, 'Machine') }
        }

        # Return true if the variable exists and is not empty
        return ![string]::IsNullOrEmpty($variable)
    }
    catch {
        Write-Error "Error checking environment variable '$Name': $_"
        return $false
    }
}

# Log function
function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [string]$Color = "White"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $Message" -ForegroundColor $Color
}

# Function to execute Robocopy backup
function Start-RobocopyBackup {
    param(
        [string]$Source,
        [string]$Destination,
        [string[]]$Options
    )

    # Ensure source and destination paths end with a backslash
    if (-not $Source.EndsWith('\')) { $Source = "$Source\" }
    if (-not $Destination.EndsWith('\')) { $Destination = "$Destination\" }

    # Simplified option handling - ensure proper slash prefix
    $roboOptions = $Options | ForEach-Object {
        $opt = $_.Trim()
        # Add slash if it doesn't start with one
        if (-not $opt.StartsWith('/')) {
            "/$opt"
        } else {
            $opt
        }
    }

    # Prepare the command
    $robocopyArgs = @($Source, $Destination) + $roboOptions

    Write-Log "Starting Robocopy backup from '$Source' to '$Destination'" -Color Cyan
    Write-Log "Options: $($roboOptions -join ' ')" -Color Gray

    try {
        # Execute Robocopy
        $process = Start-Process -FilePath "robocopy" -ArgumentList $robocopyArgs -NoNewWindow -Wait -PassThru

        # Interpret Robocopy exit codes
        switch ($process.ExitCode) {
            0 {
                Write-Log "Backup completed successfully. No files were copied." -Color Green
            }
            1 {
                Write-Log "Backup completed successfully. Files were copied without error." -Color Green
            }
            2 {
                Write-Log "Backup completed with extra files or directories detected." -Color Yellow
            }
            3 {
                Write-Log "Backup completed with some mismatched files or directories. Some copying was done." -Color Yellow
            }
            {$_ -ge 4 -and $_ -le 7} {
                Write-Log "Backup completed with some failures. Error code: $_" -Color Yellow
            }
            {$_ -ge 8} {
                Write-Log "Backup failed with serious errors. Error code: $_" -Color Red
                return $false
            }
        }
        return $true
    }
    catch {
        Write-Log "Failed to execute Robocopy: $_" -Color Red
        return $false
    }
}
#endregion

# Configuration path
$configPath = "$env:USERPROFILE\Dev\github\dingliu\private-config-backup\backup.toml"

# Read and parse backup.toml configuration
try {
    $tomlContent = Get-Content -Path $configPath -Encoding [System.Text.Encoding]::UTF8 -Raw
    $config = ConvertFrom-Toml -InputObject $tomlContent
    if (-not $config) {
        throw "Failed to parse TOML configuration."
    }
    Write-Host "Configuration loaded successfully from $configPath" -ForegroundColor Green
}
catch {
    Write-Host "Failed to load configuration from $configPath" -ForegroundColor Red
    Write-Host "Error: $_" -ForegroundColor Red
    exit 1
}

# Main backup process
Write-Log "Starting backup process..." -Color Magenta

# Process the static.targets array
foreach ($target in $config.static.targets) {
    Write-Log "Processing target: $($target.description)" -Color Yellow
    $sourcePath = $target.source

    # Local backup
    $localDest = Join-Path $config.static.destinations.local.path $target.destination
    $robocopyOptions = $config.static.handlers.Robocopy.options

    # Backup to local destination
    $localSuccess = Start-RobocopyBackup -Source $sourcePath -Destination $localDest -Options $robocopyOptions

    # If local backup succeeded, proceed to SMB backup
    if ($localSuccess) {
        Write-Log "Local backup successful. Proceeding to SMB backup..." -Color Green

        # SMB backup
        $smbDest = Join-Path $config.static.destinations.smb.path $target.destination
        $smbSuccess = Start-RobocopyBackup -Source $sourcePath -Destination $smbDest -Options $robocopyOptions

        if ($smbSuccess) {
            Write-Log "SMB backup successful for target: $($target.description)" -Color Green
        }
        else {
            Write-Log "SMB backup failed for target: $($target.description)" -Color Red
        }
    }
    else {
        Write-Log "Local backup failed. Skipping SMB backup for target: $($target.description)" -Color Red
    }

    Write-Log "Backup cycle completed for target: $($target.description)" -Color Magenta
    Write-Log "-------------------------------------------------" -Color Gray
}

Write-Log "All backup jobs completed." -Color Magenta
