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

    Orchestrator 1.2.0 (deployment reliability):
      - Every stage in a snapshot says what it is doing in words (activity), why it waits
        (waitingReason), when its engine last reported progress (lastActivityUtc) and how it stands
        (condition: active, waiting, idle, blocked, finished). A stage with no progress for longer
        than its limit is flagged (stale); the limit is longer for Windows Update downloads and
        installations, and never applies while Windows itself is still servicing updates.
      - The activity feed <dataRoot>\Deployment\activity.jsonl: one timestamped JSON line per event
        (restarts, recoveries, stage changes, retries and failures reported by the engines).
#>

Set-StrictMode -Version 2.0

$script:DeployVersion = '1.3.0'
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

<# Task state for the watchdog: @{ Exists; State (Ready, Running, Disabled, Queued); LastRunUtc; LastResult }. #>
function Get-WddTaskInfo {
    param([string] $TaskPath, [string] $TaskName)
    $t = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if (-not $t) { return @{ Exists = $false; State = ''; LastRunUtc = $null; LastResult = $null } }
    $i = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
    @{ Exists = $true; State = [string] $t.State
       LastRunUtc = $(if ($i -and $i.LastRunTime -and $i.LastRunTime.Year -gt 2000) { $i.LastRunTime.ToUniversalTime() } else { $null })
       LastResult = $(if ($i) { [int64] $i.LastTaskResult } else { $null }) }
}

<# True while Windows is installing updates itself (the Windows Update installer or TrustedInstaller is busy). #>
function Test-WddUpdateServicing {
    try { if ((New-Object -ComObject 'Microsoft.Update.Installer').IsBusy) { return $true } } catch { }
    return [bool] (Get-Process -Name 'TiWorker' -ErrorAction SilentlyContinue)
}

<#
    Orchestrator 1.3.0: restart coordination adapters.
    Get-WddServicingRestart  what Windows itself reports as a pending servicing restart (Windows
                             Update and component servicing). PendingFileRenameOperations is
                             deliberately not used: many installers leave entries there that do not
                             need a restart, and acting on it would restart for nothing.
    Test-WddInstallerActive  why restarting now would interrupt an installation ('' = nothing runs):
                             the Windows Update installer is busy, or a Windows Installer (MSI)
                             installation holds its machine-wide mutex.
#>
function Get-WddServicingRestart {
    $r = @()
    $wu = $false
    try { $wu = [bool] (New-Object -ComObject 'Microsoft.Update.SystemInfo').RebootRequired } catch { }
    if ($wu -or (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) { $r += 'Windows Update reports that a restart is required to finish installed updates' }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $r += 'Windows component servicing has a pending restart' }
    $r
}

function Test-WddInstallerActive {
    try { if ((New-Object -ComObject 'Microsoft.Update.Installer').IsBusy) { return 'the Windows Update installer is busy' } } catch { }
    $m = $null
    try { if ([System.Threading.Mutex]::TryOpenExisting('Global\_MSIExecute', [ref] $m)) { $m.Dispose(); return 'a Windows Installer (MSI) installation is running' } }
    catch [System.UnauthorizedAccessException] { return 'a Windows Installer (MSI) installation is running' } catch { }
    return ''
}

