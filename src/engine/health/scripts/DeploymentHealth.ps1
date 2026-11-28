#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Deployment Builder - deployment verification and health reports (Phase 9).

.DESCRIPTION
    Checks what this deployment was meant to achieve (health-config.json, the deployment manifest)
    against the installed Windows itself, and reads the engines' own results only as evidence:
    a stage that reported success is still checked (the application is looked up in Windows'
    uninstall records and Store packages, the device's problem code is read, the account and its
    groups are read, Defender and the firewall are asked).

    Verification is READ-ONLY. It never installs, removes, restarts, deletes, resets or changes a
    setting. It writes only its own reports below <dataRoot>\reports\health:
        deployment-health.json   every finding with expected and observed state, evidence, next action
        technician-report.html   the dashboard (offline; print or save as PDF)
        technician-report.txt    the same findings as plain text (Windows Update, devices, Office,
                                 manufacturer software recommendations, applications)
        customer-handoff.html    plain summary for the person receiving the computer
        history\                 earlier reports (the record of a failed deployment is never lost)

    Health engine 1.1.0 also audits, read-only: the Windows Update state the update engine (2.1.0)
    recorded, its policy and final Settings refresh, every Retry Windows Update run, which original
    update failures were installed later (retry results or Windows Update history), devices the
    deployment reported with problems compared with Device Manager now, Microsoft Office
    (Click-to-Run registry, activation as the activation stage recorded it) and optional
    manufacturer utilities (recommendations only; nothing is ever installed by this check).

    Health engine 1.2.0 verifies applications with the same evidence as the application engine
    (1.6.0; the catalog's "verify" block in health-config.json): uninstall records by display-name
    prefix (machine-wide 64- and 32-bit, and the deployment user's own when that user's registry is
    loaded; hives are never loaded), Store packages (registered for the user, or provisioned), files
    (also below the deployment user's profile, never SYSTEM's) and registry values. The engine's
    outcome is shown as history beside the evidence found now. Nothing is "installed" without
    evidence, and nothing is "missing" only because a machine-wide uninstall record is absent: per-
    user evidence that cannot be read yet is reported as pending. Visual C++ runtimes are listed by
    family and architecture (x86 and x64 separately).

    It can run at any time later, without replaying the deployment:
        powershell.exe -ExecutionPolicy Bypass -File C:\ProgramData\WindowsDeploymentBuilder\Package\scripts\health\DeploymentHealth.ps1 -Mode Verify
        ... -Mode Dashboard   (verifies, then opens the technician report)

      -Mode Verify            (default) verify and write the reports; exit code = overall state
      -Mode Dashboard         verify, then open the technician report
      -Mode CleanupBackups    list the retained settings backup; with -ConfirmCleanup <backup id>
                              remove it (only when no restoration is outstanding; never the USB copy)
      -Mode ExportDiagnostics a sanitized ZIP (no backups, no answer files, no passwords)
      -ScanUpdates            also ask Windows Update which updates are still available (read-only)
      -CheckAppUpdates        also list WinGet updates of the selected applications (read-only
                              "winget upgrade"; WinGet lists per user, so not possible as SYSTEM)

    Exit codes (Verify): 0 Ready, 10 ReadyWithWarnings, 20 NeedsAttention, 30 Incomplete,
    50 Unverifiable, 60 Failed. Other modes: 0 done, 1 refused or nothing to do, 4 needs elevation.

    Everything that reads the system is a small adapter function (Get-Wdh*), so the scenario tests
    replace them with simulated computers. Windows PowerShell 5.1; StrictMode 2.0.
#>
[CmdletBinding()]
param(
    [ValidateSet('Verify', 'Dashboard', 'CleanupBackups', 'ExportDiagnostics', 'Library')]
    [string] $Mode = 'Verify',
    [ValidateSet('Technician', 'DeploymentComplete', 'Startup', 'Recovery', 'Test')]
    [string] $Trigger = 'Technician',
    [switch] $ScanUpdates,
    [switch] $CheckAppUpdates,
    [switch] $Json,
    [string] $ConfirmCleanup = '',
    [string] $OutputPath = '',
    [switch] $Elevate
)

$script:WdhMain = $MyInvocation.InvocationName -ne '.' -and $Mode -ne 'Library'
# Captured first: the shared functions dot-sourced below bind their own parameters in this scope.
$script:WdhArgs = @{ Mode = $Mode; Trigger = $Trigger; ScanUpdates = [bool] $ScanUpdates; CheckAppUpdates = [bool] $CheckAppUpdates; Json =[bool] $Json; ConfirmCleanup = $ConfirmCleanup; OutputPath = $OutputPath; Elevate = [bool] $Elevate }
if (-not (Get-Command Read-WddManifest -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot '..\common\DeploymentCommon.ps1') }
Set-StrictMode -Version 2.0

$script:WdhVersion = '1.2.0'
$script:WdhScriptRoot = $PSScriptRoot
$script:WdhStates = @('Ready', 'ReadyWithWarnings', 'NeedsAttention', 'Incomplete', 'Unverifiable', 'Failed')
$script:WdhExitCodes = @{ Ready = 0; ReadyWithWarnings = 10; NeedsAttention = 20; Incomplete = 30; Unverifiable = 50; Failed = 60 }
$script:WdhCategoryRank = @{ Verified = 0; Warning = 1; NeedsAttention = 2; Incomplete = 3; Unverifiable = 4; Failed = 5 }
$script:WdhCategoryNames = [ordered]@{
    windows = 'Windows'; accounts = 'Accounts and identity'; updates = 'Windows Update'; drivers = 'Hardware and drivers'; applications = 'Applications'
    restoration = 'Restored settings'; security = 'Security'; network = 'Network'; storage = 'Storage'; customizations = 'Windows settings'; hardwareSoftware = 'Manufacturer software'; recovery = 'Recovery and outstanding work'
}
# Windows' own documented device problem codes (CM_PROB_*), in words.
$script:WdhProblemCodes = @{
    1 = 'not configured correctly'; 3 = 'driver may be corrupted or memory is low'; 10 = 'cannot start'; 12 = 'not enough free resources'; 14 = 'needs a restart to work'
    18 = 'drivers must be reinstalled'; 19 = 'configuration in the registry is damaged'; 21 = 'being removed'; 22 = 'disabled'; 24 = 'not present, not working or missing drivers'
    28 = 'no driver installed'; 29 = 'disabled by the firmware'; 31 = 'not working properly (driver could not be loaded)'; 32 = 'driver service disabled'; 37 = 'driver failed to initialize'
    39 = 'driver is corrupted or missing'; 40 = 'driver registry entry is damaged'; 41 = 'driver loaded but the hardware was not found'; 43 = 'the device reported a problem'
    45 = 'not connected'; 47 = 'prepared for safe removal'; 48 = 'driver blocked'; 52 = 'driver signature could not be verified'
}
$script:WdhHardwareCodes = @(10, 12, 24, 29, 41, 43)
$script:WdhNow = $null

# ------------------------------------------------------------------------------------------------
# Adapters: read-only observations of the computer (replaced by the scenario tests)
# ------------------------------------------------------------------------------------------------

function Get-WdhRegValue {
    param([ValidateSet('HKLM', 'HKU')] [string] $Root, [string] $SubKey, [string] $Name, [string] $Sid = '')
    $base = $(if ($Root -eq 'HKLM') { [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64) } else { [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users, [Microsoft.Win32.RegistryView]::Registry64) })
    try {
        $path = $(if ($Root -eq 'HKU') { "$Sid\$SubKey" } else { $SubKey })
        $k = $base.OpenSubKey($path)
        if (-not $k) { return $null }
        try { return $k.GetValue($Name, $null) } finally { $k.Close() }
    } finally { $base.Close() }
}

function Test-WdhRegKey {
    param([ValidateSet('HKLM', 'HKU')] [string] $Root, [string] $SubKey, [string] $Sid = '')
    $base = $(if ($Root -eq 'HKLM') { [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64) } else { [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users, [Microsoft.Win32.RegistryView]::Registry64) })
    try {
        $k = $base.OpenSubKey($(if ($Root -eq 'HKU') { "$Sid\$SubKey" } else { $SubKey }))
        if ($k) { $k.Close(); return $true }
        return $false
    } finally { $base.Close() }
}

function Get-WdhOsInfo {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $cv = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    @{
        caption        = [string] $os.Caption
        editionId      = [string] (Get-WdhRegValue 'HKLM' $cv 'EditionID')
        displayVersion = [string] (Get-WdhRegValue 'HKLM' $cv 'DisplayVersion')
        build          = [int] (Get-WdhRegValue 'HKLM' $cv 'CurrentBuildNumber')
        ubr            = [int] (Get-WdhRegValue 'HKLM' $cv 'UBR')
        architecture   = ([string] [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'Machine')).ToLowerInvariant()
        productType    = [int] $os.ProductType
        lastBootUtc    = $os.LastBootUpTime.ToUniversalTime().ToString('o')
    }
}

function Get-WdhSetupState {
    @{
        imageState            = [string] (Get-WdhRegValue 'HKLM' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' 'ImageState')
        oobeInProgress        = [int] (Get-WdhRegValue 'HKLM' 'SYSTEM\Setup' 'OOBEInProgress')
        systemSetupInProgress = [int] (Get-WdhRegValue 'HKLM' 'SYSTEM\Setup' 'SystemSetupInProgress')
    }
}

<# Windows licence state only: the product key is never read. #>
function Get-WdhActivation {
    $p = @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -Property LicenseStatus, Name, Description -ErrorAction Stop)
    if (-not $p.Count) { return @{ available = $true; licenseStatus = -1; channel = '' } }
    $x = $p[0]
    @{ available = $true; licenseStatus = [int] $x.LicenseStatus; channel = $(if ([string] $x.Description -match '(RETAIL|OEM|VOLUME)') { $Matches[1] } else { '' }) }
}

function Get-WdhComputerNames {
    @{
        active  = [string] (Get-WdhRegValue 'HKLM' 'SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' 'ComputerName')
        pending = [string] (Get-WdhRegValue 'HKLM' 'SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' 'ComputerName')
    }
}

function Get-WdhLocalUsers {
    if (Get-Command Get-LocalUser -ErrorAction SilentlyContinue) {
        return @(Get-LocalUser -ErrorAction Stop | ForEach-Object { @{ name = [string] $_.Name; sid = [string] $_.SID.Value; enabled = [bool] $_.Enabled } })
    }
    @(Get-CimInstance -ClassName Win32_UserAccount -Filter 'LocalAccount=True' | ForEach-Object { @{ name = [string] $_.Name; sid = [string] $_.SID; enabled = -not [bool] $_.Disabled } })
}

<# SIDs of the members of the local Administrators group (S-1-5-32-544), through ADSI (works with orphaned members). #>
function Get-WdhAdminMembers {
    $name = (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
    $g = [ADSI]"WinNT://./$name,group"
    @(@($g.psbase.Invoke('Members')) | ForEach-Object {
        $sidBytes = $_.GetType().InvokeMember('objectSid', 'GetProperty', $null, $_, $null)
        (New-Object Security.Principal.SecurityIdentifier($sidBytes, 0)).Value
    })
}

<# SIDs that have a user profile on this computer (paths are not reported). #>
function Get-WdhProfileSids {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $k = $base.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList')
        if (-not $k) { return @() }
        try { return @($k.GetSubKeyNames()) } finally { $k.Close() }
    } finally { $base.Close() }
}

<# Automatic sign-in: whether it is on and whether a stored password exists; the password is never read. #>
function Get-WdhAutoLogon {
    $wl = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $k = $base.OpenSubKey($wl)
        if (-not $k) { return @{ autoAdminLogon = ''; autoLogonCount = $null; userName = ''; passwordStored = $false } }
        try {
            $names = @($k.GetValueNames())
            @{ autoAdminLogon = [string] $k.GetValue('AutoAdminLogon', ''); autoLogonCount = $k.GetValue('AutoLogonCount', $null); userName = [string] $k.GetValue('DefaultUserName', ''); passwordStored = ($names -contains 'DefaultPassword') }
        } finally { $k.Close() }
    } finally { $base.Close() }
}

function Resolve-WdhSid {
    param([string] $Account)
    if (-not $Account) { return '' }
    try { (New-Object Security.Principal.NTAccount($Account)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { '' }
}

<# True when the user's registry hive is loaded (the user is signed in or a process runs as them). Hives are never loaded by this tool. #>
function Test-WdhUserHive { param([string] $Sid) if (-not $Sid) { return $false } Test-WdhRegKey 'HKU' 'Software' $Sid }

function Get-WdhServices {
    $out = @{}
    foreach ($n in 'wuauserv', 'WinDefend', 'mpssvc') {
        $s = Get-CimInstance -ClassName Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
        $out[$n] = $(if ($s) { @{ startMode = [string] $s.StartMode; state = [string] $s.State } } else { $null })
    }
    return $out
}

function Get-WdhDefender {
    $s = Get-MpComputerStatus -ErrorAction Stop
    @{ amServiceEnabled = [bool] $s.AMServiceEnabled; antivirusEnabled = [bool] $s.AntivirusEnabled; realTimeProtectionEnabled = [bool] $s.RealTimeProtectionEnabled
       signatureAgeDays = [int] $s.AntivirusSignatureAge; tamperProtected = $(if ($s.PSObject.Properties['IsTamperProtected']) { [bool] $s.IsTamperProtected } else { $null }) }
}

<# Products registered with Windows Security Center (product names and on/off only). #>
function Get-WdhSecurityCenter {
    $decode = { param($p) @{ name = [string] $p.displayName; enabled = ((([int] $p.productState) -band 0x1000) -ne 0) } }
    @{
        antivirus = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop | ForEach-Object { & $decode $_ })
        firewall  = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName FirewallProduct -ErrorAction SilentlyContinue | ForEach-Object { & $decode $_ })
    }
}

function Get-WdhFirewall { @(Get-NetFirewallProfile -ErrorAction Stop | ForEach-Object { @{ name = [string] $_.Name; enabled = ([string] $_.Enabled -eq 'True') } }) }

function Get-WdhUac {
    $k = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    @{ enableLua = Get-WdhRegValue 'HKLM' $k 'EnableLUA'; consentPromptBehaviorAdmin = Get-WdhRegValue 'HKLM' $k 'ConsentPromptBehaviorAdmin'; promptOnSecureDesktop = Get-WdhRegValue 'HKLM' $k 'PromptOnSecureDesktop' }
}

function Get-WdhSmartScreen {
    @{ explorer = [string] (Get-WdhRegValue 'HKLM' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled')
       policy = Get-WdhRegValue 'HKLM' 'SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen' }
}

<# Encryption state of the system drive and the TYPES of its key protectors; recovery keys are never read. #>
function Get-WdhEncryption {
    $v = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    @{ volumeStatus = [string] $v.VolumeStatus; protectionStatus = [string] $v.ProtectionStatus; percentage = [double] $v.EncryptionPercentage
       protectors = @(@($v.KeyProtector) | ForEach-Object { [string] $_.KeyProtectorType }) }
}

function Get-WdhRebootSignals {
    $s = @{ cbs = (Test-WdhRegKey 'HKLM' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
            windowsUpdate = (Test-WdhRegKey 'HKLM' 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
            agent = $false; fileRenames = 0 }
    try { $s.agent = [bool] (New-Object -ComObject 'Microsoft.Update.SystemInfo').RebootRequired } catch { }
    $r = Get-WdhRegValue 'HKLM' 'SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations'
    if ($r) { $s.fileRenames = @($r | Where-Object { $_ }).Count }
    return $s
}

function Get-WdhUpdateAgent {
    $au = New-Object -ComObject 'Microsoft.Update.AutoUpdate'
    $r = $au.Results
    @{ lastSearchUtc = $(if ($r.LastSearchSuccessDate) { ([DateTime] $r.LastSearchSuccessDate).ToUniversalTime().ToString('o') } else { '' })
       lastInstallUtc = $(if ($r.LastInstallationSuccessDate) { ([DateTime] $r.LastInstallationSuccessDate).ToUniversalTime().ToString('o') } else { '' }) }
}

<# Read-only search for updates that are still applicable (only with -ScanUpdates). Nothing is downloaded or installed. #>
function Get-WdhUpdateScan {
    $session = New-Object -ComObject 'Microsoft.Update.Session'
    $searcher = $session.CreateUpdateSearcher()
    $res = $searcher.Search('IsInstalled=0 and IsHidden=0')
    $o = @{ required = 0; optional = 0; drivers = 0; feature = 0; titles = @() }
    foreach ($u in @($res.Updates)) {
        $cats = @(@($u.Categories) | ForEach-Object { [string] $_.Name })
        if ([int] $u.Type -eq 2) { $o.drivers++ }
        elseif ($cats -contains 'Upgrades') { $o.feature++ }
        elseif ([bool] $u.BrowseOnly) { $o.optional++ }
        else { $o.required++; if ($o.titles.Count -lt 10) { $o.titles += [string] $u.Title } }
    }
    return $o
}

<#
    Windows Update history (read-only): what Windows itself recorded as installed, with the date.
    IUpdateSearcher.QueryHistory only reads the history; it never searches, downloads or installs.
    resultCode 2 = succeeded, 3 = succeeded with errors; operation 1 = installation, 2 = removal.
#>
function Get-WdhUpdateHistory {
    param([int] $Max = 1000)
    $session = New-Object -ComObject 'Microsoft.Update.Session'
    $searcher = $session.CreateUpdateSearcher()
    $count = [int] $searcher.GetTotalHistoryCount()
    if ($count -le 0) { return @() }
    $out = @()
    foreach ($h in @($searcher.QueryHistory(0, [Math]::Min($count, $Max)))) {
        # The Windows Update Agent records history dates in UTC.
        $d = $(if ($h.Date) { [DateTime]::SpecifyKind([DateTime] $h.Date, [DateTimeKind]::Utc).ToString('o') } else { '' })
        $out += , @{ title = [string] $h.Title; dateUtc = $d; resultCode = [int] $h.ResultCode; operation = [int] $h.Operation }
    }
    return $out
}

<#
    The Windows Update orchestrator's view (what Settings > Windows Update shows as "Last checked"),
    Windows 11 24H2 and later. Reads ONLY LastSuccessfulScanTimestamp, IsScanning and IsWorking; it
    never starts a scan. $null when the API does not exist on this Windows.
#>
function Get-WdhOrchestratorScan {
    try { $null = [Windows.Management.Update.WindowsUpdateManager, Windows.Management.Update, ContentType = WindowsRuntime] } catch { return $null }
    $m = New-Object Windows.Management.Update.WindowsUpdateManager 'WindowsDeploymentBuilder'
    $ts = $m.LastSuccessfulScanTimestamp
    $utc = $(if ($ts -is [DateTimeOffset]) { $ts.UtcDateTime.ToString('o') } elseif ($ts -is [DateTime]) { $ts.ToUniversalTime().ToString('o') } elseif ($ts) { [string] $ts } else { '' })
    @{ lastSuccessfulScanUtc = $utc; isScanning = [bool] $m.IsScanning; isWorking = [bool] $m.IsWorking }
}

<# Display adapters: name and PnP device id (vendor and device ids), for the manufacturer software recommendations. #>
function Get-WdhVideoControllers { @(Get-CimInstance -ClassName Win32_VideoController -Property Name, PNPDeviceID -ErrorAction Stop | ForEach-Object { @{ name = ([string] $_.Name).Trim(); pnpDeviceId = [string] $_.PNPDeviceID } }) }

<# Processors: name and manufacturer only. #>
function Get-WdhProcessors { @(Get-CimInstance -ClassName Win32_Processor -Property Name, Manufacturer -ErrorAction Stop | ForEach-Object { @{ name = ([string] $_.Name).Trim(); manufacturer = [string] $_.Manufacturer } }) }

<# Chassis types (SMBIOS) and whether a battery exists: desktop or portable. #>
function Get-WdhChassis {
    $types = @()
    foreach ($e in @(Get-CimInstance -ClassName Win32_SystemEnclosure -Property ChassisTypes -ErrorAction Stop)) { $types += @(@($e.ChassisTypes) | Where-Object { $null -ne $_ } | ForEach-Object { [int] $_ }) }
    $battery = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue).Count -gt 0
    @{ chassisTypes = $types; battery = $battery }
}

<#
    Microsoft Office Click-to-Run configuration (HKLM\SOFTWARE\Microsoft\Office\ClickToRun\Configuration):
    product release ids, version and platform only. Keys and licences are never read here.
#>
function Get-WdhOfficeClickToRun {
    $k = 'SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $ids = Get-WdhRegValue 'HKLM' $k 'ProductReleaseIds'
    $ver = Get-WdhRegValue 'HKLM' $k 'VersionToReport'
    $plat = Get-WdhRegValue 'HKLM' $k 'Platform'
    if ($null -eq $ids -and $null -eq $ver) { return @{ present = $false; productReleaseIds = @(); version = ''; platform = '' } }
    @{ present = $true; productReleaseIds = @(([string] $ids) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }); version = [string] $ver; platform = [string] $plat }
}

<# True while the one Retry Windows Update task exists (the engine removes it when its run is final). #>
function Test-WdhRetryTask { [bool] (Get-WddTask '\WindowsDeploymentBuilder\' 'WindowsUpdateRetry') }

<# Retry Windows Update runs (<dataRoot>\UpdateRetry\<runId>\ config.json, state.json, result.json), oldest first. #>
function Get-WdhRetryRuns {
    param([string] $Root)
    $dir = Join-Path $Root 'UpdateRetry'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $out = @()
    foreach ($d in @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $out += , @{ runId = $d.Name; config = (Read-WddJson (Join-Path $d.FullName 'config.json')); state = (Read-WddJson (Join-Path $d.FullName 'state.json')); result = (Read-WddJson (Join-Path $d.FullName 'result.json')) }
    }
    return $out
}

<# Present Plug and Play devices: name, class, service, problem code, the first hardware ID and the device instance id. #>
function Get-WdhPnpDevices {
    @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.Present -ne $false } | ForEach-Object {
        @{ name = [string] $_.Name; class = [string] $_.PNPClass; service = [string] $_.Service; problemCode = [int] $_.ConfigManagerErrorCode
           hardwareId = $(if ($_.HardwareID) { [string] @($_.HardwareID)[0] } else { '' }); deviceId = [string] $_.PNPDeviceID }
    })
}

<# Uninstall records: machine-wide (64- and 32-bit) and, when that user's hive is loaded, the deployment user's. #>
function Get-WdhUninstallEntries {
    param([string] $Sid = '')
    $out = @()
    $sub = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    $specs = @(@('LocalMachine', 'Registry64', 'machine', $sub, '64'), @('LocalMachine', 'Registry32', 'machine', $sub, '32'))
    if ($Sid) { $specs += , @('Users', 'Registry64', 'user', "$Sid\$sub", 'user') }
    foreach ($spec in $specs) {
        $base = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]$spec[0], [Microsoft.Win32.RegistryView]$spec[1])
            $root = $base.OpenSubKey($spec[3])
            if (-not $root) { continue }
            foreach ($name in $root.GetSubKeyNames()) {
                $k = $root.OpenSubKey($name)
                if (-not $k) { continue }
                $dn = [string] $k.GetValue('DisplayName', '')
                $out += , @{ scope = $spec[2]; view = $spec[4]; keyName = $name; displayName = $dn; displayVersion = [string] $k.GetValue('DisplayVersion', ''); publisher = [string] $k.GetValue('Publisher', '') }
                $k.Close()
            }
            $root.Close()
        } catch { } finally { if ($base) { $base.Close() } }
    }
    return $out
}

<# Store (MSIX) packages of the deployment user, or of every user. Needs administrator rights. #>
function Get-WdhAppxPackages {
    param([string] $Sid = '')
    $list = $(if ($Sid) { Get-AppxPackage -User $Sid -ErrorAction Stop } else { Get-AppxPackage -AllUsers -ErrorAction Stop })
    @(@($list) | ForEach-Object { @{ name = [string] $_.Name; family = [string] $_.PackageFamilyName; version = [string] $_.Version } })
}

<# Health engine 1.2.0: Store packages provisioned for every user (staged; each user registers them at sign-in). #>
function Get-WdhProvisionedAppx {
    @(@(Get-AppxProvisionedPackage -Online -ErrorAction Stop) | ForEach-Object { @{ name = [string] $_.DisplayName; version = [string] $_.Version; packageName = [string] $_.PackageName } })
}

<# The deployment user's profile folder (ProfileList), or '' when that user has no profile yet. Never SYSTEM's profile. #>
function Get-WdhUserProfilePath {
    param([string] $Sid)
    if (-not $Sid) { return '' }
    $p = Get-WdhRegValue 'HKLM' "SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid" 'ProfileImagePath'
    if (-not $p) { return '' }
    $p = [Environment]::ExpandEnvironmentVariables([string] $p)
    if (Test-Path -LiteralPath $p -PathType Container) { return $p }
    return ''
}

<# The machine-wide roots a verify path may name (the 64-bit Program Files, also from a 32-bit process). #>
function Get-WdhMachineFolders {
    $pf = $(if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles })
    @{ ProgramFiles = [string] $pf; ProgramFilesX86 = [string] ${env:ProgramFiles(x86)}; ProgramData = [string] $env:ProgramData }
}

<# One file named by a verify block: whether it exists, and its version. Read-only. #>
function Get-WdhFileEvidence {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ exists = $false; version = '' } }
    $v = ''
    try { $i = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path); $v = $(if ($i.ProductVersion) { [string] $i.ProductVersion } else { [string] $i.FileVersion }) } catch { }
    @{ exists = $true; version = ([string] $v).Trim() }
}

<# One registry value below HKLM in the 64- or 32-bit view; $null when absent. #>
function Get-WdhRegValueView {
    param([string] $SubKey, [string] $Name, [ValidateSet('64', '32')] [string] $View = '64')
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $(if ($View -eq '32') { [Microsoft.Win32.RegistryView]::Registry32 } else { [Microsoft.Win32.RegistryView]::Registry64 }))
    try {
        $k = $base.OpenSubKey($SubKey)
        if (-not $k) { return $null }
        try { return $k.GetValue($Name, $null) } finally { $k.Close() }
    } finally { $base.Close() }
}

<#
    -CheckAppUpdates: WinGet's list of available upgrades for the account running this check
    ("winget upgrade" without a package only lists; it installs nothing). No agreement is accepted
    and nothing is interactive. Returns @{ available; exitCode; text }.
#>
function Get-WdhWinGetUpgrades {
    $wg = ''
    $cmd = Get-Command 'winget.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $wg = [string] $cmd.Source }
    elseif ($env:LOCALAPPDATA -and (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'))) { $wg = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe' }
    if (-not $wg) { return @{ available = $false; exitCode = $null; text = '' } }
    # Windows PowerShell 5.1 turns a native stderr line into a terminating error under 'Stop'.
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $enc = $null
    try { $enc = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    try {
        $text = (@(& $wg 'upgrade' '--source' 'winget' '--disable-interactivity' 2>&1 | ForEach-Object { [string] $_ }) -join "`n")
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $eap
        if ($enc) { try { [Console]::OutputEncoding = $enc } catch { } }
    }
    @{ available = $true; exitCode = $code; text = $text }
}

<# Shortcuts the application engine creates for portable tools (Start menu > Windows Deployment Tools). #>
function Get-WdhPortableShortcuts {
    $dir = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Windows Deployment Tools'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    @(Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
}

function Get-WdhNetwork {
    $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop | ForEach-Object { @{ description = [string] $_.InterfaceDescription; status = [string] $_.Status; wireless = ([string] $_.PhysicalMediaType -match '802\.11|Wireless') } })
    $gateway = $false
    try { $gateway = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4DefaultGateway -or $_.IPv6DefaultGateway }).Count -gt 0 } catch { }
    @{ adapters = $adapters; gateway = $gateway }
}

function Test-WdhDns { param([string] $HostName) try { [bool] @([System.Net.Dns]::GetHostAddresses($HostName)).Count } catch { $false } }

<# The Windows connectivity test (the documented NCSI probe), then TCP 443 to a package source when needed. #>
function Test-WdhInternet {
    try {
        $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        return ([string] $r.Content).Trim() -eq 'Microsoft Connect Test'
    } catch { return $false }
}

function Test-WdhTcp {
    param([string] $HostName, [int] $Port = 443)
    $c = New-Object System.Net.Sockets.TcpClient
    try { $t = $c.BeginConnect($HostName, $Port, $null, $null); if ($t.AsyncWaitHandle.WaitOne(8000) -and $c.Connected) { return $true } return $false } catch { return $false } finally { $c.Close() }
}

function Get-WdhVolume {
    $d = $env:SystemDrive.TrimEnd(':')
    $v = Get-Volume -DriveLetter $d -ErrorAction Stop
    $dirty = $null
    try {
        $out = (& fsutil.exe dirty query "$($env:SystemDrive)" 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0) { $dirty = ($out -match 'is\s+dirty' -and $out -notmatch 'NOT\s+dirty') }
    } catch { }
    @{ fileSystem = [string] $v.FileSystem; health = [string] $v.HealthStatus; operational = [string] $v.OperationalStatus; size = [double] $v.Size; free = [double] $v.SizeRemaining; dirty = $dirty }
}

<# Physical disk health as Windows reports it (no serial numbers). #>
function Get-WdhPhysicalDisks {
    @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
        $rel = $null
        try { $c = $_ | Get-StorageReliabilityCounter -ErrorAction Stop; $rel = @{ wear = $c.Wear; temperature = $c.Temperature; readErrorsUncorrected = $c.ReadErrorsUncorrected } } catch { }
        @{ name = [string] $_.FriendlyName; media = [string] $_.MediaType; bus = [string] $_.BusType; health = [string] $_.HealthStatus; operational = [string] (@($_.OperationalStatus) -join ', '); reliability = $rel }
    })
}

<# Staged settings backups the application engine kept (below <dataRoot>\Backup). #>
function Get-WdhBackupFolders {
    param([string] $Root)
    $b = Join-Path $Root 'Backup'
    if (-not (Test-Path -LiteralPath $b)) { return @() }
    $out = @()
    foreach ($d in @(Get-ChildItem -LiteralPath $b -Directory -Recurse -Depth 1 -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'backup-manifest.json') })) {
        $bytes = 0
        foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -File -Recurse -ErrorAction SilentlyContinue)) { $bytes += $f.Length }
        $out += , @{ path = $d.FullName; name = $d.Name; bytes = $bytes }
    }
    return $out
}

function Open-WdhReport { param([string] $Path) Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList "`"$Path`"" }

function Register-WdhRecheckTask {
    param([string] $Script)
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`" -Mode Verify -Trigger Startup"
    $t = New-ScheduledTaskTrigger -AtStartup
    $t.Delay = 'PT5M'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    Register-ScheduledTask -TaskName 'HealthCheck' -TaskPath '\WindowsDeploymentBuilder\' -Action $action -Trigger $t -Principal $principal -Settings $settings -Force `
        -Description 'Windows Deployment Builder: verifies the deployment again after a pending restart (read-only), then removes itself.' | Out-Null
}

function Unregister-WdhRecheckTask { Unregister-WddTask '\WindowsDeploymentBuilder\' 'HealthCheck' }

<# Runs the recovery tool's diagnostics export (its whitelist and redaction) in its own process. #>
function Invoke-WdhRecoveryExport {
    param([string] $Tool, [string] $OutputPath)
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $out = & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Tool -Action ExportDiagnostics -OutputPath $OutputPath 2>&1
    return @{ exit = $LASTEXITCODE; text = (@($out) -join ' ') }
}

# ------------------------------------------------------------------------------------------------
# Evidence and findings
# ------------------------------------------------------------------------------------------------

function Get-WdhTime { if ($script:WdhNow) { return $script:WdhNow } (Get-WddNow) }

<# Reads one evidence file: ok, missing, corrupt (exists but is not valid JSON of the expected format). #>
function Read-WdhSource {
    param($C, [string] $Id, [string] $Relative, [string] $Format = '', [switch] $NotApplicable)
    $path = Join-Path $C.Paths.Root $Relative
    $src = [ordered]@{ id = $Id; file = $Relative; format = $Format; version = ''; generatedUtc = ''; state = 'missing' }
    $data = $null
    if ($NotApplicable) { $src.state = 'notApplicable' }
    elseif (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
            $data = ConvertTo-WddHashtable ($text | ConvertFrom-Json)
            if ($data -isnot [hashtable]) { throw 'not an object' }
            if ($Format -and $data.ContainsKey('format') -and [string] $data['format'] -ne $Format) { throw "unexpected format $($data['format'])" }
            $src.state = 'ok'
            foreach ($k in 'schemaVersion', 'formatVersion', 'version', 'reportVersion') { if ($data.ContainsKey($k) -and $null -ne $data[$k]) { $src.version = [string] $data[$k]; break } }
            foreach ($k in 'generatedUtc', 'finishedUtc', 'updatedUtc') { if ($data.ContainsKey($k) -and $data[$k]) { $src.generatedUtc = [string] $data[$k]; break } }
        } catch { $src.state = 'corrupt'; $data = $null; $C.Limitations.Add("$Relative could not be read ($($_.Exception.Message)).") }
    }
    $C.Sources.Add($src)
    return @{ Data = $data; Source = $src }
}

function Add-WdhFinding {
    param($C, [string] $Id, [string] $Category, [string] $Title, [string] $Status, [string] $Severity, [string] $Expected, [string] $Observed, [string] $Method, [string] $Evidence = '',
          [string] $NextAction = '', [bool] $Required = $true, [bool] $AutomaticRecovery = $false, [bool] $TechnicianRequired = $false, [string] $RecoveryAction = '')
    if ($Status -in 'Fail', 'Unverifiable', 'Warning' -and -not $PSBoundParameters.ContainsKey('TechnicianRequired')) { $TechnicianRequired = $true }
    $f = [ordered]@{ id = $Id; category = $Category; title = $Title; severity = $Severity; status = $Status; required = $Required; expected = $Expected; observed = $Observed; method = $Method
                     evidence = $Evidence; timestampUtc = (Get-WdhTime).ToString('o'); nextAction = $NextAction; automaticRecovery = $AutomaticRecovery; technicianRequired = $TechnicianRequired; recoveryAction = $RecoveryAction }
    $C.Findings.Add($f)
    return $f
}

