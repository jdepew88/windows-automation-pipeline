import '../styles.css';
import './manager.css';
import { ApplicationsSelectionSchema, NO_DEVICES, type AppProfile, type ApplicationsSelection } from '../engine/schema/applications';
import { CATALOG, CATALOG_CATEGORIES, catalogRef, entryKey, methodOf, type CatalogCategory, type CatalogEntry, type InstallMethod } from '../engine/applications/catalog';
import { CURRENT_PROFILE_REVISION, builtinProfiles } from '../engine/applications/builtin';
import { addPackage, adoptCurrentProfiles, createProfile, deleteProfile, exportAppProfiles, importAppProfiles, removePackage, renameProfile, resetOverrides, saveAsNewProfile, toggleProfile, usesEarlierProfiles } from '../engine/applications/profiles';
import { allProfiles, expandProfile, resolveSelection, selectionRevision, type SelectionResult } from '../engine/applications/selection';
import { packageKey } from '../engine/applications/ids';
import {
  AVAILABILITY_LABELS, MANAGER_NAME, MANAGER_PROFILES_FORMAT, RESULT_LABELS, STATE_LABELS, bulkRemovable, catalogEntryForPackage, commandLine, installPreview, isSuccess,
  bulkEligible, compareVersions, installedView, matchInventory, queueReady, removalPreview, summarize, updateIssue, updateReason, wingetArguments,
  type AgentState, type InstallPreview, type InstalledKind, type InstalledView, type Match, type OperationRecord, type RemovalPreview, type UpdateItem,
} from '../engine/manager';
import { appLogo } from '../ui/app-icon';
import { download, h, render } from '../ui/dom';
import { api, hasToken, NotConnected, Unauthorized, type PackageSpec } from './api';

/**
 * Windows Deployment — Application Manager (Phase 10). Browse the catalog, see what is installed,
 * install, update and remove applications through the local agent. The catalog, the profiles and
 * the selection logic are the deployment wizard's own (resolveSelection); only the execution
 * differs: here every operation is previewed, confirmed and run by the agent on this computer.
 */

type Tab = 'browse' | 'installed' | 'updates' | 'profiles' | 'history';
type Conn = 'connecting' | 'connected' | 'none' | 'unauthorized';
type Review =
  | { kind: 'install'; accepted: Set<string> }
  | { kind: 'upgrade'; items: UpdateItem[]; all: boolean }
  | { kind: 'uninstall'; items: RemovalPreview[]; caution: Set<string>; word: string };

const TABS: { id: Tab; label: string }[] = [
  { id: 'browse', label: 'Browse applications' },
  { id: 'installed', label: 'Installed' },
  { id: 'updates', label: 'Updates' },
  { id: 'profiles', label: 'Profiles' },
  { id: 'history', label: 'History & reports' },
];

const METHOD_LABELS: Record<InstallMethod, string> = { winget: 'WinGet', msstore: 'Microsoft Store', portable: 'Portable (WinGet)', vendor: 'Publisher installer', manual: 'Manual installer' };
const ZIP_URL = 'downloads/windows-deployment-app-manager.zip';

// The manager always browses with the current built-in profiles.
const emptySelection = (): ApplicationsSelection => ({ profiles: [], selectedProfiles: [], devices: { ...NO_DEVICES }, added: [], removed: [], profileRevision: CURRENT_PROFILE_REVISION });

const ui = {
  tab: 'browse' as Tab,
  conn: 'connecting' as Conn,
  agent: null as AgentState | null,
  sel: emptySelection(),
  q: '',
  category: '' as CatalogCategory | '',
  publisher: '',
  method: '' as InstallMethod | '',
  status: 'all',
  profileFilter: '',
  review: null as Review | null,
  picked: new Set<string>(),
  removePick: new Set<string>(),
  instGroup: 'all' as 'all' | InstalledKind,
  instQ: '',
  history: [] as OperationRecord[],
  notice: null as { kind: 'info' | 'warn' | 'error'; text: string } | null,
  newProfileName: '',
  seenBatch: '',
  rescanFor: '',
};

const root = document.getElementById('mgr')!;
let plan: SelectionResult = resolveSelection(ui.sel);
let matches: Map<string, Match> = matchInventory(null, null);

let installedCache: InstalledView = installedView(null, matches);
function recompute(): void {
  plan = resolveSelection(ui.sel);
  matches = matchInventory(ui.agent?.inventory ?? null, ui.agent?.updates ?? null);
  installedCache = installedView(ui.agent?.inventory ?? null, matches);
}

const say = (kind: 'info' | 'warn' | 'error', text: string) => {
  ui.notice = { kind, text };
  draw();
};

/**
 * Fetches the agent's state. Requests can overlap (the poll, and a refresh after an action), so a
 * response is applied only if no later request's response was applied before it: an older state
 * never replaces a newer one. Returns whether the state changed (an unchanged state is not redrawn).
 */
let stateSeq = 0;
let appliedSeq = 0;
let lastState = '';
async function fetchState(): Promise<boolean> {
  const seq = ++stateSeq;
  const s = await api.state();
  if (seq < appliedSeq) return false;
  appliedSeq = seq;
  const json = JSON.stringify(s);
  if (json === lastState) return false;
  lastState = json;
  ui.agent = s;
  recompute();
  return true;
}

/** Runs a request, then shows the agent's new state at once (queued work is then polled every second). */
async function refresh(f: () => Promise<unknown>): Promise<boolean> {
  return attempt(async () => {
    await f();
    await fetchState();
    draw();
  });
}

async function attempt(f: () => Promise<unknown>): Promise<boolean> {
  try {
    await f();
    return true;
  } catch (e) {
    if (e instanceof Unauthorized) ui.conn = 'unauthorized';
    else if (e instanceof NotConnected) ui.conn = 'none';
    say('error', (e as Error).message);
    return false;
  }
}

// ------------------------------------------------------------------------------------------------
// Persistence of the selection and custom profiles (in the agent's data folder)
// ------------------------------------------------------------------------------------------------

let saveTimer = 0;
function changed(): void {
  recompute();
  draw();
  if (ui.conn !== 'connected') return;
  clearTimeout(saveTimer);
  saveTimer = window.setTimeout(() => void attempt(() => api.saveProfiles({ format: MANAGER_PROFILES_FORMAT, version: 1, selection: ui.sel })), 400);
}

async function loadSaved(): Promise<void> {
  const r = await api.loadProfiles();
  const doc = r.profiles as { format?: string; selection?: unknown } | null;
  if (!doc) return;
  const parsed = doc.format === MANAGER_PROFILES_FORMAT ? ApplicationsSelectionSchema.safeParse(doc.selection) : null;
  if (parsed?.success) ui.sel = parsed.data;
  else ui.notice = { kind: 'warn', text: 'Saved profiles could not be read and were ignored; nothing was changed.' };
}

// ------------------------------------------------------------------------------------------------
// Polling the agent
// ------------------------------------------------------------------------------------------------

