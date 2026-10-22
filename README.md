# Windows Deployment Builder (Milestone 1 + Phase 2 Windows Update + Phase 3 WinGet provisioning + Phase 4 USB deployment + Phase 4.2 application profiles + Phase 4.3 Quick Deployment)

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

Everything runs locally in the browser, including on the deployed site. Nothing is uploaded, no script runs in the browser, and the
configuration is not saved automatically. Only application profiles you save with "Save as new profile…" are kept in this
browser's local storage (no names or passwords); export them for a backup.

## Using it

**Quick Deployment** (the default view) asks only what changes between customers, in five steps:
computer & local account, computer & customer type (Everyday, Gamer, Developer, Network Engineer /
Developer / Technician, Music, Laptop, Touchscreen, plus phones and tablets), network (Wi-Fi is
skipped unless you enter an SSID and password), applications (logo grid, logos only, compact or
detailed list), and **Final Review & Considerations**, where you confirm the relevant risks and
generate the ZIP. Next/Back sit at the top and the bottom; *Go to Applications* skips steps that are
fine as they are; nothing invalid gets past a step. **Advanced Configuration** (header switch) is the
full set of pages below; both edit the same configuration, so you can switch at any time.

In Advanced Configuration:

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
- Windows Update: download automatically, notify to install, no drivers via Windows Update. With
  the update automation on, this policy is applied after the initial updates have finished
  (Phase 4.3), not on Windows Home and never over domain/MDM/WSUS policy.
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
- **Application provisioning (Phases 3 and 4.2), on, with Core Essentials.** Every new deployment
  installs Google Chrome, VLC, 7-Zip, TeraCopy, Bitwarden and the Visual C++ runtimes; RustDesk is
  listed as a manual step because it has no WinGet or Store package. Each of them can be unticked.
  - **Choosing applications:** tick profiles (Everyday Essentials, Gaming, General Developer,
    Network Engineer / Developer / Technician, Music Enthusiast, Laptop, Touchscreen), answer the
    mobile-device questions (an iPhone or iPad adds Apple Devices), then tick or untick single apps
    from a catalog of 115 apps verified on 2026-10-21, or add any exact WinGet/Store ID.
  - **Saved profiles:** "Save as new profile…" keeps a selection (for example "Aunt's Computer") in
    this browser; export it as JSON for a real backup or another computer.
  - **Installation methods:** WinGet, Microsoft Store, portable tools (Rufus, Ventoy, … installed
    machine-wide with a Start menu shortcut, never run) and manual follow-ups that are never
    reported as installed. Only one real-time antivirus can be selected.
  - **What happens on the PC:** after Windows Update has finished, a task running as the signed-in
    user (elevated) checks WinGet, installs each package once with its exact identifier and source,
    restarts when a package needs it, and records a result for every package.
  - **Additional Software:** records installers that WinGet does not cover, as a manual follow-up.
    Nothing is downloaded.
  - ⚠️ **Not yet validated in a VM.**
- **USB deployment package (Phase 4).** **Deployment package** (or **Review & download**) builds
  `windows-deployment-package.zip` in the browser: `autounattend.xml` for the root of an ordinary
  Windows 11 installation USB drive plus a `WindowsDeployment` folder (manifest with SHA-256 of
  every file, `setup.cmd`, orchestrator, both engines, profiles, docs).
  - **Installation:** Setup still stops at disk selection; you choose the disk.
  - **First sign-in:** the orchestrator verifies the embedded files, starts Windows Update (SYSTEM)
    and the applications (signed-in user) once each, follows them across restarts, shows progress,
    and writes a deployment report. The USB drive is not needed after Setup.
  - Guides: [USB preparation](docs/phase-4-usb-deployment/usb-preparation.md),
    [recovery](docs/phase-4-usb-deployment/recovery.md).
  - ⚠️ **Tested with simulations only; not yet run in a VM or on hardware.**

The full per-setting mapping is in [docs/settings-mapping.md](docs/settings-mapping.md) (generated
from code).

## Quick start (Quick Deployment): a gaming laptop in a few clicks

1. Open the site: Quick Deployment starts at **Computer & local account**. Type the account name
   (for example `Sam`); the computer name `Sam-Computer` follows (type your own to override).
2. **Next**: tick **Gamer** and **Laptop**; answer the phone question if relevant.
3. **Go to Applications**: Steam and the Epic Games Launcher are ticked. Click a tile to untick or
   add an app; switch layouts with Logos / Grid / Compact / Detailed.