<#
    One probe of the computer. A probe that fails is never a pass: its checks become Unverifiable
    (or a warning when the check is optional), with the reason in the limitations.
#>
function Invoke-WdhProbe {
    param($C, [string] $Name, [scriptblock] $Body)
    if ($C.Obs.ContainsKey($Name)) { return $C.Obs[$Name] }
    $v = $null
    try { $v = & $Body } catch { $v = $null; $C.Limitations.Add("Could not read $Name`: $((([string] $_.Exception.Message) -split '\r?\n')[0].Trim())") }
    $C.Obs[$Name] = $v
    return $v
}

function Get-WdhNorm {
    param([string] $Name)
    $n = $Name.ToLowerInvariant() -replace '[\u00ae\u2122\u00a9]', ''
    $n = $n -replace '\((x64|x86|arm64|64-bit|32-bit|[a-z]{2}-[a-z]{2}|user|machine)\)', ' '
    $n = $n -replace '\b(x64|x86|arm64|64-bit|32-bit)\b', ' '
    $n = $n -replace '\s+v?\d+(\.\d+){1,3}([.-][0-9a-z]+)?\s*$', ' '
    ($n -replace '[^a-z0-9+#]+', ' ').Trim()
}

<# The architecture a display name states (x64, x86, arm64), or '' when it names none. #>
function Get-WdhArch {
    param([string] $Name)
    if ($Name -match '(?i)\barm64\b') { return 'arm64' }
    if ($Name -match '(?i)\b(x64|amd64)\b|\b64-bit\b') { return 'x64' }
    if ($Name -match '(?i)\bx86\b|\b32-bit\b') { return 'x86' }
    return ''
}

function ConvertTo-WdhList { param($Value) if ($null -eq $Value) { return @() } return @($Value | Where-Object { $null -ne $_ }) }

function Format-WdhBytes { param([double] $Bytes) if ($Bytes -ge 1GB) { '{0:N0} GB' -f ($Bytes / 1GB) } elseif ($Bytes -ge 1MB) { '{0:N0} MB' -f ($Bytes / 1MB) } else { '{0:N0} KB' -f ($Bytes / 1KB) } }

<# A value read from JSON, or $Default when the key is absent or null (results of older engines lack newer fields). #>
function Get-WdhKey {
    param($Table, [string] $Key, $Default = $null)
    if ($Table -is [System.Collections.IDictionary] -and $Table.Contains($Key) -and $null -ne $Table[$Key]) { return $Table[$Key] }
    return $Default
}

<# The KB numbers of an update: its kbs list, or those in its title. #>
function Get-WdhKbs {
    param($Item)
    $k = @(@(ConvertTo-WdhList (Get-WdhKey $Item 'kbs')) | ForEach-Object { $x = ([string] $_).Trim().ToUpperInvariant(); if ($x -match '^\d+$') { "KB$x" } else { $x } } | Where-Object { $_ })
    if ($k.Count) { return $k }
    @([regex]::Matches([string] (Get-WdhKey $Item 'title' ''), '(?i)KB\d{6,8}') | ForEach-Object { $_.Value.ToUpperInvariant() })
}

<# Text from an engine's record without key characters or KMS hosts (activation messages may mention them). #>
function ConvertTo-WdhSafeText {
    param([string] $Text)
    $t = $Text -replace '\s*\(key ending [^)]*\)', ''
    $t = $t -replace '(?i)\bkey ending\s+[A-Z0-9]{5}\b', 'key ending <removed>'
    $t = $t -replace '(?i)\b[A-Z0-9]{5}(-[A-Z0-9]{5}){4}\b', '<key removed>'
    $t = $t -replace '(?i)(KMS\s+(host|server)\s*[:=]?\s*)[A-Za-z0-9.\-]+(:\d+)?', '$1<host removed>'
    # Any other wording: host/server/address followed by : or =, fully qualified names (two dots or more)
    # and IPv4 addresses (raw exception text from the activation tools can name the KMS host).
    $t = $t -replace '(?i)\b(host|server|address)\s*[:=]\s*[^\s,;)]+', '$1: <host removed>'
    $t = $t -replace '(?i)\b[a-z0-9-]+(\.[a-z0-9-]+)+\.[a-z]{2,}(:\d+)?\b', '<host removed>'
    $t = $t -replace '\b\d{1,3}(\.\d{1,3}){3}(:\d+)?\b', '<address removed>'
    return $t
}

function Get-WdhShortHash { param([string] $Text) (Get-WddSha256 ([Text.Encoding]::UTF8.GetBytes($Text))).Substring(0, 12).ToLowerInvariant() }

# ------------------------------------------------------------------------------------------------
# Deployment state, integrity and the Phase 5 outcome (category "recovery")
# ------------------------------------------------------------------------------------------------

function Test-WdhDeployment {
    param($C)
    $read = $C.StateRead
    $C.Sources.Add([ordered]@{ id = 'deploymentState'; file = 'state\deployment.json'; format = 'deployment-state'; version = $(if ($read.State) { [string] $read.State['schemaVersion'] } else { '' }); generatedUtc = $(if ($read.State -and $read.State['lastMonitorUtc']) { [string] $read.State['lastMonitorUtc'] } else { '' })
                    state = $(switch ($read.Source) { 'main' { 'ok' } 'backup' { 'ok' } 'corrupt' { 'corrupt' } default { 'missing' } }) })
    if ($read.Source -eq 'corrupt') {
        Add-WdhFinding $C 'deployment.state' 'recovery' 'Deployment state' 'Unverifiable' 'Critical' 'A readable deployment state' "Damaged, and its backup copy too ($($read.Problem))" 'state\deployment.json and .bak' 'state\deployment.json' 'Run "Deployment recovery" > Resume: it rebuilds the state from the manifest and the engines'' own files. Then verify again.' -RecoveryAction 'Resume' | Out-Null
        return
    }
    if (-not $read.State) {
        Add-WdhFinding $C 'deployment.state' 'recovery' 'Deployment state' 'Unverifiable' 'Critical' 'The deployment has run on this computer' 'No deployment state was found: the deployment never started here, or its state was removed' 'state\deployment.json' 'state\deployment.json' 'Start the deployment (setup.cmd from the package) or verify on the computer it ran on.' | Out-Null
        return
    }
    $st = $read.State
    if ($read.Source -eq 'backup') { Add-WdhFinding $C 'deployment.stateBackup' 'recovery' 'Deployment state' 'Warning' 'The current state file' 'The state file was damaged; its last good copy was used' 'state\deployment.json.bak' 'state\deployment.json.bak' 'Nothing to do unless other findings disagree.' -Required $false | Out-Null }
    if ([string] $st['packageId'] -ne [string] $C.Manifest.packageId) {
        Add-WdhFinding $C 'deployment.package' 'recovery' 'Deployment identity' 'Unverifiable' 'Critical' "Deployment $($C.Manifest.packageId)" "The state belongs to deployment $($st['packageId'])" 'state\deployment.json packageId vs the staged manifest' 'state\deployment.json' 'Verify with the package that was deployed on this computer.' | Out-Null
        return
    }
    if ([string] $st['status'] -eq 'IntegrityFailed') {
        Add-WdhFinding $C 'deployment.integrity' 'recovery' 'Package integrity' 'Fail' 'The staged package is unchanged' ([string] $st['message']) 'Deployment state (monitor integrity check)' 'state\deployment.json' 'Stage the original package again (setup.cmd from the package), then resume.' -RecoveryAction 'Resume' | Out-Null
    } else {
        $check = Test-WddFiles $C.Paths.Package $C.Manifest 'Text' @($st['stagedFiles'])
        if ($check.Ok) { Add-WdhFinding $C 'deployment.integrity' 'recovery' 'Package integrity' 'Pass' 'Critical' 'The staged package is unchanged' "$($check.Checked) staged file(s) match their SHA-256" 'SHA-256 of every staged file against the manifest' 'Package\deployment-manifest.json' | Out-Null }
        else { Add-WdhFinding $C 'deployment.integrity' 'recovery' 'Package integrity' 'Fail' 'Critical' 'The staged package is unchanged' "$(@($check.Missing).Count) missing and $(@($check.Mismatched).Count) modified file(s): $((@($check.Missing) + @($check.Mismatched) | Select-Object -First 5) -join ', ')" 'SHA-256 of every staged file against the manifest' 'Package\deployment-manifest.json' 'Do not trust the results of this computer''s deployment; stage the original package again.' | Out-Null }
    }
    $o = $C.Snapshot
    $outcome = [string] $o.outcome
    $map = @{ Succeeded = @('Pass', 'Informational'); CompletedWithWarnings = @('Info', 'Informational'); CompletedWithFailures = @('Info', 'Informational'); Incomplete = @('Fail', 'Error')
              PausedAwaitingNetwork = @('Pending', 'Warning'); PausedAwaitingReboot = @('Pending', 'Warning'); PausedAwaitingUser = @('Pending', 'Warning'); InProgress = @('Pending', 'Informational')
              FailedToInitialize = @('Fail', 'Critical'); Failed = @('Fail', 'Critical') }
    $m = $(if ($map.ContainsKey($outcome)) { $map[$outcome] } else { @('Unverifiable', 'Error') })
    $next = switch ($outcome) {
        'Incomplete' { 'The deployment ended before every stage finished: run "Deployment recovery" > Resume.' }
        'PausedAwaitingNetwork' { 'Connect the computer to the network; the deployment continues by itself.' }
        'PausedAwaitingReboot' { 'Restart the computer; the deployment continues afterwards.' }
        'PausedAwaitingUser' { "Sign in as $($C.DeploymentUser); the application stage runs only in that account." }
        'InProgress' { 'Wait: the deployment is still running.' }
        'Failed' { 'A stage failed: see its findings, fix the cause and use "Deployment recovery".' }
        'FailedToInitialize' { 'The deployment could not start: see the deployment log, then run setup.cmd from the package.' }
        default { '' }
    }
    # Completed outcomes are context only: the per-item checks below decide, against Windows itself.
    Add-WdhFinding $C 'deployment.outcome' 'recovery' 'Deployment progress' $m[0] $m[1] 'Every stage has finished' "$outcome (code $($o.outcomeCode)). $($o.outcomeDetail)" 'Phase 5 outcome from the engines'' results (Get-WddDeploymentOutcome)' 'Deployment\status.json, the engines'' result.json' $next -AutomaticRecovery ($outcome -like 'Paused*' -or $outcome -eq 'InProgress') -TechnicianRequired ($outcome -in 'Incomplete', 'Failed', 'FailedToInitialize') -RecoveryAction $(if ($outcome -eq 'Incomplete') { 'Resume' } else { '' }) | Out-Null
    $recs = @(ConvertTo-WdhList $st['recoveries'])
    if ($recs.Count) { Add-WdhFinding $C 'deployment.recoveries' 'recovery' 'Recovery actions' 'Info' 'Informational' 'None needed' "$($recs.Count) recovery action(s), the last by $($recs[-1]['by']) ($($recs[-1]['action']))" 'state\deployment.json recoveries' 'state\deployment.json' | Out-Null }
    # Who runs this check, and whose profile holds the per-user installations.
    $same = $C.SameUser
    Add-WdhFinding $C 'deployment.userContext' 'recovery' 'Deployment user' 'Info' 'Informational' "Per-user checks read $($C.DeploymentUser)'s profile" $(if ($C.HiveLoaded) { "Running as $($C.Identity.Name); $($C.DeploymentUser)'s profile is available" } elseif ($C.DeploymentSid) { "Running as $($C.Identity.Name); $($C.DeploymentUser) is not signed in, so per-user checks are deferred" } else { "Running as $($C.Identity.Name); the deployment user could not be resolved" }) 'Deployment state (the user each stage ran as) and HKEY_USERS' 'state\deployment.json' $(if (-not $C.HiveLoaded -and $C.DeploymentSid) { "Sign in as $($C.DeploymentUser) and open the Health Report again to check per-user items." } else { '' }) -Required $false | Out-Null
    if ($same -eq $false -and -not $C.Identity.IsSystem) { $C.Limitations.Add("This check ran as $($C.Identity.Name), not as the deployment user $($C.DeploymentUser): per-user items were read from $($C.DeploymentUser)'s own profile, never from $($C.Identity.Name)'s.") }
}

# ------------------------------------------------------------------------------------------------
# Windows
# ------------------------------------------------------------------------------------------------

function Test-WdhWindows {
    param($C)
    $w = $C.Config['windows']
    $os = Invoke-WdhProbe $C 'os' { Get-WdhOsInfo }
    if (-not $os) {
        Add-WdhFinding $C 'windows.identity' 'windows' 'Windows' 'Unverifiable' 'Critical' 'Windows 11 information' 'Could not be read' 'Win32_OperatingSystem, CurrentVersion' 'WMI/registry' 'Run the check again as administrator.' | Out-Null
        return
    }
    $expected = @(ConvertTo-WdhList $w['expectedEditionIds'])
    if ($expected.Count) {
        if ($os.editionId -in $expected) { Add-WdhFinding $C 'windows.edition' 'windows' 'Windows edition' 'Pass' 'Critical' "$($expected -join ' or ') ($($w['editionName']))" $os.editionId 'Registry EditionID (HKLM\...\Windows NT\CurrentVersion)' 'HKLM CurrentVersion' | Out-Null }
        else { Add-WdhFinding $C 'windows.edition' 'windows' 'Windows edition' 'Fail' 'Critical' "$($expected -join ' or ') ($($w['editionName']))" "$($os.editionId) ($($os.caption))" 'Registry EditionID (HKLM\...\Windows NT\CurrentVersion)' 'HKLM CurrentVersion' 'The wrong edition is installed. Check the installation media and the answer file edition, then reinstall or upgrade the edition with a valid licence. Do not deliver this computer.' | Out-Null }
    } else {
        Add-WdhFinding $C 'windows.edition' 'windows' 'Windows edition' 'Info' 'Informational' "Chosen $($w['editionMode'])" "$($os.editionId) ($($os.caption))" 'Registry EditionID' 'HKLM CurrentVersion' -Required $false | Out-Null
    }
    $build = "$($os.build).$($os.ubr)"
    if ($os.build -ge [int] $w['minimumBuild']) { Add-WdhFinding $C 'windows.version' 'windows' 'Windows version' 'Pass' 'Error' "Windows 11 (build $($w['minimumBuild']) or later)" "Windows 11 $($os.displayVersion), build $build" 'CurrentBuildNumber, UBR, DisplayVersion' 'HKLM CurrentVersion' | Out-Null }
    else { Add-WdhFinding $C 'windows.version' 'windows' 'Windows version' 'Fail' 'Error' "Windows 11 (build $($w['minimumBuild']) or later)" "Build $build" 'CurrentBuildNumber' 'HKLM CurrentVersion' 'This deployment targets Windows 11.' | Out-Null }
    $archs = @(ConvertTo-WdhList $w['architectures'])
    if (-not $archs.Count -or $os.architecture -in $archs) { Add-WdhFinding $C 'windows.architecture' 'windows' 'Architecture' 'Pass' 'Error' ($archs -join ', ') $os.architecture 'PROCESSOR_ARCHITECTURE (machine)' 'Environment' | Out-Null }
    else { Add-WdhFinding $C 'windows.architecture' 'windows' 'Architecture' 'Fail' 'Error' ($archs -join ', ') $os.architecture 'PROCESSOR_ARCHITECTURE (machine)' 'Environment' 'Use installation media for the configured architecture.' | Out-Null }
    if ($os.productType -eq 1) { Add-WdhFinding $C 'windows.productType' 'windows' 'Product type' 'Pass' 'Error' 'Workstation' 'Workstation' 'Win32_OperatingSystem.ProductType' 'WMI' | Out-Null }
    else { Add-WdhFinding $C 'windows.productType' 'windows' 'Product type' 'Fail' 'Error' 'Workstation' "ProductType $($os.productType) (server or domain controller)" 'Win32_OperatingSystem.ProductType' 'WMI' 'This deployment is for Windows 11 client computers.' | Out-Null }
    $setup = Invoke-WdhProbe $C 'setup' { Get-WdhSetupState }
    if (-not $setup) { Add-WdhFinding $C 'windows.setup' 'windows' 'Windows Setup' 'Unverifiable' 'Error' 'Setup finished' 'Could not be read' 'Setup\State ImageState' 'Registry' | Out-Null }
    elseif ($setup.imageState -eq 'IMAGE_STATE_COMPLETE' -and -not $setup.oobeInProgress -and -not $setup.systemSetupInProgress) { Add-WdhFinding $C 'windows.setup' 'windows' 'Windows Setup' 'Pass' 'Error' 'Setup finished' 'IMAGE_STATE_COMPLETE' 'Setup\State ImageState, OOBEInProgress, SystemSetupInProgress' 'Registry' | Out-Null }
    else { Add-WdhFinding $C 'windows.setup' 'windows' 'Windows Setup' 'Pending' 'Error' 'Setup finished' "ImageState $($setup.imageState), OOBE in progress $($setup.oobeInProgress)" 'Setup\State ImageState' 'Registry' 'Let Windows Setup finish (complete the out-of-box experience).' | Out-Null }
    # Licensing is not installation: an installed, unactivated Windows works and is reported as such.
    $act = Invoke-WdhProbe $C 'activation' { Get-WdhActivation }
    $lic = @{ 0 = 'unlicensed'; 1 = 'activated'; 2 = 'out-of-box grace period'; 3 = 'out-of-tolerance grace period'; 4 = 'non-genuine grace period'; 5 = 'notification mode'; 6 = 'extended grace period'; -1 = 'no product key installed' }
    if (-not $act) { Add-WdhFinding $C 'windows.activation' 'windows' 'Activation' 'Warning' 'Warning' 'Activated' 'Activation state could not be read' 'SoftwareLicensingProduct' 'WMI' 'Check Settings > System > Activation.' -Required $false | Out-Null }
    elseif ($act.licenseStatus -eq 1) { Add-WdhFinding $C 'windows.activation' 'windows' 'Activation' 'Pass' 'Warning' 'Activated' "Activated$(if ($act.channel) { " ($($act.channel))" })" 'SoftwareLicensingProduct.LicenseStatus (the key itself is never read)' 'WMI' -Required $false | Out-Null }
    else { Add-WdhFinding $C 'windows.activation' 'windows' 'Activation' 'Warning' 'Warning' 'Activated' "Not activated yet ($($lic[[int] $act.licenseStatus])). Windows is installed and works; a generic setup key never activates it." 'SoftwareLicensingProduct.LicenseStatus' 'WMI' 'Activate with the computer''s digital licence or a valid product key (Settings > System > Activation).' -Required $false | Out-Null }
    Test-WdhRestart $C
}

<# Restart pending: Windows servicing, Windows Update, or a restart marker an engine wrote in this boot. #>
function Test-WdhRestart {
    param($C)
    $sig = Invoke-WdhProbe $C 'reboot' { Get-WdhRebootSignals }
    $marker = $false
    try { $marker = [bool] (Test-WddRestartPending $C.Paths) } catch { }
    if (-not $sig) { Add-WdhFinding $C 'windows.restart' 'windows' 'Pending restart' 'Unverifiable' 'Error' 'No restart pending' 'Could not be read' 'Component Based Servicing, Windows Update, Update Agent' 'Registry' | Out-Null; return }
    $why = @()
    if ($sig.cbs) { $why += 'Windows servicing' }
    if ($sig.windowsUpdate -or $sig.agent) { $why += 'Windows Update' }
    if ($marker) { $why += 'the deployment scheduled one' }
    if ($why.Count) { Add-WdhFinding $C 'windows.restart' 'windows' 'Pending restart' 'Pending' 'Error' 'No restart pending' "A restart is pending ($($why -join ', '))" 'CBS RebootPending, WindowsUpdate RebootRequired, Microsoft.Update.SystemInfo, restart marker' 'Registry, Update Agent' 'Restart the computer; verification runs again after the restart.' -AutomaticRecovery $true -TechnicianRequired $false | Out-Null }
    else { Add-WdhFinding $C 'windows.restart' 'windows' 'Pending restart' 'Pass' 'Error' 'No restart pending' "None$(if ($sig.fileRenames) { " (Windows lists $($sig.fileRenames) file operation(s) for the next start; this alone is normal)" })" 'CBS RebootPending, WindowsUpdate RebootRequired, Microsoft.Update.SystemInfo, restart marker' 'Registry, Update Agent' | Out-Null }
}

# ------------------------------------------------------------------------------------------------
# Accounts and identity
# ------------------------------------------------------------------------------------------------

function Test-WdhAccounts {
    param($C)
    $id = $C.Config['identity']
    $names = Invoke-WdhProbe $C 'computerName' { Get-WdhComputerNames }
    $want = [string] $id['computerName']
    if (-not $names) { Add-WdhFinding $C 'identity.computerName' 'accounts' 'Computer name' 'Unverifiable' 'Error' $(if ($want) { $want } else { 'Chosen by Windows' }) 'Could not be read' 'ComputerName registry keys' 'Registry' | Out-Null }
    elseif (-not $want) { Add-WdhFinding $C 'identity.computerName' 'accounts' 'Computer name' 'Info' 'Informational' 'A name chosen by Windows' $names.active 'ActiveComputerName' 'Registry' -Required $false | Out-Null }
    elseif ($names.active -ieq $want -and (-not $names.pending -or $names.pending -ieq $want)) { Add-WdhFinding $C 'identity.computerName' 'accounts' 'Computer name' 'Pass' 'Error' $want "$($names.active) (active)" 'ActiveComputerName and the pending ComputerName' 'Registry' | Out-Null }
    elseif ($names.pending -ieq $want) { Add-WdhFinding $C 'identity.computerName' 'accounts' 'Computer name' 'Pending' 'Error' $want "Renamed to $($names.pending), active after a restart (now $($names.active))" 'ActiveComputerName vs ComputerName' 'Registry' 'Restart the computer to apply the new name.' -AutomaticRecovery $true -TechnicianRequired $false | Out-Null }
    else { Add-WdhFinding $C 'identity.computerName' 'accounts' 'Computer name' 'Fail' 'Error' $want "$($names.active)$(if ($names.pending -and $names.pending -ne $names.active) { " (pending: $($names.pending))" })" 'ActiveComputerName vs ComputerName' 'Registry' 'Rename the computer in Settings > System > About if the configured name is still wanted (nothing was changed by this check).' | Out-Null }

    $a = $C.Config['account']
    $users = Invoke-WdhProbe $C 'users' { Get-WdhLocalUsers }
    $admins = Invoke-WdhProbe $C 'admins' { Get-WdhAdminMembers }
    $profiles = Invoke-WdhProbe $C 'profiles' { Get-WdhProfileSids }
    if ($null -eq $users) {
        Add-WdhFinding $C 'account.exists' 'accounts' 'Local account' 'Unverifiable' 'Error' $(if ($a['username']) { "$($a['username']) exists" } else { 'The account created during setup' }) 'Local accounts could not be read' 'Get-LocalUser' 'Local accounts' 'Run the check again as administrator.' | Out-Null
        return
    }
    $adminSids = @(ConvertTo-WdhList $admins)
    $wantAdmin = [string] $a['expectedGroup'] -eq 'Administrators'
    if ([string] $a['mode'] -eq 'unattendedLocal' -and $a['username']) {
        $u = @($users | Where-Object { $_.name -ieq [string] $a['username'] }) | Select-Object -First 1
        if (-not $u) {
            Add-WdhFinding $C 'account.exists' 'accounts' "Local account $($a['username'])" 'Fail' 'Error' "$($a['username']) exists" 'No such local account' 'Get-LocalUser' 'Local accounts' 'The account from the answer file was not created. Check the answer file and C:\Windows\Panther\setupact.log; nothing was changed by this check.' | Out-Null
        } else {
            if ($u.enabled) { Add-WdhFinding $C 'account.exists' 'accounts' "Local account $($u.name)" 'Pass' 'Error' "$($a['username']) exists and is enabled" "$($u.name) exists, enabled" 'Get-LocalUser' 'Local accounts' | Out-Null }
            else { Add-WdhFinding $C 'account.exists' 'accounts' "Local account $($u.name)" 'Fail' 'Error' "$($a['username']) exists and is enabled" "$($u.name) exists but is disabled" 'Get-LocalUser' 'Local accounts' 'Enable it in Computer Management if that is intended (not changed by this check).' | Out-Null }
            if ($null -eq $admins) { Add-WdhFinding $C 'account.role' 'accounts' 'Account type' 'Unverifiable' 'Error' $(if ($wantAdmin) { 'Administrator' } else { 'Standard user' }) 'The Administrators group could not be read' 'Administrators group (S-1-5-32-544)' 'Local groups' | Out-Null }
            else {
                $isAdmin = $u.sid -in $adminSids
                if ($isAdmin -eq $wantAdmin) { Add-WdhFinding $C 'account.role' 'accounts' 'Account type' 'Pass' 'Error' $(if ($wantAdmin) { 'Administrator' } else { 'Standard user' }) $(if ($isAdmin) { 'Member of Administrators' } else { 'Standard user (not in Administrators)' }) 'Administrators group membership (S-1-5-32-544)' 'Local groups' | Out-Null }
                elseif ($wantAdmin) { Add-WdhFinding $C 'account.role' 'accounts' 'Account type' 'Fail' 'Error' 'Administrator' 'Standard user (not in Administrators)' 'Administrators group membership' 'Local groups' 'Group membership was not changed. Add the account to Administrators only if that is still intended.' | Out-Null }
                else { Add-WdhFinding $C 'account.role' 'accounts' 'Account type' 'Fail' 'Error' 'Standard user' 'Unexpectedly a member of Administrators' 'Administrators group membership' 'Local groups' 'The everyday account has administrator rights it should not have. Remove it from Administrators after confirming another administrator account exists (not changed by this check).' | Out-Null }
            }
            $hasProfile = $u.sid -in @(ConvertTo-WdhList $profiles)
            Add-WdhFinding $C 'account.profile' 'accounts' 'User profile' $(if ($hasProfile) { 'Pass' } else { 'Warning' }) 'Warning' 'The profile exists (first sign-in done)' $(if ($hasProfile) { 'Profile created' } else { 'Not created yet: the account has never signed in' }) 'ProfileList' 'Registry' $(if ($hasProfile) { '' } else { 'Sign in once with this account.' }) -Required $false | Out-Null
        }
    } else {
        Add-WdhFinding $C 'account.exists' 'accounts' 'Local account' 'Info' 'Informational' 'Created during setup (interactive)' "$(@($users | Where-Object { $_.enabled }).Count) enabled local account(s)" 'Get-LocalUser' 'Local accounts' -Required $false | Out-Null
    }
    # An administrator the customer controls must exist; no hidden accounts are ever created.
    if ($null -ne $admins) {
        $enabledAdmins = @($users | Where-Object { $_.enabled -and $_.sid -in $adminSids -and $_.sid -notmatch '-500$' })
        if ($enabledAdmins.Count) { Add-WdhFinding $C 'account.administrator' 'accounts' 'Administrator access' 'Pass' 'Error' 'At least one enabled administrator account' "$($enabledAdmins.Count) enabled administrator account(s): $(($enabledAdmins | ForEach-Object { $_.name }) -join ', ')" 'Administrators group and local accounts' 'Local groups' | Out-Null }
        else { Add-WdhFinding $C 'account.administrator' 'accounts' 'Administrator access' 'Fail' 'Error' 'At least one enabled administrator account' 'No enabled administrator account besides the built-in Administrator' 'Administrators group and local accounts' 'Local groups' 'Create or enable an administrator account the customer controls before delivery.' | Out-Null }
    }
    $al = Invoke-WdhProbe $C 'autologon' { Get-WdhAutoLogon }
    if ($al) {
        $on = [string] $al.autoAdminLogon -eq '1' -and ($null -eq $al.autoLogonCount -or [int] $al.autoLogonCount -gt 0)
        $want = [string] $a['autoLogon']
        $obs = "$(if ($on) { "On (for $($al.userName))" } else { 'Off' })$(if ($al.passwordStored) { '; a sign-in password value is stored in the registry' } else { '' })"
        if ($want -eq 'persistent') { Add-WdhFinding $C 'account.autoLogon' 'accounts' 'Automatic sign-in' $(if ($on) { 'Info' } else { 'Warning' }) 'Warning' 'On (as configured)' $obs 'Winlogon AutoAdminLogon, AutoLogonCount (values only; no password is read)' 'Registry' $(if ($on) { 'Automatic sign-in stays on by configuration: anyone with physical access is signed in.' } else { 'Automatic sign-in is off although the configuration keeps it on.' }) -Required $false | Out-Null }
        elseif ($on) { Add-WdhFinding $C 'account.autoLogon' 'accounts' 'Automatic sign-in' 'Fail' 'Error' 'Off after the deployment' $obs 'Winlogon AutoAdminLogon, AutoLogonCount' 'Registry' 'Automatic sign-in is still on although it should not be. Turn it off (netplwiz) before delivery; nothing was changed by this check.' | Out-Null }
        else { Add-WdhFinding $C 'account.autoLogon' 'accounts' 'Automatic sign-in' 'Pass' 'Error' 'Off after the deployment' $obs 'Winlogon AutoAdminLogon, AutoLogonCount' 'Registry' | Out-Null }
    }
}

# ------------------------------------------------------------------------------------------------
# Windows Update
# ------------------------------------------------------------------------------------------------

<# What each updateState of the update engine (2.1.0) means here. Never "Pass" because an installation finished. #>
$script:WdhUpdateStates = @{
    UpToDate                = @('Pass', 'Up to date: Windows Update offered nothing more that this deployment''s policy installs')
    UpToDateUnderPolicy     = @('Pass', 'Up to date under this deployment''s policy (updates the policy excludes may still be offered)')
    PreviewUpdatesExcluded  = @('Pass', 'Up to date; preview updates are still offered and were intentionally excluded by policy')
    RestartRequired         = @('Warning', 'Updates were installed and need a restart to finish')
    UpdatesRemaining        = @('Warning', 'Windows Update still offers updates that the policy installs')
    InstallationIncomplete  = @('Fail', 'The update installation did not finish')
    CompletedWithFailures   = @('Fail', 'Finished, but some updates failed')
    VerificationUnavailable = @('Unverifiable', 'The final state could not be verified (the engine''s last Windows Update check failed)')
}

<# One engine result.json (the deployment's or a retry run's) in report form. Fields of engine 2.1.0 are optional. #>
function Get-WdhUpdateResultView {
    param($Data, [string] $Source, [string] $Label)
    if ($Data -isnot [System.Collections.IDictionary]) { return $null }
    $sum = Get-WdhKey $Data 'summary'
    $ver = Get-WdhKey $Data 'verification'
    $summary = $null
    if ($sum -is [System.Collections.IDictionary]) {
        $summary = [ordered]@{}
        foreach ($k in 'installed', 'superseded', 'notApplicable', 'excluded', 'previewsExcluded', 'downloadFailed', 'installFailed', 'awaitingRestart', 'remaining', 'notAttempted') { if ($null -ne (Get-WdhKey $sum $k)) { $summary[$k] = [int] $sum[$k] } }
    }
    $verification = $null
    if ($ver -is [System.Collections.IDictionary]) {
        $verification = [ordered]@{
            remainingOffered = $(if ($null -ne (Get-WdhKey $ver 'remainingOffered')) { [int] $ver['remainingOffered'] } else { $null })
            noLongerOffered = @(ConvertTo-WdhList (Get-WdhKey $ver 'noLongerOffered')).Count
            devicesWithProblems = @(ConvertTo-WdhList (Get-WdhKey $ver 'devicesWithProblems')).Count
            rebootPending = $(if ($null -ne (Get-WdhKey $ver 'rebootPending')) { [bool] $ver['rebootPending'] } else { $null })
        }
    }
    [ordered]@{
        source = $Source; label = $Label
        engineVersion = [string] (Get-WdhKey $Data 'engineVersion' ''); status = [string] (Get-WdhKey $Data 'status' '')
        updateState = [string] (Get-WdhKey $Data 'updateState' ''); updateStateText = [string] (Get-WdhKey $Data 'updateStateText' '')
        startedUtc = [string] (Get-WdhKey $Data 'startedUtc' ''); finishedUtc = [string] (Get-WdhKey $Data 'finishedUtc' '')
        installed = @(ConvertTo-WdhList (Get-WdhKey $Data 'installed')).Count; failed = @(ConvertTo-WdhList (Get-WdhKey $Data 'failed')).Count
        summary = $summary; verification = $verification
    }
}

<#
    The update policy in force: the engine result's own policy (engine 2.1.0 records previewUpdates),
    else the deployment configuration. Before previewUpdates existed, previews followed optionalUpdates.
#>
function Get-WdhUpdatePolicy {
    param($Data, $Config)
    $p = Get-WdhKey $Data 'policy'
    $has = $p -is [System.Collections.IDictionary]
    $o = [ordered]@{ source = $(if ($has) { 'engine result' } else { 'deployment configuration' }); featureUpdates = ''; optionalUpdates = ''; drivers = ''; previewUpdates = $null; previewSource = 'unknown'; maxAttemptsPerUpdate = $null }
    foreach ($k in 'featureUpdates', 'optionalUpdates', 'drivers') { $o[$k] = $(if ($has -and $null -ne (Get-WdhKey $p $k)) { [string] $p[$k] } else { [string] (Get-WdhKey $Config $k '') }) }
    if ($has -and $null -ne (Get-WdhKey $p 'previewUpdates')) { $o.previewUpdates = [bool] $p['previewUpdates']; $o.previewSource = 'policy' }
    elseif ($null -ne (Get-WdhKey $Config 'previewUpdates')) { $o.previewUpdates = [bool] $Config['previewUpdates']; $o.previewSource = 'configuration' }
    elseif ($o.optionalUpdates) { $o.previewUpdates = ($o.optionalUpdates -ne 'skip'); $o.previewSource = 'optionalUpdates' }
    if ($has -and $null -ne (Get-WdhKey $p 'maxAttemptsPerUpdate')) { $o.maxAttemptsPerUpdate = [int] $p['maxAttemptsPerUpdate'] }
    return $o
}

