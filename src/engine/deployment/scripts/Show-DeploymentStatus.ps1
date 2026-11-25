#Requires -Version 5.1
<#
.SYNOPSIS
    Shows the deployment progress in the console (read-only; no elevation needed).

.DESCRIPTION
    Reads the deployment state and what each engine wrote, live (it does not wait for the monitor):
    current stage, what each stage is doing and why it waits, when it last made progress, the
    application being installed, applications remaining, pending restart, recent activity
    (restarts, retries, failures, recoveries), whether a person needs to act, and the address of
    the LAN monitor when the package enables it.

    Orchestrator 1.3.0: the window runs without elevation and cannot see the SYSTEM tasks, so it
    never reports a task as missing itself (the SYSTEM monitor's own view is used); it shows the
    restart Windows still needs and when the monitor last ran (overdue: needs attention).

    -Watch refreshes every 7 seconds until the deployment has finished. Orchestrator 1.2.0: the
    task \WindowsDeploymentBuilder\Progress opens it with -Watch -AutoStarted at every sign-in of
    the deployment user while the deployment runs. Only one window runs per session (a second one
    exits at once). It is a viewer: closing it never affects the deployment, and it stops opening
    once the deployment has finished (the task is removed then; -AutoStarted also exits at once
    when the deployment is already complete).

    Phase 9: when the deployment verifies itself and its configuration asks for it, the watching
    window opens the technician health report once, when verification has written it (never at a
    later sign-in).
#>
[CmdletBinding()]
param(
    [switch] $Watch,
    [int] $IntervalSeconds = 7,
    [switch] $AutoStarted
)

$script:ShowMain = $MyInvocation.InvocationName -ne '.'
$script:ShowArgs = @{ Watch = [bool] $Watch; Interval = [Math]::Max(2, $IntervalSeconds); AutoStarted = [bool] $AutoStarted }
. (Join-Path $PSScriptRoot '..\common\DeploymentCommon.ps1')

$script:ProgressMutexName = 'Local\WindowsDeploymentBuilder-Progress'
$script:ConditionText = @{ active = 'Working'; waiting = 'Waiting'; idle = 'Idle'; blocked = 'NEEDS ATTENTION'; finished = 'Finished' }

<# The LAN monitor's address and token as the status server wrote them (state\monitor.json), or $null. #>
function Get-WddMonitorInfo {
    param([hashtable] $Paths)
    if (-not $Paths.ContainsKey('MonitorInfo')) { return $null }
    $m = Read-WddJson $Paths.MonitorInfo
    if ($m -is [hashtable] -and $m['token'] -and $m['port']) { return $m }
    return $null
}

<# Lines describing how to reach the LAN monitor (empty when the package has none). #>
function Format-WddMonitorLines {
    param([hashtable] $Manifest, [hashtable] $Paths)
    $l = @()
    if (-not $Manifest.ContainsKey('monitor') -or $Manifest.monitor -isnot [hashtable] -or -not $Manifest.monitor['enabled']) { return }
    $m = Get-WddMonitorInfo $Paths
    if (-not $m) { return 'Monitor        : starting (the address appears here once it runs)' }
    if ([string] $m['mode'] -in 'stopped', 'error') { return "Monitor        : $($m['mode']). $($m['message'])" }
    $fragment = "/#t=$($m['token'])"
    $lan = @(@($m['urls']) | Where-Object { $_ -and $_ -notmatch '127\.0\.0\.1|localhost' })
    if ($m['lanAccess'] -and $lan.Count) {
        $l += "Monitor        : $($lan[0])$fragment"
        foreach ($u in @($lan | Select-Object -Skip 1)) { $l += "                 $u$fragment" }
        $l += '                 Open it in a browser on another computer, phone or tablet on this network (read-only).'
    } else {
        $l += "Monitor        : http://127.0.0.1:$($m['port'])$fragment  (this computer only)"
    }
    if ($m['message']) { $l += "                 $($m['message'])" }
    return $l
}

function Format-WddStatus {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $State)
    $s = Get-WddSnapshot $Manifest $Paths $State
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add('Windows Deployment Builder - deployment progress')
    $l.Add('================================================')
    $overall = if ($State -and $State.status -eq 'Completed') { "Finished: $($State.overall)" } elseif ($State) { $State.status } else { 'Not started' }
    $cond = $(if ($s.Contains('condition')) { [string] $s.condition } else { '' })
    $l.Add("Deployment     : $overall$(if ($cond -and $cond -ne 'complete') { " ($cond)" })")
    $l.Add("Outcome        : $($s.outcome) (code $($s.outcomeCode)) $($s.outcomeDetail)")
    if ($State -and $State.message) { $l.Add("                 $($State.message)") }
    if ($State) { $l.Add("Started (UTC)  : $($State.initializedUtc)   deadline: $($State.deadlineUtc)") }
    $l.Add("Current stage  : $(if ($s.currentStage) { $s.currentStage } else { '-' })")
    $l.Add("Last activity  : $(if ($s.Contains('lastActivityUtc') -and $s.lastActivityUtc) { "$(Format-WddAge $s.lastActivityUtc) ($($s.lastActivityUtc))" } else { 'none reported yet' })")
    # Orchestrator 1.3.0: the restart Windows needs, and whether the SYSTEM monitor still runs.
    $rv = $(if ($s.Contains('restart')) { $s.restart } else { $null })
    if ($rv -and $rv.status -in 'Announced', 'Blocked', 'Restarting', 'LimitReached', 'Failed') { $l.Add("Restart        : $($rv.status). $($rv.message)") }
    else { $l.Add("Restart pending: $(if ($s.restartPending) { 'yes (a restart has been scheduled)' } else { 'no' })") }
    if ($s.Contains('monitorLastRunUtc') -and $State -and $State.status -ne 'Completed') {
        $l.Add("Monitor checks : $(if ($s.monitorLastRunUtc) { "last $(Format-WddAge $s.monitorLastRunUtc)" } else { 'not run yet' }), every $(Get-WddMonitorInterval $Manifest) min$(if ($s.monitorOverdue) { ' - OVERDUE (see NEEDS ATTENTION)' })")
    }
    if ($script:WddTaskVisibility -eq 'Limited') { $l.Add('Task view      : this window runs without administrator rights, so task problems are taken from the deployment monitor.') }
    if ($s.Contains('recovering') -and $s.recovering) { $l.Add('Recovering     : Windows restarted or a stage was recovered; unfinished tasks are being checked.') }
    foreach ($m in Format-WddMonitorLines $Manifest $Paths) { $l.Add($m) }
    $l.Add('')
    $l.Add(('{0,-22} {1,-16} {2}' -f 'Stage', 'State', 'What is happening'))
    foreach ($st in @($s.stages)) {
        $c = $(if ($st.Contains('condition') -and $script:ConditionText.ContainsKey([string] $st.condition)) { $script:ConditionText[[string] $st.condition] } else { $st.state })
        $what = $(if ($st.Contains('activity') -and $st.activity) { $st.activity } else { "$($st.status) $($st.detail)".Trim() })
        $l.Add(('{0,-22} {1,-16} {2}' -f $st.name, $c, $what))
        if ($st.id -eq 'applications') {
            if ($st.current) { $l.Add("  installing now: $($st.current) (progress unavailable: WinGet does not report it)") }
            if ($null -ne $st.total -and [int] $st.total -gt 0) { $l.Add("  applications: $($st.done) of $($st.total) done, $([int] $st.total - [int] $st.done) remaining$(if ($st.Contains('counts') -and $st.counts.Contains('failed') -and [int] $st.counts.failed) { ", $($st.counts.failed) failed" })") }
        }
        if ($st.Contains('lastError') -and $st.lastError -and $st.state -ne 'Final') { $l.Add("  last problem ($(Format-WddAge $st.lastErrorUtc)): $($st.lastError)") }
        if ($st.reboots) { $l.Add("  restarts so far: $($st.reboots)") }
        if ($st.outstanding) { $l.Add("  outstanding operations: $($st.outstanding) (retry them with the deployment recovery tool)") }
    }
    if ($s.drivers.state -eq 'NotPartOfDeployment') { $l.Add(('{0,-22} {1,-16} {2}' -f 'Hardware & drivers', 'Off', 'Not part of this deployment')) }
    elseif ($s.drivers.state -eq 'NotImplemented') { $l.Add(('{0,-22} {1,-16} {2}' -f 'Manufacturer drivers', 'NotImplemented', 'Not part of this version')) }
    if ($s.Contains('networkDriverMissing') -and $s.networkDriverMissing) { $l.Add("NETWORK: $($s.networkDriverMissing)") }
    $l.Add('')
    $recent = @(Read-WddActivity $Paths 6)
    if ($recent.Count) {
        $l.Add('Recent activity')
        foreach ($e in $recent) {
            $t = ConvertTo-WddDate $e['utc']
            $l.Add(('  {0}  {1}' -f $(if ($t) { $t.ToLocalTime().ToString('HH:mm:ss') } else { '--:--:--' }), $e['message']))
        }
        $l.Add('')
    }
    if (@($s.needsAttention).Count) {
        $l.Add('NEEDS ATTENTION')
        foreach ($n in $s.needsAttention) { $l.Add("  - $n") }
        $l.Add("  Recovery: run (elevated) $(Join-Path $Paths.Package 'scripts\orchestrator\Resume-Deployment.ps1')")
        $l.Add('')
    }
    if ($State -and $State.status -in 'StagingFailed', 'IntegrityFailed') { $l.Add("FAILED: $($State.message)"); $l.Add('') }
    if (Test-Path -LiteralPath $Paths.ReportText) { $l.Add("Report: $($Paths.ReportText)") }
    $l.Add("Logs  : $($Paths.Log)")
    [pscustomobject]@{ Text = ($l -join "`r`n"); Done = [bool] ($State -and $State.status -in 'Completed', 'StagingFailed', 'IntegrityFailed') }
}

