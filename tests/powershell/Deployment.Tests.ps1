#Requires -Version 5.1
<#
    Scenario tests for the Phase 4 deployment orchestrator (src\engine\deployment\scripts) against
    the REAL deployment package produced by the generator (see deployment-fixture.ts) and a
    simulated machine: scheduled tasks, engine installers, identity, Windows PE, time, restarts,
    ACLs, shortcuts and the event log are all replaced. Nothing is registered, installed, secured or
    restarted; everything is written below a temporary folder.

    Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\powershell\Deployment.Tests.ps1 -Fixture <dir>
    (<dir> from "vite-node tests/powershell/deployment-fixture.ts <dir>"; npm run test:ps does both.)
#>
param([Parameter(Mandatory = $true)] [string] $Fixture)

$ErrorActionPreference = 'Stop'
# The scripts are loaded from the generated package itself (the files that ship), not from src.
$pkgScripts = Join-Path $Fixture 'usb\WindowsDeployment\scripts'
. (Join-Path $pkgScripts 'common\DeploymentCommon.ps1')
. (Join-Path $pkgScripts 'bootstrap\Stage-Deployment.ps1')
. (Join-Path $pkgScripts 'bootstrap\Initialize-Deployment.ps1')
. (Join-Path $pkgScripts 'finalization\Complete-Deployment.ps1')
. (Join-Path $pkgScripts 'orchestrator\DeploymentOrchestrator.ps1')
. (Join-Path $pkgScripts 'orchestrator\Show-DeploymentStatus.ps1')
. (Join-Path $pkgScripts 'orchestrator\Resume-Deployment.ps1')
# Phase 5: the recovery tool (it also loads the package's ApplicationEngine.ps1).
. (Join-Path $pkgScripts 'recovery\DeploymentRecovery.ps1')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$script:Failures = 0
$script:Passed = 0
$script:Zoe = "Zo$([char]0xEB) Test Package"
$script:MutexName = "Global\WDD-Test-$([guid]::NewGuid().ToString('N'))"
$usb = Join-Path $Fixture 'usb'
$pkgRoot = Join-Path $usb 'WindowsDeployment'
$manifestPath = Join-Path $pkgRoot 'deployment-manifest.json'

# The simulated computer (shared with Health.Tests.ps1).
. (Join-Path $PSScriptRoot 'ProvisioningSim.ps1')
# Phase 9: the deployment verifies itself at the end; its Windows probes are simulated too.
. (Join-Path $PSScriptRoot 'HealthSim.ps1')

Write-Output "Deployment orchestrator scenarios (fixture $Fixture)"

# ------------------------------------------------------------------------------------------------
# Package, manifest and staging
# ------------------------------------------------------------------------------------------------

Test-Scenario 'ZIP package: every file matches the manifest byte for byte (TypeScript = PowerShell SHA-256)' {
    $c = Test-WddFiles $pkgRoot $script:Manifest 'Raw'
    Assert-True $c.Ok "missing: $($c.Missing -join ', ') modified: $($c.Mismatched -join ', ')"
    Assert-Equal $c.Checked @($script:Manifest.files).Count 'all files checked'
    Assert-True (Test-Path -LiteralPath (Join-Path $usb 'autounattend.xml')) 'answer file at the USB root'
    foreach ($f in @($script:Manifest.files)) { Assert-True (Test-Path -LiteralPath (Join-Path $pkgRoot $f.path)) "$($f.path) present" }
}

Test-Scenario 'ZIP package: every launcher and required script referenced by the manifest exists' {
    foreach ($s in @($script:Manifest.stages)) { if ($s.launcher) { Assert-True (Test-Path -LiteralPath (Join-Path $pkgRoot $s.launcher)) "launcher $($s.launcher)" } }
    foreach ($r in $script:RequiredForStart) { Assert-True (Test-Path -LiteralPath (Join-Path $pkgRoot $r)) "required $r" }
    $t = $null; $e = $null
    foreach ($ps1 in Get-ChildItem -LiteralPath $pkgRoot -Recurse -Filter *.ps1) {
        [void][System.Management.Automation.Language.Parser]::ParseFile($ps1.FullName, [ref]$t, [ref]$e)
        Assert-Equal $e.Count 0 "$($ps1.Name) parses"
    }
}

Test-Scenario 'answer-file extraction: text hashes match for every embedded file (real ExtractScript)' {
    $emb = Invoke-SimExtraction
    $files = @(@($script:Manifest.files) | Where-Object { $_.embedded })
    Assert-True ($files.Count -ge 15) "embedded files listed ($($files.Count))"
    $r = Invoke-WddStage $script:Manifest (Join-Path $emb 'Deployment\deployment-manifest.json') 'Embedded' (Join-Path $emb 'Deployment') $emb $script:Paths -VerifyOnly
    Assert-True $r.Ok "verification: $($r.Message) $($r.Missing -join ',') $($r.Mismatched -join ',')"
    # Since Phase 4.2 the application config escapes non-ASCII (\uXXXX), so even the non-ASCII
    # display name is verified by exact text hash (previously only structurally), and both the
    # ANSI-extracted copy and the UTF-8 ZIP copy decode to the same name.
    $nonAscii = @($files | Where-Object { -not $_.textSha256 })
    Assert-Equal $nonAscii.Count 0 'every embedded file is verified by exact text hash'
    $extracted = Join-Path $emb 'Applications\applications-config.json'
    $zipCopy = Join-Path $pkgRoot 'scripts\applications\applications-config.json'
    foreach ($cfg in $extracted, $zipCopy) {
        $names = @((Read-WddJson $cfg).packages | ForEach-Object { $_.displayName })
        Assert-True ($names -contains $script:Zoe) "non-ASCII name decodes correctly from $(Split-Path -Leaf (Split-Path -Parent $cfg))"
        Assert-True (@((Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json).packages | ForEach-Object { $_.displayName }) -contains $script:Zoe) 'also with the code-page-dependent Get-Content the engine uses'
    }
}

Test-Scenario 'staging (embedded): copies to the package folder, verifies the copy, secures the folder' {
    $emb = Invoke-SimExtraction
    $r = Invoke-WddStage $script:Manifest (Join-Path $emb 'Deployment\deployment-manifest.json') 'Embedded' (Join-Path $emb 'Deployment') $emb $script:Paths
    Assert-True $r.Ok $r.Message
    Assert-True (Test-Path -LiteralPath (Join-Path $script:Paths.Package 'scripts\windows-update\Install-UpdateEngine.ps1')) 'engine installer staged'
    Assert-True (Test-Path -LiteralPath (Join-Path $script:Paths.Package 'deployment-manifest.json')) 'manifest staged'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:Paths.Package 'setup.ps1'))) 'USB-only files are not needed after installation'
}

Test-Scenario 'staging (package): works from the USB folder; the USB can be removed afterwards' {
    $r = Invoke-WddStage $script:Manifest $manifestPath 'Package' $pkgRoot '' $script:Paths
    Assert-True $r.Ok $r.Message
    $copy = Join-Path $script:Tmp 'usb-copy'
    Copy-Item -LiteralPath $pkgRoot -Destination $copy -Recurse
    $r2 = Invoke-WddStage $script:Manifest (Join-Path $copy 'deployment-manifest.json') 'Package' $copy '' $script:Paths
    Assert-True $r2.Ok 'staging again from another location'
    Remove-Item -LiteralPath $copy -Recurse -Force
    $c = Test-WddFiles $script:Paths.Package $script:Manifest 'Text' $r2.Files
    Assert-True $c.Ok 'staged copy still valid without the source'
    Assert-True (Test-Path -LiteralPath "$($script:Paths.Package).previous") 'previous package kept aside, not deleted'
}

Test-Scenario 'missing configuration file: staging fails and nothing is launched' {
    $emb = Invoke-SimExtraction
    Remove-Item -LiteralPath (Join-Path $emb 'WindowsUpdate\config.json')
    $out = Invoke-WddInitialize $script:Manifest (Join-Path $emb 'Deployment\deployment-manifest.json') 'Embedded' (Join-Path $emb 'Deployment') $emb $script:Paths -NoConsole
    Assert-Equal $out 'StagingFailed' 'outcome'
    Assert-Equal $script:Installers.Count 0 'no installer ran'
    Assert-True (-not $script:SimTasks.ContainsKey('\WindowsDeploymentBuilder\Deployment')) 'no monitor registered'
    $s = Read-WddJson $script:Paths.Status
    Assert-Equal $s.deploymentState 'StagingFailed' 'status'
    Assert-True ($s.missing -contains 'scripts/windows-update/config.json') 'missing file named'
    Assert-True ($script:Events -contains 3002) 'error event'
}

Test-Scenario 'modified file: staging refuses a package that does not match its manifest' {
    $copy = Join-Path $script:Tmp 'usb'
    Copy-Item -LiteralPath $pkgRoot -Destination $copy -Recurse
    Add-Content -LiteralPath (Join-Path $copy 'scripts\applications\ApplicationEngine.ps1') -Value 'Write-Output tampered'
    $r = Invoke-WddStage $script:Manifest (Join-Path $copy 'deployment-manifest.json') 'Package' $copy '' $script:Paths
    Assert-True (-not $r.Ok) 'refused'
    Assert-True ($r.Mismatched -contains 'scripts/applications/ApplicationEngine.ps1') 'modified file named'
    Assert-True (-not (Test-Path -LiteralPath $script:Paths.Package)) 'nothing copied'
}

Test-Scenario 'missing USB media: package mode fails cleanly; the embedded source does not need the USB' {
    $gone = Join-Path $script:Tmp 'no-usb'
    $r = Invoke-WddStage $script:Manifest $manifestPath 'Package' $gone '' $script:Paths
    Assert-True (-not $r.Ok) 'package source missing'
    Assert-True ($r.Missing.Count -ge 10) 'files reported missing'
    Assert-Equal (Initialize-Embedded) 'Initialized' 'embedded deployment starts without the USB folder'
}

Test-Scenario 'invalid manifests are rejected' {
    $bad = Join-Path $script:Tmp 'bad.json'
    $base = Get-Content -LiteralPath $manifestPath -Raw
    $cases = @{
        'format'  = $base -replace 'windows-deployment-builder/deployment-manifest', 'something-else'
        'version' = $base -replace '"manifestVersion": 1', '"manifestVersion": 9'
        'path'    = $base -replace '"path": "setup.cmd"', '"path": "..\\..\\Windows\\evil.cmd"'
        'hash'    = $base -replace '"sha256": "[0-9A-F]{64}"', '"sha256": "abc"'
        'stage'   = $base -replace '"id": "finalization"', '"id": "formatDisk"'
        'json'    = $base.Substring(0, 200)
    }
    foreach ($k in $cases.Keys) {
        [IO.File]::WriteAllText($bad, $cases[$k])
        $threw = $false
        try { Read-WddManifest $bad | Out-Null } catch { $threw = $true }
        Assert-True $threw "manifest with bad $k rejected"
    }
}

# ------------------------------------------------------------------------------------------------
# First boot: contexts, single launch, duplicates
# ------------------------------------------------------------------------------------------------

Test-Scenario 'first sign-in: stages launched once in order, monitor registered, progress shortcut' {
    $out = Initialize-Embedded
    Assert-Equal $out 'Initialized' 'outcome'
    Assert-Equal ($script:Installers -join ',') 'Install-UpdateEngine.ps1,Install-ApplicationEngine.ps1' 'installer order'
    Assert-True $script:SimTasks.ContainsKey('\WindowsDeploymentBuilder\WindowsUpdate') 'WU task'
    Assert-True $script:SimTasks.ContainsKey('\WindowsDeploymentBuilder\Applications') 'apps task'
    Assert-True $script:SimTasks.ContainsKey('\WindowsDeploymentBuilder\Deployment') 'monitor task'
    $st = Read-WddJson $script:Paths.State
    Assert-Equal $st.status 'InProgress' 'state'
    Assert-Equal $st.stages.windowsUpdate.launchResult 'Launched' 'WU launched'
    Assert-Equal $st.stages.applications.launchResult 'Launched' 'apps launched'
    Assert-True ($script:AclCalls -ge 1) 'data folder secured'
    Assert-True $script:Shortcuts.ContainsKey('Deployment progress') 'progress shortcut'
    Assert-True ($script:Events -contains 3000) 'start event'
    $s = Read-WddJson $script:Paths.Status
    Assert-Equal $s.overall 'InProgress' 'not reported complete'
}

Test-Scenario 'duplicate execution: a second run launches nothing again; a concurrent run is refused' {
    Initialize-Embedded | Out-Null
    Assert-Equal (Initialize-Embedded) 'Initialized' 'second run'
    Assert-Equal $script:Installers.Count 2 'installers ran once each'
    $m = New-Object System.Threading.Mutex($false, $script:MutexName)
    # The job signals once it really holds the mutex (a fixed sleep raced on a busy machine).
    $flag = Join-Path $script:Tmp 'mutex-held'
    $job = Start-Job -ScriptBlock { param($n, $f) $x = New-Object System.Threading.Mutex($false, $n); [void]$x.WaitOne(); [IO.File]::WriteAllText($f, 'held'); Start-Sleep -Seconds 8; $x.ReleaseMutex() } -ArgumentList $script:MutexName, $flag
    for ($i = 0; $i -lt 600 -and -not (Test-Path -LiteralPath $flag); $i++) { Start-Sleep -Milliseconds 100 }
    Assert-True (Test-Path -LiteralPath $flag) 'the other process holds the deployment mutex'
    $saved = $script:MutexName
    try {
        function Enter-WddMutex { param([int] $TimeoutSeconds = 0) $mm = New-Object System.Threading.Mutex($false, $saved); if ($mm.WaitOne([TimeSpan]::FromSeconds(0))) { return $mm }; $mm.Dispose(); return $null }
        Assert-Equal (Initialize-Embedded) 'Busy' 'concurrent run'
        Assert-Equal (Invoke-WddMonitor $script:Paths) 'Busy' 'concurrent monitor'
    } finally { $job | Wait-Job | Remove-Job; $m.Dispose() }
}

Test-Scenario 'SYSTEM context: Windows Update launches, the WinGet stage is refused (user context only)' {
    $script:SimIdentity = @{ Name = 'NT AUTHORITY\SYSTEM'; IsSystem = $true; IsAdmin = $true }
    Initialize-Embedded | Out-Null
    $st = Read-WddJson $script:Paths.State
    Assert-Equal $st.stages.windowsUpdate.launchResult 'Launched' 'WU'
    Assert-Equal $st.stages.applications.launchResult 'LaunchFailed' 'apps refused'
    Assert-True ($st.stages.applications.message -like '*signed-in user*') 'reason'
    Assert-Equal ($script:Installers -join ',') 'Install-UpdateEngine.ps1' 'only WU installer ran'
    $snap = Get-WddSnapshot $script:Manifest $script:Paths $st
    Assert-True (@($snap.needsAttention).Count -ge 1) 'needs attention'
}

Test-Scenario 'refusals: Windows PE and non-elevated sessions change nothing' {
    $script:SimWinPE = $true
    Assert-Equal (Initialize-Embedded) 'RefusedWinPE' 'WinPE'
    $script:SimWinPE = $false
    $script:SimIdentity = @{ Name = 'PC\Alex'; IsSystem = $false; IsAdmin = $false }
    Assert-Equal (Initialize-Embedded) 'RefusedNotElevated' 'not elevated'
    Assert-Equal $script:Installers.Count 0 'nothing launched'
    Assert-True (-not (Test-Path -LiteralPath $script:Paths.Package)) 'nothing staged'
}

