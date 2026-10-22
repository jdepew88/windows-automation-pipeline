#Requires -Version 5.1
<#
.SYNOPSIS
    Writes the final deployment report and cleans up the deployment monitor.

.DESCRIPTION
    Called by DeploymentOrchestrator.ps1 when every enabled stage has a final result, or when the
    deployment deadline has passed. Run by hand (elevated) it writes the report for the current
    state without ending the deployment (-Preview), or ends it now (-Finish).

    Writes <dataRoot>\reports\deployment-report.json and deployment-report.txt, the marker
    <dataRoot>\state\deployment.done (with the overall status; a marker is never proof of success
    on its own), an Application event, and a "Deployment report" shortcut on the public desktop.
    It removes only the monitor task. Logs, state and the engines' results are kept.
#>
[CmdletBinding()]
param(
    [switch] $Preview,
    [switch] $Finish
)

$script:CompleteMain = $MyInvocation.InvocationName -ne '.'
$script:CompleteArgs = @{ Preview = [bool] $Preview; Finish = [bool] $Finish }
. (Join-Path $PSScriptRoot '..\common\DeploymentCommon.ps1')
# Phase 4.3: present only when the ongoing update policy is applied after the initial updates.
$script:PolicyScript = Join-Path $PSScriptRoot 'Set-UpdatePolicy.ps1'
if (Test-Path -LiteralPath $script:PolicyScript) { . $script:PolicyScript }

function Get-WddSystemInfo {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    [ordered]@{
        computerName   = $env:COMPUTERNAME
        windows        = [string] $os.Caption
        edition        = $(if ($cv) { [string] $cv.EditionID } else { '' })
        displayVersion = $(if ($cv -and $cv.PSObject.Properties['DisplayVersion']) { [string] $cv.DisplayVersion } else { '' })
        build          = $(if ($cv) { '{0}.{1}' -f $cv.CurrentBuildNumber, $cv.UBR } else { [string] $os.BuildNumber })
        installDateUtc = $os.InstallDate.ToUniversalTime().ToString('o')
        manufacturer   = [string] $cs.Manufacturer
        model          = [string] $cs.Model
    }
}

