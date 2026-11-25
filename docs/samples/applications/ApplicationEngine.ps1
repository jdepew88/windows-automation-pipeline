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
         final result, or is not part of this deployment; and (Phase 8, only when the configuration
         names a driver stage) until the hardware-aware driver stage has a final result.
      3. WinGet repair when needed (under the install lock), then the queue: for each package
         "winget list" (already installed?) and "winget install" while holding the machine-wide
         install lock, so Windows Update cannot restart the computer meanwhile.
      4. Additional Software (manual follow-up entries; automatic only for reviewed installers).
         Catalog entries without an unattended installation are reported as manual follow-ups;
         portable packages get a Start menu shortcut after installation (engine 1.1.0).
      5. Restart when packages require it (policy), resume after sign-in, verify, finish.

    Package results: Pending, Installing, Succeeded, AlreadyInstalled, Skipped, SkippedByUser,
    RequiresInteraction, RequiresRestart, Failed, Unavailable. (SkippedByUser: deselected for this
    deployment, recorded so the report shows it; RequiresInteraction also covers manual follow-ups.)
    Final states (result.json): Succeeded, CompletedWithFollowUp, CompletedWithFailures, Failed,
    Offline. The marker <dataRoot>\state\applications.done is written for the first three.

    Resilience (engine 1.2.0, Phase 5): every failure is classified (Transient, Network, Timeout,
    Resource, Unknown are retried; Permanent, Integrity, Policy, User are not), retries wait with
    bounded exponential backoff and jitter, a network-class failure is checked against the network
    and the package source before it counts (lost connectivity defers the package instead of
    failing it), every attempt is recorded (state history and logs\attempts.jsonl), and the state
    file is replaced atomically with a backup of the last good copy. The status values above are
    unchanged; the lifecycle (Pending, Running, Succeeded, AlreadySatisfied, FailedRetryable,
    FailedPermanent, WaitingForNetwork, WaitingForReboot, ManualActionRequired, SkippedByUser,
    BlockedByDependency) is derived from them (Get-WdaLifecycle).

    Engine 1.4.0 (deployment reliability): a failed installer run keeps the installer's own exit
    code ("Installer failed with exit code: N" in WinGet's output) next to WinGet's result
    (SHELLEXEC_INSTALL_FAILED); a package whose installer may prompt and that times out is reported
    as needing a person instead of being retried for another full timeout; status.json names the
    application being installed, the installed/failed counts and the last failure. WinGet does not
    report download progress to a redirected process, so no percentage or speed is shown.

    Engine 1.5.0 (bare-metal review): a package whose installer refuses administrator rights
    (INSTALLER_PROHIBITS_ELEVATION) is run once as the same signed-in user without elevation (a
    one-time task, limited run level, the same validated arguments); an installer hash mismatch is
    retried once, integrityRetryMinutes later, after "winget source update" - the hash is still
    checked, and a second mismatch is final.
    Modes:
      Run   (default) Full engine.
      Plan  Read-only dry run: WinGet check, installed/available state and the exact command for
            every package. Installs nothing, writes nothing, needs no elevation.
      Retry Technician recovery (called by DeploymentRecovery.ps1): reopens failed or unfinished
            operations of this deployment for another run. Installs nothing itself.
#>
[CmdletBinding()]
param(
    [ValidateSet('Run', 'Plan', 'Retry')]
    [string] $Mode = 'Run',
    [string] $ConfigPath = '',
    # Retry mode only: operation ids ("app:winget:git.git", "additional:<id>") or -AllFailed / -PendingOnly.
    [string[]] $Operation = @(),
    [switch] $AllFailed,
    [switch] $PendingOnly,
    [switch] $IncludePermanent
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:EngineVersion = '1.5.0'
$script:StateVersion = 3
$script:EventSource = 'WindowsDeploymentBuilder'
$script:LogFile = $null
$script:StatusFile = $null
$script:WinGet = $null

$script:WingetId = '^(?=.{3,128}$)[A-Za-z0-9][A-Za-z0-9_+-]{0,31}(?:\.[A-Za-z0-9_+-]{1,32}){1,7}$'
$script:StoreId = '^(?:9[A-Z0-9]{11}|XP[A-Z0-9]{12})$'
$script:VersionPattern = '^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$'
$script:SafeToken = '^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$|^--[a-z][a-z-]{1,40}$|^(list|show|install)$'
# Portable packages: shortcut target pattern and name (plain names; see catalog.ts PORTABLE_EXE/SHORTCUT_NAME).
$script:PortableExe = '^[A-Za-z0-9][A-Za-z0-9._+*-]{0,79}\.exe$'
$script:ShortcutName = '^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,59}$'
$script:CatalogKey = '^catalog:[a-z0-9][a-z0-9-]{0,47}$'

# WinGet HRESULTs (AppInstallerErrors.h) -> Status, Retry, Restart (none|later|now|initiated), Text, Class.
# Class (Phase 5): Success, Restart, Network, Transient, Resource (retried automatically while the
# budget lasts, Resource only where Retry is true), Permanent, Integrity, Policy, User (never retried
# automatically; Integrity and Policy failures are never weakened by a retry).
$script:ExitCodes = @{
    '0x00000000' = @('Succeeded', $false, 'none', 'Installed.', 'Success')
    '0x8A150061' = @('AlreadyInstalled', $false, 'none', 'Already installed (PACKAGE_ALREADY_INSTALLED).', 'Success')
    '0x8A15010D' = @('AlreadyInstalled', $false, 'none', 'Already installed (INSTALL_ALREADY_INSTALLED).', 'Success')
    '0x8A15002B' = @('AlreadyInstalled', $false, 'none', 'Installed; no applicable upgrade (UPDATE_NOT_APPLICABLE).', 'Success')
    '0x8A15010E' = @('AlreadyInstalled', $false, 'none', 'A newer version is already installed (INSTALL_DOWNGRADE).', 'Success')
    '0x8A150109' = @('RequiresRestart', $false, 'later', 'Installed; a restart is required to finish (INSTALL_REBOOT_REQUIRED_TO_FINISH).', 'Restart')
    '0x8A15010A' = @('RequiresRestart', $true, 'now', 'A restart is required before it can install (INSTALL_REBOOT_REQUIRED_FOR_INSTALL).', 'Restart')
    '0x8A15010B' = @('RequiresRestart', $false, 'initiated', 'The installer started a restart (INSTALL_REBOOT_INITIATED).', 'Restart')
    '0x00000BC2' = @('RequiresRestart', $false, 'later', 'Installed; a restart is required to finish (3010).', 'Restart')
    '0x00000669' = @('RequiresRestart', $false, 'initiated', 'The installer started a restart (1641).', 'Restart')
    '0x8A150014' = @('Unavailable', $false, 'none', 'No package with this identifier in the source (NO_APPLICATIONS_FOUND).', 'Permanent')
    '0x8A150113' = @('Unavailable', $false, 'none', 'The package does not support this system (INSTALL_SYSTEM_NOT_SUPPORTED).', 'Permanent')
    '0x8A150016' = @('Failed', $false, 'none', 'More than one package matched (MULTIPLE_APPLICATIONS_FOUND).', 'Permanent')
    '0x8A15010C' = @('RequiresInteraction', $false, 'none', 'The installer was cancelled or needs a person (INSTALL_CANCELLED_BY_USER).', 'User')
    '0x8A150011' = @('Failed', $false, 'none', 'Installer hash mismatch; not installed for safety (INSTALLER_HASH_MISMATCH).', 'Integrity')
    '0x8A15003A' = @('Failed', $false, 'none', 'Blocked by policy (BLOCKED_BY_POLICY).', 'Policy')
    '0x8A15010F' = @('Failed', $false, 'none', 'Blocked by policy (INSTALL_BLOCKED_BY_POLICY).', 'Policy')
    '0x8A15001B' = @('Failed', $false, 'none', 'Microsoft Store blocked by policy (MSSTORE_BLOCKED_BY_POLICY).', 'Policy')
    '0x8A15001C' = @('Failed', $false, 'none', 'App blocked by Store policy (MSSTORE_APP_BLOCKED_BY_POLICY).', 'Policy')
    '0x8A150041' = @('Failed', $false, 'none', 'Package agreements not accepted (PACKAGE_AGREEMENTS_NOT_ACCEPTED).', 'Permanent')
    '0x8A150046' = @('Failed', $false, 'none', 'Source agreements not accepted (SOURCE_AGREEMENTS_NOT_ACCEPTED).', 'Permanent')
    '0x8A150105' = @('Failed', $false, 'none', 'Not enough disk space (INSTALL_DISK_FULL).', 'Resource')
    '0x8A150107' = @('Failed', $true, 'none', 'No network (INSTALL_NO_NETWORK).', 'Network')
    '0x8A150008' = @('Failed', $true, 'none', 'Download failed (DOWNLOAD_FAILED).', 'Network')
    '0x8A150045' = @('Failed', $true, 'none', 'The source could not be opened (SOURCE_OPEN_FAILED).', 'Network')
    '0x8A150101' = @('Failed', $true, 'none', 'The application is in use (INSTALL_PACKAGE_IN_USE).', 'Transient')
    '0x8A150102' = @('Failed', $true, 'none', 'Another installation is in progress (INSTALL_INSTALL_IN_PROGRESS).', 'Transient')
    '0x8A150103' = @('Failed', $true, 'none', 'A file is in use (INSTALL_FILE_IN_USE).', 'Transient')
    '0x8A150111' = @('Failed', $true, 'none', 'The application is in use (INSTALL_PACKAGE_IN_USE_BY_APPLICATION).', 'Transient')
    '0x8A150104' = @('Failed', $true, 'none', 'A dependency is missing (INSTALL_MISSING_DEPENDENCY).', 'Transient')
    '0x8A150110' = @('Failed', $true, 'none', 'Dependencies could not be installed (INSTALL_DEPENDENCIES).', 'Transient')
    '0x8A150106' = @('Failed', $true, 'none', 'Not enough memory (INSTALL_INSUFFICIENT_MEMORY).', 'Resource')
    # The package's own installer exited with an error; its exit code is taken from WinGet's output.
    '0x8A150006' = @('Failed', $true, 'none', 'The installer reported a failure (SHELLEXEC_INSTALL_FAILED).', 'Unknown')
    # Engine 1.5.0: the package declares that its installer must not run elevated (for example
    # Spotify). It is run once more as the signed-in user without administrator rights.
    '0x8A150056' = @('Failed', $false, 'none', 'The installer refuses to run with administrator rights (INSTALLER_PROHIBITS_ELEVATION).', 'Elevation')
}

$script:Terminal = @('Succeeded', 'AlreadyInstalled', 'Skipped', 'SkippedByUser', 'RequiresInteraction', 'Failed', 'Unavailable')

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

<#
    Atomic write: the JSON goes to <Path>.tmp (written through to disk), then replaces <Path> in one
    file-system operation. -Backup keeps the replaced file as <Path>.bak (the last good copy), so a
    power loss can leave the old file, the new file or both, never a half-written one.
#>
function Write-WdaJson {
    param([string] $Path, $Value, [switch] $Backup)
    $json = $Value | ConvertTo-Json -Depth 12
    $tmp = "$Path.tmp"
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    $fs = New-Object System.IO.FileStream($tmp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::WriteThrough)
    try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
    if (Test-Path -LiteralPath $Path) {
        try {
            [System.IO.File]::Replace($tmp, $Path, $(if ($Backup) { "$Path.bak" } else { $null }))
            return
        } catch {
            # Replace is unavailable on some file systems; fall back to copy-aside and move.
            if ($Backup) { Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force }
        }
    }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Read-WdaJson {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    # UTF-8 explicitly: Get-Content would read a BOM-less file in the ANSI code page in PowerShell 5.1.
    ConvertTo-WdaHashtable ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
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
        # Engine 1.5.0: run an installer that refuses elevation once without it; one delayed retry
        # after a WinGet source refresh when the published installer hash does not match (the hash
        # check itself always applies).
        userContextFallback   = $true
        integrityRetryMinutes = 30
        packages              = @()
        unresolved            = @()
        additionalSoftware    = @()
        manual                = @()
        deselected            = @()
        coordination          = @{ policy = 'updatesFirst'; windowsUpdate = @{ enabled = $false } }
    }
    foreach ($k in @($defaults.Keys)) { if (-not $raw.ContainsKey($k) -or $null -eq $raw[$k]) { $raw[$k] = $defaults[$k] } }
    foreach ($k in 'packages', 'unresolved', 'additionalSoftware', 'manual', 'deselected') { $raw[$k] = @($raw[$k] | Where-Object { $_ }) }
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
        # Phase 6: the structured restoration result (for people and the later health check) and the staged settings backup.
        Restoration = Join-Path $root 'restoration.json'
        Backup      = Join-Path $Config.dataRoot 'Backup'
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
        # Engine 1.4.0: counts and the last failure for the progress window and the LAN monitor.
        $o.installed = @($State.packages.Values | Where-Object { $_.status -in 'Succeeded', 'AlreadyInstalled' }).Count
        $o.failed = @($State.packages.Values | Where-Object { $_.status -in 'Failed', 'Unavailable' }).Count
        $o.needsPerson = @($State.packages.Values | Where-Object { $_.status -eq 'RequiresInteraction' }).Count
        $o.selected = @($State.packages.Values | Where-Object { $_.status -ne 'SkippedByUser' }).Count
        if ($State.ContainsKey('lastFailure') -and $State.lastFailure) { $o.lastFailure = $State.lastFailure }
    }
    if ($Phase -eq 'Installing' -and $Detail) { $o.current = $Detail }
    $o.progress = 'unavailable'
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
        version          = $script:StateVersion
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
        # Phase 6: settings restore operations (settings:<adapter>) and the staged backup.
        settings         = @{}
        backup           = $null
        final            = $null
        # Phase 5: technician recoveries (Retry mode) and where this state came from.
        recoveries       = @()
        recoveredFrom    = ''
        originalStartUtc = $null
        halted           = ''
    }
}

