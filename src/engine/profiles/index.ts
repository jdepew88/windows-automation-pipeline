import ownerDefaultJson from '../../../profiles/owner-default.json';
import { ProfileSchema, SCHEMA_VERSION, type Profile } from '../schema/profile';
import { migrate } from './migrations';

/** Owner defaults, validated once at module load so a broken JSON file fails loudly. */
const OWNER_DEFAULT: Profile = ProfileSchema.parse(ownerDefaultJson);

/** A fresh, deep copy of the owner-default profile. The only reset target in the app. */
export function ownerDefaults(): Profile {
  return structuredClone(OWNER_DEFAULT);
}

export interface ImportResult {
  profile?: Profile;
  errors: { path: string; message: string }[];
  warnings: string[];
}

type Json = null | boolean | number | string | Json[] | { [k: string]: Json };

function isPlainObject(v: unknown): v is Record<string, Json> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/**
 * Fills missing fields from owner defaults. Arrays and record-like maps from the import replace the
 * default wholesale, so an imported empty script list stays empty. Unknown keys pass through so
 * strict schema validation can report them.
 */
function fillMissing(defaults: Json, imported: Json, path: string, filled: string[]): Json {
  if (isPlainObject(defaults) && isPlainObject(imported)) {
    const out: Record<string, Json> = { ...imported };
    for (const [k, v] of Object.entries(defaults)) {
      const p = path ? `${path}.${k}` : k;
      if (!(k in imported)) {
        out[k] = structuredClone(v);
        filled.push(p);
      } else if (isPlainObject(v) && !RECORD_PATHS.has(p)) {
        out[k] = fillMissing(v, imported[k]!, p, filled);
      }
    }
    return out;
  }
  return imported;
}

/** Map-shaped sections: missing keys are filled per entry (new catalog items get owner defaults). */
const RECORD_PATHS = new Set(['bloatware', 'desktop.icons', 'start.folders']);

function fillRecordEntries(profile: Record<string, Json>, defaults: Record<string, Json>, filled: string[]): void {
  for (const p of RECORD_PATHS) {
    const [a, b] = p.split('.') as [string, string | undefined];
    const target = b ? (profile[a] as Record<string, Json> | undefined)?.[b] : profile[a];
    const source = b ? (defaults[a] as Record<string, Json>)[b] : defaults[a];
    if (!isPlainObject(target) || !isPlainObject(source)) continue;
    for (const [k, v] of Object.entries(source)) {
      if (!(k in target)) {
        target[k] = v;
        filled.push(`${p}.${k}`);
      }
    }
  }
}

/**
 * Largest profile file accepted: far above any real profile (they are kilobytes), and a bound on the
 * work the schema validation does on a hostile or corrupt file.
 */
export const MAX_PROFILE_BYTES = 16 * 1024 * 1024;

/** Parses and validates profile JSON text (any supported schema version). */
export function importProfile(text: string): ImportResult {
  if (text.length > MAX_PROFILE_BYTES) return { errors: [{ path: '', message: `File is larger than ${MAX_PROFILE_BYTES / 1024 / 1024} MB: not a deployment profile.` }], warnings: [] };
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch (e) {
    return { errors: [{ path: '', message: `Not valid JSON: ${(e as Error).message}` }], warnings: [] };
  }
  if (!isPlainObject(raw)) {
    return { errors: [{ path: '', message: 'Profile must be a JSON object.' }], warnings: [] };
  }
  const migrated = migrate(raw);
  if (!migrated.ok) {
    return { errors: [{ path: 'schemaVersion', message: migrated.error }], warnings: [] };
  }
  const warnings = [...migrated.notes];
  const filled: string[] = [];
  const defaults = ownerDefaults() as unknown as Record<string, Json>;
  const merged = fillMissing(defaults, migrated.value as Json, '', filled) as Record<string, Json>;
  fillRecordEntries(merged, defaults, filled);
  if (filled.length > 0) {
    warnings.push(`Filled ${filled.length} missing field(s) from owner defaults: ${filled.slice(0, 8).join(', ')}${filled.length > 8 ? ', …' : ''}`);
  }
  const parsed = ProfileSchema.safeParse(merged);
  if (!parsed.success) {
    return {
      errors: parsed.error.issues.map((i) => ({ path: i.path.join('.'), message: i.message })),
      warnings,
    };
  }
  return { profile: parsed.data, errors: [], warnings };
}

export interface ExportOptions {
  /** Include account and Wi-Fi passwords. Off by default so exported profiles are safe to share. */
  includeSecrets?: boolean;
}

/** Paths that may hold secrets, blanked by {@link stripSecrets}. */
export const SECRET_PATHS = ['accounts.password', 'wifi.password'] as const;

export function stripSecrets(profile: Profile): Profile {
  const copy = structuredClone(profile);
  copy.accounts.password = '';
  copy.wifi.password = '';
  // A Wi-Fi XML profile can carry <keyMaterial>; drop it rather than parse-and-redact partially.
  if (copy.wifi.profileXml && /keyMaterial/i.test(copy.wifi.profileXml)) copy.wifi.profileXml = '';
  return copy;
}

export function hasSecrets(profile: Profile): boolean {
  return profile.accounts.password !== '' || profile.wifi.password !== '' || /keyMaterial/i.test(profile.wifi.profileXml);
}

export function exportProfile(profile: Profile, options: ExportOptions = {}): string {
  const out = options.includeSecrets ? profile : stripSecrets(profile);
  return JSON.stringify({ ...out, schemaVersion: SCHEMA_VERSION }, null, 2) + '\n';
}
