#Requires -Version 5.1
<#
    Phase 10 scenario tests for the Application Manager agent (AppManager.ps1) against a simulated
    WinGet. The agent is dot-sourced in Library mode (which only defines its functions) and every
    adapter that touches the system is replaced: WinGet processes, the network, the identity, the
    Windows uninstall records. Nothing is installed, upgraded, removed or changed on this computer;
    everything is written below a temporary folder.

    One scenario starts the real HTTP listener on 127.0.0.1 (Simulation mode, no browser) and calls
    its read-only state API: it runs no WinGet command.

    Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\powershell\AppManager.Tests.ps1 -Policy <catalog-policy.json> [-Out <dir>]
    -Out writes the argument cases (args.json) for the TypeScript parity test.
#>
param([Parameter(Mandatory = $true)] [string] $Policy, [string] $Out = '')

$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot '..\..\src\engine'
. (Join-Path $src 'deployment\scripts\DeploymentCommon.ps1')
. (Join-Path $src 'applications\scripts\ApplicationEngine.ps1')
. (Join-Path $src 'health\scripts\DeploymentHealth.ps1') -Mode Library
$agentPath = Join-Path $src 'manager\scripts\AppManager.ps1'
. $agentPath -Mode Library
$ErrorActionPreference = 'Stop'

