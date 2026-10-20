# Implementation report: Phase 4 (USB deployment and first-boot orchestration)

Branch `feature/phase-4-usb-deployment`, created from `feature/ui-redesign` at `99ea430` (which
contains Milestone 1, Phases 2 and 3 and the UI redesign). `main` and the Cloudflare Worker are
unchanged. Design: `architecture.md`. Tests: `testing.md`. Procedures: `usb-preparation.md`,
`recovery.md`.

## Built

### Deployment package (`src/engine/deployment/`)

- `index.ts`: package layout (`packageFiles`), manifest (`buildManifest`, format
  `windows-deployment-builder/deployment-manifest` v1, package and answer-file scopes), the
  answer-file integration (`modify`), the ZIP (`buildDeploymentPackage`) with warnings (passwords in
  the answer file, wrong answer-file name, no stage enabled, unresolved/interactive packages), and the
  README, `INSTALLATION.txt` and `setup.cmd` texts.
- `zip.ts`: store-method ZIP writer and reader, CRC-32, UTF-8 names, fixed timestamps, path safety
  (no absolute paths, drive letters, `..`, backslashes, control characters or duplicates).
- `sha256.ts`: synchronous SHA-256 (checked against Node crypto).
- Built entirely in the browser; nothing new at run time; works offline.

### PowerShell (Windows PowerShell 5.1, no modules; `src/engine/deployment/scripts/`)

| Script | Role |
|---|---|
| `DeploymentCommon.ps1` | Adapters, JSON (UTF-8), logging, paths, manifest validation (format, version, safe relative paths, hash formats, known stages), raw and text hashes, `Test-WddFiles`, mutex, stage snapshots from the engines' own files, overall status. |
| `Stage-Deployment.ps1` | Verify the source (embedded: text hashes; package: exact bytes) → copy to `<dataRoot>\Package` (the previous copy is kept aside) → verify the copy. Standalone it only verifies. |
| `Initialize-Deployment.ps1` | First-sign-in entry (last FirstLogon command) and `setup.ps1` target: refusals, single instance, state, ACL, staging, one launch per stage in its context, monitor task, shortcut, progress console. |
| `DeploymentOrchestrator.ps1` | Monitor (SYSTEM, startup + 15 min): integrity check, snapshot, `status.json`, completion or deadline. Never launches an engine. |
| `Complete-Deployment.ps1` | Report (`deployment-report.json` + `.txt`), marker with overall status, event, shortcuts, removes the monitor task. `-Preview` / `-Finish` by hand. |
| `Show-DeploymentStatus.ps1` | Readable console progress (`-Watch`). |
| `Resume-Deployment.ps1` | Manual recovery: re-check, re-register, reopen; `-RestartStage`; `-Status`. |
| `setup.ps1` + `setup.cmd` | Manual entry point of the package: verify, status, or start on an installed Windows after typed confirmation. Refuses Windows PE. |

### Website

- **Deployment package** page (sidebar › Automation & Output): status from the real validation and
  package warnings, the three download options explained (complete package / answer file only /
  individual scripts), package contents with size and role, USB preparation steps and layout, how
  files reach the installed system, stage order with context and Internet needs, manual recovery
  commands.
- **Review & download**: "Download deployment package" is the primary action; "Download answer
  file" and "Copy XML" remain; next steps updated; link to the package page. Individual assets are
  unchanged under Deployment assets.
- Same components and tokens as the redesign; light and dark themes; phone layout puts the
  download first.

### Changes to existing code

- `features/windows-update` and `features/applications` `modify`: still embed exactly the same files
  in the same place, but no longer add their own FirstLogon commands (the orchestrator runs the
  same installers). Setting mapping texts updated (`docs/settings-mapping.md` regenerated).
- `engine/windows-update`: `EMBEDDED_UPDATE_FILES` constant (same list as before).
- `engine/orchestration.ts`: `orchestrationAsset()` (same bytes as before, now shared).
- `pipeline.ts`: calls `deployment.modify` after the engines.
- The engines, their installers, `orchestration.json`, the catalog, owner defaults, validation rules
  and the profile schema are **unchanged**.

## Changes to the answer file

Only when Windows Update automation is on or applications/Additional Software are selected:

