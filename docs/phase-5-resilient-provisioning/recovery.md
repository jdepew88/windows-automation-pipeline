# Automatic retry and manual recovery

## The difference

**Automatic retry** happens by itself, inside the application stage, while the deployment runs.
It is for failures that usually go away: a download that broke, a mirror that timed out, an
installer that found another installation in progress. Each application gets a small, fixed budget
(3 attempts by default) with a growing wait (1 min, 2 min, 4 min … at most 15 min). A lost network
connection does not use up the budget: the application waits for the network instead. Permanent
problems (hash mismatch, policy block, package not found, cancelled installer) are never retried
automatically. When the budget is used up, the application is reported `FailedRetryable` and the
deployment finishes `CompletedWithFailures`. Nothing else is held up (unless "Continue with other
applications after a failure" is off).

**Manual recovery** is a decision by a technician after the cause has been looked at: the Wi-Fi
works again, the vendor's mirror is back, the disk has space, a corrected installer was supplied.
The recovery tool reopens exactly the operations that should run again, with a fresh attempt budget,
and lets the existing engine install them the same way as the first time. Windows is not reinstalled,
nothing that succeeded runs again, and the history of every attempt is kept.

## Technician commands

Open **Deployment recovery** on the desktop (it asks for administrator rights), or run in an
elevated Windows PowerShell:

```
$tool = 'C:\ProgramData\WindowsDeploymentBuilder\Package\scripts\recovery\DeploymentRecovery.ps1'
powershell.exe -ExecutionPolicy Bypass -File $tool                       # menu
powershell.exe -ExecutionPolicy Bypass -File $tool -Action Status        # outcome, stages, every operation
powershell.exe -ExecutionPolicy Bypass -File $tool -Action Status -Json  # the same, machine-readable; exit code = outcome code
powershell.exe -ExecutionPolicy Bypass -File $tool -Action PendingActions
powershell.exe -ExecutionPolicy Bypass -File $tool -Action RetryFailed
powershell.exe -ExecutionPolicy Bypass -File $tool -Action Retry -Operation app:winget:git.git
powershell.exe -ExecutionPolicy Bypass -File $tool -Action Retry -Operation app:winget:bitwarden.bitwarden -IncludePermanent
powershell.exe -ExecutionPolicy Bypass -File $tool -Action Retry -Operation stage:windowsUpdate
powershell.exe -ExecutionPolicy Bypass -File $tool -Action Resume
powershell.exe -ExecutionPolicy Bypass -File $tool -Action ExportDiagnostics [-OutputPath D:\diag.zip]
```

Run it as the user the applications belong to (the account the deployment created, `owner` by
default): WinGet only works in a user's context, so application retries are refused from SYSTEM.

| Action | What it does | What it never does |
|---|---|---|
| Status | Outcome and code, stages, every operation with lifecycle, attempts and message | change anything |
| PendingActions | Manual installs (with the official download), restarts, unconfirmed installs, permanent failures to correct, report follow-ups | change anything |
| RetryFailed | Reopens every `FailedRetryable`, `BlockedByDependency`, waiting or unfinished application, and a Windows Update stage that ended with failures | reopen permanent failures, manual entries, deselected apps or anything installed |
| Retry -Operation | Reopens the named operations; a dependency that did not install is reopened with what needs it (it installs first) | accept an id that is not in this deployment's verified plan |
| Retry -IncludePermanent | Also permanent failures, after the cause was corrected; the same checks apply again | bypass the hash, signature or policy check |
| Resume | Continues interrupted provisioning: unfinished operations, a missing application task or monitor, a stalled stage; rebuilds a damaged deployment state | relaunch a stage that has a result, a status file or a task |
| ExportDiagnostics | One ZIP with logs, states, results, the report, the manifest and configs; passwords and keys replaced by `[redacted]` | include answer files, Wi-Fi profiles, Panther logs or anything outside the data folder |

Exit codes: Status returns the outcome code (0, 10, 20, 25, 30, 31, 32, 40, 50, 60; see
[architecture.md](architecture.md#outcomes-and-exit-codes)); actions return 0 done, 1 refused or
nothing to do, 2 busy (the monitor or an engine is running; try again in a minute), 3 package
integrity failed, 4 not elevated.

## What happens during a retry

1. The tool takes the deployment mutex (it never runs at the same time as the monitor or setup).
2. It re-reads the staged manifest and verifies every staged file against its hash. A modified or
   missing file stops it (`IntegrityFailed`): stage the package again with `setup.cmd` from the
   original media; nothing is retried from a tampered copy.
3. It calls the application engine's own Retry logic under the engine's mutex (refused with
   `Busy` while the engine runs). Only operations of the verified configuration are eligible.
   Each reopened operation keeps its history and total attempts, gets a fresh budget, and the
   previous result is archived to `Applications\history\`.
4. `Install-ApplicationEngine.ps1 -Resume` registers the user task again **without** archiving
   the state, after checking that its copies match the verified package.
5. A Windows Update stage that ended with failures is relaunched through its own installer (it
   never offers an installed update again). The ongoing update policy is not applied a second time.
6. The deployment is reopened (`InProgress`, a new deadline, the old completion marker set aside,
   the monitor task registered again); the recovery is recorded in `recoveries` with who did what.
7. The monitor follows the engines as before and writes a new report at the end.

## Worked example: 20 applications

This is the scenario `documented example: 20 applications …` in
`tests/powershell/Applications.Tests.ps1`; the numbers below are from its result files.

**Automatic phase.** 20 applications are selected. 18 install at the first attempt.
`Vendor.FlakyDownload` fails with `DOWNLOAD_FAILED` (0x8A150008, class Network; the network check
says Online, so it counts) and is scheduled again after 60 s. `Vendor.MirrorDown` fails the same
way. After the 60 s wait both are attempted again: FlakyDownload installs (attempt 2),
MirrorDown fails again and waits 120 s, then fails a third time and has used its budget.

```
attempts.jsonl (excerpt)
app:winget:vendor.flakydownload  1 automatic  Failed     Network 0x8A150008  next: retry after 60 s
app:winget:vendor.flakydownload  2 automatic  Succeeded  Success 0x00000000  next: none
app:winget:vendor.mirrordown     1 automatic  Failed     Network 0x8A150008  next: retry after 60 s
app:winget:vendor.mirrordown     2 automatic  Failed     Network 0x8A150008  next: retry after 120 s
app:winget:vendor.mirrordown     3 automatic  Failed     Network 0x8A150008  next: manual retry (recovery tool)
```

The application stage ends `CompletedWithFailures`: counts succeeded 19, failed 1; `outstanding`
= `app:winget:vendor.mirrordown` (FailedRetryable). The deployment report shows outcome
`CompletedWithFailures` (code 20), lists the outstanding operation with the action "retry
(automatic retries used up)", and prints the recovery commands. Nothing is lost when the deployment
ends: the state, the history and the outstanding list stay on the computer.

**Technician.** The vendor's mirror is back. The technician opens Deployment recovery and chooses
"Retry failed operations" (`-Action RetryFailed`). Only `app:winget:vendor.mirrordown` is reopened
(the 19 installed ones are not eligible); the task runs, the engine touches only the reopened
operation (checking it with `winget list` first), and MirrorDown installs at its first new attempt. The stage ends `Succeeded`; the deployment
`Succeeded` (code 0). MirrorDown's record: status Succeeded, attempts 1 (this budget),
totalAttempts 4, manualRetries 1, and a history with the three automatic attempts, the manual
reopening (by `SHOP\Technician`) and the successful attempt. Only the two applications that failed
ever ran more than once.

## Typical cases

| Situation | What the deployment does by itself | What the technician does |
|---|---|---|
| Wi-Fi dropped for 20 minutes | waits (PausedAwaitingNetwork), continues | nothing |
| Microsoft Store unavailable for a day | WinGet apps continue; Store apps wait, at most 6 times, then FailedRetryable | `RetryFailed` when the Store works |
| Vendor CDN timed out three times | FailedRetryable after 3 attempts | `RetryFailed` |
| Hash mismatch (manifest updated, file replaced) | FailedPermanent, not retried | wait for the WinGet manifest fix, then `Retry -Operation … -IncludePermanent` |
| Power cut during an installation | after the restart `winget list` decides: installed = Succeeded, otherwise retried | nothing |
| deployment.json damaged | backup used; if both are damaged the monitor stops | `Resume` (rebuilds) |
| Nobody signed in, applications never ran | PausedAwaitingUser | sign in as the deployment user |
| Manual application (RustDesk) | ManualActionRequired, listed with the official download | install it by hand |
