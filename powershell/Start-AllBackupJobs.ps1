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
function New-DirectoryIfNotExists {
    <#
    .SYNOPSIS
        Creates a directory if it doesn't exist and validates its permissions.

    .DESCRIPTION
        This function checks if a directory exists at the specified path. If not, it creates the
        directory. If the directory already exists, it validates that it's actually a directory
        (not a file) and checks for read and write permissions by performing test operations.
        When DryRun is specified, the function will only log what would happen without making changes.

    .PARAMETER Path
        The full path of the directory to create or validate.
        Must be a valid path that doesn't contain invalid characters.

    .PARAMETER DryRun
        When specified, only logs what would happen without actually creating directories or testing permissions.
        Useful for previewing operations that would take place during actual execution.

    .EXAMPLE
        New-DirectoryIfNotExists -Path "C:\Backup\Data"

        Creates the directory "C:\Backup\Data" if it doesn't exist, or validates it if it does.

    .EXAMPLE
        New-DirectoryIfNotExists -Path "\\server\share\backup" -DryRun

        Simulates creating or validating a directory on a network share without making actual changes.

    .OUTPUTS
        None. This function doesn't return any output.

    .NOTES
        The function will exit the script with code 1 if:
        - The path exists but is not a directory
        - The directory is not readable
        - The directory is not writable
        - Directory creation fails

        When DryRun is specified, no filesystem operations will be performed.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({
            # Check for invalid path characters
            try {
                $null = [System.IO.Path]::GetFullPath($_)
            }
            catch {
                throw "Path contains invalid characters: $_"
            }
            return $true
        })]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun = $false
    )

    if (-not (Test-Path -Path $Path)) {
        if ($DryRun) {
            Write-Log -Message "DRY RUN: Would create directory: $Path" -Level Warning
            return
        }

        try {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            Write-Log -Message "Created directory: $Path" -Level Information
        }
        catch {
            Write-Log -Message "Failed to create directory at '$Path': $_" -Level Error
            exit 1
        }
    }
    else {
        # Check if it's actually a directory
        $item = Get-Item -Path $Path
        if (-not $item.PSIsContainer) {
            Write-Log -Message "Path '$Path' exists but is not a directory." -Level Error
            exit 1
        }

        if ($DryRun) {
            Write-Log -Message "DRY RUN: Would validate directory permissions for: $Path" -Level Warning
            return
        }

        # Check read permission
        try {
            $null = Get-ChildItem -Path $Path -ErrorAction Stop
        }
        catch {
            Write-Log -Message "Directory '$Path' is not readable: $_" -Level Error
            exit 1
        }

        # Check write permission
        try {
            $testFile = Join-Path -Path $Path -ChildPath "write-test-$([Guid]::NewGuid()).tmp"
            $null = New-Item -ItemType File -Path $testFile -Force -ErrorAction Stop
            Remove-Item -Path $testFile -Force -ErrorAction Stop
        }
        catch {
            Write-Log -Message "Directory '$Path' is not writable: $_" -Level Error
            exit 1
        }
    }
}

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
        It supports different backup handlers (currently "Robocopy" and "mirror_clone") and provides
        detailed logging of the backup process. The function can operate in both normal and dry-run modes.

    .PARAMETER Destinations
        An array of destination objects that specify where backups should be stored.
        Each destination object must contain:
        - handler: The backup handler to use (e.g., "Robocopy" or "mirror_clone")
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
        - Robocopy.options: Array of Robocopy command-line options

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
        Currently supports the following handlers:
        - Robocopy: For file system backups using robocopy
        - mirror_clone: For Git repository mirror cloning

        All operations are logged using the Write-Log function with appropriate severity levels.
        Each destination is processed independently, allowing for multiple backup destinations.
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
                "mirror_clone" {
                    # Handle mirror clone operation
                    $handlerOptions = $Handlers[$destination.handler].options
                    $destPath = Join-Path $destination.path $Target.destination
                    Write-Log -Message "Backing up target: $($Target.description) to '$destPath'" -Level Information

                    $success = Start-MirrorCloneBackup -Source $Target.source -Destination $destPath -Options $handlerOptions -DryRun:$DryRun

                    if ($success) {
                        Write-Log -Message "Backup successful: $($Target.description) from $($Target.source) to $($destPath)" -Level Information
                    } elseif ($DryRun) {
                        Write-Log -Message "Dry run completed for: $($Target.description) from $($Target.source) to $($destPath)" -Level Warning
                    } else {
                        Write-Log -Message "Backup failed: $($Target.description) from $($Target.source) to $($destPath)" -Level Error
                    }
                }
                "git_bundle" {
                    # Handle git bundle operation
                    $handlerOptions = $Handlers[$destination.handler].options
                    $destPath = Join-Path $destination.path $Target.destination
                    Write-Log -Message "Backing up target: $($Target.description) to '$destPath'" -Level Information

                    # The source of Git bundle backup is a bit different
                    $bundleSource = Join-Path $destination.source $Target.destination
                    $success = Start-GitBundleBackup -Source $bundleSource -Destination $destPath -Options $handlerOptions -DryRun:$DryRun

                    if ($success) {
                        Write-Log -Message "Backup successful: $($Target.description) from $($Target.source) to $($destPath)" -Level Information
                    } elseif ($DryRun) {
                        Write-Log -Message "Dry run completed for: $($Target.description) from $($Target.source) to $($destPath)" -Level Warning
                    } else {
                        Write-Log -Message "Backup failed: $($Target.description) from $($Target.source) to $($destPath)" -Level Error
                    }
                }
                "robocopy" {
                    $handlerOptions = $Handlers[$destination.handler].options
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
            Start-BackupByDestination -Target $target -Handlers $StaticBackupConfig.handlers -DryRun:$DryRun

        # Process all SMB share destinations
        $StaticBackupConfig.destinations.smb_shares |
            Start-BackupByDestination -Target $target -Handlers $StaticBackupConfig.handlers -DryRun:$DryRun

        Write-Log -Message "Backup cycle completed for target: $($target.description)" -Level Information
    }
}

