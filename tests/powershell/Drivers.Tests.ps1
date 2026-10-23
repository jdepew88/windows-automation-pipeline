#Requires -Version 5.1
<#
    Scenario tests for the hardware-aware driver engine (DriverEngine.ps1, Phase 8) against simulated
    computers: Plug and Play devices, their drivers and problem codes, pnputil, the network, restarts,
    downloads, catalog signatures and device-installation policy are all replaced. The engine is the
    one in the REAL generated deployment package (drivers fixture), with its real configuration, and
    the offline bundle is the fixture bundle written by TypeScript. Nothing is installed, no driver
    store is read or changed, no device is touched; everything is written below a temporary folder.

    Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\powershell\Drivers.Tests.ps1 -Fixture <dir>
    (<dir> from "vite-node tests/powershell/make-deployment-fixture.ts <dir>"; npm run test:ps does both.)
#>
param([Parameter(Mandatory = $true)] [string] $Fixture)

$ErrorActionPreference = 'Stop'
$script:DrvFixture = (Resolve-Path (Join-Path $Fixture 'drivers')).Path
$script:PkgScripts = Join-Path $script:DrvFixture 'usb\WindowsDeployment\scripts'
. (Join-Path $script:PkgScripts 'drivers\DriverEngine.ps1') -Mode Library
Set-StrictMode -Version 2.0
${function:Invoke-WdvPnpUtilReal} = ${function:Invoke-WdvPnpUtil}
$script:BundleFolder = 'WDB-Drivers-20261022-120000-abc123'
$script:BundleSource = (Resolve-Path (Join-Path $script:DrvFixture "source\$script:BundleFolder")).Path
$script:BaseConfigText = [IO.File]::ReadAllText((Join-Path $script:PkgScripts 'drivers\drivers-config.json'))
$script:WHQL = 'Microsoft Windows Hardware Compatibility Publisher'
$script:G = @{ Display = '{4d36e968-e325-11ce-bfc1-08002be10318}'; Net = '{4d36e972-e325-11ce-bfc1-08002be10318}'; System = '{4d36e97d-e325-11ce-bfc1-08002be10318}'; Media = '{4d36e96c-e325-11ce-bfc1-08002be10318}'
               Other = '{4d36e97e-e325-11ce-bfc1-08002be10318}'; SCSIAdapter = '{4d36e97b-e325-11ce-bfc1-08002be10318}'; Processor = '{50127dc3-0f36-415e-a6cc-4cb3be910b65}'; Bluetooth = '{e0cbf06c-cd8b-4647-bb8a-263b43f0f974}'
               HIDClass = '{745a17a0-74d3-11d0-b6fe-00a0c90f57da}'; DiskDrive = '{4d36e967-e325-11ce-bfc1-08002be10318}'; USB = '{36fc9e60-c465-11cf-8056-444553540000}' }

$script:Failures = 0
$script:Passed = 0

