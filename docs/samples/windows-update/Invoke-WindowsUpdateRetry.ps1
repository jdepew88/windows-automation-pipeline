#Requires -Version 5.1
<#
.SYNOPSIS
    Retry Windows Update - Windows Deployment Builder recovery tool for an installed computer.

.DESCRIPTION
    Runs the corrected Windows Update engine (WindowsUpdateEngine.ps1, 2.0.0 or later, from the same
    folder) again on a computer that is already installed, without reinstalling Windows and without
    running the deployment again. Written for the spare-computer case: a deployment whose updates
    all failed with 0x80131508 because of the engine defect fixed in 2.0.0.

    Every retry is a separate run with its own folder, log, state, result and scheduled task:
        <dataRoot>\UpdateRetry\<runId>\   (engine.log, state.json, status.json, result.json, config.json)
        task \WindowsDeploymentBuilder\WindowsUpdateRetry  (SYSTEM; removed by the engine when final)
    The original deployment's files (<dataRoot>\Updates, reports) are only read, never changed.

    Modes
      Status             Read-only. Elevation, services, pending restart, installer busy, the original
                         deployment's update result (and whether it shows the engine defect), earlier
                         retries, devices with problems. Nothing is searched or changed.
      Scan               Read-only search: what would be installed now, by pass (A/B/C), with drivers
                         and the device each is for. Nothing is installed; no state is written.
      RetryUpdates       Installs normal updates (passes A and B: servicing prerequisites, cumulative,
                         security, Defender, .NET); no drivers and no optional updates.
      RetryDrivers       Installs drivers offered by Windows Update (optional ones included).
      RetryAll           Everything the deployment's policy allows (normally drivers and optional
                         updates included; feature updates and Insider builds never).
      ExportDiagnostics  Read-only. Copies logs, states, results and reports of the original run and
                         every retry, the Windows Update history and event log, services, devices, and
                         a before/after comparison into a ZIP on the desktop (or -OutputPath).

    A Retry* mode needs elevation. If an earlier retry of the same kind is unfinished it is resumed
    (its task is started again) unless -Fresh is given; -Fresh starts a new run with a fresh search,
    so updates given up earlier are tried again. Updates Windows already installed are not offered
    and are never reinstalled. The engine restarts the computer when an update requires it (with the
    usual warning) and continues after the restart through the task.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Invoke-WindowsUpdateRetry.ps1 -Mode Status
.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Invoke-WindowsUpdateRetry.ps1 -Mode RetryUpdates -Wait
.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Invoke-WindowsUpdateRetry.ps1 -Mode ExportDiagnostics
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Scan', 'RetryUpdates', 'RetryDrivers', 'RetryAll', 'ExportDiagnostics')]
    [string] $Mode = 'Status',
    [string] $DataRoot = 'C:\ProgramData\WindowsDeploymentBuilder',
    [switch] $Fresh,
    [switch] $Wait,
    [int] $WaitMinutes = 240,
    [string] $OutputPath = '',
    [switch] $Json
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ToolVersion = '1.0.0'
$script:TaskPath = '\WindowsDeploymentBuilder\'
$script:TaskName = 'WindowsUpdateRetry'
$script:EngineFile = 'WindowsUpdateEngine.ps1'

# ------------------------------------------------------------------------------------------------
# Replaceable system access (tests replace these)
# ------------------------------------------------------------------------------------------------

function Test-WurAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WurNow { [DateTime]::UtcNow }

function Get-WurTask {
    try { return (Get-ScheduledTask -TaskName $script:TaskName -TaskPath $script:TaskPath -ErrorAction Stop) } catch { return $null }
}

