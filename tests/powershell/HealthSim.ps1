#Requires -Version 5.1
<#
    Phase 9: a simulated computer for DeploymentHealth.ps1. Every probe of Windows (edition,
    accounts, devices, uninstall records, Store packages, Defender, firewall, encryption, network,
    storage, registry) answers from $script:M, which Reset-HealthSim fills with a healthy Windows 11
    Pro computer that matches the fixture package's own health-config.json (its account and computer
    name). Applications are "installed" exactly when the simulated WinGet of ProvisioningSim.ps1
    installed them, so the health engine checks what the REAL application engine did.

    Scenarios change $script:M (wrong edition, a device error, firewall off, a missing application,
    a pending restart, another administrator signed in ...). Nothing on this computer is read or
    changed; probes listed in $script:M.fail throw, as an unavailable Windows component would.
#>

function Reset-HealthSim {
    $cfg = Read-WddJson (Join-Path $script:pkgRoot 'scripts\health\health-config.json')
    $user = $(if ($cfg -and $cfg.account.username) { [string] $cfg.account.username } else { 'Alex' })
    $sid = 'S-1-5-21-1000-2000-3000-1001'
    $script:SimUserSid = $sid
    $reg = @{}
    if ($cfg) {
        foreach ($c in @($cfg.customizations)) {
            if (-not $c) { continue }
            $k = $(if ($c.scope -eq 'user') { "HKU\$sid\$($c.registry.path)\$($c.registry.name)" } else { "HKLM\$($c.registry.path)\$($c.registry.name)" })
            $reg[$k] = [int] $c.registry.expected
        }
    }
    $script:M = @{
        os             = @{ caption = 'Microsoft Windows 11 Pro'; editionId = 'Professional'; displayVersion = '25H2'; build = 26200; ubr = 6899; architecture = 'amd64'; productType = 1; lastBootUtc = '2026-10-20T07:55:00.0000000Z' }
        setup          = @{ imageState = 'IMAGE_STATE_COMPLETE'; oobeInProgress = 0; systemSetupInProgress = 0 }
        activation     = @{ available = $true; licenseStatus = 1; channel = 'OEM' }
        names          = @{ active = $(if ($cfg -and $cfg.identity.computerName) { [string] $cfg.identity.computerName } else { 'DESKTOP-SIM1234' }); pending = '' }
        users          = @(@{ name = $user; sid = $sid; enabled = $true }, @{ name = 'Administrator'; sid = 'S-1-5-21-1000-2000-3000-500'; enabled = $false }, @{ name = 'Guest'; sid = 'S-1-5-21-1000-2000-3000-501'; enabled = $false })
        admins         = @($sid, 'S-1-5-21-1000-2000-3000-500')
        profiles       = @('S-1-5-18', 'S-1-5-19', 'S-1-5-20', $sid)
        autologon      = @{ autoAdminLogon = '1'; autoLogonCount = $null; userName = $user; passwordStored = $true }
        sids           = @{ ($user.ToLowerInvariant()) = $sid; 'technician' = 'S-1-5-21-1000-2000-3000-1002' }
        hives          = @($sid)
        services       = @{ wuauserv = @{ startMode = 'Manual'; state = 'Running' }; WinDefend = @{ startMode = 'Auto'; state = 'Running' }; mpssvc = @{ startMode = 'Auto'; state = 'Running' } }
        defender       = @{ amServiceEnabled = $true; antivirusEnabled = $true; realTimeProtectionEnabled = $true; signatureAgeDays = 0; tamperProtected = $true }
        securityCenter = @{ antivirus = @(@{ name = 'Windows Defender'; enabled = $true }); firewall = @() }
        firewall       = @(@{ name = 'Domain'; enabled = $true }, @{ name = 'Private'; enabled = $true }, @{ name = 'Public'; enabled = $true })
        uac            = @{ enableLua = 1; consentPromptBehaviorAdmin = 5; promptOnSecureDesktop = 0 }
        smartScreen    = @{ explorer = ''; policy = $null }
        encryption     = @{ volumeStatus = 'FullyDecrypted'; protectionStatus = 'Off'; percentage = 0.0; protectors = @() }
        reboot         = @{ cbs = $false; windowsUpdate = $false; agent = $false; fileRenames = 2 }
        updateAgent    = @{ lastSearchUtc = '2026-10-20T09:40:00.0000000Z'; lastInstallUtc = '2026-10-20T09:30:00.0000000Z' }
        updateScan     = @{ required = 0; optional = 2; drivers = 1; feature = 0; titles = @() }
        devices        = @(
            @{ name = 'Intel(R) Ethernet Controller I225-V'; class = 'Net'; service = 'e2f'; problemCode = 0; hardwareId = 'PCI\VEN_8086&DEV_15F3&SUBSYS_00008086&REV_03' }
            @{ name = 'NVIDIA GeForce RTX 3060'; class = 'Display'; service = 'nvlddmkm'; problemCode = 0; hardwareId = 'PCI\VEN_10DE&DEV_2504&SUBSYS_397D1462&REV_A1' }
            @{ name = 'Standard NVM Express Controller'; class = 'SCSIAdapter'; service = 'stornvme'; problemCode = 0; hardwareId = 'PCI\VEN_144D&DEV_A80C&SUBSYS_A801144D&REV_00' }
            @{ name = 'Realtek High Definition Audio'; class = 'MEDIA'; service = 'IntcAzAudAddService'; problemCode = 0; hardwareId = 'HDAUDIO\FUNC_01&VEN_10EC&DEV_0897&SUBSYS_1462D817&REV_1001' }
            @{ name = 'Microsoft Bluetooth Enumerator'; class = 'Bluetooth'; service = 'BthEnum'; problemCode = 0; hardwareId = 'BTH\MS_BTHBRB' }
        )
        extraUninstall = @()
        missing        = @()
        # Packages whose installer registers per user (in the deployment user's hive), whatever the catalog says.
        userScoped     = @()
        network        = @{ adapters = @(@{ description = 'Intel(R) Ethernet Controller I225-V'; status = 'Up'; wireless = $false }); gateway = $true }
        dns            = $true
        internet       = $true
        tcp            = $true
        volume         = @{ fileSystem = 'NTFS'; health = 'Healthy'; operational = 'OK'; size = 500GB; free = 420GB; dirty = $false }
        physicalDisks  = @(@{ name = 'Samsung SSD 990 PRO 1TB'; media = 'SSD'; bus = 'NVMe'; health = 'Healthy'; operational = 'OK'; reliability = @{ wear = 1; temperature = 38; readErrorsUncorrected = 0 } })
        reg            = $reg
        fail           = @()
        opened         = New-Object System.Collections.Generic.List[string]
        # Health engine 1.1.0 probes: display adapters, processors, chassis, the Windows Update history
        # and the orchestrator's last scan. Every suite that runs the audit uses these, so nothing on
        # this computer is read.
        videoControllers = @(@{ name = 'NVIDIA GeForce RTX 3060'; pnpDeviceId = 'PCI\VEN_10DE&DEV_2504&SUBSYS_397D1462&REV_A1\4&2A5A3C1&0&0008' })
        processors     = @(@{ name = 'Intel(R) Core(TM) i7-12700K'; manufacturer = 'GenuineIntel' })
        chassis        = @{ chassisTypes = @(3); battery = $false }
        updateHistory  = @()
        HistoryQueries = 0
        orchestrator   = @{ lastSuccessfulScanUtc = '2026-10-20T09:41:00.0000000Z'; isScanning = $false; isWorking = $false }
        # Health engine 1.2.0 probes (package-aware verification): the deployment user's profile folder,
        # files (path -> file version), Store packages registered for the user beyond the simulated
        # installs, provisioned packages, the machine folders and a read-only "winget upgrade" listing.
        profilePaths   = @{ $sid = "C:\Users\$user" }
        files          = @{}
        extraAppx      = @()
        provisioned    = @()
        machineFolders = @{ ProgramFiles = 'C:\Program Files'; ProgramFilesX86 = 'C:\Program Files (x86)'; ProgramData = 'C:\ProgramData' }
        wingetUpgrade  = @{ available = $true; exitCode = 0; text = "Name   Id      Version Available Source`n--------------------------------------`n0 upgrades available." }
        WinGetCalls    = 0
    }
}

