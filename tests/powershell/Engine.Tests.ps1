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
    param([string] $Kb, [string] $Behavior = 'ok', [switch] $Driver, [switch] $Upgrade, [switch] $Optional, [switch] $Interactive, [int] $AppearsAfterReboot = 0, [string] $Title = '', [string] $Supersedes = '')
    $u = @{ Id = "id-$Kb"; Revision = 1; Title = $(if ($Title) { $Title } else { "Update $Kb" }); Kbs = @($Kb); IsDriver = [bool] $Driver; IsUpgrade = [bool] $Upgrade
       IsOptional = [bool] $Optional; NeedsUserInput = [bool] $Interactive; IsDownloaded = $false; Native = $null
       Behavior = $Behavior; AppearsAfterReboot = $AppearsAfterReboot; Installed = $false; InstallCalls = 0; Gone = $false; Supersedes = $Supersedes }
    # Engine 2.0.0: a driver update carries the device it is for.
    if ($Driver) { $u.Driver = [ordered]@{ hardwareID = "PCI\VEN_8086&DEV_$Kb"; model = "Device for $Kb"; manufacturer = 'Contoso'; class = 'System' } }
    $u
}

function Reset-Sim {
    param([object[]] $Updates = @(), [bool] $Online = $true, [int] $OnlineAfterBoot = 0)
    $script:Sim = @{
        Now = [DateTime]::new(2026, 10, 19, 12, 0, 0, [DateTimeKind]::Utc)
        Updates = @($Updates); Boots = 0; Online = $Online; OnlineAfterBoot = $OnlineAfterBoot
        RebootPending = $false; RebootRequested = $false; Resets = 0; Events = @(); TaskRemoved = $false
        ScanThrows = 0; InstallThrows = $false; UnexpectedThrows = $false; Busy = 0; LockPolls = 0
        DownloadCalls = @(); InstallBatches = @()
        # Engine 2.0.0: HRESULT of a simulated search failure (default WU_E_NOT_APPLICABLE: not a data-store error),
        # simulated engine exceptions / failed batch calls, devices with problems, disabled services.
        ScanHResult = -2145124329; EngineException = 0; BatchCallFails = $false; Devices = @(); Disabled = @(); Searches = 0
        # Engine 2.1.0: the simulated Update Orchestrator (Settings refresh). The real one is never called.
        OrchestratorAvailable = $true; OrchestratorScans = 0; OrchestratorCompletes = $true; OrchestratorRefuses = $false
        OrchestratorTime = [DateTime]::new(2026, 10, 19, 6, 0, 0, [DateTimeKind]::Utc)
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
# Engine 2.0.0 read-only probes (readiness, pass D): simulated.
function Get-WduServiceStates { $st = [ordered]@{}; foreach ($n in 'wuauserv', 'bits', 'cryptsvc', 'TrustedInstaller') { $st[$n] = [ordered]@{ status = 'Stopped'; startType = $(if ($script:Sim.ContainsKey('Disabled') -and $script:Sim.Disabled -contains $n) { 'Disabled' } else { 'Manual' }) } }; $st }
function Test-WduAgentEnabled { $true }
function Get-WduDeviceProblems { , @($(if ($script:Sim.ContainsKey('Devices')) { $script:Sim.Devices } else { @() })) }
# Engine 2.1.0: Update Orchestrator boundary (Settings > Windows Update), simulated. A scan request
# completes by advancing the last successful scan time and makes AppearsAfterRefresh updates visible.
function Get-WduOrchestrator { if ($script:Sim.OrchestratorAvailable) { return 'sim-orchestrator' }; return $null }
function Get-WduOrchestratorScanTime { param($Manager) if ($Manager -ne 'sim-orchestrator') { throw 'not the simulated orchestrator' }; $script:Sim.OrchestratorTime }
function Start-WduOrchestratorScan {
    param($Manager)
    if ($Manager -ne 'sim-orchestrator') { throw 'not the simulated orchestrator' }
    $script:Sim.OrchestratorScans++
    if ($script:Sim.OrchestratorRefuses) { throw 'Simulated refusal' }
    foreach ($u in @($script:Sim.Updates)) { if ($u.ContainsKey('AppearsAfterRefresh')) { $u.AppearsAfterRefresh = $false } }
    if ($script:Sim.OrchestratorCompletes) { $script:Sim.OrchestratorTime = $script:Sim.Now.AddSeconds(30) }
    # Windows' own installer starts after the check (an unmanaged computer installs by itself).
    if ($script:Sim.ContainsKey('BusyAfterScan')) { $script:Sim.Busy = $script:Sim.BusyAfterScan }
}
function Test-WduOrchestratorScanning { param($Manager) $false }

function Get-WduAvailableUpdates {
    param([hashtable] $Config)
    $script:Sim.Searches++
    if ($script:Sim.ScanThrows -gt 0) { $script:Sim.ScanThrows--; throw (New-Object System.Runtime.InteropServices.COMException('Simulated scan failure', [int] $script:Sim.ScanHResult)) }
    $list = @($script:Sim.Updates | Where-Object {
        -not $_.Installed -and -not $_.Gone -and $script:Sim.Boots -ge $_.AppearsAfterReboot -and ($Config.drivers -eq 'include' -or -not $_.IsDriver) -and
        -not ($_.ContainsKey('AppearsAfterRefresh') -and $_.AppearsAfterRefresh)
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
    # Engine 2.0.0: the adapter's own call failed (what engines 1.0-1.3 did on every call: 0x80131508 at the Updates setter).
    if ($script:Sim.EngineException -gt 0) {
        $script:Sim.EngineException--
        $info = [ordered]@{ operation = 'install: assign updates to installer'; type = 'System.IndexOutOfRangeException'; hresult = '0x80131508'; message = 'Index was outside the bounds of the array.'; chain = @(); line = 777; statement = '$inst.Updates = $coll'; script = 'WindowsUpdateEngine.ps1'; stack = 'at Invoke-WduInstall'; engineVersion = 'sim'; atUtc = '' }
        foreach ($u in $Updates) { $out.Results[$u.Id] = @{ Result = 'Failed'; HResult = -2146233080; Source = 'engine'; Exception = (Format-WduException $info); ExceptionInfo = $info } }
        $out.CallFailed = $true
        return $out
    }
    # A WUA COMException for the whole call when several updates are installed together (0x8024000B WU_E_CALL_CANCELLED).
    if ($script:Sim.BatchCallFails -and @($Updates).Count -gt 1) {
        $info = [ordered]@{ operation = 'install: IUpdateInstaller.Install'; type = 'System.Runtime.InteropServices.COMException'; hresult = '0x8024000B'; message = 'Simulated call failure'; chain = @(); line = 1; statement = ''; script = ''; stack = ''; engineVersion = 'sim'; atUtc = '' }
        foreach ($u in $Updates) { $out.Results[$u.Id] = @{ Result = 'Failed'; HResult = -2145124341; Source = 'engine'; Exception = (Format-WduException $info); ExceptionInfo = $info } }
        $out.CallFailed = $true
        return $out
    }
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
            # 0x80246007 WU_E_DM_NOTDOWNLOADED: a download-cache problem, the kind a component reset repairs.
            'fail-store' { if ($script:Sim.Resets -gt 0) { $u.Installed = $true; $out.Results[$u.Id] = @{ Result = 'Succeeded'; HResult = 0 } } else { $out.Results[$u.Id] = @{ Result = 'Failed'; HResult = -2145099769 } } }
            # Installing it makes another update unnecessary (superseded): Windows stops offering that one.
            'ok-supersedes' { $u.Installed = $true; foreach ($o in $script:Sim.Updates) { if ($o.Kbs[0] -eq $u.Supersedes) { $o.Gone = $true } }; $out.Results[$u.Id] = @{ Result = 'Succeeded'; HResult = 0 } }
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
        readinessSearchAttempts = 4; readinessSearchDelaySeconds = 90; readinessRestart = $true; maxEngineExceptions = 2; verifyDevices = $true
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

$tests['download-cache failures trigger one component reset and one extra attempt (engine 2.0.0: only when warranted)'] = {
    Reset-Sim @((New-SimUpdate KB3000001 'fail-store'))
    $c = New-TestConfig
    $o = Invoke-Boots $c
    Assert-Equal $script:Sim.Resets 1 'exactly one reset'
    Assert-Equal $o[-1] 'Finished:Succeeded' 'installs after the reset'
    Assert-Equal $script:Sim.Updates[0].InstallCalls 3 'two attempts plus one after reset'
}

$tests['engine 2.0.0: failures that a reset cannot repair never reset Windows Update components'] = {
    Reset-Sim @((New-SimUpdate KB3000001 'fail'))
    $c = New-TestConfig
    $o = Invoke-Boots $c
    Assert-Equal $script:Sim.Resets 0 'no reset for WU_E_INSTALL_NOT_ALLOWED'
    Assert-Equal $o[-1] 'Finished:CompletedWithFailures' 'final outcome'
    Assert-Equal $script:Sim.Updates[0].InstallCalls 2 'two attempts, no extra one'
    $r = Get-Result $c
    Assert-Equal "$($r.failed[0].lastHResult) $($r.failed[0].category)" '0x80240016 ServicingBusy' 'HResult and category recorded'
    Assert-Equal $r.failedByCategory.ServicingBusy 1 'counted by category'
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

$tests['scan failures pointing at the update data store: one component reset, then Failed'] = {
    Reset-Sim
    $script:Sim.ScanThrows = 100
    $script:Sim.ScanHResult = -2145091577   # 0x80248007, WU_E_DS_* (update data store)
    $c = New-TestConfig
    $o = Invoke-Boots $c
    Assert-Equal $o[-1] 'Finished:Failed' 'final outcome'
    Assert-Equal $script:Sim.Resets 1 'one reset'
    Assert-True ((Get-Result $c).reason -like '*did not become ready*0x80248007*') 'reason names readiness and the code'
}

$tests['engine 2.0.0: other scan failures end as NotReady without a component reset'] = {
    Reset-Sim
    $script:Sim.ScanThrows = 100
    $c = New-TestConfig
    $o = Invoke-Boots $c
    Assert-Equal $o[-1] 'Finished:Failed' 'final outcome'
    Assert-Equal $script:Sim.Resets 0 'no reset'
    Assert-Equal $script:Sim.Searches 4 'readinessSearchAttempts searches, bounded'
    $r = Get-Result $c
    Assert-Equal "$($r.category) $($r.readiness.status) $($r.readiness.searchAttempts)" 'NotReady WaitingForSearch 4' 'category and readiness'
    Assert-True ($r.technicianAction -like '*Retry Windows Update*') 'technician action'
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
    # KB890830 (MSRT) belongs to pass B with the cumulative update (KB4052623 is a pass A prerequisite since 2.0.0).
    Reset-Sim @((New-SimUpdate KB5500001 'ok-reboot'), (New-SimUpdate KB890830 'fail'))
    $script:Sim.Updates[1].Behavior = 'fail'
    $c = New-TestConfig @{ maxAttemptsPerUpdate = 1; resetComponentsOnce = $false }
    $o = Invoke-Boots $c
    Assert-Equal $o[-1] 'Finished:CompletedWithFailures' 'outcome'
    Assert-Equal $script:Sim.Updates[1].InstallCalls 2 'the first attempt plus exactly one after the restart'
    $f = @((Get-Result $c).failed)[0]
    Assert-Equal "$($f.kbs[0]) $($f.retriedAfterRestart) $($f.errorSource)" 'KB890830 True windowsUpdate' 'retry and source reported'
}

$tests['engine 1.3.0: an exception in the engine''s own Windows Update call (0x80131508) is recorded as an engine error, with a new session next time'] = {
    Reset-Sim
    function New-WduCollection { param([object[]] $Updates) throw (New-Object System.IndexOutOfRangeException('Index was outside the bounds of the array.')) }
    function Get-WduSession { 'session' }
    $script:Session = 'stale session'
    $u = New-SimUpdate KB890830
    $r = (& $script:RealWduInstall @($u)).Results[$u.Id]
    Assert-Equal "$($r.Result) $($r.Source) $(Format-WduHResult $r.HResult)" 'Failed engine 0x80131508' 'result'
    Assert-True ($r.Exception -match 'install: build update collection raised System.IndexOutOfRangeException 0x80131508: Index was outside') 'exception kept, with the operation'
    Assert-Equal "$($r.ExceptionInfo.operation)|$($r.ExceptionInfo.type)" 'install: build update collection|System.IndexOutOfRangeException' 'structured exception record'
    Assert-True ([int] $r.ExceptionInfo.line -gt 0 -and $r.ExceptionInfo.stack) 'line number and stack trace recorded'
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
    Assert-Equal $a.lastCategory 'EngineException' 'category'
    Assert-True ($script:Activity.lastError -match 'call failed \(EngineException: 0x80131508 COR_E_INDEXOUTOFRANGE.*not a Windows Update result\); .*IndexOutOfRangeException') 'message names the category, the code and the exception'
}

# ------------------------------------------------------------------------------------------------
# Engine 2.0.0: root cause of 0x80131508, readiness, passes, isolation, verification
# ------------------------------------------------------------------------------------------------

function New-TestStringColl { $sc = New-Object -ComObject 'Microsoft.Update.StringColl'; [void] $sc.Add('a'); [void] $sc.Add('b'); return , $sc }

$tests['engine 2.0.0 ROOT CAUSE (live COM, read-only): a WUA collection returned without the comma is unrolled and its assignment throws 0x80131508; New-WduCollection keeps it intact'] = {
    # Real Windows Update Agent objects; nothing is searched, downloaded or installed.
    $session = New-Object -ComObject 'Microsoft.Update.Session'
    # The 2.0.0 path first: an empty collection survives the return and is accepted by the setter.
    $good = $session.CreateUpdateInstaller()
    $coll = New-WduCollection @()
    Assert-True ($null -ne $coll -and $coll -isnot [array]) 'New-WduCollection returns the collection itself, even when empty'
    Assert-WduCollection $coll 0
    $good.Updates = $coll
    Assert-Equal $good.Updates.Count 0 'the installer accepted the real collection'
    # The 1.0.0-1.3.0 pattern on a separate installer object.
    $installer = $session.CreateUpdateInstaller()
    function Get-Unrolled { $c = New-Object -ComObject 'Microsoft.Update.StringColl'; [void] $c.Add('only'); $c }   # the 1.0.0-1.3.0 pattern
    $unrolled = Get-Unrolled
    Assert-True ($unrolled -is [string]) 'the pipeline unrolls a one-item COM collection into its item'
    $err = $null
    try { $installer.Updates = $unrolled } catch { $err = $_ }
    Assert-True ($err) 'assigning the unrolled value fails'
    $info = ConvertFrom-WduError $err 'install: assign updates to installer'
    Assert-Equal "$($info.type) $($info.hresult)" 'System.IndexOutOfRangeException 0x80131508' 'exactly the field error: IndexOutOfRangeException 0x80131508'
    Assert-True ($info.line -gt 0 -and $info.statement.Contains('Updates = $unrolled')) 'the exception record names the line and statement'
    # Invoke-WduOperation keeps an enumerable COM object intact through its own return.
    $kept = Invoke-WduOperation 'test: keep collection' { New-TestStringColl }
    Assert-True ($kept -isnot [array] -and $kept.Count -eq 2) 'operation wrapper does not unroll a two-item collection'
}

$tests['engine 2.0.0: Assert-WduCollection rejects unrolled values, null and wrong counts as engine defects'] = {
    foreach ($case in @(@{ v = $null; m = 'null' }, @{ v = @('a', 'b'); m = 'unrolled' }, @{ v = 'single'; m = 'expected an update collection' })) {
        $msg = ''
        try { Assert-WduCollection $case.v 1 } catch { $msg = $_.Exception.Message }
        Assert-True ($msg -like "*$($case.m)*") "rejected: $($case.m) ($msg)"
    }
    $msg = ''
    try { Assert-WduCollection (New-TestStringColl) 3 } catch { $msg = $_.Exception.Message }
    Assert-True ($msg -like '*holds 2 update(s), expected 3*') 'count mismatch'
}

$tests['engine 2.0.0: per-update results are mapped by update identity, never by position; a missing result is reported, not invented'] = {
    $items = @('id-B', 'id-A')
    $coll = New-Object psobject -Property @{ Count = 2 }
    $coll | Add-Member ScriptMethod Item { param($i) [pscustomobject]@{ Identity = [pscustomobject]@{ UpdateID = $items[$i] } } }
    $res = New-Object psobject
    $res | Add-Member ScriptMethod GetUpdateResult { param($i) if ($i -eq 0) { [pscustomobject]@{ ResultCode = 4; HResult = -2145124330 } } else { [pscustomobject]@{ ResultCode = 2; HResult = 0 } } }
    $map = Read-WduResults $coll $res @(@{ Id = 'id-A' }, @{ Id = 'id-B' }, @{ Id = 'id-C' })
    Assert-Equal "$($map['id-A'].Result) $($map['id-B'].Result)" 'Succeeded Failed' 'mapped by identity'
    Assert-Equal "$($map['id-C'].Result) $($map['id-C'].Category)" 'Missing EngineException' 'missing result reported'
}

$tests['engine 2.0.0: the field failure (16 updates, same engine exception) is ONE engine error, never 16 installer failures; the stage stops without resets'] = {
    $kbs = 1..16 | ForEach-Object { 'KB59{0:D5}' -f $_ }
    Reset-Sim @($kbs | ForEach-Object { New-SimUpdate $_ })
    $script:Sim.EngineException = 100
    $c = New-TestConfig
    $o = Invoke-Boots $c
    Assert-Equal $o[-1] 'Finished:Failed' 'stops'
    $r = Get-Result $c
    Assert-Equal "$($r.category) $(@($r.failed).Count) $($r.counts.failed) $(@($r.engineExceptions).Count)" 'EngineException 0 0 2' 'no installer failures; two identical engine exceptions'
    Assert-Equal @($r.notAttempted).Count 16 'remaining updates reported as not attempted'
    Assert-Equal $script:Sim.Resets 0 'components never reset for an engine exception'
    Assert-Equal (@($script:Sim.InstallBatches | ForEach-Object { @($_).Count }) -join ',') '16,1' 'batch, then one isolated update, then stop'
    Assert-True ($r.engineExceptions[0].operation -eq 'install: assign updates to installer' -and $r.engineExceptions[0].line -eq 777) 'operation and line reported'
    Assert-True ($r.technicianAction -like '*not reported as failed installations*') 'technician action'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $c.dataRoot 'state\windows-update.done'))) 'no completion marker for a stopped stage'
    Assert-True $script:Sim.TaskRemoved 'the task is removed, so the application stage is not held back'
    $st = Get-Content -LiteralPath (Join-Path $c.dataRoot 'Updates\state.json') -Raw | ConvertFrom-Json
    Assert-Equal ([int] ($st.attempts.PSObject.Properties | ForEach-Object { $_.Value.count } | Measure-Object -Maximum).Maximum) 0 'no update attempt was used up by the engine exception'
}

$tests['engine 2.0.0: a transient engine exception is retried and the updates then install'] = {
    Reset-Sim @((New-SimUpdate KB5910001), (New-SimUpdate KB5910002))
    $script:Sim.EngineException = 1
    $c = New-TestConfig
    $o = Invoke-Boots $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'installs'
    $r = Get-Result $c
    Assert-Equal "$(@($r.installed).Count) $(@($r.engineExceptions).Count)" '2 1' 'both installed, one engine exception recorded'
}

$tests['engine 2.0.0: a WUA call failing for a whole batch is isolated one update at a time'] = {
    Reset-Sim @((New-SimUpdate KB5920001), (New-SimUpdate KB5920002), (New-SimUpdate KB5920003))
    $script:Sim.BatchCallFails = $true
    $c = New-TestConfig
    $o = Invoke-Boots $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'every update installs on its own'
    Assert-Equal (@($script:Sim.InstallBatches | ForEach-Object { @($_).Count }) -join ',') '3,1,1,1' 'batch then singles'
    Assert-Equal @((Get-Result $c).installed).Count 3 'three installed'
}

$tests['engine 2.0.0: passes run in order - A prerequisites alone, B normal, C optional and each driver on its own, D verification'] = {
    Reset-Sim @(
        (New-SimUpdate KB5930001 -Driver -Optional),
        (New-SimUpdate KB5930002),
        (New-SimUpdate KB5930003 -Title '2026-11 Servicing Stack Update for Windows 11'),
        (New-SimUpdate KB4052623 -Title 'Update for Microsoft Defender Antivirus antimalware platform'),
        (New-SimUpdate KB5930004 -Optional),
        (New-SimUpdate KB5930005 -Driver))
    $c = New-TestConfig @{ drivers = 'include'; optionalUpdates = 'install' }
    $o = Invoke-Boots $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'outcome'
    $b = @($script:Sim.InstallBatches | ForEach-Object { (@($_) | Sort-Object) -join '+' })
    Assert-Equal ($b -join ' | ') 'KB4052623+KB5930003 | KB5930002 | KB5930004 | KB5930001 | KB5930005' 'A, then B, then C (optional software together, drivers one by one)'
    $r = Get-Result $c
    Assert-Equal (@($r.passes | ForEach-Object { $_.pass }) -join '') 'ABCD' 'pass history'
    Assert-Equal "$($r.readiness.status) $($r.readiness.bootstrapNeeded) $(@($r.readiness.prerequisites).Count)" 'Ready True 2' 'prerequisites detected at readiness'
    $d = @($r.drivers | Where-Object { $_.title -like '*KB5930005*' })[0]
    Assert-Equal "$($d.device.model) $($d.device.hardwareID)" 'Device for KB5930005 PCI\VEN_8086&DEV_KB5930005' 'driver recorded with its device'
}

$tests['engine 2.0.0: readiness - no prerequisite needed is detected, not assumed'] = {
    Reset-Sim @((New-SimUpdate KB5940001))
    $c = New-TestConfig
    Assert-Equal (Invoke-WduMain $c) 'Finished:Succeeded' 'outcome'
    $r = Get-Result $c
    Assert-Equal "$($r.readiness.status) $($r.readiness.bootstrapNeeded) $($r.readiness.searchAttempts) $($r.readiness.restartDone)" 'Ready False 1 False' 'readiness record'
    Assert-Equal $r.readiness.services.wuauserv.startType 'Manual' 'service states recorded'
}

$tests['engine 2.0.0: readiness - a restart already pending is taken once before anything is installed'] = {
    Reset-Sim @((New-SimUpdate KB5950001))
    $script:Sim.RebootPending = $true
    $c = New-TestConfig
    $o = Invoke-Boots $c
    Assert-Equal ($o -join ',') 'Rebooting,Finished:Succeeded' 'one readiness restart, then installed'
    Assert-Equal $script:Sim.Updates[0].InstallCalls 1 'installed once, after the restart'
    $r = Get-Result $c
    Assert-True ($r.restarts[0].reason -like '*already pending*readiness*') 'restart history records why'
    Assert-Equal $r.readiness.rebootPendingAtStart $true 'recorded'
}

$tests['engine 2.0.0: readiness - the Windows Update service disabled ends as NotReady without searching'] = {
    Reset-Sim @((New-SimUpdate KB5960001))
    $script:Sim.Disabled = @('wuauserv')
    $c = New-TestConfig
    Assert-Equal (Invoke-WduMain $c) 'Finished:Failed' 'outcome'
    $r = Get-Result $c
    Assert-Equal "$($r.category) $($script:Sim.Searches)" 'NotReady 0' 'NotReady, nothing searched'
    Assert-True ($r.technicianAction -like '*wuauserv*Manual*') 'what to do'
}

$tests['engine 2.0.0: readiness - searches failing while the agent initialises are retried (bounded), then it is ready'] = {
    Reset-Sim @((New-SimUpdate KB5970001))
    $script:Sim.ScanThrows = 2
    $script:Sim.ScanHResult = -2145124322   # 0x8024001E WU_E_SERVICE_STOP
    $c = New-TestConfig
    Assert-Equal (Invoke-WduMain $c) 'Finished:Succeeded' 'outcome'
    $r = Get-Result $c
    Assert-Equal "$($r.readiness.searchAttempts) $($script:Sim.Resets)" '3 0' 'ready after the third search, no reset'
    Assert-True ($r.readiness.lastSearchError -like '*NotReady*0x8024001E*') 'last readiness error categorised'
}

$tests['engine 2.0.0: pass D - superseded updates are reported as no longer offered; devices with problems listed'] = {
    Reset-Sim @((New-SimUpdate KB5980001 'ok-supersedes' -Supersedes KB5980002), (New-SimUpdate KB5980002 -Optional))
    $script:Sim.Devices = @([ordered]@{ name = 'PCI Memory Controller'; deviceId = 'PCI\VEN_8086&DEV_51A3'; problemCode = 28; hardwareIds = @('PCI\VEN_8086&DEV_51A3') })
    $c = New-TestConfig @{ optionalUpdates = 'install' }
    $o = Invoke-Boots $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'outcome'
    $v = (Get-Result $c).verification
    Assert-Equal "$(@($v.noLongerOffered).Count) $($v.noLongerOffered[0].kbs[0]) $($v.noLongerOffered[0].category)" '1 KB5980002 Superseded' 'superseded update reported'
    Assert-Equal "$(@($v.devicesWithProblems).Count) $($v.devicesWithProblems[0].problemCode)" '1 28' 'device problem listed'
    Assert-Equal "$($v.remainingOffered) $(@($v.installedStillOffered).Count)" '0 0' 'nothing left; installed updates no longer offered'
}

$tests['engine 2.0.0: failure categories'] = {
    $com = [ordered]@{ type = 'System.Runtime.InteropServices.COMException' }
    $net = [ordered]@{ type = 'System.IndexOutOfRangeException' }
    $cases = @(
        @('0x80131508', 'install', 'engine', $net, 'EngineException'),
        @('0x80240017', 'install', 'windowsUpdate', $null, 'NotApplicable'),
        @('0x8024402C', 'download', 'windowsUpdate', $null, 'TransientNetwork'),
        @('0x80246007', 'download', 'windowsUpdate', $null, 'DownloadFailure'),
        @('0x80240016', 'install', 'windowsUpdate', $null, 'ServicingBusy'),
        @('0x80070BC9', 'install', 'windowsUpdate', $null, 'RebootRequired'),
        @('0x80070422', 'install', 'windowsUpdate', $null, 'NotReady'),
        @('0x80240020', 'install', 'windowsUpdate', $null, 'TechnicianRequired'),
        @('0x800F0922', 'install', 'windowsUpdate', $null, 'InstallerFailure'),
        @('0x80131508', 'install', 'windowsUpdate', $null, 'InstallerFailure'),
        @('0x8024000B', 'install', 'engine', $com, 'ComApiException'),
        @('0x80249999', 'search', 'engine', $com, 'SearchFailure'),
        @('0x80249999', 'install', 'windowsUpdate', $null, 'NativeResultFailure'))
    foreach ($x in $cases) { Assert-Equal (Get-WduCategory $x[0] $x[1] $x[2] $x[3]) $x[4] "$($x[0]) $($x[1]) $($x[2])" }
    Assert-True (Test-WduResetWarranted @('0x80248007') @()) 'data store error warrants a reset'
    Assert-True (-not (Test-WduResetWarranted @('0x80131508', '0x80240017', '0x8024402C') @('EngineException', 'NotApplicable', 'TransientNetwork'))) 'engine, not-applicable and network never do'
}

$tests['engine 2.0.0: exception records carry operation, type, HRESULT, line, statement and stack'] = {
    function Invoke-Failing { $arr = [int[]] @(1, 2); $arr[5] = 3 }
    $e = $null
    try { Invoke-Failing } catch { $e = $_ }
    $i = ConvertFrom-WduError $e 'test operation'
    Assert-Equal "$($i.operation)|$($i.type)|$($i.hresult)" 'test operation|System.IndexOutOfRangeException|0x80131508' 'type and HRESULT of the real exception'
    Assert-True ($i.line -gt 0 -and $i.statement.Contains('$arr[5] = 3') -and $i.stack -like '*Invoke-Failing*') 'line, statement and stack'
    Assert-Equal (Get-WduExceptionSignature $i) "test operation|System.IndexOutOfRangeException|$($i.line)" 'signature'
}

$tests['engine 2.0.0 retry hooks: a retry run uses its own folder and marker; the original run is untouched'] = {
    Reset-Sim @((New-SimUpdate KB5990001))
    $c = New-TestConfig @{ workFolder = 'UpdateRetry\run1'; markerName = 'windows-update-retry.done' }
    New-Item -ItemType Directory -Path (Join-Path $c.dataRoot 'Updates') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $c.dataRoot 'Updates\result.json'), '{"status":"CompletedWithFailures"}')
    Assert-Equal (Invoke-WduMain $c) 'Finished:Succeeded' 'outcome'
    Assert-True (Test-Path -LiteralPath (Join-Path $c.dataRoot 'UpdateRetry\run1\result.json')) 'result in the retry folder'
    Assert-True (Test-Path -LiteralPath (Join-Path $c.dataRoot 'state\windows-update-retry.done')) 'retry marker'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $c.dataRoot 'state\windows-update.done'))) 'deployment marker not written'
    Assert-Equal (Get-Content -LiteralPath (Join-Path $c.dataRoot 'Updates\result.json') -Raw) '{"status":"CompletedWithFailures"}' 'original result untouched'
}

