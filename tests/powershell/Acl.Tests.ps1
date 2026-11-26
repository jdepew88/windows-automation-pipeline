#Requires -Version 5.1
<#
    Real NTFS permission tests for the folder-protection functions that ship in the deployment
    package: Stage-Deployment.ps1 (Set-WddAcl), the three engine installers (Protect-WdbDataRoot)
    and ApplicationEngine.ps1 (Protect-WdaFolder, Protect-WdaBackupFolder). Nothing is mocked: each
    function is taken from the shipped script (parsed, not run as a whole, so no task is registered)
    and applied with icacls.exe to folders below %TEMP%. No system folder is touched.

    Regression for the first bare-metal deployment: "icacls <root> /inheritance:r /grant:r
    *SID:(OI)(CI)F ... /T" left every FILE protected with no entries (unreadable for SYSTEM and
    Administrators too), while icacls reported success.

    Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\powershell\Acl.Tests.ps1 -Fixture <dir>
#>
param([Parameter(Mandatory = $true)] [string] $Fixture)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off
$script:Failures = 0
$script:Passed = 0
$pkgScripts = Join-Path $Fixture 'usb\WindowsDeployment\scripts'
$src = Join-Path $PSScriptRoot '..\..\src\engine'
$me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$STD = @('*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX')

function Assert-True($Value, [string] $Message) { if (-not $Value) { throw "ASSERT: $Message" } }
function Assert-Equal($Actual, $Expected, [string] $Message) { if ("$Actual" -ne "$Expected") { throw "ASSERT: $Message. Expected <$Expected>, got <$Actual>." } }

<# Defines one function from a shipped script under a new name (the script itself is not run). #>
function Import-ShippedFunction {
    param([string] $Path, [string] $Name, [string] $As)
    $t = $null; $e = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $Path).Path, [ref] $t, [ref] $e)
    if ($e.Count) { throw "$Path does not parse: $($e[0].Message)" }
    $fn = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1
    if (-not $fn) { throw "$Path defines no function $Name" }
    Set-Item -Path "function:script:$As" -Value ([scriptblock]::Create($fn.Body.Extent.Text.Substring(1, $fn.Body.Extent.Text.Length - 2)))
}

# Every shipped protection function, with how it is called.
$targets = @(
    @{ Label = 'Stage-Deployment.ps1 Set-WddAcl'; Path = Join-Path $pkgScripts 'bootstrap\Stage-Deployment.ps1'; Name = 'Set-WddAcl' }
    @{ Label = 'Install-UpdateEngine.ps1 Protect-WdbDataRoot'; Path = Join-Path $pkgScripts 'windows-update\Install-UpdateEngine.ps1'; Name = 'Protect-WdbDataRoot' }
    @{ Label = 'Install-ApplicationEngine.ps1 Protect-WdbDataRoot'; Path = Join-Path $pkgScripts 'applications\Install-ApplicationEngine.ps1'; Name = 'Protect-WdbDataRoot' }
    @{ Label = 'Install-DriverEngine.ps1 Protect-WdbDataRoot'; Path = Join-Path $src 'drivers\scripts\Install-DriverEngine.ps1'; Name = 'Protect-WdbDataRoot' }
    @{ Label = 'Install-OfficeEngine.ps1 Protect-WdbDataRoot'; Path = Join-Path $src 'office\scripts\Install-OfficeEngine.ps1'; Name = 'Protect-WdbDataRoot' }
    @{ Label = 'ApplicationEngine.ps1 Protect-WdaFolder'; Path = Join-Path $pkgScripts 'applications\ApplicationEngine.ps1'; Name = 'Protect-WdaFolder' }
)
$i = 0
foreach ($t in $targets) { $t.Fn = "Protect$i"; Import-ShippedFunction $t.Path $t.Name $t.Fn; $i++ }
Import-ShippedFunction (Join-Path $pkgScripts 'applications\ApplicationEngine.ps1') 'Protect-WdaBackupFolder' 'Protect-WdaBackupFolder'
# Protect-WdaBackupFolder calls Protect-WdaFolder by name.
Import-ShippedFunction (Join-Path $pkgScripts 'applications\ApplicationEngine.ps1') 'Protect-WdaFolder' 'Protect-WdaFolder'
# The real atomic JSON writer and logger of the orchestrator.
. (Join-Path $pkgScripts 'common\DeploymentCommon.ps1')
# The real staging code (dot-sourcing only defines its functions).
. (Join-Path $pkgScripts 'bootstrap\Stage-Deployment.ps1')
$ErrorActionPreference = 'Stop'

