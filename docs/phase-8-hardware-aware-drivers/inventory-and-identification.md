# Hardware inventory, device identification and assessment

## Sources (read-only, no administrator rights needed for `-Mode Inspect`)

| Data | Interface |
|---|---|
| Present devices, hardware IDs, compatible IDs, class, class GUID, problem code, status | CIM `Win32_PnPEntity` (`PNPDeviceID`, `HardwareID`, `CompatibleID`, `PNPClass`, `ClassGuid`, `ConfigManagerErrorCode`, `Present`) |
| Installed driver per device: provider, version, date, INF, signer | CIM `Win32_PnPSignedDriver` |
| Parent device (storage controller of a disk) | `Get-PnpDeviceProperty -KeyName DEVPKEY_Device_Parent` |
| Computer: manufacturer, model, family, SKU, board, BIOS version, processors, chassis | `Win32_ComputerSystem`, `Win32_BaseBoard`, `Win32_BIOS`, `Win32_Processor`, `Win32_SystemEnclosure` |
| Third-party packages already in the driver store | `C:\Windows\INF\oem*.inf` (parsed, never executed) |
| Restart pending | CBS `RebootPending`, Windows Update `RebootRequired` registry keys |
| Organization restrictions | `HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions` (read only) |

Serial numbers, UUIDs, MAC addresses, user and computer names are never read into a shared file.
Instance IDs keep `enumerator\device-id\` and replace the instance-specific part (which can be a
serial number, e.g. USB sticks) by a hash: `USB\VID_0781&PID_5581\#3f2a9c1d`.

## Identification (never by name)

From the hardware and compatible IDs: `PCI\VEN_xxxx&DEV_xxxx&SUBSYS_ssssvvvv&REV_xx` (vendor,
device, subsystem device and subsystem vendor, revision; class code from `CC_xxxx`),
`USB\VID_xxxx&PID_xxxx` (and `USB\Class_..`), `HDAUDIO\FUNC_01&VEN_xxxx&DEV_xxxx` (codec vendor),
`ACPI\<PREFIX>xxxx`, `HID_DEVICE_UP:000D_U:0005` (touchpad) / `:0004` (touch screen), processors
`ACPI\GenuineIntel_…` / `ACPI\AuthenticAMD_…`. The vendor comes from these IDs and the table in
`src/data/driver-sources.json`; an unknown ID stays visible as "Unknown vendor (PCI VEN_1D17)",
never guessed. Intel hardware is identified device by device: an Intel CPU says nothing about the
network, graphics or chipset devices, and an NVIDIA GPU implies no NVIDIA utility.

Categories: `cpu, chipset, display, networkWired, networkWireless, network, bluetooth, storage,
storageNvme, storageSata, storageRaid, usb, audio, touchpad, touchscreen, camera, biometric,
input, firmware, security, monitor, unknown, other` (setup class first, then PCI class code / USB
class / HID usage). Software-only devices (`ROOT\`, `SWD\`, `SW\`, `STORAGE\`, …) are kept apart and
never acted on.

**OEM customization:** a PCI device whose subsystem vendor is a computer manufacturer (Dell 1028,
HP 103C, Lenovo 17AA, ASUS 1043, Acer 1025, MSI 1462, Gigabyte 1458, ASRock 1849, Microsoft 1414,
Samsung 144D, Toshiba 1179, Fujitsu 1734) and differs from the chip vendor is OEM-customized.

## Assessment (from the actual state)

| Problem code / driver | State | Action |
|---|---|---|
| 0, a driver | Healthy (Windows' own drivers included: a Microsoft driver is not "defective") | Keep |
| 0, `display.inf` on a Display device | BasicDriver (Microsoft Basic Display Adapter) | InstallRecommended |
| 28 or 1, no driver | DriverMissing | InstallRequired (network, display, storage, chipset, USB) / InstallRecommended |
| 22 | DisabledIntentionally | None (left disabled) |
| 14 | RestartPending | RestartRequired |
| 1, 18, 19, 28, 31, 32, 37, 39, 40, 41, 50, 56 with a driver | Malfunctioning | InstallRecommended (a different compatible driver may fix it) |
| 48, 52 (blocked / unsigned) | Malfunctioning | ReviewRequired (never an automatic install) |
| 3, 9, 10, 12, 16, 29, 33-36, 38, 42-44, 46, 47, 49, 51, 53-55, 57 | HardwareIssue ("possibly unrelated to drivers") | ReviewRequired |
| no hardware or compatible ID | Unsupported | ReviewRequired |

Code 10 and 43 are treated as possible hardware or firmware problems: installing another driver is
not attempted automatically. A storage controller with a non-inbox driver and a disk below it is
**Setup-critical** (Windows Setup may need its driver to see the disk).

## Inventory schema (`windows-deployment-builder/hardware-inventory`, version 1)

`-Mode Inspect -OutputPath <file>`; validated on import by `HardwareInventorySchema`
(`src/engine/drivers/index.ts`, strict: unknown fields are refused).

```
{ format, formatVersion: 1, inventoryId (16 hex), collectedUtc, tool { name, version },
  system { manufacturer, model, family, boardManufacturer, boardProduct, biosVersion, portable, virtual,
           architecture, osCaption, osBuild, processors[], oem },
  devices [ { key, name, category, class, vendor { id, name, vendorId }, instanceId (hashed),
              hardwareIds[<=8], compatibleIds[<=8], problemCode, driver { provider, version, date, inf, inbox } | null,
              oemCustomized, state, action, confidence (high|medium|low), reasons[], setupCritical, networkCritical } ],
  summary { devices, healthy, basicDriver, driverMissing, malfunctioning, disabled, restartPending, hardwareIssue, unsupported, needingAction },
  setupCritical [device keys], optionalApplications [ { name, vendor, purpose, required: false, installed } ], notice }
```

The website shows this table (Device, Current status, Action, Confidence, reasons; details: hardware
IDs, compatible IDs, driver, INF, problem code, instance) only from an imported file. It records the
summary in the profile (`drivers.hardware`) and the engine notes when the installed computer is a
different model.