function Test-GitHubCliInstalled {
    <#
    .SYNOPSIS
        Tests if GitHub CLI (gh) is installed and available in the system path.

    .DESCRIPTION
        This function checks if the GitHub CLI tool is installed and accessible
        by attempting to run a simple command and checking the result.

    .EXAMPLE
        Test-GitHubCliInstalled

        Returns $true if GitHub CLI is installed and accessible, $false otherwise.

    .OUTPUTS
        System.Boolean
        Returns $true if GitHub CLI is installed and accessible, $false otherwise.

    .NOTES
        This function uses the Get-Command cmdlet to check for the existence of the 'gh' command.
        It also attempts to run 'gh --version' to verify the command is operational.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        # Check if gh command exists in the path
        if (-not (Get-Command -Name 'gh' -ErrorAction SilentlyContinue)) {
            Write-Log -Message "GitHub CLI (gh) is not installed or not in the system PATH." -Level Warning
            return $false
        }

        # Verify gh command works by checking version
        $null = gh --version 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log -Message "GitHub CLI (gh) is installed but returned an error when executed." -Level Warning
            return $false
        }

        Write-Log -Message "GitHub CLI (gh) is installed and working properly." -Level Verbose
        return $true
    }
    catch {
        Write-Log -Message "Error checking GitHub CLI installation: $_" -Level Error
        return $false
    }
}

function Test-GitHubLogin {
    <#
    .SYNOPSIS
        Verifies if the user is logged into GitHub using the GitHub CLI.

    .DESCRIPTION
        This function checks the authentication status of the GitHub CLI (`gh`) for the GitHub.com host.
        It logs a warning if the user is not logged in or if the GitHub CLI is not installed or accessible.

    .EXAMPLE
        Test-GitHubLogin

        Checks if the user is logged into GitHub. Returns $true if logged in, $false otherwise.

    .OUTPUTS
        System.Boolean
        Returns $true if the user is logged into GitHub, $false otherwise.

    .NOTES
        This function requires the GitHub CLI (`gh`) to be installed and available in the system PATH.
        If the CLI is not installed or the user is not logged in, appropriate warnings are logged.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $userInfo = gh auth status -h github.com 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log -Message "You are not logged into GitHub. Please run 'gh auth login' first." -Level Warning
            return $false
        }
        Write-Log -Message "You are logged into GitHub as $($userInfo)" -Level Verbose
        return $true
    }
    catch {
        Write-Log -Message "GitHub CLI is not installed or accessible. Please make sure it's installed and in your PATH." -Level Warning
        return $false
    }
}

