#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Deployment Builder: the optional Microsoft Office LTSC stage (runs as SYSTEM).

.DESCRIPTION
    Started by the scheduled task \WindowsDeploymentBuilder\Office at startup and every 15 minutes
    until it has a final result. Each run decides one step from evidence and returns:

      1. Waits for the Windows Update stage, then for the WinGet application stage (at most
         waitFor.applications.maxWaitHours), and for any restart another engine scheduled.
      2. Respects an existing Office: the same product counts as installed (verified, not
         reinstalled); any other Click-to-Run Office, or Windows Installer Office without the
         explicit removeMsiOffice choice, ends the stage with a follow-up. Nothing is uninstalled.
      3. Checks free space, the connection to Microsoft and the pinned installer and configuration
         (SHA-256 of the text, as recorded by the builder).
      4. Takes the machine-wide installation lock and runs Install_Office.ps1 unattended. While it
         runs, the phase comes from the processes (ODT extraction, setup.exe /download,
         setup.exe /configure), not from console output, so a quiet download is never "stalled".
         The status is rewritten every 15 seconds. A run longer than installTimeoutMinutes is stopped.
      5. Verifies the Click-to-Run registration of the product before reporting success.

    Results (Office\result.json): Succeeded, CompletedWithFollowUp (existing Office, conflict),
    Failed, Offline. The marker state\office.done is written and the task removes itself.
    The stage never activates Office.
#>
[CmdletBinding()]
param([string] $ConfigPath)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:WdoVersion = '1.0.0'
$script:WdoEventSource = 'WindowsDeploymentBuilder'
$script:WdoLogFile = $null
$script:WdoStatusFile = $null
# Installer exit codes after which another attempt cannot help.
$script:WdoPermanentCodes = @(1, 2, 3, 4, 10)
$script:WdoPollSeconds = 15

# ------------------------------------------------------------------------------------------------
# Small helpers - functions so the tests can replace them.
# ------------------------------------------------------------------------------------------------

function Get-WdoNow { [DateTime]::UtcNow }
function Wait-Wdo { param([int] $Seconds) if ($Seconds -gt 0) { Start-Sleep -Seconds $Seconds } }

function ConvertTo-WdoDate {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    try { [DateTime]::Parse([string] $Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch { $null }
}

function ConvertTo-WdoHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { $h = @{}; foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-WdoHashtable $InputObject[$k] }; return $h }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) { $h = @{}; foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-WdoHashtable $p.Value }; return $h }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) { return , @($InputObject | ForEach-Object { ConvertTo-WdoHashtable $_ }) }
    return $InputObject
}

