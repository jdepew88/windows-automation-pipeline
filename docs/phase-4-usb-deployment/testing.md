# Testing: USB deployment and orchestration (Phase 4)

## Automated (development PC, Windows 11, 2026-10-20)

| Command | Result |
|---|---|
| `npm run typecheck`, `npm run lint` | clean |
| `npm test` | **296** Vitest tests in 15 files, including the Windows-only PowerShell bridge (parse check of every embedded `.ps1`, all three PowerShell suites) |
| `npm run test:ps` | `Engine.Tests.ps1` **25/25**, `Applications.Tests.ps1` **45/45**, `Deployment.Tests.ps1` **25/25** |
| `npm run test:e2e` | **45 passed**, 1 skipped (the drawer test runs on mobile only); desktop and mobile Chromium |
| `npm run build` | passes |

`Deployment.Tests.ps1` runs against a fixture built from the **real generator output**
(`tests/powershell/deployment-fixture.ts`): the deployment ZIP is extracted as a user would put it on
a USB drive, and the scripts are dot-sourced from that extracted package (the files that ship, not
`src`). Scheduled tasks, engine installers, identity, Windows PE detection, time, boot time, ACLs,
shortcuts and the event log are simulated; every file is written below a temporary folder.
**Nothing is registered, installed, secured or restarted.** A mutation check (overall status forced
to `Succeeded`, duplicate-launch guard removed) made 6 scenarios fail as expected.

### Coverage by requirement

| Requirement | Where |
|---|---|
| ZIP generation, reproducibility, path safety, CRC, corruption detection | `deployment.test.ts` › primitives, package |
| ZIP content integrity (manifest = files, sizes, SHA-256 checked with Node crypto) | `deployment.test.ts`; `Deployment.Tests.ps1` (PowerShell SHA-256 of the extracted ZIP) |
| Required files present; every launcher exists; every `.ps1` in the package parses | both |
| Answer file at the USB root | `deployment.test.ts`, `app.spec.ts` |
| Staging-script generation and the real extraction (text hashes of every embedded file) | `Deployment.Tests.ps1` (runs the generator's own `ExtractScript` on the generated answer file) |
| First-boot initiation (FirstLogon order, only the orchestrator) | `deployment.test.ts`, `windows-update.test.ts`, `applications-generate.test.ts`, `generate.test.ts` |
| SYSTEM vs user context | `Deployment.Tests.ps1` (SYSTEM → WinGet stage refused, Windows Update launched) |
| Windows Update / WinGet hand-off, marker not trusted alone | `Deployment.Tests.ps1` |
| Retry and resume, interrupted launch, launch limit | `Deployment.Tests.ps1` |
| Restart handling (state across boots, restart marker per boot, no relaunch) | `Deployment.Tests.ps1` |
| Duplicate execution, concurrent runs (mutex across processes) | `Deployment.Tests.ps1` |
| Missing USB media, missing configuration files, modified files, invalid manifests | `Deployment.Tests.ps1` |
| Customer selections (profile + additions − removals, de-duplicated; owner defaults untouched; unresolved flagged) | `deployment.test.ts`, `app.spec.ts` |
| Completion reporting (failed KBs, interaction, restarts, drivers not done, non-ASCII names) | `Deployment.Tests.ps1` |
| Stalled stage, deadline, offline target → `Incomplete` | `Deployment.Tests.ps1` |
| Integrity failure stops the monitor and resume | `Deployment.Tests.ps1` |
| Offline operation (ZIP built with the browser offline) | `app.spec.ts` (`context.setOffline(true)`) |
| Backward compatibility: both engines off = byte-identical Milestone 1 answer file; all deployment assets byte-identical to Phase 3; profile v1/v2 imports | `windows-update.test.ts` (M1 fixture), `deployment.test.ts`, regression harness below |
| Answer-file stability (empty script or profile name do not change it) | `deployment.test.ts` |
| Requirement-bypass controls unchanged | `deployment.test.ts`, `app.spec.ts` |

### Regression against Phase 3 (`30d2075`)

Every generated output was hashed for six profiles (defaults, Windows Update off, both engines off,
requirement bypasses on, applications + Additional Software, invalid) with the Phase 3 code and with
this branch:

- identical: every deployment asset (engine scripts, `config.json`, `applications-config.json`,
  `winget-packages.json`, plan, schema, READMEs, `orchestration.json`), every embedded file of
  Phases 1–3, every validation issue, and the whole answer file whenever no engine is active;
- changed, as intended: the answer file when an engine is active (added
  `C:\Windows\Setup\Scripts\Deployment\…` files and the FirstLogon command), see
  `implementation-report.md` › "Changes to the answer file".

### Real Windows, read-only

| Check | Result |
|---|---|
| `WindowsDeployment\setup.ps1 -Verify` from an extracted generated package | `Verified all 26 file(s) against the manifest.` exit 0 |
| `scripts\bootstrap\Stage-Deployment.ps1` (standalone = verify only) | `Verified (no changes made).` exit 0 |
| `C:\ProgramData\WindowsDeploymentBuilder` before and after | did not exist before, does not exist after |

## Not tested: needs a disposable VM, then physical hardware (status: UNVERIFIED)

Use a VM with UEFI + TPM (Hyper-V Gen 2 or VMware), Internet, and a virtual USB drive or ISO, and a
package with Windows Update on plus a small selection (for example Git, 7-Zip, VLC and one Store app).

1. Media and Setup
   - [ ] Media Creation Tool drive + extracted ZIP: Setup applies `autounattend.xml` and **stops at
         disk selection**.
   - [ ] Rufus drive (customisations off): same.
   - [ ] A second removable drive attached during Setup: nothing on it changes.
2. Staging and first boot
   - [ ] After specialize: `C:\Windows\Setup\Scripts\Deployment\…` exists; the Panther copy is
         deleted after the first sign-in.
   - [ ] `Deployment\logs\deployment.log`: staging verified (`Verified N file(s) … Embedded`),
         both stages launched, monitor registered.
   - [ ] ACL of `C:\ProgramData\WindowsDeploymentBuilder\Package`: Users read/execute only.
   - [ ] The progress window opens; the shortcut exists.
   - [ ] USB drive removed after Setup: deployment continues.
3. Running
   - [ ] Windows Update restarts; after each boot the monitor runs (log) and the progress view is
         correct (current stage, restarts, pending restart).
   - [ ] Applications wait for Windows Update, then install; the progress view shows the current
         application and remaining count.
4. End
   - [ ] `deployment-report.txt` matches the engine results; overall status correct; the monitor
         task is gone; the report shortcut exists.
5. Negative runs (fresh VM each)
   - [ ] No network at all → `Incomplete`; then network + `Resume-Deployment.ps1 -RestartStage …`.
   - [ ] Power off during an application installation → resumes, no duplicate launch.
   - [ ] Edit a file in `Package\` before the monitor runs → `IntegrityFailed`, nothing more runs.
   - [ ] Manual run: `setup.cmd` on an installed Windows that was not installed with the answer file.
6. Record results in `docs/validation-log.md`.

The earlier VM checklists (Milestone 1, Phase 2, Phase 3) still apply and are still open.
