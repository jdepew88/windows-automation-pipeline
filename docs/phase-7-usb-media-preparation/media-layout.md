# Filesystem layouts, large images, Secure Boot, placement, Ventoy

## Layout created from an ISO

| Drive size | Partitions (MBR) |
|---|---|
| up to 32 GB | one active FAT32 `WDB-BOOT` (whole drive) |
| over 32 GB (64, 128 GB) | FAT32 `WDB-BOOT` 32 GB (active) + NTFS `WDB-DATA` for the rest (optional) |

Why: UEFI firmware boots removable FAT32 media; Windows formats FAT32 only up to 32 GB; Windows 10
1703 and later mount several partitions on removable drives. Everything Setup and the deployment
need lives on `WDB-BOOT`; `WDB-DATA` is free space for the technician (not used by the deployment).
Some firmware boots only the first partition: `WDB-BOOT` is first. Legacy BIOS boot is not
prepared or tested (the Windows boot files for it are copied, but no BIOS boot code is written).
Capacity is checked from the real sizes: Windows files + package + backup + 5 % + 64 MB.

## Images over 4 GB (FAT32)

- `install.wim` over 4 GB: not copied; DISM `Split-WindowsImage -FileSize 3800 -CheckIntegrity`
  writes `sources\install.swm`, `install2.swm`, … directly to the drive. Windows Setup installs from
  split images placed as `sources\install*.swm` (Microsoft documents split images for media with a
  file-size limit).
- `install.esd` over 4 GB (cannot be split): DISM `Export-WindowsImage` exports **the selected
  edition** to a temporary WIM, which is then split. Other editions are not on the drive (reported).
- Any other file over 4 GB blocks the plan: nothing is copied to FAT32 and reported as success.
- Verification of split images: DISM's integrity check while splitting, then the first part's
  metadata is read from the drive (part count matches the files, the planned edition and build are
  present) and the SHA-256 of each part as written is recorded in the journal. Unchanged files are
  verified byte for byte against the ISO (SHA-256 of source and copy).

## Secure Boot

Microsoft's signed boot files (`efi\boot\bootx64.efi`/`bootaa64.efi`, `bootmgr.efi`, BCD) are
copied unchanged; nothing disables Secure Boot, signature checks or adds a boot loader. The Create
plan refuses an ISO whose `setup.exe` or UEFI boot loader is not validly signed by Microsoft. NTFS
media made by other tools (Rufus) can be updated; their boot depends on that tool's UEFI:NTFS
partition and is reported as a warning.

## Placement of the deployment files

From the verified staging copy of the ZIP (never the ZIP itself):

```
<drive>\autounattend.xml                      written last, verified (SHA-256 from the manifest)
<drive>\WindowsDeployment\...                 every manifest file, verified
<drive>\WindowsDeployment\backups\<folder>\   Phase 6 backup, only when pinned
<drive>\wdb-media-state.json                  preparation journal
<drive>\wdb-media-report.txt                  readiness report
<drive>\WDB-previous\<time>\                  a replaced deployment, kept
<drive>\WindowsDeployment\drivers\<folder>\   Phase 8 offline driver bundle, only when pinned
<drive>\$WinPEDriver$\<folder>\                Phase 8 Setup-critical drivers (loaded by Windows Setup)
```

A drive prepared this way passes the deployment's own `Stage-Deployment.ps1` verification (tested).
`USB:\SomeFolder\autounattend.xml` cannot happen: the answer file is always written to the root, and
Verify reports answer files found below the root.

## Ventoy

Ventoy drives are detected (labels `Ventoy`/`VTOYEFI`, `ventoy` folder) and never erased or updated:
Windows Setup started from an ISO inside Ventoy does not see an `autounattend.xml` placed beside the
ISO, so the deployment would not start. Ventoy's own auto-install plugin was not verified and is not
used. ISOs stored on a Ventoy drive can still be inspected (`-Mode Inspect -Iso`). Automated
answer-file injection for Ventoy remains a documented enhancement.
