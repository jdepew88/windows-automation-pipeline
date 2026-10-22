import type { PackageRef } from '../schema/applications';
import { CATALOG, catalogRef, entryKey, exclusionFor, isManual, methodOf, type CatalogEntry, type InstallMethod } from '../applications/catalog';
import { MSSTORE_ID, WINGET_ID, packageKey } from '../applications/ids';
import type { Decision, InventoryApp, Inventory } from './inventory';

/**
 * Phase 6: matching an inventory against the curated catalog. Only an identifier WinGet itself
 * reported (an installed package from the winget or msstore source) is an exact match; a name and
 * publisher that agree with a catalog entry is a strong match; a name alone is only possible and
 * needs a technician's confirmation before it can be installed. Nothing is ever installed because
 * its name merely resembles installed software, and unknown applications stay in the review as
 * manual items or exclusions.
 */

export const CLASSIFICATIONS = {
  catalog: 'In the curated catalog',
  winget: 'Verified WinGet package (outside the catalog)',
  msstore: 'Microsoft Store application',
  portable: 'Supported portable application',
  vendor: 'Verified vendor installer',
  manual: 'Manual installation required',
  unknown: 'Unknown or unsupported',
} as const;
export type Classification = keyof typeof CLASSIFICATIONS;

export const CONFIDENCES = {
  exact: 'Exact identifier reported by WinGet',
  'exact-identity': 'Exact Store package identity (no installable product ID)',
  strong: 'Name and publisher match a catalog entry',
  possible: 'Possible match: confirm before installing',
  none: 'No match',
} as const;
export type Confidence = keyof typeof CONFIDENCES;

export interface MigrationItem {
  /** The inventory id of the main record. */
  id: string;
  app: InventoryApp;
  /** Other inventory records merged into this one (the same package). */
  merged: string[];
  classification: Classification;
  confidence: Confidence;
  catalog?: CatalogEntry;
  /** What would be added to the profile; undefined when nothing can be installed. */
  ref?: PackageRef;
  method: InstallMethod | 'none';
  recommendation: Decision;
  /** Decisions the review offers for this item. */
  allowed: Decision[];
  /** "restore" for a possible match needs an explicit confirmation. */
  needsConfirmation: boolean;
  reasons: string[];
  /** Hidden by default: Windows components and frameworks. */
  system: boolean;
  /** Hardware-specific (Phase 8): never restored automatically. */
  hardware: boolean;
}