$script:Failures = 0
$script:Passed = 0
$script:Temp = Join-Path ([IO.Path]::GetTempPath()) ("wam-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:Temp -Force | Out-Null
$script:WamRoot = Join-Path $script:Temp 'agent'
New-Item -ItemType Directory -Path (Join-Path $script:WamRoot 'ui\assets') -Force | Out-Null
Copy-Item -LiteralPath $Policy -Destination (Join-Path $script:WamRoot 'catalog-policy.json')
[IO.File]::WriteAllText((Join-Path $script:WamRoot 'ui\manager.html'), '<!doctype html><title>Application Manager</title>')
[IO.File]::WriteAllText((Join-Path $script:WamRoot 'ui\assets\manager.js'), 'console.log(1)')
[IO.File]::WriteAllText((Join-Path $script:Temp 'secret.txt'), 'outside the ui folder')

function Assert-Equal($Actual, $Expected, [string] $Message) { if ("$Actual" -ne "$Expected") { throw "ASSERT: $Message. Expected <$Expected>, got <$Actual>." } }
function Assert-True($Value, [string] $Message) { if (-not $Value) { throw "ASSERT: $Message" } }

# ------------------------------------------------------------------------------------------------
# Simulated WinGet and Windows
# ------------------------------------------------------------------------------------------------

$script:E = @{ NotFound = 0x8A150014; Network = 0x8A150008; SourceOpen = 0x8A150045; Agreement = 0x8A150041; Cancelled = 0x8A15010C; Reboot = 0x8A150109; Hash = 0x8A150011; UacDeclined = -2147023673 }

function Reset-Sim {
    param([hashtable] $Installed = @{}, [hashtable] $Available = @{}, [hashtable] $Behavior = @{}, [string[]] $Explicit = @(), [bool] $Online = $true, [object[]] $Programs = @(), [hashtable] $Sources = @{})
    $script:Sim = @{ Installed = $Installed.Clone(); Available = $Available.Clone(); Behavior = $Behavior.Clone(); Explicit = $Explicit; Online = $Online; Programs = $Programs; Sources = $Sources.Clone(); Calls = New-Object System.Collections.Generic.List[string]; Now = [DateTime]::new(2026, 10, 25, 12, 0, 0, [DateTimeKind]::Utc) }
    $paths = Get-WamPaths (Join-Path $script:Temp ("data-" + [Guid]::NewGuid().ToString('N')))
    Initialize-WamStore $paths
    $script:S = New-WamState $paths
    $script:S.Settings.dryRun = $false
    return $script:S
}

function Get-WamNow { $script:Sim.Now = $script:Sim.Now.AddSeconds(1); $script:Sim.Now }
function Get-WamWinGetPath { 'C:\Sim\winget.exe' }
function Get-WamIdentity { @{ Name = 'PC\owner'; Sid = 'S-1-5-21-1000'; IsSystem = $false; Elevated = $false } }
function Test-WamOnline { [bool] $script:Sim.Online }
function Get-WdhUninstallEntries { param([string] $Sid = '') @($script:Sim.Programs) }
function Stop-WamProcess { param($Handle) }

function Get-SimSource { param([string] $Id) if ($script:Sim.Sources.ContainsKey($Id)) { $script:Sim.Sources[$Id] } else { 'winget' } }

function Format-SimTable {
    param([object[]] $Rows, [switch] $NoAvailable)
    $cols = $(if ($NoAvailable) { 'Name', 'Id', 'Version', 'Source' } else { 'Name', 'Id', 'Version', 'Available', 'Source' })
    $w = @{}
    foreach ($c in $cols) { $w[$c] = [Math]::Max($c.Length, (@($Rows | ForEach-Object { ([string] $_[$c]).Length }) + 0 | Measure-Object -Maximum).Maximum) }
    $line = { param($r) (@($cols | ForEach-Object { ([string] $r[$_]).PadRight($w[$_]) }) -join ' ').TrimEnd() }
    $head = & $line @{ Name = 'Name'; Id = 'Id'; Version = 'Version'; Available = 'Available'; Source = 'Source' }
    @($head, ('-' * ($head.Length + 2))) + @($Rows | ForEach-Object { & $line $_ })
}

function Get-SimResponse {
    param([string[]] $A)
    $verb = $A[0]
    $id = $(if ($A.Count -gt 2 -and $A[1] -eq '--id') { $A[2] } else { '' })
    $sim = $script:Sim
    $offline = -not $sim.Online
    switch ($verb) {
        'export' {
            $file = $A[2]
            $doc = @{ '$schema' = 'https://aka.ms/winget-packages.schema.2.0.json'; Sources = @(
                @{ SourceDetails = @{ Name = 'winget'; Identifier = 'Microsoft.Winget.Source_8wekyb3d8bbwe'; Argument = 'https://cdn.winget.microsoft.com/cache'; Type = 'Microsoft.PreIndexed.Package' }
                   Packages = @($sim.Installed.Keys | Where-Object { (Get-SimSource $_) -eq 'winget' } | Sort-Object | ForEach-Object { @{ PackageIdentifier = $_; Version = $sim.Installed[$_] } }) }) }
            [IO.File]::WriteAllText($file, ($doc | ConvertTo-Json -Depth 6))
            return @{ ExitCode = 0; Output = "   -`r   \`rInstalled package list exported." }
        }
        'source' { if ($offline) { return @{ ExitCode = $script:E.SourceOpen; Output = 'Failed when opening source(s); try the ''source reset'' command if the problem persists.' } }; return @{ ExitCode = 0; Output = "Updating all sources...`nUpdating source: winget...`nDone" } }
        'show' {
            if ($offline) { return @{ ExitCode = $script:E.SourceOpen; Output = 'Failed when searching source: winget' } }
            if (-not $sim.Available.ContainsKey($id)) { return @{ ExitCode = $script:E.NotFound; Output = 'No package found matching input criteria.' } }
            $agree = $(if ($sim.Behavior[$id] -eq 'agreement') { "`nAgreements:`n  License: https://example.com/eula" } else { '' })
            return @{ ExitCode = 0; Output = "Found $id [$id]`nVersion: $($sim.Available[$id])`nPublisher: Example$agree" }
        }
        'list' {
            if ($sim.Installed.ContainsKey($id)) { return @{ ExitCode = 0; Output = ((Format-SimTable @(@{ Name = $id; Id = $id; Version = $sim.Installed[$id]; Source = 'winget' }) -NoAvailable) -join "`n") } }
            return @{ ExitCode = $script:E.NotFound; Output = 'No installed package found matching input criteria.' }
        }
        'upgrade' {
            if (-not $id) {
                $src = $A[2]
                if ($offline) { return @{ ExitCode = $script:E.SourceOpen; Output = "Failed when searching source: $src" } }
                $rows = @($sim.Installed.Keys | Sort-Object | Where-Object { (Get-SimSource $_) -eq $src -and $sim.Available.ContainsKey($_) -and $sim.Available[$_] -ne $sim.Installed[$_] } | ForEach-Object { @{ Name = $_.Split('.')[-1]; Id = $_; Version = $sim.Installed[$_]; Available = $sim.Available[$_]; Source = $src } })
                $normal = @($rows | Where-Object { $sim.Explicit -notcontains $_.Id })
                $explicit = @($rows | Where-Object { $sim.Explicit -contains $_.Id })
                if (-not $rows.Count) { return @{ ExitCode = 0; Output = 'No installed package found matching input criteria.' } }
                $out = @("   - `r   \ `r") + (Format-SimTable $normal) + @("$($normal.Count) upgrades available.")
                if ($explicit.Count) { $out += @('', 'The following packages have an upgrade available, but require explicit targeting for upgrade:') + (Format-SimTable $explicit) }
                return @{ ExitCode = 0; Output = ($out -join "`r`n") }
            }
            return (Invoke-SimChange $id 'upgrade')
        }
        'install' { return (Invoke-SimChange $id 'install') }
        'uninstall' { return (Invoke-SimChange $id 'uninstall') }
    }
    throw "simulated WinGet: unexpected command $($A -join ' ')"
}

function Invoke-SimChange {
    param([string] $Id, [string] $Verb)
    $sim = $script:Sim
    $b = [string] $sim.Behavior[$Id]
    if (-not $sim.Online -and $Verb -ne 'uninstall') { return @{ ExitCode = $script:E.Network; Output = 'Download failed.' } }
    switch ($b) {
        'fail' { return @{ ExitCode = $script:E.Network; Output = 'An unexpected error occurred while executing the command: download failed' } }
        'hash' { return @{ ExitCode = $script:E.Hash; Output = 'Installer hash does not match; this cannot be overridden when running as admin' } }
        'cancel' { return @{ ExitCode = $script:E.Cancelled; Output = 'Installer failed: cancelled by user' } }
        'uac' { return @{ ExitCode = $script:E.UacDeclined; Output = 'The operation was canceled by the user.' } }
        'agreement' { if ($script:LastArgs -notcontains '--accept-package-agreements') { return @{ ExitCode = $script:E.Agreement; Output = 'Package agreements were not agreed to. Operation cancelled.' } } }
        'lies' { return @{ ExitCode = 0; Output = 'Successfully installed' } }
        'password' { return @{ ExitCode = $script:E.Network; Output = "Download from https://example.com failed`npassword=hunter2 token: abc123" } }
    }
    if ($Verb -eq 'uninstall') { [void] $sim.Installed.Remove($Id); return @{ ExitCode = 0; Output = 'Successfully uninstalled' } }
    if ($Verb -eq 'install' -and $sim.Installed.ContainsKey($Id)) { return @{ ExitCode = 0x8A150061; Output = 'Found an existing package already installed.' } }
    $sim.Installed[$Id] = $sim.Available[$Id]
    if ($b -eq 'reboot') { return @{ ExitCode = $script:E.Reboot; Output = 'Restart your PC to finish installation.' } }
    return @{ ExitCode = 0; Output = "Downloading`r`n  ██████████████  10.0 MB / 10.0 MB`r`nSuccessfully verified installer hash`r`nSuccessfully installed" }
}

function Start-WamProcess {
    param([string[]] $Arguments, [string] $OutFile)
    $script:Sim.Calls.Add(($Arguments -join ' '))
    $script:LastArgs = $Arguments
    return @{ Process = $null; OutFile = $OutFile; Started = (Get-WamNow); Response = (Get-SimResponse $Arguments); Polls = 0; Quick = ($Arguments[0] -eq 'list') }
}
function Test-WamProcess {
    param($Handle)
    $Handle.Polls++
    if (-not $Handle.Quick -and $Handle.Polls -lt 2) { return @{ Done = $false } }
    return @{ Done = $true; ExitCode = [int] $Handle.Response.ExitCode; Output = [string] $Handle.Response.Output }
}

function Invoke-Pump { param($S) for ($i = 0; $i -lt 400; $i++) { Step-WamQueue $S; if (-not $S.Current -and -not @($S.Jobs | Where-Object { $_.state -ne 'Done' }).Count) { return } }; throw 'queue did not finish' }
function Get-Records { param($S) Read-WamHistory $S.Paths }
function Item { param([string] $Id, [hashtable] $More = @{}) $h = @{ id = $Id; source = 'winget'; name = $Id; scope = ''; version = '' }; foreach ($k in $More.Keys) { $h[$k] = $More[$k] }; $h }
function Req { param([string] $Method = 'GET', [string] $Path = '/api/state', [hashtable] $Headers = @{}, [string] $Body = '', [hashtable] $Query = @{}) $h = @{ host = '127.0.0.1:5555'; 'x-wdb-token' = 'tok' }; foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }; @{ Method = $Method; Path = $Path; Query = $Query; Headers = $h; Body = $Body } }
function Call { param($S, $R) $res = Invoke-WamRequest $S $R 'tok' 5555; $obj = $null; if ($res.Type -like 'application/json*' -and $res.Body -is [string]) { $obj = ConvertTo-WddHashtable ($res.Body | ConvertFrom-Json) }; @{ Status = $res.Status; Json = $obj; Res = $res } }

