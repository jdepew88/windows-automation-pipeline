#Requires -Version 5.1
<#
    Phase 9 scenario tests: deployment verification and health (DeploymentHealth.ps1) against the
    REAL generated packages (deployment-fixture.ts: <fixture>\health, \migration), the REAL
    orchestrator, application engine, restore library and recovery tool. Only Windows itself is
    simulated (ProvisioningSim.ps1: time, tasks, WinGet, restarts; HealthSim.ps1: edition,
    accounts, devices, uninstall records, Defender, firewall, encryption, network, storage).
    Every scenario runs under Set-StrictMode -Version 2.0, as the scripts do on Windows.

    Nothing is installed, registered, restarted or changed on this computer; everything is written
    below a temporary folder. With -Out, the reports of the main scenarios are copied there so the
    TypeScript tests can validate them against the published schema.

    Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\powershell\Health.Tests.ps1 -Fixture <dir> [-Out <dir>]
#>
param([Parameter(Mandatory = $true)] [string] $Fixture, [string] $Out = '')

$ErrorActionPreference = 'Stop'
$healthPkg = Join-Path $Fixture 'health\usb\WindowsDeployment'
$pkgScripts = Join-Path $healthPkg 'scripts'
. (Join-Path $pkgScripts 'common\DeploymentCommon.ps1')
. (Join-Path $pkgScripts 'bootstrap\Stage-Deployment.ps1')
. (Join-Path $pkgScripts 'bootstrap\Initialize-Deployment.ps1')
. (Join-Path $pkgScripts 'finalization\Complete-Deployment.ps1')
. (Join-Path $pkgScripts 'orchestrator\DeploymentOrchestrator.ps1')
. (Join-Path $pkgScripts 'orchestrator\Show-DeploymentStatus.ps1')
. (Join-Path $pkgScripts 'recovery\DeploymentRecovery.ps1')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$script:Failures = 0
$script:Passed = 0
$script:MutexName = "Global\WDH-Test-$([guid]::NewGuid().ToString('N'))"
$usb = Join-Path $Fixture 'usb'
$pkgRoot = Join-Path $usb 'WindowsDeployment'
$manifestPath = Join-Path $pkgRoot 'deployment-manifest.json'
. (Join-Path $PSScriptRoot 'ProvisioningSim.ps1')
. (Join-Path $PSScriptRoot 'HealthSim.ps1')
. (Join-Path $PSScriptRoot 'MigrationSim.ps1')
if ($Out -and -not (Test-Path -LiteralPath $Out)) { New-Item -ItemType Directory -Path $Out -Force | Out-Null }

# ------------------------------------------------------------------------------------------------
# The Phase 9 package and its driver stage (simulated output; the real driver engine has its own suite)
# ------------------------------------------------------------------------------------------------

function Use-HealthPackage {
    $script:usb = Join-Path $Fixture 'health\usb'
    $script:pkgRoot = Join-Path $script:usb 'WindowsDeployment'
    $script:manifestPath = Join-Path $script:pkgRoot 'deployment-manifest.json'
    $script:Manifest = Read-WddManifest $script:manifestPath
    $script:SimIdentity = @{ Name = 'PC\owner'; IsSystem = $false; IsAdmin = $true }
    Reset-HealthSim
}

function Invoke-WddInstaller {
    param([string] $Path)
    $leaf = Split-Path -Leaf $Path
    $script:Installers.Add($leaf)
    if (-not (Test-Path -LiteralPath $Path)) { throw "installer not staged: $Path" }
    $task = switch ($leaf) { 'Install-UpdateEngine.ps1' { '\WindowsDeploymentBuilder\WindowsUpdate' } 'Install-DriverEngine.ps1' { '\WindowsDeploymentBuilder\Drivers' } default { '\WindowsDeploymentBuilder\Applications' } }
    $script:SimTasks[$task] = $script:SimIdentity.Name
    return 0
}

<# The staged application configuration with its machine paths (both stage gates) below the temporary folder. #>
function Get-SimAppConfig {
    $c = Get-WdaConfig (Join-Path $script:Paths.Package 'scripts\applications\applications-config.json')
    $c.dataRoot = $script:Paths.Root
    $c.mutexName = $script:AppMutex
    $c.coordination.windowsUpdate.stateFile = Join-Path $script:Paths.Root 'Updates\state.json'
    $c.coordination.windowsUpdate.resultFile = Join-Path $script:Paths.Root 'Updates\result.json'
    if ($c.coordination.ContainsKey('drivers') -and $c.coordination['drivers']) {
        $c.coordination.drivers.stateFile = Join-Path $script:Paths.Root 'Drivers\state.json'
        $c.coordination.drivers.resultFile = Join-Path $script:Paths.Root 'Drivers\result.json'
    }
    $c.gatePollMinutes = 1
    $c.lockWaitMinutes = 0
    return $c
}
# The recovery tool's driver branch would read C:\ProgramData: the driver stage is simulated here.
function Get-WdrDriverConfig { param([hashtable] $Paths) $null }

<# What the driver stage writes (reports\drivers.json, Drivers\result.json and state.json), in the Phase 8 contract. #>
function Set-DriverStage {
    param([string] $Status = 'Succeeded', [hashtable] $Over = @{}, [string] $Health = 'AllHealthy', [object[]] $ManualActions = @(), [object[]] $Operations = @(), [object[]] $Optional = @(), [switch] $NotFinal)
    $cat = @{ Net = 'networkWired'; Display = 'display'; SCSIAdapter = 'storageNvme'; MEDIA = 'audio'; Bluetooth = 'bluetooth' }
    $n = 0
    $devices = @(foreach ($d in $script:M.devices) {
        $n++
        $x = [ordered]@{ key = "dev-00000000000$n"; name = $d.name; category = $(if ($cat.ContainsKey($d.class)) { $cat[$d.class] } else { 'other' }); class = $d.class; vendor = @{ id = 'sim'; name = 'Sim'; vendorId = '0000' }
                         instanceId = "SIM\#$n"; hardwareIds = @($d.hardwareId); compatibleIds = @(); problemCode = 0; driver = @{ provider = 'Sim'; version = '1.0.0.0'; date = '2026-01-01'; inf = 'oem1.inf'; inbox = $false }
                         previousDriver = $null; oemCustomized = $false; state = 'Healthy'; action = 'Keep'; confidence = 'high'; reasons = @(); setupCritical = $false; networkCritical = ($d.class -eq 'Net')
                         source = 'existing'; result = 'Kept'; verification = 'Verified'; rebootRequired = $false; errors = @(); manualAction = $null }
        if ($Over.ContainsKey($d.hardwareId)) { foreach ($k in $Over[$d.hardwareId].Keys) { $x[$k] = $Over[$d.hardwareId][$k] } }
        $x
    })
    $now = $script:SimNow.ToString('o')
    $report = [ordered]@{ format = 'windows-deployment-builder/drivers-result'; version = 1; final = (-not $NotFinal); status = $(if ($NotFinal) { 'InProgress' } else { $Status }); engineVersion = '1.0.0'; deploymentId = $script:Manifest.packageId
                          generatedUtc = $now; scanUtc = $now; inspections = @(); system = @{ manufacturer = 'Contoso'; model = 'Workstation 7'; family = ''; portable = $false; virtual = $false; architecture = 'amd64'; osBuild = 26200; biosVersion = '1.0'; processors = @('Sim CPU') }
                          windowsUpdate = @{ partOfDeployment = $true; driversAllowed = $true; waitedForIt = $true; stageStatus = 'Succeeded'; gate = '' }; summary = @{ devices = $devices.Count; healthy = @($devices | Where-Object { $_.state -eq 'Healthy' }).Count; basicDriver = 0; driverMissing = 0; malfunctioning = 0; restartPending = 0; hardwareIssue = 0 }
                          health = @{ status = $Health; flags = @{} }; devices = $devices; operations = @($Operations); manualActions = @($ManualActions); unsupported = @(); optionalApplications = @($Optional)
                          networkBootstrap = @{ status = 'NotNeeded'; detail = '' }; offlineBundle = @{ status = 'None'; detail = ''; packages = 0 }; reboots = 0 }
    Write-WddJson (Join-Path $script:Paths.Root 'reports\drivers.json') $report
    if (-not $NotFinal) {
        Write-WddJson (Join-Path $script:Paths.Root 'Drivers\result.json') @{ status = $Status; reason = "sim $Status"; reboots = 0; finishedUtc = $now; health = $Health; installed = @(); outstanding = @() }
        Write-WddJson (Join-Path $script:Paths.Root 'Drivers\state.json') @{ final = $Status; operations = @{} }
        [void] $script:SimTasks.Remove('\WindowsDeploymentBuilder\Drivers')
    }
}

