#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Deployment Recovery: status, retry of failed operations, resume and diagnostics for a
    deployment on this computer (Phase 5).

.DESCRIPTION
    A small console tool for the technician. It never installs anything itself: it re-verifies the
    staged package, reopens operations in the engines' own state (ApplicationEngine.ps1 -Mode Retry
    logic, under the engine's mutex), registers the engines' tasks again and lets the deployment
    monitor follow them, exactly as during the original deployment. Every security check of the
    first run applies again on the retried attempt.

      -Action Menu               (default) numbered menu; asks for administrator rights with -Elevate
      -Action Status [-Json]     the deployment outcome, stages and every operation (read-only)
      -Action PendingActions     what a person still has to do (manual installs, restarts, checks)
      -Action RetryFailed        reopens every retryable failed or unfinished application (and a
                                 failed Windows Update stage), keeping successful ones
      -Action Retry -Operation app:winget:git.git[,...]
                                 reopens the named operations (ids from Status); a dependency that
                                 did not install is reopened with what needs it
           [-IncludePermanent]   also permanent failures (hash, signature, policy, not found,
                                 cancelled): only after the cause has been corrected
      -Action Resume             continues interrupted provisioning: unfinished operations, a
                                 missing task or monitor, a damaged deployment state (rebuilt from
                                 the manifest and the engines' own files)
      -Action RestoreSettings -BackupPath <folder or .zip>
                                 Phase 6: stages the application settings backup this deployment
                                 expects (identified by the SHA-256 pinned in its configuration;
                                 any other or modified backup is refused) and restores the settings
                                 that are still outstanding; restored settings are never repeated
      -Action AddDrivers -DriverPath <folder>
                                 Phase 8: validates INF driver packages from a folder (for example
                                 a network driver on a USB stick when the computer has no network;
                                 Microsoft-signed only), stages them for the driver stage and runs
                                 it again for the devices that are still unresolved
      -Action ExportDiagnostics [-OutputPath <zip>]
                                 logs, states, results and the report as one ZIP, with passwords
                                 and Wi-Fi keys removed; answer files and Wi-Fi profiles are never
                                 included

    Only operations of this deployment's verified configuration can be retried. Deselected apps,
    manual catalog entries, unresolved identifiers and anything already installed are refused. No
    input is ever executed: operation ids must match a strict pattern and the permitted set.

    Exit codes: Status returns the outcome code (0 Succeeded, 10 CompletedWithWarnings,
    20 CompletedWithFailures, 25 Incomplete, 30/31/32 paused for network/reboot/user, 40 InProgress,
    50 FailedToInitialize, 60 Failed). Actions return 0 (done), 1 (refused or nothing to do),
    2 (busy), 3 (package integrity), 4 (administrator rights needed).
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Status', 'PendingActions', 'RetryFailed', 'Retry', 'Resume', 'RestoreSettings', 'AddDrivers', 'ExportDiagnostics')]
    [string] $Action = 'Menu',
    [string] $BackupPath = '',
    [string] $DriverPath = '',
    [string[]] $Operation = @(),
    [switch] $IncludePermanent,
    [switch] $Json,
    [string] $OutputPath = '',
    [switch] $Elevate
)

$script:RecoveryMain = $MyInvocation.InvocationName -ne '.'
# Captured first: the scripts dot-sourced below bind their own parameters in this scope.
$script:RecoveryArgs = @{ Action = $Action; BackupPath = $BackupPath; DriverPath = $DriverPath; Operation = @($Operation); IncludePermanent = [bool] $IncludePermanent; Json = [bool] $Json; OutputPath = $OutputPath; Elevate = [bool] $Elevate }
. (Join-Path $PSScriptRoot '..\common\DeploymentCommon.ps1')
. (Join-Path $PSScriptRoot '..\bootstrap\Initialize-Deployment.ps1')
. (Join-Path $PSScriptRoot '..\orchestrator\Show-DeploymentStatus.ps1')
# The application engine's own functions (Retry mode, lifecycle); present when the stage is part of the package.
$script:AppEngineScript = Join-Path $PSScriptRoot '..\applications\ApplicationEngine.ps1'
if (Test-Path -LiteralPath $script:AppEngineScript) { . $script:AppEngineScript }
# Phase 8: the driver engine's own functions (Retry, technician packages), when the stage is part of the package.
$script:DriverEngineScript = Join-Path $PSScriptRoot '..\drivers\DriverEngine.ps1'
if (Test-Path -LiteralPath $script:DriverEngineScript) { . $script:DriverEngineScript -Mode Library }
Set-StrictMode -Version 2.0

$script:RecoveryExit = @{ Done = 0; Refused = 1; NothingToDo = 1; Busy = 2; IntegrityFailed = 3; NotElevated = 4; NoState = 1; UnknownStage = 1 }

# ------------------------------------------------------------------------------------------------
# Adapters (replaced by the scenario tests)
# ------------------------------------------------------------------------------------------------

<# The application engine configuration of the staged package (the verified copy). #>
function Get-WdrAppConfig {
    param([hashtable] $Paths)
    $p = Join-Path $Paths.Package 'scripts\applications\applications-config.json'
    if (-not (Test-Path -LiteralPath $p) -or -not (Get-Command Get-WdaConfig -ErrorAction SilentlyContinue)) { return $null }
    Get-WdaConfig $p
}

<# Registers and starts the application task again without archiving its state (Install-ApplicationEngine.ps1 -Resume). #>
function Invoke-WdrAppInstaller {
    param([hashtable] $Paths)
    $installer = Join-Path $Paths.Package 'scripts\applications\Install-ApplicationEngine.ps1'
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $out = & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer -Resume 2>&1
    foreach ($line in @($out)) { Write-WddLog "    | $line" }
    return $LASTEXITCODE
}

function Get-WdrDesktop { [Environment]::GetFolderPath('Desktop') }

