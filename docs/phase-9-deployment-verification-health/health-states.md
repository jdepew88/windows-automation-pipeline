# Health state model

## Findings

Every check produces one finding with a stable id (`app.winget:git.git`, `windows.edition`,
`restore.settings.vscode`, `drivers.device.<hash of hardware id and name>`, `updates.kb.KB5068861`).
The ids are the same on every run of the same deployment, so a re-check can say what was resolved.

| Field | Meaning |
|---|---|
| `category` | one of the 11 categories below |
| `severity` | Informational, Warning, Error, Critical: how bad it is if the check does not pass |
| `status` | Pass, Info, Warning, Fail, Pending, Unverifiable, Deferred, NotApplicable |
| `required` | whether the objective is needed for delivery |
| `expected`, `observed` | the expectation and what Windows showed |
| `method`, `evidence` | how it was checked; which result file it compared with |
| `timestampUtc` | when it was checked |
| `nextAction` | what a person should do |
| `automaticRecovery` | true when it resolves by itself (a running stage, a pending restart) |
| `technicianRequired` | true when a person has to act |
| `recoveryAction` | the recovery-tool action that addresses it: RetryFailed, Retry -IncludePermanent, Resume, RestoreSettings or AddDrivers |

Severity is fixed per check, never lowered because a stage ended "successfully". A wrong edition, no
active antivirus, the firewall off for every profile and a modified package are **Critical**.

## From finding to category

| Finding | Counts as |
|---|---|
| Fail + Critical | Failed |
| Fail + Error | NeedsAttention |
| Fail + Warning (optional objective) | Warning |
| Warning | Warning |
| Pending | Incomplete |
| Unverifiable or Deferred, required | Unverifiable |
| Unverifiable or Deferred, optional | Warning |
| Pass, Info | Verified |
| NotApplicable | not counted |

A category takes its worst finding, in the order Verified < Warning < NeedsAttention < Incomplete <
Unverifiable < Failed. A category with no counted finding is **NotApplicable**, never green: a skipped
or absent check is not shown as verified.

## Overall state (first match wins)

| State | Rule | Exit code | Event |
|---|---|---|---|
| **Failed** | any Critical finding failed | 60 | 5005 |
| **Unverifiable** | required evidence is missing, damaged, inconsistent or inaccessible (including deferred per-user checks) | 50 | 5004 |
| **Incomplete** | something is still running or waiting (restart, network, the deployment user, a stage) | 30 | 5003 |
| **NeedsAttention** | a required objective is not met | 20 | 5002 |
| **ReadyWithWarnings** | every required objective verified; optional failures, manual follow-ups or advisories remain | 10 | 5001 |
| **Ready** | every required objective verified and nothing outstanding | 0 | 5000 |

**Precedence:** Incomplete comes before NeedsAttention. While work is still running, an
application that is not installed yet may still be installed by the stage itself. Findings that need
a person are listed either way.

**Readiness for delivery:** a computer is ready only in Ready or ReadyWithWarnings. Never with:

- a required application missing;
- a malfunctioning display, network or storage device;
- the initial Windows Update unfinished;
- a restart pending;
- a failed account check;
- a failed critical security check;
- an incomplete required settings restoration;
- a damaged deployment state.

`Get-WdhOverall` implements this table; each rule has a scenario in `Health.Tests.ps1`.

## Phase 5 outcomes as evidence

The Phase 5 outcome (`Get-WddDeploymentOutcome`) is not redefined. It becomes the finding
`deployment.outcome`:

| Phase 5 outcome (code) | Finding | Why |
|---|---|---|
| Succeeded (0) | Pass | the per-item checks decide the rest |
| CompletedWithWarnings (10), CompletedWithFailures (20) | Info | the per-item checks decide (an application can be present although its attempt failed, and the reverse) |
| Incomplete (25) | Fail, Error | the deployment ended before every stage finished: Resume |
| PausedAwaitingNetwork (30), PausedAwaitingReboot (31), PausedAwaitingUser (32) | Pending | it continues by itself (or when the user signs in) |
| InProgress (40) | Pending | running |
| FailedToInitialize (50), Failed (60) | Fail, Critical | a stage or the initialization failed |

TypeScript has the same table (`PHASE5_OUTCOME_MAP`). A test compares it with the engine's source.

## Application results

| Result | When |
|---|---|
| InstalledVerified, AlreadyInstalledVerified | Windows lists it (and the engine agrees) |
| InstalledVersionDiffers | listed, with another version than a pinned one |
| InstalledVerificationUncertain | the engine reported success but no record matched; or present although the engine reported a failure |
| Missing | not installed and the engine has no record of it |
| Failed | not installed, the installation failed (failure class, attempts, retryable) |
| ManualInstallationRequired | manual catalog entries and manual Additional Software, not found |
| InstalledManually | a manual entry that is now installed |
| SkippedByUser | deselected |
| BlockedByDependency | a dependency failed |
| WaitingForReboot, Pending | still being installed, or waiting for a restart (1.2.0: also `verify.after` = restart while a restart is pending) |
| WaitingForUserContext | per-user evidence cannot be read now: the deployment user is signed out, has no profile yet, or the check runs as SYSTEM (Deferred) |
| WaitingForSignIn | 1.2.0: `verify.after` = signIn and no evidence yet (Pending) |
| PackageUnavailable | 1.2.0: engine status Unavailable or outcome PackageUnavailable (Fail) |
| UnattendedUnsupported | 1.2.0: engine outcome UnattendedUnsupported (Warning, manual action) |

From health engine 1.2.0, every result also carries the evidence found now (`evidence`), and the
engine's record (`outcome`, `engineVerification`, `engineEvidence`) as history. See
[post-deployment-audit.md](post-deployment-audit.md#applications-health-engine-120-package-aware-verification).

## Evidence quality

Each evidence file is recorded in `sources[]`:

| State | Meaning | Effect |
|---|---|---|
| `ok` | read and usable | — |
| `missing` | not there | — |
| `corrupt` | not valid JSON of the expected format | its checks become Unverifiable |
| `stale` | older than the engine's live state (the stage was reopened) | the live state is used |
| `inconsistent` | another deployment's id, or a non-final report for a finished stage | its checks become Unverifiable |
