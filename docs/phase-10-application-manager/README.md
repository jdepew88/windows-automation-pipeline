# Phase 10: Standalone Application Manager, WinGet GUI and software maintenance

**Windows Deployment — Application Manager** lets you browse the Windows Deployment Builder
catalog, see what is installed, and install, update and remove applications with WinGet. It runs on
a computer that is already set up: it needs no USB drive and no reinstallation.

| Milestone | Scope | Status |
|---|---|---|
| 10A | Catalog from the owner inventory, categories independent of profiles, profile review | Done ([catalog.md](catalog.md)) |
| 10B | Standalone manager: local agent, launcher, browsing, inventory, installation queue, profiles | Done |
| 10C | Update check, Update All Eligible, removal, history, reports, offline states | Done |

Deferred items are listed at the end. Fixes after the first real-world test (version 1.0.1): [fixes-2026-10-25.md](fixes-2026-10-25.md).

## Why a local agent plus a page

A website cannot run WinGet, and the builder site must not try (spec §6). Execution therefore
happens in a small PowerShell program on the computer itself, the **agent**
(`src/engine/manager/scripts/AppManager.ps1`). The interface is a second page of the existing Vite
build (`manager.html`, `src/manager/`). It reuses the builder's catalog, profiles, selection logic
(`resolveSelection`), logos and styles. No new framework and no desktop wrapper were added:

- Windows PowerShell 5.1 is on every Windows 10/11 computer, and the builder's engines already use it.
- The agent serves the page itself on `127.0.0.1`, so it works offline and needs no installation of
  a runtime.

```
Start menu shortcut ──> powershell.exe AppManager.ps1 (as the signed-in user)
                          │  TcpListener 127.0.0.1:<random port>
                          │  opens Edge in app mode: http://127.0.0.1:<port>/manager.html#<session key>
                          ▼
  manager.html (built page) ── fetch /api/* with X-WDB-Token ──> agent ──> winget.exe (one at a time)
```

The same `manager.html` is published on the builder site. There, without an agent, it is a
read-only catalog with a link to download the manager.

## Using it

1. In the builder, click **Application Manager**, then **Download the Application Manager (ZIP)**.
   You can also take `dist/downloads/windows-deployment-app-manager.zip` from a build.
2. Extract the ZIP and run `Install-AppManager.ps1` (right-click, *Run with PowerShell*). It checks
   every file against `files.json` (SHA-256) and copies the manager to
   `%LOCALAPPDATA%\Programs\WindowsDeploymentBuilder\AppManager`. It then adds **Windows Deployment —
   Application Manager** to *your* Start menu (`-Desktop` adds a desktop shortcut too). It needs no
   administrator rights and installs nothing for other users. `Start-AppManager.cmd` runs it from the
   folder without installing.
3. Start it from the Start menu. A minimised PowerShell window is the agent; closing it stops the
   manager. The agent also stops after 45 minutes without a page.

**Simulation mode is on for a new user.** Every action then shows the exact WinGet command and is
recorded as *Simulated*; nothing changes. Switch it off in the header when ready. Starting the agent
with `-DryRun` keeps simulation on regardless of the page.

### Dashboard

| Tab | What it does |
|---|---|
| Browse applications | The categorized catalog with search and filters (category, publisher, installation method, status, profile). Every application shows its status: installed with version, update available, not installed, detected by name only, or manual installer. Tick applications, or tick profiles, then **Review installation…**. |
| Installed | What WinGet and Windows report (`winget export` plus the uninstall records, read-only). Catalog matches show version, publisher, WinGet ID, update, source and removal support. Packages outside the catalog are listed and manageable by ID. Other Windows programs are listed but never removed from here. An unmatched program is never assumed to lack a WinGet package. |
| Updates | **Check for updates** (`winget source update`, then `winget upgrade --source winget`, both read-only), **Update selected…** and **Update All Eligible Applications…**. Each shows a preview and needs confirmation. |
| Profiles | Tick built-in and custom profiles to stack them. Save the selection as a profile; rename, delete, import or export profiles; undo your changes. Built-in definitions never change. |
| History & reports | Every operation with prior and resulting version, exit code, verification and retry. Export as CSV, HTML or JSON; retry failed items. |