function Invoke-RepoMirrorClone {
    <#
    .SYNOPSIS
        Performs a mirror clone of a Git repository.

    .DESCRIPTION
        This function creates a mirror clone of a Git repository to the specified path.
        If the repository already exists, it checks if it's a proper mirror clone and
        either updates it or re-clones it as needed. When running in dry-run mode,
        it simulates the operations without making actual changes.

    .PARAMETER RepoName
        The name of the repository to clone.
        Must contain only letters, numbers, underscores, hyphens, and periods.

    .PARAMETER CloneUrl
        The URL of the Git repository to clone.
        Must be a valid Git URL format (HTTPS, SSH, or git protocol).

    .PARAMETER BasePath
        The base directory where the repository will be cloned.
        Must be an existing directory with appropriate permissions.

    .PARAMETER DryRun
        When specified, simulates the operations without making actual changes.
        All operations will be logged with a "DRY RUN:" prefix at Warning level.

    .EXAMPLE
        Invoke-RepoMirrorClone -RepoName "my-repo" -CloneUrl "https://github.com/user/my-repo.git" -BasePath "D:\Backups\Repos"

        Creates or updates a mirror clone of the repository at D:\Backups\Repos\my-repo.git

    .EXAMPLE
        Invoke-RepoMirrorClone -RepoName "my-repo" -CloneUrl "https://github.com/user/my-repo.git" -BasePath "D:\Backups\Repos" -DryRun

        Simulates the mirror clone operation without making any actual changes.

    .OUTPUTS
        System.String
        Returns the full path to the cloned repository, or $null if the clone operation failed.
        In dry-run mode, returns the path that would be used.

    .NOTES
        - The function adds '.git' extension to the repository folder automatically
        - Requires Git to be installed and available in the system PATH
        - In dry-run mode, no filesystem changes or git operations are performed
        - Uses Write-Log for operation logging with appropriate severity levels
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({
            if ([string]::IsNullOrWhiteSpace($_)) {
                throw "The RepoName parameter cannot be empty or contain only whitespace characters."
            }
            # Validate repository name format (no spaces, special characters limited)
            if (-not ($_ -match '^[a-zA-Z0-9_.-]+$')) {
                throw "The RepoName parameter contains invalid characters. Use only letters, numbers, underscores, hyphens, and periods."
            }
            return $true
        })]
        [string]$RepoName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({
            if ([string]::IsNullOrWhiteSpace($_)) {
                throw "The CloneUrl parameter cannot be empty or contain only whitespace characters."
            }
            # Validate Git URL format
            if (-not ($_ -match '^(https?://|git@|ssh://)([\w.-]+)(:\d+)?/[\w.-]+/[\w.-]+(\.git)?$')) {
                throw "The CloneUrl parameter is not a valid Git repository URL."
            }
            return $true
        })]
        [string]$CloneUrl,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({
            if ([string]::IsNullOrWhiteSpace($_)) {
                throw "The BasePath parameter cannot be empty or contain only whitespace characters."
            }
            # Validate path exists and is a directory
            if (Test-Path -Path $_ -PathType Container) {
                return $true
            }
            throw "The BasePath '$_' does not exist or is not a directory."
        })]
        [string]$BasePath,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun = $false
    )

    # Add .git to the target repository path
    $repoPath = Join-Path -Path $BasePath -ChildPath "$RepoName.git"

    if (Test-Path -Path $repoPath) {
        # Check if it's a directory and a git repo
        if ((Test-Path -Path $repoPath -PathType Container) -and (Test-Path -Path "$repoPath\config")) {
            # Check if it's a mirror clone
            Push-Location $repoPath
            try {
                $isMirror = git config --get remote.origin.mirror 2>$null
                $originUrl = git config --get remote.origin.url 2>$null

                if ($isMirror -eq "true" -and $originUrl -eq $CloneUrl) {
                    if ($DryRun) {
                        Write-Log -Message "DRY RUN: Would update existing mirror repository '$RepoName' at '$repoPath'" -Level Warning
                        Pop-Location
                        return $repoPath
                    }
                    Write-Log -Message "Mirror repository '$RepoName' already exists at '$repoPath'. Updating instead of cloning." -Level Information
                    Update-Repository -RepoPath $repoPath -RepoName $RepoName
                    return $repoPath
                } else {
                    Write-Log -Message "Repository at '$repoPath' exists but is not a mirror of '$CloneUrl'. Removing and re-cloning." -Level Warning
                    Pop-Location
                    if (-not $DryRun) {
                        Remove-Item -Path $repoPath -Recurse -Force
                    } else {
                        Write-Log -Message "DRY RUN: Would remove non-mirror repository at '$repoPath'" -Level Warning
                    }
                }
            }
            catch {
                Write-Log -Message "Error checking repository status: $_" -Level Warning
                Pop-Location
                if (-not $DryRun) {
                    Remove-Item -Path $repoPath -Recurse -Force
                } else {
                    Write-Log -Message "DRY RUN: Would remove invalid repository at '$repoPath'" -Level Warning
                }
            }
        } else {
            # Path exists but is not a proper git repository
            Write-Log -Message "Path '$repoPath' exists but is not a valid git repository. Removing and re-cloning." -Level Warning
            if (-not $DryRun) {
                Remove-Item -Path $repoPath -Recurse -Force
            } else {
                Write-Log -Message "DRY RUN: Would remove invalid git repository at '$repoPath'" -Level Warning
            }
        }
    }

    # Perform mirror clone
    if ($DryRun) {
        Write-Log -Message "DRY RUN: Would mirror clone repository '$RepoName' to '$repoPath'" -Level Warning
        return $repoPath
    }

    Write-Log -Message "Mirror cloning repository '$RepoName' to '$repoPath'..." -Level Information
    git clone --mirror $CloneUrl $repoPath

    if ($LASTEXITCODE -ne 0) {
        Write-Log -Message "Failed to mirror clone repository '$RepoName'." -Level Error
        return $null
    }

    return $repoPath
}

