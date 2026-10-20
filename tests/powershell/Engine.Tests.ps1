#Requires -Version 5.1
<#
    Scenario tests for WindowsUpdateEngine.ps1 against a simulated Windows Update Agent.
    The engine is dot-sourced (which only defines its functions) and every function that touches
    the system is replaced by a simulation. Nothing is scanned, installed or restarted.

    Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\powershell\Engine.Tests.ps1
#>
$ErrorActionPreference = 'Stop'
$enginePath = Join-Path $PSScriptRoot '..\..\src\engine\windows-update\scripts\WindowsUpdateEngine.ps1'
. $enginePath

$script:Failures = 0
$script:Passed = 0

function Assert-Equal($Actual, $Expected, [string] $Message) {
    if ("$Actual" -ne "$Expected") { throw "ASSERT: $Message. Expected <$Expected>, got <$Actual>." }
}
function Assert-True($Value, [string] $Message) { if (-not $Value) { throw "ASSERT: $Message" } }

# ------------------------------------------------------------------------------------------------
# Simulated machine
# ------------------------------------------------------------------------------------------------

function New-SimUpdate {
    param([string] $Kb, [string] $Behavior = 'ok', [switch] $Driver, [switch] $Upgrade, [switch] $Optional, [switch] $Interactive, [int] $AppearsAfterReboot = 0)
    @{ Id = "id-$Kb"; Revision = 1; Title = "Update $Kb"; Kbs = @($Kb); IsDriver = [bool] $Driver; IsUpgrade = [bool] $Upgrade
       IsOptional = [bool] $Optional; NeedsUserInput = [bool] $Interactive; IsDownloaded = $false; Native = $null
       Behavior = $Behavior; AppearsAfterReboot = $AppearsAfterReboot; Installed = $false; InstallCalls = 0 }
}

function Reset-Sim {
    param([object[]] $Updates = @(), [bool] $Online = $true, [int] $OnlineAfterBoot = 0)
    $script:Sim = @{
        Now = [DateTime]::new(2026, 10, 19, 12, 0, 0, [DateTimeKind]::Utc)
        Updates = @($Updates); Boots = 0; Online = $Online; OnlineAfterBoot = $OnlineAfterBoot
        RebootPending = $false; RebootRequested = $false; Resets = 0; Events = @(); TaskRemoved = $false
        ScanThrows = 0; InstallThrows = $false; UnexpectedThrows = $false; Busy = 0; LockPolls = 0
    }
}

function Get-WduNow { $script:Sim.Now }
function Wait-Wdu { param([int] $Seconds) $script:Sim.Now = $script:Sim.Now.AddSeconds($Seconds) }
function Test-WduNetwork { $script:Sim.Online -or ($script:Sim.OnlineAfterBoot -gt 0 -and $script:Sim.Boots -ge $script:Sim.OnlineAfterBoot) }
function Test-WduInstallerBusy { if ($script:Sim.UnexpectedThrows) { throw 'Simulated unexpected engine error' }; if ($script:Sim.Busy -gt 0) { $script:Sim.Busy--; return $true }; $false }
function Test-WduRebootPending { $script:Sim.RebootPending }
function Write-WduEvent { param([int] $EventId, [string] $Message, [string] $EntryType = 'Information') $script:Sim.Events += $EventId }
function Unregister-WduTask { param([hashtable] $Config) $script:Sim.TaskRemoved = $true }
function Reset-WduComponents { $script:Sim.Resets++ }
function Invoke-WduReboot { param([int] $WarningSeconds, [string] $Reason) $script:Sim.RebootRequested = $true }
function Wait-WdbLockPoll { $script:Sim.LockPolls++ }
function Get-WdbBootTime { "boot-$($script:Sim.Boots)" }

function Get-WduAvailableUpdates {
    param([hashtable] $Config)
    if ($script:Sim.ScanThrows -gt 0) { $script:Sim.ScanThrows--; throw (New-Object System.Runtime.InteropServices.COMException('Simulated scan failure', -2145124329)) }
    $list = @($script:Sim.Updates | Where-Object {
        -not $_.Installed -and $script:Sim.Boots -ge $_.AppearsAfterReboot -and ($Config.drivers -eq 'include' -or -not $_.IsDriver)
    })
    return , $list
}

