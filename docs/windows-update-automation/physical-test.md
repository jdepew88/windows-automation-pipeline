# Physical test: engine 2.1.0, the health audit and the final Settings refresh

What is verified only by simulation is listed in [README.md](README.md#verified-and-still-to-verify-on-hardware). This procedure checks it on real hardware:

- **Part A** uses the existing spare computer, with no reinstallation.
- **Part B** is a clean installation with a new package.

Use an elevated Windows PowerShell throughout. Note the time before every step that changes something.

## Part A: the existing spare computer (no reinstallation)

1. **Get the tools.** From `https://deploy.88pockets.app` (or `https://deploy-wdb.pages.dev`), go to the Deployment package page, "Windows Update recovery and health audit", and choose Download (ZIP). Extract it to `C:\WDB-WindowsUpdate`, then `cd C:\WDB-WindowsUpdate`.

   It contains engine 2.1.0, Retry Windows Update 1.1.0 and `health\DeploymentHealth.ps1`. `files.json` lists the SHA-256 of every file.

   > `RW` below stands for `powershell.exe -ExecutionPolicy Bypass -File .\Invoke-WindowsUpdateRetry.ps1`.

2. **Preserve the evidence (read-only).** Run `RW -Mode ExportDiagnostics`. Keep the ZIP from the desktop.

3. **Check the recovery history and the advice (read-only).** Run `RW -Mode Status`.

   Expected:
   - the original run (engine 1.3.0, 11 failed);
   - both earlier retries listed as finished, with their counts;
   - **no** "Run RetryUpdates, then RetryDrivers". Instead: "Recovery complete: RetryUpdates Succeeded, RetryDrivers Succeeded. No further retry is needed; run the health audit".
   - Retry task: not registered.

   If it still suggests a retry, send the diagnostics ZIP back.

4. **Run the health audit (read-only).** Run `RW -Mode HealthAudit`.

   It writes `C:\ProgramData\WindowsDeploymentBuilder\reports\health\deployment-health.json` and the HTML report. Open the HTML report (or run `.\health\DeploymentHealth.ps1 -Mode Dashboard`) and check:
   - **Original failures stay historical.** The 11 original failures are listed as the original deployment's history, never as successes. Those installed later show "originally failed; installed later on … by retry … / Windows Update".
   - **Recovery history.** Both retry runs are listed.
   - **Devices.** Device problems are 0. The Intel SM Bus Controller and the PCI Memory Controller, if the original deployment reported them, show as previously reported and now healthy.
   - **Manufacturer recommendations.** These match the hardware: NVIDIA App only with an NVIDIA GeForce or RTX GPU, Adrenalin only with an AMD Radeon GPU, and Ryzen Master only with a desktop Ryzen CPU. Each shows "installed" or a manual download link.
   - **Applications and Office.** Applications show as installed and verified, or missing; Office appears only if it was selected.
   - **Last check.** "Windows Update (Settings) last successful check" shows a time on Windows 11 24H2 and later.

5. **Confirm the nine Intel drivers are recognised as installed (read-only).** Run `RW -Mode Scan`.

   Expected: none of the nine Intel drivers is offered again, because Windows does not offer an installed driver. In the health audit, Windows Update history lists them as installed by the retry.

   If Windows offers a newer version of one, it is a new update, shown in the `Class` column as `driver`.

6. **Identify the remaining previews (read-only).** In the `RW -Mode Scan` output, look at the `Class` column:
   - `windowsPreview` is a Windows cumulative preview;
   - `dotnetPreview` is a .NET Framework preview.

   They show "Install" when the deployment's policy includes previews, or "Skip … preview updates excluded" when it does not. Compare with Settings > Windows Update > Optional updates and note any preview that Settings shows but Scan does not. That would be an offer outside the Windows Update Agent, to report back.

7. **Install the previews and test the final Settings refresh.**
   1. Note the "Last checked" time under Settings > Windows Update, then close Settings.
   2. Run `RW -Mode RetryUpdates -Wait`. It installs whatever Windows updates are still offered, previews included when the policy allows. It restarts if needed; after signing in, run `RW -Mode Status` and follow it again with the same command.
   3. When it has finished, open `C:\ProgramData\WindowsDeploymentBuilder\UpdateRetry\<newest run>\result.json` and record:
      - `updateState` and `summary`;
      - `settingsRefresh.available`, `.requested`, `.completed`, `.lastSuccessfulScanBefore` and `.lastSuccessfulScanAfter`.
   4. Open Settings > Windows Update **without** clicking "Check for updates". Record:
      - the "Last checked" time;
      - whether it matches `lastSuccessfulScanAfter`;
      - whether any optional update is still listed.

   This is the only check that Settings visibly refreshed. The engine never claims it.

8. **Run the health audit again and export the diagnostics.** Run `RW -Mode HealthAudit`, then `RW -Mode ExportDiagnostics`. Send the ZIP back.

## Part B: a clean installation with a new package

1. **Generate the package.** On the website, generate a deployment package with the owner default. "Install preview updates" is on by default, under Advanced > Windows Update. Add the applications and Office edition you want to test.
2. **Install Windows.** Extract the package to the installation USB and install Windows, formatting the disk as usual. Do not intervene during the deployment.
3. **Watch the deployment, without acting.** Use the progress window or the LAN monitor. Expected:
   - readiness, then passes A, B and C;
   - automatic restarts with the 60-second warning, and automatic resumption after each;
   - the applications installing after Windows Update, with the install lock respected;
   - Office, if selected;
   - "Asking Windows Update (Settings) to check for updates";
   - verification.

   **Do not** run any Retry mode during this test.
4. **When the deployment report appears**, check that the Windows Update section shows:
   - `Engine: 2.1.0`;
   - `Update state: UpToDate`, `UpToDateUnderPolicy` or `PreviewUpdatesExcluded`;
   - the counts;
   - `Settings refresh: … completed True`;
   - drivers with their devices;
   - `Final check: … 0 device(s) with problems`.
5. **Open Settings > Windows Update without clicking anything.** Record the "Last checked" time and what is listed. Ideally it says "You're up to date", or lists only what the policy excluded.
6. **Open Device Manager.** Look for devices with a yellow mark. Compare them with the report's devices with problems.
7. **Check the health report** (the desktop "Deployment health" shortcut, or `DeploymentHealth.ps1 -Mode Dashboard`):
   - applications installed and verified;
   - Office edition, version, and activation status;
   - the manufacturer recommendations;
   - overall Ready or ReadyWithWarnings.
8. **Export diagnostics.** Run Deployment Recovery > 6 and `RW -Mode ExportDiagnostics`, then send both back.

## What a good result looks like

- **Updates.** No `0x80131508` and no `EngineException`. `updateState` is `UpToDate`, `UpToDateUnderPolicy`, or `PreviewUpdatesExcluded` when previews are off.
- **The previews Settings offered are installed** when previews are on.
- **Settings refresh:** `available` true, `requested` true and `completed` true on 24H2 and later, with Settings showing a recent "Last checked" without a click.
- **Devices.** Zero devices with problems, and no driver the engine reports as installed is still offered.
- **The health audit** separates history (original failures) from the current state, and recommends no unnecessary retry.
