# Orchestration and coordination (Phase 3)

How the Windows Update engine (Phase 2), the application engine (Phase 3), Additional Software and
the future driver stage (Phase 4) run after Windows setup without getting in each other's way.
The machine-readable version is the `orchestration.json` deployment asset (`src/engine/orchestration.ts`).

## Stages

| # | Stage | Runs as | Task | Waits for | Result | Marker |
|---|---|---|---|---|---|---|
| 1 | Windows Update (Phase 2) | SYSTEM | `\WindowsDeploymentBuilder\WindowsUpdate` (startup + hourly) | n/a | `…\Updates\result.json` | `…\state\windows-update.done` |
| 2 | Applications + Additional Software (Phase 3) | Signed-in user, elevated | `\WindowsDeploymentBuilder\Applications` (sign-in + hourly) | Stage 1 final (policy `updatesFirst`) | `…\Applications\result.json` | `…\state\applications.done` |
| 3 | Manufacturer drivers (Phase 4, **not implemented**) | SYSTEM | n/a | Stage 1 final | `…\Drivers\result.json` | `…\state\drivers.done` |

`…` = `C:\ProgramData\WindowsDeploymentBuilder` (SYSTEM and Administrators full control, Users read).

FirstLogon order: `FirstLogon.ps1` (Milestone 1), then `Install-UpdateEngine.ps1`, then
`Install-ApplicationEngine.ps1`. The application installer is generated only when applications or
Additional Software entries are selected.

### Why the application stage runs as the user

WinGet ships in **App Installer**, a per-user packaged app. Microsoft documents that it becomes
available after the user's first sign-in (asynchronous registration) and supports it in user
context. Running `winget.exe` as SYSTEM means resolving a versioned path under `WindowsApps` by
hand, which is the fragile path assumption the requirements rule out. So:

- The task is registered for the account that runs FirstLogon. It uses `LogonType Interactive`,
  so it runs only while that user is signed in and **no password is stored**, and
  `RunLevel Highest`, so machine-wide installers get administrator rights without a UAC prompt.
- With the owner default (persistent automatic sign-in) it resumes by itself after every restart.
  Without automatic sign-in it continues at the next sign-in (validation warns about this).
- A standard-user account is rejected by validation. The engine and the bootstrap both refuse to
  run as SYSTEM.

## Coordination policy `updatesFirst` (the only Phase 3 policy)

```
time ─────────────────────────────────────────────────────────────────────────────►
Windows Update   [scan][download+install 🔒][restart 🔒]…[scan][install 🔒]──final──┐
Applications        [network][WinGet check][winget show ×N]  … waiting …            └─[repair 🔒][install pkg 🔒][pkg 🔒]…[restart 🔒]──final
                    └──────── preparation, allowed in parallel ───────┘
🔒 = holds install.lock
```

1. **Parallel preparation (allowed):** network check, the read-only WinGet check, and package
   availability (`winget show`; missing packages become `Unavailable` straight away). This is done
   once.
2. **Gate:** the application stage starts installing only when the Windows Update stage is
   **final**: `Updates\state.json` has `final`, or `result.json` exists, with any final status
   including `Failed` or `Offline`. It also proceeds when:
   - Windows Update automation is not part of the deployment;
   - after 30 minutes neither its task nor its state exists, so its installer never ran (logged as
     a warning);
   - `waitForUpdatesHours` (default 8) have passed, logged as a warning.

   While waiting, each run polls once a minute for up to 50 minutes, then exits `WaitingForUpdates`.
   The hourly trigger or the next sign-in continues.
3. **Install lock:** `…\state\install.lock`, a file opened exclusively. Windows releases it when the
   owning process ends, so a crash can never leave a stale lock.
   - **Windows Update** takes it for every download and install batch, and before scheduling a
     restart.
   - **Applications** take it for every package installation, WinGet repair, reviewed Additional
     Software installer and restart.

   Whoever cannot get it within `lockWaitMinutes` (60) saves its state and exits with
   `WaitingForLock` or `RebootDeferred`. Neither is final, and nothing is counted as an attempt.
