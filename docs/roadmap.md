# Roadmap

## Milestone 1 (this repository)

Done in code and covered by automated tests. **Not validated with WSIM or a VM**; see `testing.md`.

## Phase 2: Windows Update automation (branch `feature/phase-2-windows-updates`)

Implemented and covered by automated tests, plus one read-only scan on real Windows. **Not
validated in a VM**; see `testing.md` C. Review: `phase-2/review.md`. Report:
`phase-2/implementation-report.md`.

## Phase 3: WinGet provisioning (branch `feature/phase-3-winget-provisioning`)

Implemented and covered by automated tests, plus read-only checks on real Windows (WinGet check,
dry-run plan, `winget import` format acceptance). **Not validated in a VM**; see
`phase-3/testing.md`. Report: `phase-3/implementation-report.md`.

## Phase 4: USB deployment and first-boot orchestration (branch `feature/phase-4-usb-deployment`)

Implemented and covered by automated tests (simulated machine, real generated package), plus a
read-only package verification on real Windows. **Not validated in a VM or on hardware**; see
`phase-4-usb-deployment/testing.md`. Report: `phase-4-usb-deployment/implementation-report.md`.
This delivers the former "Milestone 3: deployment bundle" items except PowerShell 7 via the catalog.

## Phase 4.2: application catalog, profiles and device ecosystems (branch `feature/phase-4-2-application-profiles`)

Implemented and covered by automated tests (simulated WinGet, the real generated package, browser
tests at three sizes), plus read-only WinGet verification and an engine Plan run on real Windows.
**Not validated in a VM or on hardware**; see `phase-4-2-application-profiles/testing.md`. Report:
`phase-4-2-application-profiles/implementation-report.md`.

## Phase 4.3: Quick Deployment wizard (branch `feature/phase-4-3-quick-deployment-wizard`)

Quick Deployment wizard sharing one configuration with the unchanged Advanced Configuration, four
catalog layouts with logos, Final Review & Considerations, the ongoing Windows Update policy applied
after the initial updates, and Wi-Fi provisioning with adapter checks. Covered by automated tests
(simulated machine, real generated package, browser tests at three sizes). **Not validated in a VM
or on hardware**; see `phase-4-3-quick-deployment-wizard/testing.md`. Report:
`phase-4-3-quick-deployment-wizard/implementation-report.md`.

## Phase 5: resilient provisioning, resume and retry (branch `feature/phase-5-resilient-provisioning`)

Failure classes and bounded automatic retry with backoff, network and package-source aware
deferral, crash and power-loss reconciliation, atomic state with last-good backups and versioned
migrations, machine-readable outcomes and exit codes, outstanding work kept after the deployment
ends, and the technician recovery tool (status, retry one or all, resume, pending actions,
diagnostics without secrets). Covered by automated tests, including fault injection, the real
generated package, the real engine and the recovery tool on a simulated machine. **Not validated in
a VM or on hardware**; the first real test is on bare metal:
`phase-5-resilient-provisioning/bare-metal-checklist.md`. Report:
`phase-5-resilient-provisioning/implementation-report.md`.

The remaining roadmap: Phase 6 application backup and restore, Phase 7 USB media preparation
assistant, Phase 8 hardware-aware drivers, Phase 9 deployment verification and health (it can read
`attempts.jsonl`, `status.json` outcomes and report v2).

## Milestone 2: validation and hardening

- Run WSIM validation and both VM runs (with and without Internet). Fix any findings and record a `docs/validation-log.md`.
- Confirm or replace the unverified mechanisms: persistent auto-logon, shortcut-arrow overlay, `Enable-ComputerRestore` at first logon.
- Re-check bloatware identifiers against the exact target build (`Get-AppxProvisionedPackage -Online` on a clean install).
- Run the Phase 2 update-engine VM checks (`testing.md` C), including the offline and reboot-limit runs.
- Run the Phase 3 application VM checks (`phase-3/testing.md`): WinGet at first sign-in, lock
  hand-over between both engines, restarts, offline and App Installer repair.

- Run the Phase 4 USB deployment checks (`phase-4-usb-deployment/testing.md`) in a VM, then on
  physical hardware (Media Creation Tool and Rufus media).
- Run the Phase 4.2 application checks (`phase-4-2-application-profiles/testing.md`): Core
  Essentials, Store and portable packages, antivirus listings, the Network Engineer profile.
- Consider a reviewed, hash-pinned vendor installer for RustDesk (currently a manual follow-up).
- Run the Phase 4.3 checks: `AUOptions=3` applied after the initial updates on Windows 11 Pro (and
  reported Unsupported on Home), Wi-Fi with a real adapter, a VM without Wi-Fi, and the predefined
  region skipping Setup's region pages.
- Run the Phase 5 bare-metal checklist (`phase-5-resilient-provisioning/bare-metal-checklist.md`):
  restarts resume, a network interruption pauses instead of failing, a failed application can be
  retried, the report and the diagnostics ZIP are accurate and contain no secrets.

## Next: manufacturer drivers

Implement the hand-off in `src/engine/drivers/contract.ts` as the `drivers` stage the Phase 4
orchestrator already reports (`NotImplemented`): inventory, vendor-recommended candidates by
hardware ID (AMD, NVIDIA, Intel, OEM utilities, mixed hardware), verified installation, restart
under `install.lock`, and device validation. Never replace a driver only because a newer package
exists.

## Then

- PXE / netboot.xyz / WinPE share / deployment server delivery of the same answer file and
  `WindowsDeployment` folder.
- Optional offline App Installer packages in the package.
- PowerShell 7: replace the `deferred.installPowerShell7` switch with the catalog entry `Microsoft.PowerShell`.

## Later

- Opt-in, notify-only update/dependency checks. They must never change generation or owner defaults.
- Deferred personalization: wallpaper, lock screen, colors, lock keys, custom visual-effects matrix.
- Custom taskbar layout XML and Windows 10 Start tiles. Script-based or interactive computer name.
- Optional features only where needed (Hyper-V, Virtual Machine Platform, WSL2, Windows Sandbox), never installed silently on every machine.

## Explicitly out of scope

ISO or boot-media editing, unattended disk selection/partitioning/wiping, and disabling Windows Update entirely.
