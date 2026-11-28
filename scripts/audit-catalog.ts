/**
 * Catalog audit (2026-11-27): reads the WinGet community manifests of every WinGet entry of
 * src/data/apps/catalog.json from github.com/microsoft/winget-pkgs at one pinned commit. Read-only:
 * nothing is installed and winget is not run (Microsoft Store entries were checked separately with
 * `winget show --source msstore`; their output is cached as text next to the manifests).
 *
 *   vite-node scripts/audit-catalog.ts fetch [extra.Id ...]   caches the manifests (node_modules/.cache/catalog-audit)
 *   vite-node scripts/audit-catalog.ts derive                 extracted facts per package (cache/derived.json)
 *   vite-node scripts/audit-catalog.ts audit                  writes docs/unified-app-catalog/catalog-audit.json
 *   vite-node scripts/audit-catalog.ts apply                  rewrites src/data/apps/catalog.json from the audit
 *
 * Needs a GitHub token in GITHUB_TOKEN or the GitHub CLI (`gh auth token`). Responses are cached,
 * so a re-run makes no requests. The facts feed docs/unified-app-catalog/catalog-audit.json.
 */
import { execSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

// js-yaml ships with the toolchain (a dependency of the build tools); it is only used by this script.
const yaml = createRequire(import.meta.url)('js-yaml') as { load(s: string): unknown };

const REPO = 'microsoft/winget-pkgs';
const ROOT = fileURLToPath(new URL('..', import.meta.url));
const CACHE = join(ROOT, 'node_modules/.cache/catalog-audit');
mkdirSync(CACHE, { recursive: true });

const BASE = 'b9ddf63'; // the catalog commit the audit started from (289 entries)

let token = '';
const auth = () => (token ||= process.env.GITHUB_TOKEN || execSync('gh auth token', { encoding: 'utf8' }).trim());
const safe = (s: string) => s.replace(/[^A-Za-z0-9._-]+/g, '_').slice(0, 180);

async function cached(name: string, get: () => Promise<string | null>): Promise<string | null> {
  const f = join(CACHE, safe(name));
  if (existsSync(f)) {
    const t = readFileSync(f, 'utf8');
    return t === '\u0000404' ? null : t;
  }
  const t = await get();
  writeFileSync(f, t ?? '\u0000404');
  return t;
}

async function api(path: string): Promise<unknown> {
  const t = await cached(`api_${path}`, async () => {
    for (let i = 0; i < 5; i++) {
      const r = await fetch(`https://api.github.com/${path}`, { headers: { Authorization: `Bearer ${auth()}`, Accept: 'application/vnd.github+json', 'User-Agent': 'wdb-catalog-audit' } });
      if (r.status === 403 || r.status === 429 || r.status >= 500) {
        await new Promise((ok) => setTimeout(ok, 4000 * (i + 1)));
        continue;
      }
      return r.status === 200 ? r.text() : null;
    }
    throw new Error(`GitHub API refused ${path} repeatedly`);
  });
  return t === null ? null : JSON.parse(t);
}

const enc = (p: string) => p.split('/').map(encodeURIComponent).join('/');
const raw = (sha: string, path: string) =>
  cached(`raw_${sha.slice(0, 10)}_${path}`, async () => {
    const r = await fetch(`https://raw.githubusercontent.com/${REPO}/${sha}/${enc(path)}`, { headers: { 'User-Agent': 'wdb-catalog-audit' } });
    return r.status === 200 ? r.text() : null;
  });

type Entry = { name: string; type: string; path: string };
const list = async (sha: string, path: string) => (await api(`repos/${REPO}/contents/${enc(path)}?ref=${sha}`)) as Entry[] | null;

function versionKey(v: string): (number | string)[] {
  return v.split(/[^0-9A-Za-z]+/).map((p) => (/^\d+$/.test(p) ? Number(p) : p));
}
function compareVersions(a: string, b: string): number {
  const x = versionKey(a), y = versionKey(b);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const p = x[i] ?? 0, q = y[i] ?? 0;
    if (p === q) continue;
    if (typeof p === 'number' && typeof q === 'number') return p - q;
    return String(p).localeCompare(String(q));
  }
  return 0;
}

function headSha(): Promise<{ sha: string; date: string }> {
  const f = join(CACHE, 'HEAD.json');
  if (existsSync(f)) return Promise.resolve(JSON.parse(readFileSync(f, 'utf8')));
  return (api(`repos/${REPO}/commits/master?x=${Date.now()}`) as Promise<{ sha: string; commit: { committer: { date: string } } }>).then((h) => {
    const v = { sha: h.sha, date: h.commit.committer.date };
    writeFileSync(f, JSON.stringify(v));
    return v;
  });
}

/** Resolves the package folder (exact path first, then case-insensitive segment by segment). */
async function packageDir(sha: string, id: string): Promise<{ path: string; canonicalId: string; entries: Entry[] } | { missing: string }> {
  const exact = `manifests/${id[0]!.toLowerCase()}/${id.split('.').join('/')}`;
  const e = await list(sha, exact);
  if (e) return { path: exact, canonicalId: id, entries: e };
  let path = `manifests/${id[0]!.toLowerCase()}`;
  const canonical: string[] = [];
  for (const seg of id.split('.')) {
    const entries = await list(sha, path);
    const hit = entries?.find((x) => x.type === 'dir' && x.name.toLowerCase() === seg.toLowerCase());
    if (!hit) return { missing: `no folder ${path}/${seg}` };
    canonical.push(hit.name);
    path = `${path}/${hit.name}`;
  }
  return { path, canonicalId: canonical.join('.'), entries: (await list(sha, path)) ?? [] };
}

export type ManifestFacts = Awaited<ReturnType<typeof readPackage>>;

