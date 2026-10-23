# Phase 9 integration: drivers.json

`C:\ProgramData\WindowsDeploymentBuilder\reports\drivers.json`, format
`windows-deployment-builder/drivers-result`, version 1. JSON Schema: `drivers-result.schema.json`
(shipped next to the engine; `DRIVERS_RESULT_JSON_SCHEMA`); TypeScript types:
`src/engine/drivers/contract.ts › DriverResult`. Written while the stage runs (`final: false`, status
`InProgress`) and at the end (`final: true`).

| Field | Content |
|---|---|
| `deploymentId` | package id of the deployment (from `state\deployment.json`) |
| `scanUtc`, `inspections[]` | the three inspections (Initial, AfterUpdates, Final) with time, boot time, counts |
| `system` | manufacturer, model, family, portable, virtual, architecture, Windows build, BIOS version, processors (no serial, UUID or computer name) |
| `windowsUpdate` | part of the deployment, drivers allowed, waited for it, its stage status, gate reason |
| `summary` | counts per device state |
| `health` | `status` + `flags` (below) |
| `devices[]` | key, name, category, class, vendor, hashed instance id, hardware IDs, compatible IDs, problem code, current driver, previous driver (if replaced), source, result, verification, restart required, errors, manual action, reasons, confidence, setupCritical, oemCustomized, optional update, state before/after Windows Update |
| `operations[]` | operation id, device, hardware ID, status, failure class, source, package, attempts, verification, restart |
| `manualActions[]`, `unsupported[]` | what a technician must do, with the official page |
| `optionalApplications[]` | vendor tools related to the hardware, `required: false` |
| `networkBootstrap`, `offlineBundle`, `setupCritical[]`, `reboots`, `firmware` | as named |

`health.status` distinguishes (first true wins): **RestartPending** (installed, restart pending),
**InstalledButMalfunctioning** (DeviceFailure / NoEffect), **MissingDriver**, **PossibleHardwareIssue**
(problem codes that point at hardware or firmware), **TechnicianRequired** (manual actions, failures,
unsupported), else **AllHealthy**. `health.flags` has each of them as a boolean (several can be true).

Also for Phase 9: `Drivers\result.json` (`status`, `reason`, `health`, `installed`, `outstanding`) is
followed by the orchestrator like every engine result; the deployment report has a "Hardware & drivers"
section and `drivers` block; `logs\attempts.jsonl`; the event IDs 4000/4001/4100-4103/4110. The full
Phase 9 dashboard is not part of Phase 8.
