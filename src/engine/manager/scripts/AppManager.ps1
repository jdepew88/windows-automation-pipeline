#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Deployment Builder - Application Manager agent (Phase 10).

.DESCRIPTION
    A small local web server for the Application Manager: it serves the manager's page to this
    computer only (127.0.0.1) and runs WinGet for it. It works on any Windows 10/11 computer with
    WinGet, whether or not Windows Deployment Builder installed it, and needs no USB drive.

      powershell.exe -ExecutionPolicy Bypass -File AppManager.ps1 [-DryRun] [-NoBrowser] [-Port n]

    Security
      - Listens on 127.0.0.1 only, on a random port. A random session token (in the address the
        agent opens, after "#", so it is never sent in a URL) must accompany every API call; the
        Host header must name 127.0.0.1 and a request from another origin is refused.
      - Runs as the signed-in user, never elevated by itself and never as SYSTEM. WinGet asks
        Windows for administrator approval (UAC) only for installers that need it, so per-user
        installations stay per-user.
      - It never builds a command from text it receives: an operation names an action
        (install, upgrade, uninstall), a package identifier that must match WinGet's syntax, a
        source (winget or msstore), and at most a scope and a version. Arguments are fixed here.
      - No --force, --ignore-security-hash, --ignore-local-archive-malware-scan, --include-unknown,
        --uninstall-previous or --purge. Package agreements are accepted only for a package the
        user accepted them for; source agreements only after the user accepted them once.
      - Runtimes, Windows components and drivers are never removed (catalog policy and patterns).
      - Simulation mode (-DryRun, or the switch in the page) shows every command without running it.

    Reuses the Phase 5 WinGet exit-code classification (ApplicationEngine.ps1) and the Phase 9
    uninstall-record reader (DeploymentHealth.ps1).
#>
[CmdletBinding()]
param(
    [ValidateSet('Serve', 'Library')]
    [string] $Mode = 'Serve',
    [int] $Port = 0,
    [switch] $DryRun,
    [switch] $NoBrowser,
    [int] $IdleMinutes = 45,
    [string] $DataRoot = '',
    # A winget.exe other than the one on PATH (a non-standard installation, or the tests' simulated WinGet).
    [string] $WinGet = ''
)

$script:WamMain = $MyInvocation.InvocationName -ne '.' -and $Mode -ne 'Library'
# Captured first: the libraries dot-sourced below bind their own parameters in this scope.
$script:WamArgs = @{ Port = $Port; DryRun = [bool] $DryRun; NoBrowser = [bool] $NoBrowser; IdleMinutes = $IdleMinutes; DataRoot = $DataRoot; WinGet = $WinGet }
$script:WamRoot = $PSScriptRoot
$lib = Join-Path $PSScriptRoot 'lib'
if (-not (Get-Command Read-WddManifest -ErrorAction SilentlyContinue)) { . (Join-Path $lib 'DeploymentCommon.ps1') }
if (-not (Get-Command ConvertFrom-WdaExitCode -ErrorAction SilentlyContinue)) { . (Join-Path $lib 'ApplicationEngine.ps1') }
if (-not (Get-Command Get-WdhUninstallEntries -ErrorAction SilentlyContinue)) { . (Join-Path $lib 'DeploymentHealth.ps1') -Mode Library }
Set-StrictMode -Version 2.0

$script:WamVersion = '1.0.0'
$script:WamFormat = 'windows-deployment-builder/app-manager-operation'
$script:WamActions = @('install', 'upgrade', 'uninstall')
$script:WamSources = @('winget', 'msstore')
# The identifier patterns of the Phase 5 application engine (one definition for both).
$script:WamWinGetId = $script:WingetId
$script:WamStoreId = $script:StoreId
$script:WamScopes = @('', 'user', 'machine')
$script:WamVersionPattern = '^[A-Za-z0-9][A-Za-z0-9.+_-]{0,63}$'
# Never removed, whatever the catalog says (Windows components, shared runtimes, frameworks, drivers).
$script:WamProtected = @('^Microsoft\.Edge(\..*)?$', '^Microsoft\.EdgeWebView2Runtime$', '^Microsoft\.VCRedist\.', '^Microsoft\.VCLibs\.', '^Microsoft\.UI\.Xaml\.', '^Microsoft\.DotNet\.', '^Microsoft\.WindowsAppRuntime\.', '^Microsoft\.DirectX$', '^Microsoft\.AppInstaller$', '^Microsoft\.WindowsTerminal$', '^Microsoft\.DesktopAppInstaller$', 'Driver', '^Intel\.', '^AMD\.', '^Nvidia\.')
$script:WamNow = $null

# ------------------------------------------------------------------------------------------------
# Adapters (replaced by the scenario tests): WinGet, time, identity, the browser, the network
# ------------------------------------------------------------------------------------------------

function Get-WamNow { [DateTime]::UtcNow }
$script:WamWinGetPath = ''
function Get-WamWinGetPath {
    if ($script:WamWinGetPath) { return $script:WamWinGetPath }
    $c = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($c) { [string] $c.Source } else { '' }
}

function Get-WamIdentity {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    @{ Name = $id.Name; Sid = $id.User.Value; IsSystem = ($id.User.Value -eq 'S-1-5-18'); Elevated = $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
}

<# Starts WinGet with fixed arguments; its output goes to a file. Returns a handle the queue polls. #>
function Start-WamProcess {
    param([string[]] $Arguments, [string] $OutFile)
    $exe = Get-WamWinGetPath
    if (-not $exe) { throw 'WinGet is not available for this user.' }
    $quoted = @($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } })
    $p = Start-Process -FilePath $exe -ArgumentList $quoted -NoNewWindow -PassThru -RedirectStandardOutput $OutFile -RedirectStandardError "$OutFile.err"
    $null = $p.Handle   # keeps the exit code readable after the process ends
    return @{ Process = $p; OutFile = $OutFile; Started = (Get-WamNow) }
}

