# Physical USB checklist (for the combined bare-metal test after Phase 9)

Nothing below has been done. Use a spare computer for preparation if possible and **unplug every
external drive that matters** before starting.

1. `-Mode Discover`: the internal disk is marked "no - it holds the running Windows"; the stick shows
   the correct model, serial and size; an external hard disk shows "erase: no".
2. `-Mode Inspect -Iso <official ISO>` (as administrator if mounting needs it): editions, Pro index,
   build and revision match `dism /Get-WimInfo` for the same file.
3. Create on a 16 or 32 GB stick with `-IsoSha256` from Microsoft's page: plan, confirm, Apply.
   Check: one FAT32 partition `WDB-BOOT`; `sources\install*.swm` present when the image was over
   4 GB; report "Ready for installation".
4. Create on a 64 or 128 GB stick: FAT32 32 GB + NTFS `WDB-DATA`; both visible in Explorer.
5. Unplug the stick during the copy: the run stops, the report says Incomplete; plug in, run the same
   plan again: completes without erasing again.
6. Update a Media Creation Tool stick with a deployment and the Phase 6 backup; Verify; then Update
   again with another package and replace: previous kept in `WDB-previous`.
7. `E:\WindowsDeployment\setup.cmd -Verify` on another PC: passes.
8. Boot the target computer with Secure Boot on (UEFI): Setup starts, uses the answer file
   (edition Pro, no edition prompt), split image installs. Record "boot tested" only now.
9. Remove the stick after Windows Setup finishes: the deployment continues; settings are restored
   from the staged backup.
10. Ventoy stick: refused, with the explanation.

Record the firmware, stick models and results in the combined validation log.
