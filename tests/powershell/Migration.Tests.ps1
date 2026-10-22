#Requires -Version 5.1
<#
    Scenario tests for WdbMigration.ps1 (Phase 6: inventory, settings backup, validation, restore)
    against a simulated computer: WinGet, uninstall records, Store packages, registry, processes and
    the VS Code command line are replaced, and every user folder points into a temporary directory
    filled with synthetic files. No real inventory is taken, nothing of the real user profile is
    read or written, nothing is installed.

    Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\powershell\Migration.Tests.ps1 [-Out <dir>]
    -Out copies a synthetic inventory and backup manifest there (validated by Vitest against the
    TypeScript import).
#>
param([string] $Out = '')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\src\engine\migration\scripts\WdbMigration.ps1') -Mode Library
Set-StrictMode -Version 2.0
# The real process runner (the scenarios use a simulation) is kept to test its argument check.
${function:Invoke-WdbProcessReal} = ${function:Invoke-WdbProcess}

$script:Failures = 0
$script:Passed = 0

function Assert-Equal($Actual, $Expected, [string] $Message) { if ("$Actual" -ne "$Expected") { throw "ASSERT: $Message. Expected <$Expected>, got <$Actual>." } }
function Assert-True($Value, [string] $Message) { if (-not $Value) { throw "ASSERT: $Message" } }
function Assert-Throws([scriptblock] $Block, [string] $Pattern, [string] $Message) {
    try { & $Block } catch { if ($_.Exception.Message -notmatch $Pattern) { throw "ASSERT: $Message. Wrong error: $($_.Exception.Message)" }; return }
    throw "ASSERT: $Message (no error)"
}

# ------------------------------------------------------------------------------------------------
# Simulated computer
# ------------------------------------------------------------------------------------------------

function Reset-Sim {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("wdb-test-" + [Guid]::NewGuid().ToString('N'))
    $u = Join-Path $root 'Users\Alex'
    $script:Sim = @{
        Root = $root
        Env = @{ USERPROFILE = $u; APPDATA = "$u\AppData\Roaming"; LOCALAPPDATA = "$u\AppData\Local"; DOCUMENTS = "$u\Documents"; PROGRAMFILES = "$root\Program Files"
                 PROGRAMFILESX86 = "$root\Program Files (x86)"; PROGRAMDATA = "$root\ProgramData"; USERNAME = 'Alex' }
        Os = @{ osName = 'Microsoft Windows 11 Pro'; osVersion = '10.0.26100'; osBuild = '26100'; displayVersion = '24H2'; architecture = 'x64' }
        WinGet = @{ Method = 'Microsoft.WinGet.Client'; Packages = @(); Message = '' }
        Uninstall = @(); Appx = @(); Python = @(); Running = @(); Registry = @{}; Cli = @{ Installed = @(); Calls = @(); Fail = @() }
        Now = [DateTime]::new(2026, 10, 22, 9, 0, 0, [DateTimeKind]::Utc)
    }
    foreach ($k in 'APPDATA', 'LOCALAPPDATA', 'DOCUMENTS', 'PROGRAMFILES') { New-Item -ItemType Directory -Path $script:Sim.Env[$k] -Force | Out-Null }
}

