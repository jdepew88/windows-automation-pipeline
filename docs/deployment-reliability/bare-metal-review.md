# Bare-metal reliability review (orchestrator 1.3.0)

Follow-up to [the reliability changes](README.md) after the second physical Windows 11 installation.
That installation ran the package from `b97998a`. The deployment ended with the progress window
showing "In Progress (code 40): Stages are starting". The engines reported final results. The
computer did not restart after the updates. Applications finished with failures, and three devices
were left unresolved.

Versions: orchestrator and package 1.3.0, Windows Update engine 1.3.0, application engine 1.5.0.
The profile schema stays at 8. The architecture is unchanged: same engines, tasks, state files and
monitor.

Nothing in this change touches:
- Windows Setup, disk selection, partitioning or formatting;
- driver-signature or installer-integrity checks;
- the NTFS permission fix (its 25 real-icacls tests still pass).

No field logs from that computer were available. The causes below come from tracing the shipped
code. Where a cause cannot be confirmed without the logs, it is marked as likely.

## Root causes

### Exit code 40 and "Stages are starting"

Code 40 is the orchestrator's own `InProgress` outcome (`$script:OutcomeCodes` in
`DeploymentCommon.ps1`). It is not an engine or Windows code.

`Get-WddDeploymentOutcome` reports a finished deployment only after the SYSTEM monitor has run
`Complete-Deployment.ps1` and set the state to `Completed`. Until then it looks for a running stage.
When every stage was final, no stage was running, so it fell through to its last line. In
`b97998a` that line was "Stages are starting." (1.2.0: "Launching the deployment stages; no engine
has reported yet."). The progress window computes this itself, live and without elevation. That is
why it showed final engine results next to a startup message.

So the deployment was never finished by the monitor. Two causes are possible, and the code allowed
both without saying so:
1. The monitor task did not run. Nothing told the technician that the monitor had stopped.
2. `Complete-WddDeployment` threw. The run ended before the state was saved, and every later run
   failed the same way, silently.

`deployment.log` on that computer shows which one: either "Monitor run N" lines stop, or they
continue with an error and no "FINISHED" line.

**Fixed in 1.3.0:**
- When every stage is final but the deployment is not finished, the outcome lists the stage
  results. It says what is still to be done: a restart, the update re-check, the report.
- The monitor's last run time is shown. If it is more than three intervals (plus 5 minutes) late
  while Windows has been running that long, it is reported as needing attention (code 32), with the
  command to run.
- Finalization is wrapped. An error is logged with the script line and shown in the progress
  window, then retried at the next run. After three failures a minimal report is written and the
  deployment ends with a follow-up and event 3105. It can no longer hang forever.

### The missing restart

Each engine restarts the computer only for itself, while it runs. Windows Update restarts when an
installation needs it, or when a restart is pending and nothing is left to install. The application
engine restarts once before installing if one is pending, and for packages that return 3010.

Nothing acted on a restart Windows still needed after a stage had finished:
- a restart left pending after the Windows Update stage was final;
- a driver's restart (Device Manager code 14) after the driver stage;
- a restart deferred because another engine held the install lock;
- a restart still pending at the end of the deployment.

`Complete-Deployment.ps1` then wrote the report and ended without one. Devices that only needed a
restart stayed unresolved.

**Fixed in 1.3.0: `Step-WddRestartCoordinator` in the SYSTEM monitor**, which runs every 5 minutes
and at startup.
- **When a restart is needed.** Only Windows' own servicing indicators count:
  - the WUA `SystemInfo.RebootRequired` value or the Windows Update `RebootRequired` key;
  - the component-servicing `RebootPending` key;
  - devices with code 14;
  - applications that finished with "restart required".

  `PendingFileRenameOperations` is ignored: installers leave entries there that need no restart.
- **Announced first.** It goes to the activity feed and the progress window, and is done at the next
  run at the earliest. An engine that is about to restart itself goes first.
- **Never while something installs.** It waits while:
  - a stage is working (installing, downloading, scanning, confirming, waiting for a retry);
  - the Windows Update installer is busy;
  - an MSI installation holds `Global\_MSIExecute`;
  - an engine holds the install lock;
  - an unfinished stage's task is missing (it would not resume after the boot).

  The reason it waits is shown.
- **Saved before restarting.** It takes the install lock and writes the restart marker in the
  engines' format, so they start nothing new. Then it saves the state, writes event 3009, runs
  `shutdown /r /t 120`, and holds the lock through the warning.
- **After the boot.** The restart is recognised as planned ("scheduled by Deployment"), and every
  unfinished stage is checked. When everything has finished, Windows Update is searched again and
  Device Manager is checked in that new boot. Then the report is written.
- **Loop prevention.** It restarts at most 3 times per deployment (`coordinatedRestarts`) and never
  twice in the same boot. When the limit is reached, Windows' pending restart is reported (event
  3010, report "Restart: ...") instead.

  A restart blocked for more than 120 minutes at the end does not hold the deployment back. It is
  reported as outstanding.

If the restart cannot start (shutdown.exe fails), the marker is removed so the engines are not held
back. The report says to restart by hand.

