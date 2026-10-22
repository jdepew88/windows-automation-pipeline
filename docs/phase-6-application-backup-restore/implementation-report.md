# Phase 6 implementation report: application inventory, backup and restore

Branch `feature/phase-6-application-backup-restore`, from Phase 5 `01f3a9f`. Not merged, not
deployed. No Windows installation, VM or bare-metal run was done (deferred by the owner until
Phases 6 to 9 are complete).

Documents: [audit](audit.md), [architecture](architecture.md) (sequencing, profile and recovery
integration), [inventory and matching](inventory-and-matching.md), [collector](collector.md),
[backup format](backup-format.md), [adapters](adapters.md), [security](security.md),
[testing](testing.md), [bare-metal checklist](bare-metal-checklist.md).

## Acceptance audit

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 1 | Local read-only Windows inventory tool | Done | `WdbMigration.ps1 -Mode Inventory`; writes only its output file; Migration suite |
| 2 | Applications from multiple sources | Done | WinGet (Client or export), uninstall records (64/32-bit, HKLM/HKCU), Store/MSIX, opt-in portable folders, development tools |
| 3 | No silent substitution of guessed software | Done | exact / strong / possible / none; possible needs confirmation; unknown never installable; `applyMigration` refuses invalid decisions; mutation check |
| 4 | Safe export and import | Done | versioned strict schema, limits, hostile-input tests, reviewed-inventory export, distinct from `winget export` |
| 5 | UI to approve restoration selections | Done | Advanced › Application Backup & Restore review; entry link from the catalog; browser tests |
| 6 | Named profiles from inventories | Done | `applyMigration` → custom profile on a base (default Network Engineer), base unchanged, exclusions preserved |
| 7 | Secure, versioned backup format | Done | `app-backup` v1, manifest of SHA-256s, pinned manifest hash, validation, safe ZIP |
| 8 | Supported settings backed up through validated adapters | Done (simulated) | 10 adapters; filters and secret scan; Migration suite |
| 9 | Settings restored after installation | Done (simulated) | engine 1.3.0 settings operations after the queue, waiting for their applications and restarts |
| 10 | Unsupported restoration clearly labelled | Done | unsupported list in previews, manifest, website; Unsupported/ManualActionRequired outcomes |
| 11 | Phase 5 resume/retry integration | Done | `settings:<adapter>` operations, state v3, interruption, RetryFailed/Retry, `RestoreSettings` |
| 12 | USB package generation still works | Done | regression comparison; default ZIP unchanged; engines-off answer file byte-identical |
| 13 | No secrets silently copied | Done | secret scan with explicit `-IncludeFlagged`; password values refused at backup and restore; no credential stores |
| 14 | Compatibility checks prevent inappropriate restoration | Done | hardware-specific apps excluded (Phase 8), Windows components excluded, Arm64 notes, app presence/running checks, adapter versions, unknown adapters skipped |
| 15 | All automated tests pass | Done | see [testing.md](testing.md) |
| 16 | Documentation of what can and cannot be restored | Done | this folder; README and roadmap |

## What was built

- **Collector / library** `src/engine/migration/scripts/WdbMigration.ps1` (PowerShell 5.1, StrictMode 2.0): Inventory, PreviewBackup, Backup, Validate, PreviewRestore, Restore, Library.
- **Website**: inventory import, catalog matching (7 classifications, 5 confidence levels), review with decisions and confirmation, profile creation, backup manifest attachment with pinned hash, adapter choice with conflict policies, follow-ups, reviewed-inventory export; validation messages.
- **Profile**: new `migration` section (no schema version bump; older profiles get it filled from owner defaults, off).
- **Engine 1.3.0**: state version 3 (`settings` map, staged-backup record), backup staging by name + hash, settings operations with dependency, restart, user and backup waits, bounded retry, interruption handling, `result.json` › `settings`/`settingsBackup`, `restoration.json`, migration follow-ups.
- **Installer**: copies and hash-checks `WdbMigration.ps1` when present.
- **Recovery tool**: `-Action RestoreSettings -BackupPath …` (menu 7); settings in Status/PendingActions/Retry.
- **Report**: "Application restoration" section, `restoration` block, `restoreSettings` command.
- **Package**: `WdbMigration.ps1` embedded and `restore-plan.txt` when a plan exists; manifest `migration` block; README/INSTALLATION say where the backup goes.

## Inventory sources

WinGet (`Get-WinGetPackage` from Microsoft.WinGet.Client, else `winget export --include-versions`),
uninstall records (HKLM 64-bit, HKLM 32-bit, HKCU), AppX/MSIX (`Get-AppxPackage`), portable
programs (opt-in folders), development environment (Git, VS Code/Cursor extensions, PowerShell
modules, Python PEP 514 and pyenv-win, Node.js with nvm-windows/fnm/volta, Docker presence, Claude
Code method, opt-in repositories).

## Settings adapters (10)

vscode, cursor, windows-terminal, git, openssh-client, putty, winscp, notepadpp, powershell-profile
(review only), winget-settings. Unsupported by design: Docker Desktop, browsers, WireGuard,
Tailscale, FileZilla, game launchers, Office/Teams/Slack/Zoom.

## Known limitations

- Every restore and every collector source was exercised against simulations only; real formats on
  current application versions are unverified (see the checklist).
- Without Microsoft.WinGet.Client the inventory has WinGet ids without names, so WinGet packages
  and uninstall records of the same application can appear separately until the website merges
  them through a catalog match.
- Store packages that WinGet does not report with a product id cannot be reinstalled automatically
  (no verified family-name-to-product mapping exists; none was invented).
- Name matching depends on the catalog's names and the publishers recorded at verification; apps
  outside the catalog without a WinGet id are always manual.
- Secret detection is pattern based; settings can still hold personal data.
- VS Code extensions need the Internet and are installed with the latest version; Cursor
  extensions, PowerShell modules, version-managed runtimes, virtual environments and repositories
  are manual follow-ups.
- Settings Sync (VS Code/Cursor) may overwrite restored settings after sign-in.
- WinSCP INI storage, portable Notepad++ and Git XDG config (`~/.config/git/config`) are not covered.
- The backup is found by name on ready drives or supplied with the recovery tool; it is not carried
  in the answer file or the ZIP (by design).
- Restore runs as the deployment user; settings of other accounts are not handled.
- The staged backup stays under the data root (restricted ACL) for later retries; it is not deleted
  automatically.

## Remaining for Phase 7 and the combined bare-metal test

- Phase 7 (USB media preparation assistant) should place the backup folder at
  `WindowsDeployment\backups\<folder>` when preparing the drive and verify its manifest hash.
- Phase 8 takes over the hardware-specific applications the review excluded.
- Phase 9 reads `restoration.json` (schema `RestorationResultSchema`) and the report's
  `restoration` block.
- Combined test: [bare-metal-checklist.md](bare-metal-checklist.md).
