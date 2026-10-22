# Phase 5 implementation report: resilient provisioning, resume and retry

Branch `feature/phase-5-resilient-provisioning`, created from Phase 4.3
(`e9e9e3c81eb64ad305d8888e51c73a492e14276f`, working tree clean). Not merged into `main`; not
deployed to Cloudflare. No Phase 6 work. Nothing was installed or removed on the development
computer, no task was registered, no partition or USB drive was touched and Windows Setup was not
run. **Nothing has been validated on bare metal or in a VM yet.**

The audit is in [audit.md](audit.md); the design in [architecture.md](architecture.md).

## Files

| Area | Files |
|---|---|
| Application engine 1.2.0: failure classes, backoff with jitter, network/source diagnosis and deferral, lifecycle, attempt history, atomic state with backup, state validation and v1→v2 migration, runtime-budget outcome, verification after success, Retry mode | `src/engine/applications/scripts/ApplicationEngine.ps1` |
| `-Resume` that keeps state and verifies copies | `src/engine/applications/scripts/Install-ApplicationEngine.ps1` |
| Orchestrator 1.1.0: atomic state with backup, damaged-state handling, outcome model and exit codes, idle user stage, restart-marker fix | `src/engine/deployment/scripts/DeploymentCommon.ps1`, `DeploymentOrchestrator.ps1`, `Initialize-Deployment.ps1`, `Resume-Deployment.ps1`, `Show-DeploymentStatus.ps1` |
| Report v2: outcome, outstanding work, attempts, recovery commands | `src/engine/deployment/scripts/Complete-Deployment.ps1` |
| Technician recovery tool (new) | `src/engine/deployment/scripts/DeploymentRecovery.ps1` → `scripts/recovery/` in the package |
| Settings, defaults, configuration, manifest, result schema 2 | `src/engine/schema/applications.ts`, `profiles/owner-default.json`, `src/features/applications/index.ts`, `src/ui/layout.ts`, `src/engine/applications/index.ts`, `src/engine/applications/results.ts`, `src/engine/deployment/index.ts` |
| Final Review line | `src/engine/quick.ts`, `src/ui/wizard.ts` |
| Tests | `tests/unit/recovery.test.ts` (new); Phase 5 sections in `tests/powershell/Applications.Tests.ps1` and `Deployment.Tests.ps1`; fixtures `tests/unit/fixtures/p43-gaming.profile.json`, `tests/fixtures/applications/engine-1.1.0-config.json` (exported by the Phase 4.3 generator); updates listed in [testing.md](testing.md) |
| Docs | this folder; `README.md`, `docs/architecture.md`, `docs/roadmap.md`, `docs/testing.md`; regenerated `docs/settings-mapping.md`, `docs/samples/` |

## Existing recovery mechanisms reused

Machine-wide state and ACLs; attempt counted before each install; reconciliation of interrupted
installs with `winget list`; idempotency check before every attempt; the OS-held install lock
(never stale); boot-bound restart markers; mutexes with abandoned-owner handling; restart and
runtime limits; the SYSTEM monitor and its integrity check; staging from the answer file (USB not
needed afterwards); the Windows Update engine unchanged (its retry, component reset, offline and
restart logic, and its "installed updates are never offered again" property); the Phase 4.3 policy
step (applied once after the update stage is final). See [audit.md](audit.md).

## New functionality

* **Failure classification** (Network, Transient, Timeout, Resource, Unknown retried; Integrity,
  Policy, Permanent, User, Manual never retried automatically), mirrored in TypeScript and checked.
* **Bounded automatic retry**: 3 attempts by default, 60 s doubling to at most 15 min, ± 20 %
  jitter, all clamped; waits count toward the existing runtime limit; the queue loop is bounded.
* **Network-aware deferral**: a network-class failure is diagnosed (adapter, route, DNS, source
  TCP, connectivity probe); lost connectivity defers the package without using its budget (at most
  6 times); an unreachable source (for example the Store) only holds its own packages.
* **Never stuck in Running**; **success verified** (`winget list` after a reported success;
  `Unconfirmed` is a follow-up).
* **Atomic, validated, versioned state** with last-good backups for the engine and the
  deployment; damaged deployment state stops safely and is rebuilt by the recovery tool.
* **Outcomes with exit codes** in `status.json`, the report and the recovery tool.
* **Outstanding work kept** after the deployment ends (`result.json` `outstanding`, report
  `outstanding` with the next action).
* **Technician recovery tool**: Status (`-Json`), PendingActions, RetryFailed, Retry one or more
  (`-IncludePermanent`), Resume, ExportDiagnostics (redacted ZIP), menu, desktop shortcut with
  elevation.
* **Website**: Advanced › Applications › Reliability & recovery (automatic retry, attempts, continue
  after a failure, include the recovery tool); Final Review states what happens on failure; the
  Quick Deployment wizard has no new controls. New deployments prefill the username `owner`.
* **Fixed**: the monitor now recognises restarts scheduled by the engines (`requestedUtc` /
  `bootTimeUtc`), so `restartPending` and PausedAwaitingReboot are reported.