function Test-WamProcess {
    param($Handle)
    $p = $Handle.Process
    if (-not $p.HasExited) { return @{ Done = $false } }
    $p.WaitForExit()
    $out = ''
    foreach ($f in $Handle.OutFile, "$($Handle.OutFile).err") { if (Test-Path -LiteralPath $f) { $out += [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8); Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
    return @{ Done = $true; ExitCode = [int] $p.ExitCode; Output = $out }
}

function Stop-WamProcess { param($Handle) try { if (-not $Handle.Process.HasExited) { $Handle.Process.Kill() } } catch { } }

function Open-WamBrowser {
    param([string] $Url)
    $edge = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'
    if (Test-Path -LiteralPath $edge) { Start-Process -FilePath $edge -ArgumentList "--app=$Url" } else { Start-Process -FilePath $Url }
}

function Test-WamOnline { try { [bool] @([System.Net.Dns]::GetHostAddresses('cdn.winget.microsoft.com')).Count } catch { $false } }

# ------------------------------------------------------------------------------------------------
# Paths, settings, persistence (per user: no administrator rights needed)
# ------------------------------------------------------------------------------------------------

function Get-WamPaths {
    param([string] $Root = '')
    if (-not $Root) { $Root = Join-Path $env:LOCALAPPDATA 'WindowsDeploymentBuilder\AppManager' }
    @{ Root = $Root; Settings = Join-Path $Root 'settings.json'; Profiles = Join-Path $Root 'profiles.json'; History = Join-Path $Root 'history.jsonl'
       Inventory = Join-Path $Root 'inventory-cache.json'; Updates = Join-Path $Root 'updates-cache.json'; Work = Join-Path $Root 'work'; Logs = Join-Path $Root 'logs' }
}

function Initialize-WamStore {
    param([hashtable] $Paths)
    foreach ($d in $Paths.Root, $Paths.Work, $Paths.Logs) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
}

function Read-WamSettings {
    param([hashtable] $Paths)
    $s = Read-WddJson $Paths.Settings
    $o = @{ dryRun = $true; acceptSourceAgreements = $false }
    if ($s -is [hashtable]) { foreach ($k in 'dryRun', 'acceptSourceAgreements') { if ($s.ContainsKey($k)) { $o[$k] = [bool] $s[$k] } } }
    return $o
}

function Add-WamHistory {
    param([hashtable] $Paths, $Record)
    $line = ($Record | ConvertTo-Json -Depth 6 -Compress) + "`n"
    [IO.File]::AppendAllText($Paths.History, $line, (New-Object Text.UTF8Encoding($false)))
}

function Read-WamHistory {
    param([hashtable] $Paths, [int] $Limit = 500)
    if (-not (Test-Path -LiteralPath $Paths.History)) { return @() }
    $lines = @([IO.File]::ReadAllLines($Paths.History, [Text.Encoding]::UTF8) | Where-Object { $_.Trim() })
    $out = @()
    foreach ($l in @($lines | Select-Object -Last $Limit)) { try { $out += , (ConvertTo-WddHashtable ($l | ConvertFrom-Json)) } catch { } }
    return $out
}

<# The catalog's removal and upgrade policy (catalog-policy.json, generated with the manager). #>
function Read-WamPolicy {
    $p = Read-WddJson (Join-Path $script:WamRoot 'catalog-policy.json')
    $byId = @{}
    if ($p -is [hashtable]) { foreach ($e in @($p['packages'])) { if ($e -is [hashtable]) { $byId[([string] $e['id']).ToLowerInvariant()] = $e } } }
    return $byId
}

# ------------------------------------------------------------------------------------------------
# WinGet arguments and output (pure functions; the TypeScript preview mirrors Get-WamArguments)
# ------------------------------------------------------------------------------------------------

function Test-WamPackageSpec {
    param($Item)
    if ($Item -isnot [System.Collections.IDictionary]) { return 'not an object' }
    $src = [string] $Item['source']
    $id = [string] $Item['id']
    if ($src -notin $script:WamSources) { return "unsupported source '$src'" }
    if ($src -eq 'winget' -and $id -notmatch $script:WamWinGetId) { return "invalid WinGet identifier '$id'" }
    if ($src -eq 'msstore' -and $id -notmatch $script:WamStoreId) { return "invalid Microsoft Store identifier '$id'" }
    $scope = [string] $Item['scope']
    if ($scope -notin $script:WamScopes) { return "invalid scope '$scope'" }
    $ver = [string] $Item['version']
    if ($ver -and $ver -notmatch $script:WamVersionPattern) { return "invalid version '$ver'" }
    return $null
}

function Get-WamArguments {
    param([ValidateSet('install', 'upgrade', 'uninstall', 'show', 'list')] [string] $Action, [string] $Id, [string] $Source, [string] $Scope = '', [string] $Version = '', [switch] $AcceptPackageAgreements, [switch] $AcceptSourceAgreements)
    $a = @($Action, '--id', $Id, '--exact', '--source', $Source)
    if ($Action -in 'install', 'upgrade', 'uninstall') {
        if ($Scope) { $a += @('--scope', $Scope) }
        if ($Version -and $Action -eq 'install') { $a += @('--version', $Version) }
        $a += '--silent'
        if ($Action -eq 'install') { $a += '--no-upgrade' }
        if ($AcceptPackageAgreements -and $Action -ne 'uninstall') { $a += '--accept-package-agreements' }
    }
    if ($AcceptSourceAgreements) { $a += '--accept-source-agreements' }
    $a += '--disable-interactivity'
    return , $a
}

<# The last state of each line (progress bars rewrite lines with carriage returns). #>
function ConvertFrom-WamOutput { param([string] $Text) @(($Text -replace "`r`n", "`n") -split "`n" | ForEach-Object { ($_ -split "`r")[-1].TrimEnd() }) }

<#
    WinGet's tables (winget upgrade, winget list): columns are found from the header above the line
    of dashes, so localized headers do not matter. The first table lists ordinary upgrades; a later
    table lists packages WinGet upgrades only when named ("explicit"). Truncated identifiers end
    with an ellipsis and are marked.
#>
function ConvertFrom-WamTable {
    param([string] $Text)
    $lines = @(ConvertFrom-WamOutput $Text)
    $rows = @()
    $table = 0
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^-{10,}\s*$') { continue }
        $table++
        $head = $lines[$i - 1]
        $starts = @(0)
        # WinGet separates columns with at least one space; its column titles are single words.
        for ($c = 1; $c -lt $head.Length; $c++) { if ($head[$c] -ne ' ' -and $head[$c - 1] -eq ' ') { $starts += $c } }
        if ($starts.Count -lt 3) { continue }
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            $l = $lines[$j]
            if (-not $l.Trim() -or $l -match '^-{10,}') { break }
            if ($l.Length -le $starts[1]) { break }
            # A row has a space before every column; a sentence running across the columns does not.
            if (@($starts | Select-Object -Skip 1 | Where-Object { $_ -lt $l.Length -and $l[$_ - 1] -ne ' ' }).Count) { break }
            $cols = @()
            for ($k = 0; $k -lt $starts.Count; $k++) {
                $from = $starts[$k]
                $to = $(if ($k + 1 -lt $starts.Count) { $starts[$k + 1] } else { $l.Length })
                $cols += $(if ($from -lt $l.Length) { $l.Substring($from, [Math]::Min($to, $l.Length) - $from).Trim() } else { '' })
            }
            $id = $cols[1]
            # Summary lines ("3 upgrades available.") and notes end the table.
            if (-not $id -or $id -match '\s') { break }
            $rows += , @{ name = $cols[0]; id = $id; version = $(if ($cols.Count -gt 2) { $cols[2] } else { '' }); available = $(if ($cols.Count -gt 4) { $cols[3] } else { '' })
                          source = $(if ($cols.Count -gt 4) { $cols[4] } elseif ($cols.Count -gt 3) { $cols[3] } else { '' }); truncated = ($id.EndsWith([string][char]0x2026) -or $cols[0].EndsWith([string][char]0x2026)); explicit = ($table -gt 1) }
        }
    }
    return $rows
}

