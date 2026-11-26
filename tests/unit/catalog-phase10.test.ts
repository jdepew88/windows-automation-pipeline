import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { CATALOG, CATALOG_CATEGORIES, CATALOG_EXCLUDED, catalogEntryById, entryKey, methodOf } from '../../src/engine/applications/catalog';
import { builtinProfile as anyBuiltin, builtinProfiles } from '../../src/engine/applications/builtin';
import { removePackage, toggleProfile } from '../../src/engine/applications/profiles';
import { resolveSelection } from '../../src/engine/applications/selection';
import { profile } from './helpers';

/**
 * Phase 10A: the catalog from the owner's inventory (exact WinGet identifiers, verified against the
 * WinGet repository) and categories that are independent of profiles.
 */

const csvText = readFileSync(new URL('../../docs/application-inventory/WDB_Application_Identity_Catalog_WinGet_Only.csv', import.meta.url), 'utf8').replace(/^\uFEFF/, '');
/** Minimal RFC 4180 reader (quoted fields with commas). */
function parseCsv(text: string): { winget_package_id: string; application_name: string }[] {
  const rows: string[][] = [];
  let row: string[] = [], cell = '', quoted = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i]!;
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') { cell += '"'; i++; } else if (c === '"') quoted = false; else cell += c;
    } else if (c === '"') quoted = true;
    else if (c === ',') { row.push(cell); cell = ''; }
    else if (c === '\n') { row.push(cell.replace(/\r$/, '')); rows.push(row); row = []; cell = ''; }
    else cell += c;
  }
  if (cell || row.length) { row.push(cell); rows.push(row); }
  const [head, ...body] = rows;
  return body.filter((r) => r.length > 1).map((r) => Object.fromEntries(head!.map((h, i) => [h, r[i] ?? ''])) as { winget_package_id: string; application_name: string });
}
const CSV = parseCsv(csvText);
const repository = JSON.parse(readFileSync(new URL('../../docs/phase-10-application-manager/winget-verification-2026-10-25.json', import.meta.url), 'utf8')) as { commit: string; results: { id: string; found: boolean; canonicalId?: string }[] };

// The Phase 10 profile tests describe revision 1 of the built-in profiles (frozen for older deployments).
const BUILTIN_PROFILES = builtinProfiles(1);
const builtinProfile = (id: string) => anyBuiltin(id, 1);
const fresh = () => ({ ...profile().applications.selection, profileRevision: 1 as const });
const ids = (s: ReturnType<typeof fresh>) => resolveSelection(s).packages.map((p) => p.catalog?.id ?? p.key);