<# Phase 8: the driver engine configuration of the staged package (the verified copy). #>
function Get-WdrDriverConfig {
    param([hashtable] $Paths)
    $p = Join-Path $Paths.Package 'scripts\drivers\drivers-config.json'
    if (-not (Test-Path -LiteralPath $p) -or -not (Get-Command Get-WdvConfig -ErrorAction SilentlyContinue)) { return $null }
    Get-WdvConfig $p
}

<# Registers and starts the driver task again without archiving its state (Install-DriverEngine.ps1 -Resume). #>
function Invoke-WdrDriverInstaller {
    param([hashtable] $Paths)
    $installer = Join-Path $Paths.Package 'scripts\drivers\Install-DriverEngine.ps1'
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $out = & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer -Resume 2>&1
    foreach ($line in @($out)) { Write-WddLog "    | $line" }
    return $LASTEXITCODE
}

# ------------------------------------------------------------------------------------------------
# Status
# ------------------------------------------------------------------------------------------------

<# Every application operation from the engine's live state (or its last result). #>
function Get-WdrOperations {
    param([hashtable] $Paths)
    $app = Join-Path $Paths.Root 'Applications'
    $s = $null
    foreach ($f in 'state.json', 'state.json.bak') { $s = Read-WddJson (Join-Path $app $f); if ($s -and $s.ContainsKey('packages')) { break } }
    $ops = @()
    foreach ($map in @(if ($s) { 'packages', 'additional', 'settings' })) {
        if (-not $s.ContainsKey($map) -or $s[$map] -isnot [hashtable]) { continue }
        foreach ($e in @($s[$map].Values)) {
            if ($e -isnot [hashtable]) { continue }
            $id = $(if ($e.ContainsKey('operationId') -and $e.operationId) { [string] $e.operationId } elseif ($map -eq 'packages') { "app:$($e['key'])" } elseif ($map -eq 'settings') { "settings:$($e['id'])" } else { "additional:$($e['id'])" })
            $life = $(if (Get-Command Get-WdaLifecycle -ErrorAction SilentlyContinue) { Get-WdaLifecycle $e } else { [string] $e.status })
            $ops += [ordered]@{ operationId = $id; name = [string] $e['name']; status = [string] $e['status']; lifecycle = $life; failureClass = [string] $e['failureClass']
                                retryable = [bool] $e['retryable']; attempts = [int] $e['attempts']; totalAttempts = [int] $e['totalAttempts']; detection = [string] $e['detection']; message = [string] $e['message'] }
        }
    }
    # Phase 8: driver operations (their status already is a lifecycle name).
    $d = $null
    foreach ($f in 'state.json', 'state.json.bak') { $d = Read-WddJson (Join-Path (Join-Path $Paths.Root 'Drivers') $f); if ($d -and $d['operations'] -is [hashtable]) { break } }
    if ($d -and $d['operations'] -is [hashtable]) {
        foreach ($e in @($d['operations'].Values)) {
            if ($e -isnot [hashtable]) { continue }
            $msg = $(if ($e['manualAction'] -is [hashtable] -and $e['manualAction']['text']) { [string] $e['manualAction']['text'] } else { [string] $e['reason'] })
            $ops += [ordered]@{ operationId = [string] $e['operationId']; name = [string] $e['name']; status = [string] $e['status']; lifecycle = [string] $e['status']; failureClass = [string] $e['failureClass']
                                retryable = ([string] $e['status'] -eq 'FailedRetryable'); attempts = [int] $e['attempts']; totalAttempts = [int] $e['totalAttempts']; detection = ''; message = $msg }
        }
    }
    return @($ops | Sort-Object { $_.operationId })
}

function Get-WdrStatus {
    param([hashtable] $Manifest, [hashtable] $Paths)
    $read = Read-WddDeploymentState $Paths
    $snap = $(if ($read.State) { Get-WddSnapshot $Manifest $Paths $read.State } else { $null })
    $out = $(if ($snap) { [ordered]@{ outcome = $snap.outcome; exitCode = $snap.outcomeCode; detail = $snap.outcomeDetail } } else { Get-WddDeploymentOutcome $null $null $read.Problem })
    [ordered]@{
        format          = 'windows-deployment-builder/recovery-status'
        version         = 1
        generatedUtc    = (Get-WddNow).ToString('o')
        packageId       = $Manifest.packageId
        outcome         = $out.outcome
        exitCode        = $out.exitCode
        detail          = $out.detail
        deploymentState = $(if ($read.State) { [string] $read.State.status } elseif ($read.Source -eq 'corrupt') { 'StateCorrupt' } else { 'NotInitialized' })
        stateSource     = $read.Source
        stages          = @(if ($snap) { @($snap.stages) | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; state = $_.state; status = $_.status; detail = $_.detail; idle = $_.idle; outstanding = $_.outstanding } } })
        operations      = @(Get-WdrOperations $Paths)
        report          = $(if (Test-Path -LiteralPath $Paths.ReportText) { $Paths.ReportText } else { '' })
    }
}

function Format-WdrStatus {
    param($Status)
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add('Windows Deployment Recovery - status')
    $l.Add('====================================')
    $l.Add("Outcome   : $($Status.outcome) (code $($Status.exitCode))")
    if ($Status.detail) { $l.Add("            $($Status.detail)") }
    $l.Add("State     : $($Status.deploymentState)$(if ($Status.stateSource -eq 'backup') { ' (recovered from its backup)' })")
    foreach ($s in @($Status.stages)) { $l.Add(('  {0,-24} {1,-10} {2} {3}' -f $s.name, $s.state, $s.status, $(if ($s.idle) { $s.idle } else { $s.detail }))) }
    $ops = @($Status.operations)
    if ($ops.Count) {
        $l.Add('')
        $l.Add(('{0,-22} {1,-36} {2,-10} {3}' -f 'Lifecycle', 'Operation', 'Attempts', 'Message'))
        foreach ($o in $ops) { $l.Add(('{0,-22} {1,-36} {2,-10} {3}' -f $o.lifecycle, $o.operationId, "$($o.totalAttempts)", $o.message)) }
        $retry = @($ops | Where-Object { $_.lifecycle -in 'FailedRetryable', 'BlockedByDependency', 'WaitingForNetwork' })
        $perm = @($ops | Where-Object { $_.lifecycle -eq 'FailedPermanent' })
        $l.Add('')
        $l.Add("Retryable: $($retry.Count) (RetryFailed)   Permanent: $($perm.Count) (fix the cause, then Retry -Operation <id> -IncludePermanent)")
    }
    if ($Status.report) { $l.Add("Report    : $($Status.report)") }
    return ($l -join "`r`n")
}

