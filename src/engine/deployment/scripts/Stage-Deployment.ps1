#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies the deployment files and copies them to the protected package folder.

.DESCRIPTION
    Called by Initialize-Deployment.ps1 (and by Resume-Deployment.ps1 for a re-check). Run by hand
    it only verifies a package and changes nothing.

    Sources:
      Embedded  The files the answer file extracted during specialize under C:\Windows\Setup\Scripts
                (Administrators-only). Used at the first sign-in of a USB installation, so nothing
                depends on the USB drive still being attached or on its drive letter.
      Package   A WindowsDeployment folder (from the ZIP, on a USB drive or a local disk), identified
                by the location of the script that was started, never by guessing a drive letter.

    Every file is checked against deployment-manifest.json before anything is copied, copied to
    <dataRoot>\Package, and checked again there. Nothing is executed from the source location.
#>
[CmdletBinding()]
param(
    [ValidateSet('Embedded', 'Package')]
    [string] $SourceMode = 'Embedded',
    [string] $SourceRoot = '',
    [string] $EmbeddedRoot = 'C:\Windows\Setup\Scripts'
)

$script:StageMain = $MyInvocation.InvocationName -ne '.'
. (Join-Path $PSScriptRoot '..\common\DeploymentCommon.ps1')

# Files the orchestrator needs before it can launch anything (both modes).
$script:RequiredForStart = @(
    'scripts/common/DeploymentCommon.ps1',
    'scripts/bootstrap/Initialize-Deployment.ps1',
    'scripts/orchestrator/DeploymentOrchestrator.ps1',
    'scripts/finalization/Complete-Deployment.ps1'
)

function Set-WddAcl {
    param([string] $Root)
    # SYSTEM and Administrators full control, Users read and execute, no inherited entries (the
    # same rule as the engine installers). Elevated tasks run scripts from here.
    & icacls.exe $Root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /T /C /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed with exit code $LASTEXITCODE; refusing to run elevated scripts from an unprotected folder." }
}

# Where a manifest file comes from in each mode.
function Get-WddSourcePath {
    param([hashtable] $File, [string] $SourceMode, [string] $SourceRoot, [string] $EmbeddedRoot)
    if ($SourceMode -eq 'Package') { return Join-Path $SourceRoot ($File.path -replace '/', '\') }
    if (-not $File.embedded) { return $null }
    return Join-Path $EmbeddedRoot $File.embedded
}

<#
    Returns @{ Ok; Message; Files (staged manifest paths); Missing; Mismatched }.
#>
function Invoke-WddStage {
    param([hashtable] $Manifest, [string] $ManifestPath, [string] $SourceMode, [string] $SourceRoot, [string] $EmbeddedRoot, [hashtable] $Paths, [switch] $VerifyOnly)
    $files = @(@($Manifest.files) | Where-Object { $SourceMode -eq 'Package' -or $_.embedded })
    $relPaths = @($files | ForEach-Object { $_.path })
    foreach ($r in $script:RequiredForStart) {
        if ($r -notin $relPaths) { return @{ Ok = $false; Message = "The manifest does not list the required file $r."; Files = @(); Missing = @($r); Mismatched = @() } }
    }

    # 1. Verify the source.
    $missing = @(); $mismatched = @()
    foreach ($f in $files) {
        $src = Get-WddSourcePath $f $SourceMode $SourceRoot $EmbeddedRoot
        if (-not $src -or -not (Test-Path -LiteralPath $src -PathType Leaf)) { $missing += $f.path; continue }
        if ($SourceMode -eq 'Package') {
            if ((Get-WddRawHash $src) -ne $f.sha256) { $mismatched += $f.path }
        } elseif ($f.textSha256) {
            if ((Get-WddTextHash $src) -ne $f.textSha256) { $mismatched += $f.path }
        } elseif ($src -like '*.json') {
            try { Get-Content -LiteralPath $src -Raw | ConvertFrom-Json | Out-Null } catch { $mismatched += $f.path }
        }
    }
    if ($missing.Count -or $mismatched.Count) {
        $msg = "Package verification failed ($SourceMode): $($missing.Count) missing, $($mismatched.Count) modified."
        Write-WddLog $msg 'ERROR'
        foreach ($m in $missing) { Write-WddLog "  missing   $m" 'ERROR' }
        foreach ($m in $mismatched) { Write-WddLog "  modified  $m" 'ERROR' }
        return @{ Ok = $false; Message = $msg; Files = @(); Missing = $missing; Mismatched = $mismatched }
    }
    Write-WddLog "Verified $($files.Count) file(s) from the $SourceMode source against manifest $($Manifest.packageId)."
    if ($VerifyOnly) { return @{ Ok = $true; Message = 'Verified (no changes made).'; Files = $relPaths; Missing = @(); Mismatched = @() } }

    # 2. Copy into a fresh package folder; the previous one (from an earlier run) is kept aside.
    $target = $Paths.Package
    if (Test-Path -LiteralPath $target) {
        $previous = "$target.previous"
        if (Test-Path -LiteralPath $previous) { Remove-Item -LiteralPath $previous -Recurse -Force }
        Move-Item -LiteralPath $target -Destination $previous -Force
    }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    foreach ($f in $files) {
        $src = Get-WddSourcePath $f $SourceMode $SourceRoot $EmbeddedRoot
        $dst = Join-Path $target ($f.path -replace '/', '\')
        $dir = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
    Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $target 'deployment-manifest.json') -Force

    # 3. Verify the copies (text hash works for both sources).
    $check = Test-WddFiles $target $Manifest 'Text' $relPaths
    if (-not $check.Ok) {
        $msg = "Staged copy failed verification: $($check.Missing.Count) missing, $($check.Mismatched.Count) modified."
        Write-WddLog $msg 'ERROR'
        return @{ Ok = $false; Message = $msg; Files = @(); Missing = $check.Missing; Mismatched = $check.Mismatched }
    }
    Write-WddLog "Staged $($files.Count) file(s) to $target and verified them."
    @{ Ok = $true; Message = "Staged $($files.Count) file(s)."; Files = $relPaths; Missing = @(); Mismatched = @() }
}

# Dot-sourcing (tests, Initialize-Deployment.ps1) only defines the functions.
if ($script:StageMain) {
    $root = if ($SourceRoot) { $SourceRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    $manifestPath = Join-Path $root 'deployment-manifest.json'
    $manifest = Read-WddManifest $manifestPath
    $paths = Get-WddPaths $manifest.dataRoot
    $r = Invoke-WddStage $manifest $manifestPath $SourceMode $root $EmbeddedRoot $paths -VerifyOnly
    $r.Message
    foreach ($m in $r.Missing) { "  missing   $m" }
    foreach ($m in $r.Mismatched) { "  modified  $m" }
    if (-not $r.Ok) { exit 1 }
    exit 0
}
