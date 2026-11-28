import type { AppProfile, ApplicationsSelection, Devices, PackageRef } from '../schema/applications';
import { builtinProfile, builtinProfiles, deviceProfiles, isBuiltinProfile, revisionOf, type ProfileRevision } from './builtin';
import { CONFLICT_GROUPS, OVERLAP_GROUPS, catalogEntryForKey, catalogRef, entryForFormerKey, entryKey, exclusionFor, isManual, methodOf, removalForCatalogId, type CatalogEntry, type ConflictGroup, type ExcludedApp, type InstallMethod } from './catalog';
import { CATALOG_SOURCE, packageKey, unresolvedReason } from './ids';

/**
 * Combines the selected application profiles, the device recommendations and individual
 * additions/removals into one ordered, de-duplicated installation queue. Identity is source +
 * PackageIdentifier (case-insensitive), never the display name.
 *
 * Deterministic rules (docs/phase-4-2-application-profiles/profiles.md):
 *   selected = defaults of every active profile (ticked profiles, the profiles they inherit, and
 *              the device profiles the device answers activate)
 *            ∪ individual additions
 *            ∪ dependencies of the above (catalog `requires`)
 *            − individual removals − exclusions saved in active custom profiles (unless added)
 *   recommended = optional apps of the active profiles that are not selected.
 * Ticking or unticking a profile never edits the user's own additions or `removed`, so a deliberate
 * change survives profile switches; only the explicit reset actions clear them. A recommendation
 * ticked while its profile is active is linked to that profile (`addedWith`) and leaves with it.
 */

export type Resolution = 'verified' | 'unverified' | 'unresolved' | 'manual';
export type Interaction = 'silent' | 'mayPrompt' | 'required' | 'unknown';

export interface PlannedPackage {
  key: string;
  ref: PackageRef;
  displayName: string;
  catalog?: CatalogEntry;
  /** Profile ids the package came from, "added" for individual additions, "required" for dependencies. */
  origins: string[];
  /** Keys of selected packages that need this one. */
  requiredBy: string[];
  resolution: Resolution;
  /** Why the package cannot be installed (resolution "unresolved"). */
  reason?: string;
  method: InstallMethod;
  interaction: Interaction;
  accountSignIn: boolean;
  reboot: 'none' | 'mayRequire' | 'unknown';
  /** Keys in this queue that must be installed first. */
  after: string[];
  /** Set for removed packages: "user", or the id of the custom profile that excludes it. */
  removedBy?: string;
  /** The package is deliberately not in the curated catalog (added by custom ID). */
  excludedFromCatalog?: ExcludedApp;
}

export interface Notice {
  key: string;
  kind: 'error' | 'warning' | 'info';
  message: string;
}

export interface SelectionResult {
  /** Install order: installable packages first (dependency-ordered), then manual and unresolved ones. */
  packages: PlannedPackage[];
  /** Packages the profiles contribute but the user (or a saved profile's exclusions) removed. */
  removed: PlannedPackage[];
  /** Optional apps of the active profiles that are not selected. */
  recommended: PlannedPackage[];
  duplicates: { key: string; displayName: string; origins: string[] }[];
  conflicts: { key: string; message: string }[];
  /** More than one selected app of a mutually exclusive group (blocks generation). */
  groupConflicts: { group: ConflictGroup; keys: string[]; message: string }[];
  /** Selection warnings, dependency warnings and notes about excluded apps. */
  notices: Notice[];
  missingProfiles: string[];
  cycles: string[];
  /** Ticked profiles plus the device profiles, in order, de-duplicated. */
  activeProfiles: string[];
  deviceProfiles: string[];
}

export const ADDED = 'added';
export const REQUIRED = 'required';

/** The built-in profile revision a selection uses (absent = 1, the definitions before the 2026-11-26 rebuild). */
export const selectionRevision = (sel: Pick<ApplicationsSelection, 'profileRevision'>): ProfileRevision => revisionOf(sel.profileRevision);