describe('the owner inventory (CSV) in the catalog', () => {
  it('reads all 130 rows, each with an exact WinGet identifier', () => {
    expect(CSV).toHaveLength(130);
    for (const r of CSV) expect(r.winget_package_id, r.application_name).toMatch(/^[A-Za-z0-9][A-Za-z0-9.+_-]*\.[A-Za-z0-9.+_-]+$/);
  });

  it('every identifier was found, with that exact spelling, in the WinGet repository', () => {
    const found = new Map(repository.results.map((r) => [r.id, r]));
    for (const r of CSV) {
      const v = found.get(r.winget_package_id);
      expect(v?.found, r.winget_package_id).toBe(true);
      expect(v?.canonicalId, r.winget_package_id).toBe(r.winget_package_id);
    }
    expect(repository.commit).toMatch(/^[0-9a-f]{40}$/);
  });

  it('every row is a catalog entry (exact identifier), a recognised alternate identifier, or an exclusion with a reason; nothing else was added', () => {
    const byId = new Map(CATALOG.filter((e) => e.packageIdentifier).map((e) => [e.packageIdentifier!, e]));
    const alternates = new Map(CATALOG.flatMap((e) => (e.alternateIds ?? []).map((a) => [a, e] as const)));
    const excluded = new Map(CATALOG_EXCLUDED.filter((x) => x.packageIdentifier).map((x) => [x.packageIdentifier!, x]));
    for (const r of CSV) {
      const id = r.winget_package_id;
      const where = byId.has(id) ? 'catalog' : alternates.has(id) ? 'alternate' : excluded.has(id) ? 'excluded' : 'missing';
      expect(where, id).not.toBe('missing');
    }
    expect(alternates.get('Zoom.Zoom.EXE')?.id).toBe('zoom');
    // Phase 10 WinGet entries all come from the CSV (no unmatched application was added).
    const csvIds = new Set(CSV.map((r) => r.winget_package_id));
    for (const e of CATALOG.filter((x) => x.validation.checkedAt === '2026-10-25' && x.packageIdentifier)) expect(csvIds.has(e.packageIdentifier!), e.id).toBe(true);
  });

  it('runtimes, system components, package managers and Windows upgrades from the inventory are excluded with a reason, not offered', () => {
    const excluded = CATALOG_EXCLUDED.map((x) => x.packageIdentifier);
    for (const id of ['Microsoft.WindowsAppRuntime.1.8', 'Microsoft.DirectX', 'Python.Launcher', 'Microsoft.WindowsInstallationAssistant', 'Chocolatey.ChocolateyGUI', 'Futuremark.FuturemarkSystemInfo']) expect(excluded, id).toContain(id);
  });

  it('applications the owner named but that are not in the inventory are not invented (PS5Upload, Samsung Flow, Samsung Magician, Reolink)', () => {
    for (const n of ['ps5upload', 'samsung flow', 'samsung magician', 'reolink']) expect(CATALOG.some((e) => e.displayName.toLowerCase().includes(n)), n).toBe(false);
  });

  it('VMware Workstation Pro is a manual entry: no WinGet package, the Broadcom portal, nothing disabled', () => {
    const v = catalogEntryById('vmware-workstation')!;
    expect(methodOf(v)).toBe('manual');
    expect(v.packageIdentifier).toBeNull();
    expect(v.category).toBe('virtualization');
    expect(v.manual!.reason).toMatch(/No VMware Workstation Pro package in the WinGet community repository/);
    expect(v.manual!.instructions).toMatch(/support\.broadcom\.com/);
    expect(v.manual!.instructions).toMatch(/nothing is disabled or changed automatically/);
  });
});

describe('categories are independent of profiles', () => {
  it('no category is named after a profile, and descriptions do not claim profile membership', () => {
    const profileNames = [...builtinProfiles(1), ...builtinProfiles(2)].map((p) => p.name.toLowerCase());
    for (const [id, label] of Object.entries(CATALOG_CATEGORIES)) {
      // Category and profile ids live in separate namespaces ("music" is both); their labels never coincide.
      expect(profileNames, id).not.toContain(label.toLowerCase());
    }
    expect(Object.keys(CATALOG_CATEGORIES)).not.toContain('essentials');
    for (const e of CATALOG) expect(e.description, e.id).not.toMatch(/Universal default|Core Essentials/);
  });

  it('places applications by what they do (the examples of the specification)', () => {
    const cat = (id: string) => catalogEntryById(id)!.category;
    expect([cat('chrome'), cat('vlc'), cat('spotify'), cat('calibre'), cat('steam'), cat('vmware-workstation'), cat('wireshark'), cat('qbittorrent'), cat('parsec'), cat('corsair-icue')]).toEqual([
      'browsers', 'video', 'music', 'books', 'gaming', 'virtualization', 'networking', 'downloads', 'remote', 'peripherals',
    ]);
  });

  it('an application selected by several profiles is listed once in the catalog and once in the plan', () => {
    const s = fresh();
    for (const p of ['gaming', 'music', 'creator']) toggleProfile(s, p, true);
    const plan = ids(s);
    expect(plan.filter((x) => x === 'obs-studio').length).toBeLessThanOrEqual(1);
    expect(new Set(plan).size).toBe(plan.length);
    expect(resolveSelection(s).packages.find((p) => p.catalog?.id === 'obs-studio')!.origins.sort()).toEqual(['creator']);
    // Default in Content Creator, recommended (unticked) in Gaming and Music Lover: not listed twice.
    expect(resolveSelection(s).recommended.some((p) => p.catalog?.id === 'obs-studio')).toBe(false);
    expect(CATALOG.filter((e) => e.id === 'obs-studio')).toHaveLength(1);
  });
});

