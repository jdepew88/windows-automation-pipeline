#Requires -Version 5.1
<#
    Phase 6 additions to ProvisioningSim.ps1: the migration fixture (a package that pins a settings
    backup on the simulated USB drive), the package's restore library, and the simulated user
    profile and uninstall records. Dot-source it after ProvisioningSim.ps1.
#>

$migFixture = Join-Path $Fixture 'migration'
if (Test-Path -LiteralPath $migFixture) {
    . (Join-Path $migFixture 'usb\WindowsDeployment\scripts\applications\WdbMigration.ps1') -Mode Library
    Set-StrictMode -Off
}
$script:MigBackupFolder = 'WDB-AppBackup-20261021-120000-a1b2c3'

function Use-MigrationPackage {
    $script:usb = Join-Path $migFixture 'usb'
    $script:pkgRoot = Join-Path $script:usb 'WindowsDeployment'
    $script:manifestPath = Join-Path $script:pkgRoot 'deployment-manifest.json'
    $script:Manifest = Read-WddManifest $script:manifestPath
    $script:UsbBackups = Join-Path $script:pkgRoot 'backups'
    $home0 = Join-Path $script:Tmp 'Users\Alex'
    $script:WdbEnv = @{ USERPROFILE = $home0; APPDATA = "$home0\AppData\Roaming"; LOCALAPPDATA = "$home0\AppData\Local"; DOCUMENTS = "$home0\Documents"; PROGRAMFILES = (Join-Path $script:Tmp 'Program Files'); PROGRAMFILESX86 = (Join-Path $script:Tmp 'Program Files (x86)'); PROGRAMDATA = (Join-Path $script:Tmp 'ProgramData'); USERNAME = 'Alex' }
    New-Item -ItemType Directory -Path $script:WdbEnv.APPDATA, $script:WdbEnv.LOCALAPPDATA -Force | Out-Null
}
function Get-WdbEnvironment { $script:WdbEnv }
function Test-WdbProcessRunning { param([string] $Name) $false }
function Get-WdbUninstallEntries {
    $names = @{ 'Microsoft.VisualStudioCode' = 'Microsoft Visual Studio Code (User)'; 'Git.Git' = 'Git' }
    @($names.Keys | Where-Object { $script:AppSim.Installed[$_] } | ForEach-Object { @{ Hive = 'HKCU'; View = '64'; KeyName = $_; Values = @{ DisplayName = $names[$_]; DisplayVersion = '1.0' } } })
}
function Get-WdaBackupCandidates { param([hashtable] $Config, [string] $FolderName) @(@(Join-Path (Join-Path $Config.dataRoot 'Backup\incoming') $FolderName) + @($script:UsbBackups | Where-Object { $_ } | ForEach-Object { Join-Path $_ $FolderName })) }
function Protect-WdaBackupFolder { param([string] $Path) }
