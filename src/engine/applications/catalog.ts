import { z } from 'zod';
import catalogJson from '../../data/apps/catalog.json';
import type { PackageRef } from '../schema/applications';
import { CATALOG_SOURCE, MSSTORE_ID, WINGET_ID, packageKey } from './ids';

/**
 * The application catalog: a manually maintained data file (`src/data/apps/catalog.json`). Listing
 * an app here neither selects nor installs it. Entries can be added or corrected without touching
 * the engine; the file is validated once at load so a broken edit fails loudly.
 *
 * Catalog version 2 (Phase 4.2) adds installation methods (portable, manual), conflict groups,
 * selection warnings and the list of apps deliberately left out of the curated catalog. Entries
 * written for version 1 stay valid: without `method`, an entry installs from its source.
 */

/**
 * What an application does. Profiles (profiles.json) say who gets it: the two are independent, so a
 * category never names a profile and an application is listed once whatever profiles select it.
 */
export const CATALOG_CATEGORIES = {
  browsers: 'Web Browsers',
  communication: 'Communication',
  documents: 'Documents, PDF & Notes',
  books: 'Books & E-readers',
  media: 'Photos & Imaging',
  music: 'Music & Streaming',
  video: 'Media Players & Video',
  creative: 'Audio & Video Production',
  gaming: 'Gaming Platforms & Tools',
  development: 'Developer Tools',
  ai: 'AI Assistants & Local Models',
  virtualization: 'Virtualization',
  networking: 'Network Tools & Diagnostics',
  remote: 'Remote Access & Streaming',
  downloads: 'Downloads & Transfers',
  files: 'Files, Archives & Backup',
  storage: 'Disk & Storage Utilities',
  usb: 'USB & Imaging Tools',
  utilities: 'System Utilities & Diagnostics',
  cloud: 'Cloud & Device Integration',
  security: 'Security, Passwords & VPN',
  peripherals: 'Peripherals, RGB & Device Control',
  runtimes: 'Runtimes',
  hardware: 'Battery & Manufacturer Utilities',
  touch: 'Pen, Touch & Handwriting',
} as const;

/**
 * What kind of software an entry is (Phase 10). Runtimes, system components and drivers are never
 * offered as ordinary recommendations, and the application manager protects them from removal.
 */
export const APP_KINDS = ['application', 'launcher', 'runtime', 'system', 'driver', 'manufacturer', 'service', 'sdk'] as const;
export type AppKind = (typeof APP_KINDS)[number];
/** normal: ordinary removal; caution: an extra confirmation; blocked: never offered for removal. */
export const REMOVAL_SAFETY = ['normal', 'caution', 'blocked'] as const;
export type RemovalSafety = (typeof REMOVAL_SAFETY)[number];
/** winget: `winget upgrade` covers it; explicit: only when named (RequireExplicitUpgrade); manual: no package. */
export const UPGRADE_METHODS = ['winget', 'explicit', 'manual'] as const;
export type CatalogCategory = keyof typeof CATALOG_CATEGORIES;

/**
 * How an entry is installed.
 * - winget / msstore: `winget install --id … --exact --source …`.
 * - portable: a WinGet portable package (WinGet downloads it from the publisher URL in the
 *   community manifest and checks its SHA-256), installed machine-wide, plus a Start menu shortcut.
 * - manual: no reliable unattended installation; reported as a manual follow-up with instructions.
 * - vendor: reserved for reviewed vendor installers (none yet); treated like manual.
 */
export const INSTALL_METHODS = ['winget', 'msstore', 'portable', 'vendor', 'manual'] as const;
export type InstallMethod = (typeof INSTALL_METHODS)[number];

/**
 * Shortcut target and name: plain names only, so a shortcut cannot point outside the package
 * folder. The target is a file-name pattern (`*` allowed) because portable file names carry the
 * version or architecture (rufus-4.15.exe); the engine searches WinGet's package folder for it.
 */