$tests['engine 2.1.0 retry hooks: selection normal installs every Windows update the policy allows (also optional and previews) but no driver; drivers skips everything else'] = {
    $ups = @((New-SimUpdate KB5991001), (New-SimUpdate KB5991002 -Driver), (New-SimUpdate KB5991003 -Optional), (New-SimUpdate KB5991004 -Driver -Optional),
             (New-SimUpdate KB5991005 -Optional -Title '2026-11 Cumulative Update Preview for Windows 11 Version 25H2 for x64-based Systems (KB5991005)'))
    Reset-Sim $ups
    $c = New-TestConfig @{ drivers = 'include'; optionalUpdates = 'install'; previewUpdates = $true; selection = 'normal' }
    Assert-Equal (Invoke-WduMain $c) 'Finished:Succeeded' 'normal outcome'
    Assert-Equal (@((Get-Result $c).installed | ForEach-Object { $_.kbs[0] } | Sort-Object) -join ',') 'KB5991001,KB5991003,KB5991005' 'every Windows update, no driver'
    Assert-True (@((Get-Result $c).skipped | Where-Object { $_.reason -like 'not selected for this retry (Windows updates only, no drivers)' }).Count -eq 2) 'the drivers reported as not selected'
    Assert-Equal "$((Get-Result $c).updateState) $((Get-Result $c).summary.notSelected) $((Get-Result $c).summary.excluded)" 'UpdatesRemaining 2 0' 'drivers left for another retry: updates remain, never "up to date"'
    Reset-Sim @((New-SimUpdate KB5991001), (New-SimUpdate KB5991002 -Driver), (New-SimUpdate KB5991003 -Optional), (New-SimUpdate KB5991004 -Driver -Optional))
    $c = New-TestConfig @{ drivers = 'include'; optionalUpdates = 'install'; selection = 'drivers' }
    Assert-Equal (Invoke-WduMain $c) 'Finished:Succeeded' 'drivers outcome'
    Assert-Equal (@((Get-Result $c).installed | ForEach-Object { $_.kbs[0] } | Sort-Object) -join ',') 'KB5991002,KB5991004' 'only drivers, optional ones included'
}

