# Security and privacy of verification

## Read-only by construction

- **Verify never changes anything:** it never installs, uninstalls, updates drivers, writes a
  policy, restarts, resets the network, formats, repairs or deletes.
- **What it writes:** its own files below `reports\health`, a log line, and an Application event
  (5000-5005).
- **What is allowed to change the computer:**

| Action | When | Effect |
|---|---|---|
| Startup re-check task (`\WindowsDeploymentBuilder\HealthCheck`, SYSTEM) | only at the end of a deployment with a pending restart | removes itself |
| `-Mode CleanupBackups -ConfirmCleanup <backup id>` | separately confirmed; administrators only; refused while restoration is outstanding | removes only `<dataRoot>\Backup` children, never through a link, never the source copy |
| Recovery-tool actions the dashboard lists | each asks or is explicit | marked "changes the computer" |

- **Tested:**
  - a scenario hashes every file below the data root before and after a verification;
  - static tests forbid installer, service, policy, firewall, BitLocker and account cmdlets in the
    engine;
  - the tests count its only `Register-ScheduledTask` and its `Remove-Item` calls.

## What is never read or reported

| Never | How |
|---|---|
| Account passwords | Winlogon is read for `AutoAdminLogon`, `AutoLogonCount` and `DefaultUserName`; for `DefaultPassword` only whether the value *exists* |
| Product keys | only `LicenseStatus`, `Name` and `Description` of the Windows licence |
| Recovery keys | only key-protector *types* of the system volume |
| Wi-Fi keys | the Wi-Fi result is not read; the diagnostics never collect Wi-Fi profiles |
| Private application settings | the restoration result's outcomes are read, never the backup's contents |
| Serial numbers, hardware UUIDs | not collected (drive names, model and health only) |

The customer report has its own reduced data set (see [reports.md](reports.md)).

## Integrity of the results

- The integrity checks cannot be turned off from the website: package integrity (SHA-256 of every
  staged file), evidence state (damaged, stale or another deployment's report is Unverifiable, never
  success), and the security checks (antivirus, firewall, account rights).
- The plan and the template are read from the verified staged package, not from the USB drive.
- The report data cannot break out of the HTML (escaped JSON in a JSON script element, values
  inserted as text).
- The website allows only the template's own script by its SHA-256 in its Content-Security-Policy.
  A test keeps the hash and the template in step.

## Accounts

- No account is created, enabled, renamed or changed.
- No hidden technician account exists.
- A standard everyday account that has administrator rights is an error.
- When the configured account is a standard user, an enabled, customer-controlled administrator must
  exist.

## The wrong profile is never read

User-specific checks (per-user applications, Explorer and taskbar settings) read the
**deployment user's** registry hive (`HKEY_USERS\<SID>`), only when Windows has it loaded. The engine
never loads a hive itself (that would lock the user's `NTUSER.DAT`) and never falls back to the
account running the check. Run from another administrator account, such items are "Deferred" with the
reason. The recovery tool refuses to retarget per-user installations without `-RetargetUser`.
