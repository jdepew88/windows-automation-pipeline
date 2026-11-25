# Deployment reliability, automatic updates and remote monitoring

Improvements based on the first bare-metal Windows 11 installation. Versions: orchestrator and
package 1.2.0, Windows Update engine 1.2.0, application engine 1.4.0, profile schema 8. The
architecture is unchanged: the same engines, scheduled tasks, state files and monitor. Nothing
here changes Windows Setup, disk selection, partitioning or formatting, and nothing weakens
driver-signature or installer-integrity checks. The NTFS permission fix from `b97998a` is not
touched (`Acl.Tests.ps1` still passes).

## What changed

### Windows Update (WindowsUpdateEngine.ps1 1.2.0)

What the first installation showed, and why:

- **Optional Intel chipset drivers were skipped.** The owner default was
  `optionalUpdates: skip`. Windows lists optional driver updates as `BrowseOnly`, so the engine
  reported them as "optional update (policy: skip)".
- **Updates that "can request user input" were never installed.** The engine skipped every update
  with `InstallationBehavior.CanRequestUserInput`, based on that flag alone.
- **Download failures.** All updates were downloaded in one call, and a failure was retried in the
  very next pass with no delay. The default was two attempts.

The changes:

- **Selection.** Everything Windows Update offers as applicable (`IsInstalled=0 and IsHidden=0`)
  is installed:
  - recommended updates;
  - optional cumulative previews and optional driver updates, which are now the owner default
    (`optionalUpdates: install`);
  - drivers, while the driver policy includes them (the owner default does).