async function readPackage(sha: string, id: string) {
  const dir = await packageDir(sha, id);
  if ('missing' in dir) return { id, exists: false as const, problem: dir.missing };
  const dirs = dir.entries.filter((x) => x.type === 'dir').map((x) => x.name);
  const ordered = [...dirs.filter((n) => /^\d/.test(n)).sort(compareVersions).reverse(), ...dirs.filter((n) => !/^\d/.test(n)).sort(compareVersions).reverse()];
  const subPackages: string[] = [];
  for (const v of ordered.slice(0, 12)) {
    const files = (await list(sha, `${dir.path}/${v}`)) ?? [];
    const inst = files.find((f) => f.name === `${dir.canonicalId}.installer.yaml`);
    const single = files.find((f) => f.name === `${dir.canonicalId}.yaml`);
    if (!inst && !single) {
      if (files.some((f) => f.type === 'dir')) subPackages.push(v);
      continue;
    }
    const installerText = (await raw(sha, `${dir.path}/${v}/${(inst ?? single)!.name}`)) ?? '';
    const versionText = (await raw(sha, `${dir.path}/${v}/${dir.canonicalId}.yaml`)) ?? '';
    const versionDoc = (inst ? (yaml.load(versionText) as Record<string, unknown>) : null) ?? {};
    const defaultLocale = String(versionDoc.DefaultLocale ?? 'en-US');
    const localeName = files.find((f) => f.name === `${dir.canonicalId}.locale.en-US.yaml`)?.name ?? files.find((f) => f.name === `${dir.canonicalId}.locale.${defaultLocale}.yaml`)?.name;
    const localeText = localeName ? ((await raw(sha, `${dir.path}/${v}/${localeName}`)) ?? '') : single ? installerText : '';
    const commits = (await api(`repos/${REPO}/commits?sha=${sha}&path=${enc(`${dir.path}/${v}`)}&per_page=1`)) as { commit: { committer: { date: string } } }[] | null;
    return {
      id,
      exists: true as const,
      canonicalId: dir.canonicalId,
      path: dir.path,
      latestVersion: v,
      versionFolders: ordered.length - subPackages.length,
      subPackages,
      otherFiles: files.filter((f) => !f.name.startsWith(`${dir.canonicalId}.`)).map((f) => f.name),
      versionCommitDate: commits?.[0]?.commit.committer.date ?? '',
      installer: yaml.load(installerText) as Record<string, unknown>,
      locale: (yaml.load(localeText) ?? {}) as Record<string, unknown>,
      localeFile: localeName ?? '',
    };
  }
  return { id, exists: false as const, problem: `no version folder with ${dir.canonicalId}.installer.yaml in ${dir.path}`, path: dir.path, subPackages };
}

function catalogIds(): string[] {
  const c = JSON.parse(execSync(`git show ${BASE}:src/data/apps/catalog.json`, { cwd: ROOT, encoding: 'utf8', maxBuffer: 64 << 20 })) as { entries: { source: string; packageIdentifier: string | null; alternateIds?: string[] }[] };
  return c.entries.filter((e) => e.source === 'winget' && e.packageIdentifier).flatMap((e) => [e.packageIdentifier!, ...(e.alternateIds ?? [])]);
}

async function pool<T, R>(items: T[], n: number, f: (t: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let i = 0;
  await Promise.all(Array.from({ length: n }, async () => {
    while (i < items.length) {
      const k = i++;
      out[k] = await f(items[k]!);
    }
  }));
  return out;
}

// ---------------------------------------------------------------------------------------------
// Derivation: what an installer manifest says about unattended installation and its evidence.
// ---------------------------------------------------------------------------------------------

type Doc = Record<string, unknown>;
type Afe = { DisplayName?: string; ProductCode?: string; UpgradeCode?: string; DisplayVersion?: string };
/** Keys an installer inherits from the manifest root unless it sets them itself. */
const INHERITED = ['InstallerType', 'NestedInstallerType', 'NestedInstallerFiles', 'Scope', 'InstallModes', 'ElevationRequirement', 'AppsAndFeaturesEntries', 'PackageFamilyName', 'Commands', 'ProductCode', 'ReleaseDate', 'InstallationMetadata', 'UpgradeBehavior', 'ExpectedReturnCodes', 'InstallerSuccessCodes', 'RequireExplicitUpgrade', 'Dependencies', 'UnsupportedOSArchitectures'] as const;
/** Installer types WinGet runs silently by default (it supplies the silent switches itself). */
const SILENT_TYPES = ['msi', 'wix', 'msix', 'appx', 'burn', 'inno', 'nullsoft', 'portable'];

function installersOf(doc: Doc): Doc[] {
  const list = (Array.isArray(doc.Installers) ? doc.Installers : []) as Doc[];
  return list.map((i) => {
    const m: Doc = { Architecture: i.Architecture, InstallerUrl: i.InstallerUrl };
    for (const k of INHERITED) m[k] = i[k] ?? doc[k];
    m.InstallerSwitches = { ...((doc.InstallerSwitches as Doc) ?? {}), ...((i.InstallerSwitches as Doc) ?? {}) };
    return m;
  });
}
const str = (v: unknown) => (v === undefined || v === null ? '' : String(v));
const uniq = <T>(a: T[]) => [...new Set(a)];

function effectiveType(i: Doc): string {
  const t = str(i.InstallerType).toLowerCase();
  return t === 'zip' ? `zip/${str(i.NestedInstallerType).toLowerCase() || '?'}` : t;
}
/** Why an installer is unattended, or '' when the manifest gives no evidence that it is. */
function silentEvidence(i: Doc): string {
  const modes = (i.InstallModes as string[] | undefined) ?? [];
  if (modes.map((m) => String(m).toLowerCase()).includes('silent')) return 'InstallModes lists silent';
  const t = effectiveType(i);
  const base = t.startsWith('zip/') ? t.slice(4) : t;
  if (SILENT_TYPES.includes(base)) return `${t} installer (WinGet supplies the silent switches)`;
  const sw = (i.InstallerSwitches as Doc) ?? {};
  if (base === 'exe' && str(sw.Silent)) return `exe with Silent switch "${str(sw.Silent)}"`;
  return '';
}

/** "Apps & features" display-name prefix: the name without the version (and locale) it carries. */
export function displayPrefix(name: string, versions: string[], id: string, multiArch = false): string {
  let n = name.trim();
  const tail = /\.(\d+(?:\.\d+)?)$/.exec(id)?.[1]; // Python.Python.3.14, SublimeHQ.SublimeText.4
  const cut = (at: number) => {
    let keep = at;
    if (tail && n.slice(at).startsWith(tail)) keep = at + tail.length;
    n = n.slice(0, keep);
  };
  const vs = uniq(versions.filter((v) => /\d\./.test(v)).flatMap((v) => [v, v.replace(/(\.0)+$/, '')])).filter((v) => v.includes('.'));
  let hit = vs.map((v) => n.indexOf(v)).filter((i) => i > 0).sort((a, b) => a - b)[0];
  if (hit !== undefined) {
    while (hit > 0 && /[A-Za-z]/.test(n[hit - 1]!) && /[A-Za-z]/.test(n[hit - 2] ?? ' ')) hit--; // "go1.27.4"
    if (/[A-Za-z]/.test(n[hit - 1] ?? ' ')) hit--; // "v1.2"
    cut(hit);
  }
  else {
    const m = /\s[-–]?\s*v?\d+(?:\.\d+){1,}\S*.*$/.exec(n);
    if (m && m.index > 0) cut(m.index + 1);
  }
  n = n.replace(/\s*\((?=[^)]*\b[a-z]{2,3}-[A-Za-z]{2,4}\b)[^)]*\)\s*$/, ''); // "(x64 en-US)"
  n = n.replace(/[\s\-–:,(]+$/, '').replace(/\s+v$/i, '').trim();
  if (multiArch) {
    // One product with an installer per architecture: "PowerToys (Preview) x64" / "... ARM64".
    n = n.replace(/\s*\((?:\s*(?:x64|x86|amd64|arm64|arm32|arm|386|64-bit|32-bit|64|bit|portable)\s*)+\)$/i, '').replace(/\s+(?:x64|x86|amd64|arm64|386)$/i, '').trim();
  }
  return n;
}

