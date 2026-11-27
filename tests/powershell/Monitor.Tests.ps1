#Requires -Version 5.1
<#
    Scenario tests for the read-only deployment monitor (DeploymentStatusServer.ps1), loaded from the
    REAL generated package, against the simulated computer of the deployment scenarios
    (ProvisioningSim.ps1): authorization, the whitelisted and sanitized status model, read-only
    methods, LAN access and its firewall rule (simulated), partially written files, the final
    report and the end of the monitor. One scenario starts the real HTTP server on 127.0.0.1 (a
    random free port) in a separate process for a few seconds and talks to it over HTTP.

    Nothing here adds a firewall rule, registers a task or listens on anything but 127.0.0.1.

    Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\powershell\Monitor.Tests.ps1 -Fixture <dir>
#>
param([Parameter(Mandatory = $true)] [string] $Fixture)

$ErrorActionPreference = 'Stop'
$pkgScripts = Join-Path $Fixture 'usb\WindowsDeployment\scripts'
$serverScript = Join-Path $pkgScripts 'monitor\DeploymentStatusServer.ps1'
. (Join-Path $pkgScripts 'common\DeploymentCommon.ps1')
. (Join-Path $pkgScripts 'bootstrap\Stage-Deployment.ps1')
. (Join-Path $pkgScripts 'bootstrap\Initialize-Deployment.ps1')
. (Join-Path $pkgScripts 'finalization\Complete-Deployment.ps1')
. (Join-Path $pkgScripts 'orchestrator\DeploymentOrchestrator.ps1')
. $serverScript -Mode Library
$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$script:Failures = 0
$script:Passed = 0
$script:MutexName = "Global\WDD-Test-$([guid]::NewGuid().ToString('N'))"
$usb = Join-Path $Fixture 'usb'
$pkgRoot = Join-Path $usb 'WindowsDeployment'
$manifestPath = Join-Path $pkgRoot 'deployment-manifest.json'
. (Join-Path $PSScriptRoot 'ProvisioningSim.ps1')
. (Join-Path $PSScriptRoot 'HealthSim.ps1')

# The monitor's own system adapters: nothing touches the firewall, the network or the task scheduler.
function Set-WddMonitorFirewall { param([int] $Port) $script:FirewallAdds += $Port }
function Remove-WddMonitorFirewall { $script:FirewallRemoves++ }
function Remove-WddStatusServerTask { $script:ServerTaskRemoved = $true }
function Get-WddLanAddresses { @($script:SimAddresses) }
function Get-WddNetworkCategories { @($script:SimCategories) }

$script:Token = 'Tk0' + ('x' * 40)
function Reset-MonitorSim {
    $script:FirewallAdds = @(); $script:FirewallRemoves = 0; $script:ServerTaskRemoved = $false
    $script:SimAddresses = @('192.168.1.100'); $script:SimCategories = @('Private')
}
function Get-Context { @{ Token = $script:Token; Manifest = $script:Manifest; Paths = $script:Paths; Settings = (Get-WddMonitorSettings $script:Manifest) } }
function Get-Api { param([hashtable] $Headers = @{ Authorization = "Bearer $($script:Token)" }) Invoke-WddMonitorRequest 'GET' '/api/status' $Headers (Get-Context) }

Write-Output "Deployment monitor scenarios (fixture $Fixture)"

