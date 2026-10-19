#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Deployment Builder - unattended Windows Update engine.

.DESCRIPTION
    Installs applicable Windows updates through the documented Windows Update Agent (WUA) COM API,
    reboots when required, resumes after each reboot through a SYSTEM scheduled task, and repeats
    until nothing applicable remains. Written independently for this project; no third-party code
    or modules.

    Modes:
      Run   (default) Full engine. Must run elevated (normally as SYSTEM from the scheduled task).
      Scan  Read-only: searches for updates and prints how each one would be handled. Installs
            nothing, writes no state, needs no elevation.

    Final states (result.json, Application event log source "WindowsDeploymentBuilder"):
      Succeeded               Nothing applicable remains.
      CompletedWithFailures   Everything else is installed, but some updates failed repeatedly
                              and were given up.
      Failed                  A limit was reached (reboots, runtime, errors) or scanning failed.
      Offline                 No network was available before the runtime limit.

    On Succeeded and CompletedWithFailures the marker <dataRoot>\state\windows-update.done is
    written for the deployment orchestrator. The scheduled task is removed on every final state.
#>
[CmdletBinding()]
param(
    [ValidateSet('Run', 'Scan')]
    [string] $Mode = 'Run',
    [string] $ConfigPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:EngineVersion = '1.0.0'
$script:UpgradeCategoryId = '3689bdc8-b205-4af4-8d4b-a63924c5e9d5'   # WUA category "Upgrades"
$script:MicrosoftUpdateServiceId = '7971f918-a847-4430-9279-4a52d1efe18d'
$script:EventSource = 'WindowsDeploymentBuilder'
$script:Session = $null
$script:LogFile = $null
$script:StatusFile = $null

# ------------------------------------------------------------------------------------------------
# Small helpers (time, waiting, JSON) - kept as functions so tests can replace them.
# ------------------------------------------------------------------------------------------------

function Get-WduNow { [DateTime]::UtcNow }

function Wait-Wdu { param([int] $Seconds) if ($Seconds -gt 0) { Start-Sleep -Seconds $Seconds } }

function ConvertTo-WduDate {
    param($Value)
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    [DateTime]::Parse([string] $Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

function Format-WduHResult {
    param($HResult)
    if ($null -eq $HResult) { return '' }
    '0x{0:X8}' -f ([int64] $HResult -band [int64] 4294967295)
}

function ConvertTo-WduHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-WduHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-WduHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return , @($InputObject | ForEach-Object { ConvertTo-WduHashtable $_ })
    }
    return $InputObject
}

function Write-WduJson {
    param([string] $Path, $Value)
    $json = $Value | ConvertTo-Json -Depth 10
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Read-WduJson {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    ConvertTo-WduHashtable (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

# ------------------------------------------------------------------------------------------------
# Configuration, paths, logging, status
# ------------------------------------------------------------------------------------------------

function Get-WduConfig {
    param([string] $Path)
    if (-not $Path) { $Path = Join-Path $PSScriptRoot 'config.json' }
    $raw = Read-WduJson $Path
    if (-not $raw) { throw "Configuration file not found: $Path" }
    $defaults = @{
        dataRoot             = 'C:\ProgramData\WindowsDeploymentBuilder'
        taskPath             = '\WindowsDeploymentBuilder\'
        taskName             = 'WindowsUpdate'
        mutexName            = 'Global\WindowsDeploymentBuilder-WindowsUpdate'
        drivers              = 'exclude'
        featureUpdates       = 'skip'
        optionalUpdates      = 'skip'
        microsoftUpdate      = $false
        maxReboots           = 10
        maxAttemptsPerUpdate = 2
        maxRuntimeHours      = 6
        maxErrors            = 5
        networkWaitMinutes   = 15
        confirmationScans    = 1
        confirmationDelaySeconds = 60
        resetComponentsOnce  = $true
        rebootWarningSeconds = 60
        initialDelaySeconds  = 60
        excludedKbs          = @()
    }
    foreach ($k in @($defaults.Keys)) { if (-not $raw.ContainsKey($k)) { $raw[$k] = $defaults[$k] } }
    $raw.excludedKbs = @($raw.excludedKbs | Where-Object { $_ } | ForEach-Object { ([string] $_).ToUpperInvariant() })
    return $raw
}

function Get-WduPaths {
    param([hashtable] $Config)
    $root = Join-Path $Config.dataRoot 'Updates'
    @{
        Root     = $root
        Logs     = Join-Path $root 'logs'
        Log      = Join-Path (Join-Path $root 'logs') 'engine.log'
        State    = Join-Path $root 'state.json'
        Status   = Join-Path $root 'status.json'
        Result   = Join-Path $root 'result.json'
        MarkerDir = Join-Path $Config.dataRoot 'state'
        Marker   = Join-Path (Join-Path $Config.dataRoot 'state') 'windows-update.done'
    }
}

function Write-WduLog {
    param([string] $Message, [ValidateSet('INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO')
    $line = '{0}  {1,-5}  {2}' -f (Get-WduNow).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Verbose $line
    if (-not $script:LogFile) { return }
    for ($i = 0; $i -lt 3; $i++) {
        try { [System.IO.File]::AppendAllText($script:LogFile, $line + "`r`n"); return }
        catch { Start-Sleep -Milliseconds 200 }
    }
}

function Limit-WduLogSize {
    param([string] $Path, [int64] $MaxBytes = 5MB)
    if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -gt $MaxBytes) {
        Move-Item -LiteralPath $Path -Destination "$Path.1" -Force
    }
}

function Set-WduStatus {
    param([string] $Phase, [string] $Detail = '', [hashtable] $State)
    if (-not $script:StatusFile) { return }
    $o = [ordered]@{
        phase      = $Phase
        detail     = $Detail
        updatedUtc = (Get-WduNow).ToString('o')
        computer   = $env:COMPUTERNAME
        version    = $script:EngineVersion
    }
    if ($State) {
        $o.starts = $State.starts
        $o.reboots = $State.reboots
        $o.installed = @($State.installed).Count
    }
    try { Write-WduJson $script:StatusFile $o } catch { Write-WduLog "Could not write status: $($_.Exception.Message)" 'WARN' }
}

function Write-WduEvent {
    param([int] $EventId, [string] $Message, [ValidateSet('Information', 'Warning', 'Error')] [string] $EntryType = 'Information')
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($script:EventSource)) {
            New-EventLog -LogName Application -Source $script:EventSource
        }
        Write-EventLog -LogName Application -Source $script:EventSource -EventId $EventId -EntryType $EntryType -Message $Message
    } catch {
        Write-WduLog "Could not write event $EventId to the Application log: $($_.Exception.Message)" 'WARN'
    }
}

# ------------------------------------------------------------------------------------------------
# State
# ------------------------------------------------------------------------------------------------

function New-WduState {
    @{
        version         = 1
        firstStartUtc   = $null
        starts          = 0
        reboots         = 0
        errors          = 0
        offlineStarts   = 0
        everOnline      = $false
        componentReset  = $false
        attempts        = @{}
        installed       = @()
        final           = $null
    }
}

function Read-WduState {
    param([hashtable] $Paths)
    $s = $null
    try { $s = Read-WduJson $Paths.State }
    catch {
        Write-WduLog "State file unreadable ($($_.Exception.Message)); keeping a copy and starting over." 'WARN'
        Copy-Item -LiteralPath $Paths.State -Destination "$($Paths.State).corrupt" -Force -ErrorAction SilentlyContinue
    }
    $fresh = New-WduState
    if (-not $s) { return $fresh }
    foreach ($k in @($fresh.Keys)) { if (-not $s.ContainsKey($k)) { $s[$k] = $fresh[$k] } }
    if ($null -eq $s.attempts) { $s.attempts = @{} }
    $s.installed = @($s.installed | Where-Object { $_ })
    return $s
}

function Save-WduState { param([hashtable] $State, [hashtable] $Paths) Write-WduJson $Paths.State $State }

# ------------------------------------------------------------------------------------------------
# Windows Update Agent adapter. Everything that touches the system lives here.
# Update objects returned to the engine are hashtables:
#   Id, Revision, Title, Kbs[], IsDriver, IsUpgrade, IsOptional, NeedsUserInput, IsDownloaded, Native
# ------------------------------------------------------------------------------------------------

function Get-WduSession {
    if (-not $script:Session) {
        $script:Session = New-Object -ComObject 'Microsoft.Update.Session'
        $script:Session.ClientApplicationID = 'Windows Deployment Builder'
    }
    $script:Session
}

function Get-WduAvailableUpdates {
    param([hashtable] $Config)
    $searcher = (Get-WduSession).CreateUpdateSearcher()
    if ($Config.microsoftUpdate) {
        $sm = New-Object -ComObject 'Microsoft.Update.ServiceManager'
        $sm.ClientApplicationID = 'Windows Deployment Builder'
        # 7 = asfAllowPendingRegistration + asfAllowOnlineRegistration + asfRegisterServiceWithAU
        [void] $sm.AddService2($script:MicrosoftUpdateServiceId, 7, '')
        $searcher.ServerSelection = 3   # ssOthers
        $searcher.ServiceID = $script:MicrosoftUpdateServiceId
    }
    $criteria = "IsInstalled=0 and IsHidden=0"
    if ($Config.drivers -ne 'include') { $criteria += " and Type='Software'" }
    $result = $searcher.Search($criteria)
    if ($result.ResultCode -notin 2, 3) { throw "Windows Update search returned result code $($result.ResultCode)." }
    $list = @()
    foreach ($u in $result.Updates) {
        $cats = @()
        foreach ($c in $u.Categories) { $cats += ([string] $c.CategoryID).ToLowerInvariant() }
        $kbs = @()
        foreach ($k in $u.KBArticleIDs) { $kbs += "KB$k" }
        $list += @{
            Id             = [string] $u.Identity.UpdateID
            Revision       = [int] $u.Identity.RevisionNumber
            Title          = [string] $u.Title
            Kbs            = $kbs
            IsDriver       = ([int] $u.Type -eq 2)
            IsUpgrade      = ($cats -contains $script:UpgradeCategoryId)
            IsOptional     = [bool] $u.BrowseOnly
            NeedsUserInput = [bool] $u.InstallationBehavior.CanRequestUserInput
            IsDownloaded   = [bool] $u.IsDownloaded
            Native         = $u
        }
    }
    return , $list
}

function ConvertTo-WduResultCode {
    param([int] $Code)
    switch ($Code) { 0 { 'NotStarted' } 1 { 'InProgress' } 2 { 'Succeeded' } 3 { 'SucceededWithErrors' } 4 { 'Failed' } 5 { 'Aborted' } default { "Unknown$Code" } }
}

function New-WduCollection {
    param([object[]] $Updates)
    $coll = New-Object -ComObject 'Microsoft.Update.UpdateColl'
    foreach ($u in $Updates) {
        if (-not $u.Native.EulaAccepted) { $u.Native.AcceptEula() }
        [void] $coll.Add($u.Native)
    }
    $coll
}

function Invoke-WduDownload {
    param([object[]] $Updates)
    $out = @{}
    $pending = @($Updates | Where-Object { -not $_.IsDownloaded })
    foreach ($u in $Updates) { if ($u.IsDownloaded) { $out[$u.Id] = @{ Result = 'Succeeded'; HResult = 0 } } }
    if ($pending.Count -eq 0) { return $out }
    try {
        $coll = New-WduCollection $pending
        $dl = (Get-WduSession).CreateUpdateDownloader()
        $dl.Updates = $coll
        $r = $dl.Download()
        for ($i = 0; $i -lt $pending.Count; $i++) {
            $ur = $r.GetUpdateResult($i)
            $out[$pending[$i].Id] = @{ Result = (ConvertTo-WduResultCode $ur.ResultCode); HResult = $ur.HResult }
        }
    } catch {
        foreach ($u in $pending) { $out[$u.Id] = @{ Result = 'Failed'; HResult = $_.Exception.HResult } }
        Write-WduLog "Download call failed: $($_.Exception.Message)" 'ERROR'
    }
    return $out
}

function Invoke-WduInstall {
    param([object[]] $Updates)
    $out = @{ RebootRequired = $false; Results = @{} }
    try {
        $coll = New-WduCollection $Updates
        $inst = (Get-WduSession).CreateUpdateInstaller()
        try { $inst.ForceQuiet = $true } catch { }
        $inst.Updates = $coll
        $r = $inst.Install()
        $out.RebootRequired = [bool] $r.RebootRequired
        for ($i = 0; $i -lt $Updates.Count; $i++) {
            $ur = $r.GetUpdateResult($i)
            $out.Results[$Updates[$i].Id] = @{ Result = (ConvertTo-WduResultCode $ur.ResultCode); HResult = $ur.HResult }
        }
    } catch {
        foreach ($u in $Updates) { $out.Results[$u.Id] = @{ Result = 'Failed'; HResult = $_.Exception.HResult } }
        Write-WduLog "Install call failed: $($_.Exception.Message)" 'ERROR'
    }
    return $out
}

function Test-WduRebootPending {
    try { if ((New-Object -ComObject 'Microsoft.Update.SystemInfo').RebootRequired) { return $true } } catch { }
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
                     'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        if (Test-Path -LiteralPath $key) { return $true }
    }
    return $false
}

function Test-WduInstallerBusy {
    try { return [bool] (New-Object -ComObject 'Microsoft.Update.Installer').IsBusy } catch { return $false }
}

function Test-WduNetwork {
    # Managed (WSUS) clients only need their update server; everyone else needs the Internet.
    $wsus = $null
    try {
        $au = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction Stop
        if ($au.UseWUServer -eq 1) {
            $wsus = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction Stop).WUServer
        }
    } catch { }
    if ($wsus) {
        $uri = [Uri] $wsus
        return (Test-WduTcp $uri.Host $uri.Port)
    }
    try {
        # Network Connectivity Status Indicator probe documented by Microsoft.
        $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 10
        if ($r.Content -eq 'Microsoft Connect Test') { return $true }
    } catch { }
    return (Test-WduTcp 'fe3.delivery.mp.microsoft.com' 443)
}

function Test-WduTcp {
    param([string] $HostName, [int] $Port)
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $tcp.BeginConnect($HostName, $Port, $null, $null)
        return ($iar.AsyncWaitHandle.WaitOne(5000) -and $tcp.Connected)
    } catch { return $false } finally { $tcp.Close() }
}

