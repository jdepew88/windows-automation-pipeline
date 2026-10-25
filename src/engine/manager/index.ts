import { CATALOG, CATALOG_UPDATED, entryKey, methodOf, type CatalogEntry, type RemovalSafety } from '../applications/catalog';
import type { PlannedPackage } from '../applications/selection';

/**
 * The standalone Application Manager (Phase 10B/10C): what the page shows and asks the local agent
 * (AppManager.ps1) to do. Everything here is pure, so the same rules are tested without WinGet:
 *
 *   - catalogPolicy()     removal and upgrade rules the agent enforces again on its side;
 *   - matchInventory()    which catalog applications WinGet (or Windows) reports as installed;
 *   - wingetArguments()   the exact command for an operation (mirror of Get-WamArguments);
 *   - installPreview()    the queue the user confirms before anything runs;
 *   - removalPreview()    what removing an application means, and whether it is allowed.
 *
 * The page never sends a command line: it sends an action and package identifiers, and the agent
 * builds the arguments itself from a fixed list.
 */

export const MANAGER_NAME = 'Windows Deployment — Application Manager';
export const MANAGER_VERSION = '1.0.0';
export const POLICY_FORMAT = 'windows-deployment-builder/app-manager-policy';
export const HISTORY_FORMAT = 'windows-deployment-builder/app-manager-operation';
export const MANAGER_PROFILES_FORMAT = 'windows-deployment-builder/app-manager-selection';

export type Action = 'install' | 'upgrade' | 'uninstall';
export type Source = 'winget' | 'msstore';

/** Same patterns as the Phase 5 engine ($script:WingetId / $script:StoreId), which the agent reuses. */
export const WINGET_ID = /^(?=.{3,128}$)[A-Za-z0-9][A-Za-z0-9_+-]{0,31}(?:\.[A-Za-z0-9_+-]{1,32}){1,7}$/;
export const STORE_ID = /^(?:9[A-Z0-9]{11}|XP[A-Z0-9]{12})$/;
export const VERSION = /^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$/;

/** Never removed, whatever the catalog says (same list as $script:WamProtected in AppManager.ps1). */
export const PROTECTED_PATTERNS: readonly RegExp[] = [
  /^Microsoft\.Edge(\..*)?$/i, /^Microsoft\.EdgeWebView2Runtime$/i, /^Microsoft\.VCRedist\./i, /^Microsoft\.VCLibs\./i, /^Microsoft\.UI\.Xaml\./i,
  /^Microsoft\.DotNet\./i, /^Microsoft\.WindowsAppRuntime\./i, /^Microsoft\.DirectX$/i, /^Microsoft\.AppInstaller$/i, /^Microsoft\.WindowsTerminal$/i,
  /^Microsoft\.DesktopAppInstaller$/i, /Driver/i, /^Intel\./i, /^AMD\./i, /^Nvidia\./i,
];

// ------------------------------------------------------------------------------------------------
// Policy (written next to the agent as catalog-policy.json)
// ------------------------------------------------------------------------------------------------

export interface PolicyEntry {
  id: string;
  catalogId: string;
  name: string;
  removal: RemovalSafety;
  upgrade: 'winget' | 'explicit' | 'manual';
  kind: string;
}

export function catalogPolicy(entries: readonly CatalogEntry[] = CATALOG) {
  const packages: PolicyEntry[] = [];
  for (const e of entries) {
    if (!e.packageIdentifier) continue;
    for (const id of [e.packageIdentifier, ...(e.alternateIds ?? [])])
      packages.push({ id, catalogId: e.id, name: e.displayName, removal: e.removal ?? 'normal', upgrade: e.upgrade ?? 'winget', kind: e.kind ?? 'application' });
  }
  return { format: POLICY_FORMAT, version: 1, catalogUpdated: CATALOG_UPDATED, packages };
}

// ------------------------------------------------------------------------------------------------
// What the agent reports
// ------------------------------------------------------------------------------------------------

export interface InventoryPackage { id: string; version: string; source: string }
export interface InventoryProgram { name: string; version: string; publisher: string; scope: string }
export interface Inventory { scannedUtc: string; method: string; note: string; packages: InventoryPackage[]; programs: InventoryProgram[] }

