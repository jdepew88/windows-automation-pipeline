import type { Profile } from '../engine/schema/profile';
import { collectorAsset } from '../engine/applications';
import { isSelectableProfile } from '../engine/applications/builtin';
import { allProfiles } from '../engine/applications/selection';
import { importInventory, type Decision, type Inventory } from '../engine/migration/inventory';
import { CLASSIFICATIONS, CONFIDENCES, classificationCounts, matchInventory, type MigrationItem } from '../engine/migration/matching';
import { importBackupManifest } from '../engine/migration/backup';
import { SETTINGS_ADAPTERS, UNSUPPORTED_SETTINGS, adapterById } from '../engine/migration/adapters';
import { CONFLICT_POLICIES, DEFAULT_BASE_PROFILE, DEFAULT_MIGRATION_PROFILE_NAME, applyMigration, attachBackup, decisionProblem, defaultDecisions, devFollowUps } from '../engine/migration/plan';
import { appLogo } from './app-icon';
import { clear, download, h, uid } from './dom';
import { customShell, type CustomRenderer } from './form';
import { icon } from './icons';
import type { Store } from './store';

/**
 * Phase 6: Application Backup & Restore (Advanced Configuration). The imported inventory and the
 * review live in this browser tab only (they are facts about someone's computer); the profile
 * records the summary, the applied decisions and the pinned backup reference. Backed-up settings
 * never reach the website: only the backup's manifest is read, to show and pin it.
 */

interface Session {
  inventory?: Inventory;
  fileName: string;
  items: MigrationItem[];
  decisions: Map<string, { decision: Decision; confirmed: boolean }>;
  warnings: string[];
}
const session: Session = { fileName: '', items: [], decisions: new Map(), warnings: [] };

const DECISION_LABEL: Record<Decision, string> = { restore: 'Restore automatically', manual: 'Include, install manually', optional: 'Keep as optional', exclude: 'Exclude from this migration' };
const MAX_ROWS = 150;

function notice(target: HTMLElement, kind: 'info' | 'error', title: string, lines: string[] = []): void {
  clear(target);
  target.className = `app-status notice ${kind}`;
  target.append(
    icon(kind === 'error' ? 'xCircle' : 'info'),
    h('div', { class: 'notice-body' }, h('strong', {}, title), lines.length ? h('ul', {}, lines.slice(0, 12).map((l) => h('li', {}, l)), lines.length > 12 ? h('li', {}, `… and ${lines.length - 12} more`) : null) : null),
  );
}

const targetArch = (p: Profile) => (p.setup.processorArchitectures.includes('arm64') && !p.setup.processorArchitectures.includes('amd64') ? 'arm64' : 'amd64');

/** Re-renders every migration editor (they share the session). */
const refreshAll = (store: Store) => store.update(() => undefined, true);

// 1. Collector and inventory import ---------------------------------------------------------------

