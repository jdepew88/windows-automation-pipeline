import { z } from 'zod';
import catalogJson from '../../data/apps/catalog.json';
import { MSSTORE_ID, WINGET_ID, packageKey } from './ids';

/**
 * The application catalog: a manually maintained data file (`src/data/apps/catalog.json`). Listing
 * an app here neither selects nor installs it. Entries can be added or corrected without touching
 * the engine; the file is validated once at load so a broken edit fails loudly.
 */

export const CATALOG_CATEGORIES = {
  browsers: 'Browsers',
  communication: 'Email & communication',
  documents: 'Documents, PDF & notes',
  media: 'Photos & media',
  utilities: 'Utilities',
  gaming: 'Gaming & emulation',
  development: 'Development & terminals',
  virtualization: 'Virtualization',
  networking: 'Networking',
  hardware: 'Battery & manufacturer utilities',
  touch: 'Pen, touch & handwriting',
} as const;
export type CatalogCategory = keyof typeof CATALOG_CATEGORIES;

const CatalogEntrySchema = z
  .object({
    id: z.string().regex(/^[a-z0-9][a-z0-9-]{0,47}$/),
    displayName: z.string().min(1).max(100),
    /** null when no identifier has been verified: such an entry is "unresolved" and never installed. */
    packageIdentifier: z.string().max(128).nullable(),
    source: z.enum(['winget', 'msstore']),
    category: z.enum(Object.keys(CATALOG_CATEGORIES) as [CatalogCategory, ...CatalogCategory[]]),
    description: z.string().max(300),
    website: z.string().url().startsWith('https://').optional(),
    /** Empty = not recorded. */
    architectures: z.array(z.enum(['x64', 'x86', 'arm64'])),
    scope: z.enum(['user', 'machine', 'either', 'unknown']),
    installerType: z.string().max(40),
    license: z.string().max(120),
    /** Package keys ("source:id") that must be installed first when both are selected. */
    requires: z.array(z.string().max(200)),
    /** "unknown" = not reviewed. "required" = never attempted unattended. */
    interaction: z.enum(['silent', 'mayPrompt', 'required', 'unknown']),
    /** Needs an account sign-in to be useful (installation itself is unattended). */
    accountSignIn: z.boolean(),
    reboot: z.enum(['none', 'mayRequire', 'unknown']),
    notes: z.string().max(400).optional(),
    validation: z
      .object({
        status: z.enum(['verified', 'unverified', 'unresolved']),
        checkedAt: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
        method: z.string().max(300),
      })
      .strict(),
  })
  .strict()
  .superRefine((e, ctx) => {
    const id = e.packageIdentifier;
    if (e.validation.status === 'unresolved') {
      if (id !== null) ctx.addIssue({ code: 'custom', message: `${e.id}: unresolved entries must not carry an identifier` });
      return;
    }
    if (id === null) ctx.addIssue({ code: 'custom', message: `${e.id}: missing packageIdentifier` });
    else if (!(e.source === 'winget' ? WINGET_ID : MSSTORE_ID).test(id)) ctx.addIssue({ code: 'custom', message: `${e.id}: invalid ${e.source} identifier ${id}` });
  });

export type CatalogEntry = z.infer<typeof CatalogEntrySchema>;

const CatalogSchema = z
  .object({
    $comment: z.string().optional(),
    catalogVersion: z.literal(1),
    updated: z.string(),
    entries: z.array(CatalogEntrySchema),
  })
  .strict()
  .superRefine((c, ctx) => {
    const ids = new Set<string>();
    const keys = new Set<string>();
    for (const e of c.entries) {
      if (ids.has(e.id)) ctx.addIssue({ code: 'custom', message: `duplicate catalog id ${e.id}` });
      ids.add(e.id);
      if (e.packageIdentifier) {
        const k = packageKey({ source: e.source, packageIdentifier: e.packageIdentifier });
        if (keys.has(k)) ctx.addIssue({ code: 'custom', message: `duplicate package ${k}` });
        keys.add(k);
      }
    }
  });

export const CATALOG: readonly CatalogEntry[] = CatalogSchema.parse(catalogJson).entries;
export const CATALOG_UPDATED: string = catalogJson.updated;

const BY_KEY = new Map(CATALOG.filter((e) => e.packageIdentifier).map((e) => [packageKey({ source: e.source, packageIdentifier: e.packageIdentifier! }), e]));

export function catalogEntryForKey(key: string): CatalogEntry | undefined {
  return BY_KEY.get(key);
}

export function catalogEntryById(id: string): CatalogEntry | undefined {
  return CATALOG.find((e) => e.id === id);
}

/** Case-insensitive search over name, description, identifier and category label. */
export function searchCatalog(query: string, category: CatalogCategory | '' = ''): CatalogEntry[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  return CATALOG.filter((e) => {
    if (category && e.category !== category) return false;
    const hay = `${e.displayName} ${e.description} ${e.packageIdentifier ?? ''} ${CATALOG_CATEGORIES[e.category]}`.toLowerCase();
    return words.every((w) => hay.includes(w));
  });
}
