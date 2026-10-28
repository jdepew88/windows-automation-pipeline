#Requires -Version 5.1
<#
.SYNOPSIS
    Installs (or removes) the Windows Deployment Builder application engine.

.DESCRIPTION
    Run elevated, as the user the applications are for, from the folder that contains
    ApplicationEngine.ps1, WinGetBootstrap.ps1, applications-config.json and winget-packages.json.
    The answer file runs it automatically as the last FirstLogon command (after the Windows Update
    engine installer); it can also be run by hand on an installed machine.

    1. Refuses to run as SYSTEM: WinGet only works in a user's context.
    2. Creates <dataRoot> and restricts it: SYSTEM and Administrators full control, Users read.
    3. Copies the engine, configuration and package list to <dataRoot>\Applications (plus any
       supplied "offline" and "installers" folders) and archives a previous run.
    4. Registers the task <taskPath><taskName> for the current user: runs only while that user is
       signed in, with highest privileges, at sign-in and hourly. No password is stored.
    5. Starts it and waits for the engine to check in.

.PARAMETER Uninstall
    Removes the scheduled task. Logs and results are kept.

.PARAMETER Resume
    Phase 5 (used by the deployment recovery tool): continues the existing run instead of starting a
    new one. The engine files are copied again from this folder (repairing missing or modified
    copies), the task is registered again and started, but state, results and history are kept, so
    nothing that already succeeded is repeated.
#>
[CmdletBinding()]
param(
    [switch] $Uninstall,
    [switch] $Resume,
    [switch] $NoStart,
    [int] $CheckInSeconds = 90
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Step { param([string] $Message) Write-Output ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) }

function Protect-WdbDataRoot {
    param([string] $Root, [string[]] $Grant = @('*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX'))
    # Only the folder itself gets explicit entries; Windows propagates them to everything below.
    # Never icacls /T with (OI)(CI) grants: on files those entries are dropped, which leaves every
    # file protected with no entries at all, unreadable even for SYSTEM and Administrators.
    # No /C either: with it icacls exits with 0 even when it fails.
    & icacls.exe $Root /inheritance:r /grant:r @Grant /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed with exit code $LASTEXITCODE on $Root; refusing to run an elevated task from an unprotected folder." }
    # Repairs what an earlier version left below (files protected with no entries, folders with a
    # protected copy of these entries): they inherit again. Deliberately private folders (settings
    # backups) have other entries and keep them.
    function Get-Entries { param($Acl) (@($Acl.Access | ForEach-Object { "$($_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value)=$([int] $_.FileSystemRights)" }) | Sort-Object) -join ';' }
    $own = Get-Entries (Get-Acl -LiteralPath $Root)
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -Attributes !ReparsePoint -ErrorAction SilentlyContinue)) {
        $damaged = $true
        try {
            $acl = Get-Acl -LiteralPath $item.FullName
            $e = Get-Entries $acl
            $damaged = $acl.AreAccessRulesProtected -and ($e -eq '' -or $e -eq $own)
        } catch { }
        if (-not $damaged) { continue }
        & icacls.exe $item.FullName /reset /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls /reset failed with exit code $LASTEXITCODE on $($item.FullName); refusing to run an elevated task from an unprotected folder." }
    }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if ($identity.User.Value -eq 'S-1-5-18') {
    throw 'Install-ApplicationEngine.ps1 must run as the signed-in user, not SYSTEM: WinGet is not supported in the SYSTEM account.'
}
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Install-ApplicationEngine.ps1 must run elevated (Run as administrator).'
}

$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'applications-config.json') -Raw | ConvertFrom-Json
$dataRoot = $config.dataRoot
$installDir = Join-Path $dataRoot 'Applications'
$taskName = $config.taskName
$taskPath = $config.taskPath

if ($Uninstall) {
    Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
    Write-Step "Removed scheduled task $taskPath$taskName (logs kept in $installDir)."
    exit 0
}

