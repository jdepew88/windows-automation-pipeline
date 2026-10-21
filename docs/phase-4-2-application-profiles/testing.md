# Testing (Phase 4.2)

Status: **implemented and covered by automated tests and simulations; not validated on a
Windows installation in a VM or on physical hardware.** Nothing was installed on the development
computer: verification used only `winget search` / `winget show` and the engine's read-only Plan
mode.

## Automated results (2026-10-21, commit of this phase)

| Suite | Result |
|---|---|
| `npm run typecheck`, `npm run lint` | clean |
| Vitest (`npm test`, 16 files, includes parsing every generated `.ps1` and the Windows Update scenarios) | 355 passed |
| `Engine.Tests.ps1` (Windows Update, simulated) | 25 / 25 |
| `Applications.Tests.ps1` (application engine 1.1.0, simulated WinGet) | 57 / 57 (45 from Phase 3 + 12 new) |
| `Deployment.Tests.ps1` (Phase 4 orchestrator against the real generated ZIP) | 25 / 25 |
| Playwright (desktop, tablet 820×1180, mobile Pixel 7) | 82 passed, 2 skipped (the mobile-drawer test runs on mobile only) |
| `npm run build` | OK |

### New coverage

* `tests/unit/app-profiles.test.ts` (59 tests): catalog integrity (unique ids/keys, categories,
  https links, counts per method, every identifier present in the recorded verification, official
  Store publishers, manual and portable metadata, exclusions, dependencies); every built-in profile;
  Core Essentials removals surviving profile switches; Gaming with Epic unticked; Network Engineer's
  full list; Music not ticking every player; no duplicates across all profiles and devices; all
  device combinations including Android + iPad; overrides, restore and resets; dependency removal
  warnings; saved profiles ("Aunt's Computer"), duplicates of built-ins, hostile names; the browser
  library (reload, reset, explicit delete, nothing secret stored, corrupt data, blocked storage);
  Avast+AVG, Avast+Avira, AVG+Avira blocking, single antivirus notes, Malwarebytes warnings; VPN,
  sync and download tools carrying no configuration; hostile imports (command text, URLs, path
  traversal, unknown members, prototype keys); custom IDs as data; config ↔ UI ↔ ZIP ↔ manifest
  consistency; every config field read by the engine; non-ASCII escaping; genuine Phase 4 (schema
  v3) exports importing without behaviour change (and the Milestone 1 XML byte for byte).
* `Applications.Tests.ps1`, new scenarios: portable install with `--scope machine` and a shortcut to
  the versioned file; already-installed portable (no reinstall, no duplicate shortcut); Ventoy's
  top-level file preferred; missing executable reported for follow-up; **junctions never followed**;
  unsafe patterns, shortcut names and scopes refused before WinGet; mixed WinGet + Store + portable
  plan; manual follow-ups and deselected apps recorded and never sent to WinGet (unsafe URL and
  invalid key ignored); deselected-only deployment is still `Succeeded`; dependency order and an
  already installed runtime; a 1.0.0-format configuration; Plan mode rows.
  A mutation check (junction guard and portable validation removed) made the two safety scenarios
  fail, so they test what they claim.
* Deployment suite fixture now carries every method (WinGet, Store via an iPhone, portable Rufus,
  manual RustDesk) and asserts that every embedded file, including the non-ASCII application
  config, is verified by exact text hash and decodes identically from the answer-file copy and the
  ZIP copy.
* Playwright: Core Essentials default; quick start (Gaming, untick Epic, add a PDF reader, download
  the ZIP and compare its config with the plan); Android + iPad; antivirus locking in the UI and
  blocking after an import; Network Engineer; Save as new profile surviving a reload, re-applying,
  rename, export, delete; WinGet import/export; Advanced ordering and custom IDs (including an
  excluded app); selection surviving navigation, Basic/Advanced, export/import and reset. All on
  three viewport sizes; screenshots checked in dark and light themes with no horizontal overflow.

### Read-only checks on this Windows computer

* The engine's `-Mode Plan` against the generated mixed package with the real WinGet 1.29.250:
  WinGet healthy; installed apps reported as `AlreadyInstalled (skip)`; Apple Devices resolved from
  the Store; Rufus shown as `Install (portable) + shortcut Rufus`; the test-only id `Unavailable`;
  RustDesk as `Manual action required`. Nothing installed.

## Regression against Phase 4 (`6f59166`)

Generated with both versions side by side:

| Configuration | Answer file | Other files |
|---|---|---|
| Windows Update off, no applications | byte-identical (also equal to the Milestone 1 fixture) | identical |
| Phase 4 owner default (Windows Update on, no applications) | differs only by the manifest's `generator.applicationEngine` version string (1.0.0 → 1.1.0) | `profiles/windows-settings.json` (schema 4) |
| Applications selected | differs in `ApplicationEngine.ps1` (1.1.0), `applications-config.json` (new fields), the manifest | plan, README, results schema, `profiles/applications.json` |

The new owner default (Core Essentials) intentionally changes the default answer file: it now
embeds the application engine. The three owner-default snapshots were updated for that reason.

## Defects found and fixed during this phase

1. **StrictMode crash (engine 1.1.0, found by the 45 existing scenarios):** Windows PowerShell 5.1
   with `Set-StrictMode -Version 2.0` throws when a missing hashtable key is read with dot syntax.
   The new `method`/`portable` reads failed for every configuration without those keys, so every
   run ended in `Error`. Fixed with `ContainsKey` checks (also for `url` and `shortcutFailed`).
2. **Non-ASCII names garbled in the ZIP copy (pre-existing since Phase 3):** the engine reads its
   config with `Get-Content`, which decodes BOM-less UTF-8 as ANSI. The answer-file copy is ANSI,
   the ZIP/`setup.cmd` copy UTF-8, so "Zoë" became "ZoÃ«" in results when started from the USB
   folder. The config is now written with `\uXXXX` escapes, identical for ASCII text.
3. A saved profile could reproduce the same apps in a different order (its additions now come before
   device recommendations); the reproduction check compares the set of apps.

## Not tested: needs a disposable VM, then hardware

Run together with the Phase 4 checklist (`../phase-4-usb-deployment/testing.md`):

- [ ] Owner default: Core Essentials installs; Visual C++ already present is skipped; RustDesk is
      listed as a manual action in the report and `follow-up.txt`.
- [ ] Store packages without a Microsoft account (Apple Devices, WhatsApp) install through the
      engine's user task; behaviour with the Store app removed or blocked by policy.
- [ ] Portable: Rufus, Ventoy, Syncthing and BatteryInfoView land in `%ProgramFiles%\WinGet\Packages`
      and get working Start menu shortcuts; nothing is executed; a second run creates no duplicates.
- [ ] Antivirus from the Store listings (Avast/AVG/Avira) installs silently or reports
      `RequiresInteraction`; Defender switches to passive mode by itself; no bundled offers accepted.
- [ ] Malwarebytes: whether a Premium trial with real-time protection starts.
- [ ] Docker Desktop after WSL, with the restart policy; HandBrake after .NET Desktop Runtime 8.
- [ ] Claude Code (`claude --version` in a new terminal), Claude Desktop, ChatGPT (Store), Cursor.
- [ ] Network Engineer profile end to end (about 40 packages) within the runtime limit; whether
      `maxRuntimeHours` (4 h default) is enough on a slow connection.
- [ ] Tailscale, WireGuard, Syncthing, qBittorrent and SABnzbd: installed, not signed in, no tunnel,
      no shared folder, no listener reachable from the network.
- [ ] Arm64 hardware: x64-only packages (TeraCopy, Steam, …) under emulation.
