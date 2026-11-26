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

    Orchestrator 1.3.0 (bare-metal review):
      - Restart coordination (Step-WddRestartCoordinator): a restart Windows still needs (servicing
        indicators, devices with code 14, applications that need one) is announced, then done
        when nothing installs, under the install lock, after saving the state; at most
        coordinatedRestarts per deployment, never twice in one boot.
      - The deployment finishes only after that restart: Windows Update is searched again
        (one more run of its stage when it offers more) and Device Manager is checked in the new
        boot.
      - Finalization never hangs: an error is logged and retried; after finalizeAttempts a
        minimal report ends the deployment with a follow-up.

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

# ------------------------------------------------------------------------------------------------
# Orchestrator 1.3.0: restart coordination, update re-check, safe finalization
# ------------------------------------------------------------------------------------------------

# Stage phases during which a restart interrupts nothing (the engine is not working; it continues after the boot).
$script:RestartSafePhases = @('RebootDeferred', 'WaitingForRestart', 'WaitingForReboot', 'WaitingForLock', 'WaitingForNetwork', 'WaitingForUpdates', 'WaitingForDrivers', 'WaitingForApplications', 'Error')

function Get-WddOrchestratorLimit {
    param([hashtable] $Manifest, [string] $Name, [int] $Default)
    $o = $Manifest.failureHandling['orchestrator']
    if ($o -is [hashtable] -and $o.ContainsKey($Name) -and $null -ne $o[$Name]) { return [int] $o[$Name] }
    return $Default
}

<#
    Why Windows needs a restart now (empty: it does not): its own servicing indicators, devices
    whose driver needs a restart (Device Manager code 14) and applications that finished with
    "restart required". Device problems that a restart does not fix are not reasons.
#>
function Get-WddRestartNeed {
    param($Snapshot)
    $reasons = @(Get-WddServicingRestart | Where-Object { $_ })
    try {
        $dev = @(Get-WddPnpDevices | Where-Object { $_ -is [System.Collections.IDictionary] -and [int] $_['problemCode'] -eq 14 })
        if ($dev.Count) { $reasons += "$($dev.Count) device(s) need a restart to finish installing their driver ($((@($dev | ForEach-Object { [string] $_['name'] }) | Select-Object -First 3) -join ', '))" }
    } catch { }
    foreach ($s in @($Snapshot.stages)) {
        if ($s.state -ne 'Final' -or $s.result -isnot [hashtable] -or -not $s.result.ContainsKey('packages')) { continue }
        $apps = @(@($s.result['packages']) | Where-Object { $_ -is [hashtable] -and [string] $_['status'] -eq 'RequiresRestart' })
        if ($apps.Count) { $reasons += "$($apps.Count) application(s) need a restart to finish ($((@($apps | ForEach-Object { [string] $_['name'] }) | Select-Object -First 3) -join ', '))" }
    }
    return @{ Required = ($reasons.Count -gt 0); Reasons = $reasons }
}

<#
    Restarts the computer when Windows needs it and nothing is being installed. The engines restart
    for themselves while they run; this covers what they cannot: a restart still required when a
    stage (or every stage) has finished, and a restart an engine had to defer.
      1. A restart is needed (Get-WddRestartNeed) and no engine has scheduled one in this boot.
      2. First sighting: announced (activity feed, progress window); the restart happens at the
         next run at the earliest, so an engine that is about to restart itself goes first.
      3. Blockers, re-checked at every run: a stage that is working (installing, downloading,
         scanning ...), the Windows Update installer busy, an MSI installation running, a stage
         task that would not resume after the boot, the install lock held by an engine.
      4. Then: install lock taken (and held through the warning), restart marker written, state
         saved, shutdown /r with a warning; the restart is recorded and expected at the next boot.
    Loop prevention: at most coordinatedRestarts per deployment, never twice in the same boot; when
    the limit is reached Windows' pending restart is reported for the technician instead.
    Returns the restart view status: NotRequired, EngineRestartScheduled, Announced, Blocked,
    Restarting, LimitReached, Failed.
