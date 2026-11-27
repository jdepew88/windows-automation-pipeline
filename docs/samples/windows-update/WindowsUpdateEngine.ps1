#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Deployment Builder - unattended Windows Update engine.

.DESCRIPTION
    Installs applicable Windows updates through the documented Windows Update Agent (WUA) COM API,
    reboots when required, resumes after each reboot through a SYSTEM scheduled task, and repeats
    until nothing applicable remains. Written independently for this project; no third-party code
    or modules.

    Modes:
      Run   (default) Full engine. Must run elevated (normally as SYSTEM from the scheduled task).
      Scan  Read-only: searches for updates and prints how each one would be handled. Installs
            nothing, writes no state, needs no elevation.

    Final states (result.json, Application event log source "WindowsDeploymentBuilder"):
      Succeeded               Nothing applicable remains.
      CompletedWithFollowUp   Everything else is installed; some updates need a person to
                              finish them (Windows reported that they need an interactive user).
      CompletedWithFailures   Everything else is installed, but some updates failed repeatedly
                              and were given up.
      Failed                  A limit was reached (reboots, runtime, errors) or scanning failed.
      Offline                 No network was available before the runtime limit.

    On Succeeded, CompletedWithFollowUp and CompletedWithFailures the marker <dataRoot>\state\windows-update.done is
    written for the deployment orchestrator. The scheduled task is removed on every final state.

    Coordination (1.1.0, Phase 3): updates are installed and restarts are scheduled only while
    holding the machine-wide install lock shared with the application engine, so Windows Update
    never restarts the computer during an application installation. When the lock stays busy the
    engine exits with WaitingForLock or RebootDeferred (not final) and tries again at the next
    start or hourly trigger. The final states above are unchanged.

    Engine 1.2.0 (deployment reliability):
      - Selection: everything Windows Update offers as applicable (IsInstalled=0, IsHidden=0) is
        installed: recommended updates, and with optionalUpdates=install the optional ones
        (IUpdate.BrowseOnly: optional cumulative previews and optional driver updates). Feature
        updates (category Upgrades, "Feature update to Windows ..." enablement packages) and Insider
        builds are never installed unless featureUpdates=install (Insider: never).
      - An update that CAN request user input (InstallationBehavior.CanRequestUserInput) is no
        longer skipped on that flag alone: it is installed on its own, quietly (ForceQuiet). Only
        when Windows answers that it needs an interactive user, or aborts it, is it reported as
        requiring interaction (CompletedWithFollowUp), and never retried in a loop.
      - Each update is downloaded on its own, so a failed download does not hold back the others
        and the status names the update being downloaded. A transient failure is retried after a
        delay, up to maxAttemptsPerUpdate attempts in total (download and installation count);
        a permanent failure (for example WU_E_NOT_APPLICABLE) is not retried. The HRESULT and its
        name are kept.
      - status.json carries the current update, the attempt, the last error and the counts.
        Download progress (bytes, speed) is not reported: the synchronous WUA calls used here do
        not expose it, and nothing is estimated.
    New final state: CompletedWithFollowUp (only updates that need a person remain).

    Engine 1.3.0 (bare-metal review):
      - An error raised by the engine's own WUA call (an exception, for example a .NET
        0x80131508) is recorded apart from Windows Update's per-update result (errorSource,
        exception), and the next attempt uses a new WUA session.
      - An update whose last attempt fails while Windows has a restart pending is retried once
        after the restart (the engine restarts for it); a second failure is final.

    Engine 2.0.0 (0x80131508 repair, readiness, passes):
      - ROOT CAUSE of the field failures "0x80131508 IndexOutOfRangeException: Index was outside
        the bounds of the array" on every update: New-WduCollection returned its
        Microsoft.Update.UpdateColl through the PowerShell pipeline, which enumerates COM
        collections. The caller therefore received the bare IUpdate (one update), an Object[]
        (several) or $null (none) instead of the collection, and PowerShell's COM property setter
        `$downloader.Updates = ...` / `$installer.Updates = ...` throws IndexOutOfRangeException for
        any value that is not an IUpdateCollection. Reproduced read-only on Windows 11 / PowerShell
        5.1. Every download and installation since engine 1.0.0 failed this way before Windows
        Update was called, so the engine itself never installed anything; Windows' own automatic
        updates installed what was installed, and optional drivers (which Windows does not install
        automatically) were all reported as failed. Retries and component resets could not help.
        Fixed by returning the collection with the unary comma, verifying its type and count
        before every assignment (Assert-WduCollection), and mapping results by update identity.
      - Every Windows Update call runs as a named operation; an exception records the operation,
        exception type, HRESULT, message, script line and stack trace (engineExceptions in
        state.json and result.json). An exception in the engine's own code is ONE engine error,
        not one installer failure per update: the updates' attempts are not used up by it, a batch
        is retried one update at a time to isolate it, and the same exception at the same line
        twice stops the stage (EngineException, technician action) instead of looping, resetting
        components or holding the applications back.
      - Failure categories (category on every failed/attempted update, see Get-WduCategory).
      - First-start readiness (readiness in result.json): network, service start types, Windows
        Update agent enabled, installer/servicing busy, restart already pending (one restart
        before installing anything), a successful search as the proof that the agent is ready
        (bounded retries, never an arbitrary wait), prerequisite classification.
      - Ordered passes: A servicing prerequisites (servicing stack, Defender platform) alone
        first, restart if required, new session, search again; B normal updates (cumulative,
        security, .NET, Defender intelligence, MSRT); C optional updates and drivers, each driver
        on its own with the device it is for (hardware ID, model, class); D verification: search
        again, installed updates must no longer be offered, updates that disappeared are recorded
        as no longer offered (superseded or no longer applicable), devices with problems listed.
      - Components are reset only when the failures point at the update data store or download
        cache (Test-WduResetWarranted), never for engine exceptions, network or not-applicable.
#>
[CmdletBinding()]
param(
    [ValidateSet('Run', 'Scan')]
    [string] $Mode = 'Run',
    [string] $ConfigPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:EngineVersion = '2.1.0'
# Engine 2.1.0: why the Update Orchestrator API could not be used, and where the state is saved during a refresh.
$script:WduOrchestratorError = ''
$script:WduStatePaths = $null
$script:UpgradeCategoryId = '3689bdc8-b205-4af4-8d4b-a63924c5e9d5'   # WUA category "Upgrades"
$script:MicrosoftUpdateServiceId = '7971f918-a847-4430-9279-4a52d1efe18d'
$script:EventSource = 'WindowsDeploymentBuilder'
$script:Session = $null
$script:LogFile = $null
$script:StatusFile = $null
# What the engine is doing right now, added to every status.json (current update, attempt, last error).
$script:Activity = @{}

<#
    Windows Update Agent and Win32 results (wuerror.h, winerror.h, winhttp.h) that appear when
    downloading or installing, with their documented names. Permanent ones are never retried: the
    update is not applicable, or it can only be finished by a person.
#>
$script:HResults = @{
    # name, meaning, permanent (never retried), category (engine 2.0.0, see Get-WduCategory)
    '0x80240016' = @('WU_E_INSTALL_NOT_ALLOWED', 'another installation is in progress or a restart is pending', $false, 'ServicingBusy')
    '0x80240017' = @('WU_E_NOT_APPLICABLE', 'the update is not applicable to this computer', $true, 'NotApplicable')
    '0x80240020' = @('WU_E_NO_INTERACTIVE_USER', 'the update needs a signed-in user to finish', $true, 'TechnicianRequired')
    '0x80240022' = @('WU_E_ALL_UPDATES_FAILED', 'every update in the operation failed', $false, 'InstallerFailure')
    '0x8024000B' = @('WU_E_CALL_CANCELLED', 'the operation was cancelled', $false, 'ComApiException')
    '0x8024001E' = @('WU_E_SERVICE_STOP', 'the operation stopped because the service or Windows was shutting down', $false, 'NotReady')
    '0x8024001F' = @('WU_E_NO_CONNECTION', 'there is no network connection', $false, 'TransientNetwork')
    '0x8024200D' = @('WU_E_UH_NEEDANOTHERDOWNLOAD', 'more content must be downloaded', $false, 'DownloadFailure')
    '0x8024401C' = @('WU_E_PT_HTTP_STATUS_REQUEST_TIMEOUT', 'the update server did not answer in time', $false, 'TransientNetwork')
    '0x8024402C' = @('WU_E_PT_WINHTTP_NAME_NOT_RESOLVED', 'the update server name could not be resolved', $false, 'TransientNetwork')
    '0x80244022' = @('WU_E_PT_HTTP_STATUS_SERVICE_UNAVAIL', 'the update service was temporarily unavailable (HTTP 503)', $false, 'TransientNetwork')
    '0x80246007' = @('WU_E_DM_NOTDOWNLOADED', 'the update has not been downloaded', $false, 'DownloadFailure')
    '0x80246008' = @('WU_E_DM_FAILTOCONNECTTOBITS', 'the Background Intelligent Transfer Service could not be reached', $false, 'DownloadFailure')
    '0x80070422' = @('ERROR_SERVICE_DISABLED', 'a required service is disabled', $false, 'NotReady')
    '0x80070BC9' = @('ERROR_FAIL_REBOOT_REQUIRED', 'a restart is required before the update can be installed', $false, 'RebootRequired')
    '0x80072EE2' = @('ERROR_INTERNET_TIMEOUT', 'the connection timed out', $false, 'TransientNetwork')
    '0x80072EFD' = @('ERROR_INTERNET_CANNOT_CONNECT', 'the server could not be reached', $false, 'TransientNetwork')
    '0x80072F8F' = @('ERROR_INTERNET_SECURE_FAILURE', 'the secure connection failed (check the date and time)', $false, 'TransientNetwork')
    '0x80092004' = @('CRYPT_E_NOT_FOUND', 'a signature catalog entry was not found (catalog database)', $false, 'DownloadFailure')
    '0x800F0922' = @('CBS_E_INSTALLERS_FAILED', 'the servicing stack could not apply the update', $false, 'InstallerFailure')
    '0x800F081F' = @('CBS_E_SOURCE_MISSING', 'the servicing stack could not find source files (component store repair: DISM /RestoreHealth)', $false, 'InstallerFailure')
    '0x80073701' = @('ERROR_SXS_ASSEMBLY_MISSING', 'a component the update needs is missing (component store repair: DISM /RestoreHealth)', $false, 'InstallerFailure')
    '0x80073712' = @('ERROR_SXS_COMPONENT_STORE_CORRUPT', 'the component store is damaged (component store repair: DISM /RestoreHealth)', $false, 'InstallerFailure')
    # .NET errors (facility 0x13) are raised by code, never by Windows Update's own result. Engine
    # 2.0.0: up to 1.3.0 every 0x80131508 came from the engine itself (see the header); a .NET code
    # in a per-update result would come from that update's own command-line installer.
    '0x80131508' = @('COR_E_INDEXOUTOFRANGE', '.NET "index out of range" exception: raised by code, not a Windows Update result', $false, 'EngineException')
    '0x80131509' = @('COR_E_INVALIDOPERATION', '.NET "invalid operation" exception: raised by code, not a Windows Update result', $false, 'EngineException')
    '0x80004003' = @('E_POINTER', 'null reference raised by code, not a Windows Update result', $false, 'EngineException')
}

<#
    Failure categories (engine 2.0.0). Every failure is recorded with exactly one:
      EngineException     an exception in this engine's own PowerShell code around a WUA call
      ComApiException     the WUA COM call itself raised an error (COMException, WU_E_* code)
      NativeResultFailure Windows Update returned Failed/Aborted for the update (not otherwise known)
      NotApplicable       Windows says the update does not apply (never retried)
      Superseded          offered earlier, no longer offered and not installed (superseded or no
                          longer applicable; WUA does not say which)
      TransientNetwork    the network or the update service was temporarily unavailable
      DownloadFailure     the download failed (BITS, download cache, catalog database)
      InstallerFailure    the update's installer or the servicing stack failed
      RebootRequired      Windows needs a restart before it can install it
      ServicingBusy       another installation or servicing operation is running
      NotReady            the Windows Update service is disabled, stopping or not initialised
      SearchFailure       searching for updates failed
      TechnicianRequired  Windows says a signed-in person is needed
#>
$script:Categories = @('EngineException', 'ComApiException', 'NativeResultFailure', 'NotApplicable', 'Superseded', 'TransientNetwork', 'DownloadFailure', 'InstallerFailure', 'RebootRequired', 'ServicingBusy', 'NotReady', 'SearchFailure', 'TechnicianRequired')

# Categories whose repeated failures point at the data store / download cache, the only problems a
# reset of SoftwareDistribution and catroot2 can fix.
$script:ResetCategories = @('DownloadFailure')
$script:ResetHResultPrefixes = @('0x80246', '0x80248')

# ------------------------------------------------------------------------------------------------
# Small helpers (time, waiting, JSON) - kept as functions so tests can replace them.
# ------------------------------------------------------------------------------------------------

function Get-WduNow { [DateTime]::UtcNow }

function Wait-Wdu { param([int] $Seconds) if ($Seconds -gt 0) { Start-Sleep -Seconds $Seconds } }

function ConvertTo-WduDate {
    param($Value)
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    [DateTime]::Parse([string] $Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

function Format-WduHResult {
    param($HResult)
    if ($null -eq $HResult) { return '' }
    '0x{0:X8}' -f ([int64] $HResult -band [int64] 4294967295)
}

<# "0x80240017 WU_E_NOT_APPLICABLE (the update is not applicable to this computer)", or the code alone. #>
function Get-WduHResultText {
    param([string] $Hex)
    if (-not $Hex) { return '' }
    $m = $script:HResults[$Hex]
    if ($m) { return "$Hex $($m[0]) ($($m[1]))" }
    return $Hex
}

<# A failure that another attempt cannot fix. #>
function Test-WduPermanentHResult {
    param([string] $Hex)
    $m = $script:HResults[$Hex]
    return [bool] ($m -and $m[2])
}

<#
    Engine 2.0.0: one category for a failure.
      Step       'download', 'install' or 'search'
      Source     'engine' (an exception in this engine's call) or 'windowsUpdate' (WUA's own result)
      Exception  the recorded exception (hashtable from ConvertFrom-WduError), if any
#>
function Get-WduCategory {
    param([string] $Hex, [string] $Step = 'install', [string] $Source = 'windowsUpdate', $Exception = $null, [string] $Result = '')
    if ($Source -eq 'engine') {
        # A COMException carrying a WUA/Win32 code is the API's answer; any other .NET exception is ours.
        $isCom = $Exception -is [System.Collections.IDictionary] -and [string] $Exception['type'] -match 'COMException$'
        if (-not $isCom) { return 'EngineException' }
        $m = $script:HResults[$Hex]
        if ($m -and $m[3] -notin 'EngineException', 'InstallerFailure', 'NativeResultFailure') { return $m[3] }
        if ($Step -eq 'search') { return 'SearchFailure' }
        return 'ComApiException'
    }
    $m = $script:HResults[$Hex]
    if ($m) {
        # A .NET code in a per-update result comes from that update's own command-line installer.
        if ($m[3] -eq 'EngineException') { return 'InstallerFailure' }
        return $m[3]
    }
    if ($Step -eq 'search') { return 'SearchFailure' }
    if ($Step -eq 'download') { return 'DownloadFailure' }
    if ($Result -eq 'Aborted') { return 'TechnicianRequired' }
    return 'NativeResultFailure'
}

<#
    Engine 2.0.0: everything known about an exception, for the log and state.json: the operation
    that was running, exception type, HRESULT, message, inner exceptions, script line and stack.
#>
function ConvertFrom-WduError {
    param($ErrorRecord, [string] $Operation)
    $ex = $ErrorRecord
    $inv = $null
    $stack = ''
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $ex = $ErrorRecord.Exception
        $inv = $ErrorRecord.InvocationInfo
        $stack = [string] $ErrorRecord.ScriptStackTrace
    }
    # PowerShell wraps exceptions raised by a COM property setter or method call; report the real one.
    $root = $ex
    $wrappers = @('System.Management.Automation.MethodInvocationException', 'System.Management.Automation.SetValueInvocationException',
                  'System.Management.Automation.GetValueInvocationException', 'System.Reflection.TargetInvocationException', 'System.Management.Automation.RuntimeException')
    while ($root -and $root.InnerException -and ($wrappers -contains $root.GetType().FullName)) { $root = $root.InnerException }
    $chain = @()
    $e = $ex
    while ($e) { $chain += ('{0} ({1}): {2}' -f $e.GetType().FullName, (Format-WduHResult $e.HResult), $e.Message); $e = $e.InnerException }
    [ordered]@{
        operation  = $Operation
        type       = $(if ($root) { $root.GetType().FullName } else { '' })
        hresult    = $(if ($root) { Format-WduHResult $root.HResult } else { '' })
        message    = $(if ($root) { [string] $root.Message } else { '' })
        chain      = @($chain)
        line       = $(if ($inv) { [int] $inv.ScriptLineNumber } else { 0 })
        statement  = $(if ($inv -and $inv.Line) { ([string] $inv.Line).Trim() } else { '' })
        script     = $(if ($inv -and $inv.ScriptName) { Split-Path -Leaf $inv.ScriptName } else { '' })
        stack      = $stack
        engineVersion = $script:EngineVersion
        atUtc      = (Get-WduNow).ToString('o')
    }
}

<# Identity of an exception for "the same failure again": operation, type and line. #>
function Get-WduExceptionSignature {
    param($Info)
    if (-not $Info) { return '' }
    '{0}|{1}|{2}' -f $Info['operation'], $Info['type'], $Info['line']
}

function Format-WduException {
    param($Info)
    if (-not $Info) { return '' }
    $where = $(if ([int] $Info['line'] -gt 0) { " at $($Info['script']) line $($Info['line']): $($Info['statement'])" } else { '' })
    "$($Info['operation']) raised $($Info['type']) $($Info['hresult']): $($Info['message'])$where"
}

function ConvertTo-WduHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-WduHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-WduHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return , @($InputObject | ForEach-Object { ConvertTo-WduHashtable $_ })
    }
    return $InputObject
}

