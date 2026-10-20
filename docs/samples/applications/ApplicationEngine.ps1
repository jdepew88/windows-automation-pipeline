#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Deployment Builder - WinGet application provisioning engine.

.DESCRIPTION
    Installs the selected WinGet packages after Windows setup, one at a time, with explicit
    identifiers and sources, and records a result for every package. Written independently for this
    project on documented interfaces (winget.exe, Appx cmdlets, Task Scheduler); no third-party code.

    Runs as the signed-in user with full (elevated) rights from the scheduled task
    \WindowsDeploymentBuilder\Applications. WinGet is a per-user packaged app and is not supported in
    the SYSTEM account, so this engine refuses to run as SYSTEM.

    Order of work on each start:
      1. Preparation (allowed while Windows Update runs): network, WinGet check (no repair),
         package availability ("winget show").
      2. Gate (coordination policy "updatesFirst"): waits until the Windows Update engine has a
         final result, or is not part of this deployment.
      3. WinGet repair when needed (under the install lock), then the queue: for each package
         "winget list" (already installed?) and "winget install" while holding the machine-wide
         install lock, so Windows Update cannot restart the computer meanwhile.
      4. Additional Software (manual follow-up entries; automatic only for reviewed installers).
      5. Restart when packages require it (policy), resume after sign-in, verify, finish.

    Package results: Pending, Installing, Succeeded, AlreadyInstalled, Skipped,
    RequiresInteraction, RequiresRestart, Failed, Unavailable.
    Final states (result.json): Succeeded, CompletedWithFollowUp, CompletedWithFailures, Failed,
    Offline. The marker <dataRoot>\state\applications.done is written for the first three.

    Modes:
      Run   (default) Full engine.
      Plan  Read-only dry run: WinGet check, installed/available state and the exact command for
            every package. Installs nothing, writes nothing, needs no elevation.
