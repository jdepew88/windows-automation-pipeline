#Requires -Version 5.1
<#
.SYNOPSIS
    Adds the Wi-Fi profile embedded in the answer file (Wifi.xml) for all users.

.DESCRIPTION
    Phase 4.3. Runs during specialize and, only if that attempt could not add the profile, once
    more at the first sign-in (before the sensitive-file cleanup deletes Wifi.xml):

      1. Waits for the WLAN AutoConfig service (WlanSvc). No service: NoWirelessService.
      2. Looks for a physical 802.11 adapter with a working driver. None: NoWirelessAdapter
         (specialize: retried at first sign-in; afterwards final).
      3. netsh wlan add profile filename=<Wifi.xml> user=all. Non-zero exit: ImportFailed.
      4. With -Connect: netsh wlan connect name=<profile>. This only REQUESTS a connection;
         whether the network is in range and accepts the key is not verified here.

    Result: <ResultRoot>\wifi-result.json (status, stage, profile name, adapter count, message)
    and wifi.log. The Wi-Fi key is never written to either: netsh output is logged only after
    redacting the key, and the XML itself is never logged.

    Statuses: Added, ConnectRequested, ConnectFailed (profile added), NoWirelessService,
    NoWirelessAdapter, ImportFailed, ProfileMissing, Failed.
#>
[CmdletBinding()]
param(
    [ValidateSet('Specialize', 'FirstLogon')] [string] $Stage = 'Specialize',
    [string] $ProfilePath = (Join-Path $PSScriptRoot 'Wifi.xml'),
    [switch] $Connect,
    [string] $ResultRoot = 'C:\ProgramData\WindowsDeploymentBuilder\Network'
)

$script:WifiMain = $MyInvocation.InvocationName -ne '.'
$script:WifiDone = @('Added', 'ConnectRequested', 'ConnectFailed')

# Adapters (replaced by tests\powershell\Wifi.Tests.ps1) -------------------------------------------

function Get-WdwServiceStatus { $s = Get-Service -Name 'WlanSvc' -ErrorAction SilentlyContinue; if ($s) { [string] $s.Status } else { '' } }
function Start-WdwService { try { Start-Service -Name 'WlanSvc' -ErrorAction Stop } catch { } }
function Wait-WdwSeconds { param([int] $Seconds) Start-Sleep -Seconds $Seconds }
function Get-WdwNow { [DateTime]::UtcNow }
<# Physical Wi-Fi adapters whose driver is loaded (NdisPhysicalMedium 9 = native 802.11). #>
function Get-WdwWirelessAdapters {
    @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.NdisPhysicalMedium -eq 9 -or $_.PhysicalMediaType -match '802\.11' } | ForEach-Object { [string] $_.Name })
}
function Invoke-WdwNetsh {
    param([string[]] $Arguments)
    $out = & "$env:SystemRoot\System32\netsh.exe" @Arguments 2>&1 | Out-String
    @{ ExitCode = $LASTEXITCODE; Output = $out }
}

# Logic --------------------------------------------------------------------------------------------

function Write-WdwLog {
    param([string] $Message)
    try {
        if (-not (Test-Path -LiteralPath $ResultRoot)) { New-Item -ItemType Directory -Path $ResultRoot -Force | Out-Null }
        [System.IO.File]::AppendAllText((Join-Path $ResultRoot 'wifi.log'), ('{0}  {1,-10}  {2}' -f (Get-WdwNow).ToString('yyyy-MM-dd HH:mm:ss'), $Stage, $Message) + "`r`n")
    } catch { }
}

function Protect-WdwText {
    param([string] $Text, [string] $Secret)
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($Secret) { $t = $t.Replace($Secret, '********') }
    if ($t.Length -gt 300) { $t = $t.Substring(0, 300) + '...' }
    return $t
}

function Read-WdwResult {
    $p = Join-Path $ResultRoot 'wifi-result.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $null }
}

