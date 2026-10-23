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
function Get-WdhUninstallEntries {
    param([string] $Sid = '')
    Assert-SimProbe 'uninstall'
    $out = @()
    $installed = $(if (Get-Variable -Name AppSim -Scope Script -ErrorAction SilentlyContinue) { $script:AppSim.Installed } else { @{} })
    foreach ($it in Get-SimHealthItems) {
        $pkgId = [string] $it.packageIdentifier
        if (-not $pkgId -or -not $installed[$pkgId] -or $script:M.missing -contains $pkgId -or [string] $it.source -eq 'msstore') { continue }
        $scope = $(if ([string] $it.scope -eq 'user' -or $script:M.userScoped -contains $pkgId) { 'user' } else { 'machine' })
        if ($scope -eq 'user' -and -not $Sid) { continue }
        $key = $(if ([string] $it.method -eq 'portable') { "$($pkgId)_Microsoft.Winget.Source_8wekyb3d8bbwe" } else { "{$([guid]::NewGuid().ToString().ToUpperInvariant())}" })
        $out += , @{ scope = $scope; keyName = $key; displayName = "$($it.name) 1.2.3"; displayVersion = '1.2.3'; publisher = 'Sim' }
    }
    foreach ($e in @($script:M.extraUninstall)) { if ($e -and ($e.scope -ne 'user' -or $Sid)) { $out += , $e } }
    return $out
}

function Get-WdhAppxPackages {
    param([string] $Sid = '')
    Assert-SimProbe 'appx'
    $installed = $(if (Get-Variable -Name AppSim -Scope Script -ErrorAction SilentlyContinue) { $script:AppSim.Installed } else { @{} })
    @(Get-SimHealthItems | Where-Object { [string] $_.source -eq 'msstore' -and $installed[[string] $_.packageIdentifier] -and $script:M.missing -notcontains [string] $_.packageIdentifier } | ForEach-Object {
        $flat = ([string] $_.name) -replace '[^A-Za-z0-9]', ''
        @{ name = "SimPublisher.$flat"; family = "SimPublisher.$($flat)_8wekyb3d8bbwe"; version = '1.0.0.0' }
    })
}

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
