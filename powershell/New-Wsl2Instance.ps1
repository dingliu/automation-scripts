<#
.SYNOPSIS
    Creates a new WSL2 instance from a root filesystem tarball with config-driven user setup and SSH configuration.

.DESCRIPTION
    This script automates the creation of a new WSL2 instance by importing a root filesystem tarball,
    creating users from a JSON configuration file (linux_users.json), setting up SSH key authentication,
    and enabling KeeAgent support for SSH key management.

    The script performs the following operations:
    - Imports a WSL2 instance from a .tar or .tar.gz file
    - Reads user definitions from a JSON config file (linux_users.json)
    - Creates the admin user (regular.admin) with explicit UID/GID, groups, shell, and SSH keys
    - Creates service users that have SSH keys defined (service users without keys are skipped)
    - Configures sudoers based on isSudoer and sudoWithoutPassword flags
    - Sets up SSH configuration sharing from Windows host for the admin user
    - Installs and configures KeeAgent support for SSH key management
    - Installs required packages (shell packages, python3-libdnf5)

.PARAMETER TargetParentDirectory
    The parent directory where the new WSL2 instance will be created. Must be an existing directory.
    A subdirectory with the instance name will be created within this path.

.PARAMETER SourceRootFilesystem
    Path to the root filesystem tarball (.tar or .tar.gz) that will be used to create the WSL2 instance.
    The file must exist and have a .tar or .tar.gz extension.

.PARAMETER TargetInstanceName
    Name for the new WSL2 instance. Must follow WSL naming conventions:
    - 1-63 characters long
    - Contains only letters (A-Z, a-z), digits (0-9), and hyphens (-)
    - Cannot start or end with a hyphen
    - Cannot contain consecutive hyphens
    - Must not conflict with existing WSL distribution names

.PARAMETER UsersConfigFile
    Path to the JSON configuration file defining Linux users. Must have a .json extension.
    If not specified, defaults to <repo_root>/../private-config-backup/common/linux_users.json.

    The JSON file must contain a 'regular.admin' entry with: username, uid, gid, shell, sshKeys.
    The admin username must match the current Windows username ($env:USERNAME).
    Service users under the 'service' key are created only if they have non-empty sshKeys.

.EXAMPLE
    .\New-Wsl2Instance.ps1 -TargetParentDirectory "C:\WSL" -SourceRootFilesystem "C:\Downloads\fedora-39.tar.gz" -TargetInstanceName "fedora-dev"

    Creates a new WSL2 instance using the default linux_users.json from private-config-backup.

.EXAMPLE
    .\New-Wsl2Instance.ps1 -TargetParentDirectory "C:\WSL" -SourceRootFilesystem "C:\Downloads\fedora-39.tar.gz" -TargetInstanceName "fedora-dev" -UsersConfigFile "C:\config\linux_users.json"

    Creates a new WSL2 instance using a custom users configuration file.

.NOTES
    Prerequisites:
    - Windows Subsystem for Linux (WSL2) must be installed and enabled
    - PowerShell 5.1 or later
    - Internet connection for downloading wsl-ssh-agent
    - KeePass with KeeAgent plugin (optional, for SSH key management)
    - The admin username in the config file must match the current Windows username

    The script requires administrative privileges for some operations and will:
    - Disable the Windows SSH agent service

.LINK
    https://docs.microsoft.com/en-us/windows/wsl/
    https://github.com/rupor-github/wsl-ssh-agent
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateScript({
        if (Test-Path $_ -PathType Container) {
            $true
        } else {
            throw "The path '$_' does not exist or is not a directory."
        }
    })]
    [string] $TargetParentDirectory,

    [Parameter(Mandatory = $true)]
    [ValidateScript({
        if (-not (Test-Path $_ -PathType Leaf)) {
            throw "The file '$_' does not exist."
        }
        if ($_ -notmatch '\.(tar|tar\.gz)$') {
            throw "The file '$_' must have a .tar or .tar.gz extension."
        }
        $true
    })]
    [string] $SourceRootFilesystem,

    [Parameter(Mandatory = $true)]
    [ValidateScript({
        if ($_.Length -lt 1 -or $_.Length -gt 63) {
            throw "The instance name '$_' must be between 1 and 63 characters long."
        }
        if ($_ -notmatch '^[A-Za-z0-9-]+$') {
            throw "The instance name '$_' can only contain letters (A-Z, a-z), digits (0-9), and hyphens (-)."
        }
        if ($_.StartsWith('-') -or $_.EndsWith('-')) {
            throw "The instance name '$_' cannot start or end with a hyphen."
        }
        if ($_ -match '--') {
            throw "The instance name '$_' cannot contain consecutive hyphens."
        }
        $existingDistros = wsl --list --quiet | Where-Object { $_.Trim() -ne '' }
        if ($existingDistros -contains $_) {
            throw "A WSL distribution named '$_' already exists. Please choose a different name."
        }
        $true
    })]
    [string] $TargetInstanceName,

    [Parameter(Mandatory = $false)]
    [ValidateScript({
        if (-not (Test-Path $_ -PathType Leaf)) {
            throw "The file '$_' does not exist."
        }
        if ($_ -notmatch '\.json$') {
            throw "The file '$_' must have a .json extension."
        }
        $true
    })]
    [string] $UsersConfigFile
)
#region Constants

    $ErrorActionPreference = 'Stop'
    $InformationPreference = 'Continue'