<# What a person still has to do; never includes secrets. #>
function Get-WdrPendingActions {
    param([hashtable] $Manifest, [hashtable] $Paths)
    $items = @()
    foreach ($o in @(Get-WdrOperations $Paths)) {
        switch ($o.lifecycle) {
            'ManualActionRequired' { $items += "$($o.name): $($o.message)" }
            'WaitingForReboot' { $items += "$($o.name): restart the computer to finish. $($o.message)" }
            'FailedPermanent' { $items += "$($o.name) [$($o.operationId)]: $($o.failureClass) failure; correct the cause, then retry with -IncludePermanent. $($o.message)" }
            'FailedRetryable' { $items += "$($o.name) [$($o.operationId)]: failed after automatic retries; run RetryFailed. $($o.message)" }
            'BlockedByDependency' { $items += "$($o.name) [$($o.operationId)]: blocked by a dependency; run RetryFailed. $($o.message)" }
            'WaitingForNetwork' { $items += "$($o.name): waiting for the network or its package source." }
        }
        if ($o.status -eq 'Succeeded' -and $o.detection -eq 'Unconfirmed') { $items += "$($o.name): WinGet reported success but could not confirm it; check that it is installed." }
    }
    $net = Get-WddNetworkDriverFlag $Paths
    if ($net) { $items += "Network: $net" }
    $report = Read-WddJson $Paths.ReportJson
    if ($report -and $report.ContainsKey('remainingTasks')) {
        foreach ($t in @($report.remainingTasks)) { if ($t -and $t -notmatch '^Application ' -and $t -notmatch '^Additional Software ' -and $t -notmatch '^Driver: ') { $items += [string] $t } }
    }
    return @($items | Select-Object -Unique)
}

# ------------------------------------------------------------------------------------------------
# Recovery actions
# ------------------------------------------------------------------------------------------------

<#
    Rebuilds a deployment state that is damaged beyond its backup: from the verified manifest and
    what the engines wrote themselves. A stage with a result, a status file or a task counts as
    launched (it is never launched twice); the damaged file is kept for diagnosis.
