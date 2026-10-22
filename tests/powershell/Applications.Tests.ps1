#Requires -Version 5.1
<#
    Scenario tests for ApplicationEngine.ps1 and WinGetBootstrap.ps1 against a simulated WinGet,
    network, Task Scheduler and restart. Both scripts are dot-sourced (which only defines their
    functions) and every adapter that touches the system is replaced. Nothing is installed,
    registered or restarted.

    Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\powershell\Applications.Tests.ps1 [-ResultOut <dir>]
    -ResultOut copies the result.json of several scenarios there (validated against the schema by Vitest).
#>
param([string] $ResultOut = '')

$ErrorActionPreference = 'Stop'
$scripts = Join-Path $PSScriptRoot '..\..\src\engine\applications\scripts'
. (Join-Path $scripts 'ApplicationEngine.ps1')
. (Join-Path $scripts 'WinGetBootstrap.ps1')

$script:Failures = 0
$script:Passed = 0

function Assert-Equal($Actual, $Expected, [string] $Message) {
    if ("$Actual" -ne "$Expected") { throw "ASSERT: $Message. Expected <$Expected>, got <$Actual>." }
}
function Assert-True($Value, [string] $Message) { if (-not $Value) { throw "ASSERT: $Message" } }

# ------------------------------------------------------------------------------------------------
# Simulated machine
# ------------------------------------------------------------------------------------------------

function New-SimPackage {
    param([string] $Id, [string] $Behavior = 'ok', [string] $Source = 'winget', [string] $Interaction = 'unknown', [string[]] $After = @(), [string] $Method = '', [hashtable] $Portable = $null)
    @{ Id = $Id; Source = $Source; Behavior = $Behavior; Interaction = $Interaction; After = $After; Installed = ($Behavior -eq 'installed'); InstallCalls = 0; ListCalls = 0; ShowCalls = 0; Args = @()
       Method = $Method; Portable = $Portable }
}

function Reset-Sim {
    param([object[]] $Packages = @(), [bool] $Online = $true)
    $script:Sim = @{
        Now = [DateTime]::new(2026, 10, 19, 14, 0, 0, [DateTimeKind]::Utc)
        Packages = @($Packages); Boots = 0; Online = $Online; RebootPending = $false; RebootRequested = $false
        IsSystem = $false; Events = @(); TaskRemoved = $false; LockPolls = 0; WuTask = $false
        WinGetHealthy = $true; WinGetVersion = '1.29.250'; RegisterFixes = $true; RegisterCalls = 0; RegisterThrows = $false
        Offline = $null; SignatureValid = $true; OfflineInstalls = 0; OfflineFixes = $true; OnlineRepairs = 0; OnlineFixes = $true
        Hashes = @{}; Executed = @(); ExecExit = 0
        PortableRoot = (Join-Path ([IO.Path]::GetTempPath()) ("wda-test-portable-" + [Guid]::NewGuid().ToString('N')))
        ShortcutFolder = (Join-Path ([IO.Path]::GetTempPath()) ("wda-test-startmenu-" + [Guid]::NewGuid().ToString('N')))
        Shortcuts = @{}; Order = @()
        # Phase 5 fault injection
        Diagnoses = @(); SourceDown = @(); Random = 0.5; Waits = @(); OnlineAt = $null
    }
}

<# Files WinGet would extract for a portable package: <root>\<Id>_<source id>\... #>
function New-SimPortableFiles {
    param([hashtable] $S, [string[]] $Files = @())
    $dir = Join-Path $script:Sim.PortableRoot "$($S.Id)_Microsoft.Winget.Source_8wekyb3d8bbwe"
    if (-not $Files.Count) { $Files = @($S.PortableFiles) }
    foreach ($rel in $Files) {
        $p = Join-Path $dir $rel
        New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force | Out-Null
        [IO.File]::WriteAllText($p, 'MZ')
    }
}

function Get-SimPackage { param([hashtable] $P) $script:Sim.Packages | Where-Object { $_.Id -eq $P.packageIdentifier -and $_.Source -eq $P.source } | Select-Object -First 1 }

# Engine adapters
function Get-WdaNow { $script:Sim.Now }
function Wait-Wda { param([int] $Seconds) $script:Sim.Waits += $Seconds; $script:Sim.Now = $script:Sim.Now.AddSeconds($Seconds) }
function Get-WdaContext { @{ User = 'TEST\Alex'; IsSystem = $script:Sim.IsSystem; IsElevated = $true } }
function Update-SimNetwork { if ($script:Sim.OnlineAt -and $script:Sim.Now -ge $script:Sim.OnlineAt) { $script:Sim.Online = $true; $script:Sim.OnlineAt = $null } }
function Test-WdaNetwork { Update-SimNetwork; $script:Sim.Online }
# Phase 5: the network diagnosis and the jitter source are simulated too (no live network is used).
function Get-WdaNetworkDiagnosis {
    param([string] $Source = 'winget')
    $script:Sim.Diagnoses += $Source
    Update-SimNetwork
    if (-not $script:Sim.Online) { return @{ Level = 'InternetUnavailable'; Detail = 'simulated: offline' } }
    if ($script:Sim.SourceDown -contains $Source) { return @{ Level = 'SourceUnavailable'; Detail = "simulated: $Source down" } }
    @{ Level = 'Online'; Detail = 'simulated' }
}
function Get-WdaRandom { $script:Sim.Random }
function Test-WdaRebootPending { $script:Sim.RebootPending }
function Invoke-WdaReboot { param([int] $WarningSeconds, [string] $Reason) $script:Sim.RebootRequested = $true }
function Test-WdaUpdateTask { param([hashtable] $WU) $script:Sim.WuTask }
function Unregister-WdaTask { param([hashtable] $Config) $script:Sim.TaskRemoved = $true }
function Write-WdaEvent { param([int] $EventId, [string] $Message, [string] $EntryType = 'Information') $script:Sim.Events += $EventId }
function Get-WdbBootTime { "boot-$($script:Sim.Boots)" }
function Wait-WdbLockPoll { $script:Sim.LockPolls++ }
function Get-WdaFileHash { param([string] $Path) $script:Sim.Hashes[(Split-Path $Path -Leaf)] }
function Test-WdaSignature { param([string] $Path) $script:Sim.SignatureValid }
function Start-WdaInstaller { param([string] $Path, [string] $Type, [string[]] $Arguments, [int] $TimeoutMinutes) $script:Sim.Executed += , @((Split-Path $Path -Leaf), $Arguments); $script:Sim.ExecExit }

function Get-WdaPortableRoots { @($script:Sim.PortableRoot) }
function Get-WdaShortcutFolder { $script:Sim.ShortcutFolder }
function New-WdaShortcutFile { param([string] $Path, [string] $Target) $script:Sim.Shortcuts[$Path] = $Target; [IO.File]::WriteAllText($Path, $Target) }

function Test-WdaInstalled {
    param([hashtable] $P, [string] $LogFile = '')
    $s = Get-SimPackage $P
    if (-not $s) { return $false }
    $s.ListCalls++
    [bool] $s.Installed
}

function Test-WdaAvailable {
    param([hashtable] $P, [string] $LogFile = '')
    $s = Get-SimPackage $P
    if (-not $s) { return 'NotFound' }
    $s.ShowCalls++
    if ($s.Behavior -eq 'notfound') { return 'NotFound' }
    'Available'
}

function Install-WdaPackage {
    param([hashtable] $P, [int] $TimeoutMinutes, [string] $LogFile = '')
    $s = Get-SimPackage $P
    $s.InstallCalls++
    $script:Sim.Order += $s.Id
    $s.Args = Get-WdaArguments 'install' $P
    $code = 0
    switch ($s.Behavior) {
        'ok'            { $s.Installed = $true; if ($s.Method -eq 'portable') { New-SimPortableFiles $s } }
        'fail'          { $code = 0x8A150008 }
        'fail-once'     { if ($s.InstallCalls -ge 2) { $s.Installed = $true } else { $code = 0x8A150008 } }
        'hash'          { $code = 0x8A150011 }
        'cancel'        { $code = 0x8A15010C }
        'reboot-finish' { $s.Installed = $false; $s.InstalledAfterBoot = $script:Sim.Boots + 1; $code = 0x8A150109 }
        'reboot-now'    { if ($script:Sim.Boots -ge 1) { $s.Installed = $true } else { $code = 0x8A15010A } }
        'initiated'     { $s.InstalledAfterBoot = $script:Sim.Boots + 1; $code = 0x8A15010B }
        'timeout'       { return @{ ExitCode = $null; TimedOut = $true; Output = '' } }
        'crash'         { if ($s.InstallCalls -eq 1) { $s.Installed = $true; throw 'Simulated engine crash during installation' } else { $s.Installed = $true } }
        # Phase 5 fault injection
        'fail-twice'    { if ($s.InstallCalls -ge 3) { $s.Installed = $true } else { $code = 0x8A150008 } }
        'timeout-once'  { if ($s.InstallCalls -ge 2) { $s.Installed = $true } else { return @{ ExitCode = $null; TimedOut = $true; Output = '' } } }
        'net-drop'      { if ($s.InstallCalls -eq 1) { $script:Sim.Online = $false; $script:Sim.OnlineAt = $script:Sim.Now.AddMinutes(90); $code = 0x8A150107 } else { $s.Installed = $true } }
        'store-down'    { if ($script:Sim.SourceDown -contains $s.Source) { $code = 0x8A150045 } else { $s.Installed = $true } }
        'unknown-once'  { if ($s.InstallCalls -ge 2) { $s.Installed = $true } else { $code = 0x80070005 } }
        'fail-but-installed' { $s.Installed = $true; $code = 0x8A150008 }
        'false-success' { $code = 0 }
        'locked-once'   { if ($s.InstallCalls -ge 2) { $s.Installed = $true } else { $code = 0x8A150102 } }
    }
    @{ ExitCode = [int] $code; TimedOut = $false; Output = '' }
}

# Bootstrap adapters
function Get-WgbContext { @{ User = 'TEST\Alex'; IsSystem = $script:Sim.IsSystem; IsElevated = $true; Build = 26100 } }
function Find-WgbWinGet { if ($script:Sim.WinGetHealthy) { 'C:\Users\Alex\AppData\Local\Microsoft\WindowsApps\winget.exe' } else { $null } }
function Invoke-WgbWinGetCommand {
    param([string] $Path, [string[]] $Arguments)
    if ($Arguments[0] -eq '--version') { return @{ ExitCode = 0; Output = "v$($script:Sim.WinGetVersion)" } }
    @{ ExitCode = 0; Output = "Name    Argument`r`n-----------------`r`nmsstore https://storeedgefd.dsx.mp.microsoft.com/v9.0`r`nwinget  https://cdn.winget.microsoft.com/cache`r`n" }
}
function Get-WgbAppInstaller { @{ Installed = $script:Sim.WinGetHealthy; Version = '1.29.250.0' } }
function Register-WgbAppInstaller { $script:Sim.RegisterCalls++; if ($script:Sim.RegisterThrows) { throw 'Simulated registration failure' }; if ($script:Sim.RegisterFixes) { $script:Sim.WinGetHealthy = $true } }
function Find-WgbOfflinePackages { param([string] $Directory) $script:Sim.Offline }
function Test-WgbSignature { param([string] $Path) $script:Sim.SignatureValid }
function Install-WgbOfflinePackage { param([string] $Bundle, [string[]] $Dependencies) $script:Sim.OfflineInstalls++; if ($script:Sim.OfflineFixes) { $script:Sim.WinGetHealthy = $true } }
function Invoke-WgbOnlineRepair { param([bool] $AllUsers) $script:Sim.OnlineRepairs++; if ($script:Sim.OnlineFixes) { $script:Sim.WinGetHealthy = $true } }
function Wait-Wgb { param([int] $Seconds) $script:Sim.Now = $script:Sim.Now.AddSeconds($Seconds) }