$script:PackageStatuses = @('Pending', 'Installing', 'Succeeded', 'AlreadyInstalled', 'Skipped', 'SkippedByUser', 'RequiresInteraction', 'RequiresRestart', 'Failed', 'Unavailable')

<# Fields every entry has since state version 2; older entries get them without changing status. #>
function Add-WdaEntryFields {
    param([hashtable] $Entry, [string] $Kind = 'app')
    $id = $(if ($Kind -eq 'additional') { "additional:$($Entry['id'])" } elseif ($Kind -eq 'settings') { "settings:$($Entry['id'])" } else { "app:$($Entry['key'])" })
    $defaults = @{ operationId = $id; failureClass = ''; retryable = $false; nextAttemptUtc = $null; waitingFor = ''; detection = ''
                   history = @(); networkDeferrals = 0; manualRetries = 0; totalAttempts = [int] $Entry['attempts']; interrupted = $false; restart = ''; restartBoot = '' }
    foreach ($k in @($defaults.Keys)) { if (-not $Entry.ContainsKey($k)) { $Entry[$k] = $defaults[$k] } }
    if ($null -eq $Entry.history) { $Entry.history = @() }
    $Entry.history = @($Entry.history | Where-Object { $_ -is [hashtable] })
}

<#
    Accepts a state only if its shape is sane: a version this engine understands, entry maps whose
    keys match their entries, known statuses and numeric attempt counts. Anything else is treated as
    corrupt (and never as "nothing installed yet", see Read-WdaState). Returns a reason or $null.
#>
function Test-WdaStateShape {
    param($S)
    if ($S -isnot [hashtable]) { return 'not an object' }
    if (-not $S.ContainsKey('version') -or "$($S.version)" -notmatch '^\d{1,3}$' -or [int] $S.version -lt 1 -or [int] $S.version -gt $script:StateVersion) { return "unsupported state version '$(if ($S.ContainsKey('version')) { $S.version })'" }
    foreach ($map in 'packages', 'additional', 'settings') {
        if (-not $S.ContainsKey($map) -or $null -eq $S[$map]) { continue }
        if ($S[$map] -isnot [hashtable]) { return "$map is not a map" }
        foreach ($k in @($S[$map].Keys)) {
            $e = $S[$map][$k]
            if ($e -isnot [hashtable]) { return "entry $k is not an object" }
            $own = $(if ($map -eq 'packages') { [string] $e['key'] } else { [string] $e['id'] })
            if ($own -ne $k) { return "entry $k does not match its key" }
            if ([string] $e['status'] -notin $script:PackageStatuses) { return "entry $k has an unknown status '$($e['status'])'" }
            if ("$($e['attempts'])" -notmatch '^\d{1,4}$') { return "entry $k has an invalid attempt count" }
        }
    }
    if ($S.ContainsKey('final') -and $S.final -and [string] $S.final -notin 'Succeeded', 'CompletedWithFollowUp', 'CompletedWithFailures', 'Failed', 'Offline') { return "unknown final status '$($S.final)'" }
    return $null
}

<#
    Reads the state. A missing file is a first start. An unreadable or malformed file is kept aside
    (state.json.corrupt) and the last good copy (state.json.bak, written by every save) is used
    instead; only when that is unusable too does the engine start over, and then every package is
    checked with "winget list" before anything is installed, so nothing completed is repeated.
    Version 1 states are upgraded in place without changing any status (completed work stays done).
#>
function Read-WdaState {
    param([hashtable] $Paths)
    $fresh = New-WdaState
    $s = $null
    $from = ''
    foreach ($candidate in @($Paths.State, "$($Paths.State).bak")) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        $reason = $null
        try { $s = Read-WdaJson $candidate; $reason = Test-WdaStateShape $s } catch { $reason = $_.Exception.Message }
        if (-not $reason) { if ($candidate -ne $Paths.State) { $from = 'backup' }; break }
        Write-WdaLog "State file $(Split-Path -Leaf $candidate) is unusable ($reason); keeping a copy." 'WARN'
        Copy-Item -LiteralPath $candidate -Destination "$candidate.corrupt" -Force -ErrorAction SilentlyContinue
        $s = $null
        $from = 'rebuilt'
    }
    if (-not $s) {
        if ($from) { $fresh.recoveredFrom = $from; Write-WdaLog 'Starting with a new state; every package is checked with winget list before any installation.' 'WARN' }
        return $fresh
    }
    if ($from) { $s.recoveredFrom = $from; Write-WdaLog 'Recovered the state from its last good copy (state.json.bak).' 'WARN' }
    foreach ($k in @($fresh.Keys)) { if (-not $s.ContainsKey($k)) { $s[$k] = $fresh[$k] } }
    if ($null -eq $s.packages) { $s.packages = @{} }
    if ($null -eq $s.additional) { $s.additional = @{} }
    if ($null -eq $s.settings) { $s.settings = @{} }
    if ($null -eq $s.recoveries) { $s.recoveries = @() }
    foreach ($e in @($s.packages.Values)) { Add-WdaEntryFields $e 'app' }
    foreach ($e in @($s.additional.Values)) { Add-WdaEntryFields $e 'additional' }
    foreach ($e in @($s.settings.Values)) { Add-WdaEntryFields $e 'settings' }
    $s.version = $script:StateVersion
    return $s
}

function Save-WdaState { param([hashtable] $State, [hashtable] $Paths) Write-WdaJson $Paths.State $State -Backup }

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
    if ($P.method -and $P.method -notin 'winget', 'msstore', 'portable') { return "Unsupported installation method '$($P.method)'." }
    if ($P.method -eq 'portable') {
        if ($source -ne 'winget' -or $P.scope -ne 'machine') { return 'Portable packages must come from winget with machine scope.' }
        if (-not $P.portable -or ([string] $P.portable.executable) -cnotmatch $script:PortableExe -or ([string] $P.portable.shortcut) -cnotmatch $script:ShortcutName) { return 'Invalid portable shortcut definition.' }
    }
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
            # Optional since engine 1.1.0: configs written for 1.0.0 have neither key (StrictMode
            # throws on a missing hashtable key, so test for it first).
            method = $(if ($p.ContainsKey('method') -and $p.method) { [string] $p.method } else { [string] $p.source })
            portable = $(if ($p.ContainsKey('portable') -and $p.portable -is [hashtable]) { @{ executable = [string] $p.portable['executable']; shortcut = [string] $p.portable['shortcut'] } } else { $null })
        }
    }
    # Packages only in the native list (for example a WinGet export placed there by hand).
    foreach ($n in $native) {
        $k = Get-WdaKey $n.source $n.packageIdentifier
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $queue += @{ key = $k; packageIdentifier = $n.packageIdentifier; source = $n.source; name = $n.packageIdentifier
                     version = $n.version; scope = $n.scope; interaction = 'unknown'; after = @(); inNative = $true; method = $n.source; portable = $null }
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
    if ($m) { return @{ Status = $m[0]; Retry = $m[1]; Restart = $m[2]; Message = $m[3]; Code = $hex; Class = $m[4] } }
    # Unknown codes: retried within the normal budget (never more), and recorded as Unknown.
    @{ Status = 'Failed'; Retry = $true; Restart = 'none'; Message = "WinGet exit code $hex (not a documented WinGet result)."; Code = $hex; Class = 'Unknown' }
}

