# Testing

## Automated (run in this repository)

| Command | What it covers |
|---|---|
| `npm run typecheck` | `tsc --noEmit`, strict mode |
| `npm run lint` | ESLint + typescript-eslint |
| `npm test` | Vitest unit/snapshot tests (`tests/unit`). On Windows this also parses every generated `.ps1` with the PowerShell parser and runs `tests/powershell/Engine.Tests.ps1` |
| `npm run test:ps` | Only the engine scenarios: `Engine.Tests.ps1` (Windows Update, simulated Windows Update Agent), `Applications.Tests.ps1` (application engine and WinGet bootstrap, simulated WinGet) and `Deployment.Tests.ps1` (Phase 4 orchestrator against the real generated package, simulated machine; see [phase-4-usb-deployment/testing.md](phase-4-usb-deployment/testing.md)). Windows PowerShell 5.1; nothing is installed |
| `npm run test:e2e` | Playwright smoke tests on desktop and mobile Chromium (`tests/e2e`). Builds and serves on port 5179. First run `npx playwright install chromium`. Set `E2E_BASE_URL=<url>` to run against a deployed site instead |
| `npm run check` | typecheck + lint + unit tests |

Unit test coverage by acceptance criterion:

- **Owner profile loads exactly / reset restores**: `profiles.test.ts` (every owner decision, independent copies), `app.spec.ts` (controls, reset).
- **Basic/Advanced toggle does not reset values**: `app.spec.ts`.
- **Import/export round trip keeps every field; no secret leakage by default**: `profiles.test.ts`, `app.spec.ts`, `generate.test.ts` ("does not leak secrets").
- **Snapshots for default XML and variations**: `generate.test.ts`, `components.test.ts` (`__snapshots__/`).
- **Parser assertions, passes, architecture, schema**: `generate.test.ts`, `xml-structure.ts` (runs on every generation).
- **Incompatible combinations rejected with field-level messages**: `validation.test.ts`, `app.spec.ts`.
- **Escaping of quotes, ampersands, script text and names**: `serialize.test.ts`, `scripts.test.ts`, `generate.test.ts` (Wi-Fi SSID/password, plain-text password, names with diacritics).
- **Disk setup interactive, no wipe**: `generate.test.ts`, `components.test.ts` (rejects disk elements), `profiles.test.ts` (rejects `diskMode` other than interactive), plus a runtime check in `checkStructure`.
- **Name edits update hostname and account references**: `generate.test.ts`, `naming.test.ts`, `app.spec.ts`.
- **Four script stages, empty lists, no phantom execution**: `scripts.test.ts`.
- **Advanced XML merge, conflicts, malformed input**: `components.test.ts`.
- **Registry ↔ schema coverage and metadata completeness**: `registry.test.ts`.
- **Phase 2: Milestone 1 output preserved** (engine off = byte-identical M1 XML; v1 profiles import
  with the engine off), embedding, ordering, config mapping, validation: `windows-update.test.ts`.
- **Phase 2 engine behaviour** (`Engine.Tests.ps1`, 22 scenarios):
  - clean machine; install → reboot → resume, with follow-up updates;
  - re-offered and failing updates given up, one component reset, download failures;
  - reboot limit;
  - policy skips (feature, driver, optional, interactive, KB);
  - offline → `Offline`, late network;
  - scan failures, unexpected errors → `Failed`, a crash counted as an attempt;
  - busy installer, already finished, pending restart, corrupt state;
  - single instance (mutex across processes), log content, config defaults.

- **Hosting (Cloudflare Pages)**: `security-headers.test.ts` (`public/_headers` and the pages' policy
  generated from one definition, strict CSP, import size limits) and `npm run test:e2e:production`
  (`tests/production/pages.spec.ts`: the built `dist/` in the local Pages emulator, headers, no CSP
  violations or external requests, ZIP contents); see
  [cloudflare-pages/deployment.md](cloudflare-pages/deployment.md).
- **Quick Deployment application review and Advanced selection fix**: `app-preview.test.ts` (summary and
  profile previews equal the generated configuration) and `app-review.spec.ts` (previews, Final Review
  summary, and the Advanced catalog scroll regression in all four layouts); see
  [phase-8-ui-review-and-app-selection-fixes](phase-8-ui-review-and-app-selection-fixes/implementation-report.md).
- **Phase 8 (hardware-aware drivers)**: `drivers.test.ts`, `Drivers.Tests.ps1` (the engine of the
  real generated package against simulated hardware: fixtures A-H, selection, Windows Update,
  restarts, recovery, orchestrator and recovery-tool integration), driver scenarios in
  `Media.Tests.ps1` and `drivers.spec.ts`; see
  [phase-8-hardware-aware-drivers/testing.md](phase-8-hardware-aware-drivers/testing.md).
