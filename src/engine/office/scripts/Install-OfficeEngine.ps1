#Requires -Version 5.1
<#
.SYNOPSIS
    Installs (or removes) the Windows Deployment Builder Office LTSC stage.

.DESCRIPTION
    Run elevated from the folder that contains OfficeEngine.ps1, office-config.json,
    Install_Office.ps1 and the Office configuration XML. The deployment orchestrator runs it once
    from the verified package copy.

    1. Creates <dataRoot> and restricts it: SYSTEM and Administrators full control, Users read.
       The stage runs as SYSTEM, so the folder must not be writable by standard users.
    2. Copies the engine, its configuration, the pinned installer and the XML to <dataRoot>\Office
       and archives a previous run (unless -Resume).
    3. Registers the scheduled task <taskPath><taskName> (SYSTEM, at startup + every 15 minutes).
    4. Starts the task and waits for the engine to check in.

.PARAMETER Uninstall
    Removes the scheduled task. Logs and results are kept.
#>
[CmdletBinding()]
param(
    [switch] $Uninstall,
    [switch] $NoStart,
    [switch] $Resume,
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
    if ($LASTEXITCODE -ne 0) { throw "icacls failed with exit code $LASTEXITCODE on $Root; refusing to run a SYSTEM task from an unprotected folder." }
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
        if ($LASTEXITCODE -ne 0) { throw "icacls /reset failed with exit code $LASTEXITCODE on $($item.FullName); refusing to run a SYSTEM task from an unprotected folder." }
    }
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Install-OfficeEngine.ps1 must run elevated (as Administrator or SYSTEM).'
}

$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'office-config.json') -Raw | ConvertFrom-Json
$dataRoot = $config.dataRoot
$installDir = Join-Path $dataRoot 'Office'
$taskName = $config.taskName
$taskPath = $config.taskPath

if ($Uninstall) {
    Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
    Write-Step "Removed scheduled task $taskPath$taskName (logs and results kept in $installDir)."
    exit 0
}

# 1. Folder and permissions (SIDs, so this works on every display language).
if (-not (Test-Path -LiteralPath $installDir)) { New-Item -ItemType Directory -Path $installDir -Force | Out-Null }
Protect-WdbDataRoot $dataRoot
Write-Step "Secured $dataRoot (SYSTEM/Administrators full control, Users read)."

# 2. Files. A new installation starts a new run; earlier state and results are archived.
if (-not $Resume) {
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    foreach ($name in 'state.json', 'result.json', 'status.json') {
        $p = Join-Path $installDir $name
        if (Test-Path -LiteralPath $p) { Move-Item -LiteralPath $p -Destination (Join-Path $installDir "$name.$stamp.bak") -Force }
    }
    $marker = Join-Path (Join-Path $dataRoot 'state') 'office.done'
    if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
}
$source = (Resolve-Path -LiteralPath $PSScriptRoot).Path.TrimEnd('\')
$target = (Resolve-Path -LiteralPath $installDir).Path.TrimEnd('\')
if ($source -ne $target) {
    foreach ($name in 'OfficeEngine.ps1', 'office-config.json', [string] $config.installer.file, [string] $config.configuration.file) {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $target $name) -Force
    }
}
Write-Step "Office stage files in $target ($($config.product.displayName))."

# 3. Scheduled task. The installer may run for hours; the engine follows it if the task is restarted.
$engine = Join-Path $target 'OfficeEngine.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $powershell -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$engine`""
$atStartup = New-ScheduledTaskTrigger -AtStartup
$atStartup.Delay = 'PT2M'
$days = [Math]::Ceiling(([double] $config.waitFor.applications.maxWaitHours + 24) / 24) + 2
$repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days $days)
$taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 6) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Trigger @($atStartup, $repeat) `
    -Principal $taskPrincipal -Settings $settings -Force `
    -Description 'Windows Deployment Builder: installs the selected Microsoft Office LTSC edition after Windows Update and the applications, verifies it, then removes itself. It never activates Office.' | Out-Null
Write-Step "Registered scheduled task $taskPath$taskName."

if ($NoStart) { Write-Step 'Not started (-NoStart). It runs at the next startup.'; exit 0 }

# 4. Start and confirm the engine is really running.
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
                Write-Step "Office stage is running (phase: $($s.phase)). Log: $(Join-Path $target 'logs\engine.log')"
                exit 0
            }
        } catch { }
    }
}
Write-Step "ERROR: the Office stage did not check in within $CheckInSeconds seconds. The task stays registered and retries at startup and every 15 minutes. Check Task Scheduler history for $taskPath$taskName and $(Join-Path $target 'logs\engine.log')."
exit 1
