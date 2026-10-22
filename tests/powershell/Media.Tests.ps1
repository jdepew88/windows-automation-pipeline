#Requires -Version 5.1
<#
    Scenario tests for the USB Preparation Assistant (WdbMediaAssistant.ps1, Phase 7) against a
    simulated computer: disks, partitions and volumes are records whose "drives" are temporary
    folders; ISO mounting, DISM, partitioning, signatures, elevation and the online release page are
    replaced. The deployment packages are the REAL ZIPs produced by the generator (fixture), and
    the Phase 6 backup is the real fixture backup. No real disk is listed, erased, partitioned or
    written; no ISO is mounted; DISM is never called.

    Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\powershell\Media.Tests.ps1 -Fixture <dir>
    (<dir> from "vite-node tests/powershell/make-deployment-fixture.ts <dir>"; npm run test:ps does both.)
#>
param([Parameter(Mandatory = $true)] [string] $Fixture)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\src\engine\media\scripts\WdbMediaAssistant.ps1') -Mode Library
. (Join-Path $PSScriptRoot '..\..\src\engine\migration\scripts\WdbMigration.ps1') -Mode Library
Set-StrictMode -Version 2.0
$script:WdmReleaseFile = Join-Path $PSScriptRoot '..\..\src\data\windows-releases.json'
${function:Invoke-WdmPartitionDiskReal} = ${function:Invoke-WdmPartitionDisk}

$script:Failures = 0
$script:Passed = 0
$script:MainZip = (Resolve-Path (Join-Path $Fixture 'package.zip')).Path
$script:MigZip = (Resolve-Path (Join-Path $Fixture 'migration\package.zip')).Path
$script:MigBackupFolder = 'WDB-AppBackup-20261021-120000-a1b2c3'
$script:MigBackup = (Resolve-Path (Join-Path $Fixture "migration\usb\WindowsDeployment\backups\$script:MigBackupFolder")).Path

