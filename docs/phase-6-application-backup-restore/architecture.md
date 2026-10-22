# Phase 6 architecture: application inventory, backup and restore

## Three separate operations

| Operation | Where | Changes anything? | Output |
|---|---|---|---|
| **Inventory** | `WdbMigration.ps1 -Mode Inventory` on the existing computer | No. Reads WinGet, uninstall records, Store packages, named folders, a few config files' existence. | `inventory.json` |
| **Backup** | `WdbMigration.ps1 -Mode PreviewBackup`, then `-Mode Backup -Adapter … -Destination …` | Writes only the new backup folder you named. | `WDB-AppBackup-<date>-<id>\` (+ optional `.zip`) |
| **Restore** | The deployment's application engine (after installation), the recovery tool, or `-Mode Restore` by hand | Writes the adapters' settings into the current user's profile, after validation. | `result.json` › `settings`, `restoration.json` |

An exported application list is never called a backup: a backup is the settings folder with its
manifest of hashes.

```
existing computer                      website (browser, local)                  new computer
-----------------                      ------------------------                  ------------
WdbMigration.ps1 -Mode Inventory  -->  import inventory.json
                                       match against the catalog
                                       review: restore / manual / optional / exclude
                                       create "Personal Workstation" profile
WdbMigration.ps1 -Mode Backup     -->  attach backup-manifest.json (hash pinned)
  (folder stays on your drive)         generate the deployment package
                 \                                   |
                  \__ copy to USB: WindowsDeployment\backups\<folder>        USB + ZIP
                                                                              |
                                              Windows Setup -> first sign-in -> staging
                                              Windows Update stage
                                              application engine 1.3.0:
                                                1. stage backup (found by name, accepted by hash)
                                                2. install apps (Phase 5 queue, retry, restarts)
                                                3. restore settings per adapter, after its app
                                                4. result.json + restoration.json
                                              monitor -> deployment report (Application restoration)
