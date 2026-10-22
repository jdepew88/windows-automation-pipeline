import { z } from 'zod';

/**
 * Phase 6: the application inventory file written by WdbMigration.ps1 (-Mode Inventory) and read
 * by the website. It is a separate, versioned format: not Microsoft's `winget export` list (which
 * only names packages from a source) and not this builder's application profile (which holds
 * selections, not facts about a computer).
 *
 * The schema is strict: unknown members are rejected, every identifier and path has a pattern or a
 * length limit, and nothing in the file is ever executed or passed to a command line. It holds no
 * secrets and no uninstall commands; the collector replaces user folders by tokens (%APPDATA%).
 */

export const INVENTORY_FORMAT = 'windows-deployment-builder/app-inventory';
export const INVENTORY_FORMAT_VERSION = 1;
export const MAX_INVENTORY_BYTES = 5 * 1024 * 1024;
export const MAX_INVENTORY_APPS = 3000;

export const INVENTORY_ID = /^[0-9a-f]{16}$/;
export const APP_INVENTORY_ID = /^app-[0-9a-f]{12}$/;
export const BACKUP_ID = INVENTORY_ID;
export const SHA256_HEX = /^[0-9A-F]{64}$/;
export const BACKUP_FOLDER = /^[A-Za-z0-9._-]{1,80}$/;
export const ADAPTER_ID = /^[a-z0-9][a-z0-9-]{0,31}$/;
export const EXTENSION_ID = /^[a-z0-9][a-z0-9-]{0,62}\.[a-z0-9][a-z0-9-]{0,62}$/;

// eslint-disable-next-line no-control-regex
const NO_CONTROL = /^[^\u0000-\u001f\u007f]*$/;
const text = (max: number) => z.string().max(max).regex(NO_CONTROL, 'contains control characters');
/** Informational paths: tokenised by the collector, displayed only, never used. */
const InfoPath = text(260).refine((p) => !/(^|[\\/])\.\.([\\/]|$)/.test(p), 'path traversal is not allowed');

export const INVENTORY_SOURCES = ['winget', 'msstore', 'registry', 'appx', 'portable', 'devtool'] as const;
export const APP_KINDS = ['application', 'runtime', 'framework', 'system', 'driver', 'devtool', 'portable'] as const;

export const InventoryAppSchema = z
  .object({
    inventoryId: z.string().regex(APP_INVENTORY_ID),
    displayName: text(300).min(1),
    publisher: text(300),
    version: text(128),
    source: z.enum(INVENTORY_SOURCES),
    packageIdentifier: text(128),
    packageSource: text(64),
    scope: z.enum(['machine', 'user', 'unknown']),
    architecture: z.enum(['x64', 'x86', 'arm64', 'neutral', 'unknown']),
    installLocation: InfoPath,
    detection: z.array(z.enum(INVENTORY_SOURCES)).min(1).max(6),
    kind: z.enum(APP_KINDS),
    hardware: z.boolean(),
    storeIdentity: text(200),
    notes: z.array(text(300)).max(10),
  })
  .strict();
export type InventoryApp = z.infer<typeof InventoryAppSchema>;

const Versions = z.array(text(64)).max(200);

export const DevEnvironmentSchema = z
  .object({
    git: z.object({ installed: z.boolean(), version: text(64), globalConfig: z.boolean() }).strict(),
    vscodeExtensions: z.array(z.object({ id: z.string().regex(EXTENSION_ID), version: text(64) }).strict()).max(1000),
    cursorExtensions: z.array(z.object({ id: z.string().regex(EXTENSION_ID), version: text(64) }).strict()).max(1000),
    powershellModules: z.array(z.object({ name: z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/), versions: Versions, scope: z.enum(['user', 'machine']), repository: text(64) }).strict()).max(1000),
    python: z.array(z.object({ tag: text(64), version: text(64), scope: z.enum(['user', 'machine']) }).strict()).max(100),
    pythonManagers: z.array(z.object({ name: text(64), versions: Versions }).strict()).max(10),
    node: z.object({ version: text(64), managers: z.array(z.object({ name: z.enum(['nvm-windows', 'fnm', 'volta']), versions: Versions }).strict()).max(5) }).strict(),
    docker: z.object({ installed: z.boolean(), settingsPresent: z.boolean() }).strict(),
    claudeCode: z.object({ installed: z.boolean(), method: z.enum(['', 'native', 'winget', 'npm']) }).strict(),
    repositories: z.array(z.object({ name: text(200), root: InfoPath, remote: text(500).refine((r) => !/:\/\/[^/@\s]+@/.test(r), 'remote URLs must not contain credentials') }).strict()).max(2000),
  })
  .strict();
export type DevEnvironment = z.infer<typeof DevEnvironmentSchema>;

export const BackupReferenceSchema = z
  .object({
    backupId: z.string().regex(BACKUP_ID),
    manifestSha256: z.string().regex(SHA256_HEX),
    folderName: z.string().regex(BACKUP_FOLDER),
    createdUtc: text(40),
    adapters: z.array(z.object({ id: z.string().regex(ADAPTER_ID), items: z.number().int().min(0).max(10000), excluded: z.number().int().min(0).max(10000) }).strict()).max(50),
  })
  .strict();
export type BackupReference = z.infer<typeof BackupReferenceSchema>;

