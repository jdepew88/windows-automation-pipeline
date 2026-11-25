import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { generate } from '../../src/engine/pipeline';
import { exportProfile, importProfile, ownerDefaults } from '../../src/engine/profiles';
import { applicationAssets, applicationsConfig, embeddedAppFiles, collectorAsset } from '../../src/engine/applications';
import { builtinProfile } from '../../src/engine/applications/builtin';
import { resolveSelection } from '../../src/engine/applications/selection';
import { buildDeploymentPackage, buildManifest } from '../../src/engine/deployment';
import { readZip } from '../../src/engine/deployment/zip';
import { sha256, utf8 } from '../../src/engine/deployment/sha256';
import { importInventory, InventorySchema, type Inventory, type InventoryApp } from '../../src/engine/migration/inventory';
import { classificationCounts, matchApp, matchInventory, normalizeName } from '../../src/engine/migration/matching';
import { importBackupManifest } from '../../src/engine/migration/backup';
import { SETTINGS_ADAPTERS, adapterById } from '../../src/engine/migration/adapters';
import { applyMigration, attachBackup, decisionProblem, defaultDecisions, devFollowUps, migrationActive, restorePlanText, settingsRestoreActive } from '../../src/engine/migration/plan';
import { RestorationResultSchema } from '../../src/engine/applications/results';
import { validateProfile } from '../../src/engine/validation/validate';
import migrationSource from '../../src/engine/migration/scripts/WdbMigration.ps1?raw';
import { profile } from './helpers';

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- free-form JSON fixtures, mutated to build hostile input
type Loose = any;

/** Phase 6: application inventory, matching, migration profiles, settings backup references. */

const validate = (p: unknown) => validateProfile(p).issues;
const fixture = (rel: string) => readFileSync(fileURLToPath(new URL(rel, import.meta.url)), 'utf8');

let n = 0;
function app(displayName: string, extra: Partial<InventoryApp> = {}): InventoryApp {
  n++;
  return {
    inventoryId: `app-${n.toString(16).padStart(12, '0')}`,
    displayName,
    publisher: '',
    version: '1.0',
    source: 'registry',
    packageIdentifier: '',
    packageSource: '',
    scope: 'machine',
    architecture: 'x64',
    installLocation: '',
    detection: ['registry'],
    kind: 'application',
    hardware: false,
    storeIdentity: '',
    notes: [],
    ...extra,
  };
}
const wg = (displayName: string, id: string, extra: Partial<InventoryApp> = {}) => app(displayName, { source: 'winget', packageIdentifier: id, packageSource: 'winget', detection: ['winget', 'registry'], ...extra });

function inventory(apps: InventoryApp[], extra: Partial<Inventory> = {}): Inventory {
  return InventorySchema.parse({
    format: 'windows-deployment-builder/app-inventory',
    formatVersion: 1,
    inventoryId: '0123456789abcdef',
    exportedUtc: '2026-10-21T11:00:00Z',
    collector: { name: 'WdbMigration.ps1', version: '1.0.0', powershell: '5.1.26100.1', wingetMethod: 'Microsoft.WinGet.Client' },
    source: { osName: 'Microsoft Windows 11 Pro', osVersion: '10.0.26100', osBuild: '26100', displayVersion: '24H2', architecture: 'x64' },
    applications: apps,
    excludedCounts: { systemComponents: 3, updates: 2, frameworks: 1, resourcePackages: 0, withoutName: 0 },
    devEnvironment: {
      git: { installed: true, version: '2.51.0', globalConfig: true },
      vscodeExtensions: [{ id: 'ms-python.python', version: '2025.1.0' }],
      cursorExtensions: [],
      powershellModules: [{ name: 'Posh-Git', versions: ['1.1.0'], scope: 'user', repository: 'PSGallery' }],
      python: [],
      pythonManagers: [],
      node: { version: '', managers: [{ name: 'nvm-windows', versions: ['v20.11.1', 'v22.20.0'] }] },
      docker: { installed: true, settingsPresent: true },
      claudeCode: { installed: true, method: 'native' },
      repositories: [{ name: 'project-a', root: '%USERPROFILE%\\src', remote: 'https://github.com/example/project-a.git' }],
    },
    settings: [],
    warnings: [],
    backup: null,
    ...extra,
  });
}

