import { z } from 'zod';
import { APP_PROFILE_ID, AppProfileSchema, NO_DEVICES, type AppProfile, type ApplicationsSelection, type PackageRef } from '../schema/applications';
import { BUILTIN_PROFILES, UNIVERSAL_PROFILES, isBuiltinProfile } from './builtin';
import { CATALOG_SOURCE, isKnownSource, packageKey, unresolvedReason } from './ids';
import { ADDED, activeClosure, allProfiles, effectiveDevices, expandProfile, resolveSelection } from './selection';
import { importWinGetDocument, looksLikeWinGetDocument, MAX_IMPORT_BYTES } from './winget-json';

/**
 * The internal application-profile file format (docs/phase-3/profile-format.md, extended in
 * docs/phase-4-2-application-profiles/profiles.md) and the profile operations used by the UI.
 * Unlike Microsoft's package list, it carries display names, categories, descriptions,
 * inheritance, exclusions and device answers. It never contains credentials: the schema is strict,
 * so unknown members (a "password", a token) are rejected rather than carried along.
 */

export const APP_PROFILE_FORMAT = 'windows-deployment-builder/app-profiles';
/** 2 (Phase 4.2) adds optional, excluded, devices and timestamps. Version 1 files still import. */
export const APP_PROFILE_FORMAT_VERSION = 2;

const FileSchema = z
  .object({
    format: z.literal(APP_PROFILE_FORMAT),
    formatVersion: z.union([z.literal(1), z.literal(APP_PROFILE_FORMAT_VERSION)]),
    exportedUtc: z.string().max(40).optional(),
    profiles: z.array(AppProfileSchema).min(1).max(50),
  })
  .strict();

/** A package key as stored in `removed`/`excluded`: "source:identifier", lower case, no unsafe characters. */
const KEY = /^[a-z0-9][a-z0-9._-]{0,63}:[a-z0-9][a-z0-9._+-]{0,127}$/;

/** `now` = null leaves out the timestamp (for reproducible deployment assets). */
export function exportAppProfiles(profiles: readonly AppProfile[], now: Date | null = new Date()): string {
  return JSON.stringify({ format: APP_PROFILE_FORMAT, formatVersion: APP_PROFILE_FORMAT_VERSION, ...(now ? { exportedUtc: now.toISOString() } : {}), profiles }, null, 2) + '\n';
}

export interface ProfileImportResult {
  ok: boolean;
  kind?: 'app-profiles' | 'winget';
  errors: string[];
  warnings: string[];
  /** New profiles to add. Existing profiles and selections are never modified by an import. */
  profiles: AppProfile[];
}

function uniqueId(base: string, taken: Set<string>): string {
  const clean = base.toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || 'profile';
  let id = clean;
  for (let n = 2; taken.has(id); n++) id = `${clean.slice(0, 40)}-${n}`;
  taken.add(id);
  return id;
}

function uniqueName(base: string, taken: Set<string>): string {
  let name = base.slice(0, 80);
  for (let n = 2; taken.has(name.toLowerCase()); n++) name = `${base.slice(0, 70)} (${n})`;
  taken.add(name.toLowerCase());
  return name;
}