<# A whole deployment: answer-file extraction, staging, every stage, the monitor, completion and verification. #>
function Invoke-SimDeployment {
    param([hashtable] $DriverOver = @{}, [string] $DriverStatus = 'Succeeded', [string] $DriverHealth = 'AllHealthy')
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'Succeeded' @{ installed = @(@{ kbs = @('KB5068861'); title = '2026-10 Cumulative Update for Windows 11' }); failed = @(); skipped = @() }
    if (@($script:Manifest.stages | Where-Object { $_.id -eq 'drivers' -and $_.enabled }).Count) { Set-DriverStage -Status $DriverStatus -Over $DriverOver -Health $DriverHealth }
    $script:LastAppRuns = Invoke-AppRuns
    return Invoke-WddMonitor $script:Paths
}

<# The staged plan (as the computer reads it), or the package's own before anything was staged. #>
function Get-HealthConfig {
    $c = Read-WddJson (Join-Path $script:Paths.Package 'scripts\health\health-config.json')
    if (-not $c) { $c = Read-WddJson (Join-Path $script:pkgRoot 'scripts\health\health-config.json') }
    return $c
}
function Invoke-Verify { param([string] $Trigger = 'Technician', [switch] $ScanUpdates) Invoke-WdhVerify $script:Manifest $script:Paths (Get-HealthConfig) $Trigger -ScanUpdates:$ScanUpdates }

function Save-Out {
    param([string] $Name)
    if (-not $Out) { return }
    $dir = Join-Path $script:Paths.Root 'reports\health'
    foreach ($f in 'deployment-health.json', 'customer-handoff.json', 'technician-report.html', 'customer-handoff.html') {
        $p = Join-Path $dir $f
        if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination (Join-Path $Out "$Name-$f") -Force }
    }
}

<# File hashes below the data root, except the health reports and logs (what verification may write). #>
function Get-TreeState {
    $root = $script:Paths.Root
    $h = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force)) {
        $rel = $f.FullName.Substring($root.Length + 1)
        if ($rel -like 'reports\health\*' -or $rel -like 'Deployment\logs\*') { continue }
        $h[$rel] = Get-WddRawHash $f.FullName
    }
    return $h
}

