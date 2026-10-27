import { z } from 'zod';
import engineSource from './scripts/DriverEngine.ps1?raw';
import installerSource from './scripts/Install-DriverEngine.ps1?raw';
import sourcesJson from '../../data/driver-sources.json';
import type { Profile } from '../schema/profile';
import { DATA_ROOT, TASK_PATH, TASK_NAME as WU_TASK_NAME, RESULT_FILE as WU_RESULT_FILE, resolveDrivers, type DeploymentAsset } from '../windows-update';
import { DriverBundleReferenceSchema, DRIVER_BUNDLE_FOLDER, DRIVER_BUNDLE_ID, DRIVER_PACKAGE_ID, HARDWARE_ID, SHA256_UPPER, type DriverBundleReference, type HardwareSummary, type VerifiedPackage } from '../schema/drivers';
import { DEVICE_CATEGORIES, DRIVER_STAGE, DEVICE_STATES, DEVICE_ACTIONS } from './contract';
import { sha256, utf8 } from '../deployment/sha256';
import { createZip } from '../deployment/zip';

/**
 * Phase 8: hardware-aware driver provisioning. The website holds only the policy, an optional
 * pinned offline bundle and technician-verified packages; the engine (DriverEngine.ps1, SYSTEM)
 * detects the hardware on the installed computer, keeps working drivers, lets Windows Update go
 * first and installs a verified, compatible driver only where one is needed. Everything a profile
 * can change goes into drivers-config.json.
 */

export const DRIVER_ENGINE_VERSION = '1.0.0';
export const DRIVER_STAGING_DIR = 'C:\\Windows\\Setup\\Scripts\\Drivers';
export const DRIVER_ROOT = DRIVER_STAGE.root;
export const DRIVER_TASK_NAME = 'Drivers';
export const DRIVER_RESULT_FILE = DRIVER_STAGE.resultFile;
export const DRIVER_REPORT_FILE = DRIVER_STAGE.reportFile;
export const DRIVER_MARKER = DRIVER_STAGE.marker;

export const DRIVER_ENGINE_FILE = 'DriverEngine.ps1';
export const DRIVER_INSTALLER_FILE = 'Install-DriverEngine.ps1';
export const DRIVER_CONFIG_FILE = 'drivers-config.json';
export const DRIVER_README_FILE = 'README-Drivers.txt';
export const DRIVER_RESULT_SCHEMA_FILE = 'drivers-result.schema.json';
export const DRIVER_SOURCES_FILE = 'driver-sources.json';
export const DRIVER_TOOL_BUNDLE = 'hardware-driver-tool.zip';
export const DRIVER_BUNDLE_FORMAT = 'windows-deployment-builder/driver-bundle';
export const HARDWARE_INVENTORY_FORMAT = 'windows-deployment-builder/hardware-inventory';
/** Files embedded in the answer file (extracted to DRIVER_STAGING_DIR during specialize). */
export const EMBEDDED_DRIVER_FILES: readonly string[] = [DRIVER_ENGINE_FILE, DRIVER_INSTALLER_FILE, DRIVER_CONFIG_FILE];
/** Where the offline bundle and the Setup-critical drivers go on the installation media. */
export const MEDIA_DRIVERS_DIR = 'WindowsDeployment/drivers';
export const MEDIA_WINPE_DRIVERS_DIR = '$WinPEDriver$';

export const DRIVER_LIMITS = { maxReboots: [0, 5] } as const satisfies Record<string, readonly [number, number]>;

// ------------------------------------------------------------------------------------------------
// Identification data
// ------------------------------------------------------------------------------------------------