function Write-WduJson {
    param([string] $Path, $Value)
    $json = $Value | ConvertTo-Json -Depth 10
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Read-WduJson {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    ConvertTo-WduHashtable (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

# ------------------------------------------------------------------------------------------------
# Configuration, paths, logging, status
# ------------------------------------------------------------------------------------------------

# Every configuration value and its default (engine 2.0.0: also applied by Invoke-WduMain).
$script:ConfigDefaults = @{
    dataRoot             = 'C:\ProgramData\WindowsDeploymentBuilder'
    taskPath             = '\WindowsDeploymentBuilder\'
    taskName             = 'WindowsUpdate'
    mutexName            = 'Global\WindowsDeploymentBuilder-WindowsUpdate'
    drivers              = 'exclude'
    featureUpdates       = 'skip'
    optionalUpdates      = 'skip'
    # Engine 2.1.0: $null = follow optionalUpdates (a configuration written before schema 10).
    previewUpdates       = $null
    settingsRefresh      = $true
    settingsRefreshMinutes = 15
    microsoftUpdate      = $false
    maxReboots           = 10
    maxAttemptsPerUpdate = 3
    retryDelaySeconds    = 120
    maxRuntimeHours      = 6
    maxErrors            = 5
    networkWaitMinutes   = 15
    confirmationScans    = 1
    confirmationDelaySeconds = 60
    resetComponentsOnce  = $true
    rebootWarningSeconds = 60
    initialDelaySeconds  = 60
    lockWaitMinutes      = 60
    excludedKbs          = @()
    # Engine 2.0.0
    readinessSearchAttempts     = 4     # searches that may fail while the agent initialises
    readinessSearchDelaySeconds = 90    # between them (bounded; readiness = a search succeeding)
    readinessRestart            = $true # restart once before installing when a restart is already pending
    maxEngineExceptions         = 2     # the same engine exception this often stops the stage
    verifyDevices               = $true # pass D lists devices with problems
    # Retry Windows Update (Invoke-WindowsUpdateRetry.ps1) runs the same engine with its own folder,
    # marker and task, so the original deployment's records are never overwritten.
    workFolder                  = 'Updates'              # below dataRoot
    markerName                  = 'windows-update.done'  # in dataRoot\state
    selection                   = 'configured'           # configured | normal (no drivers/optional) | drivers
}

function Get-WduConfig {
    param([string] $Path)
    if (-not $Path) { $Path = Join-Path $PSScriptRoot 'config.json' }
    $raw = Read-WduJson $Path
    if (-not $raw) { throw "Configuration file not found: $Path" }
    $defaults = $script:ConfigDefaults
    foreach ($k in @($defaults.Keys)) { if (-not $raw.ContainsKey($k)) { $raw[$k] = $defaults[$k] } }
    $raw.excludedKbs = @($raw.excludedKbs | Where-Object { $_ } | ForEach-Object { ([string] $_).ToUpperInvariant() })
    return $raw
}

function Get-WduPaths {
    param([hashtable] $Config)
    $folder = $(if ($Config.ContainsKey('workFolder') -and $Config.workFolder) { [string] $Config.workFolder } else { 'Updates' })
    $marker = $(if ($Config.ContainsKey('markerName') -and $Config.markerName) { [string] $Config.markerName } else { 'windows-update.done' })
    $root = Join-Path $Config.dataRoot $folder
    @{
        Root     = $root
        Logs     = Join-Path $root 'logs'
        Log      = Join-Path (Join-Path $root 'logs') 'engine.log'
        State    = Join-Path $root 'state.json'
        Status   = Join-Path $root 'status.json'
        Result   = Join-Path $root 'result.json'
        MarkerDir = Join-Path $Config.dataRoot 'state'
        Marker   = Join-Path (Join-Path $Config.dataRoot 'state') $marker
    }
}

function Write-WduLog {
    param([string] $Message, [ValidateSet('INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO')
    $line = '{0}  {1,-5}  {2}' -f (Get-WduNow).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Verbose $line
    if (-not $script:LogFile) { return }
    for ($i = 0; $i -lt 3; $i++) {
        try { [System.IO.File]::AppendAllText($script:LogFile, $line + "`r`n"); return }
        catch { Start-Sleep -Milliseconds 200 }
    }
}

function Limit-WduLogSize {
    param([string] $Path, [int64] $MaxBytes = 5MB)
    if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -gt $MaxBytes) {
        Move-Item -LiteralPath $Path -Destination "$Path.1" -Force
    }
}

function Set-WduStatus {
    param([string] $Phase, [string] $Detail = '', [hashtable] $State)
    if (-not $script:StatusFile) { return }
    $o = [ordered]@{
        phase      = $Phase
        detail     = $Detail
        updatedUtc = (Get-WduNow).ToString('o')
        computer   = $env:COMPUTERNAME
        version    = $script:EngineVersion
    }
    if ($State) {
        $o.starts = $State.starts
        $o.reboots = $State.reboots
        $o.installed = @($State.installed).Count
        # Given up so far (permanent or out of attempts), and updates that need a person.
        $o.failed = @($State.attempts.Values | Where-Object { $_ -and $_['gaveUp'] }).Count
    }
    # Engine 1.2.0: what it is doing now. Download progress is never estimated (not exposed by the calls used).
    foreach ($k in 'current', 'attempt', 'maxAttempts', 'lastError', 'lastErrorUtc', 'queued') { if ($script:Activity.ContainsKey($k)) { $o[$k] = $script:Activity[$k] } }
    $o.progress = 'unavailable'
    try { Write-WduJson $script:StatusFile $o } catch { Write-WduLog "Could not write status: $($_.Exception.Message)" 'WARN' }
}

function Write-WduEvent {
    param([int] $EventId, [string] $Message, [ValidateSet('Information', 'Warning', 'Error')] [string] $EntryType = 'Information')
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($script:EventSource)) {
            New-EventLog -LogName Application -Source $script:EventSource
        }
        Write-EventLog -LogName Application -Source $script:EventSource -EventId $EventId -EntryType $EntryType -Message $Message
    } catch {
        Write-WduLog "Could not write event $EventId to the Application log: $($_.Exception.Message)" 'WARN'
    }
}

# ------------------------------------------------------------------------------------------------
# State
# ------------------------------------------------------------------------------------------------

function New-WduState {
    @{
        version         = 1
        firstStartUtc   = $null
        starts          = 0
        reboots         = 0
        errors          = 0
        offlineStarts   = 0
        everOnline      = $false
        componentReset  = $false
        attempts        = @{}
        installed       = @()
        final           = $null
        # Engine 2.0.0
        readiness       = $null   # first-start readiness checks (Get-WduReadiness)
        pass            = ''      # A, B, C or D: the pass the last installation belonged to
        passes          = @()     # history: { pass, startedUtc, updates }
        engineExceptions = @()    # every exception in the engine's own calls, with line and stack
        offered         = @{}     # every update ever offered: id -> { title, kbs, kind, pass, firstSeenUtc }
        restarts        = @()     # restart history: { atUtc, reason, pass }
        stopReason      = ''      # why processing stopped
        # Engine 2.1.0
        settingsRefresh = $null   # the last Update Orchestrator scan request (what Settings shows)
        settingsRefreshes = 0     # how many were made (at most 2 per run)
        installedAtRefresh = -1   # installed count when the last one was made
    }
}

function Read-WduState {
    param([hashtable] $Paths)
    $s = $null
    try { $s = Read-WduJson $Paths.State }
    catch {
        Write-WduLog "State file unreadable ($($_.Exception.Message)); keeping a copy and starting over." 'WARN'
        Copy-Item -LiteralPath $Paths.State -Destination "$($Paths.State).corrupt" -Force -ErrorAction SilentlyContinue
    }
    $fresh = New-WduState
    if (-not $s) { return $fresh }
    foreach ($k in @($fresh.Keys)) { if (-not $s.ContainsKey($k)) { $s[$k] = $fresh[$k] } }
    if ($null -eq $s.attempts) { $s.attempts = @{} }
    if ($null -eq $s.offered -or $s.offered -isnot [hashtable]) { $s.offered = @{} }
    $s.installed = @($s.installed | Where-Object { $_ })
    foreach ($k in 'passes', 'engineExceptions', 'restarts') { $s[$k] = @($s[$k] | Where-Object { $_ }) }
    return $s
}

function Save-WduState { param([hashtable] $State, [hashtable] $Paths) Write-WduJson $Paths.State $State }

# ------------------------------------------------------------------------------------------------
# Windows Update Agent adapter. Everything that touches the system lives here.
# Update objects returned to the engine are hashtables:
#   Id, Revision, Title, Kbs[], IsDriver, IsUpgrade, IsOptional, NeedsUserInput, IsDownloaded, Native
# ------------------------------------------------------------------------------------------------

function Get-WduSession {
    if (-not $script:Session) {
        $script:Session = New-Object -ComObject 'Microsoft.Update.Session'
        $script:Session.ClientApplicationID = 'Windows Deployment Builder'
    }
    $script:Session
}

function Get-WduAvailableUpdates {
    param([hashtable] $Config)
    $searcher = (Get-WduSession).CreateUpdateSearcher()
    if ($Config.microsoftUpdate) {
        $sm = New-Object -ComObject 'Microsoft.Update.ServiceManager'
        $sm.ClientApplicationID = 'Windows Deployment Builder'
        # 7 = asfAllowPendingRegistration + asfAllowOnlineRegistration + asfRegisterServiceWithAU
        [void] $sm.AddService2($script:MicrosoftUpdateServiceId, 7, '')
        $searcher.ServerSelection = 3   # ssOthers
        $searcher.ServiceID = $script:MicrosoftUpdateServiceId
    }
    $criteria = "IsInstalled=0 and IsHidden=0"
    if ($Config.drivers -ne 'include') { $criteria += " and Type='Software'" }
    $result = $searcher.Search($criteria)
    if ($result.ResultCode -notin 2, 3) { throw "Windows Update search returned result code $($result.ResultCode)." }
    $list = @()
    foreach ($u in $result.Updates) {
        $cats = @()
        foreach ($c in $u.Categories) { $cats += ([string] $c.CategoryID).ToLowerInvariant() }
        $kbs = @()
        foreach ($k in $u.KBArticleIDs) { $kbs += "KB$k" }
        $title = [string] $u.Title
        $isDriver = ([int] $u.Type -eq 2)
        # Engine 2.0.0: which device a driver update is for (IWindowsDriverUpdate), when Windows says.
        $driver = $null
        if ($isDriver) {
            $driver = [ordered]@{}
            foreach ($p in 'DriverHardwareID', 'DriverModel', 'DriverManufacturer', 'DriverClass', 'DriverProvider') {
                try { $v = $u.$p; if ($null -ne $v -and "$v") { $driver[$p.Substring(6, 1).ToLowerInvariant() + $p.Substring(7)] = [string] $v } } catch { }
            }
            try { if ($u.DriverVerDate) { $driver.verDate = ([DateTime] $u.DriverVerDate).ToString('yyyy-MM-dd') } } catch { }
        }
        $list += @{
            Id             = [string] $u.Identity.UpdateID
            Revision       = [int] $u.Identity.RevisionNumber
            Title          = $title
            Kbs            = $kbs
            IsDriver       = $isDriver
            Driver         = $driver
            Categories     = $cats
            # A feature update by category, or an enablement package that switches the Windows version.
            IsUpgrade      = ($cats -contains $script:UpgradeCategoryId) -or (Test-WduFeatureTitle $title)
            IsInsider      = ($title -match '(?i)\bInsider Preview\b')
            IsOptional     = [bool] $u.BrowseOnly
            AutoSelect     = $(try { [bool] $u.AutoSelectOnWebSites } catch { $false })
            NeedsUserInput = [bool] $u.InstallationBehavior.CanRequestUserInput
            IsDownloaded   = [bool] $u.IsDownloaded
            SizeBytes      = $(try { [int64] $u.MaxDownloadSize } catch { [int64] 0 })
            Native         = $u
        }
    }
    return , $list
}

<#
    Engine 2.1.0: what kind of update this is, for the policy and the report.
      servicingStack, defenderPlatform, defenderIntelligence, msrt, cumulative, security, dotnet,
      windowsPreview, dotnetPreview (optional non-security previews), driver, firmware, feature,
      insider, other
    Titles are Microsoft's own naming ("2026-11 Cumulative Update Preview for Windows 11 ...",
    "... Cumulative Update Preview for .NET Framework ...", "Security Intelligence Update for
    Microsoft Defender Antivirus ...", "Windows Malicious Software Removal Tool ..."); categories
    and the driver class are used where Windows gives them.
#>
function Get-WduUpdateClass {
    param([hashtable] $U)
    $t = [string] $U['Title']
    $cats = @($U['Categories'])
    if ($U['IsDriver']) {
        $dc = $(if ($U['Driver'] -is [System.Collections.IDictionary]) { [string] $U['Driver']['class'] } else { '' })
        if ($dc -match '(?i)firmware' -or $t -match '(?i)\bfirmware\b') { return 'firmware' }
        return 'driver'
    }
    if ($U['IsUpgrade']) { return 'feature' }
    if ($U['IsInsider']) { return 'insider' }
    if ($t -match '(?i)\bServicing Stack Update\b') { return 'servicingStack' }
    if ($t -match '(?i)antimalware platform' -or @($U['Kbs']) -contains 'KB4052623') { return 'defenderPlatform' }
    if ($t -match '(?i)Security Intelligence Update|Definition Update' -or $cats -contains 'e0789628-ce08-4437-be74-2495b842f43b') { return 'defenderIntelligence' }
    if ($t -match '(?i)Malicious Software Removal Tool') { return 'msrt' }
    if ($t -match '(?i)\bPreview\b') { return $(if ($t -match '(?i)\.NET') { 'dotnetPreview' } else { 'windowsPreview' }) }
    if ($t -match '(?i)\.NET') { return 'dotnet' }
    if ($t -match '(?i)\bCumulative Update\b') { return 'cumulative' }
    if ($t -match '(?i)\bSecurity Update\b' -or $cats -contains '0fa1201d-4330-4fa8-8ae9-b877473b6441') { return 'security' }
    return 'other'
}

<# Adds Class, IsPreview and IsFirmware to an update (also to simulated ones in the tests). #>
function Set-WduUpdateClass {
    param([hashtable] $U)
    $U.Class = Get-WduUpdateClass $U
    $U.IsPreview = $U.Class -in 'windowsPreview', 'dotnetPreview'
    $U.IsFirmware = $U.Class -eq 'firmware'
}

<# Titles of updates that move Windows to another version, whatever their category. #>
function Test-WduFeatureTitle {
    param([string] $Title)
    return ($Title -match '(?i)^\s*(Feature update to Windows|Upgrade to Windows)\b')
}

<#
    Engine 2.0.0: the pass an update belongs to.
      A  servicing prerequisites installed on their own first: servicing stack updates and the
         Microsoft Defender antimalware platform (KB4052623, needed before security intelligence)
      B  normal updates: cumulative, security, .NET, Defender intelligence, MSRT, other software
      C  optional updates (BrowseOnly: optional cumulative previews) and every driver
#>
function Get-WduPass {
    param([hashtable] $U)
    if ($U.IsDriver -or $U.IsOptional -or $U['IsPreview']) { return 'C' }
    $kbs = @($U.Kbs)
    if ($U.Title -match '(?i)\bServicing Stack Update\b' -or $U.Title -match '(?i)antimalware platform' -or $kbs -contains 'KB4052623') { return 'A' }
    return 'B'
}

function Get-WduPassName {
    param([string] $Pass)
    switch ($Pass) { 'A' { 'Pass A - servicing prerequisites' } 'B' { 'Pass B - normal updates' } 'C' { 'Pass C - optional updates and drivers' } 'D' { 'Pass D - final verification' } default { '' } }
}

<# Why an update is a prerequisite (pass A), for the readiness record. #>
function Get-WduPrerequisiteReason {
    param([hashtable] $U)
    if ($U.Title -match '(?i)\bServicing Stack Update\b') { return 'servicing stack update: installed before other updates' }
    return 'Microsoft Defender antimalware platform: installed before security intelligence updates'
}

<# Start type and status of the services Windows Update needs (read-only). #>
function Get-WduServiceStates {
    $out = [ordered]@{}
    foreach ($n in 'wuauserv', 'bits', 'cryptsvc', 'TrustedInstaller') {
        try {
            $s = Get-Service -Name $n -ErrorAction Stop
            $out[$n] = [ordered]@{ status = [string] $s.Status; startType = $(try { [string] $s.StartType } catch { 'Unknown' }) }
        } catch { $out[$n] = [ordered]@{ status = 'Missing'; startType = 'Missing' } }
    }
    $out
}

<# IAutomaticUpdates2.ServiceEnabled: whether the components Windows Update needs are available. #>
function Test-WduAgentEnabled {
    try { return [bool] (New-Object -ComObject 'Microsoft.Update.AutoUpdate').ServiceEnabled } catch { return $null }
}

<# Devices Device Manager reports a problem for (ConfigManagerErrorCode other than 0), read-only. #>
function Get-WduDeviceProblems {
    $list = @()
    try {
        foreach ($d in @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop)) {
            $code = 0
            try { $code = [int] $d.ConfigManagerErrorCode } catch { }
            if ($code -ne 0) { $list += [ordered]@{ name = [string] $d.Name; deviceId = [string] $d.DeviceID; problemCode = $code; hardwareIds = @($d.HardwareID | Where-Object { $_ }) } }
        }
    } catch { Write-WduLog "Device check failed: $($_.Exception.Message)" 'WARN' }
    return , $list
}

<#
    Engine 2.0.0: records one exception raised in the engine's own call. Returns $true when the
    same exception (operation, type, line) has now happened maxEngineExceptions times: it is
    deterministic and the stage stops instead of looping.
#>
function Register-WduEngineException {
    param([hashtable] $State, $Info, [object[]] $Updates, [hashtable] $Config)
    $sig = Get-WduExceptionSignature $Info
    $entry = [ordered]@{}
    foreach ($k in $Info.Keys) { $entry[$k] = $Info[$k] }
    $entry.signature = $sig
    $entry.category = 'EngineException'
    $entry.updates = @($Updates | ForEach-Object { Get-WduLabel $_ })
    $entry.pass = $State.pass
    $State.engineExceptions = @(@($State.engineExceptions) + @($entry) | Select-Object -Last 50)
    $same = @($State.engineExceptions | Where-Object { $_ -and [string] $_['signature'] -eq $sig }).Count
    $msg = "Engine exception ($same of at most $($Config.maxEngineExceptions)): $(Format-WduException $Info). This is an error in the update engine's own call, not an update installation failure; it is recorded once for $(@($Updates).Count) update(s)."
    $script:Activity.lastError = $msg
    $script:Activity.lastErrorUtc = (Get-WduNow).ToString('o')
    Write-WduLog "  $msg" 'ERROR'
    Add-WdbActivity $Config.dataRoot 'windowsUpdate' $msg 'error'
    return ($same -ge [int] $Config.maxEngineExceptions)
}

<#
    Engine 2.0.0: a reset of SoftwareDistribution and catroot2 is done only when the failures point
    at what it repairs: the download cache / update data store (WU_E_DM_*, WU_E_DS_*) or the
    signature catalog database. Never for engine exceptions, network, not-applicable or busy.
#>
function Test-WduResetWarranted {
    param([string[]] $HResults, [string[]] $Categories)
    foreach ($h in @($HResults)) {
        if (-not $h) { continue }
        foreach ($p in $script:ResetHResultPrefixes) { if ($h.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
        if ($h -eq '0x80092004') { return $true }
    }
    foreach ($c in @($Categories)) { if ($script:ResetCategories -contains $c) { return $true } }
    return $false
}

function ConvertTo-WduResultCode {
    param([int] $Code)
    switch ($Code) { 0 { 'NotStarted' } 1 { 'InProgress' } 2 { 'Succeeded' } 3 { 'SucceededWithErrors' } 4 { 'Failed' } 5 { 'Aborted' } default { "Unknown$Code" } }
}

<#
    Builds the Microsoft.Update.UpdateColl for a download or installation.

    Engine 2.0.0: the collection is returned with the unary comma. Without it PowerShell enumerates
    the COM collection on output and the caller receives the bare IUpdate (one update), Object[]
    (several) or $null (none); assigning that to IUpdateDownloader.Updates / IUpdateInstaller.Updates
    throws IndexOutOfRangeException 0x80131508 inside PowerShell's COM binder. That was the field
    failure of engines 1.0.0-1.3.0 (header). Do not remove the comma.
#>
function New-WduCollection {
    param([object[]] $Updates)
    $coll = New-Object -ComObject 'Microsoft.Update.UpdateColl'
    foreach ($u in @($Updates)) {
        if (-not $u.Native.EulaAccepted) { $u.Native.AcceptEula() }
        [void] $coll.Add($u.Native)
    }
    return , $coll
}

<#
    Engine 2.0.0: proves that $Collection is a real update collection holding $Expected updates
    before it is handed to WUA. Anything else is an engine defect and is reported as one, with the
    type that was received, instead of surfacing as an IndexOutOfRangeException from the setter.
#>
function Assert-WduCollection {
    param($Collection, [int] $Expected)
    if ($null -eq $Collection) { throw (New-Object System.InvalidOperationException("Engine defect: the update collection is null (expected $Expected update(s)).")) }
    if ($Collection -is [array]) { throw (New-Object System.InvalidOperationException("Engine defect: the update collection was unrolled into $($Collection.GetType().FullName) with $(@($Collection).Count) item(s).")) }
    $count = $null
    try { $count = [int] $Collection.Count } catch { }
    $isColl = $false
    try { $isColl = [bool] ($Collection.PSObject.Methods['Add'] -and $Collection.PSObject.Methods['Item'] -and $null -ne $count) } catch { }
    if (-not $isColl) { throw (New-Object System.InvalidOperationException("Engine defect: expected an update collection, received $($Collection.GetType().FullName).")) }
    if ($count -ne $Expected) { throw (New-Object System.InvalidOperationException("Engine defect: the update collection holds $count update(s), expected $Expected.")) }
}

<# Update identity of item $Index of a WUA update collection (results are mapped by identity, not position). #>
function Get-WduCollectionId {
    param($Collection, [int] $Index)
    [string] $Collection.Item($Index).Identity.UpdateID
}

<#
    Engine 2.0.0: runs one named WUA operation. An exception is recorded with everything known
    about it (ConvertFrom-WduError) and rethrown as the operation's failure; the session is renewed.
#>
function Invoke-WduOperation {
    param([string] $Operation, [scriptblock] $Action)
    try {
        $value = & $Action
        # The comma keeps a collection (or any enumerable COM object) intact through the return.
        return , $value
    } catch {
        $info = ConvertFrom-WduError $_ $Operation
        $script:LastWduException = $info
        Write-WduLog ("{0}`r`n    chain: {1}`r`n    stack: {2}" -f (Format-WduException $info), ($info.chain -join ' <- '), ($info.stack -replace "`r?`n", ' | ')) 'ERROR'
        $script:Session = $null
        throw
    }
}

<# Per-update results of a download or installation, keyed by update identity. #>
function Read-WduResults {
    param($Collection, $OperationResult, [object[]] $Updates)
    $map = @{}
    $n = [int] $Collection.Count
    for ($i = 0; $i -lt $n; $i++) {
        $ur = $OperationResult.GetUpdateResult($i)
        $id = Get-WduCollectionId $Collection $i
        $map[$id] = @{ Result = (ConvertTo-WduResultCode $ur.ResultCode); HResult = $ur.HResult }
    }
    foreach ($u in @($Updates)) {
        # Never invent a result: an update without one is reported as missing.
        if (-not $map.ContainsKey($u.Id)) { $map[$u.Id] = @{ Result = 'Missing'; HResult = $null; Source = 'engine'; Category = 'EngineException'; Exception = 'Windows Update returned no result for this update' } }
    }
    $map
}

function Invoke-WduDownload {
    param([object[]] $Updates)
    $out = @{}
    $pending = @($Updates | Where-Object { -not $_.IsDownloaded })
    foreach ($u in $Updates) { if ($u.IsDownloaded) { $out[$u.Id] = @{ Result = 'Succeeded'; HResult = 0 } } }
    if ($pending.Count -eq 0) { return $out }
    $script:LastWduException = $null
    try {
        $coll = Invoke-WduOperation 'download: build update collection' { New-WduCollection $pending }
        $null = Invoke-WduOperation 'download: verify update collection' { Assert-WduCollection $coll $pending.Count }
        $dl = Invoke-WduOperation 'download: create downloader' { (Get-WduSession).CreateUpdateDownloader() }
        $null = Invoke-WduOperation 'download: assign updates to downloader' { $dl.Updates = $coll }
        $r = Invoke-WduOperation 'download: IUpdateDownloader.Download' { $dl.Download() }
        $res = Invoke-WduOperation 'download: read per-update results' { Read-WduResults $coll $r $pending }
        foreach ($k in $res.Keys) { $out[$k] = $res[$k] }
    } catch {
        # The call itself failed (not a per-update result): one engine/API error for the operation.
        $info = $script:LastWduException
        if (-not $info) { $info = ConvertFrom-WduError $_ 'download' }
        foreach ($u in $pending) { $out[$u.Id] = @{ Result = 'Failed'; HResult = $_.Exception.HResult; Source = 'engine'; Exception = (Format-WduException $info); ExceptionInfo = $info } }
        $script:Session = $null
    }
    return $out
}

function Invoke-WduInstall {
    param([object[]] $Updates)
    $out = @{ RebootRequired = $false; Results = @{} }
    $script:LastWduException = $null
    try {
        $coll = Invoke-WduOperation 'install: build update collection' { New-WduCollection $Updates }
        $null = Invoke-WduOperation 'install: verify update collection' { Assert-WduCollection $coll @($Updates).Count }
        $inst = Invoke-WduOperation 'install: create installer' { (Get-WduSession).CreateUpdateInstaller() }
        try { $inst.ForceQuiet = $true } catch { }
        $null = Invoke-WduOperation 'install: assign updates to installer' { $inst.Updates = $coll }
        $r = Invoke-WduOperation 'install: IUpdateInstaller.Install' { $inst.Install() }
        $out.RebootRequired = [bool] $r.RebootRequired
        $out.Results = Invoke-WduOperation 'install: read per-update results' { Read-WduResults $coll $r $Updates }
    } catch {
        $info = $script:LastWduException
        if (-not $info) { $info = ConvertFrom-WduError $_ 'install' }
        foreach ($u in $Updates) { $out.Results[$u.Id] = @{ Result = 'Failed'; HResult = $_.Exception.HResult; Source = 'engine'; Exception = (Format-WduException $info); ExceptionInfo = $info } }
        $out.CallFailed = $true
        $script:Session = $null
    }
    return $out
}

function Test-WduRebootPending {
    try { if ((New-Object -ComObject 'Microsoft.Update.SystemInfo').RebootRequired) { return $true } } catch { }
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
                     'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        if (Test-Path -LiteralPath $key) { return $true }
    }
    return $false
}

function Test-WduInstallerBusy {
    try { return [bool] (New-Object -ComObject 'Microsoft.Update.Installer').IsBusy } catch { return $false }
}

function Test-WduNetwork {
    # Managed (WSUS) clients only need their update server; everyone else needs the Internet.
    $wsus = $null
    try {
        $au = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction Stop
        if ($au.UseWUServer -eq 1) {
            $wsus = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction Stop).WUServer
        }
    } catch { }
    if ($wsus) {
        $uri = [Uri] $wsus
        return (Test-WduTcp $uri.Host $uri.Port)
    }
    try {
        # Network Connectivity Status Indicator probe documented by Microsoft.
        $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 10
        if ($r.Content -eq 'Microsoft Connect Test') { return $true }
    } catch { }
    return (Test-WduTcp 'fe3.delivery.mp.microsoft.com' 443)
}

function Test-WduTcp {
    param([string] $HostName, [int] $Port)
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $tcp.BeginConnect($HostName, $Port, $null, $null)
        return ($iar.AsyncWaitHandle.WaitOne(5000) -and $tcp.Connected)
    } catch { return $false } finally { $tcp.Close() }
}