# ------------------------------------------------------------------------------------------------
# Configuration and runner
# ------------------------------------------------------------------------------------------------

function New-AppTestConfig {
    param([object[]] $Packages = @(), [hashtable] $Overrides = @{}, [object[]] $Additional = @(), [object[]] $Unresolved = @(), [object[]] $NativeOnly = @())
    $root = Join-Path ([IO.Path]::GetTempPath()) ("wda-test-" + [Guid]::NewGuid().ToString('N'))
    $cfgDir = Join-Path $root 'config'
    New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    $c = [ordered]@{
        schemaVersion = 1; engineVersion = '1.0.0'; dataRoot = $root; taskPath = '\WdbTest\'; taskName = 'Applications'
        mutexName = "Local\wda-test-$([Guid]::NewGuid().ToString('N'))"; packagesFile = 'winget-packages.json'
        coordination = @{ policy = 'updatesFirst'; windowsUpdate = @{ enabled = $false; stateFile = (Join-Path $root 'Updates\state.json'); resultFile = (Join-Path $root 'Updates\result.json'); taskPath = '\WdbTest\'; taskName = 'WindowsUpdate' } }
        restartPolicy = 'whenRequired'; registerAppInstaller = $true; onlineRepair = $false; minimumWinGetVersion = '1.6.0'
        maxReboots = 3; maxAttemptsPerPackage = 2; packageTimeoutMinutes = 30; networkWaitMinutes = 15; maxRuntimeHours = 4
        waitForUpdatesHours = 8; gatePollMinutes = 5; lockWaitMinutes = 1; maxErrors = 5; rebootWarningSeconds = 60; retryDelaySeconds = 30
        packages = @($Packages | ForEach-Object {
            $e = @{ key = "$($_.Source):$($_.Id.ToLowerInvariant())"; packageIdentifier = $_.Id; source = $_.Source; displayName = "App $($_.Id)"; version = ''; scope = ''; interaction = $_.Interaction; after = @($_.After) }
            # Engine 1.1.0 fields only when a scenario sets them (configs written for 1.0.0 have none).
            if ($_.Method) { $e.method = $_.Method }
            if ($_.Method -eq 'portable') { $e.scope = 'machine' }
            if ($_.Portable) { $e.portable = $_.Portable }
            $e
        })
        unresolved = @($Unresolved); additionalSoftware = @($Additional)
    }
    foreach ($k in $Overrides.Keys) { $c[$k] = $Overrides[$k] }
    $bySource = @{}
    foreach ($p in @($Packages) + @($NativeOnly)) { if (-not $bySource.ContainsKey($p.Source)) { $bySource[$p.Source] = @() }; $bySource[$p.Source] += @{ PackageIdentifier = $p.Id } }
    $details = @{ winget = @{ Name = 'winget'; Identifier = 'Microsoft.Winget.Source_8wekyb3d8bbwe'; Argument = 'https://cdn.winget.microsoft.com/cache'; Type = 'Microsoft.PreIndexed.Package' }
                  msstore = @{ Name = 'msstore'; Identifier = 'StoreEdgeFD'; Argument = 'https://storeedgefd.dsx.mp.microsoft.com/v9.0'; Type = 'Microsoft.Rest' } }
    $native = @{ '$schema' = 'https://aka.ms/winget-packages.schema.2.0.json'; Sources = @($bySource.Keys | ForEach-Object { @{ Packages = @($bySource[$_]); SourceDetails = $details[$_] } }) }
    [IO.File]::WriteAllText((Join-Path $cfgDir 'winget-packages.json'), ($native | ConvertTo-Json -Depth 10))
    [IO.File]::WriteAllText((Join-Path $cfgDir 'applications-config.json'), ($c | ConvertTo-Json -Depth 10))
    Get-WdaConfig (Join-Path $cfgDir 'applications-config.json')
}

<# Runs the engine like the scheduled task: at each sign-in and hourly, until it is final. #>
function Invoke-Logons {
    param([hashtable] $Config, [int] $Max = 30)
    $outcomes = @()
    for ($i = 0; $i -lt $Max; $i++) {
        $script:Sim.RebootRequested = $false
        $o = Invoke-WdaMain $Config
        $outcomes += $o
        if ($o -eq 'Rebooting') {
            $script:Sim.Boots++
            $script:Sim.RebootPending = $false
            foreach ($p in $script:Sim.Packages) { if ($p.ContainsKey('InstalledAfterBoot') -and $script:Sim.Boots -ge $p.InstalledAfterBoot) { $p.Installed = $true } }
            $script:Sim.Now = $script:Sim.Now.AddMinutes(5)
            continue
        }
        if ($o -like 'Finished:*' -or $o -eq 'AlreadyFinished' -or $o -eq 'AlreadyRunning') { break }
        $script:Sim.Now = $script:Sim.Now.AddHours(1)
    }
    , $outcomes
}

function Get-Result { param([hashtable] $Config) Get-Content -LiteralPath (Join-Path $Config.dataRoot 'Applications\result.json') -Raw | ConvertFrom-Json }
function Get-Pkg { param($Result, [string] $Id) $Result.packages | Where-Object { $_.packageIdentifier -eq $Id } }
function Test-Marker { param([hashtable] $Config) Test-Path -LiteralPath (Join-Path $Config.dataRoot 'state\applications.done') }
function Save-Result {
    param([hashtable] $Config, [string] $Name)
    if ($ResultOut) { Copy-Item -LiteralPath (Join-Path $Config.dataRoot 'Applications\result.json') -Destination (Join-Path $ResultOut "$Name.json") -Force }
}

<# Holds a mutex in another process and returns once it is really held (no fixed sleep, so a busy machine cannot race it). #>
function Start-MutexHolder {
    param([string] $Name, [int] $Seconds = 30)
    $flag = Join-Path ([IO.Path]::GetTempPath()) ("wda-held-" + [Guid]::NewGuid().ToString('N'))
    $job = Start-Job -ArgumentList $Name, $flag, $Seconds -ScriptBlock {
        param($name, $flag, $s)
        $m = New-Object System.Threading.Mutex($false, $name)
        [void] $m.WaitOne()
        [IO.File]::WriteAllText($flag, 'held')
        Start-Sleep -Seconds $s
        $m.ReleaseMutex()
    }
    for ($i = 0; $i -lt 600 -and -not (Test-Path -LiteralPath $flag); $i++) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $flag)) { $job | Stop-Job -PassThru | Remove-Job -Force; throw 'the mutex holder did not start within 60 s' }
    Remove-Item -LiteralPath $flag -Force
    return $job
}

$tests = [ordered]@{}

# ------------------------------------------------------------------------------------------------
# Engine
# ------------------------------------------------------------------------------------------------

$tests['installs every package in order with explicit id, exact match and source: Succeeded'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'), (New-SimPackage '7zip.7zip'), (New-SimPackage '9MSPC6MP8FM4' -Source msstore))
    $c = New-AppTestConfig $script:Sim.Packages
    $o = Invoke-Logons $c
    Assert-Equal ($o -join ',') 'Finished:Succeeded' 'outcome'
    $r = Get-Result $c
    Assert-Equal (($r.packages | ForEach-Object { $_.status }) -join ',') 'Succeeded,Succeeded,Succeeded' 'statuses'
    Assert-Equal (($r.packages | ForEach-Object { $_.packageIdentifier }) -join ',') 'Git.Git,7zip.7zip,9MSPC6MP8FM4' 'order kept'
    Assert-Equal ($script:Sim.Packages[0].Args -join ' ') 'install --id Git.Git --exact --source winget --silent --no-upgrade --accept-package-agreements --accept-source-agreements --disable-interactivity' 'command'
    Assert-True (Test-Marker $c) 'marker written'
    Assert-True $script:Sim.TaskRemoved 'task removed'
    Assert-True ($script:Sim.Events -contains 2000 -and $script:Sim.Events -contains 2100) 'events'
    Assert-Equal $r.bootstrap.status 'Healthy' 'healthy WinGet left alone'
    Assert-Equal $script:Sim.RegisterCalls 0 'no repair of a healthy WinGet'
    Save-Result $c 'succeeded'
}

$tests['already installed packages are skipped, never reinstalled'] = {
    Reset-Sim @((New-SimPackage 'Git.Git' 'installed'), (New-SimPackage '7zip.7zip'))
    $c = New-AppTestConfig $script:Sim.Packages
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'outcome'
    $r = Get-Result $c
    Assert-Equal (Get-Pkg $r 'Git.Git').status 'AlreadyInstalled' 'status'
    Assert-Equal $script:Sim.Packages[0].InstallCalls 0 'no install call'
    Assert-Equal $r.counts.alreadyInstalled 1 'counted'
}

$tests['a transient failure is retried and then succeeds'] = {
    Reset-Sim @((New-SimPackage 'Git.Git' 'fail-once'))
    $c = New-AppTestConfig $script:Sim.Packages
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'outcome'
    Assert-Equal (Get-Pkg (Get-Result $c) 'Git.Git').attempts 2 'two attempts'
}

$tests['a persistent failure is given up after maxAttempts: CompletedWithFailures, never Succeeded'] = {
    Reset-Sim @((New-SimPackage 'Git.Git' 'fail'), (New-SimPackage '7zip.7zip'))
    $c = New-AppTestConfig $script:Sim.Packages
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:CompletedWithFailures' 'outcome'
    $p = Get-Pkg (Get-Result $c) 'Git.Git'
    Assert-Equal $p.status 'Failed' 'status'
    Assert-Equal $p.attempts 2 'attempts'
    Assert-Equal $p.exitCode '0x8A150008' 'exit code recorded'
    Assert-Equal $script:Sim.Packages[0].InstallCalls 2 'exactly maxAttempts installs'
    Assert-Equal (Get-Pkg (Get-Result $c) '7zip.7zip').status 'Succeeded' 'others continue'
    Assert-True (Test-Marker $c) 'marker for partial success'
    Assert-True ($script:Sim.Events -contains 2101) 'warning event'
    Save-Result $c 'failures'
}

$tests['hash mismatch is not retried'] = {
    Reset-Sim @((New-SimPackage 'Git.Git' 'hash'))
    $c = New-AppTestConfig $script:Sim.Packages
    [void] (Invoke-Logons $c)
    $p = Get-Pkg (Get-Result $c) 'Git.Git'
    Assert-Equal $p.status 'Failed' 'status'
    Assert-Equal $script:Sim.Packages[0].InstallCalls 1 'one attempt only'
    Assert-True ($p.message -match 'hash') 'reason'
}

$tests['a package missing from the source is Unavailable without an install attempt'] = {
    Reset-Sim @((New-SimPackage 'Gone.Package' 'notfound'), (New-SimPackage 'Git.Git'))
    $c = New-AppTestConfig $script:Sim.Packages
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:CompletedWithFailures' 'outcome'
    Assert-Equal (Get-Pkg (Get-Result $c) 'Gone.Package').status 'Unavailable' 'status'
    Assert-Equal $script:Sim.Packages[0].InstallCalls 0 'not attempted'
}

$tests['packages that need interaction are reported, not attempted: CompletedWithFollowUp'] = {
    Reset-Sim @((New-SimPackage 'Vendor.Interactive' -Interaction required), (New-SimPackage 'Git.Git'))
    $c = New-AppTestConfig $script:Sim.Packages
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:CompletedWithFollowUp' 'outcome'
    Assert-Equal (Get-Pkg (Get-Result $c) 'Vendor.Interactive').status 'RequiresInteraction' 'status'
    Assert-Equal $script:Sim.Packages[0].InstallCalls 0 'not attempted'
    Assert-True (Test-Marker $c) 'marker written'
    Assert-True ((Get-Content -LiteralPath (Join-Path $c.dataRoot 'Applications\follow-up.txt') -Raw) -match 'Vendor.Interactive|App Vendor') 'follow-up list'
    Save-Result $c 'followup'
}

