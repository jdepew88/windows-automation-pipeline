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
#>
[CmdletBinding()]
param(
    [ValidateSet('Run', 'Scan')]
    [string] $Mode = 'Run',
    [string] $ConfigPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:EngineVersion = '1.3.0'
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
    '0x80240016' = @('WU_E_INSTALL_NOT_ALLOWED', 'another installation is in progress or a restart is pending', $false)
    '0x80240017' = @('WU_E_NOT_APPLICABLE', 'the update is not applicable to this computer', $true)
    '0x80240020' = @('WU_E_NO_INTERACTIVE_USER', 'the update needs a signed-in user to finish', $true)
    '0x80240022' = @('WU_E_ALL_UPDATES_FAILED', 'every update in the operation failed', $false)
    '0x8024000B' = @('WU_E_CALL_CANCELLED', 'the operation was cancelled', $false)
    '0x8024200D' = @('WU_E_UH_NEEDANOTHERDOWNLOAD', 'more content must be downloaded', $false)
    '0x8024402C' = @('WU_E_PT_WINHTTP_NAME_NOT_RESOLVED', 'the update server name could not be resolved', $false)
    '0x80244022' = @('WU_E_PT_HTTP_STATUS_SERVICE_UNAVAIL', 'the update service was temporarily unavailable (HTTP 503)', $false)
    '0x80246007' = @('WU_E_DM_NOTDOWNLOADED', 'the update has not been downloaded', $false)
    '0x80246008' = @('WU_E_DM_FAILTOCONNECTTOBITS', 'the Background Intelligent Transfer Service could not be reached', $false)
    '0x80070422' = @('ERROR_SERVICE_DISABLED', 'a required service is disabled', $false)
    '0x80072EE2' = @('ERROR_INTERNET_TIMEOUT', 'the connection timed out', $false)
    '0x80072EFD' = @('ERROR_INTERNET_CANNOT_CONNECT', 'the server could not be reached', $false)
    '0x80072F8F' = @('ERROR_INTERNET_SECURE_FAILURE', 'the secure connection failed (check the date and time)', $false)
    '0x800F0922' = @('CBS_E_INSTALLERS_FAILED', 'the servicing stack could not apply the update', $false)
    '0x80073701' = @('ERROR_SXS_ASSEMBLY_MISSING', 'a component the update needs is missing', $false)
    # .NET errors (facility 0x13) are raised by code, not by Windows Update's own result: either the
    # update's installer (command-line updates such as KB890830 and KB4052623 report their own
    # exit code) or the calling script. Engine 1.3.0 records which of the two it was.
    '0x80131508' = @('COR_E_INDEXOUTOFRANGE', '.NET "index out of range" error raised while installing (the update''s installer or the calling code), not a Windows Update result', $false)
    '0x80131509' = @('COR_E_INVALIDOPERATION', '.NET "invalid operation" error raised while installing, not a Windows Update result', $false)
}

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

function Get-WduConfig {
    param([string] $Path)
    if (-not $Path) { $Path = Join-Path $PSScriptRoot 'config.json' }
    $raw = Read-WduJson $Path
    if (-not $raw) { throw "Configuration file not found: $Path" }
    $defaults = @{
        dataRoot             = 'C:\ProgramData\WindowsDeploymentBuilder'
        taskPath             = '\WindowsDeploymentBuilder\'
        taskName             = 'WindowsUpdate'
        mutexName            = 'Global\WindowsDeploymentBuilder-WindowsUpdate'
        drivers              = 'exclude'
        featureUpdates       = 'skip'
        optionalUpdates      = 'skip'
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
    }
    foreach ($k in @($defaults.Keys)) { if (-not $raw.ContainsKey($k)) { $raw[$k] = $defaults[$k] } }
    $raw.excludedKbs = @($raw.excludedKbs | Where-Object { $_ } | ForEach-Object { ([string] $_).ToUpperInvariant() })
    return $raw
}