export interface UpdateItem {
  id: string; name: string; installed: string; available: string; source: string;
  eligible: boolean; reason: string; explicit: boolean; truncated: boolean;
}
export type CheckStatus = 'ok' | 'networkUnavailable' | 'sourceUnavailable';
export interface Updates { checkedUtc: string; finishedUtc: string; status: CheckStatus; exitCode: string; items: UpdateItem[]; note: string }

export type Availability = 'checking' | 'available' | 'notFound' | 'networkUnavailable' | 'sourceUnavailable' | 'agreementRequired' | 'invalid';
export interface ValidationResult { status: Availability; version?: string; agreements?: boolean; exitCode?: string; detail: string }

export type OperationResult = 'Succeeded' | 'AlreadyInstalled' | 'UpToDate' | 'RequiresRestart' | 'ManualActionRequired' | 'AgreementRequired' | 'Unavailable' | 'Cancelled' | 'Uncertain' | 'Failed' | 'Simulated';
export interface OperationRecord {
  format: string; version: number; operationId: string; batchId: string; requestedBy: string; startedUtc: string; finishedUtc: string;
  action: Action; packageId: string; source: Source; name: string; catalogId: string; scope: string;
  priorVersion: string; resultVersion: string; exitCode: string; symbol: string; failureClass: string;
  result: OperationResult; verification: string; restartRequired: boolean; manualAction: string;
  retryable: boolean; attempt: number; retryOf: string; dryRun: boolean; command: string; output: string;
}

export interface AgentState {
  agent: { version: string; started: string; user: string; elevated: boolean; winget: string; online: boolean };
  settings: { dryRun: boolean; forcedDryRun: boolean; acceptSourceAgreements: boolean };
  busy: boolean;
  running: string;
  inventory: Inventory | null;
  updates: Updates | null;
  validation: Record<string, ValidationResult>;
  batch: { id: string; action: Action; dryRun: boolean; startedUtc: string; jobs: { id: string; packageId: string; name: string; action: Action; state: string; record: OperationRecord | null }[] } | null;
  messages: string[];
}

// ------------------------------------------------------------------------------------------------
// Installed or not
// ------------------------------------------------------------------------------------------------

export type InstallState = 'installed' | 'updateAvailable' | 'notInstalled' | 'uncertain' | 'manual' | 'unknown';

export interface Match {
  state: InstallState;
  version: string;
  /** How it was recognised: WinGet identifier, alternate identifier, or Apps & Features name only. */
  matchedBy: 'id' | 'alternate' | 'name' | '';
  installedId: string;
  update?: UpdateItem;
}

const lower = (s: string) => s.toLowerCase();

/**
 * Catalog applications against the inventory. A WinGet identifier (or a verified alternate one) is
 * a match; an Apps & Features name from the manifest alone is "uncertain" (installed, but perhaps
 * not by WinGet, so updates and removal may not work through it). Without an inventory every
 * application is "unknown", never "not installed".
 */
export function matchInventory(inv: Inventory | null, updates: Updates | null, entries: readonly CatalogEntry[] = CATALOG): Map<string, Match> {
  const out = new Map<string, Match>();
  const pk = new Map((inv?.packages ?? []).map((p) => [lower(p.id), p]));
  const progs = (inv?.programs ?? []).map((p) => ({ ...p, n: lower(p.name) }));
  const ups = new Map((updates?.items ?? []).map((u) => [lower(u.id), u]));
  for (const e of entries) {
    const m: Match = { state: 'unknown', version: '', matchedBy: '', installedId: '' };
    if (!inv) {
      if (methodOf(e) === 'manual' || methodOf(e) === 'vendor') m.state = 'manual';
      out.set(e.id, m);
      continue;
    }
    const ids = e.packageIdentifier ? [e.packageIdentifier, ...(e.alternateIds ?? [])] : [];
    const hit = ids.map((id) => pk.get(lower(id))).find(Boolean);
    if (hit) {
      m.state = 'installed';
      m.version = hit.version;
      m.installedId = hit.id;
      m.matchedBy = lower(hit.id) === lower(e.packageIdentifier ?? '') ? 'id' : 'alternate';
      const u = ups.get(lower(hit.id));
      if (u) {
        m.update = u;
        m.state = 'updateAvailable';
      }
    } else {
      const names = (e.detectNames ?? []).map(lower);
      const prog = names.length ? progs.find((p) => names.includes(p.n)) : undefined;
      if (prog) {
        m.state = 'uncertain';
        m.version = prog.version;
        m.matchedBy = 'name';
      } else m.state = methodOf(e) === 'manual' || methodOf(e) === 'vendor' ? 'manual' : 'notInstalled';
    }
    out.set(e.id, m);
  }
  return out;
}

