# Phase 8 architecture: hardware-aware drivers

The audit of the deployment before this phase is in [audit.md](audit.md).

```
website (no hardware access)                    installed computer (SYSTEM task \WindowsDeploymentBuilder\Drivers)
----------------------------                    ------------------------------------------------------------------
Hardware & Drivers policy  -----------------+   DriverEngine.ps1
pinned offline bundle (manifest SHA-256)    |     1 Inspection A  Win32_PnPEntity + Win32_PnPSignedDriver + DEVPKEY_Device_Parent
verified packages (URL + SHA-256 + IDs)     |                     + Win32_ComputerSystem/BaseBoard/BIOS/Processor/SystemEnclosure
approvals (package + hardware ID)           +-->  network bootstrap (offline packages only, when no adapter works)
optional pre-installation inventory          |  2 wait: Windows Update stage final + its restart  (WindowsUpdateEngine.ps1 decides)
  (summary only; table stays in the tab)     |  3 Inspection B; reconcile (AlreadySatisfied / still needed)
                                             |  4 resolve: driver store -> bundle -> technician -> verified download -> manual
drivers-config.json (embedded in            |     candidate filter, then pnputil /add-driver /install (Windows ranks)
  autounattend.xml, staged by Phase 4)  ----+  5 restart if needed; verify each device; reports\drivers.json, result.json
                                                ApplicationEngine.ps1 starts after the driver stage (coordination.drivers)

USB Preparation Assistant (Phase 7): bundle -> WindowsDeployment\drivers\<folder>, Setup-critical packages -> $WinPEDriver$\<folder>
hardware & driver tool (DriverEngine.ps1 -Mode Inspect / Export / Bundle) on an existing computer
```

## Components

| Component | Where | Role |
|---|---|---|
| Driver engine | `src/engine/drivers/scripts/DriverEngine.ps1` (Windows PowerShell 5.1, StrictMode 2) | the stage, plus read-only `Inspect`/`Plan`, bundle tools `Export`/`Bundle`/`ValidateBundle`, technician `AddPackages`/`Retry`, `Library` |
| Installer | `Install-DriverEngine.ps1` | ACL on the data root, copies engine + config to `<dataRoot>\Drivers`, registers the SYSTEM task (startup + every 30 min), `-Resume` for recovery |
| Configuration | `drivers-config.json` (`src/engine/drivers/index.ts › driversConfig`) | policy, timing, Windows Update coordination, pinned bundle, verified packages, approvals, identification data (`src/data/driver-sources.json`) |
| Result contract | `src/engine/drivers/contract.ts`, `drivers-result.schema.json` | `reports\drivers.json` for Phase 9 |
| Website | `src/features/drivers`, `src/ui/drivers.ts` | Hardware & Drivers page (Advanced), Quick Deployment summary line |
| Media | `WdbMediaAssistant.ps1 -Drivers` | copies and verifies the bundle; `$WinPEDriver$` for Setup-critical packages |

## No second orchestrator, no second update engine

The driver stage is one more engine stage of the existing orchestrator (`Get-WddEngineStages`):
launched once by `Initialize-Deployment.ps1`, followed by `DeploymentOrchestrator.ps1` through its
own `status.json`/`result.json`, reported by `Complete-Deployment.ps1`, recoverable through
`DeploymentRecovery.ps1`. It takes the same install lock and restart marker as the other engines
(the `# region WDB coordination` block, byte-identical in all three). It never calls the Windows
Update Agent: Windows Update installs drivers or not according to the deployment's own
`windowsUpdate.drivers` setting, and the driver stage waits for that stage to be final.

## Data written on the installed computer

```
C:\ProgramData\WindowsDeploymentBuilder\
  Drivers\state.json(.bak)           operations, device records, phase (atomic, last good copy kept)
  Drivers\status.json, result.json   live phase / final status (the orchestrator reads these)
  Drivers\inventory-initial.json     Inspection A
  Drivers\inventory-after-updates.json  Inspection B
  Drivers\inventory-final.json       verification
  Drivers\packages\bundle|technician|download\   verified copies (protected folder)
  Drivers\downloads\                 *.part during a download, deleted if the hash is wrong
  Drivers\logs\engine.log, attempts.jsonl
  reports\drivers.json               the Phase 9 result
  state\drivers.done                 marker (never trusted on its own)
  state\network-driver-missing.json  while no network adapter works and no driver is available
```

## Profiles and compatibility

Schema version 5 adds `drivers`. New profiles: on (see [sources.md](sources.md) for what that
does). Profiles of schema 1-4: off, with an import note, so they produce the deployment they did. A
deployment with the stage off has no driver files, no `coordination.drivers` and a manifest stage
marked `NotPartOfDeployment`; its engines behave as in Phase 7 (the application gate only waits
for a driver stage that the configuration names).
