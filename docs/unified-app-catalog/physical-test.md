# Physical test: application engine 1.6.0, health audit 1.2.0 and the 2026-11-27 catalog

Phase 2 (PR #3, merged as `fbdc7f1`) was validated by simulation only.

**Passed:**
- the 13 PowerShell suites (511 tests), with every Windows boundary stubbed;
- the unit tests, run one file at a time: 38 files, 694 tests;
- the production build;
- the local and live production smoke tests;
- an inspection of a ZIP generated on `deploy-wdb.pages.dev`.

**Still outstanding:**
- The browser (Playwright e2e) regression suite was **not run** for this release because of memory limits on the development computer. Run `npm run test:e2e` (with at most 2 workers) before the next release.
- **No real installation, update, restart or uninstall was run.** This procedure is the physical acceptance test, and nothing in Phase 2 is certified on hardware until it passes.

Use a spare computer that can be wiped. Use an elevated Windows PowerShell for the read-only checks. Note the time before every step that changes something.

## 1. Generate the package

On `https://deploy-wdb.pages.dev` (or the custom domain), in Advanced mode, start from the owner default and add these applications.

**The apps the 2026-11-27 audit changed:**

| App | What to expect |
| --- | --- |
| Sysinternals Suite | Now from the Microsoft Store, `9P7KNL5RWT25` |
| AIMP | Now from the Store |
| Battle.net | Manual follow-up |
| FileZilla, FreeFileSync | Still manual |

**The apps from the earlier physical deployment:**
- Sublime Text 4
- ChatGPT (Store)
- Claude Desktop
- Node.js (LTS)
- Adobe Acrobat Reader (64-bit)

**Visual C++, as separate entries:**
- 2015-2026 x64 and x86
- 2013 x64 and x86

**One saved-profile check.** Import a profile saved before 2026-11-27 that selects Microsoft Whiteboard or Amazon Music. If none exists, add Whiteboard by hand: enter `9MSPC6MP8FM4` in the "Package identifier" field under Applications, with the source set to `msstore`. Check that:
- the profile loads;
- the warning says "removed from the automated catalog on 2026-11-27 … not installed";
- the application plan preview lists it under "Not installed (removed from the automated catalog; reported as Skipped)";
- nothing replaces it.

Record the package id shown on the package page.

## 2. Install and watch, without intervening

1. Extract the ZIP to the installation USB and install Windows as usual.
2. Watch with the progress window or the LAN monitor, and do not intervene.
3. **Expected for the applications stage:**
   - **WinGet apps** install after Windows Update, with the install lock respected.
   - **Store apps** (Sysinternals, AIMP, ChatGPT) install from the `msstore` source.
   - **Manual apps** (Battle.net, FileZilla, FreeFileSync) are never attempted. Each one is listed as a follow-up with its official download link.
   - **Whiteboard** is reported as **Skipped** ("Not installed: … removed from the automated catalog"). It does not count as a failure.
   - **A hash mismatch**, if one happens: the result says "Installer hash mismatch" with WinGet's own words. One retry follows after a source refresh. `--ignore-security-hash` is never used.
4. **When a restart is required:** an app whose installer asked for one (Adobe Acrobat Reader can return 3010 or 1641) shows `RestartOrSignInRequired`. It must **not** turn into `InstalledVerified` until Windows has actually restarted.

## 3. The deployment report

For each selected application, record its outcome. These outcomes count as expected:

| App | Expected outcome |
| --- | --- |
| Installed apps | `InstalledVerified` |
| Battle.net, FileZilla, FreeFileSync | `ManualSetupRequired` |
| Whiteboard | `Skipped` |

Anything else (`InstallerSucceededVerificationPending`, `InstallerSucceededVerificationFailed`, `PackageUnavailable`, `InstallationFailed`) is a finding. Note the evidence line the report gives for it. Specifically:

- **VC++ 2015-2026 x64 and x86** each verify independently through:
  - `HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64` with `Installed = 1` in the 64-bit registry view;
  - `...\X86` in the 32-bit view.

  Removing or failing one must not mark the other as installed.
- **VC++ 2013 x64 and x86** verify by their own uninstall names. Each is matched only to its own architecture.
- **Sysinternals and ChatGPT** verify as per-user Store apps for the account that ran the application stage.
- **Claude Desktop** verifies by its AppX package `Claude` (per user).
- **Node.js** verifies by the uninstall name "Node.js".
- **Sublime Text** verifies by its uninstall name or its `%ProgramFiles%\Sublime Text` files.
- **Adobe Acrobat Reader** verifies by "Adobe Acrobat (64-bit)".
- **The stage result** is never `Succeeded` while a verification is pending or a restart is outstanding. Record the final status and the follow-up list, including whether the manual apps appear in it.

## 4. Re-verification and the recovery menu (read-only)

1. **Sign in as the deployment user**, and restart once if any app was waiting for a restart. Then open Deployment Recovery and choose **V** (Reverify applications).

   Expected:
   - nothing is installed;
   - an app that was waiting for the restart is now `InstalledVerified`;
   - the exit summary is 0 (all verified), 10 (some pending), 20 (some failed) or 1 (not possible).

   Record the number.
2. **Check that the restart is respected.** If you can reproduce a pending restart (for example, install Adobe Acrobat Reader again by hand and do **not** restart), run **V** before restarting. That app must stay pending, with "the restart the installer asked for is still outstanding".
3. **Check for app updates.** As the deployment user, choose **C**. It lists WinGet updates for the selected apps and changes nothing. Record what it lists.
4. **Re-verify from a second admin account.** Sign in as a second administrator and choose **V**. Per-user apps must be checked against the account that installed them, not the second account.

## 5. The health audit

Open the "Deployment health" shortcut, or run `DeploymentHealth.ps1 -Mode Dashboard`. Check that it shows:

- **Health audit 1.2.0.**
- **Applications** with their evidence, and the manual apps listed as follow-ups.
- **A Visual C++ inventory** with every installed runtime family and architecture. The x86 and x64 runtimes are never confused, including the 2010-2013 runtimes that share a display name pattern.
- **No change made by the audit.** Note the installed programs before and after: the list must be the same.

## 6. Export diagnostics

Run Deployment Recovery > 6 (Export diagnostics) and send the ZIP back. It contains:
- the application `state.json` and `result.json`;
- the health reports;
- the logs.

Passwords and Wi-Fi keys are removed from it.

## What a good result looks like

- Every automated app is `InstalledVerified`, or has a specific, evidence-based reason why not.
- No app is reported installed without evidence.
- Manual apps are never attempted. Removed apps are Skipped, with nothing substituted.
- VC++ x86 and x64 are verified and reported independently.
- A restart-required app is not cleared before a real restart.
- Re-verification and the update check install and change nothing.
- No hash check is bypassed.