```

## Components

| File | Role |
|---|---|
| `src/engine/migration/scripts/WdbMigration.ps1` | Collector, backup, validation, restore library (modes Inventory, PreviewBackup, Backup, Validate, PreviewRestore, Restore, Library). Every system access is an adapter function the tests replace. |
| `src/engine/migration/inventory.ts` | Strict inventory schema and import (`importInventory`). |
| `src/engine/migration/matching.ts` | Catalog matching, classification, confidence, recommendations, de-duplication. |
| `src/engine/migration/backup.ts` | Backup manifest schema and import (`importBackupManifest`), pins the SHA-256. |
| `src/engine/migration/adapters.ts` | The adapter list as the website shows it (mirrors `$script:WdbAdapters`; a test compares both). |
| `src/engine/migration/plan.ts` | Review → profile (`applyMigration`), backup reference (`attachBackup`), config blocks, `restore-plan.txt`. |
| `src/engine/schema/migration.ts` | The `migration` section of the deployment profile. |
| `src/features/migration`, `src/ui/migration.ts` | The **Application Backup & Restore** section (Advanced Configuration) and its validation. |
| `ApplicationEngine.ps1` 1.3.0 | Settings operations, backup staging, `restoration.json`. |
| `DeploymentRecovery.ps1` | `-Action RestoreSettings -BackupPath …`, settings operations in Status/PendingActions/Retry. |
| `Complete-Deployment.ps1` | Report section "Application restoration" and the `restoration` block. |

## Restore sequencing

1. **Load** the plan: `applications-config.json` › `settingsRestore` (backup id, manifest SHA-256,
   folder name, adapters with conflict policy and the package keys they wait for) and `migration`
   (the reviewed applications, follow-ups). Both are part of the verified, hashed package.
2. **Validate the backup**: at the first start (USB most likely attached) and again before
   restoring, the engine looks for `<dataRoot>\Backup\incoming\<folder>` and
   `<drive>:\WindowsDeployment\backups\<folder>` / `<drive>:\<folder>` on ready drives. A candidate
   is accepted only if its manifest has the pinned SHA-256 and every file matches its hash, size and
   path rules (`Test-WdbBackup`). It is copied (listed files only) to `<dataRoot>\Backup\<backupId>`,
   validated again and restricted to SYSTEM, Administrators and the user.
3. **Resolve selections**: the reviewed applications are an ordinary custom profile, so the
   selection (with exclusions, devices, dependencies) is resolved as for any deployment.
4. **Reconcile**: every package is checked with `winget list` first (already installed = left alone).
5. **Install** missing applications through the existing queue (Phase 5 retry and recovery).
6. **Dependencies**: catalog `requires` are installed first, as before.
7. **Restarts**: an application that needs a restart is restarted and verified; its settings wait
   (they run only when the application is `Succeeded`/`AlreadyInstalled`).
8. **Restore settings** per adapter, in plan order, with its conflict policy.
9. **Verify**: every written file is hashed again; every registry value is read back.
10. **Report**: `result.json` › `settings`, `restoration.json`, `follow-up.txt`, the deployment report.

Settings of an application that failed, was skipped or needs manual installation are
`BlockedByDependency` (retryable). A missing or invalid backup makes the settings
`WaitingForBackup` with instructions; never a guess, never a partial import of an unverified backup.

## Conflict policies

| Policy | Existing target | Missing target |
|---|---|---|
| `keepExisting` (default) | kept (`KeptExisting`) | written |
| `restoreBackup` | replaced; the original is kept once as `<file>.wdb-before-restore` (registry: `before-restore\<adapter>.json`) | written |
| `skip` | untouched (`SkippedByUser`) | untouched |

A target already identical to the backup is never written again (`identical`). Restore previews
(`-Mode PreviewRestore`, `-WhatIf`) report the same actions without writing.

## Profile integration

`applyMigration` creates a **new custom profile** (default name "Personal Workstation"; any name,
for example Gaming Desktop, Customer Office PC, Network Engineering Laptop) that:

- inherits the chosen base profile (default **Network Engineer / Developer / Technician**), which is
  never modified;
- adds the applications set to "restore" that the base does not already provide (catalog entries,
  verified WinGet/Store ids, catalog manual entries);
- lists "optional" ones as unticked recommendations;
- records base applications the review excluded in `excluded` (the base profile's own exclusions
  stay in force through inheritance);
- is ticked, and the base is unticked (it is included through inheritance).

Unknown applications set to "manual" become Additional Software manual entries
(`migration-<inventoryId>`). The profile is stored like any custom profile (browser library,
export/import). Verified custom WinGet ids stay in the personal profile and are never added to the
curated catalog.

## Recovery integration (Phase 5)

| Phase 5 concept | Settings restore |
|---|---|
| Operation id | `settings:<adapter>` (`settings:vscode`) |
| State | `state.json` › `settings` (state version 3; versions 1 and 2 upgrade without changing any status) |
| Lifecycle | derived from the same statuses: Succeeded, AlreadySatisfied (kept), ManualActionRequired, BlockedByDependency, FailedRetryable, FailedPermanent (integrity) |
| Attempts | `history` and `attempts.jsonl`, counted per operation |
| Automatic retry | "close the application" / "not registered yet" and transient I/O failures are retried with the Phase 5 backoff up to the attempt limit, then reported (never indefinitely) |
| Interrupted | `Installing` after a crash goes back to Pending (recorded as Interrupted); items already restored are only verified |
| Manual retry | `Invoke-WdaRetry` accepts `settings:` ids; `-AllFailed` includes blocked, waiting and failed settings; restored ones are refused ("already restored"); integrity failures need `-IncludePermanent` |
| Recovery tool | `RestoreSettings -BackupPath <folder or zip>` validates against the pinned hash, places the backup in `Backup\incoming`, reopens only outstanding settings and restarts the application task without archiving its state |

Application installation retry and settings restore retry are separate operations: retrying
`settings:vscode` never reinstalls VS Code, and `RetryFailed` reopens a failed application together
with its blocked settings.

## Outputs for Phase 9

`<dataRoot>\Applications\restoration.json` (`windows-deployment-builder/restoration-result`, version
1; schema `RestorationResultSchema` in `results.ts`): one outcome per reviewed application and per
settings adapter from a fixed vocabulary (InstalledSuccessfully, AlreadyInstalled,
ConfigurationRestored, ConfigurationPartiallyRestored, KeptExisting, ManualActionRequired,
WaitingForUser, WaitingForBackup, BlockedByDependency, Unsupported, Failed, SkippedByUser, Pending),
the backup status, follow-ups and counts. The deployment report repeats the summary.

## Compatibility

- Profiles from Milestone 1 to Phase 5 import with `migration` filled from owner defaults (off); they
  generate the same configuration (no `settingsRestore`/`migration` blocks, no restore library).
- Engine 1.3.0 runs configurations from engines 1.0 to 1.2 unchanged (no plan, no settings
  operations; result without `settings`).
- With both engines off the answer file is byte-identical to Phase 5.
- Source vs target: the inventory records the source build and architecture; Arm64 targets get a
  note for apps without an Arm64 build; scope and architecture are shown; hardware-specific
  utilities and drivers are excluded and left to Phase 8; Store packages without a product id are
  manual.