## Security model (spec §14, §15)

- **Local only.** The agent listens on `127.0.0.1` on a random port. Every API call needs a
  64-hex-digit session key from a cryptographic RNG; the key is compared in constant time. The key
  travels in the address after `#`, so it is never sent in an HTTP request line; the page moves it
  to sessionStorage and clears it from the address bar. Requests are refused when:
  - the `Host` header is not `127.0.0.1:<port>` or `localhost:<port>` (DNS rebinding);
  - the `Origin` header names another origin;
  - `Sec-Fetch-Site` is `cross-site`.

  Responses carry a strict CSP, `nosniff`, `no-store` and `no-referrer`. Static files are served
  only by name from the `ui` folder.
- **The page cannot send commands.** It sends an action (`install`, `upgrade`, `uninstall`) and
  package specs. The agent re-validates each spec:
  - the WinGet or Store identifier pattern of the Phase 5 engine;
  - source `winget` or `msstore` only;
  - scope `user` or `machine`;
  - a version pattern.

  The agent then builds the arguments from a fixed list (`Get-WamArguments`). The TypeScript preview
  (`wingetArguments`) is tested to produce identical arguments.
- **Flags never used:** `--force`, `--ignore-security-hash`, `--ignore-local-archive-malware-scan`,
  `--include-unknown`, `--uninstall-previous`, `--purge`, `--all`, `--override`, `--custom`.
  - Updates are per package (`winget upgrade --id <id> --exact`), so every result is recorded and
    unknown versions are never included.
  - Installs use `--no-upgrade` and `--silent` (documented WinGet behaviour, no guessed installer
    switches).
- **Agreements.** `--accept-package-agreements` is passed only for a package whose licence the user
  ticked in the review. `winget show` reports whether a package has one. Source agreements are not
  accepted unless the user has enabled it (`settings.json`).
- **Privileges.** The agent:
  - runs as the signed-in user and refuses to run as SYSTEM;
  - never elevates itself and uses no UAC bypass.

  WinGet asks Windows for approval (UAC) only for installers that need it, so per-user installations
  stay per-user. The review shows the expected privilege per package from the catalog's scope.
- **No third-party repositories** are added; Scoop and Chocolatey are not used. Chocolatey GUI is
  excluded from the catalog (see [catalog.md](catalog.md)).
- **Removal safety.**
  - Never removable (blocked in the catalog and by name patterns in the agent): runtimes,
    frameworks, Windows components, Edge, WebView2, App Installer, Windows Terminal, drivers,
    Intel, AMD and NVIDIA packages.
  - Removable only one at a time, each with its own acknowledgement (`caution`): security
    software, VPNs, drivers, device and manufacturer software, services, virtualization and
    unknown packages.
  - Every removal needs the word **REMOVE**. WinGet runs the publisher's uninstaller; settings,
    application data and documents are left in place (no `--purge`).
  - Changing a profile never removes software.
- **History.** Passwords and tokens in installer output are redacted, and output is limited to
  2,000 characters per operation.

## Data (per user, `%LOCALAPPDATA%\WindowsDeploymentBuilder\AppManager`)