let failures = 0;
async function poll(): Promise<void> {
  if (ui.conn === 'unauthorized' || ui.conn === 'none') return;
  let changedState = false;
  try {
    const first = ui.conn === 'connecting';
    changedState = await fetchState();
    failures = 0;
    if (first) {
      ui.conn = 'connected';
      await loadSaved();
      if (!ui.agent?.inventory && !ui.agent?.scanning) await api.scan('inventory');
      changedState = true;
    }
    const b = ui.agent?.batch;
    if (b && b.jobs.every((j) => j.state === 'Done' || j.state === 'Cancelled') && ui.rescanFor === b.id) {
      ui.rescanFor = '';
      if (!b.dryRun) await api.scan('inventory');
      if (ui.tab === 'history') ui.history = (await api.history()).records;
    }
  } catch (e) {
    // A single failed poll keeps the last state on screen; repeated failures mean the agent stopped.
    failures++;
    changedState = true;
    if (e instanceof Unauthorized) ui.conn = 'unauthorized';
    else if (ui.conn !== 'connected' || failures >= 3) ui.conn = 'none';
  }
  if (changedState) draw();
  if (ui.conn === 'connected') setTimeout(() => void poll(), ui.agent?.busy ? 1000 : 4000);
}

// ------------------------------------------------------------------------------------------------
// Helpers
// ------------------------------------------------------------------------------------------------

const inPlan = (e: CatalogEntry) => plan.packages.some((p) => p.catalog?.id === e.id);
const nameOfProfile = (id: string) => allProfiles(ui.sel).find((p) => p.id === id)?.name ?? id;
const badge = (text: string, kind = '', attrs: Record<string, string> = {}) => h('span', { class: `mgr-badge ${kind}`, ...attrs }, text);
const btn = (label: string, attrs: Record<string, string | boolean | ((e: Event) => void) | undefined>) => h('button', { type: 'button', class: 'btn', ...attrs }, label);
const connected = () => ui.conn === 'connected' && !!ui.agent;
const busy = () => !!ui.agent?.batch?.jobs.some((j) => j.state === 'Pending' || j.state === 'Running');

function originText(e: CatalogEntry): string {
  const p = plan.packages.find((x) => x.catalog?.id === e.id);
  if (p) {
    const profiles = p.origins.filter((o) => o !== 'added' && o !== 'required').map(nameOfProfile);
    const parts = [];
    if (profiles.length) parts.push(`Selected by ${profiles.join(', ')}`);
    if (p.origins.includes('added')) parts.push('Added by you');
    if (p.origins.includes('required')) parts.push(`Needed by ${p.requiredBy.map((k) => plan.packages.find((x) => x.key === k)?.displayName ?? k).join(', ')}`);
    return parts.join(' · ');
  }
  const removed = plan.removed.find((x) => x.catalog?.id === e.id);
  if (removed) return 'Unticked by you';
  const rec = plan.recommended.find((x) => x.catalog?.id === e.id);
  if (rec) return `Recommended by ${rec.origins.map(nameOfProfile).join(', ')}`;
  return '';
}

function stateBadge(m: Match | undefined, e?: CatalogEntry) {
  const st = m?.state ?? 'unknown';
  const label = st === 'installed' && m?.version ? `Installed ${m.version}` : st === 'updateAvailable' ? `Update: ${m?.version} → ${m?.update?.available}` : st === 'uncertain' ? `Detected ${m?.version ?? ''}`.trim() : STATE_LABELS[st];
  const title = st === 'uncertain' ? 'Found by its name in Windows, not by WinGet: it may have been installed another way.' : st === 'manual' && e?.manual ? e.manual.reason : '';
  return badge(label, `st-${st}`, { 'data-state': st, ...(title ? { title } : {}) });
}

function togglePick(e: CatalogEntry, on: boolean): void {
  const ref = catalogRef(e);
  if (!ref) return;
  if (on) addPackage(ui.sel, ref);
  else removePackage(ui.sel, entryKey(e));
  changed();
}

const spec = (id: string, source: string, name: string, more: Partial<PackageSpec> = {}): PackageSpec => ({ id, source: source === 'msstore' ? 'msstore' : 'winget', name, ...more });

// ------------------------------------------------------------------------------------------------
// Header, banners
// ------------------------------------------------------------------------------------------------

function header(): HTMLElement {
  const a = ui.agent;
  const status =
    ui.conn === 'connected'
      ? badge(a?.agent.online ? 'Connected' : 'Connected · offline', a?.agent.online ? 'ok' : 'warn', { 'data-testid': 'mgr-conn' })
      : ui.conn === 'connecting'
        ? badge('Connecting…', '', { 'data-testid': 'mgr-conn' })
        : badge('Not connected', 'err', { 'data-testid': 'mgr-conn' });
  return h(
    'header',
    { class: 'mgr-head' },
    h('div', { class: 'mgr-title' }, h('h1', {}, MANAGER_NAME), h('p', { class: 'muted' }, 'Install, update and remove applications on this computer with WinGet. Nothing runs until you confirm it.')),
    h(
      'div',
      { class: 'mgr-status' },
      status,
      a ? badge(a.agent.elevated ? 'Running as administrator' : `Signed in as ${a.agent.user}`, a.agent.elevated ? 'warn' : '', { title: 'The manager runs as you. When an installer needs administrator rights, Windows asks (UAC).' }) : null,
      a && !a.agent.winget ? badge('WinGet not found', 'err', { 'data-testid': 'mgr-nowinget' }) : null,
      a
        ? h(
            'label',
            { class: 'mgr-switch', title: a.settings.forcedDryRun ? 'Started with -DryRun: simulation cannot be switched off.' : 'In simulation mode every action shows the exact WinGet command and changes nothing.' },
            h('input', {
              type: 'checkbox',
              'data-testid': 'mgr-dryrun',
              checked: a.settings.dryRun,
              disabled: a.settings.forcedDryRun || busy(),
              onchange: (ev: Event) => void attempt(async () => {
                await api.settings({ dryRun: (ev.target as HTMLInputElement).checked });
                await fetchState();
                draw();
              }),
            }),
            h('span', {}, 'Simulation mode'),
          )
        : null,
    ),
  );
}

function banners(): (HTMLElement | null)[] {
  const a = ui.agent;
  const out: (HTMLElement | null)[] = [];
  if (ui.conn === 'none' || ui.conn === 'unauthorized')
    out.push(
      h(
        'section',
        { class: 'mgr-banner err', 'data-testid': 'mgr-not-connected', role: 'status' },
        h('strong', {}, ui.conn === 'unauthorized' ? 'The session key was not accepted.' : 'The Application Manager is not running on this computer.'),
        h('p', {}, hasToken() && ui.conn === 'unauthorized' ? 'Close this tab and start the manager again from its shortcut.' : 'This page can only browse the catalog by itself: a website cannot install software. To manage applications, download the Application Manager, extract it and run Install-AppManager.ps1 (no administrator rights needed), then start "' + MANAGER_NAME + '" from the Start menu.'),
        h('p', {}, h('a', { href: ZIP_URL, download: '', 'data-testid': 'mgr-download' }, 'Download the Application Manager (ZIP)')),
      ),
    );
  if (a?.settings.dryRun)
    out.push(h('section', { class: 'mgr-banner manual', 'data-testid': 'mgr-sim-banner', role: 'status' }, h('strong', {}, 'Simulation mode.'), ' Actions are previewed and recorded as "Simulated"; nothing is installed, updated or removed. Switch it off in the header when you are ready.'));
  if (a && !a.agent.online) out.push(h('section', { class: 'mgr-banner warn', 'data-testid': 'mgr-offline', role: 'status' }, h('strong', {}, 'No network.'), ' Installed applications, saved profiles, the last update check and the history are still shown. Availability and updates cannot be checked until the network is back.'));
  if (ui.notice) out.push(h('section', { class: `mgr-banner ${ui.notice.kind === 'error' ? 'err' : ui.notice.kind}`, 'data-testid': 'mgr-notice', role: 'status' }, ui.notice.text, ' ', btn('Dismiss', { class: 'btn ghost sm', onclick: () => { ui.notice = null; draw(); } })));
  for (const m of a?.messages ?? []) out.push(h('section', { class: 'mgr-banner warn' }, m));
  return out;
}

