#Requires -Version 5.1
<#
    Simulated computer for the deployment scenario suites (Deployment.Tests.ps1, Health.Tests.ps1):
    the orchestrator's adapters (time, identity, tasks, installers, shortcuts, events, the update
    policy) and the application engine's (WinGet, network, restarts, portable folders). Dot-source
    it after the package's own scripts; the REAL orchestrator, engines and recovery tool then run
    against it. Expects $Fixture (the fixture folder) in the calling script.
#>

function Assert-Equal($Actual, $Expected, [string] $Message) { if ("$Actual" -ne "$Expected") { throw "ASSERT: $Message. Expected <$Expected>, got <$Actual>." } }
function Assert-True($Value, [string] $Message) { if (-not $Value) { throw "ASSERT: $Message" } }

# ------------------------------------------------------------------------------------------------
# Simulated machine
# ------------------------------------------------------------------------------------------------

function Reset-Sim {
    # Phase 6 scenarios switch to the migration package; every scenario starts with the main one.
    $script:usb = Join-Path $Fixture 'usb'
    $script:pkgRoot = Join-Path $script:usb 'WindowsDeployment'
    $script:manifestPath = Join-Path $script:pkgRoot 'deployment-manifest.json'
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
    # Orchestrator 1.2.0: task states and results for the watchdog, tasks started, Windows servicing, devices.
    $script:SimTaskStates = @{}
    $script:SimTaskResults = @{}
    $script:StartedTasks = New-Object System.Collections.Generic.List[string]
    $script:SimServicing = $false
    $script:SimDevices = @()
    $script:SimDevicesThrow = $false
    $script:HelperRegistrationFails = $false
    # Orchestrator 1.3.0: what Windows reports about a pending restart, installers running, restarts
    # requested, and what a Windows Update re-check finds. Nothing real is ever restarted or searched.
    $script:SimServicingRestart = @()
    $script:SimInstallerActive = ''
    $script:SimRestarts = New-Object System.Collections.Generic.List[string]
    $script:SimRestartThrows = $false
    $script:SimRestartWaits = 0
    $script:SimOffered = @()
    $script:SimOfferedThrows = $false
    $script:SimOfferedCalls = 0
    $script:WddTaskVisibility = 'Full'
    $script:Paths = Get-WddPaths (Join-Path $script:Tmp 'ProgramData\WindowsDeploymentBuilder')
    $script:Manifest = Read-WddManifest $manifestPath
    # Phase 4.3 ongoing update policy: edition, management and the AU policy values.
    $script:SimEdition = 'Professional'
    $script:SimManaged = @()
    $script:SimAu = @{}
    $script:SimAuWrites = 0
    $script:SimAuFail = $false
    # Phase 9: a healthy simulated Windows for the health engine (HealthSim.ps1), when it is loaded.
    if (Get-Command Reset-HealthSim -ErrorAction SilentlyContinue) { Reset-HealthSim }
}

function Get-WddNow { $script:SimNow }
function Get-WddBootTime { $script:SimBoot }
function Get-WddIdentity { $script:SimIdentity }
function Test-WddWinPE { $script:SimWinPE }
function Get-WddTask { param([string] $TaskPath, [string] $TaskName) $script:SimTasks.ContainsKey("$TaskPath$TaskName") }
function Unregister-WddTask { param([string] $TaskPath, [string] $TaskName) $script:SimTasks.Remove("$TaskPath$TaskName") }
function Start-WddTask { param([string] $TaskPath, [string] $TaskName) $script:StartedTasks.Add("$TaskPath$TaskName") }
function Get-WddTaskInfo {
    param([string] $TaskPath, [string] $TaskName)
    $k = "$TaskPath$TaskName"
    if (-not $script:SimTasks.ContainsKey($k)) { return @{ Exists = $false; State = ''; LastRunUtc = $null; LastResult = $null } }
    @{ Exists = $true; State = $(if ($script:SimTaskStates.ContainsKey($k)) { $script:SimTaskStates[$k] } else { 'Ready' }); LastRunUtc = $null; LastResult = $(if ($script:SimTaskResults.ContainsKey($k)) { $script:SimTaskResults[$k] } else { 0 }) }
}
function Test-WddUpdateServicing { $script:SimServicing }
function Get-WddServicingRestart { @($script:SimServicingRestart) }
function Test-WddInstallerActive { $script:SimInstallerActive }
function Invoke-WddRestart { param([int] $WarningSeconds, [string] $Reason) if ($script:SimRestartThrows) { throw 'shutdown.exe failed with exit code 1190 (simulated)' }; $script:SimRestarts.Add($Reason) }
function Wait-WddRestart { param([int] $Seconds) $script:SimRestartWaits += $Seconds }
function Get-WddOfferedUpdates { param($Config) $script:SimOfferedCalls++; if ($script:SimOfferedThrows) { throw 'Windows Update search failed (simulated)' }; @($script:SimOffered) }
<# Simulated restart: a new boot, the pending restart and the engines' restart marker are gone. #>
function Invoke-SimBoot { $script:SimNow = $script:SimNow.AddMinutes(3); $script:SimBoot = $script:SimNow; $script:SimServicingRestart = @(); $script:SimNow = $script:SimNow.AddMinutes(2) }
function Register-WddProgressTask {
    param([hashtable] $Paths, [string] $User, [int] $IntervalSeconds = 7)
    if ($script:HelperRegistrationFails) { throw 'Access is denied (simulated)' }
    $script:SimTasks['\WindowsDeploymentBuilder\Progress'] = $User
}
function Register-WddStatusServerTask {
    param([hashtable] $Paths)
    if ($script:HelperRegistrationFails) { throw 'Access is denied (simulated)' }
    $script:SimTasks['\WindowsDeploymentBuilder\StatusServer'] = 'SYSTEM'
}
function Get-WddPnpDevices { if ($script:SimDevicesThrow) { throw 'Invalid class (simulated)' }; @($script:SimDevices) }
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
    # Like the real installer when it cannot read its own staged files (the bare-metal failure).
    if ($b -eq 'noTask') { $script:WddInstallerOutput = @('Starting.', "Access to the path '$Path' is denied."); return 1 }
    $task = if ($leaf -eq 'Install-UpdateEngine.ps1') { '\WindowsDeploymentBuilder\WindowsUpdate' } else { '\WindowsDeploymentBuilder\Applications' }
    $script:SimTasks[$task] = $script:SimIdentity.Name
    # Like the real installers: a new installation archives the engine's previous run.
    $dir = Join-Path $script:Paths.Root $(if ($leaf -eq 'Install-UpdateEngine.ps1') { 'Updates' } else { 'Applications' })
    foreach ($n in 'state.json', 'result.json', 'status.json') { $f = Join-Path $dir $n; if (Test-Path -LiteralPath $f) { Move-Item -LiteralPath $f -Destination "$f.$($script:Installers.Count).bak" -Force } }
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

