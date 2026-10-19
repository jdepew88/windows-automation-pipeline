# Roadmap

## Milestone 1 (this repository)

Done in code and covered by automated tests. **Not validated with WSIM or a VM**; see `testing.md`.

## Phase 2: Windows Update automation (branch `feature/phase-2-windows-updates`)

Implemented and covered by automated tests, plus one read-only scan on real Windows. **Not
validated in a VM**; see `testing.md` C. Review: `phase-2/review.md`. Report:
`phase-2/implementation-report.md`.

## Milestone 2: validation and hardening

- Run WSIM validation and both VM runs (with and without Internet). Fix any findings and record a `docs/validation-log.md`.
- Confirm or replace the unverified mechanisms: persistent auto-logon, shortcut-arrow overlay, `Enable-ComputerRestore` at first logon.
- Re-check bloatware identifiers against the exact target build (`Get-AppxProvisionedPackage -Online` on a clean install).
- Run the Phase 2 update-engine VM checks (`testing.md` C), including the offline and reboot-limit runs.

## Milestone 3: deployment bundle

- `Windows-Deployment.zip` containing `autounattend.xml`, a WinGet-native JSON (`winget export`/`import` schema), scripts, `setup.ps1`, ancillary config and a README.
- Durable first-logon orchestration: staged on the Windows volume before first logon, idempotent (state file), connectivity-aware queue with retry and logging. No empty bundle that only pretends to run.
- WinGet package selection: empty by default, chosen individually, with a dry-run view. Lists from imports stay in the session only.
- PowerShell 7 installation through that pipeline (`deferred.installPowerShell7`).
- The orchestrator starts application installation only after the Phase 2 marker
  `C:\ProgramData\WindowsDeploymentBuilder\state\windows-update.done` exists (or reads `result.json`).

## Later

- Opt-in, notify-only update/dependency checks. They must never change generation or owner defaults.
- Deferred personalization: wallpaper, lock screen, colors, lock keys, custom visual-effects matrix.
- Custom taskbar layout XML and Windows 10 Start tiles. Script-based or interactive computer name.
- Optional features only where needed (Hyper-V, Virtual Machine Platform, WSL2, Windows Sandbox), never installed silently on every machine.

## Explicitly out of scope

ISO or boot-media editing, unattended disk selection/partitioning/wiping, and disabling Windows Update entirely.