$tests['cancelled installer is RequiresInteraction'] = {
    Reset-Sim @((New-SimPackage 'Vendor.Cancel' 'cancel'))
    $c = New-AppTestConfig $script:Sim.Packages
    [void] (Invoke-Logons $c)
    Assert-Equal (Get-Pkg (Get-Result $c) 'Vendor.Cancel').status 'RequiresInteraction' 'status'
}

$tests['restart required to finish: restart once at the end, verify after sign-in'] = {
    Reset-Sim @((New-SimPackage 'Vendor.NeedsReboot' 'reboot-finish'), (New-SimPackage 'Git.Git'))
    $c = New-AppTestConfig $script:Sim.Packages
    $o = Invoke-Logons $c
    Assert-Equal ($o -join ',') 'Rebooting,Finished:Succeeded' 'outcomes'
    $r = Get-Result $c
    Assert-Equal (Get-Pkg $r 'Vendor.NeedsReboot').status 'Succeeded' 'verified after restart'
    Assert-Equal $script:Sim.Packages[0].InstallCalls 1 'not reinstalled'
    Assert-Equal $r.reboots 1 'one restart'
}

$tests['restart required before install: restart immediately, then install'] = {
    Reset-Sim @((New-SimPackage 'Vendor.RebootFirst' 'reboot-now'), (New-SimPackage 'Git.Git'))
    $c = New-AppTestConfig $script:Sim.Packages
    $o = Invoke-Logons $c
    Assert-Equal ($o -join ',') 'Rebooting,Finished:Succeeded' 'outcomes'
    Assert-Equal $script:Sim.Packages[0].InstallCalls 2 'installed after the restart'
    Assert-Equal $script:Sim.Packages[1].InstallCalls 1 'later packages installed once, after the restart'
}

$tests['installer-initiated restart resumes without a second restart request'] = {
    Reset-Sim @((New-SimPackage 'Vendor.SelfReboot' 'initiated'))
    $c = New-AppTestConfig $script:Sim.Packages
    $script:Requested = 0
    function Invoke-WdaReboot { param([int] $WarningSeconds, [string] $Reason) $script:Requested++ }
    $o = Invoke-Logons $c
    Assert-Equal ($o -join ',') 'Rebooting,Finished:Succeeded' 'outcomes'
    Assert-Equal $script:Requested 0 'engine did not call shutdown itself'
}

$tests['restart policy never: RequiresRestart is reported, no restart'] = {
    Reset-Sim @((New-SimPackage 'Vendor.NeedsReboot' 'reboot-finish'))
    $c = New-AppTestConfig $script:Sim.Packages -Overrides @{ restartPolicy = 'never' }
    $o = Invoke-Logons $c
    Assert-Equal ($o -join ',') 'Finished:CompletedWithFollowUp' 'outcome'
    Assert-Equal (Get-Pkg (Get-Result $c) 'Vendor.NeedsReboot').status 'RequiresRestart' 'status'
}

$tests['restart limit is respected'] = {
    Reset-Sim @((New-SimPackage 'Vendor.RebootFirst' 'reboot-now'))
    $c = New-AppTestConfig $script:Sim.Packages -Overrides @{ maxReboots = 0 }
    $o = Invoke-Logons $c
    Assert-Equal ($o -join ',') 'Finished:CompletedWithFollowUp' 'no restart'
    Assert-True ((Get-Pkg (Get-Result $c) 'Vendor.RebootFirst').message -match 'not allowed') 'reason'
}

$tests['timeout counts as a failed attempt'] = {
    Reset-Sim @((New-SimPackage 'Vendor.Hangs' 'timeout'))
    $c = New-AppTestConfig $script:Sim.Packages
    [void] (Invoke-Logons $c)
    $p = Get-Pkg (Get-Result $c) 'Vendor.Hangs'
    Assert-Equal $p.status 'Failed' 'status'
    Assert-Equal $p.attempts 2 'attempts'
}

$tests['crash during installation: resumes, confirms the package and counts the attempt'] = {
    Reset-Sim @((New-SimPackage 'Vendor.Crash' 'crash'), (New-SimPackage 'Git.Git'))
    $c = New-AppTestConfig $script:Sim.Packages
    $o = Invoke-Logons $c
    Assert-Equal ($o -join ',') 'Error,Finished:Succeeded' 'outcomes'
    $p = Get-Pkg (Get-Result $c) 'Vendor.Crash'
    Assert-Equal $p.status 'Succeeded' 'confirmed after the interruption'
    Assert-Equal $p.attempts 1 'attempt counted before the crash'
    Assert-Equal $script:Sim.Packages[0].InstallCalls 1 'not installed twice'
}

$tests['offline until the limit: Offline, packages stay Pending, no marker'] = {
    Reset-Sim @((New-SimPackage 'Git.Git')) -Online $false
    $c = New-AppTestConfig $script:Sim.Packages -Overrides @{ waitForUpdatesHours = 1; maxRuntimeHours = 1 }
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:Offline' 'outcome'
    Assert-True ($o -contains 'WaitingForNetwork') 'waited first'
    Assert-Equal (Get-Pkg (Get-Result $c) 'Git.Git').status 'Pending' 'recoverable pending'
    Assert-True (-not (Test-Marker $c)) 'no marker'
    Assert-True ($script:Sim.Events -contains 2103) 'offline event'
    Save-Result $c 'offline'
}

$tests['network arriving later resumes the run'] = {
    Reset-Sim @((New-SimPackage 'Git.Git')) -Online $false
    $c = New-AppTestConfig $script:Sim.Packages
    Assert-Equal (Invoke-WdaMain $c) 'WaitingForNetwork' 'first start'
    $script:Sim.Online = $true
    Assert-Equal (Invoke-WdaMain $c) 'Finished:Succeeded' 'second start'
}

$tests['WinGet not registered yet: documented registration repairs it, then installs'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'))
    $script:Sim.WinGetHealthy = $false
    $c = New-AppTestConfig $script:Sim.Packages
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'outcome'
    $r = Get-Result $c
    Assert-Equal $r.bootstrap.status 'Repaired' 'bootstrap status'
    Assert-Equal $r.bootstrap.method 'registration' 'method'
    Assert-Equal $script:Sim.RegisterCalls 1 'registered once'
}

$tests['WinGet cannot be initialized: Failed clearly, nothing attempted, no marker'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'))
    $script:Sim.WinGetHealthy = $false
    $script:Sim.RegisterFixes = $false
    $c = New-AppTestConfig $script:Sim.Packages
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:Failed' 'outcome'
    $r = Get-Result $c
    Assert-True ($r.reason -match 'could not be initialized') "reason: $($r.reason)"
    Assert-Equal (Get-Pkg $r 'Git.Git').status 'Pending' 'not attempted, recoverable'
    Assert-Equal $script:Sim.Packages[0].InstallCalls 0 'no install'
    Assert-True (-not (Test-Marker $c)) 'no marker'
    Save-Result $c 'bootstrap-failed'
}

$tests['SYSTEM context is refused before WinGet is touched'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'))
    $script:Sim.IsSystem = $true
    $c = New-AppTestConfig $script:Sim.Packages
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:Failed' 'outcome'
    Assert-True ((Get-Result $c).reason -match 'SYSTEM') 'reason'
    Assert-Equal $script:Sim.Packages[0].ShowCalls 0 'no WinGet call'
}

$tests['updatesFirst: prepares while Windows Update runs, installs only after it is final'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'))
    $script:Sim.WuTask = $true
    $c = New-AppTestConfig $script:Sim.Packages
    $c.coordination.windowsUpdate.enabled = $true
    $wuDir = Join-Path $c.dataRoot 'Updates'
    New-Item -ItemType Directory -Path $wuDir -Force | Out-Null
    Set-Content -LiteralPath $c.coordination.windowsUpdate.stateFile -Value '{ "final": null, "starts": 1 }'
    Assert-Equal (Invoke-WdaMain $c) 'WaitingForUpdates' 'waits'
    Assert-Equal $script:Sim.Packages[0].ShowCalls 1 'availability checked during preparation'
    Assert-Equal $script:Sim.Packages[0].InstallCalls 0 'nothing installed yet'
    Set-Content -LiteralPath $c.coordination.windowsUpdate.stateFile -Value '{ "final": "CompletedWithFailures" }'
    Assert-Equal (Invoke-WdaMain $c) 'Finished:Succeeded' 'installs after Windows Update'
    Assert-Equal $script:Sim.Packages[0].ShowCalls 1 'preparation not repeated'
}

$tests['updatesFirst: proceeds after waitForUpdatesHours if Windows Update never finishes'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'))
    $script:Sim.WuTask = $true
    $c = New-AppTestConfig $script:Sim.Packages -Overrides @{ waitForUpdatesHours = 2 }
    $c.coordination.windowsUpdate.enabled = $true
    $o = Invoke-Logons $c
    Assert-True ($o -contains 'WaitingForUpdates') 'waited'
    Assert-Equal $o[-1] 'Finished:Succeeded' 'continued'
}

$tests['updatesFirst: a missing Windows Update engine does not block forever'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'))
    $c = New-AppTestConfig $script:Sim.Packages -Overrides @{ gatePollMinutes = 40 }
    $c.coordination.windowsUpdate.enabled = $true
    Assert-Equal (Invoke-WdaMain $c) 'Finished:Succeeded' 'continues after 30 minutes without task or state'
}

$tests['install lock held by Windows Update: waits, installs nothing'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'))
    $c = New-AppTestConfig $script:Sim.Packages
    $held = Enter-WdbInstallLock $c.dataRoot 'WindowsUpdate' 0
    try {
        Assert-Equal (Invoke-WdaMain $c) 'WaitingForLock' 'waits'
        Assert-Equal $script:Sim.Packages[0].InstallCalls 0 'nothing installed'
        Assert-True ((Get-WdbInstallLockOwner $c.dataRoot) -match 'WindowsUpdate') 'owner readable'
    } finally { Exit-WdbInstallLock $held }
    Assert-Equal (Invoke-WdaMain $c) 'Finished:Succeeded' 'continues when free'
}

$tests['a restart scheduled by Windows Update stops installation until after it'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'))
    $c = New-AppTestConfig $script:Sim.Packages
    Set-WdbRestartPending $c.dataRoot 'WindowsUpdate' 'test'
    Assert-Equal (Invoke-WdaMain $c) 'WaitingForRestart' 'waits for the restart'
    Assert-Equal $script:Sim.Packages[0].InstallCalls 0 'nothing installed'
    $script:Sim.Boots++
    Assert-Equal (Invoke-WdaMain $c) 'Finished:Succeeded' 'continues after the restart'
}

$tests['the lock is held during every installation'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'))
    $c = New-AppTestConfig $script:Sim.Packages
    $script:LockFreeDuringInstall = $null
    function Install-WdaPackage {
        param([hashtable] $P, [int] $TimeoutMinutes, [string] $LogFile = '')
        $other = Enter-WdbInstallLock $c.dataRoot 'WindowsUpdate' 0
        $script:LockFreeDuringInstall = [bool] $other
        Exit-WdbInstallLock $other
        (Get-SimPackage $P).Installed = $true
        @{ ExitCode = 0; TimedOut = $false; Output = '' }
    }
    Assert-Equal (Invoke-WdaMain $c) 'Finished:Succeeded' 'outcome'
    Assert-True (-not $script:LockFreeDuringInstall) 'Windows Update could not take the lock mid-install'
}

$tests['pending Windows restart before installing: restart once, then install'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'))
    $script:Sim.RebootPending = $true
    $c = New-AppTestConfig $script:Sim.Packages
    $o = Invoke-Logons $c
    Assert-Equal ($o -join ',') 'Rebooting,Finished:Succeeded' 'outcomes'
}