const AppSchema = z.object({ name: z.string(), purpose: z.string() }).strict();
const url = z.union([z.literal(''), z.string().url().startsWith('https://')]);
export const DriverSourcesSchema = z
  .object({
    format: z.literal('windows-deployment-builder/driver-sources'),
    version: z.literal(1),
    checkedUtc: z.string(),
    notice: z.string(),
    componentVendors: z.array(
      z.object({ id: z.string().regex(/^[a-z0-9]+$/), name: z.string(), pci: z.array(z.string().regex(/^[0-9A-F]{4}$/)), usb: z.array(z.string().regex(/^[0-9A-F]{4}$/)), acpi: z.array(z.string().regex(/^[A-Z]{3,4}$/)), supportUrl: url, urlCheck: z.string(), optionalApplications: z.array(AppSchema) }).strict(),
    ),
    systemManufacturers: z.array(
      z.object({ id: z.string().regex(/^[a-z0-9]+$/), name: z.string(), match: z.string(), pciSubsystemVendor: z.string().regex(/^[0-9A-F]{4}$/), supportUrl: url, urlCheck: z.string(), optionalApplications: z.array(AppSchema) }).strict(),
    ),
    virtualPlatforms: z.array(z.string()),
    basicDrivers: z.array(z.object({ inf: z.string(), classes: z.array(z.string()), meaning: z.string() }).strict()),
    microsoftCatalogUrl: z.string().url().startsWith('https://'),
    downloadHosts: z.array(z.string().regex(/^[a-z0-9.-]+\.[a-z]{2,}$/)),
    whqlSigners: z.array(z.string()),
    nvidiaBranchPolicy: z.string(),
  })
  .strict();
export const DRIVER_SOURCE_DATA = DriverSourcesSchema.parse(sourcesJson);

export const driversActive = (p: Profile) => p.drivers.enabled;

/** True when the URL is HTTPS on one of the allowed official hosts (no credentials, default port). */
export function allowedDownloadUrl(value: string): boolean {
  let u: URL;
  try {
    u = new URL(value);
  } catch {
    return false;
  }
  return u.protocol === 'https:' && !u.username && !u.password && u.port === '' && DRIVER_SOURCE_DATA.downloadHosts.includes(u.hostname.toLowerCase());
}

// ------------------------------------------------------------------------------------------------
// Engine configuration and assets
// ------------------------------------------------------------------------------------------------

/** How long the stage waits for Windows Update, and its own runtime limit. */
export function driverTiming(p: Profile) {
  const wait = p.windowsUpdate.enabled && p.drivers.useWindowsUpdate ? p.windowsUpdate.maxRuntimeHours + 2 : 1;
  return { waitForUpdatesHours: wait, maxRuntimeHours: wait + 6 };
}

export function driversConfig(p: Profile) {
  const d = p.drivers;
  const t = driverTiming(p);
  return {
    schemaVersion: 1 as const,
    engineVersion: DRIVER_ENGINE_VERSION,
    dataRoot: DATA_ROOT,
    taskPath: TASK_PATH,
    taskName: DRIVER_TASK_NAME,
    policy: {
      useWindowsUpdate: d.useWindowsUpdate,
      resolveMissing: d.resolveMissing,
      offlinePackages: d.includeOfflinePackages,
      optionalReplacements: d.optionalReplacements,
      reportUnresolved: d.reportUnresolved,
      networkBootstrap: d.networkBootstrap,
    },
    maxReboots: d.maxReboots,
    maxAttemptsPerOperation: 2,
    maxRuntimeHours: t.maxRuntimeHours,
    waitForUpdatesHours: t.waitForUpdatesHours,
    networkWaitMinutes: 5,
    lockWaitMinutes: 60,
    rebootWarningSeconds: p.windowsUpdate.rebootWarningSeconds,
    maxNetworkDeferrals: 6,
    windowsUpdate: { enabled: p.windowsUpdate.enabled, drivers: resolveDrivers(p), stateFile: `${DATA_ROOT}\\Updates\\state.json`, resultFile: WU_RESULT_FILE, taskPath: TASK_PATH, taskName: WU_TASK_NAME },
    bundle: d.bundle && d.includeOfflinePackages ? { bundleId: d.bundle.bundleId, folderName: d.bundle.folderName, manifestSha256: d.bundle.manifestSha256 } : null,
    verifiedPackages: d.verifiedPackages.map((v) => ({ ...v, hardwareIds: v.hardwareIds.map((h) => h.toUpperCase()) })),
    approvals: d.optionalReplacements === 'approvedOnly' ? d.approvals.map((a) => ({ packageId: a.packageId, hardwareId: a.hardwareId.toUpperCase() })) : [],
    expectedSystem: d.hardware ? { manufacturer: d.hardware.manufacturer, model: d.hardware.model } : null,
    sources: DRIVER_SOURCE_DATA,
  };
}
export type DriversConfig = ReturnType<typeof driversConfig>;

