import { z } from 'zod';
import { APP_INVENTORY_ID, BackupReferenceSchema, DECISIONS, INVENTORY_ID } from '../migration/inventory';

/** Phase 6: the migration section of a deployment profile (see engine/migration/plan.ts). */

// eslint-disable-next-line no-control-regex
const text = (max: number) => z.string().max(max).regex(/^[^\u0000-\u001f\u007f]*$/);

export const CONFLICT_POLICIES = {
  keepExisting: 'Keep existing settings',
  restoreBackup: 'Restore from backup (the existing file is kept as .wdb-before-restore)',
  skip: "Skip this application's settings",
} as const;
export type ConflictPolicy = keyof typeof CONFLICT_POLICIES;

export const MigrationSchema = z
  .object({
    /** Include the restoration plan (decisions report and settings restore) in the deployment. */
    enabled: z.boolean(),
    source: z
      .object({ inventoryId: z.string().regex(INVENTORY_ID), exportedUtc: text(40), osName: text(100), osBuild: text(16), architecture: z.enum(['x64', 'x86', 'arm64', 'unknown']), applications: z.number().int().min(0) })
      .strict()
      .nullable(),
    /** The review, as applied (reported per application in restoration.json). */
    decisions: z
      .array(
        z
          .object({
            inventoryId: z.string().regex(APP_INVENTORY_ID),
            displayName: text(300),
            decision: z.enum(DECISIONS),
            confirmed: z.boolean(),
            classification: text(32),
            /** "winget:…", "msstore:…", "catalog:…", "additional:…" or "" (nothing to install). */
            key: text(200),
          })
          .strict(),
      )
      .max(3000),
    backup: BackupReferenceSchema.nullable(),
    settings: z
      .array(z.object({ adapterId: z.string().regex(/^[a-z0-9][a-z0-9-]{0,31}$/), enabled: z.boolean(), conflict: z.enum(['keepExisting', 'restoreBackup', 'skip']), installExtensions: z.boolean() }).strict())
      .max(20),
    /** Manual tasks for the development environment (version managers, modules, extensions, repositories). */
    followUps: z.array(text(500)).max(300),
  })
  .strict();
export type Migration = z.infer<typeof MigrationSchema>;

