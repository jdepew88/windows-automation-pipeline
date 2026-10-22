# Phase 7 architecture: USB Media Preparation Assistant

## Audit: the installation-media contract before Phase 7

Verified on `feature/phase-6-application-backup-restore` at `f4d1c08` (local = GitHub, clean tree).

| Piece | Where | What the media must provide |
|---|---|---|
| Answer file | `autounattend.xml` at the **root** of the drive | Windows Setup's implicit search finds only this exact name at the root of removable media. A copy in a subfolder is ignored. |
| Embedded engines | inside the answer file (`Extensions/File`), extracted during specialize to `C:\Windows\Setup\Scripts` | nothing else: the orchestrator, both engines, the recovery tool and the runtime manifest travel in the answer file |
| Package folder | `WindowsDeployment\` at the root | verification (`setup.cmd -Verify`), manual runs, recovery; the Phase 4 staging verifies every file by SHA-256 against `deployment-manifest.json` |
| Settings backup (Phase 6) | `WindowsDeployment\backups\<folder>` | the application engine searches every ready drive for this path and accepts only the backup whose manifest SHA-256 is pinned in its configuration |
| Hand-off | first sign-in, `Initialize-Deployment.ps1` (embedded mode) | stages to `C:\ProgramData\WindowsDeploymentBuilder\Package`; after that point no drive letter or USB is used |
| Secrets | the answer file may contain the account/Wi-Fi password; `profiles\windows-settings.json` never does | the drive is private; the website warns |

Missing before Phase 7: a tool that places these files and checks the result; a pinned hash of the
answer file (the manifest hashed every other file); the required edition in machine-readable form;
any check of the Windows image (edition, architecture, build, FAT32 limits).

## Design

```
website (browser)                             technician's Windows PC (local)
-----------------                             -------------------------------
configuration, applications, backup ref.      USB Preparation Assistant (WdbMediaAssistant.ps1)
        |                                       Discover  disks (CIM; Storage module when elevated)
        v                                       Inspect   drive / ISO (read-only, no admin)
windows-deployment-package.zip ---------------> Plan      validate package + backup + media; preview
  autounattend.xml                              Apply     Update (no erase)  |  Create (erase, elevated)
  WindowsDeployment\deployment-manifest.json      journal on the drive and locally; verified copies
     media: { answerFile sha256, requirements,  Verify    readiness report
              layout, backup }                    |
usb-preparation-assistant.zip  ---------------->  v
                                              USB drive: autounattend.xml, WindowsDeployment\, backups\
```

- **Loose coupling.** The website decides *what* is installed and writes it into the package; the
  assistant decides *how* media is prepared and reads only the manifest (version 1) and its new
  `media` block. It does not know about applications, profiles or updates. The block exists only in
  the package copy of the manifest: the answer file and its embedded runtime manifest are
  byte-identical to Phase 6.
- **No localhost service.** The website never talks to the assistant. Files move by download, so
  there is nothing for a web page to call and no authentication model to get wrong.
- **One PowerShell 5.1 script** plus the Phase 6 validator (`WdbMigration.ps1`, shipped next to it,
  never loaded from a package or backup), the cached release data and a `.cmd` launcher. No
  framework, no installer, no service.
- **Privilege separation.** Discover, Inspect, Plan, Verify and Update run without administrator
  rights. Create needs them only to erase and prepare the drive: the wizard writes the plan and
  starts an elevated `-Mode Apply` (UAC prompt), which validates everything again (package hashes,
  backup hash, ISO size and time stamp, disk fingerprint, eligibility, confirmation code). The
  elevated side never trusts the plan's conclusions.
- **Adapters.** Every system access (disk listing, ISO mounting, DISM split/export, partitioning,
  signatures, elevation, the clock, cancellation, the online release page) is a small function.
  The scenario tests replace all of them; the only destructive code is `Invoke-WdmPartitionDisk`
  (a unit test checks that no other code calls a disk or image cmdlet).

## Workflows

| Workflow | Erases | Admin | Steps |
|---|---|---|---|
| Update (default, implemented first) | no | no | resolve the letter to its disk, eligibility, Windows Setup structure, image vs. requirements, existing deployment (same id = repair; other id = refused unless "replace", which keeps the old one in `WDB-previous\<time>`), space, copy to `WindowsDeployment.wdb-new`, backup into it, verify, swap, answer file last, verify, report |
| Create from ISO | **yes, the confirmed flash drive** | yes | ISO size and optional SHA-256, mount read-only, Setup structure, signatures of `setup.exe` and the UEFI boot loader, image vs. requirements, FAT32 file sizes, layout plan, typed confirmation, revalidate, erase + MBR + FAT32 (+ NTFS), copy Windows files (each hashed against the ISO), split (or export + split) the install image, deployment files as in Update, verify, report |
| Inspect / Verify | no | no | structure, boot files, image editions and freshness, conflicting files (`ei.cfg`, `pid.txt`, `$OEM$`, stray `unattend.xml`, nested answer files), Ventoy, journal, and (with a package) every hash |

## PXE compatibility (not implemented)

Content generation (website), media preparation (assistant) and installation orchestration
(answer file + engines) are separate. The manifest describes the deployment, not a drive: no drive
letter is stored, the engines stage to `C:\ProgramData` and the backup is found by name and hash on
any drive. A later iPXE/WinPE delivery can serve the same answer file and `WindowsDeployment`
folder from a share (for example on Unraid) without changing the application, update, backup or
recovery engines; only a WinPE start script that copies the answer file into place is new.