Test-Scenario 'interrupted launch: a crash during an installer is resumed without launching twice' {
    $script:InstallerBehaviour['Install-ApplicationEngine.ps1'] = 'throw'
    Initialize-Embedded | Out-Null
    $st = Read-WddJson $script:Paths.State
    Assert-Equal $st.stages.applications.launchResult 'Launching' 'first attempt incomplete'
    $script:InstallerBehaviour['Install-ApplicationEngine.ps1'] = 'ok'
    Initialize-Embedded | Out-Null
    $st = Read-WddJson $script:Paths.State
    Assert-Equal $st.stages.applications.launchResult 'Launched' 'second attempt'
    Assert-Equal $st.stages.applications.attempts 2 'attempts counted'
    Assert-Equal @($script:Installers | Where-Object { $_ -eq 'Install-UpdateEngine.ps1' }).Count 1 'WU installer not repeated'
}

Test-Scenario 'launch limit: an installer that never registers its task ends LaunchFailed (no loop)' {
    $script:InstallerBehaviour['Install-UpdateEngine.ps1'] = 'noTask'
    1..4 | ForEach-Object { Initialize-Embedded | Out-Null }
    $st = Read-WddJson $script:Paths.State
    Assert-Equal $st.stages.windowsUpdate.launchResult 'LaunchFailed' 'gave up'
    Assert-Equal @($script:Installers | Where-Object { $_ -eq 'Install-UpdateEngine.ps1' }).Count 2 'two attempts only'
}

# Bare-metal regression: stage tasks missing, recovery must not claim success.
Test-Scenario 'a stage whose installer registers no task records the reason and the task it expected' {
    $script:InstallerBehaviour['Install-UpdateEngine.ps1'] = 'noTask'
    Initialize-Embedded | Out-Null
    $rec = (Read-WddJson $script:Paths.State).stages.windowsUpdate
    Assert-True ($rec.launchResult -ne 'Launched') 'not launched'
    Assert-True ($rec.message.Contains('\WindowsDeploymentBuilder\WindowsUpdate')) "expected task named ($($rec.message))"
    Assert-True ($rec.message -match 'is denied') "installer reason kept ($($rec.message))"
    Assert-True ((Get-Content -LiteralPath $script:Paths.Log -Raw) -match 'registered no task') 'logged'
}

Test-Scenario 'Resume -RestartStage: a stage whose task is not registered is StageRestartFailed, never Resumed; then it recovers' {
    Initialize-Embedded | Out-Null
    $script:SimTasks.Remove('\WindowsDeploymentBuilder\WindowsUpdate') | Out-Null   # the missing task of the field report
    $script:InstallerBehaviour['Install-UpdateEngine.ps1'] = 'noTask'
    $script:ResumeDetail = ''
    Assert-Equal (Invoke-WddResume $script:Paths 'windowsUpdate') 'StageRestartFailed' 'failure reported'
    Assert-True ($script:ResumeDetail -match 'is denied') "reason shown ($($script:ResumeDetail))"
    Assert-True (-not $script:SimTasks.ContainsKey('\WindowsDeploymentBuilder\WindowsUpdate')) 'no task'
    $st = Read-WddJson $script:Paths.State
    Assert-True ($st.stages.windowsUpdate.launchResult -ne 'Launched') 'state does not claim a launch'
    Assert-True ($st.message -match 'Restart of stage windowsUpdate failed') "state message ($($st.message))"
    Assert-True ($script:Events -contains 3006) 'error event'
    Assert-True ($st.stages.applications.launchResult -eq 'Launched') 'other stage records kept'
    # After the cause is fixed the same command works, and nothing else is relaunched.
    $script:InstallerBehaviour['Install-UpdateEngine.ps1'] = 'ok'
    $before = $script:Installers.Count
    Assert-Equal (Invoke-WddResume $script:Paths 'windowsUpdate') 'Resumed' 'recovered'
    Assert-True $script:SimTasks.ContainsKey('\WindowsDeploymentBuilder\WindowsUpdate') 'task registered'
    Assert-Equal ($script:Installers.Count - $before) 1 'one installer run'
    Assert-Equal (Read-WddJson $script:Paths.State).stages.windowsUpdate.launchResult 'Launched' 'recorded'
}

Test-Scenario 'Resume: a monitor task that cannot be registered is reported, not Resumed' {
    Initialize-Embedded | Out-Null
    function Register-WddMonitorTask { param([hashtable] $Paths, [hashtable] $Manifest) throw 'Access is denied. (0x80070005)' }
    $script:ResumeDetail = ''
    Assert-Equal (Invoke-WddResume $script:Paths '') 'MonitorRegistrationFailed' 'reported'
    Assert-True ($script:ResumeDetail -match '0x80070005') "reason ($($script:ResumeDetail))"
}

Test-Scenario 'initialization: a monitor task that cannot be registered ends MonitorRegistrationFailed with the reason in the state' {
    function Register-WddMonitorTask { param([hashtable] $Paths, [hashtable] $Manifest) throw 'The task XML is malformed.' }
    Assert-Equal (Initialize-Embedded) 'MonitorRegistrationFailed' 'reported'
    $st = Read-WddJson $script:Paths.State
    Assert-True ($st.message -match 'could not be registered: The task XML is malformed') "state ($($st.message))"
    Assert-Equal $st.stages.windowsUpdate.launchResult 'Launched' 'stages launched before are recorded'
}

Test-Scenario 'recovery tool Resume: a missing application task that cannot be registered again is Failed, not Done' {
    Initialize-Embedded | Out-Null
    $script:SimTasks.Remove('\WindowsDeploymentBuilder\Applications') | Out-Null
    $script:InstallerBehaviour['Install-ApplicationEngine.ps1'] = 'noTask'
    $r = Invoke-WdrRecovery $script:Manifest $script:Paths 'Resume'
    Assert-True ($r.Outcome -in 'Failed', 'Partial') "outcome $($r.Outcome): $($r.Message)"
    Assert-True ('stage:applications' -notin @($r.Accepted)) 'not counted as reopened'
    Assert-True (@($r.Refused | Where-Object { $_.operationId -eq 'stage:applications' }).Count -eq 1) 'listed as refused with the reason'
    Assert-True ($script:RecoveryExit[$r.Outcome] -ne 0) 'non-zero exit code'
    Assert-Equal (Read-WddJson $script:Paths.State).stages.applications.launchResult 'LaunchFailed' 'state is honest'
    $script:InstallerBehaviour['Install-ApplicationEngine.ps1'] = 'ok'
    $r = Invoke-WdrRecovery $script:Manifest $script:Paths 'Resume'
    Assert-Equal $r.Outcome 'Done' "recovers: $($r.Message)"
    Assert-True $script:SimTasks.ContainsKey('\WindowsDeploymentBuilder\Applications') 'task registered'
}

Test-Scenario 'another deployment in progress is not overwritten; a finished one is not restarted' {
    Initialize-Embedded | Out-Null
    $st = Read-WddJson $script:Paths.State
    $st.packageId = '0123456789ABCDEF'
    Save-WddState $script:Paths $st
    Assert-Equal (Initialize-Embedded) 'AnotherDeploymentInProgress' 'different package'
    $st.packageId = $script:Manifest.packageId; $st.status = 'Completed'
    Save-WddState $script:Paths $st
    Assert-Equal (Initialize-Embedded) 'AlreadyCompleted' 'finished'
}

# ------------------------------------------------------------------------------------------------
# Monitor: hand-off, restarts, outcomes
# ------------------------------------------------------------------------------------------------

Test-Scenario 'Windows Update hand-off: applications wait, then the deployment completes Succeeded' {
    Initialize-Embedded | Out-Null
    Set-EngineStatus 'windowsUpdate' 'Installing'
    Set-EngineStatus 'applications' 'WaitingForUpdates' 'Windows Update not final'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'InProgress' 'run 1'
    $s = Read-WddJson $script:Paths.Status
    Assert-Equal $s.currentStage 'windowsUpdate' 'current stage'
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'InProgress' 'WU done, apps not yet'
    Set-EngineStatus 'applications' 'Installing' 'Git' 1 3
    $s = Read-WddJson $script:Paths.Status
    $view = (Format-WddStatus $script:Manifest $script:Paths (Read-WddJson $script:Paths.State)).Text
    Assert-True ($view -match 'installing now: Git') 'current application shown'
    Assert-True ($view -match '1 of 3 done, 2 remaining') 'remaining shown'
    Set-EngineResult 'applications' 'Succeeded' @{ packages = @(@{ name = 'Git'; packageIdentifier = 'Git.Git'; source = 'winget'; status = 'Succeeded'; attempts = 1; exitCode = 0; message = '' }) }
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:Succeeded' 'completed'
    Assert-True (-not $script:SimTasks.ContainsKey('\WindowsDeploymentBuilder\Deployment')) 'monitor removed itself'
    Assert-Equal (Read-WddJson $script:Paths.Marker).status 'Succeeded' 'marker'
    Assert-True ($script:Events -contains 3100) 'success event'
    Assert-True $script:Shortcuts.ContainsKey('Deployment report') 'report shortcut'
    Assert-True (-not $script:Shortcuts.ContainsKey('Deployment progress')) 'progress shortcut removed'
}

Test-Scenario 'a completion marker alone is never taken as success' {
    Initialize-Embedded | Out-Null
    Write-WddJson (Join-Path $script:Paths.StateDir 'windows-update.done') @{ status = 'Succeeded' }
    Write-WddJson (Join-Path $script:Paths.StateDir 'applications.done') @{ status = 'Succeeded' }
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'InProgress' 'markers without results'
}

Test-Scenario 'restarts: state survives, the monitor resumes, pending restart is shown, nothing is relaunched' {
    Initialize-Embedded | Out-Null
    Write-WddJson $script:Paths.RestartMarker @{ owner = 'WindowsUpdate'; writtenUtc = $script:SimNow.ToString('o') }
    $snap = Get-WddSnapshot $script:Manifest $script:Paths (Read-WddJson $script:Paths.State)
    Assert-True $snap.restartPending 'restart pending visible'
    # Restart: new boot, new process; the monitor task runs at startup.
    $script:SimBoot = $script:SimNow.AddMinutes(2); $script:SimNow = $script:SimNow.AddMinutes(10)
    $snap = Get-WddSnapshot $script:Manifest $script:Paths (Read-WddJson $script:Paths.State)
    Assert-True (-not $snap.restartPending) 'marker from the previous boot ignored'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'InProgress' 'resumed'
    Assert-Equal $script:Installers.Count 2 'no stage relaunched by the monitor'
    Assert-Equal (Read-WddJson $script:Paths.State).monitorRuns 1 'monitor run recorded'
}

Test-Scenario 'outcomes: worst stage decides; offline and failed are never reported as success' {
    $cases = @(
        @('CompletedWithFailures', 'Succeeded', 'CompletedWithFailures'),
        @('Succeeded', 'CompletedWithFollowUp', 'CompletedWithFollowUp'),
        @('Offline', 'Offline', 'Incomplete'),
        @('Failed', 'Succeeded', 'Failed'),
        @('Succeeded', 'CompletedWithFailures', 'CompletedWithFailures')
    )
    foreach ($c in $cases) {
        Reset-Sim
        Initialize-Embedded | Out-Null
        Set-EngineResult 'windowsUpdate' $c[0]
        Set-EngineResult 'applications' $c[1]
        Assert-Equal (Invoke-WddMonitor $script:Paths) "Completed:$($c[2])" "$($c[0]) + $($c[1])"
        Remove-Item -LiteralPath $script:Tmp -Recurse -Force
    }
    Reset-Sim
}

Test-Scenario 'report: computer, failed KBs, application results, interaction, restarts, drivers not done' {
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'CompletedWithFailures' @{ installed = @(@{ kb = 'KB1' }, @{ kb = 'KB2' }); failed = @(@{ kbs = @('KB5034441'); title = 'Recovery update'; attempts = 3; lastResult = 'Failed'; lastHResult = '0x80070643' }); skipped = @() }
    Set-EngineResult 'applications' 'CompletedWithFollowUp' @{ packages = @(
            @{ name = 'Git'; packageIdentifier = 'Git.Git'; source = 'winget'; status = 'Succeeded'; attempts = 1; exitCode = 0; message = '' },
            @{ name = $script:Zoe; packageIdentifier = 'Example.TestPackage'; source = 'winget'; status = 'RequiresInteraction'; attempts = 1; exitCode = -1978335220; message = 'needs input' }) }
    Invoke-WddMonitor $script:Paths | Out-Null
    $r = Read-WddJson $script:Paths.ReportJson
    Assert-Equal $r.overall 'CompletedWithFailures' 'overall'
    Assert-Equal $r.system.computerName 'ALEX-COMPUTER' 'computer'
    Assert-Equal $r.windowsUpdate.failedUpdates[0].kbs[0] 'KB5034441' 'failed KB'
    Assert-Equal $r.windowsUpdate.installed 2 'installed count'
    Assert-Equal $r.applications.requiresInteraction[0] $script:Zoe 'interaction'
    Assert-Equal $r.restarts.windowsUpdate 1 'restarts'
    # Phase 8: this package has the driver stage turned off, which the report says (nothing is claimed).
    Assert-Equal $r.drivers.state 'NotPartOfDeployment' 'drivers not claimed'
    Assert-True (@($r.remainingTasks) -match 'KB5034441').Count 'remaining: KB'
    Assert-True (@($r.remainingTasks) -match 'drivers').Count 'remaining: drivers'
    $txt = Get-Content -LiteralPath $script:Paths.ReportText -Raw -Encoding UTF8
    Assert-True ($txt -match 'Overall result : CompletedWithFailures') 'text report'
    Assert-True ($txt.Contains($script:Zoe)) 'non-ASCII names survive'
    Assert-True (Test-Path -LiteralPath (Join-Path $script:Paths.Root 'Updates\result.json')) 'engine results kept'
    Assert-True (Test-Path -LiteralPath $script:Paths.State) 'state kept'
}

Test-Scenario 'stalled stage and deadline: reported as Incomplete with a recovery hint, no endless wait' {
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    $script:SimTasks.Remove('\WindowsDeploymentBuilder\Applications')   # task deleted, no result
    $script:SimNow = $script:SimNow.AddMinutes(30)
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'InProgress' 'grace period'
    $script:SimNow = $script:SimNow.AddHours(3)
    Invoke-WddMonitor $script:Paths | Out-Null
    $s = Read-WddJson $script:Paths.Status
    Assert-True (@($s.needsAttention) -match 'Stalled').Count 'stalled reported'
    $script:SimNow = $script:SimNow.AddHours(200)
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:Incomplete' 'deadline'
    $r = Read-WddJson $script:Paths.ReportJson
    Assert-True (@($r.incompleteStages) -match 'Applications').Count 'incomplete stage listed'
    Assert-True ($r.recovery -match 'Resume-Deployment.ps1') 'recovery command'
}

# ------------------------------------------------------------------------------------------------
# Orchestrator 1.2.0: reliability, restart recovery, progress window, clear messages, devices
# ------------------------------------------------------------------------------------------------

