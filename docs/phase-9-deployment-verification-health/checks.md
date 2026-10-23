# Checks per category

Everything here is read-only. "Not changed by this check" appears in the next actions on purpose:
the engine reports and points to the recovery tool or to Windows' own settings.

## Windows

| Id | Check | Method | Severity |
|---|---|---|---|
| `windows.edition` | expected edition (Pro = `Professional`, Home = `Core`, …) | `EditionID` | Critical |
| `windows.version`, `windows.architecture`, `windows.productType` | Windows 11 (build ≥ 22000), configured architecture, workstation | CurrentVersion, `PROCESSOR_ARCHITECTURE`, Win32_OperatingSystem | Error |
| `windows.setup` | Setup finished | `Setup\State` ImageState, OOBEInProgress, SystemSetupInProgress | Error (Pending while in progress) |
| `windows.activation` | activated, or activation pending clearly named | SoftwareLicensingProduct.LicenseStatus (the key is never read) | Warning, optional |
| `windows.restart` | no restart pending | CBS RebootPending, WindowsUpdate RebootRequired, Microsoft.Update.SystemInfo, the engines' restart marker of this boot | Pending |

Licensing is not installation: an unactivated Windows is reported as "not activated yet", never as
"not installed". A generic setup key is never taken as activation.

## Accounts and identity

| Id | Check |
|---|---|
| `identity.computerName` | ActiveComputerName equals the configured name. A pending rename is Pending, never verified |
| `account.exists` | the unattended account exists and is enabled. Interactive account modes are reported for information |
| `account.role` | Administrators membership matches the configured group. A standard account with administrator rights is an Error |
| `account.administrator` | at least one enabled administrator account besides the built-in one |
| `account.profile` | the account has signed in once (ProfileList) |
| `account.autoLogon` | automatic sign-in matches the configuration (AutoAdminLogon and AutoLogonCount). Still on when it should be off is an Error. Only the *presence* of a stored password value is noted; it is never read |

Nothing is renamed, enabled, added to or removed from a group by a check.

## Windows Update

- `updates.service`: `wuauserv` not disabled.
- `updates.stage`: the stage's own result.
  - Succeeded is a Pass.
  - Offline and Failed are failures, with RetryFailed as the next action.
  - Still running is Pending.
  - A deployment that completed without a result is Unverifiable.
- `updates.kb.<KB>`: every failed update.
- `updates.scope`: "optional and feature updates are not installed by design". The report never
  claims they are.
- `updates.scan`: only with `-ScanUpdates`. A read-only Windows Update Agent search that counts
  remaining required, optional, driver and feature updates. Without it, the report says no live scan
  was made.
- `updates.policy`: the deferred ongoing policy (Phase 4.3). ManagedByOrganization and Unsupported
  are for information.
- `updates.driverPolicy`: whether `ExcludeWUDriversInQualityUpdate` blocks Windows Update drivers.
  If it blocks them against the configuration, it is a Warning, and the policy is never changed.

## Applications

The plan contains only the applications this deployment selected, plus its Additional Software:

- automatic installs (required unless marked optional);
- manual follow-ups (always optional);
- reviewed automatic Additional Software (required).

For each one:

1. **Engine evidence:** `result.json`, or `state.json` when the result is damaged or older than the
   state. Status, detection, failure class, attempts and lifecycle (derived through
   `Get-WdaLifecycle` for schema-1 results).
