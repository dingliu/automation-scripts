<#
.SYNOPSIS
    Imports a Hyper-V virtual machine from an exported image directory.

.DESCRIPTION
    This script imports a Hyper-V virtual machine from an exported VM image directory structure.
    It validates the source image directory, destination directory, and VM name before import.
    Optionally configures a static MAC address and connects the VM to a specified virtual switch.

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

.EXAMPLE
    .\Import-HyperVImage.ps1 -SourceImageDirectory "C:\VM-Exports\MyVM" -DestinationDirectory "C:\VMs" -VirtualMachineName "ImportedVM"

    Imports a VM from the exported image in C:\VM-Exports\MyVM to C:\VMs\ImportedVM.

.EXAMPLE
    .\Import-HyperVImage.ps1 -SourceImageDirectory "C:\VM-Exports\MyVM" -DestinationDirectory "C:\VMs" -VirtualMachineName "WebServer" -StaticMacAddress "00-15-5D-00-04-08" -VirtualSwitchName "External Network"

    Imports a VM with a static MAC address and connects it to the "External Network" virtual switch.

.NOTES
    Requires: PowerShell version 5.1 or higher
    Requires: Hyper-V PowerShell module
    Requires: Hyper-V Administrator privileges

    The script performs the following validations:
    - Source image directory structure
    - VM name validity and uniqueness
    - Destination directory existence
    - MAC address format (if provided)
    - Virtual switch existence (if provided)

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
    [string]$VirtualSwitchName
)

#region Variables

    $ErrorActionPreference = 'Stop'
    $InformationPreference = 'Continue'

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

    Write-Information "VM import completed successfully."

#endregion Main execution