function Invoke-WduDownload {
    param([object[]] $Updates)
    $out = @{}
    foreach ($u in $Updates) { $out[$u.Id] = @{ Result = $(if ($u.Behavior -eq 'download-fail') { 'Failed' } else { 'Succeeded' }); HResult = $(if ($u.Behavior -eq 'download-fail') { -2145107924 } else { 0 }) } }
    $out
}

function Invoke-WduInstall {
    param([object[]] $Updates)
    if ($script:Sim.InstallThrows) { throw 'Simulated unexpected engine error' }
    $out = @{ RebootRequired = $false; Results = @{} }
    foreach ($u in $Updates) {
        $u.InstallCalls++
        switch ($u.Behavior) {
            'ok'        { $u.Installed = $true; $out.Results[$u.Id] = @{ Result = 'Succeeded'; HResult = 0 } }
            'ok-reboot' { $u.Installed = $true; $out.RebootRequired = $true; $script:Sim.RebootPending = $true; $out.Results[$u.Id] = @{ Result = 'Succeeded'; HResult = 0 } }
            'reoffer'   { $out.Results[$u.Id] = @{ Result = 'Succeeded'; HResult = 0 } }
            'fail'      { $out.Results[$u.Id] = @{ Result = 'Failed'; HResult = -2145124330 } }
            'fail-once' { if ($u.InstallCalls -ge 2) { $u.Installed = $true; $out.Results[$u.Id] = @{ Result = 'Succeeded'; HResult = 0 } } else { $out.Results[$u.Id] = @{ Result = 'Failed'; HResult = -2145124330 } } }
        }
    }
    $out
}

function New-TestConfig {
    param([hashtable] $Overrides = @{})
    $root = Join-Path ([IO.Path]::GetTempPath()) ("wdu-test-" + [Guid]::NewGuid().ToString('N'))
    $c = @{
        dataRoot = $root; taskPath = '\WdbTest\'; taskName = 'WindowsUpdate'; mutexName = "Local\wdu-test-$([Guid]::NewGuid().ToString('N'))"
        drivers = 'exclude'; featureUpdates = 'skip'; optionalUpdates = 'skip'; microsoftUpdate = $false
        maxReboots = 10; maxAttemptsPerUpdate = 2; maxRuntimeHours = 6; maxErrors = 5; networkWaitMinutes = 15
        confirmationScans = 1; confirmationDelaySeconds = 60; resetComponentsOnce = $true; rebootWarningSeconds = 60
        initialDelaySeconds = 60; excludedKbs = @(); lockWaitMinutes = 1
    }
    foreach ($k in $Overrides.Keys) { $c[$k] = $Overrides[$k] }
    $c
}

<# Runs the engine like the scheduled task would: once per boot, until it stops asking for restarts. #>
function Invoke-Boots {
    param([hashtable] $Config, [int] $MaxBoots = 40, [int] $HoursBetweenOfflineStarts = 1)
    $outcomes = @()
    for ($i = 0; $i -lt $MaxBoots; $i++) {
        $script:Sim.RebootRequested = $false
        $o = Invoke-WduMain $Config
        $outcomes += $o
        if ($o -eq 'Rebooting') {
            Assert-True $script:Sim.RebootRequested 'engine returned Rebooting without requesting a restart'
            $script:Sim.Boots++; $script:Sim.RebootPending = $false; $script:Sim.Now = $script:Sim.Now.AddMinutes(5)
            continue
        }
        if ($o -eq 'WaitingForNetwork' -or $o -eq 'Error') { $script:Sim.Now = $script:Sim.Now.AddHours($HoursBetweenOfflineStarts); continue }
        break
    }
    , $outcomes
}

function Get-Result { param([hashtable] $Config) Get-Content -LiteralPath (Join-Path $Config.dataRoot 'Updates\result.json') -Raw | ConvertFrom-Json }
function Test-Marker { param([hashtable] $Config) Test-Path -LiteralPath (Join-Path $Config.dataRoot 'state\windows-update.done') }

$tests = [ordered]@{}

