import { describe, expect, it } from 'vitest';
import { bulkEligible, compareVersions, installedView, matchInventory, updateIssue, updateReason, type Inventory, type UpdateItem } from '../../src/engine/manager';

/**
 * Phase 10 fixes from the first real-world test (2026-10-25):
 *   1. every available update was shown in the Source column and refused ("No newer version is listed");
 *   2. the ~592 other installed programs appeared, then vanished on the next background refresh.
 * The agent side is tested in tests/powershell/AppManager.Tests.ps1 (REGRESSION scenarios).
 */

const item = (over: Partial<UpdateItem>): UpdateItem => ({ id: 'Git.Git', name: 'Git', installed: '1.0', available: '2.0', source: 'winget', eligible: true, reason: '', explicit: false, truncated: false, ...over });

describe('Bug 1: updates read from the wrong column', () => {
  it('a row as the first agent produced it (new version in Source, Available empty) is refused as unreadable, whatever the agent says', () => {
    for (const [id, installed, misread] of [['7zip.7zip', '25.01', '26.05'], ['VideoLAN.VLC', '3.0.21', '3.0.24'], ['Google.Chrome', '155.0.8059.86', '156.0.8078.48'], ['WiresharkFoundation.Wireshark', '4.4.3', '4.6.9']] as const) {
      const broken = item({ id, installed, available: '', source: misread, eligible: true });
      expect(updateIssue(broken), id).toMatch(/was read as a source/);
      expect(bulkEligible(broken), id).toBe(false);
      const fixed = item({ id, installed, available: misread, source: 'winget' });
      expect(updateIssue(fixed)).toBe('');
      expect(bulkEligible(fixed), id).toBe(true);
    }
    expect(updateIssue(item({ available: 'winget', source: '' }))).toMatch(/was read as a version/);
  });

  it('bulk eligibility needs the agent and the page to agree: known, newer versions; no explicit, shortened or WinGet-own package', () => {
    expect(bulkEligible(item({}))).toBe(true);
    expect(bulkEligible(item({ eligible: false }))).toBe(false);
    expect(bulkEligible(item({ installed: '< 174.2.0.13389', available: '174.2.0.13389' }))).toBe(false);
    expect(bulkEligible(item({ installed: 'Unknown' }))).toBe(false);
    expect(bulkEligible(item({ available: '1.0' }))).toBe(false);
    expect(bulkEligible(item({ explicit: true }))).toBe(false);
    expect(bulkEligible(item({ truncated: true }))).toBe(false);
    expect(bulkEligible(item({ id: 'Microsoft.AppInstaller' }))).toBe(false);
    expect(bulkEligible(item({ problem: 'no installed version in the row' }))).toBe(false);
    expect(bulkEligible(item({ id: 'ARP\\Machine\\X64\\Foo' }))).toBe(false);
    expect(updateReason(item({ eligible: false, reason: 'The publisher asks for this package to be updated only on its own.' }))).toMatch(/on its own/);
  });

  it('versions as WinGet writes them compare as numbers', () => {
    expect(compareVersions('26.05', '25.01')).toBe(1);
    expect(compareVersions('156.0.8078.48', '155.0.8059.86')).toBe(1);
    expect(compareVersions('7.2.1 (48556)', '7.1.9 (48550)')).toBe(1);
    expect(compareVersions('10.0', '9.9')).toBe(1);
    expect(compareVersions('1.0', '1.0.0')).toBe(0);
  });
});

const program = (name: string, version = '1.0', publisher = 'P', scope = 'machine') => ({ name, version, publisher, scope });