# 1-2. Folder and permissions (SIDs, so this works on every display language).
if (-not (Test-Path -LiteralPath $installDir)) { New-Item -ItemType Directory -Path $installDir -Force | Out-Null }
Protect-WdbDataRoot $dataRoot
Write-Step "Secured $dataRoot (SYSTEM/Administrators full control, Users read)."

# 3. Files. A new installation starts a new run; earlier state and results are archived.
#    -Resume keeps them: the recovery tool has already reopened what should run again.
$stamp = Get-Date -Format 'yyyyMMddHHmmss'
if (-not $Resume) {
    foreach ($name in 'state.json', 'state.json.bak', 'result.json', 'status.json', 'follow-up.txt') {
        $p = Join-Path $installDir $name
        if (Test-Path -LiteralPath $p) { Move-Item -LiteralPath $p -Destination (Join-Path $installDir "$name.$stamp.bak") -Force }
    }
    $marker = Join-Path (Join-Path $dataRoot 'state') 'applications.done'
    if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
}
$source = (Resolve-Path -LiteralPath $PSScriptRoot).Path.TrimEnd('\')
$target = (Resolve-Path -LiteralPath $installDir).Path.TrimEnd('\')
if ($source -ne $target) {
    # WdbMigration.ps1 (Phase 6) is present only when the deployment restores application settings.
    $optional = @('WdbMigration.ps1' | Where-Object { Test-Path -LiteralPath (Join-Path $source $_) })
    foreach ($name in @('ApplicationEngine.ps1', 'WinGetBootstrap.ps1', 'applications-config.json', 'winget-packages.json') + $optional) {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $target $name) -Force
        # The task runs the copy, so the copy must be exactly what was verified.
        if ((Get-FileHash -LiteralPath (Join-Path $source $name) -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath (Join-Path $target $name) -Algorithm SHA256).Hash) {
            throw "The copy of $name in $target does not match its source; refusing to register the task."
        }
    }
    foreach ($dir in 'offline', 'installers') {
        $from = Join-Path $source $dir
        if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination $target -Recurse -Force }
    }
}
Write-Step "Engine files in $target."

# 4. Scheduled task for this user: interactive (no stored password), highest privileges.
$user = $identity.Name
$engine = Join-Path $target 'ApplicationEngine.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $powershell -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$engine`""
$atLogon = New-ScheduledTaskTrigger -AtLogOn -User $user
$atLogon.Delay = 'PT1M'
# Hourly retry while signed in: resumes after "waiting" exits and recovers from crashes.
$hourly = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(30) -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3)
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours ([int] $config.maxRuntimeHours + 2)) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Trigger @($atLogon, $hourly) `
    -Principal $taskPrincipal -Settings $settings -Force `
    -Description 'Windows Deployment Builder: installs the selected WinGet applications after Windows Update, then removes itself.' | Out-Null
Write-Step "Registered scheduled task $taskPath$taskName for $user."

if ($NoStart) { Write-Step 'Not started (-NoStart). It runs at the next sign-in.'; exit 0 }

# 5. Start and confirm the engine is really running.
$statusFile = Join-Path $target 'status.json'
$begin = [DateTime]::UtcNow.AddSeconds(-5)
Start-ScheduledTask -TaskName $taskName -TaskPath $taskPath
for ($i = 0; $i -lt $CheckInSeconds; $i++) {
    Start-Sleep -Seconds 1
    if (Test-Path -LiteralPath $statusFile) {
        try {
            $s = Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json
            $updated = [DateTime]::Parse([string] $s.updatedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
            if ($updated -ge $begin) {
                Write-Step "Application engine is running (phase: $($s.phase)). Log: $(Join-Path $target 'logs\engine.log')"
                exit 0
            }
        } catch { }
    }
}
Write-Step "ERROR: the application engine did not check in within $CheckInSeconds seconds. The task stays registered and retries at sign-in and hourly. Check Task Scheduler history for $taskPath$taskName and $(Join-Path $target 'logs\engine.log')."
exit 1
