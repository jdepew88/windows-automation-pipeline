import type { AdditionalItem, AppProfile, PackageRef } from '../schema/applications';
import type { Profile } from '../schema/profile';
import { NO_DEVICES } from '../schema/applications';
import { packageKey } from '../applications/ids';
import { allProfiles, installable, resolveSelection } from '../applications/selection';
import { createProfile, toggleProfile } from '../applications/profiles';
import { SETTINGS_ADAPTERS, adapterById } from './adapters';
import type { BackupReference, Decision, Inventory } from './inventory';
import { CONFLICT_POLICIES, type Migration } from '../schema/migration';

export { CONFLICT_POLICIES, MigrationSchema, type ConflictPolicy, type Migration } from '../schema/migration';
import type { MigrationItem } from './matching';

/**
 * Phase 6: the migration part of a deployment profile and what it generates. The review's
 * decisions become an ordinary custom application profile (built on a base profile such as
 * Network Engineer / Developer / Technician, which itself is never changed) plus manual follow-up
 * entries; the settings plan pins one backup by the SHA-256 of its manifest.
 */

export const EMPTY_MIGRATION: Migration = { enabled: false, source: null, decisions: [], backup: null, settings: [], followUps: [] };

export const DEFAULT_BASE_PROFILE = 'network-engineer';
export const DEFAULT_MIGRATION_PROFILE_NAME = 'Personal Workstation';

/** The review's starting point: the recommendation of every item. */
export function defaultDecisions(items: readonly MigrationItem[]): Map<string, { decision: Decision; confirmed: boolean }> {
  return new Map(items.map((i) => [i.id, { decision: i.recommendation, confirmed: false }]));
}

/** Why a decision is not possible for an item, or undefined. */
export function decisionProblem(item: MigrationItem, d: { decision: Decision; confirmed: boolean }): string | undefined {
  if (!item.allowed.includes(d.decision)) return `"${d.decision}" is not available: ${item.reasons.at(-1) ?? ''}`.trim();
  if ((d.decision === 'restore' || d.decision === 'optional') && !item.ref) return 'Nothing can be installed automatically for this application.';
  if (d.decision === 'restore' && item.needsConfirmation && !d.confirmed) return 'Confirm the match first: the name resembles a catalog entry, but the publisher does not confirm it.';
  return undefined;
}

/** Manual tasks for what the inventory found in the development environment. */
export function devFollowUps(inv: Inventory, settingsAdapters: readonly string[] = []): string[] {
  const d = inv.devEnvironment;
  const out: string[] = [];
  for (const m of d.node.managers) out.push(`Node.js is managed by ${m.name}${m.versions.length ? ` (versions ${m.versions.join(', ')})` : ''}: install ${m.name} and then those versions with it; the standalone Node.js package is not a replacement.`);
  for (const m of d.pythonManagers) out.push(`Python is managed by ${m.name}${m.versions.length ? ` (versions ${m.versions.join(', ')})` : ''}: install it and recreate those versions.`);
  if (d.python.length) out.push(`Python installations on the old computer: ${d.python.map((p) => `${p.tag} (${p.version || 'unknown version'}, ${p.scope})`).join(', ')}. Recreate virtual environments from their requirements; they are not copied.`);
  const gallery = d.powershellModules.filter((m) => m.repository);
  if (gallery.length) out.push(`PowerShell modules from ${[...new Set(gallery.map((m) => m.repository))].join(', ')} to install by hand (Install-Module): ${gallery.map((m) => `${m.name}${m.versions.length ? ` ${m.versions.at(-1)}` : ''}`).join(', ')}.`);
  if (d.vscodeExtensions.length && !settingsAdapters.includes('vscode')) out.push(`Visual Studio Code extensions (${d.vscodeExtensions.length}): ${d.vscodeExtensions.map((e) => e.id).join(', ')}.`);
  if (d.cursorExtensions.length) out.push(`Cursor extensions to install from its extension view (${d.cursorExtensions.length}): ${d.cursorExtensions.map((e) => e.id).join(', ')}.`);
  if (d.docker.installed) out.push('Docker Desktop: settings, images, containers and volumes are not migrated; sign in again and pull or rebuild what you need.');
  if (d.claudeCode.installed && d.claudeCode.method !== 'winget') out.push(`Claude Code was installed with ${d.claudeCode.method === 'native' ? 'its native installer' : 'npm'}; sign in again after installing it.`);
  for (const r of d.repositories) if (r.remote) out.push(`Repository ${r.name}: git clone ${r.remote} (never cloned automatically; SSH keys and credentials are yours to restore).`);
  return out.slice(0, 300);
}

export interface ApplyOptions {
  name?: string;
  baseProfile?: string;
  now?: Date;
}

export interface ApplyResult {
  profile: AppProfile;
  manualAdded: number;
  warnings: string[];
}

