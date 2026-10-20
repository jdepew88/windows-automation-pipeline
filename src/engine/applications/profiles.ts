import { z } from 'zod';
import { APP_PROFILE_ID, AppProfileSchema, type AppProfile, type ApplicationsSelection, type PackageRef } from '../schema/applications';
import { isKnownSource, packageKey, unresolvedReason } from './ids';
import { ADDED, resolveSelection } from './selection';
import { importWinGetDocument, looksLikeWinGetDocument, MAX_IMPORT_BYTES } from './winget-json';

/**
 * The internal application-profile file format (docs/phase-3/profile-format.md) and the profile
 * operations used by the UI. Unlike Microsoft's package list, it carries display names, categories,
 * descriptions and inheritance. It never contains credentials: the schema is strict, so unknown
 * members (a "password", a token) are rejected rather than carried along.
 */

export const APP_PROFILE_FORMAT = 'windows-deployment-builder/app-profiles';
export const APP_PROFILE_FORMAT_VERSION = 1;

const FileSchema = z
  .object({
    format: z.literal(APP_PROFILE_FORMAT),
    formatVersion: z.literal(APP_PROFILE_FORMAT_VERSION),
    exportedUtc: z.string().max(40).optional(),
    profiles: z.array(AppProfileSchema).min(1).max(50),
  })
  .strict();

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