# ------------------------------------------------------------------------------------------------
# Scenarios
# ------------------------------------------------------------------------------------------------

$tests = [ordered]@{}

$tests['arguments: exact identifier and source, --silent, no --force or hash or unknown-version flags; agreements only when accepted'] = {
    $a = Get-WamArguments 'install' 'Git.Git' 'winget'
    Assert-Equal ($a -join ' ') 'install --id Git.Git --exact --source winget --silent --no-upgrade --disable-interactivity' 'plain install'
    $a = Get-WamArguments 'install' 'Git.Git' 'winget' 'user' '2.47.0' -AcceptPackageAgreements -AcceptSourceAgreements
    Assert-Equal ($a -join ' ') 'install --id Git.Git --exact --source winget --scope user --version 2.47.0 --silent --no-upgrade --accept-package-agreements --accept-source-agreements --disable-interactivity' 'scoped, versioned, agreed'
    Assert-Equal ((Get-WamArguments 'upgrade' 'Git.Git' 'winget' -AcceptPackageAgreements) -join ' ') 'upgrade --id Git.Git --exact --source winget --silent --accept-package-agreements --disable-interactivity' 'upgrade'
    Assert-Equal ((Get-WamArguments 'uninstall' 'Git.Git' 'winget' -AcceptPackageAgreements) -join ' ') 'uninstall --id Git.Git --exact --source winget --silent --disable-interactivity' 'uninstall never accepts agreements'
    foreach ($action in 'install', 'upgrade', 'uninstall') {
        $all = (Get-WamArguments $action 'X.Y' 'winget' 'machine' '1.0' -AcceptPackageAgreements -AcceptSourceAgreements) -join ' '
        foreach ($bad in '--force', '--ignore-security-hash', '--ignore-local-archive-malware-scan', '--include-unknown', '--uninstall-previous', '--purge', '--all', '--override', '--custom') { Assert-True ($all -notmatch [regex]::Escape($bad)) "$action never uses $bad" }
    }
}

$tests['package specs: only WinGet/Store identifiers, scopes and versions of the expected shape (no command injection)'] = {
    Assert-Equal (Test-WamPackageSpec (Item 'Git.Git')) '' 'valid'
    Assert-Equal (Test-WamPackageSpec @{ id = '9NKSQGP7F2NH'; source = 'msstore'; scope = ''; version = '' }) '' 'store id'
    foreach ($bad in 'Git.Git; calc', 'Git.Git --force', '"Git.Git"', '..\x', 'Git', '-Git.Git', 'Git.Git&calc') { Assert-True (Test-WamPackageSpec (Item $bad)) "refused: $bad" }
    Assert-True (Test-WamPackageSpec @{ id = 'Git.Git'; source = 'chocolatey'; scope = ''; version = '' }) 'unknown source refused'
    Assert-True (Test-WamPackageSpec (Item 'Git.Git' @{ scope = 'system' })) 'unknown scope refused'
    Assert-True (Test-WamPackageSpec (Item 'Git.Git' @{ version = '1.0 --force' })) 'version with spaces refused'
    Assert-True (Test-WamPackageSpec 'Git.Git') 'non-object refused'
}

$tests['WinGet tables: columns from the header, progress lines ignored, explicit-upgrade table marked, summary line ends the table'] = {
    $text = (@("   - `r   \ `r") + (Format-SimTable @(@{ Name = 'Git'; Id = 'Git.Git'; Version = '2.45.1'; Available = '2.47.0'; Source = 'winget' }, @{ Name = 'Google Chrome'; Id = 'Google.Chrome'; Version = '130.0.1'; Available = '131.0.2'; Source = 'winget' })) + @('2 upgrades available.', '', 'The following packages have an upgrade available, but require explicit targeting for upgrade:') + (Format-SimTable @(@{ Name = 'Parsec'; Id = 'Parsec.Parsec'; Version = '150-93'; Available = '150-97'; Source = 'winget' }))) -join "`r`n"
    $rows = @(ConvertFrom-WamTable $text)
    Assert-Equal $rows.Count 3 'three rows'
    Assert-Equal $rows[1].name 'Google Chrome' 'name with a space'
    Assert-Equal "$($rows[0].id) $($rows[0].version) $($rows[0].available) $($rows[0].source)" 'Git.Git 2.45.1 2.47.0 winget' 'columns'
    Assert-True (-not $rows[0].explicit) 'first table is ordinary'
    Assert-True $rows[2].explicit 'second table is explicit'
    $trunc = @(ConvertFrom-WamTable ((Format-SimTable @(@{ Name = 'Some Long Name'; Id = ('Vendor.Very' + [char]0x2026); Version = '1.0'; Available = '1.1'; Source = 'winget' })) -join "`n"))
    Assert-True $trunc[0].truncated 'ellipsis marks a shortened identifier'
    Assert-Equal @(ConvertFrom-WamTable 'No installed package found matching input criteria.').Count 0 'no table'
}

$tests['versions and eligibility: unknown, "<" and not-newer versions, shortened ids and explicit packages are never updated in bulk'] = {
    Assert-Equal (Compare-WamVersion '2.47.0' '2.45.1') 1 'newer'
    Assert-Equal (Compare-WamVersion '10.0' '9.9') 1 'numeric, not text'
    Assert-Equal (Compare-WamVersion '1.0' '1.0.0') 0 'trailing zeros'
    Assert-Equal (Compare-WamVersion '150-93' '150-97') -1 'dash versions'
    $pol = @{ 'slack.slack' = @{ upgrade = 'explicit' } }
    $row = { param($v, $a, [bool] $t = $false, [bool] $x = $false, [string] $id = 'Git.Git') @{ id = $id; version = $v; available = $a; truncated = $t; explicit = $x; source = 'winget' } }
    Assert-Equal (Get-WamEligibility (& $row '2.45.1' '2.47.0') $pol) '' 'eligible'
    Assert-True (Get-WamEligibility (& $row 'Unknown' '2.47.0') $pol) 'unknown version'
    Assert-True (Get-WamEligibility (& $row '< 2.0' '2.47.0') $pol) 'less-than version'
    Assert-True (Get-WamEligibility (& $row '2.47.0' '2.47.0') $pol) 'not newer'
    Assert-True (Get-WamEligibility (& $row '1.0' '2.0' $true) $pol) 'shortened id'
    Assert-True (Get-WamEligibility (& $row '1.0' '2.0' $false $true) $pol) 'explicit table'
    Assert-True (Get-WamEligibility (& $row '1.0' '2.0' $false $false 'Slack.Slack') $pol) 'explicit by catalog policy'
}