// ------------------------------------------------------------------------------------------------
// Batch progress (any tab)
// ------------------------------------------------------------------------------------------------

function batchPanel(): HTMLElement | null {
  const b = ui.agent?.batch;
  if (!b) return null;
  const done = b.jobs.filter((j) => j.record);
  const s = summarize(done.map((j) => j.record!));
  const running = b.jobs.some((j) => j.state === 'Pending' || j.state === 'Running');
  const retry = done.filter((j) => j.record!.retryable).map((j) => j.record!);
  const verb = { install: 'Installation', upgrade: 'Update', uninstall: 'Removal' }[b.action];
  return h(
    'section',
    { class: 'mgr-batch', 'data-testid': 'mgr-batch', 'data-running': String(running), 'aria-live': 'polite' },
    h('h2', {}, `${verb}${b.dryRun ? ' (simulated)' : ''}: ${running ? `${done.length} of ${b.jobs.length} done` : 'finished'}`),
    !running ? h('p', { 'data-testid': 'mgr-batch-summary' }, `${s.succeeded} done, ${s.failed} failed, ${s.attention} need attention${s.simulated ? `, ${s.simulated} simulated` : ''}.${s.restart ? ' A restart is needed to finish.' : ''}`) : null,
    h(
      'ol',
      { class: 'mgr-jobs' },
      b.jobs.map((j) => {
        const r = j.record;
        const kind = !r ? '' : isSuccess(r.result) ? 'ok' : r.result === 'Simulated' ? 'manual' : r.result === 'Failed' || r.result === 'Unavailable' ? 'err' : 'warn';
        return h(
          'li',
          { 'data-job': j.packageId, 'data-result': r?.result ?? j.state },
          h('strong', {}, j.name || j.packageId),
          ' ',
          badge(r ? RESULT_LABELS[r.result] : j.state === 'Running' ? 'Running…' : j.state === 'Cancelled' ? 'Cancelled' : 'Waiting', kind),
          r && r.result !== 'Simulated' ? h('span', { class: 'muted' }, ` exit ${r.exitCode}${r.resultVersion ? ` · now ${r.resultVersion}` : ''} · ${r.verification}`) : null,
          r?.manualAction ? h('p', { class: 'mgr-note' }, r.manualAction) : null,
          r && r.result === 'Failed' ? h('p', { class: 'mgr-note' }, r.symbol) : null,
          r ? h('code', { class: 'mgr-cmd' }, r.command) : null,
        );
      }),
    ),
    h(
      'div',
      { class: 'mgr-actions' },
      running ? btn('Cancel the rest', { 'data-action': 'mgr-cancel', onclick: () => void refresh(() => api.cancel()) }) : null,
      !running && retry.length ? btn(`Retry ${retry.length} failed`, { 'data-action': 'mgr-retry', onclick: () => void retryRecords(retry) }) : null,
    ),
  );
}

async function retryRecords(records: OperationRecord[]): Promise<void> {
  const action = records[0]!.action;
  const items = records.filter((r) => r.action === action).map((r) => spec(r.packageId, r.source, r.name, { catalogId: r.catalogId, scope: r.scope as PackageSpec['scope'], installedVersion: r.priorVersion, attempt: r.attempt + 1, retryOf: r.operationId }));
  await startBatch(action, items, action === 'uninstall' ? 'REMOVE' : '');
}

async function startBatch(action: 'install' | 'upgrade' | 'uninstall', items: PackageSpec[], confirm = ''): Promise<void> {
  if (!connected()) return;
  const ok = await attempt(async () => {
    const r = await api.operate(action, items, confirm);
    ui.rescanFor = r.batchId;
    ui.review = null;
    await fetchState();
  });
  if (ok) {
    ui.notice = null;
    window.scrollTo({ top: 0 });
  }
  draw();
}

// ------------------------------------------------------------------------------------------------
// Browse
// ------------------------------------------------------------------------------------------------

function filtered(): CatalogEntry[] {
  const q = ui.q.trim().toLowerCase();
  const inProfile = ui.profileFilter ? new Set([...expandProfile(ui.profileFilter, allProfiles(ui.sel)), ...(allProfiles(ui.sel).find((p) => p.id === ui.profileFilter)?.optional ?? [])].map(packageKey)) : null;
  return CATALOG.filter((e) => {
    if (ui.category && e.category !== ui.category) return false;
    if (ui.publisher && (e.publisher ?? '') !== ui.publisher) return false;
    if (ui.method && methodOf(e) !== ui.method) return false;
    if (inProfile && !inProfile.has(entryKey(e))) return false;
    const st = matches.get(e.id)?.state ?? 'unknown';
    if (ui.status === 'installed' && !['installed', 'updateAvailable', 'uncertain'].includes(st)) return false;
    if (ui.status === 'notInstalled' && st !== 'notInstalled') return false;
    if (ui.status === 'updates' && st !== 'updateAvailable') return false;
    if (ui.status === 'manual' && methodOf(e) !== 'manual' && methodOf(e) !== 'vendor') return false;
    if (ui.status === 'selected' && !inPlan(e)) return false;
    if (q && !`${e.displayName} ${e.publisher ?? ''} ${e.packageIdentifier ?? ''} ${e.description}`.toLowerCase().includes(q)) return false;
    return true;
  });
}

function select<T extends string>(label: string, testid: string, value: T, options: [string, string][], set: (v: T) => void): HTMLElement {
  return h(
    'label',
    { class: 'mgr-field' },
    h('span', {}, label),
    h('select', { 'data-testid': testid, onchange: (ev: Event) => { set((ev.target as HTMLSelectElement).value as T); draw(); } }, options.map(([v, t]) => h('option', { value: v, selected: v === value }, t))),
  );
}