Test-Scenario 'orchestrator 1.2.0: initialization registers and checks the monitor, progress window and LAN monitor tasks' {
    Assert-Equal (Initialize-Embedded) 'Initialized' 'outcome'
    Assert-True $script:SimTasks.ContainsKey('\WindowsDeploymentBuilder\Deployment') 'monitor task'
    Assert-Equal $script:SimTasks['\WindowsDeploymentBuilder\Progress'] 'PC\Alex' 'progress window task for the deployment user'
    Assert-Equal (Get-WddMonitorInterval $script:Manifest) 5 'monitor runs every 5 minutes'
    Assert-Equal $script:Manifest.progress.refreshSeconds 7 'progress refresh declared in the manifest'
    Assert-True ([bool] $script:Manifest.monitor.enabled) 'the owner-default package enables the monitor'
    Assert-True (-not $script:Manifest.monitor.lanAccess) 'LAN access is off by default (localhost only)'
    Assert-True $script:SimTasks.ContainsKey('\WindowsDeploymentBuilder\StatusServer') 'LAN monitor task'
    Assert-True ($script:StartedTasks -contains '\WindowsDeploymentBuilder\StatusServer') 'LAN monitor started'
    Assert-True (Test-Path -LiteralPath (Join-Path $script:Paths.Package 'scripts\monitor\DeploymentStatusServer.ps1')) 'monitor script staged'
    $events = @(Read-WddActivity $script:Paths 10)
    Assert-True (@($events | Where-Object { $_.message -like 'Deployment started: 2 stage(s) scheduled*' }).Count -eq 1) 'activity: deployment started'
    $s = Read-WddJson $script:Paths.State
    Assert-Equal $s.longOperationMinutes 240 'long-operation limit recorded'
    Assert-Equal $s.lastBootUtc $script:SimBoot.ToString('o') 'boot recorded for restart detection'
}

Test-Scenario 'orchestrator 1.2.0: a stage task that cannot be registered ends InitializedWithProblems with the reason, never a plain success' {
    $script:InstallerBehaviour['Install-UpdateEngine.ps1'] = 'noTask'
    Assert-Equal (Initialize-Embedded) 'InitializedWithProblems' 'outcome'
    $s = Read-WddJson $script:Paths.State
    Assert-True ($s.message -like "Initialized, but 1 stage(s) could not be started: Windows Update*Access to the path*") "message: $($s.message)"
    Assert-True ($script:Events -contains 3002) 'event 3002'
    Assert-True $script:SimTasks.ContainsKey('\WindowsDeploymentBuilder\Deployment') 'the monitor still follows the deployment'
    Assert-True (@(Read-WddActivity $script:Paths 5 | Where-Object { $_.level -eq 'error' -and $_.message -like '*could not be started*' }).Count -eq 1) 'error in the activity feed'
}

Test-Scenario 'orchestrator 1.2.0: a helper task that cannot be registered is reported; the deployment still starts' {
    $script:HelperRegistrationFails = $true
    Assert-Equal (Initialize-Embedded) 'Initialized' 'stages and monitor are what initialization needs'
    $s = Read-WddJson $script:Paths.State
    Assert-True ($s.message -like '*helper task could not be registered*progress window task*') "message: $($s.message)"
    # The monitor registers it again once it can.
    $script:HelperRegistrationFails = $false
    Invoke-WddMonitor $script:Paths | Out-Null
    Assert-True $script:SimTasks.ContainsKey('\WindowsDeploymentBuilder\Progress') 're-registered by the monitor'
}

Test-Scenario 'restart detection: planned and unexpected restarts are recorded and shown; unfinished work is checked, nothing is relaunched' {
    Initialize-Embedded | Out-Null
    $launched = $script:Installers.Count
    Set-EngineStatus 'windowsUpdate' 'Installing' 'Installing 2 update(s)'
    Invoke-WddMonitor $script:Paths | Out-Null
    # Planned: the Windows Update engine wrote its restart marker in this boot, then Windows restarted.
    Write-WddJson $script:Paths.RestartMarker ([ordered]@{ owner = 'WindowsUpdate'; reason = 'installed updates require a restart'; requestedUtc = $script:SimNow.ToString('o'); bootTimeUtc = $script:SimBoot.ToString('yyyy-MM-ddTHH:mm:ssZ') })
    $script:SimNow = $script:SimNow.AddMinutes(5); $script:SimBoot = $script:SimNow; $script:SimNow = $script:SimNow.AddMinutes(3)
    Invoke-WddMonitor $script:Paths | Out-Null
    $s = Read-WddJson $script:Paths.State
    Assert-Equal @($s.restarts).Count 1 'one restart recorded'
    Assert-True ($s.restarts[0].planned -and $s.restarts[0].by -eq 'WindowsUpdate') 'planned by Windows Update'
    $snap = Get-WddSnapshot $script:Manifest $script:Paths $s
    Assert-True $snap.recovering 'recovering after the restart'
    Assert-Equal $snap.condition 'recovering' 'overall condition'
    Assert-True (@(Read-WddActivity $script:Paths 20 | Where-Object { $_.message -like 'Windows restarted (scheduled by WindowsUpdate: installed updates require a restart). Restoring deployment progress and checking unfinished tasks.' }).Count -eq 1) 'planned restart message'
    # Unexpected: no marker, no stage was restarting.
    Remove-Item -LiteralPath $script:Paths.RestartMarker -Force
    $script:SimNow = $script:SimNow.AddMinutes(30); $script:SimBoot = $script:SimNow; $script:SimNow = $script:SimNow.AddMinutes(3)
    Invoke-WddMonitor $script:Paths | Out-Null
    $s = Read-WddJson $script:Paths.State
    Assert-Equal @($s.restarts).Count 2 'second restart recorded'
    Assert-True (-not $s.restarts[1].planned) 'unexpected'
    Assert-True (@(Read-WddActivity $script:Paths 20 | Where-Object { $_.level -eq 'warning' -and $_.message -like 'Windows restarted unexpectedly*Restoring deployment progress and checking unfinished tasks*' }).Count -eq 1) 'unexpected restart message'
    Assert-True ($script:Events -contains 3007) 'event 3007'
    Assert-Equal $script:Installers.Count $launched 'nothing relaunched by a restart'
    $script:SimNow = $script:SimNow.AddMinutes(15)
    Assert-True (-not (Get-WddSnapshot $script:Manifest $script:Paths (Read-WddJson $script:Paths.State)).recovering) 'recovering ends'
}

Test-Scenario 'watchdog: a SYSTEM stage whose task disappeared is started again automatically, at most twice, then a technician is asked' {
    Initialize-Embedded | Out-Null
    $launched = $script:Installers.Count
    foreach ($round in 1, 2) {
        $script:SimTasks.Remove('\WindowsDeploymentBuilder\WindowsUpdate')
        $script:SimNow = $script:SimNow.AddHours(3)
        Invoke-WddMonitor $script:Paths | Out-Null
        Assert-Equal $script:Installers.Count ($launched + $round) "relaunch $round"
        Assert-True $script:SimTasks.ContainsKey('\WindowsDeploymentBuilder\WindowsUpdate') "task back after $round"
    }
    $s = Read-WddJson $script:Paths.State
    Assert-Equal $s.stages.windowsUpdate.autoRecoveries 2 'two automatic recoveries'
    Assert-Equal @($s.recoveries | Where-Object { $_.action -eq 'AutomaticRelaunch' }).Count 2 'recorded as recoveries'
    Assert-True ($script:Events -contains 3008) 'event 3008'
    # Third time: the budget is used up; no loop, a technician is asked.
    $script:SimTasks.Remove('\WindowsDeploymentBuilder\WindowsUpdate')
    $script:SimNow = $script:SimNow.AddHours(3)
    Invoke-WddMonitor $script:Paths | Out-Null
    Invoke-WddMonitor $script:Paths | Out-Null
    Assert-Equal $script:Installers.Count ($launched + 2) 'not relaunched a third time'
    Assert-Equal @(Read-WddActivity $script:Paths 50 | Where-Object { $_.message -like 'Windows Update:*Automatic recovery was already attempted 2 time(s). Technician attention required*' }).Count 1 'asked once'
    Assert-True (@((Read-WddJson $script:Paths.Status).needsAttention) -match 'Windows Update').Count 'needs attention'
}

Test-Scenario 'watchdog: the WinGet stage is never started from SYSTEM; the technician is told what to do, once' {
    Initialize-Embedded | Out-Null
    $launched = $script:Installers.Count
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    $script:SimTasks.Remove('\WindowsDeploymentBuilder\Applications')
    $script:SimNow = $script:SimNow.AddHours(3)
    Invoke-WddMonitor $script:Paths | Out-Null
    Invoke-WddMonitor $script:Paths | Out-Null
    Assert-Equal $script:Installers.Count $launched 'not relaunched'
    Assert-Equal @(Read-WddActivity $script:Paths 50 | Where-Object { $_.level -eq 'error' -and $_.message -like 'Applications (WinGet):*must be restarted by PC\Alex*Resume-Deployment.ps1 -RestartStage applications*' }).Count 1 'told once'
}

Test-Scenario 'stale detection: long Windows Update phases get the longer limit, never while Windows is servicing; a stopped task is started again' {
    Initialize-Embedded | Out-Null
    $wuTask = '\WindowsDeploymentBuilder\WindowsUpdate'
    Set-EngineStatus 'windowsUpdate' 'Installing' 'Installing 3 update(s)'
    $script:SimNow = $script:SimNow.AddMinutes(130)
    $wu = @((Get-WddSnapshot $script:Manifest $script:Paths (Read-WddJson $script:Paths.State)).stages | Where-Object { $_.id -eq 'windowsUpdate' })[0]
    Assert-True (-not $wu.stale) 'installing for 130 minutes is not stalled (limit 240)'
    Assert-Equal $wu.condition 'active' 'active'
    $script:SimNow = $script:SimNow.AddMinutes(120)
    $script:SimServicing = $true
    $wu = @((Get-WddSnapshot $script:Manifest $script:Paths (Read-WddJson $script:Paths.State)).stages | Where-Object { $_.id -eq 'windowsUpdate' })[0]
    Assert-True (-not $wu.stale) 'not stalled while Windows is servicing'
    Assert-True ($wu.activity -like '*Windows is still installing updates, so this is not treated as stalled.') "activity: $($wu.activity)"
    $script:SimServicing = $false
    $snap = Get-WddSnapshot $script:Manifest $script:Paths (Read-WddJson $script:Paths.State)
    $wu = @($snap.stages | Where-Object { $_.id -eq 'windowsUpdate' })[0]
    Assert-True $wu.stale 'stalled after 250 minutes'
    Assert-True ($wu.activity -like 'No progress detected for 250 minutes (limit 240).*') "activity: $($wu.activity)"
    Assert-True (@($snap.needsAttention) -match 'No progress detected').Count 'needs attention'
    Assert-Equal $snap.condition 'attention' 'overall condition'
    # Task still running: report only.
    $script:SimTaskStates[$wuTask] = 'Running'
    Invoke-WddMonitor $script:Paths | Out-Null
    Assert-True (-not ($script:StartedTasks -contains $wuTask)) 'a running task is not started again'
    Assert-True (@(Read-WddActivity $script:Paths 30 | Where-Object { $_.message -like '*while its task is still running*' }).Count -eq 1) 'reported'
    # Task stopped with an error: started again once.
    $script:SimTaskStates[$wuTask] = 'Ready'; $script:SimTaskResults[$wuTask] = 1
    Invoke-WddMonitor $script:Paths | Out-Null
    Assert-True ($script:StartedTasks -contains $wuTask) 'task started again'
    $s = Read-WddJson $script:Paths.State
    Assert-Equal @($s.recoveries | Where-Object { $_.action -eq 'AutomaticStartTask' }).Count 1 'recorded'
}

Test-Scenario 'clear messages: waiting, retries and failures reported by the engines reach the snapshot and the activity feed' {
    Initialize-Embedded | Out-Null
    Write-WddJson (Join-Path $script:Paths.Root 'Updates\status.json') @{ phase = 'WaitingForInstaller'; detail = 'Windows is already installing updates (for example its own automatic updates); waiting for it to finish.'; updatedUtc = $script:SimNow.AddMinutes(-2).ToString('o'); reboots = 0 }
    $snap = Get-WddSnapshot $script:Manifest $script:Paths (Read-WddJson $script:Paths.State)
    $wu = @($snap.stages | Where-Object { $_.id -eq 'windowsUpdate' })[0]
    Assert-Equal $wu.condition 'waiting' 'waiting'
    Assert-True ($wu.activity -like 'Waiting for Windows Update to finish.*Last activity: 2 minutes ago.') "activity: $($wu.activity)"
    Assert-True ($snap.outcomeDetail -like 'Windows Update: Waiting for Windows Update to finish.*') "outcome detail: $($snap.outcomeDetail)"
    Assert-True ($snap.outcomeDetail -notlike '*Stages are starting*') 'no vague message'
    Write-WddJson (Join-Path $script:Paths.Root 'Updates\status.json') @{ phase = 'Downloading'; detail = 'Downloading KB5000002 Update, update 2 of 3, attempt 1 of 3. Progress unavailable.'; updatedUtc = $script:SimNow.ToString('o'); reboots = 0
        current = 'KB5000002 Update'; attempt = 1; maxAttempts = 3; lastError = 'Unable to download KB5000001 Update: 0x8024402C WU_E_PT_WINHTTP_NAME_NOT_RESOLVED (the update server name could not be resolved). Attempt 2 of 3; retrying in 240 s. Other operations will continue where possible.'; lastErrorUtc = $script:SimNow.ToString('o') }
    $wu = @((Get-WddSnapshot $script:Manifest $script:Paths (Read-WddJson $script:Paths.State)).stages | Where-Object { $_.id -eq 'windowsUpdate' })[0]
    Assert-Equal $wu.condition 'active' 'downloading is active'
    Assert-True ($wu.lastError -like 'Unable to download KB5000001*Attempt 2 of 3*') 'last error'
    Assert-Equal $wu.counts.attempt 1 'attempt'
    # Engines append to the same feed; a line being written is skipped.
    Add-WdbActivity $script:Paths.Root 'applications' 'App Spotify could not be installed (installer failed). The failure was recorded; deployment is continuing with the remaining applications.' 'warning'
    [IO.File]::AppendAllText($script:Paths.Activity, '{"utc":"2026-10-20T08:')
    $feed = @(Read-WddActivity $script:Paths 10)
    Assert-True (@($feed | Where-Object { $_.source -eq 'applications' -and $_.message -like '*deployment is continuing with the remaining applications.' }).Count -eq 1) 'engine message in the feed'
    Assert-True ($feed.Count -ge 2) 'the partial line does not hide the others'
    Assert-True ($feed[0] -is [hashtable]) 'events are returned one by one'
    # The next event is not swallowed by the unfinished line.
    Add-WddActivity $script:Paths 'After the partial line.'
    Assert-Equal (@(Read-WddActivity $script:Paths 1)[0].message) 'After the partial line.' 'next event readable'
}

