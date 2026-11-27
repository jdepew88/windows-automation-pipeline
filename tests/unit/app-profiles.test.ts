import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import catalogJson from '../../src/data/apps/catalog.json';
import { generate } from '../../src/engine/pipeline';
import { importProfile, ownerDefaults } from '../../src/engine/profiles';
import {
  CATALOG,
  CATALOG_CATEGORIES,
  CATALOG_EXCLUDED,
  PORTABLE_EXE,
  SHORTCUT_NAME,
  catalogEntryById,
  catalogRef,
  entryKey,
  methodOf,
} from '../../src/engine/applications/catalog';
import { BUILTIN_REFERENCED, UNIVERSAL_PROFILES, builtinProfile as currentBuiltin, builtinProfiles, deviceProfiles, isSelectableProfile } from '../../src/engine/applications/builtin';
import { MSSTORE_ID, WINGET_ID, packageKey } from '../../src/engine/applications/ids';
import { removalForCatalogId } from '../../src/engine/applications/catalog';
import { installable, resolveSelection } from '../../src/engine/applications/selection';
import {
  addPackage,
  duplicateProfile,
  exportAppProfiles,
  importAppProfiles,
  loadLibrary,
  removePackage,
  resetOverrides,
  resetSelection,
  restoreProfileDefaults,
  saveAsNewProfile,
  toggleProfile,
  updateProfileFromSelection,
} from '../../src/engine/applications/profiles';
import { applicationsConfig } from '../../src/engine/applications';
import { exportWinGetDocument } from '../../src/engine/applications/winget-json';
import { buildDeploymentPackage } from '../../src/engine/deployment';
import { readZip } from '../../src/engine/deployment/zip';
import type { ApplicationsSelection, Devices } from '../../src/engine/schema/applications';
import { ProfileLibrary, LIBRARY_KEY, type Storage } from '../../src/ui/library';
import engineSource from '../../src/engine/applications/scripts/ApplicationEngine.ps1?raw';
import { commandLines, errorsOf, generateOk, noApps, profile } from './helpers';

const fixture = (name: string) => readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8');
const M1_XML = fixture('m1-owner-default-alex.xml');
const id = (catalogId: string) => entryKey(catalogEntryById(catalogId)!);
const ref = (catalogId: string) => catalogRef(catalogEntryById(catalogId)!)!;
/**
 * These tests pin revision 1 of the built-in profiles (frozen in profiles-v1.json): the definitions
 * every deployment and saved profile created before the 2026-11-26 rebuild keeps. Revision 2 is
 * covered by unified-catalog.test.ts.
 */
const BUILTIN_PROFILES = builtinProfiles(1);
const builtinProfile = (id: string) => currentBuiltin(id, 1);
const fresh = (): ApplicationsSelection => ({ ...structuredClone(ownerDefaults().applications.selection), profileRevision: 1 });
const selected = (s: ApplicationsSelection) => resolveSelection(s).packages.map((p) => p.catalog?.id ?? p.key);
const devices = (d: Partial<Devices>): Devices => ({ phone: 'none', ipad: false, extraIphone: false, androidTablet: false, ...d });
// Phase 10 (owner's instruction): RustDesk is no longer a Core Essentials default; it is optional there.
const CORE = ['chrome', 'vlc', '7zip', 'teracopy', 'bitwarden', 'vcredist-x64', 'vcredist-x86'];
const verification = JSON.parse(fixture('../../../docs/phase-4-2-application-profiles/verification-2026-10-21.json')) as { id: string; source: string; ok: boolean; publisher: string }[];
const repository = JSON.parse(fixture('../../../docs/phase-10-application-manager/winget-verification-2026-10-25.json')) as { results: { id: string; found: boolean }[] };
const expansion = JSON.parse(fixture('../../../docs/unified-app-catalog/winget-verification-2026-11-26.json')) as { results: { id: string; canonicalId?: string; found: boolean; allHashed?: boolean }[] };

