# Architecture: USB deployment and first-boot orchestration (Phase 4)

Branch `feature/phase-4-usb-deployment`, based on `feature/ui-redesign` (`99ea430`).
Related: `implementation-report.md`, `testing.md`, `usb-preparation.md`, `recovery.md`.

## Audit: what already existed and what was missing

| Piece | Before Phase 4 | Phase 4 |
|---|---|---|
| Answer file generator | Complete (M1). Embeds files in `<Extensions><File>`; the first specialize command extracts them from `C:\Windows\Panther\unattend.xml` to `C:\Windows\Setup\Scripts`. | Reused unchanged. It is the carrier for the whole deployment. |
| Windows Update engine | Complete (Phase 2, 1.1.0). `Install-UpdateEngine.ps1` ran as a FirstLogon command and registered the SYSTEM task. | Unchanged. Its installer is now run once by the orchestrator. |
| WinGet bootstrap and application engine | Complete (Phase 3). `Install-ApplicationEngine.ps1` ran as the last FirstLogon command and registered the per-user task. | Unchanged. Its installer is now run once by the orchestrator, as the user. |
| Coordination | `install.lock`, `restart-pending.json`, the `updatesFirst` gate, result files and markers. | Unchanged; the orchestrator reads them. |
| `orchestration.json`, driver contract | Contracts only. | Unchanged; included in the package. |
| Individual asset downloads | Review & download. | Unchanged. |
| ZIP, `setup.ps1`, manifest, hashes | Missing. | Added. |
| A process that follows all stages, survives restarts, reports one result and cleans up | Missing (each engine reported separately). | Added: monitor task, state, status, report. |
| Manual recovery | Each engine's installer (restarts that stage). | `Resume-Deployment.ps1`, `Show-DeploymentStatus.ps1`, `setup.cmd`. |
| UI for the package | Missing. | "Deployment package" page and a primary button on Review. |

## How the files reach the installed computer

**Decision: the answer file remains the only carrier.** The orchestrator scripts and a runtime
manifest are embedded next to the engines. The `WindowsDeployment\` folder in the ZIP holds the same
files for verification, manual runs and recovery; the installation does not read it.

```
USB root\autounattend.xml ──(Windows Setup, implicit search of removable media)──► C:\Windows\Panther\unattend.xml
specialize (SYSTEM)  ExtractScript writes every embedded file:
                       C:\Windows\Setup\Scripts\WindowsUpdate\   engine, installer, config.json        (Phase 2)
                       C:\Windows\Setup\Scripts\Applications\    engine, bootstrap, installer, JSON    (Phase 3)
                       C:\Windows\Setup\Scripts\Deployment\      orchestrator scripts, config\orchestration.json,
                                                                 deployment-manifest.json (runtime scope)   (Phase 4)
FirstLogon           1. FirstLogon.ps1 (M1 steps; deletes the Panther copy unless "keep sensitive files")
                     2. Deployment\scripts\bootstrap\Initialize-Deployment.ps1   ◄── replaces the two installer commands
```

Why this method:

| Method | Assessment |
|---|---|
| **Embedded in the answer file** (chosen) | Already used and tested upstream and by Milestone 1. Setup copies the answer file to the Windows volume itself, so no drive letter, USB detection or timing is involved, the USB drive can be removed after Setup, and the same file works from PXE/WDS or a network share later. Costs answer-file size (about 160 KB with Windows Update on, 245 KB with applications). |
| `$OEM$` folders | Needs `UseConfigurationSet` (a setup option this generator already exposes but keeps off) and a specific media layout (`sources\$OEM$`); Rufus and the Media Creation Tool layouts differ; not used. |
| `SetupComplete.cmd` | Runs as SYSTEM before the first sign-in, but Microsoft's "Add a custom script to Windows Setup" documentation lists cases where it is skipped (OEM product keys), it must be placed in the image or via `$OEM$`, and it cannot start the per-user WinGet stage. Not used. (Not re-verified against the current documentation in this phase.) |
| Copy from USB in windowsPE/specialize | Needs finding the USB drive (letters differ between WinPE and the installed system, more than one removable drive may be attached). Rejected as timing- and hardware-dependent. |
| Scheduled tasks created during specialize | Possible, but the user-context stage must be registered by the user anyway; FirstLogon is the documented first point where that user exists. |

Disk safety is unchanged and enforced by `checkStructure`: no `DiskConfiguration`, `ImageInstall`
target or `WillWipeDisk`, so Setup always stops at disk selection. Nothing in Phase 4 references a
disk, a partition or a drive letter of removable media.

## Package layout

```
autounattend.xml                       (USB root)
WindowsDeployment\
  README.txt
  deployment-manifest.json             format windows-deployment-builder/deployment-manifest v1, scope "package"
  setup.cmd                            manual entry point (administrator) → setup.ps1
  setup.ps1                            verify (-Verify), status (-Status), or start the deployment on an installed Windows
  scripts\common\DeploymentCommon.ps1  shared functions (manifest, hashes, state, snapshot)
  scripts\bootstrap\Stage-Deployment.ps1       verify + copy to the protected package folder
  scripts\bootstrap\Initialize-Deployment.ps1  first-sign-in entry: stage, launch each stage once, register the monitor
  scripts\orchestrator\DeploymentOrchestrator.ps1  monitor (SYSTEM task)
  scripts\orchestrator\Show-DeploymentStatus.ps1   progress console (read-only)
  scripts\orchestrator\Resume-Deployment.ps1       manual recovery
  scripts\finalization\Complete-Deployment.ps1     report, marker, cleanup
  scripts\windows-update\  WindowsUpdateEngine.ps1, Install-UpdateEngine.ps1, config.json, README-WindowsUpdate.txt
  scripts\applications\    ApplicationEngine.ps1, WinGetBootstrap.ps1, Install-ApplicationEngine.ps1,
                           applications-config.json, winget-packages.json, applications-plan.txt,
                           applications-results.schema.json, README-Applications.txt   (only with applications)
  profiles\windows-settings.json   this configuration (no passwords); re-import in the website
  profiles\applications.json       the effective application selection (only with applications)
  config\orchestration.json        Phase 3 contract, unchanged
  docs\INSTALLATION.txt