$tests['inventory: winget export plus Windows uninstall records; nothing changed'] = {
    $S = Reset-Sim -Installed @{ 'Git.Git' = '2.45.1'; 'VideoLAN.VLC' = '3.0.20' } -Programs @(@{ displayName = 'Contoso Tool'; displayVersion = '1.0'; publisher = 'Contoso'; scope = 'machine'; keyName = 'x' })
    Start-WamInventory $S
    Invoke-Pump $S
    Assert-Equal $S.Inventory.method 'winget export' 'method'
    Assert-Equal (@($S.Inventory.packages).Count) 2 'packages'
    Assert-Equal ((@($S.Inventory.packages) | Where-Object { $_.id -eq 'Git.Git' }).version) '2.45.1' 'version'
    Assert-Equal (@($S.Inventory.programs)[0].name) 'Contoso Tool' 'Windows programs too'
    Assert-True (Test-Path -LiteralPath $S.Paths.Inventory) 'cached for offline use'
    Assert-Equal (@($script:Sim.Calls | Where-Object { $_ -match '^(install|upgrade|uninstall) ' }).Count) 0 'read only'
    Assert-True (@($script:Sim.Calls)[0] -match '^export --output .+ --include-versions --disable-interactivity$') 'export command'
}

$tests['update check: source update, then a read-only list; explicit and unknown versions not eligible; cached'] = {
    $S = Reset-Sim -Installed @{ 'Git.Git' = '2.45.1'; 'Parsec.Parsec' = '150-93'; 'Contoso.Tool' = 'Unknown'; 'VideoLAN.VLC' = '3.0.21' } -Available @{ 'Git.Git' = '2.47.0'; 'Parsec.Parsec' = '150-97'; 'Contoso.Tool' = '2.0'; 'VideoLAN.VLC' = '3.0.21' } -Explicit @('Parsec.Parsec')
    $S.UpdateCheckId = 'check-1'
    Start-WamUpdateCheck $S
    Invoke-Pump $S
    Assert-Equal (@($script:Sim.Calls) -join ' | ') 'source update --disable-interactivity | upgrade --source winget --disable-interactivity' 'commands (no --all, no --include-unknown)'
    $items = @($S.Updates.items)
    Assert-Equal $S.Updates.status 'ok' 'status'
    Assert-Equal $items.Count 3 'three updates'
    $git = $items | Where-Object { $_.id -eq 'Git.Git' }
    Assert-True ($git.eligible -and $git.installed -eq '2.45.1' -and $git.available -eq '2.47.0') 'Git eligible with both versions'
    Assert-True (-not ($items | Where-Object { $_.id -eq 'Parsec.Parsec' }).eligible) 'Parsec only individually'
    Assert-True (-not ($items | Where-Object { $_.id -eq 'Contoso.Tool' }).eligible) 'unknown version not eligible'
    Assert-True (Test-Path -LiteralPath $S.Paths.Updates) 'cached'
    Assert-Equal (@($script:Sim.Calls | Where-Object { $_ -match '^(install|uninstall) |^upgrade --id' }).Count) 0 'nothing changed'
}

$tests['offline: update check reports the network, not missing packages; validation never says "removed"'] = {
    $S = Reset-Sim -Installed @{ 'Git.Git' = '2.45.1' } -Available @{ 'Git.Git' = '2.47.0' } -Online $false
    $S.UpdateCheckId = 'c'
    Start-WamUpdateCheck $S
    Start-WamValidation $S @((Item 'Git.Git'), (Item 'Not.There'))
    Invoke-Pump $S
    Assert-Equal $S.Updates.status 'networkUnavailable' 'network'
    Assert-True ($S.Updates.note -match 'No network') 'explained'
    Assert-Equal $S.Validation['winget:git.git'].status 'networkUnavailable' 'validation offline'
    Assert-Equal $S.Validation['winget:not.there'].status 'networkUnavailable' 'not "not found" while offline'
    Assert-True ($S.Validation['winget:git.git'].detail -notmatch 'removed') 'never claims removal'
}

$tests['validation: winget show per identifier; not found, agreements and invalid identifiers distinguished'] = {
    $S = Reset-Sim -Available @{ 'Git.Git' = '2.47.0'; 'Vendor.Eula' = '1.0' } -Behavior @{ 'Vendor.Eula' = 'agreement' }
    Start-WamValidation $S @((Item 'Git.Git'), (Item 'Not.There'), (Item 'Vendor.Eula'), (Item 'bad id'))
    Invoke-Pump $S
    Assert-Equal $S.Validation['winget:git.git'].status 'available' 'available'
    Assert-Equal $S.Validation['winget:git.git'].version '2.47.0' 'version'
    Assert-Equal $S.Validation['winget:not.there'].status 'notFound' 'not found'
    Assert-True $S.Validation['winget:vendor.eula'].agreements 'agreements shown'
    Assert-Equal $S.Validation['winget:bad id'].status 'invalid' 'invalid, never run'
    Assert-True (@($script:Sim.Calls) -contains 'show --id Git.Git --exact --source winget --disable-interactivity') 'show command'
    Assert-Equal (@($script:Sim.Calls | Where-Object { $_ -match 'bad id' }).Count) 0 'invalid id not passed to WinGet'
}

