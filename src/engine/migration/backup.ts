import { z } from 'zod';
import { sha256 } from '../deployment/sha256';
import { adapterById } from './adapters';
import { ADAPTER_ID, BACKUP_FOLDER, BACKUP_ID, INVENTORY_ID, SHA256_HEX, type BackupReference } from './inventory';

/**
 * Phase 6: the backup manifest (backup-manifest.json) written by WdbMigration.ps1 -Mode Backup.
 * The website only ever sees this manifest, never the backed-up settings themselves: it shows
 * what the backup contains and pins the manifest's SHA-256 into the deployment, which then accepts
 * only that exact backup (every file is hashed in the manifest). Nothing is uploaded anywhere.
 */

export const BACKUP_FORMAT = 'windows-deployment-builder/app-backup';
export const MAX_MANIFEST_BYTES = 1024 * 1024;

// eslint-disable-next-line no-control-regex
const text = (max: number) => z.string().max(max).regex(/^[^\u0000-\u001f\u007f]*$/);

const ItemSchema = z
  .object({
    logical: text(120),
    kind: z.enum(['file', 'folder', 'gitconfig', 'xmlsanitized', 'registryTree', 'registryValues', 'extensions', 'review']),
    path: text(200),
    size: z.number().int().min(0).max(1024 * 1024),
    sha256: z.string().regex(SHA256_HEX),
  })
  .strict();

export const BackupManifestSchema = z
  .object({
    format: z.literal(BACKUP_FORMAT),
    formatVersion: z.literal(1),
    backupId: z.string().regex(BACKUP_ID),
    folderName: z.string().regex(BACKUP_FOLDER),
    createdUtc: text(40),
    collector: z.object({ name: text(64), version: text(32) }).strict(),
    source: z.object({ osName: text(100), osBuild: text(16), architecture: z.enum(['x64', 'x86', 'arm64', 'unknown']) }).strict(),
    inventoryId: z.union([z.literal(''), z.string().regex(INVENTORY_ID)]),
    adapters: z
      .array(
        z
          .object({
            id: z.string().regex(ADAPTER_ID),
            name: text(100),
            adapterVersion: z.number().int().min(1).max(100),
            restoreMode: z.enum(['automatic', 'review']),
            items: z.array(ItemSchema).max(200),
            excluded: z.array(z.object({ logical: text(400), reason: text(500) }).strict()).max(500),
            notes: z.array(text(500)).max(200),
          })
          .strict(),
      )
      .max(50),
    unsupported: z.array(z.object({ id: text(64), reason: text(500) }).strict()).max(50),
    totals: z.object({ files: z.number().int().min(0), bytes: z.number().int().min(0) }).strict(),
    notice: text(500),
  })
  .strict();
export type BackupManifest = z.infer<typeof BackupManifestSchema>;

export interface BackupImportResult {
  ok: boolean;
  errors: string[];
  warnings: string[];
  manifest?: BackupManifest;
  reference?: BackupReference;
}

/** Same layout rule as Test-WdbBackup: data/<adapter>/<logical>, nothing else. */
function itemProblem(adapterId: string, item: z.infer<typeof ItemSchema>): string | undefined {
  if (item.path !== `data/${adapterId}/${item.logical}`) return `${adapterId}: item path "${item.path}" is not where this adapter keeps "${item.logical}".`;
  if (/\.\.|:|\\|\/\/|^\//.test(item.path)) return `${adapterId}: unsafe path "${item.path}".`;
  const a = adapterById(adapterId);
  if (!a) return undefined;
  const top = item.logical.split('/');
  const known = a.items.some((i) => (i.kind === 'folder' ? top.length === 2 && top[0] === i.logical && /^[A-Za-z0-9][A-Za-z0-9._ ()+-]{0,99}$/.test(top[1]!) : i.logical === item.logical));
  return known ? undefined : `${adapterId}: "${item.logical}" is not an item this adapter restores.`;
}

/** Validates backup-manifest.json bytes and returns the reference the deployment pins. */
export function importBackupManifest(bytes: Uint8Array): BackupImportResult {
  const fail = (errors: string[]): BackupImportResult => ({ ok: false, errors, warnings: [] });
  if (bytes.length > MAX_MANIFEST_BYTES) return fail(['The manifest is larger than 1 MB.']);
  let raw: unknown;
  try {
    const t = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    raw = JSON.parse(t.charCodeAt(0) === 0xfeff ? t.slice(1) : t);
  } catch (e) {
    return fail([`Not a valid UTF-8 JSON file: ${(e as Error).message}`]);
  }
  const parsed = BackupManifestSchema.safeParse(raw);
  if (!parsed.success) return fail(parsed.error.issues.slice(0, 12).map((i) => `${i.path.join('.') || '$'}: ${i.message}`));
  const m = parsed.data;
  const errors: string[] = [];
  const warnings: string[] = [];
  const seen = new Set<string>();
  for (const a of m.adapters) {
    if (seen.has(a.id)) errors.push(`Adapter ${a.id} is listed twice.`);
    seen.add(a.id);
    if (!adapterById(a.id)) warnings.push(`Adapter "${a.id}" is not known to this version; its settings will not be restored.`);
    for (const i of a.items) {
      const p = itemProblem(a.id, i);
      if (p) errors.push(p);
    }
  }
  if (errors.length) return fail(errors.slice(0, 12));
  return {
    ok: true,
    errors: [],
    warnings,
    manifest: m,
    reference: {
      backupId: m.backupId,
      manifestSha256: sha256(bytes),
      folderName: m.folderName,
      createdUtc: m.createdUtc,
      adapters: m.adapters.map((a) => ({ id: a.id, items: a.items.length, excluded: a.excluded.length })),
    },
  };
}
