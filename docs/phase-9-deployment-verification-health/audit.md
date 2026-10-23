# Requirement-by-requirement audit

**Abbreviations.** Paths are relative to the repository:

| Short | File |
|---|---|
| E | `src/engine/health/scripts/DeploymentHealth.ps1` |
| C | `src/engine/health/index.ts` and `contract.ts` |
| HT | `tests/powershell/Health.Tests.ps1` |
| UT | `tests/unit/health.test.ts` |
| PW | `tests/e2e/health.spec.ts` |

**What "Real-world" means.** Every row is validated in simulation only. The column says what
physical validation remains ([bare-metal-checklist.md](bare-metal-checklist.md)). Nothing marked
done is documentation without code.

| § | Requirement | Implemented in | Tests | Windows behaviour relied on | Limitation | Real-world |
|---|---|---|---|---|---|---|
| 3 | Git baseline, branch | `feature/phase-9-deployment-verification-health` from `81deadc` (local = remote verified) | — | — | — | — |
| 4 | Audit, dependency map | [architecture.md](architecture.md) | — | — | — | — |
| 5 | Independent verification engine | E (`Invoke-WdhVerify`, `Test-Wdh*`) | HT A-L | Windows APIs per category | — | outstanding |
| 6 | PowerShell 5.1, SYSTEM, right user context | E (no PS 7 syntax; hive of the deployment user only) | HT (StrictMode), L; `HealthLiveProbe.ps1` | HKEY_USERS loaded hives; `Get-AppxPackage -User` | per-user items Deferred while the user is signed out | outstanding |
| 7 | Reusable (no USB dependency) | reads the staged package and state | HT (USB never used after staging) | — | PXE not built (out of scope) | — |
| 8 | Six health states, Phase 5 mapping | E `Get-WdhOverall`, C `HEALTH_STATES`, `PHASE5_OUTCOME_MAP` | UT parity; HT every state | — | — | — |
| 9 | Finding fields, severities | E `Add-WdhFinding`, C `HealthFindingSchema` | Vitest schema validation of HT output | — | — | — |
| 10 | Windows identity, activation separate from installation | E `Test-WdhWindows` | HT A, H | EditionID, SoftwareLicensingProduct | activation reported, never required | outstanding |
| 11 | Accounts | E `Test-WdhAccounts` | HT A, fault matrix | Get-LocalUser, ADSI group members, ProfileList, Winlogon | interactive account modes only reported | outstanding |
| 12 | Computer name, pending rename | E | HT fault matrix | ActiveComputerName vs ComputerName | — | outstanding |
| 13 | Windows Update health | E `Test-WdhUpdates`, `-ScanUpdates` | HT A, G, interrupted, read-only (scan) | Update Agent COM (read-only search) | no live search unless asked (stated in the report) | outstanding |
| 14 | Driver policy default, propagation, older profiles kept | `profiles/owner-default.json`, `features/updates` warning, E `updates.driverPolicy` | UT; `drivers.test.ts`; `windows-update.test.ts`; HT package | `ExcludeWUDriversInQualityUpdate` | — | outstanding |
| 15-16 | Applications: only the selection, independent detection, classifications | C `healthConfig`, E `Test-WdhApplications`, `Find-WdhInstalled` | UT plan; HT A, B, C, inconsistent, compatibility | uninstall records, WinGet `<id>_<source>` keys, Store packages, portable shortcut | an installer without uninstall record is "uncertain" | outstanding |
| 17 | Failures and recovery via Phase 5 | E `recoveryAction`, dashboard commands | HT K | — | — | outstanding |
| 18-19 | Restoration, application vs settings separate | E `Test-WdhRestoration` | HT F, F2, F3 | — | — | outstanding |
| 20 | Retained backups, confirmed cleanup | E `Invoke-WdhCleanupBackups` | HT F2, F3 | — | — | outstanding |
| 21-23 | Drivers vs live devices, categories, vendor review | E `Test-WdhDrivers` | HT D, G, J2 | Win32_PnPEntity problem codes | hardware-type codes are heuristics | outstanding |
| 24 | Security core | E `Test-WdhSecurity` | HT I, fault matrix | Get-MpComputerStatus, SecurityCenter2, Get-NetFirewallProfile, UAC values | SmartScreen from setting/policy only (optional) | outstanding |
| 25 | Privilege model, no hidden accounts | E `account.role`, `account.administrator` | HT fault matrix | — | — | outstanding |
| 26 | Encryption, recovery key never hidden | E `security.encryption`, `security.recoveryKey` | UT (no key reads) | Get-BitLockerVolume (needs administrator) | recovery-key backup cannot be verified locally: always asks | outstanding |
| 27-28 | Customizations of earlier phases, adapter contract | C `customizationAdapters`, E `Test-WdhCustomizations` | UT; HT A, L | registry | only existing settings (no Phase 8.5) | outstanding |
| 29 | Network readiness from the configuration | E `Test-WdhNetwork` | HT G, lost network | NCSI probe, DNS, gateway | — | outstanding |
| 30 | Storage, non-destructive | E `Test-WdhStorage` | HT fault matrix | Get-Volume, fsutil, Get-PhysicalDisk | not a drive diagnosis (stated) | outstanding |
| 31-33 | Local dashboard, categories, searchable applications | `HealthReport.html` | PW preview; HT HTML checks | any browser, offline | — | outstanding |
| 33 | Additional Software in Final Review | `preview.ts`, `app-summary.ts`, `quick.ts`, `wizard.ts` | UT; PW Final Review | — | — | — |
| 34 | Machine-readable report | E, C schemas | Vitest validates HT output | — | — | — |
| 35 | Technician report, printable | template (print CSS) | PW screenshots | browser print to PDF | no generated PDF (by design) | outstanding |
| 36 | Customer handoff, no secrets, honest headline | E `Get-WdhCustomerHandoff` | HT A (embedded data checked), B, H | — | — | outstanding |
| 37 | Read-only by default | E | HT read-only; UT static | — | — | — |
| 38 | Recovery entry points, no duplicate engine | dashboard commands, recovery menu 9 | HT K, recovery Verify | — | — | outstanding |
| 39 | Reverification, history, comparison | E `Save-WdhHistory`, `Get-WdhComparison` | HT E, K, restart during verification | — | — | — |
| 40 | Automatic verification, restart handling | `Complete-Deployment.ps1`, E startup re-check | HT A, E | scheduled task at startup | at most 3 re-checks | outstanding |
| 41 | Desktop entry point, no repeated windows | shortcut; progress window opens once | HT A | Explorer opens the HTML non-elevated | — | outstanding |
| 42 | Recovery-user consistency | `DeploymentRecovery.ps1` guard, `-RetargetUser`, state rebuild keeps the user | HT L | — | — | outstanding |
| 43 | Checklist from results, human confirmation | E `Get-WdhChecklist`, template | HT A, C | — | confirmations are not stored (printed) | — |
| 44 | Deterministic readiness rules | E `Get-WdhOverall` | HT all states | — | — | — |
| 45-46 | Redaction, diagnostic ZIP checked | recovery tool whitelist + `Test-WdrDiagnosticArchive`, E `Invoke-WdhExport` | HT export | — | pattern redaction not infallible (stated) | outstanding |
| 47 | Final Review summary | `quick.ts` verification block | PW | — | — | — |
| 48 | Advanced section, sensible defaults, no switch for integrity/security | `features/health`, `ui/health.ts` | PW; UT | — | — | — |
| 49 | Report preview with sample data | `sampleHealthReport`, iframe, CSP hash | PW; UT | — | — | — |
| 50 | Evaluator tests (states, severity, missing/corrupt/conflicting/stale evidence, reboot, manual, reverification, stable ids, compatibility) | — | HT | — | — | — |
| 51 | Scenarios A-L | — | HT (all pass) | — | — | — |
| 52 | Lifecycle through real orchestration | — | HT (extraction, staging, stages, monitor, completion, recovery, re-verification) | — | the driver stage's output is simulated in HT (its engine has its own suite) | outstanding |
| 53 | Cross-phase compatibility | migration v5→v6 | UT; existing fixtures (M1, P2, P4, P4.3, P5); HT compatibility | — | — | — |
| 54 | Fault injection | — | HT faults | — | — | — |
| 55 | Phase 8 mutations | — | 7 remaining run one by one: all detected (10/10), source restored | — | — | — |
| 56 | Browser coverage, Firefox | PW; `desktop-firefox` project (opt-in) | PW three viewports | — | Firefox needs Playwright's 1555 build (not installed) | outstanding |
| 57 | Regression | — | see implementation report | — | — | — |
| 58-59 | Documentation, this audit | this folder | — | — | — | — |
| 60-61 | Bare-metal plan, three gates | [bare-metal-checklist.md](bare-metal-checklist.md) | — | — | — | **outstanding** |
| 62 | Commit and push to the feature branch | — | — | — | not merged, not deployed | — |
