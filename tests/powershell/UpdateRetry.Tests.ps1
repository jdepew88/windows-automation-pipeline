#Requires -Version 5.1
<#
    Tests for Invoke-WindowsUpdateRetry.ps1 (Retry Windows Update). The tool is dot-sourced (which
    only defines its functions); scheduled tasks, services, Windows Update history and devices are
    simulated. Nothing is searched, installed, registered or restarted; data lives in %TEMP%.

    Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\powershell\UpdateRetry.Tests.ps1
#>
$ErrorActionPreference = 'Stop'
$toolPath = Join-Path $PSScriptRoot '..\..\src\engine\windows-update\scripts\Invoke-WindowsUpdateRetry.ps1'
. $toolPath

$script:Failures = 0
$script:Passed = 0
function Assert-Equal($Actual, $Expected, [string] $Message) { if ("$Actual" -ne "$Expected") { throw "ASSERT: $Message. Expected <$Expected>, got <$Actual>." } }
function Assert-True($Value, [string] $Message) { if (-not $Value) { throw "ASSERT: $Message" } }

# Simulated machine
$script:Sim = @{}
function Reset-Sim {
    $script:Sim = @{ Admin = $true; Task = $null; Registered = @(); Started = 0; Pending = @(); Busy = $false; Devices = @(); Disabled = @()
        Now = [DateTime]::new(2026, 11, 27, 9, 0, 0, [DateTimeKind]::Utc) }
}
function Test-WurAdmin { $script:Sim.Admin }
function Get-WurNow { $script:Sim.Now = $script:Sim.Now.AddSeconds(1); $script:Sim.Now }
function Get-WurTask { $script:Sim.Task }
function Register-WurTask { param([string] $EnginePath, [string] $ConfigPath, [int] $MaxRuntimeHours) $script:Sim.Registered += , @($EnginePath, $ConfigPath); $script:Sim.Task = [pscustomobject]@{ State = 'Ready' } }
function Start-WurTask { $script:Sim.Started++ }
function Wait-WurPoll { param([int] $Seconds) }
function Get-WurServices { $o = [ordered]@{}; foreach ($n in 'wuauserv', 'bits', 'cryptsvc', 'TrustedInstaller') { $o[$n] = [ordered]@{ status = 'Running'; startType = $(if ($script:Sim.Disabled -contains $n) { 'Disabled' } else { 'Manual' }) } }; $o }
function Get-WurRestartPending { , @($script:Sim.Pending) }
function Test-WurInstallerBusy { $script:Sim.Busy }
function Get-WurDevices { , @($script:Sim.Devices) }
function Get-WurHistory { , @([ordered]@{ title = 'sim history'; resultCode = 2 }) }
function Get-WurEvents { @() }

function New-DataRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("wur-test-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root 'Updates') -Force | Out-Null
    $root
}

<# The field result of the spare computer: engine 1.3.0, 16 failures, all 0x80131508, nothing installed. #>
function Write-FieldResult {
    param([string] $Root)
    $failed = @(1..16 | ForEach-Object { [ordered]@{ id = "id-$_"; title = "Update $_"; kbs = @("KB50000$('{0:D2}' -f $_)"); lastHResult = '0x80131508'; lastResult = 'Failed'; errorSource = 'engine'; attempts = 3 } })
    $r = [ordered]@{ status = 'CompletedWithFailures'; reason = '16 update(s) could not be installed'; engineVersion = '1.3.0'; installed = @(); failed = $failed; skipped = @(); requiresInteraction = @(); reboots = 2; finishedUtc = '2026-11-26T08:00:00Z' }
    Write-WurJson (Join-Path $Root 'Updates\result.json') $r
    Write-WurJson (Join-Path $Root 'Updates\config.json') @{ drivers = 'include'; optionalUpdates = 'install'; featureUpdates = 'skip'; microsoftUpdate = $false; excludedKbs = @('KB5099999'); maxAttemptsPerUpdate = 3 }
}

$tests = [ordered]@{}

$tests['status recognises the 1.x collection defect in the original result and says what to do'] = {
    Reset-Sim
    $root = New-DataRoot; Write-FieldResult $root
    $s = Get-WurStatus $root
    Assert-Equal "$($s.original.failed) $($s.original.installed) $($s.original.collectionDefect)" '16 0 True' 'defect detected'
    Assert-Equal $s.original.failedByHResult['0x80131508'] 16 'failures by code'
    Assert-True (@($s.advice | Where-Object { $_ -like '*collection defect*RetryUpdates*RetryDrivers*' }).Count -eq 1) 'advice names the retry modes'
    $text = Show-WurStatus $s
    Assert-True ($text -match 'engine 1.x collection defect') 'shown to the technician'
}

