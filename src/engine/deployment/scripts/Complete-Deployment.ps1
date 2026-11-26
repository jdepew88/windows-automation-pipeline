#Requires -Version 5.1
<#
.SYNOPSIS
    Writes the final deployment report and cleans up the deployment monitor.

.DESCRIPTION
    Called by DeploymentOrchestrator.ps1 when every enabled stage has a final result, or when the
    deployment deadline has passed. Run by hand (elevated) it writes the report for the current
    state without ending the deployment (-Preview), or ends it now (-Finish).

    Writes <dataRoot>\reports\deployment-report.json and deployment-report.txt, the marker
    <dataRoot>\state\deployment.done (with the overall status; a marker is never proof of success
    on its own), an Application event, and a "Deployment report" shortcut on the public desktop.
    It removes only the monitor task. Logs, state and the engines' results are kept.

    Phase 9: when the package carries DeploymentHealth.ps1, the deployment is then verified against
    Windows itself (read-only), the result is added to the report, and the "Windows Deployment -
    Health Report" shortcut opens the technician dashboard. A pending restart registers a startup
    re-check that removes itself.

    Orchestrator 1.2.0: the report also contains
      - a Device Manager check (read-only): devices with a problem code, without a driver, or
        unknown to Windows, with friendly names, hardware IDs and the problem in words. A USB
        descriptor or reset failure is reported as a likely hardware or connection problem, not
        as a missing driver. Unresolved devices make a successful deployment CompletedWithFollowUp.
      - how each application was confirmed: Verified (WinGet finds the exact package ID
        installed), EngineReported (the installer reported success, not independently confirmed),
        NotVerified (reported success, but WinGet does not find it), Failed, Deferred (manual,
        deselected, needs a person or a restart) or Incomplete;
      - Windows Update counts for optional updates and drivers, and the updates needing a person;
      - the restart history (planned or unexpected) and every recovery.
    The progress window task is removed; the LAN monitor ends itself (see its script).
#>
[CmdletBinding()]
param(
    [switch] $Preview,
    [switch] $Finish
)

$script:CompleteMain = $MyInvocation.InvocationName -ne '.'
$script:CompleteArgs = @{ Preview = [bool] $Preview; Finish = [bool] $Finish }
. (Join-Path $PSScriptRoot '..\common\DeploymentCommon.ps1')
# Phase 4.3: present only when the ongoing update policy is applied after the initial updates.
$script:PolicyScript = Join-Path $PSScriptRoot 'Set-UpdatePolicy.ps1'
if (Test-Path -LiteralPath $script:PolicyScript) { . $script:PolicyScript }
# Schema 9: present when the deployment activates Windows or Office (functions only).
$script:ActivationScript = Join-Path $PSScriptRoot 'Activation.ps1'
if (Test-Path -LiteralPath $script:ActivationScript) { . $script:ActivationScript }
# Phase 9: present when the deployment verifies itself (functions only).
$script:HealthScript = Join-Path $PSScriptRoot '..\health\DeploymentHealth.ps1'
if (Test-Path -LiteralPath $script:HealthScript) { . $script:HealthScript -Mode Library }
$script:HealthShortcut = "Windows Deployment $([char] 0x2014) Health Report"

function Get-WddSystemInfo {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    [ordered]@{
        computerName   = $env:COMPUTERNAME
        windows        = [string] $os.Caption
        edition        = $(if ($cv) { [string] $cv.EditionID } else { '' })
        displayVersion = $(if ($cv -and $cv.PSObject.Properties['DisplayVersion']) { [string] $cv.DisplayVersion } else { '' })
        build          = $(if ($cv) { '{0}.{1}' -f $cv.CurrentBuildNumber, $cv.UBR } else { [string] $os.BuildNumber })
        installDateUtc = $os.InstallDate.ToUniversalTime().ToString('o')
        manufacturer   = [string] $cs.Manufacturer
        model          = [string] $cs.Model
    }
}

# Windows' documented Device Manager problem codes (CM_PROB_*), in words (same wording as the health check).
$script:WddProblemCodes = @{
    1 = 'not configured correctly'; 3 = 'driver may be corrupted or memory is low'; 10 = 'cannot start'; 12 = 'not enough free resources'; 14 = 'needs a restart to work'
    18 = 'drivers must be reinstalled'; 19 = 'configuration in the registry is damaged'; 21 = 'being removed'; 22 = 'disabled'; 24 = 'not present, not working or missing drivers'
    28 = 'no driver installed'; 29 = 'disabled by the firmware'; 31 = 'not working properly (driver could not be loaded)'; 32 = 'driver service disabled'; 37 = 'driver failed to initialize'
    39 = 'driver is corrupted or missing'; 40 = 'driver registry entry is damaged'; 41 = 'driver loaded but the hardware was not found'; 43 = 'the device reported a problem'
    45 = 'not connected'; 47 = 'prepared for safe removal'; 48 = 'driver blocked'; 52 = 'driver signature could not be verified'
}

<# Present Plug and Play devices (read-only): name, class, problem code and up to five hardware IDs. #>
function Get-WddPnpDevices {
    @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.Present -ne $false } | ForEach-Object {
        @{ name = [string] $_.Name; class = [string] $_.PNPClass; problemCode = $(if ($null -ne $_.ConfigManagerErrorCode) { [int] $_.ConfigManagerErrorCode } else { 0 })
           hardwareIds = @(@($_.HardwareID) | Where-Object { $_ } | Select-Object -First 5) }
    })
}

<#
    Devices that still need attention at the end of the deployment. Disabled (22) and disconnected
    (45) devices are not counted. Kinds: NoDriver, UnknownDevice, RestartRequired,
    HardwareOrConnection (USB descriptor/reset failures: usually a cable, hub, port or device fault,
    not a missing driver), Problem (any other problem code). Instance IDs are not reported (they can
    contain serial numbers).