/** Installed WinGet packages that are not in the curated catalog (still manageable by identifier). */
export function uncataloged(inv: Inventory | null, entries: readonly CatalogEntry[] = CATALOG): InventoryPackage[] {
  const known = new Set(entries.flatMap((e) => (e.packageIdentifier ? [e.packageIdentifier, ...(e.alternateIds ?? [])] : [])).map(lower));
  return (inv?.packages ?? []).filter((p) => !known.has(lower(p.id)));
}

export const STATE_LABELS: Record<InstallState, string> = {
  installed: 'Installed',
  updateAvailable: 'Update available',
  notInstalled: 'Not installed',
  uncertain: 'Detected (uncertain)',
  manual: 'Manual installer',
  unknown: 'Not scanned yet',
};

export const AVAILABILITY_LABELS: Record<Availability, string> = {
  checking: 'Checking…',
  available: 'Available',
  notFound: 'Not found in source',
  networkUnavailable: 'Network unavailable',
  sourceUnavailable: 'Source unavailable',
  agreementRequired: 'Terms must be accepted',
  invalid: 'Unsupported identifier',
};

// ------------------------------------------------------------------------------------------------
// Commands (mirror of Get-WamArguments; tests compare both)
// ------------------------------------------------------------------------------------------------

export interface ArgOptions { scope?: '' | 'user' | 'machine'; version?: string; acceptPackageAgreements?: boolean; acceptSourceAgreements?: boolean }

export function validSpec(id: string, source: string, o: ArgOptions = {}): string | null {
  if (source !== 'winget' && source !== 'msstore') return `unsupported source '${source}'`;
  if (source === 'winget' && !WINGET_ID.test(id)) return `invalid WinGet identifier '${id}'`;
  if (source === 'msstore' && !STORE_ID.test(id)) return `invalid Microsoft Store identifier '${id}'`;
  if (o.scope && o.scope !== 'user' && o.scope !== 'machine') return `invalid scope '${o.scope}'`;
  if (o.version && !VERSION.test(o.version)) return `invalid version '${o.version}'`;
  return null;
}

export function wingetArguments(action: Action | 'show' | 'list', id: string, source: Source, o: ArgOptions = {}): string[] {
  const a = [action, '--id', id, '--exact', '--source', source];
  if (action === 'install' || action === 'upgrade' || action === 'uninstall') {
    if (o.scope) a.push('--scope', o.scope);
    if (o.version && action === 'install') a.push('--version', o.version);
    a.push('--silent');
    if (action === 'install') a.push('--no-upgrade');
    if (o.acceptPackageAgreements && action !== 'uninstall') a.push('--accept-package-agreements');
  }
  if (o.acceptSourceAgreements) a.push('--accept-source-agreements');
  a.push('--disable-interactivity');
  return a;
}

export const commandLine = (args: readonly string[]) => 'winget ' + args.join(' ');

// ------------------------------------------------------------------------------------------------
// Installation queue preview
// ------------------------------------------------------------------------------------------------

export interface QueueItem {
  key: string;
  name: string;
  catalogId?: string;
  id: string;
  source: Source;
  scope: '' | 'user' | 'machine';
  version: string;
  command: string;
  privileges: string;
  availability: Availability | 'notChecked';
  notes: string[];
  dependencies: string[];
  /** The manifest declares agreements: the user must review and accept them for this package. */
  agreements: boolean;
}

