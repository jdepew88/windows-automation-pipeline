# Phase 6 checklist for the combined bare-metal test

The owner will do the first real installation on bare metal only after Phases 6 to 9 are complete.
**Nothing below has been done yet.** Run it as part of that combined test (Windows installation,
account and computer name, initial Windows Update, applications, retry and recovery, hardware-aware
drivers, application restoration, final health verification).

## Before: on the existing workstation

1. Run `WdbMigration.ps1 -Mode Inventory -OutFile inventory.json` as the owner (no elevation).
   Check: it finishes, writes only that file, and the file contains no user name, no computer name,
   no uninstall commands. Compare the application count with Settings › Apps.
2. Note whether `Microsoft.WinGet.Client` was used (names present) or `winget export` (ids only).
3. Run `-Mode PreviewBackup` for the wanted adapters. Check every "left out" reason, especially
   possible secrets. Do not use `-IncludeFlagged` unless the file is really clean.
4. Run `-Mode Backup -Destination <USB or external drive> -InventoryPath inventory.json`, then
   `-Mode Validate` on the result.

## In the website

5. Import the inventory. Check: Git, VS Code and other WinGet-reported apps are exact matches;
   name-only guesses are "possible" and need confirmation; hardware utilities are excluded with the
   Phase 8 note; unknown apps cannot be set to restore.
6. Create "Personal Workstation" on Network Engineer / Developer / Technician. Check the built-in
   profile is unchanged and the new profile is ticked.
7. Attach `backup-manifest.json`; choose conflict policies; download the package. Check
   `restore-plan.txt` and the README name the backup folder and hash.
8. Copy the backup folder to the USB drive as `WindowsDeployment\backups\<folder>`.

## On the new computer

9. After the applications finish: VS Code, Git, PuTTY, WinSCP, Notepad++, Windows Terminal settings
   are present and correct; PowerShell profiles are only in
   `Documents\WindowsDeploymentBuilder\Restored settings`; no password was restored (PuTTY proxy,
   WinSCP sites ask for passwords).
10. `restoration.json` and the deployment report list one outcome per reviewed application and
    adapter; manual items (unknown apps, Cursor extensions, nvm versions, repositories) are listed.
11. VS Code extensions: installed by the CLI (with Internet), or listed if not.
12. Remove the USB drive before the first sign-in in a second run: the settings become
    WaitingForBackup; `Deployment recovery` › 7 with the backup folder restores them; a modified
    copy of the backup is refused.
13. Notepad++ open during restore: WaitingForUser, then retry after closing it.
14. Run the restore a second time (recovery tool): restored settings are not written again.
15. Check the staged backup ACL: `C:\ProgramData\WindowsDeploymentBuilder\Backup` readable only by
    SYSTEM, Administrators and the owner.
16. Phase 9 reads `restoration.json` without errors.

Record results in the combined validation log; mark each adapter verified or not.
