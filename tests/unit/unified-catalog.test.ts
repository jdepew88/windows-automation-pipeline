import { readFileSync, readdirSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { CATALOG, CATALOG_CATEGORIES, OVERLAP_GROUPS, catalogEntryById, catalogRef, entryKey, isManual, searchCatalog } from '../../src/engine/applications/catalog';
import { BUILTIN_PROFILES, CURRENT_PROFILE_REVISION, builtinProfile, builtinProfiles, isSelectableProfile } from '../../src/engine/applications/builtin';
import { packageKey } from '../../src/engine/applications/ids';
import { allProfiles, installable, manualItems, resolveSelection } from '../../src/engine/applications/selection';
import { addPackage, adoptCurrentProfiles, adoptProfileDefaults, importAppProfiles, exportAppProfiles, loadLibrary, mergeLibrary, removePackage, saveAsNewProfile, toggleProfile, usesEarlierProfiles } from '../../src/engine/applications/profiles';
import { applicationsConfig, wingetArguments } from '../../src/engine/applications';
import { catalogPolicy, matchInventory } from '../../src/engine/manager';
import { buildDeploymentPackage } from '../../src/engine/deployment';
import { readZip } from '../../src/engine/deployment/zip';
import { exportProfile, importProfile, ownerDefaults } from '../../src/engine/profiles';
import { SCHEMA_VERSION } from '../../src/engine/schema/profile';
import { generate } from '../../src/engine/pipeline';
import type { AppProfile, ApplicationsSelection } from '../../src/engine/schema/applications';
import { profile } from './helpers';

/**
 * Unified application catalog and the rebuilt profiles (2026-11-26): one catalog for the Deployment
 * Builder and the Application Manager, revision 2 of the built-in profiles for new deployments, and
 * revision 1 kept for everything saved before.
 */

const key = (id: string) => entryKey(catalogEntryById(id)!);
const ref = (id: string) => catalogRef(catalogEntryById(id)!)!;
const fresh = (): ApplicationsSelection => structuredClone(ownerDefaults().applications.selection);
const ids = (s: ApplicationsSelection) => resolveSelection(s).packages.map((p) => p.catalog?.id ?? p.key);
const defaultsOf = (id: string, rev: 1 | 2 = 2) => builtinProfile(id, rev)!.packages.map((r) => CATALOG.find((e) => entryKey(e) === packageKey(r))!.id);
const optionalOf = (id: string) => builtinProfile(id)!.optional!.map((r) => CATALOG.find((e) => entryKey(e) === packageKey(r))!.id);

describe('one catalog for both tools', () => {
  it('the catalog data file is read in exactly one place, which both the builder and the Application Manager import', () => {
    const files = (dir: string): string[] => readdirSync(new URL(`../../${dir}`, import.meta.url), { withFileTypes: true }).flatMap((d) => (d.isDirectory() ? files(`${dir}/${d.name}`) : /\.ts$/.test(d.name) ? [`${dir}/${d.name}`] : []));
    const readers = files('src').filter((f) => /data\/apps\/catalog\.json/.test(readFileSync(new URL(`../../${f}`, import.meta.url), 'utf8')));
    expect(readers).toEqual(['src/engine/applications/catalog.ts']);
    for (const f of ['src/manager/main.ts', 'src/engine/manager/index.ts', 'src/ui/app-selection.ts']) {
      expect(readFileSync(new URL(`../../${f}`, import.meta.url), 'utf8'), f).toMatch(/from '\.\.\/(?:engine\/)?applications\/catalog'|from '\.\.\/engine\/applications\/catalog'/);
    }
    expect(readdirSync(new URL('../../src/data/apps', import.meta.url)).filter((n) => /catalog/i.test(n))).toEqual(['catalog.json']);
  });

  it('the Application Manager policy covers every catalog entry, including the new ones, and recognises them installed', () => {
    // Every catalog entry with a package is in the manager's removal and upgrade policy.
    expect(new Set(catalogPolicy().packages.map((x) => x.catalogId))).toEqual(new Set(CATALOG.filter((e) => e.packageIdentifier).map((e) => e.id)));
    const m = matchInventory({ scannedUtc: '2026-11-26T00:00:00Z', method: 'test', note: '', packages: [{ id: 'SumatraPDF.SumatraPDF', version: '3.6.1', source: 'winget' }], programs: [] }, null);
    expect(m.get('sumatrapdf')?.state).toBe('installed');
    expect(m.get('rustdesk')?.state).not.toBe('installed');
  });

  it('new deployments and the Application Manager use the current profiles; allProfiles shows each built-in once', () => {
    expect(CURRENT_PROFILE_REVISION).toBe(2);
    expect(fresh().profileRevision).toBe(2);
    expect(allProfiles(fresh()).map((p) => p.id)).toEqual(BUILTIN_PROFILES.map((p) => p.id));
    expect(readFileSync(new URL('../../src/manager/main.ts', import.meta.url), 'utf8')).toMatch(/profileRevision: CURRENT_PROFILE_REVISION/);
  });
});

describe('every catalog application is discoverable in the Deployment Builder', () => {
  it('the unfiltered search lists the whole catalog, and every entry is found by its own name and has a category', () => {
    expect(searchCatalog('')).toHaveLength(CATALOG.length);
    for (const e of CATALOG) {
      expect(Object.keys(CATALOG_CATEGORIES), e.id).toContain(e.category);
      expect(searchCatalog(e.displayName).map((x) => x.id), e.id).toContain(e.id);
    }
  });

  it('search covers name, publisher and category; the category filter narrows it', () => {
    expect(searchCatalog('Valve').map((e) => e.id)).toContain('steam'); // publisher
    expect(searchCatalog('krzysztof').map((e) => e.id)).toEqual(['sumatrapdf']); // publisher of SumatraPDF
    const remote = searchCatalog('remote access').map((e) => e.id); // category label
    expect(remote).toEqual(expect.arrayContaining(['teamviewer', 'rustdesk', 'anydesk']));
    expect(searchCatalog('', 'remote').every((e) => e.category === 'remote')).toBe(true);
    expect(searchCatalog('desk', 'remote').map((e) => e.id).sort()).toEqual(expect.arrayContaining(['anydesk', 'rustdesk']));
    expect(searchCatalog('player', 'music').every((e) => e.category === 'music')).toBe(true);
  });

  it('RustDesk and TeamViewer are both in the catalog: TeamViewer through WinGet, RustDesk as an accurate manual follow-up', () => {
    expect(catalogEntryById('teamviewer')).toMatchObject({ packageIdentifier: 'TeamViewer.TeamViewer', source: 'winget' });
    const rd = catalogEntryById('rustdesk')!;
    expect(isManual(rd)).toBe(true);
    expect(rd.manual!.url).toBe('https://github.com/rustdesk/rustdesk/releases/latest');
    expect(rd.manual!.reason).toMatch(/Rechecked 2026-11-26/);
    expect(rd.manual!.instructions).toMatch(/do not set a permanent password/);
  });
});

describe('profiles, revision 2', () => {
  it('the profiles and their default application counts', () => {
    const counts = Object.fromEntries(BUILTIN_PROFILES.map((p) => [p.id, p.packages.length]));
    expect(counts).toEqual({
      core: 9, everyday: 5, gaming: 7, music: 5, 'student-office': 6, creator: 6, developer: 5, 'network-engineer': 8, 'remote-support': 1,
      workstation: 7, 'apple-devices': 1, 'android-devices': 0, laptop: 1, touch: 1,
    });
    expect(BUILTIN_PROFILES.every((p) => p.inherits.length === 0)).toBe(true);
  });

  it('Core Essentials: Chrome, 7-Zip, VLC, Notepad++, Bitwarden, a lightweight PDF reader, a photo viewer and the runtimes; utilities optional', () => {
    expect(defaultsOf('core')).toEqual(['chrome', '7zip', 'vlc', 'notepadpp', 'bitwarden', 'sumatrapdf', 'imageglass', 'vcredist-x64', 'vcredist-x86']);
    expect(optionalOf('core')).toEqual(expect.arrayContaining(['teracopy', 'everything', 'powertoys']));
    expect(ids(fresh())).toEqual(defaultsOf('core'));
  });

  it('the specified defaults of Everyday, Gamer, Music Lover, Student / Office, Content Creator, Developer, IT and Remote Support', () => {
    expect(defaultsOf('everyday')).toEqual(['zoom', 'teams', 'libreoffice', 'everything', 'revo-uninstaller']);
    expect(defaultsOf('gaming')).toEqual(['steam', 'epic', 'battlenet', 'gog-galaxy', 'ubisoft-connect', 'rockstar-launcher', 'discord']);
    expect(optionalOf('gaming')).toEqual(expect.arrayContaining(['ea-app', 'playnite', 'retroarch', 'obs-studio']));
    expect(defaultsOf('music')).toEqual(['spotify', 'musicbee', 'audacity', 'mpv-net', 'mp3tag']);
    expect(optionalOf('music')).toEqual(expect.arrayContaining(['foobar2000', 'mediamonkey', 'dopamine', 'itunes', 'apple-music', 'ffmpeg']));
    expect(defaultsOf('music')).not.toContain('vlc'); // shared player: already in Core Essentials
    expect(defaultsOf('student-office')).toEqual(['libreoffice', 'thunderbird', 'teams', 'pdfsam', 'zotero', 'anki']);
    expect(defaultsOf('creator')).toEqual(['obs-studio', 'gimp', 'inkscape', 'audacity', 'handbrake', 'sharex']);
    expect(optionalOf('creator')).toEqual(expect.arrayContaining(['krita', 'blender']));
    expect(defaultsOf('developer')).toEqual(['git', 'vscode', 'python-314', 'nodejs-lts', 'github-cli']);
    expect(optionalOf('developer')).toEqual(expect.arrayContaining(['docker-desktop', 'github-desktop', 'cursor', 'claude-code', 'powershell', 'wsl']));
    expect(defaultsOf('network-engineer')).toEqual(expect.arrayContaining(['hwinfo', 'crystaldiskinfo', 'winscp', 'putty', 'wireshark', 'rufus', 'revo-uninstaller']));
    expect(defaultsOf('remote-support')).toEqual(['teamviewer']);
    expect(optionalOf('remote-support')).toEqual(expect.arrayContaining(['rustdesk', 'anydesk']));
  });

  it('device profiles keep their behaviour: Apple Devices for an iPhone, nothing ticked for Android', () => {
    const s = fresh();
    s.devices.phone = 'android';
    expect(ids(s)).toEqual(ids(fresh()));
    s.devices.phone = 'iphone';
    expect(ids(s)).toContain('apple-devices');
    expect(isSelectableProfile('apple-devices')).toBe(false);
  });

  it('competing tools are never defaults twice: one PDF reader, one remote-support tool, no antivirus, no runtime recommendations, no peripheral software outside the workstation', () => {
    const selectable = BUILTIN_PROFILES.filter((p) => isSelectableProfile(p.id) && p.id !== 'workstation');
    const allDefaults = new Set(selectable.flatMap((p) => defaultsOf(p.id)));
    for (const [group, g] of Object.entries(OVERLAP_GROUPS)) {
      const members = (g.ids as readonly string[]).filter((x) => allDefaults.has(x));
      expect(members.length, group).toBeLessThanOrEqual(1);
    }
    for (const e of CATALOG.filter((x) => x.conflictGroup)) expect(allDefaults.has(e.id), e.id).toBe(false);
    for (const p of BUILTIN_PROFILES) for (const r of p.optional ?? []) expect(catalogEntryById(CATALOG.find((e) => entryKey(e) === packageKey(r))!.id)!.kind, `${p.id}: ${r.displayName}`).not.toBe('runtime');
    for (const e of CATALOG.filter((x) => x.category === 'peripherals' || x.kind === 'manufacturer')) expect(allDefaults.has(e.id), e.id).toBe(false);
  });
});

describe('additive profiles', () => {
  it('ticking several profiles combines their defaults; a shared package is planned and installed once, with every origin', () => {
    const s = fresh();
    for (const p of ['everyday', 'gaming', 'music', 'student-office', 'creator', 'developer', 'network-engineer', 'remote-support']) toggleProfile(s, p, true);
    const r = resolveSelection(s);
    const keys = r.packages.map((p) => p.key);
    expect(new Set(keys).size).toBe(keys.length);
    const want = new Set(['core', 'everyday', 'gaming', 'music', 'student-office', 'creator', 'developer', 'network-engineer', 'remote-support'].flatMap((p) => defaultsOf(p)));
    for (const id of want) expect(ids(s), id).toContain(id);
    expect(r.packages.find((p) => p.key === key('audacity'))!.origins.sort()).toEqual(['creator', 'music']);
    expect(r.packages.find((p) => p.key === key('libreoffice'))!.origins.sort()).toEqual(['everyday', 'student-office']);
    expect(r.duplicates.map((d) => d.key)).toEqual(expect.arrayContaining([key('audacity'), key('teams'), key('revo-uninstaller')]));
    const cfg = applicationsConfig(profile((p) => (p.applications.selection = s)));
    const pkgIds = cfg.packages.map((x) => x.packageIdentifier.toLowerCase());
    expect(new Set(pkgIds).size).toBe(pkgIds.length);
  });

  it('unticking a profile removes only what no other ticked profile selects', () => {
    const s = fresh();
    toggleProfile(s, 'music', true);
    toggleProfile(s, 'creator', true);
    toggleProfile(s, 'creator', false);
    expect(ids(s)).toContain('audacity'); // still selected by Music Lover
    expect(ids(s)).not.toContain('obs-studio');
  });

  it('user additions and removals survive profile changes', () => {
    const s = fresh();
    toggleProfile(s, 'gaming', true);
    removePackage(s, key('discord'));
    addPackage(s, ref('krita')); // the user's own addition (not recommended by Gamer)
    for (const [p, on] of [['music', true], ['gaming', false], ['developer', true], ['gaming', true], ['music', false]] as const) toggleProfile(s, p, on);
    expect(ids(s)).not.toContain('discord');
    expect(ids(s)).toContain('krita');
    expect(ids(s)).toContain('steam');
  });

  it('two remote-support tools can be selected deliberately; the plan says so, and nothing configures unattended access', () => {
    const s = fresh();
    toggleProfile(s, 'remote-support', true);
    addPackage(s, ref('rustdesk'));
    const r = resolveSelection(s);
    expect(ids(s)).toEqual(expect.arrayContaining(['teamviewer', 'rustdesk']));
    expect(r.notices.find((n) => n.kind === 'info' && /remote-support tools/.test(n.message))?.message).toMatch(/TeamViewer and RustDesk are all remote-support tools/);
    expect(r.groupConflicts).toEqual([]);
    const tv = r.packages.find((p) => p.key === key('teamviewer'))!;
    const args = wingetArguments('install', tv.ref).join(' ');
    expect(args).not.toMatch(/--override|--custom|password|unattended/i);
    expect(builtinProfile('remote-support')!.description).toMatch(/never turns on unattended access or sets a password/);
  });
});

describe('manual installation is never shown as automatic', () => {
  it('a manual entry is a follow-up, not an installer command, in the plan and in the package', () => {
    const s = fresh();
    addPackage(s, ref('rustdesk'));
    const r = resolveSelection(s);
    expect(installable(r).map((p) => p.catalog?.id)).not.toContain('rustdesk');
    expect(manualItems(r).map((p) => p.catalog?.id)).toEqual(['rustdesk']);
    const cfg = applicationsConfig(profile((p) => (p.applications.selection = s)));
    expect(cfg.packages.map((x) => x.packageIdentifier)).not.toContain('rustdesk');
    expect(JSON.stringify(cfg)).toMatch(/RustDesk/);
    for (const e of CATALOG.filter(isManual)) expect(e.interaction, e.id).toBe('required');
  });
});

describe('the generated package contains exactly the selected applications', () => {
  it('Core + Gamer + Student / Office, one app unticked and one added: the ZIP manifest and the WinGet list match the plan', () => {
    const p = profile((x) => {
      const s = x.applications.selection;
      toggleProfile(s, 'gaming', true);
      toggleProfile(s, 'student-office', true);
      removePackage(s, key('epic'));
      addPackage(s, ref('krita'));
    });
    const want = installable(resolveSelection(p.applications.selection)).map((x) => x.ref.packageIdentifier);
    expect(want).toContain('KDE.Krita');
    expect(want).not.toContain('EpicGames.EpicGamesLauncher');
    const pkg = buildDeploymentPackage(p, generate(p));
    const manifestIds = pkg.manifest.applications!.packages.map((x) => x.packageIdentifier);
    expect(manifestIds).toEqual(want);
    const native = JSON.parse(new TextDecoder().decode(readZip(pkg.zip).find((e) => e.path.endsWith('winget-packages.json'))!.data));
    expect(native.Sources.flatMap((src: { Packages: { PackageIdentifier: string }[] }) => src.Packages.map((x) => x.PackageIdentifier)).sort()).toEqual([...want].sort());
  });
});

describe('older configurations are never changed silently', () => {
  /** A deployment profile as the live site (schema 9) saves it today. */
  const v9 = (selected: string[]) => {
    const p = JSON.parse(exportProfile(ownerDefaults())) as { schemaVersion: number; applications: { selection: Record<string, unknown> } };
    p.schemaVersion = 9;
    delete p.applications.selection.profileRevision;
    p.applications.selection.selectedProfiles = selected;
    return JSON.stringify(p);
  };

  it('a schema 9 deployment profile keeps revision 1 and exactly its earlier applications, with a note; adopting is explicit', () => {
    expect(SCHEMA_VERSION).toBe(10);
    const r = importProfile(v9(['core', 'gaming', 'developer']));
    expect(r.errors).toEqual([]);
    const sel = r.profile!.applications.selection;
    expect(sel.profileRevision).toBe(1);
    expect(r.warnings.join(' ')).toMatch(/Use the new profile defaults/);
    const before = new Set([...defaultsOf('core', 1), ...defaultsOf('gaming', 1), ...defaultsOf('developer', 1)]);
    expect(new Set(ids(sel))).toEqual(before);
    expect(ids(sel)).toContain('teracopy');
    expect(ids(sel)).not.toContain('discord');
    expect(usesEarlierProfiles(sel)).toBe(true);
    removePackage(sel, key('epic'));
    adoptCurrentProfiles(sel);
    expect(sel.profileRevision).toBe(2);
    expect(sel.selectedProfiles).toEqual(['core', 'gaming', 'developer']);
    expect(ids(sel)).toEqual(expect.arrayContaining(['discord', 'battlenet', 'sumatrapdf']));
    expect(ids(sel)).not.toContain('epic'); // the user's own removal survives adoption
  });

  it('a saved custom profile from before the rebuild keeps resolving its parents in revision 1 inside a new deployment, until adopted', () => {
    const old = fresh();
    old.profileRevision = 1;
    toggleProfile(old, 'gaming', true);
    const saved = saveAsNewProfile(old, 'Gaming Desktop');
    delete saved.builtinRevision; // exactly as stored in the browser before revision 2 existed
    const before = ids(old);
    const lib = loadLibrary(exportAppProfiles([saved], null));
    expect(lib.profiles[0]!.builtinRevision).toBeUndefined();
    const now = fresh();
    expect(mergeLibrary(now, lib.profiles)).toBe(1);
    now.selectedProfiles = ['gaming-desktop'];
    expect(new Set(ids(now))).toEqual(new Set(before));
    expect(ids(now)).not.toContain('discord');
    // The pinned parents are named as such.
    expect(allProfiles(now).find((p) => p.id === 'gaming~1')?.name).toBe('Gaming (earlier defaults)');
    expect(adoptProfileDefaults(now, 'gaming-desktop')).toBe(true);
    expect(ids(now)).toEqual(expect.arrayContaining(['discord', 'battlenet', 'sumatrapdf']));
  });

  it('a custom profile saved now records revision 2; an imported older profile file keeps working unchanged', () => {
    const s = fresh();
    toggleProfile(s, 'music', true);
    const p = saveAsNewProfile(s, 'Music PC');
    expect(p.builtinRevision).toBe(2);
    const file = JSON.parse(exportAppProfiles([p], null)) as { profiles: AppProfile[] };
    delete file.profiles[0]!.builtinRevision;
    const imported = importAppProfiles(JSON.stringify(file), []);
    expect(imported.ok).toBe(true);
    const target = fresh();
    target.profiles.push(...imported.profiles);
    target.selectedProfiles = [imported.profiles[0]!.id];
    expect(ids(target)).toEqual(expect.arrayContaining(['musicbee', 'teracopy'])); // revision 1 Music Lover + Core
    expect(ids(target)).not.toContain('spotify');
  });

  it('a saved profile whose id is now a built-in id is renamed by the migration, and every reference follows', () => {
    const p = JSON.parse(v9([])) as { applications: { selection: Record<string, unknown> } };
    p.applications.selection.profiles = [{ id: 'remote-support', name: 'My remote tools', category: 'custom', description: '', builtin: false, inherits: ['core'], packages: [ref('anydesk')] }];
    p.applications.selection.selectedProfiles = ['remote-support'];
    const r = importProfile(JSON.stringify(p));
    expect(r.errors).toEqual([]);
    const sel = r.profile!.applications.selection;
    expect(sel.profiles.map((x) => x.id)).toEqual(['remote-support-2']);
    expect(sel.selectedProfiles).toEqual(['remote-support-2']);
    expect(ids(sel)).toContain('anydesk');
    expect(ids(sel)).not.toContain('teamviewer');
    expect(r.warnings.join(' ')).toMatch(/renamed/);
  });

  it('revision 1 is frozen: its definitions are those of the Phase 10 release', () => {
    expect(builtinProfiles(1).map((p) => p.id)).toEqual(['core', 'everyday', 'gaming', 'developer', 'network-engineer', 'music', 'creator', 'workstation', 'apple-devices', 'android-devices', 'laptop', 'touch']);
    expect(defaultsOf('core', 1)).toEqual(['chrome', 'vlc', '7zip', 'teracopy', 'bitwarden', 'vcredist-x64', 'vcredist-x86']);
    expect(defaultsOf('gaming', 1)).toEqual(['steam', 'epic']);
    expect(builtinProfile('network-engineer', 1)!.inherits).toEqual(['developer']);
  });
});