<# The machine-wide install lock shared with the engines (<dataRoot>\state\install.lock); $null when another installation holds it. #>
function Enter-WddInstallLock {
    param([hashtable] $Paths)
    if (-not (Test-Path -LiteralPath $Paths.StateDir)) { New-Item -ItemType Directory -Path $Paths.StateDir -Force | Out-Null }
    try {
        $fs = [System.IO.File]::Open((Join-Path $Paths.StateDir 'install.lock'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(('{{"owner":"Deployment","pid":{0},"sinceUtc":"{1}"}}' -f $PID, [DateTime]::UtcNow.ToString('o')))
        $fs.SetLength(0); $fs.Write($bytes, 0, $bytes.Length); $fs.Flush()
        return $fs
    } catch [System.IO.IOException] { return $null }
}

function Exit-WddInstallLock { param($Lock) if ($Lock) { try { $Lock.Dispose() } catch { } } }

<# The restart marker in the engines' format, so they start nothing new before the restart. #>
function Set-WddRestartMarker {
    param([hashtable] $Paths, [string] $Reason)
    $boot = $(try { (Get-WddBootTime).ToString('yyyy-MM-ddTHH:mm:ssZ') } catch { 'unknown' })
    Write-WddJson $Paths.RestartMarker ([ordered]@{ owner = 'Deployment'; reason = $Reason; requestedUtc = (Get-WddNow).ToString('o'); bootTimeUtc = $boot })
}

function Invoke-WddRestart {
    param([int] $WarningSeconds, [string] $Reason)
    # p:2:17 = planned, Operating System: Hot fix
    & "$env:SystemRoot\System32\shutdown.exe" /r /t $WarningSeconds /d p:2:17 /c "Windows Deployment Builder: $Reason. The computer restarts in $WarningSeconds seconds; the deployment continues automatically."
    if ($LASTEXITCODE -ne 0) { throw "shutdown.exe failed with exit code $LASTEXITCODE" }
}

<#
    Read-only Windows Update search (the documented WUA COM API, as SYSTEM) under the Windows Update
    engine's own policy ($Config = its config.json): what it would install if it ran now. Feature
    updates and Insider builds are never counted; optional updates and drivers only when the policy
    installs them. Installs, downloads and hides nothing.
#>
function Get-WddOfferedUpdates {
    param($Config)
    $c = $(if ($Config -is [hashtable]) { $Config } else { @{} })
    $session = New-Object -ComObject 'Microsoft.Update.Session'
    $session.ClientApplicationID = 'Windows Deployment Builder (re-check)'
    $searcher = $session.CreateUpdateSearcher()
    if ($c['microsoftUpdate']) { $searcher.ServerSelection = 3; $searcher.ServiceID = '7971f918-a847-4430-9279-4a52d1efe18d' }
    $criteria = 'IsInstalled=0 and IsHidden=0'
    if ([string] $c['drivers'] -ne 'include') { $criteria += " and Type='Software'" }
    $result = $searcher.Search($criteria)
    if ($result.ResultCode -notin 2, 3) { throw "Windows Update search returned result code $($result.ResultCode)." }
    $excluded = @(@($c['excludedKbs']) | Where-Object { $_ } | ForEach-Object { ([string] $_).ToUpperInvariant() })
    foreach ($u in $result.Updates) {
        $title = [string] $u.Title
        $cats = @(foreach ($x in $u.Categories) { ([string] $x.CategoryID).ToLowerInvariant() })
        if ($cats -contains '3689bdc8-b205-4af4-8d4b-a63924c5e9d5' -or $title -match '(?i)^\s*(Feature update to Windows|Upgrade to Windows)\b' -or $title -match '(?i)\bInsider Preview\b') { continue }
        if ([bool] $u.BrowseOnly -and [string] $c['optionalUpdates'] -ne 'install') { continue }
        $kbs = @(foreach ($k in $u.KBArticleIDs) { "KB$k" })
        if (@($kbs | Where-Object { $excluded -contains $_.ToUpperInvariant() }).Count) { continue }
        @{ id = [string] $u.Identity.UpdateID; title = $title; kbs = $kbs; optional = [bool] $u.BrowseOnly; driver = ([int] $u.Type -eq 2) }
    }
}

<# Holds the install lock through the restart warning, so nothing starts installing before the restart. #>
function Wait-WddRestart { param([int] $Seconds) if ($Seconds -gt 0) { Start-Sleep -Seconds $Seconds } }

<#
    Orchestrator 1.3.0: whether this process can see the deployment's scheduled tasks. The tasks
    of SYSTEM and of an elevated user are not readable with a filtered (non-elevated) token, so
    the progress window, which runs without elevation, must never conclude that a task is missing:
    'Limited' makes the snapshot rely on the SYSTEM monitor's own view (status.json) instead.
#>
$script:WddTaskVisibility = 'Full'
function Get-WddTaskVisibility {
    $id = Get-WddIdentity
    if ($id.IsSystem -or $id['IsAdmin']) { return 'Full' }
    return 'Limited'
}

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
    $err = $null
    for ($i = 0; $i -lt 3; $i++) {
        try { [System.IO.File]::AppendAllText($script:WddLogFile, $line + "`r`n"); return } catch { $err = $_.Exception.Message; Start-Sleep -Milliseconds 200 }
    }
    # Once per process: a log that cannot be written is visible on the console and in task output.
    if (-not $script:WddLogWarned) { $script:WddLogWarned = $true; Write-Warning "Cannot write the deployment log $($script:WddLogFile): $err" }
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
        # Orchestrator 1.2.0: the timestamped activity feed and the LAN monitor's address and token.
        Activity      = Join-Path $deployment 'activity.jsonl'
        MonitorInfo   = Join-Path $state 'monitor.json'
    }
}

# ------------------------------------------------------------------------------------------------
# Activity feed (orchestrator 1.2.0)
# ------------------------------------------------------------------------------------------------