export const PORTABLE_EXE = /^[A-Za-z0-9][A-Za-z0-9._+*-]{0,79}\.exe$/;
export const SHORTCUT_NAME = /^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,59}$/;

export const CONFLICT_GROUPS = {
  'realtime-antivirus': 'Real-time antivirus',
} as const;
export type ConflictGroup = keyof typeof CONFLICT_GROUPS;

/**
 * Tools that do the same job. Unlike a conflict group, selecting several is allowed (a technician may
 * want both TeamViewer and RustDesk), but the plan says so, and built-in profiles never make two of
 * them defaults of profiles that are combined. Catalog ids, checked at load.
 */
export const OVERLAP_GROUPS = {
  'remote-support': { label: 'remote-support tools', ids: ['teamviewer', 'rustdesk', 'anydesk', 'chrome-remote-desktop'] },
  'pdf-reader': { label: 'PDF readers', ids: ['sumatrapdf', 'acrobat-reader'] },
  'office-suite': { label: 'office suites', ids: ['libreoffice', 'onlyoffice'] },
} as const satisfies Record<string, { label: string; ids: readonly string[] }>;
export type OverlapGroup = keyof typeof OVERLAP_GROUPS;

/** A path below one of the roots the engine resolves itself; no other variables, no "..". */
export const VERIFY_FILE = /^%(ProgramFiles|ProgramFiles\(x86\)|ProgramData|LocalAppData|AppData)%(\\[A-Za-z0-9 ._()+-]{1,80}){1,6}$/;
export const VERIFY_REGISTRY_KEY = /^HKLM\\SOFTWARE(\\[A-Za-z0-9 ._+-]{1,80}){1,8}$/;
export const VerifySchema = z
  .object({
    uninstall: z.array(z.string().min(3).max(100)).max(10).optional(),
    appx: z.array(z.string().regex(/^[A-Za-z0-9][A-Za-z0-9.-]{2,99}$/)).max(5).optional(),
    files: z.array(z.string().regex(VERIFY_FILE)).max(5).optional(),
    registry: z
      .array(z.object({ key: z.string().regex(VERIFY_REGISTRY_KEY), name: z.string().regex(/^[A-Za-z0-9 ._-]{1,60}$/), equals: z.string().max(40).optional(), view: z.enum(['64', '32']).default('64') }).strict())
      .max(3)
      .optional(),
    perUser: z.boolean().optional(),
    after: z.enum(['none', 'signIn', 'restart']).optional(),
  })
  .strict();
export type VerifySpec = z.infer<typeof VerifySchema>;

/** The evidence the engine looks for: the catalog's verify block, with detectNames as uninstall names. */
export function verifySpec(e: Pick<CatalogEntry, 'verify' | 'detectNames' | 'scope'> | undefined): VerifySpec {
  if (!e) return {};
  const v: VerifySpec = { ...(e.verify ?? {}) };
  const names = [...(v.uninstall ?? []), ...(e.detectNames ?? [])];
  if (names.length) v.uninstall = [...new Set(names)].slice(0, 10);
  if (v.perUser === undefined && e.scope === 'user') v.perUser = true;
  return v;
}