/** Drops invalid packages for known sources and duplicate keys inside one profile. */
function cleanPackages(packages: PackageRef[], label: string, warnings: string[]): PackageRef[] {
  const seen = new Set<string>();
  const out: PackageRef[] = [];
  for (const p of packages) {
    const ref = { ...p, source: isKnownSource(p.source.toLowerCase()) ? p.source.toLowerCase() : p.source };
    const reason = unresolvedReason(ref);
    if (reason && isKnownSource(ref.source)) {
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

/**
 * Imports either this builder's profile file or a native WinGet export. Imported profiles become
 * new, unselected custom profiles; ids and names that already exist get a suffix.
 */
export function importAppProfiles(text: string, existing: readonly AppProfile[], fileName = 'import'): ProfileImportResult {
  const fail = (errors: string[]): ProfileImportResult => ({ ok: false, errors, warnings: [], profiles: [] });
  if (text.length > MAX_IMPORT_BYTES) return fail(['File is larger than 5 MB.']);
  let raw: unknown;
  try {
    raw = JSON.parse(text.charCodeAt(0) === 0xfeff ? text.slice(1) : text);
  } catch (e) {
    return fail([`Not valid JSON: ${(e as Error).message}`]);
  }
  const takenIds = new Set(existing.map((p) => p.id));
  const takenNames = new Set(existing.map((p) => p.name.toLowerCase()));

  if (looksLikeWinGetDocument(raw)) {
    const r = importWinGetDocument(raw);
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

  const parsed = FileSchema.safeParse(raw);
  if (!parsed.success) {
    const fmt = typeof raw === 'object' && raw !== null && 'format' in raw ? '' : ' Expected a Windows Deployment Builder application profile file or a WinGet export (with "Sources").';
    return fail([...parsed.error.issues.slice(0, 12).map((i) => `${i.path.join('.') || '$'}: ${i.message}`), ...(fmt ? [fmt.trim()] : [])]);
  }
  const warnings: string[] = [];
  const idMap = new Map<string, string>();
  const profiles = parsed.data.profiles.map((p) => {
    const id = uniqueId(p.id, takenIds);
    idMap.set(p.id, id);
    if (id !== p.id) warnings.push(`Profile id "${p.id}" already exists; imported as "${id}".`);
    return { ...p, id, name: uniqueName(p.name, takenNames), builtin: false, packages: cleanPackages(p.packages, p.name, warnings) };
  });
  for (const p of profiles) {
    p.inherits = p.inherits.flatMap((i) => {
      const mapped = idMap.get(i) ?? (existing.some((e) => e.id === i) ? i : undefined);
      if (!mapped) warnings.push(`${p.name}: inherited profile "${i}" is not available and was dropped.`);
      return mapped ? [mapped] : [];
    });
  }
  return { ok: true, kind: 'app-profiles', errors: [], warnings, profiles };
}

// Profile operations ------------------------------------------------------------------------------
// All operate on a selection object in place and leave other profiles untouched.

export function createProfile(sel: ApplicationsSelection, name: string, packages: PackageRef[] = []): AppProfile {
  const taken = new Set(sel.profiles.map((p) => p.id));
  const profile: AppProfile = {
    id: uniqueId(name, taken),
    name: uniqueName(name.trim() || 'New profile', new Set(sel.profiles.map((p) => p.name.toLowerCase()))),
    category: 'custom',
    description: '',
    builtin: false,
    inherits: [],
    packages: structuredClone(packages),
  };
  sel.profiles.push(profile);
  return profile;
}

export function duplicateProfile(sel: ApplicationsSelection, id: string): AppProfile | undefined {
  const src = sel.profiles.find((p) => p.id === id);
  if (!src) return undefined;
  const copy = createProfile(sel, `${src.name} copy`, src.packages);
  copy.description = src.description;
  copy.inherits = [...src.inherits];
  return copy;
}

export function renameProfile(sel: ApplicationsSelection, id: string, name: string): boolean {
  const p = sel.profiles.find((x) => x.id === id);
  const trimmed = name.trim().slice(0, 80);
  if (!p || p.builtin || !trimmed) return false;
  p.name = trimmed;
  return true;
}

export function deleteProfile(sel: ApplicationsSelection, id: string): boolean {
  const i = sel.profiles.findIndex((p) => p.id === id);
  if (i < 0 || sel.profiles[i]!.builtin) return false;
  sel.profiles.splice(i, 1);
  sel.selectedProfiles = sel.selectedProfiles.filter((x) => x !== id);
  for (const p of sel.profiles) p.inherits = p.inherits.filter((x) => x !== id);
  return true;
}

export function toggleProfile(sel: ApplicationsSelection, id: string, on: boolean): void {
  sel.selectedProfiles = on ? [...new Set([...sel.selectedProfiles, id])] : sel.selectedProfiles.filter((x) => x !== id);
}

/** Adds a package to a profile, or to the individual additions when `target` is "added". */
export function addPackage(sel: ApplicationsSelection, ref: PackageRef, target: string = ADDED): boolean {
  const key = packageKey(ref);
  sel.removed = sel.removed.filter((k) => k !== key);
  const list = target === ADDED ? sel.added : sel.profiles.find((p) => p.id === target)?.packages;
  if (!list || list.some((r) => packageKey(r) === key)) return false;
  list.push(structuredClone(ref));
  return true;
}

/**
 * Removes a package from the combined selection: individual additions are deleted, and packages
 * that come from profiles are recorded in `removed` (the profiles themselves stay unchanged).
 */
export function removePackage(sel: ApplicationsSelection, key: string): void {
  sel.added = sel.added.filter((r) => packageKey(r) !== key);
  const fromProfiles = resolveSelection({ ...sel, added: [], removed: [] }).packages.some((p) => p.key === key);
  if (fromProfiles && !sel.removed.includes(key)) sel.removed.push(key);
}

export function restorePackage(sel: ApplicationsSelection, key: string): void {
  sel.removed = sel.removed.filter((k) => k !== key);
}

export function removeFromProfile(sel: ApplicationsSelection, profileId: string, key: string): void {
  const p = sel.profiles.find((x) => x.id === profileId);
  if (p) p.packages = p.packages.filter((r) => packageKey(r) !== key);
}

/** Replaces a profile's packages with the current combined selection (populating it explicitly). */
export function saveSelectionToProfile(sel: ApplicationsSelection, profileId: string): boolean {
  const p = sel.profiles.find((x) => x.id === profileId);
  if (!p) return false;
  const refs = resolveSelection(sel).packages.map((x) => structuredClone(x.ref));
  p.packages = refs;
  p.inherits = [];
  // The selected profiles now contribute these packages; drop the duplicates from "added".
  if (sel.selectedProfiles.includes(profileId)) sel.added = [];
  return true;
}

export const isValidProfileId = (id: string) => APP_PROFILE_ID.test(id);