function Get-WdbNow { $script:Sim.Now }
function Get-WdbEnvironment { $script:Sim.Env }
function Get-WdbOsInfo { $script:Sim.Os }
function Get-WdbWinGetPackages { $script:Sim.WinGet }
function Get-WdbUninstallEntries { $script:Sim.Uninstall }
function Get-WdbAppxPackages { $script:Sim.Appx }
function Get-WdbPythonRegistrations { $script:Sim.Python }
function Test-WdbProcessRunning { param([string] $Name) $Name -in $script:Sim.Running }
function Invoke-WdbProcess {
    param([string] $FilePath, [string[]] $Arguments, [int] $TimeoutSeconds = 300)
    $script:Sim.Cli.Calls += , @($Arguments)
    if ($Arguments[0] -eq '--list-extensions') { return @{ ExitCode = 0; Output = ($script:Sim.Cli.Installed -join "`n") } }
    if ($Arguments[1] -in $script:Sim.Cli.Fail) { return @{ ExitCode = 1; Output = '' } }
    $script:Sim.Cli.Installed += $Arguments[1]
    @{ ExitCode = 0; Output = '' }
}
function Test-WdbRegistryKey { param([string] $Path) $script:Sim.Registry.ContainsKey($Path) -or @($script:Sim.Registry.Keys | Where-Object { $_.StartsWith("$Path\") }).Count -gt 0 }
function Get-WdbRegistryValues { param([string] $Path) $o = [ordered]@{}; if ($script:Sim.Registry.ContainsKey($Path)) { foreach ($k in $script:Sim.Registry[$Path].Keys) { $o[$k] = @{ type = $script:Sim.Registry[$Path][$k].type; data = $script:Sim.Registry[$Path][$k].data } } }; $o }
function Get-WdbRegistrySubKeys { param([string] $Path) @($script:Sim.Registry.Keys | Where-Object { $_.StartsWith("$Path\") } | ForEach-Object { $_.Substring($Path.Length + 1) } | Where-Object { $_ -notmatch '\\' } | Sort-Object) }
function Set-WdbRegistryValue { param([string] $Path, [string] $Name, [string] $Type, $Data) if (-not $script:Sim.Registry.ContainsKey($Path)) { $script:Sim.Registry[$Path] = [ordered]@{} }; $script:Sim.Registry[$Path][$Name] = @{ type = $Type; data = $Data } }

function New-SimFile { param([string] $Base, [string] $Rel, [string] $Text) $p = Join-Path $script:Sim.Env[$Base] $Rel; New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force | Out-Null; [IO.File]::WriteAllText($p, $Text, (New-Object System.Text.UTF8Encoding($false))); $p }
function Get-SimText { param([string] $Base, [string] $Rel) [IO.File]::ReadAllText((Join-Path $script:Sim.Env[$Base] $Rel)) }
function New-Uninstall { param([string] $Hive, [string] $View, [string] $Key, [hashtable] $Values) @{ Hive = $Hive; View = $View; KeyName = $Key; Values = $Values } }
function New-Appx { param([string] $Name, [string] $Family, [string] $Full, [bool] $Framework = $false, [string] $Sig = 'Store', [string] $Publisher = 'CN=Contoso') @{ Name = $Name; Publisher = $Publisher; Version = '1.0.0.0'; Architecture = 'X64'; PackageFullName = $Full; PackageFamilyName = $Family; IsFramework = $Framework; IsResourcePackage = $false; NonRemovable = $false; SignatureKind = $Sig } }

<# A typical developer workstation: registry, WinGet and Store records that overlap. #>
function Set-SimWorkstation {
    $script:Sim.Uninstall = @(
        (New-Uninstall 'HKLM' '64' 'Git_is1' @{ DisplayName = 'Git'; DisplayVersion = '2.51.0'; Publisher = 'The Git Development Community'; InstallLocation = "$($script:Sim.Env.PROGRAMFILES)\Git\" }),
        (New-Uninstall 'HKCU' '64' '{771FD6B0-FA20-440A-A002-3B3BAC16DC50}_is1' @{ DisplayName = 'Microsoft Visual Studio Code (User)'; DisplayVersion = '1.105.0'; Publisher = 'Microsoft Corporation'; InstallLocation = "$($script:Sim.Env.LOCALAPPDATA)\Programs\Microsoft VS Code\" }),
        (New-Uninstall 'HKLM' '32' 'PuTTY_x86' @{ DisplayName = 'PuTTY release 0.83'; DisplayVersion = '0.83.0.0'; Publisher = 'Simon Tatham' }),
        (New-Uninstall 'HKLM' '64' 'ContosoTool' @{ DisplayName = 'Contoso Field Tool'; DisplayVersion = '4.2'; Publisher = 'Contoso Ltd.' }),
        (New-Uninstall 'HKLM' '64' 'KB5050001' @{ DisplayName = 'Security Update for Windows (KB5050001)'; ReleaseType = 'Security Update' }),
        (New-Uninstall 'HKLM' '64' 'HiddenComp' @{ DisplayName = 'Hidden Component'; SystemComponent = 1 }),
        (New-Uninstall 'HKLM' '64' 'ChildPatch' @{ DisplayName = 'Patch for Something'; ParentKeyName = 'Something' }),
        (New-Uninstall 'HKLM' '64' 'NoName' @{ DisplayVersion = '1.0' }),
        (New-Uninstall 'HKLM' '64' 'NvGfx' @{ DisplayName = 'NVIDIA Graphics Driver 581.57'; DisplayVersion = '581.57'; Publisher = 'NVIDIA Corporation' }),
        (New-Uninstall 'HKLM' '64' '{VCRT}' @{ DisplayName = 'Microsoft Visual C++ 2015-2022 Redistributable (x64) - 14.44.35211'; DisplayVersion = '14.44.35211.0'; Publisher = 'Microsoft Corporation' }),
        (New-Uninstall 'HKLM' '64' 'Node' @{ DisplayName = 'Node.js'; DisplayVersion = '22.20.0'; Publisher = 'Node.js Foundation' })
    )
    $script:Sim.Appx = @(
        (New-Appx '5319275A.WhatsAppDesktop' '5319275A.WhatsAppDesktop_cv1g1gvanyjgm' '5319275A.WhatsAppDesktop_2.2540.6.0_x64__cv1g1gvanyjgm' -Publisher 'CN=24803D75-212C-471A-BC57-9EF86AB91435'),
        (New-Appx 'Microsoft.VCLibs.140.00' 'Microsoft.VCLibs.140.00_8wekyb3d8bbwe' 'Microsoft.VCLibs.140.00_14.0.33519.0_x64__8wekyb3d8bbwe' -Framework $true),
        (New-Appx 'Microsoft.WindowsCalculator' 'Microsoft.WindowsCalculator_8wekyb3d8bbwe' 'Microsoft.WindowsCalculator_11.2502.2.0_x64__8wekyb3d8bbwe' -Publisher 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'),
        (New-Appx 'Contoso.Notes' 'Contoso.Notes_abc123' 'Contoso.Notes_1.0.0.0_x64__abc123')
    )
    $script:Sim.WinGet = @{ Method = 'Microsoft.WinGet.Client'; Message = ''; Packages = @(
        @{ Name = 'Git'; Id = 'Git.Git'; Version = '2.51.0'; Source = 'winget' },
        @{ Name = 'Microsoft Visual Studio Code (User)'; Id = 'Microsoft.VisualStudioCode'; Version = '1.105.0'; Source = 'winget' },
        @{ Name = 'PuTTY release 0.83'; Id = 'ARP\Machine\X86\PuTTY_x86'; Version = '0.83.0.0'; Source = '' },
        @{ Name = 'WhatsApp'; Id = '9NKSQGP7F2NH'; Version = 'Unknown'; Source = 'msstore' },
        @{ Name = 'Contoso.Notes'; Id = 'MSIX\Contoso.Notes_1.0.0.0_x64__abc123'; Version = '1.0.0.0'; Source = '' },
        @{ Name = 'Windows Terminal'; Id = 'Microsoft.WindowsTerminal'; Version = '1.23.0'; Source = 'winget' }
    ) }
}

function Get-App { param($Inv, [string] $Pattern) @($Inv.applications | Where-Object { $_.displayName -match $Pattern }) }

# ------------------------------------------------------------------------------------------------
# Scenarios
# ------------------------------------------------------------------------------------------------

$tests = [ordered]@{}

$tests['inventory: WinGet, uninstall records and Store packages are merged without duplicates'] = {
    Reset-Sim; Set-SimWorkstation
    $inv = New-WdbInventory
    Assert-Equal $inv.format 'windows-deployment-builder/app-inventory' 'format'
    $git = @(Get-App $inv '^Git$')
    Assert-Equal $git.Count 1 'Git appears once (registry + WinGet merged)'
    Assert-Equal $git[0].packageIdentifier 'Git.Git' 'exact WinGet id kept'
    Assert-Equal $git[0].packageSource 'winget' 'source'
    Assert-Equal (($git[0].detection | Sort-Object) -join ',') 'registry,winget' 'both detections'
    Assert-Equal $git[0].scope 'machine' 'HKLM = machine'
    Assert-Equal $git[0].architecture 'x64' '64-bit view on x64'
    Assert-Equal $git[0].installLocation '%PROGRAMFILES%\Git\' 'install location tokenised'
    $code = @(Get-App $inv 'Visual Studio Code')
    Assert-Equal $code.Count 1 'VS Code once'
    Assert-Equal $code[0].scope 'user' 'HKCU = user'
    Assert-Equal $code[0].installLocation '%LOCALAPPDATA%\Programs\Microsoft VS Code\' 'no user name in the path'
    $putty = @(Get-App $inv 'PuTTY')
    Assert-Equal $putty.Count 1 'ARP pseudo id merged into the uninstall record'
    Assert-Equal $putty[0].architecture 'x86' '32-bit view'
    Assert-Equal $putty[0].packageIdentifier '' 'ARP id is not a package id'
    Assert-True ('winget' -in $putty[0].detection) 'seen by WinGet'
    $wa = @(Get-App $inv 'WhatsApp')
    Assert-Equal $wa.Count 1 'Store app merged with its MSIX package'
    Assert-Equal $wa[0].packageIdentifier '9NKSQGP7F2NH' 'Store product id'
    Assert-Equal $wa[0].storeIdentity '5319275A.WhatsAppDesktop_cv1g1gvanyjgm' 'package family kept'
    $notes = @(Get-App $inv '^Contoso\.Notes$')
    Assert-Equal $notes.Count 1 'MSIX pseudo id merged'
    Assert-Equal $notes[0].packageIdentifier '' 'no install mapping for a sideloaded package'
    Assert-Equal @(Get-App $inv 'VCLibs').Count 0 'framework packages left out'
    Assert-Equal @(Get-App $inv 'Calculator')[0].kind 'system' 'inbox Microsoft package is a system component'
    Assert-Equal @(Get-App $inv 'KB5050001|Hidden Component|Patch for').Count 0 'updates, system components and child entries left out'
    Assert-Equal $inv.excludedCounts.updates 2 'update and child entry counted'
    Assert-Equal $inv.excludedCounts.systemComponents 1 'system component counted'
    Assert-Equal $inv.excludedCounts.withoutName 1 'entry without a name counted'
    Assert-Equal $inv.excludedCounts.frameworks 1 'framework counted'
    $nv = @(Get-App $inv 'NVIDIA')[0]
    Assert-True $nv.hardware 'graphics driver flagged as hardware-specific'
    Assert-Equal $nv.kind 'driver' 'driver kind'
    Assert-Equal @(Get-App $inv 'Visual C\+\+')[0].kind 'runtime' 'runtime kind'
    Assert-Equal @(Get-App $inv 'Windows Terminal').Count 1 'WinGet-only package listed'
}

$tests['inventory: identifiers are stable across runs and the file contains no user name'] = {
    Reset-Sim; Set-SimWorkstation
    $a = New-WdbInventory
    $b = New-WdbInventory
    Assert-Equal (($a.applications | ForEach-Object { $_.inventoryId }) -join ',') (($b.applications | ForEach-Object { $_.inventoryId }) -join ',') 'same ids'
    Assert-Equal @($a.applications | Where-Object { $_.inventoryId -notmatch '^app-[0-9a-f]{12}$' }).Count 0 'id format'
    Assert-Equal @($a.applications.inventoryId | Select-Object -Unique).Count @($a.applications).Count 'ids unique'
    $text = ConvertTo-WdbJson $a
    Assert-True ($text -notmatch 'Alex') 'no user name anywhere in the inventory'
    Assert-True ($text -notmatch [regex]::Escape($script:Sim.Root)) 'no private path'
    Assert-True ($text -notmatch '(?i)uninstallstring|password') 'no uninstall commands or passwords'
}

$tests['inventory: winget export fallback lists identifiers without names and warns'] = {
    Reset-Sim
    $doc = ConvertTo-WdbHashtable ('{"Sources":[{"SourceDetails":{"Name":"winget"},"Packages":[{"PackageIdentifier":"Git.Git","Version":"2.51.0"}]},{"SourceDetails":{"Name":"msstore"},"Packages":[{"PackageIdentifier":"9NKSQGP7F2NH"}]}]}' | ConvertFrom-Json)
    $script:Sim.WinGet = @{ Method = 'winget export'; Packages = @(ConvertFrom-WdbWinGetExport $doc); Message = '' }
    $inv = New-WdbInventory
    Assert-Equal @($inv.applications).Count 2 'two packages'
    Assert-Equal $inv.collector.wingetMethod 'winget export' 'method recorded'
    Assert-True (@($inv.warnings | Where-Object { $_ -match 'Microsoft.WinGet.Client' }).Count -eq 1) 'warning about missing names'
    $g = @(Get-App $inv '^Git\.Git$')[0]
    Assert-True (@($g.notes | Where-Object { $_ -match 'Name not reported' }).Count) 'note on the record'
}

$tests['inventory: no WinGet at all still lists registry applications'] = {
    Reset-Sim; Set-SimWorkstation
    $inv = New-WdbInventory -SkipWinGet
    Assert-Equal $inv.collector.wingetMethod 'skipped' 'skipped'
    Assert-Equal @(Get-App $inv '^Git$')[0].packageIdentifier '' 'no identifier without WinGet'
}

$tests['inventory: portable programs only in named folders, with credible metadata'] = {
    Reset-Sim
    $tools = Join-Path $script:Sim.Root 'Tools'
    New-Item -ItemType Directory -Path "$tools\SyncPortable\App\AppInfo", "$tools\RandomStuff" -Force | Out-Null
    [IO.File]::WriteAllText("$tools\SyncPortable\App\AppInfo\appinfo.ini", "[Details]`r`nName=Sync Portable`r`nPublisher=Example Project`r`n[Version]`r`nDisplayVersion=2.1`r`n")
    [IO.File]::WriteAllText("$tools\RandomStuff\run.exe", 'MZ not a real program')
    $inv = New-WdbInventory -PortableRoots @($tools)
    $p = @($inv.applications | Where-Object { $_.source -eq 'portable' })
    Assert-Equal $p.Count 1 'only the folder with metadata counts'
    Assert-Equal $p[0].displayName 'Sync Portable' 'name from appinfo.ini'
    Assert-Equal $p[0].version '2.1' 'version'
    Assert-Equal $p[0].kind 'portable' 'kind'
    Assert-True (@((New-WdbInventory).applications).Count -eq 0) 'nothing is searched without -PortablePath'
}

$tests['inventory: development environment, version managers and repositories (opt-in)'] = {
    Reset-Sim; Set-SimWorkstation
    New-Item -ItemType Directory -Path "$($script:Sim.Env.APPDATA)\nvm\v20.11.1", "$($script:Sim.Env.APPDATA)\nvm\v22.20.0" -Force | Out-Null
    New-SimFile 'USERPROFILE' '.vscode\extensions\extensions.json' '[{"identifier":{"id":"ms-python.python"},"version":"2025.1.0","location":{"path":"/c:/Users/Alex/x"}},{"identifier":{"id":"bad id; rm"},"version":"1"}]' | Out-Null
    New-SimFile 'USERPROFILE' '.gitconfig' "[user]`n`tname = Alex Example`n" | Out-Null
    New-SimFile 'DOCUMENTS' 'WindowsPowerShell\Modules\Posh-Git\1.1.0\posh-git.psd1' '@{}' | Out-Null
    New-SimFile 'DOCUMENTS' 'WindowsPowerShell\Modules\Posh-Git\1.1.0\PSGetModuleInfo.xml' '<Objs><Obj><MS><S N="Repository">PSGallery</S></MS></Obj></Objs>' | Out-Null
    New-SimFile 'USERPROFILE' '.local\bin\claude.exe' 'MZ' | Out-Null
    $script:Sim.Python = @(@{ Tag = '3.13'; Version = '3.13.7'; Scope = 'user' })
    $repos = Join-Path $script:Sim.Root 'src'
    New-Item -ItemType Directory -Path "$repos\project-a\.git" -Force | Out-Null
    [IO.File]::WriteAllText("$repos\project-a\.git\config", "[core]`n`tbare = false`n[remote `"origin`"]`n`turl = https://alex:ghp_secretvalue@github.com/example/project-a.git`n")
    $inv = New-WdbInventory -RepositoryRoots @($repos)
    $d = $inv.devEnvironment
    Assert-True $d.git.installed 'git detected'
    Assert-True $d.git.globalConfig 'global config present'
    Assert-Equal (@($d.vscodeExtensions | ForEach-Object { $_.id }) -join ',') 'ms-python.python' 'only valid extension ids'
    Assert-Equal $d.node.version '22.20.0' 'standalone Node.js version'
    Assert-Equal $d.node.managers[0].name 'nvm-windows' 'version manager kept'
    Assert-Equal ($d.node.managers[0].versions -join ',') 'v20.11.1,v22.20.0' 'managed versions'
    Assert-Equal $d.python[0].version '3.13.7' 'PEP 514 registration'
    Assert-Equal $d.powershellModules[0].name 'Posh-Git' 'module'
    Assert-Equal $d.powershellModules[0].repository 'PSGallery' 'repository'
    Assert-Equal $d.claudeCode.method 'native' 'Claude Code native installer'
    Assert-Equal $d.repositories[0].remote 'https://github.com/example/project-a.git' 'credentials removed from the remote'
    Assert-True ((ConvertTo-WdbJson $inv) -notmatch 'ghp_secret') 'token never exported'
    $s = @($inv.settings | Where-Object { $_.adapterId -eq 'git' })[0]
    Assert-True $s.available 'git settings available'
}

$tests['backup preview: secrets, caches and keys are left out; flagged files need -IncludeFlagged'] = {
    Reset-Sim; Set-SimWorkstation
    New-SimFile 'APPDATA' 'Code\User\settings.json' "{`n  `"editor.fontSize`": 14,`n  `"editor.tokenColorCustomizations`": {}`n}" | Out-Null
    New-SimFile 'APPDATA' 'Code\User\keybindings.json' "[`n  { `"key`": `"ctrl+k`", `"command`": `"x`", `"args`": { `"text`": `"$('ghp' + '_0123456789abcdefghijklmnopqrstuvwxyzAB')`" } }`n]" | Out-Null
    New-SimFile 'APPDATA' 'Code\User\snippets\python.json' '{}' | Out-Null
    New-SimFile 'APPDATA' 'Code\User\snippets\notes.txt' 'not a snippet' | Out-Null
    New-SimFile 'APPDATA' 'Code\User\globalStorage\state.vscdb' 'SQLite token store' | Out-Null
    New-SimFile 'USERPROFILE' '.ssh\config' "Host router`n  HostName 10.0.0.1`n  IdentityFile ~/.ssh/id_ed25519`n" | Out-Null
    New-SimFile 'USERPROFILE' '.ssh\id_ed25519' "-----BEGIN OPENSSH PRIVATE KEY-----`nabc`n" | Out-Null
    $plan = @(Get-WdbBackupPlan @('vscode', 'openssh-client'))
    $vs = $plan[0]
    Assert-Equal (($vs.Items | ForEach-Object { $_.Logical }) -join ',') 'settings.json,snippets/python.json' 'only settings and matching snippets; the token file is left out'
    $flag = @($vs.Excluded | Where-Object { $_.logical -eq 'keybindings.json' })
    Assert-True ($flag.Count -eq 1 -and $flag[0].reason -match 'token format, line 2' -and $flag[0].reason -notmatch 'ghp_') 'rule and line reported, never the secret'
    $ssh = $plan[1]
    Assert-Equal (($ssh.Items | ForEach-Object { $_.Logical }) -join ',') 'config' 'only the ssh config, never a key'
    $preview = Format-WdbBackupPreview $plan
    Assert-True ($preview -match 'never included: state.vscdb') 'preview names what is never included'
    Assert-True ($preview -match 'docker-desktop') 'preview lists unsupported applications'
    $plan2 = @(Get-WdbBackupPlan @('vscode') -IncludeFlagged @('vscode/keybindings.json'))
    Assert-True (@($plan2[0].Items | Where-Object { $_.Logical -eq 'keybindings.json' -and $_.Flagged }).Count -eq 1) 'included only after explicit review'
    $unk = @(Get-WdbBackupPlan @('docker-desktop'))
    Assert-True (-not $unk[0].Known -and $unk[0].Excluded[0].reason -match 'machine-bound') 'unsupported adapter explained'
}

$tests['backup: git configuration keeps only portable keys'] = {
    Reset-Sim
    $cfg = @"
[user]
	name = Alex Example
	email = alex@example.com
	signingkey = ABCDEF0123
[credential]
	helper = manager
[http "https://example.com"]
	extraheader = AUTHORIZATION: bearer abc123
[url "https://alex:tok@github.com/"]
	insteadOf = https://github.com/
[core]
	autocrlf = true
	editor = code --wait
	sshCommand = C:/Tools/ssh.exe
[alias]
	co = checkout
	nuke = !git clean -fdx
[init]
	defaultBranch = main
[safe]
	directory = D:/work/x
[include]
	path = C:/Users/Alex/private.gitconfig
"@
    $g = ConvertTo-WdbPortableGitConfig $cfg
    Assert-True ($g.Text -match "name = Alex Example") 'identity kept'
    Assert-True ($g.Text -match 'defaultBranch = main') 'defaults kept'
    Assert-True ($g.Text -match 'co = checkout') 'plain alias kept'
    Assert-True ($g.Text -notmatch '(?i)credential|extraheader|bearer|insteadOf|tok@|signingkey|sshCommand|safe|include|editor|nuke') 'secrets, machine paths and commands removed'
    Assert-True (@($g.FollowUps | Where-Object { $_ -match 'core.editor' }).Count -eq 1) 'editor listed for manual re-entry'
    Assert-True (@($g.FollowUps | Where-Object { $_ -match 'alias.nuke' }).Count -eq 1) 'shell alias listed for manual re-entry'
}

$tests['backup: Notepad++ history is removed and XML with a DTD is refused'] = {
    Reset-Sim
    New-SimFile 'APPDATA' 'Notepad++\config.xml' '<?xml version="1.0"?><NotepadPlus><FindHistory nbMaxFindHistoryPath="10"><Find name="customer password"/></FindHistory><History nbMaxFile="10"><File filename="C:\Users\Alex\secret-plan.txt"/></History><GUIConfigs><GUIConfig name="TabBar" dragAndDrop="yes"/></GUIConfigs></NotepadPlus>' | Out-Null
    New-SimFile 'APPDATA' 'Notepad++\shortcuts.xml' '<?xml version="1.0"?><!DOCTYPE x [<!ENTITY e SYSTEM "file:///c:/windows/win.ini">]><NotepadPlus>&e;</NotepadPlus>' | Out-Null
    $plan = @(Get-WdbBackupPlan @('notepadpp'))
    $cfg = [Text.Encoding]::UTF8.GetString(@($plan[0].Items | Where-Object { $_.Logical -eq 'config.xml' })[0].Bytes)
    Assert-True ($cfg -match 'TabBar' -and $cfg -notmatch 'secret-plan|customer password') 'history and searches removed, preferences kept'
    $x = @($plan[0].Excluded | Where-Object { $_.logical -eq 'shortcuts.xml' })
    Assert-True ($x.Count -eq 1 -and $x[0].reason -match 'could not be read safely') 'DTD refused (no external entity is ever resolved)'
}

$tests['backup: registry sessions without passwords; key paths reported'] = {
    Reset-Sim
    $s = 'HKCU\Software\SimonTatham\PuTTY\Sessions'
    $script:Sim.Registry["$s\Core%20Router"] = [ordered]@{ HostName = @{ type = 'String'; data = '10.0.0.1' }; PortNumber = @{ type = 'DWord'; data = [int64] 22 }; ProxyPassword = @{ type = 'String'; data = 'hunter2' }; PublicKeyFile = @{ type = 'String'; data = 'C:\Users\Alex\keys\router.ppk' }; Colour0 = @{ type = 'String'; data = '187,187,187' }; Bits = @{ type = 'Other'; data = $null }; Big = @{ type = 'DWord'; data = [int64] 4294967295 } }
    $script:Sim.Registry['HKCU\Software\SimonTatham\PuTTY\SshHostKeys'] = [ordered]@{ 'ssh-ed25519@22:10.0.0.1' = @{ type = 'String'; data = '0x1234' } }
    $plan = @(Get-WdbBackupPlan @('putty'))
    $sess = [Text.Encoding]::UTF8.GetString(@($plan[0].Items | Where-Object { $_.Logical -eq 'Sessions.json' })[0].Bytes)
    Assert-True ($sess -notmatch 'hunter2|ProxyPassword') 'password value never exported'
    Assert-True ($sess -match '"HostName"' -and $sess -match '4294967295') 'session values kept (unsigned DWORD)'
    Assert-True (@($plan[0].Notes | Where-Object { $_ -match 'PublicKeyFile' }).Count -eq 1) 'key file reference reported'
    Assert-True (@($plan[0].Excluded | Where-Object { $_.logical -match 'ProxyPassword' }).Count -eq 1) 'listed as excluded'
    # Host key values contain characters outside the allowed value names and are skipped, not guessed.
    Assert-Equal @($plan[0].Items).Count 2 'two items'
}

$tests['backup: the package has a manifest with hashes, a summary and no user name'] = {
    Reset-Sim
    New-SimFile 'APPDATA' 'Code\User\settings.json' '{ "editor.fontSize": 14 }' | Out-Null
    New-SimFile 'USERPROFILE' '.gitconfig' "[user]`n`tname = Alex`n" | Out-Null
    $dest = Join-Path $script:Sim.Root 'Backups'
    New-Item -ItemType Directory -Path $dest | Out-Null
    Assert-Throws { New-WdbBackup @(Get-WdbBackupPlan @('vscode')) '' } 'Destination' 'an explicit destination is required'
    $b = New-WdbBackup @(Get-WdbBackupPlan @('vscode', 'git', 'browsers')) $dest '0123456789abcdef' -CreateZip
    Assert-True (Test-Path (Join-Path $b.Path 'backup-manifest.json')) 'manifest'
    Assert-True (Test-Path (Join-Path $b.Path 'SUMMARY.txt')) 'summary'
    Assert-True (Test-Path (Join-Path $b.Path 'RESTORE-INSTRUCTIONS.txt')) 'instructions'
    Assert-True (Test-Path $b.Zip) 'zip'
    $m = $b.Manifest
    Assert-Equal $m.totals.files 2 'two files'
    Assert-Equal $m.unsupported[0].id 'browsers' 'unsupported recorded'
    $mText = [IO.File]::ReadAllText((Join-Path $b.Path 'backup-manifest.json'))
    Assert-True ($mText -notmatch [regex]::Escape($script:Sim.Root)) 'no local paths in the manifest'
    Assert-Equal (Get-WdbFileSha256 (Join-Path $b.Path 'backup-manifest.json')) $b.ManifestSha256 'manifest hash'
    $v = Test-WdbBackup $b.Path $b.ManifestSha256
    Assert-True $v.Ok "fresh backup validates: $($v.Problems -join '; ')"
    if ($Out) {
        New-Item -ItemType Directory -Path $Out -Force | Out-Null
        Copy-Item (Join-Path $b.Path 'backup-manifest.json') (Join-Path $Out 'backup-manifest.json')
        Set-SimWorkstation
        $inv = New-WdbInventory
        $inv.backup = [ordered]@{ backupId = $m.backupId; manifestSha256 = $b.ManifestSha256; folderName = $b.FolderName; createdUtc = $m.createdUtc; adapters = @($m.adapters | ForEach-Object { [ordered]@{ id = $_.id; items = @($_.items).Count; excluded = @($_.excluded).Count } }) }
        [IO.File]::WriteAllText((Join-Path $Out 'inventory.json'), (ConvertTo-WdbJson $inv))
    }
}

function New-SimBackup {
    param([string[]] $Adapters = @('vscode', 'git', 'putty', 'notepadpp', 'powershell-profile', 'windows-terminal', 'openssh-client'))
    New-SimFile 'APPDATA' 'Code\User\settings.json' '{ "editor.fontSize": 14 }' | Out-Null
    New-SimFile 'APPDATA' 'Code\User\snippets\python.json' '{ "main": {} }' | Out-Null
    New-SimFile 'USERPROFILE' '.vscode\extensions\extensions.json' '[{"identifier":{"id":"ms-python.python"},"version":"1"},{"identifier":{"id":"eamodio.gitlens"},"version":"2"}]' | Out-Null
    New-SimFile 'USERPROFILE' '.gitconfig' "[user]`n`tname = Alex`n" | Out-Null
    New-SimFile 'USERPROFILE' '.ssh\config' "Host r`n  HostName 10.0.0.1`n" | Out-Null
    New-SimFile 'APPDATA' 'Notepad++\stylers.xml' '<NotepadPlus/>' | Out-Null
    New-SimFile 'DOCUMENTS' 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1' 'Set-Location C:\' | Out-Null
    New-SimFile 'LOCALAPPDATA' 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json' '{ "defaultProfile": "{x}" }' | Out-Null
    $script:Sim.Registry['HKCU\Software\SimonTatham\PuTTY\Sessions\Core%20Router'] = [ordered]@{ HostName = @{ type = 'String'; data = '10.0.0.1' }; PortNumber = @{ type = 'DWord'; data = [int64] 22 } }
    $dest = Join-Path $script:Sim.Root 'Backups'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $b = New-WdbBackup @(Get-WdbBackupPlan $Adapters) $dest
    # The "new computer": an empty profile with the applications installed.
    $old = $script:Sim.Root
    Reset-Sim
    $script:Sim.OldRoot = $old
    $script:Sim.Uninstall = @(
        (New-Uninstall 'HKCU' '64' 'VSCode' @{ DisplayName = 'Microsoft Visual Studio Code (User)'; DisplayVersion = '1.105.0' }),
        (New-Uninstall 'HKLM' '64' 'PuTTY' @{ DisplayName = 'PuTTY release 0.83'; DisplayVersion = '0.83' }),
        (New-Uninstall 'HKLM' '64' 'Npp' @{ DisplayName = 'Notepad++ (64-bit x64)'; DisplayVersion = '8.8' })
    )
    New-Item -ItemType Directory -Path "$($script:Sim.Env.LOCALAPPDATA)\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe" -Force | Out-Null
    New-Item -ItemType Directory -Path "$($script:Sim.Env.LOCALAPPDATA)\Programs\Microsoft VS Code\bin" -Force | Out-Null
    [IO.File]::WriteAllText("$($script:Sim.Env.LOCALAPPDATA)\Programs\Microsoft VS Code\bin\code.cmd", '@echo simulated')
    return $b
}

$tests['validate: a modified, missing, extra or mislabelled file is detected'] = {
    Reset-Sim
    $b = New-SimBackup @('vscode', 'git')
    $v = Test-WdbBackup $b.Path $b.ManifestSha256
    Assert-True $v.Ok 'valid'
    $f = Join-Path $b.Path 'data\vscode\settings.json'
    [IO.File]::AppendAllText($f, ' ')
    $v = Test-WdbBackup $b.Path
    Assert-True (-not $v.Ok -and ($v.Problems -join ' ') -match 'wrong size|SHA-256') 'modified file detected'
    Remove-Item $f
    Assert-True ((Test-WdbBackup $b.Path).Problems -join ' ' -match 'missing') 'missing file detected'
    [IO.File]::WriteAllText((Join-Path $b.Path 'data\git\extra.txt'), 'x')
    Assert-True (((Test-WdbBackup $b.Path).Warnings -join ' ') -match 'Unlisted file ignored') 'extra file reported, never used'
    Assert-True ((Test-WdbBackup $b.Path ('0' * 64)).Problems -join ' ' -match 'does not match the backup this deployment expects') 'pinned manifest hash enforced'
}

<# Rewrites the manifest of a backup (a crafted, internally consistent backup) and returns its hash. #>
function Set-SimManifest {
    param([string] $Root, [scriptblock] $Change)
    $p = Join-Path $Root 'backup-manifest.json'
    $m = ConvertTo-WdbHashtable ([IO.File]::ReadAllText($p) | ConvertFrom-Json)
    & $Change $m
    $bytes = Get-WdbUtf8 (ConvertTo-WdbJson $m)
    [IO.File]::WriteAllBytes($p, $bytes)
    Get-WdbSha256 $bytes
}

$tests['validate: crafted manifests cannot point outside the backup or to other files'] = {
    Reset-Sim
    $b = New-SimBackup @('git')
    Set-SimManifest $b.Path { param($m) $m.adapters[0].items[0].path = 'data/git/../../../evil' } | Out-Null
    Assert-True ((Test-WdbBackup $b.Path).Problems -join ' ' -match 'not where this adapter keeps') 'traversal refused'
    Set-SimManifest $b.Path { param($m) $m.adapters[0].items[0].path = 'data/git/gitconfig'; $m.adapters[0].items[0].logical = '..\..\Windows\System32\drivers\etc\hosts' } | Out-Null
    Assert-True ((Test-WdbBackup $b.Path).Problems -join ' ' -match 'not an item this adapter restores') 'arbitrary destination refused'
    Set-SimManifest $b.Path { param($m) $m.adapters[0].items[0].logical = 'gitconfig'; $m.adapters[0].id = 'evil-adapter' } | Out-Null
    $v = Test-WdbBackup $b.Path
    Assert-True ($v.Ok -and ($v.Warnings -join ' ') -match "'evil-adapter' is not known") 'unknown adapter skipped, never trusted'
    Set-SimManifest $b.Path { param($m) $m.adapters[0].id = 'git'; $m.formatVersion = 2 } | Out-Null
    Assert-True ((Test-WdbBackup $b.Path).Problems -join ' ' -match 'Unsupported backup format version 2') 'future format refused'
    [IO.File]::WriteAllText((Join-Path $b.Path 'backup-manifest.json'), '{ not json')
    Assert-True ((Test-WdbBackup $b.Path).Problems -join ' ' -match 'not valid JSON') 'malformed manifest'
}

$tests['validate: links inside a backup are refused'] = {
    Reset-Sim
    $b = New-SimBackup @('git')
    $target = Join-Path $script:Sim.Root 'elsewhere'
    New-Item -ItemType Directory -Path $target | Out-Null
    $link = Join-Path $b.Path 'data\linked'
    New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    try {
        Assert-True ((Test-WdbBackup $b.Path).Problems -join ' ' -match 'Link inside the backup') 'junction detected'
    } finally { [IO.Directory]::Delete($link) }
}

function New-SimZip {
    param([string] $Path, [hashtable] $Entries, [System.IO.Compression.CompressionLevel] $Level = 'NoCompression')
    Add-Type -AssemblyName System.IO.Compression
    $fs = [IO.File]::Open($Path, 'Create')
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    foreach ($k in $Entries.Keys) { $e = $zip.CreateEntry($k, $Level); $s = $e.Open(); $bytes = $Entries[$k]; $s.Write($bytes, 0, $bytes.Length); $s.Dispose() }
    $zip.Dispose(); $fs.Dispose()
}

$tests['archive: a backup ZIP extracts safely; traversal, absolute paths, odd entries and bombs are refused'] = {
    Reset-Sim
    $dest = Join-Path $script:Sim.Root 'Backups'
    New-Item -ItemType Directory -Path $dest | Out-Null
    New-SimFile 'USERPROFILE' '.gitconfig' "[user]`n`tname = Alex`n" | Out-Null
    $b = New-WdbBackup @(Get-WdbBackupPlan @('git')) $dest -CreateZip
    $v = Open-WdbBackup $b.Zip $script:Sim.Root $b.ManifestSha256
    Assert-True $v.Ok "zip validates: $($v.Problems -join '; ')"
    $x = [byte[]] @(65)
    foreach ($bad in @(@('../evil.txt', 'Unsafe entry'), @('C:/Windows/evil.txt', 'Unsafe entry'), @('/abs.txt', 'Unsafe entry'), @('data/git/gitconfig:stream', 'Unsafe entry'), @('scripts/run.ps1', 'Unexpected entry'))) {
        $z = Join-Path $script:Sim.Root ("bad-" + [Guid]::NewGuid().ToString('N') + '.zip')
        New-SimZip $z @{ $bad[0] = $x }
        $t = Join-Path $script:Sim.Root ('x-' + [Guid]::NewGuid().ToString('N'))
        Assert-Throws { Expand-WdbBackupArchive $z $t } $bad[1] "refused: $($bad[0])"
        Assert-True (-not (Test-Path (Join-Path $script:Sim.Root 'evil.txt'))) 'nothing written outside'
    }
    $z = Join-Path $script:Sim.Root 'bomb.zip'
    New-SimZip $z @{ 'data/git/gitconfig' = (New-Object byte[] (3MB)) } 'Optimal'
    Assert-Throws { Expand-WdbBackupArchive $z (Join-Path $script:Sim.Root 'bomb') } 'compression ratio' 'zip bomb refused'
}

$tests['restore: settings are restored after validation, verified, and never written twice'] = {
    Reset-Sim
    $b = New-SimBackup
    $v = Test-WdbBackup $b.Path $b.ManifestSha256
    $r = Invoke-WdbAdapterRestore $v 'vscode' 'keepExisting' -InstallExtensions
    Assert-Equal $r.Outcome 'Restored' "vscode restored: $($r.Message)"
    Assert-Equal (Get-SimText 'APPDATA' 'Code\User\settings.json') '{ "editor.fontSize": 14 }' 'settings written'
    Assert-True (Test-Path (Join-Path $script:Sim.Env.APPDATA 'Code\User\snippets\python.json')) 'snippet written'
    Assert-Equal (($script:Sim.Cli.Installed | Sort-Object) -join ',') 'eamodio.gitlens,ms-python.python' 'extensions installed through the VS Code command line'
    $stamp = (Get-Item (Join-Path $script:Sim.Env.APPDATA 'Code\User\settings.json')).LastWriteTimeUtc
    $calls = $script:Sim.Cli.Calls.Count
    $r2 = Invoke-WdbAdapterRestore $v 'vscode' 'keepExisting' -InstallExtensions
    Assert-Equal $r2.Outcome 'AlreadyRestored' 'second run changes nothing'
    Assert-Equal (Get-Item (Join-Path $script:Sim.Env.APPDATA 'Code\User\settings.json')).LastWriteTimeUtc $stamp 'file not rewritten'
    Assert-Equal ($script:Sim.Cli.Calls.Count - $calls) 1 'only the extension list was read again'
    $r = Invoke-WdbAdapterRestore $v 'putty' 'keepExisting'
    Assert-Equal $r.Outcome 'Restored' 'putty'
    Assert-Equal $script:Sim.Registry['HKCU\Software\SimonTatham\PuTTY\Sessions\Core%20Router']['HostName'].data '10.0.0.1' 'registry value'
    Assert-Equal (Invoke-WdbAdapterRestore $v 'putty' 'keepExisting').Outcome 'AlreadyRestored' 'registry idempotent'
    Assert-Equal (Invoke-WdbAdapterRestore $v 'windows-terminal').Outcome 'Restored' 'terminal'
    Assert-Equal (Invoke-WdbAdapterRestore $v 'git').Outcome 'Restored' 'git'
    Assert-Equal (Invoke-WdbAdapterRestore $v 'openssh-client').Outcome 'Restored' 'ssh config'
    Assert-Equal (Invoke-WdbAdapterRestore $v 'notepadpp').Outcome 'Restored' 'notepad++'
}

$tests['restore: conflict policies keep, replace (keeping the original once) or skip'] = {
    Reset-Sim
    $b = New-SimBackup @('vscode', 'git')
    $v = Test-WdbBackup $b.Path
    New-SimFile 'USERPROFILE' '.gitconfig' "[user]`n`tname = New Computer`n" | Out-Null
    $r = Invoke-WdbAdapterRestore $v 'git' 'keepExisting'
    Assert-Equal $r.Outcome 'KeptExisting' 'kept'
    Assert-True ((Get-SimText 'USERPROFILE' '.gitconfig') -match 'New Computer') 'existing file untouched'
    Assert-Equal (Invoke-WdbAdapterRestore $v 'git' 'skip').Outcome 'SkippedByUser' 'skip'
    $p = Invoke-WdbAdapterRestore $v 'git' 'restoreBackup' -WhatIf
    Assert-True ($p.Items[0].action -eq 'replace' -and (Get-SimText 'USERPROFILE' '.gitconfig') -match 'New Computer') 'preview changes nothing'
    $r = Invoke-WdbAdapterRestore $v 'git' 'restoreBackup'
    Assert-Equal $r.Outcome 'Restored' 'replaced'
    Assert-True ((Get-SimText 'USERPROFILE' '.gitconfig.wdb-before-restore') -match 'New Computer') 'original kept'
    New-SimFile 'USERPROFILE' '.gitconfig' "[user]`n`tname = Changed again`n" | Out-Null
    Invoke-WdbAdapterRestore $v 'git' 'restoreBackup' | Out-Null
    Assert-True ((Get-SimText 'USERPROFILE' '.gitconfig.wdb-before-restore') -match 'New Computer') 'the first original is never overwritten'
    New-SimFile 'APPDATA' 'Code\User\settings.json' '{ "existing": true }' | Out-Null
    $r = Invoke-WdbAdapterRestore $v 'vscode' 'keepExisting'
    Assert-Equal $r.Outcome 'PartiallyRestored' 'some files kept, others written'
}

$tests['restore: missing or running applications wait for the user; scripts only go to a review folder'] = {
    Reset-Sim
    $b = New-SimBackup @('vscode', 'notepadpp', 'powershell-profile', 'windows-terminal')
    $v = Test-WdbBackup $b.Path
    $script:Sim.Uninstall = @()
    $r = Invoke-WdbAdapterRestore $v 'vscode'
    Assert-True ($r.Outcome -eq 'WaitingForUser' -and $r.Message -match 'not installed') 'app missing: waits, does not create its folders'
    Assert-True (-not (Test-Path (Join-Path $script:Sim.Env.APPDATA 'Code'))) 'nothing written for a missing application'
    $script:Sim.Uninstall = @(New-Uninstall 'HKLM' '64' 'Npp' @{ DisplayName = 'Notepad++ (64-bit x64)' })
    $script:Sim.Running = @('notepad++')
    Assert-True ((Invoke-WdbAdapterRestore $v 'notepadpp').Message -match 'Close Notepad\+\+') 'running application'
    Remove-Item -LiteralPath "$($script:Sim.Env.LOCALAPPDATA)\Packages" -Recurse -Force
    Assert-True ((Invoke-WdbAdapterRestore $v 'windows-terminal').Message -match 'open Windows Terminal once') 'terminal not registered yet'
    $r = Invoke-WdbAdapterRestore $v 'powershell-profile'
    Assert-Equal $r.Outcome 'ManualActionRequired' 'profiles need review'
    Assert-True (-not (Test-Path (Join-Path $script:Sim.Env.DOCUMENTS 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'))) 'live profile never written'
    Assert-True (Test-Path (Join-Path $script:Sim.Env.DOCUMENTS 'WindowsDeploymentBuilder\Restored settings\WindowsPowerShell\Microsoft.PowerShell_profile.ps1')) 'review copy'
}

$tests['restore: a crafted backup cannot write password values or leave the user folders'] = {
    Reset-Sim
    $b = New-SimBackup @('putty')
    $f = Join-Path $b.Path 'data\putty\Sessions.json'
    $doc = ConvertTo-WdbHashtable ([IO.File]::ReadAllText($f) | ConvertFrom-Json)
    $doc.keys['Core%20Router']['ProxyPassword'] = [ordered]@{ type = 'String'; data = 'injected' }
    $doc.keys['Evil\..\..\Run'] = [ordered]@{ Payload = [ordered]@{ type = 'String'; data = 'calc.exe' } }
    $bytes = Get-WdbUtf8 (ConvertTo-WdbJson $doc)
    [IO.File]::WriteAllBytes($f, $bytes)
    $h = Set-SimManifest $b.Path { param($m) $m.adapters[0].items[0].size = $bytes.Length; $m.adapters[0].items[0].sha256 = (Get-WdbSha256 $bytes) }
    $v = Test-WdbBackup $b.Path $h
    Assert-True $v.Ok 'internally consistent crafted backup'
    $r = Invoke-WdbAdapterRestore $v 'putty' 'restoreBackup'
    Assert-True (-not $script:Sim.Registry['HKCU\Software\SimonTatham\PuTTY\Sessions\Core%20Router'].Contains('ProxyPassword')) 'password value refused on restore too'
    Assert-Equal @($script:Sim.Registry.Keys | Where-Object { $_ -match 'Run|Evil' }).Count 0 'key names with a backslash refused'
    Assert-True ($r.Items[0].detail -match 'refused') 'refusal reported'
}

$tests['restore: an invalid backup restores nothing'] = {
    Reset-Sim
    $b = New-SimBackup @('git')
    [IO.File]::AppendAllText((Join-Path $b.Path 'data\git\gitconfig'), "[credential]`n`thelper = evil`n")
    $v = Test-WdbBackup $b.Path
    $r = Invoke-WdbAdapterRestore $v 'git' 'restoreBackup'
    Assert-True ($r.Outcome -eq 'Failed' -and $r.Class -eq 'Integrity') 'refused with class Integrity'
    Assert-True (-not (Test-Path (Join-Path $script:Sim.Env.USERPROFILE '.gitconfig'))) 'nothing written'
}

$tests['restore: extension failures are follow-ups; Cursor extensions are always a manual list'] = {
    Reset-Sim
    $b = New-SimBackup @('vscode')
    $v = Test-WdbBackup $b.Path
    $script:Sim.Cli.Fail = @('eamodio.gitlens')
    $r = Invoke-WdbAdapterRestore $v 'vscode' -InstallExtensions
    Assert-Equal $r.Outcome 'PartiallyRestored' 'partial'
    Assert-True (@($r.FollowUps | Where-Object { $_ -match 'eamodio.gitlens' }).Count -eq 1) 'failed extension listed'
    $r = Invoke-WdbAdapterRestore $v 'vscode'
    Assert-True (@($r.FollowUps | Where-Object { $_ -match 'code --install-extension' }).Count -eq 1) 'without -InstallExtensions only a list'
}

$tests['staging: only manifest files are copied and the copy validates'] = {
    Reset-Sim
    $b = New-SimBackup @('git', 'vscode')
    [IO.File]::WriteAllText((Join-Path $b.Path 'data\git\stowaway.ps1'), 'Write-Host evil')
    $v = Test-WdbBackup $b.Path $b.ManifestSha256
    $t = Join-Path $script:Sim.Root 'staged'
    $c = Copy-WdbBackup $v $t
    Assert-True $c.Ok 'staged copy validates'
    Assert-True (-not (Test-Path (Join-Path $t 'data\git\stowaway.ps1'))) 'unlisted file not copied'
    Assert-True (-not (Test-Path (Join-Path $t 'SUMMARY.txt'))) 'only what restore needs'
    Assert-Throws { Copy-WdbBackup @{ Ok = $false } $t } 'did not validate' 'invalid backups are never staged'
}

$tests['secret rules: common tokens are found, ordinary settings are not'] = {
    # Token-shaped values are assembled at run time, so the repository never contains one.
    $fake = 'abcdefghijklmnopqrstuvwxyz0123456789'
    foreach ($s in @("`"github.token`": `"ghp_$fake`"", 'http.proxy=http://bob:pw@proxy:8080', "`$env:OPENAI_API_KEY = `"sk-proj-$($fake.Substring(0, 24))`"", 'password = hunter22', ('-----BEGIN RSA ' + 'PRIVATE KEY-----'), ('AKIA' + 'ABCDEFGHIJKLMNOP'))) {
        Assert-True (@(Find-WdbSecrets $s).Count -eq 1) "found: $s"
    }
    foreach ($s in @('"editor.tokenColorCustomizations": {}', '"terminal.integrated.fontSize": 14', 'sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5', 'HostName 10.0.0.1', '"workbench.colorTheme": "Default Dark+"')) {
        Assert-True (@(Find-WdbSecrets $s).Count -eq 0) "not a secret: $s"
    }
}

$tests['the script refuses arguments that are not plain tokens'] = {
    Assert-Throws { Invoke-WdbProcessReal 'x.cmd' @('--install-extension', 'a&calc') } 'Refused argument' 'metacharacters refused'
}

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
Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'wdb-test-*' -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "$($script:Passed) passed, $($script:Failures) failed"
if ($script:Failures -gt 0) { exit 1 }
exit 0