4. **Restarts:**
   - Before scheduling one, an engine takes the lock and writes `…\state\restart-pending.json`
     (owner, reason, boot time).
   - It keeps the lock through the warning period, so nothing can start installing before Windows
     goes down.
   - The marker is valid only in the boot it was written in, and for at most 30 minutes, so it
     clears itself with the restart.
   - The application engine checks for the marker before every package and stops with
     `WaitingForRestart`. It also checks Windows' own pending-restart flags before it starts:
     - if the policy allows, it restarts once first;
     - if the flag survives that restart, it continues instead of looping.
5. **State is preserved:** both engines write their state atomically before acting, count every
   attempt before starting it, and resume after restarts or crashes.
   - An interrupted package is checked with `winget list` on the next start: confirmed as
     installed, or retried within its attempt limit.
   - Every package ends in a terminal status, or stays `Pending` in a run that ended `Failed` or
     `Offline` (rerun the installer to resume). Nothing disappears silently.

Future policies (for example interleaving updates and applications) can be added to the
`coordination` enum. They must keep using the same lock and restart marker, so they cannot
introduce unsafe parallel installation.

### Change to the Phase 2 engine (1.0.0 → 1.1.0)

| Area | Change |
|---|---|
| Installing updates | Only while holding `install.lock`. Otherwise the run exits `WaitingForLock` before any attempt is counted. |
| Restarting | Only while holding the lock. Writes `restart-pending.json` and keeps the lock through the warning. If the lock is busy, exits `RebootDeferred` (restart not counted) and tries again at the next start. |
| Config | New `lockWaitMinutes` (default 60; older configs get the default) |
| Final statuses, marker, events, limits | **Unchanged** |

Tested: the 22 original scenarios unchanged, plus 3 coordination scenarios (`Engine.Tests.ps1`).

## Application engine

`ApplicationEngine.ps1` (Windows PowerShell 5.1, no modules). It reads `applications-config.json`
(order, metadata, policy) and the native `winget-packages.json` (the package specification).
Packages that appear only in the native list, such as a hand-placed WinGet export, are installed
too.

Per package, while holding the lock:

1. Run `winget list --id <id> --exact --source <src>`. If the package is installed it is marked
   `AlreadyInstalled` and left unchanged; after an interruption or restart it is confirmed as
   `Succeeded`.
2. Count the attempt and record `Installing`.
3. Run `winget install --id <id> --exact --source <src> [--version v] [--scope s] --silent --no-upgrade --accept-package-agreements --accept-source-agreements --disable-interactivity`.
   Every token must match a strict pattern. The command line is built only from validated tokens
   and never passes through a shell or `Invoke-Expression`.
4. Map the exit code to a result, using `$script:ExitCodes`, which mirrors
   `WINGET_EXIT_CODES` in `results.ts`; a test enforces that the two match:

| Result | WinGet HRESULTs | Retried |
|---|---|---|
| Succeeded | `0x00000000` | n/a |
| AlreadyInstalled | `0x8A150061`, `0x8A15010D`, `0x8A15002B`, `0x8A15010E` | n/a |
| RequiresRestart | `0x8A150109` (to finish, verified after restart), `0x8A15010A` (before install, restart then retry), `0x8A15010B`/1641 (installer restarted), 3010 | after the restart |
| Unavailable | `0x8A150014`, `0x8A150113` | no |
| RequiresInteraction | `0x8A15010C` | no |
| Failed, not retried | hash mismatch `0x8A150011`, policy blocks, agreements, disk full, multiple matches | no |
| Failed, retried | network, download, in use, install in progress, dependencies, memory, timeout, unknown codes | until `maxAttemptsPerPackage` |

Packages the catalog marks `interaction: required` are not attempted; they become
`RequiresInteraction`. A dependency (catalog `requires`, for example Docker Desktop after WSL) that
did not install makes the dependent package `Skipped`.

### Results

`…\Applications\result.json` (schema: `applications-results.schema.json`, also validated in tests)
lists every package with name, identifier, source, status, attempts, exit code, message and
timestamp, plus counts, the WinGet bootstrap outcome and a follow-up list (also written to
`follow-up.txt`).