function Reset-AppSim {
    param([hashtable] $Behaviour = @{})
    $script:AppSim = @{ Behaviour = $Behaviour; Installed = @{}; Calls = @{}; Online = $true; SourceDown = @(); Order = New-Object System.Collections.Generic.List[string]; Reboots = 0; ResumeInstalls = 0 }
    $script:AppMutex = "Local\wda-dt-$([guid]::NewGuid().ToString('N'))"
}
function Get-WdaNow { $script:SimNow }
function Wait-Wda { param([int] $Seconds) $script:SimNow = $script:SimNow.AddSeconds($Seconds) }
function Get-WdaContext { @{ User = $script:SimIdentity.Name; IsSystem = $script:SimIdentity.IsSystem; IsElevated = $true } }
function Test-WdaNetwork { $script:AppSim.Online }
function Get-WdaNetworkDiagnosis {
    param([string] $Source = 'winget')
    if (-not $script:AppSim.Online) { return @{ Level = 'InternetUnavailable'; Detail = 'simulated' } }
    if ($script:AppSim.SourceDown -contains $Source) { return @{ Level = 'SourceUnavailable'; Detail = 'simulated' } }
    @{ Level = 'Online'; Detail = 'simulated' }
}
function Get-WdaRandom { 0.5 }
function Test-WdaRebootPending { $false }
function Invoke-WdaReboot { param([int] $WarningSeconds, [string] $Reason) $script:AppSim.Reboots++ }
function Test-WdaUpdateTask { param([hashtable] $WU) $script:SimTasks.ContainsKey("$($WU.taskPath)$($WU.taskName)") }
function Unregister-WdaTask { param([hashtable] $Config) [void] $script:SimTasks.Remove("$($Config.taskPath)$($Config.taskName)") }
function Write-WdaEvent { param([int] $EventId, [string] $Message, [string] $EntryType = 'Information') $script:Events.Add($EventId) }
function Get-WdbBootTime { $script:SimBoot.ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Wait-WdbLockPoll { }
function Invoke-WgbBootstrap { param([switch] $CheckOnly, $AllowRegister, $AllowOnlineRepair, $OfflinePath, $MinimumVersion) @{ Status = 'Healthy'; Method = ''; Version = '1.29.250'; Message = 'WinGet 1.29.250 works.'; Path = 'C:\sim\winget.exe'; Steps = @() } }
function Get-WdaPortableRoots { @(Join-Path $script:Tmp 'WinGetPackages') }
function Get-WdaShortcutFolder { Join-Path $script:Tmp 'StartMenu' }
function New-WdaShortcutFile { param([string] $Path, [string] $Target) [IO.File]::WriteAllText($Path, $Target) }
function Test-WdaInstalled { param([hashtable] $P, [string] $LogFile = '') [bool] $script:AppSim.Installed[$P.packageIdentifier] }
function Test-WdaAvailable { param([hashtable] $P, [string] $LogFile = '') 'Available' }
function Install-WdaPackage {
    param([hashtable] $P, [int] $TimeoutMinutes, [string] $LogFile = '')
    $id = $P.packageIdentifier
    $n = 1 + [int] $script:AppSim.Calls[$id]
    $script:AppSim.Calls[$id] = $n
    $script:AppSim.Order.Add($id)
    $b = $(if ($script:AppSim.Behaviour.ContainsKey($id)) { $script:AppSim.Behaviour[$id] } else { 'ok' })
    $code = 0
    switch ($b) {
        'ok'         { $script:AppSim.Installed[$id] = $true }
        'fail'       { $code = 0x8A150008 }
        'fail-once'  { if ($n -ge 2) { $script:AppSim.Installed[$id] = $true } else { $code = 0x8A150008 } }
        'hash'       { $code = 0x8A150011 }
        'reboot-now' { if ($script:AppSim.Reboots -ge 1) { $script:AppSim.Installed[$id] = $true } else { $code = 0x8A15010A } }
        'net-drop'   { if ($n -eq 1) { $script:AppSim.Online = $false; $code = 0x8A150107 } else { $script:AppSim.Installed[$id] = $true } }
    }
    if ($script:AppSim.Installed[$id] -and $P.method -eq 'portable') {
        $dir = Join-Path (Join-Path $script:Tmp 'WinGetPackages') "$($id)_Microsoft.Winget.Source_8wekyb3d8bbwe"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir (($P.portable.executable) -replace '\*', '-4.6')), 'MZ')
    }
    @{ ExitCode = [int] $code; TimedOut = $false; Output = '' }
}