Test-Scenario 'completion: Device Manager problems with hardware IDs; a USB descriptor failure is a connection problem; follow-up; progress task removed' {
    Initialize-Embedded | Out-Null
    $script:SimDevices = @(
        @{ name = 'PCI Simple Communications Controller'; class = ''; problemCode = 28; hardwareIds = @('PCI\VEN_8086&DEV_A2BA&SUBSYS_86941043', 'PCI\VEN_8086&DEV_A2BA') },
        @{ name = 'Unknown USB Device (Device Descriptor Request Failed)'; class = 'USB'; problemCode = 43; hardwareIds = @('USB\DEVICE_DESCRIPTOR_FAILURE') },
        @{ name = 'Intel(R) Ethernet Connection I219-V'; class = 'Net'; problemCode = 0; hardwareIds = @('PCI\VEN_8086&DEV_15B8') },
        @{ name = 'Disabled on purpose'; class = 'Media'; problemCode = 22; hardwareIds = @() })
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Set-EngineResult 'applications' 'Succeeded'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFollowUp' 'unresolved devices make it a follow-up'
    $r = Read-WddJson $script:Paths.ReportJson
    Assert-Equal $r.devices.devices 4 'devices checked'
    Assert-Equal (@($r.devices.unresolved | ForEach-Object { $_.kind }) -join ',') 'NoDriver,HardwareOrConnection' 'kinds (working and disabled devices are not listed)'
    Assert-Equal $r.devices.unresolved[0].hardwareIds[0] 'PCI\VEN_8086&DEV_A2BA&SUBSYS_86941043' 'hardware ID'
    Assert-True ($r.devices.unresolved[1].note -like '*hardware, cable, hub or port problem, not a missing driver*') 'USB descriptor note'
    $text = Get-Content -LiteralPath $script:Paths.ReportText -Raw
    Assert-True ($text -match 'Device Manager \(at the end of the deployment\)' -and $text -match 'hardware ID: PCI\\VEN_8086&DEV_A2BA') 'text report section'
    Assert-True (@($r.remainingTasks) -match '^Device: PCI Simple Communications Controller').Count 'listed as remaining task'
    Assert-True (-not $script:SimTasks.ContainsKey('\WindowsDeploymentBuilder\Progress')) 'progress window no longer opens at sign-in'
    Assert-True (@(Read-WddActivity $script:Paths 10 | Where-Object { $_.message -like 'Deployment finished: CompletedWithFollowUp.*2 device(s) need attention.*' }).Count -eq 1) 'final activity'
}

Test-Scenario 'completion: the device list cannot be read: reported, never a silent success' {
    Initialize-Embedded | Out-Null
    $script:SimDevicesThrow = $true
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Set-EngineResult 'applications' 'Succeeded'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFollowUp' 'outcome'
    $r = Read-WddJson $script:Paths.ReportJson
    Assert-True (-not $r.devices.checked) 'not checked'
    Assert-True (@($r.remainingTasks) -match '^Device Manager: The device list could not be read').Count 'follow-up'
}

Test-Scenario 'report: how each application was confirmed; Windows Update optional updates, drivers and updates needing a person' {
    Initialize-Embedded | Out-Null
    $pk = @(
        @{ name = 'Git'; packageIdentifier = 'Git.Git'; source = 'winget'; status = 'Succeeded'; detection = 'Installed'; attempts = 1; exitCode = '0x00000000'; message = 'Installed.' },
        @{ name = 'VLC'; packageIdentifier = 'VideoLAN.VLC'; source = 'winget'; status = 'Succeeded'; detection = 'Unconfirmed'; attempts = 1; exitCode = '0x00000000'; message = 'WinGet reported success, but winget list does not show the package; verify it manually.' },
        @{ name = 'Old engine result'; packageIdentifier = 'Example.Old'; source = 'winget'; status = 'Succeeded'; attempts = 1; exitCode = '0x00000000'; message = 'Installed.' },
        @{ name = 'Spotify'; packageIdentifier = 'Spotify.Spotify'; source = 'winget'; status = 'Failed'; attempts = 3; exitCode = '0x8A150006'; installerExitCode = '53'; message = 'The installer reported a failure (SHELLEXEC_INSTALL_FAILED). Installer exit code: 53.' },
        @{ name = 'Battle.net'; packageIdentifier = 'Blizzard.BattleNet'; source = 'winget'; status = 'RequiresInteraction'; attempts = 1; exitCode = 'timeout'; message = 'Did not finish within 30 min; this installer may wait for a person. Install it manually.' })
    Set-EngineResult 'windowsUpdate' 'CompletedWithFollowUp' @{ installed = @(@{ kbs = @('KB1') }, @{ kbs = @('KB2') }, @{ kbs = @('KB3') }); failed = @(); skipped = @()
        requiresInteraction = @(@{ kbs = @('KB5099999'); title = 'Example update'; reason = 'gave up: Windows reported that it needs a signed-in person to install it' })
        counts = @{ installed = 3; installedOptional = 2; installedDrivers = 1; failed = 0; requiresInteraction = 1; skipped = 0 } }
    Set-EngineResult 'applications' 'CompletedWithFailures' @{ packages = $pk }
    Invoke-WddMonitor $script:Paths | Out-Null
    $r = Read-WddJson $script:Paths.ReportJson
    Assert-Equal (@($r.applications.packages | ForEach-Object { $_.verification }) -join ',') 'Verified,NotVerified,EngineReported,Failed,Deferred' 'verification per application'
    Assert-Equal $r.applications.verification.Verified 1 'counts'
    Assert-Equal $r.applications.packages[3].installerExitCode '53' 'installer exit code kept'
    Assert-Equal "$($r.windowsUpdate.installedOptional)/$($r.windowsUpdate.installedDrivers)" '2/1' 'optional updates and drivers'
    Assert-True (@($r.remainingTasks) -match 'KB5099999.*needs a person').Count 'update needing a person is a follow-up'
    Assert-True (@($r.remainingTasks) -match '^Application VLC: reported installed, but WinGet does not find').Count 'not-verified install is a follow-up'
    $text = Get-Content -LiteralPath $script:Paths.ReportText -Raw
    Assert-True ($text -match 'Of these: optional updates 2, drivers 1' -and $text -match '<NotVerified>' -and $text -match 'Confirmation: Verified 1') 'text report'
}

Test-Scenario 'progress window: one per session, refreshes every 7 seconds, opens automatically only while the deployment runs, shows the monitor address' {
    $script:ProgressMutexName = "Local\WDD-Progress-Test-$([guid]::NewGuid().ToString('N'))"
    $first = Enter-WddProgressWindow
    Assert-True $first 'first window'
    $ps = [powershell]::Create()
    [void] $ps.AddScript("`$m = New-Object System.Threading.Mutex(`$false, '$($script:ProgressMutexName)'); `$m.WaitOne(0)")
    Assert-Equal (@($ps.Invoke())[0]) $false 'a second window (another thread) is refused'
    $ps.Dispose()
    $first.ReleaseMutex(); $first.Dispose()
    $t = $null; $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $pkgScripts 'orchestrator\Show-DeploymentStatus.ps1'), [ref] $t, [ref] $e)
    $interval = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'IntervalSeconds' })[0]
    Assert-Equal $interval.DefaultValue.Extent.Text '7' 'refresh interval default'
    Assert-True (-not (Test-WddShowAutomatically @{ status = 'Completed' })) 'not opened after completion'
    Assert-True (-not (Test-WddShowAutomatically $null)) 'not opened before a deployment'
    Assert-True (Test-WddShowAutomatically @{ status = 'InProgress' }) 'opened while running'
    Initialize-Embedded | Out-Null
    $text = (Format-WddStatus $script:Manifest $script:Paths (Read-WddJson $script:Paths.State)).Text
    Assert-True ($text -match 'Monitor        : starting') 'monitor starting'
    Assert-True ($text -match 'Last activity  : ') 'last activity line'
    Write-WddJson $script:Paths.MonitorInfo ([ordered]@{ port = 8765; lanAccess = $false; token = ('A' * 43); mode = 'serving'; urls = @('http://127.0.0.1:8765'); message = '' })
    $text = (Format-WddStatus $script:Manifest $script:Paths (Read-WddJson $script:Paths.State)).Text
    Assert-True ($text -match [regex]::Escape("Monitor        : http://127.0.0.1:8765/#t=$('A' * 43)  (this computer only)")) 'address with token'
    Assert-True ($text -match 'Recent activity') 'recent activity section'
}

# ------------------------------------------------------------------------------------------------
# Orchestrator 1.3.0: final-state reconciliation (exit code 40), restart coordination, update re-check
# ------------------------------------------------------------------------------------------------

Test-Scenario 'exit code 40 (bare-metal run): every stage final but not finished is never "starting"; the monitor finishes it; an overdue monitor is flagged' {
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'CompletedWithFailures' @{ failed = @(@{ kbs = @('KB890830'); title = 'Windows Malicious Software Removal Tool'; attempts = 3; lastResult = 'Failed'; lastHResult = '0x80131508' }) }
    Set-EngineResult 'applications' 'CompletedWithFailures' @{ packages = @(@{ name = 'Google Chrome'; packageIdentifier = 'Google.Chrome'; source = 'winget'; status = 'Failed'; attempts = 2; exitCode = '0x8A150011'; message = 'Installer hash mismatch' }) }
    $st = Read-WddJson $script:Paths.State
    $snap = Get-WddSnapshot $script:Manifest $script:Paths $st
    Assert-Equal "$($snap.allFinal) $($snap.finalizing) $($snap.outcomeCode)" 'True True 40' 'still in progress until the monitor has finished it'
    Assert-True ($snap.outcomeDetail -like 'Every stage has finished (Windows Update: CompletedWithFailures; Applications*: CompletedWithFailures)*final report*') "detail: $($snap.outcomeDetail)"
    Assert-True ($snap.outcomeDetail -notmatch '(?i)starting|launching|no engine has reported') 'never reported as starting'
    $view = (Format-WddStatus $script:Manifest $script:Paths $st).Text
    Assert-True ($view -notmatch 'Stages are starting') 'progress window'
    # The monitor did not run for 30 minutes although Windows was running: flagged for a technician.
    $script:SimBoot = $script:SimNow.AddMinutes(-60); $script:SimNow = $script:SimNow.AddMinutes(30)
    $snap = Get-WddSnapshot $script:Manifest $script:Paths $st
    Assert-Equal "$($snap.monitorOverdue) $($snap.outcome) $($snap.outcomeCode) $($snap.condition)" 'True PausedAwaitingUser 32 attention' 'overdue monitor'
    Assert-True (@($snap.needsAttention) -match '^Deployment monitor: it has not run').Count 'needs attention'
    Assert-True ((Format-WddStatus $script:Manifest $script:Paths $st).Text -match 'Monitor checks : .*OVERDUE') 'progress window shows it'
    # The monitor runs: the stage results are reconciled into the final outcome.
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFailures' 'finished'
    $snap = Get-WddSnapshot $script:Manifest $script:Paths (Read-WddJson $script:Paths.State)
    Assert-Equal "$($snap.outcome) $($snap.outcomeCode) $($snap.monitorOverdue)" 'CompletedWithFailures 20 False' 'final outcome'
    $r = Read-WddJson $script:Paths.ReportJson
    Assert-Equal "$($r.outcome) $($r.outcomeCode)" 'CompletedWithFailures 20' 'report matches the state'
}

Test-Scenario 'finalization failure: logged and retried at the next run; after three failures a minimal report ends the deployment' {
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Set-EngineResult 'applications' 'Succeeded'
    function New-WddReport { throw 'Simulated report failure' }
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'FinalizeFailed' 'run 1'
    $s = Read-WddJson $script:Paths.Status
    Assert-True ($s.outcomeDetail -match 'writing the final report failed: Simulated report failure') "status: $($s.outcomeDetail)"
    Assert-Equal "$((Read-WddJson $script:Paths.State).status) $((Read-WddJson $script:Paths.State).finalizeFailures)" 'InProgress 1' 'not finished yet'
    Assert-True (@(Read-WddActivity $script:Paths 10 | Where-Object { $_.level -eq 'error' -and $_.message -like 'Writing the final report failed (attempt 1 of 3)*' }).Count -eq 1) 'activity'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'FinalizeFailed' 'run 2'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFollowUp' 'run 3: minimal report, never a silent success'
    $r = Read-WddJson $script:Paths.ReportJson
    Assert-True ($r.minimal -and $r.reason -match 'could not be written after 3 attempts \(Simulated report failure') 'minimal report with the error'
    Assert-Equal @($r.stages).Count 2 'stage results listed'
    Assert-Equal (Read-WddJson $script:Paths.State).status 'Completed' 'deployment ended'
    Assert-True ($script:Events -contains 3105) 'event 3105'
    Assert-True (-not $script:SimTasks.ContainsKey('\WindowsDeploymentBuilder\Deployment')) 'monitor task removed'
}

Test-Scenario 'restart coordination: every stage final but Windows needs a restart: announced, restarted once under the install lock, devices and updates re-checked after the boot, then finished' {
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Set-EngineResult 'applications' 'Succeeded'
    $script:SimServicingRestart = @('Windows Update reports that a restart is required to finish installed updates')
    $script:SimDevices = @(@{ name = 'Intel(R) SM Bus Controller'; class = 'System'; problemCode = 14; hardwareIds = @('PCI\VEN_8086&DEV_A323') })
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'WaitingForRestart' 'run 1: announced, not finished'
    $s = Read-WddJson $script:Paths.Status
    Assert-Equal "$($s.outcome) $($s.outcomeCode) $($s.restart.status) $($s.condition)" 'PausedAwaitingReboot 31 Announced waiting' 'paused for the restart'
    Assert-True ($s.outcomeDetail -match 'Every stage has finished .*Windows needs a restart: Windows Update reports .*1 device\(s\) need a restart .*Intel\(R\) SM Bus Controller') "detail: $($s.outcomeDetail)"
    Assert-Equal $script:SimRestarts.Count 0 'never on the first sighting'
    Assert-True ((Format-WddStatus $script:Manifest $script:Paths (Read-WddJson $script:Paths.State)).Text -match 'Restart        : Announced') 'progress window'
    $script:SimNow = $script:SimNow.AddMinutes(5)
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'WaitingForRestart' 'run 2: restarting'
    Assert-Equal $script:SimRestarts.Count 1 'restart requested'
    $m = Read-WddJson $script:Paths.RestartMarker
    Assert-Equal "$($m.owner) $($m.bootTimeUtc)" "Deployment $($script:SimBoot.ToString('yyyy-MM-ddTHH:mm:ssZ'))" 'restart marker in the engines'' format'
    $st = Read-WddJson $script:Paths.State
    Assert-Equal "$($st.restartCoordinator.status) $($st.restartCoordinator.restarts)" 'Restarting 1' 'saved before restarting'
    Assert-True ($script:Events -contains 3009) 'event 3009'
    Assert-True ($script:SimRestartWaits -ge 180) 'the install lock was held through the warning'
    $l = Enter-WddInstallLock $script:Paths; Assert-True $l 'lock released afterwards'; Exit-WddInstallLock $l
    $script:SimNow = $script:SimNow.AddMinutes(1)
    [void] (Invoke-WddMonitor $script:Paths)
    Assert-Equal $script:SimRestarts.Count 1 'never a second restart in the same boot'
    # The restart: the driver works now.
    Invoke-SimBoot
    $script:SimDevices = @(@{ name = 'Intel(R) SM Bus Controller'; class = 'System'; problemCode = 0; hardwareIds = @('PCI\VEN_8086&DEV_A323') })
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:Succeeded' 'finished after the restart'
    $st = Read-WddJson $script:Paths.State
    Assert-True ($st.restarts[-1].planned -and $st.restarts[-1].by -eq 'Deployment') 'the boot is recognised as the planned restart'
    $r = Read-WddJson $script:Paths.ReportJson
    Assert-Equal "$($r.restartCoordination.outstanding) $($r.restartCoordination.automaticRestarts) $(@($r.restartCoordination.history).Count)" 'False 1 1' 'restart in the report'
    Assert-Equal "$(@($r.devices.unresolved).Count) $($r.devices.bootUtc)" "0 $($script:SimBoot.ToString('o'))" 'devices checked after the restart'
    Assert-Equal "$($r.updateRecheck.status) $script:SimOfferedCalls" 'NothingOffered 1' 'Windows Update searched again'
    Assert-True ((Get-Content -LiteralPath $script:Paths.ReportText -Raw) -match 'automatic restart 1: Windows Update reports') 'text report'
}

