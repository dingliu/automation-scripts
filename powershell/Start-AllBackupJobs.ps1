#Requires -Version 7.0
#Requires -Modules PSToml


#region Parameters
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Run in dry-run mode without making actual changes")]
    [switch]$DryRun
)
#endregion Parameters


#region Initialization
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
#endregion Initialization


#region Variables
# Configuration TOML filepath
$CONFIG_PATH_ENV_VAR_NAME = 'BACKUP_CONFIG_FILEPATH'
#endregion Variables


#region Functions
function Test-EnvironmentVariable {
    <#
    .SYNOPSIS
        Tests if an environment variable exists and has a non-empty value.

    .DESCRIPTION
        This function checks if an environment variable exists and has a non-empty value
        in the specified scope (Process, User, or Machine). It returns $true if the variable
        exists and has a value, and $false otherwise.

    .PARAMETER Name
        The name of the environment variable to check.
        Must contain only letters, numbers, and underscores.

    .PARAMETER Scope
        The scope in which to check for the environment variable.
        Valid values are: 'Process' (default), 'User', and 'Machine'.

    .EXAMPLE
        Test-EnvironmentVariable -Name 'BACKUP_CONFIG_FILEPATH'

        Checks if the BACKUP_CONFIG_FILEPATH environment variable exists in the Process scope.

    .EXAMPLE
        Test-EnvironmentVariable -Name 'PATH' -Scope 'User'

        Checks if the PATH environment variable exists in the User scope.

    .EXAMPLE
        Test-EnvironmentVariable -Name 'JAVA_HOME' -Scope 'Machine'

        Checks if the JAVA_HOME environment variable exists in the Machine scope.

    .OUTPUTS
        System.Boolean
        Returns $true if the environment variable exists and has a value, $false otherwise.

    .NOTES
        Function returns $false both when the variable doesn't exist and when it exists but is empty.
    #>
    [CmdletBinding()]
    param (
        [Parameter(
            Mandatory = $true,
            Position = 0
        )]
        [ValidatePattern('^[a-zA-Z0-9_]+$', ErrorMessage = "Environment variable names must contain only letters, numbers, and underscores.")]
        [ValidateNotNullOrEmpty()]
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
        return ![string]::IsNullOrEmpty($variable)
    }
    catch {
        Write-Error "Error checking environment variable '$Name': $_"
    }
}

function Write-Log {
    <#
    .SYNOPSIS
        Writes a log message to the appropriate output stream with timestamp.

    .DESCRIPTION
        This function writes a log message to the specified output stream (Debug, Verbose,
        Warning, Error, Information) with a consistent timestamp format. When the OutputJSON
        switch is enabled, it outputs the message as a JSON string with timestamp and event attributes.

    .PARAMETER Message
        The message to be logged.

    .PARAMETER Level
        The log level or output stream to write to.
        Valid values: Debug, Verbose, Warning, Error, Information

    .PARAMETER OutputJSON
        When enabled, converts the output to a JSON string with timestamp and event properties.

    .EXAMPLE
        Write-Log -Message "Processing started" -Level Information

        Writes an information message with a timestamp to the Information stream.

    .EXAMPLE
        Write-Log -Message "Something went wrong" -Level Error -OutputJSON

        Outputs a JSON string to the Error stream with timestamp and event properties.

    .OUTPUTS
        None or System.String (when OutputJSON is enabled)
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateSet('Debug', 'Verbose', 'Warning', 'Error', 'Information')]
        [string]$Level,

        [Parameter(Mandatory = $false)]
        [switch]$OutputJSON = $false
    )

    # Get current timestamp
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Prepare the log message with timestamp
    $formattedMessage = "[$timestamp] $Message"

    # If OutputJSON is specified, convert to JSON format
    if ($OutputJSON) {
        $jsonObject = @{
            timestamp = $timestamp
            event = $Message
        }
        $output = ConvertTo-Json -InputObject $jsonObject -Compress
    } else {
        $output = $formattedMessage
    }

    # Write to the appropriate stream
    switch ($Level) {
        'Debug' {
            Write-Debug $output
        }
        'Verbose' {
            Write-Verbose $output
        }
        'Warning' {
            Write-Warning $output
        }
        'Error' {
            Write-Error $output
        }
        'Information' {
            Write-Information $output -InformationAction Continue
        }
    }
}

