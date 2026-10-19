# Phase 2: licensing and architecture review (Windows Update engine)

Status: review completed and **approved by the owner on 2026-10-19** with these decisions:
- independent implementation (no AutoPatch code, no PSWindowsUpdate);
- engine **on** in the owner defaults;
- one read-only scan allowed on the development PC.

The implementation follows this document. See `implementation-report.md` for what was built and
tested.
Reviewed: `ps1xml/AutoPatch` at commit `4eab0cf` (2026-07-23), and the module it bundles,
`PSWindowsUpdate` 2.2.1.5 (`mgajda83/PSWindowsUpdate`).

## 1. Licensing

### AutoPatch (`ps1xml/AutoPatch`)

| Item | Finding |
|---|---|
| Repository root | Contains only `README.md`, `DEPLOY-AutoPatch-v8.7.3.source.ps1` and `AutoPatch.zip`. **There is no LICENSE file at the root.** GitHub detects no license (`licenseInfo: null`). |
| README | Ends with "## License / MIT." |
| `AutoPatch.zip` → `autopatch/LICENSE` | Standard MIT text, but the notice reads **`Copyright (c) 2026` with no copyright holder named**. |
| Source header | No license or copyright header. |
| History | Three commits, all on the day the repository was created. One unnamed author (`ps1xml`), no stars, no releases. |

**Assessment.** The intent is clearly MIT, and an MIT grant without a named holder is still a grant.
However:
- the license sits inside an archive rather than at the root;
- the holder is anonymous;
- the repository is a day-one upload with no track record.

Copying code would mean reproducing an attribution notice that names no one, from a source whose
provenance cannot be checked. This is a **weak but not disqualifying** license position.

### PSWindowsUpdate 2.2.1.5 (bundled inside AutoPatch as a base64 zip)

| Item | Finding |
|---|---|
| GitHub repository | MIT `LICENSE`, "Copyright (c) 2022 Michal Gajda". |
| Module manifest (`PSWindowsUpdate.psd1`) | `Copyright = '(c) 2011-2024 Michal Gajda. All rights reserved.'` and `LicenseUri` pointing to that MIT file. **The two statements conflict.** |
| Source | The repository publishes only a **compiled `PSWindowsUpdate.dll`** (plus help/format files). **No C# source is published.** |

**Assessment.** Redistributing it is probably allowed under the MIT file. But the work would then
ship a 360 KB closed-source binary, run as SYSTEM, base64-embedded in a generated file, under a
conflicting copyright statement. That is a supply-chain and auditability problem as much as a
licensing one, and it would also bloat every answer file.

### Recommendation

**Do not copy AutoPatch code. Do not bundle PSWindowsUpdate.** Implement the engine independently in
PowerShell 5.1, using the documented **Windows Update Agent (WUA) COM API**:
- `Microsoft.Update.Session`, `IUpdateSearcher`, `IUpdateDownloader`, `IUpdateInstaller`;
- `ISystemInformation.RebootRequired`;
- update categories by GUID.

Use the inbox `ScheduledTasks` module for persistence, plus `System.Threading.Mutex`. This needs **no
third-party dependency at all.**

Functional ideas reused from AutoPatch are not copied expression, and none is specific to it:
- a single-instance mutex;
- a startup scheduled task that resumes after reboot;
- a fingerprint of the offered update set to detect re-offer loops;
- a status JSON file;
- a one-time Windows Update component reset.

They will be credited as design inspiration in `docs/upstream-attribution.md`. No code will be copied.

## 2. What AutoPatch does, and what we keep, change or drop

