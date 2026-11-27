# Windows Update automation 2.1.0, drivers and the health audit

Engine 2.1.0 (`src/engine/windows-update/scripts/WindowsUpdateEngine.ps1`) keeps the 2.0.0 engine that was proven on hardware. That includes:

- the 0x80131508 collection fix;
- readiness, passes A to D and bounded retries;
- engine-exception handling and restart and resume through the scheduled task.

2.1.0 adds the parts a normal deployment needs to finish without a technician:

- every update category, with previews controlled by their own setting;
- a final check through the Update Orchestrator, the component that Settings uses;
- an honest final update state.

## The normal deployment, start to finish

| Step | What happens | Where |
|---|---|---|
| 1–2 | Readiness: services, agent, a restart already pending (one restart), a first successful search | `Invoke-WduReadiness` (2.0.0) |
| 3 | Search: `IUpdateSearcher.Search("IsInstalled=0 and IsHidden=0")` (drivers too when the policy includes them) | `Get-WduAvailableUpdates` |
| 4 | Pass A: servicing stack and the Defender platform, on their own | `Get-WduPass` |
| 5–6 | Pass B: cumulative, security, .NET, Defender intelligence, MSRT | |
| 7–8 | Pass C: Windows and .NET previews (when allowed), other optional updates, every driver on its own | |
| 9–10 | Restart when an update requires it (60 s warning, install lock respected); the task starts the engine again after the restart and it continues from its saved state | `Request-WduReboot`, state.json |
| 11–12 | Search again after every pass and every restart; anything newly applicable goes through the passes again. Bounded by `maxReboots`, `maxAttemptsPerUpdate`, `maxRuntimeHours` and the safety limit of 50 passes | `Invoke-WduRun` |
| 13–14 | Nothing selected remains: **Settings refresh** (below), then search again; whatever it made applicable is installed. At most twice per run | `Invoke-WduSettingsRefresh` |
| 15 | Pass D: final verification. This covers what is still offered, what is no longer offered (superseded), the devices with problems and whether a restart is pending | `Get-WduVerification` |
| 16 | Result with `updateState` and its counts; the deployment's health audit runs at the end of the deployment | `Complete-Wdu`, `DeploymentHealth.ps1` |

The technician launches nothing during a successful deployment. Retry Windows Update and Deployment Recovery remain the tools for troubleshooting and recovery.

## Update coverage and the preview setting

The engine gives each update a class (`Get-WduUpdateClass`) from Microsoft's own titles, from the categories and, for drivers, from the driver class:

| Class | Example title | Standard (default) | "Install preview updates" off |
|---|---|---|---|
| `servicingStack` | 2026-11 Servicing Stack Update for Windows 11 … | Install | Install |
| `cumulative` | 2026-11 Cumulative Update for Windows 11 … | Install | Install |
| `security` | … Security Update … | Install | Install |
| `dotnet` | 2026-11 Cumulative Update for .NET Framework … | Install | Install |
| `defenderPlatform`, `defenderIntelligence` | Security Intelligence Update for Microsoft Defender Antivirus … | Install | Install |
| `msrt` | Windows Malicious Software Removal Tool … | Install | Install |
| `driver` (optional ones included) | Intel - System - 10.1.1.44 | Install | Install |
| `windowsPreview` | 2026-11 Cumulative Update **Preview** for Windows 11 … | Install | **Excluded** |
| `dotnetPreview` | … Cumulative Update **Preview** for .NET Framework … | Install | **Excluded** |
| `firmware` | driver class Firmware | Never | Never |
| `feature` | Feature update to Windows … | Never (policy: skip) | Never |
| `insider` | Windows 11 Insider Preview … | Never | Never |

How the setting works:

- **The setting.** "Install preview updates" is under Advanced > Windows Update and defaults to on. It is `windowsUpdate.previewUpdates` (schema 10) and `previewUpdates` in `config.json`.
- **What turning it off changes.** Only the previews are excluded. They are reported as `preview update (policy: preview updates excluded)`, and the final state is `PreviewUpdatesExcluded`.
- **Optional drivers.** They follow "Drivers from Windows Update" and "Optional updates", not this setting.
- **Older profiles.** A profile from before schema 10 migrates with previews following its "Optional and preview updates" choice, so its package installs what it installed before.