$tests['a pending restart that survives the restart does not loop'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'))
    function Test-WdaRebootPending { $true }
    $c = New-AppTestConfig $script:Sim.Packages
    $o = Invoke-Logons $c
    Assert-Equal ($o -join ',') 'Rebooting,Finished:Succeeded' 'one restart, then continue'
}

$tests['dependency failed: dependent package is Skipped'] = {
    Reset-Sim @((New-SimPackage 'Microsoft.WSL' 'hash'), (New-SimPackage 'Docker.DockerDesktop' -After @('winget:microsoft.wsl')))
    $c = New-AppTestConfig $script:Sim.Packages
    [void] (Invoke-Logons $c)
    $r = Get-Result $c
    Assert-Equal (Get-Pkg $r 'Docker.DockerDesktop').status 'Skipped' 'skipped'
    Assert-Equal $script:Sim.Packages[1].InstallCalls 0 'not attempted'
}

$tests['unresolved and invalid entries are Unavailable and never reach WinGet'] = {
    $evil = New-SimPackage 'Foo.Bar;calc'
    Reset-Sim @($evil, (New-SimPackage 'Git.Git'))
    $c = New-AppTestConfig $script:Sim.Packages -Unresolved @(@{ key = 'custom:x.y'; packageIdentifier = 'X.Y'; source = 'contoso'; displayName = 'Custom'; reason = 'Source not supported' })
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:CompletedWithFailures' 'outcome'
    $r = Get-Result $c
    Assert-Equal (Get-Pkg $r 'Foo.Bar;calc').status 'Unavailable' 'invalid id'
    Assert-Equal (Get-Pkg $r 'X.Y').status 'Unavailable' 'unresolved'
    Assert-Equal $evil.InstallCalls 0 'never installed'
    Assert-Equal $evil.ShowCalls 0 'never queried'
}


# ------------------------------------------------------------------------------------------------
# Phase 4.2 (engine 1.1.0): portable, Store, manual, deselected, dependencies
# ------------------------------------------------------------------------------------------------

function New-PortableRufus { New-SimPackage 'Rufus.Rufus' -Method 'portable' -Portable @{ executable = 'rufus*.exe'; shortcut = 'Rufus' } }

$tests['portable: machine scope, Start menu shortcut to the versioned file, nothing run'] = {
    $rufus = New-PortableRufus
    $rufus.PortableFiles = @('rufus-4.15.exe')
    Reset-Sim @($rufus)
    $c = New-AppTestConfig $script:Sim.Packages
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'outcome'
    Assert-True (($rufus.Args -join ' ') -match '--scope machine') 'installed machine-wide'
    $lnk = Join-Path $script:Sim.ShortcutFolder 'Rufus.lnk'
    Assert-True $script:Sim.Shortcuts.ContainsKey($lnk) 'shortcut created'
    Assert-True ($script:Sim.Shortcuts[$lnk] -like '*\Rufus.Rufus_Microsoft.Winget.Source_8wekyb3d8bbwe\rufus-4.15.exe') 'points at the installed file'
    Assert-Equal $script:Sim.Executed.Count 0 'the tool itself is never executed'
    Assert-True ((Get-Pkg (Get-Result $c) 'Rufus.Rufus').message -match 'Start menu shortcut') 'recorded in the result'
}

$tests['portable: already installed keeps the package and repairs the shortcut; repeating creates no duplicate'] = {
    $rufus = New-PortableRufus
    $rufus.Installed = $true
    Reset-Sim @($rufus)
    New-SimPortableFiles $rufus @('rufus.exe')
    $c = New-AppTestConfig $script:Sim.Packages
    [void] (Invoke-Logons $c)
    Assert-Equal (Get-Pkg (Get-Result $c) 'Rufus.Rufus').status 'AlreadyInstalled' 'status'
    Assert-Equal $rufus.InstallCalls 0 'not reinstalled'
    $c2 = New-AppTestConfig $script:Sim.Packages
    [void] (Invoke-Logons $c2)
    Assert-Equal @(Get-ChildItem -LiteralPath $script:Sim.ShortcutFolder -Filter '*.lnk').Count 1 'one shortcut after two runs'
}

$tests['portable: Ventoy picks the top-level executable (shortest path), never one in a subfolder first'] = {
    $v = New-SimPackage 'Ventoy.Ventoy' -Method 'portable' -Portable @{ executable = 'Ventoy2Disk.exe'; shortcut = 'Ventoy2Disk' }
    $v.PortableFiles = @('ventoy-1.1.17\altexe\Ventoy2Disk.exe', 'ventoy-1.1.17\Ventoy2Disk.exe')
    Reset-Sim @($v)
    $c = New-AppTestConfig $script:Sim.Packages
    [void] (Invoke-Logons $c)
    $target = $script:Sim.Shortcuts[(Join-Path $script:Sim.ShortcutFolder 'Ventoy2Disk.lnk')]
    Assert-True ($target -like '*\ventoy-1.1.17\Ventoy2Disk.exe') "top-level file chosen ($target)"
}

$tests['portable: missing executable is reported as a follow-up, the package stays installed'] = {
    $rufus = New-PortableRufus
    $rufus.PortableFiles = @('readme.txt')
    Reset-Sim @($rufus)
    $c = New-AppTestConfig $script:Sim.Packages
    [void] (Invoke-Logons $c)
    $r = Get-Result $c
    Assert-Equal (Get-Pkg $r 'Rufus.Rufus').status 'Succeeded' 'installed'
    Assert-True ((Get-Pkg $r 'Rufus.Rufus').message -match 'shortcut not created') 'reason recorded'
    Assert-True (($r.followUp -join ' ') -match 'Rufus.Rufus \[shortcut\]') 'listed for follow-up'
    Assert-Equal $script:Sim.Shortcuts.Count 0 'no shortcut'
}

$tests['portable: links and junctions are never followed; a shortcut cannot point outside the package folder'] = {
    $rufus = New-PortableRufus
    $rufus.PortableFiles = @('readme.txt')
    Reset-Sim @($rufus)
    $outside = Join-Path ([IO.Path]::GetTempPath()) ("wda-test-outside-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $outside -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $outside 'rufus.exe'), 'MZ')
    $c = New-AppTestConfig $script:Sim.Packages
    New-SimPortableFiles $rufus @('readme.txt')
    $pkgDir = Join-Path $script:Sim.PortableRoot 'Rufus.Rufus_Microsoft.Winget.Source_8wekyb3d8bbwe'
    cmd /c mklink /J "$(Join-Path $pkgDir 'link')" "$outside" | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $pkgDir 'link\rufus.exe')) 'junction exists for the test'
    [void] (Invoke-Logons $c)
    Assert-Equal $script:Sim.Shortcuts.Count 0 'file behind the junction ignored'
    Assert-Equal (Find-WdaPortableExe @($script:Sim.PortableRoot) 'Rufus.Rufus' 'rufus*.exe') $null 'finder returns nothing'
    [IO.Directory]::Delete((Join-Path $pkgDir 'link'))
    Remove-Item -LiteralPath $outside -Recurse -Force
}

