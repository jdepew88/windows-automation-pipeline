# Combined bare-metal validation, Phases 1-9

The first real installation tests every phase at once. Use a **spare computer or an expendable
SSD**; never the owner's working Windows installation. Disconnect every other drive if you can.
Nothing in the package selects, partitions or formats a disk: you choose the disk in Windows Setup.

## Three separate milestones

| Gate | Passed when | Not proven by it |
|---|---|---|
| 1. **Installation boots** | the USB drive boots with UEFI Secure Boot, Setup applies the answer file, Windows reaches the first sign-in | that anything after sign-in works |
| 2. **Deployment provisioning completes** | `Deployment\status.json` outcome is final; `reports\deployment-report.txt` exists | that what the stages reported is true |
| 3. **Health verification passes** | `reports\health\deployment-health.json` is Ready or ReadyWithWarnings with every warning understood, and the technician confirms the "Confirm by hand" items | production readiness of the product as a whole (one computer is one data point) |

Record each gate separately. Do not report the product production-ready until all three have passed
on real hardware, ideally on more than one computer model.

## Prepare

1. Download the official Windows 11 ISO from Microsoft (or use the Media Creation Tool). Note the
   edition list and the ISO's SHA-256.
2. Website: Quick Deployment or Advanced. Name `owner` (default), Windows 11 Pro, Core Essentials
   plus one Store app and one portable tool, Windows Update on, drivers on, verification on (default).
   Add one manual Additional Software entry to see it in Final Review.
   - Optional for Phase 6: an inventory and settings backup of a test computer.
   - Optional for Phase 8: an offline driver bundle.
3. Final Review: check the application list, the Additional Software entry, "Verification & handoff"
   and the driver line ("Windows Update goes first…"). Generate the ZIP.
4. USB (Phase 7): run the USB Preparation Assistant on a USB stick you can erase. Check that it
   lists the correct removable disk only. Create the media, then Verify.

## Install

5. Boot the target with UEFI and Secure Boot on. Gate 1 starts.
6. At "Where do you want to install Windows?", **select the disk yourself**. Check its size and
   model.
7. Setup finishes with no region or account pages (unattended language and account). Note the time.
8. First sign-in as `owner`: the "Deployment progress" window opens; the "Deployment recovery"
   shortcut exists. **Gate 1 passed.**

## Provisioning

9. Network: wired first. For a second run, try Wi-Fi only, then no network to see the waits.
10. Windows Update runs and restarts; the deployment resumes after each restart (Phase 2, 5).
11. Drivers: `reports\drivers.json` lists the devices.
    - NVIDIA, Intel or AMD graphics: a basic display driver is replaced through Windows Update or a
      verified package, never a vendor EXE.
    - Device Manager agrees with the report.
    - Optional: a computer without a network driver and a USB stick with its INF (`AddDrivers`).
12. Applications install as `owner`.
    - Store and portable apps work.
    - RustDesk and manual Additional Software are listed as follow-ups.
13. Recovery: disconnect the network during an application installation, reconnect it, and see it
    resume. Make one application fail (for example by blocking its download), then run "Deployment
    recovery" › Retry failed operations.
14. Phase 6 (optional): settings restored after their applications; `restoration.json` correct;
    nothing secret restored.
15. The deployment ends: `status.json` outcome final, `deployment-report.txt` written. **Gate 2
    passed.**

## Verification

16. The progress window opens the technician dashboard once. The desktop has **Windows Deployment —
    Health Report**. Double-click it: the UAC prompt appears, it verifies again and opens the
    dashboard.
17. Compare every category with reality:
    - edition and activation (Settings › System › Activation);
    - `owner` in Administrators, the computer name;
    - Windows Update history;
    - Device Manager (no unexpected problem codes);
    - Apps › Installed apps (only the selected ones are listed in the report);
    - Windows Security (antivirus, firewall);
    - BitLocker or device-encryption state, and the recovery-key reminder;
    - free space.
18. Cross-check one positive and one negative per category: uninstall an application by hand, verify
    again, and see it "Failed"/"Missing". Reinstall it, verify again, and see it "resolved" in "Since
    the previous check".
19. Restart pending: install an update that needs a restart, then verify (Incomplete). Restart: the
    startup re-check runs and removes `\WindowsDeploymentBuilder\HealthCheck`.
20. Run the Health Report from a second administrator account. Per-user items are "Deferred", never
    passed; the recovery tool refuses to retry applications without `-RetargetUser`.
21. Customer handoff: open `customer-handoff.html`, print to PDF. Check it has:
    - no passwords, keys, paths or SIDs;
    - the right headline;
    - the right actions.
22. Diagnostics: `DeploymentHealth.ps1 -Mode ExportDiagnostics`. Open the ZIP:
    - no `Backup`, no `.xml`, no answer file;
    - passwords redacted.
23. Retained backup (Phase 6): `-Mode CleanupBackups` lists it, and `-ConfirmCleanup <id>` removes
    it. The USB copy remains.
24. **Gate 3 passed** when the state is Ready or ReadyWithWarnings, every warning is understood, and
    the confirm-by-hand items are done.

## Collect logs (every run, pass or fail)

From `C:\ProgramData\WindowsDeploymentBuilder` (as administrator), or the diagnostics ZIP:

- `Deployment\logs\deployment.log`, `Deployment\status.json`, `state\deployment.json`;
- `Updates\logs\engine.log`, `Updates\result.json`;
- `Applications\logs\engine.log`, `attempts.jsonl`, `result.json`, `restoration.json`;
- `Drivers\logs\engine.log`, `reports\drivers.json`;
- `reports\deployment-report.txt`, `reports\health\deployment-health.json` and `history\`.

Also:

- `C:\Windows\Panther\setupact.log` and `setuperr.log`. **Remove passwords before sharing**: the
  answer file may be copied there.
- The Application event log, source `WindowsDeploymentBuilder` (events 1000-5010).
- A photo of Device Manager.
