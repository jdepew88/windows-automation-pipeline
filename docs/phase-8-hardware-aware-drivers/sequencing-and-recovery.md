# Installation sequencing, verification, restarts and recovery

## Sequence (adapted to the existing orchestrator)

| # | Step | Who |
|---|---|---|
| 1 | Windows Setup; Setup-critical drivers from `$WinPEDriver$` | Windows Setup |
| 2 | first sign-in: package staged, stages launched once (Windows Update, applications, drivers) | `Initialize-Deployment.ps1` |
| 3 | Inspection A; offline bundle staged; network bootstrap if needed | driver engine (phase `New`) |
| 4 | initial Windows Update, restarts | Windows Update engine |
| 5 | restart if one is still pending, then Inspection B | driver engine (`WaitingForUpdates` → `Inspecting`) |
| 6 | resolution of what is still missing (network adapters first) | driver engine (`Resolving`) |
| 7 | restart when drivers need it; verification of every device | driver engine (`Verifying`) |
| 8 | drivers.json, result.json; task removed | driver engine (`Finished`) |
| 9 | applications, then Phase 6 settings restore | application engine (waits for 4 and 8) |
| 10 | deployment report, recovery data for Phase 9 | orchestrator |

Every phase transition is saved (`state.json`, atomic with a last good copy); each start continues
where the last one stopped. A pass that leaves retryable work returns and is continued by the next
task trigger (at most 3 passes); the runtime limit is `waitForUpdatesHours + 6`.

## Operation lifecycle (Phase 5 names)

One operation per device that needs something: id `driver:<device key>` (stable: a hash of the
instance id). Status: `Pending, Running, AlreadySatisfied, Succeeded, WaitingForNetwork,
WaitingForReboot, ManualActionRequired, FailedRetryable, FailedPermanent, Unsupported`. Every attempt
is counted and saved before it acts, and appended to `logs\attempts.jsonl` (ids, codes, messages only).

| Failure class | Meaning | Retried |
|---|---|---|
| `Network` | download failed | automatically (bounded), technician |
| `InstallFailed` | pnputil failed, device unchanged | once more automatically (2 attempts), then `Permanent` |
| `Integrity` | downloaded file or staged package does not match its hash | **never** (security failure), not even by a technician without a new package |
| `Signature` | Windows refused the package's signature, or it is not Microsoft-signed | **never** (security failure) |
| `Incompatible` | refused by the candidate filter after download | technician only |
| `Policy` | organization device-installation restrictions | technician only |
| `DeviceFailure` | the device has a new problem after the installation | **no further automatic attempt for that device** |
| `NoEffect` | the same problem remains | technician only |
| `NotSelected` | Windows kept its existing driver (ranked higher) | technician only |
| `Manual` | nothing safe to install | — |

Offline waiting for a download does not use attempts (at most 6 deferrals, then a manual action).

## Verification (`Get-WdvVerification`): the device, not the exit code

After `pnputil` the device is read again (`Win32_PnPEntity` + `Win32_PnPSignedDriver`):

- problem 0 and the package's provider + version → **Succeeded / Verified**;
- problem 14 or pnputil 3010 → **WaitingForReboot**; verified only after the computer has restarted
  (boot time later than the attempt);
- a missing driver now working with another driver Windows chose → Succeeded / VerifiedOtherDriver;
- unchanged (exit 0) → **ManualActionRequired / NotSelected**: the package stays in the driver store;
- the same problem → **FailedPermanent / NoEffect**; a new or different problem → **FailedPermanent /
  DeviceFailure**, the device is blocked from further automatic attempts, event 4110.

An interrupted installation (`Running` after a crash or power loss) is reconciled from the device: if it
works with the package it is Succeeded without installing again; if nothing changed it is tried again
(the attempt was already counted); it is never assumed to have failed.

## Restarts

Through the shared coordination: install lock, `state\restart-pending.json`, `shutdown /r /t <warning>`,
at most `drivers.maxReboots` (default 2); beyond that the device is reported as needing a restart. A
restart scheduled by another engine is waited for, not duplicated.

## Rollback and recovery

Before an installation the previous driver (provider, version, date, INF) is recorded. Nothing is ever
removed: the previous package stays in the driver store. If a device fails after an installation, the
report and the recovery tool give: what was there before, "Device Manager > the device > Properties >
Driver > Roll Back Driver" (where Windows kept it), and for storage controllers "do not remove its
driver". Universal rollback is not promised: some drivers and vendor installers do not support it.

Recovery tool (`DeploymentRecovery.ps1`): `Status` lists driver operations; `PendingActions` lists their
manual actions and the missing network driver; `RetryFailed` / `Retry -Operation driver:<key>
[-IncludePermanent]` reopen through the engine's own rules and register the task again
(`Install-DriverEngine.ps1 -Resume`); `Resume` re-registers a lost task; `AddDrivers -DriverPath`;
`ExportDiagnostics` includes the driver state, inventories, logs and drivers.json. Successful operations
are never repeated; an unresolved driver never touches application progress.