/** Drops invalid packages for known sources and duplicate keys inside one list. */
function cleanPackages(packages: readonly PackageRef[], label: string, warnings: string[]): PackageRef[] {
  const seen = new Set<string>();
  const out: PackageRef[] = [];
  for (const p of packages) {
    const lower = p.source.toLowerCase();
    const ref = { ...p, source: isKnownSource(lower) || lower === CATALOG_SOURCE ? lower : p.source };
    const reason = unresolvedReason(ref);
    if (reason && (isKnownSource(ref.source) || ref.source === CATALOG_SOURCE)) {
      warnings.push(`${label}: skipped ${p.packageIdentifier.slice(0, 60)}: ${reason}`);
      continue;
    }
    if (/[\s"'`$;|&<>]/.test(ref.packageIdentifier)) {
      warnings.push(`${label}: skipped an identifier with characters that are not allowed.`);
      continue;
    }
    const k = packageKey(ref);
    if (seen.has(k)) continue;
    seen.add(k);
    out.push(ref);
  }
  return out;
}

function cleanKeys(keys: readonly string[] | undefined, label: string, warnings: string[]): string[] | undefined {
  if (!keys) return undefined;
  const out = [...new Set(keys.map((k) => k.toLowerCase()))].filter((k) => {
    if (KEY.test(k)) return true;
    warnings.push(`${label}: skipped an exclusion that is not a package key.`);
    return false;
  });
  return out;
}

/** Validates one stored or imported custom profile: built-in flag cleared, packages and keys cleaned. */
function cleanProfile(p: AppProfile, warnings: string[]): AppProfile {
  const out: AppProfile = { ...p, builtin: false, packages: cleanPackages(p.packages, p.name, warnings) };
  if (p.optional) out.optional = cleanPackages(p.optional, p.name, warnings);
  const excluded = cleanKeys(p.excluded, p.name, warnings);
  if (excluded) out.excluded = excluded;
  return out;
}

function parseFile(text: string): { ok: true; profiles: AppProfile[] } | { ok: false; errors: string[]; raw?: unknown } {
  if (text.length > MAX_IMPORT_BYTES) return { ok: false, errors: ['File is larger than 5 MB.'] };
  let raw: unknown;
  try {
    raw = JSON.parse(text.charCodeAt(0) === 0xfeff ? text.slice(1) : text);
  } catch (e) {
    return { ok: false, errors: [`Not valid JSON: ${(e as Error).message}`] };
  }
  if (looksLikeWinGetDocument(raw)) return { ok: false, errors: [], raw };
  const parsed = FileSchema.safeParse(raw);
  if (!parsed.success) {
    const fmt = typeof raw === 'object' && raw !== null && 'format' in raw ? '' : ' Expected a Windows Deployment Builder application profile file or a WinGet export (with "Sources").';
    return { ok: false, errors: [...parsed.error.issues.slice(0, 12).map((i) => `${i.path.join('.') || '$'}: ${i.message}`), ...(fmt ? [fmt.trim()] : [])] };
  }
  return { ok: true, profiles: parsed.data.profiles };
}

/**
 * Imports either this builder's profile file (format version 1 or 2) or a native WinGet export.
 * Imported profiles become new, unselected custom profiles; ids and names that already exist
 * (including built-in ones) get a suffix.
 */
export function importAppProfiles(text: string, existing: readonly AppProfile[], fileName = 'import'): ProfileImportResult {
  const fail = (errors: string[]): ProfileImportResult => ({ ok: false, errors, warnings: [], profiles: [] });
  const file = parseFile(text);
  const takenIds = new Set([...BUILTIN_PROFILES.map((p) => p.id), ...existing.map((p) => p.id)]);
  const takenNames = new Set([...BUILTIN_PROFILES, ...existing].map((p) => p.name.toLowerCase()));

  if (!file.ok && file.raw !== undefined) {
    const r = importWinGetDocument(file.raw);
    if (!r.ok) return { ok: false, kind: 'winget', errors: r.errors, warnings: [], profiles: [] };
    const warnings = [...r.warnings, ...r.rejected.map((x) => `Skipped ${x.packageIdentifier} (${x.source}): ${x.reason}`)];
    if (r.packages.length === 0) warnings.push('The file contains no importable packages; an empty profile was created.');
    const base = fileName.replace(/\.json$/i, '').slice(0, 60) || 'WinGet list';
    return {
      ok: true,
      kind: 'winget',
      errors: [],
      warnings,
      profiles: [
        {
          id: uniqueId(`imported-${base}`, takenIds),
          name: uniqueName(`Imported: ${base}`, takenNames),
          category: 'custom',
          description: `Imported from a WinGet package list${r.meta.creationDate ? ` created ${r.meta.creationDate.slice(0, 10)}` : ''}${r.meta.winGetVersion ? ` by winget ${r.meta.winGetVersion}` : ''}.`,
          builtin: false,
          inherits: [],
          packages: r.packages,
        },
      ],
    };
  }
  if (!file.ok) return fail(file.errors);

  const warnings: string[] = [];
  const idMap = new Map<string, string>();
  const profiles = file.profiles.map((p) => {
    const id = uniqueId(p.id, takenIds);
    idMap.set(p.id, id);
    if (id !== p.id) warnings.push(`Profile id "${p.id}" already exists; imported as "${id}".`);
    return { ...cleanProfile(p, warnings), id, name: uniqueName(p.name, takenNames) };
  });
  for (const p of profiles) {
    p.inherits = p.inherits.flatMap((i) => {
      const mapped = idMap.get(i) ?? (existing.some((e) => e.id === i) || isBuiltinProfile(i) ? i : undefined);
      if (!mapped) warnings.push(`${p.name}: inherited profile "${i}" is not available and was dropped.`);
      return mapped ? [mapped] : [];
    });
  }
  return { ok: true, kind: 'app-profiles', errors: [], warnings, profiles };
}

// Browser library ---------------------------------------------------------------------------------

export interface LibraryLoad {
  profiles: AppProfile[];
  warnings: string[];
}

/**
 * Reads the custom profiles saved in this browser (the same file format as an export). Unlike an
 * import, ids are kept so a profile stays the same profile across reloads; only a clash with a
 * built-in id or a duplicate is renamed. Invalid data yields a readable warning and no profiles.
 */
export function loadLibrary(text: string | null): LibraryLoad {
  if (!text) return { profiles: [], warnings: [] };
  const file = parseFile(text);
  if (!file.ok) return { profiles: [], warnings: [`Saved profiles in this browser could not be read and were ignored: ${(file.errors[0] ?? 'not an application profile file').slice(0, 200)}`] };
  const warnings: string[] = [];
  const taken = new Set(BUILTIN_PROFILES.map((p) => p.id));
  const profiles = file.profiles.map((p) => {
    const id = taken.has(p.id) ? uniqueId(p.id, taken) : (taken.add(p.id), p.id);
    if (id !== p.id) warnings.push(`Saved profile id "${p.id}" was renamed to "${id}" because it was already used.`);
    return { ...cleanProfile(p, warnings), id };
  });
  for (const p of profiles) p.inherits = p.inherits.filter((i) => isBuiltinProfile(i) || profiles.some((x) => x.id === i));
  return { profiles, warnings };
}

/** Adds library profiles that the selection does not have yet (by id). Returns how many were added. */
export function mergeLibrary(sel: ApplicationsSelection, library: readonly AppProfile[]): number {
  let n = 0;
  for (const p of library) {
    if (sel.profiles.some((x) => x.id === p.id) || isBuiltinProfile(p.id)) continue;
    sel.profiles.push(structuredClone(p));
    n++;
  }
  return n;
}

// Profile operations ------------------------------------------------------------------------------
// All operate on a selection object in place and leave other profiles untouched. Built-in
// profiles are read-only templates: no operation changes them.

const stamp = (now: Date) => now.toISOString();

/** The selected package keys as a set (install order may differ, the apps may not). */
const selectedKeys = (sel: ApplicationsSelection) => resolveSelection(sel).packages.map((x) => x.key).sort().join(' ');

export function createProfile(sel: ApplicationsSelection, name: string, packages: PackageRef[] = [], now = new Date()): AppProfile {
  const taken = new Set(allProfiles(sel).map((p) => p.id));
  const profile: AppProfile = {
    id: uniqueId(name, taken),
    name: uniqueName(name.trim() || 'New profile', new Set(allProfiles(sel).map((p) => p.name.toLowerCase()))),
    category: 'custom',
    description: '',
    builtin: false,
    inherits: [],
    packages: structuredClone(packages),
    createdUtc: stamp(now),
    updatedUtc: stamp(now),
  };
  sel.profiles.push(profile);
  return profile;
}

/**
 * "Save as new profile": the current selection becomes a custom profile (the ticked profiles as
 * parents, the individual additions as its packages, the removals as its exclusions, and the
 * device answers). The deployment then uses that profile alone, which resolves to the same apps.
 */
export function saveAsNewProfile(sel: ApplicationsSelection, name: string, description = '', now = new Date()): AppProfile {
  pruneDetached(sel);
  const before = selectedKeys(sel);
  const p = createProfile(sel, name, sel.added, now);
  p.description = description.trim().slice(0, 500);
  p.inherits = sel.selectedProfiles.filter((id) => id !== p.id).slice(0, 10);
  p.excluded = [...sel.removed];
  p.devices = effectiveDevices(sel);
  sel.selectedProfiles = [p.id];
  sel.added = [];
  sel.removed = [];
  delete sel.addedWith;
  // Defensive: the saved profile must reproduce the selection exactly.
  const after = selectedKeys(sel);
  if (before !== after) throw new Error('Saved profile does not reproduce the selection.');
  return p;
}

/**
 * Updates a custom profile from the current selection. When the profile is ticked, the individual
 * changes are folded into it; otherwise it is replaced by the current selection.
 */
export function updateProfileFromSelection(sel: ApplicationsSelection, id: string, now = new Date()): boolean {
  const p = sel.profiles.find((x) => x.id === id);
  if (!p || p.builtin || isBuiltinProfile(id)) return false;
  pruneDetached(sel);
  const before = selectedKeys(sel);
  const devices = effectiveDevices(sel);
  if (sel.selectedProfiles.includes(id)) {
    const added = new Set(sel.added.map(packageKey));
    p.inherits = [...new Set([...p.inherits, ...sel.selectedProfiles.filter((x) => x !== id)])].slice(0, 10);
    p.packages = [...p.packages.filter((r) => !sel.removed.includes(packageKey(r))), ...sel.added.filter((r) => !p.packages.some((q) => packageKey(q) === packageKey(r)))];
    p.excluded = [...new Set([...(p.excluded ?? []).filter((k) => !added.has(k)), ...sel.removed])];
  } else {
    p.inherits = sel.selectedProfiles.slice(0, 10);
    p.packages = structuredClone(sel.added);
    p.excluded = [...sel.removed];
  }
  p.devices = devices;
  p.updatedUtc = stamp(now);
  sel.selectedProfiles = [id];
  sel.added = [];
  sel.removed = [];
  delete sel.addedWith;
  const after = selectedKeys(sel);
  return before === after;
}

/** Copies any profile (a built-in one becomes an editable custom profile). */
export function duplicateProfile(sel: ApplicationsSelection, id: string, now = new Date()): AppProfile | undefined {
  const src = allProfiles(sel).find((p) => p.id === id);
  if (!src) return undefined;
  const copy = createProfile(sel, `${src.name} copy`, src.packages, now);
  copy.description = src.description;
  copy.inherits = [...src.inherits];
  if (src.optional) copy.optional = structuredClone(src.optional);
  if (src.excluded) copy.excluded = [...src.excluded];
  if (src.devices) copy.devices = { ...src.devices };
  return copy;
}

export function renameProfile(sel: ApplicationsSelection, id: string, name: string, now = new Date()): boolean {
  const p = sel.profiles.find((x) => x.id === id);
  const trimmed = name.trim().slice(0, 80);
  if (!p || p.builtin || isBuiltinProfile(id) || !trimmed) return false;
  p.name = trimmed;
  p.updatedUtc = stamp(now);
  return true;
}

export function describeProfile(sel: ApplicationsSelection, id: string, description: string, now = new Date()): boolean {
  const p = sel.profiles.find((x) => x.id === id);
  if (!p || p.builtin || isBuiltinProfile(id)) return false;
  p.description = description.trim().slice(0, 500);
  p.updatedUtc = stamp(now);
  return true;
}

export function deleteProfile(sel: ApplicationsSelection, id: string): boolean {
  const i = sel.profiles.findIndex((p) => p.id === id);
  if (i < 0 || sel.profiles[i]!.builtin || isBuiltinProfile(id)) return false;
  sel.profiles.splice(i, 1);
  sel.selectedProfiles = sel.selectedProfiles.filter((x) => x !== id);
  for (const p of sel.profiles) p.inherits = p.inherits.filter((x) => x !== id);
  pruneDetached(sel);
  return true;
}

export function toggleProfile(sel: ApplicationsSelection, id: string, on: boolean): void {
  sel.selectedProfiles = on ? [...new Set([...sel.selectedProfiles, id])] : sel.selectedProfiles.filter((x) => x !== id);
  pruneDetached(sel);
}

/**
 * Forgets the recommendations whose profiles are all inactive (after a profile is unticked or a
 * device answer changes): they leave `added`, so re-ticking the profile offers them again unticked.
 * The resolver already ignores them; this keeps the stored selection equal to what is shown.
 */
export function pruneDetached(sel: ApplicationsSelection): void {
  if (!sel.addedWith) return;
  const active = activeClosure(sel);
  const linked: Record<string, string[]> = {};
  const dropped = new Set<string>();
  for (const [key, via] of Object.entries(sel.addedWith)) {
    const still = via.filter((id) => active.includes(id));
    if (still.length) linked[key] = still;
    else dropped.add(key);
  }
  sel.added = sel.added.filter((r) => !dropped.has(packageKey(r)));
  setLinks(sel, linked);
}

function setLinks(sel: ApplicationsSelection, linked: Record<string, string[]>): void {
  const kept = Object.fromEntries(Object.entries(linked).filter(([key]) => sel.added.some((r) => packageKey(r) === key)));
  if (Object.keys(kept).length) sel.addedWith = kept;
  else delete sel.addedWith;
}

const unlink = (sel: ApplicationsSelection, keys: Iterable<string>) => {
  const drop = new Set(keys);
  setLinks(sel, Object.fromEntries(Object.entries(sel.addedWith ?? {}).filter(([key]) => !drop.has(key))));
};

/** Adds a package to a custom profile, or to the individual additions when `target` is "added". */
export function addPackage(sel: ApplicationsSelection, ref: PackageRef, target: string = ADDED): boolean {
  const key = packageKey(ref);
  const list = target === ADDED ? sel.added : sel.profiles.find((p) => p.id === target && !p.builtin)?.packages;
  if (!list) return false;
  sel.removed = sel.removed.filter((k) => k !== key);
  if (list.some((r) => packageKey(r) === key)) return false;
  // Ticking an app that a profile already selects only undoes its removal.
  if (target === ADDED && resolveSelection({ ...sel, added: [], removed: [] }).packages.some((p) => p.key === key)) return true;
  // A recommendation of the active profiles is linked to them, so it leaves when they are unticked.
  const via = target === ADDED ? resolveSelection(sel).recommended.find((p) => p.key === key)?.origins : undefined;
  list.push(structuredClone(ref));
  if (via?.length) setLinks(sel, { ...sel.addedWith, [key]: via });
  return true;
}

/**
 * Removes a package from the combined selection: individual additions are deleted, and packages
 * that come from profiles (or are required by another app) are recorded in `removed`; the profiles
 * themselves stay unchanged.
 */
export function removePackage(sel: ApplicationsSelection, key: string): void {
  sel.added = sel.added.filter((r) => packageKey(r) !== key);
  unlink(sel, [key]);
  const fromProfiles = resolveSelection({ ...sel, removed: [] }).packages.some((p) => p.key === key);
  if (fromProfiles && !sel.removed.includes(key)) sel.removed.push(key);
}

export function restorePackage(sel: ApplicationsSelection, key: string): void {
  sel.removed = sel.removed.filter((k) => k !== key);
}

export function removeFromProfile(sel: ApplicationsSelection, profileId: string, key: string): void {
  const p = sel.profiles.find((x) => x.id === profileId && !x.builtin);
  if (p) p.packages = p.packages.filter((r) => packageKey(r) !== key);
}

/** Undoes the individual changes that concern one profile: its defaults are selected again, its recommendations unticked. */
export function restoreProfileDefaults(sel: ApplicationsSelection, profileId: string): void {
  const profiles = allProfiles(sel);
  const defaults = new Set(expandProfile(profileId, profiles).map(packageKey));
  const optional = new Set((profiles.find((p) => p.id === profileId)?.optional ?? []).map(packageKey));
  sel.removed = sel.removed.filter((k) => !defaults.has(k));
  sel.added = sel.added.filter((r) => !optional.has(packageKey(r)));
  unlink(sel, optional);
}

/** Clears every individual addition and removal (the ticked profiles and devices stay). */
export function resetOverrides(sel: ApplicationsSelection): void {
  sel.added = [];
  sel.removed = [];
  delete sel.addedWith;
}

/** Back to the owner defaults for applications: Core Essentials only, no devices, no changes. Custom profiles are kept. */
export function resetSelection(sel: ApplicationsSelection): void {
  sel.selectedProfiles = [...UNIVERSAL_PROFILES];
  sel.devices = { ...NO_DEVICES };
  resetOverrides(sel);
}

export const isValidProfileId = (id: string) => APP_PROFILE_ID.test(id);