#>
function Step-WddRestartCoordinator {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $State, $Snapshot)
    $max = Get-WddOrchestratorLimit $Manifest 'coordinatedRestarts' 3
    $warn = Get-WddOrchestratorLimit $Manifest 'restartWarningSeconds' 120
    $rc = $(if ($State['restartCoordinator'] -is [hashtable]) { $State['restartCoordinator'] } else { @{ restarts = 0; status = 'NotRequired'; reasons = @(); blockers = @(); history = @() } })
    $State.restartCoordinator = $rc
    $boot = $(try { (Get-WddBootTime).ToString('o') } catch { '' })
    if ($rc['lastRestartBoot'] -and [string] $rc['lastRestartBoot'] -eq $boot -and $rc['status'] -eq 'Restarting') { return 'Restarting' }
    if ($Snapshot.restartPending) { $rc.status = 'EngineRestartScheduled'; $rc.message = 'An engine has scheduled a restart.'; return $rc.status }
    $need = Get-WddRestartNeed $Snapshot
    if (-not $need.Required) {
        if ($rc['status'] -in 'Announced', 'Blocked') { Add-WddActivity $Paths 'Windows no longer reports a pending restart; no restart is needed.' }
        $rc.status = 'NotRequired'; $rc.reasons = @(); $rc.blockers = @(); $rc.message = ''; $rc.pendingSinceUtc = $null
        return $rc.status
    }
    $rc.reasons = @($need.Reasons)
    if ([int] $rc['restarts'] -ge $max) {
        if ($rc['status'] -ne 'LimitReached') {
            $rc.message = "Windows still needs a restart ($(@($need.Reasons) -join '; ')) after $max automatic restart(s); no further automatic restart (restart-loop protection). Restart the computer once by hand, then check the report."
            Add-WddActivity $Paths $rc.message 'error'
            Write-WddEvent 3010 $rc.message 'Error'
        }
        $rc.status = 'LimitReached'
        return $rc.status
    }
    $blockers = @()
    foreach ($s in @($Snapshot.stages)) {
        if ($s.state -eq 'Final') { continue }
        if ($s.state -eq 'Running' -and [string] $s.status -notin $script:RestartSafePhases) { $blockers += "$($s.name) is working ($($s.status))" }
        $stage = Get-WddStage $Manifest $s.id
        if ($stage -and $s.state -in 'Running', 'Pending' -and -not (Get-WddTask $stage.task.path $stage.task.name)) { $blockers += "the task of $($s.name) is missing, so it would not continue after the restart" }
        if ($s.state -in 'Stalled', 'LaunchFailed') { $blockers += "$($s.name) is $($s.state) and would not continue after the restart" }
    }
    $inst = Test-WddInstallerActive
    if ($inst) { $blockers += $inst }
    $now = Get-WddNow
    if ($rc['status'] -notin 'Announced', 'Blocked' -or -not $rc['pendingSinceUtc']) {
        $rc.pendingSinceUtc = $now.ToString('o'); $rc.status = 'Announced'; $rc.blockers = @($blockers)
        $rc.message = "Windows needs a restart: $(@($need.Reasons) -join '; '). The deployment restarts the computer automatically at its next check (in about $(Get-WddMonitorInterval $Manifest) minutes) when nothing is being installed."
        Add-WddActivity $Paths $rc.message
        return $rc.status
    }
    if ($blockers.Count) {
        $sig = ($blockers -join '|')
        if ([string] $rc['blockedBy'] -ne $sig) {
            $rc.blockedBy = $sig
            Add-WddActivity $Paths "A restart is needed but waits: $($blockers -join '; '). It happens automatically once this clears." 'warning'
        }
        $rc.status = 'Blocked'; $rc.blockers = @($blockers)
        $rc.message = "A restart is needed ($(@($need.Reasons) -join '; ')) but waits: $($blockers -join '; ')."
        return $rc.status
    }
    $lock = Enter-WddInstallLock $Paths
    if (-not $lock) {
        $rc.status = 'Blocked'; $rc.blockers = @('another installation holds the install lock')
        $rc.message = "A restart is needed ($(@($need.Reasons) -join '; ')) but an installation holds the install lock; it waits for it to finish."
        return $rc.status
    }
    try {
        $reason = "Windows needs a restart ($(@($need.Reasons) -join '; '))"
        $rc.restarts = [int] $rc['restarts'] + 1
        $rc.status = 'Restarting'; $rc.blockers = @(); $rc.blockedBy = ''; $rc.lastRestartBoot = $boot; $rc.lastRestartUtc = $now.ToString('o'); $rc.pendingSinceUtc = $null
        $rc.history = @(@(@($rc['history']) | Where-Object { $_ }) + @([ordered]@{ atUtc = $now.ToString('o'); reasons = @($need.Reasons); restart = [int] $rc.restarts }) | Select-Object -Last 20)
        $rc.message = "$reason. Restarting the computer (automatic restart $($rc.restarts) of at most $max); the deployment continues after the restart."
        # Durable before anything else: the next boot is recognised as planned, the engines start nothing new.
        Set-WddRestartMarker $Paths $reason
        Save-WddState $Paths $State
        Add-WddActivity $Paths $rc.message
        Write-WddEvent 3009 $rc.message 'Information'
        Write-WddLog $rc.message 'WARN'
        Invoke-WddRestart $warn $reason
        Wait-WddRestart ($warn + 60)
    } catch {
        $rc.status = 'Failed'; $rc.message = "The automatic restart could not be started: $($_.Exception.Message) Restart the computer by hand."
        Add-WddActivity $Paths $rc.message 'error'
        Write-WddLog $rc.message 'ERROR'
        Remove-Item -LiteralPath $Paths.RestartMarker -Force -ErrorAction SilentlyContinue
    } finally {
        Exit-WddInstallLock $lock
    }
    return $rc.status
}