function Invoke-WduReboot {
    param([int] $WarningSeconds, [string] $Reason)
    # p:2:17 = planned, Operating System: Hot fix
    & "$env:SystemRoot\System32\shutdown.exe" /r /t $WarningSeconds /d p:2:17 /c "Windows Deployment Builder: $Reason. The computer restarts in $WarningSeconds seconds; updating resumes automatically."
    if ($LASTEXITCODE -ne 0) { throw "shutdown.exe failed with exit code $LASTEXITCODE" }
}

function Reset-WduComponents {
    # Microsoft's documented manual reset: stop the services, rename the data stores, restart.
    $services = 'wuauserv', 'bits', 'cryptsvc'
    foreach ($s in $services) { try { Stop-Service -Name $s -Force -ErrorAction Stop } catch { Write-WduLog "Could not stop ${s}: $($_.Exception.Message)" 'WARN' } }
    $stamp = (Get-WduNow).ToString('yyyyMMddHHmmss')
    foreach ($dir in "$env:SystemRoot\SoftwareDistribution", "$env:SystemRoot\System32\catroot2") {
        if (Test-Path -LiteralPath $dir) {
            try { Rename-Item -LiteralPath $dir -NewName ("{0}.{1}.old" -f (Split-Path $dir -Leaf), $stamp) -ErrorAction Stop; Write-WduLog "Renamed $dir." }
            catch { Write-WduLog "Could not rename ${dir}: $($_.Exception.Message)" 'WARN' }
        }
    }
    foreach ($s in $services) { try { Start-Service -Name $s -ErrorAction Stop } catch { Write-WduLog "Could not start ${s}: $($_.Exception.Message)" 'WARN' } }
    $script:Session = $null
}