function Invoke-WduReboot {
    param([int] $WarningSeconds, [string] $Reason)
    # p:2:17 = planned, Operating System: Hot fix
    & "$env:SystemRoot\System32\shutdown.exe" /r /t $WarningSeconds /d p:2:17 /c "Windows Deployment Builder: $Reason. The computer restarts in $WarningSeconds seconds; updating resumes automatically."
    if ($LASTEXITCODE -ne 0) { throw "shutdown.exe failed with exit code $LASTEXITCODE" }
}

function Reset-WduComponents {
    # Microsoft's documented manual reset: stop the services, rename the data stores, restart.
    $services = 'wuauserv', 'bits', 'cryptsvc'
    foreach ($s in $services) { try { Stop-Service -Name $s -Force -ErrorAction Stop } catch { Write-WduLog "Could not stop ${s}: $($_.Exception.Message)" 'WARN' } }
    $stamp = (Get-WduNow).ToString('yyyyMMddHHmmss')
    foreach ($dir in "$env:SystemRoot\SoftwareDistribution", "$env:SystemRoot\System32\catroot2") {
        if (Test-Path -LiteralPath $dir) {
            try { Rename-Item -LiteralPath $dir -NewName ("{0}.{1}.old" -f (Split-Path $dir -Leaf), $stamp) -ErrorAction Stop; Write-WduLog "Renamed $dir." }
            catch { Write-WduLog "Could not rename ${dir}: $($_.Exception.Message)" 'WARN' }
        }
    }
    foreach ($s in $services) { try { Start-Service -Name $s -ErrorAction Stop } catch { Write-WduLog "Could not start ${s}: $($_.Exception.Message)" 'WARN' } }
    $script:Session = $null
}