Test-Scenario 'restart coordination: never while something installs (a working stage, the Windows Update installer, MSI, the install lock); it waits, then restarts' {
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Set-EngineStatus 'applications' 'Installing' 'Git'
    $script:SimServicingRestart = @('Windows component servicing has a pending restart')
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'InProgress' 'run 1'
    Assert-Equal (Read-WddJson $script:Paths.State).restartCoordinator.status 'Announced' 'announced'
    $script:SimNow = $script:SimNow.AddMinutes(5); Set-EngineStatus 'applications' 'Installing' 'Git'
    [void] (Invoke-WddMonitor $script:Paths)
    $rc = (Read-WddJson $script:Paths.State).restartCoordinator
    Assert-True ($rc.status -eq 'Blocked' -and (@($rc.blockers) -join ';') -match 'Applications.* is working \(Installing\)') "blocked by the installing stage: $(@($rc.blockers) -join ';')"
    Assert-True (@(Read-WddActivity $script:Paths 20 | Where-Object { $_.level -eq 'warning' -and $_.message -like 'A restart is needed but waits:*is working (Installing)*' }).Count -eq 1) 'activity'
    $script:SimNow = $script:SimNow.AddMinutes(5); Set-EngineStatus 'applications' 'WaitingForNetwork' 'no network'
    $script:SimInstallerActive = 'a Windows Installer (MSI) installation is running'
    [void] (Invoke-WddMonitor $script:Paths)
    Assert-True ((@((Read-WddJson $script:Paths.State).restartCoordinator.blockers) -join ';') -match 'MSI') 'blocked by an MSI installation'
    $script:SimInstallerActive = ''
    $held = Enter-WddInstallLock $script:Paths
    try {
        $script:SimNow = $script:SimNow.AddMinutes(5); Set-EngineStatus 'applications' 'WaitingForNetwork' 'no network'
        [void] (Invoke-WddMonitor $script:Paths)
        Assert-True ((@((Read-WddJson $script:Paths.State).restartCoordinator.blockers) -join ';') -match 'install lock') 'blocked by the install lock'
    } finally { Exit-WddInstallLock $held }
    Assert-Equal $script:SimRestarts.Count 0 'nothing restarted while anything installed'
    $script:SimNow = $script:SimNow.AddMinutes(5); Set-EngineStatus 'applications' 'WaitingForNetwork' 'no network'
    [void] (Invoke-WddMonitor $script:Paths)
    Assert-Equal $script:SimRestarts.Count 1 'restarted once nothing was installing'
}

Test-Scenario 'restart-loop protection: a restart Windows keeps asking for is done at most three times, never twice in one boot, then reported' {
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Set-EngineResult 'applications' 'Succeeded'
    $pending = @('Windows component servicing has a pending restart')
    $script:SimServicingRestart = $pending
    for ($i = 1; $i -le 3; $i++) {
        Assert-Equal (Invoke-WddMonitor $script:Paths) 'WaitingForRestart' "cycle $i announce"
        $script:SimNow = $script:SimNow.AddMinutes(5)
        [void] (Invoke-WddMonitor $script:Paths)
        Assert-Equal $script:SimRestarts.Count $i "cycle $i restart"
        Invoke-SimBoot
        $script:SimServicingRestart = $pending   # Windows still asks for a restart after the boot
    }
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFollowUp' 'limit reached: finished with a follow-up'
    Assert-Equal $script:SimRestarts.Count 3 'no fourth restart'
    Assert-True ($script:Events -contains 3010) 'event 3010'
    $r = Read-WddJson $script:Paths.ReportJson
    Assert-Equal "$($r.restartCoordination.status) $($r.restartCoordination.outstanding)" 'LimitReached True' 'reported'
    Assert-True (@($r.remainingTasks) -match '^Restart: Windows still needs a restart .*automatic restart limit').Count 'what to do'
}

Test-Scenario 'restart coordination: a restart that cannot be started is reported (marker removed), the deployment finishes with a follow-up' {
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Set-EngineResult 'applications' 'Succeeded'
    $script:SimServicingRestart = @('Windows component servicing has a pending restart')
    $script:SimRestartThrows = $true
    [void] (Invoke-WddMonitor $script:Paths)
    $script:SimNow = $script:SimNow.AddMinutes(5)
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFollowUp' 'finished, with the restart outstanding'
    Assert-True (-not (Test-Path -LiteralPath $script:Paths.RestartMarker)) 'no marker left that would stop the engines'
    Assert-True (@(Read-WddActivity $script:Paths 20 | Where-Object { $_.level -eq 'error' -and $_.message -like 'The automatic restart could not be started: shutdown.exe failed*' }).Count -eq 1) 'activity'
    Assert-True (@((Read-WddJson $script:Paths.ReportJson).remainingTasks) -match '^Restart: Windows still needs a restart').Count 'follow-up'
}

Test-Scenario 'restart reasons: applications that need a restart and devices with code 14 count; other device problems do not' {
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Set-EngineResult 'applications' 'CompletedWithFollowUp' @{ packages = @(@{ name = 'Visual C++ Redistributable'; packageIdentifier = 'Microsoft.VCRedist.2015+.x64'; source = 'winget'; status = 'RequiresRestart'; attempts = 1; exitCode = '0x00000BC2'; message = '3010' }) }
    $script:SimDevices = @(@{ name = 'PCI Memory Controller'; class = ''; problemCode = 28; hardwareIds = @('PCI\VEN_8086&DEV_A2A1') })
    $need = Get-WddRestartNeed (Get-WddSnapshot $script:Manifest $script:Paths (Read-WddJson $script:Paths.State))
    Assert-Equal "$($need.Required) $(@($need.Reasons).Count)" 'True 1' 'one reason'
    Assert-True ($need.Reasons[0] -like '1 application(s) need a restart to finish (Visual C++ Redistributable)') $need.Reasons[0]
    $script:SimDevices = @()
    Set-EngineResult 'applications' 'Succeeded'
    Assert-True (-not (Get-WddRestartNeed (Get-WddSnapshot $script:Manifest $script:Paths (Read-WddJson $script:Paths.State))).Required) 'nothing needs a restart'
}

Test-Scenario 'Windows Update re-check: updates offered after the stage finished get one more run; what is still offered afterwards is reported, never hidden' {
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Set-EngineResult 'applications' 'Succeeded'
    $script:SimOffered = @(@{ id = 'u1'; title = '2026-11 Cumulative Update Preview'; kbs = @('KB5099999'); optional = $true; driver = $false })
    $n = $script:Installers.Count
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'InProgress' 'Windows Update runs once more'
    Assert-Equal "$($script:Installers.Count) $($script:Installers[-1])" "$($n + 1) Install-UpdateEngine.ps1" 'its stage was launched again'
    $st = Read-WddJson $script:Paths.State
    Assert-Equal "$($st.updateRecheck.status) $($st.updateRecheck.relaunches)" 'Relaunched 1' 'recorded'
    Assert-True (@(Read-WddActivity $script:Paths 10 | Where-Object { $_.message -like 'Windows Update offers 1 more update(s) (KB5099999 2026-11 Cumulative Update Preview); the Windows Update stage runs once more (1 of 1).' }).Count -eq 1) 'activity'
    $script:SimNow = $script:SimNow.AddMinutes(40)
    Set-EngineResult 'windowsUpdate' 'CompletedWithFailures'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFailures' 'finished'
    Assert-Equal $script:Installers.Count ($n + 1) 'never a second extra run'
    $r = Read-WddJson $script:Paths.ReportJson
    Assert-Equal $r.updateRecheck.status 'Remaining' 'remaining'
    Assert-True (@($r.remainingTasks) -match '^Windows Update: KB5099999 2026-11 Cumulative Update Preview is still offered').Count 'listed for the technician'
}

Test-Scenario 'Windows Update re-check that cannot search is a follow-up, never a silent success' {
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Set-EngineResult 'applications' 'Succeeded'
    $script:SimOfferedThrows = $true
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFollowUp' 'follow-up'
    Assert-True (@((Read-WddJson $script:Paths.ReportJson).remainingTasks) -match '^Windows Update: Windows Update could not be searched again').Count 'reported'
}

Test-Scenario 'progress window without elevation: SYSTEM tasks it cannot see are never reported missing; the monitor''s own finding is shown' {
    Initialize-Embedded | Out-Null
    Set-EngineStatus 'windowsUpdate' 'Installing' 'Installing 2 update(s)'
    [void] $script:SimTasks.Remove('\WindowsDeploymentBuilder\WindowsUpdate')   # what a filtered token sees
    $script:SimNow = $script:SimNow.AddMinutes(180); Set-EngineStatus 'windowsUpdate' 'Installing' 'Installing 2 update(s)'
    $script:SimIdentity = @{ Name = 'PC\Alex'; IsSystem = $false; IsAdmin = $false }
    Assert-Equal (Get-WddTaskVisibility) 'Limited' 'non-elevated'
    $script:WddTaskVisibility = 'Limited'
    $st = Read-WddJson $script:Paths.State
    $st.lastMonitorUtc = $script:SimNow.AddMinutes(-3).ToString('o')   # the monitor itself runs normally
    $snap = Get-WddSnapshot $script:Manifest $script:Paths $st
    $wu = @($snap.stages | Where-Object { $_.id -eq 'windowsUpdate' })[0]
    Assert-Equal $wu.state 'Running' 'not Stalled'
    Assert-Equal @($snap.needsAttention).Count 0 'no false warning'
    Assert-True ((Format-WddStatus $script:Manifest $script:Paths $st).Text -match 'Task view      : this window runs without administrator rights') 'explained in the window'
    # The SYSTEM monitor (full view) finds the task really gone: its finding is shown.
    $script:WddTaskVisibility = 'Full'
    Write-WddJson $script:Paths.Status (Get-WddSnapshot $script:Manifest $script:Paths $st)
    $script:WddTaskVisibility = 'Limited'
    $wu = @((Get-WddSnapshot $script:Manifest $script:Paths $st).stages | Where-Object { $_.id -eq 'windowsUpdate' })[0]
    Assert-True ($wu.state -eq 'Stalled' -and $wu.detail -like '*(reported by the deployment monitor)') "monitor's view: $($wu.state) $($wu.detail)"
    $script:SimIdentity = @{ Name = 'NT AUTHORITY\SYSTEM'; IsSystem = $true; IsAdmin = $true }
    Assert-Equal (Get-WddTaskVisibility) 'Full' 'SYSTEM sees every task'
}

Test-Scenario 'devices: chipset and graphics hints name the official source by vendor; a generic display driver is a follow-up; USB descriptor failures get no driver hint' {
    Initialize-Embedded | Out-Null
    $script:SimDevices = @(
        @{ name = 'SM Bus Controller'; class = ''; problemCode = 28; hardwareIds = @('PCI\VEN_8086&DEV_A323&SUBSYS_86941043') },
        @{ name = 'PCI Memory Controller'; class = ''; problemCode = 28; hardwareIds = @('PCI\VEN_1022&DEV_1649') },
        @{ name = 'Microsoft Basic Display Adapter'; class = 'Display'; problemCode = 0; hardwareIds = @('PCI\VEN_10DE&DEV_2484') },
        @{ name = 'Unknown USB Device (Device Descriptor Request Failed)'; class = 'USB'; problemCode = 43; hardwareIds = @('USB\DEVICE_DESCRIPTOR_FAILURE') })
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Set-EngineResult 'applications' 'Succeeded'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFollowUp' 'follow-up'
    $u = @((Read-WddJson $script:Paths.ReportJson).devices.unresolved)
    Assert-Equal (($u | ForEach-Object { "$($_.kind)/$($_.vendor)" }) -join ',') 'NoDriver/Intel,NoDriver/AMD,GenericDriver/NVIDIA,HardwareOrConnection/' 'kinds and vendors'
    Assert-True ($u[0].driverSource -match 'Intel Chipset Device Software') 'Intel chipset'
    Assert-True ($u[1].driverSource -match 'AMD Chipset Software') 'AMD chipset'
    Assert-True ($u[2].driverSource -match 'nvidia\.com/drivers') 'NVIDIA graphics'
    Assert-Equal "$($u[3].driverSource)" '' 'no driver hint for a USB descriptor failure'
}

Test-Scenario 'integrity: a modified staged script stops the monitor; nothing is completed or run' {
    Initialize-Embedded | Out-Null
    Add-Content -LiteralPath (Join-Path $script:Paths.Package 'scripts\finalization\Complete-Deployment.ps1') -Value '# tampered'
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Set-EngineResult 'applications' 'Succeeded'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'IntegrityFailed' 'stopped'
    Assert-True (-not (Test-Path -LiteralPath $script:Paths.Marker)) 'no completion marker'
    Assert-True ($script:Events -contains 3003) 'event'
    Assert-Equal (Invoke-WddResume $script:Paths '') 'IntegrityFailed' 'resume refuses too'
    # Recovery: setup.cmd from the original package re-stages; nothing is launched twice.
    Assert-Equal (Invoke-WddInitialize $script:Manifest $manifestPath 'Package' $pkgRoot '' $script:Paths -NoConsole) 'Initialized' 're-staged from the package'
    Assert-True (Test-WddFiles $script:Paths.Package $script:Manifest 'Text' (Read-WddJson $script:Paths.State).stagedFiles).Ok 'staged copy valid again'
    Assert-Equal $script:Installers.Count 2 'no stage relaunched'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:Succeeded' 'deployment completes'
}

Test-Scenario 'manual recovery: resume reopens after the deadline; -RestartStage relaunches only that stage' {
    Initialize-Embedded | Out-Null
    $script:SimNow = $script:SimNow.AddHours(500)
    Invoke-WddMonitor $script:Paths | Out-Null
    Assert-Equal (Read-WddJson $script:Paths.State).status 'Completed' 'ended by deadline'
    Assert-Equal (Invoke-WddResume $script:Paths '') 'Resumed' 'resume'
    $st = Read-WddJson $script:Paths.State
    Assert-Equal $st.status 'InProgress' 'reopened'
    Assert-True (-not (Test-Path -LiteralPath $script:Paths.Marker)) 'old marker set aside'
    Assert-True $script:SimTasks.ContainsKey('\WindowsDeploymentBuilder\Deployment') 'monitor registered again'
    Assert-Equal $script:Installers.Count 2 'plain resume relaunches nothing'
    Assert-Equal (Invoke-WddResume $script:Paths 'applications') 'Resumed' 'restart stage'
    Assert-Equal ($script:Installers -join ',') 'Install-UpdateEngine.ps1,Install-ApplicationEngine.ps1,Install-ApplicationEngine.ps1' 'only applications relaunched'
}