$tests['portable: unsafe patterns, names or scopes are rejected before WinGet is called'] = {
    $bad = @(
        @{ executable = '..\..\Windows\System32\cmd.exe'; shortcut = 'X' },
        @{ executable = 'C:\x.exe'; shortcut = 'X' },
        @{ executable = 'rufus.exe'; shortcut = '..\..\Startup\evil' },
        @{ executable = 'rufus.exe" & calc'; shortcut = 'X' }
    )
    foreach ($p in $bad) {
        $s = New-SimPackage 'Rufus.Rufus' -Method 'portable' -Portable $p
        Reset-Sim @($s)
        $c = New-AppTestConfig $script:Sim.Packages
        [void] (Invoke-Logons $c)
        Assert-Equal (Get-Pkg (Get-Result $c) 'Rufus.Rufus').status 'Unavailable' "rejected: $($p.executable) / $($p.shortcut)"
        Assert-Equal $s.InstallCalls 0 'never installed'
    }
    Assert-Equal (Find-WdaPortableExe @('C:\') 'Rufus.Rufus' '..\cmd.exe') $null 'finder refuses a path pattern'
    $s = New-SimPackage 'Rufus.Rufus' -Method 'portable' -Portable @{ executable = 'rufus.exe'; shortcut = 'Rufus' }
    Reset-Sim @($s)
    $c = New-AppTestConfig $script:Sim.Packages
    $c.packages[0].scope = 'user'
    $q = Get-WdaQueue $c
    Assert-True ((Test-WdaPackageSpec $q[0]) -match 'machine scope') 'user scope refused for portable'
}

$tests['mixed plan: WinGet, Microsoft Store and portable packages each use their own source'] = {
    $rufus = New-PortableRufus
    $rufus.PortableFiles = @('rufus.exe')
    $store = New-SimPackage '9NP83LWLPZ9K' -Source msstore -Method 'msstore'
    Reset-Sim @((New-SimPackage 'Google.Chrome'), $store, $rufus)
    $c = New-AppTestConfig $script:Sim.Packages
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'outcome'
    Assert-Equal ($script:Sim.Order -join ',') 'Google.Chrome,9NP83LWLPZ9K,Rufus.Rufus' 'order'
    Assert-Equal ($store.Args -join ' ') 'install --id 9NP83LWLPZ9K --exact --source msstore --silent --no-upgrade --accept-package-agreements --accept-source-agreements --disable-interactivity' 'Store command'
    Assert-Equal ($script:Sim.Packages[0].Args -join ' ') 'install --id Google.Chrome --exact --source winget --silent --no-upgrade --accept-package-agreements --accept-source-agreements --disable-interactivity' 'WinGet command unchanged'
}

$tests['manual follow-ups and deselected apps are recorded, never installed, and do not hide real results'] = {
    Reset-Sim @((New-SimPackage 'Google.Chrome'))
    $manual = @(
        @{ key = 'catalog:rustdesk'; displayName = 'RustDesk'; instructions = 'Download the signed installer.'; url = 'https://github.com/rustdesk/rustdesk/releases/latest' },
        @{ key = 'catalog:evil'; displayName = 'Evil'; instructions = 'x'; url = 'https://x.example/" & calc' },
        @{ key = '..\bad'; displayName = 'Bad key'; instructions = 'x'; url = '' }
    )
    $deselected = @(@{ key = 'winget:epicgames.epicgameslauncher'; packageIdentifier = 'EpicGames.EpicGamesLauncher'; source = 'winget'; displayName = 'Epic Games Launcher' })
    $c = New-AppTestConfig $script:Sim.Packages -Overrides @{ manual = $manual; deselected = $deselected }
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:CompletedWithFollowUp' 'manual items make it a follow-up, not a success'
    $r = Get-Result $c
    $rd = Get-Pkg $r 'rustdesk'
    Assert-Equal $rd.status 'RequiresInteraction' 'manual status'
    Assert-True ($rd.message -match '^Manual action required: Download the signed installer\. \(https://github\.com/rustdesk') 'instructions and URL'
    Assert-True ((Get-Pkg $r 'evil').message -notmatch 'calc') 'unsafe URL dropped'
    Assert-Equal @($r.packages | Where-Object { $_.name -eq 'Bad key' }).Count 0 'invalid key ignored'
    Assert-Equal (Get-Pkg $r 'EpicGames.EpicGamesLauncher').status 'SkippedByUser' 'deselected'
    Assert-Equal $r.counts.skippedByUser 1 'counted'
    Assert-Equal (Get-Pkg $r 'Google.Chrome').status 'Succeeded' 'real package installed'
    Assert-Equal ($script:Sim.Order -join ',') 'Google.Chrome' 'only the real package reached WinGet'
    Assert-True (($r.followUp -join ' ') -match 'RustDesk') 'manual in follow-up'
    Assert-True (($r.followUp -join ' ') -notmatch 'Epic') 'deselected is not a follow-up'
}

$tests['deselected only: Succeeded (a customer choice is not a failure)'] = {
    Reset-Sim @((New-SimPackage 'Valve.Steam'))
    $c = New-AppTestConfig $script:Sim.Packages -Overrides @{ deselected = @(@{ key = 'winget:epicgames.epicgameslauncher'; packageIdentifier = 'EpicGames.EpicGamesLauncher'; source = 'winget'; displayName = 'Epic' }) }
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'outcome'
}

$tests['dependencies: a required runtime installs first; an already installed one is not reinstalled'] = {
    Reset-Sim @((New-SimPackage 'Docker.DockerDesktop' -After @('winget:microsoft.wsl')), (New-SimPackage 'Microsoft.WSL'))
    $c = New-AppTestConfig $script:Sim.Packages
    [void] (Invoke-Logons $c)
    Assert-Equal ($script:Sim.Order -join ',') 'Microsoft.WSL,Docker.DockerDesktop' 'dependency first even when listed later'
    Reset-Sim @((New-SimPackage 'Microsoft.VCRedist.2015+.x64' 'installed'), (New-SimPackage 'HandBrake.HandBrake' -After @('winget:microsoft.vcredist.2015+.x64')))
    $c = New-AppTestConfig $script:Sim.Packages
    [void] (Invoke-Logons $c)
    $r = Get-Result $c
    Assert-Equal (Get-Pkg $r 'Microsoft.VCRedist.2015+.x64').status 'AlreadyInstalled' 'compatible runtime detected by winget list'
    Assert-Equal $script:Sim.Packages[0].InstallCalls 0 'not reinstalled'
    Assert-Equal (Get-Pkg $r 'HandBrake.HandBrake').status 'Succeeded' 'dependent installed'
}

$tests['a 1.0.0-format configuration (no method, manual or deselected keys) still runs unchanged'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'))
    $c = New-AppTestConfig $script:Sim.Packages
    $raw = Get-Content -LiteralPath (Join-Path $c.configDirectory 'applications-config.json') -Raw | ConvertFrom-Json
    Assert-True (-not ($raw.PSObject.Properties.Name -contains 'manual')) 'fixture has no 1.1.0 keys'
    Assert-True (-not ($raw.packages[0].PSObject.Properties.Name -contains 'method')) 'no method key'
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'outcome'
}

$tests['Plan mode lists portable, manual and deselected entries without installing'] = {
    $rufus = New-PortableRufus
    Reset-Sim @($rufus)
    $c = New-AppTestConfig $script:Sim.Packages -Overrides @{ manual = @(@{ key = 'catalog:filezilla'; displayName = 'FileZilla'; instructions = 'Download it.'; url = '' }); deselected = @(@{ key = 'winget:valve.steam'; packageIdentifier = 'Valve.Steam'; source = 'winget'; displayName = 'Steam' }) }
    $plan = Invoke-WdaPlan $c
    $actions = ($plan.Rows | ForEach-Object { "$($_.Name)=$($_.Action)" }) -join '; '
    Assert-True ($actions -match 'Install \(portable\) \+ shortcut Rufus') "portable ($actions)"
    Assert-True ($actions -match 'FileZilla=Manual action required') 'manual'
    Assert-True ($actions -match 'Steam=SkippedByUser') 'deselected'
    Assert-Equal $rufus.InstallCalls 0 'nothing installed'
}

$tests['Invoke-WdaWinGet refuses unsafe argument tokens'] = {
    $script:WinGet = 'C:\nonexistent\winget.exe'
    foreach ($bad in @('Foo.Bar;calc', 'a b', '"x"', '$(calc)', '--id=x&y', 'x|y')) {
        $threw = $false
        try { [void] (Invoke-WdaWinGet @('install', '--id', $bad)) } catch { $threw = $_.Exception.Message -match 'unsafe' }
        Assert-True $threw "refused '$bad'"
    }
}

$tests['packages only in the native WinGet list are installed too'] = {
    $extra = New-SimPackage 'Extra.Tool'
    Reset-Sim @((New-SimPackage 'Git.Git'), $extra)
    $c = New-AppTestConfig @($script:Sim.Packages[0]) -NativeOnly @($extra)
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'outcome'
    Assert-Equal $extra.InstallCalls 1 'native-only package installed'
}

$tests['Additional Software: manual entries become follow-up; automatic needs hash and signature'] = {
    Reset-Sim @()
    $manual = @{ id = 'm1'; name = 'Manual Tool'; downloadUrl = 'https://example.org/dl'; execution = 'manual'; fileName = ''; sha256 = ''; silentArgs = @(); installerType = 'exe' }
    $badHash = @{ id = 'a1'; name = 'Reviewed A'; execution = 'automatic'; fileName = 'a.exe'; sha256 = ('A' * 64); silentArgs = @('/S'); installerType = 'exe' }
    $good = @{ id = 'a2'; name = 'Reviewed B'; execution = 'automatic'; fileName = 'b.msi'; sha256 = ('B' * 64); silentArgs = @('/qn', 'ALLUSERS=1'); installerType = 'msi' }
    $c = New-AppTestConfig @() -Additional @($manual, $badHash, $good)
    $inst = Join-Path $c.dataRoot 'Applications\installers'
    New-Item -ItemType Directory -Path $inst -Force | Out-Null
    foreach ($f in 'a.exe', 'b.msi') { Set-Content -LiteralPath (Join-Path $inst $f) -Value 'x' }
    $script:Sim.Hashes = @{ 'a.exe' = ('C' * 64); 'b.msi' = ('B' * 64) }
    $o = Invoke-Logons $c
    $r = Get-Result $c
    $byId = @{}; foreach ($a in $r.additionalSoftware) { $byId[$a.id] = $a }
    Assert-Equal $byId['m1'].status 'RequiresInteraction' 'manual'
    Assert-True ($byId['m1'].message -match 'example.org') 'follow-up names the official source'
    Assert-Equal $byId['a1'].status 'Failed' 'hash mismatch'
    Assert-Equal $byId['a2'].status 'Succeeded' 'reviewed installer ran'
    Assert-Equal $script:Sim.Executed.Count 1 'only the verified installer was executed'
    Assert-Equal ($script:Sim.Executed[0][1] -join ' ') '/qn ALLUSERS=1' 'arguments passed as a list'
    Assert-Equal $o[-1] 'Finished:CompletedWithFailures' 'outcome'
}

$tests['finished run does nothing on later starts'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'))
    $c = New-AppTestConfig $script:Sim.Packages
    [void] (Invoke-WdaMain $c)
    $script:Sim.TaskRemoved = $false
    Assert-Equal (Invoke-WdaMain $c) 'AlreadyFinished' 'second start'
    Assert-Equal $script:Sim.Packages[0].InstallCalls 1 'idempotent'
    Assert-True $script:Sim.TaskRemoved 'task removal retried'
}

$tests['corrupt state file is kept aside and the run continues'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'))
    $c = New-AppTestConfig $script:Sim.Packages
    $dir = Join-Path $c.dataRoot 'Applications'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'state.json') -Value '{ broken'
    Assert-Equal (Invoke-WdaMain $c) 'Finished:Succeeded' 'outcome'
    Assert-True (Test-Path -LiteralPath (Join-Path $dir 'state.json.corrupt')) 'corrupt copy kept'
}

$tests['only one application engine instance runs at a time'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'))
    $c = New-AppTestConfig $script:Sim.Packages
    $job = Start-MutexHolder $c.mutexName
    try {
        Assert-Equal (Invoke-WdaMain $c) 'AlreadyRunning' 'second instance exits'
        Assert-Equal $script:Sim.Packages[0].InstallCalls 0 'nothing installed'
    } finally {
        $job | Stop-Job -PassThru | Remove-Job -Force
    }
}

$tests['exit code mapping'] = {
    Assert-Equal (ConvertFrom-WdaExitCode 0).Status 'Succeeded' 'S_OK'
    Assert-Equal (ConvertFrom-WdaExitCode -1978335135).Status 'AlreadyInstalled' '0x8A150061'
    Assert-Equal (ConvertFrom-WdaExitCode 0x8A15002B).Status 'AlreadyInstalled' 'UPDATE_NOT_APPLICABLE'
    $r = ConvertFrom-WdaExitCode 0x8A150109
    Assert-Equal "$($r.Status)/$($r.Restart)" 'RequiresRestart/later' 'reboot to finish'
    Assert-Equal (ConvertFrom-WdaExitCode 3010).Status 'RequiresRestart' 'MSI 3010'
    $u = ConvertFrom-WdaExitCode 0x12345678
    Assert-True ($u.Status -eq 'Failed' -and $u.Retry) 'unknown codes are retryable failures'
}

$tests['log records progress and failures'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'), (New-SimPackage 'Bad.Pkg' 'fail'))
    $c = New-AppTestConfig $script:Sim.Packages
    [void] (Invoke-Logons $c)
    $log = Get-Content -LiteralPath (Join-Path $c.dataRoot 'Applications\logs\engine.log') -Raw
    foreach ($needle in 'installing App Git.Git (winget:Git.Git) attempt 1/2', '-> Succeeded App Git.Git', '-> Failed App Bad.Pkg [0x8A150008]', 'FINISHED: CompletedWithFailures', 'WinGet: WinGet 1.29.250 works') {
        Assert-True ($log.Contains($needle)) "log contains '$needle'"
    }
}

# ------------------------------------------------------------------------------------------------
# Phase 5: resilience, fault injection and technician recovery
# ------------------------------------------------------------------------------------------------

function Get-StateFile { param([hashtable] $Config) Join-Path $Config.dataRoot 'Applications\state.json' }
function Get-Attempts { param([hashtable] $Config) @(Get-Content -LiteralPath (Join-Path $Config.dataRoot 'Applications\logs\attempts.jsonl') | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) }

$tests['retry policy: bounded exponential backoff with jitter, never above the maximum'] = {
    Reset-Sim
    $c = New-AppTestConfig @() -Overrides @{ maxAttemptsPerPackage = 3 }
    $pol = Get-WdaRetryPolicy $c
    Assert-Equal "$($pol.automatic) $($pol.maxAttempts) $($pol.baseDelaySeconds) $($pol.maxDelaySeconds) $($pol.jitterRatio) $($pol.maxNetworkDeferrals)" 'True 3 60 900 0.2 6' 'defaults for a configuration without a retry block'
    $script:Sim.Random = 0.5
    Assert-Equal ((1..6 | ForEach-Object { Get-WdaBackoffSeconds $pol $_ }) -join ',') '60,120,240,480,900,900' 'doubling, capped'
    $script:Sim.Random = 0.0
    Assert-Equal (Get-WdaBackoffSeconds $pol 1) 48 'jitter -20%'
    $script:Sim.Random = 0.9999
    Assert-Equal (Get-WdaBackoffSeconds $pol 1) 72 'jitter +20%'
    Assert-Equal (Get-WdaBackoffSeconds $pol 5) 900 'jitter never exceeds the maximum delay'
    $wild = New-AppTestConfig @() -Overrides @{ maxAttemptsPerPackage = 99; retry = @{ baseDelaySeconds = 99999; maxDelaySeconds = -5; jitterRatio = 7; maxNetworkDeferrals = 500 } }
    $w = Get-WdaRetryPolicy $wild
    Assert-Equal "$($w.maxAttempts) $($w.baseDelaySeconds) $($w.maxDelaySeconds) $($w.jitterRatio) $($w.maxNetworkDeferrals)" '10 3600 3600 0.5 24' 'out-of-range configuration values are clamped (no unbounded retry)'
    Assert-Equal (Get-WdaRetryPolicy (New-AppTestConfig @() -Overrides @{ retry = @{ automatic = $false } })).maxAttempts 1 'automatic retry off: one attempt per run'
}

$tests['transient failures: waits 60 s then 120 s (backoff) and succeeds on the third attempt'] = {
    Reset-Sim @((New-SimPackage 'Vendor.Flaky' 'fail-twice'))
    $c = New-AppTestConfig $script:Sim.Packages -Overrides @{ maxAttemptsPerPackage = 3 }
    $o = Invoke-Logons $c
    Assert-Equal ($o -join ',') 'Finished:Succeeded' 'one run, no extra restart'
    Assert-Equal ($script:Sim.Waits -join ',') '60,120' 'backoff waits'
    $p = Get-Pkg (Get-Result $c) 'Vendor.Flaky'
    Assert-Equal "$($p.status) $($p.attempts) $($p.lifecycle) $($p.detection)" 'Succeeded 3 Succeeded Installed' 'result'
    Assert-Equal @($p.history).Count 3 'every attempt in the history'
    $a = Get-Attempts $c
    Assert-Equal (($a | ForEach-Object { "$($_.attempt):$($_.result):$($_.class)" }) -join ' ') '1:Failed:Network 2:Failed:Network 3:Succeeded:Success' 'attempts.jsonl'
    Assert-Equal $a[0].nextAction 'retry after 60 s' 'next scheduled action recorded'
    Assert-Equal $a[0].operationId 'app:winget:vendor.flaky' 'stable operation id'
}

$tests['exhausted retry budget: FailedRetryable, outstanding, exactly maxAttempts installs'] = {
    Reset-Sim @((New-SimPackage 'Vendor.Down' 'fail'), (New-SimPackage 'Git.Git'))
    $c = New-AppTestConfig $script:Sim.Packages -Overrides @{ maxAttemptsPerPackage = 3 }
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:CompletedWithFailures' 'outcome'
    $r = Get-Result $c
    $p = Get-Pkg $r 'Vendor.Down'
    Assert-Equal "$($p.status) $($p.lifecycle) $($p.failureClass) $($p.retryable) $($p.attempts)" 'Failed FailedRetryable Network True 3' 'classification'
    Assert-Equal $script:Sim.Packages[0].InstallCalls 3 'no more than the budget'
    Assert-Equal ((@($r.outstanding) | ForEach-Object { $_.operationId }) -join ',') 'app:winget:vendor.down' 'outstanding work recorded'
    Assert-Equal $r.schemaVersion 2 'result schema 2'
    Assert-True ($r.reason -match 'recovery tool') 'reason points to recovery'
    Save-Result $c 'phase5-exhausted'
}

$tests['permanent failures are never retried automatically (integrity, policy, cancelled, not found)'] = {
    Reset-Sim @((New-SimPackage 'Vendor.Hash' 'hash'), (New-SimPackage 'Vendor.Cancel' 'cancel'), (New-SimPackage 'Vendor.Gone' 'notfound'))
    $c = New-AppTestConfig $script:Sim.Packages -Overrides @{ maxAttemptsPerPackage = 3 }
    [void] (Invoke-Logons $c)
    $r = Get-Result $c
    Assert-Equal "$((Get-Pkg $r 'Vendor.Hash').lifecycle) $((Get-Pkg $r 'Vendor.Hash').failureClass)" 'FailedPermanent Integrity' 'hash mismatch'
    Assert-Equal $script:Sim.Packages[0].InstallCalls 1 'hash mismatch: one attempt only'
    Assert-Equal "$((Get-Pkg $r 'Vendor.Cancel').lifecycle) $((Get-Pkg $r 'Vendor.Cancel').failureClass)" 'ManualActionRequired User' 'user cancellation'
    Assert-Equal $script:Sim.Packages[1].InstallCalls 1 'cancellation: one attempt only'
    Assert-Equal (Get-Pkg $r 'Vendor.Gone').lifecycle 'FailedPermanent' 'not in the source'
    Assert-Equal $script:Sim.Packages[2].InstallCalls 0 'never attempted'
    Assert-Equal @($script:Sim.Waits | Where-Object { $_ -ge 30 }).Count 0 'no backoff wait for permanent failures'
}

$tests['portable download integrity failure: not retried, no shortcut, permanent'] = {
    $pkg = New-SimPackage 'Rufus.Rufus' 'hash' -Method portable -Portable @{ executable = 'rufus*.exe'; shortcut = 'Rufus' }
    Reset-Sim @($pkg)
    $c = New-AppTestConfig $script:Sim.Packages -Overrides @{ maxAttemptsPerPackage = 3 }
    [void] (Invoke-Logons $c)
    $p = Get-Pkg (Get-Result $c) 'Rufus.Rufus'
    Assert-Equal "$($p.status) $($p.lifecycle) $($p.exitCode)" 'Failed FailedPermanent 0x8A150011' 'integrity'
    Assert-Equal $pkg.InstallCalls 1 'one attempt'
    Assert-Equal $script:Sim.Shortcuts.Count 0 'no shortcut to a file that failed verification'
}

$tests['unknown exit code, installer timeout and package lock contention are retried within the budget'] = {
    Reset-Sim @((New-SimPackage 'Vendor.Odd' 'unknown-once'), (New-SimPackage 'Vendor.Slow' 'timeout-once'), (New-SimPackage 'Vendor.Busy' 'locked-once'))
    $c = New-AppTestConfig $script:Sim.Packages
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'all three succeed on retry'
    $a = Get-Attempts $c
    Assert-Equal (($a | Where-Object { $_.result -ne 'Succeeded' } | ForEach-Object { "$($_.name)=$($_.class)" }) -join ' ') 'App Vendor.Odd=Unknown App Vendor.Slow=Timeout App Vendor.Busy=Transient' 'classes'
    Assert-Equal ($a | Where-Object { $_.class -eq 'Unknown' }).exitCode '0x80070005' 'unknown code kept'
}

$tests['network lost mid-run: progress kept, nothing failed, resumes when the network is back'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'), (New-SimPackage 'Vendor.Download' 'net-drop'), (New-SimPackage '7zip.7zip'))
    $c = New-AppTestConfig $script:Sim.Packages
    $first = Invoke-WdaMain $c
    Assert-Equal $first 'WaitingForNetwork' 'run stops waiting for the network'
    $st = Read-WdaJson (Get-StateFile $c)
    Assert-Equal $st.packages['winget:git.git'].status 'Succeeded' 'finished work kept'
    $d = $st.packages['winget:vendor.download']
    Assert-Equal "$($d.status) $($d.attempts) $($d.waitingFor) $($d.networkDeferrals)" 'Pending 0 network 1' 'deferred, attempt not held against it'
    Assert-Equal (Get-WdaLifecycle $d) 'WaitingForNetwork' 'lifecycle'
    Assert-Equal $st.packages['winget:7zip.7zip'].status 'Pending' 'others not marked failed'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $c.dataRoot 'Applications\result.json'))) 'not final'
    $script:Sim.Now = $script:Sim.Now.AddHours(1)
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'resumed and finished'
    Assert-Equal $script:Sim.Packages[0].InstallCalls 1 'Git not reinstalled'
    $p = Get-Pkg (Get-Result $c) 'Vendor.Download'
    Assert-Equal "$($p.attempts) $($p.totalAttempts)" '1 2' 'only the real attempt counts toward the limit'
    Assert-True (@($p.history | Where-Object { $_.countsTowardLimit -eq $false }).Count -eq 1) 'deferral recorded in the history'
}

