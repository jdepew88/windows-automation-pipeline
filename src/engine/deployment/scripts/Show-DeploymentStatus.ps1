#Requires -Version 5.1
<#
.SYNOPSIS
    Shows the deployment progress in the console (read-only; no elevation needed).

.DESCRIPTION
    Reads the deployment state and what each engine wrote, live (it does not wait for the monitor):
    current stage, finished stages, the application being installed, applications remaining,
    pending restart, warnings, failures and whether a person needs to act.

    -Watch refreshes every 15 seconds until the deployment has finished. The window that opens
    after the first sign-in runs this with -Watch; it can be closed at any time without affecting
    the deployment.
#>
[CmdletBinding()]
param(
    [switch] $Watch,
    [int] $IntervalSeconds = 15
)

$script:ShowMain = $MyInvocation.InvocationName -ne '.'
$script:ShowArgs = @{ Watch = [bool] $Watch; Interval = $IntervalSeconds }
. (Join-Path $PSScriptRoot '..\common\DeploymentCommon.ps1')

function Format-WddStatus {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $State)
    $s = Get-WddSnapshot $Manifest $Paths $State
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add('Windows Deployment Builder - deployment progress')
    $l.Add('================================================')
    $overall = if ($State -and $State.status -eq 'Completed') { "Finished: $($State.overall)" } elseif ($State) { $State.status } else { 'Not started' }
    $l.Add("Deployment     : $overall")
    $l.Add("Outcome        : $($s.outcome) (code $($s.outcomeCode)) $($s.outcomeDetail)")
    if ($State -and $State.message) { $l.Add("                 $($State.message)") }
    if ($State) { $l.Add("Started (UTC)  : $($State.initializedUtc)   deadline: $($State.deadlineUtc)") }
    $l.Add("Current stage  : $(if ($s.currentStage) { $s.currentStage } else { '-' })")
    $l.Add("Restart pending: $(if ($s.restartPending) { 'yes (a restart has been scheduled)' } else { 'no' })")
    $l.Add('')
    $l.Add(('{0,-22} {1,-12} {2,-22} {3}' -f 'Stage', 'State', 'Status', 'Detail'))
    foreach ($st in @($s.stages)) {
        $l.Add(('{0,-22} {1,-12} {2,-22} {3}' -f $st.name, $st.state, $st.status, $st.detail))
        if ($st.id -eq 'applications') {
            if ($st.current) { $l.Add("  installing now: $($st.current)") }
            if ($null -ne $st.total -and [int] $st.total -gt 0) { $l.Add("  applications: $($st.done) of $($st.total) done, $([int] $st.total - [int] $st.done) remaining") }
        }
        if ($st.reboots) { $l.Add("  restarts so far: $($st.reboots)") }
        if ($st.idle) { $l.Add("  note: $($st.idle)") }
        if ($st.outstanding) { $l.Add("  outstanding operations: $($st.outstanding) (retry them with the deployment recovery tool)") }
    }
    if ($s.drivers.state -eq 'NotPartOfDeployment') { $l.Add(('{0,-22} {1,-12} {2,-22} {3}' -f 'Hardware & drivers', 'Off', '', 'Not part of this deployment')) }
    elseif ($s.drivers.state -eq 'NotImplemented') { $l.Add(('{0,-22} {1,-12} {2,-22} {3}' -f 'Manufacturer drivers', 'NotImplemented', '', 'Not part of this version')) }
    if ($s.Contains('networkDriverMissing') -and $s.networkDriverMissing) { $l.Add("NETWORK: $($s.networkDriverMissing)") }
    $l.Add('')
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

if ($script:ShowMain) {
    $package = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $manifest = Read-WddManifest (Join-Path $package 'deployment-manifest.json')
    $paths = Get-WddPaths $manifest.dataRoot
    do {
        $state = (Read-WddDeploymentState $paths).State
        $out = Format-WddStatus $manifest $paths $state
        if ($script:ShowArgs.Watch) { Clear-Host }
        Write-Output $out.Text
        if (-not $script:ShowArgs.Watch -or $out.Done) { break }
        Write-Output ''
        Write-Output "Refreshing every $($script:ShowArgs.Interval) s. You can close this window; the deployment continues."
        Start-Sleep -Seconds $script:ShowArgs.Interval
    } while ($true)
    if ($script:ShowArgs.Watch) { Write-Output ''; Read-Host 'Press Enter to close' | Out-Null }
    exit 0
}