Test-Scenario 'offline target: stages end Offline, the deployment ends Incomplete with the stages listed' {
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'Offline'
    Set-EngineResult 'applications' 'Offline'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:Incomplete' 'offline'
    $r = Read-WddJson $script:Paths.ReportJson
    Assert-Equal @($r.incompleteStages).Count 2 'both stages incomplete'
}

# ------------------------------------------------------------------------------------------------
# Phase 4.3: ongoing Windows Update policy, applied only after the initial update stage
# ------------------------------------------------------------------------------------------------

Test-Scenario 'update policy: the package carries it; the answer file no longer writes AUOptions during specialize' {
    Assert-True ($script:Manifest.updatePolicy) 'manifest has updatePolicy'
    Assert-Equal $script:Manifest.updatePolicy.mode 'notifyInstall' 'mode'
    Assert-Equal $script:Manifest.updatePolicy.values.AUOptions 3 'AUOptions 3 = download automatically, notify to install'
    Assert-Equal $script:Manifest.updatePolicy.applyAfter 'windowsUpdate' 'ordering recorded'
    Assert-True (Test-Path -LiteralPath (Join-Path $pkgRoot $script:Manifest.updatePolicy.script)) 'Set-UpdatePolicy.ps1 in the package'
    Assert-True (@($script:Manifest.files | Where-Object { $_.path -eq $script:Manifest.updatePolicy.script -and $_.embedded }).Count -eq 1) 'and embedded in the answer file'
    $xml = [System.IO.File]::ReadAllText((Join-Path $usb 'autounattend.xml'))
    Assert-True ($xml -notmatch '/v "AUOptions"') 'no AUOptions written during specialize'
    Assert-True ($xml -match 'ExcludeWUDriversInQualityUpdate') 'driver exclusion still written during specialize'
}

Test-Scenario 'update policy ordering: not applied while Windows Update runs; applied once when its stage is final' {
    Initialize-Embedded | Out-Null
    Set-EngineStatus 'windowsUpdate' 'Installing'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'InProgress' 'run 1'
    Assert-Equal $script:SimAu.Count 0 'nothing written during initial updates'
    Assert-True (-not (Read-WddJson $script:Paths.State).ContainsKey('updatePolicy')) 'no policy state yet'
    # Restart in the middle of the update stage: still nothing.
    $script:SimBoot = $script:SimNow.AddMinutes(2); $script:SimNow = $script:SimNow.AddMinutes(30)
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'InProgress' 'run 2 after restart'
    Assert-Equal $script:SimAu.Count 0 'still nothing after the restart'
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'InProgress' 'WU final, apps still running'
    Assert-Equal $script:SimAu.AUOptions 3 'AUOptions written after the update stage'
    Assert-Equal $script:SimAu.NoAutoUpdate 0 'NoAutoUpdate 0 (Windows Update stays on)'
    Assert-Equal (Read-WddJson $script:Paths.State).updatePolicy.status 'Applied' 'completion state recorded'
    Assert-Equal (Read-WddJson (Join-Path $script:Paths.Root 'Updates\policy-result.json')).status 'Applied' 'result file'
    Assert-Equal (Read-WddJson $script:Paths.Status).updatePolicy.status 'Applied' 'shown in status.json'
    $writes = $script:SimAuWrites
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'InProgress' 'next run'
    Assert-Equal $script:SimAuWrites $writes 'applied only once'
    Set-EngineResult 'applications' 'Succeeded'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:Succeeded' 'deployment succeeds'
    $r = Read-WddJson $script:Paths.ReportJson
    Assert-Equal $r.updatePolicy.status 'Applied' 'in the report'
    Assert-True ([System.IO.File]::ReadAllText($script:Paths.ReportText) -match 'Ongoing Windows Update policy') 'in the text report'
}

Test-Scenario 'update policy: Windows Home is reported Unsupported, nothing is written, follow-up listed' {
    Initialize-Embedded | Out-Null
    $script:SimEdition = 'Core'
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Set-EngineResult 'applications' 'Succeeded'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFollowUp' 'not a silent success'
    Assert-Equal $script:SimAu.Count 0 'nothing written'
    $r = Read-WddJson $script:Paths.ReportJson
    Assert-Equal $r.updatePolicy.status 'Unsupported' 'unsupported'
    Assert-True (@($r.remainingTasks | Where-Object { $_ -match 'Ongoing Windows Update policy: Unsupported' }).Count -eq 1) 'follow-up listed'
}

Test-Scenario 'update policy: domain/MDM/WSUS management and existing values are never overridden' {
    Initialize-Embedded | Out-Null
    $script:SimManaged = @('joined to an Active Directory domain')
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Invoke-WddMonitor $script:Paths | Out-Null
    Assert-Equal (Read-WddJson $script:Paths.State).updatePolicy.status 'ManagedByOrganization' 'managed'
    Assert-Equal $script:SimAu.Count 0 'nothing written on a managed computer'

    Reset-Sim; Initialize-Embedded | Out-Null
    $script:SimAu = @{ AUOptions = 4; ScheduledInstallDay = 0 }
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Invoke-WddMonitor $script:Paths | Out-Null
    Assert-Equal (Read-WddJson $script:Paths.State).updatePolicy.status 'Conflict' 'conflict'
    Assert-Equal $script:SimAu.AUOptions 4 'existing value unchanged'
    Assert-Equal $script:SimAuWrites 0 'no write'

    Reset-Sim; Initialize-Embedded | Out-Null
    $script:SimAu = @{ AUOptions = 3; NoAutoUpdate = 0 }
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Invoke-WddMonitor $script:Paths | Out-Null
    Assert-Equal (Read-WddJson $script:Paths.State).updatePolicy.status 'AlreadyApplied' 'already applied'
}

Test-Scenario 'update policy: a write failure is reported, the deployment still finishes' {
    Initialize-Embedded | Out-Null
    $script:SimAuFail = $true
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Set-EngineResult 'applications' 'Succeeded'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFollowUp' 'follow-up'
    $r = Read-WddJson $script:Paths.ReportJson
    Assert-Equal $r.updatePolicy.status 'Failed' 'failed'
    Assert-True ($r.updatePolicy.message -match 'Access is denied') 'reason kept'
}

Test-Scenario 'update policy: an Offline update stage still counts as final; the deadline applies it with a note' {
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'Offline'
    Invoke-WddMonitor $script:Paths | Out-Null
    Assert-Equal (Read-WddJson $script:Paths.State).updatePolicy.status 'Applied' 'applied after an Offline update stage'

    Reset-Sim; Initialize-Embedded | Out-Null
    Set-EngineStatus 'windowsUpdate' 'Installing'
    $state = Read-WddJson $script:Paths.State
    $script:SimNow = (ConvertTo-WddDate $state.deadlineUtc).AddMinutes(1)
    $out = Invoke-WddMonitor $script:Paths
    Assert-True ($out -like 'Completed:*') 'deadline completes'
    $r = Read-WddJson $script:Paths.ReportJson
    Assert-Equal $r.updatePolicy.status 'Applied' 'applied at the end'
    Assert-True ($r.updatePolicy.note -match 'had not reported a final result') 'note explains the timing'
}

Test-Scenario 'Wi-Fi result: a profile that could not be added is listed as a follow-up in the report' {
    Initialize-Embedded | Out-Null
    Write-WddJson (Join-Path $script:Paths.Root 'Network\wifi-result.json') @{ status = 'NoWirelessAdapter'; stage = 'FirstLogon'; final = $true; profileName = 'Home'; adapters = 0; message = 'No Wi-Fi adapter with a working driver was found.' }
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Set-EngineResult 'applications' 'Succeeded'
    Invoke-WddMonitor $script:Paths | Out-Null
    $r = Read-WddJson $script:Paths.ReportJson
    Assert-Equal $r.wifi.status 'NoWirelessAdapter' 'wifi in report'
    Assert-True (@($r.remainingTasks | Where-Object { $_ -match '^Wi-Fi: NoWirelessAdapter' }).Count -eq 1) 'follow-up'
}

# ------------------------------------------------------------------------------------------------
# Phase 5: full provisioning lifecycle. The REAL application engine and recovery tool from the
# generated package run against the real staged package and its real applications-config.json
# (WinGet, Microsoft Store, portable and manual entries); WinGet, tasks, time and restarts are
# simulated. Nothing is installed or registered.
# ------------------------------------------------------------------------------------------------


Test-Scenario 'Phase 5 package: recovery tool shipped, embedded, staged; manifest declares recovery and state schemas' {
    $f = @($script:Manifest.files | Where-Object { $_.path -eq 'scripts/recovery/DeploymentRecovery.ps1' })
    Assert-Equal $f.Count 1 'listed in the manifest'
    Assert-Equal $f[0].embedded 'Deployment\scripts\recovery\DeploymentRecovery.ps1' 'embedded in the answer file'
    Assert-Equal $script:Manifest.recovery.tool 'scripts/recovery/DeploymentRecovery.ps1' 'manifest recovery block'
    Assert-Equal "$($script:Manifest.recovery.stateSchemas.deploymentState) $($script:Manifest.recovery.stateSchemas.applicationState) $($script:Manifest.recovery.stateSchemas.applicationResult)" '2 2 2' 'state schema versions'
    Assert-Equal $script:Manifest.recovery.outcomeCodes.PausedAwaitingNetwork 30 'outcome codes'
    $cfg = Read-WddJson (Join-Path $pkgRoot 'scripts\applications\applications-config.json')
    Assert-Equal "$($cfg.engineVersion) $($cfg.maxAttemptsPerPackage) $($cfg.retry.automatic) $($cfg.retry.baseDelaySeconds)" '1.5.0 3 True 60' 'retry configuration'
    Initialize-Embedded | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $script:Paths.Package 'scripts\recovery\DeploymentRecovery.ps1')) 'staged on the computer'
    Assert-True $script:Shortcuts.ContainsKey('Deployment recovery') 'recovery shortcut'
    Assert-True ($script:Shortcuts['Deployment recovery'] -match 'DeploymentRecovery\.ps1" -Elevate') 'shortcut asks for elevation'
}

Test-Scenario 'Phase 5 lifecycle: mixed methods end to end; a transient failure is retried; outcome CompletedWithWarnings (10)' {
    Reset-AppSim @{ 'Google.Chrome' = 'fail-once' }
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    $o = Invoke-AppRuns
    Assert-Equal $o[-1] 'Finished:CompletedWithFollowUp' 'manual RustDesk is a follow-up'
    Assert-Equal $script:AppSim.Calls['Google.Chrome'] 2 'Chrome retried once'
    foreach ($id in $script:FixtureApps | Where-Object { $_ -ne 'Google.Chrome' }) { Assert-Equal $script:AppSim.Calls[$id] 1 "$id installed exactly once" }
    Assert-True (Test-Path -LiteralPath (Join-Path $script:Tmp 'StartMenu\Rufus.lnk')) 'portable shortcut'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFollowUp' 'deployment'
    $s = Read-WddJson $script:Paths.Status
    Assert-Equal "$($s.outcome) $($s.outcomeCode)" 'CompletedWithWarnings 10' 'machine-readable outcome'
    $r = Read-WddJson $script:Paths.ReportJson
    Assert-Equal "$($r.reportVersion) $($r.outcome) $($r.outcomeCode)" '2 CompletedWithWarnings 10' 'report outcome'
    Assert-Equal ((@($r.outstanding) | ForEach-Object { "$($_.operationId)=$($_.lifecycle)" }) -join ',') 'app:catalog:rustdesk=ManualActionRequired' 'outstanding work'
    Assert-Equal (@($r.applications.packages) | Where-Object { $_.packageIdentifier -eq 'Google.Chrome' }).totalAttempts 2 'attempts in the report'
    Assert-True ($r.recoveryCommands.retryFailed -match 'DeploymentRecovery\.ps1" -Action RetryFailed') 'recovery commands'
    $txt = Get-Content -LiteralPath $script:Paths.ReportText -Raw
    Assert-True ($txt -match 'Outstanding work \(kept for recovery\)') 'text report section'
    Assert-True ($txt -match 'Outcome        : CompletedWithWarnings \(exit code 10\)') 'text report outcome'
}

Test-Scenario 'Phase 5 lifecycle: restart during provisioning resumes after the boot; nothing is repeated; paused for reboot (31)' {
    Reset-AppSim @{ 'VideoLAN.VLC' = 'reboot-now' }
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Assert-Equal (Invoke-WdaMain (Get-SimAppConfig)) 'Rebooting' 'restart requested before VLC can install'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'InProgress' 'monitor during the restart window'
    $s = Read-WddJson $script:Paths.Status
    Assert-Equal "$($s.restartPending) $($s.outcome) $($s.outcomeCode)" 'True PausedAwaitingReboot 31' 'engine restart marker recognised'
    $script:SimNow = $script:SimNow.AddMinutes(3); $script:SimBoot = $script:SimNow; $script:SimNow = $script:SimNow.AddMinutes(2)
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'InProgress' 'monitor at startup'
    Assert-True (-not (Read-WddJson $script:Paths.Status).restartPending) 'marker from the previous boot ignored'
    $o = Invoke-AppRuns
    Assert-Equal $o[-1] 'Finished:CompletedWithFollowUp' 'finished after the restart'
    Assert-Equal $script:AppSim.Calls['VideoLAN.VLC'] 2 'VLC attempted again after the restart'
    Assert-Equal $script:AppSim.Calls['Google.Chrome'] 1 'packages installed before the restart are not repeated'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFollowUp' 'completed'
}

Test-Scenario 'Phase 5 lifecycle: lost network pauses the deployment (30) without failing anything, then resumes' {
    Reset-AppSim @{ 'CodeSector.TeraCopy' = 'net-drop' }
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Assert-Equal (Invoke-WdaMain (Get-SimAppConfig)) 'WaitingForNetwork' 'engine waits'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'InProgress' 'deployment continues'
    $s = Read-WddJson $script:Paths.Status
    Assert-Equal "$($s.outcome) $($s.outcomeCode)" 'PausedAwaitingNetwork 30' 'paused for the network'
    $st = Read-WddJson (Join-Path $script:Paths.Root 'Applications\state.json')
    Assert-Equal @($st.packages.Values | Where-Object { $_.status -eq 'Failed' }).Count 0 'nothing marked failed'
    $script:AppSim.Online = $true
    $o = Invoke-AppRuns
    Assert-Equal $o[-1] 'Finished:CompletedWithFollowUp' 'resumed'
    Assert-Equal $script:AppSim.Calls['Google.Chrome'] 1 'finished work not repeated'
    Assert-Equal (Get-AppPkg (Get-AppResult) 'CodeSector.TeraCopy').attempts 1 'the lost-network attempt is not held against it'
}

