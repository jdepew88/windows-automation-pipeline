#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Deployment Builder - shared functions of the deployment orchestrator.

.DESCRIPTION
    Dot-sourced by Stage-Deployment.ps1, Initialize-Deployment.ps1, DeploymentOrchestrator.ps1,
    Show-DeploymentStatus.ps1, Resume-Deployment.ps1 and Complete-Deployment.ps1. Defines functions
    only; it never acts by itself.

    Everything that touches the system (scheduled tasks, ACLs, processes, shortcuts, the event log,
    time, identity) is a small adapter function, so tests can replace it with a simulation.

    The orchestrator coordinates; it does not install. Windows Update and applications are
    installed by the existing engines (WindowsUpdateEngine.ps1 as SYSTEM, ApplicationEngine.ps1 as
    the signed-in user), each from its own scheduled task. The orchestrator launches each engine's
    installer once, follows their real result files and writes one deployment status and report.

    Phase 5 (orchestrator 1.1.0): state files are replaced atomically with a backup of the last good
    copy (Read-WddDeploymentState falls back to it and never mistakes a damaged state for "no
    deployment"), and every snapshot carries a machine-readable outcome with a stable exit code
    (Get-WddDeploymentOutcome) for DeploymentRecovery.ps1 and later health reporting.
#>

Set-StrictMode -Version 2.0

$script:DeployVersion = '1.1.0'
$script:DeployStateVersion = 2
$script:EventSource = 'WindowsDeploymentBuilder'
$script:ManifestFormat = 'windows-deployment-builder/deployment-manifest'
$script:MutexName = 'Global\WindowsDeploymentBuilder-Deployment'
$script:FinalStageStatuses = @('Succeeded', 'CompletedWithFollowUp', 'CompletedWithFailures', 'Failed', 'Offline')
$script:WddLogFile = $null

# ------------------------------------------------------------------------------------------------
# Adapters (replaced by the scenario tests)
# ------------------------------------------------------------------------------------------------

function Get-WddNow { [DateTime]::UtcNow }

function Get-WddIdentity {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    @{ Name = $id.Name; IsSystem = ($id.User.Value -eq 'S-1-5-18'); IsAdmin = $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
}

# Windows PE (the installation environment) must never run the orchestrator.
function Test-WddWinPE { (Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT') -or ($env:SystemDrive -eq 'X:') }

function Get-WddTask {
    param([string] $TaskPath, [string] $TaskName)
    $null -ne (Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue)
}

function Unregister-WddTask {
    param([string] $TaskPath, [string] $TaskName)
    Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
}

function Start-WddTask {
    param([string] $TaskPath, [string] $TaskName)
    Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
}

function Get-WddBootTime { (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime.ToUniversalTime() }

function Write-WddEvent {
    param([int] $EventId, [string] $Message, [ValidateSet('Information', 'Warning', 'Error')] [string] $EntryType = 'Information')
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($script:EventSource)) { New-EventLog -LogName Application -Source $script:EventSource }
        Write-EventLog -LogName Application -Source $script:EventSource -EventId $EventId -EntryType $EntryType -Message $Message
    } catch {
        Write-WddLog "Could not write event $EventId to the Application log: $($_.Exception.Message)" 'WARN'
    }
}

function New-WddShortcut {
    param([string] $Name, [string] $Target, [string] $Arguments, [string] $Description)
    $path = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) "$Name.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($path)
    $lnk.TargetPath = $Target
    $lnk.Arguments = $Arguments
    $lnk.Description = $Description
    $lnk.Save()
}

function Remove-WddShortcut {
    param([string] $Name)
    $path = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) "$Name.lnk"
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

# ------------------------------------------------------------------------------------------------
# JSON, logging, paths
# ------------------------------------------------------------------------------------------------

function ConvertTo-WddHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-WddHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-WddHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return , @($InputObject | ForEach-Object { ConvertTo-WddHashtable $_ })
    }
    return $InputObject
}

