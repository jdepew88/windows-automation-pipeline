#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Deployment Builder - read-only HTTP deployment monitor for the local network.

.DESCRIPTION
    A small status page that a technician opens from another computer, phone or tablet while the
    deployment runs: http://<this computer's address>:<port>/#t=<access token>. It shows the overall
    status, Windows Update, applications, drivers, devices, recent activity and, at the end, the
    final results. The page refreshes every 7 seconds.

    It reuses what the deployment already writes (state, engine status and result files, the
    activity feed, the final report) through the same functions as the progress window; it never
    starts, stops or changes anything. Windows-native only: System.Net.HttpListener (HTTP.sys) in
    Windows PowerShell 5.1; no Node.js, IIS, Docker, WinGet or Internet connection.

    Runs as SYSTEM from \WindowsDeploymentBuilder\StatusServer (registered by
    Initialize-Deployment.ps1 when the package enables the monitor; started at every startup,
    restarted if it stops). Independent of the progress window and of the engines.

    Security (read-only by construction):
      - GET and HEAD only. Three static resources without data (/, /app.js, /app.css) and one data
        endpoint, /api/status, that requires "Authorization: Bearer <token>". Anything else is 404/405.
      - The token is 256 random bits, kept in <dataRoot>\state\monitor.json for this deployment
        and compared in constant time. It is passed in the URL fragment (#t=...), which browsers
        never send to a server, so it does not appear in request lines, logs or referrers.
      - /api/status is built field by field from a whitelist (names, counts, states, the
        deployment's own messages); passwords, Wi-Fi keys, product keys, tokens and configuration
        are never read into it, and text that looks like a credential is masked.
      - No cross-origin access (no CORS headers), a strict Content-Security-Policy, no framing.
      - Bound to 127.0.0.1 unless the package enables LAN access. With LAN access, one inbound
        Windows Firewall rule is added: TCP <port>, Private profile, local subnet only. It is
        removed when the monitor stops. Router port forwarding is never configured.
      - Without a network the deployment and the progress window are unaffected; the monitor then
        answers on this computer only.

    After the deployment has finished the page shows the final results (read-only) for
    finalReportHours, then the monitor removes its firewall rule and its task and stops.

      -Mode Serve    (default) run the server (the scheduled task)
      -Mode Library  define the functions only (tests)
#>
[CmdletBinding()]
param(
    [ValidateSet('Serve', 'Library')]
    [string] $Mode = 'Serve'
)

$script:MonMain = $MyInvocation.InvocationName -ne '.' -and $Mode -eq 'Serve'
. (Join-Path $PSScriptRoot '..\common\DeploymentCommon.ps1')
Set-StrictMode -Version 2.0

$script:MonitorVersion = '1.0.0'
$script:MonitorFormat = 'windows-deployment-builder/monitor-status'
$script:FirewallRuleName = 'WindowsDeploymentBuilder-Monitor'
$script:TokenPattern = '^[A-Za-z0-9_-]{43}$'

# ------------------------------------------------------------------------------------------------
# Adapters (replaced by the tests)
# ------------------------------------------------------------------------------------------------

function New-WddMonitorToken {
    $b = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    ([Convert]::ToBase64String($b)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

<# IPv4 addresses other devices can use (no loopback, no link-local 169.254.x.x). #>
function Get-WddLanAddresses {
    @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and [string] $_.AddressState -eq 'Preferred' } | ForEach-Object { [string] $_.IPAddress } | Sort-Object -Unique)
}

<# Categories of the connected networks: Public, Private, DomainAuthenticated. #>
function Get-WddNetworkCategories { @(Get-NetConnectionProfile -ErrorAction Stop | ForEach-Object { [string] $_.NetworkCategory }) }

function Set-WddMonitorFirewall {
    param([int] $Port)
    Get-NetFirewallRule -Name $script:FirewallRuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name $script:FirewallRuleName -DisplayName 'Windows Deployment Builder - deployment monitor (read-only)' -Group 'Windows Deployment Builder' `
        -Description 'Read-only deployment status page. Private networks, local subnet only. Removed when the deployment monitor stops.' `
        -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Private -RemoteAddress LocalSubnet -ErrorAction Stop | Out-Null
}

function Remove-WddMonitorFirewall { Get-NetFirewallRule -Name $script:FirewallRuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue }

function Remove-WddStatusServerTask { Unregister-WddTask '\WindowsDeploymentBuilder\' 'StatusServer' }

# ------------------------------------------------------------------------------------------------
# Settings, token, address
# ------------------------------------------------------------------------------------------------

<# The manifest's monitor block with defaults; port, refresh and lifetime are clamped. #>
function Get-WddMonitorSettings {
    param([hashtable] $Manifest)
    $s = @{ enabled = $false; port = 8765; lanAccess = $false; refreshSeconds = 7; finalReportHours = 24 }
    if ($Manifest.ContainsKey('monitor') -and $Manifest.monitor -is [hashtable]) { foreach ($k in @($s.Keys)) { if ($Manifest.monitor.ContainsKey($k) -and $null -ne $Manifest.monitor[$k]) { $s[$k] = $Manifest.monitor[$k] } } }
    $s.enabled = [bool] $s.enabled
    $s.lanAccess = [bool] $s.lanAccess
    $s.port = [int] [Math]::Min(65535, [Math]::Max(1024, [int] $s.port))
    $s.refreshSeconds = [int] [Math]::Min(60, [Math]::Max(2, [int] $s.refreshSeconds))
    $s.finalReportHours = [int] [Math]::Min(168, [Math]::Max(0, [int] $s.finalReportHours))
    return $s
}

<#
    Writes state\monitor.json (port, mode, token, addresses, a message for the progress window) and
    returns it. The token of this deployment is kept across restarts, so a bookmarked address keeps
    working. With LAN access the firewall rule is (re)created here.
#>
function Initialize-WddMonitorInfo {
    param([hashtable] $Paths, [hashtable] $Settings, [switch] $Refresh)
    $old = Read-WddJson $Paths.MonitorInfo
    $token = $(if ($old -is [hashtable] -and [string] $old['token'] -match $script:TokenPattern) { [string] $old['token'] } else { New-WddMonitorToken })
    $info = [ordered]@{ format = 'windows-deployment-builder/monitor-info'; port = $Settings.port; lanAccess = $Settings.lanAccess; token = $token; mode = 'serving'
                        urls = @("http://127.0.0.1:$($Settings.port)"); firewall = 'NotNeeded'; message = ''; startedUtc = (Get-WddNow).ToString('o') }
    if ($Settings.lanAccess) {
        $addresses = @()
        try { $addresses = @(Get-WddLanAddresses) } catch { Write-WddLog "Monitor: network addresses could not be read: $($_.Exception.Message)" 'WARN' }
        $info.urls = @(@($addresses | ForEach-Object { "http://$($_):$($Settings.port)" }) + @("http://127.0.0.1:$($Settings.port)"))
        # A refresh (every minute) keeps an existing rule; it is only (re)created at start or after a failure.
        if ($Refresh -and $old -is [hashtable] -and [string] $old['firewall'] -eq 'Added') { $info.firewall = 'Added' }
        else { try { Set-WddMonitorFirewall $Settings.port; $info.firewall = 'Added' } catch { $info.firewall = "Failed: $($_.Exception.Message)" } }
        if ($old -is [hashtable] -and $old['startedUtc']) { $info.startedUtc = $old['startedUtc'] }
        $cats = @()
        try { $cats = @(Get-WddNetworkCategories) } catch { }
        if (-not $addresses.Count) { $info.message = 'No network connection yet: the monitor answers on this computer only. The deployment continues normally.' }
        elseif ($info.firewall -ne 'Added') { $info.message = "The firewall rule could not be added ($($info.firewall)); other devices may not reach the monitor." }
        elseif ($cats.Count -and -not @($cats | Where-Object { $_ -ne 'Public' }).Count) { $info.message = 'This network is set to Public, so Windows Firewall blocks the monitor from other devices. To use it, set the network to Private (Settings > Network & internet > the connection > Private network).' }
    }
    $same = $Refresh -and $old -is [hashtable] -and ((@($old['urls']) -join ' ') -eq (@($info.urls) -join ' ')) -and [string] $old['message'] -eq $info.message -and [string] $old['firewall'] -eq $info.firewall
    if (-not $same) { Write-WddJson $Paths.MonitorInfo $info }
    return $info
}

<# Constant-time comparison of the presented token with the expected one. #>
function Test-WddMonitorToken {
    param([string] $Given, [string] $Expected)
    if (-not $Given -or -not $Expected) { return $false }
    $a = [Text.Encoding]::ASCII.GetBytes($Given)
    $b = [Text.Encoding]::ASCII.GetBytes($Expected)
    $diff = $a.Length -bxor $b.Length
    for ($i = 0; $i -lt $b.Length; $i++) { $x = $(if ($i -lt $a.Length) { $a[$i] } else { 0 }); $diff = $diff -bor ($x -bxor $b[$i]) }
    return $diff -eq 0
}

# ------------------------------------------------------------------------------------------------
# The status model (whitelisted fields only)
# ------------------------------------------------------------------------------------------------

<# The deployment's own text, shortened, with anything that looks like a credential masked. #>
function Protect-WddText {
    param($Text, [int] $Max = 400)
    if ($null -eq $Text) { return '' }
    $t = ([string] $Text) -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ' '
    $t = $t -replace '(?i)\b(password|passwd|pwd|passphrase|psk|wpa2?|key|token|secret|productkey)\b(\s*[:=]\s*)\S+', '$1$2[hidden]'
    $t = $t -replace '\b[A-Z0-9]{5}(-[A-Z0-9]{5}){4}\b', '[product key hidden]'
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max - 3) + '...' }
    return $t
}

function Get-WddNumber { param($Map, [string] $Key) if ($Map -and $Map.Contains($Key) -and $null -ne $Map[$Key]) { return [int] $Map[$Key] }; return $null }

function ConvertTo-WddStageModel {
    param($S)
    if (-not $S) { return $null }
    [ordered]@{
        state = [string] $S.state; condition = [string] $S.condition; phase = [string] $S.status
        activity = Protect-WddText $S.activity; waitingReason = Protect-WddText $S.waitingReason
        lastActivityUtc = $S.lastActivityUtc; lastError = Protect-WddText $S.lastError; lastErrorUtc = $S.lastErrorUtc
        reboots = [int] $S.reboots; stale = [bool] $S.stale
    }
}

<#
    The model behind /api/status. Built only from the fields named here; the snapshot, the engines'
    result files and the final report are read, never returned as they are.
#>
function Get-WddMonitorStatus {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $Settings)
    $now = (Get-WddNow).ToString('o')
    $m = [ordered]@{ format = $script:MonitorFormat; version = 1; serverTimeUtc = $now; refreshSeconds = $Settings.refreshSeconds
                     computerName = Protect-WddText $env:COMPUTERNAME 64; deploymentId = [string] $Manifest.packageId; status = 'waiting'; statusText = ''
                     overall = ''; startedUtc = $null; completedUtc = $null; lastActivityUtc = $null; restartPending = $false
                     windowsUpdate = $null; applications = $null; drivers = $null; attention = @(); activity = @(); final = $null }
    $read = Read-WddDeploymentState $Paths
    $state = $read.State
    if ($read.Source -eq 'corrupt') { $m.status = 'attention'; $m.statusText = 'The deployment state file is damaged; see the deployment log on the computer.'; return $m }
    if (-not $state) { $m.statusText = 'The deployment has not started yet.'; return $m }
    $snap = Get-WddSnapshot $Manifest $Paths $state
    $m.status = [string] $snap.condition
    $m.statusText = Protect-WddText $(if ([string] $state.status -eq 'Completed') { "Finished: $($state.overall). $($state.message)" } else { $snap.outcomeDetail })
    $m.overall = [string] $state['overall']
    $m.startedUtc = $state['initializedUtc']; $m.completedUtc = $state['completedUtc']
    $m.lastActivityUtc = $snap.lastActivityUtc
    # Orchestrator 1.3.0: also a restart Windows needs that the deployment is about to do.
    $m.restartPending = [bool] ($snap.restartPending -or ($snap.Contains('restart') -and $snap.restart.status -in 'Announced', 'Blocked', 'Restarting'))
    $m.attention = @(@($snap.needsAttention) | Select-Object -First 10 | ForEach-Object { Protect-WddText $_ })
    $stage = @{}
    foreach ($s in @($snap.stages)) { $stage[$s.id] = $s }

    if ($stage.ContainsKey('windowsUpdate')) {
        $s = $stage['windowsUpdate']
        $w = ConvertTo-WddStageModel $s
        $w.current = Protect-WddText $s.current
        $w.installed = Get-WddNumber $s.counts 'installed'
        $w.failed = Get-WddNumber $s.counts 'failed'
        $w.needsPerson = Get-WddNumber $s.counts 'requiresInteraction'
        $w.installedOptional = Get-WddNumber $s.counts 'installedOptional'
        $w.installedDrivers = Get-WddNumber $s.counts 'installedDrivers'
        $w.attempt = Get-WddNumber $s.counts 'attempt'
        $w.maxAttempts = Get-WddNumber $s.counts 'maxAttempts'
        $w.rebootRequired = [bool] ($snap.restartPending -or [string] $s.status -in 'Rebooting', 'RebootDeferred')
        # The Windows Update Agent calls used do not report bytes: no percentage or speed is invented.
        $w.progress = 'unavailable'
        $m.windowsUpdate = $w
    }
    if ($stage.ContainsKey('applications')) {
        $s = $stage['applications']
        $a = ConvertTo-WddStageModel $s
        $selected = Get-WddNumber $s.counts 'selected'
        $installed = Get-WddNumber $s.counts 'installed'
        $failed = Get-WddNumber $s.counts 'failed'
        if ($s.state -eq 'Final' -and $s.result -is [hashtable] -and $s.result['counts'] -is [hashtable]) {
            $c = $s.result['counts']
            $selected = [int] $c['total'] - [int] $c['skippedByUser']; $installed = [int] $c['succeeded'] + [int] $c['alreadyInstalled']; $failed = [int] $c['failed'] + [int] $c['unavailable']
            $a.needsPerson = [int] $c['requiresInteraction']
        } else { $a.needsPerson = Get-WddNumber $s.counts 'needsPerson' }
        $a.selected = $selected; $a.installed = $installed; $a.failed = $failed
        $a.remaining = $(if ($null -ne $s.total -and $null -ne $s.done -and $s.state -ne 'Final') { [Math]::Max(0, [int] $s.total - [int] $s.done) } elseif ($s.state -eq 'Final') { 0 } else { $null })
        $a.current = Protect-WddText $(if ([string] $s.status -eq 'Installing') { $s.current } else { '' })
        # WinGet does not report download progress to a redirected process: shown as unavailable.
        $a.progress = 'unavailable'; $a.percent = $null; $a.bytesPerSecond = $null
        $m.applications = $a
    }
    $drvReport = Read-WddJson (Join-Path $Paths.Root 'reports\drivers.json')
    if ($stage.ContainsKey('drivers')) {
        $s = $stage['drivers']
        $d = ConvertTo-WddStageModel $s
        $ops = @(if ($drvReport -is [hashtable]) { @($drvReport['operations']) | Where-Object { $_ -is [hashtable] } })
        $d.installed = @($ops | Where-Object { $_['status'] -eq 'Succeeded' }).Count
        $d.failedOrSkipped = @($ops | Where-Object { [string] $_['status'] -like 'Failed*' -or [string] $_['status'] -in 'ManualActionRequired', 'Unsupported' }).Count
        $d.restartPending = [bool] (@($ops | Where-Object { $_['status'] -eq 'WaitingForReboot' }).Count -or $snap.restartPending)
        $m.drivers = $d
    } else {
        $m.drivers = [ordered]@{ state = [string] $snap.drivers.state; condition = 'finished'; activity = 'The driver stage is not part of this deployment; Windows Update installs drivers it offers.' }
    }
    # Schema 9: Office LTSC (product, phase, verified) and activation (status per target, no key).
    if ($stage.ContainsKey('office')) {
        $s = $stage['office']
        $o = ConvertTo-WddStageModel $s
        $o.product = Protect-WddText $(if ($Manifest.ContainsKey('office') -and $Manifest.office) { [string] $Manifest.office.displayName } else { $s.name }) 80
        $o.verified = [bool] ($s.state -eq 'Final' -and $s.result -is [hashtable] -and $s.result['verified'])
        $o.detail = Protect-WddText $s.detail
        # The Office Deployment Tool does not report bytes: the phase is shown, never a percentage.
        $o.progress = 'unavailable'
        $m.office = $o
    }
    if ($snap.Contains('activation') -and $snap.activation) {
        $m.activation = [ordered]@{}
        foreach ($k in 'windows', 'office') {
            $e = $snap.activation[$k]
            if ($e) { $m.activation[$k] = [ordered]@{ action = [string] $e['action']; status = [string] $e['status']; verified = [bool] $e['verified']; message = Protect-WddText $e['message'] } }
        }
    }
    # Devices: the final Device Manager check, or the driver stage's own assessment while it runs.
    $devices = @()
    if ($state.ContainsKey('deviceReport') -and $state.deviceReport -is [hashtable]) { $devices = @(@($state.deviceReport['unresolved']) | Where-Object { $_ -is [hashtable] }) }
    $m.drivers.unresolvedDevices = @($devices | Select-Object -First 25 | ForEach-Object { [ordered]@{ name = Protect-WddText $_['name'] 120; kind = [string] $_['kind']; problemCode = [int] $_['problemCode']; problem = Protect-WddText $_['problem'] 120; hardwareId = Protect-WddText (@($_['hardwareIds']) | Select-Object -First 1) 200; note = Protect-WddText $_['note'] } })

    $events = @(Read-WddActivity $Paths 40)
    [array]::Reverse($events)
    $m.activity = @($events | ForEach-Object { [ordered]@{ utc = [string] $_['utc']; level = $(if ([string] $_['level'] -in 'info', 'warning', 'error') { [string] $_['level'] } else { 'info' }); source = Protect-WddText $_['source'] 32; message = Protect-WddText $_['message'] } })

    if ([string] $state.status -eq 'Completed') { $m.final = Get-WddMonitorFinal $Paths $m }
    return $m
}