function Assert-Equal($Actual, $Expected, [string] $Message) { if ("$Actual" -ne "$Expected") { throw "ASSERT: $Message. Expected <$Expected>, got <$Actual>." } }
function Assert-True($Value, [string] $Message) { if (-not $Value) { throw "ASSERT: $Message" } }
function Assert-Match([string[]] $Lines, [string] $Pattern, [string] $Message) { if (-not @($Lines | Where-Object { $_ -match $Pattern }).Count) { throw "ASSERT: $Message. No line matches /$Pattern/ in:`n  $($Lines -join "`n  ")" } }

# ------------------------------------------------------------------------------------------------
# Simulated computer
# ------------------------------------------------------------------------------------------------

function Reset-Sim {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("wdm-test-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $script:Sim = @{ Root = $root; Disks = @(); Free = @{}; Elevated = $true; Partitioned = @(); Splits = 0; Exports = 0; Mounted = @{}; Signature = @{ Status = 'Valid'; Signer = 'CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }
                     CancelAfter = -1; Checkpoints = 0; CopyFailAfter = -1; Copies = 0; Online = ''; Now = [DateTime]::new(2026, 10, 22, 12, 0, 0, [DateTimeKind]::Utc); BeforePartition = $null }
    $script:Fat32MaxFile = 4GB - 1
}

function New-SimDisk {
    param([int] $Number, [string] $Model, [int64] $Size, [string] $Bus = 'USB', [string] $MediaType = 'Removable Media', [string] $Serial = '', [object[]] $Partitions = @(), [switch] $System, [switch] $ReadOnly, [switch] $Offline)
    @{ Number = $Number; FriendlyName = $Model; Manufacturer = ($Model -split ' ')[0]; Model = $Model; SerialNumber = $Serial; UniqueId = $(if ($Serial) { "USBSTOR\$Serial" } else { '' }); Size = $Size
       BusType = $Bus; MediaType = $MediaType; PartitionStyle = 'MBR'; IsSystem = [bool] $System; IsBoot = [bool] $System; IsReadOnly = [bool] $ReadOnly; IsOffline = [bool] $Offline; Partitions = @($Partitions); Elevated = $true }
}

<# A volume: a temporary folder standing for the drive root. #>
function New-SimVolume {
    param([string] $Letter, [string] $FileSystem = 'FAT32', [string] $Label = 'ESD-USB', [int64] $Size = 30GB, [int64] $Free = 20GB)
    $dir = Join-Path $script:Sim.Root "vol-$Letter-$([Guid]::NewGuid().ToString('N').Substring(0, 6))"
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:Sim.Free[$dir + '\'] = $Free
    @{ Number = 1; DriveLetter = $Letter; FileSystem = $FileSystem; Label = $Label; Size = $Size; Free = $Free; IsBootPartition = $false; Root = $dir + '\' }
}

function Get-WdmNow { $script:Sim.Now }
function Test-WdmElevated { $script:Sim.Elevated }
function Get-WdmSystemDriveLetter { 'C' }
function Get-WdmStateRoot { Join-Path $script:Sim.Root 'state' }
function Get-WdmDisks { $script:Sim.Disks }
function Get-WdmFreeSpace { param([string] $Root) $script:Sim.Free[$Root] }
function Mount-WdmIso { param([string] $Path) $r = $script:Sim.Mounted[$Path]; if (-not $r) { throw 'simulated: not an ISO' }; $r }
function Dismount-WdmIso { param([string] $Path) }
function Get-WdmSignature { param([string] $Path) $script:Sim.Signature }
function Write-WdmProgress { param([string] $Activity, [string] $Status, [int] $Percent = -1) }
function Test-WdmCancelRequested { param([string] $PlanId) $script:Sim.Checkpoints++; ($script:Sim.CancelAfter -ge 0 -and $script:Sim.Checkpoints -gt $script:Sim.CancelAfter) }
function Get-WdmOnlineReleasePage { param([string] $Url) if (-not $script:Sim.Online) { throw 'simulated: offline' }; $script:Sim.Online }
function Invoke-WdmPartitionDisk {
    param([int] $Number, [int64] $BootBytes, [bool] $DataPartition)
    if ($script:Sim.BeforePartition) { & $script:Sim.BeforePartition }
    $d = @($script:Sim.Disks | Where-Object { $_.Number -eq $Number })[0]
    $script:Sim.Partitioned += , @{ Number = $Number; BootBytes = $BootBytes; Data = $DataPartition }
    foreach ($p in @($d.Partitions)) { if ($p.Root -and (Test-Path -LiteralPath $p.Root)) { Remove-Item -LiteralPath $p.Root -Recurse -Force } }
    $boot = New-SimVolume 'U' 'FAT32' 'WDB-BOOT' $BootBytes ($BootBytes - 1MB)
    $d.Partitions = @($boot) + @(if ($DataPartition) { New-SimVolume 'V' 'NTFS' 'WDB-DATA' ($d.Size - $BootBytes) ($d.Size - $BootBytes) })
    @{ BootRoot = $boot.Root; DataRoot = $(if ($DataPartition) { $d.Partitions[1].Root } else { '' }) }
}
function Invoke-WdmSplitImage {
    param([string] $Source, [string] $DestinationSwm, [int] $FileSizeMB)
    $script:Sim.Splits++
    $info = Read-WdmImageInfo $Source
    $dir = Split-Path -Parent $DestinationSwm
    New-SimWim (Join-Path $dir 'install.swm') @($info.images) -Part 1 -Parts 2 -Pad 1000
    New-SimWim (Join-Path $dir 'install2.swm') @() -Part 2 -Parts 2 -Pad 1000
}
function Invoke-WdmExportImage {
    param([string] $Source, [int] $Index, [string] $Destination)
    $script:Sim.Exports++
    $info = Read-WdmImageInfo $Source
    New-SimWim $Destination @($info.images | Where-Object { $_.index -eq $Index }) -Pad 4000
}
# Copy fault injection: the n-th copy into a drive fails (an unplugged drive, a write error).
${function:Copy-WdmVerifiedFileReal} = ${function:Copy-WdmVerifiedFile}
function Copy-WdmVerifiedFile {
    param([string] $Source, [string] $Destination, [string] $ExpectedSha256 = '')
    $script:Sim.Copies++
    if ($script:Sim.CopyFailAfter -ge 0 -and $script:Sim.Copies -gt $script:Sim.CopyFailAfter) { throw 'simulated: the drive was removed during the copy' }
    Copy-WdmVerifiedFileReal $Source $Destination $ExpectedSha256
}

<# A synthetic WIM: the documented 208-byte header and a UTF-16 XML resource, plus padding. #>
function New-SimWim {
    param([string] $Path, [object[]] $Images, [int] $Part = 1, [int] $Parts = 1, [int] $Pad = 0, [switch] $BadMagic, [switch] $BadXml, [string] $RawXml = '')
    $x = New-Object System.Text.StringBuilder
    [void] $x.Append('<WIM>')
    foreach ($i in $Images) {
        $arch = @{ x86 = 0; amd64 = 9; arm64 = 12 }[[string] $i.architecture]
        [void] $x.Append("<IMAGE INDEX=`"$($i.index)`"><TOTALBYTES>$(if ($i.Contains('totalBytes')) { $i.totalBytes } else { 1000 })</TOTALBYTES><WINDOWS><ARCH>$arch</ARCH><PRODUCTNAME>Microsoft&#174; Windows&#174; Operating System</PRODUCTNAME><EDITIONID>$($i.editionId)</EDITIONID><INSTALLATIONTYPE>Client</INSTALLATIONTYPE><LANGUAGES><LANGUAGE>en-US</LANGUAGE></LANGUAGES><VERSION><MAJOR>10</MAJOR><MINOR>0</MINOR><BUILD>$($i.build)</BUILD><SPBUILD>$($i.revision)</SPBUILD></VERSION></WINDOWS><NAME>$($i.name)</NAME><DISPLAYNAME>$($i.name)</DISPLAYNAME></IMAGE>")
    }
    [void] $x.Append('</WIM>')
    $xmlText = $(if ($RawXml) { $RawXml } elseif ($BadXml) { '<WIM><IMAGE' } else { $x.ToString() })
    $xml = [byte[]] (@(0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes($xmlText))
    $h = New-Object byte[] 208
    [Text.Encoding]::ASCII.GetBytes($(if ($BadMagic) { 'NOTAWIM!' } else { "MSWIM`0`0`0" })).CopyTo($h, 0)
    [BitConverter]::GetBytes([uint32] 208).CopyTo($h, 8)
    [BitConverter]::GetBytes([uint32] 0x10D00).CopyTo($h, 12)
    [BitConverter]::GetBytes([uint16] $Part).CopyTo($h, 40)
    [BitConverter]::GetBytes([uint16] $Parts).CopyTo($h, 42)
    [BitConverter]::GetBytes([uint32] @($Images).Count).CopyTo($h, 44)
    [BitConverter]::GetBytes([int64] $xml.Length).CopyTo($h, 72)   # size (7 bytes) + flags (0)
    [BitConverter]::GetBytes([int64] 208).CopyTo($h, 80)
    [BitConverter]::GetBytes([int64] $xml.Length).CopyTo($h, 88)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $fs = [IO.File]::Create($Path)
    try { $fs.Write($h, 0, 208); $fs.Write($xml, 0, $xml.Length); if ($Pad) { $z = New-Object byte[] $Pad; $fs.Write($z, 0, $Pad) } } finally { $fs.Dispose() }
}

function Img { param([int] $Index, [string] $Name, [string] $Edition, [string] $Arch = 'amd64', [int] $Build = 26200, [int] $Rev = 9711) [ordered]@{ index = $Index; name = $Name; editionId = $Edition; architecture = $Arch; build = $Build; revision = $Rev } }

<# The usual consumer ISO set: Home first, Pro at index 6 (never assume index 1). #>
function Get-ConsumerImages { param([int] $Build = 26200, [int] $Rev = 9711, [string] $Arch = 'amd64') @((Img 1 'Windows 11 Home' 'Core' $Arch $Build $Rev), (Img 2 'Windows 11 Home N' 'CoreN' $Arch $Build $Rev), (Img 3 'Windows 11 Home Single Language' 'CoreSingleLanguage' $Arch $Build $Rev), (Img 4 'Windows 11 Education' 'Education' $Arch $Build $Rev), (Img 5 'Windows 11 Education N' 'EducationN' $Arch $Build $Rev), (Img 6 'Windows 11 Pro' 'Professional' $Arch $Build $Rev), (Img 7 'Windows 11 Pro N' 'ProfessionalN' $Arch $Build $Rev)) }

<# Windows Setup files as on a Media Creation Tool drive or in an ISO. #>
function New-SimWindowsMedia {
    param([string] $Root, [object[]] $Images = (Get-ConsumerImages), [string] $ImageName = 'install.wim', [int] $Pad = 0, [string] $Arch = 'amd64')
    foreach ($f in 'setup.exe', 'bootmgr', 'bootmgr.efi', 'sources\boot.wim', 'sources\setup.exe', 'efi\microsoft\boot\bcd', 'boot\bcd', 'support\logging\readme.txt') {
        $p = Join-Path $Root $f; New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force | Out-Null; [IO.File]::WriteAllText($p, "sim $f")
    }
    $efi = Join-Path $Root $(if ($Arch -eq 'arm64') { 'efi\boot\bootaa64.efi' } else { 'efi\boot\bootx64.efi' })
    New-Item -ItemType Directory -Path (Split-Path -Parent $efi) -Force | Out-Null
    [IO.File]::WriteAllText($efi, 'MZ signed boot loader (simulated)')
    New-SimWim (Join-Path $Root "sources\$ImageName") $Images -Pad $Pad
}

<# The standard simulated computer: OS disk, internal data disk, one USB stick with Windows media. #>
function Set-SimComputer {
    param([string] $StickFs = 'FAT32', [int64] $StickFree = 20GB)
    $c = New-SimVolume 'C' 'NTFS' 'Windows' 476GB 200GB
    $d = New-SimVolume 'D' 'NTFS' 'Data' 931GB 500GB
    $e = New-SimVolume 'E' $StickFs 'ESD-USB' 29GB $StickFree
    New-SimWindowsMedia $e.Root
    [IO.File]::WriteAllText((Join-Path $e.Root 'customer notes.txt'), 'unrelated file')
    $script:Sim.Disks = @(
        (New-SimDisk 0 'Samsung SSD 990 PRO 512GB' 512GB 'NVMe' 'Fixed hard disk media' 'S6Z1NX0000001' @($c) -System),
        (New-SimDisk 1 'WDC WD10EZEX' 1000GB 'SATA' 'Fixed hard disk media' 'WD-WCC0000002' @($d)),
        (New-SimDisk 2 'SanDisk Ultra USB 3.0' 30GB 'USB' 'Removable Media' '4C530001230101234567' @($e))
    )
    return $e
}

function Get-Problems { param($Report) "$($Report['message']) " + (@(@($Report['checks']) | Where-Object { $_ -and $_.result -ne 'Pass' } | ForEach-Object { "$($_.check): $($_.detail)" }) -join '; ') }
function Get-Lines { param($Plan) @(@($Plan.blockers) + @($Plan.warnings)) }
function Get-TreeHashes { param([string] $Root) $h = [ordered]@{}; foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName)) { $h[$f.FullName.Substring($Root.Length)] = Get-WdmFileSha256 $f.FullName }; $h }

# ------------------------------------------------------------------------------------------------
# Scenarios
# ------------------------------------------------------------------------------------------------

$tests = [ordered]@{}

$tests['disks: the Windows disk, internal disks, read-only, offline and Ventoy drives are never targets'] = {
    Reset-Sim; $e = Set-SimComputer
    $v = New-SimVolume 'G' 'exFAT' 'Ventoy' 60GB 40GB
    $script:Sim.Disks += , (New-SimDisk 3 'Kingston DataTraveler' 64GB 'USB' 'Removable Media' 'KT0001' @($v))
    $script:Sim.Disks += , (New-SimDisk 4 'Generic Card Reader' 32GB 'USB' 'Removable Media' 'CR0001' @((New-SimVolume 'H')) -ReadOnly)
    $script:Sim.Disks += , (New-SimDisk 5 'Offline Stick' 32GB 'USB' 'Removable Media' 'OF0001' @((New-SimVolume 'I')) -Offline)
    $all = $script:Sim.Disks
    $os = Test-WdmDiskEligibility $all[0] $all
    Assert-True (-not $os.Update.Allowed -and -not $os.Create.Allowed) 'OS disk refused for everything'
    Assert-Match $os.Create.Reasons 'running Windows' 'reason'
    $data = Test-WdmDiskEligibility $all[1] $all
    Assert-True (-not $data.Create.Allowed -and -not $data.Update.Allowed) 'internal data disk refused'
    Assert-Match $data.Create.Reasons 'not on the USB bus' 'bus reason'
    $stick = Test-WdmDiskEligibility $all[2] $all
    Assert-True ($stick.Update.Allowed -and $stick.Create.Allowed) 'removable USB stick allowed'
    Assert-Match (Test-WdmDiskEligibility $all[3] $all).Create.Reasons 'Ventoy' 'Ventoy never erased'
    Assert-True (-not (Test-WdmDiskEligibility $all[3] $all).Update.Allowed) 'Ventoy not updated'
    Assert-Match (Test-WdmDiskEligibility $all[4] $all).Update.Reasons 'read-only' 'read-only'
    Assert-Match (Test-WdmDiskEligibility $all[5] $all).Create.Reasons 'offline' 'offline'
    $sysByLetter = New-SimDisk 6 'USB Boot Stick' 32GB 'USB' 'Removable Media' 'BOOT01' @((New-SimVolume 'C'))
    Assert-True (-not (Test-WdmDiskEligibility $sysByLetter $all).Create.Allowed) 'a USB disk holding the system drive letter (Windows To Go) is protected even without the IsSystem flag'
}