$tests['clean machine: confirmation scan, Succeeded, marker, task removed'] = {
    Reset-Sim
    $c = New-TestConfig
    $o = Invoke-Boots $c
    Assert-Equal ($o -join ',') 'Finished:Succeeded' 'outcome'
    $r = Get-Result $c
    Assert-Equal $r.status 'Succeeded' 'status'
    Assert-Equal $r.reboots 0 'reboots'
    Assert-True (Test-Marker $c) 'completion marker written'
    Assert-True $script:Sim.TaskRemoved 'task removed'
    Assert-True ($script:Sim.Events -contains 1000 -and $script:Sim.Events -contains 1100) 'start and success events'
}

$tests['installs, reboots, resumes and finds follow-up updates'] = {
    Reset-Sim @((New-SimUpdate KB1000001 'ok-reboot'), (New-SimUpdate KB1000002 'ok'), (New-SimUpdate KB1000003 'ok-reboot' -AppearsAfterReboot 1))
    $c = New-TestConfig
    $o = Invoke-Boots $c
    Assert-Equal ($o -join ',') 'Rebooting,Rebooting,Finished:Succeeded' 'outcomes'
    $r = Get-Result $c
    Assert-Equal $r.status 'Succeeded' 'status'
    Assert-Equal $r.reboots 2 'reboots'
    Assert-Equal (@($r.installed).Count) 3 'installed count'
    Assert-Equal $r.starts 3 'starts'
}

$tests['re-offered update is given up: CompletedWithFailures, no infinite loop'] = {
    Reset-Sim @((New-SimUpdate KB2000001 'reoffer'), (New-SimUpdate KB2000002 'ok'))
    $c = New-TestConfig @{ resetComponentsOnce = $false }
    $o = Invoke-Boots $c
    Assert-Equal ($o[-1]) 'Finished:CompletedWithFailures' 'final outcome'
    $r = Get-Result $c
    Assert-Equal (@($r.failed).Count) 1 'one failed update'
    Assert-Equal $r.failed[0].kbs[0] 'KB2000001' 'failed KB'
    Assert-Equal $r.failed[0].attempts 2 'attempts recorded'
    Assert-Equal $script:Sim.Updates[0].InstallCalls 2 'install attempted exactly maxAttempts times'
    Assert-True (Test-Marker $c) 'marker written for CompletedWithFailures'
    Assert-True ($script:Sim.Events -contains 1101) 'warning event'
}

$tests['failing update triggers one component reset and one extra attempt'] = {
    Reset-Sim @((New-SimUpdate KB3000001 'fail'))
    $c = New-TestConfig
    $o = Invoke-Boots $c
    Assert-Equal $script:Sim.Resets 1 'exactly one reset'
    Assert-Equal $o[-1] 'Finished:CompletedWithFailures' 'final outcome'
    Assert-Equal $script:Sim.Updates[0].InstallCalls 3 'two attempts plus one after reset'
    $r = Get-Result $c
    Assert-Equal $r.failed[0].lastHResult '0x80240016' 'HResult recorded'
}

$tests['update that fails once then succeeds counts as installed'] = {
    Reset-Sim @((New-SimUpdate KB3100001 'fail-once'))
    $c = New-TestConfig
    $o = Invoke-Boots $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'final outcome'
    Assert-Equal $script:Sim.Resets 0 'no reset needed'
}

$tests['download failures count as attempts'] = {
    Reset-Sim @((New-SimUpdate KB3200001 'download-fail'))
    $c = New-TestConfig @{ resetComponentsOnce = $false }
    $o = Invoke-Boots $c
    Assert-Equal $o[-1] 'Finished:CompletedWithFailures' 'final outcome'
    Assert-Equal (Get-Result $c).failed[0].lastResult 'DownloadFailed' 'download failure recorded'
}

$tests['reboot limit stops the engine with Failed'] = {
    $updates = @(1..8 | ForEach-Object { New-SimUpdate ("KB40000{0:D2}" -f $_) 'ok-reboot' -AppearsAfterReboot ($_ - 1) })
    Reset-Sim $updates
    $c = New-TestConfig @{ maxReboots = 3 }
    $o = Invoke-Boots $c
    Assert-Equal ($o -join ',') 'Rebooting,Rebooting,Rebooting,Finished:Failed' 'outcomes'
    $r = Get-Result $c
    Assert-True ($r.reason -like 'Reboot limit (3)*') "reason: $($r.reason)"
    Assert-True (-not (Test-Marker $c)) 'no completion marker on Failed'
    Assert-True ($script:Sim.Events -contains 1102) 'error event'
}

