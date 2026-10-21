import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { commandLines, embedded, generateOk, noApps, profile } from './helpers';
import { generate } from '../../src/engine/pipeline';
import { ownerDefaults } from '../../src/engine/profiles';
import {
  DEPLOY_STAGING_DIR,
  INITIALIZE_SCRIPT,
  MANIFEST_FILE,
  PACKAGE_DIR,
  buildDeploymentPackage,
  buildManifest,
  deploymentActive,
  encodeFile,
  packageFiles,
  textHash,
} from '../../src/engine/deployment';
import { sha256 } from '../../src/engine/deployment/sha256';
import { createZip, crc32, isSafeZipPath, readZip } from '../../src/engine/deployment/zip';
import { orchestrationAsset } from '../../src/engine/orchestration';
import type { Profile } from '../../src/engine/schema/profile';

const nodeSha = (b: Uint8Array | string) => createHash('sha256').update(b).digest('hex').toUpperCase();
const dec = new TextDecoder();

// Exactly Git + Whiteboard (no Core Essentials), as in Phase 4.
const withApps = (mutate?: (p: Profile) => void) =>
  profile((p) => {
    noApps(p);
    p.applications.selection.added.push(
      { packageIdentifier: 'Git.Git', source: 'winget', displayName: 'Git', version: '', scope: '' },
      { packageIdentifier: '9MSPC6MP8FM4', source: 'msstore', displayName: 'Whiteboard', version: '', scope: '' },
    );
    mutate?.(p);
  });

function pkgOf(p: Profile) {
  const r = generateOk(p);
  return { r, pkg: buildDeploymentPackage(p, r) };
}

describe('SHA-256 and ZIP primitives', () => {
  it('SHA-256 matches Node crypto (empty, block boundaries, large, non-ASCII)', () => {
    for (const s of ['', 'abc', 'a'.repeat(55), 'a'.repeat(56), 'a'.repeat(64), 'x'.repeat(100_000), 'Zoë Çédille 日本']) {
      const b = new TextEncoder().encode(s);
      expect(sha256(b), `len ${s.length}`).toBe(nodeSha(b));
    }
  });

  it('CRC-32 matches the standard check value', () => {
    expect(crc32(new TextEncoder().encode('123456789')).toString(16)).toBe('cbf43926');
  });

  it('round-trips entries and refuses unsafe or duplicate paths', () => {
    const entries = [
      { path: 'a.txt', data: new TextEncoder().encode('hello') },
      { path: 'dir/sub/b.bin', data: new Uint8Array([0, 1, 2, 255]) },
    ];
    const back = readZip(createZip(entries));
    expect(back.map((e) => e.path)).toEqual(['a.txt', 'dir/sub/b.bin']);
    expect([...back[1]!.data]).toEqual([0, 1, 2, 255]);
    for (const bad of ['../x', '/abs', 'C:/x', 'a\\b', 'a/../b', 'a//b', './a', 'con:x']) {
      expect(isSafeZipPath(bad), bad).toBe(false);
      expect(() => createZip([{ path: bad, data: new Uint8Array() }])).toThrow();
    }
    expect(() => createZip([...entries, { path: 'A.TXT', data: new Uint8Array() }])).toThrow(/Duplicate/);
  });

  it('detects corruption when reading', () => {
    const z = createZip([{ path: 'a.txt', data: new TextEncoder().encode('hello') }]);
    z[35] = z[35]! ^ 0xff;
    expect(() => readZip(z)).toThrow(/CRC/);
  });
});