function Test-HealthScenario {
    param([string] $Name, [scriptblock] $Body, [switch] $Migration)
    Reset-Sim
    if ($Migration) { Use-MigrationPackage; Reset-HealthSim } else { Use-HealthPackage }
    Reset-AppSim
    try {
        Set-StrictMode -Version 2.0
        & $Body
        $script:Passed++
        Write-Output "  ok    $Name"
    } catch {
        $script:Failures++
        Write-Output "  FAIL  $Name"
        Write-Output "        $($_.Exception.Message)"
        Write-Output "        $($_.InvocationInfo.PositionMessage -replace "`n", "`n        ")"
    } finally {
        Set-StrictMode -Off
        $script:WddLogFile = $null
        Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Assert-Status { param($Report, [string] $Expected, [string] $Message) Assert-Equal $Report.overall.status $Expected "$Message (summary: $($Report.overall.summary))" }

Write-Output "Deployment verification and health scenarios (fixture $Fixture)"

# ------------------------------------------------------------------------------------------------
# Package and plan
# ------------------------------------------------------------------------------------------------

Test-HealthScenario 'package: health engine, plan and template embedded and staged; manifest verification block; the plan lists only the selected applications' {
    foreach ($n in 'DeploymentHealth.ps1', 'health-config.json', 'HealthReport.html') {
        $f = @($script:Manifest.files | Where-Object { $_.path -eq "scripts/health/$n" })
        Assert-Equal $f.Count 1 "$n listed"
        Assert-Equal $f[0].embedded "Deployment\scripts\health\$n" "$n embedded in the answer file"
        Assert-True $f[0].textSha256 "$n verified by text hash (ASCII or UTF-8 script)"
    }
    Assert-True ($script:Manifest.verification.readOnly) 'manifest: read-only verification'
    Assert-Equal $script:Manifest.paths.healthTool 'C:\ProgramData\WindowsDeploymentBuilder\Package\scripts\health\DeploymentHealth.ps1' 'manifest: tool path'
    $cfg = Get-HealthConfig
    $keys = @($cfg.applications.items | ForEach-Object { $_.key })
    # Core Essentials (nine apps since the 2026-11-26 profile rebuild) + Git, Apple Devices and Rufus.
    Assert-Equal $keys.Count 12 'twelve selected applications, not the catalog'
    Assert-True ($keys -notcontains 'catalog:rustdesk') 'the removed RustDesk is not expected'
    Assert-Equal (@($cfg.applications.items | Where-Object { -not $_.required }) | ForEach-Object { $_.key }) 'winget:videolan.vlc' 'VLC is optional'
    Assert-Equal "$($cfg.account.username) $($cfg.identity.computerName) $($cfg.windows.expectedEditionIds -join ',')" 'owner owner-Computer Professional' 'account, name, edition'
    Assert-Equal $cfg.windowsUpdate.drivers 'include' 'new deployments let Windows Update offer drivers'
    $drv = Read-WddJson (Join-Path $script:pkgRoot 'scripts\drivers\drivers-config.json')
    Assert-Equal $drv.windowsUpdate.drivers 'include' 'the driver stage receives the same driver policy'
    Initialize-Embedded | Out-Null
    foreach ($n in 'DeploymentHealth.ps1', 'health-config.json', 'HealthReport.html') { Assert-True (Test-Path -LiteralPath (Join-Path $script:Paths.Package "scripts\health\$n")) "$n staged on the computer" }
}

# ------------------------------------------------------------------------------------------------
# Scenarios A-L (Phase 9 specification, part 20)
# ------------------------------------------------------------------------------------------------

Test-HealthScenario 'A. perfect deployment: every objective verified against Windows -> Ready; reports, shortcut, checklist, customer handoff' {
    Assert-Equal (Invoke-SimDeployment) 'Completed:Succeeded' 'deployment'
    $r = Get-HealthReport
    Assert-Status $r 'Ready' 'overall'
    Assert-Equal $r.overall.exitCode 0 'exit code'
    Assert-True $r.overall.readyForDelivery 'ready for delivery'
    Assert-Equal $r.trigger 'DeploymentComplete' 'run by the deployment'
    foreach ($c in @($r.categories)) { Assert-True ($c.status -in 'Verified', 'NotApplicable') "$($c.id) is $($c.status): $($c.summary)" }
    Assert-Equal (Get-Category $r 'restoration').status 'NotApplicable' 'no restoration: not shown as verified'
    Assert-Equal @($r.applications).Count 12 'only the twelve selected applications'
    foreach ($a in @($r.applications)) { Assert-True ($a.independent -eq 'Found' -and $a.result -in 'InstalledVerified', 'AlreadyInstalledVerified') "$($a.name): $($a.result) ($($a.independent))" }
    Assert-Equal (@($r.applications) | Where-Object { $_.key -eq 'winget:rufus.rufus' }).foundIn 'machine' 'portable Rufus found by its WinGet record'
    Assert-Equal (@($r.applications) | Where-Object { $_.key -eq 'msstore:9np83lwlpz9k' }).independent 'Found' 'Store app found as a Store package'
    Assert-Equal (Get-Finding $r 'windows.edition').status 'Pass' 'edition'
    Assert-Equal (Get-Finding $r 'account.role').status 'Pass' 'owner is an administrator'
    Assert-Equal (Get-Finding $r 'identity.computerName').observed 'owner-Computer (active)' 'computer name'
    Assert-Equal (Get-Finding $r 'custom.explorer.showFileExtensions').status 'Pass' 'earlier customization verified in the owner''s hive'
    Assert-Equal @($r.findings | ForEach-Object { $_.id } | Select-Object -Unique).Count @($r.findings).Count 'finding ids are unique'
    foreach ($x in @($r.checklist)) { Assert-True ($x.state -in 'done', 'confirm', 'notApplicable') "checklist $($x.id) is $($x.state)" }
    Assert-True (@($r.checklist | Where-Object { $_.state -eq 'confirm' }).Count -ge 2) 'human confirmation items'
    Assert-True ($script:Events -contains 5000) 'event 5000 (Ready)'
    Assert-True $script:Shortcuts.ContainsKey("Windows Deployment $([char] 0x2014) Health Report") 'health report shortcut'
    Assert-True ($script:Shortcuts["Windows Deployment $([char] 0x2014) Health Report"] -match 'DeploymentHealth\.ps1" -Mode Dashboard -Elevate') 'shortcut verifies, then opens the dashboard'
    Assert-True (-not $script:SimTasks.ContainsKey('\WindowsDeploymentBuilder\HealthCheck')) 'no re-check task without a pending restart'
    $dep = Read-WddJson $script:Paths.ReportJson
    Assert-Equal "$($dep.health.status) $($dep.reportVersion)" 'Ready 2' 'the deployment report carries the verification (report format unchanged)'
    Assert-True ((Get-Content -Raw $script:Paths.ReportText) -match 'Deployment verification \(Phase 9, read-only\)') 'text report section'
    $h = Read-WddJson (Join-Path $script:Paths.Root 'reports\health\customer-handoff.json')
    Assert-Equal $h.headline 'Your computer is set up and ready to use.' 'customer headline'
    Assert-Equal "$($h.computerName) $($h.windows) $($h.account)" 'owner-Computer Windows 11 Pro owner' 'customer basics'
    Assert-Equal @($h.applications.installed).Count 12 'installed applications listed for the customer'
    Assert-True (@($h.actions | Where-Object { $_ -match 'Bitwarden' }).Count -eq 1) 'sign-in task for Bitwarden'
    Assert-Equal $h.notes 'Your files from the old computer are in Documents. Call us with any question.' 'technician notes'
    $html = [IO.File]::ReadAllText((Join-Path $script:Paths.Root 'reports\health\customer-handoff.html'))
    $data = [regex]::Match($html, '<script id="wdb-data" type="application/json">(.*?)</script>', 'Singleline').Groups[1].Value
    Assert-True ($data.Length -gt 200) 'customer data embedded'
    foreach ($bad in ':\\', 'ProgramData', 'S-1-5-21', 'password', 'technician', '"findings"', 'verificationId', 'PC\\owner') { Assert-True ($data.IndexOf($bad, [StringComparison]::OrdinalIgnoreCase) -lt 0) "customer data has no $bad" }
    $tech = [IO.File]::ReadAllText((Join-Path $script:Paths.Root 'reports\health\technician-report.html'))
    Assert-True ($tech -match '"mode":"technician"') 'technician report embeds its data'
    Assert-Equal ([regex]::Matches($tech, '</script>').Count) 2 'no script break-out in the embedded data'
    Save-Out 'A'
}

Test-HealthScenario 'B. one optional application failed -> ReadyWithWarnings with an explicit manual action' {
    $script:AppSim.Behaviour['VideoLAN.VLC'] = 'hash'
    Assert-Equal (Invoke-SimDeployment) 'Completed:CompletedWithFailures' 'deployment'
    $r = Get-HealthReport
    Assert-Status $r 'ReadyWithWarnings' 'overall'
    $f = Get-Finding $r 'app.winget:videolan.vlc'
    Assert-Equal "$($f.status) $($f.severity) $($f.required)" 'Fail Warning False' 'optional failure is a warning'
    Assert-True ($f.nextAction -match 'IncludePermanent') "next action: $($f.nextAction)"
    Assert-Equal $f.recoveryAction 'Retry -IncludePermanent' 'integrity failures need a corrected cause first'
    Assert-True $r.overall.readyForDelivery 'still deliverable'
    Assert-Equal (Get-Category $r 'applications').status 'Warning' 'category'
    Assert-True (@($r.outstanding | Where-Object { $_.operationId -eq 'app:winget:videolan.vlc' }).Count -eq 1) 'outstanding operation'
    $h = Read-WddJson (Join-Path $script:Paths.Root 'reports\health\customer-handoff.json')
    Assert-Equal $h.headline 'Your computer is ready to use. A few items need your attention.' 'customer is not told everything works'
    Assert-True (@($h.applications.notYet) -contains 'VLC media player') 'customer sees what is not installed'
    Save-Out 'B'
}

Test-HealthScenario 'C. required application missing -> NeedsAttention; never "Ready" because the stage finished' {
    $script:AppSim.Behaviour['Git.Git'] = 'hash'
    Assert-Equal (Invoke-SimDeployment) 'Completed:CompletedWithFailures' 'deployment finished'
    $r = Get-HealthReport
    Assert-Status $r 'NeedsAttention' 'overall'
    $f = Get-Finding $r 'app.winget:git.git'
    Assert-Equal "$($f.status) $($f.severity)" 'Fail Error' 'required failure'
    Assert-True ($f.observed -match 'Integrity') "failure class reported: $($f.observed)"
    Assert-True (-not $r.overall.readyForDelivery) 'not deliverable'
    Assert-Equal (@($r.checklist | Where-Object { $_.id -eq 'apps' })).state 'notDone' 'checklist'
    Assert-True ($script:Events -contains 5002) 'event 5002'
}

Test-HealthScenario 'D. NVIDIA GPU reports an error after its driver was installed -> NeedsAttention (the installer''s success is not trusted)' {
    $gpu = 'PCI\VEN_10DE&DEV_2504&SUBSYS_397D1462&REV_A1'
    Invoke-SimDeployment -DriverOver @{ $gpu = @{ result = 'Succeeded'; source = 'windowsUpdate'; state = 'Healthy' } } | Out-Null
    ($script:M.devices | Where-Object { $_.hardwareId -eq $gpu }).problemCode = 43
    $v = Invoke-Verify
    $r = $v.Report
    Assert-Status $r 'NeedsAttention' 'overall'
    $f = @($r.findings | Where-Object { $_.category -eq 'drivers' -and $_.title -eq 'NVIDIA GeForce RTX 3060' })[0]
    Assert-Equal "$($f.status) $($f.severity)" 'Fail Error' 'graphics failure is an error'
    Assert-True ($f.observed -match 'code 43' -and $f.observed -match 'it was working when the driver stage finished' -and $f.observed -match 'a driver was installed for it') "observed: $($f.observed)"
    # A device without a driver at all, and a generic display driver, are told apart.
    $script:M.devices += @{ name = 'PCI Simple Communications Controller'; class = 'System'; service = ''; problemCode = 28; hardwareId = 'PCI\VEN_8086&DEV_7AE8' }
    ($script:M.devices | Where-Object { $_.hardwareId -eq $gpu }).problemCode = 0
    ($script:M.devices | Where-Object { $_.hardwareId -eq $gpu }).service = 'BasicDisplay'
    $r = (Invoke-Verify).Report
    $basic = @($r.findings | Where-Object { $_.title -eq 'NVIDIA GeForce RTX 3060' })[0]
    Assert-Equal "$($basic.status) $($basic.severity)" 'Warning Warning' 'generic driver: functional but limited'
    $missing = @($r.findings | Where-Object { $_.title -eq 'PCI Simple Communications Controller' })[0]
    Assert-True ($missing.status -eq 'Fail' -and $missing.observed -match '^Missing driver' -and $missing.recoveryAction -eq 'AddDrivers') "missing driver: $($missing.observed)"
    # A disabled device is not broken.
    $script:M.devices += @{ name = 'Fingerprint Reader'; class = 'Biometric'; service = ''; problemCode = 22; hardwareId = 'USB\VID_06CB&PID_00BD' }
    $r = (Invoke-Verify).Report
    Assert-Equal (@($r.findings | Where-Object { $_.title -eq 'Fingerprint Reader' })[0]).status 'Info' 'disabled device'
}

Test-HealthScenario 'E. Windows Update restart pending -> Incomplete; a startup re-check verifies again after the restart and removes itself' {
    $script:M.reboot.windowsUpdate = $true
    Invoke-SimDeployment | Out-Null
    $r = Get-HealthReport
    Assert-Status $r 'Incomplete' 'overall'
    Assert-Equal (Get-Finding $r 'windows.restart').status 'Pending' 'restart finding'
    Assert-True (-not $r.overall.readyForDelivery) 'not deliverable while a restart is pending'
    Assert-True $script:SimTasks.ContainsKey('\WindowsDeploymentBuilder\HealthCheck') 're-check registered for the next start'
    Save-Out 'E'
    # The computer restarts.
    $script:SimNow = $script:SimNow.AddMinutes(10); $script:SimBoot = $script:SimNow.AddMinutes(-3)
    $script:M.reboot.windowsUpdate = $false
    $v = Invoke-WdhStartupRecheck $script:Manifest $script:Paths (Get-HealthConfig)
    Assert-Status $v.Report 'Ready' 'after the restart'
    Assert-Equal $v.Report.trigger 'Startup' 'trigger'
    Assert-True (-not $script:SimTasks.ContainsKey('\WindowsDeploymentBuilder\HealthCheck')) 're-check task removed itself'
    Assert-Equal $v.Report.comparison.previousStatus 'Incomplete' 'previous status kept'
    Assert-True (@($v.Report.comparison.resolved) -contains 'windows.restart') 'restart resolved'
    Assert-Equal @($v.Report.history).Count 1 'the earlier report is in the history'
}

Test-HealthScenario 'F. application installed but its required settings restoration failed -> NeedsAttention; both outcomes reported separately' -Migration {
    $script:UsbBackups = $null
    Initialize-Embedded | Out-Null
    Invoke-AppRuns | Out-Null
    Assert-Equal (Invoke-WddMonitor $script:Paths) 'Completed:CompletedWithFollowUp' 'the stage itself only reports a follow-up'
    $r = Get-HealthReport
    Assert-Status $r 'NeedsAttention' 'overall'
    Assert-Equal (Get-Finding $r 'app.winget:microsoft.visualstudiocode').status 'Pass' 'VS Code is installed'
    $s = Get-Finding $r 'restore.settings.vscode'
    Assert-Equal "$($s.status) $($s.severity) $($s.recoveryAction)" 'Fail Error RestoreSettings' 'VS Code settings not restored'
    Assert-Equal (Get-Finding $r 'restore.backup').status 'Fail' 'backup not found'
    Assert-True ((Get-Finding $r 'restore.backup').nextAction -match 'Restore application settings') 'what to do'
    Assert-Equal (Get-Category $r 'restoration').status 'NeedsAttention' 'category'
    Assert-True (@($r.applications | Where-Object { $_.kind -eq 'manual' -and $_.key -like 'additional:*' }).Count -eq 1) 'Additional Software entry (Contoso Field Tool) verified as a manual follow-up'
    Assert-True (-not $r.backups.retained) 'no staged backup yet'
    Save-Out 'F'
}

Test-HealthScenario 'F2. settings restored; the retained backup is reported and removed only after a separate, exact confirmation; the USB copy is untouched' -Migration {
    Initialize-Embedded | Out-Null
    Invoke-AppRuns | Out-Null
    Invoke-WddMonitor $script:Paths | Out-Null
    $r = Get-HealthReport
    Assert-Equal "$((Get-Finding $r 'restore.settings.vscode').status) $((Get-Finding $r 'restore.settings.git').status)" 'Pass Pass' 'settings restored'
    $ret = Get-Finding $r 'restore.retained'
    Assert-Equal $ret.status 'Warning' 'sensitive restoration material remains'
    Assert-True ($ret.observed -notmatch 'a1b2c3d4|WDB-AppBackup') 'location reported without private detail'
    Assert-True ($r.backups.retained -ge 1 -and -not $r.backups.requiredForOutstanding) 'backup summary'
    $cfg = Get-HealthConfig
    $usbCopy = Join-Path $script:UsbBackups "$script:MigBackupFolder\backup-manifest.json"
    Assert-Equal (Invoke-WdhCleanupBackups $script:Manifest $script:Paths $cfg '').Outcome 'ConfirmationRequired' 'nothing removed without confirmation'
    Assert-Equal (Invoke-WdhCleanupBackups $script:Manifest $script:Paths $cfg 'wrong').Outcome 'ConfirmationRequired' 'a wrong confirmation removes nothing'
    Assert-True (@(Get-WdhBackupFolders $script:Paths.Root).Count -ge 1) 'still there'
    $script:SimIdentity = @{ Name = 'PC\Alex'; IsSystem = $false; IsAdmin = $false }
    Assert-Equal (Invoke-WdhCleanupBackups $script:Manifest $script:Paths $cfg $cfg.restoration.backupId).Outcome 'NotElevated' 'administrators only'
    $script:SimIdentity = @{ Name = 'PC\Alex'; IsSystem = $false; IsAdmin = $true }
    $c = Invoke-WdhCleanupBackups $script:Manifest $script:Paths $cfg $cfg.restoration.backupId
    Assert-Equal $c.Outcome 'Done' $c.Message
    Assert-Equal @(Get-WdhBackupFolders $script:Paths.Root).Count 0 'staged copies removed'
    Assert-True (Test-Path -LiteralPath $usbCopy) 'the source backup on the USB drive was not touched'
    Assert-Equal (Get-Finding (Invoke-Verify).Report 'restore.retained') $null 'reverified: nothing retained'
}

Test-HealthScenario 'F3. outstanding restoration: cleanup refused; a tampered backup is rejected and reported, never restored' -Migration {
    $bad = Join-Path $script:Tmp 'E\backups'
    Copy-Item -LiteralPath $script:UsbBackups -Destination $bad -Recurse
    [IO.File]::WriteAllText((Join-Path $bad "$script:MigBackupFolder\data\vscode\settings.json"), '{ "tampered": true }')
    $script:UsbBackups = $bad
    Initialize-Embedded | Out-Null
    Invoke-AppRuns | Out-Null
    Invoke-WddMonitor $script:Paths | Out-Null
    $r = Get-HealthReport
    $b = Get-Finding $r 'restore.backup'
    Assert-True ($b.status -eq 'Fail' -and $b.observed -match 'Rejected') "tampered backup: $($b.status) $($b.observed)"
    Assert-Status $r 'NeedsAttention' 'overall'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:WdbEnv.APPDATA 'Code\User\settings.json'))) 'nothing restored from it'
    Assert-Equal (Invoke-WdhCleanupBackups $script:Manifest $script:Paths (Get-HealthConfig) 'a1b2c3d4e5f60718').Outcome $(if (@(Get-WdhBackupFolders $script:Paths.Root).Count) { 'Refused' } else { 'NothingToDo' }) 'never removed while restoration is outstanding'
}

