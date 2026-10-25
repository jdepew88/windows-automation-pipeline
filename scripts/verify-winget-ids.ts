/**
 * Phase 10: verifies WinGet package identifiers against the WinGet community repository
 * (github.com/microsoft/winget-pkgs, the source the default "winget" source is built from) without
 * running winget on this computer: no source update, no agreement, nothing installed.
 *
 * For each identifier it finds the package folder (exact case first, then a case-insensitive match
 * that is reported), the newest version that has an installer manifest, and reads the facts the
 * application manager relies on: package name, publisher, licence, description, homepage,
 * installer types, scopes, architectures, installer hosts, whether every installer has a SHA-256,
 * elevation, dependencies, agreements and the Apps & Features names used for detection.
 *
 * Usage: vite-node scripts/verify-winget-ids.ts <out.json> <id> [<id> ...]
 * Needs a GitHub token in GITHUB_TOKEN or the GitHub CLI (`gh auth token`). Read-only.
 */
import { execSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';

const REPO = 'microsoft/winget-pkgs';
const token = process.env.GITHUB_TOKEN || execSync('gh auth token', { encoding: 'utf8' }).trim();
const headers = { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json', 'User-Agent': 'windows-deployment-builder-verify' };

async function api(path: string): Promise<{ status: number; body: unknown }> {
  for (let i = 0; i < 4; i++) {
    const r = await fetch(`https://api.github.com/${path}`, { headers });
    if (r.status === 403 || r.status === 429) {
      await new Promise((ok) => setTimeout(ok, 5000 * (i + 1)));
      continue;
    }
    return { status: r.status, body: r.status === 200 ? await r.json() : null };
  }
  throw new Error(`GitHub API refused ${path} repeatedly (rate limit)`);
}

async function raw(sha: string, path: string): Promise<string | null> {
  const url = `https://raw.githubusercontent.com/${REPO}/${sha}/${path.split('/').map(encodeURIComponent).join('/')}`;
  const r = await fetch(url, { headers: { 'User-Agent': headers['User-Agent'] } });
  return r.status === 200 ? r.text() : null;
}

type Entry = { name: string; type: string };
const list = async (path: string, sha: string) => {
  const r = await api(`repos/${REPO}/contents/${path.split('/').map(encodeURIComponent).join('/')}?ref=${sha}`);
  return r.status === 200 ? (r.body as Entry[]) : null;
};

/** Version folders sort by numeric parts, newest first. */
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

/** Scalar values of top-level or list-item keys (a deliberately small YAML subset: manifests are flat). */
function scalars(yaml: string, key: string): string[] {
  const out: string[] = [];
  const re = new RegExp(`^\\s*-?\\s*${key}:\\s*(.+?)\\s*$`, 'gm');
  for (const m of yaml.matchAll(re)) {
    let v = m[1]!.replace(/\s+#.*$/, '');
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
    if (v && v !== '|' && v !== '>-' && v !== '>') out.push(v);
  }
  return out;
}

async function verify(id: string, sha: string) {
  const segments = id.split('.');
  const base = `manifests/${id[0]!.toLowerCase()}`;
  // Resolve the folder segment by segment, so a case difference is found and reported.
  let path = base;
  const canonical: string[] = [];
  for (const seg of segments) {
    const entries = await list(path, sha);
    if (!entries) return { id, found: false, reason: `folder ${path} not found` };
    const exact = entries.find((e) => e.type === 'dir' && e.name === seg);
    const loose = exact ?? entries.find((e) => e.type === 'dir' && e.name.toLowerCase() === seg.toLowerCase());
    if (!loose) return { id, found: false, reason: `no package folder ${path}/${seg}` };
    canonical.push(loose.name);
    path = `${path}/${loose.name}`;
  }
  const canonicalId = canonical.join('.');
  const entries = (await list(path, sha)) ?? [];
  // Version folders start with a digit; other folders are sub-packages (Mozilla.Firefox.de, ….Insiders).
  const dirs = entries.filter((e) => e.type === 'dir').map((e) => e.name);
  const numeric = dirs.filter((n) => /^\d/.test(n)).sort(compareVersions).reverse();
  const candidates = [...numeric, ...dirs.filter((n) => !/^\d/.test(n)).sort(compareVersions).reverse()];
  for (const v of candidates.slice(0, 8)) {
    const inst = await raw(sha, `${path}/${v}/${canonicalId}.installer.yaml`);
    if (!inst) continue; // a sub-package folder (Microsoft.VisualStudioCode.Insiders), not a version
    const files = (await list(`${path}/${v}`, sha)) ?? [];
    const localeFile = files.find((f) => f.name.startsWith(`${canonicalId}.locale.`) && f.name.endsWith('.yaml') && f.name.includes('en-US')) ?? files.find((f) => f.name.startsWith(`${canonicalId}.locale.`));
    const locale = localeFile ? ((await raw(sha, `${path}/${v}/${localeFile.name}`)) ?? '') : '';
    const urls = scalars(inst, 'InstallerUrl');
    const shas = scalars(inst, 'InstallerSha256');
    const hosts = [...new Set(urls.map((u) => { try { return new URL(u).host.toLowerCase(); } catch { return 'invalid'; } }))].sort();
    return {
      id,
      found: true,
      canonicalId,
      caseDiffers: canonicalId !== id,
      path,
      latestVersion: v,
      versions: candidates.length,
      packageName: scalars(locale, 'PackageName')[0] ?? '',
      publisher: scalars(locale, 'Publisher')[0] ?? '',
      license: scalars(locale, 'License')[0] ?? '',
      shortDescription: scalars(locale, 'ShortDescription')[0] ?? '',
      packageUrl: scalars(locale, 'PackageUrl')[0] ?? scalars(locale, 'PublisherUrl')[0] ?? '',
      agreements: /^\s*Agreements:/m.test(locale) || /^\s*Agreements:/m.test(inst),
      installerTypes: [...new Set([...scalars(inst, 'InstallerType'), ...scalars(inst, 'NestedInstallerType')])].sort(),
      scopes: [...new Set(scalars(inst, 'Scope'))].sort(),
      architectures: [...new Set(scalars(inst, 'Architecture'))].sort(),
      elevation: [...new Set(scalars(inst, 'ElevationRequirement'))].sort(),
      installerHosts: hosts,
      installers: urls.length,
      allHashed: urls.length > 0 && shas.length >= urls.length,
      dependencies: [...new Set(scalars(inst, 'PackageIdentifier').filter((x) => x.toLowerCase() !== canonicalId.toLowerCase()))].sort(),
      appsAndFeaturesNames: [...new Set(scalars(inst, 'DisplayName'))].sort(),
      upgradeBehavior: [...new Set(scalars(inst, 'UpgradeBehavior'))].sort(),
      requireExplicitUpgrade: /RequireExplicitUpgrade:\s*true/i.test(inst),
      msstoreProductId: /^\s*InstallerType:\s*msstore/m.test(inst),
    };
  }
  return { id, found: false, canonicalId, path, reason: `no version folder with ${canonicalId}.installer.yaml among ${candidates.length} candidate(s)` };
}

const [out, ...ids] = process.argv.slice(2).filter((a) => !a.endsWith('.ts'));
if (!out || !ids.length) throw new Error('usage: vite-node scripts/verify-winget-ids.ts <out.json> <id> [<id> ...]');
const head = (await api(`repos/${REPO}/commits/master`)).body as { sha: string; commit: { committer: { date: string } } };
const results = [];
for (const id of [...new Set(ids)]) {
  try {
    results.push(await verify(id, head.sha));
  } catch (e) {
    results.push({ id, found: false, reason: `error: ${(e as Error).message}` });
  }
  process.stdout.write(`${results.at(-1)!.found ? 'ok ' : 'NO '} ${id}\n`);
}
writeFileSync(out, JSON.stringify({ format: 'windows-deployment-builder/winget-verification', version: 1, repository: REPO, commit: head.sha, commitDate: head.commit.committer.date, checkedUtc: new Date().toISOString(), results }, null, 2) + '\n');
console.log(`${results.filter((r) => r.found).length} of ${results.length} found; commit ${head.sha}`);
