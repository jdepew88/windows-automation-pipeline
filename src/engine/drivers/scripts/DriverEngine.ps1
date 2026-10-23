#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Deployment Builder - hardware-aware driver engine.

.DESCRIPTION
    Identifies the hardware the computer actually contains, inspects the driver every device uses,
    and installs a driver only where one is missing or not working and a verified, compatible
    package exists. Written independently for this project on documented interfaces (CIM
    Win32_PnPEntity / Win32_PnPSignedDriver, PnP device properties, pnputil.exe, expand.exe,
    Authenticode); no third-party code.

    Runs as SYSTEM from the scheduled task \WindowsDeploymentBuilder\Drivers (registered by
    Install-DriverEngine.ps1, launched once by the deployment orchestrator). Conservative by design:

      1. Inspection A at the first start: every present device, its identifiers and driver state.
         If no network adapter has a working driver, verified offline packages are tried first
         (network bootstrap).
      2. Windows Update first: waits until the Windows Update stage is final and no restart is
         pending (the Windows Update engine stays the only update engine; this one never calls it).
      3. Inspection B after that restart: what Windows and Windows Update resolved is recorded and
         left alone.
      4. Resolution for what remains, in order: the Windows driver store, a verified offline bundle
         (pinned by SHA-256), technician-verified packages (official HTTPS host + SHA-256, INF only),
         otherwise a manual action with the official support page. Candidates are pre-filtered by
         hardware/compatible ID, device class, architecture, Windows build, Microsoft (WHQL or
         attestation) catalog signature and OEM subsystem; Windows' own ranking makes the final
         choice (pnputil /add-driver /install never forces a driver).
      5. Verification of the device itself, after a restart when one is needed. Exit code 0 is not
         success: success is the device working with the installed package.

    Never: disables signature enforcement or Secure Boot, runs vendor EXE installers, flashes
    firmware, removes or rolls back drivers, downgrades a working driver, replaces a healthy driver
    without technician approval, or changes Windows Update or device-installation policy.

    Final states (result.json): Succeeded, CompletedWithFollowUp, CompletedWithFailures, Failed.
    The marker <dataRoot>\state\drivers.done is written for the first three. The machine-readable
    report for Phase 9 is <dataRoot>\reports\drivers.json.

    Modes:
      Run            (default) Full engine (SYSTEM task).
      Inspect        Read-only hardware inventory (no administrator rights needed). -OutputPath
                     writes the shareable inventory (serial-like identifiers replaced by hashes).
      Plan           Read-only: inventory, assessment and the candidate decision for every device.
      Export         Exports the driver store's third-party packages (pnputil /export-driver) into a
                     verified offline bundle under -OutputPath. Changes nothing on this computer.
      Bundle         Builds a verified offline bundle from a folder of INF driver packages (-Path).
      ValidateBundle Checks a bundle (-Path) and, with -ExpectedSha256, that it is the pinned one.
      AddPackages    Technician recovery: validates INF packages from -Path and stages them for
                     this deployment, then reopens the devices they apply to.
      Retry          Technician recovery: reopens failed driver operations (-Operation / -AllFailed).
      Library        Defines the functions only (used by other tools).
#>
[CmdletBinding()]
param(
    [ValidateSet('Run', 'Inspect', 'Plan', 'Export', 'Bundle', 'ValidateBundle', 'AddPackages', 'Retry', 'Library')]
    [string] $Mode = 'Run',
    [string] $ConfigPath = '',
    [string] $OutputPath = '',
    [string] $Path = '',
    [string] $ExpectedSha256 = '',
    [string[]] $Operation = @(),
    [switch] $AllFailed,
    [switch] $IncludePermanent,
    [string] $RequestedBy = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Captured first: a script that dot-sources this file keeps its own arguments.
$script:WdvMain = $MyInvocation.InvocationName -ne '.'
$script:WdvArgs = @{ Mode = $Mode; ConfigPath = $ConfigPath; OutputPath = $OutputPath; Path = $Path; ExpectedSha256 = $ExpectedSha256; Operation = @($Operation); AllFailed = [bool] $AllFailed; IncludePermanent = [bool] $IncludePermanent; RequestedBy = $RequestedBy }

$script:WdvVersion = '1.0.0'
$script:WdvStateVersion = 1
$script:WdvInventoryFormat = 'windows-deployment-builder/hardware-inventory'
$script:WdvBundleFormat = 'windows-deployment-builder/driver-bundle'
$script:WdvResultFormat = 'windows-deployment-builder/drivers-result'
$script:WdvEventSource = 'WindowsDeploymentBuilder'
$script:WdvLogFile = $null
$script:WdvStatusFile = $null
$script:WdvSha = '^[0-9A-F]{64}$'
$script:WdvBundleFolder = '^WDB-Drivers-\d{8}-\d{6}-[0-9a-f]{6}$'
$script:WdvLimits = @{ maxPackages = 400; maxFiles = 20000; maxBytes = 8GB; maxInfBytes = 8MB; maxHardwareIds = 4000 }

# Lifecycle of a driver operation (the Phase 5 names). Terminal ones end the operation.
$script:WdvStatuses = @('Pending', 'Running', 'AlreadySatisfied', 'Succeeded', 'WaitingForNetwork', 'WaitingForReboot', 'ManualActionRequired', 'FailedRetryable', 'FailedPermanent', 'Unsupported')
$script:WdvTerminal = @('AlreadySatisfied', 'Succeeded', 'ManualActionRequired', 'FailedPermanent', 'Unsupported')
# Never retried automatically; Integrity and Signature are not reopened even by a technician
# unless the package itself was replaced (a security failure, not a transient error).
$script:WdvPermanentClasses = @('Permanent', 'Integrity', 'Signature', 'Incompatible', 'Policy', 'DeviceFailure', 'NoEffect', 'NotSelected', 'Manual')
$script:WdvSecurityClasses = @('Integrity', 'Signature')

# Device Manager problem codes (cfg.h, "Device Manager error messages").
$script:WdvProblemNames = @{
    1 = 'not configured'; 3 = 'out of memory'; 9 = 'invalid data'; 10 = 'cannot start'; 12 = 'resource conflict'; 14 = 'restart required'
    16 = 'partial resources'; 18 = 'reinstall the drivers'; 19 = 'registry problem'; 21 = 'being removed'; 22 = 'disabled'; 24 = 'not present'
    28 = 'drivers not installed'; 29 = 'disabled by firmware'; 31 = 'not working properly'; 32 = 'driver service disabled'; 33 = 'resource translation failed'
    34 = 'no automatic configuration'; 35 = 'firmware tables incomplete'; 36 = 'IRQ translation failed'; 37 = 'driver initialization failed'
    38 = 'previous driver instance still loaded'; 39 = 'driver corrupted or missing'; 40 = 'driver service key invalid'; 41 = 'driver loaded, device not found'
    42 = 'duplicate device'; 43 = 'device reported a problem'; 44 = 'halted by an application or service'; 45 = 'not connected'; 46 = 'shutdown pending'
    47 = 'prepared for safe removal'; 48 = 'driver blocked (known problems)'; 49 = 'registry too large'; 50 = 'properties could not be applied'
    51 = 'waiting on another device'; 52 = 'driver signature cannot be verified'; 53 = 'reserved for the debugger'; 54 = 'device reset failed'
    55 = 'console locked'; 56 = 'class configuration pending'; 57 = 'guest assignment failed'
}
# A different (working) driver may fix these; others point at hardware, firmware or resources.
$script:WdvDriverProblems = @(1, 18, 19, 28, 31, 32, 37, 39, 40, 41, 50, 56)
$script:WdvHardwareProblems = @(3, 9, 10, 12, 16, 29, 33, 34, 35, 36, 38, 42, 43, 44, 46, 47, 49, 51, 53, 54, 55, 57)
# Enumerators of software-only devices (no physical hardware behind them).
$script:WdvVirtualEnumerators = @('ROOT', 'SWD', 'SW', 'HTREE', 'UMB', 'STORAGE', 'VOLUME', 'BTHENUM', 'BTHLEDEVICE', 'BTHLE', 'LPTENUM', 'WPDBUSENUMROOT', 'TS_USB_HUB_ENUMERATOR', 'RDPBUS', 'ROOT_HUB_FDO')

# ------------------------------------------------------------------------------------------------
# Small helpers (time, waiting, JSON) - kept as functions so tests can replace them.
# ------------------------------------------------------------------------------------------------

function Get-WdvNow { [DateTime]::UtcNow }

function Wait-Wdv { param([int] $Seconds) if ($Seconds -gt 0) { Start-Sleep -Seconds $Seconds } }

function ConvertTo-WdvDate {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    try { [DateTime]::Parse([string] $Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch { $null }
}

function ConvertTo-WdvHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-WdvHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-WdvHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return , @($InputObject | ForEach-Object { ConvertTo-WdvHashtable $_ })
    }
    return $InputObject
}

<# Atomic write (temp file written through, then replaced); -Backup keeps the last good copy as .bak. #>
function Write-WdvJson {
    param([string] $Path, $Value, [switch] $Backup)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $Value | ConvertTo-Json -Depth 14
    $tmp = "$Path.tmp"
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    $fs = New-Object System.IO.FileStream($tmp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::WriteThrough)
    try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
    if (Test-Path -LiteralPath $Path) {
        try { [System.IO.File]::Replace($tmp, $Path, $(if ($Backup) { "$Path.bak" } else { $null })); return }
        catch { if ($Backup) { Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force } }
    }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Read-WdvJson {
    param([string] $Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try { ConvertTo-WdvHashtable ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { $null }
}

function Get-WdvSha256 {
    param([byte[]] $Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('X2') }) } finally { $sha.Dispose() }
}

function Get-WdvFileHash {
    param([string] $Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try { -join ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('X2') }) } finally { $fs.Dispose(); $sha.Dispose() }
}

function Get-WdvShortHash { param([string] $Text) (Get-WdvSha256 ([System.Text.Encoding]::UTF8.GetBytes($Text.ToUpperInvariant()))).Substring(0, 12).ToLowerInvariant() }

function Write-WdvLog {
    param([string] $Message, [ValidateSet('INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO')
    $line = '{0}  {1,-5}  {2}' -f (Get-WdvNow).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Verbose $line
    if (-not $script:WdvLogFile) { return }
    for ($i = 0; $i -lt 3; $i++) {
        try { [System.IO.File]::AppendAllText($script:WdvLogFile, $line + "`r`n"); return } catch { Start-Sleep -Milliseconds 200 }
    }
}

function Set-WdvStatus {
    param([string] $Phase, [string] $Detail, [hashtable] $State)
    if (-not $script:WdvStatusFile) { return }
    $o = [ordered]@{ phase = $Phase; detail = $Detail; updatedUtc = (Get-WdvNow).ToString('o'); engineVersion = $script:WdvVersion; reboots = 0; done = 0; total = 0 }
    if ($State) {
        $o.reboots = [int] $State.reboots
        $ops = @(Get-WdvOperationList $State)
        $o.total = $ops.Count
        $o.done = @($ops | Where-Object { $_.status -in $script:WdvTerminal }).Count
    }
    try { Write-WdvJson $script:WdvStatusFile $o } catch { Write-WdvLog "Could not write status.json: $($_.Exception.Message)" 'WARN' }
}

function Write-WdvEvent {
    param([int] $EventId, [string] $Message, [ValidateSet('Information', 'Warning', 'Error')] [string] $EntryType = 'Information')
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($script:WdvEventSource)) { New-EventLog -LogName Application -Source $script:WdvEventSource }
        Write-EventLog -LogName Application -Source $script:WdvEventSource -EventId $EventId -EntryType $EntryType -Message $Message
    } catch { Write-WdvLog "Could not write event $EventId to the Application log: $($_.Exception.Message)" 'WARN' }
}

# ------------------------------------------------------------------------------------------------
# Configuration and paths
# ------------------------------------------------------------------------------------------------

function Get-WdvConfig {
    param([string] $Path)
    if (-not $Path) { $Path = Join-Path $PSScriptRoot 'drivers-config.json' }
    $c = Read-WdvJson $Path
    if ($c -isnot [hashtable]) { throw "Driver configuration not found or not valid JSON: $Path" }
    if ([int] $c.schemaVersion -ne 1) { throw "Unsupported driver configuration version $($c.schemaVersion)." }
    if ([string] $c.dataRoot -notmatch '^[A-Za-z]:\\[^"*?<>|]+$') { throw 'The driver configuration has an invalid dataRoot.' }
    foreach ($k in 'policy', 'windowsUpdate', 'sources') { if ($c[$k] -isnot [hashtable]) { throw "The driver configuration has no '$k' block." } }
    $defaults = @{ maxReboots = 2; maxAttemptsPerOperation = 2; maxRuntimeHours = 24; waitForUpdatesHours = 26; networkWaitMinutes = 5; lockWaitMinutes = 60; rebootWarningSeconds = 120; maxNetworkDeferrals = 6 }
    foreach ($k in @($defaults.Keys)) { if (-not $c.ContainsKey($k) -or $null -eq $c[$k]) { $c[$k] = $defaults[$k] } }
    $c.maxReboots = [int] [Math]::Min(5, [Math]::Max(0, [int] $c.maxReboots))
    $c.maxAttemptsPerOperation = [int] [Math]::Min(5, [Math]::Max(1, [int] $c.maxAttemptsPerOperation))
    $c.maxNetworkDeferrals = [int] [Math]::Min(24, [Math]::Max(0, [int] $c.maxNetworkDeferrals))
    foreach ($k in 'verifiedPackages', 'approvals') { if (-not $c.ContainsKey($k) -or $null -eq $c[$k]) { $c[$k] = @() } else { $c[$k] = @($c[$k]) } }
    foreach ($k in 'bundle', 'expectedSystem') { if (-not $c.ContainsKey($k)) { $c[$k] = $null } }
    foreach ($p in @($c.verifiedPackages)) {
        if ([string] $p.id -notmatch '^[a-z0-9][a-z0-9-]{0,47}$') { throw "Verified package with an invalid id: $($p.id)" }
        if ([string] $p.sha256 -notmatch $script:WdvSha) { throw "Verified package $($p.id) has no valid SHA-256." }
        if (-not (Test-WdvDownloadUrl ([string] $p.url) @($c.sources.downloadHosts))) { throw "Verified package $($p.id) is not on an allowed official HTTPS host: $($p.url)" }
    }
    if ($c.bundle) {
        if ([string] $c.bundle.manifestSha256 -notmatch $script:WdvSha -or [string] $c.bundle.folderName -notmatch $script:WdvBundleFolder) { throw 'The driver configuration has an invalid offline bundle reference.' }
    }
    return $c
}

<# Downloads only over HTTPS from an allowed official host; no credentials, no query tricks. #>
function Test-WdvDownloadUrl {
    param([string] $Url, [string[]] $Hosts)
    $u = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref] $u)) { return $false }
    if ($u.Scheme -ne 'https' -or $u.UserInfo -or -not $u.IsDefaultPort) { return $false }
    return (@($Hosts | Where-Object { $_ -and $u.Host -ieq $_ }).Count -gt 0)
}

function Get-WdvPaths {
    param([hashtable] $Config)
    $root = Join-Path $Config.dataRoot 'Drivers'
    @{
        DataRoot   = $Config.dataRoot
        Root       = $root
        Logs       = Join-Path $root 'logs'
        Log        = Join-Path (Join-Path $root 'logs') 'engine.log'
        Attempts   = Join-Path (Join-Path $root 'logs') 'attempts.jsonl'
        State      = Join-Path $root 'state.json'
        Status     = Join-Path $root 'status.json'
        Result     = Join-Path $root 'result.json'
        Packages   = Join-Path $root 'packages'
        Downloads  = Join-Path $root 'downloads'
        Inventory  = $root
        Report     = Join-Path (Join-Path $Config.dataRoot 'reports') 'drivers.json'
        MarkerDir  = Join-Path $Config.dataRoot 'state'
        Marker     = Join-Path (Join-Path $Config.dataRoot 'state') 'drivers.done'
        NetworkFlag = Join-Path (Join-Path $Config.dataRoot 'state') 'network-driver-missing.json'
        DeploymentState = Join-Path (Join-Path $Config.dataRoot 'state') 'deployment.json'
    }
}

# ------------------------------------------------------------------------------------------------
# System adapters. Everything that reads devices, runs pnputil, downloads or restarts lives here.
# ------------------------------------------------------------------------------------------------

<# Present Plug and Play devices (CIM, no administrator rights needed). #>
function Get-WdvRawDevices {
    $out = @()
    foreach ($d in @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop)) {
        $present = $true
        try { if ($null -ne $d.Present) { $present = [bool] $d.Present } } catch { }
        $out += , @{
            InstanceId = [string] $d.PNPDeviceID; Name = [string] $d.Name; Class = [string] $d.PNPClass; ClassGuid = [string] $d.ClassGuid
            Manufacturer = [string] $d.Manufacturer; Status = [string] $d.Status; ProblemCode = $(if ($null -ne $d.ConfigManagerErrorCode) { [int] $d.ConfigManagerErrorCode } else { 0 })
            Present = $present; Service = [string] $d.Service; HardwareIds = @($d.HardwareID | Where-Object { $_ }); CompatibleIds = @($d.CompatibleID | Where-Object { $_ })
        }
    }
    return $out
}

<# Installed driver per device (Win32_PnPSignedDriver), keyed by instance id. #>
function Get-WdvSignedDrivers {
    $map = @{}
    foreach ($d in @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop)) {
        if (-not $d.DeviceID) { continue }
        $date = ''
        try { if ($d.DriverDate) { $date = ([DateTime] $d.DriverDate).ToString('yyyy-MM-dd') } } catch { }
        $map[([string] $d.DeviceID).ToUpperInvariant()] = @{ Provider = [string] $d.DriverProviderName; Version = [string] $d.DriverVersion; Date = $date; Inf = [string] $d.InfName; Signer = [string] $d.Signer; IsSigned = [bool] $d.IsSigned }
    }
    return $map
}

<# Parent device of each instance (DEVPKEY_Device_Parent), for storage controllers and hubs. #>
function Get-WdvDeviceParents {
    param([string[]] $InstanceIds)
    $map = @{}
    if (-not $InstanceIds -or -not (Get-Command Get-PnpDeviceProperty -ErrorAction SilentlyContinue)) { return $map }
    try {
        foreach ($p in @(Get-PnpDeviceProperty -InstanceId $InstanceIds -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue)) {
            if ($p.Data) { $map[([string] $p.InstanceId).ToUpperInvariant()] = [string] $p.Data }
        }
    } catch { }
    return $map
}

<# Computer identity for OEM decisions. Serial numbers and UUIDs are never read. #>
function Get-WdvSystem {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $bb = $null; $bios = $null; $cpu = $null; $enc = $null
    try { $bb = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1 } catch { }
    try { $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop | Select-Object -First 1 } catch { }
    try { $cpu = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop) } catch { $cpu = @() }
    try { $enc = Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop | Select-Object -First 1 } catch { }
    $arch = switch ([string] $env:PROCESSOR_ARCHITECTURE) { 'AMD64' { 'amd64' } 'ARM64' { 'arm64' } 'x86' { 'x86' } default { ([string] $env:PROCESSOR_ARCHITECTURE).ToLowerInvariant() } }
    @{
        Manufacturer = [string] $cs.Manufacturer; Model = [string] $cs.Model
        Family = $(try { [string] $cs.SystemFamily } catch { '' }); Sku = $(try { [string] $cs.SystemSKUNumber } catch { '' })
        PCSystemType = $(try { [int] $cs.PCSystemType } catch { 0 })
        BoardManufacturer = $(if ($bb) { [string] $bb.Manufacturer } else { '' }); BoardProduct = $(if ($bb) { [string] $bb.Product } else { '' })
        BiosVendor = $(if ($bios) { [string] $bios.Manufacturer } else { '' }); BiosVersion = $(if ($bios) { [string] $bios.SMBIOSBIOSVersion } else { '' })
        Processors = @($cpu | ForEach-Object { @{ Name = ([string] $_.Name).Trim(); Manufacturer = [string] $_.Manufacturer } })
        ChassisTypes = @(if ($enc -and $enc.ChassisTypes) { @($enc.ChassisTypes | ForEach-Object { [int] $_ }) })
        OsCaption = [string] $os.Caption; OsBuild = [string] $os.BuildNumber; OsVersion = [string] $os.Version; Architecture = $arch
    }
}

function Get-WdvBootTime { (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime.ToUniversalTime() }

function Test-WdvNetwork {
    try {
        # Network Connectivity Status Indicator probe documented by Microsoft.
        $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 10
        if ($r.Content -eq 'Microsoft Connect Test') { return $true }
    } catch { }
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $tcp.BeginConnect('www.msftconnecttest.com', 80, $null, $null)
        return ($iar.AsyncWaitHandle.WaitOne(5000) -and $tcp.Connected)
    } catch { return $false } finally { $tcp.Close() }
}

function Test-WdvSystemRebootPending {
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
                     'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        if (Test-Path -LiteralPath $key) { return $true }
    }
    return $false
}

