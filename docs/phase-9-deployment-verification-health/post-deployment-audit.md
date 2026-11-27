# Post-deployment audit (health engine 1.1.0)

Health engine 1.1.0 extends the Phase 9 verification (`DeploymentHealth.ps1`). The audit is still
**read-only**: it writes only its own report files. It never installs, removes, restarts, cleans
up, changes a setting or starts a Windows Update scan, except for the read-only search that
`-ScanUpdates` asks for.

## Running it later, without replaying the deployment

Run these from an elevated Windows PowerShell 5.1. They use the copy staged on the computer:

```
powershell.exe -ExecutionPolicy Bypass -File C:\ProgramData\WindowsDeploymentBuilder\Package\scripts\health\DeploymentHealth.ps1 -Mode Verify
powershell.exe -ExecutionPolicy Bypass -File C:\ProgramData\WindowsDeploymentBuilder\Package\scripts\health\DeploymentHealth.ps1 -Mode Dashboard
powershell.exe -ExecutionPolicy Bypass -File C:\ProgramData\WindowsDeploymentBuilder\Package\scripts\health\DeploymentHealth.ps1 -Mode Verify -ScanUpdates
```

- `-Mode Verify` checks the computer and writes the reports. Its exit code is the overall state:
  0 Ready, 10 ReadyWithWarnings, 20 NeedsAttention, 30 Incomplete, 50 Unverifiable, 60 Failed.
- `-Mode Dashboard` runs the same check, then opens `technician-report.html`.
- `-ScanUpdates` also asks Windows Update which updates are still available. This search is
  read-only.

### Side effects of Verify

Verify writes these files and entries:

- `C:\ProgramData\WindowsDeploymentBuilder\reports\health\`:
  - `deployment-health.json`
  - `technician-report.html`
  - `technician-report.txt`
  - `customer-handoff.json`
  - `customer-handoff.html`
  - `history\` (each earlier report moves here)
- One line in `Deployment\logs\deployment.log`.
- One event in the Application log, from the deployment's existing event source.

The startup re-check task (`\WindowsDeploymentBuilder\HealthCheck`) is registered only by
`Invoke-WdhAfterDeployment`. The deployment calls it when it ends with a restart pending. Running
Verify by hand never registers or removes a task. The Health scenario `W5` checks that a
verification leaves every other file, including the Retry Windows Update runs, unchanged.

### Standalone copy (recovery download)

The audit can also run from a standalone folder (`health\DeploymentHealth.ps1`,
`health\HealthReport.html`, `common\DeploymentCommon.ps1`). It then reads the following from
`C:\ProgramData\WindowsDeploymentBuilder\Package\`:

- `deployment-manifest.json`;
- `health-config.json`, unless a copy sits beside the script.

It renders its reports with the template beside the script. It falls back to the package's
template only when that file is missing, so an older package never renders a newer report. Every
health-config section added in 1.1.0 is optional:

- `office`
- `activation`
- `windowsUpdate.previewUpdates`

## What 1.1.0 adds

### Windows Update (category `updates`)

These checks use update engine 2.1.0 results: `Updates\result.json` and
`UpdateRetry\<runId>\result.json`. The 2.1.0 fields are optional: results from engines 1.x and
2.0.0 are read exactly as before.

**`updates.state`.** The `updateState` of the most recent finished result decides this finding.
The current state comes from the latest finished retry run, or from the deployment's own result
when no retry run has finished.

| updateState | Finding |
|---|---|
| UpToDate, UpToDateUnderPolicy, PreviewUpdatesExcluded | Pass |
| RestartRequired, UpdatesRemaining | Warning |
| InstallationIncomplete, CompletedWithFailures | Fail (recovery action RetryFailed) |
| VerificationUnavailable | Unverifiable. It becomes Info when a live `-ScanUpdates` search finds no required update. |

When `updateState` is known, `updates.stage` is only Info: a finished installation is never a
Pass by itself.

**`updates.stage` and `updates.originalState`.** These describe the deployment's own result. It
is the historical record and is never rewritten or reinterpreted. When a later retry run exists,
`updates.stage` is labelled "Original deployment (historical record, unchanged)".

**`updates.kb.<KB>` and `updates.update.<hash>`.** There is one finding for each original
failure.

- **Installed later (Info).** The update appears in a retry run's `installed[]` (same KB or exact
  title), or Windows Update's history (`Get-WdhUpdateHistory`, read-only `QueryHistory`) records a
  successful installation after the deployment finished. The text then reads: "Originally failed
  (historical record, unchanged) ... Installed later on <date> by <Retry Windows Update run X |
  Windows Update>".
- **Otherwise (Fail),** exactly as before.

**`updates.retry.<runId>`.** There is one finding for each Retry Windows Update run.

| Run state | Finding | Condition |
|---|---|---|
| Finished | Info | `state.json` has `final`. |
| Running or awaiting restart | Pending | No `final` yet, and the `\WindowsDeploymentBuilder\WindowsUpdateRetry` task exists. Only the newest unfinished run can be the one the task serves. |
| Stopped before finishing | Warning | No `final`, and no task. |

**`updates.scope` and `updates.previews`.** These report the policy that applied. They read the
policy of the engine's result first, then the deployment configuration.

- Feature updates are reported as skipped.
- Optional updates, drivers and preview updates are reported as excluded only when the policy
  says so.
- Before engine 2.1.0 there was no separate preview setting: previews followed `optionalUpdates`,
  and the report says so (`policy.previewSource = optionalUpdates`).

**`updates.settingsRefresh`.** This reports the engine's final Settings refresh. It distinguishes
three cases: not available or not requested, scan requested, and scan completed (the last
successful scan timestamp advanced). It always states that the Settings page display itself is
**not** verified (`settingsDisplayVerified` is always `false`).

**`updates.settingsLastCheck`.** Title: "Windows Update (Settings) last successful check". It
comes from `Get-WdhOrchestratorScan`, which reads only `LastSuccessfulScanTimestamp`, `IsScanning`
and `IsWorking` of `Windows.Management.Update.WindowsUpdateManager` and never starts a scan. The
finding is Info "Not available" on Windows versions before 11 24H2.

**`updates.drivers`.** This lists the drivers that Windows Update installed, from `drivers[]`.

### Device Manager (category `drivers`)

The audit compares the devices the deployment reported with problems with Device Manager now. It
reads them from two places: `Updates\result.json` `verification.devicesWithProblems`, and the
deployment report's `windowsUpdate.verification`.

| State | Finding | What it means |
|---|---|---|
| NowHealthy | Info (`drivers.previous.<hash>`) | The device has problem code 0 now. |
| StillHasProblem | The device's own finding, at its existing severity | The text adds "already reported by the deployment (code N)" and the hardware ID. |
| NotPresent | Info | The device is not present now. |

Zero device problems is a hardware-health result. It is not proof that every optional driver was
installed, and the `drivers.devices` finding says so.

### Applications

`Find-WdhInstalled` is the detection: it looks in Windows. `Resolve-WdhAppVerdict` is the
verdict: it weighs that detection against the engine's own record. The two are separate functions
so a later catalog can extend either one. Each application carries a `verification` status:

| Status | Meaning |
|---|---|
| InstalledAndVerified | Windows lists the application. |
| InstallerSucceededUnverified | The installer reported success, but Windows lists nothing that matches. Reported as a Warning, never a Pass. |
| Missing | The application is not found. |
| Failed | The installation failed. |
| ManualActionRequired | A person has to install or finish it. |
| Pending | The installation is still running or waiting. |
| Deferred | The verdict waits for the user context. |
| NotSelected | The application was not selected for this deployment. It is not listed in `applications`. |

An installer exit code alone never makes an application "installed".

### Microsoft Office (category `applications`)

These checks run only when health-config `office.product` is not `none`.

**`office.install`.** This reads `HKLM\SOFTWARE\Microsoft\Office\ClickToRun\Configuration`:
`ProductReleaseIds`, `VersionToReport` and `Platform`.

| Result | Finding |
|---|---|
| Expected product present | Pass |
| Another Office product present | Warning |
| Office stage still running | Pending |
| Office stage reported success, but the configuration is absent | Fail (InstallerSucceededUnverified) |
| Registry could not be read | Unverifiable |

**`office.activation`.** This uses only what the activation stage recorded: the deployment state's
`activation.office`, else `Activation\result.json`. Messages are stripped of key fragments and KMS
hosts. No key or host is ever printed.

### Manufacturer software (category `hardwareSoftware`)

Every finding here is Info with `Required $false`. Nothing is ever installed: `automaticInstall`
is always `false`, with the reason "No verified WinGet package (checked microsoft/winget-pkgs) and
the vendor installer's unattended mode is not verified".

| Utility | Recommended when | Official page |
|---|---|---|
| NVIDIA App | Display adapter with PCI `VEN_10DE` and GeForce, RTX, TITAN or Quadro in its name | https://www.nvidia.com/en-us/software/nvidia-app/ |
| AMD Software: Adrenalin Edition | Display adapter with `VEN_1002` and "Radeon" in its name | https://www.amd.com/en/products/software/adrenalin.html |
| AMD Ryzen Master | An "AMD Ryzen" processor in a desktop chassis: no portable chassis type and no battery | https://www.amd.com/en/products/software/ryzen-master.html |

- **NVIDIA App.** No account is required for driver updates.
- **AMD Software: Adrenalin Edition.** It is never recommended because of an AMD processor alone.
- **AMD Ryzen Master.** It is an optional monitoring and tuning tool, not a chipset driver.
  Windows Deployment Builder never applies tuning, overclocking, undervolting, voltage, BIOS or
  profile changes.

The installed state comes from the uninstall records. The display names checked are "NVIDIA App",
"AMD Software" and "AMD Ryzen Master".

## Report fields (deployment-health.json, schemaVersion 1, engineVersion 1.1.0)

New top-level fields. They are validated by `HealthReportSchema` and described in the published
`deployment-health.schema.json`.

- **`windowsUpdate`:**
  - `partOfDeployment`, `checkedUtc`;
  - `original` and `current` (`source`, `label`, `engineVersion`, `status`, `updateState`,
    `updateStateText`, `startedUtc`, `finishedUtc`, `installed`, `failed`, `summary`,
    `verification`);
  - `policy` (`source`, `featureUpdates`, `optionalUpdates`, `drivers`, `previewUpdates`,
    `previewSource`, `maxAttemptsPerUpdate`);
  - `settingsRefresh`;
  - `orchestrator`;
  - `retries[]` (`runId`, `selection`, `final`, `state`, `taskPresent`, `engineVersion`, `status`,
    `updateState`, `installed`, `failed`, `finishedUtc`, `findingId`);
  - `originalFailures[]` (`title`, `kbs`, `category`, `class`, `lastHResult`, `laterInstalled`,
    `installedUtc`, `installedBy`, `findingId`);
  - `drivers[]`;
  - `liveScan`.
- **`deviceComparison[]`:** `name`, `hardwareIds`, `deviceId`, `previousProblemCode`,
  `currentProblemCode`, `state`, `source`, `findingId`.
- **`office`:** `selected`, `product`, `displayName`, `expectedProductReleaseId`, `present`,
  `productReleaseIds`, `version`, `platform`, `engineStatus`, `engineVerified`, `result`,
  `activation` {`requested`, `status`, `verified`, `message`, `source`}, `checkedUtc`. The field is
  `null` when Office was not selected.
- **`hardwareSoftware[]`:** `id`, `utility`, `vendor`, `recommended`, `detectedHardware`,
  `compatibility`, `installed`, `installedVersion`, `automaticInstall`, `automaticInstallReason`,
  `manualAction`, `url`, `signIn`, `notes`, `findingId`, `checkedUtc`.
- **`applications[].verification`:** see the table above.

The technician dashboard shows the new findings in their categories. `technician-report.txt` lists
these sections in plain text:

- Windows Update;
- the devices the deployment reported;
- Office;
- manufacturer software;
- applications.

## Tests

`tests/powershell/Health.Tests.ps1` runs scenarios W1–W12 against simulated computers. Its
replaceable probes are:

- `Get-WdhVideoControllers`
- `Get-WdhProcessors`
- `Get-WdhChassis`
- `Get-WdhUpdateHistory`
- `Get-WdhOrchestratorScan`

The registry is simulated through `Get-WdhRegValue`. Scenario W's report is validated against the
schema by `tests/unit/powershell.test.ts`.