function Get-WduPaths {
    param([hashtable] $Config)
    $root = Join-Path $Config.dataRoot 'Updates'
    @{
        Root     = $root
        Logs     = Join-Path $root 'logs'
        Log      = Join-Path (Join-Path $root 'logs') 'engine.log'
        State    = Join-Path $root 'state.json'
        Status   = Join-Path $root 'status.json'
        Result   = Join-Path $root 'result.json'
        MarkerDir = Join-Path $Config.dataRoot 'state'
        Marker   = Join-Path (Join-Path $Config.dataRoot 'state') 'windows-update.done'
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
    $s.installed = @($s.installed | Where-Object { $_ })
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
        $list += @{
            Id             = [string] $u.Identity.UpdateID
            Revision       = [int] $u.Identity.RevisionNumber
            Title          = $title
            Kbs            = $kbs
            IsDriver       = ([int] $u.Type -eq 2)
            # A feature update by category, or an enablement package that switches the Windows version.
            IsUpgrade      = ($cats -contains $script:UpgradeCategoryId) -or (Test-WduFeatureTitle $title)
            IsInsider      = ($title -match '(?i)\bInsider Preview\b')
            IsOptional     = [bool] $u.BrowseOnly
            NeedsUserInput = [bool] $u.InstallationBehavior.CanRequestUserInput
            IsDownloaded   = [bool] $u.IsDownloaded
            SizeBytes      = $(try { [int64] $u.MaxDownloadSize } catch { [int64] 0 })
            Native         = $u
        }
    }
    return , $list
}

<# Titles of updates that move Windows to another version, whatever their category. #>
function Test-WduFeatureTitle {
    param([string] $Title)
    return ($Title -match '(?i)^\s*(Feature update to Windows|Upgrade to Windows)\b')
}

function ConvertTo-WduResultCode {
    param([int] $Code)
    switch ($Code) { 0 { 'NotStarted' } 1 { 'InProgress' } 2 { 'Succeeded' } 3 { 'SucceededWithErrors' } 4 { 'Failed' } 5 { 'Aborted' } default { "Unknown$Code" } }
}

function New-WduCollection {
    param([object[]] $Updates)
    $coll = New-Object -ComObject 'Microsoft.Update.UpdateColl'
    foreach ($u in $Updates) {
        if (-not $u.Native.EulaAccepted) { $u.Native.AcceptEula() }
        [void] $coll.Add($u.Native)
    }
    $coll
}

function Invoke-WduDownload {
    param([object[]] $Updates)
    $out = @{}
    $pending = @($Updates | Where-Object { -not $_.IsDownloaded })
    foreach ($u in $Updates) { if ($u.IsDownloaded) { $out[$u.Id] = @{ Result = 'Succeeded'; HResult = 0 } } }
    if ($pending.Count -eq 0) { return $out }
    try {
        $coll = New-WduCollection $pending
        $dl = (Get-WduSession).CreateUpdateDownloader()
        $dl.Updates = $coll
        $r = $dl.Download()
        for ($i = 0; $i -lt $pending.Count; $i++) {
            $ur = $r.GetUpdateResult($i)
            $out[$pending[$i].Id] = @{ Result = (ConvertTo-WduResultCode $ur.ResultCode); HResult = $ur.HResult }
        }
    } catch {
        # Engine 1.3.0: the call itself failed (not a per-update result): kept apart, with its message,
        # and the next attempt uses a new Windows Update session.
        $err = $_
        foreach ($u in $pending) { $out[$u.Id] = @{ Result = 'Failed'; HResult = $err.Exception.HResult; Source = 'engine'; Exception = "$($err.Exception.GetType().Name): $($err.Exception.Message)" } }
        Write-WduLog "Download call failed: $($err.Exception.GetType().FullName): $($err.Exception.Message)`r`n$($err.ScriptStackTrace)" 'ERROR'
        $script:Session = $null
    }
    return $out
}