export const migrationSourceEditor: CustomRenderer = (def, store) => {
  const status = h('div', { class: 'app-status', 'data-testid': 'mig-import-status', 'aria-live': 'polite' });
  const summary = h('div', { class: 'mig-summary', 'data-testid': 'mig-summary' });
  const input = h('input', {
    type: 'file',
    accept: '.json,application/json',
    class: 'sr-only',
    tabindex: -1,
    'data-testid': 'mig-inventory-input',
    onchange: async () => {
      const file = input.files?.[0];
      input.value = '';
      if (!file) return;
      const r = importInventory(await file.text());
      if (!r.ok || !r.inventory) {
        notice(status, 'error', `Could not import ${file.name}`, r.errors);
        return;
      }
      session.inventory = r.inventory;
      session.fileName = file.name;
      session.items = matchInventory(r.inventory, targetArch(store.get()));
      session.decisions = defaultDecisions(session.items);
      for (const d of r.inventory.review?.decisions ?? []) {
        const it = session.items.find((x) => x.id === d.inventoryId);
        if (it && !decisionProblem(it, d)) session.decisions.set(d.inventoryId, { decision: d.decision, confirmed: d.confirmed });
      }
      session.warnings = r.warnings;
      notice(status, 'info', `Imported ${file.name}: ${r.inventory.applications.length} application record(s)`, [
        'Nothing is selected yet: review the list below, then create a profile from it.',
        ...(r.inventory.review ? ['The review saved in this file was applied where it is still valid.'] : []),
        ...r.warnings,
      ]);
      refreshAll(store);
    },
  });
  const collector = collectorAsset();
  const el = customShell(
    def,
    h(
      'div',
      { class: 'mig-source' },
      h(
        'ol',
        { class: 'mig-steps' },
        h(
          'li',
          {},
          'Download the collector and copy it to the existing computer: ',
          h('button', { type: 'button', class: 'btn', 'data-testid': 'mig-download-collector', onclick: () => download(collector.name, collector.content, 'text/plain') }, icon('download'), collector.name),
        ),
        h('li', {}, 'In Windows PowerShell on that computer (as the user whose applications and settings you want): ', h('pre', { class: 'mig-cmd' }, `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\${collector.name} -Mode Inventory -OutFile .\\inventory.json`)),
        h('li', {}, 'Optional: add ', h('code', {}, '-PortablePath D:\\Tools'), ' to look for portable programs in a folder you name, or ', h('code', {}, '-RepositoryRoot D:\\src'), ' to list Git repositories (never cloned).'),
        h('li', {}, 'Import the inventory file here: ', h('button', { type: 'button', class: 'btn primary', 'data-action': 'mig-import', onclick: () => input.click() }, icon('importIcon'), 'Import inventory…'), input),
      ),
      status,
      summary,
    ),
  );
  const sync = (p: Profile) => {
    clear(summary);
    const inv = session.inventory;
    if (!inv) {
      if (p.migration.source) {
        const s = p.migration.source;
        summary.append(h('p', { class: 'desc' }, `This profile was built from inventory ${s.inventoryId} of ${s.osName || 'an existing computer'} (${s.applications} records, ${s.exportedUtc.slice(0, 10)}). Import that inventory again to change the review.`));
      }
      return;
    }
    const c = classificationCounts(session.items);
    summary.append(
      h('dl', { class: 'mig-facts' },
        h('dt', {}, 'Source'), h('dd', {}, `${inv.source.osName || 'Windows'} ${inv.source.displayVersion} (build ${inv.source.osBuild}, ${inv.source.architecture})`),
        h('dt', {}, 'Collected'), h('dd', {}, `${inv.exportedUtc.slice(0, 16).replace('T', ' ')} UTC with collector ${inv.collector.version}, WinGet via ${inv.collector.wingetMethod}`),
        h('dt', {}, 'Left out'), h('dd', {}, `${inv.excludedCounts.systemComponents} system components, ${inv.excludedCounts.updates} updates, ${inv.excludedCounts.frameworks} frameworks`),
      ),
      h('ul', { class: 'mig-counts', 'data-testid': 'mig-counts' }, (Object.keys(CLASSIFICATIONS) as (keyof typeof CLASSIFICATIONS)[]).map((k) => h('li', { 'data-class': k }, h('strong', {}, String(c[k])), ` ${CLASSIFICATIONS[k]}`))),
    );
  };
  return { el, sync };
};

// 2. Review ---------------------------------------------------------------------------------------

type Filter = 'all' | 'restore' | 'manual' | 'optional' | 'exclude' | 'confirm' | 'unknown' | 'system';
const FILTERS: [Filter, string][] = [
  ['all', 'All'],
  ['restore', 'Restore'],
  ['manual', 'Manual'],
  ['optional', 'Optional'],
  ['exclude', 'Excluded'],
  ['confirm', 'Needs confirmation'],
  ['unknown', 'Unknown'],
  ['system', 'Windows components'],
];