| AutoPatch behaviour | Decision |
|---|---|
| Deep Freeze thaw check (`DFC.exe`), "freeze safety" rationale | **Drop entirely**, as required. |
| RMM deploy flow (paste into RMM, run as SYSTEM, wait 45 s for check-in) | **Replace.** The engine is staged by the answer file and started at the end of FirstLogon. The start-up check-in idea is kept. |
| Bundled PSWindowsUpdate, NuGet/PSGallery fallback | **Drop.** Use the WUA COM API directly, with no download and no prompt. |
| `C:\autopatch` with icacls hardening | **Keep the hardening idea, change the location.** Use `C:\ProgramData\WindowsDeploymentBuilder\Updates\` with SID-based ACLs: SYSTEM and Administrators full control, Users read. By default, `ProgramData` lets Users create files, and the folder is executed as SYSTEM. |
| Startup task as SYSTEM that resumes the scanner | **Keep** (required). Add a boot-delay, a retry-on-failure setting, and an execution time limit. |
| Global mutex for a single instance | **Keep.** Also wait while `IUpdateInstaller.IsBusy` is true (Windows' own automatic updates may be installing). |
| Feature-update filtering by **title substrings** ("25H2", "26H1"…) | **Replace** with WUA category GUIDs (`Upgrades`) plus `DeploymentAction`. Title matching breaks with every release name. |
| Drivers "always included" | **Make configurable** (see §4). It must stay consistent with the M1 `updates.excludeDrivers` policy. |
| Same set re-offered 3× → reset datastore and reboot; 6× → give up | **Keep the concept, make it per-update.** Track attempts per update ID and HResult. Exclude an update after N failed attempts. Reset WU components at most once, as an option. |
| 30-minute idle window with a scan every 2 minutes before "complete" | **Shorten and make configurable.** One confirmation re-scan after a clean scan (default 1, configurable). |
| No reboot limit | **Add one**: maximum reboots (default 10) and a maximum total run time. Then stop with status `Failed`. |
| Success only implied by self-cleanup | **Replace** with explicit final states: `Succeeded`, `CompletedWithFailures`, `Failed`, `Offline`. These are written to a result file and the Application event log. |
| WinForms live viewer | **Defer.** The log and status JSON are enough for Phase 2. A viewer can come later. |
| `Restart-Computer -Force` | **Keep forced restart**, but log first and use `shutdown.exe /r /t 60 /c "<reason>"` so the signed-in user sees a warning. |

## 3. Proposed architecture

```
autounattend.xml  (M1 output, unchanged unless the engine is enabled)
  <Extensions><File>  WindowsUpdateEngine.ps1, wu-config.json   ← embedded like other M1 scripts
  specialize:  extract files → C:\ProgramData\WindowsDeploymentBuilder\Updates\, set ACLs
  FirstLogon:  …existing M1 steps… → LAST: register task "WDB-WindowsUpdate", start it, wait for check-in

WindowsUpdateEngine.ps1 (SYSTEM, scheduled task: at startup + on demand)
  acquire Global\WDB-WindowsUpdate mutex ─ else exit
  load config + state.json  (attempt counters, reboot count, excluded IDs, phase, start time)
  enforce limits (reboots, total runtime) ─ exceeded → Failed
  wait for network (NCSI probe + TCP to WU endpoints, bounded) ─ timeout → Offline (task retries at next boot)
  wait while IUpdateInstaller.IsBusy (bounded)
  loop:
    search  "IsInstalled=0 and IsHidden=0" (+ Type filter for drivers)
    filter  feature upgrades (category GUID), interactive updates, user-excluded/failed-out IDs
    none →  confirmation re-scan → final state → signal orchestrator → unregister task
    accept EULAs → download (per update, record results) → install (per update, record HResult)
    failures → bump per-update counters → exclude after N
    reboot required (installer result or ISystemInformation) → save state → reboot → task resumes