Test-Scenario 'unauthenticated or wrong-token requests get no deployment data' {
    Reset-MonitorSim
    Initialize-Embedded | Out-Null
    foreach ($h in @(@{}, @{ Authorization = 'Bearer ' }, @{ Authorization = "Bearer $('Tk1' + ('x' * 40))" }, @{ Authorization = "Bearer $($script:Token)x" }, @{ Authorization = $script:Token }, @{ Authorization = "Basic $($script:Token)" })) {
        $r = Get-Api $h
        Assert-Equal $r.Status 401 "refused: $($h['Authorization'])"
        Assert-True ($r.Body -notmatch [regex]::Escape($script:Manifest.packageId) -and $r.Body -notmatch 'computerName') 'no data in the refusal'
        Assert-Equal $r.Headers['WWW-Authenticate'] 'Bearer realm="deployment-monitor"' 'challenge'
    }
    # A token in the query string is never accepted (it would end up in logs and referrers).
    Assert-Equal (Invoke-WddMonitorRequest 'GET' "/api/status?t=$($script:Token)" @{} (Get-Context)).Status 401 'query token refused'
    Assert-True (Test-WddMonitorToken $script:Token $script:Token) 'the right token is accepted'
    Assert-True (-not (Test-WddMonitorToken '' $script:Token)) 'empty token refused'
}

Test-Scenario 'authorized: a whitelisted, sanitized model; no credentials, keys or tokens; no invented progress' {
    Reset-MonitorSim
    Initialize-Embedded | Out-Null
    Add-WddActivity $script:Paths 'Test entry: password=Hunter2! and key: SuperSecretKey and product key VK7JG-NPHTM-C97JM-9MPGT-3V66T' 'warning'
    Write-WddJson (Join-Path $script:Paths.Root 'Network\wifi-result.json') @{ status = 'Added'; profileName = 'HomeWiFi'; message = 'Added.'; keyMaterial = 'WifiPassw0rd!' }
    Set-EngineStatus 'applications' 'Installing' 'Spotify' 3 10
    $r = Get-Api
    Assert-Equal $r.Status 200 'authorized'
    Assert-Equal $r.ContentType 'application/json; charset=utf-8' 'JSON'
    foreach ($secret in 'Hunter2', 'SuperSecretKey', 'VK7JG-NPHTM', 'WifiPassw0rd', $script:Token, 'keyMaterial', 'HomeWiFi') { Assert-True ($r.Body -notmatch [regex]::Escape($secret)) "never in the answer: $secret" }
    Assert-True ($r.Body -match '\[hidden\]' -and $r.Body -match '\[product key hidden\]') 'masked'
    $m = $r.Body | ConvertFrom-Json
    Assert-Equal (($m.PSObject.Properties.Name | Sort-Object) -join ',') 'activity,applications,attention,completedUtc,computerName,deploymentId,drivers,final,format,lastActivityUtc,overall,refreshSeconds,restartPending,serverTimeUtc,startedUtc,status,statusText,version,windowsUpdate' 'top-level fields are the whitelist'
    Assert-Equal $m.deploymentId $script:Manifest.packageId 'deployment id'
    Assert-Equal $m.refreshSeconds 7 'refresh every 7 seconds'
    Assert-Equal $m.applications.current 'Spotify' 'application being installed'
    Assert-Equal $m.applications.progress 'unavailable' 'no invented progress'
    Assert-True ($null -eq $m.applications.percent -and $null -eq $m.applications.bytesPerSecond) 'no invented percentage or speed'
    Assert-Equal $m.windowsUpdate.progress 'unavailable' 'no invented update progress'
    Assert-True ($m.status -in 'active', 'waiting', 'recovering', 'attention') "status: $($m.status)"
    Assert-True (@($m.activity).Count -ge 1 -and $m.activity[0].message -like 'Test entry*') 'newest activity first'
}