export const migrationReviewEditor: CustomRenderer = (def, store) => {
  let filter: Filter = 'all';
  let query = '';
  let limit = MAX_ROWS;
  const status = h('div', { class: 'app-status', 'data-testid': 'mig-review-status', 'aria-live': 'polite' });
  const list = h('div', { class: 'mig-list', 'data-testid': 'mig-review' });
  const chips = h('div', { class: 'chips', role: 'group', 'aria-label': 'Filter' });
  const search = h('input', { type: 'search', placeholder: 'Search applications', 'aria-label': 'Search applications', 'data-testid': 'mig-search', oninput: () => ((query = search.value.toLowerCase()), (limit = MAX_ROWS), render()) });
  const nameId = uid('mig');
  const baseId = uid('mig');
  const name = h('input', { id: nameId, type: 'text', value: DEFAULT_MIGRATION_PROFILE_NAME, maxlength: 80, 'data-testid': 'mig-profile-name', autocomplete: 'off' });
  const base = h('select', { id: baseId, 'data-testid': 'mig-base' });
  const create = h('button', {
    type: 'button',
    class: 'btn primary',
    'data-testid': 'mig-create',
    onclick: () => {
      if (!session.inventory) return;
      let msg: { title: string; lines: string[] } | undefined;
      try {
        store.update((p) => {
          const r = applyMigration(p, session.inventory!, session.items, session.decisions, { name: name.value, baseProfile: base.value });
          msg = {
            title: `Created profile "${r.profile.name}" and ticked it`,
            lines: [
              `${r.profile.packages.length} application(s) added on top of ${allProfiles(p.applications.selection).find((x) => x.id === base.value)?.name ?? 'no base profile'}, ${r.profile.optional?.length ?? 0} optional, ${r.profile.excluded?.length ?? 0} left out. The base profile itself is unchanged.`,
              ...(r.manualAdded ? [`${r.manualAdded} manual installation(s) added to Additional Software (follow-up list).`] : []),
              'It is saved in this browser like any custom profile; export it under Applications for a backup.',
              ...r.warnings,
            ],
          };
        }, true);
      } catch (e) {
        notice(status, 'error', 'The profile was not created', [(e as Error).message]);
        return;
      }
      if (msg) notice(status, 'info', msg.title, msg.lines);
    },
  }, icon('plus'), 'Create profile from this review');
  const exportBtn = h('button', {
    type: 'button',
    class: 'btn',
    'data-testid': 'mig-export',
    title: 'The inventory with your decisions, to continue the review later or on another computer',
    onclick: () => {
      const inv = session.inventory;
      if (!inv) return;
      const reviewed: Inventory = {
        ...inv,
        review: {
          reviewedUtc: new Date().toISOString(),
          decisions: session.items.map((i) => ({ inventoryId: i.id, ...(session.decisions.get(i.id) ?? { decision: i.recommendation, confirmed: false }) })),
          mappings: session.items.map((i) => ({ inventoryId: i.id, classification: i.classification, confidence: i.confidence, packageKey: i.ref ? `${i.ref.source}:${i.ref.packageIdentifier}`.toLowerCase().slice(0, 200) : '', recommendation: i.recommendation })),
          unresolved: session.items.filter((i) => !i.ref && !i.system).map((i) => i.id),
        },
      };
      download(`reviewed-${session.fileName || 'inventory.json'}`, JSON.stringify(reviewed, null, 2) + '\n', 'application/json');
    },
  }, icon('exportIcon'), 'Export reviewed inventory');

  const matches = (i: MigrationItem, f: Filter = filter): boolean => {
    const d = session.decisions.get(i.id)?.decision ?? i.recommendation;
    if (f === 'system' ? !i.system : i.system) return false;
    if (f === 'confirm' && !(i.needsConfirmation && !session.decisions.get(i.id)?.confirmed)) return false;
    if (f === 'unknown' && i.classification !== 'unknown') return false;
    if (['restore', 'manual', 'optional', 'exclude'].includes(f) && d !== f) return false;
    if (query && !`${i.app.displayName} ${i.app.publisher} ${i.app.packageIdentifier}`.toLowerCase().includes(query)) return false;
    return true;
  };

  const row = (i: MigrationItem): HTMLElement => {
    const cur = session.decisions.get(i.id) ?? { decision: i.recommendation, confirmed: false };
    const sid = uid('mig');
    const problem = decisionProblem(i, cur);
    const select = h(
      'select',
      {
        id: sid,
        'data-testid': 'mig-decision',
        onchange: () => {
          session.decisions.set(i.id, { decision: select.value as Decision, confirmed: cur.confirmed });
          render();
        },
      },
      i.allowed.map((d) => h('option', { value: d, selected: d === cur.decision }, DECISION_LABEL[d])),
    );
    const confirmId = uid('mig');
    return h(
      'div',
      { class: `mig-row${problem ? ' invalid' : ''}`, 'data-testid': 'mig-row', 'data-inventory-id': i.id, 'data-classification': i.classification, 'data-confidence': i.confidence },
      appLogo(i.catalog?.id, i.app.displayName, i.catalog?.category, 'sm'),
      h(
        'div',
        { class: 'mig-main' },
        h('strong', {}, i.app.displayName),
        h('span', { class: 'choice-desc' }, [i.app.publisher, i.app.version, i.app.scope !== 'unknown' ? `${i.app.scope}-wide` : '', i.app.architecture !== 'unknown' ? i.app.architecture : ''].filter(Boolean).join(' · ')),
        h(
          'div',
          { class: 'badges' },
          h('span', { class: `badge ${i.classification === 'unknown' ? 'warn' : i.classification === 'manual' ? 'warn' : 'info'}` }, CLASSIFICATIONS[i.classification]),
          h('span', { class: `badge ${i.confidence === 'possible' ? 'warn' : i.confidence === 'none' ? 'muted' : 'ok'}`, title: CONFIDENCES[i.confidence] }, CONFIDENCES[i.confidence]),
          i.ref && i.ref.source !== 'catalog' ? h('code', { class: 'mig-id' }, `${i.ref.source}: ${i.ref.packageIdentifier}`) : null,
          i.hardware ? h('span', { class: 'badge warn' }, 'Hardware-specific (Phase 8)') : null,
          i.merged.length ? h('span', { class: 'badge muted' }, `${i.merged.length + 1} records merged`) : null,
        ),
        h('ul', { class: 'mig-reasons' }, i.reasons.map((r) => h('li', {}, r))),
        problem ? h('p', { class: 'risk' }, icon('alert'), problem) : null,
      ),
      h(
        'div',
        { class: 'mig-decide' },
        h('label', { for: sid, class: 'sr-only' }, `Decision for ${i.app.displayName}`),
        select,
        i.needsConfirmation
          ? h(
              'label',
              { class: 'mini-field check', for: confirmId },
              h('input', {
                type: 'checkbox',
                id: confirmId,
                'data-testid': 'mig-confirm',
                checked: cur.confirmed,
                onchange: (e: Event) => {
                  session.decisions.set(i.id, { decision: cur.decision, confirmed: (e.target as HTMLInputElement).checked });
                  render();
                },
              }),
              ` This is ${i.catalog?.displayName ?? 'the catalog app'}`,
            )
          : null,
      ),
    );
  };

  const render = () => {
    clear(list);
    clear(chips);
    if (!session.inventory) {
      list.append(h('div', { class: 'empty-state' }, icon('list'), h('p', { class: 'empty' }, 'Import an inventory to review its applications.')));
      create.disabled = true;
      exportBtn.disabled = true;
      return;
    }
    create.disabled = session.items.some((i) => !!decisionProblem(i, session.decisions.get(i.id) ?? { decision: i.recommendation, confirmed: false }));
    exportBtn.disabled = false;
    for (const [f, label] of FILTERS) {
      const n = session.items.filter((i) => matches(i, f)).length;
      chips.append(h('button', { type: 'button', class: `chip${f === filter ? ' on' : ''}`, 'aria-pressed': String(f === filter), 'data-filter': f, onclick: () => ((filter = f), (limit = MAX_ROWS), render()) }, label, h('span', { class: 'chip-count' }, String(n))));
    }
    const shown = session.items.filter((i) => matches(i));
    for (const i of shown.slice(0, limit)) list.append(row(i));
    if (!shown.length) list.append(h('p', { class: 'empty' }, 'Nothing matches this filter.'));
    if (shown.length > limit) list.append(h('button', { type: 'button', class: 'btn', onclick: () => ((limit += MAX_ROWS), render()) }, `Show ${Math.min(MAX_ROWS, shown.length - limit)} more of ${shown.length - limit}`));
  };

  const el = customShell(
    def,
    h(
      'div',
      { class: 'mig-review' },
      h('div', { class: 'app-toolbar' }, chips, search),
      list,
      h(
        'div',
        { class: 'mig-create' },
        h('div', { class: 'mini-field' }, h('label', { for: nameId }, 'Profile name'), name),
        h('div', { class: 'mini-field' }, h('label', { for: baseId }, 'Build on'), base),
        create,
        exportBtn,
      ),
      status,
    ),
  );
  const sync = (p: Profile) => {
    const keep = base.value || DEFAULT_BASE_PROFILE;
    clear(base);
    base.append(h('option', { value: '' }, 'Nothing (only the reviewed apps)'));
    for (const x of allProfiles(p.applications.selection).filter((x) => isSelectableProfile(x.id) && x.id !== 'core')) base.append(h('option', { value: x.id, selected: x.id === keep }, x.name));
    render();
  };
  return { el, sync };
};