function browse(): (HTMLElement | null)[] {
  const list = filtered();
  const publishers = [...new Set(CATALOG.map((e) => e.publisher).filter((p): p is string => !!p))].sort((a, b) => a.localeCompare(b));
  const groups = new Map<CatalogCategory, CatalogEntry[]>();
  for (const e of list) groups.set(e.category, [...(groups.get(e.category) ?? []), e]);
  const toolbar = h(
    'div',
    { class: 'mgr-toolbar', role: 'search' },
    h('label', { class: 'mgr-field grow' }, h('span', {}, 'Search'), h('input', { type: 'search', 'data-testid': 'mgr-search', value: ui.q, placeholder: 'Name, publisher or WinGet ID', oninput: (ev: Event) => { ui.q = (ev.target as HTMLInputElement).value; draw(); } })),
    select('Category', 'mgr-category', ui.category, [['', 'All categories'], ...Object.entries(CATALOG_CATEGORIES)], (v) => (ui.category = v as CatalogCategory | '')),
    select('Publisher', 'mgr-publisher', ui.publisher, [['', 'All publishers'], ...publishers.map((p): [string, string] => [p, p])], (v) => (ui.publisher = v)),
    select('Method', 'mgr-method', ui.method, [['', 'Any method'], ...Object.entries(METHOD_LABELS)], (v) => (ui.method = v as InstallMethod | '')),
    select('Status', 'mgr-status-filter', ui.status, [['all', 'Any status'], ['installed', 'Installed'], ['notInstalled', 'Not installed'], ['updates', 'Update available'], ['manual', 'Manual installation'], ['selected', 'Selected']], (v) => (ui.status = v)),
    select('Profile', 'mgr-profile-filter', ui.profileFilter, [['', 'Any profile'], ...allProfiles(ui.sel).map((p): [string, string] => [p.id, p.name])], (v) => (ui.profileFilter = v)),
  );
  const rows = [...groups].map(([cat, entries]) =>
    h(
      'section',
      { class: 'mgr-group', 'data-category': cat },
      h('h2', {}, `${CATALOG_CATEGORIES[cat]} (${entries.length})`),
      h(
        'div',
        { class: 'mgr-list' },
        entries.map((e) => {
          const m = matches.get(e.id);
          const on = inPlan(e);
          const origin = originText(e);
          return h(
            'article',
            { class: `mgr-app${on ? ' on' : ''}`, 'data-app': e.id },
            h('input', { type: 'checkbox', id: `pick-${e.id}`, 'data-pick': e.id, checked: on, 'aria-label': `Select ${e.displayName}`, onchange: (ev: Event) => togglePick(e, (ev.target as HTMLInputElement).checked) }),
            appLogo(e.id, e.displayName, e.category, 'md'),
            h(
              'label',
              { class: 'mgr-app-main', for: `pick-${e.id}` },
              h('strong', {}, e.displayName),
              e.publisher ? h('span', { class: 'muted' }, ` · ${e.publisher}`) : null,
              h('span', { class: 'mgr-desc' }, e.description),
              origin ? h('span', { class: 'mgr-origin' }, origin) : null,
              e.hardware ? h('span', { class: 'mgr-origin' }, `For: ${e.hardware.requirement}`) : null,
            ),
            h('div', { class: 'mgr-app-meta' }, stateBadge(m, e), badge(METHOD_LABELS[methodOf(e)], methodOf(e) === 'manual' || methodOf(e) === 'vendor' ? 'manual' : ''), e.packageIdentifier ? h('code', { class: 'mgr-id' }, e.packageIdentifier) : null),
          );
        }),
      ),
    ),
  );
  const pv = installPreview(plan.packages, matches);
  const bar = h(
    'div',
    { class: 'mgr-planbar', 'data-testid': 'mgr-planbar' },
    h('span', { 'data-testid': 'mgr-plan-count' }, `${plan.packages.length} selected: ${pv.queue.length} to install${pv.alreadyInstalled.length ? `, ${pv.alreadyInstalled.length} already installed` : ''}${pv.manual.length ? `, ${pv.manual.length} manual` : ''}`),
    btn('Review installation…', { class: 'btn primary', 'data-action': 'mgr-review-install', disabled: !plan.packages.length, onclick: () => openInstallReview() }),
  );
  return [toolbar, h('p', { class: 'muted', 'data-testid': 'mgr-result-count' }, `${list.length} of ${CATALOG.length} applications`), ...rows, bar];
}

function openInstallReview(): void {
  ui.review = { kind: 'install', accepted: new Set() };
  const pv = installPreview(plan.packages, matches);
  if (connected() && pv.queue.length) void refresh(() => api.validate(pv.queue.map((q) => ({ id: q.id, source: q.source }))));
  draw();
  window.scrollTo({ top: 0 });
}

function installReview(r: Extract<Review, { kind: 'install' }>): HTMLElement {
  const pv: InstallPreview = installPreview(plan.packages, matches, ui.agent?.validation ?? {}, ui.agent?.settings.acceptSourceAgreements);
  const needAccept = pv.queue.filter((q) => q.agreements && !r.accepted.has(q.key));
  const ready = connected() && queueReady(pv.queue) && !needAccept.length && !busy();
  const sim = !!ui.agent?.settings.dryRun;
  return h(
    'section',
    { class: 'mgr-review', 'data-testid': 'mgr-review-install', 'aria-labelledby': 'rv-title' },
    h('h2', { id: 'rv-title' }, `Review: install ${pv.queue.length} application(s)${sim ? ' (simulation)' : ''}`),
    h('p', {}, 'Each one is installed in turn with its exact WinGet identifier, then checked independently. One failure does not stop the others. Licence prompts are never accepted for you.'),
    pv.queue.length
      ? h(
          'ol',
          { class: 'mgr-queue', 'data-testid': 'mgr-queue' },
          pv.queue.map((q) =>
            h(
              'li',
              { 'data-queue': q.id, 'data-availability': q.availability },
              h('div', { class: 'mgr-q-head' }, h('strong', {}, q.name), ' ', badge(q.availability === 'notChecked' ? 'Not checked' : AVAILABILITY_LABELS[q.availability], q.availability === 'available' ? 'ok' : q.availability === 'checking' || q.availability === 'notChecked' ? '' : 'err', { 'data-testid': 'mgr-availability' })),
              h('div', { class: 'muted' }, `${q.source === 'msstore' ? 'Microsoft Store' : 'WinGet community repository'} · ${q.id} · ${q.privileges}`),
              q.dependencies.length ? h('div', {}, `Installed after: ${q.dependencies.join(', ')}`) : null,
              q.notes.map((n) => h('p', { class: 'mgr-note' }, n)),
              ui.agent?.validation[`${q.source}:${q.id}`.toLowerCase()]?.detail ? h('p', { class: 'mgr-note' }, ui.agent.validation[`${q.source}:${q.id}`.toLowerCase()]!.detail) : null,
              q.agreements
                ? h(
                    'label',
                    { class: 'check-inline' },
                    h('input', { type: 'checkbox', 'data-accept': q.id, checked: r.accepted.has(q.key), onchange: (ev: Event) => { if ((ev.target as HTMLInputElement).checked) r.accepted.add(q.key); else r.accepted.delete(q.key); draw(); } }),
                    h('span', {}, `I have read ${q.name}'s licence agreement ("winget show --id ${q.id}") and accept it.`),
                  )
                : null,
              h('code', { class: 'mgr-cmd' }, r.accepted.has(q.key) ? q.command.replace(' --disable-interactivity', ' --accept-package-agreements --disable-interactivity') : q.command),
            ),
          ),
        )
      : h('p', {}, 'Nothing to install automatically.'),
    pv.manual.length
      ? h('div', { 'data-testid': 'mgr-review-manual' }, h('h3', {}, 'Manual installation (not run by the manager)'), h('ul', {}, pv.manual.map((m) => h('li', {}, h('strong', {}, m.name), ` — ${m.reason} `, m.instructions, m.url ? h('span', {}, ' ', h('a', { href: m.url, target: '_blank', rel: 'noopener noreferrer' }, 'Publisher instructions')) : null))))
      : null,
    pv.alreadyInstalled.length ? h('div', { 'data-testid': 'mgr-review-installed' }, h('h3', {}, 'Already installed (skipped)'), h('p', {}, pv.alreadyInstalled.map((x) => `${x.name}${x.version ? ` ${x.version}` : ''}`).join(', '))) : null,
    pv.blocked.length ? h('div', {}, h('h3', {}, 'Cannot be installed'), h('ul', {}, pv.blocked.map((b) => h('li', {}, `${b.name}: ${b.reason}`)))) : null,
    !connected() ? h('p', { class: 'mgr-note' }, 'Start the Application Manager on this computer to install.') : needAccept.length ? h('p', { class: 'mgr-note' }, `Accept or remove the licence of: ${needAccept.map((q) => q.name).join(', ')}.`) : !queueReady(pv.queue) && pv.queue.length ? h('p', { class: 'mgr-note', 'data-testid': 'mgr-not-ready' }, 'Every application must be found in its source before installing. Items that are not available stay unticked in Browse; remove them or try again later.') : null,
    h(
      'div',
      { class: 'mgr-actions' },
      btn('Back', { 'data-action': 'mgr-back', onclick: () => { ui.review = null; draw(); } }),
      btn('Check again', { 'data-action': 'mgr-revalidate', disabled: !connected() || !pv.queue.length, onclick: () => void refresh(() => api.validate(pv.queue.map((q) => ({ id: q.id, source: q.source })))) }),
      btn(sim ? `Simulate ${pv.queue.length} installation(s)` : `Install ${pv.queue.length} application(s)`, {
        class: 'btn primary',
        'data-action': 'mgr-confirm-install',
        disabled: !ready,
        onclick: () => void startBatch('install', pv.queue.map((q) => spec(q.id, q.source, q.name, { catalogId: q.catalogId, scope: q.scope, version: q.version, acceptPackageAgreements: r.accepted.has(q.key) }))),
      }),
    ),
  );
}

