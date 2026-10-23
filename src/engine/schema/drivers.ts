import { z } from 'zod';

/**
 * Phase 8: the "Hardware & Drivers" section of a deployment profile. Hardware is detected on the
 * installed computer; nothing here describes a device the website could see. The section holds
 * the driver policy, an optional pinned offline bundle (identified by its manifest SHA-256),
 * technician-verified packages and approvals, and the summary of a pre-installation inventory.
 */

// eslint-disable-next-line no-control-regex
const text = (max: number) => z.string().max(max).regex(/^[^\u0000-\u001f\u007f]*$/);

export const SHA256_UPPER = /^[0-9A-F]{64}$/;
export const DRIVER_BUNDLE_FOLDER = /^WDB-Drivers-\d{8}-\d{6}-[0-9a-f]{6}$/;
export const DRIVER_BUNDLE_ID = /^[0-9a-f]{16}$/;
export const DRIVER_PACKAGE_ID = /^pkg-[0-9a-f]{12}$/;
export const VERIFIED_PACKAGE_ID = /^[a-z0-9][a-z0-9-]{0,47}$/;
/** A hardware or compatible ID as Windows reports it (PCI\VEN_10DE&DEV_2484&SUBSYS_..., USB\VID_..., ACPI\...). */
export const HARDWARE_ID = /^(PCI|USB|HDAUDIO|ACPI|HID|BTH|DISPLAY|INTELAUDIO|SWC|UEFI)\\[A-Z0-9_&.\-\\]{2,200}$/i;

export const DriverPackageSummarySchema = z
  .object({
    id: z.string().regex(DRIVER_PACKAGE_ID),
    inf: text(120),
    class: text(64),
    provider: text(120),
    version: text(40),
    architectures: z.array(text(16)).max(6),
    minBuild: z.number().int().min(0),
    hardwareIds: z.number().int().min(0),
    whql: z.boolean(),
    /** Placed in $WinPEDriver$ on the USB drive so Windows Setup can load it (storage controllers). */
    setupCritical: z.boolean(),
    networkDriver: z.boolean(),
  })
  .strict();
export type DriverPackageSummary = z.infer<typeof DriverPackageSummarySchema>;

export const DriverBundleReferenceSchema = z
  .object({
    bundleId: z.string().regex(DRIVER_BUNDLE_ID),
    folderName: z.string().regex(DRIVER_BUNDLE_FOLDER),
    manifestSha256: z.string().regex(SHA256_UPPER),
    createdUtc: text(40),
    source: z.object({ kind: z.enum(['driverStoreExport', 'technicianFolder']), manufacturer: text(100), model: text(100), osBuild: text(16), architecture: text(16) }).strict(),
    packages: z.array(DriverPackageSummarySchema).max(400),
    totals: z.object({ packages: z.number().int().min(0), files: z.number().int().min(0), bytes: z.number().int().min(0) }).strict(),
  })
  .strict();
export type DriverBundleReference = z.infer<typeof DriverBundleReferenceSchema>;

export const VerifiedPackageSchema = z
  .object({
    id: z.string().regex(VERIFIED_PACKAGE_ID),
    name: text(100),
    vendor: text(60),
    /** Exact HTTPS URL on an official host (see driver-sources.json downloadHosts); never guessed. */
    url: text(500),
    sha256: z.string().regex(SHA256_UPPER),
    format: z.enum(['cab', 'zip']),
    hardwareIds: z.array(z.string().regex(HARDWARE_ID)).min(1).max(50),
    deviceClass: text(64),
    version: text(40),
    architecture: z.enum(['amd64', 'arm64', 'x86']),
  })
  .strict();
export type VerifiedPackage = z.infer<typeof VerifiedPackageSchema>;

export const HardwareSummarySchema = z
  .object({
    inventoryId: z.string().regex(/^[0-9a-f]{16}$/),
    collectedUtc: text(40),
    manufacturer: text(100),
    model: text(100),
    architecture: text(16),
    osBuild: text(16),
    portable: z.boolean(),
    devices: z.number().int().min(0),
    needingAction: z.number().int().min(0),
    setupCritical: z.number().int().min(0),
  })
  .strict();
export type HardwareSummary = z.infer<typeof HardwareSummarySchema>;

export const DriversSchema = z
  .object({
    /** Detect hardware automatically and run the driver stage on the installed computer. */
    enabled: z.boolean(),
    /** Let the Windows Update stage finish (and its restart happen) before judging drivers. */
    useWindowsUpdate: z.boolean(),
    /** Resolve missing or malfunctioning drivers from verified sources (driver store, bundle, verified packages). */
    resolveMissing: z.boolean(),
    /** Use the pinned offline bundle (offline drivers and network bootstrap). */
    includeOfflinePackages: z.boolean(),
    /** A working driver is replaced only with a technician's approval (never by version alone). */
    optionalReplacements: z.enum(['never', 'approvedOnly']),
    /** List unresolved hardware as follow-up tasks in the deployment report. */
    reportUnresolved: z.boolean(),
    /** Try verified offline network drivers when no network adapter works. */
    networkBootstrap: z.boolean(),
    maxReboots: z.number().int(),
    bundle: DriverBundleReferenceSchema.nullable(),
    verifiedPackages: z.array(VerifiedPackageSchema).max(20),
    approvals: z.array(z.object({ packageId: z.string().regex(/^(pkg-[0-9a-f]{12}|[a-z0-9][a-z0-9-]{0,47})$/), hardwareId: z.string().regex(HARDWARE_ID) }).strict()).max(50),
    hardware: HardwareSummarySchema.nullable(),
  })
  .strict();
export type Drivers = z.infer<typeof DriversSchema>;