/**
 * Turns a reviewed inventory into a new custom application profile, ticks it, and records the
 * review in the deployment profile. The base profile stays untouched: the new profile inherits
 * it, adds the approved applications, keeps "optional" ones unticked, and records the base apps
 * the review excluded as its exclusions. Unknown applications marked "manual" become Additional
 * Software manual follow-ups. Throws when a decision is not allowed.
 */
export function applyMigration(p: Profile, inv: Inventory, items: readonly MigrationItem[], decisions: ReadonlyMap<string, { decision: Decision; confirmed: boolean }>, opts: ApplyOptions = {}): ApplyResult {
  const sel = p.applications.selection;
  const base = opts.baseProfile ?? DEFAULT_BASE_PROFILE;
  if (base && !allProfiles(sel).some((x) => x.id === base)) throw new Error(`Base profile "${base}" does not exist.`);
  const baseKeys = new Set(base ? resolveSelection({ profiles: sel.profiles, selectedProfiles: [base], devices: { ...NO_DEVICES }, added: [], removed: [], ...(sel.profileRevision !== undefined ? { profileRevision: sel.profileRevision } : {}) }).packages.map((x) => x.key) : []);
  const packages: PackageRef[] = [];
  const optional: PackageRef[] = [];
  const excluded: string[] = [];
  const manual: AdditionalItem[] = [];
  const record: Migration['decisions'] = [];
  const warnings: string[] = [];
  for (const it of items) {
    const d = decisions.get(it.id) ?? { decision: it.recommendation, confirmed: false };
    const problem = decisionProblem(it, d);
    if (problem) throw new Error(`${it.app.displayName}: ${problem}`);
    const key = it.ref ? packageKey(it.ref) : '';
    let recKey = key;
    if (d.decision === 'restore' && it.ref && !baseKeys.has(key)) packages.push(structuredClone(it.ref));
    else if (d.decision === 'optional' && it.ref && !baseKeys.has(key)) optional.push(structuredClone(it.ref));
    else if (d.decision === 'exclude' && key && baseKeys.has(key)) excluded.push(key);
    else if (d.decision === 'manual') {
      if (it.ref && it.ref.source === 'catalog') {
        if (!baseKeys.has(key)) packages.push(structuredClone(it.ref));
      } else {
        const id = `migration-${it.id}`;
        recKey = `additional:${id}`;
        manual.push({
          id,
          name: it.app.displayName.slice(0, 100),
          publisher: it.app.publisher.slice(0, 100),
          downloadUrl: '',
          installerType: 'other',
          fileName: '',
          sha256: '',
          silentArgs: '',
          prerequisites: '',
          interaction: 'unknown',
          manualSupply: true,
          license: '',
          redistribution: 'unknown',
          execution: 'manual',
          notes: `From the inventory of ${inv.source.osName || 'the old computer'}${it.app.version ? `, version ${it.app.version}` : ''}. ${it.reasons.at(-1) ?? ''}`.slice(0, 1000),
        });
      }
    }
    record.push({ inventoryId: it.id, displayName: it.app.displayName, decision: d.decision, confirmed: d.confirmed, classification: it.classification, key: d.decision === 'exclude' ? key : recKey });
  }
  const created = createProfile(sel, opts.name?.trim() || DEFAULT_MIGRATION_PROFILE_NAME, packages, opts.now);
  created.description = `Built from the inventory of ${inv.source.osName || 'an existing computer'} (${inv.exportedUtc.slice(0, 10)})${base ? ` on top of ${allProfiles(sel).find((x) => x.id === base)?.name ?? base}` : ''}: ${packages.length} added, ${optional.length} optional, ${excluded.length} left out.`.slice(0, 500);
  created.inherits = base ? [base] : [];
  if (optional.length) created.optional = optional;
  if (excluded.length) created.excluded = [...new Set(excluded)];
  toggleProfile(sel, created.id, true);
  if (base) toggleProfile(sel, base, false);
  const existing = new Set(p.additionalSoftware.items.map((i) => i.id));
  const fresh = manual.filter((m) => !existing.has(m.id));
  if (p.additionalSoftware.items.length + fresh.length > 50) {
    warnings.push(`Only ${50 - p.additionalSoftware.items.length} manual entries fit in Additional Software; the rest are listed in the restoration report only.`);
  }
  p.additionalSoftware.items.push(...fresh.slice(0, Math.max(0, 50 - p.additionalSoftware.items.length)));
  p.migration.enabled = true;
  p.migration.source = { inventoryId: inv.inventoryId, exportedUtc: inv.exportedUtc, osName: inv.source.osName, osBuild: inv.source.osBuild, architecture: inv.source.architecture, applications: inv.applications.length };
  p.migration.decisions = record;
  p.migration.followUps = devFollowUps(inv, p.migration.settings.filter((s) => s.enabled).map((s) => s.adapterId));
  if (inv.backup && !p.migration.backup) attachBackup(p, inv.backup);
  return { profile: created, manualAdded: fresh.length, warnings };
}

