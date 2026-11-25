#Requires -Version 5.1
<#
.SYNOPSIS
    Deployment monitor: follows the stages, keeps status.json current and finishes the deployment.

.DESCRIPTION
    Runs as SYSTEM from \WindowsDeploymentBuilder\Deployment (registered by
    Initialize-Deployment.ps1) at startup and every monitorIntervalMinutes (5 for packages from
    orchestrator 1.2.0, 15 before), so it survives every restart. Each run is short and idempotent:

      1. Single instance (mutex shared with Initialize and Resume).
      2. Verifies the staged package against its manifest before doing anything else. A modified
         or missing file stops the deployment monitor (IntegrityFailed); nothing is executed.
      3. Reads what each engine wrote (result.json, status.json, its task) and writes
         <dataRoot>\Deployment\status.json. Completion markers are not trusted on their own:
         the final status always comes from result.json.
      4. Once the windowsUpdate stage is final, applies the ongoing update policy if the package
         carries one (Set-UpdatePolicy.ps1, Phase 4.3).
      5. When every enabled stage is final, or the deadline has passed, runs
         Complete-Deployment.ps1 (report, marker, event, cleanup).

    Orchestrator 1.2.0 (watchdog, startup reconciliation; the same monitor, not a second one):
      - Restart detection: a new boot is recorded as planned (an engine scheduled it: restart
        marker, a stage that was Rebooting or whose restart count grew) or unexpected, in the
        state (restarts) and the activity feed, and the deployment shows "recovering" while the
        unfinished stages are checked.
      - Bounded automatic recovery, at most autoRecoveries times per stage (2 by default):
          SYSTEM stage whose task is gone without a result  -> its installer runs again
                                                               (Invoke-WddLaunchStage, as Resume does)
          stage with no progress whose task is not running -> its task is started again
        A stage of the signed-in user is never started from SYSTEM: it is reported with what to do.
        When the budget is used up the stage stays Stalled and needs a technician; no loop.
      - Stage changes, recoveries and restarts go to the activity feed.
      - The progress window and LAN monitor tasks are registered again if they are missing.
    Engines keep their own single-instance guards, so a recovery never runs an engine twice.

    Phase 5: a damaged deployment.json is replaced by its last good copy; if neither is usable the
    monitor stops (StateCorrupt) instead of acting on a guess, and the recovery tool rebuilds it.
    status.json carries the machine-readable outcome (outcome, outcomeCode, outcomeDetail).
#>
[CmdletBinding()]
param()

$script:MonitorMain = $MyInvocation.InvocationName -ne '.'
. (Join-Path $PSScriptRoot '..\common\DeploymentCommon.ps1')
. (Join-Path $PSScriptRoot '..\finalization\Complete-Deployment.ps1')
# Orchestrator 1.2.0: the launch and task functions used by the watchdog (functions only when dot-sourced).
. (Join-Path $PSScriptRoot '..\bootstrap\Initialize-Deployment.ps1')

<#
    Records a new boot: planned when an engine scheduled it (restart marker of the previous boot, a
    stage that was Rebooting, or a stage whose restart count grew since the last run), otherwise
    unexpected. Returns the record, or $null when Windows has not restarted since the last run.
