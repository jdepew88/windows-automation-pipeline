# Preparing an installation USB: user guide

Get the tools: in Windows Deployment Builder, **Deployment package** page, download the deployment
package and **Download the USB Preparation Assistant** (`usb-preparation-assistant.zip`). Extract the
assistant to a folder on the Windows PC you prepare drives with and double-click
`Prepare-InstallationUSB.cmd`. Every step below can also be run as a command
(`README-USB-Assistant.txt`).

**Which workflows erase data:** only "Create a new Windows USB from an ISO". It erases the one USB
flash drive whose confirmation code you type. Update, Inspect, Verify and Plan never erase,
format or repartition anything.

## 1. Prepare an existing Windows USB (no erase)

Make the USB with Microsoft's Media Creation Tool (or keep one made earlier), then:

```
WdbMediaAssistant.ps1 -Mode Plan -Workflow Update -Package windows-deployment-package.zip -Target E:
WdbMediaAssistant.ps1 -Mode Apply -PlanPath <plan file shown>
```

The plan lists every file it adds, the space needed, warnings and blockers. Windows' files and your
other files on the drive are not touched.

## 2. Create a new USB from an ISO (erases the chosen flash drive)

1. Download the Windows 11 ISO from <https://www.microsoft.com/software-download/windows11>. Copy the
   SHA-256 shown on that page for your language if you want the ISO checked.
2. `WdbMediaAssistant.ps1 -Mode Discover` and find your stick by number, model, serial and size.
   Unplug other USB drives you care about.
3. `-Mode Plan -Workflow Create -Package <zip> -Iso <file> -Disk <number> [-IsoSha256 <hash>]`
4. Read the plan: the disk, its current volumes ("Erased: …"), the layout. Then
   `-Mode Apply -PlanPath <plan> -ConfirmErase ERASE-<n>-<code>` as administrator (the wizard asks
   you to type the code and shows the Windows elevation prompt).

16 to 32 GB sticks get one FAT32 partition. Larger sticks get FAT32 (32 GB, for Windows Setup) plus
NTFS `WDB-DATA` for the rest, so 64 and 128 GB drives are not wasted (`-NoDataPartition` to skip it).

## 3. Add a customer deployment package

Any Windows Deployment Builder package ZIP works (packages from before Phase 7 too, with a warning
that their answer file is not hash-pinned). The assistant refuses a package that was modified, has
extra files, has its answer file renamed, or whose answer file belongs to another package.

## 4. Add an application restoration backup

If the deployment restores settings (Phase 6), add `-Backup <folder or .zip>`: it must be the backup
whose manifest hash the deployment pins (folder name `WDB-AppBackup-…`). It is copied to
`WindowsDeployment\backups\<folder>` and checked again on the drive. Another customer's backup is
refused. The drive then holds personal configuration data: keep it private and delete the backup
folder after the installation. The source backup is never deleted.

## 5. Check that the correct USB was selected

The plan shows: disk number, model, manufacturer, serial, capacity, bus, media type and every volume
with letter, file system and label. The confirmation code contains the disk number and part of its
identity fingerprint. If the drive is unplugged, swapped, renumbered or its letter changes before or
during preparation, the assistant stops.

## 6. Verify completed media

`WdbMediaAssistant.ps1 -Mode Verify -Target E: -Package <zip>` writes the readiness report (also
`wdb-media-report.txt` on the drive and under `%LOCALAPPDATA%\WindowsDeploymentBuilder\media\reports`).
"Ready for installation" = structure, image, edition, boot files and all hashes verified. It is not a
boot test.

## 7. Replace a deployment configuration later

Plan with a new package and `-ReplaceExisting` (wizard: type REPLACE). Only the deployment files are
written ("Update deployment files only"); Windows is not copied again. The previous answer file and
`WindowsDeployment` go to `WDB-previous\<time>\` on the drive (Windows Setup ignores them there).
Applying the same package again only rewrites missing or damaged files.

## 8. Errors and interrupted copies

- An interrupted or cancelled run is reported **Incomplete**, never ready. Run the same plan again
  (`-Mode Apply -PlanPath …`): finished files are verified, not copied again.
- During Update, the new files are assembled in `WindowsDeployment.wdb-new` and swapped in only after
  verification; the answer file is written last. A half-written drive therefore has no answer file
  and cannot start an installation by accident.
- If erasing was interrupted, the assistant refuses to continue: make a new plan and confirm again.
- To cancel at the next safe point, create `%LOCALAPPDATA%\WindowsDeploymentBuilder\media\<planId>.cancel`
  (Ctrl+C also stops; the drive is then Incomplete until the plan is run again).