const crlf = (s: string): string => s.replace(/\r?\n/g, '\r\n');

/** JSON Schema of drivers.json (the Phase 9 contract), shipped next to the engine. */
export const DRIVERS_RESULT_JSON_SCHEMA = {
  $schema: 'https://json-schema.org/draft/2020-12/schema',
  $id: 'windows-deployment-builder/drivers-result/1',
  title: 'Windows Deployment Builder driver result (drivers.json)',
  type: 'object',
  required: ['format', 'version', 'final', 'status', 'engineVersion', 'deploymentId', 'generatedUtc', 'system', 'windowsUpdate', 'health', 'devices', 'operations', 'manualActions', 'unsupported', 'optionalApplications', 'networkBootstrap', 'offlineBundle'],
  properties: {
    format: { const: 'windows-deployment-builder/drivers-result' },
    version: { const: 1 },
    final: { type: 'boolean' },
    status: { enum: ['InProgress', 'Succeeded', 'CompletedWithFollowUp', 'CompletedWithFailures', 'Failed'] },
    engineVersion: { type: 'string' },
    deploymentId: { type: 'string' },
    generatedUtc: { type: 'string' },
    scanUtc: { type: ['string', 'null'] },
    health: {
      type: 'object',
      required: ['status', 'flags'],
      properties: { status: { enum: ['AllHealthy', 'RestartPending', 'InstalledButMalfunctioning', 'MissingDriver', 'PossibleHardwareIssue', 'TechnicianRequired'] }, flags: { type: 'object', additionalProperties: { type: 'boolean' } } },
    },
    devices: {
      type: 'array',
      items: {
        type: 'object',
        required: ['key', 'name', 'category', 'state', 'action', 'result', 'verification', 'rebootRequired', 'hardwareIds'],
        properties: {
          key: { type: 'string' },
          name: { type: 'string' },
          category: { enum: Object.keys(DEVICE_CATEGORIES) },
          state: { enum: [...DEVICE_STATES] },
          action: { enum: [...DEVICE_ACTIONS] },
          instanceId: { type: 'string', description: 'Enumerator\\device ID\\#hash: the instance-specific part (it may be a serial number) is never published' },
          hardwareIds: { type: 'array', items: { type: 'string' } },
          problemCode: { type: 'integer' },
          source: { type: 'string' },
          result: { type: 'string' },
          verification: { type: 'string' },
          rebootRequired: { type: 'boolean' },
        },
      },
    },
  },
} as const;