function Assert-Equal($Actual, $Expected, [string] $Message) { if ("$Actual" -ne "$Expected") { throw "ASSERT: $Message. Expected <$Expected>, got <$Actual>." } }
function Assert-True($Value, [string] $Message) { if (-not $Value) { throw "ASSERT: $Message" } }
function Assert-Match([string[]] $Lines, [string] $Pattern, [string] $Message) { if (-not @($Lines | Where-Object { $_ -match $Pattern }).Count) { throw "ASSERT: $Message. No line matches /$Pattern/ in:`n  $($Lines -join "`n  ")" } }

# ------------------------------------------------------------------------------------------------
# Simulated computer
# ------------------------------------------------------------------------------------------------

function Reset-Sim {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("wdv-test-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $now = [DateTime]::new(2026, 10, 22, 9, 0, 0, [DateTimeKind]::Utc)
    $script:S = @{
        Root = $root; DataRoot = (Join-Path $root 'ProgramData\WindowsDeploymentBuilder'); Now = $now; Boot = $now.AddMinutes(-5); Online = $true; RebootPending = $false
        Policy = @{ Restricted = $false; Detail = '' }; Devices = New-Object System.Collections.Generic.List[object]; Effects = @{}; StoreInfs = @(); DriveRoots = @(); Signatures = @{}
        PnpCalls = New-Object System.Collections.Generic.List[string]; Downloads = New-Object System.Collections.Generic.List[string]; DownloadSource = @{}; CabContent = @{}; Reboots = 0; Events = New-Object System.Collections.Generic.List[int]
        WuTask = $true; TaskRemoved = $false; OnlineAfterNetDriver = $false; ExportSource = ''
        System = @{ Manufacturer = 'Contoso'; Model = 'Workstation 7'; Family = ''; Sku = ''; PCSystemType = 1; BoardManufacturer = 'Contoso'; BoardProduct = 'B760'; BiosVendor = 'Contoso'; BiosVersion = '1.0'
                    Processors = @(@{ Name = 'Intel(R) Core(TM) i7-13700'; Manufacturer = 'GenuineIntel' }); ChassisTypes = @(3); OsCaption = 'Microsoft Windows 11 Pro'; OsBuild = '26200'; OsVersion = '10.0.26200'; Architecture = 'amd64' }
    }
}

function New-SimDevice {
    param([string] $Id, [string] $Name, [string] $Class, [string[]] $Hw = @(), [string[]] $Compat = @(), [int] $Problem = 0, $Driver = $null, [string] $Parent = '', [string] $ClassGuid = '')
    $g = $(if ($ClassGuid) { $ClassGuid } elseif ($Class -and $script:G.ContainsKey($Class)) { $script:G[$Class] } else { '' })
    $d = @{ InstanceId = $Id; Name = $Name; Class = $Class; ClassGuid = $g; Manufacturer = ''; Status = $(if ($Problem) { 'Error' } else { 'OK' }); ProblemCode = $Problem; Present = $true; Service = ''
            HardwareIds = @($Hw); CompatibleIds = @($Compat); Driver = $Driver; Parent = $Parent; PendingDriver = $null }
    $script:S.Devices.Add($d)
    return $d
}
function New-SimDriver { param([string] $Provider, [string] $Version, [string] $Inf, [string] $Date = '2026-01-01') @{ Provider = $Provider; Version = $Version; Inf = $Inf; Date = $Date } }
function Get-SimDevice { param([string] $Like) @($script:S.Devices | Where-Object { $_.InstanceId -like $Like })[0] }

function Get-WdvNow { $script:S.Now }
function Wait-Wdv { param([int] $Seconds) $script:S.Now = $script:S.Now.AddSeconds([Math]::Max(1, $Seconds)) }
function Get-WdvBootTime { $script:S.Boot }
function Get-WdbBootTime { $script:S.Boot.ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Wait-WdbLockPoll { }
function Get-WdvRawDevices { @($script:S.Devices | ForEach-Object { $_.Clone() }) }
function Get-WdvSignedDrivers {
    $m = @{}
    foreach ($d in $script:S.Devices) { if ($d.Driver) { $m[$d.InstanceId.ToUpperInvariant()] = @{ Provider = $d.Driver.Provider; Version = $d.Driver.Version; Date = $d.Driver.Date; Inf = $d.Driver.Inf; Signer = $script:WHQL; IsSigned = $true } } }
    $m
}
function Get-WdvDeviceParents { param([string[]] $InstanceIds) $m = @{}; foreach ($d in $script:S.Devices) { if ($d.Parent) { $m[$d.InstanceId.ToUpperInvariant()] = $d.Parent } }; $m }
function Get-WdvSystem { $script:S.System }
function Test-WdvNetwork { [bool] $script:S.Online }
function Test-WdvSystemRebootPending { [bool] $script:S.RebootPending }
function Get-WdvDeviceInstallPolicy { $script:S.Policy }
function Get-WdvDriverStoreInfs { @($script:S.StoreInfs) }
function Get-WdvReadyDriveRoots { @($script:S.DriveRoots) }
function Get-WdvSignature { param([string] $Path) $leaf = (Split-Path -Leaf $Path).ToLowerInvariant(); if ($script:S.Signatures.ContainsKey($leaf)) { $script:S.Signatures[$leaf] } else { @{ Status = 'Valid'; Signer = $script:WHQL } } }
function Invoke-WdvReboot { param([int] $WarningSeconds, [string] $Reason) $script:S.Reboots++ }
function Unregister-WdvTask { param([hashtable] $Config) $script:S.TaskRemoved = $true }
function Test-WdvUpdateTask { param([hashtable] $WU) [bool] $script:S.WuTask }
function Write-WdvEvent { param([int] $EventId, [string] $Message, [string] $EntryType = 'Information') $script:S.Events.Add($EventId) }
function Enter-WdvMutex { return 'sim-mutex' }
function Exit-WdvMutex { param($Mutex) }
function Get-WdvDeviceState {
    param([string] $InstanceId)
    $d = @($script:S.Devices | Where-Object { $_.InstanceId -eq $InstanceId })
    if (-not $d.Count) { return $null }
    $x = $d[0]
    @{ ProblemCode = $x.ProblemCode; Driver = $(if ($x.Driver) { @{ provider = $x.Driver.Provider; version = $x.Driver.Version; date = $x.Driver.Date; inf = $x.Driver.Inf; signer = $script:WHQL; signed = $true; inbox = -not ($x.Driver.Inf -match '^oem\d+\.inf$') } } else { $null }) }
}

# pnputil, simulated: /add-driver applies the package's configured effect to every matching device
# that Windows would consider (no driver, a problem, or the basic display driver).
function Invoke-WdvPnpUtil {
    param([string[]] $Arguments)
    $script:S.PnpCalls.Add(($Arguments -join ' '))
    $verb = $Arguments[0]
    if ($verb -eq '/scan-devices') {
        $dev = @($script:S.Devices | Where-Object { $_.InstanceId -eq $Arguments[2] })[0]
        foreach ($inf in $script:S.StoreInfs) {
            $info = Read-WdvInf $inf
            if (@($dev.HardwareIds | Where-Object { $info.HardwareIds -contains $_.ToUpperInvariant() }).Count -and -not $dev.Driver) {
                $dev.ProblemCode = 0; $dev.Status = 'OK'; $dev.Driver = New-SimDriver $info.Provider $info.Version 'oem7.inf'
            }
        }
        return @{ ExitCode = 0; Output = 'Scanning for device hardware changes... done' }
    }
    if ($verb -ne '/add-driver') { throw "unexpected pnputil call $($Arguments -join ' ')" }
    $info = Read-WdvInf $Arguments[1]
    $effect = $(if ($script:S.Effects.ContainsKey($info.File.ToLowerInvariant())) { $script:S.Effects[$info.File.ToLowerInvariant()] } else { 'works' })
    $exit = 0; $out = 'Driver package added successfully.'
    foreach ($dev in @($script:S.Devices | Where-Object { @(@($_.HardwareIds) + @($_.CompatibleIds) | Where-Object { $info.HardwareIds -contains $_.ToUpperInvariant() }).Count })) {
        $considered = (-not $dev.Driver) -or $dev.ProblemCode -ne 0 -or $dev.Driver.Inf -eq 'display.inf' -or $effect -like 'force*'
        if (-not $considered) { continue }
        $new = New-SimDriver $info.Provider $info.Version 'oem42.inf'
        switch ($effect) {
            { $_ -in 'works', 'forceWorks' } { $dev.ProblemCode = 0; $dev.Status = 'OK'; $dev.Driver = $new; if ($script:S.OnlineAfterNetDriver -and $dev.Class -in 'Net', '') { $script:S.Online = $true } }
            'needsRestart' { $dev.ProblemCode = 14; $dev.PendingDriver = $new; $exit = 3010 }
            'breaks' { $dev.ProblemCode = 10; $dev.Status = 'Error'; $dev.Driver = $new }
            'noEffect' { $dev.Driver = $new }
            'notSelected' { }
            'fail' { $exit = 1; $out = 'Failed to install the driver on any devices.' }
            'signature' { $exit = -536870353; $out = 'The third-party INF does not contain digital signature information.' }
        }
    }
    return @{ ExitCode = $exit; Output = $out }
}

function Invoke-WdvDownload {
    param([string] $Url, [string] $Destination)
    $script:S.Downloads.Add($Url)
    if (-not $script:S.Online) { throw 'The remote name could not be resolved' }
    $src = $script:S.DownloadSource[$Url]
    if ($src -eq 'tamper') { [IO.File]::WriteAllText($Destination, 'not the verified file'); return }
    Copy-Item -LiteralPath $src -Destination $Destination
}
function Expand-WdvCabinet { param([string] $Cabinet, [string] $Destination) Copy-Item -Path (Join-Path $script:S.CabContent[(Split-Path -Leaf $Cabinet)] '*') -Destination $Destination -Recurse -Force }

<# A restart: devices waiting for one start with their new driver; restart markers expire. #>
function Invoke-SimReboot {
    $script:S.Now = $script:S.Now.AddMinutes(3)
    $script:S.Boot = $script:S.Now
    $script:S.RebootPending = $false
    foreach ($d in $script:S.Devices) { if ($d.ProblemCode -eq 14 -and $d.PendingDriver) { $d.ProblemCode = 0; $d.Status = 'OK'; $d.Driver = $d.PendingDriver; $d.PendingDriver = $null } }
    $script:S.Now = $script:S.Now.AddMinutes(2)
}

function New-SimConfig {
    param([scriptblock] $Change = $null)
    $c = ConvertTo-WdvHashtable ($script:BaseConfigText | ConvertFrom-Json)
    $c.dataRoot = $script:S.DataRoot
    $c.windowsUpdate.stateFile = Join-Path $script:S.DataRoot 'Updates\state.json'
    $c.windowsUpdate.resultFile = Join-Path $script:S.DataRoot 'Updates\result.json'
    if ($Change) { & $Change $c }
    $p = Join-Path $script:S.Root ("config-" + [Guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($p, ($c | ConvertTo-Json -Depth 12))
    return (Get-WdvConfig $p)
}

# What the Windows Update engine writes when it finishes (result.json).
function Set-WuFinished { param([string] $Status = 'Succeeded') Write-WdvJson (Join-Path $script:S.DataRoot 'Updates\result.json') @{ status = $Status; reason = "sim $Status"; reboots = 1; finishedUtc = $script:S.Now.ToString('o'); installed = @(); failed = @(); skipped = @() } }

<# Puts the fixture bundle on a simulated USB drive (<drive>\WindowsDeployment\drivers\<folder>). #>
function Add-SimBundleDrive {
    $drive = Join-Path $script:S.Root 'usb'
    $dst = Join-Path $drive "WindowsDeployment\drivers\$script:BundleFolder"
    New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
    Copy-Item -LiteralPath $script:BundleSource -Destination $dst -Recurse
    $script:S.DriveRoots = @($drive + '\')
    return $dst
}

<# Runs the engine like its scheduled task does, restarting the simulated computer when it asks, until it finishes. #>
function Invoke-SimRuns {
    param([hashtable] $Config, [int] $Max = 12, [scriptblock] $Between = $null)
    $results = @()
    for ($i = 0; $i -lt $Max; $i++) {
        $r = Invoke-WdvMain $Config
        $results += $r
        if ($r -like 'Finished:*' -or $r -eq 'AlreadyFinished') { break }
        if ($r -eq 'Rebooting') { Invoke-SimReboot }
        else { $script:S.Now = $script:S.Now.AddMinutes(30) }
        if ($Between) { & $Between $i $r }
    }
    return , @($results)
}

function Get-SimPaths { param([hashtable] $Config) Get-WdvPaths $Config }
function Get-SimState { param([hashtable] $Config) Read-WdvState (Get-WdvPaths $Config) }
function Get-SimReport { param([hashtable] $Config) Read-WdvJson (Get-WdvPaths $Config).Report }
function Get-Op { param($State, [string] $InstanceLike) @(@($State.operations.Values) | Where-Object { $_.instanceId -like $InstanceLike })[0] }

# ------------------------------------------------------------------------------------------------
# Simulated computers (Phase 8 fixtures A-H)
# ------------------------------------------------------------------------------------------------

function Add-IntelDesktopWithNvidia {
    param([string] $GpuDriver = 'display.inf')
    [void] (New-SimDevice 'ACPI\GENUINEINTEL_-_INTEL64_FAMILY_6_MODEL_183_-_13TH_GEN\_0' 'Intel(R) Core(TM) i7-13700' 'Processor' @('ACPI\GenuineIntel_-_Intel64_Family_6_Model_183', '*GenuineIntel_-_Intel64') @() 0 (New-SimDriver 'Microsoft' '10.0.26100.1' 'cpu.inf'))
    [void] (New-SimDevice 'PCI\VEN_8086&DEV_7A04&SUBSYS_7A048086&REV_11\3&11583659&0&F8' 'Intel(R) LPC Controller' 'System' @('PCI\VEN_8086&DEV_7A04&SUBSYS_7A048086&REV_11', 'PCI\VEN_8086&DEV_7A04') @('PCI\VEN_8086&DEV_7A04&CC_060100', 'PCI\CC_0601') 0 (New-SimDriver 'INTEL' '10.1.48.9' 'oem3.inf'))
    [void] (New-SimDevice 'PCI\VEN_8086&DEV_15F3&SUBSYS_00008086&REV_03\3&11583659&0&E0' 'Intel(R) Ethernet Controller I225-V' 'Net' @('PCI\VEN_8086&DEV_15F3&SUBSYS_00008086&REV_03', 'PCI\VEN_8086&DEV_15F3') @('PCI\VEN_8086&DEV_15F3&CC_020000', 'PCI\CC_0200') 0 (New-SimDriver 'Microsoft' '2.1.3.15' 'e2f.inf'))
    [void] (New-SimDevice 'HDAUDIO\FUNC_01&VEN_10EC&DEV_0897&SUBSYS_10438882&REV_1003\5&2B3C&0&0001' 'Realtek High Definition Audio' 'MEDIA' @('HDAUDIO\FUNC_01&VEN_10EC&DEV_0897&SUBSYS_10438882&REV_1003', 'HDAUDIO\FUNC_01&VEN_10EC&DEV_0897') @('HDAUDIO\FUNC_01&CTLR_VEN_8086', 'HDAUDIO\FUNC_01') 0 (New-SimDriver 'Realtek Semiconductor Corp.' '6.0.9600.1' 'oem9.inf') -ClassGuid $script:G.Media)
    [void] (New-SimDevice 'PCI\VEN_10DE&DEV_2484&SUBSYS_146B10DE&REV_A1\4&1A2B3C4D&0&0008' 'Microsoft Basic Display Adapter' 'Display' @('PCI\VEN_10DE&DEV_2484&SUBSYS_146B10DE&REV_A1', 'PCI\VEN_10DE&DEV_2484&SUBSYS_146B10DE', 'PCI\VEN_10DE&DEV_2484&CC_030000', 'PCI\VEN_10DE&DEV_2484') @('PCI\VEN_10DE&CC_030000', 'PCI\CC_0300') 0 (New-SimDriver 'Microsoft' '10.0.26100.1' $GpuDriver))
    [void] (New-SimDevice 'SWD\MMDEVAPI\{0.0.0.00000000}.{ABC}' 'Speakers' 'AudioEndpoint' @('MMDEVAPI\AudioEndpoints') @() 0 (New-SimDriver 'Microsoft' '10.0.26100.1' 'audioendpoint.inf'))
}

function Add-AmdDesktop {
    $script:S.System.Processors = @(@{ Name = 'AMD Ryzen 7 7800X3D'; Manufacturer = 'AuthenticAMD' })
    [void] (New-SimDevice 'ACPI\AUTHENTICAMD_-_AMD64_FAMILY_25_MODEL_97\_0' 'AMD Ryzen 7 7800X3D' 'Processor' @('ACPI\AuthenticAMD_-_AMD64_Family_25_Model_97') @() 0 (New-SimDriver 'Microsoft' '10.0.26100.1' 'cpu.inf'))
    [void] (New-SimDevice 'PCI\VEN_1022&DEV_14D8&SUBSYS_14D81022&REV_00\3&2411E6FE&0&00' 'AMD SMBus' 'System' @('PCI\VEN_1022&DEV_14D8&SUBSYS_14D81022&REV_00', 'PCI\VEN_1022&DEV_14D8') @('PCI\VEN_1022&DEV_14D8&CC_0C0500', 'PCI\CC_0C05') 0 (New-SimDriver 'Advanced Micro Devices, Inc' '5.12.0.38' 'oem12.inf'))
    [void] (New-SimDevice 'PCI\VEN_1002&DEV_73BF&SUBSYS_0E3A1002&REV_C1\6&3A2F&0&0000' 'AMD Radeon RX 6800' 'Display' @('PCI\VEN_1002&DEV_73BF&SUBSYS_0E3A1002&REV_C1', 'PCI\VEN_1002&DEV_73BF') @('PCI\VEN_1002&CC_030000', 'PCI\CC_0300') 0 (New-SimDriver 'Advanced Micro Devices, Inc.' '31.0.24027.1012' 'oem20.inf'))
}

function Add-DellLaptop {
    $script:S.System.Manufacturer = 'Dell Inc.'; $script:S.System.Model = 'Latitude 7440'; $script:S.System.PCSystemType = 2; $script:S.System.ChassisTypes = @(10)
    [void] (New-SimDevice 'PCI\VEN_8086&DEV_A7A1&SUBSYS_0C031028&REV_04\3&11583659&0&10' 'Intel(R) Iris(R) Xe Graphics' 'Display' @('PCI\VEN_8086&DEV_A7A1&SUBSYS_0C031028&REV_04', 'PCI\VEN_8086&DEV_A7A1&SUBSYS_0C031028', 'PCI\VEN_8086&DEV_A7A1') @('PCI\CC_0300') 0 (New-SimDriver 'Intel Corporation' '31.0.101.5186' 'oem5.inf'))
    [void] (New-SimDevice 'PCI\VEN_8086&DEV_51F0&SUBSYS_00941028&REV_01\3&11583659&0&A3' 'Intel(R) Wi-Fi 6E AX211 160MHz' 'Net' @('PCI\VEN_8086&DEV_51F0&SUBSYS_00941028&REV_01', 'PCI\VEN_8086&DEV_51F0&SUBSYS_00941028', 'PCI\VEN_8086&DEV_51F0') @('PCI\VEN_8086&DEV_51F0&CC_028000', 'PCI\CC_0280') 0 (New-SimDriver 'Intel' '23.20.0.3' 'oem14.inf'))
    [void] (New-SimDevice 'USB\VID_8087&PID_0033\5&2C7A&0&10' 'Intel(R) Wireless Bluetooth(R)' 'Bluetooth' @('USB\VID_8087&PID_0033&REV_0000', 'USB\VID_8087&PID_0033') @('USB\Class_E0&SubClass_01&Prot_01', 'USB\Class_E0') 0 (New-SimDriver 'Intel Corporation' '23.20.0.3' 'oem15.inf'))
    [void] (New-SimDevice 'HID\DELL0B9F&COL01\5&1A2B&0&0000' 'HID-compliant touch pad' 'HIDClass' @('HID\DELL0B9F&Col01', 'HID_DEVICE_UP:000D_U:0005') @('HID_DEVICE_UP:000D_U:0005', 'HID_DEVICE') 0 (New-SimDriver 'Microsoft' '10.0.26100.1' 'input.inf'))
    [void] (New-SimDevice 'ACPI\INTC1046\2&DABA3FF&1' 'Unknown device' '' @('ACPI\INTC1046', '*INTC1046') @() 28 $null -ClassGuid $script:G.Other)
}

# ------------------------------------------------------------------------------------------------
# Scenarios
# ------------------------------------------------------------------------------------------------

$tests = [ordered]@{}

$tests['config: the generated configuration loads; downloads only from official HTTPS hosts'] = {
    Reset-Sim
    $c = New-SimConfig
    Assert-Equal $c.engineVersion $script:WdvVersion 'engine and configuration versions match'
    Assert-Equal $c.bundle.folderName $script:BundleFolder 'the bundle is pinned'
    Assert-True ($c.policy.useWindowsUpdate -and $c.policy.resolveMissing -and $c.policy.offlinePackages) 'safe defaults on'
    Assert-Equal $c.policy.optionalReplacements 'never' 'working drivers are never replaced by default'
    Assert-Equal $c.windowsUpdate.drivers 'include' 'the owner default (Phase 9) lets Windows Update offer drivers'
    foreach ($bad in 'http://download.microsoft.com/x.cab', 'https://downloads.example.com/x.cab', 'https://user:pw@dl.dell.com/x.cab', 'https://dl.dell.com:8443/x.cab') {
        $threw = $false
        try { [void] (New-SimConfig { param($x) $x.verifiedPackages[0].url = $bad }) } catch { $threw = $true }
        Assert-True $threw "refused: $bad"
    }
}

$tests['A. Intel desktop + NVIDIA: only the GPU on the basic display driver gets a driver; Intel and Realtek kept'] = {
    Reset-Sim; Add-IntelDesktopWithNvidia; [void] (Add-SimBundleDrive)
    $c = New-SimConfig
    $r1 = Invoke-WdvMain $c
    Assert-Equal $r1 'WaitingForWindowsUpdate' 'waits for Windows Update after Inspection A'
    Assert-Equal $script:S.PnpCalls.Count 0 'nothing installed before Windows Update'
    $st = Get-SimState $c
    Assert-Equal $st.bundle.status 'Staged' 'the pinned bundle was found on the drive, verified and staged'
    $gpu = Get-Op $st 'PCI\VEN_10DE*'
    Assert-Equal $gpu.status 'Pending' 'the GPU waits for Windows Update'
    Assert-Equal $gpu.waitingFor 'windowsUpdate' 'waiting for Windows Update'
    Assert-Equal @($st.operations.Keys).Count 1 'no operation for the working devices'
    Set-WuFinished
    $runs = Invoke-SimRuns $c
    Assert-Equal $runs[-1] 'Finished:Succeeded' "finished: $($runs -join ', ')"
    Assert-Equal $script:S.PnpCalls.Count 1 "exactly one installation: $($script:S.PnpCalls -join ' | ')"
    Assert-Match @($script:S.PnpCalls) '^/add-driver .*nvdisp\.inf /install$' 'pnputil /add-driver <inf> /install for the NVIDIA package'
    $st = Get-SimState $c
    $gpu = Get-Op $st 'PCI\VEN_10DE*'
    Assert-Equal "$($gpu.status) $($gpu.verification) $($gpu.source)" 'Succeeded Verified offlineBundle' 'verified from the device itself'
    Assert-Equal $gpu.previousDriver.inf 'display.inf' 'the previous driver is recorded'
    foreach ($pair in @(@('PCI\VEN_8086&DEV_15F3*', 'e2f.inf'), @('HDAUDIO\*', 'oem9.inf'), @('PCI\VEN_8086&DEV_7A04*', 'oem3.inf'))) {
        Assert-Equal (Get-SimDevice $pair[0]).Driver.Inf $pair[1] "the working driver of $($pair[0]) is unchanged"
        Assert-True (-not (Get-Op $st $pair[0])) "no operation for $($pair[0])"
    }
    $rep = Get-SimReport $c
    Assert-Equal "$($rep.final) $($rep.status) $($rep.health.status)" 'True Succeeded AllHealthy' 'drivers.json'
    $apps = @($rep.optionalApplications | ForEach-Object { $_.name })
    Assert-True ($apps -contains 'NVIDIA App' -and $apps -contains 'CUDA Toolkit' -and $apps -contains 'Intel Driver & Support Assistant') 'vendor applications are listed as optional'
    Assert-True (@($rep.optionalApplications | Where-Object { $_.required }).Count -eq 0) 'none of them is required'
    Assert-True ($script:S.TaskRemoved) 'the task removes itself'
    Assert-True (Test-Path (Get-SimPaths $c).Marker) 'completion marker'
    $eth = @($rep.devices | Where-Object { $_.hardwareIds -contains 'PCI\VEN_8086&DEV_15F3' })[0]
    Assert-Equal "$($eth.result) $($eth.state) $($eth.category)" 'Kept Healthy networkWired' 'Intel Ethernet kept'
    $cpu = @($rep.devices | Where-Object { $_.category -eq 'cpu' })[0]
    Assert-Equal $cpu.vendor.id 'intel' 'the CPU vendor comes from its identifier'
}

$tests['A2. without a usable package the GPU is a manual action with the official page; Windows Update policy is named'] = {
    Reset-Sim; Add-IntelDesktopWithNvidia
    # A deployment (an older profile or an organization) that withholds drivers from Windows Update.
    $c = New-SimConfig { param($x) $x.bundle = $null; $x.windowsUpdate.drivers = 'exclude' }
    Set-WuFinished
    $runs = Invoke-SimRuns $c
    Assert-Equal $runs[-1] 'Finished:CompletedWithFollowUp' 'follow-up'
    Assert-Equal $script:S.PnpCalls.Count 0 'nothing installed'
    $rep = Get-SimReport $c
    Assert-Equal $rep.health.status 'MissingDriver' 'health distinguishes a missing driver'
    $m = @($rep.manualActions)[0]
    Assert-Equal $m.url 'https://www.nvidia.com/en-us/drivers/' 'official NVIDIA page (desktop, not OEM-customized)'
    Assert-Match @($m.text) 'PCI\\VEN_10DE&DEV_2484&SUBSYS_146B10DE&REV_A1' 'the hardware ID is given'
    Assert-Match @($m.text) 'Game Ready and Studio' 'the documented branch policy, not a guess'
    Assert-Match @($m.text) 'Windows Update was not allowed to install drivers' 'says why Windows Update did not resolve it'
    # Phase 9 default: Windows Update may install drivers, so the message is not given.
    Reset-Sim; Add-IntelDesktopWithNvidia
    $c = New-SimConfig { param($x) $x.bundle = $null }
    Set-WuFinished
    Invoke-SimRuns $c | Out-Null
    Assert-Equal (@(@((Get-SimReport $c).manualActions) | Where-Object { $_.text -match 'not allowed to install drivers' }).Count) 0 'no such claim when Windows Update may install drivers'
}

$tests['B. AMD desktop, all healthy: no download, no installation, newer package only reported'] = {
    Reset-Sim; Add-AmdDesktop; [void] (Add-SimBundleDrive)
    $c = New-SimConfig { param($x) $x.verifiedPackages = @(@{ id = 'amd-display'; name = 'AMD display'; vendor = 'AMD'; url = 'https://drivers.amd.com/x.zip'; sha256 = 'B' * 64; format = 'zip'; hardwareIds = @('PCI\VEN_1002&DEV_73BF'); deviceClass = 'Display'; version = '33.0.0.0'; architecture = 'amd64' }) }
    Set-WuFinished
    $runs = Invoke-SimRuns $c
    Assert-Equal $runs[-1] 'Finished:Succeeded' 'nothing to do'
    Assert-Equal "$($script:S.PnpCalls.Count) $($script:S.Downloads.Count)" '0 0' 'no installation, no download'
    $rep = Get-SimReport $c
    $gpu = @($rep.devices | Where-Object { $_.category -eq 'display' })[0]
    Assert-Equal $gpu.result 'Kept' 'the working Radeon driver is kept'
    Assert-True ($gpu.optionalUpdate -and $gpu.optionalUpdate.version -eq '32.0.21025.1024') 'the newer bundle package is reported as optional'
    Assert-Equal $rep.health.status 'AllHealthy' 'healthy'
}

$tests['C. Dell laptop: OEM-customized drivers are not replaced by generic packages; OEM page for the missing device'] = {
    Reset-Sim; Add-DellLaptop; [void] (Add-SimBundleDrive)
    $c = New-SimConfig { param($x) $x.policy.optionalReplacements = 'approvedOnly'; $x.approvals = @(@{ packageId = 'pkg-0000000000a4'; hardwareId = 'PCI\VEN_8086&DEV_51F0' }) }
    Set-WuFinished
    $runs = Invoke-SimRuns $c
    Assert-Equal $script:S.PnpCalls.Count 0 'no generic package replaces an OEM driver, even approved for a generic ID'
    $rep = Get-SimReport $c
    $wifi = @($rep.devices | Where-Object { $_.category -eq 'networkWireless' })[0]
    Assert-True $wifi.oemCustomized 'Wi-Fi recognised as OEM-customized (subsystem 1028)'
    Assert-Equal $wifi.result 'Kept' 'kept'
    $tp = @($rep.devices | Where-Object { $_.category -eq 'touchpad' })[0]
    Assert-Equal "$($tp.state) $($tp.result)" 'Healthy Kept' 'the Microsoft precision touchpad driver is healthy, not "defective"'
    $m = @($rep.manualActions | Where-Object { $_.text -match 'INTC1046' })[0]
    Assert-Equal $m.url 'https://www.dell.com/support/home/' 'laptop: the computer manufacturer page first'
    Assert-Equal $runs[-1] 'Finished:CompletedWithFollowUp' 'follow-up for the unknown platform device'
}

$tests['D. missing network driver: offline bootstrap from the bundle before Windows Update; connectivity checked'] = {
    Reset-Sim
    [void] (New-SimDevice 'PCI\VEN_10EC&DEV_8125&SUBSYS_86771043&REV_05\4&2A1B&0&00E4' 'Ethernet Controller' '' @('PCI\VEN_10EC&DEV_8125&SUBSYS_86771043&REV_05', 'PCI\VEN_10EC&DEV_8125&SUBSYS_86771043', 'PCI\VEN_10EC&DEV_8125') @('PCI\VEN_10EC&DEV_8125&CC_020000', 'PCI\CC_0200') 28 $null -ClassGuid $script:G.Other)
    [void] (Add-SimBundleDrive)
    $script:S.Online = $false; $script:S.OnlineAfterNetDriver = $true
    $c = New-SimConfig
    $r = Invoke-WdvMain $c
    Assert-Equal $r 'WaitingForWindowsUpdate' 'continues to wait for Windows Update (now online)'
    Assert-Equal $script:S.PnpCalls.Count 1 'the network driver was installed during Inspection A'
    $st = Get-SimState $c
    Assert-Equal $st.network.status 'Online' 'connectivity checked again'
    $op = Get-Op $st 'PCI\VEN_10EC*'
    Assert-Equal "$($op.status) $($op.source)" 'Succeeded offlineBundle' 'from the verified bundle'
    Assert-Equal @($op.history)[-1].trigger 'networkBootstrap' 'recorded as network bootstrap'
    Assert-True (-not (Test-Path (Get-SimPaths $c).NetworkFlag)) 'no missing-network flag'
}

$tests['D2. missing network driver without a package: state kept, offline intervention reported, technician package resolves it'] = {
    Reset-Sim
    [void] (New-SimDevice 'PCI\VEN_10EC&DEV_8125&SUBSYS_86771043&REV_05\4&2A1B&0&00E4' 'Ethernet Controller' '' @('PCI\VEN_10EC&DEV_8125&SUBSYS_86771043', 'PCI\VEN_10EC&DEV_8125') @('PCI\CC_0200') 28 $null -ClassGuid $script:G.Other)
    $script:S.Online = $false; $script:S.OnlineAfterNetDriver = $true
    $c = New-SimConfig
    $r = Invoke-WdvMain $c
    Assert-Equal $r 'WaitingForWindowsUpdate' 'not final: the deployment state is kept'
    $p = Get-SimPaths $c
    $flag = Read-WdvJson $p.NetworkFlag
    Assert-True ($flag -and $flag.detail -match 'Offline intervention' -and $flag.detail -match 'AddDrivers') 'state\network-driver-missing.json says what to do'
    $status = Read-WdvJson $p.Status
    Assert-Equal $status.phase 'WaitingForNetwork' 'status.json: waiting for the network (Phase 5 state)'
    Assert-Equal (Get-SimState $c).bundle.status 'NotFound' 'the bundle is not on any drive'
    # A technician supplies the driver on a stick.
    $stick = Join-Path $script:S.Root 'stick'
    Copy-Item -LiteralPath (Join-Path $script:BundleSource 'packages\002-rt25cx21x64') -Destination $stick -Recurse
    $a = Add-WdvTechnicianPackages $c $stick 'PC\Technician'
    Assert-Equal $a.Outcome 'Accepted' "technician package accepted: $($a.Message)"
    $r = Invoke-WdvMain $c
    Assert-Equal (Get-SimState $c).network.status 'Online' 'online after the technician package'
    Assert-True (-not (Test-Path $p.NetworkFlag)) 'flag removed'
    Assert-Equal (Get-Op (Get-SimState $c) 'PCI\VEN_10EC*').source 'technician' 'installed from the technician package'
}

$tests['E. Setup-critical storage controller: inventory flags it, the bundle tool marks it, its driver is never changed after installation'] = {
    Reset-Sim
    [void] (New-SimDevice 'PCI\VEN_8086&DEV_9A0B&SUBSYS_0A9F1028&REV_00\3&11583659&0&70' 'Intel(R) Volume Management Device NVMe RAID Controller' 'SCSIAdapter' @('PCI\VEN_8086&DEV_9A0B&SUBSYS_0A9F1028&REV_00', 'PCI\VEN_8086&DEV_9A0B') @('PCI\VEN_8086&DEV_9A0B&CC_010400', 'PCI\CC_0104') 0 (New-SimDriver 'Intel Corporation' '19.5.0.1037' 'oem2.inf'))
    [void] (New-SimDevice 'SCSI\DISK&VEN_NVME&PROD_SAMSUNG\4&1234&0&000000' 'Samsung SSD 990 PRO' 'DiskDrive' @('SCSI\DiskNVMe____Samsung') @('SCSI\Disk') 0 (New-SimDriver 'Microsoft' '10.0.26100.1' 'disk.inf') 'PCI\VEN_8086&DEV_9A0B&SUBSYS_0A9F1028&REV_00\3&11583659&0&70')
    $inv = Get-WdvInventory (Get-WdvSources '') 'Inspect'
    $pub = ConvertTo-WdvPublicInventory $inv (Get-WdvSources '')
    Assert-Equal @($pub.setupCritical).Count 1 'the VMD controller with a non-inbox driver and a disk below it is Setup-critical'
    $vmd = @($pub.devices | Where-Object { $_.category -eq 'storageRaid' })[0]
    Assert-True $vmd.setupCritical 'flagged on the device'
    # The bundle tool marks storage-class packages as Setup-critical.
    $out = Join-Path $script:S.Root 'bundles'
    New-Item -ItemType Directory -Path $out | Out-Null
    $b = New-WdvBundle (Join-Path $script:BundleSource 'packages\003-iastorvd') $out 'technicianFolder' (Get-WdvSources '') $script:S.System
    $m = Read-WdvJson (Join-Path $b.Folder 'drivers-manifest.json')
    Assert-Equal "$(@($m.packages).Count) $($m.packages[0].setupCritical) $($m.packages[0].class)" '1 True SCSIAdapter' 'storage package marked Setup-critical'
    Assert-True (Test-WdvBundle $b.Folder $b.Sha256 $b.FolderName (Get-WdvSources '')).Ok 'the new bundle validates against its own hash'
    # After installation: a not-working storage controller with a disk is never changed automatically.
    (Get-SimDevice 'PCI\VEN_8086&DEV_9A0B*').ProblemCode = 31
    [void] (Add-SimBundleDrive)
    $c = New-SimConfig
    Set-WuFinished
    $runs = Invoke-SimRuns $c
    Assert-Equal $script:S.PnpCalls.Count 0 'boot-critical storage driver left alone'
    Assert-Match @((Get-Op (Get-SimState $c) 'PCI\VEN_8086&DEV_9A0B*').reason) 'never changed automatically' 'explained'
}

$tests['F. unsupported and unknown hardware: nothing speculative is installed; unknown vendors stay visible'] = {
    Reset-Sim
    [void] (New-SimDevice 'ROOT\UNKNOWN\0000' 'Unknown device' '' @() @() 28 $null -ClassGuid $script:G.Other)
    [void] (New-SimDevice 'ACPI\XYZ0001\0' 'Unknown device' '' @() @() 28 $null -ClassGuid $script:G.Other)
    [void] (New-SimDevice 'PCI\VEN_1D17&DEV_9045&SUBSYS_00000000&REV_01\3&1&0&38' 'Base System Device' '' @('PCI\VEN_1D17&DEV_9045&SUBSYS_00000000&REV_01', 'PCI\VEN_1D17&DEV_9045') @('PCI\VEN_1D17&CC_088000', 'PCI\CC_0880') 28 $null -ClassGuid $script:G.Other)
    [void] (Add-SimBundleDrive)
    $c = New-SimConfig
    Set-WuFinished
    $runs = Invoke-SimRuns $c
    Assert-Equal $script:S.PnpCalls.Count 0 'the generic class package (PCI\CC_0880) is never installed'
    $st = Get-SimState $c
    $bsd = Get-Op $st 'PCI\VEN_1D17*'
    Assert-Equal $bsd.status 'ManualActionRequired' 'reported'
    Assert-Match @(@($bsd.candidates) | ForEach-Object { $_.result }) 'uncertain' 'the generic match is refused as uncertain'
    $unk = Get-Op $st 'ACPI\XYZ0001*'
    Assert-Equal $unk.status 'Unsupported' 'no identifiers: unsupported'
    $rep = Get-SimReport $c
    $dev = @($rep.devices | Where-Object { $_.hardwareIds -contains 'PCI\VEN_1D17&DEV_9045' })[0]
    Assert-Equal $dev.vendor.name 'Unknown vendor (PCI VEN_1D17)' 'unknown vendor shown with its id, nothing assumed'
    Assert-True (@($rep.unsupported).Count -ge 1) 'listed as unsupported'
    Assert-True (-not @($rep.devices | Where-Object { $_.instanceId -like 'ROOT\*' }).Count) 'software devices are not reported as hardware'
}

$tests['G. healthy driver with a newer package: kept by default; replaced only with an approval for that hardware ID'] = {
    Reset-Sim; Add-AmdDesktop; [void] (Add-SimBundleDrive)
    $c = New-SimConfig
    Set-WuFinished
    [void] (Invoke-SimRuns $c)
    Assert-Equal $script:S.PnpCalls.Count 0 'never: kept'
    Reset-Sim; Add-AmdDesktop; [void] (Add-SimBundleDrive)
    $script:S.Effects['u0400000.inf'] = 'forceWorks'
    $c = New-SimConfig { param($x) $x.policy.optionalReplacements = 'approvedOnly'; $x.approvals = @(@{ packageId = 'pkg-0000000000a5'; hardwareId = 'PCI\VEN_1002&DEV_73BF' }) }
    Set-WuFinished
    $runs = Invoke-SimRuns $c
    Assert-Equal $script:S.PnpCalls.Count 1 'the approved replacement'
    $op = Get-Op (Get-SimState $c) 'PCI\VEN_1002*'
    Assert-Equal "$($op.status) $($op.package.version) $($op.previousDriver.version)" 'Succeeded 32.0.21025.1024 31.0.24027.1012' 'newer version, previous one recorded'
}

$tests['H. a driver that breaks the device: detected, no further automatic attempt, recovery information kept'] = {
    Reset-Sim; Add-IntelDesktopWithNvidia; [void] (Add-SimBundleDrive)
    $script:S.Effects['nvdisp.inf'] = 'breaks'
    $c = New-SimConfig
    Set-WuFinished
    $runs = Invoke-SimRuns $c
    Assert-Equal $runs[-1] 'Finished:CompletedWithFailures' 'failures reported'
    Assert-Equal $script:S.PnpCalls.Count 1 'attempted once only'
    $st = Get-SimState $c
    $op = Get-Op $st 'PCI\VEN_10DE*'
    Assert-Equal "$($op.status) $($op.failureClass) $($op.problemAfter)" 'FailedPermanent DeviceFailure 10' 'the new problem is recorded'
    Assert-True $st.devices[$op.deviceKey].blocked 'no further automatic attempts for this device'
    Assert-Match @($op.manualAction.text) 'Roll Back Driver' 'technician instructions'
    Assert-Match @($op.manualAction.text) 'display\.inf' 'the previous driver is named'
    Assert-Equal (Get-SimReport $c).health.status 'InstalledButMalfunctioning' 'health distinguishes it'
    Assert-True ($script:S.Events -contains 4110) 'event 4110'
    $r = Invoke-WdvRetry $c -AllFailed -RequestedBy 'PC\Tech'
    Assert-Equal $r.Outcome 'NothingToDo' 'RetryFailed does not reopen a device failure'
    $r = Invoke-WdvRetry $c -Operations @($op.operationId) -IncludePermanent -RequestedBy 'PC\Tech'
    Assert-Equal $r.Outcome 'Accepted' 'a technician may reopen it after fixing the cause'
    Assert-True (-not (Get-SimState $c).devices[$op.deviceKey].blocked) 'unblocked by the technician'
}

$tests['selection: hardware ID before compatible ID, class, architecture, Windows build, signature, OEM subsystem'] = {
    Reset-Sim; Add-IntelDesktopWithNvidia
    $inv = Get-WdvInventory (Get-WdvSources '') 'Plan'
    $gpu = @($inv.Devices | Where-Object { $_.instanceId -like 'PCI\VEN_10DE*' })[0]
    $ctx = $inv.Context
    $mk = {
        param([string] $Name, [string] $Class, [string[]] $Ids, [string] $Deco = 'NTamd64.10.0...22000', [string] $Version = '32.0.15.8100', [string] $Sig = 'Valid', [string] $Signer = $script:WHQL)
        $dir = Join-Path $script:S.Root "pkg-$Name"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $guid = $script:G[$Class]
        $models = ($Ids | ForEach-Object { "%D% = I, $_" }) -join "`r`n"
        [IO.File]::WriteAllText((Join-Path $dir "$Name.inf"), "[Version]`r`nSignature=`"`$WINDOWS NT`$`"`r`nClass=$Class`r`nClassGuid=$guid`r`nProvider=%M%`r`nDriverVer=09/15/2026,$Version`r`nCatalogFile=$Name.cat`r`n[Manufacturer]`r`n%M%=Models,$Deco`r`n[Models.$Deco]`r`n$models`r`n[Strings]`r`nM=`"Test`"`r`nD=`"Test`"`r`n")
        [IO.File]::WriteAllText((Join-Path $dir "$Name.cat"), 'cat')
        $script:S.Signatures["$Name.cat".ToLowerInvariant()] = @{ Status = $Sig; Signer = $Signer }
        $info = Read-WdvInf (Join-Path $dir "$Name.inf")
        @{ Source = 'offlineBundle'; Id = $Name; Info = $info; Signature = (Test-WdvCatalog $info 'amd64' @($script:WHQL)); Inf = (Join-Path $dir "$Name.inf"); Root = $dir }
    }
    $hw = Test-WdvCandidate $gpu (& $mk 'hw' 'Display' @('PCI\VEN_10DE&DEV_2484&SUBSYS_146B10DE')) $ctx $gpu.assessment
    $cp = Test-WdvCandidate $gpu (& $mk 'cp' 'Display' @('PCI\VEN_10DE&CC_030000')) $ctx $gpu.assessment
    Assert-Equal "$($hw.Eligible) $($hw.Match) $($hw.Subsystem)" 'True hardwareId True' 'exact hardware ID with subsystem'
    Assert-True (-not $cp.Eligible -and $cp.RefusalClass -eq 'Uncertain') 'a vendor+class compatible ID is too generic: uncertain'
    $cv = Test-WdvCandidate $gpu (& $mk 'cv' 'Display' @('PCI\VEN_10DE&DEV_2484&CC_030000')) $ctx $gpu.assessment
    Assert-True ($cv.Eligible -and $cv.Score -gt $hw.Score) 'a more generic (later) hardware ID ranks after the exact one'
    $cls = Test-WdvCandidate $gpu (& $mk 'cls' 'Net' @('PCI\VEN_10DE&DEV_2484')) $ctx $gpu.assessment
    Assert-Equal $cls.RefusalClass 'Incompatible' 'device class mismatch refused'
    $arm = Test-WdvCandidate $gpu (& $mk 'arm' 'Display' @('PCI\VEN_10DE&DEV_2484') 'NTarm64.10.0...22000') $ctx $gpu.assessment
    Assert-Match @($arm.Refusal) 'no driver for amd64' 'wrong architecture refused'
    $ctx2 = $ctx.Clone(); $ctx2.OsBuild = 22631
    $new = Test-WdvCandidate $gpu (& $mk 'new' 'Display' @('PCI\VEN_10DE&DEV_2484') 'NTamd64.10.0...26100') $ctx2 $gpu.assessment
    Assert-Match @($new.Refusal) 'requires Windows build 26100' 'wrong Windows version refused'
    $uns = Test-WdvCandidate $gpu (& $mk 'uns' 'Display' @('PCI\VEN_10DE&DEV_2484') -Sig 'NotSigned') $ctx $gpu.assessment
    Assert-Equal $uns.RefusalClass 'Signature' 'unsigned refused'
    $auth = Test-WdvCandidate $gpu (& $mk 'auth' 'Display' @('PCI\VEN_10DE&DEV_2484') -Signer 'Contoso Ltd') $ctx $gpu.assessment
    Assert-Match @($auth.Refusal) 'not by Microsoft' 'Authenticode-only (not WHQL/attestation) refused'
    $model = Test-WdvCandidate $gpu (& $mk 'model' 'Display' @('PCI\VEN_10DE&DEV_2489')) $ctx $gpu.assessment
    Assert-Equal $model.RefusalClass 'NoMatch' 'another device model does not match'
    # OEM subsystem: a Dell-customized working GPU is not replaced by a generic package.
    Reset-Sim; Add-DellLaptop
    $inv = Get-WdvInventory (Get-WdvSources '') 'Plan'
    $igpu = @($inv.Devices | Where-Object { $_.category -eq 'display' })[0]
    $gen = Test-WdvCandidate $igpu (& $mk 'gen' 'Display' @('PCI\VEN_8086&DEV_A7A1') -Version '32.0.101.6000') $inv.Context $igpu.assessment
    Assert-Match @($gen.Refusal) 'OEM-customized' 'OEM restriction'
    $oem = Test-WdvCandidate $igpu (& $mk 'oem' 'Display' @('PCI\VEN_8086&DEV_A7A1&SUBSYS_0C031028') -Version '32.0.101.6000') $inv.Context $igpu.assessment
    Assert-True ($oem.Eligible -and $oem.Optional) 'the OEM package for this subsystem is an optional update (needs approval)'
}

$tests['selection: same driver not repeated; malfunctioning driver may get a different one; never a downgrade'] = {
    Reset-Sim
    [void] (New-SimDevice 'PCI\VEN_10EC&DEV_8125&SUBSYS_86771043&REV_05\4&2A1B&0&00E4' 'Realtek PCIe 2.5GbE' 'Net' @('PCI\VEN_10EC&DEV_8125&SUBSYS_86771043', 'PCI\VEN_10EC&DEV_8125') @('PCI\CC_0200') 10 (New-SimDriver 'Realtek' '10.68.815.2026' 'oem30.inf'))
    $inv = Get-WdvInventory (Get-WdvSources '') 'Plan'
    $nic = $inv.Devices[0]
    Assert-Equal $nic.assessment.state 'HardwareIssue' 'Code 10 is not assumed to be a driver problem'
    $nic.problemCode = 31; $nic.assessment = Get-WdvAssessment $nic (Get-WdvSources '')
    Assert-Equal "$($nic.assessment.state) $($nic.assessment.action)" 'Malfunctioning InstallRecommended' 'Code 31: a different driver may fix it'
    $root = Join-Path $script:BundleSource 'packages\002-rt25cx21x64'
    $info = Read-WdvInf (Join-Path $root 'rt25cx21x64.inf')
    $same = Test-WdvCandidate $nic @{ Source = 'offlineBundle'; Id = 'x'; Info = $info; Signature = @{ Ok = $true } } $inv.Context $nic.assessment
    Assert-Equal $same.RefusalClass 'NoEffect' 'the installed, not working driver is not installed again'
    $nic.driver.version = '10.70.0.0'
    $down = Test-WdvCandidate $nic @{ Source = 'offlineBundle'; Id = 'x'; Info = $info; Signature = @{ Ok = $true } } $inv.Context $nic.assessment
    Assert-Match @($down.Refusal) 'downgrade' 'never a downgrade'
}

$tests['Windows Update first: a device it fixed is AlreadySatisfied (source windowsUpdate); inspection waits for its restart'] = {
    Reset-Sim; Add-IntelDesktopWithNvidia; [void] (Add-SimBundleDrive)
    $c = New-SimConfig { param($x) $x.windowsUpdate.drivers = 'include' }
    [void] (Invoke-WdvMain $c)
    # Windows Update installs an NVIDIA driver that needs a restart, then finishes.
    $gpu = Get-SimDevice 'PCI\VEN_10DE*'
    $gpu.ProblemCode = 14; $gpu.PendingDriver = New-SimDriver 'NVIDIA' '32.0.15.7700' 'oem50.inf'
    $script:S.RebootPending = $true
    Set-WuFinished
    $r = Invoke-WdvMain $c
    Assert-Equal $r 'Rebooting' 'the stage restarts before judging the drivers'
    Assert-Equal $script:S.Reboots 1 'one restart'
    $runs = Invoke-SimRuns $c
    Assert-Equal $runs[-1] 'Finished:Succeeded' 'finished'
    Assert-Equal $script:S.PnpCalls.Count 0 'nothing installed by this stage: Windows Update already did it'
    $op = Get-Op (Get-SimState $c) 'PCI\VEN_10DE*'
    Assert-Equal "$($op.status) $($op.source)" 'AlreadySatisfied windowsUpdate' 'resolved by Windows Update'
    $insp = @((Get-SimReport $c).inspections | ForEach-Object { $_.id })
    Assert-Equal ($insp -join ',') 'Initial,AfterUpdates,Final' 'three inspections'
}

$tests['restart required: WaitingForReboot, restart, then verified on the device'] = {
    Reset-Sim; Add-IntelDesktopWithNvidia; [void] (Add-SimBundleDrive)
    $script:S.Effects['nvdisp.inf'] = 'needsRestart'
    $c = New-SimConfig
    Set-WuFinished
    $runs = Invoke-SimRuns $c
    Assert-True ($runs -contains 'Rebooting') "a restart was requested: $($runs -join ', ')"
    Assert-Equal $runs[-1] 'Finished:Succeeded' 'finished after the restart'
    $op = Get-Op (Get-SimState $c) 'PCI\VEN_10DE*'
    Assert-Equal "$($op.status) $($op.verification)" 'Succeeded Verified' 'verified after the restart, not before'
    Assert-Equal $script:S.PnpCalls.Count 1 'not installed twice'
}

$tests['verification: exit code 0 is not success; failed installs retried within the limit, signature failures never'] = {
    Reset-Sim; Add-IntelDesktopWithNvidia; [void] (Add-SimBundleDrive)
    $script:S.Effects['nvdisp.inf'] = 'notSelected'
    $c = New-SimConfig
    Set-WuFinished
    $runs = Invoke-SimRuns $c
    $op = Get-Op (Get-SimState $c) 'PCI\VEN_10DE*'
    Assert-Equal "$($op.status) $($op.failureClass)" 'ManualActionRequired NotSelected' 'pnputil exit 0 but the device unchanged: not a success'
    Assert-Equal $script:S.PnpCalls.Count 1 'not retried'
    Reset-Sim; Add-IntelDesktopWithNvidia; [void] (Add-SimBundleDrive)
    $script:S.Effects['nvdisp.inf'] = 'fail'
    $c = New-SimConfig
    Set-WuFinished
    $runs = Invoke-SimRuns $c -Max 20
    $op = Get-Op (Get-SimState $c) 'PCI\VEN_10DE*'
    Assert-Equal "$($op.status) $($op.totalAttempts)" 'FailedPermanent 2' 'two attempts (maxAttemptsPerOperation), then permanent'
    Assert-Equal $runs[-1] 'Finished:CompletedWithFailures' 'failures'
    Reset-Sim; Add-IntelDesktopWithNvidia; [void] (Add-SimBundleDrive)
    $script:S.Effects['nvdisp.inf'] = 'signature'
    $c = New-SimConfig
    Set-WuFinished
    [void] (Invoke-SimRuns $c)
    $op = Get-Op (Get-SimState $c) 'PCI\VEN_10DE*'
    Assert-Equal "$($op.status) $($op.failureClass) $($op.totalAttempts)" 'FailedPermanent Signature 1' 'a signature failure is a security failure, not retried'
    $r = Invoke-WdvRetry $c -Operations @($op.operationId) -IncludePermanent -RequestedBy 'PC\Tech'
    Assert-Equal $r.Outcome 'Refused' 'not even a technician reopens it without a new package'
}

$tests['offline bundle: pinned hash, modified file, unlisted file, wrong folder, unsigned catalog'] = {
    Reset-Sim
    $src = Get-WdvSources ''
    $pin = (New-SimConfig).bundle.manifestSha256
    $ok = Test-WdvBundle $script:BundleSource $pin $script:BundleFolder $src
    Assert-True $ok.Ok "the TypeScript-written bundle validates: $($ok.Problems -join '; ')"
    Assert-Equal @($ok.Packages).Count 6 'six packages'
    $wrong = Test-WdvBundle $script:BundleSource ('0' * 64) $script:BundleFolder $src
    Assert-Match @($wrong.Problems) 'not the pinned bundle' 'another bundle is refused'
    $copy = Join-Path $script:S.Root $script:BundleFolder
    Copy-Item -LiteralPath $script:BundleSource -Destination $copy -Recurse
    [IO.File]::AppendAllText((Join-Path $copy 'packages\001-nvdisp\nvdisp.sys'), 'x')
    [IO.File]::WriteAllText((Join-Path $copy 'packages\001-nvdisp\extra.dll'), 'x')
    $bad = Test-WdvBundle $copy $pin $script:BundleFolder $src
    Assert-True (-not $bad.Ok) 'modified bundle refused'
    Assert-Match @($bad.Problems) 'nvdisp\.sys was modified' 'modified file named'
    Assert-Match @($bad.Problems) 'unlisted file.*extra\.dll' 'unlisted file named'
    $script:S.Signatures['iastorvd.cat'] = @{ Status = 'HashMismatch'; Signer = $script:WHQL }
    $sig = Test-WdvBundle $script:BundleSource $pin $script:BundleFolder $src
    Assert-Match @($sig.Problems) 'catalog signature is HashMismatch' 'signature checked again on use'
    # A bundle found on a drive but not the pinned one is never staged.
    $script:S.Signatures.Remove('iastorvd.cat')
    $drive = Join-Path $script:S.Root 'usb2'
    New-Item -ItemType Directory -Path (Join-Path $drive 'WindowsDeployment\drivers') -Force | Out-Null
    Copy-Item -LiteralPath $copy -Destination (Join-Path $drive "WindowsDeployment\drivers\$script:BundleFolder") -Recurse
    $script:S.DriveRoots = @($drive + '\')
    $c = New-SimConfig
    $st = New-WdvState
    Invoke-WdvBundleStaging $c (Get-SimPaths $c) $st
    Assert-Equal $st.bundle.status 'Invalid' 'the modified copy is not staged'
}

$tests['bundle tool: unsigned packages refused, installer programs ignored, export uses pnputil /export-driver only'] = {
    Reset-Sim
    $src = Join-Path $script:S.Root 'vendor'
    Copy-Item -LiteralPath (Join-Path $script:BundleSource 'packages') -Destination $src -Recurse
    New-Item -ItemType Directory -Path (Join-Path $src 'exe-only') | Out-Null
    [IO.File]::WriteAllText((Join-Path $src 'exe-only\Setup.exe'), 'MZ')
    $script:S.Signatures['baseclass.cat'] = @{ Status = 'NotSigned'; Signer = '' }
    $out = Join-Path $script:S.Root 'out'
    New-Item -ItemType Directory -Path $out | Out-Null
    $b = New-WdvBundle $src $out 'technicianFolder' (Get-WdvSources '') $script:S.System
    Assert-Equal "$($b.Packages) $(@($b.Refused).Count)" '5 1' 'five packages, the unsigned one refused'
    Assert-Match @($b.Refused | ForEach-Object { "$($_.inf): $($_.reason)" }) 'baseclass\.inf: catalog signature is NotSigned' 'with the reason'
    Assert-True (-not (Test-Path (Join-Path $b.Folder 'packages\*\Setup.exe'))) 'installer programs are not part of a driver bundle'
    Assert-True ($b.FolderName -match $script:WdvBundleFolder) 'bundle folder naming'
    $threw = $false
    try { [void] (Invoke-WdvPnpUtilReal @('/delete-driver', 'oem1.inf', '/uninstall')) } catch { $threw = $true }
    Assert-True $threw 'pnputil /delete-driver is refused before anything runs'
    $threw = $false
    try { [void] (Invoke-WdvPnpUtilReal @('/add-driver', 'x.inf', '/install', '/force')) } catch { $threw = $true }
    Assert-True $threw 'no /force'
}

$tests['verified download: official host, SHA-256 checked, reused, tampered file deleted and never retried, offline waits'] = {
    Reset-Sim
    [void] (New-SimDevice 'PCI\VEN_1D6A&DEV_07B1&SUBSYS_00011D6A&REV_02\4&9A8B&0&00E0' 'Ethernet Controller' '' @('PCI\VEN_1D6A&DEV_07B1&SUBSYS_00011D6A&REV_02', 'PCI\VEN_1D6A&DEV_07B1') @('PCI\CC_0200') 28 $null -ClassGuid $script:G.Other)
    $content = Join-Path $script:S.Root 'cab-content'
    New-Item -ItemType Directory -Path $content | Out-Null
    [IO.File]::WriteAllText((Join-Path $content 'aqnic.inf'), "[Version]`r`nSignature=`"`$WINDOWS NT`$`"`r`nClass=Net`r`nClassGuid=$($script:G.Net)`r`nProvider=%M%`r`nDriverVer=05/01/2026,3.1.0.0`r`nCatalogFile=aqnic.cat`r`n[Manufacturer]`r`n%M%=Models,NTamd64.10.0...22000`r`n[Models.NTamd64.10.0...22000]`r`n%D%=I,PCI\VEN_1D6A&DEV_07B1`r`n[Strings]`r`nM=`"Marvell`"`r`nD=`"AQtion`"`r`n")
    [IO.File]::WriteAllText((Join-Path $content 'aqnic.cat'), 'cat')
    $cab = Join-Path $script:S.Root 'served.cab'
    [IO.File]::WriteAllText($cab, 'cabinet bytes')
    $hash = Get-WdvFileHash $cab
    $url = 'https://download.microsoft.com/download/contoso/nic.cab'
    $script:S.DownloadSource[$url] = $cab
    $script:S.CabContent['contoso-nic.cab'] = $content
    $c = New-SimConfig { param($x) $x.bundle = $null; $x.verifiedPackages[0].sha256 = $hash }
    Set-WuFinished
    $runs = Invoke-SimRuns $c
    Assert-Equal $runs[-1] 'Finished:Succeeded' "finished: $($runs -join ', ')"
    Assert-Equal $script:S.Downloads.Count 1 'downloaded once'
    $op = Get-Op (Get-SimState $c) 'PCI\VEN_1D6A*'
    Assert-Equal "$($op.status) $($op.source)" 'Succeeded verifiedDownload' 'installed from the verified package'
    Assert-True (Test-Path (Join-Path (Get-SimPaths $c).Packages 'download\contoso-nic\verified.json')) 'verified copy recorded'
    Assert-True (-not @(Get-ChildItem (Get-SimPaths $c).Downloads -Filter '*.part' -ErrorAction SilentlyContinue).Count) 'no partial download left'
    # Tampered: the wrong file is deleted and the operation is never retried automatically.
    Reset-Sim
    [void] (New-SimDevice 'PCI\VEN_1D6A&DEV_07B1&SUBSYS_00011D6A&REV_02\4&9A8B&0&00E0' 'Ethernet Controller' '' @('PCI\VEN_1D6A&DEV_07B1') @('PCI\CC_0200') 28 $null -ClassGuid $script:G.Other)
    $script:S.DownloadSource[$url] = 'tamper'
    $c = New-SimConfig { param($x) $x.bundle = $null; $x.verifiedPackages[0].sha256 = $hash }
    Set-WuFinished
    $runs = Invoke-SimRuns $c
    $op = Get-Op (Get-SimState $c) 'PCI\VEN_1D6A*'
    Assert-Equal "$($op.status) $($op.failureClass)" 'FailedPermanent Integrity' 'tampered download is a security failure'
    Assert-Equal $script:S.Downloads.Count 1 'not downloaded again'
    Assert-Equal $script:S.PnpCalls.Count 0 'never installed'
    Assert-True (-not @(Get-ChildItem (Get-SimPaths $c).Downloads -File -ErrorAction SilentlyContinue).Count) 'the wrong file was deleted'
    # Offline: waits for the network without counting attempts, then becomes a manual action.
    Reset-Sim
    [void] (New-SimDevice 'PCI\VEN_1D6A&DEV_07B1&SUBSYS_00011D6A&REV_02\4&9A8B&0&00E0' 'Ethernet Controller' '' @('PCI\VEN_1D6A&DEV_07B1') @('PCI\CC_0200') 28 $null -ClassGuid $script:G.Other)
    $script:S.Online = $false
    $c = New-SimConfig { param($x) $x.bundle = $null; $x.verifiedPackages[0].sha256 = $hash; $x.windowsUpdate.enabled = $false }
    $runs = Invoke-SimRuns $c
    $op = Get-Op (Get-SimState $c) 'PCI\VEN_1D6A*'
    Assert-Equal "$($op.status) $($op.totalAttempts)" 'ManualActionRequired 0' 'no attempt was used up while offline'
    Assert-Equal $script:S.Downloads.Count 0 'no download attempted offline'
}

$tests['policy: organization device-installation restrictions are respected; nothing installed'] = {
    Reset-Sim; Add-IntelDesktopWithNvidia; [void] (Add-SimBundleDrive)
    $script:S.Policy = @{ Restricted = $true; Detail = 'DenyUnspecified' }
    $c = New-SimConfig
    Set-WuFinished
    [void] (Invoke-SimRuns $c)
    Assert-Equal $script:S.PnpCalls.Count 0 'nothing installed under a restriction policy'
    $op = Get-Op (Get-SimState $c) 'PCI\VEN_10DE*'
    Assert-Equal "$($op.status) $($op.failureClass)" 'ManualActionRequired Policy' 'reported as policy'
}

$tests['recovery: an interrupted installation is reconciled with the device; finished work is never repeated'] = {
    Reset-Sim; Add-IntelDesktopWithNvidia; [void] (Add-SimBundleDrive)
    $c = New-SimConfig
    Set-WuFinished
    Assert-Equal (Invoke-WdvMain $c) 'Finished:Succeeded' 'resolved in one run'
    $p = Get-SimPaths $c
    $st = Read-WdvState $p
    # Simulate a power loss in the middle of the installation: the attempt was saved as Running,
    # but the device did change (Windows finished it).
    $op = Get-Op $st 'PCI\VEN_10DE*'
    $op.status = 'Running'; $op.verification = 'NotVerified'; $st.phase = 'Resolving'; $st.final = $null
    Save-WdvState $p $st
    $before = $script:S.PnpCalls.Count
    $runs = Invoke-SimRuns $c
    Assert-Equal $script:S.PnpCalls.Count $before 'not installed again'
    Assert-Equal (Get-Op (Get-SimState $c) 'PCI\VEN_10DE*').status 'Succeeded' 'reconciled from the device: it works with the package'
    # Interrupted before anything changed: tried again (the attempt counts).
    Reset-Sim; Add-IntelDesktopWithNvidia; [void] (Add-SimBundleDrive)
    $c = New-SimConfig
    [void] (Invoke-WdvMain $c)
    Set-WuFinished
    $p = Get-SimPaths $c
    $st = Read-WdvState $p
    $op = Get-Op $st 'PCI\VEN_10DE*'
    $op.status = 'Running'; $op.attempts = 1; $op.totalAttempts = 1; $op.waitingFor = ''; $st.phase = 'Resolving'
    Save-WdvState $p $st
    $runs = Invoke-SimRuns $c
    $op = Get-Op (Get-SimState $c) 'PCI\VEN_10DE*'
    Assert-Equal "$($op.status) $($op.totalAttempts)" 'Succeeded 2' 'tried again and verified'
    # A damaged state file falls back to its last good copy.
    [IO.File]::WriteAllText($p.State, '{ damaged')
    $s2 = Read-WdvState $p
    Assert-Equal (Get-Op $s2 'PCI\VEN_10DE*').status 'Succeeded' 'recovered from state.json.bak (the last good copy)'
}

$tests['lifecycle: Inspection A, Windows Update, restart, Inspection B, install, restart, verification, result for Phase 9'] = {
    Reset-Sim; Add-IntelDesktopWithNvidia; [void] (Add-SimBundleDrive)
    $script:S.Effects['nvdisp.inf'] = 'needsRestart'
    $c = New-SimConfig
    $p = Get-SimPaths $c
    $r = Invoke-WdvMain $c
    Assert-Equal $r 'WaitingForWindowsUpdate' '1. Inspection A, then waiting'
    Assert-True (Test-Path (Join-Path $p.Root 'inventory-initial.json')) 'inventory before Windows Update'
    $live = Read-WdvJson $p.Report
    Assert-Equal "$($live.final) $($live.status)" 'False InProgress' 'drivers.json is live while the stage runs'
    $script:S.Now = $script:S.Now.AddHours(1)
    Assert-Equal (Invoke-WdvMain $c) 'WaitingForWindowsUpdate' '2. still waiting while Windows Update works'
    Set-WuFinished; $script:S.RebootPending = $true
    Assert-Equal (Invoke-WdvMain $c) 'Rebooting' '3. restart after Windows Update before Inspection B'
    Invoke-SimReboot
    $r = Invoke-WdvMain $c
    Assert-Equal $r 'Rebooting' '4. Inspection B, installation, restart for the new driver'
    Assert-True (Test-Path (Join-Path $p.Root 'inventory-after-updates.json')) 'inventory after Windows Update'
    Invoke-SimReboot
    $r = Invoke-WdvMain $c
    Assert-Equal $r 'Finished:Succeeded' '5. verified and finished'
    $res = Read-WdvJson $p.Result
    Assert-Equal "$($res.status) $($res.reboots) $($res.health)" 'Succeeded 2 AllHealthy' 'result.json'
    $rep = Read-WdvJson $p.Report
    Assert-Equal "$($rep.format) $($rep.version) $($rep.final)" 'windows-deployment-builder/drivers-result 1 True' 'drivers.json contract'
    foreach ($k in 'deploymentId', 'scanUtc', 'system', 'windowsUpdate', 'health', 'devices', 'operations', 'manualActions', 'unsupported', 'optionalApplications', 'networkBootstrap', 'offlineBundle') { Assert-True ($rep.ContainsKey($k)) "drivers.json has $k" }
    $gpu = @($rep.devices | Where-Object { $_.category -eq 'display' })[0]
    Assert-Equal "$($gpu.result) $($gpu.verification) $($gpu.source) $($gpu.previousDriver.inf) $($gpu.stateBeforeUpdates)" 'Succeeded Verified offlineBundle display.inf BasicDriver' 'device record'
    Assert-Equal (Invoke-WdvMain $c) 'AlreadyFinished' '6. a later start does nothing'
    $lines = @([IO.File]::ReadAllLines($p.Attempts))
    Assert-True ($lines.Count -ge 2) 'attempts.jsonl'
}

$tests['privacy: instance-specific identifiers are hashed in every shared file; no serial numbers'] = {
    Reset-Sim
    [void] (New-SimDevice 'USB\VID_0781&PID_5581\4C530001234567891234' 'SanDisk Ultra' 'USB' @('USB\VID_0781&PID_5581&REV_0100', 'USB\VID_0781&PID_5581') @('USB\Class_08&SubClass_06&Prot_50') 0 (New-SimDriver 'Microsoft' '10.0.26100.1' 'usbstor.inf'))
    [void] (New-SimDevice 'PCI\VEN_10DE&DEV_2484&SUBSYS_146B10DE&REV_A1\4&1A2B3C4D&0&0008' 'GPU' 'Display' @('PCI\VEN_10DE&DEV_2484') @() 0 (New-SimDriver 'NVIDIA' '32.0.15.8100' 'oem1.inf'))
    $src = Get-WdvSources ''
    $inv = Get-WdvInventory $src 'Inspect'
    $pub = ConvertTo-WdvPublicInventory $inv $src
    $json = $pub | ConvertTo-Json -Depth 12
    Assert-True ($json -notmatch '4C530001234567891234') 'the USB serial number is not in the inventory'
    $usb = @($pub.devices | Where-Object { $_.hardwareIds -contains 'USB\VID_0781&PID_5581' })[0]
    Assert-True ($usb.instanceId -match '^USB\\VID_0781&PID_5581\\#[0-9a-f]{8}$') "the instance id keeps the device id and a hash: $($usb.instanceId)"
    $c = New-SimConfig { param($x) $x.windowsUpdate.enabled = $false }
    [void] (Invoke-SimRuns $c)
    $rep = [IO.File]::ReadAllText((Get-SimPaths $c).Report)
    Assert-True ($rep -notmatch '4C530001234567891234') 'not in drivers.json either'
    Assert-True ($rep -notmatch '"computer"|serialNumber|"uuid"') 'no computer name, serial or UUID fields'
}

$tests['applications wait for the driver stage only when the configuration names it'] = {
    Reset-Sim
    $appScript = Join-Path $script:PkgScripts 'applications\ApplicationEngine.ps1'
    . $appScript -Mode Plan -ConfigPath 'none' 2>$null
    Set-StrictMode -Version 2.0
    function Get-WdaNow { $script:S.Now }
    function Test-WdaUpdateTask { param([hashtable] $WU) $true }
    $state = @{ firstStartUtc = $script:S.Now.ToString('o') }
    $cfg = @{ waitForUpdatesHours = 10; coordination = @{ policy = 'updatesFirst'; windowsUpdate = @{ enabled = $false } } }
    Assert-True (Get-WdaDriversGate $cfg $state).Open 'no driver stage in the configuration: no wait (older configurations)'
    $dr = @{ enabled = $true; stateFile = (Join-Path $script:S.Root 'Drivers\state.json'); resultFile = (Join-Path $script:S.Root 'Drivers\result.json'); taskPath = '\WindowsDeploymentBuilder\'; taskName = 'Drivers' }
    $cfg.coordination.drivers = $dr
    Assert-True (-not (Get-WdaDriversGate $cfg $state).Open) 'waits while the driver stage runs'
    Write-WdvJson $dr.resultFile @{ status = 'CompletedWithFailures' }
    Assert-True (Get-WdaDriversGate $cfg $state).Open 'any final driver status opens it: a driver failure never blocks the applications'
    Remove-Item $dr.resultFile
    $script:S.Now = $script:S.Now.AddHours(11)
    $g = Get-WdaDriversGate $cfg $state
    Assert-True ($g.Open -and $g.ContainsKey('Warn')) 'and waitForUpdatesHours bounds the wait'
    $gen = ConvertTo-WdvHashtable ([IO.File]::ReadAllText((Join-Path $script:PkgScripts 'applications\applications-config.json')) | ConvertFrom-Json)
    Assert-Equal $gen.coordination.drivers.taskName 'Drivers' 'the generated application configuration names the driver stage'
}

# ------------------------------------------------------------------------------------------------
# Orchestrator integration (the drivers fixture package: Phase 4-7 scripts with the driver stage)
# ------------------------------------------------------------------------------------------------

$tests['orchestrator: the driver stage is launched once, followed, reported and recoverable'] = {
    Reset-Sim; Add-IntelDesktopWithNvidia
    $c = New-SimConfig { param($x) $x.bundle = $null }
    Set-WuFinished
    [void] (Invoke-SimRuns $c)
    . (Join-Path $script:PkgScripts 'common\DeploymentCommon.ps1')
    . (Join-Path $script:PkgScripts 'finalization\Complete-Deployment.ps1')
    Set-StrictMode -Version 2.0
    function Get-WddNow { $script:S.Now }
    function Get-WddBootTime { $script:S.Boot }
    function Get-WddTask { param([string] $TaskPath, [string] $TaskName) $false }
    function Get-WddSystemInfo { [ordered]@{ computerName = 'SIM'; windows = 'Microsoft Windows 11 Pro' } }
    $m = Read-WddManifest (Join-Path $script:DrvFixture 'usb\WindowsDeployment\deployment-manifest.json')
    Assert-Equal ((Get-WddEngineStages $m | ForEach-Object { $_.id }) -join ',') 'windowsUpdate,applications,drivers' 'engine stages include drivers'
    $dstage = Get-WddStage $m 'drivers'
    Assert-Equal "$($dstage.launcher) $($dstage.task.name)" 'scripts/drivers/Install-DriverEngine.ps1 Drivers' 'driver stage launcher and task'
    $paths = Get-WddPaths $script:S.DataRoot
    $state = @{ schemaVersion = 2; packageId = $m.packageId; packageVersion = $m.packageVersion; orchestratorVersion = '1.1.0'; sourceMode = 'Embedded'; status = 'InProgress'; initializedUtc = $script:S.Now.ToString('o'); initializedBy = 'PC\Alex'
                deadlineUtc = $script:S.Now.AddDays(2).ToString('o'); stalledAfterMinutes = 120; stagedFiles = @(); monitorRuns = 0; overall = ''; message = ''; recoveries = @()
                stages = @{ drivers = @{ launchResult = 'Launched'; launchedUtc = $script:S.Now.ToString('o'); attempts = 1; exitCode = 0; message = ''; user = 'SYSTEM' } } }
    $snap = Get-WddSnapshot $m $paths $state
    $ds = @($snap.stages | Where-Object { $_.id -eq 'drivers' })[0]
    Assert-Equal "$($ds.state) $($ds.status)" 'Final CompletedWithFollowUp' 'the monitor reads the driver result'
    Assert-Equal $snap.drivers.state 'Final' 'snapshot drivers entry'
    $report = New-WddReport $m $paths $state $snap 'CompletedWithFollowUp' 'test'
    Assert-Equal $report.drivers.health.status 'MissingDriver' 'report carries the driver health'
    Assert-Match @($report.remainingTasks) '^Driver: .*NVIDIA|^Driver: .*10DE' 'unresolved GPU is a remaining task'
    Assert-Match @($report.outstanding | ForEach-Object { "$($_.operationId) $($_.action)" }) '^driver:dev-[0-9a-f]{12} install the driver by hand' 'outstanding driver operation with what to do'
    $text = Format-WddReport $report
    Assert-Match @($text -split "`r`n") '^Hardware & drivers$' 'report section'
    Assert-Match @($text -split "`r`n") 'MANUAL' 'manual action in the text report'
    # Missing network driver: the deployment outcome says so instead of just "waiting for network".
    Write-WdvJson (Join-Path $paths.StateDir 'network-driver-missing.json') @{ detail = 'No network: Ethernet Controller has no working driver.' }
    Remove-Item (Join-Path $script:S.DataRoot 'Drivers\result.json')
    Write-WdvJson (Join-Path $script:S.DataRoot 'Drivers\status.json') @{ phase = 'WaitingForNetwork'; detail = 'No network'; updatedUtc = $script:S.Now.ToString('o') }
    $snap = Get-WddSnapshot $m $paths $state
    Assert-Equal "$($snap.outcome) $($snap.outcomeCode)" 'PausedAwaitingNetwork 30' 'Phase 5 outcome'
    Assert-Match @($snap.outcomeDetail) 'has no working driver' 'the reason is the missing network driver'
}

$tests['recovery tool: driver operations listed, RetryFailed reopens retryable ones, AddDrivers validates packages'] = {
    Reset-Sim; Add-IntelDesktopWithNvidia; [void] (Add-SimBundleDrive)
    $script:S.Effects['nvdisp.inf'] = 'fail'
    $c = New-SimConfig
    Set-WuFinished
    [void] (Invoke-WdvMain $c)
    [void] (Invoke-WdvMain $c)
    . (Join-Path $script:PkgScripts 'recovery\DeploymentRecovery.ps1') -Action Status
    Set-StrictMode -Version 2.0
    $paths = Get-WddPaths $script:S.DataRoot
    $ops = @(Get-WdrOperations $paths)
    $op = @($ops | Where-Object { $_.operationId -like 'driver:*' })[0]
    Assert-Equal "$($op.lifecycle) $($op.retryable)" 'FailedRetryable True' "driver operation in the recovery status: $(@($ops | ForEach-Object { "$($_.operationId)=$($_.lifecycle)" }) -join ', ')"
    $pending = @(Get-WdrPendingActions @{ packageId = 'x' } $paths)
    Assert-Match $pending '\[driver:dev-[0-9a-f]{12}\]: failed after automatic retries; run RetryFailed' 'pending actions list the driver operation'
    $r = Invoke-WdvRetry $c -AllFailed -RequestedBy 'PC\Tech'
    Assert-True ($r.Accepted -contains $op.operationId) 'RetryFailed reopens it through the engine'
    $st = Get-SimState $c
    Assert-Equal "$($st.phase)|$($st.final)" 'Resolving|' 'the stage runs again'
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
Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'wdv-test-*' -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "$($script:Passed) passed, $($script:Failures) failed"
if ($script:Failures -gt 0) { exit 1 }
exit 0
