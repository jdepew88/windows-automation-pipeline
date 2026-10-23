# Driver matching, trusted sources and vendors

## Source order

1. The device's current driver, if the device is healthy: kept. A newer version alone never replaces
   it; a replacement needs `optionalReplacements: approvedOnly` **and** an approval for that package
   and hardware ID, and is still refused if not newer, not for that subsystem, or an inbox driver.
2. **Windows Update**, through the existing engine and its policy (see [windows-update.md](windows-update.md)).
3. **The Windows driver store** (third-party INFs already staged, e.g. by `$WinPEDriver$`): for a device
   without a driver, `pnputil /scan-devices /instanceid <id>` asks Windows to re-evaluate it.
4. **The pinned offline bundle** (`drivers.bundle`), staged from `<drive>\WindowsDeployment\drivers\<folder>`
   only if its manifest SHA-256 is the pinned one and every file, INF and catalog checks out.
5. **Technician packages** (`DeploymentRecovery.ps1 -Action AddDrivers -DriverPath <folder>`).
6. **Verified downloads**: an exact HTTPS URL on an allowed official host + SHA-256 + hardware IDs, entered
   by a technician; INF packages in `.cab`/`.zip` only.
7. Otherwise a **manual action**: the device, its first hardware ID, why, and the official page
   (the computer manufacturer's for OEM-customized parts and laptops, else the component vendor's, else
   the Microsoft Update Catalog).

## Candidate filter (`Test-WdvCandidate`), then Windows decides

| Check | Refused when |
|---|---|
| Hardware ID match | none of the device's hardware IDs (most specific first, as Windows orders them) or compatible IDs is in the INF's models |
| Generic match | only a class-generic ID matches (`PCI\CC_…`, `PCI\VEN_x&CC_…`, `USB\Class_…`, `HID_DEVICE…`, `ACPI\PNP…`, `*…`): uncertain, manual review |
| Unknown class | the device has no class yet and only a compatible ID matches |
| Class | device class GUID ≠ the INF's `ClassGuid`; extension INFs are never installed on their own |
| Architecture | no models section for this architecture (`NTamd64`, `NTarm64`, `NTx86`) |
| Windows version | the `TargetOSVersion` decoration's build is newer than this Windows |
| Signature | catalog missing, Authenticode status not `Valid`, or signer not "Microsoft Windows Hardware Compatibility Publisher" (WHQL/attestation; 64-bit Windows 11 needs it for kernel drivers with Secure Boot) |
| OEM subsystem | the device is OEM-customized, works with its driver, and the package does not list its `SUBSYS_` ID |
| Version | healthy: not newer; malfunctioning: older (downgrade) or the identical driver already failing (NoEffect) |

Ranking among eligible candidates: hardware-ID match before compatible ID, earlier (more specific)
ID position first, then source order (driver store, bundle, technician, download), then version.
Then `pnputil /add-driver <inf> /install` **does not force** the driver: Windows applies its own
ranking ([PnPUtil syntax](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax):
"If the driver is not the highest ranked driver on the system, PnPUtil will not force it onto the
device"). The result is read from the device afterwards (see [sequencing-and-recovery.md](sequencing-and-recovery.md)).

## Automated vs manual, per source

| Path | Automated | Conditions |
|---|---|---|
| Keep the existing driver | yes | device healthy |
| Windows Update drivers | yes, by the Windows Update engine | `windowsUpdate.drivers` resolves to include (the owner default excludes them) |
| Driver store re-evaluation | yes | device has no driver, a store INF matches |
| Offline bundle | yes | pinned hash, on a ready drive at first sign-in, all checks above |
| `$WinPEDriver$` during Setup | yes, by Windows Setup | Setup-critical packages placed by the USB assistant |
| Technician packages | yes, after the technician adds them | Microsoft-signed INF packages |
| Verified downloads | yes | technician-entered URL/hash/IDs, official host, network |
| Vendor EXE installers (NVIDIA, AMD, Intel, OEM) | **never** | manual action with the official page |
| Dell Command Update, HP Image Assistant, Lenovo System Update, MyASUS, … | **never** | listed as optional applications |
| BIOS / firmware | **never** | named in drivers.json; manufacturer page |
| Removing or rolling back a driver | **never** | technician instructions (Device Manager › Roll Back Driver) |

No URL is ever composed or guessed; no search page, driver-updater site or third-party bundle is
used. Support pages in `driver-sources.json` were checked on 2026-10-22 (HTTP 200 for NVIDIA, AMD,
HP, ASUS, Realtek, Microsoft Update Catalog; 301/302 to a regional page for Lenovo and Surface;
Intel, Dell, MSI and Gigabyte answer scripts with HTTP 403 (bot protection); Acer did not answer
scripts and is marked unverified). They are shown to people, never downloaded from.

## Intel, AMD, NVIDIA

- **Intel**: CPU, iGPU, Ethernet, Wi-Fi, Bluetooth, chipset/platform (`INT…`/`INTC…` ACPI IDs, SMBus,
  MEI, LPC) are separate devices, each assessed on its own. Working chipset INF/inbox drivers are kept.
  Intel Driver & Support Assistant is an optional application, never installed.
- **AMD**: Ryzen CPU, chipset (`AMDI…`, SMBus), integrated and discrete Radeon are separate. The display
  driver (INF) is distinguished from AMD Software: Adrenalin Edition (an application, optional). An OEM
  laptop's AMD graphics package (OEM subsystem ID) is not replaced by a generic one.
- **NVIDIA**: identified by `PCI\VEN_10DE` + device and subsystem IDs. On the Microsoft Basic Display
  Adapter the stage looks for a compatible driver (Windows Update, store, bundle, verified package) and
  otherwise gives the NVIDIA page. The NVIDIA App and the CUDA Toolkit are never installed because a GPU
  is present. Branch policy (Game Ready vs Studio): the stage never chooses; it uses the driver Windows
  Update offers or the exact package a technician verified (Studio for creative/production workloads,
  Game Ready for gaming; both WHQL for the same hardware).

## OEM compatibility

Computer manufacturer, model, family/SKU, board, BIOS version and chassis are recorded; laptops
(portable chassis or `PCSystemType` 2) and OEM-customized devices get the manufacturer's support page
first. A working OEM driver (OEM subsystem ID, non-inbox) is never replaced by a generic component
package; for a device without a driver a generic package may be used, with a note that the OEM package
is preferred. BIOS and firmware updates are a separate category and never automated.

## Hardware-specific applications (Phase 6 exclusions)

Phase 6 leaves hardware utilities out of application restoration. Phase 8 evaluates them as
**optional applications**: `drivers.json › optionalApplications` lists the vendor tools that relate to
the hardware found (NVIDIA App, CUDA Toolkit, Intel DSA, AMD Software, Realtek Audio Console, Dell
Command | Update, HP Support Assistant, Lenovo Vantage, MyASUS, …) with `required: false` and "the
application profile decides". Nothing is installed because hardware is present; the customer's
application profile stays authoritative.