// 3. Settings backup and restore ------------------------------------------------------------------

export const migrationBackupEditor: CustomRenderer = (def, store) => {
  const status = h('div', { class: 'app-status', 'data-testid': 'mig-backup-status', 'aria-live': 'polite' });
  const info = h('div', { class: 'mig-backup', 'data-testid': 'mig-backup' });
  const input = h('input', {
    type: 'file',
    accept: '.json,application/json',
    class: 'sr-only',
    tabindex: -1,
    'data-testid': 'mig-backup-input',
    onchange: async () => {
      const file = input.files?.[0];
      input.value = '';
      if (!file) return;
      const r = importBackupManifest(new Uint8Array(await file.arrayBuffer()));
      if (!r.ok || !r.reference) {
        notice(status, 'error', `Could not attach ${file.name}`, r.errors);
        return;
      }
      const inv = session.inventory;
      const lines = [...r.warnings];
      if (inv?.backup && inv.backup.manifestSha256 !== r.reference.manifestSha256) lines.push('This is not the backup the inventory refers to; the attached one is used.');
      store.update((p) => {
        attachBackup(p, r.reference!);
        p.migration.enabled = true;
      }, true);
      notice(status, 'info', `Attached backup ${r.reference.backupId}`, ['Only the manifest was read. The backup folder stays on your drive; copy it to the USB drive as shown below.', ...lines]);
    },
  });
  const el = customShell(def, h('div', {}, h('button', { type: 'button', class: 'btn', 'data-action': 'mig-attach-backup', onclick: () => input.click() }, icon('archive'), 'Attach backup manifest…'), input, status, info));
  const sync = (p: Profile) => {
    clear(info);
    const b = p.migration.backup;
    if (!b) {
      info.append(
        h('p', { class: 'desc' }, 'On the existing computer, first preview, then create the backup (choose the adapters):'),
        h('pre', { class: 'mig-cmd' }, `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\WdbMigration.ps1 -Mode PreviewBackup -Adapter ${SETTINGS_ADAPTERS.map((a) => a.id).join(',')}\npowershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\WdbMigration.ps1 -Mode Backup -Adapter vscode,git,putty -Destination E:\\ -InventoryPath .\\inventory.json`),
      );
      return;
    }
    info.append(
      h('dl', { class: 'mig-facts' },
        h('dt', {}, 'Backup'), h('dd', {}, h('code', {}, b.backupId), ` created ${b.createdUtc.slice(0, 10)}`),
        h('dt', {}, 'Manifest SHA-256'), h('dd', {}, h('code', { 'data-testid': 'mig-backup-hash' }, b.manifestSha256)),
        h('dt', {}, 'On the USB drive'), h('dd', {}, h('code', {}, `WindowsDeployment\\backups\\${b.folderName}`)),
      ),
      h('button', { type: 'button', class: 'linkish', 'data-action': 'mig-detach-backup', onclick: () => store.update((q) => ((q.migration.backup = null), (q.migration.settings = [])), true) }, 'Remove this backup from the plan'),
    );
  };
  return { el, sync };
};