<#
    Atomic write: <Path>.tmp is written through to disk, then replaces <Path> in one file-system
    operation; -Backup keeps the replaced file as <Path>.bak (the last good copy).
#>
function Write-WddJson {
    param([string] $Path, $Value, [switch] $Backup)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
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
            if ($Backup) { Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force }
        }
    }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Read-WddJson {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    # Engines write UTF-8 without a BOM; Get-Content would read that as ANSI in PowerShell 5.1.
    try { ConvertTo-WddHashtable ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { $null }
}

function Write-WddLog {
    param([string] $Message, [ValidateSet('INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO')
    $line = '{0}  {1,-5}  {2}' -f (Get-WddNow).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Verbose $line
    if (-not $script:WddLogFile) { return }
    for ($i = 0; $i -lt 3; $i++) {
        try { [System.IO.File]::AppendAllText($script:WddLogFile, $line + "`r`n"); return } catch { Start-Sleep -Milliseconds 200 }
    }
}

function Get-WddPaths {
    param([string] $DataRoot)
    $deployment = Join-Path $DataRoot 'Deployment'
    $state = Join-Path $DataRoot 'state'
    $reports = Join-Path $DataRoot 'reports'
    @{
        Root          = $DataRoot
        Package       = Join-Path $DataRoot 'Package'
        Deployment    = $deployment
        Logs          = Join-Path $deployment 'logs'
        Log           = Join-Path (Join-Path $deployment 'logs') 'deployment.log'
        Status        = Join-Path $deployment 'status.json'
        StateDir      = $state
        State         = Join-Path $state 'deployment.json'
        Marker        = Join-Path $state 'deployment.done'
        RestartMarker = Join-Path $state 'restart-pending.json'
        Reports       = $reports
        ReportJson    = Join-Path $reports 'deployment-report.json'
        ReportText    = Join-Path $reports 'deployment-report.txt'
    }
}

function Initialize-WddLogging {
    param([hashtable] $Paths)
    foreach ($d in $Paths.Deployment, $Paths.Logs, $Paths.StateDir) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
    $script:WddLogFile = $Paths.Log
    if ((Test-Path -LiteralPath $Paths.Log) -and (Get-Item -LiteralPath $Paths.Log).Length -gt 5MB) { Move-Item -LiteralPath $Paths.Log -Destination "$($Paths.Log).1" -Force }
}

# ------------------------------------------------------------------------------------------------
# Manifest and integrity
# ------------------------------------------------------------------------------------------------

# Only plain relative paths: no drive, no root, no "..", a conservative character set.
function Test-WddRelativePath {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 200) { return $false }
    if ($Path -notmatch '^[A-Za-z0-9._ -]+([\\/][A-Za-z0-9._ -]+)*$') { return $false }
    foreach ($seg in $Path -split '[\\/]') { if ($seg -eq '..' -or $seg -eq '.' -or $seg.Trim() -eq '') { return $false } }
    return $true
}

function Read-WddManifest {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Deployment manifest not found: $Path" }
    try { $m = ConvertTo-WddHashtable ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { throw "Deployment manifest is not valid JSON: $Path" }
    if ($m -isnot [hashtable] -or $m.format -ne $script:ManifestFormat) { throw "Not a Windows Deployment Builder deployment manifest: $Path" }
    if ([int] $m.manifestVersion -ne 1) { throw "Unsupported deployment manifest version $($m.manifestVersion) (this orchestrator reads version 1)." }
    if ([string] $m.packageId -notmatch '^[0-9A-F]{16}$') { throw 'Deployment manifest has no valid packageId.' }
    if ([string] $m.dataRoot -notmatch '^[A-Za-z]:\\[^"*?<>|]+$') { throw 'Deployment manifest has an invalid dataRoot.' }
    foreach ($f in @($m.files)) {
        if (-not (Test-WddRelativePath $f.path)) { throw "Deployment manifest lists an unsafe path: $($f.path)" }
        if ([string] $f.sha256 -notmatch '^[0-9A-F]{64}$') { throw "Deployment manifest has an invalid hash for $($f.path)." }
        if ($f.textSha256 -and [string] $f.textSha256 -notmatch '^[0-9A-F]{64}$') { throw "Deployment manifest has an invalid text hash for $($f.path)." }
        if ($f.embedded -and -not (Test-WddRelativePath $f.embedded)) { throw "Deployment manifest lists an unsafe embedded path: $($f.embedded)" }
    }
    $known = 'staging', 'windowsUpdate', 'applications', 'drivers', 'finalization'
    foreach ($s in @($m.stages)) {
        if ($s.id -notin $known) { throw "Deployment manifest lists an unknown stage: $($s.id)" }
        foreach ($k in 'launcher', 'result', 'status') { if ($s.ContainsKey($k) -and $s[$k] -and -not (Test-WddRelativePath $s[$k])) { throw "Stage $($s.id) has an unsafe $k path." } }
    }
    return $m
}

function Get-WddSha256 {
    param([byte[]] $Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('X2') }) } finally { $sha.Dispose() }
}

# Hash of the exact file bytes (files in the package folder are byte-identical to the ZIP).
function Get-WddRawHash { param([string] $Path) Get-WddSha256 ([System.IO.File]::ReadAllBytes($Path)) }

# Hash of the text as the answer-file extraction writes it: .ps1/.xml as UTF-8 (BOM), other files
# in the system code page, line breaks normalised by the XML parser and the text trimmed. The
# manifest gives a text hash only where this is exact (ASCII text, or .ps1/.xml).
function Get-WddTextHash {
    param([string] $Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $encoding = if ($hasBom -or $ext -in '.ps1', '.xml') { New-Object System.Text.UTF8Encoding($false) } else { [System.Text.Encoding]::Default }
    $start = if ($hasBom) { 3 } else { 0 }
    $text = $encoding.GetString($bytes, $start, $bytes.Length - $start)
    $text = $text.Replace("`r`n", "`n").Replace("`r", "`n").Trim()
    Get-WddSha256 ((New-Object System.Text.UTF8Encoding($false)).GetBytes($text))
}

<#
    Checks files under $Root against the manifest.
      Raw   exact bytes (a package folder copied from the ZIP).
      Text  the text hash (files extracted from the answer file, and the staged copy of either).
    $Paths limits the check to these manifest paths. A JSON file without a text hash (non-ASCII
    content in the system code page) must at least parse.
#>
function Test-WddFiles {
    param([string] $Root, [hashtable] $Manifest, [ValidateSet('Raw', 'Text')] [string] $Mode, [string[]] $Only = $null)
    $missing = @(); $mismatched = @(); $checked = 0
    foreach ($f in @($Manifest.files)) {
        if ($null -ne $Only -and $f.path -notin $Only) { continue }
        $p = Join-Path $Root ($f.path -replace '/', '\')
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $missing += $f.path; continue }
        $checked++
        if ($Mode -eq 'Raw') {
            if ((Get-WddRawHash $p) -ne $f.sha256) { $mismatched += $f.path }
        } elseif ($f.textSha256) {
            if ((Get-WddTextHash $p) -ne $f.textSha256) { $mismatched += $f.path }
        } elseif ($p -like '*.json') {
            try { Get-Content -LiteralPath $p -Raw | ConvertFrom-Json | Out-Null } catch { $mismatched += $f.path }
        }
    }
    @{ Ok = ($missing.Count -eq 0 -and $mismatched.Count -eq 0); Missing = $missing; Mismatched = $mismatched; Checked = $checked }
}

# ------------------------------------------------------------------------------------------------
# Single instance
# ------------------------------------------------------------------------------------------------

function Enter-WddMutex {
    param([int] $TimeoutSeconds = 0)
    $created = $false
    $m = New-Object System.Threading.Mutex($false, $script:MutexName, [ref] $created)
    try { if ($m.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))) { return $m } } catch [System.Threading.AbandonedMutexException] { return $m }
    $m.Dispose()
    return $null
}