- **What is never installed.** Feature updates (category Upgrades, or titles starting "Feature
  update to Windows" or "Upgrade to Windows", which covers enablement packages) are skipped unless
  explicitly allowed. Insider Preview builds are never installed. Hidden updates stay hidden.
- **Windows decides.** Applicability, supersedence, signing and servicing remain Windows' own
  decisions; the engine only acts on what the Windows Update Agent offers.
- **"Can request user input"** is no longer a reason to skip. Such an update is installed on its
  own, quietly (`ForceQuiet`). It is reported as needing a person only if Windows answers
  `0x80240020 WU_E_NO_INTERACTIVE_USER` or aborts it. It is then never retried in a loop, and the
  stage ends `CompletedWithFollowUp`.
- **Downloads.** Each update is downloaded on its own, so one failure does not hold back the
  others. A transient failure is retried after 120 s × attempt, with at most 3 attempts in total
  per update; downloading and installing both count as attempts. A permanent failure (for example
  `0x80240017 WU_E_NOT_APPLICABLE`) is not retried. The HRESULT is kept together with its
  documented name.
- **Reboot loops.** The existing limits still apply: the reboot limit, the runtime limit, one
  component reset and the safety limit of 50 passes. After every restart the engine scans again.
- **Status.** `status.json` now carries the current update, the attempt, the last error with its
  time, and the counts.
- **Result.** `result.json` now carries counts by kind (optional updates, drivers),
  `requiresInteraction` and the policy used. There is a new final status, `CompletedWithFollowUp`,
  and a new event, 1104.

### Applications (ApplicationEngine.ps1 1.4.0)

The engine already continued after a failure, retried with backoff, and never retried integrity,
policy or permanent failures. What changed:

- **Installer exit codes.** When the package's own installer fails, WinGet returns
  `0x8A150006 SHELLEXEC_INSTALL_FAILED`. That code is now named, and the installer's own exit code
  is taken from WinGet's output ("Installer failed with exit code: N"). It is kept in the package
  result, in `attempts.jsonl` and in the report.
- **Installers that may wait for a person.** A package whose catalog entry says its installer may
  prompt (`mayPrompt`, for example Battle.net) and that times out is reported `RequiresInteraction`.
  Previously it was retried for two more full timeouts.
- **Status.** `status.json` now has installed, failed and selected counts, the application being
  installed, and the last failure, worded as "X could not be installed. The failure was recorded;
  deployment is continuing with the remaining applications."
- **Default attempts.** Three attempts per package remains the default.

**Chrome, Spotify and Battle.net.** Their logs from the field computer were not available, so the
exact codes are not confirmed. What the engine does with each likely cause:

- **Chrome:** a new release published under the same URL gives
  `0x8A150011 INSTALLER_HASH_MISMATCH`. That is reported and deliberately not retried; the check is
  not weakened.
- **Spotify:** its installer refuses to run elevated, and this engine runs elevated. That gives
  `0x8A150006` plus the installer's own code, which is now reported. Installing it from a
  non-elevated context would be a separate change.
- **Battle.net:** it may prompt, and is now reported as needing a person after one timeout.

### Restart, recovery and duplicate prevention (orchestrator 1.2.0)

**At initialization** (`Initialize-Deployment.ps1`):

- Every task is checked after registration.
- A stage task that is missing ends with `InitializedWithProblems` (exit code 1) and the reason,
  never with a plain success. A monitor task that is missing ends with `MonitorRegistrationFailed`.

**The monitor task** (`\WindowsDeploymentBuilder\Deployment`, SYSTEM) now runs every 5 minutes and
at startup. It is the same monitor as before, not a second orchestrator. On each run it does the
following:

- **Restart detection.** A new boot is recorded as planned or unexpected:
  - planned: an engine's restart marker from the previous boot, a stage that was restarting, or a
    stage whose restart count grew;
  - otherwise unexpected.

  It is written to the state (`restarts`), the activity feed and event 3007, and the deployment
  shows "recovering" for 10 minutes while unfinished stages are checked.
- **Bounded automatic recovery.** At most 2 times per stage:
  - a SYSTEM stage (Windows Update, drivers) whose task is gone without a result has its installer
    run again, as Resume does;
  - a stage with no progress whose task is not running has its task started again.

  Then a technician is asked (event 3008). The WinGet stage is never started from SYSTEM; the
  technician is told to sign in and run `Resume-Deployment.ps1 -RestartStage applications`.
- **No-progress detection.** The limit is 120 minutes, or 240 minutes while Windows Update
  downloads or installs. A stage is never flagged while Windows itself is servicing updates (the
  Windows Update installer is busy, or TiWorker is running). A stage whose task is still running is
  reported, not restarted.
- **Helper tasks.** The progress window and monitor tasks are registered again if they have
  disappeared.

**Duplicate prevention** is unchanged:

- engine mutexes, so one engine instance at a time;
- the orchestrator mutex, so one monitor, Initialize or Resume at a time;
- launch records written before an installer runs, so a crash cannot launch a stage twice;
- tasks registered with `MultipleInstances IgnoreNew`.

### Progress window (Show-DeploymentStatus.ps1)

- **Opens automatically.** The task `\WindowsDeploymentBuilder\Progress` opens it at every sign-in
  of the deployment user while the deployment runs, 20 seconds after sign-in. It runs as that user
  without elevation; it is a viewer, not an engine.
- **Refresh.** It refreshes every 7 seconds; the default was 15.
- **Single instance.** Only one window opens per session (a session mutex); a second one exits at
  once. Closing the window never affects the deployment.
- **After completion.** The task is removed when the deployment finishes. An automatically started
  window also exits at once if the deployment is already complete.
- **What it shows:**
  - each stage in words: what it is doing, why it waits, and when it last made progress;
  - the last problem with its age;
  - recent activity;
  - "recovering" after a restart;
  - the monitor address with its token.

### Clear messages and the activity feed

- **Stage descriptions.** Every stage in `status.json` now has `condition` (active, waiting, idle,
  blocked or finished), `activity` (one sentence), `waitingReason`, `lastActivityUtc` (the engine's
  last report, not the time of the refresh), `stale`, `lastError` and the counts.
- **Vague messages replaced.** "Stages are starting" and "Current stage: x" are gone. Examples of
  the new messages:
  - "Waiting for Windows Update to finish. Last activity: 2 minutes ago."
  - "Unable to download KB… : 0x8024402C WU_E_PT_WINHTTP_NAME_NOT_RESOLVED (…). Attempt 2 of 3;
    retrying in 240 s. Other operations will continue where possible."
  - "Spotify could not be installed (…). The failure was recorded; deployment is continuing with
    the remaining applications."
  - "Windows restarted unexpectedly (…). Restoring deployment progress and checking unfinished
    tasks…"
  - "No progress detected for 250 minutes (limit 240)…" followed by "Automatic recovery attempted
    (…). Technician attention may be required…"
- **Activity feed.** `<dataRoot>\Deployment\activity.jsonl` has one timestamped JSON line per
  event. The monitor writes restarts, recoveries and stage changes; the engines append their own
  retries and failures. A line left unfinished never swallows the next one, and the feed is kept
  under 1 MB.

### Device Manager check and report (Complete-Deployment.ps1)

**Device Manager check.** At completion, a read-only check lists the devices that need attention,
with their friendly name, class, problem code and its meaning, and hardware IDs. Instance IDs are
left out because they can contain serial numbers. Each device gets a kind:

- **NoDriver:** problem code 28.
- **UnknownDevice:** Windows does not recognise the device.
- **RestartRequired:** problem code 14.
- **HardwareOrConnection:** USB descriptor or reset failures. These are explained as a likely
  cable, hub, port or device fault, not a missing driver.
- **Problem:** any other code, with the note that it is not necessarily a missing driver.

Disabled (22) and disconnected (45) devices are not counted. Unresolved devices, or a device list
that could not be read, make a successful deployment `CompletedWithFollowUp`. No driver is
downloaded from manufacturers.

**Report.** The deployment report now also contains:

- **How each application was confirmed.** By exact package ID (`winget list --id <id> --exact`),
  so a similarly named package never counts:
  - `Verified`: confirmed installed;
  - `EngineReported`: success reported, not independently confirmed;
  - `NotVerified`: success reported, but WinGet does not find the package;
  - `Failed`;
  - `Deferred`: manual, deselected, needs a person, or needs a restart;
  - `Incomplete`.
- **Windows Update:** counts of optional updates and drivers installed, and the updates that need
  a person.
- **Restart history,** planned or unexpected.
- **Every recovery,** automatic or manual.
- **Follow-up items,** in "Remaining tasks".

## The deployment monitor (DeploymentStatusServer.ps1)

**How it runs:**

- It is a small read-only HTTP status page, served by `System.Net.HttpListener` (HTTP.sys) in
  Windows PowerShell 5.1. It needs no Node.js, IIS, Docker, WinGet or Internet connection.
- It reuses the deployment's own state, the engines' files, the activity feed and the final report,
  through the same functions as the progress window.
- It runs as SYSTEM from `\WindowsDeploymentBuilder\StatusServer`, which starts at every startup
  and restarts if it stops. It is independent of the progress window and the engines.
- It handles one request at a time with small answers; it is idle between requests.

**Settings.** Profile schema 8 adds `monitoring`, shown on the "Verification & Health" page:

- **enabled:** on in the owner default;
- **lanAccess:** off by default;
- **port:** 8765.

A profile saved before schema 8 imports with the monitor off.

**Reaching it:**

- The progress window shows the full address, for example `http://192.168.1.100:8765/#t=<token>`.
- With LAN access on, open that address on another computer, phone or tablet on the same network.
- Without LAN access, it answers only on the computer itself, at `http://127.0.0.1:8765/#t=<token>`.

**Security:**

- **Methods and routes.** It answers GET and HEAD only. `/`, `/app.js` and `/app.css` contain no
  data. `/api/status` requires `Authorization: Bearer <token>`. Everything else gets 404, and other
  methods get 405.
- **Token.** 256 random bits, kept for the deployment in `state\monitor.json` and compared in
  constant time. It travels in the URL fragment, which browsers never send to a server; a token in
  the query string is refused.
- **Status contents.**
  - The status is built field by field from a whitelist. Passwords, Wi-Fi keys, product keys,
    tokens and configuration are never read into it.
  - Text that looks like a credential is masked.
  - No cross-origin access, a strict Content-Security-Policy, no framing.
  - The page writes data as text only, never as HTML.
- **Firewall.** It is bound to 127.0.0.1 unless LAN access is on. With LAN access, one inbound rule
  is added: TCP on the port, Private profile, local subnet only. The rule is removed when the
  monitor stops. Router port forwarding and UPnP are never configured.
- **Who can read the token.** Any local account can read `state\monitor.json`, like the rest of the
  deployment status. The token protects against other devices, not against other local users.
- **Public networks.** On a network set to Public, Windows Firewall keeps blocking the monitor, and
  the progress window says so.
- **No network.** Without a network, the engines and the progress window are unaffected and the
  monitor answers locally.

**After the deployment.** The page shows the final results, read-only, for 24 hours: completed and
failed operations, unresolved devices and technician follow-up. Then the monitor removes its
firewall rule and task, and stops.

**Progress and speed are not shown.**
- Windows Update: the Windows Update Agent exposes download progress only through
  `BeginDownload` with COM callback objects, which Windows PowerShell 5.1 cannot implement without
  compiled code. The synchronous calls used here report no bytes.
- WinGet: it shows its progress bar only to an interactive console and reports none to a
  redirected process; parsing it would interfere with the installation.
- So the page shows "Downloading <name> - progress unavailable". It names the update or
  application and its size where Windows reports one, and never invents a percentage, speed or
  time estimate.

## How the deployment resumes after a restart

1. The engines' own tasks (Windows Update as SYSTEM at startup and hourly, drivers as SYSTEM,
   applications as the user at sign-in) continue from their state files. Work that is done is
   detected: installed updates are not offered again, and installed applications are found by
   `winget list` and never reinstalled.
