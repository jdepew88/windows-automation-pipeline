# Phase 5 audit: what already existed, what was incomplete, what changed

Baseline: `feature/phase-4-3-quick-deployment-wizard` at `e9e9e3c81eb64ad305d8888e51c73a492e14276f`
(working tree clean). Branch `feature/phase-5-resilient-provisioning` was created from it; no other
branch was modified.

## Reused as is (no rebuild)

| Mechanism | Where | Why it already satisfies Phase 5 |
|---|---|---|
| Machine-wide state below `C:\ProgramData\WindowsDeploymentBuilder` | all engines | Not in a user profile; ACL: SYSTEM and Administrators full control, Users read (`icacls` by SID in the installers, `Set-WddAcl`). |
| Attempt counted *before* an installation starts | app engine, update engine | A crash, power loss or hang mid-install still counts, so nothing loops. |
| Interrupted installation is reconciled, not assumed | app engine `Resume-WdaEntries` | `Installing` → `Pending` (interrupted) → `winget list` decides: installed = `Succeeded`, not installed = retry. |
| Idempotency check before every attempt | app engine | `winget list --id --exact --source` first; installed packages are never installed again (`AlreadyInstalled`). |
| Machine-wide install lock | `install.lock` (shared region of both engines) | An exclusively opened file: Windows releases it when the owner process ends, so it can never go stale; a live lock is respected. |
| Restart coordination | `restart-pending.json` | Valid only in the boot it was written in and for 30 minutes. |
| Single instance | named mutexes (engines, orchestrator) | `AbandonedMutexException` (owner died) is taken over; a live owner makes the second run exit. |
| Bounded restarts and runtime | `maxReboots`, `maxRuntimeHours`, deployment deadline | No reboot loop; unchanged. |
| SYSTEM monitor task | `\WindowsDeploymentBuilder\Deployment` | At startup (3 min delay) and every 15 min; idempotent; integrity check of the staged package on every run. |
| Staging from the answer file | `Stage-Deployment.ps1` | After staging, nothing needs the USB drive or a network share. |
| Windows Update engine | `WindowsUpdateEngine.ps1` 1.0.0 | Per-update attempts, scan retry, one component reset, offline handling, restart limits; installed updates are never offered again, so a re-run is safe. **Left unchanged** (authoritative, as required). |
| Phase 4.3 ongoing update policy | `Set-UpdatePolicy.ps1` | Applied once, only when the update stage is final (or at the deadline); stored in the deployment state, so it is not re-applied after a retry. Unchanged. |

## Incomplete before Phase 5

1. **Retry classification** was a single boolean; a failure was either retried at once or not,
   and the result did not say whether it was transient or permanent. Unknown codes were retried
   without being recorded as unknown.
2. **No backoff**: retries followed after a fixed 30 s, so a few minutes of outage used up the
   whole attempt budget.
3. **Network loss during the queue** consumed attempts and ended packages as `Failed`; there was no
   distinction between "the computer is offline" and "this package source is down".
4. **State writes** were `WriteAllText` + `Move-Item -Force` (delete, then move): not atomic, no
   last-good copy. A damaged application state made the engine start over; a damaged
   deployment state was read as "no deployment" (the monitor stopped silently, setup could start a
   second deployment on top).
5. **Manual retry** existed only as `Resume-Deployment.ps1 -RestartStage applications`, which
   re-runs the engine installer: it archives the state and starts a new run (correct thanks to
   `winget list`, but per-package history is lost and every package is checked again). No way to
   retry one application, no permitted-operation check, no diagnostics export.
6. **Outcome**: `Succeeded / CompletedWithFollowUp / CompletedWithFailures / Incomplete / Failed`
   existed, but "paused for network / reboot / user" and "failed to initialize" were not
   machine-readable; no exit-code contract.
7. **Runtime limit** inside the queue ended the whole stage `Failed`, even after most packages had
   installed.
8. **Bug found during the audit tests**: the engines write `requestedUtc` into
   `restart-pending.json`, the orchestrator read `writtenUtc`, so a restart scheduled by an engine
   was never shown as pending (Phase 4 mismatch). Fixed.
9. The wizard did not prefill the username (`personName` was empty).

## Changed in Phase 5 (and why)

| Change | Files |
|---|---|
| Failure classes, bounded exponential backoff with jitter, network/source diagnosis and deferral, lifecycle derivation, attempt history (`attempts.jsonl`), atomic state with `.bak` and validated, versioned state (v1 → v2), runtime-budget outcome, verification after a reported success, Retry mode | `ApplicationEngine.ps1` 1.2.0 |
| `-Resume` (keeps state; verifies the copies) | `Install-ApplicationEngine.ps1` |
| Atomic deployment state with `.bak`, damaged-state detection, outcome model and exit codes, idle user-stage detection, restart-marker fix | `DeploymentCommon.ps1` (orchestrator 1.1.0), `DeploymentOrchestrator.ps1`, `Initialize-Deployment.ps1`, `Resume-Deployment.ps1`, `Show-DeploymentStatus.ps1` |
| Outstanding work, recovery commands and per-operation attempts in the report (report v2) | `Complete-Deployment.ps1` |
| Technician recovery tool | `DeploymentRecovery.ps1` (new; `scripts/recovery/` in the package) |
| Settings, defaults, config generation, manifest `recovery` block, result schema 2, README texts, Final Review line | `schema/applications.ts`, `profiles/owner-default.json`, `features/applications`, `ui/layout.ts`, `engine/applications`, `engine/deployment`, `engine/quick.ts`, `ui/wizard.ts` |

Not changed: the Windows Update engine and its installer, the Wi-Fi script, the policy script, the
staging script, every other feature module. With both engines off the answer file is
byte-identical to Phase 4.3.
