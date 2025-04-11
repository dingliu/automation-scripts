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

function Start-7zipBackup {
    <#
    .SYNOPSIS
        Creates a 7zip archive from a source directory and saves it to a destination directory.

    .DESCRIPTION
        This function creates a 7zip archive from the specified source directory and saves it to
        the destination directory. The archive is first created in a temporary location and then
        moved to the final destination, overwriting any existing archive with the same name.
        It supports various 7zip options passed as parameters and can operate in dry-run mode for testing.

    .PARAMETER Source
        The source directory to be archived. Will have a trailing backslash added if missing.

    .PARAMETER Destination
        The destination directory where the archive will be stored. Will have a trailing backslash added if missing.

    .PARAMETER Options
        An array of 7zip command-line options to be used with the archiving operation.

    .PARAMETER DryRun
        When specified, simulates the operations without making actual changes.

    .EXAMPLE
        Start-7zipBackup -Source "C:\Data" -Destination "D:\Backup" -Options @("-mx=9", "-mmt=on")

        Creates a 7zip archive of the C:\Data directory in D:\Backup with maximum compression and multi-threading enabled.

    .EXAMPLE
        Start-7zipBackup -Source "C:\Projects" -Destination "D:\Backup\Archives" -DryRun

        Simulates creating a 7zip archive without actually performing the operation.

    .OUTPUTS
        System.Boolean
        Returns $true if the archive was created successfully, $false otherwise.

    .NOTES
        This function requires 7zip to be installed and available in the system PATH.
        The naming convention for archives is: <source_directory_name>.7z
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

    # Ensure source and destination paths end with a backslash
    if (-not $Source.EndsWith('\')) { $Source = "$Source\" }
    if (-not $Destination.EndsWith('\')) { $Destination = "$Destination\" }

    # Check if 7zip is installed
    try {
        $null = Get-Command -Name "7z" -ErrorAction Stop
    }
    catch {
        Write-Log -Message "7-Zip is not installed or not in the system PATH. Please install 7-Zip and ensure it's in your PATH." -Level Error
        return $false
    }

    # Get source directory name for the archive name
    $sourceDirName = Split-Path -Path $Source.TrimEnd('\') -Leaf

    # Create archive file name using just the source directory name
    $archiveFileName = "$sourceDirName.7z"
    $archivePath = Join-Path -Path $Destination -ChildPath $archiveFileName

    # Create a temporary directory for interim storage
    $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("7zip-temp-" + [Guid]::NewGuid().ToString())
    $tempArchivePath = Join-Path -Path $tempDir -ChildPath $archiveFileName

    Write-Log -Message "Starting 7zip backup from '$Source' to '$archivePath' (via temporary location)" -Level Information

    if ($DryRun) {
        Write-Log -Message "Dry run mode enabled. No archive will be created." -Level Warning
        Write-Log -Message "Would create temporary directory: $tempDir" -Level Warning
        Write-Log -Message "Would create 7zip archive in temp location: $tempArchivePath" -Level Warning
        Write-Log -Message "Would move archive to final destination: $archivePath" -Level Warning
        return $true
    }

    try {
        # Create temporary directory
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        Write-Log -Message "Created temporary directory: $tempDir" -Level Verbose

        # Prepare 7zip command
        $sourceForArchive = $Source.TrimEnd('\') # Remove trailing backslash
        $sevenZipArgs = @("a")

        # Add temporary archive path
        $sevenZipArgs += "`"$tempArchivePath`""

        # Add source path with wildcard
        $sevenZipArgs += "`"$sourceForArchive\*`""

        # Add any user-specified options
        if ($Options -and $Options.Count -gt 0) {
            $sevenZipArgs += $Options
            Write-Log -Message "Using 7zip options: $($Options -join ' ')" -Level Information
        }

        # Execute 7zip
        Write-Log -Message "Creating 7zip archive in temporary location: $tempArchivePath" -Level Information
        $process = Start-Process -FilePath "7z" -ArgumentList $sevenZipArgs -NoNewWindow -Wait -PassThru

        if ($process.ExitCode -eq 0) {
            Write-Log -Message "7zip archive created successfully in temporary location: $tempArchivePath" -Level Information

            # Ensure destination directory exists
            New-DirectoryIfNotExists -Path $Destination -DryRun:$DryRun

            # Move the archive(s) to the destination, handling both single and multi-volume archives
            Write-Log -Message "Moving archive(s) to final destination..." -Level Information

            # First, check if we have a multi-volume archive or a single file
            $archiveFiles = Get-ChildItem -Path $tempDir -File | Where-Object {
                $_.Name -like "$archiveFileName*" -or # Handle the base file
                $_.Name -match "$([regex]::Escape($archiveFileName))\.\d{3}$" # Handle volume parts (.001, .002, etc.)
            }

            if ($archiveFiles.Count -eq 0) {
                Write-Log -Message "No archive files found in temporary directory. Backup may have failed." -Level Error
                return $false
            }

            foreach ($file in $archiveFiles) {
                $destinationFile = Join-Path -Path $Destination -ChildPath $file.Name
                Move-Item -Path $file.FullName -Destination $destinationFile -Force
                Write-Log -Message "Moved archive file: $($file.Name) to $Destination" -Level Verbose
            }

            Write-Log -Message "7zip archive(s) moved successfully to: $Destination" -Level Information
            return $true
        } else {
            Write-Log -Message "Failed to create 7zip archive. 7-Zip returned exit code: $($process.ExitCode)" -Level Error
            return $false
        }
    }
    catch {
        Write-Log -Message "Failed to create 7zip archive: $_" -Level Error
        return $false
    }
    finally {
        # Clean up temporary directory
        if (Test-Path -Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log -Message "Removed temporary directory: $tempDir" -Level Verbose
        }
    }
}

function Start-MultiparBackup {
    <#
    .SYNOPSIS
        Generates par2 files for files in a source directory and moves them to a destination directory.

    .DESCRIPTION
        This function uses the MultiPar tool to create par2 parity files for all files directly in the source directory.
        It then moves both the original files and the generated par2 files to the destination directory.
        The function supports dry run mode and various MultiPar options.

    .PARAMETER Source
        The source directory containing files to process. Will have a trailing backslash added if missing.

    .PARAMETER Destination
        The destination directory where files and par2 files will be moved. Will have a trailing backslash added if missing.
        The directory will be created if it doesn't exist.

    .PARAMETER Options
        An array of MultiPar command-line options to be used with the operation.

    .PARAMETER DryRun
        When specified, simulates the operations without making actual changes.

    .EXAMPLE
        Start-MultiparBackup -Source "C:\Data" -Destination "D:\Backup\Archive" -Options @("/rk10", "/lc32")

        Generates par2 files for all files in C:\Data with 10% recovery blocks and 32KB block size,
        then moves all files to D:\Backup\Archive.

    .EXAMPLE
        Start-MultiparBackup -Source "C:\Documents" -Destination "D:\Backup\Docs" -DryRun

        Simulates generating par2 files and moving files without performing actual operations.

    .OUTPUTS
        System.Boolean
        Returns $true if the operation was successful, $false otherwise.

    .NOTES
        This function requires MultiPar to be installed and available in the system PATH.
        Only processes files directly in the source directory, not in subdirectories.
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

    # Ensure source and destination paths end with a backslash
    if (-not $Source.EndsWith('\')) { $Source = "$Source\" }
    if (-not $Destination.EndsWith('\')) { $Destination = "$Destination\" }

    $multiparCommand = "par2j64" # Assuming MultiPar is installed as par2j64

    # Check if multipar is installed
    try {
        $null = Get-Command -Name "$multiparCommand" -ErrorAction Stop
    }
    catch {
        Write-Log -Message "MultiPar is not installed or not in the system PATH. Please install MultiPar and ensure it's in your PATH." -Level Error
        return $false
    }

    # Get files only directly in the source directory (not in subdirectories)
    $files = Get-ChildItem -Path $Source -File -Depth 0 | Where-Object { $_.Extension -ne '.par2' }

    if ($files.Count -eq 0) {
        Write-Log -Message "No files found in source directory: $Source" -Level Warning
        return $true  # Return true as there was no error, just no files to process
    }

    Write-Log -Message "Found $($files.Count) files to process in $Source" -Level Information

    # Create destination directory if it doesn't exist
    if (-not (Test-Path -Path $Destination)) {
        if ($DryRun) {
            Write-Log -Message "Dry run mode enabled. Would create destination directory: $Destination" -Level Warning
        }
        else {
            try {
                Write-Log -Message "Creating destination directory: $Destination" -Level Information
                New-DirectoryIfNotExists -Path $Destination -DryRun:$DryRun
            }
            catch {
                Write-Log -Message "Failed to create destination directory: $_" -Level Error
                return $false
            }
        }
    }

    # Create a temp working directory for par2 files
    $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("multipar-" + [Guid]::NewGuid().ToString())

    if (-not $DryRun) {
        try {
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            Write-Log -Message "Created temporary working directory: $tempDir" -Level Verbose
        }
        catch {
            Write-Log -Message "Failed to create temporary directory: $_" -Level Error
            return $false
        }
    }
    else {
        Write-Log -Message "Dry run mode enabled. Would create temporary directory: $tempDir" -Level Warning
    }

    try {
        foreach ($file in $files) {
            # For each file, create a par2 file
            $baseFileName = $file.Name
            $sourceFilePath = $file.FullName

            # Prepare multipar command
            $multiparArgs = @("create")

            # Add any user-specified options
            if ($Options -and $Options.Count -gt 0) {
                $multiparArgs += $Options
                Write-Log -Message "Using MultiPar options: $($Options -join ' ')" -Level Information
            }

            # Add output filepath (quoted to handle spaces)
            $par2Filename = "$baseFileName.par2"
            $par2Filepath = Join-Path -Path $tempDir -ChildPath $par2Filename
            $multiparArgs += "`"$par2Filepath`""

            # Add source filepath (quoted to handle spaces)
            $multiparArgs += "`"$sourceFilePath`""

            if ($DryRun) {
                Write-Log -Message "Dry run mode enabled. Would run: $multiparCommand $($multiparArgs -join ' ')" -Level Warning
            }
            else {
                # Execute MultiPar to create par2 files
                Write-Log -Message "Generating par2 files for: $baseFileName" -Level Information
                $process = Start-Process -FilePath "$multiparCommand" -ArgumentList $multiparArgs -NoNewWindow -Wait -PassThru

                if ($process.ExitCode -ne 0) {
                    Write-Log -Message "MultiPar failed for file $baseFileName with exit code: $($process.ExitCode)" -Level Error
                    continue
                }
            }
        }

        if ($DryRun) {
            Write-Log -Message "Would move source files and generated par2 files to: $Destination" -Level Warning
        }
        else {
            # Move original files to destination
            foreach ($file in $files) {
                $destinationFilePath = Join-Path -Path $Destination -ChildPath $file.Name
                Move-Item -Path $file.FullName -Destination $destinationFilePath -Force
                Write-Log -Message "Moved file: $($file.Name) to $Destination" -Level Verbose
            }

            # Move par2 files from temp directory to destination
            $par2Files = Get-ChildItem -Path $tempDir -Filter "*.par2" -File
            foreach ($par2File in $par2Files) {
                $destinationPar2Path = Join-Path -Path $Destination -ChildPath $par2File.Name
                Move-Item -Path $par2File.FullName -Destination $destinationPar2Path -Force
                Write-Log -Message "Moved par2 file: $($par2File.Name) to $Destination" -Level Verbose
            }

            Write-Log -Message "Successfully created par2 files and moved all files to $Destination" -Level Information
        }

        return $true
    }
    catch {
        Write-Log -Message "Failed to process files with MultiPar: $_" -Level Error
        return $false
    }
    finally {
        # Clean up temporary directory if it exists
        if (-not $DryRun -and (Test-Path -Path $tempDir)) {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log -Message "Removed temporary directory: $tempDir" -Level Verbose
        }
    }
}

function Initialize-BackupDirectories {
    <#
    .SYNOPSIS
        Creates the required directory structure for backup rotation.

    .DESCRIPTION
        This function creates the main destination directory and the subdirectories
        for daily and weekly backups. It handles the DryRun mode by logging what
        would happen instead of creating directories.

    .PARAMETER Destination
        The base destination directory where daily and weekly backup folders will be created.

    .PARAMETER DryRun
        When specified, simulates operations without making actual changes.

    .EXAMPLE
        Initialize-BackupDirectories -Destination "D:\Backups\Documents" -DryRun:$false

        Creates the directory structure for backup rotation.

    .OUTPUTS
        System.Object
        Returns an object with paths to daily and weekly backup folders.
    #>
    [CmdletBinding()]
    [OutputType([System.Object])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun = $false
    )

    # Create daily and weekly backup paths
    $dailyBackupPath = Join-Path -Path $Destination -ChildPath "daily"
    $weeklyBackupPath = Join-Path -Path $Destination -ChildPath "weekly"

    if ($DryRun) {
        Write-Log -Message "DRY RUN: Would ensure destination directory exists: $Destination" -Level Warning
        Write-Log -Message "DRY RUN: Would ensure daily backup directory exists: $dailyBackupPath" -Level Warning
        Write-Log -Message "DRY RUN: Would ensure weekly backup directory exists: $weeklyBackupPath" -Level Warning
    } else {
        try {
            New-DirectoryIfNotExists -Path $Destination -DryRun:$DryRun
            New-DirectoryIfNotExists -Path $dailyBackupPath -DryRun:$DryRun
            New-DirectoryIfNotExists -Path $weeklyBackupPath -DryRun:$DryRun
        }
        catch {
            Write-Log -Message "Failed to create directory structure: $_" -Level Error
            throw
        }
    }

    return @{
        DailyPath = $dailyBackupPath
        WeeklyPath = $weeklyBackupPath
    }
}

function Move-FilesToDailyBackup {
    <#
    .SYNOPSIS
        Moves files from source to daily backup folder with date pattern.

    .DESCRIPTION
        This function processes files from the source directory, adds date patterns
        to filenames, and moves them to the daily backup folder. Files are grouped
        by their base name to maintain related files together.

    .PARAMETER Source
        The source directory containing files to be backed up.

    .PARAMETER DailyBackupPath
        The destination directory for daily backups.

    .PARAMETER DryRun
        When specified, simulates the operations without making actual changes.

    .EXAMPLE
        Move-FilesToDailyBackup -Source "D:\Cache" -DailyBackupPath "D:\Backups\Daily" -DryRun:$false

        Moves files from cache directory to daily backup folder with date pattern.

    .OUTPUTS
        System.Boolean
        Returns $true if all operations completed successfully, $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$DailyBackupPath,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun = $false
    )

    $operationSuccess = $true

    # Get today's date information
    $today = Get-Date
    $currentDate = $today.ToString("yyyyMMdd")
    $currentDayOfWeek = $today.DayOfWeek.ToString().ToLower()

    # Daily backup suffix for file renaming
    $dailyBackupSuffix = "-daily-$currentDate-$currentDayOfWeek"

    # Get all files directly under the source directory
    try {
        $sourceFiles = Get-ChildItem -Path $Source -File -Depth 0
    }
    catch {
        Write-Log -Message "Failed to get source files from ${Source}: $_" -Level Error
        return $false
    }

    # Group files by their primary name part (before first dot)
    $fileGroups = $sourceFiles | Group-Object {
        if ($_.Name -match '^([^.]+)') {
            $Matches[1]  # Extract everything before the first dot
        } else {
            $_.BaseName  # Fallback
        }
    }

    foreach ($group in $fileGroups) {
        $primaryName = $group.Name
        $files = $group.Group

        foreach ($file in $files) {
            $fileName = $file.Name

            # Skip files that already have a date pattern
            if ($fileName -match "-daily-\d{8}-[a-z]+") {
                Write-Log -Message "File $fileName already has a date pattern. Skipping renaming." -Level Warning
                continue
            }

            # Split into primary and secondary parts
            if ($fileName -match '^([^.]+)(.*)$') {
                $primaryPart = $Matches[1]
                $secondaryPart = $Matches[2]
            } else {
                $primaryPart = $fileName
                $secondaryPart = ""
            }

            # Create new filename with date pattern
            $newFileName = "$primaryPart$dailyBackupSuffix$secondaryPart"
            $sourceFilePath = $file.FullName
            $destFilePath = Join-Path -Path $DailyBackupPath -ChildPath $newFileName

            if ($DryRun) {
                Write-Log -Message "DRY RUN: Would rename and move file from $sourceFilePath to $destFilePath" -Level Warning
            } else {
                try {
                    Write-Log -Message "Moving file from $sourceFilePath to $destFilePath" -Level Information
                    Move-Item -Path $sourceFilePath -Destination $destFilePath -Force
                } catch {
                    Write-Log -Message "Failed to move file ${fileName}: $_" -Level Error
                    $operationSuccess = $false
                }
            }
        }
    }

    return $operationSuccess
}

function Get-DateInfoFromBackupFiles {
    <#
    .SYNOPSIS
        Extracts date information from backup filenames.

    .DESCRIPTION
        This function extracts date and day of week information from backup filenames
        with patterns like "-daily-YYYYMMDD-dayofweek" or "-weekly-YYYYMMDD-dayofweek".
        It returns a collection of custom objects with date information.

    .PARAMETER BackupFiles
        A collection of file objects with names containing date patterns.

    .PARAMETER Pattern
        The regex pattern to extract date information from filenames.
        Defaults to "-daily-(\d{8})-([a-z]+)" for daily backups.

    .EXAMPLE
        Get-DateInfoFromBackupFiles -BackupFiles $dailyBackups -Pattern "-daily-(\d{8})-([a-z]+)"

        Extracts date information from daily backup files.

    .OUTPUTS
        System.Object[]
        Returns an array of objects with date information extracted from filenames.
    #>
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param (
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo[]]$BackupFiles,

        [Parameter(Mandatory = $false)]
        [string]$Pattern = "-daily-(\d{8})-([a-z]+)"
    )

    # Use @() to ensure array output even when only one item is processed
    $dateInfoCollection = @($BackupFiles | ForEach-Object {
        if ($_.Name -match $Pattern) {
            $dateStr = $Matches[1]
            $weekDayStr = $Matches[2]
            $backupDate = [DateTime]::ParseExact($dateStr, "yyyyMMdd", $null)

            # Convert string day of week to integer (Monday = 1, Sunday = 7)
            $weekDay = switch ($weekDayStr) {
                "monday" { 1 }
                "tuesday" { 2 }
                "wednesday" { 3 }
                "thursday" { 4 }
                "friday" { 5 }
                "saturday" { 6 }
                "sunday" { 7 }
                default { 0 }
            }

            # Return info object
            [PSCustomObject]@{
                Date = $backupDate
                DateString = $dateStr
                WeekDay = $weekDay
                WeekDayString = $weekDayStr
                FileName = $_.Name
                FullPath = $_.FullName
                BaseName = if ($_.Name -match '^([^-]*)') { $Matches[1] } else { $_.Name }
            }
        }
    } | Sort-Object Date -Descending)

    return $dateInfoCollection
}

function Invoke-WeeklyBackupPromotion {
    <#
    .SYNOPSIS
        Promotes eligible daily backups to weekly backups.

    .DESCRIPTION
        This function identifies daily backups from the configured promotion day of the week
        that are over one week old and promotes them to weekly backups by copying them to
        the weekly backup folder with modified names.

    .PARAMETER DailyBackupPath
        The path to the daily backup folder.

    .PARAMETER WeeklyBackupPath
        The path to the weekly backup folder.

    .PARAMETER PromotionDayOfWeek
        The day of week (1-7) for promoting daily backups to weekly.

    .PARAMETER DryRun
        When specified, simulates operations without making actual changes.

    .EXAMPLE
        Invoke-WeeklyBackupPromotion -DailyBackupPath "D:\Backups\Daily" -WeeklyBackupPath "D:\Backups\Weekly" -PromotionDayOfWeek 1 -DryRun:$false

        Promotes Monday daily backups older than one week to weekly backups.

    .OUTPUTS
        System.Boolean
        Returns $true if all operations completed successfully, $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$DailyBackupPath,

        [Parameter(Mandatory = $true)]
        [string]$WeeklyBackupPath,

        [Parameter(Mandatory = $true)]
        [int]$PromotionDayOfWeek,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun = $false
    )

    $operationSuccess = $true
    $today = Get-Date
    $oneWeekAgo = $today.AddDays(-7)

    try {
        # Get all files with daily backup pattern
        $dailyBackups = Get-ChildItem -Path $DailyBackupPath -File |
            Where-Object { $_.Name -match "-daily-(\d{8})-([a-z]+)" }

        if ($dailyBackups.Count -eq 0) {
            Write-Log -Message "No daily backups found for promotion." -Level Information
            return $true
        }

        # Extract date information from daily backups
        $dateInfoCollection = Get-DateInfoFromBackupFiles -BackupFiles $dailyBackups

        # Group by base name for processing related files together
        $groupedBackups = $dateInfoCollection | Group-Object BaseName

        foreach ($group in $groupedBackups) {
            $baseNamePattern = $group.Name
            $backupFiles = $group.Group

            # Find candidates for promotion (backups from target day of week older than one week)
            $promotionCandidates = @($backupFiles | Where-Object {
                $_.WeekDay -eq $PromotionDayOfWeek -and $_.Date -lt $oneWeekAgo
            })

            if ($promotionCandidates.Count -gt 0) {
                # Get most recent candidate
                $latestCandidate = $promotionCandidates[0]

                # Check if this backup has already been promoted
                $weeklyBackupPattern = "$baseNamePattern-weekly-$($latestCandidate.DateString)-$($latestCandidate.WeekDayString)*"
                $existingWeeklyBackup = Get-ChildItem -Path $WeeklyBackupPath -File -Filter $weeklyBackupPattern

                if ($existingWeeklyBackup.Count -eq 0) {
                    # Get all files that are part of this backup set
                    $candidateDate = $latestCandidate.DateString
                    $candidateWeekDay = $latestCandidate.WeekDayString
                    $filesToPromote = @($backupFiles | Where-Object {
                        $_.DateString -eq $candidateDate -and $_.WeekDayString -eq $candidateWeekDay
                    })

                    # Promote each file
                    foreach ($file in $filesToPromote) {
                        $originalName = $file.FileName
                        $promotedName = $originalName -replace "-daily-", "-weekly-"
                        $sourcePath = $file.FullPath
                        $destPath = Join-Path -Path $WeeklyBackupPath -ChildPath $promotedName

                        if ($DryRun) {
                            Write-Log -Message "DRY RUN: Would promote daily backup to weekly: copy from $sourcePath to $destPath" -Level Warning
                        } else {
                            try {
                                Write-Log -Message "Promoting daily backup to weekly: $originalName -> $promotedName" -Level Information
                                Copy-Item -Path $sourcePath -Destination $destPath -Force
                            } catch {
                                Write-Log -Message "Failed to promote backup ${originalName}: $_" -Level Error
                                $operationSuccess = $false
                            }
                        }
                    }
                } else {
                    Write-Log -Message "Backup set from $($latestCandidate.DateString) already promoted to weekly. Skipping promotion." -Level Information
                }
            } else {
                Write-Log -Message "No candidates found for promotion to weekly backup for $baseNamePattern" -Level Information
            }
        }
    }
    catch {
        Write-Log -Message "Error during backup promotion: $_" -Level Error
        $operationSuccess = $false
    }

    return $operationSuccess
}

function Remove-OldBackups {
    <#
    .SYNOPSIS
        Applies retention policies by removing old backups.

    .DESCRIPTION
        This function applies retention policies to daily or weekly backups by removing
        backups that exceed the configured retention count. It preserves the most recent
        backups and removes older ones.

    .PARAMETER BackupPath
        The path containing backup files to clean up.

    .PARAMETER RetentionCount
        The number of unique backup dates to retain.

    .PARAMETER FilePattern
        The regex pattern to identify the backup files (daily or weekly).

    .PARAMETER BackupType
        The type of backup (daily or weekly) for logging purposes.

    .PARAMETER DryRun
        When specified, simulates the removal without making actual changes.

    .EXAMPLE
        Remove-OldBackups -BackupPath "D:\Backups\Daily" -RetentionCount 7 -FilePattern "-daily-(\d{8})-" -BackupType "daily" -DryRun:$false

        Applies retention policy to daily backups, keeping only the 7 most recent dates.

    .OUTPUTS
        System.Boolean
        Returns $true if all operations completed successfully, $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$BackupPath,

        [Parameter(Mandatory = $true)]
        [int]$RetentionCount,

        [Parameter(Mandatory = $true)]
        [string]$FilePattern,

        [Parameter(Mandatory = $true)]
        [ValidateSet('daily', 'weekly')]
        [string]$BackupType,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun = $false
    )

    if ($RetentionCount -le 0) {
        Write-Log -Message "Retention count is zero or negative. Skipping cleanup for $BackupType backups." -Level Information
        return $true
    }

    $operationSuccess = $true

    try {
        # Get all files matching the pattern
        $backupFiles = Get-ChildItem -Path $BackupPath -File |
            Where-Object { $_.Name -match $FilePattern }

        if ($backupFiles.Count -eq 0) {
            Write-Log -Message "No $BackupType backups found for cleanup." -Level Information
            return $true
        }

        # Extract date information
        $dateInfoCollection = Get-DateInfoFromBackupFiles -BackupFiles $backupFiles -Pattern $FilePattern

        # Group by base name
        $groupedBackups = $dateInfoCollection | Group-Object BaseName

        foreach ($group in $groupedBackups) {
            $backupFiles = $group.Group

            # Get unique dates
            $uniqueDates = $backupFiles | Select-Object -Property DateString, Date -Unique |
                Sort-Object -Property Date -Descending

            # Keep only the specified number of most recent backup dates
            if ($uniqueDates.Count -gt $RetentionCount) {
                $datesToRemove = @($uniqueDates | Select-Object -Skip $RetentionCount)

                foreach ($dateInfo in $datesToRemove) {
                    $filesToRemove = @($backupFiles | Where-Object { $_.DateString -eq $dateInfo.DateString })

                    foreach ($file in $filesToRemove) {
                        if ($DryRun) {
                            Write-Log -Message "DRY RUN: Would remove old $BackupType backup: $($file.FullPath)" -Level Warning
                        } else {
                            try {
                                Write-Log -Message "Removing old $BackupType backup: $($file.FileName)" -Level Information
                                Remove-Item -Path $file.FullPath -Force
                            } catch {
                                Write-Log -Message "Failed to remove old $BackupType backup $($file.FileName): $_" -Level Error
                                $operationSuccess = $false
                            }
                        }
                    }
                }
            }
        }
    }
    catch {
        Write-Log -Message "Error during $BackupType backup cleanup: $_" -Level Error
        $operationSuccess = $false
    }

    return $operationSuccess
}

function Start-BackupRotation {
    <#
    .SYNOPSIS
        Implements a file backup rotation strategy with daily and weekly retention policies.

    .DESCRIPTION
        This function moves files from a source directory to daily and weekly backup folders
        with a structured naming convention that includes date information. It implements a
        backup rotation strategy with the following components:

        1. Files are moved from source to a daily backup folder with date suffix added to filenames
        2. Older daily backups are promoted to weekly backups based on configured day of week
        3. Retention policies are applied to remove backups exceeding the configured counts

        The function preserves filename structures while inserting date patterns before file extensions.
        All operations can be simulated using the -DryRun parameter.

    .PARAMETER Source
        The source directory containing files to be backed up and rotated.
        A trailing backslash will be added if missing.

    .PARAMETER Destination
        The base destination directory where daily and weekly backup folders will be created.
        A trailing backslash will be added if missing.

    .PARAMETER Options
        A configuration object containing the following properties:
        - number_of_daily_backups: Number of daily backups to retain (integer)
        - number_of_weekly_backups: Number of weekly backups to retain (integer)
        - day_of_week: Day of week (1-7) for promoting daily backups to weekly

    .PARAMETER DryRun
        When specified, simulates all operations without making actual changes.
        All operations will be logged with a "DRY RUN:" prefix.

    .EXAMPLE
        $options = @{
            number_of_daily_backups = 7
            number_of_weekly_backups = 4
            day_of_week = 1  # Monday
        }
        Start-BackupRotation -Source "E:\backup\continuous_cache\" -Destination "E:\backup\continuous\markdown-notes\" -Options $options

        Moves files from cache directory to daily backup folder with date pattern, promotes
        eligible Monday backups to weekly, and maintains 7 daily and 4 weekly backups.

    .OUTPUTS
        System.Boolean
        Returns $true if all operations completed successfully, $false if any errors occurred.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $true)]
        [object]$Options,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun = $false
    )

    # Track overall success
    $operationSuccess = $true

    # Ensure source and destination paths end with a backslash
    if (-not $Source.EndsWith('\')) { $Source = "$Source\" }
    if (-not $Destination.EndsWith('\')) { $Destination = "$Destination\" }

    # Get configuration values
    $numberOfDailyBackups = $Options.number_of_daily_backups
    $numberOfWeeklyBackups = $Options.number_of_weekly_backups
    $promotionDayOfWeek = $Options.day_of_week

    Write-Log -Message "Starting backup rotation with retention policy: $numberOfDailyBackups daily and $numberOfWeeklyBackups weekly backups" -Level Information
    Write-Log -Message "Weekly promotion day of week: $promotionDayOfWeek" -Level Information

    try {
        # Initialize directory structure
        $paths = Initialize-BackupDirectories -Destination $Destination -DryRun:$DryRun
        $dailyBackupPath = $paths.DailyPath
        $weeklyBackupPath = $paths.WeeklyPath

        # Move files from source to daily backup with date pattern
        $moveSuccess = Move-FilesToDailyBackup -Source $Source -DailyBackupPath $dailyBackupPath -DryRun:$DryRun
        $operationSuccess = $operationSuccess -and $moveSuccess

        # Promote eligible daily backups to weekly
        $promotionSuccess = Invoke-WeeklyBackupPromotion -DailyBackupPath $dailyBackupPath -WeeklyBackupPath $weeklyBackupPath -PromotionDayOfWeek $promotionDayOfWeek -DryRun:$DryRun
        $operationSuccess = $operationSuccess -and $promotionSuccess

        # Apply retention policy to daily backups
        $dailyCleanupSuccess = Remove-OldBackups -BackupPath $dailyBackupPath -RetentionCount $numberOfDailyBackups -FilePattern "-daily-(\d{8})-" -BackupType "daily" -DryRun:$DryRun
        $operationSuccess = $operationSuccess -and $dailyCleanupSuccess

        # Apply retention policy to weekly backups
        $weeklyCleanupSuccess = Remove-OldBackups -BackupPath $weeklyBackupPath -RetentionCount $numberOfWeeklyBackups -FilePattern "-weekly-(\d{8})-" -BackupType "weekly" -DryRun:$DryRun
        $operationSuccess = $operationSuccess -and $weeklyCleanupSuccess
    }
    catch {
        Write-Log -Message "Error during backup rotation: $_" -Level Error
        $operationSuccess = $false
    }

    if ($operationSuccess) {
        Write-Log -Message "Backup rotation completed successfully" -Level Information
    } else {
        Write-Log -Message "Backup rotation completed with errors" -Level Warning
    }

    return $operationSuccess
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
                "robocopy_7zip_multipar" {
                    # ============== Robocopy part =================
                    # Robocopy mirror target to a subdirectory in the cache directory
                    $robocopyOptions = $Handlers['robocopy'].options
                    $robocopyDestPath = Join-Path $destination.cache_path $Target.destination
                    Write-Log -Message "Backing up target: $($Target.description) to '$robocopyDestPath'" -Level Information

                    $success = Start-RobocopyBackup -Source $Target.source -Destination $robocopyDestPath -Options $robocopyOptions -DryRun:$DryRun

                    if ($success) {
                        Write-Log -Message "Robocopy backup successful: $($Target.description) from $($Target.source) to $($robocopyDestPath)" -Level Information
                    } elseif ($DryRun) {
                        Write-Log -Message "Dry run completed for: $($Target.description) from $($Target.source) to $($robocopyDestPath)" -Level Warning
                    } else {
                        Write-Log -Message "Robocopy backup failed: $($Target.description) from $($Target.source) to $($robocopyDestPath)" -Level Error
                    }

                    # ============== 7zip part =================
                    # Create 7z archives in the destination directory from the cache directory
                    $sevenZipOptions = $Handlers['7zip'].options
                    # Replace volume size placeholder if defined
                    if ($Handlers['7zip'].volume_size) {
                        $volumeSize = $Handlers['7zip'].volume_size
                        $sevenZipOptions = $sevenZipOptions -replace '{volume_size}', $volumeSize
                    }
                    $sevenZipSource = $robocopyDestPath
                    $sevenZipDestPath = $destination.cache_path
                    # clear all the files directly under the destination directory
                    Write-Log -Message "Clearing files in destination directory: $($sevenZipDestPath)" -Level Information
                    Get-ChildItem -Path $sevenZipDestPath -File -Depth 0 | ForEach-Object {
                        if ($DryRun) {
                            Write-Log -Message "DRY RUN: Would remove file: $($_.FullName)" -Level Warning
                        } else {
                            Write-Log -Message "Removing file: $($_.FullName)" -Level Verbose
                            Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
                            Write-Log -Message "Removed file: $($_.FullName)" -Level Verbose
                        }
                    }
                    Write-Log -Message "Backing up target: $($Target.description) to '$sevenZipDestPath'" -Level Information

                    $success = Start-7zipBackup -Source $sevenZipSource -Destination $sevenZipDestPath -Options $sevenZipOptions -DryRun:$DryRun

                    if ($success) {
                        Write-Log -Message "7zip backup successful: $($Target.description) from $($Target.source) to $($sevenZipDestPath)" -Level Information
                    } elseif ($DryRun) {
                        Write-Log -Message "Dry run completed for: $($Target.description) from $($Target.source) to $($sevenZipDestPath)" -Level Warning
                    } else {
                        Write-Log -Message "7zip backup failed: $($Target.description) from $($Target.source) to $($sevenZipDestPath)" -Level Error
                    }

                    # ============== par2 file part =================
                    # Create par2 files for the 7z archives
                    $par2Options = $Handlers['multipar'].options
                    # Replace redundancy rate placeholder if defined
                    if ($Handlers['multipar'].redundancy_rate_percent) {
                        $redundancyRate = $Handlers['multipar'].redundancy_rate_percent
                        $par2Options = $par2Options -replace '{redundancy_rate_percent}', $redundancyRate
                    }
                    $par2Source = $sevenZipDestPath
                    $par2DestPath = $destination.cache_path
                    Write-Log -Message "Backing up target: $($Target.description) to '$par2DestPath'" -Level Information

                    $success = Start-MultiparBackup -Source $par2Source -Destination $par2DestPath -Options $par2Options -DryRun:$DryRun

                    if ($success) {
                        Write-Log -Message "Multipar backup successful: $($Target.description) from $($Target.source) to $($par2DestPath)" -Level Information
                    } elseif ($DryRun) {
                        Write-Log -Message "Dry run completed for: $($Target.description) from $($Target.source) to $($par2DestPath)" -Level Warning
                    } else {
                        Write-Log -Message "Multipar backup failed: $($Target.description) from $($Target.source) to $($par2DestPath)" -Level Error
                    }

                    # ============== rotation part =================
                    # Based on the defined promotion strategy
                    $rotationOptions = $Target.strategy
                    $rotationSource = $destination.cache_path
                    $rotationDestPath = Join-Path $destination.path $Target.destination
                    Write-Log -Message "Backing up target: $($Target.description) to '$rotationDestPath'" -Level Information

                    $success = Start-BackupRotation -Source $rotationSource -Destination $rotationDestPath -Options $rotationOptions -DryRun:$DryRun

                    if ($success) {
                        Write-Log -Message "Backup rotation successful: $($Target.description) from $($Target.source) to $($rotationDestPath)" -Level Information
                    } elseif ($DryRun) {
                        Write-Log -Message "Dry run completed for: $($Target.description) from $($Target.source) to $($rotationDestPath)" -Level Warning
                    } else {
                        Write-Log -Message "Backup rotation failed: $($Target.description) from $($Target.source) to $($rotationDestPath)" -Level Error
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
    git clone --mirror $CloneUrl "`"$repoPath`""

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

    foreach ($target in $CodeRepoBackupConfig.targets) {
        Write-Log -Message "Start processing git bundle target: $($target.description)" -Level Information

        # Process all git bundle destinations
        $CodeRepoBackupConfig.destinations.git_bundles |
            Start-BackupByDestination -Target $target -Handlers $CodeRepoBackupConfig.handlers -DryRun:$DryRun
    }
    Write-Log -Message "Backup cycle completed for target: $($target.description)" -Level Information
}

function Start-ContinuousBackupJob {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$ContinuousBackupConfig,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun = $false
    )

    foreach ($target in $ContinuousBackupConfig.targets) {
        Write-Log -Message "Start processing continuous backup target: $($target.description)" -Level Information

        # Process all continuous backup destinations
        $ContinuousBackupConfig.destinations.local_drives |
            Start-BackupByDestination -Target $target -Handlers $ContinuousBackupConfig.handlers -DryRun:$DryRun
    }
    # After all individual targets are processed, mirror local drives to SMB shares
    $robocopyOptions = $ContinuousBackupConfig.handlers.robocopy.options

    # Process all SMB share destinations
    foreach ($smb_share in $ContinuousBackupConfig.destinations.smb_shares) {
        Write-Log -Message "Start processing SMB share target: $($smb_share.description)" -Level Information
        $robocopySource = $smb_share.source
        $robocopyDestPath = $smb_share.path
        Start-RobocopyBackup -Source $robocopySource -Destination $robocopyDestPath -Options $robocopyOptions -DryRun:$DryRun
        Write-Log -Message "Backup cycle completed for target: $($smb_share.description)" -Level Information
    }
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
Start-ContinuousBackupJob -ContinuousBackupConfig $config.continuous -DryRun:$DryRun
Start-StaticBackupJob -StaticBackupConfig $config.static -DryRun:$DryRun

Write-Log -Message "All backup jobs completed." -Level Information
#endregion Main