### How previews are found and installed

Optional non-security previews are offered to the Windows Update Agent as optional (`BrowseOnly`) software updates. They are in the engine's normal search, with no other API needed.

Why the spare computer's recovery did not install the two previews that Settings showed:

- Retry Windows Update 1.0.0's `RetryUpdates` left out every optional update.
- `RetryDrivers` left out everything but drivers.

So the previews were never selected; Windows Update did not withhold them. Tool 1.1.0 changes this:

- `RetryUpdates` installs every Windows update the deployment's policy allows, previews included.
- A normal deployment already installed them.

Limits that remain:

- **Policies and Microsoft's own offering.** An update Windows does not offer to the Windows Update Agent cannot be installed by it. Examples: an organization's deferral policy, or a controlled feature rollout that Microsoft gates.
- **A preview Settings showed that the engine did not see.** It appears in the health audit as "still offered", or in Settings after the final check. It is never reported as installed.

## Final check and Settings > Windows Update

A Windows Update Agent search (`Microsoft.Update.Session`) does not change what Settings > Windows Update shows. The engine therefore also uses the documented WinRT API `Windows.Management.Update.WindowsUpdateManager` (Windows 11 24H2 and later). It talks to the Update Orchestrator, which Settings uses:

1. Read `LastSuccessfulScanTimestamp`.
2. Call `StartScan(true)`, the equivalent of "Check for updates".
3. Poll for up to 15 minutes until `IsScanning` is false and the timestamp has advanced.
4. Search again with the Windows Update Agent and install anything the check made applicable, then run pass D.

`result.json` › `settingsRefresh` records each claim separately:

| Field | Meaning |
|---|---|
| `available` | the API exists on this Windows (24H2 or later) |
| `requested` | the scan request was accepted |
| `completed` | the orchestrator's last successful scan time advanced after the request |
| `settingsDisplayVerified` | always `false`: the engine cannot see the Settings page |
| `message` | what happened, or why not |

Nothing is ever written to the registry to make Windows look current. UsoClient.exe is undocumented and is not used.

Earlier than 24H2 the refresh is "not available". The Windows Update Agent verification still decides the state, and Settings may show an older "Last checked" time until Windows checks by itself.

## Final update state (`result.json` › `updateState`)