describe('deployment package (ZIP)', () => {
  const { r, pkg } = pkgOf(withApps());
  const entries = readZip(pkg.zip);
  const byPath = new Map(entries.map((e) => [e.path, e.data]));
  const manifest = JSON.parse(dec.decode(byPath.get(`${PACKAGE_DIR}/${MANIFEST_FILE}`)!));

  it('has the answer file at the root and everything else under WindowsDeployment/', () => {
    expect(entries[0]!.path).toBe('autounattend.xml');
    expect(dec.decode(byPath.get('autounattend.xml')!)).toBe(r.xml);
    for (const e of entries.slice(1)) expect(e.path.startsWith(`${PACKAGE_DIR}/`), e.path).toBe(true);
    for (const required of ['setup.cmd', 'setup.ps1', 'README.txt', 'deployment-manifest.json', INITIALIZE_SCRIPT, 'scripts/finalization/Complete-Deployment.ps1', 'config/orchestration.json', 'profiles/windows-settings.json', 'profiles/applications.json', 'docs/INSTALLATION.txt']) {
      expect(byPath.has(`${PACKAGE_DIR}/${required}`), required).toBe(true);
    }
    for (const engine of ['windows-update/WindowsUpdateEngine.ps1', 'windows-update/Install-UpdateEngine.ps1', 'windows-update/config.json', 'applications/ApplicationEngine.ps1', 'applications/WinGetBootstrap.ps1', 'applications/Install-ApplicationEngine.ps1', 'applications/applications-config.json', 'applications/winget-packages.json']) {
      expect(byPath.has(`${PACKAGE_DIR}/scripts/${engine}`), engine).toBe(true);
    }
  });

  it('manifest lists exactly the package files, with correct sizes and SHA-256 (checked with Node crypto)', () => {
    const listed = manifest.files.map((f: { path: string }) => `${PACKAGE_DIR}/${f.path}`).sort();
    const inZip = entries.map((e) => e.path).filter((p) => p !== 'autounattend.xml' && p !== `${PACKAGE_DIR}/${MANIFEST_FILE}`).sort();
    expect(listed).toEqual(inZip);
    for (const f of manifest.files) {
      const data = byPath.get(`${PACKAGE_DIR}/${f.path}`)!;
      expect(f.size, f.path).toBe(data.length);
      expect(f.sha256, f.path).toBe(nodeSha(data));
    }
    expect(manifest.packageId).toMatch(/^[0-9A-F]{16}$/);
  });

  it('every launcher in the manifest exists in the package', () => {
    for (const s of manifest.stages.filter((x: { launcher?: string }) => x.launcher)) expect(byPath.has(`${PACKAGE_DIR}/${s.launcher}`), s.launcher).toBe(true);
  });

  it('.ps1 files carry a UTF-8 BOM (Windows PowerShell 5.1), text files use CRLF, setup.cmd is ASCII', () => {
    for (const [path, data] of byPath) {
      if (path.endsWith('.ps1')) expect([...data.slice(0, 3)], path).toEqual([0xef, 0xbb, 0xbf]);
      if (/\.(ps1|txt|cmd|json)$/.test(path)) expect(/(^|[^\r])\n/.test(dec.decode(data)), `${path} has bare LF`).toBe(false);
    }
    expect([...byPath.get(`${PACKAGE_DIR}/setup.cmd`)!].every((b) => b < 0x80)).toBe(true);
  });

  it('is reproducible: the same configuration gives the same bytes', () => {
    expect(nodeSha(pkgOf(withApps()).pkg.zip)).toBe(nodeSha(pkg.zip));
  });

  it('keeps the existing deployment assets byte-identical inside the package (except the .ps1 BOM)', () => {
    for (const a of r.assets) {
      if (a.name === 'application-profile.json') {
        expect(dec.decode(byPath.get(`${PACKAGE_DIR}/profiles/applications.json`)!)).toBe(a.content);
        continue;
      }
      const folder = a.group === 'windows-update' ? 'scripts/windows-update' : a.group === 'applications' ? 'scripts/applications' : 'config';
      const data = byPath.get(`${PACKAGE_DIR}/${folder}/${a.name}`)!;
      expect(data, a.name).toBeDefined();
      expect(dec.decode(a.name.endsWith('.ps1') ? data.slice(3) : data), a.name).toBe(a.content);
    }
  });

  it('the manifest is ASCII-only JSON (safe for the code-page extraction) and carries no secrets or user names', () => {
    const p = withApps((x) => {
      x.accounts.password = 'S3cret!pw';
      x.accounts.autoLogon = 'firstLogonOnly';
      x.wifi.mode = 'parameters';
      x.wifi.ssid = 'Home';
      x.wifi.password = 'wifi-secret-123';
    });
    const { pkg: withSecrets } = pkgOf(p);
    const text = dec.decode(readZip(withSecrets.zip).find((e) => e.path.endsWith(MANIFEST_FILE))!.data);
    expect([...text].every((c) => c.charCodeAt(0) < 0x80)).toBe(true);
    for (const secret of ['S3cret!pw', 'wifi-secret-123', '"Alex"', 'personName', 'username']) expect(text).not.toContain(secret);
    const settings = dec.decode(readZip(withSecrets.zip).find((e) => e.path.endsWith('profiles/windows-settings.json'))!.data);
    expect(settings).not.toContain('S3cret!pw');
    expect(settings).not.toContain('wifi-secret-123');
    expect(withSecrets.warnings.join(' ')).toMatch(/contains the account or Wi-Fi password/);
    expect(withSecrets.manifest.answerFile.containsSecrets).toBe(true);
  });

  it('records stages, contexts, limits and the unimplemented driver stage', () => {
    const ids = manifest.stages.map((s: { id: string }) => s.id);
    expect(ids).toEqual(['staging', 'windowsUpdate', 'applications', 'drivers', 'finalization']);
    const st = Object.fromEntries(manifest.stages.map((s: { id: string }) => [s.id, s]));
    expect(st.windowsUpdate).toMatchObject({ enabled: true, context: 'SYSTEM', finalStatuses: ['Succeeded', 'CompletedWithFailures', 'Failed', 'Offline'] });
    expect(st.applications).toMatchObject({ enabled: true, context: 'user', waitsFor: ['windowsUpdate'] });
    expect(st.drivers).toMatchObject({ enabled: false, implemented: false, status: 'NotImplemented' });
    const d = withApps();
    expect(manifest.failureHandling.windowsUpdate.maxAttemptsPerUpdate).toBe(d.windowsUpdate.maxAttemptsPerUpdate);
    expect(manifest.restartPolicy.windowsUpdate.maxReboots).toBe(d.windowsUpdate.maxReboots);
    expect(manifest.failureHandling.orchestrator.deadlineHours).toBe(d.windowsUpdate.maxRuntimeHours + d.applications.waitForUpdatesHours + d.applications.maxRuntimeHours + 24);
    expect(manifest.windows.computerName).toBe('Alex-Computer');
    expect(manifest.windows.diskSelection).toBe('interactive');
  });
});