$tests['disks: external USB hard disks are update-only; identical twins, no serial and huge drives cannot be erased'] = {
    Reset-Sim; $e = Set-SimComputer
    $ext = New-SimDisk 3 'WD Elements 25A3' 2000GB 'USB' 'External hard disk media' 'WX0001' @((New-SimVolume 'F' 'NTFS' 'Backup' 2000GB 900GB))
    $e1 = Test-WdmDiskEligibility $ext @($script:Sim.Disks + @($ext))
    Assert-True ($e1.Update.Allowed -and -not $e1.Create.Allowed) 'external disk: update only'
    Assert-Match $e1.Create.Reasons 'external hard disks may hold valuable data' 'reason'
    $twinA = New-SimDisk 4 'Generic Flash Disk' 16GB 'USB' 'Removable Media' 'SAME' @((New-SimVolume 'J'))
    $twinB = New-SimDisk 5 'Generic Flash Disk' 16GB 'USB' 'Removable Media' 'SAME' @((New-SimVolume 'K'))
    $tw = Test-WdmDiskEligibility $twinA @($twinA, $twinB)
    Assert-Match $tw.Create.Reasons 'same identity' 'identical twins cannot be told apart'
    $noSerial = New-SimDisk 6 'NoName' 16GB 'USB' 'Removable Media' '' @((New-SimVolume 'L'))
    Assert-Match (Test-WdmDiskEligibility $noSerial @($noSerial)).Create.Reasons 'identified reliably' 'no serial'
    $sameModel = New-SimDisk 7 'SanDisk Ultra USB 3.0' 30GB 'USB' 'Removable Media' 'OTHERSERIAL' @((New-SimVolume 'M'))
    Assert-Match (Test-WdmDiskEligibility $script:Sim.Disks[2] @($script:Sim.Disks + @($sameModel))).Warnings 'same model and capacity' 'same-capacity sticks: check carefully'
    $huge = New-SimDisk 8 'Big Stick' 512GB 'USB' 'Removable Media' 'BIG1' @((New-SimVolume 'N'))
    Assert-Match (Test-WdmDiskEligibility $huge @($huge)).Create.Reasons 'larger than 256 GB' 'unusual capacity'
    $fp1 = Get-WdmDiskFingerprint $script:Sim.Disks[2]
    $copy = $script:Sim.Disks[2].Clone(); $copy.Number = 9; $copy.Partitions = @()
    Assert-Equal (Get-WdmDiskFingerprint $copy) $fp1 'identity does not depend on disk number or letters'
}

$tests['image: WIM, ESD and split-image metadata are read without DISM; damaged images are rejected'] = {
    Reset-Sim
    $w = Join-Path $script:Sim.Root 'i\install.wim'; New-SimWim $w (Get-ConsumerImages)
    $i = Read-WdmImageInfo $w
    Assert-Equal "$($i.format) $($i.imageCount) $(@($i.images).Count)" 'WIM 7 7' 'seven editions'
    $pro = @($i.images | Where-Object { $_.editionId -eq 'Professional' })[0]
    Assert-Equal "$($pro.index) $($pro.name) $($pro.architecture) $($pro.build).$($pro.revision)" '6 Windows 11 Pro amd64 26200.9711' 'Pro at index 6 with build and revision'
    $esd = Join-Path $script:Sim.Root 'i\install.esd'; New-SimWim $esd @((Img 1 'Windows 11 Pro' 'Professional' 'arm64' 26100 4351))
    Assert-Equal (Read-WdmImageInfo $esd).format 'ESD' 'ESD'
    $swm = Join-Path $script:Sim.Root 'i\install.swm'; New-SimWim $swm (Get-ConsumerImages) -Part 1 -Parts 3
    $s = Read-WdmImageInfo $swm
    Assert-Equal "$($s.format) $($s.partNumber)/$($s.totalParts)" 'SWM 1/3' 'split image part'
    foreach ($bad in @(@{ BadMagic = $true; Expect = 'not a Windows image' }, @{ BadXml = $true; Expect = 'not readable' })) {
        $b = Join-Path $script:Sim.Root ("i\bad-" + [Guid]::NewGuid().ToString('N') + '.wim')
        if ($bad.ContainsKey('BadMagic')) { New-SimWim $b (Get-ConsumerImages) -BadMagic } else { New-SimWim $b (Get-ConsumerImages) -BadXml }
        try { Read-WdmImageInfo $b | Out-Null; throw 'no error' } catch { Assert-True ($_.Exception.Message -match $bad.Expect) "rejected: $($_.Exception.Message)" }
    }
    $x = Join-Path $script:Sim.Root 'i\xxe.wim'; New-SimWim $x @() -RawXml '<!DOCTYPE WIM [<!ENTITY e SYSTEM "file:///c:/windows/win.ini">]><WIM>&e;</WIM>'
    try { Read-WdmImageInfo $x | Out-Null; throw 'no error' } catch { Assert-True ($_.Exception.Message -match 'not readable') 'DTD refused' }
}

$tests['compatibility: the requested edition is found by EditionId (not index 1, not by name); a missing edition or architecture blocks'] = {
    Reset-Sim
    $rel = Get-WdmReleaseInfo
    $req = [ordered]@{ editionMode = 'genericKey'; dismEditionId = 'Professional'; editionName = 'Windows 11 Pro'; architectures = @('amd64'); minimumBuild = 22000 }
    $img = @{ images = @(Get-ConsumerImages) }
    $c = Test-WdmCompatibility $req $img $rel
    Assert-Equal "$(@($c.Blockers).Count) $($c.Selected.index)" '0 6' 'Pro selected at index 6'
    $homeOnly = @{ images = @((Img 1 'Windows 11 Home' 'Core'), (Img 2 'Windows 11 Home Single Language' 'CoreSingleLanguage')) }
    Assert-Match (Test-WdmCompatibility $req $homeOnly $rel).Blockers 'does not contain.*never changed silently' 'Pro missing: blocked, never Home instead'
    $misnamed = @{ images = @((Img 1 'Windows 11 Pro' 'Core')) }
    Assert-True (@((Test-WdmCompatibility $req $misnamed $rel).Blockers).Count -eq 1) 'a display name is not an edition id'
    Assert-Match (Test-WdmCompatibility $req @{ images = @(Get-ConsumerImages -Arch arm64) } $rel).Blockers 'arm64.*amd64' 'wrong architecture'
    $two = @{ images = @((Img 1 'Windows 11 Pro' 'Professional'), (Img 2 'Windows 11 Pro (alt)' 'Professional')) }
    Assert-Match (Test-WdmCompatibility $req $two $rel).Warnings 'indexes 1, 2' 'two candidates named explicitly'
    $inter = [ordered]@{ editionMode = 'interactive'; dismEditionId = ''; editionName = 'interactive'; architectures = @('amd64'); minimumBuild = 22000 }
    Assert-Match (Test-WdmCompatibility $inter $img $rel).Warnings 'chosen during Windows Setup' 'interactive edition'
    Assert-Match (Test-WdmCompatibility $req @{ images = @(Get-ConsumerImages -Build 19045) } $rel).Blockers 'not Windows 11|22000' 'Windows 10 media refused'
}