| File | Content |
|---|---|
| `history.jsonl` | One `windows-deployment-builder/app-manager-operation` v1 record per operation: timestamps, user, action, package ID, source, scope, prior and resulting version, exit code and its meaning, failure class, result, independent verification, restart, manual action, retryable, attempt, original operation, simulated, command, last output lines (redacted). |
| `profiles.json` | `windows-deployment-builder/app-manager-selection` v1: the selection and custom profiles (the builder's own schema, validated on load). |
| `settings.json` | `dryRun`, `acceptSourceAgreements`. |
| `inventory-cache.json`, `updates-cache.json` | The last scan and update check, shown while offline. |

Results:
- `Succeeded`, `AlreadyInstalled`, `UpToDate`, `RequiresRestart`;
- `ManualActionRequired` (cancelled, or the installer needs a person);
- `AgreementRequired`, `Unavailable`, `Cancelled` (UAC declined);
- `Uncertain` (the installer reported success but WinGet does not list the package);
- `Failed`, `Simulated`.

Exit codes are classified by the Phase 5 engine's table (`ConvertFrom-WdaExitCode`). After every
operation the agent checks `winget list --id <id> --exact` itself.

## Offline and unavailable

Installed applications, saved profiles, the cached catalog metadata, the last update check and
the history work without a network. These states are kept apart:

- not installed;
- not scanned yet;
- **network unavailable**;
- **source unavailable** ("this does not mean the package was removed");
- **not found in the source**;
- terms must be accepted;
- manual installer;
- unsupported identifier;
- detected by name only (uncertain).

A failed search during an outage is never reported as a removed package. The installation queue
starts only when every item was found in its source *now*.

## Compatibility with the deployment builder (spec §18)

- The wizard and the manager share `catalog.json`, `profiles.json`, `resolveSelection` and the
  profile file format. Exports from either import into the other.
- The deployment process is unchanged. The manager is not added to deployments; it is a separate
  download.
- The agent reuses, without copying them:
  - the Phase 5 exit-code table (`ApplicationEngine.ps1`);
  - the Phase 9 uninstall-record reader (`Get-WdhUninstallEntries` in `DeploymentHealth.ps1`);
  - the shared JSON helpers (`DeploymentCommon.ps1`).

  These are packaged in `lib/`.
- Phase 9 health verification runs unchanged; its suites pass. Applications removed later with
  the manager appear in a later health report as missing, which is correct.

## Tests

| Suite | What it covers |
|---|---|
| `tests/unit/catalog-phase10.test.ts` (19) | Every CSV row is an exact catalog ID, an alternate ID or a reasoned exclusion; nothing invented; categories independent of profiles; stacking and dedup; profile contents; maintenance metadata. |
| `tests/unit/manager.test.ts` (11) | Policy; detection by ID, alternate ID and name; command generation and refusal; installation queue preview (stacking, already installed, manual, agreements, validation gating); removal rules; result summary. Also runs the agent suite and checks argument and protected-pattern parity with the agent. |
| `tests/powershell/AppManager.Tests.ps1` (25) | The agent against a simulated WinGet: arguments and refused flags; spec validation (injection); WinGet table parsing (explicit table, summary lines, truncation); version comparison and eligibility; inventory; update check; offline; validation states; queue order and per-package failures; retry; restart, cancel, declined UAC, agreements, hash mismatch, false success; simulation mode and its default; upgrade versions; removal rules; cancel; redaction; CSV, HTML and JSON reports; HTTP host, origin, token and static-path checks; profile persistence; SYSTEM guard; launcher integrity and uninstall; a real listener on 127.0.0.1. |
| `tests/e2e/manager.spec.ts` (15 × 3 widths) | The page against a mock agent: not-connected mode and the ZIP's contents; builder link; wrong key; filters; stacking and persistence; install review (validation, agreements, failures, retry); not found and offline; simulation; Update All Eligible and individual updates; removal rules; profile changes never remove; history exports; offline; tabs, accessible names and no horizontal scroll at phone width. |
| `tests/e2e/manager-agent.spec.ts` (2) | The **packaged ZIP** end to end: the real agent serves the built page with its CSP, scans, simulates, installs, verifies, checks updates and records history. WinGet is replaced by `tests/powershell/FakeWinGet.cmd`. |

Nothing in the tests runs the real WinGet or changes the development computer.

## Deferred (not implemented)

- **Including the manager in the deployment USB package** as an opt-in post-installation tool
  (spec §18 allows it; today it is a separate download).
- **Hardware-aware suggestions** for device software. The catalog records the hardware each
  application needs, and the page shows it. Matching against detected devices (Phase 8 data) is not
  done; the manager never suggests or installs device software because of detected hardware.
- **Local verified installers** (official offline installers with a verified unattended method)
  and **VMware Workstation Pro** automation. Broadcom requires a signed-in download, so VMware stays a
  manual entry with instructions.
- **Microsoft Store update checks** run only after the user enables source agreements.
- **Localized WinGet output.** Tables are parsed by position, so localized column titles work. Version
  lines in `winget show` are read only from English output; availability still comes from the exit code.
- **Real-hardware validation.** Everything was tested against simulated and fake WinGet only. As the
  spec requires, nothing was installed on the development PC. The UAC prompt for machine-wide
  installers and Edge app mode should be checked once on a test computer.
