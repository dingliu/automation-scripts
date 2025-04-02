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

#endregion Functions