function readme(p: Profile): string {
  const t = driverTiming(p);
  return `Windows Deployment Builder - hardware-aware driver engine ${DRIVER_ENGINE_VERSION}
==========================================================================

These files are generated by Windows Deployment Builder and embedded in autounattend.xml; the
deployment orchestrator installs them at the first sign-in. You only need them separately to
inspect them or to run the engine on a computer that is already installed.

Files
  ${DRIVER_ENGINE_FILE}         The engine. Runs as SYSTEM from ${TASK_PATH}${DRIVER_TASK_NAME}.
  ${DRIVER_INSTALLER_FILE}  Secures ${DATA_ROOT}, copies the engine, registers the task.
  ${DRIVER_CONFIG_FILE}       Policy, offline bundle, verified packages, identification data.
  ${DRIVER_RESULT_SCHEMA_FILE} JSON Schema of the result for later health reporting.

What happens
  1. First start: every present device is inspected (identifiers, driver, problem code).
     If no network adapter has a working driver, verified offline packages are tried first.
  2. ${p.windowsUpdate.enabled && p.drivers.useWindowsUpdate ? `Waits for the Windows Update stage to finish and for its restart (at most ${t.waitForUpdatesHours} h).` : 'Does not wait for Windows Update.'}
     Windows Update drivers: ${resolveDrivers(p) === 'include' ? 'allowed (Windows Update may install drivers itself)' : 'not allowed by this deployment\'s update policy'}.
  3. Inspects again. What works is kept; nothing is replaced because a newer version exists.
  4. ${p.drivers.resolveMissing ? 'For a missing or broken driver only: the Windows driver store, the pinned offline bundle, then technician-verified packages (SHA-256, Microsoft-signed INF only).' : 'Resolution from verified sources is off: missing drivers are reported.'}
     Windows' own driver ranking makes the final choice (pnputil /add-driver /install).
  5. Verifies every device (after a restart when needed) and reports the rest as manual actions
     with the official support page. BIOS and firmware are never updated.

Manual use (elevated Windows PowerShell 5.1, files in one folder)
  powershell.exe -ExecutionPolicy Bypass -File .\\${DRIVER_ENGINE_FILE} -Mode Inspect
      (read-only inventory; -OutputPath <file.json> writes the shareable inventory)
  powershell.exe -ExecutionPolicy Bypass -File .\\${DRIVER_ENGINE_FILE} -Mode Plan
      (read-only: what would be done on this computer)

Results
  Log:      ${DRIVER_ROOT}\\logs\\engine.log, attempts in logs\\attempts.jsonl
  Status:   ${DRIVER_ROOT}\\status.json (live)
  Result:   ${DRIVER_RESULT_FILE}
            status = Succeeded | CompletedWithFollowUp | CompletedWithFailures | Failed
  Report:   ${DRIVER_REPORT_FILE} (every device, health, manual actions)
  Events:   Application log, source "WindowsDeploymentBuilder", IDs 4000 started, 4001 restart,
            4100 Succeeded, 4101 CompletedWithFollowUp, 4102 CompletedWithFailures, 4103 Failed,
            4110 a driver left a device not working

Status: tested with simulated hardware only. Not yet run on a real computer.
`;
}

/** Downloadable deployment assets; empty when the stage is off. */
export function driverAssets(p: Profile): DeploymentAsset[] {
  if (!driversActive(p)) return [];
  return [
    { name: DRIVER_ENGINE_FILE, content: crlf(engineSource), mime: 'text/plain', description: 'Driver engine (runs as SYSTEM from its scheduled task)', group: 'drivers' },
    { name: DRIVER_INSTALLER_FILE, content: crlf(installerSource), mime: 'text/plain', description: 'Installs the driver engine and registers its task', group: 'drivers' },
    { name: DRIVER_CONFIG_FILE, content: crlf(JSON.stringify(driversConfig(p), null, 2) + '\n'), mime: 'application/json', description: 'Driver policy, offline bundle and verified packages from this profile', group: 'drivers' },
    { name: DRIVER_RESULT_SCHEMA_FILE, content: crlf(JSON.stringify(DRIVERS_RESULT_JSON_SCHEMA, null, 2) + '\n'), mime: 'application/json', description: 'JSON Schema of drivers.json (for health reporting)', group: 'drivers' },
    { name: DRIVER_README_FILE, content: crlf(readme(p)), mime: 'text/plain', description: 'How the driver stage works and where it reports', group: 'drivers' },
  ];
}

// ------------------------------------------------------------------------------------------------
// Offline bundle (drivers-manifest.json) import: only the manifest is read, never a driver file
// ------------------------------------------------------------------------------------------------

