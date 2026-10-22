# Collector usage (`WdbMigration.ps1`)

Download it from **Advanced Configuration › Application Backup & Restore** ("Download the collector")
or take it from a deployment package (`WindowsDeployment\scripts\applications\WdbMigration.ps1` when
settings are restored). It needs Windows PowerShell 5.1 (included in Windows 10 and 11); PowerShell 7
works but adds nothing required. Run it as the user whose applications and settings you want; it
does not need administrator rights (only the machine-wide uninstall records are read, which every
user can read).

```powershell
# 1. Inventory (read-only)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WdbMigration.ps1 -Mode Inventory -OutFile .\inventory.json
#    optional: -PortablePath D:\Tools        portable programs in folders you name (never a disk search)
#              -RepositoryRoot D:\src        list Git repositories (names and remote URLs; never cloned)
#              -NoWinGet                     skip WinGet

# 2. Preview what a backup would contain (read-only)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WdbMigration.ps1 -Mode PreviewBackup -Adapter vscode,git,putty,winscp,notepadpp,windows-terminal,openssh-client

# 3. Back up the chosen adapters to a folder you choose (local, external drive or network share)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WdbMigration.ps1 -Mode Backup -Adapter vscode,git,putty -Destination E:\ -InventoryPath .\inventory.json [-Zip]
#    -IncludeFlagged vscode/settings.json    include a file the preview flagged as a possible secret, after you checked it

# 4. Check a backup (read-only)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WdbMigration.ps1 -Mode Validate -BackupPath E:\WDB-AppBackup-...

# 5. Restore by hand on an installed computer (outside a deployment)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WdbMigration.ps1 -Mode PreviewRestore -BackupPath E:\WDB-AppBackup-...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WdbMigration.ps1 -Mode Restore -BackupPath E:\WDB-AppBackup-... [-Adapter vscode] [-Conflict keepExisting|restoreBackup|skip]
```

`-Json` gives machine-readable output for Validate, PreviewRestore and Restore. Exit codes: 0 done,
1 a restore failed, 3 the backup is not valid.

## What happens in each mode

| Mode | Reads | Writes |
|---|---|---|
| Inventory | WinGet list, uninstall records, Store packages, named folders, existence and size of settings files | the inventory file only |
| PreviewBackup | the settings files of the chosen adapters (to filter and scan them) | nothing |
| Backup | same | a new folder `WDB-AppBackup-<date>-<id>` under `-Destination` (and `<folder>.zip` with `-Zip`); with `-InventoryPath`, adds the backup reference to that inventory |
| Validate | the backup | nothing (a ZIP is extracted to a new temporary folder first) |
| PreviewRestore | the backup and the current settings | nothing |
| Restore | the backup | the adapters' settings in the current user's profile; originals kept as `*.wdb-before-restore`, registry originals in `%LOCALAPPDATA%\WindowsDeploymentBuilder\before-restore\<backupId>` |

## Then, in the website

1. Import `inventory.json`; review every application (filters: restore, manual, optional, excluded,
   needs confirmation, unknown, Windows components).
2. Choose the profile name and the base profile, then **Create profile from this review**.
3. Attach `backup-manifest.json` from the backup folder and choose the settings and conflict policies.
4. Keep **Include the restoration plan in the deployment** on and download the deployment package.
5. Copy the backup folder to the USB drive as `WindowsDeployment\backups\<folder name>` (the folder
   name is shown next to the pinned hash).

**Export reviewed inventory** saves your decisions so the review can continue later.