Test-Scenario 'read-only: other methods 405, unknown paths 404, strict security headers, no cross-origin access' {
    Reset-MonitorSim
    Initialize-Embedded | Out-Null
    foreach ($verb in 'POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS') {
        $r = Invoke-WddMonitorRequest $verb '/api/status' @{ Authorization = "Bearer $($script:Token)" } (Get-Context)
        Assert-Equal $r.Status 405 "$verb refused"
        Assert-Equal $r.Headers['Allow'] 'GET, HEAD' 'Allow header'
    }
    foreach ($p in '/api', '/api/restart', '/../state/monitor.json', '/C:/Windows/win.ini', '/scripts/monitor/DeploymentStatusServer.ps1') {
        Assert-Equal (Invoke-WddMonitorRequest 'GET' $p @{ Authorization = "Bearer $($script:Token)" } (Get-Context)).Status 404 "no file access: $p"
    }
    foreach ($p in '/', '/app.js', '/app.css', '/api/status') {
        $r = Invoke-WddMonitorRequest 'GET' $p @{ Authorization = "Bearer $($script:Token)" } (Get-Context)
        Assert-True ($r.Headers['Content-Security-Policy'] -match "default-src 'none'" -and $r.Headers['Content-Security-Policy'] -match "frame-ancestors 'none'") "CSP on $p"
        Assert-Equal $r.Headers['Cache-Control'] 'no-store' "no caching of $p"
        Assert-True (-not $r.Headers.Contains('Access-Control-Allow-Origin')) "no CORS on $p"
    }
    $page = (Invoke-WddMonitorRequest 'GET' '/' @{} (Get-Context)).Body
    Assert-True ($page -notmatch '<script>' -and $page -notmatch 'style=') 'no inline script or style (CSP)'
    Assert-True ($page -notmatch [regex]::Escape($script:Manifest.packageId)) 'the page itself carries no data'
    $js = (Invoke-WddMonitorRequest 'GET' '/app.js' @{} (Get-Context)).Body
    Assert-True ($js -match 'textContent' -and $js -notmatch 'innerHTML') 'data is written as text, never as HTML'
    Assert-True ($js -match 'refresh \* 1000' -and $js -match "Authorization', 'Bearer '") 'polls with the token in a header'
}

Test-Scenario 'LAN access: firewall rule for this port only, LAN address listed, token kept; localhost-only adds no rule; Public network and no network explained' {
    Reset-MonitorSim
    Initialize-Embedded | Out-Null
    $lan = @{ enabled = $true; port = 8765; lanAccess = $true; refreshSeconds = 7; finalReportHours = 24 }
    $i1 = Initialize-WddMonitorInfo $script:Paths $lan
    Assert-Equal ($script:FirewallAdds -join ',') '8765' 'one rule for the port'
    Assert-Equal ($i1.urls -join ' ') 'http://192.168.1.100:8765 http://127.0.0.1:8765' 'addresses'
    Assert-True ($i1.token -match '^[A-Za-z0-9_-]{43}$') 'random 256-bit token'
    $i2 = Initialize-WddMonitorInfo $script:Paths $lan -Refresh
    Assert-Equal $i2.token $i1.token 'token kept across restarts of the monitor'
    Assert-Equal ($script:FirewallAdds -join ',') '8765' 'a refresh does not recreate the rule'
    $script:SimCategories = @('Public')
    $i3 = Initialize-WddMonitorInfo $script:Paths $lan -Refresh
    Assert-True ($i3.message -like 'This network is set to Public*Private network*') "public network: $($i3.message)"
    $script:SimAddresses = @()
    $i4 = Initialize-WddMonitorInfo $script:Paths $lan -Refresh
    Assert-True ($i4.message -like 'No network connection yet*The deployment continues normally.') 'no network'
    Assert-Equal ($i4.urls -join ' ') 'http://127.0.0.1:8765' 'this computer only'
    Reset-MonitorSim
    Remove-Item -LiteralPath $script:Paths.MonitorInfo
    $local = Initialize-WddMonitorInfo $script:Paths (Get-WddMonitorSettings $script:Manifest)
    Assert-Equal $script:FirewallAdds.Count 0 'no firewall rule without LAN access'
    Assert-Equal $local.firewall 'NotNeeded' 'recorded'
    Assert-Equal ($local.urls -join ' ') 'http://127.0.0.1:8765' 'localhost only'
    $s = Get-WddMonitorSettings @{ monitor = @{ enabled = $true; port = 80; refreshSeconds = 0; finalReportHours = 1000 } }
    Assert-Equal "$($s.port) $($s.refreshSeconds) $($s.finalReportHours) $($s.lanAccess)" '1024 2 168 False' 'settings are clamped; LAN access off unless enabled'
}

