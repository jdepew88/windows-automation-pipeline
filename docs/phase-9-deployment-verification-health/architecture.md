# Phase 9 architecture: deployment verification and health

Phase 9 adds one read-only component, `DeploymentHealth.ps1`, that checks what a deployment was
meant to achieve against the installed Windows itself. It does not install, retry, repair or
reconfigure anything: the installers, the update engine, the driver engine, the restore library and
the Phase 5 recovery tool are unchanged and keep that job.

**A successful script exit is not evidence.** The engines' results are read as *evidence*. Each
expectation is then checked against Windows:

- the edition in the registry;
- the account and its group membership;
- the active computer name;
- uninstall records and Store packages;
- device problem codes;
- Defender, the firewall and User Account Control;
- BitLocker;
- the network and the system volume.

```
 website (Advanced › Verification & Health)                     installed computer
 ─────────────────────────────────────────                     ───────────────────
 healthConfig(p) → health-config.json  ─┐  embedded in the     <dataRoot>\Package\scripts\health\
 HealthReport.html (template)           ├─ answer file and the  (verified staged copy)
 DeploymentHealth.ps1                   ┘  WindowsDeployment\        │
                                                                     ▼
 Complete-Deployment.ps1 (monitor, SYSTEM) ── state Completed ──► Invoke-WdhAfterDeployment
 "Windows Deployment — Health Report" shortcut ─(elevated)──────► -Mode Dashboard
 DeploymentRecovery.ps1 menu 9 / -Action Verify ────────────────► Invoke-WdhVerify (Recovery)
 \WindowsDeploymentBuilder\HealthCheck (after a pending restart) ► -Trigger Startup (removes itself)

 evidence (read)                                Windows (read, through Get-Wdh* adapters)
 state\deployment.json(.bak)  Updates\result.json   Win32_OperatingSystem, CurrentVersion, Setup\State
 Deployment snapshot (Get-WddSnapshot)              SoftwareLicensingProduct (status only)
 Applications\result.json, state.json(.bak)         ComputerName keys, Get-LocalUser, ADSI Administrators
 Applications\restoration.json                      ProfileList, Winlogon (no password value)
 reports\drivers.json                               Win32_Service, Get-MpComputerStatus, SecurityCenter2
 state\network-driver-missing.json, policy result   Get-NetFirewallProfile, UAC/SmartScreen registry
 the staged manifest (integrity: SHA-256)           Get-BitLockerVolume (protector types only)
                                                    Win32_PnPEntity, uninstall records, Get-AppxPackage
                                                    Get-NetAdapter, DNS, NCSI probe, Get-Volume, fsutil
                                                    Get-PhysicalDisk / reliability counters (optional)
                                     │
                                     ▼
 <dataRoot>\reports\health\deployment-health.json   technician-report.html   customer-handoff.html/.json
                           history\deployment-health-<time>-<status>.json    recheck.json
```

## Where each result comes from (dependency map)