<# Final results from the deployment report (whitelisted). #>
function Get-WddMonitorFinal {
    param([hashtable] $Paths, $Model)
    $r = Read-WddJson $Paths.ReportJson
    $f = [ordered]@{ overall = [string] $Model.overall; completed = @(); failed = @(); unresolvedDevices = @($Model.drivers.unresolvedDevices); followUp = @() }
    if ($r -isnot [hashtable]) { return $f }
    $f.overall = [string] $r['overall']
    $w = $r['windowsUpdate']
    if ($w -is [hashtable]) {
        $f.completed += "Windows Update: $([int] $w['installed']) update(s) installed$(if ($null -ne $w['installedOptional']) { " ($([int] $w['installedOptional']) optional, $([int] $w['installedDrivers']) drivers)" }); result $($w['status'])."
        foreach ($x in @($w['failedUpdates']) | Where-Object { $_ -is [hashtable] }) { $f.failed += Protect-WddText "Windows Update $((@($x['kbs']) -join ', ')) $($x['title']): failed after $($x['attempts']) attempt(s) ($($x['lastHResult']))" }
    }
    $a = $r['applications']
    if ($a -is [hashtable]) {
        $pk = @(@($a['packages']) | Where-Object { $_ -is [hashtable] })
        $ok = @($pk | Where-Object { $_['status'] -in 'Succeeded', 'AlreadyInstalled' })
        $f.completed += "Applications: $($ok.Count) of $(@($pk | Where-Object { $_['status'] -ne 'SkippedByUser' }).Count) installed$(if ($a['verification'] -is [hashtable]) { " ($([int] $a['verification']['Verified']) confirmed by WinGet)" })."
        foreach ($x in @($pk | Where-Object { $_['status'] -in 'Failed', 'Unavailable' })) { $f.failed += Protect-WddText "Application $($x['name']): $($x['status']). $($x['message'])" }
    }
    $d = $r['drivers']
    if ($d -is [hashtable] -and $d.ContainsKey('status')) { $f.completed += "Hardware and drivers: $($d['status'])." }
    $f.followUp = @(@($r['remainingTasks']) | Where-Object { $_ } | Select-Object -First 30 | ForEach-Object { Protect-WddText $_ })
    return $f
}