export const migrationSettingsEditor: CustomRenderer = (def, store) => {
  const list = h('div', { class: 'mig-settings', 'data-testid': 'mig-settings' });
  const el = customShell(def, list);
  const sync = (p: Profile) => {
    clear(list);
    const m = p.migration;
    if (!m.backup) {
      list.append(h('p', { class: 'empty' }, 'Attach a backup manifest to choose which settings are restored.'));
    }
    m.settings.forEach((s, n) => {
      const a = adapterById(s.adapterId);
      if (!a) return;
      const on = uid('mig');
      const cid = uid('mig');
      const xid = uid('mig');
      const counts = m.backup?.adapters.find((x) => x.id === a.id);
      list.append(
        h(
          'div',
          { class: `item mig-adapter${s.enabled ? ' on' : ''}`, 'data-adapter': a.id },
          h(
            'div',
            { class: 'item-head' },
            h('input', { type: 'checkbox', id: on, checked: s.enabled, 'data-testid': 'mig-adapter-enabled', onchange: (e: Event) => store.update((q) => (q.migration.settings[n]!.enabled = (e.target as HTMLInputElement).checked), true) }),
            h('label', { for: on }, h('strong', {}, a.name), h('span', { class: 'choice-desc' }, ` ${counts?.items ?? 0} item(s) in the backup${counts?.excluded ? `, ${counts.excluded} left out by the collector` : ''}`)),
            a.restoreMode === 'review' ? h('span', { class: 'badge warn' }, 'restored for review only') : null,
          ),
          h(
            'div',
            { class: 'mini-grid' },
            h('div', { class: 'mini-field' }, h('label', { for: cid }, 'If settings already exist'), h('select', { id: cid, 'data-testid': 'mig-adapter-conflict', onchange: (e: Event) => store.update((q) => (q.migration.settings[n]!.conflict = (e.target as HTMLSelectElement).value as typeof s.conflict), true) }, Object.entries(CONFLICT_POLICIES).map(([v, l]) => h('option', { value: v, selected: v === s.conflict }, l)))),
            a.extensionsCli ? h('div', { class: 'mini-field check' }, h('input', { type: 'checkbox', id: xid, checked: s.installExtensions, onchange: (e: Event) => store.update((q) => (q.migration.settings[n]!.installExtensions = (e.target as HTMLInputElement).checked), true) }), h('label', { for: xid }, 'Reinstall extensions with the VS Code command line (needs the Internet)')) : null,
          ),
          h('details', {}, h('summary', {}, 'What is included, and what never is'),
            h('ul', {}, a.items.map((i) => h('li', {}, h('code', {}, i.location)))),
            h('p', { class: 'desc' }, h('strong', {}, 'Never included: '), a.excluded.join('; '), '.'),
            h('p', { class: 'desc' }, h('strong', {}, 'Prerequisites: '), a.prerequisites, ' ', h('strong', {}, 'Verification: '), a.verification),
            h('p', { class: 'desc' }, h('strong', {}, 'Limitations: '), a.limitations),
          ),
        ),
      );
    });
    list.append(h('details', { class: 'mig-unsupported' }, h('summary', {}, 'Not backed up by design'), h('ul', {}, Object.entries(UNSUPPORTED_SETTINGS).map(([k, v]) => h('li', {}, h('strong', {}, k), `: ${v}`)))));
  };
  return { el, sync };
};

export const migrationFollowUpsEditor: CustomRenderer = (def) => {
  const list = h('ul', { class: 'mig-followups', 'data-testid': 'mig-followups' });
  const el = customShell(def, list);
  const sync = (p: Profile) => {
    clear(list);
    const items = p.migration.followUps.length ? p.migration.followUps : session.inventory ? devFollowUps(session.inventory) : [];
    if (!items.length) list.append(h('li', { class: 'empty' }, 'None.'));
    for (const f of items) list.append(h('li', {}, f));
  };
  return { el, sync };
};

/** For tests and the profile reset: forgets the imported inventory of this tab. */
export function resetMigrationSession(): void {
  session.inventory = undefined;
  session.items = [];
  session.decisions = new Map();
  session.warnings = [];
  session.fileName = '';
}