```

Existing engine files keep their names; each engine folder keeps the files its installer expects
next to it (`config.json`, `applications-config.json`, `winget-packages.json`), so the installers
run unchanged from the package. `.ps1` files in the ZIP carry a UTF-8 BOM so Windows PowerShell 5.1
reads them as UTF-8; all text is CRLF. The ZIP is built in the browser (store method, CRC-32, fixed
timestamps, so it is reproducible) by `src/engine/deployment/zip.ts`; there is no server.

## Manifest and integrity

`deployment-manifest.json` (built by `buildManifest`, `src/engine/deployment/index.ts`):

- `packageId`: first 16 hex digits of SHA-256 over the embedded files (path + text hash). It
  identifies what runs on the computer, so README or profile-export changes cannot change the
  answer file.
- `windows` (edition, generated computer name, architectures, `diskSelection: interactive`),
  `stages` (id, order, context, launcher, task, result/status/marker paths relative to the data
  root, final statuses, `requiresInternet`), `applications` (selected profiles, effective packages
  after composition and de-duplication, unresolved/interaction flags, removals),
  `restartPolicy`, `failureHandling` (engine limits plus orchestrator `launchAttempts`,
  `stalledAfterMinutes`, `deadlineHours`), `drivers` (`implemented: false`), `customScripts`
  (counts; they run from the answer file), `paths`, `files`.
- `files[]`: `path`, `role`, `size`, `sha256` of the exact ZIP bytes, `textSha256` (see below) and
  `embedded` (path under `C:\Windows\Setup\Scripts` when the file is also in the answer file).
- No user name, person name, password or token. The JSON is ASCII-only (non-ASCII is escaped), so
  the code page used by the extraction cannot alter it.
- The answer file embeds the same manifest with `scope: "answerFile"` and only the embedded files.

Two hashes, because the extraction script does not write files byte-for-byte: the XML parser turns
CRLF into LF, the script trims the text, writes `.ps1`/`.xml` as UTF-8 with BOM and other files in
the system code page. `textSha256` hashes the normalised text (LF, trimmed, UTF-8) and is given
whenever that is exact (ASCII text, or `.ps1`/`.xml`). A JSON file with non-ASCII text in the system
code page is checked structurally (must parse). `Deployment.Tests.ps1` runs the generator's real
`ExtractScript` against the generated answer file and verifies every hash.

Checks: `setup.ps1` (exact bytes, before anything runs), `Stage-Deployment.ps1` (source, then the
copy), the monitor on every run (staged copy), `Resume-Deployment.ps1` (staged copy). A mismatch
stops that step; nothing is executed from a package that fails.

## Runtime layout on the installed computer

`C:\ProgramData\WindowsDeploymentBuilder` (SYSTEM and Administrators full control, Users read and
execute, inheritance removed; the same rule the engine installers apply):

```
Package\            verified copy of the deployment (immutable for standard users); the monitor runs from here
Deployment\         status.json, logs\deployment.log
state\              deployment.json (orchestrator state), deployment.done (marker with overall status),
                    install.lock, restart-pending.json, windows-update.done, applications.done (Phases 2–3)