function Import-TomlConfig {
    <#
    .SYNOPSIS
        Imports and parses a TOML configuration file.

    .DESCRIPTION
        This function reads a TOML configuration file from the specified path,
        parses its content using ConvertFrom-Toml, and returns the resulting
        configuration object. If any errors occur during the process, it logs
        the error and exits the script.

    .PARAMETER ConfigPath
        The full path to the TOML configuration file to import.
        Must be a valid file path to an existing TOML file.

    .EXAMPLE
        $config = Import-TomlConfig -ConfigPath "C:\config\backup.toml"

        Imports the TOML configuration from the specified path and stores it in $config.

    .OUTPUTS
        System.Object
        Returns the parsed configuration object from the TOML file.

    .NOTES
        Requires the PSToml module to be installed.
        The function will exit with code 1 if any errors occur during import or parsing.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    try {
        $tomlContent = Get-Content -Path $ConfigPath -Encoding 'UTF8' -Raw
        $config = ConvertFrom-Toml -InputObject $tomlContent

        if (-not $config) {
            Write-Log -Message "Failed to parse TOML configuration" -Level Error
            exit 1
        }

        Write-Log -Message "Configuration loaded successfully from $ConfigPath" -Level Information
        return $config
    }
    catch {
        Write-Log -Message "Failed to load configuration from $ConfigPath. Error: $_" -Level Error
        exit 1
    }
}

function Start-RobocopyBackup {
    <#
    .SYNOPSIS
        Performs a backup operation using Robocopy with specified source and destination paths.

    .DESCRIPTION
        This function executes a Robocopy command to backup files from a source to a destination
        directory. It handles path formatting, option processing, and provides detailed logging
        of the operation. The function interprets Robocopy exit codes to provide meaningful
        status information about the backup operation.

    .PARAMETER Source
        The source directory path from which files will be copied.
        The path will automatically have a trailing backslash added if missing.

    .PARAMETER Destination
        The destination directory path where files will be copied to.
        The path will automatically have a trailing backslash added if missing.

    .PARAMETER Options
        An array of Robocopy options/switches to be used with the command.
        Forward slashes will be automatically added if missing from the options.

    .PARAMETER DryRun
        When specified, runs Robocopy in list-only mode (/L) without actually copying files.
        Useful for testing what would happen during the actual backup.

    .EXAMPLE
        Start-RobocopyBackup -Source "C:\Data" -Destination "D:\Backup" -Options @("MIR", "XA:H")

        Performs a mirror backup from C:\Data to D:\Backup, excluding hidden files.

    .EXAMPLE
        Start-RobocopyBackup -Source "C:\Projects" -Destination "D:\Backup\Projects" -DryRun -Options @("MIR")

        Simulates a mirror backup operation without actually copying files.

    .OUTPUTS
        System.Boolean
        Returns $true if the backup completed successfully (exit codes 0-3),
        Returns $false if serious errors occurred (exit codes 8 or higher).

    .NOTES
        Robocopy Exit Codes:
        0 - No files were copied. No failure was encountered.
        1 - One or more files were copied successfully.
        2 - Extra files or directories were detected.
        3 - Some files were copied. Additional files were present.
        4-7 - Some files or directories could not be copied.
        >= 8 - Serious error. Backup failed.
    #>
    param(
        [string]$Source,
        [string]$Destination,
        [string[]]$Options,
        [switch]$DryRun = $false
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

    Write-Log -Message "Starting Robocopy backup from '$Source' to '$Destination'" -Level Information
    Write-Log -Message "Options: $($roboOptions -join ' ')" -Level Information

    if ($DryRun) {
        $robocopyArgs += " /L" # List only mode
        Write-Log -Message "Dry run mode enabled. No files will be copied." -Level Warning
    }

    try {
        # Execute Robocopy
        $process = Start-Process -FilePath "robocopy" -ArgumentList $robocopyArgs -NoNewWindow -Wait -PassThru

        # Interpret Robocopy exit codes
        switch ($process.ExitCode) {
            0 {
                Write-Log -Message "Backup completed successfully. No files were copied." -Level Information
            }
            1 {
                Write-Log -Message "Backup completed successfully. Files were copied without error." -Level Information
            }
            2 {
                Write-Log -Message "Backup completed with extra files or directories detected." -Level Warning
            }
            3 {
                Write-Log -Message "Backup completed with some mismatched files or directories. Some copying was done." -Level Warning
            }
            {$_ -ge 4 -and $_ -le 7} {
                Write-Log -Message "Backup completed with some failures. Error code: $_" -Level Warning
            }
            {$_ -ge 8} {
                Write-Log -Message "Backup failed with serious errors. Error code: $_" -Level Error
                return $false
            }
        }
        return $true
    }
    catch {
        Write-Log -Message "Failed to execute Robocopy: $_" -Level Error
        return $false
    }
}

function Start-BackupByDestination {
    <#
    .SYNOPSIS
        Processes backup operations for a collection of destinations using specified handlers.

    .DESCRIPTION
        This function performs backup operations for each destination in the provided collection.
        It supports different backup handlers (currently Robocopy) and provides detailed logging
        of the backup process. The function can operate in both normal and dry-run modes.

    .PARAMETER Destinations
        An array of destination objects that specify where backups should be stored.
        Each destination object must contain:
        - handler: The backup handler to use (e.g., "Robocopy")
        - path: The base path for the backup
        - description: A human-readable description of the destination
        Supports pipeline input and allows empty collections.

    .PARAMETER Target
        An object describing the backup target with the following properties:
        - source: The source path to backup
        - destination: The relative path within the destination
        - description: A human-readable description of the target

    .PARAMETER Handlers
        An object containing handler-specific configurations.
        For Robocopy handler, must include:
        - Robocopy.Options: Array of Robocopy command-line options

    .PARAMETER DryRun
        When specified, simulates the backup operation without making actual changes.

    .EXAMPLE
        $destinations | Start-BackupByDestination -Target $target -Handlers $handlers -DryRun:$false

        Processes backup operations for all destinations using the specified target and handlers.

    .EXAMPLE
        Start-BackupByDestination -Destinations $localDrives -Target $target -Handlers $handlers -DryRun

        Performs a dry run of backup operations to local drives without making actual changes.

    .OUTPUTS
        None. This function logs its progress using Write-Log.

    .NOTES
        Currently only supports the Robocopy handler.
        All operations are logged using the Write-Log function with appropriate severity levels.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [AllowEmptyCollection()]
        [object[]]$Destinations,

        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [object]$Handlers,

        [switch]$DryRun = $false
    )

    process {
        foreach ($destination in $Destinations) {
            switch ($destination.handler) {
                "Robocopy" {
                    $handlerOptions = $Handlers.Robocopy.Options
                    $destPath = Join-Path $destination.path $Target.destination
                    Write-Log -Message "Backing up target: $($Target.description) to '$destPath'" -Level Information

                    $success = Start-RobocopyBackup -Source $Target.source -Destination $destPath -Options $handlerOptions -DryRun:$DryRun

                    if ($success) {
                        Write-Log -Message "Backup successful: $($Target.description) from $($Target.source) to $($destPath)" -Level Information
                    } elseif ($DryRun) {
                        Write-Log -Message "Dry run completed for: $($Target.description) from $($Target.source) to $($destPath)" -Level Warning
                    } else {
                        Write-Log -Message "Backup failed: $($Target.description) from $($Target.source) to $($destPath)" -Level Error
                    }
                }
                Default {
                    Write-Log -Message "Unknown handler $($destination.handler) for destination $($destination.description). Skipping..." -Level Error
                }
            }
        }
    }
}