Test-Scenario 'partially written or damaged files: the monitor keeps answering' {
    Reset-MonitorSim
    Initialize-Embedded | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:Paths.Root 'Updates') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $script:Paths.Root 'Updates\status.json'), '{"phase":"Downl')
    [IO.File]::AppendAllText($script:Paths.Activity, '{"utc":"2026-')
    $r = Get-Api
    Assert-Equal $r.Status 200 'half-written engine status'
    Set-Content -LiteralPath $script:Paths.State -Value '{ broken'
    Set-Content -LiteralPath "$($script:Paths.State).bak" -Value '{ broken'
    $r = Get-Api
    Assert-Equal $r.Status 200 'damaged state'
    $m = $r.Body | ConvertFrom-Json
    Assert-Equal $m.status 'attention' 'reported as needing attention'
    Assert-True ($m.statusText -like '*damaged*') 'said so'
    # Any other failure while the model is built (a file replaced at that moment): a temporary 503.
    function Get-WddMonitorStatus { throw 'simulated read while a file is replaced' }
    $r = Get-Api
    Assert-Equal $r.Status 503 'temporary 503, not a crash'
    Assert-Equal $r.Headers['Retry-After'] '5' 'retry hint'
    Assert-True ($r.Body -notmatch 'simulated') 'no internal error text in the answer'
}

Test-Scenario 'after the deployment: final results (read-only), then the monitor removes its firewall rule and task and stops' {
    Reset-MonitorSim
    Initialize-Embedded | Out-Null
    Set-EngineResult 'windowsUpdate' 'Succeeded'
    Set-EngineResult 'applications' 'CompletedWithFailures' @{ packages = @(@{ name = 'Spotify'; packageIdentifier = 'Spotify.Spotify'; source = 'winget'; status = 'Failed'; attempts = 3; exitCode = '0x8A150006'; message = 'The installer reported a failure.' }, @{ name = 'Git'; packageIdentifier = 'Git.Git'; source = 'winget'; status = 'Succeeded'; detection = 'Installed'; attempts = 1; exitCode = '0x00000000'; message = 'Installed.' }) }
    $script:SimDevices = @(@{ name = 'Unknown device'; class = ''; problemCode = 28; hardwareIds = @('ACPI\VEN_INT&DEV_33A1') })
    Invoke-WddMonitor $script:Paths | Out-Null
    $m = (Get-Api).Body | ConvertFrom-Json
    Assert-Equal $m.status 'complete' 'complete'
    Assert-Equal $m.final.overall 'CompletedWithFailures' 'final overall'
    Assert-True (@($m.final.failed) -match '^Application Spotify: Failed').Count 'failed operations listed'
    Assert-True (@($m.final.completed) -match '^Applications: 1 of 2 installed \(1 confirmed by WinGet\)').Count 'completed operations listed'
    Assert-Equal @($m.final.unresolvedDevices).Count 1 'unresolved device'
    Assert-Equal $m.final.unresolvedDevices[0].hardwareId 'ACPI\VEN_INT&DEV_33A1' 'hardware ID'
    Assert-True (@($m.final.followUp).Count -ge 1) 'technician follow-up'
    Assert-Equal $m.final.health.status 'NeedsAttention' 'the audit run at the end of the deployment is shown as the current health'
    # Engine 2.1.0: the latest read-only health audit is the current state, shown apart from the
    # deployment's own result (history, never rewritten).
    Write-WddJson (Join-Path $script:Paths.Root 'reports\health\deployment-health.json') ([ordered]@{ generatedUtc = '2026-11-27T12:00:00Z'; overall = [ordered]@{ status = 'Ready'; summary = '41 of 41 check(s) verified'; title = 'Ready' } })
    $m = (Get-Api).Body | ConvertFrom-Json
    Assert-Equal "$($m.final.overall) $($m.final.health.status) $($m.final.health.generatedUtc)" 'CompletedWithFailures Ready 2026-11-27T12:00:00Z' 'history and current health side by side'
    $settings = Get-WddMonitorSettings $script:Manifest
    $script:SimNow = $script:SimNow.AddHours(1)
    Assert-True (-not (Test-WddMonitorExpired $script:Paths $settings)) 'still shown after 1 hour'
    $script:SimNow = $script:SimNow.AddHours(24)
    Assert-True (Test-WddMonitorExpired $script:Paths $settings) 'ends after finalReportHours'
    Write-WddJson $script:Paths.MonitorInfo @{ port = 8765; token = $script:Token; mode = 'serving'; urls = @() }
    Stop-WddMonitor $script:Paths 'The deployment finished.'
    Assert-Equal $script:FirewallRemoves 1 'firewall rule removed'
    Assert-True $script:ServerTaskRemoved 'task removed'
    Assert-Equal (Read-WddJson $script:Paths.MonitorInfo).mode 'stopped' 'the progress window is told'
}