// eslint-disable-next-line no-control-regex
const text = (max: number) => z.string().max(max).regex(/^[^\u0000-\u001f\u007f]*$/);
const relPath = text(240).regex(/^[A-Za-z0-9._ ()+,#&~-]+(\/[A-Za-z0-9._ ()+,#&~-]+)*$/).refine((s) => !s.split('/').some((x) => x === '..' || x === '.'), 'unsafe path');

export const DriverBundleManifestSchema = z
  .object({
    format: z.literal(DRIVER_BUNDLE_FORMAT),
    formatVersion: z.literal(1),
    bundleId: z.string().regex(DRIVER_BUNDLE_ID),
    folderName: z.string().regex(DRIVER_BUNDLE_FOLDER),
    createdUtc: text(40),
    tool: z.object({ name: text(64), version: text(32) }).strict(),
    source: z.object({ kind: z.enum(['driverStoreExport', 'technicianFolder']), manufacturer: text(100), model: text(100), osBuild: text(16), architecture: text(16) }).strict(),
    packages: z
      .array(
        z
          .object({
            id: z.string().regex(DRIVER_PACKAGE_ID),
            folder: relPath.refine((s) => s.startsWith('packages/'), 'packages live under packages/'),
            inf: relPath,
            class: text(64),
            classGuid: text(40),
            provider: text(120),
            version: text(40),
            date: text(16),
            catalog: text(120),
            targets: z.array(z.object({ arch: text(16), minBuild: z.number().int().min(0) }).strict()).max(16),
            hardwareIds: z.array(text(260)).max(4000),
            signature: z.object({ status: text(40), signer: text(200), whql: z.boolean() }).strict(),
            setupCritical: z.boolean(),
            networkDriver: z.boolean(),
            files: z.array(z.object({ path: relPath, size: z.number().int().min(0), sha256: z.string().regex(SHA256_UPPER) }).strict()).max(5000),
            bytes: z.number().int().min(0),
          })
          .strict(),
      )
      .max(400),
    refused: z.array(z.object({ inf: text(200), reason: text(500) }).strict()).max(1000),
    totals: z.object({ packages: z.number().int().min(0), files: z.number().int().min(0), bytes: z.number().int().min(0) }).strict(),
    notice: text(500),
  })
  .strict();
export type DriverBundleManifest = z.infer<typeof DriverBundleManifestSchema>;

export interface BundleImportResult {
  ok: boolean;
  errors: string[];
  warnings: string[];
  manifest?: DriverBundleManifest;
  reference?: DriverBundleReference;
}

/** Validates drivers-manifest.json bytes and returns the reference the deployment pins. */
export function importDriverBundleManifest(bytes: Uint8Array): BundleImportResult {
  if (bytes.length > 8 * 1024 * 1024) return { ok: false, errors: ['drivers-manifest.json is larger than 8 MB.'], warnings: [] };
  let raw: unknown;
  try {
    raw = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes).replace(/^\uFEFF/, ''));
  } catch {
    return { ok: false, errors: ['Not a JSON file.'], warnings: [] };
  }
  const parsed = DriverBundleManifestSchema.safeParse(raw);
  if (!parsed.success) return { ok: false, errors: parsed.error.issues.slice(0, 6).map((i) => `${i.path.join('.') || 'manifest'}: ${i.message}`), warnings: [] };
  const m = parsed.data;
  const errors: string[] = [];
  const warnings: string[] = [];
  const ids = new Set<string>();
  for (const p of m.packages) {
    if (ids.has(p.id)) errors.push(`Package ${p.id} appears twice.`);
    ids.add(p.id);
    if (!p.files.some((f) => `${p.folder}/${f.path}`.toLowerCase() === `${p.folder}/${p.inf}`.toLowerCase())) errors.push(`${p.folder}: the INF ${p.inf} is not among the listed files.`);
    if (!p.signature.whql) errors.push(`${p.inf}: not signed by Microsoft's hardware publisher; the bundle tool should have refused it.`);
  }
  if (m.packages.length === 0) errors.push('The bundle contains no driver package.');
  if (m.refused.length) warnings.push(`${m.refused.length} INF file(s) were refused when the bundle was built (unsigned, unreadable or declaring no hardware); they are not part of it.`);
  if (errors.length) return { ok: false, errors, warnings };
  const reference: DriverBundleReference = DriverBundleReferenceSchema.parse({
    bundleId: m.bundleId,
    folderName: m.folderName,
    manifestSha256: sha256(bytes),
    createdUtc: m.createdUtc,
    source: m.source,
    packages: m.packages.map((p) => ({
      id: p.id,
      inf: p.inf.split('/').pop()!,
      class: p.class,
      provider: p.provider,
      version: p.version,
      architectures: [...new Set(p.targets.map((t) => t.arch))].slice(0, 6),
      minBuild: Math.min(...p.targets.map((t) => t.minBuild), 99999),
      hardwareIds: p.hardwareIds.length,
      whql: p.signature.whql,
      setupCritical: p.setupCritical,
      networkDriver: p.networkDriver,
    })),
    totals: m.totals,
  });
  return { ok: true, errors: [], warnings, manifest: m, reference };
}

// ------------------------------------------------------------------------------------------------
// Pre-installation hardware inventory import (DriverEngine.ps1 -Mode Inspect -OutputPath)
// ------------------------------------------------------------------------------------------------

