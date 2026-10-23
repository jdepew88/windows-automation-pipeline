import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import driverSource from '../../src/engine/drivers/scripts/DriverEngine.ps1?raw';
import installerSource from '../../src/engine/drivers/scripts/Install-DriverEngine.ps1?raw';
import wuEngineSource from '../../src/engine/windows-update/scripts/WindowsUpdateEngine.ps1?raw';
import appEngineSource from '../../src/engine/applications/scripts/ApplicationEngine.ps1?raw';
import recoverySource from '../../src/engine/deployment/scripts/DeploymentRecovery.ps1?raw';
import {
  DRIVERS_RESULT_JSON_SCHEMA,
  DRIVER_ENGINE_VERSION,
  DRIVER_SOURCE_DATA,
  allowedDownloadUrl,
  driverAssets,
  driverMediaBlock,
  driverToolBundle,
  driversConfig,
  hardwareSummary,
  importDriverBundleManifest,
  importHardwareInventory,
  reviewRows,
  verifiedPackageProblems,
} from '../../src/engine/drivers';
import { DRIVER_HEALTH, DRIVER_OPERATION_STATUSES, DRIVER_PERMANENT_CLASSES, DEVICE_STATES } from '../../src/engine/drivers/contract';
import { buildDeploymentPackage, buildManifest } from '../../src/engine/deployment';
import { readZip } from '../../src/engine/deployment/zip';
import { sha256, utf8 } from '../../src/engine/deployment/sha256';
import { applicationsConfig } from '../../src/engine/applications';
import { orchestrationContract } from '../../src/engine/orchestration';
import { importProfile, ownerDefaults } from '../../src/engine/profiles';
import { SCHEMA_VERSION } from '../../src/engine/schema/profile';
import { reviewSummary } from '../../src/engine/quick';
import { errorsOf, generateOk, profile } from './helpers';
import { FIXTURE_DRIVER_PACKAGES, fixtureInf } from '../powershell/deployment-fixture';

/** Phase 8: hardware-aware driver provisioning (website side, contracts and static safety checks). */

const fixture = (name: string) => readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8');

/** The body of one PowerShell function of the driver engine. */
function fnBody(name: string): string {
  const start = driverSource.indexOf(`function ${name} {`);
  if (start < 0) throw new Error(`no function ${name}`);
  const next = driverSource.indexOf('\nfunction ', start + 10);
  return driverSource.slice(start, next < 0 ? undefined : next);
}
const withoutFn = (names: string[]) => names.reduce((s, n) => s.replace(fnBody(n), ''), driverSource);

/** A bundle manifest in the bundle tool's format (what New-WdvBundle writes). */
function bundleManifest(mutate?: (m: Record<string, unknown> & { packages: Record<string, unknown>[] }) => void): Uint8Array {
  const packages = FIXTURE_DRIVER_PACKAGES.slice(0, 3).map((x, n) => {
    const inf = utf8(fixtureInf(x));
    return {
      id: x.id, folder: `packages/00${n + 1}-${x.base}`, inf: `${x.base}.inf`, class: x.cls, classGuid: '{4d36e968-e325-11ce-bfc1-08002be10318}', provider: x.provider, version: x.version, date: '2026-09-15',
      catalog: `${x.base}.cat`, targets: [{ arch: 'amd64', minBuild: 22000 }], hardwareIds: [...x.ids].sort(), signature: { status: 'Valid', signer: 'Microsoft Windows Hardware Compatibility Publisher', whql: true },
      setupCritical: x.setupCritical, networkDriver: x.cls === 'Net', files: [{ path: `${x.base}.inf`, size: inf.length, sha256: sha256(inf) }, { path: `${x.base}.cat`, size: 4, sha256: 'A'.repeat(64) }], bytes: inf.length + 4,
    };
  });
  const m = {
    format: 'windows-deployment-builder/driver-bundle', formatVersion: 1, bundleId: '0123456789abcdef', folderName: 'WDB-Drivers-20261022-120000-abc123', createdUtc: '2026-10-22T12:00:00Z',
    tool: { name: 'DriverEngine.ps1', version: '1.0.0' }, source: { kind: 'driverStoreExport', manufacturer: 'Contoso', model: 'Workstation 7', osBuild: '26100', architecture: 'amd64' },
    packages, refused: [], totals: { packages: 3, files: 6, bytes: 1 }, notice: 'INF driver packages only.',
  };
  mutate?.(m as never);
  return utf8(JSON.stringify(m));
}

