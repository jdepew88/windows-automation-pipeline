# Progress, troubleshooting and recovery (Phase 4)

All commands run on the installed computer. `<Package>` is
`C:\ProgramData\WindowsDeploymentBuilder\Package`.

## Where to look

| What | Where |
|---|---|
| Live progress | Desktop shortcut **Deployment progress**, or `powershell -ExecutionPolicy Bypass -File "<Package>\scripts\orchestrator\Show-DeploymentStatus.ps1" -Watch` (read-only, no elevation) |
| Deployment state | `…\Deployment\status.json` (snapshot), `…\state\deployment.json` (orchestrator state) |
| Final report | `…\reports\deployment-report.txt` / `.json`, desktop shortcut **Deployment report** |
| Logs | `…\Deployment\logs\deployment.log`, `…\Updates\logs\engine.log`, `…\Applications\logs\engine.log` (+ `packages\` per package) |
| Engine results | `…\Updates\result.json`, `…\Applications\result.json`, `…\Applications\follow-up.txt` |
| Events | Application log, source `WindowsDeploymentBuilder`: 1000–1103 (Windows Update), 2000–2104 (applications), 3000 started, 3001 resumed, 3002 staging failed, 3003 integrity failed, 3100 Succeeded, 3101 CompletedWithFollowUp, 3102 CompletedWithFailures, 3103 Failed, 3104 Incomplete |
| Tasks | Task Scheduler › `\WindowsDeploymentBuilder\`: `WindowsUpdate` (SYSTEM), `Applications` (the user), `Deployment` (SYSTEM monitor). Each removes itself when finished. |

The progress view shows the deployment state, the current stage, each stage's state and status,
the application being installed and how many remain, restart counts, whether a restart is pending,
and a **NEEDS ATTENTION** block when a person must act.

## Recovery commands (elevated PowerShell)

| Situation | Command |
|---|---|
| A stage shows **Stalled** (its task disappeared without a result), the monitor task was deleted, or the deployment ended **Incomplete** because the deadline passed | `powershell -ExecutionPolicy Bypass -File "<Package>\scripts\orchestrator\Resume-Deployment.ps1"` — re-checks the package, re-registers the monitor, reopens a finished deployment with a new deadline. Launches nothing. |
| A stage ended **Offline**, **Failed**, or must run again (for example after fixing the network) | `… Resume-Deployment.ps1 -RestartStage windowsUpdate` or `-RestartStage applications`. Runs that engine's installer again; it archives the previous run (`*.bak`) and starts a new one. Installed updates are not offered again; installed applications are reported `AlreadyInstalled`. Run `applications` as the signed-in user (elevated), never as SYSTEM. |
| Only show progress | `… Resume-Deployment.ps1 -Status` |
| **StagingFailed** (missing or modified files at the first sign-in) | Nothing was launched. Fix the cause (see the log), then from the original USB package run `WindowsDeployment\setup.cmd` as administrator. |
| **IntegrityFailed** (a staged file changed afterwards) | The monitor stopped and runs nothing. Re-stage from the original package: `setup.cmd` as administrator, then `Resume-Deployment.ps1`. |
| Run the same deployment on a Windows installation that was not installed with this answer file | `WindowsDeployment\setup.cmd` as administrator (verifies, asks for `YES`, then stages and starts). |
| End the deployment now and write the report | `powershell -ExecutionPolicy Bypass -File "<Package>\scripts\finalization\Complete-Deployment.ps1" -Finish` (`-Preview` prints the report without ending anything). |

Never delete `state\deployment.json` while stages are running; it is what prevents duplicate
launches. Logs, results and state are never deleted automatically.

## Common causes

- **Applications wait for a long time:** they wait for Windows Update to finish (by design), then
  only run while the user is signed in. With automatic sign-in off they continue at the next
  sign-in.
- **Applications LaunchFailed "must be started by the signed-in user":** the orchestrator was run as
  SYSTEM (for example by hand from a SYSTEM shell). Sign in and run
  `Resume-Deployment.ps1 -RestartStage applications`.
- **Microsoft Store packages fail:** a Microsoft account may be required for some Store apps; they
  are reported for follow-up.
- **Drivers:** not part of this version. The report always lists manufacturer drivers as a
  remaining task; install chipset/graphics/OEM software manually if Windows Update did not provide
  them.

## Removing everything afterwards

The tasks remove themselves. To remove the deployment data (keeps the installed software):
delete `C:\ProgramData\WindowsDeploymentBuilder` and `C:\Windows\Setup\Scripts\Deployment`,
`…\WindowsUpdate`, `…\Applications` as administrator, and the two desktop shortcuts.