$tests['freshness: current, outdated, end of service, newer than known; offline uses the cache; the online page refreshes it'] = {
    Reset-Sim
    $rel = Get-WdmReleaseInfo
    Assert-Equal $rel.mode 'cached' 'offline by default'
    Assert-Equal (Get-WdmFreshness (Img 1 'P' 'Professional' 'amd64' 26200 9711) $rel 'Professional').status 'Current' 'latest known revision'
    $o = Get-WdmFreshness (Img 1 'P' 'Professional' 'amd64' 26200 1234) $rel 'Professional'
    Assert-True ($o.status -eq 'Outdated' -and $o.message -match 'not fully patched' -and $o.message -match '26200.9711') "outdated image: $($o.message)"
    Assert-Equal (Get-WdmFreshness (Img 1 'P' 'Professional' 'amd64' 26100 9711) $rel 'Professional').status 'EndOfService' '24H2 Pro has reached end of updates'
    Assert-Equal (Get-WdmFreshness (Img 1 'E' 'Enterprise' 'amd64' 26100 9711) $rel 'Enterprise').status 'Current' '24H2 Enterprise is still serviced'
    Assert-Equal (Get-WdmFreshness (Img 1 'P' 'Professional' 'amd64' 26400 1) $rel 'Professional').status 'NewerThanKnown' 'unknown newer build'
    $script:Sim.Online = '<h3>Version 27H2 (OS build 26400)</h3><td>26400.120</td><h3>Version 25H2 (OS build 26200)</h3><td>26200.9800</td><td>26200.9711</td>'
    $on = Get-WdmReleaseInfo -Online
    Assert-Equal $on.mode 'online' 'online refresh'
    Assert-Equal (Get-WdmFreshness (Img 1 'P' 'Professional' 'amd64' 26200 9711) $on 'Professional').status 'Outdated' 'newer revision found online'
    Assert-Equal (Get-WdmFreshness (Img 1 'P' 'Professional' 'amd64' 26400 120) $on 'Professional').version '27H2' 'new release found online'
    $script:Sim.Online = ''
    $off = Get-WdmReleaseInfo -Online
    Assert-True ($off.mode -eq 'cached' -and $off.message -match 'Online check failed.*verified 2026-10-22') 'failure falls back to the cache with its date'
}

$tests['package: the real deployment ZIP validates; the answer file is pinned and its embedded scripts match the manifest'] = {
    Reset-Sim
    $p = Read-WdmPackage $script:MainZip
    Assert-True $p.Ok "valid: $($p.Problems -join '; ')"
    Assert-Equal $p.Requirements.dismEditionId 'Professional' 'edition from the media block'
    Assert-Equal (@($p.Requirements.architectures) -join ',') 'amd64' 'architecture'
    Assert-True ($p.Media -and $p.Media['answerFile']['sha256'] -match '^[0-9A-F]{64}$') 'answer file hash pinned'
    Assert-Equal @($p.Warnings).Count 0 'no warnings for a current package'
    $m = Read-WdmPackage $script:MigZip
    Assert-True ($m.Ok -and $m.Backup.folderName -eq $script:MigBackupFolder) 'migration package pins its backup'
}

function New-TamperedZip {
    param([string] $Name, [scriptblock] $Change)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $dir = Join-Path $script:Sim.Root "pkg-$Name"
    [IO.Compression.ZipFile]::ExtractToDirectory($script:MainZip, $dir)
    & $Change $dir
    $zip = Join-Path $script:Sim.Root "$Name.zip"
    [IO.Compression.ZipFile]::CreateFromDirectory($dir, $zip)
    return $zip
}

$tests['package: tampered files, a changed answer file, extra or unsafe entries and wrong names are rejected'] = {
    Reset-Sim
    $t = New-TamperedZip 'script' { param($d) Add-Content -LiteralPath (Join-Path $d 'WindowsDeployment\scripts\common\DeploymentCommon.ps1') '# changed' }
    Assert-Match (Read-WdmPackage $t).Problems 'Modified or damaged: scripts/common/DeploymentCommon.ps1' 'modified script'
    $a = New-TamperedZip 'answer' { param($d) $f = Join-Path $d 'autounattend.xml'; [IO.File]::WriteAllText($f, ([IO.File]::ReadAllText($f) -replace '<ComputerName>[^<]*</ComputerName>', '<ComputerName>EVIL</ComputerName>')) }
    Assert-Match (Read-WdmPackage $a).Problems 'answer file does not match the SHA-256' 'changed answer file'
    $x = New-TamperedZip 'extra' { param($d) [IO.File]::WriteAllText((Join-Path $d 'WindowsDeployment\scripts\evil.ps1'), 'calc') }
    Assert-Match (Read-WdmPackage $x).Problems 'Unexpected file in the package' 'unlisted file'
    $r = New-TamperedZip 'root' { param($d) [IO.File]::WriteAllText((Join-Path $d 'run-me.cmd'), 'calc') }
    Assert-Match (Read-WdmPackage $r).Problems 'Unexpected entry' 'unexpected root entry'
    # A crafted ZIP with a traversal entry name (the system ZIP API would refuse to create one by path).
    $z = Join-Path $script:Sim.Root 'traversal.zip'
    Add-Type -AssemblyName System.IO.Compression
    $fs = [IO.File]::Open($z, 'Create'); $arc = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
    $en = $arc.CreateEntry('../../evil.txt'); $s = $en.Open(); $s.WriteByte(65); $s.Dispose(); $arc.Dispose(); $fs.Dispose()
    Assert-Match (Read-WdmPackage $z).Problems 'Unsafe entry' 'traversal refused'
    Assert-True (-not (Test-Path (Join-Path $script:Sim.Root 'evil.txt'))) 'nothing written outside'
    $n = New-TamperedZip 'name' { param($d) Rename-Item -LiteralPath (Join-Path $d 'autounattend.xml') 'notautounattend.xml' }
    Assert-Match (Read-WdmPackage $n).Problems 'exactly one answer file' 'renamed answer file'
    Assert-Match (Read-WdmPackage (Join-Path $script:Sim.Root 'missing.zip')).Problems 'not found' 'missing package'
    [IO.File]::WriteAllText((Join-Path $script:Sim.Root 'notzip.zip'), 'not a zip')
    Assert-Match (Read-WdmPackage (Join-Path $script:Sim.Root 'notzip.zip')).Problems 'not a readable ZIP' 'not a ZIP'
}

$tests['package: a pre-Phase 7 package (no media block) still validates its embedded scripts; a foreign answer file is caught'] = {
    Reset-Sim
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $old = Join-Path $script:Sim.Root 'old'
    [IO.Compression.ZipFile]::ExtractToDirectory($script:MainZip, $old)
    $mf = Join-Path $old 'WindowsDeployment\deployment-manifest.json'
    $m = ConvertTo-WdmHashtable ([IO.File]::ReadAllText($mf) | ConvertFrom-Json); $m.Remove('media')
    [IO.File]::WriteAllText($mf, (ConvertTo-WdmJson $m))
    $p = Read-WdmPackage $old
    Assert-True $p.Ok "old package valid: $($p.Problems -join '; ')"
    Assert-Match $p.Warnings 'made before Phase 7' 'warning'
    Assert-Equal $p.Requirements.dismEditionId 'Professional' 'edition from the display name'
    # The answer file of another deployment (here: the migration package) is detected.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $mig = Join-Path $script:Sim.Root 'mig'
    [IO.Compression.ZipFile]::ExtractToDirectory($script:MigZip, $mig)
    Copy-Item -LiteralPath (Join-Path $mig 'autounattend.xml') -Destination (Join-Path $old 'autounattend.xml') -Force
    Assert-Match (Read-WdmPackage $old).Problems 'different deployment package|answer file.*differs|does not carry' 'foreign answer file'
}

$tests['Update: an existing Windows USB gets the deployment at the root; Windows and unrelated files are untouched'] = {
    Reset-Sim; $e = Set-SimComputer
    $before = Get-TreeHashes $e.Root
    $plan = New-WdmPlan Update $script:MainZip '' 'E:'
    Assert-Equal @($plan.blockers).Count 0 "no blockers: $(@($plan.blockers) -join '; ')"
    Assert-True (-not @($plan.operations | Where-Object { $_.destructive }).Count) 'nothing destructive'
    Assert-Equal $plan.image.selected.index 6 'Pro found at index 6'
    Assert-Equal (Get-TreeHashes $e.Root).Count $before.Count 'planning changed nothing'
    $r = Invoke-WdmApply $plan
    Assert-Equal $r.status 'ReadyForInstallation' "ready: $(Get-Problems $r)"
    Assert-True (Test-Path (Join-Path $e.Root 'autounattend.xml')) 'answer file at the root'
    Assert-True (-not (Test-Path (Join-Path $e.Root 'WindowsDeployment\autounattend.xml'))) 'not in a subfolder'
    Assert-True (Test-Path (Join-Path $e.Root 'WindowsDeployment\deployment-manifest.json')) 'package at the root'
    Assert-True (Test-Path (Join-Path $e.Root 'WindowsDeployment\scripts\bootstrap\Initialize-Deployment.ps1')) 'scripts in place'
    $after = Get-TreeHashes $e.Root
    foreach ($k in $before.Keys) { Assert-Equal $after[$k] $before[$k] "unchanged: $k" }
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $e.Root 'customer notes.txt'))) 'unrelated file' 'unrelated file kept'
    Assert-True ($r.bootTested -eq $false -and $r.mediaStructureValidated) 'structure validated, boot not tested'
    $text = Format-WdmReport $r
    Assert-True ($text -match 'Boot not tested') 'the report says so'
    Assert-True (-not (Test-Path (Join-Path $e.Root 'WindowsDeployment.wdb-new'))) 'no staging folder left'
    Assert-Equal @(Get-ChildItem (Join-Path (Get-WdmStateRoot) 'staging') -ErrorAction SilentlyContinue).Count 0 'local staging removed'
    # Deployment engines read the same layout: the package on the drive verifies with the deployment's own checks.
    Assert-True (Read-WdmPackage $e.Root).Ok 'the drive is a valid package for setup.cmd / recovery'
}

