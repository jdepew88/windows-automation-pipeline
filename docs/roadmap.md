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

## Milestone 2: validation and hardening

- Run WSIM validation and both VM runs (with and without Internet). Fix any findings and record a `docs/validation-log.md`.
- Confirm or replace the unverified mechanisms: persistent auto-logon, shortcut-arrow overlay, `Enable-ComputerRestore` at first logon.
- Re-check bloatware identifiers against the exact target build (`Get-AppxProvisionedPackage -Online` on a clean install).
- Run the Phase 2 update-engine VM checks (`testing.md` C), including the offline and reboot-limit runs.
- Run the Phase 3 application VM checks (`phase-3/testing.md`): WinGet at first sign-in, lock
  hand-over between both engines, restarts, offline and App Installer repair.

## Phase 4: manufacturer drivers

Implement the hand-off in `src/engine/drivers/contract.ts` (stage 3 in `orchestration.json`):
inventory, vendor-recommended candidates by hardware ID, verified installation, restart, and device
validation. Never replace a driver only because a newer package exists.

## Milestone 3: deployment bundle

- `Windows-Deployment.zip` containing `autounattend.xml`, a WinGet-native JSON (`winget export`/`import` schema), scripts, `setup.ps1`, ancillary config and a README.
- Durable first-logon orchestration: staged on the Windows volume before first logon, idempotent (state file), connectivity-aware queue with retry and logging. No empty bundle that only pretends to run.
- Bundle the grouped deployment assets (Windows Update, applications, `orchestration.json`) and
  optional offline App Installer packages. Read `orchestration.json` for stages, markers and
  results. (WinGet selection, the dry-run plan and Windows Update coordination are done in Phase 3.)
- PowerShell 7: replace the `deferred.installPowerShell7` switch with the catalog entry `Microsoft.PowerShell`.

## Later

- Opt-in, notify-only update/dependency checks. They must never change generation or owner defaults.
- Deferred personalization: wallpaper, lock screen, colors, lock keys, custom visual-effects matrix.
- Custom taskbar layout XML and Windows 10 Start tiles. Script-based or interactive computer name.
- Optional features only where needed (Hyper-V, Virtual Machine Platform, WSL2, Windows Sandbox), never installed silently on every machine.

## Explicitly out of scope

ISO or boot-media editing, unattended disk selection/partitioning/wiping, and disabling Windows Update entirely.