function Start-StaticBackupJob {
    <#
    .SYNOPSIS
        Processes all static backup tasks defined in the configuration.

    .DESCRIPTION
        This function iterates through all targets defined in the static backup configuration
        and processes both local drive and SMB share destinations for each target. It uses the
        Start-BackupByDestination function to perform the actual backup operations and provides
        appropriate logging for the beginning and completion of each backup cycle.

    .PARAMETER StaticBackupConfig
        An object containing the static backup configuration with the following structure:
        - targets: Array of backup target objects each with source, destination, and description
        - destinations: Object containing local_drives and smb_shares arrays
        - handlers: Object containing handler-specific configurations like Robocopy options

    .PARAMETER DryRun
        When specified, simulates the backup operations without making actual changes.
        This is passed through to the underlying backup functions.

    .EXAMPLE
        Start-StaticBackupJob -StaticBackupConfig $config.static -DryRun:$false

        Processes all static backup jobs defined in the configuration with actual file operations.

    .EXAMPLE
        Start-StaticBackupJob -StaticBackupConfig $config.static -DryRun

        Simulates all static backup jobs without performing actual file operations.

    .OUTPUTS
        None. This function logs its progress using Write-Log.

    .NOTES
        This function is typically called from the main script flow after loading the configuration.
        It relies on the Start-BackupByDestination function to handle the specific backup operations.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object]$StaticBackupConfig,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun = $false
    )

    # Process the static.targets array
    foreach ($target in $StaticBackupConfig.targets) {
        Write-Log -Message "Start processing target: $($target.description)" -Level Information

        # Process all local drive destinations
        $StaticBackupConfig.destinations.local_drives |
            Start-BackupByDestination -Target $target -Handlers $StaticBackupConfig.Handlers -DryRun:$DryRun

        # Process all SMB share destinations
        $StaticBackupConfig.destinations.smb_shares |
            Start-BackupByDestination -Target $target -Handlers $StaticBackupConfig.Handlers -DryRun:$DryRun

        Write-Log -Message "Backup cycle completed for target: $($target.description)" -Level Information
    }
}

#endregion Functions


#region Main
# Check if the configuration file path environment variable is set
if (-not (Test-EnvironmentVariable -Name $CONFIG_PATH_ENV_VAR_NAME)) {
    Write-Log -Message "Environment variable '$CONFIG_PATH_ENV_VAR_NAME' is not set. Please set it to the path of your backup configuration file." -Level Error
    exit 1
}

$config = Import-TomlConfig -ConfigPath [Environment]::GetEnvironmentVariable($CONFIG_PATH_ENV_VAR_NAME)

Start-StaticBackupJob -StaticBackupConfig $config.static -DryRun:$DryRun

Write-Log -Message "All backup jobs completed." -Level Information
#endregion Main