describe('catalog (Phase 4.2)', () => {
  it('has unique ids and package keys, valid categories, and only https links', () => {
    expect(new Set(CATALOG.map((e) => e.id)).size).toBe(CATALOG.length);
    const keys = CATALOG.map(entryKey).filter(Boolean);
    expect(new Set(keys).size).toBe(keys.length);
    for (const e of CATALOG) {
      expect(Object.keys(CATALOG_CATEGORIES), e.id).toContain(e.category);
      for (const u of [e.website, e.manual?.url]) if (u) expect(u, e.id).toMatch(/^https:\/\//);
    }
  });

  it('counts after the catalog audit of 2026-11-27: 287 entries (263 WinGet, 12 Store, 4 portable, 8 manual), every automated entry rechecked that day', () => {
    const by = (m: string) => CATALOG.filter((e) => methodOf(e) === m).length;
    expect([CATALOG.length, by('winget'), by('msstore'), by('portable'), by('manual'), by('vendor')]).toEqual([287, 263, 12, 4, 8, 0]);
    expect(CATALOG.filter((e) => methodOf(e) === 'manual').map((e) => e.id).sort()).toEqual(['battlenet', 'dotnet-framework-35', 'filezilla', 'freefilesync', 'launchbox', 'rustdesk', 'spybot', 'vmware-workstation']);
    expect(CATALOG.filter((e) => methodOf(e) !== 'manual' && e.validation.checkedAt !== '2026-11-27').map((e) => e.id)).toEqual([]);
  });

  it('every WinGet and Store identifier is one that a recorded verification found (never invented)', () => {
    // Earlier read-only checks (2026-10-21 winget show, 2026-10-25 repository, 2026-11-26 expansion) and the
    // 2026-11-27 audit: a WinGet id needs its manifest at the exact path; a Store id a lookup that resolved.
    const found = new Set(verification.filter((v) => v.ok).map((v) => `${v.source}:${v.id}`.toLowerCase()));
    const repo = new Set(repository.results.filter((r) => r.found).map((r) => `winget:${r.id}`.toLowerCase()));
    const exp = new Set(expansion.results.filter((r) => r.found && r.allHashed).map((r) => `winget:${r.canonicalId}`.toLowerCase()));
    const audit = JSON.parse(readFileSync(new URL('../../docs/unified-app-catalog/catalog-audit.json', import.meta.url), 'utf8')) as {
      entries: { id: string; status: string; source: string; packageIdentifier: string | null; manifest?: { path: string }; store?: { id: string; resolves: boolean } }[];
    };
    const rec = new Map(audit.entries.map((r) => [r.id, r]));
    for (const e of CATALOG.filter((x) => x.packageIdentifier)) {
      const key = `${e.source}:${e.packageIdentifier}`.toLowerCase();
      const r = rec.get(e.id);
      expect(r?.status, `${e.id}: audited`).toBe('verified');
      const byAudit =
        e.source === 'winget'
          ? !!r?.manifest && r.packageIdentifier === e.packageIdentifier && r.manifest.path.toLowerCase().startsWith(`manifests/${e.packageIdentifier![0]!.toLowerCase()}/${e.packageIdentifier!.toLowerCase().split('.').join('/')}/`)
          : !!r?.store && r.store.resolves && r.store.id === e.packageIdentifier;
      expect(byAudit || found.has(key) || repo.has(key) || exp.has(key), `${e.id} ${e.packageIdentifier}`).toBe(true);
    }
  });

  it('identifiers the verification did not find are not in the catalog as packages', () => {
    const missing = verification.filter((v) => !v.ok).map((v) => v.id.toLowerCase());
    expect(missing).toEqual(expect.arrayContaining(['rustdesk.rustdesk', 'timkosse.filezilla.client', 'freefilesync.freefilesync']));
    for (const e of CATALOG) if (e.packageIdentifier) expect(missing, e.id).not.toContain(e.packageIdentifier.toLowerCase());
  });

  it('Store entries use the official publisher (Apple, OpenAI, WhatsApp, the MusicBee author)', () => {
    const pub = (pkg: string) => verification.find((v) => v.id === pkg)!.publisher;
    expect(pub(catalogEntryById('apple-devices')!.packageIdentifier!)).toBe('Apple Inc.');
    expect(pub(catalogEntryById('apple-music')!.packageIdentifier!)).toBe('Apple Inc.');
    expect(pub(catalogEntryById('icloud')!.packageIdentifier!)).toBe('Apple Inc.');
    expect(pub(catalogEntryById('chatgpt')!.packageIdentifier!)).toBe('OpenAI');
    expect(pub(catalogEntryById('whatsapp')!.packageIdentifier!)).toBe('WhatsApp Inc.');
    expect(pub(catalogEntryById('musicbee')!.packageIdentifier!)).toBe('Steven Mayall');
    expect(catalogEntryById('mpv-net')!.packageIdentifier).toBe('mpv.net');
    expect(pub('mpv.net')).toMatch(/stax76/);
  });

  it('manual entries carry a reason, instructions and an official https download, and are never WinGet packages', () => {
    const manual = CATALOG.filter((e) => methodOf(e) === 'manual');
    // Battle.net became manual in the 2026-11-27 audit (its setup has no silent mode).
    expect(manual.map((e) => e.id).sort()).toEqual(['battlenet', 'dotnet-framework-35', 'filezilla', 'freefilesync', 'launchbox', 'rustdesk', 'spybot', 'vmware-workstation']);
    for (const e of manual) {
      expect(e).toMatchObject({ packageIdentifier: null, source: 'none', interaction: 'required', validation: { status: 'manual' } });
      expect(e.manual!.url, e.id).toMatch(/^https:\/\//);
      expect(catalogRef(e)).toMatchObject({ source: 'catalog', packageIdentifier: e.id });
    }
  });

  it('portable entries are WinGet portable packages with safe shortcut patterns, machine-wide', () => {
    const portable = CATALOG.filter((e) => methodOf(e) === 'portable');
    expect(portable.map((e) => e.id).sort()).toEqual(['batteryinfoview', 'rufus', 'syncthing', 'ventoy']);
    for (const e of portable) {
      expect(e.source).toBe('winget');
      expect(PORTABLE_EXE.test(e.portable!.executable)).toBe(true);
      expect(SHORTCUT_NAME.test(e.portable!.shortcut)).toBe(true);
      expect(catalogRef(e)!.scope).toBe('machine');
    }
    for (const bad of ['..\\cmd.exe', 'C:\\x.exe', 'a/b.exe', 'x.exe" & calc', 'x.bat', '']) expect(PORTABLE_EXE.test(bad), bad).toBe(false);
    for (const bad of ['..\\Startup\\x', 'a/b', '', 'x;y']) expect(SHORTCUT_NAME.test(bad), bad).toBe(false);
  });

  it('dependencies resolve to catalog entries', () => {
    for (const e of CATALOG) for (const r of e.requires) expect(CATALOG.some((x) => entryKey(x) === r), `${e.id} → ${r}`).toBe(true);
    expect(catalogEntryById('docker-desktop')!.requires).toEqual(['winget:microsoft.wsl']);
  });

  it('owner exclusions are recorded and none of them is a catalog entry', () => {
    const names = CATALOG_EXCLUDED.map((x) => x.name);
    for (const n of ['Brave', 'Vivaldi', 'Pidgin', 'Dropbox', 'SugarSync', 'Foxit Reader', 'PDF24 Creator', 'CutePDF', 'Ghostscript', 'IrfanView', 'WinDirStat', 'Apple TV']) {
      expect(names, n).toContain(n);
      expect(CATALOG.some((e) => e.displayName.toLowerCase().includes(n.toLowerCase())), n).toBe(false);
    }
    // 2026-11-26 (owner decision): these five exclusions were lifted and are verified catalog entries now.
    for (const [n, cid] of [['SumatraPDF', 'sumatrapdf'], ['Paint.NET', 'paint-net'], ['Krita', 'krita'], ['Greenshot', 'greenshot'], ['ShareX', 'sharex']] as const) {
      expect(names, n).not.toContain(n);
      // Added 2026-11-26, rechecked by the 2026-11-27 audit.
      expect(catalogEntryById(cid), n).toMatchObject({ displayName: n, source: 'winget', validation: { status: 'verified', checkedAt: '2026-11-27' } });
    }
    // Phase 10: the owner's inventory (2026-10-25) lists Opera and LibreOffice, superseding the earlier exclusions.
    for (const n of ['Opera', 'LibreOffice']) {
      expect(names, n).not.toContain(n);
      expect(CATALOG.some((e) => e.displayName === n && e.validation.status === 'verified' && e.validation.checkedAt === '2026-11-27'), n).toBe(true);
    }
    expect(catalogJson.catalogVersion).toBe(2);
  });

  it('Claude Code and Claude Desktop are separate entries; Claude Code uses the WinGet ID Anthropic documents', () => {
    expect(catalogEntryById('claude-code')!.packageIdentifier).toBe('Anthropic.ClaudeCode');
    expect(catalogEntryById('claude-desktop')!.packageIdentifier).toBe('Anthropic.Claude');
  });
});

describe('built-in profiles, revision 1 (frozen for older deployments)', () => {
  it('are templates: validated, read-only, and only reference packages that exist', () => {
    expect(BUILTIN_PROFILES.map((p) => p.id)).toEqual(['core', 'everyday', 'gaming', 'developer', 'network-engineer', 'music', 'creator', 'workstation', 'apple-devices', 'android-devices', 'laptop', 'touch']);
    expect(BUILTIN_PROFILES.every((p) => p.builtin)).toBe(true);
    // Revision 1 is frozen: an app removed from the catalog since stays named, with its removal record.
    for (const cid of BUILTIN_REFERENCED) {
      const e = catalogEntryById(cid);
      if (e) expect(entryKey(e), cid).toBeTruthy();
      else expect(removalForCatalogId(cid)?.removed?.formerId, cid).toBe(cid);
    }
    expect(UNIVERSAL_PROFILES).toEqual(['core']);
    expect(isSelectableProfile('apple-devices')).toBe(false);
    expect(isSelectableProfile('gaming')).toBe(true);
  });

  it('Core Essentials is in every new deployment, and each of its apps can be unticked and stays unticked', () => {
    const s = fresh();
    expect(selected(s)).toEqual(['chrome', 'vlc', '7zip', 'teracopy', 'bitwarden', 'vcredist-x64', 'vcredist-x86']);
    // Remote support and power-user tools are recommended, never universal.
    expect(resolveSelection(s).recommended.map((p) => p.catalog!.id)).toEqual(['rustdesk', 'notepadpp', 'everything', 'powertoys']);
    expect(new Set(selected(s))).toEqual(new Set(CORE));
    for (const app of ['chrome', 'bitwarden']) removePackage(s, id(app));
    toggleProfile(s, 'gaming', true);
    toggleProfile(s, 'network-engineer', true);
    toggleProfile(s, 'gaming', false);
    s.devices.phone = 'iphone';
    expect(selected(s)).not.toContain('chrome');
    expect(selected(s)).not.toContain('bitwarden');
  });

  it('Gaming selects Steam and Epic; the other launchers and Discord are recommended, unticked', () => {
    const s = fresh();
    toggleProfile(s, 'gaming', true);
    const r = resolveSelection(s);
    expect(selected(s)).toEqual(expect.arrayContaining(['steam', 'epic']));
    expect(r.recommended.map((p) => p.catalog!.id)).toEqual(expect.arrayContaining(['battlenet', 'ea-app', 'ubisoft-connect', 'gog-galaxy', 'playnite', 'discord']));
    expect(selected(s)).not.toContain('battlenet');
  });

  it('Gaming with Epic unticked: the effective plan has Steam and not Epic; the template is unchanged', () => {
    const s = fresh();
    toggleProfile(s, 'gaming', true);
    removePackage(s, id('epic'));
    const cfg = applicationsConfig(profile((p) => (p.applications.selection = s)));
    expect(cfg.packages.map((x) => x.packageIdentifier)).toContain('Valve.Steam');
    expect(cfg.packages.map((x) => x.packageIdentifier)).not.toContain('EpicGames.EpicGamesLauncher');
    expect(cfg.deselected.map((x) => x.packageIdentifier)).toEqual(['EpicGames.EpicGamesLauncher']);
    expect(builtinProfile('gaming')!.packages.map((x) => x.packageIdentifier)).toEqual(['Valve.Steam', 'EpicGames.EpicGamesLauncher']);
  });

  it('General Developer stays lean: Git, VS Code, Python and Node.js LTS by default', () => {
    expect(builtinProfile('developer')!.packages.map((x) => catalogEntryById(CATALOG.find((e) => entryKey(e) === packageKey(x))!.id)!.id)).toEqual(['git', 'vscode', 'python-314', 'nodejs-lts']);
    expect(builtinProfile('developer')!.optional!.length).toBeGreaterThanOrEqual(15);
  });

  it('Network Engineer / Technician includes the developer baseline and every specified tool', () => {
    const s = fresh();
    toggleProfile(s, 'network-engineer', true);
    const want = [
      ...CORE,
      'git', 'vscode', 'python-314', 'nodejs-lts',
      'cursor', 'claude-code', 'claude-desktop', 'chatgpt', 'github-desktop', 'sublime-text', 'docker-desktop',
      'wireshark', 'winscp', 'putty', 'filezilla', 'tailscale', 'wireguard',
      'winmerge', 'wiztree', 'hwinfo', 'crystaldiskinfo', 'crystaldiskmark', 'bulk-rename-utility',
      'rufus', 'ventoy', 'qbittorrent', 'sabnzbd', 'syncthing',
      'wsl', // required by Docker Desktop
    ];
    expect(new Set(selected(s))).toEqual(new Set(want));
    const rec = resolveSelection(s).recommended.map((p) => p.catalog!.id);
    expect(rec).toEqual(expect.arrayContaining(['quicklook', 'freefilesync']));
    expect(CATALOG.some((e) => /windirstat/i.test(e.id))).toBe(false);
  });

  it('Music Enthusiast selects one library manager, not every player', () => {
    const s = fresh();
    toggleProfile(s, 'music', true);
    const sel = selected(s).filter((x) => !CORE.includes(x));
    expect(sel).toEqual(['musicbee']);
    expect(resolveSelection(s).recommended.map((p) => p.catalog!.id)).toEqual(expect.arrayContaining(['tauon', 'dopamine', 'museeks', 'mpv-net', 'audacity', 'handbrake', 'spotify', 'itunes', 'apple-music', 'obs-studio']));
  });

  it('combined profiles never list an app twice', () => {
    const s = fresh();
    for (const p of ['everyday', 'gaming', 'developer', 'network-engineer', 'music', 'laptop', 'touch']) toggleProfile(s, p, true);
    s.devices = devices({ phone: 'android', ipad: true, androidTablet: true, extraIphone: true });
    const keys = resolveSelection(s).packages.map((p) => p.key);
    expect(new Set(keys).size).toBe(keys.length);
    expect(resolveSelection(s).duplicates.map((d) => d.key)).toContain(id('git'));
  });
});

describe('devices', () => {
  it.each([
    [devices({ phone: 'iphone' }), ['apple-devices']],
    [devices({ ipad: true }), ['apple-devices']],
    [devices({ extraIphone: true }), ['apple-devices']],
    [devices({ phone: 'android', ipad: true }), ['apple-devices', 'android-devices']],
    [devices({ phone: 'android' }), ['android-devices']],
    [devices({ androidTablet: true }), ['android-devices']],
    [devices({}), []],
  ] as const)('%o activates %o', (d, want) => {
    expect(deviceProfiles(d)).toEqual(want);
  });

  it('iPhone or iPad recommends and ticks Apple Devices; Apple Music, iTunes and iCloud stay optional', () => {
    for (const d of [devices({ phone: 'iphone' }), devices({ phone: 'android', ipad: true })]) {
      const s = fresh();
      s.devices = d;
      expect(selected(s)).toContain('apple-devices');
      expect(selected(s)).not.toEqual(expect.arrayContaining(['apple-music']));
      expect(resolveSelection(s).recommended.map((p) => p.catalog!.id)).toEqual(expect.arrayContaining(['apple-music', 'itunes', 'icloud']));
    }
  });

  it('Apple Devices can be unticked even with an iPhone', () => {
    const s = fresh();
    s.devices = devices({ phone: 'iphone' });
    removePackage(s, id('apple-devices'));
    expect(selected(s)).not.toContain('apple-devices');
  });

  it('Android adds nothing by default (USB file transfer needs no software); manufacturer tools are optional', () => {
    const s = fresh();
    s.devices = devices({ phone: 'android', androidTablet: true });
    expect(selected(s)).toEqual(selected(fresh()));
    // Only the Android profile's own recommendations are added (Core Essentials keeps its own).
    const coreOptional = ['rustdesk', 'notepadpp', 'everything', 'powertoys'];
    expect(resolveSelection(s).recommended.map((p) => p.catalog!.id).filter((x) => !coreOptional.includes(x))).toEqual(['google-quick-share', 'samsung-smart-switch']);
  });

  it('iCloud carries a large-transfer warning and is installed only', () => {
    const s = fresh();
    addPackage(s, ref('icloud'));
    expect(resolveSelection(s).notices.map((n) => n.message).join(' ')).toMatch(/iCloud for Windows: Turning on iCloud Photos or iCloud Drive later can download and upload very large amounts of data/);
    expect(catalogEntryById('icloud')!.description).toMatch(/no Apple Account is signed in/);
  });
});

describe('overrides and profile switching', () => {
  it('ticking a profile default that was unticked only restores it; ticking a recommendation adds it', () => {
    const s = fresh();
    toggleProfile(s, 'gaming', true);
    removePackage(s, id('epic'));
    expect(s.removed).toEqual([id('epic')]);
    addPackage(s, ref('epic'));
    expect(s.removed).toEqual([]);
    expect(s.added).toEqual([]);
    addPackage(s, ref('discord'));
    expect(s.added.map((r) => r.packageIdentifier)).toEqual(['Discord.Discord']);
  });

  it('removing and re-adding a profile keeps deliberate changes; its ticked recommendations leave with it; restore and reset are explicit', () => {
    const s = fresh();
    toggleProfile(s, 'gaming', true);
    removePackage(s, id('epic'));
    addPackage(s, ref('discord'));
    addPackage(s, ref('gimp'));
    expect(s.addedWith).toEqual({ [id('discord')]: ['gaming'] });
    toggleProfile(s, 'gaming', false);
    // Discord was a Gaming recommendation: it goes with Gaming. GIMP was the user's own addition.
    expect(selected(s)).not.toContain('discord');
    expect(selected(s)).toContain('gimp');
    expect(s.added.map((r) => packageKey(r))).toEqual([id('gimp')]);
    expect(s.addedWith).toBeUndefined();
    toggleProfile(s, 'gaming', true);
    expect(selected(s)).not.toContain('epic');
    expect(selected(s)).not.toContain('discord');
    expect(resolveSelection(s).recommended.some((p) => p.key === id('discord'))).toBe(true);
    addPackage(s, ref('discord'));
    expect(selected(s)).toContain('discord');
    restoreProfileDefaults(s, 'gaming');
    expect(selected(s)).toContain('epic');
    expect(selected(s)).not.toContain('discord');
    removePackage(s, id('chrome'));
    resetOverrides(s);
    expect(selected(s)).toContain('chrome');
    toggleProfile(s, 'music', true);
    s.devices.ipad = true;
    resetSelection(s);
    expect(s).toMatchObject({ selectedProfiles: ['core'], devices: devices({}), added: [], removed: [] });
  });

  it('a removal recorded for a profile that is no longer ticked has no effect and is not shown as removed', () => {
    const s = fresh();
    toggleProfile(s, 'gaming', true);
    removePackage(s, id('epic'));
    toggleProfile(s, 'gaming', false);
    expect(resolveSelection(s).removed).toEqual([]);
  });

  it('deselecting a dependency keeps it out and warns; the dependent app is still planned', () => {
    const s = fresh();
    addPackage(s, ref('docker-desktop'));
    expect(selected(s)).toContain('wsl');
    removePackage(s, id('wsl'));
    const r = resolveSelection(s);
    expect(selected(s)).not.toContain('wsl');
    expect(selected(s)).toContain('docker-desktop');
    expect(r.notices.map((n) => n.message).join(' ')).toMatch(/Docker Desktop needs Windows Subsystem for Linux, which is deselected/);
  });

  it('HandBrake brings the .NET Desktop Runtime 8 and installs after it', () => {
    const s = fresh();
    addPackage(s, ref('handbrake'));
    const ids = installable(resolveSelection(s)).map((p) => p.catalog?.id);
    expect(ids.indexOf('dotnet-desktop-8')).toBeLessThan(ids.indexOf('handbrake'));
  });
});

describe('saved profiles', () => {
  it('"Aunt\'s Computer": saved with parents, exclusions and devices; built-in templates unchanged; update folds in later changes', () => {
    const before = JSON.stringify(BUILTIN_PROFILES);
    const s = fresh();
    toggleProfile(s, 'everyday', true);
    s.devices.phone = 'iphone';
    removePackage(s, id('bitwarden'));
    addPackage(s, ref('zoom'));
    const want = new Set(selected(s));
    const p = saveAsNewProfile(s, "Aunt's Computer");
    expect(new Set(selected(s))).toEqual(want);
    addPackage(s, ref('firefox'));
    expect(updateProfileFromSelection(s, p.id)).toBe(true);
    expect(p.packages.map((x) => x.packageIdentifier)).toEqual(['Zoom.Zoom', 'Mozilla.Firefox']);
    expect(s.added).toEqual([]);
    expect(JSON.stringify(BUILTIN_PROFILES)).toBe(before);
    expect(updateProfileFromSelection(s, 'gaming')).toBe(false);
  });

  it('duplicating a built-in profile gives an editable copy with its defaults and recommendations', () => {
    const s = fresh();
    const copy = duplicateProfile(s, 'gaming')!;
    expect(copy).toMatchObject({ id: 'gaming-copy', builtin: false, category: 'custom' });
    expect(copy.optional!.length).toBe(builtinProfile('gaming')!.optional!.length);
    copy.packages.length = 0;
    expect(builtinProfile('gaming')!.packages).toHaveLength(2);
  });

  it('profile names are data: quotes, markup and script text are kept literally, never executed', () => {
    const s = fresh();
    const p = saveAsNewProfile(s, '<img src=x onerror=alert(1)> "$(calc)"');
    const back = importAppProfiles(exportAppProfiles([p]), []).profiles[0]!;
    expect(back.name).toBe('<img src=x onerror=alert(1)> "$(calc)"');
    // The name is recorded as escaped data (deployment manifest), never as markup or in a command.
    const r = generateOk(profile((x) => (x.applications.selection = s)));
    expect(r.xml).not.toContain('<img');
    expect(r.xml).toContain('&lt;img src=x onerror=alert(1)&gt;');
    for (const line of [...commandLines(r.root).firstLogon, ...commandLines(r.root).specialize]) expect(line).not.toMatch(/onerror|calc/);
  });
});

describe('browser persistence (library)', () => {
  class MemoryStorage implements Storage {
    data = new Map<string, string>();
    getItem(k: string) {
      return this.data.get(k) ?? null;
    }
    setItem(k: string, v: string) {
      this.data.set(k, v);
    }
  }

  it('custom profiles survive a reload, a reset and an import; deleting is explicit', () => {
    const storage = new MemoryStorage();
    const lib = new ProfileLibrary(storage);
    const s = fresh();
    saveAsNewProfile(s, 'Gaming Desktop');
    lib.saveFrom(s);
    expect(storage.getItem(LIBRARY_KEY)).toContain('"Gaming Desktop"');
    const reloaded = new ProfileLibrary(storage);
    const after = fresh();
    expect(reloaded.restoreInto(after)).toBe(1);
    expect(after.profiles[0]!.name).toBe('Gaming Desktop');
    expect(reloaded.restoreInto(after)).toBe(0);
    reloaded.remove('gaming-desktop');
    expect(new ProfileLibrary(storage).list()).toEqual([]);
  });

  it('stores only application profiles: never names, passwords or other configuration', () => {
    const storage = new MemoryStorage();
    const p = profile((x) => {
      x.accounts.password = 'S3cret!';
      x.wifi.password = 'wifi-secret';
    });
    saveAsNewProfile(p.applications.selection, 'Office');
    new ProfileLibrary(storage).saveFrom(p.applications.selection);
    const text = storage.getItem(LIBRARY_KEY)!;
    expect(text).not.toMatch(/S3cret|wifi-secret|Alex|password/);
  });

  it('corrupt or incompatible data gives a readable warning and no profiles; built-in ids are never shadowed', () => {
    expect(loadLibrary('{not json').warnings[0]).toMatch(/could not be read/);
    expect(loadLibrary('{"format":"windows-deployment-builder/app-profiles","formatVersion":99,"profiles":[]}').warnings[0]).toMatch(/could not be read/);
    const clash = JSON.stringify({ format: 'windows-deployment-builder/app-profiles', formatVersion: 2, profiles: [{ id: 'gaming', name: 'Mine', category: 'custom', description: '', builtin: true, inherits: ['ghost', 'core'], packages: [] }] });
    const r = loadLibrary(clash);
    expect(r.profiles[0]).toMatchObject({ id: 'gaming-2', builtin: false, inherits: ['core'] });
    expect(r.warnings[0]).toMatch(/renamed/);
  });

  it('works without storage (private mode): nothing is thrown', () => {
    const throwing: Storage = { getItem: () => { throw new Error('denied'); }, setItem: () => { throw new Error('denied'); } };
    const lib = new ProfileLibrary(throwing);
    expect(lib.available).toBe(false);
    const s = fresh();
    saveAsNewProfile(s, 'X');
    expect(() => lib.saveFrom(s)).not.toThrow();
  });
});

describe('antivirus and security selections', () => {
  const avs = ['avast', 'avg', 'avira'] as const;
  it.each([
    ['avast', 'avg'],
    ['avast', 'avira'],
    ['avg', 'avira'],
  ] as const)('%s + %s is a blocking conflict', (a, b) => {
    const p = profile((x) => {
      addPackage(x.applications.selection, ref(a));
      addPackage(x.applications.selection, ref(b));
    });
    const errs = errorsOf(p);
    expect(errs).toEqual([expect.objectContaining({ path: 'applications.selection', message: expect.stringMatching(/real-time antivirus products.*keep only one/) })]);
  });

  it('one antivirus alone is allowed, with a note that Defender switches to passive mode (nothing is changed)', () => {
    for (const a of avs) {
      const r = generate(profile((x) => addPackage(x.applications.selection, ref(a))));
      expect(r.ok, a).toBe(true);
      expect(r.issues.some((i) => /passive mode; this deployment does not change Defender/.test(i.message)), a).toBe(true);
    }
  });

  it('Malwarebytes is allowed next to an antivirus, with real-time overlap warnings', () => {
    const r = generate(profile((x) => {
      addPackage(x.applications.selection, ref('malwarebytes'));
      addPackage(x.applications.selection, ref('avira'));
    }));
    expect(r.ok).toBe(true);
    const text = r.issues.map((i) => i.message).join(' ');
    expect(text).toMatch(/cannot guarantee on-demand-only operation/);
    expect(text).toMatch(/Malwarebytes and Avira Security are both selected/);
  });

  it('RustDesk, VPNs and sync tools are installed only: nothing in the plan configures access, tunnels or folders', () => {
    const s = fresh();
    for (const a of ['tailscale', 'wireguard', 'syncthing', 'qbittorrent', 'sabnzbd']) addPackage(s, ref(a));
    const p = profile((x) => (x.applications.selection = s));
    const cfg = applicationsConfig(p);
    // Only identity, order and metadata reach the engine: no credentials, keys, servers, ports or arguments.
    const keys = new Set(cfg.packages.flatMap(Object.keys));
    expect([...keys].sort()).toEqual(['after', 'displayName', 'interaction', 'key', 'method', 'packageIdentifier', 'portable', 'scope', 'source', 'verify', 'version']);
    expect(JSON.stringify(cfg.packages)).not.toMatch(/authkey|--unattended|--password|netsh|firewall|\.conf"|https?:/i);
    expect(catalogEntryById('rustdesk')!.manual!.instructions).toMatch(/Leave unattended access off/);
    expect(catalogEntryById('tailscale')!.description).toMatch(/does not sign in, join a tailnet or connect/);
    expect(catalogEntryById('ventoy')!.description).toMatch(/Never run by the deployment/);
    expect(engineSource).not.toMatch(/Format-Volume|Clear-Disk|diskpart|Initialize-Disk|bcdedit|New-Partition/i);
  });

  it('imported profiles cannot inject commands, URLs or unknown members', () => {
    const hostile = JSON.stringify({
      format: 'windows-deployment-builder/app-profiles',
      formatVersion: 2,
      profiles: [
        {
          id: 'x',
          name: 'X',
          category: 'custom',
          description: '',
          builtin: false,
          inherits: [],
          packages: [
            { packageIdentifier: 'Git.Git; Remove-Item C:\\', source: 'winget', displayName: 'a', version: '', scope: '' },
            { packageIdentifier: 'https://evil.example/x.exe', source: 'winget', displayName: 'b', version: '', scope: '' },
            { packageIdentifier: '../../evil', source: 'catalog', displayName: 'c', version: '', scope: '' },
            { packageIdentifier: 'Git.Git', source: 'winget', displayName: 'ok', version: '1.0 && calc', scope: '' },
          ],
        },
      ],
    });
    const r = importAppProfiles(hostile, []);
    expect(r.profiles[0]!.packages).toEqual([]);
    expect(r.warnings).toHaveLength(4);
    expect(importAppProfiles(JSON.stringify({ format: 'windows-deployment-builder/app-profiles', formatVersion: 2, profiles: [{ id: 'x', name: 'X', category: 'custom', description: '', builtin: false, inherits: [], packages: [], downloadUrl: 'https://evil.example' }] }), []).ok).toBe(false);
    expect(importAppProfiles('{"__proto__":{"polluted":1},"format":"windows-deployment-builder/app-profiles","formatVersion":2,"profiles":[]}', []).ok).toBe(false);
    expect(({} as Record<string, unknown>).polluted).toBeUndefined();
  });

  it('a custom WinGet ID is data: it reaches the engine only as a validated token', () => {
    const p = profile((x) => addPackage(x.applications.selection, { packageIdentifier: 'Contoso.Tool', source: 'winget', displayName: '"); calc; ("', version: '', scope: '' }));
    const r = generateOk(p);
    for (const line of [...commandLines(r.root).firstLogon, ...commandLines(r.root).specialize]) expect(line).not.toContain('calc');
    expect(applicationsConfig(p).packages.find((x) => x.packageIdentifier === 'Contoso.Tool')!.displayName).toBe('"); calc; ("');
  });

  it('adding an excluded app by ID is allowed and explained', () => {
    const s = fresh();
    addPackage(s, { packageIdentifier: 'Brave.Brave', source: 'winget', displayName: 'Brave', version: '', scope: '' });
    expect(resolveSelection(s).notices.map((n) => n.message).join(' ')).toMatch(/Brave is not in the curated catalog/);
  });
});

describe('engine plan and USB package', () => {
  const p = profile((x) => {
    const s = x.applications.selection;
    toggleProfile(s, 'gaming', true);
    removePackage(s, id('epic'));
    addPackage(s, ref('acrobat-reader'));
    addPackage(s, ref('rufus'));
    // A manual catalog entry (Phase 10: no longer a Core Essentials default).
    addPackage(s, ref('rustdesk'));
    s.devices.ipad = true;
  });

  it('the config carries exactly the UI selection, with methods, portable shortcuts, manual and deselected entries', () => {
    const c = applicationsConfig(p);
    const r = resolveSelection(p.applications.selection);
    expect(c.packages.map((x) => x.key)).toEqual(installable(r).map((x) => x.key));
    expect(c.packages.find((x) => x.packageIdentifier === 'Rufus.Rufus')).toMatchObject({ method: 'portable', scope: 'machine', portable: { executable: 'rufus*.exe', shortcut: 'Rufus' } });
    expect(c.packages.find((x) => x.packageIdentifier === '9NP83LWLPZ9K')).toMatchObject({ method: 'msstore', source: 'msstore' });
    expect(c.manual.map((x) => x.key)).toEqual(['catalog:battlenet', 'catalog:rustdesk']);
    expect(c.deselected.map((x) => x.key)).toEqual([id('epic')]);
  });

  it('every engine-config field is read by ApplicationEngine.ps1 (nothing generated that the engine ignores)', () => {
    const c = applicationsConfig(p);
    const keys = new Set([...Object.keys(c), ...c.packages.flatMap(Object.keys), ...c.manual.flatMap(Object.keys), ...c.deselected.flatMap(Object.keys), 'executable', 'shortcut']);
    // schemaVersion/engineVersion are informational; the engine reports its own version.
    for (const k of [...keys].filter((x) => !['schemaVersion', 'engineVersion'].includes(x))) expect(engineSource, k).toMatch(new RegExp(`[.']${k}\\b`));
  });

  it('the native WinGet list holds only WinGet/Store packages, portable ones machine-wide', () => {
    const doc = exportWinGetDocument(installable(resolveSelection(p.applications.selection)).map((x) => x.ref), null);
    const all = doc.Sources.flatMap((s) => s.Packages);
    expect(all.find((x) => x.PackageIdentifier === 'Rufus.Rufus')!.Scope).toBe('machine');
    expect(all.some((x) => x.PackageIdentifier === 'rustdesk')).toBe(false);
  });

  it('the ZIP and manifest describe the same plan, with provenance, devices and verified hashes', () => {
    const r = generateOk(p);
    const pkg = buildDeploymentPackage(p, r);
    const apps = pkg.manifest.applications;
    expect(apps.packages.map((x) => x.packageIdentifier)).toEqual(resolveSelection(p.applications.selection).packages.map((x) => x.ref.packageIdentifier));
    expect(apps.packages.find((x) => x.packageIdentifier === 'rustdesk')).toMatchObject({ method: 'manual', resolution: 'manual', requiresAttention: true });
    expect(apps).toMatchObject({ deviceProfiles: ['iPhone / iPad'], devices: { ipad: true } });
    const entries = readZip(pkg.zip);
    const dec = new TextDecoder();
    const cfg = JSON.parse(dec.decode(entries.find((e) => e.path.endsWith('applications-config.json'))!.data));
    expect(cfg).toEqual(applicationsConfig(p));
    const profileJson = JSON.parse(dec.decode(entries.find((e) => e.path.endsWith('profiles/applications.json'))!.data));
    expect(profileJson.formatVersion).toBe(2);
    expect(profileJson.profiles[0].packages.map((x: { packageIdentifier: string }) => x.packageIdentifier)).toContain('Rufus.Rufus');
  });

  it('a non-ASCII display name is escaped in the config (reads the same in any code page)', () => {
    const q = profile((x) => addPackage(x.applications.selection, { packageIdentifier: 'Contoso.Tool', source: 'winget', displayName: 'Zoë', version: '', scope: '' }));
    const r = generateOk(q);
    const pkg = buildDeploymentPackage(q, r);
    const raw = new TextDecoder().decode(readZip(pkg.zip).find((e) => e.path.endsWith('applications-config.json'))!.data);
    // eslint-disable-next-line no-control-regex
    expect(/^[\x00-\x7f]*$/.test(raw)).toBe(true);
    expect(raw).toContain('Zo\\u00eb');
    expect(pkg.manifest.files.every((f) => !f.embedded || f.textSha256)).toBe(true);
  });
});

describe('legacy profiles (Phase 4 / schema v3 exports)', () => {
  it('a Phase 4 owner-default export imports without Core Essentials and, with Windows Update off, gives the Milestone 1 XML', () => {
    const v3 = JSON.parse(fixture('p4-owner-default.profile.json')) as Record<string, unknown>;
    expect(v3.schemaVersion).toBe(3);
    (v3.accounts as Record<string, unknown>).personName = 'Alex';
    (v3.windowsUpdate as Record<string, unknown>).enabled = false;
    const r = importProfile(JSON.stringify(v3));
    expect(r.errors).toEqual([]);
    expect(r.profile!.applications.selection).toMatchObject({ profiles: [], selectedProfiles: [], devices: devices({}) });
    expect(r.warnings.join(' ')).toMatch(/Core Essentials .* is not selected for this older profile/);
    expect(generate(r.profile).xml).toBe(M1_XML);
  });

  it('a filled-in v3 built-in profile becomes a ticked custom profile and installs the same apps as before', () => {
    const r = importProfile(fixture('p4-filled-gaming.profile.json'));
    expect(r.errors).toEqual([]);
    const sel = r.profile!.applications.selection;
    expect(sel.profiles.map((x) => [x.id, x.name, x.builtin])).toEqual([['gaming-saved', 'Gaming (from an older profile)', false]]);
    expect(sel.selectedProfiles).toEqual(['gaming-saved']);
    // Phase 4 resolved this file to Steam (filled Gaming) + Git (added); the empty Everyday tick is dropped.
    expect(resolveSelection(sel).packages.map((x) => x.ref.packageIdentifier)).toEqual(['Valve.Steam', 'Git.Git']);
    expect(r.warnings.join(' ')).toMatch(/your filled-in "Gaming" became custom profile/);
  });

  it('the v3 Phase 3 helper profiles (imported-legacy from Milestone 1) survive two migrations', () => {
    const v1 = JSON.parse(fixture('m1-owner-default.profile.json')) as Record<string, unknown>;
    (v1.deferred as Record<string, unknown>).wingetPackages = ['Git.Git'];
    const r = importProfile(JSON.stringify(v1));
    expect(r.profile!.applications.selection.profiles.map((x) => x.id)).toEqual(['imported-legacy']);
    expect(resolveSelection(r.profile!.applications.selection).packages).toEqual([]);
  });

  it('the owner defaults still validate and the Milestone 1 XML is unchanged when both engines are off', () => {
    const r = generate(profile((x) => {
      x.windowsUpdate.enabled = false;
      noApps(x);
      // Milestone 1's owner default withheld drivers from quality updates; Phase 9 changed the default.
      x.updates.excludeDrivers = true;
    }));
    expect(r.xml).toBe(M1_XML);
  });
});