1. **Added** embedded files under `C:\Windows\Setup\Scripts\Deployment\`:
   `scripts\common\DeploymentCommon.ps1`, `scripts\bootstrap\Stage-Deployment.ps1`,
   `scripts\bootstrap\Initialize-Deployment.ps1`, `scripts\orchestrator\DeploymentOrchestrator.ps1`,
   `scripts\orchestrator\Show-DeploymentStatus.ps1`, `scripts\orchestrator\Resume-Deployment.ps1`,
   `scripts\finalization\Complete-Deployment.ps1`, `config\orchestration.json` and
   `deployment-manifest.json` (answer-file scope: embedded files only).
2. **FirstLogonCommands:** the commands for `WindowsUpdate\Install-UpdateEngine.ps1` and
   `Applications\Install-ApplicationEngine.ps1` are replaced by one command,
   `Deployment\scripts\bootstrap\Initialize-Deployment.ps1`, still the last FirstLogon command.
3. Nothing else changes. With both engines off the answer file is byte-identical to Milestone 1
   (frozen fixture test). Changes that do not affect the installed computer (an empty script, the
   profile name) do not change the answer file (test).

Size: about 75 KB → 159 KB with the owner defaults (Windows Update on), about 245 KB with four
applications. Regression tests: `deployment.test.ts`, updated FirstLogon assertions in
`windows-update.test.ts`, `applications-generate.test.ts`, `generate.test.ts`, and the three updated
snapshots.

## Defects found by the tests and fixed

- `Invoke-WddStage`: a local `$paths` collided with the `[hashtable] $Paths` parameter
  (PowerShell names are case-insensitive), so staging would have thrown on a real machine.
- `Read-WddJson`: `Get-Content` reads UTF-8 without BOM as ANSI in PowerShell 5.1, which garbled
  non-ASCII application names in the report; now read explicitly as UTF-8.
- The first manifest design hashed documentation and the profile export into the package ID, so
  unrelated edits changed the answer file; the ID now covers only what runs on the computer.
- After an `IntegrityFailed`, `setup.cmd` did not re-stage; it now replaces the staged copy and keeps
  the launch records.
- Dot-sourcing a script with a `param()` block rebinds those parameters in the caller; entry points
  now capture their arguments first.

## Not tested / requires real hardware

**Nothing was installed, registered, secured or restarted on the development computer, and no
Windows installation was run.** The orchestrator was exercised against simulations and the real
generated package; the package's own verification ran read-only on real Windows. Still unverified:

- Windows Setup with the generated `autounattend.xml` from Media Creation Tool and Rufus media; the
  stop at disk selection; specialize extraction of the larger answer file.
- `Initialize-Deployment.ps1` as a FirstLogon command (elevation, the visible progress console,
  shortcut creation, ACLs on `Package`), the SYSTEM monitor task across real restarts, real engine
  installers launched as child processes, and the report on a real machine.
- Interaction with the engines' real timing (Windows Update restarts, WinGet availability at first
  sign-in) and with removing the USB drive after Setup.
- Everything already listed as unverified for Milestone 1, Phase 2 and Phase 3.

## Known limitations

- The answer file grows to 160–250 KB. Windows Setup accepts larger answer files in practice
  (upstream embeds similar scripts), but this size has not been validated on media.
- The deployment's identity is per package: a second, different package on the same computer is
  refused while the first is in progress (by design; see `recovery.md`).
- The application stage still needs a signed-in administrator; without automatic sign-in it waits
  for the next sign-in, and the deadline may end the deployment `Incomplete` first (resume reopens
  it).
- Driver stage: interface only (`NotImplemented`); PXE and network sources: not implemented, but the
  answer file and `setup.ps1 -SourceMode Package` do not depend on USB.
- `orchestration.json` still labels the driver stage with `phase: 4` from the Phase 3 contract; the
  contract was left byte-identical on purpose. Drivers are a later phase.
- Additional Software still never runs automatically (reviewed list empty).

## For the next phases

- Validate this phase in a VM, then on hardware (`testing.md`), and record `docs/validation-log.md`.
- Manufacturer drivers as the `drivers` stage: launcher, inventory, vendor packages (AMD, NVIDIA,
  Intel, OEM), restarts under `install.lock`, results read by the existing monitor.
- PXE/netboot/WinPE share/server delivery: serve the same answer file or `WindowsDeployment` folder.
