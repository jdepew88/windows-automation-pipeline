#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Deployment Builder - manual entry point of a deployment package.

.DESCRIPTION
    A USB installation does NOT need this script: the answer file (autounattend.xml) carries the
    deployment and starts it at the first sign-in by itself.

    Use setup.ps1 (through setup.cmd, as administrator) to:
      - verify a package (-Verify): checks every file against deployment-manifest.json, changes
        nothing;
      - run the same deployment on a Windows installation that was not installed with this answer
        file, or restart it after a failed staging: verifies the package, copies it to
        C:\ProgramData\WindowsDeploymentBuilder\Package and starts it from there, so the USB drive
        can be removed afterwards;
      - show the progress (-Status).

    It works from wherever the WindowsDeployment folder is (USB drive or local disk): its own
    location is the package; no drive letter is assumed. It never partitions, formats or writes to
    any disk other than the Windows drive's ProgramData folder, and refuses to run in Windows PE.
#>
[CmdletBinding()]
param(
    [switch] $Verify,
    [switch] $Status,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'scripts\common\DeploymentCommon.ps1')

$manifest = Read-WddManifest (Join-Path $root 'deployment-manifest.json')
Write-Output "Windows Deployment Builder - deployment package $($manifest.packageId) (package format $($manifest.packageVersion))"
Write-Output "Package folder: $root"

if (Test-WddWinPE) {
    Write-Output 'This is Windows Setup (Windows PE). Nothing to do here: Windows Setup reads autounattend.xml from the root of the USB drive by itself.'
    exit 2
}

$check = Test-WddFiles $root $manifest 'Raw'
if (-not $check.Ok) {
    Write-Output "Package verification FAILED: $($check.Missing.Count) missing, $($check.Mismatched.Count) modified file(s). Extract the ZIP again; do not edit files in the package."
    foreach ($m in $check.Missing) { Write-Output "  missing   $m" }
    foreach ($m in $check.Mismatched) { Write-Output "  modified  $m" }
    exit 3
}
Write-Output "Verified all $($check.Checked) file(s) against the manifest."
if ($Verify) { exit 0 }

if ($Status) {
    & (Join-Path $root 'scripts\orchestrator\Show-DeploymentStatus.ps1')
    exit 0
}

$identity = Get-WddIdentity
if (-not $identity.IsAdmin) {
    Write-Output 'Administrator rights are required. Right-click setup.cmd and choose "Run as administrator".'
    exit 4
}

Write-Output ''
Write-Output 'This will start the post-installation deployment on THIS computer:'
foreach ($s in @($manifest.stages) | Sort-Object { [int] $_.order }) {
    $what = if (-not $s.implemented) { 'not implemented in this version' } elseif ($s.enabled) { "runs as $($s.context)" } else { 'not part of this package' }
    Write-Output ('  {0}. {1,-28} {2}' -f $s.order, $s.name, $what)
}
Write-Output 'Windows Update and application installation need an Internet connection; the computer may restart several times.'
Write-Output 'No disk is partitioned or formatted.'
if (-not $Force) {
    $answer = Read-Host 'Type YES to start'
    if ($answer -cne 'YES') { Write-Output 'Cancelled. Nothing was changed.'; exit 5 }
}

& (Join-Path $root 'scripts\bootstrap\Initialize-Deployment.ps1') -SourceMode Package -SourceRoot $root
exit $LASTEXITCODE