function ConvertFrom-WamExport {
    param($Doc)
    $out = @()
    foreach ($s in @($Doc['Sources'])) {
        if ($s -isnot [System.Collections.IDictionary]) { continue }
        $src = [string] $s['SourceDetails']['Name']
        foreach ($p in @($s['Packages'])) { if ($p -is [System.Collections.IDictionary] -and $p['PackageIdentifier']) { $out += , @{ id = [string] $p['PackageIdentifier']; version = [string] $p['Version']; source = $src } } }
    }
    return $out
}

<# Version comparison for upgrade eligibility: numeric parts first; "Unknown" or "<" versions are never eligible. #>
function Compare-WamVersion {
    param([string] $A, [string] $B)
    $x = @($A -split '[^0-9A-Za-z]+' | Where-Object { $_ }); $y = @($B -split '[^0-9A-Za-z]+' | Where-Object { $_ })
    for ($i = 0; $i -lt [Math]::Max($x.Count, $y.Count); $i++) {
        $p = $(if ($i -lt $x.Count) { $x[$i] } else { '0' }); $q = $(if ($i -lt $y.Count) { $y[$i] } else { '0' })
        if ($p -match '^\d+$' -and $q -match '^\d+$') { $d = [decimal] $p - [decimal] $q; if ($d -ne 0) { return [Math]::Sign($d) } }
        else { $d = [string]::Compare($p, $q, $true); if ($d -ne 0) { return [Math]::Sign($d) } }
    }
    return 0
}

function Get-WamEligibility {
    param($Row, [hashtable] $Policy)
    $id = ([string] $Row.id).ToLowerInvariant()
    if ($Row.truncated) { return 'The identifier is shortened in WinGet''s output; update it individually after checking it.' }
    if (-not $Row.version -or $Row.version -match '^(Unknown|<)' -or $Row.version.StartsWith('<')) { return 'The installed version is unknown to WinGet; it is never updated in bulk.' }
    if (-not $Row.available) { return 'No newer version is listed.' }
    if ((Compare-WamVersion $Row.available $Row.version) -le 0) { return 'The listed version is not newer.' }
    if ($Row.explicit) { return 'The publisher asks for this package to be updated only on its own.' }
    if ($Policy.ContainsKey($id) -and [string] $Policy[$id]['upgrade'] -eq 'explicit') { return 'The publisher asks for this package to be updated only on its own.' }
    if ([string] $Row.source -notin $script:WamSources) { return "Source '$($Row.source)' is not managed here." }
    return ''
}

<# Whether a package may be removed here, and how carefully. #>
function Get-WamRemovalPolicy {
    param([string] $Id, [hashtable] $Policy)
    foreach ($p in $script:WamProtected) { if ($Id -match $p) { return @{ allowed = $false; level = 'blocked'; reason = 'A Windows component, shared runtime or driver: never removed here.' } } }
    $e = $Policy[$Id.ToLowerInvariant()]
    if ($e) {
        switch ([string] $e['removal']) {
            'blocked' { return @{ allowed = $false; level = 'blocked'; reason = 'Marked as not removable (runtime or Windows component).' } }
            'caution' { return @{ allowed = $true; level = 'caution'; reason = "Removing $($e['name']) can affect security, drivers, devices or other applications." } }
        }
        return @{ allowed = $true; level = 'normal'; reason = '' }
    }
    return @{ allowed = $true; level = 'caution'; reason = 'Not in the curated catalog: check that nothing depends on it.' }
}

# ------------------------------------------------------------------------------------------------
# State, jobs and the operation queue (one WinGet process at a time)
# ------------------------------------------------------------------------------------------------

function New-WamState {
    param([hashtable] $Paths, [bool] $ForceDryRun = $false)
    $settings = Read-WamSettings $Paths
    if ($ForceDryRun) { $settings.dryRun = $true }
    @{
        Paths = $Paths; Settings = $settings; ForcedDryRun = $ForceDryRun; Policy = (Read-WamPolicy)
        Identity = (Get-WamIdentity); WinGet = ''; Started = (Get-WamNow).ToString('o')
        Inventory = (Read-WddJson $Paths.Inventory); Updates = (Read-WddJson $Paths.Updates)
        Validation = @{}; Jobs = New-Object System.Collections.Generic.List[object]; Current = $null
        Batch = $null; Messages = New-Object System.Collections.Generic.List[string]; LastRequest = (Get-WamNow); Stop = $false
    }
}

function Add-WamJob { param($S, [hashtable] $Job) $Job.state = 'Pending'; $S.Jobs.Add($Job) }

<# Advances the queue: polls the running WinGet process, then starts the next job. Never blocks. #>
function Step-WamQueue {
    param($S)
    if ($S.Current) {
        $r = Test-WamProcess $S.Current.handle
        if (-not $r.Done) {
            $limit = $(if ($S.Current.kind -eq 'operation') { 60 } else { 15 })
            if (((Get-WamNow) - $S.Current.handle.Started).TotalMinutes -gt $limit) { Stop-WamProcess $S.Current.handle; Complete-WamJob $S $S.Current @{ Done = $true; ExitCode = -1; Output = "Stopped after $limit minutes." } }
            return
        }
        Complete-WamJob $S $S.Current $r
    }
    $next = @($S.Jobs | Where-Object { $_.state -eq 'Pending' }) | Select-Object -First 1
    if (-not $next) { return }
    $next.state = 'Running'
    $next.startedUtc = (Get-WamNow).ToString('o')
    if ($next.kind -eq 'operation' -and $S.Settings.dryRun) {
        Complete-WamJob $S $next @{ Done = $true; ExitCode = 0; Output = 'Simulation mode: the command was not run.'; Simulated = $true }
        return
    }
    if ($next.kind -eq 'registry') { Complete-WamJob $S $next @{ Done = $true; ExitCode = 0; Output = '' }; return }
    try {
        $next.handle = Start-WamProcess $next.args (Join-Path $S.Paths.Work ("{0}.out" -f $next.id))
        $S.Current = $next
    } catch { Complete-WamJob $S $next @{ Done = $true; ExitCode = -2; Output = $_.Exception.Message } }
}