// ------------------------------------------------------------------------------------------------
// Installed
// ------------------------------------------------------------------------------------------------

/**
 * Everything the inventory found, from installedView: catalog applications, other WinGet packages,
 * and other programs Windows lists. Phase 10 fix: the other programs used to sit in a <details>
 * element whose "open" state the next background refresh removed (the list vanished), and only
 * the first 500 were drawn. Now every row is drawn, the group and search are page state, and a
 * refresh keeps the last list on screen until a complete new one arrives.
 */
function installed(): (HTMLElement | null)[] {
  const inv = ui.agent?.inventory;
  const scanning = !!ui.agent?.scanning;
  const scan = btn(scanning ? 'Scanning…' : inv ? 'Scan again' : 'Scan this computer', { 'data-action': 'mgr-scan', disabled: !connected() || scanning, onclick: () => void refresh(() => api.scan('inventory')) });
  if (!inv)
    return [h('p', { 'data-testid': 'mgr-inv-status', role: 'status' }, connected() ? (scanning ? 'Scanning this computer… (WinGet and the Windows uninstall records)' : 'Not scanned yet.') : 'Start the Application Manager on this computer to see what is installed.'), scan];
  const view = installedCache;
  const q = ui.instQ.trim().toLowerCase();
  const shown = view.rows.filter((r) => (ui.instGroup === 'all' || r.kind === ui.instGroup) && (!q || `${r.name} ${r.id} ${r.publisher}`.toLowerCase().includes(q)));
  const picked = view.rows.filter((r) => ui.removePick.has(r.key) && r.id);
  const groups: [typeof ui.instGroup, string, number][] = [
    ['all', 'All', view.counts.total],
    ['catalog', 'In the catalog', view.counts.catalog],
    ['winget', 'Other WinGet packages', view.counts.winget],
    ['other', 'Other programs', view.counts.other],
  ];
  const updatesById = new Map((ui.agent?.updates?.items ?? []).map((u) => [u.id.toLowerCase(), u]));
  return [
    h(
      'div',
      { class: 'mgr-toolbar' },
      h('p', { class: 'muted grow', 'data-testid': 'mgr-inv-meta', role: 'status' }, `Scanned ${new Date(inv.scannedUtc).toLocaleString()} (${inv.method}).`, scanning ? h('strong', { 'data-testid': 'mgr-inv-rescanning' }, ' Scanning again… this list stays until the new scan is complete.') : null),
      scan,
    ),
    inv.note ? h('p', { class: 'mgr-banner warn', 'data-testid': 'mgr-inv-note' }, inv.note) : null,
    h(
      'p',
      { class: 'muted', 'data-testid': 'mgr-inv-summary' },
      `${view.counts.catalog + view.counts.winget} packages WinGet reports as installed (${view.counts.catalog} in the catalog, ${view.counts.winget} others) and ${view.counts.other} other programs Windows lists. `,
      'Only WinGet packages can be updated or removed here; other programs need their own installer or Settings > Apps.',
      view.linked ? null : ' Programs could not be linked to WinGet packages in this scan, so some may be listed twice.',
    ),
    h(
      'div',
      { class: 'mgr-toolbar' },
      h('div', { class: 'mgr-seg', role: 'group', 'aria-label': 'Show' }, groups.map(([g, label, n]) => h('button', { type: 'button', class: 'btn sm', 'data-inst-group': g, 'aria-pressed': String(ui.instGroup === g), onclick: () => { ui.instGroup = g; draw(); } }, `${label} (${n})`))),
      h('label', { class: 'mgr-field grow' }, h('span', {}, 'Search installed'), h('input', { type: 'search', 'data-testid': 'mgr-inst-search', value: ui.instQ, placeholder: 'Name, publisher or WinGet ID', oninput: (ev: Event) => { ui.instQ = (ev.target as HTMLInputElement).value; draw(); } })),
    ),
    h('p', { class: 'muted', 'data-testid': 'mgr-inst-count' }, `Showing ${shown.length} of ${view.counts.total}.`),
    h(
      'table',
      { class: 'mgr-table', 'data-testid': 'mgr-installed' },
      h('thead', {}, h('tr', {}, ['', 'Application', 'Version', 'Publisher', 'WinGet ID', 'Update', 'Found by', 'Removal'].map((t) => h('th', { scope: 'col' }, t)))),
      h(
        'tbody',
        {},
        shown.map((r) => {
          const pol = r.id ? removalPreview({ id: r.id, version: r.version, source: r.source }, matches) : null;
          const up = r.id ? updatesById.get(r.id.toLowerCase()) : undefined;
          return h(
            'tr',
            { 'data-installed': r.key, 'data-kind': r.kind },
            h('td', {}, pol ? h('input', { type: 'checkbox', 'aria-label': `Select ${r.name} for removal`, 'data-remove-pick': r.key, checked: ui.removePick.has(r.key), disabled: !pol.allowed, title: pol.allowed ? '' : pol.reason, onchange: (ev: Event) => { if ((ev.target as HTMLInputElement).checked) ui.removePick.add(r.key); else ui.removePick.delete(r.key); draw(); } }) : null),
            h('td', {}, r.catalogId ? appLogo(r.catalogId, r.name, undefined, 'sm') : null, ' ', r.name, r.match?.state === 'uncertain' ? badge('Detected by name', 'warn', { title: 'Not matched to a WinGet package: updates and removal may need the program\'s own tools.' }) : null),
            h('td', {}, r.version || '—'),
            h('td', {}, r.publisher || '—'),
            h('td', {}, r.id ? h('code', {}, r.id) : '—'),
            h('td', {}, !r.id ? '—' : up ? `${up.available}${bulkEligible(up) ? '' : ' (individually)'}` : ui.agent?.updates ? 'None listed' : 'Not checked'),
            h('td', {}, r.origin),
            h('td', {}, pol ? badge(pol.level === 'blocked' ? 'Protected' : pol.level === 'caution' ? 'Extra confirmation' : 'Removable', pol.level === 'blocked' ? 'err' : pol.level === 'caution' ? 'warn' : '', { title: pol.reason }) : 'Its own uninstaller'),
          );
        }),
      ),
    ),
    h(
      'div',
      { class: 'mgr-actions' },
      btn(`Remove selected (${picked.length})…`, {
        'data-action': 'mgr-review-remove',
        disabled: !picked.length || !connected(),
        onclick: () => {
          ui.review = { kind: 'uninstall', items: picked.map((r) => removalPreview({ id: r.id, version: r.version, source: r.source === 'msstore' ? 'msstore' : 'winget' }, matches)), caution: new Set(), word: '' };
          draw();
          window.scrollTo({ top: 0 });
        },
      }),
    ),
  ];
}

