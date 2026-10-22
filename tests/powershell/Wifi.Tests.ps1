#Requires -Version 5.1
<#
    Scenario tests for Add-WifiProfile.ps1 (Phase 4.3) against the files the REAL generator embeds
    (see wifi-fixture.ts) and a simulated machine: the WLAN service, Wi-Fi adapters and netsh are
    replaced. Nothing is added to this computer's Wi-Fi configuration; results go to a temp folder.

    Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\powershell\Wifi.Tests.ps1 -Fixture <dir>
#>
param([Parameter(Mandatory = $true)] [string] $Fixture)

$ErrorActionPreference = 'Stop'
$script:Failures = 0
$script:Passed = 0

function Assert-Equal($Actual, $Expected, [string] $Message) { if ("$Actual" -ne "$Expected") { throw "ASSERT: $Message. Expected <$Expected>, got <$Actual>." } }
function Assert-True($Value, [string] $Message) { if (-not $Value) { throw "ASSERT: $Message" } }

# The script is dot-sourced from the fixture (the file that ships); its param() defaults are then
# replaced per scenario.
. (Join-Path $Fixture 'plain\Add-WifiProfile.ps1')
$ErrorActionPreference = 'Stop'

function Reset-Sim {
    param([string] $Case = 'plain', [string] $Stage = 'Specialize', [switch] $Connect)
    $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ("wdw-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Tmp | Out-Null
    Copy-Item -LiteralPath (Join-Path $Fixture "$Case\Wifi.xml") -Destination (Join-Path $script:Tmp 'Wifi.xml')
    $script:CaseData = [System.IO.File]::ReadAllText((Join-Path $Fixture "$Case\case.json"), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $script:ProfilePath = Join-Path $script:Tmp 'Wifi.xml'
    $script:ResultRoot = Join-Path $script:Tmp 'Network'
    $script:Stage = $Stage
    $script:Connect = [bool] $Connect
    $script:SimService = 'Running'       # '' = service missing
    $script:SimStartsAfter = 0           # seconds until a stopped service runs
    $script:SimWaited = 0
    $script:SimAdapters = @('Wi-Fi')
    $script:SimNetsh = New-Object System.Collections.Generic.List[string]
    $script:SimAddExit = 0
    $script:SimAddOutput = 'Profile is added on interface Wi-Fi.'
    $script:SimConnectExit = 0
}
# Variables the script reads (normally its parameters).
function Set-Stage { param([string] $Value) $script:Stage = $Value; Set-Variable -Name Stage -Value $Value -Scope Script }

function Get-WdwServiceStatus { if (-not $script:SimService) { return '' }; if ($script:SimService -ne 'Running' -and $script:SimWaited -ge $script:SimStartsAfter) { $script:SimService = 'Running' }; $script:SimService }
function Start-WdwService { }
function Wait-WdwSeconds { param([int] $Seconds) $script:SimWaited += $Seconds }
function Get-WdwNow { [DateTime]::new(2026, 10, 21, 9, 0, 0, [DateTimeKind]::Utc) }
function Get-WdwWirelessAdapters { @($script:SimAdapters) }
function Invoke-WdwNetsh {
    param([string[]] $Arguments)
    $script:SimNetsh.Add($Arguments -join ' ')
    if ($Arguments[1] -eq 'add') { return @{ ExitCode = $script:SimAddExit; Output = $script:SimAddOutput } }
    @{ ExitCode = $script:SimConnectExit; Output = 'Connection request was completed successfully.' }
}

function Get-Result { [System.IO.File]::ReadAllText((Join-Path $script:ResultRoot 'wifi-result.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json }
function Get-AllOutput {
    $t = ''
    foreach ($f in Get-ChildItem -LiteralPath $script:ResultRoot -File) { $t += [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8) }
    $t
}

function Test-Scenario {
    param([string] $Name, [scriptblock] $Body)
    try {
        & $Body
        $script:Passed++
        Write-Output "  ok    $Name"
    } catch {
        $script:Failures++
        Write-Output "  FAIL  $Name"
        Write-Output "        $($_.Exception.Message)"
    } finally {
        if ($script:Tmp -and (Test-Path -LiteralPath $script:Tmp)) { Remove-Item -LiteralPath $script:Tmp -Recurse -Force }
    }
}

Write-Output 'Add-WifiProfile.ps1 (simulated WLAN service, adapters and netsh)'

Test-Scenario 'generated XML: special characters escaped, exact SSID bytes as hex, safe ASCII profile name, exact key' {
    foreach ($case in 'special', 'unicode', 'plain') {
        Reset-Sim $case
        $xml = New-Object System.Xml.XmlDocument
        $xml.Load($script:ProfilePath)
        $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace('w', 'http://www.microsoft.com/networking/WLAN/profile/v1')
        Assert-Equal $xml.SelectSingleNode('//w:SSID/w:hex', $ns).InnerText $script:CaseData.ssidHex "$case hex is the exact UTF-8 SSID"
        Assert-Equal $xml.SelectSingleNode('//w:SSID/w:name', $ns).InnerText $script:CaseData.ssid "$case SSID name round-trips"
        Assert-Equal $xml.SelectSingleNode('//w:keyMaterial', $ns).InnerText $script:CaseData.password "$case key round-trips through XML escaping"
        $name = $xml.SelectSingleNode('/w:WLANProfile/w:name', $ns).InnerText
        Assert-True ($name -match '^[\x20-\x7e]+$' -and $name -notmatch '"') "$case profile name is netsh-safe ASCII ($name)"
        Remove-Item -LiteralPath $script:Tmp -Recurse -Force
    }
    Reset-Sim 'plain'
    Assert-Equal ([xml] [System.IO.File]::ReadAllText($script:ProfilePath)).WLANProfile.name 'HomeNet' 'plain SSIDs keep their own name'
}

Test-Scenario 'adapter present: profile added for all users; the key is in neither the result nor the log' {
    Reset-Sim 'special'
    Assert-Equal (Invoke-WdwMain) 'Added' 'status'
    Assert-Equal $script:SimNetsh.Count 1 'one netsh call'
    Assert-True ($script:SimNetsh[0] -match '^wlan add profile filename=.+Wifi\.xml user=all$') "netsh arguments: $($script:SimNetsh[0])"
    $r = Get-Result
    Assert-Equal $r.status 'Added' 'result'
    Assert-Equal $r.adapters 1 'adapter count'
    Assert-True ([bool] $r.final) 'final'
    Assert-True (-not (Get-AllOutput).Contains($script:CaseData.password)) 'no key in result or log'
}

Test-Scenario 'connect automatically: a connection is requested by profile name and reported as not verified' {
    Reset-Sim 'special' -Connect
    Assert-Equal (Invoke-WdwMain) 'ConnectRequested' 'status'
    Assert-True ($script:SimNetsh[1] -match '^wlan connect name=WiFi-') 'connect by the safe profile name'
    Assert-True ((Get-Result).message -match 'not verified') 'honest about the connection'
    $script:SimConnectExit = 1
    Remove-Item -LiteralPath $script:ResultRoot -Recurse -Force
    Assert-Equal (Invoke-WdwMain) 'ConnectFailed' 'failed connect request still keeps the profile'
}

Test-Scenario 'missing wireless driver at specialize: deferred; retried at first sign-in once the adapter exists' {
    Reset-Sim 'plain'
    $script:SimAdapters = @()
    Assert-Equal (Invoke-WdwMain) 'NoWirelessAdapter' 'specialize'
    Assert-True (-not [bool] (Get-Result).final) 'not final at specialize'
    Assert-Equal $script:SimNetsh.Count 0 'netsh not called without an adapter'
    Set-Variable -Name Stage -Value 'FirstLogon' -Scope Script
    $script:SimAdapters = @('Wi-Fi 2')
    Assert-Equal (Invoke-WdwMain) 'Added' 'first sign-in retry'
    Assert-Equal (Get-Result).stage 'FirstLogon' 'recorded at first sign-in'
}

Test-Scenario 'missing wireless hardware: final NoWirelessAdapter at first sign-in, with manual instructions' {
    Reset-Sim 'plain' 'FirstLogon'
    $script:SimAdapters = @()
    Assert-Equal (Invoke-WdwMain) 'NoWirelessAdapter' 'status'
    $r = Get-Result
    Assert-True ([bool] $r.final) 'final'
    Assert-True ($r.message -match 'connect to the network manually') 'tells the person what to do'
}

Test-Scenario 'no WLAN service (no wireless stack): NoWirelessService, nothing attempted' {
    Reset-Sim 'plain'
    $script:SimService = ''
    Assert-Equal (Invoke-WdwMain) 'NoWirelessService' 'status'
    Assert-Equal $script:SimNetsh.Count 0 'no netsh'
}

Test-Scenario 'slow WLAN service: waits for it, then adds the profile; a service that never starts is reported' {
    Reset-Sim 'plain'
    $script:SimService = 'Stopped'; $script:SimStartsAfter = 20
    Assert-Equal (Invoke-WdwMain) 'Added' 'after waiting'
    Assert-True ($script:SimWaited -ge 20 -and $script:SimWaited -le 60) "waited $($script:SimWaited)s"
    Reset-Sim 'plain'
    $script:SimService = 'Stopped'; $script:SimStartsAfter = 999
    Assert-Equal (Invoke-WdwMain) 'NoWirelessAdapter' 'never running'
    Assert-True ($script:SimWaited -le 60) 'bounded wait'
}

Test-Scenario 'failed WLAN profile import: ImportFailed; netsh output in the log is redacted' {
    Reset-Sim 'special'
    $script:SimAddExit = 1
    $script:SimAddOutput = "The profile is not valid. keyMaterial $($script:CaseData.password)"
    Assert-Equal (Invoke-WdwMain) 'ImportFailed' 'specialize'
    Assert-True (-not [bool] (Get-Result).final) 'retried at first sign-in'
    $all = Get-AllOutput
    Assert-True (-not $all.Contains($script:CaseData.password)) 'key redacted'
    Assert-True ($all -match '\*\*\*\*\*\*\*\*') 'redaction marker present'
    Set-Variable -Name Stage -Value 'FirstLogon' -Scope Script
    Assert-Equal (Invoke-WdwMain) 'ImportFailed' 'still failing'
    Assert-True ([bool] (Get-Result).final) 'final at first sign-in'
}

Test-Scenario 'first sign-in after a successful specialize: nothing is done again' {
    Reset-Sim 'plain'
    Assert-Equal (Invoke-WdwMain) 'Added' 'specialize'
    Set-Variable -Name Stage -Value 'FirstLogon' -Scope Script
    Assert-Equal (Invoke-WdwMain) 'AlreadyAdded' 'no second import'
    Assert-Equal $script:SimNetsh.Count 1 'netsh once'
}

Test-Scenario 'missing Wifi.xml: ProfileMissing, no exception' {
    Reset-Sim 'plain'
    Remove-Item -LiteralPath $script:ProfilePath
    Assert-Equal (Invoke-WdwMain) 'ProfileMissing' 'status'
}

Write-Output ''
Write-Output "$($script:Passed) passed, $($script:Failures) failed"
if ($script:Failures -gt 0) { exit 1 }
exit 0