<# Engine 2.1.0: the field mix of the spare computer, every category Windows Update offers. #>
function New-MixedUpdates {
    @(
        (New-SimUpdate KB5990001 -Title '2026-11 Servicing Stack Update for Windows 11 Version 25H2 for x64-based Systems (KB5990001)'),
        (New-SimUpdate KB5990002 -Title '2026-11 Cumulative Update for Windows 11 Version 25H2 for x64-based Systems (KB5990002)'),
        (New-SimUpdate KB5990003 -Title '2026-11 Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11, version 25H2 for x64 (KB5990003)'),
        (New-SimUpdate KB2267602 -Title 'Security Intelligence Update for Microsoft Defender Antivirus - KB2267602 (Version 1.441.1.0) - Current Channel (Broad)'),
        (New-SimUpdate KB890830 -Title 'Windows Malicious Software Removal Tool x64 - v5.137 (KB890830)'),
        (New-SimUpdate KB5990004 -Optional -Title '2026-11 Cumulative Update Preview for Windows 11 Version 25H2 for x64-based Systems (KB5990004)'),
        (New-SimUpdate KB5990005 -Optional -Title '2026-11 Cumulative Update Preview for .NET Framework 3.5 and 4.8.1 for Windows 11, version 25H2 for x64 (KB5990005)'),
        (New-SimUpdate DRV0001 -Driver -Title 'Intel - System - 10.1.1.44'),
        (New-SimUpdate DRV0002 -Driver -Optional -Title 'Intel - System - 2.2.100.1'),
        (New-SimUpdate DRV0003 -Driver -Title 'Contoso - Firmware - 1.2.3')
    )
}

