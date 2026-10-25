#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the Windows Deployment Builder Application Manager for the signed-in user.

.DESCRIPTION
    Copies the manager to %LOCALAPPDATA%\Programs\WindowsDeploymentBuilder\AppManager and adds
    "Windows Deployment — Application Manager" to the Start menu (and, with -Desktop, the desktop)
    of this user. No administrator rights are needed and nothing is installed for other users.
    Every file is checked against files.json (SHA-256) before it is copied.

      powershell.exe -ExecutionPolicy Bypass -File Install-AppManager.ps1 [-Desktop] [-Start]
      powershell.exe -ExecutionPolicy Bypass -File Install-AppManager.ps1 -Uninstall [-RemoveData]

    -Uninstall removes the program files and shortcuts. The operation history, saved profiles and
    settings (%LOCALAPPDATA%\WindowsDeploymentBuilder\AppManager) are kept unless -RemoveData is given.
    Applications installed with the manager are never removed by this script.
#>
[CmdletBinding()]
param(
    [switch] $Desktop,
    [switch] $Start,
    [switch] $Uninstall,
    [switch] $RemoveData,
    [string] $Destination = '',
    # Where the shortcuts go (default: this user's Start menu and desktop). Used by the tests.
    [string] $ShortcutFolder = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$name = 'Windows Deployment ' + [char]0x2014 + ' Application Manager'
if (-not $Destination) { $Destination = Join-Path $env:LOCALAPPDATA 'Programs\WindowsDeploymentBuilder\AppManager' }
$startMenu = Join-Path $(if ($ShortcutFolder) { $ShortcutFolder } else { [Environment]::GetFolderPath('Programs') }) "$name.lnk"
$desktopLnk = Join-Path $(if ($ShortcutFolder) { Join-Path $ShortcutFolder 'Desktop' } else { [Environment]::GetFolderPath('DesktopDirectory') }) "$name.lnk"
$dataRoot = Join-Path $env:LOCALAPPDATA 'WindowsDeploymentBuilder\AppManager'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($id.User.Value -eq 'S-1-5-18') { Write-Output 'Run this as the user who will use the Application Manager, not as SYSTEM.'; exit 2 }

if ($Uninstall) {
    foreach ($l in $startMenu, $desktopLnk) { if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l -Force } }
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    if ($RemoveData -and (Test-Path -LiteralPath $dataRoot)) { Remove-Item -LiteralPath $dataRoot -Recurse -Force }
    Write-Output "Removed the Application Manager$(if ($RemoveData) { ' and its history, profiles and settings' } else { '. Its history, profiles and settings are kept in ' + $dataRoot })."
    exit 0
}

# Integrity: every packaged file must match files.json, and nothing outside the list is copied.
$here = $PSScriptRoot
$list = Get-Content -LiteralPath (Join-Path $here 'files.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$sha = [Security.Cryptography.SHA256]::Create()
foreach ($f in @($list.files)) {
    $rel = [string] $f.path
    if ($rel -match '(^|[\\/])\.\.([\\/]|$)' -or $rel -match '^[\\/]|:') { throw "Unsafe path in files.json: $rel" }
    $p = Join-Path $here ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Missing file: $rel. Extract the whole ZIP and try again." }
    $h = -join ($sha.ComputeHash([IO.File]::ReadAllBytes($p)) | ForEach-Object { $_.ToString('x2') })
    if ($h -ne ([string] $f.sha256).ToLowerInvariant()) { throw "File changed or damaged: $rel. Download the Application Manager again." }
}

if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
foreach ($f in @($list.files) + @(@{ path = 'files.json' })) {
    $rel = ([string] $f.path) -replace '/', '\'
    $to = Join-Path $Destination $rel
    $dir = Split-Path -Parent $to
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -LiteralPath (Join-Path $here $rel) -Destination $to -Force
}
# Files from a downloaded ZIP carry the "from the internet" mark; these were just verified.
Get-ChildItem -LiteralPath $Destination -Recurse -File | Unblock-File

$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File `"$(Join-Path $Destination 'AppManager.ps1')`""
$shell = New-Object -ComObject WScript.Shell
foreach ($l in @($startMenu) + @(if ($Desktop) { $desktopLnk })) {
    $d = Split-Path -Parent $l
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    $lnk = $shell.CreateShortcut($l)
    $lnk.TargetPath = $ps
    $lnk.Arguments = $arguments
    $lnk.WorkingDirectory = $Destination
    $lnk.Description = 'Browse, install, update and remove applications with WinGet (runs on this computer only).'
    $lnk.IconLocation = "$env:SystemRoot\System32\imageres.dll,152"
    $lnk.Save()
}
Write-Output "Installed for $($id.Name). Start it from the Start menu: $name."
if ($Start) { Start-Process -FilePath $ps -ArgumentList $arguments -WindowStyle Minimized }
exit 0
