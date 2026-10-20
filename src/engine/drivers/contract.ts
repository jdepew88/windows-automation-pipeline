/**
 * Phase 4 (manufacturer drivers) - interface only. Phase 3 installs no drivers and generates no
 * driver script. These types fix the hand-off so the later driver stage can plug into the same
 * orchestration: where it runs, what it waits for, what it reads and what it must write.
 *
 * Intended sequence (docs/phase-3/orchestration.md):
 *   1. Windows installed  2. Windows Update stage final  3. inventory of devices and drivers
 *   4. candidate manufacturer packages per device  5. install only verified, applicable packages
 *   6. restart when required  7. validate device status (no new problem codes) and report.
 *
 * Selection rules the implementation must follow:
 *   - Match on hardware IDs / compatible IDs from the inventory, never on device names.
 *   - A newer vendor package is not automatically better: replace a driver only when the vendor
 *     support policy recommends that package for this device (or the device has a problem code),
 *     and never downgrade a driver Windows Update installed unless a policy says so explicitly.
 *   - Packages come only from the vendor's official distribution, verified by signature and hash.
 */

import { DATA_ROOT } from '../windows-update';

export const DRIVER_STAGE = {
  id: 'drivers',
  phase: 4,
  implemented: false,
  root: `${DATA_ROOT}\\Drivers`,
  inventoryFile: `${DATA_ROOT}\\Drivers\\inventory.json`,
  planFile: `${DATA_ROOT}\\Drivers\\plan.json`,
  resultFile: `${DATA_ROOT}\\Drivers\\result.json`,
  marker: `${DATA_ROOT}\\state\\drivers.done`,
  /** The driver stage starts only after these markers (or result files with a final status) exist. */
  waitsFor: ['windowsUpdate'] as const,
  /** It runs as SYSTEM (pnputil / vendor installers need no user session). */
  runsAs: 'SYSTEM',
} as const;

export type DriverVendor = 'nvidia' | 'amd' | 'intel' | 'oem' | 'motherboard' | 'other';

/** One device as Phase 4 must record it before deciding anything (from Win32_PnPSignedDriver / pnputil). */
export interface DriverInventoryEntry {
  instanceId: string;
  deviceName: string;
  deviceClass: string;
  hardwareIds: string[];
  compatibleIds: string[];
  /** Win32 ConfigManagerErrorCode; 0 = working. */
  problemCode: number;
  driver: {
    provider: string;
    version: string;
    date: string;
    infName: string;
    signer: string;
    /** Where the current driver came from, when known. */
    origin: 'inbox' | 'windowsUpdate' | 'vendor' | 'unknown';
  } | null;
  vendor: DriverVendor;
}

export interface DriverInventory {
  schemaVersion: 1;
  computer: string;
  collectedUtc: string;
  system: { manufacturer: string; model: string; baseboard: string; biosVersion: string; osBuild: string };
  devices: DriverInventoryEntry[];
}

export type DriverDecision = 'keep' | 'install' | 'skip' | 'manual';

export interface DriverCandidate {
  instanceId: string;
  vendor: DriverVendor;
  packageName: string;
  packageVersion: string;
  /** Official vendor URL; never a mirror. */
  sourceUrl: string;
  sha256: string;
  signer: string;
  /** Which hardware ID the vendor package declares support for. */
  matchedHardwareId: string;
  decision: DriverDecision;
  /** Why: e.g. "vendor recommends for this device", "current driver is newer", "no match". */
  reason: string;
}

export const DRIVER_RESULT_STATUSES = ['Current', 'Updated', 'RequiresRestart', 'Skipped', 'RequiresInteraction', 'Failed', 'NotApplicable'] as const;
export const DRIVER_FINAL_STATUSES = ['Succeeded', 'CompletedWithFollowUp', 'CompletedWithFailures', 'Failed'] as const;

export interface DriverResult {
  schemaVersion: 1;
  stage: 'drivers';
  status: (typeof DRIVER_FINAL_STATUSES)[number];
  reason: string;
  devices: { instanceId: string; deviceName: string; status: (typeof DRIVER_RESULT_STATUSES)[number]; before: string; after: string; message: string }[];
}