Test-Scenario 'Phase 5 lifecycle: USB and setup files gone after staging; engine, monitor and recovery run from the local copy' {
    Reset-AppSim @{ 'Git.Git' = 'fail' }
    $copy = Join-Path $script:Tmp 'usb-copy'
    Copy-Item -LiteralPath $pkgRoot -Destination $copy -Recurse
    Assert-Equal (Invoke-WddInitialize $script:Manifest (Join-Path $copy 'deployment-manifest.json') 'Package' $copy '' $script:Paths -NoConsole) 'Initialized' 'staged from the USB copy'
    Remove-Item -LiteralPath $copy -Recurse -Force    # the USB drive is removed
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    [void] (Invoke-AppRuns)
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFailures' 'finished without the USB'
    $script:AppSim.Behaviour['Git.Git'] = 'ok'
    Assert-Equal (Invoke-WdrRecovery $script:Manifest $script:Paths 'RetryFailed').Outcome 'Done' 'recovery without the USB'
    [void] (Invoke-AppRuns)
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFollowUp' 'completed after recovery'
    Assert-Equal $script:Installers.Count 2 'no stage launched twice'
}

Test-Scenario 'Phase 5 recovery: retry failed after CompletedWithFailures; successful apps untouched; permanent failure needs -IncludePermanent' {
    Reset-AppSim @{ 'Git.Git' = 'fail'; 'Bitwarden.Bitwarden' = 'hash' }
    $script:AppSim.IntegrityRetryMinutes = 0
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    [void] (Invoke-AppRuns)
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFailures' 'first result'
    Assert-Equal (Read-WddJson $script:Paths.Status).outcomeCode 20 'exit code 20'
    $r = Read-WddJson $script:Paths.ReportJson
    $out = @{}; foreach ($x in @($r.outstanding)) { $out[$x.operationId] = $x.lifecycle }
    Assert-Equal "$($out['app:winget:git.git']) $($out['app:winget:bitwarden.bitwarden']) $($out['app:catalog:rustdesk'])" 'FailedRetryable FailedPermanent ManualActionRequired' 'outstanding classified'
    Assert-Equal $script:AppSim.Calls['Git.Git'] 3 'three automatic attempts'
    Assert-Equal $script:AppSim.Calls['Bitwarden.Bitwarden'] 1 'hash mismatch not retried'

    $script:AppSim.Behaviour['Git.Git'] = 'ok'           # the technician fixed the cause
    $rec = Invoke-WdrRecovery $script:Manifest $script:Paths 'RetryFailed'
    Assert-Equal $rec.Outcome 'Done' 'accepted'
    Assert-Equal (@($rec.Accepted) -join ',') 'app:winget:git.git' 'only the retryable failure'
    Assert-True (@($rec.Refused).Count -eq 0) 'permanent failures are simply not selected by RetryFailed'
    Assert-Equal $script:AppSim.ResumeInstalls 1 'application task registered again (no archive)'
    $st = Read-WddJson $script:Paths.State
    Assert-Equal $st.status 'InProgress' 'deployment reopened'
    Assert-Equal @($st.recoveries).Count 1 'recovery recorded'
    Assert-True $script:SimTasks.ContainsKey('\WindowsDeploymentBuilder\Deployment') 'monitor registered again'
    Assert-True (-not (Test-Path -LiteralPath $script:Paths.Marker)) 'old marker set aside'
    Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $script:Paths.Reports 'history') -Filter 'deployment-report-*').Count 2 'previous report (json + txt) kept'
    [void] (Invoke-AppRuns)
    Assert-Equal "$($script:AppSim.Calls['Git.Git']) $($script:AppSim.Calls['Google.Chrome'])" '4 1' 'Git once more; Chrome never again'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFailures' 'Bitwarden still failed'
    $g = @((Read-WddJson $script:Paths.ReportJson).applications.packages) | Where-Object { $_.packageIdentifier -eq 'Git.Git' }
    Assert-Equal "$($g.status) $($g.manualRetries) $($g.totalAttempts)" 'Succeeded 1 4' 'history in the report'

    $rec = Invoke-WdrRecovery $script:Manifest $script:Paths 'Retry' -Operations @('app:winget:bitwarden.bitwarden')
    Assert-Equal $rec.Outcome 'Refused' 'permanent without -IncludePermanent'
    Assert-True ($rec.Refused[0].reason -match 'IncludePermanent') 'reason'
    $script:AppSim.Behaviour['Bitwarden.Bitwarden'] = 'ok'
    Assert-Equal (Invoke-WdrRecovery $script:Manifest $script:Paths 'Retry' -Operations @('app:winget:bitwarden.bitwarden') -IncludePermanent).Outcome 'Done' 'explicit override'
    [void] (Invoke-AppRuns)
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFollowUp' 'only the manual app remains'
    Assert-Equal $script:Installers.Count 2 'Windows was not reinstalled and no stage was relaunched'
}

Test-Scenario 'Phase 5 recovery: refuses manual, deselected-or-installed, finished stages, tampered packages and non-administrators' {
    Reset-AppSim @{ 'Git.Git' = 'fail' }
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    [void] (Invoke-AppRuns)
    [void] (Invoke-WddMonitor $script:Paths)
    $rec = Invoke-WdrRecovery $script:Manifest $script:Paths 'Retry' -Operations @('app:catalog:rustdesk', 'app:winget:google.chrome', 'stage:windowsUpdate', 'app:winget:$(calc)')
    Assert-Equal $rec.Outcome 'Refused' 'nothing reopened'
    $why = @{}; foreach ($x in $rec.Refused) { $why[$x.operationId] = $x.reason }
    Assert-True ($why['app:catalog:rustdesk'] -match 'not a valid operation id') 'manual entry refused'
    Assert-True ($why['app:winget:google.chrome'] -match 'already installed') 'installed refused'
    Assert-True ($why['stage:windowsUpdate'] -match 'only a stage that ended with failures') 'finished update stage refused'
    Assert-True ($why['app:winget:$(calc)'] -match 'not a valid operation id') 'no expression is evaluated'
    Assert-Equal (Read-WddJson $script:Paths.State).status 'Completed' 'state untouched'
    Add-Content -LiteralPath (Join-Path $script:Paths.Package 'scripts\applications\ApplicationEngine.ps1') -Value '# tampered'
    $rec = Invoke-WdrRecovery $script:Manifest $script:Paths 'RetryFailed'
    Assert-Equal $rec.Outcome 'IntegrityFailed' 'tampered package refused'
    Assert-True (@($rec.Refused | Where-Object { $_.operationId -eq 'file:scripts/applications/ApplicationEngine.ps1' }).Count -eq 1) 'modified file named'
    Assert-Equal $script:AppSim.ResumeInstalls 0 'nothing registered'
    $script:SimIdentity = @{ Name = 'PC\Guest'; IsSystem = $false; IsAdmin = $false }
    Assert-Equal (Invoke-WdrRecovery $script:Manifest $script:Paths 'RetryFailed').Outcome 'NotElevated' 'administrators only'
}

Test-Scenario 'Phase 5 recovery: a failed Windows Update stage is relaunched once; the ongoing policy is not applied twice' {
    Reset-AppSim
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'CompletedWithFailures' @{ failed = @(@{ kbs = @('KB5031455'); title = 'Cumulative Update'; attempts = 2; lastResult = 'Failed'; lastHResult = '0x80240022' }) }
    [void] (Invoke-AppRuns)
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFailures' 'update failures'
    Assert-Equal (Read-WddJson $script:Paths.State).updatePolicy.status 'Applied' 'policy applied after the final update result'
    $writes = $script:SimAuWrites
    $r = Read-WddJson $script:Paths.ReportJson
    Assert-True (@($r.outstanding | Where-Object { $_.operationId -eq 'stage:windowsUpdate' }).Count -eq 1) 'update stage outstanding'
    $rec = Invoke-WdrRecovery $script:Manifest $script:Paths 'RetryFailed'
    Assert-Equal (@($rec.Accepted) -join ',') 'stage:windowsUpdate' 'update stage relaunched (no application to retry)'
    Assert-Equal ($script:Installers -join ',') 'Install-UpdateEngine.ps1,Install-ApplicationEngine.ps1,Install-UpdateEngine.ps1' 'its own installer, once'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'InProgress' 'waits for the new update run'
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFollowUp' 'finished'
    Assert-Equal $script:SimAuWrites $writes 'policy not written again'
}

Test-Scenario 'Phase 5 state: a damaged deployment.json uses its backup; both damaged stops safely and Resume rebuilds without relaunching' {
    Reset-AppSim
    Initialize-Embedded | Out-Null
    [void] (Invoke-WddMonitor $script:Paths)
    Assert-True (Test-Path -LiteralPath "$($script:Paths.State).bak") 'backup kept'
    [IO.File]::WriteAllText($script:Paths.State, '{"schemaVersion":2,"packageId":"')
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'InProgress' 'backup used'
    Assert-True (Test-Path -LiteralPath "$($script:Paths.State).corrupt") 'damaged copy kept'

    [IO.File]::WriteAllText($script:Paths.State, 'garbage')
    [IO.File]::WriteAllText("$($script:Paths.State).bak", '{"schemaVersion":2,"packageId":"NOT-A-PACKAGE","status":"Completed"}')
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'StateCorrupt' 'monitor stops'
    $s = Read-WddJson $script:Paths.Status
    Assert-Equal "$($s.deploymentState) $($s.outcome) $($s.outcomeCode)" 'StateCorrupt FailedToInitialize 50' 'status'
    Assert-True ($script:Events -contains 3004) 'event'
    Assert-Equal (Initialize-Embedded) 'StateCorrupt' 'setup never starts over on a damaged state'
    Assert-Equal $script:Installers.Count 2 'nothing relaunched'
    Assert-Equal (Invoke-WdrRecovery $script:Manifest $script:Paths 'RetryFailed').Outcome 'Refused' 'retry asks for Resume first'
    $rec = Invoke-WdrRecovery $script:Manifest $script:Paths 'Resume'
    Assert-Equal $rec.Outcome 'Done' 'resume rebuilds'
    $st = Read-WddJson $script:Paths.State
    Assert-Equal "$($st.status) $($st.stages.windowsUpdate.launchResult) $($st.stages.applications.launchResult)" 'InProgress Launched Launched' 'stages found, not relaunched'
    Assert-Equal $script:Installers.Count 2 'still no second launch'
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    [void] (Invoke-AppRuns)
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFollowUp' 'completes normally'
}

Test-Scenario 'Phase 5 status: idle user stage is PausedAwaitingUser (32); Status -Json and PendingActions for the technician' {
    Reset-AppSim
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Set-EngineStatus 'applications' 'WaitingForUpdates'
    $script:SimNow = $script:SimNow.AddHours(5)    # nobody signed in: the user task never ran
    [void] (Invoke-WddMonitor $script:Paths)
    $s = Read-WddJson $script:Paths.Status
    Assert-Equal "$($s.outcome) $($s.outcomeCode)" 'PausedAwaitingUser 32' 'paused for the user'
    Assert-True ($s.outcomeDetail -match 'PC\\Alex is signed in') 'says who must sign in'
    [void] (Invoke-AppRuns)
    [void] (Invoke-WddMonitor $script:Paths)
    $j = (Invoke-WdrAction $script:Manifest $script:Paths 'Status' -Json)
    $st = $j.Text | ConvertFrom-Json
    Assert-Equal "$($st.outcome) $($st.exitCode) $($j.Exit)" 'CompletedWithWarnings 10 10' 'machine-readable status and exit code'
    Assert-Equal @($st.operations).Count 12 'every operation listed'
    Assert-True (@($st.operations | Where-Object { $_.operationId -eq 'app:winget:git.git' -and $_.lifecycle -eq 'Succeeded' }).Count -eq 1) 'lifecycle per operation'
    $p = (Invoke-WdrAction $script:Manifest $script:Paths 'PendingActions').Text
    Assert-True ($p -match 'RustDesk: Manual action required') 'manual follow-up listed'
    Assert-True ($p -match 'Manufacturer drivers') 'report follow-ups listed'
}

Test-Scenario 'Engine 2.0.0: Retry Windows Update is staged with the package and offered by the recovery tool (separate process, mode passed through)' {
    Reset-AppSim @{}
    $emb = Invoke-SimExtraction
    Invoke-WddInitialize $script:Manifest (Join-Path $emb 'Deployment\deployment-manifest.json') 'Embedded' (Join-Path $emb 'Deployment') $emb $script:Paths -NoConsole | Out-Null
    $tool = Join-Path $script:Paths.Package 'scripts\windows-update\Invoke-WindowsUpdateRetry.ps1'
    Assert-True (Test-Path -LiteralPath $tool) 'retry tool staged on the computer'
    $script:RetryCalls = @()
    function Invoke-WdrUpdateRetryTool { param([string] $Tool, [string] $Mode, [string] $DataRoot, [bool] $Json, [string] $OutputPath) $script:RetryCalls += , @($Tool, $Mode, $DataRoot); @{ Text = @("simulated $Mode"); Exit = 0 } }
    $r = Invoke-WdrAction $script:Manifest $script:Paths 'RetryWindowsUpdate' -UpdateMode 'RetryDrivers'
    Assert-Equal "$($r.Text) $($r.Exit)" 'simulated RetryDrivers 0' 'tool output returned'
    Assert-Equal "$($script:RetryCalls[0][0]) $($script:RetryCalls[0][1]) $($script:RetryCalls[0][2])" "$tool RetryDrivers $($script:Paths.Root)" 'package tool, mode and data root'
    Remove-Item -LiteralPath $tool -Force
    $r = Invoke-WdrAction $script:Manifest $script:Paths 'RetryWindowsUpdate' -UpdateMode 'Status'
    Assert-True ($r.Exit -eq 1 -and $r.Text -match 'not part of this deployment package') 'a package without the tool says so'
    Remove-Item Function:\Invoke-WdrUpdateRetryTool -ErrorAction SilentlyContinue
}

Test-Scenario 'Engine 2.0.0: the recovery tool runner survives stderr from the retry tool and returns its exit code (Windows PowerShell 5.1 under Stop)' {
    $probe = Join-Path $script:Paths.Root 'stderr-probe.ps1'
    New-Item -ItemType Directory -Path $script:Paths.Root -Force | Out-Null
    [IO.File]::WriteAllText($probe, "param([string] `$Mode, [string] `$DataRoot) [Console]::Error.WriteLine('a warning on stderr'); `"mode `$Mode`"; exit 3")
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    try { $r = Invoke-WdrUpdateRetryTool -Tool $probe -Mode 'Status' -DataRoot $script:Paths.Root -Json $false -OutputPath '' }
    finally { $ErrorActionPreference = $eap }
    Assert-Equal $r.Exit 3 'exit code returned, not a terminating error'
    Assert-True (@($r.Text) -contains 'mode Status') 'standard output kept'
    Assert-True (@($r.Text) -match 'a warning on stderr').Count 'stderr kept as text'
    Assert-Equal $ErrorActionPreference $eap 'error preference restored'
}