<#
    After the stages have finished and Windows needs no further restart: a read-only Windows Update
    search under the deployment's own policy. Updates Windows offers only now (often after a
    restart) get one more run of the Windows Update stage (updateRechecks, 1 by default); after
    that, what is still offered is reported, never hidden behind "no updates remain".
    Returns Relaunched, NothingOffered, Remaining, CheckFailed or Skipped.
#>
function Step-WddUpdateRecheck {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $State, $Snapshot)
    $wu = @(@($Snapshot.stages) | Where-Object { $_.id -eq 'windowsUpdate' } | Select-Object -First 1)
    if (-not $wu.Count -or $wu[0].state -ne 'Final' -or $wu[0].status -eq 'Offline') { return 'Skipped' }
    $rk = $(if ($State['updateRecheck'] -is [hashtable]) { $State['updateRecheck'] } else { @{ relaunches = 0; status = '' } })
    $State.updateRecheck = $rk
    # Once per final result of the stage: a relaunched stage that finishes again is checked again.
    $sig = "$($wu[0].status)|$($wu[0].updatedUtc)"
    if ([string] $rk['checkedFor'] -eq $sig) { return [string] $rk['status'] }
    $cfg = Read-WddJson (Join-Path $Paths.Root 'Updates\config.json')
    $list = $null
    try { $list = @(Get-WddOfferedUpdates $cfg | Where-Object { $_ -is [System.Collections.IDictionary] }) }
    catch {
        $rk.checkedFor = $sig; $rk.status = 'CheckFailed'; $rk.checkedUtc = (Get-WddNow).ToString('o'); $rk.message = "Windows Update could not be searched again: $($_.Exception.Message)"
        Add-WddActivity $Paths $rk.message 'warning'
        return $rk.status
    }
    $rk.checkedFor = $sig; $rk.checkedUtc = (Get-WddNow).ToString('o'); $rk.remaining = @($list)
    if (-not $list.Count) { $rk.status = 'NothingOffered'; $rk.message = 'Windows Update was searched again after the stages finished: nothing the deployment installs is offered.'; Add-WddActivity $Paths $rk.message; return $rk.status }
    $names = (@($list | ForEach-Object { "$((@($_['kbs']) -join ',')) $($_['title'])".Trim() }) | Select-Object -First 5) -join '; '
    $max = Get-WddOrchestratorLimit $Manifest 'updateRechecks' 1
    $stage = Get-WddStage $Manifest 'windowsUpdate'
    if ([int] $rk['relaunches'] -lt $max -and $stage) {
        $rk.relaunches = [int] $rk['relaunches'] + 1
        $State.stages['windowsUpdate'] = @{ launchResult = ''; attempts = 0; launchedUtc = $null; exitCode = $null; message = "Run again: Windows Update offered $($list.Count) more update(s) after the stage finished."; user = 'SYSTEM' }
        $r = Invoke-WddLaunchStage $stage $Paths $State (Get-WddIdentity) ([int] $Manifest.failureHandling.orchestrator.launchAttempts)
        if ($r.launchResult -eq 'Launched') {
            $rk.status = 'Relaunched'
            $rk.message = "Windows Update offers $($list.Count) more update(s) ($names); the Windows Update stage runs once more ($($rk.relaunches) of $max)."
            Add-WddActivity $Paths $rk.message
            return $rk.status
        }
        Add-WddActivity $Paths "Windows Update offers $($list.Count) more update(s), but its stage could not be started again: $($r.message)" 'warning'
    }
    $rk.status = 'Remaining'
    $rk.message = "Windows Update still offers $($list.Count) update(s) the deployment would install ($names). Install them from Settings > Windows Update."
    Add-WddActivity $Paths $rk.message 'warning'
    return $rk.status
}