<#
    Appends one event to <dataRoot>\Deployment\activity.jsonl: {utc, level, source, message}.
    The engines append their own retry and failure messages to the same file (Add-WdbActivity).
    Never contains secrets: only the deployment's own messages.
#>
function Add-WddActivity {
    param([hashtable] $Paths, [string] $Message, [ValidateSet('info', 'warning', 'error')] [string] $Level = 'info', [string] $Source = 'deployment')
    $line = ([ordered]@{ utc = (Get-WddNow).ToString('o'); level = $Level; source = $Source; message = $Message } | ConvertTo-Json -Compress)
    Write-WddLog "Activity: $Message" $(switch ($Level) { 'error' { 'ERROR' } 'warning' { 'WARN' } default { 'INFO' } })
    $dir = Split-Path -Parent $Paths.Activity
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    for ($i = 0; $i -lt 3; $i++) {
        try {
            # A line left unfinished by a writer that was stopped must not swallow this one.
            $fs = New-Object System.IO.FileStream($Paths.Activity, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
            try {
                $prefix = ''
                if ($fs.Length -gt 0) { [void] $fs.Seek(-1, [System.IO.SeekOrigin]::End); if ($fs.ReadByte() -ne 10) { $prefix = "`r`n" } }
                [void] $fs.Seek(0, [System.IO.SeekOrigin]::End)
                $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($prefix + $line + "`r`n")
                $fs.Write($bytes, 0, $bytes.Length)
            } finally { $fs.Dispose() }
            return
        } catch { Start-Sleep -Milliseconds 100 }
    }
}

<# The last $Last events, oldest first. A line that is being written (incomplete JSON) is skipped. #>
function Read-WddActivity {
    param([hashtable] $Paths, [int] $Last = 30)
    # Returns the events one by one (callers collect them with @()).
    if (-not $Paths.ContainsKey('Activity') -or -not (Test-Path -LiteralPath $Paths.Activity)) { return }
    $lines = $null
    for ($i = 0; $i -lt 3 -and $null -eq $lines; $i++) {
        try {
            $fs = New-Object System.IO.FileStream($Paths.Activity, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try { $lines = (New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)).ReadToEnd() -split "`r?`n" } finally { $fs.Dispose() }
        } catch { Start-Sleep -Milliseconds 100 }
    }
    $out = @()
    foreach ($l in @($lines | Where-Object { $_ -and $_.Trim() } | Select-Object -Last $Last)) {
        try { $e = ConvertTo-WddHashtable ($l | ConvertFrom-Json); if ($e -is [hashtable] -and $e['utc'] -and $e['message']) { $out += , $e } } catch { }
    }
    return $out
}

<# Keeps the feed small: above $MaxBytes only the last $Keep events are kept. #>
function Limit-WddActivity {
    param([hashtable] $Paths, [int64] $MaxBytes = 1MB, [int] $Keep = 500)
    if (-not (Test-Path -LiteralPath $Paths.Activity) -or (Get-Item -LiteralPath $Paths.Activity).Length -le $MaxBytes) { return }
    try {
        $keep = @([System.IO.File]::ReadAllLines($Paths.Activity, [System.Text.Encoding]::UTF8) | Select-Object -Last $Keep)
        $tmp = "$($Paths.Activity).tmp"
        [System.IO.File]::WriteAllLines($tmp, [string[]] $keep, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $Paths.Activity -Force
    } catch { Write-WddLog "Could not shorten the activity feed: $($_.Exception.Message)" 'WARN' }
}

<# "just now", "1 minute ago", "12 minutes ago", "3 hours ago". #>
function Format-WddAge {
    param($Since)
    $d = ConvertTo-WddDate $Since
    if (-not $d) { return 'unknown' }
    $m = [int] [Math]::Floor(((Get-WddNow) - $d).TotalMinutes)
    if ($m -lt 1) { return 'just now' }
    if ($m -eq 1) { return '1 minute ago' }
    if ($m -lt 120) { return "$m minutes ago" }
    return "$([int] [Math]::Floor($m / 60)) hours ago"
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

# Phase 8: the driver stage is an engine stage when the manifest enables it (older manifests never do).
function Get-WddEngineStages { param([hashtable] $Manifest) @(@($Manifest.stages) | Where-Object { $_.id -in 'windowsUpdate', 'applications', 'drivers' -and $_.enabled -and ($_.id -ne 'drivers' -or $_['launcher']) } | Sort-Object { [int] $_.order }) }

<# Phase 8: the driver engine's flag for a computer that is offline because no network adapter has a driver. #>
function Get-WddNetworkDriverFlag {
    param([hashtable] $Paths)
    $f = Read-WddJson (Join-Path $Paths.StateDir 'network-driver-missing.json')
    if ($f -and $f['detail']) { return [string] $f['detail'] }
    return ''
}

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
<# The SYSTEM monitor's last view of one stage (from its status.json, if written in the last 30 minutes), or $null. #>
function Get-WddMonitorStageView {
    param([hashtable] $Paths, [string] $Id)
    $s = Read-WddJson $Paths.Status
    if ($s -isnot [hashtable] -or -not $s.ContainsKey('stages')) { return $null }
    $at = ConvertTo-WddDate $s['updatedUtc']
    if (-not $at -or ((Get-WddNow) - $at).TotalMinutes -gt 30) { return $null }
    return (@($s['stages']) | Where-Object { $_ -is [hashtable] -and $_['id'] -eq $Id } | Select-Object -First 1)
}

function Get-WddStageSnapshot {
    param([hashtable] $Stage, [hashtable] $Paths, [hashtable] $State)
    $root = $Paths.Root
    $launch = if ($State -and $State.stages -and $State.stages.ContainsKey($Stage.id)) { $State.stages[$Stage.id] } else { $null }
    $o = [ordered]@{ id = $Stage.id; name = $Stage.name; enabled = [bool] $Stage.enabled; context = $Stage.context; state = 'NotStarted'; status = ''; outcome = ''; detail = ''; reboots = 0; updatedUtc = $null; current = ''; done = $null; total = $null; result = $null; idle = ''; outstanding = 0
                     condition = 'waiting'; activity = ''; waitingReason = ''; lastActivityUtc = $null; stale = $false; staleMinutes = 0; counts = [ordered]@{}; lastError = ''; lastErrorUtc = $null; progress = 'unavailable'; engine = $null }
    $result = Read-WddJson (Join-Path $root $Stage.result)
    if ($result -and $result.status -in $script:FinalStageStatuses) {
        $o.state = 'Final'; $o.status = $result.status; $o.outcome = Get-WddOutcome $result.status; $o.detail = [string] $result.reason
        $o.reboots = [int] $result.reboots; $o.updatedUtc = $result.finishedUtc; $o.result = $result
        if ($result.ContainsKey('outstanding')) { $o.outstanding = @($result.outstanding).Count }
        Set-WddStageNarrative $o $Stage $null $null $State
        return $o
    }
    $status = Read-WddJson (Join-Path $root $Stage.status)
    $o.engine = $status
    # Orchestrator 1.3.0: a non-elevated process cannot see the SYSTEM tasks; it never concludes "missing".
    $taskKnown = $script:WddTaskVisibility -ne 'Limited'
    $taskExists = $(if ($taskKnown) { Get-WddTask $Stage.task.path $Stage.task.name } else { $false })
    if ($status) {
        $o.status = [string] $status.phase; $o.detail = [string] $status.detail; $o.updatedUtc = $status.updatedUtc
        if ($status.ContainsKey('reboots')) { $o.reboots = [int] $status.reboots }
        if ($status.ContainsKey('done')) { $o.done = [int] $status.done; $o.total = [int] $status.total }
        if ($status.phase -eq 'Installing' -and $status.detail) { $o.current = [string] $status.detail }
    }
    if (-not $launch) { Set-WddStageNarrative $o $Stage $status $launch $State; return $o }
    if ($launch.launchResult -eq 'LaunchFailed') { $o.state = 'LaunchFailed'; $o.detail = [string] $launch.message; Set-WddStageNarrative $o $Stage $status $launch $State; return $o }
    $since = ConvertTo-WddDate $launch.launchedUtc
    $age = if ($since) { ((Get-WddNow) - $since).TotalMinutes } else { 0 }
    if (-not $taskKnown) {
        # What the SYSTEM monitor saw at its last run decides Stalled; otherwise the task is assumed present.
        $mv = Get-WddMonitorStageView $Paths $Stage.id
        if ($mv -and [string] $mv['state'] -in 'Stalled', 'LaunchFailed') {
            $o.state = [string] $mv['state']; $o.detail = "$([string] $mv['detail']) (reported by the deployment monitor)".Trim()
            Set-WddStageNarrative $o $Stage $status $launch $State
            return $o
        }
        $taskExists = $true
    }
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
        Set-WddStageNarrative $o $Stage $status $launch $State
        return $o
    }
    # No task and no result: the engine removed its task without a result, or the task was deleted.
    if ($age -ge [int] $State.stalledAfterMinutes) { $o.state = 'Stalled'; if (-not $o.detail) { $o.detail = 'The scheduled task is missing and there is no result. Run Resume-Deployment.ps1.' } }
    else { $o.state = $(if ($status) { 'Running' } else { 'Pending' }) }
    Set-WddStageNarrative $o $Stage $status $launch $State
    return $o
}

# Engine phases that mean "waiting for something", with the reason in words.
$script:WaitingPhases = @{
    WaitingForNetwork   = 'Waiting for a network connection.'
    WaitingForInstaller = 'Waiting for Windows Update to finish.'
    WaitingForLock      = 'Waiting for another installation to finish.'
    WaitingForRetry     = 'Waiting before the next retry.'
    WaitingForUpdates   = 'Waiting for Windows Update to finish first.'
    WaitingForDrivers   = 'Waiting for the driver stage to finish first.'
    WaitingForRestart   = 'Waiting for the scheduled restart.'
    WaitingForReboot    = 'Waiting for a restart.'
    RebootDeferred      = 'A restart is needed; it waits until the current installation has finished.'
    Rebooting           = 'Restarting Windows; the deployment continues after the restart.'
    Error               = 'The engine hit an unexpected error and tries again at its next run.'
}
# Phases during which Windows Update legitimately works for a long time without a new status.
$script:LongPhases = @('Downloading', 'Installing', 'WaitingForInstaller', 'Rebooting', 'ResettingComponents')

<#
    Orchestrator 1.2.0: what a stage is doing, in words, from evidence only (the engine's own
    status.json and result.json, its task, the launch record):
      condition  finished | active | waiting | idle | blocked
      activity   one sentence for people (the progress window and the LAN monitor)
      stale      no progress reported for longer than the limit (not while Windows is servicing)
#>
function Set-WddStageNarrative {
    param($O, [hashtable] $Stage, $Status, $Launch, $State)
    $limit = [int] $(if ($State -and $State['stalledAfterMinutes']) { $State['stalledAfterMinutes'] } else { 120 })
    $long = [int] $(if ($State -and $State['longOperationMinutes']) { $State['longOperationMinutes'] } else { [Math]::Max(240, $limit) })
    if ($Status -is [hashtable]) {
        $O.lastActivityUtc = $Status['updatedUtc']
        foreach ($k in 'installed', 'failed', 'needsPerson', 'selected', 'done', 'total', 'attempt', 'maxAttempts', 'queued') { if ($Status.ContainsKey($k) -and $null -ne $Status[$k]) { $O.counts[$k] = $Status[$k] } }
        if ($Status.ContainsKey('current') -and $Status['current']) { $O.current = [string] $Status['current'] }
        if ($Status.ContainsKey('lastError') -and $Status['lastError']) { $O.lastError = [string] $Status['lastError']; $O.lastErrorUtc = $Status['lastErrorUtc'] }
        if ($Status.ContainsKey('lastFailure') -and $Status['lastFailure'] -is [hashtable]) { $O.lastError = [string] $Status['lastFailure']['message']; $O.lastErrorUtc = $Status['lastFailure']['atUtc'] }
    }
    switch ($O.state) {
        'Final' {
            $O.condition = 'finished'; $O.lastActivityUtc = $O.updatedUtc
            $O.activity = "Finished: $($O.status).$(if ($O.detail) { " $($O.detail)" })"
            if ($O.result -is [hashtable]) {
                foreach ($k in 'installed', 'failed', 'skipped', 'requiresInteraction') { if ($O.result.ContainsKey($k) -and $O.result[$k] -is [array]) { $O.counts[$k] = @($O.result[$k]).Count } }
                if ($O.result.ContainsKey('counts') -and $O.result['counts'] -is [hashtable]) { foreach ($k in $O.result['counts'].Keys) { $O.counts[$k] = $O.result['counts'][$k] } }
            }
            return
        }
        'LaunchFailed' { $O.condition = 'blocked'; $O.activity = "Could not be started: $($O.detail)"; return }
        'Stalled' { $O.condition = 'blocked'; $O.activity = "No progress: $($O.detail)"; return }
        'NotStarted' { $O.condition = 'waiting'; $O.activity = 'Not started yet.'; $O.waitingReason = 'Waiting for the deployment to launch this stage.'; return }
        'Pending' {
            $O.condition = 'waiting'
            $since = $(if ($Launch -is [hashtable]) { $Launch['launchedUtc'] } else { $null })
            $O.waitingReason = $(if ($Stage.context -eq 'user') { 'Scheduled; it starts when the deployment user is signed in.' } else { 'Scheduled; waiting for the engine to start.' })
            $O.activity = "$($O.waitingReason) Launched $(Format-WddAge $since)."
            $O.lastActivityUtc = $since
            return
        }
    }
    # Running: the engine has checked in.
    $phase = [string] $O.status
    $age = $(if (ConvertTo-WddDate $O.lastActivityUtc) { ((Get-WddNow) - (ConvertTo-WddDate $O.lastActivityUtc)).TotalMinutes } else { 0 })
    if ($O.idle) {
        $O.condition = 'idle'; $O.activity = "Idle: $($O.idle)"; $O.waitingReason = $O.idle
    } elseif ($script:WaitingPhases.ContainsKey($phase)) {
        $O.condition = 'waiting'; $O.waitingReason = $script:WaitingPhases[$phase]
        $O.activity = "$($script:WaitingPhases[$phase])$(if ($O.detail -and $O.detail -ne $script:WaitingPhases[$phase]) { " $($O.detail)" }) Last activity: $(Format-WddAge $O.lastActivityUtc)."
    } else {
        $O.condition = 'active'
        $O.activity = "$(if ($O.detail) { $O.detail } else { $phase })$(if ($O.detail -notmatch '\.$') { '.' }) Last activity: $(Format-WddAge $O.lastActivityUtc)."
    }
    # No progress for longer than the limit. Never while Windows Update is still servicing.
    $max = $(if ($phase -in $script:LongPhases -and $Stage.id -eq 'windowsUpdate') { $long } else { $limit })
    if ($O.condition -ne 'idle' -and $age -ge $max -and $phase -notin 'Rebooting') {
        $servicing = $false
        if ($Stage.id -eq 'windowsUpdate' -or $phase -eq 'WaitingForInstaller') { try { $servicing = [bool] (Test-WddUpdateServicing) } catch { } }
        if (-not $servicing) {
            $O.stale = $true; $O.staleMinutes = [int] $age; $O.condition = 'blocked'
            $O.activity = "No progress detected for $([int] $age) minutes (limit $max). Last step: $(if ($O.detail) { $O.detail } else { $phase })."
        } else {
            $O.activity = "$($O.activity) Windows is still installing updates, so this is not treated as stalled."
        }
    }
}

function Get-WddSnapshot {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $State)
    $stages = @()
    foreach ($s in Get-WddEngineStages $Manifest) { $stages += , (Get-WddStageSnapshot $s $Paths $State) }
    $drivers = Get-WddStage $Manifest 'drivers'
    $drvSnap = @($stages | Where-Object { $_.id -eq 'drivers' } | Select-Object -First 1)
    $drvState = $(if ($drvSnap.Count) { [ordered]@{ id = 'drivers'; state = $drvSnap[0].state; status = $drvSnap[0].status; detail = $drvSnap[0].detail } }
                  elseif ($drivers -and $drivers['implemented']) { [ordered]@{ id = 'drivers'; state = 'NotPartOfDeployment'; detail = [string] $drivers['note'] } }
                  else { [ordered]@{ id = 'drivers'; state = 'NotImplemented'; detail = $(if ($drivers) { [string] $drivers['note'] } else { '' }) } })
    $engine = @($stages)
    $allFinal = ($engine.Count -eq 0) -or (@($engine | Where-Object { $_.state -ne 'Final' }).Count -eq 0)
    $blocked = @($engine | Where-Object { $_.state -in 'Stalled', 'LaunchFailed' -or $_.stale })
    $current = @($engine | Where-Object { $_.state -in 'Running', 'Pending' } | Select-Object -First 1)
    $snap = [ordered]@{
        packageId       = $Manifest.packageId
        updatedUtc      = (Get-WddNow).ToString('o')
        deploymentState = $(if ($State) { [string] $State.status } else { 'NotInitialized' })
        currentStage    = $(if ($current.Count) { $current[0].id } else { '' })
        stages          = $stages
        drivers         = $drvState
        networkDriverMissing = (Get-WddNetworkDriverFlag $Paths)
        allFinal        = $allFinal
        restartPending  = (Test-WddRestartPending $Paths)
        needsAttention  = @($blocked | ForEach-Object { if ($_.stale) { "$($_.name): $($_.activity)" } else { "$($_.name): $($_.state). $($_.detail)" } })
        overall         = $(if ($allFinal) { Get-WddOverall $engine } else { 'InProgress' })
        lastActivityUtc = (Get-WddLastActivity $engine)
        recovering      = [bool] ($State -and $State['recoveringUntilUtc'] -and (ConvertTo-WddDate $State['recoveringUntilUtc']) -gt (Get-WddNow))
        restarts        = @(if ($State -and $State['restarts']) { @($State['restarts']) | Select-Object -Last 10 })
        # Orchestrator 1.3.0: the coordinated restart, finalization and whether the monitor still runs.
        restart         = (Get-WddRestartView $State)
        finalizing      = [bool] ($allFinal -and $State -and [string] $State['status'] -notin 'Completed', 'StagingFailed', 'IntegrityFailed')
        finalizeError   = $(if ($State -and $State['lastFinalizeError']) { [string] $State['lastFinalizeError'] } else { '' })
        monitorLastRunUtc = $(if ($State) { $State['lastMonitorUtc'] } else { $null })
        monitorOverdue  = (Test-WddMonitorOverdue $Manifest $State)
    }
    if ($snap.monitorOverdue) {
        $snap.needsAttention = @(@($snap.needsAttention) + @("Deployment monitor: it has not run since $(if ($snap.monitorLastRunUtc) { Format-WddAge $snap.monitorLastRunUtc } else { 'the deployment started' }) (it should run every $(Get-WddMonitorInterval $Manifest) minutes as SYSTEM, task \WindowsDeploymentBuilder\Deployment). Nothing is finished or restarted automatically until it runs again; run Resume-Deployment.ps1 as administrator."))
    }
    Set-WddSnapshotOutcome $snap $State
    $snap.condition = Get-WddCondition $snap $State
    return $snap
}

<# The most recent progress any stage reported (ISO 8601), or $null. #>
function Get-WddLastActivity {
    param([object[]] $Stages)
    $best = $null
    foreach ($s in @($Stages)) { $d = ConvertTo-WddDate $s.lastActivityUtc; if ($d -and (-not $best -or $d -gt $best)) { $best = $d } }
    if ($best) { return $best.ToString('o') }
    return $null
}

<# Minutes between monitor runs (orchestrator 1.2.0 packages: 5; older: 15). #>
function Get-WddMonitorInterval {
    param([hashtable] $Manifest)
    $o = $(if ($Manifest -and $Manifest['failureHandling'] -is [hashtable]) { $Manifest.failureHandling['orchestrator'] } else { $null })
    if ($o -is [hashtable] -and $o.ContainsKey('monitorIntervalMinutes') -and [int] $o.monitorIntervalMinutes -ge 1) { return [int] $o.monitorIntervalMinutes }
    return 15
}

<#
    Orchestrator 1.3.0: the SYSTEM monitor has not run for three intervals (plus 5 minutes) although
    Windows has been running that long. Nothing finishes or restarts automatically without it, so
    the progress window says so instead of looking busy.
#>
function Test-WddMonitorOverdue {
    param([hashtable] $Manifest, $State)
    if (-not $State -or [string] $State['status'] -notin 'Launching', 'InProgress') { return $false }
    $limit = 3 * (Get-WddMonitorInterval $Manifest) + 5
    $last = ConvertTo-WddDate $(if ($State['lastMonitorUtc']) { $State['lastMonitorUtc'] } else { $State['initializedUtc'] })
    if (-not $last -or ((Get-WddNow) - $last).TotalMinutes -lt $limit) { return $false }
    try { $boot = Get-WddBootTime } catch { return $false }
    return ((Get-WddNow) - $boot).TotalMinutes -ge $limit
}

<# True when Windows still needed a restart the deployment did not do (limit reached, blocked, failed, or not done yet). #>
function Test-WddRestartOutstanding {
    param($State)
    return ((Get-WddRestartView $State).status -in 'Announced', 'Blocked', 'LimitReached', 'Failed')
}

<# The coordinated restart as the progress window and the LAN monitor show it. #>
function Get-WddRestartView {
    param($State)
    $rc = $(if ($State -and $State['restartCoordinator'] -is [hashtable]) { $State['restartCoordinator'] } else { $null })
    if (-not $rc) { return [ordered]@{ status = 'NotRequired'; reasons = @(); blockers = @(); restarts = 0; message = '' } }
    [ordered]@{ status = [string] $rc['status']; reasons = @($rc['reasons'] | Where-Object { $_ }); blockers = @($rc['blockers'] | Where-Object { $_ })
                restarts = [int] $rc['restarts']; message = [string] $rc['message'] }
}

<#
    One word for the whole deployment (progress window, LAN monitor):
      complete   finished (see overall)            attention  something needs a person
      recovering after a restart or an automatic recovery, while unfinished work is checked
      active     an engine is working              waiting    every running stage waits for something
#>
function Get-WddCondition {
    param($Snapshot, $State)
    if ($State -and [string] $State['status'] -eq 'Completed') { return 'complete' }
    if (-not $State -or [string] $State['status'] -in 'StagingFailed', 'IntegrityFailed') { return 'attention' }
    if (@($Snapshot.needsAttention).Count) { return 'attention' }
    if ($Snapshot.recovering) { return 'recovering' }
    if ($Snapshot.Contains('restart') -and $Snapshot.restart.status -in 'Announced', 'Restarting', 'Blocked') { return 'waiting' }
    if (@($Snapshot.stages | Where-Object { $_.condition -eq 'active' }).Count) { return 'active' }
    if (@($Snapshot.stages | Where-Object { $_.condition -ne 'finished' }).Count -eq 0) { return 'active' }
    return 'waiting'
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
    # Orchestrator 1.3.0: every stage has its final result, the deployment is not finished yet
    # (the bare-metal run showed code 40 with a startup message here): say exactly what is left.
    if ($stages.Count -and -not $live.Count) {
        $results = ($stages | ForEach-Object { "$($_.name): $($_.status)" }) -join '; '
        $rv = $(if ($Snapshot.Contains('restart')) { $Snapshot.restart } else { $null })
        if ($rv -and $rv.status -in 'Announced', 'Restarting', 'Blocked') {
            $what = $(if ($rv.status -eq 'Blocked') { "It waits because $(@($rv.blockers) -join '; ')." } elseif ($rv.status -eq 'Restarting') { 'The restart has been started.' } else { 'The deployment restarts the computer automatically at its next check when nothing is installing.' })
            return & $o 'PausedAwaitingReboot' "Every stage has finished ($results). Windows needs a restart: $(@($rv.reasons) -join '; '). $what After the restart Windows Update and Device Manager are checked again and the final report is written."
        }
        if ($Snapshot.Contains('finalizeError') -and $Snapshot.finalizeError) { return & $o 'InProgress' "Every stage has finished ($results), but writing the final report failed: $($Snapshot.finalizeError) It is tried again at the monitor's next run." }
        if ($Snapshot.Contains('monitorOverdue') -and $Snapshot.monitorOverdue) { return & $o 'PausedAwaitingUser' "Every stage has finished ($results), but the deployment monitor has not run to finish the deployment. Run Resume-Deployment.ps1 as administrator." }
        return & $o 'InProgress' "Every stage has finished ($results). The deployment monitor is finishing the deployment (restart check, Windows Update and Device Manager check, final report) at its next run."
    }
    if (($Snapshot -and $Snapshot.restartPending) -or @($live | Where-Object { $_.status -in 'Rebooting', 'RebootDeferred' }).Count) { return & $o 'PausedAwaitingReboot' 'A restart is scheduled or in progress; the deployment continues after it.' }
    $net = @($live | Where-Object { $_.status -eq 'WaitingForNetwork' })
    # Phase 8: offline because no network adapter has a driver: say so, the network will not appear by itself.
    if ($Snapshot -and $Snapshot.Contains('networkDriverMissing') -and $Snapshot.networkDriverMissing) { return & $o 'PausedAwaitingNetwork' ([string] $Snapshot.networkDriverMissing) }
    if ($net.Count) { return & $o 'PausedAwaitingNetwork' ("$(($net | ForEach-Object { $_.name }) -join ', '): waiting for the network. $(($net | ForEach-Object { $_.detail } | Where-Object { $_ }) -join '; ')".Trim()) }
    if ($Snapshot -and $Snapshot.Contains('monitorOverdue') -and $Snapshot.monitorOverdue) { return & $o 'PausedAwaitingUser' (@($Snapshot.needsAttention) | Select-Object -Last 1) }
    $user = @($live | Where-Object { $_.state -in 'Stalled', 'LaunchFailed' -or $_.idle })
    if ($user.Count) { return & $o 'PausedAwaitingUser' (($user | ForEach-Object { "$($_.name): $(if ($_.idle) { $_.idle } else { "$($_.state). $($_.detail)" })" }) -join ' ') }
    if ($Snapshot -and $Snapshot.currentStage) {
        $cur = @($live | Where-Object { $_.id -eq $Snapshot.currentStage } | Select-Object -First 1)
        return & $o 'InProgress' $(if ($cur.Count -and $cur[0].activity) { "$($cur[0].name): $($cur[0].activity)" } else { "Current stage: $($Snapshot.currentStage)." })
    }
    $waiting = @($live | Where-Object { $_.activity })
    return & $o 'InProgress' $(if ($waiting.Count) { (($waiting | ForEach-Object { "$($_.name): $($_.activity)" }) -join ' ') } else { 'Launching the deployment stages; no engine has reported yet.' })
}
