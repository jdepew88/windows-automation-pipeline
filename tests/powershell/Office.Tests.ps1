#Requires -Version 5.1
<#
    Scenario tests for the Office LTSC stage (OfficeEngine.ps1) and the activation stage
    (Activation.ps1), using the scripts and configuration of REAL generated packages (office fixture:
    p2024 = Professional Plus 2024 with Microsoft activation, p2021 = Standard 2021 with technician
    activation). Everything Windows would do is simulated: Click-to-Run and MSI Office, the network,
    free space, the installer process and its phases, the installation lock, restarts and the
    licensing service. Nothing is installed or activated, no key is real, and every file is written
    below a temporary folder.

    Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\powershell\Office.Tests.ps1 -Fixture <dir>
#>
param([Parameter(Mandatory = $true)] [string] $Fixture)

$ErrorActionPreference = 'Stop'
$script:OfficeFixture = (Resolve-Path (Join-Path $Fixture 'office')).Path
$script:P24 = Join-Path $script:OfficeFixture 'p2024\WindowsDeployment'
$script:P21 = Join-Path $script:OfficeFixture 'p2021\WindowsDeployment'

. (Join-Path $script:P24 'scripts\office\OfficeEngine.ps1')
. (Join-Path $script:P24 'scripts\common\DeploymentCommon.ps1')
. (Join-Path $script:P24 'scripts\finalization\Activation.ps1')
Set-StrictMode -Version 2.0
${function:Set-WdoStatusReal} = ${function:Set-WdoStatus}

$script:Failures = 0
$script:Passed = 0
function Assert-Equal($Actual, $Expected, [string] $Message) { if ("$Actual" -ne "$Expected") { throw "ASSERT: $Message. Expected <$Expected>, got <$Actual>." } }
function Assert-True($Value, [string] $Message) { if (-not $Value) { throw "ASSERT: $Message" } }
function Test-Case {
    param([string] $Name, [scriptblock] $Body)
    try { & $Body; $script:Passed++; Write-Output "  ok    $Name" }
    catch { $script:Failures++; Write-Output "  FAIL  $Name`n        $($_.Exception.Message)`n        $($_.InvocationInfo.PositionMessage -replace "`n", "`n        ")" }
}

# ------------------------------------------------------------------------------------------------
# Simulated computer for the Office stage
# ------------------------------------------------------------------------------------------------