2. **Independent check against Windows,** in this order:
   1. WinGet's own uninstall record `<PackageIdentifier>_<source>`.
   2. An uninstall record whose normalized display name matches (machine-wide 64/32-bit, and the
      deployment user's hive when it is loaded).
   3. A Store package of the deployment user (`Get-AppxPackage -User <SID>`).
   4. The portable tool's Start menu shortcut.
3. **The decision:** see [health-states.md](health-states.md#application-results). An executable
   found somewhere on disk is never accepted. One failed lookup never makes an installed application
   "missing": success without a matching record is "uncertain".

A failed application keeps its attempts, failure class and whether it is retryable. Its
`recoveryAction` points to the existing recovery tool:

- RetryFailed for retryable failures;
- `Retry -IncludePermanent` after the cause has been corrected.

There is no second installer and no second retry engine.

## Restored settings

When the deployment restores settings (Phase 6), `Applications\restoration.json` is checked:

- `restore.backup`: Staged (validated against the pinned SHA-256), NotFound, Invalid (tampered or
  wrong backup) or NotSearched.
- `restore.settings.<adapter>`: restored, kept existing, partially restored, manual review, waiting
  (backup, user, dependency) or failed. Review items (conflicts) are warnings.
- `restore.consistency.<adapter>`: settings reported restored while the application is missing.
- `restore.retained`: staged backups under `<dataRoot>\Backup`.
  - While a restoration is outstanding, they are still needed (Info).
  - Afterwards, a Warning: personal application settings remain. The location is reported without
    the backup's name or contents.

An installed application and its restored settings are separate findings (scenario F).

**Cleanup** is a separate, confirmed action. `DeploymentHealth.ps1 -Mode CleanupBackups` lists the
staged copies. Adding `-ConfirmCleanup <backup id>` (administrators only) removes them, and only:

- when no restoration is outstanding;
- below `<dataRoot>\Backup`;
- never through a link.

The USB or source copy is never touched.

## Hardware and drivers

- `drivers.report`: `reports\drivers.json` must be final, of this deployment and readable. If not,
  it is Unverifiable.
- Every present device with a problem code, compared with the report:
  - **Missing driver:** code 28, with AddDrivers as the next action.
  - **Not working:** the device errors although a driver was installed or it was working when the
    stage finished. This is how scenario D is caught: the installer's success is not trusted.
  - **Possible hardware or firmware problem:** the report said HardwareIssue, or a hardware-type
    code.
  - **Waiting for a restart:** code 14.
  - **Disabled:** code 22, reported for information; a disabled device is not broken.
  - **Basic display driver:** a generic Microsoft driver, functional but limited (Warning). A
    Microsoft driver is never "outdated" by itself.
- Severity: graphics, network, storage and system devices are Errors; others are Warnings.
- `drivers.vendorReview`: "Vendor driver review recommended" for the optional vendor tools of the
  report. It never claims Intel DSA or AMD Auto-Detect have scanned the computer.
- When the driver stage is off, the devices are still checked.

## Security

- `security.antivirus`: real-time protection by Defender. If Defender hands over, a product
  registered and on in Windows Security Center counts. No active antivirus is Critical.
- `security.firewall`: every profile on (or a registered firewall product). All off is Critical;
  some off is an Error.
- `security.uac`: EnableLUA and the configured prompt level. Off although configured on is an Error.
- `security.smartScreen`: not turned off by setting or policy (optional: Windows Security shows the
  full picture). It does not rely on one undocumented flag.
- `security.encryption`: BitLocker or device encryption status, protection and progress. Only
  protector *types* are read; keys never are. Encryption is never turned on.
- `security.recoveryKey`: when encrypted, it always says the recovery-key backup **cannot be
  verified** from the computer and asks for confirmation. It is never folded into "encryption
  healthy".

## Network

The requirement comes from the configuration:

- **auto** (default): required only while something outstanding needs the Internet (unfinished
  stages, applications waiting for the network, a live update scan);
- **always**;
- **never**.

A finished, offline computer is not reported as broken.

Checks:

- `network.driver`: the driver stage's flag, which says the network will not appear by itself
  (AddDrivers).
- `network.adapter`: a connected physical adapter.
- `network.internet`: gateway, DNS and the documented Windows connectivity test (never one ping).
- `network.packageSource`: TCP 443 to the WinGet source while applications wait.

## Storage

- `storage.systemVolume`: accessible, NTFS, healthy.
- `storage.freeSpace`: a Warning below 10 GB or 10 %, an Error below 3 GB.
- `storage.dirtyBit`: from `fsutil dirty query` (read-only).
- `storage.disk.*`: optional physical disk health and reliability counters, labelled "not a full
  diagnosis". No disk test, surface scan or repair is ever run.

## Windows settings (verification adapters)

Each adapter declares:

- setting id and label;
- Windows versions;
- machine or user scope;
- method (registry path, value, expected);
- when it takes effect (immediately, at sign-in, after a restart);
- how to reverse it.

The results (Pass, Warning or Deferred) are listed in `customizations[]`. Only settings this
repository already applies have adapters:

| Adapter | Value |
|---|---|
| file extensions | `HideFileExt` = 0 |
| Explorer opens to This PC | `LaunchTo` = 1 |
| taskbar on the left | `TaskbarAl` = 0 |
| long paths | `LongPathsEnabled` = 1 |
| Fast Startup off | `HiberbootEnabled` = 0 |

A later Phase 8.5 adds adapters to `customizationAdapters()` without changing the health engine;
nothing of Phase 8.5 is implemented.

## Recovery and outstanding work

- `deployment.state`: damaged state (and backup), no state, or another deployment's state is
  Unverifiable, with Resume as the next action.
- `deployment.integrity`: every staged file's SHA-256 against the manifest. A modified package is
  Critical.
- `deployment.outcome`: the Phase 5 outcome (see [health-states.md](health-states.md)).
- `deployment.recoveries` and `deployment.userContext`: who ran the stages, and who runs this check.
