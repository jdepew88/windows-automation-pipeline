import { z } from 'zod';
import profilesJson from '../../data/apps/profiles.json';
import profilesV1Json from '../../data/apps/profiles-v1.json';
import { AppProfileCategorySchema, APP_PROFILE_ID, type AppProfile, type Devices, type PackageRef } from '../schema/applications';
import { catalogEntryById, catalogRef, entryKey, removalForCatalogId } from './catalog';
import { CATALOG_SOURCE } from './ids';

/**
 * Built-in application profiles (Phase 4.2): templates defined in `src/data/apps/profiles.json`,
 * referencing catalog entries by their stable catalog id. They are never stored in a deployment
 * profile and cannot be edited, renamed or deleted, so a customer's changes can never alter them;
 * "Duplicate" makes an editable copy. Device profiles are not ticked by the user: the answers under
 * "Mobile devices & ecosystem" activate them.
 *
 * Revisions (2026-11-26): the profiles were rebuilt. Revision 1 (the original definitions) is frozen
 * in `profiles-v1.json`; revision 2 is `profiles.json`. Every deployment and every saved custom
 * profile records the revision it was created with (absent = 1), so the new defaults apply to new
 * deployments only and an older configuration keeps exactly the applications it had until the
 * technician adopts the new defaults explicitly.
 */

export type ProfileRevision = 1 | 2;
/** The revision new deployments and new custom profiles use. */
export const CURRENT_PROFILE_REVISION: ProfileRevision = 2;
export const PROFILE_REVISIONS: readonly ProfileRevision[] = [1, 2];

const BuiltinSchema = z
  .object({
    id: z.string().regex(APP_PROFILE_ID),
    name: z.string().min(1).max(80),
    category: AppProfileCategorySchema,
    description: z.string().max(500),
    /** Profiles whose defaults this one includes. */
    inherits: z.array(z.string()).max(10),
    /** Catalog ids selected when the profile is active. */
    defaults: z.array(z.string()),
    /** Catalog ids recommended (shown unticked) while the profile is active. */
    optional: z.array(z.string()),
    /** Device profiles are activated by the device answers instead of a checkbox. */
    activation: z.enum(['selectable', 'devices-apple', 'devices-android']),
  })
  .strict();

const fileSchema = (version: ProfileRevision) =>
  z
    .object({
      $comment: z.string().optional(),
      profilesVersion: z.literal(version),
      /** Profiles every new deployment starts with. */
      universal: z.array(z.string()),
      profiles: z.array(BuiltinSchema),
    })
    .strict()
    .superRefine((f, ctx) => {
      const issue = (message: string) => ctx.addIssue({ code: 'custom', message: `revision ${version}: ${message}` });
      const ids = new Set(f.profiles.map((p) => p.id));
      if (ids.size !== f.profiles.length) issue('duplicate built-in profile id');
      for (const u of f.universal) if (!ids.has(u)) issue(`universal profile ${u} does not exist`);
      for (const p of f.profiles) {
        for (const i of p.inherits) if (!ids.has(i)) issue(`${p.id}: inherits unknown profile ${i}`);
        const all = [...p.defaults, ...p.optional];
        if (new Set(all).size !== all.length) issue(`${p.id}: an app is listed twice`);
        for (const id of all) {
          const e = catalogEntryById(id);
          // Revision 1 is frozen: an app removed from the catalog since stays named there; it resolves
          // to a "removed" warning and is never installed. The current revision must not name one.
          if (!e && version === 1 && removalForCatalogId(id)) continue;
          if (!e) issue(`${p.id}: unknown catalog id ${id}`);
          else if (!entryKey(e)) issue(`${p.id}: ${id} has no package and cannot be selected`);
        }
      }
    });

const FILES = { 1: fileSchema(1).parse(profilesV1Json), 2: fileSchema(2).parse(profilesJson) } as const;

const refs = (ids: readonly string[]): PackageRef[] =>
  ids.map((id) => {
    const e = catalogEntryById(id);
    // A removed entry (revision 1 only): a catalog reference the planner reports as removed.
    return e ? catalogRef(e)! : { packageIdentifier: id, source: CATALOG_SOURCE, displayName: removalForCatalogId(id)?.name ?? id, version: '', scope: '' };
  });

const SETS: Record<ProfileRevision, readonly AppProfile[]> = {
  1: build(1),
  2: build(2),
};
function build(rev: ProfileRevision): AppProfile[] {
  return FILES[rev].profiles.map((p) => ({
    id: p.id,
    name: p.name,
    category: p.category,
    description: p.description,
    builtin: true,
    inherits: [...p.inherits],
    packages: refs(p.defaults),
    optional: refs(p.optional),
  }));
}

/** The built-in profiles of a revision (the current one by default). */
export const builtinProfiles = (rev: ProfileRevision = CURRENT_PROFILE_REVISION): readonly AppProfile[] => SETS[rev];

/** The current built-in profiles (revision 2). */
export const BUILTIN_PROFILES: readonly AppProfile[] = SETS[CURRENT_PROFILE_REVISION];

/** Ids of the profiles selected in every new deployment (Core Essentials; the same in every revision). */
export const UNIVERSAL_PROFILES: readonly string[] = FILES[CURRENT_PROFILE_REVISION].universal;

const ACTIVATION = new Map(PROFILE_REVISIONS.flatMap((rev) => FILES[rev].profiles.map((p) => [p.id, p.activation] as const)));

/** The ids of every revision's built-in profiles (reserved: a custom profile never uses one). */
export const BUILTIN_IDS: readonly string[] = [...ACTIVATION.keys()];

/** True for an id of any revision's built-in profiles (a custom profile can never use one). */
export const isBuiltinProfile = (id: string) => ACTIVATION.has(id);
/** False for device profiles, which follow the device answers. */
export const isSelectableProfile = (id: string) => ACTIVATION.get(id) !== 'devices-apple' && ACTIVATION.get(id) !== 'devices-android';
export const builtinProfile = (id: string, rev: ProfileRevision = CURRENT_PROFILE_REVISION) => SETS[rev].find((p) => p.id === id);

/** The revision a selection or custom profile uses: absent (anything created before revision 2) means 1. */
export const revisionOf = (value: number | undefined): ProfileRevision => (value === 2 ? 2 : 1);

export const APPLE_DEVICES = (d: Devices) => d.phone === 'iphone' || d.ipad || d.extraIphone;
export const ANDROID_DEVICES = (d: Devices) => d.phone === 'android' || d.androidTablet;

/** The device profiles the answers activate (an Android phone and an iPad activate both; the same ids in every revision). */
export function deviceProfiles(d: Devices): string[] {
  return FILES[CURRENT_PROFILE_REVISION].profiles.filter((p) => (p.activation === 'devices-apple' && APPLE_DEVICES(d)) || (p.activation === 'devices-android' && ANDROID_DEVICES(d))).map((p) => p.id);
}

/** Every catalog entry a built-in profile of any revision refers to, for tests and documentation. */
export const BUILTIN_REFERENCED = new Set(PROFILE_REVISIONS.flatMap((rev) => FILES[rev].profiles.flatMap((p) => [...p.defaults, ...p.optional])));
