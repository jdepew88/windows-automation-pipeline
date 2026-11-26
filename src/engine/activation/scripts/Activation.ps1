<#
.SYNOPSIS
    Windows Deployment Builder: the optional activation stage (functions only; dot-sourced by
    Complete-Deployment.ps1, the deployment monitor and DeploymentRecovery.ps1).

.DESCRIPTION
    Runs once, at the very end: after every stage is final and Windows needs no further restart.
    Windows and Office are handled independently; one never blocks the other.

      Windows  microsoft  digitalLicense  activate online (digital entitlement / firmware key)
                          kms             activate against the organization's KMS host (or DNS)
                          productKey      the technician types the key into the recovery tool
               manual     the technician activates by other means; the result is only checked
      Office   microsoft  kms             Activate_Office.ps1 (pinned) -KmsHost / -Activate
                          activeDirectory Activate_Office.ps1 -Activate
                          mak             the technician types the MAK into the recovery tool
               manual     as for Windows

    Office activation runs only when the Office stage installed and verified the product; otherwise
    it is Blocked (never "failed": the installation result is reported by the Office stage).
    "Activated" is reported only with evidence: the licensing service (SoftwareLicensingProduct)
    reports the product as licensed. A launched tool or a typed key is not evidence.

    Statuses: NotRequested, AwaitingTechnician, Activated, Failed, Deferred, Blocked, Unavailable.
    No product key is stored, logged or shown: keys are read with Read-Host -AsSecureString, go
    straight to the licensing service in this process and only the last five characters, which
    Windows itself reports, ever appear.
#>

$script:WdlWindowsAppId = '55c92734-d682-4d71-983e-d6ec3f16059f'
$script:WdlOfficeAppId = '0ff1ce15-a989-479d-af46-f275c6370663'
$script:WdlAttention = @('AwaitingTechnician', 'Failed', 'Deferred', 'Blocked', 'Unavailable')
$script:WdlKeyPattern = '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$'

# ------------------------------------------------------------------------------------------------
# What Windows says and does (replaced in the tests)
# ------------------------------------------------------------------------------------------------

<# Installed licenses of one application (Windows or Office): name, description, status, last five key characters. #>
function Get-WdlLicenseProducts {
    param([ValidateSet('Windows', 'Office')] [string] $Target)
    $app = $(if ($Target -eq 'Windows') { $script:WdlWindowsAppId } else { $script:WdlOfficeAppId })
    @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID='$app' AND PartialProductKey IS NOT NULL" -ErrorAction Stop | ForEach-Object {
        @{ id = [string] $_.ID; name = [string] $_.Name; description = [string] $_.Description; licenseStatus = [int] $_.LicenseStatus; partialKey = [string] $_.PartialProductKey }
    })
}

<# Activates one installed license through the licensing service (online, or KMS when it is a KMS client). #>
function Invoke-WdlActivateProduct {
    param([string] $ProductId)
    $p = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ID='$ProductId'" -ErrorAction Stop
    [void] (Invoke-CimMethod -InputObject $p -MethodName Activate -ErrorAction Stop)
}

<# Installs a product key from a SecureString; the plain text exists only inside this call. #>
function Install-WdlProductKey {
    param([Security.SecureString] $Key)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Key)
    try {
        $plain = ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)).Trim().ToUpperInvariant()
        if ($plain -notmatch $script:WdlKeyPattern) { throw 'That is not a product key (five groups of five letters and digits).' }
        $svc = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
        [void] (Invoke-CimMethod -InputObject $svc -MethodName InstallProductKey -Arguments @{ ProductKey = $plain } -ErrorAction Stop)
        [void] (Invoke-CimMethod -InputObject $svc -MethodName RefreshLicenseStatus -ErrorAction SilentlyContinue)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        $plain = $null
    }
}