$tests['policy: feature, driver, optional, interactive and excluded KB updates are skipped'] = {
    Reset-Sim @(
        (New-SimUpdate KB5000001 'ok' -Upgrade), (New-SimUpdate KB5000002 'ok' -Driver), (New-SimUpdate KB5000003 'ok' -Optional),
        (New-SimUpdate KB5000004 'ok' -Interactive), (New-SimUpdate KB5000005 'ok'), (New-SimUpdate KB5000006 'ok'))
    $c = New-TestConfig @{ excludedKbs = @('KB5000005') }
    $o = Invoke-Boots $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'skips are not failures'
    $installed = @($script:Sim.Updates | Where-Object { $_.Installed } | ForEach-Object { $_.Kbs[0] })
    Assert-Equal ($installed -join ',') 'KB5000006' 'only the plain update is installed'
    $reasons = @((Get-Result $c).skipped | ForEach-Object { $_.reason })
    Assert-True ($reasons -match 'feature update') 'feature update reason'
    Assert-True ($reasons -match 'optional') 'optional reason'
    Assert-True ($reasons -match 'user input') 'interactive reason'
    Assert-True ($reasons -match 'excluded by configuration') 'excluded reason'
}

$tests['policy: drivers, feature and optional updates install when allowed'] = {
    Reset-Sim @((New-SimUpdate KB5100001 'ok' -Upgrade), (New-SimUpdate KB5100002 'ok' -Driver), (New-SimUpdate KB5100003 'ok' -Optional))
    $c = New-TestConfig @{ drivers = 'include'; featureUpdates = 'install'; optionalUpdates = 'install' }
    $o = Invoke-Boots $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'outcome'
    Assert-Equal (@($script:Sim.Updates | Where-Object { $_.Installed }).Count) 3 'all installed'
}

$tests['offline until the runtime limit ends as Offline, never Succeeded'] = {
    Reset-Sim -Updates @((New-SimUpdate KB6000001 'ok')) -Online $false
    $c = New-TestConfig @{ maxRuntimeHours = 3 }
    $o = Invoke-Boots $c
    Assert-Equal $o[-1] 'Finished:Offline' 'final outcome'
    Assert-True ($o -contains 'WaitingForNetwork') 'waited for network first'
    Assert-True (-not (Test-Marker $c)) 'no marker when offline'
    Assert-True ($script:Sim.Events -contains 1103) 'offline event'
}

$tests['network arriving later resumes the run'] = {
    Reset-Sim -Updates @((New-SimUpdate KB6100001 'ok')) -Online $false
    $c = New-TestConfig
    $o1 = Invoke-WduMain $c
    Assert-Equal $o1 'WaitingForNetwork' 'first start offline'
    $script:Sim.Online = $true; $script:Sim.Now = $script:Sim.Now.AddMinutes(30)
    $o2 = Invoke-WduMain $c
    Assert-Equal $o2 'Finished:Succeeded' 'second start completes'
}

$tests['scan failures: one component reset, then Failed'] = {
    Reset-Sim
    $script:Sim.ScanThrows = 100
    $c = New-TestConfig
    $o = Invoke-Boots $c
    Assert-Equal $o[-1] 'Finished:Failed' 'final outcome'
    Assert-Equal $script:Sim.Resets 1 'one reset'
    Assert-True ((Get-Result $c).reason -like '*scan keeps failing*') 'reason'
}

$tests['transient scan failure is retried'] = {
    Reset-Sim @((New-SimUpdate KB6200001 'ok'))
    $script:Sim.ScanThrows = 2
    $c = New-TestConfig
    Assert-Equal (Invoke-WduMain $c) 'Finished:Succeeded' 'outcome'
    Assert-Equal $script:Sim.Resets 0 'no reset'
}

$tests['unexpected errors are retried, then Failed after maxErrors'] = {
    Reset-Sim @((New-SimUpdate KB7000001 'ok'))
    $script:Sim.UnexpectedThrows = $true
    $c = New-TestConfig @{ maxErrors = 3 }
    $o = Invoke-Boots $c -HoursBetweenOfflineStarts 0
    Assert-Equal ($o -join ',') 'Error,Error,Finished:Failed' 'outcomes'
    Assert-True ((Get-Result $c).reason -like 'Stopped after 3 unexpected errors*') 'reason'
}

