# Phase 8 testing

No driver was installed and no real driver store, device, network adapter, BIOS, firmware, USB drive
or Windows installation was touched. The owner's computer was not inventoried by any test (the only
local commands were `pnputil /?` and HTTP status checks of public support pages).
`Drivers.Tests.ps1` loads the engine **from the real generated deployment package** (drivers fixture,
with its real `drivers-config.json`) and replaces every system adapter: Plug and Play devices and
their drivers and problem codes, pnputil (with Windows-ranking effects: works, needs a restart,
breaks the device, not selected, fails, signature refused), downloads, `expand.exe`, catalog
signatures, the network, restarts (boot time), device-installation policy, the clock. The offline
bundle is written by TypeScript in the bundle tool's format and validated by PowerShell.

## Results (2026-10-22)

| Check | Result |
|---|---|
| typecheck, lint, production build | clean (bundle-size advisory as before) |
| Vitest | **460 passed in 21 files** (Phase 7: 440 in 20): `drivers.test.ts` 19 new, `powershell.test.ts` +1 suite |
| `Drivers.Tests.ps1` (driver engine, orchestrator and recovery-tool integration) | **26/26** (new) |
| `Media.Tests.ps1` (USB assistant) | **29/29** (27 + 2 driver scenarios) |
| Windows Update / applications / migration / deployment / Wi-Fi suites | 25/25, 89/89, 24/24, 46/46, 10/10 |
| Playwright (desktop, tablet, Pixel 7) | **157 passed, 2 skipped** (Phase 7: 142 + 2): `drivers.spec.ts` 5 tests x 3 sizes; screenshots reviewed in light and dark themes |
| Mutation checks | 3 of 10 completed, all detected (healthy driver replaced without approval; Windows Update not waited for; invalid catalog signature accepted). The run was stopped by the system for low memory while the 4th ran; the engine source was checked and restored. Not re-run |
| Regression | profiles of schema 1-4 import with the stage off; "everything off" still reproduces the Milestone 1 answer file byte for byte; snapshot changes reviewed line by line (driver stage entries, the changed orchestrator/recovery scripts and their hashes only) |

Existing tests changed for Phase 8 (contract changes, not weaker checks): the report of a package with
the stage off says `NotPartOfDeployment` instead of `NotImplemented`; the manifest/orchestration
assertions describe the implemented stage; the `noApps` helper (used to reproduce earlier owner
defaults) also turns the driver stage off; the assistant ZIP lists the driver validator; diagnostics
may collect from `Drivers\`; the package-stage pill says On.

## Scenario coverage (`Drivers.Tests.ps1`)

| Area | Scenarios |
|---|---|
| A. Intel desktop + NVIDIA | only the GPU on the basic display driver is installed (one pnputil call), from the bundle, verified; Intel chipset/Ethernet and Realtek audio untouched; NVIDIA App/CUDA/Intel DSA listed as optional only; without a package: manual action with the NVIDIA page, branch policy, Windows Update policy named |
| B. AMD desktop healthy | no download, no installation; newer bundle package reported as optional |
| C. Dell laptop | OEM-customized Wi-Fi/iGPU not replaced by generic packages even with an approval for the generic ID; Microsoft touchpad driver healthy; Dell page for the missing platform device |
| D. missing network driver | bootstrap from the bundle during Inspection A, connectivity re-checked; without a package: state kept, flag, WaitingForNetwork, technician AddPackages resolves it |
| E. Setup-critical storage | VMD controller with a disk flagged Setup-critical; bundle tool marks storage packages; a broken storage controller with a disk is never changed |
| F. unsupported / unknown | no IDs → Unsupported; generic class-ID package refused as uncertain; unknown vendor visible; software devices not reported as hardware |
| G. healthy + newer | kept; replaced only with an approval for that package and hardware ID |
| H. broken after install | DeviceFailure, blocked, rollback instructions, event 4110, RetryFailed does not reopen, technician `-IncludePermanent` can |
| Selection | exact HWID with subsystem, generic compatible ID refused, later HWID ranks after, class mismatch, wrong architecture, wrong Windows build, unsigned, Authenticode-only, other device model, OEM subsystem rule, same driver not repeated, Code 10 not treated as a driver problem, no downgrade |
| Windows Update | waits; restart before Inspection B; device fixed by Windows Update = AlreadySatisfied (windowsUpdate); three inspections |
| Verification | restart required → verified after the restart; exit 0 with an unchanged device is not success; failed install retried within the limit; signature failure never retried, not even by a technician |
| Bundle | TypeScript-written bundle validates; wrong pinned hash; modified file; unlisted file; catalog re-checked; modified copy on a drive never staged; bundle tool refuses unsigned packages and ignores EXEs; pnputil delete/force refused by the adapter itself |
| Verified download | official host, SHA-256, verified copy, no partial file; tampered file deleted, Integrity, not downloaded again; offline waits without using attempts |
| Policy, recovery, lifecycle | device-installation restrictions respected; interrupted install reconciled from the device; damaged state falls back to its last good copy; full lifecycle A → Windows Update → restart → B → install → restart → verified → drivers.json; a later start does nothing |
| Privacy | USB serial number never in the inventory or drivers.json; hashed instance ids |
| Integration | application gate waits only when configured, opens on any driver result and after waitForUpdatesHours; orchestrator stages, snapshot, report section, remaining tasks, outstanding operations, PausedAwaitingNetwork; recovery Status/PendingActions/RetryFailed |

USB assistant (`Media.Tests.ps1`): bundle required when it carries Setup-critical drivers, another or
modified bundle refused, copied and verified to `WindowsDeployment\drivers`, only the storage package in
`$WinPEDriver$`, the drive still passes `Stage-Deployment`; a foreign `$WinPEDriver$` moved to
`WDB-previous`; a missing Setup driver file makes Verify Incomplete; a package without drivers never
copies a bundle.

## Not tested: needs real hardware (status: UNVERIFIED)

CIM data on real devices, pnputil behaviour and exit codes, Windows driver ranking, `/scan-devices`
on a driverless device, `$WinPEDriver$` loading by Windows Setup, real NVIDIA/AMD/Intel/OEM packages,
Authenticode results of real catalogs, restarts, network bootstrap with a real adapter. See
[bare-metal-checklist.md](bare-metal-checklist.md).