#>
function Step-WddRestartCheck {
    param([hashtable] $Paths, [hashtable] $State, [hashtable] $Manifest)
    try { $boot = Get-WddBootTime } catch { return $null }
    $prev = ConvertTo-WddDate $State['lastBootUtc']
    $State.lastBootUtc = $boot.ToString('o')
    if (-not $prev -or [Math]::Abs(($boot - $prev).TotalSeconds) -le 2) { return $null }
    $planned = $false; $by = ''; $reason = ''
    $m = Read-WddJson $Paths.RestartMarker
    if ($m -is [hashtable]) {
        $mb = ConvertTo-WddDate $m['bootTimeUtc']
        if ($mb -and [Math]::Abs(($mb - $prev).TotalSeconds) -le 2) { $planned = $true; $by = [string] $m['owner']; $reason = [string] $m['reason'] }
    }
    $seen = $(if ($State['seenReboots'] -is [hashtable]) { $State['seenReboots'] } else { @{} })
    $phases = $(if ($State['seenPhases'] -is [hashtable]) { $State['seenPhases'] } else { @{} })
    foreach ($s in Get-WddEngineStages $Manifest) {
        if ($planned) { break }
        $st = Read-WddJson (Join-Path $Paths.Root $s.status)
        $now = $(if ($st -is [hashtable] -and $st.ContainsKey('reboots')) { [int] $st['reboots'] } else { 0 })
        if ($now -gt [int] $seen[$s.id] -or [string] $phases[$s.id] -in 'Rebooting', 'RebootDeferred') { $planned = $true; $by = $s.name; $reason = $(if ($st -is [hashtable]) { [string] $st['detail'] } else { '' }) }
    }
    $rec = [ordered]@{ bootUtc = $boot.ToString('o'); previousBootUtc = $prev.ToString('o'); detectedUtc = (Get-WddNow).ToString('o'); planned = $planned; by = $by; reason = $reason }
    $State.restarts = @(@(@($State['restarts']) | Where-Object { $_ }) + @($rec) | Select-Object -Last 50)
    $State.recoveringUntilUtc = (Get-WddNow).AddMinutes(10).ToString('o')
    $msg = $(if ($planned) { "Windows restarted (scheduled by $(if ($by) { $by } else { 'the deployment' })$(if ($reason) { ": $reason" })). Restoring deployment progress and checking unfinished tasks." }
             else { 'Windows restarted unexpectedly (the deployment had not scheduled a restart). Restoring deployment progress and checking unfinished tasks; interrupted operations are resumed or reported.' })
    Add-WddActivity $Paths $msg $(if ($planned) { 'info' } else { 'warning' })
    Write-WddEvent 3007 $msg $(if ($planned) { 'Information' } else { 'Warning' })
    return $rec
}

<# What the next restart check compares against: each stage's restart count and phase. #>
function Save-WddSeenStages {
    param([hashtable] $State, $Snapshot)
    $r = @{}; $p = @{}
    foreach ($s in @($Snapshot.stages)) { $r[$s.id] = [int] $s.reboots; $p[$s.id] = [string] $s.status }
    $State.seenReboots = $r; $State.seenPhases = $p
}

<#
    Bounded automatic recovery of stalled stages (see the description). Returns the number of
    recoveries attempted in this run.
#>
function Invoke-WddWatchdog {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $State, $Snapshot)
    $o = $Manifest.failureHandling.orchestrator
    $max = $(if ($o -is [hashtable] -and $o.ContainsKey('autoRecoveries')) { [int] $o.autoRecoveries } else { 2 })
    $acted = 0
    foreach ($s in @($Snapshot.stages)) {
        if ($s.state -eq 'Final' -or -not $State.stages.ContainsKey($s.id)) { continue }
        $stage = Get-WddStage $Manifest $s.id
        $rec = $State.stages[$s.id]
        $action = $null; $why = ''
        if ($s.state -eq 'Stalled') { $action = 'Relaunch'; $why = 'its scheduled task is missing and it has no result' }
        elseif ($s.state -eq 'LaunchFailed' -and [string] $rec['message'] -notlike '*must be started by the signed-in user*') { $action = 'Relaunch'; $why = "it could not be started ($($rec['message']))" }
        elseif ($s.stale) {
            $info = Get-WddTaskInfo $stage.task.path $stage.task.name
            if ($info.Exists -and $info.State -ne 'Running') { $action = 'StartTask'; $why = "no progress for $($s.staleMinutes) minutes and its task is not running (last result 0x$('{0:X8}' -f ([int64] $info.LastResult -band 4294967295)))" }
            elseif ($info.Exists) {
                if (-not $rec['staleReported']) {
                    $rec.staleReported = $true
                    Add-WddActivity $Paths "$($s.name): no progress detected for $($s.staleMinutes) minutes while its task is still running. Waiting; technician attention may be required if this continues." 'warning'
                }
                continue
            }
        }
        if (-not $action) { if ($rec['staleReported'] -and -not $s.stale) { $rec.staleReported = $false }; continue }
        if ($stage.context -eq 'user') {
            # WinGet runs only as the signed-in user: never started from SYSTEM.
            if (-not $rec['userActionReported']) {
                $rec.userActionReported = $true
                $who = $(if ($rec['user']) { [string] $rec['user'] } else { 'the deployment user' })
                Add-WddActivity $Paths "$($s.name): $why. It must be restarted by $who`: sign in and run Resume-Deployment.ps1 -RestartStage $($s.id) as administrator. Technician attention required." 'error'
            }
            continue
        }
        $used = [int] $rec['autoRecoveries']
        if ($used -ge $max) {
            if (-not $rec['autoRecoveryExhausted']) {
                $rec.autoRecoveryExhausted = $true
                $msg = "$($s.name): $why. Automatic recovery was already attempted $max time(s). Technician attention required: see the log, then run Resume-Deployment.ps1 -RestartStage $($s.id)."
                Add-WddActivity $Paths $msg 'error'
                Write-WddEvent 3008 $msg 'Error'
            }
            continue
        }
        $rec.autoRecoveries = $used + 1
        $ok = $false; $err = ''
        if ($action -eq 'Relaunch') {
            $rec.launchResult = ''; $rec.attempts = 0
            $r = Invoke-WddLaunchStage $stage $Paths $State (Get-WddIdentity) ([int] $o.launchAttempts)
            $ok = $r.launchResult -eq 'Launched'
            if (-not $ok) { $err = [string] $r.message }
        } else {
            try { Start-WddTask $stage.task.path $stage.task.name; $ok = $true } catch { $err = $_.Exception.Message }
        }
        $State.recoveries = @(@($State['recoveries']) + @(@{ atUtc = (Get-WddNow).ToString('o'); by = 'monitor (automatic)'; action = "Automatic$action"; stage = $s.id; reason = $why
                                                            accepted = @(if ($ok) { "stage:$($s.id)" }); refused = @(if (-not $ok) { "stage:$($s.id)" }); attempt = $rec.autoRecoveries; message = $err }))
        $State.recoveringUntilUtc = (Get-WddNow).AddMinutes(10).ToString('o')
        $msg = "$($s.name): no progress ($why). Automatic recovery attempted ($(if ($action -eq 'Relaunch') { 'stage started again' } else { 'task started again' }), $($rec.autoRecoveries) of $max): $(if ($ok) { 'done; technician attention may be required if it still does not progress.' } else { "it failed: $err Technician attention may be required." })"
        Add-WddActivity $Paths $msg $(if ($ok) { 'warning' } else { 'error' })
        Write-WddEvent 3008 $msg $(if ($ok) { 'Warning' } else { 'Error' })
        $acted++
    }
    return $acted
}