function Write-WdwResult {
    param([hashtable] $Result)
    if (-not (Test-Path -LiteralPath $ResultRoot)) { New-Item -ItemType Directory -Path $ResultRoot -Force | Out-Null }
    $json = ([pscustomobject] $Result) | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText((Join-Path $ResultRoot 'wifi-result.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-WdwProvision {
    $r = [ordered]@{ status = ''; stage = $Stage; final = $true; profileName = ''; adapters = 0; message = ''; updatedUtc = '' }
    $secret = ''
    try {
        if ($Stage -eq 'FirstLogon') {
            $prev = Read-WdwResult
            if ($prev -and [string] $prev.status -in $script:WifiDone) { return $null }
        }
        if (-not (Test-Path -LiteralPath $ProfilePath)) {
            $r.status = 'ProfileMissing'; $r.message = 'The embedded Wi-Fi profile (Wifi.xml) was not found.'
            return $r
        }
        $xml = New-Object System.Xml.XmlDocument
        $xml.Load($ProfilePath)
        $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace('w', 'http://www.microsoft.com/networking/WLAN/profile/v1')
        $nameNode = $xml.SelectSingleNode('/w:WLANProfile/w:name', $ns)
        $keyNode = $xml.SelectSingleNode('//w:keyMaterial', $ns)
        $r.profileName = $(if ($nameNode) { $nameNode.InnerText } else { '' })
        $secret = $(if ($keyNode) { $keyNode.InnerText } else { '' })

        $wait = if ($Stage -eq 'Specialize') { 60 } else { 30 }
        if (-not (Get-WdwServiceStatus)) {
            $r.status = 'NoWirelessService'; $r.message = 'The WLAN AutoConfig service does not exist on this installation, so no Wi-Fi profile can be added.'
            return $r
        }
        if ((Get-WdwServiceStatus) -ne 'Running') { Start-WdwService }
        for ($t = 0; (Get-WdwServiceStatus) -ne 'Running' -and $t -lt $wait; $t += 5) { Wait-WdwSeconds 5 }
        $adapters = @(Get-WdwWirelessAdapters)
        $r.adapters = $adapters.Count
        if ((Get-WdwServiceStatus) -ne 'Running' -or $adapters.Count -eq 0) {
            $r.status = 'NoWirelessAdapter'
            $r.final = ($Stage -eq 'FirstLogon')
            $r.message = $(if ($Stage -eq 'Specialize') { 'No Wi-Fi adapter with a working driver yet; retrying at the first sign-in.' } else { 'No Wi-Fi adapter with a working driver was found. The profile was not added; connect to the network manually once the Wi-Fi driver is installed.' })
            return $r
        }
        $add = Invoke-WdwNetsh @('wlan', 'add', 'profile', "filename=$ProfilePath", 'user=all')
        Write-WdwLog "netsh wlan add profile: exit $($add.ExitCode). $(Protect-WdwText $add.Output $secret)"
        if ($add.ExitCode -ne 0) {
            $r.status = 'ImportFailed'
            $r.final = ($Stage -eq 'FirstLogon')
            $r.message = "Windows rejected the Wi-Fi profile (netsh exit code $($add.ExitCode))$(if ($Stage -eq 'Specialize') { '; retrying at the first sign-in' } else { '. Connect to the network manually' })."
            return $r
        }
        $r.status = 'Added'
        $r.message = "Wi-Fi profile added for all users on $($adapters.Count) adapter(s)."
        if ($Connect) {
            $c = Invoke-WdwNetsh @('wlan', 'connect', "name=$($r.profileName)")
            Write-WdwLog "netsh wlan connect: exit $($c.ExitCode). $(Protect-WdwText $c.Output $secret)"
            if ($c.ExitCode -eq 0) { $r.status = 'ConnectRequested'; $r.message += ' A connection was requested (not verified: the network may be out of range).' }
            else { $r.status = 'ConnectFailed'; $r.message += " The connection request failed (exit $($c.ExitCode)); Windows connects when the network is in range." }
        }
        return $r
    } catch {
        $r.status = 'Failed'
        $r.final = ($Stage -eq 'FirstLogon')
        $r.message = "Adding the Wi-Fi profile failed: $(Protect-WdwText $_.Exception.Message $secret)"
        return $r
    } finally {
        $secret = $null
    }
}

function Invoke-WdwMain {
    $r = Invoke-WdwProvision
    if (-not $r) { Write-WdwLog 'Profile already added during specialize; nothing to do.'; return 'AlreadyAdded' }
    $r.updatedUtc = (Get-WdwNow).ToString('o')
    Write-WdwLog "$($r.status): $($r.message)"
    try { Write-WdwResult $r } catch { Write-WdwLog "Could not write wifi-result.json: $($_.Exception.Message)" }
    return $r.status
}

if ($script:WifiMain) {
    $status = Invoke-WdwMain
    Write-Output "Wi-Fi: $status"
    exit 0
}
