import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { CATALOG, catalogEntryById, searchCatalog } from '../../src/engine/applications/catalog';
import { MSSTORE_ID, WINGET_ID, packageKey, unresolvedReason } from '../../src/engine/applications/ids';
import {
  addPackage,
  createProfile,
  deleteProfile,
  duplicateProfile,
  exportAppProfiles,
  importAppProfiles,
  removeFromProfile,
  removePackage,
  renameProfile,
  restorePackage,
  saveSelectionToProfile,
  toggleProfile,
} from '../../src/engine/applications/profiles';
import { ADDED, resolveSelection } from '../../src/engine/applications/selection';
import { exportWinGetDocument, exportWinGetJson, importWinGetJson, validateWinGetDocument } from '../../src/engine/applications/winget-json';
import type { ApplicationsSelection, PackageRef } from '../../src/engine/schema/applications';
import { ownerDefaults } from '../../src/engine/profiles';

const fixture = (name: string) => readFileSync(new URL(`../fixtures/applications/${name}`, import.meta.url), 'utf8');
const ref = (packageIdentifier: string, source = 'winget', extra: Partial<PackageRef> = {}): PackageRef => ({ packageIdentifier, source, displayName: packageIdentifier, version: '', scope: '', ...extra });
const doc = (sources: unknown) => JSON.stringify({ $schema: 'https://aka.ms/winget-packages.schema.2.0.json', Sources: sources });
const WINGET = { Name: 'winget', Identifier: 'Microsoft.Winget.Source_8wekyb3d8bbwe', Argument: 'https://cdn.winget.microsoft.com/cache', Type: 'Microsoft.PreIndexed.Package' };
const MSSTORE = { Name: 'msstore', Identifier: 'StoreEdgeFD', Argument: 'https://storeedgefd.dsx.mp.microsoft.com/v9.0', Type: 'Microsoft.Rest' };
const emptySelection = (): ApplicationsSelection => structuredClone(ownerDefaults().applications.selection);