function Unregister-WduTask {
    param([hashtable] $Config)
    try {
        $t = Get-ScheduledTask -TaskName $Config.taskName -TaskPath $Config.taskPath -ErrorAction Stop
        $t | Unregister-ScheduledTask -Confirm:$false
        Write-WduLog "Removed scheduled task $($Config.taskPath)$($Config.taskName)."
    } catch {
        Write-WduLog "Scheduled task $($Config.taskPath)$($Config.taskName) not removed: $($_.Exception.Message)" 'WARN'
    }
}

# ------------------------------------------------------------------------------------------------
# Single instance
# ------------------------------------------------------------------------------------------------

function Enter-WduMutex {
    param([string] $Name)
    $m = New-Object System.Threading.Mutex($false, $Name)
    try {
        if ($m.WaitOne([TimeSpan]::FromSeconds(10))) { return $m }
    } catch [System.Threading.AbandonedMutexException] {
        return $m   # previous owner died; we own it now
    }
    $m.Dispose()
    return $null
}

function Exit-WduMutex {
    param($Mutex)
    if ($Mutex) { try { $Mutex.ReleaseMutex() } catch { }; $Mutex.Dispose() }
}

# ------------------------------------------------------------------------------------------------
# Planning
# ------------------------------------------------------------------------------------------------