/** Pins a backup and offers its adapters (those this version supports), off by default for review. */
export function attachBackup(p: Profile, ref: BackupReference): void {
  p.migration.backup = structuredClone(ref);
  const keep = new Map(p.migration.settings.map((s) => [s.adapterId, s]));
  p.migration.settings = ref.adapters
    .filter((a) => adapterById(a.id) && a.items > 0)
    .map((a) => keep.get(a.id) ?? { adapterId: a.id, enabled: true, conflict: 'keepExisting' as const, installExtensions: adapterById(a.id)!.extensionsCli });
}

export const settingsRestoreActive = (p: Profile): boolean => p.migration.enabled && !!p.migration.backup && p.migration.settings.some((s) => s.enabled && adapterById(s.adapterId));

/** True when the deployment carries a restoration plan. */
export const migrationActive = (p: Profile): boolean => p.migration.enabled && (p.migration.decisions.length > 0 || settingsRestoreActive(p));

/** applications-config.json › settingsRestore (engine 1.3.0). */
export function settingsRestoreConfig(p: Profile) {
  if (!settingsRestoreActive(p)) return undefined;
  const b = p.migration.backup!;
  const selected = new Set(installable(resolveSelection(p.applications.selection)).map((x) => x.key));
  return {
    backupId: b.backupId,
    manifestSha256: b.manifestSha256,
    folderName: b.folderName,
    adapters: p.migration.settings
      .filter((s) => s.enabled && adapterById(s.adapterId))
      .map((s) => {
        const a = adapterById(s.adapterId)!;
        return { id: a.id, name: a.name, conflict: s.conflict, after: a.appKeys.filter((k) => selected.has(k)), installExtensions: a.extensionsCli && s.installExtensions };
      }),
  };
}

/** applications-config.json › migration (the per-application report of restoration.json). */
export function migrationConfig(p: Profile) {
  if (!migrationActive(p) || !p.migration.source) return undefined;
  return {
    inventoryId: p.migration.source.inventoryId,
    applications: p.migration.decisions.map((d) => ({ inventoryId: d.inventoryId, displayName: d.displayName, decision: d.decision, key: d.key })),
    followUps: p.migration.followUps,
  };
}

/** Human-readable restoration plan (restore-plan.txt in the deployment package). */
export function restorePlanText(p: Profile): string {
  const m = p.migration;
  const lines = ['Windows Deployment Builder - application restoration plan', '=========================================================', ''];
  if (m.source) lines.push(`Source: inventory ${m.source.inventoryId} of ${m.source.osName || 'an existing computer'} (build ${m.source.osBuild || '?'}, ${m.source.architecture}), exported ${m.source.exportedUtc.slice(0, 10)}.`, '');
  const by = (d: Decision) => m.decisions.filter((x) => x.decision === d);
  const block = (title: string, xs: Migration['decisions']) => {
    lines.push(`${title} (${xs.length})`);
    for (const x of xs) lines.push(`  - ${x.displayName}${x.key ? `  [${x.key}]` : ''}`);
    lines.push('');
  };
  block('Reinstalled automatically (through the application stage, with its retry and recovery)', by('restore'));
  block('Manual installation (follow-up list)', by('manual'));
  block('Optional (not selected unless ticked)', by('optional'));
  block('Excluded from this migration', by('exclude'));
  if (settingsRestoreActive(p)) {
    const b = m.backup!;
    lines.push(`Settings restore: backup ${b.backupId} (manifest SHA-256 ${b.manifestSha256}).`, `  Put the backup folder on the USB drive as  WindowsDeployment\\backups\\${b.folderName}`, '  Settings are restored after their applications are installed; nothing else is accepted.');
    for (const s of m.settings.filter((x) => x.enabled)) {
      const a = adapterById(s.adapterId);
      if (a) lines.push(`  - ${a.name}: ${CONFLICT_POLICIES[s.conflict]}${a.extensionsCli && s.installExtensions ? '; extensions reinstalled' : ''}${a.restoreMode === 'review' ? ' (restored for review only)' : ''}`);
    }
    lines.push('');
  } else lines.push('Settings restore: none.', '');
  if (m.followUps.length) {
    lines.push('Manual follow-ups for the development environment:');
    for (const f of m.followUps) lines.push(`  - ${f}`);
    lines.push('');
  }
  lines.push('Not restored by design: passwords, tokens, private keys, credential stores, browser profiles, Docker data, user documents.');
  return lines.join('\n') + '\n';
}

export { SETTINGS_ADAPTERS };
