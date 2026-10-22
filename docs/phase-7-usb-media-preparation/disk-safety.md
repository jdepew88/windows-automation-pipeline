# Disk safety

## Discovery

Disks are read with CIM (`Win32_DiskDrive` → `Win32_DiskPartition` → `Win32_LogicalDisk`), which
works without administrator rights; when elevated, the Storage module adds the unique id, bus type,
partition style and the system/boot/read-only/offline flags. Shown per disk: number, friendly name,
manufacturer, model, serial, capacity, bus, media type, partition style, and per volume letter,
file system, label and size.

**Identity** is a fingerprint of unique id, serial, model and size, never the number or a letter.
Before every write phase the disk is found again by fingerprint; a different number, a missing disk,
a look-alike with another serial, or two disks with the same fingerprint stop the run.

## Rules (`Test-WdmDiskEligibility`)

| Condition | Update (add files) | Create (erase) |
|---|---|---|
| holds the running Windows (system flag, the system drive letter, a boot partition) | refused | refused |
| read-only or offline | refused | refused |
| Ventoy (labels `Ventoy`/`VTOYEFI` or a `ventoy` folder) | refused | refused |
| not on the USB bus (NVMe, SATA, SAS, …) | refused | refused |
| USB but not "Removable Media" (external HDD/SSD) | allowed, with a warning | refused |
| larger than 256 GB | allowed | refused (unusual for a flash drive) |
| no serial and no unique id | allowed | refused (cannot be identified reliably) |
| another connected disk with the same fingerprint | allowed | refused (disconnect it) |
| same model and capacity as another disk | warning | warning |
| no volume with a letter | refused | — |

No disk is selected by default, by capacity or by bus alone: Create requires the disk number from
the user and the typed confirmation code `ERASE-<number>-<fingerprint prefix>` (case-sensitive),
separate from any "continue" answer. The code is checked again inside the elevated process, the
disk is revalidated immediately before `Clear-Disk`, and an interrupted erase is never resumed
without a new plan and confirmation. A remembered selection is never reused.

## The destructive step

`Invoke-WdmPartitionDisk` is the only function that changes partitions: `Clear-Disk` (skipped on a
RAW disk), `Initialize-Disk -PartitionStyle MBR`, an active FAT32 partition labelled `WDB-BOOT`
(at most 32 GB, the Windows FAT32 format limit), and optionally NTFS `WDB-DATA` for the rest. All
arguments are typed values from the validated plan; no command string is built. The unit test
"destructive disk and image operations exist only inside their adapter functions" enforces that
no other code calls `Clear-Disk`, `Initialize-Disk`, `New-Partition`, `Format-Volume`,
`Split-WindowsImage`, `Export-WindowsImage` or `Mount-DiskImage`.

**During development no real disk was listed for preparation, erased, partitioned or written; no ISO
was mounted; DISM was not run.** Every scenario uses simulated disks whose volumes are temporary
folders.