$tests['install queue: one at a time, verified afterwards, one failure keeps the others; history records every field'] = {
    $S = Reset-Sim -Available @{ 'Git.Git' = '2.47.0'; 'VideoLAN.VLC' = '3.0.21'; 'Bad.Download' = '1.0' } -Behavior @{ 'Bad.Download' = 'fail' }
    $r = Start-WamBatch $S 'install' @((Item 'Git.Git' @{ name = 'Git'; catalogId = 'git' }), (Item 'Bad.Download'), (Item 'VideoLAN.VLC' @{ scope = 'user' }))
    Assert-True $r.ok 'accepted'
    Assert-Equal @($r.commands)[2] 'winget install --id VideoLAN.VLC --exact --source winget --scope user --silent --no-upgrade --disable-interactivity' 'preview command (per-user scope kept)'
    Invoke-Pump $S
    $recs = @(Get-Records $S)
    Assert-Equal $recs.Count 3 'three records'
    $git = $recs | Where-Object { $_.packageId -eq 'Git.Git' }
    Assert-Equal "$($git.result) $($git.verification) $($git.resultVersion) $($git.exitCode)" 'Succeeded Verified 2.47.0 0x00000000' 'Git installed and verified'
    Assert-Equal "$($git.format) $($git.version) $($git.catalogId) $($git.requestedBy)" "$($script:WamFormat) 1 git PC\owner" 'versioned record'
    $bad = $recs | Where-Object { $_.packageId -eq 'Bad.Download' }
    Assert-Equal "$($bad.result) $($bad.exitCode) $($bad.failureClass) $($bad.retryable)" 'Failed 0x8A150008 Network True' 'failure captured, retryable'
    Assert-Equal ($recs | Where-Object { $_.packageId -eq 'VideoLAN.VLC' }).result 'Succeeded' 'VLC still installed after the failure'
    foreach ($k in 'startedUtc', 'finishedUtc', 'action', 'priorVersion', 'source', 'restartRequired', 'attempt', 'retryOf', 'command', 'manualAction') { Assert-True ($git.ContainsKey($k)) "record has $k" }
    $order = @($script:Sim.Calls | Where-Object { $_ -match '^install ' } | ForEach-Object { ($_ -split ' ')[2] })
    Assert-Equal ($order -join ',') 'Git.Git,Bad.Download,VideoLAN.VLC' 'in order, one at a time'
}

$tests['retry: a failed item can be queued again; attempt and the original operation are recorded'] = {
    $S = Reset-Sim -Available @{ 'Flaky.App' = '1.0' } -Behavior @{ 'Flaky.App' = 'fail' }
    [void] (Start-WamBatch $S 'install' @((Item 'Flaky.App')))
    Invoke-Pump $S
    $first = @(Get-Records $S)[0]
    $script:Sim.Behavior.Remove('Flaky.App')
    [void] (Start-WamBatch $S 'install' @((Item 'Flaky.App' @{ attempt = 2; retryOf = $first.operationId })))
    Invoke-Pump $S
    $second = @(Get-Records $S)[1]
    Assert-Equal "$($second.result) $($second.attempt) $($second.retryOf)" "Succeeded 2 $($first.operationId)" 'retry recorded'
}

$tests['installer outcomes: restart, cancellation, declined UAC, agreements, hash mismatch, "success" that did not install'] = {
    $S = Reset-Sim -Available @{ 'R.Boot' = '1'; 'C.Cancel' = '1'; 'U.Uac' = '1'; 'A.Eula' = '1'; 'H.Hash' = '1'; 'L.Lies' = '1' } -Behavior @{ 'R.Boot' = 'reboot'; 'C.Cancel' = 'cancel'; 'U.Uac' = 'uac'; 'A.Eula' = 'agreement'; 'H.Hash' = 'hash'; 'L.Lies' = 'lies' }
    [void] (Start-WamBatch $S 'install' @('R.Boot', 'C.Cancel', 'U.Uac', 'A.Eula', 'H.Hash', 'L.Lies' | ForEach-Object { Item $_ }))
    Invoke-Pump $S
    $r = @{}; foreach ($x in Get-Records $S) { $r[$x.packageId] = $x }
    Assert-True ($r['R.Boot'].result -eq 'RequiresRestart' -and $r['R.Boot'].restartRequired) 'restart'
    Assert-True ($r['C.Cancel'].result -eq 'ManualActionRequired' -and $r['C.Cancel'].manualAction) 'cancelled needs a person'
    Assert-True ($r['U.Uac'].result -eq 'Cancelled' -and $r['U.Uac'].manualAction -match 'UAC') 'declined UAC'
    Assert-True ($r['A.Eula'].result -eq 'AgreementRequired' -and $r['A.Eula'].manualAction -match 'licence') 'agreement never accepted for the user'
    Assert-True ($r['H.Hash'].result -eq 'Failed' -and $r['H.Hash'].failureClass -eq 'Integrity' -and -not $r['H.Hash'].retryable) 'hash mismatch never retried'
    Assert-Equal "$($r['L.Lies'].result) $($r['L.Lies'].verification)" 'Uncertain NotFound' 'independent verification'
    Assert-True (@($script:Sim.Calls | Where-Object { $_ -match 'accept-package-agreements' }).Count -eq 0) 'no agreement accepted without the user'
}

$tests['package agreements are passed only for a package the user accepted them for'] = {
    $S = Reset-Sim -Available @{ 'A.Eula' = '1'; 'B.Plain' = '1' } -Behavior @{ 'A.Eula' = 'agreement' }
    [void] (Start-WamBatch $S 'install' @((Item 'A.Eula' @{ acceptPackageAgreements = $true }), (Item 'B.Plain')))
    Invoke-Pump $S
    Assert-True (@($script:Sim.Calls) -contains 'install --id A.Eula --exact --source winget --silent --no-upgrade --accept-package-agreements --disable-interactivity') 'accepted for A'
    Assert-True (@($script:Sim.Calls) -contains 'install --id B.Plain --exact --source winget --silent --no-upgrade --disable-interactivity') 'not for B'
    Assert-Equal ((Get-Records $S | Where-Object { $_.packageId -eq 'A.Eula' }).result) 'Succeeded' 'installed after acceptance'
}

$tests['simulation mode: nothing is run, every command is recorded as Simulated'] = {
    $S = Reset-Sim -Available @{ 'Git.Git' = '2.47.0' } -Installed @{ 'VideoLAN.VLC' = '3.0.20' }
    $S.Settings.dryRun = $true
    $r = Start-WamBatch $S 'install' @((Item 'Git.Git'))
    Assert-True $r.dryRun 'batch marked'
    Invoke-Pump $S
    [void] (Start-WamBatch $S 'uninstall' @((Item 'VideoLAN.VLC')) 'REMOVE')
    Invoke-Pump $S
    Assert-Equal $script:Sim.Calls.Count 0 'no WinGet process at all'
    $recs = @(Get-Records $S)
    Assert-Equal (($recs | ForEach-Object { "$($_.result)/$($_.dryRun)" }) -join ',') 'Simulated/True,Simulated/True' 'simulated records'
    Assert-Equal $recs[0].command 'winget install --id Git.Git --exact --source winget --silent --no-upgrade --disable-interactivity' 'the command that would run'
    Assert-True $script:Sim.Installed.ContainsKey('VideoLAN.VLC') 'still installed'
}