function Complete-WamJob {
    param($S, $Job, $R)
    $S.Current = $null
    $Job.state = 'Done'
    $Job.finishedUtc = (Get-WamNow).ToString('o')
    $Job.exitCode = $R.ExitCode
    try { & ("Complete-Wam" + $Job.handler) $S $Job $R } catch { $S.Messages.Add("$($Job.kind) $($Job.id): $($_.Exception.Message)"); $Job.error = $_.Exception.Message }
}

function New-WamId { ([guid]::NewGuid().ToString('N')).Substring(0, 12) }

function Start-WamInventory {
    param($S)
    $exp = Join-Path $S.Paths.Work 'export.json'
    if (Test-Path -LiteralPath $exp) { Remove-Item -LiteralPath $exp -Force }
    $a = @('export', '--output', $exp, '--include-versions')
    if ($S.Settings.acceptSourceAgreements) { $a += '--accept-source-agreements' }
    $a += '--disable-interactivity'
    Add-WamJob $S @{ id = (New-WamId); kind = 'inventory'; handler = 'Inventory'; args = $a; exportFile = $exp }
}

function Complete-WamInventory {
    param($S, $Job, $R)
    $pk = @()
    $method = 'winget export'
    $note = ''
    if (Test-Path -LiteralPath $Job.exportFile) {
        $doc = Read-WddJson $Job.exportFile
        if ($doc) { $pk = @(ConvertFrom-WamExport $doc) }
        Remove-Item -LiteralPath $Job.exportFile -Force -ErrorAction SilentlyContinue
    } else { $note = "WinGet could not list the installed packages (exit code $(Format-WdaHResult $R.ExitCode)). Installed programs are listed from Windows only." ; $method = 'Windows only' }
    $reg = @(Get-WdhUninstallEntries $S.Identity.Sid | Where-Object { $_.displayName } | ForEach-Object { @{ name = [string] $_.displayName; version = [string] $_.displayVersion; publisher = [string] $_.publisher; scope = [string] $_.scope } })
    $S.Inventory = [ordered]@{ scannedUtc = (Get-WamNow).ToString('o'); method = $method; note = $note; packages = $pk; programs = $reg }
    Write-WddJson $S.Paths.Inventory $S.Inventory
}

function Start-WamUpdateCheck {
    param($S)
    $acc = $(if ($S.Settings.acceptSourceAgreements) { @('--accept-source-agreements') } else { @() })
    Add-WamJob $S @{ id = (New-WamId); kind = 'sourceUpdate'; handler = 'SourceUpdate'; args = @(@('source', 'update', '--disable-interactivity')) }
    Add-WamJob $S @{ id = (New-WamId); kind = 'updates'; handler = 'Updates'; args = @(@('upgrade', '--source', 'winget') + $acc + @('--disable-interactivity')) }
    if ($S.Settings.acceptSourceAgreements) { Add-WamJob $S @{ id = (New-WamId); kind = 'updates'; handler = 'Updates'; source = 'msstore'; args = @(@('upgrade', '--source', 'msstore') + $acc + @('--disable-interactivity')) } }
}

function Complete-WamSourceUpdate {
    param($S, $Job, $R)
    $S.SourceUpdate = @{ ok = ($R.ExitCode -eq 0); exitCode = (Format-WdaHResult $R.ExitCode); finishedUtc = (Get-WamNow).ToString('o') }
}

function Complete-WamUpdates {
    param($S, $Job, $R)
    $src = $(if ($Job.ContainsKey('source')) { [string] $Job.source } else { 'winget' })
    $rows = @(ConvertFrom-WamTable $R.Output)
    $c = ConvertFrom-WdaExitCode $R.ExitCode
    $failed = $R.ExitCode -ne 0 -and -not $rows.Count
    $status = $(if (-not $failed) { 'ok' } elseif ($c.Class -eq 'Network' -or -not (Test-WamOnline)) { 'networkUnavailable' } else { 'sourceUnavailable' })
    $known = @{}
    if ($S.Inventory -and $S.Inventory['packages']) { foreach ($p in @($S.Inventory['packages'])) { $known[([string] $p['id']).ToLowerInvariant()] = [string] $p['id'] } }
    $items = @(foreach ($row in $rows) {
        if ($row.truncated) {
            $prefix = $row.id.TrimEnd([char]0x2026).ToLowerInvariant()
            $m = @($known.Keys | Where-Object { $_.StartsWith($prefix) })
            if ($m.Count -eq 1) { $row.id = $known[$m[0]]; $row.truncated = $false }
        }
        if (-not $row.source) { $row.source = $src }
        $why = Get-WamEligibility $row $S.Policy
        [ordered]@{ id = $row.id; name = $row.name; installed = $row.version; available = $row.available; source = $row.source; eligible = (-not $why); reason = $why; explicit = [bool] $row.explicit; truncated = [bool] $row.truncated }
    })
    $prev = $(if ($S.Updates -and $S.Updates['checkedUtc'] -eq $S.UpdateCheckId) { @($S.Updates['items']) } else { @() })
    $S.Updates = [ordered]@{ checkedUtc = $S.UpdateCheckId; finishedUtc = (Get-WamNow).ToString('o'); status = $status; exitCode = (Format-WdaHResult $R.ExitCode); items = @(@($prev | Where-Object { $_['source'] -ne $src }) + $items)
                             note = $(switch ($status) { 'networkUnavailable' { 'No network: updates cannot be checked now. Installed applications are not affected.' } 'sourceUnavailable' { "The $src source could not be read now. This does not mean any package was removed from it." } default { '' } }) }
    Write-WddJson $S.Paths.Updates $S.Updates
}

function Start-WamValidation {
    param($S, [object[]] $Items)
    foreach ($it in $Items) {
        $bad = Test-WamPackageSpec $it
        $key = "$($it['source']):$($it['id'])".ToLowerInvariant()
        if ($bad) { $S.Validation[$key] = @{ status = 'invalid'; detail = $bad }; continue }
        $S.Validation[$key] = @{ status = 'checking'; detail = '' }
        Add-WamJob $S @{ id = (New-WamId); kind = 'validate'; handler = 'Validation'; key = $key; args = (Get-WamArguments 'show' ([string] $it['id']) ([string] $it['source']) -AcceptSourceAgreements:$S.Settings.acceptSourceAgreements) }
    }
}