/** Separator of the internal ids of a built-in profile pinned to another revision ("core~1"). */
export const PINNED = '~';

/**
 * Built-in profiles of the selection's revision, then the custom profiles of this selection (a custom
 * one never shadows a built-in id). A custom profile saved with another revision keeps resolving its
 * parents in that revision: they are added as pinned copies ("core~1", named "… (earlier defaults)"),
 * so a saved profile never changes because the built-in defaults did.
 */
export function allProfiles(sel: Pick<ApplicationsSelection, 'profiles' | 'profileRevision'>): AppProfile[] {
  const rev = selectionRevision(sel);
  const pinned = new Map<string, AppProfile>();
  const pin = (id: string, r: ProfileRevision): string => {
    const b = builtinProfile(id, r);
    if (r === rev || !b) return id;
    const pid = `${id}${PINNED}${r}`;
    if (!pinned.has(pid)) {
      pinned.set(pid, b);
      pinned.set(pid, { ...b, id: pid, name: `${b.name} (${r < rev ? 'earlier' : 'new'} defaults)`, inherits: b.inherits.map((i) => pin(i, r)) });
    }
    return pid;
  };
  const custom = sel.profiles
    .filter((p) => !isBuiltinProfile(p.id))
    .map((p) => {
      const r = revisionOf(p.builtinRevision);
      return r === rev || !p.inherits.some(isBuiltinProfile) ? p : { ...p, inherits: p.inherits.map((i) => (isBuiltinProfile(i) ? pin(i, r) : i)) };
    });
  return [...builtinProfiles(rev), ...custom, ...pinned.values()];
}

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

/** The profile and every profile it inherits, without repetition. */
function closure(id: string, profiles: readonly AppProfile[], seen = new Set<string>()): string[] {
  if (seen.has(id)) return [];
  seen.add(id);
  const p = profiles.find((x) => x.id === id);
  if (!p) return [];
  return [...p.inherits.flatMap((i) => closure(i, profiles, seen)), id];
}

/** The deployment's device answers combined with those saved in its ticked custom profiles. */
export function effectiveDevices(sel: Pick<ApplicationsSelection, 'devices' | 'selectedProfiles' | 'profiles'>): Devices {
  const d: Devices = { ...sel.devices };
  for (const id of sel.selectedProfiles) {
    const saved = sel.profiles.find((p) => p.id === id)?.devices;
    if (!saved) continue;
    if (d.phone === 'none') d.phone = saved.phone;
    d.ipad ||= saved.ipad;
    d.extraIphone ||= saved.extraIphone;
    d.androidTablet ||= saved.androidTablet;
  }
  return d;
}

/** Every profile active in this selection: the ticked ones, the device profiles and everything they inherit. */
export function activeClosure(sel: ApplicationsSelection): string[] {
  const profiles = allProfiles(sel);
  const ids = [...sel.selectedProfiles.filter((id) => profiles.some((p) => p.id === id)), ...deviceProfiles(effectiveDevices(sel))];
  return [...new Set(ids.flatMap((id) => closure(id, profiles)))];
}

/**
 * The individual additions that count: the user's own, and recommendations ticked while a profile
 * that recommends them is still active. A recommendation goes with its profiles, so unticking the
 * last of them removes it (`pruneDetached` then forgets it).
 */
export function attachedAdditions(sel: ApplicationsSelection, active: readonly string[] = activeClosure(sel)): PackageRef[] {
  const linked = sel.addedWith ?? {};
  return sel.added.filter((ref) => {
    const via = linked[packageKey(ref)];
    return !via || via.some((id) => active.includes(id));
  });
}