$tests['engine 2.1.0 classes: servicing stack, cumulative, .NET, Defender intelligence, MSRT, Windows and .NET previews, drivers and firmware'] = {
    $expect = [ordered]@{ KB5990001 = 'servicingStack'; KB5990002 = 'cumulative'; KB5990003 = 'dotnet'; KB2267602 = 'defenderIntelligence'; KB890830 = 'msrt'
                          KB5990004 = 'windowsPreview'; KB5990005 = 'dotnetPreview'; DRV0001 = 'driver'; DRV0002 = 'driver'; DRV0003 = 'firmware' }
    foreach ($u in New-MixedUpdates) {
        Set-WduUpdateClass $u
        Assert-Equal $u.Class $expect[$u.Kbs[0]] "class of $($u.Title)"
    }
    $insider = New-SimUpdate KB1 -Title 'Windows 11 Insider Preview Quality Update (26220.9836)'
    $insider.IsInsider = $true; Set-WduUpdateClass $insider
    Assert-Equal "$($insider.Class) $($insider.IsPreview)" 'insider False' 'an Insider build is never a preview update'
}

$tests['engine 2.1.0 standard mode: every category installed (previews and optional drivers included), firmware never; the result says Up to date'] = {
    Reset-Sim (New-MixedUpdates)
    $c = New-TestConfig @{ drivers = 'include'; optionalUpdates = 'install'; previewUpdates = $true }
    Assert-Equal (Invoke-WduMain $c) 'Finished:Succeeded' 'outcome'
    $r = Get-Result $c
    Assert-Equal (@($r.installed | ForEach-Object { $_.kbs[0] } | Sort-Object) -join ',') 'DRV0001,DRV0002,KB2267602,KB5990001,KB5990002,KB5990003,KB5990004,KB5990005,KB890830' 'everything but the firmware'
    Assert-True (@($r.skipped | Where-Object { $_.kbs[0] -eq 'DRV0003' -and $_.reason -eq 'firmware (never installed automatically)' -and $_.class -eq 'firmware' }).Count -eq 1) 'firmware excluded and reported'
    Assert-Equal "$($r.policy.previewUpdates) $($r.engineVersion)" 'True 2.1.0' 'policy and version recorded'
    Assert-Equal (@($r.installed | Where-Object { $_.preview } | ForEach-Object { $_.class } | Sort-Object) -join ',') 'dotnetPreview,windowsPreview' 'previews marked in the installed list'
    Assert-Equal $r.updateState 'UpToDateUnderPolicy' 'the firmware stays offered: up to date under the selected policy'
    Assert-Equal "$($r.summary.installed) $($r.summary.excluded) $($r.summary.previewsExcluded) $($r.summary.remaining)" '9 1 0 0' 'summary counts'
}

