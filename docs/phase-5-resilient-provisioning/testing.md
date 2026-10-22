# Phase 5 testing

## Strategy

Nothing in this phase touches the development computer: no application is installed or removed, no
task is registered, no network, disk or Windows setting is changed, Windows Setup is not run. Every
system interaction is an adapter function that the PowerShell scenario suites replace with a
simulation (WinGet, the network and its diagnosis, Task Scheduler, restarts and boot time, the
clock, the jitter source, identity, the event log, shortcuts, ACLs). Faults are injected
deterministically into those simulations, never into the real system, and no routine test needs
an Internet connection.

Three levels:

1. **Engine fault injection** (`tests/powershell/Applications.Tests.ps1`): the real
   `ApplicationEngine.ps1` on a simulated WinGet.
2. **Full lifecycle** (`tests/powershell/Deployment.Tests.ps1`, Phase 5 section): the real
   deployment ZIP produced by the generator, extracted with the answer file's own ExtractScript,
   staged, then the real application engine and the real recovery tool *from that package* run with
   its real `applications-config.json` (WinGet, Microsoft Store, portable and manual entries); the
   monitor writes the real status and report.
3. **TypeScript** (`tests/unit/recovery.test.ts`, updated suites) and **browser**
   (`tests/e2e/app.spec.ts`, `quick.spec.ts`).

## Automated results (2026-10-22, this branch)

| Check | Result |
|---|---|
| `npm run typecheck`, `npm run lint`, `npm run build` | clean (the bundle-size advisory as before) |
| Vitest (`npm test`) | **395 passed in 18 files** (Phase 4.3: 378 in 17): 16 new in `recovery.test.ts`, 1 new in `quick.test.ts`; includes the four PowerShell suites below via `powershell.test.ts` |
| Windows Update engine (`Engine.Tests.ps1`) | 25/25 (unchanged; the engine is unchanged) |
| Application engine (`Applications.Tests.ps1`) | **82/82** (57 earlier + 25 Phase 5) |
| Deployment orchestrator and full lifecycle (`Deployment.Tests.ps1`, real generated package) | **43/43** (32 earlier + 11 Phase 5) |
| Wi-Fi script (`Wifi.Tests.ps1`) | 10/10 (unchanged) |
| Playwright, desktop 1280x720, tablet 820x1180, mobile Pixel 7 | **124 passed, 2 skipped** (the mobile-only drawer test on desktop and tablet, as before): 1 new test per size |
| Mutation checks | 10 deliberate defects (7 in the engine, 3 in the orchestrator and recovery tool), each detected by its scenario |
| Regression against Phase 4.3 (`e9e9e3c`) | both engines off: answer file byte-identical; otherwise only the embedded engine and orchestrator scripts, `applications-config.json`, the manifest and the new recovery script differ (six profiles compared file by file) |
| ZIP inspection (default configuration) | 30 entries (Phase 4.3: 29), 28 manifest files all matching their SHA-256, 18 embedded (Phase 4.3: 17) |

Existing tests changed only where Phase 5 deliberately changed behaviour or where a test was
timing-dependent:

* New deployments prefill the username `owner`: `profiles.test.ts` (default value),
  `generate.test.ts` ("a cleared account name refuses to generate", previously "owner default
  without a name"), `quick.test.ts` (the blocking test clears the name first), `app.spec.ts` (the
  name test starts from `owner`, then clears it; reset returns to `owner`; the "blocked package"
  test clears the name), `quick.spec.ts` (identity starts complete; the blocking test clears it).
* Three attempts by default: `applications-generate.test.ts` expects 3 and the `retry` block; the
  `app.spec.ts` attempts test now sets 4 (setting 3 would no longer prove anything).
* `powershell.test.ts`: the exit-code mirror also compares the failure class; the result-schema
  check covers four more saved results (schema 2).
* Engine log line: the class is appended after the message, so the existing log assertion is unchanged.
* Three answer-file snapshots were updated after a file-by-file comparison showed that only the
  embedded scripts, configuration and manifest changed (see the regression row).
* Timing: the single-instance tests in `Applications.Tests.ps1` and the concurrent-run test in
  `Deployment.Tests.ps1` waited a fixed 2-3 s for a helper process to take a mutex and failed once
  on a loaded machine; they now wait for an explicit "held" signal. The assertions are unchanged.
* The deployment simulation's engine installer now archives the engine's previous run, as the real
  installers do (needed to retry a finished stage).

## Fault-injection coverage

