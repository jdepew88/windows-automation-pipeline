# Phase 8 audit: the deployment before hardware-aware drivers

Verified on `feature/phase-7-usb-media-preparation` at `555517d` (local = GitHub, clean tree);
`feature/phase-8-hardware-aware-drivers` was created from it. Written before any Phase 8 change.

## What exists

| Area | Where | Relevant to drivers |
|---|---|---|
| Carrier | `autounattend.xml` embeds every script (`Extensions/File`), extracted during specialize to `C:\Windows\Setup\Scripts\<Engine>\` | a driver engine must be embedded the same way; driver *packages* (binary, large) cannot be |
| Staging | `Initialize-Deployment.ps1` (last FirstLogon command) verifies the embedded files against the runtime manifest and copies them to `C:\ProgramData\WindowsDeploymentBuilder\Package`; then runs each enabled engine stage's installer once | a `drivers` stage plugs in through `Get-WddEngineStages` |
| Monitor | `DeploymentOrchestrator.ps1` (SYSTEM task, startup + 15 min): integrity check, `status.json` from each engine's own `status.json`/`result.json`, finalization when all stages are final. It never launches an engine itself | the driver stage needs a result with one of the existing final statuses |
| Windows Update | `WindowsUpdateEngine.ps1` (SYSTEM task, WUA COM API). Drivers follow `windowsUpdate.drivers` (followPolicy / include / exclude); the owner default policy **excludes** drivers from quality updates. It finishes `Succeeded` only when no restart is pending | the authoritative update engine; the driver stage must wait for it, not duplicate it |
| Applications | `ApplicationEngine.ps1` (signed-in user). `Get-WdaUpdatesGate` waits for the Windows Update result (or `waitForUpdatesHours`) | the gate is where "applications after drivers" belongs |
| Coordination | `# region WDB coordination` (install lock `state\install.lock`, `state\restart-pending.json`), byte-identical in both engines (unit test) | a third engine copies the same region |
| Phase 5 | durable state with `.bak`, failure classes (`Permanent, Integrity, Policy, User, Manual` never retried automatically), lifecycle names, `attempts.jsonl`, outcome codes (`PausedAwaitingNetwork`/`Reboot`/`User`), `DeploymentRecovery.ps1` (Status, PendingActions, RetryFailed, Retry, Resume, RestoreSettings, ExportDiagnostics) | driver operations reuse the lifecycle names, failure classes, outcome codes and the recovery tool |
| Phase 6 | `WdbMigration.ps1` marks hardware utilities (`$HardwareName`, kind `driver`) "left for Phase 8"; `matching.ts` never reinstalls them | Phase 8 must define how they are evaluated (optional applications, never automatic) |
| Phase 7 | `WdbMediaAssistant.ps1` reads the ZIP manifest `media` block, places `autounattend.xml`, `WindowsDeployment\`, the pinned backup; Ventoy refused; image inspection | setup-critical drivers must go onto the media through it |
| Driver stub | `src/engine/drivers/contract.ts` (Phase 3 interface: `DRIVER_STAGE`, inventory/candidate/result types, selection rules), a disabled `drivers` stage in `orchestration.json` and the manifest, "not implemented" lines in the report and status window | replaced by the real stage; the selection rules in the stub are kept |
| PowerShell | Windows PowerShell 5.1, `Set-StrictMode -Version 2.0`, adapters for every system call, scenario tests that replace them | the driver engine follows the same pattern |

## Gaps

No hardware inventory; no device or driver state; nothing distinguishes a basic display driver from
a vendor driver; nothing waits for Windows Update before judging drivers; no offline driver path
(the owner may install without a network); no way to supply a storage driver Windows Setup needs;
a missing network driver silently leads every stage to `Offline`; no driver result for Phase 9.

## Decisions

1. **One more engine, not a second orchestrator.** `DriverEngine.ps1` runs as SYSTEM from its own
   task (`\WindowsDeploymentBuilder\Drivers`), launched once by `Initialize-Deployment.ps1` like
   the others, followed by the existing monitor. It installs nothing Windows Update would; it never
   calls the Windows Update Agent.
2. **Order.** Inspection A at the first start (and network bootstrap from verified offline
   packages); then it waits until the Windows Update stage is final *and* no restart is pending;
   Inspection B after that restart; resolution; verification after any restart; result. The
   application stage waits for the driver stage (`coordination.drivers`, only in configurations
   that have the driver stage, so older configurations behave as before).
3. **Sources, in order:** the device's current healthy driver; the Windows driver store; Windows
   Update (through the existing engine and its policy); a verified offline bundle pinned by SHA-256;
   technician-entered verified packages (official HTTPS host, SHA-256, INF-based); otherwise a manual
   action with the official support page. No scraping, no invented URLs, no EXE installers.
4. **Windows decides the final ranking.** Candidates are pre-filtered by hardware ID / compatible ID,
   class, architecture, OS build, Microsoft (WHQL/attestation) catalog signature and OEM subsystem;
   `pnputil /add-driver <inf> /install` then lets Windows' own ranking choose. Success is recorded
   only after the device itself reports a working driver from that package.
5. **Setup-critical drivers** go to `$WinPEDriver$` on the USB drive (documented Setup behaviour,
   no image modification), only the packages the technician pinned, through the Phase 7 assistant.
6. **Profiles.** Schema version 5 adds `drivers`. New deployments: on (inspection + safe sources).
   Older profiles: off (migration note), so they keep producing the deployment they did.