const CatalogEntrySchema = z
  .object({
    id: z.string().regex(/^[a-z0-9][a-z0-9-]{0,47}$/),
    displayName: z.string().min(1).max(100),
    /** null when there is no verified WinGet/Store package (unresolved or manual entries); such entries are never passed to WinGet. */
    packageIdentifier: z.string().max(128).nullable(),
    /** "none" only for manual entries. */
    source: z.enum(['winget', 'msstore', 'none']),
    /** Defaults to the source for entries written before Phase 4.2. */
    method: z.enum(INSTALL_METHODS).optional(),
    category: z.enum(Object.keys(CATALOG_CATEGORIES) as [CatalogCategory, ...CatalogCategory[]]),
    description: z.string().max(300),
    website: z.string().url().startsWith('https://').optional(),
    /** Architectures with a native installer (x64 apps also run on Arm64 under emulation). Empty = not recorded. */
    architectures: z.array(z.enum(['x64', 'x86', 'arm64'])),
    scope: z.enum(['user', 'machine', 'either', 'unknown']),
    installerType: z.string().max(40),
    license: z.string().max(120),
    /** Package keys ("source:id") this app needs: added to the plan with it and installed first. */
    requires: z.array(z.string().max(200)),
    /** "unknown" = not reviewed. "required" = never attempted unattended. */
    interaction: z.enum(['silent', 'mayPrompt', 'required', 'unknown']),
    /** Needs an account sign-in to be useful (installation itself is unattended). */
    accountSignIn: z.boolean(),
    reboot: z.enum(['none', 'mayRequire', 'unknown']),
    notes: z.string().max(400).optional(),
    /** Shown as a warning whenever the app is selected (for example overlapping real-time protection). */
    selectionWarning: z.string().max(500).optional(),
    /** At most one app of a conflict group can be selected. */
    conflictGroup: z.enum(Object.keys(CONFLICT_GROUPS) as [ConflictGroup, ...ConflictGroup[]]).optional(),
    portable: z.object({ executable: z.string().regex(PORTABLE_EXE), shortcut: z.string().regex(SHORTCUT_NAME) }).strict().optional(),
    manual: z
      .object({ reason: z.string().min(1).max(300), instructions: z.string().min(1).max(400), url: z.string().url().startsWith('https://').optional() })
      .strict()
      .optional(),
    /** Phase 10 metadata (optional, so catalogs written before it stay valid). */
    publisher: z.string().max(120).optional(),
    kind: z.enum(APP_KINDS).optional(),
    removal: z.enum(REMOVAL_SAFETY).optional(),
    upgrade: z.enum(UPGRADE_METHODS).optional(),
    /** Hardware the application is only useful with; the manager shows it, it never installs because of it. */
    hardware: z.object({ requirement: z.string().min(1).max(200), vendors: z.array(z.string().max(40)).max(10) }).strict().optional(),
    /**
     * Package keys ("winget:<id>" / "msstore:<id>", lower case) this entry was saved under before it
     * moved to another source or became manual (catalog audit 2026-11). Saved selections and
     * deselections under a former key mean this entry; the plan says so (never a silent substitution).
     */
    formerKeys: z.array(z.string().regex(/^(winget|msstore):[a-z0-9][a-z0-9.+_-]{0,127}$/)).max(5).optional(),
    /** Other verified WinGet identifiers of the same product (recognised as installed, never installed). */
    alternateIds: z.array(z.string().regex(WINGET_ID)).max(5).optional(),
    /** "Apps & features" names from the package manifest, used to recognise installations made outside WinGet. */
    detectNames: z.array(z.string().max(100)).max(10).optional(),
    /**
     * Package-aware installation evidence (catalog audit 2026-11). The engine and the health audit
     * accept an installation as verified only from one of these, never from the installer's exit code:
     * uninstall: "Apps & features" display-name prefixes (machine, 32-bit and per-user hives);
     * appx: Store/MSIX package names (registered for a user, or provisioned);
     * files: executables under a known root (%ProgramFiles%, %ProgramFiles(x86)%, %ProgramData%,
     *        %LocalAppData% and %AppData% of the deployment user);
     * registry: an exact value (for example the Visual C++ runtime "Installed" = 1 per architecture);
     * perUser: installs into the signed-in user's profile (verified in that user's hive and folders);
     * after: what must happen before the evidence can exist (a sign-in of the user, or a restart).
     */
    verify: VerifySchema.optional(),
    validation: z
      .object({
        status: z.enum(['verified', 'unverified', 'unresolved', 'manual']),
        checkedAt: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
        method: z.string().max(400),
      })
      .strict(),
  })
  .strict()
  .superRefine((e, ctx) => {
    const issue = (message: string) => ctx.addIssue({ code: 'custom', message: `${e.id}: ${message}` });
    const id = e.packageIdentifier;
    const method = methodOf(e);
    if (method === 'manual' || method === 'vendor') {
      if (id !== null || e.source !== 'none') issue('manual entries carry no package identifier and source "none"');
      if (!e.manual) issue('manual entries need "manual" instructions');
      if (e.validation.status !== 'manual') issue('manual entries have validation status "manual"');
      return;
    }
    if (e.manual) issue('"manual" instructions are only for manual entries');
    if (method === 'portable' ? !e.portable || e.source !== 'winget' : e.portable) issue('portable entries are WinGet packages with a "portable" block, and only those');
    if (method === 'msstore' && e.source !== 'msstore') issue('method msstore needs source msstore');
    if (method === 'winget' && e.source !== 'winget') issue('method winget needs source winget');
    if (e.source === 'none') issue('source "none" is only for manual entries');
    if (e.validation.status === 'manual') issue('status "manual" is only for manual entries');
    if (e.validation.status === 'unresolved') {
      if (id !== null) issue('unresolved entries must not carry an identifier');
      return;
    }
    if (id === null) issue('missing packageIdentifier');
    else if (!(e.source === 'winget' ? WINGET_ID : MSSTORE_ID).test(id)) issue(`invalid ${e.source} identifier ${id}`);
  });

