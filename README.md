# Windows Deployment Builder (Milestone 1 + Phase 2 Windows Update + Phase 3 WinGet provisioning)

A local, offline, browser-based generator for **Windows 11 Pro `autounattend.xml`** answer files,
written entirely in TypeScript. It is built on the option model and XML patterns of
[cschneegans/unattend-generator](https://github.com/cschneegans/unattend-generator) (MIT) and
pre-set with the owner's defaults. Every implemented setting stays editable, and rare settings sit
behind an **Advanced** view.

> **Status:** Implemented and covered by automated tests. **Not yet validated with Windows
> ADK/WSIM or a VM installation.** See [docs/testing.md](docs/testing.md) for the procedure. Do not
> use it on a machine you care about until that is done.

## Quick start

```bash
npm install
npm run dev        # http://localhost:5173
npm run build      # typecheck + production build in dist/
npm test           # unit and snapshot tests (on Windows also the PowerShell engine scenarios)
npm run test:ps    # only the PowerShell engine scenarios (simulated; installs nothing)
npx playwright install chromium && npm run test:e2e   # browser smoke tests
npm run lint
```

## Deployment (Cloudflare Workers)

The site is deployed as the static-assets-only Worker `windows-automation-pipeline` (`wrangler.jsonc`
serves `dist/`; source maps are excluded by `public/.assetsignore`). Deploy manually with
`npm run deploy`, or let Cloudflare Workers Builds deploy pushes to `main` (build command
`npm run build`, deploy command `npx wrangler deploy`).

Everything runs locally in the browser, including on the deployed site. Nothing is uploaded, no script runs in the browser, and profiles are not
saved automatically.

## Using it

1. Enter **one person's name**. The username and the `<Name>-Computer` computer name (≤ 15 chars)
   are derived live.
2. Review the sections. **Basic** shows everyday choices. **Advanced** adds rare settings, the other
   three script stages, extra XML components, mapping details and the full diff.
3. Fix anything listed under **Review & download**. Errors block output.
4. **Download** `autounattend.xml` and copy it to the **root** of your Windows installation USB drive
   yourself.
5. Use **Export profile** / **Import profile** (JSON) to save and reuse settings. Passwords are left
   out of exports unless you tick "include passwords". **Reset to owner defaults** restores every
   decision.

## Owner defaults (highlights)

- English (US), Windows 11 Pro via its **generic installation key**. The key only selects the
  edition; it does not license or activate Windows.
- **Disk selection stays interactive.** The file contains no disk configuration at all.
- One local **Administrator** account with an **empty password** and **automatic sign-in**, with no
  Microsoft account. ⚠️ Anyone with physical access gets an administrator session, and
  BitLocker/device encryption does not prevent this. This is the requested default and is labelled
  in the UI.
- UAC on, "notify without dimming". Defender, Firewall, SmartScreen, Smart App Control and device
  encryption are untouched. System Restore is on.
- Maximum practical privacy: required diagnostic data only (the minimum on Pro), and advertising
  ID, tailored experiences, inking/typing, location, suggestions, Bing results, Copilot and Recall
  are off.
- Windows Update: download automatically, notify to install, no drivers via Windows Update.
- Fast Startup off, hibernation untouched, WER off, PowerShell `RemoteSigned`, Edge first-run,
  Startup Boost and background mode off.
- Explorer: extensions shown, opens to This PC. Left taskbar, search icon only, no Widgets.
  Recycle Bin is the only desktop icon. Custom Start folders.
- App removal with **Keep / Remove / Leave untouched** for each app (owner list applied). Wi-Fi is
  interactive. Scripts and extra XML are empty.
- **Windows Update automation (Phase 2), on.** After the first sign-in, a SYSTEM scheduled task
  installs all applicable updates. It restarts as needed (with a warning) and resumes, until none
  remain. Drivers follow the driver policy above, and feature updates are skipped. It stops after at
  most 10 restarts, 2 attempts per update, or 6 hours, and reports `Succeeded`,
  `CompletedWithFailures`, `Failed` or `Offline`. It is built only on documented Windows APIs. The
  scripts are also offered as separate downloads under **Review & download → Deployment assets**.
  ⚠️ **Not yet validated in a VM.**
- **Application provisioning (Phase 3), on but empty.** Six profiles (Everyday Essentials, Gaming,
  Developer / Power User, Laptop, Touchscreen / 2-in-1, Custom) start **empty**, and nothing is
  selected, so nothing is generated until you choose applications.
  - **Choosing applications:** combine profiles, add from a catalog of 48 apps whose WinGet
    identifiers were checked on 2026-10-19, or import a native `winget export` file.
  - **What happens on the PC:** after Windows Update has finished, a task running as the signed-in
    user (elevated) checks WinGet, installs each package once with its exact identifier and source,
    restarts when a package needs it, and records a result for every package.
  - **Additional Software:** records installers that WinGet does not cover, as a manual follow-up.
    Nothing is downloaded.
  - ⚠️ **Not yet validated in a VM.**

The full per-setting mapping is in [docs/settings-mapping.md](docs/settings-mapping.md) (generated
from code).

## Documentation

- [docs/implementation-plan.md](docs/implementation-plan.md): plan
- [docs/architecture.md](docs/architecture.md): engine, stages, staging of scripts, extension points
- [docs/settings-mapping.md](docs/settings-mapping.md): every setting with its pass/stage, XML/registry/policy, caveats and status
- [docs/testing.md](docs/testing.md): automated tests and the **WSIM/VM procedure**
- [docs/roadmap.md](docs/roadmap.md): later milestones
- [docs/upstream-attribution.md](docs/upstream-attribution.md): what was adapted, from which revision, and the deviations
- [docs/implementation-report.md](docs/implementation-report.md): what was built, tested and not tested, blockers
- [docs/samples/autounattend.sample.xml](docs/samples/autounattend.sample.xml): owner defaults with the name "Alex" (`npm run generate:sample`), and the update engine assets in [docs/samples/windows-update/](docs/samples/windows-update/)
- [docs/phase-2/review.md](docs/phase-2/review.md): Windows Update engine licensing and architecture review
- [docs/phase-2/implementation-report.md](docs/phase-2/implementation-report.md): what Phase 2 built, tested and left unverified
- [docs/phase-3/implementation-report.md](docs/phase-3/implementation-report.md): Phase 3 (WinGet) built, tested, limitations, next steps
- [docs/phase-3/orchestration.md](docs/phase-3/orchestration.md): stages, Windows Update / WinGet coordination, results, Phase 4 driver interface
- [docs/phase-3/profile-format.md](docs/phase-3/profile-format.md): builder profile JSON vs Microsoft's WinGet JSON
- [docs/phase-3/testing.md](docs/phase-3/testing.md): Phase 3 test coverage, read-only real-Windows checks and the VM checklist

## Not yet implemented

Manufacturer driver installation (Phase 4; the interface is defined in
`src/engine/drivers/contract.ts`), the ZIP bundle and `setup.ps1` orchestrator, automatic
execution of Additional Software installers, ISO/boot media editing, unattended disk formatting,
and background deployment. The profile records `deferred.installPowerShell7` as an extension point
only. To install PowerShell 7, select "PowerShell 7" under Application provisioning.
