#Requires -Version 5.1
<#
.SYNOPSIS
    Manual recovery for a deployment: re-checks the package, re-registers the monitor and, only
    when asked, restarts a stage.

.DESCRIPTION
    Run elevated (as the signed-in user when restarting the applications stage):

      Resume-Deployment.ps1
          Verifies <dataRoot>\Package, registers the monitor task again and runs it once. Use it
          after a stalled stage was fixed, after the deadline passed, or if the monitor task was
          removed. A finished deployment is reopened (its report is rewritten at the end).
      Resume-Deployment.ps1 -RestartStage windowsUpdate|applications|drivers
          Runs that engine's installer again. The installer archives the previous run and starts
          a new one; work already done is detected (installed updates are not offered again,
          installed applications are reported AlreadyInstalled). If the installer does not
          register its task, the result is StageRestartFailed with the reason (exit code 1),
          never Resumed. Windows Setup and the disk are never touched.
      Resume-Deployment.ps1 -Status
          Prints the progress and changes nothing.

    It never deletes logs, results or the state file.
#>
[CmdletBinding()]
param(
    [ValidateSet('', 'windowsUpdate', 'applications', 'drivers')]
    [string] $RestartStage = '',
    [switch] $Status
)

$script:ResumeMain = $MyInvocation.InvocationName -ne '.'
$script:ResumeArgs = @{ RestartStage = $RestartStage; Status = [bool] $Status }
. (Join-Path $PSScriptRoot '..\common\DeploymentCommon.ps1')
. (Join-Path $PSScriptRoot '..\bootstrap\Initialize-Deployment.ps1')
. (Join-Path $PSScriptRoot 'Show-DeploymentStatus.ps1')

function Invoke-WddResume {
    param([hashtable] $Paths, [string] $RestartStage)
    Initialize-WddLogging $Paths
    $identity = Get-WddIdentity
    if (-not $identity.IsAdmin) { return 'RefusedNotElevated' }
    $mutex = Enter-WddMutex 60
    if (-not $mutex) { return 'Busy' }
    try {
        $read = Read-WddDeploymentState $Paths
        if ($read.Source -eq 'corrupt') { Write-WddLog "Resume: the deployment state is damaged ($($read.Problem)). Use DeploymentRecovery.ps1 -Action Resume, which rebuilds it." 'ERROR'; return 'StateCorrupt' }
        $state = $read.State
        if (-not $state) { Write-WddLog 'Resume: no deployment state. Start a deployment with setup.ps1 or Initialize-Deployment.ps1.' 'ERROR'; return 'NoState' }
        $manifestPath = Join-Path $Paths.Package 'deployment-manifest.json'
        $manifest = Read-WddManifest $manifestPath
        $check = Test-WddFiles $Paths.Package $manifest 'Text' @($state.stagedFiles)
        if (-not $check.Ok) {
            Write-WddLog "Resume refused: the staged package is modified or incomplete ($($check.Missing.Count) missing, $($check.Mismatched.Count) modified). Run setup.ps1 from the original package to stage it again." 'ERROR'
            return 'IntegrityFailed'
        }
        Write-WddLog "==== Resume requested by $($identity.Name)$(if ($RestartStage) { " (restart stage $RestartStage)" }) ===="
        if ($state.status -in 'Completed', 'IntegrityFailed') {
            if (Test-Path -LiteralPath $Paths.Marker) { Move-Item -LiteralPath $Paths.Marker -Destination "$($Paths.Marker).$((Get-WddNow).ToString('yyyyMMddHHmmss')).bak" -Force }
        }
        $state.status = 'InProgress'
        $state.message = 'Resumed manually.'
        $state.deadlineUtc = (Get-WddNow).AddHours([double] $manifest.failureHandling.orchestrator.deadlineHours).ToString('o')
        if ($RestartStage) {
            $stage = Get-WddStage $manifest $RestartStage
            if (-not $stage -or -not $stage.enabled) { Write-WddLog "Stage $RestartStage is not part of this deployment." 'ERROR'; return 'UnknownStage' }
            $state.stages[$RestartStage] = @{ launchResult = ''; attempts = 0; launchedUtc = $null; exitCode = $null; message = 'Restarted manually.' }
            $rec = Invoke-WddLaunchStage $stage $Paths $state $identity ([int] $manifest.failureHandling.orchestrator.launchAttempts)
            if ($rec.launchResult -ne 'Launched') {
                # Recorded (the monitor reports the stage as failed to launch); never reported as resumed.
                $state.message = "Restart of stage $RestartStage failed: $($rec.message)"
                $script:ResumeDetail = $state.message
                Save-WddState $Paths $state
                Write-WddLog "Resume: $($state.message)" 'ERROR'
                Write-WddEvent 3006 "Deployment $($manifest.packageId): $($state.message) See $($Paths.Log)." 'Error'
                try { Register-WddMonitorTask $Paths $manifest } catch { Write-WddLog "Resume: the monitor task could not be registered either: $($_.Exception.Message)" 'ERROR' }
                return 'StageRestartFailed'
            }
        }
        Save-WddState $Paths $state
        try { Register-WddMonitorTask $Paths $manifest }
        catch {
            $script:ResumeDetail = "The monitor task $($script:MonitorTask.path)$($script:MonitorTask.name) could not be registered: $($_.Exception.Message)"
            Write-WddLog "Resume: $($script:ResumeDetail)" 'ERROR'
            return 'MonitorRegistrationFailed'
        }
        try { Start-WddTask $script:MonitorTask.path $script:MonitorTask.name } catch { Write-WddLog "Resume: could not start the monitor now; it runs within $(Get-WddMonitorInterval $manifest) minutes: $($_.Exception.Message)" 'WARN' }
        Write-WddEvent 3001 "Deployment $($manifest.packageId) resumed manually$(if ($RestartStage) { " (stage $RestartStage restarted)" })."
        return 'Resumed'
    } finally {
        Exit-WddMutex $mutex
    }
}

if ($script:ResumeMain) {
    $package = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $manifest = Read-WddManifest (Join-Path $package 'deployment-manifest.json')
    $paths = Get-WddPaths $manifest.dataRoot
    if ($script:ResumeArgs.Status) { (Format-WddStatus $manifest $paths (Read-WddDeploymentState $paths).State).Text; exit 0 }
    $script:ResumeDetail = ''
    $outcome = Invoke-WddResume $paths $script:ResumeArgs.RestartStage
    Write-Output "Resume: $outcome.$(if ($script:ResumeDetail) { " $($script:ResumeDetail)" }) Log: $($paths.Log)"
    if ($outcome -eq 'Resumed') { exit 0 }
    exit 1
}