function Write-WdoJson {
    param([string] $Path, $Value)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, ($Value | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Read-WdoJson {
    param([string] $Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try { ConvertTo-WdoHashtable ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { $null }
}

function Write-WdoLog {
    param([string] $Message, [ValidateSet('INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO')
    $line = '{0}  {1,-5}  {2}' -f (Get-WdoNow).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Verbose $line
    if (-not $script:WdoLogFile) { return }
    for ($i = 0; $i -lt 3; $i++) { try { [System.IO.File]::AppendAllText($script:WdoLogFile, $line + "`r`n"); return } catch { Start-Sleep -Milliseconds 200 } }
}

<# status.json for the orchestrator, the progress window and the LAN monitor. #>
function Set-WdoStatus {
    param([string] $Phase, [string] $Detail, [hashtable] $State, [string] $LastError = '')
    if (-not $script:WdoStatusFile) { return }
    $o = [ordered]@{ phase = $Phase; detail = $Detail; updatedUtc = (Get-WdoNow).ToString('o'); engineVersion = $script:WdoVersion; reboots = 0; done = 0; total = 1
                     product = $script:WdoProductName; attempts = $(if ($State) { @($State.attempts).Count } else { 0 }); lastError = $LastError }
    try { Write-WdoJson $script:WdoStatusFile $o } catch { Write-WdoLog "Could not write status.json: $($_.Exception.Message)" 'WARN' }
}

function Write-WdoEvent {
    param([int] $EventId, [string] $Message, [ValidateSet('Information', 'Warning', 'Error')] [string] $EntryType = 'Information')
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($script:WdoEventSource)) { New-EventLog -LogName Application -Source $script:WdoEventSource }
        Write-EventLog -LogName Application -Source $script:WdoEventSource -EventId $EventId -EntryType $EntryType -Message $Message
    } catch { Write-WdoLog "Could not write event $EventId to the Application log: $($_.Exception.Message)" 'WARN' }
}

<# SHA-256 of a text file as the builder records it: no BOM, LF line ends, trimmed. #>
function Get-WdoTextHash {
    param([string] $Path)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8).TrimStart([char] 0xFEFF) -replace "`r`n?", "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text.Trim())) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
}

# ------------------------------------------------------------------------------------------------
# Configuration, paths, state
# ------------------------------------------------------------------------------------------------

function Get-WdoConfig {
    param([string] $Path)
    if (-not $Path) { $Path = Join-Path $PSScriptRoot 'office-config.json' }
    $c = Read-WdoJson $Path
    if ($c -isnot [hashtable]) { throw "Office configuration not found or not valid JSON: $Path" }
    if ([int] $c.schemaVersion -ne 1) { throw "Unsupported Office configuration version $($c.schemaVersion)." }
    if ([string] $c.dataRoot -notmatch '^[A-Za-z]:\\[^"*?<>|]+$') { throw 'The Office configuration has an invalid dataRoot.' }
    foreach ($k in 'product', 'installer', 'configuration', 'waitFor') { if ($c[$k] -isnot [hashtable]) { throw "The Office configuration has no '$k' block." } }
    if ([string] $c.product.productId -notmatch '^(Standard|ProPlus)(2021|2024)Volume$') { throw "Unsupported Office product: $($c.product.productId)" }
    if ([string] $c.product.channel -ne "PerpetualVL$($c.product.version)" -or [string] $c.product.productId -notlike "*$($c.product.version)Volume") { throw 'The Office product, version and channel do not match.' }
    foreach ($f in [string] $c.installer.file, [string] $c.configuration.file) { if ($f -notmatch '^[A-Za-z0-9_.-]+$') { throw "Invalid file name in the Office configuration: $f" } }
    $defaults = @{ minimumFreeSpaceGB = 10; installTimeoutMinutes = 240; maxAttempts = 2; networkWaitHours = 6 }
    foreach ($k in @($defaults.Keys)) { if (-not $c.ContainsKey($k) -or $null -eq $c[$k]) { $c[$k] = $defaults[$k] } }
    $c.maxAttempts = [int] [Math]::Min(3, [Math]::Max(1, [int] $c.maxAttempts))
    return $c
}

function Get-WdoPaths {
    param([hashtable] $Config, [string] $EngineDir)
    $root = Join-Path $Config.dataRoot 'Office'
    @{
        DataRoot = $Config.dataRoot
        Root     = $root
        State    = Join-Path $root 'state.json'
        Status   = Join-Path $root 'status.json'
        Result   = Join-Path $root 'result.json'
        Logs     = Join-Path $root 'logs'
        Work     = Join-Path $root 'work'
        Marker   = Join-Path (Join-Path $Config.dataRoot 'state') 'office.done'
        Engine   = $EngineDir
    }
}

function New-WdoState { @{ schemaVersion = 1; firstRunUtc = (Get-WdoNow).ToString('o'); attempts = @(); current = $null; networkWaitSinceUtc = $null } }

function Save-WdoState { param([hashtable] $Paths, [hashtable] $State) Write-WdoJson $Paths.State $State }

# ------------------------------------------------------------------------------------------------
# What Windows says (replaced in the tests)
# ------------------------------------------------------------------------------------------------

<#
    The installed Office: Click-to-Run product IDs and version, and Windows Installer (MSI) Office
    suites from the uninstall registry (both registry views).
#>
function Get-WdoInstalledOffice {
    $o = @{ clickToRun = @(); version = ''; msi = @() }
    $c2r = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
    if ($c2r) {
        if ($c2r.PSObject.Properties['ProductReleaseIds']) { $o.clickToRun = @(([string] $c2r.ProductReleaseIds) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        if ($c2r.PSObject.Properties['VersionToReport']) { $o.version = [string] $c2r.VersionToReport }
    }
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
        foreach ($e in @(Get-ItemProperty -Path $key -ErrorAction SilentlyContinue)) {
            $name = $(if ($e.PSObject.Properties['DisplayName']) { [string] $e.DisplayName } else { '' })
            $msi = $e.PSObject.Properties['WindowsInstaller'] -and [int] $e.WindowsInstaller -eq 1
            $system = $e.PSObject.Properties['SystemComponent'] -and [int] $e.SystemComponent -eq 1
            if ($msi -and -not $system -and $name -match '^Microsoft Office (Standard|Professional|Home|Small Business|Enterprise|Ultimate|Basic)') { $o.msi += $name }
        }
    }
    return $o
}

function Get-WdoFreeSpaceGB {
    $drive = New-Object System.IO.DriveInfo(($env:SystemDrive + '\'))
    return [Math]::Round($drive.AvailableFreeSpace / 1GB, 1)
}

<# True when any of Microsoft's Office endpoints answers (any HTTP status counts: the network works). #>
function Test-WdoNetwork {
    param([string[]] $Urls)
    foreach ($u in $Urls) {
        try { Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing -TimeoutSec 20 -MaximumRedirection 0 -ErrorAction Stop | Out-Null; return $true }
        catch { if ($_.Exception -is [System.Net.WebException] -and $_.Exception.Response) { return $true } }
    }
    return $false
}

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

<# The machine-wide installation lock shared with the other engines (see WindowsUpdateEngine.ps1). #>
function Enter-WdbInstallLock {
    param([string] $DataRoot, [string] $Owner, [int] $TimeoutSeconds = 0)
    $p = Get-WdbCoordinationPaths $DataRoot
    if (-not (Test-Path -LiteralPath $p.Dir)) { New-Item -ItemType Directory -Path $p.Dir -Force | Out-Null }
    $polls = [int] [Math]::Ceiling([Math]::Max(0, $TimeoutSeconds) / 5)
    for ($i = 0; ; $i++) {
        try {
            $fs = [System.IO.File]::Open($p.Lock, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes(('{{"owner":"{0}","pid":{1},"sinceUtc":"{2}"}}' -f $Owner, $PID, [DateTime]::UtcNow.ToString('o')))
            $fs.SetLength(0); $fs.Write($bytes, 0, $bytes.Length); $fs.Flush()
            return $fs
        } catch [System.IO.IOException] {
            if ($i -ge $polls) { return $null }
            Wait-WdbLockPoll
        }
    }
}

function Exit-WdbInstallLock { param($Lock) if ($Lock) { try { $Lock.Dispose() } catch { } } }

<# A restart another engine scheduled in this boot (restart-pending.json, valid for 30 minutes). #>
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
    return $false
}

function Add-WdbActivity {
    param([string] $DataRoot, [string] $Source, [string] $Message, [string] $Level = 'info')
    try {
        $dir = Join-Path $DataRoot 'Deployment'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $line = ([ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); level = $Level; source = $Source; message = $Message } | ConvertTo-Json -Compress)
        [System.IO.File]::AppendAllText((Join-Path $dir 'activity.jsonl'), $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

<# Starts Install_Office.ps1 in a hidden Windows PowerShell; returns @{ Id; Process }. #>
function Start-WdoInstaller {
    param([string] $Script, [string[]] $Arguments)
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $all = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$Script`"") + @($Arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } })
    $p = Start-Process -FilePath $ps -ArgumentList $all -WindowStyle Hidden -PassThru
    return @{ Id = $p.Id; Process = $p }
}

<# $null while the process runs, its exit code once it ended, -1 when it is gone without one. #>
function Get-WdoProcessExit {
    param([hashtable] $Run)
    if ($Run.Process) {
        if (-not $Run.Process.HasExited) { return $null }
        try { return [int] $Run.Process.ExitCode } catch { return -1 }
    }
    # Followed from an earlier run: only a Windows PowerShell process with that ID is the installer
    # (a reused process ID of another program is not).
    $p = Get-Process -Id ([int] $Run.Id) -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -ieq 'powershell') { return $null }
    return -1
}

function Stop-WdoProcessTree {
    param([int] $ProcessId)
    & "$env:SystemRoot\System32\taskkill.exe" /PID $ProcessId /T /F 2>&1 | Out-Null
}

<#
    What the installer is doing, from its processes: the ODT self-extractor, setup.exe /download or
    setup.exe /configure under the stage's working folder, and Click-to-Run itself.
#>
function Get-WdoInstallerActivity {
    param([string] $WorkDir)
    $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='setup.exe' OR Name='officedeploymenttool.exe' OR Name='OfficeClickToRun.exe'" -ErrorAction SilentlyContinue)
    $mine = @($procs | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($WorkDir, [StringComparison]::OrdinalIgnoreCase) })
    if (@($mine | Where-Object { $_.Name -ieq 'setup.exe' -and $_.CommandLine -match '/configure' }).Count) { return 'Installing' }
    if (@($mine | Where-Object { $_.Name -ieq 'setup.exe' -and $_.CommandLine -match '/download' }).Count) { return 'Downloading' }
    if (@($mine | Where-Object { $_.Name -ieq 'officedeploymenttool.exe' }).Count) { return 'PreparingTool' }
    return 'Preparing'
}

function Unregister-WdoTask {
    param([hashtable] $Config)
    try { Get-ScheduledTask -TaskName $Config.taskName -TaskPath $Config.taskPath -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false } catch { Write-WdoLog "Could not remove the scheduled task: $($_.Exception.Message)" 'WARN' }
}

# ------------------------------------------------------------------------------------------------
# Decisions
# ------------------------------------------------------------------------------------------------

$script:WdoPhaseText = @{
    Preparing     = 'Preparing the Office installation.'
    PreparingTool = 'Preparing the Microsoft Office Deployment Tool.'
    Downloading   = 'Downloading the Office installation files from Microsoft. This takes a while and shows no progress.'
    Installing    = 'Installing Office.'
    Verifying     = 'Verifying the Office installation.'
}

<# Other Office products that would conflict (language and proofing packs are not products). #>
function Get-WdoConflicts {
    param([hashtable] $Installed, [hashtable] $Config)
    $c = @()
    $c += @($Installed.clickToRun | Where-Object { $_ -ne $Config.product.productId -and $_ -notmatch '^(LanguagePack|ProofingTools|AccessRuntime)' } | ForEach-Object { "Click-to-Run Office ($_)" })
    if (-not $Config.removeMsiOffice) { $c += @($Installed.msi | ForEach-Object { "Windows Installer Office ($_)" }) }
    return , @($c)
}

function Test-WdoProductInstalled { param([hashtable] $Installed, [hashtable] $Config) return (@($Installed.clickToRun) -contains [string] $Config.product.productId) }

<# Writes the final result and the marker, removes the task. #>
function Complete-Wdo {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State, [string] $Status, [string] $Reason, [string] $Category = '', [hashtable] $Installed = $null, [bool] $AlreadyInstalled = $false)
    $last = @($State.attempts) | Select-Object -Last 1
    $result = [ordered]@{
        schemaVersion    = 1
        engineVersion    = $script:WdoVersion
        status           = $Status
        reason           = $Reason
        category         = $Category
        finishedUtc      = (Get-WdoNow).ToString('o')
        reboots          = 0
        product          = $Config.product
        verified         = ($Status -eq 'Succeeded')
        alreadyInstalled = $AlreadyInstalled
        installed        = $(if ($Installed) { [ordered]@{ clickToRun = @($Installed.clickToRun); version = [string] $Installed.version; msi = @($Installed.msi) } } else { $null })
        attempts         = @($State.attempts)
        exitCode         = $(if ($last) { $last.exitCode } else { $null })
        source           = [ordered]@{ installer = $Config.installer.source; configuration = $Config.configuration.source }
        logs             = $Paths.Logs
        activated        = $false
    }
    Write-WdoJson $Paths.Result $result
    $markerDir = Split-Path -Parent $Paths.Marker
    if (-not (Test-Path -LiteralPath $markerDir)) { New-Item -ItemType Directory -Path $markerDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Paths.Marker, "$Status $((Get-WdoNow).ToString('o'))")
    Set-WdoStatus $Status $Reason $State
    Write-WdoLog "Final: $Status. $Reason" $(if ($Status -eq 'Succeeded') { 'INFO' } else { 'WARN' })
    Add-WdbActivity $Config.dataRoot 'office' "$($Config.product.displayName): $Status. $Reason" $(if ($Status -eq 'Succeeded') { 'info' } else { 'warning' })
    Write-WdoEvent $(if ($Status -eq 'Succeeded') { 3201 } else { 3202 }) "Office stage: $Status. $Reason" $(if ($Status -in 'Succeeded') { 'Information' } else { 'Warning' })
    Unregister-WdoTask $Config
    return 0
}

<# Watches a running installer, rewriting the status every poll; returns its exit code (or 'Timeout'). #>
function Watch-WdoInstaller {
    param([hashtable] $Config, [hashtable] $Paths, [hashtable] $State, [hashtable] $Run, [DateTime] $Started)
    $limit = $Started.AddMinutes([int] $Config.installTimeoutMinutes)
    $last = ''
    while ($true) {
        $code = Get-WdoProcessExit $Run
        if ($null -ne $code) { return $code }
        if ((Get-WdoNow) -ge $limit) {
            Write-WdoLog "The installer has run for more than $($Config.installTimeoutMinutes) minutes; stopping it." 'ERROR'
            Stop-WdoProcessTree ([int] $Run.Id)
            return 'Timeout'
        }
        $phase = Get-WdoInstallerActivity $Paths.Work
        if ($phase -ne $last) { Write-WdoLog "Phase: $phase"; Add-WdbActivity $Config.dataRoot 'office' $script:WdoPhaseText[$phase]; $last = $phase }
        Set-WdoStatus $phase $script:WdoPhaseText[$phase] $State
        Wait-Wdo $script:WdoPollSeconds
    }
}

function Invoke-WdoRun {
    param([hashtable] $Config, [hashtable] $Paths)
    $existing = Read-WdoJson $Paths.Result
    if ($existing -and $existing.status) {
        Write-WdoLog "Already final ($($existing.status)); removing the task."
        Unregister-WdoTask $Config
        return 0
    }
    $state = Read-WdoJson $Paths.State
    if ($state -isnot [hashtable]) { $state = New-WdoState }
    $state.attempts = @($state.attempts)
    $now = Get-WdoNow

    # An attempt from an earlier run: still running (the engine was stopped, the installer was not)
    # or interrupted (a restart, a crash). Never start a second installer next to a running one.
    if ($state.current) {
        $cur = $state.current
        $sameBoot = [string] $cur.bootTimeUtc -eq (Get-WdbBootTime)
        $code = $(if ($sameBoot) { Get-WdoProcessExit @{ Id = [int] $cur.pid; Process = $null } } else { -1 })
        if ($null -eq $code) {
            Write-WdoLog "The installer started at $($cur.startedUtc) (process $($cur.pid)) is still running; following it."
            $code = Watch-WdoInstaller $Config $Paths $state @{ Id = [int] $cur.pid; Process = $null } (ConvertTo-WdoDate $cur.startedUtc)
            $state.attempts += @{ attempt = [int] $cur.attempt; startedUtc = $cur.startedUtc; finishedUtc = (Get-WdoNow).ToString('o'); exitCode = $(if ($code -is [int]) { $code } else { $null }); outcome = $(if ($code -eq 'Timeout') { 'TimedOut' } else { 'Finished' }); note = 'Followed after the engine restarted.' }
        } else {
            Write-WdoLog "The installer attempt started at $($cur.startedUtc) was interrupted (restart or crash)." 'WARN'
            $state.attempts += @{ attempt = [int] $cur.attempt; startedUtc = $cur.startedUtc; finishedUtc = $now.ToString('o'); exitCode = $null; outcome = 'Interrupted'; note = 'Interrupted by a restart or a crash.' }
            Add-WdbActivity $Config.dataRoot 'office' 'The Office installation was interrupted; it is checked and, if needed, tried again.' 'warning'
        }
        $state.current = $null
        Save-WdoState $Paths $state
    }

    # 1. Order: Windows Update, then the WinGet applications, then no pending restart.
    $wu = $Config.waitFor.windowsUpdate
    if ($wu -and $wu.enabled -and -not (Test-Path -LiteralPath (Join-Path $Config.dataRoot $wu.marker))) {
        Set-WdoStatus 'WaitingForUpdates' 'Office installs after Windows Update has finished.' $state; Save-WdoState $Paths $state; return 0
    }
    $apps = $Config.waitFor.applications
    if ($apps -and $apps.enabled -and -not (Test-Path -LiteralPath (Join-Path $Config.dataRoot $apps.marker))) {
        $since = ConvertTo-WdoDate $state.firstRunUtc
        if ($since -and ($now - $since).TotalHours -lt [double] $apps.maxWaitHours) {
            Set-WdoStatus 'WaitingForApplications' 'Office installs after the WinGet applications have finished.' $state; Save-WdoState $Paths $state; return 0
        }
        Write-WdoLog "The application stage has not finished after $($apps.maxWaitHours) hours; installing Office now (installations never overlap: they share the installation lock)." 'WARN'
    }
    if (Test-WdbRestartPending $Config.dataRoot) {
        Set-WdoStatus 'WaitingForRestart' 'Another stage scheduled a restart; Office installs after it.' $state; Save-WdoState $Paths $state; return 0
    }

    # 2. Existing Office.
    Set-WdoStatus 'Verifying' 'Checking for an existing Office installation.' $state
    $installed = Get-WdoInstalledOffice
    if (Test-WdoProductInstalled $installed $Config) {
        $already = @($state.attempts).Count -eq 0
        return (Complete-Wdo $Config $Paths $state 'Succeeded' "$($Config.product.displayName) is installed (Click-to-Run $($Config.product.productId), version $($installed.version))$(if ($already) { '; it was already installed, nothing was reinstalled' })." 'Verified' $installed $already)
    }
    $conflicts = Get-WdoConflicts $installed $Config
    if ($conflicts.Count -gt 0) {
        return (Complete-Wdo $Config $Paths $state 'CompletedWithFollowUp' "Not installed: this computer already has $($conflicts -join ', '). Nothing was removed. Remove it first (or choose 'remove MSI Office' for Windows Installer versions), then run Resume-Deployment.ps1 -RestartStage office." 'ExistingOffice' $installed)
    }

    # 3. Attempts, space, connection, integrity.
    $last = @($state.attempts) | Select-Object -Last 1
    if (@($state.attempts).Count -ge [int] $Config.maxAttempts) {
        return (Complete-Wdo $Config $Paths $state 'Failed' "Office was not installed after $(@($state.attempts).Count) attempt(s). Last: $(Get-WdoAttemptText $last). Logs: $($Paths.Logs)." $(if ($last) { [string] $last.category } else { 'Install' }) $installed)
    }
    $free = Get-WdoFreeSpaceGB
    if ($free -lt [double] $Config.minimumFreeSpaceGB) {
        return (Complete-Wdo $Config $Paths $state 'Failed' "Not enough free space on the system drive: $free GB free, $($Config.minimumFreeSpaceGB) GB needed." 'DiskSpace' $installed)
    }
    if (-not (Test-WdoNetwork @($Config.networkTest))) {
        if (-not $state.networkWaitSinceUtc) { $state.networkWaitSinceUtc = $now.ToString('o') }
        $waited = ($now - (ConvertTo-WdoDate $state.networkWaitSinceUtc)).TotalHours
        if ($waited -ge [double] $Config.networkWaitHours) {
            return (Complete-Wdo $Config $Paths $state 'Offline' "No connection to Microsoft's Office servers for $([Math]::Round($waited, 1)) hours. Connect the computer, then run Resume-Deployment.ps1 -RestartStage office." 'Network' $installed)
        }
        Set-WdoStatus 'WaitingForNetwork' "Waiting for a connection to Microsoft's Office servers." $state; Save-WdoState $Paths $state; return 0
    }
    $state.networkWaitSinceUtc = $null
    $installer = Join-Path $Paths.Engine ([string] $Config.installer.file)
    $configFile = Join-Path $Paths.Engine ([string] $Config.configuration.file)
    foreach ($f in @(@{ Path = $installer; Hash = [string] $Config.installer.textSha256 }, @{ Path = $configFile; Hash = [string] $Config.configuration.textSha256 })) {
        if (-not (Test-Path -LiteralPath $f.Path) -or (Get-WdoTextHash $f.Path) -ne $f.Hash) {
            return (Complete-Wdo $Config $Paths $state 'Failed' "The pinned Office file $(Split-Path -Leaf $f.Path) is missing or was changed; it was not run." 'Integrity' $installed)
        }
    }

    # 4. Install under the shared lock.
    $lock = Enter-WdbInstallLock $Config.dataRoot 'office' 0
    if (-not $lock) { Set-WdoStatus 'WaitingForLock' 'Waiting for another installation to finish.' $state; Save-WdoState $Paths $state; return 0 }
    try {
        foreach ($d in $Paths.Work, $Paths.Logs) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
        $installArgs = @($Config.installer.arguments | ForEach-Object { if ($_ -eq '<configuration>') { $configFile } else { [string] $_ } }) + @('-WorkingDirectory', $Paths.Work, '-LogDirectory', $Paths.Logs)
        $attempt = @($state.attempts).Count + 1
        Write-WdoLog "Attempt $attempt`: $($Config.product.displayName) with $($Config.installer.file) (commit $($Config.installer.source.commit)) $($installArgs -join ' ')"
        Add-WdbActivity $Config.dataRoot 'office' "Installing $($Config.product.displayName) (attempt $attempt)."
        Set-WdoStatus 'Preparing' $script:WdoPhaseText['Preparing'] $state
        $started = Get-WdoNow
        $run = Start-WdoInstaller $installer $installArgs
        $state.current = @{ pid = [int] $run.Id; startedUtc = $started.ToString('o'); bootTimeUtc = (Get-WdbBootTime); attempt = $attempt }
        Save-WdoState $Paths $state
        $code = Watch-WdoInstaller $Config $Paths $state $run $started
        $state.attempts += @{ attempt = $attempt; startedUtc = $started.ToString('o'); finishedUtc = (Get-WdoNow).ToString('o'); exitCode = $(if ($code -is [int]) { $code } else { $null }); outcome = $(if ($code -eq 'Timeout') { 'TimedOut' } else { 'Finished' }); category = $(Get-WdoCategory $code $Config) }
        $state.current = $null
        Save-WdoState $Paths $state
    } finally { Exit-WdbInstallLock $lock }

    # 5. Verify: the exit code alone is never proof.
    $last = @($state.attempts) | Select-Object -Last 1
    Set-WdoStatus 'Verifying' $script:WdoPhaseText['Verifying'] $state
    $installed = Get-WdoInstalledOffice
    if (Test-WdoProductInstalled $installed $Config) {
        if ($last.exitCode -ne 0) { Write-WdoLog "The installer returned $($last.exitCode), but $($Config.product.productId) is registered." 'WARN' }
        return (Complete-Wdo $Config $Paths $state 'Succeeded' "$($Config.product.displayName) installed and verified (Click-to-Run $($Config.product.productId), version $($installed.version))." 'Verified' $installed)
    }
    if ($last.exitCode -eq 0) { $last.category = 'NotVerified'; $last.note = "The installer reported success, but $($Config.product.productId) is not registered." ; Save-WdoState $Paths $state }
    $text = Get-WdoAttemptText $last
    Write-WdoLog "Attempt $($last.attempt) failed: $text" 'ERROR'
    if ($last.exitCode -in $script:WdoPermanentCodes) {
        return (Complete-Wdo $Config $Paths $state 'Failed' "Office was not installed: $text Logs: $($Paths.Logs)." ([string] $last.category) $installed)
    }
    if (@($state.attempts).Count -ge [int] $Config.maxAttempts) {
        return (Complete-Wdo $Config $Paths $state 'Failed' "Office was not installed after $(@($state.attempts).Count) attempt(s). Last: $text Logs: $($Paths.Logs)." ([string] $last.category) $installed)
    }
    Set-WdoStatus 'WaitingForRetry' "Attempt $($last.attempt) failed ($text); trying again at the next run." $state $text
    Add-WdbActivity $Config.dataRoot 'office' "Office attempt $($last.attempt) failed: $text It is tried again." 'warning'
    return 0
}

function Get-WdoCategory {
    param($Code, [hashtable] $Config)
    if ($Code -eq 'Timeout') { return 'Timeout' }
    $map = $Config.installer.exitCodes
    if ($map -and $map.ContainsKey([string] $Code)) { return [string] $map[[string] $Code] }
    return 'Unexpected'
}

function Get-WdoAttemptText {
    param($Attempt)
    if (-not $Attempt) { return 'no attempt' }
    if ($Attempt['note'] -and $Attempt.outcome -ne 'Finished') { return [string] $Attempt.note }
    if ($Attempt.outcome -eq 'TimedOut') { return 'the installer ran too long and was stopped.' }
    if ($Attempt['note']) { return [string] $Attempt.note }
    $cat = $(if ($Attempt['category']) { [string] $Attempt.category } else { '' })
    return "the installer returned exit code $($Attempt.exitCode)$(if ($cat) { " ($cat)" })."
}

function Invoke-WdoMain {
    $config = Get-WdoConfig $ConfigPath
    $paths = Get-WdoPaths $config $PSScriptRoot
    foreach ($d in $paths.Root, $paths.Logs) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
    $script:WdoLogFile = Join-Path $paths.Logs 'engine.log'
    $script:WdoStatusFile = $paths.Status
    $script:WdoProductName = [string] $config.product.displayName
    try { return (Invoke-WdoRun $config $paths) }
    catch {
        Write-WdoLog "Unexpected error: $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
        Set-WdoStatus 'Error' "Unexpected error: $($_.Exception.Message). The stage tries again at its next run." $null $_.Exception.Message
        return 1
    }
}

$script:WdoProductName = ''
if ($MyInvocation.InvocationName -ne '.') { exit (Invoke-WdoMain) }