function Complete-WamValidation {
    param($S, $Job, $R)
    $lines = @(ConvertFrom-WamOutput $R.Output)
    $c = ConvertFrom-WdaExitCode $R.ExitCode
    $version = (@($lines | Where-Object { $_ -match '^\s*Version:\s*\S' }) | Select-Object -First 1) -replace '^\s*Version:\s*', ''
    $agreements = @($lines | Where-Object { $_ -match '^\s*(Agreements|License Agreement|Package Agreements?):' }).Count -gt 0
    $status = $(if ($R.ExitCode -eq 0) { 'available' } elseif ($c.Code -eq '0x8A150014') { 'notFound' } elseif ($c.Class -eq 'Network' -or -not (Test-WamOnline)) { 'networkUnavailable' } elseif ($c.Code -in '0x8A150046', '0x8A150041') { 'agreementRequired' } else { 'sourceUnavailable' })
    $S.Validation[$Job.key] = @{ status = $status; version = [string] $version; agreements = $agreements; exitCode = $c.Code; detail = $(switch ($status) { 'notFound' { 'Not found in this source now. Check the identifier; it is not installed or offered.' } 'networkUnavailable' { 'No network: availability cannot be checked now.' } 'sourceUnavailable' { "The source could not be read ($($c.Code)). This does not mean the package was removed." } 'agreementRequired' { 'The source or package asks for its terms to be accepted.' } default { '' } }) }
}

<#
    One batch of install, upgrade or uninstall operations, each checked and confirmed. Every item
    is validated again here: the page cannot widen what is run.
#>
function Start-WamBatch {
    param($S, [string] $Action, [object[]] $Items, [string] $Confirm = '')
    if ($Action -notin $script:WamActions) { return @{ ok = $false; error = "Unknown action '$Action'." } }
    if (-not @($Items).Count -or @($Items).Count -gt 200) { return @{ ok = $false; error = 'Choose between 1 and 200 applications.' } }
    if (@($S.Jobs | Where-Object { $_.kind -eq 'operation' -and $_.state -ne 'Done' }).Count) { return @{ ok = $false; error = 'Another batch is still running.' } }
    $checked = @()
    foreach ($it in $Items) {
        $bad = Test-WamPackageSpec $it
        if ($bad) { return @{ ok = $false; error = "Refused: $bad. Nothing was started." } }
        if ($Action -eq 'uninstall') {
            $pol = Get-WamRemovalPolicy ([string] $it['id']) $S.Policy
            if (-not $pol.allowed) { return @{ ok = $false; error = "Refused: $($it['id']) cannot be removed here. $($pol.reason)" } }
            if ($Confirm -ne 'REMOVE') { return @{ ok = $false; error = 'Removal needs the confirmation word REMOVE.' } }
            if ($pol.level -eq 'caution' -and -not [bool] $it['confirmCaution']) { return @{ ok = $false; error = "Refused: $($it['id']) needs its own confirmation. $($pol.reason)" } }
        }
        $checked += , $it
    }
    $batch = [ordered]@{ id = (New-WamId); action = $Action; startedUtc = (Get-WamNow).ToString('o'); dryRun = [bool] $S.Settings.dryRun; items = @() }
    foreach ($it in $checked) {
        $id = [string] $it['id']; $src = [string] $it['source']
        $argv = Get-WamArguments $Action $id $src ([string] $it['scope']) ([string] $it['version']) -AcceptPackageAgreements:([bool] $it['acceptPackageAgreements']) -AcceptSourceAgreements:$S.Settings.acceptSourceAgreements
        $job = @{ id = (New-WamId); kind = 'operation'; handler = 'Operation'; batchId = $batch.id; action = $Action; packageId = $id; source = $src; name = [string] $it['name']; catalogId = [string] $it['catalogId']
                  scope = [string] $it['scope']; priorVersion = [string] $it['installedVersion']; attempt = [int] $(if ($it['attempt']) { $it['attempt'] } else { 1 }); retryOf = [string] $it['retryOf']; args = $argv }
        Add-WamJob $S $job
        $batch.items += , $job.id
    }
    $S.Batch = $batch
    return @{ ok = $true; batchId = $batch.id; dryRun = $batch.dryRun; commands = @($checked | ForEach-Object { 'winget ' + ((Get-WamArguments $Action ([string] $_['id']) ([string] $_['source']) ([string] $_['scope']) ([string] $_['version']) -AcceptPackageAgreements:([bool] $_['acceptPackageAgreements']) -AcceptSourceAgreements:$S.Settings.acceptSourceAgreements) -join ' ') }) }
}

<# Installed version as WinGet sees it now (read-only "winget list --id --exact"), or $null when not installed. #>
function Get-WamInstalledVersion {
    param($S, [string] $Id, [string] $Source)
    $r = Invoke-WamQuick (Get-WamArguments 'list' $Id $Source -AcceptSourceAgreements:$S.Settings.acceptSourceAgreements)
    if ($r.ExitCode -ne 0) { return $null }
    $row = @(ConvertFrom-WamTable $r.Output | Where-Object { ([string] $_.id).ToLowerInvariant() -eq $Id.ToLowerInvariant() }) | Select-Object -First 1
    if ($row) { return [string] $row.version }
    return ''
}

<# A short, synchronous WinGet call (used only to verify one package after an operation). #>
function Invoke-WamQuick {
    param([string[]] $Arguments)
    $h = Start-WamProcess $Arguments (Join-Path $env:TEMP ("wam-{0}.out" -f (New-WamId)))
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline) { $r = Test-WamProcess $h; if ($r.Done) { return $r }; Start-Sleep -Milliseconds 200 }
    Stop-WamProcess $h
    return @{ Done = $true; ExitCode = -1; Output = 'Timed out.' }
}

