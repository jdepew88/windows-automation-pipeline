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
    5. Registers \WindowsDeploymentBuilder\Deployment (SYSTEM; at startup and every 15 minutes),
       which follows the engines, writes status.json and, at the end, the deployment report.
    6. Opens a progress window for the signed-in user (unless -NoConsole).
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
    $atStartup.Delay = 'PT3M'
    $days = [Math]::Ceiling(([double] $Manifest.failureHandling.orchestrator.deadlineHours) / 24) + 1
    $every = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days $days)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    Register-ScheduledTask -TaskName $script:MonitorTask.name -TaskPath $script:MonitorTask.path -Action $action -Trigger @($atStartup, $every) -Principal $principal -Settings $settings -Force `
        -Description 'Windows Deployment Builder: follows the deployment stages, writes status.json and the final report, then removes itself.' | Out-Null
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

function New-WddState {
    param([hashtable] $Manifest, [string] $SourceMode, [hashtable] $Identity)
    $now = Get-WddNow
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
        try { Register-WddMonitorTask $Paths $Manifest }
        catch {
            # Without the monitor nothing follows the stages: say so instead of failing silently.
            $state.message = "The monitor task $($script:MonitorTask.path)$($script:MonitorTask.name) could not be registered: $($_.Exception.Message) Run Resume-Deployment.ps1 as administrator."
            Save-WddState $Paths $state
            Write-WddLog $state.message 'ERROR'
            Write-WddEvent 3002 "Deployment $($Manifest.packageId): $($state.message)" 'Error'
            return 'MonitorRegistrationFailed'
        }
        Write-WddLog "Registered $($script:MonitorTask.path)$($script:MonitorTask.name) (SYSTEM; at startup and every 15 minutes)."
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
        try { Start-WddTask $script:MonitorTask.path $script:MonitorTask.name } catch { Write-WddLog "Could not start the monitor now; it runs within 15 minutes: $($_.Exception.Message)" 'WARN' }
        if (-not $NoConsole) { try { Start-WddConsole $Paths } catch { Write-WddLog "Could not open the progress window: $($_.Exception.Message)" 'WARN' } }
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
    Write-Output "Deployment: $outcome. Log: $($paths.Log)"
    if ($outcome -in 'Initialized', 'AlreadyCompleted', 'Busy') { exit 0 }
    exit 1
}