function urlVersioned(url: string, version: string): boolean {
  const v = version.replace(/^v/i, '');
  const parts = [v, v.replace(/\./g, ''), v.replace(/\./g, '_'), v.replace(/\./g, '-'), v.replace(/(\.0)+$/, '')].filter((x) => x.length >= 2);
  return parts.some((p) => url.includes(p));
}

const ARCH: Record<string, string> = { x64: 'x64', x86: 'x86', arm64: 'arm64' };
const ROOTS: [RegExp, string][] = [
  [/^%ProgramFiles%/i, '%ProgramFiles%'],
  [/^%ProgramFiles\(x86\)%/i, '%ProgramFiles(x86)%'],
  [/^%ProgramData%/i, '%ProgramData%'],
  [/^%LocalAppData%/i, '%LocalAppData%'],
  [/^%AppData%/i, '%AppData%'],
];

export function deriveFacts(p: Extract<ManifestFacts, { exists: true }>) {
  const doc = p.installer;
  const loc = p.locale;
  const ins = installersOf(doc);
  const version = str(doc.PackageVersion || p.latestVersion);
  const afe = ins.flatMap((i) => (i.AppsAndFeaturesEntries as Afe[] | undefined) ?? []);
  const evidence = ins.map(silentEvidence);
  // WinGet installs a portable package (or a zip of portables) per user unless --scope machine is given.
  const scopeOf = (i: Doc) => str(i.Scope) || (/^(portable|zip\/portable)$/.test(effectiveType(i)) ? 'user' : '');
  const declaredScopes = uniq(ins.map(scopeOf).filter(Boolean)).sort();
  const meta = (i: Doc) => (i.InstallationMetadata as Doc | undefined) ?? {};
  const locations = uniq(ins.map((i) => str(meta(i).DefaultInstallLocation)).filter(Boolean));
  const metaFiles = ins.flatMap((i) => ((meta(i).Files as Doc[] | undefined) ?? []).map((f) => ({ loc: str(meta(i).DefaultInstallLocation), rel: str(f.RelativeFilePath), type: str(f.FileType) })));
  const urls = ins.map((i) => str(i.InstallerUrl));
  const switches = ins.map((i) => i.InstallerSwitches as Doc);
  const pfn = uniq(ins.map((i) => str(i.PackageFamilyName)).filter(Boolean));
  const returnCodes = ins.flatMap((i) => ((i.ExpectedReturnCodes as Doc[] | undefined) ?? []).map((r) => str(r.ReturnResponse)));
  const successCodes = ins.flatMap((i) => ((i.InstallerSuccessCodes as unknown[] | undefined) ?? []).map(String));
  let scope: 'machine' | 'user' | 'either' | 'unknown' = 'unknown';
  let scopeEvidence = '';
  if (declaredScopes.length === 2) [scope, scopeEvidence] = ['either', `installers for both scopes (${ins.map((i) => `${effectiveType(i)}:${scopeOf(i) || '-'}`).filter((v, k, a) => a.indexOf(v) === k).join(', ')})`];
  else if (declaredScopes.length === 1) [scope, scopeEvidence] = [declaredScopes[0] as 'machine' | 'user', `Scope ${declaredScopes[0]}${ins.some((i) => !scopeOf(i)) ? ' (some installers declare none)' : ''}${ins.some((i) => !i.Scope && scopeOf(i)) ? ' (portable: per user by default)' : ''}`];
  else if (locations.length && locations.every((l) => /^%ProgramFiles/i.test(l))) [scope, scopeEvidence] = ['machine', `DefaultInstallLocation ${locations[0]}`];
  else if (locations.length && locations.every((l) => /^%(LocalAppData|AppData)%/i.test(l))) [scope, scopeEvidence] = ['user', `DefaultInstallLocation ${locations[0]}`];
  // Windows 11 runs on x64 and Arm64 only: an installer unsupported on both is never selected.
  const usable = ins.filter((i) => { const u = ((i.UnsupportedOSArchitectures as string[] | undefined) ?? []).map(String); return !(u.includes('x64') && u.includes('arm64')); });
  const archs = uniq(usable.map((i) => str(i.Architecture)));
  const names = uniq(afe.map((a) => str(a.DisplayName)).filter(Boolean));
  const multiArch = uniq(archs.filter((a) => a !== 'neutral')).length > 1;
  const prefixes = uniq(names.map((n) => displayPrefix(n, [version, ...afe.map((a) => str(a.DisplayVersion))], p.canonicalId, multiArch)).filter((n) => n.length >= 3 && n.length <= 100));
  return {
    exists: true as const,
    manifestPath: `${p.path}/${p.latestVersion}`,
    latestVersion: p.latestVersion,
    versionFolders: p.versionFolders,
    manifestCommitDate: p.versionCommitDate.slice(0, 10),
    releaseDate: uniq(ins.map((i) => (i.ReleaseDate instanceof Date ? i.ReleaseDate.toISOString() : str(i.ReleaseDate))).filter(Boolean).map((d) => d.slice(0, 10)))[0] ?? '',
    packageName: str(loc.PackageName),
    publisher: str(loc.Publisher),
    license: str(loc.License),
    packageUrl: str(loc.PackageUrl || loc.PublisherUrl),
    agreements: Array.isArray(loc.Agreements) && loc.Agreements.length > 0,
    installerTypes: uniq(ins.map(effectiveType)).sort(),
    scopes: declaredScopes,
    architectures: archs.sort(),
    installModes: uniq(ins.flatMap((i) => ((i.InstallModes as string[] | undefined) ?? []).map(String))).sort(),
    installerSwitches: {
      silent: uniq(switches.map((s) => str(s?.Silent)).filter(Boolean)),
      silentWithProgress: uniq(switches.map((s) => str(s?.SilentWithProgress)).filter(Boolean)),
      custom: uniq(switches.map((s) => str(s?.Custom)).filter(Boolean)),
    },
    elevation: uniq(ins.map((i) => str(i.ElevationRequirement)).filter(Boolean)).sort(),
    appsAndFeaturesEntries: uniq(afe.map((a) => JSON.stringify({ displayName: str(a.DisplayName), productCode: str(a.ProductCode), upgradeCode: str(a.UpgradeCode) }))).map((s) => JSON.parse(s) as { displayName: string; productCode: string; upgradeCode: string }),
    productCodes: uniq([...ins.map((i) => str(i.ProductCode)), ...afe.map((a) => str(a.ProductCode))].filter(Boolean)).slice(0, 8),
    packageFamilyNames: pfn,
    commands: uniq(ins.flatMap((i) => ((i.Commands as unknown[] | undefined) ?? []).map(String))).sort(),
    defaultInstallLocations: locations,
    installerUrls: uniq(urls),
    urlsVersioned: urls.every((u) => urlVersioned(u, version)),
    requireExplicitUpgrade: ins.some((i) => i.RequireExplicitUpgrade === true),
    rebootEvidence: uniq([...returnCodes.filter((r) => /reboot/i.test(r)), ...successCodes.filter((c) => c === '3010' || c === '1641').map((c) => `success code ${c}`)]),
    dependencies: uniq(ins.flatMap((i) => (((i.Dependencies as Doc | undefined)?.PackageDependencies as Doc[] | undefined) ?? []).map((d) => str(d.PackageIdentifier)))),
    silent: evidence.length > 0 && evidence.every(Boolean),
    silentPartial: evidence.some(Boolean) && !evidence.every(Boolean),
    silentEvidence: uniq(evidence.filter(Boolean)),
    scope,
    scopeEvidence,
    uninstallPrefixes: prefixes.filter((x) => !prefixes.some((y) => y !== x && x.startsWith(y))).slice(0, 10),
    appxNames: uniq(pfn.map((f) => f.replace(/_[a-z0-9]{13}$/i, ''))).filter((n) => /^[A-Za-z0-9][A-Za-z0-9.-]{2,99}$/.test(n)),
    files: uniq(
      metaFiles
        .filter((f) => /\.exe$/i.test(f.rel) && (!f.type || /launch/i.test(f.type)))
        .flatMap((f) => {
          const root = ROOTS.find(([re]) => re.test(f.loc));
          return root ? [`${f.loc.replace(root[0], root[1])}\\${f.rel}`.replace(/\//g, '\\').replace(/\\{2,}/g, '\\')] : [];
        }),
    ),
    archMapped: ['x64', 'x86', 'arm64'].filter((a) => archs.some((x) => ARCH[x] === a)),
  };
}
export type Derived = ReturnType<typeof deriveFacts>;

// ---------------------------------------------------------------------------------------------
// Audit and catalog update. Both start from the catalog as it was before the audit (BASE), so a
// re-run gives the same result. Decisions that are not mechanical are written out below.
// ---------------------------------------------------------------------------------------------

const CHECKED = '2026-11-27';
/** Looked up besides the catalog's own identifiers (task: renamed, moved or alternative packages). */
const EXTRA_IDS = ['TimKosse.FileZilla.Client', 'FreeFileSync.FreeFileSync', 'OpenJS.NodeJS', 'Microsoft.Sysinternals', 'Microsoft.Sysinternals.Suite', 'RustDesk.RustDesk', 'LaunchBox.LaunchBox'];

type CatEntry = Record<string, unknown> & { id: string; displayName: string; packageIdentifier: string | null; source: string; method?: string; interaction: string; detectNames?: string[]; validation: { status: string; checkedAt: string; method: string } };
type Store = { id: string; resolves: boolean; name: string; publisher: string; publisherUrl: string; installerType: string; offline: boolean; license: string };

const byIdOf = (facts: { packages: ManifestFacts[] }, id: string) => facts.packages.find((p) => p.id.toLowerCase() === id.toLowerCase());

function store(id: string): Store {
  const f = join(CACHE, 'msstore', `${id}.txt`);
  const t = existsSync(f) ? readFileSync(f, 'utf8').replace(/^\uFEFF/, '') : '';
  const line = (k: string) => new RegExp(`^\\s*${k}:\\s*(.*)$`, 'm').exec(t)?.[1]?.trim() ?? '';
  const found = /^Found (.+) \[([A-Z0-9]+)\]/m.exec(t);
  return { id, resolves: !!found, name: found?.[1] ?? '', publisher: line('Publisher'), publisherUrl: line('Publisher Url'), installerType: line('Installer Type'), offline: /Offline Distribution Supported: true/.test(t), license: line('License') };
}

type Decision = { decision: 'keep' | 'repair' | 'manual' | 'remove'; reason: string; problems?: string[] };
const SYSINTERNALS_STORE = '9P7KNL5RWT25';
/** Entry-specific findings and decisions (everything else follows from the manifest). */
const DECIDED: Record<string, Decision & { patch?: Record<string, unknown>; manual?: { reason: string; instructions: string; url: string }; verify?: Record<string, unknown> }> = {
  battlenet: {
    decision: 'manual',
    patch: { description: "Blizzard's game launcher. Installed by hand: its setup has no unattended mode." },
    reason: 'Blizzard.BattleNet 2.0.0.4232 is a plain exe with no Silent switch and no silent InstallModes (only Custom --lang=enUS): WinGet would start the interactive Battle.net setup. The Microsoft Store listing XPDM5VSMTKQLBJ (publisher Blizzard Entertainment Inc.) serves the same Battle.net-Setup.exe (identical SHA-256) as a Store-hosted exe with no switches shown. Converted to a manual follow-up with the official download from the manifest (PackageUrl).',
    problems: ['exe installer without a silent switch or silent install mode', 'InstallerUrl is unversioned (getInstaller?…): the published hash goes stale when Blizzard replaces the file'],
    manual: {
      reason: 'The WinGet package Blizzard.BattleNet (2.0.0.4232, winget-pkgs a549889c) and the Store listing XPDM5VSMTKQLBJ are the same plain exe setup with no silent switch, so it cannot be installed unattended. Rechecked 2026-11-27.',
      instructions: 'Download the Battle.net desktop app from Blizzard\'s official page, run the setup, and let the customer sign in with their own Battle.net account.',
      url: 'https://download.battle.net/en-us/desktop',
    },
  },
  aimp: {
    decision: 'repair',
    reason: 'AIMP.AIMP has a single stale version (5.10.2418, manifest committed 2023-01-04): the WinGet package is unmaintained and would install a build several years old. The Microsoft Store has AIMP as 9PCLLLH15SMT (winget show: publisher Artem Izmaylov, the same publisher as the WinGet manifest, publisher URL http://www.aimp.ru, Installer Type msstore), which the Store keeps current, so the entry now installs that; AIMP.AIMP stays an alternate id.',
    problems: ['manifest not updated since 2023-01-04 (unmaintained package)'],
    patch: {
      packageIdentifier: '9PCLLLH15SMT',
      source: 'msstore',
      description: 'Lightweight audio player with a good equaliser and playlist handling, from the Microsoft Store (publisher Artem Izmaylov).',
      architectures: [],
      installerType: 'msstore',
      license: 'Free (Microsoft Store)',
      publisher: 'Artem Izmaylov',
      alternateIds: ['AIMP.AIMP'],
      notes: 'The WinGet package AIMP.AIMP has not been updated since 2023 (5.10.2418); the Store edition is current. An AIMP installed with WinGet is still recognised.',
    },
  },
  'amazon-music': {
    decision: 'remove',
    reason: 'Amazon.Music: plain exe without a silent switch or silent mode (not unattended), the manifest is stale (9.4.0.2386, 2023-01-23) and names no official URL, and Amazon Music is not in the Microsoft Store (winget search, 2026-11-27). Nothing verifiable to convert to a manual entry.',
    problems: ['exe installer without a silent switch or silent install mode', 'manifest not updated since 2023-01-23 (unmaintained package)', 'no PublisherUrl/PackageUrl in the manifest', 'no Microsoft Store package (winget search "Amazon Music" --source msstore: none)'],
  },
  whiteboard: {
    decision: 'remove',
    reason: 'Microsoft Store product 9MSPC6MP8FM4 no longer resolves (winget show --exact and search --id, msstore source, 2026-11-27, while other Store ids resolved); no Whiteboard in the Store search and no manifests/m/Microsoft/Whiteboard in winget-pkgs a549889c.',
    problems: ['Store product id does not resolve'],
  },
  sysinternals: {
    decision: 'repair',
    reason: `The reported "Installer hash mismatch" is structural: Microsoft.Sysinternals.Suite (2026-10-15, one version folder) downloads the unversioned https://download.sysinternals.com/files/SysinternalsSuite.zip, so its SHA-256 is stale from the moment Microsoft updates the zip until the manifest is updated (days). WDB never ignores the hash; a source refresh + retry only helps once the manifest has caught up. The Microsoft Store edition ${SYSINTERNALS_STORE} (winget show: Sysinternals Suite, publisher Microsoft Corporation, publisher URL https://www.sysinternals.com, licence live.sysinternals.com/Eula.txt) is updated by the Store and has no hash window, so the entry now installs it; the WinGet id stays an alternate id (recognised as installed).`,
    problems: ['zip/portable with an unversioned InstallerUrl: the published hash goes stale whenever Microsoft updates the suite'],
    patch: {
      packageIdentifier: SYSINTERNALS_STORE,
      source: 'msstore',
      description: 'Microsoft\'s Sysinternals troubleshooting tools (Process Explorer, Process Monitor, Autoruns, PsTools, …) from the Microsoft Store (publisher Microsoft Corporation), which keeps them up to date.',
      website: 'https://www.sysinternals.com/',
      architectures: [],
      installerType: 'msstore',
      license: 'Sysinternals licence terms (Microsoft Store)',
      publisher: 'Microsoft Corporation',
      alternateIds: ['Microsoft.Sysinternals.Suite'],
      notes: 'The WinGet package Microsoft.Sysinternals.Suite downloads an unversioned zip whose published hash goes stale whenever Microsoft updates it (the "installer hash mismatch" seen on a deployment). The Store edition has no such window. A suite installed with WinGet is still recognised.',
    },
  },
  'sublime-text': {
    decision: 'repair',
    reason: 'SublimeHQ.SublimeText.4 4.0.0.421500 (build 4215) is the 4.x edition: an inno installer (Scope machine, DefaultInstallLocation %ProgramFiles%\\Sublime Text, AppsAndFeatures "Sublime Text", ProductCode "Sublime Text_is1") and a zip/portable (AppsAndFeatures "Sublime Text (Portable)") whose NestedInstallerFiles name sublime_text.exe. The file evidence %ProgramFiles%\\Sublime Text\\sublime_text.exe combines the inno install location with that executable name; the uninstall prefix "Sublime Text" matches both installers.',
    verify: { files: ['%ProgramFiles%\\Sublime Text\\sublime_text.exe'] },
  },
  'nodejs-lts': {
    decision: 'repair',
    reason: 'OpenJS.NodeJS.LTS 26.13.1: wix, Scope machine, x64 + arm64, Commands node/npm/npx/corepack; the manifest has no AppsAndFeaturesEntries or InstallationMetadata. The same nodejs.org MSI family records AppsAndFeatures DisplayName "Node.js" (publisher Node.js Foundation) in OpenJS.NodeJS 26.0.0-26.5.0, so "Node.js" is the uninstall evidence. No manifest names %ProgramFiles%\\nodejs\\node.exe, so no file evidence is written (PATH is never used). OpenJS.NodeJS (Current, 26.12.1) is a separate package and not in the catalog.',
    verify: { uninstall: ['Node.js'] },
  },
  'acrobat-reader': {
    decision: 'keep',
    reason: 'Adobe.Acrobat.Reader.64-bit 26.003.22110: exe, Scope machine, Silent "-sfx_nu /sAll /rs /msi", ProductCode {AC76BA86-1033-FF00-7760-BC15014EA700}; AppsAndFeaturesEntries DisplayName "Adobe Acrobat (64-bit)" (the unified Acrobat/Reader name) confirms the existing detectNames; ExpectedReturnCodes 3010/1641 mean a restart may be required.',
  },
  'claude-desktop': {
    decision: 'repair',
    reason: 'Anthropic.Claude 6.28899.6: MSIX installers (PackageFamilyName Claude_pzs8sxrjxfjjc, no scope: registered per user) listed first, plus per-user exe installers (Scope user, Silent --silent, ProductCode AnthropicClaude). Evidence: appx "Claude", perUser. The manifest has no AppsAndFeatures DisplayName and no install path, so no uninstall name or %LocalAppData% file is written; nothing in the manifest says installation completes only at first launch or sign-in, so "after" stays unset.',
  },
  chatgpt: {
    decision: 'keep',
    reason: 'winget show --id 9PLM9XGG6VKS --exact --source msstore: ChatGPT, publisher OpenAI, Installer Type msstore, offline distribution supported. The Store listing does not expose the AppX package name, so verify.appx stays unset (not guessed); the Store package is registered per user (perUser).',
  },
  filezilla: {
    decision: 'keep',
    reason: 'Still no official package: no manifests/t/TimKosse folder (TimKosse.FileZilla.Client) and no FileZilla publisher folder under manifests/f or manifests/t at winget-pkgs a549889c (2026-11-27). Stays manual.',
  },
  freefilesync: {
    decision: 'keep',
    reason: 'Still no official package: no manifests/f/FreeFileSync folder and no Zenju folder under manifests/z at winget-pkgs a549889c (2026-11-27). Stays manual.',
  },
  rustdesk: { decision: 'keep', reason: 'Still no manifests/r/RustDesk folder at winget-pkgs a549889c (2026-11-27). Stays manual.' },
  launchbox: { decision: 'keep', reason: 'Still no manifests/l/LaunchBox folder at winget-pkgs a549889c (2026-11-27). Stays manual.' },
  joplin: { decision: 'repair', reason: 'Category corrected from "touch" (pen and handwriting tools) to "documents": Joplin is a note-taking app. The Touchscreen profile still recommends it.', patch: { category: 'documents' } },
  'thunderbird-esr': { decision: 'keep', reason: 'Not a duplicate of Mozilla.Thunderbird: Mozilla.Thunderbird.ESR is the separate Extended Support Release channel (its own manifest folder and versions).' },
  'chrome-canary': { decision: 'keep', reason: 'Not a duplicate of Google.Chrome: Google.Chrome.Canary is the separate nightly channel, installed side by side per user.' },
};

/** Visual C++ runtimes: one entry per architecture and family (x86 is never redundant on x64 Windows). */
const VC: Record<string, { description: string; registry?: { key: string; name: string; equals: string; view: '64' | '32' }[] }> = {
  'vcredist-x64': {
    description: 'Visual C++ 2015-2026 (v14) runtime for 64-bit programs. Installed together with the x86 runtime: 64-bit programs load this one, 32-bit programs need the x86 one even on 64-bit Windows.',
    registry: [{ key: 'HKLM\\SOFTWARE\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\X64', name: 'Installed', equals: '1', view: '64' }],
  },
  'vcredist-x86': {
    description: 'Visual C++ 2015-2026 (v14) runtime for 32-bit programs, which still need it on 64-bit Windows; 64-bit programs need the separate x64 runtime, so both are installed.',
    registry: [{ key: 'HKLM\\SOFTWARE\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\X86', name: 'Installed', equals: '1', view: '32' }],
  },
  'vcredist-2013-x64': { description: 'Legacy Visual C++ 2013 runtime for 64-bit programs that ask for it. 32-bit programs need the separate x86 package, even on 64-bit Windows.' },
  'vcredist-2013-x86': { description: 'Legacy Visual C++ 2013 runtime for 32-bit programs that ask for it (needed on 64-bit Windows too). 64-bit programs need the separate x64 package.' },
  'vcredist-2012-x64': { description: 'Legacy Visual C++ 2012 runtime for 64-bit programs that ask for it. 32-bit programs need the separate x86 package, even on 64-bit Windows.' },
  'vcredist-2012-x86': { description: 'Legacy Visual C++ 2012 runtime for 32-bit programs that ask for it (needed on 64-bit Windows too). 64-bit programs need the separate x64 package.' },
  'vcredist-2010-x64': { description: 'Legacy Visual C++ 2010 SP1 runtime for 64-bit programs that ask for it. 32-bit programs need the separate x86 package, even on 64-bit Windows.' },
  'vcredist-2010-x86': { description: 'Legacy Visual C++ 2010 SP1 runtime for 32-bit programs that ask for it (needed on 64-bit Windows too). 64-bit programs need the separate x64 package.' },
};

const typeLabel = (types: string[]) => {
  const t = types.map((x) => (x.startsWith('zip/') ? `${x.slice(4)} (zip)` : x)).join(', ');
  return t.length <= 40 ? t : `${t.slice(0, 37)}...`;
};
const methodOfEntry = (e: CatEntry) => e.method ?? (e.source === 'none' ? 'manual' : e.source);
/** Schema key order (src/engine/applications/catalog.ts), so diffs stay readable. */
const KEY_ORDER = ['id', 'displayName', 'packageIdentifier', 'source', 'method', 'category', 'description', 'website', 'architectures', 'scope', 'installerType', 'license', 'requires', 'interaction', 'accountSignIn', 'reboot', 'notes', 'selectionWarning', 'conflictGroup', 'portable', 'manual', 'publisher', 'kind', 'removal', 'upgrade', 'hardware', 'alternateIds', 'detectNames', 'verify', 'validation'];
const ordered = (e: Record<string, unknown>) => Object.fromEntries([...KEY_ORDER.filter((k) => e[k] !== undefined).map((k) => [k, e[k]]), ...Object.entries(e).filter(([k]) => !KEY_ORDER.includes(k))]);

function buildAudit() {
  const base = JSON.parse(execSync(`git show ${BASE}:src/data/apps/catalog.json`, { cwd: ROOT, encoding: 'utf8', maxBuffer: 64 << 20 })) as { entries: CatEntry[]; excluded: unknown[] } & Record<string, unknown>;
  const facts = JSON.parse(readFileSync(join(CACHE, 'facts.json'), 'utf8')) as { commit: string; commitDate: string; packages: ManifestFacts[] };
  const byId = new Map(facts.packages.map((p) => [p.id.toLowerCase(), p]));
  const short = facts.commit.slice(0, 8);
  const records: Record<string, unknown>[] = [];
  const entries: Record<string, unknown>[] = [];
  const excluded = [...base.excluded];
  for (const e of base.entries) {
    const d = DECIDED[e.id];
    const method = methodOfEntry(e);
    const problems: string[] = [...(d?.problems ?? [])];
    const rec: Record<string, unknown> = { id: e.id, displayName: e.displayName, packageIdentifier: e.packageIdentifier, source: e.source, method };
    let next: Record<string, unknown> = { ...e };
    if (method === 'manual' || method === 'vendor') {
      Object.assign(rec, { status: 'manual', manifest: null, silent: false, scope: 'n/a', verification: 'manual follow-up: the technician confirms the installation', problems, decision: d?.decision ?? 'keep', reason: d?.reason ?? `No WinGet or Store package (${String((e.manual as { reason?: string } | undefined)?.reason ?? '')})`.slice(0, 600) });
      if (d?.reason && ['filezilla', 'freefilesync'].includes(e.id)) {
        const m = { ...(e.manual as Record<string, string>) };
        m.reason = m.reason!.replace('rechecked 2026-11-26', `rechecked ${CHECKED} at winget-pkgs ${short}`).slice(0, 300);
        next = { ...next, manual: m, validation: { status: 'manual', checkedAt: CHECKED, method: m.reason } };
      }
      records.push(rec);
      entries.push(ordered(next));
      continue;
    }
    if (e.source === 'msstore') {
      const s = store(e.packageIdentifier!);
      const msix = /^msstore$/i.test(s.installerType);
      Object.assign(rec, {
        status: s.resolves ? 'verified' : 'missing',
        store: s,
        silent: s.resolves && msix,
        silentEvidence: msix ? ['Microsoft Store package (Installer Type msstore): installed unattended by WinGet'] : s.resolves ? [`Store-hosted ${s.installerType} installer: winget show lists no silent switch`] : [],
        scope: msix ? 'user' : 'unknown',
        scopeEvidence: msix ? 'Microsoft Store packages are registered per user' : '',
      });
      if (!s.resolves) problems.push('Store product id does not resolve (winget show --exact --source msstore)');
      if (s.resolves && !msix) problems.push(`Store lists a ${s.installerType} installer without silent switches`);
      if (d?.decision === 'remove') {
        excluded.push({ name: e.displayName, packageIdentifier: e.packageIdentifier!, reason: d.reason.slice(0, 300), removed: { date: CHECKED, formerId: e.id } });
        Object.assign(rec, { problems, decision: 'remove', reason: d.reason });
        records.push(rec);
        continue;
      }
      const verify: Record<string, unknown> = { ...(d?.verify ?? {}) };
      if (msix) verify.perUser = true;
      next = {
        ...next,
        scope: msix ? 'user' : e.scope,
        interaction: e.interaction === 'mayPrompt' ? 'mayPrompt' : msix ? 'silent' : e.interaction,
        ...(Object.keys(verify).length ? { verify } : {}),
        validation: { status: 'verified', checkedAt: CHECKED, method: `winget show --id ${e.packageIdentifier} --exact --source msstore (${CHECKED}): ${s.name}, publisher ${s.publisher}, installer type ${s.installerType}${s.offline ? ', offline distribution supported' : ''}`.slice(0, 400) },
      };
      Object.assign(rec, { verification: next.verify ?? null, problems, decision: d?.decision ?? 'keep', reason: d?.reason ?? (msix ? 'Resolves in the msstore source; Store package, unattended, registered per user.' : `Resolves in the msstore source; ${s.installerType} installer: kept "mayPrompt" (Store-hosted Win32 installer, no switches shown).`) });
      records.push(rec);
      entries.push(ordered(next));
      continue;
    }
    // WinGet (and WinGet portable) entries.
    const p = byId.get(e.packageIdentifier!.toLowerCase());
    if (!p || !p.exists) {
      Object.assign(rec, { status: 'missing', manifest: null, problems: [...problems, p ? p.problem : 'not looked up'], decision: 'remove', reason: 'package not found' });
      records.push(rec);
      continue;
    }
    const f = deriveFacts(p);
    if (!f.silent) problems.push('no evidence of an unattended installation (plain exe without Silent switch or silent InstallModes)');
    if (!f.urlsVersioned) problems.push('an InstallerUrl does not contain the version: its published hash goes stale when the publisher replaces the file (WDB retries after a source refresh, never ignores the hash)');
    if (f.manifestCommitDate && f.manifestCommitDate < '2024-11-27') problems.push(`newest manifest committed ${f.manifestCommitDate} (over two years old)`);
    if (f.installerUrls.some((u) => u.startsWith('http://'))) problems.push('an InstallerUrl uses http:// (integrity rests on the manifest hash)');
    const portable = method === 'portable';
    const scope = portable ? 'machine' : f.scope !== 'unknown' ? f.scope : (e.scope as string);
    const scopeEvidence = portable ? 'portable method: WDB installs it with --scope machine' : f.scope !== 'unknown' ? f.scopeEvidence : 'not stated in the manifest (catalog value kept)';
    const verify: Record<string, unknown> = {};
    const detect = new Set((e.detectNames ?? []).map((x) => x.toLowerCase()));
    const uninstall = uniq([...(((d?.verify?.uninstall as string[]) ?? [])), ...f.uninstallPrefixes]).filter((x) => !detect.has(x.toLowerCase()));
    if (uninstall.length) verify.uninstall = uninstall;
    if (f.appxNames.length) verify.appx = f.appxNames;
    const files = uniq([...((d?.verify?.files as string[]) ?? []), ...f.files]);
    if (files.length) verify.files = files;
    if (VC[e.id]?.registry) verify.registry = VC[e.id]!.registry;
    if (scope === 'user') verify.perUser = true;
    const status = f.silent ? 'verified' : 'unverified';
    const decision = d?.decision ?? 'keep';
    const archs = f.archMapped.length ? f.archMapped : (e.architectures as string[]);
    const changed: string[] = [];
    if (typeLabel(f.installerTypes) !== e.installerType) changed.push(`installerType "${e.installerType}" -> "${typeLabel(f.installerTypes)}"`);
    if (JSON.stringify([...archs].sort()) !== JSON.stringify([...(e.architectures as string[])].sort())) changed.push(`architectures [${(e.architectures as string[]).join(', ')}] -> [${archs.join(', ')}]`);
    if (scope !== e.scope) changed.push(`scope ${e.scope as string} -> ${scope}`);
    Object.assign(rec, {
      status,
      manifest: {
        path: f.manifestPath, latestVersion: f.latestVersion, versionFolders: f.versionFolders, committed: f.manifestCommitDate, releaseDate: f.releaseDate,
        packageName: f.packageName, publisher: f.publisher, license: f.license, installerTypes: f.installerTypes, scopes: f.scopes, architectures: f.architectures,
        installModes: f.installModes, installerSwitches: f.installerSwitches, elevation: f.elevation, appsAndFeaturesEntries: f.appsAndFeaturesEntries, productCodes: f.productCodes,
        packageFamilyNames: f.packageFamilyNames, commands: f.commands, defaultInstallLocations: f.defaultInstallLocations, installerHosts: uniq(f.installerUrls.map((u) => { try { return new URL(u).host; } catch { return 'invalid'; } })),
        urlsVersioned: f.urlsVersioned, requireExplicitUpgrade: f.requireExplicitUpgrade, dependencies: f.dependencies, agreements: f.agreements, rebootEvidence: f.rebootEvidence,
      },
      silent: f.silent,
      silentEvidence: f.silentEvidence,
      scope,
      scopeEvidence,
      verification: Object.keys(verify).length ? verify : null,
      verificationEvidence: [
        ...(f.uninstallPrefixes.length ? [`uninstall: AppsAndFeaturesEntries DisplayName ${f.appsAndFeaturesEntries.map((a) => a.displayName).filter(Boolean).map((n) => `"${n}"`).join(', ')} (version stripped)`] : []),
        ...(f.appxNames.length ? [`appx: PackageFamilyName ${f.packageFamilyNames.join(', ')}`] : []),
        ...(VC[e.id]?.registry ? ['registry: Microsoft\'s documented v14 runtime key (Installed = 1)'] : []),
        ...(scope === 'user' ? ['perUser: user-scope installer'] : []),
        ...(d?.verify ? ['see reason'] : []),
        ...(!Object.keys(verify).length && !(e.detectNames ?? []).length ? ['WinGet\'s own installation record only (the manifest names no AppsAndFeatures DisplayName, PackageFamilyName or install location)'] : []),
      ],
      changes: changed,
    });
    if (decision === 'remove') {
      excluded.push({ name: e.displayName, packageIdentifier: e.packageIdentifier!, reason: d!.reason.slice(0, 300), removed: { date: CHECKED, formerId: e.id } });
      Object.assign(rec, { problems, decision, reason: d!.reason });
      records.push(rec);
      continue;
    }
    if (decision === 'manual') {
      const rest: Record<string, unknown> = { ...next };
      for (const k of ['verify', 'alternateIds', 'detectNames', 'portable']) delete rest[k];
      // The WinGet id still exists (it is only not unattended): kept as an alternate id, so an earlier
      // WinGet installation is recognised as this application. It is never installed.
      next = { ...rest, ...(d!.patch ?? {}), packageIdentifier: null, source: 'none', method: 'manual', architectures: [], scope: 'unknown', installerType: 'manual', interaction: 'required', upgrade: 'manual', manual: d!.manual, alternateIds: [e.packageIdentifier!], validation: { status: 'manual', checkedAt: CHECKED, method: d!.manual!.reason } };
      Object.assign(rec, { problems, decision, reason: d!.reason });
      records.push(rec);
      entries.push(ordered(next));
      continue;
    }
    const interaction = e.interaction === 'mayPrompt' ? 'mayPrompt' : f.silent ? 'silent' : e.interaction;
    next = {
      ...next,
      ...(VC[e.id] ? { description: VC[e.id]!.description } : {}),
      architectures: archs,
      scope,
      installerType: typeLabel(f.installerTypes),
      license: (f.license || (e.license as string)).slice(0, 120),
      interaction,
      reboot: f.rebootEvidence.length ? 'mayRequire' : e.reboot,
      ...(Object.keys(verify).length ? { verify } : {}),
      validation: {
        status: 'verified',
        checkedAt: CHECKED,
        method: `winget-pkgs ${short} ${f.manifestPath} (installer + ${p.localeFile || 'locale'}): ${f.packageName} ${f.latestVersion}, publisher ${f.publisher}; ${typeLabel(f.installerTypes)}; ${f.silentEvidence[0] ?? 'no silent evidence'}; scope ${scope}`.slice(0, 400),
      },
      ...(d?.patch ?? {}),
    };
    if (d?.patch?.source === 'msstore') {
      const sid = String(d.patch.packageIdentifier);
      const s = store(sid);
      if (!s.resolves || s.installerType !== 'msstore') throw new Error(`${e.id}: Store replacement ${sid} does not resolve as a Store package`);
      const rest: Record<string, unknown> = { ...next };
      delete rest.verify;
      next = { ...rest, scope: 'user', interaction: 'silent', reboot: 'unknown', verify: { perUser: true }, validation: { status: 'verified', checkedAt: CHECKED, method: `winget show --id ${sid} --exact --source msstore (${CHECKED}): ${s.name}, publisher ${s.publisher} (${s.publisherUrl}), installer type ${s.installerType}; replaces the WinGet package ${e.packageIdentifier} (${d.problems?.[0] ?? ''})`.slice(0, 400) } };
      Object.assign(rec, { store: s, newPackageIdentifier: sid, newSource: 'msstore', scope: 'user', scopeEvidence: 'Microsoft Store packages are registered per user', verification: { perUser: true } });
    }
    Object.assign(rec, { problems, decision: decision === 'keep' && changed.length ? 'repair' : decision, reason: d?.reason ?? (changed.length ? `Manifest facts corrected: ${changed.join('; ')}.` : 'Manifest confirms the entry.') + (interaction === 'mayPrompt' ? ' Interaction stays "mayPrompt" (earlier review: installer offers, bundled components or first-run questions).' : '') });
    records.push(rec);
    entries.push(ordered(next));
  }
  return { base, facts, records, entries, excluded };
}

const [cmd, ...extra] = process.argv.slice(2).filter((a) => !a.endsWith('.ts'));
if (cmd === 'audit') {
  const { base, facts, records, entries, excluded } = buildAudit();
  const count = (k: string) => Object.fromEntries(uniq(records.map((r) => String(r[k]))).sort().map((v) => [v, records.filter((r) => String(r[k]) === v).length]));
  const auto = (list: Record<string, unknown>[]) => list.filter((e) => !['manual', 'vendor'].includes(String(e.method ?? (e.source === 'none' ? 'manual' : e.source)))).length;
  const audit = {
    format: 'windows-deployment-builder/catalog-audit',
    version: 1,
    checkedAt: CHECKED,
    repository: REPO,
    commit: facts.commit,
    commitDate: facts.commitDate,
    baseCatalog: `${BASE}:src/data/apps/catalog.json`,
    policy: 'An entry stays automated (WinGet, Store or portable) only if its package resolves, installs unattended and can be verified; otherwise it becomes a manual follow-up (official https URL) or is removed (excluded, with a removal record). silent = InstallModes lists silent, or an installer type WinGet runs silently (msi, wix, msix, appx, burn, inno, nullsoft, portable, zip with such a nested type), or an exe with an explicit Silent switch.',
    lookups: EXTRA_IDS.map((id) => { const p = byIdOf(facts, id); return { id, exists: !!p?.exists, note: p && !p.exists ? p.problem : p ? `${(p as { path: string }).path} ${(p as { latestVersion: string }).latestVersion}` : 'not looked up' }; }),
    counts: {
      before: { entries: base.entries.length, automated: auto(base.entries), manual: base.entries.length - auto(base.entries), excluded: base.excluded.length },
      after: { entries: entries.length, automated: auto(entries), manual: entries.length - auto(entries), excluded: excluded.length },
      status: count('status'),
      decision: count('decision'),
    },
    entries: records,
  };
  writeFileSync(join(ROOT, 'docs/unified-app-catalog/catalog-audit.json'), JSON.stringify(audit, null, 1) + '\n');
  console.error(JSON.stringify(audit.counts));
} else if (cmd === 'apply') {
  const { base, entries, excluded } = buildAudit();
  const out = {
    ...base,
    $comment: `Generated by scripts/catalog-source.mjs from the read-only verifications of 2026-10-21, 2026-10-25 and 2026-11-26, then corrected by the catalog audit of ${CHECKED} (scripts/audit-catalog.ts, docs/unified-app-catalog/catalog-audit.md) from the WinGet community manifests and the Microsoft Store. Listing an app here neither selects nor installs it.`,
    updated: CHECKED,
    entries,
    excluded,
  };
  writeFileSync(join(ROOT, 'src/data/apps/catalog.json'), JSON.stringify(out, null, 2) + '\n');
  console.error(`catalog: ${entries.length} entries, ${excluded.length} excluded`);
} else if (cmd === 'derive') {
  const facts = JSON.parse(readFileSync(join(CACHE, 'facts.json'), 'utf8')) as { packages: ManifestFacts[] };
  const out = facts.packages.map((p) => (p.exists ? { id: p.id, ...deriveFacts(p) } : p));
  writeFileSync(join(CACHE, 'derived.json'), JSON.stringify(out, null, 1));
  console.error(`derived ${out.length}`);
} else if (cmd === 'fetch' || cmd === 'facts') {
  const head = await headSha();
  const ids = [...new Set([...catalogIds(), ...EXTRA_IDS, ...extra])];
  const facts = await pool(ids, 6, async (id) => {
    try {
      const r = await readPackage(head.sha, id);
      if (cmd === 'fetch') process.stderr.write(`${r.exists ? 'ok ' : 'NO '} ${id}\n`);
      return r;
    } catch (e) {
      return { id, exists: false as const, problem: `error: ${(e as Error).message}` };
    }
  });
  const out = { repository: REPO, commit: head.sha, commitDate: head.date, packages: facts };
  if (cmd === 'facts') process.stdout.write(JSON.stringify(out));
  else {
    writeFileSync(join(CACHE, 'facts.json'), JSON.stringify(out));
    console.error(`${facts.filter((f) => f.exists).length} of ${facts.length} found at ${head.sha}`);
  }
} else {
  console.error('usage: vite-node scripts/audit-catalog.ts fetch|facts [extra.Id ...]');
  process.exitCode = 2;
}