function uninstallReview(r: Extract<Review, { kind: 'uninstall' }>): HTMLElement {
  const bulk = r.items.length > 1;
  const notBulk = bulk ? r.items.filter((x) => !bulkRemovable(x)) : [];
  const needCaution = r.items.filter((x) => x.level === 'caution' && !r.caution.has(x.id));
  const blocked = r.items.filter((x) => !x.allowed);
  const sim = !!ui.agent?.settings.dryRun;
  const ready = connected() && !busy() && r.word === 'REMOVE' && !needCaution.length && !notBulk.length && !blocked.length;
  return h(
    'section',
    { class: 'mgr-review', 'data-testid': 'mgr-review-uninstall' },
    h('h2', {}, `Review: remove ${r.items.length} application(s)${sim ? ' (simulation)' : ''}`),
    h('p', {}, 'WinGet runs each publisher\'s own uninstaller. Your documents, settings and application data are not deleted. Unticking an application in a profile never removes it; only this confirmation does.'),
    h(
      'ul',
      { class: 'mgr-queue' },
      r.items.map((x) =>
        h(
          'li',
          { 'data-remove': x.id },
          h('div', { class: 'mgr-q-head' }, h('strong', {}, x.name), ` ${x.version}`, ' ', badge(x.level === 'blocked' ? 'Protected' : x.level === 'caution' ? 'Extra confirmation' : 'Removable', x.level === 'normal' ? '' : x.level === 'caution' ? 'warn' : 'err')),
          x.reason ? h('p', { class: 'mgr-note' }, x.reason) : null,
          h('p', {}, x.restart),
          x.risks.map((t) => h('p', { class: 'mgr-note' }, t)),
          h('code', { class: 'mgr-cmd' }, x.command),
          x.level === 'caution' && !bulk
            ? h('label', { class: 'check-inline' }, h('input', { type: 'checkbox', 'data-caution': x.id, checked: r.caution.has(x.id), onchange: (ev: Event) => { if ((ev.target as HTMLInputElement).checked) r.caution.add(x.id); else r.caution.delete(x.id); draw(); } }), h('span', {}, `I understand the risk of removing ${x.name}.`))
            : null,
        ),
      ),
    ),
    notBulk.length ? h('p', { class: 'mgr-note', 'data-testid': 'mgr-not-bulk' }, `Remove ${notBulk.map((x) => x.name).join(', ')} on its own: security software, drivers, device software and programs outside the catalog are never removed in bulk.`) : null,
    h('label', { class: 'mgr-field' }, h('span', {}, 'Type REMOVE to confirm'), h('input', { type: 'text', 'data-testid': 'mgr-remove-word', value: r.word, autocomplete: 'off', oninput: (ev: Event) => { r.word = (ev.target as HTMLInputElement).value; draw(); } })),
    h(
      'div',
      { class: 'mgr-actions' },
      btn('Back', { 'data-action': 'mgr-back', onclick: () => { ui.review = null; draw(); } }),
      btn(sim ? 'Simulate removal' : `Remove ${r.items.length} application(s)`, {
        class: 'btn danger',
        'data-action': 'mgr-confirm-remove',
        disabled: !ready,
        onclick: () => {
          const items = r.items.map((x) => spec(x.id, catalogEntryForPackage(x.id)?.source ?? 'winget', x.name, { catalogId: catalogEntryForPackage(x.id)?.id, installedVersion: x.version, confirmCaution: r.caution.has(x.id) }));
          ui.removePick.clear();
          void startBatch('uninstall', items, 'REMOVE');
        },
      }),
    ),
  );
}

// ------------------------------------------------------------------------------------------------
// Updates
// ------------------------------------------------------------------------------------------------

/** Can be chosen for an individual update: read consistently, a known installed version, a newer one available. */
const selectable = (u: UpdateItem) => !updateIssue(u) && !u.truncated && !!u.available && !/^(unknown|<)/i.test(u.installed) && compareVersions(u.available, u.installed) > 0;

function updates(): (HTMLElement | null)[] {
  const up = ui.agent?.updates;
  const checking = !!ui.agent?.checking;
  const items = up?.items ?? [];
  // Phase 10 fix: eligibility is the agent's decision confirmed by the page's own rules (bulkEligible).
  const eligible = items.filter(bulkEligible);
  const picked = items.filter((u) => ui.picked.has(u.id) && selectable(u));
  return [
    h(
      'div',
      { class: 'mgr-explain' },
      h('p', {}, 'Like "apt update" then "apt upgrade": first refresh the package source and list what has a newer version (nothing changes), then choose what to update. ', h('strong', {}, 'WinGet is not APT: '), 'it can only update programs it matches to a package, it cannot always tell the installed version, and each publisher\'s installer does the work. The manager never updates anything because it was opened.'),
      h('p', { class: 'muted' }, 'Updates run one package at a time ("winget upgrade --id … --exact"), so each result is recorded. Packages with an unknown installed version, a shortened identifier, WinGet itself, or whose publisher asks to update them only on their own are left out of "Update all eligible".'),
    ),
    h(
      'div',
      { class: 'mgr-toolbar' },
      btn(checking ? 'Checking…' : 'Check for updates', { class: 'btn primary', 'data-action': 'mgr-check-updates', disabled: !connected() || checking || busy(), onclick: () => void refresh(() => api.scan('updates')) }),
      up ? h('span', { class: 'muted grow', 'data-testid': 'mgr-updates-meta' }, `Last checked ${new Date(up.finishedUtc).toLocaleString()}.`, checking ? ' Checking again… the list below is from the last check.' : '') : h('span', { class: 'muted grow' }, checking ? 'Checking…' : 'Not checked yet.'),
    ),
    up && up.status !== 'ok'
      ? h('div', { class: 'mgr-banner warn', 'data-testid': 'mgr-updates-status', role: 'status' }, h('p', {}, up.note), up.problems?.length ? h('ul', {}, up.problems.slice(0, 5).map((t) => h('li', {}, t))) : null)
      : null,
    items.length
      ? h(
          'table',
          { class: 'mgr-table', 'data-testid': 'mgr-updates' },
          h('thead', {}, h('tr', {}, ['', 'Application', 'Installed', 'Available', 'Source', 'Eligible'].map((t) => h('th', { scope: 'col' }, t)))),
          h(
            'tbody',
            {},
            items.map((u) => {
              const ok = bulkEligible(u);
              const why = updateReason(u);
              return h(
                'tr',
                { 'data-update': u.id, 'data-eligible': String(ok), 'data-readable': String(!updateIssue(u)) },
                h('td', {}, h('input', { type: 'checkbox', 'aria-label': `Select ${u.name}`, 'data-update-pick': u.id, checked: ui.picked.has(u.id), disabled: !selectable(u), onchange: (ev: Event) => { if ((ev.target as HTMLInputElement).checked) ui.picked.add(u.id); else ui.picked.delete(u.id); draw(); } })),
                h('td', {}, u.name, ' ', h('code', {}, u.id)),
                h('td', { 'data-col': 'installed' }, u.installed),
                h('td', { 'data-col': 'available' }, u.available || '—'),
                h('td', { 'data-col': 'source' }, u.source),
                h('td', {}, ok ? badge('Yes', 'ok') : badge(updateIssue(u) ? 'Could not read' : selectable(u) ? 'Only on its own' : 'No', updateIssue(u) ? 'err' : 'warn', { title: why }), ok ? null : h('span', { class: 'muted' }, ` ${why}`)),
              );
            }),
          ),
        )
      : up && up.status === 'ok'
        ? h('p', { 'data-testid': 'mgr-up-to-date' }, 'Everything WinGet can match is up to date.')
        : null,
    h(
      'div',
      { class: 'mgr-actions' },
      btn(`Update selected (${picked.length})…`, { 'data-action': 'mgr-update-selected', disabled: !picked.length || !connected() || busy(), onclick: () => { ui.review = { kind: 'upgrade', items: picked, all: false }; draw(); } }),
      btn(`Update All Eligible Applications (${eligible.length})…`, { class: 'btn primary', 'data-action': 'mgr-update-all', disabled: !eligible.length || !connected() || busy(), onclick: () => { ui.review = { kind: 'upgrade', items: eligible, all: true }; draw(); } }),
    ),
  ];
}

