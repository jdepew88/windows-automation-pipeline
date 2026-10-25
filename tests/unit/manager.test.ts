import { execFile } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { describe, expect, it } from 'vitest';
import { CATALOG, catalogEntryById, catalogRef, entryKey } from '../../src/engine/applications/catalog';
import { addPackage, toggleProfile } from '../../src/engine/applications/profiles';
import { resolveSelection } from '../../src/engine/applications/selection';
import {
  PROTECTED_PATTERNS, bulkRemovable, catalogPolicy, installPreview, matchInventory, queueReady, removalPolicy, removalPreview, summarize, uncataloged, validSpec, wingetArguments,
  type Inventory, type OperationRecord, type Updates,
} from '../../src/engine/manager';
import { profile } from './helpers';

const inv = (packages: [string, string][], programs: { name: string; version?: string }[] = []): Inventory => ({
  scannedUtc: '2026-10-25T12:00:00Z', method: 'winget export', note: '',
  packages: packages.map(([id, version]) => ({ id, version, source: 'winget' })),
  programs: programs.map((p) => ({ name: p.name, version: p.version ?? '1.0', publisher: '', scope: 'machine' })),
});
const updates = (items: Partial<Updates['items'][number]>[]): Updates => ({
  checkedUtc: 'x', finishedUtc: 'y', status: 'ok', exitCode: '0x00000000', note: '',
  items: items.map((i) => ({ id: '', name: '', installed: '', available: '', source: 'winget', eligible: true, reason: '', explicit: false, truncated: false, ...i })),
});
const sel = () => profile().applications.selection;

describe('Application Manager: policy shared with the agent', () => {
  it('lists every WinGet identifier (and alternate identifiers) with its removal and upgrade rule', () => {
    const p = catalogPolicy();
    expect(p.format).toBe('windows-deployment-builder/app-manager-policy');
    const byId = new Map(p.packages.map((x) => [x.id, x]));
    expect(byId.get('Zoom.Zoom.EXE')?.catalogId).toBe('zoom');
    expect(byId.get('Microsoft.VCRedist.2015+.x64')?.removal).toBe('blocked');
    expect(byId.get('Parsec.Parsec')?.upgrade).toBe('explicit');
    expect(byId.get('PrivateInternetAccess.PrivateInternetAccess')?.removal).toBe('caution');
    expect(p.packages.length).toBe(CATALOG.filter((e) => e.packageIdentifier).length + CATALOG.reduce((n, e) => n + (e.alternateIds?.length ?? 0), 0));
  });
});

describe('Application Manager: detection', () => {
  it('matches by WinGet identifier, alternate identifier, or (uncertain) Apps & Features name; never "not installed" before a scan', () => {
    const none = matchInventory(null, null);
    expect(none.get('git')!.state).toBe('unknown');
    expect(none.get('vmware-workstation')!.state).toBe('manual');
    const m = matchInventory(inv([['git.git', '2.45.1'], ['Zoom.Zoom.EXE', '6.0']], [{ name: 'RetroArch', version: '1.19' }]), updates([{ id: 'Git.Git', installed: '2.45.1', available: '2.47.0' }]));
    expect(m.get('git')).toMatchObject({ state: 'updateAvailable', version: '2.45.1', matchedBy: 'id' });
    expect(m.get('git')!.update!.available).toBe('2.47.0');
    expect(m.get('zoom')).toMatchObject({ state: 'installed', matchedBy: 'alternate', installedId: 'Zoom.Zoom.EXE' });
    expect(m.get('retroarch')).toMatchObject({ state: 'uncertain', matchedBy: 'name', version: '1.19' });
    expect(m.get('vlc')!.state).toBe('notInstalled');
  });

  it('lists installed packages outside the catalog (they are not assumed to be unavailable in WinGet)', () => {
    expect(uncataloged(inv([['Git.Git', '1'], ['Contoso.Tool', '2']])).map((p) => p.id)).toEqual(['Contoso.Tool']);
  });
});

