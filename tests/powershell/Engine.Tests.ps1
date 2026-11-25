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
# Engine 1.3.0 scenarios call the real WUA adapters with a failing collection (nothing reaches Windows).
$script:RealWduInstall = ${function:Invoke-WduInstall}
$script:RealWduDownload = ${function:Invoke-WduDownload}

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
        DownloadCalls = @(); InstallBatches = @()
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
    $script:Sim.DownloadCalls += , @($Updates | ForEach-Object { $_.Kbs[0] })
    foreach ($u in $Updates) {
        if (-not $u.ContainsKey('DownloadCalls')) { $u.DownloadCalls = 0 }
        $u.DownloadCalls++
        # 0x8024402C WU_E_PT_WINHTTP_NAME_NOT_RESOLVED (transient)
        $fail = $u.Behavior -eq 'download-fail' -or ($u.Behavior -eq 'download-fail-once' -and $u.DownloadCalls -eq 1)
        $out[$u.Id] = @{ Result = $(if ($fail) { 'Failed' } else { 'Succeeded' }); HResult = $(if ($fail) { -2145107924 } else { 0 }) }
    }
    $out
}

function Invoke-WduInstall {
    param([object[]] $Updates)
    if ($script:Sim.InstallThrows) { throw 'Simulated unexpected engine error' }
    $out = @{ RebootRequired = $false; Results = @{} }
    $script:Sim.InstallBatches += , @($Updates | ForEach-Object { $_.Kbs[0] })
    foreach ($u in $Updates) {
        $u.InstallCalls++
        switch ($u.Behavior) {
            'ok'        { $u.Installed = $true; $out.Results[$u.Id] = @{ Result = 'Succeeded'; HResult = 0 } }
            'download-fail-once' { $u.Installed = $true; $out.Results[$u.Id] = @{ Result = 'Succeeded'; HResult = 0 } }
            # 0x80240020 WU_E_NO_INTERACTIVE_USER: Windows says a person is needed.
            'needs-person' { $out.Results[$u.Id] = @{ Result = 'Failed'; HResult = -2145124320 } }
            # 0x80240017 WU_E_NOT_APPLICABLE: permanent.
            'not-applicable' { $out.Results[$u.Id] = @{ Result = 'Failed'; HResult = -2145124329 } }
            'ok-reboot' { $u.Installed = $true; $out.RebootRequired = $true; $script:Sim.RebootPending = $true; $out.Results[$u.Id] = @{ Result = 'Succeeded'; HResult = 0 } }
            'reoffer'   { $out.Results[$u.Id] = @{ Result = 'Succeeded'; HResult = 0 } }
            'fail'      { $out.Results[$u.Id] = @{ Result = 'Failed'; HResult = -2145124330 } }
            'fail-once' { if ($u.InstallCalls -ge 2) { $u.Installed = $true; $out.Results[$u.Id] = @{ Result = 'Succeeded'; HResult = 0 } } else { $out.Results[$u.Id] = @{ Result = 'Failed'; HResult = -2145124330 } } }
            # Engine 1.3.0: fails while Windows waits for a restart (like KB890830/KB4052623 in the field), installs after it.
            'fail-pending' { if ($script:Sim.RebootPending) { $out.Results[$u.Id] = @{ Result = 'Failed'; HResult = -2146233080 } } else { $u.Installed = $true; $out.Results[$u.Id] = @{ Result = 'Succeeded'; HResult = 0 } } }
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
        initialDelaySeconds = 60; excludedKbs = @(); lockWaitMinutes = 1; retryDelaySeconds = 120
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

$tests['policy: feature, driver, optional and excluded KB updates are skipped; one that can ask for input is tried'] = {
    Reset-Sim @(
        (New-SimUpdate KB5000001 'ok' -Upgrade), (New-SimUpdate KB5000002 'ok' -Driver), (New-SimUpdate KB5000003 'ok' -Optional),
        (New-SimUpdate KB5000004 'ok' -Interactive), (New-SimUpdate KB5000005 'ok'), (New-SimUpdate KB5000006 'ok'))
    $c = New-TestConfig @{ excludedKbs = @('KB5000005') }
    $o = Invoke-Boots $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'skips are not failures'
    $installed = @($script:Sim.Updates | Where-Object { $_.Installed } | ForEach-Object { $_.Kbs[0] })
    # CanRequestUserInput alone is no reason to skip: Windows installs it quietly.
    Assert-Equal ($installed -join ',') 'KB5000004,KB5000006' 'the plain update and the one that can ask for input are installed'
    $reasons = @((Get-Result $c).skipped | ForEach-Object { $_.reason })
    Assert-True ($reasons -match 'feature update') 'feature update reason'
    Assert-True ($reasons -match 'optional') 'optional reason'
    Assert-True (-not ($reasons -match 'user input')) 'no update is skipped for "user input" alone'
    Assert-True ($reasons -match 'excluded by configuration') 'excluded reason'
    # The update that can ask for input is installed on its own, after the others.
    Assert-Equal (($script:Sim.InstallBatches | ForEach-Object { $_ -join '+' }) -join ' | ') 'KB5000006 | KB5000004' 'install batches'
}

$tests['owner defaults: optional updates, optional drivers and drivers are installed and counted'] = {
    Reset-Sim @((New-SimUpdate KB5200001 'ok'), (New-SimUpdate KB5200002 'ok' -Optional), (New-SimUpdate KB5200003 'ok' -Driver -Optional), (New-SimUpdate KB5200004 'ok' -Driver))
    $c = New-TestConfig @{ drivers = 'include'; optionalUpdates = 'install'; maxAttemptsPerUpdate = 3 }
    $o = Invoke-Boots $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'outcome'
    $r = Get-Result $c
    Assert-Equal $r.counts.installed 4 'installed'
    Assert-Equal $r.counts.installedOptional 2 'optional installed (including the optional driver)'
    Assert-Equal $r.counts.installedDrivers 2 'drivers installed'
    $kinds = @($r.installed | ForEach-Object { "$($_.kbs[0])=$($_.kind)" }) -join ','
    Assert-Equal $kinds 'KB5200001=Update,KB5200002=Optional,KB5200003=Optional driver,KB5200004=Driver' 'kinds'
    Assert-Equal $r.policy.optionalUpdates 'install' 'policy recorded in the result'
}

$tests['transient download failure is retried after a delay, and the update installs'] = {
    Reset-Sim @((New-SimUpdate KB5300001 'download-fail-once'), (New-SimUpdate KB5300002 'ok'))
    $c = New-TestConfig @{ maxAttemptsPerUpdate = 3; resetComponentsOnce = $false }
    $start = $script:Sim.Now
    $o = Invoke-Boots $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'outcome'
    Assert-Equal $script:Sim.Updates[0].DownloadCalls 2 'downloaded twice'
    Assert-True ($script:Sim.Updates[1].Installed) 'the other update was installed meanwhile'
    Assert-True (($script:Sim.Now - $start).TotalSeconds -ge 120) 'waited for the retry delay'
    Assert-Equal (($script:Sim.DownloadCalls | ForEach-Object { $_.Count }) -join ',') '1,1,1' 'one update per download call'
    $log = Get-Content -LiteralPath (Join-Path $c.dataRoot 'Updates\logs\engine.log') -Raw
    Assert-True ($log -match 'Unable to download KB5300001 .*0x8024402C WU_E_PT_WINHTTP_NAME_NOT_RESOLVED.*Attempt 1 of 3; retrying in 120 s\. Other operations will continue where possible') 'retry message in the log'
}

$tests['download that keeps failing: three attempts in total, HRESULT name kept, other updates installed'] = {
    Reset-Sim @((New-SimUpdate KB5400001 'download-fail'), (New-SimUpdate KB5400002 'ok'))
    $c = New-TestConfig @{ maxAttemptsPerUpdate = 3; resetComponentsOnce = $false }
    $o = Invoke-Boots $c
    Assert-Equal $o[-1] 'Finished:CompletedWithFailures' 'outcome'
    Assert-Equal $script:Sim.Updates[0].DownloadCalls 3 'exactly three attempts'
    $r = Get-Result $c
    Assert-Equal $r.failed[0].attempts 3 'attempts recorded'
    Assert-Equal $r.failed[0].lastHResult '0x8024402C' 'HRESULT kept'
    Assert-True ($r.failed[0].error -like '*WU_E_PT_WINHTTP_NAME_NOT_RESOLVED*') "named error: $($r.failed[0].error)"
    Assert-True ($script:Sim.Updates[1].Installed) 'the other update was installed'
    $status = Get-Content -LiteralPath (Join-Path $c.dataRoot 'Updates\status.json') -Raw | ConvertFrom-Json
    Assert-True ($status.lastError -like 'Unable to download KB5400001*Attempt 3 of 3; given up*') "last error in status.json: $($status.lastError)"
    Assert-Equal $status.progress 'unavailable' 'no invented progress'
}

$tests['permanent failure (not applicable) is not retried'] = {
    Reset-Sim @((New-SimUpdate KB5500001 'not-applicable'), (New-SimUpdate KB5500002 'ok'))
    $c = New-TestConfig @{ maxAttemptsPerUpdate = 3 }
    $o = Invoke-Boots $c
    Assert-Equal $o[-1] 'Finished:CompletedWithFailures' 'outcome'
    Assert-Equal $script:Sim.Updates[0].InstallCalls 1 'installed once only'
    Assert-Equal $script:Sim.Resets 0 'no component reset for a permanent failure'
    $r = Get-Result $c
    Assert-True ($r.failed[0].reason -like 'gave up: 0x80240017 WU_E_NOT_APPLICABLE*') "reason: $($r.failed[0].reason)"
}

$tests['update that Windows says needs a person: tried quietly once, CompletedWithFollowUp, marker written'] = {
    Reset-Sim @((New-SimUpdate KB5600001 'needs-person' -Interactive), (New-SimUpdate KB5600002 'ok'))
    $c = New-TestConfig @{ maxAttemptsPerUpdate = 3 }
    $o = Invoke-Boots $c
    Assert-Equal $o[-1] 'Finished:CompletedWithFollowUp' 'outcome'
    Assert-Equal $script:Sim.Updates[0].InstallCalls 1 'not retried in a loop'
    $r = Get-Result $c
    Assert-Equal (@($r.requiresInteraction).Count) 1 'listed as needing a person'
    Assert-Equal (@($r.failed).Count) 0 'not a failure'
    Assert-Equal $r.counts.requiresInteraction 1 'counted'
    Assert-True (Test-Marker $c) 'marker written'
    Assert-True ($script:Sim.Events -contains 1104) 'follow-up event'
}

$tests['feature enablement packages and Insider builds are recognised by title'] = {
    Assert-True (Test-WduFeatureTitle 'Feature update to Windows 11, version 25H2 via Enablement Package (KB5054156)') 'enablement package'
    Assert-True (-not (Test-WduFeatureTitle '2026-11 Cumulative Update for Windows 11, version 25H2 for x64-based Systems (KB5070000)')) 'cumulative update is not a feature update'
    $s = New-WduState
    $c = New-TestConfig @{ featureUpdates = 'install'; optionalUpdates = 'install' }
    $u = New-SimUpdate KB5700001 'ok'; $u.IsInsider = $true
    Assert-True ((Get-WduSkipReason $u $c $s) -like 'Insider Preview build*') 'Insider builds never install, even with feature updates allowed'
    $p = New-SimUpdate KB5700002 'ok' -Optional
    Assert-Equal (Get-WduSkipReason $p $c $s) '' 'optional cumulative preview installs with optionalUpdates=install'
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

$tests['engine 1.3.0: an update failing on its last attempt while a restart is pending is retried once after the restart'] = {
    Reset-Sim @((New-SimUpdate KB5500001 'ok-reboot'), (New-SimUpdate KB890830 'fail-pending'))
    $c = New-TestConfig @{ maxAttemptsPerUpdate = 1; resetComponentsOnce = $false }
    $o = Invoke-Boots $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'installed after the restart'
    Assert-Equal "$($script:Sim.Updates[1].InstallCalls) $($script:Sim.Boots)" '2 1' 'one extra attempt, in the next boot'
    $log = Get-Content -LiteralPath (Join-Path $c.dataRoot 'Updates\logs\engine.log') -Raw
    Assert-True ($log -match 'KB890830 .*while Windows has a restart pending; retried once more after the restart') 'explained in the log'
}

$tests['engine 1.3.0: still failing after that restart: given up once, never looped; reported with the retry and the error source'] = {
    Reset-Sim @((New-SimUpdate KB5500001 'ok-reboot'), (New-SimUpdate KB4052623 'fail'))
    $script:Sim.Updates[1].Behavior = 'fail'
    $c = New-TestConfig @{ maxAttemptsPerUpdate = 1; resetComponentsOnce = $false }
    $o = Invoke-Boots $c
    Assert-Equal $o[-1] 'Finished:CompletedWithFailures' 'outcome'
    Assert-Equal $script:Sim.Updates[1].InstallCalls 2 'the first attempt plus exactly one after the restart'
    $f = @((Get-Result $c).failed)[0]
    Assert-Equal "$($f.kbs[0]) $($f.retriedAfterRestart) $($f.errorSource)" 'KB4052623 True windowsUpdate' 'retry and source reported'
}

$tests['engine 1.3.0: an exception in the engine''s own Windows Update call (0x80131508) is recorded as an engine error, with a new session next time'] = {
    Reset-Sim
    function New-WduCollection { param([object[]] $Updates) throw (New-Object System.IndexOutOfRangeException('Index was outside the bounds of the array.')) }
    function Get-WduSession { 'session' }
    $script:Session = 'stale session'
    $u = New-SimUpdate KB890830
    $r = (& $script:RealWduInstall @($u)).Results[$u.Id]
    Assert-Equal "$($r.Result) $($r.Source) $(Format-WduHResult $r.HResult)" 'Failed engine 0x80131508' 'result'
    Assert-True ($r.Exception -match 'IndexOutOfRangeException: Index was outside') 'exception kept'
    Assert-Equal "$($script:Session)" '' 'the next attempt uses a new Windows Update session'
    $script:Session = 'stale session'
    $d = (& $script:RealWduDownload @($u))[$u.Id]
    Assert-Equal "$($d.Source) $(Format-WduHResult $d.HResult)" 'engine 0x80131508' 'download path too'
    Assert-Equal "$($script:Session)" '' 'download resets the session too'
    $c = New-TestConfig
    $script:LogFile = Join-Path $c.dataRoot 'test.log'; New-Item -ItemType Directory -Path $c.dataRoot -Force | Out-Null
    $a = @{ count = 1; title = $u.Title; kbs = @('KB890830') }
    Register-WduFailure $u $a $c 'install' 'Failed' $r.HResult $r
    Assert-Equal "$($a.lastErrorSource) $($a.lastHResult)" 'engine 0x80131508' 'attempt record'
    Assert-True ($script:Activity.lastError -match 'failed in the engine \(0x80131508 COR_E_INDEXOUTOFRANGE.*not a Windows Update result\); IndexOutOfRangeException') 'message names the engine, the code and the exception'
}

$tests['Get-WduConfig fills defaults and normalises KB numbers'] = {
    $p = Join-Path ([IO.Path]::GetTempPath()) ("wdu-cfg-" + [Guid]::NewGuid().ToString('N') + '.json')
    Set-Content -LiteralPath $p -Value '{ "maxReboots": 4, "excludedKbs": ["kb5000001"] }'
    $cfg = Get-WduConfig $p
    Assert-Equal $cfg.maxReboots 4 'explicit value'
    Assert-Equal $cfg.maxAttemptsPerUpdate 3 'default value (three attempts in total)'
    Assert-Equal $cfg.retryDelaySeconds 120 'retry delay default'
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