# ------------------------------------------------------------------------------------------------
# HTTP
# ------------------------------------------------------------------------------------------------

$script:SecurityHeaders = [ordered]@{
    'Cache-Control'           = 'no-store'
    'X-Content-Type-Options'  = 'nosniff'
    'Referrer-Policy'         = 'no-referrer'
    'X-Frame-Options'         = 'DENY'
    'Cross-Origin-Resource-Policy' = 'same-origin'
    'Content-Security-Policy' = "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
}

function New-WddResponse {
    param([int] $Status, [string] $ContentType, [string] $Body, [hashtable] $Extra = @{})
    $h = [ordered]@{}
    foreach ($k in $script:SecurityHeaders.Keys) { $h[$k] = $script:SecurityHeaders[$k] }
    foreach ($k in $Extra.Keys) { $h[$k] = $Extra[$k] }
    @{ Status = $Status; ContentType = $ContentType; Body = $Body; Headers = $h }
}

<#
    Answers one request (pure: no network; the server loop and the tests call it).
    $Context: Token, Manifest, Paths, Settings.
#>
function Invoke-WddMonitorRequest {
    param([string] $Method, [string] $Path, [hashtable] $Headers, [hashtable] $Context)
    if ($Method -notin 'GET', 'HEAD') { return New-WddResponse 405 'text/plain; charset=utf-8' 'Method not allowed. This monitor is read-only.' @{ Allow = 'GET, HEAD' } }
    $p = ([string] $Path).Split('?')[0]
    switch ($p) {
        { $_ -in '/', '/index.html' } { return New-WddResponse 200 'text/html; charset=utf-8' $script:DashboardHtml }
        '/app.js' { return New-WddResponse 200 'application/javascript; charset=utf-8' $script:DashboardJs }
        '/app.css' { return New-WddResponse 200 'text/css; charset=utf-8' $script:DashboardCss }
        '/favicon.ico' { return New-WddResponse 204 'text/plain' '' }
        '/api/status' {
            $auth = $(if ($Headers -and $Headers.ContainsKey('Authorization')) { [string] $Headers['Authorization'] } else { '' })
            $given = $(if ($auth -match '^Bearer\s+(\S+)$') { $Matches[1] } else { '' })
            if (-not (Test-WddMonitorToken $given ([string] $Context.Token))) {
                return New-WddResponse 401 'application/json; charset=utf-8' '{"error":"unauthorized","message":"Open the full address shown in the Deployment Progress window; it ends with #t= followed by the access token."}' @{ 'WWW-Authenticate' = 'Bearer realm="deployment-monitor"' }
            }
            $model = $null
            try { $model = Get-WddMonitorStatus $Context.Manifest $Context.Paths $Context.Settings }
            catch {
                # A state file being replaced at this moment, for example: the page tries again in a few seconds.
                Write-WddLog "Monitor: status could not be built: $($_.Exception.Message)" 'WARN'
                return New-WddResponse 503 'application/json; charset=utf-8' '{"error":"unavailable","message":"The status is being updated; trying again shortly."}' @{ 'Retry-After' = '5' }
            }
            return New-WddResponse 200 'application/json; charset=utf-8' ($model | ConvertTo-Json -Depth 8 -Compress)
        }
    }
    return New-WddResponse 404 'text/plain; charset=utf-8' 'Not found.'
}