<#
    Finishes the deployment and never leaves it hanging: an error while writing the report is
    logged with its location and retried at the next run; after finalizeAttempts failures a minimal
    report is written and the deployment ends with a follow-up (the error is in the report).
#>
function Invoke-WddFinalize {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $State, $Snapshot, [switch] $DeadlineReached)
    try {
        $overall = Complete-WddDeployment $Manifest $Paths $State $Snapshot -DeadlineReached:$DeadlineReached
        return "Completed:$overall"
    } catch {
        $err = $_
        $State.finalizeFailures = [int] $State['finalizeFailures'] + 1
        $State.lastFinalizeError = "$($err.Exception.Message) ($(@($err.ScriptStackTrace -split "`n")[0]))"
        Write-WddLog "Finishing the deployment failed ($($State.finalizeFailures)): $($err.Exception.Message)`r`n$($err.ScriptStackTrace)" 'ERROR'
        $max = Get-WddOrchestratorLimit $Manifest 'finalizeAttempts' 3
        if ([int] $State.finalizeFailures -lt $max) {
            Add-WddActivity $Paths "Writing the final report failed (attempt $($State.finalizeFailures) of $max): $($err.Exception.Message). Tried again at the next check." 'error'
            Save-WddState $Paths $State
            $Snapshot.finalizeError = $State.lastFinalizeError
            Set-WddSnapshotOutcome $Snapshot $State
            Write-WddJson $Paths.Status $Snapshot
            return 'FinalizeFailed'
        }
        $overall = Get-WddOverall $Snapshot.stages -DeadlineReached:$DeadlineReached
        if ($overall -eq 'Succeeded') { $overall = 'CompletedWithFollowUp' }
        $now = (Get-WddNow).ToString('o')
        $msg = "The final report could not be written after $max attempts ($($State.lastFinalizeError)); this minimal report lists the stage results. See $($Paths.Log)."
        $report = [ordered]@{ packageId = $Manifest.packageId; generatedUtc = $now; overall = $overall; reason = $msg; minimal = $true
                              stages = @(@($Snapshot.stages) | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; state = $_.state; status = $_.status; detail = $_.detail } }) }
        try { Write-WddJson $Paths.ReportJson $report; [IO.File]::WriteAllText($Paths.ReportText, "Windows Deployment Builder - deployment report (minimal)`r`nOverall: $overall`r`n$msg`r`n" + ((@($report.stages) | ForEach-Object { "$($_.name): $($_.state) $($_.status) $($_.detail)" }) -join "`r`n"), (New-Object System.Text.UTF8Encoding($true))) } catch { }
        Write-WddJson $Paths.Marker ([ordered]@{ status = $overall; finishedUtc = $now; report = $Paths.ReportJson })
        $State.status = 'Completed'; $State.overall = $overall; $State.completedUtc = $now; $State.message = $msg
        Save-WddState $Paths $State
        $Snapshot.deploymentState = 'Completed'; $Snapshot.overall = $overall
        Set-WddSnapshotOutcome $Snapshot $State
        Write-WddJson $Paths.Status $Snapshot
        Add-WddActivity $Paths "Deployment finished: $overall. $msg" 'error'
        Write-WddEvent 3105 $msg 'Error'
        try { Unregister-WddTask '\WindowsDeploymentBuilder\' 'Deployment'; Unregister-WddTask '\WindowsDeploymentBuilder\' 'Progress' } catch { }
        return "Completed:$overall"
    }
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
        $deadline = ConvertTo-WddDate $state.deadlineUtc
        $deadlineReached = [bool] ($deadline -and (Get-WddNow) -ge $deadline)
        # Orchestrator 1.3.0: a restart Windows needs, before finishing and whenever no stage is working.
        $restart = 'NotRequired'
        if (-not $deadlineReached) {
            try { $restart = Step-WddRestartCoordinator $manifest $Paths $state $snapshot } catch { Write-WddLog "Restart coordination: $($_.Exception.Message)" 'WARN' }
            $snapshot.restart = Get-WddRestartView $state
        }
        # After the stages and any restart: Windows Update is searched again (one more run if it offers more).
        $recheck = ''
        if ($snapshot.allFinal -and $restart -in 'NotRequired', 'LimitReached', 'Failed') {
            try { $recheck = Step-WddUpdateRecheck $manifest $Paths $state $snapshot } catch { Write-WddLog "Windows Update re-check: $($_.Exception.Message)" 'WARN' }
            if ($recheck -eq 'Relaunched') { $snapshot = Get-WddSnapshot $manifest $Paths $state }
        }
        Set-WddSnapshotOutcome $snapshot $state
        $snapshot.condition = Get-WddCondition $snapshot $state
        Save-WddState $Paths $state
        Write-WddJson $Paths.Status $snapshot
        $summary = (@($snapshot.stages) | ForEach-Object { "$($_.id)=$($_.state)$(if ($_.status) { "/$($_.status)" })" }) -join ', '
        Write-WddLog "Monitor run $($state.monitorRuns): $summary; restart: $restart$(if ($recheck) { "; update re-check: $recheck" })"

        if ($snapshot.allFinal) {
            # Finished only when no restart is still to be done (a blocked one waits at most restartWaitMinutes).
            $hold = $restart -in 'Announced', 'Restarting', 'EngineRestartScheduled'
            if ($restart -eq 'Blocked') {
                $since = ConvertTo-WddDate $state.restartCoordinator['pendingSinceUtc']
                $hold = -not $since -or ((Get-WddNow) - $since).TotalMinutes -lt (Get-WddOrchestratorLimit $manifest 'restartWaitMinutes' 120)
            }
            if ($hold) { return 'WaitingForRestart' }
            # Schema 9: the optional activation stage, last, once (never holds the deployment).
            if (Get-Command Step-WddActivation -ErrorAction SilentlyContinue) {
                try { [void] (Step-WddActivation $manifest $Paths $state $snapshot $restart); $snapshot.activation = Get-WddActivationView $manifest $state } catch { Write-WddLog "Activation: $($_.Exception.Message)" 'WARN' }
            }
            return (Invoke-WddFinalize $manifest $Paths $state $snapshot)
        }
        if ($deadlineReached) {
            Write-WddLog "Deadline $($state.deadlineUtc) reached with unfinished stages." 'WARN'
            return (Invoke-WddFinalize $manifest $Paths $state $snapshot -DeadlineReached)
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
