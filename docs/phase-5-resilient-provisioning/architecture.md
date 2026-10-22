# Phase 5 architecture: resilient provisioning, resume and retry

Phase 5 adds operational resilience to the existing engines; it does not add a second installer,
scheduler or download manager. Windows Update remains the job of `WindowsUpdateEngine.ps1`
(unchanged), applications of `ApplicationEngine.ps1` (now 1.2.0), and the SYSTEM monitor still
only follows what the engines write.

```
                   answer file (embedded copies)            USB drive (not needed after staging)
                               │ FirstLogon
                               ▼
  Initialize-Deployment ── verify + stage ──► C:\ProgramData\WindowsDeploymentBuilder\Package (verified copy)
          │ launches each stage once (recorded before it starts)
          ├──► \WindowsDeploymentBuilder\WindowsUpdate (SYSTEM)     → Updates\state.json, result.json
          ├──► \WindowsDeploymentBuilder\Applications (signed-in user, sign-in + hourly)
          │                                                          → Applications\state.json(.bak), result.json,
          │                                                            logs\attempts.jsonl
          └──► \WindowsDeploymentBuilder\Deployment (SYSTEM monitor, startup + 15 min)
                     → Deployment\status.json (outcome, outcomeCode), state\deployment.json(.bak),
                       reports\deployment-report.json/.txt (outstanding work, recovery commands)

  Technician: "Deployment recovery" shortcut → scripts\recovery\DeploymentRecovery.ps1
     verifies the package → engine Retry logic (under the engine's mutex) → Install-ApplicationEngine -Resume
     (task again, state kept) → reopens the deployment → the monitor follows as before
```

## State model

All state is machine-wide below `C:\ProgramData\WindowsDeploymentBuilder` (SYSTEM and
Administrators full control, Users read). No password, Wi-Fi key or token is ever written there:
the engines record identifiers, exit codes, classes and their own messages only.

| File | Writer | Schema | Contents |
|---|---|---|---|
| `state\deployment.json` (+ `.bak`) | orchestrator, recovery tool | 2 (reads 1) | package id/version, status (Staging, StagingFailed, Launching, InProgress, Completed, IntegrityFailed), stage launch records (result, attempts, time, exit code, user), deadline, monitor runs, ongoing update policy result, `recoveries[]` |
| `Deployment\status.json` | monitor | snapshot | stages, current stage, restart pending, needs attention, `overall`, **`outcome`, `outcomeCode`, `outcomeDetail`** |
| `Applications\state.json` (+ `.bak`) | application engine | 2 (reads 1) | per operation: `operationId`, status, attempts (budget), `totalAttempts`, exit code, `failureClass`, `retryable`, `nextAttemptUtc`, `waitingFor`, `networkDeferrals`, `detection`, `manualRetries`, `history[]` (last 20); run: starts, reboots, first start, install start, `halted`, `recoveries[]`, `recoveredFrom` |
| `Applications\result.json` | application engine | 2 | final status and reason, every operation with its lifecycle, `outstanding[]`, `retryPolicy`, `recoveries[]`, `stateRecoveredFrom` (JSON Schema: `applications-results.schema.json`) |
| `Applications\logs\attempts.jsonl` | application engine | one JSON object per line | every attempt: operation id, name, trigger (automatic/manual), attempt, start/end, result, exit code, class, counts toward limit, next action, next attempt, restart required, package id and source |
| `Applications\history\result-*.json` | Retry mode | 2 | each previous final result, kept when a stage is reopened |
| `reports\deployment-report.json/.txt` | monitor at the end | report 2 | outcome, per-application attempts and lifecycle, `outstanding[]` with the next action, `recoveries[]`, recovery commands |

The tracked fields requested for Phase 5 map as follows: deployment ID = `packageId`; manifest
version/hash = `packageVersion` + `packageId` (a hash of every file that runs on the computer);
current phase = deployment `status` + stage states; operation ID = `operationId`; package ID and
source = `packageIdentifier`, `source`; attempt count = `attempts` (current budget) and
`totalAttempts`; last attempt time = `updatedUtc` / history; last exit code or reason = `exitCode`,
`message`; completion status = `status` + derived `lifecycle`; reboot required = `RequiresRestart`
/ `restart` / `detection = InstalledRequiresRestart`; last checkpoint = the last successful state
write (`state.json`, with the previous one in `state.json.bak`); pending user action =
`ManualActionRequired` operations and the report's remaining tasks; overall = `outcome`.

### Atomic writes and corruption recovery

Every state write goes to `<file>.tmp` with `FileOptions.WriteThrough`, then
`[IO.File]::Replace(tmp, file, file.bak)` swaps it in one file-system operation and keeps the
previous version as `.bak`. A power loss therefore leaves the old file, the new file, or both,
never a half-written one.