$tests['simulation is the default for a new user; -DryRun cannot be switched off from the page'] = {
    $paths = Get-WamPaths (Join-Path $script:Temp ("fresh-" + [Guid]::NewGuid().ToString('N')))
    Initialize-WamStore $paths
    Assert-True (New-WamState $paths).Settings.dryRun 'default on'
    $S = New-WamState $paths $true
    $r = Call $S (Req 'POST' '/api/settings' @{} '{"dryRun":false}')
    Assert-True $r.Json.settings.dryRun 'forced simulation stays on'
}

$tests['upgrade selected: by identifier, recorded with the prior and resulting version'] = {
    $S = Reset-Sim -Installed @{ 'Git.Git' = '2.45.1' } -Available @{ 'Git.Git' = '2.47.0' }
    [void] (Start-WamBatch $S 'upgrade' @((Item 'Git.Git' @{ installedVersion = '2.45.1' })))
    Invoke-Pump $S
    $rec = @(Get-Records $S)[0]
    Assert-Equal "$($rec.action) $($rec.priorVersion) $($rec.resultVersion) $($rec.result)" 'upgrade 2.45.1 2.47.0 Succeeded' 'versions recorded'
    Assert-True (@($script:Sim.Calls) -contains 'upgrade --id Git.Git --exact --source winget --silent --disable-interactivity') 'command'
}

$tests['removal: confirmation word, protected packages refused, caution packages need their own confirmation, verified afterwards'] = {
    $S = Reset-Sim -Installed @{ 'VideoLAN.VLC' = '3.0.20'; 'Microsoft.VCRedist.2015+.x64' = '14.0'; 'PrivateInternetAccess.PrivateInternetAccess' = '3.6' }
    Assert-True (-not (Start-WamBatch $S 'uninstall' @((Item 'VideoLAN.VLC'))).ok) 'no confirmation word'
    $r = Start-WamBatch $S 'uninstall' @((Item 'VideoLAN.VLC'), (Item 'Microsoft.VCRedist.2015+.x64')) 'REMOVE'
    Assert-True (-not $r.ok -and $r.error -match 'cannot be removed') 'runtime refused, whole batch refused'
    foreach ($p in 'Microsoft.Edge', 'Microsoft.WindowsAppRuntime.1.8', 'Microsoft.DotNet.DesktopRuntime.8', 'Intel.IntelDriverAndSupportAssistant', 'Nvidia.GeForceExperience') { Assert-True (-not (Get-WamRemovalPolicy $p $S.Policy).allowed) "$p protected" }
    $r = Start-WamBatch $S 'uninstall' @((Item 'PrivateInternetAccess.PrivateInternetAccess')) 'REMOVE'
    Assert-True (-not $r.ok -and $r.error -match 'its own confirmation') 'VPN needs its own confirmation'
    Assert-Equal (Get-WamRemovalPolicy 'Unknown.Vendor' $S.Policy).level 'caution' 'unknown packages need care'
    Assert-Equal $script:Sim.Calls.Count 0 'nothing run while refused'
    [void] (Start-WamBatch $S 'uninstall' @((Item 'VideoLAN.VLC'), (Item 'PrivateInternetAccess.PrivateInternetAccess' @{ confirmCaution = $true })) 'REMOVE')
    Invoke-Pump $S
    $recs = @(Get-Records $S)
    Assert-Equal (($recs | ForEach-Object { "$($_.packageId)=$($_.result)/$($_.verification)" }) -join ',') 'VideoLAN.VLC=Succeeded/Verified,PrivateInternetAccess.PrivateInternetAccess=Succeeded/Verified' 'removed and verified'
    Assert-True (@($script:Sim.Calls | Where-Object { $_ -match 'purge' }).Count -eq 0) 'settings and data kept (no --purge)'
}

$tests['one batch at a time; cancel stops what has not started, never a running installer'] = {
    $S = Reset-Sim -Available @{ 'A.One' = '1'; 'B.Two' = '1'; 'C.Three' = '1' }
    [void] (Start-WamBatch $S 'install' @((Item 'A.One'), (Item 'B.Two'), (Item 'C.Three')))
    Step-WamQueue $S
    Assert-True (-not (Start-WamBatch $S 'install' @((Item 'A.One'))).ok) 'second batch refused'
    $r = Call $S (Req 'POST' '/api/cancel')
    Assert-Equal $r.Json.cancelled 2 'two not started'
    Invoke-Pump $S
    Assert-Equal (@($script:Sim.Calls | Where-Object { $_ -match '^install ' }).Count) 1 'only the running one finished'
    Assert-Equal ((Get-WamPublicState $S).batch.jobs | Where-Object { $_.state -eq 'Cancelled' } | Measure-Object).Count 2 'shown as cancelled'
}

$tests['history: passwords and tokens in installer output are redacted; output is bounded'] = {
    $S = Reset-Sim -Available @{ 'P.Pw' = '1' } -Behavior @{ 'P.Pw' = 'password' }
    [void] (Start-WamBatch $S 'install' @((Item 'P.Pw')))
    Invoke-Pump $S
    $raw = [IO.File]::ReadAllText($S.Paths.History)
    Assert-True ($raw -notmatch 'hunter2|abc123') 'secrets not stored'
    Assert-True ($raw -match '\[redacted\]') 'redacted'
    Assert-True ((Protect-WamText ('x' * 5000)).Length -le 2000) 'bounded'
}

$tests['reports: CSV, HTML (encoded) and JSON from the history; available offline'] = {
    $S = Reset-Sim -Available @{ 'Git.Git' = '2.47.0' }
    [void] (Start-WamBatch $S 'install' @((Item 'Git.Git' @{ name = '<b>Git</b>' })))
    Invoke-Pump $S
    $script:Sim.Online = $false
    $csv = Call $S (Req 'GET' '/api/report' -Query @{ format = 'csv' })
    Assert-True ($csv.Res.Body -match '^finishedUtc,action,name,packageId') 'CSV header'
    Assert-True ($csv.Res.Body -match 'Git\.Git') 'CSV row'
    $html = Call $S (Req 'GET' '/api/report' -Query @{ format = 'html' })
    Assert-True ($html.Res.Body -match '&lt;b&gt;Git&lt;/b&gt;' -and $html.Res.Body -notmatch '<b>Git</b>') 'HTML encoded'
    $json = Call $S (Req 'GET' '/api/report')
    Assert-Equal $json.Json.format 'windows-deployment-builder/app-manager-history' 'JSON format'
    Assert-Equal @($json.Json.records).Count 1 'one record'
    Assert-True ($html.Res.Headers['Content-Disposition'] -match 'attachment') 'downloaded'
}