2. Two minutes after startup the monitor runs. It records the restart as planned or unexpected,
   checks every unfinished stage and its task, recovers what it can within its bounds, and reports
   what needs a technician.
3. The status server starts again (one minute after startup). At sign-in the progress window opens
   by itself.

## Files

**New:**
- `src/engine/deployment/scripts/DeploymentStatusServer.ps1`;
- `tests/powershell/Monitor.Tests.ps1`;
- `tests/unit/deployment-reliability.test.ts`;
- this document.

**Changed engines and orchestrator:**
- `src/engine/windows-update/scripts/WindowsUpdateEngine.ps1`;
- `src/engine/applications/scripts/ApplicationEngine.ps1`;
- `src/engine/drivers/scripts/DriverEngine.ps1`: only the shared coordination block, with the new
  `Add-WdbActivity`;
- `src/engine/deployment/scripts/`: `DeploymentCommon.ps1`, `Initialize-Deployment.ps1`,
  `DeploymentOrchestrator.ps1`, `Show-DeploymentStatus.ps1`, `Complete-Deployment.ps1`.

**Changed generator and settings:**
- `src/engine/deployment/index.ts`;
- `src/engine/windows-update/index.ts`;
- `src/engine/applications/index.ts`;
- `src/engine/schema/profile.ts`;
- `src/engine/profiles/migrations.ts`;
- `src/features/health/index.ts`;
- `src/features/windows-update/index.ts`;
- `src/ui/layout.ts`;
- `profiles/owner-default.json`.