export const normalizeName = (name: string): string =>
  name
    .toLowerCase()
    .replace(/[®™©]/g, '')
    .replace(/\((x64|x86|arm64|64-bit|32-bit|[a-z]{2}-[a-z]{2}|user|machine)\)/g, ' ')
    .replace(/\b(x64|x86|arm64|64-bit|32-bit)\b/g, ' ')
    .replace(/\s+v?\d+(\.\d+){1,3}([.-][0-9a-z]+)?\s*$/, ' ')
    .replace(/[^a-z0-9+#]+/g, ' ')
    .trim();

const COMPANY_SUFFIX = /\b(inc|incorporated|llc|ltd|limited|corp|corporation|co|gmbh|ag|sa|bv|pty|plc|the|software|foundation|project|team|community|development)\b/g;
export const normalizePublisher = (p: string): string => p.toLowerCase().replace(/[.,]/g, ' ').replace(COMPANY_SUFFIX, ' ').replace(/[^a-z0-9]+/g, ' ').trim();

interface CatalogName {
  entry: CatalogEntry;
  names: string[];
  publisher: string;
}

/** Names and publisher of each catalog entry, including the ones WinGet reported when it was verified. */
const CATALOG_NAMES: CatalogName[] = CATALOG.map((e) => {
  const m = /:\s(.+?)\s(?:v?\d[\w.+-]*)?,\spublisher\s(.+)$/.exec(e.validation.method);
  const names = [...new Set([e.displayName, m?.[1] ?? ''].filter(Boolean).map(normalizeName).filter(Boolean))];
  return { entry: e, names, publisher: m ? normalizePublisher(m[2]!) : '' };
});

const BY_KEY = new Map(CATALOG.filter((e) => entryKey(e)).map((e) => [entryKey(e), e]));

function publisherAgrees(a: string, b: string): boolean {
  if (!a || !b) return false;
  return a === b || a.startsWith(`${b} `) || b.startsWith(`${a} `) || a.split(' ')[0] === b.split(' ')[0];
}

/** Best catalog candidate by name: exact name (strong with publisher) or a name prefix (possible). */
function nameMatch(app: InventoryApp): { entry: CatalogEntry; confidence: 'strong' | 'possible' } | undefined {
  const n = normalizeName(app.displayName);
  if (!n) return undefined;
  const pub = normalizePublisher(app.publisher);
  let possible: CatalogEntry | undefined;
  for (const c of CATALOG_NAMES) {
    if (c.names.includes(n)) {
      if (publisherAgrees(pub, c.publisher)) return { entry: c.entry, confidence: 'strong' };
      possible ??= c.entry;
      continue;
    }
    // "PuTTY release 0.83" vs "PuTTY": the catalog name followed only by a version is the same name;
    // anything else after it ("Microsoft Teams Meeting Add-in") is at most a possible match.
    const prefix = c.names.find((x) => x.length >= 3 && (n.startsWith(`${x} `) || x.startsWith(`${n} `)));
    if (prefix) {
      const rest = (n.length > prefix.length ? n.slice(prefix.length) : prefix.slice(n.length)).trim();
      if (/^(release|version|build|v)?\s*[\d ]*$/.test(rest) && publisherAgrees(pub, c.publisher)) return { entry: c.entry, confidence: 'strong' };
      possible ??= c.entry;
    }
  }
  return possible ? { entry: possible, confidence: 'possible' } : undefined;
}

const ALL: Decision[] = ['restore', 'optional', 'manual', 'exclude'];

/** Classifies one inventory record. `targetArch` is the deployment's processor architecture. */
export function matchApp(app: InventoryApp, targetArch: 'amd64' | 'arm64' | 'x86' = 'amd64'): MigrationItem {
  const base = { id: app.inventoryId, app, merged: [], hardware: app.hardware, system: app.kind === 'system' || app.kind === 'framework', reasons: [] as string[] };
  const item = (x: Omit<MigrationItem, 'id' | 'app' | 'merged' | 'hardware' | 'system' | 'reasons'> & { reasons?: string[] }): MigrationItem => {
    const out: MigrationItem = { ...base, ...x, reasons: [...base.reasons, ...(x.reasons ?? [])] };
    // Hardware-specific utilities are left to Phase 8 (hardware-aware drivers), never reinstalled automatically.
    if (app.hardware) {
      out.recommendation = 'exclude';
      out.allowed = out.allowed.filter((d) => d === 'exclude' || d === 'manual');
      out.reasons.push('Hardware-specific software: it belongs to the old computer\'s hardware and is handled by the later hardware-aware driver provisioning, not restored here.');
    }
    if (out.system) {
      out.recommendation = 'exclude';
      out.allowed = ['exclude'];
      out.reasons.push('Part of Windows or a framework that other apps bring with them; not selected.');
    }
    return out;
  };
  const archNote = (e?: CatalogEntry) => {
    if (!e || !e.architectures.length) return [];
    if (targetArch === 'arm64' && !e.architectures.includes('arm64')) return [e.architectures.includes('x64') ? 'No Arm64 build: runs under x64 emulation on Arm64.' : 'No build for Arm64 computers is recorded.'];
    return [];
  };
  const src = app.packageSource.toLowerCase();
  // 1. Exact identifiers reported by WinGet.
  if (app.packageIdentifier && (src === 'winget' || src === 'msstore')) {
    const valid = src === 'winget' ? WINGET_ID.test(app.packageIdentifier) : MSSTORE_ID.test(app.packageIdentifier.toUpperCase());
    if (valid) {
      const id = src === 'msstore' ? app.packageIdentifier.toUpperCase() : app.packageIdentifier;
      const key = packageKey({ source: src, packageIdentifier: id });
      const entry = BY_KEY.get(key);
      if (entry) {
        return item({ classification: 'catalog', confidence: 'exact', catalog: entry, ref: catalogRef(entry), method: methodOf(entry), recommendation: 'restore', allowed: ALL, needsConfirmation: false, reasons: [`Same package as the catalog entry "${entry.displayName}".`, ...archNote(entry)] });
      }
      const excluded = exclusionFor({ packageIdentifier: id });
      return item({
        classification: src === 'msstore' ? 'msstore' : 'winget',
        confidence: 'exact',
        ref: { packageIdentifier: id, source: src, displayName: app.displayName.slice(0, 200), version: '', scope: '' },
        method: src === 'msstore' ? 'msstore' : 'winget',
        recommendation: excluded ? 'optional' : 'restore',
        allowed: ALL,
        needsConfirmation: false,
        reasons: [
          `WinGet reported it as installed from the ${src} source, so the identifier is verified; it is added to this profile only, not to the curated catalog.`,
          ...(excluded ? [`Deliberately not in the curated catalog: ${excluded.reason}`] : []),
        ],
      });
    }
    return item({ classification: 'unknown', confidence: 'none', method: 'none', recommendation: 'exclude', allowed: ['manual', 'exclude'], needsConfirmation: false, reasons: [`"${app.packageIdentifier}" is not a valid ${src} identifier.`] });
  }
  if (app.packageIdentifier) {
    return item({ classification: 'unknown', confidence: 'none', method: 'none', recommendation: 'exclude', allowed: ['manual', 'exclude'], needsConfirmation: false, reasons: [`From the WinGet source "${app.packageSource}", which this builder does not install from.`] });
  }
  // 2. Store packages without a product id: the identity is exact, but there is nothing to install by.
  if (app.source === 'appx') {
    return item({
      classification: 'msstore',
      confidence: 'exact-identity',
      method: 'none',
      recommendation: 'manual',
      allowed: ['manual', 'exclude'],
      needsConfirmation: false,
      reasons: [`Microsoft Store / MSIX package ${app.storeIdentity}. WinGet reported no Store product ID for it, so it cannot be installed automatically; reinstall it from the Microsoft Store.`],
    });
  }
  // 3. Names: catalog entries (installable, portable or manual).
  const nm = nameMatch(app);
  if (nm) {
    const e = nm.entry;
    const manual = isManual(e);
    const ref = catalogRef(e);
    const how = manual ? 'manual' : methodOf(e) === 'portable' ? 'portable' : 'catalog';
    const strong = nm.confidence === 'strong';
    return item({
      classification: how as Classification,
      confidence: nm.confidence,
      catalog: e,
      ref,
      method: methodOf(e),
      recommendation: manual ? 'manual' : strong ? 'optional' : 'manual',
      allowed: ALL,
      needsConfirmation: !strong && !manual,
      reasons: [
        strong ? `Name and publisher match "${e.displayName}" in the catalog.` : `The name resembles "${e.displayName}" in the catalog, but the publisher does not confirm it. Confirm the match before it can be installed automatically.`,
        ...(manual ? [`${e.displayName} has no unattended installation: ${e.manual?.instructions ?? ''}`.trim()] : []),
        ...archNote(e),
      ],
    });
  }
  // 4. Unknown: kept for manual review, never guessed.
  const why = app.source === 'portable' ? 'A portable program that is not in the catalog.' : 'Not in the catalog and WinGet did not report a package for it.';
  return item({ classification: 'unknown', confidence: 'none', method: 'none', recommendation: app.kind === 'runtime' ? 'exclude' : 'exclude', allowed: ['manual', 'exclude'], needsConfirmation: false, reasons: [`${why} It cannot be installed automatically; choose "manual" to keep it on the follow-up list.`] });
}

const RANK: Record<Confidence, number> = { exact: 4, 'exact-identity': 3, strong: 2, possible: 1, none: 0 };

/**
 * Matches every application and merges records that resolve to the same package (for example an
 * uninstall record matched by name and the WinGet record of the same catalog entry).
 */
export function matchInventory(inv: Inventory, targetArch: 'amd64' | 'arm64' | 'x86' = 'amd64'): MigrationItem[] {
  const out: MigrationItem[] = [];
  const byKey = new Map<string, MigrationItem>();
  const items = inv.applications.map((a) => matchApp(a, targetArch)).sort((a, b) => RANK[b.confidence] - RANK[a.confidence]);
  for (const it of items) {
    const key = it.ref ? packageKey(it.ref) : '';
    const prev = key ? byKey.get(key) : undefined;
    if (prev) {
      prev.merged.push(it.id);
      if (!prev.reasons.some((r) => r.startsWith('Also found as'))) prev.reasons.push(`Also found as "${it.app.displayName}" (${it.app.source}); listed once.`);
      continue;
    }
    if (key) byKey.set(key, it);
    out.push(it);
  }
  return out.sort((a, b) => a.app.displayName.localeCompare(b.app.displayName));
}

/** Counts per classification (for the review header and the report). */
export function classificationCounts(items: readonly MigrationItem[]): Record<Classification, number> {
  const c = Object.fromEntries(Object.keys(CLASSIFICATIONS).map((k) => [k, 0])) as Record<Classification, number>;
  for (const i of items) if (!i.system) c[i.classification]++;
  return c;
}