describe('customer application selections', () => {
  it('contains exactly the effective selection after composition, additions, removals and de-duplication', () => {
    const ref = (packageIdentifier: string, displayName: string) => ({ packageIdentifier, source: 'winget', displayName, version: '', scope: '' as const });
    const p = profile((x) => {
      noApps(x);
      const sel = x.applications.selection;
      sel.profiles.push({ id: 'home', name: 'Home', category: 'custom', description: '', builtin: false, inherits: [], packages: [ref('Mozilla.Firefox', 'Firefox'), ref('7zip.7zip', '7-Zip')] });
      sel.profiles.push({ id: 'extra', name: 'Extra', category: 'custom', description: '', builtin: false, inherits: [], packages: [ref('Valve.Steam', 'Steam'), ref('7ZIP.7ZIP', '7-Zip')] });
      sel.selectedProfiles = ['home', 'gaming', 'extra'];
      sel.added.push(ref('Adobe.Acrobat.Reader.64-bit', 'Acrobat Reader'));
      sel.removed.push('winget:epicgames.epicgameslauncher');
    });
    const { pkg } = pkgOf(p);
    expect(pkg.manifest.applications.packages.map((x) => x.packageIdentifier)).toEqual(['Mozilla.Firefox', '7zip.7zip', 'Valve.Steam', 'Adobe.Acrobat.Reader.64-bit']);
    const native = JSON.parse(dec.decode(readZip(pkg.zip).find((e) => e.path.endsWith('winget-packages.json'))!.data));
    expect(native.Sources[0].Packages.map((x: { PackageIdentifier: string }) => x.PackageIdentifier)).toEqual(['Mozilla.Firefox', '7zip.7zip', 'Valve.Steam', 'Adobe.Acrobat.Reader.64-bit']);
    expect(pkg.manifest.applications.removedFromProfiles).toEqual(['winget:epicgames.epicgameslauncher']);
    expect(pkg.manifest.applications.selectedProfiles).toEqual(['Home', 'Gaming', 'Extra']);
    expect(pkg.manifest.applications.packages.find((x) => x.packageIdentifier === 'Valve.Steam')!.origins).toEqual(['gaming', 'extra']);
  });

  it('does not change the owner defaults', () => {
    const before = JSON.stringify(ownerDefaults());
    pkgOf(withApps((x) => x.applications.selection.added.push({ packageIdentifier: 'Mozilla.Firefox', source: 'winget', displayName: 'Firefox', version: '', scope: '' })));
    expect(JSON.stringify(ownerDefaults())).toBe(before);
  });

  it('keeps unresolved packages marked for attention and never installable', () => {
    const p = withApps((x) => x.applications.selection.added.push({ packageIdentifier: 'Some.Tool', source: 'mycorp', displayName: 'Corp tool', version: '', scope: '' }));
    const { pkg } = pkgOf(p);
    const corp = pkg.manifest.applications.packages.find((x) => x.packageIdentifier === 'Some.Tool')!;
    expect(corp).toMatchObject({ resolution: 'unresolved', requiresAttention: true });
    const native = dec.decode(readZip(pkg.zip).find((e) => e.path.endsWith('winget-packages.json'))!.data);
    expect(native).not.toContain('Some.Tool');
    expect(pkg.warnings.join(' ')).toMatch(/unresolved/);
  });
});

