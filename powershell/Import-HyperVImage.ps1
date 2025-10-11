<#
.SYNOPSIS
    Imports a Hyper-V virtual machine from an exported image directory.

.DESCRIPTION
    This script imports a Hyper-V virtual machine from an exported VM image directory structure.
    It validates the source image directory, destination directory, and VM name before import.
    Optionally configures a static MAC address and connects the VM to a specified virtual switch.
    For Linux VMs, it can also configure static IPv4 address using SSH.

    The script expects the source image directory to contain the standard Hyper-V export structure:
    - Virtual Hard Disks\ (containing VHD/VHDX files)
    - Virtual Machines\ (containing .vmcx configuration file)

.PARAMETER SourceImageDirectory
    The path to the directory containing the exported Hyper-V VM image.
    Must contain 'Virtual Hard Disks' and 'Virtual Machines' subdirectories.

.PARAMETER DestinationDirectory
    The directory where the imported VM will be stored.
    The script will create a subdirectory with the VM name inside this directory.

.PARAMETER VirtualMachineName
    The name for the imported virtual machine.
    Must not conflict with existing VM names and cannot contain invalid characters (< > : " / \ | ? *).
    Maximum length is 100 characters.

.PARAMETER StaticMacAddress
    Optional. A static MAC address to assign to the VM's network adapter.
    Accepts formats: 00-15-5D-00-04-08, 00:15:5D:00:04:08, 00 15 5D 00 04 08, or 00155D000408.

.PARAMETER VirtualSwitchName
    Optional. The name of the virtual switch to connect the VM's network adapter to.
    The switch must exist on the Hyper-V host.

.PARAMETER IPv4AddressInfo
    Optional. Hashtable containing IPv4 configuration for Linux VMs.
    Must include three keys: 'address' (IP/CIDR), 'gateway' (IP), and 'dns' (comma-separated IPs).
    Example: @{address='192.168.1.100/24'; gateway='192.168.1.1'; dns='8.8.8.8,8.8.4.4'}

.EXAMPLE
    .\Import-HyperVImage.ps1 -SourceImageDirectory "C:\VM-Exports\MyVM" -DestinationDirectory "C:\VMs" -VirtualMachineName "ImportedVM"

    Imports a VM from the exported image in C:\VM-Exports\MyVM to C:\VMs\ImportedVM.

.EXAMPLE
    .\Import-HyperVImage.ps1 -SourceImageDirectory "C:\VM-Exports\MyVM" -DestinationDirectory "C:\VMs" -VirtualMachineName "WebServer" -StaticMacAddress "00-15-5D-00-04-08" -VirtualSwitchName "External Network"

    Imports a VM with a static MAC address and connects it to the "External Network" virtual switch.

.EXAMPLE
    $ipConfig = @{address='192.168.1.100/24'; gateway='192.168.1.1'; dns='8.8.8.8,8.8.4.4'}
    .\Import-HyperVImage.ps1 -SourceImageDirectory "C:\VM-Exports\LinuxVM" -DestinationDirectory "C:\VMs" -VirtualMachineName "LinuxServer" -IPv4AddressInfo $ipConfig

    Imports a Linux VM and configures static IP address via SSH.

.NOTES
    Requires: PowerShell version 5.1 or higher
    Requires: Hyper-V PowerShell module
    Requires: Hyper-V Administrator privileges
    Requires: WSL2 with bash for static IP configuration

    The script performs the following validations:
    - Source image directory structure
    - VM name validity and uniqueness
    - Destination directory existence
    - MAC address format (if provided)
    - Virtual switch existence (if provided)
    - IPv4 configuration format (if provided)

.LINK
    https://docs.microsoft.com/en-us/powershell/module/hyper-v/
#>
#Requires -Version 5.1
#Requires -Modules Hyper-V

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceImageDirectory,

    [Parameter(Mandatory = $true)]
    [string]$DestinationDirectory,

    [Parameter(Mandatory = $true)]
    [string]$VirtualMachineName,

    [Parameter(Mandatory = $false)]
    [string]$StaticMacAddress,

    [Parameter(Mandatory = $false)]
    [string]$VirtualSwitchName,

    [Parameter(Mandatory = $false)]
    [hashtable]$IPv4AddressInfo
)