function Invoke-WduInstall {
    param([object[]] $Updates)
    $out = @{ RebootRequired = $false; Results = @{} }
    try {
        $coll = New-WduCollection $Updates
        $inst = (Get-WduSession).CreateUpdateInstaller()
        try { $inst.ForceQuiet = $true } catch { }
        $inst.Updates = $coll
        $r = $inst.Install()
        $out.RebootRequired = [bool] $r.RebootRequired
        for ($i = 0; $i -lt $Updates.Count; $i++) {
            $ur = $r.GetUpdateResult($i)
            $out.Results[$Updates[$i].Id] = @{ Result = (ConvertTo-WduResultCode $ur.ResultCode); HResult = $ur.HResult }
        }
    } catch {
        $err = $_
        foreach ($u in $Updates) { $out.Results[$u.Id] = @{ Result = 'Failed'; HResult = $err.Exception.HResult; Source = 'engine'; Exception = "$($err.Exception.GetType().Name): $($err.Exception.Message)" } }
        Write-WduLog "Install call failed: $($err.Exception.GetType().FullName): $($err.Exception.Message)`r`n$($err.ScriptStackTrace)" 'ERROR'
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
    if ($Update.IsDriver -and $Config.drivers -ne 'include') { return 'driver (policy: exclude)' }
    if ($Update.IsOptional -and $Config.optionalUpdates -ne 'install') { return 'optional update (policy: skip)' }
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
        $entry = @{ id = $u.Id; title = $u.Title; kbs = @($u.Kbs); reason = $reason; kind = (Get-WduKind $u) }
        if ($reason -like 'gave up*') {
            $a = $State.attempts[$u.Id]
            $entry.attempts = $a.count; $entry.lastResult = $a.lastResult; $entry.lastHResult = $a.lastHResult
            $entry.error = Get-WduHResultText ([string] $a.lastHResult)
            # Engine 1.3.0: an exception in the engine's own call, or Windows Update's result for this update.
            $entry.errorSource = $(if ($a['lastErrorSource']) { [string] $a['lastErrorSource'] } else { 'windowsUpdate' })
            if ($a['lastException']) { $entry.exception = [string] $a['lastException'] }
            if ($a['restartChance'] -eq 'used') { $entry.retriedAfterRestart = $true }
            if ($a['interaction']) { $plan.Interaction += $entry } else { $plan.GaveUp += $entry }
        } else {
            $plan.Skipped += $entry
        }
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
    $max = [int] $Config.maxAttemptsPerUpdate
    $what = $(if ($Step -eq 'download') { 'download' } else { 'install' })
    $why = $(if ($hex) { Get-WduHResultText $hex } else { $Result })
    if ($A.lastErrorSource -eq 'engine') { $why = "the Windows Update call failed in the engine ($why; $($A.lastException))" }
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
        policy        = [ordered]@{ optionalUpdates = $Config.optionalUpdates; drivers = $Config.drivers; featureUpdates = $Config.featureUpdates; maxAttemptsPerUpdate = $Config.maxAttemptsPerUpdate }
    }
    Write-WduJson $Paths.Result $result
    $State.final = $Status
    Save-WduState $State $Paths
    if ($Status -in 'Succeeded', 'CompletedWithFollowUp', 'CompletedWithFailures') {
        if (-not (Test-Path -LiteralPath $Paths.MarkerDir)) { New-Item -ItemType Directory -Path $Paths.MarkerDir -Force | Out-Null }
        Write-WduJson $Paths.Marker ([ordered]@{ status = $Status; finishedUtc = $now; result = $Paths.Result })
    }
    $level = switch ($Status) { 'Succeeded' { 'INFO' } 'CompletedWithFailures' { 'WARN' } 'CompletedWithFollowUp' { 'WARN' } default { 'ERROR' } }
    Write-WduLog ("FINISHED: {0}. {1} Installed {2} (optional {3}, drivers {4}), failed {5}, need a person {6}, skipped {7}, reboots {8}." -f $Status, $Reason, @($result.installed).Count, $result.counts.installedOptional, $result.counts.installedDrivers, @($result.failed).Count, @($result.requiresInteraction).Count, @($result.skipped).Count, $State.reboots) $level
    foreach ($f in $result.failed) { Write-WduLog ("  FAILED   {0} {1} ({2} attempts, last {3} {4})" -f ($f.kbs -join ','), $f.title, $f.attempts, $f.lastResult, (Get-WduHResultText ([string] $f.lastHResult))) 'WARN' }
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

    # Another update operation (for example Windows' own automatic updates) may be installing.
    for ($i = 0; $i -lt 60 -and (Test-WduInstallerBusy); $i++) {
        if ($i -eq 0) { Write-WduLog 'Windows Update installer is busy; waiting (max 30 min).' }
        Set-WduStatus 'WaitingForInstaller' 'Windows is already installing updates (for example its own automatic updates); waiting for it to finish.' $State
        Wait-Wdu 30
    }

    $emptyScans = 0
    $scanFailures = 0
    for ($pass = 1; $pass -le 50; $pass++) {
        if (Test-WduDeadline $Config $State) { return Complete-Wdu $Config $Paths $State 'Failed' "Runtime limit ($($Config.maxRuntimeHours) h) reached." }

        Set-WduStatus 'Scanning' "Pass $pass" $State
        Write-WduLog "Scan pass $pass."
        try {
            $updates = Get-WduAvailableUpdates $Config
            $scanFailures = 0
        } catch {
            $scanFailures++
            $hr = Format-WduHResult $_.Exception.HResult
            Write-WduLog "Scan failed ($scanFailures/3): $($_.Exception.Message) $hr" 'ERROR'
            if ($scanFailures -lt 3) { Wait-Wdu 60; continue }
            if ($Config.resetComponentsOnce -and -not $State.componentReset) {
                Write-WduLog 'Resetting Windows Update components once after repeated scan failures.' 'WARN'
                Set-WduStatus 'ResettingComponents' 'Scan failures' $State
                Reset-WduComponents
                $State.componentReset = $true
                Save-WduState $State $Paths
                $scanFailures = 0
                continue
            }
            return Complete-Wdu $Config $Paths $State 'Failed' "Windows Update scan keeps failing: $($_.Exception.Message) $hr"
        }

        $plan = Get-WduPlan $updates $Config $State
        Write-WduLog ("Found {0} update(s): {1} to install, {2} skipped by policy, {3} given up, {4} need a person, {5} waiting to retry." -f @($updates).Count, @($plan.Install).Count, @($plan.Skipped).Count, @($plan.GaveUp).Count, @($plan.Interaction).Count, @($plan.Deferred).Count)

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
                Set-WduStatus 'Confirming' "Confirmation scan $emptyScans" $State
                Wait-Wdu ([int] $Config.confirmationDelaySeconds)
                continue
            }
            if (@($plan.GaveUp).Count -gt 0) {
                return Complete-Wdu $Config $Paths $State 'CompletedWithFailures' "$(@($plan.GaveUp).Count) update(s) could not be installed and were given up.$(if (@($plan.Interaction).Count) { " $(@($plan.Interaction).Count) update(s) need a person to install them." })" $plan
            }
            if (@($plan.Interaction).Count -gt 0) {
                return Complete-Wdu $Config $Paths $State 'CompletedWithFollowUp' "$(@($plan.Interaction).Count) update(s) need a person to install them (Windows reported that they need a signed-in user); everything else is installed." $plan
            }
            return Complete-Wdu $Config $Paths $State 'Succeeded' 'No applicable updates remain.' $plan
        }
        $emptyScans = 0

        # Coordination: no update installation while an application is being installed.
        $lock = Enter-WdbInstallLock $Config.dataRoot 'WindowsUpdate' ([int] $Config.lockWaitMinutes * 60)
        if (-not $lock) {
            Write-WduLog 'Another installation holds the install lock; trying again at the next start.' 'WARN'
            Set-WduStatus 'WaitingForLock' 'Waiting for an application installation to finish before installing updates.' $State
            return 'WaitingForLock'
        }
        $rebootRequired = $false
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
                $label = Get-WduLabel $u
                Write-WduLog ("  queued   {0} [{1}] (attempt {2}/{3})" -f $label, (Get-WduKind $u), $a.count, $max)
                Save-WduState $State $Paths
                $script:Activity.current = $label; $script:Activity.attempt = [int] $a.count; $script:Activity.maxAttempts = $max; $script:Activity.queued = @($plan.Install).Count
                $size = $(if ($u.ContainsKey('SizeBytes') -and [int64] $u.SizeBytes -gt 0) { " ($([Math]::Round([double] $u.SizeBytes / 1MB, 1)) MB)" } else { '' })
                Set-WduStatus 'Downloading' "Downloading $label$size, update $i of $(@($plan.Install).Count), attempt $($a.count) of $max. Progress unavailable." $State
                # One update per call: a failed download never holds back the others.
                $r = (Invoke-WduDownload @($u))[$u.Id]
                if ($r -and $r.Result -in 'Succeeded', 'SucceededWithErrors') { $ready += $u; continue }
                Register-WduFailure $u $a $Config 'download' $(if ($r) { "Download$($r.Result)" } else { 'DownloadMissing' }) $(if ($r) { $r.HResult } else { $null }) $r
            }
            Save-WduState $State $Paths

            # Ordinary updates are installed together; one that can ask for input is installed on its own, quietly.
            $batches = @()
            $normal = @($ready | Where-Object { -not $_.NeedsUserInput })
            if ($normal.Count) { $batches += , $normal }
            foreach ($u in @($ready | Where-Object { $_.NeedsUserInput })) { $batches += , @($u) }
            foreach ($batch in $batches) {
                $labels = @($batch | ForEach-Object { Get-WduLabel $_ })
                $script:Activity.current = ($labels -join '; ')
                Set-WduStatus 'Installing' "Installing $(@($batch).Count) update(s): $($labels -join '; ')" $State
                $in = Invoke-WduInstall $batch
                if ($in.RebootRequired) { $rebootRequired = $true }
                foreach ($u in $batch) {
                    $r = $in.Results[$u.Id]
                    $a = $State.attempts[$u.Id]
                    if ($r -and $r.Result -in 'Succeeded', 'SucceededWithErrors') {
                        $a.lastResult = $r.Result; $a.lastHResult = Format-WduHResult $r.HResult
                        $State.installed += @{ id = $u.Id; title = $u.Title; kbs = @($u.Kbs); kind = (Get-WduKind $u); optional = [bool] $u.IsOptional; driver = [bool] $u.IsDriver; result = $r.Result; atUtc = (Get-WduNow).ToString('o') }
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

        # An update about to be given up gets one more chance after a component reset (not a permanent failure).
        $exhausted = @($plan.Install | Where-Object {
            $a = $State.attempts[$_.Id]
            $a['gaveUp'] -and -not $a['permanent'] -and -not $a['interaction'] -and $a.lastResult -notin 'Succeeded', 'SucceededWithErrors'
        })
        if ($exhausted.Count -gt 0 -and $Config.resetComponentsOnce -and -not $State.componentReset) {
            Write-WduLog "$($exhausted.Count) update(s) keep failing; resetting Windows Update components once." 'WARN'
            Set-WduStatus 'ResettingComponents' 'Repeated update failures' $State
            Reset-WduComponents
            $State.componentReset = $true
            foreach ($u in $exhausted) { $a = $State.attempts[$u.Id]; $a.count = [int] $Config.maxAttemptsPerUpdate - 1; $a.gaveUp = $false; $a.nextAttemptUtc = $null }
            Save-WduState $State $Paths
            return Request-WduReboot $Config $Paths $State 'Windows Update components were reset'
        }

        if ($rebootRequired -or (Test-WduRebootPending)) {
            return Request-WduReboot $Config $Paths $State 'installed updates require a restart'
        }
    }
    return Complete-Wdu $Config $Paths $State 'Failed' 'Safety limit of 50 passes without a restart reached.'
}

function Invoke-WduMain {
    param([hashtable] $Config)
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
    $plan = Get-WduPlan $updates $Config $state
    $rows = @()
    foreach ($u in $plan.Install) { $rows += [pscustomobject]@{ Action = 'Install'; KB = ($u.Kbs -join ','); Title = $u.Title; Reason = '' } }
    foreach ($s in $plan.Skipped) { $rows += [pscustomobject]@{ Action = 'Skip'; KB = ($s.kbs -join ','); Title = $s.title; Reason = $s.reason } }
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