$tests['Update: an existing deployment is never merged; with replace it is kept in WDB-previous; the same one is repaired in place'] = {
    Reset-Sim; $e = Set-SimComputer
    Assert-Equal (Invoke-WdmApply (New-WdmPlan Update $script:MigZip $script:MigBackup 'E:')).status 'ReadyForInstallation' 'first deployment'
    $p2 = New-WdmPlan Update $script:MainZip '' 'E:'
    Assert-Match $p2.blockers 'already has a deployment.*never merged' 'blocked without replace'
    $p3 = New-WdmPlan Update $script:MainZip '' 'E:' -Replace
    Assert-Match @($p3.operations | ForEach-Object { $_.description }) 'WDB-previous' 'previous is kept'
    $r = Invoke-WdmApply $p3
    Assert-Equal $r.status 'ReadyForInstallation' 'replaced'
    $prev = @(Get-ChildItem (Join-Path $e.Root 'WDB-previous') -Directory)
    Assert-Equal $prev.Count 1 'one kept copy'
    Assert-True (Test-Path (Join-Path $prev[0].FullName 'autounattend.xml')) 'old answer file kept (not at the root, so Setup ignores it)'
    Assert-True (Test-Path (Join-Path $prev[0].FullName "WindowsDeployment\backups\$script:MigBackupFolder")) 'old backup kept, not deleted'
    Assert-True (-not (Test-Path (Join-Path $e.Root "WindowsDeployment\backups"))) 'the new deployment has no stray backup'
    # Repair: damage two files of the current deployment; only those are rewritten.
    $f1 = Join-Path $e.Root 'WindowsDeployment\scripts\common\DeploymentCommon.ps1'; Remove-Item $f1
    $f2 = Join-Path $e.Root 'WindowsDeployment\setup.ps1'; Add-Content $f2 '# damaged'
    Assert-Equal (Test-WdmMedia $e.Root (Read-WdmPackage $script:MainZip)).status 'Failed' 'damage detected'
    $intact = Join-Path $e.Root 'WindowsDeployment\README.txt'; $stamp = (Get-Item $intact).LastWriteTimeUtc
    $p4 = New-WdmPlan Update $script:MainZip '' 'E:'
    Assert-Match $p4.warnings 'already has this deployment' 'recognised'
    $r4 = Invoke-WdmApply $p4; Assert-Equal $r4.status 'ReadyForInstallation' "repaired: $($r4['message']) $(Get-Problems $r4)"
    Assert-Equal (Get-Item $intact).LastWriteTimeUtc $stamp 'intact files are not rewritten'
    Assert-Equal @(Get-ChildItem (Join-Path $e.Root 'WDB-previous') -Directory).Count 1 'a repair keeps no extra copy'
}

$tests['Update: interrupted copy is never reported ready; the previous state stays intact; rerunning repairs it'] = {
    Reset-Sim; $e = Set-SimComputer
    $plan = New-WdmPlan Update $script:MainZip '' 'E:'
    $script:Sim.CopyFailAfter = 5
    $r = Invoke-WdmApply $plan
    Assert-Equal $r.status 'Incomplete' 'not ready'
    Assert-True (-not (Test-Path (Join-Path $e.Root 'autounattend.xml'))) 'no answer file on a half-prepared drive'
    Assert-True (-not (Test-Path (Join-Path $e.Root 'WindowsDeployment'))) 'no half-copied deployment in the live location'
    $state = Read-WdmJsonFile (Join-Path $e.Root 'wdb-media-state.json')
    Assert-Equal $state.status 'Failed' 'journal on the drive'
    Assert-Equal (Test-WdmMedia $e.Root).status 'InspectionOnly' 'no deployment: inspection only'
    $script:Sim.CopyFailAfter = -1
    $r2 = Invoke-WdmApply $plan
    Assert-Equal $r2.status 'ReadyForInstallation' "rerun repairs it: $($r2['message'])"
    Assert-Equal (Read-WdmJsonFile (Join-Path $e.Root 'wdb-media-state.json')).status 'Complete' 'journal complete'
}

$tests['Update: cancellation at a safe checkpoint; before any change it is a clean cancel, later the drive is Incomplete'] = {
    Reset-Sim; $e = Set-SimComputer
    $plan = New-WdmPlan Update $script:MainZip '' 'E:'
    $script:Sim.CancelAfter = 0
    $r = Invoke-WdmApply $plan
    Assert-Equal $r.status 'Cancelled' 'nothing done'
    Assert-True ($r.message -match 'before anything was changed') 'clean cancel'
    Reset-Sim; $e = Set-SimComputer
    $plan = New-WdmPlan Update $script:MainZip '' 'E:'
    $script:Sim.CancelAfter = 6
    $r = Invoke-WdmApply $plan
    Assert-Equal $r.status 'Incomplete' 'cancelled mid-way'
    Assert-True ($r.message -match 'incomplete') 'says so'
    Assert-True (-not (Test-Path (Join-Path $e.Root 'autounattend.xml'))) 'not boot-ready'
    $script:Sim.CancelAfter = -1; $script:Sim.Checkpoints = 0
    Assert-Equal (Invoke-WdmApply $plan).status 'ReadyForInstallation' 'finished on rerun'
}

$tests['Update: a changed letter, a removed or replaced drive stops before anything is written'] = {
    Reset-Sim; $e = Set-SimComputer
    $plan = New-WdmPlan Update $script:MainZip '' 'E:'
    $script:Sim.Disks[2].Partitions[0].DriveLetter = 'F'
    $r = Invoke-WdmApply $plan
    Assert-True ($r.status -eq 'Failed' -and $r.message -match 'no longer on the planned disk') "letter changed: $($r.message)"
    $script:Sim.Disks = @($script:Sim.Disks[0], $script:Sim.Disks[1])
    Assert-True ((Invoke-WdmApply $plan).message -match 'no longer connected') 'removed'
    $other = New-SimDisk 2 'SanDisk Ultra USB 3.0' 30GB 'USB' 'Removable Media' 'DIFFERENTSERIAL' @($e)
    $script:Sim.Disks = @($script:Sim.Disks + @($other))
    Assert-True ((Invoke-WdmApply $plan).message -match 'no longer connected or has changed') 'replaced by a look-alike'
    Assert-True (-not (Test-Path (Join-Path $e.Root 'autounattend.xml'))) 'nothing written'
}

$tests['Update: not Windows media, Ventoy, too little space and NTFS/exFAT media are handled honestly'] = {
    Reset-Sim; $e = Set-SimComputer
    Remove-Item (Join-Path $e.Root 'sources\boot.wim')
    Assert-Match (New-WdmPlan Update $script:MainZip '' 'E:').blockers 'not a Windows installation drive' 'not Windows media'
    Reset-Sim; $e = Set-SimComputer -StickFree 1MB
    Assert-Match (New-WdmPlan Update $script:MainZip '' 'E:').blockers 'Not enough space' 'capacity'
    Reset-Sim; $e = Set-SimComputer -StickFs 'NTFS'
    $p = New-WdmPlan Update $script:MainZip '' 'E:'
    Assert-True (@($p.blockers).Count -eq 0) 'NTFS (Rufus) media can be updated'
    Assert-Match $p.warnings 'UEFI:NTFS' 'with an explanation'
    Reset-Sim; $e = Set-SimComputer
    New-Item -ItemType Directory -Path (Join-Path $e.Root 'ventoy') | Out-Null
    Assert-Match (New-WdmPlan Update $script:MainZip '' 'E:').blockers 'Ventoy' 'Ventoy refused'
    Reset-Sim; $e = Set-SimComputer
    [IO.File]::WriteAllText((Join-Path $e.Root 'sources\ei.cfg'), "[EditionID]`nCore")
    Assert-Match (New-WdmPlan Update $script:MainZip '' 'E:').warnings 'ei.cfg' 'edition override reported'
}