$tests['Microsoft Store source unavailable: WinGet packages continue, the Store package waits'] = {
    Reset-Sim @((New-SimPackage '9NBLGGH4NNS1' 'store-down' -Source msstore), (New-SimPackage 'Git.Git'), (New-SimPackage '7zip.7zip'))
    $script:Sim.SourceDown = @('msstore')
    $c = New-AppTestConfig $script:Sim.Packages
    Assert-Equal (Invoke-WdaMain $c) 'WaitingForNetwork' 'waits for the source'
    $st = Read-WdaJson (Get-StateFile $c)
    Assert-Equal "$($st.packages['winget:git.git'].status) $($st.packages['winget:7zip.7zip'].status)" 'Succeeded Succeeded' 'other source continued'
    Assert-Equal $st.packages['msstore:9nblggh4nns1'].waitingFor 'source:msstore' 'waiting for that source'
    $script:Sim.SourceDown = @()
    $script:Sim.Now = $script:Sim.Now.AddHours(1)
    Assert-Equal (Invoke-WdaMain $c) 'Finished:Succeeded' 'installs when the source is back'
}

$tests['source never returns: deferrals are bounded, then Failed (retryable), no loop'] = {
    Reset-Sim @((New-SimPackage '9NBLGGH4NNS1' 'store-down' -Source msstore), (New-SimPackage 'Git.Git'))
    $script:Sim.SourceDown = @('msstore')
    $c = New-AppTestConfig $script:Sim.Packages -Overrides @{ retry = @{ maxNetworkDeferrals = 2 } }
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:CompletedWithFailures' 'ends'
    Assert-True ($o.Count -le 6) "bounded number of runs ($($o.Count))"
    $p = Get-Pkg (Get-Result $c) '9NBLGGH4NNS1'
    Assert-Equal "$($p.status) $($p.lifecycle) $($p.failureClass)" 'Failed FailedRetryable Network' 'retryable by a technician'
}

$tests['interrupted installer that finished anyway: confirmed, not reinstalled'] = {
    Reset-Sim @((New-SimPackage 'Vendor.Partial' 'fail-but-installed'))
    $c = New-AppTestConfig $script:Sim.Packages
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'outcome'
    Assert-Equal $script:Sim.Packages[0].InstallCalls 1 'winget list found it before a second attempt'
    Assert-Equal (Get-Pkg (Get-Result $c) 'Vendor.Partial').detection 'Installed' 'detection'
}

$tests['successful exit code without the application: Unconfirmed, follow-up, never a silent success'] = {
    Reset-Sim @((New-SimPackage 'Vendor.Ghost' 'false-success'))
    $c = New-AppTestConfig $script:Sim.Packages
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:CompletedWithFollowUp' 'follow-up'
    $r = Get-Result $c
    Assert-Equal (Get-Pkg $r 'Vendor.Ghost').detection 'Unconfirmed' 'detection'
    Assert-True (@($r.followUp | Where-Object { $_ -match 'unconfirmed' }).Count -eq 1) 'listed'
}

$tests['power loss with operations left Running: reconciled with winget list, never stuck'] = {
    Reset-Sim @((New-SimPackage 'Vendor.Done' 'installed'), (New-SimPackage 'Vendor.Notyet'))
    $c = New-AppTestConfig $script:Sim.Packages
    [void] (Invoke-WdaMain $c)
    # Rewind to a state written just before both installers finished (both left "Installing").
    Reset-Sim @((New-SimPackage 'Vendor.Done' 'installed'), (New-SimPackage 'Vendor.Notyet'))
    $st = Read-WdaJson (Get-StateFile $c)
    foreach ($k in 'winget:vendor.done', 'winget:vendor.notyet') { $st.packages[$k].status = 'Installing'; $st.packages[$k].attempts = 1 }
    $st.final = $null
    Write-WdaJson (Get-StateFile $c) $st
    Remove-Item -LiteralPath (Join-Path $c.dataRoot 'Applications\result.json')
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'outcome'
    $r = Get-Result $c
    Assert-Equal (Get-Pkg $r 'Vendor.Done').status 'Succeeded' 'installed one confirmed'
    Assert-Equal $script:Sim.Packages[0].InstallCalls 0 'and not reinstalled'
    Assert-Equal $script:Sim.Packages[1].InstallCalls 1 'missing one installed once'
    Assert-Equal (Get-Pkg $r 'Vendor.Notyet').attempts 2 'interrupted attempt still counted'
    Assert-True (@((Get-Pkg $r 'Vendor.Done').history | Where-Object { $_.result -eq 'Interrupted' }).Count -eq 1) 'interruption recorded'
}