4. **Final Review**: check the summary, confirm the administrator-without-password consideration,
   and **Generate Deployment ZIP**. Extract it to a Windows 11 installation USB drive.

## Quick start (Advanced Configuration): a gaming PC with a PDF reader, on a USB drive

1. Open the site. Enter the customer's name under **Account & computer name**.
2. Go to **WinGet applications**. Core Essentials is already ticked.
3. Under **Profiles**, tick **Gaming**. Steam and the Epic Games Launcher are ticked; Battle.net, EA
   app, Discord and the others appear unticked as recommendations.
4. The customer only uses Steam: untick **Epic Games Launcher**. It is marked "Unticked by you" and
   the Gaming profile itself stays unchanged.
5. Type `pdf` in the search box and tick **Adobe Acrobat Reader**.
6. If the customer has an iPhone, choose **iPhone** under **Mobile devices & ecosystem**; Apple
   Devices is ticked automatically.
7. Check **Installation plan** on the right: it lists exactly what will be installed, in order, plus
   the manual follow-ups (RustDesk) and what you unticked.
8. Optional: **Save as new profile…** to reuse this selection for the next computer.
9. Go to **Deployment package** and download `windows-deployment-package.zip`. Extract it to the root
   of a Windows 11 installation USB drive ([how](docs/phase-4-usb-deployment/usb-preparation.md)).
   The ZIP's application plan is the one you saw on screen.

⚠️ Application installation from a real USB drive has not been tested in a VM or on hardware yet.

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
- [docs/phase-4-usb-deployment/architecture.md](docs/phase-4-usb-deployment/architecture.md): audit, staging method, package layout, manifest, orchestration, restarts
- [docs/phase-4-usb-deployment/implementation-report.md](docs/phase-4-usb-deployment/implementation-report.md): Phase 4 built, answer-file changes, defects found, limitations
- [docs/phase-4-usb-deployment/testing.md](docs/phase-4-usb-deployment/testing.md): Phase 4 coverage, regression results, VM/hardware checklist
- [docs/phase-4-usb-deployment/usb-preparation.md](docs/phase-4-usb-deployment/usb-preparation.md): preparing the USB drive (Media Creation Tool, Rufus, manual copy)
- [docs/phase-4-usb-deployment/recovery.md](docs/phase-4-usb-deployment/recovery.md): progress, logs, recovery commands
- [docs/phase-4-2-application-profiles/catalog.md](docs/phase-4-2-application-profiles/catalog.md): catalog schema, source verification, installation methods, portable tools, security software, runtimes
- [docs/phase-4-2-application-profiles/profiles.md](docs/phase-4-2-application-profiles/profiles.md): built-in profiles, devices, selection rules, saved profiles, browser storage, JSON formats
- [docs/phase-4-2-application-profiles/testing.md](docs/phase-4-2-application-profiles/testing.md): test results, regression against Phase 4, VM/hardware checklist
- [docs/phase-4-2-application-profiles/implementation-report.md](docs/phase-4-2-application-profiles/implementation-report.md): what Phase 4.2 changed, engine 1.1.0, ZIP integration, limitations
- [docs/phase-4-3-quick-deployment-wizard/architecture.md](docs/phase-4-3-quick-deployment-wizard/architecture.md): Quick Deployment and Advanced Configuration on one configuration, wizard flow, defaults, Final Review, persistence
- [docs/phase-4-3-quick-deployment-wizard/wifi.md](docs/phase-4-3-quick-deployment-wizard/wifi.md): Wi-Fi provisioning and the credential security model
- [docs/phase-4-3-quick-deployment-wizard/windows-update.md](docs/phase-4-3-quick-deployment-wizard/windows-update.md): initial updates vs the ongoing policy, ordering, outcomes
- [docs/phase-4-3-quick-deployment-wizard/catalog-and-icons.md](docs/phase-4-3-quick-deployment-wizard/catalog-and-icons.md): the four catalog layouts and logo sources
- [docs/phase-4-3-quick-deployment-wizard/testing.md](docs/phase-4-3-quick-deployment-wizard/testing.md) and [implementation-report.md](docs/phase-4-3-quick-deployment-wizard/implementation-report.md)

## Not yet implemented

Manufacturer driver installation (a later phase; the interface is defined in
`src/engine/drivers/contract.ts` and the orchestrator reports the stage as not implemented), PXE or
network delivery, automatic execution of Additional Software installers, ISO/boot media editing,
unattended disk formatting, and customer data restoration. The profile records `deferred.installPowerShell7` as an extension point
only. To install PowerShell 7, select "PowerShell 7" under Application provisioning.
