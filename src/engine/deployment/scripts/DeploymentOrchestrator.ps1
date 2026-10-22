#Requires -Version 5.1
<#
.SYNOPSIS
    Deployment monitor: follows the stages, keeps status.json current and finishes the deployment.

.DESCRIPTION
    Runs as SYSTEM from \WindowsDeploymentBuilder\Deployment (registered by
    Initialize-Deployment.ps1) at startup and every 15 minutes, so it survives every restart. Each
    run is short and idempotent:

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

    It never launches or re-launches an engine. A stage whose task disappeared without a result is
    reported as Stalled and needs Resume-Deployment.ps1, so no stage can loop.

    Phase 5: a damaged deployment.json is replaced by its last good copy; if neither is usable the
    monitor stops (StateCorrupt) instead of acting on a guess, and the recovery tool rebuilds it.
    status.json carries the machine-readable outcome (outcome, outcomeCode, outcomeDetail).
#>
[CmdletBinding()]
param()

$script:MonitorMain = $MyInvocation.InvocationName -ne '.'
. (Join-Path $PSScriptRoot '..\common\DeploymentCommon.ps1')
. (Join-Path $PSScriptRoot '..\finalization\Complete-Deployment.ps1')

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
        $snapshot = Get-WddSnapshot $manifest $Paths $state
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
