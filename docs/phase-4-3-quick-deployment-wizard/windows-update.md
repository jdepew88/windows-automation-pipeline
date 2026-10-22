# Windows Update: initial provisioning vs ongoing policy (Phase 4.3)

Two separate concepts:

| | Initial provisioning (Phase 2, unchanged) | Ongoing policy (Phase 4.3 timing) |
|---|---|---|
| Setting | `windowsUpdate.*` (Advanced › Update automation) | `updates.mode` (wizard step 1 › Windows settings, Advanced › Windows Update) |
| What | WindowsUpdateEngine.ps1: scan, download, install, restart, resume, limits, logs, result | "Configure Automatic Updates" policy: `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU` `NoAutoUpdate=0`, `AUOptions` |
| When | after the first sign-in, SYSTEM task, until nothing applicable remains | after the initial update stage is final |

The update engine was not changed (version 1.1.0) and does not read the policy: it uses the Windows
Update Agent API, which installs regardless of `AUOptions`.

## Options

| Wizard choice | `updates.mode` | Policy |
|---|---|---|
| Download automatically; notify before installing (owner default) | `notifyInstall` | `AUOptions=3` |
| Windows recommended defaults | `windowsDefault` | none written |
| Advanced / custom policy | `notifyDownload` (`AUOptions=2`), or `windowsDefault` + "prevent automatic reboot" (upstream workaround) | as before |

**Verification.** Microsoft Learn, "Manage additional Windows Update settings" (page dated
2026-02-11, read 2026-10-21): option 3 is "Auto download and notify for Install"; the registry
values `NoAutoUpdate` / `AUOptions` under `…\WindowsUpdate\AU` are the documented way to configure
it without Active Directory; "Supported from: All" Windows 10/11 client versions; policy values
override the local user's preference. The policy is not supported on Windows Home: the step reports
`Unsupported` there instead of writing it. Microsoft can still enforce some updates (for example
when a device falls out of support) and Defender security intelligence and Store app updates are
not governed by it. Behaviour on a current Windows 11 Pro build is **not yet validated in a VM**.

## Ordering

* **Engine on + notify mode:** the answer file no longer writes `AUOptions` during specialize. The
  package carries `scripts/finalization/Set-UpdatePolicy.ps1` (embedded like the other
  orchestrator files) and the manifest an `updatePolicy` entry (`applyAfter: windowsUpdate`).
  The SYSTEM deployment monitor calls `Step-WddUpdatePolicy` on every run; it acts only once the
  `windowsUpdate` stage has a final `result.json` (Succeeded, CompletedWithFailures, Failed or
  Offline: the engine has stopped, including all of its restarts). If the deployment deadline ends
  the deployment first, it is applied then, with a note.
* **Engine off:** nothing to wait for, so the policy is written during specialize exactly as in
  Phase 4.2 (byte-identical answer file).
* `ExcludeWUDriversInQualityUpdate` (driver exclusion) stays in specialize because it protects the
  provisioning phase too.

During the initial updates Windows' own automatic updating is in its default mode. The engine already
handles a busy installer and pending restarts; Windows' own restarts respect active hours.

## Outcome (explicit completion state)

Recorded once in `state\deployment.json` (`updatePolicy`), `Updates\policy-result.json`,
`Deployment\status.json` and the deployment report:

| Status | Meaning |
|---|---|
| `Applied` | written and read back |
| `AlreadyApplied` | the values were already set |
| `Unsupported` | Windows Home; nothing written |
| `ManagedByOrganization` | domain-joined, MDM `Update` policy, or a WSUS server configured; nothing written |
| `Conflict` | other Automatic Updates values already exist; left unchanged |
| `Failed` | writing or reading back failed |

Anything other than `Applied`/`AlreadyApplied` is listed under "Remaining tasks" and turns an
otherwise `Succeeded` deployment into `CompletedWithFollowUp`. Nothing stops the Windows Update
service, blocks endpoints, or touches Defender updates; users keep Settings › Windows Update.