<#
    Retry Windows Update runs. One task (\WindowsDeploymentBuilder\WindowsUpdateRetry) serves every run
    and the engine removes it when its run is final: an unfinished run is running (or waiting for a
    restart) only while that task exists, and only the newest unfinished run can be the one it serves.
#>
function Get-WdhRetryView {
    param($C)
    $runs = @(ConvertTo-WdhList (Invoke-WdhProbe $C 'retryRuns' { Get-WdhRetryRuns $C.Paths.Root }))
    if (-not $runs.Count) { return @() }
    $task = [bool] (Invoke-WdhProbe $C 'retryTask' { Test-WdhRetryTask })
    $open = @($runs | Where-Object { -not [string] (Get-WdhKey $_['state'] 'final' '') })
    $newestOpen = $(if ($open.Count) { [string] $open[-1]['runId'] } else { '' })
    $out = @()
    foreach ($r in $runs) {
        $final = [string] (Get-WdhKey $r['state'] 'final' '')
        $state = $(if ($final) { 'Finished' } elseif ($task -and [string] $r['runId'] -eq $newestOpen) { 'RunningOrAwaitingRestart' } else { 'StoppedBeforeFinishing' })
        $out += , @{ runId = [string] $r['runId']; selection = [string] (Get-WdhKey $r['config'] 'selection' ''); final = $final; state = $state; taskPresent = $task; result = $r['result']
                     view = (Get-WdhUpdateResultView $r['result'] "retry:$($r['runId'])" "Retry Windows Update run $($r['runId'])") }
    }
    return $out
}

<#
    An original failure installed later: in a Retry Windows Update run's installed[] (same KB or exact
    title), or as a successful installation in Windows Update's own history after the failure.
#>
function Find-WdhLaterInstall {
    param($Failure, [object[]] $RetryInstalls, [object[]] $History, $After)
    $kbs = @(Get-WdhKbs $Failure)
    $title = [string] (Get-WdhKey $Failure 'title' '')
    foreach ($i in @($RetryInstalls | Where-Object { $_ })) {
        if (@($kbs | Where-Object { $_ -in @($i['kbs']) }).Count -or ($title -and $title -ieq [string] $i['title'])) { return $i }
    }
    foreach ($h in @($History | Where-Object { $_ })) {
        if ([int] (Get-WdhKey $h 'operation' 0) -ne 1 -or [int] (Get-WdhKey $h 'resultCode' 0) -notin 2, 3) { continue }
        $d = ConvertTo-WddDate (Get-WdhKey $h 'dateUtc' '')
        if ($After -and $d -and $d -lt $After) { continue }
        $hk = @(Get-WdhKbs $h)
        if (@($kbs | Where-Object { $_ -in $hk }).Count -or ($title -and $title -ieq [string] $h['title'])) { return @{ title = [string] $h['title']; kbs = $hk; atUtc = [string] $h['dateUtc']; by = 'Windows Update (its installation history)' } }
    }
    return $null
}