**After a restart, the application engine needs the deployment user to sign in.** WinGet runs only
as that user, never as SYSTEM. With the account's automatic sign-in set to "first sign-in only",
someone must sign in after each restart. The progress window reopens and the applications continue
by themselves; no script has to be started by hand.

### KB890830, KB4052623 and `0x80131508`

`0x80131508` is not a Windows Update error. It is the .NET error `COR_E_INDEXOUTOFRANGE` ("index
out of range"). It can reach the result in two ways:
- **Windows Update's own per-update result.** KB890830 (Malicious Software Removal Tool) and
  KB4052623 (Microsoft Defender platform) are command-line updates, so Windows Update passes their
  installer's own failure code through.
- **An exception in the engine's own WUA call.** In engine 1.2.0 this was recorded as if Windows
  Update had returned it.

Both updates were installed in the same pass as updates that needed a restart. Likely cause: they
failed while that restart was pending, and the logs needed to confirm it are not available.

**Fixed in 1.3.0:**
- The engine records who reported the error: `windowsUpdate` or `engine`. An engine exception keeps
  its type and message, and the next attempt uses a new WUA session. `0x80131508` and `0x80131509`
  are named.
- An update whose last attempt fails while Windows has a restart pending is not given up. It is
  retried once in the next boot, and the engine restarts for it. A second failure is final and
  reported with `retriedAfterRestart`.
- After everything has finished, the monitor searches Windows Update again (read-only, under the
  engine's own policy). If anything installable is offered, the Windows Update stage runs once more
  (`updateRechecks`, 1). Anything still offered after that is listed in the report, never hidden
  behind "no updates remain".

### Applications

- **Google Chrome, hash mismatch (`0x8A150011`, likely).** Google replaces the installer behind a
  fixed URL before the WinGet manifest's hash is updated. Engine 1.5.0 retries it once, 30 minutes
  later (`integrityRetryMinutes`), after `winget source update`. The hash is still checked: WinGet's
  skip-hash option is never used, and a test enforces it. A second mismatch is final (`Integrity`).
- **Spotify, refuses elevation (`0x8A150056` INSTALLER_PROHIBITS_ELEVATION, likely).** The
  application engine runs elevated. Engine 1.5.0 runs such a package once as the same signed-in user
  without elevation. It uses a one-time task with an interactive logon and the limited run level,
  the same validated WinGet arguments, and a temp folder for the exit code. The task is removed
  afterwards. If that fails too, the package needs a person, with the exact command. It is never
  retried in a loop.
- **Battle.net, prompting installer.** Since 1.4.0 it is reported as needing a person after one
  timeout.
- **FileZilla and RustDesk.** Not in WinGet (verified 2026-10-21; see the catalog). They are manual
  catalog entries, reported with their download instructions. No WinGet ID is invented.

Unchanged from earlier versions:
- Source and package agreements are accepted by WinGet's own flags.
- An installed application is detected with `winget list --id <id> --exact` before any installation,
  and verified again after one.
- A failure never stops the other applications.
- Each failure records WinGet's code and the installer's own exit code.

### Devices

The three unresolved devices of that run fit three cases:
- the SM Bus Controller and PCI Memory Controller have no driver (chipset);
- a device needed a restart that never came;
- a USB device failed its descriptor request.

**In 1.3.0:**
- Devices are checked after the deployment's last restart (`devices.bootUtc`).
- A code-14 device triggers the coordinated restart.
- A display adapter on "Microsoft Basic Display Adapter" is reported (`GenericDriver`).
- Chipset and graphics devices name their official driver source by the PCI vendor ID:
  - Intel: Chipset Device Software or Driver & Support Assistant;
  - AMD: Chipset Software or Adrenalin;
  - NVIDIA: nvidia.com/drivers;
  - otherwise the computer or motherboard manufacturer.

Nothing is downloaded. No third-party driver site is suggested. A USB descriptor failure gets no
driver hint: it is a cable, port or device problem. Optional driver updates from Windows Update are
installed by default since 1.2.0; that covers Intel's chipset INF updates when Windows Update offers
them.

### The progress window and the scheduled tasks

The progress window runs without elevation. A filtered token cannot read the tasks of SYSTEM or of
an elevated user. So in 1.2.0, after two hours, a running stage could look "Stalled: the scheduled
task is missing".

In 1.3.0 a non-elevated process never concludes that a task is missing. It uses the SYSTEM
monitor's last view instead (status.json, at most 30 minutes old), and the window says so.

## Overall states

| Shown | Outcome (code) | When |
|---|---|---|
| Running | InProgress (40) | an engine works, or the stages are being launched |
| Finishing | InProgress (40) | every stage is final; the monitor finishes it at its next run (the text lists the results) |
| Waiting for restart | PausedAwaitingReboot (31) | an engine or the coordinator restarts the computer |
| Recovering | condition `recovering` | 10 minutes after a restart or an automatic recovery |
| Waiting for a person | PausedAwaitingUser (32) | a stalled stage, a sign-in, or the monitor not running |
| Completed successfully | Succeeded (0) | everything verified, no restart or device outstanding |
| Completed with follow-up | CompletedWithWarnings (10) | a person must act: interaction, devices, restart, updates still offered |
| Completed with application failures | CompletedWithFailures (20) | updates or applications failed |
| Incomplete | Incomplete (25) | the deadline passed with unfinished stages, or a stage was offline |
| Failed | Failed (60) | a stage failed |

The report's `outcome` and `outcomeCode` are taken from the same function as the progress window.
They cannot disagree.

## Report additions

- `restartCoordination`: the status, whether a restart is still outstanding, the reasons and
  blockers, the automatic restarts and their history.
- `updateRecheck`: the status and what Windows Update still offers.
- Windows Update failures: `errorSource`, `exception` and `retriedAfterRestart`.
- Devices: `vendor`, `driverSource`, and the `bootUtc` of the check.

The text report has a "Restart required by Windows" and a "Windows Update re-check" section.

## Tests

The tests simulate Windows: WUA, WinGet, installers, tasks, devices, the restart command and the
update search. No test restarts, searches or installs anything on the computer running it. They do
not prove that a physical installation works.

**New:**
- `Engine.Tests.ps1` (3 scenarios):
  - an update that failed while a restart was pending is retried after it;
  - an update still failing after that restart is given up once;
  - an exception in the engine's own WUA call (`0x80131508`) is recorded as an engine error, with a
    new session.
- `Applications.Tests.ps1` (6 scenarios):
  - the hash-mismatch retry from a refreshed source;
  - the retry turned off;
  - the publisher fixing the hash;
  - the non-elevated run for Spotify, its failure, and the option turned off.
- `Deployment.Tests.ps1` (11 scenarios):
  - exit code 40 reconciliation and the overdue monitor;
  - a finalization failure, retry and minimal report;
  - the full coordinated restart and post-restart re-check;
  - the blockers (working stage, MSI, install lock);
  - the restart-loop limit;
  - a restart that cannot start;
  - the restart reasons;
  - the update re-check (run once more, then reported);
  - an update search that fails;
  - the non-elevated task view;
  - the chipset and graphics hints.
- `deployment-reliability.test.ts` (8 static guarantees).

## Remaining limits (need the physical computer)

- Whether the real servicing indicators clear after the restart. If one stays set, the coordinator
  restarts at most 3 times, then reports it.
- That `shutdown /r` from the SYSTEM monitor task restarts a signed-in computer as expected. The
  120-second warning is shown to the signed-in user.
- Whether the non-elevated run (a one-time interactive task with the limited run level) installs
  Spotify on real Windows, and how long Spotify's installer takes.
- Whether Google's Chrome manifest is corrected within 30 minutes of a mismatch. If not, the
  failure stays reported.
- The read-only WUA re-search as SYSTEM: its duration, and what it returns right after a restart.
- The real Device Manager data for the chipset devices, and whether the optional chipset driver
  from Windows Update resolves them.
- The cause of `0x80131508`. The new `errorSource` and `exception` fields in `Updates\result.json`
  will show it.

## Checklist for the next spare-computer installation

1. **Package.** Generate it with the owner defaults (LAN monitor on, if you want it). Use a network
   set to Private. Keep `deployment.log` and `Updates\result.json` from the previous attempt if you
   still have them.
2. **First sign-in.**
   - [ ] The progress window opens by itself.
   - [ ] "Monitor checks" shows a recent run.
   - [ ] No stage shows "task is missing".
3. **During Windows Update.**
   - [ ] Every restart is announced in the window.
   - [ ] After each restart and sign-in the window reopens with "Windows restarted (scheduled by
     ...)". Nothing has to be started by hand.
4. **If an update fails.**
   - [ ] `Updates\result.json` lists it with `errorSource` (`windowsUpdate` or `engine`) and
     `exception`. A failure while a restart was pending shows `retriedAfterRestart`.
5. **Applications.**
   - [ ] Chrome: either installed, or failed with "the source is refreshed and it is tried once
     more" followed by a final Integrity failure.
   - [ ] Spotify: installed "without administrator rights", or a clear person-needed message.
   - [ ] Battle.net: needs a person after one timeout.
   - [ ] Every application has a verification category in the report.
6. **After every stage has finished.**
   - [ ] If Windows needs a restart, the window says "Restart: Announced", then the computer
     restarts once with a 2-minute warning.
   - [ ] After the restart: "Windows Update re-check", then the report.
   - [ ] The window never shows "Stages are starting".
7. **The report.**
   - [ ] `restartCoordination.outstanding` is `false` (or explains why).
   - [ ] `updateRecheck` is NothingOffered or lists what is still offered.
   - [ ] Device Manager matches the report. Chipset or graphics devices carry their vendor's
     source.
   - [ ] The outcome code matches the progress window.
8. **Monitor overdue test (optional).**
   - [ ] Disable the `\WindowsDeploymentBuilder\Deployment` task for 25 minutes. The window shows
     "OVERDUE" and code 32. Re-enable it and the deployment continues.
9. **Permissions.**
   - [ ] `Get-Acl` on `C:\ProgramData\WindowsDeploymentBuilder\Package\scripts\*.ps1` shows SYSTEM,
     Administrators and Users entries.