/** A backup manifest exactly like WdbMigration.ps1 writes it, for the given adapters and files. */
function backupManifest(files: Record<string, Record<string, string>> = { vscode: { 'settings.json': '{}' }, git: { gitconfig: '[user]\n\tname = A\n' } }) {
  const adapters = Object.entries(files).map(([id, items]) => ({
    id,
    name: adapterById(id)?.name ?? id,
    adapterVersion: 1,
    restoreMode: adapterById(id)?.restoreMode ?? 'automatic',
    items: Object.entries(items).map(([logical, text]) => ({ logical, kind: 'file', path: `data/${id}/${logical}`, size: utf8(text).length, sha256: sha256(utf8(text)) })),
    excluded: [],
    notes: [],
  }));
  return {
    format: 'windows-deployment-builder/app-backup',
    formatVersion: 1,
    backupId: 'a1b2c3d4e5f60718',
    folderName: 'WDB-AppBackup-20261021-120000-a1b2c3',
    createdUtc: '2026-10-21T12:00:00Z',
    collector: { name: 'WdbMigration.ps1', version: '1.0.0' },
    source: { osName: 'Microsoft Windows 11 Pro', osBuild: '26100', architecture: 'x64' },
    inventoryId: '0123456789abcdef',
    adapters,
    unsupported: [],
    totals: { files: 2, bytes: 10 },
    notice: 'Application settings only.',
  };
}
const bytesOf = (v: unknown) => utf8(JSON.stringify(v, null, 2) + '\n');

describe('inventory import (format, validation, hostile input)', () => {
  const good = inventory([wg('Git', 'Git.Git')]);
  it('accepts a valid inventory and never needs to execute anything in it', () => {
    const r = importInventory(JSON.stringify(good));
    expect(r.ok).toBe(true);
    expect(r.inventory!.applications[0]!.packageIdentifier).toBe('Git.Git');
  });

  it('rejects non-JSON, native WinGet lists, backup manifests, other versions and unknown members', () => {
    expect(importInventory('not json').errors[0]).toMatch(/Not valid JSON/);
    expect(importInventory(JSON.stringify({ Sources: [] })).errors[0]).toMatch(/native "winget export"/);
    expect(importInventory(JSON.stringify(backupManifest())).errors[0]).toMatch(/backup manifest/);
    expect(importInventory(JSON.stringify({ ...good, formatVersion: 2 })).errors[0]).toMatch(/version 2 is not supported/);
    const extra = structuredClone(good) as unknown as Record<string, unknown>;
    (extra.applications as Record<string, unknown>[])[0]!.uninstallString = 'cmd /c del C:\\*';
    expect(importInventory(JSON.stringify(extra)).ok).toBe(false);
    const cmd = structuredClone(good) as unknown as Record<string, unknown>;
    cmd.postImport = 'Invoke-Expression evil';
    expect(importInventory(JSON.stringify(cmd)).ok).toBe(false);
  });

  it('rejects malformed ids, traversal paths, control characters, credentials in remotes and duplicates', () => {
    const bad = (mutate: (x: Loose) => void) => {
      const x = structuredClone(good) as unknown as Loose;
      mutate(x);
      return importInventory(JSON.stringify(x)).ok;
    };
    expect(bad((x) => (x.applications[0].inventoryId = 'app-../../x'))).toBe(false);
    expect(bad((x) => (x.applications[0].installLocation = '%PROGRAMFILES%\\..\\..\\Windows'))).toBe(false);
    expect(bad((x) => (x.applications[0].displayName = 'Git\u0007'))).toBe(false);
    expect(bad((x) => (x.applications[0].displayName = ''))).toBe(false);
    expect(bad((x) => (x.applications[0].source = 'script'))).toBe(false);
    expect(bad((x) => (x.devEnvironment.repositories = [{ name: 'a', root: '', remote: 'https://alex:ghp_x@github.com/a.git' }]))).toBe(false);
    expect(bad((x) => (x.devEnvironment.vscodeExtensions = [{ id: 'x; rm -rf', version: '1' }]))).toBe(false);
    expect(bad((x) => x.applications.push(structuredClone(x.applications[0])))).toBe(false);
    expect(bad((x) => (x.review = { reviewedUtc: '', decisions: [{ inventoryId: 'app-ffffffffffff', decision: 'restore', confirmed: false }], mappings: [], unresolved: [] }))).toBe(false);
    expect(importInventory('x'.repeat(5 * 1024 * 1024 + 1)).errors[0]).toMatch(/larger than 5 MB/);
  });

  it('keeps inventory JSON distinct from the native WinGet format', () => {
    expect(JSON.stringify(good)).not.toContain('"Sources"');
    expect(good.format).toBe('windows-deployment-builder/app-inventory');
  });
});