const DriverInfoSchema = z.object({ provider: text(200), version: text(60), date: text(16), inf: text(120), inbox: z.boolean() }).strict();
export const InventoryDeviceSchema = z
  .object({
    key: z.string().regex(/^dev-[0-9a-f]{12}$/),
    name: text(300),
    category: z.enum(Object.keys(DEVICE_CATEGORIES) as [keyof typeof DEVICE_CATEGORIES, ...(keyof typeof DEVICE_CATEGORIES)[]]),
    class: text(64),
    vendor: z.object({ id: text(32), name: text(120), vendorId: text(32) }).strict(),
    instanceId: text(400),
    hardwareIds: z.array(text(260)).max(8),
    compatibleIds: z.array(text(260)).max(8),
    problemCode: z.number().int().min(0).max(100),
    driver: DriverInfoSchema.nullable(),
    oemCustomized: z.boolean(),
    state: z.enum(DEVICE_STATES),
    action: z.enum(DEVICE_ACTIONS),
    confidence: z.enum(['high', 'medium', 'low']),
    reasons: z.array(text(1000)).max(10),
    setupCritical: z.boolean(),
    networkCritical: z.boolean(),
  })
  .strict();
export type InventoryDevice = z.infer<typeof InventoryDeviceSchema>;

export const HardwareInventorySchema = z
  .object({
    format: z.literal(HARDWARE_INVENTORY_FORMAT),
    formatVersion: z.literal(1),
    inventoryId: z.string().regex(/^[0-9a-f]{16}$/),
    collectedUtc: text(40),
    tool: z.object({ name: text(64), version: text(32) }).strict(),
    system: z
      .object({
        manufacturer: text(100), model: text(100), family: text(100), boardManufacturer: text(100), boardProduct: text(100), biosVersion: text(100),
        portable: z.boolean(), virtual: z.boolean(), architecture: text(16), osCaption: text(120), osBuild: text(16), processors: z.array(text(200)).max(16), oem: text(32),
      })
      .strict(),
    devices: z.array(InventoryDeviceSchema).max(2000),
    summary: z.record(z.string(), z.number().int().min(0)),
    setupCritical: z.array(z.string().regex(/^dev-[0-9a-f]{12}$/)).max(100),
    optionalApplications: z.array(z.object({ name: text(120), vendor: text(120), purpose: text(500), required: z.literal(false), installed: text(200) }).strict()).max(50),
    notice: text(500),
  })
  .strict();
export type HardwareInventory = z.infer<typeof HardwareInventorySchema>;

/** Largest inventory accepted: above what the schema's bounds allow, and a limit on the validation work. */
export const MAX_HARDWARE_INVENTORY_BYTES = 16 * 1024 * 1024;

export function importHardwareInventory(textValue: string): { ok: boolean; errors: string[]; inventory?: HardwareInventory } {
  if (textValue.length > MAX_HARDWARE_INVENTORY_BYTES) return { ok: false, errors: [`File is larger than ${MAX_HARDWARE_INVENTORY_BYTES / 1024 / 1024} MB: not a hardware inventory.`] };
  let raw: unknown;
  try {
    raw = JSON.parse(textValue.replace(/^\uFEFF/, ''));
  } catch {
    return { ok: false, errors: ['Not a JSON file.'] };
  }
  const r = HardwareInventorySchema.safeParse(raw);
  if (!r.success) return { ok: false, errors: r.error.issues.slice(0, 6).map((i) => `${i.path.join('.') || 'inventory'}: ${i.message}`) };
  return { ok: true, errors: [], inventory: r.data };
}

export function hardwareSummary(inv: HardwareInventory): HardwareSummary {
  return {
    inventoryId: inv.inventoryId,
    collectedUtc: inv.collectedUtc,
    manufacturer: inv.system.manufacturer,
    model: inv.system.model,
    architecture: inv.system.architecture,
    osBuild: inv.system.osBuild,
    portable: inv.system.portable,
    devices: inv.devices.length,
    needingAction: inv.devices.filter((d) => d.action !== 'Keep' && d.action !== 'None').length,
    setupCritical: inv.setupCritical.length,
  };
}

