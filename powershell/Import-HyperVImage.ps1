#Requires -Modules Hyper-V

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceImageDirectory,

    [Parameter(Mandatory = $true)]
    [string]$DestinationDirectory,

    [Parameter(Mandatory = $true)]
    [string]$VirtualMachineName
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
        Import-VM `
            -Copy `
            -GenerateNewId `
            -Path $vmcxPath `
            -VirtualMachinePath $virtualMachinePath `
            -SmartPagingFilePath $smartPagingFilePath `
            -SnapshotFilePath $snapshotFilePath `
            -VhdDestinationPath $vhdDestinationPath | `
        Rename-VM -NewName $VirtualMachineName
        Write-Information "VM '$VirtualMachineName' imported successfully to '$virtualMachinePath'."
    }

#endregion Functions


#region Main

    Test-ImageDirectoryStructure -ImagePath $SourceImageDirectory
    Test-VMName -VmName $VirtualMachineName
    Test-DestinationDirectory -DestinationDirectory $DestinationDirectory
    Import-Image -SourceImageDirectory $SourceImageDirectory `
        -DestinationDirectory $DestinationDirectory `
        -VirtualMachineName $VirtualMachineName

#endregion Main