#>
function Get-WddDeviceReport {
    $devices = $null
    # Each device is one pipeline object (a hashtable); an empty list is an empty array.
    try { $devices = @(Get-WddPnpDevices | Where-Object { $_ -is [System.Collections.IDictionary] }) } catch { return [ordered]@{ checked = $false; checkedUtc = (Get-WddNow).ToString('o'); error = "The device list could not be read: $($_.Exception.Message)"; devices = 0; unresolved = @() } }
    $out = @()
    foreach ($d in $devices) {
        $code = [int] $d['problemCode']
        $name = [string] $d['name']
        $class = [string] $d['class']
        $ids = @(@($d['hardwareIds']) | Where-Object { $_ })
        $unknown = (-not $class -or $class -eq 'Unknown' -or $name -match '(?i)^unknown device$' -or -not $name)
        if ($code -in 22, 45) { continue }
        # Orchestrator 1.3.0: a display adapter running on Windows' generic driver works, but without acceleration.
        $basicDisplay = $code -eq 0 -and $name -match '(?i)^Microsoft Basic Display Adapter$'
        if ($code -eq 0 -and -not $unknown -and -not $basicDisplay) { continue }
        $descriptor = (@($ids | Where-Object { $_ -match '(?i)(DEVICE_DESCRIPTOR_FAILURE|CONFIG_DESCRIPTOR_FAILURE|RESET_FAILURE|SET_ADDRESS_FAILURE)' }).Count -gt 0) -or $name -match '(?i)(Descriptor Request Failed|Port Reset Failed|Set Address Failed)'
        $problem = $(if ($code -and $script:WddProblemCodes.ContainsKey($code)) { $script:WddProblemCodes[$code] } elseif ($code) { "problem code $code" } else { 'no matching driver' })
        if ($descriptor) { $kind = 'HardwareOrConnection'; $note = 'The USB device did not answer Windows correctly (descriptor or reset failure). This usually means a hardware, cable, hub or port problem, not a missing driver: reconnect it, try another port, or check the device.' }
        elseif ($code -eq 28) { $kind = 'NoDriver'; $note = 'No driver is installed. Find the driver by the hardware ID (Windows Update optional updates, or the manufacturer''s support page).' }
        elseif ($unknown) { $kind = 'UnknownDevice'; $note = 'Windows does not recognise this device. Identify it by its hardware ID.' }
        elseif ($code -eq 14) { $kind = 'RestartRequired'; $note = 'Restart the computer to finish installing its driver.' }
        elseif ($basicDisplay) { $kind = 'GenericDriver'; $note = 'The graphics adapter runs on Windows'' generic display driver (no acceleration). Windows Update did not provide its driver.' }
        else { $kind = 'Problem'; $note = "Device Manager reports code ${code}: $problem. This is not necessarily a missing driver; check the device in Device Manager." }
        $hint = Get-WddDriverHint $name $class $ids $kind
        $out += , ([ordered]@{ name = $(if ($name) { $name } else { 'Unknown device' }); class = $class; problemCode = $code; problem = $problem; kind = $kind; hardwareIds = $ids; note = $note; vendor = $hint.vendor; driverSource = $hint.source })
    }
    return [ordered]@{ checked = $true; checkedUtc = (Get-WddNow).ToString('o'); devices = @($devices).Count; unresolved = $out }
}

<#
    Orchestrator 1.3.0: where a missing chipset or graphics driver officially comes from, by the PCI
    vendor ID in the hardware ID. Guidance for the technician only: nothing is downloaded, and no
    third-party driver site is ever suggested. A USB descriptor failure gets no driver hint.
#>
$script:WddPciVendors = @{ '8086' = 'Intel'; '1022' = 'AMD'; '1002' = 'AMD'; '10DE' = 'NVIDIA'; '10EC' = 'Realtek'; '14E4' = 'Broadcom'; '1B21' = 'ASMedia'; '168C' = 'Qualcomm Atheros'; '1969' = 'Qualcomm Atheros' }
function Get-WddDriverHint {
    param([string] $Name, [string] $Class, [object[]] $Ids, [string] $Kind)
    $o = [ordered]@{ vendor = ''; source = '' }
    if ($Kind -eq 'HardwareOrConnection') { return $o }
    foreach ($id in @($Ids)) { if ([string] $id -match '(?i)VEN_([0-9A-F]{4})') { $v = $Matches[1].ToUpperInvariant(); if ($script:WddPciVendors.ContainsKey($v)) { $o.vendor = $script:WddPciVendors[$v] } else { $o.vendor = "PCI vendor $v" }; break } }
    $chipset = $Name -match '(?i)(SM ?Bus Controller|PCI Memory Controller|PCI Simple Communications Controller|PCI Data Acquisition|Base System Device|PCI Encryption|Signal Processing Controller)'
    $graphics = $Class -eq 'Display' -or $Name -match '(?i)(Video Controller|Basic Display Adapter|3D Video Controller)'
    if ($chipset) {
        $o.source = switch ($o.vendor) {
            'Intel' { 'Chipset driver: Intel Chipset Device Software (Intel Driver & Support Assistant, intel.com) or the motherboard/computer manufacturer''s support page.' }
            'AMD' { 'Chipset driver: AMD Chipset Software (amd.com/support) or the motherboard/computer manufacturer''s support page.' }
            default { 'Chipset driver: the motherboard or computer manufacturer''s support page for this model.' }
        }
    } elseif ($graphics) {
        $o.source = switch ($o.vendor) {
            'NVIDIA' { 'Graphics driver: nvidia.com/drivers (or NVIDIA App), or the computer manufacturer''s support page for laptops.' }
            'AMD' { 'Graphics driver: AMD Software: Adrenalin Edition (amd.com/support), or the computer manufacturer''s support page for laptops.' }
            'Intel' { 'Graphics driver: Intel Driver & Support Assistant (intel.com), or the computer manufacturer''s support page for laptops.' }
            default { 'Graphics driver: the graphics card or computer manufacturer''s support page.' }
        }
    } elseif ($Kind -in 'NoDriver', 'UnknownDevice' -and $o.vendor) {
        $o.source = "Driver: $($o.vendor)'s support site or the computer/motherboard manufacturer's support page (search by the hardware ID)."
    }
    return $o
}

<#
    How an application result was confirmed (see the description). Verification is by the exact
    package ID (winget list --id <id> --exact), so a similarly named package or another version of
    a different product never counts.
#>
function Get-WddAppVerification {
    param($Package)
    $st = [string] $Package['status']
    $det = $(if ($Package.Contains('detection')) { [string] $Package['detection'] } else { '' })
    switch ($st) {
        'Succeeded' { if ($det -eq 'Installed') { return 'Verified' } elseif ($det -eq 'Unconfirmed') { return 'NotVerified' } else { return 'EngineReported' } }
        'AlreadyInstalled' { return 'Verified' }
        { $_ -in 'Failed', 'Unavailable' } { return 'Failed' }
        { $_ -in 'RequiresInteraction', 'RequiresRestart', 'SkippedByUser', 'Skipped' } { return 'Deferred' }
    }
    return 'Incomplete'
}