| Category | Expected state from | Evidence read | Checked against Windows |
|---|---|---|---|
| Windows | `health-config.json` › windows (edition id from the Setup edition, architectures, build ≥ 22000) | none | EditionID, ProductType, build/UBR, `Setup\State` ImageState, licence status, restart signals |
| Accounts and identity | › account, › identity (answer file's username, group, auto sign-in, derived name) | none | local users, Administrators members (S-1-5-32-544), ProfileList, Winlogon values, ActiveComputerName vs pending ComputerName |
| Windows Update | › windowsUpdate (stage on, skip optional/feature, driver policy, ongoing policy) | `Updates\result.json` (status, failed KBs), state `updatePolicy` | wuauserv start mode, Update Agent last search, optional live search (`-ScanUpdates`), `ExcludeWUDriversInQualityUpdate` |
| Hardware and drivers | › drivers | `reports\drivers.json` (Phase 8 contract), deployment id, `final` | Win32_PnPEntity problem codes and service (basic display), per device, matched by hardware ID |
| Applications | › applications.items (the selection only: automatic, manual follow-ups, Additional Software; required/optional) | `Applications\result.json`, `state.json` (+ `.bak`): status, detection, attempts, class, lifecycle | uninstall records (machine, and the deployment user's hive when loaded), WinGet `<id>_<source>` records, Store packages, the portable shortcut |
| Restored settings | › restoration (backup id, adapters) | `Applications\restoration.json` (backup status, outcome per adapter, review items) | staged backups under `<dataRoot>\Backup`; consistency with the application check |
| Security | › security (UAC level values, SmartScreen expected, device encryption prevented) | none | Defender status, Security Center products, firewall profiles, UAC values, SmartScreen setting/policy, BitLocker |
| Network | › network.requirement (auto/required/notRequired) | non-final stages, waiting/retryable operations, network-driver flag | physical adapters, gateway, DNS, NCSI connectivity test, TCP 443 to the WinGet source when needed |
| Storage | › options.storageObservations | none | Get-Volume (NTFS, health, free space), `fsutil dirty query`, Get-PhysicalDisk and reliability counters |
| Windows settings | › customizations (verification adapters) | none | registry values, machine-wide or in the deployment user's hive |
| Recovery and outstanding work | the manifest | deployment state, its backup, recoveries, the Phase 5 outcome | SHA-256 of every staged file (package integrity) |

## Audit findings (part 2)

| Area | Found | Phase 9 action |
|---|---|---|
| Final report | `Complete-Deployment.ps1` writes `deployment-report.json/.txt` from the engines' results only | Kept. The verification runs afterwards and adds a `health` block (report format 2 is unchanged and additive) |
| Phase 5 outcome | `Get-WddDeploymentOutcome` gives a machine-readable outcome | Used as evidence, mapped in [health-states.md](health-states.md); never redefined |
| Recovery tool | Status, retry, resume, restore settings, add drivers, diagnostics | Reused. Added Verify (menu 9), health files in the diagnostics, an archive check and a deployment-user guard |
| Deployment user | Stage launch records keep `user`; `Repair-WddDeploymentState` used the current account | The guard below. The rebuild now keeps the user from the engine's result |
| Driver policy | The owner default set **Do not include drivers with Windows quality updates**, while the driver stage waits for Windows Update drivers. The two contradict each other | The default is corrected (below) |
| StrictMode | `Initialize-Deployment.ps1` logged `"$script:DeployVersion: initialize"`. Under the StrictMode 2.0 the scripts enable, that throws, so a real first sign-in would have stopped. The existing tests run with StrictMode off, which hid it | Fixed (`$($script:DeployVersion)`). The Phase 9 scenarios run under StrictMode, and a static test forbids the pattern in every shipped script |
| Final Review | Additional Software entries were not listed with the selected applications (a known Phase 8 UI limitation) | Fixed: the "Additional Software" group in the summary and an "Additional Software" row |

## Design decisions

- **One engine, many triggers.**
  - The same functions run:
    - at the end of the deployment;
    - after a pending restart, from a startup task that removes itself after at most 3 runs;
    - from the desktop shortcut;
    - from the recovery tool.
  - Nothing depends on the USB drive. The engine reads the verified staged copy of its plan and
    template under `<dataRoot>\Package`.
- **The plan is written by the website, the truth is read on the computer.** `health-config.json`
  lists only what the deployment selected: never the 115-application catalog.
- **Independent where Windows allows it, honest where it does not.**
  - An application the engine installed but that no uninstall record, Store package or shortcut
    shows is reported as *uncertain*, never as missing on that basis alone.
  - A per-user item is checked in the deployment user's own registry hive, and only when that hive
    is loaded. The engine never loads a hive and never reads the technician's profile in its place.
    Otherwise the item is *Deferred*.
- **Adapters.** Every probe of Windows is a small `Get-Wdh*` function, so the scenario tests replace
  them with simulated computers. The orchestration, engines and evaluation stay real.
- **Reusable for later delivery methods.** Only `deployment-manifest.json`, the persistent state and
  the reports are needed. PXE or other media produce the same files.

## Driver policy correction (part 6, §14)

- **New deployments:** `updates.excludeDrivers` is now `false` in the owner defaults. Windows Update
  may offer compatible drivers during the initial updates, and the driver stage receives the same
  policy (`drivers-config.json › windowsUpdate.drivers = include`, manifest
  `drivers.policy.windowsUpdateDrivers = include`).
- **Older profiles:** an older profile that explicitly sets the policy keeps it. Profiles are
  imported with their values; only missing fields are filled.
- **Warning:** the website warns when the policy hides drivers while the driver stage waits for
  Windows Update.
- **Never overwritten:** the health engine reports a blocking `ExcludeWUDriversInQualityUpdate`
  (for example an organization's policy) as a warning and never writes it. Tests:
  `health.test.ts` › "Windows Update drivers during provisioning", `drivers.test.ts`,
  `Health.Tests.ps1` › package scenario.

## Deployment-user consistency (part 16, §42)

Per-user applications and settings belong to the account the application stage ran as.

- **Guard:** `DeploymentRecovery.ps1` RetryFailed, Retry, Resume and RestoreSettings now refuse to
  register the application stage for another administrator. They name the owner of the stage and the
  two authorized ways forward:
  - sign in as that user and run the tool there; or
  - pass `-RetargetUser`, which deliberately moves the remaining per-user installations to the
    current account. It is recorded in the launch record and the recovery history
    (`retargetUser: true`).
- **No cross-session launches:** no process is ever launched in another user's session.
- **Health engine:** it reads the intended user from the deployment state. Per-user checks stay
  Deferred while that user is signed out (scenario L).
