# Preparing a USB deployment (Phase 4)

What you need: a USB drive of 8 GB or more (it is erased when the Windows media is created),
official Windows 11 installation media from Microsoft, and the deployment package
(`windows-deployment-package.zip`) from the website's **Deployment package** page.

The package does **not** contain Windows. It adds an answer file and a `WindowsDeployment` folder
to a normal installation drive.

## 1. Create the Windows 11 installation drive

| Method | Notes |
|---|---|
| **Media Creation Tool** (Microsoft) → "USB flash drive" | Recommended. FAT32, boots on UEFI, `install.esd`. Nothing to change. |
| **Rufus** with an official Windows 11 ISO | Supported, with one rule: when Rufus shows the **"Windows User Experience" / customization** dialog (remove requirements, create a local account, skip privacy questions, …), **untick every option**. Rufus implements those options with its own answer file, which would conflict with ours. Rufus usually formats NTFS with a small UEFI:NTFS boot partition; that is fine. |
| **Copying an ISO's files by hand** | Works only if the drive is FAT32 (UEFI firmware boots FAT32) and every file is under 4 GB. `sources\install.wim` on current ISOs is usually larger, so it must be split first (`dism /Split-Image … /FileSize:3800` to `install.swm`). Use one of the tools above unless you know you need this. |
| Ventoy and similar multi-ISO tools | Not supported: the ISO is booted from inside an image file, so an `autounattend.xml` next to it is not seen (Ventoy has its own auto-install plugin). Untested. |

## 2. Put the package on the drive

Extract the ZIP to the **root** of the USB drive, so that the answer file is next to `setup.exe`:

```
USB drive (for example E:\)
├── boot\  efi\  sources\  support\  setup.exe  …   (from Microsoft; leave unchanged)
├── autounattend.xml                               (from the ZIP)
└── WindowsDeployment\                             (from the ZIP)
    ├── setup.cmd  setup.ps1  deployment-manifest.json  README.txt
    ├── scripts\  profiles\  config\  docs\
```

With Windows' **Extract all…**: in the destination box remove the folder name it suggests and type
only the drive (for example `E:\`). If you see `E:\windows-deployment-package\autounattend.xml`,
move both items up one level.

Windows Setup looks for `autounattend.xml` in the root of removable drives (the "implicit answer
file search"). It must be named exactly `autounattend.xml`; the website's **Output** setting
"notautounattend.xml" is for archiving and is reported as a warning on the Deployment package page.

Optional check (on any Windows PC, as administrator): `E:\WindowsDeployment\setup.cmd -Verify`
verifies every file against the manifest and changes nothing.

## 3. Install

1. Boot the target computer from the USB drive (boot menu key or firmware setting).
2. Setup starts and applies the answer file (language, edition, account, privacy, …).
3. **Setup stops at "Where do you want to install Windows?". Select the disk yourself.** Check the
   size and model; delete or create partitions only if you mean to. Nothing in the answer file or
   the package selects, cleans or formats a disk, and the deployment scripts never touch other
   drives (they only write to `C:\ProgramData\WindowsDeploymentBuilder` on the installed Windows).
4. Windows installs and restarts (several times). You can remove the USB drive once Windows Setup
   has finished; the deployment does not need it.
5. The account is created and signs in (automatically with the owner defaults). The deployment
   starts by itself: a **Deployment progress** window opens and a shortcut is placed on the
   desktop.
6. Windows Update runs, restarting as needed; then the selected applications are installed. Leave
   the computer connected to the Internet and signed in.
7. When everything has finished, **Deployment report** appears on the desktop.

## Internet

| Stage | Needs Internet |
|---|---|
| Windows Setup, answer file, staging, report | No |
| Windows Update | Yes. Without a network it waits and retries within its runtime limit, then ends `Offline`. |
| Applications (WinGet) | Yes. It waits for Windows Update, then for a network within its limits, then ends `Offline`. |

An installation without Internet completes Windows Setup normally; the deployment ends as
`Incomplete` with the offline stages listed, and `Resume-Deployment.ps1 -RestartStage …` continues
them later (see `recovery.md`).

## After installing

- Remove `autounattend.xml` from the USB drive (or keep the drive safe): any computer booted from it
  is installed with the same settings, and the file contains the account and Wi-Fi passwords if
  you set any (the website warns before download). `profiles\windows-settings.json` never contains
  passwords.
- The answer file copy in `C:\Windows\Panther` is deleted at the first sign-in unless
  "Keep sensitive files" is on.

## Status of this procedure

The package format, staging, hashing and orchestration are covered by automated tests with
simulations, and the package's own verification ran on a real Windows PC (read-only). **Nothing in
this procedure has been run on physical hardware or in a VM yet**; see `testing.md` for the
validation checklist.
