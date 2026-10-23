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
        customer-handoff.html    plain summary for the person receiving the computer
        history\                 earlier reports (the record of a failed deployment is never lost)

      -Mode Verify            (default) verify and write the reports; exit code = overall state
      -Mode Dashboard         verify, then open the technician report
      -Mode CleanupBackups    list the retained settings backup; with -ConfirmCleanup <backup id>
                              remove it (only when no restoration is outstanding; never the USB copy)
      -Mode ExportDiagnostics a sanitized ZIP (no backups, no answer files, no passwords)
      -ScanUpdates            also ask Windows Update which updates are still available (read-only)

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
    [switch] $Json,
    [string] $ConfirmCleanup = '',
    [string] $OutputPath = '',
    [switch] $Elevate
)

$script:WdhMain = $MyInvocation.InvocationName -ne '.' -and $Mode -ne 'Library'
# Captured first: the shared functions dot-sourced below bind their own parameters in this scope.
$script:WdhArgs = @{ Mode = $Mode; Trigger = $Trigger; ScanUpdates = [bool] $ScanUpdates; Json = [bool] $Json; ConfirmCleanup = $ConfirmCleanup; OutputPath = $OutputPath; Elevate = [bool] $Elevate }
if (-not (Get-Command Read-WddManifest -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot '..\common\DeploymentCommon.ps1') }
Set-StrictMode -Version 2.0

$script:WdhVersion = '1.0.0'
$script:WdhScriptRoot = $PSScriptRoot
$script:WdhStates = @('Ready', 'ReadyWithWarnings', 'NeedsAttention', 'Incomplete', 'Unverifiable', 'Failed')
$script:WdhExitCodes = @{ Ready = 0; ReadyWithWarnings = 10; NeedsAttention = 20; Incomplete = 30; Unverifiable = 50; Failed = 60 }
$script:WdhCategoryRank = @{ Verified = 0; Warning = 1; NeedsAttention = 2; Incomplete = 3; Unverifiable = 4; Failed = 5 }
$script:WdhCategoryNames = [ordered]@{
    windows = 'Windows'; accounts = 'Accounts and identity'; updates = 'Windows Update'; drivers = 'Hardware and drivers'; applications = 'Applications'
    restoration = 'Restored settings'; security = 'Security'; network = 'Network'; storage = 'Storage'; customizations = 'Windows settings'; recovery = 'Recovery and outstanding work'
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

<# Present Plug and Play devices: name, class, service, problem code and the first hardware ID. #>
function Get-WdhPnpDevices {
    @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.Present -ne $false } | ForEach-Object {
        @{ name = [string] $_.Name; class = [string] $_.PNPClass; service = [string] $_.Service; problemCode = [int] $_.ConfigManagerErrorCode
           hardwareId = $(if ($_.HardwareID) { [string] @($_.HardwareID)[0] } else { '' }) }
    })
}