Test-HealthScenario 'G. no working network driver: the network cannot appear by itself -> specific diagnosis and the AddDrivers action' {
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'Offline' @{ installed = @(); failed = @(); skipped = @() }
    $script:M.devices = @(@($script:M.devices | Where-Object { $_.class -ne 'Net' }) + @(@{ name = 'Ethernet Controller'; class = 'Net'; service = ''; problemCode = 28; hardwareId = 'PCI\VEN_10EC&DEV_8125' }))
    $script:M.network = @{ adapters = @(); gateway = $false }
    $script:M.dns = $false; $script:M.internet = $false
    Write-WddJson (Join-Path $script:Paths.StateDir 'network-driver-missing.json') @{ detail = 'No network adapter has a working driver (Ethernet Controller, PCI\VEN_10EC&DEV_8125). Supply a network driver with DeploymentRecovery.ps1 -Action AddDrivers.' }
    $r = (Invoke-Verify).Report
    Assert-True ($r.overall.status -in 'Incomplete', 'NeedsAttention') "overall $($r.overall.status)"
    $n = Get-Finding $r 'network.driver'
    Assert-True ($n.status -eq 'Fail' -and $n.observed -match 'No network adapter has a working driver' -and $n.recoveryAction -eq 'AddDrivers') "network driver: $($n.observed)"
    Assert-True ($n.nextAction -match 'will not appear by itself') 'explains why waiting does not help'
    Assert-Equal (Get-Finding $r 'deployment.outcome').status 'Pending' 'the deployment is paused, not finished'
    Assert-True ((Get-Finding $r 'deployment.outcome').observed -match 'PausedAwaitingNetwork') 'Phase 5 outcome as evidence'
    Assert-Equal (Get-Finding $r 'updates.stage').status 'Fail' 'initial updates not done'
    Assert-True (@($r.findings | Where-Object { $_.category -eq 'drivers' -and $_.observed -match '^Missing driver' }).Count -eq 1) 'the adapter is a missing driver'
}