## State schema changes

| State | Before | Now |
|---|---|---|
| `Applications\state.json` | version 1 | version 2: per operation `operationId`, `failureClass`, `retryable`, `nextAttemptUtc`, `waitingFor`, `networkDeferrals`, `detection`, `totalAttempts`, `manualRetries`, `history[]`; run `recoveries[]`, `recoveredFrom`, `originalStartUtc`, `halted`. v1 is upgraded without changing any status. |
| `Applications\result.json` | schema 1 | schema 2: the fields above per operation plus `lifecycle`; `outstanding[]`, `retryPolicy`, `recoveries[]`, `stateRecoveredFrom` |
| `state\deployment.json` | schema 1 | schema 2: `recoveries[]`; stage launch records gain `user` |
| `Deployment\status.json` | snapshot | + `outcome`, `outcomeCode`, `outcomeDetail`; stages + `idle`, `outstanding` |
| Deployment report | v1 | v2: `outcome`, `outcomeCode`, `outstanding[]`, `recoveries[]`, `recoveryCommands`; per application `operationId`, `lifecycle`, `failureClass`, `retryable`, `detection`, `totalAttempts`, `manualRetries` |
| `applications-config.json` | schema 1, engine 1.1.0 | schema 1, engine 1.2.0, optional `retry` |
| Manifest | manifestVersion 1, package 1.0.0 | manifestVersion 1, package 1.1.0, `recovery` block, `paths.recoveryTool` |
| Profile | schema 4 | schema 4 + `applications.recovery` (filled on import) |

## Retry policies and defaults

| | Default | Range / bound |
|---|---|---|
| Automatic retry | on | off = 1 attempt per run |
| Attempts per application | 3 (profiles from before Phase 5 keep theirs, 2 by default) | 1-5 in the UI, engine clamps to 1-10 |
| Backoff | 60 s × 2^(n-1), cap 900 s, jitter 0.2 | base ≤ 3600 s, cap ≤ 3600 s, jitter ≤ 0.5 |
| Network deferrals | 6 per application | ≤ 24 |
| Continue after a failure | on | off = stop the queue, rest stays outstanding |
| Recovery tool | included | can be left out |
| Unchanged | package timeout 30 min, runtime 4 h, 3 restarts, update engine limits, deployment deadline | |

## Automatic recovery scenarios supported

Transient download or installer failure; installer timeout; package lock contention; undocumented
exit code (bounded); network lost mid-run (pause, resume); one package source down (others
continue); installer-requested restart before or after install; installer-initiated restart; engine
crash or power loss during an install (reconciled); power loss during a state write (backup); a
damaged application state (backup, else verified rebuild); a stale install lock; a pending Windows
restart before installing; a user not signed in (reported, resumes at sign-in); runtime limit
(finished work kept); dependency failure (dependents blocked, not failed); Windows Update's own
scan, download and install retries (unchanged).

## Manual recovery procedure

See [recovery.md](recovery.md): open Deployment recovery (administrator), check Status and Pending
actions, fix the cause, then RetryFailed (or Retry a specific operation; `-IncludePermanent` only
after correcting a permanent failure), or Resume for interrupted provisioning or a damaged state;
export diagnostics when asking for help. Windows is not reinstalled; successful operations never run
again; every recovery is recorded.

## Test counts

typecheck, lint, build clean. Vitest 395 passed (18 files). PowerShell: Windows Update 25/25,
applications 82/82 (25 new), deployment and full lifecycle 43/43 (11 new), Wi-Fi 10/10. Playwright
124 passed, 2 skipped. 10 mutation checks detected. Details and the fault-injection table:
[testing.md](testing.md).

## Deployment ZIP changes