function Update-Repository {
    <#
    .SYNOPSIS
        Updates a Git repository by fetching all remote branches and tags.

    .DESCRIPTION
        This function updates a Git mirror repository by fetching all branches and tags
        from the remote origin, including pruning any references that no longer exist.

    .PARAMETER RepoPath
        The full path to the Git repository to update.

    .PARAMETER RepoName
        The name of the repository, used for logging purposes.

    .PARAMETER Remote
        The name of the Git remote to fetch from. Defaults to 'origin'.

    .PARAMETER All
        When specified, fetches from all remotes instead of just the specified remote.

    .EXAMPLE
        Update-Repository -RepoPath "D:\Backups\Repos\my-repo.git" -RepoName "my-repo"

        Updates the Git repository at the specified path by fetching from the 'origin' remote.

    .EXAMPLE
        Update-Repository -RepoPath "D:\Backups\Repos\my-repo.git" -RepoName "my-repo" -Remote "upstream"

        Updates the Git repository at the specified path by fetching from the 'upstream' remote.

    .EXAMPLE
        Update-Repository -RepoPath "D:\Backups\Repos\my-repo.git" -RepoName "my-repo" -All

        Updates the Git repository at the specified path by fetching from all remotes.

    .OUTPUTS
        None

    .NOTES
        This function requires Git to be installed and available in the system PATH.
        It is primarily used to update mirror clones created with Invoke-RepoMirrorClone.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({
            if (-not (Test-Path -Path $_)) {
                throw "The repository path '$_' does not exist."
            }
            return $true
        })]
        [string]$RepoPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepoName,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$Remote = "origin",

        [Parameter(Mandatory = $false)]
        [switch]$All = $false
    )

    if (-not $RepoPath -or -not (Test-Path -Path $RepoPath)) {
        Write-Log -Message "Repository path '$RepoPath' does not exist. Skipping update." -Level Warning
        return
    }

    Push-Location $RepoPath

    try {
        Write-Log -Message "Updating repository '$RepoName'..." -Level Information

        # Fetch all remote branches
        if ($All) {
            Write-Log -Message "Fetching all branches from all remotes for '$RepoName'..." -Level Verbose
            git fetch --all --prune --prune-tags
        } else {
            Write-Log -Message "Fetching all branches from remote '$Remote' for '$RepoName'..." -Level Verbose
            git fetch --prune --prune-tags $Remote
        }

        if ($LASTEXITCODE -ne 0) {
            Write-Log -Message "Failed to fetch remote branches for '$RepoName'." -Level Error
            return
        }

        Write-Log -Message "Successfully updated repository '$RepoName'." -Level Information
    }
    catch {
        Write-Log -Message "Error updating repository '$RepoName': $_" -Level Error
    }
    finally {
        Pop-Location
    }
}