function Get-WduSkipReason {
    param([hashtable] $Update, [hashtable] $Config, [hashtable] $State)
    if ($Update.IsUpgrade -and $Config.featureUpdates -ne 'install') { return 'feature update (policy: skip)' }
    if ($Update.IsDriver -and $Config.drivers -ne 'include') { return 'driver (policy: exclude)' }
    if ($Update.IsOptional -and $Config.optionalUpdates -ne 'install') { return 'optional update (policy: skip)' }
    foreach ($kb in $Update.Kbs) { if ($Config.excludedKbs -contains $kb.ToUpperInvariant()) { return "excluded by configuration ($kb)" } }
    if ($Update.NeedsUserInput) { return 'requires user input' }
    $a = $State.attempts[$Update.Id]
    if ($a -and [int] $a.count -ge [int] $Config.maxAttemptsPerUpdate) { return "gave up after $($a.count) attempt(s)" }
    return $null
}

function Get-WduPlan {
    param([object[]] $Updates, [hashtable] $Config, [hashtable] $State)
    $plan = @{ Install = @(); Skipped = @(); GaveUp = @() }
    foreach ($u in $Updates) {
        $reason = Get-WduSkipReason $u $Config $State
        if (-not $reason) { $plan.Install += $u; continue }
        $entry = @{ id = $u.Id; title = $u.Title; kbs = @($u.Kbs); reason = $reason }
        if ($reason -like 'gave up*') {
            $a = $State.attempts[$u.Id]
            $entry.attempts = $a.count; $entry.lastResult = $a.lastResult; $entry.lastHResult = $a.lastHResult
            $plan.GaveUp += $entry
        } else {
            $plan.Skipped += $entry
        }
    }
    $plan
}