function Complete-WamOperation {
    param($S, $Job, $R)
    $sim = [bool] $(if ($R -is [hashtable] -and $R.ContainsKey('Simulated')) { $R.Simulated } else { $false })
    $c = ConvertFrom-WdaExitCode $R.ExitCode
    $result = 'Failed'; $verification = 'NotVerified'; $resultVersion = ''; $manual = ''
    if ($sim) { $result = 'Simulated'; $verification = 'Simulated' }
    else {
        switch ($c.Status) {
            'Succeeded' { $result = 'Succeeded' }
            'AlreadyInstalled' { $result = $(if ($Job.action -eq 'upgrade') { 'UpToDate' } else { 'AlreadyInstalled' }) }
            'RequiresRestart' { $result = 'RequiresRestart' }
            'RequiresInteraction' { $result = 'ManualActionRequired'; $manual = 'The installer was cancelled or needs a person: run it again and answer its questions.' }
            'Unavailable' { $result = 'Unavailable' }
            default { $result = 'Failed' }
        }
        if ($c.Code -eq '0x8A150041') { $manual = 'This package asks for its licence agreement to be accepted. Review it with "winget show", then retry and accept it.'; $result = 'AgreementRequired' }
        if ($R.ExitCode -in 1223, -2147023673) { $result = 'Cancelled'; $manual = 'Administrator approval (UAC) was declined; nothing was changed.' }
        # Independent check: what WinGet lists now, not what the installer said.
        try {
            $now = Get-WamInstalledVersion $S $Job.packageId $Job.source
            if ($Job.action -eq 'uninstall') { $verification = $(if ($null -eq $now) { 'Verified' } else { 'StillInstalled' }) }
            else { $verification = $(if ($null -ne $now) { 'Verified' } elseif ($result -eq 'RequiresRestart') { 'PendingRestart' } else { 'NotFound' }); $resultVersion = [string] $now }
            if ($result -eq 'Succeeded' -and $verification -in 'NotFound', 'StillInstalled') { $result = 'Uncertain' }
        } catch { $verification = 'Unknown' }
    }
    $rec = [ordered]@{
        format = $script:WamFormat; version = 1; operationId = $Job.id; batchId = $Job.batchId; requestedBy = [string] $S.Identity.Name
        startedUtc = [string] $Job.startedUtc; finishedUtc = $Job.finishedUtc; action = $Job.action; packageId = $Job.packageId; source = $Job.source; name = $Job.name; catalogId = $Job.catalogId
        scope = $Job.scope; priorVersion = $Job.priorVersion; resultVersion = $resultVersion; exitCode = $c.Code; symbol = [string] $c.Message; failureClass = [string] $c.Class
        result = $result; verification = $verification; restartRequired = ($result -eq 'RequiresRestart' -or [string] $c.Restart -in 'later', 'now', 'initiated'); manualAction = $manual
        retryable = ([bool] $c.Retry -and $result -eq 'Failed'); attempt = $Job.attempt; retryOf = $Job.retryOf; dryRun = $sim; command = 'winget ' + ($Job.args -join ' ')
        output = (Protect-WamText ((@(ConvertFrom-WamOutput $R.Output) | Where-Object { $_ } | Select-Object -Last 8) -join "`n"))
    }
    $Job.record = $rec
    Add-WamHistory $S.Paths $rec
}

<# Passwords and tokens never reach the history (WinGet does not print them; this is a second line of defence). #>
function Protect-WamText {
    param([string] $Text)
    $t = [regex]::Replace($Text, '(?i)\b(password|passwd|pwd|token|apikey|secret)(\s*[=:]\s*)\S+', '$1$2[redacted]')
    if ($t.Length -gt 2000) { $t = $t.Substring($t.Length - 2000) }
    return $t
}

# ------------------------------------------------------------------------------------------------
# Reports
# ------------------------------------------------------------------------------------------------

function ConvertTo-WamCsv {
    param([object[]] $Records)
    $cols = 'finishedUtc', 'action', 'name', 'packageId', 'source', 'priorVersion', 'resultVersion', 'result', 'verification', 'exitCode', 'restartRequired', 'attempt', 'dryRun'
    $esc = { param($v) $s = [string] $v; if ($s -match '[",\r\n]') { '"' + ($s -replace '"', '""') + '"' } else { $s } }
    $lines = @($cols -join ',')
    foreach ($r in $Records) { $lines += (@($cols | ForEach-Object { & $esc $r[$_] }) -join ',') }
    return ($lines -join "`r`n") + "`r`n"
}

