#Requires -Version 7.5
#Requires -Modules PSToml

function Get-BackupConfig {
    $configPath = "c:\Users\dingliu\Dev\github\dingliu\private-config-backup\backup.toml"
    $config = Import-PSToml -Path $configPath
    return $config
}

function Invoke-RobocopyMirror {
    param (
        [string]$Source,
        [string]$Destination,
        [array]$Options
    )

    # Create destination directory if it doesn't exist
    if (-not (Test-Path -Path $Destination)) {
        New-Item -Path $Destination -ItemType Directory -Force | Out-Null
    }

    # Build robocopy command
    $robocopyArgs = @($Source, $Destination) + $Options

    Write-Host "Mirroring $Source to $Destination..."
    & robocopy @robocopyArgs

    # Check robocopy exit code
    $exitCode = $LASTEXITCODE
    # Robocopy exit codes 0-7 are considered success
    if ($exitCode -ge 8) {
        Write-Error "Robocopy failed with exit code $exitCode"
        return $false
    }
    return $true
}

function Invoke-SevenZipCompression {
    param (
        [string]$Source,
        [string]$DestinationArchive,
        [array]$Options,
        [string]$VolumeSize
    )

    # Replace the volume size placeholder in options
    $processedOptions = $Options -replace "{7zip_volume_size}", $VolumeSize

    # Build 7-zip command
    $7zipPath = "C:\Program Files\7-Zip\7z.exe"
    $7zipArgs = @("a") + $processedOptions + @($DestinationArchive, "$Source\*")

    Write-Host "Compressing $Source to $DestinationArchive..."
    & $7zipPath @7zipArgs

    if ($LASTEXITCODE -ne 0) {
        Write-Error "7-zip compression failed with exit code $LASTEXITCODE"
        return $false
    }
    return $true
}

function Invoke-MultiParParity {
    param (
        [string]$SourceArchive,
        [int]$RedundancyRate
    )

    # Build MultiPar command
    $multiparPath = "C:\Program Files\MultiPar\par2j64.exe"
    $multiparArgs = @("c", "/rr$RedundancyRate", $SourceArchive)

    Write-Host "Creating parity data for $SourceArchive..."
    & $multiparPath @multiparArgs

    if ($LASTEXITCODE -ne 0) {
        Write-Error "MultiPar failed with exit code $LASTEXITCODE"
        return $false
    }
    return $true
}

function Manage-BackupRetention {
    param (
        [string]$BackupFolder,
        [string]$DestinationName,
        [int]$DailyLimit,
        [int]$WeeklyLimit,
        [int]$MonthlyLimit
    )

    Write-Host "Managing retention for $DestinationName backups..."

    # Get daily backups
    $dailyBackups = Get-ChildItem -Path $BackupFolder -Filter "$DestinationName-daily-*.7z" |
                    Sort-Object -Property LastWriteTime

    # Get weekly backups
    $weeklyBackups = Get-ChildItem -Path $BackupFolder -Filter "$DestinationName-weekly-*.7z" |
                     Sort-Object -Property LastWriteTime

    # Get monthly backups
    $monthlyBackups = Get-ChildItem -Path $BackupFolder -Filter "$DestinationName-monthly-*.7z" |
                      Sort-Object -Property LastWriteTime

    # Manage daily -> weekly promotion if needed
    while ($dailyBackups.Count -gt $DailyLimit) {
        $oldestDaily = $dailyBackups[0]
        $datePattern = $oldestDaily.Name -replace ".*-daily-(\d{8})-.*", '$1'
        $dayPattern = $oldestDaily.Name -replace ".*-(\w+)\.7z", '$1'

        $newName = $oldestDaily.Name -replace "-daily-", "-weekly-"
        $newPath = Join-Path -Path $BackupFolder -ChildPath $newName

        Write-Host "Promoting $($oldestDaily.Name) to weekly backup..."
        Move-Item -Path $oldestDaily.FullName -Destination $newPath

        # Also rename any associated par2 files
        Get-ChildItem -Path $BackupFolder -Filter "$($oldestDaily.BaseName)*.par2" | ForEach-Object {
            $newParName = $_.Name -replace "-daily-", "-weekly-"
            $newParPath = Join-Path -Path $BackupFolder -ChildPath $newParName
            Move-Item -Path $_.FullName -Destination $newParPath
        }

        # Refresh the lists
        $dailyBackups = Get-ChildItem -Path $BackupFolder -Filter "$DestinationName-daily-*.7z" |
                        Sort-Object -Property LastWriteTime
        $weeklyBackups = Get-ChildItem -Path $BackupFolder -Filter "$DestinationName-weekly-*.7z" |
                         Sort-Object -Property LastWriteTime
    }

    # Manage weekly -> monthly promotion if needed
    while ($weeklyBackups.Count -gt $WeeklyLimit) {
        $oldestWeekly = $weeklyBackups[0]

        $newName = $oldestWeekly.Name -replace "-weekly-", "-monthly-"
        $newPath = Join-Path -Path $BackupFolder -ChildPath $newName

        Write-Host "Promoting $($oldestWeekly.Name) to monthly backup..."
        Move-Item -Path $oldestWeekly.FullName -Destination $newPath

        # Also rename any associated par2 files
        Get-ChildItem -Path $BackupFolder -Filter "$($oldestWeekly.BaseName)*.par2" | ForEach-Object {
            $newParName = $_.Name -replace "-weekly-", "-monthly-"
            $newParPath = Join-Path -Path $BackupFolder -ChildPath $newParName
            Move-Item -Path $_.FullName -Destination $newParPath
        }

        # Refresh the lists
        $weeklyBackups = Get-ChildItem -Path $BackupFolder -Filter "$DestinationName-weekly-*.7z" |
                         Sort-Object -Property LastWriteTime
        $monthlyBackups = Get-ChildItem -Path $BackupFolder -Filter "$DestinationName-monthly-*.7z" |
                          Sort-Object -Property LastWriteTime
    }

    # Cleanup excess monthly backups if needed
    while ($monthlyBackups.Count -gt $MonthlyLimit) {
        $oldestMonthly = $monthlyBackups[0]

        Write-Host "Removing excess monthly backup $($oldestMonthly.Name)..."
        Remove-Item -Path $oldestMonthly.FullName -Force

        # Also remove any associated par2 files
        Get-ChildItem -Path $BackupFolder -Filter "$($oldestMonthly.BaseName)*.par2" | ForEach-Object {
            Remove-Item -Path $_.FullName -Force
        }

        # Refresh the list
        $monthlyBackups = Get-ChildItem -Path $BackupFolder -Filter "$DestinationName-monthly-*.7z" |
                          Sort-Object -Property LastWriteTime
    }
}