function Get-WduLabel { param([hashtable] $U) $kb = if (@($U.Kbs).Count) { ($U.Kbs -join ',') + ' ' } else { '' }; "$kb$($U.Title)" }

# ------------------------------------------------------------------------------------------------
# Outcomes
# ------------------------------------------------------------------------------------------------

function Complete-Wdu {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State, [string] $Status, [string] $Reason, $Plan = $null)
    $now = (Get-WduNow).ToString('o')
    $result = [ordered]@{
        status        = $Status
        reason        = $Reason
        engineVersion = $script:EngineVersion
        computer      = $env:COMPUTERNAME
        startedUtc    = $State.firstStartUtc
        finishedUtc   = $now
        starts        = $State.starts
        reboots       = $State.reboots
        installed     = @($State.installed)
        failed        = @(if ($Plan) { $Plan.GaveUp })
        skipped       = @(if ($Plan) { $Plan.Skipped })
    }
    Write-WduJson $Paths.Result $result
    $State.final = $Status
    Save-WduState $State $Paths
    if ($Status -in 'Succeeded', 'CompletedWithFailures') {
        if (-not (Test-Path -LiteralPath $Paths.MarkerDir)) { New-Item -ItemType Directory -Path $Paths.MarkerDir -Force | Out-Null }
        Write-WduJson $Paths.Marker ([ordered]@{ status = $Status; finishedUtc = $now; result = $Paths.Result })
    }
    $level = switch ($Status) { 'Succeeded' { 'INFO' } 'CompletedWithFailures' { 'WARN' } default { 'ERROR' } }
    Write-WduLog ("FINISHED: {0}. {1} Installed {2}, failed {3}, skipped {4}, reboots {5}." -f $Status, $Reason, @($result.installed).Count, @($result.failed).Count, @($result.skipped).Count, $State.reboots) $level
    foreach ($f in $result.failed) { Write-WduLog ("  FAILED   {0} {1} ({2} attempts, last {3} {4})" -f ($f.kbs -join ','), $f.title, $f.attempts, $f.lastResult, $f.lastHResult) 'WARN' }
    foreach ($s in $result.skipped) { Write-WduLog ("  SKIPPED  {0} {1}: {2}" -f ($s.kbs -join ','), $s.title, $s.reason) }
    $eventId = switch ($Status) { 'Succeeded' { 1100 } 'CompletedWithFailures' { 1101 } 'Failed' { 1102 } default { 1103 } }
    $entryType = switch ($Status) { 'Succeeded' { 'Information' } 'CompletedWithFailures' { 'Warning' } default { 'Error' } }
    Write-WduEvent $eventId "Windows Update automation finished: $Status. $Reason See $($Paths.Result)." $entryType
    Set-WduStatus $Status $Reason $State
    Unregister-WduTask $Config
    return "Finished:$Status"
}

