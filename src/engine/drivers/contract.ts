/**
 * Phase 8: the driver stage's place in the orchestration and its result contract (drivers.json)
 * for Phase 9. The engine is src/engine/drivers/scripts/DriverEngine.ps1; this file fixes the
 * paths it writes and the shape of what it reports.
 *
 * Sequence (docs/phase-8-hardware-aware-drivers/sequencing.md):
 *   1. Windows installed (Setup-critical drivers from $WinPEDriver$ when the media carries them)
 *   2. first start: Inspection A, network bootstrap from verified offline packages if needed
 *   3. Windows Update stage final and its restart done  4. Inspection B
 *   5. resolve what remains from verified sources only  6. restart when required
 *   7. verify every device  8. drivers.json; the application stage starts after this stage
 *
 * Selection rules (unchanged from the Phase 3 interface, now implemented):
 *   - Match on hardware IDs / compatible IDs, never on device names.
 *   - A newer package is not automatically better: a working driver is kept; a replacement needs a
 *     technician's approval; never downgrade a working driver.
 *   - Packages come only from Windows (driver store, Windows Update), a pinned offline bundle or a
 *     technician-verified package, checked by SHA-256 and Microsoft catalog signature.
 */

import { DATA_ROOT } from '../windows-update';

export const DRIVER_STAGE = {
  id: 'drivers',
  phase: 8,
  implemented: true,
  root: `${DATA_ROOT}\\Drivers`,
  inventoryFiles: [`${DATA_ROOT}\\Drivers\\inventory-initial.json`, `${DATA_ROOT}\\Drivers\\inventory-after-updates.json`, `${DATA_ROOT}\\Drivers\\inventory-final.json`],
  stateFile: `${DATA_ROOT}\\Drivers\\state.json`,
  resultFile: `${DATA_ROOT}\\Drivers\\result.json`,
  reportFile: `${DATA_ROOT}\\reports\\drivers.json`,
  marker: `${DATA_ROOT}\\state\\drivers.done`,
  networkFlag: `${DATA_ROOT}\\state\\network-driver-missing.json`,
  /** Resolution starts after the Windows Update stage is final (Inspection A and network bootstrap run before). */
  waitsFor: ['windowsUpdate'] as const,
  /** pnputil needs no user session; device installation runs as SYSTEM. */
  runsAs: 'SYSTEM',
} as const;

/** Final statuses of the stage (result.json), the same names as the other engines. */
export const DRIVER_FINAL_STATUSES = ['Succeeded', 'CompletedWithFollowUp', 'CompletedWithFailures', 'Failed'] as const;
export const DRIVER_MARKER_STATUSES = ['Succeeded', 'CompletedWithFollowUp', 'CompletedWithFailures'] as const;

/** Lifecycle of one driver operation (the Phase 5 names). */
export const DRIVER_OPERATION_STATUSES = [
  'Pending',
  'Running',
  'AlreadySatisfied',
  'Succeeded',
  'WaitingForNetwork',
  'WaitingForReboot',
  'ManualActionRequired',
  'FailedRetryable',
  'FailedPermanent',
  'Unsupported',
] as const;
export type DriverOperationStatus = (typeof DRIVER_OPERATION_STATUSES)[number];

/** Failure classes never retried automatically; Integrity and Signature are security failures. */
export const DRIVER_PERMANENT_CLASSES = ['Permanent', 'Integrity', 'Signature', 'Incompatible', 'Policy', 'DeviceFailure', 'NoEffect', 'NotSelected', 'Manual'] as const;

export const DEVICE_STATES = ['Healthy', 'BasicDriver', 'DriverMissing', 'Malfunctioning', 'DisabledIntentionally', 'RestartPending', 'HardwareIssue', 'Unsupported', 'NotPhysical'] as const;
export type DeviceState = (typeof DEVICE_STATES)[number];
export const DEVICE_ACTIONS = ['Keep', 'InstallRequired', 'InstallRecommended', 'RestartRequired', 'ReviewRequired', 'None'] as const;
export type DeviceAction = (typeof DEVICE_ACTIONS)[number];

