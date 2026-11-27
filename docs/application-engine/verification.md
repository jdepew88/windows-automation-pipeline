# Application engine 1.6.0: package-aware verification

`ApplicationEngine.ps1` no longer treats an installer's exit code as proof of an installation.
Every package is verified from **evidence**, and only a verified installation counts as a success.
Status: simulated tests only (`tests/powershell/Applications.Tests.ps1`); not yet validated on a
Windows installation in a VM.

## Evidence (`Test-WdaVerification $P $Context`)

The catalog's `verify` block (`catalog.ts` `VerifySchema` / `verifySpec()`, passed in
`applications-config.json` as `packages[].verify`) names what to look for. The engine validates it
again and looks, in this order:

| Kind | What | Where (`where`) |
| --- | --- | --- |
| `winget` | `winget list --id <id> --exact --source <source>`. For a `perUser` package only when the engine runs as that user; otherwise skipped with a note. | `machine`, or `user:<name>` for per-user packages |
| `uninstall` | "Apps & features" records whose `DisplayName` **starts with** one of the prefixes (case-insensitive; never a substring elsewhere in the name): HKLM 64-bit view, HKLM 32-bit view (WOW6432Node), and `HKEY_USERS\<sid>` of the deployment user when that hive is loaded. `detectNames` are added as prefixes. | `machine` / `user:<name>` |
| `appx` | AppX package with exactly that `Name`, registered for the deployment user (`Get-AppxPackage [-User <sid>]`), else provisioned (`Get-AppxProvisionedPackage -Online`). | `user:<name>` / `provisioned` |
| `file` | An exact path under `%ProgramFiles%`, `%ProgramFiles(x86)%`, `%ProgramData%`, or `%LocalAppData%` / `%AppData%` **of the deployment user** (profile from the ProfileList, AppData from that user's "User Shell Folders"; never the SYSTEM profile). The file version (FileVersionInfo) is reported. Links are not evidence; nothing is searched. | `machine` / `user:<name>` |
| `registry` | An exact value under `HKLM\SOFTWARE\...` in the requested view (`64` or `32`), optionally `equals`. A package with registry checks is verified **only when all of them match** (so the Visual C++ x86 runtime, `...\VC\Runtimes\X86` in the 32-bit view, is never satisfied by the x64 one). | `machine` |

No probe ever looks anything up on `PATH` (the PATH of a running process is stale right after an
installation: Node.js is verified from `%ProgramFiles%\nodejs\node.exe` and its uninstall record,
never from `node -v`). Every probe is a small read-only function (`Get-WdaUninstallEntries`,
`Get-WdaAppxRegistered`, `Get-WdaAppxProvisioned`, `Get-WdaFileEvidence`, `Get-WdaRegistryValue`,
`Get-WdaDeploymentUser`, `Get-WdaMachineRoots`) that the tests replace.

The deployment user is the engine's own account; when the engine runs as SYSTEM (for example
`-Mode Verify` from a SYSTEM task) it is the user signed in at the console.

## New fields (state.json and result.json, packages and Additional Software)

`status` and `detection` keep their values and meaning (detection: `Installed` when verified,
`Unconfirmed` when verification failed, `Unknown`/`InstalledRequiresRestart` while pending).

| Field | Values |
| --- | --- |
| `verification` | `Verified` \| `Pending` \| `Failed` \| `NotApplicable` |
| `verificationEvidence` | `[{ kind, detail, where, version }]` (at most 12) |
| `verificationNote` | what could not be checked, or why there is no evidence |
| `outcome` | `InstalledVerified`, `InstallerSucceededVerificationPending`, `InstallerSucceededVerificationFailed`, `InstallationFailed`, `PackageUnavailable`, `UnattendedUnsupported`, `Skipped`, `RestartOrSignInRequired`, `ManualSetupRequired` |
| `installedVersion` | version from the evidence (file, uninstall record, AppX), when known |
| `hashMismatch` | `{ packageIdentifier, source, version, message, occurrences, sourceUpdated, staleDownloadsRemoved, retried }` |

Result level: `counts.verificationPending`, `counts.verificationFailed` (and `succeeded` /
`alreadyInstalled` now count verified installations only), `reverification { starts, sinceUtc,
lastUtc }`, `runtimes` (Visual C++ inventory). The published JSON Schema
(`applications-results.schema.json`, from `src/engine/applications/results.ts`) describes them.

## Outcome rules

* Installer success (exit 0 or a documented success code) **with evidence** -> `InstalledVerified`.
* Success **without evidence**, but the catalog says the evidence appears `after: signIn` /
  `after: restart`, or the package is `perUser` and the user's hive/profile is not available, or
  Windows reports a pending restart, or WinGet could not tell -> verification `Pending`:
  `RestartOrSignInRequired` (sign-in / restart) or `InstallerSucceededVerificationPending`.
  `after: restart` makes the package `RequiresRestart`, so the restart policy applies and it is
  verified after the restart (never reinstalled).
