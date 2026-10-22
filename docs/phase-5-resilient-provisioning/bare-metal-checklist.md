# First bare-metal test: checklist

**Status: NOT YET PERFORMED.** Nothing in this project has been validated on real hardware or in
a VM. The first real installation will be on bare metal (not Unraid). This checklist prepares it;
record the results in `docs/validation-log.md`. Do not treat a successful boot into Windows as the
end of provisioning: the deployment is finished only when the report says so.

## Before you start (safety)

- [ ] A **spare computer, or an expendable destination drive**. Disconnect every other internal
      and external drive you care about (data disks, backup drives), so they cannot be chosen by
      mistake.
- [ ] A **known-good backup or recovery path** for that computer (vendor recovery media, a
      disk image, or nothing of value on it).
- [ ] **Official Windows 11 Pro x64 media** (Media Creation Tool, or an official ISO written with
      Rufus with every "Customize Windows installation" option turned **off**).
- [ ] Generate the package with Quick Deployment: username **`owner`** (prefilled; change it only
      if intended), the computer name you want, Windows 11 Pro, x64, and a **small application
      selection** (Core Essentials, or Core Essentials plus one or two apps). Keep the defaults for
      Reliability & recovery (automatic retry on, 3 attempts, recovery tool included).
- [ ] **Controlled network**: Ethernet, or the Wi-Fi network you entered; know how to unplug it
      (needed for test 8 below).
- [ ] Extract the ZIP to the USB root; `autounattend.xml` must be in the root, next to `setup.exe`.
- [ ] Keep a second computer or phone at hand to read this checklist and take photos of screens.

## During Windows Setup

- [ ] Setup stops at **"Where do you want to install Windows?"**. Nothing selects or wipes a disk
      automatically. **Select and double-check the destination disk yourself** (size, name). If you
      are not sure which disk it is, stop and turn the computer off.
- [ ] Do not use any disk-wiping step as part of this test.

## First-run validation

| # | Check | How | Result |
|---|---|---|---|
| 1 | Windows Setup completes | Reaches the desktop without errors | |
| 2 | Correct edition | `winver`, or Settings › System › About: Windows 11 Pro | |
| 3 | Correct local account | Signed in as `owner` (or your name), an administrator | |
| 4 | Computer name | Settings › System › About shows the name you entered | |
| 5 | Deployment staged on the internal drive | `C:\ProgramData\WindowsDeploymentBuilder\Package\deployment-manifest.json` exists; desktop shortcuts **Deployment progress** and **Deployment recovery** | |
| 6 | Initial Windows Updates run | Deployment progress shows Windows Update Scanning / Installing; `Updates\logs\engine.log` | |
| 7 | Restarts resume | After each restart the progress window or `status.json` continues; no stage starts from scratch; `state\deployment.json` keeps `monitorRuns` growing | |
| 8 | Network loss is survived | During the application stage, unplug the network for ~10 minutes: `Deployment\status.json` shows `outcome` `PausedAwaitingNetwork`, no application turns `Failed` because of it; plug it back: installation continues | |
| 9 | Selected applications install | Each is in the Start menu / `winget list`; `Applications\result.json` lists `Succeeded` or `AlreadyInstalled`; manual ones (RustDesk) are `RequiresInteraction` with instructions | |
| 10 | Failed applications can be retried | If one failed: Deployment recovery › Retry failed operations; only that one runs again, the others keep their attempt counts. If none failed: Deployment recovery › Retry one application with the id of an installed one (from Status): expect "already installed" and nothing runs | |
| 11 | Final result is accurate | `reports\deployment-report.txt`: outcome and code match what you saw; every application listed with its attempts; outstanding work listed | |
| 12 | Technician can recover logs and state | Deployment recovery › Export diagnostic report: a ZIP on the desktop or in `reports\`; open it and confirm it contains logs and states and **no password** (search for the Wi-Fi password if you set one) | |
| 13 | USB not needed | Remove the USB drive after the first sign-in; the deployment continues | |
| 14 | Ongoing update policy | After Windows Update has finished: `Updates\policy-result.json` `Applied`; Settings › Windows Update offers "Install now" | |

Also observe (record in the log): total time, number of restarts, any prompt that appeared on
screen, any application that needed interaction.

## Collecting evidence

- `C:\ProgramData\WindowsDeploymentBuilder\reports\deployment-report.txt` and `.json`
- `C:\ProgramData\WindowsDeploymentBuilder\Deployment\status.json`
- The diagnostics ZIP (Deployment recovery › Export diagnostic report)
- Event Viewer › Windows Logs › Application, source `WindowsDeploymentBuilder` (IDs 1xxx update
  engine, 2xxx applications, 3xxx deployment: 3005 recovery, 3004 damaged state)
- Task Scheduler › `\WindowsDeploymentBuilder\` (the tasks remove themselves when finished)

## If something goes wrong

| Symptom | Do this |
|---|---|
| Setup did not find the answer file | `autounattend.xml` is not in the USB root; re-extract |
| Deployment progress never appeared | Sign in again; check `Deployment\logs\deployment.log`; run `setup.cmd` from the USB package as administrator |
| Stuck on one stage for hours | Deployment recovery › Status; then Resume |
| An application failed | Deployment recovery › Pending actions, then Retry failed operations |
| "The deployment state is damaged" | Deployment recovery › Resume (rebuilds it) |
| Need to start completely over | Reinstall from the USB drive (re-check the disk selection) |

Do not claim bare-metal validation in any document until this checklist has been completed and
recorded.