function Register-WurTask {
    param([string] $EnginePath, [string] $ConfigPath, [int] $MaxRuntimeHours)
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $powershell -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$EnginePath`" -ConfigPath `"$ConfigPath`""
    $atStartup = New-ScheduledTaskTrigger -AtStartup
    $atStartup.Delay = 'PT2M'
    $hourly = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(30) -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 2)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours ($MaxRuntimeHours + 1)) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $script:TaskName -TaskPath $script:TaskPath -Action $action -Trigger @($atStartup, $hourly) `
        -Principal $principal -Settings $settings -Force -Description 'Windows Deployment Builder: Retry Windows Update (removes itself when finished).' | Out-Null
}

function Start-WurTask { Start-ScheduledTask -TaskName $script:TaskName -TaskPath $script:TaskPath }

function Wait-WurPoll { param([int] $Seconds) Start-Sleep -Seconds $Seconds }

function Get-WurServices {
    $out = [ordered]@{}
    foreach ($n in 'wuauserv', 'bits', 'cryptsvc', 'TrustedInstaller', 'UsoSvc', 'WaaSMedicSvc') {
        try { $s = Get-Service -Name $n -ErrorAction Stop; $out[$n] = [ordered]@{ status = [string] $s.Status; startType = $(try { [string] $s.StartType } catch { 'Unknown' }) } }
        catch { $out[$n] = [ordered]@{ status = 'Missing'; startType = 'Missing' } }
    }
    $out
}

function Get-WurRestartPending {
    $why = @()
    try { if ((New-Object -ComObject 'Microsoft.Update.SystemInfo').RebootRequired) { $why += 'Windows Update' } } catch { }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $why += 'Component Based Servicing' }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $why += 'Windows Update (registry)' }
    , @($why)
}

function Test-WurInstallerBusy { try { return [bool] (New-Object -ComObject 'Microsoft.Update.Installer').IsBusy } catch { return $null } }

function Get-WurDevices {
    $list = @()
    try {
        foreach ($d in @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop)) {
            $code = 0; try { $code = [int] $d.ConfigManagerErrorCode } catch { }
            if ($code -ne 0) { $list += [ordered]@{ name = [string] $d.Name; deviceId = [string] $d.DeviceID; problemCode = $code } }
        }
    } catch { }
    , @($list)
}

<# Windows Update history (read-only, IUpdateSearcher.QueryHistory), newest first. #>
function Get-WurHistory {
    param([int] $Max = 200)
    $rows = @()
    try {
        $searcher = (New-Object -ComObject 'Microsoft.Update.Session').CreateUpdateSearcher()
        $n = [Math]::Min($Max, [int] $searcher.GetTotalHistoryCount())
        if ($n -gt 0) {
            $h = $searcher.QueryHistory(0, $n)
            for ($i = 0; $i -lt [int] $h.Count; $i++) {
                $e = $h.Item($i)
                $rows += [ordered]@{ date = ([DateTime] $e.Date).ToUniversalTime().ToString('o'); title = [string] $e.Title; operation = [int] $e.Operation; resultCode = [int] $e.ResultCode; hresult = ('0x{0:X8}' -f ([int64] $e.HResult -band 4294967295)); client = [string] $e.ClientApplicationID }
            }
        }
    } catch { $rows += [ordered]@{ error = $_.Exception.Message } }
    , @($rows)
}

function Get-WurEvents {
    try { return @(Get-WinEvent -LogName 'Microsoft-Windows-WindowsUpdateClient/Operational' -MaxEvents 300 -ErrorAction Stop | ForEach-Object { [ordered]@{ time = $_.TimeCreated.ToUniversalTime().ToString('o'); id = $_.Id; level = [string] $_.LevelDisplayName; message = [string] $_.Message } }) }
    catch { return @() }
}

# ------------------------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------------------------

function ConvertTo-WurHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { $h = @{}; foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-WurHashtable $InputObject[$k] }; return $h }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) { $h = @{}; foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-WurHashtable $p.Value }; return $h }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) { return , @($InputObject | ForEach-Object { ConvertTo-WurHashtable $_ }) }
    return $InputObject
}

function Read-WurJson {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return ConvertTo-WurHashtable (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { return $null }
}

function Write-WurJson {
    param([string] $Path, $Value)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, ($Value | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Get-WurCount { param($Value) if ($null -eq $Value) { return 0 }; return @($Value | Where-Object { $null -ne $_ }).Count }

<#
    Summary of one engine result.json: status, counts, failures by category and HRESULT, engine
    exceptions, and whether it shows the 1.x collection defect (every failure 0x80131508 and nothing
    installed by the engine).
#>
function Get-WurResultSummary {
    param($Result, [string] $Label)
    if (-not $Result) { return $null }
    $failed = @($Result['failed'] | Where-Object { $_ })
    $codes = [ordered]@{}
    foreach ($f in $failed) { $c = [string] $f['lastHResult']; if (-not $c) { $c = 'none' }; $codes[$c] = 1 + [int] $codes[$c] }
    $installed = Get-WurCount $Result['installed']
    $engine = [string] $Result['engineVersion']
    $defect = $failed.Count -gt 0 -and $installed -eq 0 -and (@($failed | Where-Object { [string] $_['lastHResult'] -eq '0x80131508' }).Count -eq $failed.Count) -and ($engine -match '^1\.')
    [ordered]@{
        label = $Label
        status = [string] $Result['status']
        reason = [string] $Result['reason']
        engineVersion = $engine
        finishedUtc = [string] $Result['finishedUtc']
        installed = $installed
        failed = $failed.Count
        requiresInteraction = Get-WurCount $Result['requiresInteraction']
        failedByHResult = $codes
        failedByCategory = $(if ($Result['failedByCategory']) { $Result['failedByCategory'] } else { [ordered]@{} })
        engineExceptions = Get-WurCount $Result['engineExceptions']
        reboots = [int] $Result['reboots']
        collectionDefect = [bool] $defect
        devicesWithProblems = $(if ($Result['verification']) { Get-WurCount $Result['verification']['devicesWithProblems'] } else { $null })
        failedTitles = @($failed | ForEach-Object { "$((@($_['kbs']) -join ',')) $($_['title'])".Trim() })
    }
}

function Get-WurRuns {
    param([string] $DataRoot)
    $root = Join-Path $DataRoot 'UpdateRetry'
    # Returns the runs as plain pipeline output: callers wrap the call in @().
    if (-not (Test-Path -LiteralPath $root)) { return }
    $runs = @()
    foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $cfg = Read-WurJson (Join-Path $d.FullName 'config.json')
        $res = Read-WurJson (Join-Path $d.FullName 'result.json')
        $st = Read-WurJson (Join-Path $d.FullName 'state.json')
        $runs += [ordered]@{ runId = $d.Name; path = $d.FullName; selection = $(if ($cfg) { [string] $cfg['selection'] } else { '' }); final = $(if ($st) { [string] $st['final'] } else { '' }); result = (Get-WurResultSummary $res $d.Name) }
    }
    $runs
}

function Get-WurEnginePath {
    $p = Join-Path $PSScriptRoot $script:EngineFile
    if (-not (Test-Path -LiteralPath $p)) { throw "The corrected engine $script:EngineFile is not next to this tool ($PSScriptRoot)." }
    $text = Get-Content -LiteralPath $p -Raw
    $m = [regex]::Match($text, "\`$script:EngineVersion = '([0-9.]+)'")
    if (-not $m.Success -or [version] $m.Groups[1].Value -lt [version] '2.0.0') { throw "The engine next to this tool is $($m.Groups[1].Value); Retry Windows Update needs engine 2.0.0 or later (the 0x80131508 fix)." }
    [ordered]@{ path = $p; version = $m.Groups[1].Value }
}

<# The deployment's own update policy (config.json of the original engine), or safe defaults. #>
function Get-WurBaseConfig {
    param([string] $DataRoot)
    $cfg = Read-WurJson (Join-Path (Join-Path $DataRoot 'Updates') 'config.json')
    if (-not $cfg) { $cfg = @{ drivers = 'include'; optionalUpdates = 'install'; featureUpdates = 'skip'; microsoftUpdate = $false; excludedKbs = @() } }
    $cfg
}

<# Configuration for a retry run: the deployment's policy, the chosen selection, its own folder, marker and task. #>
function New-WurRunConfig {
    param([string] $DataRoot, [string] $Selection, [string] $RunId)
    $base = Get-WurBaseConfig $DataRoot
    $c = @{}
    foreach ($k in 'featureUpdates', 'microsoftUpdate', 'excludedKbs', 'maxAttemptsPerUpdate', 'rebootWarningSeconds') { if ($base.ContainsKey($k)) { $c[$k] = $base[$k] } }
    if (-not $c.ContainsKey('featureUpdates') -or $c.featureUpdates -ne 'install') { $c.featureUpdates = 'skip' }
    switch ($Selection) {
        'normal'  { $c.drivers = 'exclude'; $c.optionalUpdates = 'skip' }
        'drivers' { $c.drivers = 'include'; $c.optionalUpdates = 'install' }
        default   { $c.drivers = $(if ($base['drivers'] -eq 'exclude') { 'exclude' } else { 'include' }); $c.optionalUpdates = $(if ($base['optionalUpdates']) { [string] $base['optionalUpdates'] } else { 'install' }) }
    }
    $c.selection = $(if ($Selection -eq 'all') { 'configured' } else { $Selection })
    $c.dataRoot = $DataRoot
    $c.workFolder = "UpdateRetry\$RunId"
    $c.markerName = 'windows-update-retry.done'
    $c.taskPath = $script:TaskPath
    $c.taskName = $script:TaskName
    $c.mutexName = 'Global\WindowsDeploymentBuilder-WindowsUpdate'
    $c.maxReboots = 5
    $c.maxRuntimeHours = 8
    $c.initialDelaySeconds = 0
    $c.resetComponentsOnce = $true
    $c.lockWaitMinutes = 10
    $c.retryRunId = $RunId
    $c
}

# ------------------------------------------------------------------------------------------------
# Modes
# ------------------------------------------------------------------------------------------------

function Get-WurStatus {
    param([string] $DataRoot)
    $original = Read-WurJson (Join-Path (Join-Path $DataRoot 'Updates') 'result.json')
    $origSummary = Get-WurResultSummary $original 'original deployment'
    $pending = Get-WurRestartPending
    $task = Get-WurTask
    $s = [ordered]@{
        tool = $script:ToolVersion
        computer = $env:COMPUTERNAME
        atUtc = (Get-WurNow).ToString('o')
        elevated = [bool] (Test-WurAdmin)
        services = Get-WurServices
        restartPending = (@($pending).Count -gt 0)
        restartPendingBecause = @($pending)
        installerBusy = Test-WurInstallerBusy
        original = $origSummary
        retries = @(Get-WurRuns $DataRoot)
        retryTask = $(if ($task) { [string] $task.State } else { 'not registered' })
        devicesWithProblems = Get-WurDevices
        advice = @()
    }
    if (-not $s.elevated) { $s.advice += 'Run the Retry modes from an elevated Windows PowerShell (Run as administrator).' }
    foreach ($n in 'wuauserv', 'bits') { if ($s.services[$n]['startType'] -eq 'Disabled') { $s.advice += "The $n service is disabled; set it back to Manual before retrying." } }
    if ($s.restartPending) { $s.advice += 'Windows has a restart pending; the retry restarts once before installing (or restart now).' }
    if ($origSummary -and $origSummary.collectionDefect) {
        $s.advice += "The original deployment used engine $($origSummary.engineVersion): its $($origSummary.failed) failure(s) with 0x80131508 are the engine's collection defect (fixed in 2.0.0), not update failures. Run -Mode RetryUpdates, then -Mode RetryDrivers."
    }
    if (@($s.retries | Where-Object { -not $_.final }).Count) { $s.advice += 'An earlier retry is unfinished; a Retry mode of the same kind resumes it (add -Fresh for a new run).' }
    $s
}

function Show-WurStatus {
    param($S)
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add("Retry Windows Update $($S.tool) - $($S.computer) - $($S.atUtc)")
    $l.Add("  Elevated: $($S.elevated). Restart pending: $($S.restartPending)$(if ($S.restartPending) { " ($(@($S.restartPendingBecause) -join ', '))" }). Installer busy: $($S.installerBusy).")
    $l.Add('  Services: ' + ((@($S.services.Keys) | ForEach-Object { "$_ $($S.services[$_]['status'])/$($S.services[$_]['startType'])" }) -join ', '))
    if ($S.original) {
        $o = $S.original
        $l.Add("  Original deployment: $($o.status) (engine $($o.engineVersion)), installed $($o.installed), failed $($o.failed), engine exceptions $($o.engineExceptions).")
        if (@($o.failedByHResult.Keys).Count) { $l.Add('    failures by code: ' + ((@($o.failedByHResult.Keys) | ForEach-Object { "$_ x$($o.failedByHResult[$_])" }) -join ', ')) }
        if ($o.collectionDefect) { $l.Add('    -> engine 1.x collection defect (0x80131508): these updates were never offered to Windows Update by the engine.') }
    } else { $l.Add('  Original deployment: no update result found.') }
    foreach ($r in @($S.retries)) { $l.Add("  Retry $($r.runId) [$($r.selection)]: $(if ($r.final) { $r.final } else { 'unfinished' })$(if ($r.result) { ", installed $($r.result.installed), failed $($r.result.failed)" })") }
    $l.Add("  Retry task: $($S.retryTask). Devices with problems: $(@($S.devicesWithProblems).Count).")
    foreach ($d in @($S.devicesWithProblems)) { $l.Add("    code $($d.problemCode)  $($d.name)") }
    foreach ($a in @($S.advice)) { $l.Add("  NEXT: $a") }
    $l -join "`r`n"
}

function Invoke-WurScan {
    param([string] $DataRoot)
    $engine = Get-WurEnginePath
    . $engine.path
    $cfg = New-WurRunConfig $DataRoot 'all' 'scan'
    foreach ($k in @($script:ConfigDefaults.Keys)) { if (-not $cfg.ContainsKey($k)) { $cfg[$k] = $script:ConfigDefaults[$k] } }
    $scan = Invoke-WduScan $cfg
    [ordered]@{ engineVersion = $engine.version; rebootPending = $scan.RebootPending; installerBusy = $scan.InstallerBusy; updates = @($scan.Updates) }
}

function Start-WurRetry {
    param([string] $DataRoot, [string] $Selection, [switch] $Fresh)
    if (-not (Test-WurAdmin)) { throw 'Retry modes must run elevated (Run as administrator).' }
    $engine = Get-WurEnginePath
    $status = Get-WurStatus $DataRoot
    foreach ($n in 'wuauserv', 'bits') { if ($status.services[$n]['startType'] -eq 'Disabled') { throw "The $n service is disabled. Set it back to Manual first; nothing was changed." } }
    $runs = @(Get-WurRuns $DataRoot)
    $open = @($runs | Where-Object { -not $_.final -and $_.selection -eq $(if ($Selection -eq 'all') { 'configured' } else { $Selection }) })
    $installDir = Join-Path $DataRoot 'UpdateRetry'
    $engineCopy = Join-Path $installDir $script:EngineFile
    if (-not (Test-Path -LiteralPath $installDir)) { New-Item -ItemType Directory -Path $installDir -Force | Out-Null }
    # The data root is already protected by the deployment (SYSTEM/Administrators full, Users read); the
    # retry folder inherits that. The engine copy runs as SYSTEM from there.
    Copy-Item -LiteralPath $engine.path -Destination $engineCopy -Force
    if ($open.Count -and -not $Fresh) {
        $run = $open[-1]
        $cfgPath = Join-Path $run.path 'config.json'
        $resumed = $true
    } else {
        $runId = '{0}-{1}' -f (Get-WurNow).ToString('yyyyMMdd-HHmmss'), $Selection
        $cfg = New-WurRunConfig $DataRoot $Selection $runId
        $cfgPath = Join-Path (Join-Path $installDir $runId) 'config.json'
        Write-WurJson $cfgPath $cfg
        $run = [ordered]@{ runId = $runId; path = (Split-Path -Parent $cfgPath) }
        $resumed = $false
    }
    Register-WurTask $engineCopy $cfgPath 8
    Start-WurTask
    [ordered]@{ runId = $run.runId; folder = $run.path; config = $cfgPath; resumed = $resumed; engineVersion = $engine.version; task = "$script:TaskPath$script:TaskName"
        log = (Join-Path (Join-Path $run.path 'logs') 'engine.log'); result = (Join-Path $run.path 'result.json') }
}

function Wait-WurRetry {
    param($Run, [int] $Minutes)
    $statusFile = Join-Path $Run.folder 'status.json'
    $resultFile = Join-Path $Run.folder 'result.json'
    $deadline = (Get-WurNow).AddMinutes($Minutes)
    $last = ''
    while ((Get-WurNow) -lt $deadline) {
        $r = Read-WurJson $resultFile
        if ($r) { return $r }
        $s = Read-WurJson $statusFile
        if ($s) {
            $line = "$($s['phase']): $($s['detail'])"
            if ($line -ne $last) { Write-Output ('{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $line); $last = $line }
            if ($s['phase'] -eq 'Rebooting') { Write-Output 'The computer restarts now; the retry continues automatically after the restart. Run -Mode Status afterwards.'; return $null }
        }
        Wait-WurPoll 10
    }
    Write-Output "Still running after $Minutes minutes; it continues in the background. Check with -Mode Status."
    return $null
}

<# Before/after comparison of the original deployment and every retry (also in the diagnostics ZIP). #>
function Get-WurComparison {
    param([string] $DataRoot)
    $orig = Get-WurResultSummary (Read-WurJson (Join-Path (Join-Path $DataRoot 'Updates') 'result.json')) 'original deployment'
    $runs = @(Get-WurRuns $DataRoot | Where-Object { $_.result })
    $rows = @()
    if ($orig) { $rows += $orig }
    foreach ($r in $runs) { $rows += $r.result }
    $fixed = @()
    if ($orig) {
        $later = @($runs | ForEach-Object { $_.result.failedTitles })
        $installedLater = @()
        foreach ($r in $runs) {
            $res = Read-WurJson (Join-Path $r.path 'result.json')
            $installedLater += @($res['installed'] | Where-Object { $_ } | ForEach-Object { "$((@($_['kbs']) -join ',')) $($_['title'])".Trim() })
        }
        $fixed = @($orig.failedTitles | Where-Object { $installedLater -contains $_ })
        $stillFailing = @($orig.failedTitles | Where-Object { $later -contains $_ })
    } else { $stillFailing = @() }
    [ordered]@{ runs = @($rows); originalFailuresInstalledByRetry = @($fixed); originalFailuresStillFailing = @($stillFailing); devicesNow = Get-WurDevices }
}

function Format-WurComparison {
    param($C)
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add('Windows Update: original deployment versus retries')
    $l.Add(('{0,-34} {1,-22} {2,9} {3,7} {4,7} {5,8}' -f 'Run', 'Status', 'Installed', 'Failed', 'Engine', 'Devices'))
    foreach ($r in @($C.runs)) { $l.Add(('{0,-34} {1,-22} {2,9} {3,7} {4,7} {5,8}' -f $r.label, $r.status, $r.installed, $r.failed, $r.engineVersion, $(if ($null -ne $r.devicesWithProblems) { $r.devicesWithProblems } else { '-' }))) }
    $l.Add("Original failures installed by a retry: $(@($C.originalFailuresInstalledByRetry).Count)")
    foreach ($t in @($C.originalFailuresInstalledByRetry)) { $l.Add("  fixed  $t") }
    $l.Add("Original failures that still fail: $(@($C.originalFailuresStillFailing).Count)")
    foreach ($t in @($C.originalFailuresStillFailing)) { $l.Add("  still  $t") }
    $l.Add("Devices with problems now: $(@($C.devicesNow).Count)")
    foreach ($d in @($C.devicesNow)) { $l.Add("  code $($d.problemCode)  $($d.name)  [$($d.deviceId)]") }
    $l -join "`r`n"
}

function Export-WurDiagnostics {
    param([string] $DataRoot, [string] $OutputPath)
    $stamp = (Get-WurNow).ToString('yyyyMMdd-HHmmss')
    if (-not $OutputPath) { $OutputPath = Join-Path ([Environment]::GetFolderPath('Desktop')) "WDB-WindowsUpdate-diagnostics-$env:COMPUTERNAME-$stamp.zip" }
    $work = Join-Path ([IO.Path]::GetTempPath()) "wdb-wu-diag-$stamp"
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        # Copies only: the originals stay where they are.
        foreach ($rel in 'Updates', 'UpdateRetry', 'reports', 'Deployment') {
            $src = Join-Path $DataRoot $rel
            if (Test-Path -LiteralPath $src) {
                $dst = Join-Path $work $rel
                New-Item -ItemType Directory -Path $dst -Force | Out-Null
                Get-ChildItem -LiteralPath $src -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.json', '.log', '.txt', '.jsonl', '.1', '.bak', '.corrupt' -and $_.Name -notlike '*.ps1' } | ForEach-Object {
                    $relPath = $_.FullName.Substring($src.Length).TrimStart('\')
                    $target = Join-Path $dst $relPath
                    $tdir = Split-Path -Parent $target
                    if (-not (Test-Path -LiteralPath $tdir)) { New-Item -ItemType Directory -Path $tdir -Force | Out-Null }
                    Copy-Item -LiteralPath $_.FullName -Destination $target -ErrorAction SilentlyContinue
                }
            }
        }
        Write-WurJson (Join-Path $work 'status.json') (Get-WurStatus $DataRoot)
        $cmp = Get-WurComparison $DataRoot
        Write-WurJson (Join-Path $work 'comparison.json') $cmp
        [System.IO.File]::WriteAllText((Join-Path $work 'comparison.txt'), (Format-WurComparison $cmp), (New-Object System.Text.UTF8Encoding($false)))
        Write-WurJson (Join-Path $work 'windows-update-history.json') (Get-WurHistory)
        Write-WurJson (Join-Path $work 'windows-update-events.json') (Get-WurEvents)
        Write-WurJson (Join-Path $work 'devices-with-problems.json') (Get-WurDevices)
        if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
        Compress-Archive -Path (Join-Path $work '*') -DestinationPath $OutputPath -Force
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
    [ordered]@{ zip = $OutputPath; comparison = $cmp }
}

# ------------------------------------------------------------------------------------------------
# Entry point (dot-sourcing only defines the functions)
# ------------------------------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    try {
        switch ($Mode) {
            'Status' {
                $s = Get-WurStatus $DataRoot
                if ($Json) { $s | ConvertTo-Json -Depth 10 } else { Show-WurStatus $s }
                exit 0
            }
            'Scan' {
                $r = Invoke-WurScan $DataRoot
                if ($Json) { $r | ConvertTo-Json -Depth 8 } else {
                    @($r.updates) | Format-Table -AutoSize -Wrap | Out-String -Width 220
                    "Engine $($r.engineVersion). Restart pending: $($r.rebootPending). Installer busy: $($r.installerBusy). Nothing was installed."
                }
                exit 0
            }
            'ExportDiagnostics' {
                $r = Export-WurDiagnostics $DataRoot $OutputPath
                "Diagnostics: $($r.zip)"
                Format-WurComparison $r.comparison
                exit 0
            }
            default {
                $sel = switch ($Mode) { 'RetryUpdates' { 'normal' } 'RetryDrivers' { 'drivers' } default { 'all' } }
                $run = Start-WurRetry $DataRoot $sel -Fresh:$Fresh
                "$(if ($run.resumed) { 'Resumed' } else { 'Started' }) retry $($run.runId) with engine $($run.engineVersion) (task $($run.task))."
                "Log: $($run.log)"
                "Result (when finished): $($run.result)"
                if ($Wait) {
                    $res = Wait-WurRetry $run $WaitMinutes
                    if ($res) { "Finished: $($res['status']). $($res['reason'])"; Format-WurComparison (Get-WurComparison $DataRoot) }
                }
                exit 0
            }
        }
    } catch {
        Write-Output "ERROR: $($_.Exception.Message)"
        exit 1
    }
}