describe('stackable profiles', () => {
  it('Core + Gaming + Music Lover, and Core + General Developer + Network Engineer, without duplicates; origins are shown', () => {
    const a = fresh();
    for (const p of ['gaming', 'music']) toggleProfile(a, p, true);
    const ra = resolveSelection(a);
    expect(new Set(ra.packages.map((p) => p.key)).size).toBe(ra.packages.length);
    expect(ra.packages.find((p) => p.catalog?.id === 'steam')!.origins).toEqual(['gaming']);
    expect(ra.packages.find((p) => p.catalog?.id === 'chrome')!.origins).toEqual(['core']);
    const b = fresh();
    for (const p of ['developer', 'network-engineer']) toggleProfile(b, p, true);
    const rb = resolveSelection(b);
    expect(new Set(rb.packages.map((p) => p.key)).size).toBe(rb.packages.length);
    expect(rb.packages.find((p) => p.catalog?.id === 'git')!.origins.sort()).toEqual(['developer', 'network-engineer']);
  });

  it('an explicitly deselected application stays deselected when profiles are switched', () => {
    const s = fresh();
    toggleProfile(s, 'workstation', true);
    removePackage(s, entryKey(catalogEntryById('qbittorrent')!));
    toggleProfile(s, 'network-engineer', true); // also selects qBittorrent
    toggleProfile(s, 'workstation', false);
    toggleProfile(s, 'workstation', true);
    expect(ids(s)).not.toContain('qbittorrent');
  });
});