<#
    Device installation restrictions set by an organization (Group Policy "Device Installation
    Restrictions"). When present, nothing is installed and the devices are reported instead.
#>
function Get-WdvDeviceInstallPolicy {
    $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
    if (-not (Test-Path -LiteralPath $key)) { return @{ Restricted = $false; Detail = '' } }
    $set = @()
    try {
        $v = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
        foreach ($n in 'DenyUnspecified', 'DenyDeviceIDs', 'DenyDeviceClasses', 'DenyInstanceIDs', 'AllowDeviceIDs', 'AllowDeviceClasses') {
            if ($v.PSObject.Properties[$n] -and $v.$n) { $set += $n }
        }
    } catch { }
    return @{ Restricted = ($set.Count -gt 0); Detail = ($set -join ', ') }
}

<# Third-party INF files published in the driver store (C:\Windows\INF\oem*.inf). #>
function Get-WdvDriverStoreInfs { @(Get-ChildItem -LiteralPath (Join-Path $env:SystemRoot 'INF') -Filter 'oem*.inf' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }

<#
    The only place pnputil.exe runs. Allowed verbs: /add-driver (install a verified INF package),
    /scan-devices (ask Windows to re-evaluate a device), /export-driver (copy driver-store packages
    out). Never /delete-driver, /remove-device, /disable-device or /force.
#>
function Invoke-WdvPnpUtil {
    param([string[]] $Arguments)
    if (@($Arguments).Count -eq 0 -or $Arguments[0] -notin '/add-driver', '/scan-devices', '/export-driver') { throw "pnputil verb not allowed: $($Arguments -join ' ')" }
    if (@($Arguments | Where-Object { $_ -match '^/(force|delete|remove|disable|uninstall|reboot)' }).Count) { throw "pnputil option not allowed: $($Arguments -join ' ')" }
    $exe = Join-Path $env:SystemRoot 'System32\pnputil.exe'
    $out = & $exe @Arguments 2>&1
    return @{ ExitCode = $LASTEXITCODE; Output = (@($out | ForEach-Object { [string] $_ }) -join "`n") }
}

function Invoke-WdvDownload {
    param([string] $Url, [string] $Destination)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 600 -MaximumRedirection 3
}

function Expand-WdvCabinet {
    param([string] $Cabinet, [string] $Destination)
    $exe = Join-Path $env:SystemRoot 'System32\expand.exe'
    $out = & $exe -F:* $Cabinet $Destination 2>&1
    if ($LASTEXITCODE -ne 0) { throw "expand.exe returned $LASTEXITCODE`: $((@($out) | Select-Object -Last 2) -join ' ')" }
}

<# Authenticode signature of a catalog (.cat) or file: status and the signer's common name. #>
function Get-WdvSignature {
    param([string] $Path)
    $s = Get-AuthenticodeSignature -LiteralPath $Path
    $cn = ''
    if ($s.SignerCertificate) { if ($s.SignerCertificate.Subject -match 'CN=([^,]+)') { $cn = $Matches[1].Trim('"', ' ') } }
    @{ Status = [string] $s.Status; Signer = $cn }
}

<# Root folders of ready drives (where an offline bundle may be: <drive>\WindowsDeployment\drivers). #>
function Get-WdvReadyDriveRoots { @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -in 'Removable', 'Fixed' } | ForEach-Object { $_.RootDirectory.FullName }) }

function Invoke-WdvReboot {
    param([int] $WarningSeconds, [string] $Reason)
    # p:2:4 = planned, Operating System: Reconfiguration
    & "$env:SystemRoot\System32\shutdown.exe" /r /t $WarningSeconds /d p:2:4 /c "Windows Deployment Builder: $Reason. The computer restarts in $WarningSeconds seconds; driver setup resumes automatically."
    if ($LASTEXITCODE -ne 0) { throw "shutdown.exe failed with exit code $LASTEXITCODE" }
}

function Unregister-WdvTask {
    param([hashtable] $Config)
    try { Get-ScheduledTask -TaskName $Config.taskName -TaskPath $Config.taskPath -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false } catch { Write-WdvLog "Could not remove the scheduled task: $($_.Exception.Message)" 'WARN' }
}

function Test-WdvUpdateTask {
    param([hashtable] $WU)
    try { [void] (Get-ScheduledTask -TaskName $WU.taskName -TaskPath $WU.taskPath -ErrorAction Stop); return $true } catch { return $false }
}

# ------------------------------------------------------------------------------------------------
# Coordination with the Windows Update and application engines
# ------------------------------------------------------------------------------------------------
# Third copy of the shared region below; tests/unit/drivers.test.ts checks that it is identical
# to the copies in WindowsUpdateEngine.ps1 and ApplicationEngine.ps1.

# region WDB coordination
# Shared by WindowsUpdateEngine.ps1 and ApplicationEngine.ps1; both copies must stay identical
# (tests/unit/applications-engine.test.ts checks this).
#
# install.lock         Machine-wide installation lock: a file opened exclusively. Windows releases
#                      it when the owning process ends, so a crash can never leave a stale lock.
#                      Whoever installs something or restarts the computer holds it.
# restart-pending.json Written just before an engine schedules a restart. Valid only in the boot
#                      it was written in (and for 30 minutes), so it disappears with the restart.