<# The package installer's own exit code from WinGet's output ("Installer failed with exit code: 1603"), or ''. #>
function Get-WdaInstallerExitCode {
    param([string] $Output)
    if ($Output -match '(?im)Installer failed with exit code:\s*(-?\d+|0x[0-9A-F]+)') { return $Matches[1] }
    return ''
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

<# Engine 1.5.0: "winget source update" for one source before a retry after a hash mismatch. #>
function Update-WdaSource {
    param([string] $Source, [string] $LogFile = '')
    if ($Source -cnotmatch $script:SafeToken) { return }
    try { [void] (Invoke-WdaWinGet @('source', 'update', '--name', $Source, '--disable-interactivity') 5 $LogFile) } catch { Write-WdaLog "WinGet source update failed: $($_.Exception.Message)" 'WARN' }
}

<#
    Engine 1.5.0: the same validated "winget install" run as the signed-in user WITHOUT elevation,
    for installers that refuse administrator rights. A one-time task of this user (interactive
    logon, limited run level: never more rights than the user's normal session) runs it; the exit
    code and output come back through a folder in the user's temp directory. The task is removed
    afterwards. Returns @{ ExitCode; TimedOut; Output; Error }.
#>
function Install-WdaPackageAsUser {
    param([hashtable] $P, [int] $TimeoutMinutes, [string] $LogFile = '')
    $arguments = Get-WdaArguments 'install' $P
    foreach ($t in $arguments) { if ($t -cnotmatch $script:SafeToken) { throw "Refusing unsafe WinGet argument '$t'." } }
    if (-not $script:WinGet) { throw 'WinGet path not resolved.' }
    $q = { param([string] $x) "'" + ($x -replace "'", "''") + "'" }
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('wdb-user-install-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $out = Join-Path $dir 'output.txt'; $codeFile = Join-Path $dir 'exitcode.txt'; $runner = Join-Path $dir 'run.ps1'
    $body = @(
        "`$a = @($((@($arguments) | ForEach-Object { & $q $_ }) -join ', '))",
        "`$o = & $(& $q $script:WinGet) @a 2>&1 | Out-String",
        "[IO.File]::WriteAllText($(& $q $out), [string] `$o)",
        "[IO.File]::WriteAllText($(& $q $codeFile), [string] `$LASTEXITCODE)"
    ) -join "`r`n"
    [IO.File]::WriteAllText($runner, $body, (New-Object System.Text.UTF8Encoding($true)))
    $name = 'ApplicationAsUser-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $path = '\WindowsDeploymentBuilder\'
    $user = (Get-WdaContext).User
    $registered = $false
    try {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$runner`""
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes ($TimeoutMinutes + 5))
        Register-ScheduledTask -TaskName $name -TaskPath $path -Action $action -Principal $principal -Settings $settings -Force -Description 'Windows Deployment Builder: one application installation without administrator rights (removed afterwards).' | Out-Null
        $registered = $true
        Start-ScheduledTask -TaskName $name -TaskPath $path
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        $code = $null
        while ((Get-Date) -lt $deadline) {
            if (Test-Path -LiteralPath $codeFile) { $txt = ''; try { $txt = [IO.File]::ReadAllText($codeFile).Trim() } catch { }; $n = 0; if ([int]::TryParse($txt, [ref] $n)) { $code = $n; break } }
            Start-Sleep -Seconds 5
        }
        $text = $(if (Test-Path -LiteralPath $out) { try { [IO.File]::ReadAllText($out) } catch { '' } } else { '' })
        if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, ("`r`n> (as $user, not elevated) winget {0}`r`n{1}`r`nexit {2}`r`n" -f ($arguments -join ' '), $text.Trim(), $(if ($null -eq $code) { 'timeout' } else { Format-WdaHResult $code }))) } catch { } }
        if ($null -eq $code) { try { Stop-ScheduledTask -TaskName $name -TaskPath $path } catch { }; return @{ ExitCode = $null; TimedOut = $true; Output = $text; Error = '' } }
        return @{ ExitCode = $code; TimedOut = $false; Output = $text; Error = '' }
    } catch {
        return @{ ExitCode = $null; TimedOut = $false; Output = ''; Error = $_.Exception.Message }
    } finally {
        if ($registered) { try { Unregister-ScheduledTask -TaskName $name -TaskPath $path -Confirm:$false } catch { } }
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

<# Folders where WinGet puts machine-scope portable packages (its documented defaults). #>
function Get-WdaPortableRoots {
    @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | ForEach-Object { Join-Path $_ 'WinGet\Packages' } | Select-Object -Unique
}

function Get-WdaShortcutFolder { Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Windows Deployment Tools' }

function New-WdaShortcutFile {
    param([string] $Path, [string] $Target)
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath = $Target
    $lnk.WorkingDirectory = Split-Path -Parent $Target
    $lnk.Save()
}

<#
    Finds the executable of an installed portable package inside WinGet's package folder
    (<root>\<PackageIdentifier>_<source id>). Only plain files below that folder count: reparse
    points (links, junctions) are skipped and every match must resolve inside the folder, so a
    crafted archive cannot redirect the shortcut. The shortest path wins (top-level file first).
#>
function Find-WdaPortableExe {
    param([string[]] $Roots, [string] $PackageIdentifier, [string] $Pattern)
    if ($Pattern -cnotmatch $script:PortableExe -or $PackageIdentifier -cnotmatch $script:WingetId) { return $null }
    foreach ($root in $Roots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name.StartsWith("$($PackageIdentifier)_", [StringComparison]::OrdinalIgnoreCase) -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
        foreach ($dir in $dirs) {
            $base = [IO.Path]::GetFullPath($dir.FullName).TrimEnd('\') + '\'
            $found = @()
            $level = @($dir)
            for ($depth = 0; $depth -lt 4 -and $level.Count; $depth++) {
                $next = @()
                foreach ($d in $level) {
                    foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -Filter $Pattern -File -ErrorAction SilentlyContinue)) {
                        $full = [IO.Path]::GetFullPath($f.FullName)
                        if (-not ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { $found += $full }
                    }
                    $next += @(Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
                }
                $level = $next
            }
            if ($found.Count) { return ($found | Sort-Object Length, { $_ } | Select-Object -First 1) }
        }
    }
    return $null
}

<# Creates (or replaces) the Start menu shortcut of a portable package. Never fails the package. #>
function Set-WdaPortableShortcut {
    param([hashtable] $P)
    try {
        $exe = Find-WdaPortableExe @(Get-WdaPortableRoots) $P.packageIdentifier $P.portable.executable
        if (-not $exe) { return @{ Ok = $false; Message = "Start menu shortcut not created: $($P.portable.executable) was not found in WinGet's machine package folder." } }
        $folder = Get-WdaShortcutFolder
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
        $lnk = Join-Path $folder ($P.portable.shortcut + '.lnk')
        New-WdaShortcutFile $lnk $exe
        return @{ Ok = $true; Message = "Start menu shortcut: $lnk -> $exe." }
    } catch {
        return @{ Ok = $false; Message = "Start menu shortcut not created: $($_.Exception.Message)" }
    }
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

<#
    Phase 5: where connectivity breaks, checked after a network-class failure. Levels, in order:
    NoInterface (no adapter is up), NoLocalNetwork (no default route), DnsUnavailable (the package
    source's host name does not resolve), SourceUnavailable (the Internet is reachable but the
    package source is not), InternetUnavailable, Online. A check that cannot run (missing cmdlet)
    is skipped rather than reported as a failure. Nothing is changed: no adapter, DNS, proxy or
    firewall setting is ever touched.
#>
function Get-WdaNetworkDiagnosis {
    param([string] $Source = 'winget')
    $hosts = @{ winget = 'cdn.winget.microsoft.com'; msstore = 'storeedgefd.dsx.mp.microsoft.com' }
    $target = $(if ($hosts.ContainsKey($Source)) { $hosts[$Source] } else { $hosts.winget })
    try {
        if (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) {
            if (@(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }).Count -eq 0) { return @{ Level = 'NoInterface'; Detail = 'no network adapter is connected' } }
        }
        if (Get-Command Get-NetRoute -ErrorAction SilentlyContinue) {
            if (@(Get-NetRoute -DestinationPrefix '0.0.0.0/0', '::/0' -ErrorAction SilentlyContinue).Count -eq 0) { return @{ Level = 'NoLocalNetwork'; Detail = 'no default gateway' } }
        }
    } catch { }
    try { [void] [System.Net.Dns]::GetHostAddresses($target) } catch { return @{ Level = 'DnsUnavailable'; Detail = "$target does not resolve" } }
    $tcp = New-Object System.Net.Sockets.TcpClient
    $reachable = $false
    try { $iar = $tcp.BeginConnect($target, 443, $null, $null); $reachable = ($iar.AsyncWaitHandle.WaitOne(5000) -and $tcp.Connected) } catch { } finally { $tcp.Close() }
    if ($reachable) { return @{ Level = 'Online'; Detail = "$target reachable" } }
    $internet = $false
    try { $internet = ((Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 10).Content -eq 'Microsoft Connect Test') } catch { }
    if ($internet) { return @{ Level = 'SourceUnavailable'; Detail = "$target (source $Source) is not reachable on port 443" } }
    return @{ Level = 'InternetUnavailable'; Detail = 'the Internet is not reachable' }
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

<#
    Appends one event to the deployment's activity feed <dataRoot>\Deployment\activity.jsonl
    (retries, failures and restarts, for the progress window and the LAN monitor). Best effort:
    the feed is information, never a reason for an installation to fail.
#>
function Add-WdbActivity {
    param([string] $DataRoot, [string] $Source, [string] $Message, [string] $Level = 'info')
    try {
        $dir = Join-Path $DataRoot 'Deployment'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $line = ([ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); level = $Level; source = $Source; message = $Message } | ConvertTo-Json -Compress)
        [System.IO.File]::AppendAllText((Join-Path $dir 'activity.jsonl'), $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
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

<#
    Phase 8: applications start after the driver stage, which itself waits for Windows Update. Only
    configurations that name a driver stage (coordination.drivers) wait; any final driver status
    opens the gate (a driver failure never blocks the applications), and so does
    waitForUpdatesHours, or a driver engine that was never installed.
#>
function Get-WdaDriversGate {
    param([hashtable] $Config, [hashtable] $State)
    $c = $Config.coordination
    $dv = $(if ($c -is [hashtable] -and $c.ContainsKey('drivers')) { $c['drivers'] } else { $null })
    if (-not $dv -or -not $dv.enabled) { return @{ Open = $true; Reason = 'The driver stage is not part of this deployment.' } }
    $s = $null
    try { $s = Read-WdaJson $dv.stateFile } catch { }
    if ($s -and $s['final']) { return @{ Open = $true; Reason = "Driver stage finished: $($s['final'])." } }
    if (Test-Path -LiteralPath $dv.resultFile) { return @{ Open = $true; Reason = 'Driver stage result found.' } }
    $waited = ((Get-WdaNow) - (ConvertTo-WdaDate $State.firstStartUtc)).TotalHours
    if ($waited -ge [double] $Config.waitForUpdatesHours) { return @{ Open = $true; Reason = "The driver stage is still not finished after $($Config.waitForUpdatesHours) h; continuing anyway."; Warn = $true } }
    if (-not $s -and -not (Test-WdaUpdateTask $dv) -and $waited -ge 0.5) { return @{ Open = $true; Reason = 'The driver engine is not installed (no task, no state); continuing.'; Warn = $true } }
    @{ Open = $false; Reason = 'Waiting for the driver stage to finish.' }
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

# ------------------------------------------------------------------------------------------------
# Retry policy, failure classes and the operation lifecycle (Phase 5)
# ------------------------------------------------------------------------------------------------

# Never retried automatically; a technician may retry them after fixing the cause (-IncludePermanent).
$script:PermanentClasses = @('Permanent', 'Integrity', 'Policy', 'User', 'Manual', 'Elevation')

<#
    Retry settings from applications-config.json "retry" (engine 1.2.0). Configurations written for
    earlier engines have no "retry" block and get these defaults. Every value is clamped, so no
    configuration can make retries unbounded.
#>
function Get-WdaRetryPolicy {
    param([hashtable] $Config)
    $r = @{ automatic = $true; baseDelaySeconds = 60; maxDelaySeconds = 900; jitterRatio = 0.2; continueAfterFailure = $true; maxNetworkDeferrals = 6 }
    if ($Config.ContainsKey('retry') -and $Config['retry'] -is [hashtable]) {
        foreach ($k in @($r.Keys)) { if ($Config['retry'].ContainsKey($k) -and $null -ne $Config['retry'][$k]) { $r[$k] = $Config['retry'][$k] } }
    }
    $r.automatic = [bool] $r.automatic
    $r.continueAfterFailure = [bool] $r.continueAfterFailure
    $r.baseDelaySeconds = [int] [Math]::Min(3600, [Math]::Max(0, [int] $r.baseDelaySeconds))
    $r.maxDelaySeconds = [int] [Math]::Min(3600, [Math]::Max([int] $r.baseDelaySeconds, [int] $r.maxDelaySeconds))
    $r.jitterRatio = [double] [Math]::Min(0.5, [Math]::Max(0.0, [double] $r.jitterRatio))
    $r.maxNetworkDeferrals = [int] [Math]::Min(24, [Math]::Max(0, [int] $r.maxNetworkDeferrals))
    # Automatic retry off: one attempt per run; failures stay retryable by the recovery tool.
    $r.maxAttempts = $(if ($r.automatic) { [int] [Math]::Min(10, [Math]::Max(1, [int] $Config.maxAttemptsPerPackage)) } else { 1 })
    return $r
}

function Get-WdaRandom { Get-Random -Minimum 0.0 -Maximum 1.0 }

<# Delay before attempt n+1: base * 2^(n-1), +/- jitter, never more than maxDelaySeconds. #>
function Get-WdaBackoffSeconds {
    param([hashtable] $Policy, [int] $Attempt)
    $exp = [Math]::Min(20, [Math]::Max(0, $Attempt - 1))
    $d = [Math]::Min([double] $Policy.maxDelaySeconds, [double] $Policy.baseDelaySeconds * [Math]::Pow(2, $exp))
    $j = 1 + [double] $Policy.jitterRatio * (2 * [double] (Get-WdaRandom) - 1)
    return [int] [Math]::Round([Math]::Min([double] $Policy.maxDelaySeconds, [Math]::Max(0, $d * $j)))
}

<# The lifecycle state of an operation, derived from its status (one model, no second copy). #>
function Get-WdaLifecycle {
    param([hashtable] $Entry)
    switch ([string] $Entry['status']) {
        'Pending' {
            if ($Entry['waitingFor']) { return 'WaitingForNetwork' }
            if ([int] $Entry['attempts'] -gt 0 -or $Entry['nextAttemptUtc']) { return 'FailedRetryable' }
            return 'Pending'
        }
        'Installing' { return 'Running' }
        'Succeeded' { return 'Succeeded' }
        'AlreadyInstalled' { return 'AlreadySatisfied' }
        'SkippedByUser' { return 'SkippedByUser' }
        'Skipped' { return 'BlockedByDependency' }
        'RequiresRestart' { return 'WaitingForReboot' }
        'RequiresInteraction' { return 'ManualActionRequired' }
        'Unavailable' { return 'FailedPermanent' }
        'Failed' { if ([string] $Entry['failureClass'] -in $script:PermanentClasses) { return 'FailedPermanent' }; return 'FailedRetryable' }
    }
    return 'Pending'
}

<#
    Records one attempt: in the entry's history (last 20) and as one JSON line in
    logs\attempts.jsonl (machine-readable, for diagnostics and the later health dashboard). Never
    contains secrets: only identifiers, codes, classes and the engine's own messages.
#>
function Add-WdaAttempt {
    param([hashtable] $Paths, [hashtable] $Entry, [hashtable] $Record)
    $rec = [ordered]@{ operationId = $Entry.operationId; name = $Entry.name }
    foreach ($k in 'trigger', 'attempt', 'startUtc', 'endUtc', 'result', 'exitCode', 'installerExitCode', 'class', 'countsTowardLimit', 'nextAction', 'nextAttemptUtc', 'rebootRequired', 'message', 'packageIdentifier', 'source') {
        if ($Record.ContainsKey($k)) { $rec[$k] = $Record[$k] }
    }
    $h = @{}
    foreach ($k in $rec.Keys) { if ($k -notin 'operationId', 'name') { $h[$k] = $rec[$k] } }
    $Entry.history = @(@(@($Entry.history) + @($h)) | Select-Object -Last 20)
    try { [System.IO.File]::AppendAllText((Join-Path $Paths.Logs 'attempts.jsonl'), (($rec | ConvertTo-Json -Compress -Depth 4) + "`r`n")) } catch { Write-WdaLog "Could not append to attempts.jsonl: $($_.Exception.Message)" 'WARN' }
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
    foreach ($m in @($Config.manual)) {
        $k = ([string] $m.key).ToLowerInvariant()
        if ($k -cnotmatch $script:CatalogKey -or $State.packages.ContainsKey($k)) { continue }
        $how = [string] $m.instructions
        if ($m.ContainsKey('url') -and ([string] $m.url) -match '^https://[^\s"''<>]+$') { $how = "$how ($($m.url))" }
        $State.packages[$k] = @{ key = $k; name = [string] $m.displayName; packageIdentifier = $k.Substring(8); source = 'catalog'
                                status = 'RequiresInteraction'; attempts = 0; exitCode = ''; message = "Manual action required: $how"; updatedUtc = (Get-WdaNow).ToString('o')
                                restart = ''; restartBoot = ''; interrupted = $false }
    }
    foreach ($d in @($Config.deselected)) {
        $k = Get-WdaKey ([string] $d.source) ([string] $d.packageIdentifier)
        if ($State.packages.ContainsKey($k)) { continue }
        $State.packages[$k] = @{ key = $k; name = [string] $d.displayName; packageIdentifier = [string] $d.packageIdentifier; source = [string] $d.source
                                status = 'SkippedByUser'; attempts = 0; exitCode = ''; message = 'Deselected for this deployment; not installed.'; updatedUtc = (Get-WdaNow).ToString('o')
                                restart = ''; restartBoot = ''; interrupted = $false }
    }
    foreach ($a in @($Config.additionalSoftware)) {
        if ($State.additional.ContainsKey($a.id)) { continue }
        $State.additional[$a.id] = @{ id = $a.id; name = [string] $a.name; status = 'Pending'; attempts = 0; exitCode = ''; message = ''; updatedUtc = (Get-WdaNow).ToString('o') }
    }
    foreach ($e in @($State.packages.Values)) {
        $new = -not $e.ContainsKey('operationId')
        Add-WdaEntryFields $e 'app'
        if ($new -and $e.status -eq 'Unavailable') { $e.failureClass = 'Permanent' }
        elseif ($new -and $e.status -eq 'RequiresInteraction') { $e.failureClass = 'Manual' }
    }
    foreach ($e in @($State.additional.Values)) { Add-WdaEntryFields $e 'additional' }
    # Phase 6: one settings restore operation per adapter of the restoration plan.
    foreach ($a in @(Get-WdaSettingsPlan $Config)) {
        if ($State.settings.ContainsKey($a.id)) { continue }
        $State.settings[$a.id] = @{ id = $a.id; name = $a.name; status = 'Pending'; attempts = 0; exitCode = ''; message = ''; updatedUtc = (Get-WdaNow).ToString('o')
                                    restoreOutcome = 'Pending'; items = @(); followUps = @() }
    }
    foreach ($e in @($State.settings.Values)) { Add-WdaEntryFields $e 'settings' }
}

<#
    The settings restore plan of the configuration (engine 1.3.0, Phase 6), validated again here:
    adapter ids, conflict policies and dependency keys must match strict patterns. Returns @() when
    the configuration has no plan (every earlier configuration).
#>
function Get-WdaSettingsPlan {
    param([hashtable] $Config)
    $plan = $(if ($Config.ContainsKey('settingsRestore')) { $Config['settingsRestore'] } else { $null })
    if ($plan -isnot [hashtable] -or [string] $plan['backupId'] -notmatch '^[0-9a-f]{16}$' -or [string] $plan['manifestSha256'] -notmatch '^[0-9A-F]{64}$' -or [string] $plan['folderName'] -notmatch '^[A-Za-z0-9._-]{1,80}$') { return @() }
    $out = @()
    foreach ($a in @($plan['adapters'])) {
        if ($a -isnot [hashtable] -or [string] $a['id'] -cnotmatch '^[a-z0-9][a-z0-9-]{0,31}$' -or [string] $a['conflict'] -notin 'keepExisting', 'restoreBackup', 'skip') { continue }
        $after = @(@($a['after']) | Where-Object { [string] $_ -cmatch '^(winget|msstore):[a-z0-9][a-z0-9._+-]{0,127}$' })
        $out += , @{ id = [string] $a['id']; name = $(if ($a['name']) { [string] $a['name'] } else { [string] $a['id'] }); conflict = [string] $a['conflict']; after = $after; installExtensions = [bool] $a['installExtensions'] }
    }
    return $out
}

<#
    After a restart, packages waiting for one are verified or retried. An operation left Running
    (Installing) by a crash, a power loss or an installer-initiated restart is never assumed to have
    failed or succeeded: it goes back to Pending with "interrupted" set, and the queue checks with
    "winget list" whether it is installed before anything else happens.
#>
function Resume-WdaEntries {
    param([hashtable] $State, [hashtable] $Paths = $null)
    $boot = Get-WdbBootTime
    foreach ($e in @($State.packages.Values)) {
        if ($e.status -eq 'Installing') {
            $e.interrupted = $true
            Set-WdaPackage $e 'Pending' 'The previous attempt was interrupted; checking again.'
            if ($Paths) { Add-WdaAttempt $Paths $e @{ trigger = 'automatic'; attempt = [int] $e.totalAttempts; endUtc = (Get-WdaNow).ToString('o'); result = 'Interrupted'; class = 'Interrupted'; countsTowardLimit = $true; nextAction = 'reconcile with winget list'; message = 'The engine stopped during this attempt (crash, power loss or restart).' } }
            Write-WdaLog "  $($e.name): previous attempt was interrupted."  'WARN'
        } elseif ($e.status -eq 'RequiresRestart' -and $e.restart -and $e.restartBoot -ne $boot) {
            $e.interrupted = $true
            Set-WdaPackage $e 'Pending' 'Checking again after the restart.'
        }
    }
    # A settings restore left Running is repeated: each item is compared with the backup first, so
    # what was already written is not written again.
    foreach ($e in @($State.settings.Values)) {
        if ($e.status -ne 'Installing') { continue }
        $e.interrupted = $true
        Set-WdaPackage $e 'Pending' 'The previous restore was interrupted; restoring again (items already restored are only verified).'
        if ($Paths) { Add-WdaAttempt $Paths $e @{ trigger = 'automatic'; attempt = [int] $e.totalAttempts; endUtc = (Get-WdaNow).ToString('o'); result = 'Interrupted'; class = 'Interrupted'; countsTowardLimit = $true; nextAction = 'restore again'; message = 'The engine stopped while restoring these settings.' } }
    }
}

<# Portable packages: (re)creates the Start menu shortcut; a failure is noted, the package stays installed. #>
function Complete-WdaPortable {
    param([hashtable] $P, [hashtable] $Entry)
    if ($P.method -ne 'portable' -or -not $P.portable) { return }
    $r = Set-WdaPortableShortcut $P
    $Entry.shortcutFailed = -not $r.Ok
    Set-WdaPackage $Entry $Entry.status ("$($Entry.message) $($r.Message)".Trim())
    Write-WdaLog "  $($P.name): $($r.Message)" $(if ($r.Ok) { 'INFO' } else { 'WARN' })
}

function Get-WdaCounts {
    param([hashtable] $State)
    $c = [ordered]@{ total = 0; succeeded = 0; alreadyInstalled = 0; skipped = 0; skippedByUser = 0; requiresInteraction = 0; requiresRestart = 0; failed = 0; unavailable = 0; pending = 0 }
    foreach ($e in @($State.packages.Values) + @($State.additional.Values)) {
        $c.total++
        switch ($e.status) {
            'Succeeded' { $c.succeeded++ } 'AlreadyInstalled' { $c.alreadyInstalled++ } 'Skipped' { $c.skipped++ } 'SkippedByUser' { $c.skippedByUser++ }
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
    # Phase 5 (result schema 2): the lifecycle, failure class and attempt history of every operation.
    $resilience = {
        param($E)
        [ordered]@{ operationId = [string] $E['operationId']; lifecycle = (Get-WdaLifecycle $E); failureClass = [string] $E['failureClass']; retryable = [bool] $E['retryable']
                    detection = [string] $E['detection']; nextAttemptUtc = $E['nextAttemptUtc']; waitingFor = [string] $E['waitingFor']; totalAttempts = [int] $E['totalAttempts']
                    manualRetries = [int] $E['manualRetries']; history = @($E['history']) }
    }
    $packages = @($State.packages.Values | Sort-Object @{ Expression = { if ($order.ContainsKey($_.key)) { $order[$_.key] } else { 100000 } } }, key | ForEach-Object {
        $o = [ordered]@{ key = $_.key; name = $_.name; packageIdentifier = $_.packageIdentifier; source = $_.source; status = $_.status
                         attempts = [int] $_.attempts; exitCode = $_.exitCode; message = $_.message; timestampUtc = $_.updatedUtc }
        # Engine 1.4.0: the installer's own exit code (only when WinGet reported one).
        if ($_.ContainsKey('installerExitCode') -and $_.installerExitCode) { $o.installerExitCode = [string] $_.installerExitCode }
        $x = & $resilience $_
        foreach ($k in $x.Keys) { $o[$k] = $x[$k] }
        $o
    })
    $additional = @($State.additional.Values | Sort-Object name | ForEach-Object {
        $o = [ordered]@{ id = $_.id; name = $_.name; status = $_.status; attempts = [int] $_.attempts; exitCode = $_.exitCode; message = $_.message; timestampUtc = $_.updatedUtc }
        $x = & $resilience $_
        foreach ($k in $x.Keys) { $o[$k] = $x[$k] }
        $o
    })
    $settings = @($State.settings.Values | Sort-Object { $_.id } | ForEach-Object {
        $o = [ordered]@{ id = $_.id; name = $_.name; status = $_.status; restoreOutcome = [string] $_['restoreOutcome']; attempts = [int] $_.attempts; message = $_.message; timestampUtc = $_.updatedUtc
                         items = @($_['items'] | Where-Object { $_ }); followUps = @($_['followUps'] | Where-Object { $_ }) }
        $x = & $resilience $_
        foreach ($k in $x.Keys) { $o[$k] = $x[$k] }
        $o
    })
    $followUp = @()
    $outstanding = @()
    foreach ($e in $settings) {
        if ($e.status -notin 'Succeeded', 'AlreadyInstalled', 'SkippedByUser' -or $e.restoreOutcome -eq 'ConfigurationPartiallyRestored') { $followUp += ('{0} settings [{1}]: {2}' -f $e.name, $e.restoreOutcome, $e.message) }
        foreach ($f in @($e.followUps)) { $followUp += ('{0} settings: {1}' -f $e.name, $f) }
    }
    if ($Config.ContainsKey('migration') -and $Config['migration'] -is [hashtable]) { foreach ($f in @($Config['migration']['followUps'] | Where-Object { $_ } | Select-Object -First 300)) { $followUp += "Migration: $f" } }
    foreach ($e in $packages + $additional + $settings) {
        if ($e.status -in 'RequiresInteraction', 'RequiresRestart', 'Failed', 'Unavailable', 'Pending', 'Skipped') { $followUp += ('{0} [{1}]: {2}' -f $e.name, $e.status, $e.message) }
        elseif ($e.Contains('key') -and $State.packages.ContainsKey($e.key) -and $State.packages[$e.key].ContainsKey('shortcutFailed') -and $State.packages[$e.key].shortcutFailed) { $followUp += ('{0} [shortcut]: {1}' -f $e.name, $e.message) }
        elseif ($e.status -eq 'Succeeded' -and $e.detection -eq 'Unconfirmed') { $followUp += ('{0} [unconfirmed]: {1}' -f $e.name, $e.message) }
        # Outstanding work survives the end of the run: the recovery tool reads it from here.
        if ($e.lifecycle -notin 'Succeeded', 'AlreadySatisfied', 'SkippedByUser') {
            $outstanding += [ordered]@{ operationId = $e.operationId; name = $e.name; status = $e.status; lifecycle = $e.lifecycle; failureClass = $e.failureClass; retryable = $e.retryable; message = $e.message }
        }
    }
    $policy = Get-WdaRetryPolicy $Config
    $b = $State.bootstrap
    $result = [ordered]@{
        schemaVersion      = 2
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
        outstanding        = $outstanding
        retryPolicy        = [ordered]@{ automatic = $policy.automatic; maxAttempts = $policy.maxAttempts; baseDelaySeconds = $policy.baseDelaySeconds; maxDelaySeconds = $policy.maxDelaySeconds; jitterRatio = $policy.jitterRatio; continueAfterFailure = $policy.continueAfterFailure; maxNetworkDeferrals = $policy.maxNetworkDeferrals }
        recoveries         = @($State.recoveries)
        stateRecoveredFrom = [string] $State.recoveredFrom
    }
    # Phase 6: only when the deployment restores settings or migrates applications, so earlier results keep their shape.
    if (@(Get-WdaSettingsPlan $Config).Count) {
        $result.settings = $settings
        $result.settingsBackup = [ordered]@{ status = $(if ($State.backup) { [string] $State.backup['status'] } else { 'NotSearched' }); message = $(if ($State.backup) { [string] $State.backup['message'] } else { '' }) }
    }
    Write-WdaJson $Paths.Result $result
    if (@(Get-WdaSettingsPlan $Config).Count -or ($Config.ContainsKey('migration') -and $Config['migration'] -is [hashtable])) {
        try { Write-WdaJson $Paths.Restoration (Get-WdaRestoration $Config $State $Status $packages $settings) } catch { Write-WdaLog "Could not write restoration.json: $($_.Exception.Message)" 'WARN' }
    }
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

<#
    The structured restoration result (restoration.json, Phase 6): for every application of the
    migration plan and every settings adapter, one outcome from a fixed vocabulary:
      InstalledSuccessfully, AlreadyInstalled, ConfigurationRestored, ConfigurationPartiallyRestored,
      KeptExisting, ManualActionRequired, WaitingForUser, WaitingForBackup, BlockedByDependency,
      Unsupported, Failed, SkippedByUser, Pending.
    Read by people (follow-up), the deployment report and the later health verification.
#>
function Get-WdaRestoration {
    param([hashtable] $Config, [hashtable] $State, [string] $Status, [object[]] $Packages, [object[]] $Settings)
    $appOutcome = @{ Succeeded = 'InstalledSuccessfully'; AlreadyInstalled = 'AlreadyInstalled'; SkippedByUser = 'SkippedByUser'; RequiresInteraction = 'ManualActionRequired'
                     RequiresRestart = 'ManualActionRequired'; Skipped = 'BlockedByDependency'; Failed = 'Failed'; Unavailable = 'Failed'; Pending = 'Pending'; Installing = 'Pending' }
    $mig = $(if ($Config.ContainsKey('migration') -and $Config['migration'] -is [hashtable]) { $Config['migration'] } else { @{} })
    $apps = @()
    foreach ($m in @($mig['applications'])) {
        if ($m -isnot [hashtable]) { continue }
        $key = ([string] $m['key']).ToLowerInvariant()
        $decision = [string] $m['decision']
        $o = 'Unsupported'; $detail = ''
        if ($decision -eq 'exclude') { $o = 'SkippedByUser'; $detail = 'Excluded from this migration.' }
        elseif ($key -like 'additional:*' -and $State.additional.ContainsKey($key.Substring(11))) { $x = $State.additional[$key.Substring(11)]; $o = $(if ($appOutcome.ContainsKey($x.status)) { $appOutcome[$x.status] } else { 'Pending' }); $detail = [string] $x.message }
        elseif ($key -and $State.packages.ContainsKey($key)) { $x = $State.packages[$key]; $o = $(if ($appOutcome.ContainsKey($x.status)) { $appOutcome[$x.status] } else { 'Pending' }); $detail = [string] $x.message }
        elseif ($decision -eq 'optional') { $o = 'SkippedByUser'; $detail = 'Kept as optional and not selected for this deployment.' }
        elseif ($decision -eq 'manual') { $o = 'ManualActionRequired'; $detail = 'Install it by hand (no unattended installation is available).' }
        else { $detail = 'No supported installation method.' }
        $apps += , [ordered]@{ inventoryId = [string] $m['inventoryId']; displayName = [string] $m['displayName']; decision = $decision; key = $key; outcome = $o; detail = $detail }
    }
    $set = @($Settings | ForEach-Object { [ordered]@{ adapterId = $_.id; name = $_.name; outcome = $(if ($_.restoreOutcome) { $_.restoreOutcome } else { 'Pending' }); detail = $_.message; items = @($_.items); followUps = @($_.followUps); attempts = $_.totalAttempts } })
    $counts = [ordered]@{}
    foreach ($x in @($apps) + @($set)) { $k = [string] $x.outcome; if ($counts.Contains($k)) { $counts[$k]++ } else { $counts[$k] = 1 } }
    $plan = $(if ($Config.ContainsKey('settingsRestore')) { $Config['settingsRestore'] } else { $null })
    [ordered]@{
        format        = 'windows-deployment-builder/restoration-result'
        formatVersion = 1
        generatedUtc  = (Get-WdaNow).ToString('o')
        stageStatus   = $Status
        inventoryId   = [string] $mig['inventoryId']
        backupId      = $(if ($plan -is [hashtable]) { [string] $plan['backupId'] } else { '' })
        backup        = [ordered]@{ status = $(if ($State.backup) { [string] $State.backup['status'] } elseif ($plan) { 'NotSearched' } else { 'None' }); message = $(if ($State.backup) { [string] $State.backup['message'] } else { '' }) }
        applications  = @($apps)
        settings      = @($set)
        followUps     = @(@($mig['followUps']) | Where-Object { $_ } | ForEach-Object { [string] $_ } | Select-Object -First 300)
        counts        = $counts
    }
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
    # Phase 5: a success WinGet reported but winget list cannot confirm is not a silent success.
    if (@($State.packages.Values | Where-Object { $_.status -eq 'Succeeded' -and $_['detection'] -eq 'Unconfirmed' }).Count) { return 'CompletedWithFollowUp' }
    # Phase 6: settings restore operations (counted on their own; the package counts are unchanged).
    $settings = @($State.settings.Values)
    if (@($settings | Where-Object { $_.status -eq 'Failed' }).Count) { return 'CompletedWithFailures' }
    if (@($settings | Where-Object { $_.status -notin 'Succeeded', 'AlreadyInstalled', 'SkippedByUser' -or $_['restoreOutcome'] -eq 'ConfigurationPartiallyRestored' }).Count) { return 'CompletedWithFollowUp' }
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
            $e.failureClass = 'Manual'
            Set-WdaPackage $e 'RequiresInteraction' "Manual follow-up: install from $where$hash."
            continue
        }
        $file = Join-Path $Paths.Installers ([string] $a.fileName)
        if (-not $a.fileName -or -not (Test-Path -LiteralPath $file)) {
            $e.failureClass = 'Manual'
            Set-WdaPackage $e 'RequiresInteraction' "Installer not supplied: place $($a.fileName) in $($Paths.Installers) and run the installer again."
            continue
        }
        $actual = Get-WdaFileHash $file
        if ($actual -ne ([string] $a.sha256).ToUpperInvariant()) {
            $e.failureClass = 'Integrity'
            Set-WdaPackage $e 'Failed' "SHA-256 mismatch (expected $($a.sha256), found $actual); not executed."
            continue
        }
        if ($a.installerType -in 'exe', 'msi' -and -not (Test-WdaSignature $file)) {
            $e.failureClass = 'Integrity'
            Set-WdaPackage $e 'Failed' 'No valid Authenticode signature; not executed.'
            continue
        }
        $lock = Enter-WdbInstallLock $Config.dataRoot 'Applications' ([int] $Config.lockWaitMinutes * 60)
        if (-not $lock) { return 'WaitingForLock' }
        try {
            $e.attempts = [int] $e.attempts + 1
            $e.totalAttempts = [int] $e.totalAttempts + 1
            Set-WdaPackage $e 'Installing'
            Save-WdaState $State $Paths
            $started = (Get-WdaNow).ToString('o')
            $code = Start-WdaInstaller $file ([string] $a.installerType) @($a.silentArgs) ([int] $Config.packageTimeoutMinutes)
            $e.failureClass = ''
            if ($null -eq $code) { $e.failureClass = 'Timeout'; Set-WdaPackage $e 'Failed' 'Timed out.' }
            elseif ($code -eq 0) { Set-WdaPackage $e 'Succeeded' 'Installed.' $code }
            elseif ($code -in 3010, 1641) { Set-WdaPackage $e 'Succeeded' 'Installed; a restart is required to finish.' $code }
            else { $e.failureClass = 'Unknown'; Set-WdaPackage $e 'Failed' "Installer exit code $code." $code }
            $e.retryable = ($e.status -eq 'Failed')
            Add-WdaAttempt $Paths $e @{ trigger = 'automatic'; attempt = [int] $e.totalAttempts; startUtc = $started; endUtc = (Get-WdaNow).ToString('o'); result = $e.status; exitCode = [string] $e.exitCode
                class = [string] $e.failureClass; countsTowardLimit = $true; nextAction = $(if ($e.status -eq 'Failed') { 'manual retry (recovery tool)' } else { 'none' }); rebootRequired = [bool] ($code -in 3010, 1641); message = $e.message }
        } finally {
            Exit-WdbInstallLock $lock
        }
        Write-WdaLog "  additional $($a.name): $($e.status) $($e.message)"
    }
    return $null
}

# ------------------------------------------------------------------------------------------------
# Phase 6: application settings restore (after the applications they belong to)
# ------------------------------------------------------------------------------------------------

<# Where a settings backup may be: the drop folder under the data root, then every ready drive. #>
function Get-WdaBackupCandidates {
    param([hashtable] $Config, [string] $FolderName)
    $out = @(Join-Path (Join-Path (Join-Path $Config.dataRoot 'Backup') 'incoming') $FolderName)
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        try { if (-not $d.IsReady -or [string] $d.DriveType -notin 'Removable', 'Fixed', 'Network') { continue } } catch { continue }
        $out += Join-Path $d.RootDirectory.FullName "WindowsDeployment\backups\$FolderName"
        $out += Join-Path $d.RootDirectory.FullName $FolderName
    }
    return $out
}

<# The staged backup holds personal settings: SYSTEM, Administrators and this user only. #>
function Protect-WdaBackupFolder {
    param([string] $Path)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Protect-WdaFolder $Path @('*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', "*$($sid):(OI)(CI)F")
}

function Protect-WdaFolder {
    param([string] $Root, [string[]] $Grant = @('*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX'))
    # Only the folder itself gets explicit entries; Windows propagates them to everything below.
    # Never icacls /T with (OI)(CI) grants: on files those entries are dropped, which leaves every
    # file protected with no entries at all, unreadable even for SYSTEM and Administrators.
    # No /C either: with it icacls exits with 0 even when it fails.
    & icacls.exe $Root /inheritance:r /grant:r @Grant /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed with exit code $LASTEXITCODE on $Root; the folder is not protected." }
    # Repairs what an earlier version left below (files protected with no entries, folders with a
    # protected copy of these entries): they inherit again. Deliberately private folders (settings
    # backups) have other entries and keep them.
    function Get-Entries { param($Acl) (@($Acl.Access | ForEach-Object { "$($_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value)=$([int] $_.FileSystemRights)" }) | Sort-Object) -join ';' }
    $own = Get-Entries (Get-Acl -LiteralPath $Root)
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -Attributes !ReparsePoint -ErrorAction SilentlyContinue)) {
        $damaged = $true
        try {
            $acl = Get-Acl -LiteralPath $item.FullName
            $e = Get-Entries $acl
            $damaged = $acl.AreAccessRulesProtected -and ($e -eq '' -or $e -eq $own)
        } catch { }
        if (-not $damaged) { continue }
        & icacls.exe $item.FullName /reset /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls /reset failed with exit code $LASTEXITCODE on $($item.FullName); the folder is not protected." }
    }
}

<#
    Finds the settings backup of the plan, identified only by its folder name and the SHA-256 of its
    manifest (pinned in the verified configuration), validates every file, copies it to
    <dataRoot>\Backup\<backupId> and validates the copy. A backup with any other hash, a modified
    file, a link or an unexpected path is rejected. Returns the validated staged backup or $null.
#>
function Invoke-WdaBackupStaging {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State)
    $plan = $Config['settingsRestore']
    if (-not @(Get-WdaSettingsPlan $Config).Count) { return $null }
    if (-not (Get-Command Test-WdbBackup -CommandType Function -ErrorAction SilentlyContinue)) {
        $State.backup = @{ status = 'LibraryMissing'; atUtc = (Get-WdaNow).ToString('o'); message = 'WdbMigration.ps1 is not among the engine files; settings cannot be restored.' }
        return $null
    }
    $target = Join-Path $Paths.Backup ([string] $plan['backupId'])
    if ($State.backup -and $State.backup['status'] -eq 'Staged' -and (Test-Path -LiteralPath $target)) {
        $v = Test-WdbBackup $target ([string] $plan['manifestSha256'])
        if ($v.Ok) { return $v }
        Write-WdaLog "The staged settings backup no longer validates ($($v.Problems -join ' ')); looking for it again." 'WARN'
    }
    $rejected = @()
    foreach ($c in @(Get-WdaBackupCandidates $Config ([string] $plan['folderName']))) {
        if (-not (Test-Path -LiteralPath (Join-Path $c 'backup-manifest.json'))) { continue }
        $v = Test-WdbBackup $c ([string] $plan['manifestSha256'])
        if (-not $v.Ok) { $rejected += $c; Write-WdaLog "Settings backup at $c rejected: $(@($v.Problems)[0])" 'WARN'; continue }
        try {
            $staged = Copy-WdbBackup $v $target
            Protect-WdaBackupFolder $target
        } catch { $rejected += $c; Write-WdaLog "Settings backup at $c could not be staged: $($_.Exception.Message)" 'WARN'; continue }
        $State.backup = @{ status = 'Staged'; source = $c; atUtc = (Get-WdaNow).ToString('o'); message = "Staged from $c and verified (manifest SHA-256 $($plan['manifestSha256']))." }
        Write-WdaLog "Settings backup $($plan['backupId']) staged from $c and verified."
        return $staged
    }
    $searches = $(if ($State.backup -and $State.backup.ContainsKey('searches')) { [int] $State.backup['searches'] + 1 } else { 1 })
    $State.backup = @{ status = $(if ($rejected.Count) { 'Invalid' } else { 'NotFound' }); atUtc = (Get-WdaNow).ToString('o'); searches = $searches
                       message = $(if ($rejected.Count) { "A backup named $($plan['folderName']) was found but did not validate (modified, incomplete or a different backup)." } else { "The settings backup $($plan['folderName']) was not found on any drive." }) }
    return $null
}

# Outcome of WdbMigration's Invoke-WdbAdapterRestore -> engine status, restoration outcome.
$script:SettingsOutcomes = @{
    Restored = @('Succeeded', 'ConfigurationRestored'); AlreadyRestored = @('Succeeded', 'ConfigurationRestored'); PartiallyRestored = @('Succeeded', 'ConfigurationPartiallyRestored')
    KeptExisting = @('AlreadyInstalled', 'KeptExisting'); SkippedByUser = @('SkippedByUser', 'SkippedByUser'); WaitingForUser = @('RequiresInteraction', 'WaitingForUser')
    ManualActionRequired = @('RequiresInteraction', 'ManualActionRequired'); Unsupported = @('Unavailable', 'Unsupported'); Failed = @('Failed', 'Failed')
}

<#
    Restores the settings of the plan, adapter by adapter, once their applications are installed:
      - an application that failed, was skipped or needs a person blocks its settings (retryable);
      - a missing or invalid backup is a manual action with instructions (recovery tool), never a guess;
      - "close the application" / "not registered yet" is retried a few times with backoff within the
        run, then becomes WaitingForUser (never retried indefinitely);
      - a restored operation is never repeated; an interrupted one only re-verifies what it wrote.
#>
function Invoke-WdaSettings {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State)
    $plan = @(Get-WdaSettingsPlan $Config)
    if (-not $plan.Count -or -not @($plan | Where-Object { $State.settings[$_.id].status -eq 'Pending' }).Count) { return $null }
    $policy = Get-WdaRetryPolicy $Config
    Set-WdaStatus 'RestoringSettings' '' $State
    $backup = Invoke-WdaBackupStaging $Config $Paths $State
    Save-WdaState $State $Paths
    $cfg = $Config['settingsRestore']
    $where = "the USB drive as WindowsDeployment\backups\$($cfg['folderName']) or to $(Join-Path $Paths.Backup 'incoming')"
    foreach ($a in $plan) {
        $e = $State.settings[$a.id]
        if ($e.status -ne 'Pending') { continue }
        $blocked = $null; $restart = $null
        foreach ($k in @($a.after)) {
            $d = $State.packages[$k]
            if (-not $d) { continue }
            if ($d.status -eq 'RequiresRestart') { $restart = $d.name }
            elseif ($d.status -notin 'Succeeded', 'AlreadyInstalled') { $blocked = $d.name }
        }
        if ($blocked -or $restart) {
            $e.failureClass = 'Dependency'; $e.retryable = $true; $e.restoreOutcome = 'BlockedByDependency'
            Set-WdaPackage $e 'Skipped' $(if ($blocked) { "Not restored: $blocked was not installed." } else { "Not restored yet: $restart needs a restart to finish." })
            continue
        }
        if (-not $backup) {
            $e.failureClass = 'User'; $e.retryable = $true; $e.restoreOutcome = $(if ($State.backup -and $State.backup['status'] -eq 'LibraryMissing') { 'Failed' } else { 'WaitingForBackup' })
            Set-WdaPackage $e 'RequiresInteraction' "$($State.backup['message']) Copy it to $where, then run Deployment recovery and choose Restore application settings (-Action RestoreSettings)."
            continue
        }
        for ($try = 1; ; $try++) {
            $e.attempts = [int] $e.attempts + 1
            $e.totalAttempts = [int] $e.totalAttempts + 1
            Set-WdaPackage $e 'Installing' "Restoring settings ($($a.conflict))."
            Save-WdaState $State $Paths
            $started = (Get-WdaNow).ToString('o')
            try {
                $r = Invoke-WdbAdapterRestore $backup $a.id $a.conflict -UndoRoot (Join-Path (Join-Path $Paths.Backup ([string] $cfg['backupId'])) 'before-restore') -InstallExtensions:$a.installExtensions
            } catch {
                $r = @{ Outcome = 'Failed'; Class = 'Transient'; Message = "Restore error: $($_.Exception.Message)"; Items = @(); FollowUps = @() }
            }
            $map = $script:SettingsOutcomes[[string] $r.Outcome]
            if (-not $map) { $map = @('Failed', 'Failed') }
            $e.items = @($r.Items); $e.followUps = @($r.FollowUps | Select-Object -First 20)
            $e.failureClass = $(if ($r.Class) { [string] $r.Class } elseif ($map[0] -eq 'RequiresInteraction') { 'Manual' } else { '' })
            $e.restoreOutcome = $map[1]
            $again = ($r.Outcome -eq 'WaitingForUser' -or ($r.Outcome -eq 'Failed' -and $e.failureClass -notin $script:PermanentClasses)) -and $policy.automatic -and $try -lt $policy.maxAttempts
            $e.retryable = ($map[0] -in 'Failed', 'RequiresInteraction') -and $e.restoreOutcome -ne 'ManualActionRequired' -and $e.failureClass -ne 'Integrity'
            Set-WdaPackage $e $(if ($again) { 'Pending' } else { $map[0] }) ([string] $r.Message)
            $wait = $(if ($again) { Get-WdaBackoffSeconds $policy $try } else { 0 })
            Add-WdaAttempt $Paths $e @{ trigger = 'automatic'; attempt = [int] $e.totalAttempts; startUtc = $started; endUtc = (Get-WdaNow).ToString('o'); result = [string] $r.Outcome; class = [string] $e.failureClass
                countsTowardLimit = $true; nextAction = $(if ($again) { "retry in $wait s" } elseif ($e.retryable) { 'recovery tool (RetryFailed)' } else { 'none' }); rebootRequired = $false; message = [string] $r.Message }
            Write-WdaLog "  settings $($a.name): $($r.Outcome). $($r.Message)" $(if ($map[0] -in 'Succeeded', 'AlreadyInstalled', 'SkippedByUser') { 'INFO' } else { 'WARN' })
            Save-WdaState $State $Paths
            if (-not $again) { break }
            Wait-Wda $wait
        }
    }
    return $null
}

<#
    Installs pending packages in queue order. Returns $null when the queue is done for this run, or
    an outcome string (Rebooting, WaitingForLock, WaitingForRestart, WaitingForNetwork, Finished:*)
    to stop.

    Phase 5: a failed attempt is classified (ConvertFrom-WdaExitCode). Retryable classes wait with
    bounded exponential backoff before the next attempt (nextAttemptUtc, kept across restarts); the
    loop waits for the earliest due retry within the run. A network-class failure is checked first
    (Get-WdaNetworkDiagnosis): if connectivity or the package source is really gone, the attempt is
    not held against the package; it is deferred (bounded by maxNetworkDeferrals) and the run stops
    with WaitingForNetwork, or, when only one source is unreachable, packages from other sources
    continue. Every iteration acts on a package or waits for one, and the loop has a hard bound.
#>
function Invoke-WdaQueue {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State, [object[]] $Queue)
    $policy = Get-WdaRetryPolicy $Config
    $blockedSources = @{}
    $guardMax = 2 * ([int] $policy.maxAttempts + [int] $policy.maxNetworkDeferrals + 2) * [Math]::Max(1, @($Queue).Count) + 10
    for ($guard = 0; $guard -lt $guardMax; $guard++) {
        $pending = @($Queue | Where-Object { $State.packages[$_.key].status -eq 'Pending' })
        if ($pending.Count -eq 0) { return $null }
        if (((Get-WdaNow) - (ConvertTo-WdaDate $State.installStartUtc)).TotalHours -ge [double] $Config.maxRuntimeHours) {
            # Budget exhausted: what is done stays done; the rest is reported and can be retried later.
            foreach ($p in $pending) {
                $e = $State.packages[$p.key]
                $e.failureClass = 'Budget'; $e.retryable = $true; $e.nextAttemptUtc = $null
                Set-WdaPackage $e 'Failed' ("Not installed: the application runtime limit ($($Config.maxRuntimeHours) h) was reached. $(if ([int] $e.attempts) { "Last: $($e.message)" })".Trim())
            }
            Write-WdaLog "Runtime limit ($($Config.maxRuntimeHours) h) reached; $($pending.Count) package(s) not installed." 'WARN'
            Save-WdaState $State $Paths
            return $null
        }
        $acted = $false
        $soonest = $null
        foreach ($p in $pending) {
            $e = $State.packages[$p.key]
            if ($e.status -ne 'Pending' -or $State.halted) { continue }
            # Dependencies first; a dependency that did not install makes this one Skipped.
            $blocked = $null; $waiting = $false
            foreach ($k in @($p.after)) {
                $d = $State.packages[$k]
                if (-not $d) { continue }
                if ($d.status -in 'Failed', 'Unavailable', 'RequiresInteraction', 'Skipped') { $blocked = $d.name }
                elseif ($d.status -notin 'Succeeded', 'AlreadyInstalled') { $waiting = $true }
            }
            if ($blocked) { $e.failureClass = 'Dependency'; $e.retryable = $true; Set-WdaPackage $e 'Skipped' "Not attempted: it needs $blocked, which was not installed."; $acted = $true; continue }
            if ($waiting) { continue }
            if ($p.interaction -eq 'required') {
                $e.failureClass = 'Manual'
                Set-WdaPackage $e 'RequiresInteraction' 'Marked as needing interaction; install it manually (winget install --id ... --interactive).'
                $acted = $true
                continue
            }
            if ($blockedSources.ContainsKey($p.source)) { continue }
            if ($e.nextAttemptUtc) {
                $due = ConvertTo-WdaDate $e.nextAttemptUtc
                if ($due -gt (Get-WdaNow)) { if (-not $soonest -or $due -lt $soonest) { $soonest = $due }; continue }
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
            $offline = $null
            $acted = $true
            try {
                $log = Join-Path $Paths.PackageLogs (($p.key -replace '[^A-Za-z0-9._+-]', '_') + '.log')
                # Idempotency: an application that is already there is never installed again.
                $installed = Test-WdaInstalled $p $log
                if ($installed -eq $true) {
                    if ($e.interrupted -or $e.attempts -gt 0) { Set-WdaPackage $e 'Succeeded' 'Installed (confirmed by winget list).' }
                    else { Set-WdaPackage $e 'AlreadyInstalled' 'Already installed before this run; left unchanged.' }
                    $e.detection = 'Installed'; $e.waitingFor = ''; $e.nextAttemptUtc = $null; $e.failureClass = ''; $e.retryable = $false
                    Complete-WdaPortable $p $e
                    Write-WdaLog "  $($e.status.ToLowerInvariant()) $($p.name)"
                    Save-WdaState $State $Paths
                    continue
                }
                if ([int] $e.attempts -ge [int] $policy.maxAttempts) {
                    $e.retryable = ([string] $e.failureClass) -notin $script:PermanentClasses
                    Set-WdaPackage $e 'Failed' "Gave up after $($e.attempts) attempt(s). Last: $($e.message)"
                    Save-WdaState $State $Paths
                    continue
                }
                # Count the attempt before acting, so a crash or hang mid-install still counts.
                $e.attempts = [int] $e.attempts + 1
                $e.totalAttempts = [int] $e.totalAttempts + 1
                $e.interrupted = $false; $e.waitingFor = ''; $e.nextAttemptUtc = $null
                Set-WdaPackage $e 'Installing' "Attempt $($e.attempts)."
                Save-WdaState $State $Paths
                Set-WdaStatus 'Installing' $p.name $State
                $started = Get-WdaNow
                # Engine 1.5.0: the retry after a hash mismatch starts from a freshly updated source.
                if ($e.ContainsKey('refreshSource') -and $e.refreshSource) { $e.refreshSource = $false; Update-WdaSource $p.source $log }
                Write-WdaLog ("  installing {0} ({1}:{2}) attempt {3}/{4}" -f $p.name, $p.source, $p.packageIdentifier, $e.attempts, $policy.maxAttempts)
                $r = Install-WdaPackage $p ([int] $Config.packageTimeoutMinutes) $log
                if ($r.TimedOut -and $p.interaction -eq 'mayPrompt') {
                    # An installer known to prompt that is still running after the timeout is most
                    # likely waiting for a person: another full timeout would not help.
                    $m = @{ Status = 'RequiresInteraction'; Retry = $false; Restart = 'none'; Message = "Did not finish within $($Config.packageTimeoutMinutes) min; this installer may wait for a person. Install it manually."; Code = 'timeout'; Class = 'User' }
                } elseif ($r.TimedOut) {
                    $m = @{ Status = 'Failed'; Retry = $true; Restart = 'none'; Message = "Timed out after $($Config.packageTimeoutMinutes) min."; Code = 'timeout'; Class = 'Timeout' }
                } else { $m = ConvertFrom-WdaExitCode $r.ExitCode }
                # Engine 1.5.0: an installer that refuses elevation runs once as the signed-in user without it.
                if ($m.Class -eq 'Elevation' -and $Config.userContextFallback -and -not ($e.ContainsKey('userContextTried') -and $e.userContextTried)) {
                    $e.userContextTried = $true
                    Write-WdaLog "  $($p.name): the installer refuses administrator rights; running it once as $((Get-WdaContext).User) without elevation."
                    Set-WdaStatus 'Installing' "$($p.name) (without administrator rights)" $State
                    $r2 = Install-WdaPackageAsUser $p ([int] $Config.packageTimeoutMinutes) $log
                    $e.installContext = 'user (not elevated)'
                    if ($r2.Error) {
                        $m = @{ Status = 'RequiresInteraction'; Retry = $false; Restart = 'none'; Message = "The installer refuses administrator rights, and running it without them failed ($($r2.Error)). Install it from a normal (non-administrator) session: winget install --id $($p.packageIdentifier) --exact."; Code = $m.Code; Class = 'Elevation' }
                    } elseif ($r2.TimedOut) {
                        $m = @{ Status = 'RequiresInteraction'; Retry = $false; Restart = 'none'; Message = "Run without administrator rights, it did not finish within $($Config.packageTimeoutMinutes) min; it may wait for a person. Install it from a normal session."; Code = 'timeout'; Class = 'User' }
                    } else {
                        $r = $r2
                        $m = ConvertFrom-WdaExitCode $r2.ExitCode
                        $m.Message = "$($m.Message) (run without administrator rights, as the installer requires)"
                        if ($m.Class -eq 'Elevation') { $m.Status = 'RequiresInteraction'; $m.Message = "$($m.Message). Install it from a normal (non-administrator) session." }
                    }
                }
                $installerCode = $(if ($r.ContainsKey('Output')) { Get-WdaInstallerExitCode ([string] $r.Output) } else { '' })
                if ($installerCode) { $e.installerExitCode = $installerCode; $m.Message = "$($m.Message) Installer exit code: $installerCode." }
                $status = $m.Status
                $counts = $true
                $next = ''
                if ($status -eq 'Failed' -and $m.Class -eq 'Network') {
                    $diag = Get-WdaNetworkDiagnosis $p.source
                    if ($diag.Level -ne 'Online') {
                        $e.networkDeferrals = [int] $e.networkDeferrals + 1
                        if ([int] $e.networkDeferrals -le [int] $policy.maxNetworkDeferrals) {
                            # Not the package's fault: the attempt is not held against it.
                            $e.attempts = [int] $e.attempts - 1
                            $counts = $false
                            $status = 'Pending'
                            $e.waitingFor = $(if ($diag.Level -eq 'SourceUnavailable') { "source:$($p.source)" } else { 'network' })
                            $m.Message = "$($m.Message) Network check: $($diag.Level) ($($diag.Detail)); deferred until it is reachable ($($e.networkDeferrals)/$($policy.maxNetworkDeferrals))."
                            if ($diag.Level -eq 'SourceUnavailable') { $blockedSources[$p.source] = $diag; $next = "wait for source $($p.source)" } else { $offline = $diag; $next = 'wait for network' }
                        } else {
                            $m.Message = "$($m.Message) Network check: $($diag.Level); already deferred $($policy.maxNetworkDeferrals) time(s)."
                        }
                    }
                }
                if ($status -eq 'Failed' -and $m.Retry -and [int] $e.attempts -lt [int] $policy.maxAttempts) {
                    $delay = Get-WdaBackoffSeconds $policy ([int] $e.attempts)
                    $e.nextAttemptUtc = (Get-WdaNow).AddSeconds($delay).ToString('o')
                    $status = 'Pending'
                    $next = "retry after $delay s"
                }
                # Engine 1.5.0: an installer hash mismatch usually means the publisher replaced the installer
                # before the WinGet manifest was updated. One retry later, from a refreshed source; the hash
                # is still verified (WinGet's option to skip the hash check is never used). A second mismatch is final.
                if ($status -eq 'Failed' -and $m.Code -eq '0x8A150011' -and [int] $Config.integrityRetryMinutes -gt 0 -and -not ($e.ContainsKey('integrityRetried') -and $e.integrityRetried) -and [int] $e.attempts -lt [int] $policy.maxAttempts) {
                    $e.integrityRetried = $true; $e.refreshSource = $true
                    $e.nextAttemptUtc = (Get-WdaNow).AddMinutes([int] $Config.integrityRetryMinutes).ToString('o')
                    $status = 'Pending'
                    $next = "retry in $($Config.integrityRetryMinutes) min after refreshing the WinGet source"
                    $m.Message = "$($m.Message) The published hash often lags behind a new installer release: the source is refreshed and it is tried once more in $($Config.integrityRetryMinutes) min. The hash check still applies."
                }
                if ($status -eq 'Succeeded') {
                    # Do not rely on the exit code alone.
                    $check = Test-WdaInstalled $p $log
                    $e.detection = $(if ($check -eq $true) { 'Installed' } elseif ($check -eq $false) { 'Unconfirmed' } else { 'Unknown' })
                    if ($check -eq $false) { $m.Message = 'WinGet reported success, but winget list does not show the package; verify it manually.' }
                }
                if ($status -eq 'AlreadyInstalled') { $e.detection = 'Installed' }
                if ($status -eq 'RequiresRestart') {
                    $e.restart = $(if ($m.Restart -eq 'later') { 'verify' } else { 'retry' })
                    $e.detection = $(if ($m.Restart -eq 'later') { 'InstalledRequiresRestart' } else { 'NotInstalled' })
                    if ($m.Restart -in 'now', 'initiated') { $restartNow = $m.Restart }
                }
                $e.failureClass = $(if ($status -in 'Succeeded', 'AlreadyInstalled', 'RequiresRestart') { '' } else { [string] $m.Class })
                $e.retryable = ($status -in 'Failed', 'Pending') -and ([string] $m.Class) -notin $script:PermanentClasses
                Set-WdaPackage $e $status $m.Message $m.Code
                if ($status -in 'Succeeded', 'AlreadyInstalled') { Complete-WdaPortable $p $e }
                if (-not $next) {
                    $next = switch ($status) {
                        'Succeeded' { 'none' } 'AlreadyInstalled' { 'none' } 'RequiresRestart' { 'restart' }
                        'RequiresInteraction' { 'manual action' }
                        default { $(if ($e.retryable) { 'manual retry (recovery tool)' } else { 'none (permanent)' }) }
                    }
                }
                if ($status -in 'Failed', 'Unavailable', 'RequiresInteraction') {
                    # What the progress window and the LAN monitor show; the queue carries on.
                    $State.lastFailure = [ordered]@{ name = $p.name; status = $status; code = [string] $m.Code; installerExitCode = $installerCode; atUtc = (Get-WdaNow).ToString('o')
                        message = $(if ($status -eq 'RequiresInteraction') { "$($p.name) needs a person to install it. Recorded; deployment is continuing with the remaining applications." } else { "$($p.name) could not be installed ($($m.Message.TrimEnd('.'))). The failure was recorded; deployment is continuing with the remaining applications." }) }
                } elseif ($status -eq 'Pending' -and $e.nextAttemptUtc) {
                    $State.lastFailure = [ordered]@{ name = $p.name; status = 'Retrying'; code = [string] $m.Code; installerExitCode = $installerCode; atUtc = (Get-WdaNow).ToString('o')
                        message = "$($p.name): attempt $($e.attempts) of $($policy.maxAttempts) failed ($($m.Message.TrimEnd('.'))); $next. The other applications continue." }
                }
                if ($status -in 'Failed', 'Unavailable', 'RequiresInteraction' -or ($status -eq 'Pending' -and $e.nextAttemptUtc)) {
                    Add-WdbActivity $Config.dataRoot 'applications' ([string] $State.lastFailure['message']) $(if ($State.lastFailure['status'] -eq 'Retrying') { 'info' } else { 'warning' })
                }
                Add-WdaAttempt $Paths $e @{ trigger = 'automatic'; attempt = [int] $e.totalAttempts; startUtc = $started.ToString('o'); endUtc = (Get-WdaNow).ToString('o')
                    result = [string] $m.Status; exitCode = [string] $m.Code; installerExitCode = $installerCode; class = [string] $m.Class; countsTowardLimit = $counts; nextAction = $next
                    nextAttemptUtc = $e.nextAttemptUtc; rebootRequired = [bool] ($status -eq 'RequiresRestart'); message = $m.Message; packageIdentifier = $p.packageIdentifier; source = $p.source }
                $lvl = $(if ($status -in 'Succeeded', 'AlreadyInstalled') { 'INFO' } else { 'WARN' })
                Write-WdaLog ("  -> {0} {1} [{2}] {3} (class {4}; attempt {5}/{6}; next: {7})" -f $status, $p.name, $m.Code, $m.Message, $m.Class, $e.attempts, $policy.maxAttempts, $next) $lvl
                Save-WdaState $State $Paths
            } finally {
                Exit-WdbInstallLock $lock
            }
            if ($offline) {
                Write-WdaLog "Connectivity lost ($($offline.Level): $($offline.Detail)); progress is kept and the run continues when the network is back." 'WARN'
                Set-WdaStatus 'WaitingForNetwork' "Connectivity lost: $($offline.Level)" $State
                return 'WaitingForNetwork'
            }
            if ($e.status -eq 'Failed' -and -not $policy.continueAfterFailure) {
                $State.halted = $p.name
                Write-WdaLog "Stopping the queue after $($p.name) failed ('continue after a failure' is off)." 'WARN'
                Save-WdaState $State $Paths
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
        if ($acted) { continue }
        if ($soonest) {
            $wait = [int] [Math]::Min([double] $policy.maxDelaySeconds, [Math]::Max(1, [Math]::Ceiling(($soonest - (Get-WdaNow)).TotalSeconds)))
            Write-WdaLog "Next retry in $wait s."
            Set-WdaStatus 'WaitingForRetry' "Next retry at $($soonest.ToString('o'))" $State
            Wait-Wda $wait
            continue
        }
        break
    }
    $left = @($Queue | Where-Object { $State.packages[$_.key].status -eq 'Pending' })
    if ($left.Count -and ($blockedSources.Count -or @($left | Where-Object { $State.packages[$_.key].waitingFor }).Count)) {
        $names = ($blockedSources.Keys | Sort-Object) -join ', '
        Write-WdaLog "Package source(s) unreachable ($names); $($left.Count) package(s) wait for the next run." 'WARN'
        Set-WdaStatus 'WaitingForNetwork' "Package source unreachable: $names" $State
        Save-WdaState $State $Paths
        return 'WaitingForNetwork'
    }
    foreach ($p in $left) {
        $e = $State.packages[$p.key]
        if ($State.halted) { Set-WdaPackage $e 'Pending' "Not attempted: application setup stopped after $($State.halted) failed ('continue after a failure' is off). Retry it with the recovery tool." }
        else { $e.retryable = $true; Set-WdaPackage $e 'Failed' "Gave up after $($e.attempts) attempt(s). Last: $($e.message)" }
    }
    return $null
}

# ------------------------------------------------------------------------------------------------
# Technician recovery (Retry mode)
# ------------------------------------------------------------------------------------------------

<#
    Reopens operations for another run, under the engine's own mutex so it never races a running
    engine. Only operations of this deployment's configuration are eligible (the permitted set):
    queued WinGet/Store/portable packages and reviewed Additional Software. Never eligible:
    deselected apps, manual catalog entries, unresolved or invalid identifiers, anything already
    installed. Permanent failures (integrity, policy, cancelled, not found ...) need
    -IncludePermanent, i.e. a technician who has corrected the cause; their checks still apply on the
    next attempt because the engine installs exactly as before. Dependencies that did not install are
    reopened together with what needs them. Each reopened operation gets a fresh attempt budget; its
    history, total attempts and the previous result are kept.
#>
function Invoke-WdaRetry {
    param([hashtable] $Config, [string[]] $Operations = @(), [switch] $AllFailed, [switch] $PendingOnly, [switch] $IncludePermanent, [string] $RequestedBy = '')
    $paths = Get-WdaPaths $Config
    foreach ($d in $paths.Root, $paths.Logs, $paths.PackageLogs) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
    $script:LogFile = $paths.Log
    $script:StatusFile = $paths.Status
    $mutex = Enter-WdaMutex $Config.mutexName
    if (-not $mutex) { return @{ Outcome = 'Busy'; Accepted = @(); Refused = @(); Message = 'The application engine is running; try again when it has stopped.' } }
    try {
        if (-not (Test-Path -LiteralPath $paths.State) -and -not (Test-Path -LiteralPath "$($paths.State).bak")) {
            return @{ Outcome = 'NoState'; Accepted = @(); Refused = @(); Message = 'The application stage has not run on this computer yet.' }
        }
        $State = Read-WdaState $paths
        $queue = Get-WdaQueue $Config
        Initialize-WdaEntries $Config $State $queue
        $byKey = @{}
        foreach ($p in $queue) { $byKey[$p.key] = $p }
        $automatic = @{}
        foreach ($a in @($Config.additionalSoftware)) { if ($a.execution -eq 'automatic') { $automatic[[string] $a.id] = $true } }

        # Eligibility of one operation id: $null (eligible) or a refusal reason.
        $why = {
            param([string] $Id)
            if ($Id -cmatch '^app:(winget|msstore):[a-z0-9][a-z0-9._+-]{0,127}$') {
                $k = $Id.Substring(4)
                $e = $State.packages[$k]
                if (-not $e) { return 'not part of this deployment' }
                if (-not $byKey.ContainsKey($k)) {
                    if ($e.status -eq 'SkippedByUser') { return 'explicitly deselected for this deployment' }
                    return "not installable by the engine ($($e.status): $($e.message))"
                }
                $bad = Test-WdaPackageSpec $byKey[$k]
                if ($bad) { return "invalid package definition: $bad" }
                if ($byKey[$k].interaction -eq 'required') { return 'needs interaction; install it manually' }
                $life = Get-WdaLifecycle $e
                if ($life -in 'Succeeded', 'AlreadySatisfied') { return 'already installed' }
                if ($life -eq 'Running') { return 'an installation is in progress' }
                if ($life -eq 'WaitingForReboot') { return 'waiting for a restart; restart the computer first' }
                if ($life -eq 'FailedPermanent' -and -not $IncludePermanent) { return "permanent failure ($($e.failureClass)): correct the cause, then retry with -IncludePermanent" }
                return $null
            }
            if ($Id -cmatch '^settings:[a-z0-9][a-z0-9-]{0,31}$') {
                $e = $State.settings[$Id.Substring(9)]
                if (-not $e) { return 'not part of this deployment' }
                if ($e.status -in 'Succeeded', 'AlreadyInstalled') { return 'already restored (or the existing settings were kept by the conflict policy)' }
                if ($e.status -eq 'SkippedByUser') { return 'skipped by the conflict policy' }
                if ($e.status -eq 'Unavailable') { return 'the backup has no settings for it' }
                if ($e.status -eq 'Installing') { return 'a restore is in progress' }
                if ($e['restoreOutcome'] -eq 'ManualActionRequired') { return 'needs manual action: review the restored files' }
                if ($e.failureClass -eq 'Integrity' -and -not $IncludePermanent) { return 'the backup failed verification: supply the correct backup, then retry with -IncludePermanent' }
                return $null
            }
            if ($Id -cmatch '^additional:[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
                $k = $Id.Substring(11)
                $e = $State.additional[$k]
                if (-not $e) { return 'not part of this deployment' }
                if (-not $automatic.ContainsKey($k)) { return 'manual follow-up; install it by hand' }
                if ($e.status -eq 'Succeeded') { return 'already installed' }
                if ($e.status -eq 'Failed' -and ([string] $e.failureClass) -in $script:PermanentClasses -and -not $IncludePermanent) { return 'permanent failure (hash or signature): supply the correct installer, then retry with -IncludePermanent' }
                return $null
            }
            return 'not a valid operation id'
        }

        $targets = New-Object System.Collections.Generic.List[string]
        if ($AllFailed -or $PendingOnly) {
            foreach ($e in @($State.packages.Values)) {
                $life = Get-WdaLifecycle $e
                $want = $(if ($PendingOnly) { $e.status -eq 'Pending' } else { ($life -in @('FailedRetryable', 'BlockedByDependency', 'WaitingForNetwork', 'Pending')) -or ($IncludePermanent -and $life -eq 'FailedPermanent') })
                if ($want -and $byKey.ContainsKey($e.key)) { $targets.Add($e.operationId) }
            }
            if (-not $PendingOnly) { foreach ($e in @($State.additional.Values)) { if ($e.status -in 'Failed', 'Pending' -and $automatic.ContainsKey([string] $e.id)) { $targets.Add($e.operationId) } } }
            foreach ($e in @($State.settings.Values)) {
                $want = $(if ($PendingOnly) { $e.status -eq 'Pending' } else { $e.status -in 'Pending', 'Skipped' -or ($e.status -eq 'Failed' -and ($IncludePermanent -or $e.failureClass -ne 'Integrity')) -or ($e.status -eq 'RequiresInteraction' -and $e['restoreOutcome'] -in 'WaitingForUser', 'WaitingForBackup') })
                if ($want) { $targets.Add($e.operationId) }
            }
        }
        foreach ($o in @($Operations | Where-Object { $_ })) {
            $id = ([string] $o).Trim()
            if ($id -notmatch '^(app|additional|settings):') { $id = "app:$id" }
            if ($id.StartsWith('app:')) { $id = $id.ToLowerInvariant() }
            if (-not $targets.Contains($id)) { $targets.Add($id) }
        }
        $accepted = New-Object System.Collections.Generic.List[string]
        $refused = @()
        # Unmet dependencies are reopened with the operations that need them (dependency first).
        for ($i = 0; $i -lt $targets.Count; $i++) {
            $id = $targets[$i]
            $reason = & $why $id
            if ($reason) { $refused += @{ operationId = $id; reason = $reason }; continue }
            if ($id.StartsWith('app:')) {
                foreach ($dep in @($byKey[$id.Substring(4)].after)) {
                    $d = $State.packages[$dep]
                    if (-not $d -or $d.status -in 'Succeeded', 'AlreadyInstalled') { continue }
                    $dr = & $why "app:$dep"
                    if ($dr) { $reason = "its dependency $($d.name) cannot be retried ($dr)"; break }
                    if (-not $targets.Contains("app:$dep")) { $targets.Add("app:$dep") }
                }
                if ($reason) { $refused += @{ operationId = $id; reason = $reason }; continue }
            }
            if (-not $accepted.Contains($id)) { $accepted.Add($id) }
        }
        if ($accepted.Count -eq 0) {
            return @{ Outcome = $(if ($targets.Count) { 'Refused' } else { 'NothingToRetry' }); Accepted = @(); Refused = $refused; Message = 'No operation was reopened.' }
        }
        $now = (Get-WdaNow).ToString('o')
        foreach ($id in $accepted) {
            $e = $(if ($id.StartsWith('app:')) { $State.packages[$id.Substring(4)] } elseif ($id.StartsWith('settings:')) { $State.settings[$id.Substring(9)] } else { $State.additional[$id.Substring(11)] })
            $previous = "$($e.status): $($e.message)"
            Add-WdaAttempt $paths $e @{ trigger = 'manual'; attempt = [int] $e.totalAttempts; startUtc = $now; endUtc = $now; result = 'Reopened'; exitCode = [string] $e.exitCode
                class = [string] $e.failureClass; countsTowardLimit = $false; nextAction = 'retry'; nextAttemptUtc = $null; rebootRequired = $false
                message = "Retry requested$(if ($RequestedBy) { " by $RequestedBy" }). Previous: $previous" }
            $e.manualRetries = [int] $e.manualRetries + 1
            $e.attempts = 0; $e.networkDeferrals = 0; $e.nextAttemptUtc = $null; $e.waitingFor = ''; $e.interrupted = $false; $e.failureClass = ''; $e.retryable = $false
            if ($id.StartsWith('settings:')) { $e.restoreOutcome = 'Pending' }
            Set-WdaPackage $e 'Pending' "Retry requested$(if ($RequestedBy) { " by $RequestedBy" }) (previous: $previous)"
        }
        # The stage runs again with a fresh time budget; its previous result is kept in history\.
        if (Test-Path -LiteralPath $paths.Result) {
            $hist = Join-Path $paths.Root 'history'
            if (-not (Test-Path -LiteralPath $hist)) { New-Item -ItemType Directory -Path $hist -Force | Out-Null }
            Move-Item -LiteralPath $paths.Result -Destination (Join-Path $hist ("result-{0}.json" -f (Get-WdaNow).ToString('yyyyMMddHHmmss'))) -Force
        }
        if (Test-Path -LiteralPath $paths.Marker) { Remove-Item -LiteralPath $paths.Marker -Force }
        if (-not $State.originalStartUtc) { $State.originalStartUtc = $State.firstStartUtc }
        $State.final = $null
        $State.halted = ''
        $State.errors = 0
        $State.firstStartUtc = $now
        $State.installStartUtc = $null
        $State.recoveries = @(@($State.recoveries) + @(@{ atUtc = $now; by = $RequestedBy; mode = $(if ($PendingOnly) { 'resume' } elseif ($AllFailed) { 'retryFailed' } else { 'retry' }); accepted = @($accepted); refused = @($refused | ForEach-Object { $_.operationId }); includePermanent = [bool] $IncludePermanent }))
        Save-WdaState $State $paths
        Write-WdaLog ("Recovery: reopened {0} operation(s){1}: {2}. Refused: {3}." -f $accepted.Count, $(if ($RequestedBy) { " for $RequestedBy" }), ($accepted -join ', '), $(if ($refused.Count) { ($refused | ForEach-Object { "$($_.operationId) ($($_.reason))" }) -join '; ' } else { 'none' })) 'WARN'
        Set-WdaStatus 'Pending' "Recovery reopened $($accepted.Count) operation(s)" $State
        return @{ Outcome = 'Accepted'; Accepted = @($accepted); Refused = $refused; Message = "Reopened $($accepted.Count) operation(s)." }
    } finally {
        Exit-WdaMutex $mutex
    }
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
    Resume-WdaEntries $State $Paths
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
    # Phase 6: stage the settings backup early, while the installation drive is most likely attached.
    if (@(Get-WdaSettingsPlan $Config).Count -and -not ($State.backup -and $State.backup['status'] -eq 'Staged')) { [void] (Invoke-WdaBackupStaging $Config $Paths $State); Save-WdaState $State $Paths }

    # 2. Gate: Windows Update first.
    $polls = [int] $Config.gatePollMinutes
    for ($i = 0; ; $i++) {
        $gate = Get-WdaUpdatesGate $Config $State
        # Phase 8: then the driver stage (only when the configuration has one).
        if ($gate.Open) { $dg = Get-WdaDriversGate $Config $State; if (-not $dg.Open -or $dg.ContainsKey('Warn') -or $dg.Reason -notlike 'The driver stage is not part*') { $gate = $dg } }
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

    # 6. Phase 6: restore supported application settings, now that their applications are installed.
    $out = Invoke-WdaSettings $Config $Paths $State
    if ($out) { Save-WdaState $State $Paths; return $out }
    Save-WdaState $State $Paths

    $final = Get-WdaFinalStatus $State
    $reason = switch ($final) {
        'Succeeded' { 'Every selected application is installed.' }
        'CompletedWithFollowUp' { 'Some applications need manual follow-up (interaction, a restart or a manual check).' }
        default { 'Some applications could not be installed.' }
    }
    if (@($State.packages.Values | Where-Object { $_['failureClass'] -eq 'Budget' }).Count) { $reason += " The runtime limit ($($Config.maxRuntimeHours) h) was reached." }
    if ($State.halted) { $reason += " Stopped after $($State.halted) failed (continue after a failure is off)." }
    if ($final -ne 'Succeeded') { $reason += ' Failed and unfinished applications can be retried with the deployment recovery tool.' }
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
        $action = if ($bad) { "Unavailable: $bad" } elseif ($p.interaction -eq 'required') { 'RequiresInteraction (not attempted)' } elseif ($installed -eq 'yes') { 'AlreadyInstalled (skip)' } elseif ($available -eq 'NotFound') { 'Unavailable' } elseif ($p.method -eq 'portable') { "Install (portable) + shortcut $($p.portable.shortcut)" } else { 'Install' }
        $rows += [pscustomobject]@{ '#' = $n; Name = $p.name; Source = $p.source; Id = $p.packageIdentifier; Installed = $installed; Available = $available; Action = $action
                                    Command = $(if ($bad) { '' } else { 'winget ' + ((Get-WdaArguments 'install' $p) -join ' ') }) }
    }
    foreach ($u in @($Config.unresolved)) { $rows += [pscustomobject]@{ '#' = ''; Name = $u.displayName; Source = $u.source; Id = $u.packageIdentifier; Installed = ''; Available = ''; Action = "Unavailable: $($u.reason)"; Command = '' } }
    foreach ($m in @($Config.manual)) { $rows += [pscustomobject]@{ '#' = ''; Name = $m.displayName; Source = 'manual'; Id = $m.key; Installed = ''; Available = ''; Action = "Manual action required: $($m.instructions)"; Command = '' } }
    foreach ($d in @($Config.deselected)) { $rows += [pscustomobject]@{ '#' = ''; Name = $d.displayName; Source = $d.source; Id = $d.packageIdentifier; Installed = ''; Available = ''; Action = 'SkippedByUser (deselected)'; Command = '' } }
    foreach ($a in @($Config.additionalSoftware)) { $rows += [pscustomobject]@{ '#' = ''; Name = $a.name; Source = 'additional'; Id = $a.fileName; Installed = ''; Available = ''; Action = $(if ($a.execution -eq 'automatic') { 'Reviewed installer (hash + signature checked)' } else { 'Manual follow-up' }); Command = '' } }
    [pscustomobject]@{ WinGet = $b; Rows = $rows; Paths = $paths }
}

# Dot-sourcing (tests) only defines the functions.
if ($MyInvocation.InvocationName -ne '.') {
    $engineMode = $Mode
    $cfg = Get-WdaConfig $ConfigPath
    . (Join-Path $PSScriptRoot 'WinGetBootstrap.ps1')
    # Phase 6: the settings restore library (present when the deployment restores settings).
    $migrationLibrary = Join-Path $PSScriptRoot 'WdbMigration.ps1'
    if (Test-Path -LiteralPath $migrationLibrary) { . $migrationLibrary -Mode Library }
    if ($engineMode -eq 'Retry') {
        $who = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $r = Invoke-WdaRetry $cfg -Operations $Operation -AllFailed:$AllFailed -PendingOnly:$PendingOnly -IncludePermanent:$IncludePermanent -RequestedBy $who
        [pscustomobject]$r | ConvertTo-Json -Depth 5
        if ($r.Outcome -eq 'Accepted') { exit 0 }
        exit 1
    }
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