reports\            deployment-report.json, deployment-report.txt
Updates\            Windows Update engine (Phase 2)
Applications\       application engine (Phase 3)
```

## First boot

```
FirstLogon (signed-in user, elevated)
  Initialize-Deployment.ps1
    refuse: Windows PE, not elevated, another run (mutex Global\WindowsDeploymentBuilder-Deployment)
    state: finished → stop; other package in progress → refuse; same package → continue (no relaunch)
    secure data root → Stage-Deployment (verify source → copy → verify copy) → fail = StagingFailed, nothing launched
    for each enabled stage in order, once (recorded before it starts, max 2 attempts):
        windowsUpdate  powershell -File Package\scripts\windows-update\Install-UpdateEngine.ps1      → SYSTEM task
        applications   powershell -File Package\scripts\applications\Install-ApplicationEngine.ps1  → task for this user
                       (refused when running as SYSTEM: WinGet is not supported there)
    register \WindowsDeploymentBuilder\Deployment (SYSTEM; at startup +3 min, every 15 min)
    "Deployment progress" shortcut on the public desktop; progress console for the user
Monitor (SYSTEM, short runs)
    mutex → verify Package → snapshot every stage from its own files → status.json
    all enabled stages final, or deadline passed → Complete-Deployment.ps1
Complete-Deployment.ps1
    report (json + txt), state\deployment.done {status}, event 3100–3104,
    "Deployment report" shortcut, remove "Deployment progress", unregister the monitor task.
    State, logs and engine results are kept.
```

Stage contexts are preserved exactly as in Phases 2 and 3: the Windows Update engine runs as SYSTEM;
the WinGet engine runs as the signed-in user with highest privileges, never as SYSTEM.

### Windows Update and WinGet coordination

Unchanged from Phase 3 (`docs/phase-3/orchestration.md`): the application engine prepares (network,
WinGet check, `winget show`) while Windows Update works, installs only after the Windows Update
stage is final (or not part of the deployment, or `waitForUpdatesHours` passed), and every
installation and restart holds `install.lock`. The orchestrator does not add a second gate; it
reports.

### Stage states and the overall result

Per stage (`Get-WddStageSnapshot`): `Final` only when that engine's `result.json` has a final
status. Markers are never trusted alone. Otherwise `Running` (engine checked in), `Pending`
(launched, task exists), `Stalled` (no task, no result after `stalledAfterMinutes`), `LaunchFailed`
or `NotStarted`.

| Overall | When |
|---|---|
| Succeeded | every enabled stage `Succeeded` |
| CompletedWithFollowUp | worst stage `CompletedWithFollowUp` (interaction, sign-in, restart) |
| CompletedWithFailures | worst stage `CompletedWithFailures` (failed updates, failed/unavailable packages) |
| Incomplete | a stage ended `Offline`, is stalled, or the deadline passed first |
| Failed | a stage `Failed`, or staging/integrity failed before anything ran |

The deadline is `Windows Update maxRuntimeHours + applications (waitForUpdatesHours +
maxRuntimeHours) + 24 h` from initialization. The engines keep their own limits (restarts,
attempts, runtime), unchanged.

### Restarts and recovery

- All state is on the Windows volume and written atomically before each action. Every launch is
  recorded before the installer runs, so a crash cannot launch a stage twice; an interrupted
  launch whose task exists is recognised as done.
- The monitor never launches or re-launches an engine, so it cannot cause a loop. A stage whose
  task vanished without a result becomes `Stalled` and is shown as needing attention; the
  deadline ends the deployment as `Incomplete` with a recovery command in the report.
- Engine restarts and resumption are the engines' own (Phases 2 and 3): restart limits, the
  install lock around restarts, resume from state after boot. The monitor's startup trigger picks
  the deployment up after every restart.
- Manual recovery: `recovery.md`.

## Future: drivers and other media

- **Drivers:** stage 3 (`drivers`) is in the manifest, `orchestration.json` and every status and
  report as `NotImplemented`; nothing installs or changes drivers, and the report lists manual
  driver installation as a remaining task. A later phase adds a launcher for this stage
  (inventory by hardware ID, vendor packages for AMD, NVIDIA and Intel and OEM utilities, mixed
  hardware) under the same install lock, using the existing `drivers/contract.ts`.
- **PXE, netboot.xyz, WinPE network shares, a deployment server:** the orchestration needs only the
  answer file (which carries everything) or a `WindowsDeployment` folder reachable from the
  installed system (`setup.ps1 -SourceMode Package`). Media acquisition and staging are separate
  from the post-installation logic; nothing in the orchestrator knows about USB.