function Request-WduReboot {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State, [string] $Reason, $Plan = $null)
    if ([int] $State.reboots -ge [int] $Config.maxReboots) {
        return Complete-Wdu $Config $Paths $State 'Failed' "Reboot limit ($($Config.maxReboots)) reached while a restart is still required ($Reason)." $Plan
    }
    $State.reboots = [int] $State.reboots + 1
    Save-WduState $State $Paths
    Write-WduLog "Restart $($State.reboots)/$($Config.maxReboots): $Reason. Resuming after boot."
    Set-WduStatus 'Rebooting' $Reason $State
    Write-WduEvent 1001 "Restarting to continue Windows Update ($Reason)."
    Invoke-WduReboot -WarningSeconds ([int] $Config.rebootWarningSeconds) -Reason $Reason
    return 'Rebooting'
}

function Test-WduDeadline {
    param([hashtable] $Config, [hashtable] $State)
    ((Get-WduNow) - (ConvertTo-WduDate $State.firstStartUtc)).TotalHours -ge [double] $Config.maxRuntimeHours
}

# ------------------------------------------------------------------------------------------------
# Main loop
# ------------------------------------------------------------------------------------------------

function Invoke-WduRun {
    param([hashtable] $Config, [hashtable] $Paths)
    $State = Read-WduState $Paths
    if ($State.final) {
        Write-WduLog "Already finished with status $($State.final); nothing to do."
        Unregister-WduTask $Config
        return 'AlreadyFinished'
    }
    $first = -not $State.firstStartUtc
    if ($first) { $State.firstStartUtc = (Get-WduNow).ToString('o') }
    $State.starts = [int] $State.starts + 1
    Save-WduState $State $Paths
    Write-WduLog "==== Engine $($script:EngineVersion) start $($State.starts) (reboots so far: $($State.reboots)) ===="
    Set-WduStatus 'Starting' "Start $($State.starts)" $State
    if ($first) {
        Write-WduEvent 1000 'Windows Update automation started.'
        Write-WduLog ("Policy: drivers={0}, feature updates={1}, optional={2}, Microsoft Update={3}; limits: {4} reboots, {5} attempts/update, {6} h." -f $Config.drivers, $Config.featureUpdates, $Config.optionalUpdates, $Config.microsoftUpdate, $Config.maxReboots, $Config.maxAttemptsPerUpdate, $Config.maxRuntimeHours)
        Wait-Wdu ([int] $Config.initialDelaySeconds)
    }

    if (Test-WduDeadline $Config $State) {
        if ($State.everOnline) { return Complete-Wdu $Config $Paths $State 'Failed' "Runtime limit ($($Config.maxRuntimeHours) h) reached." }
        return Complete-Wdu $Config $Paths $State 'Offline' "No network connection before the runtime limit ($($Config.maxRuntimeHours) h)."
    }

    # Network
    Set-WduStatus 'WaitingForNetwork' '' $State
    $deadline = (Get-WduNow).AddMinutes([double] $Config.networkWaitMinutes)
    $online = $false
    while ($true) {
        if (Test-WduNetwork) { $online = $true; break }
        if ((Get-WduNow) -ge $deadline) { break }
        Wait-Wdu 15
    }
    if (-not $online) {
        $State.offlineStarts = [int] $State.offlineStarts + 1
        Save-WduState $State $Paths
        Write-WduLog "No network after $($Config.networkWaitMinutes) min. The task retries at the next start or within the hour." 'WARN'
        Set-WduStatus 'WaitingForNetwork' 'No network; will retry' $State
        if (Test-WduDeadline $Config $State) {
            if ($State.everOnline) { return Complete-Wdu $Config $Paths $State 'Failed' "Runtime limit ($($Config.maxRuntimeHours) h) reached while offline." }
            return Complete-Wdu $Config $Paths $State 'Offline' "No network connection before the runtime limit ($($Config.maxRuntimeHours) h)."
        }
        return 'WaitingForNetwork'
    }
    if (-not $State.everOnline) { $State.everOnline = $true; Save-WduState $State $Paths }
    Write-WduLog 'Network available.'

    # Another update operation (for example Windows' own automatic updates) may be installing.
    for ($i = 0; $i -lt 60 -and (Test-WduInstallerBusy); $i++) {
        if ($i -eq 0) { Write-WduLog 'Windows Update installer is busy; waiting (max 30 min).' }
        Set-WduStatus 'WaitingForInstaller' '' $State
        Wait-Wdu 30
    }

    $emptyScans = 0
    $scanFailures = 0
    for ($pass = 1; $pass -le 50; $pass++) {
        if (Test-WduDeadline $Config $State) { return Complete-Wdu $Config $Paths $State 'Failed' "Runtime limit ($($Config.maxRuntimeHours) h) reached." }

        Set-WduStatus 'Scanning' "Pass $pass" $State
        Write-WduLog "Scan pass $pass."
        try {
            $updates = Get-WduAvailableUpdates $Config
            $scanFailures = 0
        } catch {
            $scanFailures++
            $hr = Format-WduHResult $_.Exception.HResult
            Write-WduLog "Scan failed ($scanFailures/3): $($_.Exception.Message) $hr" 'ERROR'
            if ($scanFailures -lt 3) { Wait-Wdu 60; continue }
            if ($Config.resetComponentsOnce -and -not $State.componentReset) {
                Write-WduLog 'Resetting Windows Update components once after repeated scan failures.' 'WARN'
                Set-WduStatus 'ResettingComponents' 'Scan failures' $State
                Reset-WduComponents
                $State.componentReset = $true
                Save-WduState $State $Paths
                $scanFailures = 0
                continue
            }
            return Complete-Wdu $Config $Paths $State 'Failed' "Windows Update scan keeps failing: $($_.Exception.Message) $hr"
        }

        $plan = Get-WduPlan $updates $Config $State
        Write-WduLog ("Found {0} update(s): {1} to install, {2} skipped by policy, {3} given up." -f @($updates).Count, @($plan.Install).Count, @($plan.Skipped).Count, @($plan.GaveUp).Count)

        if (@($plan.Install).Count -eq 0) {
            if (Test-WduRebootPending) { return Request-WduReboot $Config $Paths $State 'a restart is pending to finish installed updates' $plan }
            $emptyScans++
            if ($emptyScans -le [int] $Config.confirmationScans) {
                Write-WduLog "Nothing to install; confirmation scan $emptyScans/$($Config.confirmationScans) after $($Config.confirmationDelaySeconds) s."
                Set-WduStatus 'Confirming' "Confirmation scan $emptyScans" $State
                Wait-Wdu ([int] $Config.confirmationDelaySeconds)
                continue
            }
            if (@($plan.GaveUp).Count -gt 0) {
                return Complete-Wdu $Config $Paths $State 'CompletedWithFailures' "$(@($plan.GaveUp).Count) update(s) failed repeatedly and were given up." $plan
            }
            return Complete-Wdu $Config $Paths $State 'Succeeded' 'No applicable updates remain.' $plan
        }
        $emptyScans = 0

        # Count the attempt before acting, so a crash or hang mid-install still counts.
        foreach ($u in $plan.Install) {
            $a = $State.attempts[$u.Id]
            if (-not $a) { $a = @{ count = 0; title = $u.Title; kbs = @($u.Kbs); lastResult = ''; lastHResult = '' }; $State.attempts[$u.Id] = $a }
            $a.count = [int] $a.count + 1
            Write-WduLog ("  queued   {0} (attempt {1}/{2})" -f (Get-WduLabel $u), $a.count, $Config.maxAttemptsPerUpdate)
        }
        Save-WduState $State $Paths

        Set-WduStatus 'Downloading' "$(@($plan.Install).Count) update(s)" $State
        $dl = Invoke-WduDownload $plan.Install
        $ready = @()
        foreach ($u in $plan.Install) {
            $r = $dl[$u.Id]
            if ($r -and $r.Result -in 'Succeeded', 'SucceededWithErrors') { $ready += $u; continue }
            $a = $State.attempts[$u.Id]
            $a.lastResult = if ($r) { "Download$($r.Result)" } else { 'DownloadMissing' }
            $a.lastHResult = if ($r) { Format-WduHResult $r.HResult } else { '' }
            Write-WduLog ("  download failed {0}: {1} {2}" -f (Get-WduLabel $u), $a.lastResult, $a.lastHResult) 'WARN'
        }

        $rebootRequired = $false
        if ($ready.Count -gt 0) {
            Set-WduStatus 'Installing' "$($ready.Count) update(s)" $State
            $in = Invoke-WduInstall $ready
            $rebootRequired = [bool] $in.RebootRequired
            foreach ($u in $ready) {
                $r = $in.Results[$u.Id]
                $a = $State.attempts[$u.Id]
                $a.lastResult = if ($r) { $r.Result } else { 'Missing' }
                $a.lastHResult = if ($r) { Format-WduHResult $r.HResult } else { '' }
                if ($r -and $r.Result -in 'Succeeded', 'SucceededWithErrors') {
                    $State.installed += @{ id = $u.Id; title = $u.Title; kbs = @($u.Kbs); result = $r.Result; atUtc = (Get-WduNow).ToString('o') }
                    Write-WduLog ("  installed {0} ({1})" -f (Get-WduLabel $u), $r.Result)
                } else {
                    Write-WduLog ("  install failed {0}: {1} {2}" -f (Get-WduLabel $u), $a.lastResult, $a.lastHResult) 'WARN'
                }
            }
        }
        Save-WduState $State $Paths

        # An update about to be given up gets one more chance after a component reset.
        $exhausted = @($plan.Install | Where-Object {
            $a = $State.attempts[$_.Id]
            [int] $a.count -ge [int] $Config.maxAttemptsPerUpdate -and $a.lastResult -notin 'Succeeded', 'SucceededWithErrors'
        })
        if ($exhausted.Count -gt 0 -and $Config.resetComponentsOnce -and -not $State.componentReset) {
            Write-WduLog "$($exhausted.Count) update(s) keep failing; resetting Windows Update components once." 'WARN'
            Set-WduStatus 'ResettingComponents' 'Repeated update failures' $State
            Reset-WduComponents
            $State.componentReset = $true
            foreach ($u in $exhausted) { $State.attempts[$u.Id].count = [int] $Config.maxAttemptsPerUpdate - 1 }
            Save-WduState $State $Paths
            return Request-WduReboot $Config $Paths $State 'Windows Update components were reset'
        }

        if ($rebootRequired -or (Test-WduRebootPending)) {
            return Request-WduReboot $Config $Paths $State 'installed updates require a restart'
        }
    }
    return Complete-Wdu $Config $Paths $State 'Failed' 'Safety limit of 50 passes without a restart reached.'
}