function upgradeReview(r: Extract<Review, { kind: 'upgrade' }>): HTMLElement {
  const sim = !!ui.agent?.settings.dryRun;
  const left = r.all ? (ui.agent?.updates?.items ?? []).filter((u) => !bulkEligible(u)) : [];
  return h(
    'section',
    { class: 'mgr-review', 'data-testid': 'mgr-review-upgrade' },
    h('h2', {}, `Review: ${r.all ? 'update all eligible' : 'update selected'} — ${r.items.length} application(s)${sim ? ' (simulation)' : ''}`),
    h('p', {}, 'Each package is updated on its own with its publisher\'s installer. Close the applications first; an installer may restart one that is open. One failure does not stop the others.'),
    h('ol', { class: 'mgr-queue' }, r.items.map((u) => h('li', { 'data-upgrade': u.id }, h('strong', {}, u.name), ` ${u.installed} → ${u.available}`, h('code', { class: 'mgr-cmd' }, commandLine(wingetArguments('upgrade', u.id, u.source === 'msstore' ? 'msstore' : 'winget', { acceptSourceAgreements: ui.agent?.settings.acceptSourceAgreements })))))),
    left.length ? h('div', { 'data-testid': 'mgr-upgrade-excluded' }, h('h3', {}, 'Not included'), h('ul', {}, left.map((u) => h('li', {}, `${u.name}: ${updateReason(u)}`)))) : null,
    h(
      'div',
      { class: 'mgr-actions' },
      btn('Back', { 'data-action': 'mgr-back', onclick: () => { ui.review = null; draw(); } }),
      btn(sim ? `Simulate ${r.items.length} update(s)` : `Update ${r.items.length} application(s)`, {
        class: 'btn primary',
        'data-action': 'mgr-confirm-upgrade',
        disabled: !connected() || busy(),
        onclick: () => {
          ui.picked.clear();
          void startBatch('upgrade', r.items.map((u) => spec(u.id, u.source, u.name, { catalogId: catalogEntryForPackage(u.id)?.id, installedVersion: u.installed })));
        },
      }),
    ),
  );
}

// ------------------------------------------------------------------------------------------------
// Profiles
// ------------------------------------------------------------------------------------------------

function profiles(): (HTMLElement | null)[] {
  const all = allProfiles(ui.sel);
  const count = (p: AppProfile) => `${expandProfile(p.id, all).length} selected${p.optional?.length ? `, ${p.optional.length} recommended` : ''}`;
  const card = (p: AppProfile, custom: boolean) =>
    h(
      'li',
      { class: 'mgr-profile', 'data-profile': p.id },
      h('label', { class: 'check-inline' }, h('input', { type: 'checkbox', 'data-profile-toggle': p.id, checked: ui.sel.selectedProfiles.includes(p.id), onchange: (ev: Event) => { toggleProfile(ui.sel, p.id, (ev.target as HTMLInputElement).checked); changed(); } }), h('strong', {}, p.name)),
      h('span', { class: 'muted' }, ` ${count(p)}`),
      p.description ? h('p', { class: 'mgr-desc' }, p.description) : null,
      custom
        ? h(
            'div',
            { class: 'mgr-actions' },
            btn('Rename', { class: 'btn ghost sm', onclick: () => { const n = prompt('New name', p.name); if (n && renameProfile(ui.sel, p.id, n)) changed(); } }),
            btn('Export', { class: 'btn ghost sm', onclick: () => download(`${p.name.replace(/[^A-Za-z0-9 _-]/g, '').trim() || 'profile'}.app-profile.json`, exportAppProfiles([p]), 'application/json') }),
            btn('Delete', { class: 'btn ghost sm', 'data-action': 'mgr-profile-delete', onclick: () => { if (confirm(`Delete the profile "${p.name}"? Installed applications are not affected.`) && deleteProfile(ui.sel, p.id)) changed(); } }),
          )
        : null,
    );
  const fileInput = h('input', {
    type: 'file',
    accept: '.json,application/json',
    hidden: true,
    'data-testid': 'mgr-import-input',
    onchange: async (ev: Event) => {
      const f = (ev.target as HTMLInputElement).files?.[0];
      if (!f) return;
      const r = importAppProfiles(await f.text(), ui.sel.profiles, f.name);
      if (!r.ok) return say('error', `Could not import ${f.name}: ${r.errors.join(' ')}`);
      ui.sel.profiles.push(...r.profiles);
      changed();
      say('info', `Imported ${r.profiles.map((p) => `"${p.name}"`).join(', ')}. Tick it to use it.${r.warnings.length ? ` ${r.warnings.join(' ')}` : ''}`);
    },
  });
  const overrides = ui.sel.added.length + ui.sel.removed.length;
  return [
    h('p', {}, 'Profiles stack: tick several and each application is selected once, showing every profile that chose it. Built-in profiles never change; your changes are kept as additions and removals, or saved as your own profile. Changing a profile never removes installed software.'),
    usesEarlierProfiles(ui.sel)
      ? h(
          'p',
          { class: 'mgr-notice', 'data-testid': 'mgr-legacy-profiles' },
          'This selection was saved before the built-in profiles were rebuilt, so its profiles still select what they did then. ',
          btn('Use the new profile defaults', { class: 'btn sm', 'data-action': 'mgr-adopt-profiles', onclick: () => { if (confirm('Use the new built-in profile defaults? Your ticked profiles and individual changes stay; installed software is not changed.')) { adoptCurrentProfiles(ui.sel); changed(); } } }),
        )
      : null,
    h('h2', {}, 'Built-in profiles'),
    h('ul', { class: 'mgr-profiles' }, builtinProfiles(selectionRevision(ui.sel)).map((p) => card(p, false))),
    h('h2', {}, 'Your profiles'),
    ui.sel.profiles.length ? h('ul', { class: 'mgr-profiles' }, ui.sel.profiles.map((p) => card(p, true))) : h('p', { class: 'muted' }, 'None yet.'),
    h(
      'div',
      { class: 'mgr-toolbar' },
      h('label', { class: 'mgr-field grow' }, h('span', {}, 'Save the current selection as a profile'), h('input', { type: 'text', 'data-testid': 'mgr-new-profile', value: ui.newProfileName, placeholder: 'Profile name', oninput: (ev: Event) => { ui.newProfileName = (ev.target as HTMLInputElement).value; } })),
      btn('Save as new profile', { 'data-action': 'mgr-profile-save', disabled: !plan.packages.length, onclick: () => { const p = saveAsNewProfile(ui.sel, ui.newProfileName || 'My applications'); ui.newProfileName = ''; changed(); say('info', `Saved "${p.name}"; it is ticked and reproduces this selection.`); } }),
      btn('New empty profile', { class: 'btn ghost', onclick: () => { createProfile(ui.sel, ui.newProfileName || 'New profile'); ui.newProfileName = ''; changed(); } }),
      btn('Import…', { 'data-action': 'mgr-profile-import', onclick: () => fileInput.click() }),
      btn('Export all', { disabled: !ui.sel.profiles.length, onclick: () => download('application-profiles.json', exportAppProfiles(ui.sel.profiles), 'application/json') }),
      fileInput,
    ),
    h(
      'section',
      { class: 'mgr-combined', 'data-testid': 'mgr-combined' },
      h('h2', {}, `Combined selection: ${plan.packages.length} application(s)`),
      overrides ? h('p', {}, `${ui.sel.added.length} added and ${ui.sel.removed.length} unticked by you. `, btn('Undo my changes', { class: 'btn ghost sm', 'data-action': 'mgr-reset-overrides', onclick: () => { resetOverrides(ui.sel); changed(); } })) : null,
      h('ul', {}, plan.packages.map((p) => h('li', { 'data-combined': p.key }, p.displayName, h('span', { class: 'muted' }, ` — ${p.origins.map((o) => (o === 'added' ? 'added by you' : o === 'required' ? 'required' : nameOfProfile(o))).join(', ')}`)))),
    ),
  ];
}

