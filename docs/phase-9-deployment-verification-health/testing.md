# Phase 9 testing

Everything below is **simulation**: the real generated packages, the real orchestrator,
application engine, restore library, recovery tool and health engine, with Windows replaced by
simulated computers. No Windows installation, disk, driver, account or setting was changed. Real
hardware validation is outstanding ([bare-metal-checklist.md](bare-metal-checklist.md)).

## Suites

| Suite | What |
|---|---|
| `tests/powershell/Health.Tests.ps1` (27 scenarios, run by Vitest and `npm run test:ps`) | scenarios A-L, fault injection, the full lifecycle, re-verification, cleanup, diagnostics, read-only proof, compatibility. **Every scenario runs under `Set-StrictMode -Version 2.0`.** With `-Out`, the reports are validated by Vitest against `HealthReportSchema` and `CustomerHandoffSchema` |
| `tests/powershell/HealthSim.ps1` | the simulated computer of the health engine |
| `tests/powershell/ProvisioningSim.ps1`, `MigrationSim.ps1` | the orchestrator and application-engine simulation, moved out of `Deployment.Tests.ps1` unchanged and shared by both suites |
| `tests/powershell/Deployment.Tests.ps1` (46 scenarios) | the Phase 4-6 orchestrator scenarios. Verification now runs at every completion |
| `tests/powershell/HealthLiveProbe.ps1` (opt-in, not part of `npm test`) | the real, non-simulated probes on the computer that runs it, read-only, under StrictMode. Run once on the development computer: 51 findings, 0 check errors, 16 s. Store packages and BitLocker need elevation and were reported as "could not be read" in a non-elevated shell. No event, task or file outside a deleted temporary folder |
| `tests/unit/health.test.ts` (18) | the plan (only the selection, required/optional, Additional Software, edition ids, account, adapters); the driver-policy default and its propagation; schema 6 migration; the package and manifest; validation of notes; Final Review summary; template safety and the CSP hash; sample reports against the schemas; PowerShell/TypeScript parity (states, exit codes, categories, Phase 5 mapping); static safety (no side-effect cmdlets, no secret reads, no `$scope:name:` interpolation in any shipped script) |
| `tests/e2e/health.spec.ts` (5 × desktop, tablet, Pixel 7) | the Advanced section and its effect on the ZIP; verification off removes the engine; secret-looking notes refused; previews with sample data (keyboard, region, search, customer notes); Final Review lists Additional Software and the verification, matching the ZIP's plan; light/dark, no horizontal scroll, screenshots of the section and of both reports |

## Scenarios (part 20 and 21)

| Scenario | Result checked |
|---|---|
| A Perfect deployment (Windows 11 Pro, `owner`, `owner-Computer`, updates, drivers, 10 selected applications incl. Store and portable, customizations) | **Ready**, exit 0, every category Verified or NotApplicable, checklist, shortcut, event 5000, customer handoff (no technical data), deployment report `health` block |
| B Optional application (VLC, integrity failure) | **ReadyWithWarnings**, finding Fail/Warning, `Retry -IncludePermanent`, customer told what is not installed |
| C Required application (Git) missing | **NeedsAttention**, checklist "not done" |
| D NVIDIA GPU reports code 43 after its driver was installed | **NeedsAttention**: "a driver was installed for it, but the device still reports a problem". Also: a missing driver (code 28), a basic display driver (warning), a disabled device (information) |
| E Windows Update restart pending | **Incomplete**, startup re-check registered. After the restart: **Ready**, the task removed itself, "windows.restart" resolved, history kept |
| F Settings restoration failed (backup not supplied) | **NeedsAttention**: VS Code installed (Pass) and its settings not restored (Fail) as separate findings, RestoreSettings |
| F2 Restored, backup retained | warning without private details; cleanup refused without the exact confirmation, refused for non-administrators, done with it; USB copy untouched; re-verified |
| F3 Tampered backup | rejected and reported, nothing restored, cleanup never during outstanding restoration |
| G No network driver | Incomplete with `network.driver` "will not appear by itself", AddDrivers |
| H Home instead of Pro | **Failed** (critical), exit 60, customer not told it works |
| I Security | firewall off for every profile: Failed (critical); for some profiles: Error; Defender off with a registered antivirus: hand-over (Pass); no antivirus: Failed; UAC off unexpectedly: NeedsAttention |
| J, J2 Damaged evidence | corrupt application results, corrupt deployment state, corrupt or foreign driver report: **Unverifiable** |
| K Technician recovery | NeedsAttention, then the real recovery tool's RetryFailed, one reinstall, **Ready**, the failed report in the history, resolved finding by id |
| L Another administrator | per-user application and settings **Deferred** (Unverifiable), never read from the technician's profile; read from the owner's hive when signed in; the recovery tool refuses to retarget without `-RetargetUser`, records it with it |

### Health engine 1.2.0: package-aware application verification (simulated)