function Get-WdbBootTime {
    try { return (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    catch { return 'unknown' }
}

function Wait-WdbLockPoll { Start-Sleep -Seconds 5 }

function Get-WdbCoordinationPaths {
    param([string] $DataRoot)
    $dir = Join-Path $DataRoot 'state'
    @{ Dir = $dir; Lock = (Join-Path $dir 'install.lock'); Restart = (Join-Path $dir 'restart-pending.json') }
}

function Enter-WdbInstallLock {
    param([string] $DataRoot, [string] $Owner, [int] $TimeoutSeconds = 0)
    $p = Get-WdbCoordinationPaths $DataRoot
    if (-not (Test-Path -LiteralPath $p.Dir)) { New-Item -ItemType Directory -Path $p.Dir -Force | Out-Null }
    $polls = [int] [Math]::Ceiling([Math]::Max(0, $TimeoutSeconds) / 5)
    for ($i = 0; ; $i++) {
        try {
            $fs = [System.IO.File]::Open($p.Lock, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes(('{{"owner":"{0}","pid":{1},"sinceUtc":"{2}"}}' -f $Owner, $PID, [DateTime]::UtcNow.ToString('o')))
            $fs.SetLength(0)
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush()
            return $fs
        } catch [System.IO.IOException] {
            if ($i -ge $polls) { return $null }
            Wait-WdbLockPoll
        }
    }
}

function Exit-WdbInstallLock {
    param($Lock)
    if ($Lock) { try { $Lock.Dispose() } catch { } }
}

function Get-WdbInstallLockOwner {
    param([string] $DataRoot)
    $p = Get-WdbCoordinationPaths $DataRoot
    try {
        $fs = [System.IO.File]::Open($p.Lock, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try { return (New-Object System.IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { return '' }
}

function Set-WdbRestartPending {
    param([string] $DataRoot, [string] $Owner, [string] $Reason)
    $p = Get-WdbCoordinationPaths $DataRoot
    if (-not (Test-Path -LiteralPath $p.Dir)) { New-Item -ItemType Directory -Path $p.Dir -Force | Out-Null }
    $o = [ordered]@{ owner = $Owner; reason = $Reason; requestedUtc = [DateTime]::UtcNow.ToString('o'); bootTimeUtc = (Get-WdbBootTime) }
    [System.IO.File]::WriteAllText($p.Restart, ($o | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}

function Test-WdbRestartPending {
    param([string] $DataRoot)
    $p = Get-WdbCoordinationPaths $DataRoot
    if (-not (Test-Path -LiteralPath $p.Restart)) { return $false }
    $m = $null
    try { $m = Get-Content -LiteralPath $p.Restart -Raw | ConvertFrom-Json } catch { }
    if ($m -and ([string] $m.bootTimeUtc) -eq (Get-WdbBootTime)) {
        $age = [DateTime]::UtcNow - [DateTime]::Parse([string] $m.requestedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        if ($age.TotalMinutes -lt 30) { return $true }
    }
    # Written before the last restart, unreadable or abandoned: the restart is no longer pending.
    Remove-Item -LiteralPath $p.Restart -Force -ErrorAction SilentlyContinue
    return $false
}

# endregion WDB coordination

# ------------------------------------------------------------------------------------------------
# INF driver packages
# ------------------------------------------------------------------------------------------------

# Plain relative paths only: no drive, no root, no "..", a conservative character set.
function Test-WdvRelPath {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 240) { return $false }
    if ($Path -notmatch '^[A-Za-z0-9._ ()+,#&~-]+([\\/][A-Za-z0-9._ ()+,#&~-]+)*$') { return $false }
    foreach ($seg in $Path -split '[\\/]') { if ($seg -eq '..' -or $seg -eq '.' -or $seg.Trim() -eq '' -or $seg -match '^(con|prn|aux|nul|com\d|lpt\d)(\..*)?$') { return $false } }
    return $true
}

<# Text of an INF file in its own encoding (UTF-16 with or without BOM, UTF-8 BOM, else ANSI). #>
function Read-WdvInfText {
    param([string] $Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2) }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3) }
    if ($bytes.Length -ge 4 -and $bytes[1] -eq 0 -and $bytes[3] -eq 0) { return [System.Text.Encoding]::Unicode.GetString($bytes) }
    return [System.Text.Encoding]::Default.GetString($bytes)
}

function ConvertFrom-WdvInfValue {
    param([string] $Value, [hashtable] $Strings)
    $v = $Value.Trim()
    $v = [regex]::Replace($v, '%([^%]+)%', { param($m) $k = $m.Groups[1].Value.ToLowerInvariant(); if ($Strings.ContainsKey($k)) { $Strings[$k] } else { $m.Value } })
    return $v.Trim().Trim('"').Trim()
}

<#
    Parses an INF (documented INF sections; nothing in it is executed): [Version] (Class, ClassGuid,
    Provider, DriverVer, CatalogFile[.<arch>]), [Strings], [Manufacturer] and the decorated models
    sections. TargetOSVersion decorations NT<arch>[.major[.minor[.product[.suite[.build]]]]] give the
    architectures and the minimum Windows build per models section. Returns the hardware and
    compatible IDs the package declares, upper case.
#>
function Read-WdvInf {
    param([string] $Path)
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -gt $script:WdvLimits.maxInfBytes) { throw "INF too large: $($item.Name)" }
    $sections = @{}
    $current = $null
    $pending = ''
    foreach ($raw in ((Read-WdvInfText $Path) -split "`r?`n")) {
        $line = $pending + $raw
        $pending = ''
        # Comments start at a ';' outside quotes.
        $sb = New-Object System.Text.StringBuilder
        $inQuote = $false
        foreach ($ch in $line.ToCharArray()) {
            if ($ch -eq '"') { $inQuote = -not $inQuote }
            if ($ch -eq ';' -and -not $inQuote) { break }
            [void] $sb.Append($ch)
        }
        $line = $sb.ToString().TrimEnd()
        if ($line.EndsWith('\')) { $pending = $line.Substring(0, $line.Length - 1); continue }
        $line = $line.Trim()
        if (-not $line) { continue }
        if ($line -match '^\[(.+)\]$') { $current = $Matches[1].Trim().ToLowerInvariant(); if (-not $sections.ContainsKey($current)) { $sections[$current] = New-Object System.Collections.Generic.List[string] }; continue }
        if ($null -ne $current) { $sections[$current].Add($line) }
    }
    $strings = @{}
    foreach ($k in @($sections.Keys | Where-Object { $_ -eq 'strings' -or $_ -like 'strings.*' } | Sort-Object { $_.Length })) {
        foreach ($l in $sections[$k]) { if ($l -match '^([^=]+?)\s*=\s*(.*)$' -and -not $strings.ContainsKey($Matches[1].Trim().ToLowerInvariant())) { $strings[$Matches[1].Trim().ToLowerInvariant()] = $Matches[2].Trim().Trim('"') } }
    }
    $version = @{}
    if ($sections.ContainsKey('version')) {
        foreach ($l in $sections['version']) { if ($l -match '^([^=]+?)\s*=\s*(.*)$') { $version[$Matches[1].Trim().ToLowerInvariant()] = ConvertFrom-WdvInfValue $Matches[2] $strings } }
    }
    $info = @{
        Path = $Path; File = $item.Name; Class = ''; ClassGuid = ''; Provider = ''; Version = ''; Date = ''; Catalogs = @{}
        Targets = @(); HardwareIds = @(); Problems = @()
    }
    if ($version.ContainsKey('class')) { $info.Class = $version['class'] }
    if ($version.ContainsKey('classguid')) { $info.ClassGuid = $version['classguid'].ToLowerInvariant() }
    if ($version.ContainsKey('provider')) { $info.Provider = $version['provider'] }
    if ($version.ContainsKey('driverver') -and $version['driverver'] -match '^\s*(\d{1,2})/(\d{1,2})/(\d{4})\s*(?:,\s*([0-9.]+))?') {
        $info.Date = '{0}-{1:D2}-{2:D2}' -f $Matches[3], [int] $Matches[1], [int] $Matches[2]
        if ($Matches[4]) { $info.Version = $Matches[4] }
    }
    foreach ($k in @($version.Keys | Where-Object { $_ -like 'catalogfile*' })) {
        $suffix = $k.Substring('catalogfile'.Length).TrimStart('.')
        $arch = switch -Regex ($suffix) { '^ntamd64' { 'amd64' } '^ntarm64' { 'arm64' } '^ntx86' { 'x86' } '^$|^nt$' { '*' } default { $suffix } }
        $info.Catalogs[$arch] = $version[$k]
    }
    if (-not $version.ContainsKey('signature') -or $version['signature'] -notmatch '^\$(windows nt|chicago)\$$') { $info.Problems += 'missing or unknown [Version] Signature' }
    $ids = New-Object System.Collections.Generic.HashSet[string]
    $targets = @()
    if ($sections.ContainsKey('manufacturer')) {
        foreach ($l in $sections['manufacturer']) {
            if ($l -notmatch '^([^=]+?)\s*=\s*(.+)$') { continue }
            $parts = @($Matches[2].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if (-not $parts.Count) { continue }
            $models = ConvertFrom-WdvInfValue $parts[0] $strings
            $decorations = @($parts | Select-Object -Skip 1)
            if (-not $decorations.Count) { $decorations = @('') }
            foreach ($d in $decorations) {
                $segs = $d.Split('.')
                $arch = switch -Regex ($segs[0].ToLowerInvariant()) { '^ntamd64$' { 'amd64' } '^ntarm64$' { 'arm64' } '^ntx86$' { 'x86' } '^nt$' { 'x86' } '^$' { 'x86' } default { $segs[0].ToLowerInvariant() } }
                $build = 0
                if ($segs.Count -ge 6 -and $segs[5] -match '^\d+$') { $build = [int] $segs[5] }
                $sectionName = $(if ($d) { "$models.$d" } else { $models }).ToLowerInvariant()
                $count = 0
                if ($sections.ContainsKey($sectionName)) {
                    foreach ($ml in $sections[$sectionName]) {
                        if ($ml -notmatch '^[^=]+=\s*(.+)$') { continue }
                        foreach ($idv in @($Matches[1].Split(',') | Select-Object -Skip 1)) {
                            $id = (ConvertFrom-WdvInfValue $idv $strings).ToUpperInvariant()
                            if ($id) { [void] $ids.Add($id); $count++ }
                        }
                    }
                }
                $targets += , @{ Arch = $arch; MinBuild = $build; Ids = $count }
            }
        }
    } else { $info.Problems += 'no [Manufacturer] section' }
    $info.Targets = $targets
    $info.HardwareIds = @($ids | Sort-Object)
    if ($info.HardwareIds.Count -gt $script:WdvLimits.maxHardwareIds) { $info.Problems += 'too many hardware IDs' }
    return $info
}

<# Lowest Windows build an INF supports on an architecture; -1 when it has no models section for it. #>
function Get-WdvInfMinBuild {
    param([hashtable] $Info, [string] $Arch, [int] $Build)
    $ok = @($Info.Targets | Where-Object { $_.Arch -eq $Arch -and $_.Ids -gt 0 })
    if (-not $ok.Count) { return -1 }
    $fit = @($ok | Where-Object { [int] $_.MinBuild -le $Build })
    if ($fit.Count) { return ([int] (@($fit | ForEach-Object { [int] $_.MinBuild }) | Measure-Object -Minimum).Minimum) }
    return ([int] (@($ok | ForEach-Object { [int] $_.MinBuild }) | Measure-Object -Minimum).Minimum)
}

function Get-WdvInfArchitectures { param([hashtable] $Info) @($Info.Targets | Where-Object { $_.Ids -gt 0 } | ForEach-Object { $_.Arch } | Select-Object -Unique) }

<#
    Catalog signature of one INF package: the catalog named by CatalogFile[.<arch>] must exist next
    to the INF, carry a valid Authenticode signature and be signed by Microsoft's hardware
    publisher (WHQL or attestation), which 64-bit Windows 11 requires for kernel drivers with
    Secure Boot. Windows itself checks that every file matches the catalog when the package is
    added, and refuses it otherwise.
#>
function Test-WdvCatalog {
    param([hashtable] $Info, [string] $Arch, [string[]] $WhqlSigners)
    $name = $(if ($Info.Catalogs.ContainsKey($Arch)) { $Info.Catalogs[$Arch] } elseif ($Info.Catalogs.ContainsKey('*')) { $Info.Catalogs['*'] } else { '' })
    if (-not $name) { return @{ Ok = $false; Status = 'NoCatalog'; Signer = ''; Whql = $false; Catalog = ''; Reason = 'the INF names no catalog file (unsigned package)' } }
    if (-not (Test-WdvRelPath $name)) { return @{ Ok = $false; Status = 'BadCatalog'; Signer = ''; Whql = $false; Catalog = $name; Reason = 'unsafe catalog file name' } }
    $cat = Join-Path (Split-Path -Parent $Info.Path) $name
    if (-not (Test-Path -LiteralPath $cat -PathType Leaf)) { return @{ Ok = $false; Status = 'NoCatalog'; Signer = ''; Whql = $false; Catalog = $name; Reason = "catalog $name is missing" } }
    $sig = Get-WdvSignature $cat
    $whql = @($WhqlSigners | Where-Object { $_ -and $sig.Signer -eq $_ }).Count -gt 0
    if ($sig.Status -ne 'Valid') { return @{ Ok = $false; Status = $sig.Status; Signer = $sig.Signer; Whql = $whql; Catalog = $name; Reason = "catalog signature is $($sig.Status)" } }
    if (-not $whql) { return @{ Ok = $false; Status = 'Valid'; Signer = $sig.Signer; Whql = $false; Catalog = $name; Reason = "signed by '$($sig.Signer)', not by Microsoft's hardware publisher (WHQL/attestation)" } }
    return @{ Ok = $true; Status = 'Valid'; Signer = $sig.Signer; Whql = $true; Catalog = $name; Reason = '' }
}

# Storage controllers Windows Setup may need before it can see the disk.
$script:WdvSetupCriticalClasses = @('scsiadapter', 'hdc')

function Get-WdvPackageEntry {
    param([string] $InfPath, [string] $PackageRoot, [string] $RelFolder, [hashtable] $Sources)
    $info = Read-WdvInf $InfPath
    $archs = @(Get-WdvInfArchitectures $info)
    $sigArch = $(if ($archs -contains 'amd64') { 'amd64' } elseif ($archs.Count) { $archs[0] } else { '*' })
    $sig = Test-WdvCatalog $info $sigArch @($Sources.whqlSigners)
    $files = @()
    $bytes = [int64] 0
    foreach ($f in @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -File -Force)) {
        if ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Links are not allowed in driver packages: $($f.FullName)" }
        $rel = $f.FullName.Substring($PackageRoot.TrimEnd('\').Length + 1)
        if (-not (Test-WdvRelPath $rel)) { throw "Unsafe file name in driver package: $rel" }
        $files += , [ordered]@{ path = ($rel -replace '\\', '/'); size = [int64] $f.Length; sha256 = (Get-WdvFileHash $f.FullName) }
        $bytes += $f.Length
    }
    $targets = @($info.Targets | Where-Object { $_.Ids -gt 0 } | ForEach-Object { [ordered]@{ arch = $_.Arch; minBuild = [int] $_.MinBuild } })
    $e = [ordered]@{}
    $e.id = 'pkg-' + (Get-WdvShortHash ("$($info.File)|$($info.Version)|" + ((@($files | Where-Object { $_.path -ieq $info.File }) | ForEach-Object { $_.sha256 }) -join '')))
    $e.folder = $RelFolder
    $e.inf = ($InfPath.Substring($PackageRoot.TrimEnd('\').Length + 1) -replace '\\', '/')
    $e.class = $info.Class
    $e.classGuid = $info.ClassGuid
    $e.provider = $info.Provider
    $e.version = $info.Version
    $e.date = $info.Date
    $e.catalog = $sig.Catalog
    $e.targets = $targets
    $e.hardwareIds = @($info.HardwareIds)
    $e.signature = [ordered]@{ status = $sig.Status; signer = $sig.Signer; whql = [bool] $sig.Whql }
    $e.setupCritical = ($info.Class.ToLowerInvariant() -in $script:WdvSetupCriticalClasses)
    $e.networkDriver = ($info.Class -ieq 'Net')
    $e.files = $files
    $e.bytes = $bytes
    return @{ Entry = $e; Info = $info; Signature = $sig }
}

<#
    Builds an offline driver bundle from a folder of INF packages (one package per folder that holds
    an INF). Unsigned packages, packages without models and links are refused (listed with the
    reason), never included. Vendor EXE installers are not driver packages and are ignored.
#>
function New-WdvBundle {
    param([string] $Source, [string] $Destination, [string] $Kind, [hashtable] $Sources, [hashtable] $System)
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "Driver package folder not found: $Source" }
    $stamp = (Get-WdvNow).ToString('yyyyMMdd-HHmmss')
    $folderName = "WDB-Drivers-$stamp-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
    $target = Join-Path $Destination $folderName
    New-Item -ItemType Directory -Path (Join-Path $target 'packages') -Force | Out-Null
    $entries = @(); $refused = @(); $n = 0
    $infs = @(Get-ChildItem -LiteralPath $Source -Recurse -File -Filter '*.inf' -ErrorAction Stop | Where-Object { $_.Name -ne 'autorun.inf' } | Sort-Object FullName)
    if ($infs.Count -gt $script:WdvLimits.maxPackages) { throw "Too many INF files ($($infs.Count)); the limit is $($script:WdvLimits.maxPackages)." }
    $copied = @{}
    foreach ($inf in $infs) {
        $dir = $inf.DirectoryName
        try {
            $n++
            $folder = $(if ($copied.ContainsKey($dir)) { $copied[$dir] } else { 'packages/{0:D3}-{1}' -f $n, (($inf.BaseName -replace '[^A-Za-z0-9._-]', '_').ToLowerInvariant()) })
            $pe = Get-WdvPackageEntry $inf.FullName $dir $folder $Sources
            if ($pe.Info.Problems.Count) { $refused += , [ordered]@{ inf = $inf.Name; reason = ($pe.Info.Problems -join '; ') }; continue }
            if (-not @(Get-WdvInfArchitectures $pe.Info).Count) { $refused += , [ordered]@{ inf = $inf.Name; reason = 'declares no hardware' }; continue }
            if (-not $pe.Signature.Ok) { $refused += , [ordered]@{ inf = $inf.Name; reason = $pe.Signature.Reason }; continue }
            if (-not $copied.ContainsKey($dir)) {
                $dest = Join-Path $target ($folder -replace '/', '\')
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                foreach ($f in $pe.Entry.files) {
                    $to = Join-Path $dest ($f.path -replace '/', '\')
                    $toDir = Split-Path -Parent $to
                    if (-not (Test-Path -LiteralPath $toDir)) { New-Item -ItemType Directory -Path $toDir -Force | Out-Null }
                    Copy-Item -LiteralPath (Join-Path $dir ($f.path -replace '/', '\')) -Destination $to -Force
                    if ((Get-WdvFileHash $to) -ne $f.sha256) { throw "Copy of $($f.path) does not match its source." }
                }
                $copied[$dir] = $folder
            }
            $entries += , $pe.Entry
        } catch {
            $refused += , [ordered]@{ inf = $inf.Name; reason = $_.Exception.Message }
        }
    }
    $m = [ordered]@{}
    $m.format = $script:WdvBundleFormat
    $m.formatVersion = 1
    $m.bundleId = (Get-WdvShortHash "$folderName|$(($entries | ForEach-Object { $_.id }) -join ',')").Substring(0, 12) + '0000'
    $m.folderName = $folderName
    $m.createdUtc = (Get-WdvNow).ToString('o')
    $m.tool = [ordered]@{ name = 'DriverEngine.ps1'; version = $script:WdvVersion }
    $m.source = [ordered]@{ kind = $Kind; manufacturer = [string] $System.Manufacturer; model = [string] $System.Model; osBuild = [string] $System.OsBuild; architecture = [string] $System.Architecture }
    $m.packages = $entries
    $m.refused = $refused
    $m.totals = [ordered]@{ packages = $entries.Count; files = [int] (@($entries | ForEach-Object { @($_.files).Count }) | Measure-Object -Sum).Sum; bytes = [int64] (@($entries | ForEach-Object { [int64] $_.bytes }) | Measure-Object -Sum).Sum }
    $m.notice = 'INF driver packages only. Vendor applications and control panels are not part of a driver bundle; install them from their own installers if wanted.'
    $json = $m | ConvertTo-Json -Depth 8
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    [System.IO.File]::WriteAllBytes((Join-Path $target 'drivers-manifest.json'), $bytes)
    return @{ Folder = $target; FolderName = $folderName; Sha256 = (Get-WdvSha256 $bytes); Packages = $entries.Count; Refused = $refused }
}

<#
    Validates a bundle folder: manifest format, (optionally) its pinned SHA-256 and folder name,
    every package file (path, size, SHA-256), no unlisted files, the INF re-read and compared with
    the manifest, and the catalog signature checked again now. Returns the usable packages.
#>
function Test-WdvBundle {
    param([string] $Folder, [string] $ExpectedSha256, [string] $ExpectedFolderName, [hashtable] $Sources)
    $problems = @()
    $result = @{ Ok = $false; Problems = $problems; Manifest = $null; Packages = @(); Sha256 = ''; Folder = $Folder }
    $mPath = Join-Path $Folder 'drivers-manifest.json'
    if (-not (Test-Path -LiteralPath $mPath -PathType Leaf)) { $result.Problems = @('drivers-manifest.json is missing'); return $result }
    if ((Get-Item -LiteralPath $mPath).Length -gt 8MB) { $result.Problems = @('drivers-manifest.json is too large'); return $result }
    $bytes = [System.IO.File]::ReadAllBytes($mPath)
    $result.Sha256 = Get-WdvSha256 $bytes
    if ($ExpectedSha256 -and $result.Sha256 -ne $ExpectedSha256.ToUpperInvariant()) { $result.Problems = @("drivers-manifest.json is not the pinned bundle (SHA-256 $($result.Sha256))"); return $result }
    $m = $null
    try { $m = ConvertTo-WdvHashtable ([System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json) } catch { }
    if ($m -isnot [hashtable] -or $m.format -ne $script:WdvBundleFormat -or [int] $m.formatVersion -ne 1) { $result.Problems = @('not a driver bundle manifest (format/version)'); return $result }
    if ([string] $m.folderName -notmatch $script:WdvBundleFolder) { $result.Problems = @('invalid bundle folder name'); return $result }
    if ((Split-Path -Leaf $Folder) -ne $m.folderName) { $problems += "folder name $(Split-Path -Leaf $Folder) does not match the manifest ($($m.folderName))" }
    if ($ExpectedFolderName -and $m.folderName -ne $ExpectedFolderName) { $problems += "bundle $($m.folderName) is not the expected $ExpectedFolderName" }
    $result.Manifest = $m
    $listed = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    [void] $listed.Add('drivers-manifest.json')
    $usable = @()
    foreach ($p in @($m.packages)) {
        if ($p -isnot [hashtable] -or -not (Test-WdvRelPath ([string] $p.folder)) -or ([string] $p.folder) -notmatch '^packages/' -or -not (Test-WdvRelPath ([string] $p.inf))) { $problems += "package with an unsafe path: $($p.folder)"; continue }
        $root = Join-Path $Folder (([string] $p.folder) -replace '/', '\')
        $bad = $false
        foreach ($f in @($p.files)) {
            $rel = [string] $f.path
            if (-not (Test-WdvRelPath $rel) -or [string] $f.sha256 -notmatch $script:WdvSha) { $problems += "$($p.folder): unsafe or unhashed file $rel"; $bad = $true; continue }
            [void] $listed.Add((("$($p.folder)/$rel") -replace '\\', '/'))
            $fp = Join-Path $root ($rel -replace '/', '\')
            if (-not (Test-Path -LiteralPath $fp -PathType Leaf)) { $problems += "$($p.folder): missing $rel"; $bad = $true; continue }
            $fi = Get-Item -LiteralPath $fp -Force
            if ($fi.Attributes -band [IO.FileAttributes]::ReparsePoint) { $problems += "$($p.folder): $rel is a link"; $bad = $true; continue }
            if ([int64] $fi.Length -ne [int64] $f.size -or (Get-WdvFileHash $fp) -ne [string] $f.sha256) { $problems += "$($p.folder): $rel was modified"; $bad = $true }
        }
        if ($bad) { continue }
        $infPath = Join-Path $root (([string] $p.inf) -replace '/', '\')
        try {
            $info = Read-WdvInf $infPath
        } catch { $problems += "$($p.folder): INF unreadable ($($_.Exception.Message))"; continue }
        if ($info.Version -ne [string] $p.version -or $info.ClassGuid -ne ([string] $p.classGuid).ToLowerInvariant() -or @($info.HardwareIds).Count -ne @($p.hardwareIds).Count) { $problems += "$($p.folder): the INF does not match the manifest"; continue }
        $archs = @(Get-WdvInfArchitectures $info)
        $sigArch = $(if ($archs -contains 'amd64') { 'amd64' } elseif ($archs.Count) { $archs[0] } else { '*' })
        $sig = Test-WdvCatalog $info $sigArch @($Sources.whqlSigners)
        if (-not $sig.Ok) { $problems += "$($p.folder): $($sig.Reason)"; continue }
        $usable += , @{ Entry = $p; Root = $root; Inf = $infPath; Info = $info; Source = 'offlineBundle' }
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $Folder -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = ($f.FullName.Substring($Folder.TrimEnd('\').Length + 1)) -replace '\\', '/'
        if (-not $listed.Contains($rel)) { $problems += "unlisted file in the bundle: $rel" }
    }
    $result.Problems = $problems
    $result.Packages = $usable
    $result.Ok = ($problems.Count -eq 0 -and $usable.Count -eq @($m.packages).Count)
    return $result
}

# ------------------------------------------------------------------------------------------------
# Hardware inventory: identifiers, vendor, category
# ------------------------------------------------------------------------------------------------

function Find-WdvVendor {
    param([hashtable] $Ids, [hashtable] $Sources)
    $lists = @(@($Sources.componentVendors))
    $pick = {
        param([string] $Kind, [string] $Value)
        foreach ($v in $lists) { if (@($v[$Kind]) -contains $Value) { return @{ id = [string] $v.id; name = [string] $v.name; vendorId = $Value } } }
        return $null
    }
    if ($Ids.pci) { $r = & $pick 'pci' $Ids.pci.ven; if ($r) { return $r }; return @{ id = 'unknown'; name = "Unknown vendor (PCI VEN_$($Ids.pci.ven))"; vendorId = $Ids.pci.ven } }
    if ($Ids.hdaudio) { $r = & $pick 'pci' $Ids.hdaudio.ven; if ($r) { return $r }; return @{ id = 'unknown'; name = "Unknown vendor (codec VEN_$($Ids.hdaudio.ven))"; vendorId = $Ids.hdaudio.ven } }
    if ($Ids.usb) { $r = & $pick 'usb' $Ids.usb.vid; if ($r) { return $r }; return @{ id = 'unknown'; name = "Unknown vendor (USB VID_$($Ids.usb.vid))"; vendorId = $Ids.usb.vid } }
    if ($Ids.cpu) { $r = @($lists | Where-Object { $_.id -eq $Ids.cpu } | Select-Object -First 1); if ($r.Count) { return @{ id = [string] $r[0].id; name = [string] $r[0].name; vendorId = $Ids.cpu } } }
    if ($Ids.acpi) {
        foreach ($v in $lists) { foreach ($pre in @($v.acpi)) { if ($pre -and $Ids.acpi.id.StartsWith($pre)) { return @{ id = [string] $v.id; name = [string] $v.name; vendorId = $Ids.acpi.id } } } }
        if ($Ids.acpi.id -match '^PNP') { return @{ id = 'microsoft'; name = 'Standard (PNP)'; vendorId = $Ids.acpi.id } }
        return @{ id = 'unknown'; name = "Unknown vendor (ACPI $($Ids.acpi.id))"; vendorId = $Ids.acpi.id }
    }
    return @{ id = 'none'; name = ''; vendorId = '' }
}

<# Identifiers parsed from the hardware and compatible IDs (PCI, USB, HD Audio, ACPI). #>
function Get-WdvIds {
    param([string[]] $HardwareIds, [string[]] $CompatibleIds)
    $o = @{ pci = $null; usb = $null; hdaudio = $null; acpi = $null; cpu = ''; pciClass = ''; usbClass = ''; hidUsage = '' }
    foreach ($h in @($HardwareIds)) {
        $u = $h.ToUpperInvariant()
        # Processors: ACPI\GenuineIntel_-_Intel64_Family_... / ACPI\AuthenticAMD_-_AMD64_Family_...
        if (-not $o.cpu -and $u -match '^ACPI\\(GENUINEINTEL|AUTHENTICAMD)') { $o.cpu = $(if ($Matches[1] -eq 'GENUINEINTEL') { 'intel' } else { 'amd' }) }
        if (-not $o.pci -and $u -match '^PCI\\VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})(?:&SUBSYS_([0-9A-F]{8}))?(?:&REV_([0-9A-F]{2}))?') {
            $subsys = [string] $Matches[3]
            $o.pci = @{ ven = $Matches[1]; dev = $Matches[2]; subsys = $subsys; subsysVendor = $(if ($subsys) { $subsys.Substring(4, 4) } else { '' }); rev = [string] $Matches[4] }
        }
        if (-not $o.usb -and $u -match '^USB\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') { $o.usb = @{ vid = $Matches[1]; pid = $Matches[2] } }
        if (-not $o.usb -and $u -match '^HID\\VID_([0-9A-F]{4})&(?:UP_[0-9A-F]{4}_U_[0-9A-F]{4}&)?PID_([0-9A-F]{4})') { $o.usb = @{ vid = $Matches[1]; pid = $Matches[2] } }
        if (-not $o.hdaudio -and $u -match '^HDAUDIO\\FUNC_[0-9A-F]{2}&VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})') { $o.hdaudio = @{ ven = $Matches[1]; dev = $Matches[2] } }
        if (-not $o.acpi -and $u -match '^ACPI\\([A-Z]{3,4}[0-9A-F]{4})$') { $o.acpi = @{ id = $Matches[1] } }
    }
    foreach ($c in @($CompatibleIds) + @($HardwareIds)) {
        $u = ([string] $c).ToUpperInvariant()
        if (-not $o.pciClass -and $u -match '^PCI\\(?:VEN_[0-9A-F]{4}&)?(?:DEV_[0-9A-F]{4}&)?(?:REV_[0-9A-F]{2}&)?CC_([0-9A-F]{4,6})') { $o.pciClass = $Matches[1].Substring(0, 4) }
        if (-not $o.usbClass -and $u -match '^USB\\CLASS_([0-9A-F]{2})(?:&SUBCLASS_([0-9A-F]{2}))?(?:&PROT_([0-9A-F]{2}))?') { $o.usbClass = ($Matches[1] + $(if ($Matches[2]) { $Matches[2] } else { '' }) + $(if ($Matches[3]) { $Matches[3] } else { '' })) }
        if (-not $o.hidUsage -and $u -match '^HID_DEVICE_UP:([0-9A-F]{4})_U:([0-9A-F]{4})') { $o.hidUsage = "$($Matches[1]):$($Matches[2])" }
    }
    return $o
}

<# Hardware category from the setup class and the class codes in the identifiers (never the name). #>
function Get-WdvCategory {
    param([hashtable] $Device)
    $class = ([string] $Device.class).ToLowerInvariant()
    $ids = $Device.ids
    $cc = [string] $ids.pciClass
    $hid = [string] $ids.hidUsage
    if ($class -eq 'processor') { return 'cpu' }
    if ($class -eq 'display' -or $cc -like '03*') { return 'display' }
    if ($class -eq 'net' -or $cc -like '02*') {
        if ($cc -eq '0280') { return 'networkWireless' }
        if ($cc -eq '0200') { return 'networkWired' }
        return 'network'
    }
    if ($class -eq 'bluetooth' -or $ids.usbClass -like 'E00101*') { return 'bluetooth' }
    if ($class -in 'scsiadapter', 'hdc' -or $cc -like '01*') {
        switch ($cc) { '0108' { return 'storageNvme' } '0106' { return 'storageSata' } '0104' { return 'storageRaid' } default { return 'storage' } }
    }
    if ($cc -eq '0C03' -or ($class -eq 'usb' -and -not $ids.usb)) { return 'usb' }
    if ($class -eq 'media' -or $cc -like '04*' -or $ids.hdaudio) { return 'audio' }
    if ($class -in 'camera', 'image' -or $ids.usbClass -like '0E*') { return 'camera' }
    if ($class -eq 'biometric') { return 'biometric' }
    if ($hid -eq '000D:0005' -or ($ids.acpi -and $ids.acpi.id -match '^PNP0F')) { return 'touchpad' }
    if ($hid -eq '000D:0004') { return 'touchscreen' }
    if ($class -in 'hidclass', 'mouse', 'keyboard') { return 'input' }
    if ($class -eq 'firmware') { return 'firmware' }
    if ($class -eq 'securitydevices') { return 'security' }
    if ($class -eq 'monitor') { return 'monitor' }
    if ($class -eq 'system' -or $cc -like '06*' -or ($cc -in '0C05', '0780', '1180', '0880') -or ($ids.acpi -and ($Device.vendor.id -in 'intel', 'amd'))) { return 'chipset' }
    if (-not $class -or $class -eq 'unknown' -or $Device.classGuid -eq '{4d36e97e-e325-11ce-bfc1-08002be10318}') { return 'unknown' }
    return 'other'
}

<# Instance id with its instance-specific part (it may be a serial number) replaced by a hash. #>
function Get-WdvPublicInstanceId {
    param([string] $InstanceId)
    $parts = $InstanceId.Split('\')
    if ($parts.Count -lt 3) { return $InstanceId }
    return ('{0}\{1}\#{2}' -f $parts[0], $parts[1], (Get-WdvShortHash $InstanceId).Substring(0, 8))
}

function Get-WdvSystemContext {
    param([hashtable] $System, [hashtable] $Sources)
    $man = ([string] $System.Manufacturer).Trim()
    $oem = $null
    foreach ($o in @($Sources.systemManufacturers)) { if ($man -match "(?i)$($o.match)") { $oem = $o; break } }
    $virtual = $false
    foreach ($v in @($Sources.virtualPlatforms)) { if ("$man $($System.Model)" -match "(?i)$v") { $virtual = $true } }
    $portableTypes = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $portable = ([int] $System.PCSystemType -eq 2) -or (@($System.ChassisTypes | Where-Object { $_ -in $portableTypes }).Count -gt 0)
    $cpuVendor = ''
    foreach ($p in @($System.Processors)) { if ($p.Manufacturer -match '(?i)intel') { $cpuVendor = 'intel' } elseif ($p.Manufacturer -match '(?i)amd|advanced micro') { $cpuVendor = 'amd' } elseif ($p.Manufacturer -match '(?i)qualcomm') { $cpuVendor = 'qualcomm' } }
    @{
        Manufacturer = $man; Model = [string] $System.Model; Oem = $oem; OemSubsystemVendor = $(if ($oem) { [string] $oem.pciSubsystemVendor } else { '' })
        Virtual = $virtual; Portable = $portable; Architecture = [string] $System.Architecture; OsBuild = [int] ("0" + ($System.OsBuild -replace '\D', '')); CpuVendor = $cpuVendor
    }
}

<# One normalized device record (identity, driver, ids) from the raw CIM data. #>
function ConvertTo-WdvDevice {
    param([hashtable] $Raw, [hashtable] $Drivers, [hashtable] $Parents, [hashtable] $Context, [hashtable] $Sources)
    $iid = [string] $Raw.InstanceId
    $enum = $iid.Split('\')[0].ToUpperInvariant()
    $drv = $(if ($Drivers.ContainsKey($iid.ToUpperInvariant())) { $Drivers[$iid.ToUpperInvariant()] } else { $null })
    $driver = $null
    if ($drv -and ($drv.Inf -or $drv.Provider)) {
        $driver = @{ provider = [string] $drv.Provider; version = [string] $drv.Version; date = [string] $drv.Date; inf = [string] $drv.Inf; signer = [string] $drv.Signer; signed = [bool] $drv.IsSigned
                     inbox = -not (([string] $drv.Inf) -match '^oem\d+\.inf$') }
    }
    $ids = Get-WdvIds @($Raw.HardwareIds) @($Raw.CompatibleIds)
    $d = @{
        key = 'dev-' + (Get-WdvShortHash $iid); instanceId = $iid; publicInstanceId = (Get-WdvPublicInstanceId $iid)
        name = [string] $Raw.Name; class = [string] $Raw.Class; classGuid = ([string] $Raw.ClassGuid).ToLowerInvariant(); manufacturer = [string] $Raw.Manufacturer
        enumerator = $enum; physical = ($enum -notin $script:WdvVirtualEnumerators -and $enum -notmatch '^\{' -and $enum -ne 'ACPI_HAL')
        problemCode = [int] $Raw.ProblemCode; status = [string] $Raw.Status; enabled = ([int] $Raw.ProblemCode -ne 22)
        hardwareIds = @($Raw.HardwareIds | ForEach-Object { ([string] $_).ToUpperInvariant() }); compatibleIds = @($Raw.CompatibleIds | ForEach-Object { ([string] $_).ToUpperInvariant() })
        ids = $ids; driver = $driver; parent = $(if ($Parents.ContainsKey($iid.ToUpperInvariant())) { $Parents[$iid.ToUpperInvariant()] } else { '' })
        vendor = $null; category = ''; oemCustomized = $false; hostsSystemDisk = $false
    }
    $d.vendor = Find-WdvVendor $ids $Sources
    $d.category = Get-WdvCategory $d
    if ($ids.pci -and $ids.pci.subsysVendor -and $ids.pci.subsysVendor -ne $ids.pci.ven -and $ids.pci.subsysVendor -ne '0000') {
        $oemVendors = @(@($Sources.systemManufacturers) | ForEach-Object { [string] $_.pciSubsystemVendor })
        $d.oemCustomized = ($ids.pci.subsysVendor -eq $Context.OemSubsystemVendor) -or ($oemVendors -contains $ids.pci.subsysVendor)
    }
    return $d
}

<#
    Assessment of one device from its actual state (problem code, driver, class), never from the
    vendor or the newest version. States: Healthy, BasicDriver, DriverMissing, Malfunctioning,
    DisabledIntentionally, RestartPending, HardwareIssue, Unsupported, NotPhysical. Actions: Keep,
    InstallRequired, InstallRecommended, RestartRequired, ReviewRequired, None.
#>
function Get-WdvAssessment {
    param([hashtable] $Device, [hashtable] $Sources)
    $a = @{ state = 'Healthy'; action = 'Keep'; confidence = 'high'; reasons = @(); setupCritical = $false; networkCritical = $false; problem = '' }
    $code = [int] $Device.problemCode
    if ($code -ne 0) { $a.problem = $(if ($script:WdvProblemNames.ContainsKey($code)) { "Code $code ($($script:WdvProblemNames[$code]))" } else { "Code $code" }) }
    $a.networkCritical = $Device.category -in 'networkWired', 'networkWireless', 'network'
    $a.setupCritical = ($Device.category -like 'storage*') -and $Device.driver -and -not $Device.driver.inbox -and $Device.hostsSystemDisk
    if (-not $Device.physical) {
        $a.state = 'NotPhysical'; $a.action = 'None'
        if ($code -ne 0 -and $code -ne 22) { $a.action = 'ReviewRequired'; $a.confidence = 'low'; $a.reasons += "Software device with $($a.problem); not a hardware driver question." }
        return $a
    }
    if (@($Device.hardwareIds).Count -eq 0 -and @($Device.compatibleIds).Count -eq 0) {
        $a.state = 'Unsupported'; $a.action = 'ReviewRequired'; $a.confidence = 'low'
        $a.reasons += 'Windows reports no hardware or compatible ID, so no driver can be matched to it.'
        return $a
    }
    switch ($code) {
        0 {
            $basic = $null
            if ($Device.driver) { foreach ($b in @($Sources.basicDrivers)) { if ($Device.driver.inf -ieq $b.inf -and (@($b.classes) -contains $Device.class)) { $basic = $b } } }
            if ($basic) {
                $a.state = 'BasicDriver'; $a.action = 'InstallRecommended'
                $a.reasons += "Working, but with $($basic.meaning). A driver for this $($Device.vendor.name) device is recommended."
            } elseif (-not $Device.driver) {
                $a.reasons += 'Working; Windows reports no separate driver for it.'
            } else {
                $src = $(if ($Device.driver.inbox) { "Windows' own driver ($($Device.driver.inf))" } else { "$($Device.driver.provider) $($Device.driver.version)" })
                $a.reasons += "Working with $src; kept."
            }
        }
        22 { $a.state = 'DisabledIntentionally'; $a.action = 'None'; $a.reasons += 'Disabled in Device Manager; left as it is.' }
        14 { $a.state = 'RestartPending'; $a.action = 'RestartRequired'; $a.reasons += 'A driver was installed; the device starts after a restart.' }
        { $_ -in 28, 1 -and -not $Device.driver } {
            $a.state = 'DriverMissing'
            $a.action = $(if ($Device.category -in 'networkWired', 'networkWireless', 'network', 'display', 'storage', 'storageNvme', 'storageSata', 'storageRaid', 'chipset', 'usb') { 'InstallRequired' } else { 'InstallRecommended' })
            $a.reasons += "No driver is installed ($($a.problem))."
        }
        52 { $a.state = 'Malfunctioning'; $a.action = 'ReviewRequired'; $a.reasons += "Windows blocked the driver: $($a.problem). This is a signature problem; nothing unsigned is ever installed." }
        48 { $a.state = 'Malfunctioning'; $a.action = 'ReviewRequired'; $a.reasons += "Windows blocked a driver with known problems ($($a.problem)); a compatible newer driver from the manufacturer is needed." }
        default {
            if ($code -in $script:WdvDriverProblems) {
                $a.state = 'Malfunctioning'; $a.action = 'InstallRecommended'; $a.confidence = 'medium'
                $a.reasons += "The driver is not working ($($a.problem)); a different compatible driver may fix it."
            } elseif ($code -in $script:WdvHardwareProblems) {
                $a.state = 'HardwareIssue'; $a.action = 'ReviewRequired'; $a.confidence = 'medium'
                $a.reasons += "$($a.problem): usually hardware, firmware or resources rather than the driver, so no driver is installed automatically."
            } else {
                $a.state = 'Malfunctioning'; $a.action = 'ReviewRequired'; $a.confidence = 'low'
                $a.reasons += "Unusual state $($a.problem); needs a technician."
            }
        }
    }
    if ($Device.vendor.id -eq 'unknown') { $a.reasons += "$($Device.vendor.name): shown with its identifiers; no vendor is assumed." }
    return $a
}

function Compare-WdvVersion {
    param([string] $A, [string] $B)
    $va = $null; $vb = $null
    if ([Version]::TryParse(($A -replace '[^0-9.]', ''), [ref] $va) -and [Version]::TryParse(($B -replace '[^0-9.]', ''), [ref] $vb)) { return $va.CompareTo($vb) }
    return [string]::Compare($A, $B, [StringComparison]::OrdinalIgnoreCase)
}

$script:WdvSourceRank = @{ driverStore = 0; offlineBundle = 1; technician = 2; verifiedDownload = 3 }

<#
    Whether a package may be installed automatically for a device, and how well it matches. The
    device's own hardware IDs come first (most specific first, as Windows orders them), compatible
    IDs after; a match on a generic class ID only is uncertain and never automatic. Class,
    architecture, Windows build, signature and OEM subsystem rules refuse unsafe candidates.
#>
function Test-WdvCandidate {
    param([hashtable] $Device, [hashtable] $Package, [hashtable] $Context, [hashtable] $Assessment)
    $r = @{ Eligible = $false; Optional = $false; Match = ''; MatchedId = ''; Position = -1; Subsystem = $false; Refusal = ''; RefusalClass = ''; Notes = @(); Score = 0 }
    $info = $Package.Info
    $ids = @($info.HardwareIds)
    for ($i = 0; $i -lt @($Device.hardwareIds).Count; $i++) { if ($ids -contains $Device.hardwareIds[$i]) { $r.Match = 'hardwareId'; $r.MatchedId = $Device.hardwareIds[$i]; $r.Position = $i; break } }
    if (-not $r.Match) { for ($j = 0; $j -lt @($Device.compatibleIds).Count; $j++) { if ($ids -contains $Device.compatibleIds[$j]) { $r.Match = 'compatibleId'; $r.MatchedId = $Device.compatibleIds[$j]; $r.Position = $j; break } } }
    if (-not $r.Match) { $r.Refusal = 'no matching hardware or compatible ID'; $r.RefusalClass = 'NoMatch'; return $r }
    $r.Subsystem = $r.MatchedId -match '&SUBSYS_'
    $refuse = { param([string] $Why, [string] $Class) $r.Refusal = $Why; $r.RefusalClass = $Class; return $r }
    if ($info.Class -ieq 'Extension') { return (& $refuse 'extension INF: Windows applies it together with the base driver' 'Incompatible') }
    $minBuild = Get-WdvInfMinBuild $info $Context.Architecture $Context.OsBuild
    if ($minBuild -lt 0) { return (& $refuse "the package has no driver for $($Context.Architecture)" 'Incompatible') }
    if ($minBuild -gt $Context.OsBuild) { return (& $refuse "the package requires Windows build $minBuild or later (this is $($Context.OsBuild))" 'Incompatible') }
    $other = '{4d36e97e-e325-11ce-bfc1-08002be10318}'
    if ($Device.classGuid -and $Device.classGuid -ne $other -and $info.ClassGuid -and $Device.classGuid -ne $info.ClassGuid) { return (& $refuse "device class $($Device.class) does not match the package class $($info.Class)" 'Incompatible') }
    if ($r.Match -eq 'compatibleId' -and ($r.MatchedId -match '^(PCI\\(VEN_[0-9A-F]{4}&)?CC_|USB\\CLASS_|HID_DEVICE|ACPI\\PNP|\*)' -or $r.MatchedId -notmatch '(VEN_|VID_|^ACPI\\[A-Z]{3,4}[0-9A-F]{4}$)')) {
        return (& $refuse "only the generic ID $($r.MatchedId) matches; the match is uncertain" 'Uncertain')
    }
    if ((-not $Device.classGuid -or $Device.classGuid -eq $other) -and $r.Match -ne 'hardwareId') { return (& $refuse 'the device class is unknown and only a compatible ID matches' 'Uncertain') }
    if ($Package.Source -ne 'driverStore') {
        $sigOk = $Package.ContainsKey('Signature') -and $Package.Signature -and $Package.Signature.Ok
        if (-not $sigOk) { return (& $refuse $(if ($Package.ContainsKey('Signature') -and $Package.Signature) { $Package.Signature.Reason } else { 'signature not verified' }) 'Signature') }
    }
    $healthy = $Assessment.state -eq 'Healthy'
    if ($Device.oemCustomized -and -not $r.Subsystem) {
        if ($healthy -or ($Device.driver -and -not $Device.driver.inbox -and $Assessment.state -ne 'Malfunctioning')) { return (& $refuse "the device is OEM-customized (subsystem $($Device.ids.pci.subsys)) and works with its OEM driver; a generic component package does not replace it" 'Incompatible') }
        $r.Notes += "Generic $($Device.vendor.name) package for an OEM-customized device (subsystem $($Device.ids.pci.subsys)); the manufacturer's package is preferred when available."
    }
    if ($Device.driver -and $Device.driver.version -and $info.Version) {
        $cmp = Compare-WdvVersion $info.Version $Device.driver.version
        $sameProvider = $Device.driver.provider -ieq $info.Provider
        if ($healthy) {
            if ($cmp -le 0 -or ($Device.driver.inbox -and $Device.category -ne 'display')) { return (& $refuse $(if ($cmp -le 0) { "not newer than the installed $($Device.driver.version)" } else { "Windows' working driver is kept" }) 'NotNeeded') }
            $r.Optional = $true
        } elseif ($Assessment.state -eq 'Malfunctioning') {
            if ($cmp -lt 0 -and -not $Device.driver.inbox) { return (& $refuse "older than the installed $($Device.driver.version) (would be a downgrade)" 'Incompatible') }
            if ($cmp -eq 0 -and $sameProvider) { return (& $refuse 'this is the driver that is already installed and not working' 'NoEffect') }
        }
    }
    $rank = $(if ($script:WdvSourceRank.ContainsKey($Package.Source)) { $script:WdvSourceRank[$Package.Source] } else { 9 })
    $r.Score = $(if ($r.Match -eq 'hardwareId') { 0 } else { 0x10000 }) + ($r.Position * 0x100) + ($rank * 0x10)
    $r.Eligible = $true
    return $r
}

# ------------------------------------------------------------------------------------------------
# Inventory
# ------------------------------------------------------------------------------------------------

<# One device's current state (for verification right after an installation). #>
function Get-WdvDeviceState {
    param([string] $InstanceId)
    $id = $InstanceId.Replace('\', '\\').Replace("'", "\'")
    $d = Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPDeviceID='$id'" -ErrorAction Stop | Select-Object -First 1
    if (-not $d) { return $null }
    $s = Get-CimInstance -ClassName Win32_PnPSignedDriver -Filter "DeviceID='$id'" -ErrorAction SilentlyContinue | Select-Object -First 1
    $date = ''
    try { if ($s -and $s.DriverDate) { $date = ([DateTime] $s.DriverDate).ToString('yyyy-MM-dd') } } catch { }
    @{
        ProblemCode = $(if ($null -ne $d.ConfigManagerErrorCode) { [int] $d.ConfigManagerErrorCode } else { 0 })
        Driver = $(if ($s -and ($s.InfName -or $s.DriverProviderName)) { @{ provider = [string] $s.DriverProviderName; version = [string] $s.DriverVersion; date = $date; inf = [string] $s.InfName; signer = [string] $s.Signer; signed = [bool] $s.IsSigned; inbox = -not (([string] $s.InfName) -match '^oem\d+\.inf$') } } else { $null })
    }
}

<#
    Complete inventory: present devices, their drivers and parents, the computer, and the
    assessment of every device. Devices that are not present (remembered by Windows only) are
    left out; software devices are kept but never acted on.
#>
function Get-WdvInventory {
    param([hashtable] $Sources, [string] $Label)
    $raw = @(Get-WdvRawDevices | Where-Object { $_.Present -and $_.InstanceId })
    $drivers = Get-WdvSignedDrivers
    $system = Get-WdvSystem
    $context = Get-WdvSystemContext $system $Sources
    $parents = Get-WdvDeviceParents @($raw | ForEach-Object { $_.InstanceId })
    $devices = @()
    foreach ($r in $raw) { $devices += , (ConvertTo-WdvDevice $r $drivers $parents $context $Sources) }
    # Storage controllers that have a disk below them (Windows Setup may need their driver).
    $byId = @{}
    foreach ($d in $devices) { $byId[$d.instanceId.ToUpperInvariant()] = $d }
    foreach ($disk in @($devices | Where-Object { $_.class -ieq 'DiskDrive' })) {
        $p = $disk.parent
        for ($i = 0; $i -lt 8 -and $p; $i++) {
            $pd = $(if ($byId.ContainsKey($p.ToUpperInvariant())) { $byId[$p.ToUpperInvariant()] } else { $null })
            if (-not $pd) { break }
            if ($pd.category -like 'storage*') { $pd.hostsSystemDisk = $true; break }
            $p = $pd.parent
        }
    }
    foreach ($d in $devices) { $d.assessment = Get-WdvAssessment $d $Sources }
    $boot = $null
    try { $boot = (Get-WdvBootTime).ToString('o') } catch { }
    return @{ Label = $Label; CollectedUtc = (Get-WdvNow).ToString('o'); BootUtc = $boot; System = $system; Context = $context; Devices = $devices }
}

function Get-WdvCounts {
    param([object[]] $Devices)
    $c = [ordered]@{ devices = 0; healthy = 0; basicDriver = 0; driverMissing = 0; malfunctioning = 0; disabled = 0; restartPending = 0; hardwareIssue = 0; unsupported = 0; needingAction = 0 }
    foreach ($d in @($Devices | Where-Object { $_.physical })) {
        $c.devices++
        switch ($d.assessment.state) {
            'Healthy' { $c.healthy++ } 'BasicDriver' { $c.basicDriver++ } 'DriverMissing' { $c.driverMissing++ } 'Malfunctioning' { $c.malfunctioning++ }
            'DisabledIntentionally' { $c.disabled++ } 'RestartPending' { $c.restartPending++ } 'HardwareIssue' { $c.hardwareIssue++ } 'Unsupported' { $c.unsupported++ }
        }
        if ($d.assessment.action -notin 'Keep', 'None') { $c.needingAction++ }
    }
    return $c
}

<# The shareable record of a device: no raw instance id, at most 8 identifiers of each kind. #>
function ConvertTo-WdvPublicDevice {
    param([hashtable] $Device)
    $o = [ordered]@{}
    $o.key = $Device.key
    $o.name = $Device.name
    $o.category = $Device.category
    $o.class = $Device.class
    $o.vendor = [ordered]@{ id = $Device.vendor.id; name = $Device.vendor.name; vendorId = $Device.vendor.vendorId }
    $o.instanceId = $Device.publicInstanceId
    $o.hardwareIds = @($Device.hardwareIds | Select-Object -First 8)
    $o.compatibleIds = @($Device.compatibleIds | Select-Object -First 8)
    $o.problemCode = $Device.problemCode
    $o.driver = $(if ($Device.driver) { [ordered]@{ provider = $Device.driver.provider; version = $Device.driver.version; date = $Device.driver.date; inf = $Device.driver.inf; inbox = [bool] $Device.driver.inbox } } else { $null })
    $o.oemCustomized = [bool] $Device.oemCustomized
    $o.state = $Device.assessment.state
    $o.action = $Device.assessment.action
    $o.confidence = $Device.assessment.confidence
    $o.reasons = @($Device.assessment.reasons)
    $o.setupCritical = [bool] $Device.assessment.setupCritical
    $o.networkCritical = [bool] $Device.assessment.networkCritical
    return $o
}

<# Vendor applications that relate to the hardware found. Recommendations only: never installed. #>
function Get-WdvOptionalApplications {
    param([object[]] $Devices, [hashtable] $Context, [hashtable] $Sources)
    $out = @()
    $seen = @{}
    $vendors = @($Devices | Where-Object { $_.physical -and $_.category -in 'display', 'networkWired', 'networkWireless', 'network', 'audio', 'chipset', 'bluetooth' } | ForEach-Object { $_.vendor.id } | Select-Object -Unique)
    foreach ($v in @($Sources.componentVendors)) {
        if ($vendors -notcontains $v.id) { continue }
        foreach ($a in @($v.optionalApplications)) { if (-not $seen.ContainsKey($a.name)) { $seen[$a.name] = $true; $out += , [ordered]@{ name = $a.name; vendor = $v.name; purpose = $a.purpose; required = $false; installed = 'not by the driver stage (the application profile decides)' } } }
    }
    if ($Context.Oem) { foreach ($a in @($Context.Oem.optionalApplications)) { if (-not $seen.ContainsKey($a.name)) { $seen[$a.name] = $true; $out += , [ordered]@{ name = $a.name; vendor = $Context.Oem.name; purpose = $a.purpose; required = $false; installed = 'not by the driver stage (the application profile decides)' } } } }
    return $out
}

function Save-WdvInventory {
    param([hashtable] $Inventory, [string] $Path)
    $o = [ordered]@{}
    $o.label = $Inventory.Label
    $o.collectedUtc = $Inventory.CollectedUtc
    $o.bootUtc = $Inventory.BootUtc
    $o.counts = Get-WdvCounts $Inventory.Devices
    $o.devices = @($Inventory.Devices | Where-Object { $_.physical -or $_.assessment.action -ne 'None' } | ForEach-Object { ConvertTo-WdvPublicDevice $_ })
    Write-WdvJson $Path $o
}

# ------------------------------------------------------------------------------------------------
# State and operations
# ------------------------------------------------------------------------------------------------

function New-WdvState {
    @{
        schemaVersion = $script:WdvStateVersion; engineVersion = $script:WdvVersion; firstStartUtc = $null; starts = 0; reboots = 0
        phase = 'New'; final = $null; passes = 0
        network = @{ status = 'Unknown'; detail = ''; devices = @(); checkedUtc = $null }
        bundle = @{ status = 'NotConfigured'; folder = ''; detail = ''; packages = 0; checkedUtc = $null }
        technicianPackages = @(); inspections = @{}; devices = @{}; operations = @{}
        policy = @{ restricted = $false; detail = '' }; gate = @{ open = $false; reason = ''; atUtc = $null }; rebootRequests = @()
        context = $null; errors = 0
    }
}

function Read-WdvState {
    param([hashtable] $Paths)
    foreach ($candidate in @($Paths.State, "$($Paths.State).bak")) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        $s = Read-WdvJson $candidate
        if ($s -is [hashtable] -and [int] $s.schemaVersion -ge 1 -and [int] $s.schemaVersion -le $script:WdvStateVersion -and $s.operations -is [hashtable]) {
            if ($candidate -ne $Paths.State) { Write-WdvLog 'Driver state recovered from its last good copy (state.json.bak).' 'WARN' }
            # Every key of a new state exists (Windows PowerShell's strict mode refuses missing keys).
            $fresh = New-WdvState
            foreach ($k in @($fresh.Keys)) { if (-not $s.ContainsKey($k)) { $s[$k] = $fresh[$k] } }
            foreach ($k in 'devices', 'inspections') { if ($s[$k] -isnot [hashtable]) { $s[$k] = @{} } }
            foreach ($k in 'technicianPackages', 'rebootRequests') { if ($null -eq $s[$k]) { $s[$k] = @() } else { $s[$k] = @($s[$k]) } }
            return $s
        }
        Write-WdvLog "Driver state file $(Split-Path -Leaf $candidate) is damaged; ignored." 'WARN'
    }
    return (New-WdvState)
}

function Save-WdvState { param([hashtable] $Paths, [hashtable] $State) Write-WdvJson $Paths.State $State -Backup }

function Get-WdvOperationList { param([hashtable] $State) @(@($State.operations.Values) | Where-Object { $_ -is [hashtable] } | Sort-Object { [string] $_.operationId }) }

function New-WdvOperation {
    param([hashtable] $Device, [string] $Status, [string] $Reason)
    $now = (Get-WdvNow).ToString('o')
    @{
        operationId = "driver:$($Device.key)"; deviceKey = $Device.key; name = $(if ($Device.name) { $Device.name } else { $Device.publicInstanceId }); category = $Device.category
        hardwareId = $(if (@($Device.hardwareIds).Count) { $Device.hardwareIds[0] } else { '' }); instanceId = $Device.instanceId; publicInstanceId = $Device.publicInstanceId
        status = $Status; reason = $Reason; source = ''; package = $null; candidates = @(); attempts = 0; totalAttempts = 0; networkDeferrals = 0
        failureClass = ''; retryable = $false; history = @(); previousDriver = $Device.driver; problemBefore = [int] $Device.problemCode; problemAfter = $null
        rebootRequired = $false; verification = 'NotVerified'; manualAction = $null; waitingFor = ''; nextAttemptUtc = $null; createdUtc = $now; updatedUtc = $now
        stateAtCreation = $Device.assessment.state
    }
}

function Set-WdvOperation {
    param([hashtable] $Op, [string] $Status, [string] $Reason = '', [string] $Class = $null)
    $Op.status = $Status
    if ($Reason) { $Op.reason = $Reason }
    if ($null -ne $Class) { $Op.failureClass = $Class }
    $Op.retryable = ($Status -eq 'FailedRetryable')
    $Op.updatedUtc = (Get-WdvNow).ToString('o')
}

<# One attempt in the operation's history (last 20) and in logs\attempts.jsonl. No secrets: ids, codes, messages. #>
function Add-WdvAttempt {
    param([hashtable] $Paths, [hashtable] $Op, [hashtable] $Record)
    $rec = [ordered]@{ operationId = $Op.operationId; name = $Op.name }
    foreach ($k in 'trigger', 'attempt', 'startUtc', 'endUtc', 'action', 'source', 'package', 'exitCode', 'result', 'class', 'problemBefore', 'problemAfter', 'rebootRequired', 'message') { if ($Record.ContainsKey($k)) { $rec[$k] = $Record[$k] } }
    $h = @{}
    foreach ($k in $rec.Keys) { if ($k -notin 'operationId', 'name') { $h[$k] = $rec[$k] } }
    $Op.history = @(@(@($Op.history) + @($h)) | Select-Object -Last 20)
    try { [System.IO.File]::AppendAllText($Paths.Attempts, (($rec | ConvertTo-Json -Compress -Depth 5) + "`r`n")) } catch { Write-WdvLog "Could not append to attempts.jsonl: $($_.Exception.Message)" 'WARN' }
}

# ------------------------------------------------------------------------------------------------
# Sources: offline bundle, technician packages, driver store, verified downloads
# ------------------------------------------------------------------------------------------------

<#
    Finds the pinned offline bundle on a ready drive (<drive>\WindowsDeployment\drivers\<folder>),
    validates it (pinned manifest SHA-256, every file, signatures) and copies it to the protected
    packages folder, where it is validated again. Only the listed files are copied.
#>
function Invoke-WdvBundleStaging {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State)
    $b = $Config.bundle
    if (-not $b -or -not $Config.policy.offlinePackages) { $State.bundle.status = 'NotConfigured'; return }
    $staged = Join-Path (Join-Path $Paths.Packages 'bundle') $b.folderName
    if ($State.bundle.status -eq 'Staged' -and (Test-Path -LiteralPath (Join-Path $staged 'drivers-manifest.json'))) { return }
    $State.bundle.checkedUtc = (Get-WdvNow).ToString('o')
    $found = $null; $problems = @()
    foreach ($root in @(Get-WdvReadyDriveRoots)) {
        $cand = Join-Path $root ("WindowsDeployment\drivers\$($b.folderName)")
        if (-not (Test-Path -LiteralPath $cand -PathType Container)) { continue }
        $v = Test-WdvBundle $cand $b.manifestSha256 $b.folderName $Config.sources
        if ($v.Ok) { $found = $v; break }
        $problems += "$cand`: $((@($v.Problems) | Select-Object -First 3) -join '; ')"
    }
    if (-not $found) {
        $State.bundle.status = $(if ($problems.Count) { 'Invalid' } else { 'NotFound' })
        $State.bundle.detail = $(if ($problems.Count) { "The offline driver bundle was found but is not the pinned one or was modified: $($problems -join ' | ')" } else { "The offline driver bundle $($b.folderName) is not on any drive (expected WindowsDeployment\drivers\$($b.folderName))." })
        Write-WdvLog $State.bundle.detail 'WARN'
        return
    }
    if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Recurse -Force }
    New-Item -ItemType Directory -Path $staged -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $found.Folder 'drivers-manifest.json') -Destination (Join-Path $staged 'drivers-manifest.json') -Force
    foreach ($p in @($found.Manifest.packages)) {
        foreach ($f in @($p.files)) {
            $rel = ("$($p.folder)/$($f.path)") -replace '/', '\'
            $to = Join-Path $staged $rel
            $dir = Split-Path -Parent $to
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Copy-Item -LiteralPath (Join-Path $found.Folder $rel) -Destination $to -Force
        }
    }
    $again = Test-WdvBundle $staged $b.manifestSha256 $b.folderName $Config.sources
    if (-not $again.Ok) {
        $State.bundle.status = 'Invalid'; $State.bundle.detail = "The staged copy of the offline bundle failed verification: $((@($again.Problems) | Select-Object -First 3) -join '; ')"
        Remove-Item -LiteralPath $staged -Recurse -Force -ErrorAction SilentlyContinue
        Write-WdvLog $State.bundle.detail 'ERROR'
        return
    }
    $State.bundle.status = 'Staged'; $State.bundle.folder = $staged; $State.bundle.packages = @($again.Packages).Count
    $State.bundle.detail = "Offline bundle $($b.folderName) verified and staged ($(@($again.Packages).Count) package(s)) from $($found.Folder)."
    Write-WdvLog $State.bundle.detail
}

<# Re-hashes one staged package's files right before it is installed. #>
function Test-WdvPackageFiles {
    param([hashtable] $Package)
    if (-not $Package.Entry) { return $true }
    foreach ($f in @($Package.Entry.files)) {
        $fp = Join-Path $Package.Root (([string] $f.path) -replace '/', '\')
        if (-not (Test-Path -LiteralPath $fp -PathType Leaf) -or (Get-WdvFileHash $fp) -ne [string] $f.sha256) { return $false }
    }
    return $true
}

<#
    Every package that may be considered for this computer, with its parsed INF:
    the staged bundle, technician-added packages, third-party INFs already in the driver store and
    verified downloads (metadata only until they are downloaded and checked).
#>
function Get-WdvPackages {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State, [switch] $NoDriverStore)
    $out = @()
    if ($State.bundle.status -eq 'Staged' -and $State.bundle.folder) {
        $m = Read-WdvJson (Join-Path $State.bundle.folder 'drivers-manifest.json')
        foreach ($p in @($m.packages)) {
            $root = Join-Path $State.bundle.folder (([string] $p.folder) -replace '/', '\')
            $inf = Join-Path $root (([string] $p.inf) -replace '/', '\')
            try {
                $info = Read-WdvInf $inf
                $archs = @(Get-WdvInfArchitectures $info)
                $sig = Test-WdvCatalog $info $(if ($archs -contains 'amd64') { 'amd64' } elseif ($archs.Count) { $archs[0] } else { '*' }) @($Config.sources.whqlSigners)
                $out += , @{ Source = 'offlineBundle'; Id = [string] $p.id; Entry = $p; Root = $root; Inf = $inf; Info = $info; Signature = $sig; SetupCritical = [bool] $p.setupCritical }
            } catch { Write-WdvLog "Bundle package $($p.folder) unreadable: $($_.Exception.Message)" 'WARN' }
        }
    }
    foreach ($t in @($State.technicianPackages)) {
        try {
            $info = Read-WdvInf $t.inf
            $archs = @(Get-WdvInfArchitectures $info)
            $sig = Test-WdvCatalog $info $(if ($archs -contains 'amd64') { 'amd64' } elseif ($archs.Count) { $archs[0] } else { '*' }) @($Config.sources.whqlSigners)
            $out += , @{ Source = 'technician'; Id = [string] $t.id; Entry = $t.entry; Root = $t.root; Inf = $t.inf; Info = $info; Signature = $sig; SetupCritical = $false }
        } catch { Write-WdvLog "Technician package $($t.inf) unreadable: $($_.Exception.Message)" 'WARN' }
    }
    if (-not $NoDriverStore) {
        foreach ($inf in @(Get-WdvDriverStoreInfs)) {
            try { $out += , @{ Source = 'driverStore'; Id = "store:$((Split-Path -Leaf $inf).ToLowerInvariant())"; Entry = $null; Root = (Split-Path -Parent $inf); Inf = $inf; Info = (Read-WdvInf $inf); Signature = $null; SetupCritical = $false } } catch { }
        }
    }
    foreach ($v in @($Config.verifiedPackages)) {
        $dir = Join-Path (Join-Path $Paths.Packages 'download') $v.id
        $ready = Join-Path $dir 'verified.json'
        if (Test-Path -LiteralPath $ready) {
            $rec = Read-WdvJson $ready
            if ($rec -and $rec.sha256 -eq $v.sha256 -and $rec.inf -and (Test-Path -LiteralPath $rec.inf)) {
                try {
                    $info = Read-WdvInf $rec.inf
                    $archs = @(Get-WdvInfArchitectures $info)
                    $sig = Test-WdvCatalog $info $(if ($archs -contains 'amd64') { 'amd64' } elseif ($archs.Count) { $archs[0] } else { '*' }) @($Config.sources.whqlSigners)
                    $out += , @{ Source = 'verifiedDownload'; Id = $v.id; Entry = $null; Root = (Split-Path -Parent $rec.inf); Inf = $rec.inf; Info = $info; Signature = $sig; SetupCritical = $false; Download = $v; Downloaded = $true }
                    continue
                } catch { }
            }
        }
        # Not downloaded yet: the metadata stands in for the INF until the file is checked.
        $meta = @{ Path = ''; File = ''; Class = [string] $v.deviceClass; ClassGuid = ''; Provider = [string] $v.vendor; Version = [string] $v.version; Date = ''; Catalogs = @{}; Targets = @(@{ Arch = [string] $v.architecture; MinBuild = 0; Ids = @($v.hardwareIds).Count }); HardwareIds = @($v.hardwareIds | ForEach-Object { ([string] $_).ToUpperInvariant() }); Problems = @() }
        $out += , @{ Source = 'verifiedDownload'; Id = $v.id; Entry = $null; Root = ''; Inf = ''; Info = $meta; Signature = @{ Ok = $true; Reason = 'checked after download' }; SetupCritical = $false; Download = $v; Downloaded = $false }
    }
    return $out
}

<#
    Downloads one verified package: HTTPS from an allowed official host, into downloads\<id>.part;
    accepted only if its SHA-256 is the one the technician verified, then extracted (CAB or ZIP,
    safe paths only) into packages\download\<id>. A wrong hash deletes the file and is a security
    failure; an unchanged verified file is never downloaded again.
#>
function Get-WdvVerifiedPackage {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $Meta)
    $dir = Join-Path (Join-Path $Paths.Packages 'download') $Meta.id
    $ready = Join-Path $dir 'verified.json'
    $rec = Read-WdvJson $ready
    if ($rec -and $rec.sha256 -eq $Meta.sha256 -and $rec.inf -and (Test-Path -LiteralPath $rec.inf)) { return @{ Ok = $true; Inf = $rec.inf; Reused = $true } }
    if (-not (Test-WdvDownloadUrl ([string] $Meta.url) @($Config.sources.downloadHosts))) { return @{ Ok = $false; Class = 'Policy'; Message = "not an allowed official HTTPS host: $($Meta.url)" } }
    if (-not (Test-Path -LiteralPath $Paths.Downloads)) { New-Item -ItemType Directory -Path $Paths.Downloads -Force | Out-Null }
    $ext = $(if ($Meta.format -eq 'zip') { 'zip' } else { 'cab' })
    $part = Join-Path $Paths.Downloads "$($Meta.id).$ext.part"
    $file = Join-Path $Paths.Downloads "$($Meta.id).$ext"
    if (-not ((Test-Path -LiteralPath $file) -and (Get-WdvFileHash $file) -eq $Meta.sha256)) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
        try { Invoke-WdvDownload $Meta.url $part } catch {
            if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
            return @{ Ok = $false; Class = 'Network'; Message = "download failed: $($_.Exception.Message)" }
        }
        $hash = Get-WdvFileHash $part
        if ($hash -ne $Meta.sha256) {
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            return @{ Ok = $false; Class = 'Integrity'; Message = "the downloaded file's SHA-256 $hash is not the verified $($Meta.sha256); deleted, never used" }
        }
        Move-Item -LiteralPath $part -Destination $file -Force
    }
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    $content = Join-Path $dir 'content'
    New-Item -ItemType Directory -Path $content -Force | Out-Null
    try {
        if ($ext -eq 'cab') { Expand-WdvCabinet $file $content }
        else {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::OpenRead($file)
            try {
                if ($zip.Entries.Count -gt $script:WdvLimits.maxFiles) { throw 'too many files in the archive' }
                foreach ($e in $zip.Entries) {
                    $name = $e.FullName -replace '\\', '/'
                    if ($name.EndsWith('/')) { continue }
                    if (-not (Test-WdvRelPath $name)) { throw "unsafe path in the archive: $name" }
                    $to = Join-Path $content ($name -replace '/', '\')
                    $toDir = Split-Path -Parent $to
                    if (-not (Test-Path -LiteralPath $toDir)) { New-Item -ItemType Directory -Path $toDir -Force | Out-Null }
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $to, $true)
                }
            } finally { $zip.Dispose() }
        }
    } catch {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        return @{ Ok = $false; Class = 'Incompatible'; Message = "the package could not be extracted: $($_.Exception.Message)" }
    }
    $infs = @(Get-ChildItem -LiteralPath $content -Recurse -File -Filter '*.inf' | Where-Object { $_.Name -ne 'autorun.inf' })
    if (-not $infs.Count) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue; return @{ Ok = $false; Class = 'Incompatible'; Message = 'the package contains no INF driver (installer programs are never run automatically)' } }
    $best = $null
    foreach ($i in $infs) { try { $info = Read-WdvInf $i.FullName; $hit = @($info.HardwareIds | Where-Object { @($Meta.hardwareIds) -contains $_ }).Count; if ($hit -and (-not $best -or $hit -gt $best.Hits)) { $best = @{ Inf = $i.FullName; Hits = $hit } } } catch { } }
    if (-not $best) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue; return @{ Ok = $false; Class = 'Incompatible'; Message = 'no INF in the package declares the hardware IDs it was verified for' } }
    Write-WdvJson $ready ([ordered]@{ id = $Meta.id; sha256 = $Meta.sha256; inf = $best.Inf; verifiedUtc = (Get-WdvNow).ToString('o') })
    return @{ Ok = $true; Inf = $best.Inf; Reused = $false }
}

# ------------------------------------------------------------------------------------------------
# Decisions
# ------------------------------------------------------------------------------------------------

<# Official page for a manual follow-up: the computer manufacturer first for OEM parts and laptops. #>
function Get-WdvManualAction {
    param([hashtable] $Device, [hashtable] $Context, [hashtable] $Sources, [string] $Why)
    $vendor = @($Sources.componentVendors | Where-Object { $_.id -eq $Device.vendor.id } | Select-Object -First 1)
    $oem = $Context.Oem
    $url = ''; $where = ''
    if ($oem -and $oem.supportUrl -and ($Device.oemCustomized -or $Context.Portable -or -not ($vendor.Count -and $vendor[0].supportUrl))) { $url = [string] $oem.supportUrl; $where = "$($oem.name) support for the $($Context.Model)" }
    elseif ($vendor.Count -and $vendor[0].supportUrl) { $url = [string] $vendor[0].supportUrl; $where = "$($vendor[0].name) drivers" }
    else { $url = [string] $Sources.microsoftCatalogUrl; $where = 'the Microsoft Update Catalog (search for the hardware ID)' }
    $hw = $(if (@($Device.hardwareIds).Count) { $Device.hardwareIds[0] } else { $Device.publicInstanceId })
    $text = "$($Device.name): $Why Hardware ID $hw. Get a driver for this exact device from $where, then install it (or run DeploymentRecovery.ps1 -Action AddDrivers -DriverPath <folder> with an INF package)."
    if ($Device.vendor.id -eq 'nvidia' -and $Device.category -eq 'display') { $text += " $($Sources.nvidiaBranchPolicy)" }
    return @{ text = $text; url = $url }
}

<#
    What to do for one device. Order of sources: the current driver if healthy; Windows Update
    (still to come during Inspection A); the driver store; the offline bundle; technician packages;
    verified downloads; otherwise a manual action. Returns @{ Kind; Package; Candidate; Considered;
    Reason; Manual } where Kind is Keep, Optional, Restart, Wait, Scan, Install, Download, Manual or
    Unsupported.
#>
function Get-WdvDecision {
    param([hashtable] $Device, [object[]] $Packages, [hashtable] $Config, [hashtable] $Context, [switch] $BeforeUpdates, [switch] $NetworkOnly)
    $a = $Device.assessment
    $d = @{ Kind = 'Keep'; Package = $null; Candidate = $null; Considered = @(); Reason = ($a.reasons -join ' '); Manual = $null }
    if ($a.action -in 'Keep', 'None') {
        if ($a.state -ne 'Healthy' -or -not $Device.driver -or $Device.driver.inbox) { return $d }
        foreach ($p in @($Packages | Where-Object { $_.Source -ne 'driverStore' })) {
            $c = Test-WdvCandidate $Device $p $Context $a
            if ($c.Eligible -and $c.Optional) {
                $approved = @($Config.approvals | Where-Object { $_.packageId -eq $p.Id -and ($Device.hardwareIds -contains ([string] $_.hardwareId).ToUpperInvariant()) }).Count -gt 0
                $d.Considered += , @{ source = $p.Source; package = $p.Id; version = $p.Info.Version; match = $c.MatchedId; result = $(if ($approved) { 'approved replacement' } else { 'newer, optional (not installed without technician approval)' }) }
                if ($approved -and $Config.policy.optionalReplacements -eq 'approvedOnly' -and -not $d.Package) { $d.Kind = $(if ($p.Source -eq 'verifiedDownload' -and -not $p.Downloaded) { 'Download' } else { 'Install' }); $d.Package = $p; $d.Candidate = $c; $d.Reason = "Approved replacement of a working driver with $($p.Info.Provider) $($p.Info.Version)." }
                elseif (-not $d.Package) { $d.Kind = 'Optional'; $d.Reason = "Working; a newer driver ($($p.Info.Version)) is available but a working driver is not replaced without approval." }
            }
        }
        return $d
    }
    if ($a.action -eq 'RestartRequired') { $d.Kind = 'Restart'; return $d }
    if ($a.action -eq 'ReviewRequired') {
        $d.Kind = $(if ($a.state -eq 'Unsupported') { 'Unsupported' } else { 'Manual' })
        $d.Manual = Get-WdvManualAction $Device $Context $Config.sources $(if ($a.reasons.Count) { $a.reasons[0] } else { 'needs review.' })
        return $d
    }
    # Boot-critical: never change the driver of a storage controller that has a disk below it.
    if ($Device.category -like 'storage*' -and $Device.hostsSystemDisk -and $Device.driver) {
        $d.Kind = 'Manual'; $d.Reason = 'Storage controller with a disk attached: its driver is never changed automatically.'
        $d.Manual = Get-WdvManualAction $Device $Context $Config.sources 'its driver is not working, and boot-critical storage drivers are never changed automatically.'
        return $d
    }
    if (-not $Config.policy.resolveMissing) {
        $d.Kind = 'Manual'; $d.Manual = Get-WdvManualAction $Device $Context $Config.sources "$($a.reasons -join ' ') Resolution from verified sources is turned off for this deployment."
        return $d
    }
    $eligible = @()
    foreach ($p in @($Packages)) {
        if ($NetworkOnly -and $p.Source -eq 'verifiedDownload') { continue }
        if ($p.Source -eq 'driverStore' -and $Device.driver) { continue }
        $c = Test-WdvCandidate $Device $p $Context $a
        if ($c.RefusalClass -eq 'NoMatch') { continue }
        $d.Considered += , @{ source = $p.Source; package = $p.Id; version = $p.Info.Version; match = $c.MatchedId; result = $(if ($c.Eligible) { "eligible ($($c.Match))" } else { "refused: $($c.Refusal)" }) }
        if ($c.Eligible) { $eligible += , @{ P = $p; C = $c } }
    }
    # Windows Update first: before it has run, nothing is installed (the network bootstrap is the exception).
    if ($BeforeUpdates -and $Config.windowsUpdate.enabled -and $Config.policy.useWindowsUpdate) { $d.Kind = 'Wait'; $d.Reason = "$($a.reasons -join ' ') Windows Update runs first."; return $d }
    if ($eligible.Count) {
        $best = @($eligible | Sort-Object { [int] $_.C.Score }, @{ Expression = { $_.P.Info.Version }; Descending = $true } | Select-Object -First 1)[0]
        $d.Package = $best.P; $d.Candidate = $best.C
        $d.Kind = switch ($best.P.Source) { 'driverStore' { 'Scan' } 'verifiedDownload' { $(if ($best.P.Downloaded) { 'Install' } else { 'Download' }) } default { 'Install' } }
        $d.Reason = "$($a.reasons -join ' ') Candidate: $($best.P.Info.Provider) $($best.P.Info.Version) from $($best.P.Source) ($($best.C.Match) $($best.C.MatchedId))."
        if ($best.C.Notes.Count) { $d.Reason += ' ' + ($best.C.Notes -join ' ') }
        return $d
    }
    $why = "$($a.reasons -join ' ')"
    if (@($d.Considered).Count) { $why += " No candidate was safe to install ($((@($d.Considered) | ForEach-Object { $_.result }) -join '; '))." } else { $why += ' No verified driver package for it is available.' }
    if ($Config.windowsUpdate.enabled -and $Config.windowsUpdate.drivers -ne 'include') { $why += ' Windows Update was not allowed to install drivers in this deployment.' }
    $d.Kind = 'Manual'
    $d.Manual = Get-WdvManualAction $Device $Context $Config.sources $why
    $d.Reason = $why
    return $d
}

# ------------------------------------------------------------------------------------------------
# Installation and verification
# ------------------------------------------------------------------------------------------------

function Test-WdvSamePackage {
    param($Driver, [hashtable] $Info)
    if (-not $Driver -or -not $Info) { return $false }
    return ($Info.Version -and $Driver.version -eq $Info.Version -and $Driver.provider -ieq $Info.Provider)
}

<#
    Verification from the device itself (never from an exit code):
      Succeeded         the device works with the package (or, for a missing driver, with the
                        driver Windows chose)
      WaitingForReboot  the device needs a restart (problem 14 or pnputil 3010)
      NotSelected       the device is unchanged: Windows ranked its current driver higher
      DeviceFailure     the device has a new or different problem: no further automatic attempt
      NoEffect          the same problem remains: the package is not tried again
#>
function Get-WdvVerification {
    param([hashtable] $Op, $After, [hashtable] $Info, $ExitCode)
    if (-not $After) { return @{ Status = 'FailedPermanent'; Class = 'DeviceFailure'; Verification = 'DeviceMissing'; Message = 'the device is no longer present after the installation' } }
    $code = [int] $After.ProblemCode
    $same = Test-WdvSamePackage $After.Driver $Info
    $Op.problemAfter = $code
    if ($code -eq 14 -or ($ExitCode -eq 3010 -and -not ($same -and $code -eq 0))) { return @{ Status = 'WaitingForReboot'; Class = ''; Verification = 'RestartPending'; Message = 'installed; the device starts with the new driver after a restart' } }
    if ($code -eq 0 -and $same) { return @{ Status = 'Succeeded'; Class = ''; Verification = 'Verified'; Message = "the device works with $($Info.Provider) $($Info.Version)" } }
    if ($code -eq 0) {
        $before = $Op.previousDriver
        $changed = (-not $before -and $After.Driver) -or ($before -and $After.Driver -and ($before.inf -ne $After.Driver.inf -or $before.version -ne $After.Driver.version))
        if ($changed -and ([int] $Op.problemBefore -ne 0 -or $Op.stateAtCreation -eq 'BasicDriver')) {
            if ($After.Driver -and $After.Driver.inf -ieq 'display.inf') { return @{ Status = 'ManualActionRequired'; Class = 'NotSelected'; Verification = 'NotResolved'; Message = 'Windows still uses the basic display driver' } }
            return @{ Status = 'Succeeded'; Class = ''; Verification = 'VerifiedOtherDriver'; Message = "the device works; Windows chose $($After.Driver.provider) $($After.Driver.version)" }
        }
        return @{ Status = 'ManualActionRequired'; Class = 'NotSelected'; Verification = 'NotResolved'; Message = 'Windows kept the existing driver (it ranks higher than the package, which stays in the driver store)' }
    }
    if ($code -eq [int] $Op.problemBefore -and [int] $Op.problemBefore -ne 0) { return @{ Status = 'FailedPermanent'; Class = 'NoEffect'; Verification = 'Failed'; Message = "the problem remains (Code $code); this package is not tried again" } }
    return @{ Status = 'FailedPermanent'; Class = 'DeviceFailure'; Verification = 'Failed'; Message = "the device now reports Code $code ($(if ($script:WdvProblemNames.ContainsKey($code)) { $script:WdvProblemNames[$code] } else { 'unknown' })); no further automatic attempt for this device" }
}

function Get-WdvRollbackHint {
    param([hashtable] $Op)
    $prev = $Op.previousDriver
    $was = $(if ($prev) { "$($prev.provider) $($prev.version) ($($prev.inf))" } else { 'no driver' })
    $hint = "Before: $was. Device Manager > the device > Properties > Driver > Roll Back Driver restores the previous driver where Windows kept it; the previous package was not removed from the driver store."
    if ($Op.category -like 'storage*') { $hint += ' This is a storage controller: do not remove its driver.' }
    return $hint
}

<# Runs one installation under the shared install lock; the attempt is counted and saved first. #>
function Invoke-WdvInstall {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State, [hashtable] $Op, [hashtable] $Device, [hashtable] $Decision, [string] $Trigger = 'automatic')
    $pkg = $Decision.Package
    if ($State.policy.restricted) {
        Set-WdvOperation $Op 'ManualActionRequired' "Device installation is restricted by organization policy ($($State.policy.detail)); nothing was installed." 'Policy'
        return 'Policy'
    }
    if ($Decision.Kind -eq 'Download') {
        if (-not (Test-WdvNetwork)) {
            $Op.networkDeferrals = [int] $Op.networkDeferrals + 1
            if ([int] $Op.networkDeferrals -gt [int] $Config.maxNetworkDeferrals) {
                $Op.manualAction = Get-WdvManualAction $Device $State.context $Config.sources 'the verified package could not be downloaded (no network).'
                Set-WdvOperation $Op 'ManualActionRequired' 'No network to download the verified package.' 'Manual'
            } else { Set-WdvOperation $Op 'WaitingForNetwork' 'Waiting for the network to download the verified package.'; $Op.waitingFor = 'network' }
            return 'WaitingForNetwork'
        }
        $Op.waitingFor = ''
        $dl = Get-WdvVerifiedPackage $Config $Paths $pkg.Download
        if (-not $dl.Ok) {
            Add-WdvAttempt $Paths $Op @{ trigger = $Trigger; startUtc = (Get-WdvNow).ToString('o'); action = 'download'; source = 'verifiedDownload'; package = $pkg.Id; result = 'Failed'; class = $dl.Class; message = $dl.Message }
            if ($dl.Class -eq 'Network') {
                $Op.attempts = [int] $Op.attempts + 1; $Op.totalAttempts = [int] $Op.totalAttempts + 1
                if ([int] $Op.attempts -ge [int] $Config.maxAttemptsPerOperation) { Set-WdvOperation $Op 'FailedPermanent' $dl.Message 'Permanent' } else { Set-WdvOperation $Op 'FailedRetryable' $dl.Message 'Network'; $Op.nextAttemptUtc = (Get-WdvNow).AddMinutes(15).ToString('o') }
            } else {
                $Op.manualAction = Get-WdvManualAction $Device $State.context $Config.sources "the verified package was refused: $($dl.Message)."
                Set-WdvOperation $Op 'FailedPermanent' $dl.Message $dl.Class
            }
            return $dl.Class
        }
        $info = Read-WdvInf $dl.Inf
        $archs = @(Get-WdvInfArchitectures $info)
        $sig = Test-WdvCatalog $info $(if ($archs -contains 'amd64') { 'amd64' } elseif ($archs.Count) { $archs[0] } else { '*' }) @($Config.sources.whqlSigners)
        $pkg = @{ Source = 'verifiedDownload'; Id = $pkg.Id; Entry = $null; Root = (Split-Path -Parent $dl.Inf); Inf = $dl.Inf; Info = $info; Signature = $sig; Downloaded = $true; Download = $pkg.Download }
        $c = Test-WdvCandidate $Device $pkg $State.context $Device.assessment
        if (-not $c.Eligible) {
            $Op.manualAction = Get-WdvManualAction $Device $State.context $Config.sources "the downloaded package was refused: $($c.Refusal)."
            Set-WdvOperation $Op 'FailedPermanent' "Downloaded package refused: $($c.Refusal)." $(if ($c.RefusalClass -in 'Signature', 'Incompatible') { $c.RefusalClass } else { 'Incompatible' })
            return $Op.failureClass
        }
    }
    if ($pkg.Source -in 'offlineBundle', 'technician' -and -not (Test-WdvPackageFiles $pkg)) {
        Set-WdvOperation $Op 'FailedPermanent' "The staged package $($pkg.Id) was modified after it was verified; it is never used." 'Integrity'
        return 'Integrity'
    }
    $lock = Enter-WdbInstallLock $Config.dataRoot 'Drivers' ([int] $Config.lockWaitMinutes * 60)
    if (-not $lock) { Write-WdvLog 'Another installation holds the install lock; trying again at the next start.' 'WARN'; return 'WaitingForLock' }
    $start = (Get-WdvNow).ToString('o')
    $r = $null
    try {
        $Op.attempts = [int] $Op.attempts + 1; $Op.totalAttempts = [int] $Op.totalAttempts + 1
        $Op.source = $pkg.Source
        $Op.package = @{ id = $pkg.Id; inf = (Split-Path -Leaf $pkg.Inf); provider = $pkg.Info.Provider; version = $pkg.Info.Version; date = $pkg.Info.Date; class = $pkg.Info.Class; path = $pkg.Inf }
        Set-WdvOperation $Op 'Running' "Installing $($pkg.Info.Provider) $($pkg.Info.Version) ($($pkg.Source))."
        Save-WdvState $Paths $State
        Set-WdvStatus 'Installing' $Op.name $State
        Write-WdvLog "  install $($Op.name) [$($Op.hardwareId)]: $($pkg.Source) $($pkg.Id) $($pkg.Info.Provider) $($pkg.Info.Version) (attempt $($Op.attempts)/$($Config.maxAttemptsPerOperation))"
        if ($Decision.Kind -eq 'Scan') { $r = Invoke-WdvPnpUtil @('/scan-devices', '/instanceid', $Op.instanceId) }
        else { $r = Invoke-WdvPnpUtil @('/add-driver', $pkg.Inf, '/install') }
    } catch {
        $r = @{ ExitCode = -1; Output = $_.Exception.Message }
    } finally { Exit-WdbInstallLock $lock }
    Wait-Wdv 5
    $after = $null
    try { $after = Get-WdvDeviceState $Op.instanceId } catch { Write-WdvLog "Could not re-read the device: $($_.Exception.Message)" 'WARN' }
    $signatureText = ([string] $r.Output) -match '(?i)signature|catalog|hash|not digitally signed|authenticode'
    if ($r.ExitCode -notin 0, 3010 -and -not ($after -and (Test-WdvSamePackage $after.Driver $pkg.Info))) {
        $msg = "pnputil returned $($r.ExitCode): $(((([string] $r.Output) -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 2) -join ' ')"
        if ($signatureText) { Set-WdvOperation $Op 'FailedPermanent' "Windows refused the package's signature ($msg)." 'Signature' }
        elseif ([int] $Op.attempts -ge [int] $Config.maxAttemptsPerOperation) { Set-WdvOperation $Op 'FailedPermanent' "Installation failed $($Op.attempts) time(s): $msg" 'Permanent' }
        else { Set-WdvOperation $Op 'FailedRetryable' "Installation failed: $msg" 'InstallFailed'; $Op.nextAttemptUtc = (Get-WdvNow).AddMinutes(10).ToString('o') }
        if ($Op.status -eq 'FailedPermanent') { $Op.manualAction = Get-WdvManualAction $Device $State.context $Config.sources "automatic installation failed ($msg)." }
        $v = @{ Verification = 'Failed' }
    } else {
        $v = Get-WdvVerification $Op $after $pkg.Info $r.ExitCode
        $Op.verification = $v.Verification
        Set-WdvOperation $Op $v.Status "$($v.Message)." $v.Class
        $Op.rebootRequired = ($v.Status -eq 'WaitingForReboot')
        if ($v.Class -eq 'DeviceFailure') {
            if ($State.devices.ContainsKey($Op.deviceKey)) { $State.devices[$Op.deviceKey].blocked = $true }
            $Op.manualAction = @{ text = "$($Op.name): $($v.Message). $(Get-WdvRollbackHint $Op)"; url = '' }
            Write-WdvEvent 4110 "Driver installation for $($Op.name) left the device not working ($($v.Message)). No further automatic attempts for this device." 'Warning'
        } elseif ($v.Status -eq 'ManualActionRequired' -or $v.Class -eq 'NoEffect') {
            $Op.manualAction = Get-WdvManualAction $Device $State.context $Config.sources "$($v.Message)."
        }
    }
    if ($after -and $State.devices.ContainsKey($Op.deviceKey)) { $State.devices[$Op.deviceKey].driverFinal = $after.Driver }
    Add-WdvAttempt $Paths $Op @{ trigger = $Trigger; attempt = [int] $Op.attempts; startUtc = $start; endUtc = (Get-WdvNow).ToString('o'); action = $(if ($Decision.Kind -eq 'Scan') { 'scan-devices' } else { 'add-driver' }); source = $pkg.Source; package = $pkg.Id
                                 exitCode = $r.ExitCode; result = $Op.status; class = $Op.failureClass; problemBefore = $Op.problemBefore; problemAfter = $Op.problemAfter; rebootRequired = [bool] $Op.rebootRequired; message = $Op.reason }
    Write-WdvLog "  result $($Op.name): $($Op.status)$(if ($Op.failureClass) { " ($($Op.failureClass))" }). $($Op.reason)" $(if ($Op.status -in 'Succeeded', 'WaitingForReboot') { 'INFO' } else { 'WARN' })
    Save-WdvState $Paths $State
    return $Op.status
}

<# After a restart or crash: what an interrupted or restart-pending installation actually did. #>
function Resume-WdvOperations {
    param([hashtable] $Paths, [hashtable] $State, [hashtable] $Config)
    $boot = $null
    try { $boot = Get-WdvBootTime } catch { }
    foreach ($op in @(Get-WdvOperationList $State | Where-Object { $_.status -in 'Running', 'WaitingForReboot' })) {
        # A restart-pending installation is verified only once the computer has restarted.
        if ($op.status -eq 'WaitingForReboot' -and (-not $boot -or $boot -le (ConvertTo-WdvDate $op.updatedUtc))) { continue }
        $after = $null
        try { $after = Get-WdvDeviceState $op.instanceId } catch { }
        $info = $(if ($op.package) { @{ Provider = $op.package.provider; Version = $op.package.version } } else { $null })
        $wasRunning = $op.status -eq 'Running'
        if ($wasRunning -and $after -and [int] $after.ProblemCode -ne 0 -and [int] $after.ProblemCode -ne 14 -and -not (Test-WdvSamePackage $after.Driver $info)) {
            # Interrupted before anything changed: try again (the attempt was already counted).
            if ([int] $op.attempts -ge [int] $Config.maxAttemptsPerOperation) { Set-WdvOperation $op 'FailedPermanent' 'The installation was interrupted repeatedly.' 'Permanent' }
            else { Set-WdvOperation $op 'Pending' 'The previous installation attempt was interrupted; it is checked and tried again.' '' }
            Add-WdvAttempt $Paths $op @{ trigger = 'resume'; result = $op.status; message = 'interrupted attempt reconciled with the device state' }
            continue
        }
        $v = Get-WdvVerification $op $after $info $null
        if ($wasRunning -and $v.Status -eq 'ManualActionRequired' -and [int] $op.attempts -lt [int] $Config.maxAttemptsPerOperation) {
            Set-WdvOperation $op 'Pending' 'The previous installation attempt was interrupted before Windows applied it; tried again.' ''
            continue
        }
        if ($v.Status -eq 'WaitingForReboot' -and -not $wasRunning) { continue }
        $op.verification = $v.Verification
        Set-WdvOperation $op $v.Status "$($v.Message) (checked after $(if ($wasRunning) { 'an interruption' } else { 'the restart' }))." $v.Class
        $op.rebootRequired = ($v.Status -eq 'WaitingForReboot')
        if ($v.Class -eq 'DeviceFailure' -and $State.devices.ContainsKey($op.deviceKey)) { $State.devices[$op.deviceKey].blocked = $true; $op.manualAction = @{ text = "$($op.name): $($v.Message). $(Get-WdvRollbackHint $op)"; url = '' } }
        Add-WdvAttempt $Paths $op @{ trigger = 'verify'; result = $op.status; class = $op.failureClass; problemAfter = $op.problemAfter; message = $op.reason }
    }
}

# ------------------------------------------------------------------------------------------------
# Coordination: Windows Update first, restarts, network bootstrap
# ------------------------------------------------------------------------------------------------

<#
    Windows Update first: the stage waits until the Windows Update engine has a final result (or is
    not part of this deployment, or waitForUpdatesHours passed). It never starts or changes Windows
    Update itself.
#>
function Get-WdvUpdatesGate {
    param([hashtable] $Config, [hashtable] $State)
    $wu = $Config.windowsUpdate
    if (-not $wu.enabled) { return @{ Open = $true; Reason = 'Windows Update automation is not part of this deployment.' } }
    if (-not $Config.policy.useWindowsUpdate) { return @{ Open = $true; Reason = 'Configured not to wait for Windows Update.' } }
    $s = Read-WdvJson $wu.stateFile
    if ($s -and $s['final']) { return @{ Open = $true; Reason = "Windows Update finished: $($s['final'])."; Status = [string] $s['final'] } }
    $res = Read-WdvJson $wu.resultFile
    if ($res -and $res['status']) { return @{ Open = $true; Reason = "Windows Update result: $($res['status'])."; Status = [string] $res['status'] } }
    $waited = ((Get-WdvNow) - (ConvertTo-WdvDate $State.firstStartUtc)).TotalHours
    if ($waited -ge [double] $Config.waitForUpdatesHours) { return @{ Open = $true; Reason = "Windows Update still not finished after $($Config.waitForUpdatesHours) h; continuing."; Warn = $true; Status = 'NotFinished' } }
    if (-not $s -and -not (Test-WdvUpdateTask $wu) -and $waited -ge 0.5) { return @{ Open = $true; Reason = 'The Windows Update engine is not installed (no task, no state); continuing.'; Warn = $true; Status = 'NotInstalled' } }
    return @{ Open = $false; Reason = 'Waiting for Windows Update to finish (it may install drivers itself).' }
}

function Request-WdvReboot {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State, [string] $Reason)
    if ([int] $State.reboots -ge [int] $Config.maxReboots) { Write-WdvLog "Restart needed ($Reason) but the limit of $($Config.maxReboots) restart(s) is reached; reported instead." 'WARN'; return 'LimitReached' }
    if (Test-WdbRestartPending $Config.dataRoot) { Set-WdvStatus 'WaitingForReboot' 'Another engine has scheduled a restart.' $State; return 'Rebooting' }
    $lock = Enter-WdbInstallLock $Config.dataRoot 'Drivers' ([int] $Config.lockWaitMinutes * 60)
    if (-not $lock) { Set-WdvStatus 'RebootDeferred' $Reason $State; Write-WdvLog "Restart deferred ($Reason): another installation holds the install lock." 'WARN'; return 'RebootDeferred' }
    try {
        $State.reboots = [int] $State.reboots + 1
        $State.rebootRequests = @(@($State.rebootRequests) + @(@{ atUtc = (Get-WdvNow).ToString('o'); reason = $Reason }))
        Save-WdvState $Paths $State
        Write-WdvLog "Restart $($State.reboots)/$($Config.maxReboots): $Reason."
        Set-WdvStatus 'Rebooting' $Reason $State
        Write-WdvEvent 4001 "Restarting to continue driver setup ($Reason)."
        Set-WdbRestartPending $Config.dataRoot 'Drivers' $Reason
        Invoke-WdvReboot -WarningSeconds ([int] $Config.rebootWarningSeconds) -Reason $Reason
        Wait-Wdv ([int] $Config.rebootWarningSeconds + 120)
    } finally { Exit-WdbInstallLock $lock }
    return 'Rebooting'
}

<#
    Network bootstrap: when the computer is offline and a network adapter has no working driver,
    verified offline packages (bundle, technician, driver store) are tried for that adapter only,
    then the adapter and the connection are checked again. Without a usable package the state is
    kept and the missing network driver is reported (state\network-driver-missing.json), so the
    other stages are not left guessing why the network never appears.
#>
function Invoke-WdvNetworkBootstrap {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State, [hashtable] $Inventory)
    $State.network.checkedUtc = (Get-WdvNow).ToString('o')
    if (Test-WdvNetwork) {
        $State.network.status = 'Online'; $State.network.detail = 'Connected.'; $State.network.devices = @()
        if (Test-Path -LiteralPath $Paths.NetworkFlag) { Remove-Item -LiteralPath $Paths.NetworkFlag -Force -ErrorAction SilentlyContinue }
        return 'Online'
    }
    $broken = @($Inventory.Devices | Where-Object { $_.physical -and $_.assessment.networkCritical -and $_.assessment.state -in 'DriverMissing', 'Malfunctioning', 'BasicDriver' })
    if (-not $broken.Count) {
        $State.network.status = 'OfflineNoDriverProblem'; $State.network.detail = 'Offline, but every network adapter has a working driver (cable, Wi-Fi profile or network).'; $State.network.devices = @()
        if (Test-Path -LiteralPath $Paths.NetworkFlag) { Remove-Item -LiteralPath $Paths.NetworkFlag -Force -ErrorAction SilentlyContinue }
        return 'Offline'
    }
    Write-WdvLog "Offline and $($broken.Count) network adapter(s) without a working driver: network bootstrap from verified offline packages."
    if (-not $Config.policy.networkBootstrap) { $State.network.status = 'NetworkDriverMissing'; $State.network.detail = 'Network bootstrap is turned off.' }
    else {
        $packages = @(Get-WdvPackages $Config $Paths $State | Where-Object { $_.Source -ne 'verifiedDownload' })
        foreach ($dev in $broken) {
            if ($State.devices.ContainsKey($dev.key) -and $State.devices[$dev.key].blocked) { continue }
            $op = Get-WdvDeviceOperation $State $dev
            if ($op.status -in 'Succeeded', 'FailedPermanent') { continue }
            $dec = Get-WdvDecision $dev $packages $Config $State.context -NetworkOnly
            $op.candidates = @($dec.Considered)
            if ($dec.Kind -notin 'Install', 'Scan') { continue }
            [void] (Invoke-WdvInstall $Config $Paths $State $op $dev $dec 'networkBootstrap')
        }
        for ($i = 0; $i -lt [Math]::Max(1, [int] $Config.networkWaitMinutes * 4); $i++) {
            if (Test-WdvNetwork) { $State.network.status = 'Online'; $State.network.detail = 'Connected after the network driver was installed from verified offline packages.'; $State.network.devices = @(); break }
            Wait-Wdv 15
        }
    }
    if ($State.network.status -eq 'Online') {
        if (Test-Path -LiteralPath $Paths.NetworkFlag) { Remove-Item -LiteralPath $Paths.NetworkFlag -Force -ErrorAction SilentlyContinue }
        Write-WdvLog $State.network.detail
        return 'Online'
    }
    $State.network.status = 'NetworkDriverMissing'
    $State.network.devices = @($broken | ForEach-Object { @{ name = $_.name; category = $_.category; hardwareId = $(if (@($_.hardwareIds).Count) { $_.hardwareIds[0] } else { '' }); state = $_.assessment.state } })
    $State.network.detail = "No network: $(@($broken | ForEach-Object { $_.name }) -join ', ') has no working driver and no verified offline driver for it is available. Offline intervention: supply an INF network driver (DeploymentRecovery.ps1 -Action AddDrivers -DriverPath <folder>) or connect a supported adapter."
    Write-WdvJson $Paths.NetworkFlag ([ordered]@{ sinceUtc = $State.network.checkedUtc; detail = $State.network.detail; devices = @($State.network.devices) })
    Write-WdvLog $State.network.detail 'WARN'
    return 'NetworkDriverMissing'
}

function Get-WdvDeviceOperation {
    param([hashtable] $State, [hashtable] $Device)
    $id = "driver:$($Device.key)"
    if (-not $State.operations.ContainsKey($id)) { $State.operations[$id] = New-WdvOperation $Device 'Pending' ($Device.assessment.reasons -join ' ') }
    $op = $State.operations[$id]
    $op.instanceId = $Device.instanceId
    return $op
}

<# Remembers each device across inspections (state before Windows Update, after it, at the end). #>
function Update-WdvDeviceRecords {
    param([hashtable] $State, [hashtable] $Inventory, [string] $Stage)
    foreach ($d in @($Inventory.Devices | Where-Object { $_.physical })) {
        if (-not $State.devices.ContainsKey($d.key)) { $State.devices[$d.key] = @{ name = $d.name; category = $d.category; publicInstanceId = $d.publicInstanceId; hardwareId = $(if (@($d.hardwareIds).Count) { $d.hardwareIds[0] } else { '' }); blocked = $false } }
        $rec = $State.devices[$d.key]
        $rec["state$Stage"] = $d.assessment.state
        $rec["driver$Stage"] = $d.driver
        $rec["problem$Stage"] = $d.problemCode
    }
}

<#
    Turns an inspection into operations. Before Windows Update only devices that need something get
    an operation (waiting for Windows Update); afterwards every such operation is reconciled: a
    device Windows or Windows Update fixed in the meantime is AlreadySatisfied, the rest get a
    decision. Healthy devices without an operation are kept as they are.
#>
function Update-WdvOperations {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State, [hashtable] $Inventory, [switch] $BeforeUpdates)
    $packages = @(Get-WdvPackages $Config $Paths $State)
    foreach ($d in @($Inventory.Devices | Where-Object { $_.physical })) {
        $id = "driver:$($d.key)"
        $has = $State.operations.ContainsKey($id)
        $op = $(if ($has) { $State.operations[$id] } else { $null })
        $rec = $State.devices[$d.key]
        if ($op -and $op.status -in 'Succeeded', 'FailedPermanent', 'Running', 'WaitingForReboot') { continue }
        if ($op -and $op.status -eq 'ManualActionRequired' -and $op.failureClass -in 'NotSelected', 'Policy', 'NoEffect', 'DeviceFailure') { continue }
        if ($rec -and $rec.blocked) { continue }
        $dec = Get-WdvDecision $d $packages $Config $Inventory.Context -BeforeUpdates:$BeforeUpdates
        if ($dec.Kind -eq 'Optional' -and $rec) { $rec.optionalUpdate = (@($dec.Considered) | Select-Object -First 1) }
        if ($dec.Kind -in 'Keep', 'Optional') {
            if ($op -and $op.status -notin $script:WdvTerminal) {
                $changed = $rec -and ($rec['driverInitial'] -and $d.driver -and ($rec['driverInitial'].inf -ne $d.driver.inf -or $rec['driverInitial'].version -ne $d.driver.version)) -or ($rec -and -not $rec['driverInitial'] -and $d.driver)
                $op.source = $(if ($changed -and $Config.windowsUpdate.enabled -and $Config.windowsUpdate.drivers -eq 'include') { 'windowsUpdate' } elseif ($changed) { 'windows' } else { 'existing' })
                $op.verification = 'Verified'
                Set-WdvOperation $op 'AlreadySatisfied' $(if ($changed) { "Resolved before this stage acted: the device works with $($d.driver.provider) $($d.driver.version) (installed by $(if ($op.source -eq 'windowsUpdate') { 'Windows Update' } else { 'Windows' }))." } else { 'The device works now; nothing was installed.' }) ''
                Add-WdvAttempt $Paths $op @{ trigger = 'inspection'; result = 'AlreadySatisfied'; source = $op.source; message = $op.reason }
            }
            continue
        }
        $op = Get-WdvDeviceOperation $State $d
        $op.candidates = @($dec.Considered)
        $op.previousDriver = $d.driver
        $op.problemBefore = [int] $d.problemCode
        $op.stateAtCreation = $d.assessment.state
        switch ($dec.Kind) {
            'Wait' { Set-WdvOperation $op 'Pending' $dec.Reason ''; $op.waitingFor = 'windowsUpdate' }
            'Restart' { Set-WdvOperation $op 'WaitingForReboot' 'The device starts with its new driver after a restart.' ''; $op.rebootRequired = $true; $op.verification = 'RestartPending' }
            'Manual' { $op.manualAction = $dec.Manual; Set-WdvOperation $op 'ManualActionRequired' $dec.Reason 'Manual' }
            'Unsupported' { $op.manualAction = $dec.Manual; Set-WdvOperation $op 'Unsupported' $dec.Reason 'Manual' }
            default {
                if ($op.status -eq 'FailedRetryable' -and $op.nextAttemptUtc -and (ConvertTo-WdvDate $op.nextAttemptUtc) -gt (Get-WdvNow)) { break }
                if ($op.status -notin 'FailedRetryable', 'WaitingForNetwork') { Set-WdvOperation $op 'Pending' $dec.Reason '' }
                $op.waitingFor = ''
                $op.plannedKind = $dec.Kind
            }
        }
    }
}

<# Runs every operation that is ready: network adapters first, then the rest. #>
function Invoke-WdvResolution {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State, [hashtable] $Inventory)
    $packages = @(Get-WdvPackages $Config $Paths $State)
    $byKey = @{}
    foreach ($d in $Inventory.Devices) { $byKey[$d.key] = $d }
    $ready = @(Get-WdvOperationList $State | Where-Object { $_.status -in 'Pending', 'FailedRetryable', 'WaitingForNetwork' -and -not $_.waitingFor -or $_.status -eq 'WaitingForNetwork' })
    $ordered = @($ready | Sort-Object { if ($_.category -like 'network*') { 0 } else { 1 } }, { $_.operationId })
    foreach ($op in $ordered) {
        if (-not $byKey.ContainsKey($op.deviceKey)) { Set-WdvOperation $op 'ManualActionRequired' 'The device is no longer present.' 'Manual'; continue }
        if ($op.status -eq 'FailedRetryable' -and $op.nextAttemptUtc -and (ConvertTo-WdvDate $op.nextAttemptUtc) -gt (Get-WdvNow)) { continue }
        $dev = $byKey[$op.deviceKey]
        $dec = Get-WdvDecision $dev $packages $Config $Inventory.Context
        $op.candidates = @($dec.Considered)
        if ($dec.Kind -notin 'Install', 'Scan', 'Download') {
            if ($dec.Kind -in 'Keep', 'Optional') { Set-WdvOperation $op 'AlreadySatisfied' 'The device works now; nothing was installed.' ''; $op.verification = 'Verified'; continue }
            $op.manualAction = $dec.Manual
            Set-WdvOperation $op $(if ($dec.Kind -eq 'Unsupported') { 'Unsupported' } else { 'ManualActionRequired' }) $dec.Reason 'Manual'
            continue
        }
        $res = Invoke-WdvInstall $Config $Paths $State $op $dev $dec
        if ($res -eq 'WaitingForLock') { return 'WaitingForLock' }
    }
    return 'Done'
}

# ------------------------------------------------------------------------------------------------
# Results
# ------------------------------------------------------------------------------------------------

<#
    The health summary Phase 9 reads. Distinguishes: AllHealthy, RestartPending,
    InstalledButMalfunctioning, MissingDriver, PossibleHardwareIssue, TechnicianRequired.
#>
function Get-WdvHealth {
    param([object[]] $Devices, [object[]] $Operations)
    $phys = @($Devices | Where-Object { $_.physical })
    $flags = [ordered]@{
        restartPending = (@($phys | Where-Object { $_.assessment.state -eq 'RestartPending' }).Count + @($Operations | Where-Object { $_.status -eq 'WaitingForReboot' }).Count) -gt 0
        installedButMalfunctioning = @($Operations | Where-Object { $_.failureClass -in 'DeviceFailure', 'NoEffect' }).Count -gt 0
        missingDriver = @($phys | Where-Object { $_.assessment.state -in 'DriverMissing', 'BasicDriver' -or ($_.assessment.state -eq 'Malfunctioning' -and $_.problemCode -in $script:WdvDriverProblems) }).Count -gt 0
        possibleHardwareIssue = @($phys | Where-Object { $_.assessment.state -eq 'HardwareIssue' }).Count -gt 0
        technicianRequired = @($Operations | Where-Object { $_.status -in 'ManualActionRequired', 'FailedPermanent', 'FailedRetryable', 'Unsupported' }).Count -gt 0
    }
    $status = 'AllHealthy'
    foreach ($k in 'restartPending', 'installedButMalfunctioning', 'missingDriver', 'possibleHardwareIssue', 'technicianRequired') { if ($flags[$k]) { $status = $k.Substring(0, 1).ToUpperInvariant() + $k.Substring(1); break } }
    $flags.allHealthy = ($status -eq 'AllHealthy')
    return [ordered]@{ status = $status; flags = $flags }
}

function Get-WdvStageStatus {
    param([object[]] $Operations)
    if (@($Operations | Where-Object { $_.status -eq 'FailedPermanent' -and $_.failureClass -notin 'Manual' -or $_.status -eq 'FailedRetryable' }).Count) { return 'CompletedWithFailures' }
    if (@($Operations | Where-Object { $_.status -in 'ManualActionRequired', 'WaitingForReboot', 'Unsupported', 'WaitingForNetwork', 'Pending' }).Count) { return 'CompletedWithFollowUp' }
    return 'Succeeded'
}

<# drivers.json: the machine-readable driver result (also written while the stage runs, final = false). #>
function Write-WdvReport {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State, $Inventory, [string] $Status, [bool] $Final)
    $ops = @(Get-WdvOperationList $State)
    $devices = @(if ($Inventory) { @($Inventory.Devices | Where-Object { $_.physical }) })
    $deploy = Read-WdvJson $Paths.DeploymentState
    $wuRes = Read-WdvJson $Config.windowsUpdate.resultFile
    $opsByKey = @{}
    foreach ($o in $ops) { $opsByKey[$o.deviceKey] = $o }
    $devOut = @()
    foreach ($d in $devices) {
        $op = $(if ($opsByKey.ContainsKey($d.key)) { $opsByKey[$d.key] } else { $null })
        $rec = $(if ($State.devices.ContainsKey($d.key)) { $State.devices[$d.key] } else { @{} })
        $e = ConvertTo-WdvPublicDevice $d
        $e.previousDriver = $(if ($op -and $op.status -eq 'Succeeded' -and $op.previousDriver) { $op.previousDriver } else { $null })
        $e.source = $(if ($op -and $op.source) { $op.source } else { 'existing' })
        $e.result = $(if ($op) { $op.status } elseif ($d.assessment.state -in 'Healthy', 'DisabledIntentionally') { 'Kept' } else { 'NotHandled' })
        $e.verification = $(if ($op) { $op.verification } elseif ($d.assessment.state -eq 'Healthy') { 'Verified' } else { 'NotVerified' })
        $e.rebootRequired = $(if ($op) { [bool] $op.rebootRequired } else { $d.assessment.state -eq 'RestartPending' })
        $e.errors = @(if ($op -and $op.status -in 'FailedPermanent', 'FailedRetryable') { "$($op.failureClass): $($op.reason)" })
        $e.manualAction = $(if ($op -and $op.manualAction) { $op.manualAction } else { $null })
        $e.optionalUpdate = $(if ($rec.ContainsKey('optionalUpdate')) { $rec.optionalUpdate } else { $null })
        $e.stateBeforeUpdates = $(if ($rec.ContainsKey('stateInitial')) { $rec['stateInitial'] } else { '' })
        $e.stateAfterUpdates = $(if ($rec.ContainsKey('stateAfterUpdates')) { $rec['stateAfterUpdates'] } else { '' })
        $devOut += , $e
    }
    $r = [ordered]@{}
    $r.format = $script:WdvResultFormat
    $r.version = 1
    $r.final = $Final
    $r.status = $Status
    $r.engineVersion = $script:WdvVersion
    $r.deploymentId = $(if ($deploy) { [string] $deploy['packageId'] } else { '' })
    $r.generatedUtc = (Get-WdvNow).ToString('o')
    $r.scanUtc = $(if ($Inventory) { $Inventory.CollectedUtc } else { $null })
    $ctx = $(if ($Inventory) { $Inventory.Context } else { $State.context })
    $sys = $(if ($Inventory) { $Inventory.System } else { $null })
    $r.system = [ordered]@{
        manufacturer = $(if ($ctx) { $ctx.Manufacturer } else { '' }); model = $(if ($ctx) { $ctx.Model } else { '' }); family = $(if ($sys) { $sys.Family } else { '' })
        portable = $(if ($ctx) { [bool] $ctx.Portable } else { $false }); virtual = $(if ($ctx) { [bool] $ctx.Virtual } else { $false }); architecture = $(if ($ctx) { $ctx.Architecture } else { '' })
        osBuild = $(if ($ctx) { $ctx.OsBuild } else { 0 }); biosVersion = $(if ($sys) { $sys.BiosVersion } else { '' }); processors = @(if ($sys) { @($sys.Processors | ForEach-Object { $_.Name }) })
    }
    if ($Config.expectedSystem -and $ctx -and ($Config.expectedSystem.model -and $Config.expectedSystem.model -ne $ctx.Model)) { $r.system.note = "The pre-installation inventory was taken on $($Config.expectedSystem.manufacturer) $($Config.expectedSystem.model); this computer is $($ctx.Manufacturer) $($ctx.Model)." }
    $r.windowsUpdate = [ordered]@{ partOfDeployment = [bool] $Config.windowsUpdate.enabled; driversAllowed = ($Config.windowsUpdate.drivers -eq 'include'); waitedForIt = [bool] ($Config.windowsUpdate.enabled -and $Config.policy.useWindowsUpdate); stageStatus = $(if ($wuRes) { [string] $wuRes['status'] } else { '' }); gate = $State.gate.reason }
    $r.inspections = @(foreach ($k in 'Initial', 'AfterUpdates', 'Final') { if ($State.inspections.ContainsKey($k)) { $State.inspections[$k] } })
    $r.summary = $(if ($Inventory) { Get-WdvCounts $Inventory.Devices } else { $null })
    $r.health = Get-WdvHealth $devices $ops
    $r.devices = $devOut
    $r.operations = @($ops | ForEach-Object { [ordered]@{ operationId = $_.operationId; device = $_.name; hardwareId = $_.hardwareId; status = $_.status; failureClass = $_.failureClass; source = $_.source; package = $(if ($_.package) { [ordered]@{ id = $_.package.id; inf = $_.package.inf; provider = $_.package.provider; version = $_.package.version } } else { $null }); attempts = [int] $_.totalAttempts; verification = $_.verification; rebootRequired = [bool] $_.rebootRequired; reason = $_.reason } })
    $r.manualActions = @($ops | Where-Object { $_.manualAction -and $_.status -notin 'Succeeded', 'AlreadySatisfied' } | ForEach-Object { [ordered]@{ operationId = $_.operationId; device = $_.name; text = $_.manualAction.text; url = $_.manualAction.url } })
    $r.unsupported = @($ops | Where-Object { $_.status -eq 'Unsupported' } | ForEach-Object { [ordered]@{ device = $_.name; instanceId = $_.publicInstanceId; reason = $_.reason } })
    $r.setupCritical = @($devices | Where-Object { $_.assessment.setupCritical } | ForEach-Object { [ordered]@{ device = $_.name; hardwareId = $(if (@($_.hardwareIds).Count) { $_.hardwareIds[0] } else { '' }); driver = $(if ($_.driver) { "$($_.driver.provider) $($_.driver.version) ($($_.driver.inf))" } else { '' }) } })
    $r.optionalApplications = @(if ($Inventory) { Get-WdvOptionalApplications $Inventory.Devices $Inventory.Context $Config.sources })
    $r.networkBootstrap = [ordered]@{ status = $State.network.status; detail = $State.network.detail; devices = @($State.network.devices) }
    $r.offlineBundle = [ordered]@{ status = $State.bundle.status; detail = $State.bundle.detail; packages = [int] $State.bundle.packages }
    $r.reboots = [int] $State.reboots
    $r.firmware = 'BIOS and firmware updates are never automated; check the manufacturer support page.'
    Write-WdvJson $Paths.Report $r
    return $r
}

function Complete-Wdv {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State, $Inventory, [string] $Status = '', [string] $Reason = '')
    $ops = @(Get-WdvOperationList $State)
    if (-not $Status) { $Status = Get-WdvStageStatus $ops }
    $report = Write-WdvReport $Config $Paths $State $Inventory $Status $true
    $outstanding = @($ops | Where-Object { $_.status -notin 'Succeeded', 'AlreadySatisfied' } | ForEach-Object { [ordered]@{ operationId = $_.operationId; name = $_.name; status = $_.status; failureClass = $_.failureClass; message = $_.reason } })
    if (-not $Reason) {
        $Reason = switch ($Status) {
            'Succeeded' { "Every device has a working driver ($(@($ops | Where-Object { $_.status -eq 'Succeeded' }).Count) installed, $(@($ops | Where-Object { $_.status -eq 'AlreadySatisfied' }).Count) resolved by Windows)." }
            'CompletedWithFollowUp' { "$($outstanding.Count) device(s) need a technician or a restart." }
            'CompletedWithFailures' { "$(@($ops | Where-Object { $_.status -like 'Failed*' }).Count) driver installation(s) failed." }
            default { 'The driver stage failed.' }
        }
    }
    $now = (Get-WdvNow).ToString('o')
    $result = [ordered]@{ status = $Status; reason = $Reason; engineVersion = $script:WdvVersion; startedUtc = $State.firstStartUtc; finishedUtc = $now; starts = [int] $State.starts; reboots = [int] $State.reboots
                          health = $report.health.status; installed = @($ops | Where-Object { $_.status -eq 'Succeeded' } | ForEach-Object { $_.name }); outstanding = $outstanding; report = $Paths.Report }
    Write-WdvJson $Paths.Result $result
    $State.final = $Status
    $State.phase = 'Finished'
    Save-WdvState $Paths $State
    if ($Status -ne 'Failed') {
        if (-not (Test-Path -LiteralPath $Paths.MarkerDir)) { New-Item -ItemType Directory -Path $Paths.MarkerDir -Force | Out-Null }
        Write-WdvJson $Paths.Marker ([ordered]@{ status = $Status; finishedUtc = $now; result = $Paths.Result })
    }
    Write-WdvLog "FINISHED: $Status. $Reason Health: $($report.health.status)." $(if ($Status -eq 'Succeeded') { 'INFO' } elseif ($Status -eq 'Failed') { 'ERROR' } else { 'WARN' })
    foreach ($o in $outstanding) { Write-WdvLog "  $($o.status)  $($o.name): $($o.message)" 'WARN' }
    $eventId = switch ($Status) { 'Succeeded' { 4100 } 'CompletedWithFollowUp' { 4101 } 'CompletedWithFailures' { 4102 } default { 4103 } }
    Write-WdvEvent $eventId "Driver setup finished: $Status. $Reason See $($Paths.Report)." $(if ($Status -eq 'Succeeded') { 'Information' } elseif ($Status -eq 'Failed') { 'Error' } else { 'Warning' })
    Set-WdvStatus $Status $Reason $State
    Unregister-WdvTask $Config
    return "Finished:$Status"
}

# ------------------------------------------------------------------------------------------------
# Main loop
# ------------------------------------------------------------------------------------------------

function Save-WdvInspection {
    param([hashtable] $Paths, [hashtable] $State, [hashtable] $Inventory, [string] $Stage)
    $file = Join-Path $Paths.Inventory ("inventory-{0}.json" -f $(switch ($Stage) { 'Initial' { 'initial' } 'AfterUpdates' { 'after-updates' } default { 'final' } }))
    Save-WdvInventory $Inventory $file
    $State.inspections[$Stage] = [ordered]@{ id = $Stage; atUtc = $Inventory.CollectedUtc; bootUtc = $Inventory.BootUtc; file = $file; counts = (Get-WdvCounts $Inventory.Devices) }
    $State.context = $Inventory.Context
    Update-WdvDeviceRecords $State $Inventory $Stage
    Write-WdvLog ("Inspection {0}: {1} device(s), {2} healthy, {3} basic driver, {4} missing, {5} malfunctioning, {6} restart pending, {7} possible hardware issue." -f $Stage, $State.inspections[$Stage].counts.devices, $State.inspections[$Stage].counts.healthy, $State.inspections[$Stage].counts.basicDriver, $State.inspections[$Stage].counts.driverMissing, $State.inspections[$Stage].counts.malfunctioning, $State.inspections[$Stage].counts.restartPending, $State.inspections[$Stage].counts.hardwareIssue)
}

function Invoke-WdvRun {
    param([hashtable] $Config, [hashtable] $Paths)
    $State = Read-WdvState $Paths
    if ($State.final) { Write-WdvLog "Already finished with status $($State.final); nothing to do."; Unregister-WdvTask $Config; return 'AlreadyFinished' }
    $first = -not $State.firstStartUtc
    if ($first) { $State.firstStartUtc = (Get-WdvNow).ToString('o') }
    $State.starts = [int] $State.starts + 1
    $State.policy = Get-WdvDeviceInstallPolicy
    Save-WdvState $Paths $State
    Write-WdvLog "==== Driver engine $($script:WdvVersion) start $($State.starts) (phase $($State.phase), restarts so far $($State.reboots)) ===="
    Set-WdvStatus 'Starting' "Start $($State.starts)" $State
    if ($first) {
        Write-WdvEvent 4000 'Hardware-aware driver setup started.'
        Write-WdvLog ("Policy: Windows Update first={0} (drivers {1}), verified sources={2}, offline packages={3}, optional replacements={4}; {5} verified package(s); bundle {6}." -f $Config.policy.useWindowsUpdate, $Config.windowsUpdate.drivers, $Config.policy.resolveMissing, $Config.policy.offlinePackages, $Config.policy.optionalReplacements, @($Config.verifiedPackages).Count, $(if ($Config.bundle) { $Config.bundle.folderName } else { 'none' }))
    }
    if ($State.policy.restricted) { Write-WdvLog "Device installation is restricted by organization policy ($($State.policy.detail)); devices are inspected and reported, nothing is installed." 'WARN' }
    $elapsed = ((Get-WdvNow) - (ConvertTo-WdvDate $State.firstStartUtc)).TotalHours
    $deadline = $elapsed -ge [double] $Config.maxRuntimeHours

    Resume-WdvOperations $Paths $State $Config

    if ($State.phase -eq 'New') {
        Set-WdvStatus 'Inspecting' 'Inspection before Windows Update' $State
        $inv = Get-WdvInventory $Config.sources 'Initial'
        Save-WdvInspection $Paths $State $inv 'Initial'
        Invoke-WdvBundleStaging $Config $Paths $State
        Update-WdvOperations $Config $Paths $State $inv -BeforeUpdates
        if ($Config.policy.networkBootstrap) { [void] (Invoke-WdvNetworkBootstrap $Config $Paths $State $inv) }
        $State.phase = 'WaitingForUpdates'
        Save-WdvState $Paths $State
        [void] (Write-WdvReport $Config $Paths $State $inv 'InProgress' $false)
    }

    if ($State.phase -eq 'WaitingForUpdates') {
        if ($State.bundle.status -in 'NotFound', 'Invalid') { Invoke-WdvBundleStaging $Config $Paths $State }
        if ($State.network.status -eq 'NetworkDriverMissing' -and $Config.policy.networkBootstrap) {
            $inv = Get-WdvInventory $Config.sources 'Initial'
            [void] (Invoke-WdvNetworkBootstrap $Config $Paths $State $inv)
        }
        $gate = Get-WdvUpdatesGate $Config $State
        $State.gate = @{ open = [bool] $gate.Open; reason = $gate.Reason; atUtc = (Get-WdvNow).ToString('o') }
        if (-not $gate.Open -and -not $deadline) {
            Save-WdvState $Paths $State
            Set-WdvStatus $(if ($State.network.status -eq 'NetworkDriverMissing') { 'WaitingForNetwork' } else { 'WaitingForWindowsUpdate' }) $(if ($State.network.status -eq 'NetworkDriverMissing') { $State.network.detail } else { $gate.Reason }) $State
            Write-WdvLog $gate.Reason
            return 'WaitingForWindowsUpdate'
        }
        Write-WdvLog "Gate open: $($gate.Reason)" $(if ($gate.ContainsKey('Warn') -and $gate.Warn) { 'WARN' } else { 'INFO' })
        $State.phase = 'Inspecting'
        Save-WdvState $Paths $State
    }

    if ($State.phase -eq 'Inspecting') {
        # Inspection B only after the restart Windows Update (or a driver it installed) needs.
        if ((Test-WdvSystemRebootPending) -or (Test-WdbRestartPending $Config.dataRoot)) {
            $rr = Request-WdvReboot $Config $Paths $State 'a restart is pending after Windows Update; devices are inspected again after it'
            if ($rr -in 'Rebooting', 'RebootDeferred') { return $rr }
        }
        Set-WdvStatus 'Inspecting' 'Inspection after Windows Update' $State
        $inv = Get-WdvInventory $Config.sources 'AfterUpdates'
        Save-WdvInspection $Paths $State $inv 'AfterUpdates'
        if (@($inv.Devices | Where-Object { $_.physical -and $_.assessment.state -eq 'RestartPending' }).Count -and [int] $State.reboots -lt [int] $Config.maxReboots) {
            $rr = Request-WdvReboot $Config $Paths $State 'devices are waiting for a restart to start their new drivers'
            if ($rr -in 'Rebooting', 'RebootDeferred') { return $rr }
        }
        Update-WdvOperations $Config $Paths $State $inv
        $State.phase = 'Resolving'
        Save-WdvState $Paths $State
        [void] (Write-WdvReport $Config $Paths $State $inv 'InProgress' $false)
    }

    if ($State.phase -eq 'Resolving') {
        $inv = Get-WdvInventory $Config.sources 'AfterUpdates'
        if (-not $deadline) {
            Set-WdvStatus 'Resolving' 'Installing verified drivers where needed' $State
            $State.passes = [int] $State.passes + 1
            $res = Invoke-WdvResolution $Config $Paths $State $inv
            Save-WdvState $Paths $State
            if ($res -eq 'WaitingForLock') { Set-WdvStatus 'WaitingForLock' 'Another installation is running.' $State; return 'WaitingForLock' }
        }
        $State.phase = 'Verifying'
        Save-WdvState $Paths $State
        if (@(Get-WdvOperationList $State | Where-Object { $_.status -eq 'WaitingForReboot' }).Count) {
            $rr = Request-WdvReboot $Config $Paths $State 'installed drivers need a restart before they can be verified'
            if ($rr -in 'Rebooting', 'RebootDeferred') { return $rr }
        }
    }

    if ($State.phase -eq 'Verifying') {
        Set-WdvStatus 'Verifying' 'Checking every device again' $State
        Resume-WdvOperations $Paths $State $Config
        $inv = Get-WdvInventory $Config.sources 'Final'
        Save-WdvInspection $Paths $State $inv 'Final'
        # A retryable failure gets another pass while time and passes remain.
        $retry = @(Get-WdvOperationList $State | Where-Object { $_.status -in 'FailedRetryable', 'WaitingForNetwork' -or ($_.status -eq 'Pending' -and -not $_.waitingFor) })
        if ($retry.Count -and [int] $State.passes -lt 3 -and -not $deadline) {
            $State.phase = 'Resolving'
            Save-WdvState $Paths $State
            [void] (Write-WdvReport $Config $Paths $State $inv 'InProgress' $false)
            Set-WdvStatus 'Resolving' "$($retry.Count) operation(s) will be tried again" $State
            return 'RetryLater'
        }
        foreach ($op in $retry) {
            if ($op.status -eq 'WaitingForNetwork') { $op.manualAction = @{ text = "$($op.name): the verified package could not be downloaded (no network)."; url = '' }; Set-WdvOperation $op 'ManualActionRequired' 'No network to download the verified package.' 'Manual' }
            elseif ($op.status -eq 'Pending') { Set-WdvOperation $op 'ManualActionRequired' 'Not resolved before the stage ended.' 'Manual' }
        }
        return (Complete-Wdv $Config $Paths $State $inv $(if ($deadline -and @(Get-WdvOperationList $State | Where-Object { $_.status -eq 'Running' }).Count) { 'Failed' } else { '' }))
    }
    if ($deadline) {
        $inv = Get-WdvInventory $Config.sources 'Final'
        Save-WdvInspection $Paths $State $inv 'Final'
        return (Complete-Wdv $Config $Paths $State $inv)
    }
    return 'InProgress'
}

function Enter-WdvMutex {
    $m = New-Object System.Threading.Mutex($false, 'Global\WindowsDeploymentBuilder-Drivers')
    try { if ($m.WaitOne([TimeSpan]::FromSeconds(10))) { return $m } } catch [System.Threading.AbandonedMutexException] { return $m }
    $m.Dispose()
    return $null
}

function Exit-WdvMutex { param($Mutex) if ($Mutex) { try { $Mutex.ReleaseMutex() } catch { }; $Mutex.Dispose() } }

function Initialize-WdvLogging {
    param([hashtable] $Paths)
    foreach ($d in $Paths.Root, $Paths.Logs, $Paths.Packages) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
    $script:WdvLogFile = $Paths.Log
    $script:WdvStatusFile = $Paths.Status
    if ((Test-Path -LiteralPath $Paths.Log) -and (Get-Item -LiteralPath $Paths.Log).Length -gt 5MB) { Move-Item -LiteralPath $Paths.Log -Destination "$($Paths.Log).1" -Force }
}

function Invoke-WdvMain {
    param([hashtable] $Config)
    $paths = Get-WdvPaths $Config
    Initialize-WdvLogging $paths
    $mutex = Enter-WdvMutex
    if (-not $mutex) { Write-WdvLog 'Another driver engine instance is running; exiting.'; return 'Busy' }
    try {
        try { return (Invoke-WdvRun $Config $paths) }
        catch {
            Write-WdvLog "Unexpected error: $($_.Exception.Message) $($_.ScriptStackTrace)" 'ERROR'
            $State = Read-WdvState $paths
            $State.errors = [int] $State.errors + 1
            Save-WdvState $paths $State
            if ([int] $State.errors -ge 3) { return (Complete-Wdv $Config $paths $State $null 'Failed' "The driver engine failed repeatedly: $($_.Exception.Message)") }
            return 'Error'
        }
    } finally { Exit-WdvMutex $mutex }
}

# ------------------------------------------------------------------------------------------------
# Technician recovery: Retry and AddPackages
# ------------------------------------------------------------------------------------------------

<#
    Reopens driver operations for another run. FailedRetryable (and, with -IncludePermanent,
    FailedPermanent and ManualActionRequired) operations become Pending again. Integrity and
    signature failures are never reopened: the package must be replaced first. A device whose
    driver installation broke it is reopened only with -IncludePermanent.
#>
function Invoke-WdvRetry {
    param([hashtable] $Config, [string[]] $Operations = @(), [switch] $AllFailed, [switch] $IncludePermanent, [string] $RequestedBy = '')
    $paths = Get-WdvPaths $Config
    Initialize-WdvLogging $paths
    $mutex = Enter-WdvMutex
    if (-not $mutex) { return @{ Outcome = 'Busy'; Message = 'The driver engine is running; try again in a minute.'; Accepted = @(); Refused = @() } }
    try {
        $State = Read-WdvState $paths
        $accepted = @(); $refused = @()
        $targets = @(Get-WdvOperationList $State | Where-Object { $AllFailed -or ($Operations -contains $_.operationId) })
        foreach ($id in @($Operations | Where-Object { -not $State.operations.ContainsKey($_) })) { $refused += @{ operationId = $id; reason = 'unknown driver operation' } }
        foreach ($op in $targets) {
            $reopen = $op.status -eq 'FailedRetryable' -or ($IncludePermanent -and $op.status -in 'FailedPermanent', 'ManualActionRequired', 'Unsupported')
            if ($op.failureClass -in $script:WdvSecurityClasses) { $refused += @{ operationId = $op.operationId; reason = "$($op.failureClass) failure: replace the package with a correctly signed, unmodified one first" }; continue }
            if (-not $reopen) { if (-not $AllFailed) { $refused += @{ operationId = $op.operationId; reason = "status $($op.status)$(if ($op.status -like 'Failed*' -or $op.status -eq 'ManualActionRequired') { '; use -IncludePermanent after fixing the cause' })" } }; continue }
            $op.attempts = 0; $op.networkDeferrals = 0; $op.nextAttemptUtc = $null; $op.waitingFor = ''
            if ($State.devices.ContainsKey($op.deviceKey)) { $State.devices[$op.deviceKey].blocked = $false }
            Set-WdvOperation $op 'Pending' "Reopened by $RequestedBy." ''
            Add-WdvAttempt $paths $op @{ trigger = 'technician'; result = 'Pending'; message = "reopened by $RequestedBy" }
            $accepted += $op.operationId
        }
        if ($accepted.Count) {
            foreach ($f in $paths.Result, $paths.Marker) { if (Test-Path -LiteralPath $f) { Move-Item -LiteralPath $f -Destination "$f.$((Get-WdvNow).ToString('yyyyMMddHHmmss')).bak" -Force } }
            $State.final = $null; $State.phase = 'Resolving'; $State.passes = 0; $State.errors = 0
            $State.firstStartUtc = (Get-WdvNow).ToString('o')
            Save-WdvState $paths $State
            Write-WdvLog "Technician retry by $RequestedBy`: $($accepted -join ', ')."
        }
        return @{ Outcome = $(if ($accepted.Count) { 'Accepted' } elseif ($refused.Count) { 'Refused' } else { 'NothingToDo' }); Message = "Reopened: $(if ($accepted.Count) { $accepted -join ', ' } else { 'none' })."; Accepted = $accepted; Refused = $refused }
    } finally { Exit-WdvMutex $mutex }
}

<#
    Technician-supplied INF packages (for example a network driver on a USB stick when the computer
    has no network). Every INF must be Microsoft-signed (WHQL/attestation) and readable; the files
    are copied to packages\technician\<id> and checked again. Then every unresolved operation
    (including a missing network driver) is reopened so the next run considers them.
#>
function Add-WdvTechnicianPackages {
    param([hashtable] $Config, [string] $Source, [string] $RequestedBy = '')
    $paths = Get-WdvPaths $Config
    Initialize-WdvLogging $paths
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return @{ Outcome = 'Refused'; Message = "Folder not found: $Source"; Added = @(); Refused = @() } }
    $mutex = Enter-WdvMutex
    if (-not $mutex) { return @{ Outcome = 'Busy'; Message = 'The driver engine is running; try again in a minute.'; Added = @(); Refused = @() } }
    try {
        $State = Read-WdvState $paths
        $added = @(); $refused = @()
        foreach ($inf in @(Get-ChildItem -LiteralPath $Source -Recurse -File -Filter '*.inf' | Where-Object { $_.Name -ne 'autorun.inf' } | Select-Object -First 50)) {
            try {
                $pe = Get-WdvPackageEntry $inf.FullName $inf.DirectoryName '' $Config.sources
                if ($pe.Info.Problems.Count) { $refused += @{ inf = $inf.Name; reason = ($pe.Info.Problems -join '; ') }; continue }
                if (-not $pe.Signature.Ok) { $refused += @{ inf = $inf.Name; reason = $pe.Signature.Reason }; continue }
                $dest = Join-Path (Join-Path $paths.Packages 'technician') $pe.Entry.id
                if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                foreach ($f in $pe.Entry.files) {
                    $to = Join-Path $dest ($f.path -replace '/', '\')
                    $d = Split-Path -Parent $to
                    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
                    Copy-Item -LiteralPath (Join-Path $inf.DirectoryName ($f.path -replace '/', '\')) -Destination $to -Force
                    if ((Get-WdvFileHash $to) -ne $f.sha256) { throw "copy of $($f.path) does not match" }
                }
                $pe.Entry.folder = ''
                $State.technicianPackages = @(@($State.technicianPackages | Where-Object { $_.id -ne $pe.Entry.id }) + @(@{ id = $pe.Entry.id; root = $dest; inf = (Join-Path $dest ($pe.Entry.inf -replace '/', '\')); entry = $pe.Entry; addedUtc = (Get-WdvNow).ToString('o'); by = $RequestedBy }))
                $added += "$($inf.Name) ($($pe.Info.Provider) $($pe.Info.Version))"
            } catch { $refused += @{ inf = $inf.Name; reason = $_.Exception.Message } }
        }
        if ($added.Count) {
            foreach ($op in @(Get-WdvOperationList $State | Where-Object { $_.status -in 'ManualActionRequired', 'Unsupported', 'Pending', 'WaitingForNetwork' -and $_.failureClass -notin 'DeviceFailure', 'Policy' })) {
                $op.attempts = 0; $op.waitingFor = ''
                Set-WdvOperation $op 'Pending' "Reconsidered with technician packages ($RequestedBy)." ''
            }
            foreach ($f in $paths.Result, $paths.Marker) { if (Test-Path -LiteralPath $f) { Move-Item -LiteralPath $f -Destination "$f.$((Get-WdvNow).ToString('yyyyMMddHHmmss')).bak" -Force } }
            $State.final = $null
            if ($State.phase -in 'Finished', 'Verifying') { $State.phase = 'Resolving'; $State.passes = 0 }
            if ($State.phase -eq 'New') { $State.phase = 'New' }
            $State.firstStartUtc = $(if ($State.firstStartUtc) { $State.firstStartUtc } else { (Get-WdvNow).ToString('o') })
            Save-WdvState $paths $State
            Write-WdvLog "Technician packages added by $RequestedBy`: $($added -join ', ')."
        }
        return @{ Outcome = $(if ($added.Count) { 'Accepted' } else { 'Refused' }); Message = "Added: $(if ($added.Count) { $added -join ', ' } else { 'none' })."; Added = $added; Refused = $refused }
    } finally { Exit-WdvMutex $mutex }
}

# ------------------------------------------------------------------------------------------------
# Read-only tools: Inspect, Plan; bundle tools: Export, Bundle, ValidateBundle
# ------------------------------------------------------------------------------------------------

<# Identification data: from the deployment configuration, else driver-sources.json next to this script. #>
function Get-WdvSources {
    param([string] $ConfigPath)
    if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) { return (Get-WdvConfig $ConfigPath).sources }
    $cfg = Join-Path $PSScriptRoot 'drivers-config.json'
    if (Test-Path -LiteralPath $cfg) { return (Get-WdvConfig $cfg).sources }
    $s = Read-WdvJson (Join-Path $PSScriptRoot 'driver-sources.json')
    if ($s -isnot [hashtable] -or $s.format -ne 'windows-deployment-builder/driver-sources') { throw 'driver-sources.json (identification data) is missing next to DriverEngine.ps1.' }
    return $s
}

<#
    The shareable hardware inventory (website import): the computer, every physical device with its
    identifiers, driver and assessment. No serial numbers, UUIDs, MAC addresses, user or computer
    names; instance ids carry a hash instead of their instance-specific part.
#>
function ConvertTo-WdvPublicInventory {
    param([hashtable] $Inventory, [hashtable] $Sources)
    $sys = $Inventory.System
    $ctx = $Inventory.Context
    $phys = @($Inventory.Devices | Where-Object { $_.physical })
    $o = [ordered]@{}
    $o.format = $script:WdvInventoryFormat
    $o.formatVersion = 1
    $o.inventoryId = [guid]::NewGuid().ToString('N').Substring(0, 16)
    $o.collectedUtc = $Inventory.CollectedUtc
    $o.tool = [ordered]@{ name = 'DriverEngine.ps1'; version = $script:WdvVersion }
    $sysOut = [ordered]@{}
    $sysOut.manufacturer = $ctx.Manufacturer
    $sysOut.model = $ctx.Model
    $sysOut.family = [string] $sys.Family
    $sysOut.boardManufacturer = [string] $sys.BoardManufacturer
    $sysOut.boardProduct = [string] $sys.BoardProduct
    $sysOut.biosVersion = [string] $sys.BiosVersion
    $sysOut.portable = [bool] $ctx.Portable
    $sysOut.virtual = [bool] $ctx.Virtual
    $sysOut.architecture = $ctx.Architecture
    $sysOut.osCaption = [string] $sys.OsCaption
    $sysOut.osBuild = [string] $sys.OsBuild
    $sysOut.processors = @($sys.Processors | ForEach-Object { [string] $_.Name })
    $sysOut.oem = $(if ($ctx.Oem) { [string] $ctx.Oem.id } else { '' })
    $o.system = $sysOut
    $o.devices = @($phys | ForEach-Object { ConvertTo-WdvPublicDevice $_ })
    $o.summary = Get-WdvCounts $Inventory.Devices
    $o.setupCritical = @($phys | Where-Object { $_.assessment.setupCritical } | ForEach-Object { $_.key })
    $o.optionalApplications = @(Get-WdvOptionalApplications $Inventory.Devices $ctx $Sources)
    $o.notice = 'Collected on this computer by a read-only scan. The deployment inspects the hardware again on the installed computer and decides from that.'
    return $o
}

function Format-WdvInventory {
    param([hashtable] $Inventory, [object[]] $Decisions = @())
    $l = New-Object System.Collections.Generic.List[string]
    $ctx = $Inventory.Context
    $l.Add("Hardware inventory: $($ctx.Manufacturer) $($ctx.Model) ($($ctx.Architecture), Windows build $($ctx.OsBuild)$(if ($ctx.Portable) { ', portable' })$(if ($ctx.Virtual) { ', virtual machine' }))")
    $l.Add(('{0,-44} {1,-16} {2,-16} {3,-20} {4}' -f 'Device', 'Category', 'State', 'Action', 'Driver'))
    $byKey = @{}
    foreach ($d in $Decisions) { $byKey[$d.Key] = $d }
    foreach ($d in @($Inventory.Devices | Where-Object { $_.physical } | Sort-Object { $_.category }, { $_.name })) {
        $drv = $(if ($d.driver) { "$($d.driver.provider) $($d.driver.version)" } else { '(none)' })
        $name = $(if ($d.name.Length -gt 43) { $d.name.Substring(0, 43) } else { $d.name })
        $l.Add(('{0,-44} {1,-16} {2,-16} {3,-20} {4}' -f $name, $d.category, $d.assessment.state, $d.assessment.action, $drv))
        if ($byKey.ContainsKey($d.key) -and $byKey[$d.key].Kind -notin 'Keep') { $l.Add("    -> $($byKey[$d.key].Kind): $($byKey[$d.key].Reason)") }
    }
    $c = Get-WdvCounts $Inventory.Devices
    $l.Add("Total $($c.devices): $($c.healthy) healthy, $($c.basicDriver) basic driver, $($c.driverMissing) missing, $($c.malfunctioning) malfunctioning, $($c.restartPending) restart pending, $($c.hardwareIssue) possible hardware issue, $($c.disabled) disabled.")
    return ($l -join "`r`n")
}

<# Read-only plan: what the deployment would decide for this computer with this configuration. #>
function Invoke-WdvPlan {
    param([hashtable] $Config)
    $paths = Get-WdvPaths $Config
    $State = New-WdvState
    $inv = Get-WdvInventory $Config.sources 'Plan'
    $State.context = $inv.Context
    $packages = @(Get-WdvPackages $Config $paths $State)
    $decisions = @()
    foreach ($d in @($inv.Devices | Where-Object { $_.physical })) {
        $dec = Get-WdvDecision $d $packages $Config $inv.Context
        $decisions += , @{ Key = $d.key; Kind = $dec.Kind; Reason = $(if ($dec.Manual) { $dec.Manual.text } else { $dec.Reason }) }
    }
    return @{ Inventory = $inv; Decisions = $decisions; Text = (Format-WdvInventory $inv $decisions) }
}

function Test-WdvElevated {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

<#
    Exports the driver store's third-party packages (pnputil /export-driver * <temp>) and builds a
    verified bundle from them. Only copies files; nothing on this computer changes. Vendor
    applications are not part of the driver store and therefore not part of the export.
#>
function Invoke-WdvExport {
    param([hashtable] $Sources, [string] $Destination)
    if (-not (Test-WdvElevated)) { throw 'Export needs administrator rights (pnputil /export-driver).' }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("wdb-driver-export-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $r = Invoke-WdvPnpUtil @('/export-driver', '*', $tmp)
        if ($r.ExitCode -ne 0 -and -not @(Get-ChildItem -LiteralPath $tmp -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue).Count) { throw "pnputil /export-driver returned $($r.ExitCode)." }
        return (New-WdvBundle $tmp $Destination 'driverStoreExport' $Sources (Get-WdvSystem))
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------------------

if ($script:WdvMain -and $script:WdvArgs.Mode -ne 'Library') {
    $a = $script:WdvArgs
    switch ($a.Mode) {
        'Run' {
            $config = Get-WdvConfig $a.ConfigPath
            if (-not (Test-WdvElevated)) { Write-Output 'The driver engine must run elevated (normally as SYSTEM from its scheduled task).'; exit 4 }
            $r = Invoke-WdvMain $config
            Write-Output $r
            exit 0
        }
        'Inspect' {
            $sources = Get-WdvSources $a.ConfigPath
            $inv = Get-WdvInventory $sources 'Inspect'
            Write-Output (Format-WdvInventory $inv)
            if ($a.OutputPath) {
                $doc = ConvertTo-WdvPublicInventory $inv $sources
                Write-WdvJson $a.OutputPath $doc
                Write-Output "Inventory written to $($a.OutputPath). Import it under Hardware & Drivers in Windows Deployment Builder."
            }
            exit 0
        }
        'Plan' {
            $config = Get-WdvConfig $a.ConfigPath
            $p = Invoke-WdvPlan $config
            Write-Output $p.Text
            if ($a.OutputPath) { Write-WdvJson $a.OutputPath (ConvertTo-WdvPublicInventory $p.Inventory $config.sources) }
            exit 0
        }
        'Export' {
            if (-not $a.OutputPath) { Write-Output 'Use -OutputPath <folder> (for example E:\WindowsDeployment\drivers).'; exit 2 }
            $b = Invoke-WdvExport (Get-WdvSources $a.ConfigPath) $a.OutputPath
            Write-Output "Bundle $($b.FolderName): $($b.Packages) package(s), $(@($b.Refused).Count) refused. drivers-manifest.json SHA-256 $($b.Sha256)"
            foreach ($x in @($b.Refused)) { Write-Output "  refused $($x.inf): $($x.reason)" }
            Write-Output "Attach $($b.Folder)\drivers-manifest.json under Hardware & Drivers in Windows Deployment Builder."
            exit 0
        }
        'Bundle' {
            if (-not $a.Path -or -not $a.OutputPath) { Write-Output 'Use -Path <folder with INF driver packages> -OutputPath <destination folder>.'; exit 2 }
            $sources = Get-WdvSources $a.ConfigPath
            $sys = $(try { Get-WdvSystem } catch { @{ Manufacturer = ''; Model = ''; OsBuild = ''; Architecture = '' } })
            $b = New-WdvBundle $a.Path $a.OutputPath 'technicianFolder' $sources $sys
            Write-Output "Bundle $($b.FolderName): $($b.Packages) package(s), $(@($b.Refused).Count) refused. drivers-manifest.json SHA-256 $($b.Sha256)"
            foreach ($x in @($b.Refused)) { Write-Output "  refused $($x.inf): $($x.reason)" }
            exit 0
        }
        'ValidateBundle' {
            if (-not $a.Path) { Write-Output 'Use -Path <bundle folder> [-ExpectedSha256 <hash>].'; exit 2 }
            $v = Test-WdvBundle $a.Path $a.ExpectedSha256 '' (Get-WdvSources $a.ConfigPath)
            Write-Output "$(if ($v.Ok) { 'VALID' } else { 'INVALID' }): $(@($v.Packages).Count) usable package(s); SHA-256 $($v.Sha256)"
            foreach ($p in @($v.Problems)) { Write-Output "  $p" }
            if ($v.Ok) { exit 0 }
            exit 1
        }
        'AddPackages' {
            if (-not (Test-WdvElevated)) { Write-Output 'Run as administrator.'; exit 4 }
            $config = Get-WdvConfig $a.ConfigPath
            $r = Add-WdvTechnicianPackages $config $a.Path $(if ($a.RequestedBy) { $a.RequestedBy } else { [Security.Principal.WindowsIdentity]::GetCurrent().Name })
            Write-Output "$($r.Outcome): $($r.Message)"
            foreach ($x in @($r.Refused)) { Write-Output "  refused $($x.inf): $($x.reason)" }
            if ($r.Outcome -eq 'Accepted') { exit 0 }
            exit 1
        }
        'Retry' {
            if (-not (Test-WdvElevated)) { Write-Output 'Run as administrator.'; exit 4 }
            $config = Get-WdvConfig $a.ConfigPath
            $r = Invoke-WdvRetry $config -Operations $a.Operation -AllFailed:$a.AllFailed -IncludePermanent:$a.IncludePermanent -RequestedBy $(if ($a.RequestedBy) { $a.RequestedBy } else { [Security.Principal.WindowsIdentity]::GetCurrent().Name })
            Write-Output "$($r.Outcome): $($r.Message)"
            foreach ($x in @($r.Refused)) { Write-Output "  refused $($x.operationId): $($x.reason)" }
            if ($r.Outcome -in 'Accepted', 'NothingToDo') { exit 0 }
            exit 1
        }
    }
}