$tests['state writes are atomic: the last good copy is kept and used when the state is damaged'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'), (New-SimPackage 'Vendor.Later' 'fail'))
    $c = New-AppTestConfig $script:Sim.Packages -Overrides @{ maxAttemptsPerPackage = 1 }
    [void] (Invoke-WdaMain $c)
    $file = Get-StateFile $c
    Assert-True (Test-Path -LiteralPath "$file.bak") 'backup written by every save'
    Assert-True (-not (Test-Path -LiteralPath "$file.tmp")) 'no temporary file left behind'
    # Reopen the finished run, then damage the state as a power loss mid-write would (truncated).
    # Git.Git is "not installed" in the simulation now, so a state rebuilt from scratch would
    # install it again: only the backup can keep the completed operation.
    $st = Read-WdaJson $file; $st.final = $null; Write-WdaJson $file $st -Backup; Write-WdaJson $file $st -Backup
    Remove-Item -LiteralPath (Join-Path $c.dataRoot 'Applications\result.json')
    [IO.File]::WriteAllText($file, '{"version":2,"packages":{"winget:git.git":{"key":"winget:git.')
    $script:Sim.Packages[0].Installed = $false
    $script:Sim.Packages[0].InstallCalls = 0
    $o = Invoke-WdaMain $c
    Assert-Equal $o 'Finished:CompletedWithFailures' 'finishes'
    Assert-Equal $script:Sim.Packages[0].InstallCalls 0 'completed operation not repeated'
    $r = Get-Result $c
    Assert-Equal $r.stateRecoveredFrom 'backup' 'recovered from the backup'
    Assert-Equal (Get-Pkg $r 'Git.Git').status 'Succeeded' 'completed operation preserved'
    Assert-True (Test-Path -LiteralPath "$file.corrupt") 'damaged copy kept for diagnosis'
    Save-Result $c 'phase5-backup'
}

$tests['malformed or untrusted states are rejected, never trusted'] = {
    $bad = @(
        '{"version":99,"packages":{}}',
        '{"version":2,"packages":{"winget:git.git":{"key":"winget:other.pkg","status":"Succeeded","attempts":0}}}',
        '{"version":2,"packages":{"winget:git.git":{"key":"winget:git.git","status":"Hacked","attempts":0}}}',
        '{"version":2,"packages":{"winget:git.git":{"key":"winget:git.git","status":"Pending","attempts":"1; rm"}}}',
        '{"version":2,"packages":[1,2,3]}',
        '{"version":2,"final":"Pwned","packages":{}}'
    )
    foreach ($json in $bad) {
        Reset-Sim @((New-SimPackage 'Git.Git'))
        $c = New-AppTestConfig $script:Sim.Packages
        $dir = Join-Path $c.dataRoot 'Applications'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'state.json'), $json)
        Assert-True ($null -ne (Test-WdaStateShape (ConvertTo-WdaHashtable ($json | ConvertFrom-Json)))) "rejected: $json"
        Assert-Equal (Invoke-WdaMain $c) 'Finished:Succeeded' "fresh, verified run instead: $json"
        Assert-Equal (Get-Pkg (Get-Result $c) 'Git.Git').status 'Succeeded' 'the configuration decides what is installed'
    }
}

$tests['state version 1 (engine 1.0/1.1) is upgraded without reopening completed work'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'), (New-SimPackage 'Vendor.Old' 'fail'), (New-SimPackage '7zip.7zip'))
    $c = New-AppTestConfig $script:Sim.Packages
    $dir = Join-Path $c.dataRoot 'Applications'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $now = $script:Sim.Now.ToString('o')
    $v1 = @{ version = 1; firstStartUtc = $now; installStartUtc = $now; starts = 2; reboots = 0; errors = 0; offlineStarts = 0; everOnline = $true; prepared = $true; restartForPending = $false; bootstrap = $null; final = $null; additional = @{}
             packages = @{ 'winget:git.git' = @{ key = 'winget:git.git'; name = 'App Git.Git'; packageIdentifier = 'Git.Git'; source = 'winget'; status = 'Succeeded'; attempts = 1; exitCode = '0x00000000'; message = 'Installed.'; updatedUtc = $now; restart = ''; restartBoot = ''; interrupted = $false }
                           'winget:vendor.old' = @{ key = 'winget:vendor.old'; name = 'App Vendor.Old'; packageIdentifier = 'Vendor.Old'; source = 'winget'; status = 'Failed'; attempts = 2; exitCode = '0x8A150008'; message = 'Download failed.'; updatedUtc = $now; restart = ''; restartBoot = ''; interrupted = $false } } }
    [IO.File]::WriteAllText((Join-Path $dir 'state.json'), ($v1 | ConvertTo-Json -Depth 6))
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:CompletedWithFailures' 'outcome'
    Assert-Equal "$($script:Sim.Packages[0].InstallCalls) $($script:Sim.Packages[1].InstallCalls)" '0 0' 'Succeeded and Failed stay as they were (no reinstall, no silent retry)'
    Assert-Equal $script:Sim.Packages[2].InstallCalls 1 'unfinished work continues'
    $st = Read-WdaJson (Get-StateFile $c)
    Assert-Equal $st.version 2 'upgraded'
    Assert-Equal $st.packages['winget:vendor.old'].operationId 'app:winget:vendor.old' 'new fields added'
    Assert-Equal $st.packages['winget:git.git'].status 'Succeeded' 'status unchanged'
}

$tests['runtime limit: finished work kept, the rest Failed (Budget, retryable), never a blanket Failed'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'), (New-SimPackage 'Vendor.Slow' 'fail'), (New-SimPackage '7zip.7zip'))
    $c = New-AppTestConfig $script:Sim.Packages -Overrides @{ maxAttemptsPerPackage = 3; maxRuntimeHours = 1; retry = @{ baseDelaySeconds = 3600; maxDelaySeconds = 3600 } }
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:CompletedWithFailures' 'not a blanket Failed'
    $r = Get-Result $c
    Assert-Equal (Get-Pkg $r 'Git.Git').status 'Succeeded' 'kept'
    $p = Get-Pkg $r 'Vendor.Slow'
    Assert-Equal "$($p.status) $($p.failureClass) $($p.retryable)" 'Failed Budget True' 'budget class'
    Assert-True ($r.reason -match 'runtime limit') 'reason'
}

$tests['continue after a failure off: the queue stops, the rest stays outstanding, resume finishes it'] = {
    Reset-Sim @((New-SimPackage 'Vendor.Bad' 'hash'), (New-SimPackage 'Git.Git'), (New-SimPackage '7zip.7zip'))
    $c = New-AppTestConfig $script:Sim.Packages -Overrides @{ retry = @{ continueAfterFailure = $false } }
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:CompletedWithFailures' 'outcome'
    $r = Get-Result $c
    Assert-Equal "$((Get-Pkg $r 'Git.Git').status) $((Get-Pkg $r '7zip.7zip').status)" 'Pending Pending' 'not attempted'
    Assert-Equal @($r.outstanding).Count 3 'all three outstanding'
    $rr = Invoke-WdaRetry $c -PendingOnly -RequestedBy 'PC\Tech'
    Assert-Equal "$($rr.Outcome) $(@($rr.Accepted).Count)" 'Accepted 2' 'resume reopens the unfinished ones only'
    [void] (Invoke-Logons $c)
    $r = Get-Result $c
    Assert-Equal "$((Get-Pkg $r 'Git.Git').status) $((Get-Pkg $r '7zip.7zip').status) $((Get-Pkg $r 'Vendor.Bad').status)" 'Succeeded Succeeded Failed' 'resumed; the permanent failure is untouched'
    Assert-Equal $script:Sim.Packages[0].InstallCalls 1 'not retried'
}

$tests['automatic retry off: one attempt, then a technician retry succeeds'] = {
    Reset-Sim @((New-SimPackage 'Vendor.Once' 'fail-once'))
    $c = New-AppTestConfig $script:Sim.Packages -Overrides @{ retry = @{ automatic = $false } }
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:CompletedWithFailures' 'no automatic retry'
    Assert-Equal $script:Sim.Packages[0].InstallCalls 1 'one attempt'
    Assert-Equal (Get-Pkg (Get-Result $c) 'Vendor.Once').lifecycle 'FailedRetryable' 'retryable'
    Assert-Equal (Invoke-WdaRetry $c -AllFailed).Outcome 'Accepted' 'technician retry'
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'succeeds'
}

$tests['recovery: retry one failed application; successful ones are not repeated; history kept'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'), (New-SimPackage 'Vendor.Down' 'fail'), (New-SimPackage '7zip.7zip'))
    $c = New-AppTestConfig $script:Sim.Packages
    [void] (Invoke-Logons $c)
    Assert-True (Test-Marker $c) 'finished with failures'
    $script:Sim.Packages[1].Behavior = 'ok'     # the technician fixed the cause
    $r = Invoke-WdaRetry $c -Operations @('app:winget:vendor.down') -RequestedBy 'PC\Tech'
    Assert-Equal $r.Outcome 'Accepted' 'accepted'
    Assert-True (-not (Test-Marker $c)) 'marker removed while the stage runs again'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $c.dataRoot 'Applications\history') -Filter 'result-*.json').Count -eq 1) 'previous result archived'
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'now complete'
    Assert-Equal "$($script:Sim.Packages[0].InstallCalls) $($script:Sim.Packages[2].InstallCalls)" '1 1' 'no successful operation repeated'
    $p = Get-Pkg (Get-Result $c) 'Vendor.Down'
    Assert-Equal "$($p.manualRetries) $($p.totalAttempts) $($p.attempts)" '1 3 1' 'fresh budget, total kept'
    Assert-True (@($p.history | Where-Object { $_.trigger -eq 'manual' -and $_.message -match 'PC\\Tech' }).Count -eq 1) 'manual retry in the history'
    Assert-Equal @((Get-Result $c).recoveries).Count 1 'recovery recorded'
    Save-Result $c 'phase5-recovered'
}

$tests['recovery: refuses deselected, manual, installed, invalid and unknown operations; permanent needs -IncludePermanent'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'), (New-SimPackage 'Vendor.Hash' 'hash'))
    $c = New-AppTestConfig $script:Sim.Packages -Overrides @{
        manual = @(@{ key = 'catalog:rustdesk'; displayName = 'RustDesk'; instructions = 'Install it from the publisher.'; url = 'https://rustdesk.com/' })
        deselected = @(@{ key = 'winget:mozilla.firefox'; packageIdentifier = 'Mozilla.Firefox'; source = 'winget'; displayName = 'Firefox' }) }
    [void] (Invoke-Logons $c)
    $ops = @('app:winget:git.git', 'app:winget:mozilla.firefox', 'catalog:rustdesk', 'app:winget:vendor.hash', 'app:winget:Bad;Pkg', 'app:winget:not.inplan', 'shell:Remove-Item')
    $r = Invoke-WdaRetry $c -Operations $ops
    Assert-Equal $r.Outcome 'Refused' 'nothing reopened'
    $why = @{}; foreach ($x in $r.Refused) { $why[$x.operationId] = $x.reason }
    Assert-True ($why['app:winget:git.git'] -match 'already installed') 'installed'
    Assert-Equal $why['app:winget:mozilla.firefox'] 'explicitly deselected for this deployment' 'deselection respected (exact reason)'
    Assert-True ($why['app:catalog:rustdesk'] -match 'not a valid operation id') 'manual entry'
    Assert-True ($why['app:winget:vendor.hash'] -match 'IncludePermanent') 'permanent'
    Assert-True ($why['app:winget:bad;pkg'] -match 'not a valid operation id') 'invalid id'
    Assert-True ($why['app:winget:not.inplan'] -match 'not part of this deployment') 'unknown'
    Assert-True ($why['app:shell:remove-item'] -match 'not a valid operation id') 'no arbitrary input'
    Assert-Equal "$($script:Sim.Packages[0].InstallCalls) $($script:Sim.Packages[1].InstallCalls)" '1 1' 'nothing ran'
    $r = Invoke-WdaRetry $c -Operations @('app:winget:vendor.hash') -IncludePermanent
    Assert-Equal $r.Outcome 'Accepted' 'explicit technician override'
    [void] (Invoke-Logons $c)
    Assert-Equal $script:Sim.Packages[1].InstallCalls 2 'retried once more with the same checks'
    Assert-Equal (Get-Pkg (Get-Result $c) 'Vendor.Hash').lifecycle 'FailedPermanent' 'the hash check still applies'
}