| Scenario | What it checks |
|---|---|
| V1 | Win32 uninstall records. Adobe Acrobat Reader is found by display-name prefix in the machine-wide 64-bit records, where its name alone would not match. A 32-bit (WOW6432Node) record is marked "(32-bit)". Each item shows its version, `where` and engine outcome. |
| V2 | Store/MSIX. ChatGPT is registered for the owner, with no uninstall record needed. Another package is provisioned only (`where: provisioned`). When both are absent and the evidence is readable, the result is InstallerSucceededVerificationFailed (Warning). |
| V3 | Per-user (Claude Desktop). A file in the owner's profile is verified while the owner is signed in, and also while signed out. With no profile and no hive, the result is pending (Deferred), never missing. When the evidence is readable and absent, the verification failed. |
| V4 | SYSTEM context. The user has no profile and is not signed in, so the result is pending and the reason names SYSTEM. The engine's note is kept as history. `-CheckAppUpdates` returns notAsSystem, with no WinGet call. |
| V5 | Node.js by its file and file version, with no uninstall record. A registry value in the 32-bit view is checked. A different exact value is not evidence, and the finding reports the mismatch. The engine's earlier evidence never counts as current evidence. |
| V6 | Engine 1.6.0 outcomes: PackageUnavailable (Fail) and UnattendedUnsupported (Warning, manual action). With `after` signIn, the result is pending. With `after` restart, it is pending only while a restart is pending. Every Pass has evidence. |
| V7 | Visual C++ 2015+. x86 present with x64 missing gives a Warning saying "the x86 runtime does not replace it", and the reverse case is checked too. x86 is never called redundant. The text report has its own section. |
| V8 | `-CheckAppUpdates` as the deployment user. The WinGet table is matched to the selected applications. The result is Info only, and the overall state stays Ready. A WinGet failure reports its exit code (0x8A150014). Without the switch, WinGet is not called. |
| L (updated) | Another administrator's check makes per-user Notepad++ InstallerSucceededVerificationPending. a Store app registered for the owner (ChatGPT) is still verified, because AppX evidence is readable by SID without the owner's hive. |
| compatibility (updated) | An application result without the 1.6.0 fields and a plan without `verify` blocks still verify every application. |
| W12 (updated) | The schema-validated full report also contains `runtimes`, `appUpdates`, file evidence and engine evidence. |

HealthSim.ps1 also answers the application engine's own evidence probes (`Get-WdaDeploymentUser`,
`Get-WdaUninstallEntries`, `Get-WdaAppx*`, `Get-WdaFileEvidence` and `Get-WdaRegistryValue`) from
the same simulated computer. A simulated installer leaves the evidence that its catalog `verify`
block names. So the engine run by a scenario never reads the real computer, and both engines agree
on what is installed. `Deployment.Tests.ps1` covers the recovery actions Reverify applications (a
simulated process, exit codes 0, 10, 20 and older engines, stderr kept) and Check for application
updates (as the user and as SYSTEM). It also checks that the menu lists the read-only actions and
the installing actions separately.

## Fault injection (part 22)

| Fault | Result |
|---|---|
| Lost network | Incomplete, Internet required while applications wait; offline after completion is not a failure |
| Interrupted update | Incomplete, update stage Pending, outstanding stage |
| Incomplete deployment, deadline passed | Phase 5 outcome Incomplete is a failure with Resume |
| Inconsistent status | no engine record and absent: Fail (inconsistent); success without a record: uncertain; present without a record: Pass |
| Restart during verification | the next run compares with the newest archived report; finding ids stable across runs |
| Wrong edition, Defender off, account not an administrator, wrong computer name, unavailable probe, disk nearly full | never Ready or ReadyWithWarnings |
| Failed or unsafe export | non-.zip refused; a failing export reported; backup, answer-file and `..` entries detected by both archive checks; passwords redacted |
| Corrupted JSON, missing or tampered backup, security off, wrong edition, profile mismatch | J, F, F3, I, H, L |
| Read-only | no file below the data root changes outside `reports\health`; no task, shortcut or window |
| Compatibility | a result without lifecycle fields (schema 1) and a health configuration without optional sections, under StrictMode |
| No deployment on the computer | Unverifiable, exit 50 |

## Phase 8 mutation testing (completed)

The 7 cases left over from Phase 8 ran one at a time against `Drivers.Tests.ps1`. Each was detected,
and `DriverEngine.ps1` was restored and byte-identical afterwards:

- download hash not checked;
- exit code trusted as success;
- security failures reopened;
- OEM subsystem rule removed;
- generic compatible ID accepted;
- boot-critical storage driver changed;
- network bootstrap skipped.

Total: **10 of 10 detected**.

## Not covered

- **Firefox.** The project `desktop-firefox` (the Advanced scroll regression) is opt-in
  (`E2E_FIREFOX=1`). The installed Playwright Firefox build (1543) does not match Playwright 1.64
  (1555), and downloading a browser was out of scope here. Run `npx playwright install firefox` first.
- **Real computers.** Real devices, Defender, BitLocker, Store packages and Windows Update searches
  are simulated in the scenarios. Only the read-only live-probe smoke test touched real APIs, on the
  development computer.