<# Points Windows at a KMS host (host[:port]); empty = DNS auto-discovery. #>
function Set-WdlKmsHost {
    param([string] $KmsHost)
    $svc = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
    if (-not $KmsHost) { [void] (Invoke-CimMethod -InputObject $svc -MethodName ClearKeyManagementServiceMachine -ErrorAction Stop); return }
    $name, $port = $KmsHost -split ':', 2
    [void] (Invoke-CimMethod -InputObject $svc -MethodName SetKeyManagementServiceMachine -Arguments @{ MachineName = $name } -ErrorAction Stop)
    if ($port) { [void] (Invoke-CimMethod -InputObject $svc -MethodName SetKeyManagementServicePort -Arguments @{ PortNumber = [uint32] $port } -ErrorAction Stop) }
}

<# Runs the pinned Activate_Office.ps1 (OSPP.VBS) for KMS or Active Directory activation (never with a key); returns its exit code. #>
function Invoke-WdlOfficeHelper {
    param([string] $Script, [hashtable] $Arguments, [string] $Log)
    $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @(foreach ($k in $Arguments.Keys) { "-$k"; if ($Arguments[$k] -isnot [switch] -and $Arguments[$k] -isnot [bool]) { [string] $Arguments[$k] } }) 2>&1
    $code = $LASTEXITCODE
    if ($Log) { try { [IO.File]::AppendAllText($Log, ((@($out) | ForEach-Object { "    $_" }) -join "`r`n") + "`r`n") } catch { } }
    return $code
}

# ------------------------------------------------------------------------------------------------
# Decisions
# ------------------------------------------------------------------------------------------------

function Get-WdlPaths {
    param([hashtable] $Paths)
    $root = Join-Path $Paths.Root 'Activation'
    @{ Root = $root; Result = (Join-Path $root 'result.json'); Log = (Join-Path $root 'activation.log'); Helper = (Join-Path $Paths.Package 'scripts\activation\Activate_Office.ps1') }
}