**Changed tests:**
- `Engine.Tests.ps1`, `Applications.Tests.ps1`, `Deployment.Tests.ps1`, `ProvisioningSim.ps1`;
- `windows-update.test.ts`, `applications-generate.test.ts`, `recovery.test.ts`,
  `migration.test.ts`, `powershell.test.ts`;
- the snapshots, `package.json` (`test:ps`) and `docs/samples`.

## Limits

- Everything is tested with simulations (WUA, WinGet, installers, tasks, devices), plus one real
  HTTP test on 127.0.0.1. That does not prove that a physical installation works.
- Not exercised on a real installation:
  - the Windows Update Agent's real answers;
  - Task Scheduler at sign-in;
  - SYSTEM's HTTP.sys binding on `+`;
  - the firewall rule;
  - the real Device Manager data.
- The first Windows Update pass can take longer: downloads now happen one update at a time, and
  optional updates are installed too.
- A transient failure waits 120 s, then 240 s, before the next attempt.

## Bare-metal validation checklist (next spare computer)

1. **Build the package.** Generate it with the owner defaults, and turn on "Allow access from other
   devices on the local network". Prepare the USB drive as before. Use a network set to Private.
2. **First sign-in.**
   - [ ] The Deployment Progress window opens by itself and refreshes every 7 s.
   - [ ] It shows the monitor address with `#t=`.
   - [ ] Every stage has a sentence and a "Last activity".
   - [ ] `Get-ScheduledTask -TaskPath '\WindowsDeploymentBuilder\'` lists Deployment, Progress,
     StatusServer, WindowsUpdate and Applications (and Drivers if enabled).
   - [ ] `Initialize` reported `Initialized` (`deployment.log`).
   - [ ] The automatically opened window (not elevated) shows the same stage states as
     `Resume-Deployment.ps1 -Status` run as administrator. This confirms that a standard token can
     see the deployment's scheduled tasks; if it cannot, a stage would show as missing its task.
3. **From a phone or another PC.**
   - [ ] The address opens the dashboard.
   - [ ] The same address without `#t=…` shows no data.
   - [ ] The status changes within about 7 s of the progress window.
4. **Windows Update.**
   - [ ] Optional updates appear in `Updates\result.json` (`counts.installedOptional`), including
     any optional chipset driver Settings > Windows Update > Advanced options > Optional updates
     listed before the deployment.
   - [ ] No feature update or Insider build is installed.
   - [ ] Any failure shows a named HRESULT and "Attempt n of 3".
5. **Restarts.**
   - [ ] After every Windows Update restart and sign-in, the window reopens, shows "Windows
     restarted (scheduled by WindowsUpdate…)", and the deployment continues without intervention.
   - [ ] Pull the power once during the application stage: after boot the feed says "restarted
     unexpectedly" and the stage resumes. No application is installed twice (`attempts.jsonl`).
6. **Applications.**
   - [ ] A failing application (as Chrome, Spotify or Battle.net did) is reported with WinGet's
     code and the installer's exit code.
   - [ ] The remaining applications still install.
7. **Watchdog.**
   - [ ] Optional: delete the `\WindowsDeploymentBuilder\WindowsUpdate` task while that stage runs.
     Within about 2 hours plus 5 minutes the monitor registers it again (activity: "Automatic
     recovery attempted").
8. **At the end.**
   - [ ] The report has the Device Manager section (compare with Device Manager), the verification
     per application, and the restart history.
   - [ ] The Progress task is gone, and no window opens at the next sign-in.
   - [ ] The dashboard shows the final results.
   - [ ] After 24 h, the StatusServer task and the firewall rule `WindowsDeploymentBuilder-Monitor`
     are removed.
9. **Permissions.**
   - [ ] `Get-Acl` on `C:\ProgramData\WindowsDeploymentBuilder\Package\scripts\*.ps1` shows SYSTEM,
     Administrators and Users entries (the `b97998a` fix).