$tests['engine 2.1.0 previews off: only the Windows and .NET previews are excluded; optional drivers and every other update still install'] = {
    Reset-Sim (New-MixedUpdates)
    $c = New-TestConfig @{ drivers = 'include'; optionalUpdates = 'install'; previewUpdates = $false }
    Assert-Equal (Invoke-WduMain $c) 'Finished:Succeeded' 'outcome'
    $r = Get-Result $c
    Assert-Equal (@($r.installed | ForEach-Object { $_.kbs[0] } | Sort-Object) -join ',') 'DRV0001,DRV0002,KB2267602,KB5990001,KB5990002,KB5990003,KB890830' 'previews (and firmware) left out, optional driver installed'
    Assert-Equal (@($r.skipped | Where-Object { $_.reason -eq 'preview update (policy: preview updates excluded)' } | ForEach-Object { $_.kbs[0] } | Sort-Object) -join ',') 'KB5990004,KB5990005' 'previews reported as intentionally excluded'
    Assert-Equal $r.updateState 'PreviewUpdatesExcluded' 'state: previews intentionally excluded'
    Assert-Equal $r.summary.previewsExcluded 2 'counted'
}

$tests['engine 2.1.0 configuration written before schema 10: previews follow optionalUpdates'] = {
    foreach ($case in @(@('install', 'True'), @('skip', 'False'))) {
        Reset-Sim @((New-SimUpdate KB5990004 -Optional -Title '2026-11 Cumulative Update Preview for Windows 11 Version 25H2 (KB5990004)'))
        $c = New-TestConfig @{ optionalUpdates = $case[0] }
        if ($c.ContainsKey('previewUpdates')) { $c.Remove('previewUpdates') }
        [void] (Invoke-WduMain $c)
        Assert-Equal "$((Get-Result $c).policy.previewUpdates)" $case[1] "optionalUpdates=$($case[0])"
    }
}