Test-Scenario 'real HTTP on 127.0.0.1: serves the page, refuses without the token, answers with it, read-only, then stops' {
    Reset-MonitorSim
    Initialize-Embedded | Out-Null
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
    $harness = Join-Path $script:Tmp 'serve.ps1'
    Set-Content -LiteralPath $harness -Encoding UTF8 -Value @'
param([string] $ServerScript, [string] $ManifestPath, [string] $DataRoot, [int] $Port, [string] $Token)
. $ServerScript -Mode Library
$m = Read-WddManifest $ManifestPath
$paths = Get-WddPaths $DataRoot
$settings = Get-WddMonitorSettings $m
$settings.port = $Port
Start-WddStatusServer $m $paths $settings @{ token = $Token } -Prefixes @("http://127.0.0.1:$Port/") -MaxSeconds 40
'@
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $proc = Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$harness`"", '-ServerScript', "`"$serverScript`"", '-ManifestPath', "`"$(Join-Path $script:Paths.Package 'deployment-manifest.json')`"", '-DataRoot', "`"$($script:Paths.Root)`"", '-Port', $port, '-Token', $script:Token) -WindowStyle Hidden -PassThru
    try {
        $base = "http://127.0.0.1:$port"
        $page = $null
        for ($i = 0; $i -lt 60 -and -not $page; $i++) { try { $page = Invoke-WebRequest -Uri "$base/" -UseBasicParsing -TimeoutSec 2 } catch { Start-Sleep -Milliseconds 500 } }
        Assert-True $page 'the server answers'
        Assert-Equal $page.StatusCode 200 'page'
        Assert-True ($page.Headers['Content-Security-Policy'] -match "default-src 'none'") 'CSP over HTTP'
        Assert-True (-not $page.Headers['Access-Control-Allow-Origin']) 'no CORS over HTTP'
        $code = 0
        try { Invoke-WebRequest -Uri "$base/api/status" -UseBasicParsing -TimeoutSec 5 | Out-Null } catch { $code = [int] $_.Exception.Response.StatusCode }
        Assert-Equal $code 401 'no token, no data'
        $ok = Invoke-WebRequest -Uri "$base/api/status" -Headers @{ Authorization = "Bearer $($script:Token)" } -UseBasicParsing -TimeoutSec 15
        Assert-Equal $ok.StatusCode 200 'with the token'
        Assert-Equal ($ok.Content | ConvertFrom-Json).deploymentId $script:Manifest.packageId 'status over HTTP'
        $code = 0
        try { Invoke-WebRequest -Uri "$base/api/status" -Method Post -Body '{}' -Headers @{ Authorization = "Bearer $($script:Token)" } -UseBasicParsing -TimeoutSec 5 | Out-Null } catch { $code = [int] $_.Exception.Response.StatusCode }
        Assert-Equal $code 405 'read-only over HTTP'
    } finally {
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    }
}

Write-Output "$($script:Passed) passed, $($script:Failures) failed"
if ($script:Failures -gt 0) { exit 1 }
exit 0