function Invoke-WduMain {
    param([hashtable] $Config)
    $paths = Get-WduPaths $Config
    foreach ($d in $paths.Root, $paths.Logs) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
    $script:LogFile = $paths.Log
    $script:StatusFile = $paths.Status
    Limit-WduLogSize $paths.Log

    $mutex = Enter-WduMutex $Config.mutexName
    if (-not $mutex) {
        Write-WduLog 'Another engine instance is running; exiting.'
        return 'AlreadyRunning'
    }
    try {
        return Invoke-WduRun -Config $Config -Paths $paths
    } catch {
        $err = $_
        Write-WduLog "Unhandled error: $($err.Exception.Message) $(Format-WduHResult $err.Exception.HResult)`r`n$($err.ScriptStackTrace)" 'ERROR'
        $state = Read-WduState $paths
        $state.errors = [int] $state.errors + 1
        Save-WduState $state $paths
        if ($state.errors -ge [int] $Config.maxErrors -and -not $state.final) {
            return Complete-Wdu $Config $paths $state 'Failed' "Stopped after $($state.errors) unexpected errors. Last: $($err.Exception.Message)"
        }
        Set-WduStatus 'Error' "$($err.Exception.Message) (will retry)" $state
        return 'Error'
    } finally {
        Exit-WduMutex $mutex
    }
}

