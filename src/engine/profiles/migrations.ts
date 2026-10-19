import { SCHEMA_VERSION } from '../schema/profile';

/**
 * Schema migrations. `MIGRATIONS[n]` upgrades a version-n object to version n+1. Add entries here
 * (and tests) whenever `SCHEMA_VERSION` is bumped. Fields a migration leaves out are filled from
 * owner defaults by the importer.
 */
export type Migration = (input: Record<string, unknown>) => { value: Record<string, unknown>; note?: string };

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
