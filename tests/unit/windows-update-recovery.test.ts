import { createHash } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { embedded, generateOk, profile } from './helpers';
import { PACKAGE_DIR, buildDeploymentPackage } from '../../src/engine/deployment';
import { readZip } from '../../src/engine/deployment/zip';
import { ENGINE_SOURCE, ENGINE_VERSION, RECOVERY_KIT_DIR, RECOVERY_KIT_FILE, RETRY_SOURCE } from '../../src/engine/windows-update';
import { buildRecoveryKit, recoveryKitReadme } from '../../src/engine/windows-update/recovery-kit';

/**
 * Windows Update engine 2.0.0 in what the website hands out: the deployment package (and its answer
 * file) and the standalone recovery download. The spare-computer recovery used exactly these
 * engine and retry sources.
 */

const dec = new TextDecoder();
const nodeSha = (b: Uint8Array) => createHash('sha256').update(b).digest('hex').toUpperCase();
const crlf = (s: string) => s.replace(/\r?\n/g, '\r\n');
const BOM = [0xef, 0xbb, 0xbf];
const stripBom = (b: Uint8Array) => (b[0] === BOM[0] && b[1] === BOM[1] && b[2] === BOM[2] ? b.subarray(3) : b);

describe('engine 2.0.0 sources', () => {
  it('is version 2.1.0 with the 2.0.0 collection fix (no bare collection return)', () => {
    expect(ENGINE_VERSION).toBe('2.1.0');
    expect(ENGINE_SOURCE).toContain("$script:EngineVersion = '2.1.0'");
    expect(ENGINE_SOURCE).toContain('return , $coll');
    expect(ENGINE_SOURCE).toContain('function Assert-WduCollection');
  });
});

describe('the generated deployment package', () => {
  const p = profile();
  const r = generateOk(p);
  const pkg = buildDeploymentPackage(p, r);
  const files = new Map(readZip(pkg.zip).map((e) => [e.path, e.data]));
  const text = (path: string) => dec.decode(stripBom(files.get(path)!));

  it('ships engine 2.0.0 and Retry Windows Update, byte for byte the tested sources', () => {
    expect(text(`${PACKAGE_DIR}/scripts/windows-update/WindowsUpdateEngine.ps1`)).toBe(crlf(ENGINE_SOURCE));
    expect(text(`${PACKAGE_DIR}/scripts/windows-update/Invoke-WindowsUpdateRetry.ps1`)).toBe(crlf(RETRY_SOURCE));
    expect(pkg.manifest.files.map((f) => f.path)).toEqual(expect.arrayContaining(['scripts/windows-update/WindowsUpdateEngine.ps1', 'scripts/windows-update/Invoke-WindowsUpdateRetry.ps1']));
  });

  it('the recovery tool offers Retry Windows Update (menu U) and the report reads the 2.0.0 fields', () => {
    const recovery = text(`${PACKAGE_DIR}/scripts/recovery/DeploymentRecovery.ps1`);
    expect(recovery).toContain('RetryWindowsUpdate');
    expect(recovery).toContain("$ErrorActionPreference = 'Continue'");
    const complete = text(`${PACKAGE_DIR}/scripts/finalization/Complete-Deployment.ps1`);
    for (const k of ['engineVersion', 'engineExceptions', 'failedByCategory', 'verification', 'technicianAction']) expect(complete).toContain(k);
    expect(complete).not.toContain('PostInstall');
  });

  it('the answer file embeds the same engine 2.0.0 and the retry tool', () => {
    const emb = embedded(r.root);
    expect(emb.get('WindowsUpdateEngine.ps1')).toContain("$script:EngineVersion = '2.1.0'");
    expect(emb.has('Invoke-WindowsUpdateRetry.ps1')).toBe(true);
  });
});

describe('the standalone recovery download', () => {
  const entries = readZip(buildRecoveryKit());
  const byName = new Map(entries.map((e) => [e.path, e.data]));

  it(`${RECOVERY_KIT_FILE}: exactly the engine, the retry tool, the health audit with what it loads, README.txt and files.json under ${RECOVERY_KIT_DIR}/`, () => {
    expect(entries.map((e) => e.path).sort()).toEqual(
      ['files.json', 'Invoke-WindowsUpdateRetry.ps1', 'README.txt', 'WindowsUpdateEngine.ps1', 'health/DeploymentHealth.ps1', 'health/HealthReport.html', 'common/DeploymentCommon.ps1']
        .map((f) => `${RECOVERY_KIT_DIR}/${f}`)
        .sort(),
    );
  });

  it('the health audit is the one the deployment package ships, laid out as it expects (health/ beside common/)', () => {
    const p = profile();
    const pkg = readZip(buildDeploymentPackage(p, generateOk(p)).zip);
    const fromPkg = (rel: string) => stripBom(pkg.find((e) => e.path === `${PACKAGE_DIR}/scripts/${rel}`)!.data);
    for (const rel of ['health/DeploymentHealth.ps1', 'health/HealthReport.html', 'common/DeploymentCommon.ps1']) {
      expect(dec.decode(stripBom(byName.get(`${RECOVERY_KIT_DIR}/${rel}`)!)), rel).toBe(dec.decode(fromPkg(rel)));
    }
  });

  it('the scripts are the tested sources with a UTF-8 BOM and CRLF (Windows PowerShell 5.1)', () => {
    const engine = byName.get(`${RECOVERY_KIT_DIR}/WindowsUpdateEngine.ps1`)!;
    expect([...engine.subarray(0, 3)]).toEqual(BOM);
    expect(dec.decode(stripBom(engine))).toBe(crlf(ENGINE_SOURCE));
    expect(dec.decode(stripBom(byName.get(`${RECOVERY_KIT_DIR}/Invoke-WindowsUpdateRetry.ps1`)!))).toBe(crlf(RETRY_SOURCE));
  });

  it('files.json lists every other file with its SHA-256 and size', () => {
    const manifest = JSON.parse(dec.decode(byName.get(`${RECOVERY_KIT_DIR}/files.json`)!)) as { windowsUpdateEngine: string; files: { path: string; sha256: string; bytes: number }[] };
    expect(manifest.windowsUpdateEngine).toBe('2.1.0');
    expect(manifest.files).toHaveLength(6);
    for (const f of manifest.files) {
      const data = byName.get(`${RECOVERY_KIT_DIR}/${f.path}`)!;
      expect(f.sha256).toBe(nodeSha(data));
      expect(f.bytes).toBe(data.length);
    }
  });

  it('the README gives the tested order of commands and never claims more than was tested', () => {
    const readme = recoveryKitReadme();
    const order = ['-Mode ExportDiagnostics', '-Mode Status', '-Mode Scan', '-Mode RetryUpdates -Wait', '-Mode RetryDrivers -Wait', '-Mode HealthAudit'].map((m) => readme.indexOf(m));
    expect(order.every((i) => i >= 0)).toBe(true);
    expect([...order].sort((a, b) => a - b)).toEqual(order);
    expect(readme).toContain('0x80131508');
    expect(readme).not.toMatch(/\r(?!\n)/);
    expect(readme.toLowerCase()).not.toContain(['c:', 'users'].join(String.fromCharCode(92)));
  });
});