function Unregister-WduTask {
    param([hashtable] $Config)
    try {
        $t = Get-ScheduledTask -TaskName $Config.taskName -TaskPath $Config.taskPath -ErrorAction Stop
        $t | Unregister-ScheduledTask -Confirm:$false
        Write-WduLog "Removed scheduled task $($Config.taskPath)$($Config.taskName)."
    } catch {
        Write-WduLog "Scheduled task $($Config.taskPath)$($Config.taskName) not removed: $($_.Exception.Message)" 'WARN'
    }
}

# ------------------------------------------------------------------------------------------------
# Coordination with the application engine
# ------------------------------------------------------------------------------------------------

# region WDB coordination
# Shared by WindowsUpdateEngine.ps1 and ApplicationEngine.ps1; both copies must stay identical
# (tests/unit/applications-engine.test.ts checks this).
#
# install.lock         Machine-wide installation lock: a file opened exclusively. Windows releases
#                      it when the owning process ends, so a crash can never leave a stale lock.
#                      Whoever installs something or restarts the computer holds it.
# restart-pending.json Written just before an engine schedules a restart. Valid only in the boot
#                      it was written in (and for 30 minutes), so it disappears with the restart.

function Get-WdbBootTime {
    try { return (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    catch { return 'unknown' }
}

function Wait-WdbLockPoll { Start-Sleep -Seconds 5 }

function Get-WdbCoordinationPaths {
    param([string] $DataRoot)
    $dir = Join-Path $DataRoot 'state'
    @{ Dir = $dir; Lock = (Join-Path $dir 'install.lock'); Restart = (Join-Path $dir 'restart-pending.json') }
}

function Enter-WdbInstallLock {
    param([string] $DataRoot, [string] $Owner, [int] $TimeoutSeconds = 0)
    $p = Get-WdbCoordinationPaths $DataRoot
    if (-not (Test-Path -LiteralPath $p.Dir)) { New-Item -ItemType Directory -Path $p.Dir -Force | Out-Null }
    $polls = [int] [Math]::Ceiling([Math]::Max(0, $TimeoutSeconds) / 5)
    for ($i = 0; ; $i++) {
        try {
            $fs = [System.IO.File]::Open($p.Lock, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes(('{{"owner":"{0}","pid":{1},"sinceUtc":"{2}"}}' -f $Owner, $PID, [DateTime]::UtcNow.ToString('o')))
            $fs.SetLength(0)
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush()
            return $fs
        } catch [System.IO.IOException] {
            if ($i -ge $polls) { return $null }
            Wait-WdbLockPoll
        }
    }
}

function Exit-WdbInstallLock {
    param($Lock)
    if ($Lock) { try { $Lock.Dispose() } catch { } }
}

function Get-WdbInstallLockOwner {
    param([string] $DataRoot)
    $p = Get-WdbCoordinationPaths $DataRoot
    try {
        $fs = [System.IO.File]::Open($p.Lock, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try { return (New-Object System.IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { return '' }
}

function Set-WdbRestartPending {
    param([string] $DataRoot, [string] $Owner, [string] $Reason)
    $p = Get-WdbCoordinationPaths $DataRoot
    if (-not (Test-Path -LiteralPath $p.Dir)) { New-Item -ItemType Directory -Path $p.Dir -Force | Out-Null }
    $o = [ordered]@{ owner = $Owner; reason = $Reason; requestedUtc = [DateTime]::UtcNow.ToString('o'); bootTimeUtc = (Get-WdbBootTime) }
    [System.IO.File]::WriteAllText($p.Restart, ($o | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}

function Test-WdbRestartPending {
    param([string] $DataRoot)
    $p = Get-WdbCoordinationPaths $DataRoot
    if (-not (Test-Path -LiteralPath $p.Restart)) { return $false }
    $m = $null
    try { $m = Get-Content -LiteralPath $p.Restart -Raw | ConvertFrom-Json } catch { }
    if ($m -and ([string] $m.bootTimeUtc) -eq (Get-WdbBootTime)) {
        $age = [DateTime]::UtcNow - [DateTime]::Parse([string] $m.requestedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        if ($age.TotalMinutes -lt 30) { return $true }
    }
    # Written before the last restart, unreadable or abandoned: the restart is no longer pending.
    Remove-Item -LiteralPath $p.Restart -Force -ErrorAction SilentlyContinue
    return $false
}

<#
    Appends one event to the deployment's activity feed <dataRoot>\Deployment\activity.jsonl
    (retries, failures and restarts, for the progress window and the LAN monitor). Best effort:
    the feed is information, never a reason for an installation to fail.
#>
function Add-WdbActivity {
    param([string] $DataRoot, [string] $Source, [string] $Message, [string] $Level = 'info')
    try {
        $dir = Join-Path $DataRoot 'Deployment'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $line = ([ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); level = $Level; source = $Source; message = $Message } | ConvertTo-Json -Compress)
        [System.IO.File]::AppendAllText((Join-Path $dir 'activity.jsonl'), $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# endregion WDB coordination

# ------------------------------------------------------------------------------------------------
# Single instance
# ------------------------------------------------------------------------------------------------

function Enter-WduMutex {
    param([string] $Name)
    $m = New-Object System.Threading.Mutex($false, $Name)
    try {
        if ($m.WaitOne([TimeSpan]::FromSeconds(10))) { return $m }
    } catch [System.Threading.AbandonedMutexException] {
        return $m   # previous owner died; we own it now
    }
    $m.Dispose()
    return $null
}

function Exit-WduMutex {
    param($Mutex)
    if ($Mutex) { try { $Mutex.ReleaseMutex() } catch { }; $Mutex.Dispose() }
}

# ------------------------------------------------------------------------------------------------
# Planning
# ------------------------------------------------------------------------------------------------

<#
    Why an offered update is not installed now, or $null. "Can request user input" is deliberately
    not a reason: such an update is tried quietly on its own, and only Windows' own answer
    (WU_E_NO_INTERACTIVE_USER, Aborted) marks it as needing a person.
#>
function Get-WduSkipReason {
    param([hashtable] $Update, [hashtable] $Config, [hashtable] $State)
    if ($Update.ContainsKey('IsInsider') -and $Update.IsInsider) { return 'Insider Preview build (never installed)' }
    if ($Update.IsUpgrade -and $Config.featureUpdates -ne 'install') { return 'feature update (policy: skip)' }
    # Engine 2.1.0: firmware is never installed automatically, whatever the driver policy.
    if ($Update['IsFirmware']) { return 'firmware (never installed automatically)' }
    if ($Update.IsDriver -and $Config.drivers -ne 'include') { return 'driver (policy: exclude)' }
    # Engine 2.1.0: Windows and .NET Framework previews follow "Install preview updates" only.
    if ($Update['IsPreview']) {
        if (-not $Config['previewUpdates']) { return 'preview update (policy: preview updates excluded)' }
    } elseif ($Update.IsOptional -and $Config.optionalUpdates -ne 'install') { return 'optional update (policy: skip)' }
    # Retry Windows Update: only the chosen kind is retried; the rest stays for another run.
    $sel = $(if ($Config.ContainsKey('selection')) { [string] $Config.selection } else { 'configured' })
    if ($sel -eq 'normal' -and $Update.IsDriver) { return 'not selected for this retry (Windows updates only, no drivers)' }
    if ($sel -eq 'drivers' -and -not $Update.IsDriver) { return 'not selected for this retry (drivers only)' }
    foreach ($kb in $Update.Kbs) { if ($Config.excludedKbs -contains $kb.ToUpperInvariant()) { return "excluded by configuration ($kb)" } }
    $a = $State.attempts[$Update.Id]
    if ($a -and $a['interaction']) { return 'gave up: Windows reported that it needs a signed-in person to install it' }
    if ($a -and $a['permanent']) { return "gave up: $(Get-WduHResultText ([string] $a.lastHResult)) (not retried)" }
    if ($a -and [int] $a.count -ge [int] $Config.maxAttemptsPerUpdate) { return "gave up after $($a.count) attempt(s)" }
    return $null
}

<# "Driver", "Optional driver", "Optional", "Feature update" or "Update": how the report groups an update. #>
function Get-WduKind {
    param([hashtable] $U)
    $optional = [bool] $U.IsOptional
    if ($U.IsDriver) { return $(if ($optional) { 'Optional driver' } else { 'Driver' }) }
    if ($U.IsUpgrade) { return 'Feature update' }
    if ($optional) { return 'Optional' }
    return 'Update'
}

function Get-WduPlan {
    param([object[]] $Updates, [hashtable] $Config, [hashtable] $State)
    # Deferred: a failed download or installation waiting for its retry delay (not given up).
    # AfterRestart (engine 1.3.0): failed while a restart was pending; retried once in the next boot.
    $plan = @{ Install = @(); Skipped = @(); GaveUp = @(); Interaction = @(); Deferred = @(); AfterRestart = @() }
    foreach ($u in $Updates) {
        $a = $State.attempts[$u.Id]
        if ($a -and $a['restartChance'] -eq 'waiting') {
            if ([string] $a['restartChanceBoot'] -eq (Get-WdbBootTime)) {
                $plan.AfterRestart += @{ id = $u.Id; title = $u.Title; kbs = @($u.Kbs); kind = (Get-WduKind $u); attempts = $a.count; lastResult = $a.lastResult; lastHResult = $a.lastHResult; error = (Get-WduHResultText ([string] $a.lastHResult)); reason = 'failed while a restart was pending; retried after the restart' }
                continue
            }
            # A new boot: the one extra attempt.
            $a.restartChance = 'used'; $a.count = [int] $Config.maxAttemptsPerUpdate - 1; $a.nextAttemptUtc = $null
        }
        $reason = Get-WduSkipReason $u $Config $State
        if (-not $reason) {
            $a = $State.attempts[$u.Id]
            $due = $(if ($a -and $a['nextAttemptUtc']) { ConvertTo-WduDate $a['nextAttemptUtc'] } else { $null })
            if ($due -and $due -gt (Get-WduNow)) { $plan.Deferred += @{ Update = $u; Due = $due }; continue }
            $plan.Install += $u
            continue
        }
        $entry = @{ id = $u.Id; title = $u.Title; kbs = @($u.Kbs); reason = $reason; kind = (Get-WduKind $u); pass = (Get-WduPass $u); class = [string] $u['Class'] }
        if ($u.ContainsKey('Driver') -and $u.Driver) { $entry.device = $u.Driver }
        if ($reason -like 'gave up*') {
            $a = $State.attempts[$u.Id]
            $entry.attempts = $a.count; $entry.lastResult = $a.lastResult; $entry.lastHResult = $a.lastHResult
            $entry.error = Get-WduHResultText ([string] $a.lastHResult)
            # Engine 1.3.0: an exception in the engine's own call, or Windows Update's result for this update.
            $entry.errorSource = $(if ($a['lastErrorSource']) { [string] $a['lastErrorSource'] } else { 'windowsUpdate' })
            if ($a['lastException']) { $entry.exception = [string] $a['lastException'] }
            if ($a['restartChance'] -eq 'used') { $entry.retriedAfterRestart = $true }
            $entry.category = $(if ($a['lastCategory']) { [string] $a['lastCategory'] } else { Get-WduCategory ([string] $a.lastHResult) 'install' $entry.errorSource })
            if ($a['interaction']) { $plan.Interaction += $entry } else { $plan.GaveUp += $entry }
        } else {
            $plan.Skipped += $entry
        }
    }
    # Engine 2.0.0: install one pass at a time, in order (A prerequisites, B normal, C optional and
    # drivers). The others wait for the next scan, which follows any restart the pass needs.
    $plan.Pass = ''
    $plan.Later = @()
    if (@($plan.Install).Count) {
        $plan.Pass = @($plan.Install | ForEach-Object { Get-WduPass $_ } | Sort-Object)[0]
        $plan.Later = @($plan.Install | Where-Object { (Get-WduPass $_) -ne $plan.Pass })
        $plan.Install = @($plan.Install | Where-Object { (Get-WduPass $_) -eq $plan.Pass })
    }
    $plan
}

function Get-WduLabel { param([hashtable] $U) $kb = if (@($U.Kbs).Count) { ($U.Kbs -join ',') + ' ' } else { '' }; "$kb$($U.Title)" }

<#
    Records a failed download or installation of one update and decides what happens next:
      permanent HRESULT or Windows needs a person -> given up now, not retried
      attempts used up                             -> given up (one more chance after a component reset)
      otherwise                                    -> retried after retryDelaySeconds x attempt
    The other updates and the application stage carry on either way.
#>
function Register-WduFailure {
    param([hashtable] $U, [hashtable] $A, [hashtable] $Config, [string] $Step, [string] $Result, $HResult, $Raw = $null)
    $hex = Format-WduHResult $HResult
    $A.lastResult = $Result
    $A.lastHResult = $hex
    $A.lastErrorUtc = (Get-WduNow).ToString('o')
    # Engine 1.3.0: who reported the error: Windows Update for this update, or an exception in the call.
    $A.lastErrorSource = $(if ($Raw -is [hashtable] -and $Raw['Source'] -eq 'engine') { 'engine' } else { 'windowsUpdate' })
    $A.lastException = $(if ($Raw -is [hashtable] -and $Raw['Exception']) { [string] $Raw['Exception'] } else { '' })
    # Engine 2.0.0: one category per failure (Get-WduCategory).
    $A.lastCategory = Get-WduCategory $hex $Step $A.lastErrorSource $(if ($Raw -is [hashtable]) { $Raw['ExceptionInfo'] } else { $null }) $Result
    if ($A.lastCategory -eq 'TechnicianRequired' -and -not $A['interaction'] -and $hex -eq '0x80240020') { $A.interaction = $true }
    $max = [int] $Config.maxAttemptsPerUpdate
    $what = $(if ($Step -eq 'download') { 'download' } else { 'install' })
    $why = $(if ($hex) { Get-WduHResultText $hex } else { $Result })
    if ($A.lastErrorSource -eq 'engine') { $why = "the Windows Update call failed ($($A.lastCategory): $why; $($A.lastException))" } else { $why = "$why [$($A.lastCategory)]" }
    $label = Get-WduLabel $U
    # Engine 1.3.0: an update failing while Windows waits for a restart often installs after it.
    # Its last attempt is not used up now: it is retried once after the restart.
    $pendingRestart = $false
    if (-not $A['interaction'] -and -not (Test-WduPermanentHResult $hex) -and [int] $A.count -ge $max -and -not $A['restartChance']) { $pendingRestart = [bool] (Test-WduRebootPending) }
    if ($pendingRestart) {
        $A.restartChance = 'waiting'; $A.restartChanceBoot = Get-WdbBootTime; $A.nextAttemptUtc = $null
        $msg = "Unable to $what ${label}: $why. Attempt $($A.count) of $max while Windows has a restart pending; retried once more after the restart. Other operations continue."
    } elseif ($A['interaction']) {
        $A.gaveUp = $true
        $msg = "$label needs a person to install it ($why). Recorded for follow-up; the other updates continue."
    } elseif (Test-WduPermanentHResult $hex) {
        $A.permanent = $true; $A.gaveUp = $true
        $msg = "Unable to $what ${label}: $why. Not retried; the other updates continue."
    } elseif ([int] $A.count -ge $max) {
        $A.gaveUp = $true
        $msg = "Unable to $what ${label}: $why. Attempt $($A.count) of $max; given up. Other operations continue."
    } else {
        $delay = [int] $Config.retryDelaySeconds * [int] $A.count
        $A.nextAttemptUtc = (Get-WduNow).AddSeconds($delay).ToString('o')
        $msg = "Unable to $what ${label}: $why. Attempt $($A.count) of $max; retrying in $delay s. Other operations will continue where possible."
    }
    $script:Activity.lastError = $msg
    $script:Activity.lastErrorUtc = $A.lastErrorUtc
    Write-WduLog "  $msg" 'WARN'
    Add-WdbActivity $Config.dataRoot 'windowsUpdate' $msg 'warning'
}

# ------------------------------------------------------------------------------------------------
# Outcomes
# ------------------------------------------------------------------------------------------------

function Complete-Wdu {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State, [string] $Status, [string] $Reason, $Plan = $null)
    # Engine 2.0.0: a plan built for one purpose (readiness, engine stop) may lack the lists.
    if ($Plan -is [hashtable]) { foreach ($k in 'GaveUp', 'Skipped', 'Interaction', 'AfterRestart') { if (-not $Plan.ContainsKey($k) -or $null -eq $Plan[$k]) { $Plan[$k] = @() } } }
    $now = (Get-WduNow).ToString('o')
    $result = [ordered]@{
        status        = $Status
        reason        = $Reason
        engineVersion = $script:EngineVersion
        computer      = $env:COMPUTERNAME
        startedUtc    = $State.firstStartUtc
        finishedUtc   = $now
        starts        = $State.starts
        reboots       = $State.reboots
        installed     = @($State.installed)
        failed        = @(if ($Plan) { @($Plan.GaveUp) + @(if ($Plan.ContainsKey('AfterRestart')) { $Plan.AfterRestart }) })
        skipped       = @(if ($Plan) { $Plan.Skipped })
        # Engine 1.2.0: updates Windows said need a person, and the counts by kind.
        requiresInteraction = @(if ($Plan -and $Plan.ContainsKey('Interaction')) { $Plan.Interaction })
        counts        = [ordered]@{
            installed         = @($State.installed).Count
            installedOptional = @($State.installed | Where-Object { $_ -is [hashtable] -and $_['optional'] }).Count
            installedDrivers  = @($State.installed | Where-Object { $_ -is [hashtable] -and $_['driver'] }).Count
            failed            = @(if ($Plan) { @($Plan.GaveUp) + @(if ($Plan.ContainsKey('AfterRestart')) { $Plan.AfterRestart }) }).Count
            requiresInteraction = @(if ($Plan -and $Plan.ContainsKey('Interaction')) { $Plan.Interaction }).Count
            skipped           = @(if ($Plan) { $Plan.Skipped }).Count
        }
        policy        = [ordered]@{ optionalUpdates = $Config.optionalUpdates; previewUpdates = [bool] $Config['previewUpdates']; drivers = $Config.drivers; featureUpdates = $Config.featureUpdates; maxAttemptsPerUpdate = $Config.maxAttemptsPerUpdate }
    }
    # Engine 2.0.0: why processing stopped, readiness, passes, restarts, engine exceptions, verification.
    $State.stopReason = $Reason
    $result.stopReason = $Reason
    $result.readiness = $State.readiness
    $result.passes = @($State.passes)
    $result.restarts = @($State.restarts)
    $result.engineExceptions = @($State.engineExceptions | ForEach-Object { $e = [ordered]@{}; foreach ($k in $_.Keys) { if ($k -ne 'stack') { $e[$k] = $_[$k] } }; $e })
    $result.counts.engineExceptions = @($State.engineExceptions).Count
    $byCategory = [ordered]@{}
    foreach ($f in $result.failed) { $c = $(if ($f -is [System.Collections.IDictionary] -and $f['category']) { [string] $f['category'] } else { 'NativeResultFailure' }); $byCategory[$c] = 1 + [int] $byCategory[$c] }
    $result.failedByCategory = $byCategory
    $result.drivers = @($State.installed | Where-Object { $_ -is [hashtable] -and $_['driver'] } | ForEach-Object { [ordered]@{ title = $_.title; device = $_['device']; result = $_.result } })
    if ($Plan -and $Plan.ContainsKey('NotAttempted')) { $result.notAttempted = @($Plan.NotAttempted) }
    if ($Plan -and $Plan.ContainsKey('Verification')) { $result.verification = $Plan.Verification }
    if ($Plan -and $Plan.ContainsKey('Category')) { $result.category = $Plan.Category }
    if ($Plan -and $Plan.ContainsKey('TechnicianAction')) { $result.technicianAction = $Plan.TechnicianAction }
    # Engine 2.1.0: the final Settings refresh and the truthful update state with its counts.
    $result.settingsRefresh = $State['settingsRefresh']
    $us = Get-WduUpdateState $Status $result
    $result.updateState = $us.state
    $result.updateStateText = $us.text
    $result.summary = $us.summary
    Write-WduJson $Paths.Result $result
    $State.final = $Status
    Save-WduState $State $Paths
    if ($Status -in 'Succeeded', 'CompletedWithFollowUp', 'CompletedWithFailures') {
        if (-not (Test-Path -LiteralPath $Paths.MarkerDir)) { New-Item -ItemType Directory -Path $Paths.MarkerDir -Force | Out-Null }
        Write-WduJson $Paths.Marker ([ordered]@{ status = $Status; finishedUtc = $now; result = $Paths.Result })
    }
    $level = switch ($Status) { 'Succeeded' { 'INFO' } 'CompletedWithFailures' { 'WARN' } 'CompletedWithFollowUp' { 'WARN' } default { 'ERROR' } }
    Write-WduLog ("UPDATE STATE: {0}. {1}" -f $result.updateState, $result.updateStateText)
    Write-WduLog ("FINISHED: {0}. {1} Installed {2} (optional {3}, drivers {4}), failed {5}, need a person {6}, skipped {7}, reboots {8}." -f $Status, $Reason, @($result.installed).Count, $result.counts.installedOptional, $result.counts.installedDrivers, @($result.failed).Count, @($result.requiresInteraction).Count, @($result.skipped).Count, $State.reboots) $level
    foreach ($f in $result.failed) { Write-WduLog ("  FAILED   {0} {1} ({2} attempts, last {3} {4}) [{5}]" -f ($f.kbs -join ','), $f.title, $f.attempts, $f.lastResult, (Get-WduHResultText ([string] $f.lastHResult)), $f['category']) 'WARN' }
    foreach ($x in @($State.engineExceptions)) { Write-WduLog ("  ENGINE   {0}" -f (Format-WduException $x)) 'WARN' }
    foreach ($f in $result.requiresInteraction) { Write-WduLog ("  PERSON   {0} {1}: {2}" -f ($f.kbs -join ','), $f.title, $f.reason) 'WARN' }
    foreach ($s in $result.skipped) { Write-WduLog ("  SKIPPED  {0} {1}: {2}" -f ($s.kbs -join ','), $s.title, $s.reason) }
    $eventId = switch ($Status) { 'Succeeded' { 1100 } 'CompletedWithFailures' { 1101 } 'CompletedWithFollowUp' { 1104 } 'Failed' { 1102 } default { 1103 } }
    $entryType = switch ($Status) { 'Succeeded' { 'Information' } 'CompletedWithFailures' { 'Warning' } 'CompletedWithFollowUp' { 'Warning' } default { 'Error' } }
    Write-WduEvent $eventId "Windows Update automation finished: $Status. $Reason See $($Paths.Result)." $entryType
    Add-WdbActivity $Config.dataRoot 'windowsUpdate' ("Windows Update finished: {0}. {1} Installed {2} update(s) ({3} optional, {4} drivers)." -f $Status, $Reason, @($result.installed).Count, $result.counts.installedOptional, $result.counts.installedDrivers) $(if ($Status -eq 'Succeeded') { 'info' } elseif ($Status -in 'CompletedWithFollowUp', 'CompletedWithFailures') { 'warning' } else { 'error' })
    Set-WduStatus $Status $Reason $State
    Unregister-WduTask $Config
    return "Finished:$Status"
}

function Request-WduReboot {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State, [string] $Reason, $Plan = $null)
    if ([int] $State.reboots -ge [int] $Config.maxReboots) {
        return Complete-Wdu $Config $Paths $State 'Failed' "Reboot limit ($($Config.maxReboots)) reached while a restart is still required ($Reason)." $Plan
    }
    # Never restart while an application is being installed.
    $lock = Enter-WdbInstallLock $Config.dataRoot 'WindowsUpdate' ([int] $Config.lockWaitMinutes * 60)
    if (-not $lock) {
        Write-WduLog "Restart deferred ($Reason): another installation holds the install lock. Trying again at the next start." 'WARN'
        Set-WduStatus 'RebootDeferred' $Reason $State
        return 'RebootDeferred'
    }
    try {
        $State.reboots = [int] $State.reboots + 1
        $State.restarts = @(@($State.restarts) + @([ordered]@{ atUtc = (Get-WduNow).ToString('o'); reason = $Reason; pass = $State.pass; number = $State.reboots }))
        Save-WduState $State $Paths
        Write-WduLog "Restart $($State.reboots)/$($Config.maxReboots): $Reason. Resuming after boot."
        Set-WduStatus 'Rebooting' $Reason $State
        Write-WduEvent 1001 "Restarting to continue Windows Update ($Reason)."
        Add-WdbActivity $Config.dataRoot 'windowsUpdate' "Windows Update restarts the computer ($Reason); updating continues after the restart (restart $($State.reboots) of at most $($Config.maxReboots))." 'info'
        Set-WdbRestartPending $Config.dataRoot 'WindowsUpdate' $Reason
        Invoke-WduReboot -WarningSeconds ([int] $Config.rebootWarningSeconds) -Reason $Reason
        # Hold the lock through the warning period so nothing starts installing before the restart.
        Wait-Wdu ([int] $Config.rebootWarningSeconds + 120)
    } finally {
        Exit-WdbInstallLock $lock
    }
    return 'Rebooting'
}

function Test-WduDeadline {
    param([hashtable] $Config, [hashtable] $State)
    ((Get-WduNow) - (ConvertTo-WduDate $State.firstStartUtc)).TotalHours -ge [double] $Config.maxRuntimeHours
}

# ------------------------------------------------------------------------------------------------
# Main loop
# ------------------------------------------------------------------------------------------------

<#
    Engine 2.0.0: first-start readiness. Checks what can be checked without waiting (services,
    agent, pending restart); the proof that Windows Update is ready is the first successful search
    in the main loop (bounded by readinessSearchAttempts), never an arbitrary wait. Returns 'Ready'
    or the outcome that ends this start (a readiness restart, or a final state).
#>
function Invoke-WduReadiness {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State)
    if (-not $State.readiness) {
        $State.readiness = [ordered]@{ startedUtc = (Get-WduNow).ToString('o'); status = 'Checking'; services = $null; agentEnabled = $null
            rebootPendingAtStart = $null; restartDone = $false; installerBusySeconds = 0; searchSucceeded = $false; searchAttempts = 0
            lastSearchError = ''; prerequisites = @(); bootstrapNeeded = $null; readyUtc = $null }
    }
    $r = $State.readiness
    if ($r['status'] -eq 'Ready') { return 'Ready' }
    Set-WduStatus 'CheckingReadiness' 'Checking that Windows Update is ready (services, pending restart, first search).' $State
    $r.services = Get-WduServiceStates
    $r.agentEnabled = Test-WduAgentEnabled
    foreach ($n in 'wuauserv', 'bits') {
        $svc = $r.services[$n]
        if ($svc -and ($svc['startType'] -eq 'Disabled' -or $svc['status'] -eq 'Missing')) {
            $r.status = 'NotReady'
            Save-WduState $State $Paths
            $plan = @{ Category = 'NotReady'; TechnicianAction = "The $n service is $($svc['startType']). Set it back to Manual (the Windows default) or remove the policy or tool that disabled it, then run Retry Windows Update." }
            return Complete-Wdu $Config $Paths $State 'Failed' "Windows Update cannot run: the $n service is $($svc['startType'])." $plan
        }
    }
    $pending = [bool] (Test-WduRebootPending)
    if ($null -eq $r['rebootPendingAtStart']) { $r.rebootPendingAtStart = $pending }
    if ($pending -and $Config.readinessRestart -and -not $r['restartDone'] -and @($State.installed).Count -eq 0) {
        $r.restartDone = $true
        Save-WduState $State $Paths
        Write-WduLog 'Readiness: Windows already has a restart pending; restarting once before installing anything.'
        return Request-WduReboot $Config $Paths $State 'a restart was already pending before updating (readiness check)'
    }
    $r.status = 'WaitingForSearch'
    Save-WduState $State $Paths
    return 'Ready'
}

<#
    Engine 2.0.0, pass D: what the final search shows. Installed updates must no longer be offered;
    updates offered earlier that are neither offered nor installed by this engine are reported as no
    longer offered (WUA does not say whether they were superseded, became inapplicable, or were
    installed by Windows' own automatic updates); devices with problems are listed.
#>
function Get-WduVerification {
    param([hashtable] $State, [object[]] $Updates, [hashtable] $Config)
    $now = @{}
    foreach ($u in @($Updates)) { $now[$u.Id] = $u }
    $installedIds = @($State.installed | Where-Object { $_ -is [hashtable] } | ForEach-Object { [string] $_['id'] })
    $still = @($State.installed | Where-Object { $_ -is [hashtable] -and $now.ContainsKey([string] $_['id']) } | ForEach-Object { [ordered]@{ title = $_['title']; kbs = @($_['kbs']) } })
    $gone = @()
    foreach ($id in @($State.offered.Keys)) {
        if ($now.ContainsKey($id) -or $installedIds -contains $id) { continue }
        $o = $State.offered[$id]
        $a = $State.attempts[$id]
        $gone += [ordered]@{ title = $o['title']; kbs = @($o['kbs']); kind = $o['kind']; category = 'Superseded'; attempted = [bool] $a
            reason = 'offered earlier, no longer offered and not installed by this engine (superseded, no longer applicable, or installed by Windows itself)' }
    }
    $devices = @()
    if ($Config.verifyDevices) { $devices = @(Get-WduDeviceProblems) }
    [ordered]@{
        atUtc = (Get-WduNow).ToString('o')
        remainingOffered = @($Updates).Count
        installedStillOffered = @($still)
        noLongerOffered = @($gone)
        rebootPending = [bool] (Test-WduRebootPending)
        devicesWithProblems = @($devices)
    }
}

# ------------------------------------------------------------------------------------------------
# Engine 2.1.0: final check through the Update Orchestrator (Settings > Windows Update)
# ------------------------------------------------------------------------------------------------
<#
    A search through the Windows Update Agent (Microsoft.Update.Session) does not change what
    Settings > Windows Update shows ("Last checked", the list of updates). The documented WinRT API
    Windows.Management.Update.WindowsUpdateManager (Windows 11 24H2 and later) asks the Update
    Orchestrator, which Settings uses, to scan, and reports its last successful scan time. The engine
    records the request, whether that time advanced (the scan completed), and never claims that the
    Settings page itself was seen to refresh. No registry value or timestamp is ever written.
    Replaceable boundary (the tests simulate it): Get-WduOrchestrator, Get-WduOrchestratorScanTime,
    Start-WduOrchestratorScan, Test-WduOrchestratorScanning.
#>
function Get-WduOrchestrator {
    $script:WduOrchestratorError = ''
    try { $null = [Windows.Management.Update.WindowsUpdateManager, Windows.Management.Update, ContentType = WindowsRuntime] }
    catch { $script:WduOrchestratorError = 'missing'; return $null }
    try { return (New-Object Windows.Management.Update.WindowsUpdateManager 'WindowsDeploymentBuilder') }
    catch { $script:WduOrchestratorError = "$($_.Exception.GetType().Name): $($_.Exception.Message)"; return $null }
}

function Get-WduOrchestratorScanTime {
    param($Manager)
    try { $t = $Manager.LastSuccessfulScanTimestamp; if ($null -ne $t) { return ([DateTimeOffset] $t).UtcDateTime } } catch { }
    return $null
}

function Start-WduOrchestratorScan { param($Manager) $Manager.StartScan($false) }

function Test-WduOrchestratorScanning { param($Manager) try { return [bool] $Manager.IsScanning } catch { return $false } }

function Test-WduSettingsRefreshDue {
    param([hashtable] $Config, [hashtable] $State)
    if (-not $Config['settingsRefresh']) { return $false }
    $n = [int] $State['settingsRefreshes']
    if ($n -eq 0) { return $true }
    # A second one only when the first made more updates applicable and they were installed.
    return ($n -lt 2 -and @($State.installed).Count -gt [int] $State['installedAtRefresh'])
}

function Invoke-WduSettingsRefresh {
    param([hashtable] $Config, [hashtable] $State)
    $State.settingsRefreshes = 1 + [int] $State['settingsRefreshes']
    $State.installedAtRefresh = @($State.installed).Count
    $rec = [ordered]@{
        api = 'Windows.Management.Update.WindowsUpdateManager (Update Orchestrator)'; available = $false; requested = $false; completed = $false
        requestedUtc = $null; completedUtc = $null; lastSuccessfulScanBefore = $null; lastSuccessfulScanAfter = $null
        settingsDisplayVerified = $false; attempt = [int] $State.settingsRefreshes; message = ''
    }
    Set-WduStatus 'RefreshingSettings' 'Asking Windows Update (Settings) to check for updates.' $State
    # Saved before the wait: a restart or a stop during it never repeats the request (bounded at two).
    if ($script:WduStatePaths) { Save-WduState $State $script:WduStatePaths }
    $m = Get-WduOrchestrator
    if (-not $m) {
        $why = $(if ($script:WduOrchestratorError -and $script:WduOrchestratorError -ne 'missing') { "Windows Update's orchestrator API could not be used ($($script:WduOrchestratorError))." } else { 'Not available on this Windows version (Windows.Management.Update needs Windows 11 24H2 or later).' })
        $rec.message = "$why The engine's own final search is the verification; Settings may show an older ""Last checked"" time until Windows checks by itself."
    } else {
        $rec.available = $true
        $before = Get-WduOrchestratorScanTime $m
        if ($before) { $rec.lastSuccessfulScanBefore = $before.ToString('o') }
        try {
            Start-WduOrchestratorScan $m
            $rec.requested = $true
            $rec.requestedUtc = (Get-WduNow).ToString('o')
        } catch { $rec.message = "Windows refused the scan request: $($_.Exception.Message)" }
        if ($rec.requested) {
            $polls = [Math]::Max(1, [int] $Config.settingsRefreshMinutes * 6)
            for ($i = 0; $i -lt $polls; $i++) {
                Wait-Wdu 10
                $after = Get-WduOrchestratorScanTime $m
                if ($after -and (-not $before -or $after -gt $before) -and -not (Test-WduOrchestratorScanning $m)) {
                    $rec.completed = $true
                    $rec.completedUtc = (Get-WduNow).ToString('o')
                    $rec.lastSuccessfulScanAfter = $after.ToString('o')
                    break
                }
            }
            $rec.message = $(if ($rec.completed) { 'Windows Update (the Update Orchestrator that Settings uses) completed a check for updates; its last successful check time advanced. Whether the Settings page shows it is not observed by the engine.' }
                             else { "Requested, but Windows did not report a completed check within $($Config.settingsRefreshMinutes) minutes. The engine's own final search is the verification." })
        }
    }
    if ($rec.requested) {
        $busyPolls = 0
        while ((Test-WduInstallerBusy) -and $busyPolls -lt 120) { $busyPolls++; Set-WduStatus 'WaitingForInstaller' 'Windows Update is installing on its own after the check; waiting before searching again.' $State; Wait-Wdu 30 }
        if ($busyPolls) { $rec.waitedForWindowsInstallerSeconds = $busyPolls * 30 }
    }
    $State.settingsRefresh = $rec
    Write-WduLog ("Settings refresh {0}: available {1}, requested {2}, completed {3}. {4}" -f $rec.attempt, $rec.available, $rec.requested, $rec.completed, $rec.message) $(if ($rec.completed -or -not $rec.available) { 'INFO' } else { 'WARN' })
    Add-WdbActivity $Config.dataRoot 'windowsUpdate' $(if ($rec.completed) { 'Windows Update check for Settings completed; searching once more.' } elseif ($rec.available) { 'Windows Update check for Settings requested; searching once more.' } else { 'Settings refresh not available on this Windows version; final search follows.' }) 'info'
}

<#
    Engine 2.1.0: the truthful final state of the computer's updates (never "up to date" just because
    an installation command finished), and the counts behind it.
#>
function Get-WduUpdateState {
    param([string] $Status, [System.Collections.IDictionary] $Result)
    $v = $(if ($Result.Contains('verification')) { $Result['verification'] } else { $null })
    $failed = @(@($Result['failed']) | Where-Object { $_ -is [System.Collections.IDictionary] })
    $skipped = @(@($Result['skipped']) | Where-Object { $_ -is [System.Collections.IDictionary] })
    $person = @(@($Result['requiresInteraction']) | Where-Object { $_ })
    $cat = { param($f) [string] $f['category'] }
    $previews = @($skipped | Where-Object { [string] $_['reason'] -like 'preview update (policy*' }).Count
    $notSelected = @($skipped | Where-Object { [string] $_['reason'] -like 'not selected for this retry*' }).Count
    $summary = [ordered]@{
        installed        = @($Result['installed'] | Where-Object { $_ }).Count
        superseded       = $(if ($v) { @(@($v['noLongerOffered']) | Where-Object { $_ }).Count } else { 0 })
        notApplicable    = @($failed | Where-Object { (& $cat $_) -eq 'NotApplicable' }).Count
        excluded         = $skipped.Count - $notSelected
        previewsExcluded = $previews
        notSelected      = $notSelected
        downloadFailed   = @($failed | Where-Object { (& $cat $_) -in 'DownloadFailure', 'TransientNetwork' }).Count
        installFailed    = @($failed | Where-Object { (& $cat $_) -notin 'NotApplicable', 'DownloadFailure', 'TransientNetwork' }).Count
        awaitingRestart  = $(if ($v) { [bool] $v['rebootPending'] } else { $false })
        remaining        = $failed.Count + $person.Count
        notAttempted     = @($Result['notAttempted'] | Where-Object { $_ }).Count
    }
    $state = $(
        if ($Status -in 'Failed', 'Offline' -or $summary.notAttempted) { 'InstallationIncomplete' }
        elseif (-not $v) { 'VerificationUnavailable' }
        elseif ($summary.awaitingRestart) { 'RestartRequired' }
        elseif ($failed.Count) { 'CompletedWithFailures' }
        elseif ($person.Count -or $notSelected) { 'UpdatesRemaining' }
        elseif ($previews) { 'PreviewUpdatesExcluded' }
        elseif ($skipped.Count - $notSelected) { 'UpToDateUnderPolicy' }
        else { 'UpToDate' })
    $text = switch ($state) {
        'UpToDate' { 'Up to date: the final search found nothing applicable left.' }
        'UpToDateUnderPolicy' { "Up to date under the selected policy: $($skipped.Count) offered update(s) are excluded by policy (see skipped)." }
        'PreviewUpdatesExcluded' { "Up to date; $previews preview update(s) are offered but intentionally excluded (Install preview updates is off)." }
        'RestartRequired' { 'A restart is still required to finish installing updates.' }
        'UpdatesRemaining' { $(if ($person.Count) { "$($person.Count) selected update(s) remain: Windows reported that they need a signed-in person." } else { "$notSelected update(s) of another kind remain offered: this retry did not select them (run the other retry mode or RetryAll)." }) }
        'CompletedWithFailures' { "$($failed.Count) selected update(s) could not be installed." }
        'InstallationIncomplete' { 'Installation did not finish (stopped by a limit, an engine error or no network); updates may remain.' }
        default { 'The final verification search did not run, so the update state is not verified.' }
    }
    [ordered]@{ state = $state; text = $text; summary = $summary }
}

<# Ends the stage after a deterministic engine exception (never loops, never resets components). #>
function Stop-WduForEngineException {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State, [hashtable] $Plan)
    $last = @($State.engineExceptions)[-1]
    $n = @($State.engineExceptions | Where-Object { $_ -and [string] $_['signature'] -eq [string] $last['signature'] }).Count
    $installedIds = @($State.installed | Where-Object { $_ -is [hashtable] } | ForEach-Object { [string] $_['id'] })
    $Plan.NotAttempted = @(@($Plan.Install) + @($Plan.Later) | Where-Object { $_ -and $installedIds -notcontains $_.Id } | ForEach-Object { Get-WduLabel $_ })
    $Plan.Category = 'EngineException'
    $Plan.TechnicianAction = "The update engine stopped because the same exception happened $n times ($(Format-WduException $last)). It is an error in the engine's own call, so the updates were not reported as failed installations and Windows Update components were not reset. Install the remaining updates from Settings > Windows Update, or run Retry Windows Update with a corrected engine; send $($Paths.Result) and $($Paths.Log) with the report."
    return Complete-Wdu $Config $Paths $State 'Failed' "Stopped after the same engine exception $n times: $(Format-WduException $last). $(@($Plan.NotAttempted).Count) update(s) not attempted." $Plan
}

function Invoke-WduRun {
    param([hashtable] $Config, [hashtable] $Paths)
    $State = Read-WduState $Paths
    if ($State.final) {
        Write-WduLog "Already finished with status $($State.final); nothing to do."
        Unregister-WduTask $Config
        return 'AlreadyFinished'
    }
    $first = -not $State.firstStartUtc
    if ($first) { $State.firstStartUtc = (Get-WduNow).ToString('o') }
    $State.starts = [int] $State.starts + 1
    Save-WduState $State $Paths
    Write-WduLog "==== Engine $($script:EngineVersion) start $($State.starts) (reboots so far: $($State.reboots)) ===="
    Set-WduStatus 'Starting' "Start $($State.starts)" $State
    if ($first) {
        Write-WduEvent 1000 'Windows Update automation started.'
        Write-WduLog ("Policy: drivers={0}, feature updates={1}, optional={2}, Microsoft Update={3}; limits: {4} reboots, {5} attempts/update, {6} h." -f $Config.drivers, $Config.featureUpdates, $Config.optionalUpdates, $Config.microsoftUpdate, $Config.maxReboots, $Config.maxAttemptsPerUpdate, $Config.maxRuntimeHours)
        # Lets the first sign-in settle. Not readiness: readiness is checked below.
        Wait-Wdu ([int] $Config.initialDelaySeconds)
    }

    if (Test-WduDeadline $Config $State) {
        if ($State.everOnline) { return Complete-Wdu $Config $Paths $State 'Failed' "Runtime limit ($($Config.maxRuntimeHours) h) reached." }
        return Complete-Wdu $Config $Paths $State 'Offline' "No network connection before the runtime limit ($($Config.maxRuntimeHours) h)."
    }

    # Network
    Set-WduStatus 'WaitingForNetwork' '' $State
    $deadline = (Get-WduNow).AddMinutes([double] $Config.networkWaitMinutes)
    $online = $false
    while ($true) {
        if (Test-WduNetwork) { $online = $true; break }
        if ((Get-WduNow) -ge $deadline) { break }
        Wait-Wdu 15
    }
    if (-not $online) {
        $State.offlineStarts = [int] $State.offlineStarts + 1
        Save-WduState $State $Paths
        Write-WduLog "No network after $($Config.networkWaitMinutes) min. The task retries at the next start or within the hour." 'WARN'
        Set-WduStatus 'WaitingForNetwork' 'No network; will retry' $State
        if (Test-WduDeadline $Config $State) {
            if ($State.everOnline) { return Complete-Wdu $Config $Paths $State 'Failed' "Runtime limit ($($Config.maxRuntimeHours) h) reached while offline." }
            return Complete-Wdu $Config $Paths $State 'Offline' "No network connection before the runtime limit ($($Config.maxRuntimeHours) h)."
        }
        return 'WaitingForNetwork'
    }
    if (-not $State.everOnline) { $State.everOnline = $true; Save-WduState $State $Paths }
    Write-WduLog 'Network available.'

    # Engine 2.0.0: readiness (services, pending restart); the first successful search completes it.
    $ready = Invoke-WduReadiness $Config $Paths $State
    if ($ready -ne 'Ready') { return $ready }

    # Another update operation (for example Windows' own automatic updates) may be installing.
    for ($i = 0; $i -lt 60 -and (Test-WduInstallerBusy); $i++) {
        if ($i -eq 0) { Write-WduLog 'Windows Update installer is busy; waiting (max 30 min).' }
        Set-WduStatus 'WaitingForInstaller' 'Windows is already installing updates (for example its own automatic updates); waiting for it to finish.' $State
        Wait-Wdu 30
        if ($State.readiness) { $State.readiness.installerBusySeconds = [int] $State.readiness['installerBusySeconds'] + 30 }
    }

    $emptyScans = 0
    $scanFailures = 0
    for ($pass = 1; $pass -le 50; $pass++) {
        if (Test-WduDeadline $Config $State) { return Complete-Wdu $Config $Paths $State 'Failed' "Runtime limit ($($Config.maxRuntimeHours) h) reached." }

        $initialising = [bool] ($State.readiness -and -not $State.readiness['searchSucceeded'])
        Set-WduStatus 'Scanning' $(if ($initialising) { "Readiness: first search for updates (attempt $([int] $State.readiness['searchAttempts'] + 1))" } else { "Search $pass" }) $State
        Write-WduLog "Scan pass $pass."
        $script:LastWduException = $null
        if ($initialising) { $State.readiness.searchAttempts = [int] $State.readiness['searchAttempts'] + 1 }
        try {
            $updates = Invoke-WduOperation 'search: IUpdateSearcher.Search' { Get-WduAvailableUpdates $Config }
            foreach ($x in @($updates)) { if ($x -is [hashtable] -and -not $x.ContainsKey('Class')) { Set-WduUpdateClass $x } }
            $scanFailures = 0
        } catch {
            $info = $script:LastWduException
            if (-not $info) { $info = ConvertFrom-WduError $_ 'search' }
            $cat = Get-WduCategory ([string] $info['hresult']) 'search' 'engine' $info
            $scanFailures++
            $limit = $(if ($initialising) { [int] $Config.readinessSearchAttempts } else { 3 })
            $delay = $(if ($initialising) { [int] $Config.readinessSearchDelaySeconds } else { 60 })
            Write-WduLog "Scan failed ($scanFailures/$limit) [$cat]: $(Format-WduException $info)" 'ERROR'
            if ($initialising) { $State.readiness.lastSearchError = "[$cat] $(Format-WduException $info)" }
            if ($cat -eq 'EngineException') {
                $stop = Register-WduEngineException $State $info @() $Config
                Save-WduState $State $Paths
                if ($stop) { return Stop-WduForEngineException $Config $Paths $State @{ Install = @(); Later = @() } }
            }
            Save-WduState $State $Paths
            if ($scanFailures -lt $limit) { Wait-Wdu $delay; continue }
            if ($cat -ne 'EngineException' -and $Config.resetComponentsOnce -and -not $State.componentReset -and (Test-WduResetWarranted @([string] $info['hresult']) @($cat))) {
                Write-WduLog "Resetting Windows Update components once: repeated search failures point at the update data store ($($info['hresult']))." 'WARN'
                Set-WduStatus 'ResettingComponents' 'Search failures (update data store)' $State
                Reset-WduComponents
                $State.componentReset = $true
                Save-WduState $State $Paths
                $scanFailures = 0
                continue
            }
            $reason = $(if ($initialising) { "Windows Update did not become ready: $limit searches failed [$cat]: $(Format-WduException $info)" } else { "Windows Update search keeps failing [$cat]: $(Format-WduException $info)" })
            return Complete-Wdu $Config $Paths $State 'Failed' $reason @{ Category = $(if ($initialising -and $cat -ne 'EngineException') { 'NotReady' } else { $cat }); TechnicianAction = 'Check the network, the date and time and the Windows Update services, then run Retry Windows Update (-Mode Status first).' }
        }

        # Every update ever offered (pass D reports those that disappear).
        foreach ($u in @($updates)) {
            if (-not $State.offered.ContainsKey($u.Id)) {
                $State.offered[$u.Id] = [ordered]@{ title = $u.Title; kbs = @($u.Kbs); kind = (Get-WduKind $u); pass = (Get-WduPass $u); firstSeenUtc = (Get-WduNow).ToString('o') }
            }
        }
        if ($initialising) {
            $r = $State.readiness
            $r.searchSucceeded = $true; $r.status = 'Ready'; $r.readyUtc = (Get-WduNow).ToString('o')
            $pre = @($updates | Where-Object { (Get-WduPass $_) -eq 'A' -and -not (Get-WduSkipReason $_ $Config $State) })
            $r.prerequisites = @($pre | ForEach-Object { [ordered]@{ title = $_.Title; kbs = @($_.Kbs); reason = (Get-WduPrerequisiteReason $_) } })
            $r.bootstrapNeeded = [bool] $pre.Count
            Write-WduLog ("Readiness: Windows Update answered after {0} search(es); {1} prerequisite update(s) to install first." -f $r.searchAttempts, $pre.Count)
            Add-WdbActivity $Config.dataRoot 'windowsUpdate' ("Windows Update is ready ({0} update(s) offered; {1} servicing prerequisite(s) installed first)." -f @($updates).Count, $pre.Count) 'info'
        }
        Save-WduState $State $Paths

        $plan = Get-WduPlan $updates $Config $State
        Write-WduLog ("Found {0} update(s): {1} to install now ({2}), {3} in later passes, {4} skipped by policy, {5} given up, {6} need a person, {7} waiting to retry." -f @($updates).Count, @($plan.Install).Count, $(if ($plan.Pass) { Get-WduPassName $plan.Pass } else { 'none' }), @($plan.Later).Count, @($plan.Skipped).Count, @($plan.GaveUp).Count, @($plan.Interaction).Count, @($plan.Deferred).Count)

        if (@($plan.Install).Count -eq 0) {
            if (@($plan.Deferred).Count -gt 0) {
                # A failed download or installation is retried after its delay; nothing else is waiting.
                $next = @($plan.Deferred | Sort-Object { $_.Due })[0]
                $wait = [int] [Math]::Max(1, [Math]::Ceiling(($next.Due - (Get-WduNow)).TotalSeconds))
                Set-WduStatus 'WaitingForRetry' "Retrying $(Get-WduLabel $next.Update) in $wait s." $State
                Write-WduLog "Waiting $wait s before retrying $(Get-WduLabel $next.Update)."
                Wait-Wdu $wait
                $emptyScans = 0
                continue
            }
            if (@($plan.AfterRestart).Count -gt 0) { return Request-WduReboot $Config $Paths $State "$(@($plan.AfterRestart).Count) update(s) failed while a restart was pending and are retried after it" $plan }
            if (Test-WduRebootPending) { return Request-WduReboot $Config $Paths $State 'a restart is pending to finish installed updates' $plan }
            $emptyScans++
            if ($emptyScans -le [int] $Config.confirmationScans) {
                Write-WduLog "Nothing to install; confirmation scan $emptyScans/$($Config.confirmationScans) after $($Config.confirmationDelaySeconds) s."
                Set-WduStatus 'Confirming' "$(Get-WduPassName 'D'): confirmation search $emptyScans" $State
                Wait-Wdu ([int] $Config.confirmationDelaySeconds)
                continue
            }
            # Engine 2.1.0: once nothing selected remains, ask the Update Orchestrator (what Settings >
            # Windows Update shows) to check for updates, then search again: whatever that check makes
            # applicable is installed before the final verification. At most twice per run.
            if (Test-WduSettingsRefreshDue $Config $State) {
                $script:WduStatePaths = $Paths
                Invoke-WduSettingsRefresh $Config $State
                Save-WduState $State $Paths
                $emptyScans = 0
                continue
            }
            # Pass D: final verification.
            Set-WduStatus 'Verifying' "$(Get-WduPassName 'D'): checking installed updates and devices." $State
            $State.pass = 'D'
            $plan.Verification = Get-WduVerification $State $updates $Config
            $State.passes = @(@($State.passes) + @([ordered]@{ pass = 'D'; name = (Get-WduPassName 'D'); startedUtc = (Get-WduNow).ToString('o'); updates = @() }))
            $v = $plan.Verification
            Write-WduLog ("Verification: {0} still offered, {1} installed update(s) offered again, {2} no longer offered, {3} device(s) with problems, restart pending: {4}." -f $v.remainingOffered, @($v.installedStillOffered).Count, @($v.noLongerOffered).Count, @($v.devicesWithProblems).Count, $v.rebootPending)
            if (@($plan.GaveUp).Count -gt 0) {
                return Complete-Wdu $Config $Paths $State 'CompletedWithFailures' "$(@($plan.GaveUp).Count) update(s) could not be installed and were given up.$(if (@($plan.Interaction).Count) { " $(@($plan.Interaction).Count) update(s) need a person to install them." })" $plan
            }
            if (@($plan.Interaction).Count -gt 0) {
                return Complete-Wdu $Config $Paths $State 'CompletedWithFollowUp' "$(@($plan.Interaction).Count) update(s) need a person to install them (Windows reported that they need a signed-in user); everything else is installed." $plan
            }
            return Complete-Wdu $Config $Paths $State 'Succeeded' 'No applicable updates remain.' $plan
        }
        $emptyScans = 0

        if ($State.pass -ne $plan.Pass) {
            $State.pass = $plan.Pass
            $State.passes = @(@($State.passes) + @([ordered]@{ pass = $plan.Pass; name = (Get-WduPassName $plan.Pass); startedUtc = (Get-WduNow).ToString('o'); updates = @($plan.Install | ForEach-Object { Get-WduLabel $_ }) }))
            Write-WduLog "Starting $(Get-WduPassName $plan.Pass) with $(@($plan.Install).Count) update(s)."
            Add-WdbActivity $Config.dataRoot 'windowsUpdate' "$(Get-WduPassName $plan.Pass): $(@($plan.Install).Count) update(s)." 'info'
        }
        $script:Activity.pass = Get-WduPassName $plan.Pass

        # Coordination: no update installation while an application is being installed.
        $lock = Enter-WdbInstallLock $Config.dataRoot 'WindowsUpdate' ([int] $Config.lockWaitMinutes * 60)
        if (-not $lock) {
            Write-WduLog 'Another installation holds the install lock; trying again at the next start.' 'WARN'
            Set-WduStatus 'WaitingForLock' 'Waiting for an application installation to finish before installing updates.' $State
            return 'WaitingForLock'
        }
        $rebootRequired = $false
        $stopForEngine = $false
        try {
            $max = [int] $Config.maxAttemptsPerUpdate
            $ready = @()
            $i = 0
            foreach ($u in $plan.Install) {
                $i++
                # Count the attempt before acting, so a crash or hang mid-download or mid-install still counts.
                $a = $State.attempts[$u.Id]
                if (-not $a) { $a = @{ count = 0; title = $u.Title; kbs = @($u.Kbs); kind = (Get-WduKind $u); lastResult = ''; lastHResult = '' }; $State.attempts[$u.Id] = $a }
                $a.count = [int] $a.count + 1
                $a.nextAttemptUtc = $null
                $a.pass = $plan.Pass
                $label = Get-WduLabel $u
                Write-WduLog ("  queued   {0} [{1}, pass {2}] (attempt {3}/{4})" -f $label, (Get-WduKind $u), $plan.Pass, $a.count, $max)
                Save-WduState $State $Paths
                $script:Activity.current = $label; $script:Activity.attempt = [int] $a.count; $script:Activity.maxAttempts = $max; $script:Activity.queued = @($plan.Install).Count
                $size = $(if ($u.ContainsKey('SizeBytes') -and [int64] $u.SizeBytes -gt 0) { " ($([Math]::Round([double] $u.SizeBytes / 1MB, 1)) MB)" } else { '' })
                Set-WduStatus 'Downloading' "$(Get-WduPassName $plan.Pass): downloading $label$size, update $i of $(@($plan.Install).Count), attempt $($a.count) of $max. Progress unavailable." $State
                # One update per call: a failed download never holds back the others.
                $r = (Invoke-WduDownload @($u))[$u.Id]
                if ($r -and $r.Result -in 'Succeeded', 'SucceededWithErrors') { $ready += $u; continue }
                if ($r -and $r['Source'] -eq 'engine' -and (Get-WduCategory (Format-WduHResult $r.HResult) 'download' 'engine' $r['ExceptionInfo']) -eq 'EngineException') {
                    # An exception in the engine's own call: not this update's failure; its attempt is not used up.
                    $a.count = [Math]::Max(0, [int] $a.count - 1)
                    $a.lastErrorSource = 'engine'; $a.lastCategory = 'EngineException'; $a.lastException = [string] $r['Exception']
                    $a.nextAttemptUtc = (Get-WduNow).AddSeconds([int] $Config.retryDelaySeconds).ToString('o')
                    if (Register-WduEngineException $State $r['ExceptionInfo'] @($u) $Config) { $stopForEngine = $true; break }
                    continue
                }
                Register-WduFailure $u $a $Config 'download' $(if ($r) { "Download$($r.Result)" } else { 'DownloadMissing' }) $(if ($r) { $r.HResult } else { $null }) $r
            }
            Save-WduState $State $Paths

            # Ordinary updates are installed together; one that can ask for input, and (pass C) every
            # driver, is installed on its own so its result belongs to one update and one device.
            $queue = New-Object System.Collections.ArrayList
            if (-not $stopForEngine) {
                $normal = @($ready | Where-Object { -not $_.NeedsUserInput -and -not $_.IsDriver })
                if ($normal.Count) { [void] $queue.Add(@($normal)) }
                foreach ($u in @($ready | Where-Object { $_.NeedsUserInput -or $_.IsDriver })) { [void] $queue.Add(@($u)) }
            }
            $isolated = $false
            $recount = @{}   # isolated updates whose attempt is counted again only when actually tried
            for ($q = 0; $q -lt $queue.Count -and -not $stopForEngine; $q++) {
                $batch = @($queue[$q])
                foreach ($u in $batch) {
                    if ($recount.ContainsKey($u.Id)) { $recount.Remove($u.Id); $State.attempts[$u.Id].count = [int] $State.attempts[$u.Id].count + 1; $State.attempts[$u.Id].nextAttemptUtc = $null }
                }
                $labels = @($batch | ForEach-Object { Get-WduLabel $_ })
                $script:Activity.current = ($labels -join '; ')
                Set-WduStatus 'Installing' "$(Get-WduPassName $plan.Pass): installing $(@($batch).Count) update(s): $($labels -join '; ')" $State
                $in = Invoke-WduInstall $batch
                if ($in.RebootRequired) { $rebootRequired = $true }
                if ($in.ContainsKey('CallFailed') -and $in.CallFailed) {
                    $first0 = $in.Results[$batch[0].Id]
                    $info = $first0['ExceptionInfo']
                    $cat = Get-WduCategory (Format-WduHResult $first0.HResult) 'install' 'engine' $info
                    if ($cat -eq 'EngineException') {
                        foreach ($u in $batch) {
                            $a = $State.attempts[$u.Id]
                            $a.count = [Math]::Max(0, [int] $a.count - 1)
                            $a.lastErrorSource = 'engine'; $a.lastCategory = 'EngineException'; $a.lastException = [string] $first0['Exception']
                            $a.nextAttemptUtc = (Get-WduNow).AddSeconds([int] $Config.retryDelaySeconds).ToString('o')
                        }
                        if (Register-WduEngineException $State $info $batch $Config) { $stopForEngine = $true; break }
                    }
                    if ($batch.Count -gt 1 -and -not $isolated) {
                        # The call failed for the whole batch: isolate it, one update at a time, once.
                        $isolated = $true
                        Write-WduLog "  The installation call failed for $($batch.Count) update(s) together [$cat]; installing them one at a time to isolate the failure." 'WARN'
                        if ($cat -eq 'EngineException') { foreach ($u in $batch) { $recount[$u.Id] = $true } }
                        foreach ($u in $batch) { [void] $queue.Add(@($u)) }
                        Save-WduState $State $Paths
                        continue
                    }
                    if ($cat -eq 'EngineException') { Save-WduState $State $Paths; continue }
                }
                foreach ($u in $batch) {
                    $r = $in.Results[$u.Id]
                    $a = $State.attempts[$u.Id]
                    if ($r -and $r.Result -in 'Succeeded', 'SucceededWithErrors') {
                        $a.lastResult = $r.Result; $a.lastHResult = Format-WduHResult $r.HResult; $a.lastCategory = ''
                        $rec = @{ id = $u.Id; title = $u.Title; kbs = @($u.Kbs); kind = (Get-WduKind $u); optional = [bool] $u.IsOptional; driver = [bool] $u.IsDriver; result = $r.Result; atUtc = (Get-WduNow).ToString('o'); pass = $plan.Pass; class = [string] $u['Class']; preview = [bool] $u['IsPreview'] }
                        if ($u.ContainsKey('Driver') -and $u.Driver) { $rec.device = $u.Driver }
                        $State.installed += $rec
                        Write-WduLog ("  installed {0} ({1})" -f (Get-WduLabel $u), $r.Result)
                        continue
                    }
                    $hex = $(if ($r) { Format-WduHResult $r.HResult } else { '' })
                    # Windows' own answer that a person is needed (never the CanRequestUserInput flag alone).
                    if ($u.NeedsUserInput -and $r -and ($hex -eq '0x80240020' -or $r.Result -eq 'Aborted')) { $a.interaction = $true }
                    Register-WduFailure $u $a $Config 'install' $(if ($r) { $r.Result } else { 'Missing' }) $(if ($r) { $r.HResult } else { $null }) $r
                }
                Save-WduState $State $Paths
            }
            $script:Activity.current = ''
        } finally {
            Exit-WdbInstallLock $lock
        }
        Save-WduState $State $Paths
        if ($stopForEngine) { return Stop-WduForEngineException $Config $Paths $State $plan }

        # An update about to be given up gets one more chance after a component reset, but only when
        # its failures point at what a reset repairs (Test-WduResetWarranted).
        $exhausted = @($plan.Install | Where-Object {
            $a = $State.attempts[$_.Id]
            $a['gaveUp'] -and -not $a['permanent'] -and -not $a['interaction'] -and $a.lastResult -notin 'Succeeded', 'SucceededWithErrors'
        })
        $warranted = $exhausted.Count -gt 0 -and (Test-WduResetWarranted @($exhausted | ForEach-Object { [string] $State.attempts[$_.Id].lastHResult }) @($exhausted | ForEach-Object { [string] $State.attempts[$_.Id]['lastCategory'] }))
        if ($exhausted.Count -gt 0 -and -not $warranted -and -not $State.componentReset) {
            Write-WduLog "$($exhausted.Count) update(s) given up; their failures do not point at the update data store, so Windows Update components are not reset." 'WARN'
        }
        if ($warranted -and $Config.resetComponentsOnce -and -not $State.componentReset) {
            Write-WduLog "$($exhausted.Count) update(s) keep failing with download/data-store errors; resetting Windows Update components once." 'WARN'
            Set-WduStatus 'ResettingComponents' 'Repeated download or data-store failures' $State
            Reset-WduComponents
            $State.componentReset = $true
            foreach ($u in $exhausted) { $a = $State.attempts[$u.Id]; $a.count = [int] $Config.maxAttemptsPerUpdate - 1; $a.gaveUp = $false; $a.nextAttemptUtc = $null }
            Save-WduState $State $Paths
            return Request-WduReboot $Config $Paths $State 'Windows Update components were reset'
        }

        if ($rebootRequired -or (Test-WduRebootPending)) {
            return Request-WduReboot $Config $Paths $State "installed updates require a restart ($(Get-WduPassName $plan.Pass))"
        }
        # Next scan: a new session, so the next pass sees what this one installed.
        $script:Session = $null
    }
    return Complete-Wdu $Config $Paths $State 'Failed' 'Safety limit of 50 passes without a restart reached.'
}

function Invoke-WduMain {
    param([hashtable] $Config)
    # Engine 2.0.0: a configuration written by an older package (or a test) gets the newer defaults.
    foreach ($k in @($script:ConfigDefaults.Keys)) { if (-not $Config.ContainsKey($k)) { $Config[$k] = $script:ConfigDefaults[$k] } }
    # Engine 2.1.0: up to schema 9 "optional updates" also covered the Windows and .NET previews.
    if ($null -eq $Config.previewUpdates) { $Config.previewUpdates = ([string] $Config.optionalUpdates -eq 'install') }
    $paths = Get-WduPaths $Config
    foreach ($d in $paths.Root, $paths.Logs) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
    $script:LogFile = $paths.Log
    $script:StatusFile = $paths.Status
    $script:Activity = @{}
    Limit-WduLogSize $paths.Log

    $mutex = Enter-WduMutex $Config.mutexName
    if (-not $mutex) {
        Write-WduLog 'Another engine instance is running; exiting.'
        return 'AlreadyRunning'
    }
    try {
        return Invoke-WduRun -Config $Config -Paths $paths
    } catch {
        $err = $_
        Write-WduLog "Unhandled error: $($err.Exception.Message) $(Format-WduHResult $err.Exception.HResult)`r`n$($err.ScriptStackTrace)" 'ERROR'
        $state = Read-WduState $paths
        $state.errors = [int] $state.errors + 1
        Save-WduState $state $paths
        if ($state.errors -ge [int] $Config.maxErrors -and -not $state.final) {
            return Complete-Wdu $Config $paths $state 'Failed' "Stopped after $($state.errors) unexpected errors. Last: $($err.Exception.Message)"
        }
        Set-WduStatus 'Error' "$($err.Exception.Message) (will retry)" $state
        return 'Error'
    } finally {
        Exit-WduMutex $mutex
    }
}

function Invoke-WduScan {
    param([hashtable] $Config)
    $state = New-WduState
    $updates = Get-WduAvailableUpdates $Config
    foreach ($x in @($updates)) { if ($x -is [hashtable] -and -not $x.ContainsKey('Class')) { Set-WduUpdateClass $x } }
    $plan = Get-WduPlan $updates $Config $state
    $rows = @()
    foreach ($u in @($plan.Install) + @($plan.Later)) { $rows += [pscustomobject]@{ Action = 'Install'; Pass = (Get-WduPass $u); Class = [string] $u['Class']; KB = ($u.Kbs -join ','); Title = $u.Title; Reason = $(if ($u.IsDriver -and $u.Driver) { "driver for $($u.Driver['model']) [$($u.Driver['hardwareID'])]" } else { '' }) } }
    foreach ($s in $plan.Skipped) { $rows += [pscustomobject]@{ Action = 'Skip'; Pass = $s['pass']; Class = [string] $s['class']; KB = ($s.kbs -join ','); Title = $s.title; Reason = $s.reason } }
    $rows = @($rows | Sort-Object Action, Pass, Title)
    [pscustomobject]@{
        Updates       = $rows
        RebootPending = Test-WduRebootPending
        InstallerBusy = Test-WduInstallerBusy
    }
}

# Dot-sourcing (tests) only defines the functions.
if ($MyInvocation.InvocationName -ne '.') {
    $cfg = Get-WduConfig $ConfigPath
    if ($Mode -eq 'Scan') {
        $scan = Invoke-WduScan $cfg
        $scan.Updates | Format-Table -AutoSize -Wrap | Out-String -Width 200
        "Reboot pending: $($scan.RebootPending). Installer busy: $($scan.InstallerBusy)."
        exit 0
    }
    $outcome = Invoke-WduMain $cfg
    Write-Output $outcome
    if ($outcome -eq 'Error' -or $outcome -eq 'Finished:Failed') { exit 1 }
    exit 0
}