| State | When |
|---|---|
| `UpToDate` | the final search found nothing applicable left |
| `UpToDateUnderPolicy` | only updates excluded by policy remain offered (firmware, drivers when excluded, a retry's other kind) |
| `PreviewUpdatesExcluded` | previews are offered and intentionally excluded |
| `RestartRequired` | a restart is still pending |
| `UpdatesRemaining` | selected updates remain (Windows said they need a person) |
| `CompletedWithFailures` | selected updates were given up |
| `InstallationIncomplete` | stopped by a limit, an engine error or no network |
| `VerificationUnavailable` | the final verification did not run; never reported as up to date |

`summary` counts the following separately:

- installed;
- superseded (offered earlier, no longer offered);
- not applicable;
- excluded by policy, with previews also counted on their own;
- download failed;
- installation failed;
- remaining;
- not attempted.

It also records whether a restart is still awaited (`awaitingRestart`, true or false). The deployment report, the monitor and the health audit show the state.

## Drivers

Windows Update is the driver source. It matches the hardware IDs itself, and WDB keeps no PCI database. Every driver is installed on its own and recorded with its device (hardware ID, model, class). Pass D lists the devices that still have a problem, and the health audit compares them with the devices the original deployment reported.

Zero device problems is a hardware-health result. It is not proof that every optional driver was installed.

## Manufacturer software recommendations

These are part of the health audit. They are optional enhancements; drivers come from Windows Update.

| Hardware (detected via Win32_VideoController / Win32_Processor / chassis) | Recommendation |
|---|---|
| NVIDIA GeForce, RTX, TITAN or Quadro display adapter (PCI VEN_10DE), for example RTX 4080 | NVIDIA App |
| AMD Radeon display adapter (VEN_1002), for example RX 6700 XT; never because of an AMD CPU alone | AMD Software: Adrenalin Edition |
| AMD Ryzen CPU in a desktop chassis, for example Ryzen 7 7800X3D | AMD Ryzen Master: monitoring and tuning, not a chipset driver; WDB never applies tuning, overclocking, voltage or BIOS changes |

None of the three is installed automatically. `microsoft/winget-pkgs` has no package for them (checked on 2026-11-27), and their installers' unattended modes are not verified. Each is reported with its detected hardware, whether it is installed, and the official download page as a manual technician action. A missing recommendation never fails a deployment.

## Historical result versus current health

- **The deployment's own record is history and is never rewritten.** This covers `reports\deployment-report.*` and `Updates\result.json`.
- **Each Retry Windows Update run has its own folder.** That is `UpdateRetry\<run>`.
- **The health audit is the current state.** It is `reports\health\deployment-health.json` and `.html`. It reads all of the above, and Windows Update history, and reports an original failure that was installed later as "originally failed; installed later".

## Recovery and maintenance entry points

All of these run locally. The LAN monitor stays read-only and never runs actions.

| Action | Command (elevated Windows PowerShell) | Changes the computer |
|---|---|---|
| Health audit | `DeploymentRecovery.ps1` menu 9, `Invoke-WindowsUpdateRetry.ps1 -Mode HealthAudit`, or `scripts\health\DeploymentHealth.ps1 -Mode Verify` (`-Mode Dashboard` also opens the report) | No (writes its report) |
| Status, recovery history, hardware problems | `Invoke-WindowsUpdateRetry.ps1 -Mode Status` (menu U › S) | No |
| Check for updates | `-Mode Scan` (menu U › C): a Windows Update Agent search, installs nothing | No |
| Install Windows updates (no drivers) | `-Mode RetryUpdates -Wait` (menu U › N) | Yes, may restart |
| Install optional drivers | `-Mode RetryDrivers -Wait` (menu U › D) | Yes, may restart |
| Install all selected updates | `-Mode RetryAll -Wait` (menu U › A) | Yes, may restart |
| Export diagnostics | `-Mode ExportDiagnostics` (menu U › E) | No |

How these behave:

- **Advice from Status.** Status bases its advice on what actually happened:
  - a run can be running, awaiting a restart, resuming, or stopped without its task;
  - when only one part of the recovery succeeded, it names the other;
  - once the recovery has succeeded, it recommends the health audit and never another retry.
- **One retry task.** All retry runs share one task, so a second kind of retry is refused while a run still owns it.
- **The monitor.** It shows the deployment's result as history, and the latest health audit as the current state.
- **After the monitor expires.** Use menu 9 or `DeploymentHealth.ps1 -Mode Dashboard`.

## Verified, and still to verify on hardware

| Claim | Verified by |
|---|---|
| Collection fix, passes, retries, restart/resume, engine exceptions | Engine.Tests.ps1 (simulated agent), live read-only COM test, spare-computer recovery (2.0.0) |
| Classes, preview policy, firmware exclusion, retry selections, update states, Settings-refresh outcomes | Engine.Tests.ps1, UpdateRetry.Tests.ps1 (simulated orchestrator) |
| The WinRT API exists and its last-scan time can be read from Windows PowerShell 5.1 | read-only probe on Windows 11 build 26220 (development PC) |
| `StartScan` from SYSTEM in a scheduled task, its effect on Settings | **not verified: spare computer** |
| Preview updates offered to the Windows Update Agent and installed | **not verified: spare computer** |
| Manufacturer recommendations on real NVIDIA/AMD hardware | Health.Tests.ps1 (simulated); **real hardware not verified** |

See [physical-test.md](physical-test.md) for the hardware procedure.
