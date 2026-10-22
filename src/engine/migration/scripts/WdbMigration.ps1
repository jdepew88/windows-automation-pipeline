#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Deployment Builder - application inventory, settings backup and restore (Phase 6).

.DESCRIPTION
    A local tool for the computer whose applications should be reconstructed later. It never
    installs, uninstalls or runs an application, never starts a service and never uploads
    anything: every mode works on this computer and on folders you name.

      -Mode Inventory       (read-only) installed applications from WinGet, the Windows uninstall
                            records (64-bit, 32-bit, machine and current user), Microsoft Store /
                            MSIX packages and, only for folders you name with -PortablePath,
                            portable programs; development tools and the settings that could be
                            backed up. Writes one inventory JSON file (-OutFile).
      -Mode PreviewBackup   (read-only) exactly what a backup would contain, what it leaves out and
                            why (possible secrets, caches, machine-bound state).
      -Mode Backup          copies the supported settings of the chosen adapters (-Adapter) into a
                            new folder under -Destination, with a manifest of SHA-256 hashes, a
                            summary and restore instructions. -Zip also writes an uncompressed ZIP.
      -Mode Validate        (read-only) checks a backup folder or ZIP: manifest, paths, sizes,
                            hashes, adapter compatibility. A failed validation stops a restore.
      -Mode PreviewRestore  (read-only) what a restore would write, keep or skip on this computer.
      -Mode Restore         restores the chosen adapters into the current user's profile after the
                            backup validated. -Conflict decides what happens to existing settings:
                            keepExisting (default), restoreBackup (the original is kept as
                            *.wdb-before-restore) or skip.
      -Mode Library         (dot-sourcing) defines the functions only; the application engine uses
                            them to restore settings during a deployment.

    Never collected: passwords, tokens, private keys (SSH, PuTTY .ppk, certificates), credential
    stores, browser profiles, cookies, Docker credentials, whole AppData folders, caches. Files that
    look like they contain a secret are left out unless named with -IncludeFlagged after review.
    Nothing inside a backup is ever executed; restore destinations come from the adapter
    definitions in this script, never from the backup.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WdbMigration.ps1 -Mode Inventory -OutFile .\inventory.json
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WdbMigration.ps1 -Mode PreviewBackup -Adapter vscode,git,putty
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WdbMigration.ps1 -Mode Backup -Adapter vscode,git,putty -Destination E:\Backups -InventoryPath .\inventory.json
#>
[CmdletBinding()]
param(
    [ValidateSet('Inventory', 'PreviewBackup', 'Backup', 'Validate', 'PreviewRestore', 'Restore', 'Library')]
    [string] $Mode = 'Inventory',
    [string] $OutFile = '',
    [string] $Destination = '',
    [string] $BackupPath = '',
    [string] $InventoryPath = '',
    [string[]] $Adapter = @(),
    [string[]] $IncludeFlagged = @(),
    [string[]] $PortablePath = @(),
    [string[]] $RepositoryRoot = @(),
    [ValidateSet('keepExisting', 'restoreBackup', 'skip')]
    [string] $Conflict = 'keepExisting',
    [switch] $Zip,
    [switch] $NoWinGet,
    [switch] $Json
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:WdbVersion = '1.0.0'
$script:InventoryFormat = 'windows-deployment-builder/app-inventory'
$script:BackupFormat = 'windows-deployment-builder/app-backup'
$script:RegistryFormat = 'windows-deployment-builder/registry-export'
$script:ManifestName = 'backup-manifest.json'

# Limits: a backup holds settings, not data. Anything larger is refused rather than truncated.
$script:Limits = @{ fileBytes = 1MB; adapterBytes = 5MB; backupBytes = 20MB; folderFiles = 100; manifestBytes = 1MB; zipEntries = 2000; zipBytes = 50MB; zipRatio = 100; portableExe = 200; registryKeys = 500; registryValues = 200; stringValue = 4096 }

$script:HexId = '^[0-9a-f]{16}$'
$script:Sha256 = '^[0-9A-F]{64}$'
$script:AdapterIdPattern = '^[a-z0-9][a-z0-9-]{0,31}$'
$script:SafeName = '^[A-Za-z0-9][A-Za-z0-9._ ()+-]{0,99}$'
$script:ExtensionId = '^[A-Za-z0-9][A-Za-z0-9-]{0,62}\.[A-Za-z0-9][A-Za-z0-9-]{0,62}$'
$script:RegistryValueName = '^[A-Za-z0-9][A-Za-z0-9_ .-]{0,99}$'
# Key names: PuTTY and WinSCP escape special characters (%20); "/" separates WinSCP folders.
$script:RegistryKeyName = '^[A-Za-z0-9%][A-Za-z0-9%._ @/()+=,~#!-]{0,199}$'

# ------------------------------------------------------------------------------------------------
# Adapters. Each one is a reviewed, fixed description of where an application keeps settings that
# are safe to move to another computer. Destinations are resolved from these definitions only.
#   kind file          one file             folder     files of one folder matching filePattern
#        gitconfig     .gitconfig, filtered to portable keys
#        xmlsanitized  XML with history nodes emptied (recent files, search terms)
#        registryTree  HKCU subkeys and their values      registryValues   values of one HKCU key
#        extensions    extension list (reinstalled, never copied)
#        review        restored to a review folder, never into the live location (scripts)
# ------------------------------------------------------------------------------------------------

$script:WdbAdapters = [ordered]@{
    'vscode' = @{
        name = 'Visual Studio Code'; adapterVersion = 1; restoreMode = 'automatic'; requiresApp = $true
        appKeys = @('winget:microsoft.visualstudiocode'); appName = '^Microsoft Visual Studio Code'
        items = @(
            @{ logical = 'settings.json'; kind = 'file'; base = 'APPDATA'; path = 'Code\User\settings.json'; format = 'jsonc' },
            @{ logical = 'keybindings.json'; kind = 'file'; base = 'APPDATA'; path = 'Code\User\keybindings.json'; format = 'jsonc' },
            @{ logical = 'snippets'; kind = 'folder'; base = 'APPDATA'; path = 'Code\User\snippets'; filePattern = '^[A-Za-z0-9][A-Za-z0-9._ -]{0,80}\.(json|code-snippets)$'; format = 'jsonc' },
            @{ logical = 'extensions.json'; kind = 'extensions'; base = 'USERPROFILE'; path = '.vscode\extensions\extensions.json'; cli = 'vscode' }
        )
        excluded = @('globalStorage and workspaceStorage (machine and workspace state)', 'state.vscdb (holds sign-in tokens)', 'History, CachedData, logs and sync folders (caches)', 'extension folders (reinstalled from the Marketplace instead)')
        prerequisites = 'Visual Studio Code is installed (settings are restored after its installation).'
        verification = 'Every restored file is compared with the backup by SHA-256; extensions are checked with "code --list-extensions".'
        limitations = 'Settings Sync, if you sign in, can overwrite restored settings. Extensions need the Internet. Extension data in globalStorage is not restored.'
    }
    'cursor' = @{
        name = 'Cursor'; adapterVersion = 1; restoreMode = 'automatic'; requiresApp = $true
        appKeys = @('winget:anysphere.cursor'); appName = '^Cursor'
        items = @(
            @{ logical = 'settings.json'; kind = 'file'; base = 'APPDATA'; path = 'Cursor\User\settings.json'; format = 'jsonc' },
            @{ logical = 'keybindings.json'; kind = 'file'; base = 'APPDATA'; path = 'Cursor\User\keybindings.json'; format = 'jsonc' },
            @{ logical = 'snippets'; kind = 'folder'; base = 'APPDATA'; path = 'Cursor\User\snippets'; filePattern = '^[A-Za-z0-9][A-Za-z0-9._ -]{0,80}\.(json|code-snippets)$'; format = 'jsonc' },
            @{ logical = 'extensions.json'; kind = 'extensions'; base = 'USERPROFILE'; path = '.cursor\extensions\extensions.json'; cli = '' }
        )
        excluded = @('globalStorage and workspaceStorage', 'state.vscdb (holds sign-in tokens and AI session state)', 'caches and logs', 'extension folders')
        prerequisites = 'Cursor is installed.'
        verification = 'Every restored file is compared with the backup by SHA-256.'
        limitations = 'Cursor extensions are listed as a manual follow-up: an unattended extension installation for Cursor is not verified. Account sign-in is manual.'
    }
    'windows-terminal' = @{
        name = 'Windows Terminal'; adapterVersion = 1; restoreMode = 'automatic'; requiresApp = $true
        appKeys = @('winget:microsoft.windowsterminal'); appName = ''; appFolder = @{ base = 'LOCALAPPDATA'; path = 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe' }
        items = @(@{ logical = 'settings.json'; kind = 'file'; base = 'LOCALAPPDATA'; path = 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'; format = 'jsonc' })
        excluded = @('state.json (window positions)', 'fragments and dynamic profiles generated on the new computer')
        prerequisites = 'Windows Terminal is installed (included in Windows 11) and registered for the user.'
        verification = 'settings.json is compared with the backup by SHA-256.'
        limitations = 'Profiles that start programs which are not installed on the new computer show an error when opened. Profiles for WSL distributions appear once the distributions are installed.'
    }
    'git' = @{
        name = 'Git (global configuration)'; adapterVersion = 1; restoreMode = 'automatic'; requiresApp = $false
        appKeys = @('winget:git.git'); appName = '^Git( version|$)'
        items = @(@{ logical = 'gitconfig'; kind = 'gitconfig'; base = 'USERPROFILE'; path = '.gitconfig' })
        excluded = @('credential helpers and stored credentials', 'http.* (proxies, extra headers that can carry tokens) and url.* rewrites', 'include/includeIf, safe.directory, hooks and other machine paths', 'signing keys and gpg/ssh program paths', 'shell aliases (!...) and core.editor/core.pager commands: listed for manual re-entry')
        prerequisites = 'None; Git reads the file once it is installed.'
        verification = 'The restored file is compared with the filtered backup by SHA-256.'
        limitations = 'Only portable keys are kept (identity, defaults, aliases without shell commands, colours). Repositories are never cloned.'
    }
    'openssh-client' = @{
        name = 'OpenSSH client (config and known hosts)'; adapterVersion = 1; restoreMode = 'automatic'; requiresApp = $false
        appKeys = @(); appName = ''
        items = @(
            @{ logical = 'config'; kind = 'file'; base = 'USERPROFILE'; path = '.ssh\config'; format = 'text' },
            @{ logical = 'known_hosts'; kind = 'file'; base = 'USERPROFILE'; path = '.ssh\known_hosts'; format = 'text' }
        )
        excluded = @('private and public keys (id_*, *.pem, *.ppk, *.key): copy keys yourself, never through a backup', 'authorized_keys', 'agent sockets')
        prerequisites = 'None (the OpenSSH client is part of Windows 11).'
        verification = 'Each file is compared with the backup by SHA-256.'
        limitations = 'IdentityFile entries still point to keys that you must copy yourself. ProxyCommand lines are restored as written; review them.'
    }
    'putty' = @{
        name = 'PuTTY saved sessions'; adapterVersion = 1; restoreMode = 'automatic'; requiresApp = $true
        appKeys = @('winget:putty.putty'); appName = '^PuTTY'
        items = @(
            @{ logical = 'Sessions.json'; kind = 'registryTree'; path = 'HKCU\Software\SimonTatham\PuTTY\Sessions'; denyValues = '(?i)password|passphrase'; pathValues = '^(PublicKeyFile|DetachedCertificate|LogFileName|BellWaveFile|X11AuthFile)$' },
            @{ logical = 'SshHostKeys.json'; kind = 'registryValues'; path = 'HKCU\Software\SimonTatham\PuTTY\SshHostKeys'; denyValues = '(?i)password|passphrase'; pathValues = '^$' }
        )
        excluded = @('ProxyPassword and every other value whose name contains "password" or "passphrase"', 'private key files (.ppk) referenced by PublicKeyFile', 'Pageant keys')
        prerequisites = 'PuTTY is installed.'
        verification = 'Every restored registry value is read back and compared with the backup.'
        limitations = 'Sessions that use a private key need the key copied by hand; their PublicKeyFile path is reported.'
    }
    'winscp' = @{
        name = 'WinSCP sites (without passwords)'; adapterVersion = 1; restoreMode = 'automatic'; requiresApp = $true
        appKeys = @('winget:winscp.winscp'); appName = '^WinSCP'
        items = @(@{ logical = 'Sessions.json'; kind = 'registryTree'; path = 'HKCU\Software\Martin Prikryl\WinSCP 2\Sessions'; denyValues = '(?i)password|passphrase'; pathValues = '^(PublicKeyFile|DetachedCertificate|TunnelPublicKeyFile|LocalDirectory)$' })
        excluded = @('stored passwords, tunnel and proxy passwords, passphrases (WinSCP obfuscation is reversible, so they are never copied)', 'master password settings', 'WinSCP.ini storage (not supported by this version)')
        prerequisites = 'WinSCP is installed and uses the registry for its configuration (the default).'
        verification = 'Every restored registry value is read back and compared with the backup.'
        limitations = 'Passwords must be entered again. A WinSCP.ini (portable) configuration is reported as unsupported.'
    }
    'notepadpp' = @{
        name = 'Notepad++'; adapterVersion = 1; restoreMode = 'automatic'; requiresApp = $true
        appKeys = @('winget:notepad++.notepad++'); appName = '^Notepad\+\+'; process = 'notepad++'
        items = @(
            @{ logical = 'config.xml'; kind = 'xmlsanitized'; base = 'APPDATA'; path = 'Notepad++\config.xml'; emptyNodes = @('History', 'FindHistory') },
            @{ logical = 'shortcuts.xml'; kind = 'file'; base = 'APPDATA'; path = 'Notepad++\shortcuts.xml'; format = 'xml' },
            @{ logical = 'contextMenu.xml'; kind = 'file'; base = 'APPDATA'; path = 'Notepad++\contextMenu.xml'; format = 'xml' },
            @{ logical = 'stylers.xml'; kind = 'file'; base = 'APPDATA'; path = 'Notepad++\stylers.xml'; format = 'xml' },
            @{ logical = 'userDefineLangs'; kind = 'folder'; base = 'APPDATA'; path = 'Notepad++\userDefineLangs'; filePattern = '^[A-Za-z0-9][A-Za-z0-9._ ()+-]{0,80}\.xml$'; format = 'xml' },
            @{ logical = 'themes'; kind = 'folder'; base = 'APPDATA'; path = 'Notepad++\themes'; filePattern = '^[A-Za-z0-9][A-Za-z0-9._ ()+-]{0,80}\.xml$'; format = 'xml' }
        )
        excluded = @('session.xml (open files of the old computer)', 'backup\ (contents of unsaved documents)', 'recent files and search history inside config.xml', 'plugins and their configuration')
        prerequisites = 'Notepad++ is installed and not running (it rewrites config.xml when it closes).'
        verification = 'Every restored file is compared with the backup by SHA-256.'
        limitations = 'A portable Notepad++ (doLocalConf.xml) keeps its settings next to the program and is not covered. Plugins are not reinstalled.'
    }
    'powershell-profile' = @{
        name = 'PowerShell profiles (for review)'; adapterVersion = 1; restoreMode = 'review'; requiresApp = $false
        appKeys = @(); appName = ''
        items = @(
            @{ logical = 'WindowsPowerShell/Microsoft.PowerShell_profile.ps1'; kind = 'review'; base = 'DOCUMENTS'; path = 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'; format = 'text' },
            @{ logical = 'WindowsPowerShell/profile.ps1'; kind = 'review'; base = 'DOCUMENTS'; path = 'WindowsPowerShell\profile.ps1'; format = 'text' },
            @{ logical = 'PowerShell/Microsoft.PowerShell_profile.ps1'; kind = 'review'; base = 'DOCUMENTS'; path = 'PowerShell\Microsoft.PowerShell_profile.ps1'; format = 'text' },
            @{ logical = 'PowerShell/profile.ps1'; kind = 'review'; base = 'DOCUMENTS'; path = 'PowerShell\profile.ps1'; format = 'text' }
        )
        excluded = @('installed modules (listed in the inventory with the command to install them)', 'profiles that look like they contain a secret (API keys, tokens)')
        prerequisites = 'None.'
        verification = 'The review copies are compared with the backup by SHA-256.'
        limitations = 'Profiles are scripts, so they are never put back into the live profile location: they are restored to Documents\WindowsDeploymentBuilder\Restored settings for review and copied into place by hand.'
    }
    'winget-settings' = @{
        name = 'WinGet settings'; adapterVersion = 1; restoreMode = 'automatic'; requiresApp = $false
        appKeys = @(); appName = ''; appFolder = @{ base = 'LOCALAPPDATA'; path = 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' }
        items = @(@{ logical = 'settings.json'; kind = 'file'; base = 'LOCALAPPDATA'; path = 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json'; format = 'jsonc' })
        excluded = @('sources, pins and the installed package database (machine state)')
        prerequisites = 'App Installer (WinGet) is registered for the user.'
        verification = 'settings.json is compared with the backup by SHA-256.'
        limitations = 'Restored after the applications are installed, so it does not change how this deployment installs them.'
    }
}

# Applications whose settings are deliberately not backed up, with the reason (shown in previews and reports).
$script:WdbUnsupported = [ordered]@{
    'docker-desktop' = 'Docker Desktop settings are machine-bound (VM, WSL and disk paths) and its credentials live in credential helpers; containers, images and volumes are data, not settings.'
    'browsers'       = 'Browser profiles (Chrome, Edge, Firefox) hold passwords, cookies and signed-in sessions; use the browser''s own sync instead.'
    'wireguard'      = 'WireGuard tunnels contain private keys.'
    'tailscale'      = 'Tailscale state is a device identity; sign in again instead.'
    'filezilla'      = 'FileZilla stores site passwords in sitemanager.xml.'
    'game-launchers' = 'Game launchers keep account sessions and large libraries; sign in and let them download again.'
    'office-and-chat' = 'Office, Teams, Slack and Zoom settings follow the account and are restored after sign-in.'
}

# ------------------------------------------------------------------------------------------------
# System adapters (replaced by the scenario tests; nothing else touches the system)
# ------------------------------------------------------------------------------------------------

function Get-WdbNow { [DateTime]::UtcNow }

<# Folder tokens used by the adapters. The scenario tests point them at temporary folders. #>
function Get-WdbEnvironment {
    @{
        USERPROFILE     = $env:USERPROFILE
        APPDATA         = $env:APPDATA
        LOCALAPPDATA    = $env:LOCALAPPDATA
        DOCUMENTS       = [Environment]::GetFolderPath('MyDocuments')
        PROGRAMFILES    = $env:ProgramFiles
        PROGRAMFILESX86 = ${env:ProgramFiles(x86)}
        PROGRAMDATA     = $env:ProgramData
        USERNAME        = $env:USERNAME
    }
}

function Get-WdbOsInfo {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $display = ''
    try { $display = [string] (Get-ItemProperty -LiteralPath $cv -Name DisplayVersion -ErrorAction Stop).DisplayVersion } catch { }
    $arch = $(if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE })
    @{ osName = [string] $os.Caption; osVersion = [string] $os.Version; osBuild = [string] $os.BuildNumber; displayVersion = $display
       architecture = $(switch ($arch) { 'ARM64' { 'arm64' } 'AMD64' { 'x64' } 'x86' { 'x86' } default { 'unknown' } }) }
}

<#
    Installed packages as WinGet reports them. Microsoft.WinGet.Client (Get-WinGetPackage) gives
    names and correlates them with the uninstall records; without it, "winget export" gives the
    identifiers and versions of everything that is available from a source.
#>
function Get-WdbWinGetPackages {
    if (Get-Module -ListAvailable -Name Microsoft.WinGet.Client) {
        try {
            Import-Module Microsoft.WinGet.Client -ErrorAction Stop
            $list = @(Get-WinGetPackage -ErrorAction Stop | ForEach-Object { @{ Name = [string] $_.Name; Id = [string] $_.Id; Version = [string] $_.InstalledVersion; Source = [string] $_.Source } })
            return @{ Method = 'Microsoft.WinGet.Client'; Packages = $list; Message = '' }
        } catch { }
    }
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) { return @{ Method = 'unavailable'; Packages = @(); Message = 'WinGet is not available for this user.' } }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("wdb-winget-export-{0}.json" -f [Guid]::NewGuid().ToString('N'))
    try {
        & $winget.Source export --output $tmp --include-versions --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
        if (-not (Test-Path -LiteralPath $tmp)) { return @{ Method = 'winget export'; Packages = @(); Message = "winget export wrote no file (exit code $LASTEXITCODE)." } }
        $doc = ConvertTo-WdbHashtable ([IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8) | ConvertFrom-Json)
        return @{ Method = 'winget export'; Packages = @(ConvertFrom-WdbWinGetExport $doc); Message = '' }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
}

<# Uninstall records: HKLM (64- and 32-bit views) and HKCU. Values are only read, never run. #>
function Get-WdbUninstallEntries {
    $out = @()
    $sub = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    foreach ($spec in @(@('HKLM', 'Registry64'), @('HKLM', 'Registry32'), @('HKCU', 'Registry64'))) {
        $hive = $(if ($spec[0] -eq 'HKLM') { [Microsoft.Win32.RegistryHive]::LocalMachine } else { [Microsoft.Win32.RegistryHive]::CurrentUser })
        $base = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]$spec[1])
            $root = $base.OpenSubKey($sub)
            if (-not $root) { continue }
            foreach ($name in $root.GetSubKeyNames()) {
                $k = $root.OpenSubKey($name)
                if (-not $k) { continue }
                $v = @{}
                foreach ($n in 'DisplayName', 'DisplayVersion', 'Publisher', 'InstallLocation', 'SystemComponent', 'ParentKeyName', 'ReleaseType', 'WindowsInstaller', 'NoRemove') {
                    $x = $k.GetValue($n, $null)
                    if ($null -ne $x) { $v[$n] = $x }
                }
                $k.Close()
                $out += , @{ Hive = $spec[0]; View = $(if ($spec[1] -eq 'Registry32') { '32' } else { '64' }); KeyName = $name; Values = $v }
            }
            $root.Close()
        } catch { } finally { if ($base) { $base.Close() } }
    }
    return $out
}

function Get-WdbAppxPackages {
    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) { return @() }
    @(Get-AppxPackage -ErrorAction SilentlyContinue | ForEach-Object {
        @{ Name = [string] $_.Name; Publisher = [string] $_.Publisher; Version = [string] $_.Version; Architecture = [string] $_.Architecture
           PackageFullName = [string] $_.PackageFullName; PackageFamilyName = [string] $_.PackageFamilyName; IsFramework = [bool] $_.IsFramework
           IsResourcePackage = [bool] $_.IsResourcePackage; NonRemovable = [bool] $_.NonRemovable; SignatureKind = [string] $_.SignatureKind }
    })
}

<# PEP 514 Python registrations (HKCU, then HKLM). #>
function Get-WdbPythonRegistrations {
    $out = @()
    foreach ($h in @(@('HKCU', 'user'), @('HKLM', 'machine'))) {
        $path = "$($h[0]):\SOFTWARE\Python\PythonCore"
        if (-not (Test-Path -LiteralPath $path)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $path -ErrorAction SilentlyContinue)) {
            $ver = ''
            try { $ver = [string] (Get-ItemProperty -LiteralPath $k.PSPath -Name Version -ErrorAction Stop).Version } catch { }
            $out += , @{ Tag = [string] $k.PSChildName; Version = $ver; Scope = $h[1] }
        }
    }
    return $out
}

function Test-WdbProcessRunning { param([string] $Name) [bool] (Get-Process -Name $Name -ErrorAction SilentlyContinue) }

<# Runs a program with fixed arguments (never a shell string) and a timeout; returns @{ ExitCode; Output }. #>
function Invoke-WdbProcess {
    param([string] $FilePath, [string[]] $Arguments, [int] $TimeoutSeconds = 300)
    foreach ($a in $Arguments) { if ($a -notmatch '^[A-Za-z0-9][A-Za-z0-9._@-]*$|^--[a-z][a-z-]+$') { throw "Refused argument: $a" } }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($FilePath -match '\.cmd$') {
        # A .cmd needs the command interpreter; the arguments are plain tokens checked above.
        $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $psi.Arguments = '/d /c ""' + $FilePath + '" ' + ($Arguments -join ' ') + '"'
    } else {
        $psi.FileName = $FilePath
        $psi.Arguments = $Arguments -join ' '
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) { try { $p.Kill() } catch { }; return @{ ExitCode = $null; Output = '' } }
    return @{ ExitCode = $p.ExitCode; Output = $stdout.Result }
}

# Registry access for the registry adapters (HKCU only).
function Get-WdbRegistryPath { param([string] $Path) if ($Path -notmatch '^HKCU\\') { throw "Only HKCU paths are supported: $Path" }; 'Registry::HKEY_CURRENT_USER\' + $Path.Substring(5) }

function Test-WdbRegistryKey { param([string] $Path) Test-Path -LiteralPath (Get-WdbRegistryPath $Path) }

<# Values of one key: @{ name = @{ type = String|DWord|Other; data } }. #>
function Get-WdbRegistryValues {
    param([string] $Path)
    $out = [ordered]@{}
    $p = Get-WdbRegistryPath $Path
    if (-not (Test-Path -LiteralPath $p)) { return $out }
    $key = Get-Item -LiteralPath $p
    foreach ($n in $key.GetValueNames()) {
        if ($n -eq '') { continue }
        $kind = $key.GetValueKind($n).ToString()
        $data = $key.GetValue($n, $null, 'DoNotExpandEnvironmentNames')
        # DWORDs as unsigned numbers (the registry API returns them signed).
        if ($kind -eq 'DWord') { $data = [int64] [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32] $data), 0) }
        $out[$n] = @{ type = $(if ($kind -in 'String', 'DWord') { $kind } else { 'Other' }); data = $data }
    }
    return $out
}

function Get-WdbRegistrySubKeys {
    param([string] $Path)
    $p = Get-WdbRegistryPath $Path
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    @(Get-ChildItem -LiteralPath $p -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
}

function Set-WdbRegistryValue {
    param([string] $Path, [string] $Name, [string] $Type, $Data)
    $p = Get-WdbRegistryPath $Path
    if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force | Out-Null }
    if ($Type -eq 'DWord') { $Data = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32] [int64] $Data), 0) }
    New-ItemProperty -LiteralPath $p -Name $Name -PropertyType $Type -Value $Data -Force | Out-Null
}