<# One activity entry for every stage whose state or phase changed since the last run. #>
function Step-WddStageActivity {
    param([hashtable] $Paths, [hashtable] $State, $Snapshot)
    $seen = $(if ($State['seenStages'] -is [hashtable]) { $State['seenStages'] } else { @{} })
    foreach ($s in @($Snapshot.stages)) {
        $sig = "$($s.state)|$($s.status)"
        if ([string] $seen[$s.id] -eq $sig) { continue }
        $seen[$s.id] = $sig
        $level = $(if ($s.condition -eq 'blocked') { 'warning' } elseif ($s.state -eq 'Final') { $(if ($s.outcome -eq 'ok') { 'info' } elseif ($s.outcome -eq 'failed') { 'error' } else { 'warning' }) } else { 'info' })
        Add-WddActivity $Paths "$($s.name): $($s.activity)" $level
    }
    $State.seenStages = $seen
}

<# The progress window and LAN monitor tasks, registered again if they were removed while the deployment runs. #>
function Confirm-WddHelperTasks {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $State)
    $user = [string] $State['initializedBy']
    $missing = (-not (Get-WddTask $script:ProgressTask.path $script:ProgressTask.name) -and $user -and $user -notmatch '(?i)^(NT AUTHORITY\\)?SYSTEM$') -or
               ((Get-WddMonitorConfig $Manifest) -and -not (Get-WddTask $script:StatusServerTask.path $script:StatusServerTask.name))
    if (-not $missing) { return }
    $problems = @(Register-WddHelperTasks $Manifest $Paths $user)
    Add-WddActivity $Paths $(if ($problems.Count) { "A helper task could not be registered again: $($problems -join '; ')" } else { 'The progress window and monitor tasks were registered again.' }) $(if ($problems.Count) { 'warning' } else { 'info' })
}

