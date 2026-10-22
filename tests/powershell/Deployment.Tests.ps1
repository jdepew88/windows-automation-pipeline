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

function Assert-Equal($Actual, $Expected, [string] $Message) { if ("$Actual" -ne "$Expected") { throw "ASSERT: $Message. Expected <$Expected>, got <$Actual>." } }
function Assert-True($Value, [string] $Message) { if (-not $Value) { throw "ASSERT: $Message" } }

# ------------------------------------------------------------------------------------------------
# Simulated machine
# ------------------------------------------------------------------------------------------------

function Reset-Sim {
    # Phase 6 scenarios switch to the migration package; every scenario starts with the main one.
    $script:usb = Join-Path $Fixture 'usb'
    $script:pkgRoot = Join-Path $script:usb 'WindowsDeployment'
    $script:manifestPath = Join-Path $script:pkgRoot 'deployment-manifest.json'
    $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ("wdd-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Tmp | Out-Null
    $script:SimNow = [DateTime]::new(2026, 10, 20, 8, 0, 0, [DateTimeKind]::Utc)
    $script:SimBoot = $script:SimNow.AddMinutes(-5)
    $script:SimIdentity = @{ Name = 'PC\Alex'; IsSystem = $false; IsAdmin = $true }
    $script:SimWinPE = $false
    $script:SimTasks = @{}
    $script:Installers = New-Object System.Collections.Generic.List[string]
    $script:InstallerBehaviour = @{}   # leaf name -> 'ok' | 'noTask' | 'throw'
    $script:Events = New-Object System.Collections.Generic.List[int]
    $script:Shortcuts = @{}
    $script:Consoles = 0
    $script:AclCalls = 0
    $script:Paths = Get-WddPaths (Join-Path $script:Tmp 'ProgramData\WindowsDeploymentBuilder')
    $script:Manifest = Read-WddManifest $manifestPath
    # Phase 4.3 ongoing update policy: edition, management and the AU policy values.
    $script:SimEdition = 'Professional'
    $script:SimManaged = @()
    $script:SimAu = @{}
    $script:SimAuWrites = 0
    $script:SimAuFail = $false
}

function Get-WddNow { $script:SimNow }
function Get-WddBootTime { $script:SimBoot }
function Get-WddIdentity { $script:SimIdentity }
function Test-WddWinPE { $script:SimWinPE }
function Get-WddTask { param([string] $TaskPath, [string] $TaskName) $script:SimTasks.ContainsKey("$TaskPath$TaskName") }
function Unregister-WddTask { param([string] $TaskPath, [string] $TaskName) $script:SimTasks.Remove("$TaskPath$TaskName") }
function Start-WddTask { param([string] $TaskPath, [string] $TaskName) }
function Register-WddMonitorTask { param([hashtable] $Paths, [hashtable] $Manifest) $script:SimTasks['\WindowsDeploymentBuilder\Deployment'] = 'SYSTEM' }
function Set-WddAcl { param([string] $Root) $script:AclCalls++ }
function New-WddShortcut { param([string] $Name, [string] $Target, [string] $Arguments, [string] $Description) $script:Shortcuts[$Name] = $Arguments }
function Remove-WddShortcut { param([string] $Name) $script:Shortcuts.Remove($Name) }
function Start-WddConsole { param([hashtable] $Paths) $script:Consoles++ }
function Write-WddEvent { param([int] $EventId, [string] $Message, [string] $EntryType = 'Information') $script:Events.Add($EventId) }
function Get-WddSystemInfo { [ordered]@{ computerName = 'ALEX-COMPUTER'; windows = 'Microsoft Windows 11 Pro'; edition = 'Professional'; displayVersion = '25H2'; build = '26200.1'; installDateUtc = '2026-10-20T07:00:00Z'; manufacturer = 'Sim'; model = 'VM' } }
function Invoke-WddInstaller {
    param([string] $Path)
    $leaf = Split-Path -Leaf $Path
    $script:Installers.Add($leaf)
    if (-not (Test-Path -LiteralPath $Path)) { throw "installer not staged: $Path" }
    $b = if ($script:InstallerBehaviour.ContainsKey($leaf)) { $script:InstallerBehaviour[$leaf] } else { 'ok' }
    if ($b -eq 'throw') { throw 'simulated installer crash' }
    if ($b -eq 'noTask') { return 1 }
    $task = if ($leaf -eq 'Install-UpdateEngine.ps1') { '\WindowsDeploymentBuilder\WindowsUpdate' } else { '\WindowsDeploymentBuilder\Applications' }
    $script:SimTasks[$task] = $script:SimIdentity.Name
    # Like the real installers: a new installation archives the engine's previous run.
    $dir = Join-Path $script:Paths.Root $(if ($leaf -eq 'Install-UpdateEngine.ps1') { 'Updates' } else { 'Applications' })
    foreach ($n in 'state.json', 'result.json', 'status.json') { $f = Join-Path $dir $n; if (Test-Path -LiteralPath $f) { Move-Item -LiteralPath $f -Destination "$f.$($script:Installers.Count).bak" -Force } }
    return 0
}

function Get-WddEditionId { $script:SimEdition }
function Get-WddUpdateManagement { $script:SimManaged }
function Get-WddAuPolicyValues {
    $o = @{}
    foreach ($n in 'NoAutoUpdate', 'AUOptions', 'ScheduledInstallDay', 'ScheduledInstallTime', 'NoAutoRebootWithLoggedOnUsers') { $o[$n] = $(if ($script:SimAu.ContainsKey($n)) { $script:SimAu[$n] } else { $null }) }
    return $o
}
function Set-WddAuPolicyValue { param([string] $Name, [int] $Value) if ($script:SimAuFail) { throw 'Access is denied' }; $script:SimAuWrites++; $script:SimAu[$Name] = $Value }

# Engines write these files themselves; the simulation writes them for the scenarios.
function Set-EngineResult {
    param([string] $Stage, [string] $Status, [hashtable] $Extra = @{})
    $dir = if ($Stage -eq 'windowsUpdate') { 'Updates' } else { 'Applications' }
    $r = @{ status = $Status; reason = "sim $Status"; reboots = 1; finishedUtc = $script:SimNow.ToString('o') }
    foreach ($k in $Extra.Keys) { $r[$k] = $Extra[$k] }
    Write-WddJson (Join-Path $script:Paths.Root "$dir\result.json") $r
    $task = if ($Stage -eq 'windowsUpdate') { '\WindowsDeploymentBuilder\WindowsUpdate' } else { '\WindowsDeploymentBuilder\Applications' }
    $script:SimTasks.Remove($task)   # engines remove their own task when they finish
}
function Set-EngineStatus {
    param([string] $Stage, [string] $Phase, [string] $Detail = '', [int] $Done = 0, [int] $Total = 0)
    $dir = if ($Stage -eq 'windowsUpdate') { 'Updates' } else { 'Applications' }
    Write-WddJson (Join-Path $script:Paths.Root "$dir\status.json") @{ phase = $Phase; detail = $Detail; updatedUtc = $script:SimNow.ToString('o'); reboots = 0; done = $Done; total = $Total }
}

# Real answer-file extraction: the generator's own ExtractScript, run on the generated XML with
# every target path moved below the temporary folder.
function Invoke-SimExtraction {
    $xml = New-Object System.Xml.XmlDocument
    $xml.Load((Join-Path $usb 'autounattend.xml'))
    $root = Join-Path $script:Tmp 'Windows\Setup\Scripts'
    foreach ($f in $xml.unattend.Extensions.File) {
        $p = $f.GetAttribute('path')
        if (-not $p.StartsWith('C:\Windows\Setup\Scripts\', [StringComparison]::OrdinalIgnoreCase)) { throw "unexpected embedded path $p" }
        $f.SetAttribute('path', (Join-Path $root $p.Substring('C:\Windows\Setup\Scripts\'.Length)))
    }
    $sb = [scriptblock]::Create($xml.unattend.Extensions.ExtractScript)
    Invoke-Command -ScriptBlock $sb -ArgumentList $xml | Out-Null
    return $root
}

function Initialize-Embedded {
    $emb = Invoke-SimExtraction
    $src = Join-Path $emb 'Deployment'
    Invoke-WddInitialize $script:Manifest (Join-Path $src 'deployment-manifest.json') 'Embedded' $src $emb $script:Paths -NoConsole
}

function Test-Scenario {
    param([string] $Name, [scriptblock] $Body)
    Reset-Sim
    try {
        & $Body
        $script:Passed++
        Write-Output "  ok    $Name"
    } catch {
        $script:Failures++
        Write-Output "  FAIL  $Name"
        Write-Output "        $($_.Exception.Message)"
        Write-Output "        $($_.InvocationInfo.PositionMessage -replace "`n", "`n        ")"
    } finally {
        $script:WddLogFile = $null
        Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

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
    Assert-Equal $r.drivers.state 'NotImplemented' 'drivers not claimed'
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

function Reset-AppSim {
    param([hashtable] $Behaviour = @{})
    $script:AppSim = @{ Behaviour = $Behaviour; Installed = @{}; Calls = @{}; Online = $true; SourceDown = @(); Order = New-Object System.Collections.Generic.List[string]; Reboots = 0; ResumeInstalls = 0 }
    $script:AppMutex = "Local\wda-dt-$([guid]::NewGuid().ToString('N'))"
}
function Get-WdaNow { $script:SimNow }
function Wait-Wda { param([int] $Seconds) $script:SimNow = $script:SimNow.AddSeconds($Seconds) }
function Get-WdaContext { @{ User = $script:SimIdentity.Name; IsSystem = $script:SimIdentity.IsSystem; IsElevated = $true } }
function Test-WdaNetwork { $script:AppSim.Online }
function Get-WdaNetworkDiagnosis {
    param([string] $Source = 'winget')
    if (-not $script:AppSim.Online) { return @{ Level = 'InternetUnavailable'; Detail = 'simulated' } }
    if ($script:AppSim.SourceDown -contains $Source) { return @{ Level = 'SourceUnavailable'; Detail = 'simulated' } }
    @{ Level = 'Online'; Detail = 'simulated' }
}
function Get-WdaRandom { 0.5 }
function Test-WdaRebootPending { $false }
function Invoke-WdaReboot { param([int] $WarningSeconds, [string] $Reason) $script:AppSim.Reboots++ }
function Test-WdaUpdateTask { param([hashtable] $WU) $script:SimTasks.ContainsKey("$($WU.taskPath)$($WU.taskName)") }
function Unregister-WdaTask { param([hashtable] $Config) [void] $script:SimTasks.Remove("$($Config.taskPath)$($Config.taskName)") }
function Write-WdaEvent { param([int] $EventId, [string] $Message, [string] $EntryType = 'Information') $script:Events.Add($EventId) }
function Get-WdbBootTime { $script:SimBoot.ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Wait-WdbLockPoll { }
function Invoke-WgbBootstrap { param([switch] $CheckOnly, $AllowRegister, $AllowOnlineRepair, $OfflinePath, $MinimumVersion) @{ Status = 'Healthy'; Method = ''; Version = '1.29.250'; Message = 'WinGet 1.29.250 works.'; Path = 'C:\sim\winget.exe'; Steps = @() } }
function Get-WdaPortableRoots { @(Join-Path $script:Tmp 'WinGetPackages') }
function Get-WdaShortcutFolder { Join-Path $script:Tmp 'StartMenu' }
function New-WdaShortcutFile { param([string] $Path, [string] $Target) [IO.File]::WriteAllText($Path, $Target) }
function Test-WdaInstalled { param([hashtable] $P, [string] $LogFile = '') [bool] $script:AppSim.Installed[$P.packageIdentifier] }
function Test-WdaAvailable { param([hashtable] $P, [string] $LogFile = '') 'Available' }
function Install-WdaPackage {
    param([hashtable] $P, [int] $TimeoutMinutes, [string] $LogFile = '')
    $id = $P.packageIdentifier
    $n = 1 + [int] $script:AppSim.Calls[$id]
    $script:AppSim.Calls[$id] = $n
    $script:AppSim.Order.Add($id)
    $b = $(if ($script:AppSim.Behaviour.ContainsKey($id)) { $script:AppSim.Behaviour[$id] } else { 'ok' })
    $code = 0
    switch ($b) {
        'ok'         { $script:AppSim.Installed[$id] = $true }
        'fail'       { $code = 0x8A150008 }
        'fail-once'  { if ($n -ge 2) { $script:AppSim.Installed[$id] = $true } else { $code = 0x8A150008 } }
        'hash'       { $code = 0x8A150011 }
        'reboot-now' { if ($script:AppSim.Reboots -ge 1) { $script:AppSim.Installed[$id] = $true } else { $code = 0x8A15010A } }
        'net-drop'   { if ($n -eq 1) { $script:AppSim.Online = $false; $code = 0x8A150107 } else { $script:AppSim.Installed[$id] = $true } }
    }
    if ($script:AppSim.Installed[$id] -and $P.method -eq 'portable') {
        $dir = Join-Path (Join-Path $script:Tmp 'WinGetPackages') "$($id)_Microsoft.Winget.Source_8wekyb3d8bbwe"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir (($P.portable.executable) -replace '\*', '-4.6')), 'MZ')
    }
    @{ ExitCode = [int] $code; TimedOut = $false; Output = '' }
}

<# The engine configuration exactly as staged, with only its machine paths moved below the temporary folder. #>
function Get-SimAppConfig {
    $c = Get-WdaConfig (Join-Path $script:Paths.Package 'scripts\applications\applications-config.json')
    $c.dataRoot = $script:Paths.Root
    $c.mutexName = $script:AppMutex
    $c.coordination.windowsUpdate.stateFile = Join-Path $script:Paths.Root 'Updates\state.json'
    $c.coordination.windowsUpdate.resultFile = Join-Path $script:Paths.Root 'Updates\result.json'
    $c.gatePollMinutes = 1
    $c.lockWaitMinutes = 0
    return $c
}
function Get-WdrAppConfig { param([hashtable] $Paths) Get-SimAppConfig }
function Invoke-WdrAppInstaller { param([hashtable] $Paths) $script:AppSim.ResumeInstalls++; $script:SimTasks['\WindowsDeploymentBuilder\Applications'] = $script:SimIdentity.Name; return 0 }

<# The application task: at sign-in and hourly, plus a simulated restart when the engine asks for one. #>
function Invoke-AppRuns {
    param([int] $Max = 25)
    $out = @()
    for ($i = 0; $i -lt $Max; $i++) {
        $o = Invoke-WdaMain (Get-SimAppConfig)
        $out += $o
        if ($o -eq 'Rebooting') { $script:SimNow = $script:SimNow.AddMinutes(3); $script:SimBoot = $script:SimNow; $script:SimNow = $script:SimNow.AddMinutes(2); continue }
        if ($o -like 'Finished:*' -or $o -eq 'AlreadyFinished') { break }
        $script:SimNow = $script:SimNow.AddHours(1)
    }
    , $out
}
function Get-AppResult { Read-WddJson (Join-Path $script:Paths.Root 'Applications\result.json') }
function Get-AppPkg { param($Result, [string] $Id) @($Result.packages) | Where-Object { $_.packageIdentifier -eq $Id } | Select-Object -First 1 }
$script:FixtureApps = @('Google.Chrome', 'VideoLAN.VLC', '7zip.7zip', 'CodeSector.TeraCopy', 'Bitwarden.Bitwarden', 'Microsoft.VCRedist.2015+.x64', 'Microsoft.VCRedist.2015+.x86', '9NP83LWLPZ9K', 'Rufus.Rufus', 'Git.Git', 'Example.TestPackage')

Test-Scenario 'Phase 5 package: recovery tool shipped, embedded, staged; manifest declares recovery and state schemas' {
    $f = @($script:Manifest.files | Where-Object { $_.path -eq 'scripts/recovery/DeploymentRecovery.ps1' })
    Assert-Equal $f.Count 1 'listed in the manifest'
    Assert-Equal $f[0].embedded 'Deployment\scripts\recovery\DeploymentRecovery.ps1' 'embedded in the answer file'
    Assert-Equal $script:Manifest.recovery.tool 'scripts/recovery/DeploymentRecovery.ps1' 'manifest recovery block'
    Assert-Equal "$($script:Manifest.recovery.stateSchemas.deploymentState) $($script:Manifest.recovery.stateSchemas.applicationState) $($script:Manifest.recovery.stateSchemas.applicationResult)" '2 2 2' 'state schema versions'
    Assert-Equal $script:Manifest.recovery.outcomeCodes.PausedAwaitingNetwork 30 'outcome codes'
    $cfg = Read-WddJson (Join-Path $pkgRoot 'scripts\applications\applications-config.json')
    Assert-Equal "$($cfg.engineVersion) $($cfg.maxAttemptsPerPackage) $($cfg.retry.automatic) $($cfg.retry.baseDelaySeconds)" '1.3.0 3 True 60' 'retry configuration'
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

$migFixture = Join-Path $Fixture 'migration'
if (Test-Path -LiteralPath $migFixture) {
    . (Join-Path $migFixture 'usb\WindowsDeployment\scripts\applications\WdbMigration.ps1') -Mode Library
    Set-StrictMode -Off
}
$script:MigBackupFolder = 'WDB-AppBackup-20261021-120000-a1b2c3'

function Use-MigrationPackage {
    $script:usb = Join-Path $migFixture 'usb'
    $script:pkgRoot = Join-Path $script:usb 'WindowsDeployment'
    $script:manifestPath = Join-Path $script:pkgRoot 'deployment-manifest.json'
    $script:Manifest = Read-WddManifest $script:manifestPath
    $script:UsbBackups = Join-Path $script:pkgRoot 'backups'
    $home0 = Join-Path $script:Tmp 'Users\Alex'
    $script:WdbEnv = @{ USERPROFILE = $home0; APPDATA = "$home0\AppData\Roaming"; LOCALAPPDATA = "$home0\AppData\Local"; DOCUMENTS = "$home0\Documents"; PROGRAMFILES = (Join-Path $script:Tmp 'Program Files'); PROGRAMFILESX86 = (Join-Path $script:Tmp 'Program Files (x86)'); PROGRAMDATA = (Join-Path $script:Tmp 'ProgramData'); USERNAME = 'Alex' }
    New-Item -ItemType Directory -Path $script:WdbEnv.APPDATA, $script:WdbEnv.LOCALAPPDATA -Force | Out-Null
}
function Get-WdbEnvironment { $script:WdbEnv }
function Test-WdbProcessRunning { param([string] $Name) $false }
function Get-WdbUninstallEntries {
    $names = @{ 'Microsoft.VisualStudioCode' = 'Microsoft Visual Studio Code (User)'; 'Git.Git' = 'Git' }
    @($names.Keys | Where-Object { $script:AppSim.Installed[$_] } | ForEach-Object { @{ Hive = 'HKCU'; View = '64'; KeyName = $_; Values = @{ DisplayName = $names[$_]; DisplayVersion = '1.0' } } })
}
function Get-WdaBackupCandidates { param([hashtable] $Config, [string] $FolderName) @(@(Join-Path (Join-Path $Config.dataRoot 'Backup\incoming') $FolderName) + @($script:UsbBackups | Where-Object { $_ } | ForEach-Object { Join-Path $_ $FolderName })) }
function Protect-WdaBackupFolder { param([string] $Path) }

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