Reading: the main file is validated (version this engine understands, maps whose keys match their
entries, known statuses, numeric attempt counts, known final status). If it is unusable it is kept
as `.corrupt` and the `.bak` is used. Only if both are unusable does the application engine start
a new state; even then nothing completed is repeated, because every package is checked with
`winget list` before any installation. The deployment state is stricter: if neither copy is usable
the monitor stops (`StateCorrupt`, outcome `FailedToInitialize`, event 3004), `Initialize` refuses
to start over (a new state would launch stages a second time), and
`DeploymentRecovery.ps1 -Action Resume` rebuilds it from the verified manifest and what the engines
wrote (a stage with a result, status file or task counts as launched and is never launched again).

### Migrations

State version 1 (engines 1.0/1.1, orchestrator 1.0) is upgraded in place on first read: new fields
get neutral defaults and **no status changes**, so a completed operation never becomes pending and
a failed one is not silently retried. Configuration files without the engine 1.2.0 `retry` block,
and profiles without `applications.recovery`, get the same defaults as new ones (see
[Manifest and configuration compatibility](#manifest-and-configuration-compatibility)).

## Operation lifecycle

Every operation has a stable id: `app:<source>:<id>` (for example `app:winget:git.git`,
`app:msstore:9np83lwlpz9k`, `app:catalog:rustdesk` for a manual catalog entry) or
`additional:<id>`. The engine keeps its existing `status` values (so earlier consumers keep
working) and derives one lifecycle state from them (`Get-WdaLifecycle`); there is no second copy
of the state.

| Lifecycle | From status | Meaning |
|---|---|---|
| Pending | Pending, no attempt yet | not started |
| Running | Installing | an installer is running (after a crash this becomes Pending + interrupted, then `winget list` decides) |
| Succeeded | Succeeded | installed by this deployment (`detection` says how it was confirmed) |
| AlreadySatisfied | AlreadyInstalled | was already installed; left unchanged |
| FailedRetryable | Failed (class Network, Transient, Timeout, Resource, Unknown, Budget), or Pending with a scheduled retry | can succeed on another attempt (automatic while the budget lasts, otherwise the recovery tool) |
| FailedPermanent | Failed (class Permanent, Integrity, Policy), Unavailable | another attempt would not help until the cause is corrected |
| WaitingForNetwork | Pending with `waitingFor` = `network` or `source:<name>` | deferred until connectivity or the package source is back |
| WaitingForReboot | RequiresRestart | needs a restart before or after installing |
| ManualActionRequired | RequiresInteraction (manual catalog entry, interactive installer, cancelled installer) | a person has to act |
| SkippedByUser | SkippedByUser | deselected for this deployment |
| BlockedByDependency | Skipped | a dependency did not install; retried together with it |

`detection` distinguishes Installed, InstalledRequiresRestart, NotInstalled, **Unconfirmed**
(WinGet returned success but `winget list` does not show the package: reported as a follow-up,
never a silent success) and Unknown (the check itself failed). A portable package whose Start menu
shortcut could not be created stays installed and is listed as a follow-up (configuration
incomplete).

## Retry policy (automatic)

| Setting | Default | Where |
|---|---|---|
| Automatic retry | on | `applications.recovery.automaticRetry` → `retry.automatic` |
| Attempts per application (first included) | 3 (Phase 4.x: 2; older profiles keep theirs) | `applications.maxAttemptsPerPackage` (1-5) |
| First wait, growth, cap | 60 s, doubling, 15 min (`RETRY_TIMING`) | `retry.baseDelaySeconds`, `retry.maxDelaySeconds` |
| Jitter | ± 20 % (never above the cap) | `retry.jitterRatio` |
| Network deferrals per application | 6 | `retry.maxNetworkDeferrals` |
| Continue after a failure | on | `applications.recovery.continueAfterFailure` → `retry.continueAfterFailure` |
| Package timeout, runtime limit, restarts | unchanged (30 min, 4 h, 3) | existing settings |

The engine clamps every value whatever the configuration says (at most 10 attempts, delays at
most 1 h, jitter at most 50 %, at most 24 deferrals), and the queue loop has a hard iteration
bound. Backoff waits count toward the existing runtime limit; when that limit is reached, the
finished work is kept and the rest is `Failed` with class `Budget` (retryable), so the stage ends
`CompletedWithFailures` instead of a blanket `Failed`. With automatic retry off, each application
gets one attempt per run and failures wait for the recovery tool.

## Failure classification

`$script:ExitCodes` (and its TypeScript mirror `WINGET_EXIT_CODES`, compared by a test) gives every
documented WinGet result a class:

| Class | Examples | Automatic retry |
|---|---|---|
| Network | `INSTALL_NO_NETWORK`, `DOWNLOAD_FAILED`, `SOURCE_OPEN_FAILED` | yes, after a network check (below) |
| Transient | package/file in use, another installation in progress, missing dependency | yes |
| Timeout | the installer exceeded `packageTimeoutMinutes` (process stopped) | yes |
| Resource | out of memory (retried); disk full (not retried, technician) | as listed |
| Unknown | any undocumented code (recorded as is) | yes, within the normal budget only |
| Integrity | `INSTALLER_HASH_MISMATCH`; Additional Software hash or signature failure | **never** |
| Policy | blocked by policy (WinGet or Store) | **never** |
| Permanent | not found, not applicable to this system, several matches, agreements | **never** |
| User | installer cancelled | **never** |
| Manual | no unattended installation exists | **never** (manual action) |

Also never retried: explicitly deselected applications (not in the installable set at all),
invalid identifiers (refused before WinGet is called) and antivirus conflicts (the selection
validation of Phase 4.2 refuses to generate them). A technician can retry a permanent failure after
correcting its cause (`-IncludePermanent`); the engine then installs exactly as before, so WinGet
verifies the hash again and the policy still applies. Retries never pass extra flags and never
weaken WinGet's verification.

## Download recovery

WinGet downloads, caches and verifies every installer (SHA-256 from the manifest) and does not run
a partial download; portable tools are WinGet portable packages, so the same applies. The engine
therefore adds no download manager of its own. Additional Software runs only from a file the
technician supplied, after its SHA-256 and Authenticode signature have been checked; the engine
never downloads it. A hash failure in either path is an Integrity failure and is never retried
automatically.

## Network recovery

At each start the engine waits up to `networkWaitMinutes` for connectivity (unchanged). New: when
an attempt fails with a Network-class code, `Get-WdaNetworkDiagnosis` checks, in order, a connected
adapter, a default route, DNS for the package source's host, TCP 443 to that host, and the Windows
connectivity probe, and reports `NoInterface`, `NoLocalNetwork`, `DnsUnavailable`,
`SourceUnavailable` (Internet fine, that source unreachable) or `InternetUnavailable`. It changes
nothing (no adapter, DNS, proxy, firewall or Wi-Fi setting is touched).

* Connectivity really lost: the attempt is not held against the package (`countsTowardLimit:
  false`), the package waits (`WaitingForNetwork`), progress is saved and the run stops with
  `WaitingForNetwork`; the task resumes at the next sign-in or within the hour.
* Only one source down (for example the Microsoft Store): its packages wait, packages from other
  sources continue in the same run.
* Bounded: at most `maxNetworkDeferrals` per package, then `Failed` (class Network, retryable by a
  technician); the existing runtime and offline limits still apply.

## Reboot and startup recovery

Unchanged and reused: the SYSTEM monitor (startup + 15 min, `MultipleInstances IgnoreNew`), the
user task (sign-in + hourly), `Register-ScheduledTask -Force` (re-registration replaces, never
duplicates), the mutexes, the OS-held install lock, boot-bound restart markers, `maxReboots`.
New: the restart marker the engines write (`requestedUtc`, `bootTimeUtc`) is now understood by the
monitor, so `status.json` shows `restartPending` and outcome `PausedAwaitingReboot`; a marker from
an earlier boot is ignored. Engine files run from the verified local copy; neither the USB drive
nor a WinPE share is needed after staging (tested by removing the USB copy after staging).

## Outcomes and exit codes

`status.json`, the report and `DeploymentRecovery.ps1 -Action Status` use one outcome:

| Outcome | Code | When |
|---|---|---|
| Succeeded | 0 | every enabled stage succeeded |
| CompletedWithWarnings | 10 | finished; manual actions or follow-ups remain (CompletedWithFollowUp) |
| CompletedWithFailures | 20 | finished; some updates or applications failed (outstanding work is kept) |
| Incomplete | 25 | ended (deadline, offline) before every stage finished |
| PausedAwaitingNetwork | 30 | a stage waits for the network or a package source |
| PausedAwaitingReboot | 31 | a restart is scheduled or in progress |
| PausedAwaitingUser | 32 | a stage stalled, or the user-context stage has not run (its user is not signed in) |
| InProgress | 40 | running |
| FailedToInitialize | 50 | no usable state, staging or integrity failure |
| Failed | 60 | a stage failed |

The existing `overall` values are unchanged.

## Manifest and configuration compatibility

* Manifest: still `manifestVersion` 1 (additive): `packageVersion` 1.1.0, a `recovery` block (tool,
  retry policy, `neverRetriedAutomatically`, `stateSchemas`, `outcomeCodes`, actions) and
  `paths.recoveryTool`. Orchestrator 1.0.0 would ignore the new keys.
* `applications-config.json`: still schema 1, engine 1.2.0, new optional `retry` block. Engine 1.2.0
  runs configurations from engines 1.0.0 and 1.1.0 (tested with a 1.0-format config and with the
  real Phase 4.3 output, `tests/fixtures/applications/engine-1.1.0-config.json`, under
  `Set-StrictMode -Version 2.0`; optional keys are tested with `ContainsKey` / index access, never
  with property access that Windows PowerShell 5.1 StrictMode rejects).
* Profiles: still schema 4. `applications.recovery` is filled from owner defaults on import
  (Milestone 1, Phase 2, Phase 4, 4.2 and 4.3 exports tested); malformed values are rejected.
* Windows PowerShell 5.1 only; nothing assumes PowerShell 7.