function Invoke-WddMonitor {
    param([hashtable] $Paths)
    Initialize-WddLogging $Paths
    $mutex = Enter-WddMutex 30
    if (-not $mutex) { Write-WddLog 'Monitor: another deployment process is running; skipping this run.'; return 'Busy' }
    try {
        $read = Read-WddDeploymentState $Paths
        $state = $read.State
        if ($read.Source -eq 'corrupt') {
            $msg = "The deployment state is damaged and its backup is unusable ($($read.Problem)). The monitor stopped; nothing is run. Run DeploymentRecovery.ps1 -Action Resume to rebuild it."
            Write-WddLog $msg 'ERROR'
            $snap = [ordered]@{ updatedUtc = (Get-WddNow).ToString('o'); deploymentState = 'StateCorrupt'; overall = 'Failed'; message = $msg }
            Set-WddSnapshotOutcome $snap $null $read.Problem
            Write-WddJson $Paths.Status $snap
            Write-WddEvent 3004 $msg 'Error'
            return 'StateCorrupt'
        }
        if (-not $state) { Write-WddLog 'Monitor: no deployment state; nothing to follow.' 'WARN'; return 'NoState' }
        if ($state.status -eq 'Completed') { Unregister-WddTask '\WindowsDeploymentBuilder\' 'Deployment'; return 'AlreadyCompleted' }
        if ($state.status -eq 'IntegrityFailed') { return 'IntegrityFailed' }

        $manifestPath = Join-Path $Paths.Package 'deployment-manifest.json'
        try { $manifest = Read-WddManifest $manifestPath } catch { $manifest = $null; $err = $_.Exception.Message }
        $check = if ($manifest) { Test-WddFiles $Paths.Package $manifest 'Text' @($state.stagedFiles) } else { @{ Ok = $false; Missing = @('deployment-manifest.json'); Mismatched = @() } }
        if (-not $check.Ok -or ($manifest -and $manifest.packageId -ne $state.packageId)) {
            $state.status = 'IntegrityFailed'
            $state.message = "The staged package was modified or is incomplete ($($check.Missing.Count) missing, $($check.Mismatched.Count) modified). The monitor stopped; nothing more is run by it."
            Save-WddState $Paths $state
            Write-WddLog $state.message 'ERROR'
            foreach ($m in @($check.Missing) + @($check.Mismatched)) { Write-WddLog "  $m" 'ERROR' }
            $snap = [ordered]@{ packageId = $state.packageId; updatedUtc = (Get-WddNow).ToString('o'); deploymentState = 'IntegrityFailed'; overall = 'Failed'; message = $state.message }
            Set-WddSnapshotOutcome $snap $state
            Write-WddJson $Paths.Status $snap
            Write-WddEvent 3003 $state.message 'Error'
            return 'IntegrityFailed'
        }

        $state.monitorRuns = [int] $state.monitorRuns + 1
        $state.lastMonitorUtc = (Get-WddNow).ToString('o')
        Limit-WddActivity $Paths
        # Orchestrator 1.2.0: restart detection, bounded recovery, activity feed, helper tasks.
        [void] (Step-WddRestartCheck $Paths $state $manifest)
        $snapshot = Get-WddSnapshot $manifest $Paths $state
        if ((Invoke-WddWatchdog $manifest $Paths $state $snapshot) -gt 0) { $snapshot = Get-WddSnapshot $manifest $Paths $state }
        Step-WddStageActivity $Paths $state $snapshot
        Save-WddSeenStages $state $snapshot
        if (-not $snapshot.allFinal) { try { Confirm-WddHelperTasks $manifest $Paths $state } catch { Write-WddLog "Helper tasks: $($_.Exception.Message)" 'WARN' } }
        # Phase 4.3: the ongoing update policy, once the initial Windows Update stage is final.
        if (Get-Command Step-WddUpdatePolicy -ErrorAction SilentlyContinue) {
            $policy = Step-WddUpdatePolicy $manifest $Paths $state $snapshot
            if ($policy) { $snapshot.updatePolicy = $policy }
        }
        Save-WddState $Paths $state
        Write-WddJson $Paths.Status $snapshot
        $summary = (@($snapshot.stages) | ForEach-Object { "$($_.id)=$($_.state)$(if ($_.status) { "/$($_.status)" })" }) -join ', '
        Write-WddLog "Monitor run $($state.monitorRuns): $summary"

        if ($snapshot.allFinal) {
            $overall = Complete-WddDeployment $manifest $Paths $state $snapshot
            return "Completed:$overall"
        }
        $deadline = ConvertTo-WddDate $state.deadlineUtc
        if ($deadline -and (Get-WddNow) -ge $deadline) {
            Write-WddLog "Deadline $($state.deadlineUtc) reached with unfinished stages." 'WARN'
            $overall = Complete-WddDeployment $manifest $Paths $state $snapshot -DeadlineReached
            return "Completed:$overall"
        }
        return 'InProgress'
    } finally {
        Exit-WddMutex $mutex
    }
}

if ($script:MonitorMain) {
    # The monitor lives in <dataRoot>\Package\scripts\orchestrator; dataRoot comes from the manifest.
    $package = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $manifest = Read-WddManifest (Join-Path $package 'deployment-manifest.json')
    $outcome = Invoke-WddMonitor (Get-WddPaths $manifest.dataRoot)
    Write-Output $outcome
    if ($outcome -in 'IntegrityFailed', 'StateCorrupt') { exit 1 }
    exit 0
}