- **Phase 7 (USB media preparation)**: `media.test.ts`, `Media.Tests.ps1` (the assistant against
  the real generated packages, simulated disks and synthetic Windows images) and `usb.spec.ts`; see
  [phase-7-usb-media-preparation/testing.md](phase-7-usb-media-preparation/testing.md).
- **Phase 6 (application inventory, backup and restore)**: `migration.test.ts`,
  `Migration.Tests.ps1` (collector, backup, validation, restore on a simulated computer), the
  Phase 6 scenarios in `Applications.Tests.ps1` and `Deployment.Tests.ps1` (a second real generated
  package with a pinned backup) and `migration.spec.ts`; see
  [phase-6-application-backup-restore/testing.md](phase-6-application-backup-restore/testing.md).
- **Phase 5 (resilient provisioning, resume and retry)**: `recovery.test.ts`, the Phase 5 scenarios
  in `Applications.Tests.ps1` (fault injection on the engine) and `Deployment.Tests.ps1` (the full
  lifecycle: real package, real engine, monitor and recovery tool), and the Reliability & recovery
  browser test; see [phase-5-resilient-provisioning/testing.md](phase-5-resilient-provisioning/testing.md).
- **Phase 9 (deployment verification and health)**:
  - `health.test.ts`;
  - `Health.Tests.ps1`: scenarios A-L, fault injection and the full lifecycle under StrictMode, also
    run by `npm run test:ps`;
  - `health.spec.ts`;
  - the shared simulations `ProvisioningSim.ps1`, `HealthSim.ps1` and `MigrationSim.ps1`;
  - opt-in, read-only on this computer: `HealthLiveProbe.ps1`;
  - opt-in: the Firefox scroll regression (`E2E_FIREFOX=1 npx playwright test --project=desktop-firefox`,
    after `npx playwright install firefox`).

  See [phase-9-deployment-verification-health/testing.md](phase-9-deployment-verification-health/testing.md).
- **Phase 4.3 (Quick Deployment, update policy timing, Wi-Fi provisioning, catalog layouts)**:
  `quick.test.ts`, `quick.spec.ts`, the new `Deployment.Tests.ps1` scenarios and `Wifi.Tests.ps1`
  (also run by `npm run test:ps`); see
  [phase-4-3-quick-deployment-wizard/testing.md](phase-4-3-quick-deployment-wizard/testing.md).
- **Phase 4.2 (catalog, profiles, devices, engine 1.1.0)**: `app-profiles.test.ts`, the new
  `Applications.Tests.ps1` scenarios and the application browser tests; see
  [phase-4-2-application-profiles/testing.md](phase-4-2-application-profiles/testing.md).
- **Phase 3 (WinGet provisioning)**: see [phase-3/testing.md](phase-3/testing.md) for the coverage
  table, the read-only checks done on real Windows, and the VM checklist (section D below points
  there).

## Not automated: must be done on Windows (status: UNVERIFIED)

Claude's environment could not run Windows ADK/WSIM or install Windows in a VM. **None of the following
has been done.** The generated file is well-formed and structurally checked, but that does **not** prove
that Windows Setup accepts it or behaves as intended.

### A. WSIM catalog validation

1. Install the **Windows ADK** matching your media (the Windows 11 ADK; only "Deployment Tools" is
   needed). Record the ADK version.
2. Download the Windows 11 ISO you will deploy (e.g. 25H2, English US, x64). Record the exact build
   from `dism /Get-WimInfo /WimFile:<mount>\sources\install.wim /Index:<Pro index>`.
3. Copy `sources\install.wim` to a writable folder. Open **Windows System Image Manager**, then
   *File → Select Windows Image* → choose the Pro index and let it create the catalog (`.clg`).
4. Generate the answer file from the app (enter a test name), then *File → Open Answer File* →
   `autounattend.xml`.
5. Run *Tools → Validate Answer File*. Record every message. Expected:
   - **No errors** for components, settings, passes or values.
   - WSIM may warn about the `Extensions` element in the foreign namespace. Windows Setup ignores
     unknown namespaces (upstream relies on this). Record the warning text.
6. Repeat with any additional XML components you plan to use.

### B. Disposable VM install (repeat twice: with Internet and without)

Hyper-V Generation 2 (Secure Boot + vTPM) or VMware/VirtualBox with EFI + TPM 2.0, 4 GB RAM,
64 GB disk, **no snapshots of real data**.

1. Build media: write the ISO to a USB drive (or a second ISO with only `autounattend.xml` in the
   root, attached as a second DVD drive in the VM). Put `autounattend.xml` in the **root**.
