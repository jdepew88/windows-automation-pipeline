#Requires -Version 5.1
<#
.SYNOPSIS
    Applies the ongoing (post-deployment) Windows Update policy after the initial update stage.

.DESCRIPTION
    Phase 4.3. Dot-sourced by Complete-Deployment.ps1 (and so by DeploymentOrchestrator.ps1). It is
    part of the package only when the deployment runs the initial Windows Update engine AND the
    chosen ongoing policy is a "notify" mode; otherwise the answer file writes the policy during
    specialize exactly as before.

    The initial update engine (WindowsUpdateEngine.ps1) is not changed and does not read this
    policy. This step runs from the SYSTEM monitor only once the windowsUpdate stage has a final
    result (or when the deployment ends at its deadline), applies the documented
    "Configure Automatic Updates" registry policy once, reads it back and records the outcome:

      Applied               NoAutoUpdate/AUOptions written and read back
      AlreadyApplied        the values were already exactly these
      Unsupported           Windows Home: the policy is not supported; Windows defaults stay
      ManagedByOrganization domain, MDM or update-server management detected; nothing written
      Conflict              other Automatic Updates policy values already exist; left unchanged
      Failed                writing or reading back failed

    The outcome is stored in the deployment state (explicit completion state) and in
    <dataRoot>\<updatePolicy.result>. It never stops the Windows Update service, never blocks
    endpoints and never touches Defender security intelligence updates.
#>

$script:WddPolicyWuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$script:WddPolicyAuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$script:WddPolicyOkStatuses = @('Applied', 'AlreadyApplied')

# Adapters (replaced by the scenario tests) --------------------------------------------------------

function Get-WddEditionId {
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    if ($cv -and $cv.PSObject.Properties['EditionID']) { [string] $cv.EditionID } else { '' }
}

<# Reasons why the computer is managed by an organization (empty when it is not). #>
function Get-WddUpdateManagement {
    $reasons = @()
    try { if ((Get-CimInstance -ClassName Win32_ComputerSystem).PartOfDomain) { $reasons += 'joined to an Active Directory domain' } } catch { }
    $wu = Get-ItemProperty -LiteralPath $script:WddPolicyWuKey -ErrorAction SilentlyContinue
    if ($wu -and $wu.PSObject.Properties['WUServer'] -and [string] $wu.WUServer) { $reasons += 'configured for an update server (WSUS)' }
    $mdm = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update' -ErrorAction SilentlyContinue
    if ($mdm -and $mdm.PSObject.Properties['AllowAutoUpdate']) { $reasons += 'Windows Update is managed by device management (MDM)' }
    $reasons
}

function Get-WddAuPolicyValues {
    $k = Get-ItemProperty -LiteralPath $script:WddPolicyAuKey -ErrorAction SilentlyContinue
    $o = @{}
    foreach ($n in 'NoAutoUpdate', 'AUOptions', 'ScheduledInstallDay', 'ScheduledInstallTime', 'NoAutoRebootWithLoggedOnUsers') {
        $o[$n] = $(if ($k -and $k.PSObject.Properties[$n]) { [int] $k.$n } else { $null })
    }
    return $o
}

function Set-WddAuPolicyValue {
    param([string] $Name, [int] $Value)
    if (-not (Test-Path -LiteralPath $script:WddPolicyAuKey)) { New-Item -Path $script:WddPolicyAuKey -Force | Out-Null }
    New-ItemProperty -LiteralPath $script:WddPolicyAuKey -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

# Policy -------------------------------------------------------------------------------------------

function Invoke-WddUpdatePolicy {
    param([hashtable] $Policy, [hashtable] $Paths)
    $want = [ordered]@{ NoAutoUpdate = [int] $Policy.values.NoAutoUpdate; AUOptions = [int] $Policy.values.AUOptions }
    $r = [ordered]@{ status = ''; mode = [string] $Policy.mode; values = $want; appliedUtc = (Get-WddNow).ToString('o'); message = '' }
    try {
        $edition = Get-WddEditionId
        if ($edition -match '^Core') {
            $r.status = 'Unsupported'
            $r.message = "Windows $edition (Home) does not support the Configure Automatic Updates policy. Windows' default update behaviour stays in place."
        } else {
            $managed = @(Get-WddUpdateManagement | Where-Object { $_ })
            $have = Get-WddAuPolicyValues
            if ($managed.Count -gt 0) {
                $r.status = 'ManagedByOrganization'
                $r.message = "This computer is $($managed -join '; '). Organizational policy takes precedence, so the ongoing update policy was not written."
            } elseif ($have.NoAutoUpdate -eq $want.NoAutoUpdate -and $have.AUOptions -eq $want.AUOptions) {
                $r.status = 'AlreadyApplied'
                $r.message = 'The Automatic Updates policy already had these values.'
            } elseif (@($have.Keys | Where-Object { $null -ne $have[$_] }).Count -gt 0) {
                $r.status = 'Conflict'
                $r.existing = $have
                $r.message = 'Automatic Updates policy values already exist on this computer and were left unchanged.'
            } else {
                foreach ($n in $want.Keys) { Set-WddAuPolicyValue $n $want[$n] }
                $check = Get-WddAuPolicyValues
                if ($check.NoAutoUpdate -eq $want.NoAutoUpdate -and $check.AUOptions -eq $want.AUOptions) {
                    $r.status = 'Applied'
                    $r.message = "Configure Automatic Updates = $($want.AUOptions) ($(if ($want.AUOptions -eq 3) { 'download automatically, notify before installing' } else { 'notify before downloading and installing' }))."
                } else {
                    $r.status = 'Failed'
                    $r.message = 'The policy values could not be read back after writing them.'
                }
            }
        }
    } catch {
        $r.status = 'Failed'
        $r.message = "Applying the update policy failed: $($_.Exception.Message)"
    }
    Write-WddLog "Ongoing update policy: $($r.status). $($r.message)" $(if ($r.status -in $script:WddPolicyOkStatuses) { 'INFO' } else { 'WARN' })
    try { Write-WddJson (Join-Path $Paths.Root ([string] $Policy.result)) $r } catch { Write-WddLog "Could not write the update policy result: $($_.Exception.Message)" 'WARN' }
    return $r
}

<#
    Applies the policy once: only after the windowsUpdate stage is Final, or with -Force when the
    deployment ends. Returns the recorded result, or $null while it is still waiting.
#>
function Step-WddUpdatePolicy {
    param([hashtable] $Manifest, [hashtable] $Paths, [hashtable] $State, $Snapshot, [switch] $Force)
    if (-not $Manifest.ContainsKey('updatePolicy') -or -not $Manifest.updatePolicy) { return $null }
    if ($State.ContainsKey('updatePolicy') -and $State.updatePolicy) { return $State.updatePolicy }
    $wu = @(@($Snapshot.stages) | Where-Object { $_ -and $_.id -eq 'windowsUpdate' }) | Select-Object -First 1
    $final = [bool] ($wu -and $wu.state -eq 'Final')
    if (-not $final -and -not $Force) { return $null }
    $r = Invoke-WddUpdatePolicy $Manifest.updatePolicy $Paths
    if (-not $final) { $r.note = 'Applied when the deployment ended; the initial Windows Update stage had not reported a final result.' }
    $State.updatePolicy = $r
    return $r
}
