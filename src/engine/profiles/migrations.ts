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
    value.applications = {
      selection: {
        profiles: [
          ...structuredClone(V3_BUILTIN_PROFILES),
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

  // v4 (Phase 4.2): built-in application profiles become read-only templates from the catalog data,
  // the selection gains device answers, and new deployments start with Core Essentials. An older
  // profile keeps producing the same answer file: Core Essentials is NOT added, the empty v3
  // built-ins are dropped (and unticked), and a v3 built-in that someone had filled becomes a
  // custom profile with the same packages, ticked if it was.
  3: (input) => {
    const value = { ...input };
    const apps = isObj(value.applications) ? { ...value.applications } : {};
    const sel = isObj(apps.selection) ? { ...apps.selection } : {};
    const profiles = Array.isArray(sel.profiles) ? sel.profiles.filter(isObj) : [];
    const selected = Array.isArray(sel.selectedProfiles) ? sel.selectedProfiles.filter((x): x is string => typeof x === 'string') : [];
    const kept: Record<string, unknown>[] = [];
    const renamed = new Map<string, string | null>();
    const converted: string[] = [];
    for (const p of profiles) {
      if (p.builtin !== true) {
        kept.push(p);
        continue;
      }
      const packages = Array.isArray(p.packages) ? p.packages : [];
      const inherits = Array.isArray(p.inherits) ? p.inherits : [];
      if (packages.length === 0 && inherits.length === 0) {
        renamed.set(String(p.id), null);
        continue;
      }
      const id = `${String(p.id).slice(0, 40)}-saved`;
      renamed.set(String(p.id), id);
      converted.push(String(p.name));
      kept.push({ ...p, id, name: `${String(p.name)} (from an older profile)`.slice(0, 80), builtin: false, category: 'custom' });
    }
    const remap = (ids: unknown[]) => ids.flatMap((x) => (typeof x === 'string' && renamed.has(x) ? (renamed.get(x) ? [renamed.get(x)!] : []) : typeof x === 'string' ? [x] : []));
    for (const p of kept) if (Array.isArray(p.inherits)) p.inherits = remap(p.inherits);
    value.applications = {
      ...apps,
      selection: {
        ...sel,
        profiles: kept,
        selectedProfiles: remap(selected),
        devices: { phone: 'none', ipad: false, extraIphone: false, androidTablet: false },
        added: Array.isArray(sel.added) ? sel.added : [],
        removed: Array.isArray(sel.removed) ? sel.removed : [],
      },
    };
    const notes = ['Core Essentials (Chrome, VLC, 7-Zip, TeraCopy, RustDesk, Bitwarden and the Visual C++ runtimes) is not selected for this older profile, so it installs the same applications as before. Tick "Core Essentials" under Applications to add it.'];
    if (converted.length) notes.push(`Built-in profiles are now fixed templates; your filled-in ${converted.map((n) => `"${n}"`).join(', ')} became custom profile(s) "… (from an older profile)" with the same packages.`);
    return { value, note: notes.join(' ') };
  },

  // v5 (Phase 8) adds hardware-aware driver provisioning. New deployments start with it on; an
  // older profile keeps the deployment it produced, so the stage starts off for it.
  4: (input) => {
    if (isObj(input.drivers)) return { value: input };
    return {
      value: { ...input, drivers: { enabled: false } },
      note: 'Hardware-aware driver provisioning (added in schema version 5) is turned off for this older profile, so it produces the same deployment as before. Turn it on under "Hardware & Drivers" if you want it.',
    };
  },

  // v6 (Phase 9) adds deployment verification and health reports. New deployments verify
  // themselves; an older profile keeps the package it produced (no health engine), and its
  // explicit Windows Update driver policy is kept as it was.
  5: (input) => {
    if (isObj(input.health)) return { value: input };
    return {
      value: { ...input, health: { enabled: false } },
      note: 'Deployment verification and health reports (added in schema version 6) are turned off for this older profile, so it produces the same deployment as before. Turn them on under "Verification & Health" if you want them.',
    };
  },
};

/** The six (empty) built-in profiles of schema version 3, for the v2→v3 step. */
const V3_BUILTIN_PROFILES = [
  ['everyday', 'Everyday Essentials', 'everyday', 'Browsers, email, documents, PDFs, photo viewing and basic productivity for home users.'],
  ['gaming', 'Gaming', 'gaming', 'Game launchers, library managers and optional emulator frontends.'],
  ['developer', 'Developer / Power User', 'developer', 'Editors, terminals, Git, virtualization, networking and related tools.'],
  ['laptop', 'Laptop', 'laptop', 'Battery-management and optional manufacturer utilities for portable devices.'],
  ['touch', 'Touchscreen / 2-in-1', 'touch', 'Pen, handwriting, note-taking and touch-oriented apps for convertibles.'],
  ['custom', 'Custom', 'custom', 'Any combination you choose.'],
].map(([id, name, category, description]) => ({ id, name, category, description, builtin: true, inherits: [], packages: [] }));

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