describe('answer file integration (Phase 4 changes)', () => {
  const r = generateOk(withApps());
  const files = embedded(r.root);
  const { manifest, runtimeJson } = buildManifest(withApps());

  it('embeds the orchestrator and the manifest; the text hashes match what extraction writes', () => {
    expect(files.get(MANIFEST_FILE)).toBe(runtimeJson.replace(/\r\n/g, '\n').trim());
    const runtime = JSON.parse(runtimeJson);
    expect(runtime.scope).toBe('answerFile');
    expect(runtime.packageId).toBe(manifest.packageId);
    expect(runtime.files.map((f: { path: string }) => f.path)).toEqual(manifest.files.filter((f) => f.embedded).map((f) => f.path));
    for (const f of manifest.files.filter((x) => x.embedded)) {
      const content = files.get(f.embedded!.split('\\').pop()!)!;
      expect(content, f.path).toBeDefined();
      if (f.textSha256) expect(textHash(content), f.path).toBe(f.textSha256);
    }
    expect(r.embeddedFiles.map((f) => f.path)).toContain(`${DEPLOY_STAGING_DIR}\\scripts\\bootstrap\\Initialize-Deployment.ps1`);
  });

  it('FirstLogon: the M1 script, then only the orchestrator; no direct engine installer commands', () => {
    const fl = commandLines(r.root).firstLogon;
    expect(fl).toHaveLength(2);
    expect(fl[0]).toContain('FirstLogon.ps1');
    expect(fl[1]).toBe(`powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "${DEPLOY_STAGING_DIR}\\scripts\\bootstrap\\Initialize-Deployment.ps1"`);
  });

  it('still contains no disk automation and keeps the bypass settings unchanged', () => {
    expect(r.xml).not.toMatch(/DiskConfiguration|WillWipeDisk|diskpart/i);
    expect(r.xml).not.toContain('LabConfig');
    const bypass = generateOk(withApps((x) => (x.setup.bypassRequirementsCheck = true)));
    for (const v of ['BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck']) expect(bypass.xml).toContain(v);
  });

  it('with both engines off nothing is added (Milestone 1 answer file unchanged)', () => {
    const p = profile((x) => {
      x.windowsUpdate.enabled = false;
      noApps(x);
    });
    expect(deploymentActive(p)).toBe(false);
    const off = generateOk(p);
    expect(off.embeddedFiles.some((f) => f.path.includes('\\Deployment\\'))).toBe(false);
    expect(commandLines(off.root).firstLogon.join('\n')).not.toContain('Initialize-Deployment');
    // The package is still offered, with a warning that nothing runs after installation.
    expect(buildDeploymentPackage(p, off).warnings.join(' ')).toMatch(/nothing runs after installation/);
  });

  it('orchestration.json in the package is the existing contract, byte for byte', () => {
    expect(packageFiles(withApps()).find((f) => f.path === 'config/orchestration.json')!.content).toBe(orchestrationAsset(withApps()).content);
  });

  it('refuses to build a package for an invalid configuration', () => {
    const bad = generate(profile(undefined, ''));
    expect(bad.ok).toBe(false);
    expect(() => buildDeploymentPackage(profile(undefined, ''), bad)).toThrow();
  });

  it('encodes .ps1 files with a BOM and leaves other files unchanged', () => {
    expect([...encodeFile('a.ps1', 'x')]).toEqual([0xef, 0xbb, 0xbf, 0x78]);
    expect([...encodeFile('a.json', 'x')]).toEqual([0x78]);
  });

  it('package file names are unique and safe', () => {
    const paths = packageFiles(withApps()).map((f) => f.path);
    expect(new Set(paths.map((x) => x.toLowerCase())).size).toBe(paths.length);
    for (const x of paths) expect(isSafeZipPath(`${PACKAGE_DIR}/${x}`), x).toBe(true);
  });

  it('docs in the package explain disk selection, Rufus and the USB root', () => {
    const install = packageFiles(withApps()).find((f) => f.path === 'docs/INSTALLATION.txt')!.content;
    expect(install).toMatch(/SELECT THE DISK YOURSELF/);
    expect(install).toMatch(/Rufus/);
    expect(install).toMatch(/ROOT of the USB drive/);
    expect(readFileSync(new URL('../../src/engine/deployment/scripts/setup.ps1', import.meta.url), 'utf8')).toMatch(/refuses to run in Windows PE/);
  });
});

describe('answer-file stability', () => {
  it('changes that do not affect the installed computer do not change the answer file', () => {
    const base = generateOk(withApps()).xml;
    const blankScript = generateOk(withApps((p) => p.scripts.firstLogon.push({ id: 'x', name: '', type: 'ps1', enabled: true, content: '   ' }))).xml;
    const renamed = generateOk(withApps((p) => (p.profileName = 'Another name'))).xml;
    expect(blankScript).toBe(base);
    expect(renamed).toBe(base);
  });
});
