import type { AppProfile, ApplicationsSelection, PackageRef } from '../schema/applications';
import { catalogEntryForKey, type CatalogEntry } from './catalog';
import { packageKey, unresolvedReason } from './ids';

/**
 * Combines the selected application profiles and individual additions/removals into one ordered,
 * de-duplicated installation queue. Identity is source + PackageIdentifier (case-insensitive),
 * never the display name.
 */

export type Resolution = 'verified' | 'unverified' | 'unresolved';
export type Interaction = 'silent' | 'mayPrompt' | 'required' | 'unknown';

export interface PlannedPackage {
  key: string;
  ref: PackageRef;
  displayName: string;
  catalog?: CatalogEntry;
  /** Profile ids the package came from, plus "added" for individual additions. */
  origins: string[];
  resolution: Resolution;
  /** Why the package cannot be installed (resolution "unresolved"). */
  reason?: string;
  interaction: Interaction;
  accountSignIn: boolean;
  reboot: 'none' | 'mayRequire' | 'unknown';
  /** Keys in this queue that must be installed first. */
  after: string[];
}

export interface SelectionResult {
  /** Install order: installable packages first (dependency-ordered), then unresolved ones. */
  packages: PlannedPackage[];
  /** Packages the profiles contribute but the user removed. */
  removed: PlannedPackage[];
  duplicates: { key: string; displayName: string; origins: string[] }[];
  conflicts: { key: string; message: string }[];
  missingProfiles: string[];
  cycles: string[];
}

export const ADDED = 'added';

/** All packages of a profile including inherited ones, depth-first, with cycle detection. */
export function expandProfile(id: string, profiles: readonly AppProfile[], cycles: string[] = [], stack: string[] = []): PackageRef[] {
  const p = profiles.find((x) => x.id === id);
  if (!p) return [];
  if (stack.includes(id)) {
    cycles.push([...stack, id].join(' → '));
    return [];
  }
  const next = [...stack, id];
  return [...p.inherits.flatMap((i) => expandProfile(i, profiles, cycles, next)), ...p.packages];
}

function plan(key: string, ref: PackageRef, origin: string): PlannedPackage {
  const catalog = catalogEntryForKey(key);
  const reason = unresolvedReason(ref);
  return {
    key,
    ref,
    displayName: catalog?.displayName ?? (ref.displayName || ref.packageIdentifier),
    catalog,
    origins: [origin],
    resolution: reason ? 'unresolved' : catalog?.validation.status === 'verified' ? 'verified' : 'unverified',
    reason,
    interaction: catalog?.interaction ?? 'unknown',
    accountSignIn: catalog?.accountSignIn ?? false,
    reboot: catalog?.reboot ?? 'unknown',
    after: [],
  };
}

const describe = (r: PackageRef) => `${r.version ? `version ${r.version}` : 'latest version'}, ${r.scope ? `${r.scope} scope` : 'default scope'}`;

export function resolveSelection(sel: ApplicationsSelection): SelectionResult {
  const cycles: string[] = [];
  const missingProfiles = sel.selectedProfiles.filter((id) => !sel.profiles.some((p) => p.id === id));
  const byKey = new Map<string, PlannedPackage>();
  const conflicts: SelectionResult['conflicts'] = [];

  const take = (ref: PackageRef, origin: string) => {
    const key = packageKey(ref);
    const existing = byKey.get(key);
    if (!existing) {
      byKey.set(key, plan(key, ref, origin));
      return;
    }
    if (!existing.origins.includes(origin)) existing.origins.push(origin);
    if (existing.ref.version !== ref.version || existing.ref.scope !== ref.scope) {
      const explicit = origin === ADDED;
      conflicts.push({
        key,
        message: `${existing.displayName}: ${origin === ADDED ? 'the individual addition' : `profile "${origin}"`} asks for ${describe(ref)}, but it is already selected with ${describe(existing.ref)}. ${explicit ? 'The individual addition wins.' : 'The first one wins.'}`,
      });
      if (explicit) existing.ref = ref;
    }
  };

  for (const id of [...new Set(sel.selectedProfiles)]) for (const ref of expandProfile(id, sel.profiles, cycles)) take(ref, id);
  for (const ref of sel.added) take(ref, ADDED);

  const removedKeys = new Set(sel.removed.map((k) => k.toLowerCase()));
  const all = [...byKey.values()];
  const kept = all.filter((p) => !removedKeys.has(p.key));
  const removed = all.filter((p) => removedKeys.has(p.key));
  const duplicates = all.filter((p) => p.origins.length > 1).map((p) => ({ key: p.key, displayName: p.displayName, origins: p.origins }));

  const keptKeys = new Set(kept.map((p) => p.key));
  for (const p of kept) p.after = (p.catalog?.requires ?? []).filter((k) => keptKeys.has(k) && k !== p.key);

  return { packages: order(kept), removed, duplicates, conflicts, missingProfiles, cycles: [...new Set(cycles)] };
}

/**
 * Stable topological order over `after`, installable first; packages that need interaction are
 * placed after unattended ones, unresolved packages last. Dependency cycles keep their input order.
 */
function order(items: PlannedPackage[]): PlannedPackage[] {
  const rank = (p: PlannedPackage) => (p.resolution === 'unresolved' ? 2 : p.interaction === 'required' ? 1 : 0);
  const sorted = [...items].sort((a, b) => rank(a) - rank(b));
  const out: PlannedPackage[] = [];
  const done = new Set<string>();
  const visiting = new Set<string>();
  const byKey = new Map(sorted.map((p) => [p.key, p]));
  const visit = (p: PlannedPackage) => {
    if (done.has(p.key) || visiting.has(p.key)) return;
    visiting.add(p.key);
    for (const k of p.after) visit(byKey.get(k)!);
    visiting.delete(p.key);
    done.add(p.key);
    out.push(p);
  };
  sorted.forEach(visit);
  return out;
}

/** The packages the engine can attempt (everything except unresolved ones). */
export const installable = (r: SelectionResult): PlannedPackage[] => r.packages.filter((p) => p.resolution !== 'unresolved');