function Start-MirrorCloneBackup {
    <#
    .SYNOPSIS
        Performs mirror clone backup of GitHub repositories.

    .DESCRIPTION
        This function retrieves all non-archived repositories from the current GitHub user's account
        and creates mirror clones of them in the specified destination directory. It handles
        authentication verification, repository listing, and clone/update operations.

    .PARAMETER Source
        The source path (currently unused, maintained for handler interface compatibility).

    .PARAMETER Destination
        The destination directory where repository mirrors will be created.

    .PARAMETER Options
        Additional options (currently unused, maintained for handler interface compatibility).

    .PARAMETER DryRun
        When specified, simulates the operations without making actual changes.

    .OUTPUTS
        System.Boolean
        Returns $true if all operations completed successfully, $false otherwise.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $false)]
        [string[]]$Options,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun = $false
    )

    if (-not (Test-GitHubCliInstalled)) {
        Write-Log -Message "GitHub CLI is not installed. Exiting backup job." -Level Error
        return $false
    }

    if (-not (Test-GitHubLogin)) {
        Write-Log -Message "User is not logged into GitHub. Exiting backup job." -Level Error
        return $false
    }

    try {
        # Ensure the destination directory exists
        New-DirectoryIfNotExists -Path $Destination -DryRun:$DryRun

        Write-Log -Message "Fetching all non-archived repositories for current GitHub user..." -Level Information
        $repos = gh repo list --json name,url,isArchived --limit 1000 | ConvertFrom-Json | Where-Object { -not $_.isArchived }

        if (-not $repos -or $repos.Count -eq 0) {
            Write-Log -Message "No repositories found for the current GitHub user." -Level Warning
            return $false
        }

        Write-Log -Message "Found $($repos.Count) repositories to process." -Level Information

        # Clone or update each repository
        foreach ($repo in $repos) {
            if (-not $repo.url.EndsWith(".git")) {
                $repo.url = "$($repo.url).git"
            }

            Write-Log -Message "Processing repository: $($repo.name)" -Level Verbose
            $repoPath = Invoke-RepoMirrorClone -RepoName $repo.name -CloneUrl $repo.url -BasePath $Destination -DryRun:$DryRun

            if (-not $repoPath) {
                Write-Log -Message "Failed to process repository: $($repo.name)" -Level Warning
                continue
            }
        }

        Write-Log -Message "Mirror clone backup completed successfully." -Level Information
        return $true
    }
    catch {
        Write-Log -Message "Error during mirror clone backup: $_" -Level Error
        return $false
    }
}

