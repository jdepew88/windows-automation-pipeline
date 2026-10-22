#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Deployment Builder - USB Preparation Assistant (Phase 7).

.DESCRIPTION
    Turns a Windows Deployment Builder deployment package into a ready-to-boot Windows 11
    installation USB, on this computer. The website decides what is installed; this tool only
    prepares and verifies media. It never uploads anything.

      -Mode Wizard     (default) guided console steps; asks for administrator rights only to erase
                       and prepare a drive from an ISO
      -Mode Discover   (read-only) lists disks with their identity, bus, media type, partitions,
                       letters, file systems and labels, and whether each can be a target
      -Mode Inspect    (read-only) a USB drive, a folder or a Windows ISO: Windows Setup structure,
                       image editions, architecture, build and servicing level, deployment files,
                       conflicting files, Ventoy, free space
      -Mode Plan       (read-only) validates the deployment package (and the Phase 6 backup it pins)
                       against the media and writes a plan: every file added or replaced, every
                       destructive step, the space needed, blockers and warnings
      -Mode Apply      carries out a plan after re-validating everything:
                         Update  adds the deployment files to an existing Windows USB (no format;
                                 Windows files untouched; a previous deployment is moved to
                                 WDB-previous\<time>, never deleted)
                         Create  ERASES the selected USB flash drive, creates FAT32 (+ NTFS for the
                                 rest of a large drive), copies Windows from the ISO (splitting an
                                 image over 4 GB with DISM) and adds the deployment files; needs
                                 administrator rights and -ConfirmErase <code from the plan>
      -Mode Verify     (read-only) checks a prepared USB and writes the readiness report

    Layout written (the contract of the Phase 4-6 engines):
      <root>\autounattend.xml                          found by Windows Setup on removable media
      <root>\WindowsDeployment\...                     the package (manifest + hashed files)
      <root>\WindowsDeployment\backups\<folder>\       the Phase 6 settings backup, when pinned
    The installed computer does not need the USB after Windows Setup: everything the deployment runs
    is embedded in the answer file and staged locally.

    Never: formats a disk without the typed confirmation of that exact disk; touches the disk of the
    running Windows, a boot disk, a fixed or external hard disk, a Ventoy drive, an ambiguous disk;
    executes anything from a package, backup or ISO; changes boot files or Secure Boot.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WdbMediaAssistant.ps1
.EXAMPLE
    .\WdbMediaAssistant.ps1 -Mode Plan -Workflow Update -Package .\windows-deployment-package.zip -Backup E:\WDB-AppBackup-... -Target F:
    .\WdbMediaAssistant.ps1 -Mode Apply -PlanPath <plan.json>
#>
[CmdletBinding()]
param(
    [ValidateSet('Wizard', 'Discover', 'Inspect', 'Plan', 'Apply', 'Verify', 'Library')]
    [string] $Mode = 'Wizard',
    [ValidateSet('Update', 'Create')]
    [string] $Workflow = 'Update',
    [string] $Package = '',
    [string] $Backup = '',
    [string] $Target = '',
    [string] $Iso = '',
    [int] $Disk = -1,
    [string] $PlanPath = '',
    [string] $ConfirmErase = '',
    [string] $IsoSha256 = '',
    [switch] $ReplaceExisting,
    [switch] $NoDataPartition,
    [switch] $CheckOnline,
    [switch] $Json
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Captured first: dot-sourcing WdbMigration.ps1 below binds its own parameters (Mode, Json) in this scope.
$script:WdmArgs = @{ Mode = $Mode; Workflow = $Workflow; Package = $Package; Backup = $Backup; Target = $Target; Iso = $Iso; Disk = $Disk; PlanPath = $PlanPath
                     ConfirmErase = $ConfirmErase; IsoSha256 = $IsoSha256; ReplaceExisting = [bool] $ReplaceExisting; NoDataPartition = [bool] $NoDataPartition; CheckOnline = [bool] $CheckOnline; Json = [bool] $Json }
$script:WdmMain = $MyInvocation.InvocationName -ne '.'
$script:WdmVersion = '1.0.0'
# Cached Microsoft release information, shipped next to the assistant.
$script:WdmReleaseFile = Join-Path $PSScriptRoot 'windows-releases.json'
$script:PlanFormat = 'windows-deployment-builder/media-plan'
$script:StateFormat = 'windows-deployment-builder/media-state'
$script:ReportFormat = 'windows-deployment-builder/media-report'
$script:ManifestFormat = 'windows-deployment-builder/deployment-manifest'
$script:PackageDir = 'WindowsDeployment'
$script:AnswerFile = 'autounattend.xml'
$script:StateFile = 'wdb-media-state.json'
$script:ReportFile = 'wdb-media-report.txt'
$script:PreviousDir = 'WDB-previous'
$script:Fat32MaxFile = 4GB - 1
# Windows formats FAT32 volumes up to 32 GB; a larger drive gets FAT32 for Setup plus NTFS for the rest.
$script:Fat32MaxVolume = 32GB - 64MB
$script:SplitSizeMB = 3800
$script:MaxRemovableBytes = 256GB
$script:WdmLimits = @{ zipEntries = 5000; zipBytes = 512MB; xmlBytes = 16MB; manifestBytes = 4MB }
$script:WdmHexId = '^[0-9A-F]{16}$'
$script:WdmSha256 = '^[0-9A-F]{64}$'

# Generic edition ids of the builder -> the EditionId of a Windows image (DISM / install.wim XML).
$script:DismEditions = [ordered]@{
    home = 'Core'; home_n = 'CoreN'; home_single = 'CoreSingleLanguage'; education = 'Education'; education_n = 'EducationN'
    pro = 'Professional'; pro_n = 'ProfessionalN'; pro_education = 'ProfessionalEducation'; pro_education_n = 'ProfessionalEducationN'
    pro_workstations = 'ProfessionalWorkstation'; pro_workstations_n = 'ProfessionalWorkstationN'; enterprise = 'Enterprise'; enterprise_n = 'EnterpriseN'
}
# Packages from before Phase 7 only state the edition by name ("Windows 11 Pro").
$script:EditionNames = @{
    'Windows 11 Home' = 'Core'; 'Windows 11 Home N' = 'CoreN'; 'Windows 11 Home Single Language' = 'CoreSingleLanguage'; 'Windows 11 Education' = 'Education'
    'Windows 11 Education N' = 'EducationN'; 'Windows 11 Pro' = 'Professional'; 'Windows 11 Pro N' = 'ProfessionalN'; 'Windows 11 Pro Education' = 'ProfessionalEducation'
    'Windows 11 Pro Education N' = 'ProfessionalEducationN'; 'Windows 11 Pro for Workstations' = 'ProfessionalWorkstation'; 'Windows 11 Pro N for Workstations' = 'ProfessionalWorkstationN'
    'Windows 11 Enterprise' = 'Enterprise'; 'Windows 11 Enterprise N' = 'EnterpriseN'
}
$script:ArchNames = @{ '0' = 'x86'; '5' = 'arm'; '9' = 'amd64'; '12' = 'arm64' }
$script:BootEfi = @{ amd64 = 'efi\boot\bootx64.efi'; arm64 = 'efi\boot\bootaa64.efi'; x86 = 'efi\boot\bootia32.efi' }

# ------------------------------------------------------------------------------------------------
# System adapters (the scenario tests replace every one of these; nothing else touches the system)
# ------------------------------------------------------------------------------------------------

function Get-WdmNow { [DateTime]::UtcNow }

function Test-WdmElevated {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WdmSystemDriveLetter { ([string] $env:SystemDrive).TrimEnd(':').ToUpperInvariant() }

function Get-WdmStateRoot { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WindowsDeploymentBuilder\media' }

<#
    Physical disks with everything needed to tell them apart. Read with CIM (works without
    administrator rights); with administrator rights the Storage module adds the unique id, bus
    type and the system/boot/read-only flags. Disk numbers and letters are only shown and
    re-checked; identity is the fingerprint (Get-WdmDiskFingerprint).
#>
function Get-WdmDisks {
    $out = @()
    $storage = @{}
    try { foreach ($d in @(Get-Disk -ErrorAction Stop)) { $storage[[int] $d.Number] = $d } } catch { }
    foreach ($dd in @(Get-CimInstance -ClassName Win32_DiskDrive)) {
        $n = [int] $dd.Index
        $parts = @()
        foreach ($p in @(Get-CimAssociatedInstance -InputObject $dd -ResultClassName Win32_DiskPartition)) {
            $ld = @(Get-CimAssociatedInstance -InputObject $p -ResultClassName Win32_LogicalDisk | Select-Object -First 1)
            $letter = $(if ($ld) { ([string] $ld[0].DeviceID).TrimEnd(':') } else { '' })
            $parts += , @{ Number = [int] $p.Index + 1; DriveLetter = $letter; FileSystem = $(if ($ld) { [string] $ld[0].FileSystem } else { '' }); Label = $(if ($ld) { [string] $ld[0].VolumeName } else { '' })
                           Size = [int64] $p.Size; Free = $(if ($ld) { [int64] $ld[0].FreeSpace } else { 0 }); IsBootPartition = [bool] $p.BootPartition; Root = $(if ($letter) { "$($letter):\" } else { '' }) }
        }
        $s = $(if ($storage.ContainsKey($n)) { $storage[$n] } else { $null })
        $out += , @{
            Number = $n; FriendlyName = $(if ($s) { [string] $s.FriendlyName } else { [string] $dd.Caption }); Manufacturer = [string] $dd.Manufacturer; Model = [string] $dd.Model
            SerialNumber = ([string] $dd.SerialNumber).Trim(); UniqueId = $(if ($s) { [string] $s.UniqueId } else { [string] $dd.PNPDeviceID }); Size = [int64] $dd.Size
            BusType = $(if ($s) { [string] $s.BusType } else { [string] $dd.InterfaceType }); MediaType = [string] $dd.MediaType
            PartitionStyle = $(if ($s) { [string] $s.PartitionStyle } else { '' }); IsSystem = $(if ($s) { [bool] $s.IsSystem } else { $false }); IsBoot = $(if ($s) { [bool] $s.IsBoot } else { $false })
            IsReadOnly = $(if ($s) { [bool] $s.IsReadOnly } else { $false }); IsOffline = $(if ($s) { [bool] $s.IsOffline } else { $false }); Partitions = $parts; Elevated = [bool] $s
        }
    }
    return $out
}

function Get-WdmFreeSpace { param([string] $Root) (New-Object IO.DriveInfo($Root)).AvailableFreeSpace }

<# Mounts an ISO read-only and returns its root ("F:\"). #>
function Mount-WdmIso {
    param([string] $Path)
    $img = Mount-DiskImage -ImagePath $Path -Access ReadOnly -StorageType ISO -PassThru
    $letter = ($img | Get-Volume).DriveLetter
    if (-not $letter) { throw 'The ISO was mounted without a drive letter.' }
    return "$($letter):\"
}
function Dismount-WdmIso { param([string] $Path) Dismount-DiskImage -ImagePath $Path | Out-Null }

<#
    The only destructive operation: erases disk $Number and creates the layout. Called only by
    Invoke-WdmApply after the typed confirmation and a fresh identity check. MBR with one active
    FAT32 partition (UEFI firmware boots it; Microsoft's signed boot files are copied unchanged),
    plus NTFS for the rest of a drive larger than 32 GB.
#>
function Invoke-WdmPartitionDisk {
    param([int] $Number, [int64] $BootBytes, [bool] $DataPartition)
    $d = Get-Disk -Number $Number
    if ([string] $d.PartitionStyle -ne 'RAW') { Clear-Disk -Number $Number -RemoveData -RemoveOEM -Confirm:$false }
    Initialize-Disk -Number $Number -PartitionStyle MBR
    $boot = New-Partition -DiskNumber $Number -Size $BootBytes -IsActive -AssignDriveLetter
    Format-Volume -Partition $boot -FileSystem FAT32 -NewFileSystemLabel 'WDB-BOOT' -Confirm:$false -Force | Out-Null
    $data = ''
    if ($DataPartition) {
        $p2 = New-Partition -DiskNumber $Number -UseMaximumSize -AssignDriveLetter
        Format-Volume -Partition $p2 -FileSystem NTFS -NewFileSystemLabel 'WDB-DATA' -Confirm:$false -Force | Out-Null
        $data = "$((Get-Partition -DiskNumber $Number -PartitionNumber $p2.PartitionNumber).DriveLetter):\"
    }
    @{ BootRoot = "$((Get-Partition -DiskNumber $Number -PartitionNumber $boot.PartitionNumber).DriveLetter):\"; DataRoot = $data }
}

<# DISM: split a WIM into Setup-compatible install.swm parts (with integrity check). #>
function Invoke-WdmSplitImage {
    param([string] $Source, [string] $DestinationSwm, [int] $FileSizeMB)
    Split-WindowsImage -ImagePath $Source -SplitImagePath $DestinationSwm -FileSize $FileSizeMB -CheckIntegrity | Out-Null
}

<# DISM: export one edition of an ESD/WIM to a WIM (an ESD cannot be split). #>
function Invoke-WdmExportImage {
    param([string] $Source, [int] $Index, [string] $Destination)
    Export-WindowsImage -SourceImagePath $Source -SourceIndex $Index -DestinationImagePath $Destination -CompressionType Max -CheckIntegrity | Out-Null
}

function Get-WdmSignature {
    param([string] $Path)
    $s = Get-AuthenticodeSignature -LiteralPath $Path
    @{ Status = [string] $s.Status; Signer = $(if ($s.SignerCertificate) { [string] $s.SignerCertificate.Subject } else { '' }) }
}

function Write-WdmProgress {
    param([string] $Activity, [string] $Status, [int] $Percent = -1)
    if ($Percent -ge 0) { Write-Progress -Activity $Activity -Status $Status -PercentComplete $Percent } else { Write-Progress -Activity $Activity -Status $Status }
}

<# Safe checkpoint: a cancel request is a file next to the plan (the wizard creates it on Ctrl+C). #>
function Test-WdmCancelRequested { param([string] $PlanId) Test-Path -LiteralPath (Join-Path (Get-WdmStateRoot) "$PlanId.cancel") }

function Get-WdmOnlineReleasePage { param([string] $Url) (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 20).Content }

function Read-WdmAnswer { param([string] $Prompt) Read-Host $Prompt }

# ------------------------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------------------------

function ConvertTo-WdmHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { $h = [ordered]@{}; foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-WdmHashtable $InputObject[$k] }; return $h }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) { $h = [ordered]@{}; foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-WdmHashtable $p.Value }; return $h }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) { return , @($InputObject | ForEach-Object { ConvertTo-WdmHashtable $_ }) }
    return $InputObject
}

function Read-WdmJsonFile {
    param([string] $Path, [int64] $MaxBytes = 4MB)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    if ((Get-Item -LiteralPath $Path -Force).Length -gt $MaxBytes) { throw "$Path is larger than expected." }
    $t = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    ConvertTo-WdmHashtable ($t.TrimStart([char] 0xFEFF) | ConvertFrom-Json)
}

function ConvertTo-WdmJson { param($Value) ($Value | ConvertTo-Json -Depth 12) -replace "`r`n", "`n" }

function Get-WdmSha256Bytes {
    param([byte[]] $Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('X2') }) } finally { $sha.Dispose() }
}

function Get-WdmFileSha256 {
    param([string] $Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::OpenRead($Path)
    try { -join ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('X2') }) } finally { $fs.Dispose(); $sha.Dispose() }
}

