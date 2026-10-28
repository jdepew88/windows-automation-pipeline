# Deployment package permissions: first bare-metal deployment failure

Found during the first physical Windows 11 installation (Core i7-7700K, GTX 1080, TPM, CPU and
Secure Boot bypasses on). Windows Setup and the first sign-in worked; Windows Update, the
applications and the drivers never started.

## Symptoms

- Files under `C:\ProgramData\WindowsDeploymentBuilder` (staged scripts, `deployment.log`, JSON
  state) had owner `BUILTIN\Administrators`, `AreAccessRulesProtected: True` and **no** access
  entries. Nobody could read them, not SYSTEM and not an elevated administrator.
- The status viewer showed Windows Update, Applications and Hardware & drivers as `Stalled` with
  missing scheduled tasks; the log stopped after its first line.
- After `icacls … /inheritance:e /T`, the viewer worked; `Resume-Deployment.ps1 -RestartStage
  windowsUpdate` printed `Resume: Resumed`, no Windows Update task appeared, the files were
  unreadable again, and `\WindowsDeploymentBuilder\Deployment` went from LastTaskResult 0 to 1.

## Root cause

Five places protected a folder with the same command:

```powershell
icacls.exe <folder> /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /T /C /Q
```

- `scripts/bootstrap/Stage-Deployment.ps1` (`Set-WddAcl`, called before and after staging)
- `scripts/windows-update/Install-UpdateEngine.ps1`
- `scripts/applications/Install-ApplicationEngine.ps1`
- `scripts/drivers/Install-DriverEngine.ps1`
- `scripts/applications/ApplicationEngine.ps1` (`Protect-WdaBackupFolder`)

With `/T`, icacls applies the same command to every item below. On a **file**, `/inheritance:r`
removes the inherited entries and makes the list protected, and the grants with container
inheritance flags `(OI)(CI)` are not applied to a file. Each file is left protected with an empty
list. Folders keep their entries, so nothing looked wrong at folder level. With `/C`, icacls also
exits with **0** although it failed, so the `$LASTEXITCODE` checks never fired. This was reproduced
with real icacls on Windows 11 (`tests/powershell/Acl.Tests.ps1`, first scenario).

What happened on the computer, in order:

1. First sign-in: `Initialize-Deployment.ps1` writes the first log line, runs `Set-WddAcl` (log and
   state files emptied; later log writes fail silently), stages the package (new copies inherit
   correctly), then runs `Set-WddAcl` again. **Every staged script is now unreadable.**
2. Each engine installer is started from the staged copy and cannot be read, so no stage task is
   registered (Stalled, "task missing").
3. The monitor task (SYSTEM) cannot read `DeploymentOrchestrator.ps1` and fails (LastTaskResult 1).
4. After the manual `icacls /inheritance:e` repair, `Resume -RestartStage windowsUpdate` runs the
   staged `Install-UpdateEngine.ps1`. Its own icacls call (`/T` on the whole data root) empties the
   package again, then it cannot copy its own files and stops before registering its task.
5. `Resume-Deployment.ps1` ignored the launch result and returned `Resumed` anyway.

It was not caused by a file copy, by integrity verification or by `File.Replace`: those create
files that inherit correctly (tested). The tests had never caught it because the test simulator
replaces `Set-WddAcl` with a counter and the engine installers are not run as a whole.

## Fix

**Permissions.** Every protection function now:

- sets the protected entries on the folder itself only (no `/T`), as inheritable entries;
- lets Windows propagate them to everything below that inherits;
- repairs what an earlier version left behind: files protected with no entries, and folders with a
  protected copy of the same entries, inherit again;
- leaves deliberately private folders alone (the per-user settings backup has other entries);
- drops `/C`, so a failure throws.

Result: SYSTEM and Administrators have full control and Users have read & execute on every staged
script, log and JSON file. New files inherit the same entries, and running it again (restage,
Resume, each engine installer) changes nothing. The settings backup stays limited to SYSTEM,
Administrators and the deployment user.

**Honest failure reporting.**

- **`Resume-Deployment.ps1`:**
  - checks the launch result. A stage whose task is not registered returns `StageRestartFailed`
    (exit 1) with the installer's reason, records it in the state and writes event 3006;
  - reports a monitor task that cannot be registered as `MonitorRegistrationFailed`;
  - accepts `-RestartStage drivers`.
- **`Initialize-Deployment.ps1`:**
  - a failed launch records the expected task and the installer's last output line (for example
    "Access to the path … is denied"), not just an exit code;
  - an installer missing from the package is named;
  - a monitor that cannot be registered ends `MonitorRegistrationFailed` instead of an unhandled
    error.