| Fault (injected in the simulation) | Scenario | Verified |
|---|---|---|
| Download fails on the first attempt | transient failures …; lifecycle: mixed methods … | retried after 60 s, succeeds, attempts recorded |
| Download fails twice | transient failures: waits 60 s then 120 s … | exponential backoff, third attempt succeeds |
| Persistent download failure | exhausted retry budget …; documented example | exactly `maxAttempts` installs, FailedRetryable, outstanding |
| Installer timeout | unknown exit code, installer timeout and package lock contention … | class Timeout, retried |
| Package lock contention (`INSTALL_IN_PROGRESS`) | same | class Transient, retried |
| Undocumented exit code | same | class Unknown, code kept, bounded retry |
| Network lost mid-run | network lost mid-run …; lifecycle: lost network pauses … | WaitingForNetwork, attempt not counted, nothing failed, PausedAwaitingNetwork (30), resumes |
| Microsoft Store source down | Microsoft Store source unavailable … | WinGet packages continue, Store package waits for its source |
| Source never returns | source never returns … | bounded deferrals, Failed (retryable), bounded number of runs |
| Hash mismatch (WinGet, portable) | permanent failures …; portable download integrity failure … | one attempt, FailedPermanent, no shortcut |
| Cancelled installer, package not found | permanent failures … | never retried |
| Installer reports failure but the app is installed | interrupted installer that finished anyway … | confirmed by `winget list`, not reinstalled |
| Installer reports success but the app is missing | successful exit code without the application … | Unconfirmed, follow-up, never a silent success |
| Engine crash / power loss with operations Running | crash during installation (Phase 3); power loss with operations left Running … | reconciled, interrupted attempt counted, nothing stuck |
| Restart required before install | lifecycle: restart during provisioning … | restart, PausedAwaitingReboot (31), resumes after the boot, nothing repeated |
| Power loss while writing the state (truncated file) | state writes are atomic … | last good copy used, completed work not repeated |
| Malformed / untrusted / future-version state | malformed or untrusted states are rejected … | rejected, verified fresh run |
| Damaged deployment state (main, then both copies) | Phase 5 state: a damaged deployment.json … | backup used; StateCorrupt stops safely; Initialize refuses; Resume rebuilds without relaunching |
| Stale install lock (owner gone) | stale install lock … | taken over at once; a live lock is respected |
| Engine running during a retry | recovery: never runs while the engine runs … | Busy |
| Runtime limit reached | runtime limit … | finished work kept, rest Failed (Budget), CompletedWithFailures |
| Dependency failure | recovery: a dependent application is retried together with its failed dependency … | BlockedByDependency, both reopened, dependency first |
| Transient Windows Update failure | Engine.Tests (existing): update that fails once then succeeds; download failures; Phase 5: a failed Windows Update stage is relaunched once … | stage relaunched once, ongoing policy not re-applied |
| USB removed after staging | Phase 5 lifecycle: USB and setup files gone … | engine, monitor and recovery work from the local copy |
| Tampered staged engine | Phase 5 recovery: refuses … tampered packages | IntegrityFailed, nothing reopened |
| User not signed in | Phase 5 status: idle user stage … | PausedAwaitingUser (32) with who must sign in |
| Planted password and Wi-Fi key | Phase 5 diagnostics … | redacted; no `.xml`, no answer file in the ZIP |

Mutation checks (each run once, then reverted): the scenarios above failed when the network-attempt
refund, the permanent-failure classification, the backup fallback, the "stop after a failure"
switch, the backoff, the state validation, the corrupt-state refusal in Initialize, the integrity
check in the recovery tool or the restart-marker fix was removed. One gap was found this way and closed: removing the explicit "deselected" refusal was still caught only by a generic message, so the assertion now checks the exact reason.

## Backward compatibility

| Input | Test | Result |
|---|---|---|
| Engine 1.0.0 configuration (no `method`, `manual`, `deselected`, `retry`) | `a 1.0.0-format configuration … still runs unchanged` | runs |
| Real engine 1.1.0 configuration from the Phase 4.3 generator | `a real engine 1.1.0 configuration … runs under StrictMode` | runs under `Set-StrictMode -Version 2.0`, defaults applied |
| Application state version 1 | `state version 1 (engine 1.0/1.1) is upgraded …` | upgraded; Succeeded and Failed unchanged |
| Profiles from Milestone 1, Phase 2, Phase 4, 4.2 and 4.3 | `recovery.test.ts` | import; `applications.recovery` filled with safe defaults |
| Answer file with both engines off | regression comparison against `e9e9e3c` | byte-identical |
| Phase 4/4.3 report readers (`overall`, `remainingTasks`, `recovery` text) | existing Deployment scenarios | unchanged fields still present |

## Not tested: needs real hardware (status: UNVERIFIED)

See [bare-metal-checklist.md](bare-metal-checklist.md). In particular, these are exercised only by
simulation: `Get-WdaNetworkDiagnosis` against real adapters, `[IO.File]::Replace` on the target's
NTFS volume during a real power loss, `Install-ApplicationEngine.ps1 -Resume` (registers a real
task; covered by static checks only), the elevation prompt of the recovery shortcut, `winget list`
detection for every catalog package after installation (`Unconfirmed` would show up as a
follow-up), and the diagnostics ZIP on a real system.
