#Requires -Version 5.1
<#
.SYNOPSIS
    Starts the post-installation deployment: verifies and stages the package, launches each
    enabled stage once in its own context and registers the deployment monitor.

.DESCRIPTION
    The answer file runs this as the last FirstLogon command (elevated, as the user that signs in
    first). setup.ps1 runs it for a manual deployment from a WindowsDeployment folder.

    1. Refuses Windows PE, non-elevated sessions, and a second concurrent run (mutex).
    2. Reads deployment-manifest.json and the persistent state (<dataRoot>\state\deployment.json).
       A finished deployment is not started again; a running one is not launched twice.
    3. Secures <dataRoot>, verifies the package and copies it to <dataRoot>\Package
       (Stage-Deployment.ps1). Nothing is launched if verification fails.
    4. Launches each enabled stage once, in manifest order, by running that engine's own installer
       from the staged copy:
         windowsUpdate  Install-UpdateEngine.ps1      registers a SYSTEM task
         applications   Install-ApplicationEngine.ps1 registers a task for this user (WinGet is not
                        supported as SYSTEM, so this script must run as the user, not SYSTEM)
       Each launch is recorded before it starts, so a crash cannot launch a stage twice.
    5. Registers \WindowsDeploymentBuilder\Deployment (SYSTEM; at startup and every
       monitorIntervalMinutes), which follows the engines, writes status.json, recovers stalled
       stages within a bound and, at the end, writes the deployment report.
    6. Orchestrator 1.2.0: registers \WindowsDeploymentBuilder\Progress for the signed-in user (at
       every sign-in while the deployment runs; opens the read-only progress window, which can be
       closed at any time) and, when the package enables it, \WindowsDeploymentBuilder\StatusServer
       (SYSTEM, at startup: the read-only LAN monitor). Every task is checked after registration.
       A stage whose task could not be registered ends initialization with InitializedWithProblems
       (exit code 1) and the reason, never with a plain success.
    7. Opens the progress window for the signed-in user (unless -NoConsole).
#>
[CmdletBinding()]
param(
    [ValidateSet('Embedded', 'Package')]
    [string] $SourceMode = 'Embedded',
    [string] $SourceRoot = '',
    [string] $EmbeddedRoot = 'C:\Windows\Setup\Scripts',
    [switch] $NoConsole
)

$script:InitMain = $MyInvocation.InvocationName -ne '.'
# Captured first: dot-sourcing Stage-Deployment.ps1 binds its own parameters in this scope.
$script:InitArgs = @{ SourceMode = $SourceMode; SourceRoot = $SourceRoot; EmbeddedRoot = $EmbeddedRoot; NoConsole = [bool] $NoConsole }
. (Join-Path $PSScriptRoot '..\common\DeploymentCommon.ps1')
. (Join-Path $PSScriptRoot 'Stage-Deployment.ps1')