<# Phase 9: the technician report, once it has been written for the finished deployment. #>
function Get-WddHealthReportToOpen {
    param([hashtable] $Paths, $State)
    $cfg = Read-WddJson (Join-Path $Paths.Package 'scripts\health\health-config.json')
    if (-not $cfg -or -not ($cfg['options'] -is [hashtable]) -or -not $cfg['options']['openReportAfterDeployment'] -or -not $cfg['options']['technicianReport']) { return '' }
    $html = Join-Path (Join-Path $Paths.Root ([string] $cfg['reportDir'])) 'technician-report.html'
    $done = ConvertTo-WddDate $(if ($State) { $State['completedUtc'] } else { $null })
    if ((Test-Path -LiteralPath $html) -and (-not $done -or (Get-Item -LiteralPath $html).LastWriteTimeUtc -ge $done.AddSeconds(-5))) { return $html }
    return ''
}

<#
    Orchestrator 1.2.0: one progress window per session. Returns the held mutex, or $null when
    another window already shows the progress.
#>
function Enter-WddProgressWindow {
    $created = $false
    $m = New-Object System.Threading.Mutex($false, $script:ProgressMutexName, [ref] $created)
    try { if ($m.WaitOne(0)) { return $m } } catch [System.Threading.AbandonedMutexException] { return $m }
    $m.Dispose()
    return $null
}