// ------------------------------------------------------------------------------------------------
// History
// ------------------------------------------------------------------------------------------------

function historyTab(): (HTMLElement | null)[] {
  const recs = [...ui.history].reverse();
  const dl = (format: 'csv' | 'html' | 'json') =>
    btn(format.toUpperCase(), {
      'data-action': `mgr-report-${format}`,
      disabled: !connected(),
      onclick: () => void attempt(async () => {
        const body = await api.report(format);
        download(`application-manager-${format === 'html' ? 'report.html' : `history.${format}`}`, typeof body === 'string' ? body : JSON.stringify(body, null, 2), format === 'csv' ? 'text/csv' : format === 'html' ? 'text/html' : 'application/json');
      }),
    });
  return [
    h('div', { class: 'mgr-toolbar' }, h('p', { class: 'muted grow' }, 'Every operation is recorded on this computer (history.jsonl, a versioned format). No passwords or application data are stored.'), h('span', {}, 'Export: '), dl('csv'), dl('html'), dl('json'), btn('Refresh', { disabled: !connected(), onclick: () => void attempt(async () => { ui.history = (await api.history()).records; draw(); }) })),
    recs.length
      ? h(
          'table',
          { class: 'mgr-table', 'data-testid': 'mgr-history' },
          h('thead', {}, h('tr', {}, ['When', 'Action', 'Application', 'Before', 'After', 'Result', 'Verified', 'Exit code', ''].map((t) => h('th', { scope: 'col' }, t)))),
          h(
            'tbody',
            {},
            recs.map((r) =>
              h(
                'tr',
                { 'data-history': r.operationId, 'data-result': r.result },
                h('td', {}, new Date(r.finishedUtc).toLocaleString()),
                h('td', {}, r.action),
                h('td', {}, r.name || r.packageId, ' ', h('code', {}, r.packageId)),
                h('td', {}, r.priorVersion || '—'),
                h('td', {}, r.resultVersion || '—'),
                h('td', {}, RESULT_LABELS[r.result] ?? r.result, r.attempt > 1 ? ` (attempt ${r.attempt})` : '', r.restartRequired ? ' · restart' : ''),
                h('td', {}, r.verification),
                h('td', {}, h('code', {}, r.exitCode)),
                h('td', {}, r.retryable ? btn('Retry', { class: 'btn ghost sm', disabled: busy(), onclick: () => void retryRecords([r]) }) : null),
              ),
            ),
          ),
        )
      : h('p', { class: 'muted' }, connected() ? 'No operations yet.' : 'Start the Application Manager on this computer to see its history.'),
  ];
}

// ------------------------------------------------------------------------------------------------
// Page
// ------------------------------------------------------------------------------------------------

function content(): (HTMLElement | null)[] {
  const r = ui.review;
  if (r?.kind === 'install') return [installReview(r)];
  if (r?.kind === 'uninstall') return [uninstallReview(r)];
  if (r?.kind === 'upgrade') return [upgradeReview(r)];
  switch (ui.tab) {
    case 'browse': return browse();
    case 'installed': return installed();
    case 'updates': return updates();
    case 'profiles': return profiles();
    case 'history': return historyTab();
  }
}

function draw(): void {
  render(root, (into) => {
    into.append(
      header(),
      ...banners().filter((b): b is HTMLElement => !!b),
      ...[batchPanel()].filter((b): b is HTMLElement => !!b),
      h(
        'nav',
        { class: 'mgr-tabs', role: 'tablist', 'aria-label': 'Application Manager' },
        TABS.map((t) =>
          h('button', {
            type: 'button', role: 'tab', class: 'mgr-tab', 'data-tab': t.id, 'aria-selected': String(ui.tab === t.id && !ui.review), 'aria-controls': 'mgr-panel',
            onclick: () => {
              ui.tab = t.id;
              ui.review = null;
              if (t.id === 'history' && connected()) void attempt(async () => { ui.history = (await api.history()).records; draw(); });
              draw();
            },
          }, t.label, t.id === 'updates' && ui.agent?.updates?.items.length ? h('span', { class: 'mgr-count' }, String(ui.agent.updates.items.length)) : null),
        ),
      ),
      h('main', { id: 'mgr-panel', class: 'mgr-panel', role: 'tabpanel', 'data-panel': ui.review ? `review-${ui.review.kind}` : ui.tab }, content()),
    );
  });
}

function setTheme(): void {
  try {
    const t = localStorage.getItem('wdb.theme');
    if (t === 'light' || t === 'dark' || t === 'system') document.documentElement.dataset.theme = t;
  } catch {
    /* preference only */
  }
}

setTheme();
if (!hasToken()) ui.conn = 'none';
recompute();
draw();
void poll();
