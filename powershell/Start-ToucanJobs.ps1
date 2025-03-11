#region Initialize
$ErrorActionPreference = "Stop"
#endregion

#region Constants
Set-Variable -Name "TOUCAN_EXE_PATH_ENV_VAR" -Value "TOUCAN_EXE_PATH" -Option Constant
Set-Variable -Name "WAIT_INTERVAL_SECONDS" -Value 20 -Option Constant
#endregion

#region Functions
function Start-ToucanJob {
    param (
        [string] $jobName
    )

    if (-not (Test-Path "env:$TOUCAN_EXE_PATH_ENV_VAR")) {
        throw "Environment variable not found: $TOUCAN_EXE_PATH_ENV_VAR"
    }

    $toucanExePath = "$([Environment]::GetEnvironmentVariable($TOUCAN_EXE_PATH_ENV_VAR))"
    if (-not (Test-Path $toucanExePath)) {
        throw "Toucan executable not found at: $toucanExePath"
    }
    "Starting Toucan job: $jobName"
    $toucan = Get-ChildItem -Path $toucanExePath
    "Toucan executable found at: $($toucan.FullName)"
    $toucanWorkingDirectory = $toucan.Directory.FullName
    "Toucan working directory: $toucanWorkingDirectory"
    $arguments = "--job=$jobName --verbose"
    $process = Start-Process `
                -WorkingDirectory $toucanWorkingDirectory `
                -FilePath $toucan.FullName `
                -ArgumentList $arguments `
                -PassThru `
                -Wait
    "Process completed successfully: $($process.ExitCode -eq 0)"
    "Wait for $WAIT_INTERVAL_SECONDS seconds before proceeding to the next step..."
    Start-Sleep -Seconds $WAIT_INTERVAL_SECONDS    
}

function Enter-SleepMode {
    Start-Process -FilePath "shutdown.exe" -ArgumentList "/h" -NoNewWindow
}
#endregion

#region variables
[string[]] $jobNames = @(
    "mirror-obsidian-markdown-notes",
    "mirror-calibre-ebook-library"
)
#endregion

#region main
"Starting Toucan jobs: $($jobNames -join ', ')..."
foreach ($jobName in $jobNames) {
    Start-ToucanJob -jobName $jobName
}
"Toucan jobs completed successfully."
"Entering sleep mode..."
Enter-SleepMode
#endregion