$tests['Update: the edition and architecture of the drive must match the deployment'] = {
    Reset-Sim; $e = Set-SimComputer
    New-SimWim (Join-Path $e.Root 'sources\install.wim') @((Img 1 'Windows 11 Home' 'Core'), (Img 2 'Windows 11 Home Single Language' 'CoreSingleLanguage'))
    Assert-Match (New-WdmPlan Update $script:MainZip '' 'E:').blockers 'Windows 11 Pro.*does not contain' 'Home-only media refused for a Pro deployment'
    Reset-Sim; $e = Set-SimComputer
    New-SimWim (Join-Path $e.Root 'sources\install.wim') (Get-ConsumerImages -Arch arm64)
    Assert-Match (New-WdmPlan Update $script:MainZip '' 'E:').blockers 'arm64' 'Arm64 media refused for an x64 deployment'
    Reset-Sim; $e = Set-SimComputer
    New-SimWim (Join-Path $e.Root 'sources\install.wim') (Get-ConsumerImages -Build 26100 -Rev 2033)
    Assert-Match (New-WdmPlan Update $script:MainZip '' 'E:').warnings 'no longer receives updates' 'old release reported'
}

$tests['backup: the pinned Phase 6 backup is required, validated against its hash, copied and verified; others are refused'] = {
    Reset-Sim; $e = Set-SimComputer
    Assert-Match (New-WdmPlan Update $script:MigZip '' 'E:').blockers "choose that backup folder" 'required'
    $wrongName = Join-Path $script:Sim.Root 'WDB-AppBackup-OTHER'; Copy-Item $script:MigBackup $wrongName -Recurse
    Assert-Match (New-WdmPlan Update $script:MigZip $wrongName 'E:').blockers "expects '$script:MigBackupFolder'" 'another customer''s folder name'
    $tampered = Join-Path (Join-Path $script:Sim.Root 't') $script:MigBackupFolder; Copy-Item $script:MigBackup $tampered -Recurse
    [IO.File]::WriteAllText((Join-Path $tampered 'data\git\gitconfig'), "[user]`n`tname = Someone Else`n")
    Assert-Match (New-WdmPlan Update $script:MigZip $tampered 'E:').blockers 'Settings backup:.*(SHA-256|size)' 'modified backup'
    $forged = Join-Path (Join-Path $script:Sim.Root 'f') $script:MigBackupFolder; Copy-Item $script:MigBackup $forged -Recurse
    Add-Content (Join-Path $forged 'backup-manifest.json') ' '
    Assert-Match (New-WdmPlan Update $script:MigZip $forged 'E:').blockers 'expects' 'a different manifest (hash) is refused'
    $extra = Join-Path (Join-Path $script:Sim.Root 'x') $script:MigBackupFolder; Copy-Item $script:MigBackup $extra -Recurse
    [IO.File]::WriteAllText((Join-Path $extra 'data\git\stowaway.ps1'), 'evil')
    $plan = New-WdmPlan Update $script:MigZip $extra 'E:'
    Assert-Equal @($plan.blockers).Count 0 "an unlisted extra file does not block: $(@($plan.blockers) -join '; ')"
    $r = Invoke-WdmApply $plan
    Assert-Equal $r.status 'ReadyForInstallation' "ready with backup: $(Get-Problems $r)"
    $dst = Join-Path $e.Root "WindowsDeployment\backups\$script:MigBackupFolder"
    Assert-True (Test-Path (Join-Path $dst 'backup-manifest.json')) 'at WindowsDeployment\backups\<folder>'
    Assert-True (-not (Test-Path (Join-Path $dst 'data\git\stowaway.ps1'))) 'unlisted file not copied'
    Assert-Match @($r.checks | ForEach-Object { "$($_.check) $($_.result) $($_.detail)" }) 'Settings backup Pass' 'backup verified on the drive'
    Assert-True (Test-Path $extra) 'the source backup is never deleted'
    $text = (Format-WdmReport $r) + (ConvertTo-WdmJson $r)
    Assert-True ($text -notmatch 'Alex Example') 'backup contents never reach the report'
    Assert-Match (Get-Lines $plan) 'personal configuration data' 'privacy warning'
}

$tests['backup: archives are validated (corrupt or traversal refused); a backup not needed is not copied; space is counted'] = {
    Reset-Sim; $e = Set-SimComputer
    $bad = Join-Path $script:Sim.Root 'corrupt.zip'; [IO.File]::WriteAllText($bad, 'not a zip')
    Assert-Match (New-WdmPlan Update $script:MigZip $bad 'E:').blockers 'Settings backup|could not be opened' 'corrupt archive'
    Add-Type -AssemblyName System.IO.Compression
    $z = Join-Path $script:Sim.Root 'trav.zip'
    $fs = [IO.File]::Open($z, 'Create'); $arc = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
    $en = $arc.CreateEntry('../evil.json'); $s = $en.Open(); $s.WriteByte(65); $s.Dispose(); $arc.Dispose(); $fs.Dispose()
    Assert-Match (New-WdmPlan Update $script:MigZip $z 'E:').blockers 'Unsafe entry|could not be opened' 'traversal archive'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $okZip = Join-Path $script:Sim.Root 'backup.zip'; [IO.Compression.ZipFile]::CreateFromDirectory($script:MigBackup, $okZip)
    $p = New-WdmPlan Update $script:MigZip $okZip 'E:'
    Assert-Equal @($p.blockers).Count 0 "a valid backup ZIP is accepted: $(@($p.blockers) -join '; ')"
    Assert-True ($p.backup.bytes -gt 0 -and @($p.operations | Where-Object { $_.kind -eq 'placeBackup' }).Count -eq 1) 'counted and planned'
    $p2 = New-WdmPlan Update $script:MainZip $script:MigBackup 'E:'
    Assert-Match $p2.warnings 'does not restore settings; it is not copied' 'not needed'
    Assert-True (-not @($p2.operations | Where-Object { $_.kind -eq 'placeBackup' }).Count) 'not copied'
    Reset-Sim; $e = Set-SimComputer -StickFree 2MB
    Assert-Match (New-WdmPlan Update $script:MigZip $script:MigBackup 'E:').blockers 'Not enough space' 'inadequate capacity'
}

function Set-SimIso {
    param([object[]] $Images = (Get-ConsumerImages), [string] $ImageName = 'install.wim', [int] $Pad = 0)
    $isoRoot = Join-Path $script:Sim.Root 'iso-mounted'
    New-SimWindowsMedia $isoRoot $Images $ImageName $Pad
    $isoFile = Join-Path $script:Sim.Root 'Win11_25H2_English_x64.iso'
    [IO.File]::WriteAllText($isoFile, 'simulated ISO container')
    $script:Sim.Mounted[$isoFile] = $isoRoot + '\'
    return $isoFile
}

$tests['Create: an ISO onto a positively identified stick, after typed confirmation and elevation; layout for 16 GB and 64 GB'] = {
    Reset-Sim; $e = Set-SimComputer
    $iso = Set-SimIso
    $plan = New-WdmPlan Create $script:MainZip '' '' $iso 2
    Assert-Equal @($plan.blockers).Count 0 "no blockers: $(@($plan.blockers) -join '; ')"
    Assert-True ($plan.target.confirmCode -match '^ERASE-2-[0-9A-F]{6}$') 'confirmation code for this disk'
    Assert-True (@($plan.operations | Where-Object { $_.destructive }).Count -eq 1) 'one destructive step, named'
    Assert-Match (Format-WdmPlan $plan) 'ERASES DATA' 'the preview says it erases'
    Assert-Match @($plan.target.existingVolumes) "E: FAT32 'ESD-USB'" 'existing volumes listed'
    Assert-Equal @($plan.layout.partitions).Count 1 'a 30 GB stick: one FAT32 partition'
    Assert-Equal $script:Sim.Partitioned.Count 0 'planning erased nothing'
    $script:Sim.Elevated = $false
    Assert-True ((Invoke-WdmApply $plan $plan.target.confirmCode).message -match 'administrator rights') 'needs elevation'
    $script:Sim.Elevated = $true
    Assert-True ((Invoke-WdmApply $plan 'ERASE').message -match 'Confirmation does not match') 'wrong code refused'
    Assert-True ((Invoke-WdmApply $plan ($plan.target.confirmCode.ToLowerInvariant())).message -match 'Confirmation does not match') 'case-sensitive'
    Assert-Equal $script:Sim.Partitioned.Count 0 'nothing erased without the code'
    $r = Invoke-WdmApply $plan $plan.target.confirmCode
    Assert-Equal $r.status 'ReadyForInstallation' "created: $($r['message']) $(Get-Problems $r)"
    Assert-Equal $script:Sim.Partitioned.Count 1 'erased once'
    $root = $script:Sim.Disks[2].Partitions[0].Root
    Assert-Equal (Get-WdmFileSha256 (Join-Path $root 'efi\boot\bootx64.efi')) (Get-WdmFileSha256 (Join-Path $script:Sim.Mounted[$iso] 'efi\boot\bootx64.efi')) 'Microsoft boot loader copied unchanged (Secure Boot)'
    Assert-True (Test-Path (Join-Path $root 'autounattend.xml')) 'deployment added'
    # 64 GB stick: FAT32 for Setup (Windows formats FAT32 up to 32 GB) and NTFS for the rest.
    Reset-Sim; [void] (Set-SimComputer); $script:Sim.Disks[2].Size = 64GB
    $p64 = New-WdmPlan Create $script:MainZip '' '' (Set-SimIso) 2
    Assert-Equal "$(@($p64.layout.partitions).Count) $($p64.layout.partitions[0].fileSystem) $($p64.layout.partitions[1].fileSystem)" '2 FAT32 NTFS' 'two partitions'
    Assert-True ([int64] $p64.layout.partitions[0].bytes -le 32GB) 'FAT32 within the Windows format limit'
    Assert-True ([int64] $p64.layout.partitions[1].bytes -gt 30GB) 'the rest is usable, not wasted'
    $pn = New-WdmPlan Create $script:MainZip '' '' (Set-SimIso) 2 -NoData
    Assert-Equal @($pn.layout.partitions).Count 1 'data partition optional'
}