<# The engine configuration exactly as staged, with only its machine paths moved below the temporary folder. #>
function Get-SimAppConfig {
    $c = Get-WdaConfig (Join-Path $script:Paths.Package 'scripts\applications\applications-config.json')
    $c.dataRoot = $script:Paths.Root
    $c.mutexName = $script:AppMutex
    $c.coordination.windowsUpdate.stateFile = Join-Path $script:Paths.Root 'Updates\state.json'
    $c.coordination.windowsUpdate.resultFile = Join-Path $script:Paths.Root 'Updates\result.json'
    $c.gatePollMinutes = 1
    $c.lockWaitMinutes = 0
    # Engine 1.5.0: scenarios that use a hash mismatch as "a permanent failure" turn the delayed retry off.
    if ($script:AppSim -and $script:AppSim.ContainsKey('IntegrityRetryMinutes')) { $c.integrityRetryMinutes = $script:AppSim.IntegrityRetryMinutes }
    return $c
}
# Engine 1.5.0 adapters: never a real source update or task in the simulation.
function Update-WdaSource { param([string] $Source, [string] $LogFile = '') if ($script:AppSim) { $script:AppSim['SourceUpdates'] = [int] $script:AppSim['SourceUpdates'] + 1 } }
function Install-WdaPackageAsUser { param([hashtable] $P, [int] $TimeoutMinutes, [string] $LogFile = '') @{ ExitCode = $null; TimedOut = $false; Output = ''; Error = 'not available in the simulation' } }
function Get-WdrAppConfig { param([hashtable] $Paths) Get-SimAppConfig }
function Invoke-WdrAppInstaller {
    param([hashtable] $Paths)
    if ($script:AppSim) { $script:AppSim.ResumeInstalls++ }
    if ($script:InstallerBehaviour['Install-ApplicationEngine.ps1'] -eq 'noTask') { return 1 }
    $script:SimTasks['\WindowsDeploymentBuilder\Applications'] = $script:SimIdentity.Name
    return 0
}

<# The application task: at sign-in and hourly, plus a simulated restart when the engine asks for one. #>
function Invoke-AppRuns {
    param([int] $Max = 25)
    $out = @()
    for ($i = 0; $i -lt $Max; $i++) {
        $o = Invoke-WdaMain (Get-SimAppConfig)
        $out += $o
        if ($o -eq 'Rebooting') { $script:SimNow = $script:SimNow.AddMinutes(3); $script:SimBoot = $script:SimNow; $script:SimNow = $script:SimNow.AddMinutes(2); continue }
        if ($o -like 'Finished:*' -or $o -eq 'AlreadyFinished') { break }
        $script:SimNow = $script:SimNow.AddHours(1)
    }
    , $out
}
function Get-AppResult { Read-WddJson (Join-Path $script:Paths.Root 'Applications\result.json') }
function Get-AppPkg { param($Result, [string] $Id) @($Result.packages) | Where-Object { $_.packageIdentifier -eq $Id } | Select-Object -First 1 }
$script:FixtureApps = @('Google.Chrome', 'VideoLAN.VLC', '7zip.7zip', 'CodeSector.TeraCopy', 'Bitwarden.Bitwarden', 'Microsoft.VCRedist.2015+.x64', 'Microsoft.VCRedist.2015+.x86', '9NP83LWLPZ9K', 'Rufus.Rufus', 'Git.Git', 'Example.TestPackage')