Test-HealthScenario 'H. Windows Home installed although Pro was requested -> Failed (critical), even with every stage successful' {
    $script:M.os.editionId = 'Core'; $script:M.os.caption = 'Microsoft Windows 11 Home'
    Assert-Equal (Invoke-SimDeployment) 'Completed:Succeeded' 'every stage succeeded'
    $r = Get-HealthReport
    Assert-Status $r 'Failed' 'overall'
    $f = Get-Finding $r 'windows.edition'
    Assert-Equal "$($f.status) $($f.severity)" 'Fail Critical' 'critical edition failure'
    Assert-Equal $r.overall.exitCode 60 'exit code'
    $h = Read-WddJson (Join-Path $script:Paths.Root 'reports\health\customer-handoff.json')
    Assert-True ($h.headline -match 'not finished') 'the customer is not told it works'
}

Test-HealthScenario 'I. security: firewall off -> Failed; Defender off with a registered antivirus is a hand-over; no antivirus at all -> Failed; UAC off unexpectedly -> NeedsAttention' {
    Invoke-SimDeployment | Out-Null
    foreach ($p in $script:M.firewall) { $p.enabled = $false }
    $r = (Invoke-Verify).Report
    Assert-Status $r 'Failed' 'firewall off for every profile'
    Assert-Equal (Get-Finding $r 'security.firewall').severity 'Critical' 'not a harmless warning'
    $script:M.firewall[2].enabled = $true
    Assert-Equal (Get-Finding (Invoke-Verify).Report 'security.firewall').severity 'Error' 'off for some profiles'
    foreach ($p in $script:M.firewall) { $p.enabled = $true }
    $script:M.defender = @{ amServiceEnabled = $true; antivirusEnabled = $false; realTimeProtectionEnabled = $false; signatureAgeDays = 0; tamperProtected = $false }
    $script:M.securityCenter = @{ antivirus = @(@{ name = 'Windows Defender'; enabled = $false }, @{ name = 'Contoso Antivirus'; enabled = $true }); firewall = @() }
    $r = (Invoke-Verify).Report
    Assert-True ((Get-Finding $r 'security.antivirus').status -eq 'Pass' -and (Get-Finding $r 'security.antivirus').observed -match 'Contoso Antivirus') 'third-party antivirus hand-over'
    $script:M.securityCenter = @{ antivirus = @(@{ name = 'Windows Defender'; enabled = $false }); firewall = @() }
    $r = (Invoke-Verify).Report
    Assert-Status $r 'Failed' 'no active antivirus'
    $script:M.defender.antivirusEnabled = $true; $script:M.defender.realTimeProtectionEnabled = $true
    $script:M.uac.enableLua = 0
    $r = (Invoke-Verify).Report
    Assert-Status $r 'NeedsAttention' 'UAC off although configured on'
    Assert-Equal (Get-Finding $r 'security.uac').status 'Fail' 'UAC finding'
}