describe('Application Manager: commands', () => {
  it('exact identifier and source; no forcing, hash-skipping or unknown-version flags', () => {
    expect(wingetArguments('install', 'Git.Git', 'winget')).toEqual(['install', '--id', 'Git.Git', '--exact', '--source', 'winget', '--silent', '--no-upgrade', '--disable-interactivity']);
    expect(wingetArguments('uninstall', 'Git.Git', 'winget', { acceptPackageAgreements: true })).not.toContain('--accept-package-agreements');
    for (const a of ['install', 'upgrade', 'uninstall'] as const) {
      const s = wingetArguments(a, 'X.Y', 'winget', { scope: 'machine', version: '1', acceptPackageAgreements: true, acceptSourceAgreements: true }).join(' ');
      for (const bad of ['--force', '--ignore-security-hash', '--include-unknown', '--all', '--purge', '--override', '--uninstall-previous']) expect(s).not.toContain(bad);
    }
  });

  it('refuses identifiers, scopes and versions that could carry a flag or a command', () => {
    expect(validSpec('Git.Git', 'winget')).toBeNull();
    for (const id of ['Git.Git --force', 'Git.Git;calc', 'Git', '"Git.Git"']) expect(validSpec(id, 'winget'), id).toMatch(/invalid/);
    expect(validSpec('Git.Git', 'chocolatey')).toMatch(/unsupported source/);
    expect(validSpec('Git.Git', 'winget', { version: '1 --force' })).toMatch(/invalid version/);
  });
});

describe('Application Manager: installation queue preview', () => {
  it('uses the shared selection: stacked profiles, no duplicates, already-installed skipped, manual items listed with steps', () => {
    const s = sel();
    toggleProfile(s, 'workstation', true);
    toggleProfile(s, 'developer', true);
    addPackage(s, catalogRef(catalogEntryById('vmware-workstation')!)!);
    const plan = resolveSelection(s).packages;
    const matches = matchInventory(inv([['Google.Chrome', '130'], ['qBittorrent.qBittorrent', '5.0']]), null);
    const pv = installPreview(plan, matches);
    expect(pv.alreadyInstalled.map((x) => x.name).sort()).toEqual(['Google Chrome', 'qBittorrent']);
    expect(pv.queue.some((q) => q.id === 'Google.Chrome')).toBe(false);
    expect(new Set(pv.queue.map((q) => q.key)).size).toBe(pv.queue.length);
    expect(pv.manual.map((m) => m.name)).toContain('VMware Workstation Pro');
    expect(pv.manual.find((m) => m.name === 'VMware Workstation Pro')!.instructions).toMatch(/support\.broadcom\.com/);
    const parsec = pv.queue.find((q) => q.id === 'Parsec.Parsec')!;
    expect(parsec.command).toBe('winget install --id Parsec.Parsec --exact --source winget --silent --no-upgrade --disable-interactivity');
    expect(parsec.availability).toBe('notChecked');
    expect(queueReady(pv.queue)).toBe(false);
  });

  it('shows privileges, sign-in, licences, hardware and dependencies; ready only when every item was found in its source', () => {
    const s = sel();
    toggleProfile(s, 'core', false);
    for (const id of ['docker-desktop', 'openrgb']) addPackage(s, catalogRef(catalogEntryById(id)!)!);
    const plan = resolveSelection(s).packages;
    const validation = Object.fromEntries(plan.map((p) => [`${p.ref.source}:${p.ref.packageIdentifier}`.toLowerCase(), { status: 'available' as const, detail: '' }]));
    const pv = installPreview(plan, matchInventory(inv([]), null), validation);
    const docker = pv.queue.find((q) => q.catalogId === 'docker-desktop')!;
    expect(docker.dependencies).toEqual(['Windows Subsystem for Linux']);
    expect(docker.privileges).toMatch(/administrator|approval/i);
    expect(pv.queue.find((q) => q.catalogId === 'openrgb')!.notes.join(' ')).toMatch(/Only useful with/);
    expect(queueReady(pv.queue)).toBe(true);
    const missing = { ...validation, 'winget:docker.dockerdesktop': { status: 'sourceUnavailable' as const, detail: '' } };
    expect(queueReady(installPreview(plan, matchInventory(inv([]), null), missing).queue)).toBe(false);
  });

  it('an agreement in the manifest is shown, never accepted on the user\'s behalf', () => {
    const s = sel();
    const plan = resolveSelection(s).packages;
    const key = entryKey(catalogEntryById('chrome')!);
    const pv = installPreview(plan, matchInventory(inv([]), null), { [key]: { status: 'available', agreements: true, detail: '' } });
    const chrome = pv.queue.find((q) => q.catalogId === 'chrome')!;
    expect(chrome.agreements).toBe(true);
    expect(chrome.command).not.toContain('accept-package-agreements');
  });
});