/** What Phase 9 must be able to tell apart (drivers.json › health.status). */
export const DRIVER_HEALTH = ['AllHealthy', 'RestartPending', 'InstalledButMalfunctioning', 'MissingDriver', 'PossibleHardwareIssue', 'TechnicianRequired'] as const;
export type DriverHealth = (typeof DRIVER_HEALTH)[number];

export const DRIVER_SOURCES = ['existing', 'windows', 'windowsUpdate', 'driverStore', 'offlineBundle', 'technician', 'verifiedDownload'] as const;

export const DEVICE_CATEGORIES = {
  cpu: 'Processor',
  chipset: 'Chipset and platform',
  display: 'Graphics',
  networkWired: 'Wired network',
  networkWireless: 'Wireless network',
  network: 'Network',
  bluetooth: 'Bluetooth',
  storage: 'Storage controller',
  storageNvme: 'NVMe controller',
  storageSata: 'SATA controller',
  storageRaid: 'RAID / VMD controller',
  usb: 'USB controller',
  audio: 'Audio',
  touchpad: 'Touchpad',
  touchscreen: 'Touchscreen',
  camera: 'Camera',
  biometric: 'Biometric',
  input: 'Input device',
  firmware: 'Firmware',
  security: 'Security device',
  monitor: 'Monitor',
  unknown: 'Unknown device',
  other: 'Other',
} as const;

export interface DriverInfo {
  provider: string;
  version: string;
  date: string;
  inf: string;
  inbox: boolean;
}

/** One device in drivers.json (no raw instance id: its instance-specific part is a hash). */
export interface DriverResultDevice {
  key: string;
  name: string;
  category: keyof typeof DEVICE_CATEGORIES;
  class: string;
  vendor: { id: string; name: string; vendorId: string };
  instanceId: string;
  hardwareIds: string[];
  compatibleIds: string[];
  problemCode: number;
  driver: DriverInfo | null;
  previousDriver: DriverInfo | null;
  oemCustomized: boolean;
  state: DeviceState;
  action: DeviceAction;
  confidence: 'high' | 'medium' | 'low';
  reasons: string[];
  setupCritical: boolean;
  networkCritical: boolean;
  source: (typeof DRIVER_SOURCES)[number];
  result: DriverOperationStatus | 'Kept' | 'NotHandled';
  verification: 'Verified' | 'VerifiedOtherDriver' | 'RestartPending' | 'NotVerified' | 'NotResolved' | 'Failed' | 'DeviceMissing';
  rebootRequired: boolean;
  errors: string[];
  manualAction: { text: string; url: string } | null;
}

export interface DriverResult {
  format: 'windows-deployment-builder/drivers-result';
  version: 1;
  final: boolean;
  status: (typeof DRIVER_FINAL_STATUSES)[number] | 'InProgress';
  engineVersion: string;
  deploymentId: string;
  generatedUtc: string;
  scanUtc: string | null;
  system: { manufacturer: string; model: string; family: string; portable: boolean; virtual: boolean; architecture: string; osBuild: number; biosVersion: string; processors: string[] };
  windowsUpdate: { partOfDeployment: boolean; driversAllowed: boolean; waitedForIt: boolean; stageStatus: string; gate: string };
  health: { status: DriverHealth; flags: Record<string, boolean> };
  devices: DriverResultDevice[];
  operations: { operationId: string; device: string; hardwareId: string; status: DriverOperationStatus; failureClass: string; source: string; attempts: number; verification: string; rebootRequired: boolean; reason: string }[];
  manualActions: { operationId: string; device: string; text: string; url: string }[];
  unsupported: { device: string; instanceId: string; reason: string }[];
  optionalApplications: { name: string; vendor: string; purpose: string; required: false }[];
  networkBootstrap: { status: string; detail: string };
  offlineBundle: { status: string; detail: string; packages: number };
  reboots: number;
}