#>
function Repair-WddDeploymentState {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $Identity)
    $stamp = (Get-WddNow).ToString('yyyyMMddHHmmss')
    foreach ($f in $Paths.State, "$($Paths.State).bak") { if (Test-Path -LiteralPath $f) { Move-Item -LiteralPath $f -Destination "$f.corrupt-$stamp" -Force } }
    $state = New-WddState $Manifest 'Embedded' $Identity
    $state.status = 'InProgress'
    $state.message = 'Rebuilt by the recovery tool after the deployment state was damaged.'
    $state.stagedFiles = @(@($Manifest.files) | Where-Object { $_.embedded -and (Test-Path -LiteralPath (Join-Path $Paths.Package ($_.path -replace '/', '\'))) } | ForEach-Object { $_.path })
    foreach ($s in Get-WddEngineStages $Manifest) {
        $seen = (Test-Path -LiteralPath (Join-Path $Paths.Root $s.result)) -or (Test-Path -LiteralPath (Join-Path $Paths.Root $s.status)) -or (Get-WddTask $s.task.path $s.task.name)
        $state.stages[$s.id] = @{ launchResult = $(if ($seen) { 'Launched' } else { '' }); attempts = 0; launchedUtc = $(if ($seen) { (Get-WddNow).ToString('o') } else { $null }); exitCode = $null
                                  message = $(if ($seen) { 'Found running or finished while rebuilding the state.' } else { 'Not launched before the state was lost.' }); user = $(if ($s.context -eq 'user') { [string] $Identity.Name } else { 'SYSTEM' }) }
    }
    Save-WddState $Paths $state
    Write-WddLog "Deployment state rebuilt from the manifest (stages: $(($state.stages.Keys | ForEach-Object { "$_=$($state.stages[$_].launchResult)" }) -join ', '))." 'WARN'
    return $state
}

<#
    RetryFailed, Retry and Resume. Steps: administrator check, deployment mutex, state (rebuilt
    only for Resume), package integrity, the application stage (engine Retry logic, then its task
    again without archiving), the Windows Update stage (relaunched only when it ended with
    failures, or for Resume when its task is gone), then the deployment is reopened for the monitor.
#>
function Invoke-WdrRecovery {
    param([hashtable] $Manifest, [hashtable] $Paths, [ValidateSet('RetryFailed', 'Retry', 'Resume')] [string] $Mode, [string[]] $Operations = @(), [switch] $IncludePermanent)
    Initialize-WddLogging $Paths
    $identity = Get-WddIdentity
    if (-not $identity.IsAdmin) { return @{ Outcome = 'NotElevated'; Message = 'Run the recovery tool as administrator.'; Accepted = @(); Refused = @() } }
    $mutex = Enter-WddMutex 60
    if (-not $mutex) { return @{ Outcome = 'Busy'; Message = 'Another deployment process (monitor or setup) is running; try again in a minute.'; Accepted = @(); Refused = @() } }
    try {
        Write-WddLog "==== Recovery ($Mode) requested by $($identity.Name)$(if (@($Operations).Count) { ': ' + (@($Operations) -join ', ') }) ===="
        $read = Read-WddDeploymentState $Paths
        $state = $read.State
        if ($read.Source -eq 'corrupt') {
            if ($Mode -ne 'Resume') { return @{ Outcome = 'Refused'; Message = "The deployment state is damaged ($($read.Problem)). Run -Action Resume first; it rebuilds the state."; Accepted = @(); Refused = @() } }
            $state = Repair-WddDeploymentState $Manifest $Paths $identity
        }
        if (-not $state) { return @{ Outcome = 'NoState'; Message = 'No deployment has been started on this computer (run setup.cmd from the package).'; Accepted = @(); Refused = @() } }
        if ($state.packageId -ne $Manifest.packageId) { return @{ Outcome = 'Refused'; Message = "The deployment on this computer ($($state.packageId)) is not this package ($($Manifest.packageId))."; Accepted = @(); Refused = @() } }
        $check = Test-WddFiles $Paths.Package $Manifest 'Text' @($state.stagedFiles)
        if (-not $check.Ok) {
            Write-WddLog "Recovery refused: the staged package is modified or incomplete ($($check.Missing.Count) missing, $($check.Mismatched.Count) modified)." 'ERROR'
            return @{ Outcome = 'IntegrityFailed'; Message = 'The staged package was modified or is incomplete; run setup.cmd from the original package to stage it again. Nothing was retried.'; Accepted = @(); Refused = @(@($check.Missing) + @($check.Mismatched) | ForEach-Object { @{ operationId = "file:$_"; reason = 'missing or modified' } }) }
        }

        $accepted = @(); $refused = @(); $notes = @()
        $ops = @($Operations | Where-Object { $_ } | ForEach-Object { ([string] $_).Trim() })
        $wuRequested = $ops -contains 'stage:windowsUpdate'
        $driverOps = @($ops | Where-Object { $_ -like 'driver:*' -or $_ -eq 'stage:drivers' })
        $appOps = @($ops | Where-Object { $_ -ne 'stage:windowsUpdate' -and $_ -notlike 'driver:*' -and $_ -ne 'stage:drivers' })

        # Applications: the engine's own Retry logic decides what may run again.
        $appStage = Get-WddStage $Manifest 'applications'
        if ($appStage -and $appStage.enabled) {
            $cfg = Get-WdrAppConfig $Paths
            if (-not $cfg) { $notes += 'The application engine is not part of the staged package.' }
            elseif ($Mode -ne 'Retry' -or $appOps.Count) {
                if ($identity.IsSystem) {
                    $refused += @{ operationId = 'stage:applications'; reason = 'the application stage runs as the signed-in user (WinGet is not supported as SYSTEM); run the recovery tool as that user' }
                } else {
                    $r = switch ($Mode) {
                        'RetryFailed' { Invoke-WdaRetry $cfg -AllFailed -IncludePermanent:$IncludePermanent -RequestedBy $identity.Name }
                        'Retry' { Invoke-WdaRetry $cfg -Operations $appOps -IncludePermanent:$IncludePermanent -RequestedBy $identity.Name }
                        'Resume' { Invoke-WdaRetry $cfg -PendingOnly -RequestedBy $identity.Name }
                    }
                    $accepted += @($r.Accepted); $refused += @($r.Refused)
                    if ($r.Outcome -eq 'Busy') { return @{ Outcome = 'Busy'; Message = $r.Message; Accepted = @(); Refused = @() } }
                    $snapApp = Get-WddStageSnapshot $appStage $Paths $state
                    $needsTask = ($r.Outcome -eq 'Accepted') -or ($Mode -eq 'Resume' -and $snapApp.state -ne 'Final' -and -not (Get-WddTask $appStage.task.path $appStage.task.name))
                    if ($needsTask) {
                        $code = $null
                        try { $code = Invoke-WdrAppInstaller $Paths } catch { $notes += "Application task: $($_.Exception.Message)" }
                        $rec = $(if ($state.stages.ContainsKey('applications')) { $state.stages['applications'] } else { @{ attempts = 0 } })
                        $rec.launchResult = $(if (Get-WddTask $appStage.task.path $appStage.task.name) { 'Launched' } else { 'LaunchFailed' })
                        $rec.launchedUtc = (Get-WddNow).ToString('o'); $rec.exitCode = $code; $rec.user = $identity.Name
                        $rec.message = $(if ($rec.launchResult -eq 'Launched') { "Restarted by the recovery tool ($Mode)." } else { "The recovery tool could not register the application task (exit code $code)." })
                        $state.stages['applications'] = $rec
                        $notes += "Application stage: $($rec.message)"
                        if ($r.Outcome -ne 'Accepted') { $accepted += 'stage:applications' }
                    }
                }
            }
        }

        # Windows Update: its engine never offers an installed update again, so a relaunch is safe.
        $wuStage = Get-WddStage $Manifest 'windowsUpdate'
        if ($wuStage -and $wuStage.enabled -and ($Mode -ne 'Retry' -or $wuRequested)) {
            $wu = Get-WddStageSnapshot $wuStage $Paths $state
            $failed = $wu.state -eq 'Final' -and $wu.status -in 'CompletedWithFailures', 'Failed', 'Offline'
            $lost = $Mode -eq 'Resume' -and $wu.state -in 'Stalled', 'LaunchFailed', 'NotStarted'
            if (($Mode -ne 'Resume' -and $failed) -or $lost) {
                $state.stages['windowsUpdate'] = @{ launchResult = ''; attempts = 0; launchedUtc = $null; exitCode = $null; message = "Restarted by the recovery tool ($Mode)."; user = 'SYSTEM' }
                $rec = Invoke-WddLaunchStage $wuStage $Paths $state $identity ([int] $Manifest.failureHandling.orchestrator.launchAttempts)
                if ($rec.launchResult -eq 'Launched') { $accepted += 'stage:windowsUpdate' } else { $refused += @{ operationId = 'stage:windowsUpdate'; reason = [string] $rec.message } }
            } elseif ($wuRequested) {
                $refused += @{ operationId = 'stage:windowsUpdate'; reason = "the Windows Update stage is $($wu.state)$(if ($wu.status) { "/$($wu.status)" }); only a stage that ended with failures is retried" }
            }
        }

        # Phase 8: driver operations, through the driver engine's own Retry logic (security failures are never reopened).
        $drvStage = Get-WddStage $Manifest 'drivers'
        if ($drvStage -and $drvStage.enabled -and $drvStage['launcher'] -and ($Mode -ne 'Retry' -or $driverOps.Count)) {
            $dcfg = Get-WdrDriverConfig $Paths
            if (-not $dcfg) { $notes += 'The driver engine is not part of the staged package.' }
            else {
                $named = @($driverOps | Where-Object { $_ -ne 'stage:drivers' })
                $r = switch ($Mode) {
                    'RetryFailed' { Invoke-WdvRetry $dcfg -AllFailed -IncludePermanent:$IncludePermanent -RequestedBy $identity.Name }
                    'Retry' { $(if ($named.Count) { Invoke-WdvRetry $dcfg -Operations $named -IncludePermanent:$IncludePermanent -RequestedBy $identity.Name } else { @{ Outcome = 'NothingToDo'; Accepted = @(); Refused = @() } }) }
                    'Resume' { @{ Outcome = 'NothingToDo'; Accepted = @(); Refused = @() } }
                }
                if ($r.Outcome -eq 'Busy') { return @{ Outcome = 'Busy'; Message = $r.Message; Accepted = @(); Refused = @() } }
                $accepted += @($r.Accepted); $refused += @($r.Refused)
                $snapD = Get-WddStageSnapshot $drvStage $Paths $state
                $needsTask = ($r.Outcome -eq 'Accepted') -or ($driverOps -contains 'stage:drivers') -or ($Mode -eq 'Resume' -and $snapD.state -ne 'Final' -and -not (Get-WddTask $drvStage.task.path $drvStage.task.name))
                if ($needsTask) {
                    $code = $null
                    try { $code = Invoke-WdrDriverInstaller $Paths } catch { $notes += "Driver task: $($_.Exception.Message)" }
                    $rec = $(if ($state.stages.ContainsKey('drivers')) { $state.stages['drivers'] } else { @{ attempts = 0 } })
                    $rec.launchResult = $(if (Get-WddTask $drvStage.task.path $drvStage.task.name) { 'Launched' } else { 'LaunchFailed' })
                    $rec.launchedUtc = (Get-WddNow).ToString('o'); $rec.exitCode = $code; $rec.user = 'SYSTEM'
                    $rec.message = $(if ($rec.launchResult -eq 'Launched') { "Restarted by the recovery tool ($Mode)." } else { "The recovery tool could not register the driver task (exit code $code)." })
                    $state.stages['drivers'] = $rec
                    $notes += "Driver stage: $($rec.message)"
                    if ($rec.launchResult -eq 'Launched' -and $r.Outcome -ne 'Accepted') { $accepted += 'stage:drivers' }
                    elseif ($rec.launchResult -ne 'Launched') { $refused += @{ operationId = 'stage:drivers'; reason = $rec.message } }
                }
            }
        } elseif ($driverOps.Count) {
            foreach ($x in $driverOps) { $refused += @{ operationId = $x; reason = 'the driver stage is not part of this deployment' } }
        }

        $reopen = ($accepted.Count -gt 0) -or ($Mode -eq 'Resume')
        if ($reopen) {
            $stamp = (Get-WddNow).ToString('yyyyMMddHHmmss')
            if ($state.status -in 'Completed', 'IntegrityFailed' -and (Test-Path -LiteralPath $Paths.Marker)) {
                Move-Item -LiteralPath $Paths.Marker -Destination "$($Paths.Marker).$stamp.bak" -Force
            }
            # The previous report is kept (reports\history\); the monitor writes a new one at the end.
            foreach ($r in $Paths.ReportJson, $Paths.ReportText) {
                if (Test-Path -LiteralPath $r) {
                    $hist = Join-Path $Paths.Reports 'history'
                    if (-not (Test-Path -LiteralPath $hist)) { New-Item -ItemType Directory -Path $hist -Force | Out-Null }
                    Move-Item -LiteralPath $r -Destination (Join-Path $hist ("{0}-{1}{2}" -f [IO.Path]::GetFileNameWithoutExtension($r), $stamp, [IO.Path]::GetExtension($r))) -Force
                }
            }
            $state.status = 'InProgress'
            $state.message = "Recovery ($Mode) by $($identity.Name)."
            $state.deadlineUtc = (Get-WddNow).AddHours([double] $Manifest.failureHandling.orchestrator.deadlineHours).ToString('o')
        }
        $state.recoveries = @(@($state.recoveries) + @(@{ atUtc = (Get-WddNow).ToString('o'); by = $identity.Name; action = $Mode; accepted = @($accepted); refused = @($refused | ForEach-Object { $_.operationId }) }))
        Save-WddState $Paths $state
        if ($reopen) {
            Register-WddMonitorTask $Paths $Manifest
            try { Start-WddTask $script:MonitorTask.path $script:MonitorTask.name } catch { }
        }
        $outcome = $(if ($accepted.Count) { 'Done' } elseif ($Mode -eq 'Resume') { 'Done' } elseif ($refused.Count) { 'Refused' } else { 'NothingToDo' })
        $msg = "Reopened: $(if ($accepted.Count) { $accepted -join ', ' } else { 'none' }). Refused: $(if ($refused.Count) { ($refused | ForEach-Object { "$($_.operationId) ($($_.reason))" }) -join '; ' } else { 'none' }).$(if ($notes.Count) { ' ' + ($notes -join ' ') })"
        Write-WddLog "Recovery ($Mode): $msg" $(if ($outcome -eq 'Done') { 'INFO' } else { 'WARN' })
        Write-WddEvent 3005 "Deployment recovery ($Mode) by $($identity.Name): $msg" $(if ($outcome -eq 'Done') { 'Information' } else { 'Warning' })
        return @{ Outcome = $outcome; Message = $msg; Accepted = @($accepted); Refused = @($refused) }
    } finally {
        Exit-WddMutex $mutex
    }
}

<#
    Phase 8: technician-supplied INF driver packages (for example a network driver when the computer
    has no network). The staged package is verified first; the packages are validated by the driver
    engine of that package (Microsoft-signed INF only, every file hashed), copied into its protected
    folder, and the driver stage runs again for what is unresolved. Nothing is installed here.
#>
function Invoke-WdrAddDrivers {
    param([hashtable] $Manifest, [hashtable] $Paths, [string] $DriverPath)
    Initialize-WddLogging $Paths
    $identity = Get-WddIdentity
    if (-not $identity.IsAdmin) { return @{ Outcome = 'NotElevated'; Message = 'Run the recovery tool as administrator.'; Accepted = @(); Refused = @() } }
    $drvStage = Get-WddStage $Manifest 'drivers'
    if (-not ($drvStage -and $drvStage.enabled -and $drvStage['launcher'])) { return @{ Outcome = 'Refused'; Message = 'The driver stage is not part of this deployment; install the driver with Device Manager or pnputil.'; Accepted = @(); Refused = @() } }
    if (-not $DriverPath -or -not (Test-Path -LiteralPath $DriverPath -PathType Container)) { return @{ Outcome = 'Refused'; Message = "Driver folder not found: $DriverPath"; Accepted = @(); Refused = @() } }
    $read = Read-WddDeploymentState $Paths
    if (-not $read.State) { return @{ Outcome = 'NoState'; Message = 'No deployment has been started on this computer.'; Accepted = @(); Refused = @() } }
    $check = Test-WddFiles $Paths.Package $Manifest 'Text' @($read.State.stagedFiles)
    if (-not $check.Ok) { return @{ Outcome = 'IntegrityFailed'; Message = 'The staged package was modified or is incomplete; nothing was added.'; Accepted = @(); Refused = @() } }
    $dcfg = Get-WdrDriverConfig $Paths
    if (-not $dcfg) { return @{ Outcome = 'Refused'; Message = 'The driver engine is not part of the staged package.'; Accepted = @(); Refused = @() } }
    $a = Add-WdvTechnicianPackages $dcfg $DriverPath $identity.Name
    Write-WddLog "Recovery (AddDrivers) by $($identity.Name): $($a.Outcome). $($a.Message)"
    if ($a.Outcome -eq 'Busy') { return @{ Outcome = 'Busy'; Message = $a.Message; Accepted = @(); Refused = @() } }
    $refusedPk = @($a.Refused | ForEach-Object { @{ operationId = "package:$($_.inf)"; reason = $_.reason } })
    if ($a.Outcome -ne 'Accepted') { return @{ Outcome = 'Refused'; Message = "No package was usable. $(($a.Refused | ForEach-Object { "$($_.inf): $($_.reason)" }) -join '; ')"; Accepted = @(); Refused = $refusedPk } }
    $r = Invoke-WdrRecovery $Manifest $Paths 'Retry' -Operations @('stage:drivers')
    return @{ Outcome = $r.Outcome; Message = "$($a.Message) $($r.Message)"; Accepted = @(@($a.Added) + @($r.Accepted)); Refused = @($refusedPk + @($r.Refused)) }
}

<#
    Phase 6: makes the settings backup this deployment expects available and restores what is still
    outstanding. The backup is identified only by the manifest SHA-256 pinned in the verified
    application configuration; it is validated (every file, path and hash) by the restore library
    of the staged package, copied to <dataRoot>\Backup\incoming\<folder> and validated again by the
    engine before anything is restored. Then the outstanding settings operations are reopened
    through the engine's own Retry logic (RetryFailed rules: restored ones are never repeated).
#>
function Invoke-WdrRestoreSettings {
    param([hashtable] $Manifest, [hashtable] $Paths, [string] $BackupPath)
    Initialize-WddLogging $Paths
    $identity = Get-WddIdentity
    if (-not $identity.IsAdmin) { return @{ Outcome = 'NotElevated'; Message = 'Run the recovery tool as administrator.'; Accepted = @(); Refused = @() } }
    $cfg = Get-WdrAppConfig $Paths
    $plan = $(if ($cfg -and $cfg.ContainsKey('settingsRestore')) { $cfg['settingsRestore'] } else { $null })
    if ($plan -isnot [hashtable] -or -not @(Get-WdaSettingsPlan $cfg).Count) { return @{ Outcome = 'NothingToDo'; Message = 'This deployment does not restore application settings.'; Accepted = @(); Refused = @() } }
    if (-not $BackupPath) { return @{ Outcome = 'Refused'; Message = "Name the backup folder or ZIP with -BackupPath (expected: $($plan['folderName']))."; Accepted = @(); Refused = @() } }
    $lib = Join-Path $Paths.Package 'scripts\applications\WdbMigration.ps1'
    if (-not (Test-Path -LiteralPath $lib)) { return @{ Outcome = 'IntegrityFailed'; Message = 'The restore library is not part of the staged package.'; Accepted = @(); Refused = @() } }
    if (-not (Get-Command Open-WdbBackup -CommandType Function -ErrorAction SilentlyContinue)) { . $lib -Mode Library }
    $work = Join-Path $Paths.Root 'Backup\work'
    if (-not (Test-Path -LiteralPath $work)) { New-Item -ItemType Directory -Path $work -Force | Out-Null }
    try { $v = Open-WdbBackup $BackupPath $work ([string] $plan['manifestSha256']) } catch { return @{ Outcome = 'Refused'; Message = "The backup could not be opened: $($_.Exception.Message)"; Accepted = @(); Refused = @() } }
    if (-not $v.Ok) {
        Write-WddLog "RestoreSettings refused $BackupPath`: $(@($v.Problems) -join ' ')" 'WARN'
        return @{ Outcome = 'IntegrityFailed'; Message = "The backup is not the one this deployment expects, or it is damaged: $(@($v.Problems) -join ' ') Nothing was restored."; Accepted = @(); Refused = @() }
    }
    $incoming = Join-Path (Join-Path $Paths.Root 'Backup\incoming') ([string] $plan['folderName'])
    [void] (Copy-WdbBackup $v $incoming)
    Write-WddLog "RestoreSettings: backup $($plan['backupId']) validated from $BackupPath and placed in $incoming."
    $ops = @(Get-WdrOperations $Paths | Where-Object { $_.operationId -like 'settings:*' -and $_.status -notin 'Succeeded', 'AlreadyInstalled', 'SkippedByUser', 'Unavailable' } | ForEach-Object { $_.operationId })
    if (-not $ops.Count) { return @{ Outcome = 'NothingToDo'; Message = 'The backup was validated and staged; no settings are outstanding.'; Accepted = @(); Refused = @() } }
    return Invoke-WdrRecovery $Manifest $Paths 'Retry' -Operations $ops -IncludePermanent
}

# ------------------------------------------------------------------------------------------------
# Diagnostics
# ------------------------------------------------------------------------------------------------

<#
    Removes passwords and Wi-Fi keys from text (defence in depth: these files should contain none).
    The Wi-Fi element name is written as key[M]aterial so this script itself never contains the
    literal token the answer-file secret checks look for.
#>
function Protect-WdrText {
    param([string] $Text)
    $t = [regex]::Replace($Text, '(?i)("(?:password|passphrase|key[M]aterial|networkKey|secret|token|apiKey|adminPassword)"\s*:\s*)"(?:[^"\\]|\\.)*"', '$1"[redacted]"')
    $t = [regex]::Replace($t, '(?is)(<(key[M]aterial|Password)>).*?(</\2>)', '$1[redacted]$3')
    $t = [regex]::Replace($t, '(?i)\b(password|passwd|pwd|key[M]aterial|networkKey)(\s*[=:]\s*)[^\s,;"]+', '$1$2[redacted]')
    return $t
}

<#
    Only these files below the data root are collected; anything else (answer files, Wi-Fi
    profiles, Panther logs, user files) is never read.
#>
$script:DiagnosticFiles = @(
    'Deployment\status.json', 'Deployment\logs\*.log', 'Deployment\logs\*.log.1',
    'state\*.json', 'state\*.done', 'state\*.bak', 'state\*.corrupt*',
    'reports\deployment-report.json', 'reports\deployment-report.txt', 'reports\history\*.json',
    'Applications\state.json', 'Applications\state.json.bak', 'Applications\state.json.corrupt', 'Applications\status.json', 'Applications\result.json', 'Applications\follow-up.txt',
    'Applications\logs\*.log', 'Applications\logs\*.log.1', 'Applications\logs\attempts.jsonl', 'Applications\logs\packages\*.log', 'Applications\history\*.json',
    'Updates\state.json', 'Updates\status.json', 'Updates\result.json', 'Updates\policy-result.json', 'Updates\logs\*.log',
    'Network\wifi-result.json', 'Network\*.log',
    'Drivers\state.json', 'Drivers\state.json.bak', 'Drivers\status.json', 'Drivers\result.json', 'Drivers\inventory-*.json', 'Drivers\logs\*.log', 'Drivers\logs\attempts.jsonl', 'reports\drivers.json',
    'Package\scripts\drivers\drivers-config.json',
    'Package\deployment-manifest.json', 'Package\config\orchestration.json', 'Package\scripts\applications\applications-config.json', 'Package\scripts\windows-update\config.json'
)

function Export-WdrDiagnostics {
    param([hashtable] $Manifest, [hashtable] $Paths, [string] $OutputPath = '')
    $identity = Get-WddIdentity
    $stamp = (Get-WddNow).ToString('yyyyMMdd-HHmmss')
    if (-not $OutputPath) {
        $dir = $(if ($identity.IsAdmin) { $Paths.Reports } else { Get-WdrDesktop })
        $OutputPath = Join-Path $dir ("deployment-diagnostics-{0}-{1}.zip" -f $env:COMPUTERNAME, $stamp)
    }
    if ($OutputPath -notmatch '\.zip$') { throw 'The diagnostics file must end in .zip.' }
    $staging = Join-Path ([IO.Path]::GetTempPath()) ("wdr-diag-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    $index = @()
    $redacted = 0
    try {
        $root = [IO.Path]::GetFullPath($Paths.Root).TrimEnd('\') + '\'
        foreach ($pattern in $script:DiagnosticFiles) {
            $dir = Join-Path $Paths.Root (Split-Path -Parent $pattern)
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter (Split-Path -Leaf $pattern) -File -ErrorAction SilentlyContinue)) {
                $full = [IO.Path]::GetFullPath($f.FullName)
                if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
                if ($f.Extension -in '.xml', '.wim', '.exe', '.msi') { continue }
                $rel = $full.Substring($root.Length)
                $bytes = [IO.File]::ReadAllBytes($full)
                $max = 20MB
                if ($bytes.Length -gt $max) { $bytes = $bytes[($bytes.Length - $max)..($bytes.Length - 1)] }
                $text = [Text.Encoding]::UTF8.GetString($bytes)
                $safeText = Protect-WdrText $text
                if ($safeText -ne $text) { $redacted++ }
                $target = Join-Path $staging $rel
                New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
                [IO.File]::WriteAllText($target, $safeText, (New-Object Text.UTF8Encoding($false)))
                $index += [ordered]@{ path = $rel; size = $f.Length; truncated = ($f.Length -gt $max); redacted = ($safeText -ne $text) }
            }
        }
        $status = Get-WdrStatus $Manifest $Paths
        $info = [ordered]@{
            format = 'windows-deployment-builder/diagnostics'; version = 1; generatedUtc = (Get-WddNow).ToString('o'); computer = $env:COMPUTERNAME
            windows = [string] [Environment]::OSVersion.VersionString; powershell = $PSVersionTable.PSVersion.ToString(); packageId = $Manifest.packageId
            outcome = $status.outcome; outcomeCode = $status.exitCode; files = $index; redactedFiles = $redacted
            excluded = 'Answer files (autounattend.xml, unattend.xml), Wi-Fi profiles (*.xml), Panther logs and anything outside the data root are never collected; password and key values are replaced by [redacted].'
        }
        [IO.File]::WriteAllText((Join-Path $staging 'diagnostics.json'), ($info | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $staging 'recovery-status.txt'), (Format-WdrStatus $status), (New-Object Text.UTF8Encoding($true)))
        $outDir = Split-Path -Parent $OutputPath
        if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
        if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($staging, $OutputPath)
        return @{ Outcome = 'Done'; Path = $OutputPath; Files = $index.Count; Redacted = $redacted }
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------------------------------------
# Console
# ------------------------------------------------------------------------------------------------

function Invoke-WdrAction {
    param([hashtable] $Manifest, [hashtable] $Paths, [string] $Action, [string[]] $Operation = @(), [switch] $IncludePermanent, [switch] $Json, [string] $OutputPath = '', [string] $BackupPath = '', [string] $DriverPath = '')
    switch ($Action) {
        'AddDrivers' {
            $r = Invoke-WdrAddDrivers $Manifest $Paths $DriverPath
            $text = $(if ($Json) { [pscustomobject]$r | ConvertTo-Json -Depth 6 } else { "AddDrivers: $($r.Outcome). $($r.Message)" })
            return @{ Text = $text; Exit = [int] $script:RecoveryExit[$r.Outcome] }
        }
        'RestoreSettings' {
            $r = Invoke-WdrRestoreSettings $Manifest $Paths $BackupPath
            $text = $(if ($Json) { [pscustomobject]$r | ConvertTo-Json -Depth 6 } else { "RestoreSettings: $($r.Outcome). $($r.Message)" })
            return @{ Text = $text; Exit = [int] $script:RecoveryExit[$r.Outcome] }
        }
        'Status' {
            $st = Get-WdrStatus $Manifest $Paths
            return @{ Text = $(if ($Json) { $st | ConvertTo-Json -Depth 8 } else { Format-WdrStatus $st }); Exit = [int] $st.exitCode }
        }
        'PendingActions' {
            $items = @(Get-WdrPendingActions $Manifest $Paths)
            $text = $(if ($Json) { ConvertTo-Json @($items) } elseif ($items.Count) { "Pending actions`r`n===============`r`n" + (($items | ForEach-Object { "- $_" }) -join "`r`n") } else { 'Nothing is waiting for a person.' })
            return @{ Text = $text; Exit = 0 }
        }
        'ExportDiagnostics' {
            $r = Export-WdrDiagnostics $Manifest $Paths $OutputPath
            return @{ Text = "Diagnostics: $($r.Path) ($($r.Files) file(s), $($r.Redacted) with values redacted)."; Exit = 0 }
        }
        default {
            $r = Invoke-WdrRecovery $Manifest $Paths $Action -Operations $Operation -IncludePermanent:$IncludePermanent
            $text = $(if ($Json) { [pscustomobject]$r | ConvertTo-Json -Depth 6 } else { "$($Action): $($r.Outcome). $($r.Message)" })
            return @{ Text = $text; Exit = [int] $script:RecoveryExit[$r.Outcome] }
        }
    }
}

function Show-WdrMenu {
    param([hashtable] $Manifest, [hashtable] $Paths)
    while ($true) {
        Write-Output ''
        Write-Output (Format-WdrStatus (Get-WdrStatus $Manifest $Paths))
        Write-Output ''
        Write-Output 'Windows Deployment Recovery'
        Write-Output '  1  Refresh status            4  Retry one application'
        Write-Output '  2  Retry failed operations   5  Resume interrupted provisioning'
        Write-Output '  3  View pending actions      6  Export diagnostic report'
        Write-Output '  7  Restore application settings from a backup folder'
        Write-Output '  8  Add driver packages from a folder (for example a network driver)'
        Write-Output '  0  Exit'
        $c = Read-Host 'Choose'
        $r = switch ($c) {
            '1' { $null }
            '2' { Invoke-WdrAction $Manifest $Paths 'RetryFailed' }
            '3' { Invoke-WdrAction $Manifest $Paths 'PendingActions' }
            '4' {
                $id = Read-Host 'Operation id (from the list, for example app:winget:git.git)'
                $perm = (Read-Host 'Is this a permanent failure whose cause you have corrected? (y/N)') -match '^(y|yes)$'
                Invoke-WdrAction $Manifest $Paths 'Retry' -Operation @($id) -IncludePermanent:$perm
            }
            '5' { Invoke-WdrAction $Manifest $Paths 'Resume' }
            '6' { Invoke-WdrAction $Manifest $Paths 'ExportDiagnostics' }
            '7' { Invoke-WdrAction $Manifest $Paths 'RestoreSettings' -BackupPath (Read-Host 'Backup folder or .zip (for example E:\WindowsDeployment\backups\WDB-AppBackup-...)') }
            '8' { Invoke-WdrAction $Manifest $Paths 'AddDrivers' -DriverPath (Read-Host 'Folder with INF driver packages (for example E:\Drivers\Network)') }
            '0' { return }
            default { @{ Text = 'Choose 0-8.'; Exit = 0 } }
        }
        if ($r) { Write-Output ''; Write-Output $r.Text }
    }
}

if ($script:RecoveryMain) {
    $a = $script:RecoveryArgs
    $package = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    try { $manifest = Read-WddManifest (Join-Path $package 'deployment-manifest.json') } catch { Write-Output "ERROR: $($_.Exception.Message)"; exit 50 }
    $paths = Get-WddPaths $manifest.dataRoot
    $id = Get-WddIdentity
    if ($a.Elevate -and -not $id.IsAdmin) {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $ps -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Action', $a.Action)
        exit 0
    }
    if ($a.Action -eq 'Menu') {
        if (-not $id.IsAdmin) { Write-Output 'Not running as administrator: status only. Retry, resume and diagnostics need administrator rights (use the "Deployment recovery" shortcut or -Elevate).' }
        Show-WdrMenu $manifest $paths
        exit 0
    }
    $r = Invoke-WdrAction $manifest $paths $a.Action -Operation $a.Operation -IncludePermanent:$a.IncludePermanent -Json:$a.Json -OutputPath $a.OutputPath -BackupPath $a.BackupPath -DriverPath $a.DriverPath
    Write-Output $r.Text
    exit $r.Exit
}