describe('Application Manager: removal', () => {
  it('runtimes, Windows components and drivers are never removable; security and device software need care; documents are kept', () => {
    const m = matchInventory(inv([['Microsoft.VCRedist.2015+.x64', '14'], ['Docker.DockerDesktop', '4'], ['Microsoft.WSL', '2']]), null);
    expect(removalPreview({ id: 'Microsoft.VCRedist.2015+.x64', version: '14', source: 'winget' }, m).allowed).toBe(false);
    for (const id of ['Microsoft.Edge', 'Microsoft.WindowsAppRuntime.1.8', 'Nvidia.GeForceExperience', 'Intel.IntelDriverAndSupportAssistant']) expect(removalPolicy(id, undefined).allowed, id).toBe(false);
    const wsl = removalPreview({ id: 'Microsoft.WSL', version: '2', source: 'winget' }, m);
    expect(wsl.level).toBe('caution');
    expect(wsl.dependents).toEqual(['Docker Desktop']);
    expect(wsl.risks.join(' ')).toMatch(/documents, settings and application data are left in place/);
    expect(bulkRemovable(wsl)).toBe(false);
    const unknown = removalPreview({ id: 'Contoso.Tool', version: '1', source: 'winget' }, m);
    expect(unknown.level).toBe('caution');
    expect(bulkRemovable(removalPreview({ id: 'VideoLAN.VLC', version: '3', source: 'winget' }, m))).toBe(true);
    expect(removalPreview({ id: 'VideoLAN.VLC', version: '3', source: 'winget' }, m).command).toBe('winget uninstall --id VideoLAN.VLC --exact --source winget --silent --disable-interactivity');
  });
});

describe('Application Manager: results', () => {
  it('counts simulated, successful, failed and attention results separately', () => {
    const r = (result: OperationRecord['result'], restartRequired = false) => ({ result, restartRequired }) as OperationRecord;
    expect(summarize([r('Succeeded'), r('RequiresRestart', true), r('Failed'), r('ManualActionRequired'), r('Simulated')])).toEqual({ total: 5, succeeded: 2, failed: 1, attention: 1, simulated: 1, restart: true });
  });
});

const onWindows = process.platform === 'win32';
const run = promisify(execFile);
const script = (rel: string) => fileURLToPath(new URL(rel, import.meta.url));

describe.skipIf(!onWindows)('Application Manager agent (PowerShell, simulated WinGet)', () => {
  it('scenario suite passes; its WinGet arguments and protected list match the page\'s', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'wam-'));
    try {
      writeFileSync(join(dir, 'catalog-policy.json'), JSON.stringify(catalogPolicy()));
      let out: string;
      try {
        out = (await run('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script('../powershell/AppManager.Tests.ps1'), '-Policy', join(dir, 'catalog-policy.json'), '-Out', dir], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 })).stdout;
      } catch (e) {
        throw new Error(`AppManager.Tests.ps1 failed:\n${(e as { stdout?: string }).stdout ?? e}`);
      }
      expect(out).toMatch(/\b\d+ passed, 0 failed/);
      const strip = (s: string) => (s.charCodeAt(0) === 0xfeff ? s.slice(1) : s);
      const cases = JSON.parse(strip(readFileSync(join(dir, 'args.json'), 'utf8'))) as { action: 'install'; id: string; source: 'winget'; scope: ''; version: string; acceptPackageAgreements: boolean; acceptSourceAgreements: boolean; args: string[] }[];
      expect(cases.length).toBe(7);
      for (const c of cases) expect(wingetArguments(c.action, c.id, c.source, c), `${c.action} ${c.id}`).toEqual(c.args);
      const prot = JSON.parse(strip(readFileSync(join(dir, 'protected.json'), 'utf8'))) as string[];
      expect(prot.map((p) => new RegExp(p, 'i').source)).toEqual(PROTECTED_PATTERNS.map((r) => r.source));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 240_000);
});