function plan(key: string, input: PackageRef, origin: string): PlannedPackage {
  const catalog = catalogEntryForKey(key);
  const isCatalogRef = input.source.toLowerCase() === CATALOG_SOURCE;
  // A former catalog entry removed because it cannot be installed and verified unattended: the saved
  // reference stays (for diagnostics and so the technician can remove or replace it), nothing is installed.
  const removal = catalog ? undefined : isCatalogRef ? removalForCatalogId(input.packageIdentifier) : exclusionFor(input)?.removed ? exclusionFor(input) : undefined;
  const reason =
    unresolvedReason(input) ??
    (removal
      ? `${removal.name} was removed from the automated catalog on ${removal.removed!.date}: ${removal.reason} It stays in this profile for reference and is not installed; remove it or choose another application.`
      : isCatalogRef && !catalog
        ? `"${input.packageIdentifier}" is not an entry of this catalog.`
        : undefined);
  const method: InstallMethod = catalog ? methodOf(catalog) : input.source.toLowerCase() === 'msstore' ? 'msstore' : 'winget';
  // Portable packages are always installed machine-wide (protected folder, shortcut for all users).
  const ref = method === 'portable' ? { ...input, scope: 'machine' as const } : input;
  const manual = !!catalog && isManual(catalog);
  return {
    key,
    ref,
    displayName: catalog?.displayName ?? (ref.displayName || ref.packageIdentifier),
    catalog,
    origins: [origin],
    requiredBy: [],
    resolution: reason ? 'unresolved' : manual ? 'manual' : catalog?.validation.status === 'verified' ? 'verified' : 'unverified',
    reason,
    method,
    interaction: manual ? 'required' : (catalog?.interaction ?? 'unknown'),
    accountSignIn: catalog?.accountSignIn ?? false,
    reboot: catalog?.reboot ?? 'unknown',
    after: [],
    excludedFromCatalog: catalog ? undefined : (removal ?? exclusionFor(ref)),
  };
}

const describe = (r: PackageRef) => `${r.version ? `version ${r.version}` : 'latest version'}, ${r.scope ? `${r.scope} scope` : 'default scope'}`;

/**
 * Catalog audit 2026-11: a selection saved before an entry moved to another source (or became a manual
 * entry) names it by its former key. Additions, deselections, links and custom profiles are rewritten
 * to the entry's current key, and each rewrite is reported (never a silent substitution).
 */
export function canonicalSelection(sel: ApplicationsSelection): { sel: ApplicationsSelection; moved: Notice[] } {
  const moved = new Map<string, Notice>();
  const note = (oldKey: string) => {
    const e = entryForFormerKey(oldKey);
    if (!e) return undefined;
    const key = entryKey(e)!;
    if (!moved.has(key)) {
      moved.set(key, {
        key,
        kind: 'info',
        message: `${e.displayName} was saved as ${oldKey}; it is now ${isManual(e) ? 'a manual installation (WDB cannot install it unattended)' : `installed from ${e.source === 'msstore' ? 'the Microsoft Store' : 'WinGet'} as ${e.packageIdentifier}`}${e.notes ? ` (${e.notes})` : ''}. The same application, not a replacement.`,
      });
    }
    return e;
  };
  const ref = (r: PackageRef): PackageRef => {
    const e = note(packageKey(r));
    return e ? { ...catalogRef(e)!, scope: isManual(e) ? '' : r.scope } : r;
  };
  const key = (k: string): string => {
    const e = note(k);
    return e ? entryKey(e)! : k;
  };
  const next: ApplicationsSelection = {
    ...sel,
    added: sel.added.map(ref),
    removed: sel.removed.map(key),
    ...(sel.addedWith ? { addedWith: Object.fromEntries(Object.entries(sel.addedWith).map(([k, v]) => [key(k), v])) } : {}),
    profiles: sel.profiles.map((p) => ({
      ...p,
      packages: p.packages.map(ref),
      ...(p.optional ? { optional: p.optional.map(ref) } : {}),
      ...(p.excluded ? { excluded: p.excluded.map(key) } : {}),
    })),
  };
  return moved.size ? { sel: next, moved: [...moved.values()] } : { sel, moved: [] };
}

