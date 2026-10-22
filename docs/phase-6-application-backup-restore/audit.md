# Phase 6 audit: what existed before application backup and restore

## Git verification (2026-10-22, before any change)

| Check | Result |
|---|---|
| `git status` | clean, on `feature/phase-5-resilient-provisioning` |
| `git fetch origin` | done |
| local `feature/phase-5-resilient-provisioning` | `01f3a9f8bdbbe78a6b638e0838c68c6e45b577c8` |
| `origin/feature/phase-5-resilient-provisioning` | `01f3a9f8bdbbe78a6b638e0838c68c6e45b577c8` (also `git ls-remote`: present on GitHub) |
| `main` / `origin/main` | `0318bf7`, unchanged |
| Uncommitted work | none |

`feature/phase-6-application-backup-restore` was created from `01f3a9f`. The Phase 5 branch was
not changed.

## What already existed and was reused

| Need | Existing mechanism (reused, not rebuilt) |
|---|---|
| Installing applications | The application engine (`ApplicationEngine.ps1`) with its queue, `winget list` check before every install, dependency order, restarts, install lock. Restoration reinstalls apps **only** through the normal selection → engine path. |
| Retry, resume, recovery | Phase 5: operation ids, lifecycle, failure classes, bounded backoff, atomic state with `.bak`, `attempts.jsonl`, `Invoke-WdaRetry`, the recovery tool. Settings restore operations are a third operation kind (`settings:<adapter>`) in the same state and use the same retry and recovery. |
| Package identity | `PackageRef`, `packageKey`, the strict WinGet/Store id patterns (`ids.ts`), `unresolvedReason`. Inventory identifiers pass the same checks. |
| Catalog | The 115-entry catalog (`catalog.json`), `entryKey`, `catalogRef`, `methodOf`, the excluded-apps list, the verification method strings (they contain the name and publisher WinGet reported; matching uses them). |
| Named profiles | Custom application profiles (`createProfile`, inheritance, `optional`, `excluded`), the browser profile library, profile export/import. A migration result *is* a custom profile. |
| Manual installs | Additional Software entries with `execution: manual` (engine reports them as manual follow-ups). Unknown applications marked "manual" become such entries. |
| WinGet import | `importWinGetJson` (native `winget export` files) stays as it was; the inventory is a separate format, and the importer tells the two apart. |
| Deployment package | Manifest with hashes, embedded files, staging, `Install-ApplicationEngine.ps1` copy-and-verify. The restore library is one more engine file. |
| Reporting | `result.json`, `follow-up.txt`, the deployment report v2, `outstanding`. Phase 6 adds `restoration.json` and a report section. |
| UI | Advanced Configuration sections, custom editors, `customShell`, field groups, app logos (`appLogo` with fallback), notices. |

## What was missing

- No way to learn what is installed on an existing computer (no collector, no inventory format).
- The only import was a native WinGet list: no names, publishers, uninstall records, Store packages, portable apps, confidence or unresolved items.
- No settings backup or restore of any kind; no adapter model; no backup format or validation.
- No per-application restoration result for a later health check.

## Decisions

- **Collector**: one Windows PowerShell 5.1 script (`WdbMigration.ps1`), StrictMode 2.0, explicit modes. No service, no localhost connection to the browser. The website only imports files.
- **Backups stay off the website**: the website reads only `backup-manifest.json` and pins its SHA-256. The backup folder goes to the USB drive (or is supplied with the recovery tool); the deployment accepts only the backup with that manifest hash. Nothing is uploaded and nothing personal is embedded in the answer file.
- **No second engine**: settings restore runs inside the application engine after the queue, as tracked operations. The engine loads `WdbMigration.ps1 -Mode Library`, the same code the collector uses for `-Mode Restore`.
- **No catalog growth**: verified WinGet identifiers from an inventory go into the personal profile only.