function Test-WdhUpdates {
    param($C)
    $wu = $C.Config['windowsUpdate']
    if ($wu -isnot [System.Collections.IDictionary]) { $wu = @{ enabled = $false } }
    $svc = Invoke-WdhProbe $C 'services' { Get-WdhServices }
    $agent = Invoke-WdhProbe $C 'updateAgent' { Get-WdhUpdateAgent }
    if ($svc -and $svc['wuauserv']) {
        $s = $svc['wuauserv']
        if ($s.startMode -eq 'Disabled') { Add-WdhFinding $C 'updates.service' 'updates' 'Windows Update service' 'Fail' 'Error' 'Available (not disabled)' 'Disabled' 'Win32_Service wuauserv' 'Services' 'Something disabled Windows Update; set the service back to Manual (not changed by this check).' | Out-Null }
        else { Add-WdhFinding $C 'updates.service' 'updates' 'Windows Update service' 'Pass' 'Error' 'Available (not disabled)' "$($s.startMode), $($s.state)" 'Win32_Service wuauserv' 'Services' | Out-Null }
    } else { Add-WdhFinding $C 'updates.service' 'updates' 'Windows Update service' 'Unverifiable' 'Error' 'Available' 'Could not be read' 'Win32_Service wuauserv' 'Services' | Out-Null }
    $sec = [ordered]@{ partOfDeployment = [bool] $wu['enabled']; checkedUtc = (Get-WdhTime).ToString('o'); original = $null; current = $null; policy = $null; settingsRefresh = $null; orchestrator = $null
                       retries = @(); originalFailures = @(); drivers = @(); liveScan = $null }
    $C.WindowsUpdate = $sec
    # Retry Windows Update runs decide the current state; the deployment's own result stays its historical record.
    $runs = @(Get-WdhRetryView $C)
    $cur = $null
    foreach ($x in @($runs | Where-Object { $_.state -eq 'Finished' -and $_.view })) {
        if (-not $cur) { $cur = $x; continue }
        $a = ConvertTo-WddDate $x.view.finishedUtc; $b = ConvertTo-WddDate $cur.view.finishedUtc
        if (-not $a -or -not $b -or $a -ge $b) { $cur = $x }
    }
    $data = $null; $origFinal = $false; $snap = $null; $r = $null
    if ($wu['enabled']) {
        $r = Read-WdhSource $C 'windowsUpdate' 'Updates\result.json'
        $snap = @($C.Snapshot.stages | Where-Object { $_.id -eq 'windowsUpdate' }) | Select-Object -First 1
        $data = $r.Data
        $C.UpdateResult = $data
        $origFinal = [bool] ($data -and $snap -and $snap.state -eq 'Final')
        if ($data) { $sec.original = Get-WdhUpdateResultView $data 'original' 'Initial Windows Update (deployment)' }
    }
    $curView = $(if ($cur) { $cur.view } elseif ($origFinal) { $sec.original } else { $null })
    $curData = $(if ($cur) { $cur.result } elseif ($origFinal) { $data } else { $null })
    $curFile = $(if ($cur) { "UpdateRetry\$($cur.runId)\result.json" } else { 'Updates\result.json' })
    $sec.current = $curView
    $stateKnown = [bool] ($curView -and $curView.updateState)
    if (-not $wu['enabled']) {
        Add-WdhFinding $C 'updates.stage' 'updates' 'Initial Windows Update' 'NotApplicable' 'Informational' 'Not part of this deployment' "Windows updates itself on its own schedule$(if ($agent -and $agent.lastSearchUtc) { "; last successful search $($agent.lastSearchUtc)" })" 'Deployment configuration' 'health-config.json' -Required $false | Out-Null
    } else {
        if ($r.Source.state -eq 'corrupt') { Add-WdhFinding $C 'updates.stage' 'updates' 'Initial Windows Update' 'Unverifiable' 'Error' 'Every applicable update installed' 'The update result is damaged' 'Updates\result.json' 'Updates\result.json' 'Run "Deployment recovery" > Retry failed operations to run the update stage again (installed updates are never offered again).' -RecoveryAction 'RetryFailed' | Out-Null }
        elseif (-not $data -or -not $snap -or $snap.state -ne 'Final') {
            $stateText = $(if ($snap) { "$($snap.state)$(if ($snap.status) { "/$($snap.status)" })" } else { 'not started' })
            $staleFinal = $C.StateRead.State -and [string] $C.StateRead.State['status'] -eq 'Completed' -and -not $data
            if ($staleFinal) { Add-WdhFinding $C 'updates.stage' 'updates' 'Initial Windows Update' 'Unverifiable' 'Error' 'Every applicable update installed' 'The deployment ended but the update stage left no result' 'Updates\result.json vs deployment state' 'Updates\result.json' 'Run "Deployment recovery" > Resume.' -RecoveryAction 'Resume' | Out-Null }
            else { Add-WdhFinding $C 'updates.stage' 'updates' 'Initial Windows Update' 'Pending' 'Error' 'Every applicable update installed' "Still running ($stateText)" 'Updates\status.json, the stage task' 'Updates\status.json' 'Wait; the stage continues by itself (it restarts the computer when needed).' -AutomaticRecovery $true -TechnicianRequired $false | Out-Null }
        } else {
            $failed = @(ConvertTo-WdhList $data['failed'])
            $installed = @(ConvertTo-WdhList $data['installed']).Count
            $ev = [string] (Get-WdhKey $data 'engineVersion' '')
            $engineText = $(if ($ev) { " (engine $ev, finished $($data['finishedUtc']))" } else { '' })
            $st = ''; $obs = ''; $next = ''; $rec = ''; $method = 'Updates\result.json'
            switch ([string] $data['status']) {
                'Succeeded' { $st = $(if ($stateKnown) { 'Info' } else { 'Pass' }); $method = 'Updates\result.json and the Windows Update Agent'; $obs = "Succeeded: $installed installed, $([int] $data['reboots']) restart(s)$engineText$(if ($agent -and $agent.lastSearchUtc) { "; Windows Update's last successful search $($agent.lastSearchUtc)" })" }
                'Offline' { $st = 'Fail'; $obs = 'Not done: there was no network before the stage''s time limit'; $next = 'Connect the network, then "Deployment recovery" > Retry failed operations.'; $rec = 'RetryFailed' }
                'Failed' { $st = 'Fail'; $obs = "Failed: $($data['reason'])$engineText"; $next = 'See Updates\logs\engine.log, fix the cause, then "Deployment recovery" > Retry failed operations.'; $rec = 'RetryFailed' }
                default { $st = $(if ($failed.Count -or $stateKnown) { 'Info' } else { 'Pass' }); $obs = "$($data['status']): $installed installed, $($failed.Count) failed$engineText" }
            }
            if ($stateKnown -and $st -eq 'Info') { $obs += '. Whether Windows is up to date is the separate "Windows Update state" check' }
            # A later retry run decides the current state; this result stays the deployment's own (historical) record.
            if ($cur) { $st = $(if ($st -eq 'Pass') { 'Pass' } else { 'Info' }); $obs = "Original deployment (historical record, unchanged): $obs. A later Retry Windows Update run ($($cur.runId)) finished $($cur.final); it decides the current state"; $next = ''; $rec = '' }
            Add-WdhFinding $C 'updates.stage' 'updates' 'Initial Windows Update' $st 'Error' 'Every applicable update installed' $obs $method 'Updates\result.json' $next -RecoveryAction $rec | Out-Null
            # Original failures: historical facts. Each is compared with later installations (retry runs, Windows Update history).
            $retryInstalls = @()
            foreach ($x in $runs) {
                foreach ($i in @(ConvertTo-WdhList (Get-WdhKey $x.result 'installed'))) {
                    if ($i -isnot [System.Collections.IDictionary]) { continue }
                    $retryInstalls += , @{ title = [string] (Get-WdhKey $i 'title' ''); kbs = @(Get-WdhKbs $i); atUtc = [string] (Get-WdhKey $i 'atUtc' (Get-WdhKey $x.result 'finishedUtc' '')); by = "Retry Windows Update run $($x.runId)" }
                }
            }
            $history = @()
            if ($failed.Count) { $history = @(ConvertTo-WdhList (Invoke-WdhProbe $C 'updateHistory' { Get-WdhUpdateHistory })) }
            $after = ConvertTo-WddDate (Get-WdhKey $data 'finishedUtc' '')
            foreach ($f in $failed) {
                $kbs = @(Get-WdhKbs $f)
                $kb = @(@(ConvertTo-WdhList (Get-WdhKey $f 'kbs')) + $kbs) | Select-Object -First 1
                $title = [string] (Get-WdhKey $f 'title' '')
                $fid = $(if ($kb) { "updates.kb.$kb" } else { "updates.update.$(Get-WdhShortHash $title)" })
                $cls = @(@([string] (Get-WdhKey $f 'category' ''), [string] (Get-WdhKey $f 'class' '')) | Where-Object { $_ }) -join ', '
                $what = "$($title): failed after $(Get-WdhKey $f 'attempts' '?') attempt(s) ($(Get-WdhKey $f 'lastHResult' 'no code')$(if ($cls) { ", $cls" }))"
                $m = Find-WdhLaterInstall $f $retryInstalls $history $after
                if ($m) { Add-WdhFinding $C $fid 'updates' "Update $(if ($kb) { "$kb " })failed originally, installed later" 'Info' 'Informational' 'Installed' "Originally failed (historical record, unchanged): $what. Installed later on $($m['atUtc']) by $($m['by'])." 'Updates\result.json failed[] compared with Retry Windows Update results and the Windows Update history (read-only)' 'Updates\result.json, UpdateRetry\<run>\result.json, Windows Update history' -Required $false -TechnicianRequired $false | Out-Null }
                else { Add-WdhFinding $C $fid 'updates' "Update $(if ($kb) { "$kb " })failed" 'Fail' 'Error' 'Installed' $what 'Updates\result.json failed[]; no later installation found in retry results or the Windows Update history' 'Updates\result.json' 'Retry the update stage ("Deployment recovery" > Retry failed operations), run Retry Windows Update, or install it from Settings > Windows Update.' -RecoveryAction 'RetryFailed' | Out-Null }
                $sec.originalFailures += , [ordered]@{ title = $title; kbs = @($kbs); category = [string] (Get-WdhKey $f 'category' ''); class = [string] (Get-WdhKey $f 'class' ''); lastHResult = [string] (Get-WdhKey $f 'lastHResult' '')
                                                     laterInstalled = [bool] $m; installedUtc = $(if ($m) { [string] $m['atUtc'] } else { '' }); installedBy = $(if ($m) { [string] $m['by'] } else { '' }); findingId = $fid }
            }
        }
    }
    # Retry Windows Update runs (each one listed; running, finished or stopped).
    foreach ($x in $runs) {
        $fid = "updates.retry.$($x.runId -replace '[^A-Za-z0-9_:+\-]', '-')"
        $v = $x.view
        $counts = $(if ($v) { "installed $($v.installed), failed $($v.failed)$(if ($v.engineVersion) { ", engine $($v.engineVersion)" })$(if ($v.updateState) { ", state $($v.updateState)" })$(if ($v.finishedUtc) { ", finished $($v.finishedUtc)" })" } else { 'no result yet' })
        $sel = $(if ($x.selection) { "selection $($x.selection)" } else { 'selection not recorded' })
        $title = "Retry Windows Update run $($x.runId)"
        $ev = "UpdateRetry\$($x.runId)\ (config.json, state.json, result.json)"
        switch ($x.state) {
            'Finished' { Add-WdhFinding $C $fid 'updates' $title 'Info' 'Informational' 'Finished' "Finished ($($x.final)), $sel; $counts" 'state.json final and result.json of the run' $ev -Required $false -TechnicianRequired $false | Out-Null }
            'RunningOrAwaitingRestart' { Add-WdhFinding $C $fid 'updates' $title 'Pending' 'Warning' 'Finished' "Running or awaiting a restart (not final yet; the WindowsUpdateRetry task exists), $sel; $counts" 'state.json (no final status) and the \WindowsDeploymentBuilder\WindowsUpdateRetry task' $ev 'Wait; the retry continues by itself, also after a restart. Verify again when it has finished.' -Required $false -AutomaticRecovery $true -TechnicianRequired $false | Out-Null }
            default { Add-WdhFinding $C $fid 'updates' $title 'Warning' 'Warning' 'Finished' "Stopped before finishing: no final status and no WindowsUpdateRetry task remains, $sel; $counts" 'state.json (no final status) and the scheduled task list' $ev 'Start Retry Windows Update again (Deployment recovery, or Invoke-WindowsUpdateRetry.ps1 -Mode RetryUpdates); installed updates are never offered again.' -Required $false | Out-Null }
        }
        $sec.retries += , [ordered]@{ runId = $x.runId; selection = $x.selection; final = $x.final; state = $x.state; taskPresent = [bool] $x.taskPresent
                                      engineVersion = $(if ($v) { [string] $v.engineVersion } else { '' }); status = $(if ($v) { [string] $v.status } else { '' }); updateState = $(if ($v) { [string] $v.updateState } else { '' })
                                      installed = $(if ($v) { [int] $v.installed } else { 0 }); failed = $(if ($v) { [int] $v.failed } else { 0 }); finishedUtc = $(if ($v) { [string] $v.finishedUtc } else { '' }); findingId = $fid }
    }
    # The current Windows Update state (engine 2.1.0 updateState), from the most recent finished result.
    $scan = $null
    if ($C.ScanUpdates) { $scan = Invoke-WdhProbe $C 'updateScan' { Get-WdhUpdateScan } }
    if ($stateKnown) {
        $us = [string] $curView.updateState
        $m = $(if ($script:WdhUpdateStates.ContainsKey($us)) { $script:WdhUpdateStates[$us] } else { @('Unverifiable', "Unknown state (written by a newer engine)") })
        $st = $m[0]
        $text = $(if ($curView.updateStateText) { [string] $curView.updateStateText } else { $m[1] })
        $from = $(if ($cur) { "Retry Windows Update run $($cur.runId)" } else { 'the deployment''s update stage' })
        $parts = @()
        if ($curView.summary) { $parts += 'summary: ' + (@($curView.summary.Keys | ForEach-Object { "$_ $($curView.summary[$_])" }) -join ', ') }
        if ($curView.verification) {
            $vv = $curView.verification
            $parts += "final check: $(if ($null -ne $vv.remainingOffered) { "$($vv.remainingOffered) still offered" } else { 'offered count not recorded' }), $($vv.noLongerOffered) no longer offered, $($vv.devicesWithProblems) device(s) with problems, restart pending $(if ($null -ne $vv.rebootPending) { $vv.rebootPending } else { 'not recorded' })"
        }
        $obs = "$($us): $text. Recorded by $from (engine $(if ($curView.engineVersion) { $curView.engineVersion } else { 'unknown' }), finished $($curView.finishedUtc))$(if ($parts.Count) { '; ' + ($parts -join '; ') })"
        if ($us -eq 'VerificationUnavailable' -and $scan -and [int] $scan.required -eq 0) { $st = 'Info'; $obs += '. A live read-only scan now finds no required update' }
        $next = switch ($us) {
            'RestartRequired' { 'Restart the computer, then verify again (with -ScanUpdates to ask Windows Update what is still offered).' }
            'UpdatesRemaining' { 'Install them from Settings > Windows Update, or run Retry Windows Update; then verify again.' }
            { $_ -in 'InstallationIncomplete', 'CompletedWithFailures' } { 'See the failed updates in this report; run Retry Windows Update (Deployment recovery) or install them from Settings > Windows Update.' }
            'VerificationUnavailable' { 'Verify again with -ScanUpdates when online, or check Settings > Windows Update.' }
            default { '' }
        }
        if ($st -eq 'Info') { $next = '' }
        Add-WdhFinding $C 'updates.state' 'updates' 'Windows Update state' $st $(if ($st -eq 'Warning') { 'Warning' } else { 'Error' }) 'Up to date under this deployment''s policy' $obs 'updateState of the engine''s result.json (update engine 2.1.0 or later); never concluded from "the installation finished"' $curFile $next -RecoveryAction $(if ($st -eq 'Fail') { 'RetryFailed' } else { '' }) | Out-Null
    }
    if ($cur -and $sec.original) {
        $o = $sec.original
        Add-WdhFinding $C 'updates.originalState' 'updates' 'Windows Update at the end of the deployment' 'Info' 'Informational' 'Historical record' "$($o.status)$(if ($o.updateState) { " / $($o.updateState)" }): $($o.installed) installed, $($o.failed) failed (finished $($o.finishedUtc)). Kept unchanged as the deployment's record; the current state comes from the later Retry Windows Update run $($cur.runId)." 'Updates\result.json' 'Updates\result.json' -Required $false -TechnicianRequired $false | Out-Null
    }
    # Policy: what the deployment installs by design, and what it intentionally leaves out.
    if ($wu['enabled'] -or $cur) {
        $pol = Get-WdhUpdatePolicy $(if ($curData) { $curData } else { $data }) $wu
        $sec.policy = $pol
        $in = @('security and quality updates'); $out = @()
        if ($pol.featureUpdates -eq 'install') { $in += 'feature updates' } else { $out += 'feature updates (a new Windows version) are skipped' }
        if ($pol.optionalUpdates -eq 'skip') { $out += 'optional updates are excluded by policy' } elseif ($pol.optionalUpdates) { $in += 'optional updates' }
        if ($pol.drivers -eq 'exclude') { $out += 'drivers from Windows Update are excluded by policy' } elseif ($pol.drivers) { $in += 'drivers that Windows Update offers' }
        $pv = $(if ($pol.previewSource -eq 'optionalUpdates') { ' (this engine had no separate preview setting: previews followed the optional-update policy)' } else { '' })
        if ($pol.previewUpdates -eq $false) { $out += "preview updates are intentionally excluded by policy$pv" } elseif ($pol.previewUpdates -eq $true) { $in += "preview updates$pv" }
        Add-WdhFinding $C 'updates.scope' 'updates' 'Update policy' 'Info' 'Informational' "Installed by policy: $($in -join ', ')" $(if ($out.Count) { "Not installed by design: $($out -join '; '). This report does not claim that excluded updates are installed" } else { 'Nothing is excluded by policy' }) "Policy of the engine's result.json, else the deployment configuration (here: $($pol.source))" $(if ($curData) { $curFile } else { 'health-config.json' }) -Required $false | Out-Null
        $pe = $(if ($curView -and $curView.summary -and $curView.summary.Contains('previewsExcluded')) { [int] $curView.summary['previewsExcluded'] } else { $null })
        if ($pol.previewUpdates -eq $false) { Add-WdhFinding $C 'updates.previews' 'updates' 'Preview updates' 'Info' 'Informational' 'Not installed (policy)' "Intentionally excluded by policy$pv$(if ($pe) { ": $pe preview update(s) were offered and not installed" } else { '' })" 'policy.previewUpdates and summary.previewsExcluded of the engine''s result.json' $(if ($curData) { $curFile } else { 'health-config.json' }) -Required $false -TechnicianRequired $false | Out-Null }
        elseif ($pol.previewUpdates -eq $true) { Add-WdhFinding $C 'updates.previews' 'updates' 'Preview updates' 'Info' 'Informational' 'Installed (policy)' "Included by policy$pv; remaining previews count as remaining updates in the Windows Update state" 'policy.previewUpdates of the engine''s result.json' $(if ($curData) { $curFile } else { 'health-config.json' }) -Required $false -TechnicianRequired $false | Out-Null }
    }
    # The final Settings refresh the engine requested (2.1.0): requested, completed, and what is NOT verified.
    $srcData = $(if (Get-WdhKey $curData 'settingsRefresh') { $curData } elseif (Get-WdhKey $data 'settingsRefresh') { $data } else { $null })
    if ($srcData -and $srcData['settingsRefresh'] -is [System.Collections.IDictionary]) {
        $sr = $srcData['settingsRefresh']
        $g = { param([string] $k) [string] (Get-WdhKey $sr $k '') }
        $view = [ordered]@{ from = $(if ($srcData -eq $curData) { $curFile } else { 'Updates\result.json' }); available = [bool] (Get-WdhKey $sr 'available' $false); requested = [bool] (Get-WdhKey $sr 'requested' $false); completed = [bool] (Get-WdhKey $sr 'completed' $false)
                            attempt = (& $g 'attempt'); requestedUtc = (& $g 'requestedUtc'); completedUtc = (& $g 'completedUtc'); lastSuccessfulScanBefore = (& $g 'lastSuccessfulScanBefore'); lastSuccessfulScanAfter = (& $g 'lastSuccessfulScanAfter')
                            settingsDisplayVerified = $false; message = (ConvertTo-WdhSafeText (& $g 'message')) }
        $sec.settingsRefresh = $view
        $nr = { param([string] $t) if ($t) { $t } else { 'not recorded' } }
        $obs = $(if (-not $view.available) { 'Not available on this Windows (the Windows Update orchestrator API needs Windows 11 24H2 or later); no scan was requested' }
                 elseif (-not $view.requested) { 'Not requested by the engine' }
                 elseif ($view.completed) { "Scan requested ($(& $nr $view.requestedUtc)) and completed: the last successful scan timestamp advanced from $(& $nr $view.lastSuccessfulScanBefore) to $(& $nr $view.lastSuccessfulScanAfter)" }
                 else { "Scan requested ($(& $nr $view.requestedUtc)); completion not confirmed: the last successful scan timestamp did not advance (before $(& $nr $view.lastSuccessfulScanBefore), after $(& $nr $view.lastSuccessfulScanAfter))" })
        $obs += '. The Settings page display itself is NOT verified by the engine (settingsDisplayVerified = false)'
        if ($view.message) { $obs += ". Engine: $($view.message)" }
        Add-WdhFinding $C 'updates.settingsRefresh' 'updates' 'Final Settings refresh (Windows Update page)' 'Info' 'Informational' 'A final scan, so Settings shows the current state' $obs 'settingsRefresh of the engine''s result.json' $view.from 'Open Settings > Windows Update to see what it shows; this report cannot see that page.' -Required $false -TechnicianRequired $false | Out-Null
    }
    # What Settings shows as "Last checked" (read-only orchestrator properties; no scan is started).
    $orc = Invoke-WdhProbe $C 'orchestratorScan' { Get-WdhOrchestratorScan }
    $sec.orchestrator = [ordered]@{ available = [bool] $orc; lastSuccessfulScanUtc = $(if ($orc) { [string] $orc.lastSuccessfulScanUtc } else { '' }); isScanning = $(if ($orc) { [bool] $orc.isScanning } else { $null }); isWorking = $(if ($orc) { [bool] $orc.isWorking } else { $null }) }
    $orcObs = $(if ($orc) { "Last successful check: $(if ($orc.lastSuccessfulScanUtc) { $orc.lastSuccessfulScanUtc } else { 'none recorded' })$(if ($orc.isScanning) { '; a check is running now' })$(if ($orc.isWorking) { '; Windows Update is working now' })" } else { 'Not available: the Windows Update orchestrator API (Windows 11 24H2 and later) does not exist on this Windows or could not be read' })
    Add-WdhFinding $C 'updates.settingsLastCheck' 'updates' 'Windows Update (Settings) last successful check' 'Info' 'Informational' 'Reported' $orcObs 'Windows.Management.Update.WindowsUpdateManager: LastSuccessfulScanTimestamp, IsScanning, IsWorking (read-only; no scan is started)' 'Windows Update orchestrator' -Required $false -TechnicianRequired $false | Out-Null
    # Drivers that Windows Update installed (deployment and retry runs).
    $drv = @()
    foreach ($src in @(@(@{ d = $data; by = 'deployment' }) + @($runs | ForEach-Object { @{ d = $_.result; by = "retry $($_.runId)" } }))) {
        foreach ($d in @(ConvertTo-WdhList (Get-WdhKey $src.d 'drivers'))) {
            if ($d -isnot [System.Collections.IDictionary]) { continue }
            $dev = Get-WdhKey $d 'device'
            $drv += , [ordered]@{ title = [string] (Get-WdhKey $d 'title' ''); model = [string] (Get-WdhKey $dev 'model' ''); hardwareId = [string] (Get-WdhKey $dev 'hardwareID' (Get-WdhKey $dev 'hardwareId' '')); result = [string] (Get-WdhKey $d 'result' ''); installedBy = $src.by }
        }
    }
    $sec.drivers = $drv
    if ($drv.Count) { Add-WdhFinding $C 'updates.drivers' 'updates' 'Drivers installed through Windows Update' 'Info' 'Informational' 'Reported' "$($drv.Count) driver(s): $((@($drv | Select-Object -First 5) | ForEach-Object { "$($_.title)$(if ($_.model) { " ($($_.model))" }) [$($_.result)]" }) -join '; ')$(if ($drv.Count -gt 5) { '; ...' })" 'drivers[] of the engine''s result.json' 'Updates\result.json, UpdateRetry\<run>\result.json' -Required $false -TechnicianRequired $false | Out-Null }
    if ($C.ScanUpdates) {
        $sec.liveScan = [ordered]@{ performed = [bool] $scan; required = $(if ($scan) { [int] $scan.required } else { 0 }); optional = $(if ($scan) { [int] $scan.optional } else { 0 }); drivers = $(if ($scan) { [int] $scan.drivers } else { 0 }); feature = $(if ($scan) { [int] $scan.feature } else { 0 }) }
        if ($null -eq $scan) { Add-WdhFinding $C 'updates.scan' 'updates' 'Windows Update scan' 'Unverifiable' 'Warning' 'Scan completed' 'The scan was not possible (no network, or the service is busy)' 'Microsoft.Update.Session search (read-only)' 'Windows Update Agent' 'Try again when online.' -Required $false | Out-Null }
        elseif ($scan.required) { Add-WdhFinding $C 'updates.scan' 'updates' 'Updates still available' 'Warning' 'Warning' 'No required update outstanding' "$($scan.required) update(s) available now: $($scan.titles -join '; ')$(if ($scan.optional -or $scan.drivers -or $scan.feature) { ". Also $($scan.optional) optional, $($scan.drivers) driver, $($scan.feature) feature update(s)" })" 'Microsoft.Update.Session search (read-only)' 'Windows Update Agent' 'Install them from Settings > Windows Update, or retry the update stage.' -Required $false | Out-Null }
        else { Add-WdhFinding $C 'updates.scan' 'updates' 'Windows Update scan' 'Pass' 'Warning' 'No required update outstanding' "None required now ($($scan.optional) optional, $($scan.drivers) driver, $($scan.feature) feature update(s) not counted)" 'Microsoft.Update.Session search (read-only)' 'Windows Update Agent' -Required $false | Out-Null }
    } else { $C.Limitations.Add('No live Windows Update scan was made (run with -ScanUpdates to ask Windows Update what is still available). The update results above are the engines'' own evidence.') }
    # Ongoing policy (Phase 4.3), and whether Windows Update may offer drivers (Phase 8 driver stage).
    if ($wu['ongoingPolicy']) {
        $pol = $(if ($C.StateRead.State -and $C.StateRead.State.ContainsKey('updatePolicy')) { $C.StateRead.State['updatePolicy'] } else { $null })
        if ($pol -is [hashtable] -and [string] $pol['status'] -in 'Applied', 'AlreadyApplied') { Add-WdhFinding $C 'updates.policy' 'updates' 'Ongoing update policy' 'Pass' 'Warning' "Applied ($($wu['ongoingPolicy']))" ([string] $pol['status']) 'Deployment state updatePolicy (Set-UpdatePolicy.ps1)' 'state\deployment.json' -Required $false | Out-Null }
        elseif ($pol -is [hashtable] -and [string] $pol['status'] -in 'ManagedByOrganization', 'Unsupported') { Add-WdhFinding $C 'updates.policy' 'updates' 'Ongoing update policy' 'Info' 'Informational' "Applied ($($wu['ongoingPolicy']))" "$($pol['status']): $($pol['message'])" 'Deployment state updatePolicy' 'state\deployment.json' -Required $false | Out-Null }
        elseif ($pol -is [hashtable]) { Add-WdhFinding $C 'updates.policy' 'updates' 'Ongoing update policy' 'Warning' 'Warning' "Applied ($($wu['ongoingPolicy']))" "$($pol['status']): $($pol['message'])" 'Deployment state updatePolicy' 'state\deployment.json' 'Set it under Settings > Windows Update, or re-run the deployment.' -Required $false | Out-Null }
        else { Add-WdhFinding $C 'updates.policy' 'updates' 'Ongoing update policy' $(if ($C.Snapshot.allFinal) { 'Warning' } else { 'Pending' }) 'Warning' "Applied ($($wu['ongoingPolicy']))" 'Not applied yet' 'Deployment state updatePolicy' 'state\deployment.json' $(if ($C.Snapshot.allFinal) { 'Set it under Settings > Windows Update.' } else { 'It is applied once the initial update stage has finished.' }) -Required $false | Out-Null }
    }
    $ex = Get-WdhRegValue 'HKLM' 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate'
    $blocked = $null -ne $ex -and [int] $ex -eq 1
    if ([string] $wu['drivers'] -eq 'include' -and $blocked) { Add-WdhFinding $C 'updates.driverPolicy' 'updates' 'Drivers from Windows Update' 'Warning' 'Warning' 'Windows Update may offer drivers' 'Blocked by policy (ExcludeWUDriversInQualityUpdate = 1, set by an organization or an older profile)' 'HKLM Policies WindowsUpdate' 'Registry' 'Leave it if an organization manages updates; otherwise drivers come only from the driver stage or Device Manager.' -Required $false | Out-Null }
    else { Add-WdhFinding $C 'updates.driverPolicy' 'updates' 'Drivers from Windows Update' 'Info' 'Informational' $(if ([string] $wu['drivers'] -eq 'include') { 'Windows Update may offer drivers' } else { 'Windows Update does not install drivers (configured)' }) $(if ($blocked) { 'Blocked by policy' } else { 'Allowed' }) 'HKLM Policies WindowsUpdate ExcludeWUDriversInQualityUpdate' 'Registry' -Required $false | Out-Null }
}

# ------------------------------------------------------------------------------------------------
# Applications: only what this deployment selected
# ------------------------------------------------------------------------------------------------

function Find-WdhInstalled {
    param($Item, [object[]] $Entries, [object[]] $Appx, [string[]] $Shortcuts)
    $pkgId = ([string] $Item['packageIdentifier']).ToLowerInvariant()
    $names = @(@(ConvertTo-WdhList $Item['names']) | ForEach-Object { Get-WdhNorm ([string] $_) } | Where-Object { $_.Length -ge 3 })
    foreach ($e in $Entries) {
        $key = ([string] $e.keyName).ToLowerInvariant()
        # WinGet registers portable packages (and some others) under "<PackageIdentifier>_<source>".
        if ($pkgId -and ($key -eq $pkgId -or $key.StartsWith("$($pkgId)_"))) { return @{ found = $true; scope = $e.scope; version = $e.displayVersion; how = 'WinGet uninstall record' } }
    }
    # The name match drops architecture words, so an item that names one (the Visual C++ runtimes:
    # x86 and x64 are independent installations) only matches a record of the same architecture.
    $wantArch = @(@(ConvertTo-WdhList $Item['names']) | ForEach-Object { Get-WdhArch ([string] $_) } | Where-Object { $_ } | Select-Object -Unique)
    foreach ($e in $Entries) {
        if (-not $e.displayName) { continue }
        if ($wantArch.Count) { $has = Get-WdhArch ([string] $e.displayName); if ($has -and $has -notin $wantArch) { continue } }
        $n = Get-WdhNorm $e.displayName
        foreach ($want in $names) {
            if ($n -eq $want -or (" $n " -like "* $want *")) { return @{ found = $true; scope = $e.scope; version = $e.displayVersion; how = "uninstall record ""$($e.displayName)""$(if ([string] $e['view'] -eq '32') { ' (32-bit)' })" } }
        }
    }
    if ([string] $Item['source'] -eq 'msstore' -and $Appx) {
        foreach ($a in $Appx) {
            $flat = (([string] $a.name) + ' ' + ([string] $a.family)).ToLowerInvariant() -replace '[^a-z0-9 ]', ''
            foreach ($want in $names) { if ($flat.Contains(($want -replace ' ', ''))) { return @{ found = $true; scope = 'user'; version = $a.version; how = "Store package $($a.name)" } } }
        }
    }
    if ($Item['shortcut'] -and $Shortcuts -contains [string] $Item['shortcut']) { return @{ found = $true; scope = 'machine'; version = ''; how = 'portable tool shortcut' } }
    return @{ found = $false; scope = ''; version = ''; how = '' }
}

<#
    Health engine 1.2.0: the evidence the catalog names for one application (health-config.json
    items[].verify: the application engine's verifySpec). Older plans have none: an empty spec, and
    the name match of Find-WdhInstalled alone decides, as in 1.1.0. Malformed values are ignored.
#>
function Get-WdhVerifySpec {
    param($Item)
    $spec = @{ uninstall = @(); appx = @(); files = @(); registry = @(); perUser = $false; after = 'none' }
    $v = Get-WdhKey $Item 'verify' $null
    if ($v -isnot [System.Collections.IDictionary]) { return $spec }
    $spec.uninstall = @(@(ConvertTo-WdhList (Get-WdhKey $v 'uninstall')) | ForEach-Object { ([string] $_).Trim() } | Where-Object { $_.Length -ge 3 })
    $spec.appx = @(@(ConvertTo-WdhList (Get-WdhKey $v 'appx')) | ForEach-Object { [string] $_ } | Where-Object { $_ -match '^[A-Za-z0-9][A-Za-z0-9.-]{2,99}$' })
    # Only the five known roots, no other variable and no "." or ".." segment (the website's schema enforces the same).
    $spec.files = @(@(ConvertTo-WdhList (Get-WdhKey $v 'files')) | ForEach-Object { [string] $_ } | Where-Object { $_ -match '^%(ProgramFiles|ProgramFiles\(x86\)|ProgramData|LocalAppData|AppData)%(\\[^\\/:*?"<>|%]+)+$' -and $_ -notmatch '\\\.{1,2}(\\|$)' })
    $spec.registry = @(@(ConvertTo-WdhList (Get-WdhKey $v 'registry')) | Where-Object { $_ -is [System.Collections.IDictionary] -and ([string] $_['key']) -match '^HKLM\\SOFTWARE(\\[^\\]+)+$' -and ([string] $_['name']) })
    $spec.perUser = [bool] (Get-WdhKey $v 'perUser' $false)
    $a = [string] (Get-WdhKey $v 'after' 'none')
    $spec.after = $(if ($a -in 'none', 'signIn', 'restart') { $a } else { 'none' })
    return $spec
}

$script:WdhVcRedistId = '^Microsoft\.VCRedist\.(2015\+|2013|2012|2010|2008|2005)\.(x64|x86|arm64)$'

<#
    Visual C++ runtimes in the uninstall records (the application engine's Get-WdaRuntimeInventory,
    replicated over this engine's own, replaceable, uninstall probe):
      "Microsoft Visual C++ 2015-2022 Redistributable (x64) - 14.40.33810"   family 2015+ (v14), x64
      "Microsoft Visual C++ v14 Redistributable (x86) - 14.51.36247"         family 2015+, x86
      "Microsoft Visual C++ 2010  x64 Redistributable - 10.0.40219"          family 2010, x64
    "Minimum Runtime" and "Additional Runtime" are parts of a redistributable and are not listed.
    x86 and x64 are separate runtimes: on 64-bit Windows, 32-bit applications use the x86 one.
#>
function Get-WdhRuntimeItems {
    param([object[]] $Entries)
    $out = @()
    $seen = @{}
    foreach ($e in @($Entries)) {
        if ($null -eq $e) { continue }
        $dn = [string] $e['displayName']
        $m = [regex]::Match($dn, '^Microsoft Visual C\+\+ (v14|\d{4})(-\d{4})?\b.*\bRedistributable\b', 'IgnoreCase')
        if (-not $m.Success) { continue }
        $year = $m.Groups[1].Value
        $family = $(if ($year -ieq 'v14' -or [int] $year -ge 2015) { '2015+' } else { $year })
        if ($family -notin '2015+', '2013', '2012', '2010', '2008', '2005') { continue }
        $am = [regex]::Match($dn, '\b(x64|x86|arm64|amd64)\b', 'IgnoreCase')
        $arch = $(if ($am.Success) { $am.Groups[1].Value.ToLowerInvariant() } elseif ($family -in '2005', '2008') { 'x86' } else { '' })
        if ($arch -eq 'amd64') { $arch = 'x64' }
        if ($arch -notin 'x64', 'x86', 'arm64') { continue }
        $ver = [string] $e['displayVersion']
        if (-not $ver) { $vm = [regex]::Match($dn, '(\d+\.\d+\.\d+(\.\d+)?)\s*$'); if ($vm.Success) { $ver = $vm.Groups[1].Value } }
        $k = "$family|$arch|$ver"
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $out += , [ordered]@{ family = $family; architecture = $arch; version = $ver; displayName = $dn; where = 'machine' }
    }
    return $out
}

<#
    The runtime inventory: the uninstall records (Get-WdhRuntimeItems), plus the Visual C++ 2015+
    runtime keys (HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\<X64|X86|ARM64>, Installed = 1,
    in the 64-bit view for x64/ARM64 and the 32-bit view for x86) for an architecture the records lack,
    as the application engine reads them.
#>
function Get-WdhRuntimeInventory {
    param($C, [object[]] $Entries)
    $items = @(Get-WdhRuntimeItems $Entries)
    foreach ($r in @(@('X64', '64', 'x64'), @('X86', '32', 'x86'), @('ARM64', '64', 'arm64'))) {
        if (@($items | Where-Object { $_.family -eq '2015+' -and $_.architecture -eq $r[2] }).Count) { continue }
        $rk = "SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\$($r[0])"
        $rview = $r[1]
        $inst = Invoke-WdhProbe $C "reg$($rview)|$rk|Installed" { Get-WdhRegValueView $rk 'Installed' $rview }
        if ([string] $inst -ne '1') { continue }
        $ver = [string] (Invoke-WdhProbe $C "reg$($rview)|$rk|Version" { Get-WdhRegValueView $rk 'Version' $rview })
        $items += , [ordered]@{ family = '2015+'; architecture = $r[2]; version = $ver.TrimStart('v'); displayName = "Visual C++ 2015+ runtime key HKLM\$rk ($rview-bit view)"; where = 'machine' }
    }
    return $items
}

<# True when Windows or the deployment reports a restart as pending (the probe Test-WdhRestart already made). #>
function Test-WdhRestartPendingNow {
    param($C)
    $sig = Invoke-WdhProbe $C 'reboot' { Get-WdhRebootSignals }
    $marker = $false
    try { $marker = [bool] (Test-WddRestartPending $C.Paths) } catch { }
    return [bool] ($marker -or ($sig -and ($sig.cbs -or $sig.windowsUpdate -or $sig.agent)))
}

<#
    Health engine 1.2.0: what Windows shows NOW for one selected application. Evidence comes from its
    verify block (the same the application engine checks) and from the name match of
    Find-WdhInstalled, which older plans rely on:
      uninstall  display-name prefix (case-insensitive) in the machine-wide records, 64- and 32-bit
                 (WOW6432Node), and the deployment user's own when that user's registry is loaded
      appx       registered for the deployment user, or provisioned for every user
      file       below Program Files, ProgramData, or the deployment user's profile (never SYSTEM's)
      registry   an HKLM value in the 64- or 32-bit view, optionally with an exact value
      VC++       a Microsoft.VCRedist package: its runtime family and architecture in the records
    Returns @{ found; scope; version; how; evidence; userPending; userWhy; checked; mismatch }.
    userPending: nothing was found and some evidence could not be read now (the user's registry is
    not loaded, the user has no profile yet, the check runs as SYSTEM without either): absence is
    then not a verdict. A user's registry hive is never loaded by this tool.
#>
function Find-WdhAppEvidence {
    param($C, $Item, $Spec, [object[]] $Entries, [object[]] $Appx, [string[]] $Shortcuts, [object[]] $Runtimes)
    $ev = New-Object System.Collections.Generic.List[object]
    $checked = New-Object System.Collections.Generic.List[string]
    $unread = New-Object System.Collections.Generic.List[string]
    $mismatch = New-Object System.Collections.Generic.List[string]
    $userWhere = "user:$($C.DeploymentUser)"
    $add = { param([string] $Kind, [string] $Detail, [string] $Where, [string] $Version) $ev.Add([ordered]@{ kind = $Kind; detail = $Detail; where = $Where; version = [string] $Version }) }
    $legacy = Find-WdhInstalled $Item $Entries $Appx $Shortcuts
    if ($legacy.found) {
        $kind = $(if ($legacy.how -like 'Store package*') { 'appx' } elseif ($legacy.how -like 'portable*') { 'file' } else { 'uninstall' })
        & $add $kind ([string] $legacy.how) $(if ($legacy.scope -eq 'user') { $userWhere } else { 'machine' }) ([string] $legacy.version)
    }
    if ($Spec.uninstall.Count) {
        $checked.Add('uninstall records by name')
        foreach ($e in @($Entries)) {
            if ($null -eq $e) { continue }
            $dn = [string] $e['displayName']
            if (-not $dn) { continue }
            foreach ($p in $Spec.uninstall) {
                if (-not $dn.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { continue }
                & $add 'uninstall' "uninstall record ""$dn""$(if ([string] $e['view'] -eq '32') { ' (32-bit)' })" $(if ([string] $e['scope'] -eq 'user') { $userWhere } else { 'machine' }) ([string] $e['displayVersion'])
                break
            }
        }
    }
    if ($Spec.appx.Count) {
        $checked.Add('Store packages')
        if (-not $C.AppxReadable) { $unread.Add('Store packages could not be read (administrator rights are needed)') }
        foreach ($n in $Spec.appx) {
            $reg = @(@($Appx) | Where-Object { $null -ne $_ -and (([string] $_['name']) -ieq $n -or ([string] $_['family']) -like "$($n)_*") }) | Select-Object -First 1
            if ($reg) { & $add 'appx' "Store package $($reg['name'])" $(if ($C.DeploymentSid) { $userWhere } else { 'machine' }) ([string] $reg['version']); continue }
            $prov = @(ConvertTo-WdhList (Invoke-WdhProbe $C 'appxProvisioned' { , @(Get-WdhProvisionedAppx) }))
            $pp = @($prov | Where-Object { ([string] $_['name']) -ieq $n }) | Select-Object -First 1
            if ($pp) { & $add 'appx' "Store package $($pp['name']), provisioned for every user (each user registers it at sign-in)" 'provisioned' ([string] $pp['version']) }
        }
    }
    if ($Spec.files.Count) {
        $checked.Add('files')
        $folders = Invoke-WdhProbe $C 'machineFolders' { Get-WdhMachineFolders }
        foreach ($f in $Spec.files) {
            $m = [regex]::Match($f, '^%([^%]+)%(\\.+)$')
            $root = $m.Groups[1].Value
            $rest = $m.Groups[2].Value
            $inProfile = $root -in 'LocalAppData', 'AppData'
            $base = ''
            if ($inProfile) {
                $prof = $(if ($C.DeploymentSid) { [string] (Invoke-WdhProbe $C 'userProfile' { Get-WdhUserProfilePath $C.DeploymentSid }) } else { '' })
                if (-not $prof) { $unread.Add($(if (-not $C.DeploymentSid) { "$($C.DeploymentUser) is not known on this computer, so its profile cannot be checked" } else { "$($C.DeploymentUser) has no user profile yet (not signed in since the account was created)" })); continue }
                $base = Join-Path $prof $(if ($root -eq 'LocalAppData') { 'AppData\Local' } else { 'AppData\Roaming' })
            } elseif ($folders) {
                $base = $(switch ($root) { 'ProgramFiles' { [string] $folders.ProgramFiles } 'ProgramFiles(x86)' { $(if ($folders.ProgramFilesX86) { [string] $folders.ProgramFilesX86 } else { [string] $folders.ProgramFiles }) } 'ProgramData' { [string] $folders.ProgramData } default { '' } })
            }
            if (-not $base) { $unread.Add("the folder %$root% could not be resolved"); continue }
            $filePath = $base.TrimEnd('\') + $rest
            $fe = Invoke-WdhProbe $C "file:$filePath" { Get-WdhFileEvidence $filePath }
            if ($null -eq $fe) { $unread.Add("$f could not be read"); continue }
            if ($fe.exists) { & $add 'file' $f $(if ($inProfile) { $userWhere } else { 'machine' }) ([string] $fe.version) }
        }
    }
    if ($Spec.registry.Count) {
        $checked.Add('registry values')
        foreach ($rg in $Spec.registry) {
            $rk = ([string] $rg['key']).Substring(5)
            $rn = [string] $rg['name']
            $rview = $(if ([string] $rg['view'] -eq '32') { '32' } else { '64' })
            $val = Invoke-WdhProbe $C "reg$($rview)|$rk|$rn" { Get-WdhRegValueView $rk $rn $rview }
            if ($null -eq $val) { continue }
            $sval = $(if ($val -is [array]) { (@($val) | ForEach-Object { [string] $_ }) -join ',' } else { [string] $val })
            $want = Get-WdhKey $rg 'equals' $null
            if ($null -ne $want -and $sval -ne [string] $want) { $mismatch.Add("HKLM\$rk\$rn is '$sval', expected '$want'"); continue }
            & $add 'registry' "HKLM\$rk\$rn = $sval$(if ($rview -eq '32') { ' (32-bit view)' })" 'machine' $(if ($rn -match 'version') { $sval } else { '' })
        }
    }
    $rm = [regex]::Match([string] $Item['packageIdentifier'], $script:WdhVcRedistId, 'IgnoreCase')
    if ($rm.Success) {
        $checked.Add('Visual C++ runtimes')
        $fam = $rm.Groups[1].Value; $arch = $rm.Groups[2].Value.ToLowerInvariant()
        foreach ($rt in @(@($Runtimes) | Where-Object { $null -ne $_ -and $_['family'] -eq $fam -and $_['architecture'] -eq $arch })) { & $add 'uninstall' "Visual C++ runtime ""$($rt['displayName'])""" 'machine' ([string] $rt['version']) }
    }
    # The deployment user's own uninstall records exist only while that user's registry is loaded.
    if (-not $C.HiveLoaded -and ($Spec.perUser -or [string] $Item['scope'] -ne 'machine')) {
        $unread.Add($(if (-not $C.DeploymentSid) { "$($C.DeploymentUser) is not known on this computer" }
                      elseif ($C.Identity.IsSystem) { "this check runs as SYSTEM and $($C.DeploymentUser) is not signed in (that user's registry is not loaded; this tool never loads it)" }
                      else { "$($C.DeploymentUser) is not signed in (that user's registry is not loaded; this tool never loads it)" }))
    }
    # One entry per piece of evidence (the name match and a verify prefix can find the same record).
    $list = @()
    $keys = @{}
    foreach ($x in $ev) {
        $k = "$($x.kind)|$((([string] $x.detail) -replace ' \(32-bit\)$', '').ToLowerInvariant())|$($x.where)"
        if (-not $keys.ContainsKey($k)) { $keys[$k] = $true; $list += , $x }
    }
    # Uninstall records and Store packages carry the package version; a file's version may differ.
    $first = @($list | Where-Object { $_.kind -in 'uninstall', 'appx' }) + @($list | Where-Object { $_.kind -notin 'uninstall', 'appx' })
    $withVersion = @($first | Where-Object { $_.version }) | Select-Object -First 1
    $lead = $(if ($first.Count) { $first[0] } else { $null })
    @{
        found = ($list.Count -gt 0)
        scope = $(if (-not $lead) { '' } elseif ($lead.where -like 'user:*') { 'user' } elseif ($lead.where -eq 'provisioned') { 'provisioned' } else { 'machine' })
        version = $(if ($withVersion) { [string] $withVersion.version } else { '' })
        how = $(if ($lead) { [string] $lead.detail } else { '' })
        evidence = @($first)
        userPending = ($list.Count -eq 0 -and $unread.Count -gt 0)
        userWhy = (@($unread | Select-Object -Unique) -join '; ')
        checked = @($checked | Select-Object -Unique)
        mismatch = @($mismatch)
    }
}

<#
    The verdict for one selected application: the evidence found now (Find-WdhAppEvidence) weighed
    against the engine's own record, which is history. Kept apart from detection so a later catalog
    can extend either one. An installer exit code alone never makes an application "installed": only
    evidence in Windows does; and an application with per-user evidence that cannot be read now is
    pending, never "missing". Returns @{ Status; Result; Observed; Next; Severity; Recovery; Verification }.

    Engine 1.6.0 outcomes (result.json "outcome") are read when present; older engines' "status" otherwise:
      InstalledVerified, InstallerSucceededVerification*   the installer succeeded (the evidence decides)
      RestartOrSignInRequired                              pending until a restart or sign-in
      InstallationFailed / PackageUnavailable              Failed / PackageUnavailable
      UnattendedUnsupported / ManualSetupRequired          a person must install or finish it
#>
function Resolve-WdhAppVerdict {
    param($Item, $Engine, $Hit, [hashtable] $X)
    $it = $Item; $e = $Engine; $hit = $Hit
    $eng = [string] $X.eng; $det = [string] $X.det; $msg = [string] $X.msg; $attempts = [int] $X.attempts; $stageFinal = [bool] $X.stageFinal; $snap = $X.snap
    $indep = [string] $X.indep; $where = [string] $X.where; $name = [string] $X.name; $recovery = [string] $X.recovery; $sev = [string] $X.sev; $user = [string] $X.user
    $outcome = [string] $X.outcome; $after = [string] $X.after; $restart = [bool] $X.restart; $why = [string] $X.why; $checked = [string] $X.checked
    $succ = ($eng -in 'Succeeded', 'AlreadyInstalled') -or ($outcome -in 'InstalledVerified', 'InstallerSucceededVerificationPending', 'InstallerSucceededVerificationFailed')
    $label = $(if ($eng) { $eng } else { $outcome })
    $fc = $(if ($e -is [System.Collections.IDictionary] -and $e['failureClass']) { " ($($e['failureClass']))" } else { '' })
    $vf = ''
    $v = $null
    if ([string] $it['kind'] -eq 'manual') {
        if ($hit.found) { $v = @('Pass', 'InstalledManually', "Installed by hand: $where", '') }
        elseif ($indep -eq 'Deferred') { $v = @('Warning', 'ManualInstallationRequired', "Manual follow-up; not found machine-wide ($($user)'s own applications could not be checked)", [string] $it['instructions']) }
        else { $v = @('Warning', 'ManualInstallationRequired', 'Not installed: this application has no unattended installation', $(if ($it['instructions']) { [string] $it['instructions'] } else { "Install $name by hand." })) }
        $sev = 'Warning'
    } elseif ($eng -in 'Pending', 'Installing' -and -not $stageFinal) { $v = @('Pending', 'Pending', "Not installed yet (the application stage is $(if ($snap) { $snap.state } else { 'not started' }))", 'Wait; the stage continues by itself.') }
    elseif (-not $e -and -not $stageFinal -and -not $hit.found) { $v = @('Pending', 'Pending', 'Not installed yet (the application stage has not reached it)', 'Wait; the stage continues by itself.') }
    elseif ($eng -eq 'RequiresRestart' -or ($outcome -eq 'RestartOrSignInRequired' -and -not $hit.found)) {
        $v = @('Pending', 'WaitingForReboot', $(if ($eng -eq 'RequiresRestart') { 'Installed; needs a restart to finish' } else { 'The installer finished; it needs a restart or a sign-in before it can be verified' }), 'Restart the computer (or sign in as the deployment user), then verify again.')
        $vf = $(if ($hit.found) { 'InstalledAndVerified' } else { 'InstallerSucceededVerificationPending' })
    }
    elseif ($eng -eq 'SkippedByUser') { $v = @('NotApplicable', 'SkippedByUser', 'Deselected for this deployment', '') }
    elseif ($hit.found) {
        if ($eng -in 'Succeeded', 'AlreadyInstalled', '' -or ($eng -eq 'RequiresInteraction') -or $succ) {
            $want = [string] $it['version']
            if ($want -and $hit.version -and $hit.version -ne $want) { $v = @('Warning', 'InstalledVersionDiffers', "Installed, version $($hit.version) instead of $want ($where)", 'Check whether the pinned version is still required.') }
            else { $v = @('Pass', $(if ($eng -eq 'AlreadyInstalled') { 'AlreadyInstalledVerified' } else { 'InstalledVerified' }), "Installed: $where$(if (-not $e) { '; the engine has no record of it' })", '') }
        } else { $v = @('Warning', 'InstalledVerificationUncertain', "Present ($where), although the installation reported $label. $msg", 'Open it once to confirm it works; retry it with "Deployment recovery" if it does not.') }
    } elseif ($succ -and $indep -eq 'Deferred') {
        $v = @('Deferred', 'WaitingForUserContext', "The engine reported $label in $($user)'s account; not found machine-wide, and $($user)'s own applications cannot be checked now: $why", "Sign in as $($user) and open the Health Report again.")
        $vf = 'InstallerSucceededVerificationPending'
    } elseif ($succ -and $after -eq 'restart' -and $restart) {
        $v = @('Pending', 'WaitingForReboot', "The engine reported $label; its evidence appears only after the pending restart", 'Restart the computer, then verify again.')
        $vf = 'InstallerSucceededVerificationPending'
    } elseif ($succ -and $after -eq 'signIn') {
        $v = @('Pending', 'WaitingForSignIn', "The engine reported $label; its evidence appears only after $($user) signs in", "Sign in as $($user) (sign out and in again if already signed in), then verify again.")
        $vf = 'InstallerSucceededVerificationPending'
    } elseif ($succ) {
        $v = @('Warning', 'InstalledVerificationUncertain', "The engine reported $label$(if ($det -eq 'Unconfirmed') { ', but WinGet could not confirm it afterwards' } elseif ($det) { " (WinGet detection: $det)" }); no uninstall record or Store package matched its name$(if ($checked) { ", and none of its evidence was found ($checked)" })", 'Open it once to confirm it is installed (uninstall records do not exist for every installer), then "Deployment recovery" > Reverify applications.')
        $vf = 'InstallerSucceededVerificationFailed'
    } elseif ($eng -eq 'Skipped') { $v = @('Fail', 'BlockedByDependency', "Not installed: a dependency failed. $msg", 'Run "Deployment recovery" > Retry failed operations (it retries the dependency too).') }
    elseif ($outcome -eq 'UnattendedUnsupported') { $v = @('Warning', 'UnattendedUnsupported', "Not installed: it cannot be installed unattended. $msg", "Install $name by hand."); $sev = 'Warning' }
    elseif ($eng -eq 'RequiresInteraction' -or $outcome -eq 'ManualSetupRequired') { $v = @('Warning', 'ManualInstallationRequired', "Needs a person: $msg", "Install or finish $name by hand.") }
    elseif ($eng -eq 'Unavailable' -or $outcome -eq 'PackageUnavailable') { $v = @('Fail', 'PackageUnavailable', "Missing: the package was not available$fc after $attempts attempt(s). $msg", $(if ($recovery -eq 'RetryFailed') { 'Run "Deployment recovery" > Retry failed operations.' } else { 'Correct the cause (see the message), then "Deployment recovery" > Retry one application with -IncludePermanent.' })) }
    elseif ($eng -eq 'Failed' -or $outcome -eq 'InstallationFailed') { $v = @('Fail', 'Failed', "Missing: the installation failed$fc after $attempts attempt(s). $msg", $(if ($recovery -eq 'RetryFailed') { 'Run "Deployment recovery" > Retry failed operations.' } else { 'Correct the cause (see the message), then "Deployment recovery" > Retry one application with -IncludePermanent.' })) }
    elseif (-not $e -and $indep -eq 'Deferred') { $v = @('Deferred', 'WaitingForUserContext', "No engine record, and $($user)'s own applications cannot be checked now: $why", "Sign in as $($user) and open the Health Report again.") }
    else { $v = @('Fail', 'Missing', "Not installed$(if (-not $e) { '; the application stage has no record of it (inconsistent results)' } else { " (engine: $label)" })", 'Run "Deployment recovery" > Resume.') ; if (-not $recovery) { $recovery = 'Resume' } }
    @{ Status = $v[0]; Result = $v[1]; Observed = $v[2]; Next = $v[3]; Severity = $sev; Recovery = $recovery; Verification = (Get-WdhAppVerification $v[1] ([bool] $hit.found) $vf) }
}

<#
    The verification status reported for an application (contract.ts APP_VERIFICATION_STATES):
      InstalledAndVerified                   evidence found now (uninstall record, Store package, file, registry, shortcut)
      InstallerSucceededVerificationPending  the installer succeeded; its evidence can only appear later (sign-in,
                                             restart) or lies in the deployment user's profile, unreadable now
      InstallerSucceededVerificationFailed   the installer succeeded; the evidence was checked and none was found
      Missing / Failed / PackageUnavailable  not found; it failed, was not offered, or there is no result at all
      UnattendedUnsupported                  it cannot be installed without a person
      ManualActionRequired                   no unattended installation, or the installer needs a person
      NotSelected                            deselected for this deployment (listed, never counted as missing)
      Pending / Deferred                     still running / no record and the user's profile is not available
    (InstallerSucceededUnverified is health engine 1.1.0's name for both InstallerSucceeded* states.)
#>
function Get-WdhAppVerification {
    param([string] $Result, [bool] $Found, [string] $Override = '')
    if ($Override) { return $Override }
    switch ($Result) {
        { $_ -in 'InstalledVerified', 'AlreadyInstalledVerified', 'InstalledManually', 'InstalledVersionDiffers' } { return 'InstalledAndVerified' }
        'InstalledVerificationUncertain' { if ($Found) { return 'InstalledAndVerified' } return 'InstallerSucceededVerificationFailed' }
        'Failed' { return 'Failed' }
        'PackageUnavailable' { return 'PackageUnavailable' }
        'UnattendedUnsupported' { return 'UnattendedUnsupported' }
        { $_ -in 'Missing', 'BlockedByDependency' } { return 'Missing' }
        'ManualInstallationRequired' { return 'ManualActionRequired' }
        'SkippedByUser' { return 'NotSelected' }
        'WaitingForUserContext' { return 'Deferred' }
        'WaitingForSignIn' { return 'InstallerSucceededVerificationPending' }
        default { return 'Pending' }
    }
}

<# The engine's own evidence list (engine 1.6.0 verificationEvidence), as history; unknown kinds are left out. #>
function ConvertTo-WdhEngineEvidence {
    param($Engine)
    if ($Engine -isnot [System.Collections.IDictionary]) { return @() }
    @(@(ConvertTo-WdhList (Get-WdhKey $Engine 'verificationEvidence')) | Where-Object { $_ -is [System.Collections.IDictionary] -and [string] $_['kind'] -in 'winget', 'uninstall', 'appx', 'file', 'registry' } | Select-Object -First 10 | ForEach-Object {
        [ordered]@{ kind = [string] $_['kind']; detail = [string] (Get-WdhKey $_ 'detail' ''); where = [string] (Get-WdhKey $_ 'where' ''); version = [string] (Get-WdhKey $_ 'version' '') }
    })
}

function Format-WdhEvidence { param([object[]] $Evidence) (@(@($Evidence) | Where-Object { $_ } | ForEach-Object { "$($_.kind) $($_.detail) ($($_.where))$(if ($_.version) { " $($_.version)" })" }) -join '; ') }

function Test-WdhApplications {
    param($C)
    $cfgApps = $C.Config['applications']
    $items = @(ConvertTo-WdhList $cfgApps['items'])
    if (-not $cfgApps['enabled'] -or -not $items.Count) {
        Add-WdhFinding $C 'apps.plan' 'applications' 'Applications' 'NotApplicable' 'Informational' 'No application is part of this deployment' 'Nothing to verify' 'health-config.json' 'health-config.json' -Required $false | Out-Null
        return
    }
    $res = Read-WdhSource $C 'applications' 'Applications\result.json'
    $stRead = Read-WdhSource $C 'applicationState' 'Applications\state.json'
    if ($stRead.Source.state -ne 'ok') {
        $bak = Join-Path $C.Paths.Root 'Applications\state.json.bak'
        if (Test-Path -LiteralPath $bak) { $b = Read-WddJson $bak; if ($b) { $stRead = @{ Data = $b; Source = $stRead.Source }; $C.Limitations.Add('Applications\state.json was unusable; its last good copy was read.') } }
    }
    $snap = @($C.Snapshot.stages | Where-Object { $_.id -eq 'applications' }) | Select-Object -First 1
    $stageFinal = $snap -and $snap.state -eq 'Final'
    if ($res.Source.state -eq 'corrupt' -and -not $stRead.Data) { Add-WdhFinding $C 'apps.result' 'applications' 'Application results' 'Unverifiable' 'Error' 'The application stage''s results' 'Damaged, and no usable state' 'Applications\result.json, state.json' 'Applications' 'Run "Deployment recovery" > Resume; each application is checked again before anything is installed.' -RecoveryAction 'Resume' | Out-Null }
    if ($stageFinal -and $res.Data -and $res.Data['finishedUtc'] -and $stRead.Data -and $stRead.Data['updatedUtc']) {
        $rd = ConvertTo-WddDate $res.Data['finishedUtc']; $sd = ConvertTo-WddDate $stRead.Data['updatedUtc']
        if ($rd -and $sd -and $sd -gt $rd.AddMinutes(1)) { $res.Source.state = 'stale'; $C.Limitations.Add('Applications\result.json is older than the engine''s state (the stage was reopened); the live state was used.') }
    }
    $byKey = @{}
    $useState = $res.Source.state -ne 'ok'
    if (-not $useState -and $res.Data) {
        foreach ($p in @(ConvertTo-WdhList $res.Data['packages'])) { $byKey[([string] $p['key']).ToLowerInvariant()] = $p }
        foreach ($p in @(ConvertTo-WdhList $res.Data['additionalSoftware'])) { $byKey["additional:$(([string] $p['id']).ToLowerInvariant())"] = $p }
    }
    if ($stRead.Data -is [hashtable]) {
        $sp = $stRead.Data['packages']; $sa = $stRead.Data['additional']
        if ($sp -is [hashtable]) { foreach ($k in $sp.Keys) { if ($useState -or -not $byKey.ContainsKey($k.ToLowerInvariant())) { $byKey[$k.ToLowerInvariant()] = $sp[$k] } } }
        if ($sa -is [hashtable]) { foreach ($k in $sa.Keys) { $kk = "additional:$($k.ToLowerInvariant())"; if ($useState -or -not $byKey.ContainsKey($kk)) { $byKey[$kk] = $sa[$k] } } }
    }
    $sid = $C.DeploymentSid
    $entries = @(ConvertTo-WdhList (Invoke-WdhProbe $C 'uninstall' { Get-WdhUninstallEntries $(if ($C.HiveLoaded) { $sid } else { '' }) }))
    $appx = Invoke-WdhProbe $C 'appx' { Get-WdhAppxPackages $(if ($sid) { $sid } else { '' }) }
    # An empty list is a result; only a failed read (reported in the limitations) leaves Store packages unknown.
    $C.AppxReadable = @($C.Limitations | Where-Object { $_ -like 'Could not read appx*' }).Count -eq 0
    $shortcuts = @(ConvertTo-WdhList (Invoke-WdhProbe $C 'shortcuts' { Get-WdhPortableShortcuts }))
    $runtimes = @(Get-WdhRuntimeInventory $C $entries)
    $restart = Test-WdhRestartPendingNow $C
    foreach ($it in $items) {
        $key = ([string] $it['key']).ToLowerInvariant()
        $fid = "app.$key"
        $e = $(if ($byKey.ContainsKey($key)) { $byKey[$key] } else { $null })
        $eng = $(if ($e) { [string] $e['status'] } else { '' })
        $det = $(if ($e -and $e.ContainsKey('detection')) { [string] $e['detection'] } else { '' })
        $life = $(if ($e -and $e.ContainsKey('lifecycle')) { [string] $e['lifecycle'] } elseif ($e -and (Get-Command Get-WdaLifecycle -ErrorAction SilentlyContinue)) { [string] (Get-WdaLifecycle $e) } else { '' })
        $attempts = $(if ($e -and $e.ContainsKey('totalAttempts')) { [int] $e['totalAttempts'] } elseif ($e) { [int] $e['attempts'] } else { 0 })
        $msg = $(if ($e) { [string] $e['message'] } else { '' })
        # Application engine 1.6.0 fields (absent from older results).
        $outcome = [string] (Get-WdhKey $e 'outcome' '')
        $engVer = [string] (Get-WdhKey $e 'verification' '')
        $engNote = [string] (Get-WdhKey $e 'verificationNote' '')
        $engEvidence = @(ConvertTo-WdhEngineEvidence $e)
        $spec = Get-WdhVerifySpec $it
        $hit = Find-WdhAppEvidence $C $it $spec $entries @(ConvertTo-WdhList $appx) $shortcuts $runtimes
        $scope = [string] $it['scope']
        $indep = $(if ($hit.found) { 'Found' } elseif ($hit.userPending) { 'Deferred' } else { 'NotFound' })
        $required = [bool] $it['required']
        $sev = $(if ($required) { 'Error' } else { 'Warning' })
        $name = [string] $it['name']
        $where = $(if ($hit.found) { "$($hit.how)$(if ($hit.version) { ", version $($hit.version)" }) ($($hit.scope))" } else { '' })
        $checked = @($hit.checked) -join ', '
        $method = "Evidence now: $(if ($checked) { "$checked, " })uninstall records (machine, 32-bit and the deployment user's), Store packages, portable shortcut by name; the engine's result as history"
        $evidence = $(if ($e) { "engine: $(if ($eng) { $eng } else { '-' })$(if ($outcome) { ", outcome $outcome" })$(if ($engVer) { ", its verification $engVer" })$(if ($det) { ", detection $det" })$(if ($attempts) { ", $attempts attempt(s)" })" } else { 'no engine record' })
        if ($hit.found) { $evidence += "; found now: $(Format-WdhEvidence $hit.evidence)" }
        if (@($hit.mismatch).Count) { $evidence += "; not matching: $(@($hit.mismatch) -join '; ')" }
        $recovery = $(if ($e -and $e.ContainsKey('retryable') -and [bool] $e['retryable']) { 'RetryFailed' } elseif ($eng -in 'Failed', 'Unavailable' -or $outcome -in 'InstallationFailed', 'PackageUnavailable') { 'Retry -IncludePermanent' } else { '' })
        $verdict = Resolve-WdhAppVerdict $it $e $hit @{ eng = $eng; det = $det; msg = $msg; attempts = $attempts; stageFinal = $stageFinal; snap = $snap; indep = $indep; where = $where; name = $name; recovery = $recovery; sev = $sev; user = $C.DeploymentUser
                                                       outcome = $outcome; after = $spec.after; restart = $restart; why = $hit.userWhy; checked = $checked }
        $v = @($verdict.Status, $verdict.Result, $verdict.Observed, $verdict.Next)
        $sev = $verdict.Severity; $recovery = $verdict.Recovery
        $status = $v[0]
        if ($status -eq 'Fail' -and -not $required) { $sev = 'Warning' }
        Add-WdhFinding $C $fid 'applications' $name $status $sev $(if ([string] $it['kind'] -eq 'manual') { 'Installed (manual follow-up)' } elseif ($it['version']) { "Installed, version $($it['version'])" } else { 'Installed' }) $v[2] $method $evidence $v[3] -Required ($required -and [string] $it['kind'] -ne 'manual') -AutomaticRecovery ($status -eq 'Pending') -TechnicianRequired ($status -in 'Fail', 'Warning', 'Deferred') -RecoveryAction $(if ($status -eq 'Fail') { $recovery } else { '' }) | Out-Null
        $note = $(if ($hit.found) { "Evidence found now: $(Format-WdhEvidence $hit.evidence)" }
                  elseif ($hit.userPending) { "No evidence yet; it cannot be read now: $($hit.userWhy)" }
                  elseif ($checked) { "No evidence found ($checked; names)" }
                  else { 'No evidence found (uninstall records, Store packages and the portable shortcut by name)' })
        if ($engNote) { $note += " Engine: $engNote" }
        # Deselected for this deployment: listed as NotSelected (as before 1.1.0), never counted as missing.
        $C.Apps.Add([ordered]@{ key = $key; name = $name; source = [string] $it['source']; packageIdentifier = [string] $it['packageIdentifier']; method = [string] $it['method']; kind = [string] $it['kind']; required = $required
                                scope = $scope; engineStatus = $eng; lifecycle = $life; attempts = $attempts; detection = $det; independent = $indep; foundIn = $(if ($hit.found) { [string] $hit.scope } else { '' }); version = [string] $hit.version; result = $v[1]
                                verification = $verdict.Verification; findingId = $fid
                                evidence = @($hit.evidence); engineEvidence = @($engEvidence); outcome = $outcome; engineVerification = $engVer; failureClass = [string] (Get-WdhKey $e 'failureClass' ''); verificationNote = $note })
        if ($v[1] -in 'ManualInstallationRequired', 'UnattendedUnsupported') { $C.Manual.Add([ordered]@{ id = $fid; text = "$name`: $($v[3])"; url = [string] $it['url'] }) }
    }
    if ($res.Data -and $res.Data['bootstrap'] -is [hashtable] -and [string] $res.Data['bootstrap']['status'] -in 'Failed', 'Unsupported', 'NeedsRepair') {
        Add-WdhFinding $C 'apps.winget' 'applications' 'WinGet' 'Fail' 'Error' 'WinGet usable' "$($res.Data['bootstrap']['status']): $($res.Data['bootstrap']['message'])" 'Applications\result.json bootstrap' 'Applications\result.json' 'Update App Installer from the Microsoft Store, then "Deployment recovery" > Retry failed operations.' -RecoveryAction 'RetryFailed' | Out-Null
    }
}

<#
    Visual C++ runtimes (read-only; its own finding, apps.runtimes): every family and architecture in
    the uninstall records, with versions. Information, unless a runtime this deployment selected is
    absent (Warning; the application's own finding says what its installation did). On 64-bit
    Windows the x86 runtime is what 32-bit applications load: it is never redundant beside x64, and
    x64 does not replace it (nor the other way round).
#>
function Test-WdhRuntimes {
    param($C)
    $cfgApps = $C.Config['applications']
    $items = @(ConvertTo-WdhList $cfgApps['items'])
    $entries = @(ConvertTo-WdhList (Invoke-WdhProbe $C 'uninstall' { Get-WdhUninstallEntries $(if ($C.HiveLoaded) { $C.DeploymentSid } else { '' }) }))
    $readable = @($C.Limitations | Where-Object { $_ -like 'Could not read uninstall*' }).Count -eq 0
    $runtimes = @(Get-WdhRuntimeInventory $C $entries)
    $os = $C.Obs['os']
    $osArch = $(if ($os) { [string] $os.architecture } else { '' })
    $is64 = $osArch -match '64'
    $selected = @()
    foreach ($it in $items) {
        $m = [regex]::Match([string] $it['packageIdentifier'], $script:WdhVcRedistId, 'IgnoreCase')
        if (-not $m.Success) { continue }
        $fam = $m.Groups[1].Value; $arch = $m.Groups[2].Value.ToLowerInvariant()
        $have = @($runtimes | Where-Object { $_.family -eq $fam -and $_.architecture -eq $arch }) | Select-Object -First 1
        $selected += , [ordered]@{ key = ([string] $it['key']).ToLowerInvariant(); name = [string] $it['name']; family = $fam; architecture = $arch; present = [bool] $have; version = $(if ($have) { [string] $have.version } else { '' }) }
    }
    $notes = @()
    if ($is64) { $notes += 'On 64-bit Windows, 32-bit applications use the x86 runtime and 64-bit applications the x64 one: both are needed, neither replaces the other.' }
    foreach ($f in @($runtimes | ForEach-Object { $_.family } | Select-Object -Unique)) {
        $archs = @($runtimes | Where-Object { $_.family -eq $f } | ForEach-Object { $_.architecture } | Select-Object -Unique)
        if ($is64 -and $archs -contains 'x86' -and $archs -notcontains 'x64') { $notes += "Visual C++ $f is present for x86 only: 32-bit applications can use it; 64-bit applications that need it would not start." }
        if ($is64 -and $archs -contains 'x64' -and $archs -notcontains 'x86') { $notes += "Visual C++ $f is present for x64 only: 32-bit applications that need it would not start." }
    }
    $fid = 'apps.runtimes'
    $C.Runtimes = [ordered]@{ checkedUtc = (Get-WdhTime).ToString('o'); osArchitecture = $osArch; available = $readable; source = 'Uninstall records (64- and 32-bit) and the Visual C++ 2015+ runtime keys, as the application engine''s runtime inventory'
                              items = @($runtimes); selected = @($selected); notes = @($notes); findingId = $(if ($cfgApps['enabled'] -and $items.Count) { $fid } else { '' }) }
    # Without applications in this deployment the inventory stays in the report, without a finding.
    if (-not ($cfgApps['enabled'] -and $items.Count)) { return }
    $list = $(if ($runtimes.Count) { (@($runtimes | Sort-Object { $_.family }, { $_.architecture } | ForEach-Object { "$($_.family) $($_.architecture) $($_.version)" }) -join ', ') } else { 'none' })
    $missing = @($selected | Where-Object { -not $_.present })
    $method = 'Uninstall records and the VC\Runtimes keys, by family (2015+ = the shared v14 runtime, 2013, 2012, 2010, 2008, 2005) and architecture'
    if (-not $readable) { Add-WdhFinding $C $fid 'applications' 'Visual C++ runtimes' 'Info' 'Informational' 'Listed for information' 'The uninstall records could not be read' $method 'Uninstall records' -Required $false -TechnicianRequired $false | Out-Null; return }
    if ($missing.Count) {
        $why = @($missing | ForEach-Object { "$($_.family) $($_.architecture)$(if ($is64 -and $_.architecture -eq 'x86') { ' (needed by 32-bit applications even on 64-bit Windows)' } elseif ($_.architecture -eq 'x64') { ' (needed by 64-bit applications; the x86 runtime does not replace it)' })" })
        Add-WdhFinding $C $fid 'applications' 'Visual C++ runtimes' 'Warning' 'Warning' "The selected runtimes: $(@($selected | ForEach-Object { "$($_.family) $($_.architecture)" }) -join ', ')" "Missing: $($why -join ', '). Present: $list" $method 'Uninstall records' 'Install the missing runtime ("Deployment recovery" > Retry failed operations, or its WinGet package Microsoft.VCRedist.<family>.<architecture>).' -Required $false | Out-Null
    } else {
        Add-WdhFinding $C $fid 'applications' 'Visual C++ runtimes' 'Info' 'Informational' $(if ($selected.Count) { "The selected runtimes: $(@($selected | ForEach-Object { "$($_.family) $($_.architecture)" }) -join ', ')" } else { 'Listed for information' }) "Present: $list.$(if ($notes.Count) { ' ' + ($notes -join ' ') })" $method 'Uninstall records' -Required $false -TechnicianRequired $false | Out-Null
    }
}

<#
    WinGet's table (winget upgrade): the Application Manager's parser when it is loaded (it handles
    wide characters, other display languages and every WinGet table), else a compact reading of the
    same table by its English column titles. Each row: name, id, version, available, source.
#>
function ConvertFrom-WdhWinGetTable {
    param([string] $Text)
    if (Get-Command ConvertFrom-WamTable -ErrorAction SilentlyContinue) { return @(ConvertFrom-WamTable $Text) }
    $lines = @(($Text -replace "`r`n", "`n") -split "`n" | ForEach-Object { ($_.TrimEnd("`r") -split "`r")[-1].TrimEnd() })
    $rows = @()
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^-{10,}\s*$') { continue }
        $head = $lines[$i - 1]
        $starts = @(); $titles = @()
        foreach ($m in [regex]::Matches($head, '\S+')) { $starts += $m.Index; $titles += $m.Value.ToLowerInvariant() }
        if ($starts.Count -lt 3 -or $starts[0] -ne 0) { continue }
        $roles = @($titles | ForEach-Object { if ($_ -in 'name', 'id', 'version', 'available', 'source') { $_ } else { '' } })
        if (@($roles | Where-Object { -not $_ }).Count) { $roles = @('name', 'id', 'version', 'available', 'source') | Select-Object -First $starts.Count }
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            $l = $lines[$j]
            if (-not $l.Trim() -or $l.Length -le $starts[1]) { break }
            $r = @{ name = ''; id = ''; version = ''; available = ''; source = '' }
            for ($k = 0; $k -lt $starts.Count; $k++) {
                if ($starts[$k] -ge $l.Length) { continue }
                $end = $(if ($k + 1 -lt $starts.Count) { [Math]::Min($starts[$k + 1], $l.Length) } else { $l.Length })
                if ($roles[$k]) { $r[$roles[$k]] = $l.Substring($starts[$k], $end - $starts[$k]).Trim() }
            }
            if (-not $r.id -or $r.id -match '\s' -or -not $r.version) { break }
            $rows += , $r
        }
    }
    return $rows
}

<#
    -CheckAppUpdates (read-only): which selected applications WinGet can update. WinGet lists the
    packages of the account that runs it; as SYSTEM it cannot run for the deployment user, so that
    is said instead of a result. Information only: an available update is not a deployment defect,
    and nothing is ever installed here (updates are a separate action of the Application Manager).
#>
function Test-WdhAppUpdates {
    param($C)
    if (-not $C.CheckAppUpdates) { return }
    $items = @(ConvertTo-WdhList $C.Config['applications']['items'])
    $fid = 'apps.updates'
    $runAs = $(if ($C.Identity.IsSystem) { 'SYSTEM' } else { [string] $C.Identity.Name })
    $view = [ordered]@{ checkedUtc = (Get-WdhTime).ToString('o'); status = 'ok'; runAs = $runAs; asDeploymentUser = $C.SameUser; exitCode = ''; items = @(); otherAvailable = 0; problems = @(); note = ''; findingId = $fid }
    $method = 'winget upgrade --source winget (read-only listing; nothing is installed)'
    if ($C.Identity.IsSystem) {
        $view.status = 'notAsSystem'
        $view.note = "WinGet lists updates per user and cannot run for $($C.DeploymentUser) as SYSTEM. Run DeploymentHealth.ps1 -CheckAppUpdates as $($C.DeploymentUser), or use the Application Manager."
        $C.AppUpdates = $view
        Add-WdhFinding $C $fid 'applications' 'Application updates' 'Info' 'Informational' 'Listed for information' "Not checked: this audit runs as SYSTEM. $($view.note)" $method 'WinGet' -Required $false -TechnicianRequired $false | Out-Null
        return
    }
    $r = Invoke-WdhProbe $C 'wingetUpgrade' { Get-WdhWinGetUpgrades }
    if (-not $r -or -not $r.available) {
        $view.status = 'wingetUnavailable'; $view.note = 'WinGet (App Installer) was not found for this account.'
        $C.AppUpdates = $view
        Add-WdhFinding $C $fid 'applications' 'Application updates' 'Info' 'Informational' 'Listed for information' "Not checked: $($view.note)" $method 'WinGet' -Required $false -TechnicianRequired $false | Out-Null
        return
    }
    $view.exitCode = $(if ($null -ne $r.exitCode) { '0x{0:X8}' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32] $r.exitCode), 0) } else { '' })
    $rows = @(ConvertFrom-WdhWinGetTable ([string] $r.text))
    if (-not $rows.Count -and $r.exitCode -ne 0 -and [string] $r.text -notmatch '(?i)no (installed package|applicable upgrade|available upgrade)') {
        $view.status = 'failed'; $view.note = "WinGet could not list updates (exit code $($view.exitCode))."
        $view.problems = @(@(([string] $r.text) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^[-\\|/ ]+$' } | Select-Object -Last 2) | ForEach-Object { ConvertTo-WdhSafeText $_ })
        $C.AppUpdates = $view
        Add-WdhFinding $C $fid 'applications' 'Application updates' 'Info' 'Informational' 'Listed for information' $view.note $method 'WinGet' 'Run the check again when online; the Application Manager shows the same list.' -Required $false -TechnicianRequired $false | Out-Null
        return
    }
    $byId = @{}
    foreach ($row in $rows) { if ($row.id) { $byId[([string] $row.id).ToLowerInvariant()] = $row } }
    $found = @()
    foreach ($it in $items) {
        $id = ([string] $it['packageIdentifier']).ToLowerInvariant()
        if (-not $id -or -not $byId.ContainsKey($id)) { continue }
        $row = $byId[$id]
        $found += , [ordered]@{ key = ([string] $it['key']).ToLowerInvariant(); name = [string] $it['name']; id = [string] $row.id; installed = [string] $row.version; available = [string] $row.available; source = $(if ($row.source) { [string] $row.source } else { 'winget' }) }
    }
    $view.items = @($found)
    $view.otherAvailable = [Math]::Max(0, $rows.Count - $found.Count)
    if ($C.SameUser -eq $false) { $view.note = "Listed for $runAs, not for the deployment user $($C.DeploymentUser): that user's own per-user applications are not included." }
    $C.AppUpdates = $view
    $obs = $(if ($found.Count) { "$($found.Count) selected application(s) can be updated: $((@($found | ForEach-Object { "$($_.name) $($_.installed) -> $($_.available)" })) -join ', ')" } else { 'No update is listed for the selected applications' })
    if ($view.otherAvailable) { $obs += "; $($view.otherAvailable) other package(s) on this computer also have updates" }
    Add-WdhFinding $C $fid 'applications' 'Application updates' 'Info' 'Informational' 'Listed for information' "$obs.$(if ($view.note) { ' ' + $view.note })" $method 'WinGet' $(if ($found.Count) { 'Update them with the Application Manager (Updates), or leave them to the applications'' own updaters.' } else { '' }) -Required $false -TechnicianRequired $false | Out-Null
}

# ------------------------------------------------------------------------------------------------
# Microsoft Office (when this deployment selected it) and its activation as the activation stage recorded it
# ------------------------------------------------------------------------------------------------

function Test-WdhOffice {
    param($C)
    # health-config.json of packages before engine 1.1.0 has no "office": nothing to check then.
    $o = Get-WdhKey $C.Config 'office'
    $product = [string] (Get-WdhKey $o 'product' '')
    if (-not $product -or $product -eq 'none') { return }
    $want = [string] (Get-WdhKey $o 'productReleaseId' '')
    $label = $(if (Get-WdhKey $o 'displayName') { [string] $o['displayName'] } else { $product })
    $res = Read-WdhSource $C 'office' 'Office\result.json'
    $snap = @($C.Snapshot.stages | Where-Object { $_.id -eq 'office' }) | Select-Object -First 1
    $engine = [string] (Get-WdhKey $res.Data 'status' '')
    $final = ($snap -and $snap.state -eq 'Final') -or (-not $snap -and $engine -in 'Succeeded', 'CompletedWithFollowUp', 'Failed', 'Offline')
    $c2r = Invoke-WdhProbe $C 'officeClickToRun' { Get-WdhOfficeClickToRun }
    $ids = $(if ($c2r) { @(ConvertTo-WdhList $c2r.productReleaseIds) } else { @() })
    $view = [ordered]@{ selected = $true; product = $product; displayName = $label; expectedProductReleaseId = $want; present = $(if ($c2r) { [bool] $c2r.present } else { $null }); productReleaseIds = @($ids)
                        version = $(if ($c2r) { [string] $c2r.version } else { '' }); platform = $(if ($c2r) { [string] $c2r.platform } else { '' }); engineStatus = $engine; engineVerified = [bool] (Get-WdhKey $res.Data 'verified' $false)
                        result = ''; activation = $null; checkedUtc = (Get-WdhTime).ToString('o') }
    $method = 'HKLM\SOFTWARE\Microsoft\Office\ClickToRun\Configuration (ProductReleaseIds, VersionToReport, Platform); the Office stage''s result as evidence'
    $evidence = "Office stage: $(if ($engine) { $engine } else { 'no result' })"
    $exp = "$label installed$(if ($want) { " ($want)" })"
    if ($null -eq $c2r) { $view.result = 'Unverifiable'; Add-WdhFinding $C 'office.install' 'applications' $label 'Unverifiable' 'Error' $exp 'The Office Click-to-Run configuration could not be read' $method $evidence 'Run the check again as administrator, or open an Office application and check File > Account.' | Out-Null }
    elseif ($c2r.present -and (-not $want -or $ids -contains $want)) { $view.result = 'InstalledAndVerified'; Add-WdhFinding $C 'office.install' 'applications' $label 'Pass' 'Error' $exp "Installed: $($ids -join ', '), version $($c2r.version)$(if ($c2r.platform) { ", $($c2r.platform)" })" $method $evidence | Out-Null }
    elseif ($c2r.present) { $view.result = 'DifferentProduct'; Add-WdhFinding $C 'office.install' 'applications' $label 'Warning' 'Error' $exp "Office Click-to-Run is installed as $($ids -join ', '), not as $want (version $($c2r.version))" $method $evidence 'Check whether a different Office was installed on purpose; this check changes nothing.' | Out-Null }
    elseif (-not $final) { $view.result = 'Pending'; Add-WdhFinding $C 'office.install' 'applications' $label 'Pending' 'Error' $exp "Not installed yet (the Office stage is $(if ($snap) { $snap.state } else { 'not started' }))" $method $evidence 'Wait; the Office stage continues by itself.' -AutomaticRecovery $true -TechnicianRequired $false | Out-Null }
    elseif ($engine -in 'Succeeded', 'CompletedWithFollowUp') { $view.result = 'InstallerSucceededUnverified'; Add-WdhFinding $C 'office.install' 'applications' $label 'Fail' 'Error' $exp "The Office stage reported $engine, but Windows has no Office Click-to-Run configuration" $method $evidence 'Open Settings > Apps to look for Office; install it again with "Deployment recovery" if it is missing.' -RecoveryAction 'RetryFailed' | Out-Null }
    else { $view.result = 'Missing'; Add-WdhFinding $C 'office.install' 'applications' $label 'Fail' 'Error' $exp "Not installed (Office stage: $(if ($engine) { "$engine. $(Get-WdhKey $res.Data 'detail' (Get-WdhKey $res.Data 'reason' ''))" } else { 'no result' }))" $method $evidence 'See Office\logs, fix the cause, then "Deployment recovery" > Retry failed operations.' -RecoveryAction 'RetryFailed' | Out-Null }
    # Activation: only what the activation stage recorded (deployment state, else Activation\result.json). Never a key or a KMS host.
    $plan = [string] (Get-WdhKey (Get-WdhKey $C.Config 'activation') 'office' '')
    $st = $C.StateRead.State
    $entry = Get-WdhKey (Get-WdhKey $st 'activation') 'office'
    $source = 'state\deployment.json activation'
    if ($entry -isnot [System.Collections.IDictionary]) { $entry = Get-WdhKey (Read-WddJson (Join-Path $C.Paths.Root 'Activation\result.json')) 'office'; $source = 'Activation\result.json' }
    $a = [ordered]@{ requested = $(if ($plan) { $plan } else { 'unknown' }); status = ''; verified = $false; message = ''; source = '' }
    $aMethod = 'Status recorded by the activation stage (the licence is not read again here; keys and KMS hosts are never shown)'
    if ($entry -is [System.Collections.IDictionary]) {
        $a.status = [string] (Get-WdhKey $entry 'status' ''); $a.verified = [bool] (Get-WdhKey $entry 'verified' $false); $a.message = ConvertTo-WdhSafeText ([string] (Get-WdhKey $entry 'message' '')); $a.source = $source
        $obs = "$($a.status)$(if ($a.verified) { ' (verified by the activation stage)' }). $($a.message)"
        if ($a.status -eq 'Activated' -and $a.verified) { Add-WdhFinding $C 'office.activation' 'applications' 'Office activation' 'Pass' 'Warning' 'Activated' $obs $aMethod $source -Required $false | Out-Null }
        elseif ($a.status -in 'AwaitingTechnician', 'Deferred', 'Failed', 'Blocked', 'Unavailable', 'Activated') { Add-WdhFinding $C 'office.activation' 'applications' 'Office activation' 'Warning' 'Warning' 'Activated' $obs $aMethod $source 'Activate Office with the technician''s licence: "Deployment recovery" > Activation (DeploymentRecovery.ps1 -Action Activate -Target Office). Office is installed and works for a grace period meanwhile.' -Required $false | Out-Null }
        else { Add-WdhFinding $C 'office.activation' 'applications' 'Office activation' 'Info' 'Informational' 'As requested' $obs $aMethod $source -Required $false | Out-Null }
    } elseif ($plan -eq 'none') {
        $a.status = 'NotRequested'
        Add-WdhFinding $C 'office.activation' 'applications' 'Office activation' 'Info' 'Informational' 'Not part of this deployment' 'No Office activation was requested by this deployment' 'health-config.json activation.office' 'health-config.json' -Required $false | Out-Null
    } elseif ($C.Snapshot.allFinal -or -not $plan) {
        $a.status = 'NotRecorded'
        Add-WdhFinding $C 'office.activation' 'applications' 'Office activation' 'Unverifiable' 'Warning' 'Activated' 'The activation stage left no record for Office' $aMethod 'state\deployment.json, Activation\result.json' 'Check with "Deployment recovery" > Activation (CheckActivation only reads the licensing state).' -Required $false | Out-Null
    } else {
        $a.status = 'Waiting'
        Add-WdhFinding $C 'office.activation' 'applications' 'Office activation' 'Pending' 'Warning' 'Activated' 'Not done yet: activation runs at the end of the deployment' $aMethod 'state\deployment.json' 'Wait for the deployment to finish.' -Required $false -AutomaticRecovery $true -TechnicianRequired $false | Out-Null
    }
    $view.activation = $a
    $C.Office = $view
}

# ------------------------------------------------------------------------------------------------
# Restored settings (Phase 6) and retained backups
# ------------------------------------------------------------------------------------------------

function Test-WdhRestoration {
    param($C)
    $plan = $C.Config['restoration']
    $folders = @(ConvertTo-WdhList (Invoke-WdhProbe $C 'backups' { Get-WdhBackupFolders $C.Paths.Root }))
    $outstanding = $false
    if (-not $plan['required']) {
        Add-WdhFinding $C 'restore.plan' 'restoration' 'Settings restoration' 'NotApplicable' 'Informational' 'Not part of this deployment' 'No settings backup was planned' 'health-config.json' 'health-config.json' -Required $false | Out-Null
    } else {
        $r = Read-WdhSource $C 'restoration' 'Applications\restoration.json' 'windows-deployment-builder/restoration-result'
        $snap = @($C.Snapshot.stages | Where-Object { $_.id -eq 'applications' }) | Select-Object -First 1
        $final = $snap -and $snap.state -eq 'Final'
        if ($r.Source.state -eq 'corrupt') { Add-WdhFinding $C 'restore.result' 'restoration' 'Restoration result' 'Unverifiable' 'Error' 'Readable restoration result' 'restoration.json is damaged or not a restoration result' 'Applications\restoration.json' 'Applications\restoration.json' 'Run "Deployment recovery" > Resume.' -RecoveryAction 'Resume' | Out-Null; $outstanding = $true }
        elseif (-not $r.Data) {
            if ($final) { Add-WdhFinding $C 'restore.result' 'restoration' 'Restoration result' 'Unverifiable' 'Error' 'A restoration result' 'The application stage finished without writing restoration.json' 'Applications\restoration.json' 'Applications\restoration.json' 'Run "Deployment recovery" > Resume.' -RecoveryAction 'Resume' | Out-Null }
            else { Add-WdhFinding $C 'restore.result' 'restoration' 'Restoration result' 'Pending' 'Error' 'Settings restored' 'Not done yet: settings are restored after their applications' 'Applications\restoration.json' 'Applications\restoration.json' 'Wait for the application stage.' -AutomaticRecovery $true -TechnicianRequired $false | Out-Null }
            $outstanding = $true
        } else {
            $d = $r.Data
            if ([string] $d['backupId'] -and [string] $plan['backupId'] -and [string] $d['backupId'] -ne [string] $plan['backupId']) { Add-WdhFinding $C 'restore.backup' 'restoration' 'Settings backup' 'Unverifiable' 'Error' "Backup $($plan['backupId'])" "The result describes backup $($d['backupId'])" 'restoration.json backupId vs the plan' 'Applications\restoration.json' 'Verify with the package that pins this backup.' | Out-Null }
            else {
                $bs = $(if ($d['backup'] -is [hashtable]) { [string] $d['backup']['status'] } else { '' })
                $bm = $(if ($d['backup'] -is [hashtable]) { [string] $d['backup']['message'] } else { '' })
                switch ($bs) {
                    'Staged' { Add-WdhFinding $C 'restore.backup' 'restoration' 'Settings backup' 'Pass' 'Error' "Backup $($plan['backupId']) found and validated" 'Found, every file matched its SHA-256' 'restoration.json backup (validated by the engine against the pinned manifest SHA-256)' 'Applications\restoration.json' | Out-Null }
                    'NotSearched' { Add-WdhFinding $C 'restore.backup' 'restoration' 'Settings backup' $(if ($final) { 'Fail' } else { 'Pending' }) 'Error' "Backup $($plan['backupId']) found and validated" 'Not looked for yet' 'restoration.json backup' 'Applications\restoration.json' 'Wait for the application stage.' | Out-Null; $outstanding = $true }
                    'NotFound' { Add-WdhFinding $C 'restore.backup' 'restoration' 'Settings backup' 'Fail' 'Error' "Backup $($plan['folderName']) found and validated" "Not found. $bm" 'restoration.json backup' 'Applications\restoration.json' "Connect the drive with $($plan['folderName']) and run ""Deployment recovery"" > Restore application settings." -RecoveryAction 'RestoreSettings' | Out-Null; $outstanding = $true }
                    'Invalid' { Add-WdhFinding $C 'restore.backup' 'restoration' 'Settings backup' 'Fail' 'Error' "Backup $($plan['folderName']) found and validated" "Rejected: damaged, modified or not the expected backup. $bm" 'restoration.json backup (SHA-256 validation)' 'Applications\restoration.json' 'Supply the original, unmodified backup ("Deployment recovery" > Restore application settings). A modified backup is never restored.' -RecoveryAction 'RestoreSettings' | Out-Null; $outstanding = $true }
                    default { Add-WdhFinding $C 'restore.backup' 'restoration' 'Settings backup' 'Fail' 'Error' "Backup $($plan['folderName']) found and validated" "$bs. $bm" 'restoration.json backup' 'Applications\restoration.json' 'See the application engine log.' -RecoveryAction 'RestoreSettings' | Out-Null; $outstanding = $true }
                }
            }
            $settings = @{}
            foreach ($s in @(ConvertTo-WdhList $d['settings'])) { $settings[[string] $s['adapterId']] = $s }
            $appByKey = @{}
            foreach ($a in $C.Apps) { $appByKey[$a.key] = $a }
            foreach ($ad in @(ConvertTo-WdhList $plan['adapters'])) {
                $aid = [string] $ad['id']
                $s = $(if ($settings.ContainsKey($aid)) { $settings[$aid] } else { $null })
                $fid = "restore.settings.$aid"
                $title = "$($ad['name']) settings"
                if (-not $s) { Add-WdhFinding $C $fid 'restoration' $title $(if ($final) { 'Unverifiable' } else { 'Pending' }) 'Error' 'Restored' 'No result for this adapter' 'restoration.json settings[]' 'Applications\restoration.json' 'Run "Deployment recovery" > Resume.' -RecoveryAction 'Resume' | Out-Null; $outstanding = $true; continue }
                $o = [string] $s['outcome']
                $detail = "$o. $($s['detail'])"
                $review = @(@(ConvertTo-WdhList $s['items']) | Where-Object { [string] $_['action'] -eq 'review' }).Count
                switch ($o) {
                    'ConfigurationRestored' { Add-WdhFinding $C $fid 'restoration' $title $(if ($review) { 'Warning' } else { 'Pass' }) 'Error' 'Restored' $(if ($review) { "$detail $review item(s) need a manual review (conflict with existing settings)." } else { $detail }) 'restoration.json (the engine compared every restored file with the backup)' 'Applications\restoration.json' $(if ($review) { 'Review the listed items with the customer.' } else { '' }) | Out-Null }
                    'KeptExisting' { Add-WdhFinding $C $fid 'restoration' $title 'Pass' 'Error' 'Restored' "$detail (existing settings were kept by the chosen conflict rule)" 'restoration.json' 'Applications\restoration.json' | Out-Null }
                    'ConfigurationPartiallyRestored' { Add-WdhFinding $C $fid 'restoration' $title 'Warning' 'Warning' 'Restored' $detail 'restoration.json' 'Applications\restoration.json' 'Check the items that were not restored with the customer.' | Out-Null }
                    'ManualActionRequired' { Add-WdhFinding $C $fid 'restoration' $title 'Warning' 'Warning' 'Restored' $detail 'restoration.json' 'Applications\restoration.json' (@(ConvertTo-WdhList $s['followUps']) -join ' ') | Out-Null }
                    'Unsupported' { Add-WdhFinding $C $fid 'restoration' $title 'Warning' 'Warning' 'Restored' $detail 'restoration.json' 'Applications\restoration.json' 'Restore these settings by hand.' -Required $false | Out-Null }
                    'SkippedByUser' { Add-WdhFinding $C $fid 'restoration' $title 'NotApplicable' 'Informational' 'Restored' $detail 'restoration.json' 'Applications\restoration.json' -Required $false | Out-Null }
                    { $_ -in 'Pending', 'WaitingForUser', 'WaitingForBackup', 'BlockedByDependency' } {
                        $wait = $(if ($o -eq 'WaitingForBackup') { 'Connect the backup and run "Deployment recovery" > Restore application settings.' } elseif ($o -eq 'WaitingForUser') { "Sign in as $($C.DeploymentUser); settings are restored in that account." } elseif ($o -eq 'BlockedByDependency') { 'Its application is not installed; fix that first.' } else { 'Wait for the application stage.' })
                        Add-WdhFinding $C $fid 'restoration' $title $(if ($final -and $o -ne 'WaitingForUser') { 'Fail' } else { 'Pending' }) 'Error' 'Restored' $detail 'restoration.json' 'Applications\restoration.json' $wait -RecoveryAction $(if ($o -eq 'WaitingForBackup') { 'RestoreSettings' } else { 'RetryFailed' }) | Out-Null
                        $outstanding = $true
                    }
                    default { Add-WdhFinding $C $fid 'restoration' $title 'Fail' 'Error' 'Restored' $detail 'restoration.json' 'Applications\restoration.json' 'Run "Deployment recovery" > Retry failed operations, or restore the settings by hand.' -RecoveryAction 'RetryFailed' | Out-Null; $outstanding = $true }
                }
                # Installed is not migrated: an application can be present while its settings failed.
                if ($o -in 'ConfigurationRestored', 'KeptExisting', 'ConfigurationPartiallyRestored') {
                    $app = @($C.Apps | Where-Object { $_.name -like "*$($ad['name'])*" -or $ad['name'] -like "*$($_.name)*" }) | Select-Object -First 1
                    if ($app -and $app.independent -eq 'NotFound' -and $app.result -in 'Failed', 'Missing', 'BlockedByDependency') { Add-WdhFinding $C "restore.consistency.$aid" 'restoration' "$($ad['name']) settings without the application" 'Unverifiable' 'Error' 'Settings restored for an installed application' "The settings are reported restored, but $($app.name) is not installed" 'restoration.json vs the application check' 'Applications\restoration.json' 'Install the application, then verify again.' | Out-Null }
                }
            }
        }
    }
    $bytes = 0; foreach ($f in $folders) { $bytes += [double] $f.bytes }
    $C.Backups = [ordered]@{ retained = $folders.Count; bytes = $bytes; location = $(if ($folders.Count) { 'C:\ProgramData\WindowsDeploymentBuilder\Backup' } else { '' }); requiredForOutstanding = $outstanding
                             cleanup = $(if ($folders.Count -and -not $outstanding -and $plan['backupId']) { "powershell.exe -ExecutionPolicy Bypass -File `"$(Join-Path $C.Paths.Package 'scripts\health\DeploymentHealth.ps1')`" -Mode CleanupBackups -ConfirmCleanup $($plan['backupId'])" } else { '' }) }
    if ($folders.Count) {
        if ($outstanding) { Add-WdhFinding $C 'restore.retained' 'restoration' 'Retained settings backup' 'Info' 'Informational' 'Kept until restoration is complete' "$($folders.Count) staged backup folder(s), $(Format-WdhBytes $bytes); still needed" 'Backup folder below the data root' 'Backup' -Required $false | Out-Null }
        else { Add-WdhFinding $C 'restore.retained' 'restoration' 'Retained settings backup' 'Warning' 'Warning' 'Removed after delivery, or kept on purpose' "$($folders.Count) staged backup folder(s) with personal application settings remain ($(Format-WdhBytes $bytes)) under C:\ProgramData\WindowsDeploymentBuilder\Backup" 'Backup folder below the data root' 'Backup' 'Remove it after confirming the settings with the customer: DeploymentHealth.ps1 -Mode CleanupBackups (asks for the backup id; the USB copy is never touched).' -Required $false | Out-Null }
    }
}

# ------------------------------------------------------------------------------------------------
# Hardware and drivers (Phase 8 report compared with the devices as they are now)
# ------------------------------------------------------------------------------------------------

<#
    Devices the deployment reported with a problem at its end (the update engine's final check, kept in
    Updates\result.json verification.devicesWithProblems and in the deployment report's windowsUpdate
    section): name, problem code, hardware IDs and device instance id.
#>
function Get-WdhPreviousProblemDevices {
    param($C)
    $u = $(if ($C.UpdateResult) { $C.UpdateResult } else { Read-WddJson (Join-Path $C.Paths.Root 'Updates\result.json') })
    $repPath = $(if ($C.Paths.ContainsKey('ReportJson') -and $C.Paths.ReportJson) { $C.Paths.ReportJson } else { Join-Path $C.Paths.Root 'reports\deployment-report.json' })
    $rep = Read-WddJson $repPath
    $lists = @(, @('Updates\result.json', (Get-WdhKey (Get-WdhKey $u 'verification') 'devicesWithProblems')))
    $lists += , @('reports\deployment-report.json', (Get-WdhKey (Get-WdhKey (Get-WdhKey $rep 'windowsUpdate') 'verification') 'devicesWithProblems'))
    $seen = @{}; $out = @()
    foreach ($l in $lists) {
        foreach ($d in @(ConvertTo-WdhList $l[1])) {
            if ($d -isnot [System.Collections.IDictionary]) { continue }
            $hw = @(@(@(ConvertTo-WdhList (Get-WdhKey $d 'hardwareIds')) + @(ConvertTo-WdhList (Get-WdhKey $d 'hardwareId'))) | Where-Object { $_ } | ForEach-Object { ([string] $_).ToUpperInvariant() })
            $devId = ([string] (Get-WdhKey $d 'deviceId' (Get-WdhKey $d 'instanceId' ''))).ToUpperInvariant()
            $name = [string] (Get-WdhKey $d 'name' '')
            $key = $(if ($devId) { $devId } elseif ($hw.Count) { $hw[0] } else { "NAME:$($name.ToUpperInvariant())" })
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $out += , @{ key = $key; name = $name; problemCode = [int] (Get-WdhKey $d 'problemCode' 0); hardwareIds = $hw; deviceId = $devId; source = [string] $l[0] }
        }
    }
    return $out
}

<# The previously reported device that is this present device (device id, else a hardware ID, else the name when no id was recorded). #>
function Find-WdhPreviousDevice {
    param($Device, [object[]] $Previous)
    $did = $(if ($Device -is [System.Collections.IDictionary] -and $Device.Contains('deviceId')) { ([string] $Device['deviceId']).ToUpperInvariant() } else { '' })
    $hw = ([string] $Device['hardwareId']).ToUpperInvariant()
    foreach ($p in @($Previous | Where-Object { $_ })) { if ($did -and $p.deviceId -and $did -eq $p.deviceId) { return $p } }
    foreach ($p in @($Previous | Where-Object { $_ })) { if ($hw -and @($p.hardwareIds) -contains $hw) { return $p } }
    foreach ($p in @($Previous | Where-Object { $_ })) { if (-not $p.deviceId -and -not @($p.hardwareIds).Count -and $p.name -and $p.name -ieq [string] $Device['name']) { return $p } }
    return $null
}

function Get-WdhDeviceSeverity { param([string] $Class) if ($Class -in 'Display', 'Net', 'SCSIAdapter', 'HDC', 'DiskDrive', 'System') { 'Error' } else { 'Warning' } }

function Test-WdhDrivers {
    param($C)
    $cfg = $C.Config['drivers']
    $devices = Invoke-WdhProbe $C 'devices' { Get-WdhPnpDevices }
    $report = $null
    if ($cfg['enabled']) {
        $r = Read-WdhSource $C 'drivers' 'reports\drivers.json' 'windows-deployment-builder/drivers-result'
        $snap = @($C.Snapshot.stages | Where-Object { $_.id -eq 'drivers' }) | Select-Object -First 1
        if ($r.Source.state -eq 'corrupt') { Add-WdhFinding $C 'drivers.report' 'drivers' 'Driver report' 'Unverifiable' 'Error' 'A readable driver report' 'drivers.json is damaged' 'reports\drivers.json' 'reports\drivers.json' 'Run "Deployment recovery" > Retry failed operations to run the driver stage again.' -RecoveryAction 'RetryFailed' | Out-Null }
        elseif (-not $r.Data) { Add-WdhFinding $C 'drivers.report' 'drivers' 'Driver report' $(if ($snap -and $snap.state -eq 'Final') { 'Unverifiable' } else { 'Pending' }) 'Error' 'The driver stage finished' $(if ($snap) { "No report yet (stage $($snap.state))" } else { 'No report' }) 'reports\drivers.json' 'reports\drivers.json' 'Wait for the driver stage.' | Out-Null }
        elseif ([string] $r.Data['deploymentId'] -and [string] $r.Data['deploymentId'] -ne [string] $C.Manifest.packageId) { $r.Source.state = 'inconsistent'; Add-WdhFinding $C 'drivers.report' 'drivers' 'Driver report' 'Unverifiable' 'Error' "The report of deployment $($C.Manifest.packageId)" "The report belongs to deployment $($r.Data['deploymentId'])" 'drivers.json deploymentId' 'reports\drivers.json' 'Run the driver stage of this deployment again.' | Out-Null }
        elseif (-not $r.Data['final'] -and $snap -and $snap.state -eq 'Final') { $r.Source.state = 'inconsistent'; Add-WdhFinding $C 'drivers.report' 'drivers' 'Driver report' 'Unverifiable' 'Error' 'A final driver report' 'The stage finished but its report is not final' 'drivers.json final vs Drivers\result.json' 'reports\drivers.json' 'Run "Deployment recovery" > Resume.' | Out-Null }
        else {
            $report = $r.Data
            $hs = $(if ($report['health'] -is [hashtable]) { [string] $report['health']['status'] } else { '' })
            Add-WdhFinding $C 'drivers.report' 'drivers' 'Driver stage' $(if (-not $report['final']) { 'Pending' } else { 'Info' }) 'Informational' 'The driver stage finished' "$([string] $report['status']); health $hs (as the stage saw it; compared with the devices below)" 'reports\drivers.json' 'reports\drivers.json' -Required $false | Out-Null
        }
    } else {
        Add-WdhFinding $C 'drivers.stage' 'drivers' 'Driver stage' 'Info' 'Informational' 'Not part of this deployment' 'No driver was installed or changed by the deployment; the devices are still checked' 'health-config.json' 'health-config.json' -Required $false | Out-Null
    }
    if ($null -eq $devices) { Add-WdhFinding $C 'drivers.devices' 'drivers' 'Devices' 'Unverifiable' 'Error' 'Every device working' 'The device list could not be read' 'Win32_PnPEntity' 'Plug and Play' 'Run the check again as administrator.' | Out-Null; return }
    $byHw = @{}
    if ($report) { foreach ($d in @(ConvertTo-WdhList $report['devices'])) { foreach ($h in @(ConvertTo-WdhList $d['hardwareIds'])) { $byHw[([string] $h).ToUpperInvariant()] = $d } } }
    $problems = 0
    $basic = 0
    # Devices the deployment itself reported with a problem, compared with Device Manager now.
    $prev = @(Get-WdhPreviousProblemDevices $C)
    $matched = @{}
    foreach ($dev in @($devices)) {
        $code = [int] $dev.problemCode
        $rep = $(if ($dev.hardwareId -and $byHw.ContainsKey($dev.hardwareId.ToUpperInvariant())) { $byHw[$dev.hardwareId.ToUpperInvariant()] } else { $null })
        $id = "drivers.device.$((Get-WddSha256 ([Text.Encoding]::UTF8.GetBytes("$($dev.hardwareId)|$($dev.name)"))).Substring(0, 12).ToLowerInvariant())"
        $hwText = "hardware ID $(if ($dev.hardwareId) { $dev.hardwareId } else { 'not reported' })"
        $p = $(if ($prev.Count -and $code -notin 45, 47) { Find-WdhPreviousDevice $dev $prev } else { $null })
        $pText = ''
        if ($p) {
            $matched[$p.key] = $true
            $pid2 = "drivers.previous.$(Get-WdhShortHash $p.key)"
            $was = "code $($p.problemCode): $(if ($script:WdhProblemCodes.ContainsKey($p.problemCode)) { $script:WdhProblemCodes[$p.problemCode] } else { 'problem' })"
            $C.DeviceComparison.Add([ordered]@{ name = [string] $dev.name; hardwareIds = @($p.hardwareIds); deviceId = [string] $p.deviceId; previousProblemCode = [int] $p.problemCode; currentProblemCode = $code; state = $(if ($code -eq 0) { 'NowHealthy' } else { 'StillHasProblem' }); source = $p.source; findingId = $(if ($code -eq 0) { $pid2 } else { $id }) })
            if ($code -eq 0) { Add-WdhFinding $C $pid2 'drivers' "$($dev.name): previously reported, now healthy" 'Info' 'Informational' 'Working driver' "Working now (problem code 0). The deployment had reported it with $was; $hwText" 'Plug and Play problem code now, compared with the devices the deployment reported (devicesWithProblems)' "Win32_PnPEntity, $($p.source)" -Required $false -TechnicianRequired $false | Out-Null }
            else { $pText = "; already reported by the deployment ($was)" }
        }
        $isBasic = $dev.class -eq 'Display' -and ($dev.service -eq 'BasicDisplay' -or $dev.name -like 'Microsoft Basic Display*')
        if ($code -eq 0 -and $isBasic) {
            $basic++
            Add-WdhFinding $C $id 'drivers' $dev.name 'Warning' 'Warning' 'A vendor graphics driver' 'Working with the generic Microsoft Basic Display driver (functional but limited: resolution, acceleration, multiple monitors)' 'Plug and Play service and problem code' 'Win32_PnPEntity' $(if ($rep -and $rep['manualAction'] -is [hashtable]) { [string] $rep['manualAction']['text'] } else { 'Install the graphics driver from Windows Update or the manufacturer.' }) -Required $false | Out-Null
            continue
        }
        if ($code -eq 0) {
            if ($rep -and [string] $rep['state'] -in 'DriverMissing', 'Malfunctioning', 'HardwareIssue') { Add-WdhFinding $C $id 'drivers' $dev.name 'Pass' 'Error' 'Working driver' "Working now (the driver stage had reported $($rep['state']))" 'Plug and Play problem code now vs drivers.json' 'Win32_PnPEntity, reports\drivers.json' | Out-Null }
            continue
        }
        if ($code -in 45, 47) { continue }
        $problems++
        $what = $(if ($script:WdhProblemCodes.ContainsKey($code)) { $script:WdhProblemCodes[$code] } else { 'problem' })
        $sev = Get-WdhDeviceSeverity $dev.class
        if ($code -eq 22) { Add-WdhFinding $C $id 'drivers' $dev.name 'Info' 'Informational' 'Working, or disabled on purpose' "Disabled (code 22). A disabled device is not treated as broken." 'Plug and Play problem code' 'Win32_PnPEntity' 'Enable it in Device Manager only if it should be in use.' -Required $false | Out-Null; continue }
        if ($code -eq 14 -or ($rep -and [string] $rep['state'] -eq 'RestartPending')) { Add-WdhFinding $C $id 'drivers' $dev.name 'Pending' $sev 'Working driver' "Waiting for a restart (code ${code}: $what)$pText; $hwText"'Plug and Play problem code' 'Win32_PnPEntity' 'Restart the computer.' -AutomaticRecovery $true -TechnicianRequired $false | Out-Null; continue }
        $hw = ($rep -and [string] $rep['state'] -eq 'HardwareIssue') -or (-not $rep -and $code -in $script:WdhHardwareCodes -and $code -ne 10)
        $wasOk = $rep -and [string] $rep['state'] -in 'Healthy', 'BasicDriver'
        $obs = "$(if ($code -eq 28) { 'Missing driver' } elseif ($hw) { 'Possible hardware or firmware problem' } else { 'Not working' }) (code ${code}: $what)$(if ($wasOk) { '; it was working when the driver stage finished' })$(if ($rep -and [string] $rep['result'] -eq 'Succeeded') { '; a driver was installed for it, but the device still reports a problem' })$pText; $hwText"
        $next = $(if ($rep -and $rep['manualAction'] -is [hashtable] -and $rep['manualAction']['text']) { [string] $rep['manualAction']['text'] } elseif ($code -eq 28) { 'Install a driver: Windows Update, the manufacturer''s support page, or "Deployment recovery" > Add driver packages.' } elseif ($hw) { 'Check the hardware (seating, cables, firmware settings) before replacing drivers.' } else { 'Open Device Manager for details; reinstall the driver or check the hardware.' })
        $C.Manual.Add([ordered]@{ id = $id; text = "$($dev.name): $next"; url = $(if ($rep -and $rep['manualAction'] -is [hashtable]) { [string] $rep['manualAction']['url'] } else { '' }) })
        Add-WdhFinding $C $id 'drivers' $dev.name 'Fail' $sev 'Working driver' $obs 'Plug and Play problem code (Win32_PnPEntity.ConfigManagerErrorCode), compared with drivers.json' 'Win32_PnPEntity, reports\drivers.json' $next -RecoveryAction $(if ($code -eq 28) { 'AddDrivers' } else { '' }) | Out-Null
    }
    foreach ($p in @($prev | Where-Object { $_ -and -not $matched.ContainsKey($_.key) })) {
        $pid2 = "drivers.previous.$(Get-WdhShortHash $p.key)"
        $C.DeviceComparison.Add([ordered]@{ name = [string] $p.name; hardwareIds = @($p.hardwareIds); deviceId = [string] $p.deviceId; previousProblemCode = [int] $p.problemCode; currentProblemCode = $null; state = 'NotPresent'; source = $p.source; findingId = $pid2 })
        Add-WdhFinding $C $pid2 'drivers' "$($p.name): previously reported, not present now" 'Info' 'Informational' 'Working driver' "Not present now (disconnected, removed or re-enumerated). The deployment had reported it with code $($p.problemCode); hardware ID $(if (@($p.hardwareIds).Count) { @($p.hardwareIds)[0] } else { 'not recorded' })" 'Present devices (Win32_PnPEntity) compared with the devices the deployment reported' "Win32_PnPEntity, $($p.source)" -Required $false -TechnicianRequired $false | Out-Null
    }
    $note = ' Zero device problems is a hardware-health result, not proof that every optional driver was installed.'
    if (-not $problems -and -not $basic) { Add-WdhFinding $C 'drivers.devices' 'drivers' 'Devices' 'Pass' 'Error' 'Every device working' "$(@($devices).Count) device(s), none reports a problem.$note" 'Plug and Play problem codes (Win32_PnPEntity)' 'Win32_PnPEntity' | Out-Null }
    elseif (-not $problems) { Add-WdhFinding $C 'drivers.devices' 'drivers' 'Devices' 'Pass' 'Error' 'Every device working' "$(@($devices).Count) device(s), none reports a problem ($basic with a generic driver).$note" 'Plug and Play problem codes' 'Win32_PnPEntity' | Out-Null }
    if ($report) {
        foreach ($m in @(ConvertTo-WdhList $report['manualActions'])) {
            $C.Manual.Add([ordered]@{ id = "drivers.manual.$($m['operationId'])"; text = [string] $m['text']; url = [string] $m['url'] })
        }
        foreach ($o in @(ConvertTo-WdhList $report['operations']) | Where-Object { $_ -and [string] $_['status'] -eq 'WaitingForReboot' }) {
            Add-WdhFinding $C "drivers.restart.$($o['operationId'] -replace '[^A-Za-z0-9_:+\-]', '-')" 'drivers' "$($o['device']): restart needed" 'Pending' 'Warning' 'Driver active' 'The new driver starts after a restart' 'drivers.json operations[]' 'reports\drivers.json' 'Restart the computer.' -AutomaticRecovery $true -TechnicianRequired $false | Out-Null
        }
        $tools = @(@(ConvertTo-WdhList $report['optionalApplications']) | ForEach-Object { [string] $_['name'] } | Where-Object { $_ })
        if ($tools.Count) { Add-WdhFinding $C 'drivers.vendorReview' 'drivers' 'Vendor driver review' 'Info' 'Informational' 'Optional' "Vendor driver review recommended: $($tools -join ', '). These tools have not scanned this computer; the deployment never runs them." 'drivers.json optionalApplications' 'reports\drivers.json' 'Optionally run the vendor tool with the customer. A working driver does not need replacing.' -Required $false | Out-Null }
    }
}

# ------------------------------------------------------------------------------------------------
# Manufacturer software: optional recommendations only (every finding Info, never required)
# ------------------------------------------------------------------------------------------------

$script:WdhNoAutoInstall = 'No verified WinGet package (checked microsoft/winget-pkgs) and the vendor installer''s unattended mode is not verified'

<# Desktop or portable, from the SMBIOS chassis types and a battery. #>
function Get-WdhChassisKind {
    param($Chassis)
    if (-not $Chassis) { return @{ kind = 'unknown'; text = 'the chassis type could not be read' } }
    $types = @(@(ConvertTo-WdhList $Chassis.chassisTypes) | ForEach-Object { [int] $_ })
    $list = $(if ($types.Count) { $types -join ', ' } else { 'none reported' })
    # Portable: 8 Portable, 9 Laptop, 10 Notebook, 11 Hand Held, 12 Docking Station, 14 Sub Notebook, 30 Tablet, 31 Convertible, 32 Detachable.
    if (@($types | Where-Object { $_ -in 8, 9, 10, 11, 12, 14, 30, 31, 32 }).Count -or [bool] $Chassis.battery) { return @{ kind = 'portable'; text = "portable computer (chassis type $list$(if ($Chassis.battery) { '; a battery is present' }))" } }
    # Desktop: 3 Desktop, 4 Low Profile, 5 Pizza Box, 6 Mini Tower, 7 Tower, 13 All in One, 15 Space-saving, 16 Lunch Box, 17 Main System Chassis, 24 Sealed-case PC, 35 Mini PC, 36 Stick PC.
    if (@($types | Where-Object { $_ -in 3, 4, 5, 6, 7, 13, 15, 16, 17, 24, 35, 36 }).Count) { return @{ kind = 'desktop'; text = "desktop (chassis type $list; no battery)" } }
    return @{ kind = 'unknown'; text = "chassis type $list is not a desktop type (no battery)" }
}

function Test-WdhManufacturerSoftware {
    param($C)
    $gpus = Invoke-WdhProbe $C 'videoControllers' { Get-WdhVideoControllers }
    $cpus = Invoke-WdhProbe $C 'processors' { Get-WdhProcessors }
    $chassis = Invoke-WdhProbe $C 'chassis' { Get-WdhChassis }
    $entries = Invoke-WdhProbe $C 'uninstall' { Get-WdhUninstallEntries $(if ($C.HiveLoaded) { $C.DeploymentSid } else { '' }) }
    $gpuList = @(ConvertTo-WdhList $gpus); $cpuList = @(ConvertTo-WdhList $cpus)
    # An empty list is a result; only a failed read (reported in the limitations) leaves the installed state unknown.
    $uninstallFailed = @($C.Limitations | Where-Object { $_ -like 'Could not read uninstall*' }).Count -gt 0
    $kind = Get-WdhChassisKind $chassis
    $now = (Get-WdhTime).ToString('o')
    $method = 'Win32_VideoController (Name, PNPDeviceID), Win32_Processor, Win32_SystemEnclosure ChassisTypes and Win32_Battery; uninstall records for the installed state (read-only)'
    $recs = @()
    $nv = @($gpuList | Where-Object { [string] $_.pnpDeviceId -match '(?i)VEN_10DE' -and [string] $_.name -match '(?i)GeForce|RTX|TITAN|Quadro' }) | Select-Object -First 1
    if ($nv) {
        $recs += , @{ id = 'nvidiaApp'; utility = 'NVIDIA App'; vendor = 'NVIDIA'; pattern = '^NVIDIA App\b'; url = 'https://www.nvidia.com/en-us/software/nvidia-app/'; detected = "$($nv.name) (PCI vendor 10DE)"
                      compatibility = "NVIDIA GeForce, RTX, TITAN or Quadro graphics ($($nv.name)): NVIDIA App is NVIDIA's utility for these cards (driver updates and graphics settings)."
                      signIn = 'No NVIDIA account is required for driver updates; signing in is optional.'; notes = 'A working driver from Windows Update does not need replacing.' }
    }
    $amd = @($gpuList | Where-Object { [string] $_.pnpDeviceId -match '(?i)VEN_1002' -and [string] $_.name -match '(?i)Radeon' }) | Select-Object -First 1
    if ($amd) {
        $recs += , @{ id = 'amdAdrenalin'; utility = 'AMD Software: Adrenalin Edition'; vendor = 'AMD'; pattern = '^AMD Software\b'; url = 'https://www.amd.com/en/products/software/adrenalin.html'; detected = "$($amd.name) (PCI vendor 1002)"
                      compatibility = "AMD Radeon graphics ($($amd.name)): AMD Software: Adrenalin Edition is AMD's graphics driver and settings suite. It is recommended because of the Radeon graphics, never because of an AMD processor alone."
                      signIn = 'No account is required.'; notes = 'A working driver from Windows Update does not need replacing.' }
    }
    $ryzen = @($cpuList | Where-Object { [string] $_.name -match '(?i)^\s*AMD Ryzen' }) | Select-Object -First 1
    $notes = @()
    if ($ryzen -and $kind.kind -eq 'desktop') {
        $recs += , @{ id = 'amdRyzenMaster'; utility = 'AMD Ryzen Master'; vendor = 'AMD'; pattern = '^AMD Ryzen Master\b'; url = 'https://www.amd.com/en/products/software/ryzen-master.html'; detected = "$($ryzen.name); $($kind.text)"
                      compatibility = "AMD Ryzen desktop processor ($($ryzen.name)) in a $($kind.text): AMD Ryzen Master is an optional monitoring and tuning tool, not a chipset driver."
                      signIn = 'No account is required.'; notes = 'Windows Deployment Builder never applies tuning, overclocking, undervolting, voltage, BIOS or profile changes; any tuning is the owner''s own decision.' }
    } elseif ($ryzen) { $notes += "AMD Ryzen Master is not recommended: $($kind.text) (it is meant for desktop Ryzen processors)" }
    if (-not $amd -and @($cpuList | Where-Object { [string] $_.name -match '(?i)\bAMD\b' -or [string] $_.manufacturer -match '(?i)AMD' }).Count) { $notes += 'AMD Software: Adrenalin Edition is not recommended: no Radeon graphics (an AMD processor alone does not need it)' }
    $items = @()
    foreach ($r in $recs) {
        $hit = @(@(ConvertTo-WdhList $entries) | Where-Object { [string] $_.displayName -match $r.pattern }) | Select-Object -First 1
        $installed = $(if ($uninstallFailed) { $null } else { [bool] $hit })
        $fid = "vendor.$($r.id)"
        $manual = $(if ($installed) { 'Already installed; nothing to do.' } else { "Optional: if the customer wants it, download it from $($r.url) and install it with them." })
        $obs = "Detected: $($r.detected). $($r.compatibility) Installed: $(if ($null -eq $installed) { 'could not be read' } elseif ($installed) { "yes ($($hit.displayName)$(if ($hit.displayVersion) { " $($hit.displayVersion)" }))" } else { 'no' }). Automatic installation: no ($script:WdhNoAutoInstall). $($r.signIn) $($r.notes)"
        Add-WdhFinding $C $fid 'hardwareSoftware' "$($r.utility) (optional)" 'Info' 'Informational' 'Optional manufacturer utility (recommendation only)' $obs $method $r.url $(if ($installed) { '' } else { $manual }) -Required $false -TechnicianRequired $false | Out-Null
        $items += , [ordered]@{ id = $r.id; utility = $r.utility; vendor = $r.vendor; recommended = $true; detectedHardware = $r.detected; compatibility = $r.compatibility; installed = $installed
                                installedVersion = $(if ($hit) { [string] $hit.displayVersion } else { '' }); automaticInstall = $false; automaticInstallReason = $script:WdhNoAutoInstall; manualAction = $manual; url = $r.url
                                signIn = $r.signIn; notes = $r.notes; findingId = $fid; checkedUtc = $now }
    }
    foreach ($i in $items) { $C.HardwareSoftware.Add($i) }
    $hwText = "Graphics: $(if ($null -eq $gpus) { 'could not be read' } elseif ($gpuList.Count) { ($gpuList | ForEach-Object { $_.name }) -join ', ' } else { 'none reported' }); processor: $(if ($null -eq $cpus) { 'could not be read' } elseif ($cpuList.Count) { ($cpuList | ForEach-Object { $_.name }) -join ', ' } else { 'none reported' }); $($kind.text)"
    Add-WdhFinding $C 'vendor.summary' 'hardwareSoftware' 'Manufacturer software recommendations' 'Info' 'Informational' 'Recommendations only; nothing is installed by this check' "$hwText. Recommended: $(if ($items.Count) { ($items | ForEach-Object { $_.utility }) -join ', ' } else { 'none' }).$(if ($notes.Count) { ' ' + ($notes -join '. ') + '.' })" $method 'WMI, uninstall records' -Required $false -TechnicianRequired $false | Out-Null
}

# ------------------------------------------------------------------------------------------------
# Security
# ------------------------------------------------------------------------------------------------

function Test-WdhSecurity {
    param($C)
    $sec = $C.Config['security']
    $def = Invoke-WdhProbe $C 'defender' { Get-WdhDefender }
    $sc = Invoke-WdhProbe $C 'securityCenter' { Get-WdhSecurityCenter }
    $third = @(); $thirdFw = @()
    if ($sc) { $third = @(@($sc.antivirus) | Where-Object { $_.enabled -and $_.name -notmatch 'Windows Defender|Microsoft Defender' }); $thirdFw = @(@($sc.firewall) | Where-Object { $_.enabled }) }
    $defOn = $def -and $def.amServiceEnabled -and $def.antivirusEnabled -and $def.realTimeProtectionEnabled
    if ($defOn) { Add-WdhFinding $C 'security.antivirus' 'security' 'Antivirus' 'Pass' 'Critical' 'Real-time protection on' "Microsoft Defender Antivirus, real-time protection on (signatures $($def.signatureAgeDays) day(s) old)" 'Get-MpComputerStatus, Windows Security Center' 'Defender, SecurityCenter2' $(if ($def.signatureAgeDays -gt 7) { 'Update the security intelligence (Windows Security > Virus & threat protection).' } else { '' }) | Out-Null }
    elseif ($third.Count) { Add-WdhFinding $C 'security.antivirus' 'security' 'Antivirus' 'Pass' 'Critical' 'Real-time protection on' "Protected by $(($third | ForEach-Object { $_.name }) -join ', ') (registered with Windows Security; Defender hands over to it)" 'Windows Security Center (SecurityCenter2) product state' 'SecurityCenter2' | Out-Null }
    elseif (-not $def -and -not $sc) { Add-WdhFinding $C 'security.antivirus' 'security' 'Antivirus' 'Unverifiable' 'Critical' 'Real-time protection on' 'Neither Defender nor Windows Security Center could be read' 'Get-MpComputerStatus, SecurityCenter2' 'Defender, SecurityCenter2' 'Run the check again as administrator; open Windows Security to confirm.' | Out-Null }
    else { Add-WdhFinding $C 'security.antivirus' 'security' 'Antivirus' 'Fail' 'Critical' 'Real-time protection on' "No active antivirus: $(if ($def) { "Defender service $($def.amServiceEnabled), antivirus $($def.antivirusEnabled), real-time $($def.realTimeProtectionEnabled)" } else { 'Defender unavailable' }), and no other product is registered" 'Get-MpComputerStatus, Windows Security Center' 'Defender, SecurityCenter2' 'Turn real-time protection on in Windows Security (nothing was changed by this check). Do not deliver an unprotected computer.' | Out-Null }
    $fw = Invoke-WdhProbe $C 'firewall' { Get-WdhFirewall }
    if ($null -eq $fw) { Add-WdhFinding $C 'security.firewall' 'security' 'Firewall' 'Unverifiable' 'Critical' 'On for every profile' 'Could not be read' 'Get-NetFirewallProfile' 'Firewall' | Out-Null }
    else {
        $off = @(@($fw) | Where-Object { -not $_.enabled } | ForEach-Object { $_.name })
        if (-not $off.Count) { Add-WdhFinding $C 'security.firewall' 'security' 'Firewall' 'Pass' 'Critical' 'On for every profile' "On: $((@($fw) | ForEach-Object { $_.name }) -join ', ')" 'Get-NetFirewallProfile' 'Firewall' | Out-Null }
        elseif ($thirdFw.Count) { Add-WdhFinding $C 'security.firewall' 'security' 'Firewall' 'Pass' 'Critical' 'On for every profile' "Windows Firewall off for $($off -join ', '); $(($thirdFw | ForEach-Object { $_.name }) -join ', ') is registered and on" 'Get-NetFirewallProfile, SecurityCenter2' 'Firewall' | Out-Null }
        elseif ($off.Count -eq @($fw).Count) { Add-WdhFinding $C 'security.firewall' 'security' 'Firewall' 'Fail' 'Critical' 'On for every profile' 'Off for every profile' 'Get-NetFirewallProfile' 'Firewall' 'Turn the firewall on (Windows Security > Firewall & network protection); nothing was changed by this check.' | Out-Null }
        else { Add-WdhFinding $C 'security.firewall' 'security' 'Firewall' 'Fail' 'Error' 'On for every profile' "Off for $($off -join ', ')" 'Get-NetFirewallProfile' 'Firewall' 'Turn the firewall on for every profile.' | Out-Null }
    }
    $uac = Invoke-WdhProbe $C 'uac' { Get-WdhUac }
    $want = $sec['uac']
    if ($uac) {
        $lua = $(if ($null -eq $uac.enableLua) { 1 } else { [int] $uac.enableLua })
        if ([int] $want['enableLua'] -eq 0) { Add-WdhFinding $C 'security.uac' 'security' 'User Account Control' $(if ($lua -eq 0) { 'Warning' } else { 'Info' }) 'Warning' 'Off (configured)' $(if ($lua -eq 0) { 'Off, as configured: every program runs with full rights' } else { 'On' }) 'Policies\System EnableLUA' 'Registry' 'UAC is off by configuration; consider turning it on before delivery.' -Required $false | Out-Null }
        elseif ($lua -eq 0) { Add-WdhFinding $C 'security.uac' 'security' 'User Account Control' 'Fail' 'Error' 'On' 'Off (EnableLUA = 0)' 'Policies\System EnableLUA' 'Registry' 'UAC was turned off although the configuration keeps it on; turn it on (restart needed).' | Out-Null }
        else {
            $cp = $want['consentPromptBehaviorAdmin']; $sd = $want['promptOnSecureDesktop']
            $mism = ($null -ne $cp -and $null -ne $uac.consentPromptBehaviorAdmin -and [int] $uac.consentPromptBehaviorAdmin -ne [int] $cp) -or ($null -ne $sd -and $null -ne $uac.promptOnSecureDesktop -and [int] $uac.promptOnSecureDesktop -ne [int] $sd)
            Add-WdhFinding $C 'security.uac' 'security' 'User Account Control' $(if ($mism) { 'Warning' } else { 'Pass' }) 'Error' "On ($($want['level']))" "On (ConsentPromptBehaviorAdmin $($uac.consentPromptBehaviorAdmin), PromptOnSecureDesktop $($uac.promptOnSecureDesktop))" 'Policies\System EnableLUA, ConsentPromptBehaviorAdmin, PromptOnSecureDesktop' 'Registry' $(if ($mism) { 'The prompt level differs from the configuration (an organization policy or a later change).' } else { '' }) | Out-Null
        }
    } else { Add-WdhFinding $C 'security.uac' 'security' 'User Account Control' 'Unverifiable' 'Error' 'On' 'Could not be read' 'Policies\System' 'Registry' | Out-Null }
    $ss = Invoke-WdhProbe $C 'smartScreen' { Get-WdhSmartScreen }
    if ($ss) {
        $offBy = @()
        if ($ss.explorer -ieq 'Off') { $offBy += 'Explorer SmartScreenEnabled = Off' }
        if ($null -ne $ss.policy -and [int] $ss.policy -eq 0) { $offBy += 'policy EnableSmartScreen = 0' }
        if ($sec['smartScreenExpected']) { Add-WdhFinding $C 'security.smartScreen' 'security' 'SmartScreen' $(if ($offBy.Count) { 'Warning' } else { 'Pass' }) 'Warning' 'On (reputation-based protection)' $(if ($offBy.Count) { "Turned off: $($offBy -join '; ')" } else { 'Not turned off by setting or policy' }) 'Explorer SmartScreenEnabled and the EnableSmartScreen policy (Windows Security shows the full state)' 'Registry' $(if ($offBy.Count) { 'Turn SmartScreen on in Windows Security > App & browser control.' } else { '' }) -Required $false | Out-Null }
        else { Add-WdhFinding $C 'security.smartScreen' 'security' 'SmartScreen' 'Info' 'Informational' 'Off (configured)' $(if ($offBy.Count) { "Off: $($offBy -join '; ')" } else { 'Not turned off' }) 'Explorer SmartScreenEnabled, EnableSmartScreen policy' 'Registry' -Required $false | Out-Null }
    }
    $enc = Invoke-WdhProbe $C 'encryption' { Get-WdhEncryption }
    if (-not $enc) { Add-WdhFinding $C 'security.encryption' 'security' 'Encryption' 'Info' 'Informational' 'Reported' 'The encryption state could not be read (BitLocker is not available on every edition)' 'Get-BitLockerVolume' 'BitLocker' -Required $false | Out-Null }
    else {
        $protected = $enc.protectionStatus -eq 'On'
        $obs = "$($enc.volumeStatus), protection $($enc.protectionStatus)$(if ($enc.volumeStatus -eq 'EncryptionInProgress') { " ($([int] $enc.percentage) %)" })"
        Add-WdhFinding $C 'security.encryption' 'security' 'Encryption of the system drive' 'Info' 'Informational' $(if ($sec['deviceEncryptionPrevented']) { 'Not encrypted automatically (configured)' } else { 'Reported (never turned on by the deployment)' }) $obs 'Get-BitLockerVolume (protector types only; keys are never read)' 'BitLocker' -Required $false | Out-Null
        if ($protected -or $enc.volumeStatus -in 'FullyEncrypted', 'EncryptionInProgress') {
            $hasRecovery = @($enc.protectors) -contains 'RecoveryPassword'
            Add-WdhFinding $C 'security.recoveryKey' 'security' 'Recovery key backup' 'Warning' 'Warning' 'The customer can retrieve the recovery key' "$(if ($hasRecovery) { 'A recovery password protector exists' } else { 'No recovery password protector' }); where it is backed up cannot be verified from this computer" 'BitLocker key protector types' 'BitLocker' 'Confirm with the customer where the recovery key is kept (for example their Microsoft account at https://aka.ms/myrecoverykey). The key is not in this report.' -Required $false | Out-Null
        }
    }
}

# ------------------------------------------------------------------------------------------------
# Network
# ------------------------------------------------------------------------------------------------

function Test-WdhNetwork {
    param($C)
    $mode = [string] $C.Config['network']['requirement']
    $need = @()
    foreach ($s in @($C.Snapshot.stages)) { if ($s.state -ne 'Final' -and $s.id -in 'windowsUpdate', 'applications') { $need += $s.name } }
    foreach ($a in $C.Apps) { if ($a.lifecycle -in 'WaitingForNetwork', 'FailedRetryable') { $need += $a.name } }
    if ($C.ScanUpdates) { $need += 'the Windows Update scan' }
    $required = $(if ($mode -eq 'required') { $true } elseif ($mode -eq 'notRequired') { $false } else { $need.Count -gt 0 })
    $why = $(if ($mode -eq 'required') { 'required by the configuration' } elseif ($need.Count) { "needed by $(@($need | Select-Object -Unique) -join ', ')" } else { 'not needed: nothing outstanding uses the network' })
    $netFlag = Get-WddNetworkDriverFlag $C.Paths
    $net = Invoke-WdhProbe $C 'network' { Get-WdhNetwork }
    $sevNeed = $(if ($required) { 'Error' } else { 'Warning' })
    if ($netFlag) { Add-WdhFinding $C 'network.driver' 'network' 'Network adapter driver' 'Fail' $sevNeed 'A network adapter with a working driver' $netFlag 'Driver stage flag (state\network-driver-missing.json) and the adapter list' 'state\network-driver-missing.json' 'The network will not appear by itself: supply the adapter''s driver ("Deployment recovery" > Add driver packages, from a USB stick).' -RecoveryAction 'AddDrivers' -Required $required | Out-Null }
    if (-not $net) { Add-WdhFinding $C 'network.adapter' 'network' 'Network adapters' 'Unverifiable' $sevNeed 'A connected adapter' 'Could not be read' 'Get-NetAdapter' 'Network' -Required $required | Out-Null; return }
    $up = @(@($net.adapters) | Where-Object { $_.status -eq 'Up' })
    if (-not @($net.adapters).Count) { Add-WdhFinding $C 'network.adapter' 'network' 'Network adapters' $(if ($required) { 'Fail' } else { 'Warning' }) $sevNeed 'A physical network adapter' 'None is visible to Windows (often a missing driver)' 'Get-NetAdapter -Physical' 'Network' 'Check Hardware and drivers; install the network driver.' -Required $required -RecoveryAction 'AddDrivers' | Out-Null; return }
    if (-not $up.Count) { Add-WdhFinding $C 'network.adapter' 'network' 'Network connection' $(if ($required) { 'Fail' } else { 'Info' }) $sevNeed "Connected ($why)" "$(@($net.adapters).Count) adapter(s), none connected" 'Get-NetAdapter -Physical' 'Network' $(if ($required) { 'Connect a cable or Wi-Fi; the deployment continues once online.' } else { 'Not a problem for this computer now.' }) -Required $required | Out-Null; return }
    Add-WdhFinding $C 'network.adapter' 'network' 'Network connection' 'Pass' $sevNeed "Connected ($why)" "$($up.Count) adapter(s) connected$(if (@($up | Where-Object { $_.wireless }).Count) { ' (Wi-Fi)' })" 'Get-NetAdapter -Physical' 'Network' -Required $required | Out-Null
    $dns = Test-WdhDns 'www.msftconnecttest.com'
    $inet = $(if ($dns) { Test-WdhInternet } else { $false })
    $obs = $(if (-not $net.gateway) { 'No default gateway (local network only)' } elseif (-not $dns) { 'DNS does not resolve names' } elseif (-not $inet) { 'Names resolve, but the Windows connectivity test failed (proxy, captive portal or no Internet)' } else { 'Reachable (DNS and the Windows connectivity test)' })
    $ok = $net.gateway -and $dns -and $inet
    Add-WdhFinding $C 'network.internet' 'network' 'Internet' $(if ($ok) { 'Pass' } elseif ($required) { 'Fail' } else { 'Info' }) $sevNeed "Reachable ($why)" $obs 'Default gateway, DNS lookup, the Windows connectivity test (msftconnecttest.com); never a single ping' 'Network' $(if ($ok -or -not $required) { '' } else { 'Fix the connection; outstanding work continues once online.' }) -Required $required | Out-Null
    if ($ok -and @($C.Apps | Where-Object { $_.lifecycle -in 'WaitingForNetwork', 'FailedRetryable' -and $_.source -in 'winget', 'msstore' }).Count) {
        $src = Test-WdhTcp 'cdn.winget.microsoft.com' 443
        Add-WdhFinding $C 'network.packageSource' 'network' 'WinGet package source' $(if ($src) { 'Pass' } else { 'Fail' }) 'Error' 'Reachable for the outstanding applications' $(if ($src) { 'cdn.winget.microsoft.com:443 reachable' } else { 'cdn.winget.microsoft.com:443 not reachable (Internet works: the source or a filter blocks it)' }) 'TCP 443 to the source host' 'Network' $(if ($src) { '' } else { 'Check firewalls or filters for the WinGet source.' }) | Out-Null
    }
}

# ------------------------------------------------------------------------------------------------
# Storage (non-destructive observations only)
# ------------------------------------------------------------------------------------------------

function Test-WdhStorage {
    param($C)
    $v = Invoke-WdhProbe $C 'volume' { Get-WdhVolume }
    if (-not $v) { Add-WdhFinding $C 'storage.systemVolume' 'storage' 'System drive' 'Unverifiable' 'Error' 'Accessible and healthy' 'Could not be read' 'Get-Volume' 'Storage' | Out-Null }
    else {
        $healthy = $v.health -in 'Healthy', '' -and $v.operational -in 'OK', ''
        Add-WdhFinding $C 'storage.systemVolume' 'storage' "System drive ($env:SystemDrive)" $(if ($healthy) { 'Pass' } else { 'Fail' }) 'Error' 'Accessible, NTFS, healthy' "$($v.fileSystem), health $($v.health), $($v.operational)" 'Get-Volume (what Windows reports; not a physical drive test)' 'Storage' $(if ($healthy) { '' } else { 'Back up important data and check the drive; this check repairs nothing.' }) | Out-Null
        if ($v.size -gt 0) {
            $pct = [Math]::Round(100 * $v.free / $v.size)
            $st = $(if ($v.free -lt 3GB) { 'Fail' } elseif ($v.free -lt 10GB -or $pct -lt 10) { 'Warning' } else { 'Pass' })
            Add-WdhFinding $C 'storage.freeSpace' 'storage' "Free space on $env:SystemDrive" $st $(if ($st -eq 'Fail') { 'Error' } else { 'Warning' }) 'At least 10 GB and 10 %' "$(Format-WdhBytes $v.free) free of $(Format-WdhBytes $v.size) ($pct %)" 'Get-Volume' 'Storage' $(if ($st -eq 'Pass') { '' } else { 'Free up space; Windows Update needs room to install updates.' }) -Required ($st -eq 'Fail') | Out-Null
        }
        if ($null -ne $v.dirty) { Add-WdhFinding $C 'storage.dirtyBit' 'storage' 'File system state' $(if ($v.dirty) { 'Warning' } else { 'Pass' }) 'Warning' 'No check pending' $(if ($v.dirty) { 'Marked dirty: Windows will check the file system at the next start' } else { 'Not marked dirty' }) 'fsutil dirty query (read-only)' 'Storage' $(if ($v.dirty) { 'Restart and let Windows check the drive. Nothing was repaired by this check.' } else { '' }) -Required $false | Out-Null }
    }
    if ($C.Config['options']['storageObservations']) {
        $disks = Invoke-WdhProbe $C 'physicalDisks' { Get-WdhPhysicalDisks }
        if ($null -eq $disks) { $C.Limitations.Add('Physical disk health is not available on this computer.') }
        foreach ($d in @(ConvertTo-WdhList $disks)) {
            $rel = $d.reliability
            $relText = $(if ($rel) { "; wear $($rel.wear) %, temperature $($rel.temperature) C, uncorrected read errors $($rel.readErrorsUncorrected)" } else { '' })
            $bad = $d.health -notin 'Healthy', ''
            Add-WdhFinding $C "storage.disk.$((Get-WddSha256 ([Text.Encoding]::UTF8.GetBytes([string] $d.name))).Substring(0, 12).ToLowerInvariant())" 'storage' "Drive: $($d.name)" $(if ($bad) { 'Warning' } else { 'Info' }) 'Warning' 'Healthy' "$($d.media) $($d.bus), health $($d.health), $($d.operational)$relText" 'Get-PhysicalDisk, Get-StorageReliabilityCounter (as reported by the drive; not a full diagnosis or surface scan)' 'Storage' $(if ($bad) { 'Possible physical drive problem: back up data and run the manufacturer''s diagnostics.' } else { '' }) -Required $false | Out-Null
        }
    }
    $sd = @(@(ConvertTo-WdhList $C.Obs['devices']) | Where-Object { $_.class -in 'SCSIAdapter', 'HDC', 'DiskDrive' -and $_.problemCode -notin 0, 22, 45, 47 })
    foreach ($x in $sd) { $C.Limitations.Add("Storage device $($x.name) reports problem code $($x.problemCode) (see Hardware and drivers).") }
}

# ------------------------------------------------------------------------------------------------
# Windows settings from earlier phases (verification adapters; Phase 8.5 will register more)
# ------------------------------------------------------------------------------------------------

function Test-WdhCustomizations {
    param($C)
    $list = @(ConvertTo-WdhList $C.Config['customizations'])
    if (-not $list.Count) { Add-WdhFinding $C 'custom.none' 'customizations' 'Windows settings' 'NotApplicable' 'Informational' 'No verifiable setting is configured' 'Nothing to check' 'health-config.json' 'health-config.json' -Required $false | Out-Null; return }
    foreach ($a in $list) {
        $reg = $a['registry']
        $exp = [string] $reg['expected']
        if ([string] $a['scope'] -eq 'user') {
            if (-not $C.HiveLoaded) { $obs = "Not checked: $($C.DeploymentUser) is not signed in"; $res = 'Deferred' }
            else { $val = Get-WdhRegValue 'HKU' ([string] $reg['path']) ([string] $reg['name']) $C.DeploymentSid; $obs = $(if ($null -eq $val) { 'Not set (Windows default)' } else { [string] $val }); $res = $(if ("$val" -eq $exp) { 'Pass' } else { 'Warning' }) }
        } else { $val = Get-WdhRegValue 'HKLM' ([string] $reg['path']) ([string] $reg['name']); $obs = $(if ($null -eq $val) { 'Not set (Windows default)' } else { [string] $val }); $res = $(if ("$val" -eq $exp) { 'Pass' } else { 'Warning' }) }
        $where = "$(if ([string] $a['scope'] -eq 'user') { "HKU\<$($C.DeploymentUser)>" } else { 'HKLM' })\$($reg['path'])\$($reg['name'])"
        Add-WdhFinding $C "custom.$($a['id'])" 'customizations' ([string] $a['label']) $res 'Warning' "$($reg['name']) = $exp" $obs "Registry $where$(if ([string] $a['effect'] -ne 'immediate') { " (takes effect after $(if ([string] $a['effect'] -eq 'signIn') { 'the next sign-in' } else { 'a restart' }))" })" 'Registry' $(if ($res -eq 'Warning') { "Set it again if still wanted: $($a['reversible'])." } elseif ($res -eq 'Deferred') { "Sign in as $($C.DeploymentUser) and verify again." } else { '' }) -Required $false | Out-Null
        $C.Custom.Add([ordered]@{ id = [string] $a['id']; label = [string] $a['label']; scope = [string] $a['scope']; expected = $exp; observed = $obs; result = $res; effect = [string] $a['effect']; reversible = [string] $a['reversible'] })
    }
}

# ------------------------------------------------------------------------------------------------
# Evaluation: finding -> category -> overall (deterministic; documented in health-states.md)
# ------------------------------------------------------------------------------------------------

<# What one finding means for its category. #>
function Get-WdhEffective {
    param($F)
    switch ([string] $F.status) {
        'Fail' { if ($F.severity -eq 'Critical') { return 'Failed' } elseif ($F.severity -eq 'Error') { return 'NeedsAttention' } else { return 'Warning' } }
        'Warning' { return 'Warning' }
        'Pending' { return 'Incomplete' }
        'Unverifiable' { if ($F.required) { return 'Unverifiable' } return 'Warning' }
        'Deferred' { if ($F.required) { return 'Unverifiable' } return 'Warning' }
        default { return 'Verified' }
    }
}

function Get-WdhCategories {
    param($C)
    $out = @()
    foreach ($id in $script:WdhCategoryNames.Keys) {
        $fs = @($C.Findings | Where-Object { $_.category -eq $id })
        $counted = @($fs | Where-Object { $_.status -ne 'NotApplicable' })
        if (-not $counted.Count) {
            $out += , [ordered]@{ id = $id; name = $script:WdhCategoryNames[$id]; status = 'NotApplicable'; summary = $(if ($fs.Count) { [string] $fs[0].observed } else { 'Not checked' }); findings = $fs.Count }
            continue
        }
        $worst = 'Verified'
        foreach ($f in $counted) { $e = Get-WdhEffective $f; if ($script:WdhCategoryRank[$e] -gt $script:WdhCategoryRank[$worst]) { $worst = $e } }
        $bad = @($counted | Where-Object { (Get-WdhEffective $_) -ne 'Verified' })
        $passed = @($counted | Where-Object { $_.status -eq 'Pass' }).Count
        $summary = $(if ($bad.Count) { "$($bad.Count) of $($counted.Count) check(s) need attention: $((@($bad | Select-Object -First 3) | ForEach-Object { $_.title }) -join ', ')$(if ($bad.Count -gt 3) { ', ...' })" }
                     elseif (-not $passed) { "$($counted.Count) item(s) for information; nothing here needs action" }
                     else { "$passed of $($counted.Count) check(s) verified" })
        $out += , [ordered]@{ id = $id; name = $script:WdhCategoryNames[$id]; status = $worst; summary = $summary; findings = $fs.Count }
    }
    return $out
}

<#
    Overall state, first match wins:
      Failed        a critical check failed (wrong edition, no antivirus, firewall off, package modified, stage failed)
      Unverifiable  required evidence is missing, damaged, inconsistent or inaccessible (deferred user context)
      Incomplete    work still in progress or waiting for a restart / the network / the user
      NeedsAttention a required objective failed verification
      ReadyWithWarnings  required objectives verified; optional failures or follow-ups remain
      Ready         every required objective verified, nothing outstanding
#>
function Get-WdhOverall {
    param([object[]] $Findings)
    $eff = @($Findings | ForEach-Object { Get-WdhEffective $_ })
    foreach ($s in 'Failed', 'Unverifiable', 'Incomplete', 'NeedsAttention') { if ($eff -contains $s) { return $s } }
    if ($eff -contains 'Warning') { return 'ReadyWithWarnings' }
    return 'Ready'
}

function Get-WdhOverallText {
    param([string] $Status, [object[]] $Findings)
    $n = @($Findings | Where-Object { (Get-WdhEffective $_) -ne 'Verified' }).Count
    $first = @($Findings | Where-Object { (Get-WdhEffective $_) -eq $(switch ($Status) { 'Failed' { 'Failed' } 'Unverifiable' { 'Unverifiable' } 'Incomplete' { 'Incomplete' } 'NeedsAttention' { 'NeedsAttention' } default { 'Warning' } }) } | Select-Object -First 3 | ForEach-Object { $_.title })
    switch ($Status) {
        'Ready' { @('Ready for delivery', 'Every required objective was verified on this computer and nothing is outstanding.') }
        'ReadyWithWarnings' { @('Ready with warnings', "Every required objective was verified. $n item(s) need a technician or the customer: $($first -join ', ').") }
        'NeedsAttention' { @('Needs attention', "At least one required objective is not met: $($first -join ', '). $n item(s) in total.") }
        'Incomplete' { @('Still completing', "The deployment is still working or waiting (restart, network or user): $($first -join ', '). Verify again afterwards.") }
        'Unverifiable' { @('Cannot be verified', "Required evidence is missing, damaged or not accessible: $($first -join ', '). This is not a success.") }
        'Failed' { @('Failed', "A critical check failed: $($first -join ', '). Do not deliver this computer.") }
    }
}

# ------------------------------------------------------------------------------------------------
# Checklist, customer handoff, recovery actions
# ------------------------------------------------------------------------------------------------

function Get-WdhChecklist {
    param($C)
    $fs = $C.Findings.ToArray()
    $item = {
        param([string] $Id, [string] $Label, [string[]] $Patterns, [string] $Note = '')
        $m = @($fs | Where-Object { $f = $_; @($Patterns | Where-Object { $f.id -like $_ }).Count })
        $counted = @($m | Where-Object { $_.status -ne 'NotApplicable' })
        $state = $(if (-not $counted.Count) { 'notApplicable' }
                    elseif (@($counted | Where-Object { $_.status -in 'Fail', 'Unverifiable' -or ($_.status -eq 'Deferred') }).Count) { 'notDone' }
                    elseif (@($counted | Where-Object { $_.status -eq 'Pending' }).Count) { 'pending' }
                    elseif (@($counted | Where-Object { $_.status -eq 'Warning' -and $_.required }).Count) { 'notDone' }
                    else { 'done' })
        $notes = @($counted | Where-Object { $_.status -notin 'Pass', 'Info' } | Select-Object -First 3 | ForEach-Object { "$($_.title): $($_.observed)" })
        [ordered]@{ id = $Id; label = $Label; state = $state; note = $(if ($Note) { $Note } else { $notes -join ' | ' }); findingIds = @($m | ForEach-Object { $_.id }) }
    }
    $list = @(
        (& $item 'windows' "Windows installed ($(if ($C.Config['windows']['editionName']) { $C.Config['windows']['editionName'] } else { 'edition chosen during setup' }))" @('windows.edition', 'windows.version', 'windows.setup', 'windows.architecture', 'windows.productType'))
        (& $item 'account' 'Expected account present, with the intended rights' @('account.*'))
        (& $item 'computerName' 'Computer name correct' @('identity.computerName'))
    )
    $act = & $item 'activation' 'Windows activated, or activation pending clearly identified' @('windows.activation')
    $actF = @($fs | Where-Object { $_.id -eq 'windows.activation' }) | Select-Object -First 1
    if ($actF -and $actF.status -ne 'Pass') { $act.state = 'pending'; $act.note = [string] $actF.observed }
    $list += $act
    $list += & $item 'updates' 'Windows Update completed as required' @('updates.*')
    $list += & $item 'drivers' 'Hardware drivers healthy' @('drivers.*')
    $list += & $item 'apps' 'Selected applications verified' @('app.*', 'apps.*')
    if (@($fs | Where-Object { $_.id -eq 'office.install' }).Count) { $list += & $item 'office' 'Microsoft Office installed and verified (activation as recorded)' @('office.*') }
    $list += & $item 'restoration' 'Settings restoration completed' @('restore.*')
    $list += & $item 'security' 'Security protections checked' @('security.antivirus', 'security.firewall', 'security.uac', 'security.smartScreen')
    $list += & $item 'network' 'Network functional where required' @('network.*')
    $list += & $item 'restart' 'No required restart pending' @('windows.restart', 'drivers.restart.*')
    $list += [ordered]@{ id = 'recoveryInfo'; label = 'Backup and recovery information available to the customer'; state = 'confirm'; note = $(if (@($fs | Where-Object { $_.id -eq 'security.recoveryKey' }).Count) { 'The system drive is encrypted: confirm where the recovery key is kept.' } else { 'Confirm by hand.' }); findingIds = @(@($fs | Where-Object { $_.id -eq 'security.recoveryKey' } | ForEach-Object { $_.id })) }
    $signIn = @(@(ConvertTo-WdhList $C.Config['applications']['items']) | Where-Object { $_['signIn'] } | ForEach-Object { [string] $_['name'] })
    $list += [ordered]@{ id = 'customerSignIn'; label = 'Customer sign-in tasks documented'; state = 'confirm'; note = $(if ($signIn.Count) { "Applications that need the customer's account: $($signIn -join ', ')." } else { 'Confirm by hand (accounts, e-mail, cloud storage).' }); findingIds = @() }
    return $list
}

function Get-WdhCustomerHandoff {
    param($C, [string] $Status, $Os)
    $ok = $Status -in 'Ready', 'ReadyWithWarnings'
    $headline = switch ($Status) {
        'Ready' { 'Your computer is set up and ready to use.' }
        'ReadyWithWarnings' { 'Your computer is ready to use. A few items need your attention.' }
        default { 'Setup is not finished yet. Your technician needs to complete the items below before this computer is ready.' }
    }
    $installed = @($C.Apps | Where-Object { $_.kind -ne 'manual' -and ($_.independent -eq 'Found' -or $_.result -in 'InstalledVerificationUncertain', 'WaitingForUserContext') } | ForEach-Object { $_.name })
    $manual = @($C.Apps | Where-Object { $_.kind -eq 'manual' -and $_.result -eq 'ManualInstallationRequired' } | ForEach-Object { $a = $_; $it = @(@(ConvertTo-WdhList $C.Config['applications']['items']) | Where-Object { ([string] $_['key']).ToLowerInvariant() -eq $a.key }) | Select-Object -First 1; [ordered]@{ name = $a.name; how = $(if ($it -and $it['instructions']) { [string] $it['instructions'] } else { 'Ask your technician.' }) } })
    $notYet = @($C.Apps | Where-Object { $_.kind -ne 'manual' -and $_.independent -ne 'Found' -and $_.result -notin 'InstalledVerificationUncertain', 'WaitingForUserContext', 'SkippedByUser' } | ForEach-Object { $_.name })
    $f = @{}; foreach ($x in $C.Findings) { $f[$x.id] = $x }
    $state = { param([string] $Id, [string] $On, [string] $Off) if (-not $f.ContainsKey($Id)) { 'Not checked' } elseif ($f[$Id].status -eq 'Pass') { $On } elseif ($f[$Id].status -in 'Unverifiable', 'Deferred') { 'Could not be checked' } else { $Off } }
    $security = @(
        [ordered]@{ label = 'Virus protection'; state = (& $state 'security.antivirus' 'On' 'Off - ask your technician') }
        [ordered]@{ label = 'Firewall'; state = (& $state 'security.firewall' 'On' 'Off - ask your technician') }
    )
    if ($f.ContainsKey('security.encryption')) { $security += [ordered]@{ label = 'Device encryption'; state = $(if ($f.ContainsKey('security.recoveryKey')) { "On $([char] 0x2014) keep your recovery key safe" } else { 'Off' }) } }
    # The Windows Update state (engine 2.1.0, or a later retry run) decides when it exists; otherwise the stage result.
    $uf = $(if ($f.ContainsKey('updates.state')) { $f['updates.state'] } elseif ($f.ContainsKey('updates.stage')) { $f['updates.stage'] } else { $null })
    $updates = $(if (-not $uf -or $uf.status -eq 'NotApplicable') { 'Windows installs updates automatically.' }
                 elseif ($uf.status -eq 'Pass' -or ($uf.id -eq 'updates.state' -and $uf.status -eq 'Info')) { 'Windows was updated during setup.' }
                 elseif ($uf.status -eq 'Pending') { 'Updates are still being installed.' }
                 elseif ($uf.id -eq 'updates.state' -and $uf.observed -like 'RestartRequired*') { 'Restart the computer once to finish installing updates.' }
                 else { 'Some updates still need to be installed (your technician will finish this).' })
    $actions = @()
    if ($f.ContainsKey('windows.activation') -and $f['windows.activation'].status -ne 'Pass') { $actions += 'Activate Windows (Settings > System > Activation).' }
    if ((@($C.Findings | Where-Object { $_.status -eq 'Pending' -and $_.id -in 'windows.restart', 'identity.computerName' })).Count) { $actions += 'Restart the computer once.' }
    foreach ($m in $manual) { $actions += "Install $($m.name): $($m.how)" }
    foreach ($a in @(@(ConvertTo-WdhList $C.Config['applications']['items']) | Where-Object { $_['signIn'] })) { $actions += "Sign in to $($a['name']) with your account." }
    if ($f.ContainsKey('security.recoveryKey')) { $actions += 'Keep your BitLocker recovery key safe (for example in your Microsoft account).' }
    $account = $(if ($C.Config['account']['mode'] -eq 'unattendedLocal') { [string] $C.Config['account']['username'] } else { '' })
    [ordered]@{
        format = 'windows-deployment-builder/customer-handoff'; schemaVersion = 1; generatedUtc = (Get-WdhTime).ToString('o')
        computerName = [string] $Os.computerName; windows = $(if ($Os.caption) { ([string] $Os.caption) -replace '^Microsoft\s+', '' } else { 'Windows' })
        status = $Status; headline = $headline
        statusText = $(if ($ok) { 'Windows, updates, drivers, applications and security protection were checked on this computer.' } else { 'Some checks did not pass yet, so this summary does not say that everything is working.' })
        account = $account
        applications = [ordered]@{ installed = @($installed); toDoYourself = @($manual); notYet = @($notYet) }
        security = $security; updates = $updates; actions = @($actions | Select-Object -Unique); notes = [string] $C.Config['customerNotes']
    }
}

function Get-WdhRecoveryActions {
    param($C)
    $tool = Join-Path $C.Paths.Package 'scripts\recovery\DeploymentRecovery.ps1'
    $me = Join-Path $C.Paths.Package 'scripts\health\DeploymentHealth.ps1'
    $has = Test-Path -LiteralPath $tool
    $ps = 'powershell.exe -ExecutionPolicy Bypass -File'
    $a = @([ordered]@{ id = 'verify'; label = 'Verify again'; command = "$ps `"$me`""; sideEffects = $false }
           [ordered]@{ id = 'scanUpdates'; label = 'Recheck Windows Update (live scan)'; command = "$ps `"$me`" -ScanUpdates"; sideEffects = $false }
           [ordered]@{ id = 'checkAppUpdates'; label = 'Check for application updates (WinGet list, run as the deployment user)'; command = "$ps `"$me`" -CheckAppUpdates"; sideEffects = $false })
    if ($has) {
        $a += [ordered]@{ id = 'recovery'; label = 'Open Deployment recovery'; command = "$ps `"$tool`""; sideEffects = $false }
        if (Test-Path -LiteralPath (Join-Path $C.Paths.Package 'scripts\applications\ApplicationEngine.ps1')) { $a += [ordered]@{ id = 'ReverifyApplications'; label = 'Reverify applications (installs nothing)'; command = "$ps `"$tool`" -Action ReverifyApplications"; sideEffects = $false } }
        $a += [ordered]@{ id = 'RetryFailed'; label = 'Retry failed operations'; command = "$ps `"$tool`" -Action RetryFailed"; sideEffects = $true }
        $a += [ordered]@{ id = 'Resume'; label = 'Resume provisioning'; command = "$ps `"$tool`" -Action Resume"; sideEffects = $true }
        if ($C.Config['restoration']['required']) { $a += [ordered]@{ id = 'RestoreSettings'; label = 'Retry settings restoration'; command = "$ps `"$tool`" -Action RestoreSettings -BackupPath <backup folder>"; sideEffects = $true } }
        if ($C.Config['drivers']['enabled']) { $a += [ordered]@{ id = 'AddDrivers'; label = 'Provide a verified driver package'; command = "$ps `"$tool`" -Action AddDrivers -DriverPath <folder>"; sideEffects = $true } }
        $a += [ordered]@{ id = 'ExportDiagnostics'; label = 'Export diagnostics'; command = "$ps `"$me`" -Mode ExportDiagnostics"; sideEffects = $false }
    }
    @{ toolAvailable = $has; actions = $a }
}

function Get-WdhOutstanding {
    param($C)
    $out = @()
    foreach ($a in $C.Apps) {
        if ($a.result -in 'InstalledVerified', 'AlreadyInstalledVerified', 'InstalledManually', 'SkippedByUser', 'InstalledVersionDiffers') { continue }
        $f = @($C.Findings | Where-Object { $_.id -eq $a.findingId }) | Select-Object -First 1
        if (-not $f -or $f.status -in 'Pass', 'Info', 'NotApplicable') { continue }
        $out += , [ordered]@{ operationId = $(if ($a.kind -eq 'additional' -or $a.key -like 'additional:*') { "additional:$($a.key.Substring(11))" } else { "app:$($a.key)" }); name = $a.name; lifecycle = $(if ($a.lifecycle) { $a.lifecycle } else { $a.result }); action = [string] $f.nextAction; retryable = ($f.recoveryAction -eq 'RetryFailed') }
    }
    foreach ($s in @($C.Snapshot.stages)) { if ($s.state -ne 'Final') { $out += , [ordered]@{ operationId = "stage:$($s.id)"; name = [string] $s.name; lifecycle = [string] $s.state; action = 'resume'; retryable = $true } } }
    return $out
}

# ------------------------------------------------------------------------------------------------
# Writing the reports, history and comparison
# ------------------------------------------------------------------------------------------------

function Write-WdhText { param([string] $Path, [string] $Text) $dir = Split-Path -Parent $Path; if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }; [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false))) }

function ConvertTo-WdhHtml {
    param([string] $Template, $Data)
    $json = ($Data | ConvertTo-Json -Depth 12 -Compress)
    $json = $json.Replace('<', '\u003c').Replace('>', '\u003e').Replace('&', '\u0026')
    return $Template.Replace('__WDB_HEALTH_DATA__', $json)
}

function Get-WdhProblemIds { param($Report) @(@(ConvertTo-WdhList $Report['findings']) | Where-Object { $_ -is [System.Collections.IDictionary] -and [string] $_['status'] -notin 'Pass', 'Info', 'NotApplicable' } | ForEach-Object { [string] $_['id'] }) }

function Save-WdhHistory {
    param($C, [string] $Dir, [string] $Current)
    $hist = Join-Path $Dir 'history'
    $prev = $null
    if (Test-Path -LiteralPath $Current) {
        $prev = Read-WddJson $Current
        if (-not (Test-Path -LiteralPath $hist)) { New-Item -ItemType Directory -Path $hist -Force | Out-Null }
        $stamp = $(if ($prev -and $prev['generatedUtc']) { (ConvertTo-WddDate $prev['generatedUtc']).ToString('yyyyMMdd-HHmmss') } else { (Get-WdhTime).ToString('yyyyMMdd-HHmmss') })
        $name = "deployment-health-$stamp-$(if ($prev -and $prev['overall'] -is [hashtable]) { [string] $prev['overall']['status'] } else { 'Unknown' }).json"
        $target = Join-Path $hist $name
        $n = 1
        while (Test-Path -LiteralPath $target) { $n++; $target = Join-Path $hist ($name -replace '\.json$', "-$n.json") }
        Move-Item -LiteralPath $Current -Destination $target
    } elseif (Test-Path -LiteralPath $hist) {
        # A restart between archiving and writing leaves no current report: compare with the newest archived one.
        $last = @(Get-ChildItem -LiteralPath $hist -Filter 'deployment-health-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name) | Select-Object -Last 1
        if ($last) { $prev = Read-WddJson $last.FullName }
    }
    # Keep the first report ever (the original record) and the newest ones.
    $limit = [int] $C.Config['options']['historyLimit']
    if ($limit -lt 2) { $limit = 2 }
    $files = @(Get-ChildItem -LiteralPath $hist -Filter 'deployment-health-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($files.Count -gt $limit) { foreach ($f in $files[1..($files.Count - $limit)]) { Remove-Item -LiteralPath $f.FullName -Force } }
    $list = @(@(Get-ChildItem -LiteralPath $hist -Filter 'deployment-health-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name) | ForEach-Object {
        $m = [regex]::Match($_.Name, '^deployment-health-(\d{8})-(\d{6})-([A-Za-z]+)')
        [ordered]@{ file = "history\$($_.Name)"; generatedUtc = $(if ($m.Success) { [DateTime]::ParseExact($m.Groups[1].Value + $m.Groups[2].Value, 'yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture).ToString('yyyy-MM-ddTHH:mm:ssZ') } else { '' }); status = $(if ($m.Success) { $m.Groups[3].Value } else { '' }) }
    })
    return @{ Previous = $prev; History = $list }
}

function Get-WdhComparison {
    param($Previous, [object[]] $Findings)
    if (-not ($Previous -is [hashtable]) -or -not ($Previous['overall'] -is [hashtable])) { return $null }
    $before = @(Get-WdhProblemIds $Previous)
    $now = @($Findings | Where-Object { $_.status -notin 'Pass', 'Info', 'NotApplicable' } | ForEach-Object { $_.id })
    [ordered]@{
        previousStatus = [string] $Previous['overall']['status']; previousUtc = [string] $Previous['generatedUtc']; previousVerificationId = [string] $Previous['verificationId']
        resolved = @($before | Where-Object { $_ -notin $now }); new = @($now | Where-Object { $_ -notin $before }); remaining = @($now | Where-Object { $_ -in $before })
    }
}

# ------------------------------------------------------------------------------------------------
# Verify
# ------------------------------------------------------------------------------------------------

function New-WdhContext {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $Config, [switch] $ScanUpdates, [switch] $CheckAppUpdates)
    $read = Read-WddDeploymentState $Paths
    $identity = Get-WddIdentity
    $snap = $(if ($read.State) { Get-WddSnapshot $Manifest $Paths $read.State } else { [ordered]@{ stages = @(); allFinal = $false; outcome = 'FailedToInitialize'; outcomeCode = 50; outcomeDetail = ''; restartPending = $false } })
    $user = ''
    if ($read.State -and $read.State['stages'] -is [hashtable] -and $read.State['stages'].ContainsKey('applications') -and $read.State['stages']['applications'] -is [hashtable]) { $user = [string] $read.State['stages']['applications']['user'] }
    if (-not $user -and $read.State) { $user = [string] $read.State['initializedBy'] }
    if (-not $user -and $Config['account']['username']) { $user = "$($env:COMPUTERNAME)\$($Config['account']['username'])" }
    $sid = Resolve-WdhSid $user
    $hive = $(if ($sid) { [bool] (Test-WdhUserHive $sid) } else { $false })
    @{
        Manifest = $Manifest; Paths = $Paths; Config = $Config; StateRead = $read; Snapshot = $snap; Identity = $identity
        DeploymentUser = $(if ($user) { $user } else { 'the deployment user' }); DeploymentSid = $sid; HiveLoaded = $hive
        SameUser = $(if ($identity.IsSystem -or -not $user) { $null } else { $identity.Name -ieq $user })
        ScanUpdates = [bool] $ScanUpdates; CheckAppUpdates = [bool] $CheckAppUpdates
        Findings = New-Object System.Collections.Generic.List[object]; Sources = New-Object System.Collections.Generic.List[object]
        Apps = New-Object System.Collections.Generic.List[object]; Manual = New-Object System.Collections.Generic.List[object]; Custom = New-Object System.Collections.Generic.List[object]
        Limitations = New-Object System.Collections.Generic.List[string]; Obs = @{}; Backups = [ordered]@{ retained = 0; bytes = 0; location = ''; requiredForOutstanding = $false; cleanup = '' }
        # Engine 1.1.0 sections: Windows Update state and history, device comparison, Office, manufacturer software.
        WindowsUpdate = $null; UpdateResult = $null; Office = $null
        DeviceComparison = New-Object System.Collections.Generic.List[object]; HardwareSoftware = New-Object System.Collections.Generic.List[object]
        # Engine 1.2.0 sections: Visual C++ runtimes, and the optional WinGet update listing (-CheckAppUpdates).
        Runtimes = $null; AppUpdates = $null; AppxReadable = $true
    }
}

<# The technician report as plain text (technician-report.txt): the same findings, the new sections and their evidence. #>
function Format-WdhTextReport {
    param($Report)
    $l = New-Object System.Collections.Generic.List[string]
    $os = $Report['os']; $o = $Report['overall']
    $l.Add('Windows Deployment Builder - deployment health report (read-only)')
    $l.Add("Computer $($os['computerName']), $($os['caption']) $($os['displayVersion']) (build $($os['build']))")
    $l.Add("Verified $($Report['generatedUtc']) by $($Report['context']['runAs']) ($($Report['trigger'])); health engine $($Report['engineVersion']); verification $($Report['verificationId']); deployment $($Report['deploymentId'])")
    $l.Add('')
    $l.Add("OVERALL: $($o['status']) - $($o['title']). $($o['summary'])")
    $l.Add('')
    $l.Add('Categories')
    foreach ($k in @($Report['categories'])) { $l.Add(('  {0,-32} {1,-15} {2}' -f $k['name'], $k['status'], $k['summary'])) }
    $l.Add('')
    $todo = @(@($Report['findings']) | Where-Object { $_['status'] -notin 'Pass', 'Info', 'NotApplicable' })
    $l.Add("What needs attention ($($todo.Count))")
    foreach ($f in $todo) { $l.Add("  [$($f['status'])] $($f['title']): $($f['observed'])"); if ($f['nextAction']) { $l.Add("      Next: $($f['nextAction'])") } }
    $w = $Report['windowsUpdate']
    if ($w) {
        $l.Add('')
        $l.Add("Windows Update (checked $($w['checkedUtc']))")
        foreach ($pair in @(@('Deployment', $w['original']), @('Current', $w['current']))) {
            $v = $pair[1]
            if (-not $v) { continue }
            $l.Add("  $($pair[0]): $($v['label']); status $($v['status'])$(if ($v['updateState']) { ", state $($v['updateState'])" }); engine $(if ($v['engineVersion']) { $v['engineVersion'] } else { 'unknown' }); finished $($v['finishedUtc']); installed $($v['installed']), failed $($v['failed'])")
            if ($v['updateStateText']) { $l.Add("    $($v['updateStateText'])") }
            if ($v['summary']) { $l.Add('    Summary: ' + (@($v['summary'].Keys | ForEach-Object { "$_ $($v['summary'][$_])" }) -join ', ')) }
        }
        if ($w['policy']) { $p = $w['policy']; $l.Add("  Policy ($($p['source'])): feature updates $($p['featureUpdates']), optional updates $($p['optionalUpdates']), drivers $($p['drivers']), preview updates $(if ($null -eq $p['previewUpdates']) { 'not recorded' } elseif ($p['previewUpdates']) { 'included' } else { 'intentionally excluded' }) ($($p['previewSource']))") }
        if ($w['settingsRefresh']) { $s = $w['settingsRefresh']; $l.Add("  Final Settings refresh: available $($s['available']), requested $($s['requested']) $($s['requestedUtc']), completed $($s['completed']) $($s['completedUtc']); last successful scan $($s['lastSuccessfulScanBefore']) -> $($s['lastSuccessfulScanAfter']). The Settings page display is NOT verified.") }
        if ($w['orchestrator']) { $g = $w['orchestrator']; $l.Add("  Windows Update (Settings) last successful check: $(if ($g['available']) { if ($g['lastSuccessfulScanUtc']) { $g['lastSuccessfulScanUtc'] } else { 'none recorded' } } else { 'not available on this Windows' })") }
        foreach ($x in @($w['retries'])) { if ($x) { $l.Add("  Retry run $($x['runId']) ($($x['selection'])): $($x['state'])$(if ($x['final']) { " ($($x['final']))" }); installed $($x['installed']), failed $($x['failed']); engine $($x['engineVersion']); $($x['updateState'])") } }
        foreach ($x in @($w['originalFailures'])) { if ($x) { $l.Add("  Original failure: $(@($x['kbs']) -join ',') $($x['title']) ($($x['lastHResult']))$(if ($x['laterInstalled']) { " - installed later on $($x['installedUtc']) by $($x['installedBy'])" } else { ' - not installed since' })") } }
        foreach ($x in @($w['drivers'])) { if ($x) { $l.Add("  Driver via Windows Update: $($x['title']) $($x['model']) [$($x['result'])]") } }
        if ($w['liveScan']) { $s = $w['liveScan']; $l.Add("  Live scan (read-only): $(if ($s['performed']) { "$($s['required']) required, $($s['optional']) optional, $($s['drivers']) driver, $($s['feature']) feature update(s)" } else { 'not possible' })") }
    }
    if (@($Report['deviceComparison']).Count) {
        $l.Add('')
        $l.Add('Devices the deployment reported with problems, now')
        foreach ($d in @($Report['deviceComparison'])) { if ($d) { $l.Add("  $($d['state']): $($d['name']) (was code $($d['previousProblemCode']), now $(if ($null -eq $d['currentProblemCode']) { 'not present' } else { "code $($d['currentProblemCode'])" })); $(@($d['hardwareIds']) | Select-Object -First 1)") } }
        $l.Add('  Zero device problems is a hardware-health result, not proof that every optional driver was installed.')
    }
    if ($Report['office']) {
        $x = $Report['office']
        $l.Add('')
        $l.Add("Microsoft Office: $($x['displayName']) - $($x['result']); Click-to-Run $(if ($x['present']) { "$(@($x['productReleaseIds']) -join ', ') $($x['version']) $($x['platform'])" } else { 'not found' }); Office stage $($x['engineStatus'])")
        if ($x['activation']) { $l.Add("  Activation (as the activation stage recorded it): $($x['activation']['status'])$(if ($x['activation']['message']) { " - $($x['activation']['message'])" })") }
    }
    $l.Add('')
    $l.Add('Manufacturer software (optional recommendations; nothing is installed automatically)')
    if (-not @($Report['hardwareSoftware']).Count) { $l.Add('  None recommended for this hardware.') }
    foreach ($x in @($Report['hardwareSoftware'])) { if ($x) { $l.Add("  $($x['utility']): $($x['detectedHardware']); installed $(if ($null -eq $x['installed']) { 'unknown' } else { $x['installed'] }); $($x['url'])"); $l.Add("    $($x['compatibility']) $($x['signIn']) Automatic installation: no ($($x['automaticInstallReason']))") } }
    $l.Add('')
    $l.Add("Applications ($(@($Report['applications']).Count))")
    foreach ($a in @($Report['applications'])) {
        if (-not $a) { continue }
        $l.Add(('  {0,-36} {1,-38} engine: {2}{3}' -f $a['name'], $a['verification'], $(if ($a['engineStatus']) { $a['engineStatus'] } else { '-' }), $(if ($a['outcome']) { " ($($a['outcome']))" } else { '' })))
        foreach ($x in @(ConvertTo-WdhList $a['evidence'])) { $l.Add("      evidence: $($x['kind']) $($x['detail']) ($($x['where']))$(if ($x['version']) { " version $($x['version'])" })") }
        if (-not @(ConvertTo-WdhList $a['evidence']).Count -and $a['verificationNote'] -and $a['kind'] -ne 'manual') { $l.Add("      $($a['verificationNote'])") }
    }
    $rt = $Report['runtimes']
    if ($rt) {
        $l.Add('')
        $l.Add("Visual C++ runtimes ($($rt['source']))")
        if (-not @($rt['items']).Count) { $l.Add('  None found.') }
        foreach ($x in @($rt['items'])) { if ($x) { $l.Add(('  {0,-6} {1,-6} {2,-16} {3}' -f $x['family'], $x['architecture'], $x['version'], $x['displayName'])) } }
        foreach ($x in @($rt['selected'])) { if ($x) { $l.Add("  Selected by this deployment: $($x['family']) $($x['architecture']) - $(if ($x['present']) { "present ($($x['version']))" } else { 'MISSING' })") } }
        foreach ($x in @($rt['notes'])) { if ($x) { $l.Add("  $x") } }
    }
    $au = $Report['appUpdates']
    if ($au) {
        $l.Add('')
        $l.Add("Application updates (WinGet, read-only; $($au['status']), as $($au['runAs']), $($au['checkedUtc']))")
        foreach ($x in @($au['items'])) { if ($x) { $l.Add("  $($x['name']) ($($x['id'])): $($x['installed']) -> $($x['available'])") } }
        if ($au['status'] -eq 'ok' -and -not @($au['items']).Count) { $l.Add('  No update listed for the selected applications.') }
        if ($au['note']) { $l.Add("  $($au['note'])") }
    }
    $l.Add('')
    $l.Add('Limitations')
    foreach ($x in @($Report['limitations'])) { $l.Add("  - $x") }
    $l.Add('')
    $l.Add('Machine-readable: deployment-health.json in this folder. Verification never changes this computer.')
    return ($l -join "`r`n") + "`r`n"
}

<#
    Verifies the deployment and writes the reports. Returns @{ Status; ExitCode; Report; Paths }.
    Nothing outside <dataRoot>\reports\health is written.
#>
function Invoke-WdhVerify {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $Config, [string] $Trigger = 'Technician', [switch] $ScanUpdates, [switch] $CheckAppUpdates)
    $script:WdhNow = Get-WddNow
    $C = New-WdhContext $Manifest $Paths $Config -ScanUpdates:$ScanUpdates -CheckAppUpdates:$CheckAppUpdates
    foreach ($t in 'Test-WdhDeployment', 'Test-WdhWindows', 'Test-WdhAccounts', 'Test-WdhUpdates', 'Test-WdhApplications', 'Test-WdhRuntimes', 'Test-WdhAppUpdates', 'Test-WdhOffice', 'Test-WdhRestoration', 'Test-WdhDrivers', 'Test-WdhManufacturerSoftware', 'Test-WdhSecurity', 'Test-WdhNetwork', 'Test-WdhStorage', 'Test-WdhCustomizations') {
        try { & $t $C } catch {
            $cat = @{ 'Test-WdhDeployment' = 'recovery'; 'Test-WdhWindows' = 'windows'; 'Test-WdhAccounts' = 'accounts'; 'Test-WdhUpdates' = 'updates'; 'Test-WdhApplications' = 'applications'; 'Test-WdhRuntimes' = 'applications'; 'Test-WdhAppUpdates' = 'applications'; 'Test-WdhOffice' = 'applications'; 'Test-WdhRestoration' = 'restoration'; 'Test-WdhDrivers' = 'drivers'; 'Test-WdhManufacturerSoftware' = 'hardwareSoftware'; 'Test-WdhSecurity' = 'security'; 'Test-WdhNetwork' = 'network'; 'Test-WdhStorage' = 'storage'; 'Test-WdhCustomizations' = 'customizations' }[$t]
            $req = $t -notin 'Test-WdhManufacturerSoftware', 'Test-WdhRuntimes', 'Test-WdhAppUpdates'
            # Manufacturer software is a recommendation: its failure never affects the overall state beyond "Info".
            if (-not $req) { Add-WdhFinding $C "$cat$(@{ 'Test-WdhRuntimes' = '.runtimes'; 'Test-WdhAppUpdates' = '.updates' }[$t]).checkError" $cat "$($script:WdhCategoryNames[$cat]) check" 'Info' 'Informational' 'The check completes' "The check stopped: $($_.Exception.Message)" $t 'DeploymentHealth.ps1' -Required $false -TechnicianRequired $false | Out-Null; continue }
            Add-WdhFinding $C "$cat$(if ($t -eq 'Test-WdhOffice') { '.office' }).checkError" $cat "$($script:WdhCategoryNames[$cat]) check" 'Unverifiable' 'Error' 'The check completes' "The check stopped: $($_.Exception.Message)" $t 'DeploymentHealth.ps1' 'Run the check again; report this message if it repeats.' | Out-Null
        }
    }
    # ToArray: @() on a generic List can fail in Windows PowerShell 5.1 ("Argument types do not match").
    $findings = $C.Findings.ToArray()
    # Stable ids: a duplicate id would make reverification ambiguous.
    $seen = @{}
    foreach ($f in $findings) { if ($seen.ContainsKey($f.id)) { $n = 2; while ($seen.ContainsKey("$($f.id)-$n")) { $n++ }; $f.id = "$($f.id)-$n" }; $seen[$f.id] = $true }
    $status = Get-WdhOverall $findings
    $text = Get-WdhOverallText $status $findings
    $os = $(if ($C.Obs['os']) { $C.Obs['os'] } else { @{ caption = ''; editionId = ''; displayVersion = ''; build = 0; ubr = 0; architecture = ''; productType = 0 } })
    $names = $C.Obs['computerName']
    $osBlock = [ordered]@{ computerName = $(if ($names -and $names.active) { [string] $names.active } else { [string] $env:COMPUTERNAME }); caption = [string] $os.caption; editionId = [string] $os.editionId; displayVersion = [string] $os.displayVersion; build = $(if ($os.build) { "$($os.build).$($os.ubr)" } else { '' }); architecture = [string] $os.architecture; productType = [int] $os.productType }
    $dir = Join-Path $Paths.Root ([string] $Config['reportDir'])
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $current = Join-Path $dir 'deployment-health.json'
    $h = Save-WdhHistory $C $dir $current
    $limitations = @($C.Limitations | Select-Object -Unique)
    $limitations += 'Verification is read-only and tested with simulated computers; physical validation on real hardware is outstanding.'
    $limitations += 'Applications are verified with the evidence their catalog entry names (uninstall records, Store packages, files, registry values) and by name; an installer that leaves no evidence is reported as unverified, never as missing on that basis alone, and per-user evidence that cannot be read now as pending.'
    if (-not $C.CheckAppUpdates) { $limitations += 'Application updates were not listed (run with -CheckAppUpdates as the deployment user for a read-only WinGet listing).' }
    $report = [ordered]@{
        format = 'windows-deployment-builder/deployment-health'; schemaVersion = 1; engineVersion = $script:WdhVersion
        verificationId = ([guid]::NewGuid().ToString('N')).Substring(0, 16); deploymentId = [string] $Manifest.packageId; generatedUtc = $script:WdhNow.ToString('o'); trigger = $Trigger; readOnly = $true
        context = [ordered]@{ runAs = $(if ($C.Identity.IsSystem) { 'SYSTEM' } else { [string] $C.Identity.Name }); deploymentUser = [string] $C.DeploymentUser; sameUser = $C.SameUser
                              userContext = $(if (-not @(@(ConvertTo-WdhList $Config['applications']['items']) + @(ConvertTo-WdhList $Config['customizations'])).Count) { 'NotNeeded' } elseif ($C.HiveLoaded) { 'Available' } else { 'Deferred' }) }
        os = $osBlock
        overall = [ordered]@{ status = $status; title = $text[0]; summary = $text[1]; readyForDelivery = ($status -in 'Ready', 'ReadyWithWarnings'); exitCode = $script:WdhExitCodes[$status] }
        categories = @(Get-WdhCategories $C)
        findings = $findings
        applications = $C.Apps.ToArray()
        outstanding = @(Get-WdhOutstanding $C)
        manualActions = @($C.Manual | Group-Object { $_.id } | ForEach-Object { $_.Group[0] })
        checklist = @(Get-WdhChecklist $C)
        recovery = (Get-WdhRecoveryActions $C)
        backups = $C.Backups
        customizations = $C.Custom.ToArray()
        sources = $C.Sources.ToArray()
        limitations = @($limitations)
        comparison = (Get-WdhComparison $h.Previous $findings)
        history = @($h.History)
        # Engine 1.1.0 sections (each with its own timestamps, versions and evidence).
        windowsUpdate = $C.WindowsUpdate
        deviceComparison = $C.DeviceComparison.ToArray()
        office = $C.Office
        hardwareSoftware = $C.HardwareSoftware.ToArray()
        # Engine 1.2.0 sections.
        runtimes = $C.Runtimes
        appUpdates = $C.AppUpdates
    }
    Write-WddJson $current $report
    # The template beside this script first: a newer audit (for example from a recovery download) run on a
    # computer deployed with an older package must not render its report with that package's older template.
    $template = Join-Path $script:WdhScriptRoot 'HealthReport.html'
    if (-not (Test-Path -LiteralPath $template)) { $template = Join-Path $Paths.Package 'scripts\health\HealthReport.html' }
    if ($Config['options']['technicianReport']) { Write-WdhText (Join-Path $dir 'technician-report.txt') (Format-WdhTextReport $report) }
    if (Test-Path -LiteralPath $template) {
        $tpl = [IO.File]::ReadAllText($template, [Text.Encoding]::UTF8)
        if ($Config['options']['technicianReport']) { Write-WdhText (Join-Path $dir 'technician-report.html') (ConvertTo-WdhHtml $tpl ([ordered]@{ mode = 'technician'; report = $report })) }
        if ($Config['options']['customerReport']) {
            $handoff = Get-WdhCustomerHandoff $C $status $osBlock
            Write-WddJson (Join-Path $dir 'customer-handoff.json') $handoff
            Write-WdhText (Join-Path $dir 'customer-handoff.html') (ConvertTo-WdhHtml $tpl ([ordered]@{ mode = 'customer'; handoff = $handoff }))
        }
    } else { Write-WddLog 'Health report template missing; only deployment-health.json was written.' 'WARN' }
    $eventId = @{ Ready = 5000; ReadyWithWarnings = 5001; NeedsAttention = 5002; Incomplete = 5003; Unverifiable = 5004; Failed = 5005 }[$status]
    if ($Trigger -ne 'Test') { Write-WddEvent $eventId "Deployment $($Manifest.packageId) verified: $status. $($text[1]) Report: $current" $(if ($status -in 'Ready', 'ReadyWithWarnings') { 'Information' } elseif ($status -eq 'Failed') { 'Error' } else { 'Warning' }) }
    Write-WddLog "Health verification ($Trigger): $status. $($findings.Count) finding(s). Report: $current"
    return @{ Status = $status; ExitCode = $script:WdhExitCodes[$status]; Report = $report; Path = $current; Directory = $dir }
}

<#
    Called by Complete-Deployment.ps1 when the deployment ends: verifies (read-only), and when a
    restart is pending registers a startup re-check that removes itself afterwards.
#>
function Invoke-WdhAfterDeployment {
    param([hashtable] $Manifest, [hashtable] $Paths)
    # The verified staged copy of the plan (the monitor checked the package before calling this).
    $cfgPath = Join-Path $Paths.Package 'scripts\health\health-config.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) { $cfgPath = Join-Path $script:WdhScriptRoot 'health-config.json' }
    $cfg = Read-WddJson $cfgPath
    if (-not $cfg) { Write-WddLog "Health verification skipped: $cfgPath is missing or unreadable." 'WARN'; return $null }
    $r = Invoke-WdhVerify $Manifest $Paths $cfg 'DeploymentComplete'
    $restart = @($r.Report.findings | Where-Object { $_.status -eq 'Pending' -and ($_.id -eq 'windows.restart' -or $_.id -like 'drivers.restart.*' -or $_.id -eq 'identity.computerName') }).Count -gt 0
    if ($restart) {
        try { Register-WdhRecheckTask (Join-Path $script:WdhScriptRoot 'DeploymentHealth.ps1'); Write-WdhRecheckState $Paths $cfg 0 } catch { Write-WddLog "Could not register the health re-check after restart: $($_.Exception.Message)" 'WARN' }
    }
    return $r
}

function Write-WdhRecheckState { param([hashtable] $Paths, $Config, [int] $Runs) Write-WddJson (Join-Path (Join-Path $Paths.Root ([string] $Config['reportDir'])) 'recheck.json') ([ordered]@{ runs = $Runs; updatedUtc = (Get-WddNow).ToString('o') }) }

<# Startup re-check: verifies again; removes its task once no restart is pending, or after the configured number of runs. #>
function Invoke-WdhStartupRecheck {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $Config)
    $statePath = Join-Path (Join-Path $Paths.Root ([string] $Config['reportDir'])) 'recheck.json'
    $s = Read-WddJson $statePath
    $runs = $(if ($s) { [int] $s['runs'] } else { 0 }) + 1
    $r = Invoke-WdhVerify $Manifest $Paths $Config 'Startup'
    $restart = @($r.Report.findings | Where-Object { $_.status -eq 'Pending' -and ($_.id -eq 'windows.restart' -or $_.id -like 'drivers.restart.*' -or $_.id -eq 'identity.computerName') }).Count -gt 0
    Write-WdhRecheckState $Paths $Config $runs
    if (-not $restart -or $runs -ge [int] $Config['options']['startupRechecks']) { try { Unregister-WdhRecheckTask } catch { } }
    return $r
}

# ------------------------------------------------------------------------------------------------
# Separately confirmed cleanup of the retained settings backup, and diagnostics
# ------------------------------------------------------------------------------------------------

function Invoke-WdhCleanupBackups {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $Config, [string] $Confirm = '')
    $identity = Get-WddIdentity
    if (-not $identity.IsAdmin) { return @{ Outcome = 'NotElevated'; Message = 'Run as administrator.'; Removed = @() } }
    $plan = $Config['restoration']
    $folders = @(ConvertTo-WdhList (Get-WdhBackupFolders $Paths.Root))
    if (-not $folders.Count) { return @{ Outcome = 'NothingToDo'; Message = 'No retained settings backup on this computer.'; Removed = @() } }
    # Never while a restoration is outstanding: the backup is still needed.
    $r = Read-WddJson (Join-Path $Paths.Root 'Applications\restoration.json')
    $open = @()
    if ($plan['required']) {
        if (-not $r) { $open += 'no restoration result yet' }
        else { foreach ($s in @(ConvertTo-WdhList $r['settings'])) { if ([string] $s['outcome'] -notin 'ConfigurationRestored', 'KeptExisting', 'ConfigurationPartiallyRestored', 'Unsupported', 'SkippedByUser', 'ManualActionRequired') { $open += "$($s['name']) ($($s['outcome']))" } } }
    }
    $total = 0; foreach ($f in $folders) { $total += [double] $f.bytes }
    $list = "$($folders.Count) folder(s), $(Format-WdhBytes $total) below $(Join-Path $Paths.Root 'Backup')"
    if ($open.Count) { return @{ Outcome = 'Refused'; Message = "The backup is still needed for outstanding restoration: $($open -join ', '). Nothing was removed."; Removed = @() } }
    $id = [string] $plan['backupId']
    if (-not $Confirm -or ($id -and $Confirm -ne $id) -or (-not $id -and $Confirm -ne 'REMOVE')) {
        return @{ Outcome = 'ConfirmationRequired'; Message = "Retained: $list. To remove it (the USB or source copy is never touched), run again with -ConfirmCleanup $(if ($id) { $id } else { 'REMOVE' })."; Removed = @() }
    }
    $root = [IO.Path]::GetFullPath((Join-Path $Paths.Root 'Backup')).TrimEnd('\') + '\'
    $removed = @()
    foreach ($f in $folders) {
        $full = [IO.Path]::GetFullPath($f.path)
        $item = Get-Item -LiteralPath $full -Force
        if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        Remove-Item -LiteralPath $full -Recurse -Force
        $removed += $f.name
    }
    Write-WddLog "Retained settings backup removed by $($identity.Name) after confirmation: $($removed -join ', ')." 'WARN'
    Write-WddEvent 5010 "Retained settings backup removed by $($identity.Name): $($removed -join ', ')." 'Information'
    return @{ Outcome = 'Done'; Message = "Removed $($removed.Count) staged backup folder(s). The original backup on your drive was not touched."; Removed = $removed }
}

<# Entries of a diagnostics ZIP that may be shared: relative paths, known text types, never a backup or an answer file. #>
function Test-WdhArchiveEntry {
    param([string] $Name)
    $n = $Name.Replace('\', '/')
    if (-not $n -or $n.StartsWith('/') -or $n -match '(^|/)\.\.(/|$)' -or $n -match ':' -or $n.Length -gt 240) { return $false }
    if ($n -match '(?i)(^|/)(backup|backups)(/|$)' -or $n -match '(?i)(unattend|autounattend)\.xml$' -or $n -match '(?i)\.(xml|wim|exe|msi|zip|reg|pfx|key)$') { return $false }
    return $n -match '(?i)\.(json|jsonl|txt|log|1|done|bak|corrupt[-0-9]*)$' -or $n -match '(?i)\.json\.(bak|corrupt)'
}

function Test-WdhArchive {
    param([string] $Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($Path)
    try { return @(@($z.Entries) | Where-Object { -not (Test-WdhArchiveEntry $_.FullName) } | ForEach-Object { $_.FullName }) } finally { $z.Dispose() }
}

function Invoke-WdhExport {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $Config, [string] $OutputPath = '')
    $stamp = (Get-WddNow).ToString('yyyyMMdd-HHmmss')
    if (-not $OutputPath) { $OutputPath = Join-Path $Paths.Reports ("deployment-diagnostics-{0}-{1}.zip" -f $env:COMPUTERNAME, $stamp) }
    if ($OutputPath -notmatch '\.zip$') { return @{ Outcome = 'Refused'; Message = 'The diagnostics file must end in .zip.'; Path = '' } }
    $tool = Join-Path $Paths.Package 'scripts\recovery\DeploymentRecovery.ps1'
    if (Test-Path -LiteralPath $tool) {
        $x = Invoke-WdhRecoveryExport $tool $OutputPath
        if ($x.exit -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) { return @{ Outcome = 'Failed'; Message = "The recovery tool could not export diagnostics: $($x.text)"; Path = '' } }
    } else {
        # Without the recovery tool: the health reports only (written by this engine, no secrets).
        $staging = Join-Path ([IO.Path]::GetTempPath()) ('wdh-diag-' + [guid]::NewGuid().ToString('N'))
        try {
            $dir = Join-Path $Paths.Root ([string] $Config['reportDir'])
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue)) {
                $rel = $f.FullName.Substring($Paths.Root.TrimEnd('\').Length + 1)
                $t = Join-Path $staging $rel
                New-Item -ItemType Directory -Path (Split-Path -Parent $t) -Force | Out-Null
                Copy-Item -LiteralPath $f.FullName -Destination $t
            }
            if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::CreateFromDirectory($staging, $OutputPath)
        } finally { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $bad = @(Test-WdhArchive $OutputPath)
    if ($bad.Count) { Remove-Item -LiteralPath $OutputPath -Force; return @{ Outcome = 'Refused'; Message = "The archive contained entries that must not be shared ($($bad -join ', ')); it was deleted."; Path = '' } }
    return @{ Outcome = 'Done'; Message = "Diagnostics: $OutputPath (sanitized; no backups, answer files or passwords). Nothing was sent anywhere."; Path = $OutputPath }
}

# ------------------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------------------

if ($script:WdhMain) {
    $a = $script:WdhArgs
    $package = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    # Run from a standalone download (no manifest beside it): verify the deployment staged on this computer.
    $staged = Join-Path $env:ProgramData 'WindowsDeploymentBuilder\Package'
    if (-not (Test-Path -LiteralPath (Join-Path $package 'deployment-manifest.json')) -and (Test-Path -LiteralPath (Join-Path $staged 'deployment-manifest.json'))) { $package = $staged }
    try { $manifest = Read-WddManifest (Join-Path $package 'deployment-manifest.json') } catch { Write-Output "Unverifiable: $($_.Exception.Message)"; exit 50 }
    # The plan beside this script, else the staged package's (older packages lack the newer, optional sections).
    $cfgPath = Join-Path $PSScriptRoot 'health-config.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) { $cfgPath = Join-Path $package 'scripts\health\health-config.json' }
    $config = Read-WddJson $cfgPath
    if (-not $config) { Write-Output 'Unverifiable: health-config.json is missing or damaged.'; exit 50 }
    $paths = Get-WddPaths $manifest.dataRoot
    $id = Get-WddIdentity
    if ($a.Elevate -and -not $id.IsAdmin) {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $ps -Verb RunAs -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Mode', $a.Mode) + @(if ($a.ScanUpdates) { '-ScanUpdates' }) + @(if ($a.CheckAppUpdates) { '-CheckAppUpdates' }))
        exit 0
    }
    if (-not $id.IsAdmin -and $a.Mode -in 'Verify', 'Dashboard') { Write-Output 'Note: not running as administrator; some checks (accounts, encryption, Store packages) may be reported as not verifiable.' }
    try { Initialize-WddLogging $paths } catch { }
    switch ($a.Mode) {
        'CleanupBackups' { $r = Invoke-WdhCleanupBackups $manifest $paths $config $a.ConfirmCleanup; Write-Output "CleanupBackups: $($r.Outcome). $($r.Message)"; exit $(if ($r.Outcome -eq 'Done') { 0 } elseif ($r.Outcome -eq 'NotElevated') { 4 } else { 1 }) }
        'ExportDiagnostics' { $r = Invoke-WdhExport $manifest $paths $config $a.OutputPath; Write-Output "ExportDiagnostics: $($r.Outcome). $($r.Message)"; exit $(if ($r.Outcome -eq 'Done') { 0 } else { 1 }) }
        default {
            $r = $(if ($a.Trigger -eq 'Startup') { Invoke-WdhStartupRecheck $manifest $paths $config } else { Invoke-WdhVerify $manifest $paths $config $a.Trigger -ScanUpdates:$a.ScanUpdates -CheckAppUpdates:$a.CheckAppUpdates })
            if ($a.Json) { $r.Report | ConvertTo-Json -Depth 12 } else {
                Write-Output "Deployment health: $($r.Status) - $($r.Report.overall.summary)"
                foreach ($k in $r.Report.categories) { Write-Output ('  {0,-32} {1}' -f $k.name, $k.status) }
                Write-Output "Report: $(Join-Path $r.Directory 'technician-report.html')"
            }
            if ($a.Mode -eq 'Dashboard') { try { Open-WdhReport (Join-Path $r.Directory 'technician-report.html') } catch { Write-Output "Open the report by hand: $($_.Exception.Message)" } }
            exit $r.ExitCode
        }
    }
}