$tests['a crash during installation counts as an attempt'] = {
    Reset-Sim @((New-SimUpdate KB7000002 'ok'))
    $script:Sim.InstallThrows = $true
    $c = New-TestConfig @{ maxErrors = 10; resetComponentsOnce = $false }
    $o = Invoke-Boots $c -HoursBetweenOfflineStarts 0
    Assert-Equal ($o -join ',') 'Error,Error,Finished:CompletedWithFailures' 'outcomes'
}

$tests['waits while the Windows Update installer is busy'] = {
    Reset-Sim @((New-SimUpdate KB7100001 'ok'))
    $script:Sim.Busy = 3
    $c = New-TestConfig
    Assert-Equal (Invoke-WduMain $c) 'Finished:Succeeded' 'outcome'
    Assert-Equal $script:Sim.Busy 0 'busy checks consumed'
}

$tests['finished run does nothing on later starts'] = {
    Reset-Sim
    $c = New-TestConfig
    [void] (Invoke-WduMain $c)
    $script:Sim.TaskRemoved = $false
    Assert-Equal (Invoke-WduMain $c) 'AlreadyFinished' 'second start'
    Assert-True $script:Sim.TaskRemoved 'task removal retried'
}

$tests['pending restart with nothing to install is completed first'] = {
    Reset-Sim
    $script:Sim.RebootPending = $true
    $c = New-TestConfig
    $o = Invoke-Boots $c
    Assert-Equal ($o -join ',') 'Rebooting,Finished:Succeeded' 'outcomes'
}

$tests['corrupt state file is kept aside and the run continues'] = {
    Reset-Sim
    $c = New-TestConfig
    $dir = Join-Path $c.dataRoot 'Updates'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'state.json') -Value '{ not json'
    Assert-Equal (Invoke-WduMain $c) 'Finished:Succeeded' 'outcome'
    Assert-True (Test-Path -LiteralPath (Join-Path $dir 'state.json.corrupt')) 'corrupt copy kept'
}

$tests['only one engine instance runs at a time'] = {
    Reset-Sim
    $c = New-TestConfig
    $job = Start-Job -ArgumentList $c.mutexName -ScriptBlock {
        param($name)
        $m = New-Object System.Threading.Mutex($false, $name)
        [void] $m.WaitOne()
        Start-Sleep -Seconds 20
        $m.ReleaseMutex()
    }
    try {
        Start-Sleep -Seconds 3
        Assert-Equal (Invoke-WduMain $c) 'AlreadyRunning' 'second instance exits'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $c.dataRoot 'Updates\state.json'))) 'second instance wrote no state'
    } finally {
        $job | Stop-Job -PassThru | Remove-Job -Force
    }
}

$tests['log records progress and failures'] = {
    Reset-Sim @((New-SimUpdate KB8000001 'ok-reboot'), (New-SimUpdate KB8000002 'reoffer'))
    $c = New-TestConfig @{ resetComponentsOnce = $false }
    [void] (Invoke-Boots $c)
    $log = Get-Content -LiteralPath (Join-Path $c.dataRoot 'Updates\logs\engine.log') -Raw
    foreach ($needle in 'queued   KB8000001', 'installed KB8000001', 'Restart 1/10', 'FAILED   KB8000002', 'FINISHED: CompletedWithFailures') {
        Assert-True ($log.Contains($needle)) "log contains '$needle'"
    }
}

$tests['coordination: no update installation while the application engine holds the install lock'] = {
    Reset-Sim @((New-SimUpdate KB9000001 'ok'))
    $c = New-TestConfig
    $held = Enter-WdbInstallLock $c.dataRoot 'Applications' 0
    try {
        Assert-Equal (Invoke-WduMain $c) 'WaitingForLock' 'waits instead of installing'
        Assert-Equal $script:Sim.Updates[0].InstallCalls 0 'nothing installed while locked'
        Assert-True ($script:Sim.LockPolls -ge 12) 'polled for the configured wait'
        $s = Get-Content -LiteralPath (Join-Path $c.dataRoot 'Updates\state.json') -Raw | ConvertFrom-Json
        Assert-True ($null -eq $s.final) 'not final'
        Assert-Equal (@($s.attempts.PSObject.Properties).Count) 0 'no attempt counted'
    } finally { Exit-WdbInstallLock $held }
    Assert-Equal (Invoke-WduMain $c) 'Finished:Succeeded' 'installs once the lock is free'
}