$tests['HTTP: host, origin, cross-site and token checks; static files only from the ui folder'] = {
    $S = Reset-Sim
    Assert-Equal (Call $S (Req -Headers @{ host = 'evil.example:5555' })).Status 421 'DNS rebinding refused'
    Assert-Equal (Call $S (Req -Headers @{ origin = 'https://evil.example' })).Status 403 'other origin refused'
    Assert-Equal (Call $S (Req -Headers @{ 'sec-fetch-site' = 'cross-site' })).Status 403 'cross-site refused'
    Assert-Equal (Call $S (Req -Headers @{ 'x-wdb-token' = 'wrong' })).Status 401 'wrong token'
    Assert-Equal (Call $S (Req -Headers @{ 'x-wdb-token' = '' })).Status 401 'no token'
    Assert-Equal (Call $S (Req -Headers @{ origin = 'http://127.0.0.1:5555' })).Status 200 'same origin with token'
    Assert-Equal (Call $S (Req 'POST' '/api/operations' @{} '{not json')).Status 400 'bad JSON'
    $page = Invoke-WamRequest $S (Req 'GET' '/' @{ 'x-wdb-token' = '' }) 'tok' 5555
    Assert-True ($page.Status -eq 200 -and $page.Type -match 'text/html') 'page served without a token'
    Assert-Equal (Invoke-WamRequest $S (Req 'GET' '/assets/manager.js') 'tok' 5555).Type 'text/javascript; charset=utf-8' 'script type'
    foreach ($p in '/../secret.txt', '/assets/../../secret.txt', '/assets/..%5c..%5csecret.txt', '/C:/Windows/win.ini', '/ui/manager.html', '/assets/') { Assert-Equal (Invoke-WamRequest $S (Req 'GET' $p) 'tok' 5555).Status 404 "not served: $p" }
    Assert-Equal (Invoke-WamRequest $S (Req 'POST' '/manager.html') 'tok' 5555).Status 405 'static is GET only'
    Assert-Equal (Call $S (Req 'GET' '/api/nope')).Status 404 'unknown API'
}

$tests['HTTP: operations are validated by the agent; the page cannot pass flags or commands'] = {
    $S = Reset-Sim -Available @{ 'Git.Git' = '1' }
    $r = Call $S (Req 'POST' '/api/operations' @{} '{"action":"install","items":[{"id":"Git.Git --force","source":"winget","scope":"","version":""}]}')
    Assert-True ($r.Status -eq 400 -and $r.Json.error -match 'invalid WinGet identifier') 'flag in identifier refused'
    $r = Call $S (Req 'POST' '/api/operations' @{} '{"action":"exec","items":[{"id":"Git.Git","source":"winget"}]}')
    Assert-Equal $r.Status 400 'unknown action refused'
    $r = Call $S (Req 'POST' '/api/operations' @{} '{"action":"install","items":[]}')
    Assert-Equal $r.Status 400 'empty batch refused'
    $r = Call $S (Req 'POST' '/api/operations' @{} '{"action":"install","items":[{"id":"Git.Git","source":"winget","scope":"","version":"","args":"--force","command":"calc.exe"}]}')
    Assert-Equal $r.Status 202 'extra members ignored'
    Invoke-Pump $S
    Assert-Equal (@($script:Sim.Calls) -join '|') 'install --id Git.Git --exact --source winget --silent --no-upgrade --disable-interactivity|list --id Git.Git --exact --source winget --disable-interactivity' 'only the fixed arguments'
}

$tests['state and profiles API: saved profiles survive a restart of the agent; state shows identity and simulation'] = {
    $S = Reset-Sim
    $body = '{"format":"windows-deployment-builder/app-manager-selection","version":1,"selection":{"selectedProfiles":["core","gaming"]}}'
    Assert-Equal (Call $S (Req 'PUT' '/api/profiles' @{} $body)).Status 200 'saved'
    $again = New-WamState $S.Paths
    $r = Call $again (Req 'GET' '/api/profiles')
    Assert-Equal (@($r.Json.profiles.selection.selectedProfiles) -join ',') 'core,gaming' 'read back'
    $st = (Call $S (Req)).Json
    Assert-Equal "$($st.agent.user) $($st.agent.elevated)" 'PC\owner False' 'runs as the user, not elevated'
    Assert-True ($st.settings.ContainsKey('dryRun')) 'simulation flag'
}

$tests['the agent refuses to run as SYSTEM'] = {
    $text = [IO.File]::ReadAllText($agentPath)
    Assert-True ($text -match "if \(\`$id\.IsSystem\) \{ Write-Output 'The Application Manager runs as a signed-in user, not as SYSTEM\.'; exit 2 \}") 'SYSTEM guard'
    Assert-True ($text -notmatch 'Start-Process[^\n]*-Verb RunAs') 'never elevates itself'
    Assert-True ($text -match '\[Net\.IPAddress\]::Loopback') 'loopback only'
}

$tests['real listener on 127.0.0.1: page and state served; wrong token refused; stops on request (no WinGet command)'] = {
    $data = Join-Path $script:Temp 'live'
    $job = Start-Job -ScriptBlock { param($p, $d) & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p -DryRun -NoBrowser -IdleMinutes 2 -DataRoot $d } -ArgumentList (Join-Path $script:WamRoot 'AppManager.ps1'), $data
    try {
        $url = $null
        for ($i = 0; $i -lt 150 -and -not $url; $i++) { Start-Sleep -Milliseconds 200; foreach ($l in @(Receive-Job $job -Keep)) { if ("$l" -match '^Open: (http://127\.0\.0\.1:\d+/manager\.html)#([0-9a-f]{64})$') { $url = $Matches[1]; $tok = $Matches[2] } } }
        Assert-True $url "agent started: $(@(Receive-Job $job -Keep) -join ' / ')"
        $base = $url -replace '/manager\.html$', ''
        $page = Invoke-WebRequest -UseBasicParsing -Uri $url
        Assert-True ($page.Content -match 'Application Manager') 'page'
        Assert-True ($page.Headers['Content-Security-Policy'] -match "default-src 'self'") 'CSP header'
        $st = Invoke-RestMethod -Uri "$base/api/state" -Headers @{ 'X-WDB-Token' = $tok }
        Assert-True $st.settings.dryRun 'simulation'
        Assert-True $st.settings.forcedDryRun 'forced by -DryRun'
        $code = 0
        try { Invoke-WebRequest -UseBasicParsing -Uri "$base/api/state" -Headers @{ 'X-WDB-Token' = ('0' * 64) } | Out-Null } catch { $code = [int] $_.Exception.Response.StatusCode }
        Assert-Equal $code 401 'wrong token'
        Invoke-RestMethod -Method Post -Uri "$base/api/shutdown" -Headers @{ 'X-WDB-Token' = $tok } | Out-Null
        Assert-True (Wait-Job $job -Timeout 20) 'stopped'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $data 'history.jsonl'))) 'no operation'
    } finally { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue }
}