export type CatalogEntry = z.infer<typeof CatalogEntrySchema>;

/** Deliberately not in the curated catalog (owner decision). A custom WinGet ID can still add one. */
const ExcludedSchema = z
  .object({
    name: z.string().min(1).max(100),
    packageIdentifier: z.string().max(128).optional(),
    reason: z.string().min(1).max(300),
    /**
     * Set when the app was an automated catalog entry and was taken out because WDB cannot install
     * and verify it unattended. A saved profile that still selects it loads with a compatibility
     * warning and keeps the reference, but the app is never installed and never replaced by another.
     */
    removed: z.object({ date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/), formerId: z.string().regex(/^[a-z0-9][a-z0-9-]{0,47}$/) }).strict().optional(),
  })
  .strict();
export type ExcludedApp = z.infer<typeof ExcludedSchema>;

/** The installation method of an entry (entries from before Phase 4.2 have none: their source). */
export function methodOf(e: Pick<CatalogEntry, 'method' | 'source'>): InstallMethod {
  return e.method ?? (e.source === 'none' ? 'manual' : e.source);
}

/** True for entries the engine reports as a manual follow-up instead of installing. */
export const isManual = (e: Pick<CatalogEntry, 'method' | 'source'>) => methodOf(e) === 'manual' || methodOf(e) === 'vendor';

/** "source:id" for packages, "catalog:<id>" for manual entries, "" for unresolved ones. */
export function entryKey(e: Pick<CatalogEntry, 'id' | 'source' | 'packageIdentifier' | 'method'>): string {
  if (isManual(e)) return packageKey({ source: CATALOG_SOURCE, packageIdentifier: e.id });
  return e.packageIdentifier && e.source !== 'none' ? packageKey({ source: e.source, packageIdentifier: e.packageIdentifier }) : '';
}

