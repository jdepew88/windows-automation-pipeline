# Offline drivers, Setup-critical drivers, network bootstrap

## Offline bundle (`windows-deployment-builder/driver-bundle`, version 1)

Made with the hardware & driver tool (`hardware-driver-tool.zip` on the Hardware & Drivers page):

```
DriverEngine.ps1 -Mode Export -OutputPath E:\WindowsDeployment\drivers     (administrator)
DriverEngine.ps1 -Mode Bundle -Path D:\Drivers -OutputPath E:\WindowsDeployment\drivers
DriverEngine.ps1 -Mode ValidateBundle -Path <bundle> [-ExpectedSha256 <hash>]
```

- **Export** copies the driver store's third-party packages (`pnputil /export-driver * <temp>`) from an
  installation with the same hardware. It contains driver packages only: vendor applications, control
  panels and services installed by an EXE are not in the driver store and not exported.
- **Bundle** takes INF packages extracted from the manufacturer's download (`.inf` + `.sys` + `.cat`).
- Every package needs a readable INF with models for an architecture and a catalog signed by
  Microsoft's hardware publisher; others are listed under `refused` and left out. EXE installers are ignored.
- Layout: `WDB-Drivers-<yyyyMMdd-HHmmss>-<id>\drivers-manifest.json` and `packages\<nnn>-<inf>\…`. The
  manifest lists per package: id, folder, INF, class, class GUID, provider, version, date, catalog,
  targets (architecture + minimum build), hardware IDs, signature (status, signer, WHQL), setupCritical
  (storage classes `SCSIAdapter`/`HDC`), networkDriver, every file with size and SHA-256.

The website reads only the manifest (`importDriverBundleManifest`) and pins its SHA-256. On the
installed computer the engine finds the bundle by folder name on a ready drive, accepts only the pinned
one, checks every file, the INF and the catalog again, copies the listed files to
`Drivers\packages\bundle\<folder>` and checks the copy again; before installing a package its files are
hashed once more. A bundle from one computer fits only computers with the same hardware: a package is
used only for a device whose hardware IDs it declares, and only after all checks.

## Setup-critical drivers

Some computers (Intel VMD/RST RAID, some NVMe/RAID controllers) need a storage driver before Windows
Setup can see the disk; it cannot be downloaded after Setup. Detection: an inventory of the existing
installation flags a storage controller with a non-inbox driver and a disk below it (`setupCritical`).
The bundle marks storage-class packages Setup-critical (the website lets the technician change the tick
"Load during Windows Setup").

Delivery: the USB Preparation Assistant copies only those packages to `$WinPEDriver$\<folder>\` at
the root of the drive. Windows Setup scans `$WinPEDriver$` on every drive, loads the INF drivers it finds
and schedules them for the installed Windows (Microsoft:
[Limitations of $WinPeDriver$](https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/limitations-dollar-sign-winpedriver-dollar-sign)).
Microsoft advises not to mix driver versions across injection methods; the assistant therefore does not
touch `boot.wim`/`install.wim` and moves a `$WinPEDriver$` folder of a replaced deployment to
`WDB-previous\<time>\`. The answer file is not changed. Only the pinned bundle's Setup-critical packages
go there; nothing hardware-specific is put on every customer's USB. A deployment whose bundle has
Setup-critical packages cannot be prepared without that bundle (blocker), and Verify reports a missing or
modified `$WinPEDriver$` file as Incomplete.

After installation a storage controller with a disk below it is never changed automatically, and a
storage driver is never removed.

## Network bootstrap

When the computer is offline and a network adapter has no working driver (missing, not working or the
basic driver), at the first start and at every later start while that lasts:

1. the adapter is identified from Inspection A (category network*, its hardware IDs);
2. compatible packages from the staged bundle, technician packages and the driver store are evaluated
   (no downloads);
3. a matching verified package is installed (`trigger: networkBootstrap`);
4. the device is checked again; 5. connectivity is checked again (NCSI probe) for up to 5 minutes;
6. if online, provisioning continues and Windows Update finds the network.

Without a usable driver the state is kept and `state\network-driver-missing.json` says which adapter
and what to do; `status.json` shows `WaitingForNetwork`, and the deployment outcome becomes
**PausedAwaitingNetwork** with that detail (Phase 5). The application engine's network deferrals do not
count against its retry budget (Phase 5), and applications wait for the driver stage anyway. A
technician supplies a driver with `DeploymentRecovery.ps1 -Action AddDrivers -DriverPath <folder>`
(menu item 8): Microsoft-signed INF packages only, copied into the protected folder, then the stage runs
again and the bootstrap retries.