#region Variables

    $ErrorActionPreference = 'Stop'
    $InformationPreference = 'Continue'

    $Script:SetStaticIpScriptRelativePath = "..\bash\set-staticip.sh"

#endregion Variables


#region Functions

    function Test-ImageDirectoryStructure {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string]$ImagePath
        )
        if (-not (Test-Path -Path $ImagePath -PathType Container)) {
            throw "The source image directory '$ImagePath' does not exist."
        }

        $virtualHardDisksPath = Join-Path -Path $ImagePath -ChildPath "Virtual Hard Disks"
        $virtualMachinesPath = Join-Path -Path $ImagePath -ChildPath "Virtual Machines"

        if (-not (Test-Path -Path $virtualHardDisksPath -PathType Container)) {
            throw "The 'Virtual Hard Disks' subdirectory does not exist in the source image directory."
        }

        if (-not (Test-Path -Path $virtualMachinesPath -PathType Container)) {
            throw "The 'Virtual Machines' subdirectory does not exist in the source image directory."
        }

        $vmcxFile = Get-ChildItem -Path $virtualMachinesPath -Filter *.vmcx | Select-Object -First 1
        if (-not $vmcxFile) {
            throw "No .vmcx file found in the 'Virtual Machines' subdirectory."
        }
        Write-Information "Source image directory structure is valid."
    }

    function Test-VMName {
        [CmdletBinding()]
        [OutputType([bool])]
        param(
            [Parameter(Mandatory = $true)]
            [string]$VmName
        )

        $invalidChars = '[<>:"/\\|?*]'
        if ($VmName -match $invalidChars) {
            throw 'VM name contains invalid characters. Invalid characters: < > : " / \ | ? *'
        }

        if ($VmName.Length -gt 100) {
            throw "VM name is too long. Maximum length is 100 characters."
        }

        $existingVm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
        if ($existingVm) {
            throw "A VM with the name '$VmName' already exists."
        }
        Write-Information "VM name '$VmName' is valid and does not conflict with existing VMs."
    }

    function Test-DestinationDirectory {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string]$DestinationDirectory
        )
        if (-not (Test-Path -Path $DestinationDirectory -PathType Container)) {
            throw "The destination directory '$DestinationDirectory' does not exist."
        }
        Write-Information "Destination directory '$DestinationDirectory' exists and is valid."
    }

    function Test-MacAddress {
        <#
        .SYNOPSIS
            Validates a MAC address format for Hyper-V VM network adapters.

        .DESCRIPTION
            Tests if the provided MAC address string is in a valid format for Hyper-V.
            Accepts formats like
            - '00-15-5D-00-04-08'
            - '00:15:5D:00:04:08'
            - '00 15 5D 00 04 08'
            - '00155D000408'

        .PARAMETER MacAddress
            The MAC address string to validate.

        .EXAMPLE
            Test-MacAddress -MacAddress "00-15-5D-00-04-08"

        .EXAMPLE
            Test-MacAddress -MacAddress "00:15:5D:00:04:08"

        .EXAMPLE
            Test-MacAddress -MacAddress "00155D000408"
        #>
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string]$MacAddress
        )

        # Remove any dashes, colons, or spaces to normalize the format
        $normalizedMac = $MacAddress -replace '[-:\s]', ''

        # Check if it's exactly 12 hexadecimal characters
        if ($normalizedMac -notmatch '^[0-9A-Fa-f]{12}$') {
            throw "Invalid MAC address format. MAC address must be 12 hexadecimal characters, optionally separated by dashes, colons, or spaces. Example: 00-15-5D-00-04-08"
        }

        # Convert to Hyper-V format (with dashes every 2 characters)
        $formattedMac = $normalizedMac -replace '(..)', '$1-' -replace '-$', ''

        Write-Information "MAC address '$MacAddress' is valid. Formatted as: $formattedMac"
        return $formattedMac
    }

    function Test-VirtualSwitch {
        <#
        .SYNOPSIS
            Validates if a Hyper-V virtual switch exists.

        .DESCRIPTION
            Tests if the specified virtual switch name exists on the Hyper-V host.
            Throws an exception if the switch does not exist.

        .PARAMETER SwitchName
            The name of the virtual switch to validate.

        .EXAMPLE
            Test-VirtualSwitch -SwitchName "Default Switch"

        .EXAMPLE
            Test-VirtualSwitch -SwitchName "External Network"
        #>
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string]$SwitchName
        )

        $virtualSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
        if (-not $virtualSwitch) {
            throw "Virtual switch '$SwitchName' does not exist. Available switches: $((Get-VMSwitch | Select-Object -ExpandProperty Name) -join ', ')"
        }

        Write-Information "Virtual switch '$SwitchName' exists and is valid."
        return $virtualSwitch
    }

    function Get-VmcxFilepath {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string]$SourceImageDirectory
        )
        $vmcxFiles = @(Get-ChildItem -Path (Join-Path -Path $SourceImageDirectory -ChildPath "Virtual Machines") -Filter *.vmcx)
        if ($vmcxFiles.Count -eq 0) {
            throw "No .vmcx files found in the 'Virtual Machines' subdirectory."
        }
        if ($vmcxFiles.Count -gt 1) {
            throw "Multiple .vmcx files found in the 'Virtual Machines' subdirectory. Something is wrong. Please check the source image directory."
        }
        Write-Information "Found .vmcx file: $($vmcxFiles[0].FullName)"
        return $vmcxFiles[0].FullName
    }

    function Import-Image {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [string]$SourceImageDirectory,

            [Parameter(Mandatory = $true)]
            [string]$DestinationDirectory,

            [Parameter(Mandatory = $true)]
            [string]$VirtualMachineName
        )

        $vmcxPath = Get-VmcxFilepath -SourceImageDirectory $SourceImageDirectory
        $virtualMachinePath = Join-Path -Path $DestinationDirectory -ChildPath $VirtualMachineName
        $smartPagingFilePath = Join-Path -Path $virtualMachinePath -ChildPath "smart_paging"
        $snapshotFilePath = Join-Path -Path $virtualMachinePath -ChildPath "snapshots"
        $vhdDestinationPath = Join-Path -Path $virtualMachinePath -ChildPath "vhds"

        Write-Information "Importing VM from '$vmcxPath' to '$virtualMachinePath' with VHDs in '$vhdDestinationPath'."
        $importedVm = Import-VM `
            -Copy `
            -GenerateNewId `
            -Path $vmcxPath `
            -VirtualMachinePath $virtualMachinePath `
            -SmartPagingFilePath $smartPagingFilePath `
            -SnapshotFilePath $snapshotFilePath `
            -VhdDestinationPath $vhdDestinationPath | `
        Rename-VM -NewName $VirtualMachineName -PassThru
        Write-Information "VM '$VirtualMachineName' imported successfully to '$virtualMachinePath'."

        return $importedVm
    }

    function Set-VmStaticMacAddress {
        <#
        .SYNOPSIS
            Sets a static MAC address for a Hyper-V VM's network adapter.

        .DESCRIPTION
            Configures the network adapter of the specified VM to use a static MAC address.
            The MAC address is validated before setting.

        .PARAMETER VirtualMachineName
            The name of the virtual machine to configure.

        .PARAMETER MacAddress
            The MAC address to set, in format like 00-15-5D-00-04-08.

        .EXAMPLE
            Set-VmStaticMacAddress -VirtualMachineName "MyVM" -MacAddress "00-15-5D-00-04-08"
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [string]$VirtualMachineName,

            [Parameter(Mandatory = $true)]
            [string]$MacAddress
        )

        Write-Information "Setting static MAC address '$MacAddress' for VM '$VirtualMachineName'."
        Set-VMNetworkAdapter -VMName $VirtualMachineName -StaticMacAddress $MacAddress
        Write-Information "Static MAC address '$MacAddress' set successfully for VM '$VirtualMachineName'."
    }

    function Connect-VmToVirtualSwitch {
        <#
        .SYNOPSIS
            Connects a Hyper-V VM's network adapter to a virtual switch.

        .DESCRIPTION
            Connects the network adapter of the specified VM to the specified virtual switch.
            The virtual switch existence is validated before connecting.

        .PARAMETER VirtualMachineName
            The name of the virtual machine to configure.

        .PARAMETER SwitchName
            The name of the virtual switch to connect to.

        .EXAMPLE
            Connect-VmToVirtualSwitch -VirtualMachineName "MyVM" -SwitchName "Default Switch"
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [string]$VirtualMachineName,

            [Parameter(Mandatory = $true)]
            [string]$SwitchName
        )

        Write-Information "Connecting VM '$VirtualMachineName' to virtual switch '$SwitchName'."
        Connect-VMNetworkAdapter -VMName $VirtualMachineName -SwitchName $SwitchName
        Write-Information "VM '$VirtualMachineName' successfully connected to virtual switch '$SwitchName'."
    }

    function Test-IPv4AddressInfo {
        <#
        .SYNOPSIS
            Validates the IPv4AddressInfo hashtable format.

        .DESCRIPTION
            Tests if the provided hashtable contains the required keys for IPv4 configuration.
            Validates IP address and gateway formats.

        .PARAMETER IPv4Info
            The hashtable containing IPv4 configuration information.

        .EXAMPLE
            Test-IPv4AddressInfo -IPv4Info @{address='192.168.1.100/24'; gateway='192.168.1.1'; dns='8.8.8.8,8.8.4.4'}
        #>
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [hashtable]$IPv4Info
        )

        $requiredKeys = @('address', 'gateway', 'dns')
        foreach ($key in $requiredKeys) {
            if (-not $IPv4Info.ContainsKey($key)) {
                throw "IPv4AddressInfo hashtable is missing required key: '$key'. Required keys: $($requiredKeys -join ', ')"
            }
            if ([string]::IsNullOrWhiteSpace($IPv4Info[$key])) {
                throw "IPv4AddressInfo hashtable key '$key' cannot be null or empty."
            }
        }

        # Validate IP address format (basic validation)
        if ($IPv4Info.address -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$') {
            throw "Invalid IP address format in 'address'. Expected format: 192.168.1.100/24"
        }

        if ($IPv4Info.gateway -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
            throw "Invalid gateway IP format in 'gateway'. Expected format: 192.168.1.1"
        }

        # Validate DNS servers format
        $dnsServers = $IPv4Info.dns -split ','
        foreach ($dns in $dnsServers) {
            $dns = $dns.Trim()
            if ($dns -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                throw "Invalid DNS server IP format: '$dns'. Expected format: 8.8.8.8"
            }
        }

        Write-Information "IPv4AddressInfo configuration is valid."
        Write-Information "  Address: $($IPv4Info.address)"
        Write-Information "  Gateway: $($IPv4Info.gateway)"
        Write-Information "  DNS: $($IPv4Info.dns)"
    }

    function Test-WSLAvailability {
        <#
        .SYNOPSIS
            Tests if WSL2 is available and can execute bash commands.

        .DESCRIPTION
            Verifies that WSL is installed and can execute basic commands.
            Also checks if the specified bash script exists.

        .PARAMETER BashScriptPath
            The absolute path to the bash script to validate.

        .EXAMPLE
            Test-WSLAvailability -BashScriptPath "C:\path\to\set-staticip.sh"
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [string]$BashScriptPath
        )

        try {
            $wslVersion = wsl --version 2>$null
            if (-not $wslVersion) {
                throw "WSL is not installed or not available."
            }
            Write-Information "WSL is available."

            # Test bash execution
            $bashTest = wsl --exec bash -c "echo 'WSL bash test successful'" 2>$null
            if ($bashTest -ne "WSL bash test successful") {
                throw "Unable to execute bash commands in WSL."
            }
            Write-Information "WSL bash execution is working."

            # Check if the specified bash script exists
            if (-not (Test-Path -Path $BashScriptPath)) {
                throw "Bash script not found at: $BashScriptPath"
            }
            Write-Information "Bash script found at: $BashScriptPath"

        } catch {
            throw "WSL availability check failed: $($_.Exception.Message)"
        }
    }

    function Get-SshCredentials {
        <#
        .SYNOPSIS
            Interactively prompts user for SSH credentials.

        .DESCRIPTION
            Prompts the user to enter SSH username, private key file path, and passphrase.
            Validates that the SSH key file exists.

        .EXAMPLE
            $creds = Get-SshCredentials
        #>
        [CmdletBinding()]
        param()

        Write-Information "SSH credentials are required to configure static IP address."

        # Get SSH username
        $sshUsername = Read-Host -Prompt "Enter SSH username"
        if ([string]::IsNullOrWhiteSpace($sshUsername)) {
            throw "SSH username cannot be empty."
        }

        # Get SSH private key path
        $sshKeyPath = Read-Host -Prompt "Enter SSH private key file path"
        if ([string]::IsNullOrWhiteSpace($sshKeyPath)) {
            throw "SSH private key path cannot be empty."
        }
        $sshKeyWindowsPath = $(wsl --exec bash -c "wslpath -w `$(realpath $sshKeyPath)")
        Write-Information "SSH key Windows path: $sshKeyWindowsPath"
        if (-not (Test-Path -Path $sshKeyWindowsPath)) {
            throw "SSH private key file not found: $sshKeyPath"
        }

        # Get SSH passphrase
        $sshPassphrase = Read-Host -Prompt "Enter SSH private key passphrase" -AsSecureString
        $sshPassphraseText = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sshPassphrase))

        if ([string]::IsNullOrWhiteSpace($sshPassphraseText)) {
            throw "SSH passphrase cannot be empty."
        }

        return @{
            Username = $sshUsername
            KeyPath = $sshKeyPath
            Passphrase = $sshPassphraseText
        }
    }

    function Get-VmCurrentIPAddress {
        <#
        .SYNOPSIS
            Retrieves the current IP address of a Hyper-V VM.

        .DESCRIPTION
            Uses Hyper-V integration services to get the current IP address of the specified VM.
            The VM must be running and have integration services installed.

        .PARAMETER VirtualMachineName
            The name of the virtual machine to query.

        .EXAMPLE
            Get-VmCurrentIPAddress -VirtualMachineName "MyVM"
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [string]$VirtualMachineName
        )

        Write-Information "Retrieving current IP address for VM '$VirtualMachineName'..."

        # Wait for VM to be fully started and integration services to be available
        $maxAttempts = 30
        $attempt = 0
        $currentIP = $null

        do {
            $attempt++
            Start-Sleep -Seconds 2

            try {
                $vm = Get-VM -Name $VirtualMachineName
                if ($vm.State -ne 'Running') {
                    Write-Information "VM is not running. Starting VM '$VirtualMachineName'..."
                    Start-VM -Name $VirtualMachineName
                    Start-Sleep -Seconds 5
                    continue
                }

                $networkAdapters = Get-VMNetworkAdapter -VMName $VirtualMachineName
                foreach ($adapter in $networkAdapters) {
                    if ($adapter.IPAddresses) {
                        # Get the first IPv4 address (filter out IPv6)
                        $currentIP = $adapter.IPAddresses | Where-Object { $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' } | Select-Object -First 1
                        if ($currentIP) {
                            break
                        }
                    }
                }

                if ($currentIP) {
                    Write-Information "Current IP address found: $currentIP"
                    return $currentIP
                }

            } catch {
                Write-Information "Attempt $attempt failed: $($_.Exception.Message)"
            }

            Write-Information "Attempt $attempt of $maxAttempts - waiting for IP address..."

        } while ($attempt -lt $maxAttempts -and -not $currentIP)

        if (-not $currentIP) {
            throw "Unable to retrieve current IP address for VM '$VirtualMachineName' after $maxAttempts attempts. Please ensure the VM is running and has integration services installed."
        }
    }

    function Set-VmStaticIPAddress {
        <#
        .SYNOPSIS
            Configures static IP address for a Linux VM using the specified bash script.

        .DESCRIPTION
            Uses WSL2 to execute the provided bash script to configure static IP address
            on the specified Linux VM via SSH.

        .PARAMETER VirtualMachineName
            The name of the virtual machine to configure.

        .PARAMETER CurrentIPAddress
            The current IP address of the VM.

        .PARAMETER IPv4Info
            Hashtable containing the static IP configuration.

        .PARAMETER SshCredentials
            Hashtable containing SSH credentials.

        .PARAMETER BashScriptPath
            The absolute path to the bash script to execute.

        .EXAMPLE
            Set-VmStaticIPAddress -VirtualMachineName "LinuxVM" -CurrentIPAddress "192.168.1.50" -IPv4Info $ipConfig -SshCredentials $sshCreds -BashScriptPath "C:\path\to\set-staticip.sh"
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [string]$VirtualMachineName,

            [Parameter(Mandatory = $true)]
            [string]$CurrentIPAddress,

            [Parameter(Mandatory = $true)]
            [hashtable]$IPv4Info,

            [Parameter(Mandatory = $true)]
            [hashtable]$SshCredentials,

            [Parameter(Mandatory = $true)]
            [string]$BashScriptPath
        )
        $targetIpCidr = $IPv4Info.address
        $targetIpAddress = $targetIpCidr.Split('/')[0]
        Write-Information "Configuring static IP address for VM '$VirtualMachineName'..."
        Write-Information "Current IP: $CurrentIPAddress"
        Write-Information "Target static IP: $($targetIpCidr)"

        # Convert Windows paths to WSL paths using wslpath
        $scriptWSLPath = $(wsl --exec bash -c "wslpath -u '$BashScriptPath'")
        Write-Information "Script WSL path: $scriptWSLPath"
        $sshKeyWSLPath = $(wsl --exec bash -c "realpath $($SshCredentials.KeyPath)")

        Set-SshHostKeys -IPAddress $CurrentIPAddress

        # Build the command with history management
        $bashCommand = "set +o history; " +
                      "'$scriptWSLPath' " +
                      "-p '$($SshCredentials.Passphrase)' " +
                      "-k '$sshKeyWSLPath' " +
                      "-t '$CurrentIPAddress' " +
                      "-u '$($SshCredentials.Username)' " +
                      "-a '$($targetIpCidr)' " +
                      "-g '$($IPv4Info.gateway)' " +
                      "-d '$($IPv4Info.dns)'; " +
                      "set -o history"

        Write-Information "Executing static IP configuration script..."
        try {
            $result = wsl --exec bash -c $bashCommand
            Write-Information "Static IP configuration completed successfully."
            Write-Information "Script output: $result"
        } catch {
            throw "Failed to configure static IP address: $($_.Exception.Message)"
        }
        Set-SshHostKeys -IPAddress $targetIpAddress
    }

    function Set-SshHostKeys {
        # Manage SSH host keys to avoid host verification issues
        param (
            [string]$IPAddress
        )
            Write-Information "Managing SSH host keys for IP address: $IPAddress"
            try {
                wsl --exec bash -c "ssh-keygen -R $IPAddress && ssh-keyscan -H $IPAddress >> ~/.ssh/known_hosts"
                Write-Information "SSH host keys updated successfully."
            } catch {
                Write-Warning "Failed to update SSH host keys, but continuing: $($_.Exception.Message)"
            }
    }

