#Requires -Version 5.1
<#
    Phase 9: read-only smoke test of the health engine's REAL Windows probes (no simulation), under
    Set-StrictMode -Version 2.0, on the computer that runs it. Nothing is installed, registered or
    changed: no event is written (trigger Test), no task or shortcut is created, and the report goes
    to a temporary folder that is deleted afterwards. There is no deployment on a development
    computer, so the expected result is "Unverifiable" with every probe either answering or being
    reported as not readable (never a crash).

    Run (opt-in; it reads this computer's state): powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\powershell\HealthLiveProbe.ps1 -Fixture <dir>
#>
param([Parameter(Mandatory = $true)] [string] $Fixture)
$ErrorActionPreference = 'Stop'
$pkg = Join-Path $Fixture 'health\usb\WindowsDeployment'
. (Join-Path $pkg 'scripts\common\DeploymentCommon.ps1')
. (Join-Path $pkg 'scripts\health\DeploymentHealth.ps1') -Mode Library
function Write-WddEvent { param([int] $EventId, [string] $Message, [string] $EntryType = 'Information') }
$root = Join-Path ([IO.Path]::GetTempPath()) ('wdh-live-' + [guid]::NewGuid().ToString('N'))
try {
    Set-StrictMode -Version 2.0
    $manifest = Read-WddManifest (Join-Path $pkg 'deployment-manifest.json')
    $cfg = Read-WddJson (Join-Path $pkg 'scripts\health\health-config.json')
    $paths = Get-WddPaths $root
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $v = Invoke-WdhVerify $manifest $paths $cfg 'Test'
    $sw.Stop()
    $errors = @($v.Report.findings | Where-Object { $_.id -like '*.checkError' })
    $answered = @($v.Report.findings | Where-Object { $_.status -ne 'Unverifiable' }).Count
    Write-Output "live probes: overall $($v.Status), $(@($v.Report.findings).Count) finding(s), $answered answered, $($errors.Count) check error(s), $([int] $sw.Elapsed.TotalSeconds) s"
    foreach ($e in $errors) { Write-Output "  CHECK ERROR $($e.id): $($e.observed)" }
    foreach ($l in @($v.Report.limitations)) { Write-Output "  limitation: $l" }
    if ($errors.Count -or $v.Status -ne 'Unverifiable') { exit 1 }
    exit 0
} finally {
    Set-StrictMode -Off
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