<# A data root like C:\ProgramData\WindowsDeploymentBuilder: staged scripts, state, logs. #>
function New-Tree {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("wdb-acl-" + [guid]::NewGuid().ToString('N'))
    foreach ($d in 'Package\scripts\orchestrator', 'Package\scripts\common', 'Deployment\logs', 'state', 'Updates') { New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null }
    Set-Content -LiteralPath (Join-Path $root 'Package\scripts\orchestrator\Show-DeploymentStatus.ps1') -Value "'status-ok'"
    Set-Content -LiteralPath (Join-Path $root 'Package\scripts\common\DeploymentCommon.ps1') -Value '# common'
    Set-Content -LiteralPath (Join-Path $root 'Package\deployment-manifest.json') -Value '{}'
    Set-Content -LiteralPath (Join-Path $root 'Deployment\logs\deployment.log') -Value 'initialized'
    Set-Content -LiteralPath (Join-Path $root 'state\deployment.json') -Value '{}'
    return $root
}

function Remove-Tree {
    param([string] $Root)
    # The owner may always rewrite the permissions, even of an emptied entry list.
    & icacls.exe $Root /reset /T /C /Q | Out-Null
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}

<# Entries of one item as "SID=rights[(i)]". #>
function Get-Entries {
    param([string] $Path)
    $a = Get-Acl -LiteralPath $Path
    @{
        Protected = $a.AreAccessRulesProtected
        Rules     = @($a.Access | ForEach-Object { "$($_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value)=$($_.FileSystemRights)$(if ($_.IsInherited) { '(i)' })" })
        Sddl      = $a.Sddl
    }
}

<# The bare-metal failure: a protected item without a single entry. #>
function Get-EmptyItems {
    param([string] $Root)
    @(Get-ChildItem -LiteralPath $Root -Recurse -Force | Where-Object { $e = Get-Entries $_.FullName; $e.Protected -and $e.Rules.Count -eq 0 } | ForEach-Object { $_.FullName.Substring($Root.Length) })
}

<# SYSTEM and Administrators full control and Users read & execute, inherited from the root. #>
function Assert-Usable {
    param([string] $Root, [string] $Label)
    $r = Get-Entries $Root
    Assert-True $r.Protected "$Label root is protected (nothing inherited from ProgramData)"
    foreach ($want in 'S-1-5-18=FullControl', 'S-1-5-32-544=FullControl') { Assert-True ($r.Rules -contains $want) "$Label root grants $want (has $($r.Rules -join '; '))" }
    Assert-True (@($r.Rules | Where-Object { $_ -like 'S-1-5-32-545=ReadAndExecute*' }).Count -eq 1) "$Label root grants Users read & execute"
    $empty = @(Get-EmptyItems $Root)
    Assert-Equal $empty.Count 0 "$Label leaves no item without entries ($($empty -join ', '))"
    foreach ($item in Get-ChildItem -LiteralPath $Root -Recurse -Force) {
        $e = Get-Entries $item.FullName
        if ($item.FullName -like '*\Backup\*') { continue }
        Assert-True (-not $e.Protected) "$Label $($item.Name) inherits"
        foreach ($want in 'S-1-5-18=FullControl(i)', 'S-1-5-32-544=FullControl(i)') { Assert-True ($e.Rules -contains $want) "$Label $($item.Name) has $want (has $($e.Rules -join '; '))" }
        Assert-True (@($e.Rules | Where-Object { $_ -like 'S-1-5-32-545=ReadAndExecute*(i)' }).Count -eq 1) "$Label $($item.Name) has Users read & execute (inherited)"
    }
}

function Invoke-OldAcl {
    param([string] $Root)
    # The code that shipped before this fix (all five places).
    & icacls.exe $Root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /T /C /Q | Out-Null
    return $LASTEXITCODE
}

<# Runs a staged script in a new Windows PowerShell process, as the orchestrator and tasks do. #>
function Invoke-Staged {
    param([string] $Path)
    # The damaged case writes "access denied" to stderr; collect it instead of stopping.
    $ErrorActionPreference = 'Continue'
    $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path 2>&1
    @{ Exit = $LASTEXITCODE; Out = (@($out) -join ' ') }
}

