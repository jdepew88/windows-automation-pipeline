# Phase 7 testing

No real disk was erased, partitioned, formatted or written during development; no ISO was mounted;
DISM was not run. `Media.Tests.ps1` replaces every system adapter: disks are records whose volumes
are temporary folders; the ISO is a folder; DISM split/export write synthetic split images;
partitioning re-creates temporary volumes; signatures, elevation, the clock, cancellation and the
online release page are simulated. Packages are the **real ZIPs** produced by the generator (the
main fixture and the Phase 6 migration fixture with its real backup); images are synthetic WIMs
with the documented header and XML (`New-SimWim`); the FAT32 limit is lowered to 2 MB in the
large-image scenarios so they need no 4 GB files.

## Results (2026-10-22)

| Check | Result |
|---|---|
| typecheck, lint, production build | clean (bundle-size advisory as before) |
| Vitest | **440 passed in 20 files** (Phase 6: 429 in 19): 10 in `media.test.ts`, 1 new in `powershell.test.ts` |
| `Media.Tests.ps1` (USB Preparation Assistant) | **27/27** (new) |
| Windows Update / applications / migration / deployment / Wi-Fi suites | 25/25, 89/89, 24/24, 46/46, 10/10 (unchanged) |
| Playwright (desktop, tablet, Pixel 7) | **142 passed, 2 skipped** (Phase 6: 136 + 2): 2 new tests x 3 sizes; screenshots of the new card reviewed in light and dark themes |
| Mutation checks | 9 deliberate defects in the assistant, each detected |
| Regression | answer files byte-identical to Phase 6 (snapshots unchanged); the ZIP manifest gains only the `media` block |

## Scenario coverage

| Area | Scenarios |
|---|---|
| Disk rules | OS disk (flag and by system letter), internal data disk, removable USB, external USB HDD (update only), Ventoy, read-only, offline, identical twins, no serial, same model and capacity, > 256 GB, fingerprint independent of number |
| Image metadata | multi-edition WIM (Pro at index 6), ESD, split image part, bad magic, damaged XML, DTD refused |
| Compatibility | edition by EditionId, missing Pro (never Home), name ≠ edition id, wrong architecture, several candidates, interactive edition, Windows 10 build |
| Freshness | current, outdated, end of service (24H2 Pro vs Enterprise), newer than known, online refresh, offline fallback with date |
| Package | real ZIP valid with pinned answer file; tampered script, changed answer file, unlisted file, unexpected root entry, traversal entry, renamed answer file, missing, not a ZIP; pre-Phase 7 package; foreign answer file |
| Update | placement at the root, Windows and unrelated files untouched, no merge, replace keeps WDB-previous, repair in place rewrites only damaged files, interrupted copy (Incomplete, no answer file, live folder untouched, rerun completes), cancel before/after changes, letter changed / drive removed / look-alike drive, not Windows media, Ventoy, capacity, NTFS, `ei.cfg`, Home-only and Arm64 media, end-of-service warning |
| Backup | required, wrong folder name, modified file, different manifest, unlisted extra file not copied, success + verified on the drive, source kept, contents not in reports, corrupt archive, traversal archive, valid ZIP, not needed = not copied, capacity |
| Create | plan with confirmation code and erase preview, elevation required, wrong/lower-case code refused, success with Microsoft boot files unchanged, 30 GB single FAT32, 64 GB FAT32 + NTFS, no-data option, WIM split, ESD export + split, other > 4 GB file blocks, OS/internal disk refused, no default disk, forged plan refused, swapped stick refused before erasing, interrupted erase not resumed, interrupted copy resumed without second erase, ISO hash mismatch/match, unsigned or wrongly signed boot files, non-Windows ISO, missing ISO with the official link |
| Inspect / Verify | read-only (hashes unchanged), self-check labelled, nested answer file, missing answer file, case-insensitive name, tampered answer file, another package |
| Paths | spaces, long names, Unicode, case-insensitive identity, traversal/drive/backslash package paths |
| Contract | a prepared drive passes the deployment's `Stage-Deployment.ps1` verification; the backup sits where the engine searches |
| Wizard | scripted Update flow; nothing written without YES; drive list explains refusals |
| Static (unit) | destructive cmdlets only in adapters; no BCD/boot/Secure Boot/security changes; one network call (release page); package content never executed; edition map and layout identical in PowerShell, TypeScript and the engine |

## Not tested: needs real hardware (status: UNVERIFIED)

Real disk enumeration (CIM and Storage module) on USB sticks, card readers and external disks;
`Clear-Disk`/`Initialize-Disk`/`New-Partition`/`Format-Volume` on a removable drive; `Mount-DiskImage`
of a real ISO; DISM split/export of a real 5-7 GB image; Windows Setup installing from the split
image; UEFI boot of the created drive with Secure Boot on; behaviour when a stick is unplugged mid-copy.
See [physical-usb-checklist.md](physical-usb-checklist.md).
