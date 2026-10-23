# Windows Update coordination

The Windows Update engine (Phase 2) stays the only update engine. The driver stage:

- never calls the Windows Update Agent, never changes `windowsUpdate.drivers`, the
  "ExcludeWUDriversInQualityUpdate" policy, the Phase 4.3 ongoing update policy, WSUS or any
  organization policy;
- **Inspection A** at its first start (Windows has just set up the devices with its inbox drivers);
- waits (`Get-WdvUpdatesGate`) until `Updates\state.json` is final or `Updates\result.json` exists, or the
  Windows Update stage is not part of the deployment, or it was never installed (30 min), or
  `waitForUpdatesHours` (= the Windows Update runtime limit + 2 h) passed;
- before **Inspection B** requests a restart if one is pending (the Windows Update keys, a restart
  marker of another engine, or a device with problem code 14), so a driver Windows Update installed is
  judged only after it has started. The Windows Update engine itself finishes `Succeeded` only when no
  restart is pending;
- records a device that works after Windows Update as **AlreadySatisfied** (source `windowsUpdate` when
  the deployment let Windows Update install drivers and the driver changed between the inspections).

## The owner default withholds drivers from Windows Update

`updates.excludeDrivers` is on in the owner default, so `windowsUpdate.drivers: followPolicy` resolves
to `exclude`: Windows Update installs no drivers. The driver stage still runs; missing drivers then come
from the driver store, the offline bundle and verified packages, or are reported (with "Windows Update
was not allowed to install drivers in this deployment"). To let Windows Update provide drivers, turn
off "Do not include drivers with Windows quality updates" and choose "Install drivers too" under
Windows Update automation; this is a deliberate owner choice and is not changed by the driver stage.

## Limitations

- Optional driver updates that Windows Update offers only on request (Settings › Optional updates) are
  not installed unless the Windows Update engine's `optionalUpdates` is set to install.
- Some manufacturers deliver drivers only through their own tools (Dell Command | Update, HP Image
  Assistant, Lenovo System Update) or as EXE installers; those are manual actions.
- Windows Update and the driver store may give a generic driver where an OEM-specific one would add
  features (e.g. hotkeys); a working device is still reported as healthy.