function Test-Scenario {
    param([string] $Name, [scriptblock] $Body)
    $script:Root = New-Tree
    try {
        & $Body
        $script:Passed++
        Write-Output "  ok    $Name"
    } catch {
        $script:Failures++
        Write-Output "  FAIL  $Name"
        Write-Output "        $($_.Exception.Message)"
        Write-Output "        $($_.InvocationInfo.PositionMessage -replace "`n", "`n        ")"
    } finally {
        $script:WddLogFile = $null
        Remove-Tree $script:Root
    }
}

Write-Output 'NTFS permission scenarios (real icacls on folders below %TEMP%)'

Test-Scenario 'the old command reproduces the field failure: icacls succeeds, every file is protected with no entries, a staged script cannot run' {
    Assert-Equal (Invoke-OldAcl $script:Root) 0 'icacls reported success'
    $empty = @(Get-EmptyItems $script:Root)
    Assert-True ($empty -contains '\Package\scripts\orchestrator\Show-DeploymentStatus.ps1') "status viewer emptied ($($empty -join ', '))"
    Assert-True ($empty -contains '\Deployment\logs\deployment.log') 'log emptied'
    Assert-True ($empty -contains '\state\deployment.json') 'state emptied'
    $run = Invoke-Staged (Join-Path $script:Root 'Package\scripts\orchestrator\Show-DeploymentStatus.ps1')
    Assert-True ($run.Out -notmatch 'status-ok') "the script did not run ($($run.Out))"
}

foreach ($t in $targets) {
    $fn = $t.Fn; $label = $t.Label
    Test-Scenario "$($label): every folder and file is usable by SYSTEM and Administrators, readable by Users" {
        & $fn $script:Root
        Assert-Usable $script:Root $label
    }

    Test-Scenario "$($label): a staged script runs from the protected folder" {
        & $fn $script:Root
        $run = Invoke-Staged (Join-Path $script:Root 'Package\scripts\orchestrator\Show-DeploymentStatus.ps1')
        Assert-Equal $run.Exit 0 "exit code ($($run.Out))"
        Assert-True ($run.Out -match 'status-ok') "output ($($run.Out))"
    }

    Test-Scenario "$($label): running it again (restage, resume, each engine installer) changes nothing" {
        & $fn $script:Root
        $before = @(Get-ChildItem -LiteralPath $script:Root -Recurse -Force | ForEach-Object { "$($_.FullName)|$((Get-Entries $_.FullName).Sddl)" })
        & $fn $script:Root
        & $fn $script:Root
        $after = @(Get-ChildItem -LiteralPath $script:Root -Recurse -Force | ForEach-Object { "$($_.FullName)|$((Get-Entries $_.FullName).Sddl)" })
        Assert-Equal ($after -join "`n") ($before -join "`n") 'same security descriptors'
        Assert-Usable $script:Root $label
    }

    Test-Scenario "$($label): repairs a package damaged by the earlier version" {
        Invoke-OldAcl $script:Root | Out-Null
        Assert-True (@(Get-EmptyItems $script:Root).Count -gt 0) 'damaged first'
        & $fn $script:Root
        Assert-Usable $script:Root $label
        $run = Invoke-Staged (Join-Path $script:Root 'Package\scripts\orchestrator\Show-DeploymentStatus.ps1')
        Assert-True ($run.Out -match 'status-ok') "the status viewer runs again ($($run.Out))"
    }
}

Test-Scenario 'logs and JSON written after protection (orchestrator writers, atomic replace) inherit the root entries' {
    # The tests are not elevated: this user is granted write access in addition, as SYSTEM and
    # Administrators are on a real computer.
    Protect0 $script:Root (@($STD) + "*$($me):(OI)(CI)F")
    $paths = Get-WddPaths $script:Root
    Initialize-WddLogging $paths
    Write-WddLog 'after protection'
    Write-WddJson $paths.Status @{ phase = 'x' }
    Write-WddJson $paths.Status @{ phase = 'y' }          # replaces the existing file
    Write-WddJson $paths.State @{ status = 'InProgress' } -Backup
    foreach ($f in $paths.Log, $paths.Status, $paths.State, "$($paths.State).bak") {
        Assert-True (Test-Path -LiteralPath $f) "$f written"
        $e = Get-Entries $f
        Assert-True (-not $e.Protected) "$f inherits"
        foreach ($want in 'S-1-5-18=FullControl(i)', 'S-1-5-32-544=FullControl(i)') { Assert-True ($e.Rules -contains $want) "$f has $want ($($e.Rules -join '; '))" }
    }
    Assert-True ((Get-Content -LiteralPath $paths.Log -Raw) -match 'after protection') 'log line appended'
    Assert-Equal (Read-WddJson $paths.Status).phase 'y' 'status replaced'
}