| Final status | Meaning | Marker | Event |
|---|---|---|---|
| Succeeded | Every package Succeeded/AlreadyInstalled/Skipped by design | yes | 2100 |
| CompletedWithFollowUp | Nothing failed, but some need interaction or a restart | yes | 2104 |
| CompletedWithFailures | Some packages Failed or Unavailable | yes | 2101 |
| Failed | WinGet could not be initialised, SYSTEM context, runtime limit, repeated errors | no | 2102 |
| Offline | No network within `waitForUpdatesHours + maxRuntimeHours` | no | 2103 |

The orchestrator can tell full success from partial failure from the marker's `status` field, or
from `result.json`.

## WinGet bootstrap

`WinGetBootstrap.ps1`. The engine runs it as a read-only check during preparation, and with repair
(under the lock) only if needed.

1. Context: SYSTEM is `Unsupported`, as is a build older than 17763.
2. Probe: `winget.exe` resolved via the user's PATH (the App Execution Alias), `winget --version`
   ≥ 1.6.0, and `winget source list` shows the `winget` source. A healthy WinGet is never repaired.
3. `Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe`
   (Microsoft's documented step), then up to 60 s of re-probing.
4. Offline: `*DesktopAppInstaller*.msixbundle` plus `.appx`/`.msix` dependencies from the
   `offline` folder. Every file needs a valid Authenticode signature from Microsoft Corporation,
   otherwise nothing is installed.
5. Online (only if `onlineRepair` is on; off by default): `Microsoft.WinGet.Client` from the
   PowerShell Gallery, then `Repair-WinGetPackageManager` (Microsoft's documented procedure).
6. Otherwise `Failed`, with every step in the log. The stage ends `Failed`, packages stay `Pending`
   and no marker is written.

## Additional Software

Entries record the official download URL, installer type, supplied file name, expected SHA-256,
publisher, documented silent arguments, prerequisites, interaction, manual-supply flag, licence and
redistribution restrictions.

- **Nothing is downloaded**, and no URL is ever fetched by the builder or the engine.
- **Manual (always, for user-entered entries):** reported as `RequiresInteraction` with the source
  and checksum in `follow-up.txt`.
- **Automatic:** only for an exact match on `REVIEWED_INSTALLERS` (name, SHA-256, type and
  arguments). That list is **empty** in this release. The installer must also be supplied in
  `…\Applications\installers`, its SHA-256 must match, and EXE/MSI files need a valid signature. It
  then runs with an argument list (MSI through `msiexec /i`), never through a shell.
- Validation rejects non-https URLs, URLs with credentials or token-like query parameters,
  malformed checksums, path-like file names, shell metacharacters in arguments, and automatic
  execution for unreviewed entries.

This stage runs after the WinGet queue, in the same engine and under the same lock.

## Phase 4 hand-off: manufacturer drivers (interface only)

Defined in `src/engine/drivers/contract.ts` and listed as stage 3 (`implemented: false`) in
`orchestration.json`. Phase 3 installs no drivers and generates no driver script.

- **Waits for** the Windows Update stage to be final and runs as SYSTEM. Driver packages need no
  user session.
- **Inventory first** (`Drivers\inventory.json`, `DriverInventory`): per device the instance ID,
  hardware IDs, compatible IDs, class, problem code, and current driver provider, version, date,
  INF, signer and origin (inbox, Windows Update, vendor); also system manufacturer, model,
  baseboard and BIOS.
- **Plan** (`Drivers\plan.json`, `DriverCandidate`): per device the candidate vendor package (from
  the official URL only, with SHA-256 and signer), the hardware ID it matched, and a decision
  (`keep`, `install`, `skip` or `manual`) **with the reason**.
- **Selection rules** the implementation must follow:
  - match on hardware and compatible IDs, never on device names;
  - a newer vendor package is not automatically better: replace a driver only when the vendor's
    support policy recommends that package for this device, or the device has a problem;
  - never silently downgrade what Windows Update installed.
- **Result** (`Drivers\result.json`): device statuses `Current`, `Updated`, `RequiresRestart`,
  `Skipped`, `RequiresInteraction`, `Failed` or `NotApplicable`; the same final statuses as the
  application stage; marker `state\drivers.done`. After installing it validates device status (no
  new problem codes) and restarts under the same install lock.
- The intended sequence: install Windows; Windows Update final; inventory; candidates; install
  verified packages; restart if required; validate devices.