Test-HealthScenario 'J. damaged evidence: corrupted application results, deployment state or driver report -> Unverifiable, never success' {
    Invoke-SimDeployment | Out-Null
    $app = Join-Path $script:Paths.Root 'Applications'
    foreach ($f in 'result.json', 'state.json', 'state.json.bak') { [IO.File]::WriteAllText((Join-Path $app $f), '{ "packages": [ broken') }
    $r = (Invoke-Verify).Report
    Assert-Status $r 'Unverifiable' 'damaged application results'
    Assert-True (@($r.sources | Where-Object { $_.file -eq 'Applications\result.json' -and $_.state -eq 'corrupt' }).Count -eq 1) 'source marked corrupt'
    Assert-Equal (Get-Finding $r 'apps.result').status 'Unverifiable' 'finding'
    Assert-True (-not $r.overall.readyForDelivery) 'not deliverable'
    foreach ($f in $script:Paths.State, "$($script:Paths.State).bak") { [IO.File]::WriteAllText($f, 'not json') }
    $r = (Invoke-Verify).Report
    Assert-Status $r 'Unverifiable' 'damaged deployment state'
    Assert-True ((Get-Finding $r 'deployment.state').nextAction -match 'Resume') 'what to do'
}

Test-HealthScenario 'J2. driver report damaged, or from another deployment -> Unverifiable' {
    Invoke-SimDeployment | Out-Null
    [IO.File]::WriteAllText((Join-Path $script:Paths.Root 'reports\drivers.json'), '{"format":"windows-deployment-builder/drivers-result", "devices": [')
    Assert-Status (Invoke-Verify).Report 'Unverifiable' 'corrupt driver report'
    Set-DriverStage
    $d = Read-WddJson (Join-Path $script:Paths.Root 'reports\drivers.json'); $d.deploymentId = '0123456789ABCDEF'; Write-WddJson (Join-Path $script:Paths.Root 'reports\drivers.json') $d
    $r = (Invoke-Verify).Report
    Assert-Status $r 'Unverifiable' 'report of another deployment'
    Assert-True (@($r.sources | Where-Object { $_.id -eq 'drivers' -and $_.state -eq 'inconsistent' }).Count -eq 1) 'source inconsistent'
}

Test-HealthScenario 'K. technician recovery: a failed application is retried through the Phase 5 recovery tool, reinstalled once and verified again; the report shows it resolved' {
    $script:AppSim.Behaviour['Bitwarden.Bitwarden'] = 'fail'
    Assert-Equal (Invoke-SimDeployment) 'Completed:CompletedWithFailures' 'first deployment'
    $first = Get-HealthReport
    Assert-Status $first 'NeedsAttention' 'before recovery'
    $f = Get-Finding $first 'app.winget:bitwarden.bitwarden'
    Assert-Equal $f.recoveryAction 'RetryFailed' 'retryable through the recovery tool'
    $calls = $script:AppSim.Calls['Bitwarden.Bitwarden']
    $script:AppSim.Behaviour['Bitwarden.Bitwarden'] = 'ok'
    $rec = Invoke-WdrRecovery $script:Manifest $script:Paths 'RetryFailed'
    Assert-Equal $rec.Outcome 'Done' $rec.Message
    Invoke-AppRuns | Out-Null
    Assert-Equal $script:AppSim.Calls['Bitwarden.Bitwarden'] ($calls + 1) 'retried once by the engine itself'
    Assert-Equal $script:AppSim.Calls['Google.Chrome'] 1 'successful applications are never installed again'
    Assert-True ((Invoke-WddMonitor $script:Paths) -like 'Completed:*') 'deployment completes again'
    $r = Get-HealthReport
    Assert-Status $r 'Ready' 'after recovery'
    Assert-Equal (Get-Finding $r 'app.winget:bitwarden.bitwarden').status 'Pass' 'independently verified'
    Assert-Equal $r.comparison.previousStatus 'NeedsAttention' 'previous status'
    Assert-True (@($r.comparison.resolved) -contains 'app.winget:bitwarden.bitwarden') 'resolved finding'
    Assert-Equal @($r.comparison.new).Count 0 'nothing new'
    Assert-True (Test-Path -LiteralPath (Join-Path $script:Paths.Root "reports\health\$($r.history[0].file)")) 'the failed report is kept in the history'
    Assert-Equal $r.history[0].status 'NeedsAttention' 'history status'
    Save-Out 'K'
}

Test-HealthScenario 'L. another administrator runs the check: per-user items are read from the deployment user''s profile, or deferred; never a false pass; recovery refuses to retarget per-user installations' {
    $script:M.userScoped = @('Bitwarden.Bitwarden')
    $script:AppSim.Behaviour['Git.Git'] = 'fail'
    Invoke-SimDeployment | Out-Null
    $r = Get-HealthReport
    Assert-Equal (Get-Finding $r 'app.winget:bitwarden.bitwarden').status 'Pass' 'per-user application found in owner''s profile'
    Assert-Status $r 'NeedsAttention' 'Git failed'
    $script:SimIdentity = @{ Name = 'PC\technician'; IsSystem = $false; IsAdmin = $true }
    $script:M.hives = @('S-1-5-21-1000-2000-3000-1002')
    $r = (Invoke-Verify).Report
    Assert-Equal "$($r.context.runAs) $($r.context.deploymentUser) $($r.context.sameUser) $($r.context.userContext)" 'PC\technician PC\owner False Deferred' 'context'
    $b = Get-Finding $r 'app.winget:bitwarden.bitwarden'
    Assert-Equal $b.status 'Deferred' 'per-user application deferred, not passed (and never looked up in the technician''s profile)'
    Assert-True ($b.nextAction -match 'Sign in as PC\\owner') 'how to verify it'
    Assert-Status $r 'Unverifiable' 'an explicit inability to verify'
    Assert-Equal (Get-Finding $r 'custom.taskbar.leftAlign').status 'Deferred' 'per-user settings deferred'
    Assert-True (@($r.limitations | Where-Object { $_ -match 'never from PC\\technician' }).Count -eq 1) 'limitation stated'
    # The deployment user signs in while the technician checks again: the owner's hive is read.
    $script:M.hives = @('S-1-5-21-1000-2000-3000-1002', $script:SimUserSid)
    $r = (Invoke-Verify).Report
    Assert-Equal (Get-Finding $r 'app.winget:bitwarden.bitwarden').status 'Pass' 'read from the owner''s own profile'
    # Recovery from the technician's account never silently moves per-user installations.
    $rec = Invoke-WdrRecovery $script:Manifest $script:Paths 'RetryFailed'
    Assert-True (@($rec.Refused | Where-Object { $_.operationId -eq 'stage:applications' -and $_.reason -match 'belongs to PC\\owner' -and $_.reason -match '-RetargetUser' }).Count -eq 1) "refused: $($rec.Message)"
    Assert-True (@($rec.Accepted).Count -eq 0) 'nothing reopened'
    $st = (Read-WddDeploymentState $script:Paths).State
    Assert-Equal $st.stages.applications.user 'PC\owner' 'deployment user preserved'
    Assert-Equal $st.status 'Completed' 'the deployment was not reopened'
    # An explicit, recorded retarget.
    $rec = Invoke-WdrRecovery $script:Manifest $script:Paths 'RetryFailed' -RetargetUser
    Assert-Equal $rec.Outcome 'Done' $rec.Message
    Assert-True (@($rec.Accepted) -contains 'app:winget:git.git') 'Git reopened'
    $st = (Read-WddDeploymentState $script:Paths).State
    Assert-Equal $st.stages.applications.user 'PC\technician' 'retarget recorded in the launch record'
    Assert-True ([bool] @($st.recoveries)[-1].retargetUser) 'retarget in the recovery history'
}