#endregion Constants

#region Config Loading

    if (-not $UsersConfigFile) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
        $repoRoot = Split-Path -Parent $scriptDir
        $UsersConfigFile = Join-Path $repoRoot "..\private-config-backup\common\linux_users.json"
    }
    $UsersConfigFile = (Resolve-Path $UsersConfigFile).Path

    $usersConfig = Get-Content -Path $UsersConfigFile -Raw | ConvertFrom-Json

    if (-not $usersConfig.regular -or -not $usersConfig.regular.admin) {
        throw "Users config file '$UsersConfigFile' must contain a 'regular.admin' entry."
    }

    $adminUser = $usersConfig.regular.admin
    $requiredFields = @("username", "uid", "gid", "shell", "sshKeys")
    foreach ($field in $requiredFields) {
        if ($null -eq $adminUser.$field) {
            throw "Admin user in '$UsersConfigFile' is missing required field '$field'."
        }
    }

    if ($adminUser.username -ne $env:USERNAME) {
        throw "Admin username '$($adminUser.username)' in '$UsersConfigFile' does not match the current Windows username '$env:USERNAME'."
    }

    $serviceUsers = @()
    if ($usersConfig.service) {
        $usersConfig.service.PSObject.Properties | ForEach-Object {
            $user = $_.Value
            if ($user.sshKeys -and $user.sshKeys.Count -gt 0) {
                $serviceUsers += $user
            }
        }
    }

    Write-Information "Loaded users config from '$UsersConfigFile': admin='$($adminUser.username)', service users=$(($serviceUsers | ForEach-Object { $_.username }) -join ', ')"

#endregion Config Loading