describe('catalog matching (exact, strong, possible, unknown; never a guessed install)', () => {
  it('an identifier WinGet reported is an exact match: catalog entry, or a verified custom WinGet id outside the catalog', () => {
    const git = matchApp(wg('Git', 'Git.Git'));
    expect([git.classification, git.confidence, git.recommendation, git.catalog?.id]).toEqual(['catalog', 'exact', 'restore', 'git']);
    const custom = matchApp(wg('Example Tool', 'Example.Tool'));
    expect([custom.classification, custom.confidence, custom.ref?.packageIdentifier, custom.recommendation]).toEqual(['winget', 'exact', 'Example.Tool', 'restore']);
    const store = matchApp(app('WhatsApp', { source: 'msstore', packageIdentifier: '9NKSQGP7F2NH', packageSource: 'msstore' }));
    expect([store.classification, store.confidence, store.catalog?.id]).toEqual(['catalog', 'exact', 'whatsapp']);
    const storeOther = matchApp(app('Some Store App', { source: 'msstore', packageIdentifier: '9ABCDEFGHIJK', packageSource: 'msstore' }));
    expect([storeOther.classification, storeOther.ref?.source]).toEqual(['msstore', 'msstore']);
  });

  it('an app deliberately left out of the curated catalog is offered as optional, not added to the catalog', () => {
    // Brave is deliberately not in the curated catalog (owner decision); Chrome Canary joined it in Phase 10.
    const m = matchApp(wg('Brave', 'Brave.Brave'));
    expect(m.classification).toBe('winget');
  });

  it('name and publisher together are a strong match; a name alone, or extra words, is only possible', () => {
    const strong = matchApp(app('PuTTY release 0.83 (64-bit)', { publisher: 'Simon Tatham' }));
    expect([strong.classification, strong.confidence, strong.catalog?.id, strong.recommendation, strong.needsConfirmation]).toEqual(['catalog', 'strong', 'putty', 'optional', false]);
    const possible = matchApp(app('PuTTY', { publisher: 'Someone Else' }));
    expect([possible.confidence, possible.recommendation, possible.needsConfirmation]).toEqual(['possible', 'manual', true]);
    const addin = matchApp(app('Microsoft Teams Meeting Add-in for Microsoft Office', { publisher: 'Microsoft' }));
    expect(addin.confidence).not.toBe('strong');
  });

  it('a possible match cannot be restored until it is confirmed', () => {
    const possible = matchApp(app('PuTTY', { publisher: 'Someone Else' }));
    expect(decisionProblem(possible, { decision: 'restore', confirmed: false })).toMatch(/Confirm the match/);
    expect(decisionProblem(possible, { decision: 'restore', confirmed: true })).toBeUndefined();
  });

  it('unknown applications, Store packages without a product id and invalid identifiers are never installable', () => {
    const unknown = matchApp(app('Contoso Field Tool', { publisher: 'Contoso' }));
    expect([unknown.classification, unknown.ref, unknown.allowed]).toEqual(['unknown', undefined, ['manual', 'exclude']]);
    expect(decisionProblem(unknown, { decision: 'restore', confirmed: true })).toBeDefined();
    const appx = matchApp(app('Contoso.Notes', { source: 'appx', storeIdentity: 'Contoso.Notes_abc123', detection: ['appx'], scope: 'user' }));
    expect([appx.classification, appx.confidence, appx.ref, appx.recommendation]).toEqual(['msstore', 'exact-identity', undefined, 'manual']);
    const invalid = matchApp(wg('Bad', 'not an id'));
    expect([invalid.classification, invalid.ref]).toEqual(['unknown', undefined]);
    const otherSource = matchApp(app('Private', { source: 'winget', packageIdentifier: 'Corp.Tool', packageSource: 'corp-repo' }));
    expect(otherSource.reasons.join(' ')).toMatch(/does not install from/);
  });

  it('manual catalog entries stay manual; portable entries are recognised by name', () => {
    const rustdesk = matchApp(app('RustDesk', { publisher: 'Purslane Ltd.' }));
    expect([rustdesk.classification, rustdesk.ref?.source, rustdesk.recommendation]).toEqual(['manual', 'catalog', 'manual']);
    const rufus = matchApp(app('Rufus', { source: 'portable', kind: 'portable', publisher: 'Akeo Consulting' }));
    expect(rufus.classification).toBe('portable');
  });

  it('hardware-specific software and Windows components are excluded and never restored automatically', () => {
    const hw = matchApp(wg('Dell Command | Update', 'Dell.CommandUpdate', { hardware: true }));
    expect([hw.recommendation, hw.allowed.includes('restore'), hw.reasons.join(' ')]).toEqual(['exclude', false, expect.stringMatching(/hardware-aware driver provisioning/)]);
    const sys = matchApp(app('Microsoft.WindowsCalculator', { source: 'appx', kind: 'system', detection: ['appx'] }));
    expect([sys.system, sys.allowed]).toEqual([true, ['exclude']]);
  });

  it('records of the same package are merged; counts ignore Windows components', () => {
    const items = matchInventory(inventory([wg('Git', 'Git.Git'), app('Git', { publisher: 'The Git Development Community' }), app('Microsoft.WindowsCalculator', { source: 'appx', kind: 'system', detection: ['appx'] })]));
    const git = items.filter((i) => i.catalog?.id === 'git');
    expect(git).toHaveLength(1);
    expect(git[0]!.confidence).toBe('exact');
    expect(git[0]!.merged).toHaveLength(1);
    expect(classificationCounts(items).catalog).toBe(1);
  });

  it('notes architecture differences for Arm64 targets', () => {
    const m = matchApp(wg('TeraCopy', 'CodeSector.TeraCopy'), 'arm64');
    expect(m.reasons.join(' ')).toMatch(/Arm64/);
  });

  it('normalises versions, architectures and editions out of names', () => {
    expect(normalizeName('Microsoft Visual Studio Code (User)')).toBe('microsoft visual studio code');
    expect(normalizeName('7-Zip 24.09 (x64)')).toBe('7 zip');
    expect(normalizeName('Mozilla Firefox (x64 en-US)')).toBe('mozilla firefox en us');
  });
});