Default configuration: 30 ZIP entries (Phase 4.3: 29). New: `WindowsDeployment/scripts/recovery/
DeploymentRecovery.ps1` (also embedded in the answer file and staged to
`C:\ProgramData\WindowsDeploymentBuilder\Package\scripts\recovery\`). Changed: the application
engine and its installer, the orchestrator scripts and the report script, `applications-config.json`
(engine 1.2.0, 3 attempts, `retry`), the manifest (package 1.1.0, `recovery`), README and
INSTALLATION texts (automatic retry vs manual recovery), the results schema. All 28 manifest files
match their SHA-256 in the ZIP; 18 are embedded. With both engines off the answer file is
byte-identical to Phase 4.3 (and to Milestone 1).

## Backward compatibility results

Engine 1.2.0 runs a 1.0.0-format configuration and the real Phase 4.3 (engine 1.1.0) configuration
under `Set-StrictMode -Version 2.0`; state version 1 is upgraded without reopening completed or
failed work; profiles from Milestone 1, Phase 2, Phase 4, 4.2 and 4.3 import with safe defaults;
every Phase 4/4.3 report field is still written; only Windows PowerShell 5.1 is assumed.

## Bare-metal test readiness

[bare-metal-checklist.md](bare-metal-checklist.md): safety (spare computer or expendable drive,
other drives disconnected, backup path, official Windows 11 Pro x64 media, manual disk
selection), a small application set, the default username `owner`, 14 first-run checks (edition,
account, computer name, staging, updates, restarts, a deliberate network interruption, applications,
retry, final report, diagnostics, USB removal, update policy), evidence to collect and what to do
when something goes wrong. Not performed yet.

## Known limitations

* **No VM or bare-metal validation.** Everything above is verified by simulation against the real
  scripts and the real generated package.
* `Get-WdaNetworkDiagnosis`, `[IO.File]::Replace` under a real power loss, the elevation prompt
  and `Install-ApplicationEngine.ps1 -Resume` (registers a real task) are not exercised on Windows
  by the tests (the last one has static checks only).
* `Unconfirmed` relies on `winget list` finding what `winget install` installed; a package WinGet
  cannot correlate would be reported as a follow-up (honest, possibly noisy).
* The Windows Update engine was deliberately left unchanged: its state is still written with the
  Phase 2 method (not atomic). A damaged update state makes it start a new scan, which is safe
  because installed updates are not offered again.
* No independent download manager: interrupted WinGet downloads are retried by a new attempt,
  not resumed byte-wise (WinGet decides; it never runs a partial or unverified file).
* Application retries must run as the deployment user (WinGet is per user); if another
  administrator runs the tool, the application task is registered for that administrator.
* `Resume-Deployment.ps1 -RestartStage` keeps its Phase 4 behaviour (a new run; history archived
  as `.bak`); the recovery tool is the history-preserving path.
* The main web bundle still exceeds Vite's 500 kB advisory size (as before).

## Incomplete requirements

None of the requested behaviours is missing or merely simulated in the code. What remains is the
real-hardware validation the specification itself reserves for the bare-metal test (§19), and the
items listed under known limitations.

## Acceptance audit

| § | Requirement | Status | Evidence |
|---|---|---|---|
| 2 | Audit; branch from 4.3; history preserved | Done | [audit.md](audit.md); branch from `e9e9e3c`; no other branch touched |
| 3 | Durable machine-wide state, tracked fields, no secrets, atomic writes, corruption strategy, restricted ACL | Done | state model in [architecture.md](architecture.md); atomic-write and corruption scenarios |
| 4 | Lifecycle, stable ids, never stuck Running, reconcile both ways | Done | `Get-WdaLifecycle`; power-loss, interrupted-but-installed, false-success scenarios |
| 5 | Configurable bounded retries, backoff, jitter, budgets; transient vs permanent; unknown recorded | Done | retry-policy, backoff, exhausted, permanent, unknown/timeout/lock scenarios |
| 6 | Download recovery without weakening verification | Done (WinGet-native) | hash-mismatch scenarios (WinGet and portable); no download manager by design |
| 7 | Idempotency, detection states, no duplicates, deselections preserved | Done | `winget list` before every attempt; `detection`; portable "no duplicate" scenario; deselection refusal |
| 8 | Windows Update recovery without a competing scheduler; policy ordering | Done | engine unchanged (25/25 scenarios); WU-stage relaunch scenario: policy not re-applied |
| 9 | Network readiness levels, source-specific, no settings changed, bounded | Done | network-lost and Store-source scenarios; diagnosis is read-only |
| 10 | Startup/reboot: duplicates, races, simultaneous runs, stale locks, loops, missing files, interrupted writes; USB-independent | Done | existing Phase 4 scenarios + stale lock, restart marker, USB-removed and integrity scenarios |
| 11 | Technician recovery: status, retry failed/one, resume, diagnostics, pending actions; safeguards | Done | `DeploymentRecovery.ps1`; recovery and refusal scenarios (engine and package level) |
| 12 | Distinct completion outcomes, recoverable after failures, machine-readable | Done | outcome table and exit codes; lifecycle scenarios 10/20/30/31/32/50 |
| 13 | Per-attempt logging, technician-readable, machine-readable, redacted diagnostics | Done | `attempts.jsonl`, engine log lines, report; diagnostics scenario |
| 14 | Website settings (Advanced only), safe defaults; ZIP includes recovery payload | Done | Reliability & recovery group; browser test; ZIP inspection |
| 15 | Compatibility 3/4/4.2/4.3, StrictMode, PS 5.1, versioned migration | Done | compatibility table in [testing.md](testing.md) |
| 16 | Security model | Done | [security.md](security.md); refusal, integrity and redaction scenarios; static checks |
| 17 | Unit, engine, update, deployment and security tests | Done | [testing.md](testing.md) |
| 18 | Deterministic fault injection, no real system faults, no live Internet | Done | fault-injection table in [testing.md](testing.md) |
| 19 | Bare-metal checklist; `owner` prefilled; independent username/computer name; warnings kept | Done (checklist); **validation not performed** | [bare-metal-checklist.md](bare-metal-checklist.md); quick.test and browser tests for `owner` |
| 20 | Documentation incl. the 18/2 example and automatic vs manual | Done | this folder; [recovery.md](recovery.md) |
| 21 | Acceptance criteria | Met in simulation; bare-metal pending | this report |
| 22 | Checks, ZIP inspection, commit, push | See the final report | |