function Get-WdmUtf8 { param([string] $Text) (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text) }

function Write-WdmFileAtomic {
    param([string] $Path, [byte[]] $Bytes)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.wdb-tmp"
    [IO.File]::WriteAllBytes($tmp, $Bytes)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    Move-Item -LiteralPath $tmp -Destination $Path
}

function Test-WdmReparsePoint {
    param([string] $Path)
    $i = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return [bool] ($i -and ($i.Attributes -band [IO.FileAttributes]::ReparsePoint))
}

<# Relative package path: "/" separators, no drive, no "..", no reserved characters. #>
function Test-WdmRelativePath {
    param([string] $Path)
    if (-not $Path -or $Path.Length -gt 240 -or $Path.StartsWith('/') -or $Path.Contains('\') -or $Path -match '^[A-Za-z]:') { return $false }
    foreach ($s in $Path.Split('/')) { if (-not $s -or $s -eq '.' -or $s -eq '..' -or $s -match '[<>:"|?*\x00-\x1f]') { return $false } }
    return $true
}

<# Copies one file through a temporary name, then compares the SHA-256 of source and copy. #>
function Copy-WdmVerifiedFile {
    param([string] $Source, [string] $Destination, [string] $ExpectedSha256 = '')
    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $want = $(if ($ExpectedSha256) { $ExpectedSha256 } else { Get-WdmFileSha256 $Source })
    if ((Test-Path -LiteralPath $Destination -PathType Leaf) -and (Get-Item -LiteralPath $Destination -Force).Length -eq (Get-Item -LiteralPath $Source -Force).Length -and (Get-WdmFileSha256 $Destination) -eq $want) {
        return @{ Copied = $false; Sha256 = $want }
    }
    $tmp = "$Destination.wdb-tmp"
    Copy-Item -LiteralPath $Source -Destination $tmp -Force
    if ((Get-WdmFileSha256 $tmp) -ne $want) { Remove-Item -LiteralPath $tmp -Force; throw "Verification failed after copying $(Split-Path -Leaf $Destination)." }
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
    Move-Item -LiteralPath $tmp -Destination $Destination
    return @{ Copied = $true; Sha256 = $want }
}

# ------------------------------------------------------------------------------------------------
# Disks: identity and safety rules
# ------------------------------------------------------------------------------------------------

<# Identity of a physical disk, independent of its number and drive letters. #>
function Get-WdmDiskFingerprint {
    param([hashtable] $Disk)
    (Get-WdmSha256Bytes (Get-WdmUtf8 ("{0}|{1}|{2}|{3}" -f $Disk.UniqueId, $Disk.SerialNumber, $Disk.Model, $Disk.Size))).Substring(0, 16)
}

function Test-WdmVentoy {
    param([hashtable] $Disk)
    [bool] @($Disk.Partitions | Where-Object { $_.Label -match '^(Ventoy|VTOYEFI)$' -or ($_.Root -and (Test-Path -LiteralPath (Join-Path $_.Root 'ventoy'))) }).Count
}

<#
    Whether a disk may be a target. Update (add files) and Create (erase) have separate rules; Create
    is restricted to positively identified removable USB flash drives. Returns
    @{ Update = @{ Allowed; Reasons }; Create = @{ Allowed; Reasons }; Warnings }.
#>
function Test-WdmDiskEligibility {
    param([hashtable] $Disk, [object[]] $AllDisks = @(), [string] $SystemLetter = '')
    if (-not $SystemLetter) { $SystemLetter = Get-WdmSystemDriveLetter }
    $u = New-Object System.Collections.Generic.List[string]
    $c = New-Object System.Collections.Generic.List[string]
    $w = New-Object System.Collections.Generic.List[string]
    $letters = @($Disk.Partitions | Where-Object { $_.DriveLetter } | ForEach-Object { ([string] $_.DriveLetter).ToUpperInvariant() })
    $hostsWindows = $Disk.IsSystem -or $Disk.IsBoot -or ($letters -contains $SystemLetter) -or @($Disk.Partitions | Where-Object { $_.IsBootPartition }).Count
    if ($hostsWindows) { $u.Add('it holds the running Windows or its boot partition'); $c.Add('it holds the running Windows or its boot partition') }
    if ($Disk.IsReadOnly) { $u.Add('it is read-only'); $c.Add('it is read-only') }
    if ($Disk.IsOffline) { $u.Add('it is offline'); $c.Add('it is offline') }
    if (Test-WdmVentoy $Disk) { $u.Add('it is a Ventoy drive (its partitions are never changed; see the Ventoy notes)'); $c.Add('it is a Ventoy drive') }
    $usb = [string] $Disk.BusType -eq 'USB'
    if (-not $usb) { $u.Add("it is not on the USB bus ($($Disk.BusType))"); $c.Add("it is not on the USB bus ($($Disk.BusType))") }
    if ([string] $Disk.MediaType -ne 'Removable Media') {
        $c.Add("it is not a removable flash drive ($(if ($Disk.MediaType) { $Disk.MediaType } else { 'media type unknown' })); external hard disks may hold valuable data and are never erased by this version")
        if ($usb) { $w.Add('External disk: only "Update deployment files" is offered; nothing is erased.') }
    }
    if ([int64] $Disk.Size -gt $script:MaxRemovableBytes) { $c.Add("it is larger than $($script:MaxRemovableBytes / 1GB) GB, which is unusual for a flash drive") }
    if ([int64] $Disk.Size -le 0) { $c.Add('its size is unknown') }
    if (-not $Disk.SerialNumber -and -not $Disk.UniqueId) { $c.Add('it reports no serial number or unique id, so it cannot be identified reliably') }
    $fp = Get-WdmDiskFingerprint $Disk
    $twins = @($AllDisks | Where-Object { $_.Number -ne $Disk.Number -and (Get-WdmDiskFingerprint $_) -eq $fp })
    if ($twins.Count) { $c.Add('another connected disk has the same identity (model, size and serial); disconnect it first') }
    elseif (@($AllDisks | Where-Object { $_.Number -ne $Disk.Number -and $_.Model -eq $Disk.Model -and $_.Size -eq $Disk.Size }).Count) { $w.Add('Another connected drive has the same model and capacity: check the serial number and disk number carefully.') }
    if (-not @($Disk.Partitions | Where-Object { $_.Root }).Count) { $u.Add('it has no volume with a drive letter') }
    @{ Update = @{ Allowed = ($u.Count -eq 0); Reasons = @($u) }; Create = @{ Allowed = ($c.Count -eq 0); Reasons = @($c) }; Warnings = @($w); Fingerprint = $fp }
}

function Format-WdmDisk {
    param([hashtable] $Disk)
    $parts = @($Disk.Partitions | ForEach-Object { "$(if ($_.DriveLetter) { "$($_.DriveLetter): " })$($_.FileSystem) '$($_.Label)' $([Math]::Round($_.Size / 1GB, 1)) GB" }) -join '; '
    "Disk $($Disk.Number): $($Disk.FriendlyName) | $($Disk.Manufacturer) $($Disk.Model) | serial $(if ($Disk.SerialNumber) { $Disk.SerialNumber } else { '(none)' }) | $([Math]::Round($Disk.Size / 1GB, 1)) GB | bus $($Disk.BusType) | $($Disk.MediaType) | $(if ($Disk.PartitionStyle) { $Disk.PartitionStyle } else { 'style ?' }) | $(if ($parts) { $parts } else { 'no partitions' })"
}

<# Finds the disk and volume of a drive letter or folder target. #>
function Resolve-WdmTarget {
    param([string] $Target, [object[]] $Disks)
    $letter = ($Target.Trim().TrimEnd('\').TrimEnd(':')).ToUpperInvariant()
    if ($letter -notmatch '^[A-Z]$') { throw "Give the USB drive as a drive letter (for example E:), not '$Target'." }
    foreach ($d in @($Disks)) {
        foreach ($p in @($d.Partitions)) { if (([string] $p.DriveLetter).ToUpperInvariant() -eq $letter) { return @{ Disk = $d; Partition = $p; Root = [string] $p.Root } } }
    }
    throw "No disk has a volume with the letter $($letter):."
}

# ------------------------------------------------------------------------------------------------
# Windows images: WIM/ESD/SWM metadata without DISM (documented WIM header + XML resource)
# ------------------------------------------------------------------------------------------------

<#
    Reads the header and the XML metadata of a WIM, ESD or the first part of a split image. The XML
    resource is stored uncompressed (UTF-16LE); its position is the resource header at offset 72 of
    the 208-byte header. Nothing is extracted and nothing needs administrator rights.
#>
function Read-WdmImageInfo {
    param([string] $Path)
    $fs = [IO.File]::OpenRead($Path)
    try {
        $br = New-Object IO.BinaryReader($fs)
        $magic = [Text.Encoding]::ASCII.GetString($br.ReadBytes(8))
        if ($magic -ne "MSWIM`0`0`0") { throw 'not a Windows image (WIM header missing; encrypted or damaged ESD files are not supported)' }
        $headerSize = $br.ReadUInt32()
        if ($headerSize -lt 148) { throw 'the image header is too short' }
        [void] $br.ReadUInt32()                      # version
        $flags = $br.ReadUInt32()
        [void] $br.ReadUInt32()                      # chunk size
        [void] $br.ReadBytes(16)                     # guid
        $part = $br.ReadUInt16(); $parts = $br.ReadUInt16(); $count = $br.ReadUInt32()
        $fs.Position = 72
        $sizeAndFlags = $br.ReadBytes(8)
        $xmlOffset = $br.ReadInt64()
        $xmlSize = $br.ReadInt64()
        $stored = [BitConverter]::ToInt64(([byte[]] ($sizeAndFlags[0..6] + 0)), 0)
        if ($xmlSize -le 0) { $xmlSize = $stored }
        if ($xmlSize -le 0 -or $xmlSize -gt $script:WdmLimits.xmlBytes -or $xmlOffset -lt $headerSize -or $xmlOffset + $xmlSize -gt $fs.Length) { throw 'the image metadata (XML) is missing or damaged' }
        $fs.Position = $xmlOffset
        $bytes = $br.ReadBytes([int] $xmlSize)
    } finally { $fs.Dispose() }
    $text = [Text.Encoding]::Unicode.GetString($bytes).TrimStart([char] 0xFEFF).TrimEnd([char] 0)
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create((New-Object IO.StringReader($text)), $settings)
    try { $doc = New-Object System.Xml.XmlDocument; $doc.XmlResolver = $null; $doc.Load($reader) } catch { throw 'the image metadata (XML) is not readable' } finally { $reader.Dispose() }
    $images = @()
    foreach ($img in @($doc.SelectNodes('/WIM/IMAGE'))) {
        $v = { param([string] $XPath) $n = $img.SelectSingleNode($XPath); if ($n) { $n.InnerText.Trim() } else { '' } }
        $arch = & $v 'WINDOWS/ARCH'
        $images += , [ordered]@{
            index = [int] $img.GetAttribute('INDEX'); name = (& $v 'NAME'); displayName = (& $v 'DISPLAYNAME'); editionId = (& $v 'WINDOWS/EDITIONID')
            architecture = $(if ($script:ArchNames.ContainsKey($arch)) { $script:ArchNames[$arch] } else { "unknown ($arch)" }); installationType = (& $v 'WINDOWS/INSTALLATIONTYPE')
            major = [int] ('0' + (& $v 'WINDOWS/VERSION/MAJOR')); build = [int] ('0' + (& $v 'WINDOWS/VERSION/BUILD')); revision = [int] ('0' + (& $v 'WINDOWS/VERSION/SPBUILD'))
            languages = @($img.SelectNodes('WINDOWS/LANGUAGES/LANGUAGE') | ForEach-Object { $_.InnerText.Trim() }); totalBytes = [int64] ('0' + (& $v 'TOTALBYTES'))
        }
    }
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    [ordered]@{ path = $Path; format = $(switch ($ext) { '.esd' { 'ESD' } '.swm' { 'SWM' } default { 'WIM' } }); size = (Get-Item -LiteralPath $Path -Force).Length
                partNumber = [int] $part; totalParts = [int] $parts; imageCount = [int] $count; flags = [int64] $flags; images = @($images) }
}

<# Windows Setup structure of a media root (USB drive, folder or mounted ISO). Reads only. #>
function Get-WdmMediaInfo {
    param([string] $Root)
    $has = { param([string] $Rel) Test-Path -LiteralPath (Join-Path $Root $Rel) }
    $info = [ordered]@{ root = $Root; isWindowsMedia = $false; setupExe = (& $has 'setup.exe'); bootWim = (& $has 'sources\boot.wim'); bootFiles = [ordered]@{}; image = $null; imageError = ''; splitParts = @()
                        answerFile = (& $has $script:AnswerFile); packageDir = (& $has $script:PackageDir); conflicts = @(); ventoy = (& $has 'ventoy'); state = $null; largeFiles = @() }
    foreach ($a in $script:BootEfi.Keys) { $info.bootFiles[$a] = (& $has $script:BootEfi[$a]) }
    $info.bootFiles['bootmgr.efi'] = (& $has 'bootmgr.efi')
    $info.bootFiles['bcd'] = (& $has 'efi\microsoft\boot\bcd')
    $img = $null
    foreach ($n in 'install.wim', 'install.esd', 'install.swm') { $p = Join-Path $Root "sources\$n"; if (Test-Path -LiteralPath $p -PathType Leaf) { $img = $p; break } }
    if ($img) {
        try { $info.image = Read-WdmImageInfo $img } catch { $info.imageError = $_.Exception.Message }
        if ($img -like '*.swm') {
            $info.splitParts = @(Get-ChildItem -LiteralPath (Join-Path $Root 'sources') -Filter 'install*.swm' -File | Sort-Object Name | ForEach-Object { $_.Name })
        }
    }
    $info.isWindowsMedia = [bool] ($info.setupExe -and $info.bootWim -and $img)
    foreach ($c in 'sources\ei.cfg', 'sources\pid.txt') { if (& $has $c) { $info.conflicts += "$c can force the edition or product key Windows Setup uses; it conflicts with the answer file's edition." } }
    if (& $has 'unattend.xml') { $info.conflicts += 'unattend.xml at the root is not read by Windows Setup from removable media (only autounattend.xml); it is probably left over.' }
    if (Test-Path -LiteralPath (Join-Path $Root 'sources\$OEM$')) { $info.conflicts += 'sources\$OEM$ copies extra files during Setup; check that it belongs to this deployment.' }
    $state = Join-Path $Root $script:StateFile
    if (Test-Path -LiteralPath $state) { try { $info.state = Read-WdmJsonFile $state } catch { $info.state = @{ status = 'Unreadable' } } }
    $info.largeFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt $script:Fat32MaxFile } | ForEach-Object { $_.FullName.Substring($Root.TrimEnd('\').Length + 1) })
    return $info
}

# ------------------------------------------------------------------------------------------------
# Windows release freshness (cached Microsoft release information; optional online refresh)
# ------------------------------------------------------------------------------------------------

function Get-WdmReleaseInfo {
    param([switch] $Online)
    $cached = Read-WdmJsonFile $script:WdmReleaseFile
    if (-not $cached) { return @{ releases = @(); source = ''; verifiedUtc = ''; mode = 'none'; message = 'No cached release information is available; freshness cannot be confirmed.' } }
    $cached['mode'] = 'cached'
    $cached['message'] = "Cached Microsoft release information, verified $($cached['verifiedUtc'])."
    if (-not $Online) { return $cached }
    try {
        $html = Get-WdmOnlineReleasePage ([string] $cached['source'])
        $found = ConvertFrom-WdmReleasePage $html
        if (-not @($found).Count) { throw 'no release table found' }
        foreach ($r in @($cached['releases'])) {
            $f = @($found | Where-Object { $_.build -eq [int] $r['build'] } | Select-Object -First 1)
            if ($f -and $f[0].revision -gt [int] ('0' + $r['latestRevision'])) { $r['latestRevision'] = $f[0].revision; $r['latestRevisionDate'] = 'online' }
        }
        $known = @($cached['releases'] | ForEach-Object { [int] $_['build'] })
        foreach ($f in @($found | Where-Object { $_.build -notin $known -and $_.version })) { $cached['releases'] = @(@($cached['releases']) + @([ordered]@{ version = $f.version; build = $f.build; availability = $null; endHomePro = $null; endEnterpriseEducation = $null; latestRevision = $f.revision; latestRevisionDate = 'online'; note = 'Found online; not in the cached list.' })) }
        $cached['mode'] = 'online'
        $cached['message'] = "Checked online against $($cached['source']) at $((Get-WdmNow).ToString('u'))."
    } catch {
        $cached['message'] = "Online check failed ($($_.Exception.Message)); using cached information verified $($cached['verifiedUtc'])."
    }
    return $cached
}

<# "Version 25H2 (OS build 26200)" headings and the highest "26200.NNNN" build of each. #>
function ConvertFrom-WdmReleasePage {
    param([string] $Html)
    $out = @()
    foreach ($m in [regex]::Matches($Html, 'Version\s+(\d{2}H\d)\s*\(OS build\s+(\d{5})\)')) {
        $build = [int] $m.Groups[2].Value
        if (@($out | Where-Object { $_.build -eq $build }).Count) { continue }
        $rev = 0
        foreach ($r in [regex]::Matches($Html, "\b$build\.(\d{1,5})\b")) { $rev = [Math]::Max($rev, [int] $r.Groups[1].Value) }
        $out += , @{ version = $m.Groups[1].Value; build = $build; revision = $rev }
    }
    return $out
}

<# How current an image is: feature release, build, servicing level, and support status. #>
function Get-WdmFreshness {
    param($Image, $Releases, [string] $EditionId = '')
    $build = [int] $Image.build; $rev = [int] $Image.revision
    $o = [ordered]@{ version = ''; build = $build; revision = $rev; latestRevision = $null; latestRevisionDate = $null; status = 'Unknown'; message = ''; basis = [string] $Releases['message'] }
    if ($build -lt [int] ('0' + $Releases['minimumBuild']) -or $build -lt 22000) { $o.status = 'Unsupported'; $o.message = "Build $build is not Windows 11 (Windows 11 starts with build 22000)."; return $o }
    $r = @(@($Releases['releases']) | Where-Object { [int] $_['build'] -eq $build } | Select-Object -First 1)
    if (-not $r) {
        # Newest = the build of the most recently released version (build numbers are not ordered by date: 26H1 is 28000).
        $latest = @(@($Releases['releases']) | Where-Object { $_['availability'] } | Sort-Object { [string] $_['availability'] } -Descending | Select-Object -First 1)
        $newest = $(if ($latest) { [int] $latest[0]['build'] } else { 0 })
        if ($newest -and $build -gt $newest) { $o.status = 'NewerThanKnown'; $o.message = "Build $build is newer than the release information ($($Releases['message'])); its status cannot be confirmed." }
        else { $o.message = "Build $build is not in the release information; its servicing status cannot be confirmed." }
        return $o
    }
    $r = $r[0]
    $o.version = [string] $r['version']
    $o.latestRevision = $r['latestRevision']; $o.latestRevisionDate = $r['latestRevisionDate']
    $homePro = $EditionId -notmatch '^(Enterprise|Education|IoTEnterprise)'
    $end = $(if ($homePro) { [string] $r['endHomePro'] } else { [string] $r['endEnterpriseEducation'] })
    if ($end -eq 'ended') { $o.status = 'EndOfService'; $o.message = "Windows 11 $($o.version) (build $build) no longer receives updates for this edition; Windows Update will offer a newer feature update after installation. Prefer current media." }
    elseif ($r['latestRevision'] -and $rev -lt [int] $r['latestRevision']) { $o.status = 'Outdated'; $o.message = "Windows 11 $($o.version) image at $build.$rev; the latest known update is $build.$($r['latestRevision']) ($($r['latestRevisionDate'])). The Windows Update stage installs the missing updates after setup; the image itself is not fully patched." }
    else { $o.status = 'Current'; $o.message = "Windows 11 $($o.version) image at $build.$rev, the latest known update level ($($Releases['message']))." }
    if ($r['note']) { $o.message += " $($r['note'])" }
    return $o
}

# ------------------------------------------------------------------------------------------------
# Deployment package (the ZIP the website produced, or the same tree extracted)
# ------------------------------------------------------------------------------------------------

<# Same text normalisation as the deployment's Get-WddTextHash for files embedded in the answer file. #>
function Get-WdmTextHash { param([string] $Text) Get-WdmSha256Bytes (Get-WdmUtf8 ($Text.TrimStart([char] 0xFEFF).Replace("`r`n", "`n").Replace("`r", "`n").Trim())) }

function Read-WdmXmlDocument {
    param([string] $Path)
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($Path, $settings)
    try { $doc = New-Object System.Xml.XmlDocument; $doc.XmlResolver = $null; $doc.PreserveWhitespace = $true; $doc.Load($reader); return $doc } finally { $reader.Dispose() }
}

<#
    Validates a deployment package without running anything in it and stages a verified copy in a
    new folder under the assistant's state folder. Returns
      @{ Ok; Problems; Warnings; Manifest; Media; Staging; AnswerFile; PackageSha256; Bytes; Requirements }
#>
function Read-WdmPackage {
    param([string] $Path)
    $problems = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $res = @{ Ok = $false; Problems = $problems; Warnings = $warnings; Manifest = $null; Media = $null; Staging = ''; AnswerFile = ''; PackageSha256 = ''; Bytes = 0; Requirements = $null; Source = $Path }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { $problems.Add("Deployment package not found: $Path"); return $res }
    $staging = Join-Path (Join-Path (Get-WdmStateRoot) 'staging') ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    $res.Staging = $staging
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $res.PackageSha256 = Get-WdmFileSha256 $Path
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        try { $zip = [System.IO.Compression.ZipFile]::OpenRead($Path) } catch { $problems.Add('The package is not a readable ZIP file.'); return $res }
        try {
            $entries = @($zip.Entries)
            if ($entries.Count -gt $script:WdmLimits.zipEntries) { $problems.Add("The package has $($entries.Count) entries; at most $($script:WdmLimits.zipEntries) are accepted."); return $res }
            $sum = 0
            foreach ($e in $entries) {
                $n = $e.FullName.Replace('\', '/')
                if ($n.EndsWith('/')) { continue }
                if (-not (Test-WdmRelativePath $n)) { $problems.Add("Unsafe entry in the package: $n"); return $res }
                if ($n -notmatch '^[^/]+\.xml$' -and $n -notmatch "^$($script:PackageDir)/") { $problems.Add("Unexpected entry in the package: $n (only the answer file and $($script:PackageDir)\ belong in it)"); return $res }
                $sum += $e.Length
                if ($sum -gt $script:WdmLimits.zipBytes) { $problems.Add('The package expands to more than the size limit.'); return $res }
            }
            foreach ($e in $entries) {
                $n = $e.FullName.Replace('\', '/')
                if ($n.EndsWith('/')) { continue }
                $dst = [IO.Path]::GetFullPath((Join-Path $staging ($n -replace '/', '\')))
                if (-not $dst.StartsWith($staging.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { $problems.Add("Entry leaves the staging folder: $($e.FullName)"); return $res }
                New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dst, $false)
            }
        } finally { $zip.Dispose() }
    } else {
        foreach ($f in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue)) {
            if ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) { $problems.Add("Link inside the package folder: $($f.Name)"); return $res }
        }
        if (Test-Path -LiteralPath (Join-Path $Path $script:AnswerFile)) { Copy-Item -LiteralPath (Join-Path $Path $script:AnswerFile) -Destination $staging }
        $src = Join-Path $Path $script:PackageDir
        if (Test-Path -LiteralPath $src) {
            foreach ($f in @(Get-ChildItem -LiteralPath $src -Recurse -File -Force)) {
                $rel = $f.FullName.Substring($src.TrimEnd('\').Length + 1)
                if ($rel -like 'backups\*') { continue }
                $dst = Join-Path (Join-Path $staging $script:PackageDir) $rel
                New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
                Copy-Item -LiteralPath $f.FullName -Destination $dst
            }
        }
    }
    $mPath = Join-Path $staging "$($script:PackageDir)\deployment-manifest.json"
    try { $m = Read-WdmJsonFile $mPath $script:WdmLimits.manifestBytes } catch { $problems.Add('The deployment manifest is not valid JSON.'); return $res }
    if (-not $m) { $problems.Add("$($script:PackageDir)\deployment-manifest.json is missing: this is not a Windows Deployment Builder package."); return $res }
    if ($m['format'] -ne $script:ManifestFormat) { $problems.Add('Not a Windows Deployment Builder deployment manifest.'); return $res }
    if ("$($m['manifestVersion'])" -ne '1') { $problems.Add("Unsupported manifest version $($m['manifestVersion']) (this assistant reads version 1)."); return $res }
    if ([string] $m['packageId'] -notmatch $script:WdmHexId) { $problems.Add('The manifest has no valid package id.'); return $res }
    if ([string] $m['scope'] -ne 'package') { $problems.Add("This manifest describes '$($m['scope'])', not a full package."); return $res }
    $res.Manifest = $m
    $listed = @{ ("$($script:PackageDir)/deployment-manifest.json").ToLowerInvariant() = $true }
    foreach ($f in @($m['files'])) {
        $rel = [string] $f['path']
        if (-not (Test-WdmRelativePath $rel) -or [string] $f['sha256'] -notmatch $script:WdmSha256) { $problems.Add("The manifest lists an unsafe path or an invalid hash: $rel"); continue }
        $listed[("$($script:PackageDir)/$rel").ToLowerInvariant()] = $true
        $p = Join-Path $staging ("$($script:PackageDir)\" + ($rel -replace '/', '\'))
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $problems.Add("Missing from the package: $rel"); continue }
        if ((Get-WdmFileSha256 $p) -ne [string] $f['sha256']) { $problems.Add("Modified or damaged: $rel (SHA-256 does not match the manifest)") }
    }
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $staging $script:PackageDir) -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = ($f.FullName.Substring($staging.TrimEnd('\').Length + 1) -replace '\\', '/').ToLowerInvariant()
        if (-not $listed.ContainsKey($rel)) { $problems.Add("Unexpected file in the package (not in the manifest): $rel") }
        $res.Bytes += $f.Length
    }
    $answerName = $(if ($m['answerFile'] -and $m['answerFile']['fileName']) { [string] $m['answerFile']['fileName'] } else { $script:AnswerFile })
    $answer = Join-Path $staging $answerName
    $xmls = @(Get-ChildItem -LiteralPath $staging -Filter '*.xml' -File)
    if ($xmls.Count -ne 1 -or -not (Test-Path -LiteralPath $answer -PathType Leaf)) { $problems.Add("The package must contain exactly one answer file at its root ($answerName).") }
    elseif ($answerName -ne $script:AnswerFile) { $problems.Add("The answer file is named $answerName; Windows Setup only finds $($script:AnswerFile) on a USB drive. Choose autounattend.xml under Output and download the package again.") }
    else {
        $res.AnswerFile = $answer
        $res.Bytes += (Get-Item -LiteralPath $answer).Length
        $media = $(if ($m.Contains('media')) { $m['media'] } else { $null })
        $res.Media = $media
        if ($media -and $media['answerFile']) {
            if ((Get-WdmFileSha256 $answer) -ne [string] $media['answerFile']['sha256']) { $problems.Add('The answer file does not match the SHA-256 in the manifest (modified after it was generated).') }
        } else { $warnings.Add('This package was made before Phase 7: the answer file is not hash-pinned, so only its embedded scripts are verified. Download the package again for full verification.') }
        # The scripts embedded in the answer file must be exactly the manifest's files.
        try {
            $doc = Read-WdmXmlDocument $answer
            $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
            $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
            $embedded = @{}
            foreach ($e in @($doc.SelectNodes('/u:unattend/*[local-name()="Extensions"]/*[local-name()="File"]', $ns))) { $embedded[([string] $e.GetAttribute('path')).ToLowerInvariant()] = $e.InnerText }
            $runtime = $null
            foreach ($f in @($m['files'] | Where-Object { $_['embedded'] })) {
                $key = ("C:\Windows\Setup\Scripts\$($f['embedded'])").ToLowerInvariant()
                if (-not $embedded.ContainsKey($key)) { $problems.Add("The answer file does not carry $($f['path'])."); continue }
                if ($f['textSha256'] -and (Get-WdmTextHash $embedded[$key]) -ne [string] $f['textSha256']) { $problems.Add("The answer file's copy of $($f['path']) differs from the package.") }
            }
            $rk = 'c:\windows\setup\scripts\deployment\deployment-manifest.json'
            if ($embedded.ContainsKey($rk)) {
                try { $runtime = ConvertTo-WdmHashtable ($embedded[$rk] | ConvertFrom-Json) } catch { }
                if (-not $runtime -or [string] $runtime['packageId'] -ne [string] $m['packageId']) { $problems.Add('The answer file belongs to a different deployment package (package id differs).') }
            } elseif (@($m['files'] | Where-Object { $_['embedded'] }).Count) { $problems.Add('The answer file carries no deployment manifest.') }
        } catch { $problems.Add("The answer file is not well-formed XML ($($_.Exception.Message.Split("`n")[0])).") }
    }
    # What the media must provide.
    $req = [ordered]@{ editionMode = [string] $m['windows']['editionMode']; dismEditionId = ''; editionName = [string] $m['windows']['edition']; architectures = @($m['windows']['architectures']); minimumBuild = 22000 }
    if ($res.Media -and $res.Media['requirements']) {
        $r = $res.Media['requirements']
        $req.dismEditionId = [string] $r['dismEditionId']; $req.editionName = [string] $r['editionName']; $req.architectures = @($r['architectures']); $req.minimumBuild = [int] $r['minimumBuild']
    } elseif ($req.editionMode -eq 'genericKey' -and $script:EditionNames.ContainsKey($req.editionName)) { $req.dismEditionId = $script:EditionNames[$req.editionName] }
    $res.Requirements = $req
    $res.Backup = $null
    if ($m.Contains('migration') -and $m['migration'] -and $m['migration']['settingsRestore']) {
        $sr = $m['migration']['settingsRestore']
        $res.Backup = @{ backupId = [string] $sr['backupId']; manifestSha256 = [string] $sr['manifestSha256']; folderName = [string] $sr['folderName'] }
        if ($res.Backup.folderName -notmatch '^[A-Za-z0-9._-]{1,80}$' -or $res.Backup.manifestSha256 -notmatch $script:WdmSha256) { $problems.Add('The settings restore reference in the manifest is invalid.') }
    }
    $res.Ok = ($problems.Count -eq 0)
    return $res
}

<# The edition, architecture and build checks between a package and a Windows image. #>
function Test-WdmCompatibility {
    param($Requirements, $Image, $Releases)
    $blockers = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $sel = $null
    if (-not $Image) { $blockers.Add('No readable Windows image (sources\install.wim, install.esd or install.swm).'); return @{ Blockers = $blockers; Warnings = $warnings; Selected = $null; Freshness = $null } }
    $imgs = @($Image.images | Where-Object { $_['installationType'] -ne 'WindowsPE' })
    $archOk = @($imgs | Where-Object { $_.architecture -in @($Requirements.architectures) })
    if (-not $archOk.Count) { $blockers.Add("The image is $((@($imgs | ForEach-Object { $_.architecture }) | Select-Object -Unique) -join '/'), but the deployment is for $(@($Requirements.architectures) -join '/').") }
    if ($Requirements.dismEditionId) {
        $match = @($archOk | Where-Object { $_.editionId -eq $Requirements.dismEditionId })
        if (-not $match.Count) {
            $blockers.Add("The deployment installs $($Requirements.editionName) (EditionId $($Requirements.dismEditionId)), which this media does not contain. Available: $((@($imgs | ForEach-Object { "$($_.name) [$($_.editionId)]" })) -join ', '). Use media that contains it; the edition is never changed silently.")
        } else {
            $sel = $match[0]
            if ($match.Count -gt 1) { $warnings.Add("$($match.Count) images have EditionId $($Requirements.dismEditionId) (indexes $(@($match | ForEach-Object { $_.index }) -join ', ')); Windows Setup picks one by the generic key: index $($sel.index) '$($sel.name)' is assumed.") }
        }
    } else {
        $sel = @($archOk | Select-Object -First 1)[0]
        $warnings.Add($(switch ($Requirements.editionMode) { 'interactive' { 'The edition is chosen during Windows Setup (interactive); every edition on the media is offered.' } 'firmware' { 'The edition follows the key in the computer''s firmware; make sure the media contains it.' } 'customKey' { 'A custom product key selects the edition; this media is not checked against it.' } default { 'The required edition is not stated in this package; the media was not checked against it.' } }))
    }
    $fresh = $null
    if ($sel) {
        if ($sel.build -lt [int] $Requirements.minimumBuild) { $blockers.Add("The image is build $($sel.build); Windows 11 (build $($Requirements.minimumBuild) or later) is required.") }
        $fresh = Get-WdmFreshness $sel $Releases $sel.editionId
        if ($fresh.status -eq 'Unsupported') { $blockers.Add($fresh.message) }
        elseif ($fresh.status -ne 'Current') { $warnings.Add($fresh.message) }
    }
    @{ Blockers = $blockers; Warnings = $warnings; Selected = $sel; Freshness = $fresh }
}

<# Validates the Phase 6 settings backup pinned by the package (the assistant's own copy of WdbMigration.ps1). #>
function Open-WdmBackup {
    param($Pinned, [string] $Path)
    $r = @{ Ok = $false; Problems = @(); Validated = $null; Bytes = 0 }
    if (-not (Get-Command Open-WdbBackup -CommandType Function -ErrorAction SilentlyContinue)) { $r.Problems = @('WdbMigration.ps1 must be next to this assistant to verify the settings backup.'); return $r }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { $r.Problems = @("Settings backup not found: $Path"); return $r }
    if ((Test-Path -LiteralPath $Path -PathType Container) -and (Split-Path -Leaf $Path.TrimEnd('\')) -ne $Pinned.folderName) {
        $r.Problems = @("The backup folder is named '$(Split-Path -Leaf $Path.TrimEnd('\'))'; this deployment expects '$($Pinned.folderName)'. Choose the backup made for this customer.")
        return $r
    }
    try { $v = Open-WdbBackup $Path (Join-Path (Get-WdmStateRoot) 'staging') $Pinned.manifestSha256 } catch { $r.Problems = @("The backup could not be opened: $($_.Exception.Message)"); return $r }
    if (-not $v.Ok) { $r.Problems = @($v.Problems | ForEach-Object { "Settings backup: $_" }); return $r }
    if ([string] $v.Manifest['backupId'] -ne $Pinned.backupId -or [string] $v.Manifest['folderName'] -ne $Pinned.folderName) { $r.Problems = @('The backup id or folder name does not match the deployment.'); return $r }
    $r.Ok = $true; $r.Validated = $v
    $r.Bytes = [int64] (@(Get-ChildItem -LiteralPath $v.Root -Recurse -File -Force | Measure-Object -Property Length -Sum).Sum)
    return $r
}

# ------------------------------------------------------------------------------------------------
# Plan
# ------------------------------------------------------------------------------------------------

function Get-WdmTreeSize { param([string] $Root, [string[]] $Skip = @()) [int64] ((@(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName.Substring($Root.TrimEnd('\').Length + 1).ToLowerInvariant() -notin $Skip }) | Measure-Object -Property Length -Sum).Sum) }

<#
    Builds a plan. Nothing is changed. -Workflow Update needs -Target (drive letter of an existing
    Windows USB); Create needs -Iso and -Disk. Blockers stop Apply; warnings are shown.
#>
function New-WdmPlan {
    param([ValidateSet('Update', 'Create')] [string] $Workflow, [string] $PackagePath, [string] $BackupPath = '', [string] $TargetLetter = '', [string] $IsoPath = '', [int] $DiskNumber = -1,
          [switch] $Replace, [switch] $NoData, [string] $ExpectedIsoSha256 = '', [switch] $Online)
    $blockers = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $ops = New-Object System.Collections.Generic.List[object]
    Write-WdmProgress 'Plan' 'Validating the deployment package'
    $pkg = Read-WdmPackage $PackagePath
    foreach ($p in $pkg.Problems) { $blockers.Add($p) }
    foreach ($w in $pkg.Warnings) { $warnings.Add($w) }
    $backup = $null
    if ($pkg.Ok -and $pkg.Backup) {
        Write-WdmProgress 'Plan' 'Validating the settings backup'
        if (-not $BackupPath) { $blockers.Add("This deployment restores application settings from backup $($pkg.Backup.folderName); choose that backup folder (-Backup).") }
        else { $backup = Open-WdmBackup $pkg.Backup $BackupPath; foreach ($p in $backup.Problems) { $blockers.Add($p) } }
    } elseif ($BackupPath) { $warnings.Add('A backup was given, but this deployment does not restore settings; it is not copied.') }
    $releases = Get-WdmReleaseInfo -Online:$Online
    $disks = @(Get-WdmDisks)
    $target = [ordered]@{}
    $media = $null; $imageFile = ''; $windowsBytes = [int64] 0; $split = $false; $export = $false; $source = $null; $layout = $null
    if ($Workflow -eq 'Update') {
        try { $t = Resolve-WdmTarget $TargetLetter $disks } catch { $blockers.Add($_.Exception.Message); $t = $null }
        if ($t) {
            $el = Test-WdmDiskEligibility $t.Disk $disks
            if (-not $el.Update.Allowed) { $blockers.Add("Disk $($t.Disk.Number) cannot be used: $($el.Update.Reasons -join '; ').") }
            foreach ($w in $el.Warnings) { $warnings.Add($w) }
            $target = [ordered]@{ diskNumber = $t.Disk.Number; fingerprint = $el.Fingerprint; description = (Format-WdmDisk $t.Disk); driveLetter = [string] $t.Partition.DriveLetter; root = $t.Root; fileSystem = [string] $t.Partition.FileSystem; label = [string] $t.Partition.Label; size = [int64] $t.Disk.Size; free = $(try { [int64] (Get-WdmFreeSpace $t.Root) } catch { 0 }) }
            $media = Get-WdmMediaInfo $t.Root
            if (-not $media.isWindowsMedia) { $blockers.Add("$($t.Root) is not a Windows installation drive (setup.exe, sources\boot.wim and an install image are required). Use 'Create from an ISO' instead.") }
            if ($media.imageError) { $blockers.Add("The Windows image on the drive cannot be read: $($media.imageError)") }
            if ($media.ventoy) { $blockers.Add('This is a Ventoy drive: Windows Setup started from an ISO inside Ventoy does not see files placed next to it, so this deployment would not run. Use a standard Windows USB.') }
            foreach ($c in $media.conflicts) { $warnings.Add($c) }
            if ($media.state -and [string] $media.state['status'] -eq 'InProgress') { $warnings.Add('A previous preparation of this drive did not finish; this run repairs it.') }
            if ($target.fileSystem -notin 'FAT32', 'NTFS', 'exFAT') { $warnings.Add("File system $($target.fileSystem): UEFI firmware normally boots FAT32 Windows media only.") }
            elseif ($target.fileSystem -eq 'NTFS') { $warnings.Add('The drive is NTFS (for example made with Rufus): booting depends on its UEFI:NTFS helper partition. Secure Boot may need to accept it; nothing about the boot files is changed here.') }
            elseif ($target.fileSystem -eq 'exFAT') { $warnings.Add('exFAT Windows media boots only on firmware that reads exFAT; FAT32 is the safe choice.') }
            if ($media.answerFile -or $media.packageDir) {
                $old = $(try { Read-WdmJsonFile (Join-Path $t.Root "$($script:PackageDir)\deployment-manifest.json") } catch { $null })
                $oldId = $(if ($old) { [string] $old['packageId'] } else { 'unknown' })
                $target.existingPackageId = $oldId
                if ($pkg.Manifest -and $oldId -eq [string] $pkg.Manifest['packageId']) { $warnings.Add("The drive already has this deployment ($oldId); its files are checked and only missing or damaged ones are written.") }
                elseif (-not $Replace) { $blockers.Add("The drive already has a deployment ($oldId). Run again with 'replace' (-ReplaceExisting): the current answer file and WindowsDeployment folder are moved to $($script:PreviousDir)\<time>\, never deleted; deployments are never merged.") }
                else { $ops.Add([ordered]@{ id = 'keepPrevious'; kind = 'keepPrevious'; destructive = $false; description = "Move the existing autounattend.xml and WindowsDeployment ($oldId) to $($script:PreviousDir)\<time>\ (kept, not deleted)"; bytes = 0 }) }
            }
            if ($media.image) { $source = $media }
        }
    } else {
        if (-not $IsoPath -or -not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) { $blockers.Add("Windows ISO not found: $IsoPath. Download it from https://www.microsoft.com/software-download/windows11.") }
        else {
            $isoItem = Get-Item -LiteralPath $IsoPath
            $iso = [ordered]@{ path = $isoItem.FullName; size = $isoItem.Length; lastWriteUtc = $isoItem.LastWriteTimeUtc.ToString('o'); sha256 = ''; sha256Expected = $ExpectedIsoSha256.ToUpperInvariant(); provenance = '' }
            if ($ExpectedIsoSha256) {
                Write-WdmProgress 'Plan' 'Computing the SHA-256 of the ISO'
                $iso.sha256 = Get-WdmFileSha256 $isoItem.FullName
                if ($iso.sha256 -ne $iso.sha256Expected) { $blockers.Add('The ISO does not match the SHA-256 you entered (Microsoft lists the hashes on its download page). Download it again.') } else { $iso.provenance = 'SHA-256 matches the hash you entered.' }
            } else { $iso.provenance = 'Not established: no SHA-256 was entered. The signatures of setup.exe and the UEFI boot loader are checked instead.' }
            try { $isoRoot = Mount-WdmIso $isoItem.FullName } catch { $blockers.Add("The ISO could not be mounted read-only: $($_.Exception.Message)"); $isoRoot = '' }
            if ($isoRoot) {
                try {
                    $media = Get-WdmMediaInfo $isoRoot
                    if (-not $media.isWindowsMedia) { $blockers.Add('The ISO is not Windows installation media.') }
                    if ($media.imageError) { $blockers.Add("The Windows image in the ISO cannot be read: $($media.imageError)") }
                    foreach ($c in $media.conflicts) { $warnings.Add($c) }
                    foreach ($f in 'setup.exe', 'efi\boot\bootx64.efi', 'efi\boot\bootaa64.efi') {
                        $p = Join-Path $isoRoot $f
                        if (-not (Test-Path -LiteralPath $p)) { continue }
                        $s = Get-WdmSignature $p
                        $iso["signature:$f"] = "$($s.Status) $($s.Signer)".Trim()
                        if ($s.Status -ne 'Valid' -or $s.Signer -notmatch 'O=Microsoft Corporation') { $blockers.Add("$f is not validly signed by Microsoft ($($s.Status)); the ISO is not used.") }
                    }
                    $imageFile = $(if ($media.image) { [string] $media.image.path } else { '' })
                    $skip = @()
                    if ($imageFile) { $skip = @(('sources\' + (Split-Path -Leaf $imageFile)).ToLowerInvariant()) }
                    $windowsBytes = Get-WdmTreeSize $isoRoot $skip
                    foreach ($lf in @($media.largeFiles | Where-Object { $_.ToLowerInvariant() -notin $skip })) { $blockers.Add("$lf is larger than 4 GB and cannot be stored on FAT32.") }
                    if ($media.image) {
                        $windowsBytes += [int64] $media.image.size
                        if ($media.image.size -gt $script:Fat32MaxFile) { if ($media.image.format -eq 'ESD') { $export = $true }; $split = $true }
                    }
                    $source = $media
                } finally { Dismount-WdmIso $isoItem.FullName }
            }
            $target.iso = $iso
        }
        $d = @($disks | Where-Object { $_.Number -eq $DiskNumber })
        if ($DiskNumber -lt 0 -or -not $d) { $blockers.Add('Choose the USB flash drive to erase by its disk number (-Disk; see Discover). No disk is ever chosen automatically.') }
        else {
            $d = $d[0]
            $el = Test-WdmDiskEligibility $d $disks
            if (-not $el.Create.Allowed) { $blockers.Add("Disk $($d.Number) cannot be erased: $($el.Create.Reasons -join '; ').") }
            foreach ($w in $el.Warnings) { $warnings.Add($w) }
            $bootBytes = [int64] [Math]::Min([int64] $d.Size - 8MB, $script:Fat32MaxVolume)
            $data = (-not $NoData) -and ([int64] $d.Size - $bootBytes -gt 1GB)
            $layout = [ordered]@{ partitionStyle = 'MBR'; partitions = @([ordered]@{ label = 'WDB-BOOT'; fileSystem = 'FAT32'; bytes = $bootBytes; active = $true }) + @(if ($data) { [ordered]@{ label = 'WDB-DATA'; fileSystem = 'NTFS'; bytes = [int64] $d.Size - $bootBytes; active = $false } }) }
            $target.diskNumber = $d.Number; $target.fingerprint = $el.Fingerprint; $target.description = Format-WdmDisk $d; $target.size = [int64] $d.Size; $target.free = $bootBytes
            $target.existingVolumes = @($d.Partitions | ForEach-Object { "$(if ($_.DriveLetter) { "$($_.DriveLetter): " })$($_.FileSystem) '$($_.Label)' $([Math]::Round($_.Size / 1GB, 1)) GB" })
            $target.confirmCode = "ERASE-$($d.Number)-$($el.Fingerprint.Substring(0, 6))"
            $ops.Add([ordered]@{ id = 'partition'; kind = 'partition'; destructive = $true; description = "ERASE disk $($d.Number) ($($d.Model), $([Math]::Round($d.Size / 1GB, 1)) GB): every partition and file on it is deleted; create MBR, FAT32 'WDB-BOOT' $([Math]::Round($bootBytes / 1GB, 1)) GB (active)$(if ($data) { ", NTFS 'WDB-DATA' for the remaining $([Math]::Round(([int64] $d.Size - $bootBytes) / 1GB, 1)) GB" })"; bytes = 0 })
            $ops.Add([ordered]@{ id = 'copyWindows'; kind = 'copyWindows'; destructive = $false; description = "Copy the Windows Setup files from the ISO (boot files unchanged)$(if ($split) { ', except the install image' })"; bytes = $windowsBytes })
            if ($export) { $ops.Add([ordered]@{ id = 'exportImage'; kind = 'exportImage'; destructive = $false; description = 'Export the selected edition from install.esd to a WIM with DISM (an ESD cannot be split)'; bytes = 0 }) }
            if ($split) { $ops.Add([ordered]@{ id = 'splitImage'; kind = 'splitImage'; destructive = $false; description = "Split the install image over 4 GB into sources\install.swm parts of $($script:SplitSizeMB) MB with DISM (integrity checked)"; bytes = 0 }) }
        }
    }
    $compat = Test-WdmCompatibility $(if ($pkg.Requirements) { $pkg.Requirements } else { @{ architectures = @(); dismEditionId = ''; editionMode = ''; minimumBuild = 22000 } }) $(if ($source) { $source.image } else { $null }) $releases
    if ($pkg.Ok) { foreach ($b in $compat.Blockers) { $blockers.Add($b) } }
    foreach ($w in $compat.Warnings) { $warnings.Add($w) }
    if ($source -and $compat.Selected) {
        $bootFile = $script:BootEfi[[string] $compat.Selected.architecture]
        if ($bootFile -and -not $source.bootFiles[[string] $compat.Selected.architecture]) { $blockers.Add("The media has no UEFI boot loader for $($compat.Selected.architecture) ($bootFile).") }
    }
    $ops.Add([ordered]@{ id = 'placePackage'; kind = 'placePackage'; destructive = $false; description = "Copy $($script:PackageDir)\ (package $(if ($pkg.Manifest) { $pkg.Manifest['packageId'] })) to the drive root, verified against its manifest"; bytes = $pkg.Bytes })
    if ($backup -and $backup.Ok) { $ops.Add([ordered]@{ id = 'placeBackup'; kind = 'placeBackup'; destructive = $false; description = "Copy settings backup $($pkg.Backup.folderName) to $($script:PackageDir)\backups\ (personal data: keep the drive private)"; bytes = $backup.Bytes }) }
    $ops.Add([ordered]@{ id = 'placeAnswerFile'; kind = 'placeAnswerFile'; destructive = $false; description = "Write $($script:AnswerFile) to the drive root (last, so a drive is never half-configured)"; bytes = 0 })
    $ops.Add([ordered]@{ id = 'verify'; kind = 'verify'; destructive = $false; description = 'Verify every written file and write the readiness report'; bytes = 0 })
    $needed = [int64] 0
    foreach ($o in $ops) { $needed += [int64] $o['bytes'] }
    $needed = [int64] ($needed * 1.05) + 64MB
    $avail = $(if ($target.Contains('free')) { [int64] $target.free } else { 0 })
    if ($Workflow -eq 'Update' -and $media -and $media.packageDir) { $avail += [int64] (Get-WdmTreeSize (Join-Path $target.root $script:PackageDir)) }
    if ($avail -and $needed -gt $avail) { $blockers.Add("Not enough space: $([Math]::Round($needed / 1MB)) MB needed, $([Math]::Round($avail / 1MB)) MB available.") }
    if ($pkg.Backup) { $warnings.Add('The drive will contain a settings backup (personal configuration data). Keep it private and delete the backup folder when the computer is set up.') }
    if ($pkg.Manifest -and $pkg.Manifest['answerFile'] -and $pkg.Manifest['answerFile']['containsSecrets']) { $warnings.Add('The answer file contains the account or Wi-Fi password. Keep the drive private and delete autounattend.xml after installing.') }
    $planId = (Get-WdmSha256Bytes (Get-WdmUtf8 ("$Workflow|$($pkg.PackageSha256)|$($target['fingerprint'])|$((Get-WdmNow).Ticks)|$([Guid]::NewGuid())"))).Substring(0, 16)
    $imageInfo = $null
    if ($source -and $source.image) {
        $editions = New-Object System.Collections.Generic.List[string]
        foreach ($im in @($source.image.images)) { $editions.Add(("{0}: {1} [{2}, {3}, {4}.{5}]" -f $im['index'], $im['name'], $im['editionId'], $im['architecture'], $im['build'], $im['revision'])) }
        $imageInfo = [ordered]@{ file = (Split-Path -Leaf ([string] $source.image.path)); format = [string] $source.image.format; size = [int64] $source.image.size; split = $split; export = $export; selected = $compat.Selected; editions = @($editions) }
    }
    # Values first: Windows PowerShell 5.1 fails ("Argument types do not match") on if-expressions inside large [ordered] literals.
    $pkgId = ''; $pkgVersion = ''
    if ($pkg.Manifest) { $pkgId = [string] $pkg.Manifest['packageId']; $pkgVersion = [string] $pkg.Manifest['packageVersion'] }
    $packageInfo = [ordered]@{}
    $packageInfo.path = $PackagePath; $packageInfo.sha256 = $pkg.PackageSha256; $packageInfo.packageId = $pkgId; $packageInfo.packageVersion = $pkgVersion; $packageInfo.bytes = $pkg.Bytes; $packageInfo.requirements = $pkg.Requirements
    $backupInfo = $null
    if ($pkg.Backup) {
        $backupInfo = [ordered]@{}
        $backupInfo.path = $BackupPath; $backupInfo.backupId = $pkg.Backup.backupId; $backupInfo.manifestSha256 = $pkg.Backup.manifestSha256; $backupInfo.folderName = $pkg.Backup.folderName
        $backupInfo.bytes = [int64] 0
        if ($backup) { $backupInfo.bytes = [int64] $backup.Bytes }
    }
    $plan = [ordered]@{}
    $plan.format = $script:PlanFormat; $plan.formatVersion = 1; $plan.planId = $planId; $plan.createdUtc = (Get-WdmNow).ToString('o'); $plan.tool = $script:WdmVersion; $plan.workflow = $Workflow
    $plan.package = $packageInfo
    $plan.backup = $backupInfo
    $plan.target = $target
    $plan.image = $imageInfo
    $plan.freshness = $compat.Freshness
    $plan.layout = $layout
    $plan.operations = $ops.ToArray(); $plan.requiredBytes = $needed; $plan.availableBytes = $avail
    $plan.blockers = $blockers.ToArray(); $plan.warnings = @($warnings.ToArray() | Select-Object -Unique)
    $plan.releaseInfo = [string] $releases['message']
    # Staging folders of this check are not kept; Apply validates and stages again.
    foreach ($s in @($pkg.Staging) + @(if ($backup -and $backup.Validated -and $backup.Validated.Root -like "*\staging\*") { $backup.Validated.Root })) { if ($s -and (Test-Path -LiteralPath $s)) { Remove-Item -LiteralPath $s -Recurse -Force -ErrorAction SilentlyContinue } }
    return $plan
}

function Format-WdmPlan {
    param($Plan)
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add("USB preparation plan $($Plan.planId) ($($Plan.workflow)) - nothing has been changed yet")
    $l.Add('=' * 72)
    $l.Add("Target   : $($Plan.target.description)")
    if ($Plan.target.Contains('root') -and $Plan.target.root) { $l.Add("Volume   : $($Plan.target.root) $($Plan.target.fileSystem) '$($Plan.target.label)', $([Math]::Round([int64] $Plan.target.free / 1GB, 2)) GB free") }
    if ($Plan.target.Contains('existingVolumes')) { $l.Add("Erased   : $(if (@($Plan.target.existingVolumes).Count) { @($Plan.target.existingVolumes) -join '; ' } else { 'no volumes' })") }
    $l.Add("Package  : $($Plan.package.packageId) (package $($Plan.package.packageVersion)), $($Plan.package.requirements.editionName), $(@($Plan.package.requirements.architectures) -join '/')")
    if ($Plan.image) { $l.Add("Image    : $($Plan.image.file) ($($Plan.image.format), $([Math]::Round([int64] $Plan.image.size / 1GB, 2)) GB)"); foreach ($e in $Plan.image.editions) { $l.Add("           $e") } }
    if ($Plan.image -and $Plan.image.selected) { $l.Add("Selected : index $($Plan.image.selected.index) $($Plan.image.selected.name) [$($Plan.image.selected.editionId)]") }
    if ($Plan.freshness) { $l.Add("Freshness: $($Plan.freshness.status). $($Plan.freshness.message)") }
    if ($Plan.backup) { $l.Add("Backup   : $($Plan.backup.folderName) (manifest $($Plan.backup.manifestSha256))") }
    $l.Add("Space    : $([Math]::Round([int64] $Plan.requiredBytes / 1MB)) MB needed$(if ($Plan.availableBytes) { ", $([Math]::Round([int64] $Plan.availableBytes / 1MB)) MB available" })")
    $l.Add('')
    $l.Add('Operations:')
    $i = 0
    foreach ($o in $Plan.operations) { $i++; $l.Add(("  {0}. {1}{2}" -f $i, $(if ($o.destructive) { '[ERASES DATA] ' } else { '' }), $o.description)) }
    if (@($Plan.warnings).Count) { $l.Add(''); $l.Add('Warnings:'); foreach ($w in $Plan.warnings) { $l.Add("  ! $w") } }
    if (@($Plan.blockers).Count) { $l.Add(''); $l.Add('Cannot continue:'); foreach ($b in $Plan.blockers) { $l.Add("  x $b") } }
    elseif ($Plan.workflow -eq 'Create') { $l.Add(''); $l.Add("To erase this drive, confirm with: $($Plan.target.confirmCode)") }
    return ($l -join "`r`n")
}

# ------------------------------------------------------------------------------------------------
# Apply (with a journal: restartable, never a false success)
# ------------------------------------------------------------------------------------------------

function Save-WdmJournal {
    param($Journal, [string] $MediaRoot = '')
    $Journal.updatedUtc = (Get-WdmNow).ToString('o')
    $bytes = Get-WdmUtf8 (ConvertTo-WdmJson $Journal)
    Write-WdmFileAtomic (Join-Path (Get-WdmStateRoot) "journal-$($Journal.planId).json") $bytes
    if ($MediaRoot -and (Test-Path -LiteralPath $MediaRoot)) { Write-WdmFileAtomic (Join-Path $MediaRoot $script:StateFile) $bytes }
}

<# The disk of the plan, found again by identity; throws if it is gone, renumbered or changed. #>
function Assert-WdmTarget {
    param($Plan, [string] $Purpose)
    $disks = @(Get-WdmDisks)
    $d = @($disks | Where-Object { (Get-WdmDiskFingerprint $_) -eq [string] $Plan.target.fingerprint })
    if (-not $d.Count) { throw "The planned drive ($($Plan.target.description)) is no longer connected or has changed. Nothing more was written. Plan again." }
    if ($d.Count -gt 1) { throw 'More than one connected disk has the planned identity; disconnect the other one.' }
    $d = $d[0]
    if ($d.Number -ne [int] $Plan.target.diskNumber) { throw "The planned drive is now disk $($d.Number) instead of disk $($Plan.target.diskNumber). Plan again; an outdated disk number is never used." }
    $el = Test-WdmDiskEligibility $d $disks
    if ($Purpose -eq 'Create' -and -not $el.Create.Allowed) { throw "Disk $($d.Number) can no longer be erased: $($el.Create.Reasons -join '; ')" }
    if ($Purpose -eq 'Update' -and -not $el.Update.Allowed) { throw "Disk $($d.Number) can no longer be used: $($el.Update.Reasons -join '; ')" }
    return $d
}

<#
    Carries out a plan. Everything is validated again here (package, backup, disk identity); the
    plan's own conclusions are not trusted. Returns the readiness report.
      Update: new files go to WindowsDeployment.wdb-new on the drive, are verified, then swapped in;
              the answer file is written last. An interrupted run leaves the previous deployment (or
              none), never a mixed one, and the journal marks the drive Incomplete.
      Create: needs elevation and -ConfirmErase equal to the plan's code; the erase step is never
              resumed without a new plan and confirmation.
#>
function Invoke-WdmApply {
    param($Plan, [string] $Confirm = '', [string] $IsoPath = '', [string] $BackupPath = '')
    $refuse = { param([string] $Message) $o = [ordered]@{}; $o.format = $script:ReportFormat; $o.status = 'Failed'; $o.message = "Refused: $Message Nothing was changed."; $o.planId = [string] $Plan['planId']; $o.bootTested = $false; $o }
    if ($Plan['format'] -ne $script:PlanFormat -or "$($Plan['formatVersion'])" -ne '1') { return (& $refuse 'not a USB preparation plan of this version.') }
    if (@($Plan.blockers).Count) { return (& $refuse "the plan has blockers; fix them and plan again: $(@($Plan.blockers) -join ' ')") }
    $planId = [string] $Plan.planId
    if ($planId -notmatch '^[0-9A-F]{16}$') { return (& $refuse 'invalid plan id.') }
    $create = $Plan.workflow -eq 'Create'
    if ($create) {
        if (-not (Test-WdmElevated)) { return (& $refuse 'erasing and preparing a drive needs administrator rights.') }
        if ($Confirm -cne [string] $Plan.target.confirmCode) { return (& $refuse "the confirmation does not match. Type exactly $($Plan.target.confirmCode) to erase $($Plan.target.description).") }
    }
    $journalPath = Join-Path (Get-WdmStateRoot) "journal-$planId.json"
    $journal = $(if (Test-Path -LiteralPath $journalPath) { Read-WdmJsonFile $journalPath } else { $null })
    if (-not $journal) { $journal = [ordered]@{ format = $script:StateFormat; formatVersion = 1; planId = $planId; workflow = $Plan.workflow; diskFingerprint = [string] $Plan.target.fingerprint; packageId = [string] $Plan.package.packageId; status = 'InProgress'; startedUtc = (Get-WdmNow).ToString('o'); updatedUtc = ''; steps = [ordered]@{}; mediaRoot = ''; message = '' } }
    if ($journal['diskFingerprint'] -ne [string] $Plan.target.fingerprint) { return (& $refuse 'this plan was already used for another drive.') }
    $steps = $journal['steps']
    $done = { param([string] $Id) $steps.Contains($Id) -and [string] $steps[$Id]['status'] -eq 'Done' }
    $mark = { param([string] $Id, [string] $Status, [string] $Detail = '') $steps[$Id] = [ordered]@{ status = $Status; atUtc = (Get-WdmNow).ToString('o'); detail = $Detail }; Save-WdmJournal $journal ([string] $journal['mediaRoot']) }
    $journal['status'] = 'InProgress'
    $cancelled = $false
    $checkpoint = { if (Test-WdmCancelRequested $planId) { throw [System.OperationCanceledException]::new('Cancelled at a safe checkpoint.') } }
    try {
        & $checkpoint
        Write-WdmProgress 'Prepare' 'Validating the deployment package again'
        $pkg = Read-WdmPackage ([string] $Plan.package.path)
        if (-not $pkg.Ok) { throw "The deployment package no longer validates: $($pkg.Problems -join ' ')" }
        if ($pkg.PackageSha256 -ne [string] $Plan.package.sha256 -or [string] $pkg.Manifest['packageId'] -ne [string] $Plan.package.packageId) { throw 'The deployment package changed since the plan was made. Plan again.' }
        $backup = $null
        if ($pkg.Backup) {
            $bp = $(if ($BackupPath) { $BackupPath } elseif ($Plan.backup) { [string] $Plan.backup.path } else { '' })
            $backup = Open-WdmBackup $pkg.Backup $bp
            if (-not $backup.Ok) { throw "The settings backup does not validate: $($backup.Problems -join ' ')" }
        }
        $disk = Assert-WdmTarget $Plan $Plan.workflow
        $root = ''
        if ($create) {
            if ($steps.Contains('partition') -and [string] $steps['partition']['status'] -eq 'Running') { throw 'Erasing this drive was interrupted. Make a new plan and confirm the erase again; it is never resumed automatically.' }
            if (-not (& $done 'partition')) {
                & $checkpoint
                & $mark 'partition' 'Running'
                Write-WdmProgress 'Prepare' "Erasing disk $($disk.Number) and creating the layout"
                [void] (Assert-WdmTarget $Plan 'Create')
                $layout = Invoke-WdmPartitionDisk $disk.Number ([int64] $Plan.layout.partitions[0].bytes) ([bool] (@($Plan.layout.partitions).Count -gt 1))
                $journal['mediaRoot'] = [string] $layout.BootRoot
                & $mark 'partition' 'Done' "boot $($layout.BootRoot) data $($layout.DataRoot)"
            }
            $disk = Assert-WdmTarget $Plan 'Update'
            $boot = @($disk.Partitions | Where-Object { $_.Label -eq 'WDB-BOOT' -and $_.Root } | Select-Object -First 1)
            if (-not $boot) { throw 'The prepared FAT32 partition WDB-BOOT is not visible; plan again.' }
            $root = [string] $boot[0].Root
            $journal['mediaRoot'] = $root
            if (-not (& $done 'copyWindows') -or -not (& $done 'splitImage')) {
                $iso = $(if ($IsoPath) { $IsoPath } else { [string] $Plan.target.iso.path })
                $isoItem = Get-Item -LiteralPath $iso
                if ($isoItem.Length -ne [int64] $Plan.target.iso.size -or $isoItem.LastWriteTimeUtc.ToString('o') -ne [string] $Plan.target.iso.lastWriteUtc) { throw 'The ISO changed since the plan was made. Plan again.' }
                $isoRoot = Mount-WdmIso $isoItem.FullName
                try {
                    $imgName = [string] $Plan.image.file
                    if (-not (& $done 'copyWindows')) {
                        & $mark 'copyWindows' 'Running'
                        $files = @(Get-ChildItem -LiteralPath $isoRoot -Recurse -File -Force)
                        $total = [int64] (($files | Measure-Object -Property Length -Sum).Sum); $copied = [int64] 0; $n = 0
                        foreach ($f in $files) {
                            $rel = $f.FullName.Substring($isoRoot.TrimEnd('\').Length + 1)
                            $copied += $f.Length; $n++
                            if ($Plan.image.split -and $rel -ieq "sources\$imgName") { continue }
                            & $checkpoint
                            Write-WdmProgress 'Copying Windows files' "$n of $($files.Count): $rel" ([int] [Math]::Min(100, 100 * $copied / [Math]::Max(1, $total)))
                            [void] (Copy-WdmVerifiedFile $f.FullName (Join-Path $root $rel))
                        }
                        & $mark 'copyWindows' 'Done' "$($files.Count) file(s), $total bytes, each verified by SHA-256 against the ISO"
                    }
                    if ($Plan.image.split -and -not (& $done 'splitImage')) {
                        & $checkpoint
                        & $mark 'splitImage' 'Running'
                        $src = Join-Path $isoRoot "sources\$imgName"
                        if ($Plan.image.export) {
                            $tmp = Join-Path (Get-WdmStateRoot) "export-$planId.wim"
                            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
                            Write-WdmProgress 'Preparing the Windows image' 'Exporting the selected edition with DISM'
                            Invoke-WdmExportImage $src ([int] $Plan.image.selected.index) $tmp
                            $src = $tmp
                        }
                        foreach ($old in @(Get-ChildItem -LiteralPath (Join-Path $root 'sources') -Filter 'install*.swm' -File -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $old.FullName -Force }
                        Write-WdmProgress 'Preparing the Windows image' "Splitting into $($script:SplitSizeMB) MB parts with DISM"
                        Invoke-WdmSplitImage $src (Join-Path $root 'sources\install.swm') $script:SplitSizeMB
                        $parts = @(Get-ChildItem -LiteralPath (Join-Path $root 'sources') -Filter 'install*.swm' -File)
                        if (-not $parts.Count -or @($parts | Where-Object { $_.Length -gt $script:Fat32MaxFile }).Count) { throw 'DISM did not produce valid install.swm parts.' }
                        $first = Read-WdmImageInfo (Join-Path $root 'sources\install.swm')
                        if ($first.totalParts -ne $parts.Count) { throw "The split image has $($parts.Count) part(s) but declares $($first.totalParts)." }
                        if (-not @($first.images | Where-Object { $_.editionId -eq [string] $Plan.image.selected.editionId -and $_.build -eq [int] $Plan.image.selected.build }).Count) { throw 'The split image does not contain the planned edition.' }
                        if ($Plan.image.export) { Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue }
                        & $mark 'splitImage' 'Done' "$($parts.Count) part(s): $((@($parts | ForEach-Object { "$($_.Name)=$(Get-WdmFileSha256 $_.FullName)" })) -join ', ')"
                    }
                } finally { Dismount-WdmIso $isoItem.FullName }
            }
        } else {
            $part = @($disk.Partitions | Where-Object { ([string] $_.DriveLetter) -eq [string] $Plan.target.driveLetter } | Select-Object -First 1)
            if (-not $part -or [string] $part[0].Root -ne [string] $Plan.target.root) { throw "Drive $($Plan.target.driveLetter): is no longer on the planned disk. Plan again." }
            $root = [string] $part[0].Root
            $journal['mediaRoot'] = $root
        }
        & $checkpoint
        # Deployment files: staged next to the live folder, verified, then swapped in.
        $live = Join-Path $root $script:PackageDir
        $new = "$live.wdb-new"
        if (-not (& $done 'placePackage')) {
            & $mark 'placePackage' 'Running'
            $sameId = $Plan.target.Contains('existingPackageId') -and [string] $Plan.target.existingPackageId -eq [string] $Plan.package.packageId -and (Test-Path -LiteralPath $live)
            if ($sameId) { $new = $live }
            elseif (Test-Path -LiteralPath $new) { Remove-Item -LiteralPath $new -Recurse -Force }
            $files = @(Get-ChildItem -LiteralPath (Join-Path $pkg.Staging $script:PackageDir) -Recurse -File -Force)
            $n = 0
            foreach ($f in $files) {
                $n++
                & $checkpoint
                $rel = $f.FullName.Substring((Join-Path $pkg.Staging $script:PackageDir).Length + 1)
                Write-WdmProgress 'Deployment files' "$n of $($files.Count): $rel" ([int] (100 * $n / $files.Count))
                [void] (Copy-WdmVerifiedFile $f.FullName (Join-Path $new $rel))
            }
            if ($backup) {
                & $checkpoint
                Write-WdmProgress 'Settings backup' "Copying $($pkg.Backup.folderName)"
                $bdst = Join-Path $new "backups\$($pkg.Backup.folderName)"
                [void] (Copy-WdbBackup $backup.Validated $bdst)
                $check = Test-WdbBackup $bdst $pkg.Backup.manifestSha256
                if (-not $check.Ok) { throw "The copied settings backup does not validate: $($check.Problems -join ' ')" }
            }
            & $checkpoint
            # Swap: the previous deployment is kept (never deleted), then the new one takes its place.
            $stamp = (Get-WdmNow).ToString('yyyyMMdd-HHmmss')
            $keep = Join-Path $root "$($script:PreviousDir)\$stamp"
            $existingAnswer = Join-Path $root $script:AnswerFile
            if ($sameId) { & $mark 'placePackage' 'Done' "repaired in place: $($files.Count) file(s) verified" }
            elseif ((Test-Path -LiteralPath $live) -or (Test-Path -LiteralPath $existingAnswer)) {
                New-Item -ItemType Directory -Path $keep -Force | Out-Null
                if (Test-Path -LiteralPath $existingAnswer) { Move-Item -LiteralPath $existingAnswer -Destination (Join-Path $keep $script:AnswerFile) }
                if (Test-Path -LiteralPath $live) { Move-Item -LiteralPath $live -Destination (Join-Path $keep $script:PackageDir) }
                $journal['previous'] = $keep
            }
            if (-not $sameId) {
                Move-Item -LiteralPath $new -Destination $live
                & $mark 'placePackage' 'Done' "$($files.Count) file(s)$(if ($backup) { ' and the settings backup' }) verified"
            }
        }
        if (-not (& $done 'placeAnswerFile')) {
            & $checkpoint
            [void] (Copy-WdmVerifiedFile $pkg.AnswerFile (Join-Path $root $script:AnswerFile))
            & $mark 'placeAnswerFile' 'Done' 'verified'
        }
        Write-WdmProgress 'Verify' 'Checking the prepared drive'
        $report = Test-WdmMedia $root $pkg $backup $Plan -CurrentPlanId $planId
        $journal['status'] = $(if ($report.status -in 'ReadyForInstallation', 'ReadyWithWarnings') { 'Complete' } else { 'Failed' })
        $journal['message'] = [string] $report.status
        & $mark 'verify' $(if ($journal['status'] -eq 'Complete') { 'Done' } else { 'Failed' }) ([string] $report.status)
        return $report
    } catch [System.OperationCanceledException] {
        $cancelled = $true
        $journal['status'] = 'Cancelled'
        $journal['message'] = $(if (@($steps.Keys).Count) { 'Cancelled: the drive is incomplete; run the same plan again to finish, or plan again.' } else { 'Cancelled before anything was changed.' })
        Save-WdmJournal $journal ([string] $journal['mediaRoot'])
        return [ordered]@{ format = $script:ReportFormat; status = $(if (@($steps.Keys).Count) { 'Incomplete' } else { 'Cancelled' }); message = $journal['message']; planId = $planId; bootTested = $false }
    } catch {
        $journal['status'] = 'Failed'
        $journal['message'] = $_.Exception.Message
        try { Save-WdmJournal $journal ([string] $journal['mediaRoot']) } catch { }
        return [ordered]@{ format = $script:ReportFormat; status = $(if (@($steps.Keys).Count) { 'Incomplete' } else { 'Failed' }); message = $_.Exception.Message; planId = $planId; bootTested = $false }
    } finally {
        # The verified staging copies are not kept (they are recreated from the sources on every run).
        foreach ($v in 'pkg', 'backup') {
            $x = Get-Variable -Name $v -ValueOnly -ErrorAction SilentlyContinue
            if (-not $x) { continue }
            $dir = $(if ($v -eq 'pkg') { [string] $x.Staging } elseif ($x.Validated) { [string] $x.Validated.Root } else { '' })
            if ($dir -and $dir -like "$(Get-WdmStateRoot)\staging\*" -and (Test-Path -LiteralPath $dir)) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        if (-not $cancelled -and (Test-Path -LiteralPath (Join-Path (Get-WdmStateRoot) "$planId.cancel"))) { Remove-Item -LiteralPath (Join-Path (Get-WdmStateRoot) "$planId.cancel") -Force -ErrorAction SilentlyContinue }
    }
}

# ------------------------------------------------------------------------------------------------
# Verify and report
# ------------------------------------------------------------------------------------------------

<#
    Checks a drive (read-only) and returns the readiness report:
      ReadyForInstallation  structure, image, package, answer file and backup all verified
      ReadyWithWarnings     verified, with warnings (old servicing level, NTFS media, conflicts, ...)
      Incomplete            files missing or a preparation did not finish
      Failed                integrity failure or a mismatch (edition, architecture, other package)
      InspectionOnly        no deployment package to verify against
    "Media structure validated" is never "boot tested": no firmware boot is performed here.
#>
function Test-WdmMedia {
    param([string] $Root, $Package = $null, $BackupInfo = $null, $Plan = $null, [switch] $Online, [string] $CurrentPlanId = '')
    $checks = New-Object System.Collections.Generic.List[object]
    $add = { param([string] $Name, [string] $Result, [string] $Detail) $checks.Add([ordered]@{ check = $Name; result = $Result; detail = $Detail }) }
    $media = Get-WdmMediaInfo $Root
    $releases = Get-WdmReleaseInfo -Online:$Online
    & $add 'Windows Setup files' $(if ($media.isWindowsMedia) { 'Pass' } else { 'Missing' }) $(if ($media.isWindowsMedia) { 'setup.exe, sources\boot.wim and an install image are present.' } else { 'setup.exe, sources\boot.wim or the install image is missing.' })
    $arches = @($script:BootEfi.Keys | Where-Object { $media.bootFiles[$_] })
    & $add 'UEFI boot files' $(if ($arches.Count -and $media.bootFiles['bcd']) { 'Pass' } else { 'Missing' }) "Boot loaders: $(if ($arches.Count) { $arches -join ', ' } else { 'none' }); BCD: $(if ($media.bootFiles['bcd']) { 'present' } else { 'missing' }). Microsoft's files are not modified."
    if ($media.imageError) { & $add 'Windows image' 'Fail' $media.imageError }
    elseif ($media.image) {
        & $add 'Windows image' 'Pass' "$(Split-Path -Leaf $media.image.path) ($($media.image.format)): $((@($media.image.images | ForEach-Object { "$($_.index) $($_.name) [$($_.editionId) $($_.architecture) $($_.build).$($_.revision)]" })) -join '; ')"
        if ($media.image.format -eq 'SWM') {
            & $add 'Split image parts' $(if (@($media.splitParts).Count -eq $media.image.totalParts) { 'Pass' } else { 'Missing' }) "$(@($media.splitParts).Count) of $($media.image.totalParts) part(s): $(@($media.splitParts) -join ', ')"
        }
    }
    if (@($media.largeFiles).Count) { & $add 'FAT32 file sizes' 'Warn' "Files over 4 GB: $(@($media.largeFiles) -join ', ') (cannot be on FAT32; the drive is NTFS or exFAT)" }
    foreach ($c in $media.conflicts) { & $add 'Conflicting files' 'Warn' $c }
    if ($media.ventoy) { & $add 'Ventoy' 'Warn' 'Ventoy drive: an answer file next to an ISO is not used by Windows Setup started from Ventoy. Not supported for automated deployment.' }
    if ($media.state -and [string] $media.state['status'] -ne 'Complete' -and [string] $media.state['planId'] -ne $CurrentPlanId) { & $add 'Preparation journal' 'Missing' "The last preparation of this drive ended as '$($media.state['status'])': $($media.state['message'])" }
    $req = $null
    $pkg = $Package
    if (-not $pkg -and $media.packageDir) {
        # Self-check against the manifest on the drive: shows consistency, not origin.
        $pkg = Read-WdmPackage $Root
        $pkg.SelfCheck = $true
    }
    $status = 'InspectionOnly'
    if ($pkg) {
        $status = 'Checked'
        $mPath = Join-Path $Root "$($script:PackageDir)\deployment-manifest.json"
        $m = $(try { Read-WdmJsonFile $mPath } catch { $null })
        if (-not $m) { & $add 'Deployment manifest' 'Missing' "$($script:PackageDir)\deployment-manifest.json is missing or unreadable." }
        else {
            $same = $pkg.Manifest -and [string] $m['packageId'] -eq [string] $pkg.Manifest['packageId']
            & $add 'Deployment manifest' $(if ($same) { 'Pass' } else { 'Fail' }) "Package $($m['packageId']), manifest version $($m['manifestVersion']), package version $($m['packageVersion'])$(if (-not $same -and $pkg.Manifest) { "; expected $($pkg.Manifest['packageId'])" })"
            $missing = @(); $bad = @(); $ok = 0
            foreach ($f in @($m['files'])) {
                $p = Join-Path $Root ("$($script:PackageDir)\" + (([string] $f['path']) -replace '/', '\'))
                if (-not (Test-WdmRelativePath ([string] $f['path']))) { $bad += [string] $f['path']; continue }
                if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $missing += [string] $f['path']; continue }
                if ((Get-WdmFileSha256 $p) -ne [string] $f['sha256']) { $bad += [string] $f['path'] } else { $ok++ }
            }
            & $add 'Deployment files' $(if ($bad.Count) { 'Fail' } elseif ($missing.Count) { 'Missing' } else { 'Pass' }) "$ok verified$(if ($missing.Count) { "; missing: $($missing -join ', ')" })$(if ($bad.Count) { "; modified: $($bad -join ', ')" })"
            $answer = Join-Path $Root $script:AnswerFile
            if (-not (Test-Path -LiteralPath $answer -PathType Leaf)) { & $add 'Answer file' 'Missing' "$($script:AnswerFile) is not at the drive root, so Windows Setup would run without it." }
            elseif ($m.Contains('media') -and $m['media'] -and $m['media']['answerFile']) { $h = Get-WdmFileSha256 $answer; & $add 'Answer file' $(if ($h -eq [string] $m['media']['answerFile']['sha256']) { 'Pass' } else { 'Fail' }) "$($script:AnswerFile) at the root; SHA-256 $(if ($h -eq [string] $m['media']['answerFile']['sha256']) { 'matches' } else { 'does NOT match' }) the manifest." }
            elseif ($pkg.AnswerFile -and (Get-WdmFileSha256 $answer) -eq (Get-WdmFileSha256 $pkg.AnswerFile)) { & $add 'Answer file' 'Pass' "$($script:AnswerFile) at the root, identical to the package's." }
            else { & $add 'Answer file' 'Warn' "$($script:AnswerFile) at the root; not hash-pinned by this (pre-Phase 7) package." }
            $nested = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter $script:AnswerFile -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.DirectoryName.TrimEnd('\') -ne $Root.TrimEnd('\') -and $_.FullName -notmatch [regex]::Escape($script:PreviousDir) })
            if ($nested.Count) { & $add 'Answer file location' 'Warn' "Other $($script:AnswerFile) files below the root are ignored by Windows Setup: $(@($nested | ForEach-Object { $_.FullName.Substring($Root.TrimEnd('\').Length + 1) }) -join ', ')" }
            $sr = $(if ($m.Contains('migration') -and $m['migration']) { $m['migration']['settingsRestore'] } else { $null })
            if ($sr) {
                $bdir = Join-Path $Root "$($script:PackageDir)\backups\$($sr['folderName'])"
                if (-not (Test-Path -LiteralPath $bdir)) { & $add 'Settings backup' 'Missing' "Backup $($sr['folderName']) is not on the drive; settings would wait for Deployment recovery (RestoreSettings)." }
                else {
                    if (Get-Command Test-WdbBackup -CommandType Function -ErrorAction SilentlyContinue) {
                        $v = Test-WdbBackup $bdir ([string] $sr['manifestSha256'])
                        & $add 'Settings backup' $(if ($v.Ok) { 'Pass' } else { 'Fail' }) $(if ($v.Ok) { "Backup $($sr['folderName']) verified (manifest SHA-256 matches the deployment, every file hashed)." } else { "Backup $($sr['folderName']): $(@($v.Problems) -join ' ')" })
                    } else { & $add 'Settings backup' 'Warn' 'WdbMigration.ps1 is not next to the assistant; the backup was not verified.' }
                }
            }
            if ($pkg.Requirements -and $media.image) {
                $compat = Test-WdmCompatibility $pkg.Requirements $media.image $releases
                foreach ($b in $compat.Blockers) { & $add 'Compatibility' 'Fail' $b }
                foreach ($w in $compat.Warnings) { & $add 'Compatibility' 'Warn' $w }
                if ($compat.Selected) { & $add 'Edition' 'Pass' "Index $($compat.Selected.index) $($compat.Selected.name) [$($compat.Selected.editionId), $($compat.Selected.architecture)]" }
                $req = $compat
            }
            if ($pkg.Contains('SelfCheck') -and $pkg.SelfCheck) { & $add 'Package origin' 'Warn' 'Verified against the manifest on the drive itself (consistency); verify against the downloaded package (-Package) to check it is the intended one.' }
        }
    } elseif ($media.image) {
        $sel = @($media.image.images | Select-Object -First 1)
        if ($sel) { $f = Get-WdmFreshness $sel[0] $releases $sel[0].editionId; & $add 'Freshness' $(if ($f.status -eq 'Current') { 'Pass' } else { 'Warn' }) $f.message }
    }
    $results = @($checks.ToArray() | ForEach-Object { $_.result })
    if ($status -ne 'InspectionOnly') {
        $status = $(if ($results -contains 'Fail') { 'Failed' } elseif ($results -contains 'Missing') { 'Incomplete' } elseif ($results -contains 'Warn') { 'ReadyWithWarnings' } else { 'ReadyForInstallation' })
    }
    $sel = $null
    if ($req -and $req.Selected) { $sel = $req.Selected }
    $checkArray = $checks.ToArray()
    $report = [ordered]@{}
    $report.format = $script:ReportFormat; $report.formatVersion = 1; $report.generatedUtc = (Get-WdmNow).ToString('o'); $report.tool = $script:WdmVersion; $report.status = $status
    $report.mediaStructureValidated = ($status -in 'ReadyForInstallation', 'ReadyWithWarnings'); $report.bootTested = $false
    $report.bootNote = 'Boot not tested: files, image and boot components were checked; no computer was booted from this drive.'
    $report.root = $Root
    $report.device = ''
    if ($Plan -and $Plan.target) { $report.device = [string] $Plan.target.description }
    $report.edition = ''; $report.architecture = ''; $report.imageBuild = ''; $report.freshness = $null
    if ($sel) { $report.edition = "$($sel.name) [$($sel.editionId)]"; $report.architecture = [string] $sel.architecture; $report.imageBuild = "$($sel.build).$($sel.revision)"; $report.freshness = $req.Freshness }
    $report.packageId = ''; $report.manifestVersion = ''
    if ($pkg -and $pkg.Manifest) { $report.packageId = [string] $pkg.Manifest['packageId']; $report.manifestVersion = [string] $pkg.Manifest['manifestVersion'] }
    $report.backupRequired = [bool] ($pkg -and $pkg.Backup)
    $report.checks = $checkArray
    $report.verifiedFiles = @($checkArray | Where-Object { $_.check -eq 'Deployment files' } | ForEach-Object { $_.detail })
    $manual = New-Object System.Collections.Generic.List[string]
    foreach ($c in $checkArray) { if ($c.result -in 'Missing', 'Fail') { $manual.Add("$($c.check): $($c.detail)") } }
    $manual.Add('Remove or protect the drive after installing: it starts an automatic installation on any computer booted from it.')
    $report.manualActions = $manual.ToArray()
    $report.limitations = @('Booting depends on the target firmware (UEFI). Legacy BIOS boot is not prepared or tested.', "Secure Boot: Microsoft's signed boot files are used unchanged.")
    return $report
}

function Format-WdmReport {
    param($Report)
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add("Windows installation USB - readiness report ($($Report.generatedUtc))")
    $l.Add('=' * 72)
    $l.Add("Result   : $($Report.status)")
    $l.Add("           $($Report.bootNote)")
    if ($Report.Contains('device') -and $Report.device) { $l.Add("Device   : $($Report.device)") }
    if ($Report.Contains('root')) { $l.Add("Drive    : $($Report.root)") }
    if ($Report.Contains('edition') -and $Report.edition) { $l.Add("Windows  : $($Report.edition), $($Report.architecture), build $($Report.imageBuild)") }
    if ($Report.Contains('freshness') -and $Report.freshness) { $l.Add("Freshness: $($Report.freshness.status). $($Report.freshness.message)") }
    if ($Report.Contains('packageId') -and $Report.packageId) { $l.Add("Package  : $($Report.packageId) (manifest version $($Report.manifestVersion))$(if ($Report.backupRequired) { ', with settings backup' })") }
    if ($Report.Contains('message')) { $l.Add("Message  : $($Report.message)") }
    if ($Report.Contains('checks')) { $l.Add(''); foreach ($c in $Report.checks) { $l.Add(('  {0,-8} {1,-24} {2}' -f $c.result, $c.check, $c.detail)) } }
    if ($Report.Contains('manualActions') -and @($Report.manualActions).Count) { $l.Add(''); $l.Add('To do:'); foreach ($a in $Report.manualActions) { $l.Add("  - $a") } }
    if ($Report.Contains('limitations')) { $l.Add(''); foreach ($a in $Report.limitations) { $l.Add("  * $a") } }
    return ($l -join "`r`n")
}

function Save-WdmReport {
    param($Report)
    $dir = Join-Path (Get-WdmStateRoot) 'reports'
    $stamp = (Get-WdmNow).ToString('yyyyMMdd-HHmmss')
    $text = Format-WdmReport $Report
    Write-WdmFileAtomic (Join-Path $dir "media-report-$stamp.json") (Get-WdmUtf8 (ConvertTo-WdmJson $Report))
    Write-WdmFileAtomic (Join-Path $dir "media-report-$stamp.txt") (Get-WdmUtf8 $text)
    if ($Report.Contains('root') -and $Report.root -and $Report.status -ne 'InspectionOnly' -and (Test-Path -LiteralPath $Report.root)) {
        try { Write-WdmFileAtomic (Join-Path $Report.root $script:ReportFile) (Get-WdmUtf8 $text) } catch { }
    }
    return (Join-Path $dir "media-report-$stamp.txt")
}

# ------------------------------------------------------------------------------------------------
# Wizard (console)
# ------------------------------------------------------------------------------------------------

function Invoke-WdmWizard {
    Write-Output 'Windows Deployment Builder - USB Preparation Assistant'
    Write-Output 'Official Windows 11 media: https://www.microsoft.com/software-download/windows11'
    Write-Output ''
    Write-Output '  1  Update deployment files on an existing Windows USB (nothing is erased)'
    Write-Output '  2  Create a new Windows USB from an ISO (ERASES the chosen USB flash drive)'
    Write-Output '  3  Inspect or verify a drive or ISO (read-only)'
    $c = Read-WdmAnswer 'Choose 1-3'
    if ($c -eq '3') {
        $t = Read-WdmAnswer 'Drive letter (E:) or ISO path'
        $pk = Read-WdmAnswer 'Deployment package ZIP to verify against (Enter to skip)'
        if ($t -match '\.iso$') { $root = Mount-WdmIso $t; try { $r = Test-WdmMedia $root } finally { Dismount-WdmIso $t } }
        else { $root = (Resolve-WdmTarget $t @(Get-WdmDisks)).Root; $p = $(if ($pk) { Read-WdmPackage $pk } else { $null }); $r = Test-WdmMedia $root $p }
        Write-Output (Format-WdmReport $r)
        return $r
    }
    $pkgPath = Read-WdmAnswer 'Deployment package ZIP (windows-deployment-package.zip)'
    $bk = Read-WdmAnswer 'Settings backup folder, if this deployment restores settings (Enter to skip)'
    Write-Output ''
    foreach ($d in @(Get-WdmDisks)) { $e = Test-WdmDiskEligibility $d @(Get-WdmDisks); Write-Output "$(Format-WdmDisk $d)`r`n    update: $(if ($e.Update.Allowed) { 'yes' } else { 'no - ' + ($e.Update.Reasons -join '; ') })   erase: $(if ($e.Create.Allowed) { 'yes' } else { 'no - ' + ($e.Create.Reasons -join '; ') })" }
    if ($c -eq '1') {
        $t = Read-WdmAnswer 'Drive letter of the Windows USB (for example E:)'
        $plan = New-WdmPlan Update $pkgPath $bk $t
        Write-Output (Format-WdmPlan $plan)
        if (@($plan.blockers).Count -and @($plan.blockers | Where-Object { $_ -match 'already has a deployment' }).Count -and (Read-WdmAnswer 'Replace the existing deployment (it is kept in WDB-previous)? Type REPLACE') -ceq 'REPLACE') {
            $plan = New-WdmPlan Update $pkgPath $bk $t -Replace
            Write-Output (Format-WdmPlan $plan)
        }
        if (@($plan.blockers).Count) { return $plan }
        if ((Read-WdmAnswer 'Write these files? Type YES') -cne 'YES') { Write-Output 'Nothing was changed.'; return $plan }
        $r = Invoke-WdmApply $plan '' '' $bk
    } else {
        $isoPath = Read-WdmAnswer 'Windows 11 ISO file'
        $hash = Read-WdmAnswer 'SHA-256 from Microsoft''s download page (Enter to skip)'
        $num = Read-WdmAnswer 'Disk NUMBER of the USB flash drive to ERASE'
        if ($num -notmatch '^\d{1,3}$') { Write-Output 'No disk chosen; nothing was changed.'; return $null }
        $plan = New-WdmPlan Create $pkgPath $bk '' $isoPath ([int] $num) -ExpectedIsoSha256 $hash
        Write-Output (Format-WdmPlan $plan)
        if (@($plan.blockers).Count) { return $plan }
        Write-Output ''
        Write-Output "WARNING: every partition and file on disk $($plan.target.diskNumber) will be deleted:"
        Write-Output "  $($plan.target.description)"
        $code = Read-WdmAnswer "Type $($plan.target.confirmCode) to erase it (anything else cancels)"
        if ($code -cne [string] $plan.target.confirmCode) { Write-Output 'Not confirmed; nothing was changed.'; return $plan }
        $planFile = Join-Path (Get-WdmStateRoot) "plan-$($plan.planId).json"
        Write-WdmFileAtomic $planFile (Get-WdmUtf8 (ConvertTo-WdmJson $plan))
        if (-not (Test-WdmElevated)) {
            Write-Output 'Windows asks for administrator rights to prepare the drive; the plan is checked again there.'
            $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $proc = Start-Process -FilePath $ps -Verb RunAs -Wait -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Mode', 'Apply', '-PlanPath', "`"$planFile`"", '-ConfirmErase', $code)
            Write-Output "Finished with exit code $($proc.ExitCode). The report is in $(Join-Path (Get-WdmStateRoot) 'reports')."
            return $null
        }
        $r = Invoke-WdmApply $plan $code '' $bk
    }
    Write-Output (Format-WdmReport $r)
    if ($r.Contains('root')) { Write-Output "Report: $(Save-WdmReport $r)" }
    return $r
}

# ------------------------------------------------------------------------------------------------
# Main (dot-sourcing only defines the functions)
# ------------------------------------------------------------------------------------------------

$script:WdmExit = @{ ReadyForInstallation = 0; ReadyWithWarnings = 0; InspectionOnly = 0; Incomplete = 2; Cancelled = 2; Failed = 1; Blocked = 3 }

# The Phase 6 backup validator ships next to this assistant (never loaded from a package or backup).
$script:WdmLibrary = Join-Path $PSScriptRoot 'WdbMigration.ps1'
if (Test-Path -LiteralPath $script:WdmLibrary) { . $script:WdmLibrary -Mode Library; Set-StrictMode -Version 2.0 }

if ($script:WdmMain -and $script:WdmArgs.Mode -ne 'Library') {
    $a = $script:WdmArgs
    $Mode = $a.Mode; $Workflow = $a.Workflow; $Package = $a.Package; $Backup = $a.Backup; $Target = $a.Target; $Iso = $a.Iso; $Disk = $a.Disk; $PlanPath = $a.PlanPath
    $ConfirmErase = $a.ConfirmErase; $IsoSha256 = $a.IsoSha256; $ReplaceExisting = $a.ReplaceExisting; $NoDataPartition = $a.NoDataPartition; $CheckOnline = $a.CheckOnline; $Json = $a.Json
    switch ($Mode) {
        'Wizard' { $r = Invoke-WdmWizard; if ($r -and $r.Contains('status')) { exit $script:WdmExit[[string] $r.status] }; exit 0 }
        'Discover' {
            $disks = @(Get-WdmDisks)
            $rows = @($disks | ForEach-Object { $e = Test-WdmDiskEligibility $_ $disks; [ordered]@{ disk = $_.Number; description = (Format-WdmDisk $_); update = $e.Update; erase = $e.Create; warnings = $e.Warnings } })
            if ($Json) { ConvertTo-WdmJson @($rows) } else { foreach ($r in $rows) { $r.description; "    update deployment files: $(if ($r.update.Allowed) { 'possible' } else { 'no - ' + ($r.update.Reasons -join '; ') })"; "    erase and create:        $(if ($r.erase.Allowed) { 'possible' } else { 'no - ' + ($r.erase.Reasons -join '; ') })"; foreach ($w in $r.warnings) { "    ! $w" } } }
            exit 0
        }
        'Inspect' {
            if ($Iso) { $root = Mount-WdmIso $Iso; try { $r = Test-WdmMedia $root -Online:([bool] $CheckOnline) } finally { Dismount-WdmIso $Iso } }
            else { $root = $(if ($Target -match '^[A-Za-z]:?\\?$') { (Resolve-WdmTarget $Target @(Get-WdmDisks)).Root } else { $Target }); $p = $(if ($Package) { Read-WdmPackage $Package } else { $null }); $r = Test-WdmMedia $root $p -Online:([bool] $CheckOnline); if (-not $Package) { $r.selfCheckStatus = $r.status; $r.status = 'InspectionOnly' } }
            if ($Json) { ConvertTo-WdmJson $r } else { Format-WdmReport $r }
            exit 0
        }
        'Plan' {
            $plan = New-WdmPlan $Workflow $Package $Backup $Target $Iso $Disk -Replace:([bool] $ReplaceExisting) -NoData:([bool] $NoDataPartition) -ExpectedIsoSha256 $IsoSha256 -Online:([bool] $CheckOnline)
            $file = $(if ($PlanPath) { $PlanPath } else { Join-Path (Get-WdmStateRoot) "plan-$($plan.planId).json" })
            Write-WdmFileAtomic ([IO.Path]::GetFullPath($file)) (Get-WdmUtf8 (ConvertTo-WdmJson $plan))
            if ($Json) { ConvertTo-WdmJson $plan } else { Format-WdmPlan $plan; ''; "Plan saved: $file"; if (-not @($plan.blockers).Count) { "Apply it: .\WdbMediaAssistant.ps1 -Mode Apply -PlanPath `"$file`"$(if ($plan.workflow -eq 'Create') { " -ConfirmErase $($plan.target.confirmCode)" })" } }
            if (@($plan.blockers).Count) { exit $script:WdmExit.Blocked }
            exit 0
        }
        'Apply' {
            $plan = Read-WdmJsonFile $PlanPath
            if (-not $plan) { 'Plan not found.'; exit $script:WdmExit.Failed }
            $r = Invoke-WdmApply $plan $ConfirmErase $Iso $Backup
            $path = $(if ($r.Contains('root')) { Save-WdmReport $r } else { '' })
            if ($Json) { ConvertTo-WdmJson $r } else { Format-WdmReport $r; if ($path) { "Report: $path" } }
            exit $script:WdmExit[[string] $r.status]
        }
        'Verify' {
            $root = (Resolve-WdmTarget $Target @(Get-WdmDisks)).Root
            $p = $(if ($Package) { Read-WdmPackage $Package } else { $null })
            $r = Test-WdmMedia $root $p -Online:([bool] $CheckOnline)
            $path = Save-WdmReport $r
            if ($Json) { ConvertTo-WdmJson $r } else { Format-WdmReport $r; "Report: $path" }
            exit $script:WdmExit[[string] $r.status]
        }
    }
}