function Reset-Office {
    param([string] $Package = $script:P24)
    $root = Join-Path ([IO.Path]::GetTempPath()) ('wdo-test-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $now = [DateTime]::new(2026, 11, 25, 9, 0, 0, [DateTimeKind]::Utc)
    $script:S = @{ Root = $root; DataRoot = (Join-Path $root 'ProgramData\WindowsDeploymentBuilder'); Now = $now; Boot = '2026-11-25T08:55:00Z'
                   C2R = @(); Msi = @(); Free = 120.0; Online = $true; LockBusy = $false; RestartPending = $false
                   Starts = New-Object System.Collections.Generic.List[object]; Runs = New-Object System.Collections.Generic.List[hashtable]; Run = $null; Polls = 0
                   Phases = New-Object System.Collections.Generic.List[string]; Stopped = New-Object System.Collections.Generic.List[int]; TaskRemoved = $false; Activity = New-Object System.Collections.Generic.List[string]; FollowRunning = 0 }
    $script:Cfg = Get-WdoConfig (Join-Path $Package 'scripts\office\office-config.json')
    $script:Cfg.dataRoot = $script:S.DataRoot
    $script:Paths = Get-WdoPaths $script:Cfg (Join-Path $Package 'scripts\office')
    foreach ($d in $script:Paths.Root, $script:Paths.Logs) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    $script:WdoLogFile = Join-Path $script:Paths.Logs 'engine.log'
    $script:WdoStatusFile = $script:Paths.Status
    $script:WdoProductName = [string] $script:Cfg.product.displayName
}

<# The next installer runs: each @{ Code; Phases = @('PreparingTool','Downloading','Installing'); Installs = $true }. #>
function Add-Run { param([int] $Code = 0, [string[]] $Phases = @('PreparingTool', 'Downloading', 'Downloading', 'Installing'), [bool] $Installs = $true, [int] $Polls = 0) $script:S.Runs.Add(@{ Code = $Code; Phases = $Phases; Installs = $Installs; Polls = $(if ($Polls) { $Polls } else { $Phases.Count }) }) }
function Set-Marker { param([string] $Name) $d = Join-Path $script:S.DataRoot 'state'; New-Item -ItemType Directory -Path $d -Force | Out-Null; Set-Content -LiteralPath (Join-Path $d $Name) -Value 'x' }
function Get-Result { Read-WdoJson $script:Paths.Result }
function Invoke-Office { Invoke-WdoRun $script:Cfg $script:Paths }

function Get-WdoNow { $script:S.Now }
function Wait-Wdo { param([int] $Seconds) $script:S.Now = $script:S.Now.AddSeconds($Seconds); $script:S.Polls++ }
function Get-WdbBootTime { $script:S.Boot }
function Test-WdbRestartPending { param([string] $DataRoot) $script:S.RestartPending }
function Enter-WdbInstallLock { param([string] $DataRoot, [string] $Owner, [int] $TimeoutSeconds = 0) if ($script:S.LockBusy) { return $null } return 'lock' }
function Exit-WdbInstallLock { param($Lock) }
function Get-WdoInstalledOffice { @{ clickToRun = @($script:S.C2R); version = $(if (@($script:S.C2R).Count) { '16.0.17932.20328' } else { '' }); msi = @($script:S.Msi) } }
function Get-WdoFreeSpaceGB { $script:S.Free }
function Test-WdoNetwork { param([string[]] $Urls) $script:S.Online }
function Unregister-WdoTask { param([hashtable] $Config) $script:S.TaskRemoved = $true }
function Write-WdoEvent { param([int] $EventId, [string] $Message, [string] $EntryType = 'Information') }
function Add-WdbActivity { param([string] $DataRoot, [string] $Source, [string] $Message, [string] $Level = 'info') $script:S.Activity.Add("$Level $Message") }
function Stop-WdoProcessTree { param([int] $ProcessId) $script:S.Stopped.Add($ProcessId); $script:S.Run = $null }
function Set-WdoStatus { param([string] $Phase, [string] $Detail, [hashtable] $State, [string] $LastError = '') $script:S.Phases.Add($Phase); Set-WdoStatusReal $Phase $Detail $State $LastError }
function Start-WdoInstaller {
    param([string] $Script, [string[]] $Arguments)
    $script:S.Starts.Add(@{ Script = $Script; Arguments = @($Arguments) })
    if (-not $script:S.Runs.Count) { throw 'TEST: no simulated installer run is queued.' }
    $script:S.Run = $script:S.Runs[0]; $script:S.Runs.RemoveAt(0); $script:S.Polls = 0
    return @{ Id = 4242; Process = $null }
}
function Get-WdoProcessExit {
    param([hashtable] $Run)
    if ($script:S.FollowRunning -gt 0) { $script:S.FollowRunning--; if ($script:S.FollowRunning -eq 0) { $script:S.C2R = @($script:Cfg.product.productId); return 0 } return $null }
    $r = $script:S.Run
    if (-not $r) { return -1 }
    if ($script:S.Polls -lt $r.Polls) { return $null }
    if ($r.Installs) { $script:S.C2R = @(@($script:S.C2R) + @($script:Cfg.product.productId)) }
    $script:S.Run = $null
    return $r.Code
}
function Get-WdoInstallerActivity { param([string] $WorkDir) $r = $script:S.Run; if ($r -and $script:S.Polls -lt $r.Phases.Count) { return $r.Phases[$script:S.Polls] } return 'Preparing' }

# ------------------------------------------------------------------------------------------------
# Office stage
# ------------------------------------------------------------------------------------------------

Write-Output 'Office LTSC stage (OfficeEngine.ps1)'

Test-Case 'pinned configuration: 2024 ProPlus uses its own XML and -Edition; 2021 Standard its adapted XML via -ConfigPath; never both' {
    Reset-Office $script:P24
    Assert-Equal $script:Cfg.product.productId 'ProPlus2024Volume' 'product'
    Assert-Equal $script:Cfg.product.channel 'PerpetualVL2024' 'channel'
    Assert-Equal $script:Cfg.configuration.file 'config_ProPlus.xml' '2024 configuration'
    Assert-True (@($script:Cfg.installer.arguments) -contains '-Edition') '2024: -Edition'
    Assert-True (-not (Test-Path (Join-Path $script:P24 'scripts\office\config-2021-Standard.xml'))) 'no 2021 file in the 2024 package'
    Assert-Equal $script:Cfg.installer.source.commit '3e2817194aaef0856c5ce8653763c77e24cb3e72' 'installer commit'
    Reset-Office $script:P21
    Assert-Equal $script:Cfg.product.productId 'Standard2021Volume' 'product 2021'
    Assert-Equal $script:Cfg.product.channel 'PerpetualVL2021' 'channel 2021'
    Assert-Equal $script:Cfg.configuration.file 'config-2021-Standard.xml' '2021 configuration'
    Assert-Equal $script:Cfg.configuration.source.commit '548c49142589a9c7c093a4724b9cee1045c0eb2b' 'configuration commit'
    Assert-True (@($script:Cfg.installer.arguments) -contains '-ConfigPath') '2021: -ConfigPath'
    Assert-True (@($script:Cfg.installer.arguments) -contains '-RemovePreviousVersions') '2021 fixture chose MSI removal'
    Assert-True (-not (Test-Path (Join-Path $script:P21 'scripts\office\config_ProPlus.xml')) -and -not (Test-Path (Join-Path $script:P21 'scripts\office\config_standard.xml'))) 'no 2024 file in the 2021 package'
    $xml = [xml] (Get-Content -Raw (Join-Path $script:P21 'scripts\office\config-2021-Standard.xml'))
    Assert-Equal $xml.Configuration.Add.Channel 'PerpetualVL2021' 'XML channel'
    Assert-Equal $xml.Configuration.Add.Product.ID 'Standard2021Volume' 'XML product'
    Assert-True (-not $xml.Configuration.Add.Product.HasAttribute('PIDKEY')) 'no key in the XML'
    Assert-Equal @($xml.SelectNodes("//Property[@Name='AUTOACTIVATE']")).Count 0 'no automatic activation in the XML'
    Assert-Equal @($xml.SelectNodes('//RemoveMSI')).Count 0 'no unconditional MSI removal in the XML'
}

Test-Case 'order: waits for Windows Update, then the applications; nothing is started' {
    Reset-Office
    Invoke-Office | Out-Null
    Assert-Equal (Get-Content -Raw $script:Paths.Status | ConvertFrom-Json).phase 'WaitingForUpdates' 'waits for Windows Update'
    Set-Marker 'windows-update.done'
    Invoke-Office | Out-Null
    Assert-Equal (Get-Content -Raw $script:Paths.Status | ConvertFrom-Json).phase 'WaitingForApplications' 'waits for the applications'
    Assert-Equal $script:S.Starts.Count 0 'no installer'
    Assert-True (-not (Test-Path $script:Paths.Result)) 'no result'
}

Test-Case 'unattended install 2024: phases from the processes, status rewritten while quiet, verified Click-to-Run registration' {
    Reset-Office
    Set-Marker 'windows-update.done'; Set-Marker 'applications.done'
    Add-Run 0 @('PreparingTool', 'Downloading', 'Downloading', 'Downloading', 'Downloading', 'Installing', 'Installing')
    Invoke-Office | Out-Null
    $r = Get-Result
    Assert-Equal $r.status 'Succeeded' 'result'
    Assert-True $r.verified 'verified'
    Assert-True (-not $r.activated) 'never activated by the stage'
    Assert-Equal $script:S.Starts.Count 1 'one installer run'
    $a = @($script:S.Starts[0].Arguments)
    Assert-True ($a -contains '-Unattended' -and $a -contains 'ProPlus' -and $a -contains '-WorkingDirectory' -and $a -contains '-LogDirectory') "arguments: $($a -join ' ')"
    Assert-True (-not ($a -contains '-AcceptEula')) 'never accepts the license terms for the user'
    foreach ($p in 'PreparingTool', 'Downloading', 'Installing', 'Verifying') { Assert-True ($script:S.Phases -contains $p) "phase $p reported" }
    Assert-True (@($script:S.Phases | Where-Object { $_ -eq 'Downloading' }).Count -ge 4) 'a quiet download keeps rewriting its status'
    Assert-True $script:S.TaskRemoved 'task removed'
    Assert-True (Test-Path (Join-Path $script:S.DataRoot 'state\office.done')) 'marker'
}

Test-Case '2021 Standard: runs the pinned installer with the adapted 2021 configuration and MSI removal' {
    Reset-Office $script:P21
    Set-Marker 'windows-update.done'; Set-Marker 'applications.done'
    $script:S.Msi = @('Microsoft Office Professional Plus 2016')
    Add-Run 0
    Invoke-Office | Out-Null
    $a = @($script:S.Starts[0].Arguments)
    Assert-True ($a -contains '-ConfigPath' -and @($a | Where-Object { $_ -like '*config-2021-Standard.xml' }).Count -eq 1) "2021 configuration passed: $($a -join ' ')"
    Assert-True ($a -contains '-RemovePreviousVersions') 'MSI removal only because it was chosen'
    Assert-Equal (Get-Result).status 'Succeeded' 'installed'
}

Test-Case 'existing Office: the same product is verified, not reinstalled' {
    Reset-Office
    Set-Marker 'windows-update.done'; Set-Marker 'applications.done'
    $script:S.C2R = @('ProPlus2024Volume')
    Invoke-Office | Out-Null
    $r = Get-Result
    Assert-Equal $r.status 'Succeeded' 'result'
    Assert-True $r.alreadyInstalled 'already installed'
    Assert-Equal $script:S.Starts.Count 0 'nothing reinstalled'
}

Test-Case 'conflicts: other Click-to-Run Office or MSI Office (removal not chosen) stop with a follow-up; nothing is removed or installed' {
    Reset-Office
    Set-Marker 'windows-update.done'; Set-Marker 'applications.done'
    $script:S.C2R = @('O365ProPlusRetail')
    Invoke-Office | Out-Null
    $r = Get-Result
    Assert-Equal $r.status 'CompletedWithFollowUp' 'Click-to-Run conflict'
    Assert-True ($r.reason -match 'O365ProPlusRetail' -and $r.reason -match 'Nothing was removed') $r.reason
    Assert-Equal $script:S.Starts.Count 0 'not installed next to it'
    Reset-Office
    Set-Marker 'windows-update.done'; Set-Marker 'applications.done'
    $script:S.Msi = @('Microsoft Office Standard 2013')
    Invoke-Office | Out-Null
    Assert-Equal (Get-Result).status 'CompletedWithFollowUp' 'MSI conflict without the removal choice'
    Assert-Equal $script:S.Starts.Count 0 'MSI conflict: nothing installed'
}

Test-Case 'exit code 0 is not proof: an unregistered product is retried once, then Failed' {
    Reset-Office
    Set-Marker 'windows-update.done'; Set-Marker 'applications.done'
    Add-Run 0 -Installs $false; Add-Run 0 -Installs $false
    Invoke-Office | Out-Null
    Assert-True (-not (Test-Path $script:Paths.Result)) 'no result after the first attempt'
    Assert-Equal (Get-Content -Raw $script:Paths.Status | ConvertFrom-Json).phase 'WaitingForRetry' 'waits for the retry'
    Invoke-Office | Out-Null
    $r = Get-Result
    Assert-Equal $r.status 'Failed' 'failed after two attempts'
    Assert-Equal $r.category 'NotVerified' 'category'
    Assert-True (-not $r.verified) 'not verified'
}

Test-Case 'download failure (exit 7) is retried and the second attempt succeeds; exit codes are kept' {
    Reset-Office
    Set-Marker 'windows-update.done'; Set-Marker 'applications.done'
    Add-Run 7 -Installs $false; Add-Run 0
    Invoke-Office | Out-Null
    Invoke-Office | Out-Null
    $r = Get-Result
    Assert-Equal $r.status 'Succeeded' 'second attempt'
    Assert-Equal @($r.attempts).Count 2 'two attempts recorded'
    Assert-Equal $r.attempts[0].exitCode 7 'first exit code kept'
    Assert-Equal $r.attempts[0].category 'OfficeDownload' 'first category'
}

Test-Case 'permanent installer errors (disk space, configuration) fail at once; the disk check stops before any download' {
    Reset-Office
    Set-Marker 'windows-update.done'; Set-Marker 'applications.done'
    Add-Run 2 -Installs $false
    Invoke-Office | Out-Null
    Assert-Equal (Get-Result).status 'Failed' 'configuration error'
    Assert-Equal $script:S.Starts.Count 1 'not retried'
    Reset-Office
    Set-Marker 'windows-update.done'; Set-Marker 'applications.done'
    $script:S.Free = 4.5
    Invoke-Office | Out-Null
    Assert-Equal (Get-Result).category 'DiskSpace' 'free space checked first'
    Assert-Equal $script:S.Starts.Count 0 'nothing downloaded'
}

Test-Case 'a hung installer is stopped after installTimeoutMinutes and retried' {
    Reset-Office
    Set-Marker 'windows-update.done'; Set-Marker 'applications.done'
    $script:Cfg.installTimeoutMinutes = 2
    Add-Run 0 @('Downloading') -Polls 100; Add-Run 0
    Invoke-Office | Out-Null
    Assert-Equal $script:S.Stopped.Count 1 'process tree stopped'
    Invoke-Office | Out-Null
    $r = Get-Result
    Assert-Equal $r.status 'Succeeded' 'second attempt'
    Assert-Equal $r.attempts[0].outcome 'TimedOut' 'first attempt timed out'
}

Test-Case 'interrupted installation: a restart during the attempt is recorded and the installation checked, then retried' {
    Reset-Office
    Set-Marker 'windows-update.done'; Set-Marker 'applications.done'
    Save-WdoState $script:Paths @{ schemaVersion = 1; firstRunUtc = $script:S.Now.ToString('o'); attempts = @(); current = @{ pid = 999; startedUtc = $script:S.Now.AddMinutes(-20).ToString('o'); bootTimeUtc = '2026-11-25T07:00:00Z'; attempt = 1 }; networkWaitSinceUtc = $null }
    Add-Run 0
    Invoke-Office | Out-Null
    $r = Get-Result
    Assert-Equal $r.attempts[0].outcome 'Interrupted' 'interruption recorded'
    Assert-Equal $r.status 'Succeeded' 'retried and verified'
    Assert-True (@($script:S.Activity | Where-Object { $_ -match 'interrupted' }).Count) 'reported in the activity feed'
}

Test-Case 'an installer still running from an earlier engine run is followed, never started twice' {
    Reset-Office
    Set-Marker 'windows-update.done'; Set-Marker 'applications.done'
    Save-WdoState $script:Paths @{ schemaVersion = 1; firstRunUtc = $script:S.Now.ToString('o'); attempts = @(); current = @{ pid = 4242; startedUtc = $script:S.Now.AddMinutes(-5).ToString('o'); bootTimeUtc = $script:S.Boot; attempt = 1 }; networkWaitSinceUtc = $null }
    $script:S.FollowRunning = 3
    Invoke-Office | Out-Null
    Assert-Equal $script:S.Starts.Count 0 'no second installer'
    Assert-Equal (Get-Result).status 'Succeeded' 'followed to the end and verified'
}

Test-Case 'no network: waits, then Offline after networkWaitHours; a busy installation lock and a pending restart wait' {
    Reset-Office
    Set-Marker 'windows-update.done'; Set-Marker 'applications.done'
    $script:S.Online = $false
    Invoke-Office | Out-Null
    Assert-Equal (Get-Content -Raw $script:Paths.Status | ConvertFrom-Json).phase 'WaitingForNetwork' 'waits'
    $script:S.Now = $script:S.Now.AddHours(7)
    Invoke-Office | Out-Null
    Assert-Equal (Get-Result).status 'Offline' 'gives up after the limit'
    Reset-Office
    Set-Marker 'windows-update.done'; Set-Marker 'applications.done'
    $script:S.LockBusy = $true
    Invoke-Office | Out-Null
    Assert-Equal (Get-Content -Raw $script:Paths.Status | ConvertFrom-Json).phase 'WaitingForLock' 'lock'
    $script:S.LockBusy = $false; $script:S.RestartPending = $true
    Invoke-Office | Out-Null
    Assert-Equal (Get-Content -Raw $script:Paths.Status | ConvertFrom-Json).phase 'WaitingForRestart' 'restart'
    Assert-Equal $script:S.Starts.Count 0 'nothing started'
}

Test-Case 'integrity: a changed installer is never run' {
    Reset-Office
    Set-Marker 'windows-update.done'; Set-Marker 'applications.done'
    $copy = Join-Path $script:S.Root 'engine'
    Copy-Item -Recurse (Join-Path $script:P24 'scripts\office') $copy
    Add-Content -LiteralPath (Join-Path $copy 'Install_Office.ps1') -Value 'Write-Host tampered'
    $script:Paths.Engine = $copy
    Invoke-Office | Out-Null
    Assert-Equal (Get-Result).category 'Integrity' 'refused'
    Assert-Equal $script:S.Starts.Count 0 'not run'
}

Test-Case 'applications that never finish: Office installs after waitFor.applications.maxWaitHours' {
    Reset-Office
    Set-Marker 'windows-update.done'
    Add-Run 0
    Invoke-Office | Out-Null
    Assert-Equal $script:S.Starts.Count 0 'still waiting'
    $script:S.Now = $script:S.Now.AddHours([double] $script:Cfg.waitFor.applications.maxWaitHours + 1)
    Invoke-Office | Out-Null
    Assert-Equal (Get-Result).status 'Succeeded' 'installed after the wait limit'
}

# ------------------------------------------------------------------------------------------------
# Activation stage
# ------------------------------------------------------------------------------------------------

Write-Output ''
Write-Output 'Activation stage (Activation.ps1)'

$script:M24 = Read-WddManifest (Join-Path $script:P24 'deployment-manifest.json')
$script:M21 = Read-WddManifest (Join-Path $script:P21 'deployment-manifest.json')
$script:FakeKey = 'TQ7XB-4NRHP-9CJ2W-KM3DV-YF8GG'

function Reset-Act {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('wdl-test-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $script:A = @{ Root = $root; Lic = @{ Windows = @(@{ id = 'w1'; name = 'Windows(R), Professional edition'; description = 'Windows(R) Operating System, RETAIL channel'; licenseStatus = 0; partialKey = 'GG8YF' })
                                          Office = @(@{ id = 'o1'; name = 'Office 24, Office24ProPlus2024VL_KMS_Client_AE edition'; description = 'Office 24, VOLUME_KMSCLIENT channel'; licenseStatus = 0; partialKey = 'GCVGB' }) }
                   Throws = $false; Activate = New-Object System.Collections.Generic.List[string]; Helper = New-Object System.Collections.Generic.List[string]; Keys = 0; Kms = New-Object System.Collections.Generic.List[string]
                   ActivateWorks = $true; HelperWorks = $true }
    $script:APaths = Get-WddPaths (Join-Path $root 'ProgramData\WindowsDeploymentBuilder')
    New-Item -ItemType Directory -Path $script:APaths.Root -Force | Out-Null
}
function Get-WdlLicenseProducts { param([string] $Target) if ($script:A.Throws) { throw 'Access denied (simulated)' } @($script:A.Lic[$Target]) }
function Invoke-WdlActivateProduct { param([string] $ProductId) $script:A.Activate.Add($ProductId); if ($script:A.ActivateWorks) { foreach ($t in 'Windows', 'Office') { foreach ($p in @($script:A.Lic[$t])) { if ($p.id -eq $ProductId) { $p.licenseStatus = 1 } } } } }
function Invoke-WdlOfficeHelper { param([string] $Script, [hashtable] $Arguments, [string] $Log) $script:A.Helper.Add((@($Arguments.Keys | Sort-Object | ForEach-Object { "$_=$($Arguments[$_])" }) -join ' ')); if ($script:A.HelperWorks) { foreach ($p in @($script:A.Lic.Office)) { $p.licenseStatus = 1 } }; return 0 }
function Set-WdlKmsHost { param([string] $KmsHost) $script:A.Kms.Add($KmsHost) }
function Install-WdlProductKey {
    param([Security.SecureString] $Key)
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Key))
    Assert-Equal $plain $script:FakeKey 'the key reaches the licensing service unchanged'
    $script:A.Keys++
    foreach ($p in @($script:A.Lic.Office)) { $p.partialKey = $plain.Substring($plain.Length - 5) }
}
function New-Snap { param([string] $OfficeStatus = 'Succeeded', [string] $OfficeState = 'Final') @{ stages = @(@{ id = 'office'; state = $OfficeState; status = $OfficeStatus; detail = 'simulated' }) } }
function Get-AllText { (Get-ChildItem -LiteralPath $script:A.Root -Recurse -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n" }

Test-Case 'Microsoft activation, both targets: Windows online, Office via the pinned helper and its KMS host; verified by the licensing service' {
    Reset-Act
    $st = @{}
    $act = Step-WddActivation $script:M24 $script:APaths $st (New-Snap) 'NotRequired'
    Assert-Equal $act.windows.status 'Activated' 'Windows'
    Assert-True $act.windows.verified 'Windows verified'
    Assert-Equal $act.office.status 'Activated' 'Office'
    Assert-Equal ($script:A.Helper -join ';') 'KmsHost=kms.example.test KmsPort=1688' 'helper arguments'
    Assert-Equal ($script:A.Activate -join ';') 'w1' 'Windows activated through the licensing service only'
    Assert-True (Test-Path (Join-Path $script:APaths.Root 'Activation\result.json')) 'separate result file'
    Assert-True (Test-Path (Join-Path $script:APaths.Root 'Activation\activation.log')) 'separate log'
}

Test-Case 'Office installation failed: only Office activation is blocked; Windows is still activated' {
    Reset-Act
    $act = Step-WddActivation $script:M24 $script:APaths @{} (New-Snap 'Failed') 'NotRequired'
    Assert-Equal $act.office.status 'Blocked' 'Office blocked'
    Assert-Equal $script:A.Helper.Count 0 'Office helper not run'
    Assert-Equal $act.windows.status 'Activated' 'Windows independent'
    Reset-Act
    $act = Step-WddActivation $script:M24 $script:APaths @{} (New-Snap '' 'Running') 'NotRequired'
    Assert-Equal $act.office.status 'Blocked' 'Office still installing: never activated as if installed'
}

Test-Case 'evidence only: an activation call that leaves the product unlicensed is Failed, never Activated' {
    Reset-Act
    $script:A.ActivateWorks = $false; $script:A.HelperWorks = $false
    $act = Step-WddActivation $script:M24 $script:APaths @{} (New-Snap) 'NotRequired'
    Assert-Equal $act.windows.status 'Failed' 'Windows'
    Assert-Equal $act.office.status 'Failed' 'Office'
    Assert-True (Test-WddActivationAttention @{ activation = $act }) 'needs attention (a follow-up)'
}

Test-Case 'a restart still outstanding defers activation; an unreadable licensing service is Unavailable' {
    Reset-Act
    $act = Step-WddActivation $script:M24 $script:APaths @{} (New-Snap) 'LimitReached'
    Assert-Equal $act.windows.status 'Deferred' 'Windows deferred'
    Assert-Equal $act.office.status 'Deferred' 'Office deferred'
    Assert-Equal ($script:A.Activate.Count + $script:A.Helper.Count) 0 'nothing changed'
    Reset-Act
    $script:A.Throws = $true
    $act = Step-WddActivation $script:M24 $script:APaths @{} (New-Snap) 'NotRequired'
    Assert-Equal $act.windows.status 'Unavailable' 'unavailable'
}

Test-Case 'technician methods: manual Windows and Office MAK wait for the technician; no key is asked for or installed automatically' {
    Reset-Act
    $act = Step-WddActivation $script:M21 $script:APaths @{} (New-Snap) 'NotRequired'
    Assert-Equal $act.windows.status 'AwaitingTechnician' 'manual Windows'
    Assert-Equal $act.office.status 'AwaitingTechnician' 'MAK'
    Assert-Equal $script:A.Keys 0 'no key installed'
    Assert-Equal ($script:A.Activate.Count + $script:A.Helper.Count) 0 'nothing activated'
    Assert-True ($act.office.message -match 'DeploymentRecovery.ps1 -Action Activate -Target Office') 'tells the technician what to run'
}

Test-Case 'the step runs once; a deployment without activation has none' {
    Reset-Act
    $st = @{}
    [void] (Step-WddActivation $script:M24 $script:APaths $st (New-Snap) 'NotRequired')
    $n = $script:A.Activate.Count
    [void] (Step-WddActivation $script:M24 $script:APaths $st (New-Snap) 'NotRequired')
    Assert-Equal $script:A.Activate.Count $n 'not repeated'
    $plain = Read-WddManifest (Join-Path $script:OfficeFixture '..\usb\WindowsDeployment\deployment-manifest.json')
    Assert-True ($null -eq (Step-WddActivation $plain $script:APaths @{} (New-Snap) 'NotRequired')) 'no activation block, no step'
}

Test-Case 'Office re-run after a failed installation: the blocked Office activation is attempted then; Windows is not activated again' {
    Reset-Act
    $st = @{}
    $act = Step-WddActivation $script:M24 $script:APaths $st (New-Snap 'Failed') 'NotRequired'
    Assert-Equal $act.office.status 'Blocked' 'blocked while Office is not installed'
    $windowsCalls = $script:A.Activate.Count
    # Resume-Deployment.ps1 -RestartStage office: the stage succeeds the second time.
    $act = Step-WddActivation $script:M24 $script:APaths $st (New-Snap 'Succeeded') 'NotRequired'
    Assert-Equal $act.office.status 'Activated' 'Office activated after the successful re-run'
    Assert-Equal $act.windows.status 'Activated' 'Windows result kept'
    Assert-Equal $script:A.Activate.Count $windowsCalls 'Windows not activated a second time'
}

Test-Case 'technician MAK: the key goes to the licensing service only; it is never stored, logged or shown' {
    Reset-Act
    # The 2021 package installs Standard 2021: the licensing service lists that product.
    $script:A.Lic.Office = @(@{ id = 'o21'; name = 'Office 21, Office21Standard2021VL_KMS_Client_AE edition'; description = 'Office 21, VOLUME_KMSCLIENT channel'; licenseStatus = 0; partialKey = '6F7TH' })
    $st = @{}
    [void] (Step-WddActivation $script:M21 $script:APaths $st (New-Snap) 'NotRequired')
    $officeDir = Join-Path $script:APaths.Root 'Office'; New-Item -ItemType Directory -Path $officeDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $officeDir 'result.json') -Value '{"status":"Succeeded"}'
    $secure = ConvertTo-SecureString $script:FakeKey -AsPlainText -Force
    $act = Invoke-WddActivationAction $script:M21 $script:APaths $st 'Activate' 'Office' $secure
    Assert-Equal $act.office.status 'Activated' 'activated with the MAK'
    Assert-Equal $script:A.Keys 1 'installed once'
    Save-WddState $script:APaths $st
    $all = Get-AllText
    foreach ($part in $script:FakeKey, ($script:FakeKey -replace '-', ''), $script:FakeKey.Substring(0, 17)) { Assert-True (-not $all.Contains($part)) "key text not on disk: $part" }
    $view = Get-WddActivationView $script:M21 $st
    Assert-True (-not ([string] $view.office.message).Contains('YF8GG')) 'the status view drops even the last five characters'
}

Test-Case 'CheckActivation reports Activated only with evidence; a manual Windows activation is confirmed afterwards' {
    Reset-Act
    $st = @{}
    [void] (Step-WddActivation $script:M21 $script:APaths $st (New-Snap) 'NotRequired')
    $act = Invoke-WddActivationAction $script:M21 $script:APaths $st 'CheckActivation'
    Assert-Equal $act.windows.status 'AwaitingTechnician' 'still not licensed'
    $script:A.Lic.Windows[0].licenseStatus = 1
    $act = Invoke-WddActivationAction $script:M21 $script:APaths $st 'CheckActivation'
    Assert-Equal $act.windows.status 'Activated' 'licensed now'
    Assert-True $act.windows.verified 'verified'
}

Test-Case 'the deployment snapshot lists the Office stage after the applications; the view reports Waiting before the step' {
    $stages = @(Get-WddEngineStages $script:M24 | ForEach-Object { $_.id })
    Assert-Equal ($stages -join ',') 'windowsUpdate,applications,drivers,office' 'engine stages in order'
    $view = Get-WddActivationView $script:M24 @{}
    Assert-Equal $view.windows.status 'Waiting' 'waiting'
    Assert-Equal $view.office.status 'Waiting' 'waiting'
}

Test-Case 'LAN monitor: Office and activation appear only for such deployments, with the phase and no key at all' {
    . (Join-Path $script:P24 'scripts\monitor\DeploymentStatusServer.ps1') -Mode Library
    $script:WddTaskVisibility = 'Limited'
    Reset-Act
    $st = @{ schemaVersion = $script:DeployStateVersion; status = 'InProgress'; packageId = $script:M24.packageId; initializedUtc = (Get-WddNow).ToString('o'); stages = @{}; stalledAfterMinutes = 120
             activation = @{ ranUtc = (Get-WddNow).ToString('o')
                             windows = @{ target = 'Windows'; action = 'microsoft'; status = 'Activated'; verified = $true; message = 'Activated and verified: Windows(R), Professional edition: Licensed (key ending GG8YF).' }
                             office = @{ target = 'Office'; action = 'microsoft'; status = 'Failed'; verified = $false; message = 'Office is not activated after the attempt. Office 24: Unlicensed (key ending GCVGB).' } } }
    Save-WddState $script:APaths $st
    $officeDir = Join-Path $script:APaths.Root 'Office'; New-Item -ItemType Directory -Path $officeDir -Force | Out-Null
    Write-WddJson (Join-Path $officeDir 'result.json') @{ status = 'Succeeded'; reason = 'Office LTSC Professional Plus 2024 installed and verified.'; verified = $true; finishedUtc = (Get-WddNow).ToString('o'); reboots = 0 }
    $m = Get-WddMonitorStatus $script:M24 $script:APaths @{ refreshSeconds = 7 }
    Assert-True ($m.Contains('office') -and $m.Contains('activation')) 'present for this deployment'
    Assert-Equal $m.office.state 'Final' 'Office stage'
    Assert-True $m.office.verified 'verified'
    Assert-Equal $m.office.progress 'unavailable' 'no invented download progress'
    Assert-Equal $m.activation.windows.status 'Activated' 'Windows activation'
    Assert-Equal $m.activation.office.status 'Failed' 'Office activation, separate from the installation'
    $json = $m | ConvertTo-Json -Depth 8
    foreach ($s in 'GG8YF', 'GCVGB', 'key ending') { Assert-True (-not $json.Contains($s)) "not served: $s" }
    $plain = Read-WddManifest (Join-Path $script:OfficeFixture '..\usb\WindowsDeployment\deployment-manifest.json')
    $m2 = Get-WddMonitorStatus $plain $script:APaths @{ refreshSeconds = 7 }
    Assert-True (-not $m2.Contains('office') -and -not $m2.Contains('activation')) 'absent for a deployment without them'
}

Write-Output ''
Write-Output "$script:Passed passed, $script:Failures failed"
if ($script:Failures) { exit 1 }