$tests['recovery: a dependent application is retried together with its failed dependency, in order'] = {
    Reset-Sim @((New-SimPackage 'Microsoft.VCRedist.2015+.x64' 'fail'), (New-SimPackage 'Vendor.NeedsRuntime' -After @('winget:microsoft.vcredist.2015+.x64')))
    $c = New-AppTestConfig $script:Sim.Packages
    [void] (Invoke-Logons $c)
    Assert-Equal (Get-Pkg (Get-Result $c) 'Vendor.NeedsRuntime').lifecycle 'BlockedByDependency' 'blocked'
    $script:Sim.Packages[0].Behavior = 'ok'
    $script:Sim.Order = @()
    $r = Invoke-WdaRetry $c -Operations @('app:winget:vendor.needsruntime')
    Assert-Equal (@($r.Accepted) -join ',') 'app:winget:vendor.needsruntime,app:winget:microsoft.vcredist.2015+.x64' 'dependency reopened too'
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'both installed'
    Assert-Equal ($script:Sim.Order -join ',') 'Microsoft.VCRedist.2015+.x64,Vendor.NeedsRuntime' 'dependency first'
}

$tests['recovery: never runs while the engine runs; no state means nothing to retry'] = {
    Reset-Sim @((New-SimPackage 'Git.Git'))
    $c = New-AppTestConfig $script:Sim.Packages
    Assert-Equal (Invoke-WdaRetry $c -AllFailed).Outcome 'NoState' 'no state'
    $job = Start-MutexHolder $c.mutexName
    try {
        Assert-Equal (Invoke-WdaRetry $c -AllFailed).Outcome 'Busy' 'refused while running'
    } finally { $job | Stop-Job -PassThru | Remove-Job -Force }
}

$tests['a real engine 1.1.0 configuration (Phase 4.3 generator, no retry block) runs under StrictMode with safe defaults'] = {
    $src = Join-Path $PSScriptRoot '..\fixtures\applications\engine-1.1.0-config.json'
    $raw = Get-Content -LiteralPath $src -Raw | ConvertFrom-Json
    $sims = @($raw.packages | ForEach-Object {
        $sp = New-SimPackage $_.packageIdentifier -Source $_.source -Method $(if ($_.PSObject.Properties['method']) { [string] $_.method } else { '' })
        if ($_.PSObject.Properties['portable'] -and $_.portable) { $sp.Portable = @{ executable = [string] $_.portable.executable; shortcut = [string] $_.portable.shortcut }; $sp.PortableFiles = @(([string] $_.portable.executable) -replace '\*', '-1.0') }
        $sp
    })
    Reset-Sim $sims
    $root = Join-Path ([IO.Path]::GetTempPath()) ("wda-test-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Copy-Item -LiteralPath $src -Destination (Join-Path $root 'applications-config.json')
    $c = Get-WdaConfig (Join-Path $root 'applications-config.json')
    Assert-Equal "$($c.engineVersion) $($c.ContainsKey('retry'))" '1.1.0 False' 'a genuine 1.1.0 configuration'
    $c.dataRoot = $root
    $c.mutexName = "Local\wda-test-$([Guid]::NewGuid().ToString('N'))"
    $c.coordination.windowsUpdate.enabled = $false
    Set-StrictMode -Version 2.0
    try { $o = Invoke-Logons $c } finally { Set-StrictMode -Off }
    Assert-Equal $o[-1] 'Finished:CompletedWithFollowUp' 'finishes (RustDesk is a manual follow-up)'
    $r = Get-Result $c
    Assert-Equal "$($r.retryPolicy.automatic) $($r.retryPolicy.maxAttempts) $($r.retryPolicy.baseDelaySeconds)" 'True 2 60' 'engine defaults with the configured attempt limit'
    Assert-Equal @($r.packages | Where-Object { $_.status -notin 'Succeeded', 'RequiresInteraction' }).Count 0 'every package installed'
    Assert-True (@($r.packages).Count -ge 10) "the real plan ($(@($r.packages).Count) operations)"
}

$tests['documented example: 20 applications, 18 succeed, one recovers on automatic retry, one needs a technician'] = {
    $ids = @(1..18 | ForEach-Object { New-SimPackage ("Vendor.App{0:D2}" -f $_) })
    $flaky = New-SimPackage 'Vendor.FlakyDownload' 'fail-once'
    $down = New-SimPackage 'Vendor.MirrorDown' 'fail'
    Reset-Sim (@($ids[0..8]) + @($flaky) + @($ids[9..17]) + @($down))
    $c = New-AppTestConfig $script:Sim.Packages -Overrides @{ maxAttemptsPerPackage = 3 }
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:CompletedWithFailures' 'automatic phase'
    $r = Get-Result $c
    Assert-Equal "$($r.counts.succeeded) $($r.counts.failed)" '19 1' '18 + the one that recovered; one failed'
    Assert-Equal (Get-Pkg $r 'Vendor.FlakyDownload').attempts 2 'recovered on the second attempt'
    Assert-Equal "$((Get-Pkg $r 'Vendor.MirrorDown').attempts) $((Get-Pkg $r 'Vendor.MirrorDown').lifecycle)" '3 FailedRetryable' 'budget used up'
    Assert-Equal ($script:Sim.Waits -join ',') '60,120' 'backoff: one 60 s wait (both first retries were due together), then 120 s'
    Save-Result $c 'phase5-example-before'
    $down.Behavior = 'ok'                            # the mirror is back / the technician fixed the cause
    Assert-Equal (Invoke-WdaRetry $c -AllFailed -RequestedBy 'SHOP\Technician').Outcome 'Accepted' 'technician retry'
    $o = Invoke-Logons $c
    Assert-Equal $o[-1] 'Finished:Succeeded' 'all 20 installed'
    Assert-Equal (@($script:Sim.Packages | Where-Object { $_.InstallCalls -gt 1 } | ForEach-Object { $_.Id }) -join ',') 'Vendor.FlakyDownload,Vendor.MirrorDown' 'only the two failing apps ran more than once'
    Save-Result $c 'phase5-example-after'
}

$tests['stale install lock (owner process gone) is taken over at once; a live lock is not'] = {
    Reset-Sim
    $root = Join-Path ([IO.Path]::GetTempPath()) ("wda-test-" + [Guid]::NewGuid().ToString('N'))
    $p = Get-WdbCoordinationPaths $root
    New-Item -ItemType Directory -Path $p.Dir -Force | Out-Null
    [IO.File]::WriteAllText($p.Lock, '{"owner":"Applications","pid":999999,"sinceUtc":"2026-10-19T00:00:00Z"}')
    $l = Enter-WdbInstallLock $root 'Applications' 60
    try {
        Assert-True ($null -ne $l) 'stale lock file taken over'
        Assert-Equal $script:Sim.LockPolls 0 'without waiting'
        Assert-True ((Get-WdbInstallLockOwner $root) -match "`"pid`":$PID") 'new owner recorded'
        Assert-Equal (Enter-WdbInstallLock $root 'Other' 0) $null 'a live lock is respected'
    } finally { Exit-WdbInstallLock $l }
}

# ------------------------------------------------------------------------------------------------
# Bootstrap
# ------------------------------------------------------------------------------------------------

$tests['bootstrap: healthy WinGet is left alone'] = {
    Reset-Sim
    $b = Invoke-WgbBootstrap -AllowRegister $true -AllowOnlineRepair $true
    Assert-Equal $b.Status 'Healthy' 'status'
    Assert-Equal "$($script:Sim.RegisterCalls)/$($script:Sim.OfflineInstalls)/$($script:Sim.OnlineRepairs)" '0/0/0' 'no repair action'
}

$tests['bootstrap: Check mode never repairs'] = {
    Reset-Sim
    $script:Sim.WinGetHealthy = $false
    $b = Invoke-WgbBootstrap -CheckOnly
    Assert-Equal $b.Status 'NeedsRepair' 'status'
    Assert-Equal $script:Sim.RegisterCalls 0 'no registration'
}

$tests['bootstrap: SYSTEM is unsupported'] = {
    Reset-Sim
    $script:Sim.IsSystem = $true
    $b = Invoke-WgbBootstrap
    Assert-Equal $b.Status 'Unsupported' 'status'
    Assert-True ($b.Message -match 'SYSTEM') 'message'
}

$tests['bootstrap: outdated WinGet is not accepted as healthy'] = {
    Reset-Sim
    $script:Sim.WinGetVersion = '1.2.10271'
    $script:Sim.RegisterFixes = $false
    $b = Invoke-WgbBootstrap -AllowRegister $true
    Assert-Equal $b.Status 'Failed' 'status'
    Assert-True ($b.Message -match 'older than') "message: $($b.Message)"
}

$tests['bootstrap: registration fails, signed offline package repairs'] = {
    Reset-Sim
    $script:Sim.WinGetHealthy = $false
    $script:Sim.RegisterThrows = $true
    $script:Sim.Offline = @{ Bundle = 'C:\offline\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'; Dependencies = @('C:\offline\Microsoft.VCLibs.x64.appx') }
    $b = Invoke-WgbBootstrap -AllowRegister $true -OfflinePath 'C:\offline'
    Assert-Equal $b.Status 'Repaired' 'status'
    Assert-Equal $b.Method 'offline package' 'method'
}

$tests['bootstrap: unsigned offline package is never installed'] = {
    Reset-Sim
    $script:Sim.WinGetHealthy = $false
    $script:Sim.RegisterFixes = $false
    $script:Sim.SignatureValid = $false
    $script:Sim.Offline = @{ Bundle = 'C:\offline\Microsoft.DesktopAppInstaller.msixbundle'; Dependencies = @() }
    $b = Invoke-WgbBootstrap -AllowRegister $true -OfflinePath 'C:\offline'
    Assert-Equal $b.Status 'Failed' 'status'
    Assert-Equal $script:Sim.OfflineInstalls 0 'not installed'
    Assert-True (($b.Steps -join ' ') -match 'no valid Microsoft signature') 'reason recorded'
}

$tests['bootstrap: online repair only when allowed'] = {
    Reset-Sim
    $script:Sim.WinGetHealthy = $false
    $script:Sim.RegisterFixes = $false
    $b = Invoke-WgbBootstrap -AllowRegister $true -AllowOnlineRepair $false
    Assert-Equal $b.Status 'Failed' 'not allowed'
    Assert-Equal $script:Sim.OnlineRepairs 0 'no online repair'
    $b = Invoke-WgbBootstrap -AllowRegister $true -AllowOnlineRepair $true
    Assert-Equal $b.Status 'Repaired' 'allowed'
    Assert-Equal $b.Method 'online repair' 'method'
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
# Junctions created by the traversal scenario are removed first (without following them).
Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'wda-test-portable-*' -Directory -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Recurse -Directory -Attributes ReparsePoint -ErrorAction SilentlyContinue | ForEach-Object { [IO.Directory]::Delete($_.FullName) } }
Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'wda-test-*' -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "$($script:Passed) passed, $($script:Failures) failed"
if ($script:Failures -gt 0) { exit 1 }
exit 0