export interface InstallPreview {
  queue: QueueItem[];
  alreadyInstalled: { key: string; name: string; version: string }[];
  manual: { key: string; name: string; instructions: string; url?: string; reason: string }[];
  blocked: { key: string; name: string; reason: string }[];
}

function privilegesOf(e: CatalogEntry | undefined, scope: string): string {
  const s = scope || e?.scope || 'unknown';
  if (s === 'user') return 'No administrator rights needed (installs for you only).';
  if (s === 'machine') return 'Windows asks for administrator approval (UAC).';
  if (s === 'either') return 'Installs for you only where the installer supports it; otherwise Windows asks for approval.';
  return 'May ask for administrator approval (UAC), depending on the installer.';
}

/** The queue for planned packages (from resolveSelection), skipping what is already installed. */
export function installPreview(planned: readonly PlannedPackage[], matches: Map<string, Match>, validation: Record<string, ValidationResult> = {}, acceptSourceAgreements = false): InstallPreview {
  const out: InstallPreview = { queue: [], alreadyInstalled: [], manual: [], blocked: [] };
  const names = new Map(planned.map((p) => [p.key, p.displayName]));
  for (const p of planned) {
    const e = p.catalog;
    if (p.resolution === 'manual') {
      out.manual.push({ key: p.key, name: p.displayName, reason: e?.manual?.reason ?? 'No unattended installer.', instructions: e?.manual?.instructions ?? 'Install it from the publisher.', url: e?.manual?.url });
      continue;
    }
    if (p.resolution === 'unresolved') {
      out.blocked.push({ key: p.key, name: p.displayName, reason: p.reason ?? 'No verified package.' });
      continue;
    }
    const m = e ? matches.get(e.id) : undefined;
    if (m && (m.state === 'installed' || m.state === 'updateAvailable')) {
      out.alreadyInstalled.push({ key: p.key, name: p.displayName, version: m.version });
      continue;
    }
    const source = p.ref.source as Source;
    const id = p.ref.packageIdentifier;
    const bad = validSpec(id, source, { scope: p.ref.scope, version: p.ref.version });
    if (bad) {
      out.blocked.push({ key: p.key, name: p.displayName, reason: `Refused: ${bad}.` });
      continue;
    }
    const v = validation[`${source}:${id}`.toLowerCase()];
    const notes: string[] = [];
    if (m?.state === 'uncertain') notes.push('Something with this name is already installed (perhaps not by WinGet); WinGet will not reinstall it over a newer version.');
    if (e?.accountSignIn) notes.push('Needs a sign-in to the publisher\'s account after installation.');
    if (e?.interaction === 'mayPrompt') notes.push('The installer may show a window or question.');
    if (e?.reboot === 'mayRequire') notes.push('May need a restart.');
    if (e?.license && /proprietary|commercial|subscription|trial/i.test(e.license)) notes.push(`Licence: ${e.license}.`);
    if (e?.hardware) notes.push(`Only useful with: ${e.hardware.requirement}`);
    if (e?.notes) notes.push(e.notes);
    if (v?.agreements) notes.push('The package has its own licence agreement: review it (winget show) and accept it before installing.');
    out.queue.push({
      key: p.key, name: p.displayName, catalogId: e?.id, id, source, scope: p.ref.scope, version: p.ref.version,
      command: commandLine(wingetArguments('install', id, source, { scope: p.ref.scope, version: p.ref.version, acceptSourceAgreements })),
      privileges: privilegesOf(e, p.ref.scope), availability: v?.status ?? 'notChecked', notes,
      dependencies: p.after.map((k) => names.get(k) ?? k), agreements: !!v?.agreements,
    });
  }
  return out;
}

/** A queue can start only when every item was validated as available in its source now. */
export const queueReady = (q: readonly QueueItem[]) => q.length > 0 && q.every((x) => x.availability === 'available');

// ------------------------------------------------------------------------------------------------
// Removal
// ------------------------------------------------------------------------------------------------

export interface RemovalPreview {
  id: string;
  name: string;
  version: string;
  allowed: boolean;
  level: RemovalSafety;
  reason: string;
  command: string;
  dependents: string[];
  restart: string;
  risks: string[];
}