function Assert-SimProbe { param([string] $Name) if ($script:M.fail -contains $Name) { throw "simulated: $Name is not available" } }

function Get-WdhOsInfo { Assert-SimProbe 'os'; $script:M.os }
function Get-WdhSetupState { Assert-SimProbe 'setup'; $script:M.setup }
function Get-WdhActivation { Assert-SimProbe 'activation'; $script:M.activation }
function Get-WdhComputerNames { Assert-SimProbe 'computerName'; @{ active = $script:M.names.active; pending = $(if ($script:M.names.pending) { $script:M.names.pending } else { $script:M.names.active }) } }
function Get-WdhLocalUsers { Assert-SimProbe 'users'; @($script:M.users) }
function Get-WdhAdminMembers { Assert-SimProbe 'admins'; @($script:M.admins) }
function Get-WdhProfileSids { @($script:M.profiles) }
function Get-WdhAutoLogon { $script:M.autologon }
function Resolve-WdhSid { param([string] $Account) if (-not $Account) { return '' } $leaf = $Account.Split('\')[-1].ToLowerInvariant(); if ($script:M.sids.ContainsKey($leaf)) { return $script:M.sids[$leaf] } '' }
function Test-WdhUserHive { param([string] $Sid) [bool] ($Sid -and $script:M.hives -contains $Sid) }
function Get-WdhServices { Assert-SimProbe 'services'; $script:M.services }
function Get-WdhDefender { Assert-SimProbe 'defender'; $script:M.defender }
function Get-WdhSecurityCenter { Assert-SimProbe 'securityCenter'; $script:M.securityCenter }
function Get-WdhFirewall { Assert-SimProbe 'firewall'; @($script:M.firewall) }
function Get-WdhUac { Assert-SimProbe 'uac'; $script:M.uac }
function Get-WdhSmartScreen { $script:M.smartScreen }
function Get-WdhEncryption { Assert-SimProbe 'encryption'; $script:M.encryption }
function Get-WdhRebootSignals { Assert-SimProbe 'reboot'; $script:M.reboot }
function Get-WdhUpdateAgent { Assert-SimProbe 'updateAgent'; $script:M.updateAgent }
function Get-WdhUpdateScan { Assert-SimProbe 'updateScan'; $script:M.updateScan }
function Get-WdhPnpDevices { Assert-SimProbe 'devices'; @($script:M.devices) }
function Get-WdhNetwork { Assert-SimProbe 'network'; $script:M.network }
function Test-WdhDns { param([string] $HostName) [bool] $script:M.dns }
function Test-WdhInternet { [bool] $script:M.internet }
function Test-WdhTcp { param([string] $HostName, [int] $Port = 443) [bool] $script:M.tcp }
function Get-WdhVolume { Assert-SimProbe 'volume'; $script:M.volume }
function Get-WdhPhysicalDisks { Assert-SimProbe 'physicalDisks'; @($script:M.physicalDisks) }
function Open-WdhReport { param([string] $Path) $script:M.opened.Add($Path) }
function Get-WdhVideoControllers { Assert-SimProbe 'videoControllers'; @($script:M.videoControllers) }
function Get-WdhProcessors { Assert-SimProbe 'processors'; @($script:M.processors) }
function Get-WdhChassis { Assert-SimProbe 'chassis'; $script:M.chassis }
function Get-WdhUpdateHistory { Assert-SimProbe 'updateHistory'; $script:M.HistoryQueries++; @($script:M.updateHistory) }
function Get-WdhOrchestratorScan { Assert-SimProbe 'orchestrator'; $script:M.orchestrator }
function Register-WdhRecheckTask { param([string] $Script) $script:SimTasks['\WindowsDeploymentBuilder\HealthCheck'] = 'SYSTEM' }

function Get-WdhRegValue {
    param([string] $Root, [string] $SubKey, [string] $Name, [string] $Sid = '')
    $k = $(if ($Root -eq 'HKU') { "HKU\$Sid\$SubKey\$Name" } else { "HKLM\$SubKey\$Name" })
    if ($script:M.reg.ContainsKey($k)) { return $script:M.reg[$k] }
    return $null
}

<# The health configuration items of the staged package (what the deployment selected). #>
function Get-SimHealthItems { $c = Read-WddJson (Join-Path $script:Paths.Package 'scripts\health\health-config.json'); if ($c) { @($c.applications.items) } else { @() } }

<#
    Uninstall records: what the simulated WinGet installed (Applications sim), as the installers
    would register it (display name plus a version; per-user scope in the user's hive; WinGet's
    "<id>_<source>" key for portable packages), plus $script:M.extraUninstall.
#>
<#
    Health engine 1.2.0: the selected items the simulated WinGet installed (and that a scenario did
    not remove with $script:M.missing). A simulated installer leaves the evidence its catalog entry's
    verify block names: an uninstall record starting with its first prefix, its Store package, its
    files (version 1.2.3.0) and its registry values, so both engines check the same computer.
#>
function Get-SimInstalledItems {
    $installed = $(if (Get-Variable -Name AppSim -Scope Script -ErrorAction SilentlyContinue) { $script:AppSim.Installed } else { @{} })
    @(Get-SimHealthItems | Where-Object { [string] $_.packageIdentifier -and $installed[[string] $_.packageIdentifier] -and $script:M.missing -notcontains [string] $_.packageIdentifier })
}
function Get-SimVerify { param($Item) if ($Item -is [hashtable] -and $Item.ContainsKey('verify') -and $Item.verify -is [hashtable]) { $Item.verify } else { @{} } }
function Resolve-SimPath {
    param([string] $Path)
    $prof = $(if ($script:M.profilePaths.ContainsKey($script:SimUserSid)) { [string] $script:M.profilePaths[$script:SimUserSid] } else { '' })
    $f = $script:M.machineFolders
    $Path.Replace('%ProgramFiles(x86)%', [string] $f.ProgramFilesX86).Replace('%ProgramFiles%', [string] $f.ProgramFiles).Replace('%ProgramData%', [string] $f.ProgramData).Replace('%LocalAppData%', "$prof\AppData\Local").Replace('%AppData%', "$prof\AppData\Roaming")
}

function Get-WdhUninstallEntries {
    param([string] $Sid = '')
    Assert-SimProbe 'uninstall'
    $out = @()
    foreach ($it in Get-SimInstalledItems) {
        $pkgId = [string] $it.packageIdentifier
        if ([string] $it.source -eq 'msstore') { continue }
        $vf = Get-SimVerify $it
        $scope = $(if ([string] $it.scope -eq 'user' -or $script:M.userScoped -contains $pkgId -or ($vf.ContainsKey('perUser') -and $vf.perUser)) { 'user' } else { 'machine' })
        if ($scope -eq 'user' -and -not $Sid) { continue }
        $key = $(if ([string] $it.method -eq 'portable') { "$($pkgId)_Microsoft.Winget.Source_8wekyb3d8bbwe" } else { "{$([guid]::NewGuid().ToString().ToUpperInvariant())}" })
        # The Visual C++ redistributables register as Microsoft names them (32-bit view), not by the catalog's display name.
        if ($pkgId -match '^Microsoft\.VCRedist\.2015\+\.(x64|x86)$') { $out += , @{ scope = 'machine'; view = '32'; keyName = $key; displayName = "Microsoft Visual C++ 2015-2022 Redistributable ($($Matches[1])) - 14.40.33810"; displayVersion = '14.40.33810.0'; publisher = 'Microsoft Corporation' }; continue }
        $dn = $(if ($vf.ContainsKey('uninstall') -and @($vf.uninstall).Count) { "$(@($vf.uninstall)[0]) 1.2.3" } else { "$($it.name) 1.2.3" })
        $out += , @{ scope = $scope; view = $(if ($scope -eq 'user') { 'user' } else { '64' }); keyName = $key; displayName = $dn; displayVersion = '1.2.3'; publisher = 'Sim' }
    }
    foreach ($e in @($script:M.extraUninstall)) { if ($e -and ($e.scope -ne 'user' -or $Sid)) { $out += , $e } }
    return $out
}

function Get-WdhAppxPackages {
    param([string] $Sid = '')
    Assert-SimProbe 'appx'
    $out = @()
    foreach ($it in Get-SimInstalledItems) {
        if ([string] $it.source -eq 'msstore') {
            $flat = ([string] $it.name) -replace '[^A-Za-z0-9]', ''
            $out += , @{ name = "SimPublisher.$flat"; family = "SimPublisher.$($flat)_8wekyb3d8bbwe"; version = '1.0.0.0' }
        }
        $vf = Get-SimVerify $it
        if ($vf.ContainsKey('appx')) { foreach ($n in @($vf.appx)) { if ($n) { $out += , @{ name = [string] $n; family = "$($n)_8wekyb3d8bbwe"; version = '1.2.3.0' } } } }
    }
    return @($out) + @(@($script:M.extraAppx) | Where-Object { $_ })
}

function Get-WdhProvisionedAppx { Assert-SimProbe 'appxProvisioned'; @($script:M.provisioned) }
function Get-WdhUserProfilePath { param([string] $Sid) if ($Sid -and $script:M.profilePaths.ContainsKey($Sid)) { [string] $script:M.profilePaths[$Sid] } else { '' } }
function Get-WdhMachineFolders { $script:M.machineFolders }
function Get-WdhFileEvidence {
    param([string] $Path)
    Assert-SimProbe 'files'
    if ($script:M.files.ContainsKey($Path)) { return @{ exists = $true; version = [string] $script:M.files[$Path] } }
    foreach ($it in Get-SimInstalledItems) { $vf = Get-SimVerify $it; if ($vf.ContainsKey('files')) { foreach ($f in @($vf.files)) { if ((Resolve-SimPath ([string] $f)) -eq $Path) { return @{ exists = $true; version = '1.2.3.0' } } } } }
    @{ exists = $false; version = '' }
}
<# HKLM values by view: "HKLM\<key>\<name>" (64-bit) or "HKLM32\<key>\<name>" in $script:M.reg, or those a simulated installer wrote. #>
function Get-WdhRegValueView {
    param([string] $SubKey, [string] $Name, [string] $View = '64')
    $k = "HKLM$(if ($View -eq '32') { '32' })\$SubKey\$Name"
    if ($script:M.reg.ContainsKey($k)) { return $script:M.reg[$k] }
    foreach ($it in Get-SimInstalledItems) {
        $vf = Get-SimVerify $it
        if (-not $vf.ContainsKey('registry')) { continue }
        foreach ($r in @($vf.registry)) { if ($r -and "HKLM\$SubKey" -eq [string] $r.key -and $Name -eq [string] $r.name -and $View -eq $(if ([string] $r.view -eq '32') { '32' } else { '64' })) { return $(if ($r.ContainsKey('equals') -and $null -ne $r.equals) { [string] $r.equals } else { '1' }) } }
    }
    return $null
}

<#
    The application engine's (1.6.0) evidence probes answer from the same simulated computer, so the
    engine run by the scenario never reads the real one (its user, uninstall records, Store packages,
    files or registry) and both engines agree on what is installed.
#>
function Get-WdaDeploymentUser {
    $isSystem = [bool] $script:SimIdentity.IsSystem
    $name = $(if ($isSystem) { "PC\$(@($script:M.users)[0].name)" } else { [string] $script:SimIdentity.Name })
    $leaf = $name.Split('\')[-1].ToLowerInvariant()
    $sid = $(if ($script:M.sids.ContainsKey($leaf)) { [string] $script:M.sids[$leaf] } else { '' })
    $prof = $(if ($sid -and $script:M.profilePaths.ContainsKey($sid)) { [string] $script:M.profilePaths[$sid] } else { '' })
    @{ Name = $name; Sid = $sid; ProfilePath = $prof; LocalAppData = $(if ($prof) { "$prof\AppData\Local" } else { '' }); AppData = $(if ($prof) { "$prof\AppData\Roaming" } else { '' }); HiveLoaded = [bool] ($sid -and $script:M.hives -contains $sid); IsEngineAccount = (-not $isSystem) }
}
function Get-WdaMachineRoots { @{ ProgramFiles = [string] $script:M.machineFolders.ProgramFiles; 'ProgramFiles(x86)' = [string] $script:M.machineFolders.ProgramFilesX86; ProgramData = [string] $script:M.machineFolders.ProgramData } }
function Get-WdaUninstallEntries {
    param([string] $Hive, [string] $Sid = '')
    if ($Hive -eq 'User' -and -not ($Sid -and $script:M.hives -contains $Sid)) { return , @() }
    $all = @(Get-WdhUninstallEntries $(if ($Hive -eq 'User') { $Sid } else { '' }))
    , @($all | Where-Object { if ($Hive -eq 'User') { $_.scope -eq 'user' } elseif ($Hive -eq 'Machine32') { $_.scope -ne 'user' -and [string] $_['view'] -eq '32' } else { $_.scope -ne 'user' -and [string] $_['view'] -ne '32' } } | ForEach-Object { @{ DisplayName = [string] $_.displayName; DisplayVersion = [string] $_.displayVersion; Publisher = [string] $_.publisher; KeyName = [string] $_.keyName } })
}
function Get-WdaAppxRegistered { param([string] $Name, [hashtable] $User) , @(@(Get-WdhAppxPackages ([string] $User['Sid'])) | Where-Object { $_ -and [string] $_.name -eq $Name } | ForEach-Object { @{ Name = [string] $_.name; Version = [string] $_.version } }) }
function Get-WdaAppxProvisioned { param([string] $Name) , @(@($script:M.provisioned) | Where-Object { $_ -and [string] $_.name -eq $Name } | ForEach-Object { @{ Name = [string] $_.name; Version = [string] $_.version } }) }
function Get-WdaFileEvidence { param([string] $Path) $r = Get-WdhFileEvidence $Path; if ($r.exists) { @{ Path = $Path; Version = [string] $r.version } } else { $null } }
function Get-WdaRegistryValue { param([string] $Key, [string] $Name, [string] $View = '64') $v = Get-WdhRegValueView $Key.Substring(5) $Name $View; @{ Found = ($null -ne $v); Value = $v } }
function Get-WdhWinGetUpgrades { Assert-SimProbe 'winget'; $script:M.WinGetCalls++; $script:M.wingetUpgrade }

<# The portable shortcuts the REAL application engine created in the simulated Start menu. #>
function Get-WdhPortableShortcuts {
    $dir = Join-Path $script:Tmp 'StartMenu'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    @(Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -File | ForEach-Object { $_.BaseName })
}

<# The diagnostics export runs the recovery tool's real exporter in this process (no child process). #>
function Invoke-WdhRecoveryExport {
    param([string] $Tool, [string] $OutputPath)
    try { $r = Export-WdrDiagnostics $script:Manifest $script:Paths $OutputPath; @{ exit = 0; text = $r.Path } } catch { @{ exit = 1; text = $_.Exception.Message } }
}

function Get-HealthReport { Read-WddJson (Join-Path $script:Paths.Root 'reports\health\deployment-health.json') }
function Get-Finding { param($Report, [string] $Id) @($Report.findings) | Where-Object { $_.id -eq $Id } | Select-Object -First 1 }
function Get-Category { param($Report, [string] $Id) @($Report.categories) | Where-Object { $_.id -eq $Id } | Select-Object -First 1 }