$tests['status is read-only: nothing is registered, started or written'] = {
    Reset-Sim
    $root = New-DataRoot; Write-FieldResult $root
    $before = @(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" })
    [void] (Get-WurStatus $root)
    $after = @(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" })
    Assert-Equal ($after -join ';') ($before -join ';') 'no file changed'
    Assert-Equal "$(@($script:Sim.Registered).Count) $($script:Sim.Started)" '0 0' 'no task'
}

$tests['a genuine failure (not 0x80131508 everywhere) is not reported as the engine defect'] = {
    $r = @{ engineVersion = '1.3.0'; installed = @(@{ title = 'x' }); failed = @(@{ lastHResult = '0x80131508' }, @{ lastHResult = '0x80240017' }) }
    Assert-Equal (Get-WurResultSummary $r 'x').collectionDefect $false 'mixed failures with installations'
    $r2 = @{ engineVersion = '2.0.0'; installed = @(); failed = @(@{ lastHResult = '0x80131508' }) }
    Assert-Equal (Get-WurResultSummary $r2 'x').collectionDefect $false 'engine 2.x is not the 1.x defect'
}

$tests['retry configurations: own folder, marker and task; selection per mode; the deployment policy kept'] = {
    $root = New-DataRoot; Write-FieldResult $root
    $n = New-WurRunConfig $root 'normal' 'r1'
    Assert-Equal "$($n.workFolder) $($n.markerName) $($n.taskName)" 'UpdateRetry\r1 windows-update-retry.done WindowsUpdateRetry' 'separate from the original run'
    Assert-Equal "$($n.selection) $($n.drivers) $($n.optionalUpdates)" 'normal exclude skip' 'normal updates only'
    $d = New-WurRunConfig $root 'drivers' 'r2'
    Assert-Equal "$($d.selection) $($d.drivers) $($d.optionalUpdates)" 'drivers include install' 'drivers, optional ones included'
    $a = New-WurRunConfig $root 'all' 'r3'
    Assert-Equal "$($a.selection) $($a.drivers) $($a.optionalUpdates) $($a.featureUpdates)" 'configured include install skip' 'everything the policy allows, never feature updates'
    Assert-Equal ($a.excludedKbs -join ',') 'KB5099999' 'excluded KBs kept'
    Assert-Equal $a.mutexName 'Global\WindowsDeploymentBuilder-WindowsUpdate' 'never runs beside the deployment engine'
}

$tests['retry refuses without elevation or with Windows Update disabled; nothing is changed'] = {
    Reset-Sim
    $root = New-DataRoot; Write-FieldResult $root
    $script:Sim.Admin = $false
    $m = ''; try { [void] (Start-WurRetry $root 'normal') } catch { $m = $_.Exception.Message }
    Assert-True ($m -like '*elevated*') 'not elevated'
    $script:Sim.Admin = $true; $script:Sim.Disabled = @('wuauserv')
    $m = ''; try { [void] (Start-WurRetry $root 'normal') } catch { $m = $_.Exception.Message }
    Assert-True ($m -like '*wuauserv*disabled*nothing was changed*') 'service disabled'
    Assert-Equal "$(@($script:Sim.Registered).Count) $(Test-Path (Join-Path $root 'UpdateRetry'))" '0 False' 'nothing registered or created'
}

$tests['retry starts a new run with the corrected engine; the original records are untouched'] = {
    Reset-Sim
    $root = New-DataRoot; Write-FieldResult $root
    $orig = Get-Content -LiteralPath (Join-Path $root 'Updates\result.json') -Raw
    $run = Start-WurRetry $root 'normal'
    Assert-Equal "$($run.resumed) $($run.engineVersion -ge '2.0.0')" 'False True' 'new run, engine 2.x'
    Assert-True (Test-Path -LiteralPath $run.config) 'run configuration written'
    Assert-True (Test-Path -LiteralPath (Join-Path $root 'UpdateRetry\WindowsUpdateEngine.ps1')) 'engine copied beside the runs'
    Assert-Equal $script:Sim.Registered[0][1] $run.config 'task runs the engine with this configuration'
    Assert-Equal $script:Sim.Started 1 'started'
    Assert-Equal (Get-Content -LiteralPath (Join-Path $root 'Updates\result.json') -Raw) $orig 'original result unchanged'
}

$tests['an unfinished retry of the same kind is resumed; -Fresh starts a new run'] = {
    Reset-Sim
    $root = New-DataRoot; Write-FieldResult $root
    $r1 = Start-WurRetry $root 'normal'
    $r2 = Start-WurRetry $root 'normal'
    Assert-Equal "$($r2.resumed) $($r2.runId -eq $r1.runId)" 'True True' 'resumed'
    $r3 = Start-WurRetry $root 'normal' -Fresh
    Assert-Equal "$($r3.resumed) $($r3.runId -ne $r1.runId)" 'False True' 'fresh run'
    $r4 = Start-WurRetry $root 'drivers'
    Assert-Equal $r4.resumed $false 'another kind is a new run'
    # A finished run is never resumed.
    Write-WurJson (Join-Path $r4.folder 'state.json') @{ final = 'Succeeded' }
    $r5 = Start-WurRetry $root 'drivers'
    Assert-Equal $r5.resumed $false 'finished run not resumed'
}

$tests['comparison: original failures installed by the retry and those still failing; devices now'] = {
    Reset-Sim
    $root = New-DataRoot; Write-FieldResult $root
    $dir = Join-Path $root 'UpdateRetry\20261127-090000-normal'
    Write-WurJson (Join-Path $dir 'config.json') @{ selection = 'normal' }
    Write-WurJson (Join-Path $dir 'state.json') @{ final = 'CompletedWithFailures' }
    $inst = @(1..15 | ForEach-Object { [ordered]@{ title = "Update $_"; kbs = @("KB50000$('{0:D2}' -f $_)") } })
    Write-WurJson (Join-Path $dir 'result.json') ([ordered]@{ status = 'CompletedWithFailures'; engineVersion = '2.0.0'; installed = $inst; failed = @([ordered]@{ title = 'Update 16'; kbs = @('KB5000016'); lastHResult = '0x800F0922'; category = 'InstallerFailure' }); failedByCategory = @{ InstallerFailure = 1 }; reboots = 1; verification = @{ devicesWithProblems = @(@{ name = 'x' }) } })
    $script:Sim.Devices = @([ordered]@{ name = 'SM Bus Controller'; deviceId = 'PCI\VEN_8086'; problemCode = 28 })
    $c = Get-WurComparison $root
    Assert-Equal "$(@($c.runs).Count) $(@($c.originalFailuresInstalledByRetry).Count) $(@($c.originalFailuresStillFailing).Count)" '2 15 1' 'counts'
    $t = Format-WurComparison $c
    Assert-True ($t -match 'still  KB5000016 Update 16' -and $t -match 'code 28  SM Bus Controller') 'readable comparison'
}

$tests['diagnostics: a ZIP with copies of logs, results, the comparison and history; originals untouched'] = {
    Reset-Sim
    $root = New-DataRoot; Write-FieldResult $root
    [System.IO.File]::WriteAllText((Join-Path $root 'Updates\engine.ps1'), 'not exported')
    New-Item -ItemType Directory -Path (Join-Path $root 'Updates\logs') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $root 'Updates\logs\engine.log'), 'log line')
    $zip = Join-Path ([IO.Path]::GetTempPath()) ("wur-test-" + [Guid]::NewGuid().ToString('N') + '.zip')
    $r = Export-WurDiagnostics $root $zip
    Assert-True (Test-Path -LiteralPath $zip) 'zip written'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try { $names = @($z.Entries | ForEach-Object { $_.FullName -replace '\\', '/' }) } finally { $z.Dispose() }
    foreach ($n in 'Updates/result.json', 'Updates/logs/engine.log', 'comparison.txt', 'comparison.json', 'status.json', 'windows-update-history.json', 'devices-with-problems.json') { Assert-True ($names -contains $n) "contains $n" }
    Assert-True (-not ($names -contains 'Updates/engine.ps1')) 'scripts are not exported'
    Assert-True (Test-Path -LiteralPath (Join-Path $root 'Updates\logs\engine.log')) 'originals kept'
    Remove-Item -LiteralPath $zip -Force
}

$tests['the engine beside the tool must be 2.0.0 or later'] = {
    $e = Get-WurEnginePath
    Assert-True ([version] $e.version -ge [version] '2.0.0') "engine $($e.version)"
}

foreach ($name in $tests.Keys) {
    try { & $tests[$name]; $script:Passed++; Write-Output "  ok    $name" }
    catch { $script:Failures++; Write-Output "  FAIL  $name`n        $($_.Exception.Message)`n        $($_.InvocationInfo.PositionMessage -replace "`n", "`n        ")" }
}
Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'wur-test-*' -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "$($script:Passed) passed, $($script:Failures) failed"
if ($script:Failures -gt 0) { exit 1 }
exit 0