describe('migration profiles (review -> named profile on top of a base profile)', () => {
  const inv = () =>
    inventory([
      wg('Git', 'Git.Git'),
      wg('Example Tool', 'Example.Tool'),
      wg('Obsidian', 'Obsidian.Obsidian'),
      wg('Wireshark', 'WiresharkFoundation.Wireshark'),
      app('Contoso Field Tool', { publisher: 'Contoso' }),
      app('RustDesk', { publisher: 'Purslane Ltd.' }),
    ]);

  it('builds an expanded Network Engineer profile; the built-in profile is never changed', () => {
    const before = structuredClone(builtinProfile('network-engineer'));
    const p = profile();
    const i = inv();
    const items = matchInventory(i);
    const d = defaultDecisions(items);
    const byName = (s: string) => items.find((x) => x.app.displayName === s)!;
    d.set(byName('Obsidian').id, { decision: 'optional', confirmed: false });
    d.set(byName('Wireshark').id, { decision: 'exclude', confirmed: false });
    d.set(byName('Contoso Field Tool').id, { decision: 'manual', confirmed: false });
    // Phase 10 added a built-in "Personal Workstation" profile; names must stay unique, so this test uses another.
    const r = applyMigration(p, i, items, d, { name: "Alex's Workstation" });
    expect(r.profile.name).toBe("Alex's Workstation");
    expect(r.profile.inherits).toEqual(['network-engineer']);
    // RustDesk (a manual catalog entry of Core Essentials, not of the base) becomes its catalog follow-up.
    expect(r.profile.packages.map((x) => `${x.source}:${x.packageIdentifier}`)).toEqual(['winget:Example.Tool', 'catalog:rustdesk']);
    expect(r.profile.optional?.map((x) => x.packageIdentifier)).toEqual(['Obsidian.Obsidian']);
    expect(r.profile.excluded).toEqual(['winget:wiresharkfoundation.wireshark']);
    expect(r.manualAdded).toBe(1);
    expect(p.additionalSoftware.items.at(-1)).toMatchObject({ id: `migration-${byName('Contoso Field Tool').id}`, execution: 'manual', name: 'Contoso Field Tool' });
    expect(builtinProfile('network-engineer')).toEqual(before);
    const keys = resolveSelection(p.applications.selection).packages.map((x) => x.key);
    expect(keys).toContain('winget:git.git');
    expect(keys).toContain('winget:example.tool');
    expect(keys).not.toContain('winget:wiresharkfoundation.wireshark');
    expect(p.applications.selection.selectedProfiles).toContain(r.profile.id);
    expect(p.applications.selection.selectedProfiles).not.toContain('network-engineer');
    expect(p.migration.enabled).toBe(true);
    expect(p.migration.decisions.find((x) => x.displayName === 'Contoso Field Tool')!.key).toMatch(/^additional:migration-app-/);
  });

  it('other names are allowed (Gaming Desktop, Customer Office PC); a clash gets a suffix', () => {
    const p = profile();
    const i = inv();
    const items = matchInventory(i);
    const a = applyMigration(p, i, items, defaultDecisions(items), { name: 'Gaming Desktop', baseProfile: 'gaming' });
    const b = applyMigration(p, i, items, defaultDecisions(items), { name: 'Gaming Desktop', baseProfile: 'gaming' });
    expect([a.profile.name, b.profile.name]).toEqual(['Gaming Desktop', 'Gaming Desktop (2)']);
    expect(a.profile.id).not.toBe(b.profile.id);
  });

  it('refuses decisions that are not allowed (no silent substitution)', () => {
    const p = profile();
    const i = inv();
    const items = matchInventory(i);
    const d = defaultDecisions(items);
    d.set(items.find((x) => x.app.displayName === 'Contoso Field Tool')!.id, { decision: 'restore', confirmed: true });
    expect(() => applyMigration(p, i, items, d)).toThrow(/Contoso Field Tool/);
  });

  it('lists development-environment follow-ups instead of guessing installations', () => {
    const f = devFollowUps(inv());
    expect(f.join('\n')).toMatch(/nvm-windows \(versions v20.11.1, v22.20.0\).*standalone Node.js package is not a replacement/);
    expect(f.join('\n')).toMatch(/Install-Module.*Posh-Git 1.1.0/);
    expect(f.join('\n')).toMatch(/git clone https:\/\/github.com\/example\/project-a.git \(never cloned automatically/);
    expect(f.join('\n')).toMatch(/Docker Desktop: settings, images, containers and volumes are not migrated/);
    expect(f.join('\n')).toMatch(/Visual Studio Code extensions \(1\): ms-python.python/);
    expect(devFollowUps(inv(), ['vscode']).join('\n')).not.toMatch(/Visual Studio Code extensions/);
  });

  it('profiles from earlier phases import with migration off and generate the same configuration', () => {
    for (const f of ['p5-network-engineer.profile.json', 'p43-gaming.profile.json', 'p4-owner-default.profile.json', 'm1-owner-default.profile.json']) {
      const r = importProfile(fixture(`fixtures/${f}`));
      expect(r.errors, f).toEqual([]);
      expect(r.profile!.migration, f).toEqual({ enabled: false, source: null, decisions: [], backup: null, settings: [], followUps: [] });
      expect(migrationActive(r.profile!), f).toBe(false);
      const c = applicationsConfig(r.profile!);
      expect('settingsRestore' in c || 'migration' in c, f).toBe(false);
    }
  });

  it('a migrated profile survives export and import', () => {
    const p = profile();
    const i = inv();
    const items = matchInventory(i);
    applyMigration(p, i, items, defaultDecisions(items));
    attachBackup(p, importBackupManifest(bytesOf(backupManifest())).reference!);
    const back = importProfile(exportProfile(p));
    expect(back.errors).toEqual([]);
    expect(back.profile!.migration).toEqual(p.migration);
  });
});

describe('settings backup manifests (what the website reads and pins)', () => {
  it('pins the SHA-256 of the exact manifest bytes and offers the supported adapters', () => {
    const bytes = bytesOf(backupManifest());
    const r = importBackupManifest(bytes);
    expect(r.ok).toBe(true);
    expect(r.reference).toMatchObject({ backupId: 'a1b2c3d4e5f60718', manifestSha256: sha256(bytes), folderName: 'WDB-AppBackup-20261021-120000-a1b2c3' });
    const p = profile();
    attachBackup(p, r.reference!);
    expect(p.migration.settings.map((s) => [s.adapterId, s.enabled, s.conflict, s.installExtensions])).toEqual([
      ['vscode', true, 'keepExisting', true],
      ['git', true, 'keepExisting', false],
    ]);
  });

  it('rejects traversal, items an adapter does not restore, duplicates, bad hashes and other formats', () => {
    const m = backupManifest();
    const mutate = (f: (x: Loose) => void) => {
      const x = structuredClone(m);
      f(x);
      return importBackupManifest(bytesOf(x));
    };
    expect(mutate((x) => (x.adapters[0].items[0].path = 'data/vscode/../../../evil')).errors.join(' ')).toMatch(/not where this adapter keeps/);
    expect(mutate((x) => ((x.adapters[0].items[0].logical = 'state.vscdb'), (x.adapters[0].items[0].path = 'data/vscode/state.vscdb'))).errors.join(' ')).toMatch(/not an item this adapter restores/);
    expect(mutate((x) => x.adapters.push(structuredClone(x.adapters[0]))).errors.join(' ')).toMatch(/listed twice/);
    expect(mutate((x) => (x.adapters[0].items[0].sha256 = 'abc')).ok).toBe(false);
    expect(mutate((x) => (x.formatVersion = 2)).ok).toBe(false);
    expect(mutate((x) => (x.adapters[0].script = 'Remove-Item C:\\')).ok).toBe(false);
    expect(mutate((x) => ((x.adapters[0].id = 'future-app'), (x.adapters[0].items = [])))).toMatchObject({ ok: true, warnings: [expect.stringMatching(/not known to this version/)] });
    expect(importBackupManifest(new Uint8Array([0xff, 0xfe, 0x00])).ok).toBe(false);
  });
});

describe('deployment generation with a restoration plan', () => {
  function migrated() {
    const p = profile();
    const i = inventory([wg('Microsoft Visual Studio Code', 'Microsoft.VisualStudioCode'), wg('Git', 'Git.Git'), app('Contoso Field Tool', { publisher: 'Contoso' })]);
    const items = matchInventory(i);
    const d = defaultDecisions(items);
    d.set(items.find((x) => x.app.displayName === 'Contoso Field Tool')!.id, { decision: 'manual', confirmed: false });
    applyMigration(p, i, items, d, { baseProfile: '' });
    attachBackup(p, importBackupManifest(bytesOf(backupManifest())).reference!);
    return p;
  }

  it('settings wait for their applications; the plan pins the backup; the engine is 1.4.0', () => {
    const p = migrated();
    expect(settingsRestoreActive(p)).toBe(true);
    const c = applicationsConfig(p);
    expect(c.engineVersion).toBe('1.4.0');
    expect(c.settingsRestore).toEqual({
      backupId: 'a1b2c3d4e5f60718',
      manifestSha256: p.migration.backup!.manifestSha256,
      folderName: 'WDB-AppBackup-20261021-120000-a1b2c3',
      adapters: [
        { id: 'vscode', name: 'Visual Studio Code', conflict: 'keepExisting', after: ['winget:microsoft.visualstudiocode'], installExtensions: true },
        { id: 'git', name: 'Git (global configuration)', conflict: 'keepExisting', after: ['winget:git.git'], installExtensions: false },
      ],
    });
    expect(c.migration!.applications.map((a) => a.decision)).toEqual(expect.arrayContaining(['restore', 'manual']));
  });

  it('embeds the restore library only when settings are restored; the package never contains backup data', () => {
    const p = migrated();
    expect(embeddedAppFiles(p)).toContain('WdbMigration.ps1');
    expect(embeddedAppFiles(profile())).not.toContain('WdbMigration.ps1');
    expect(applicationAssets(p).map((a) => a.name)).toEqual(expect.arrayContaining(['WdbMigration.ps1', 'restore-plan.txt']));
    const r = generate(p);
    expect(r.ok).toBe(true);
    expect(r.xml).toContain('Applications\\WdbMigration.ps1');
    expect(r.xml).not.toMatch(/diskpart|clean\b|format\s+fs/i);
    expect(r.xml).not.toContain('keyMaterial');
    const pkg = buildDeploymentPackage(p, r);
    const paths = readZip(pkg.zip).map((e) => e.path);
    expect(paths).toContain('WindowsDeployment/scripts/applications/restore-plan.txt');
    expect(paths.some((x) => /backups\/|\/data\//.test(x))).toBe(false);
    expect(pkg.manifest.migration).toMatchObject({ decisions: { restore: 2, manual: 1 }, settingsRestore: { expectedLocation: 'WindowsDeployment\\backups\\WDB-AppBackup-20261021-120000-a1b2c3', includedInPackage: false } });
    expect(new TextDecoder().decode(readZip(pkg.zip).find((e) => e.path === 'WindowsDeployment/README.txt')!.data)).toContain('WindowsDeployment\\backups\\WDB-AppBackup-20261021-120000-a1b2c3');
  });

  it('a profile without a restoration plan generates no Phase 6 blocks', () => {
    const p = profile();
    const c = applicationsConfig(p);
    expect('settingsRestore' in c).toBe(false);
    expect('migration' in c).toBe(false);
    expect('migration' in buildManifest(p).manifest).toBe(false);
  });

  it('the restoration plan text names every group and what is never restored', () => {
    const t = restorePlanText(migrated());
    expect(t).toMatch(/Reinstalled automatically .* \(2\)/);
    expect(t).toMatch(/Manual installation \(follow-up list\) \(1\)/);
    expect(t).toContain('WindowsDeployment\\backups\\WDB-AppBackup-20261021-120000-a1b2c3');
    expect(t).toMatch(/Not restored by design: passwords, tokens, private keys/);
  });

  it('validation: settings without a backup, or with application provisioning off, are errors', () => {
    const p = migrated();
    p.migration.backup = null;
    expect(validate(p).filter((i) => i.severity === 'error').map((i) => i.message).join(' ')).toMatch(/no backup manifest is attached/);
    const q = migrated();
    q.applications.enabled = false;
    expect(validate(q).filter((i) => i.severity === 'error').map((i) => i.message).join(' ')).toMatch(/turn on application provisioning/);
    const w = migrated();
    w.migration.settings[0]!.conflict = 'restoreBackup';
    expect(validate(w).filter((i) => i.severity === 'warning').map((i) => i.message).join(' ')).toMatch(/replaced \(the original is kept/);
  });

  it('the restoration result schema accepts the documented outcome vocabulary', () => {
    const r = RestorationResultSchema.safeParse({
      format: 'windows-deployment-builder/restoration-result',
      formatVersion: 1,
      generatedUtc: '2026-10-22T10:00:00Z',
      stageStatus: 'CompletedWithFollowUp',
      inventoryId: '0123456789abcdef',
      backupId: 'a1b2c3d4e5f60718',
      backup: { status: 'Staged', message: '' },
      applications: [{ inventoryId: 'app-000000000001', displayName: 'Git', decision: 'restore', key: 'winget:git.git', outcome: 'InstalledSuccessfully', detail: '' }],
      settings: [{ adapterId: 'git', name: 'Git', outcome: 'ConfigurationRestored', detail: '', items: [{ logical: 'gitconfig', action: 'written', detail: '' }], followUps: [], attempts: 1 }],
      followUps: [],
      counts: { InstalledSuccessfully: 1, ConfigurationRestored: 1 },
    });
    expect(r.success ? [] : r.error.issues).toEqual([]);
  });
});

describe('collector and restore library (static checks)', () => {
  it('ships as one Windows PowerShell 5.1 script with the documented modes and no execution of imported data', () => {
    expect(migrationSource).toMatch(/^#Requires -Version 5\.1/);
    expect(migrationSource).toContain("[ValidateSet('Inventory', 'PreviewBackup', 'Backup', 'Validate', 'PreviewRestore', 'Restore', 'Library')]");
    expect(migrationSource).toContain('Set-StrictMode -Version 2.0');
    expect(migrationSource).not.toMatch(/Invoke-Expression|\biex\b|DownloadString|Invoke-WebRequest|Invoke-RestMethod|Net\.WebClient|Start-BitsTransfer|Set-ExecutionPolicy|Add-MpPreference/i);
    expect(migrationSource).not.toMatch(/Format-Volume|Clear-Disk|diskpart|Initialize-Disk|bcdedit|New-Partition|Uninstall-Package|msiexec/i);
    expect(migrationSource).not.toMatch(/UninstallString'|QuietUninstallString/);
    expect(migrationSource).toContain('DtdProcessing = [System.Xml.DtdProcessing]::Prohibit');
    expect(collectorAsset().name).toBe('WdbMigration.ps1');
  });

  it('never reads credential stores, browser profiles or private keys', () => {
    // The documentation names these things; no code path may read them.
    expect(migrationSource).not.toMatch(/Login Data|Network\\Cookies|cmdkey|CredRead|vaultcmd|Microsoft\\Credentials|Microsoft\\Protect|Local State|\.ssh\\id_/i);
  });

  it('the TypeScript adapter list matches the script (ids, restore modes, applications, items)', () => {
    for (const a of SETTINGS_ADAPTERS) {
      const block = migrationSource.slice(migrationSource.indexOf(`    '${a.id}' = @{`));
      const body = block.slice(0, block.indexOf("\n    }\n") > 0 ? block.indexOf("\n    }\n") : block.indexOf("\n    }\r\n"));
      expect(body, a.id).toContain(`name = '${a.name.replace(/'/g, "''")}'`);
      expect(body, a.id).toContain(`restoreMode = '${a.restoreMode}'`);
      expect(body, a.id).toContain(`requiresApp = $${a.requiresApp}`);
      expect(body, a.id).toContain(`appKeys = @(${a.appKeys.map((k) => `'${k}'`).join(', ')})`);
      for (const i of a.items) expect(body, `${a.id} ${i.logical}`).toContain(`logical = '${i.logical}'; kind = '${i.kind}'`);
    }
    const ids = [...migrationSource.matchAll(/^ {4}'([a-z0-9-]+)' = @\{$/gm)].map((m) => m[1]);
    expect(ids).toEqual(SETTINGS_ADAPTERS.map((a) => a.id));
  });

  it('the owner default starts without a restoration plan', () => {
    expect(ownerDefaults().migration).toEqual({ enabled: false, source: null, decisions: [], backup: null, settings: [], followUps: [] });
  });
});