Test-Scenario 'Engine 2.0.0: the deployment report carries the engine version, readiness, passes, categories, engine exceptions, drivers and the final check' {
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'CompletedWithFailures' @{ engineVersion = '2.0.0'; stopReason = ''
        installed = @(@{ kb = 'KB1'; title = 'Intel - System - 10.1'; driver = $true; device = @{ model = 'Intel SM Bus'; hardwareID = 'PCI\VEN_8086&DEV_51A3' } })
        failed = @(@{ kbs = @('KB5099999'); title = '2026-11 Cumulative Update'; attempts = 2; lastResult = 'Failed'; lastHResult = '0x800F0922'; category = 'InstallerFailure' })
        skipped = @()
        failedByCategory = @{ InstallerFailure = 1 }
        technicianAction = 'Check free space on the system reserved partition, then run Retry Windows Update.'
        readiness = @{ status = 'Ready'; searchAttempts = 2; restartDone = $false; prerequisites = @(@{ title = 'SSU' }) }
        passes = @(@{ pass = 'A'; updates = @('SSU') }, @{ pass = 'B'; updates = @('CU') }, @{ pass = 'D'; updates = @() })
        engineExceptions = @(@{ operation = 'install: IUpdateInstaller.Install'; type = 'System.Runtime.InteropServices.COMException'; hresult = '0x8024000B'; message = 'x'; line = 12; statement = ''; updates = @('KB1') })
        drivers = @(@{ title = 'Intel - System - 10.1'; device = @{ model = 'Intel SM Bus'; hardwareID = 'PCI\VEN_8086&DEV_51A3' }; result = 'Succeeded' })
        verification = @{ remainingOffered = 1; noLongerOffered = @(@{ title = 'old preview' }); devicesWithProblems = @(@{ name = 'USB device'; problem = 43 }); rebootPending = $false } }
    Set-EngineResult 'applications' 'Succeeded' @{ packages = @(@{ name = 'Git'; packageIdentifier = 'Git.Git'; source = 'winget'; status = 'Succeeded'; attempts = 1; exitCode = 0; message = '' }) }
    $outcome = Invoke-WddMonitor $script:Paths
    Assert-True ($outcome -like 'Completed:*') "the deployment completes ($outcome)"
    $r = Read-WddJson $script:Paths.ReportJson
    $w = $r.windowsUpdate
    Assert-Equal "$($w.engineVersion) $(@($w.engineExceptions).Count) $(@($w.passes).Count) $($w.devicesAfterUpdates)" '2.0.0 1 3 1' 'engine 2.0.0 details in the JSON report'
    Assert-Equal "$($w.failedUpdates[0].category) $($w.failedUpdates[0].lastHResult)" 'InstallerFailure 0x800F0922' 'failure category carried into the report'
    Assert-True (@($r.remainingTasks) -match 'KB5099999.*0x800F0922, InstallerFailure').Count 'follow-up names the code and category'
    Assert-True (@($r.remainingTasks) -match 'Check free space on the system reserved partition').Count 'technician action is a follow-up'
    $txt = Get-Content -LiteralPath $script:Paths.ReportText -Raw -Encoding UTF8
    foreach ($t in 'Engine: 2.0.0', 'Readiness: Ready after 2 search', 'Passes: A (1), B (1), D (0)', 'Failures by category: InstallerFailure 1', 'ENGINE  install: IUpdateInstaller.Install', 'not an update failure', 'DRIVER  Intel - System - 10.1 -> Intel SM Bus [PCI\VEN_8086&DEV_51A3]', 'Final check: 1 still offered, 1 no longer offered', '1 device(s) with problems', 'FAILED  KB5099999 2026-11 Cumulative Update (2 attempts, 0x800F0922, InstallerFailure)', 'ACTION  Check free space') {
        Assert-True ($txt.Contains($t)) "text report: $t"
    }
    Assert-True (-not $txt.Contains('Post-install')) 'no post-install section (not part of this branch)'
}

Test-Scenario 'Phase 5 diagnostics: one ZIP with logs, states and report; passwords redacted; answer files and Wi-Fi profiles never included' {
    Reset-AppSim @{ 'Git.Git' = 'fail' }
    $emb = Invoke-SimExtraction
    Invoke-WddInitialize $script:Manifest (Join-Path $emb 'Deployment\deployment-manifest.json') 'Embedded' (Join-Path $emb 'Deployment') $emb $script:Paths -NoConsole | Out-Null
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    [void] (Invoke-AppRuns)
    [void] (Invoke-WddMonitor $script:Paths)
    [IO.File]::AppendAllText((Join-Path $script:Paths.Root 'Applications\logs\engine.log'), "2026-10-20 09:00:00  INFO   test line password=Hunter2!Secret`r`n")
    New-Item -ItemType Directory -Path (Join-Path $script:Paths.Root 'Network') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $script:Paths.Root 'Network\wifi-result.json'), '{"status":"Added","profileName":"Home","networkKey":"Wifi-Pass-123"}')
    [IO.File]::WriteAllText((Join-Path $script:Paths.Root 'Network\Wifi.xml'), '<WLANProfile><keyMaterial>Wifi-Pass-123</keyMaterial></WLANProfile>')
    [IO.File]::WriteAllText((Join-Path $emb 'Wifi.xml'), '<WLANProfile><keyMaterial>Wifi-Pass-123</keyMaterial></WLANProfile>')
    $zip = Join-Path $script:Tmp 'out\diag.zip'
    $r = Export-WdrDiagnostics $script:Manifest $script:Paths $zip
    Assert-Equal $r.Outcome 'Done' 'exported'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $names = @($z.Entries | ForEach-Object { $_.FullName -replace '/', '\' })
        foreach ($need in 'diagnostics.json', 'recovery-status.txt', 'state\deployment.json', 'Applications\state.json', 'Applications\result.json', 'Applications\logs\engine.log', 'Applications\logs\attempts.jsonl', 'reports\deployment-report.txt', 'Package\deployment-manifest.json') {
            Assert-True ($names -contains $need) "contains $need"
        }
        Assert-Equal @($names | Where-Object { $_ -match '\.xml$|autounattend|unattend' }).Count 0 'no answer file or Wi-Fi profile'
        $all = ($z.Entries | ForEach-Object { $s = $_.Open(); try { (New-Object IO.StreamReader($s)).ReadToEnd() } finally { $s.Dispose() } }) -join "`n"
        Assert-True (-not $all.Contains('Hunter2!Secret')) 'password in a log redacted'
        Assert-True (-not $all.Contains('Wifi-Pass-123')) 'Wi-Fi key redacted'
        Assert-True ($all.Contains('[redacted]')) 'redaction marker'
        $info = ($z.Entries | Where-Object { $_.FullName -eq 'diagnostics.json' } | ForEach-Object { $s = $_.Open(); try { (New-Object IO.StreamReader($s)).ReadToEnd() } finally { $s.Dispose() } }) | ConvertFrom-Json
        Assert-Equal "$($info.outcome) $($info.outcomeCode)" 'CompletedWithFailures 20' 'outcome in the index'
        Assert-True ([int] $info.redactedFiles -ge 2) 'redactions counted'
    } finally { $z.Dispose() }
    Assert-True (Test-Path -LiteralPath (Join-Path $emb 'Wifi.xml')) 'nothing outside the data root was touched'
}

# ------------------------------------------------------------------------------------------------
# Phase 6: application restoration. The second generated package (deployment-fixture.ts
# writeMigrationFixture) carries a reviewed inventory and pins a settings backup that lies on the
# simulated USB drive. The package's own engine, restore library and recovery tool run; the user
# profile, WinGet, tasks and drives are simulated.
# ------------------------------------------------------------------------------------------------

. (Join-Path $PSScriptRoot 'MigrationSim.ps1')

if (Test-Path -LiteralPath $migFixture) {

Test-Scenario 'Phase 6 package: restore library embedded and staged, restoration plan shipped, the backup never inside the package' {
    Use-MigrationPackage
    $f = @($script:Manifest.files | Where-Object { $_.path -eq 'scripts/applications/WdbMigration.ps1' })
    Assert-Equal $f[0].embedded 'Applications\WdbMigration.ps1' 'restore library embedded in the answer file'
    Assert-True (@($script:Manifest.files | Where-Object { $_.path -eq 'scripts/applications/restore-plan.txt' }).Count -eq 1) 'restoration plan in the package'
    Assert-Equal @($script:Manifest.files | Where-Object { $_.path -match 'backups/|data/' }).Count 0 'no backup data in the package'
    $m = Read-WddJson (Join-Path $script:UsbBackups "$script:MigBackupFolder\backup-manifest.json")
    $cfg = Read-WddJson (Join-Path $script:pkgRoot 'scripts\applications\applications-config.json')
    Assert-Equal $cfg.settingsRestore.manifestSha256 (Get-WddRawHash (Join-Path $script:UsbBackups "$script:MigBackupFolder\backup-manifest.json")) 'the plan pins exactly this backup manifest'
    Assert-Equal $script:Manifest.migration.settingsRestore.expectedLocation "WindowsDeployment\backups\$script:MigBackupFolder" 'manifest says where the backup goes'
    Assert-Equal $m.backupId $cfg.settingsRestore.backupId 'backup id'
    Assert-True (Test-WdbBackup (Join-Path $script:UsbBackups $script:MigBackupFolder) $cfg.settingsRestore.manifestSha256).Ok 'a manifest written by TypeScript validates in PowerShell'
    Initialize-Embedded | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $script:Paths.Package 'scripts\applications\WdbMigration.ps1')) 'staged with the engine'
}

Test-Scenario 'Phase 6 lifecycle: applications first, then settings from the USB backup; restoration.json and the report' {
    Use-MigrationPackage
    Reset-AppSim
    Initialize-Embedded | Out-Null
    $o = Invoke-AppRuns
    Assert-Equal $o[-1] 'Finished:CompletedWithFollowUp' 'manual items are follow-ups'
    Assert-Equal $script:AppSim.Calls['Microsoft.VisualStudioCode'] 1 'VS Code installed once'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $script:WdbEnv.APPDATA 'Code\User\settings.json'))) "{ `"editor.fontSize`": 15, `"files.autoSave`": `"afterDelay`" }`n" 'VS Code settings restored'
    Assert-True ([IO.File]::ReadAllText((Join-Path $script:WdbEnv.USERPROFILE '.gitconfig')) -match 'Alex Example') 'Git identity restored'
    $order = @(Get-Content -LiteralPath (Join-Path $script:Paths.Root 'Applications\logs\attempts.jsonl') | ForEach-Object { ($_ | ConvertFrom-Json).operationId })
    Assert-True ([array]::IndexOf($order, 'settings:vscode') -gt [array]::IndexOf($order, 'app:winget:microsoft.visualstudiocode')) 'settings after the application'
    $x = Read-WddJson (Join-Path $script:Paths.Root 'Applications\restoration.json')
    Assert-Equal ((@($x.applications) | ForEach-Object { "$($_.displayName)=$($_.outcome)" }) -join ';') 'Contoso Field Tool=ManualActionRequired;Git=InstalledSuccessfully;Microsoft Visual Studio Code=InstalledSuccessfully;NVIDIA Graphics Driver=SkippedByUser' 'per-application outcomes'
    Assert-Equal ((@($x.settings) | ForEach-Object { "$($_.adapterId)=$($_.outcome)" }) -join ';') 'git=ConfigurationRestored;vscode=ConfigurationRestored' 'settings outcomes'
    Assert-Equal $x.backup.status 'Staged' 'backup staged from the USB drive'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFollowUp' 'deployment finished'
    $r = Read-WddJson $script:Paths.ReportJson
    Assert-Equal $r.restoration.counts.ConfigurationRestored 2 'restoration in the report'
    Assert-True ($r.recoveryCommands.restoreSettings -match '-Action RestoreSettings') 'recovery command'
    Assert-True ((Get-Content -Raw $script:Paths.ReportText) -match 'Application restoration') 'report text'
}

Test-Scenario 'Phase 6 recovery: USB removed before staging; a wrong backup is refused; RestoreSettings restores only what is outstanding' {
    Use-MigrationPackage
    Reset-AppSim
    $script:UsbBackups = $null
    Initialize-Embedded | Out-Null
    $o = Invoke-AppRuns
    Assert-Equal $o[-1] 'Finished:CompletedWithFollowUp' 'follow-up, not failure'
    $res = Read-WddJson (Join-Path $script:Paths.Root 'Applications\result.json')
    Assert-Equal ((@($res.settings) | ForEach-Object { "$($_.id)=$($_.restoreOutcome)" }) -join ';') 'git=WaitingForBackup;vscode=WaitingForBackup' 'waiting for the backup'
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFollowUp' 'deployment finished'
    $pending = @(Get-WdrPendingActions $script:Manifest $script:Paths)
    Assert-True (@($pending | Where-Object { $_ -match 'RestoreSettings' }).Count -ge 1) 'pending actions explain what to do'
    # A copy with one modified file is refused before anything is staged or restored.
    $bad = Join-Path $script:Tmp 'E\bad'
    Copy-Item -LiteralPath (Join-Path $migFixture "usb\WindowsDeployment\backups\$script:MigBackupFolder") -Destination $bad -Recurse
    [IO.File]::WriteAllText((Join-Path $bad 'data\vscode\settings.json'), '{ "evil": true }')
    $r = Invoke-WdrRestoreSettings $script:Manifest $script:Paths $bad
    Assert-Equal $r.Outcome 'IntegrityFailed' 'tampered backup refused'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:WdbEnv.APPDATA 'Code'))) 'nothing restored'
    $good = Join-Path $script:Tmp 'E\good'
    Copy-Item -LiteralPath (Join-Path $migFixture "usb\WindowsDeployment\backups\$script:MigBackupFolder") -Destination $good -Recurse
    New-Item -ItemType File -Path (Join-Path $script:WdbEnv.USERPROFILE '.gitconfig') -Value "[user]`n`tname = Already Here`n" -Force | Out-Null
    $r = Invoke-WdrRestoreSettings $script:Manifest $script:Paths $good
    Assert-Equal $r.Outcome 'Done' "accepted: $($r.Message)"
    Assert-Equal ((@($r.Accepted) | Sort-Object) -join ',') 'settings:git,settings:vscode' 'only the settings operations reopened'
    $o = Invoke-AppRuns
    Assert-Equal $o[-1] 'Finished:CompletedWithFollowUp' 'settings done; the manual Contoso Field Tool stays a follow-up'
    $res0 = Read-WddJson (Join-Path $script:Paths.Root 'Applications\result.json')
    Assert-Equal ((@($res0.outstanding) | ForEach-Object { $_.operationId } | Sort-Object) -join ',') 'additional:migration-app-000000000003,app:catalog:rustdesk' 'only the manual installations (Contoso, RustDesk of Core Essentials) are outstanding'
    foreach ($id in 'Microsoft.VisualStudioCode', 'Git.Git') { Assert-Equal $script:AppSim.Calls[$id] 1 "$id was not installed again" }
    $res = Read-WddJson (Join-Path $script:Paths.Root 'Applications\result.json')
    Assert-Equal ((@($res.settings) | ForEach-Object { "$($_.id)=$($_.restoreOutcome)" }) -join ';') 'git=KeptExisting;vscode=ConfigurationRestored' 'existing Git settings kept by policy'
    Assert-True ([IO.File]::ReadAllText((Join-Path $script:WdbEnv.USERPROFILE '.gitconfig')) -match 'Already Here') 'existing file untouched'
    $again = Invoke-WdrRestoreSettings $script:Manifest $script:Paths $good
    Assert-Equal $again.Outcome 'NothingToDo' 'restored settings are never repeated'
}

}

Write-Output ''
Write-Output "$($script:Passed) passed, $($script:Failures) failed"
if ($script:Failures -gt 0) { exit 1 }
exit 0
