# Windows Deployment Builder (Milestone 1)

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
npm test           # unit and snapshot tests
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
- [docs/samples/autounattend.sample.xml](docs/samples/autounattend.sample.xml): owner defaults with the name "Alex" (`npm run generate:sample`)

## Not in Milestone 1

WinGet packages, application installation, the ZIP bundle and `setup.ps1` orchestrator, ISO/boot
media editing, unattended disk formatting, and background deployment. The profile records
`deferred.installPowerShell7` and an empty `deferred.wingetPackages` as extension points only.