const STATE_LABELS: Record<(typeof DEVICE_STATES)[number], string> = {
  Healthy: 'Healthy',
  BasicDriver: 'Basic driver',
  DriverMissing: 'Missing driver',
  Malfunctioning: 'Driver not working',
  DisabledIntentionally: 'Disabled',
  RestartPending: 'Restart pending',
  HardwareIssue: 'Possible hardware issue',
  Unsupported: 'Cannot be identified',
  NotPhysical: 'Software device',
};
const ACTION_LABELS: Record<(typeof DEVICE_ACTIONS)[number], string> = {
  Keep: 'Keep existing',
  InstallRequired: 'Driver required',
  InstallRecommended: 'Compatible driver recommended',
  RestartRequired: 'Restart',
  ReviewRequired: 'Review required',
  None: 'Nothing to do',
};

export interface ReviewRow {
  key: string;
  device: string;
  category: string;
  vendor: string;
  status: string;
  action: string;
  confidence: string;
  reason: string;
  attention: boolean;
  setupCritical: boolean;
  details: { hardwareIds: string[]; compatibleIds: string[]; driver: string; inf: string; problemCode: number; instanceId: string; oemCustomized: boolean };
}

/**
 * The review table of an imported inventory: one row per device, straight from the collected
 * data (the assessment the engine made on that computer). Nothing is invented here.
 */
export function reviewRows(inv: HardwareInventory): ReviewRow[] {
  const order = (d: InventoryDevice) => (d.action === 'Keep' || d.action === 'None' ? 1 : 0);
  return [...inv.devices]
    .sort((a, b) => order(a) - order(b) || a.category.localeCompare(b.category) || a.name.localeCompare(b.name))
    .map((d) => ({
      key: d.key,
      device: d.name || d.instanceId,
      category: DEVICE_CATEGORIES[d.category],
      vendor: d.vendor.name || '—',
      status: STATE_LABELS[d.state],
      action: ACTION_LABELS[d.action],
      confidence: d.confidence,
      reason: d.reasons.join(' '),
      attention: d.action !== 'Keep' && d.action !== 'None',
      setupCritical: d.setupCritical,
      details: {
        hardwareIds: d.hardwareIds,
        compatibleIds: d.compatibleIds,
        driver: d.driver ? `${d.driver.provider} ${d.driver.version}${d.driver.date ? ` (${d.driver.date})` : ''}${d.driver.inbox ? ' · Windows inbox driver' : ''}` : 'No driver',
        inf: d.driver?.inf ?? '',
        problemCode: d.problemCode,
        instanceId: d.instanceId,
        oemCustomized: d.oemCustomized,
      },
    }));
}

// ------------------------------------------------------------------------------------------------
// Verified packages (technician-entered metadata)
// ------------------------------------------------------------------------------------------------

export function verifiedPackageProblems(v: VerifiedPackage): string[] {
  const out: string[] = [];
  if (!allowedDownloadUrl(v.url)) out.push(`${v.name || v.id}: the URL must be HTTPS on an official host (${DRIVER_SOURCE_DATA.downloadHosts.join(', ')}).`);
  if (!/\.(cab|zip)(\?|$)/i.test(new URL(v.url, 'https://x.invalid').pathname) && allowedDownloadUrl(v.url)) out.push(`${v.name || v.id}: only INF driver packages in a .cab or .zip are downloaded; installer programs (.exe) are never run.`);
  if (!SHA256_UPPER.test(v.sha256)) out.push(`${v.name || v.id}: the SHA-256 must be 64 hexadecimal characters.`);
  for (const h of v.hardwareIds) if (!HARDWARE_ID.test(h)) out.push(`${v.name || v.id}: "${h}" is not a hardware ID.`);
  return out;
}

// ------------------------------------------------------------------------------------------------
// The technician tool download (inventory and bundles on an existing computer)
// ------------------------------------------------------------------------------------------------

const INSPECT_CMD = `@echo off
rem Windows Deployment Builder - hardware inventory (read-only). Writes hardware-inventory.json
rem next to this file; import it under Hardware & Drivers in the website.
"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0${DRIVER_ENGINE_FILE}" -Mode Inspect -OutputPath "%~dp0hardware-inventory.json"
pause
`;