# Main backup workflow
function Start-ContinuousBackup {
    # Get configuration
    $config = Get-BackupConfig
    $continuousConfig = $config.continuous

    # Get the current date and time
    $currentDate = Get-Date
    $dateFormat = $currentDate.ToString("yyyyMMdd")
    $dayOfWeek = $currentDate.ToString("dddd").ToLower()

    # Create temporary working directory
    $tempWorkingDir = Join-Path -Path $env:TEMP -ChildPath "continuous-backup-$dateFormat"
    if (Test-Path -Path $tempWorkingDir) {
        Remove-Item -Path $tempWorkingDir -Recurse -Force
    }
    New-Item -Path $tempWorkingDir -ItemType Directory -Force | Out-Null

    # Get local drive destination
    $localDestination = $continuousConfig.destinations.local_drives[0].path

    # Get handler configurations
    $robocopyOptions = $continuousConfig.handlers.Robocopy.options
    $sevenZipOptions = $continuousConfig.handlers.7zip.options
    $sevenZipVolumeSize = $continuousConfig.handlers.7zip.volume_size
    $multiParRedundancyRate = $continuousConfig.handlers.MultiPar.redundancy_rate_percent

    # Get retention policy
    $dailyLimit = $continuousConfig.strategy.number_of_daily_backups
    $weeklyLimit = $continuousConfig.strategy.number_of_weekly_backups
    $monthlyLimit = $continuousConfig.strategy.number_of_monthly_backups

    # Process each target
    foreach ($target in $continuousConfig.targets) {
        $sourcePath = $target.source
        $destinationName = $target.destination
        $description = $target.description

        Write-Host "Processing backup target: $description" -ForegroundColor Cyan

        # Step 1: Create a local mirror using robocopy
        $mirrorDestination = Join-Path -Path $tempWorkingDir -ChildPath $destinationName
        $mirrorSuccess = Invoke-RobocopyMirror -Source $sourcePath -Destination $mirrorDestination -Options $robocopyOptions

        if (-not $mirrorSuccess) {
            Write-Error "Failed to mirror $sourcePath. Skipping this target."
            continue
        }

        # Step 2: Create the backup destination directory if it doesn't exist
        $backupDestDir = Join-Path -Path $localDestination -ChildPath $destinationName
        if (-not (Test-Path -Path $backupDestDir)) {
            New-Item -Path $backupDestDir -ItemType Directory -Force | Out-Null
        }

        # Step 3: Compress the mirrored folder with 7-zip
        $archiveName = "$destinationName-daily-$dateFormat-$dayOfWeek.7z"
        $archivePath = Join-Path -Path $backupDestDir -ChildPath $archiveName
        $compressionSuccess = Invoke-SevenZipCompression -Source $mirrorDestination -DestinationArchive $archivePath -Options $sevenZipOptions -VolumeSize $sevenZipVolumeSize

        if (-not $compressionSuccess) {
            Write-Error "Failed to compress $mirrorDestination. Skipping parity creation and retention management."
            continue
        }

        # Step 4: Create parity data
        $paritySuccess = Invoke-MultiParParity -SourceArchive $archivePath -RedundancyRate $multiParRedundancyRate

        if (-not $paritySuccess) {
            Write-Warning "Failed to create parity data for $archivePath. Continuing with retention management."
        }

        # Step 5: Apply retention policy
        Manage-BackupRetention -BackupFolder $backupDestDir -DestinationName $destinationName -DailyLimit $dailyLimit -WeeklyLimit $weeklyLimit -MonthlyLimit $monthlyLimit
    }

    # Clean up
    Write-Host "Cleaning up temporary files..." -ForegroundColor Cyan
    Remove-Item -Path $tempWorkingDir -Recurse -Force

    Write-Host "Continuous backup completed successfully." -ForegroundColor Green
}

# Execute the backup workflow
Start-ContinuousBackup