#>
[CmdletBinding()]
param(
    [ValidateSet('Run', 'Plan')]
    [string] $Mode = 'Run',
    [string] $ConfigPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:EngineVersion = '1.0.0'
$script:EventSource = 'WindowsDeploymentBuilder'
$script:LogFile = $null
$script:StatusFile = $null
$script:WinGet = $null

$script:WingetId = '^(?=.{3,128}$)[A-Za-z0-9][A-Za-z0-9_+-]{0,31}(?:\.[A-Za-z0-9_+-]{1,32}){1,7}$'
$script:StoreId = '^(?:9[A-Z0-9]{11}|XP[A-Z0-9]{12})$'
$script:VersionPattern = '^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$'
$script:SafeToken = '^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$|^--[a-z][a-z-]{1,40}$|^(list|show|install)$'

# WinGet HRESULTs (AppInstallerErrors.h) -> Status, Retry, Restart (none|later|now|initiated), Text
$script:ExitCodes = @{
    '0x00000000' = @('Succeeded', $false, 'none', 'Installed.')
    '0x8A150061' = @('AlreadyInstalled', $false, 'none', 'Already installed (PACKAGE_ALREADY_INSTALLED).')
    '0x8A15010D' = @('AlreadyInstalled', $false, 'none', 'Already installed (INSTALL_ALREADY_INSTALLED).')
    '0x8A15002B' = @('AlreadyInstalled', $false, 'none', 'Installed; no applicable upgrade (UPDATE_NOT_APPLICABLE).')
    '0x8A15010E' = @('AlreadyInstalled', $false, 'none', 'A newer version is already installed (INSTALL_DOWNGRADE).')
    '0x8A150109' = @('RequiresRestart', $false, 'later', 'Installed; a restart is required to finish (INSTALL_REBOOT_REQUIRED_TO_FINISH).')
    '0x8A15010A' = @('RequiresRestart', $true, 'now', 'A restart is required before it can install (INSTALL_REBOOT_REQUIRED_FOR_INSTALL).')
    '0x8A15010B' = @('RequiresRestart', $false, 'initiated', 'The installer started a restart (INSTALL_REBOOT_INITIATED).')
    '0x00000BC2' = @('RequiresRestart', $false, 'later', 'Installed; a restart is required to finish (3010).')
    '0x00000669' = @('RequiresRestart', $false, 'initiated', 'The installer started a restart (1641).')
    '0x8A150014' = @('Unavailable', $false, 'none', 'No package with this identifier in the source (NO_APPLICATIONS_FOUND).')
    '0x8A150113' = @('Unavailable', $false, 'none', 'The package does not support this system (INSTALL_SYSTEM_NOT_SUPPORTED).')
    '0x8A150016' = @('Failed', $false, 'none', 'More than one package matched (MULTIPLE_APPLICATIONS_FOUND).')
    '0x8A15010C' = @('RequiresInteraction', $false, 'none', 'The installer was cancelled or needs a person (INSTALL_CANCELLED_BY_USER).')
    '0x8A150011' = @('Failed', $false, 'none', 'Installer hash mismatch; not installed for safety (INSTALLER_HASH_MISMATCH).')
    '0x8A15003A' = @('Failed', $false, 'none', 'Blocked by policy (BLOCKED_BY_POLICY).')
    '0x8A15010F' = @('Failed', $false, 'none', 'Blocked by policy (INSTALL_BLOCKED_BY_POLICY).')
    '0x8A15001B' = @('Failed', $false, 'none', 'Microsoft Store blocked by policy (MSSTORE_BLOCKED_BY_POLICY).')
    '0x8A15001C' = @('Failed', $false, 'none', 'App blocked by Store policy (MSSTORE_APP_BLOCKED_BY_POLICY).')
    '0x8A150041' = @('Failed', $false, 'none', 'Package agreements not accepted (PACKAGE_AGREEMENTS_NOT_ACCEPTED).')
    '0x8A150046' = @('Failed', $false, 'none', 'Source agreements not accepted (SOURCE_AGREEMENTS_NOT_ACCEPTED).')
    '0x8A150105' = @('Failed', $false, 'none', 'Not enough disk space (INSTALL_DISK_FULL).')
    '0x8A150107' = @('Failed', $true, 'none', 'No network (INSTALL_NO_NETWORK).')
    '0x8A150008' = @('Failed', $true, 'none', 'Download failed (DOWNLOAD_FAILED).')
    '0x8A150045' = @('Failed', $true, 'none', 'The source could not be opened (SOURCE_OPEN_FAILED).')
    '0x8A150101' = @('Failed', $true, 'none', 'The application is in use (INSTALL_PACKAGE_IN_USE).')
    '0x8A150102' = @('Failed', $true, 'none', 'Another installation is in progress (INSTALL_INSTALL_IN_PROGRESS).')
    '0x8A150103' = @('Failed', $true, 'none', 'A file is in use (INSTALL_FILE_IN_USE).')
    '0x8A150111' = @('Failed', $true, 'none', 'The application is in use (INSTALL_PACKAGE_IN_USE_BY_APPLICATION).')
    '0x8A150104' = @('Failed', $true, 'none', 'A dependency is missing (INSTALL_MISSING_DEPENDENCY).')
    '0x8A150110' = @('Failed', $true, 'none', 'Dependencies could not be installed (INSTALL_DEPENDENCIES).')
    '0x8A150106' = @('Failed', $true, 'none', 'Not enough memory (INSTALL_INSUFFICIENT_MEMORY).')
}

$script:Terminal = @('Succeeded', 'AlreadyInstalled', 'Skipped', 'RequiresInteraction', 'Failed', 'Unavailable')

# ------------------------------------------------------------------------------------------------
# Small helpers (time, waiting, JSON) - kept as functions so tests can replace them.
# ------------------------------------------------------------------------------------------------

function Get-WdaNow { [DateTime]::UtcNow }

function Wait-Wda { param([int] $Seconds) if ($Seconds -gt 0) { Start-Sleep -Seconds $Seconds } }

function ConvertTo-WdaDate {
    param($Value)
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    [DateTime]::Parse([string] $Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

function Format-WdaHResult {
    param($Code)
    if ($null -eq $Code -or "$Code" -eq '') { return '' }
    '0x{0:X8}' -f ([int64] $Code -band [int64] 4294967295)
}

function ConvertTo-WdaHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-WdaHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-WdaHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return , @($InputObject | ForEach-Object { ConvertTo-WdaHashtable $_ })
    }
    return $InputObject
}

function Write-WdaJson {
    param([string] $Path, $Value)
    $json = $Value | ConvertTo-Json -Depth 10
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Read-WdaJson {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    ConvertTo-WdaHashtable (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

# ------------------------------------------------------------------------------------------------
# Configuration, paths, logging, status
# ------------------------------------------------------------------------------------------------

function Get-WdaConfig {
    param([string] $Path)
    if (-not $Path) { $Path = Join-Path $PSScriptRoot 'applications-config.json' }
    $raw = Read-WdaJson $Path
    if (-not $raw) { throw "Configuration file not found: $Path" }
    $defaults = @{
        dataRoot              = 'C:\ProgramData\WindowsDeploymentBuilder'
        taskPath              = '\WindowsDeploymentBuilder\'
        taskName              = 'Applications'
        mutexName             = 'Global\WindowsDeploymentBuilder-Applications'
        packagesFile          = 'winget-packages.json'
        restartPolicy         = 'whenRequired'
        registerAppInstaller  = $true
        onlineRepair          = $false
        minimumWinGetVersion  = '1.6.0'
        maxReboots            = 3
        maxAttemptsPerPackage = 2
        packageTimeoutMinutes = 30
        networkWaitMinutes    = 15
        maxRuntimeHours       = 4
        waitForUpdatesHours   = 8
        gatePollMinutes       = 50
        lockWaitMinutes       = 60
        maxErrors             = 5
        rebootWarningSeconds  = 60
        retryDelaySeconds     = 30
        packages              = @()
        unresolved            = @()
        additionalSoftware    = @()
        coordination          = @{ policy = 'updatesFirst'; windowsUpdate = @{ enabled = $false } }
    }
    foreach ($k in @($defaults.Keys)) { if (-not $raw.ContainsKey($k) -or $null -eq $raw[$k]) { $raw[$k] = $defaults[$k] } }
    foreach ($k in 'packages', 'unresolved', 'additionalSoftware') { $raw[$k] = @($raw[$k] | Where-Object { $_ }) }
    $raw.configDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    return $raw
}

function Get-WdaPaths {
    param([hashtable] $Config)
    $root = Join-Path $Config.dataRoot 'Applications'
    @{
        Root        = $root
        Logs        = Join-Path $root 'logs'
        Log         = Join-Path (Join-Path $root 'logs') 'engine.log'
        PackageLogs = Join-Path (Join-Path $root 'logs') 'packages'
        State       = Join-Path $root 'state.json'
        Status      = Join-Path $root 'status.json'
        Result      = Join-Path $root 'result.json'
        FollowUp    = Join-Path $root 'follow-up.txt'
        Installers  = Join-Path $root 'installers'
        Offline     = Join-Path $root 'offline'
        MarkerDir   = Join-Path $Config.dataRoot 'state'
        Marker      = Join-Path (Join-Path $Config.dataRoot 'state') 'applications.done'
    }
}

function Write-WdaLog {
    param([string] $Message, [ValidateSet('INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO')
    $line = '{0}  {1,-5}  {2}' -f (Get-WdaNow).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Verbose $line
    if (-not $script:LogFile) { return }
    for ($i = 0; $i -lt 3; $i++) {
        try { [System.IO.File]::AppendAllText($script:LogFile, $line + "`r`n"); return }
        catch { Start-Sleep -Milliseconds 200 }
    }
}

function Limit-WdaLogSize {
    param([string] $Path, [int64] $MaxBytes = 5MB)
    if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -gt $MaxBytes) {
        Move-Item -LiteralPath $Path -Destination "$Path.1" -Force
    }
}

function Set-WdaStatus {
    param([string] $Phase, [string] $Detail = '', [hashtable] $State)
    if (-not $script:StatusFile) { return }
    $o = [ordered]@{
        phase      = $Phase
        detail     = $Detail
        updatedUtc = (Get-WdaNow).ToString('o')
        computer   = $env:COMPUTERNAME
        version    = $script:EngineVersion
    }
    if ($State) {
        $o.starts = $State.starts
        $o.reboots = $State.reboots
        $o.done = @($State.packages.Values | Where-Object { $_.status -in $script:Terminal }).Count
        $o.total = @($State.packages.Values).Count
    }
    try { Write-WdaJson $script:StatusFile $o } catch { Write-WdaLog "Could not write status: $($_.Exception.Message)" 'WARN' }
}

function Write-WdaEvent {
    param([int] $EventId, [string] $Message, [ValidateSet('Information', 'Warning', 'Error')] [string] $EntryType = 'Information')
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($script:EventSource)) {
            New-EventLog -LogName Application -Source $script:EventSource
        }
        Write-EventLog -LogName Application -Source $script:EventSource -EventId $EventId -EntryType $EntryType -Message $Message
    } catch {
        Write-WdaLog "Could not write event $EventId to the Application log: $($_.Exception.Message)" 'WARN'
    }
}

# ------------------------------------------------------------------------------------------------
# State
# ------------------------------------------------------------------------------------------------

function New-WdaState {
    @{
        version          = 1
        firstStartUtc    = $null
        installStartUtc  = $null
        starts           = 0
        reboots          = 0
        errors           = 0
        offlineStarts    = 0
        everOnline       = $false
        prepared         = $false
        restartForPending = $false
        bootstrap        = $null
        packages         = @{}
        additional       = @{}
        final            = $null
    }
}

function Read-WdaState {
    param([hashtable] $Paths)
    $s = $null
    try { $s = Read-WdaJson $Paths.State }
    catch {
        Write-WdaLog "State file unreadable ($($_.Exception.Message)); keeping a copy and starting over." 'WARN'
        Copy-Item -LiteralPath $Paths.State -Destination "$($Paths.State).corrupt" -Force -ErrorAction SilentlyContinue
    }
    $fresh = New-WdaState
    if (-not $s) { return $fresh }
    foreach ($k in @($fresh.Keys)) { if (-not $s.ContainsKey($k)) { $s[$k] = $fresh[$k] } }
    if ($null -eq $s.packages) { $s.packages = @{} }
    if ($null -eq $s.additional) { $s.additional = @{} }
    return $s
}

function Save-WdaState { param([hashtable] $State, [hashtable] $Paths) Write-WdaJson $Paths.State $State }

# ------------------------------------------------------------------------------------------------
# Package queue. The native WinGet package list is the package specification; applications-config
# adds order and metadata. Every identifier is validated again here (defence in depth).
# ------------------------------------------------------------------------------------------------

function Get-WdaKey { param([string] $Source, [string] $Id) "$($Source.ToLowerInvariant()):$($Id.ToLowerInvariant())" }

function Test-WdaPackageSpec {
    param([hashtable] $P)
    $source = [string] $P.source
    $id = [string] $P.packageIdentifier
    if ($source -eq 'winget') { if ($id -cnotmatch $script:WingetId) { return "Invalid winget identifier '$id'." } }
    elseif ($source -eq 'msstore') { if ($id -cnotmatch $script:StoreId) { return "Invalid Microsoft Store identifier '$id'." } }
    else { return "Unsupported source '$source'." }
    if ($P.version -and ([string] $P.version) -cnotmatch $script:VersionPattern) { return "Invalid version '$($P.version)'." }
    if ($P.scope -and $P.scope -notin 'user', 'machine') { return "Invalid scope '$($P.scope)'." }
    return $null
}

function Read-WdaNativePackages {
    param([string] $Path)
    $out = @()
    if (-not (Test-Path -LiteralPath $Path)) { return , $out }
    $doc = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($s in @($doc.Sources)) {
        $d = $s.SourceDetails
        $source = switch -Regex ([string] $d.Identifier) {
            '^Microsoft\.Winget\.Source_8wekyb3d8bbwe$' { 'winget'; break }
            '^StoreEdgeFD$' { 'msstore'; break }
            default { [string] $d.Name }
        }
        foreach ($p in @($s.Packages)) {
            $id = [string] $p.PackageIdentifier
            if ($source -eq 'msstore') { $id = $id.ToUpperInvariant() }
            $version = ''; $scope = ''
            if ($p.PSObject.Properties['Version']) { $version = [string] $p.Version }
            if ($p.PSObject.Properties['Scope']) { $scope = [string] $p.Scope }
            $out += @{ packageIdentifier = $id; source = $source; version = $version; scope = $scope }
        }
    }
    return , $out
}

function Get-WdaQueue {
    param([hashtable] $Config)
    $native = Read-WdaNativePackages (Join-Path $Config.configDirectory $Config.packagesFile)
    $nativeKeys = @{}
    foreach ($n in $native) { $nativeKeys[(Get-WdaKey $n.source $n.packageIdentifier)] = $n }
    $queue = @()
    $seen = @{}
    foreach ($p in @($Config.packages)) {
        $k = Get-WdaKey $p.source $p.packageIdentifier
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $queue += @{
            key = $k; packageIdentifier = [string] $p.packageIdentifier; source = [string] $p.source
            name = $(if ($p.displayName) { [string] $p.displayName } else { [string] $p.packageIdentifier })
            version = [string] $p.version; scope = [string] $p.scope
            interaction = $(if ($p.interaction) { [string] $p.interaction } else { 'unknown' })
            after = @($p.after | Where-Object { $_ }); inNative = $nativeKeys.ContainsKey($k)
        }
    }
    # Packages only in the native list (for example a WinGet export placed there by hand).
    foreach ($n in $native) {
        $k = Get-WdaKey $n.source $n.packageIdentifier
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $queue += @{ key = $k; packageIdentifier = $n.packageIdentifier; source = $n.source; name = $n.packageIdentifier
                     version = $n.version; scope = $n.scope; interaction = 'unknown'; after = @(); inNative = $true }
    }
    return , $queue
}

function Get-WdaArguments {
    param([string] $Verb, [hashtable] $P)
    $a = @($Verb, '--id', $P.packageIdentifier, '--exact', '--source', $P.source)
    if ($Verb -eq 'install') {
        if ($P.version) { $a += @('--version', $P.version) }
        if ($P.scope) { $a += @('--scope', $P.scope) }
        $a += @('--silent', '--no-upgrade', '--accept-package-agreements')
    }
    $a += @('--accept-source-agreements', '--disable-interactivity')
    , $a
}

function ConvertFrom-WdaExitCode {
    param($Code)
    $hex = Format-WdaHResult $Code
    $m = $script:ExitCodes[$hex]
    if ($m) { return @{ Status = $m[0]; Retry = $m[1]; Restart = $m[2]; Message = $m[3]; Code = $hex } }
    @{ Status = 'Failed'; Retry = $true; Restart = 'none'; Message = "WinGet exit code $hex."; Code = $hex }
}

# ------------------------------------------------------------------------------------------------
# System adapters. Everything that touches WinGet, the network, tasks or restarts lives here.
# ------------------------------------------------------------------------------------------------

function Get-WdaContext {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    @{ User = $id.Name; IsSystem = ($id.User.Value -eq 'S-1-5-18'); IsElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
}

<#
    Runs winget.exe with validated tokens only. Every argument must match a strict pattern (no
    spaces, quotes or shell characters), so joining them into one command line cannot inject.
#>
function Invoke-WdaWinGet {
    param([string[]] $Arguments, [int] $TimeoutMinutes = 10, [string] $LogFile = '')
    foreach ($t in $Arguments) { if ($t -cnotmatch $script:SafeToken) { throw "Refusing unsafe WinGet argument '$t'." } }
    if (-not $script:WinGet) { throw 'WinGet path not resolved.' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:WinGet
    $psi.Arguments = $Arguments -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()
    $timedOut = -not $proc.WaitForExit([int] [Math]::Min([int]::MaxValue, $TimeoutMinutes * 60000))
    if ($timedOut) { try { $proc.Kill() } catch { } }
    $proc.WaitForExit()
    $text = ($stdout.Result + $stderr.Result) -replace '[\u2580-\u259F\u2800-\u28FF]', '' -replace "(?m)^\s*[-\\|/]\s*$", ''
    if ($LogFile) {
        try { [System.IO.File]::AppendAllText($LogFile, ("`r`n> winget {0}`r`n{1}`r`nexit {2}`r`n" -f $psi.Arguments, $text.Trim(), $(if ($timedOut) { 'timeout' } else { Format-WdaHResult $proc.ExitCode }))) } catch { }
    }
    @{ ExitCode = $(if ($timedOut) { $null } else { $proc.ExitCode }); TimedOut = $timedOut; Output = $text }
}

<# $true = installed, $false = not installed, $null = could not tell. #>
function Test-WdaInstalled {
    param([hashtable] $P, [string] $LogFile = '')
    $r = Invoke-WdaWinGet (Get-WdaArguments 'list' $P) 5 $LogFile
    if ($r.TimedOut) { return $null }
    if ($r.ExitCode -eq 0) { return $true }
    if ((Format-WdaHResult $r.ExitCode) -eq '0x8A150014') { return $false }
    return $null
}

<# Available, NotFound or Unknown. #>
function Test-WdaAvailable {
    param([hashtable] $P, [string] $LogFile = '')
    $r = Invoke-WdaWinGet (Get-WdaArguments 'show' $P) 5 $LogFile
    if ($r.TimedOut) { return 'Unknown' }
    if ($r.ExitCode -eq 0) { return 'Available' }
    if ((Format-WdaHResult $r.ExitCode) -eq '0x8A150014') { return 'NotFound' }
    return 'Unknown'
}

function Install-WdaPackage {
    param([hashtable] $P, [int] $TimeoutMinutes, [string] $LogFile = '')
    Invoke-WdaWinGet (Get-WdaArguments 'install' $P) $TimeoutMinutes $LogFile
}

function Test-WdaNetwork {
    try {
        # Network Connectivity Status Indicator probe documented by Microsoft.
        $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 10
        if ($r.Content -eq 'Microsoft Connect Test') { return $true }
    } catch { }
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $tcp.BeginConnect('cdn.winget.microsoft.com', 443, $null, $null)
        return ($iar.AsyncWaitHandle.WaitOne(5000) -and $tcp.Connected)
    } catch { return $false } finally { $tcp.Close() }
}

function Test-WdaRebootPending {
    try { if ((New-Object -ComObject 'Microsoft.Update.SystemInfo').RebootRequired) { return $true } } catch { }
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
                     'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        if (Test-Path -LiteralPath $key) { return $true }
    }
    return $false
}

function Invoke-WdaReboot {
    param([int] $WarningSeconds, [string] $Reason)
    # p:4:2 = planned, Application: Installation
    & "$env:SystemRoot\System32\shutdown.exe" /r /t $WarningSeconds /d p:4:2 /c "Windows Deployment Builder: $Reason. The computer restarts in $WarningSeconds seconds; application setup resumes after sign-in."
    if ($LASTEXITCODE -ne 0) { throw "shutdown.exe failed with exit code $LASTEXITCODE" }
}

function Test-WdaUpdateTask {
    param([hashtable] $WU)
    try { [void] (Get-ScheduledTask -TaskName $WU.taskName -TaskPath $WU.taskPath -ErrorAction Stop); return $true } catch { return $false }
}

function Unregister-WdaTask {
    param([hashtable] $Config)
    try {
        $t = Get-ScheduledTask -TaskName $Config.taskName -TaskPath $Config.taskPath -ErrorAction Stop
        $t | Unregister-ScheduledTask -Confirm:$false
        Write-WdaLog "Removed scheduled task $($Config.taskPath)$($Config.taskName)."
    } catch {
        Write-WdaLog "Scheduled task $($Config.taskPath)$($Config.taskName) not removed: $($_.Exception.Message)" 'WARN'
    }
}

function Get-WdaFileHash { param([string] $Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant() }

function Test-WdaSignature { param([string] $Path) (Get-AuthenticodeSignature -LiteralPath $Path).Status -eq 'Valid' }

<# Runs a reviewed installer with an argument list (never through a shell). Returns the exit code. #>
function Start-WdaInstaller {
    param([string] $Path, [string] $Type, [string[]] $Arguments, [int] $TimeoutMinutes)
    $quoted = @($Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
    if ($Type -eq 'msi') {
        $file = Join-Path $env:SystemRoot 'System32\msiexec.exe'
        $quoted = @('/i', ('"' + $Path + '"')) + $quoted
    } else { $file = $Path }
    $proc = Start-Process -FilePath $file -ArgumentList $quoted -PassThru -WindowStyle Hidden
    if (-not $proc.WaitForExit([int] [Math]::Min([int]::MaxValue, $TimeoutMinutes * 60000))) { try { $proc.Kill() } catch { }; return $null }
    $proc.ExitCode
}

# ------------------------------------------------------------------------------------------------
# Coordination with the Windows Update engine
# ------------------------------------------------------------------------------------------------

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

<#
    "updatesFirst": applications are installed only after the Windows Update engine finished (any
    final status), or when it is not part of this deployment, or after waitForUpdatesHours.
#>
function Get-WdaUpdatesGate {
    param([hashtable] $Config, [hashtable] $State)
    $wu = $Config.coordination.windowsUpdate
    if (-not $wu -or -not $wu.enabled) { return @{ Open = $true; Reason = 'Windows Update automation is not part of this deployment.' } }
    $s = $null
    try { $s = Read-WdaJson $wu.stateFile } catch { }
    if ($s -and $s.final) { return @{ Open = $true; Reason = "Windows Update finished: $($s.final)." } }
    if (Test-Path -LiteralPath $wu.resultFile) { return @{ Open = $true; Reason = 'Windows Update result found.' } }
    $waited = ((Get-WdaNow) - (ConvertTo-WdaDate $State.firstStartUtc)).TotalHours
    if ($waited -ge [double] $Config.waitForUpdatesHours) { return @{ Open = $true; Reason = "Windows Update still not finished after $($Config.waitForUpdatesHours) h; continuing anyway."; Warn = $true } }
    if (-not $s -and -not (Test-WdaUpdateTask $wu) -and $waited -ge 0.5) {
        return @{ Open = $true; Reason = 'The Windows Update engine is not installed (no task, no state); continuing.'; Warn = $true }
    }
    @{ Open = $false; Reason = 'Waiting for Windows Update to finish.' }
}

# ------------------------------------------------------------------------------------------------
# Single instance
# ------------------------------------------------------------------------------------------------

function Enter-WdaMutex {
    param([string] $Name)
    $m = New-Object System.Threading.Mutex($false, $Name)
    try {
        if ($m.WaitOne([TimeSpan]::FromSeconds(10))) { return $m }
    } catch [System.Threading.AbandonedMutexException] {
        return $m
    }
    $m.Dispose()
    return $null
}

function Exit-WdaMutex {
    param($Mutex)
    if ($Mutex) { try { $Mutex.ReleaseMutex() } catch { }; $Mutex.Dispose() }
}

# ------------------------------------------------------------------------------------------------
# Package bookkeeping
# ------------------------------------------------------------------------------------------------

function Set-WdaPackage {
    param([hashtable] $Entry, [string] $Status, [string] $Message = '', $Code = $null)
    $Entry.status = $Status
    if ($Message) { $Entry.message = $Message }
    if ($null -ne $Code) { $Entry.exitCode = [string] $Code }
    $Entry.updatedUtc = (Get-WdaNow).ToString('o')
}

function Initialize-WdaEntries {
    param([hashtable] $Config, [hashtable] $State, [object[]] $Queue)
    foreach ($p in $Queue) {
        if ($State.packages.ContainsKey($p.key)) { continue }
        $e = @{ key = $p.key; name = $p.name; packageIdentifier = $p.packageIdentifier; source = $p.source; status = 'Pending'
                attempts = 0; exitCode = ''; message = ''; updatedUtc = (Get-WdaNow).ToString('o'); restart = ''; restartBoot = ''; interrupted = $false }
        $bad = Test-WdaPackageSpec $p
        if ($bad) { Set-WdaPackage $e 'Unavailable' "Not installed: $bad" }
        $State.packages[$p.key] = $e
    }
    foreach ($u in @($Config.unresolved)) {
        $k = Get-WdaKey ([string] $u.source) ([string] $u.packageIdentifier)
        if ($State.packages.ContainsKey($k)) { continue }
        $State.packages[$k] = @{ key = $k; name = [string] $u.displayName; packageIdentifier = [string] $u.packageIdentifier; source = [string] $u.source
                                status = 'Unavailable'; attempts = 0; exitCode = ''; message = "Unresolved: $($u.reason)"; updatedUtc = (Get-WdaNow).ToString('o')
                                restart = ''; restartBoot = ''; interrupted = $false }
    }
    foreach ($a in @($Config.additionalSoftware)) {
        if ($State.additional.ContainsKey($a.id)) { continue }
        $State.additional[$a.id] = @{ id = $a.id; name = [string] $a.name; status = 'Pending'; attempts = 0; exitCode = ''; message = ''; updatedUtc = (Get-WdaNow).ToString('o') }
    }
}

<# After a restart, packages waiting for one are verified or retried; a crash mid-install is noted. #>
function Resume-WdaEntries {
    param([hashtable] $State)
    $boot = Get-WdbBootTime
    foreach ($e in @($State.packages.Values)) {
        if ($e.status -eq 'Installing') {
            $e.interrupted = $true
            Set-WdaPackage $e 'Pending' 'The previous attempt was interrupted; checking again.'
            Write-WdaLog "  $($e.name): previous attempt was interrupted."  'WARN'
        } elseif ($e.status -eq 'RequiresRestart' -and $e.restart -and $e.restartBoot -ne $boot) {
            $e.interrupted = $true
            Set-WdaPackage $e 'Pending' 'Checking again after the restart.'
        }
    }
}

function Get-WdaCounts {
    param([hashtable] $State)
    $c = [ordered]@{ total = 0; succeeded = 0; alreadyInstalled = 0; skipped = 0; requiresInteraction = 0; requiresRestart = 0; failed = 0; unavailable = 0; pending = 0 }
    foreach ($e in @($State.packages.Values) + @($State.additional.Values)) {
        $c.total++
        switch ($e.status) {
            'Succeeded' { $c.succeeded++ } 'AlreadyInstalled' { $c.alreadyInstalled++ } 'Skipped' { $c.skipped++ }
            'RequiresInteraction' { $c.requiresInteraction++ } 'RequiresRestart' { $c.requiresRestart++ }
            'Failed' { $c.failed++ } 'Unavailable' { $c.unavailable++ } default { $c.pending++ }
        }
    }
    $c
}

# ------------------------------------------------------------------------------------------------
# Outcomes
# ------------------------------------------------------------------------------------------------

function Complete-Wda {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State, [string] $Status, [string] $Reason, [object[]] $Queue = @())
    $now = (Get-WdaNow).ToString('o')
    $order = @{}
    $i = 0
    foreach ($q in $Queue) { $order[$q.key] = $i++ }
    $packages = @($State.packages.Values | Sort-Object @{ Expression = { if ($order.ContainsKey($_.key)) { $order[$_.key] } else { 100000 } } }, key | ForEach-Object {
        [ordered]@{ key = $_.key; name = $_.name; packageIdentifier = $_.packageIdentifier; source = $_.source; status = $_.status
                    attempts = [int] $_.attempts; exitCode = $_.exitCode; message = $_.message; timestampUtc = $_.updatedUtc }
    })
    $additional = @($State.additional.Values | Sort-Object name | ForEach-Object {
        [ordered]@{ id = $_.id; name = $_.name; status = $_.status; attempts = [int] $_.attempts; exitCode = $_.exitCode; message = $_.message; timestampUtc = $_.updatedUtc }
    })
    $followUp = @()
    foreach ($e in $packages + $additional) {
        if ($e.status -in 'RequiresInteraction', 'RequiresRestart', 'Failed', 'Unavailable', 'Pending') { $followUp += ('{0} [{1}]: {2}' -f $e.name, $e.status, $e.message) }
    }
    $b = $State.bootstrap
    $result = [ordered]@{
        schemaVersion      = 1
        stage              = 'applications'
        status             = $Status
        reason             = $Reason
        engineVersion      = $script:EngineVersion
        computer           = $env:COMPUTERNAME
        user               = $env:USERNAME
        startedUtc         = $State.firstStartUtc
        finishedUtc        = $now
        starts             = $State.starts
        reboots            = $State.reboots
        bootstrap          = [ordered]@{ status = $(if ($b) { $b.status } else { 'NotRun' }); method = $(if ($b) { $b.method } else { '' }); winGetVersion = $(if ($b) { $b.version } else { '' }); message = $(if ($b) { $b.message } else { '' }) }
        counts             = Get-WdaCounts $State
        packages           = $packages
        additionalSoftware = $additional
        followUp           = $followUp
    }
    Write-WdaJson $Paths.Result $result
    $State.final = $Status
    Save-WdaState $State $Paths
    $text = @("Windows Deployment Builder - application setup: $Status", $Reason, '') + @($followUp | ForEach-Object { "- $_" })
    try { [System.IO.File]::WriteAllText($Paths.FollowUp, ($text -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false))) } catch { }
    if ($Status -in 'Succeeded', 'CompletedWithFollowUp', 'CompletedWithFailures') {
        if (-not (Test-Path -LiteralPath $Paths.MarkerDir)) { New-Item -ItemType Directory -Path $Paths.MarkerDir -Force | Out-Null }
        Write-WdaJson $Paths.Marker ([ordered]@{ status = $Status; finishedUtc = $now; result = $Paths.Result })
    }
    $level = switch ($Status) { 'Succeeded' { 'INFO' } { $_ -in 'CompletedWithFollowUp', 'CompletedWithFailures' } { 'WARN' } default { 'ERROR' } }
    $c = $result.counts
    Write-WdaLog ("FINISHED: {0}. {1} Succeeded {2}, already installed {3}, follow-up {4}, failed {5}, unavailable {6}, pending {7}, restarts {8}." -f $Status, $Reason, $c.succeeded, $c.alreadyInstalled, ($c.requiresInteraction + $c.requiresRestart), $c.failed, $c.unavailable, $c.pending, $State.reboots) $level
    foreach ($e in $packages) { if ($e.status -notin 'Succeeded', 'AlreadyInstalled') { Write-WdaLog ("  {0,-19} {1} ({2}:{3}) {4}" -f $e.status.ToUpperInvariant(), $e.name, $e.source, $e.packageIdentifier, $e.message) } }
    $eventId = switch ($Status) { 'Succeeded' { 2100 } 'CompletedWithFailures' { 2101 } 'Failed' { 2102 } 'Offline' { 2103 } default { 2104 } }
    $entryType = switch ($Status) { 'Succeeded' { 'Information' } { $_ -in 'CompletedWithFollowUp', 'CompletedWithFailures' } { 'Warning' } default { 'Error' } }
    Write-WdaEvent $eventId "Application setup finished: $Status. $Reason See $($Paths.Result)." $entryType
    Set-WdaStatus $Status $Reason $State
    Unregister-WdaTask $Config
    return "Finished:$Status"
}

function Request-WdaReboot {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State, [string] $Reason)
    $lock = Enter-WdbInstallLock $Config.dataRoot 'Applications' ([int] $Config.lockWaitMinutes * 60)
    if (-not $lock) {
        Write-WdaLog "Restart deferred ($Reason): another installation holds the install lock." 'WARN'
        Set-WdaStatus 'RebootDeferred' $Reason $State
        return 'RebootDeferred'
    }
    try {
        $State.reboots = [int] $State.reboots + 1
        $boot = Get-WdbBootTime
        foreach ($e in @($State.packages.Values)) { if ($e.status -eq 'RequiresRestart') { $e.restartBoot = $boot } }
        Save-WdaState $State $Paths
        Write-WdaLog "Restart $($State.reboots)/$($Config.maxReboots): $Reason. Resuming after sign-in."
        Set-WdaStatus 'Rebooting' $Reason $State
        Write-WdaEvent 2001 "Restarting to continue application setup ($Reason)."
        Set-WdbRestartPending $Config.dataRoot 'Applications' $Reason
        Invoke-WdaReboot -WarningSeconds ([int] $Config.rebootWarningSeconds) -Reason $Reason
        Wait-Wda ([int] $Config.rebootWarningSeconds + 120)
    } finally {
        Exit-WdbInstallLock $lock
    }
    return 'Rebooting'
}

function Test-WdaCanRestart {
    param([hashtable] $Config, [hashtable] $State)
    ($Config.restartPolicy -eq 'whenRequired') -and ([int] $State.reboots -lt [int] $Config.maxReboots)
}

function Get-WdaFinalStatus {
    param([hashtable] $State)
    $c = Get-WdaCounts $State
    if ($c.failed -gt 0 -or $c.unavailable -gt 0) { return 'CompletedWithFailures' }
    if ($c.requiresInteraction -gt 0 -or $c.requiresRestart -gt 0) { return 'CompletedWithFollowUp' }
    return 'Succeeded'
}

# ------------------------------------------------------------------------------------------------
# Stages
# ------------------------------------------------------------------------------------------------

function Invoke-WdaBootstrapStep {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State, [switch] $CheckOnly)
    $b = Invoke-WgbBootstrap -CheckOnly:$CheckOnly -AllowRegister ([bool] $Config.registerAppInstaller) -AllowOnlineRepair ([bool] $Config.onlineRepair) `
        -OfflinePath $Paths.Offline -MinimumVersion ([string] $Config.minimumWinGetVersion)
    foreach ($s in @($b.Steps)) { Write-WdaLog "  WinGet: $s" }
    $State.bootstrap = @{ status = $b.Status; method = $b.Method; version = $b.Version; message = $b.Message; path = $b.Path; atUtc = (Get-WdaNow).ToString('o') }
    if ($b.Status -in 'Healthy', 'Repaired') { $script:WinGet = $b.Path }
    $b
}

function Invoke-WdaAvailability {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State, [object[]] $Queue)
    foreach ($p in $Queue) {
        $e = $State.packages[$p.key]
        if ($e.status -ne 'Pending' -or $e.attempts -gt 0) { continue }
        $a = Test-WdaAvailable $p (Join-Path $Paths.PackageLogs 'availability.log')
        if ($a -eq 'NotFound') {
            Set-WdaPackage $e 'Unavailable' "No package $($p.packageIdentifier) in source $($p.source)." '0x8A150014'
            Write-WdaLog "  unavailable $($p.name) ($($p.source):$($p.packageIdentifier))" 'WARN'
        }
    }
    $State.prepared = $true
}

function Invoke-WdaAdditional {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State)
    foreach ($a in @($Config.additionalSoftware)) {
        $e = $State.additional[$a.id]
        if ($e.status -in $script:Terminal) { continue }
        if ($a.execution -ne 'automatic') {
            $where = $(if ($a.downloadUrl) { "official download $($a.downloadUrl)" } else { 'the publisher' })
            $hash = $(if ($a.sha256) { "; verify SHA-256 $($a.sha256)" } else { '' })
            Set-WdaPackage $e 'RequiresInteraction' "Manual follow-up: install from $where$hash."
            continue
        }
        $file = Join-Path $Paths.Installers ([string] $a.fileName)
        if (-not $a.fileName -or -not (Test-Path -LiteralPath $file)) {
            Set-WdaPackage $e 'RequiresInteraction' "Installer not supplied: place $($a.fileName) in $($Paths.Installers) and run the installer again."
            continue
        }
        $actual = Get-WdaFileHash $file
        if ($actual -ne ([string] $a.sha256).ToUpperInvariant()) {
            Set-WdaPackage $e 'Failed' "SHA-256 mismatch (expected $($a.sha256), found $actual); not executed."
            continue
        }
        if ($a.installerType -in 'exe', 'msi' -and -not (Test-WdaSignature $file)) {
            Set-WdaPackage $e 'Failed' 'No valid Authenticode signature; not executed.'
            continue
        }
        $lock = Enter-WdbInstallLock $Config.dataRoot 'Applications' ([int] $Config.lockWaitMinutes * 60)
        if (-not $lock) { return 'WaitingForLock' }
        try {
            $e.attempts = [int] $e.attempts + 1
            Set-WdaPackage $e 'Installing'
            Save-WdaState $State $Paths
            $code = Start-WdaInstaller $file ([string] $a.installerType) @($a.silentArgs) ([int] $Config.packageTimeoutMinutes)
            if ($null -eq $code) { Set-WdaPackage $e 'Failed' 'Timed out.' }
            elseif ($code -eq 0) { Set-WdaPackage $e 'Succeeded' 'Installed.' $code }
            elseif ($code -in 3010, 1641) { Set-WdaPackage $e 'Succeeded' 'Installed; a restart is required to finish.' $code }
            else { Set-WdaPackage $e 'Failed' "Installer exit code $code." $code }
        } finally {
            Exit-WdbInstallLock $lock
        }
        Write-WdaLog "  additional $($a.name): $($e.status) $($e.message)"
    }
    return $null
}

<#
    Installs pending packages in queue order. Returns $null when the queue is done for this run, or
    an outcome string (Rebooting, WaitingForLock, WaitingForRestart, Finished:*) to stop.
#>
function Invoke-WdaQueue {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State, [object[]] $Queue)
    $maxPasses = [int] $Config.maxAttemptsPerPackage + 1
    for ($pass = 1; $pass -le $maxPasses; $pass++) {
        $pending = @($Queue | Where-Object { $State.packages[$_.key].status -eq 'Pending' })
        if ($pending.Count -eq 0) { return $null }
        if ($pass -gt 1) { Write-WdaLog "Retry pass $pass for $($pending.Count) package(s)."; Wait-Wda ([int] $Config.retryDelaySeconds) }
        foreach ($p in $pending) {
            $e = $State.packages[$p.key]
            if ($e.status -ne 'Pending') { continue }
            if (((Get-WdaNow) - (ConvertTo-WdaDate $State.installStartUtc)).TotalHours -ge [double] $Config.maxRuntimeHours) {
                return Complete-Wda $Config $Paths $State 'Failed' "Runtime limit ($($Config.maxRuntimeHours) h) reached." $Queue
            }
            # Dependencies first; a dependency that did not install makes this one Skipped.
            $blocked = $null; $waiting = $false
            foreach ($k in @($p.after)) {
                $d = $State.packages[$k]
                if (-not $d) { continue }
                if ($d.status -in 'Failed', 'Unavailable', 'RequiresInteraction', 'Skipped') { $blocked = $d.name }
                elseif ($d.status -notin 'Succeeded', 'AlreadyInstalled') { $waiting = $true }
            }
            if ($blocked) { Set-WdaPackage $e 'Skipped' "Not attempted: it needs $blocked, which was not installed."; continue }
            if ($waiting) { continue }
            if ($p.interaction -eq 'required') {
                Set-WdaPackage $e 'RequiresInteraction' 'Marked as needing interaction; install it manually (winget install --id ... --interactive).'
                continue
            }
            if (Test-WdbRestartPending $Config.dataRoot) {
                Save-WdaState $State $Paths
                Write-WdaLog 'A restart has been scheduled by another engine; stopping until after it.' 'WARN'
                return 'WaitingForRestart'
            }
            $lock = Enter-WdbInstallLock $Config.dataRoot 'Applications' ([int] $Config.lockWaitMinutes * 60)
            if (-not $lock) {
                Save-WdaState $State $Paths
                Write-WdaLog 'Another installation holds the install lock; trying again later.' 'WARN'
                Set-WdaStatus 'WaitingForLock' '' $State
                return 'WaitingForLock'
            }
            $restartNow = $null
            try {
                $log = Join-Path $Paths.PackageLogs (($p.key -replace '[^A-Za-z0-9._+-]', '_') + '.log')
                $installed = Test-WdaInstalled $p $log
                if ($installed -eq $true) {
                    if ($e.interrupted -or $e.attempts -gt 0) { Set-WdaPackage $e 'Succeeded' 'Installed (confirmed by winget list).' }
                    else { Set-WdaPackage $e 'AlreadyInstalled' 'Already installed before this run; left unchanged.' }
                    Write-WdaLog "  $($e.status.ToLowerInvariant()) $($p.name)"
                    Save-WdaState $State $Paths
                    continue
                }
                if ([int] $e.attempts -ge [int] $Config.maxAttemptsPerPackage) {
                    Set-WdaPackage $e 'Failed' "Gave up after $($e.attempts) attempt(s). Last: $($e.message)"
                    Save-WdaState $State $Paths
                    continue
                }
                # Count the attempt before acting, so a crash or hang mid-install still counts.
                $e.attempts = [int] $e.attempts + 1
                $e.interrupted = $false
                Set-WdaPackage $e 'Installing' "Attempt $($e.attempts)."
                Save-WdaState $State $Paths
                Set-WdaStatus 'Installing' $p.name $State
                Write-WdaLog ("  installing {0} ({1}:{2}) attempt {3}/{4}" -f $p.name, $p.source, $p.packageIdentifier, $e.attempts, $Config.maxAttemptsPerPackage)
                $r = Install-WdaPackage $p ([int] $Config.packageTimeoutMinutes) $log
                if ($r.TimedOut) {
                    $m = @{ Status = 'Failed'; Retry = $true; Restart = 'none'; Message = "Timed out after $($Config.packageTimeoutMinutes) min."; Code = 'timeout' }
                } else { $m = ConvertFrom-WdaExitCode $r.ExitCode }
                $status = $m.Status
                if ($status -eq 'Failed' -and $m.Retry -and [int] $e.attempts -lt [int] $Config.maxAttemptsPerPackage) { $status = 'Pending' }
                if ($status -eq 'Succeeded' -and (Test-WdaInstalled $p $log) -eq $false) { $m.Message = 'Installed (WinGet reported success; the package is not listed by winget list).' }
                if ($status -eq 'RequiresRestart') {
                    $e.restart = $(if ($m.Restart -eq 'later') { 'verify' } else { 'retry' })
                    if ($m.Restart -in 'now', 'initiated') { $restartNow = $m.Restart }
                }
                Set-WdaPackage $e $status $m.Message $m.Code
                $lvl = $(if ($status -in 'Succeeded', 'AlreadyInstalled') { 'INFO' } else { 'WARN' })
                Write-WdaLog ("  -> {0} {1} [{2}] {3}" -f $status, $p.name, $m.Code, $m.Message) $lvl
                Save-WdaState $State $Paths
            } finally {
                Exit-WdbInstallLock $lock
            }
            if ($restartNow -eq 'initiated') {
                $State.reboots = [int] $State.reboots + 1
                $e.restartBoot = Get-WdbBootTime
                Save-WdaState $State $Paths
                Write-WdaLog "$($p.name) started a restart itself; resuming after sign-in." 'WARN'
                return 'Rebooting'
            }
            if ($restartNow -eq 'now') {
                if (Test-WdaCanRestart $Config $State) { return Request-WdaReboot $Config $Paths $State "$($p.name) needs a restart before it can install" }
                Set-WdaPackage $e 'RequiresRestart' "$($e.message) Not installed: restarts are not allowed (policy or limit)."
                $e.restart = ''
            }
        }
    }
    # Anything still pending after the last pass has run out of attempts.
    foreach ($p in $Queue) {
        $e = $State.packages[$p.key]
        if ($e.status -eq 'Pending') { Set-WdaPackage $e 'Failed' "Gave up after $($e.attempts) attempt(s). Last: $($e.message)" }
    }
    return $null
}

# ------------------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------------------

function Invoke-WdaRun {
    param([hashtable] $Config, [hashtable] $Paths)
    $State = Read-WdaState $Paths
    if ($State.final) {
        Write-WdaLog "Already finished with status $($State.final); nothing to do."
        Unregister-WdaTask $Config
        return 'AlreadyFinished'
    }
    $ctx = Get-WdaContext
    $queue = Get-WdaQueue $Config
    $first = -not $State.firstStartUtc
    if ($first) { $State.firstStartUtc = (Get-WdaNow).ToString('o') }
    $State.starts = [int] $State.starts + 1
    Initialize-WdaEntries $Config $State $queue
    Resume-WdaEntries $State
    Save-WdaState $State $Paths
    Write-WdaLog "==== Application engine $($script:EngineVersion) start $($State.starts) as $($ctx.User) (restarts so far: $($State.reboots)) ===="
    Set-WdaStatus 'Starting' "Start $($State.starts)" $State
    if ($first) {
        Write-WdaEvent 2000 'Application setup started.'
        Write-WdaLog ("Queue: {0} package(s), {1} unresolved, {2} additional item(s). Policy: {3}, restarts {4} (max {5}), {6} attempt(s) per package." -f @($queue).Count, @($Config.unresolved).Count, @($Config.additionalSoftware).Count, $Config.coordination.policy, $Config.restartPolicy, $Config.maxReboots, $Config.maxAttemptsPerPackage)
    }
    if ($ctx.IsSystem) {
        return Complete-Wda $Config $Paths $State 'Failed' 'The application stage must run as the signed-in user: WinGet is not supported in the SYSTEM account.' $queue
    }
    if (-not $ctx.IsElevated) { Write-WdaLog 'Not elevated: machine-wide installers may fail. The scheduled task should run with highest privileges.' 'WARN' }

    # 1. Preparation (allowed while Windows Update is still working).
    Set-WdaStatus 'WaitingForNetwork' '' $State
    $deadline = (Get-WdaNow).AddMinutes([double] $Config.networkWaitMinutes)
    $online = $false
    while ($true) {
        if (Test-WdaNetwork) { $online = $true; break }
        if ((Get-WdaNow) -ge $deadline) { break }
        Wait-Wda 15
    }
    if (-not $online) {
        $State.offlineStarts = [int] $State.offlineStarts + 1
        Save-WdaState $State $Paths
        $limit = [double] $Config.waitForUpdatesHours + [double] $Config.maxRuntimeHours
        if (((Get-WdaNow) - (ConvertTo-WdaDate $State.firstStartUtc)).TotalHours -ge $limit) {
            if ($State.everOnline) { return Complete-Wda $Config $Paths $State 'Failed' "Runtime limit reached while offline." $queue }
            return Complete-Wda $Config $Paths $State 'Offline' "No network connection within $limit h; nothing was installed." $queue
        }
        Write-WdaLog "No network after $($Config.networkWaitMinutes) min; trying again at the next sign-in or within the hour." 'WARN'
        Set-WdaStatus 'WaitingForNetwork' 'No network; will retry' $State
        return 'WaitingForNetwork'
    }
    if (-not $State.everOnline) { $State.everOnline = $true; Save-WdaState $State $Paths }

    $boot = $null
    if (-not $State.prepared) {
        Set-WdaStatus 'Preparing' 'Checking WinGet and package availability' $State
        $boot = Invoke-WdaBootstrapStep $Config $Paths $State -CheckOnly
        if ($boot.Status -eq 'Unsupported') { return Complete-Wda $Config $Paths $State 'Failed' $boot.Message $queue }
        if ($boot.Status -eq 'Healthy') { Invoke-WdaAvailability $Config $Paths $State $queue }
        Save-WdaState $State $Paths
    }

    # 2. Gate: Windows Update first.
    $polls = [int] $Config.gatePollMinutes
    for ($i = 0; ; $i++) {
        $gate = Get-WdaUpdatesGate $Config $State
        if ($gate.Open) {
            Write-WdaLog $gate.Reason $(if ($gate.ContainsKey('Warn')) { 'WARN' } else { 'INFO' })
            break
        }
        if ($i -eq 0) { Write-WdaLog $gate.Reason }
        if ($i -ge $polls) { Set-WdaStatus 'WaitingForUpdates' $gate.Reason $State; return 'WaitingForUpdates' }
        Set-WdaStatus 'WaitingForUpdates' $gate.Reason $State
        Wait-Wda 60
    }

    # 3. WinGet (repair under the install lock when needed), then the queue.
    if (-not $State.installStartUtc) { $State.installStartUtc = (Get-WdaNow).ToString('o'); Save-WdaState $State $Paths }
    if (-not $boot -or $boot.Status -ne 'Healthy') {
        $lock = Enter-WdbInstallLock $Config.dataRoot 'Applications' ([int] $Config.lockWaitMinutes * 60)
        if (-not $lock) { Set-WdaStatus 'WaitingForLock' '' $State; return 'WaitingForLock' }
        try { $boot = Invoke-WdaBootstrapStep $Config $Paths $State } finally { Exit-WdbInstallLock $lock }
        Save-WdaState $State $Paths
        if ($boot.Status -notin 'Healthy', 'Repaired') {
            foreach ($e in @($State.packages.Values)) { if ($e.status -eq 'Pending') { Set-WdaPackage $e 'Pending' 'Not attempted: WinGet is unavailable.' } }
            return Complete-Wda $Config $Paths $State 'Failed' $boot.Message $queue
        }
        if (-not $State.prepared) { Invoke-WdaAvailability $Config $Paths $State $queue; Save-WdaState $State $Paths }
    }

    if (Test-WdbRestartPending $Config.dataRoot) { Write-WdaLog 'A restart is scheduled; waiting for it.' 'WARN'; return 'WaitingForRestart' }
    if (Test-WdaRebootPending) {
        if (-not $State.restartForPending -and (Test-WdaCanRestart $Config $State)) {
            $State.restartForPending = $true
            Save-WdaState $State $Paths
            return Request-WdaReboot $Config $Paths $State 'a restart is pending before applications can be installed'
        }
        Write-WdaLog 'Windows still reports a pending restart; installing anyway (already restarted once, or restarts are not allowed).' 'WARN'
    }

    Set-WdaStatus 'Installing' '' $State
    $out = Invoke-WdaQueue $Config $Paths $State $queue
    if ($out) { return $out }
    Save-WdaState $State $Paths

    # 4. Additional Software.
    $out = Invoke-WdaAdditional $Config $Paths $State
    if ($out) { Save-WdaState $State $Paths; return $out }
    Save-WdaState $State $Paths

    # 5. Restart for packages that need one to finish, then verify on the next start.
    $needRestart = @($State.packages.Values | Where-Object { $_.status -eq 'RequiresRestart' -and $_.restart })
    if ($needRestart.Count -gt 0) {
        if (Test-WdaCanRestart $Config $State) { return Request-WdaReboot $Config $Paths $State "$($needRestart.Count) package(s) need a restart to finish" }
        foreach ($e in $needRestart) { $e.restart = ''; Set-WdaPackage $e 'RequiresRestart' "$($e.message) Restart the computer to finish (restarts not allowed by policy or limit)." }
    }

    $final = Get-WdaFinalStatus $State
    $reason = switch ($final) {
        'Succeeded' { 'Every selected application is installed.' }
        'CompletedWithFollowUp' { 'Some applications need manual follow-up (interaction or a restart).' }
        default { 'Some applications could not be installed.' }
    }
    return Complete-Wda $Config $Paths $State $final $reason $queue
}

function Invoke-WdaMain {
    param([hashtable] $Config)
    $paths = Get-WdaPaths $Config
    foreach ($d in $paths.Root, $paths.Logs, $paths.PackageLogs) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
    $script:LogFile = $paths.Log
    $script:StatusFile = $paths.Status
    Limit-WdaLogSize $paths.Log

    $mutex = Enter-WdaMutex $Config.mutexName
    if (-not $mutex) {
        Write-WdaLog 'Another application engine instance is running; exiting.'
        return 'AlreadyRunning'
    }
    try {
        return Invoke-WdaRun -Config $Config -Paths $paths
    } catch {
        $err = $_
        Write-WdaLog "Unhandled error: $($err.Exception.Message) $(Format-WdaHResult $err.Exception.HResult)`r`n$($err.ScriptStackTrace)" 'ERROR'
        $state = Read-WdaState $paths
        $state.errors = [int] $state.errors + 1
        Save-WdaState $state $paths
        if ($state.errors -ge [int] $Config.maxErrors -and -not $state.final) {
            return Complete-Wda $Config $paths $state 'Failed' "Stopped after $($state.errors) unexpected errors. Last: $($err.Exception.Message)"
        }
        Set-WdaStatus 'Error' "$($err.Exception.Message) (will retry)" $state
        return 'Error'
    } finally {
        Exit-WdaMutex $mutex
    }
}

<# Read-only dry run. #>
function Invoke-WdaPlan {
    param([hashtable] $Config)
    $paths = Get-WdaPaths $Config
    $queue = Get-WdaQueue $Config
    $b = Invoke-WgbBootstrap -CheckOnly -MinimumVersion ([string] $Config.minimumWinGetVersion)
    if ($b.Status -eq 'Healthy') { $script:WinGet = $b.Path }
    $rows = @()
    $n = 0
    foreach ($p in $queue) {
        $n++
        $bad = Test-WdaPackageSpec $p
        $installed = ''; $available = ''
        if (-not $bad -and $script:WinGet) {
            $i = Test-WdaInstalled $p
            $installed = $(if ($i -eq $true) { 'yes' } elseif ($i -eq $false) { 'no' } else { '?' })
            $available = Test-WdaAvailable $p
        }
        $action = if ($bad) { "Unavailable: $bad" } elseif ($p.interaction -eq 'required') { 'RequiresInteraction (not attempted)' } elseif ($installed -eq 'yes') { 'AlreadyInstalled (skip)' } elseif ($available -eq 'NotFound') { 'Unavailable' } else { 'Install' }
        $rows += [pscustomobject]@{ '#' = $n; Name = $p.name; Source = $p.source; Id = $p.packageIdentifier; Installed = $installed; Available = $available; Action = $action
                                    Command = $(if ($bad) { '' } else { 'winget ' + ((Get-WdaArguments 'install' $p) -join ' ') }) }
    }
    foreach ($u in @($Config.unresolved)) { $rows += [pscustomobject]@{ '#' = ''; Name = $u.displayName; Source = $u.source; Id = $u.packageIdentifier; Installed = ''; Available = ''; Action = "Unavailable: $($u.reason)"; Command = '' } }
    foreach ($a in @($Config.additionalSoftware)) { $rows += [pscustomobject]@{ '#' = ''; Name = $a.name; Source = 'additional'; Id = $a.fileName; Installed = ''; Available = ''; Action = $(if ($a.execution -eq 'automatic') { 'Reviewed installer (hash + signature checked)' } else { 'Manual follow-up' }); Command = '' } }
    [pscustomobject]@{ WinGet = $b; Rows = $rows; Paths = $paths }
}

# Dot-sourcing (tests) only defines the functions.
if ($MyInvocation.InvocationName -ne '.') {
    $engineMode = $Mode
    $cfg = Get-WdaConfig $ConfigPath
    . (Join-Path $PSScriptRoot 'WinGetBootstrap.ps1')
    if ($engineMode -eq 'Plan') {
        $plan = Invoke-WdaPlan $cfg
        "WinGet: $($plan.WinGet.Status) $($plan.WinGet.Version) $($plan.WinGet.Message)"
        $plan.Rows | Format-Table -AutoSize -Wrap | Out-String -Width 220
        exit 0
    }
    $outcome = Invoke-WdaMain $cfg
    Write-Output $outcome
    if ($outcome -eq 'Error' -or $outcome -eq 'Finished:Failed') { exit 1 }
    exit 0
}