#region Functions

    function Invoke-Wsl2InstanceCreation {

        Write-Information "Importing WSL2 instance '$TargetInstanceName' from '$SourceRootFilesystem' to '$TargetParentDirectory'."
        wsl --import $TargetInstanceName `
            "$TargetParentDirectory\$TargetInstanceName" `
            $SourceRootFilesystem `
            --version 2

        Write-Information "Shutdown WSL."
        Invoke-WslShutdown

        Write-Information "Updating system packages for WSL2 instance '$TargetInstanceName'."
        Invoke-Wsl2SystemUpdate `
            -InstanceName $TargetInstanceName

        $adminShellPkg = Get-ShellPackageName -Shell $adminUser.shell
        if ($adminShellPkg) {
            Write-Information "Installing shell package '$adminShellPkg' for admin user."
            Invoke-Wsl2PackageInstallation `
                -InstanceName $TargetInstanceName `
                -PackageName $adminShellPkg
        }

        Write-Information "Creating admin user '$($adminUser.username)'."
        New-Wsl2User `
            -InstanceName $TargetInstanceName `
            -UserConfig $adminUser

        Write-Information "Set WSL2 instance configuration for '$TargetInstanceName'."
        Set-Wsl2InstanceConfiguration `
            -InstanceName $TargetInstanceName `
            -Username $adminUser.username

        Write-Information "Shutting down WSL."
        Invoke-WslShutdown

        foreach ($serviceUser in $serviceUsers) {
            Write-Information "Creating service user '$($serviceUser.username)'."
            New-Wsl2User `
                -InstanceName $TargetInstanceName `
                -UserConfig $serviceUser
        }

        Write-Information "Installing packages for WSL2 instance '$TargetInstanceName'."
        Invoke-Wsl2PackageInstallation `
            -InstanceName $TargetInstanceName `
            -PackageName "python3-libdnf5"

        Write-Information "Setting SSH configuration sharing for WSL2 instance '$TargetInstanceName'."
        Set-SshConfigSharing `
            -InstanceName $TargetInstanceName

        Write-Information "Setting up KeeAgent support for WSL2 instance '$TargetInstanceName'."
        Set-KeeAgentSupport `
            -InstanceName $TargetInstanceName
    }

    function Get-ShellPackageName {
        param (
            [string] $Shell
        )
        switch ($Shell) {
            "/bin/zsh"  { return "zsh" }
            "/bin/fish" { return "fish" }
            "/bin/bash" { return $null }
            default     { return $null }
        }
    }

    function Get-ShellRcFile {
        param (
            [string] $Shell
        )
        switch ($Shell) {
            "/bin/zsh"  { return "~/.zshrc" }
            "/bin/bash" { return "~/.bashrc" }
            default     { return "~/.bashrc" }
        }
    }

    function Invoke-BashCommandInWsl2 {
        param (
            [string] $InstanceName,
            [string] $User,
            [string] $Command
        )
        Write-Debug "Executing command in WSL2 instance '$InstanceName' as user '$User': $Command"
        wsl -d $InstanceName --user $User --exec bash -c $Command
    }

    function New-Wsl2User {
        [CmdletBinding()]
        param (
            [string] $InstanceName,
            [PSCustomObject] $UserConfig
        )
        $username = $UserConfig.username
        $uid = $UserConfig.uid
        $gid = $UserConfig.gid
        $shell = $UserConfig.shell
        $otherGroups = if ($UserConfig.otherGroups) { $UserConfig.otherGroups -join ',' } else { '' }
        $sshKeys = $UserConfig.sshKeys
        $isSudoer = $UserConfig.isSudoer
        $sudoWithoutPassword = $UserConfig.sudoWithoutPassword

        Write-Information "Creating group '$username' (GID: $gid) in WSL2 instance '$InstanceName'."
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User "root" `
            -Command "groupadd -g $gid $username"

        $useraddCmd = "useradd -m -u $uid -g $gid -s $shell $username"
        if ($otherGroups) {
            $useraddCmd = "useradd -m -u $uid -g $gid -G $otherGroups -s $shell $username"
        }
        Write-Information "Creating user '$username' (UID: $uid) in WSL2 instance '$InstanceName'."
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User "root" `
            -Command $useraddCmd

        $verifiedUid = Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User "root" `
            -Command "id -u $username"
        if ($verifiedUid -eq "") {
            Write-Error "Failed to create user '$username' in WSL2 instance '$InstanceName'."
            exit 1
        }
        Write-Information "User '$username' created with UID: $verifiedUid."

        if ($isSudoer) {
            if ($sudoWithoutPassword) {
                $sudoersEntry = "$username ALL=(ALL) NOPASSWD: ALL"
            } else {
                $sudoersEntry = "$username ALL=(ALL) ALL"
            }
            Write-Information "Set sudoers for user '$username'."
            Invoke-BashCommandInWsl2 `
                -InstanceName $InstanceName `
                -User "root" `
                -Command "echo '$sudoersEntry' > /etc/sudoers.d/${uid}-$username && chmod 0440 /etc/sudoers.d/${uid}-$username"
        }

        Write-Information "Setting up SSH directory for user '$username'."
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User "root" `
            -Command "mkdir -p /home/$username/.ssh && chmod 700 /home/$username/.ssh && chown ${username}:${username} /home/$username/.ssh"

        if ($sshKeys -and $sshKeys.Count -gt 0) {
            $quotedKeys = ($sshKeys | ForEach-Object { "'$_'" }) -join ' '
            Write-Information "Writing $($sshKeys.Count) SSH key(s) for user '$username'."
            Invoke-BashCommandInWsl2 `
                -InstanceName $InstanceName `
                -User "root" `
                -Command "printf '%s\n' $quotedKeys > /home/$username/.ssh/authorized_keys && chmod 600 /home/$username/.ssh/authorized_keys && chown ${username}:${username} /home/$username/.ssh/authorized_keys"
        }
    }

    function Invoke-Wsl2SystemUpdate {
        param (
            [string] $InstanceName
        )
        Write-Information "Updating system packages in WSL2 instance '$InstanceName'."
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User "root" `
            -Command "dnf update -y"
    }

    function Invoke-Wsl2PackageInstallation {
        param (
            [string] $InstanceName,
            [string] $PackageName
        )
        Write-Information "Installing package '$PackageName' in WSL2 instance '$InstanceName'."
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User "root" `
            -Command "dnf install -y $PackageName"
    }

    function Set-Wsl2InstanceConfiguration {
        param (
            [string] $InstanceName,
            [string] $Username
        )
        $wslConfPath = "/etc/wsl.conf"
        $wslConfTemplatePath = "wsl.conf.tpl"

        Write-Information "Getting WSL config file path in WSL2 instance '$InstanceName'."
        $wslConfWindowsPath = Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User "root" `
            -Command "wslpath -w $wslConfPath"
        Write-Information "WSL config file path in Windows: $wslConfWindowsPath"

        Write-Information "Reading wsl.conf template and replacing username token."
        $wslConfContent = Get-Content -Path $wslConfTemplatePath -Raw
        $wslConfContent = $wslConfContent -replace 'default={{USERNAME}}', "default=$Username"

        Write-Information "Writing updated wsl.conf to temporary location."
        $tempWslConf = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $tempWslConf -Value $wslConfContent -NoNewline

        Write-Information "Copying wsl.conf to WSL2 instance '$InstanceName'."
        Copy-Item `
            -Path $tempWslConf `
            -Destination $wslConfWindowsPath `
            -Force

        Write-Information "Cleaning up temporary file."
        Remove-Item -Path $tempWslConf -Force

        Write-Information "Setting permissions for WSL config file in WSL2 instance '$InstanceName'."
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User "root" `
            -Command "chmod 644 $wslConfPath && chown root:root $wslConfPath"
    }

    function Invoke-WslShutdown {
        wsl --shutdown
        Write-Information "WSL has been shut down. Sleeping for 8 seconds to ensure all processes are terminated."
        Start-Sleep -Seconds 8
    }

    function Set-SshConfigSharing {
        param (
            [string] $InstanceName
        )
        Set-WSLENV -Value "USERPROFILE/p:"

        Write-Information "Removing existing SSH configuration in WSL2 instance '$InstanceName'."
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User $adminUser.username `
            -Command "rm -f ~/.ssh/config"

        Write-Information "Creating symbolic link of SSH config file in WSL2 instance '$InstanceName'."
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User $adminUser.username `
            -Command "if [[ -f `$USERPROFILE/.ssh/config ]]; then ln -s `$USERPROFILE/.ssh/config ~/.ssh/config; fi"
    }

    function Set-WSLENV {
        param (
            [string] $Value
        )
        $env:WSLENV = $Value

        if ( -not [string]::IsNullOrEmpty($env:WT_SESSION) -and
            -not [string]::IsNullOrEmpty($env:WT_PROFILE_ID) ) {
            $env:WSLENV += "WT_SESSION:WT_PROFILE_ID:$Value"
        }
    }

    function Set-KeeAgentSupport {
        param (
            [string] $InstanceName
        )
        Write-Information "Setting up KeeAgent support in WSL2 instance '$InstanceName'."
        Set-SshAgentServiceDisabled
        Invoke-WslSshAgentDownload
        Set-WslSshAgentSymbolicLink -InstanceName $InstanceName
        Install-WslSshAgentForwarderRequiredPackages -InstanceName $InstanceName
        Set-WslSshAgentForwarder -InstanceName $InstanceName
    }

    function Set-SshAgentServiceDisabled {
        Write-Information "Setting SSH agent service to disabled in Windows host."
        $sshAgentService = Get-Service -Name "ssh-agent" -ErrorAction SilentlyContinue
        if ($null -ne $sshAgentService) {
            Set-Service -Name "ssh-agent" -StartupType Disabled
            Write-Information "SSH agent service has been set to disabled."
        } else {
            Write-Information "SSH agent service is not installed on the system."
        }
        Write-Information "Ensure that the SSH agent service is not running."
        if ($sshAgentService -and $sshAgentService.Status -eq 'Running') {
            Stop-Service -Name "ssh-agent" -Force
            Write-Information "SSH agent service has been stopped."
        } else {
            Write-Information "SSH agent service is not running."
        }
    }

    function Invoke-WslSshAgentDownload {
        $wslSshAgentVersion = "1.6.9"
        $wslSshAgentArchiveName = "wsl-ssh-agent.zip"
        Write-Information "Downloading wsl-ssh-agent version $wslSshAgentVersion."
        $wslSshAgentUrl = "https://github.com/rupor-github/wsl-ssh-agent/releases/download/v${wslSshAgentVersion}/wsl-ssh-agent.zip"
        Invoke-WebRequest "$wslSshAgentUrl" -OutFile $wslSshAgentArchiveName

        $wslSshAgentExtractDir = "$env:USERPROFILE/wsl-keeagent"
        if (-not (Test-Path -Path $wslSshAgentExtractDir)) {
            Write-Information "Creating directory for wsl-ssh-agent: $wslSshAgentExtractDir"
            New-Item -ItemType Directory -Path $wslSshAgentExtractDir -Force | Out-Null
        }
        Write-Information "Extracting wsl-ssh-agent to $wslSshAgentExtractDir."
        Expand-Archive -Path $wslSshAgentArchiveName -DestinationPath $wslSshAgentExtractDir -Force

        Remove-Item -Path $wslSshAgentArchiveName -Force
    }

    function Set-WslSshAgentSymbolicLink {
        param (
            [string] $InstanceName
        )
        Write-Information "Set WSLENV for SSH agent in WSL2 instance '$InstanceName'."
        Set-WSLENV -Value "USERPROFILE/p:"

        Write-Information "Make npiperelay executable in WSL2 instance '$InstanceName'."
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User "root" `
            -Command "chmod +x `$USERPROFILE/wsl-keeagent/npiperelay.exe"

        Write-Information "Creating symbolic link for npiperelay in WSL2 instance '$InstanceName'."
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User "root" `
            -Command "ln -s `$USERPROFILE/wsl-keeagent/npiperelay.exe /usr/local/bin/npiperelay.exe"
    }

    function Install-WslSshAgentForwarderRequiredPackages {
        param (
            [string] $InstanceName
        )
        Write-Information "Installing required packages for WSL SSH Agent forwarder in WSL2 instance '$InstanceName'."
        $requiredPackages = @("socat", "iproute")
        $packageList = $requiredPackages -join " "
        Invoke-Wsl2PackageInstallation `
            -InstanceName $InstanceName `
            -PackageName $packageList
    }

    function Set-WslSshAgentForwarder {
        param (
            [string] $InstanceName
        )
        $wslSshAgentForwrderFile = "wsl-ssh-agent-forwarder"
        $wslSshAgentForwrderPath = "~/bin/$wslSshAgentForwrderFile"
        $wslUsername = $adminUser.username

        Write-Information "Getting WSL SSH Agent forwarder filepath in WSL2 instance '$InstanceName'."
        $wslSshAgentForwrderWindowsPath = Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User $wslUsername `
            -Command "wslpath -w $wslSshAgentForwrderPath"
        Write-Information "WSL SSH Agent forwarder filepath in Windows: $wslSshAgentForwrderWindowsPath"

        Write-Information "Creating directory for WSL SSH Agent forwarder in WSL2 instance '$InstanceName'."
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User $wslUsername `
            -Command "mkdir -p ~/bin && chmod 0755 ~/bin && chown ${wslUsername}:${wslUsername} ~/bin"

        Write-Information "Copying WSL SSH Agent forwarder to WSL2 instance '$InstanceName'."
        Copy-Item `
            -Path $wslSshAgentForwrderFile `
            -Destination $wslSshAgentForwrderWindowsPath `
            -Force

        Write-Information "Setting permissions for WSL SSH Agent forwarder in WSL2 instance '$InstanceName'."
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User $wslUsername `
            -Command "chmod 0750 $wslSshAgentForwrderPath && chown ${wslUsername}:${wslUsername} $wslSshAgentForwrderPath"

        Write-Information "Creating socket file for WSL SSH Agent forwarder in WSL2 instance '$InstanceName'."
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User $wslUsername `
            -Command "touch ~/.ssh/agent.sock && chmod 0600 ~/.ssh/agent.sock && chown ${wslUsername}:${wslUsername} ~/.ssh/agent.sock"

        $shellRcFile = Get-ShellRcFile -Shell $adminUser.shell
        Write-Information "Updating '$shellRcFile' to start WSL SSH Agent forwarder in WSL2 instance '$InstanceName'."
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User $wslUsername `
            -Command "echo '[[ ! -f ~/bin/wsl-ssh-agent-forwarder ]] || source ~/bin/wsl-ssh-agent-forwarder' >> $shellRcFile"
    }

#endregion Functions

#region Main

    try {
        Write-Information "Starting WSL2 instance creation process."
        Invoke-Wsl2InstanceCreation
    }
    catch {
        Write-Error "An error occurred during WSL2 instance creation: $_"
        exit 1
    }
    finally {
        Write-Information "WSL2 instance creation process completed."
    }

#endregion Main