function Start-GitBundleBackup {
    <#
    .SYNOPSIS
        Creates Git bundle backups from mirror clone repositories.

    .DESCRIPTION
        This function creates Git bundle files from mirror clone repositories found in the source directory.
        It processes all first-level subdirectories containing '.git' in their name, verifies if they are
        mirror clones, and creates Git bundles in a temporary location before moving them to the final
        destination.

    .PARAMETER Source
        The source directory containing Git mirror clone repositories.
        Must be a valid directory path containing Git repositories.

    .PARAMETER Destination
        The destination directory where Git bundle files will be stored.
        Directory will be created if it doesn't exist.

    .PARAMETER Options
        Additional options for bundle creation (currently unused, maintained for handler interface compatibility).

    .PARAMETER DryRun
        When specified, simulates the operations without making actual changes.

    .EXAMPLE
        Start-GitBundleBackup -Source "D:\Repos" -Destination "D:\Backups\Bundles"

        Creates Git bundles from all mirror clone repositories in D:\Repos and stores them in D:\Backups\Bundles.

    .EXAMPLE
        Start-GitBundleBackup -Source "D:\Repos" -Destination "D:\Backups\Bundles" -DryRun

        Simulates Git bundle creation without making actual changes.

    .OUTPUTS
        System.Boolean
        Returns $true if all operations completed successfully, $false if any critical errors occurred.

    .NOTES
        - Requires Git to be installed and available in the system PATH
        - Only processes first-level subdirectories containing '.git' in their name
        - Skips repositories that are not mirror clones
        - Uses a temporary directory for interim bundle storage
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateScript({
            if (-not (Test-Path -Path $_)) {
                throw "Source path '$_' does not exist."
            }
            return $true
        })]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $false)]
        [string[]]$Options,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun = $false
    )

    try {
        # Ensure the destination directory exists
        New-DirectoryIfNotExists -Path $Destination -DryRun:$DryRun

        # Create temporary directory
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("git-bundles-" + [Guid]::NewGuid().ToString())
        if (-not $DryRun) {
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            Write-Log -Message "Created temporary directory: $tempDir" -Level Verbose
        } else {
            Write-Log -Message "DRY RUN: Would create temporary directory: $tempDir" -Level Warning
        }

        # Get all first-level subdirectories containing '.git'
        $gitDirs = Get-ChildItem -Path $Source -Directory |
            Where-Object { $_.Name -like "*.git*" }

        $success = $true
        foreach ($dir in $gitDirs) {
            Push-Location $dir.FullName
            try {
                # Check if it's a mirror clone
                $isMirror = git config --get remote.origin.mirror 2>$null

                if ($isMirror -ne "true") {
                    Write-Log -Message "Directory '$($dir.Name)' is not a mirror clone. Skipping." -Level Warning
                    continue
                }

                $bundleName = "$($dir.BaseName).bundle"
                $bundlePath = Join-Path $tempDir $bundleName

                if ($DryRun) {
                    Write-Log -Message "DRY RUN: Would create bundle for repository '$($dir.Name)' at '$bundlePath'" -Level Warning
                    continue
                }

                # Create bundle
                Write-Log -Message "Creating bundle for repository '$($dir.Name)'..." -Level Information
                git bundle create $bundlePath --all 2>&1

                if ($LASTEXITCODE -ne 0) {
                    Write-Log -Message "Failed to create bundle for '$($dir.Name)'" -Level Error
                    $success = $false
                    continue
                }
            }
            finally {
                Pop-Location
            }
        }

        if (-not $DryRun -and (Test-Path $tempDir)) {
            # Move bundles to destination
            Get-ChildItem -Path $tempDir -Filter "*.bundle" | ForEach-Object {
                $destPath = Join-Path $Destination $_.Name
                Move-Item -Path $_.FullName -Destination $destPath -Force
                Write-Log -Message "Moved bundle to: $destPath" -Level Verbose
            }

            # Cleanup temporary directory
            Remove-Item -Path $tempDir -Recurse -Force
            Write-Log -Message "Removed temporary directory: $tempDir" -Level Verbose
        }

        Write-Log -Message "Git bundle backup completed successfully." -Level Information
        return $success
    }
    catch {
        Write-Log -Message "Error during Git bundle backup: $_" -Level Error
        if (-not $DryRun -and (Test-Path $tempDir)) {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
}

function Start-GitHubRepoBackupJob {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$CodeRepoBackupConfig,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun = $false
    )

    foreach ($target in $CodeRepoBackupConfig.targets) {
        Write-Log -Message "Start processing mirror clone target: $($target.description)" -Level Information

        # Process all mirror clone destinations
        $CodeRepoBackupConfig.destinations.mirror_clones |
            Start-BackupByDestination -Target $target -Handlers $CodeRepoBackupConfig.handlers -DryRun:$DryRun
    }

    # Handle git bundle destinations
    foreach ($target in $CodeRepoBackupConfig.targets) {
        Write-Log -Message "Start processing git bundle target: $($target.description)" -Level Information

        # Process all git bundle destinations
        $CodeRepoBackupConfig.destinations.git_bundles |
            Start-BackupByDestination -Target $target -Handlers $CodeRepoBackupConfig.handlers -DryRun:$DryRun
    }
    Write-Log -Message "Backup cycle completed for target: $($target.description)" -Level Information
}
#endregion Functions


#region Main
# Check if the configuration file path environment variable is set
if (-not (Test-EnvironmentVariable -Name $CONFIG_PATH_ENV_VAR_NAME)) {
    Write-Log -Message "Environment variable '$CONFIG_PATH_ENV_VAR_NAME' is not set. Please set it to the path of your backup configuration file." -Level Error
    exit 1
}

$config = Import-TomlConfig -ConfigPath "$([Environment]::GetEnvironmentVariable($CONFIG_PATH_ENV_VAR_NAME))"

Start-GitHubRepoBackupJob -CodeRepoBackupConfig $config.code_repos -DryRun:$DryRun
Start-StaticBackupJob -StaticBackupConfig $config.static -DryRun:$DryRun

Write-Log -Message "All backup jobs completed." -Level Information
#endregion Main