function ConvertTo-WamHtml {
    param([object[]] $Records, [string] $Computer, [string] $User)
    $enc = { param($v) [System.Net.WebUtility]::HtmlEncode([string] $v) }
    $rows = @($Records | ForEach-Object { "<tr><td>$(& $enc $_['finishedUtc'])</td><td>$(& $enc $_['action'])</td><td>$(& $enc $_['name'])<br><code>$(& $enc $_['packageId'])</code></td><td>$(& $enc $_['priorVersion'])</td><td>$(& $enc $_['resultVersion'])</td><td>$(& $enc $_['result'])</td><td>$(& $enc $_['verification'])</td><td><code>$(& $enc $_['exitCode'])</code></td></tr>" }) -join "`n"
    @"
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Application Manager report</title>
<style>body{font:14px/1.5 "Segoe UI",system-ui,sans-serif;margin:24px;color:#1d2330}table{border-collapse:collapse;width:100%}th,td{border-top:1px solid #ccd;padding:6px 8px;text-align:left;vertical-align:top}th{color:#555}code{font-family:Consolas,monospace;font-size:12px}@media print{body{margin:0}}</style></head>
<body><h1>Application Manager report</h1><p>$(& $enc $Computer) &middot; $(& $enc $User) &middot; created $(& $enc ((Get-WamNow).ToString('u'))) &middot; $($Records.Count) operation(s). Simulated operations are marked "Simulated".</p>
<table><thead><tr><th>Finished (UTC)</th><th>Action</th><th>Application</th><th>Before</th><th>After</th><th>Result</th><th>Verified</th><th>Exit code</th></tr></thead><tbody>
$rows
</tbody></table></body></html>
"@
}

# ------------------------------------------------------------------------------------------------
# HTTP (127.0.0.1 only)
# ------------------------------------------------------------------------------------------------

$script:WamTypes = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.json' = 'application/json; charset=utf-8'; '.map' = 'application/json; charset=utf-8'; '.ico' = 'image/x-icon'; '.woff2' = 'font/woff2' }
$script:WamCsp = "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'; object-src 'none'"

function Test-WamToken { param([string] $A, [string] $B) if ($A.Length -ne $B.Length) { return $false }; $d = 0; for ($i = 0; $i -lt $A.Length; $i++) { $d = $d -bor ([int][char]$A[$i] -bxor [int][char]$B[$i]) }; return $d -eq 0 }

<#
    Decides how to answer one parsed request: @{ Method; Path; Query; Headers (lower-case keys); Body }.
    Returns @{ Status; Type; Body (string or byte[]); Headers }. Pure apart from the state it acts on.
#>
function Invoke-WamRequest {
    param($S, [hashtable] $Req, [string] $Token, [int] $Port)
    $json = { param([int] $Status, $Value) @{ Status = $Status; Type = 'application/json; charset=utf-8'; Body = ($Value | ConvertTo-Json -Depth 10 -Compress) } }
    $hostOk = [string] $Req.Headers['host'] -in "127.0.0.1:$Port", "localhost:$Port"
    if (-not $hostOk) { return & $json 421 @{ error = 'Wrong host.' } }
    $origin = [string] $Req.Headers['origin']
    if ($origin -and $origin -notin "http://127.0.0.1:$Port", "http://localhost:$Port") { return & $json 403 @{ error = 'Cross-origin requests are refused.' } }
    if ([string] $Req.Headers['sec-fetch-site'] -eq 'cross-site') { return & $json 403 @{ error = 'Cross-site requests are refused.' } }
    $path = $Req.Path
    if (-not $path.StartsWith('/api/')) {
        if ($Req.Method -ne 'GET') { return & $json 405 @{ error = 'Method not allowed.' } }
        if ($path -eq '/' ) { $path = '/manager.html' }
        if ($path -notmatch '^/(manager\.html|assets/[A-Za-z0-9._-]+|app-icons/[A-Za-z0-9._-]+)$') { return & $json 404 @{ error = 'Not found.' } }
        $file = Join-Path (Join-Path $script:WamRoot 'ui') ($path.TrimStart('/') -replace '/', '\')
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return & $json 404 @{ error = 'Not found.' } }
        $ext = [IO.Path]::GetExtension($file).ToLowerInvariant()
        return @{ Status = 200; Type = $(if ($script:WamTypes.ContainsKey($ext)) { $script:WamTypes[$ext] } else { 'application/octet-stream' }); Body = [IO.File]::ReadAllBytes($file) }
    }
    if (-not (Test-WamToken ([string] $Req.Headers['x-wdb-token']) $Token)) { return & $json 401 @{ error = 'Missing or wrong session token. Open the manager from its shortcut.' } }
    $S.LastRequest = Get-WamNow
    $body = $(if ($Req.Body) { try { ConvertTo-WddHashtable ($Req.Body | ConvertFrom-Json) } catch { $null } } else { @{} })
    if ($Req.Body -and $null -eq $body) { return & $json 400 @{ error = 'The request is not valid JSON.' } }
    switch ("$($Req.Method) $path") {
        'GET /api/state' { return & $json 200 (Get-WamPublicState $S) }
        'POST /api/scan' {
            if ([string] $body['kind'] -eq 'updates') { $S.UpdateCheckId = (Get-WamNow).ToString('o'); Start-WamUpdateCheck $S } else { Start-WamInventory $S }
            return & $json 202 @{ ok = $true }
        }
        'POST /api/validate' { Start-WamValidation $S @($body['items']); return & $json 202 @{ ok = $true } }
        'POST /api/operations' {
            $r = Start-WamBatch $S ([string] $body['action']) @($body['items']) ([string] $body['confirm'])
            return & $json $(if ($r.ok) { 202 } else { 400 }) $r
        }
        'POST /api/cancel' {
            $n = 0
            foreach ($j in $S.Jobs) { if ($j.state -eq 'Pending' -and $j.kind -eq 'operation') { $j.state = 'Done'; $j.cancelled = $true; $n++ } }
            return & $json 200 @{ ok = $true; cancelled = $n; note = 'Operations not started yet were cancelled; a running installer is never interrupted.' }
        }
        'POST /api/settings' {
            if ($body.ContainsKey('dryRun')) { $S.Settings.dryRun = ([bool] $body['dryRun']) -or $S.ForcedDryRun }
            if ($body.ContainsKey('acceptSourceAgreements')) { $S.Settings.acceptSourceAgreements = [bool] $body['acceptSourceAgreements'] }
            Write-WddJson $S.Paths.Settings @{ dryRun = $S.Settings.dryRun; acceptSourceAgreements = $S.Settings.acceptSourceAgreements }
            return & $json 200 @{ ok = $true; settings = $S.Settings }
        }
        'GET /api/profiles' { $p = Read-WddJson $S.Paths.Profiles; return & $json 200 @{ profiles = $(if ($p) { $p } else { $null }) } }
        'PUT /api/profiles' {
            if ($Req.Body.Length -gt 1MB) { return & $json 413 @{ error = 'Too large.' } }
            Write-WddJson $S.Paths.Profiles $body
            return & $json 200 @{ ok = $true }
        }
        'GET /api/history' { return & $json 200 @{ records = @(Read-WamHistory $S.Paths 500) } }
        'GET /api/report' {
            $recs = @(Read-WamHistory $S.Paths 5000)
            switch ([string] $Req.Query['format']) {
                'csv' { return @{ Status = 200; Type = 'text/csv; charset=utf-8'; Body = (ConvertTo-WamCsv $recs); Headers = @{ 'Content-Disposition' = 'attachment; filename="application-manager-history.csv"' } } }
                'html' { return @{ Status = 200; Type = 'text/html; charset=utf-8'; Body = (ConvertTo-WamHtml $recs $env:COMPUTERNAME $S.Identity.Name); Headers = @{ 'Content-Disposition' = 'attachment; filename="application-manager-report.html"' } } }
                default { return @{ Status = 200; Type = 'application/json; charset=utf-8'; Body = (@{ format = 'windows-deployment-builder/app-manager-history'; version = 1; generatedUtc = (Get-WamNow).ToString('o'); records = $recs } | ConvertTo-Json -Depth 8); Headers = @{ 'Content-Disposition' = 'attachment; filename="application-manager-history.json"' } } }
            }
        }
        'POST /api/shutdown' { $S.Stop = $true; return & $json 200 @{ ok = $true } }
    }
    return & $json 404 @{ error = 'Unknown API.' }
}

function Get-WamPublicState {
    param($S)
    $jobs = @($S.Jobs | Where-Object { $_.kind -eq 'operation' -and $S.Batch -and $_.batchId -eq $S.Batch.id } | ForEach-Object {
        [ordered]@{ id = $_.id; packageId = $_.packageId; name = $_.name; action = $_.action; state = $(if ($_.ContainsKey('cancelled')) { 'Cancelled' } else { $_.state }); record = $(if ($_.ContainsKey('record')) { $_.record } else { $null }) }
    })
    [ordered]@{
        agent = [ordered]@{ version = $script:WamVersion; started = $S.Started; user = [string] $S.Identity.Name; elevated = [bool] $S.Identity.Elevated; winget = $S.WinGet; online = (Test-WamOnline) }
        settings = [ordered]@{ dryRun = [bool] $S.Settings.dryRun; forcedDryRun = [bool] $S.ForcedDryRun; acceptSourceAgreements = [bool] $S.Settings.acceptSourceAgreements }
        busy = [bool] (@($S.Jobs | Where-Object { $_.state -ne 'Done' }).Count)
        running = $(if ($S.Current) { [string] $S.Current.kind } else { '' })
        inventory = $S.Inventory; updates = $S.Updates; validation = $S.Validation
        batch = $(if ($S.Batch) { [ordered]@{ id = $S.Batch.id; action = $S.Batch.action; dryRun = $S.Batch.dryRun; startedUtc = $S.Batch.startedUtc; jobs = $jobs } } else { $null })
        messages = @($S.Messages | Select-Object -Last 10)
    }
}

<# Reads one HTTP/1.1 request from a stream (headers up to 16 KB, body up to 2 MB). #>
function Read-WamHttp {
    param([IO.Stream] $Stream)
    $buf = New-Object byte[] 8192
    $ms = New-Object IO.MemoryStream
    $headerEnd = -1
    while ($headerEnd -lt 0) {
        $n = $Stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { return $null }
        $ms.Write($buf, 0, $n)
        $text = [Text.Encoding]::ASCII.GetString($ms.ToArray())
        $headerEnd = $text.IndexOf("`r`n`r`n")
        if ($ms.Length -gt 16KB -and $headerEnd -lt 0) { return $null }
    }
    $all = $ms.ToArray()
    $head = [Text.Encoding]::ASCII.GetString($all, 0, $headerEnd)
    $lines = $head -split "`r`n"
    $parts = $lines[0] -split ' '
    if ($parts.Count -lt 3) { return $null }
    $headers = @{}
    foreach ($l in $lines[1..($lines.Count - 1)]) { $i = $l.IndexOf(':'); if ($i -gt 0) { $headers[$l.Substring(0, $i).Trim().ToLowerInvariant()] = $l.Substring($i + 1).Trim() } }
    $len = 0
    if ($headers.ContainsKey('content-length')) { $len = [int] $headers['content-length'] }
    if ($len -gt 2MB) { return $null }
    $bodyBytes = New-Object byte[] $len
    $have = $all.Length - ($headerEnd + 4)
    if ($have -gt 0) { [Array]::Copy($all, $headerEnd + 4, $bodyBytes, 0, [Math]::Min($have, $len)) }
    while ($have -lt $len) { $n = $Stream.Read($bodyBytes, $have, $len - $have); if ($n -le 0) { break }; $have += $n }
    $target = $parts[1]
    $q = @{}
    $qi = $target.IndexOf('?')
    $path = $(if ($qi -ge 0) { $target.Substring(0, $qi) } else { $target })
    if ($qi -ge 0) { foreach ($kv in $target.Substring($qi + 1) -split '&') { $p = $kv -split '=', 2; if ($p[0]) { $q[[uri]::UnescapeDataString($p[0])] = $(if ($p.Count -gt 1) { [uri]::UnescapeDataString($p[1]) } else { '' }) } } }
    @{ Method = $parts[0]; Path = $path; Query = $q; Headers = $headers; Body = [Text.Encoding]::UTF8.GetString($bodyBytes) }
}

function Write-WamHttp {
    param([IO.Stream] $Stream, [hashtable] $Res)
    $body = $(if ($Res.Body -is [byte[]]) { $Res.Body } else { (New-Object Text.UTF8Encoding($false)).GetBytes([string] $Res.Body) })
    $reason = @{ 200 = 'OK'; 202 = 'Accepted'; 400 = 'Bad Request'; 401 = 'Unauthorized'; 403 = 'Forbidden'; 404 = 'Not Found'; 405 = 'Method Not Allowed'; 413 = 'Payload Too Large'; 421 = 'Misdirected Request'; 500 = 'Internal Server Error' }[[int] $Res.Status]
    $h = "HTTP/1.1 $($Res.Status) $reason`r`nContent-Type: $($Res.Type)`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nReferrer-Policy: no-referrer`r`nContent-Security-Policy: $script:WamCsp`r`nConnection: close`r`n"
    if ($Res.ContainsKey('Headers') -and $Res.Headers) { foreach ($k in $Res.Headers.Keys) { $h += "$k`: $($Res.Headers[$k])`r`n" } }
    $hb = [Text.Encoding]::ASCII.GetBytes($h + "`r`n")
    $Stream.Write($hb, 0, $hb.Length)
    $Stream.Write($body, 0, $body.Length)
    $Stream.Flush()
}

function Start-WamServer {
    param([hashtable] $Paths, [int] $Port = 0, [switch] $DryRun, [switch] $NoBrowser, [int] $IdleMinutes = 45)
    Initialize-WamStore $Paths
    $S = New-WamState $Paths ([bool] $DryRun)
    $S.WinGet = Get-WamWinGetPath
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $token = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    $port = ([Net.IPEndPoint] $listener.LocalEndpoint).Port
    $url = "http://127.0.0.1:$port/manager.html#$token"
    Write-Output "Application Manager: http://127.0.0.1:$port/ (this computer only). Close this window to stop it."
    if (-not $NoBrowser) { Open-WamBrowser $url } else { Write-Output "Open: $url" }
    try {
        while (-not $S.Stop) {
            if ($listener.Pending()) {
                $client = $listener.AcceptTcpClient()
                try {
                    $client.ReceiveTimeout = 2000
                    $stream = $client.GetStream()
                    # Browsers open spare connections that may never send a request: do not wait on them.
                    $wait = [Diagnostics.Stopwatch]::StartNew()
                    while (-not $stream.DataAvailable -and $wait.ElapsedMilliseconds -lt 1500) { Start-Sleep -Milliseconds 10 }
                    if (-not $stream.DataAvailable) { continue }
                    $req = Read-WamHttp $stream
                    if ($req) {
                        $res = $null
                        try { $res = Invoke-WamRequest $S $req $token $port } catch { $res = @{ Status = 500; Type = 'application/json'; Body = (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) } }
                        Write-WamHttp $stream $res
                    }
                } catch { } finally { $client.Close() }
                continue
            }
            Step-WamQueue $S
            $idle = ((Get-WamNow) - $S.LastRequest).TotalMinutes
            if ($idle -gt $IdleMinutes -and -not @($S.Jobs | Where-Object { $_.state -ne 'Done' }).Count) { Write-Output 'No page has been open for a while; stopping.'; break }
            Start-Sleep -Milliseconds 40
        }
    } finally { $listener.Stop() }
}

if ($script:WamMain) {
    $a = $script:WamArgs
    $id = Get-WamIdentity
    if ($id.IsSystem) { Write-Output 'The Application Manager runs as a signed-in user, not as SYSTEM.'; exit 2 }
    if ($a.WinGet) {
        if (-not (Test-Path -LiteralPath $a.WinGet -PathType Leaf)) { Write-Output "WinGet not found: $($a.WinGet)"; exit 2 }
        $script:WamWinGetPath = (Resolve-Path -LiteralPath $a.WinGet).Path
    }
    Start-WamServer (Get-WamPaths $a.DataRoot) -Port $a.Port -DryRun:$a.DryRun -NoBrowser:$a.NoBrowser -IdleMinutes $a.IdleMinutes
    exit 0
}