- **`DeploymentRecovery.ps1`:**
  - a stage counts as restarted only when its task exists afterwards;
  - Resume or Retry return `Failed` (exit 6) or `Partial` (exit 5) when a stage task could not be
    registered, never `Done`.
- **`DeploymentCommon.ps1`:** a log that cannot be written produces a warning once per process
  instead of silence.

Recovery never repeats Windows Setup and never touches a disk. State, logs, manifests and
completed records are kept.

## Repairing the installed computer (no reinstall)

The installed package still contains the old engine installers, so **do not run
`Resume-Deployment.ps1` or `DeploymentRecovery.ps1` from it**: they would empty the permissions
again. Run everything in **Windows PowerShell as administrator**, signed in as the account that
should receive the applications.

1. Repair the permissions, so the status viewer and logs work again:

   ```powershell
   $r = 'C:\ProgramData\WindowsDeploymentBuilder'
   icacls.exe $r /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX'
   icacls.exe "$r\*" /reset /T
   ```

   Both must end with `Failed processing 0 files`. The second command makes everything below
   inherit from the folder. On this computer no settings backup was staged, because the application
   stage never ran. If `$r\Backup` exists, re-protect it afterwards with
   `icacls.exe "$r\Backup" /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "*$([Security.Principal.WindowsIdentity]::GetCurrent().User.Value):(OI)(CI)F"`.

2. Create a new deployment package with the fixed builder, using the same settings. You can import
   `WindowsDeployment\profiles\windows-settings.json` from the original ZIP; passwords are not in it
   and are not needed here. Copy its `WindowsDeployment` folder to the computer (USB stick or local
   disk).

3. Set the stuck deployment record aside. It is renamed, not deleted, so it stays available for
   reference. Without this, the new package is refused as "a different deployment is still in
   progress".

   ```powershell
   $stamp = Get-Date -Format yyyyMMddHHmmss
   Get-ChildItem "$r\state" -Filter 'deployment.json*' | Rename-Item -NewName { "$($_.Name).stuck-$stamp" }
   ```

4. Start the deployment from the new package: right-click `WindowsDeployment\setup.cmd`, choose
   **Run as administrator** and type `YES`. It verifies and stages the package (the old copy is kept
   as `Package.previous`), registers the monitor and launches Windows Update (SYSTEM), the
   applications (this account) and the drivers. It does not partition, format or reinstall
   anything.

5. Check:

   ```powershell
   Get-ScheduledTask -TaskPath '\WindowsDeploymentBuilder\' | Get-ScheduledTaskInfo | Format-Table TaskName, LastTaskResult, LastRunTime
   & "$r\Package\scripts\orchestrator\Show-DeploymentStatus.ps1"
   ```

   You should see `Deployment`, `WindowsUpdate`, `Applications` and `Drivers`, and the stages
   moving out of `Stalled`. Afterwards a stage can be restarted with the new package's
   `Resume-Deployment.ps1 -RestartStage windowsUpdate|applications|drivers`. A failure now says
   `StageRestartFailed` and gives the reason.

## Tests

- `tests/powershell/Acl.Tests.ps1`: 25 real NTFS scenarios, Windows only, run from
  `tests/unit/powershell.test.ts` and `npm run test:ps`. Each takes the shipped functions from the
  generated package and runs real icacls on folders under `%TEMP%`. They cover:
  - the old command reproducing the field failure;
  - SYSTEM, Administrators and Users entries on every item for all five functions;
  - a staged script running in a new process;
  - idempotence and repair of a damaged tree;
  - logs and JSON written afterwards, including the atomic replace;
  - the private backup folder;
  - failures throwing;
  - the full field sequence with the real staging code.
- `tests/powershell/Deployment.Tests.ps1`, five new scenarios:
  - a stage with no task records its reason;
  - `Resume -RestartStage` with the task missing returns `StageRestartFailed`, then recovers;
  - a monitor that can't be registered fails Resume and Initialize;
  - the recovery tool's Resume returns `Failed` and then recovers.
- `tests/unit/acl-commands.test.ts`: no shipped icacls call combines `/T` with `(OI)`/`(CI)`, and no
  exit-checked call uses `/C`.

What the tests cannot show: they run as an unelevated user, so SYSTEM's own access and the task
scheduler are not exercised for real. Entries are checked by SID and rights, and scripts are run as
a member of Users. Nothing in the tests registers a task or changes system folders.