function Send-WddResponse {
    param($HttpContext, [hashtable] $Response, [bool] $Head)
    $res = $HttpContext.Response
    $res.StatusCode = $Response.Status
    $res.ContentType = $Response.ContentType
    foreach ($k in $Response.Headers.Keys) {
        # Some headers can only be set through properties (HTTP.sys); a header that cannot be set is skipped.
        try { $res.AddHeader($k, [string] $Response.Headers[$k]) } catch { Write-WddLog "Monitor: header $k not sent: $($_.Exception.Message)" 'WARN' }
    }
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes([string] $Response.Body)
    $res.ContentLength64 = $bytes.Length
    if (-not $Head -and $bytes.Length) { $res.OutputStream.Write($bytes, 0, $bytes.Length) }
    $res.Close()
}

<# $true once the final report has been shown for finalReportHours after completion. #>
function Test-WddMonitorExpired {
    param([hashtable] $Paths, [hashtable] $Settings)
    $s = (Read-WddDeploymentState $Paths).State
    if (-not $s -or [string] $s['status'] -ne 'Completed') { return $false }
    $done = ConvertTo-WddDate $s['completedUtc']
    return [bool] ($done -and (Get-WddNow) -ge $done.AddHours($Settings.finalReportHours))
}

<# Removes the firewall rule and the task, and tells the progress window why the monitor stopped. #>
function Stop-WddMonitor {
    param([hashtable] $Paths, [string] $Message)
    try { Remove-WddMonitorFirewall } catch { Write-WddLog "Monitor: firewall rule not removed: $($_.Exception.Message)" 'WARN' }
    $info = Read-WddJson $Paths.MonitorInfo
    if ($info -is [hashtable]) { $info.mode = 'stopped'; $info.message = $Message; $info.stoppedUtc = (Get-WddNow).ToString('o'); try { Write-WddJson $Paths.MonitorInfo $info } catch { } }
    try { Remove-WddStatusServerTask } catch { Write-WddLog "Monitor: task not removed: $($_.Exception.Message)" 'WARN' }
    Write-WddLog "Monitor stopped: $Message"
}