$tests['launcher: installs for this user only after every file matches files.json; shortcut named for the Start menu; uninstall keeps the data'] = {
    $pkg = Join-Path $script:Temp 'pkg'
    New-Item -ItemType Directory -Path (Join-Path $pkg 'lib') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $src 'manager\scripts\Install-AppManager.ps1'), $agentPath -Destination $pkg
    [IO.File]::WriteAllText((Join-Path $pkg 'lib\x.ps1'), '# lib')
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = { param($p) -join ($sha.ComputeHash([IO.File]::ReadAllBytes($p)) | ForEach-Object { $_.ToString('x2') }) }
    $files = @('AppManager.ps1', 'Install-AppManager.ps1', 'lib/x.ps1') | ForEach-Object { @{ path = $_; sha256 = (& $hash (Join-Path $pkg $_)) } }
    $writeList = { param($list) [IO.File]::WriteAllText((Join-Path $pkg 'files.json'), (@{ files = @($list) } | ConvertTo-Json -Depth 4)) }
    & $writeList $files
    $dest = Join-Path $script:Temp 'installed'
    $links = Join-Path $script:Temp 'links'
    $run = { param([string[]] $More) $ErrorActionPreference = 'Continue'; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pkg 'Install-AppManager.ps1') -Destination $dest -ShortcutFolder $links @More 2>&1; $LASTEXITCODE }
    $out = & $run @()
    Assert-Equal $out[-1] 0 "installed: $($out -join ' / ')"
    Assert-True (Test-Path -LiteralPath (Join-Path $dest 'lib\x.ps1')) 'copied'
    $lnk = Join-Path $links ('Windows Deployment ' + [char]0x2014 + ' Application Manager.lnk')
    Assert-True (Test-Path -LiteralPath $lnk) 'Start menu shortcut'
    $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    Assert-True ($sc.Arguments -match '-File ".+\\installed\\AppManager\.ps1"' -and $sc.Arguments -notmatch 'RunAs') 'runs the installed agent, not elevated'
    # A changed file is refused before anything is copied.
    [IO.File]::AppendAllText((Join-Path $pkg 'lib\x.ps1'), 'tampered')
    Remove-Item -LiteralPath $dest -Recurse -Force
    $out = & $run @()
    Assert-True ($out[-1] -ne 0 -and ($out -join ' ') -match 'changed or damaged') 'tampered package refused'
    Assert-True (-not (Test-Path -LiteralPath $dest)) 'nothing copied'
    # A path that leaves the package is refused.
    & $writeList (@(@{ path = '../secret.txt'; sha256 = '00' }) + @($files))
    $out = & $run @()
    Assert-True (($out -join ' ') -match 'Unsafe path') 'traversal refused'
    # Uninstall removes the program and shortcut; the history stays.
    & $writeList @($files | Where-Object { $_.path -ne 'lib/x.ps1' })
    $out = & $run @()
    Assert-Equal $out[-1] 0 'reinstalled'
    $out = & $run @('-Uninstall')
    Assert-True ($out[-1] -eq 0 -and -not (Test-Path -LiteralPath $dest) -and -not (Test-Path -LiteralPath $lnk)) 'uninstalled'
    Assert-True (($out -join ' ') -match 'history, profiles and settings are kept') 'data kept'
}

# The live scenario runs the agent from the test folder with its libraries next to it, as packaged.
New-Item -ItemType Directory -Path (Join-Path $script:WamRoot 'lib') -Force | Out-Null
Copy-Item -LiteralPath $agentPath -Destination $script:WamRoot
Copy-Item -LiteralPath (Join-Path $src 'deployment\scripts\DeploymentCommon.ps1'), (Join-Path $src 'applications\scripts\ApplicationEngine.ps1'), (Join-Path $src 'health\scripts\DeploymentHealth.ps1') -Destination (Join-Path $script:WamRoot 'lib')

foreach ($name in $tests.Keys) {
    try {
        & $tests[$name]
        $script:Passed++
        Write-Output "  ok    $name"
    } catch {
        $script:Failures++
        Write-Output "  FAIL  $name`n        $($_.Exception.Message)`n        $($_.InvocationInfo.PositionMessage -replace "`n", "`n        ")"
    }
}

if ($Out) {
    if (-not (Test-Path -LiteralPath $Out)) { New-Item -ItemType Directory -Path $Out -Force | Out-Null }
    $cases = @()
    foreach ($c in @(@('install', 'Git.Git', 'winget', '', '', $false, $false), @('install', 'Git.Git', 'winget', 'user', '2.47.0', $true, $true), @('install', '9NKSQGP7F2NH', 'msstore', 'machine', '', $false, $true), @('upgrade', 'Git.Git', 'winget', 'machine', '2.0', $true, $false), @('uninstall', 'Git.Git', 'winget', 'user', '', $true, $true), @('show', 'Git.Git', 'winget', '', '', $false, $true), @('list', 'Git.Git', 'winget', '', '', $false, $false))) {
        $cases += , @{ action = $c[0]; id = $c[1]; source = $c[2]; scope = $c[3]; version = $c[4]; acceptPackageAgreements = $c[5]; acceptSourceAgreements = $c[6]; args = (Get-WamArguments $c[0] $c[1] $c[2] $c[3] $c[4] -AcceptPackageAgreements:$c[5] -AcceptSourceAgreements:$c[6]) }
    }
    [IO.File]::WriteAllText((Join-Path $Out 'args.json'), (ConvertTo-Json @($cases) -Depth 4), (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $Out 'protected.json'), (ConvertTo-Json @($script:WamProtected)), (New-Object Text.UTF8Encoding($false)))
}

Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "$($script:Passed) passed, $($script:Failures) failed"
if ($script:Failures -gt 0) { exit 1 }
exit 0