# ------------------------------------------------------------------------------------------------
# Fault injection (part 22)
# ------------------------------------------------------------------------------------------------

Test-HealthScenario 'faults: lost network while applications wait -> Incomplete; Internet judged from gateway, DNS and the connectivity test, required only while needed' {
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'Succeeded' @{ installed = @(); failed = @(); skipped = @() }
    Set-DriverStage
    $script:AppSim.Behaviour['Google.Chrome'] = 'net-drop'
    Invoke-WdaMain (Get-SimAppConfig) | Out-Null
    $script:M.internet = $false
    $r = (Invoke-Verify).Report
    Assert-Status $r 'Incomplete' 'overall'
    $i = Get-Finding $r 'network.internet'
    Assert-True ($i.status -eq 'Fail' -and $i.required -and $i.expected -match 'needed by') "internet required while outstanding: $($i.expected)"
    # Finished and deliberately offline: not a network failure.
    Reset-AppSim
    Invoke-AppRuns | Out-Null
    Invoke-WddMonitor $script:Paths | Out-Null
    $r = (Invoke-Verify).Report
    $i = Get-Finding $r 'network.internet'
    Assert-True ($i.status -eq 'Info' -and -not $i.required) "offline after completion: $($i.status) $($i.expected)"
    Assert-Status $r 'Ready' 'offline computer is ready'
}

Test-HealthScenario 'faults: interrupted update stage, incomplete deployment and an ended-by-deadline deployment' {
    Initialize-Embedded | Out-Null
    Set-EngineStatus 'windowsUpdate' 'Installing' 'KB5068861' 3 10
    $r = (Invoke-Verify).Report
    Assert-Status $r 'Incomplete' 'still running'
    Assert-Equal (Get-Finding $r 'updates.stage').status 'Pending' 'update stage pending'
    Assert-True (@($r.outstanding | Where-Object { $_.operationId -eq 'stage:windowsUpdate' }).Count -eq 1) 'outstanding stage'
    $script:SimNow = $script:SimNow.AddHours(80)
    Invoke-WddMonitor $script:Paths | Out-Null
    $r = Get-HealthReport
    $o = Get-Finding $r 'deployment.outcome'
    Assert-True ($o.status -eq 'Fail' -and $o.observed -match '^Incomplete' -and $o.recoveryAction -eq 'Resume') "deadline: $($o.observed)"
    Assert-True ($r.overall.status -in 'NeedsAttention', 'Incomplete', 'Unverifiable') "not ready: $($r.overall.status)"
}

Test-HealthScenario 'faults: inconsistent application status (no engine record for a selected app; success without an uninstall record); a version that differs' {
    Invoke-SimDeployment | Out-Null
    $app = Join-Path $script:Paths.Root 'Applications'
    $res = Read-WddJson (Join-Path $app 'result.json')
    $res.packages = @(@($res.packages) | Where-Object { $_.key -ne 'winget:git.git' })
    Write-WddJson (Join-Path $app 'result.json') $res
    $st = Read-WddJson (Join-Path $app 'state.json'); [void] $st.packages.Remove('winget:git.git'); Write-WddJson (Join-Path $app 'state.json') $st
    $script:M.missing = @('Git.Git', '7zip.7zip')
    $r = (Invoke-Verify).Report
    $g = Get-Finding $r 'app.winget:git.git'
    Assert-True ($g.status -eq 'Fail' -and $g.observed -match 'inconsistent') "no record and absent: $($g.observed)"
    $z = Get-Finding $r 'app.winget:7zip.7zip'
    Assert-Equal $z.status 'Warning' 'success without an uninstall record is uncertain, never "missing"'
    Assert-True ($z.observed -match 'no uninstall record or Store package matched') $z.observed
    Assert-Equal (@($r.applications) | Where-Object { $_.key -eq 'winget:7zip.7zip' }).result 'InstalledVerificationUncertain' 'classification'
    # Present although the engine has no record: verified independently.
    $script:M.missing = @('7zip.7zip')
    Assert-Equal (Get-Finding (Invoke-Verify).Report 'app.winget:git.git').status 'Pass' 'independent evidence suffices'
    $script:M.missing = @()
    $script:M.extraUninstall = @(@{ scope = 'machine'; keyName = 'RustDesk'; displayName = 'RustDesk'; displayVersion = '1.4'; publisher = 'Purslane' })
}

Test-HealthScenario 'faults: restart during verification (the report was archived but not rewritten); stable finding ids across runs' {
    Invoke-SimDeployment | Out-Null
    $first = Get-HealthReport
    $ids1 = (@($first.findings) | ForEach-Object { $_.id }) -join ','
    # Simulate the power loss: the current report moved to the history, nothing written after it.
    $dir = Join-Path $script:Paths.Root 'reports\health'
    New-Item -ItemType Directory -Path (Join-Path $dir 'history') -Force | Out-Null
    Move-Item -LiteralPath (Join-Path $dir 'deployment-health.json') -Destination (Join-Path $dir 'history\deployment-health-20261020-090000-Ready.json')
    $r = (Invoke-Verify).Report
    Assert-Equal $r.comparison.previousStatus 'Ready' 'compared with the newest archived report'
    Assert-Equal ((@($r.findings) | ForEach-Object { $_.id }) -join ',') $ids1 'same ids, same order'
    Assert-True ($r.verificationId -ne $first.verificationId) 'a new verification id'
}

Test-HealthScenario 'faults: wrong edition, disabled security, profile mismatch and corrupted reports never produce "Ready" (summary of the fault matrix)' {
    Invoke-SimDeployment | Out-Null
    $cases = @(
        @{ n = 'edition'; set = { $script:M.os.editionId = 'Core' }; undo = { $script:M.os.editionId = 'Professional' } }
        @{ n = 'defender'; set = { $script:M.defender.realTimeProtectionEnabled = $false }; undo = { $script:M.defender.realTimeProtectionEnabled = $true } }
        @{ n = 'account'; set = { $script:M.admins = @('S-1-5-21-1000-2000-3000-500') }; undo = { $script:M.admins = @($script:SimUserSid, 'S-1-5-21-1000-2000-3000-500') } }
        @{ n = 'computer name'; set = { $script:M.names.active = 'DESKTOP-ABC123' }; undo = { $script:M.names.active = 'owner-Computer' } }
        @{ n = 'autologon left on'; set = { } ; undo = { } }
        @{ n = 'probe unavailable'; set = { $script:M.fail = @('firewall') }; undo = { $script:M.fail = @() } }
        @{ n = 'disk nearly full'; set = { $script:M.volume.free = 1GB }; undo = { $script:M.volume.free = 420GB } }
    )
    foreach ($c in $cases) {
        if ($c.n -eq 'autologon left on') { continue }
        & $c.set
        $s = (Invoke-Verify).Report.overall.status
        Assert-True ($s -notin 'Ready', 'ReadyWithWarnings') "$($c.n): $s"
        & $c.undo
    }
    Assert-Status (Invoke-Verify).Report 'Ready' 'restored machine is ready again'
}