2. Run 1 with the virtual network adapter **connected** to the Internet. Run 2 **disconnected**.
3. Boot and verify, recording timestamps and screenshots:
   - [ ] No language, edition or EULA page appears (edition = Pro).
   - [ ] **Setup stops at "Where do you want to install Windows?"** Nothing is selected or wiped
         automatically. Create/select the partition manually.
   - [ ] After install, OOBE shows the **Wi-Fi/network page** (interactive, owner default) when a
         Wi-Fi adapter is present. In a VM with wired networking it may be skipped by OOBE.
   - [ ] **No Microsoft account page** appears in either run. The privacy page does not appear
         (ProtectYourPC=3).
   - [ ] The local account `<Name>` is created, and the computer name is `<Name>-Computer` (`hostname`).
   - [ ] The desktop signs in automatically. A PowerShell window runs FirstLogon.ps1 **once**.
         Check `C:\Windows\Setup\Scripts\FirstLogon.log`, `Specialize.log` and `DefaultUser.log` for errors.
   - [ ] Reboot twice: auto-login **persists** (owner "persistent" mode, unverified mechanism).
         Check `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon` (`AutoAdminLogon=1`,
         no `AutoLogonCount`).
   - [ ] UAC: `HKLM\…\Policies\System` shows `EnableLUA=1`, `ConsentPromptBehaviorAdmin=5`,
         `PromptOnSecureDesktop=0`. A prompt appears without dimming.
   - [ ] `powercfg /a` shows Hibernate available. Fast Startup is off (`HiberbootEnabled=0`).
   - [ ] File extensions are shown. Explorer opens This PC. Taskbar is left-aligned with the search
         icon only. Widgets are gone. Task View is visible.
   - [ ] Desktop shows only the Recycle Bin, with no Edge shortcut. Shortcut arrows are blank
         (**unverified tweak**: check for black squares).
   - [ ] Start → folders next to Power: Downloads, Personal folder, Pictures, Settings.
   - [ ] `Get-AppxProvisionedPackage -Online` no longer lists removed apps. Kept apps are still present.
   - [ ] `Get-ComputerRestorePoint` / System Protection shows C: protected.
   - [ ] `C:\Windows\Panther\unattend.xml` is deleted.
   - [ ] Add a test FirstLogon script (e.g. writes a file to `C:\fl-test.txt`) and confirm it ran
         once, at the first logon, after the generated steps.
4. Record: ISO name and build, ADK version, hypervisor and version, VM settings, repository commit,
   and results per checkbox, in `docs/validation-log.md` (create it).

Report anything that fails as **unverified/failed**. Do not mark M1 as hardware-validated until both
runs pass.

### C. Windows Update engine (Phase 2; status: UNVERIFIED)

Only a **read-only** scan has run on real Windows (`-Mode Scan` on the developer's Windows 11
Insider workstation, 2026-10-19). It found 2 applicable updates and correctly reported an
existing pending restart. Nothing was installed. Installing, restarting and resuming have only
been exercised against the simulation.

Run in the same disposable VM as B, using an ISO that is a few months old so updates are pending:

1. Generate with the owner defaults (engine on). After the first desktop appears:
   - [ ] `FirstLogon.log` shows FirstLogon.ps1 finished **before** Install-UpdateEngine.ps1 ran. The
         installer printed "Engine is running".
   - [ ] Task Scheduler → `\WindowsDeploymentBuilder\WindowsUpdate` exists and runs as SYSTEM.
   - [ ] `icacls C:\ProgramData\WindowsDeploymentBuilder` shows SYSTEM/Administrators F, Users RX only.
2. Watch `C:\ProgramData\WindowsDeploymentBuilder\Updates\logs\engine.log` and `status.json`:
   - [ ] A restart warning appears about 60 s before each restart. After the restart the engine resumes
         (start N+1 in the log) without anyone signing in.
   - [ ] No second engine instance (`Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"`).
   - [ ] The run ends with `result.json` `status: Succeeded` (or `CompletedWithFailures` with the KBs
         listed). `windows-update.done` exists. Application log has event 1100/1101. The task is gone.
   - [ ] Settings → Windows Update shows "You're up to date". No feature update was installed (skip),
         and no drivers when the driver exclusion is on.
3. Negative runs (one each, fresh VM):
   - [ ] Network disconnected for the whole run, with `maxRuntimeHours` = 1: ends `Offline`, no marker.
   - [ ] `maxReboots` = 1 on an old ISO: ends `Failed` with "Reboot limit (1) reached".
   - [ ] Network connected only after the first hour: the engine resumes at the hourly trigger.
4. Record the results and the ISO build in `docs/validation-log.md`.

### D. Application provisioning (Phase 3; status: UNVERIFIED)

Follow the checklist in [phase-3/testing.md](phase-3/testing.md) ("Not tested: needs a disposable
VM") in the same VM, with a small selection of applications.