$tests['engine 2.1.0 Settings refresh: after the last pass the Update Orchestrator is asked to check, completion is recorded by its timestamp, the GUI is never claimed'] = {
    Reset-Sim @((New-SimUpdate KB5990002))
    $c = New-TestConfig @{}
    Assert-Equal (Invoke-WduMain $c) 'Finished:Succeeded' 'outcome'
    $r = Get-Result $c
    $sr = $r.settingsRefresh
    Assert-Equal "$($sr.available) $($sr.requested) $($sr.completed) $($sr.settingsDisplayVerified)" 'True True True False' 'requested and completed; display not verified'
    Assert-True ([DateTime] $sr.lastSuccessfulScanAfter -gt [DateTime] $sr.lastSuccessfulScanBefore) 'the orchestrator time advanced'
    Assert-Equal $script:Sim.OrchestratorScans 1 'one request'
    Assert-True ((Get-Content -LiteralPath (Join-Path $c.dataRoot 'Updates\logs\engine.log') -Raw) -match 'Settings refresh 1: available True, requested True, completed True') 'logged'
    # Windows installing by itself after the check: the engine waits before searching again.
    Reset-Sim @((New-SimUpdate KB5990002))
    $script:Sim.BusyAfterScan = 2
    $c = New-TestConfig @{}
    Assert-Equal (Invoke-WduMain $c) 'Finished:Succeeded' 'outcome after waiting'
    Assert-Equal (Get-Result $c).settingsRefresh.waitedForWindowsInstallerSeconds 60 'waited while Windows installed'
    Assert-Equal $script:Sim.Busy 0 'the installer was idle before the next search'
}