export function removalPolicy(id: string, entry: CatalogEntry | undefined): { allowed: boolean; level: RemovalSafety; reason: string } {
  if (PROTECTED_PATTERNS.some((r) => r.test(id))) return { allowed: false, level: 'blocked', reason: 'A Windows component, shared runtime or driver: never removed here.' };
  if (!entry) return { allowed: true, level: 'caution', reason: 'Not in the curated catalog: check that nothing depends on it.' };
  if (entry.removal === 'blocked') return { allowed: false, level: 'blocked', reason: 'Marked as not removable (runtime or Windows component).' };
  if (entry.removal === 'caution') return { allowed: true, level: 'caution', reason: `Removing ${entry.displayName} can affect security, drivers, devices or other applications.` };
  return { allowed: true, level: 'normal', reason: '' };
}

export function catalogEntryForPackage(id: string, entries: readonly CatalogEntry[] = CATALOG): CatalogEntry | undefined {
  const l = lower(id);
  return entries.find((e) => lower(e.packageIdentifier ?? '') === l || (e.alternateIds ?? []).some((a) => lower(a) === l));
}

export function removalPreview(pkg: InventoryPackage, matches: Map<string, Match>, entries: readonly CatalogEntry[] = CATALOG): RemovalPreview {
  const e = catalogEntryForPackage(pkg.id, entries);
  const pol = removalPolicy(pkg.id, e);
  const key = e ? entryKey(e) : `${pkg.source}:${pkg.id}`.toLowerCase();
  const dependents = entries.filter((x) => x.requires.includes(key) && ['installed', 'updateAvailable'].includes(matches.get(x.id)?.state ?? '')).map((x) => x.displayName);
  const risks: string[] = ['Your documents, settings and application data are left in place (WinGet runs the publisher\'s own uninstaller).'];
  if (dependents.length) risks.push(`Installed applications that use it: ${dependents.join(', ')}.`);
  if (e?.kind === 'service' || e?.category === 'security') risks.push('It protects or connects this computer; removing it can leave it without that protection or connection.');
  if (e?.kind === 'manufacturer' || e?.kind === 'driver') risks.push('Devices it controls may stop working as configured.');
  if (pkg.source === 'msstore') risks.push('A Microsoft Store app: it is removed for your account.');
  return {
    id: pkg.id, name: e?.displayName ?? pkg.id, version: pkg.version, ...pol,
    command: commandLine(wingetArguments('uninstall', pkg.id, pkg.source === 'msstore' ? 'msstore' : 'winget')),
    dependents, restart: e?.reboot === 'mayRequire' ? 'May need a restart.' : e?.reboot === 'none' ? 'No restart expected.' : 'A restart may be requested by the uninstaller.', risks,
  };
}

/** Bulk removal is never offered for anything but ordinary applications. */
export const bulkRemovable = (p: RemovalPreview) => p.allowed && p.level === 'normal';

// ------------------------------------------------------------------------------------------------
// Results
// ------------------------------------------------------------------------------------------------

export const RESULT_LABELS: Record<OperationResult, string> = {
  Succeeded: 'Done', AlreadyInstalled: 'Already installed', UpToDate: 'Already up to date', RequiresRestart: 'Done; restart needed',
  ManualActionRequired: 'Needs you', AgreementRequired: 'Terms not accepted', Unavailable: 'Not available', Cancelled: 'Cancelled',
  Uncertain: 'Finished; not confirmed', Failed: 'Failed', Simulated: 'Simulated',
};

export const isSuccess = (r: OperationResult) => r === 'Succeeded' || r === 'AlreadyInstalled' || r === 'UpToDate' || r === 'RequiresRestart';

export function summarize(records: readonly OperationRecord[]) {
  const c = { total: records.length, succeeded: 0, failed: 0, attention: 0, simulated: 0, restart: false };
  for (const r of records) {
    if (r.result === 'Simulated') c.simulated++;
    else if (isSuccess(r.result)) c.succeeded++;
    else if (r.result === 'Failed' || r.result === 'Unavailable') c.failed++;
    else c.attention++;
    if (r.restartRequired) c.restart = true;
  }
  return c;
}
