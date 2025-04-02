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
