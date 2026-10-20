#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Deployment Builder - WinGet availability check and documented repair.

.DESCRIPTION
    Decides whether WinGet (the Windows Package Manager client in Microsoft App Installer) works for
    the current user, and repairs it only when it does not. A healthy WinGet is never reinstalled.

    Check order (Mode Repair):
      1. Context. WinGet is a per-user packaged app; it is not supported in the SYSTEM account, so
         SYSTEM is refused with a clear message. Windows 10 1809 (build 17763) or later is required.
      2. Probe. Resolve winget.exe the documented way (the App Execution Alias on the user's PATH),
         run "winget --version" and "winget source list", and require the default "winget" source.
      3. Registration (documented by Microsoft for "WinGet not available yet after first sign-in"):
           Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
      4. Offline packages, only if supplied: <OfflinePath>\*DesktopAppInstaller*.msixbundle plus its
         dependency packages (*.appx / *.msix). Every file must carry a valid Authenticode signature
         from Microsoft Corporation, or nothing is installed.
      5. Online repair, only if allowed: the Microsoft.WinGet.Client module from the PowerShell
         Gallery and Repair-WinGetPackageManager (Microsoft's documented procedure).
    After every step WinGet is probed again; the first healthy probe ends the procedure.

    Statuses: Healthy (nothing done), Repaired, NeedsRepair (Mode Check only), Unsupported, Failed.

    Mode Check is read-only and changes nothing. The application engine dot-sources this file and
    calls Invoke-WgbBootstrap.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\WinGetBootstrap.ps1 -Mode Check
#>
[CmdletBinding()]
param(
    [ValidateSet('Check', 'Repair')]
    [string] $Mode = 'Check',
    [switch] $NoRegister,
    [switch] $AllowOnlineRepair,
    [string] $OfflinePath = '',
    [string] $MinimumVersion = '1.6.0'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:WgbAppInstallerFamily = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'

# ------------------------------------------------------------------------------------------------
# Adapters: everything that touches the system. Tests replace these functions.
# ------------------------------------------------------------------------------------------------

function Get-WgbContext {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    @{
        User       = $id.Name
        IsSystem   = ($id.User.Value -eq 'S-1-5-18')
        IsElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Build      = [Environment]::OSVersion.Version.Build
    }
}

function Find-WgbWinGet {
    $c = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    return $null
}

function Invoke-WgbWinGetCommand {
    param([string] $Path, [string[]] $Arguments)
    $out = & $Path @Arguments 2>&1 | Out-String
    @{ ExitCode = $LASTEXITCODE; Output = $out }
}

function Get-WgbAppInstaller {
    $p = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if ($p) { return @{ Installed = $true; Version = [string] $p.Version } }
    @{ Installed = $false; Version = '' }
}

function Register-WgbAppInstaller {
    Add-AppxPackage -RegisterByFamilyName -MainPackage $script:WgbAppInstallerFamily -ErrorAction Stop
}

function Find-WgbOfflinePackages {
    param([string] $Directory)
    if (-not $Directory -or -not (Test-Path -LiteralPath $Directory)) { return $null }
    $bundle = Get-ChildItem -LiteralPath $Directory -Filter '*DesktopAppInstaller*.msixbundle' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $bundle) { return $null }
    $deps = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.appx', '.msix' } | ForEach-Object { $_.FullName })
    @{ Bundle = $bundle.FullName; Dependencies = $deps }
}

function Test-WgbSignature {
    param([string] $Path)
    $s = Get-AuthenticodeSignature -LiteralPath $Path
    ($s.Status -eq 'Valid') -and ($null -ne $s.SignerCertificate) -and ($s.SignerCertificate.Subject -match 'O=Microsoft Corporation')
}

function Install-WgbOfflinePackage {
    param([string] $Bundle, [string[]] $Dependencies)
    if (@($Dependencies).Count -gt 0) { Add-AppxPackage -Path $Bundle -DependencyPath $Dependencies -ErrorAction Stop }
    else { Add-AppxPackage -Path $Bundle -ErrorAction Stop }
}

function Invoke-WgbOnlineRepair {
    param([bool] $AllUsers)
    $scope = if ($AllUsers) { 'AllUsers' } else { 'CurrentUser' }
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope $scope -ErrorAction Stop | Out-Null
    Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Force -Scope $scope -ErrorAction Stop
    Import-Module Microsoft.WinGet.Client -ErrorAction Stop
    if ($AllUsers) { Repair-WinGetPackageManager -AllUsers -ErrorAction Stop } else { Repair-WinGetPackageManager -ErrorAction Stop }
}

function Wait-Wgb { param([int] $Seconds) if ($Seconds -gt 0) { Start-Sleep -Seconds $Seconds } }

# ------------------------------------------------------------------------------------------------
# Procedure
# ------------------------------------------------------------------------------------------------

function Test-WgbWinGet {
    param([string] $MinimumVersion = '1.6.0')
    $path = Find-WgbWinGet
    if (-not $path) { return @{ Healthy = $false; Path = $null; Version = ''; Error = 'winget.exe is not on PATH for this user (App Installer not registered yet?).' } }
    try {
        $v = Invoke-WgbWinGetCommand $path @('--version')
        if ($v.ExitCode -ne 0 -or $v.Output -notmatch 'v?(\d+\.\d+\.\d+)') {
            return @{ Healthy = $false; Path = $path; Version = ''; Error = "winget --version failed (exit $($v.ExitCode))." }
        }
        $version = $Matches[1]
        if ([Version] $version -lt [Version] $MinimumVersion) {
            return @{ Healthy = $false; Path = $path; Version = $version; Error = "WinGet $version is older than the required $MinimumVersion." }
        }
        $s = Invoke-WgbWinGetCommand $path @('source', 'list', '--disable-interactivity')
        if ($s.ExitCode -ne 0) { return @{ Healthy = $false; Path = $path; Version = $version; Error = "winget source list failed (exit $($s.ExitCode))." } }
        if ($s.Output -notmatch '(?m)^\s*winget\s') { return @{ Healthy = $false; Path = $path; Version = $version; Error = 'The default "winget" source is missing.' } }
        return @{ Healthy = $true; Path = $path; Version = $version; Error = '' }
    } catch {
        return @{ Healthy = $false; Path = $path; Version = ''; Error = "WinGet could not be started: $($_.Exception.Message)" }
    }
}

<#
    Returns a hashtable: Status, Method, Path, Version, AppInstaller, Message, Steps (list of strings).
#>
function Invoke-WgbBootstrap {
    param(
        [switch] $CheckOnly,
        [bool] $AllowRegister = $true,
        [bool] $AllowOnlineRepair = $false,
        [string] $OfflinePath = '',
        [string] $MinimumVersion = '1.6.0',
        [int] $RegistrationWaitSeconds = 60
    )
    $steps = New-Object System.Collections.ArrayList
    $r = @{ Status = 'Failed'; Method = 'none'; Path = $null; Version = ''; AppInstaller = ''; Message = ''; Steps = $steps }
    $done = {
        param($Probe, $Method)
        $r.Status = $(if ($Method -eq 'existing') { 'Healthy' } else { 'Repaired' })
        $r.Method = $Method; $r.Path = $Probe.Path; $r.Version = $Probe.Version
        $r.Message = $(if ($Method -eq 'existing') { "WinGet $($Probe.Version) works; nothing to repair." } else { "WinGet $($Probe.Version) works after $Method." })
        [void] $steps.Add($r.Message)
        $r
    }

    $ctx = Get-WgbContext
    if ($ctx.IsSystem) {
        $r.Status = 'Unsupported'
        $r.Message = 'WinGet is not supported in the SYSTEM account. Run the application stage as the signed-in user.'
        [void] $steps.Add($r.Message)
        return $r
    }
    if ([int] $ctx.Build -lt 17763) {
        $r.Status = 'Unsupported'
        $r.Message = "WinGet needs Windows 10 1809 (build 17763) or later; this is build $($ctx.Build)."
        [void] $steps.Add($r.Message)
        return $r
    }

    $probe = Test-WgbWinGet $MinimumVersion
    if ($probe.Healthy) { return (& $done $probe 'existing') }
    [void] $steps.Add("Probe: $($probe.Error)")
    $ai = Get-WgbAppInstaller
    $r.AppInstaller = $(if ($ai.Installed) { "registered ($($ai.Version))" } else { 'not registered for this user' })
    [void] $steps.Add("App Installer: $($r.AppInstaller).")
    if ($CheckOnly) {
        $r.Status = 'NeedsRepair'
        $r.Message = $probe.Error
        return $r
    }

    $last = $probe.Error
    if ($AllowRegister) {
        try {
            Register-WgbAppInstaller
            [void] $steps.Add("Registered $($script:WgbAppInstallerFamily).")
            for ($i = 0; $i -le [Math]::Ceiling($RegistrationWaitSeconds / 10); $i++) {
                $probe = Test-WgbWinGet $MinimumVersion
                if ($probe.Healthy) { return (& $done $probe 'registration') }
                Wait-Wgb 10
            }
            $last = $probe.Error
            [void] $steps.Add("After registration: $last")
        } catch {
            $last = "Registration failed: $($_.Exception.Message)"
            [void] $steps.Add($last)
        }
    }

    $offline = Find-WgbOfflinePackages $OfflinePath
    if ($offline) {
        $files = @($offline.Bundle) + @($offline.Dependencies)
        $unsigned = @($files | Where-Object { -not (Test-WgbSignature $_) })
        if ($unsigned.Count -gt 0) {
            $last = "Offline packages not used: no valid Microsoft signature on $(($unsigned | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')."
            [void] $steps.Add($last)
        } else {
            try {
                Install-WgbOfflinePackage $offline.Bundle $offline.Dependencies
                [void] $steps.Add("Installed the offline App Installer package $(Split-Path $offline.Bundle -Leaf).")
                $probe = Test-WgbWinGet $MinimumVersion
                if ($probe.Healthy) { return (& $done $probe 'offline package') }
                $last = "After the offline package: $($probe.Error)"
                [void] $steps.Add($last)
            } catch {
                $last = "Offline package installation failed: $($_.Exception.Message)"
                [void] $steps.Add($last)
            }
        }
    } elseif ($OfflinePath) {
        [void] $steps.Add("No offline App Installer package in $OfflinePath.")
    }

    if ($AllowOnlineRepair) {
        try {
            Invoke-WgbOnlineRepair -AllUsers ([bool] $ctx.IsElevated)
            [void] $steps.Add('Ran Repair-WinGetPackageManager (Microsoft.WinGet.Client from the PowerShell Gallery).')
            $probe = Test-WgbWinGet $MinimumVersion
            if ($probe.Healthy) { return (& $done $probe 'online repair') }
            $last = "After online repair: $($probe.Error)"
            [void] $steps.Add($last)
        } catch {
            $last = "Online repair failed: $($_.Exception.Message)"
            [void] $steps.Add($last)
        }
    }

    $r.Status = 'Failed'
    $r.Message = "WinGet could not be initialized. Last problem: $last"
    [void] $steps.Add($r.Message)
    return $r
}

# Dot-sourcing (the application engine, tests) only defines the functions.
if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-WgbBootstrap -CheckOnly:($Mode -eq 'Check') -AllowRegister (-not $NoRegister) -AllowOnlineRepair ([bool] $AllowOnlineRepair) -OfflinePath $OfflinePath -MinimumVersion $MinimumVersion
    $result.Steps | ForEach-Object { "  $_" }
    "Status: $($result.Status)$(if ($result.Version) { " (WinGet $($result.Version))" })"
    if ($result.Status -in 'Healthy', 'Repaired') { exit 0 }
    exit 1
}