describe('built-in profiles after Phase 10 (revision 1, frozen for older deployments)', () => {
  it('Core Essentials stays small; remote support and power-user tools are optional, never universal', () => {
    const core = builtinProfile('core')!;
    expect(core.packages.map((p) => p.displayName)).toEqual(['Google Chrome', 'VLC media player', '7-Zip', 'TeraCopy', 'Bitwarden', 'Visual C++ Redistributable 2015-2026 (x64)', 'Visual C++ Redistributable 2015-2026 (x86)']);
    expect(core.optional!.map((p) => p.displayName)).toEqual(['RustDesk', 'Notepad++', 'Everything', 'PowerToys']);
    for (const p of core.packages) expect(CATALOG.find((e) => entryKey(e) === `${p.source}:${p.packageIdentifier}`.toLowerCase())!.category, p.displayName).not.toBe('remote');
  });

  it('Personal Workstation selects the owner\'s applications; peripheral software and VMware are optional; nothing is added to Core or existing profiles', () => {
    const ws = builtinProfile('workstation')!;
    expect(ws.packages.map((p) => p.displayName)).toEqual(['Private Internet Access', 'Parsec', 'Stremio', 'JDownloader 2', 'qBittorrent', 'PS Remote Play', 'OpenRGB']);
    expect(ws.optional!.map((p) => p.displayName)).toEqual(['SABnzbd', 'VMware Workstation Pro', 'Corsair iCUE 5', 'Logitech G HUB', 'NZXT CAM']);
    const personal = ['pia', 'parsec', 'stremio', 'jdownloader', 'ps-remote-play', 'openrgb', 'corsair-icue', 'logitech-ghub', 'nzxt-cam'];
    for (const p of BUILTIN_PROFILES.filter((x) => x.id !== 'workstation')) {
      for (const r of [...p.packages, ...(p.optional ?? [])]) {
        const e = CATALOG.find((x) => entryKey(x) === `${r.source}:${r.packageIdentifier}`.toLowerCase() || x.id === r.packageIdentifier);
        expect(personal, `${p.id}: ${r.displayName}`).not.toContain(e?.id);
      }
    }
  });

  it('device and peripheral software is never a default outside Personal Workstation, and names the hardware it is for', () => {
    for (const e of CATALOG.filter((x) => x.category === 'peripherals')) {
      expect(e.hardware, e.id).toBeTruthy();
      expect(e.kind, e.id).toBe('manufacturer');
    }
    const defaults = BUILTIN_PROFILES.filter((p) => p.id !== 'workstation').flatMap((p) => p.packages.map((r) => r.packageIdentifier));
    for (const e of CATALOG.filter((x) => x.kind === 'manufacturer' || x.category === 'peripherals')) expect(defaults, e.id).not.toContain(e.packageIdentifier);
  });

  it('runtimes are never offered as recommendations; only the two current Visual C++ runtimes are defaults', () => {
    const runtimeKeys = new Set(CATALOG.filter((e) => e.kind === 'runtime').map(entryKey));
    for (const p of BUILTIN_PROFILES) for (const r of p.optional ?? []) expect(runtimeKeys.has(`${r.source}:${r.packageIdentifier}`.toLowerCase()), `${p.id}: ${r.displayName}`).toBe(false);
    const runtimeDefaults = BUILTIN_PROFILES.flatMap((p) => p.packages).filter((r) => runtimeKeys.has(`${r.source}:${r.packageIdentifier}`.toLowerCase())).map((r) => r.packageIdentifier);
    expect([...new Set(runtimeDefaults)].sort()).toEqual(['Microsoft.VCRedist.2015+.x64', 'Microsoft.VCRedist.2015+.x86']);
  });

  it('renamed to the owner\'s terms; ids unchanged so saved selections keep working', () => {
    expect(builtinProfile('everyday')!.name).toBe('Everyday / Home');
    expect(builtinProfile('network-engineer')!.name).toBe('Network Engineer / Technician');
    expect(builtinProfile('music')!.name).toBe('Music Lover');
    expect(builtinProfile('creator')!.name).toBe('Content Creator');
  });
});

describe('maintenance metadata', () => {
  it('runtimes and Windows components can never be removed from the manager; security, drivers and device control need an extra confirmation', () => {
    for (const e of CATALOG.filter((x) => x.kind === 'runtime')) expect(e.removal, e.id).toBe('blocked');
    expect(catalogEntryById('edge')!.removal).toBe('blocked');
    for (const id of ['pia', 'malwarebytes', 'hidhide', 'corsair-icue', 'wsl', 'docker-desktop', 'teamviewer']) expect(catalogEntryById(id)!.removal, id).toBe('caution');
    expect(catalogEntryById('vlc')!.removal).toBe('normal');
  });

  it('packages that WinGet upgrades only when named are marked (RequireExplicitUpgrade)', () => {
    // Android Studio, GPT4All and Miniconda (2026-11-26) are RequireExplicitUpgrade in their manifests too.
    expect(CATALOG.filter((e) => e.upgrade === 'explicit').map((e) => e.id).sort()).toEqual(['android-studio', 'discord', 'gpt4all', 'miniconda', 'parsec', 'slack']);
    for (const e of CATALOG.filter((x) => methodOf(x) === 'manual')) expect(e.upgrade, e.id).toBe('manual');
  });

  it('carries publisher and Apps & Features names from the manifests for detection', () => {
    expect(catalogEntryById('git')!.publisher).toBeTruthy();
    // Only manifests that declare AppsAndFeaturesEntries carry names (22 at the 2026-10-25 check); WinGet's own matching covers the rest.
    expect(catalogEntryById('retroarch')!.detectNames).toEqual(['RetroArch']);
    expect(CATALOG.filter((e) => e.detectNames?.length).length).toBeGreaterThanOrEqual(20);
    expect(CATALOG.filter((e) => e.source === 'winget').every((e) => !!e.publisher)).toBe(true);
  });
});