function Exit-WddMutex { param($Mutex) if ($Mutex) { try { $Mutex.ReleaseMutex() } catch { }; $Mutex.Dispose() } }

# ------------------------------------------------------------------------------------------------
# Deployment state and stage snapshot
# ------------------------------------------------------------------------------------------------

function Get-WddStage { param([hashtable] $Manifest, [string] $Id) @($Manifest.stages) | Where-Object { $_.id -eq $Id } | Select-Object -First 1 }

function Get-WddEngineStages { param([hashtable] $Manifest) @(@($Manifest.stages) | Where-Object { $_.id -in 'windowsUpdate', 'applications' -and $_.enabled } | Sort-Object { [int] $_.order }) }

function ConvertTo-WddDate {
    param($Value)
    if (-not $Value) { return $null }
    try { [DateTime]::Parse([string] $Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch { $null }
}

function Get-WddOutcome {
    param([string] $Status)
    switch ($Status) {
        'Succeeded' { 'ok' }
        'CompletedWithFollowUp' { 'followUp' }
        'CompletedWithFailures' { 'failures' }
        'Failed' { 'failed' }
        'Offline' { 'offline' }
        default { 'unknown' }
    }
}

function Test-WddRestartPending {
    param([hashtable] $Paths)
    $m = Read-WddJson $Paths.RestartMarker
    if (-not $m) { return $false }
    # The engines' shared Set-WdbRestartPending writes requestedUtc and the boot it was written in
    # (bootTimeUtc); writtenUtc is the Phase 4 name. A marker from an earlier boot is not pending.
    if ($m['bootTimeUtc']) {
        $markerBoot = ConvertTo-WddDate $m['bootTimeUtc']
        try { $boot = Get-WddBootTime } catch { return $true }
        if (-not $markerBoot -or [Math]::Abs(($markerBoot - $boot).TotalSeconds) -gt 2) { return $false }
    }
    $written = ConvertTo-WddDate $(if ($m['writtenUtc']) { $m['writtenUtc'] } else { $m['requestedUtc'] })
    if (-not $written -or ((Get-WddNow) - $written).TotalMinutes -gt 30) { return $false }
    try { $boot = Get-WddBootTime } catch { return $true }
    return $written -ge $boot
}

<#
    Snapshot of one engine stage, from what the engine itself wrote:
      Final       result.json exists (its status is the real outcome; a marker alone is never trusted)
      Running     the engine has checked in (status.json)
      Pending     launched, its task exists, not started yet
      Stalled     launched, but no task, no status and no result after the grace period, or the
                  task has gone while the stage is not final: needs manual attention
      NotStarted  not launched (yet)
      LaunchFailed the installer could not register the task
#>
function Get-WddStageSnapshot {
    param([hashtable] $Stage, [hashtable] $Paths, [hashtable] $State)
    $root = $Paths.Root
    $launch = if ($State -and $State.stages -and $State.stages.ContainsKey($Stage.id)) { $State.stages[$Stage.id] } else { $null }
    $o = [ordered]@{ id = $Stage.id; name = $Stage.name; enabled = [bool] $Stage.enabled; context = $Stage.context; state = 'NotStarted'; status = ''; outcome = ''; detail = ''; reboots = 0; updatedUtc = $null; current = ''; done = $null; total = $null; result = $null; idle = ''; outstanding = 0 }
    $result = Read-WddJson (Join-Path $root $Stage.result)
    if ($result -and $result.status -in $script:FinalStageStatuses) {
        $o.state = 'Final'; $o.status = $result.status; $o.outcome = Get-WddOutcome $result.status; $o.detail = [string] $result.reason
        $o.reboots = [int] $result.reboots; $o.updatedUtc = $result.finishedUtc; $o.result = $result
        if ($result.ContainsKey('outstanding')) { $o.outstanding = @($result.outstanding).Count }
        return $o
    }
    $status = Read-WddJson (Join-Path $root $Stage.status)
    $taskExists = Get-WddTask $Stage.task.path $Stage.task.name
    if ($status) {
        $o.status = [string] $status.phase; $o.detail = [string] $status.detail; $o.updatedUtc = $status.updatedUtc
        if ($status.ContainsKey('reboots')) { $o.reboots = [int] $status.reboots }
        if ($status.ContainsKey('done')) { $o.done = [int] $status.done; $o.total = [int] $status.total }
        if ($status.phase -eq 'Installing' -and $status.detail) { $o.current = [string] $status.detail }
    }
    if (-not $launch) { return $o }
    if ($launch.launchResult -eq 'LaunchFailed') { $o.state = 'LaunchFailed'; $o.detail = [string] $launch.message; return $o }
    $since = ConvertTo-WddDate $launch.launchedUtc
    $age = if ($since) { ((Get-WddNow) - $since).TotalMinutes } else { 0 }
    if ($taskExists) {
        $o.state = $(if ($status) { 'Running' } else { 'Pending' })
        # Phase 5: the user-context stage runs only while its user is signed in; say so when it has
        # not checked in for a long time instead of looking busy.
        $seen = ConvertTo-WddDate $o.updatedUtc
        $limit = [int] $State.stalledAfterMinutes
        if ($Stage.context -eq 'user' -and $limit -gt 0 -and $age -ge $limit -and (-not $seen -or ((Get-WddNow) - $seen).TotalMinutes -ge $limit)) {
            $who = $(if ($launch.ContainsKey('user') -and $launch.user) { [string] $launch.user } else { 'the user who started the deployment' })
            $o.idle = "has not run for more than $limit minutes; it runs only while $who is signed in."
        }
        return $o
    }
    # No task and no result: the engine removed its task without a result, or the task was deleted.
    if ($age -ge [int] $State.stalledAfterMinutes) { $o.state = 'Stalled'; if (-not $o.detail) { $o.detail = 'The scheduled task is missing and there is no result. Run Resume-Deployment.ps1.' } }
    else { $o.state = $(if ($status) { 'Running' } else { 'Pending' }) }
    return $o
}

function Get-WddSnapshot {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $State)
    $stages = @()
    foreach ($s in Get-WddEngineStages $Manifest) { $stages += , (Get-WddStageSnapshot $s $Paths $State) }
    $drivers = Get-WddStage $Manifest 'drivers'
    $engine = @($stages)
    $allFinal = ($engine.Count -eq 0) -or (@($engine | Where-Object { $_.state -ne 'Final' }).Count -eq 0)
    $blocked = @($engine | Where-Object { $_.state -in 'Stalled', 'LaunchFailed' })
    $current = @($engine | Where-Object { $_.state -in 'Running', 'Pending' } | Select-Object -First 1)
    $snap = [ordered]@{
        packageId       = $Manifest.packageId
        updatedUtc      = (Get-WddNow).ToString('o')
        deploymentState = $(if ($State) { [string] $State.status } else { 'NotInitialized' })
        currentStage    = $(if ($current.Count) { $current[0].id } else { '' })
        stages          = $stages
        drivers         = [ordered]@{ id = 'drivers'; state = 'NotImplemented'; detail = $(if ($drivers) { [string] $drivers.note } else { '' }) }
        allFinal        = $allFinal
        restartPending  = (Test-WddRestartPending $Paths)
        needsAttention  = @($blocked | ForEach-Object { "$($_.name): $($_.state). $($_.detail)" })
        overall         = $(if ($allFinal) { Get-WddOverall $engine } else { 'InProgress' })
    }
    Set-WddSnapshotOutcome $snap $State
    return $snap
}

<# Adds outcome, outcomeCode and outcomeDetail (Phase 5) to a snapshot. #>
function Set-WddSnapshotOutcome {
    param($Snapshot, $State, [string] $Problem = '')
    $out = Get-WddDeploymentOutcome $State $Snapshot $Problem
    $Snapshot.outcome = $out.outcome
    $Snapshot.outcomeCode = $out.exitCode
    $Snapshot.outcomeDetail = $out.detail
}

<#
    Overall result, from the worst stage:
      Succeeded              every enabled stage Succeeded (or nothing to do)
      CompletedWithFollowUp  finished; some items need a person (interaction, sign-in, restart)
      CompletedWithFailures  finished; some updates or packages failed or were unavailable
      Incomplete             a stage ended Offline, stalled, or the deadline passed first
      Failed                 a stage Failed (or staging/integrity failed before any stage ran)
#>
function Get-WddOverall {
    param([object[]] $Stages, [switch] $DeadlineReached)
    $rank = @{ ok = 0; followUp = 1; failures = 2; offline = 3; incomplete = 3; failed = 4 }
    $worst = 'ok'
    foreach ($s in @($Stages)) {
        $o = if ($s.state -eq 'Final') { $s.outcome } else { 'incomplete' }
        if (-not $rank.ContainsKey($o)) { $o = 'failed' }
        if ($rank[$o] -gt $rank[$worst]) { $worst = $o }
    }
    if ($DeadlineReached -and $worst -ne 'failed' -and @($Stages | Where-Object { $_.state -ne 'Final' }).Count -gt 0) { $worst = 'incomplete' }
    switch ($worst) { 'ok' { 'Succeeded' } 'followUp' { 'CompletedWithFollowUp' } 'failures' { 'CompletedWithFailures' } 'failed' { 'Failed' } default { 'Incomplete' } }
}

function Save-WddState { param([hashtable] $Paths, [hashtable] $State) Write-WddJson $Paths.State $State -Backup }

$script:DeployStates = @('Staging', 'StagingFailed', 'Launching', 'InProgress', 'Completed', 'IntegrityFailed')

<# Shape check of deployment.json: a reason, or $null when the state is usable. #>
function Test-WddStateShape {
    param($S)
    if ($S -isnot [hashtable]) { return 'not an object' }
    if ("$($S['schemaVersion'])" -notmatch '^\d{1,3}$' -or [int] $S['schemaVersion'] -lt 1 -or [int] $S['schemaVersion'] -gt $script:DeployStateVersion) { return "unsupported schema version '$($S['schemaVersion'])'" }
    if ([string] $S['packageId'] -notmatch '^[0-9A-F]{16}$') { return 'no valid packageId' }
    if ([string] $S['status'] -notin $script:DeployStates) { return "unknown status '$($S['status'])'" }
    if ($S.ContainsKey('stages') -and $null -ne $S['stages'] -and $S['stages'] -isnot [hashtable]) { return 'stages is not a map' }
    return $null
}

<#
    Reads deployment.json, falling back to the last good copy (deployment.json.bak). Returns
      @{ State; Source = main | backup | missing | corrupt; Problem }
    "corrupt" (a state file exists but neither copy is usable) is never treated as "no deployment":
    callers stop and leave the decision to a technician (DeploymentRecovery.ps1 -Action Resume
    rebuilds the state from the manifest and the engines' own files).
#>
function Read-WddDeploymentState {
    param([hashtable] $Paths)
    $problems = @()
    $exists = $false
    foreach ($candidate in @($Paths.State, "$($Paths.State).bak")) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        $exists = $true
        $s = Read-WddJson $candidate
        $why = $(if ($null -eq $s) { 'not valid JSON' } else { Test-WddStateShape $s })
        if (-not $why) {
            if (-not $s.ContainsKey('recoveries') -or $null -eq $s['recoveries']) { $s['recoveries'] = @() }
            if (-not $s.ContainsKey('stages') -or $null -eq $s['stages']) { $s['stages'] = @{} }
            $s.schemaVersion = $script:DeployStateVersion
            if ($candidate -ne $Paths.State) {
                Write-WddLog "Deployment state recovered from its last good copy ($(Split-Path -Leaf $candidate)); the damaged file was kept as deployment.json.corrupt." 'WARN'
                if (Test-Path -LiteralPath $Paths.State) { Copy-Item -LiteralPath $Paths.State -Destination "$($Paths.State).corrupt" -Force -ErrorAction SilentlyContinue }
                return @{ State = $s; Source = 'backup'; Problem = ($problems -join '; ') }
            }
            return @{ State = $s; Source = 'main'; Problem = '' }
        }
        $problems += "$(Split-Path -Leaf $candidate): $why"
    }
    if (-not $exists) { return @{ State = $null; Source = 'missing'; Problem = '' } }
    return @{ State = $null; Source = 'corrupt'; Problem = ($problems -join '; ') }
}

# ------------------------------------------------------------------------------------------------
# Outcome (Phase 5): one machine-readable result with a stable exit code
# ------------------------------------------------------------------------------------------------

$script:OutcomeCodes = [ordered]@{
    Succeeded = 0; CompletedWithWarnings = 10; CompletedWithFailures = 20; Incomplete = 25
    PausedAwaitingNetwork = 30; PausedAwaitingReboot = 31; PausedAwaitingUser = 32; InProgress = 40
    FailedToInitialize = 50; Failed = 60
}

<#
    Where the deployment stands, for people and programs:
      ended    Succeeded, CompletedWithWarnings (manual actions or follow-ups), CompletedWithFailures,
               Incomplete (ended before every stage finished), Failed
      running  PausedAwaitingNetwork, PausedAwaitingReboot, PausedAwaitingUser, InProgress
      never    FailedToInitialize (no usable state, staging or integrity failure)
#>
function Get-WddDeploymentOutcome {
    param($State, $Snapshot, [string] $Problem = '')
    $o = { param([string] $Name, [string] $Detail) [ordered]@{ outcome = $Name; exitCode = $script:OutcomeCodes[$Name]; detail = $Detail } }
    if (-not $State) { return & $o 'FailedToInitialize' $(if ($Problem) { "The deployment state is unusable: $Problem" } else { 'No deployment has been started on this computer.' }) }
    switch ([string] $State.status) {
        'StagingFailed' { return & $o 'FailedToInitialize' ([string] $State.message) }
        'IntegrityFailed' { return & $o 'FailedToInitialize' ([string] $State.message) }
        'Completed' {
            $map = @{ Succeeded = 'Succeeded'; CompletedWithFollowUp = 'CompletedWithWarnings'; CompletedWithFailures = 'CompletedWithFailures'; Incomplete = 'Incomplete'; Failed = 'Failed' }
            $name = $(if ($map.ContainsKey([string] $State.overall)) { $map[[string] $State.overall] } else { 'Failed' })
            return & $o $name ([string] $State.message)
        }
    }
    $stages = @(if ($Snapshot) { @($Snapshot.stages) } else { @() })
    $live = @($stages | Where-Object { $_ -and $_.state -ne 'Final' })
    if (($Snapshot -and $Snapshot.restartPending) -or @($live | Where-Object { $_.status -in 'Rebooting', 'RebootDeferred' }).Count) { return & $o 'PausedAwaitingReboot' 'A restart is scheduled or in progress; the deployment continues after it.' }
    $net = @($live | Where-Object { $_.status -eq 'WaitingForNetwork' })
    if ($net.Count) { return & $o 'PausedAwaitingNetwork' ("$(($net | ForEach-Object { $_.name }) -join ', '): waiting for the network. $(($net | ForEach-Object { $_.detail } | Where-Object { $_ }) -join '; ')".Trim()) }
    $user = @($live | Where-Object { $_.state -in 'Stalled', 'LaunchFailed' -or $_.idle })
    if ($user.Count) { return & $o 'PausedAwaitingUser' (($user | ForEach-Object { "$($_.name): $(if ($_.idle) { $_.idle } else { "$($_.state). $($_.detail)" })" }) -join ' ') }
    return & $o 'InProgress' $(if ($Snapshot -and $Snapshot.currentStage) { "Current stage: $($Snapshot.currentStage)." } else { 'Stages are starting.' })
}