* Success without evidence otherwise -> `InstallerSucceededVerificationFailed` (status `Succeeded`,
  `failureClass` `Verification`, detection `Unconfirmed`): a follow-up, never a success.
* `AlreadyInstalled` only with evidence (the package is then never installed or changed).
* Unavailable package -> `PackageUnavailable`; interaction `required` -> `UnattendedUnsupported`
  (never attempted); manual catalog entries -> `ManualSetupRequired`; deselected or blocked by a
  dependency -> `Skipped`; failed installation -> `InstallationFailed`.
* Only `InstalledVerified` counts as success: any pending or failed verification makes the stage
  `CompletedWithFollowUp`.

## Re-verification

* **Next start of the engine.** At every start, pending verifications are checked again before the
  queue. When the stage finishes while a verification is pending, the scheduled task
  `\WindowsDeploymentBuilder\Applications` (at sign-in and hourly) **stays registered**: each later
  start re-checks the pending packages only (installs nothing), rewrites `result.json`, the marker
  and `follow-up.txt`, and removes the task once nothing is pending. Bounded: 48 starts within 7 days
  of the first completion; what is still pending then becomes a failed verification.
* **`-Mode Verify`** (read-only entry point):

  ```
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\WindowsDeploymentBuilder\Applications\ApplicationEngine.ps1 -Mode Verify [-ConfigPath <applications-config.json>]
  ```

  Re-checks every package of the queue. Installs nothing, registers no task, writes no event and
  changes no package status: only `verification`, `verificationEvidence`, `verificationNote`,
  `outcome` and `detection` change in `state.json`; `result.json` (marker, follow-up) is rewritten
  when the stage has finished. Without a state (the engine has not run) it only reports. Prints a
  JSON summary. Exit code: `0` everything verified or not applicable, `10` a verification is
  pending (or a package is not done yet), `20` a verification failed or a package is not installed,
  `1` the engine is running or an error occurred. Run it elevated (state.json is writable only for
  administrators). `Invoke-WdaVerify` is the same entry point for a dot-sourced engine.

## Failure classes (`failureClass`)

Named by cause from WinGet's documented `APPINSTALLER_CLI_ERROR_*` results (no new codes):
`Network` (INSTALL_NO_NETWORK), `Download` (DOWNLOAD_FAILED), `Source` (SOURCE_OPEN_FAILED),
`Installer` (SHELLEXEC_INSTALL_FAILED; the installer's own code in `installerExitCode`),
`HashMismatch` (INSTALLER_HASH_MISMATCH 0x8A150011), `Blocked` (the four policy codes), `Unavailable`
(NO_APPLICATIONS_FOUND, INSTALL_SYSTEM_NOT_SUPPORTED), `RebootRequired`, `Verification`, plus the
earlier `Transient`, `Resource`, `Timeout`, `Unknown`, `Permanent`, `User`, `Elevation`, `Manual`,
`Dependency`, `Budget`. Network, Download and Source failures are checked against the network and the
package source first (a lost connection defers, never fails). Retry limits are unchanged. States
written by engine 1.5.0 keep `Integrity` / `Policy`, which stay permanent.

## Hash mismatch

1. WinGet's exact words (the output lines about the hash), the package id, source and version
   (WinGet's "Found ... [id] Version x" line, or the pinned version) are recorded in `hashMismatch`.
2. Before the single retry (`integrityRetryMinutes` later, default 30): `winget source update --name
   <source>`, then only that package's stale download folder in the running account's
   `%TEMP%\WinGet` is removed: a folder named exactly `<id>` or `<id>.<version>`, directly in that
   folder, not a link, at most 200 entries. Nothing else is touched.
3. A second mismatch is final: `Failed`, `failureClass` `HashMismatch`, outcome `InstallationFailed`,
   with the evidence. The other packages continue. The hash check always applies: the engine never
   skips it and never changes WinGet settings or the installer hash override.

## Visual C++ runtimes

Packages with registry evidence (2015+ runtimes per architecture) are detected independently for x86
(32-bit view / WOW6432Node) and x64; an installed runtime is `AlreadyInstalled` with evidence and is
never reinstalled or removed. `Get-WdaRuntimeInventory` (read-only, usable from a dot-sourced engine)
returns every runtime found:

```
@{ family = '2005' | '2008' | '2010' | '2012' | '2013' | '2015-2022' | ... | '2015+';
   architecture = 'x86' | 'x64' | 'arm64' | 'unknown'; version; displayName;
   source = 'uninstall' | 'runtimeKey' }
```

from the "Microsoft Visual C++ <year> ... Redistributable" uninstall records (64- and 32-bit hives;
Minimum/Additional Runtime components are not listed) and the `VC\Runtimes\X64|X86|ARM64` keys
(`family` `2015+`). It is included in `result.json` as `runtimes`.