const CatalogSchema = z
  .object({
    $comment: z.string().optional(),
    catalogVersion: z.literal(2),
    updated: z.string(),
    entries: z.array(CatalogEntrySchema),
    excluded: z.array(ExcludedSchema),
  })
  .strict()
  .superRefine((c, ctx) => {
    const ids = new Set<string>();
    const keys = new Set<string>();
    for (const e of c.entries) {
      if (ids.has(e.id)) ctx.addIssue({ code: 'custom', message: `duplicate catalog id ${e.id}` });
      ids.add(e.id);
      const k = entryKey(e);
      if (k) {
        if (keys.has(k)) ctx.addIssue({ code: 'custom', message: `duplicate package ${k}` });
        keys.add(k);
      }
    }
    for (const e of c.entries) {
      for (const r of e.requires) if (!keys.has(r)) ctx.addIssue({ code: 'custom', message: `${e.id}: requires ${r}, which is not in the catalog` });
    }
    for (const x of c.excluded) {
      const clash = c.entries.some((e) => e.displayName.toLowerCase() === x.name.toLowerCase() || (!!x.packageIdentifier && e.packageIdentifier?.toLowerCase() === x.packageIdentifier.toLowerCase()));
      if (clash) ctx.addIssue({ code: 'custom', message: `excluded app ${x.name} is also a catalog entry` });
    }
  });

const PARSED = CatalogSchema.parse(catalogJson);
for (const g of Object.values(OVERLAP_GROUPS) as { ids: readonly string[] }[]) {
  for (const id of g.ids) if (!PARSED.entries.some((e) => e.id === id)) throw new Error(`Overlap group refers to unknown catalog id ${id}`);
}
export const CATALOG: readonly CatalogEntry[] = PARSED.entries;
export const CATALOG_EXCLUDED: readonly ExcludedApp[] = PARSED.excluded;
export const CATALOG_UPDATED: string = PARSED.updated;

const BY_KEY = new Map(CATALOG.filter((e) => entryKey(e)).map((e) => [entryKey(e), e]));

export function catalogEntryForKey(key: string): CatalogEntry | undefined {
  return BY_KEY.get(key);
}

const BY_FORMER_KEY = new Map(CATALOG.flatMap((e) => (e.formerKeys ?? []).map((k) => [k, e] as const)));

/** The entry that a key saved before the catalog audit now means (an entry that moved source or became manual). */
export function entryForFormerKey(key: string): CatalogEntry | undefined {
  const k = key.toLowerCase();
  return BY_KEY.has(k) ? undefined : BY_FORMER_KEY.get(k);
}

export function catalogEntryById(id: string): CatalogEntry | undefined {
  return CATALOG.find((e) => e.id === id);
}

/** The reference a catalog entry is selected with; portable packages are always machine-wide. */
export function catalogRef(e: CatalogEntry): PackageRef | undefined {
  const key = entryKey(e);
  if (!key) return undefined;
  const manual = isManual(e);
  return {
    packageIdentifier: manual ? e.id : e.packageIdentifier!,
    source: manual ? CATALOG_SOURCE : e.source,
    displayName: e.displayName,
    version: '',
    scope: methodOf(e) === 'portable' ? 'machine' : '',
  };
}

/** The curated-catalog exclusion matching a package, if any (a custom ID may still add it). */
export function exclusionFor(ref: Pick<PackageRef, 'packageIdentifier'>): ExcludedApp | undefined {
  return CATALOG_EXCLUDED.find((x) => !!x.packageIdentifier && x.packageIdentifier.toLowerCase() === ref.packageIdentifier.toLowerCase());
}

/** The removal record of a former catalog entry, by its old catalog id (a "catalog:<id>" reference). */
export function removalForCatalogId(id: string): ExcludedApp | undefined {
  return CATALOG_EXCLUDED.find((x) => x.removed?.formerId === id.toLowerCase());
}

/** The text a catalog search looks in: name, publisher, description, identifier and category label. */
export const searchText = (e: CatalogEntry): string => `${e.displayName} ${e.publisher ?? ''} ${e.description} ${e.packageIdentifier ?? ''} ${CATALOG_CATEGORIES[e.category]}`.toLowerCase();

/** Case-insensitive search (every word must match) over name, publisher, description, identifier and category label. */
export function searchCatalog(query: string, category: CatalogCategory | '' = ''): CatalogEntry[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  return CATALOG.filter((e) => {
    if (category && e.category !== category) return false;
    const hay = searchText(e);
    return words.every((w) => hay.includes(w));
  });
}