export const DECISIONS = ['restore', 'manual', 'optional', 'exclude'] as const;
export type Decision = (typeof DECISIONS)[number];

/** Review decisions, added when the website exports a reviewed inventory. */
export const ReviewSchema = z
  .object({
    reviewedUtc: text(40),
    decisions: z.array(z.object({ inventoryId: z.string().regex(APP_INVENTORY_ID), decision: z.enum(DECISIONS), confirmed: z.boolean() }).strict()).max(MAX_INVENTORY_APPS),
    /** Package mappings and recommendations as computed at review time (informational on import; always recomputed). */
    mappings: z
      .array(z.object({ inventoryId: z.string().regex(APP_INVENTORY_ID), classification: text(32), confidence: text(32), packageKey: text(200), recommendation: z.enum(DECISIONS) }).strict())
      .max(MAX_INVENTORY_APPS),
    unresolved: z.array(z.string().regex(APP_INVENTORY_ID)).max(MAX_INVENTORY_APPS),
  })
  .strict();
export type Review = z.infer<typeof ReviewSchema>;

export const InventorySchema = z
  .object({
    format: z.literal(INVENTORY_FORMAT),
    formatVersion: z.literal(INVENTORY_FORMAT_VERSION),
    inventoryId: z.string().regex(INVENTORY_ID),
    exportedUtc: text(40),
    collector: z.object({ name: text(64), version: text(32), powershell: text(32), wingetMethod: z.enum(['Microsoft.WinGet.Client', 'winget export', 'unavailable', 'skipped']) }).strict(),
    source: z.object({ osName: text(100), osVersion: text(32), osBuild: text(16), displayVersion: text(16), architecture: z.enum(['x64', 'x86', 'arm64', 'unknown']) }).strict(),
    applications: z.array(InventoryAppSchema).max(MAX_INVENTORY_APPS),
    excludedCounts: z.object({ systemComponents: z.number().int().min(0), updates: z.number().int().min(0), frameworks: z.number().int().min(0), resourcePackages: z.number().int().min(0), withoutName: z.number().int().min(0) }).strict(),
    devEnvironment: DevEnvironmentSchema,
    settings: z.array(z.object({ adapterId: z.string().regex(ADAPTER_ID), appDetected: z.boolean(), available: z.boolean(), items: z.number().int().min(0), bytes: z.number().int().min(0), notes: z.array(text(300)).max(10) }).strict()).max(50),
    warnings: z.array(text(500)).max(50),
    backup: BackupReferenceSchema.nullable(),
    review: ReviewSchema.optional(),
  })
  .strict();
export type Inventory = z.infer<typeof InventorySchema>;

export interface InventoryImportResult {
  ok: boolean;
  errors: string[];
  warnings: string[];
  inventory?: Inventory;
}

/**
 * Parses and validates an inventory file. Never throws for bad input. Besides the schema it
 * rejects duplicate inventory ids and decisions for applications that are not in the file.
 */
export function importInventory(textIn: string): InventoryImportResult {
  const fail = (errors: string[]): InventoryImportResult => ({ ok: false, errors, warnings: [] });
  if (textIn.length > MAX_INVENTORY_BYTES) return fail([`File is larger than ${MAX_INVENTORY_BYTES / 1024 / 1024} MB.`]);
  let raw: unknown;
  try {
    raw = JSON.parse(textIn.charCodeAt(0) === 0xfeff ? textIn.slice(1) : textIn);
  } catch (e) {
    return fail([`Not valid JSON: ${(e as Error).message}`]);
  }
  if (typeof raw === 'object' && raw !== null && 'Sources' in raw) return fail(['This is a native "winget export" list, not an application inventory. Import it under Applications › Import JSON, or run WdbMigration.ps1 -Mode Inventory on the source computer.']);
  if (typeof raw === 'object' && raw !== null && (raw as Record<string, unknown>).format === 'windows-deployment-builder/app-backup') return fail(['This is a backup manifest. Import the inventory first, then attach the backup manifest.']);
  if (typeof raw === 'object' && raw !== null && typeof (raw as Record<string, unknown>).formatVersion === 'number' && (raw as Record<string, unknown>).format === INVENTORY_FORMAT && (raw as Record<string, unknown>).formatVersion !== INVENTORY_FORMAT_VERSION) {
    return fail([`Inventory format version ${(raw as Record<string, unknown>).formatVersion} is not supported (this version reads ${INVENTORY_FORMAT_VERSION}).`]);
  }
  const parsed = InventorySchema.safeParse(raw);
  if (!parsed.success) {
    return fail(parsed.error.issues.slice(0, 15).map((i) => `${i.path.join('.') || '$'}: ${i.message}`));
  }
  const inv = parsed.data;
  const ids = new Set<string>();
  for (const a of inv.applications) {
    if (ids.has(a.inventoryId)) return fail([`Duplicate application id ${a.inventoryId}.`]);
    ids.add(a.inventoryId);
  }
  const warnings = [...inv.warnings];
  if (inv.review) {
    const unknown = inv.review.decisions.filter((d) => !ids.has(d.inventoryId));
    if (unknown.length) return fail([`The review refers to ${unknown.length} application(s) that are not in the inventory.`]);
  }
  if (inv.collector.wingetMethod === 'unavailable') warnings.push('WinGet was not available on the source computer: applications could only be matched by name.');
  return { ok: true, errors: [], warnings, inventory: inv };
}