<# Uninstall records: machine-wide (64- and 32-bit) and, when that user's hive is loaded, the deployment user's. #>
function Get-WdhUninstallEntries {
    param([string] $Sid = '')
    $out = @()
    $sub = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    $specs = @(@('LocalMachine', 'Registry64', 'machine', $sub), @('LocalMachine', 'Registry32', 'machine', $sub))
    if ($Sid) { $specs += , @('Users', 'Registry64', 'user', "$Sid\$sub") }
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
                $out += , @{ scope = $spec[2]; keyName = $name; displayName = $dn; displayVersion = [string] $k.GetValue('DisplayVersion', ''); publisher = [string] $k.GetValue('Publisher', '') }
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

function ConvertTo-WdhList { param($Value) if ($null -eq $Value) { return @() } return @($Value | Where-Object { $null -ne $_ }) }

function Format-WdhBytes { param([double] $Bytes) if ($Bytes -ge 1GB) { '{0:N0} GB' -f ($Bytes / 1GB) } elseif ($Bytes -ge 1MB) { '{0:N0} MB' -f ($Bytes / 1MB) } else { '{0:N0} KB' -f ($Bytes / 1KB) } }

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

function Test-WdhUpdates {
    param($C)
    $wu = $C.Config['windowsUpdate']
    $svc = Invoke-WdhProbe $C 'services' { Get-WdhServices }
    $agent = Invoke-WdhProbe $C 'updateAgent' { Get-WdhUpdateAgent }
    if ($svc -and $svc['wuauserv']) {
        $s = $svc['wuauserv']
        if ($s.startMode -eq 'Disabled') { Add-WdhFinding $C 'updates.service' 'updates' 'Windows Update service' 'Fail' 'Error' 'Available (not disabled)' 'Disabled' 'Win32_Service wuauserv' 'Services' 'Something disabled Windows Update; set the service back to Manual (not changed by this check).' | Out-Null }
        else { Add-WdhFinding $C 'updates.service' 'updates' 'Windows Update service' 'Pass' 'Error' 'Available (not disabled)' "$($s.startMode), $($s.state)" 'Win32_Service wuauserv' 'Services' | Out-Null }
    } else { Add-WdhFinding $C 'updates.service' 'updates' 'Windows Update service' 'Unverifiable' 'Error' 'Available' 'Could not be read' 'Win32_Service wuauserv' 'Services' | Out-Null }
    if (-not $wu['enabled']) {
        Add-WdhFinding $C 'updates.stage' 'updates' 'Initial Windows Update' 'NotApplicable' 'Informational' 'Not part of this deployment' "Windows updates itself on its own schedule$(if ($agent -and $agent.lastSearchUtc) { "; last successful search $($agent.lastSearchUtc)" })" 'Deployment configuration' 'health-config.json' -Required $false | Out-Null
    } else {
        $r = Read-WdhSource $C 'windowsUpdate' 'Updates\result.json'
        $snap = @($C.Snapshot.stages | Where-Object { $_.id -eq 'windowsUpdate' }) | Select-Object -First 1
        $data = $r.Data
        if ($r.Source.state -eq 'corrupt') { Add-WdhFinding $C 'updates.stage' 'updates' 'Initial Windows Update' 'Unverifiable' 'Error' 'Every applicable update installed' 'The update result is damaged' 'Updates\result.json' 'Updates\result.json' 'Run "Deployment recovery" > Retry failed operations to run the update stage again (installed updates are never offered again).' -RecoveryAction 'RetryFailed' | Out-Null }
        elseif (-not $data -or -not $snap -or $snap.state -ne 'Final') {
            $stateText = $(if ($snap) { "$($snap.state)$(if ($snap.status) { "/$($snap.status)" })" } else { 'not started' })
            $staleFinal = $C.StateRead.State -and [string] $C.StateRead.State['status'] -eq 'Completed' -and -not $data
            if ($staleFinal) { Add-WdhFinding $C 'updates.stage' 'updates' 'Initial Windows Update' 'Unverifiable' 'Error' 'Every applicable update installed' 'The deployment ended but the update stage left no result' 'Updates\result.json vs deployment state' 'Updates\result.json' 'Run "Deployment recovery" > Resume.' -RecoveryAction 'Resume' | Out-Null }
            else { Add-WdhFinding $C 'updates.stage' 'updates' 'Initial Windows Update' 'Pending' 'Error' 'Every applicable update installed' "Still running ($stateText)" 'Updates\status.json, the stage task' 'Updates\status.json' 'Wait; the stage continues by itself (it restarts the computer when needed).' -AutomaticRecovery $true -TechnicianRequired $false | Out-Null }
        } else {
            $failed = @(ConvertTo-WdhList $data['failed'])
            $installed = @(ConvertTo-WdhList $data['installed']).Count
            switch ([string] $data['status']) {
                'Succeeded' { Add-WdhFinding $C 'updates.stage' 'updates' 'Initial Windows Update' 'Pass' 'Error' 'Every applicable update installed' "Succeeded: $installed installed, $([int] $data['reboots']) restart(s)$(if ($agent -and $agent.lastSearchUtc) { "; Windows Update's last successful search $($agent.lastSearchUtc)" })" 'Updates\result.json and the Windows Update Agent' 'Updates\result.json' | Out-Null }
                'Offline' { Add-WdhFinding $C 'updates.stage' 'updates' 'Initial Windows Update' 'Fail' 'Error' 'Every applicable update installed' 'Not done: there was no network before the stage''s time limit' 'Updates\result.json' 'Updates\result.json' 'Connect the network, then "Deployment recovery" > Retry failed operations.' -RecoveryAction 'RetryFailed' | Out-Null }
                'Failed' { Add-WdhFinding $C 'updates.stage' 'updates' 'Initial Windows Update' 'Fail' 'Error' 'Every applicable update installed' "Failed: $($data['reason'])" 'Updates\result.json' 'Updates\result.json' 'See Updates\logs\engine.log, fix the cause, then "Deployment recovery" > Retry failed operations.' -RecoveryAction 'RetryFailed' | Out-Null }
                default { Add-WdhFinding $C 'updates.stage' 'updates' 'Initial Windows Update' $(if ($failed.Count) { 'Info' } else { 'Pass' }) 'Error' 'Every applicable update installed' "$($data['status']): $installed installed, $($failed.Count) failed" 'Updates\result.json' 'Updates\result.json' | Out-Null }
            }
            foreach ($f in $failed) {
                $kb = @(ConvertTo-WdhList $f['kbs']) | Select-Object -First 1
                $fid = $(if ($kb) { "updates.kb.$kb" } else { "updates.update.$((Get-WddSha256 ([Text.Encoding]::UTF8.GetBytes([string] $f['title']))).Substring(0, 12))" })
                Add-WdhFinding $C $fid 'updates' "Update $(if ($kb) { "$kb " })failed" 'Fail' 'Error' 'Installed' "$($f['title']): failed after $($f['attempts']) attempt(s) ($($f['lastHResult']))" 'Updates\result.json failed[]' 'Updates\result.json' 'Retry the update stage ("Deployment recovery" > Retry failed operations), or install it from Settings > Windows Update.' -RecoveryAction 'RetryFailed' | Out-Null
            }
        }
        $skipped = @()
        if ([string] $wu['featureUpdates'] -eq 'skip') { $skipped += 'feature updates' }
        if ([string] $wu['optionalUpdates'] -eq 'skip') { $skipped += 'optional updates' }
        if ($skipped.Count) { Add-WdhFinding $C 'updates.scope' 'updates' 'Updates not installed by design' 'Info' 'Informational' "$($skipped -join ' and ') are not installed by the deployment" 'Every other applicable update was in scope; this report does not claim that optional or deferred updates are installed' 'Deployment configuration' 'health-config.json' -Required $false | Out-Null }
    }
    if ($C.ScanUpdates) {
        $scan = Invoke-WdhProbe $C 'updateScan' { Get-WdhUpdateScan }
        if ($null -eq $scan) { Add-WdhFinding $C 'updates.scan' 'updates' 'Windows Update scan' 'Unverifiable' 'Warning' 'Scan completed' 'The scan was not possible (no network, or the service is busy)' 'Microsoft.Update.Session search (read-only)' 'Windows Update Agent' 'Try again when online.' -Required $false | Out-Null }
        elseif ($scan.required) { Add-WdhFinding $C 'updates.scan' 'updates' 'Updates still available' 'Warning' 'Warning' 'No required update outstanding' "$($scan.required) update(s) available now: $($scan.titles -join '; ')$(if ($scan.optional -or $scan.drivers -or $scan.feature) { ". Also $($scan.optional) optional, $($scan.drivers) driver, $($scan.feature) feature update(s)" })" 'Microsoft.Update.Session search (read-only)' 'Windows Update Agent' 'Install them from Settings > Windows Update, or retry the update stage.' -Required $false | Out-Null }
        else { Add-WdhFinding $C 'updates.scan' 'updates' 'Windows Update scan' 'Pass' 'Warning' 'No required update outstanding' "None required now ($($scan.optional) optional, $($scan.drivers) driver, $($scan.feature) feature update(s) not counted)" 'Microsoft.Update.Session search (read-only)' 'Windows Update Agent' -Required $false | Out-Null }
    } else { $C.Limitations.Add('No live Windows Update scan was made (run with -ScanUpdates to ask Windows Update what is still available). The update result above is the deployment''s own evidence.') }
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
    foreach ($e in $Entries) {
        if (-not $e.displayName) { continue }
        $n = Get-WdhNorm $e.displayName
        foreach ($want in $names) {
            if ($n -eq $want -or (" $n " -like "* $want *")) { return @{ found = $true; scope = $e.scope; version = $e.displayVersion; how = "uninstall record ""$($e.displayName)""" } }
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
    $shortcuts = @(ConvertTo-WdhList (Invoke-WdhProbe $C 'shortcuts' { Get-WdhPortableShortcuts }))
    $userAvailable = $C.HiveLoaded
    foreach ($it in $items) {
        $key = ([string] $it['key']).ToLowerInvariant()
        $fid = "app.$key"
        $e = $(if ($byKey.ContainsKey($key)) { $byKey[$key] } else { $null })
        $eng = $(if ($e) { [string] $e['status'] } else { '' })
        $det = $(if ($e -and $e.ContainsKey('detection')) { [string] $e['detection'] } else { '' })
        $life = $(if ($e -and $e.ContainsKey('lifecycle')) { [string] $e['lifecycle'] } elseif ($e -and (Get-Command Get-WdaLifecycle -ErrorAction SilentlyContinue)) { [string] (Get-WdaLifecycle $e) } else { '' })
        $attempts = $(if ($e -and $e.ContainsKey('totalAttempts')) { [int] $e['totalAttempts'] } elseif ($e) { [int] $e['attempts'] } else { 0 })
        $msg = $(if ($e) { [string] $e['message'] } else { '' })
        $hit = Find-WdhInstalled $it $entries @(ConvertTo-WdhList $appx) $shortcuts
        $scope = [string] $it['scope']
        $indep = $(if ($hit.found) { 'Found' } elseif (-not $userAvailable -and $scope -ne 'machine') { 'Deferred' } else { 'NotFound' })
        $required = [bool] $it['required']
        $sev = $(if ($required) { 'Error' } else { 'Warning' })
        $name = [string] $it['name']
        $where = $(if ($hit.found) { "$($hit.how)$(if ($hit.version) { ", version $($hit.version)" }) ($($hit.scope))" } else { '' })
        $method = 'Uninstall records (machine and the deployment user), Store packages, portable shortcut; the engine''s result as evidence'
        $evidence = $(if ($e) { "engine: $eng$(if ($det) { ", detection $det" })$(if ($attempts) { ", $attempts attempt(s)" })" } else { 'no engine record' })
        $recovery = $(if ($e -and $e.ContainsKey('retryable') -and [bool] $e['retryable']) { 'RetryFailed' } elseif ($eng -in 'Failed', 'Unavailable') { 'Retry -IncludePermanent' } else { '' })
        $v = $null
        if ([string] $it['kind'] -eq 'manual') {
            if ($hit.found) { $v = @('Pass', 'InstalledManually', "Installed by hand: $where", '') }
            elseif ($indep -eq 'Deferred') { $v = @('Warning', 'ManualInstallationRequired', "Manual follow-up; not found machine-wide ($($C.DeploymentUser)'s own applications could not be checked)", [string] $it['instructions']) }
            else { $v = @('Warning', 'ManualInstallationRequired', 'Not installed: this application has no unattended installation', $(if ($it['instructions']) { [string] $it['instructions'] } else { "Install $name by hand." })) }
            $sev = 'Warning'
        } elseif ($eng -in 'Pending', 'Installing' -and -not $stageFinal) { $v = @('Pending', 'Pending', "Not installed yet (the application stage is $(if ($snap) { $snap.state } else { 'not started' }))", 'Wait; the stage continues by itself.') }
        elseif (-not $e -and -not $stageFinal -and -not $hit.found) { $v = @('Pending', 'Pending', 'Not installed yet (the application stage has not reached it)', 'Wait; the stage continues by itself.') }
        elseif ($eng -eq 'RequiresRestart') { $v = @('Pending', 'WaitingForReboot', 'Installed; needs a restart to finish', 'Restart the computer.') }
        elseif ($eng -eq 'SkippedByUser') { $v = @('NotApplicable', 'SkippedByUser', 'Deselected for this deployment', '') }
        elseif ($hit.found) {
            if ($eng -in 'Succeeded', 'AlreadyInstalled', '' -or ($eng -eq 'RequiresInteraction')) {
                $want = [string] $it['version']
                if ($want -and $hit.version -and $hit.version -ne $want) { $v = @('Warning', 'InstalledVersionDiffers', "Installed, version $($hit.version) instead of $want ($where)", 'Check whether the pinned version is still required.') }
                else { $v = @('Pass', $(if ($eng -eq 'AlreadyInstalled') { 'AlreadyInstalledVerified' } else { 'InstalledVerified' }), "Installed: $where$(if (-not $e) { '; the engine has no record of it' })", '') }
            } else { $v = @('Warning', 'InstalledVerificationUncertain', "Present ($where), although the installation reported $eng. $msg", 'Open it once to confirm it works; retry it with "Deployment recovery" if it does not.') }
        } elseif ($indep -eq 'Deferred' -and $eng -in 'Succeeded', 'AlreadyInstalled') {
            $v = @('Deferred', 'WaitingForUserContext', "The engine reported $eng in $($C.DeploymentUser)'s account; not found machine-wide, and $($C.DeploymentUser)'s own applications cannot be checked while that user is signed out", "Sign in as $($C.DeploymentUser) and open the Health Report again.")
        } elseif ($eng -in 'Succeeded', 'AlreadyInstalled') {
            $v = @('Warning', 'InstalledVerificationUncertain', "The engine reported $eng$(if ($det -eq 'Unconfirmed') { ', but WinGet could not confirm it afterwards' } elseif ($det) { " (WinGet detection: $det)" }); no uninstall record or Store package matched its name", 'Open it once to confirm it is installed; uninstall records do not exist for every installer.')
        } elseif ($eng -eq 'Skipped') { $v = @('Fail', 'BlockedByDependency', "Not installed: a dependency failed. $msg", 'Run "Deployment recovery" > Retry failed operations (it retries the dependency too).') }
        elseif ($eng -eq 'RequiresInteraction') { $v = @('Warning', 'ManualInstallationRequired', "Needs a person: $msg", "Install or finish $name by hand.") }
        elseif ($eng -in 'Failed', 'Unavailable') { $v = @('Fail', 'Failed', "Missing: the installation failed$(if ($e['failureClass']) { " ($($e['failureClass']))" }) after $attempts attempt(s). $msg", $(if ($recovery -eq 'RetryFailed') { 'Run "Deployment recovery" > Retry failed operations.' } else { 'Correct the cause (see the message), then "Deployment recovery" > Retry one application with -IncludePermanent.' })) }
        elseif (-not $e -and $indep -eq 'Deferred') { $v = @('Deferred', 'WaitingForUserContext', "No engine record, and $($C.DeploymentUser)'s own applications cannot be checked now", "Sign in as $($C.DeploymentUser) and open the Health Report again.") }
        else { $v = @('Fail', 'Missing', "Not installed$(if (-not $e) { '; the application stage has no record of it (inconsistent results)' } else { " (engine: $eng)" })", 'Run "Deployment recovery" > Resume.') ; if (-not $recovery) { $recovery = 'Resume' } }
        $status = $v[0]
        if ($status -eq 'Fail' -and -not $required) { $sev = 'Warning' }
        Add-WdhFinding $C $fid 'applications' $name $status $sev $(if ([string] $it['kind'] -eq 'manual') { 'Installed (manual follow-up)' } elseif ($it['version']) { "Installed, version $($it['version'])" } else { 'Installed' }) $v[2] $method $evidence $v[3] -Required ($required -and [string] $it['kind'] -ne 'manual') -AutomaticRecovery ($status -eq 'Pending') -TechnicianRequired ($status -in 'Fail', 'Warning', 'Deferred') -RecoveryAction $(if ($status -eq 'Fail') { $recovery } else { '' }) | Out-Null
        $C.Apps.Add([ordered]@{ key = $key; name = $name; source = [string] $it['source']; packageIdentifier = [string] $it['packageIdentifier']; method = [string] $it['method']; kind = [string] $it['kind']; required = $required
                                scope = $scope; engineStatus = $eng; lifecycle = $life; attempts = $attempts; detection = $det; independent = $indep; foundIn = $(if ($hit.found) { [string] $hit.scope } else { '' }); version = [string] $hit.version; result = $v[1]; findingId = $fid })
        if ($v[1] -eq 'ManualInstallationRequired') { $C.Manual.Add([ordered]@{ id = $fid; text = "$name`: $($v[3])"; url = [string] $it['url'] }) }
    }
    if ($res.Data -and $res.Data['bootstrap'] -is [hashtable] -and [string] $res.Data['bootstrap']['status'] -in 'Failed', 'Unsupported', 'NeedsRepair') {
        Add-WdhFinding $C 'apps.winget' 'applications' 'WinGet' 'Fail' 'Error' 'WinGet usable' "$($res.Data['bootstrap']['status']): $($res.Data['bootstrap']['message'])" 'Applications\result.json bootstrap' 'Applications\result.json' 'Update App Installer from the Microsoft Store, then "Deployment recovery" > Retry failed operations.' -RecoveryAction 'RetryFailed' | Out-Null
    }
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
    foreach ($dev in @($devices)) {
        $code = [int] $dev.problemCode
        $rep = $(if ($dev.hardwareId -and $byHw.ContainsKey($dev.hardwareId.ToUpperInvariant())) { $byHw[$dev.hardwareId.ToUpperInvariant()] } else { $null })
        $id = "drivers.device.$((Get-WddSha256 ([Text.Encoding]::UTF8.GetBytes("$($dev.hardwareId)|$($dev.name)"))).Substring(0, 12).ToLowerInvariant())"
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
        if ($code -eq 14 -or ($rep -and [string] $rep['state'] -eq 'RestartPending')) { Add-WdhFinding $C $id 'drivers' $dev.name 'Pending' $sev 'Working driver' "Waiting for a restart (code ${code}: $what)" 'Plug and Play problem code' 'Win32_PnPEntity' 'Restart the computer.' -AutomaticRecovery $true -TechnicianRequired $false | Out-Null; continue }
        $hw = ($rep -and [string] $rep['state'] -eq 'HardwareIssue') -or (-not $rep -and $code -in $script:WdhHardwareCodes -and $code -ne 10)
        $wasOk = $rep -and [string] $rep['state'] -in 'Healthy', 'BasicDriver'
        $obs = "$(if ($code -eq 28) { 'Missing driver' } elseif ($hw) { 'Possible hardware or firmware problem' } else { 'Not working' }) (code ${code}: $what)$(if ($wasOk) { '; it was working when the driver stage finished' })$(if ($rep -and [string] $rep['result'] -eq 'Succeeded') { '; a driver was installed for it, but the device still reports a problem' })"
        $next = $(if ($rep -and $rep['manualAction'] -is [hashtable] -and $rep['manualAction']['text']) { [string] $rep['manualAction']['text'] } elseif ($code -eq 28) { 'Install a driver: Windows Update, the manufacturer''s support page, or "Deployment recovery" > Add driver packages.' } elseif ($hw) { 'Check the hardware (seating, cables, firmware settings) before replacing drivers.' } else { 'Open Device Manager for details; reinstall the driver or check the hardware.' })
        $C.Manual.Add([ordered]@{ id = $id; text = "$($dev.name): $next"; url = $(if ($rep -and $rep['manualAction'] -is [hashtable]) { [string] $rep['manualAction']['url'] } else { '' }) })
        Add-WdhFinding $C $id 'drivers' $dev.name 'Fail' $sev 'Working driver' $obs 'Plug and Play problem code (Win32_PnPEntity.ConfigManagerErrorCode), compared with drivers.json' 'Win32_PnPEntity, reports\drivers.json' $next -RecoveryAction $(if ($code -eq 28) { 'AddDrivers' } else { '' }) | Out-Null
    }
    if (-not $problems -and -not $basic) { Add-WdhFinding $C 'drivers.devices' 'drivers' 'Devices' 'Pass' 'Error' 'Every device working' "$(@($devices).Count) device(s), none reports a problem" 'Plug and Play problem codes (Win32_PnPEntity)' 'Win32_PnPEntity' | Out-Null }
    elseif (-not $problems) { Add-WdhFinding $C 'drivers.devices' 'drivers' 'Devices' 'Pass' 'Error' 'Every device working' "$(@($devices).Count) device(s), none reports a problem ($basic with a generic driver)" 'Plug and Play problem codes' 'Win32_PnPEntity' | Out-Null }
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
        $summary = $(if ($bad.Count) { "$($bad.Count) of $($counted.Count) check(s) need attention: $((@($bad | Select-Object -First 3) | ForEach-Object { $_.title }) -join ', ')$(if ($bad.Count -gt 3) { ', ...' })" } else { "$passed of $($counted.Count) check(s) verified" })
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
    $updates = $(if (-not $f.ContainsKey('updates.stage') -or $f['updates.stage'].status -eq 'NotApplicable') { 'Windows installs updates automatically.' } elseif ($f['updates.stage'].status -eq 'Pass') { 'Windows was updated during setup.' } elseif ($f['updates.stage'].status -eq 'Pending') { 'Updates are still being installed.' } else { 'Some updates still need to be installed (your technician will finish this).' })
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
           [ordered]@{ id = 'scanUpdates'; label = 'Recheck Windows Update (live scan)'; command = "$ps `"$me`" -ScanUpdates"; sideEffects = $false })
    if ($has) {
        $a += [ordered]@{ id = 'recovery'; label = 'Open Deployment recovery'; command = "$ps `"$tool`""; sideEffects = $false }
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
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $Config, [switch] $ScanUpdates)
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
        ScanUpdates = [bool] $ScanUpdates
        Findings = New-Object System.Collections.Generic.List[object]; Sources = New-Object System.Collections.Generic.List[object]
        Apps = New-Object System.Collections.Generic.List[object]; Manual = New-Object System.Collections.Generic.List[object]; Custom = New-Object System.Collections.Generic.List[object]
        Limitations = New-Object System.Collections.Generic.List[string]; Obs = @{}; Backups = [ordered]@{ retained = 0; bytes = 0; location = ''; requiredForOutstanding = $false; cleanup = '' }
    }
}

<#
    Verifies the deployment and writes the reports. Returns @{ Status; ExitCode; Report; Paths }.
    Nothing outside <dataRoot>\reports\health is written.
#>
function Invoke-WdhVerify {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $Config, [string] $Trigger = 'Technician', [switch] $ScanUpdates)
    $script:WdhNow = Get-WddNow
    $C = New-WdhContext $Manifest $Paths $Config -ScanUpdates:$ScanUpdates
    foreach ($t in 'Test-WdhDeployment', 'Test-WdhWindows', 'Test-WdhAccounts', 'Test-WdhUpdates', 'Test-WdhApplications', 'Test-WdhRestoration', 'Test-WdhDrivers', 'Test-WdhSecurity', 'Test-WdhNetwork', 'Test-WdhStorage', 'Test-WdhCustomizations') {
        try { & $t $C } catch {
            $cat = @{ 'Test-WdhDeployment' = 'recovery'; 'Test-WdhWindows' = 'windows'; 'Test-WdhAccounts' = 'accounts'; 'Test-WdhUpdates' = 'updates'; 'Test-WdhApplications' = 'applications'; 'Test-WdhRestoration' = 'restoration'; 'Test-WdhDrivers' = 'drivers'; 'Test-WdhSecurity' = 'security'; 'Test-WdhNetwork' = 'network'; 'Test-WdhStorage' = 'storage'; 'Test-WdhCustomizations' = 'customizations' }[$t]
            Add-WdhFinding $C "$cat.checkError" $cat "$($script:WdhCategoryNames[$cat]) check" 'Unverifiable' 'Error' 'The check completes' "The check stopped: $($_.Exception.Message)" $t 'DeploymentHealth.ps1' 'Run the check again; report this message if it repeats.' | Out-Null
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
    $limitations += 'Applications are found by their uninstall records, Store packages or portable shortcut; an installer that registers none is reported as uncertain, never as missing on that basis alone.'
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
    }
    Write-WddJson $current $report
    $template = Join-Path $Paths.Package 'scripts\health\HealthReport.html'
    if (-not (Test-Path -LiteralPath $template)) { $template = Join-Path $script:WdhScriptRoot 'HealthReport.html' }
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
    try { $manifest = Read-WddManifest (Join-Path $package 'deployment-manifest.json') } catch { Write-Output "Unverifiable: $($_.Exception.Message)"; exit 50 }
    $config = Read-WddJson (Join-Path $PSScriptRoot 'health-config.json')
    if (-not $config) { Write-Output 'Unverifiable: health-config.json is missing or damaged.'; exit 50 }
    $paths = Get-WddPaths $manifest.dataRoot
    $id = Get-WddIdentity
    if ($a.Elevate -and -not $id.IsAdmin) {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $ps -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Mode', $a.Mode)
        exit 0
    }
    if (-not $id.IsAdmin -and $a.Mode -in 'Verify', 'Dashboard') { Write-Output 'Note: not running as administrator; some checks (accounts, encryption, Store packages) may be reported as not verifiable.' }
    try { Initialize-WddLogging $paths } catch { }
    switch ($a.Mode) {
        'CleanupBackups' { $r = Invoke-WdhCleanupBackups $manifest $paths $config $a.ConfirmCleanup; Write-Output "CleanupBackups: $($r.Outcome). $($r.Message)"; exit $(if ($r.Outcome -eq 'Done') { 0 } elseif ($r.Outcome -eq 'NotElevated') { 4 } else { 1 }) }
        'ExportDiagnostics' { $r = Invoke-WdhExport $manifest $paths $config $a.OutputPath; Write-Output "ExportDiagnostics: $($r.Outcome). $($r.Message)"; exit $(if ($r.Outcome -eq 'Done') { 0 } else { 1 }) }
        default {
            $r = $(if ($a.Trigger -eq 'Startup') { Invoke-WdhStartupRecheck $manifest $paths $config } else { Invoke-WdhVerify $manifest $paths $config $a.Trigger -ScanUpdates:$a.ScanUpdates })
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
