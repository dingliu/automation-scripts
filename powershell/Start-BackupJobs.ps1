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
    # ========================================================================
    # Double quotes are used to handle spaces in paths.
    # However, because both source and destination have a trailing backslash,
    # an extra backslash is added to escape the quotes. This is necessary to
    # ensure the paths are correctly interpreted by Robocopy.
    # ========================================================================
    $robocopyArgs = @("`"$Source\`"", "`"$Destination\`"") + $roboOptions

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

# Function to process backups by destination type
function Start-BackupByDestination {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [AllowEmptyCollection()]
        [object[]]$Destinations,

        [Parameter(Mandatory = $true)]
        [string]$Target,

        [Parameter(Mandatory = $true)]
        [string[]]$Options
    )

    process {
        foreach ($destination in $Destinations) {
            switch ($destination.handler) {
                "Robocopy" {
                    $destPath = Join-Path $destination.path $Target.destination
                    Write-Log "Backing up target: $($Target.description) to '$destPath'" -Color Cyan

                    $success = Start-RobocopyBackup -Source $Target.source -Destination $destPath -Options $Options
                    if ($success) {
                        Write-Log "Backup successful: $($Target.description) from $($Target.source) to $($destPath)" -Color Green
                    } else {
                        Write-Log "Backup failed: $($Target.description) from $($Target.source) to $($destPath)" -Color Red
                    }
                }
                Default {
                    Write-Log "Unknown handler $($destination.handler) for destination $($destination.description). Skipping..." -Color Red
                }
            }
        }
    }
}
#endregion Functions


#region Constants
# Configuration TOML filepath
$CONFIG_PATH_ENV_VAR_NAME = 'BACKUP_CONFIG_FILEPATH'
#endregion Constants


#region Main
# Check if the environment variable for config path is set
if (Test-EnvironmentVariable -Name $CONFIG_PATH_ENV_VAR_NAME) {
    $configPath = [Environment]::GetEnvironmentVariable($CONFIG_PATH_ENV_VAR_NAME)
} else {
    Write-Log "Environment variable '$CONFIG_PATH_ENV_VAR_NAME' is not set." -Color Red
    Write-Log "Please set the environment variable to point to the backup.toml file." -Color Red
    exit 1
}

# Read and parse backup.toml configuration
try {
    $tomlContent = Get-Content -Path $configPath -Encoding 'UTF8' -Raw
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
    $robocopyOptions = $config.static.handlers.Robocopy.options

    # Process all local drive destinations
    $config.static.destinations.local_drives | ForEach-Object {
        Start-BackupByDestination -Target $target -Destinations $_ -Options $robocopyOptions}


    # Process all SMB share destinations
    $config.static.destinations.smb_shares | ForEach-Object {
        Start-BackupByDestination -Target $target -Destinations $_ -Options $robocopyOptions}

    Write-Log "Backup cycle completed for target: $($target.description)" -Color Magenta
    Write-Log "-------------------------------------------------" -Color Gray
}

Write-Log "All backup jobs completed." -Color Magenta
#endregion Main