export function driverToolReadme(): string {
  return `Windows Deployment Builder - hardware & driver tool ${DRIVER_ENGINE_VERSION}
====================================================

Runs on a Windows 10/11 computer with Windows PowerShell 5.1 (included). Nothing is uploaded and,
apart from the bundle you ask it to write, nothing on the computer is changed.

  Inspect-Hardware.cmd
      Read-only inventory of this computer's hardware and drivers -> hardware-inventory.json.
      Import it under Hardware & Drivers to review it before you prepare a deployment. The file
      contains no serial numbers, UUIDs, MAC addresses, user or computer names.

  .\\${DRIVER_ENGINE_FILE} -Mode Export -OutputPath E:\\WindowsDeployment\\drivers      (administrator)
      Copies this computer's third-party driver packages (pnputil /export-driver) into a
      verified offline bundle WDB-Drivers-<date>-<id>. Driver packages only: vendor control
      panels and utilities are not part of the driver store and are not exported.

  .\\${DRIVER_ENGINE_FILE} -Mode Bundle -Path <folder with INF drivers> -OutputPath <folder>
      Builds a bundle from INF driver packages you downloaded from the manufacturer (extracted,
      .inf + .sys + .cat). Unsigned packages are refused; installer programs are ignored.

  .\\${DRIVER_ENGINE_FILE} -Mode ValidateBundle -Path <bundle folder> [-ExpectedSha256 <hash>]

Attach the bundle's drivers-manifest.json under Hardware & Drivers: the deployment then accepts
only that exact bundle. Storage controller drivers in it can be placed in $WinPEDriver$ on the
USB drive by the USB Preparation Assistant, so Windows Setup can see the disk.

A bundle from one computer fits only computers with the same hardware. The deployment checks
every package against the target computer's hardware IDs before using it.

Status: tested with simulated hardware only.
`;
}

export function driverToolFiles(): { path: string; content: string }[] {
  return [
    { path: DRIVER_ENGINE_FILE, content: crlf(engineSource) },
    { path: DRIVER_SOURCES_FILE, content: crlf(JSON.stringify(DRIVER_SOURCE_DATA, null, 2) + '\n') },
    { path: 'Inspect-Hardware.cmd', content: crlf(INSPECT_CMD) },
    { path: 'README-Hardware-Driver-Tool.txt', content: crlf(driverToolReadme()) },
  ];
}

const withBom = (path: string, content: string): Uint8Array => {
  const body = utf8(content);
  if (!path.endsWith('.ps1')) return body;
  const out = new Uint8Array(body.length + 3);
  out.set([0xef, 0xbb, 0xbf]);
  out.set(body, 3);
  return out;
};

export function driverToolBundle(): Uint8Array {
  return createZip(driverToolFiles().map((f) => ({ path: `hardware-driver-tool/${f.path}`, data: withBom(f.path, f.content) })));
}

// ------------------------------------------------------------------------------------------------
// Installation media (Phase 7 assistant)
// ------------------------------------------------------------------------------------------------

/**
 * The manifest's media › drivers block: the pinned bundle the USB drive should carry and the
 * Setup-critical packages the assistant copies to $WinPEDriver$ (documented Windows Setup
 * behaviour: Setup loads INF drivers found there and stages them into the installed Windows). Only
 * the packages this deployment pinned; nothing hardware-specific goes onto every customer's USB.
 */
export function driverMediaBlock(p: Profile) {
  const d = p.drivers;
  if (!d.enabled || !d.includeOfflinePackages || !d.bundle) return null;
  const critical = d.bundle.packages.filter((x) => x.setupCritical);
  return {
    bundle: { bundleId: d.bundle.bundleId, folderName: d.bundle.folderName, manifestSha256: d.bundle.manifestSha256, location: `${MEDIA_DRIVERS_DIR}/${d.bundle.folderName}` },
    setupCritical: critical.length ? { packages: critical.map((x) => x.id), location: `${MEDIA_WINPE_DRIVERS_DIR}/${d.bundle.folderName}` } : null,
    /** A Setup-critical driver must be on the media; the rest of the bundle is recommended. */
    required: critical.length > 0,
  };
}
