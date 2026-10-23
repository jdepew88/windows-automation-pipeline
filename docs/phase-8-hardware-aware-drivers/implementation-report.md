# Phase 8 implementation report: hardware-aware drivers

Branch `feature/phase-8-hardware-aware-drivers`, from Phase 7 `555517d` (verified locally and on
GitHub). Not merged, not deployed. No driver was installed, no driver store, device, network adapter,
BIOS, firmware or USB drive was changed during development; no Windows installation was run. Real
hardware validation is deferred by the owner to the combined test after Phase 9.

Documents: [audit](audit.md), [architecture](architecture.md),
[inventory and identification](inventory-and-identification.md) (sources, identification,
assessment, inventory schema), [matching and sources](matching-and-sources.md) (ranking, trusted
sources, automated vs manual, Intel/AMD/NVIDIA, OEM, hardware applications),
[Windows Update](windows-update.md), [offline, Setup-critical, network bootstrap](offline-setup-network.md),
[sequencing and recovery](sequencing-and-recovery.md), [security](security.md), [testing](testing.md),
[Phase 9 integration](phase9-integration.md), [bare-metal checklist](bare-metal-checklist.md).

## Files

Added: `src/engine/drivers/scripts/DriverEngine.ps1`, `Install-DriverEngine.ps1`,
`src/engine/drivers/index.ts`, `src/engine/schema/drivers.ts`, `src/data/driver-sources.json`,
`src/features/drivers/index.ts`, `src/ui/drivers.ts`, `tests/powershell/Drivers.Tests.ps1`,
`tests/unit/drivers.test.ts`, `tests/e2e/drivers.spec.ts`, this folder.
Changed: `src/engine/drivers/contract.ts` (from interface stub to the result contract), profile schema 5
and migration, owner defaults, deployment package/manifest/orchestration/pipeline/application config,
`DeploymentCommon.ps1`, `Complete-Deployment.ps1`, `Show-DeploymentStatus.ps1`,
`DeploymentRecovery.ps1`, `ApplicationEngine.ps1` (driver gate), `WdbMediaAssistant.ps1` and
`src/engine/media/index.ts` (drivers), UI (layout, editors, icons, styles, review, wizard, deployment),
`quick.ts`, tests and fixtures, README and the roadmap, architecture, testing and Phase 7 layout docs.
Unchanged: the Windows Update engine, `WdbMigration.ps1`, Initialize/Stage scripts, the answer-file
structure (new embedded files only when the stage is on).

## Acceptance audit

| # | Requirement | Status | Evidence |
|---|---|---|---|
| 1 | Hardware identified by reliable identifiers | Done | PnP hardware/compatible IDs, PCI/USB/HDAUDIO/ACPI/HID parsing, subsystem, class code; never by name (fixtures A-F, privacy test) |
| 2 | Existing driver state inspected | Done | problem code, driver provider/version/date/INF, inbox vs third-party, restart pending, policy, driver store |
| 3 | Healthy drivers preserved | Done | fixtures A, B, C, G; zero installations on healthy hardware |
| 4 | Windows Update given priority | Done | gate + restart before Inspection B; AlreadySatisfied (source windowsUpdate) |
| 5 | Missing/malfunctioning drivers identified | Done | assessment table; basic display driver distinguished; hardware issues separated |
| 6 | Matching on compatibility evidence | Done | `Test-WdvCandidate` (IDs, class, arch, build, signature, OEM, version); Windows ranks |
| 7 | Trusted sources enforced | Done | driver store, pinned bundle, technician packages, official-host verified downloads; no URL guessed |
| 8 | Integrity and signatures checked | Done | per-file SHA-256, manifest SHA-256, catalog WHQL/attestation; Integrity/Signature never retried |
| 9 | Verified offline packages | Done | bundle tool (Export/Bundle/ValidateBundle), staging from the USB, technician AddDrivers |
| 10 | Setup-critical needs distinguishable | Done | storage controller with a disk + non-inbox driver; storage-class packages; `$WinPEDriver$` via the assistant |
| 11 | Missing network drivers handled | Done | bootstrap before Windows Update; flag + PausedAwaitingNetwork; AddDrivers |
| 12 | Optional vendor applications separated | Done | `optionalApplications` (required: false); no installer is ever run |
| 13 | Phase 5 recovery integrated | Done | lifecycle names, failure classes, attempts.jsonl, recovery tool Status/Pending/RetryFailed/Retry/Resume/AddDrivers/diagnostics |
| 14 | Phase 6 excludes hardware restoration | Done | unchanged exclusion; Phase 8 evaluates those tools as optional applications |
| 15 | Phase 7 recognizes driver requirements | Done | `media.drivers` block, `-Drivers`, verification, `$WinPEDriver$` hygiene |
| 16 | Provisioning order consistent | Done | drivers after Windows Update, applications after drivers (gate only when configured) |
| 17 | Structured driver result | Done | `reports\drivers.json` + JSON Schema + TS types; health statuses for Phase 9 |
| 18 | All tests pass | Done | [testing.md](testing.md) |
| 19 | Older configurations compatible | Done | schema 5 migration (stage off), engines read configurations without `coordination.drivers` unchanged |
| 20 | Documentation | Done | this folder, README, roadmap, architecture, testing |

## Automated vs manual

Automated: keeping working drivers; Windows Update drivers (when the deployment allows them);
driver-store re-evaluation; pinned offline bundle; `$WinPEDriver$` at Setup; technician packages;
technician-verified INF downloads; approved replacements. Manual (reported with the official page):
vendor EXE installers (NVIDIA, AMD, Intel, OEM), OEM update tools, BIOS/firmware, rollback, devices
with hardware-type problem codes, unidentifiable devices, anything a candidate check refuses. No vendor
website is crawled and no OEM catalog API is called: universal OEM driver installation does not exist
in this implementation.

## Known limitations

- Everything was tested against simulated devices, drivers, pnputil, downloads and signatures; behaviour
  on real hardware (CIM property availability on every device, pnputil exit codes and output, Windows'
  ranking, timing of device restarts) is unverified.
- Windows Update installs no drivers with the owner default (`excludeDrivers`); then only the driver
  store, the bundle and verified packages can fill gaps.
- `pnputil /scan-devices` for driver-store candidates relies on Windows re-evaluating a driverless
  device; verified afterwards, not assumed.
- Signature acceptance requires Microsoft's hardware publisher (WHQL/attestation). Some legitimate OEM
  packages signed otherwise are refused and become manual actions.
- NVIDIA, AMD and most OEM downloads are EXE installers: they are never automated; an INF package must
  be extracted by a technician (or come through Windows Update / the Microsoft Update Catalog).
- A bundle is only as good as the computer it was exported from; packages are used only where the
  hardware IDs match, but a wrong-but-matching package (e.g. another OEM's) is only refused by the
  subsystem rule for working devices.
- OEM customization is detected from PCI subsystem vendor IDs of known manufacturers; others are treated
  as generic.
- `$WinPEDriver$` loading by Windows Setup is documented by Microsoft but not tested here (no boot).
- Restarts are bounded (`maxReboots`, default 2); further needs are reported.
- Rollback is instructions only; drivers are never removed.

## Deferred

Real hardware validation (combined bare-metal test); OEM catalog integrations (Dell, HP, Lenovo
catalogs) and vendor EXE automation (only with verified command lines); firmware/BIOS updates (separate
safeguards needed); WinPE driver injection for PXE; the Phase 9 health dashboard.