$tests['engine 2.1.0 Settings refresh makes a new update applicable: it is installed, a second refresh follows, then verification (bounded)'] = {
    $late = New-SimUpdate KB5990009 -Title '2026-11 Cumulative Update for .NET Framework (KB5990009)'
    $late.AppearsAfterRefresh = $true
    Reset-Sim @((New-SimUpdate KB5990002), $late)
    $c = New-TestConfig @{}
    Assert-Equal (Invoke-WduMain $c) 'Finished:Succeeded' 'outcome'
    $r = Get-Result $c
    Assert-Equal (@($r.installed | ForEach-Object { $_.kbs[0] } | Sort-Object) -join ',') 'KB5990002,KB5990009' 'the update found by the refresh was installed'
    Assert-Equal "$($script:Sim.OrchestratorScans) $($r.settingsRefresh.attempt)" '2 2' 'two refreshes at most'
    Assert-Equal $r.updateState 'UpToDate' 'up to date'
}

$tests['engine 2.1.0 Settings refresh unavailable or refused: honest message, the WUA verification still decides, never a failure'] = {
    Reset-Sim @((New-SimUpdate KB5990002))
    $script:Sim.OrchestratorAvailable = $false
    $c = New-TestConfig @{}
    Assert-Equal (Invoke-WduMain $c) 'Finished:Succeeded' 'unavailable: still Succeeded'
    $sr = (Get-Result $c).settingsRefresh
    Assert-Equal "$($sr.available) $($sr.requested) $($sr.completed)" 'False False False' 'not available'
    Assert-True ($sr.message -like '*Windows 11 24H2*final search is the verification*') 'says why and what verifies instead'
    # The API exists but cannot be created (for example access denied): the real error, not "needs 24H2".
    Reset-Sim @((New-SimUpdate KB5990002))
    function Get-WduOrchestrator { $script:WduOrchestratorError = 'UnauthorizedAccessException: Access is denied.'; return $null }
    try {
        $c = New-TestConfig @{}
        [void] (Invoke-WduMain $c)
        Assert-True ((Get-Result $c).settingsRefresh.message -like "*could not be used (UnauthorizedAccessException: Access is denied.)*") 'real reason reported'
    } finally { Remove-Item Function:\Get-WduOrchestrator }
    Assert-Equal (Get-WduOrchestrator) 'sim-orchestrator' 'simulation restored'
    Reset-Sim @((New-SimUpdate KB5990002))
    $script:Sim.OrchestratorRefuses = $true
    $c = New-TestConfig @{}
    Assert-Equal (Invoke-WduMain $c) 'Finished:Succeeded' 'refused: still Succeeded'
    Assert-True ((Get-Result $c).settingsRefresh.message -like 'Windows refused the scan request*') 'refusal recorded'
    Reset-Sim @((New-SimUpdate KB5990002))
    $script:Sim.OrchestratorCompletes = $false
    $c = New-TestConfig @{ settingsRefreshMinutes = 1 }
    Assert-Equal (Invoke-WduMain $c) 'Finished:Succeeded' 'timeout: still Succeeded'
    $sr = (Get-Result $c).settingsRefresh
    Assert-Equal "$($sr.requested) $($sr.completed)" 'True False' 'requested, not completed'
    Assert-True ($sr.message -like '*did not report a completed check within 1 minutes*') 'timeout recorded'
    Reset-Sim @((New-SimUpdate KB5990002))
    $c = New-TestConfig @{ settingsRefresh = $false }
    [void] (Invoke-WduMain $c)
    Assert-Equal "$($script:Sim.OrchestratorScans) $($null -eq (Get-Result $c).settingsRefresh)" '0 True' 'can be turned off'
}

