# Bare-metal checklist (combined test after Phase 9)

Nothing below has been done. Phase 8 was tested with simulated hardware only.

1. On a computer that already runs Windows: `Inspect-Hardware.cmd`; compare the categories, vendors,
   problem codes and drivers with Device Manager; import the file; check the review table.
2. `DriverEngine.ps1 -Mode Plan` there (read-only): the decisions are plausible; no device is wrongly
   "missing" (e.g. working Microsoft class drivers are Healthy).
3. `-Mode Export` to a USB drive; `-Mode ValidateBundle`; attach `drivers-manifest.json`; check that the
   storage controller (if VMD/RAID) is Setup-critical.
4. Prepare the USB with the assistant `-Drivers <bundle>`; Verify: Driver bundle and Setup-critical
   drivers Pass.
5. Install a computer that needs the storage driver (VMD on): Windows Setup shows the disk;
   `Setupact.log` mentions `$WinPEDriver$`.
6. Desktop with an NVIDIA GPU, Windows Update drivers excluded (owner default): after the deployment the
   GPU uses the bundle's NVIDIA driver (Device Manager), drivers.json Succeeded/Verified; Intel/Realtek
   devices unchanged; no NVIDIA App, CUDA or Intel DSA installed.
7. Same with Windows Update drivers included: the GPU driver comes from Windows Update
   (AlreadySatisfied, source windowsUpdate).
8. Computer without network driver and without network: the bundle's NIC driver is installed before
   Windows Update; without it, PausedAwaitingNetwork with the missing adapter; `-Action AddDrivers` from a
   stick resolves it.
9. A driver that needs a restart: one restart, then Verified.
10. Healthy laptop (Dell/HP/Lenovo): no driver replaced; manual actions point to the manufacturer page.
11. Pull the power during a driver installation: after the restart the operation is reconciled, not
    repeated blindly.
12. `drivers.json` validates against `drivers-result.schema.json`; no serial numbers inside.

Record the hardware, firmware, Windows build, results and any deviation in the combined validation log.