/** A shareable inventory in DriverEngine.ps1 -Mode Inspect's format. */
function inventory(mutate?: (i: Record<string, unknown> & { devices: Record<string, unknown>[] }) => void): string {
  const dev = (key: string, name: string, category: string, state: string, action: string, extra: Record<string, unknown> = {}) => ({
    key, name, category, class: 'Display', vendor: { id: 'nvidia', name: 'NVIDIA', vendorId: '10DE' }, instanceId: 'PCI\\VEN_10DE&DEV_2484\\#1a2b3c4d', hardwareIds: ['PCI\\VEN_10DE&DEV_2484&SUBSYS_146B10DE'],
    compatibleIds: ['PCI\\CC_0300'], problemCode: 0, driver: { provider: 'Microsoft', version: '10.0.26100.1', date: '2006-06-21', inf: 'display.inf', inbox: true }, oemCustomized: false, state, action, confidence: 'high',
    reasons: ['Working, but with Microsoft Basic Display Adapter.'], setupCritical: false, networkCritical: false, ...extra,
  });
  const i = {
    format: 'windows-deployment-builder/hardware-inventory', formatVersion: 1, inventoryId: '00112233445566aa', collectedUtc: '2026-10-21T10:00:00Z', tool: { name: 'DriverEngine.ps1', version: '1.0.0' },
    system: { manufacturer: 'Contoso', model: 'Workstation 7', family: '', boardManufacturer: 'Contoso', boardProduct: 'B760', biosVersion: '1.0', portable: false, virtual: false, architecture: 'amd64', osCaption: 'Microsoft Windows 11 Pro', osBuild: '26200', processors: ['Intel(R) Core(TM) i7-13700'], oem: '' },
    devices: [
      dev('dev-aaaaaaaaaaaa', 'Intel(R) Ethernet Controller I225-V', 'networkWired', 'Healthy', 'Keep', { class: 'Net', vendor: { id: 'intel', name: 'Intel', vendorId: '8086' } }),
      dev('dev-bbbbbbbbbbbb', 'Microsoft Basic Display Adapter', 'display', 'BasicDriver', 'InstallRecommended'),
      dev('dev-cccccccccccc', 'Intel(R) VMD Controller', 'storageRaid', 'Healthy', 'Keep', { class: 'SCSIAdapter', setupCritical: true, driver: { provider: 'Intel Corporation', version: '19.5.0.1037', date: '2025-03-01', inf: 'oem2.inf', inbox: false } }),
    ],
    summary: { devices: 3, healthy: 2, basicDriver: 1 }, setupCritical: ['dev-cccccccccccc'],
    optionalApplications: [{ name: 'NVIDIA App', vendor: 'NVIDIA', purpose: 'Optional.', required: false, installed: 'not by the driver stage (the application profile decides)' }], notice: 'read-only',
  };
  mutate?.(i as never);
  return JSON.stringify(i);
}

