<#
.SYNOPSIS
    Creates a new WSL2 instance from a root filesystem tarball with automated user setup and SSH configuration.

.DESCRIPTION
    This script automates the creation of a new WSL2 instance by importing a root filesystem tarball,
    configuring users, setting up SSH key authentication, and enabling KeeAgent support for SSH key management.

    The script performs the following operations:
    - Imports a WSL2 instance from a .tar or .tar.gz file
    - Creates a regular user account matching the current Windows username
    - Creates an 'ansible' user account for automation
    - Configures SSH key authentication for both users
    - Sets up SSH configuration sharing from Windows host
    - Installs and configures KeeAgent support for SSH key management
    - Installs required packages for the WSL2 instance

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

.PARAMETER AnsiblePublicKey
    SSH public key content for the ansible user. This key will be added to the ansible user's
    authorized_keys file for SSH authentication.

.EXAMPLE
    .\New-Wsl2Instance.ps1 -TargetParentDirectory "C:\WSL" -SourceRootFilesystem "C:\Downloads\fedora-39.tar.gz" -TargetInstanceName "fedora-dev" -AnsiblePublicKey "ssh-rsa AAAAB3Nza..."

    Creates a new WSL2 instance named 'fedora-dev' in C:\WSL\fedora-dev using the Fedora 39 root filesystem.

.NOTES
    Prerequisites:
    - Windows Subsystem for Linux (WSL2) must be installed and enabled
    - PowerShell 5.1 or later
    - Internet connection for downloading wsl-ssh-agent
    - KeePass with KeeAgent plugin (optional, for SSH key management)

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

    [Parameter(Mandatory = $true)]
    [string] $AnsiblePublicKey
)
# TODO:
# 4. validate user creation and other commands outcomes

#region Constants

    $ErrorActionPreference = 'Stop'
    $InformationPreference = 'Continue'

#endregion Constants

#region Functions

    function Invoke-Wsl2InstanceCreation {

        Write-Information "Importing WSL2 instance '$TargetInstanceName' from '$SourceRootFilesystem' to '$TargetParentDirectory'."
        wsl --import $TargetInstanceName `
            "$TargetParentDirectory\$TargetInstanceName" `
            $SourceRootFilesystem `
            --version 2

        Write-Information "Shutdown WSL."
        Invoke-WslShutdown

        Write-Information "Creating user '$env:USERNAME'."
        New-Wsl2User `
            -InstanceName $TargetInstanceName `
            -Username $env:USERNAME `
            -Shell "/bin/bash" `
            -PublicKey ""

        Write-Information "Set WSL2 instance configuration for '$TargetInstanceName'."
        Set-Wsl2InstanceConfiguration `
            -InstanceName $TargetInstanceName

        Write-Information "Shutting down WSL."
        Invoke-WslShutdown

        Write-Information "Creating user 'ansible'."
        New-Wsl2User `
            -InstanceName $TargetInstanceName `
            -Username "ansible" `
            -Shell "/bin/bash" `
            -PublicKey "$AnsiblePublicKey"

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
            [string] $Username,
            [string] $Shell = "/bin/bash",
            [string] $PublicKey = "<PUBLIC_KEY>"
        )
        Write-Information "Creating user '$Username' in WSL2 instance '$InstanceName'."
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User "root" `
            -Command "useradd -m -G wheel -s $Shell $Username"
        $userId = Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User "root" `
            -Command "id -u $Username"
        if ($userId -eq "") {
            Write-Error "Failed to create user '$Username' in WSL2 instance '$InstanceName'."
            exit 1
        }
        Write-Information "User '$Username' created with UID: $userId."
        Write-Information "Set sudoers for user '$Username'."
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User "root" `
            -Command "echo '$Username ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/${userId}-$Username"
        Write-Information "Setting up SSH keys for user '$Username'."
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User "root" `
            -Command "mkdir -p /home/$Username/.ssh && chmod 700 /home/$Username/.ssh && chown ${Username}:${Username} /home/$Username/.ssh"
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User "root" `
            -Command "echo '$PublicKey' > /home/$Username/.ssh/authorized_keys && chmod 600 /home/$Username/.ssh/authorized_keys && chown ${Username}:${Username} /home/$Username/.ssh/authorized_keys"
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
            -Command "dnf update -y && dnf install -y $PackageName"
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
            -User $env:USERNAME `
            -Command "rm -f ~/.ssh/config"

        Write-Information "Creating symbolic link of SSH config file in WSL2 instance '$InstanceName'."
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User $env:USERNAME `
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
        $wslSshAgentVersion = "1.6.8"
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

        Write-Information "Getting WSL SSH Agent forwarder filepath in WSL2 instance '$InstanceName'."
        $wslSshAgentForwrderWindowsPath = Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User $env:USERNAME `
            -Command "wslpath -w $wslSshAgentForwrderPath"
        write-Information "WSL SSH Agent forwarder filepath in Windows: $wslSshAgentForwrderWindowsPath"

        Write-Information "Creating directory for WSL SSH Agent forwarder in WSL2 instance '$InstanceName'."
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User $env:USERNAME `
            -Command "mkdir -p ~/bin && chmod 0755 ~/bin && chown ${env:USERNAME}:${env:USERNAME} ~/bin"

        write-Information "Copying WSL SSH Agent forwarder to WSL2 instance '$InstanceName'."
        Copy-Item `
            -Path $wslSshAgentForwrderFile `
            -Destination $wslSshAgentForwrderWindowsPath `
            -Force

        Write-Information "Setting permissions for WSL SSH Agent forwarder in WSL2 instance '$InstanceName'."
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User $env:USERNAME `
            -Command "chmod 0750 $wslSshAgentForwrderPath && chown ${env:USERNAME}:${env:USERNAME} $wslSshAgentForwrderPath"

        Write-Information "Creating socket file for WSL SSH Agent forwarder in WSL2 instance '$InstanceName'."
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User $env:USERNAME `
            -Command "touch ~/.ssh/agent.sock && chmod 0600 ~/.ssh/agent.sock && chown ${env:USERNAME}:${env:USERNAME} ~/.ssh/agent.sock"

        Write-Information "Updating .bashrc to start WSL SSH Agent forwarder in WSL2 instance '$InstanceName'."
        Invoke-BashCommandInWsl2 `
            -InstanceName $InstanceName `
            -User $env:USERNAME `
            -Command "echo '[[ ! -f ~/bin/wsl-ssh-agent-forwarder ]] || source ~/bin/wsl-ssh-agent-forwarder' >> ~/.bashrc"
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
