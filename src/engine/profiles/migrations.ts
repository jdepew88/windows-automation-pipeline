import ownerDefaultJson from '../../../profiles/owner-default.json';
import { SCHEMA_VERSION } from '../schema/profile';
import { normalizeId, WINGET_ID } from '../applications/ids';

/**
 * Schema migrations. `MIGRATIONS[n]` upgrades a version-n object to version n+1. Add entries here
 * (and tests) whenever `SCHEMA_VERSION` is bumped. Fields a migration leaves out are filled from
 * owner defaults by the importer.
 */
export type Migration = (input: Record<string, unknown>) => { value: Record<string, unknown>; note?: string };

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

export const MIGRATIONS: Record<number, Migration> = {
  // v2 adds Windows Update automation. Profiles saved before it existed keep generating the same
  // answer file, so the engine starts disabled for them.
  1: (input) => {
    if ('windowsUpdate' in input) return { value: input };
    return {
      value: { ...input, windowsUpdate: { enabled: false } },
      note: 'Windows Update automation (added in schema version 2) is turned off for this older profile. Turn it on under "Windows Update automation" if you want it.',
    };
  },

  // v3 adds application provisioning. The selection starts empty, so the answer file is unchanged.
  // The old record-only `deferred.wingetPackages` list moves into an unselected custom profile:
  // kept, but never installed until someone selects it.
  2: (input) => {
    const value = { ...input };
    const deferred = isObj(value.deferred) ? { ...value.deferred } : undefined;
    const legacy = deferred && Array.isArray(deferred.wingetPackages) ? deferred.wingetPackages.filter((x): x is string => typeof x === 'string') : [];
    if (deferred) {
      delete deferred.wingetPackages;
      value.deferred = deferred;
    }
    if ('applications' in value || legacy.length === 0) return { value };

    // WinGet identifiers are case-insensitive: keep the first spelling of each.
    const byKey = new Map<string, string>();
    for (const id of legacy.map((x) => normalizeId('winget', x))) if (!byKey.has(id.toLowerCase())) byKey.set(id.toLowerCase(), id);
    const ids = [...byKey.values()];
    const valid = ids.filter((id) => WINGET_ID.test(id));
    const defaults = structuredClone(ownerDefaultJson.applications.selection.profiles);
    value.applications = {
      selection: {
        profiles: [
          ...defaults,
          {
            id: 'imported-legacy',
            name: 'Imported from an older profile',
            category: 'custom',
            description: 'Package IDs recorded by Milestone 1 (deferred.wingetPackages). Not selected: select this profile to install them.',
            builtin: false,
            inherits: [],
            packages: valid.map((id) => ({ packageIdentifier: id, source: 'winget', displayName: id, version: '', scope: '' })),
          },
        ],
        selectedProfiles: [],
        added: [],
        removed: [],
      },
    };
    const dropped = ids.length - valid.length;
    return {
      value,
      note: `${valid.length} WinGet package ID(s) from this older profile were moved to the unselected profile "Imported from an older profile" under Application provisioning${dropped ? `; ${dropped} invalid ID(s) were dropped` : ''}. Nothing is installed unless you select it.`,
    };
  },
};

export type MigrateResult =
  | { ok: true; value: Record<string, unknown>; notes: string[] }
  | { ok: false; error: string };

export function migrate(
  input: Record<string, unknown>,
  migrations: Record<number, Migration> = MIGRATIONS,
  target: number = SCHEMA_VERSION,
): MigrateResult {
  const version = input.schemaVersion;
  if (typeof version !== 'number' || !Number.isInteger(version) || version < 1) {
    return { ok: false, error: 'Missing or invalid "schemaVersion"; this does not look like a Windows Deployment Builder profile.' };
  }
  if (version > target) {
    return { ok: false, error: `Profile schema version ${version} is newer than this app supports (${target}). Update the app.` };
  }
  let value = structuredClone(input);
  const notes: string[] = [];
  for (let v = version; v < target; v++) {
    const step = migrations[v];
    if (!step) return { ok: false, error: `No migration from schema version ${v} to ${v + 1}.` };
    const result = step(value);
    value = { ...result.value, schemaVersion: v + 1 };
    if (result.note) notes.push(result.note);
  }
  return { ok: true, value, notes };
}