describe('Bug 2: installed programs disappearing', () => {
  const inv: Inventory = {
    scannedUtc: '2026-10-25T11:33:47Z', method: 'winget export', note: '', listing: 'ok',
    packages: [{ id: '7zip.7zip', version: '25.01', source: 'winget' }, { id: 'Example.Thing', version: '30.0.4', source: 'winget' }, { id: 'Contoso.Widget', version: '2.0', source: 'winget' }, { id: 'Microsoft.VCRedist.2015+.x64', version: '14.51', source: 'winget' }],
    listed: [
      { name: '7-Zip 25.01 (x64)', id: '7zip.7zip', version: '25.01', source: 'winget', truncated: false },
      { name: 'Example Thing 30.0.4', id: 'Example.Thing', version: '30.0.4', source: 'winget', truncated: false },
      { name: 'Microsoft Visual C++ 2015-2022 Redistrib…', id: 'Microsoft.VCRedist.2015+.x64', version: '14.51', source: 'winget', truncated: true },
      { name: 'Contoso Field Tool', id: 'ARP\\Machine\\X64\\Contoso', version: '4.1', source: '', truncated: false },
      { name: 'Calculator', id: 'MSIX\\Microsoft.WindowsCalculator_11.2_x64__8wekyb3d8bbwe', version: '11.2', source: '', truncated: false },
    ],
    programs: [
      program('7-Zip 25.01 (x64)', '25.01', 'Igor Pavlov'),
      program('Example Thing 30.0.4', '30.0.4', 'Example Ltd'),
      program('Microsoft Visual C++ 2015-2022 Redistributable (x64) - 14.51.36231', '14.51', 'Microsoft Corporation'),
      program('Contoso Field Tool', '4.1', 'Contoso'),
      program('Contoso Field Tool', '4.1', 'Contoso', 'user'),
      program('Windows Driver Package - libusbK', '3.0.7.0', 'libusbK'),
    ],
  };
  const view = () => installedView(inv, matchInventory(inv, null));

  it('every program is listed once, in one of three groups: catalog, other WinGet packages, other programs', () => {
    const v = view();
    const by = (k: string) => v.rows.filter((r) => r.kind === k).map((r) => r.name).sort();
    expect(by('catalog')).toEqual(['7-Zip', 'Visual C++ Redistributable 2015-2026 (x64)']);
    expect(by('winget')).toEqual(['Contoso.Widget', 'Example Thing 30.0.4']);
    expect(by('other')).toEqual(['Calculator', 'Contoso Field Tool', 'Windows Driver Package - libusbK']);
    expect(v.counts).toEqual({ catalog: 2, winget: 2, other: 3, total: 7 });
    expect(v.linked).toBe(true);
  });

  it('a Windows program is linked to its WinGet package by "winget list" (shortened names by prefix) and not listed twice', () => {
    const v = view();
    expect(v.rows.filter((r) => /7-Zip/.test(r.name))).toHaveLength(1);
    expect(v.rows.find((r) => r.id === '7zip.7zip')!.publisher).toBe('Igor Pavlov');
    expect(v.rows.find((r) => r.id === 'Microsoft.VCRedist.2015+.x64')!.publisher).toBe('Microsoft Corporation');
    expect(v.rows.some((r) => r.name.startsWith('Microsoft Visual C++') && r.kind === 'other')).toBe(false);
  });

  it('only WinGet packages carry an identifier; other programs are never presented as manageable through WinGet', () => {
    for (const r of view().rows) expect(!!r.id, r.name).toBe(r.kind !== 'other');
    expect(view().rows.filter((r) => r.kind === 'other').every((r) => r.origin.startsWith('Windows uninstall record') || r.origin.startsWith('MSIX'))).toBe(true);
  });

  it('without "winget list", nothing is dropped and the page says programs are not linked', () => {
    const v = installedView({ ...inv, listed: undefined, listing: 'failed' }, matchInventory(inv, null));
    expect(v.linked).toBe(false);
    expect(v.counts.other).toBe(5);
    expect(v.counts.catalog + v.counts.winget).toBe(4);
  });

  it('1,200 Windows programs and 300 packages: all listed, stable order and counts, in well under a frame budget per run', () => {
    const big: Inventory = {
      scannedUtc: 'x', method: 'winget export', note: '', listing: 'ok',
      packages: Array.from({ length: 300 }, (_, i) => ({ id: `Vendor${i}.App${i}`, version: '1.0', source: 'winget' })),
      listed: Array.from({ length: 300 }, (_, i) => ({ name: `Packaged app ${i}`, id: `Vendor${i}.App${i}`, version: '1.0', source: 'winget', truncated: false })),
      programs: [...Array.from({ length: 300 }, (_, i) => program(`Packaged app ${i}`)), ...Array.from({ length: 1200 }, (_, i) => program(`Program ${String(i).padStart(4, '0')}`))],
    };
    const m = matchInventory(big, null);
    const t = performance.now();
    const a = installedView(big, m);
    const ms = performance.now() - t;
    const b = installedView(big, m);
    expect(a.counts).toEqual({ catalog: 0, winget: 300, other: 1200, total: 1500 });
    expect(a.rows.map((r) => r.key)).toEqual(b.rows.map((r) => r.key));
    expect(ms).toBeLessThan(250);
  });
});