<# What an automatically opened window does: $true = show the progress, $false = exit (finished or not started). #>
function Test-WddShowAutomatically {
    param($State)
    return [bool] ($State -and [string] $State.status -notin 'Completed', 'StagingFailed')
}

if ($script:ShowMain) {
    $package = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $manifest = Read-WddManifest (Join-Path $package 'deployment-manifest.json')
    $paths = Get-WddPaths $manifest.dataRoot
    # Orchestrator 1.3.0: without elevation the SYSTEM tasks are invisible; never report them as missing.
    $script:WddTaskVisibility = Get-WddTaskVisibility
    $state = (Read-WddDeploymentState $paths).State
    # Opened at sign-in: nothing to show once the deployment has finished.
    if ($script:ShowArgs.AutoStarted -and -not (Test-WddShowAutomatically $state)) { exit 0 }
    $window = $null
    if ($script:ShowArgs.Watch) {
        $window = Enter-WddProgressWindow
        if (-not $window) { Write-Output 'The deployment progress window is already open.'; exit 0 }
        try { $Host.UI.RawUI.WindowTitle = 'Deployment Progress - Windows Deployment Builder' } catch { }
    }
    try {
        do {
            $state = (Read-WddDeploymentState $paths).State
            $out = Format-WddStatus $manifest $paths $state
            if ($script:ShowArgs.Watch) { Clear-Host }
            Write-Output $out.Text
            if (-not $script:ShowArgs.Watch -or $out.Done) { break }
            Write-Output ''
            Write-Output "Refreshing every $($script:ShowArgs.Interval) s ($((Get-Date).ToString('HH:mm:ss'))). You can close this window; the deployment continues."
            Start-Sleep -Seconds $script:ShowArgs.Interval
        } while ($true)
        if ($script:ShowArgs.Watch -and $state -and $state.status -eq 'Completed') {
            # Verification runs right after completion: wait for its report (at most 5 minutes), open it once.
            $html = ''
            for ($i = 0; $i -lt 20 -and -not $html; $i++) { $html = Get-WddHealthReportToOpen $paths $state; if (-not $html) { Start-Sleep -Seconds 15; $state = (Read-WddDeploymentState $paths).State } }
            if ($html) {
                Write-Output ''
                Write-Output "Health report: $html"
                try { Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList "`"$html`"" } catch { Write-Output "Open it by hand: $($_.Exception.Message)" }
            }
        }
        if ($script:ShowArgs.Watch) { Write-Output ''; Read-Host 'Press Enter to close' | Out-Null }
    } finally {
        if ($window) { try { $window.ReleaseMutex() } catch { }; $window.Dispose() }
    }
    exit 0
}
