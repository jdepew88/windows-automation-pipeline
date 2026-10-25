#Requires -Version 5.1
<#
    A stand-in for winget.exe for the end-to-end test of the packaged Application Manager
    (tests/e2e/manager-agent.spec.ts). It never installs anything: "installed" packages are entries
    in the JSON file named by $env:WDB_FAKE_WINGET_STATE:

      { "installed": { "<id>": "<version>" }, "available": { "<id>": "<version>" }, "calls": [] }

    Output follows WinGet's layout (a header, a line of dashes, aligned columns) and its exit codes.
#>
$ErrorActionPreference = 'Stop'
$statePath = $env:WDB_FAKE_WINGET_STATE
if (-not $statePath -or -not (Test-Path -LiteralPath $statePath)) { Write-Output 'fake winget: no state file'; exit 1 }
$st = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
$installed = @{}; foreach ($p in $st.installed.PSObject.Properties) { $installed[$p.Name] = [string] $p.Value }
$available = @{}; foreach ($p in $st.available.PSObject.Properties) { $available[$p.Name] = [string] $p.Value }
$calls = @($st.calls) + @($args -join ' ')
$save = { [IO.File]::WriteAllText($statePath, (@{ installed = $installed; available = $available; calls = $calls } | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false))) }
$table = {
    param($rows, [switch] $NoAvailable)
    $cols = $(if ($NoAvailable) { 'Name', 'Id', 'Version', 'Source' } else { 'Name', 'Id', 'Version', 'Available', 'Source' })
    $w = @{}; foreach ($c in $cols) { $w[$c] = [Math]::Max($c.Length, (@($rows | ForEach-Object { ([string] $_[$c]).Length }) + 0 | Measure-Object -Maximum).Maximum) }
    $line = { param($r) (@($cols | ForEach-Object { ([string] $r[$_]).PadRight($w[$_]) }) -join ' ').TrimEnd() }
    $head = & $line @{ Name = 'Name'; Id = 'Id'; Version = 'Version'; Available = 'Available'; Source = 'Source' }
    @($head, ('-' * $head.Length)) + @($rows | ForEach-Object { & $line $_ })
}
$id = $(if ($args.Count -gt 2 -and $args[1] -eq '--id') { [string] $args[2] } else { '' })
$code = 0
switch ([string] $args[0]) {
    'export' {
        $doc = @{ '$schema' = 'https://aka.ms/winget-packages.schema.2.0.json'; Sources = @(@{ SourceDetails = @{ Name = 'winget'; Identifier = 'Microsoft.Winget.Source_8wekyb3d8bbwe'; Argument = 'https://cdn.winget.microsoft.com/cache'; Type = 'Microsoft.PreIndexed.Package' }; Packages = @($installed.Keys | Sort-Object | ForEach-Object { @{ PackageIdentifier = $_; Version = $installed[$_] } }) }) }
        [IO.File]::WriteAllText([string] $args[2], ($doc | ConvertTo-Json -Depth 6))
        Write-Output 'Installed package list exported.'
    }
    'source' { Write-Output 'Updating all sources...'; Write-Output 'Done' }
    'show' { if ($available.ContainsKey($id)) { Write-Output "Found $id [$id]"; Write-Output "Version: $($available[$id])" } else { Write-Output 'No package found matching input criteria.'; $code = -1978335212 } }
    'list' { if ($installed.ContainsKey($id)) { & $table @(@{ Name = $id; Id = $id; Version = $installed[$id]; Source = 'winget' }) -NoAvailable } else { Write-Output 'No installed package found matching input criteria.'; $code = -1978335212 } }
    'upgrade' {
        if (-not $id) {
            $rows = @($installed.Keys | Sort-Object | Where-Object { $available.ContainsKey($_) -and $available[$_] -ne $installed[$_] } | ForEach-Object { @{ Name = $_.Split('.')[-1]; Id = $_; Version = $installed[$_]; Available = $available[$_]; Source = 'winget' } })
            if ($rows.Count) { & $table $rows; Write-Output "$($rows.Count) upgrades available." } else { Write-Output 'No installed package found matching input criteria.' }
        } elseif ($installed.ContainsKey($id) -and $available.ContainsKey($id)) { $installed[$id] = $available[$id]; Write-Output 'Successfully installed' }
        else { Write-Output 'No applicable upgrade found.'; $code = -1978335189 }
    }
    'install' { if ($available.ContainsKey($id)) { $installed[$id] = $available[$id]; Write-Output 'Successfully verified installer hash'; Write-Output 'Successfully installed' } else { Write-Output 'No package found matching input criteria.'; $code = -1978335212 } }
    'uninstall' { if ($installed.ContainsKey($id)) { [void] $installed.Remove($id); Write-Output 'Successfully uninstalled' } else { $code = -1978335212 } }
    default { Write-Output "fake winget: unsupported command $($args -join ' ')"; $code = 1 }
}
& $save
exit $code
