# Phase 9 implementation report: deployment verification and health

**Branch and baseline.** Branch `feature/phase-9-deployment-verification-health`, created from
`feature/phase-8-ui-review-and-app-selection-fixes` at `81deadc` (local and remote verified equal,
clean tree, Phases 5-8 and the UI corrections in its history).

**What was not done.** Not merged, not deployed. No Windows installation, disk, driver, account,
policy or setting on this computer was changed. Phase 8.5 was not started.

**Validation status.** Everything here is validated **in simulation only**. Real-hardware validation
is outstanding: [bare-metal-checklist.md](bare-metal-checklist.md).

## What was built

| Area | Files |
|---|---|
| Health engine (read-only, Windows PowerShell 5.1, StrictMode) | `src/engine/health/scripts/DeploymentHealth.ps1` |
| Report template (technician dashboard, customer handoff, website preview) | `src/engine/health/scripts/HealthReport.html` |
| Verification plan, contract, schemas, sample data | `src/engine/health/index.ts`, `contract.ts`, `src/engine/schema/health.ts` |
| Profile schema 6 (`health` section, migration: older profiles keep verification off) | `schema/profile.ts`, `profiles/migrations.ts`, `profiles/owner-default.json` |
| Package and manifest (`verification` block, `paths.healthTool`, README stage 5) | `src/engine/deployment/index.ts` |
| Orchestrator integration | `Complete-Deployment.ps1` (verify after Completed, report `health` block, desktop shortcut), `Show-DeploymentStatus.ps1` (open once) |
| Recovery tool | `DeploymentRecovery.ps1` (Verify, menu 9; deployment-user guard and `-RetargetUser`; state rebuild keeps the user; health files in diagnostics; archive check) |
| Advanced section | `src/features/health/index.ts`, `src/ui/health.ts`, `layout.ts`, `editors.ts`, `styles.css` |
| Final Review | `preview.ts`, `app-summary.ts` (Additional Software), `quick.ts`, `wizard.ts` ("Verification & handoff") |
| Website security | `index.html` CSP: the template's script allowed by SHA-256 only |

## Corrections found during the audit

1. **The Windows Update driver policy contradicted the driver stage.**
   - **Before:** new deployments hid drivers from Windows Update while the driver stage waited for
     Windows Update to supply them.
   - **Now:** the default is off. The driver stage receives the same policy. Older profiles keep
     their explicit value and are warned about the conflict. An organization's policy is reported,
     never overwritten.
2. **A StrictMode error in `Initialize-Deployment.ps1` (Phase 4).**
   - `"$script:DeployVersion: initialize"` throws under the StrictMode 2.0 the scripts enable, so a
     real first sign-in would have stopped before staging.
   - The orchestrator tests run with StrictMode off, which hid it.
   - Fixed. The Phase 9 scenarios run under StrictMode, and a static test now rejects the pattern in
     every shipped script.
3. **Recovery could silently retarget per-user installations** to another administrator's profile.
   It now refuses, with a recorded, explicit `-RetargetUser` override.
4. **Final Review did not list Additional Software** (a Phase 8 UI limitation). It does now.

## Tests

| Suite | Result |
|---|---|
| Typecheck, lint, production build | clean (only the existing bundle-size advisory) |
| Vitest (23 files; on Windows also every PowerShell suite: Windows Update, applications, deployment, migration, media, drivers, health, Wi-Fi, exit-code and adapter parity) | 488 passed (469 before Phase 9) |
| `Health.Tests.ps1` | 27 of 27 (scenarios A-L, fault injection, lifecycle, re-verification, cleanup, diagnostics, read-only proof, compatibility), all under StrictMode; reports validated against the published schemas |
| `Deployment.Tests.ps1` | 46 of 46 (verification now runs at every completion) |
| `Drivers.Tests.ps1` | 26 of 26 (two expectations updated for the corrected default; the "Windows Update was not allowed" explanation is still tested with an explicit exclude policy) |
| Playwright (desktop, tablet, Pixel 7) | 220 passed, 2 skipped (the existing mobile-drawer tests on wider screens); new `health.spec.ts` 5 × 3 |
| Phase 8 mutations | the remaining 7 run one at a time: all detected (10 of 10); source restored byte-identical |
| Live probes (`HealthLiveProbe.ps1`, read-only, this computer) | 51 findings, 0 check errors, 16 s. Store packages and BitLocker need elevation and were reported as such |

**Tests changed because of the deliberate default change.** Each assertion that encoded the old
driver default (`exclude`) now expects `include`, or sets the old policy explicitly where the test is
about the Milestone 1 output or the conflict. No assertion was removed. The snapshots were
regenerated; their only differences are:

- the removed policy line;
- `drivers: include`;
- the Initialize fix;
- the Phase 9 files.

## Known limitations

- **Simulation only.** Real devices, Defender, BitLocker, Store packages and Windows Update searches
  are simulated in the scenarios. The driver stage's output is also simulated there; the real driver
  engine has its own suite.
- **Application detection.** It relies on uninstall records, Store packages and the portable
  shortcut. An installer that registers none is reported as uncertain (never as missing).
- **Per-user checks.** They need the deployment user's hive to be loaded. Otherwise they are
  Deferred (Unverifiable).
- **Recovery keys.** Where a recovery key is backed up cannot be verified on the computer. The report
  always asks for confirmation.
- **SmartScreen and hardware codes.** SmartScreen is judged from its setting and policy (optional).
  Device problem codes that point at hardware are heuristics, labelled "possible".
- **Confirmations.** The technician's "confirm by hand" ticks and notes are for printing; they are not
  stored.
- **No PDF engine.** The reports are print-ready HTML (browser "Save as PDF").
- **Firefox.** The scroll-regression project is opt-in. The installed Playwright Firefox build does not
  match Playwright 1.64, and no browser was downloaded.
- **Package size.** The answer file grows by the engine, its plan and the template: the documentation
  sample went from 609 KB to 810 KB (about 200 KB, XML-escaped). Whether Windows Setup
  accepts an answer file of this size has not been tested on real media: it is part of gate 1.