export function resolveSelection(input: ApplicationsSelection): SelectionResult {
  const { sel, moved } = canonicalSelection(input);
  const profiles = allProfiles(sel);
  const cycles: string[] = [];
  const missingProfiles = sel.selectedProfiles.filter((id) => !profiles.some((p) => p.id === id));
  const devices = deviceProfiles(effectiveDevices(sel));
  const activeProfiles = [...new Set([...sel.selectedProfiles.filter((id) => !missingProfiles.includes(id)), ...devices])];
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
    if (existing.ref.version !== ref.version || (existing.method !== 'portable' && existing.ref.scope !== ref.scope)) {
      const explicit = origin === ADDED;
      conflicts.push({
        key,
        message: `${existing.displayName}: ${explicit ? 'the individual addition' : `profile "${origin}"`} asks for ${describe(ref)}, but it is already selected with ${describe(existing.ref)}. ${explicit ? 'The individual addition wins.' : 'The first one wins.'}`,
      });
      if (explicit) existing.ref = plan(key, ref, origin).ref;
    }
  };

  for (const id of activeProfiles) for (const ref of expandProfile(id, profiles, cycles)) take(ref, id);
  const active = [...new Set(activeProfiles.flatMap((id) => closure(id, profiles)))];
  const added = attachedAdditions(sel, active);
  for (const ref of added) take(ref, ADDED);

  // Removals: the user's, plus exclusions saved in active custom profiles (an explicit addition beats those).
  const addedKeys = new Set(added.map(packageKey));
  const removedBy = new Map<string, string>();
  for (const id of active) for (const k of profiles.find((p) => p.id === id)?.excluded ?? []) if (!addedKeys.has(k.toLowerCase())) removedBy.set(k.toLowerCase(), id);
  for (const k of sel.removed) removedBy.set(k.toLowerCase(), 'user');

  const notices: Notice[] = [...moved];
  // Dependencies of selected packages join the plan (unless removed, which is reported).
  for (let changed = true; changed; ) {
    changed = false;
    for (const p of [...byKey.values()]) {
      if (removedBy.has(p.key)) continue;
      for (const dep of p.catalog?.requires ?? []) {
        const depEntry = catalogEntryForKey(dep);
        const existing = byKey.get(dep);
        if (existing) {
          if (!existing.requiredBy.includes(p.key)) existing.requiredBy.push(p.key);
          if (removedBy.has(dep) && !notices.some((n) => n.key === p.key && n.message.includes(existing.displayName))) {
            notices.push({ key: p.key, kind: 'warning', message: `${p.displayName} needs ${existing.displayName}, which is deselected. ${p.displayName} is still attempted, but may not work until ${existing.displayName} is installed.` });
          }
          continue;
        }
        if (!depEntry) continue;
        const ref = catalogRef(depEntry);
        if (!ref) continue;
        take(ref, REQUIRED);
        byKey.get(dep)!.requiredBy.push(p.key);
        if (removedBy.has(dep)) notices.push({ key: p.key, kind: 'warning', message: `${p.displayName} needs ${depEntry.displayName}, which is deselected. ${p.displayName} is still attempted, but may not work until ${depEntry.displayName} is installed.` });
        changed = true;
      }
    }
  }

  const all = [...byKey.values()];
  const kept = all.filter((p) => !removedBy.has(p.key));
  const removed = all.filter((p) => removedBy.has(p.key)).map((p) => ({ ...p, removedBy: removedBy.get(p.key) }));
  const duplicates = kept.filter((p) => p.origins.filter((o) => o !== REQUIRED).length > 1).map((p) => ({ key: p.key, displayName: p.displayName, origins: p.origins }));

  const keptKeys = new Set(kept.map((p) => p.key));
  for (const p of kept) p.after = (p.catalog?.requires ?? []).filter((k) => keptKeys.has(k) && k !== p.key);

  // Recommendations of the active profiles that are not selected.
  const recommended = new Map<string, PlannedPackage>();
  for (const id of active) {
    for (const ref of profiles.find((p) => p.id === id)?.optional ?? []) {
      const key = packageKey(ref);
      if (keptKeys.has(key) || removedBy.has(key)) continue;
      const r = recommended.get(key);
      if (r) {
        if (!r.origins.includes(id)) r.origins.push(id);
      } else recommended.set(key, plan(key, ref, id));
    }
  }

  // Mutually exclusive groups (real-time antivirus) and per-app warnings.
  const groupConflicts: SelectionResult['groupConflicts'] = [];
  for (const group of Object.keys(CONFLICT_GROUPS) as ConflictGroup[]) {
    const members = kept.filter((p) => p.catalog?.conflictGroup === group);
    if (members.length > 1) {
      groupConflicts.push({
        group,
        keys: members.map((p) => p.key),
        message: `${members.map((p) => p.displayName).join(' and ')} are both real-time antivirus products. Running two real-time scanners causes conflicts, slowdowns and failed scans: keep only one.`,
      });
    }
  }
  for (const p of kept) {
    if (p.catalog?.selectionWarning) notices.push({ key: p.key, kind: 'warning', message: `${p.displayName}: ${p.catalog.selectionWarning}` });
    if (p.excludedFromCatalog?.removed) notices.push({ key: p.key, kind: 'warning', message: p.reason ?? `${p.displayName} was removed from the automated catalog.` });
    else if (p.excludedFromCatalog) notices.push({ key: p.key, kind: 'info', message: `${p.displayName} is not in the curated catalog (${p.excludedFromCatalog.reason}). It is installed by its exact identifier because you added it.` });
  }
  // Overlapping tools (two remote-support tools, two PDF readers…): allowed when deliberate, but said.
  for (const g of Object.values(OVERLAP_GROUPS) as { label: string; ids: readonly string[] }[]) {
    const members = kept.filter((p) => !!p.catalog && g.ids.includes(p.catalog.id));
    if (members.length > 1) notices.push({ key: members[0]!.key, kind: 'info', message: `${members.map((p) => p.displayName).join(' and ')} are all ${g.label}. That is fine when it is deliberate; keep only one if the user needs just one.` });
  }
  const antivirus = kept.filter((p) => p.catalog?.conflictGroup === 'realtime-antivirus');
  const malwarebytes = kept.find((p) => p.catalog?.id === 'malwarebytes');
  if (malwarebytes && antivirus.length) {
    notices.push({ key: malwarebytes.key, kind: 'warning', message: `Malwarebytes and ${antivirus.map((p) => p.displayName).join(', ')} are both selected. As an on-demand scanner Malwarebytes can run alongside ${antivirus[0]!.displayName}, but a Premium trial or licence turns on real-time protection, which overlaps with it: after installation, check Malwarebytes' Real-Time Protection settings, or keep only one real-time product.` });
  }

  return {
    packages: order(kept),
    removed,
    recommended: [...recommended.values()],
    duplicates,
    conflicts,
    groupConflicts,
    notices,
    missingProfiles,
    cycles: [...new Set(cycles)],
    activeProfiles,
    deviceProfiles: devices,
  };
}

/**
 * Stable topological order over `after`, installable first; packages that need interaction are
 * placed after unattended ones, manual follow-ups and unresolved packages last. Dependency cycles
 * keep their input order.
 */
function order(items: PlannedPackage[]): PlannedPackage[] {
  const rank = (p: PlannedPackage) => (p.resolution === 'unresolved' ? 3 : p.resolution === 'manual' ? 2 : p.interaction === 'required' ? 1 : 0);
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

/** The packages the engine can attempt with WinGet (everything except unresolved and manual ones). */
export const installable = (r: SelectionResult): PlannedPackage[] => r.packages.filter((p) => p.resolution !== 'unresolved' && p.resolution !== 'manual');

/** Selected catalog entries without an unattended installation (manual follow-up). */
export const manualItems = (r: SelectionResult): PlannedPackage[] => r.packages.filter((p) => p.resolution === 'manual');
