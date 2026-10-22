# Phase 5 security controls

Recovery is never less strict than the first installation: a retried operation is installed by the
same engine code, with the same identifiers, sources and checks.

| Control | How it holds during retry and recovery |
|---|---|
| Source verification | Operations come only from the staged, hash-verified `applications-config.json` and `winget-packages.json`. The recovery tool verifies every staged file against the manifest before it does anything and refuses a modified package (`IntegrityFailed`). Ids are matched against `^app:(winget\|msstore):[a-z0-9][a-z0-9._+-]{0,127}$` / `^additional:…$` and must be in the permitted set; a package definition is re-validated (`Test-WdaPackageSpec`) before it is reopened. |
| Package integrity | WinGet verifies every installer's SHA-256 on every attempt; a mismatch is class Integrity and never retried automatically. Additional Software: hash and Authenticode signature are checked again on each attempt. Retries never pass extra flags (no `--ignore-security-hash`, no override). |
| Explicit deselections | Deselected apps are not in the installable set; Retry refuses them ("explicitly deselected for this deployment"). |
| Antivirus conflicts | Mutually exclusive real-time antivirus products are refused at generation time (Phase 4.2 validation), so a conflicting pair never reaches the plan a retry draws from. |
| Manual and unresolved entries | Never installable; Retry refuses them. |
| Permanent failures | Only with `-IncludePermanent`, an explicit technician decision; the same checks apply again. |
| Arbitrary code | The recovery tool and the engine never evaluate input (`Invoke-Expression`, `[scriptblock]::Create` and the like are absent and checked by a unit test). Imported configuration cannot add commands: WinGet arguments are built from validated tokens only (`Invoke-WdaWinGet` refuses anything else). The only process the recovery tool starts itself is its own elevation prompt. |
| Who can recover | Administrators only (status is readable without elevation). Application retries run as the deployment user, never SYSTEM. The tool works only against the deployment state of this computer and refuses a package whose id differs from the deployment's. |
| Concurrency | The deployment mutex (monitor, setup, recovery) and the application engine's mutex: a retry never edits a state that an engine is using. |
| State files | Machine-wide below ProgramData with the existing ACL (SYSTEM/Administrators full, Users read). They contain identifiers, codes, classes and the engine's own messages; no password, Wi-Fi key or token. Malformed or future-version states are rejected, not trusted. |
| Secrets in diagnostics | Only a fixed list of files below the data folder is collected; `.xml` files (Wi-Fi profiles), answer files and Panther logs are never read. Values of `password`, `keyMaterial`, `networkKey`, `secret`, `token` (JSON, XML or `name=value`) are replaced by `[redacted]` as defence in depth (tested with a planted password and Wi-Fi key). |
| Windows Defender and Firewall | Not touched by any Phase 5 code (no `Set-MpPreference`, `Add-MpPreference`, firewall cmdlets or `netsh advfirewall`; checked by a unit test). |
| Network settings | The network diagnosis only reads (adapters, routes, DNS resolution, a TCP connection, the Windows connectivity probe); it never changes Wi-Fi, DNS, proxy, VPN or firewall settings. |
| Remote access | Nothing grants unattended remote access; RustDesk stays a manual follow-up with its existing instructions (no permanent password). |
| Media and disks | Nothing in Phase 5 touches partitions, formats a drive, erases installation media or reinstalls Windows; recovery works on the installed system only. |
| Limits | Retry counts, delays, deferrals, runtime, restarts and the deployment deadline are all bounded and clamped; the queue loop has a hard iteration bound. |