function Write-WdlLog {
    param([hashtable] $LP, [string] $Message, [string] $Level = 'INFO')
    try {
        if (-not (Test-Path -LiteralPath $LP.Root)) { New-Item -ItemType Directory -Path $LP.Root -Force | Out-Null }
        [IO.File]::AppendAllText($LP.Log, ('{0}  {1,-5}  {2}' -f [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message) + "`r`n")
    } catch { }
}

<#
    The licensing state of a target: Unavailable when the licensing service cannot be read, the
    matching product (Office: by its product ID, for example ProPlus2024) and whether it is licensed.
#>
function Get-WdlLicenseState {
    param([string] $Target, [string] $OfficeProductId = '')
    try { $products = @(Get-WdlLicenseProducts $Target) } catch { return @{ available = $false; licensed = $false; product = $null; detail = "The licensing service could not be read: $($_.Exception.Message)" } }
    if ($Target -eq 'Office' -and $OfficeProductId) {
        $token = $OfficeProductId -replace 'Volume$', ''
        $products = @($products | Where-Object { $_.name -match [regex]::Escape($token) -or $_.description -match [regex]::Escape($token) })
    }
    if (-not $products.Count) { return @{ available = $true; licensed = $false; product = $null; detail = "No installed $Target license was found." } }
    $licensed = @($products | Where-Object { $_.licenseStatus -eq 1 })
    $p = $(if ($licensed.Count) { $licensed[0] } else { $products[0] })
    $statusText = @{ 0 = 'Unlicensed'; 1 = 'Licensed'; 2 = 'Initial grace period'; 3 = 'Additional grace period'; 4 = 'Non-genuine grace period'; 5 = 'Notification'; 6 = 'Extended grace period' }[[int] $p.licenseStatus]
    return @{ available = $true; licensed = [bool] $licensed.Count; product = $p; detail = "$($p.name): $statusText (key ending $($p.partialKey))." }
}

function New-WdlEntry {
    param([string] $Target, [hashtable] $Plan)
    [ordered]@{ target = $Target; action = [string] $Plan.action; method = [string] $Plan.method; status = 'NotRequested'; verified = $false; message = ''; license = ''; updatedUtc = [DateTime]::UtcNow.ToString('o') }
}

function Set-WdlEntry {
    param($Entry, [string] $Status, [string] $Message, $License = $null)
    $Entry.status = $Status; $Entry.message = $Message; $Entry.updatedUtc = [DateTime]::UtcNow.ToString('o')
    $Entry.verified = ($Status -eq 'Activated')
    if ($License -and $License.product) { $Entry.license = [string] $License.detail }
    return $Entry
}

<# One automatic attempt for a target (no key is ever needed here). #>
function Invoke-WdlAutomatic {
    param([string] $Target, [hashtable] $Plan, [hashtable] $LP, [string] $OfficeProductId)
    $entry = New-WdlEntry $Target $Plan
    if ($Plan.action -eq 'none') { return (Set-WdlEntry $entry 'NotRequested' 'No activation was requested.') }
    $before = Get-WdlLicenseState $Target $OfficeProductId
    if (-not $before.available) { return (Set-WdlEntry $entry 'Unavailable' $before.detail) }
    if ($before.licensed) { return (Set-WdlEntry $entry 'Activated' "Already activated: $($before.detail)" $before) }
    if ($Plan.action -eq 'manual') { return (Set-WdlEntry $entry 'AwaitingTechnician' "Activate $Target with your own licensing process, then confirm: DeploymentRecovery.ps1 -Action CheckActivation. Now: $($before.detail)" $before) }
    if (($Target -eq 'Windows' -and $Plan.method -eq 'productKey') -or ($Target -eq 'Office' -and $Plan.method -eq 'mak')) {
        return (Set-WdlEntry $entry 'AwaitingTechnician' "Enter the $(if ($Target -eq 'Office') { 'MAK' } else { 'product key' }) in the recovery tool: DeploymentRecovery.ps1 -Action Activate -Target $Target. Now: $($before.detail)" $before)
    }
    try {
        if ($Target -eq 'Windows') {
            if ($Plan.method -eq 'kms') { Write-WdlLog $LP "Windows: KMS host $(if ($Plan.kmsHost) { $Plan.kmsHost } else { '(DNS auto-discovery)' })"; Set-WdlKmsHost ([string] $Plan.kmsHost) }
            if (-not $before.product) { return (Set-WdlEntry $entry 'Failed' "No Windows license is installed to activate. $($before.detail)" $before) }
            Write-WdlLog $LP "Windows: activating $($before.product.name)"
            Invoke-WdlActivateProduct ([string] $before.product.id)
        } else {
            $helperArgs = @{}
            if ($Plan.method -eq 'kms' -and $Plan.kmsHost) { $h, $port = ([string] $Plan.kmsHost) -split ':', 2; $helperArgs.KmsHost = $h; if ($port) { $helperArgs.KmsPort = $port } } else { $helperArgs.Activate = $true }
            Write-WdlLog $LP "Office: Activate_Office.ps1 $(($helperArgs.Keys | ForEach-Object { "-$_" }) -join ' ')"
            $code = Invoke-WdlOfficeHelper $LP.Helper $helperArgs $LP.Log
            Write-WdlLog $LP "Office: Activate_Office.ps1 exit code $code"
        }
    } catch {
        Write-WdlLog $LP "$Target activation error: $($_.Exception.Message)" 'ERROR'
        $after = Get-WdlLicenseState $Target $OfficeProductId
        return (Set-WdlEntry $entry 'Failed' "$Target activation failed: $($_.Exception.Message) $($after.detail)" $after)
    }
    $after = Get-WdlLicenseState $Target $OfficeProductId
    if ($after.licensed) { return (Set-WdlEntry $entry 'Activated' "Activated and verified: $($after.detail)" $after) }
    return (Set-WdlEntry $entry 'Failed' "$Target is not activated after the attempt. $($after.detail)" $after)
}

<# Writes Activation\result.json (no keys: only statuses and the licensing service's own description). #>
function Save-WdlResult {
    param([hashtable] $Paths, [hashtable] $State)
    $LP = Get-WdlPaths $Paths
    if (-not (Test-Path -LiteralPath $LP.Root)) { New-Item -ItemType Directory -Path $LP.Root -Force | Out-Null }
    Write-WddJson $LP.Result ([ordered]@{ schemaVersion = 1; updatedUtc = (Get-WddNow).ToString('o'); windows = $State.activation.windows; office = $State.activation.office; containsSecrets = $false })
}

<#
    The final-stage step (deployment monitor, SYSTEM). Runs when every stage is final and no
    restart is pending; a restart that could not be done defers what would change licensing.
    Each target is attempted once. Only a target that was never attempted (Blocked, Deferred) is
    looked at again, for example after the technician re-ran the Office stage with
    Resume-Deployment.ps1 -RestartStage office. Never holds the deployment: whatever needs a person
    is AwaitingTechnician.
#>
function Step-WddActivation {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $State, $Snapshot, [string] $Restart = 'NotRequired')
    if (-not ($Manifest.ContainsKey('activation') -and $Manifest.activation)) { return $null }
    $prev = $(if ($State['activation'] -is [hashtable] -and $State.activation['ranUtc']) { $State.activation } else { $null })
    $again = @(@('windows', 'office') | Where-Object { -not $prev -or -not $prev[$_] -or [string] $prev[$_]['status'] -in 'Blocked', 'Deferred' })
    if (-not $again.Count) { return $prev }
    $plan = $Manifest.activation
    $LP = Get-WdlPaths $Paths
    $State.activation = @{ ranUtc = (Get-WddNow).ToString('o'); windows = $(if ($prev) { $prev['windows'] } else { $null }); office = $(if ($prev) { $prev['office'] } else { $null }) }
    $officeStage = @(@($Snapshot.stages) | Where-Object { $_.id -eq 'office' }) | Select-Object -First 1
    $officeId = $(if ($Manifest.ContainsKey('office') -and $Manifest.office) { [string] $Manifest.office.productId } else { '' })
    foreach ($target in 'Windows', 'Office') {
        if ($target.ToLowerInvariant() -notin $again) { continue }
        $p = $plan[$target.ToLowerInvariant()]
        $entry = New-WdlEntry $target $p
        if ([string] $p.action -eq 'none') { $entry = Set-WdlEntry $entry 'NotRequested' 'No activation was requested.' }
        elseif ($target -eq 'Office' -and -not ($officeStage -and $officeStage.state -eq 'Final' -and $officeStage.status -eq 'Succeeded')) {
            $why = $(if (-not $officeStage) { 'Office is not part of this deployment.' } elseif ($officeStage.state -ne 'Final') { "the Office stage did not finish ($($officeStage.state))." } else { "the Office stage ended $($officeStage.status): $($officeStage.detail)" })
            $entry = Set-WdlEntry $entry 'Blocked' "Office activation was not attempted: $why"
        } elseif ($Restart -notin 'NotRequired') {
            $entry = Set-WdlEntry $entry 'Deferred' "Not attempted: Windows still needs a restart ($Restart). Restart, then run DeploymentRecovery.ps1 -Action Activate -Target $target."
        } else {
            $entry = Invoke-WdlAutomatic $target $p $LP $officeId
        }
        Write-WdlLog $LP "$target`: $($entry.status). $($entry.message)" $(if ($entry.status -in $script:WdlAttention) { 'WARN' } else { 'INFO' })
        $State.activation[$target.ToLowerInvariant()] = $entry
        if ($entry.status -ne 'NotRequested') { Add-WddActivity $Paths "Activation, ${target}: $($entry.status). $($entry.message)" $(if ($entry.status -in $script:WdlAttention) { 'warning' } else { 'info' }) }
    }
    Save-WdlResult $Paths $State
    return $State.activation
}