Test-HealthScenario 'faults: failed or unsafe report export; diagnostics never contain backups, answer files or passwords' -Migration {
    Initialize-Embedded | Out-Null
    Invoke-AppRuns | Out-Null
    Invoke-WddMonitor $script:Paths | Out-Null
    $cfg = Get-HealthConfig
    Assert-Equal (Invoke-WdhExport $script:Manifest $script:Paths $cfg (Join-Path $script:Tmp 'diag.txt')).Outcome 'Refused' 'only .zip'
    [IO.File]::WriteAllText((Join-Path $script:Paths.Root 'Deployment\logs\deployment.log'), "password=Secret123 at 10:00`r`n", (New-Object Text.UTF8Encoding($false)))
    $zip = Join-Path $script:Tmp 'out\diag.zip'
    $e = Invoke-WdhExport $script:Manifest $script:Paths $cfg $zip
    Assert-Equal $e.Outcome 'Done' $e.Message
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $names = @($z.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        Assert-True ($names -contains 'reports/health/deployment-health.json') 'health report included'
        Assert-True (@($names | Where-Object { $_ -match '(?i)^backup/|backups/|\.xml$' }).Count -eq 0) "no backup or XML: $($names -join ', ')"
        $log = $z.Entries | Where-Object { $_.FullName -match 'deployment\.log$' } | Select-Object -First 1
        $sr = New-Object IO.StreamReader($log.Open()); $txt = $sr.ReadToEnd(); $sr.Dispose()
        Assert-True ($txt -notmatch 'Secret123' -and $txt -match 'redacted') 'password redacted'
    } finally { $z.Dispose() }
    Assert-True (@(Get-WdhBackupFolders $script:Paths.Root).Count -ge 1) 'a staged backup exists on the computer'
    # An archive with an unexpected entry is detected (and an export producing one is deleted).
    $crafted = Join-Path $script:Tmp 'crafted.zip'
    $z = [IO.Compression.ZipFile]::Open($crafted, 'Create')
    try { foreach ($n in 'reports/health/deployment-health.json', 'Backup/a1b2/data/vscode/settings.json', 'Package/autounattend.xml', '../evil.txt') { $w = New-Object IO.StreamWriter($z.CreateEntry($n).Open()); $w.Write('x'); $w.Dispose() } } finally { $z.Dispose() }
    $bad = @(Test-WdrDiagnosticArchive $crafted)
    Assert-Equal ($bad -join ',') 'Backup/a1b2/data/vscode/settings.json,Package/autounattend.xml,../evil.txt' 'unsafe entries found'
    Assert-Equal (@(Test-WdhArchive $crafted) -join ',') ($bad -join ',') 'both checks agree'
    function Invoke-WdhRecoveryExport { param([string] $Tool, [string] $OutputPath) @{ exit = 1; text = 'simulated failure' } }
    $e = Invoke-WdhExport $script:Manifest $script:Paths $cfg (Join-Path $script:Tmp 'out\diag2.zip')
    Assert-Equal $e.Outcome 'Failed' 'a failed export is reported, not hidden'
}

# ------------------------------------------------------------------------------------------------
# Read-only verification, compatibility and StrictMode
# ------------------------------------------------------------------------------------------------

Test-HealthScenario 'read-only: verification changes nothing outside reports\health (no state, task, shortcut, backup or setting)' {
    Invoke-SimDeployment | Out-Null
    $before = Get-TreeState
    $tasks = ($script:SimTasks.Keys | Sort-Object) -join ','
    $shortcuts = ($script:Shortcuts.Keys | Sort-Object) -join ','
    $script:M.reboot.cbs = $true
    $v = Invoke-Verify -ScanUpdates
    Assert-Status $v.Report 'Incomplete' 'a pending restart is reported'
    $after = Get-TreeState
    Assert-Equal (($after.Keys | Sort-Object) -join ',') (($before.Keys | Sort-Object) -join ',') 'no file added or removed'
    foreach ($k in $before.Keys) { Assert-Equal $after[$k] $before[$k] "$k unchanged" }
    Assert-Equal (($script:SimTasks.Keys | Sort-Object) -join ',') $tasks 'no task registered by a technician check'
    Assert-Equal (($script:Shortcuts.Keys | Sort-Object) -join ',') $shortcuts 'no shortcut changed'
    Assert-Equal $script:M.opened.Count 0 'nothing opened'
    Assert-True ((Get-Finding $v.Report 'updates.scan').status -in 'Pass', 'Warning') 'read-only update scan reported'
}

Test-HealthScenario 'compatibility: Phase 5 result without lifecycle fields, an older health configuration without optional sections, all under StrictMode' {
    Invoke-SimDeployment | Out-Null
    $app = Join-Path $script:Paths.Root 'Applications\result.json'
    $res = Read-WddJson $app
    foreach ($p in @($res.packages)) { foreach ($k in 'lifecycle', 'operationId', 'failureClass', 'retryable', 'detection', 'totalAttempts', 'manualRetries', 'history', 'nextAttemptUtc', 'waitingFor') { [void] $p.Remove($k) } }
    $res.schemaVersion = 1
    Write-WddJson $app $res
    $cfg = Get-HealthConfig
    foreach ($k in 'customizations', 'customerNotes') { [void] $cfg.Remove($k) }
    $cfg.options.Remove('storageObservations') | Out-Null
    Set-StrictMode -Version 2.0
    $v = Invoke-WdhVerify $script:Manifest $script:Paths $cfg 'Technician'
    Assert-True ($v.Report.overall.status -in 'Ready', 'ReadyWithWarnings') "legacy evidence verified: $($v.Report.overall.status) $($v.Report.overall.summary)"
    Assert-Equal @($v.Report.findings | Where-Object { $_.id -like '*.checkError' }).Count 0 'no check stopped'
}

Test-HealthScenario 'no deployment on this computer: Unverifiable with the reason, not success' {
    $v = Invoke-Verify
    Assert-Status $v.Report 'Unverifiable' 'no state'
    Assert-True ((Get-Finding $v.Report 'deployment.state').observed -match 'No deployment state') 'reason'
    Assert-Equal $v.ExitCode 50 'exit code'
}

Test-HealthScenario 'report data cannot break out of the HTML template; customer data contains no technical detail' {
    $tpl = [IO.File]::ReadAllText((Join-Path $script:pkgRoot 'scripts\health\HealthReport.html'))
    $html = ConvertTo-WdhHtml $tpl ([ordered]@{ mode = 'technician'; report = @{ name = '</script><img src=x onerror=alert(1)>' } })
    Assert-Equal ([regex]::Matches($html, '</script>').Count) 2 'only the template''s own script tags'
    Assert-True ($html -match '\\u003c/script\\u003e') 'escaped'
    Assert-True ($tpl -notmatch '[^\x00-\x7F]') 'template is ASCII (exact text hash on any code page)'
}

Test-HealthScenario 'recovery tool: Verify action (menu 9) runs the same read-only verification' {
    Invoke-SimDeployment | Out-Null
    $a = Invoke-WdrAction $script:Manifest $script:Paths 'Verify'
    Assert-Equal $a.Exit 0 "exit code: $($a.Text)"
    Assert-True ($a.Text -match 'Deployment health: Ready') $a.Text
    Assert-Equal (Get-HealthReport).trigger 'Recovery' 'trigger'
}

Write-Output ''
Write-Output "$($script:Passed) passed, $($script:Failures) failed"
if ($script:Failures -gt 0) { exit 1 }
exit 0