```

**Completion signal to the deployment orchestrator.** The orchestrator is the Milestone 3
`setup.ps1`, which does not exist yet. The engine therefore publishes a stable contract that the
orchestrator can read later:
1. `C:\ProgramData\WindowsDeploymentBuilder\Updates\result.json` with fields `status`, `startedAt`,
   `finishedAt`, `reboots`, `installed[]`, `failed[]` (KB, title, HResult, attempts) and
   `skipped[]` (reason).
2. A marker file, `C:\ProgramData\WindowsDeploymentBuilder\state\windows-update.done`, written only on
   `Succeeded`/`CompletedWithFailures`.
3. An Application event-log entry: source `WindowsDeploymentBuilder`, distinct event IDs per final
   status.

Phase 3 can then wait on the marker without depending on engine internals.

**Generated assets.** The TS engine renders the scripts from templates. The web app shows them and
offers each file for download individually:
- `WindowsUpdateEngine.ps1`;
- `wu-config.json`;
- `Install-UpdateEngine.ps1`, for manual or RMM use on an already-installed machine.

When the feature is enabled, the same files are also embedded in `autounattend.xml`, so the single
answer file keeps working on its own. A ZIP bundle stays in Milestone 3. Everything is generated in
the browser, so the app stays offline.

**Web UI.** A new "Windows Update automation" section:
- Basic view: enable, and the driver and feature-update policy.
- Advanced view: limits (reboots, attempts per update, runtime, network wait), confirmation scans,
  component reset, exclusions by KB.

It gets a script preview and download buttons, and validation against the existing M1 update
settings.

**Profile.** Schema v2 adds a `windowsUpdate` section. A migration from v1 inserts defaults, so all
M1 profiles still import. With the feature disabled, generated XML must be byte-identical to M1. That
is enforced by the existing snapshots.

## 4. Policy options to decide

| Option | Proposed values | Proposed owner default |
|---|---|---|
| Engine enabled | on / off | **off** until VM-validated, *or* on. Owner decision |
| Drivers | follow M1 policy (`excludeDrivers` → skip drivers) / include drivers / exclude drivers | follow M1 policy (= exclude, since M1 excludes drivers) |
| Feature updates (e.g. 24H2→25H2) | skip / allow | **skip** |
| Microsoft Update (Office and other Microsoft products) | off / on (registers service `7971f918-a847-4430-9279-4a52d1efe18d`) | off |
| Optional / preview updates | skip / include | skip |
| Max reboots | 1–30 | 10 |
| Failed attempts before an update is given up | 1–5 | 2 |
| Max total runtime | 1–24 h | 6 h |
| Network wait per start | 1–60 min | 15 min, then `Offline`; retried at next boot up to the reboot limit |
| One-time WU component reset when an update keeps failing | on / off | on |
| Reboot warning to the signed-in user | 0–300 s | 60 s |

The driver option interacts with M1: "include drivers" while `updates.excludeDrivers` is on is a
contradiction. The policy makes Windows Update withhold drivers from the scan, so the engine would
see none. This will be a **hard validation error**, not a silent override.

## 5. Technical risks and blockers

**No blockers to implementation.** There are risks to resolve or accept:

1. **Nothing here can be run against real Windows Update on a target machine.** This workstation
   runs Windows 11, but installing updates or rebooting it is out of the question. The engine will
   be tested with:
   - Vitest for config, validation and script rendering;
   - PowerShell parser checks of every generated script;
   - Pester-style dry runs against a **mocked WUA layer** (the engine reads WUA through a thin
     adapter).

   A read-only scan on this machine is possible **only if you allow it**. Real install, reboot and
   resume behaviour stays **unverified until a VM run**.
2. **M1 itself is still not VM-validated.** The engine is triggered from FirstLogon, whose timing and
   behaviour have not been observed yet. Phase 2 inherits that risk.
3. **Network at first logon.** With interactive Wi-Fi, the machine may have no network when
   FirstLogon runs. Mitigation: the bounded network wait, then `Offline`, then a retry at the next
   boot. If the machine never connects, the engine ends `Offline` once its limits are reached and
   never claims success.
4. **Forced reboots with auto-logon.** The owner default signs in automatically. The engine will
   reboot a signed-in desktop, with a warning. Unsaved user work could be lost during the update
   phase. This is expected for a fresh deployment, but it must be stated in the UI.
5. **Interaction with automatic updates.** The M1 policy (download automatically, notify to install)
   means Windows may download in parallel. WUA serialises installs, and the engine waits on
   `IsBusy`. Duplicate downloads are harmless.
6. **WU component reset** (renaming `SoftwareDistribution`/`catroot2`) is a Microsoft-documented
   troubleshooting step, but it discards update history. It is offered as an option and runs at most
   once.
7. **Feature-update detection.** The `Upgrades` category GUID is documented. Whether 24H2→25H2
   enablement packages arrive as an "Upgrade" or as a regular cumulative update must be confirmed in
   the VM. Enablement packages may install even with "skip".
8. **Roadmap naming.** `docs/roadmap.md` calls WSIM/VM validation "Milestone 2" and puts WinGet and
   PowerShell 7 in Milestone 3. This work will be recorded as **Phase 2: Windows Update automation**.
   Validation stays an open prerequisite for calling anything VM-verified, and WinGet stays out of
   scope.