$tests['Create: an image over 4 GB is split into install.swm (ESD exported first); other huge files block'] = {
    Reset-Sim; [void] (Set-SimComputer)
    $script:Fat32MaxFile = 2MB
    $iso = Set-SimIso -Pad 3145728
    $plan = New-WdmPlan Create $script:MainZip '' '' $iso 2
    Assert-True ($plan.image.split -and -not $plan.image.export) 'WIM: split'
    $r = Invoke-WdmApply $plan $plan.target.confirmCode
    Assert-Equal $r.status 'ReadyForInstallation' "split media ready: $(Get-Problems $r)"
    $root = $script:Sim.Disks[2].Partitions[0].Root
    Assert-True (-not (Test-Path (Join-Path $root 'sources\install.wim'))) 'oversized install.wim not copied'
    Assert-True ((Test-Path (Join-Path $root 'sources\install.swm')) -and (Test-Path (Join-Path $root 'sources\install2.swm'))) 'install.swm parts in sources'
    Assert-Equal $script:Sim.Splits 1 'DISM split once'
    Assert-Match @($r.checks | ForEach-Object { "$($_.check) $($_.result) $($_.detail)" }) 'Split image parts Pass 2 of 2' 'parts verified'
    Reset-Sim; [void] (Set-SimComputer)
    $script:Fat32MaxFile = 2MB
    $iso = Set-SimIso -ImageName 'install.esd' -Pad 3145728
    $plan = New-WdmPlan Create $script:MainZip '' '' $iso 2
    Assert-True ($plan.image.split -and $plan.image.export) 'ESD: export, then split'
    Assert-Equal (Invoke-WdmApply $plan $plan.target.confirmCode).status 'ReadyForInstallation' 'ESD media ready'
    Assert-Equal "$($script:Sim.Exports) $($script:Sim.Splits)" '1 1' 'DISM export and split'
    Reset-Sim; [void] (Set-SimComputer)
    $script:Fat32MaxFile = 2MB
    $iso = Set-SimIso
    [IO.File]::WriteAllBytes((Join-Path $script:Sim.Mounted[$iso] 'sources\huge.cab'), (New-Object byte[] 3145728))
    Assert-Match (New-WdmPlan Create $script:MainZip '' '' $iso 2).blockers 'huge.cab is larger than 4 GB' 'never copied to FAT32 and reported as success'
}

$tests['Create: the OS disk, an external disk or a substituted disk is never erased, even with a forged plan'] = {
    Reset-Sim; [void] (Set-SimComputer)
    $iso = Set-SimIso
    Assert-Match (New-WdmPlan Create $script:MainZip '' '' $iso 0).blockers 'cannot be erased: it holds the running Windows' 'OS disk'
    Assert-Match (New-WdmPlan Create $script:MainZip '' '' $iso 1).blockers 'cannot be erased' 'internal disk'
    Assert-Match (New-WdmPlan Create $script:MainZip '' '' $iso -1).blockers 'No disk is ever chosen automatically' 'no default disk'
    $plan = New-WdmPlan Create $script:MainZip '' '' $iso 2
    # Forge: point the approved plan at the OS disk.
    $forged = ConvertTo-WdmHashtable ((ConvertTo-WdmJson $plan) | ConvertFrom-Json)
    $forged.target.fingerprint = Get-WdmDiskFingerprint $script:Sim.Disks[0]; $forged.target.diskNumber = 0; $forged.planId = '0123456789ABCDEF'
    $r = Invoke-WdmApply $forged $plan.target.confirmCode
    Assert-True ($r.message -match 'cannot be erased|holds the running Windows|Confirmation') "forged plan refused: $($r.message)"
    Assert-Equal $script:Sim.Partitioned.Count 0 'nothing erased'
    # The stick is swapped for another one after confirmation, just before erasing.
    $script:Sim.BeforePartition = $null
    $script:Sim.Disks[2] = New-SimDisk 2 'SanDisk Ultra USB 3.0' 30GB 'USB' 'Removable Media' 'ANOTHERSTICK' @($script:Sim.Disks[2].Partitions)
    $r = Invoke-WdmApply $plan $plan.target.confirmCode
    Assert-True ($r.message -match 'no longer connected or has changed') 'substituted disk refused'
    Assert-Equal $script:Sim.Partitioned.Count 0 'still nothing erased'
}

$tests['Create: an interrupted erase is never resumed without a new plan; an interrupted copy resumes without erasing again'] = {
    Reset-Sim; [void] (Set-SimComputer)
    $iso = Set-SimIso
    $plan = New-WdmPlan Create $script:MainZip '' '' $iso 2
    $script:Sim.BeforePartition = { throw 'simulated power loss while partitioning' }
    $r = Invoke-WdmApply $plan $plan.target.confirmCode
    Assert-Equal $r.status 'Incomplete' 'incomplete'
    $script:Sim.BeforePartition = $null
    $r = Invoke-WdmApply $plan $plan.target.confirmCode
    Assert-True ($r.message -match 'never resumed automatically') 'erase not resumed'
    Assert-Equal $script:Sim.Partitioned.Count 0 'not erased a second time'
    Reset-Sim; [void] (Set-SimComputer)
    $iso = Set-SimIso
    $plan = New-WdmPlan Create $script:MainZip '' '' $iso 2
    $script:Sim.CopyFailAfter = 4
    Assert-Equal (Invoke-WdmApply $plan $plan.target.confirmCode).status 'Incomplete' 'copy interrupted'
    Assert-Equal (Test-WdmMedia $script:Sim.Disks[2].Partitions[0].Root (Read-WdmPackage $script:MainZip)).status 'Incomplete' 'Verify says Incomplete, never ready'
    $script:Sim.CopyFailAfter = -1
    Assert-Equal (Invoke-WdmApply $plan $plan.target.confirmCode).status 'ReadyForInstallation' 'resumed'
    Assert-Equal $script:Sim.Partitioned.Count 1 'erased only once'
}

$tests['Create: ISO checks: hash mismatch, unsigned boot files and non-Windows ISOs are refused; provenance is stated precisely'] = {
    Reset-Sim; [void] (Set-SimComputer)
    $iso = Set-SimIso
    $p = New-WdmPlan Create $script:MainZip '' '' $iso 2
    Assert-True ($p.target.iso.provenance -match 'Not established') 'no claim of authenticity without a hash'
    Assert-Match (New-WdmPlan Create $script:MainZip '' '' $iso 2 -ExpectedIsoSha256 ('0' * 64)).blockers 'does not match the SHA-256' 'hash mismatch'
    $good = Get-WdmFileSha256 $iso
    Assert-True ((New-WdmPlan Create $script:MainZip '' '' $iso 2 -ExpectedIsoSha256 $good).target.iso.provenance -match 'matches the hash you entered') 'hash match stated as such'
    $script:Sim.Signature = @{ Status = 'NotSigned'; Signer = '' }
    Assert-Match (New-WdmPlan Create $script:MainZip '' '' $iso 2).blockers 'not validly signed by Microsoft' 'unsigned boot files'
    $script:Sim.Signature = @{ Status = 'Valid'; Signer = 'CN=Someone, O=Not Microsoft' }
    Assert-Match (New-WdmPlan Create $script:MainZip '' '' $iso 2).blockers 'not validly signed by Microsoft' 'wrong signer'
    $script:Sim.Signature = @{ Status = 'Valid'; Signer = 'CN=Microsoft Windows, O=Microsoft Corporation' }
    Remove-Item (Join-Path $script:Sim.Mounted[$iso] 'setup.exe')
    Assert-Match (New-WdmPlan Create $script:MainZip '' '' $iso 2).blockers 'not Windows installation media' 'not a Windows ISO'
    Assert-Match (New-WdmPlan Create $script:MainZip '' '' (Join-Path $script:Sim.Root 'none.iso') 2).blockers 'ISO not found.*microsoft.com/software-download/windows11' 'official download link'
}