$tests['coordination: restart deferred while an application installs, then taken'] = {
    Reset-Sim @((New-SimUpdate KB9100001 'ok-reboot'))
    $c = New-TestConfig
    $script:HeldLock = $null
    # The application engine grabs the lock right after the update installed (between install and restart).
    # Functions defined inside a test block shadow the simulation only for that block.
    function Invoke-WduInstall {
        param([object[]] $Updates)
        $u = $Updates[0]; $u.InstallCalls++; $u.Installed = $true; $script:Sim.RebootPending = $true
        @{ RebootRequired = $true; Results = @{ $u.Id = @{ Result = 'Succeeded'; HResult = 0 } } }
    }
    function Exit-WdbInstallLock { param($Lock) if ($Lock) { $Lock.Dispose() }; if (-not $script:HeldLock) { $script:HeldLock = Enter-WdbInstallLock $c.dataRoot 'Applications' 0 } }
    try {
        Assert-Equal (Invoke-WduMain $c) 'RebootDeferred' 'restart deferred'
        Assert-True (-not $script:Sim.RebootRequested) 'no restart requested while locked'
        $s = Get-Content -LiteralPath (Join-Path $c.dataRoot 'Updates\state.json') -Raw | ConvertFrom-Json
        Assert-Equal $s.reboots 0 'deferred restart is not counted'
    } finally { if ($script:HeldLock) { $script:HeldLock.Dispose() } }
}

$tests['coordination: restart marker written and lock held through the warning'] = {
    Reset-Sim @((New-SimUpdate KB9200001 'ok-reboot'))
    $c = New-TestConfig
    $script:SeenDuringReboot = $null
    function Invoke-WduReboot { param([int] $WarningSeconds, [string] $Reason)
        $script:Sim.RebootRequested = $true
        $other = Enter-WdbInstallLock $c.dataRoot 'Applications' 0
        $script:SeenDuringReboot = @{ LockFree = [bool] $other; Marker = (Test-WdbRestartPending $c.dataRoot) }
        Exit-WdbInstallLock $other
    }
    try {
        Assert-Equal (Invoke-WduMain $c) 'Rebooting' 'restarts'
        Assert-True (-not $script:SeenDuringReboot.LockFree) 'lock held while the restart is pending'
        Assert-True $script:SeenDuringReboot.Marker 'restart marker visible to the other engine'
        $script:Sim.Boots++
        Assert-True (-not (Test-WdbRestartPending $c.dataRoot)) 'marker is stale after the restart'
    } finally { $script:SeenDuringReboot = $null }
}

$tests['Get-WduConfig fills defaults and normalises KB numbers'] = {
    $p = Join-Path ([IO.Path]::GetTempPath()) ("wdu-cfg-" + [Guid]::NewGuid().ToString('N') + '.json')
    Set-Content -LiteralPath $p -Value '{ "maxReboots": 4, "excludedKbs": ["kb5000001"] }'
    $cfg = Get-WduConfig $p
    Assert-Equal $cfg.maxReboots 4 'explicit value'
    Assert-Equal $cfg.maxAttemptsPerUpdate 2 'default value'
    Assert-Equal $cfg.lockWaitMinutes 60 'coordination default for configs written before 1.1.0'
    Assert-Equal ($cfg.excludedKbs -join ',') 'KB5000001' 'normalised KB'
    Remove-Item -LiteralPath $p
}

foreach ($name in $tests.Keys) {
    try {
        & $tests[$name]
        $script:Passed++
        Write-Output "  ok    $name"
    } catch {
        $script:Failures++
        Write-Output "  FAIL  $name`n        $($_.Exception.Message)`n        $($_.InvocationInfo.PositionMessage -replace "`n", "`n        ")"
    }
}
Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'wdu-test-*' -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "$($script:Passed) passed, $($script:Failures) failed"
if ($script:Failures -gt 0) { exit 1 }
exit 0