function New-WddReport {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $State, $Snapshot, [string] $Overall, [string] $Reason)
    $system = try { Get-WddSystemInfo } catch { [ordered]@{ computerName = $env:COMPUTERNAME; error = $_.Exception.Message } }
    $wu = @($Snapshot.stages | Where-Object { $_.id -eq 'windowsUpdate' }) | Select-Object -First 1
    $apps = @($Snapshot.stages | Where-Object { $_.id -eq 'applications' }) | Select-Object -First 1
    $remaining = @(); $errors = @(); $incomplete = @()
    $wuReport = $null
    if ($wu) {
        $r = $wu.result
        $failed = @(if ($r) { @($r.failed) | Where-Object { $_ } | ForEach-Object { [ordered]@{ kbs = @($_.kbs); title = $_.title; attempts = $_.attempts; lastResult = $_.lastResult; lastHResult = $_.lastHResult } } })
        $wuReport = [ordered]@{ state = $wu.state; status = $wu.status; reason = $wu.detail; reboots = $wu.reboots
                                installed = $(if ($r) { @($r.installed).Count } else { $null }); skipped = $(if ($r) { @($r.skipped).Count } else { $null }); failedUpdates = $failed }
        foreach ($f in $failed) { $remaining += "Windows Update: $((@($f.kbs) -join ', ')) $($f.title) failed after $($f.attempts) attempt(s)." }
        if ($wu.state -ne 'Final') { $incomplete += "Windows Update ($($wu.state))" }
        elseif ($wu.status -eq 'Offline') { $incomplete += 'Windows Update (Offline: no network before its runtime limit)' }
        elseif ($wu.status -eq 'Failed') { $errors += "Windows Update failed: $($wu.detail)" }
    }
    $appsReport = $null
    if ($apps) {
        $r = $apps.result
        # Phase 5: lifecycle, failure class and attempt totals come from result schema 2 (absent in schema 1).
        $pk = @(if ($r) { @($r.packages) | Where-Object { $_ } | ForEach-Object {
            $x = [ordered]@{ name = $_.name; packageIdentifier = $_.packageIdentifier; source = $_.source; status = $_.status; attempts = $_.attempts; exitCode = $_.exitCode; message = $_.message }
            foreach ($k in 'operationId', 'lifecycle', 'failureClass', 'retryable', 'detection', 'totalAttempts', 'manualRetries') { if ($_.ContainsKey($k)) { $x[$k] = $_[$k] } }
            $x
        } })
        $add = @(if ($r) { @($r.additionalSoftware) | Where-Object { $_ } })
        $appsReport = [ordered]@{ state = $apps.state; status = $apps.status; reason = $apps.detail; reboots = $apps.reboots
                                  counts = $(if ($r) { $r.counts } else { $null }); packages = $pk; additionalSoftware = $add
                                  requiresInteraction = @($pk | Where-Object { $_.status -eq 'RequiresInteraction' } | ForEach-Object { $_.name })
                                  bootstrap = $(if ($r) { $r.bootstrap } else { $null }) }
        foreach ($p in $pk) { if ($p.status -in 'RequiresInteraction', 'RequiresRestart', 'Failed', 'Unavailable', 'Pending') { $remaining += "Application $($p.name) ($($p.source):$($p.packageIdentifier)): $($p.status). $($p.message)" } }
        foreach ($a in $add) { if ($a.status -ne 'Succeeded') { $remaining += "Additional Software $($a.name): $($a.status). $($a.message)" } }
        if ($apps.state -ne 'Final') { $incomplete += "Applications ($($apps.state))" }
        elseif ($apps.status -eq 'Offline') { $incomplete += 'Applications (Offline)' }
        elseif ($apps.status -eq 'Failed') { $errors += "Application setup failed: $($apps.detail)" }
    }
    foreach ($n in @($Snapshot.needsAttention)) { $errors += $n }
    # Phase 4.3: written by Add-WifiProfile.ps1 when the answer file adds a Wi-Fi profile (never contains the key).
    $wifi = Read-WddJson (Join-Path $Paths.Root 'Network\wifi-result.json')
    if ($wifi -and $wifi.status -notin 'Added', 'ConnectRequested', 'ConnectFailed') { $remaining += "Wi-Fi: $($wifi.status). $($wifi.message)" }
    $policy = $(if ($State.ContainsKey('updatePolicy')) { $State.updatePolicy } else { $null })
    if ($Manifest.ContainsKey('updatePolicy') -and $Manifest.updatePolicy) {
        if (-not $policy) { $remaining += 'Ongoing Windows Update policy: not applied. Set it under Settings > Windows Update or re-run the deployment.' }
        elseif ($policy.status -notin 'Applied', 'AlreadyApplied') { $remaining += "Ongoing Windows Update policy: $($policy.status). $($policy.message)" }
    }
    $remaining += 'Manufacturer drivers: not part of this deployment (driver stage not implemented). Install chipset, graphics and OEM drivers manually if Windows Update did not provide them.'
    # Phase 5: what is still open and how to recover it, kept after the deployment ends.
    $tool = Join-Path $Paths.Package 'scripts\recovery\DeploymentRecovery.ps1'
    $hasTool = Test-Path -LiteralPath $tool
    $outstanding = @()
    if ($apps -and $apps.result -and $apps.result.ContainsKey('outstanding')) {
        foreach ($x in @($apps.result.outstanding) | Where-Object { $_ }) {
            $how = switch ([string] $x.lifecycle) {
                'FailedRetryable' { 'retry (automatic retries used up)' } 'BlockedByDependency' { 'retry (with its dependency)' }
                'WaitingForNetwork' { 'resume when the network is back' } 'Pending' { 'resume' } 'FailedPermanent' { 'correct the cause, then retry with -IncludePermanent' }
                'ManualActionRequired' { 'install or finish it by hand' } 'WaitingForReboot' { 'restart the computer' } default { 'check' }
            }
            $outstanding += [ordered]@{ operationId = $x.operationId; name = $x.name; lifecycle = $x.lifecycle; failureClass = $x.failureClass; retryable = $x.retryable; action = $how; message = $x.message }
        }
    } elseif ($apps -and $apps.state -ne 'Final') {
        $outstanding += [ordered]@{ operationId = 'stage:applications'; name = 'Applications'; lifecycle = 'Pending'; failureClass = ''; retryable = $true; action = 'resume'; message = "The application stage is $($apps.state)." }
    }
    if ($wu -and $wu.state -eq 'Final' -and $wu.status -in 'CompletedWithFailures', 'Failed', 'Offline') {
        $outstanding += [ordered]@{ operationId = 'stage:windowsUpdate'; name = 'Windows Update'; lifecycle = 'FailedRetryable'; failureClass = $(if ($wu.status -eq 'Offline') { 'Network' } else { 'Transient' }); retryable = $true; action = 'retry the update stage (installed updates are never offered again)'; message = [string] $wu.detail }
    }
    $recoveryCommands = [ordered]@{
        status      = "powershell.exe -ExecutionPolicy Bypass -File `"$tool`" -Action Status"
        retryFailed = "powershell.exe -ExecutionPolicy Bypass -File `"$tool`" -Action RetryFailed"
        retryOne    = "powershell.exe -ExecutionPolicy Bypass -File `"$tool`" -Action Retry -Operation <operationId>"
        resume      = "powershell.exe -ExecutionPolicy Bypass -File `"$tool`" -Action Resume"
        diagnostics = "powershell.exe -ExecutionPolicy Bypass -File `"$tool`" -Action ExportDiagnostics"
    }
    # Phase 6: the application stage's restoration result (inventory migration and settings restore).
    $restorationFile = Join-Path $Paths.Root 'Applications\restoration.json'
    $restoration = Read-WddJson $restorationFile
    $restorationReport = $null
    if ($restoration -and $restoration['format'] -eq 'windows-deployment-builder/restoration-result') {
        $restorationReport = [ordered]@{ file = $restorationFile; inventoryId = [string] $restoration['inventoryId']; backupId = [string] $restoration['backupId']
                                         backup = $restoration['backup']; counts = $restoration['counts']
                                         settings = @(@($restoration['settings']) | Where-Object { $_ } | ForEach-Object { [ordered]@{ adapterId = $_['adapterId']; name = $_['name']; outcome = $_['outcome']; detail = $_['detail'] } }) }
        if (@($restoration['settings']).Count) { $recoveryCommands.restoreSettings = "powershell.exe -ExecutionPolicy Bypass -File `"$tool`" -Action RestoreSettings -BackupPath <backup folder>" }
    }
    $outcome = Get-WddDeploymentOutcome @{ status = 'Completed'; overall = $Overall; message = $Reason } $null
    [ordered]@{
        format             = 'windows-deployment-builder/deployment-report'
        reportVersion      = 2
        overall            = $Overall
        outcome            = $outcome.outcome
        outcomeCode        = $outcome.exitCode
        reason             = $Reason
        generatedUtc       = (Get-WddNow).ToString('o')
        packageId          = $Manifest.packageId
        packageVersion     = $Manifest.packageVersion
        orchestratorVersion = $script:DeployVersion
        startedUtc         = $State.initializedUtc
        deadlineUtc        = $State.deadlineUtc
        system             = $system
        windowsUpdate      = $wuReport
        applications       = $appsReport
        updatePolicy       = $policy
        wifi               = $wifi
        drivers            = [ordered]@{ state = 'NotImplemented'; note = 'No driver was installed or changed by this deployment.' }
        restarts           = [ordered]@{ windowsUpdate = $(if ($wu) { $wu.reboots } else { 0 }); applications = $(if ($apps) { $apps.reboots } else { 0 }) }
        incompleteStages   = $incomplete
        errors             = $errors
        remainingTasks     = $remaining
        outstanding        = $outstanding
        recoveries         = @(if ($State.ContainsKey('recoveries')) { @($State.recoveries) })
        logs               = [ordered]@{ deployment = $Paths.Log; windowsUpdate = (Join-Path $Paths.Root 'Updates\logs\engine.log'); applications = (Join-Path $Paths.Root 'Applications\logs\engine.log'); attempts = (Join-Path $Paths.Root 'Applications\logs\attempts.jsonl') }
        recovery           = "$(if ($hasTool) { "Recovery tool (as administrator; status, retry, resume, diagnostics): $($recoveryCommands.status). " })Resume only: powershell.exe -ExecutionPolicy Bypass -File `"$(Join-Path $Paths.Package 'scripts\orchestrator\Resume-Deployment.ps1')`""
        recoveryCommands   = $(if ($hasTool) { $recoveryCommands } else { $null })
        restoration        = $restorationReport
    }
}

function Format-WddReport {
    param($Report)
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add('Windows Deployment Builder - deployment report')
    $l.Add('==============================================')
    $l.Add("Overall result : $($Report.overall)")
    if ($Report.Contains('outcome')) { $l.Add("Outcome        : $($Report.outcome) (exit code $($Report.outcomeCode))") }
    if ($Report.reason) { $l.Add("               : $($Report.reason)") }
    $l.Add("Generated (UTC): $($Report.generatedUtc)")
    $l.Add("Package        : $($Report.packageId) (package $($Report.packageVersion), orchestrator $($Report.orchestratorVersion))")
    $l.Add('')
    $l.Add('Computer')
    foreach ($k in $Report.system.Keys) { $l.Add(('  {0,-15} {1}' -f $k, $Report.system[$k])) }
    $l.Add('')
    $l.Add('Windows Update')
    if ($Report.windowsUpdate) {
        $w = $Report.windowsUpdate
        $l.Add("  Result: $($w.status) ($($w.state)). $($w.reason)")
        $l.Add("  Installed: $($w.installed)  Skipped by policy: $($w.skipped)  Restarts: $($w.reboots)")
        foreach ($f in @($w.failedUpdates)) { $l.Add("  FAILED  $((@($f.kbs) -join ', ')) $($f.title) ($($f.attempts) attempts, $($f.lastHResult))") }
    } else { $l.Add('  Not part of this deployment.') }
    $l.Add('')
    $l.Add('Applications (WinGet)')
    if ($Report.applications) {
        $a = $Report.applications
        $l.Add("  Result: $($a.status) ($($a.state)). $($a.reason)")
        $l.Add("  Restarts: $($a.reboots)")
        foreach ($p in @($a.packages)) {
            $tries = $(if ($p.Contains('totalAttempts') -and [int] $p.totalAttempts -gt 1) { " [$($p.totalAttempts) attempts$(if ([int] $p.manualRetries) { ", $($p.manualRetries) manual retr$(if ([int] $p.manualRetries -eq 1) { 'y' } else { 'ies' })" })]" } else { '' })
            $l.Add(('  {0,-20} {1} ({2}:{3}){4} {5}' -f $p.status, $p.name, $p.source, $p.packageIdentifier, $tries, $p.message))
        }
        foreach ($s in @($a.additionalSoftware)) { $l.Add(('  {0,-20} {1} (Additional Software) {2}' -f $s.status, $s.name, $s.message)) }
    } else { $l.Add('  Not part of this deployment.') }
    $l.Add('')
    if ($Report.Contains('updatePolicy') -and $Report.updatePolicy) {
        $l.Add('Ongoing Windows Update policy (after the initial updates)')
        $l.Add("  $($Report.updatePolicy.status). $($Report.updatePolicy.message)")
        $l.Add('')
    }
    if ($Report.Contains('wifi') -and $Report.wifi) {
        $l.Add('Wi-Fi profile')
        $l.Add("  $($Report.wifi.status) ($($Report.wifi.profileName)). $($Report.wifi.message)")
        $l.Add('')
    }
    $l.Add('Manufacturer drivers')
    $l.Add('  Not implemented in this version; nothing was installed or changed.')
    $l.Add('')
    $l.Add('Incomplete stages')
    if (@($Report.incompleteStages).Count) { foreach ($x in $Report.incompleteStages) { $l.Add("  - $x") } } else { $l.Add('  None.') }
    $l.Add('')
    $l.Add('Errors')
    if (@($Report.errors).Count) { foreach ($x in $Report.errors) { $l.Add("  - $x") } } else { $l.Add('  None.') }
    $l.Add('')
    $l.Add('Remaining tasks')
    foreach ($x in $Report.remainingTasks) { $l.Add("  - $x") }
    $l.Add('')
    if ($Report.Contains('outstanding')) {
        $l.Add('Outstanding work (kept for recovery)')
        if (@($Report.outstanding).Count) {
            foreach ($x in $Report.outstanding) { $l.Add(('  {0,-22} {1} [{2}]: {3}' -f $x.lifecycle, $x.name, $x.operationId, $x.action)) }
        } else { $l.Add('  None.') }
        $l.Add('')
    }
    if ($Report.Contains('restoration') -and $Report.restoration) {
        $x = $Report.restoration
        $l.Add('Application restoration')
        if ($x.counts) { $l.Add('  ' + (($x.counts.Keys | Sort-Object | ForEach-Object { "$_ $($x.counts[$_])" }) -join ', ')) }
        if ($x.backupId) { $l.Add("  Settings backup $($x.backupId): $($x.backup.status). $($x.backup.message)") }
        foreach ($s in @($x.settings)) { $l.Add(('  {0,-32} {1}: {2}' -f $s.name, $s.outcome, $s.detail)) }
        $l.Add("  Details: $($x.file)")
        $l.Add('')
    }
    $l.Add('Logs')
    foreach ($k in $Report.logs.Keys) { $l.Add(('  {0,-14} {1}' -f $k, $Report.logs[$k])) }
    $l.Add('')
    $l.Add("Recovery: $($Report.recovery)")
    if ($Report.Contains('recoveryCommands') -and $Report.recoveryCommands) {
        foreach ($k in $Report.recoveryCommands.Keys) { $l.Add(('  {0,-12} {1}' -f $k, $Report.recoveryCommands[$k])) }
    }
    return ($l -join "`r`n") + "`r`n"
}

function Write-WddReport {
    param($Report, [hashtable] $Paths)
    Write-WddJson $Paths.ReportJson $Report
    [System.IO.File]::WriteAllText($Paths.ReportText, (Format-WddReport $Report), (New-Object System.Text.UTF8Encoding($true)))
}

<#
    Ends the deployment: report, marker, event, shortcuts, monitor task removal. State is kept.
#>
function Complete-WddDeployment {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $State, $Snapshot, [switch] $DeadlineReached)
    if (Get-Command Step-WddUpdatePolicy -ErrorAction SilentlyContinue) { $null = Step-WddUpdatePolicy $Manifest $Paths $State $Snapshot -Force }
    $overall = Get-WddOverall $Snapshot.stages -DeadlineReached:$DeadlineReached
    # A policy that could not be applied is a follow-up, never a silent success.
    if ($overall -eq 'Succeeded' -and $Manifest.ContainsKey('updatePolicy') -and $Manifest.updatePolicy -and -not ($State.ContainsKey('updatePolicy') -and $State.updatePolicy -and $State.updatePolicy.status -in 'Applied', 'AlreadyApplied')) { $overall = 'CompletedWithFollowUp' }
    $reason = if ($DeadlineReached -and -not $Snapshot.allFinal) { "The deployment deadline ($($State.deadlineUtc)) passed before every stage finished." } elseif (@($Snapshot.stages).Count -eq 0) { 'No post-installation stage was enabled.' } else { 'Every enabled stage has a final result.' }
    $report = New-WddReport $Manifest $Paths $State $Snapshot $overall $reason
    Write-WddReport $report $Paths
    $now = (Get-WddNow).ToString('o')
    Write-WddJson $Paths.Marker ([ordered]@{ status = $overall; finishedUtc = $now; report = $Paths.ReportJson })
    $State.status = 'Completed'; $State.overall = $overall; $State.completedUtc = $now; $State.message = $reason
    Save-WddState $Paths $State
    $Snapshot.deploymentState = 'Completed'
    $Snapshot.overall = $overall
    Set-WddSnapshotOutcome $Snapshot $State
    Write-WddJson $Paths.Status $Snapshot
    Write-WddLog "FINISHED: $overall. $reason Report: $($Paths.ReportText)" $(if ($overall -eq 'Succeeded') { 'INFO' } else { 'WARN' })
    $eventId = switch ($overall) { 'Succeeded' { 3100 } 'CompletedWithFollowUp' { 3101 } 'CompletedWithFailures' { 3102 } 'Failed' { 3103 } default { 3104 } }
    Write-WddEvent $eventId "Deployment $($Manifest.packageId) finished: $overall. $reason Report: $($Paths.ReportText)" $(if ($overall -eq 'Succeeded') { 'Information' } elseif ($overall -eq 'Failed') { 'Error' } else { 'Warning' })
    try {
        Remove-WddShortcut 'Deployment progress'
        New-WddShortcut 'Deployment report' (Join-Path $env:SystemRoot 'System32\notepad.exe') "`"$($Paths.ReportText)`"" 'Windows Deployment Builder: deployment report'
    } catch { Write-WddLog "Could not update the desktop shortcuts: $($_.Exception.Message)" 'WARN' }
    try { Unregister-WddTask '\WindowsDeploymentBuilder\' 'Deployment' } catch { Write-WddLog "Could not remove the monitor task: $($_.Exception.Message)" 'WARN' }
    return $overall
}

if ($script:CompleteMain) {
    $package = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $manifest = Read-WddManifest (Join-Path $package 'deployment-manifest.json')
    $paths = Get-WddPaths $manifest.dataRoot
    Initialize-WddLogging $paths
    $state = (Read-WddDeploymentState $paths).State
    if (-not $state) { Write-Output 'No deployment state found.'; exit 1 }
    $snapshot = Get-WddSnapshot $manifest $paths $state
    if ($script:CompleteArgs.Finish) {
        $overall = Complete-WddDeployment $manifest $paths $state $snapshot -DeadlineReached
        Write-Output "Deployment ended: $overall. Report: $($paths.ReportText)"
    } else {
        $report = New-WddReport $manifest $paths $state $snapshot $snapshot.overall 'Preview of the current state (the deployment continues).'
        Format-WddReport $report
    }
    exit 0
}
