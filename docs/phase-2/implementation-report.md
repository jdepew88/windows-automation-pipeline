# Implementation report: Phase 2 (Windows Update automation)

Branch: `feature/phase-2-windows-updates`. Design and licensing: `review.md`.

## Owner decisions (2026-10-19)

- Build independently on documented Windows APIs. **No AutoPatch code and no PSWindowsUpdate.**
- Engine **enabled** in the owner defaults.
- One read-only Windows Update scan allowed on the development PC.

## Built

- **Engine** (`src/engine/windows-update/scripts/WindowsUpdateEngine.ps1`, Windows PowerShell 5.1,
  no dependencies):
  - **Instance and state:** single-instance mutex; persistent `state.json` with atomic writes, and a
    corrupt state file is kept aside.
  - **Before scanning:** bounded network wait (NCSI probe, TCP fallback, or the WSUS server when
    one is configured); waits while the Windows Update installer is busy.
  - **Updates:** Windows Update Agent search, download and install with per-update results and
    HResults; EULA acceptance; quiet installs.
  - **Policy:** drivers by type, feature updates by the `Upgrades` category, optional updates by
    `BrowseOnly`; updates that need user input are never attempted; KB exclusions.
  - **Loop protection:**
    - attempts are counted per update before each try, so crashes count;
    - re-offered or failing updates are given up after N attempts;
    - one Microsoft-documented component reset adds one more attempt;
    - a confirmation scan runs before declaring success.
  - **Limits:** restarts, total runtime, unexpected errors, and 50 passes per start.
  - **Restarts:** `shutdown.exe /r /t <warning>` with a visible reason; a pending restart is honoured
    even when nothing is left to install.
  - **Final states:**
    - `Succeeded`, `CompletedWithFailures`, `Failed` or `Offline` in `result.json`, listing
      installed, failed (KB, attempts, last result and HResult) and skipped updates with reasons;
    - Application events 1000/1001/1100–1103;
    - live `status.json`;
    - `engine.log` with timestamped steps (rotated at 5 MB);
    - the completion marker `C:\ProgramData\WindowsDeploymentBuilder\state\windows-update.done`
      for the orchestrator, written only for `Succeeded` and `CompletedWithFailures`;
    - the scheduled task removes itself.
  - **`-Mode Scan`:** read-only preview; needs no elevation and writes nothing.
- **Installer** (`Install-UpdateEngine.ps1`):
  - requires elevation;
  - locks `C:\ProgramData\WindowsDeploymentBuilder` with SID-based ACLs (SYSTEM/Administrators full
    control, Users read), and refuses to continue if that fails;
  - archives a previous run;
  - registers `\WindowsDeploymentBuilder\WindowsUpdate`: SYSTEM, at startup + 2 min, hourly retry
    for 7 days, `IgnoreNew`, a time limit and restart-on-failure;
  - starts it and waits for the engine to check in, reporting an error instead of a false success;
  - `-Uninstall` and `-NoStart` switches.
- **Answer file:** when enabled, the three files are embedded and extracted during specialize to
  `C:\Windows\Setup\Scripts\WindowsUpdate`. The installer is the **last** FirstLogon command, after
  every Milestone 1 step. With the engine **off**, the output is byte-identical to Milestone 1.
- **Profile schema v2:** a new `windowsUpdate` section. The v1→v2 migration turns the engine **off**
  for profiles saved by Milestone 1, with a notice, so they keep producing the same XML.
- **Web UI:** a "Windows Update automation" section.
  - Basic view: enable, drivers, feature updates.
  - Advanced view: optional updates, Microsoft Update, limits, component reset, restart warning,
    KB exclusions.
  - Field-level validation: ranges, KB format, and "include drivers" against the M1 driver policy.
  - A summary row, and a **Deployment assets** panel to preview and download
    `WindowsUpdateEngine.ps1`, `Install-UpdateEngine.ps1`, `config.json` and
    `README-WindowsUpdate.txt`. Everything is generated in the browser, so the app still works
    offline.
- **Docs:** this report, `review.md`, architecture, the testing procedure (section C), the settings
  mapping (regenerated, 131 settings), README, roadmap, upstream attribution, and the samples in
  `docs/samples/windows-update/`.

## Tested

| Check | Result |
|---|---|
| `npm run typecheck`, `npm run lint` | clean |
| `npm test` | 148 Vitest tests in 11 files pass, including the PowerShell parse check of every generated `.ps1` and the engine scenario run |
| `npm run test:ps` | 22/22 engine scenarios pass against a simulated Windows Update Agent (see `testing.md`) |
| `npm run test:e2e` | 20/20 (10 scenarios × desktop and mobile Chromium) |
| `npm run build` | passes |
| Milestone 1 preservation | Engine off: XML byte-identical to the published M1 sample. M1 (v1) profile imports and generates the same XML. Snapshot diffs for the owner default contain additions only |
| Real Windows, read-only | `WindowsUpdateEngine.ps1 -Mode Scan` on the development PC (Windows 11 Insider 26220, not elevated): 2 applicable updates found (Insider quality update, .NET security update), pending restart detected correctly, 11 s. **Nothing downloaded or installed** |

The scenario tests found two real defects, both fixed:
- HResults were formatted as 64-bit values (`0xFFFFFFFF80240016`).
- The "error limit" scenario showed that an install that crashes repeatedly is reported as a
  given-up update (`CompletedWithFailures`) rather than an engine failure. That behaviour is now
  intended and has its own test.

## Not tested / unverified

- **Downloading, installing, restarting and resuming on a real installation.** Not run: this would
  modify the development PC. Use the VM procedure in `testing.md` C.
- **Task Scheduler registration as SYSTEM, ACL hardening, and the check-in wait** on a fresh
  install. These are exercised only by reading the code and by the parser check.
- **FirstLogon timing:** that the engine starts only after FirstLogon.ps1 and the UserOnce
  scripts. RunOnce entries may still be running when the first update restart happens. The
  60-second initial delay plus the restart warning are expected to cover it, but this is not
  observed.
- **Feature updates:** whether "skip" also holds back enablement packages on 24H2/25H2.
- **Microsoft Update service registration** (off by default).
- Milestone 1 itself is still not validated in a VM.

## Known limitations

- If a machine never gets a network connection within `maxRuntimeHours`, the engine ends `Offline`
  and does not retry later. Run `Install-UpdateEngine.ps1` again to start a new run.
- The engine restarts the PC while the auto-logon session is active. Anything left open in that
  session is closed after the warning.
- Progress is shown only in `status.json` and `engine.log`. There is no on-screen viewer.

## Not started

Phase 3 (WinGet) and the ZIP bundle / `setup.ps1` orchestrator. The orchestrator contract is
ready: the completion marker and `result.json`.
