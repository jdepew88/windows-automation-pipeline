# Phase 6 testing

## Strategy

Nothing touches the development computer: no inventory of it is taken, no real user folder or
registry key is read or written, nothing is installed or removed, no network is used. Every system
access of `WdbMigration.ps1` is an adapter function (WinGet, uninstall records, Store packages,
OS information, user folders, registry, processes, the VS Code command line) that the scenario
suites replace with a simulated computer whose user folders are temporary directories filled with
synthetic files. The engine and deployment suites additionally simulate WinGet, tasks, drives and
restarts as in Phase 5.

| Level | Suite | What runs for real |
|---|---|---|
| Collector and restore library | `tests/powershell/Migration.Tests.ps1` | the real script: inventory normalisation, backup, validation, ZIP extraction, restore |
| Engine | `tests/powershell/Applications.Tests.ps1` (Phase 6 section) | the real engine 1.3.0 with the real restore library |
| Full lifecycle | `tests/powershell/Deployment.Tests.ps1` (Phase 6 section) | a second **real generated package** (`writeMigrationFixture`): its answer-file extraction, staging, engine, restore library, monitor, report and recovery tool; the backup on the simulated USB drive was written in TypeScript, so the PowerShell validator checks a manifest produced by the website's side |
| TypeScript | `tests/unit/migration.test.ts` | import, matching, profiles, backup manifests, generation, validation, static script checks |
| Cross-language | `tests/unit/powershell.test.ts` | the collector's real inventory and manifest (from the synthetic computer) are imported by the website; adapter lists compared; `restoration.json` and `result.json` checked against their schemas |
| Browser | `tests/e2e/migration.spec.ts` | the Application Backup & Restore section at desktop, tablet and mobile sizes |

## Results (2026-10-22, this branch)

| Check | Result |
|---|---|
| `npm run typecheck`, `npm run lint`, `npm run build` | clean (bundle-size advisory as before) |
| Vitest | **429 passed in 19 files** (Phase 5: 395 in 18): 32 in `migration.test.ts`, 2 new in `powershell.test.ts` |
| Windows Update engine (`Engine.Tests.ps1`) | 25/25 (unchanged) |
| Application engine (`Applications.Tests.ps1`) | **89/89** (82 + 7 Phase 6) |
| Collector, backup, restore (`Migration.Tests.ps1`) | **24/24** (new) |
| Deployment and full lifecycle (`Deployment.Tests.ps1`) | **46/46** (43 + 3 Phase 6) |
| Wi-Fi (`Wifi.Tests.ps1`) | 10/10 (unchanged) |
| Playwright (desktop 1280x720, tablet 820x1180, Pixel 7) | **136 passed, 2 skipped** (Phase 5: 124 + 2): 4 new tests x 3 sizes; the 2 skipped are the mobile-only drawer test on desktop and tablet, as before |
| Mutation checks | 8 deliberate defects, each detected (below) |
| Regression against Phase 5 (`01f3a9f`), six profiles compared file by file | both engines off: answer file **byte-identical**; otherwise only `ApplicationEngine.ps1`, `Install-ApplicationEngine.ps1`, `DeploymentRecovery.ps1`, `Complete-Deployment.ps1`, the engine version in `applications-config.json` and `README-Applications.txt`, the results schema, the manifest hashes/package id, and the new `migration` section (off) in `profiles/windows-settings.json` differ |
| ZIP (default configuration) | unchanged: 30 entries, 28 manifest files, 18 embedded. With a restoration plan: + `WdbMigration.ps1` (embedded) + `restore-plan.txt`; never any backup data |

## Coverage (requested areas)