$tests['Inspect and Verify are read-only and report missing, misplaced, conflicting and tampered files'] = {
    Reset-Sim; $e = Set-SimComputer
    Assert-Equal (Invoke-WdmApply (New-WdmPlan Update $script:MainZip '' 'E:')).status 'ReadyForInstallation' 'prepared'
    $before = Get-TreeHashes $e.Root
    $i = Test-WdmMedia $e.Root
    Assert-Match @($i.checks | ForEach-Object { $_.check }) 'Package origin' 'self-check says it verified the drive against itself'
    $after = Get-TreeHashes $e.Root
    Assert-Equal ($after.Keys -join ',') ($before.Keys -join ',') 'no file added or removed'
    foreach ($k in $before.Keys) { Assert-Equal $after[$k] $before[$k] "unchanged $k" }
    $pkg = Read-WdmPackage $script:MainZip
    New-Item -ItemType Directory -Path (Join-Path $e.Root 'Extra') | Out-Null
    Copy-Item (Join-Path $e.Root 'autounattend.xml') (Join-Path $e.Root 'Extra\autounattend.xml')
    Assert-Match @((Test-WdmMedia $e.Root $pkg).checks | ForEach-Object { $_.detail }) 'ignored by Windows Setup: Extra' 'misplaced answer file reported'
    Remove-Item (Join-Path $e.Root 'autounattend.xml')
    Assert-Equal (Test-WdmMedia $e.Root $pkg).status 'Incomplete' 'missing answer file'
    Copy-Item (Join-Path $e.Root 'Extra\autounattend.xml') (Join-Path $e.Root 'AUTOUNATTEND.XML')
    Assert-Equal (Test-WdmMedia $e.Root $pkg).status 'ReadyWithWarnings' 'case-insensitive name found (warning remains for the extra copy)'
    [IO.File]::AppendAllText((Join-Path $e.Root 'AUTOUNATTEND.XML'), ' ')
    Assert-Equal (Test-WdmMedia $e.Root $pkg).status 'Failed' 'tampered answer file'
    $other = Read-WdmPackage $script:MigZip
    Assert-Match @((Test-WdmMedia $e.Root $other).checks | ForEach-Object { "$($_.check) $($_.result)" }) 'Deployment manifest Fail' 'another deployment than expected'
}

$tests['paths: spaces, long names and Unicode are copied and verified; names compare case-insensitively'] = {
    Reset-Sim
    $src = Join-Path $script:Sim.Root ('Source Folder with spaces\' + ('long-name-' * 12) + "Zo$([char] 0xEB) $([char] 0x00E9)t$([char] 0x00E9) $([char] 0x65E5)$([char] 0x672C).txt")
    New-Item -ItemType Directory -Path (Split-Path -Parent $src) -Force | Out-Null
    [IO.File]::WriteAllText($src, "unicode $([char] 0x65E5)")
    $dst = Join-Path $script:Sim.Root ('USB Drive\Folder\' + (Split-Path -Leaf $src))
    $r = Copy-WdmVerifiedFile $src $dst
    Assert-True ($r.Copied -and (Get-WdmFileSha256 $dst) -eq (Get-WdmFileSha256 $src)) 'copied and verified'
    Assert-True (-not (Copy-WdmVerifiedFile $src $dst).Copied) 'identical file not rewritten'
    $upper = Join-Path $script:Sim.Root ('USB DRIVE\FOLDER\' + (Split-Path -Leaf $src).ToUpperInvariant())
    Assert-True (-not (Copy-WdmVerifiedFile $src $upper).Copied) 'same file under another case is the same file'
    Assert-True (-not (Test-WdmRelativePath 'a/../b')) 'traversal in package paths'
    Assert-True (-not (Test-WdmRelativePath 'C:/x')) 'drive paths'
    Assert-True (-not (Test-WdmRelativePath 'a\b')) 'backslash paths'
    Assert-True (Test-WdmRelativePath "scripts/Zo$([char] 0xEB) file.ps1") 'Unicode and spaces allowed'
}

$tests['the destructive adapter is never called by planning, inspection or Update'] = {
    Reset-Sim; $e = Set-SimComputer
    $saved = ${function:Invoke-WdmPartitionDisk}
    ${function:Invoke-WdmPartitionDisk} = { throw 'REAL DESTRUCTIVE ADAPTER CALLED' }
    try {
        [void] (New-WdmPlan Update $script:MainZip '' 'E:')
        [void] (Test-WdmMedia $e.Root)
        [void] (Invoke-WdmApply (New-WdmPlan Update $script:MainZip '' 'E:'))
        [void] (New-WdmPlan Create $script:MainZip '' '' (Set-SimIso) 2)
    } finally {
        ${function:Invoke-WdmPartitionDisk} = $saved
    }
    Assert-True (Test-Path (Join-Path $e.Root 'autounattend.xml')) 'Update still worked'
}

$tests['contract: a prepared drive passes the deployment''s own package verification (Stage-Deployment -VerifyOnly)'] = {
    Reset-Sim; $e = Set-SimComputer
    Assert-Equal (Invoke-WdmApply (New-WdmPlan Update $script:MigZip $script:MigBackup 'E:')).status 'ReadyForInstallation' 'prepared'
    $stage = Join-Path $e.Root 'WindowsDeployment\scripts\bootstrap\Stage-Deployment.ps1'
    $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $stage -SourceMode Package -SourceRoot (Join-Path $e.Root 'WindowsDeployment') 2>&1
    Assert-Equal $LASTEXITCODE 0 "Stage-Deployment verified the drive: $($out -join ' ')"
    Assert-Match @($out | ForEach-Object { "$_" }) 'Verified \(no changes made\)' 'read-only verification by the engine itself'
    # The settings backup sits exactly where the application engine looks for it on every drive.
    $engine = Get-Content -Raw (Join-Path $e.Root 'WindowsDeployment\scripts\applications\ApplicationEngine.ps1')
    Assert-True ($engine.Contains('"WindowsDeployment\backups\$FolderName"')) 'engine search path'
    Assert-True (Test-Path (Join-Path $e.Root "WindowsDeployment\backups\$script:MigBackupFolder\backup-manifest.json")) 'backup at that path'
}

$tests['wizard: the Update flow with typed answers; nothing is written without YES'] = {
    Reset-Sim; $e = Set-SimComputer
    $script:Answers = New-Object System.Collections.Queue
    foreach ($a in @('1', $script:MainZip, '', 'E:', 'no')) { $script:Answers.Enqueue($a) }
    ${function:Read-WdmAnswer} = { param([string] $Prompt) $script:Answers.Dequeue() }
    $out = @(Invoke-WdmWizard)
    Assert-True (-not (Test-Path (Join-Path $e.Root 'autounattend.xml'))) 'declined: nothing written'
    Assert-Match @($out | ForEach-Object { "$_" }) 'Nothing was changed' 'says so'
    foreach ($a in @('1', $script:MainZip, '', 'E:', 'YES')) { $script:Answers.Enqueue($a) }
    $out = @(Invoke-WdmWizard)
    Assert-True (Test-Path (Join-Path $e.Root 'autounattend.xml')) 'confirmed: prepared'
    Assert-Match @($out | ForEach-Object { "$_" }) 'Result   : ReadyForInstallation' 'readiness report shown'
    Assert-Match @($out | ForEach-Object { "$_" }) 'erase: no - it holds the running Windows' 'the drive list explains why the OS disk is not offered'
}

foreach ($name in $tests.Keys) {
    try {
        & $tests[$name]
        $script:Passed++
        Write-Output "  ok    $name"
    } catch {
        $script:Failures++
        Write-Output "  FAIL  $name`n        $($_.Exception.Message)`n        $($_.InvocationInfo.PositionMessage -replace "`n", "`n        ")`n        $($_.ScriptStackTrace -replace "`n", "`n        ")"
    }
}
Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'wdm-test-*' -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "$($script:Passed) passed, $($script:Failures) failed"
if ($script:Failures -gt 0) { exit 1 }
exit 0