describe('driver policy and engine configuration', () => {
  it('new deployments start with safe defaults; the configuration carries the policy, timing and identification data', () => {
    const p = ownerDefaults();
    expect(p.schemaVersion).toBe(SCHEMA_VERSION);
    expect(p.drivers).toMatchObject({ enabled: true, useWindowsUpdate: true, resolveMissing: true, includeOfflinePackages: true, optionalReplacements: 'never', reportUnresolved: true, networkBootstrap: true, bundle: null, verifiedPackages: [], approvals: [] });
    const c = driversConfig(p);
    expect(c).toMatchObject({ schemaVersion: 1, engineVersion: DRIVER_ENGINE_VERSION, taskName: 'Drivers', policy: { optionalReplacements: 'never' }, windowsUpdate: { enabled: true, drivers: 'include' }, bundle: null, approvals: [] });
    expect(c.waitForUpdatesHours).toBe(p.windowsUpdate.maxRuntimeHours + 2);
    expect(c.maxRuntimeHours).toBeGreaterThan(c.waitForUpdatesHours);
    expect(c.sources.downloadHosts.length).toBeGreaterThan(5);
    expect(driverSource).toContain(`$script:WdvVersion = '${DRIVER_ENGINE_VERSION}'`);
  });

  it('approvals reach the engine only with "approved replacements"; the bundle only with offline packages on', () => {
    const p = profile((x) => {
      x.drivers.approvals = [{ packageId: 'pkg-0123456789ab', hardwareId: 'pci\\ven_10de&dev_2484' }];
      x.drivers.includeOfflinePackages = false;
    });
    expect(driversConfig(p).approvals).toEqual([]);
    p.drivers.optionalReplacements = 'approvedOnly';
    expect(driversConfig(p).approvals).toEqual([{ packageId: 'pkg-0123456789ab', hardwareId: 'PCI\\VEN_10DE&DEV_2484' }]);
  });

  it('PowerShell and TypeScript share the operation lifecycle, failure classes, device states and health names', () => {
    const list = (name: string) => (new RegExp(`\\$script:${name} = @\\(([^)]*)\\)`).exec(driverSource)?.[1] ?? '').split(',').map((s) => s.trim().replace(/'/g, ''));
    expect(list('WdvStatuses')).toEqual([...DRIVER_OPERATION_STATUSES]);
    expect(list('WdvPermanentClasses')).toEqual([...DRIVER_PERMANENT_CLASSES]);
    for (const s of DEVICE_STATES) expect(driverSource, s).toContain(`'${s}'`);
    for (const h of DRIVER_HEALTH) expect(driverSource.includes(`'${h}'`) || driverSource.includes(h.charAt(0).toLowerCase() + h.slice(1)), h).toBe(true);
    expect(DRIVERS_RESULT_JSON_SCHEMA.properties.health.properties.status.enum).toEqual([...DRIVER_HEALTH]);
  });
});

describe('profile migration (schema 5)', () => {
  it('older profiles get the driver stage off and keep producing the deployment they did', () => {
    for (const f of ['p43-gaming.profile.json', 'p5-network-engineer.profile.json', 'p4-owner-default.profile.json', 'm1-owner-default.profile.json']) {
      const raw = JSON.parse(fixture(f)) as Record<string, unknown>;
      (raw.accounts as Record<string, unknown>).personName = 'Alex';
      const r = importProfile(JSON.stringify(raw));
      expect(r.errors, f).toEqual([]);
      expect(r.profile!.drivers.enabled, f).toBe(false);
      expect(r.warnings.join(' '), f).toMatch(/Hardware-aware driver provisioning .* turned off for this older profile/);
      const g = generateOk(r.profile!);
      expect(g.embeddedFiles.some((x) => x.path.includes('\\Drivers\\')), f).toBe(false);
      // (The recovery tool mentions the driver engine of a package that has one; nothing is embedded here.)
      expect(g.xml, f).not.toContain('C:\\Windows\\Setup\\Scripts\\Drivers\\');
    }
  });

  it('a v5 export round-trips its driver section', () => {
    const p = ownerDefaults();
    p.accounts.personName = 'Alex';
    p.drivers.maxReboots = 3;
    const r = importProfile(JSON.stringify(p));
    expect(r.errors).toEqual([]);
    expect(r.profile!.drivers).toEqual(p.drivers);
  });
});

describe('deployment package integration', () => {
  it('with the driver stage on: engine embedded, stage launched by the orchestrator, applications wait for it', () => {
    const p = profile();
    const g = generateOk(p);
    const embedded = g.embeddedFiles.map((f) => f.path);
    for (const f of ['DriverEngine.ps1', 'Install-DriverEngine.ps1', 'drivers-config.json']) expect(embedded).toContain(`C:\\Windows\\Setup\\Scripts\\Drivers\\${f}`);
    const { manifest } = buildManifest(p);
    const st = manifest.stages.find((s) => s.id === 'drivers') as Record<string, unknown>;
    expect(st).toMatchObject({ enabled: true, implemented: true, context: 'SYSTEM', launcher: 'scripts/drivers/Install-DriverEngine.ps1', task: { path: '\\WindowsDeploymentBuilder\\', name: 'Drivers' }, waitsFor: ['windowsUpdate'] });
    expect(manifest.drivers).toMatchObject({ implemented: true, enabled: true, policy: { windowsUpdateDrivers: 'include' } });
    expect(manifest.files.some((f) => f.path === 'scripts/drivers/DriverEngine.ps1' && f.embedded === 'Drivers\\DriverEngine.ps1')).toBe(true);
    expect(applicationsConfig(p).coordination.drivers).toMatchObject({ enabled: true, taskName: 'Drivers' });
    expect(orchestrationContract(p).stages.find((s) => s.id === 'applications')!.waitsFor).toEqual(['windowsUpdate', 'drivers']);
    expect(driverAssets(p).map((a) => a.name)).toEqual(['DriverEngine.ps1', 'Install-DriverEngine.ps1', 'drivers-config.json', 'drivers-result.schema.json', 'README-Drivers.txt']);
  });

  it('with the driver stage off: no driver files, no coordination entry, the stage is reported as not part of the deployment', () => {
    const p = profile((x) => (x.drivers.enabled = false));
    const g = generateOk(p);
    expect(g.embeddedFiles.some((f) => f.path.includes('\\Drivers\\'))).toBe(false);
    expect(driverAssets(p)).toEqual([]);
    expect(applicationsConfig(p).coordination).not.toHaveProperty('drivers');
    const { manifest } = buildManifest(p);
    expect(manifest.files.some((f) => f.path.startsWith('scripts/drivers/'))).toBe(false);
    expect(manifest.generator).not.toHaveProperty('driverEngine');
    expect(manifest.stages.find((s) => s.id === 'drivers')).toMatchObject({ enabled: false, status: 'NotPartOfDeployment' });
  });

  it('a pinned bundle is described for the USB assistant (Setup-critical packages to $WinPEDriver$), never packed into the ZIP', () => {
    const ref = importDriverBundleManifest(bundleManifest()).reference!;
    const p = profile((x) => (x.drivers.bundle = ref));
    const g = generateOk(p);
    const pkg = buildDeploymentPackage(p, g);
    const block = driverMediaBlock(p)!;
    expect(block).toEqual({
      bundle: { bundleId: ref.bundleId, folderName: ref.folderName, manifestSha256: ref.manifestSha256, location: `WindowsDeployment/drivers/${ref.folderName}` },
      setupCritical: { packages: ['pkg-0000000000a3'], location: `$WinPEDriver$/${ref.folderName}` },
      required: true,
    });
    expect(pkg.manifest.media.drivers).toEqual(block);
    expect(readZip(pkg.zip).some((e) => /drivers-manifest|\.sys$|\.cat$|\$WinPEDriver/.test(e.path))).toBe(false);
    expect(pkg.warnings.join(' ')).toMatch(/is not part of this ZIP: put it on the USB drive as WindowsDeployment\\drivers\\WDB-Drivers-/);
    expect(driversConfig(p).bundle).toEqual({ bundleId: ref.bundleId, folderName: ref.folderName, manifestSha256: ref.manifestSha256 });
    expect(g.xml).not.toContain('"media"');
  });
});

describe('offline bundle and hardware inventory import', () => {
  it('a bundle manifest is pinned by the SHA-256 of its exact bytes; only the manifest is read', () => {
    const bytes = bundleManifest();
    const r = importDriverBundleManifest(bytes);
    expect(r.errors).toEqual([]);
    expect(r.reference!.manifestSha256).toBe(sha256(bytes));
    expect(r.reference!.packages.map((x) => [x.inf, x.setupCritical, x.whql, x.architectures.join()])).toEqual([
      ['nvdisp.inf', false, true, 'amd64'],
      ['rt25cx21x64.inf', false, true, 'amd64'],
      ['iastorvd.inf', true, true, 'amd64'],
    ]);
  });

  it('refuses unsigned packages, unsafe paths, a missing INF, unknown fields and other formats', () => {
    expect(importDriverBundleManifest(bundleManifest((m) => ((m.packages[0]!.signature as { whql: boolean }).whql = false))).errors.join(' ')).toMatch(/not signed by Microsoft/);
    expect(importDriverBundleManifest(bundleManifest((m) => (m.packages[0]!.folder = 'packages/../../Windows'))).ok).toBe(false);
    expect(importDriverBundleManifest(bundleManifest((m) => (m.packages[0]!.files = []))).errors.join(' ')).toMatch(/is not among the listed files/);
    expect(importDriverBundleManifest(bundleManifest((m) => (m.extra = 1))).ok).toBe(false);
    expect(importDriverBundleManifest(bundleManifest((m) => (m.format = 'windows-deployment-builder/app-backup'))).ok).toBe(false);
    expect(importDriverBundleManifest(utf8('not json')).errors).toEqual(['Not a JSON file.']);
  });

  it('the review table shows the collected devices only, needing attention first, with their identifiers', () => {
    const r = importHardwareInventory(inventory());
    expect(r.errors).toEqual([]);
    const rows = reviewRows(r.inventory!);
    expect(rows.map((x) => [x.device, x.status, x.action])).toEqual([
      ['Microsoft Basic Display Adapter', 'Basic driver', 'Compatible driver recommended'],
      ['Intel(R) Ethernet Controller I225-V', 'Healthy', 'Keep existing'],
      ['Intel(R) VMD Controller', 'Healthy', 'Keep existing'],
    ]);
    expect(rows[0]!.details).toMatchObject({ hardwareIds: ['PCI\\VEN_10DE&DEV_2484&SUBSYS_146B10DE'], inf: 'display.inf', problemCode: 0 });
    expect(hardwareSummary(r.inventory!)).toMatchObject({ manufacturer: 'Contoso', model: 'Workstation 7', devices: 3, needingAction: 1, setupCritical: 1 });
    expect(importHardwareInventory(inventory((i) => (i.serialNumber = 'X'))).ok).toBe(false);
    expect(importHardwareInventory(inventory((i) => (i.devices[0]!.state = 'Fine'))).ok).toBe(false);
  });
});

describe('validation', () => {
  it('verified packages: official HTTPS host, INF archives only, a real SHA-256 and hardware IDs', () => {
    expect(allowedDownloadUrl('https://download.microsoft.com/x/driver.cab')).toBe(true);
    for (const bad of ['http://download.microsoft.com/x.cab', 'https://example.com/x.cab', 'https://u:p@dl.dell.com/x.cab', 'https://dl.dell.com:444/x.cab', 'not a url']) expect(allowedDownloadUrl(bad), bad).toBe(false);
    const v = { id: 'nic', name: 'NIC', vendor: 'Contoso', url: 'https://downloadmirror.intel.com/1/driver.exe', sha256: 'A'.repeat(64), format: 'cab' as const, hardwareIds: ['PCI\\VEN_8086&DEV_15F3'], deviceClass: 'Net', version: '1.0', architecture: 'amd64' as const };
    expect(verifiedPackageProblems(v).join(' ')).toMatch(/installer programs \(\.exe\) are never run/);
    expect(errorsOf(profile((p) => (p.drivers.verifiedPackages = [{ ...v, url: 'https://drivers.example.net/x.cab' }])))).toEqual([expect.objectContaining({ path: 'drivers.verifiedPackages' })]);
    expect(errorsOf(profile((p) => (p.drivers.approvals = [{ packageId: 'pkg-0123456789ab', hardwareId: 'PCI\\VEN_10DE&DEV_2484' }])))).toEqual([expect.objectContaining({ path: 'drivers.approvals', message: expect.stringMatching(/unknown package/) })]);
  });

  it('the owner default has no driver warning; a Setup-critical inventory without its driver does', () => {
    const r = generateOk(profile());
    expect(r.issues.filter((i) => i.path.startsWith('drivers.'))).toEqual([]);
    const inv = importHardwareInventory(inventory()).inventory!;
    const w = generateOk(profile((p) => (p.drivers.hardware = hardwareSummary(inv)))).issues;
    expect(w).toContainEqual(expect.objectContaining({ severity: 'warning', path: 'drivers.hardware', message: expect.stringMatching(/\$WinPEDriver\$/) }));
  });
});

describe('static safety checks of the driver engine', () => {
  it('pnputil runs in one adapter, with add/scan/export only; never delete, remove, disable, force or rollback', () => {
    expect(withoutFn(['Invoke-WdvPnpUtil', 'Expand-WdvCabinet'])).not.toMatch(/System32\\pnputil\.exe|& \$exe/i);
    expect(fnBody('Invoke-WdvPnpUtil')).toContain("Join-Path $env:SystemRoot 'System32\\pnputil.exe'");
    const pnp = fnBody('Invoke-WdvPnpUtil');
    expect(pnp).toContain("'/add-driver', '/scan-devices', '/export-driver'");
    expect(pnp).toMatch(/force\|delete\|remove\|disable\|uninstall\|reboot/);
    const calls = [...driverSource.matchAll(/Invoke-WdvPnpUtil @\(([^)]*)\)/g)].map((m) => m[1]!);
    expect(calls.length).toBe(3);
    for (const c of calls) expect(c).toMatch(/^'\/(add-driver|scan-devices|export-driver)'/);
  });

  it('no signature, Secure Boot, Defender, firewall, firmware or policy changes; nothing downloaded is executed', () => {
    for (const src of [driverSource, installerSource]) {
      expect(src).not.toMatch(/bcdedit|testsigning|nointegritychecks|Set-MpPreference|Add-MpPreference|Set-NetFirewall|netsh advfirewall|Set-SecureBoot|Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|Invoke-Expression|\biex\b|Start-Process|Invoke-Item|msiexec|DiRollbackDriver|devcon|Disable-PnpDevice|Uninstall-|\/delete-driver /i);
      // Only these programs are ever started: pnputil, expand, shutdown (restart), icacls (installer ACL).
      const started = [...src.matchAll(/(?:^\s*|[=({;]\s*)& +("[^"]*"|\$[A-Za-z]+|[A-Za-z.]+)/gm)].map((m) => m[1]!);
      for (const x of started) expect(x, x).toMatch(/^(\$exe|\$ps|"\$env:SystemRoot\\System32\\shutdown\.exe"|icacls\.exe|\$refuse|\$pick|\$mk|\$Change|\$Between)$/);
    }
    expect(withoutFn(['Invoke-WdvDownload', 'Test-WdvNetwork'])).not.toMatch(/Invoke-WebRequest|DownloadFile|WebClient/);
    expect(withoutFn(['Get-WdvSignature'])).not.toContain('Get-AuthenticodeSignature');
    expect(withoutFn(['Invoke-WdvReboot'])).not.toMatch(/shutdown\.exe|Restart-Computer/);
    expect(withoutFn(['Expand-WdvCabinet'])).not.toMatch(/System32\\expand\.exe/);
    expect(fnBody('Expand-WdvCabinet')).toMatch(/System32\\expand\.exe/);
    // Device-installation policy is read, never written.
    expect(fnBody('Get-WdvDeviceInstallPolicy')).not.toMatch(/Set-|New-|Remove-/);
  });

  it('shares the identical coordination block with both other engines', () => {
    const region = (s: string) => {
      const t = s.replace(/\r\n/g, '\n');
      return t.slice(t.indexOf('# region WDB coordination'), t.indexOf('# endregion WDB coordination'));
    };
    expect(region(driverSource).length).toBeGreaterThan(1000);
    expect(region(driverSource)).toBe(region(wuEngineSource));
    expect(region(driverSource)).toBe(region(appEngineSource));
  });

  it('identification data: official support pages only (no installer links), no driver-updater sites', () => {
    const urls = [...DRIVER_SOURCE_DATA.componentVendors, ...DRIVER_SOURCE_DATA.systemManufacturers].map((v) => v.supportUrl).filter(Boolean);
    expect(urls.length).toBeGreaterThanOrEqual(12);
    for (const u of urls) {
      expect(u).toMatch(/^https:\/\//);
      expect(u).not.toMatch(/\.(exe|zip|cab|msi)(\?|$)|driverpack|driverbooster|drivereasy|snappy/i);
    }
    expect(JSON.stringify(DRIVER_SOURCE_DATA)).not.toMatch(/driverpack|driver ?booster|driver ?easy|snappy ?driver/i);
    expect(DRIVER_SOURCE_DATA.whqlSigners).toContain('Microsoft Windows Hardware Compatibility Publisher');
  });

  it('the recovery tool reopens driver operations only through the engine; the technician tool is read-only by default', () => {
    expect(recoverySource).toContain('Invoke-WdvRetry $dcfg -AllFailed');
    expect(recoverySource).toContain('Add-WdvTechnicianPackages $dcfg $DriverPath');
    const files = readZip(driverToolBundle()).map((e) => e.path);
    expect(files).toEqual(['hardware-driver-tool/DriverEngine.ps1', 'hardware-driver-tool/driver-sources.json', 'hardware-driver-tool/Inspect-Hardware.cmd', 'hardware-driver-tool/README-Hardware-Driver-Tool.txt']);
    const cmd = new TextDecoder().decode(readZip(driverToolBundle()).find((e) => e.path.endsWith('.cmd'))!.data);
    expect(cmd).toContain('-Mode Inspect');
  });
});

describe('Quick Deployment', () => {
  it('summarises the driver stage without implying the website can see the hardware', () => {
    const s = reviewSummary(ownerDefaults());
    expect(s.drivers.summary).toBe('Windows will identify hardware, use compatible existing or Windows Update drivers, and report any missing drivers.');
    expect(s.drivers.detail).toMatch(/^Detected on the installed computer, not by this website\./);
    const off = ownerDefaults();
    off.drivers.enabled = false;
    expect(reviewSummary(off).drivers.summary).toMatch(/^Off/);
  });
});