#endregion Functions


#region Main execution

    # Validate input parameters
    Test-ImageDirectoryStructure -ImagePath $SourceImageDirectory
    Test-VMName -VmName $VirtualMachineName
    Test-DestinationDirectory -DestinationDirectory $DestinationDirectory

    # Validate MAC address if provided
    $formattedMacAddress = $null
    if ($StaticMacAddress) {
        $formattedMacAddress = Test-MacAddress -MacAddress $StaticMacAddress
    }

    # Validate virtual switch if provided
    if ($VirtualSwitchName) {
        Test-VirtualSwitch -SwitchName $VirtualSwitchName
    }

    # Validate IPv4 configuration if provided
    $sshCredentials = $null
    if ($IPv4AddressInfo) {
        Test-IPv4AddressInfo -IPv4Info $IPv4AddressInfo
        Test-WSLAvailability -BashScriptPath $SetStaticIpScriptRelativePath
        $sshCredentials = Get-SshCredentials
    }

    # Import the VM
    $importedVm = Import-Image -SourceImageDirectory $SourceImageDirectory -DestinationDirectory $DestinationDirectory -VirtualMachineName $VirtualMachineName

    # Set static MAC address if provided
    if ($formattedMacAddress) {
        Set-VmStaticMacAddress -VirtualMachineName $VirtualMachineName -MacAddress $formattedMacAddress
    }

    # Connect to virtual switch if provided
    if ($VirtualSwitchName) {
        Connect-VmToVirtualSwitch -VirtualMachineName $VirtualMachineName -SwitchName $VirtualSwitchName
    }

    # Configure static IP address if provided
    if ($IPv4AddressInfo -and $sshCredentials) {
        $currentIP = Get-VmCurrentIPAddress -VirtualMachineName $VirtualMachineName
        Set-VmStaticIPAddress -VirtualMachineName $VirtualMachineName -CurrentIPAddress $currentIP -IPv4Info $IPv4AddressInfo -SshCredentials $sshCredentials -BashScriptPath $SetStaticIpScriptRelativePath
        Write-Information "Static IP address configuration completed."
    }

    Write-Information "VM import completed successfully."

#endregion Main execution