$script:MonitorTask = @{ path = '\WindowsDeploymentBuilder\'; name = 'Deployment' }
$script:ProgressTask = @{ path = '\WindowsDeploymentBuilder\'; name = 'Progress' }
$script:StatusServerTask = @{ path = '\WindowsDeploymentBuilder\'; name = 'StatusServer' }
$script:StatusServerScript = 'scripts\monitor\DeploymentStatusServer.ps1'

# ------------------------------------------------------------------------------------------------
# Adapters
# ------------------------------------------------------------------------------------------------

# Runs an engine installer in its own Windows PowerShell process; returns the exit code. Its
# output goes to the log, and its last line is kept as the reason when no task is registered.
function Invoke-WddInstaller {
    param([string] $Path)
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $out = & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path 2>&1
    foreach ($line in @($out)) { Write-WddLog "    | $line" }
    $script:WddInstallerOutput = @(@($out) | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    return $LASTEXITCODE
}

function Register-WddMonitorTask {
    param([hashtable] $Paths, [hashtable] $Manifest)
    $script = Join-Path $Paths.Package 'scripts\orchestrator\DeploymentOrchestrator.ps1'
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
    $atStartup = New-ScheduledTaskTrigger -AtStartup
    $atStartup.Delay = 'PT2M'
    $days = [Math]::Ceiling(([double] $Manifest.failureHandling.orchestrator.deadlineHours) / 24) + 1
    $every = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes (Get-WddMonitorInterval $Manifest)) -RepetitionDuration (New-TimeSpan -Days $days)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    Register-ScheduledTask -TaskName $script:MonitorTask.name -TaskPath $script:MonitorTask.path -Action $action -Trigger @($atStartup, $every) -Principal $principal -Settings $settings -Force `
        -Description 'Windows Deployment Builder: follows the deployment stages, writes status.json and the final report, then removes itself.' | Out-Null
}

<#
    Orchestrator 1.2.0: opens the progress window at every sign-in of the deployment user while the
    deployment runs. It runs as that user without elevation (a viewer, not an engine); a second
    copy exits at once (single instance), and the task is removed when the deployment finishes.
#>
function Register-WddProgressTask {
    param([hashtable] $Paths, [string] $User, [int] $IntervalSeconds = 7)
    $show = Join-Path $Paths.Package 'scripts\orchestrator\Show-DeploymentStatus.ps1'
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$show`" -Watch -AutoStarted -IntervalSeconds $IntervalSeconds"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $User
    $trigger.Delay = 'PT20S'
    $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $script:ProgressTask.name -TaskPath $script:ProgressTask.path -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force `
        -Description 'Windows Deployment Builder: opens the read-only deployment progress window at sign-in while the deployment runs. Closing the window does not stop the deployment. Removed when the deployment finishes.' | Out-Null
}

<#
    Orchestrator 1.2.0: the read-only LAN monitor (DeploymentStatusServer.ps1) as SYSTEM, started at
    every startup and restarted if it stops. It serves status only; it ends itself after the
    deployment (see the script).
#>
function Register-WddStatusServerTask {
    param([hashtable] $Paths)
    $server = Join-Path $Paths.Package $script:StatusServerScript
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$server`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT1M'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $script:StatusServerTask.name -TaskPath $script:StatusServerTask.path -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force `
        -Description 'Windows Deployment Builder: read-only deployment monitor (HTTP). Serves status only; removes itself after the deployment.' | Out-Null
}

function Start-WddConsole {
    param([hashtable] $Paths)
    $show = Join-Path $Paths.Package 'scripts\orchestrator\Show-DeploymentStatus.ps1'
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$show`"", '-Watch')
}

function Get-WddRecoveryShortcut {
    param([hashtable] $Paths)
    $tool = Join-Path $Paths.Package 'scripts\recovery\DeploymentRecovery.ps1'
    if (-not (Test-Path -LiteralPath $tool)) { return $null }
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    @{ Target = $ps; Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$tool`" -Elevate" }
}

function Get-WddProgressShortcut {
    param([hashtable] $Paths)
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    @{ Target = $ps; Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $Paths.Package 'scripts\orchestrator\Show-DeploymentStatus.ps1')`" -Watch" }
}

# ------------------------------------------------------------------------------------------------
# Initialization
# ------------------------------------------------------------------------------------------------

<# Minutes between monitor runs (the manifest's value; 15 for manifests written before 1.2.0). #>
<# The LAN monitor block of the manifest (absent or disabled: $null). #>
function Get-WddMonitorConfig {
    param([hashtable] $Manifest)
    if (-not $Manifest.ContainsKey('monitor') -or $Manifest.monitor -isnot [hashtable] -or -not $Manifest.monitor['enabled']) { return $null }
    return $Manifest.monitor
}

<#
    Registers the viewer tasks that follow the deployment user and the LAN monitor, and checks that
    each one exists afterwards. Returns the problems (empty when everything is registered).
#>
function Register-WddHelperTasks {
    param([hashtable] $Manifest, [hashtable] $Paths, [string] $User)
    $problems = @()
    if ($User -and $User -notmatch '(?i)^(NT AUTHORITY\\)?SYSTEM$') {
        try { Register-WddProgressTask $Paths $User } catch { $problems += "progress window task: $($_.Exception.Message)" }
        if (-not (Get-WddTask $script:ProgressTask.path $script:ProgressTask.name) -and -not ($problems -match 'progress window')) { $problems += 'progress window task: not found after registration' }
    }
    if (Get-WddMonitorConfig $Manifest) {
        if (-not (Test-Path -LiteralPath (Join-Path $Paths.Package $script:StatusServerScript))) { $problems += "LAN monitor: $($script:StatusServerScript) is missing from the package" }
        else {
            try { Register-WddStatusServerTask $Paths } catch { $problems += "LAN monitor task: $($_.Exception.Message)" }
            if (Get-WddTask $script:StatusServerTask.path $script:StatusServerTask.name) {
                try { Start-WddTask $script:StatusServerTask.path $script:StatusServerTask.name } catch { Write-WddLog "Could not start the LAN monitor now; it starts at the next startup: $($_.Exception.Message)" 'WARN' }
            } elseif (-not ($problems -match 'LAN monitor')) { $problems += 'LAN monitor task: not found after registration' }
        }
    }
    foreach ($p in $problems) { Write-WddLog "Helper task: $p" 'WARN' }
    # One problem per pipeline object; callers collect them with @().
    return $problems
}

function New-WddState {
    param([hashtable] $Manifest, [string] $SourceMode, [hashtable] $Identity)
    $now = Get-WddNow
    $o = $Manifest.failureHandling.orchestrator
    $boot = $null
    try { $boot = (Get-WddBootTime).ToString('o') } catch { }
    @{
        schemaVersion        = 2
        packageId            = $Manifest.packageId
        packageVersion       = $Manifest.packageVersion
        orchestratorVersion  = $script:DeployVersion
        sourceMode           = $SourceMode
        status               = 'Staging'
        initializedUtc       = $now.ToString('o')
        initializedBy        = $Identity.Name
        deadlineUtc          = $now.AddHours([double] $Manifest.failureHandling.orchestrator.deadlineHours).ToString('o')
        stalledAfterMinutes  = [int] $Manifest.failureHandling.orchestrator.stalledAfterMinutes
        # Orchestrator 1.2.0: no-progress limit for long Windows Update phases, restart history.
        longOperationMinutes = $(if ($o -is [hashtable] -and $o.ContainsKey('longOperationMinutes')) { [int] $o.longOperationMinutes } else { 240 })
        lastBootUtc          = $boot
        restarts             = @()
        stagedFiles          = @()
        stages               = @{}
        monitorRuns          = 0
        overall              = ''
        message              = ''
        recoveries           = @()
    }
}

<#
    Launches one engine stage unless it was already launched. Returns its launch record.
#>
function Invoke-WddLaunchStage {
    param([hashtable] $Stage, [hashtable] $Paths, [hashtable] $State, [hashtable] $Identity, [int] $MaxAttempts)
    $rec = if ($State.stages.ContainsKey($Stage.id)) { $State.stages[$Stage.id] } else { @{ launchResult = ''; attempts = 0; launchedUtc = $null; exitCode = $null; message = '' } }
    $State.stages[$Stage.id] = $rec
    # Phase 5: who the stage runs as (a user-context stage only runs while that user is signed in).
    if (-not $rec.ContainsKey('user') -or -not $rec.user) { $rec.user = $(if ($Stage.context -eq 'user') { [string] $Identity.Name } else { 'SYSTEM' }) }
    if ($rec.launchResult -eq 'Launched') { Write-WddLog "Stage $($Stage.id) was already launched; not launching it again."; return $rec }
    # Interrupted earlier launch: if its task exists the installer finished registering it.
    if ($rec.launchResult -eq 'Launching' -and (Get-WddTask $Stage.task.path $Stage.task.name)) {
        $rec.launchResult = 'Launched'; $rec.message = 'Task found after an interrupted launch.'
        Write-WddLog "Stage $($Stage.id): task found after an interrupted launch; marked launched."
        return $rec
    }
    if ($Stage.context -eq 'user' -and $Identity.IsSystem) {
        $rec.launchResult = 'LaunchFailed'
        $rec.message = 'This stage must be started by the signed-in user (WinGet is not supported as SYSTEM). Sign in and run Resume-Deployment.ps1 -RestartStage applications.'
        Write-WddLog "Stage $($Stage.id): $($rec.message)" 'ERROR'
        return $rec
    }
    if ([int] $rec.attempts -ge $MaxAttempts) {
        $rec.launchResult = 'LaunchFailed'
        if (-not $rec.message) { $rec.message = "Launch attempts exhausted ($MaxAttempts)." }
        return $rec
    }
    $installer = Join-Path $Paths.Package ($Stage.launcher -replace '/', '\')
    $rec.attempts = [int] $rec.attempts + 1
    $rec.launchResult = 'Launching'
    $rec.launchedUtc = (Get-WddNow).ToString('o')
    Save-WddState $Paths $State
    Write-WddLog "Launching stage $($Stage.id) ($($Stage.context)): $installer"
    $code = $null
    $script:WddInstallerOutput = @()
    # The reason of THIS attempt (an earlier message, such as "Restarted manually.", is not one).
    $failure = $null
    if (-not (Test-Path -LiteralPath $installer)) { $failure = "The installer is missing from the staged package: $installer" }
    else { try { $code = Invoke-WddInstaller $installer } catch { $failure = $_.Exception.Message; Write-WddLog "  installer error: $failure" 'ERROR' } }
    $rec.exitCode = $code
    if (Get-WddTask $Stage.task.path $Stage.task.name) {
        $rec.launchResult = 'Launched'
        if ($code -ne 0) { $rec.message = "The installer returned $code, but the task is registered; it will run at the next start or sign-in." }
        Write-WddLog "Stage $($Stage.id) launched (task $($Stage.task.path)$($Stage.task.name), installer exit code $code)."
    } elseif (Test-Path -LiteralPath (Join-Path $Paths.Root $Stage.result)) {
        $rec.launchResult = 'Launched'; $rec.message = 'Finished during launch.'
    } else {
        $rec.launchResult = $(if ([int] $rec.attempts -ge $MaxAttempts) { 'LaunchFailed' } else { 'Launching' })
        $reason = @($script:WddInstallerOutput) | Select-Object -Last 1
        $rec.message = $(if ($failure) { $failure } else { "The installer returned $code and registered no task $($Stage.task.path)$($Stage.task.name)$(if ($reason) { ": $reason" } else { '.' })" })
        Write-WddLog "Stage $($Stage.id): $($rec.message)" 'ERROR'
    }
    Save-WddState $Paths $State
    return $rec
}

function Invoke-WddInitialize {
    param([hashtable] $Manifest, [string] $ManifestPath, [string] $SourceMode, [string] $SourceRoot, [string] $EmbeddedRoot, [hashtable] $Paths, [switch] $NoConsole)
    Initialize-WddLogging $Paths
    $identity = Get-WddIdentity
    Write-WddLog "==== Deployment orchestrator $($script:DeployVersion): initialize ($SourceMode) as $($identity.Name), package $($Manifest.packageId) ===="
    if (Test-WddWinPE) { Write-WddLog 'Refusing to run in Windows PE.' 'ERROR'; return 'RefusedWinPE' }
    if (-not $identity.IsAdmin) { Write-WddLog 'Refusing to run without administrator rights.' 'ERROR'; return 'RefusedNotElevated' }

    $mutex = Enter-WddMutex 120
    if (-not $mutex) { Write-WddLog 'Another deployment process is running; nothing to do.' 'WARN'; return 'Busy' }
    try {
        $read = Read-WddDeploymentState $Paths
        if ($read.Source -eq 'corrupt') {
            # Never start over on top of a damaged state: that would launch stages a second time.
            Write-WddLog "The deployment state is damaged ($($read.Problem)); refusing to start over. Run DeploymentRecovery.ps1 -Action Resume." 'ERROR'
            return 'StateCorrupt'
        }
        $state = $read.State
        if ($state) {
            if ($state.packageId -ne $Manifest.packageId -and $state.status -notin 'Completed', 'StagingFailed') {
                Write-WddLog "A different deployment ($($state.packageId)) is still in progress; refusing to start $($Manifest.packageId). Finish or reset it first (see recovery instructions)." 'ERROR'
                return 'AnotherDeploymentInProgress'
            }
            if ($state.packageId -eq $Manifest.packageId -and $state.status -eq 'Completed') {
                Write-WddLog "This deployment already finished ($($state.overall)). Report: $($Paths.ReportText)"
                return 'AlreadyCompleted'
            }
            if ($state.packageId -ne $Manifest.packageId) { $state = $null }
        }
        if (-not $state -or $state.status -eq 'StagingFailed') { $state = New-WddState $Manifest $SourceMode $identity }
        # A staged copy that failed its integrity check is replaced; launch records are kept, so
        # stages that were already launched are not launched again.
        if ($state.status -eq 'IntegrityFailed') { $state.status = 'Staging'; $state.sourceMode = $SourceMode; $state.message = 'Re-staging after an integrity failure.' }
        foreach ($k in 'stages') { if (-not $state[$k]) { $state[$k] = @{} } }

        # Stage (verify + copy) unless already staged for this package.
        if ($state.status -eq 'Staging') {
            Set-WddAcl $Paths.Root
            $staged = Invoke-WddStage $Manifest $ManifestPath $SourceMode $SourceRoot $EmbeddedRoot $Paths
            if (-not $staged.Ok) {
                $state.status = 'StagingFailed'; $state.overall = 'Failed'; $state.message = $staged.Message
                Save-WddState $Paths $state
                $snap = [ordered]@{ packageId = $Manifest.packageId; updatedUtc = (Get-WddNow).ToString('o'); deploymentState = 'StagingFailed'; overall = 'Failed'; message = $staged.Message; missing = $staged.Missing; modified = $staged.Mismatched }
                Set-WddSnapshotOutcome $snap $state
                Write-WddJson $Paths.Status $snap
                Write-WddEvent 3002 "Deployment not started: $($staged.Message) See $($Paths.Log)." 'Error'
                return 'StagingFailed'
            }
            Set-WddAcl $Paths.Root
            $state.stagedFiles = $staged.Files
            $state.status = 'Launching'
            Save-WddState $Paths $state
        }

        # Launch each enabled engine stage once.
        $max = [int] $Manifest.failureHandling.orchestrator.launchAttempts
        foreach ($stage in Get-WddEngineStages $Manifest) {
            Invoke-WddLaunchStage $stage $Paths $state $identity $max | Out-Null
        }

        $state.status = 'InProgress'
        Save-WddState $Paths $state
        $monitorError = $null
        try { Register-WddMonitorTask $Paths $Manifest } catch { $monitorError = $_.Exception.Message }
        if (-not $monitorError -and -not (Get-WddTask $script:MonitorTask.path $script:MonitorTask.name)) { $monitorError = 'the task was not found after registration.' }
        if ($monitorError) {
            # Without the monitor nothing follows the stages: say so instead of failing silently.
            $state.message = "The monitor task $($script:MonitorTask.path)$($script:MonitorTask.name) could not be registered: $monitorError Run Resume-Deployment.ps1 as administrator."
            Save-WddState $Paths $state
            Write-WddLog $state.message 'ERROR'
            Write-WddEvent 3002 "Deployment $($Manifest.packageId): $($state.message)" 'Error'
            return 'MonitorRegistrationFailed'
        }
        Write-WddLog "Registered $($script:MonitorTask.path)$($script:MonitorTask.name) (SYSTEM; at startup and every $(Get-WddMonitorInterval $Manifest) minutes)."
        $helperProblems = @(Register-WddHelperTasks $Manifest $Paths ([string] $identity.Name))
        # Orchestrator 1.2.0: initialization is complete only when every stage task exists.
        $notLaunched = @(Get-WddEngineStages $Manifest | Where-Object { [string] $state.stages[$_.id].launchResult -ne 'Launched' })
        if ($notLaunched.Count) {
            $state.message = "Initialized, but $($notLaunched.Count) stage(s) could not be started: $(($notLaunched | ForEach-Object { "$($_.name): $($state.stages[$_.id].message)" }) -join ' ') The monitor retries automatically where it can; see the progress window."
            Write-WddLog $state.message 'ERROR'
            Write-WddEvent 3002 "Deployment $($Manifest.packageId): $($state.message)" 'Warning'
        } elseif ($helperProblems.Count) {
            $state.message = "The deployment runs, but a helper task could not be registered: $($helperProblems -join '; ')"
        }
        Save-WddState $Paths $state
        Add-WddActivity $Paths $(if ($notLaunched.Count) { $state.message } else { "Deployment started: $(@(Get-WddEngineStages $Manifest).Count) stage(s) scheduled ($((Get-WddEngineStages $Manifest | ForEach-Object { $_.name }) -join ', '))." }) $(if ($notLaunched.Count) { 'error' } else { 'info' })
        $snapshot = Get-WddSnapshot $Manifest $Paths $state
        Write-WddJson $Paths.Status $snapshot
        try {
            $sc = Get-WddProgressShortcut $Paths
            New-WddShortcut 'Deployment progress' $sc.Target $sc.Arguments 'Windows Deployment Builder: deployment progress'
        } catch { Write-WddLog "Could not create the progress shortcut: $($_.Exception.Message)" 'WARN' }
        # Phase 5: the technician recovery entry point, when the package carries it.
        $rt = Get-WddRecoveryShortcut $Paths
        if ($rt) {
            try { New-WddShortcut 'Deployment recovery' $rt.Target $rt.Arguments 'Windows Deployment Builder: status, retry failed applications, resume, diagnostics (asks for administrator rights)' }
            catch { Write-WddLog "Could not create the recovery shortcut: $($_.Exception.Message)" 'WARN' }
        }
        Write-WddEvent 3000 "Deployment $($Manifest.packageId) started. Status: $($Paths.Status)."
        try { Start-WddTask $script:MonitorTask.path $script:MonitorTask.name } catch { Write-WddLog "Could not start the monitor now; it runs within $(Get-WddMonitorInterval $Manifest) minutes: $($_.Exception.Message)" 'WARN' }
        if (-not $NoConsole) {
            # The progress task opens the window without elevation (single instance); a direct start is the fallback.
            $opened = $false
            if (Get-WddTask $script:ProgressTask.path $script:ProgressTask.name) { try { Start-WddTask $script:ProgressTask.path $script:ProgressTask.name; $opened = $true } catch { Write-WddLog "Could not start the progress task: $($_.Exception.Message)" 'WARN' } }
            if (-not $opened) { try { Start-WddConsole $Paths } catch { Write-WddLog "Could not open the progress window: $($_.Exception.Message)" 'WARN' } }
        }
        if ($notLaunched.Count) { return 'InitializedWithProblems' }
        return 'Initialized'
    } finally {
        Exit-WddMutex $mutex
    }
}

# Dot-sourcing (tests) only defines the functions.
if ($script:InitMain) {
    $a = $script:InitArgs
    $root = if ($a.SourceRoot) { $a.SourceRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    $manifestPath = Join-Path $root 'deployment-manifest.json'
    try {
        $manifest = Read-WddManifest $manifestPath
    } catch {
        Write-Output "ERROR: $($_.Exception.Message)"
        exit 2
    }
    $paths = Get-WddPaths $manifest.dataRoot
    $outcome = Invoke-WddInitialize $manifest $manifestPath $a.SourceMode $root $a.EmbeddedRoot $paths -NoConsole:$a.NoConsole
    $detail = ''
    if ($outcome -eq 'InitializedWithProblems') { $s = (Read-WddDeploymentState $paths).State; if ($s) { $detail = " $($s.message)" } }
    Write-Output "Deployment: $outcome.$detail Log: $($paths.Log)"
    if ($outcome -in 'Initialized', 'AlreadyCompleted', 'Busy') { exit 0 }
    exit 1
}
