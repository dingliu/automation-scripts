[CmdletBinding()]
param (
)

#region Initialization
$ErrorActionPreference = 'Stop'
#endregion


#region constants
Set-Variable -Name "DESKTOP_PC_USERNAME_ENV_VAR" -Value 'DESKTOP_PC_USERNAME' -Option Constant
Set-Variable -Name "DESKTOP_PC_PASSWORD_ENV_VAR" -Value 'DESKTOP_PC_PASSWORD' -Option Constant
Set-Variable -Name "DESKTOP_PC_HOSTNAME_ENV_VAR" -Value 'DESKTOP_PC_HOSTNAME' -Option Constant
Set-Variable -Name "MOONLIGHT_EXE_PATH_ENV_VAR" -Value 'MOONLIGHT_EXE_PATH' -Option Constant
Set-Variable -Name "SUNSHINE_SERVICE_NAME" -Value 'sunshinesvc' -Option Constant
#endregion


#region functions
function Test-EnvironmentVariable {
    param (
        # Name of the environment variable to test
        [Parameter(Mandatory)]
        [string]$VariableName
    )
    Write-Verbose "Testing environment variable '$VariableName'"
    if (-not (Test-Path env:$VariableName)) {
        throw "Environment variable '$VariableName' not found"
    }
}

function Test-RequiredEnvironmentVariables {
    param (
        # List of environment variable names to test
        [Parameter(Mandatory)]
        [string[]]$VariableNames
    )
    Write-Verbose "Testing required environment variables: [$VariableNames]"
    foreach ($variableName in $VariableNames) {
        Test-EnvironmentVariable -VariableName $variableName
        Write-Verbose "Environment variable '$variableName' found"
    }
}

function Get-RemoteCredential {
    param (
        # Username for the remote machine
        [Parameter(Mandatory)]
        [string]$Username,
        # Password for the remote machine
        [Parameter(Mandatory)]
        [securestring]$Password
    )
    Write-Verbose "Creating remote credential for user '$Username'"
    return New-Object System.Management.Automation.PSCredential($Username, $Password)
}

function Invoke-RemoteSunshine {
    param (
        # Remote session to use
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )
    $sunshineProcess = Invoke-Command -Session $Session `
        -Verbose `
        -ArgumentList @($SUNSHINE_SERVICE_NAME) `
        -ScriptBlock {
            param(
                [string]$SunshineServiceName
            )
            Write-Verbose "Checking if '$SunshineServiceName' process is running"
            $sunshineProcess = Get-Process -Name $SunshineServiceName -ErrorAction SilentlyContinue
            if ($sunshineProcess) {
                Write-Verbose "Sunshine is running"
                return $sunshineProcess
            }
            else {
                Write-Verbose "Sunshine is not running"
                $sunshineProcess = Start-Process `
                    -FilePath 'C:\Program Files\Sunshine\sunshine.exe' `
                    -ArgumentList "--shortcut" `
                    -PassThru
                return $sunshineProcess
            }
        }

    if ($sunshineProcess) {
        Write-Verbose "Sunshine is running on remote machine"
        return $sunshineProcess
    }
    else {
        throw "Failed to start Sunshine on remote machine"
    }
}

function Invoke-Moonlight {
    param(
        [Parameter(Mandatory)]
        [string]$RemoteHost
    )
    Write-Verbose "Invoking Moonlight targeting host '$RemoteHost'"
    try {
        $MOONLIGHT_EXE_PATH = [Environment]::GetEnvironmentVariable($MOONLIGHT_EXE_PATH_ENV_VAR)
        if (-not (Test-Path $MOONLIGHT_EXE_PATH)) {
            throw "Moonlight executable not found at '$MOONLIGHT_EXE_PATH'"
        }
        $moonlight = Get-ChildItem -Path $MOONLIGHT_EXE_PATH

        $moonlightWorkingDir = $moonlight.Directory.FullName
        Start-Process `
            -FilePath $moonlight.FullName `
            -WorkingDirectory $moonlightWorkingDir `
            -ArgumentList "stream $RemoteHost Desktop --1440 --quit-after" `
            -PassThru `
            -Wait | Out-Null
    }
    catch {
        throw "Failed to start Moonlight: $_"
    }
}

function Stop-RemoteSunshine {
    param (
        # Remote session to use
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )
    Write-Verbose "Stopping Sunshine process on remote machine"
    Invoke-Command -Session $Session `
        -ArgumentList @($SUNSHINE_SERVICE_NAME) `
        -ScriptBlock {
            param(
                [string]$SunshineServiceName
            )
            try {
                Get-Process -Name $SunshineServiceName | Stop-Process -Force
            }
            catch {
                throw "Failed to stop Sunshine process: $_"
            }
        }
}
#endregion


#region main
Write-Verbose "Testing required environment variables"
Test-RequiredEnvironmentVariables -VariableNames @(
    $DESKTOP_PC_USERNAME_ENV_VAR,
    $DESKTOP_PC_PASSWORD_ENV_VAR,
    $DESKTOP_PC_HOSTNAME_ENV_VAR,
    $MOONLIGHT_EXE_PATH_ENV_VAR
)

Write-Verbose "Getting remote credential"
$remoteCredential = Get-RemoteCredential `
    -Username "$([Environment]::GetEnvironmentVariable($DESKTOP_PC_USERNAME_ENV_VAR))" `
    -Password $("$([Environment]::GetEnvironmentVariable($DESKTOP_PC_PASSWORD_ENV_VAR))" | ConvertTo-SecureString -AsPlainText -Force)
Write-Verbose "Remote credential created: $remoteCredential"

try {
    $remoteHost = [Environment]::GetEnvironmentVariable($DESKTOP_PC_HOSTNAME_ENV_VAR)
    Write-Verbose "Creating remote session targeting host '$remoteHost'"
    $session = New-PSSession `
                -ComputerName $remoteHost `
                -Credential $remoteCredential
    Write-Verbose "Remote session created: $session"

    Write-Verbose "Invoking Sunshine in remote session"
    $sunshineProcess = Invoke-RemoteSunshine -Session $session

    Write-Verbose "Invoking Moonlight"
    Invoke-Moonlight -RemoteHost $remoteHost
    Write-Verbose "Moonlight completed"

    Write-Verbose "Stopping Sunshine process on remote machine"
    Stop-RemoteSunshine -Session $session
    Write-Verbose "Sunshine process stopped"
}
catch {
    throw "Error: $_"
}
finally {
    if ($session) {
        Write-Verbose "Removing remote session"
        Remove-PSSession -Session $session
        Write-Verbose "Remote session removed"
    }
}

#endregion