# ------------------------------------------------------------------------------------------------
# Helpers: JSON, hashes, safe files
# ------------------------------------------------------------------------------------------------

function ConvertTo-WdbHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-WdbHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-WdbHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return , @($InputObject | ForEach-Object { ConvertTo-WdbHashtable $_ })
    }
    return $InputObject
}

function ConvertTo-WdbJson { param($Value) ($Value | ConvertTo-Json -Depth 12) -replace "`r`n", "`n" }

function Get-WdbSha256 {
    param([byte[]] $Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('X2') }) } finally { $sha.Dispose() }
}

function Get-WdbFileSha256 { param([string] $Path) Get-WdbSha256 ([IO.File]::ReadAllBytes($Path)) }

function Get-WdbUtf8 { param([string] $Text) (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text) }

function New-WdbId { param([string] $Seed = '') if ($Seed) { (Get-WdbSha256 (Get-WdbUtf8 $Seed)).Substring(0, 16).ToLowerInvariant() } else { [Guid]::NewGuid().ToString('N').Substring(0, 16) } }

<# Writes bytes through a temporary file and replaces the target in one step (no half-written file). #>
function Write-WdbFileAtomic {
    param([string] $Path, [byte[]] $Bytes)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.wdb-tmp"
    $fs = New-Object System.IO.FileStream($tmp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::WriteThrough)
    try { $fs.Write($Bytes, 0, $Bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
    if (Test-Path -LiteralPath $Path) {
        try { [System.IO.File]::Replace($tmp, $Path, $null); return } catch { Remove-Item -LiteralPath $Path -Force }
    }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Test-WdbReparsePoint {
    param([string] $Path)
    $i = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return [bool] ($i -and ($i.Attributes -band [IO.FileAttributes]::ReparsePoint))
}

<# True when $Path is inside $Root (after normalisation) and no folder on the way is a link. #>
function Test-WdbInside {
    param([string] $Root, [string] $Path)
    $r = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $p = [IO.Path]::GetFullPath($Path)
    if (-not $p.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $cur = $p
    while ($cur.Length -ge $r.Length) {
        if ((Test-Path -LiteralPath $cur) -and (Test-WdbReparsePoint $cur)) { return $false }
        $parent = Split-Path -Parent $cur
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }
    return $true
}

<# The destination of an adapter item on this computer, from the trusted definition only. #>
function Resolve-WdbTarget {
    param([hashtable] $Env, [string] $Base, [string] $Relative)
    $root = [string] $Env[$Base]
    if (-not $root) { throw "Folder $Base is not known on this computer." }
    $full = [IO.Path]::GetFullPath((Join-Path $root $Relative))
    if (-not (Test-WdbInside $root $full)) { throw "Refused: $Relative leaves $Base or crosses a link." }
    return $full
}

# ------------------------------------------------------------------------------------------------
# Privacy: secrets and personal paths
# ------------------------------------------------------------------------------------------------

# Rules that mark text as possibly secret. Only the rule name and line number are ever reported.
$script:SecretRules = [ordered]@{
    'private key'       = '-----BEGIN [A-Z ]*PRIVATE KEY-----|PuTTY-User-Key-File-'
    'credential in URL' = '[a-z][a-z0-9+.-]*://[^/\s:@"'']+:[^/\s@"'']+@'
    'named secret'      = '(?i)["'']?[A-Za-z0-9_.-]*(password|passwd|passphrase|secret|api[_-]?key|apikey|access[_-]?token|auth[_-]?token|bearer[_-]?token|client[_-]?secret|private[_-]?key)["'']?\s*[:=]\s*["'']?[^\s"'',;}{]{4,}'
    'token format'      = '\b(ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|gho_[A-Za-z0-9]{30,}|glpat-[A-Za-z0-9_-]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|sk-(ant|proj)-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{40,})'
    'environment secret' = '(?i)\$env:[A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD)[A-Za-z0-9_]*\s*=\s*["''][^"'']{4,}'
}

function Find-WdbSecrets {
    param([string] $Text)
    $found = @()
    $n = 0
    foreach ($line in ($Text -split "`n")) {
        $n++
        foreach ($rule in $script:SecretRules.Keys) {
            if ($line -match $script:SecretRules[$rule]) { $found += , @{ rule = $rule; line = $n }; break }
        }
        if ($found.Count -ge 20) { break }
    }
    return $found
}

<# Replaces this user's folders by tokens so no user name or private path leaves the computer. #>
function Protect-WdbPath {
    param([string] $Path, [hashtable] $Env)
    if (-not $Path) { return '' }
    $p = $Path.Trim().Trim('"')
    foreach ($k in 'LOCALAPPDATA', 'APPDATA', 'DOCUMENTS', 'USERPROFILE', 'PROGRAMFILESX86', 'PROGRAMFILES', 'PROGRAMDATA') {
        $v = [string] $Env[$k]
        if ($v -and $p.StartsWith($v.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { $p = "%$k%" + $p.Substring($v.TrimEnd('\').Length); break }
    }
    $u = [string] $Env['USERNAME']
    if ($u -and $u.Length -ge 2) { $p = [regex]::Replace($p, '(?i)(?<=\\)' + [regex]::Escape($u) + '(?=\\|$)', '%USERNAME%') }
    if ($p.Length -gt 260) { $p = $p.Substring(0, 260) }
    return $p
}

# ------------------------------------------------------------------------------------------------
# Inventory
# ------------------------------------------------------------------------------------------------

<# "winget export" document -> package records (identifiers and versions, no names). #>
function ConvertFrom-WdbWinGetExport {
    param($Doc)
    $out = @()
    foreach ($s in @($Doc['Sources'])) {
        if ($s -isnot [System.Collections.IDictionary]) { continue }
        $src = [string] $s['SourceDetails']['Name']
        foreach ($p in @($s['Packages'])) {
            if ($p -isnot [System.Collections.IDictionary] -or -not $p['PackageIdentifier']) { continue }
            $out += , @{ Name = ''; Id = [string] $p['PackageIdentifier']; Version = [string] $p['Version']; Source = $src }
        }
    }
    return $out
}

function Get-WdbNormalizedName {
    param([string] $Name)
    $n = $Name.ToLowerInvariant() -replace '[\u00ae\u2122\u00a9]', ''
    $n = $n -replace '\((x64|x86|arm64|64-bit|32-bit|[a-z]{2}-[a-z]{2}|user|machine)\)', ' '
    $n = $n -replace '\b(x64|x86|arm64|64-bit|32-bit)\b', ' '
    $n = $n -replace '\s+v?\d+(\.\d+){1,3}([.-][0-9a-z]+)?\s*$', ' '
    ($n -replace '[^a-z0-9+#]+', ' ').Trim()
}

$script:RuntimeName = '(?i)^(microsoft visual c\+\+ \d{4}.*redistributable|microsoft \.net (runtime|desktop runtime|host|framework)|microsoft asp\.net core|microsoft windows desktop runtime|java\(tm\)|eclipse temurin|microsoft visual studio tools for office runtime|microsoft update health tools|windows software development kit|microsoft edge webview2 runtime)'
$script:HardwareName = '(?i)(\bdriver\b|chipset|\bnvidia\b|\bgeforce\b|\bradeon\b|amd software|amd chipset|intel\(r\)|intel .*(graphics|wireless|bluetooth|management engine|rapid storage|serial io|optane)|realtek|synaptics|\belan\b|dolby|maxxaudio|thunderbolt|dell (command|supportassist|update|digital delivery|optimizer)|lenovo (vantage|system update|hotkeys|commercial vantage)|hp (support|smart|sure|system event)|myasus|armoury crate|msi center|logitech (options|g hub)|razer synapse|corsair icue|steelseries gg|samsung (magician|settings)|alienware|killer (network|performance))'
$script:HardwarePublisher = '(?i)^(nvidia|advanced micro devices|amd|intel|realtek|synaptics|elan|dolby|waves|logitech|razer|corsair|steelseries|asustek|micro-star|hp inc|hewlett|dell|lenovo|alienware|rivet networks|qualcomm|broadcom|marvell)'

function Get-WdbAppId { param([string] $Seed) 'app-' + (Get-WdbSha256 (Get-WdbUtf8 $Seed.ToLowerInvariant())).Substring(0, 12).ToLowerInvariant() }

function New-WdbApp {
    param([string] $Seed, [string] $Name, [string] $Source)
    [ordered]@{ inventoryId = (Get-WdbAppId $Seed); displayName = $Name; publisher = ''; version = ''; source = $Source; packageIdentifier = ''; packageSource = ''
                scope = 'unknown'; architecture = 'unknown'; installLocation = ''; detection = @($Source); kind = 'application'; hardware = $false; storeIdentity = ''; notes = @() }
}

function Add-WdbNote { param($App, [string] $Note) if ($App.notes.Count -lt 10 -and $Note -notin $App.notes) { $App.notes = @(@($App.notes) + @($Note.Substring(0, [Math]::Min(300, $Note.Length)))) } }

function Set-WdbHardware {
    param($App)
    if ($App.displayName -match $script:HardwareName -or ($App.publisher -match $script:HardwarePublisher -and $App.displayName -match '(?i)(driver|control|utility|update|center|software|panel|audio|graphics|wireless|bluetooth)')) {
        $App.hardware = $true
        if ($App.kind -eq 'application') { $App.kind = $(if ($App.displayName -match '(?i)\bdriver\b') { 'driver' } else { 'application' }) }
        Add-WdbNote $App 'Hardware-specific software: left for the hardware-aware driver provisioning (Phase 8); not restored to different hardware.'
    }
}

<#
    Builds the normalised application list. Overlapping records are merged:
      - WinGet "ARP\Machine|User\X64|X86\<key>" ids are the uninstall record with that key name;
      - WinGet "MSIX\<full name>" ids are that Store/MSIX package;
      - a WinGet package from a source (winget, msstore) is merged with the uninstall record of the
        same normalised name (WinGet itself correlates them; this only joins the two views);
      - an MSIX package whose name contains a Microsoft Store package's name is merged with it.
    System components, updates and hotfixes, frameworks and resource packages are kept out.
#>
function ConvertTo-WdbApplications {
    param($WinGet, [object[]] $Uninstall, [object[]] $Appx, [object[]] $Portable, [hashtable] $Env, [hashtable] $Os)
    $apps = New-Object System.Collections.ArrayList
    $byReg = @{}; $byAppx = @{}; $skipped = @{ system = 0; updates = 0; frameworks = 0; resources = 0; noName = 0 }
    foreach ($u in @($Uninstall)) {
        $v = $u.Values
        $name = [string] $v['DisplayName']
        if (-not $name.Trim()) { $skipped.noName++; continue }
        if ($v.ContainsKey('ParentKeyName') -or ([string] $v['ReleaseType']) -match '(?i)update|hotfix' -or $u.KeyName -match '^KB\d{6,}$') { $skipped.updates++; continue }
        if ($v.ContainsKey('SystemComponent') -and [int] $v['SystemComponent'] -eq 1) { $skipped.system++; continue }
        $a = New-WdbApp "registry:$($u.Hive):$($u.View):$($u.KeyName)" $name.Trim() 'registry'
        $a.publisher = ([string] $v['Publisher']).Trim()
        $a.version = ([string] $v['DisplayVersion']).Trim()
        $a.scope = $(if ($u.Hive -eq 'HKCU') { 'user' } else { 'machine' })
        $a.architecture = $(if ($u.View -eq '32') { 'x86' } elseif ($u.Hive -eq 'HKCU') { 'unknown' } elseif ($Os.architecture -eq 'arm64') { 'unknown' } else { 'x64' })
        $a.installLocation = Protect-WdbPath ([string] $v['InstallLocation']) $Env
        if ($name -match $script:RuntimeName) { $a.kind = 'runtime' }
        Set-WdbHardware $a
        [void] $apps.Add($a)
        $byReg["$($u.Hive):$($u.View):$($u.KeyName)".ToLowerInvariant()] = $a
    }
    foreach ($x in @($Appx)) {
        if ($x.IsResourcePackage) { $skipped.resources++; continue }
        if ($x.IsFramework) { $skipped.frameworks++; continue }
        $a = New-WdbApp "appx:$($x.PackageFamilyName)" ([string] $x.Name) 'appx'
        $a.publisher = [string] $x.Publisher
        $a.version = [string] $x.Version
        $a.scope = 'user'
        $a.architecture = $(switch ([string] $x.Architecture) { 'X64' { 'x64' } 'X86' { 'x86' } 'Arm64' { 'arm64' } 'Neutral' { 'neutral' } default { 'unknown' } })
        $a.storeIdentity = [string] $x.PackageFamilyName
        if ($x.SignatureKind -eq 'System' -or $x.NonRemovable -or ($x.Name -like 'Microsoft.*' -and $x.Publisher -match 'O=Microsoft Corporation')) { $a.kind = 'system' }
        [void] $apps.Add($a)
        $byAppx[([string] $x.PackageFullName).ToLowerInvariant()] = $a
    }
    $wg = @(if ($WinGet) { @($WinGet.Packages) } else { @() })
    foreach ($w in $wg) {
        $id = [string] $w.Id
        if ($id -match '^ARP\\(Machine|User)\\(X64|X86|Arm64)\\(.+)$') {
            $hive = $(if ($Matches[1] -eq 'User') { 'HKCU' } else { 'HKLM' })
            $view = $(if ($Matches[2] -eq 'X86' -and $hive -eq 'HKLM') { '32' } else { '64' })
            $hit = $byReg["${hive}:${view}:$($Matches[3])".ToLowerInvariant()]
            if ($hit -and 'winget' -notin $hit.detection) { $hit.detection = @(@($hit.detection) + 'winget') }
            continue
        }
        if ($id -match '^MSIX\\(.+)$') {
            $hit = $byAppx[$Matches[1].ToLowerInvariant()]
            if ($hit -and 'winget' -notin $hit.detection) { $hit.detection = @(@($hit.detection) + 'winget') }
            continue
        }
        $src = ([string] $w.Source).ToLowerInvariant()
        $name = $(if ($w.Name) { [string] $w.Name } else { $id })
        $norm = Get-WdbNormalizedName $name
        $merged = $null
        if ($w.Name) {
            $merged = @($apps | Where-Object { $_.source -eq 'registry' -and -not $_.packageIdentifier -and (Get-WdbNormalizedName $_.displayName) -eq $norm -and (-not $w.Version -or -not $_.version -or $_.version -eq $w.Version) } | Select-Object -First 1)
            if (-not $merged -and $src -eq 'msstore') {
                $tail = ($norm -replace ' ', '')
                $merged = @($apps | Where-Object { $_.source -eq 'appx' -and -not $_.packageIdentifier -and $tail.Length -ge 4 -and ((($_.displayName -split '\.')[-1]).ToLowerInvariant() -replace '[^a-z0-9]', '').Contains($tail) } | Select-Object -First 1)
            }
        }
        if ($merged) {
            $a = $merged[0]
            $a.packageIdentifier = $id; $a.packageSource = $src
            if ('winget' -notin $a.detection) { $a.detection = @(@($a.detection) + 'winget') }
            if ($a.source -eq 'appx') { $a.displayName = $name; if ($a.kind -eq 'system') { $a.kind = 'application' } }
            if (-not $a.version) { $a.version = [string] $w.Version }
            continue
        }
        $a = New-WdbApp "${src}:$id" $name $(if ($src -eq 'msstore') { 'msstore' } else { 'winget' })
        $a.packageIdentifier = $id; $a.packageSource = $src; $a.version = [string] $w.Version; $a.detection = @('winget')
        if ($name -match $script:RuntimeName -or $id -match '^Microsoft\.(VCRedist|DotNet)\.') { $a.kind = 'runtime' }
        if (-not $w.Name) { Add-WdbNote $a 'Name not reported (winget export); the WinGet identifier is shown instead.' }
        Set-WdbHardware $a
        [void] $apps.Add($a)
    }
    foreach ($p in @($Portable)) { [void] $apps.Add($p) }
    return @{ Applications = @($apps | Sort-Object { $_.displayName }); Skipped = $skipped }
}

<#
    Opt-in portable detection: only folders named with -PortablePath, two levels deep, never a
    recursive disk search. A folder counts as a portable application when it carries credible
    metadata: a PortableApps.com App\AppInfo\appinfo.ini, or an executable with product and company
    names in its version resource. Installers, uninstallers and updaters are ignored.
#>
function Find-WdbPortableApps {
    param([string[]] $Roots, [hashtable] $Env)
    $out = @()
    foreach ($root in @($Roots | Where-Object { $_ })) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Select-Object -First 200)) {
            if (Test-WdbReparsePoint $dir.FullName) { continue }
            $ini = Join-Path $dir.FullName 'App\AppInfo\appinfo.ini'
            $name = ''; $publisher = ''; $version = ''; $evidence = ''
            if (Test-Path -LiteralPath $ini) {
                foreach ($line in [IO.File]::ReadAllLines($ini)) {
                    if ($line -match '^\s*Name\s*=\s*(.+)$' -and -not $name) { $name = $Matches[1].Trim() }
                    elseif ($line -match '^\s*Publisher\s*=\s*(.+)$' -and -not $publisher) { $publisher = $Matches[1].Trim() }
                    elseif ($line -match '^\s*DisplayVersion\s*=\s*(.+)$' -and -not $version) { $version = $Matches[1].Trim() }
                }
                $evidence = 'PortableApps.com appinfo.ini'
            }
            if (-not $name) {
                $exes = @(Get-ChildItem -LiteralPath $dir.FullName -Filter *.exe -File -ErrorAction SilentlyContinue | Select-Object -First $script:Limits.portableExe | Where-Object { $_.Name -notmatch '(?i)^(unins|setup|install|update|updater|helper|crash|vc_?redist)' })
                $best = $null
                foreach ($e in $exes) {
                    $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($e.FullName)
                    if (-not $vi.ProductName -or -not $vi.CompanyName) { continue }
                    if (-not $best -or ($vi.ProductName -replace '\W', '') -like "*$($dir.Name -replace '\W', '')*") { $best = @{ Exe = $e; Info = $vi } }
                }
                if ($best) {
                    $name = $best.Info.ProductName.Trim(); $publisher = $best.Info.CompanyName.Trim(); $version = [string] $best.Info.ProductVersion
                    $evidence = "version resource of $($best.Exe.Name)"
                }
            }
            if (-not $name) { continue }
            $a = New-WdbApp "portable:$($dir.FullName)" $name 'portable'
            $a.publisher = $publisher; $a.version = $version.Trim(); $a.kind = 'portable'; $a.installLocation = Protect-WdbPath $dir.FullName $Env
            Add-WdbNote $a "Portable program found by $evidence in a folder you named."
            $out += , $a
        }
    }
    return $out
}

function Get-WdbVsCodeExtensions {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $list = @()
    try {
        $doc = ConvertTo-WdbHashtable ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json)
        foreach ($e in @($doc)) {
            if ($e -isnot [System.Collections.IDictionary] -or -not $e.Contains('identifier')) { continue }
            $id = [string] $e['identifier']['id']
            if ($id -match $script:ExtensionId) { $list += , [ordered]@{ id = $id.ToLowerInvariant(); version = $(if ($e.Contains('version')) { [string] $e['version'] } else { '' }) } }
        }
    } catch {
        # Older layouts: <publisher>.<name>-<version> folders next to the file.
        foreach ($d in @(Get-ChildItem -LiteralPath (Split-Path -Parent $Path) -Directory -ErrorAction SilentlyContinue)) {
            if ($d.Name -match '^([A-Za-z0-9][A-Za-z0-9-]*\.[A-Za-z0-9][A-Za-z0-9-]*)-(\d+\.\d+\.\d+.*)$') { $list += , [ordered]@{ id = $Matches[1].ToLowerInvariant(); version = $Matches[2] } }
        }
    }
    return @($list | Sort-Object { $_.id } -Unique)
}

function Get-WdbModules {
    param([hashtable] $Env)
    $out = @()
    $roots = @(@('DOCUMENTS', 'WindowsPowerShell\Modules', 'user'), @('DOCUMENTS', 'PowerShell\Modules', 'user'), @('PROGRAMFILES', 'WindowsPowerShell\Modules', 'machine'), @('PROGRAMFILES', 'PowerShell\Modules', 'machine'))
    foreach ($r in $roots) {
        if (-not $Env[$r[0]]) { continue }
        $dir = Join-Path $Env[$r[0]] $r[1]
        foreach ($m in @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue)) {
            if ($m.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$' -or $m.Name -in 'PackageManagement', 'PowerShellGet', 'Pester', 'PSReadLine', 'Microsoft.PowerShell.Operation.Validation') { continue }
            $versions = @(Get-ChildItem -LiteralPath $m.FullName -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' } | ForEach-Object { $_.Name })
            $repo = ''
            foreach ($info in @(Get-ChildItem -LiteralPath $m.FullName -Filter PSGetModuleInfo.xml -Recurse -Depth 1 -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                if ([IO.File]::ReadAllText($info.FullName) -match '<S N="Repository">([A-Za-z0-9 ._-]{1,64})</S>') { $repo = $Matches[1] }
            }
            $out += , [ordered]@{ name = $m.Name; versions = @($versions | Sort-Object -Unique); scope = $r[2]; repository = $repo }
        }
    }
    return @($out | Sort-Object { $_.name })
}

function Get-WdbRepositories {
    param([string[]] $Roots, [hashtable] $Env)
    $out = @()
    foreach ($root in @($Roots | Where-Object { $_ })) {
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Select-Object -First 500)) {
            $cfg = Join-Path $d.FullName '.git\config'
            if (-not (Test-Path -LiteralPath $cfg -PathType Leaf)) { continue }
            $remote = ''
            $inOrigin = $false
            foreach ($line in [IO.File]::ReadAllLines($cfg)) {
                if ($line -match '^\s*\[') { $inOrigin = $line -match '^\s*\[remote "origin"\]' ; continue }
                if ($inOrigin -and $line -match '^\s*url\s*=\s*(\S+)') { $remote = $Matches[1] -replace '://[^/@\s]+@', '://' }
            }
            $out += , [ordered]@{ name = $d.Name; root = (Protect-WdbPath $root $Env); remote = $(if ($remote -match '^(https?|ssh|git)://|^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:') { $remote } else { '' }) }
        }
    }
    return $out
}

function Get-WdbDevEnvironment {
    param([hashtable] $Env, [object[]] $Applications, [string[]] $RepositoryRoots = @())
    $has = { param([string] $Pattern) [bool] @($Applications | Where-Object { $_.displayName -match $Pattern -or $_.packageIdentifier -match $Pattern }).Count }
    $gitApp = @($Applications | Where-Object { $_.displayName -match '^Git( version|$)' -or $_.packageIdentifier -eq 'Git.Git' } | Select-Object -First 1)
    $node = [ordered]@{ version = ''; managers = @() }
    $nodeApp = @($Applications | Where-Object { $_.displayName -match '^Node\.js' } | Select-Object -First 1)
    if ($nodeApp) { $node.version = [string] $nodeApp[0].version }
    $nvmRoot = Join-Path ([string] $Env['APPDATA']) 'nvm'
    if ($Env['APPDATA'] -and (Test-Path -LiteralPath $nvmRoot)) {
        $node.managers += , [ordered]@{ name = 'nvm-windows'; versions = @(Get-ChildItem -LiteralPath $nvmRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^v\d+\.\d+\.\d+$' } | ForEach-Object { $_.Name }) }
    }
    foreach ($m in @(@('fnm', 'APPDATA', 'fnm\node-versions'), @('volta', 'LOCALAPPDATA', 'Volta\tools\image\node'))) {
        if (-not $Env[$m[1]]) { continue }
        $d = Join-Path $Env[$m[1]] $m[2]
        if (Test-Path -LiteralPath $d) { $node.managers += , [ordered]@{ name = $m[0]; versions = @(Get-ChildItem -LiteralPath $d -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Where-Object { $_ -match '^v?\d+\.\d+\.\d+' }) } }
    }
    $python = @(Get-WdbPythonRegistrations | ForEach-Object { [ordered]@{ tag = [string] $_.Tag; version = [string] $_.Version; scope = [string] $_.Scope } })
    $pyManagers = @()
    if ($Env['USERPROFILE'] -and (Test-Path -LiteralPath (Join-Path $Env['USERPROFILE'] '.pyenv\pyenv-win'))) {
        $pyManagers += , [ordered]@{ name = 'pyenv-win'; versions = @(Get-ChildItem -LiteralPath (Join-Path $Env['USERPROFILE'] '.pyenv\pyenv-win\versions') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) }
    }
    $claude = ''
    if ($Env['USERPROFILE'] -and (Test-Path -LiteralPath (Join-Path $Env['USERPROFILE'] '.local\bin\claude.exe'))) { $claude = 'native' }
    elseif (& $has '^Anthropic\.ClaudeCode$') { $claude = 'winget' }
    elseif ($Env['APPDATA'] -and (Test-Path -LiteralPath (Join-Path $Env['APPDATA'] 'npm\claude.cmd'))) { $claude = 'npm' }
    $vsx = $(if ($Env['USERPROFILE']) { Get-WdbVsCodeExtensions (Join-Path $Env['USERPROFILE'] '.vscode\extensions\extensions.json') } else { $null })
    $csx = $(if ($Env['USERPROFILE']) { Get-WdbVsCodeExtensions (Join-Path $Env['USERPROFILE'] '.cursor\extensions\extensions.json') } else { $null })
    [ordered]@{
        git               = [ordered]@{ installed = [bool] $gitApp; version = $(if ($gitApp) { [string] $gitApp[0].version } else { '' }); globalConfig = [bool] ($Env['USERPROFILE'] -and (Test-Path -LiteralPath (Join-Path $Env['USERPROFILE'] '.gitconfig'))) }
        vscodeExtensions  = @(if ($vsx) { $vsx })
        cursorExtensions  = @(if ($csx) { $csx })
        powershellModules = @(Get-WdbModules $Env)
        python            = $python
        pythonManagers    = $pyManagers
        node              = $node
        docker            = [ordered]@{ installed = (& $has '^Docker Desktop$|^Docker\.DockerDesktop$'); settingsPresent = [bool] ($Env['APPDATA'] -and ((Test-Path -LiteralPath (Join-Path $Env['APPDATA'] 'Docker\settings-store.json')) -or (Test-Path -LiteralPath (Join-Path $Env['APPDATA'] 'Docker\settings.json')))) }
        claudeCode        = [ordered]@{ installed = [bool] $claude; method = $claude }
        repositories      = @(Get-WdbRepositories $RepositoryRoots $Env)
    }
}

<# What each adapter would find on this computer (existence and size only; nothing is read). #>
function Get-WdbSettingsAvailability {
    param([hashtable] $Env, [object[]] $Applications)
    $out = @()
    foreach ($id in $script:WdbAdapters.Keys) {
        $def = $script:WdbAdapters[$id]
        $items = 0; $bytes = 0; $notes = @()
        foreach ($it in $def.items) {
            foreach ($c in @(Get-WdbItemSources $def $it $Env)) { $items++; $bytes += [int64] $c.Size }
        }
        if ($id -eq 'winscp' -and $Env['APPDATA'] -and (Test-Path -LiteralPath (Join-Path $Env['APPDATA'] 'WinSCP.ini'))) { $notes += 'WinSCP.ini found: INI storage is not supported by this version.' }
        $detected = $(if ($def.appName) { [bool] @($Applications | Where-Object { $_.displayName -match $def.appName }).Count } elseif (@($def.appKeys).Count) { [bool] @($Applications | Where-Object { $_.packageSource -and ("$($_.packageSource):$($_.packageIdentifier)".ToLowerInvariant() -in $def.appKeys) }).Count } else { $true })
        $out += , [ordered]@{ adapterId = $id; appDetected = $detected; available = ($items -gt 0); items = $items; bytes = $bytes; notes = @($notes) }
    }
    return $out
}

function New-WdbInventory {
    param([string[]] $PortableRoots = @(), [string[]] $RepositoryRoots = @(), [switch] $SkipWinGet)
    $env0 = Get-WdbEnvironment
    $os = Get-WdbOsInfo
    $warnings = @()
    $wg = $(if ($SkipWinGet) { @{ Method = 'skipped'; Packages = @(); Message = 'WinGet was skipped (-NoWinGet).' } } else { Get-WdbWinGetPackages })
    if ($wg.Message) { $warnings += [string] $wg.Message }
    if ($wg.Method -eq 'winget export') { $warnings += 'Microsoft.WinGet.Client is not installed, so WinGet packages are listed by identifier from "winget export"; only packages available from a source appear.' }
    $portable = @(Find-WdbPortableApps $PortableRoots $env0)
    $r = ConvertTo-WdbApplications $wg @(Get-WdbUninstallEntries) @(Get-WdbAppxPackages) $portable $env0 $os
    $apps = @($r.Applications)
    $now = (Get-WdbNow).ToString('o')
    [ordered]@{
        format         = $script:InventoryFormat
        formatVersion  = 1
        inventoryId    = New-WdbId
        exportedUtc    = $now
        collector      = [ordered]@{ name = 'WdbMigration.ps1'; version = $script:WdbVersion; powershell = $PSVersionTable.PSVersion.ToString(); wingetMethod = [string] $wg.Method }
        source         = [ordered]@{ osName = [string] $os.osName; osVersion = [string] $os.osVersion; osBuild = [string] $os.osBuild; displayVersion = [string] $os.displayVersion; architecture = [string] $os.architecture }
        applications   = $apps
        excludedCounts = [ordered]@{ systemComponents = $r.Skipped.system; updates = $r.Skipped.updates; frameworks = $r.Skipped.frameworks; resourcePackages = $r.Skipped.resources; withoutName = $r.Skipped.noName }
        devEnvironment = Get-WdbDevEnvironment $env0 $apps $RepositoryRoots
        settings       = @(Get-WdbSettingsAvailability $env0 $apps)
        warnings       = @($warnings)
        backup         = $null
    }
}

# ------------------------------------------------------------------------------------------------
# Backup
# ------------------------------------------------------------------------------------------------

<# Source files of one adapter item on this computer: @{ Logical; Path; Size }. #>
function Get-WdbItemSources {
    param([hashtable] $Def, [hashtable] $Item, [hashtable] $Env)
    if ($Item.kind -in 'registryTree', 'registryValues') {
        if (Test-WdbRegistryKey $Item.path) { return @(@{ Logical = $Item.logical; Path = $Item.path; Size = 0; Registry = $true }) }
        return @()
    }
    if (-not $Env[$Item.base]) { return @() }
    $full = Join-Path $Env[$Item.base] $Item.path
    if ($Item.kind -eq 'folder') {
        if (-not (Test-Path -LiteralPath $full -PathType Container) -or (Test-WdbReparsePoint $full)) { return @() }
        $files = @(Get-ChildItem -LiteralPath $full -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $Item.filePattern -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } | Sort-Object Name | Select-Object -First $script:Limits.folderFiles)
        return @($files | ForEach-Object { @{ Logical = "$($Item.logical)/$($_.Name)"; Path = $_.FullName; Size = $_.Length } })
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or (Test-WdbReparsePoint $full)) { return @() }
    return @(@{ Logical = $Item.logical; Path = $full; Size = (Get-Item -LiteralPath $full -Force).Length })
}

$script:GitPortableKeys = '^(user\.(name|email)|core\.(autocrlf|eol|whitespace|longpaths|ignorecase|quotepath|safecrlf)|init\.defaultbranch|pull\.(rebase|ff)|push\.(default|autosetupremote|followtags)|fetch\.(prune|prunetags)|merge\.(conflictstyle|ff)|diff\.(algorithm|colormoved|renames)|rebase\.(autostash|autosquash|updaterefs)|rerere\.enabled|color\.[a-z.]+|alias\.[A-Za-z0-9_-]+|branch\.sort|tag\.sort|column\.ui|help\.autocorrect|commit\.verbose|log\.date|status\.(short|branch|showuntrackedfiles))$'

<# Keeps only portable keys of a .gitconfig; returns @{ Text; Dropped (key names); FollowUps }. #>
function ConvertTo-WdbPortableGitConfig {
    param([string] $Text)
    $section = ''
    $kept = [ordered]@{}
    $dropped = @(); $follow = @()
    foreach ($raw in ($Text -split "`r?`n")) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
        if ($line -match '^\[\s*([A-Za-z0-9.-]+)(\s+"([^"]*)")?\s*\]') {
            $section = $Matches[1].ToLowerInvariant()
            if ($Matches[3]) { $section = "$section.$($Matches[3])" }
            continue
        }
        if ($line -notmatch '^([A-Za-z][A-Za-z0-9-]*)\s*(=\s*(.*))?$') { continue }
        $key = "$section.$($Matches[1].ToLowerInvariant())"
        if ($key -like 'alias.*') { $key = "alias.$($Matches[1])" }
        $value = $(if ($Matches[2]) { $Matches[3].Trim() } else { 'true' })
        if ($key -match '^core\.(editor|pager)$' -or ($key -like 'alias.*' -and $value.TrimStart('"').StartsWith('!'))) { $follow += "git config --global $key $value"; $dropped += $key; continue }
        if ($key -notmatch $script:GitPortableKeys -or @(Find-WdbSecrets $value).Count) { $dropped += $key; continue }
        $sec = $key.Substring(0, $key.LastIndexOf('.'))
        $name = $key.Substring($key.LastIndexOf('.') + 1)
        if (-not $kept.Contains($sec)) { $kept[$sec] = [ordered]@{} }
        $kept[$sec][$name] = $value
    }
    $sb = New-Object System.Text.StringBuilder
    foreach ($sec in $kept.Keys) {
        $head = $(if ($sec -match '^([a-z0-9-]+)\.(.+)$' -and $sec -notmatch '^(color|alias)$') { "[$($Matches[1]) `"$($Matches[2])`"]" } else { "[$sec]" })
        [void] $sb.Append("$head`n")
        foreach ($k in $kept[$sec].Keys) { [void] $sb.Append("`t$k = $($kept[$sec][$k])`n") }
    }
    @{ Text = $sb.ToString(); Dropped = @($dropped | Select-Object -Unique); FollowUps = @($follow) }
}

<# Notepad++-style XML: parse without DTDs, empty the named nodes, return the text. #>
function ConvertTo-WdbSanitizedXml {
    param([string] $Text, [string[]] $EmptyNodes)
    $doc = Read-WdbXml $Text
    foreach ($n in $EmptyNodes) {
        foreach ($node in @($doc.SelectNodes("//$n"))) { while ($node.HasChildNodes) { [void] $node.RemoveChild($node.FirstChild) } }
    }
    $sw = New-Object System.IO.StringWriter
    $doc.Save($sw)
    return $sw.ToString()
}

function Read-WdbXml {
    param([string] $Text)
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create((New-Object System.IO.StringReader($Text)), $settings)
    try { $doc = New-Object System.Xml.XmlDocument; $doc.XmlResolver = $null; $doc.Load($reader); return $doc } finally { $reader.Dispose() }
}

<# Registry export of one item: @{ Json; Dropped; PathValues; Skipped }. #>
function Export-WdbRegistryItem {
    param([hashtable] $Item)
    $dropped = @(); $pathRefs = @(); $skipped = 0
    $filter = {
        param($Values, [string] $Owner)
        $o = [ordered]@{}
        foreach ($n in $Values.Keys) {
            $v = $Values[$n]
            if ($n -match $Item.denyValues) { $script:__dropped += "$Owner\$n"; continue }
            if ($n -notmatch $script:RegistryValueName -or $v.type -eq 'Other') { $script:__skipped++; continue }
            if ($v.type -eq 'String' -and ([string] $v.data).Length -gt $script:Limits.stringValue) { $script:__skipped++; continue }
            if ($v.type -eq 'String' -and @(Find-WdbSecrets ([string] $v.data)).Count) { $script:__dropped += "$Owner\$n"; continue }
            if ($n -match $Item.pathValues -and [string] $v.data) { $script:__paths += "$Owner\$n" }
            $o[$n] = [ordered]@{ type = $v.type; data = $(if ($v.type -eq 'DWord') { [int64] $v.data } else { [string] $v.data }) }
            if ($o.Count -ge $script:Limits.registryValues) { break }
        }
        $o
    }
    $script:__dropped = @(); $script:__skipped = 0; $script:__paths = @()
    $doc = [ordered]@{ format = $script:RegistryFormat; formatVersion = 1; path = $Item.path; kind = $Item.kind }
    if ($Item.kind -eq 'registryTree') {
        $keys = [ordered]@{}
        foreach ($k in @(Get-WdbRegistrySubKeys $Item.path | Select-Object -First $script:Limits.registryKeys)) {
            if ($k -notmatch $script:RegistryKeyName) { $script:__skipped++; continue }
            $keys[$k] = & $filter (Get-WdbRegistryValues "$($Item.path)\$k") $k
        }
        $doc.keys = $keys
    } else {
        $doc.values = & $filter (Get-WdbRegistryValues $Item.path) ''
    }
    @{ Json = (ConvertTo-WdbJson $doc); Dropped = @($script:__dropped); PathValues = @($script:__paths); Skipped = $script:__skipped }
}

<#
    What a backup of the given adapters would contain. Returns per adapter the items with their
    bytes (already filtered), the items left out with the reason, and follow-up notes. Reads only.
#>
function Get-WdbBackupPlan {
    param([string[]] $AdapterIds, [string[]] $IncludeFlagged = @(), [hashtable] $Env = $null)
    if (-not $Env) { $Env = Get-WdbEnvironment }
    $ids = @(if (@($AdapterIds | Where-Object { $_ }).Count) { @($AdapterIds | ForEach-Object { ([string] $_).Split(',') } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ }) } else { @($script:WdbAdapters.Keys) })
    $plan = @()
    $total = 0
    foreach ($id in $ids) {
        if (-not $script:WdbAdapters.Contains($id)) {
            $plan += , @{ Id = $id; Known = $false; Items = @(); Excluded = @(@{ logical = '*'; reason = $(if ($script:WdbUnsupported.Contains($id)) { "Unsupported: $($script:WdbUnsupported[$id])" } else { 'Unknown adapter.' }) }); Notes = @(); Bytes = 0 }
            continue
        }
        $def = $script:WdbAdapters[$id]
        $items = @(); $excluded = @(); $notes = @(); $bytes = 0
        if ($id -eq 'winscp' -and $Env['APPDATA'] -and (Test-Path -LiteralPath (Join-Path $Env['APPDATA'] 'WinSCP.ini'))) { $excluded += @{ logical = 'WinSCP.ini'; reason = 'INI storage is not supported by this version.' } }
        foreach ($it in $def.items) {
            foreach ($src in @(Get-WdbItemSources $def $it $Env)) {
                $logical = [string] $src.Logical
                $text = $null; $extra = @{}
                try {
                    switch ($it.kind) {
                        { $_ -in 'registryTree', 'registryValues' } {
                            $r = Export-WdbRegistryItem $it
                            $text = $r.Json
                            foreach ($d in $r.Dropped) { $excluded += @{ logical = "$logical $d"; reason = 'password or passphrase value (never copied)' } }
                            foreach ($p in $r.PathValues) { $notes += "$($def.name): $p refers to a file on the old computer (for example a private key); copy that file yourself." }
                            if ($r.Skipped) { $notes += "$($def.name): $($r.Skipped) value(s) of an unsupported type or size were skipped." }
                        }
                        default {
                            if ($src.Size -gt $script:Limits.fileBytes) { $excluded += @{ logical = $logical; reason = "larger than $($script:Limits.fileBytes / 1MB) MB (settings files are small; this looks like data)" }; continue }
                            $raw = [IO.File]::ReadAllText($src.Path, [Text.Encoding]::UTF8)
                            switch ($it.kind) {
                                'gitconfig' {
                                    $g = ConvertTo-WdbPortableGitConfig $raw
                                    $text = $g.Text
                                    foreach ($d in $g.Dropped) { $excluded += @{ logical = "gitconfig $d"; reason = 'not portable or may hold a secret (credentials, proxies, machine paths, commands)' } }
                                    foreach ($f in $g.FollowUps) { $notes += "Git: set again by hand if wanted: $f" }
                                }
                                'xmlsanitized' { $text = ConvertTo-WdbSanitizedXml $raw $it.emptyNodes; $notes += "$($def.name): recent files and search history were removed from $logical." }
                                'extensions' {
                                    $list = @(Get-WdbVsCodeExtensions $src.Path)
                                    $text = ConvertTo-WdbJson ([ordered]@{ extensions = @($list) })
                                    $extra.count = $list.Count
                                }
                                default {
                                    if ($it.format -eq 'xml') { [void] (Read-WdbXml $raw) }
                                    if ($it.format -eq 'json') { [void] ($raw | ConvertFrom-Json) }
                                    $text = $raw
                                }
                            }
                        }
                    }
                } catch {
                    $excluded += @{ logical = $logical; reason = "could not be read safely ($($_.Exception.Message.Split("`n")[0]))" }
                    continue
                }
                if ($null -eq $text) { continue }
                $hits = @(Find-WdbSecrets $text)
                $key = "$id/$logical"
                if ($hits.Count -and $key -notin $IncludeFlagged) {
                    $excluded += @{ logical = $logical; reason = "possible secret ($(($hits | ForEach-Object { "$($_.rule), line $($_.line)" } | Select-Object -First 3) -join '; ')): left out; review it and add -IncludeFlagged $key to include it"; flagged = $true }
                    continue
                }
                $bytesOf = Get-WdbUtf8 $text
                if ($bytes + $bytesOf.Length -gt $script:Limits.adapterBytes) { $excluded += @{ logical = $logical; reason = 'the adapter size limit was reached' }; continue }
                $bytes += $bytesOf.Length
                $items += , @{ Logical = $logical; Kind = $it.kind; Bytes = $bytesOf; Flagged = [bool] $hits.Count; Extra = $extra }
            }
        }
        if ($items.Count -eq 0 -and $excluded.Count -eq 0) { $notes += "$($def.name): no settings found on this computer." }
        $total += $bytes
        $plan += , @{ Id = $id; Known = $true; Def = $def; Items = $items; Excluded = $excluded; Notes = $notes; Bytes = $bytes }
    }
    if ($total -gt $script:Limits.backupBytes) { throw "The backup would be larger than $($script:Limits.backupBytes / 1MB) MB; choose fewer adapters." }
    return $plan
}

function Format-WdbBackupPreview {
    param([object[]] $Plan)
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add('Application settings backup - preview (nothing has been copied)')
    $l.Add('================================================================')
    foreach ($p in $Plan) {
        $l.Add('')
        if (-not $p.Known) { $l.Add("[$($p.Id)] not backed up: $($p.Excluded[0].reason)"); continue }
        $l.Add("[$($p.Id)] $($p.Def.name): $($p.Items.Count) item(s), $([Math]::Round($p.Bytes / 1KB, 1)) KB")
        foreach ($i in $p.Items) { $l.Add("    + $($i.Logical)$(if ($i.Flagged) { '   (included by -IncludeFlagged)' })") }
        foreach ($x in $p.Excluded) { $l.Add("    - $($x.logical): $($x.reason)") }
        foreach ($x in @($p.Def.excluded)) { $l.Add("    - never included: $x") }
        foreach ($n in $p.Notes) { $l.Add("    ! $n") }
    }
    $l.Add('')
    $l.Add('Not covered by any adapter (reason):')
    foreach ($k in $script:WdbUnsupported.Keys) { $l.Add("    $k - $($script:WdbUnsupported[$k])") }
    $l.Add('')
    $l.Add('Treat a settings backup as personal data even without secrets: keep it on a drive you control.')
    return ($l -join "`r`n")
}

<# Creates <Destination>\WDB-AppBackup-<stamp>-<id> and returns @{ Path; ManifestSha256; Manifest }. #>
function New-WdbBackup {
    param([object[]] $Plan, [string] $Destination, [string] $InventoryId = '', [switch] $CreateZip)
    if (-not $Destination) { throw 'Choose where the backup goes with -Destination (a local folder, an external drive or a network share).' }
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) { throw "Destination folder not found: $Destination" }
    $now = Get-WdbNow
    $backupId = New-WdbId
    $folder = 'WDB-AppBackup-{0}-{1}' -f $now.ToString('yyyyMMdd-HHmmss'), $backupId.Substring(0, 6)
    $root = Join-Path $Destination $folder
    New-Item -ItemType Directory -Path $root | Out-Null
    $os = Get-WdbOsInfo
    $adapters = @(); $unsupported = @(); $files = 0; $bytes = 0
    foreach ($p in $Plan) {
        if (-not $p.Known) { $unsupported += , [ordered]@{ id = $p.Id; reason = [string] $p.Excluded[0].reason }; continue }
        $entries = @()
        foreach ($i in $p.Items) {
            $rel = "data/$($p.Id)/$($i.Logical)"
            $dst = Join-Path $root ($rel -replace '/', '\')
            Write-WdbFileAtomic $dst $i.Bytes
            $entries += , [ordered]@{ logical = $i.Logical; kind = $i.Kind; path = $rel; size = $i.Bytes.Length; sha256 = (Get-WdbSha256 $i.Bytes) }
            $files++; $bytes += $i.Bytes.Length
        }
        $adapters += , [ordered]@{ id = $p.Id; name = $p.Def.name; adapterVersion = $p.Def.adapterVersion; restoreMode = $p.Def.restoreMode; items = @($entries)
                                   excluded = @($p.Excluded | ForEach-Object { [ordered]@{ logical = [string] $_.logical; reason = [string] $_.reason } }); notes = @($p.Notes) }
    }
    $manifest = [ordered]@{
        format = $script:BackupFormat; formatVersion = 1; backupId = $backupId; folderName = $folder; createdUtc = $now.ToString('o')
        collector = [ordered]@{ name = 'WdbMigration.ps1'; version = $script:WdbVersion }
        source = [ordered]@{ osName = [string] $os.osName; osBuild = [string] $os.osBuild; architecture = [string] $os.architecture }
        inventoryId = $InventoryId
        adapters = @($adapters); unsupported = @($unsupported); totals = [ordered]@{ files = $files; bytes = $bytes }
        notice = 'Application settings only: no passwords, tokens, private keys, credential stores, browser profiles or user documents. Treat it as personal data.'
    }
    $mBytes = Get-WdbUtf8 ((ConvertTo-WdbJson $manifest) + "`n")
    Write-WdbFileAtomic (Join-Path $root $script:ManifestName) $mBytes
    $mHash = Get-WdbSha256 $mBytes
    Write-WdbFileAtomic (Join-Path $root 'SUMMARY.txt') (Get-WdbUtf8 ((Format-WdbBackupPreview $Plan) -replace '\(nothing has been copied\)', "(backup $backupId)"))
    $restore = @"
Restoring this backup
=====================
Backup $backupId, created $($now.ToString('u')), manifest SHA-256 $mHash.

With a Windows Deployment Builder deployment (recommended)
  1. Import the inventory (which references this backup) in Windows Deployment Builder, choose the
     settings to restore, and download the deployment package.
  2. Copy this whole folder to the USB drive as  WindowsDeployment\backups\$folder
     The deployment finds it by this exact name and checks the SHA-256 of every file; settings are
     restored after their applications are installed.
  3. If the folder was not on the drive, run "Deployment recovery" on the new computer and choose
     "Restore application settings from a backup folder".

By hand on an installed computer (as the user whose settings these are)
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File WdbMigration.ps1 -Mode Validate -BackupPath "<this folder>"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File WdbMigration.ps1 -Mode PreviewRestore -BackupPath "<this folder>"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File WdbMigration.ps1 -Mode Restore -BackupPath "<this folder>" [-Conflict keepExisting|restoreBackup|skip]

Nothing in this folder is ever executed. Files are only copied to the locations the adapters of
WdbMigration.ps1 define, after every hash matched.
"@
    Write-WdbFileAtomic (Join-Path $root 'RESTORE-INSTRUCTIONS.txt') (Get-WdbUtf8 ($restore -replace "`r?`n", "`r`n"))
    $zipPath = ''
    if ($CreateZip) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zipPath = "$root.zip"
        [System.IO.Compression.ZipFile]::CreateFromDirectory($root, $zipPath, [System.IO.Compression.CompressionLevel]::NoCompression, $false)
    }
    return @{ Path = $root; Zip = $zipPath; ManifestSha256 = $mHash; Manifest = $manifest; FolderName = $folder }
}

# ------------------------------------------------------------------------------------------------
# Validation
# ------------------------------------------------------------------------------------------------

<# The trusted item rule for a logical name of an adapter, or $null. #>
function Get-WdbItemRule {
    param([hashtable] $Def, [string] $Logical)
    foreach ($it in $Def.items) {
        if ($it.kind -eq 'folder') {
            $parts = $Logical.Split('/')
            if ($parts.Count -eq 2 -and $parts[0] -ceq $it.logical -and $parts[1] -match $it.filePattern) { return @{ Rule = $it; Name = $parts[1] } }
        } elseif ($it.logical -ceq $Logical) { return @{ Rule = $it; Name = '' } }
    }
    return $null
}

<#
    Checks a backup folder. Returns @{ Ok; Problems; Warnings; Manifest; ManifestSha256; Root }.
    Every check must pass; a failure is never ignored by the restore.
#>
function Test-WdbBackup {
    param([string] $Root, [string] $ExpectedManifestSha256 = '')
    $problems = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $res = @{ Ok = $false; Problems = $problems; Warnings = $warnings; Manifest = $null; ManifestSha256 = ''; Root = $Root }
    $mPath = Join-Path $Root $script:ManifestName
    if (-not (Test-Path -LiteralPath $mPath -PathType Leaf)) { $problems.Add("$script:ManifestName is missing."); return $res }
    if ((Test-WdbReparsePoint $Root) -or (Test-WdbReparsePoint $mPath)) { $problems.Add('The backup folder or its manifest is a link; refused.'); return $res }
    $mBytes = [IO.File]::ReadAllBytes($mPath)
    if ($mBytes.Length -gt $script:Limits.manifestBytes) { $problems.Add('The manifest is larger than 1 MB.'); return $res }
    $res.ManifestSha256 = Get-WdbSha256 $mBytes
    if ($ExpectedManifestSha256 -and $res.ManifestSha256 -ne $ExpectedManifestSha256.ToUpperInvariant()) { $problems.Add("The manifest does not match the backup this deployment expects (SHA-256 $($res.ManifestSha256), expected $ExpectedManifestSha256)."); return $res }
    try { $m = ConvertTo-WdbHashtable ((New-Object System.Text.UTF8Encoding($false, $true)).GetString($mBytes).TrimStart([char] 0xFEFF) | ConvertFrom-Json) } catch { $problems.Add('The manifest is not valid JSON.'); return $res }
    if ($m -isnot [System.Collections.IDictionary] -or $m['format'] -ne $script:BackupFormat) { $problems.Add('Not a Windows Deployment Builder application backup.'); return $res }
    if ("$($m['formatVersion'])" -ne '1') { $problems.Add("Unsupported backup format version $($m['formatVersion']) (this tool reads version 1)."); return $res }
    if ([string] $m['backupId'] -notmatch $script:HexId) { $problems.Add('The backup id is invalid.') }
    if ([string] $m['folderName'] -notmatch '^[A-Za-z0-9._-]{1,80}$') { $problems.Add('The folder name in the manifest is invalid.') }
    $res.Manifest = $m
    $listed = @{}
    $total = 0
    foreach ($a in @($m['adapters'])) {
        if ($a -isnot [System.Collections.IDictionary] -or [string] $a['id'] -notmatch $script:AdapterIdPattern) { $problems.Add('An adapter entry is malformed.'); continue }
        $id = [string] $a['id']
        if (-not $script:WdbAdapters.Contains($id)) { $warnings.Add("Adapter '$id' is not known to this version and is skipped."); continue }
        $def = $script:WdbAdapters[$id]
        if ([int] $a['adapterVersion'] -gt [int] $def.adapterVersion) { $warnings.Add("Adapter '$id' was written by a newer version ($($a['adapterVersion'])) and is skipped."); continue }
        $adapterBytes = 0
        foreach ($i in @($a['items'])) {
            if ($i -isnot [System.Collections.IDictionary]) { $problems.Add("$($id): an item is malformed."); continue }
            $logical = [string] $i['logical']; $rel = [string] $i['path']
            if (-not (Get-WdbItemRule $def $logical)) { $problems.Add("$($id): '$logical' is not an item this adapter restores."); continue }
            if ($rel -cne "data/$id/$logical") { $problems.Add("$($id): item path '$rel' is not where this adapter keeps '$logical'."); continue }
            if ($rel -match '\.\.|:|\\|//|^/' ) { $problems.Add("$($id): unsafe path '$rel'."); continue }
            if ([string] $i['sha256'] -notmatch $script:Sha256) { $problems.Add("$($id): '$logical' has no valid SHA-256."); continue }
            if ("$($i['size'])" -notmatch '^\d{1,9}$' -or [int64] $i['size'] -gt $script:Limits.fileBytes) { $problems.Add("$($id): '$logical' has an invalid size."); continue }
            $full = Join-Path $Root ($rel -replace '/', '\')
            if (-not (Test-WdbInside $Root $full)) { $problems.Add("$($id): '$rel' leaves the backup folder or crosses a link."); continue }
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $problems.Add("$($id): '$logical' is missing."); continue }
            $len = (Get-Item -LiteralPath $full -Force).Length
            if ($len -ne [int64] $i['size']) { $problems.Add("$($id): '$logical' has the wrong size ($len, expected $($i['size']))."); continue }
            if ((Get-WdbFileSha256 $full) -ne [string] $i['sha256']) { $problems.Add("$($id): '$logical' does not match its SHA-256 (modified or damaged)."); continue }
            $listed[$rel.ToLowerInvariant()] = $true
            $adapterBytes += $len; $total += $len
        }
        if ($adapterBytes -gt $script:Limits.adapterBytes) { $problems.Add("$($id): larger than the adapter limit.") }
    }
    if ($total -gt $script:Limits.backupBytes) { $problems.Add('The backup is larger than the size limit.') }
    $data = Join-Path $Root 'data'
    if (Test-Path -LiteralPath $data) {
        foreach ($f in @(Get-ChildItem -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue)) {
            if ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) { $problems.Add("Link inside the backup: $($f.Name)."); continue }
            if ($f.PSIsContainer) { continue }
            $rel = 'data/' + $f.FullName.Substring($data.Length + 1).Replace('\', '/')
            if (-not $listed.ContainsKey($rel.ToLowerInvariant())) { $warnings.Add("Unlisted file ignored: $rel") }
        }
    }
    $res.Ok = ($problems.Count -eq 0)
    return $res
}

<#
    Safe extraction of a backup ZIP into a new, empty folder under $Target: every entry name is
    checked (no rooted or drive paths, no "..", no alternate data streams, only the backup layout),
    entry count, total size and compression ratio are bounded, and no entry may land outside.
#>
function Expand-WdbBackupArchive {
    param([string] $ZipPath, [string] $Target)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Target) { throw "Extraction folder already exists: $Target" }
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entries = @($zip.Entries)
        if ($entries.Count -gt $script:Limits.zipEntries) { throw "The archive has $($entries.Count) entries; at most $($script:Limits.zipEntries) are accepted." }
        $sum = 0
        foreach ($e in $entries) {
            $n = $e.FullName.Replace('\', '/')
            if ($n.EndsWith('/')) { continue }
            if ($n -match '^/|^[A-Za-z]:|\.\.|:|[\x00-\x1f]' -or $n.Length -gt 260) { throw "Unsafe entry name in the archive: $n" }
            if ($n -notmatch '^(backup-manifest\.json|SUMMARY\.txt|RESTORE-INSTRUCTIONS\.txt|inventory\.json|data/[a-z0-9][a-z0-9-]{0,31}/[A-Za-z0-9][A-Za-z0-9._ ()+-]{0,99}(/[A-Za-z0-9][A-Za-z0-9._ ()+-]{0,99})?)$') { throw "Unexpected entry in the archive: $n" }
            $sum += $e.Length
            if ($sum -gt $script:Limits.zipBytes) { throw 'The archive expands to more than the size limit.' }
            if ($e.Length -gt 1MB -and $e.CompressedLength -gt 0 -and ($e.Length / $e.CompressedLength) -gt $script:Limits.zipRatio) { throw "Suspicious compression ratio for $n." }
        }
        New-Item -ItemType Directory -Path $Target | Out-Null
        foreach ($e in $entries) {
            $n = $e.FullName.Replace('\', '/')
            if ($n.EndsWith('/')) { continue }
            $dst = [IO.Path]::GetFullPath((Join-Path $Target ($n -replace '/', '\')))
            if (-not (Test-WdbInside $Target $dst)) { throw "Entry would leave the extraction folder: $n" }
            $dir = Split-Path -Parent $dst
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dst, $false)
        }
    } finally { $zip.Dispose() }
    return $Target
}

<# Opens a backup folder or ZIP; a ZIP is extracted into a fresh folder under $WorkRoot first. #>
function Open-WdbBackup {
    param([string] $Path, [string] $WorkRoot = '', [string] $ExpectedManifestSha256 = '')
    if (-not (Test-Path -LiteralPath $Path)) { throw "Backup not found: $Path" }
    $root = $Path
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        if ($Path -notmatch '\.zip$') { throw 'A backup is a folder or a .zip file.' }
        if (-not $WorkRoot) { $WorkRoot = [IO.Path]::GetTempPath() }
        $root = Expand-WdbBackupArchive $Path (Join-Path $WorkRoot ("wdb-backup-" + [Guid]::NewGuid().ToString('N')))
    }
    return Test-WdbBackup $root $ExpectedManifestSha256
}

<# Copies a validated backup (only the files its manifest lists) to $Target and validates the copy. #>
function Copy-WdbBackup {
    param([hashtable] $Validated, [string] $Target)
    if (-not $Validated.Ok) { throw 'Refused: the backup did not validate.' }
    if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Recurse -Force }
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Validated.Root $script:ManifestName) -Destination (Join-Path $Target $script:ManifestName)
    foreach ($a in @($Validated.Manifest['adapters'])) {
        if (-not $script:WdbAdapters.Contains([string] $a['id'])) { continue }
        foreach ($i in @($a['items'])) {
            $rel = ([string] $i['path']) -replace '/', '\'
            $dst = Join-Path $Target $rel
            New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $Validated.Root $rel) -Destination $dst
        }
    }
    $check = Test-WdbBackup $Target $Validated.ManifestSha256
    if (-not $check.Ok) { throw "The copied backup did not validate: $($check.Problems -join ' ')" }
    return $check
}

# ------------------------------------------------------------------------------------------------
# Restore
# ------------------------------------------------------------------------------------------------

function Get-WdbRestoreItems {
    param($ManifestAdapter)
    @($ManifestAdapter['items'] | Where-Object { $_ -is [System.Collections.IDictionary] })
}

function Get-WdbCodeCli {
    param([hashtable] $Env)
    foreach ($c in @(@('LOCALAPPDATA', 'Programs\Microsoft VS Code\bin\code.cmd'), @('PROGRAMFILES', 'Microsoft VS Code\bin\code.cmd'))) {
        if ($Env[$c[0]]) { $p = Join-Path $Env[$c[0]] $c[1]; if (Test-Path -LiteralPath $p -PathType Leaf) { return $p } }
    }
    return $null
}

<# Is the application of an adapter present on this computer? @{ Present; Version }. #>
function Test-WdbAppPresent {
    param([hashtable] $Def, [hashtable] $Env)
    if ($Def.ContainsKey('appFolder') -and $Def.appFolder) {
        $f = $(if ($Env[$Def.appFolder.base]) { Join-Path $Env[$Def.appFolder.base] $Def.appFolder.path } else { '' })
        return @{ Present = [bool] ($f -and (Test-Path -LiteralPath $f)); Version = '' }
    }
    if (-not $Def.appName) { return @{ Present = $true; Version = '' } }
    $hit = @(Get-WdbUninstallEntries | Where-Object { ([string] $_.Values['DisplayName']) -match $Def.appName } | Select-Object -First 1)
    if ($hit) { return @{ Present = $true; Version = [string] $hit[0].Values['DisplayVersion'] } }
    return @{ Present = $false; Version = '' }
}

<# One file item: compares, keeps or writes atomically, keeping the original once. #>
function Restore-WdbFileItem {
    param([string] $Source, [string] $Target, [string] $Conflict, [switch] $WhatIf)
    $want = Get-WdbFileSha256 $Source
    if (Test-Path -LiteralPath $Target -PathType Leaf) {
        if (Test-WdbReparsePoint $Target) { return @{ Action = 'failed'; Detail = 'the destination is a link; not overwritten' } }
        if ((Get-WdbFileSha256 $Target) -eq $want) { return @{ Action = 'identical'; Detail = 'already as in the backup' } }
        if ($Conflict -ne 'restoreBackup') { return @{ Action = 'kept'; Detail = 'existing settings kept (conflict policy keepExisting)' } }
        if ($WhatIf) { return @{ Action = 'replace'; Detail = 'would replace the existing file (the original is kept as .wdb-before-restore)' } }
        $orig = "$Target.wdb-before-restore"
        if (-not (Test-Path -LiteralPath $orig)) { Copy-Item -LiteralPath $Target -Destination $orig }
    } elseif ($WhatIf) { return @{ Action = 'write'; Detail = 'would be created' } }
    Write-WdbFileAtomic $Target ([IO.File]::ReadAllBytes($Source))
    if ((Get-WdbFileSha256 $Target) -ne $want) { return @{ Action = 'failed'; Detail = 'verification after writing failed' } }
    return @{ Action = 'written'; Detail = 'restored and verified' }
}

<# Registry export -> HKCU, value by value, never a password value, verified by reading back. #>
function Restore-WdbRegistryItem {
    param([hashtable] $Rule, [string] $Source, [string] $Conflict, [string] $UndoFile, [switch] $WhatIf)
    $doc = ConvertTo-WdbHashtable ([IO.File]::ReadAllText($Source, [Text.Encoding]::UTF8) | ConvertFrom-Json)
    if ($doc['format'] -ne $script:RegistryFormat -or [string] $doc['path'] -ne $Rule.path -or [string] $doc['kind'] -ne $Rule.kind) { return @{ Action = 'failed'; Detail = 'the registry export does not match this adapter' } }
    $targets = @()
    if ($Rule.kind -eq 'registryTree') {
        foreach ($k in @($doc['keys'].Keys)) { if ($k -match $script:RegistryKeyName) { $targets += , @{ Path = "$($Rule.path)\$k"; Values = $doc['keys'][$k]; Name = $k } } }
    } else { $targets += , @{ Path = $Rule.path; Values = $doc['values']; Name = '' } }
    $written = 0; $identical = 0; $kept = 0; $refused = 0; $undo = [ordered]@{}
    foreach ($t in $targets) {
        $current = Get-WdbRegistryValues $t.Path
        $want = [ordered]@{}
        foreach ($n in @($t.Values.Keys)) {
            $v = $t.Values[$n]
            if ($n -notmatch $script:RegistryValueName -or $n -match $Rule.denyValues -or [string] $v['type'] -notin 'String', 'DWord') { $refused++; continue }
            if ($v['type'] -eq 'String' -and ([string] $v['data']).Length -gt $script:Limits.stringValue) { $refused++; continue }
            if ($v['type'] -eq 'DWord' -and ("$($v['data'])" -notmatch '^\d{1,10}$' -or [int64] $v['data'] -gt 4294967295)) { $refused++; continue }
            $want[$n] = $v
        }
        $same = @($want.Keys | Where-Object { $current.Contains($_) -and "$($current[$_].data)" -eq "$($want[$_]['data'])" }).Count -eq $want.Count
        if ($same) { $identical++; continue }
        if ($Rule.kind -eq 'registryTree' -and $current.Count -gt 0 -and $Conflict -ne 'restoreBackup') { $kept++; continue }
        if ($WhatIf) { $written++; continue }
        $undo[$t.Path] = $current
        foreach ($n in $want.Keys) {
            if ($Rule.kind -eq 'registryValues' -and $current.Contains($n) -and $Conflict -ne 'restoreBackup') { continue }
            $data = $(if ($want[$n]['type'] -eq 'DWord') { [int64] $want[$n]['data'] } else { [string] $want[$n]['data'] })
            Set-WdbRegistryValue $t.Path $n $want[$n]['type'] $data
        }
        $check = Get-WdbRegistryValues $t.Path
        foreach ($n in $want.Keys) { if (-not $check.Contains($n)) { return @{ Action = 'failed'; Detail = "value $n could not be written" } } }
        $written++
    }
    if ($undo.Count -and $UndoFile) { Write-WdbFileAtomic $UndoFile (Get-WdbUtf8 (ConvertTo-WdbJson $undo)) }
    $detail = "$written written, $identical already present, $kept kept$(if ($refused) { ", $refused refused (not allowed)" })"
    $action = $(if ($written -and $kept) { 'partial' } elseif ($written) { $(if ($WhatIf) { 'write' } else { 'written' }) } elseif ($kept) { 'kept' } else { 'identical' })
    return @{ Action = $action; Detail = $detail }
}

<#
    Restores one adapter from a validated backup. Returns
      @{ Outcome = Restored | AlreadyRestored | PartiallyRestored | KeptExisting | SkippedByUser |
                   WaitingForUser | ManualActionRequired | Unsupported | Failed
         Class (failure class); Message; Items = @(@{ logical; action; detail }); FollowUps }
    Idempotent: an item already equal to the backup is not written again.
#>
function Invoke-WdbAdapterRestore {
    param([hashtable] $Validated, [string] $AdapterId, [string] $Conflict = 'keepExisting', [hashtable] $Env = $null, [string] $UndoRoot = '', [switch] $InstallExtensions, [switch] $WhatIf)
    if (-not $Env) { $Env = Get-WdbEnvironment }
    $r = @{ Outcome = 'Failed'; Class = ''; Message = ''; Items = @(); FollowUps = @() }
    if (-not $Validated.Ok) { $r.Class = 'Integrity'; $r.Message = 'The backup did not validate; nothing was restored.'; return $r }
    if (-not $script:WdbAdapters.Contains($AdapterId)) { $r.Outcome = 'Unsupported'; $r.Class = 'Permanent'; $r.Message = "No adapter '$AdapterId' in this version."; return $r }
    $def = $script:WdbAdapters[$AdapterId]
    $ma = @($Validated.Manifest['adapters'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['id'] -eq $AdapterId } | Select-Object -First 1)
    if (-not $ma) { $r.Outcome = 'Unsupported'; $r.Class = 'Permanent'; $r.Message = "The backup has no settings for $($def.name)."; return $r }
    if ($Conflict -eq 'skip') { $r.Outcome = 'SkippedByUser'; $r.Message = 'Skipped (conflict policy skip).'; return $r }
    if ($def.requiresApp) {
        $app = Test-WdbAppPresent $def $Env
        if (-not $app.Present) { $r.Outcome = 'WaitingForUser'; $r.Class = 'User'; $r.Message = "$($def.name) is not installed (or not yet registered for this user)$(if ($AdapterId -eq 'windows-terminal') { '; open Windows Terminal once' }). Its settings are restored once it is."; return $r }
    }
    if ($def.ContainsKey('process') -and $def.process -and (Test-WdbProcessRunning $def.process)) { $r.Outcome = 'WaitingForUser'; $r.Class = 'User'; $r.Message = "Close $($def.name); it rewrites its settings when it exits."; return $r }
    $items = @(); $follow = @()
    foreach ($i in (Get-WdbRestoreItems $ma[0])) {
        $logical = [string] $i['logical']
        $rule = Get-WdbItemRule $def $logical
        $src = Join-Path $Validated.Root (([string] $i['path']) -replace '/', '\')
        try {
            switch ($rule.Rule.kind) {
                { $_ -in 'registryTree', 'registryValues' } {
                    $undo = $(if ($UndoRoot) { Join-Path $UndoRoot "$AdapterId-$($logical -replace '[^A-Za-z0-9.-]', '_').before-restore.json" } else { '' })
                    $x = Restore-WdbRegistryItem $rule.Rule $src $Conflict $undo -WhatIf:$WhatIf
                }
                'extensions' {
                    $list = @((ConvertTo-WdbHashtable ([IO.File]::ReadAllText($src, [Text.Encoding]::UTF8) | ConvertFrom-Json))['extensions'] | ForEach-Object { [string] $_['id'] } | Where-Object { $_ -match $script:ExtensionId })
                    $cli = $(if ($rule.Rule.cli -eq 'vscode') { Get-WdbCodeCli $Env } else { $null })
                    if (-not $list.Count) { $x = @{ Action = 'identical'; Detail = 'no extensions in the backup' } }
                    elseif (-not $cli -or -not $InstallExtensions -or $WhatIf) {
                        $how = $(if ($rule.Rule.cli -eq 'vscode') { 'code --install-extension' } else { "install from the extension view of $($def.name)" })
                        $follow += "$($def.name) extensions to install ($how): $($list -join ', ')"
                        $x = @{ Action = $(if ($WhatIf -and $cli -and $InstallExtensions) { 'write' } else { 'review' }); Detail = "$($list.Count) extension(s)$(if (-not $cli -and $rule.Rule.cli) { '; the VS Code command line was not found' })" }
                    } else {
                        $have = @(([string] (Invoke-WdbProcess $cli @('--list-extensions') 120).Output) -split "`r?`n" | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
                        $missing = @($list | Where-Object { $_.ToLowerInvariant() -notin $have })
                        $failed = @()
                        foreach ($e in $missing) {
                            $p = Invoke-WdbProcess $cli @('--install-extension', $e) 300
                            if ($p.ExitCode -ne 0) { $failed += $e }
                        }
                        if ($failed.Count) { $follow += "$($def.name) extensions that did not install (install them yourself): $($failed -join ', ')" }
                        $x = @{ Action = $(if ($failed.Count -eq $missing.Count -and $missing.Count) { 'failed' } elseif ($failed.Count) { 'partial' } elseif ($missing.Count) { 'written' } else { 'identical' }); Detail = "$($missing.Count - $failed.Count) installed, $($list.Count - $missing.Count) already present, $($failed.Count) failed" }
                    }
                }
                'review' {
                    $target = Resolve-WdbTarget $Env 'DOCUMENTS' ('WindowsDeploymentBuilder\Restored settings\' + ($logical -replace '/', '\'))
                    $x = Restore-WdbFileItem $src $target 'restoreBackup' -WhatIf:$WhatIf
                    $follow += "PowerShell profile $logical was restored for review to $(Protect-WdbPath $target $Env); copy it into place yourself after reading it."
                    if ($x.Action -in 'written', 'identical', 'write') { $x.Action = 'review' }
                }
                default {
                    $rel = $(if ($rule.Name) { Join-Path $rule.Rule.path $rule.Name } else { $rule.Rule.path })
                    $target = Resolve-WdbTarget $Env $rule.Rule.base $rel
                    $x = Restore-WdbFileItem $src $target $Conflict -WhatIf:$WhatIf
                }
            }
        } catch {
            $x = @{ Action = 'failed'; Detail = $_.Exception.Message.Split("`n")[0] }
        }
        $items += , [ordered]@{ logical = $logical; action = [string] $x.Action; detail = [string] $x.Detail }
    }
    foreach ($n in @($ma[0]['notes'])) { if ($n) { $follow += [string] $n } }
    $acts = @($items | ForEach-Object { $_.action })
    $failed = @($acts | Where-Object { $_ -eq 'failed' }).Count
    $done = @($acts | Where-Object { $_ -in 'written', 'write', 'replace' }).Count
    $same = @($acts | Where-Object { $_ -eq 'identical' }).Count
    $kept = @($acts | Where-Object { $_ -eq 'kept' }).Count
    $review = @($acts | Where-Object { $_ -eq 'review' }).Count
    $partial = @($acts | Where-Object { $_ -eq 'partial' }).Count
    $r.Items = $items; $r.FollowUps = @($follow)
    $r.Outcome = $(if ($acts.Count -eq 0) { 'AlreadyRestored' }
                   elseif ($failed -and -not ($done + $same + $partial + $review)) { 'Failed' }
                   elseif ($failed -or $partial -or ($kept -and ($done + $same))) { 'PartiallyRestored' }
                   elseif ($def.restoreMode -eq 'review' -or ($review -and -not $done)) { 'ManualActionRequired' }
                   elseif ($kept) { 'KeptExisting' }
                   elseif ($done) { 'Restored' }
                   else { 'AlreadyRestored' })
    if ($r.Outcome -eq 'Restored' -and $review) { $r.Outcome = 'PartiallyRestored' }
    $r.Class = $(switch ($r.Outcome) { 'Failed' { 'Transient' } 'ManualActionRequired' { 'Manual' } default { '' } })
    $r.Message = "$($def.name): " + (($items | ForEach-Object { "$($_.logical) $($_.action)" }) -join ', ')
    return $r
}

function Format-WdbRestorePreview {
    param([hashtable] $Validated, [object[]] $Results)
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add("Restore preview for backup $($Validated.Manifest['backupId']) (nothing has been changed)")
    foreach ($x in $Results) {
        $l.Add('')
        $l.Add("[$($x.Id)] $($x.Result.Outcome): $($x.Result.Message)")
        foreach ($i in @($x.Result.Items)) { $l.Add("    $($i.action.PadRight(10)) $($i.logical) - $($i.detail)") }
        foreach ($f in @($x.Result.FollowUps)) { $l.Add("    ! $f") }
    }
    return ($l -join "`r`n")
}

# ------------------------------------------------------------------------------------------------
# Main (dot-sourcing only defines the functions)
# ------------------------------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.' -and $Mode -ne 'Library') {
    switch ($Mode) {
        'Inventory' {
            $inv = New-WdbInventory -PortableRoots $PortablePath -RepositoryRoots $RepositoryRoot -SkipWinGet:$NoWinGet
            $path = $(if ($OutFile) { $OutFile } else { Join-Path (Get-Location) ("inventory-{0}.json" -f (Get-WdbNow).ToString('yyyyMMdd-HHmmss')) })
            Write-WdbFileAtomic ([IO.Path]::GetFullPath($path)) (Get-WdbUtf8 ((ConvertTo-WdbJson $inv) + "`n"))
            if ($Json) { ConvertTo-WdbJson @{ inventory = $path; applications = @($inv.applications).Count } }
            else {
                "Inventory written to $path"
                "  $(@($inv.applications).Count) applications ($((@($inv.applications) | Where-Object { $_.packageIdentifier }).Count) with a WinGet or Store identifier); WinGet: $($inv.collector.wingetMethod)"
                "  left out: $($inv.excludedCounts.systemComponents) system components, $($inv.excludedCounts.updates) updates, $($inv.excludedCounts.frameworks) frameworks"
                foreach ($w in $inv.warnings) { "  ! $w" }
                'Nothing was changed on this computer. Import the file in Windows Deployment Builder (Application Backup & Restore).'
            }
            exit 0
        }
        'PreviewBackup' { Format-WdbBackupPreview (Get-WdbBackupPlan $Adapter $IncludeFlagged); exit 0 }
        'Backup' {
            $plan = Get-WdbBackupPlan $Adapter $IncludeFlagged
            $invId = ''
            $inv = $null
            if ($InventoryPath) { $inv = ConvertTo-WdbHashtable ([IO.File]::ReadAllText($InventoryPath, [Text.Encoding]::UTF8) | ConvertFrom-Json); $invId = [string] $inv['inventoryId'] }
            $b = New-WdbBackup $plan $Destination $invId -CreateZip:$Zip
            if ($inv) {
                $inv['backup'] = [ordered]@{ backupId = $b.Manifest.backupId; manifestSha256 = $b.ManifestSha256; folderName = $b.FolderName; createdUtc = $b.Manifest.createdUtc
                                             adapters = @($b.Manifest.adapters | ForEach-Object { [ordered]@{ id = $_.id; items = @($_.items).Count; excluded = @($_.excluded).Count } }) }
                Write-WdbFileAtomic ([IO.Path]::GetFullPath($InventoryPath)) (Get-WdbUtf8 ((ConvertTo-WdbJson $inv) + "`n"))
            }
            "Backup written to $($b.Path)$(if ($b.Zip) { " (and $($b.Zip))" })"
            "  manifest SHA-256 $($b.ManifestSha256); $($b.Manifest.totals.files) file(s), $($b.Manifest.totals.bytes) bytes"
            if ($inv) { "  the inventory $InventoryPath now references this backup" }
            'See SUMMARY.txt for what it contains and what it does not.'
            exit 0
        }
        'Validate' {
            $v = Open-WdbBackup $BackupPath
            if ($Json) { ConvertTo-WdbJson @{ ok = $v.Ok; problems = @($v.Problems); warnings = @($v.Warnings); manifestSha256 = $v.ManifestSha256 } }
            else {
                $(if ($v.Ok) { "Backup is valid (manifest SHA-256 $($v.ManifestSha256))." } else { 'Backup is NOT valid; it will not be restored:' })
                foreach ($p in $v.Problems) { "  x $p" }
                foreach ($w in $v.Warnings) { "  ! $w" }
            }
            if ($v.Ok) { exit 0 } else { exit 3 }
        }
        { $_ -in 'PreviewRestore', 'Restore' } {
            $v = Open-WdbBackup $BackupPath
            if (-not $v.Ok) { 'Backup is NOT valid; nothing was restored:'; foreach ($p in $v.Problems) { "  x $p" }; exit 3 }
            $ids = @(if (@($Adapter | Where-Object { $_ }).Count) { @($Adapter | ForEach-Object { ([string] $_).Split(',') } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ }) } else { @($v.Manifest['adapters'] | ForEach-Object { [string] $_['id'] }) })
            $undo = Join-Path ([string] (Get-WdbEnvironment)['LOCALAPPDATA']) "WindowsDeploymentBuilder\before-restore\$($v.Manifest['backupId'])"
            $results = @()
            foreach ($id in $ids) { $results += , @{ Id = $id; Result = (Invoke-WdbAdapterRestore $v $id $Conflict -UndoRoot $undo -InstallExtensions:($Mode -eq 'Restore') -WhatIf:($Mode -eq 'PreviewRestore')) } }
            if ($Json) { ConvertTo-WdbJson @($results | ForEach-Object { [ordered]@{ adapterId = $_.Id; outcome = $_.Result.Outcome; message = $_.Result.Message; items = @($_.Result.Items); followUps = @($_.Result.FollowUps) } }) }
            else { Format-WdbRestorePreview $v $results }
            if (@($results | Where-Object { $_.Result.Outcome -eq 'Failed' }).Count) { exit 1 }
            exit 0
        }
    }
}