<#
    The server loop: one request at a time (small, read-only answers). Every 60 seconds it refreshes
    the addresses (a network that appears later) and checks whether its time is over.
    -MaxSeconds limits the run (tests).
#>
function Start-WddStatusServer {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $Settings, [hashtable] $Info, [string[]] $Prefixes = @(), [int] $MaxSeconds = 0)
    $listener = New-Object System.Net.HttpListener
    if (-not $Prefixes.Count) { $Prefixes = $(if ($Settings.lanAccess) { @("http://+:$($Settings.port)/") } else { @("http://127.0.0.1:$($Settings.port)/", "http://localhost:$($Settings.port)/") }) }
    foreach ($p in $Prefixes) { $listener.Prefixes.Add($p) }
    $listener.IgnoreWriteExceptions = $true
    $listener.Start()
    Write-WddLog "Monitor $($script:MonitorVersion) listening on $($Prefixes -join ', ') (LAN access: $($Settings.lanAccess))."
    $context = @{ Token = [string] $Info.token; Manifest = $Manifest; Paths = $Paths; Settings = $Settings }
    $started = Get-Date
    $nextCheck = (Get-Date).AddSeconds(60)
    try {
        while ($true) {
            $ar = $listener.BeginGetContext($null, $null)
            $stop = $false
            while (-not $ar.AsyncWaitHandle.WaitOne(1000)) {
                if ($MaxSeconds -gt 0 -and ((Get-Date) - $started).TotalSeconds -ge $MaxSeconds) { $stop = $true; break }
                if ((Get-Date) -ge $nextCheck) {
                    $nextCheck = (Get-Date).AddSeconds(60)
                    if (Test-WddMonitorExpired $Paths $Settings) { $stop = $true; Stop-WddMonitor $Paths "The deployment finished; the final results were shown for $($Settings.finalReportHours) hour(s). The report stays on this computer."; break }
                    if ($Settings.lanAccess) { try { $fresh = Initialize-WddMonitorInfo $Paths $Settings -Refresh; $context.Token = [string] $fresh.token } catch { } }
                }
            }
            if ($stop) { break }
            $http = $listener.EndGetContext($ar)
            try {
                $req = $http.Request
                $h = @{}
                if ($req.Headers['Authorization']) { $h['Authorization'] = [string] $req.Headers['Authorization'] }
                $r = Invoke-WddMonitorRequest $req.HttpMethod $req.Url.AbsolutePath $h $context
                Send-WddResponse $http $r ($req.HttpMethod -eq 'HEAD')
            } catch {
                Write-WddLog "Monitor: request failed: $($_.Exception.Message)" 'WARN'
                try { $http.Response.StatusCode = 500; $http.Response.Close() } catch { }
            }
        }
    } finally {
        try { $listener.Stop() } catch { }
        $listener.Close()
    }
}