describe('WinGet JSON import (packages.schema.2.0.json)', () => {
  it('imports a native winget export: identifiers, sources, versions and scopes preserved', () => {
    const r = importWinGetJson(fixture('winget-export.json'));
    expect(r.errors).toEqual([]);
    expect(r.ok).toBe(true);
    expect(r.meta).toEqual({ winGetVersion: '1.29.250', creationDate: '2026-10-19T09:41:12.512-00:00', sources: 2 });
    expect(r.packages.map((p) => `${p.source}:${p.packageIdentifier}`)).toEqual(['winget:Git.Git', 'winget:7zip.7zip', 'winget:Mozilla.Firefox', 'winget:Microsoft.PowerToys', 'msstore:9MSPC6MP8FM4']);
    expect(r.packages[2]!.version).toBe('131.0.3');
    expect(r.packages[3]!.scope).toBe('machine');
    expect(r.packages.every((p) => p.sourceDetails === undefined)).toBe(true);
  });

  it('accepts a UTF-8 BOM, as written by some editors', () => {
    expect(importWinGetJson(String.fromCharCode(0xfeff) + fixture('winget-export.json')).ok).toBe(true);
  });

  it.each([
    ['not JSON', '{', /Not valid JSON/],
    ['an array', '[]', /must be a JSON object/],
    ['missing Sources', '{"WinGetVersion":"1.6.0"}', /required property "Sources"/],
    ['Sources not an array', '{"Sources":{}}', /Sources: must be an array/],
    ['missing SourceDetails', doc([{ Packages: [{ PackageIdentifier: 'Git.Git' }] }]), /SourceDetails/],
    ['SourceDetails without Identifier', doc([{ SourceDetails: { Name: 'winget', Argument: 'x', Type: 'y' }, Packages: [{ PackageIdentifier: 'Git.Git' }] }]), /"Identifier" is missing/],
    ['empty Packages (minItems 1)', doc([{ SourceDetails: WINGET, Packages: [] }]), /at least 1 package/],
    ['PackageIdentifier not a string', doc([{ SourceDetails: WINGET, Packages: [{ PackageIdentifier: 42 }] }]), /PackageIdentifier: must be a string/],
    ['missing PackageIdentifier', doc([{ SourceDetails: WINGET, Packages: [{ Version: '1' }] }]), /"PackageIdentifier" is missing/],
    ['invalid Scope', doc([{ SourceDetails: WINGET, Packages: [{ PackageIdentifier: 'Git.Git', Scope: 'system' }] }]), /Scope: must be "user" or "machine"/],
    ['bad WinGetVersion', JSON.stringify({ WinGetVersion: 'latest', Sources: [] }), /WinGetVersion/],
    ['bad CreationDate', JSON.stringify({ CreationDate: 'yesterday', Sources: [] }), /CreationDate/],
  ])('rejects %s with a schema error', (_label, text, message) => {
    const r = importWinGetJson(text);
    expect(r.ok).toBe(false);
    expect(r.packages).toEqual([]);
    expect(r.errors.join('\n')).toMatch(message);
  });

  it('validates the schema independently of normalisation', () => {
    expect(validateWinGetDocument(JSON.parse(fixture('winget-export.json')))).toEqual([]);
    expect(validateWinGetDocument({ Sources: [] })).toEqual([]);
  });

  it('rejects invalid identifiers instead of importing a plausible-looking name', () => {
    const r = importWinGetJson(doc([{ SourceDetails: WINGET, Packages: [{ PackageIdentifier: 'Google Chrome' }, { PackageIdentifier: 'Git.Git' }, { PackageIdentifier: 'NoDots' }] }, { SourceDetails: MSSTORE, Packages: [{ PackageIdentifier: 'Microsoft.Whiteboard' }] }]));
    expect(r.ok).toBe(true);
    expect(r.packages.map((p) => p.packageIdentifier)).toEqual(['Git.Git']);
    expect(r.rejected.map((x) => x.packageIdentifier)).toEqual(['Google Chrome', 'NoDots', 'Microsoft.Whiteboard']);
  });

  it.each(['Foo.Bar;calc.exe', 'Foo.Bar&&calc', 'Foo.$(Invoke-Expression).Bar', "Foo.Bar'", 'Foo."Bar"', 'Foo.Bar|x', 'Foo.Bar`n'])('rejects the injection attempt %s', (id) => {
    const r = importWinGetJson(doc([{ SourceDetails: WINGET, Packages: [{ PackageIdentifier: id }] }]));
    expect(r.packages).toEqual([]);
    expect(r.rejected).toHaveLength(1);
  });

  it('upper-cases Microsoft Store IDs and de-duplicates case-insensitively', () => {
    const r = importWinGetJson(doc([{ SourceDetails: MSSTORE, Packages: [{ PackageIdentifier: '9mspc6mp8fm4' }, { PackageIdentifier: '9MSPC6MP8FM4' }] }, { SourceDetails: WINGET, Packages: [{ PackageIdentifier: 'git.git' }, { PackageIdentifier: 'Git.Git' }] }]));
    expect(r.packages.map((p) => p.packageIdentifier)).toEqual(['9MSPC6MP8FM4', 'git.git']);
    expect(r.warnings.filter((w) => /more than once/.test(w))).toHaveLength(2);
  });

  it('keeps packages from other sources as unresolved, with their source details', () => {
    const custom = { Name: 'contoso', Identifier: 'Contoso.Repo', Argument: 'https://packages.contoso.example/api', Type: 'Microsoft.Rest' };
    const r = importWinGetJson(doc([{ SourceDetails: custom, Packages: [{ PackageIdentifier: 'Contoso.Tool' }] }]));
    expect(r.packages).toEqual([{ ...ref('Contoso.Tool', 'contoso'), sourceDetails: custom }]);
    expect(unresolvedReason(r.packages[0]!)).toMatch(/not supported/);
    expect(r.warnings.join(' ')).toMatch(/not supported/);
  });

  it('does not trust a source that only claims to be "winget"', () => {
    const spoof = { ...WINGET, Argument: 'https://evil.example/cache' };
    const r = importWinGetJson(doc([{ SourceDetails: spoof, Packages: [{ PackageIdentifier: 'Git.Git' }] }]));
    expect(r.packages[0]!.source).toBe('winget (unverified)');
    expect(r.packages[0]!.sourceDetails).toEqual(spoof);
    expect(r.warnings.join(' ')).toMatch(/does not match Microsoft's winget source/);
    // Kept with its details, but unresolved: it never merges with the real winget package and is not exported for installation.
    expect(unresolvedReason(r.packages[0]!)).toMatch(/not supported/);
    const sel = emptySelection();
    sel.added = [...r.packages, ref('Git.Git')];
    expect(resolveSelection(sel).packages.map((p) => p.resolution)).toEqual(['verified', 'unresolved']);
    expect(JSON.parse(exportWinGetJson(r.packages, null)).Sources).toEqual([]);
  });

  it('drops installer override arguments and channels (never executed, never re-exported)', () => {
    const r = importWinGetJson(doc([{ SourceDetails: WINGET, Packages: [{ PackageIdentifier: 'Git.Git', InitialOverrideArguments: '/VERYSILENT & calc.exe', InitialCustomSwitches: '/x', Channel: 'beta' }] }]));
    expect(r.packages).toEqual([ref('Git.Git')]);
    expect(r.warnings.join(' ')).toMatch(/never used/);
    expect(exportWinGetJson(r.packages)).not.toMatch(/Override|Custom|Channel|calc/);
  });

  it('ignores unknown members and prototype-pollution keys', () => {
    const text = '{"__proto__":{"polluted":true},"Sources":[{"__proto__":{"x":1},"Extra":1,"SourceDetails":' + JSON.stringify(WINGET) + ',"Packages":[{"PackageIdentifier":"Git.Git","constructor":{"prototype":{"polluted":true}}}]}]}';
    const r = importWinGetJson(text);
    expect(r.packages).toEqual([ref('Git.Git')]);
    expect(({} as Record<string, unknown>).polluted).toBeUndefined();
  });

  it('refuses oversized files and too many packages', () => {
    expect(importWinGetJson(' '.repeat(5 * 1024 * 1024 + 1)).errors[0]).toMatch(/larger than/);
    const many = Array.from({ length: 2001 }, (_, i) => ({ PackageIdentifier: `Pub.P${i}` }));
    expect(importWinGetJson(doc([{ SourceDetails: WINGET, Packages: many }])).errors[0]).toMatch(/at most 2000/);
  });

  it('survives deeply nested input without throwing', () => {
    const deep = '{"Sources":[{"SourceDetails":' + JSON.stringify(WINGET) + ',"Packages":[{"PackageIdentifier":"Git.Git","x":' + '['.repeat(2000) + ']'.repeat(2000) + '}]}]}';
    expect(importWinGetJson(deep).packages).toEqual([ref('Git.Git')]);
  });
});

describe('WinGet JSON export', () => {
  const refs = [ref('Git.Git'), ref('9MSPC6MP8FM4', 'msstore'), ref('Mozilla.Firefox', 'winget', { version: '131.0.3', scope: 'machine' }), ref('Contoso.Tool', 'contoso'), ref('Bad Id')];

  it('writes a schema-valid document grouped by source, with only installable packages', () => {
    const d = exportWinGetDocument(refs, new Date('2026-10-19T12:00:00Z'));
    expect(validateWinGetDocument(d)).toEqual([]);
    expect(d).toEqual({
      $schema: 'https://aka.ms/winget-packages.schema.2.0.json',
      CreationDate: '2026-10-19T12:00:00.000Z',
      Sources: [
        { Packages: [{ PackageIdentifier: 'Git.Git' }, { PackageIdentifier: 'Mozilla.Firefox', Version: '131.0.3', Scope: 'machine' }], SourceDetails: WINGET },
        { Packages: [{ PackageIdentifier: '9MSPC6MP8FM4' }], SourceDetails: MSSTORE },
      ],
    });
  });

  it('round-trips through the importer', () => {
    const r = importWinGetJson(exportWinGetJson(refs));
    expect(r.packages.map(packageKey)).toEqual(['winget:git.git', 'winget:mozilla.firefox', 'msstore:9mspc6mp8fm4']);
  });

  it('omits sources without packages (Packages needs at least one) and can leave out the date', () => {
    const d = exportWinGetDocument([], null);
    expect(d).toEqual({ $schema: 'https://aka.ms/winget-packages.schema.2.0.json', Sources: [] });
    expect(validateWinGetDocument(d)).toEqual([]);
  });
});

describe('identifier rules', () => {
  it.each(['Git.Git', '7zip.7zip', 'Notepad++.Notepad++', 'Adobe.Acrobat.Reader.64-bit', 'Python.Python.3.13', 'Microsoft.Sysinternals.Suite'])('accepts real winget ID %s', (id) => expect(WINGET_ID.test(id)).toBe(true));
  it.each(['Git', 'Git Git', '.Git', 'Git..Git', 'A.' + 'b'.repeat(33), 'Git.Git;x', 'Git.Git"'])('rejects winget ID %s', (id) => expect(WINGET_ID.test(id)).toBe(false));
  it('checks Store product IDs', () => {
    expect(MSSTORE_ID.test('9MSPC6MP8FM4')).toBe(true);
    expect(MSSTORE_ID.test('XP89DCGQ3K6VLD')).toBe(true);
    expect(MSSTORE_ID.test('Microsoft.Whiteboard')).toBe(false);
  });
});

describe('profile composition', () => {
  const sel = () => {
    const s = emptySelection();
    s.profiles.find((p) => p.id === 'everyday')!.packages = [ref('Mozilla.Firefox'), ref('7zip.7zip')];
    s.profiles.find((p) => p.id === 'gaming')!.packages = [ref('Valve.Steam'), ref('7ZIP.7ZIP')];
    s.profiles.find((p) => p.id === 'laptop')!.packages = [ref('NirSoft.BatteryInfoView')];
    s.profiles.find((p) => p.id === 'touch')!.packages = [ref('9MSPC6MP8FM4', 'msstore')];
    return s;
  };

  it('owner defaults: every profile is empty and nothing is selected', () => {
    const r = resolveSelection(emptySelection());
    expect(r.packages).toEqual([]);
    for (const p of emptySelection().profiles) expect(resolveSelection({ ...emptySelection(), selectedProfiles: [p.id] }).packages, p.id).toEqual([]);
  });

  it('Everyday + Gaming + Laptop + Touchscreen combine; duplicates by identifier+source are installed once', () => {
    const s = sel();
    s.selectedProfiles = ['everyday', 'gaming', 'laptop', 'touch'];
    const r = resolveSelection(s);
    expect(r.packages.map((p) => p.key)).toEqual(['winget:mozilla.firefox', 'winget:7zip.7zip', 'winget:valve.steam', 'winget:nirsoft.batteryinfoview', 'msstore:9mspc6mp8fm4']);
    expect(r.duplicates).toEqual([{ key: 'winget:7zip.7zip', displayName: '7-Zip', origins: ['everyday', 'gaming'] }]);
  });

  it('does not merge by display name, and keeps the same ID from different sources apart', () => {
    const s = emptySelection();
    s.added = [ref('Mozilla.Firefox', 'winget', { displayName: 'Browser' }), ref('Other.Browser', 'winget', { displayName: 'Browser' }), ref('Contoso.Tool', 'winget'), ref('Contoso.Tool', 'contoso')];
    expect(resolveSelection(s).packages).toHaveLength(4);
  });

  it('individual additions and removals apply after the profiles', () => {
    const s = sel();
    s.selectedProfiles = ['everyday'];
    addPackage(s, ref('Git.Git'));
    removePackage(s, 'winget:7zip.7zip');
    const r = resolveSelection(s);
    expect(r.packages.map((p) => p.key)).toEqual(['winget:mozilla.firefox', 'winget:git.git']);
    expect(r.removed.map((p) => p.key)).toEqual(['winget:7zip.7zip']);
    expect(s.profiles.find((p) => p.id === 'everyday')!.packages).toHaveLength(2);
    restorePackage(s, 'winget:7zip.7zip');
    expect(resolveSelection(s).packages).toHaveLength(3);
    removePackage(s, 'winget:git.git');
    expect(s.added).toEqual([]);
    expect(s.removed).toEqual([]);
  });

  it('an explicit addition wins a version conflict, with a warning', () => {
    const s = sel();
    s.selectedProfiles = ['everyday'];
    s.added = [ref('Mozilla.Firefox', 'winget', { version: '131.0.3' })];
    const r = resolveSelection(s);
    expect(r.packages[0]!.ref.version).toBe('131.0.3');
    expect(r.conflicts[0]!.message).toMatch(/individual addition wins/);
  });

  it('resolves inheritance, detects cycles and missing profiles', () => {
    const s = sel();
    s.profiles.find((p) => p.id === 'custom')!.inherits = ['everyday', 'laptop'];
    s.selectedProfiles = ['custom', 'ghost'];
    const r = resolveSelection(s);
    expect(r.packages.map((p) => p.key)).toEqual(['winget:mozilla.firefox', 'winget:7zip.7zip', 'winget:nirsoft.batteryinfoview']);
    expect(r.missingProfiles).toEqual(['ghost']);
    s.profiles.find((p) => p.id === 'everyday')!.inherits = ['custom'];
    expect(resolveSelection(s).cycles.length).toBeGreaterThan(0);
  });

  it('orders by catalog dependencies, interaction-required packages and unresolved ones last', () => {
    const s = emptySelection();
    s.added = [ref('Docker.DockerDesktop'), ref('Contoso.Tool', 'contoso'), ref('Microsoft.WSL'), ref('Git.Git')];
    const r = resolveSelection(s);
    expect(r.packages.map((p) => p.ref.packageIdentifier)).toEqual(['Microsoft.WSL', 'Docker.DockerDesktop', 'Git.Git', 'Contoso.Tool']);
    expect(r.packages[1]!.after).toEqual(['winget:microsoft.wsl']);
    expect(r.packages.map((p) => p.resolution)).toEqual(['verified', 'verified', 'verified', 'unresolved']);
  });

  it('marks packages that are not in the catalog as unverified, not invalid', () => {
    const s = emptySelection();
    s.added = [ref('Some.Unlisted')];
    expect(resolveSelection(s).packages[0]!.resolution).toBe('unverified');
  });
});

describe('profile operations', () => {
  it('create, duplicate, rename, delete; built-in profiles cannot be renamed or deleted', () => {
    const s = emptySelection();
    const p = createProfile(s, 'Family PC', [ref('Git.Git')]);
    expect(p).toMatchObject({ id: 'family-pc', name: 'Family PC', builtin: false, category: 'custom' });
    const copy = duplicateProfile(s, p.id)!;
    expect(copy.name).toBe('Family PC copy');
    expect(copy.packages).toEqual(p.packages);
    copy.packages.push(ref('7zip.7zip'));
    expect(p.packages).toHaveLength(1);
    expect(renameProfile(s, p.id, '  Kids PC ')).toBe(true);
    expect(p.name).toBe('Kids PC');
    expect(renameProfile(s, 'gaming', 'X')).toBe(false);
    expect(deleteProfile(s, 'gaming')).toBe(false);
    toggleProfile(s, copy.id, true);
    expect(deleteProfile(s, copy.id)).toBe(true);
    expect(s.selectedProfiles).toEqual([]);
    expect(createProfile(s, 'Kids PC').name).toBe('Kids PC (2)');
  });

  it('adds packages to a chosen profile (populating it explicitly) and removes them again', () => {
    const s = emptySelection();
    expect(addPackage(s, ref('Valve.Steam'), 'gaming')).toBe(true);
    expect(addPackage(s, ref('VALVE.STEAM'), 'gaming')).toBe(false);
    expect(resolveSelection(s).packages).toEqual([]);
    toggleProfile(s, 'gaming', true);
    expect(resolveSelection(s).packages.map((p) => p.key)).toEqual(['winget:valve.steam']);
    removeFromProfile(s, 'gaming', 'winget:valve.steam');
    expect(resolveSelection(s).packages).toEqual([]);
  });

  it('saves the combined selection into a profile', () => {
    const s = emptySelection();
    addPackage(s, ref('Git.Git'));
    addPackage(s, ref('7zip.7zip'));
    toggleProfile(s, 'developer', true);
    expect(saveSelectionToProfile(s, 'developer')).toBe(true);
    expect(s.profiles.find((p) => p.id === 'developer')!.packages.map((r) => r.packageIdentifier)).toEqual(['Git.Git', '7zip.7zip']);
    expect(s.added).toEqual([]);
    expect(resolveSelection(s).packages).toHaveLength(2);
  });
});

describe('application profile file format', () => {
  it('exports and re-imports profiles as new custom profiles without touching existing ones', () => {
    const s = emptySelection();
    s.profiles.find((p) => p.id === 'gaming')!.packages = [ref('Valve.Steam')];
    const text = exportAppProfiles(s.profiles, new Date('2026-10-19T00:00:00Z'));
    const r = importAppProfiles(text, s.profiles);
    expect(r.ok).toBe(true);
    expect(r.profiles.map((p) => p.id)).toEqual(['everyday-2', 'gaming-2', 'developer-2', 'laptop-2', 'touch-2', 'custom-2']);
    expect(r.profiles.every((p) => !p.builtin)).toBe(true);
    expect(r.profiles[1]!.name).toBe('Gaming (2)');
    expect(r.profiles[1]!.packages).toEqual([ref('Valve.Steam')]);
  });

  it('imports the illustrative fixture: inheritance remapped, invalid entries reported', () => {
    const r = importAppProfiles(fixture('illustrative-profiles.json'), emptySelection().profiles);
    expect(r.ok).toBe(true);
    expect(r.profiles.map((p) => p.id)).toEqual(['fixture-everyday', 'fixture-gaming', 'fixture-laptop-touch']);
    expect(r.profiles[2]!.inherits).toEqual(['fixture-everyday']);
    const s = emptySelection();
    s.profiles.push(...r.profiles);
    s.selectedProfiles = r.profiles.map((p) => p.id);
    const sel = resolveSelection(s);
    expect(sel.packages).toHaveLength(7);
    expect(sel.duplicates.map((d) => d.key)).toEqual(['winget:mozilla.firefox', 'winget:videolan.vlc', 'winget:7zip.7zip']);
  });

  it('imports a native WinGet export as one new, labelled custom profile', () => {
    const r = importAppProfiles(fixture('winget-export.json'), emptySelection().profiles, 'office-pc.json');
    expect(r.kind).toBe('winget');
    expect(r.profiles).toHaveLength(1);
    expect(r.profiles[0]).toMatchObject({ id: 'imported-office-pc', name: 'Imported: office-pc', category: 'custom', builtin: false });
    expect(r.profiles[0]!.packages).toHaveLength(5);
  });

  it('rejects unknown members such as credentials, and wrong formats', () => {
    const withPassword = JSON.stringify({ format: 'windows-deployment-builder/app-profiles', formatVersion: 1, profiles: [{ ...emptySelection().profiles[0], password: 'secret' }] });
    const r = importAppProfiles(withPassword, []);
    expect(r.ok).toBe(false);
    expect(r.errors.join(' ')).toMatch(/password/);
    expect(importAppProfiles('{"format":"something-else","profiles":[]}', []).ok).toBe(false);
    expect(importAppProfiles('not json', []).errors[0]).toMatch(/Not valid JSON/);
    expect(importAppProfiles('{"formatVersion":1}', []).errors.join(' ')).toMatch(/WinGet export/);
  });

  it('skips invalid identifiers inside an otherwise valid profile file', () => {
    const file = JSON.stringify({ format: 'windows-deployment-builder/app-profiles', formatVersion: 1, profiles: [{ id: 'x', name: 'X', category: 'custom', description: '', builtin: true, inherits: ['nope'], packages: [ref('Git.Git'), ref('Bad;Id'), ref('Foo Bar')] }] });
    const r = importAppProfiles(file, []);
    expect(r.profiles[0]!.packages).toEqual([ref('Git.Git')]);
    expect(r.profiles[0]!.builtin).toBe(false);
    expect(r.profiles[0]!.inherits).toEqual([]);
    expect(r.warnings.length).toBe(3);
  });
});

describe('catalog', () => {
  it('loads, is validated, and identifies entries by identifier and source', () => {
    expect(CATALOG.length).toBeGreaterThanOrEqual(40);
    for (const e of CATALOG) {
      if (e.validation.status === 'verified') expect(e.packageIdentifier, e.id).toBeTruthy();
      if (e.website) expect(e.website.startsWith('https://'), e.id).toBe(true);
    }
  });

  it('marks an app without a verified identifier as unresolved instead of guessing one', () => {
    const e = catalogEntryById('launchbox')!;
    expect(e.validation.status).toBe('unresolved');
    expect(e.packageIdentifier).toBeNull();
  });

  it('searches by name, purpose and identifier, and filters by category', () => {
    expect(searchCatalog('pdf').map((e) => e.id)).toEqual(expect.arrayContaining(['acrobat-reader', 'sumatrapdf']));
    expect(searchCatalog('git.git').map((e) => e.id)).toEqual(['git']);
    expect(searchCatalog('', 'gaming').every((e) => e.category === 'gaming')).toBe(true);
    expect(searchCatalog('no such app at all')).toEqual([]);
  });

  it('is not used to populate any owner-default profile', () => {
    expect(ownerDefaults().applications.selection.profiles.flatMap((p) => p.packages)).toEqual([]);
    expect(ADDED).toBe('added');
  });
});