$tests['engine 2.1.0 update state: restart required, completed with failures, updates remaining (need a person), installation incomplete, verification unavailable'] = {
    Reset-Sim @((New-SimUpdate KB5990002 -Behavior 'fail'))
    $c = New-TestConfig @{ maxAttemptsPerUpdate = 1 }
    [void] (Invoke-WduMain $c)
    $r = Get-Result $c
    Assert-Equal "$($r.updateState) $($r.summary.installFailed) $($r.summary.remaining)" 'CompletedWithFailures 1 1' 'failure'
    Assert-Equal (Get-WduUpdateState 'Succeeded' ([ordered]@{ installed = @(); failed = @(); skipped = @(); requiresInteraction = @(); verification = [ordered]@{ rebootPending = $true; noLongerOffered = @() } })).state 'RestartRequired' 'restart pending'
    Assert-Equal (Get-WduUpdateState 'CompletedWithFollowUp' ([ordered]@{ installed = @(); failed = @(); skipped = @(); requiresInteraction = @(@{ title = 'x' }); verification = [ordered]@{ rebootPending = $false; noLongerOffered = @() } })).state 'UpdatesRemaining' 'needs a person'
    Assert-Equal (Get-WduUpdateState 'Failed' ([ordered]@{ installed = @(); failed = @(); skipped = @(); requiresInteraction = @() })).state 'InstallationIncomplete' 'stopped'
    Assert-Equal (Get-WduUpdateState 'Succeeded' ([ordered]@{ installed = @(); failed = @(); skipped = @(); requiresInteraction = @() })).state 'VerificationUnavailable' 'no verification: never up to date'
    $nav = Get-WduUpdateState 'CompletedWithFailures' ([ordered]@{ installed = @(); failed = @(@{ category = 'NotApplicable' }, @{ category = 'DownloadFailure' }); skipped = @(); requiresInteraction = @(); verification = [ordered]@{ rebootPending = $false; noLongerOffered = @(@{ title = 'old' }) } })
    Assert-Equal "$($nav.summary.notApplicable) $($nav.summary.downloadFailed) $($nav.summary.installFailed) $($nav.summary.superseded)" '1 1 0 1' 'not applicable, download failed and superseded counted apart'
}

$tests['engine 2.1.0 safety: the tests never reach the real Update Orchestrator'] = {
    Assert-Equal (Get-WduOrchestrator) 'sim-orchestrator' 'the boundary is simulated in this suite'
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
    Assert-Equal "$($cfg.readinessSearchAttempts) $($cfg.maxEngineExceptions) $($cfg.readinessRestart) $($cfg.verifyDevices)" '4 2 True True' 'engine 2.0.0 defaults'
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