# ------------------------------------------------------------------------------------------------
# The page (no data in it; everything comes from /api/status with the token)
# ------------------------------------------------------------------------------------------------

$script:DashboardHtml = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>Deployment Monitor</title>
<link rel="stylesheet" href="/app.css">
<script src="/app.js" defer></script>
</head>
<body>
<header>
  <h1 id="title">Deployment Monitor</h1>
  <p id="subtitle">Windows Deployment Builder - read-only status</p>
</header>
<main>
  <section id="overall" class="card wide" aria-live="polite">
    <div class="row"><span id="badge" class="badge">Connecting</span><span id="statusText">Connecting to the deployment monitor...</span></div>
    <dl class="facts">
      <dt>Computer</dt><dd id="computer">-</dd>
      <dt>Deployment</dt><dd id="deployment">-</dd>
      <dt>Last activity</dt><dd id="lastActivity">-</dd>
      <dt>Last contact with the monitor</dt><dd id="lastContact">-</dd>
    </dl>
    <ul id="attention" class="attention"></ul>
  </section>
  <section class="card" aria-labelledby="wu-h"><h2 id="wu-h">Windows Update</h2><div id="wu"></div></section>
  <section class="card" aria-labelledby="apps-h"><h2 id="apps-h">Applications</h2><div id="apps"></div></section>
  <section class="card" aria-labelledby="drv-h"><h2 id="drv-h">Drivers and devices</h2><div id="drv"></div></section>
  <section id="officeCard" class="card" hidden aria-labelledby="off-h"><h2 id="off-h">Microsoft Office</h2><div id="off"></div></section>
  <section id="activationCard" class="card" hidden aria-labelledby="actv-h"><h2 id="actv-h">Activation</h2><div id="actv"></div></section>
  <section id="finalCard" class="card wide" hidden aria-labelledby="final-h"><h2 id="final-h">Final results</h2><div id="final"></div></section>
  <section class="card wide" aria-labelledby="act-h"><h2 id="act-h">Recent activity</h2><ol id="activity" class="activity"></ol></section>
</main>
<footer><p>Read-only. This page cannot start, stop or change anything on the computer. It refreshes every <span id="refresh">7</span> seconds.</p></footer>
</body>
</html>
'@

