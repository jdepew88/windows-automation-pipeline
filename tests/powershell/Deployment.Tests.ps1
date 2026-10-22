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
    $job = Start-Job -ScriptBlock { param($n) $x = New-Object System.Threading.Mutex($false, $n); [void]$x.WaitOne(); Start-Sleep -Seconds 8; $x.ReleaseMutex() } -ArgumentList $script:MutexName
    Start-Sleep -Seconds 2
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

Write-Output ''
Write-Output "$($script:Passed) passed, $($script:Failures) failed"
if ($script:Failures -gt 0) { exit 1 }
exit 0