Test-Scenario 'a private settings backup keeps its own entries when the data root is protected again (Users get nothing there)' {
    $backup = Join-Path $script:Root 'Backup\b1'
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $backup 'settings.json') -Value '{}'
    Protect-WdaBackupFolder $backup
    foreach ($t in $targets) { & $t.Fn $script:Root }
    $b = Get-Entries $backup
    Assert-True $b.Protected 'backup stays protected'
    Assert-True ($b.Rules -contains "$me=FullControl") "backup grants this user ($($b.Rules -join '; '))"
    Assert-True (-not ($b.Rules -match '^S-1-5-32-545=')) 'Users not granted on the backup'
    $f = Get-Entries (Join-Path $backup 'settings.json')
    Assert-True (-not $f.Protected) 'backup file inherits from the backup folder'
    Assert-True ($f.Rules -contains "$me=FullControl(i)") 'backup file readable by this user'
    Assert-True (-not ($f.Rules -match '^S-1-5-32-545=')) 'Users not granted on the backup file'
    Assert-Usable $script:Root 'data root'
}

Test-Scenario 'the field sequence with the real staging code: secure, stage the real package, secure again, then every engine installer and a restage; the staged scripts still run' {
    # This user stands in for SYSTEM/Administrators (the tests are not elevated) while staging writes.
    $grant = @($STD) + "*$($me):(OI)(CI)F"
    $paths = Get-WddPaths $script:Root
    $manifest = Read-WddManifest (Join-Path $Fixture 'usb\WindowsDeployment\deployment-manifest.json')
    Initialize-WddLogging $paths
    Write-WddLog 'initialize'
    Protect0 $paths.Root $grant                                   # Initialize-Deployment: before staging
    $staged = Invoke-WddStage $manifest (Join-Path $Fixture 'usb\WindowsDeployment\deployment-manifest.json') 'Package' (Join-Path $Fixture 'usb\WindowsDeployment') '' $paths
    Assert-True $staged.Ok "staged: $($staged.Message)"
    Protect0 $paths.Root $grant                                   # Initialize-Deployment: after staging
    foreach ($t in $targets) { & $t.Fn $paths.Root $grant }        # each engine installer (launch, Resume -RestartStage)
    $staged = Invoke-WddStage $manifest (Join-Path $Fixture 'usb\WindowsDeployment\deployment-manifest.json') 'Package' (Join-Path $Fixture 'usb\WindowsDeployment') '' $paths
    Assert-True $staged.Ok "restaged: $($staged.Message)"
    Protect0 $paths.Root $grant
    Write-WddLog 'still writable'
    Assert-Equal @(Get-EmptyItems $paths.Root).Count 0 'no item without entries'
    $check = Test-WddFiles $paths.Package $manifest 'Text' $staged.Files
    Assert-True $check.Ok "staged files readable and intact ($($check.Missing.Count) missing, $($check.Mismatched.Count) modified)"
    $parse = & powershell.exe -NoProfile -NonInteractive -Command "`$e = `$null; [void][Management.Automation.Language.Parser]::ParseFile('$(Join-Path $paths.Package 'scripts\orchestrator\Show-DeploymentStatus.ps1')', [ref] `$null, [ref] `$e); 'parsed=' + `$e.Count"
    Assert-Equal ($parse | Select-Object -Last 1) 'parsed=0' 'another process reads the staged status viewer'
    Assert-True ((Get-Content -LiteralPath $paths.Log -Raw) -match 'still writable') 'the log is still written'
}

Test-Scenario 'a failing icacls call is an error, not a silent success' {
    $missing = Join-Path $script:Root 'does-not-exist'
    foreach ($t in $targets) {
        $threw = $false
        try { & $t.Fn $missing } catch { $threw = $_.Exception.Message -match 'icacls failed with exit code' }
        Assert-True $threw "$($t.Label) throws"
    }
}

Write-Output ''
Write-Output "$($script:Passed) passed, $($script:Failures) failed"
if ($script:Failures) { exit 1 }
exit 0