$script:DashboardCss = @'
:root { --bg: #f4f6f8; --card: #ffffff; --text: #1b2430; --muted: #5b6776; --line: #dde3ea; --ok: #1e7b3a; --wait: #8a6100; --bad: #b3261e; --act: #1f5fbf; --rec: #6b3fa0; }
@media (prefers-color-scheme: dark) { :root { --bg: #11161c; --card: #1a2129; --text: #e7edf3; --muted: #a3b0bf; --line: #2c3743; --ok: #5cc27a; --wait: #e0b44a; --bad: #ff8a80; --act: #7fb0ff; --rec: #c4a3f0; } }
* { box-sizing: border-box; }
body { margin: 0; font: 15px/1.45 system-ui, "Segoe UI", Roboto, sans-serif; background: var(--bg); color: var(--text); }
header, footer { padding: 16px; max-width: 1100px; margin: 0 auto; }
h1 { margin: 0; font-size: 1.5rem; }
h2 { margin: 0 0 8px; font-size: 1.1rem; }
#subtitle, footer { color: var(--muted); font-size: .9rem; }
main { display: grid; gap: 12px; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); padding: 0 16px 16px; max-width: 1100px; margin: 0 auto; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 10px; padding: 14px; min-width: 0; overflow-wrap: anywhere; }
.wide { grid-column: 1 / -1; }
.row { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
.badge { display: inline-block; padding: 3px 10px; border-radius: 999px; font-weight: 600; color: #fff; background: var(--muted); }
.badge.active { background: var(--act); } .badge.waiting { background: var(--wait); } .badge.recovering { background: var(--rec); }
.badge.complete { background: var(--ok); } .badge.attention { background: var(--bad); } .badge.offline { background: var(--bad); }
.facts { display: grid; grid-template-columns: max-content 1fr; gap: 4px 12px; margin: 10px 0 0; }
.facts dt { color: var(--muted); } .facts dd { margin: 0; }
.attention { margin: 10px 0 0; padding-left: 18px; color: var(--bad); }
.kv { display: grid; grid-template-columns: max-content 1fr; gap: 2px 12px; margin: 8px 0 0; }
.kv span:nth-child(odd) { color: var(--muted); }
.activityText { margin: 0; }
.error { color: var(--bad); }
.activity { list-style: none; margin: 0; padding: 0; }
.activity li { padding: 6px 0; border-top: 1px solid var(--line); display: grid; grid-template-columns: max-content 1fr; gap: 10px; }
.activity li:first-child { border-top: 0; }
.activity time { color: var(--muted); font-variant-numeric: tabular-nums; }
.activity .warning { color: var(--wait); } .activity .error { color: var(--bad); }
ul.plain { margin: 6px 0 0; padding-left: 18px; }
'@

$script:DashboardJs = @'
(function () {
  'use strict';
  var KEY = 'wdbMonitorToken';
  var token = '';
  var timer = null;
  var refresh = 7;
  var lastOk = null;
  try {
    var m = /(?:^#|&)t=([A-Za-z0-9_-]{43})(?:&|$)/.exec(window.location.hash);
    if (m) { token = m[1]; sessionStorage.setItem(KEY, token); history.replaceState(null, '', window.location.pathname); }
    else { token = sessionStorage.getItem(KEY) || ''; }
  } catch (e) { token = token || ''; }

  function $(id) { return document.getElementById(id); }
  function clear(node) { while (node.firstChild) { node.removeChild(node.firstChild); } }
  function el(tag, cls, text) { var n = document.createElement(tag); if (cls) { n.className = cls; } if (text !== undefined && text !== null) { n.textContent = String(text); } return n; }
  function when(iso) { if (!iso) { return 'unknown'; } var d = new Date(iso); if (isNaN(d.getTime())) { return 'unknown'; } var s = Math.round((Date.now() - d.getTime()) / 1000); var ago = s < 60 ? 'just now' : s < 7200 ? Math.round(s / 60) + ' min ago' : Math.round(s / 3600) + ' h ago'; return d.toLocaleTimeString() + ' (' + ago + ')'; }
  function kv(parent, pairs) { var g = el('div', 'kv'); pairs.forEach(function (p) { if (p[1] === null || p[1] === undefined || p[1] === '') { return; } g.appendChild(el('span', null, p[0])); g.appendChild(el('span', null, p[1])); }); parent.appendChild(g); }
  function text(parent, t, cls) { if (t) { parent.appendChild(el('p', cls || 'activityText', t)); } }
  var LABEL = { active: 'Active', waiting: 'Waiting', recovering: 'Recovering', complete: 'Complete', attention: 'Attention required', offline: 'Monitor unreachable' };

  function badge(status, extra) { var b = $('badge'); b.className = 'badge ' + status; b.textContent = LABEL[status] || status; if (extra) { $('statusText').textContent = extra; } }

  function render(s) {
    refresh = s.refreshSeconds || 7; $('refresh').textContent = refresh;
    $('title').textContent = 'Deployment Monitor - ' + (s.computerName || '');
    document.title = (LABEL[s.status] || s.status) + ' - ' + (s.computerName || 'Deployment');
    badge(s.status, s.statusText || '');
    $('computer').textContent = s.computerName || '-';
    $('deployment').textContent = s.deploymentId || '-';
    $('lastActivity').textContent = when(s.lastActivityUtc);
    var at = $('attention'); clear(at); (s.attention || []).forEach(function (a) { at.appendChild(el('li', null, a)); });

    var wu = $('wu'); clear(wu);
    if (s.windowsUpdate) {
      var w = s.windowsUpdate;
      text(wu, w.activity);
      kv(wu, [['Current update', w.current || ''], ['Attempt', w.attempt ? (w.attempt + ' of ' + (w.maxAttempts || '?')) : ''],
              ['Installed', w.installed], ['Optional / drivers', w.installedOptional !== null && w.installedOptional !== undefined ? (w.installedOptional + ' / ' + w.installedDrivers) : ''],
              ['Failed', w.failed], ['Need a person', w.needsPerson], ['Restart required', w.rebootRequired ? 'Yes' : 'No'],
              ['Download progress', w.phase === 'Downloading' ? 'progress unavailable' : '']]);
      if (w.lastError) { text(wu, 'Most recent error: ' + w.lastError, 'error'); }
    } else { text(wu, 'Not part of this deployment.'); }

    var ap = $('apps'); clear(ap);
    if (s.applications) {
      var a = s.applications;
      if (a.current) { text(ap, 'Installing ' + a.current + ' - progress unavailable'); }
      text(ap, a.activity);
      kv(ap, [['Selected', a.selected], ['Installed', a.installed], ['Remaining', a.remaining], ['Failed', a.failed], ['Need a person', a.needsPerson]]);
      if (a.lastError) { text(ap, a.lastError, 'error'); }
    } else { text(ap, 'Not part of this deployment.'); }

    var off = $('off'); clear(off); $('officeCard').hidden = !s.office;
    if (s.office) {
      var o = s.office;
      text(off, o.activity);
      kv(off, [['Edition', o.product], ['Phase', o.phase], ['Verified', o.state === 'Final' ? (o.verified ? 'Yes' : 'No') : ''], ['Download progress', o.phase === 'Downloading' ? 'progress unavailable' : '']]);
      if (o.state === 'Final' && o.detail) { text(off, o.detail); }
      if (o.lastError) { text(off, 'Most recent error: ' + o.lastError, 'error'); }
    }
    var av = $('actv'); clear(av); $('activationCard').hidden = !s.activation;
    if (s.activation) {
      [['Windows', s.activation.windows], ['Office', s.activation.office]].forEach(function (p) {
        if (p[1]) { kv(av, [[p[0], p[1].status + (p[1].verified ? ' (verified)' : '')]]); text(av, p[1].message); }
      });
    }

    var dv = $('drv'); clear(dv);
    if (s.drivers) {
      var d = s.drivers;
      text(dv, d.activity);
      kv(dv, [['Installed', d.installed], ['Failed or skipped', d.failedOrSkipped], ['Restart pending', d.restartPending === undefined ? '' : (d.restartPending ? 'Yes' : 'No')],
              ['Unresolved devices', (d.unresolvedDevices || []).length]]);
      if ((d.unresolvedDevices || []).length) {
        var ul = el('ul', 'plain');
        d.unresolvedDevices.forEach(function (x) { ul.appendChild(el('li', null, x.name + ' (' + (x.problemCode ? 'code ' + x.problemCode + ': ' : '') + x.problem + ')' + (x.hardwareId ? ' [' + x.hardwareId + ']' : '') + '. ' + x.note)); });
        dv.appendChild(ul);
      }
    }

    var fc = $('finalCard'), f = $('final'); clear(f);
    if (s.final) {
      fc.hidden = false;
      text(f, 'Overall result: ' + s.final.overall);
      [['Completed', s.final.completed], ['Failed', s.final.failed], ['Technician follow-up', s.final.followUp]].forEach(function (g) {
        if (!g[1] || !g[1].length) { return; }
        f.appendChild(el('h3', null, g[0]));
        var list = el('ul', 'plain'); g[1].forEach(function (t) { list.appendChild(el('li', null, t)); }); f.appendChild(list);
      });
    } else { fc.hidden = true; }

    var act = $('activity'); clear(act);
    (s.activity || []).forEach(function (e) { var li = el('li'); li.appendChild(el('time', null, when(e.utc))); li.appendChild(el('span', e.level, e.message)); act.appendChild(li); });
    if (!(s.activity || []).length) { act.appendChild(el('li', null, 'No activity recorded yet.')); }
  }

  function schedule() { if (timer) { clearTimeout(timer); } timer = setTimeout(poll, refresh * 1000); }

  function poll() {
    if (!token) { badge('attention', 'No access token. Open the full address shown in the Deployment Progress window on the computer (it ends with #t=...).'); return; }
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '/api/status', true);
    xhr.setRequestHeader('Authorization', 'Bearer ' + token);
    xhr.timeout = 10000;
    xhr.onload = function () {
      if (xhr.status === 200) {
        try { lastOk = new Date(); $('lastContact').textContent = lastOk.toLocaleTimeString(); render(JSON.parse(xhr.responseText)); } catch (e) { badge('offline', 'The answer could not be read; trying again.'); }
      } else if (xhr.status === 401) {
        try { sessionStorage.removeItem(KEY); } catch (e) { }
        token = ''; badge('attention', 'The access token was not accepted. Open the full address shown in the Deployment Progress window again.'); return;
      } else { badge('offline', 'The monitor answered ' + xhr.status + '; trying again.'); }
      schedule();
    };
    xhr.onerror = xhr.ontimeout = function () {
      badge('offline', 'The computer did not answer' + (lastOk ? ' since ' + lastOk.toLocaleTimeString() : '') + '. It may be restarting; trying again.');
      schedule();
    };
    xhr.send();
  }
  document.addEventListener('DOMContentLoaded', poll);
}());
'@

# ------------------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------------------

if ($script:MonMain) {
    $package = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $manifest = Read-WddManifest (Join-Path $package 'deployment-manifest.json')
    $paths = Get-WddPaths $manifest.dataRoot
    foreach ($d in $paths.Deployment, $paths.Logs, $paths.StateDir) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
    $script:WddLogFile = Join-Path $paths.Logs 'monitor.log'
    $settings = Get-WddMonitorSettings $manifest
    if (-not $settings.enabled) { Write-Output 'The deployment monitor is not enabled in this package.'; exit 0 }
    if (Test-WddMonitorExpired $paths $settings) { Stop-WddMonitor $paths 'The deployment finished; the final results were already shown. The report stays on this computer.'; exit 0 }
    try {
        $info = Initialize-WddMonitorInfo $paths $settings
        Start-WddStatusServer $manifest $paths $settings $info
    } catch {
        $msg = "The monitor could not start: $($_.Exception.Message) The deployment continues; the progress window still shows the status."
        Write-WddLog $msg 'ERROR'
        $info = Read-WddJson $paths.MonitorInfo
        if ($info -is [hashtable]) { $info.mode = 'error'; $info.message = $msg; try { Write-WddJson $paths.MonitorInfo $info } catch { } }
        exit 1
    }
    exit 0
}
