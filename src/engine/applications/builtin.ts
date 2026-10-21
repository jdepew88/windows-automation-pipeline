import { z } from 'zod';
import profilesJson from '../../data/apps/profiles.json';
import { AppProfileCategorySchema, APP_PROFILE_ID, type AppProfile, type Devices, type PackageRef } from '../schema/applications';
import { catalogEntryById, catalogRef, entryKey } from './catalog';

/**
 * Built-in application profiles (Phase 4.2): templates defined in `src/data/apps/profiles.json`,
 * referencing catalog entries by their stable catalog id. They are never stored in a deployment
 * profile and cannot be edited, renamed or deleted, so a customer's changes can never alter them;
 * "Duplicate" makes an editable copy. Device profiles are not ticked by the user: the answers under
 * "Mobile devices & ecosystem" activate them.
 */

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

const FileSchema = z
  .object({
    $comment: z.string().optional(),
    profilesVersion: z.literal(1),
    /** Profiles every new deployment starts with. */
    universal: z.array(z.string()),
    profiles: z.array(BuiltinSchema),
  })
  .strict()
  .superRefine((f, ctx) => {
    const issue = (message: string) => ctx.addIssue({ code: 'custom', message });
    const ids = new Set(f.profiles.map((p) => p.id));
    if (ids.size !== f.profiles.length) issue('duplicate built-in profile id');
    for (const u of f.universal) if (!ids.has(u)) issue(`universal profile ${u} does not exist`);
    for (const p of f.profiles) {
      for (const i of p.inherits) if (!ids.has(i)) issue(`${p.id}: inherits unknown profile ${i}`);
      const all = [...p.defaults, ...p.optional];
      if (new Set(all).size !== all.length) issue(`${p.id}: an app is listed twice`);
      for (const id of all) {
        const e = catalogEntryById(id);
        if (!e) issue(`${p.id}: unknown catalog id ${id}`);
        else if (!entryKey(e)) issue(`${p.id}: ${id} has no package and cannot be selected`);
      }
    }
  });

const FILE = FileSchema.parse(profilesJson);

const refs = (ids: readonly string[]): PackageRef[] => ids.map((id) => catalogRef(catalogEntryById(id)!)!);

export const BUILTIN_PROFILES: readonly AppProfile[] = FILE.profiles.map((p) => ({
  id: p.id,
  name: p.name,
  category: p.category,
  description: p.description,
  builtin: true,
  inherits: [...p.inherits],
  packages: refs(p.defaults),
  optional: refs(p.optional),
}));

/** Ids of the profiles selected in every new deployment (Core Essentials). */
export const UNIVERSAL_PROFILES: readonly string[] = FILE.universal;

const ACTIVATION = new Map(FILE.profiles.map((p) => [p.id, p.activation]));

export const isBuiltinProfile = (id: string) => ACTIVATION.has(id);
/** False for device profiles, which follow the device answers. */
export const isSelectableProfile = (id: string) => ACTIVATION.get(id) !== 'devices-apple' && ACTIVATION.get(id) !== 'devices-android';
export const builtinProfile = (id: string) => BUILTIN_PROFILES.find((p) => p.id === id);

export const APPLE_DEVICES = (d: Devices) => d.phone === 'iphone' || d.ipad || d.extraIphone;
export const ANDROID_DEVICES = (d: Devices) => d.phone === 'android' || d.androidTablet;

/** The device profiles the answers activate (an Android phone and an iPad activate both). */
export function deviceProfiles(d: Devices): string[] {
  return FILE.profiles.filter((p) => (p.activation === 'devices-apple' && APPLE_DEVICES(d)) || (p.activation === 'devices-android' && ANDROID_DEVICES(d))).map((p) => p.id);
}

/** Every catalog entry a built-in profile refers to, for tests and documentation. */
export const BUILTIN_REFERENCED = new Set(FILE.profiles.flatMap((p) => [...p.defaults, ...p.optional]));