function Invoke-WduScan {
    param([hashtable] $Config)
    $state = New-WduState
    $updates = Get-WduAvailableUpdates $Config
    $plan = Get-WduPlan $updates $Config $state
    $rows = @()
    foreach ($u in $plan.Install) { $rows += [pscustomobject]@{ Action = 'Install'; KB = ($u.Kbs -join ','); Title = $u.Title; Reason = '' } }
    foreach ($s in $plan.Skipped) { $rows += [pscustomobject]@{ Action = 'Skip'; KB = ($s.kbs -join ','); Title = $s.title; Reason = $s.reason } }
    [pscustomobject]@{
        Updates       = $rows
        RebootPending = Test-WduRebootPending
        InstallerBusy = Test-WduInstallerBusy
    }
}

# Dot-sourcing (tests) only defines the functions.
if ($MyInvocation.InvocationName -ne '.') {
    $cfg = Get-WduConfig $ConfigPath
    if ($Mode -eq 'Scan') {
        $scan = Invoke-WduScan $cfg
        $scan.Updates | Format-Table -AutoSize -Wrap | Out-String -Width 200
        "Reboot pending: $($scan.RebootPending). Installer busy: $($scan.InstallerBusy)."
        exit 0
    }
    $outcome = Invoke-WduMain $cfg
    Write-Output $outcome
    if ($outcome -eq 'Error' -or $outcome -eq 'Finished:Failed') { exit 1 }
    exit 0
}