function New-WddReport {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $State, $Snapshot, [string] $Overall, [string] $Reason)
    $system = try { Get-WddSystemInfo } catch { [ordered]@{ computerName = $env:COMPUTERNAME; error = $_.Exception.Message } }
    $wu = @($Snapshot.stages | Where-Object { $_.id -eq 'windowsUpdate' }) | Select-Object -First 1
    $apps = @($Snapshot.stages | Where-Object { $_.id -eq 'applications' }) | Select-Object -First 1
    $drv = @($Snapshot.stages | Where-Object { $_.id -eq 'drivers' }) | Select-Object -First 1
    $remaining = @(); $errors = @(); $incomplete = @()
    $wuReport = $null
    if ($wu) {
        $r = $wu.result
        $failed = @(if ($r) { @($r.failed) | Where-Object { $_ } | ForEach-Object { [ordered]@{ kbs = @($_.kbs); title = $_.title; attempts = $_.attempts; lastResult = $_.lastResult; lastHResult = $_.lastHResult } } })
        $person = @(if ($r -and $r.ContainsKey('requiresInteraction')) { @($r.requiresInteraction) | Where-Object { $_ } | ForEach-Object { [ordered]@{ kbs = @($_.kbs); title = $_.title; reason = $_.reason } } })
        $counts = $(if ($r -and $r.ContainsKey('counts')) { $r.counts } else { $null })
        $wuReport = [ordered]@{ state = $wu.state; status = $wu.status; reason = $wu.detail; reboots = $wu.reboots
                                installed = $(if ($r) { @($r.installed).Count } else { $null }); skipped = $(if ($r) { @($r.skipped).Count } else { $null }); failedUpdates = $failed
                                installedOptional = $(if ($counts) { $counts['installedOptional'] } else { $null }); installedDrivers = $(if ($counts) { $counts['installedDrivers'] } else { $null })
                                requiresInteraction = $person; policy = $(if ($r -and $r.ContainsKey('policy')) { $r.policy } else { $null }) }
        foreach ($f in $failed) { $remaining += "Windows Update: $((@($f.kbs) -join ', ')) $($f.title) failed after $($f.attempts) attempt(s) ($($f.lastHResult))." }
        foreach ($f in $person) { $remaining += "Windows Update: $((@($f.kbs) -join ', ')) $($f.title) needs a person to install it (Settings > Windows Update)." }
        if ($wu.state -ne 'Final') { $incomplete += "Windows Update ($($wu.state))" }
        elseif ($wu.status -eq 'Offline') { $incomplete += 'Windows Update (Offline: no network before its runtime limit)' }
        elseif ($wu.status -eq 'Failed') { $errors += "Windows Update failed: $($wu.detail)" }
    }
    $appsReport = $null
    if ($apps) {
        $r = $apps.result
        # Phase 5: lifecycle, failure class and attempt totals come from result schema 2 (absent in schema 1).
        $pk = @(if ($r) { @($r.packages) | Where-Object { $_ } | ForEach-Object {
            $x = [ordered]@{ name = $_.name; packageIdentifier = $_.packageIdentifier; source = $_.source; status = $_.status; attempts = $_.attempts; exitCode = $_.exitCode; message = $_.message }
            foreach ($k in 'operationId', 'lifecycle', 'failureClass', 'retryable', 'detection', 'totalAttempts', 'manualRetries', 'installerExitCode') { if ($_.ContainsKey($k)) { $x[$k] = $_[$k] } }
            $x.verification = Get-WddAppVerification $x
            $x
        } })
        $verification = [ordered]@{}
        foreach ($v in 'Verified', 'EngineReported', 'NotVerified', 'Failed', 'Deferred', 'Incomplete') { $verification[$v] = @($pk | Where-Object { $_.verification -eq $v }).Count }
        $add = @(if ($r) { @($r.additionalSoftware) | Where-Object { $_ } })
        $appsReport = [ordered]@{ state = $apps.state; status = $apps.status; reason = $apps.detail; reboots = $apps.reboots
                                  counts = $(if ($r) { $r.counts } else { $null }); packages = $pk; additionalSoftware = $add
                                  requiresInteraction = @($pk | Where-Object { $_.status -eq 'RequiresInteraction' } | ForEach-Object { $_.name })
                                  verification = $verification
                                  bootstrap = $(if ($r) { $r.bootstrap } else { $null }) }
        foreach ($p in @($pk | Where-Object { $_.verification -eq 'NotVerified' })) { $remaining += "Application $($p.name): reported installed, but WinGet does not find $($p.packageIdentifier); check it by hand." }
        foreach ($p in $pk) { if ($p.status -in 'RequiresInteraction', 'RequiresRestart', 'Failed', 'Unavailable', 'Pending') { $remaining += "Application $($p.name) ($($p.source):$($p.packageIdentifier)): $($p.status). $($p.message)" } }
        foreach ($a in $add) { if ($a.status -ne 'Succeeded') { $remaining += "Additional Software $($a.name): $($a.status). $($a.message)" } }
        if ($apps.state -ne 'Final') { $incomplete += "Applications ($($apps.state))" }
        elseif ($apps.status -eq 'Offline') { $incomplete += 'Applications (Offline)' }
        elseif ($apps.status -eq 'Failed') { $errors += "Application setup failed: $($apps.detail)" }
    }
    foreach ($n in @($Snapshot.needsAttention)) { $errors += $n }
    # Phase 4.3: written by Add-WifiProfile.ps1 when the answer file adds a Wi-Fi profile (never contains the key).
    $wifi = Read-WddJson (Join-Path $Paths.Root 'Network\wifi-result.json')
    if ($wifi -and $wifi.status -notin 'Added', 'ConnectRequested', 'ConnectFailed') { $remaining += "Wi-Fi: $($wifi.status). $($wifi.message)" }
    $policy = $(if ($State.ContainsKey('updatePolicy')) { $State.updatePolicy } else { $null })
    if ($Manifest.ContainsKey('updatePolicy') -and $Manifest.updatePolicy) {
        if (-not $policy) { $remaining += 'Ongoing Windows Update policy: not applied. Set it under Settings > Windows Update or re-run the deployment.' }
        elseif ($policy.status -notin 'Applied', 'AlreadyApplied') { $remaining += "Ongoing Windows Update policy: $($policy.status). $($policy.message)" }
    }
    # Phase 8: the driver stage's own result (reports\drivers.json); without it, say plainly that nothing handled drivers.
    $driversReport = $null
    $drvStage = Get-WddStage $Manifest 'drivers'
    $drvPolicy = $(if ($Manifest.ContainsKey('drivers') -and $Manifest.drivers -is [hashtable] -and $Manifest.drivers.ContainsKey('policy')) { $Manifest.drivers.policy } else { $null })
    if ($drv) {
        $dr = Read-WddJson (Join-Path $Paths.Root 'reports\drivers.json')
        $listUnresolved = -not ($drvPolicy -and $drvPolicy.ContainsKey('reportUnresolved') -and -not $drvPolicy.reportUnresolved)
        $driversReport = [ordered]@{ state = $drv.state; status = $drv.status; reason = $drv.detail; reboots = $drv.reboots
                                     health = $(if ($dr) { $dr['health'] } else { $null }); summary = $(if ($dr) { $dr['summary'] } else { $null })
                                     installed = @(if ($dr) { @($dr['operations']) | Where-Object { $_ -and $_['status'] -eq 'Succeeded' } | ForEach-Object { [ordered]@{ device = $_['device']; source = $_['source']; package = $_['package'] } } })
                                     manualActions = @(if ($dr) { @($dr['manualActions']) | Where-Object { $_ } })
                                     optionalApplications = @(if ($dr) { @($dr['optionalApplications']) | Where-Object { $_ } | ForEach-Object { $_['name'] } })
                                     networkBootstrap = $(if ($dr) { $dr['networkBootstrap'] } else { $null }); report = (Join-Path $Paths.Root 'reports\drivers.json') }
        if ($dr -and $listUnresolved) {
            foreach ($m in @($dr['manualActions']) | Where-Object { $_ }) { $remaining += "Driver: $($m['text'])$(if ($m['url']) { " ($($m['url']))" })" }
            foreach ($o in @($dr['operations']) | Where-Object { $_ -and $_['status'] -eq 'WaitingForReboot' }) { $remaining += "Driver: $($o['device']): restart the computer to start the new driver." }
        }
        if ($drv.state -ne 'Final') { $incomplete += "Hardware & drivers ($($drv.state))" }
        elseif ($drv.status -eq 'Failed') { $errors += "Driver setup failed: $($drv.detail)" }
    } elseif ($drvStage -and $drvStage['implemented']) {
        $remaining += 'Manufacturer drivers: hardware-aware driver provisioning was not part of this deployment. Install chipset, graphics and OEM drivers manually if Windows Update did not provide them.'
    } else {
        $remaining += 'Manufacturer drivers: not part of this deployment (driver stage not implemented). Install chipset, graphics and OEM drivers manually if Windows Update did not provide them.'
    }
    # Phase 5: what is still open and how to recover it, kept after the deployment ends.
    $tool = Join-Path $Paths.Package 'scripts\recovery\DeploymentRecovery.ps1'
    $hasTool = Test-Path -LiteralPath $tool
    $outstanding = @()
    if ($apps -and $apps.result -and $apps.result.ContainsKey('outstanding')) {
        foreach ($x in @($apps.result.outstanding) | Where-Object { $_ }) {
            $how = switch ([string] $x.lifecycle) {
                'FailedRetryable' { 'retry (automatic retries used up)' } 'BlockedByDependency' { 'retry (with its dependency)' }
                'WaitingForNetwork' { 'resume when the network is back' } 'Pending' { 'resume' } 'FailedPermanent' { 'correct the cause, then retry with -IncludePermanent' }
                'ManualActionRequired' { 'install or finish it by hand' } 'WaitingForReboot' { 'restart the computer' } default { 'check' }
            }
            $outstanding += [ordered]@{ operationId = $x.operationId; name = $x.name; lifecycle = $x.lifecycle; failureClass = $x.failureClass; retryable = $x.retryable; action = $how; message = $x.message }
        }
    } elseif ($apps -and $apps.state -ne 'Final') {
        $outstanding += [ordered]@{ operationId = 'stage:applications'; name = 'Applications'; lifecycle = 'Pending'; failureClass = ''; retryable = $true; action = 'resume'; message = "The application stage is $($apps.state)." }
    }
    if ($drv -and $drv.result -and $drv.result.ContainsKey('outstanding')) {
        foreach ($x in @($drv.result.outstanding) | Where-Object { $_ }) {
            $how = switch ([string] $x.status) {
                'FailedRetryable' { 'retry (RetryFailed)' } 'WaitingForNetwork' { 'resume when the network is back' } 'Pending' { 'resume' }
                'FailedPermanent' { $(if ([string] $x.failureClass -in 'Integrity', 'Signature') { 'replace the package with a correctly signed, unmodified one' } else { 'correct the cause, then retry with -IncludePermanent' }) }
                'ManualActionRequired' { 'install the driver by hand (see the device in drivers.json) or supply one with -Action AddDrivers' } 'WaitingForReboot' { 'restart the computer' } 'Unsupported' { 'check the device' } default { 'check' }
            }
            $outstanding += [ordered]@{ operationId = $x.operationId; name = $x.name; lifecycle = $x.status; failureClass = $x.failureClass; retryable = ($x.status -eq 'FailedRetryable'); action = $how; message = $x.message }
        }
    } elseif ($drv -and $drv.state -ne 'Final') {
        $outstanding += [ordered]@{ operationId = 'stage:drivers'; name = 'Hardware & drivers'; lifecycle = 'Pending'; failureClass = ''; retryable = $true; action = 'resume'; message = "The driver stage is $($drv.state)." }
    }
    if ($wu -and $wu.state -eq 'Final' -and $wu.status -in 'CompletedWithFailures', 'Failed', 'Offline') {
        $outstanding += [ordered]@{ operationId = 'stage:windowsUpdate'; name = 'Windows Update'; lifecycle = 'FailedRetryable'; failureClass = $(if ($wu.status -eq 'Offline') { 'Network' } else { 'Transient' }); retryable = $true; action = 'retry the update stage (installed updates are never offered again)'; message = [string] $wu.detail }
    }
    $recoveryCommands = [ordered]@{
        status      = "powershell.exe -ExecutionPolicy Bypass -File `"$tool`" -Action Status"
        retryFailed = "powershell.exe -ExecutionPolicy Bypass -File `"$tool`" -Action RetryFailed"
        retryOne    = "powershell.exe -ExecutionPolicy Bypass -File `"$tool`" -Action Retry -Operation <operationId>"
        resume      = "powershell.exe -ExecutionPolicy Bypass -File `"$tool`" -Action Resume"
        diagnostics = "powershell.exe -ExecutionPolicy Bypass -File `"$tool`" -Action ExportDiagnostics"
    }
    # Phase 6: the application stage's restoration result (inventory migration and settings restore).
    $restorationFile = Join-Path $Paths.Root 'Applications\restoration.json'
    $restoration = Read-WddJson $restorationFile
    $restorationReport = $null
    if ($restoration -and $restoration['format'] -eq 'windows-deployment-builder/restoration-result') {
        $restorationReport = [ordered]@{ file = $restorationFile; inventoryId = [string] $restoration['inventoryId']; backupId = [string] $restoration['backupId']
                                         backup = $restoration['backup']; counts = $restoration['counts']
                                         settings = @(@($restoration['settings']) | Where-Object { $_ } | ForEach-Object { [ordered]@{ adapterId = $_['adapterId']; name = $_['name']; outcome = $_['outcome']; detail = $_['detail'] } }) }
        if (@($restoration['settings']).Count) { $recoveryCommands.restoreSettings = "powershell.exe -ExecutionPolicy Bypass -File `"$tool`" -Action RestoreSettings -BackupPath <backup folder>" }
    }
    # Orchestrator 1.2.0: Device Manager at the end (read-only), restarts and recoveries.
    $devices = $(if ($State.ContainsKey('deviceReport') -and $State.deviceReport) { $State.deviceReport } else { Get-WddDeviceReport })
    foreach ($d in @($devices.unresolved)) { $remaining += "Device: $($d.name)$(if (@($d.hardwareIds).Count) { " [$(@($d.hardwareIds)[0])]" }): $($d.note)$(if ($d.Contains('driverSource') -and $d.driverSource) { " $($d.driverSource)" })" }
    if (-not $devices.checked) { $remaining += "Device Manager: $($devices.error)" }
    # Orchestrator 1.3.0: a restart Windows still needs, and what Windows Update still offers after the last run.
    $restartView = Get-WddRestartView $State
    $rcState = $(if ($State['restartCoordinator'] -is [hashtable]) { $State['restartCoordinator'] } else { @{} })
    $restartReport = [ordered]@{ status = $restartView.status; outstanding = (Test-WddRestartOutstanding $State); reasons = @($restartView.reasons); blockers = @($restartView.blockers)
                                 automaticRestarts = $restartView.restarts; message = $restartView.message; history = @(@($rcState['history']) | Where-Object { $_ }) }
    if ($restartReport.outstanding) { $remaining += "Restart: Windows still needs a restart ($(@($restartView.reasons) -join '; ')). $(if ($restartView.status -eq 'LimitReached') { 'The automatic restart limit was reached.' } elseif (@($restartView.blockers).Count) { "It was blocked: $(@($restartView.blockers) -join '; ')." }) Restart the computer, then check Device Manager." }
    $recheck = $(if ($State['updateRecheck'] -is [hashtable]) { $State['updateRecheck'] } else { $null })
    if ($recheck -and $recheck['status'] -eq 'Remaining') { foreach ($u in @($recheck['remaining']) | Where-Object { $_ }) { $remaining += "Windows Update: $((@($u['kbs']) -join ', ')) $($u['title']) is still offered after the deployment's last update run." } }
    if ($recheck -and $recheck['status'] -eq 'CheckFailed') { $remaining += "Windows Update: $($recheck['message'])" }
    # Schema 9: Office LTSC (installation) and activation, reported separately.
    $officeReport = $null
    $off = @($Snapshot.stages | Where-Object { $_.id -eq 'office' }) | Select-Object -First 1
    if ($off) {
        $r = $off.result
        $officeReport = [ordered]@{ product = $(if ($Manifest.ContainsKey('office')) { [string] $Manifest.office.displayName } else { $off.name }); state = $off.state; status = $off.status; detail = $off.detail
                                    verified = [bool] ($r -and $r['verified']); alreadyInstalled = [bool] ($r -and $r['alreadyInstalled']); category = $(if ($r) { [string] $r['category'] } else { '' })
                                    version = $(if ($r -and $r['installed']) { [string] $r['installed']['version'] } else { '' }); attempts = $(if ($r) { @($r['attempts']).Count } else { 0 })
                                    source = $(if ($Manifest.ContainsKey('office')) { $Manifest.office.source } else { $null }); activated = $false; log = (Join-Path $Paths.Root 'Office\logs') }
        if ($off.state -ne 'Final') { $incomplete += "Microsoft Office ($($off.state))" }
        elseif ($off.status -eq 'Failed') { $errors += "Microsoft Office was not installed: $($off.detail)" }
        elseif ($off.status -in 'CompletedWithFollowUp', 'Offline') { $remaining += "Microsoft Office: $($off.detail)" }
    }
    $activationReport = $null
    if ($Manifest.ContainsKey('activation') -and $Manifest.activation) {
        $act = $(if ($State['activation'] -is [hashtable]) { $State.activation } else { @{} })
        $activationReport = [ordered]@{ windows = $act['windows']; office = $act['office']; plan = $Manifest.activation; log = (Join-Path $Paths.Root 'Activation\activation.log'); containsSecrets = $false }
        foreach ($k in 'windows', 'office') {
            $e = $act[$k]
            if (-not $e) { if ([string] $Manifest.activation[$k]['action'] -ne 'none') { $remaining += "Activation ($k): not attempted; the deployment ended before its activation step." }; continue }
            # No key characters in the remaining tasks (they also reach the LAN monitor's final view).
            $note = [string] $e['message'] -replace '\s*\(key ending [A-Za-z0-9]*\)', ''
            if ([string] $e['status'] -in 'AwaitingTechnician', 'Failed', 'Deferred', 'Blocked', 'Unavailable') { $remaining += "Activation ($k): $($e['status']). $note" }
        }
    }
    $outcome = Get-WddDeploymentOutcome @{ status = 'Completed'; overall = $Overall; message = $Reason } $null
    $report = [ordered]@{
        format             = 'windows-deployment-builder/deployment-report'
        reportVersion      = 2
        overall            = $Overall
        outcome            = $outcome.outcome
        outcomeCode        = $outcome.exitCode
        reason             = $Reason
        generatedUtc       = (Get-WddNow).ToString('o')
        packageId          = $Manifest.packageId
        packageVersion     = $Manifest.packageVersion
        orchestratorVersion = $script:DeployVersion
        startedUtc         = $State.initializedUtc
        deadlineUtc        = $State.deadlineUtc
        system             = $system
        windowsUpdate      = $wuReport
        applications       = $appsReport
        updatePolicy       = $policy
        wifi               = $wifi
        drivers            = $(if ($driversReport) { $driversReport } elseif ($drvStage -and $drvStage['implemented']) { [ordered]@{ state = 'NotPartOfDeployment'; note = 'Hardware-aware driver provisioning was off; no driver was installed or changed by this deployment.' } } else { [ordered]@{ state = 'NotImplemented'; note = 'No driver was installed or changed by this deployment.' } })
        restarts           = [ordered]@{ windowsUpdate = $(if ($wu) { $wu.reboots } else { 0 }); applications = $(if ($apps) { $apps.reboots } else { 0 }); drivers = $(if ($drv) { $drv.reboots } else { 0 }) }
        restartHistory     = @(if ($State.ContainsKey('restarts')) { @($State.restarts) | Where-Object { $_ } })
        restartCoordination = $restartReport
        updateRecheck      = $recheck
        devices            = $devices
        incompleteStages   = $incomplete
        errors             = $errors
        remainingTasks     = $remaining
        outstanding        = $outstanding
        recoveries         = @(if ($State.ContainsKey('recoveries')) { @($State.recoveries) })
        logs               = $(if ($drv) { [ordered]@{ deployment = $Paths.Log; windowsUpdate = (Join-Path $Paths.Root 'Updates\logs\engine.log'); applications = (Join-Path $Paths.Root 'Applications\logs\engine.log'); attempts = (Join-Path $Paths.Root 'Applications\logs\attempts.jsonl'); drivers = (Join-Path $Paths.Root 'Drivers\logs\engine.log') } } else { [ordered]@{ deployment = $Paths.Log; windowsUpdate = (Join-Path $Paths.Root 'Updates\logs\engine.log'); applications = (Join-Path $Paths.Root 'Applications\logs\engine.log'); attempts = (Join-Path $Paths.Root 'Applications\logs\attempts.jsonl') } })
        recovery           = "$(if ($hasTool) { "Recovery tool (as administrator; status, retry, resume, diagnostics): $($recoveryCommands.status). " })Resume only: powershell.exe -ExecutionPolicy Bypass -File `"$(Join-Path $Paths.Package 'scripts\orchestrator\Resume-Deployment.ps1')`""
        recoveryCommands   = $(if ($hasTool) { $recoveryCommands } else { $null })
        restoration        = $restorationReport
    }
    if ($officeReport) { $report.office = $officeReport; $report.logs['office'] = (Join-Path $Paths.Root 'Office\logs\engine.log') }
    if ($activationReport) { $report.activation = $activationReport; $report.logs['activation'] = $activationReport.log }
    return $report
}

function Format-WddReport {
    param($Report)
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add('Windows Deployment Builder - deployment report')
    $l.Add('==============================================')
    $l.Add("Overall result : $($Report.overall)")
    if ($Report.Contains('outcome')) { $l.Add("Outcome        : $($Report.outcome) (exit code $($Report.outcomeCode))") }
    if ($Report.reason) { $l.Add("               : $($Report.reason)") }
    $l.Add("Generated (UTC): $($Report.generatedUtc)")
    $l.Add("Package        : $($Report.packageId) (package $($Report.packageVersion), orchestrator $($Report.orchestratorVersion))")
    $l.Add('')
    $l.Add('Computer')
    foreach ($k in $Report.system.Keys) { $l.Add(('  {0,-15} {1}' -f $k, $Report.system[$k])) }
    $l.Add('')
    $l.Add('Windows Update')
    if ($Report.windowsUpdate) {
        $w = $Report.windowsUpdate
        $l.Add("  Result: $($w.status) ($($w.state)). $($w.reason)")
        $l.Add("  Installed: $($w.installed)  Skipped by policy: $($w.skipped)  Restarts: $($w.reboots)")
        if ($w.Contains('installedOptional') -and $null -ne $w.installedOptional) { $l.Add("  Of these: optional updates $($w.installedOptional), drivers $($w.installedDrivers)") }
        foreach ($f in @($w.failedUpdates)) { $l.Add("  FAILED  $((@($f.kbs) -join ', ')) $($f.title) ($($f.attempts) attempts, $($f.lastHResult))") }
        if ($w.Contains('requiresInteraction')) { foreach ($f in @($w.requiresInteraction)) { $l.Add("  PERSON  $((@($f.kbs) -join ', ')) $($f.title): needs a person to install it") } }
    } else { $l.Add('  Not part of this deployment.') }
    $l.Add('')
    $l.Add('Applications (WinGet)')
    if ($Report.applications) {
        $a = $Report.applications
        $l.Add("  Result: $($a.status) ($($a.state)). $($a.reason)")
        $l.Add("  Restarts: $($a.reboots)")
        if ($a.Contains('verification') -and $a.verification) { $l.Add('  Confirmation: ' + (($a.verification.Keys | Where-Object { [int] $a.verification[$_] } | ForEach-Object { "$_ $($a.verification[$_])" }) -join ', ')) }
        foreach ($p in @($a.packages)) {
            $tries = $(if ($p.Contains('totalAttempts') -and [int] $p.totalAttempts -gt 1) { " [$($p.totalAttempts) attempts$(if ([int] $p.manualRetries) { ", $($p.manualRetries) manual retr$(if ([int] $p.manualRetries -eq 1) { 'y' } else { 'ies' })" })]" } else { '' })
            $how = $(if ($p.Contains('verification')) { " <$($p.verification)>" } else { '' })
            $l.Add(('  {0,-20} {1} ({2}:{3}){4}{5} {6}' -f $p.status, $p.name, $p.source, $p.packageIdentifier, $tries, $how, $p.message))
        }
        foreach ($s in @($a.additionalSoftware)) { $l.Add(('  {0,-20} {1} (Additional Software) {2}' -f $s.status, $s.name, $s.message)) }
    } else { $l.Add('  Not part of this deployment.') }
    $l.Add('')
    if ($Report.Contains('updatePolicy') -and $Report.updatePolicy) {
        $l.Add('Ongoing Windows Update policy (after the initial updates)')
        $l.Add("  $($Report.updatePolicy.status). $($Report.updatePolicy.message)")
        $l.Add('')
    }
    if ($Report.Contains('wifi') -and $Report.wifi) {
        $l.Add('Wi-Fi profile')
        $l.Add("  $($Report.wifi.status) ($($Report.wifi.profileName)). $($Report.wifi.message)")
        $l.Add('')
    }
    $l.Add('Hardware & drivers')
    $d = $Report.drivers
    if ($d -and $d.Contains('status')) {
        $l.Add("  Result: $($d.status) ($($d.state)). $($d.reason)")
        if ($d.health) { $l.Add("  Health: $($d.health.status)") }
        if ($d.summary) { $l.Add(('  Devices: {0}, healthy {1}, basic driver {2}, missing {3}, not working {4}, restart pending {5}, possible hardware issue {6}' -f $d.summary.devices, $d.summary.healthy, $d.summary.basicDriver, $d.summary.driverMissing, $d.summary.malfunctioning, $d.summary.restartPending, $d.summary.hardwareIssue)) }
        foreach ($x in @($d.installed)) { $l.Add("  INSTALLED  $($x.device) ($($x.source)$(if ($x.package) { " $($x.package.provider) $($x.package.version)" }))") }
        foreach ($x in @($d.manualActions)) { $l.Add("  MANUAL     $($x.text)") }
        if (@($d.optionalApplications).Count) { $l.Add("  Optional vendor applications (not installed by the driver stage): $(@($d.optionalApplications) -join ', ')") }
        $l.Add("  Details: $($d.report)")
    } elseif ($d -and $d.state -eq 'NotPartOfDeployment') {
        $l.Add('  Not part of this deployment; nothing was installed or changed.')
    } else {
        $l.Add('  Not implemented in this version; nothing was installed or changed.')
    }
    $l.Add('')
    if ($Report.Contains('devices') -and $Report.devices) {
        $dv = $Report.devices
        $l.Add('Device Manager (at the end of the deployment)')
        if (-not $dv.checked) { $l.Add("  Not checked: $($dv.error)") }
        elseif (-not @($dv.unresolved).Count) { $l.Add("  $($dv.devices) device(s); none reports a problem.") }
        else {
            $l.Add("  $($dv.devices) device(s); $(@($dv.unresolved).Count) need attention:")
            foreach ($d in @($dv.unresolved)) {
                $l.Add(('  {0,-20} {1} ({2}{3})' -f $d.kind, $d.name, $(if ($d.class) { "$($d.class), " }), $(if ($d.problemCode) { "code $($d.problemCode): $($d.problem)" } else { $d.problem })))
                if (@($d.hardwareIds).Count) { $l.Add("                       hardware ID: $(@($d.hardwareIds) -join '; ')") }
                $l.Add("                       $($d.note)")
                if ($d.Contains('driverSource') -and $d.driverSource) { $l.Add("                       $($d.driverSource)") }
            }
        }
        $l.Add('')
    }
    if ($Report.Contains('restartHistory') -and @($Report.restartHistory).Count) {
        $l.Add('Restarts during the deployment')
        foreach ($x in @($Report.restartHistory)) { $l.Add("  $($x.bootUtc)  $(if ($x.planned) { "planned ($($x.by)$(if ($x.reason) { ": $($x.reason)" }))" } else { 'UNEXPECTED (not scheduled by the deployment)' })") }
        $l.Add('')
    }
    if ($Report.Contains('office') -and $Report.office) {
        $o = $Report.office
        $l.Add("Microsoft Office: $($o.product)")
        $l.Add("  Installation: $($o.status) ($($o.state))$(if ($o.verified) { ', verified' })$(if ($o.alreadyInstalled) { ', was already installed' })$(if ($o.version) { ", version $($o.version)" }). $($o.detail)")
        if ($o.source) { $l.Add("  Installer: $($o.source.repository) commit $($o.source.installer.commit); configuration from branch $($o.source.configuration.branch) commit $($o.source.configuration.commit)") }
        $l.Add('  Installing Office does not activate it; see Activation.')
        $l.Add('')
    }
    if ($Report.Contains('activation') -and $Report.activation) {
        $a = $Report.activation
        $l.Add('Activation (separate from the installation results)')
        foreach ($k in 'windows', 'office') {
            $e = $a[$k]
            $label = $(if ($k -eq 'windows') { 'Windows' } else { 'Office ' })
            if ($e) { $l.Add("  ${label}: $($e['status'])$(if ($e['verified']) { ' (verified by the licensing service)' }). $($e['message'])") }
            elseif ([string] $a.plan[$k]['action'] -ne 'none') { $l.Add("  ${label}: not attempted.") }
            else { $l.Add("  ${label}: no activation was requested.") }
        }
        $l.Add('')
    }
    if ($Report.Contains('restartCoordination') -and $Report.restartCoordination) {
        $rc = $Report.restartCoordination
        $l.Add('Restart required by Windows (at the end of the deployment)')
        $l.Add("  $(if ($rc.outstanding) { "OUTSTANDING: $(@($rc.reasons) -join '; ')$(if ($rc.message) { " $($rc.message)" })" } else { 'None outstanding.' })  Automatic restarts by the deployment: $($rc.automaticRestarts).")
        foreach ($h in @($rc.history)) { $l.Add("  $($h.atUtc)  automatic restart $($h.restart): $(@($h.reasons) -join '; ')") }
        $l.Add('')
    }
    if ($Report.Contains('updateRecheck') -and $Report.updateRecheck) {
        $l.Add('Windows Update re-check (after the stages finished)')
        $l.Add("  $($Report.updateRecheck['status']): $($Report.updateRecheck['message'])")
        $l.Add('')
    }
    if ($Report.Contains('recoveries') -and @($Report.recoveries).Count) {
        $l.Add('Recoveries')
        foreach ($x in @($Report.recoveries)) { $l.Add("  $($x.atUtc)  $($x.action) by $($x.by)$(if ($x.Contains('stage')) { ": $($x.stage)" })$(if ($x.Contains('reason') -and $x.reason) { " ($($x.reason))" })$(if ([string] $x.action -like 'Automatic*' -and @($x.refused).Count) { ' - FAILED' })") }
        $l.Add('')
    }
    $l.Add('Incomplete stages')
    if (@($Report.incompleteStages).Count) { foreach ($x in $Report.incompleteStages) { $l.Add("  - $x") } } else { $l.Add('  None.') }
    $l.Add('')
    $l.Add('Errors')
    if (@($Report.errors).Count) { foreach ($x in $Report.errors) { $l.Add("  - $x") } } else { $l.Add('  None.') }
    $l.Add('')
    $l.Add('Remaining tasks')
    foreach ($x in $Report.remainingTasks) { $l.Add("  - $x") }
    $l.Add('')
    if ($Report.Contains('outstanding')) {
        $l.Add('Outstanding work (kept for recovery)')
        if (@($Report.outstanding).Count) {
            foreach ($x in $Report.outstanding) { $l.Add(('  {0,-22} {1} [{2}]: {3}' -f $x.lifecycle, $x.name, $x.operationId, $x.action)) }
        } else { $l.Add('  None.') }
        $l.Add('')
    }
    if ($Report.Contains('health') -and $Report.health) {
        $l.Add('Deployment verification (Phase 9, read-only)')
        $l.Add("  $($Report.health.status): $($Report.health.summary)")
        $l.Add("  Dashboard: $($Report.health.technicianReport)")
        $l.Add('')
    }
    if ($Report.Contains('restoration') -and $Report.restoration) {
        $x = $Report.restoration
        $l.Add('Application restoration')
        if ($x.counts) { $l.Add('  ' + (($x.counts.Keys | Sort-Object | ForEach-Object { "$_ $($x.counts[$_])" }) -join ', ')) }
        if ($x.backupId) { $l.Add("  Settings backup $($x.backupId): $($x.backup.status). $($x.backup.message)") }
        foreach ($s in @($x.settings)) { $l.Add(('  {0,-32} {1}: {2}' -f $s.name, $s.outcome, $s.detail)) }
        $l.Add("  Details: $($x.file)")
        $l.Add('')
    }
    $l.Add('Logs')
    foreach ($k in $Report.logs.Keys) { $l.Add(('  {0,-14} {1}' -f $k, $Report.logs[$k])) }
    $l.Add('')
    $l.Add("Recovery: $($Report.recovery)")
    if ($Report.Contains('recoveryCommands') -and $Report.recoveryCommands) {
        foreach ($k in $Report.recoveryCommands.Keys) { $l.Add(('  {0,-12} {1}' -f $k, $Report.recoveryCommands[$k])) }
    }
    return ($l -join "`r`n") + "`r`n"
}

function Write-WddReport {
    param($Report, [hashtable] $Paths)
    Write-WddJson $Paths.ReportJson $Report
    [System.IO.File]::WriteAllText($Paths.ReportText, (Format-WddReport $Report), (New-Object System.Text.UTF8Encoding($true)))
}

<#
    Ends the deployment: report, marker, event, shortcuts, monitor task removal. State is kept.
#>
function Complete-WddDeployment {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $State, $Snapshot, [switch] $DeadlineReached)
    if (Get-Command Step-WddUpdatePolicy -ErrorAction SilentlyContinue) { $null = Step-WddUpdatePolicy $Manifest $Paths $State $Snapshot -Force }
    $overall = Get-WddOverall $Snapshot.stages -DeadlineReached:$DeadlineReached
    # A policy that could not be applied is a follow-up, never a silent success.
    if ($overall -eq 'Succeeded' -and $Manifest.ContainsKey('updatePolicy') -and $Manifest.updatePolicy -and -not ($State.ContainsKey('updatePolicy') -and $State.updatePolicy -and $State.updatePolicy.status -in 'Applied', 'AlreadyApplied')) { $overall = 'CompletedWithFollowUp' }
    # Orchestrator 1.2.0: devices that still need attention are a follow-up too.
    $State.deviceReport = Get-WddDeviceReport
    # Orchestrator 1.3.0: the check runs after the deployment's last restart (the boot it ran in is recorded).
    try { $State.deviceReport.bootUtc = (Get-WddBootTime).ToString('o') } catch { }
    if ($overall -eq 'Succeeded' -and (@($State.deviceReport.unresolved).Count -or -not $State.deviceReport.checked)) { $overall = 'CompletedWithFollowUp' }
    # A restart Windows still needs, or updates Windows still offers, is a follow-up too.
    if ($overall -eq 'Succeeded' -and ((Test-WddRestartOutstanding $State) -or ($State['updateRecheck'] -is [hashtable] -and [string] $State['updateRecheck']['status'] -in 'Remaining', 'CheckFailed'))) { $overall = 'CompletedWithFollowUp' }
    # Schema 9: activation that needs a person is a follow-up, never an installation failure.
    if ($overall -eq 'Succeeded' -and (Get-Command Test-WddActivationAttention -ErrorAction SilentlyContinue) -and (Test-WddActivationAttention $State)) { $overall = 'CompletedWithFollowUp' }
    if ($overall -eq 'Succeeded' -and $Manifest.ContainsKey('activation') -and $Manifest.activation -and $State['activation'] -isnot [hashtable]) { $overall = 'CompletedWithFollowUp' }
    $reason = if ($DeadlineReached -and -not $Snapshot.allFinal) { "The deployment deadline ($($State.deadlineUtc)) passed before every stage finished." } elseif (@($Snapshot.stages).Count -eq 0) { 'No post-installation stage was enabled.' } else { 'Every enabled stage has a final result.' }
    $report = New-WddReport $Manifest $Paths $State $Snapshot $overall $reason
    Write-WddReport $report $Paths
    $now = (Get-WddNow).ToString('o')
    Write-WddJson $Paths.Marker ([ordered]@{ status = $overall; finishedUtc = $now; report = $Paths.ReportJson })
    $State.status = 'Completed'; $State.overall = $overall; $State.completedUtc = $now; $State.message = $reason
    Save-WddState $Paths $State
    $Snapshot.deploymentState = 'Completed'
    $Snapshot.overall = $overall
    Set-WddSnapshotOutcome $Snapshot $State
    Write-WddJson $Paths.Status $Snapshot
    Write-WddLog "FINISHED: $overall. $reason Report: $($Paths.ReportText)" $(if ($overall -eq 'Succeeded') { 'INFO' } else { 'WARN' })
    $eventId = switch ($overall) { 'Succeeded' { 3100 } 'CompletedWithFollowUp' { 3101 } 'CompletedWithFailures' { 3102 } 'Failed' { 3103 } default { 3104 } }
    Write-WddEvent $eventId "Deployment $($Manifest.packageId) finished: $overall. $reason Report: $($Paths.ReportText)" $(if ($overall -eq 'Succeeded') { 'Information' } elseif ($overall -eq 'Failed') { 'Error' } else { 'Warning' })
    Add-WddActivity $Paths "Deployment finished: $overall. $reason$(if (@($report.devices.unresolved).Count) { " $(@($report.devices.unresolved).Count) device(s) need attention." }) Report: $($Paths.ReportText)" $(if ($overall -eq 'Succeeded') { 'info' } elseif ($overall -eq 'Failed') { 'error' } else { 'warning' })
    # Phase 9: verify what the stages reported against Windows itself, now that the state says Completed.
    $health = $null
    if (Get-Command Invoke-WdhAfterDeployment -ErrorAction SilentlyContinue) {
        try { $health = Invoke-WdhAfterDeployment $Manifest $Paths } catch { Write-WddLog "Deployment verification could not run: $($_.Exception.Message)" 'WARN' }
        if ($health) {
            $report.health = [ordered]@{ status = $health.Status; summary = [string] $health.Report.overall.summary; readyForDelivery = [bool] $health.Report.overall.readyForDelivery; verificationId = [string] $health.Report.verificationId
                                         report = $health.Path; technicianReport = (Join-Path $health.Directory 'technician-report.html'); customerReport = (Join-Path $health.Directory 'customer-handoff.html') }
            Write-WddReport $report $Paths
        }
    }
    try {
        Remove-WddShortcut 'Deployment progress'
        New-WddShortcut 'Deployment report' (Join-Path $env:SystemRoot 'System32\notepad.exe') "`"$($Paths.ReportText)`"" 'Windows Deployment Builder: deployment report'
        if ($health) {
            $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            New-WddShortcut $script:HealthShortcut $ps "-NoProfile -ExecutionPolicy Bypass -File `"$([IO.Path]::GetFullPath($script:HealthScript))`" -Mode Dashboard -Elevate" 'Windows Deployment Builder: verify the deployment (read-only) and open the health report'
        }
    } catch { Write-WddLog "Could not update the desktop shortcuts: $($_.Exception.Message)" 'WARN' }
    try { Unregister-WddTask '\WindowsDeploymentBuilder\' 'Deployment' } catch { Write-WddLog "Could not remove the monitor task: $($_.Exception.Message)" 'WARN' }
    # Orchestrator 1.2.0: the progress window no longer opens at sign-in.
    try { Unregister-WddTask '\WindowsDeploymentBuilder\' 'Progress' } catch { Write-WddLog "Could not remove the progress window task: $($_.Exception.Message)" 'WARN' }
    return $overall
}

if ($script:CompleteMain) {
    $package = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $manifest = Read-WddManifest (Join-Path $package 'deployment-manifest.json')
    $paths = Get-WddPaths $manifest.dataRoot
    Initialize-WddLogging $paths
    $state = (Read-WddDeploymentState $paths).State
    if (-not $state) { Write-Output 'No deployment state found.'; exit 1 }
    $snapshot = Get-WddSnapshot $manifest $paths $state
    if ($script:CompleteArgs.Finish) {
        $overall = Complete-WddDeployment $manifest $paths $state $snapshot -DeadlineReached
        Write-Output "Deployment ended: $overall. Report: $($paths.ReportText)"
    } else {
        $report = New-WddReport $manifest $paths $state $snapshot $snapshot.overall 'Preview of the current state (the deployment continues).'
        Format-WddReport $report
    }
    exit 0
}