| Area | Where |
|---|---|
| WinGet inventory parsing (Client and `winget export`) | Migration: merged inventory; export fallback; no WinGet |
| Registry inventory (64/32-bit, HKLM/HKCU, updates, system components, child entries, no name) | Migration: merged inventory |
| AppX/MSIX (frameworks, inbox, Store, sideloaded) | Migration: merged inventory; unit: Store packages without a product id |
| Deduplication | Migration (ARP, MSIX, name+version, Store name); unit: records of the same package merged |
| Ambiguous matching, unknown packages, source matching | unit: exact / strong / possible / unknown, add-in not strong, other sources, invalid ids, confirmation required |
| Portable classification | Migration: only named folders, credible metadata; unit: catalog portable entry |
| Per-user vs machine | Migration (scope, architecture); unit (shown) |
| Safe settings collection, secret exclusion | Migration: token in keybindings left out (rule + line, never the value), ssh keys never, state.vscdb never, gitconfig filter, Notepad++ history removed, DTD refused, registry passwords dropped; secret rules positive/negative |
| Backup manifest generation, hash validation | Migration: package, hashes, no user name; modified/missing/extra files; pinned hash |
| Archive extraction, path traversal | Migration: traversal, absolute, drive, alternate stream, unexpected entry, bomb; crafted manifests; links refused; unit: manifest traversal and foreign items |
| Adapter compatibility | Migration: unknown adapter skipped; future format refused; app missing / running / not registered |
| Restore conflicts | Migration: keep, replace (original kept once), skip, preview writes nothing, partial |
| Interrupted restore | Applications: power loss during a restore, nothing rewritten |
| Phase 5 recovery integration | Applications: blocked by a failed app then RetryFailed; missing backup then Retry; Deployment: RestoreSettings refuses a tampered backup, restores only outstanding settings, never repeats |
| Invalid profile/inventory imports | unit: non-JSON, WinGet list, manifest, version, unknown members, control characters, traversal, credentials, duplicates, size; browser: hostile inventory rejected |
| Legacy profile compatibility | unit: Milestone 1, Phase 4, 4.3 and a real Phase 5 export import with migration off and no Phase 6 blocks |
| Accurate manual-action reporting | Applications/Deployment: `restoration.json` outcomes per app and adapter; outstanding list exact; report section |
| PowerShell 5.1 StrictMode | every suite runs under Windows PowerShell 5.1; the collector, engine and tests set `Set-StrictMode -Version 2.0` |
| Browser: import, review, save profile, errors | `migration.spec.ts` |

## Mutation checks (each applied once, run, reverted)

| Defect | Caught by |
|---|---|
| pinned manifest hash not enforced | Migration: validate … pinned manifest hash |
| password values written on restore | Migration: crafted backup cannot write password values |
| possible secrets included in a backup | Migration: backup preview |
| unsafe archive entry names accepted | Migration: archive |
| identical settings written again | Migration: never written twice |
| PowerShell profiles restored to the live location | Migration: scripts only go to a review folder |
| settings restored although their application failed | Applications: blocked, then RetryFailed |
| a name-only match treated as strong | unit: strong vs possible; confirmation |

## Changed existing tests

Only where Phase 6 deliberately changed behaviour: the engine version (`1.2.0` → `1.3.0`) in
`recovery.test.ts`, `Deployment.Tests.ps1` and `app.spec.ts`; the state version (2 → 3, with an empty
`settings` map) in the version-1 upgrade scenario; the list of saved results in `powershell.test.ts`
(+ `phase6-restored.json`, plus the separately validated `restoration-phase6.json`); three answer-file
snapshots after the file-by-file comparison above. No assertion was weakened.

## Not tested: needs real hardware (status: UNVERIFIED)

Real application settings formats on current versions (VS Code, Cursor, Windows Terminal, Notepad++,
PuTTY, WinSCP), `Get-WinGetPackage`/`winget export`, `Get-AppxPackage` and the uninstall records on a
real workstation, `code --install-extension` from the elevated task, drive enumeration for the
backup, the staged-backup ACL, OneDrive-redirected Documents. See
[bare-metal-checklist.md](bare-metal-checklist.md).
