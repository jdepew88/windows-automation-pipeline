# Phase 7 implementation report: USB Media Preparation Assistant

Branch `feature/phase-7-usb-media-preparation`, from Phase 6 `f4d1c08` (verified locally and on
GitHub). Not merged, not deployed. No real disk was formatted or modified; no installation or boot
test was done (deferred by the owner until Phase 9).

Documents: [architecture](architecture.md) (audit of the media contract, design, PXE notes),
[user guide](user-guide.md) (the eight procedures, including backups, verification and interrupted
copies), [disk safety](disk-safety.md), [Windows images](windows-image.md) (inspection, editions,
freshness, provenance), [media layout](media-layout.md) (FAT32, large images, Secure Boot,
placement, Ventoy), [security](security.md), [testing](testing.md),
[physical USB checklist](physical-usb-checklist.md).

## Files

Added: `src/engine/media/scripts/WdbMediaAssistant.ps1` (the assistant), `src/engine/media/index.ts`
(media contract, edition map, release data, assistant bundle), `src/data/windows-releases.json`,
`tests/powershell/Media.Tests.ps1`, `tests/unit/media.test.ts`, `tests/e2e/usb.spec.ts`, this folder.
Changed: `src/engine/deployment/index.ts` (manifest `media` block in the ZIP copy), `src/ui/deployment.ts`
(Prepare Installation USB card), `src/ui/layout.ts` (navigation), `src/ui/review.ts` (next step text),
`tests/powershell/deployment-fixture.ts` (migration package ZIP), `tests/unit/powershell.test.ts`,
`package.json` (`test:ps`), README and the roadmap, architecture, testing and Phase 4 USB docs.
Unchanged: the answer file, the embedded runtime manifest, every engine and the orchestrator.

## Acceptance audit

| Requirement | Status | Evidence |
|---|---|---|
| Phase 6 ZIP consumed by the assistant | Done | real fixture ZIPs; manifest, hashes, answer file, embedded scripts |
| Existing Windows USBs updated non-destructively | Done (simulated) | Update scenarios; Windows and unrelated files unchanged |
| New media from an official ISO | Done (simulated) | Create scenarios; DISM, partitioning and mounting are adapters |
| Image metadata inspected | Done | WIM/ESD/SWM header and XML |
| Edition and architecture mismatches detected | Done | blocks; never another edition; answer file unchanged |
| Large-image handling | Done (simulated) | split WIM; ESD export + split; other > 4 GB files block |
| Disks positively identified | Done | fingerprint; revalidation; twins and missing serials refused |
| Destructive operations need explicit confirmation | Done | typed per-disk code, checked again elevated |
| System disks protected | Done | flags, system letter, boot partition; forged plan refused |
| Correct placement | Done | root answer file, `WindowsDeployment\`, backups path; passes `Stage-Deployment` |
| Phase 6 backups copied and verified | Done | pinned hash, name, listed files, verified on the drive |
| Post-copy integrity checks | Done | every file hashed; report |
| Interrupted copies detected and repaired | Done | journal, staged swap, rerun; erase never resumed silently |
| Report reflects actual validation | Done | statuses; "boot not tested" always |
| Existing engines compatible | Done | answer file byte-identical; engines unchanged; contract test |
| All automated tests pass | Done | [testing.md](testing.md) |
| Documented | Done | this folder, README, roadmap |
| No real disk formatting during development | Done | all disk operations simulated |

## Supported / unsupported

| Capability | Status |
|---|---|
| UEFI Windows 11 media (x64, Arm64 boot loader detected) | supported |
| Update of FAT32 (Media Creation Tool) and NTFS (Rufus) Windows USBs | supported (NTFS with a boot warning) |
| Create on removable USB flash drives up to 256 GB | supported |
| Create on external USB hard disks / SSDs | **unsupported** (refused; update only) |
| Legacy BIOS boot | not prepared, not tested |
| Ventoy | detected and refused; auto-install integration not implemented |
| Media Creation Tool automation | not used (documented mechanisms only) |
| PXE | not implemented; architecture kept independent of drive letters |

## Known limitations

- Every disk, ISO and DISM operation ran against simulations; real hardware behaviour is unverified.
- Mounting an ISO may need administrator rights on some systems (Inspect then asks you to mount it in
  Explorer and inspect the drive letter).
- Exporting an ESD keeps only the selected edition on the drive.
- Verification after writing reads the files back through the OS cache; it detects wrong or missing
  data but cannot prove the flash cells.
- Freshness depends on the cached release data (2026-10-22) unless `-CheckOnline` succeeds; the online
  parser relies on the page's "Version XXHX (OS build NNNNN)" headings.
- The console wizard is text based; the website only explains and provides the download.
- A drive that has NTFS boot media made by another tool is updated, but its boot path is that tool's.

## Deferred

Ventoy answer-file injection; legacy BIOS media; external-disk creation; a graphical wizard; real
media and boot testing (combined bare-metal test).