<# True when an activation result needs a person (a follow-up, never an installation failure). #>
function Test-WddActivationAttention {
    param([hashtable] $State)
    if ($State['activation'] -isnot [hashtable]) { return $false }
    return (@(@($State.activation['windows'], $State.activation['office']) | Where-Object { $_ -and [string] $_['status'] -in $script:WdlAttention }).Count -gt 0)
}

<#
    Technician actions (DeploymentRecovery.ps1, elevated, interactive):
      CheckActivation        re-reads the licensing state of every requested target
      Activate -Target X     runs the chosen method again; asks for the key where one is needed
    Returns the updated activation block.
#>
function Invoke-WddActivationAction {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $State, [ValidateSet('CheckActivation', 'Activate')] [string] $Action, [string] $Target = '', [Security.SecureString] $ProductKey = $null)
    if (-not ($Manifest.ContainsKey('activation') -and $Manifest.activation)) { throw 'This deployment has no activation settings.' }
    if ($State['activation'] -isnot [hashtable]) { $State.activation = @{ ranUtc = $null; windows = $null; office = $null } }
    $LP = Get-WdlPaths $Paths
    $officeId = $(if ($Manifest.ContainsKey('office') -and $Manifest.office) { [string] $Manifest.office.productId } else { '' })
    $targets = $(if ($Target) { @($Target) } else { @('Windows', 'Office') })
    foreach ($t in $targets) {
        $key = $t.ToLowerInvariant()
        $p = $Manifest.activation[$key]
        $entry = $(if ($State.activation[$key]) { $State.activation[$key] } else { New-WdlEntry $t $p })
        if ([string] $p.action -eq 'none' -and $Action -eq 'CheckActivation') { continue }
        if ($t -eq 'Office' -and $Action -eq 'Activate') {
            $r = Read-WddJson (Join-Path $Paths.Root 'Office\result.json')
            if (-not ($r -and $r.status -eq 'Succeeded')) { $State.activation[$key] = Set-WdlEntry $entry 'Blocked' 'Office activation needs an installed and verified Office (the Office stage has no successful result).'; continue }
        }
        if ($Action -eq 'Activate') {
            $needsKey = ($t -eq 'Windows' -and $p.method -eq 'productKey') -or ($t -eq 'Office' -and $p.method -eq 'mak')
            if ($needsKey -or $ProductKey) {
                if (-not $ProductKey) { $ProductKey = Read-Host -AsSecureString "$t $(if ($t -eq 'Office') { 'MAK' } else { 'product key' }) (not shown, not saved)" }
                try {
                    Write-WdlLog $LP "${t}: installing the technician's key (not logged)."
                    Install-WdlProductKey $ProductKey
                    $st = Get-WdlLicenseState $t $officeId
                    if ($st.product) { Invoke-WdlActivateProduct ([string] $st.product.id) }
                } catch { Write-WdlLog $LP "${t}: $($_.Exception.Message)" 'ERROR'; $State.activation[$key] = Set-WdlEntry $entry 'Failed' "$t activation failed: $($_.Exception.Message)" (Get-WdlLicenseState $t $officeId); continue }
                finally { $ProductKey = $null }
                $st = Get-WdlLicenseState $t $officeId
                $State.activation[$key] = $(if ($st.licensed) { Set-WdlEntry $entry 'Activated' "Activated and verified: $($st.detail)" $st } else { Set-WdlEntry $entry 'Failed' "$t is not activated after the key was installed. $($st.detail)" $st })
                continue
            }
            $State.activation[$key] = Invoke-WdlAutomatic $t $p $LP $officeId
            continue
        }
        # CheckActivation: evidence only.
        $st = Get-WdlLicenseState $t $officeId
        if (-not $st.available) { $State.activation[$key] = Set-WdlEntry $entry 'Unavailable' $st.detail }
        elseif ($st.licensed) { $State.activation[$key] = Set-WdlEntry $entry 'Activated' "Verified: $($st.detail)" $st }
        else { $State.activation[$key] = Set-WdlEntry $entry $(if ([string] $entry.status -in 'Blocked', 'Deferred', 'Failed') { [string] $entry.status } else { 'AwaitingTechnician' }) "Not activated yet. $($st.detail)" $st }
    }
    foreach ($k in 'windows', 'office') { if ($State.activation[$k]) { Write-WdlLog $LP "$($Action): $k = $($State.activation[$k].status). $($State.activation[$k].message)" } }
    Save-WdlResult $Paths $State
    return $State.activation
}
