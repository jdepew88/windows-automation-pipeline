# Spare-computer retest: Retry Windows Update without reinstalling Windows

This tests the corrected Windows Update engine (2.0.0) on the spare computer whose deployment reported 16 updates failed with `0x80131508`. Nothing is erased and Windows is not reinstalled. The original deployment's Windows Update results, logs and reports are only read, never changed; a retry adds its own lines to the deployment's activity log and the Application event log.

## What you need

- **The Windows Update recovery download.** `windows-update-recovery.zip` comes from the website's Deployment package page, under "Windows Update recovery" (`https://deploy.88pockets.app/downloads/windows-update-recovery.zip`). From a source checkout, run `npm run build` (writes `dist/downloads/`) or `npx vite-node scripts/build-update-recovery-kit.ts --out <zip>`.
- **The ZIP's contents:**
  - `WDB-WindowsUpdate\WindowsUpdateEngine.ps1`, engine 2.0.0;
  - `WDB-WindowsUpdate\Invoke-WindowsUpdateRetry.ps1`;
  - `README.txt`, the same procedure;
  - `files.json`, which holds the SHA-256 of every file.
- The first spare-computer run used an earlier development download (`WDB-Maintenance\windows-update\`) with the same engine, byte for byte. The retry tool there lacked one later safeguard: another kind of retry is now refused while a run is unfinished (all runs share one scheduled task).
- **The computer:** an administrator account, and the network connected.

Copy the ZIP to the spare computer, extract it (for example to `C:\WDB-WindowsUpdate`), and open **Windows PowerShell as administrator** in `C:\WDB-WindowsUpdate`.

> In every command below, `RW` stands for
> `powershell.exe -ExecutionPolicy Bypass -File .\Invoke-WindowsUpdateRetry.ps1`.

## Procedure

1. **Preserve the original evidence (read-only).**

   `RW -Mode ExportDiagnostics`

   This writes `WDB-WindowsUpdate-diagnostics-<computer>-<time>.zip` on the desktop. It contains copies of:
   - `C:\ProgramData\WindowsDeploymentBuilder\Updates` (engine.log, state.json, result.json);
   - `reports\deployment-report.txt` and `.json`, which the "Deployment report" shortcut opens;
   - the Windows Update history and event log;
   - the devices with problems.

   Keep this ZIP: it is the "before" picture. Send it back if anything below is unexpected.

2. **Diagnose (read-only).**

   `RW -Mode Status`

   Expected output:
   - "Original deployment: CompletedWithFailures (engine 1.x), installed 0, failed 16";
   - "failures by code: 0x80131508 x16";
   - the line "engine 1.x collection defect (0x80131508)";
   - a NEXT line naming RetryUpdates and RetryDrivers.

   It also shows the services, any pending restart, and the devices with problems.

3. **Check readiness and what would be installed (read-only).**

   `RW -Mode Scan`

   Lists every update Windows Update offers now, with its pass:
   - **A:** servicing prerequisites;
   - **B:** normal updates;
   - **C:** optional updates and drivers, each driver with the device it is for.

   Nothing is downloaded or installed.

4. **Install the normal updates.**

   `RW -Mode RetryUpdates -Wait`

   - This starts a separate run in `C:\ProgramData\WindowsDeploymentBuilder\UpdateRetry\<run>`, under the scheduled task `\WindowsDeploymentBuilder\WindowsUpdateRetry` (SYSTEM).
   - If Windows already has a restart pending, it restarts once before installing anything.
   - It installs pass A, then pass B, and restarts when an update requires it, with a 60-second warning.
   - After a restart, sign in, open an elevated PowerShell in the same folder and run `RW -Mode Status`. The task continues by itself; run `RW -Mode RetryUpdates -Wait` again to follow it, which resumes the same run rather than starting a new one.

5. **Install the drivers.**

   `RW -Mode RetryDrivers -Wait`

   Drivers are installed one at a time, and each is recorded with its device's hardware ID and model.

   Start this once step 4's run has finished (`RW -Mode Status` lists it as finished). Every retry uses the one task `\WindowsDeploymentBuilder\WindowsUpdateRetry`, so another kind of retry is refused while a run still owns it, and nothing is changed.

6. **After the last restart, verify.**

   `RW -Mode Status`

   Every retry should be listed as finished: Succeeded, CompletedWithFollowUp or CompletedWithFailures. The devices with problems are listed again.

7. **Inspect Device Manager.** Compare the devices still listed with the deployment report. A code-28 device is one with no driver. Its hardware ID is in the retry's `result.json` (`verification.devicesWithProblems`) and in `RW -Mode Status`.

8. **Export the comparison.**

   `RW -Mode ExportDiagnostics`

   The new ZIP contains `comparison.txt`, which shows:
   - the original run against each retry: status, installed, failed, engine version and devices;
   - which originally failed updates are now installed;
   - which still fail, with their category;
   - the devices with problems now.

## What a good result looks like

- **Installed updates.** The retry installs the updates the original run reported as failed, or reports them as **no longer offered**. Since the original run, Windows' own automatic updates may already have installed some of them.
- **No engine errors.** No failure has the category `EngineException`, and `engineExceptions` in the retry's `result.json` is empty.
- **Remaining failures are real Windows Update results.** Anything that still fails carries a code and category from Windows Update itself, for example `InstallerFailure 0x800F0922` or `NotApplicable`, never `0x80131508`.

If a retry stops with `EngineException`, it was stopped deliberately after the same exception twice; it did not loop. Send the diagnostics ZIP back. Its `result.json` (`engineExceptions`) contains the operation, script line, statement and stack trace.

## Also available

- **From an installed deployment package:** `powershell.exe -ExecutionPolicy Bypass -File C:\ProgramData\WindowsDeploymentBuilder\Package\scripts\recovery\DeploymentRecovery.ps1 -Action RetryWindowsUpdate -UpdateMode Status`, or menu **U** in Deployment Recovery. This needs a package built with engine 2.0.0 or later; the spare computer's package predates it, so use the download there.

## Result on the spare computer (2026-11-27)

Reported by the owner after following this procedure:

| | Original deployment | Retry with engine 2.0.0 |
|---|---|---|
| Engine | 1.3.0 | 2.0.0 |
| Status | CompletedWithFailures | 0 failed retries |
| Installed | 0 | 1 normal update, 9 drivers |
| Failed | 11 (`0x80131508`) | 0 |
| Devices with problems | | 0 |
| Pending restart | | False |
| Retry task | | not registered (removed itself) |

Original failures recovered: 9; still failing: 0. Final diagnostics:
`WDB-WindowsUpdate-diagnostics-JOE-COMPUTER-20261127-120916.zip` (on that computer, not in this
repository).

## What this does and does not prove

- **Proven on hardware:** engine 2.0.0 downloads and installs normal updates and drivers through the
  real Windows Update Agent, records each driver with its device, and leaves no retry task behind.
- **Not yet proven on hardware:** a complete deployment with engine 2.0.0 from the start
  (readiness, passes A to D and restarts during the first sign-in). That is the next physical test:
  a new deployment package generated from the website.
