import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { generate } from '../../src/engine/pipeline';
import { ownerDefaults } from '../../src/engine/profiles';
import { buildDeploymentPackage } from '../../src/engine/deployment';
import { readZip } from '../../src/engine/deployment/zip';
import { catalogEntryById, catalogRef } from '../../src/engine/applications/catalog';
import { sha256, utf8 } from '../../src/engine/deployment/sha256';
import { importBackupManifest } from '../../src/engine/migration/backup';
import { InventorySchema } from '../../src/engine/migration/inventory';
import { matchInventory } from '../../src/engine/migration/matching';
import { applyMigration, attachBackup, defaultDecisions } from '../../src/engine/migration/plan';
import { importDriverBundleManifest } from '../../src/engine/drivers';

/**
 * Builds the fixture Deployment.Tests.ps1 runs against: the real deployment ZIP produced by the
 * generator, extracted into <dir>\usb exactly as a user would put it on a USB drive. The profile
 * is owner defaults (Windows Update on, Core Essentials) plus the manual RustDesk entry (optional in
 * Core Essentials since Phase 10)
 * plus an iPhone (Apple Devices from the Microsoft Store), the portable Rufus, Git, and a test-only
 * identifier with a non-ASCII name (exercises the code-page path of the answer-file extraction).
 * So the package carries every installation method: WinGet, Store, portable and manual.
 */
export function writeDeploymentFixture(dir: string): { packageId: string; files: number } {
  const p = ownerDefaults();
  p.accounts.personName = 'Alex';
  // The Phase 4-7 orchestrator scenarios run without the Phase 8 driver stage (the "off" regression);
  // the driver stage has its own fixture below (<dir>/drivers).
  p.drivers.enabled = false;
  p.applications.selection.devices.phone = 'iphone';
  p.applications.selection.added.push(catalogRef(catalogEntryById('rufus')!)!);
  p.applications.selection.added.push(catalogRef(catalogEntryById('rustdesk')!)!);
  p.applications.selection.added.push(
    { packageIdentifier: 'Git.Git', source: 'winget', displayName: 'Git', version: '', scope: '' },
    // Test-only identifier (not in the catalog) so the non-ASCII display name reaches the engine config.
    { packageIdentifier: 'Example.TestPackage', source: 'winget', displayName: 'Zoë Test Package', version: '', scope: '' },
  );
  const r = generate(p);
  if (!r.ok) throw new Error(`fixture profile is invalid: ${JSON.stringify(r.issues)}`);
  const pkg = buildDeploymentPackage(p, r);
  rmSync(dir, { recursive: true, force: true });
  const usb = join(dir, 'usb');
  for (const e of readZip(pkg.zip)) {
    const target = join(usb, ...e.path.split('/'));
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, e.data);
  }
  writeFileSync(join(dir, 'package.zip'), pkg.zip);
  writeMigrationFixture(join(dir, 'migration'));
  writeDriversFixture(join(dir, 'drivers'));
  writeHealthFixture(join(dir, 'health'));
  return { packageId: pkg.manifest.packageId, files: pkg.manifest.files.length };
}

/**
 * Phase 9 fixture (<dir>/health): a new deployment as the owner defaults make it (account "owner",
 * Windows Update, the driver stage and verification on), Core Essentials (no manual entry since
 * Phase 10, so a perfect computer can be "Ready"), plus Git, an iPhone (Apple Devices from the
 * Microsoft Store) and the portable Rufus. VLC is marked optional for delivery.
 */
export function writeHealthFixture(dir: string): { packageId: string } {
  rmSync(dir, { recursive: true, force: true });
  const p = ownerDefaults();
  p.applications.selection.devices.phone = 'iphone';
  p.applications.selection.added.push(catalogRef(catalogEntryById('rufus')!)!);
  p.applications.selection.added.push({ packageIdentifier: 'Git.Git', source: 'winget', displayName: 'Git', version: '', scope: '' });
  p.health.optionalApps = ['winget:videolan.vlc'];
  p.health.customerNotes = 'Your files from the old computer are in Documents. Call us with any question.';
  const r = generate(p);
  if (!r.ok) throw new Error(`health fixture profile is invalid: ${JSON.stringify(r.issues)}`);
  const pkg = buildDeploymentPackage(p, r);
  const usb = join(dir, 'usb');
  for (const e of readZip(pkg.zip)) {
    const target = join(usb, ...e.path.split('/'));
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, e.data);
  }
  writeFileSync(join(dir, 'package.zip'), pkg.zip);
  return { packageId: pkg.manifest.packageId };
}

export const MIGRATION_BACKUP_FOLDER = 'WDB-AppBackup-20261021-120000-a1b2c3';

/**
 * Phase 6 fixture (<dir>/migration): a synthetic inventory reviewed into a profile, a settings
 * backup written in the collector's format (so the PowerShell validator checks a manifest produced
 * by TypeScript), and the real deployment package that pins that backup. The backup is placed on
 * the simulated USB drive as WindowsDeployment/backups/<folder>, never inside the ZIP.
 */
export function writeMigrationFixture(dir: string): { packageId: string; manifestSha256: string } {
  rmSync(dir, { recursive: true, force: true });
  const usb = join(dir, 'usb');
  const backupRoot = join(usb, 'WindowsDeployment', 'backups', MIGRATION_BACKUP_FOLDER);
  const files: Record<string, string> = {
    'data/vscode/settings.json': '{ "editor.fontSize": 15, "files.autoSave": "afterDelay" }\n',
    'data/git/gitconfig': '[user]\n\tname = Alex Example\n\temail = alex@example.com\n[init]\n\tdefaultBranch = main\n',
  };
  for (const [rel, text] of Object.entries(files)) {
    mkdirSync(dirname(join(backupRoot, ...rel.split('/'))), { recursive: true });
    writeFileSync(join(backupRoot, ...rel.split('/')), text);
  }
  const item = (adapter: string, logical: string, kind: string) => {
    const bytes = utf8(files[`data/${adapter}/${logical}`]!);
    return { logical, kind, path: `data/${adapter}/${logical}`, size: bytes.length, sha256: sha256(bytes) };
  };
  const manifest = {
    format: 'windows-deployment-builder/app-backup',
    formatVersion: 1,
    backupId: 'a1b2c3d4e5f60718',
    folderName: MIGRATION_BACKUP_FOLDER,
    createdUtc: '2026-10-21T12:00:00.0000000Z',
    collector: { name: 'WdbMigration.ps1', version: '1.0.0' },
    source: { osName: 'Microsoft Windows 11 Pro', osBuild: '26100', architecture: 'x64' },
    inventoryId: '0123456789abcdef',
    adapters: [
      { id: 'vscode', name: 'Visual Studio Code', adapterVersion: 1, restoreMode: 'automatic', items: [item('vscode', 'settings.json', 'file')], excluded: [], notes: [] },
      { id: 'git', name: 'Git (global configuration)', adapterVersion: 1, restoreMode: 'automatic', items: [item('git', 'gitconfig', 'gitconfig')], excluded: [{ logical: 'gitconfig credential.helper', reason: 'not portable or may hold a secret' }], notes: [] },
    ],
    unsupported: [],
    totals: { files: 2, bytes: Object.values(files).reduce((n, t) => n + utf8(t).length, 0) },
    notice: 'Application settings only.',
  };
  const mBytes = utf8(JSON.stringify(manifest, null, 2) + '\n');
  writeFileSync(join(backupRoot, 'backup-manifest.json'), mBytes);
  const attached = importBackupManifest(mBytes);
  if (!attached.ok) throw new Error(`fixture backup manifest is invalid: ${attached.errors.join('; ')}`);

  const app = (n: number, displayName: string, extra: Record<string, unknown>) => ({
    inventoryId: `app-00000000000${n}`, displayName, publisher: '', version: '1.0', source: 'registry', packageIdentifier: '', packageSource: '', scope: 'machine',
    architecture: 'x64', installLocation: '', detection: ['registry'], kind: 'application', hardware: false, storeIdentity: '', notes: [], ...extra,
  });
  const inventory = InventorySchema.parse({
    format: 'windows-deployment-builder/app-inventory', formatVersion: 1, inventoryId: '0123456789abcdef', exportedUtc: '2026-10-21T11:00:00Z',
    collector: { name: 'WdbMigration.ps1', version: '1.0.0', powershell: '5.1.26100.1', wingetMethod: 'Microsoft.WinGet.Client' },
    source: { osName: 'Microsoft Windows 11 Pro', osVersion: '10.0.26100', osBuild: '26100', displayVersion: '24H2', architecture: 'x64' },
    applications: [
      app(1, 'Microsoft Visual Studio Code', { source: 'winget', packageIdentifier: 'Microsoft.VisualStudioCode', packageSource: 'winget', detection: ['winget', 'registry'], scope: 'user' }),
      app(2, 'Git', { source: 'winget', packageIdentifier: 'Git.Git', packageSource: 'winget', detection: ['winget', 'registry'] }),
      app(3, 'Contoso Field Tool', { publisher: 'Contoso Ltd.' }),
      app(4, 'NVIDIA Graphics Driver', { publisher: 'NVIDIA Corporation', kind: 'driver', hardware: true }),
    ],
    excludedCounts: { systemComponents: 0, updates: 0, frameworks: 0, resourcePackages: 0, withoutName: 0 },
    devEnvironment: { git: { installed: true, version: '2.51.0', globalConfig: true }, vscodeExtensions: [], cursorExtensions: [], powershellModules: [], python: [], pythonManagers: [], node: { version: '', managers: [] }, docker: { installed: false, settingsPresent: false }, claudeCode: { installed: false, method: '' }, repositories: [] },
    settings: [], warnings: [], backup: attached.reference!,
  });
  const p = ownerDefaults();
  p.accounts.personName = 'Alex';
  p.windowsUpdate.enabled = false;
  p.drivers.enabled = false;
  // The manual RustDesk entry (optional in Core Essentials since Phase 10) keeps a catalog follow-up in this package.
  p.applications.selection.added.push(catalogRef(catalogEntryById('rustdesk')!)!);
  const items = matchInventory(inventory);
  const decisions = defaultDecisions(items);
  decisions.set('app-000000000003', { decision: 'manual', confirmed: false });
  applyMigration(p, inventory, items, decisions, { name: 'Personal Workstation', baseProfile: '' });
  attachBackup(p, attached.reference!);
  const r = generate(p);
  if (!r.ok) throw new Error(`migration fixture profile is invalid: ${JSON.stringify(r.issues)}`);
  const pkg = buildDeploymentPackage(p, r);
  for (const e of readZip(pkg.zip)) {
    const target = join(usb, ...e.path.split('/'));
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, e.data);
  }
  writeFileSync(join(dir, 'package.zip'), pkg.zip);
  return { packageId: pkg.manifest.packageId, manifestSha256: attached.reference!.manifestSha256 };
}

export const DRIVER_BUNDLE_FOLDER = 'WDB-Drivers-20261022-120000-abc123';
const CLASS_GUIDS = {
  Display: '{4d36e968-e325-11ce-bfc1-08002be10318}',
  Net: '{4d36e972-e325-11ce-bfc1-08002be10318}',
  SCSIAdapter: '{4d36e97b-e325-11ce-bfc1-08002be10318}',
  System: '{4d36e97d-e325-11ce-bfc1-08002be10318}',
} as const;

/** The synthetic INF driver packages of the Phase 8 fixture (text the engine parses; no real driver). */
export const FIXTURE_DRIVER_PACKAGES = [
  { id: 'pkg-0000000000a1', base: 'nvdisp', cls: 'Display', provider: 'NVIDIA', version: '32.0.15.8100', date: '09/15/2026', ids: ['PCI\\VEN_10DE&DEV_2484&SUBSYS_146B10DE', 'PCI\\VEN_10DE&DEV_2484'], setupCritical: false },
  { id: 'pkg-0000000000a2', base: 'rt25cx21x64', cls: 'Net', provider: 'Realtek', version: '10.68.815.2026', date: '08/15/2026', ids: ['PCI\\VEN_10EC&DEV_8125'], setupCritical: false },
  { id: 'pkg-0000000000a3', base: 'iastorvd', cls: 'SCSIAdapter', provider: 'Intel Corporation', version: '20.1.0.1032', date: '07/01/2026', ids: ['PCI\\VEN_8086&DEV_9A0B'], setupCritical: true },
  { id: 'pkg-0000000000a4', base: 'netwtw', cls: 'Net', provider: 'Intel', version: '23.160.0.4', date: '09/01/2026', ids: ['PCI\\VEN_8086&DEV_51F0'], setupCritical: false },
  { id: 'pkg-0000000000a5', base: 'u0400000', cls: 'Display', provider: 'Advanced Micro Devices, Inc.', version: '32.0.21025.1024', date: '09/20/2026', ids: ['PCI\\VEN_1002&DEV_73BF'], setupCritical: false },
  { id: 'pkg-0000000000a6', base: 'baseclass', cls: 'System', provider: 'Contoso', version: '1.0.0.0', date: '01/01/2026', ids: ['PCI\\CC_0880'], setupCritical: false },
] as const;

export function fixtureInf(x: (typeof FIXTURE_DRIVER_PACKAGES)[number]): string {
  return [
    '; Synthetic driver package for the Windows Deployment Builder tests (installs nothing)',
    '[Version]',
    'Signature = "$WINDOWS NT$"',
    `Class = ${x.cls}`,
    `ClassGuid = ${CLASS_GUIDS[x.cls]}`,
    'Provider = %Mfg%',
    `DriverVer = ${x.date},${x.version}`,
    `CatalogFile = ${x.base}.cat`,
    '',
    '[Manufacturer]',
    '%Mfg% = Models, NTamd64.10.0...22000',
    '',
    '[Models.NTamd64.10.0...22000]',
    ...x.ids.map((id) => `%Desc% = Install, ${id}`),
    '',
    '[Install]',
    'CopyFiles = Files',
    '',
    '[Strings]',
    `Mfg = "${x.provider}"`,
    'Desc = "Test device"',
    '',
  ].join('\r\n');
}

/**
 * Phase 8 fixture (<dir>/drivers): an offline driver bundle written in the bundle tool's format (so
 * the PowerShell validator checks a manifest produced by TypeScript), and the real deployment
 * package with the driver stage on that pins it (the storage package is Setup-critical). The bundle
 * stays outside the ZIP, as in a real deployment.
 */
export function writeDriversFixture(dir: string): { packageId: string; manifestSha256: string } {
  rmSync(dir, { recursive: true, force: true });
  const bundleRoot = join(dir, 'source', DRIVER_BUNDLE_FOLDER);
  const packages = FIXTURE_DRIVER_PACKAGES.map((x, n) => {
    const folder = `packages/${String(n + 1).padStart(3, '0')}-${x.base}`;
    const files: Record<string, Uint8Array> = {
      [`${x.base}.inf`]: utf8(fixtureInf(x)),
      [`${x.base}.cat`]: utf8(`synthetic catalog for ${x.base}\r\n`),
      [`${x.base}.sys`]: utf8(`synthetic driver binary ${x.base} ${x.version}\r\n`),
    };
    for (const [name, data] of Object.entries(files)) {
      mkdirSync(join(bundleRoot, ...folder.split('/')), { recursive: true });
      writeFileSync(join(bundleRoot, ...folder.split('/'), name), data);
    }
    const list = Object.entries(files).map(([path, data]) => ({ path, size: data.length, sha256: sha256(data) }));
    const [mm, dd, yyyy] = x.date.split('/');
    return {
      id: x.id, folder, inf: `${x.base}.inf`, class: x.cls, classGuid: CLASS_GUIDS[x.cls], provider: x.provider, version: x.version, date: `${yyyy}-${mm}-${dd}`,
      catalog: `${x.base}.cat`, targets: [{ arch: 'amd64', minBuild: 22000 }], hardwareIds: [...x.ids].map((i) => i.toUpperCase()).sort(),
      signature: { status: 'Valid', signer: 'Microsoft Windows Hardware Compatibility Publisher', whql: true },
      setupCritical: x.setupCritical, networkDriver: x.cls === 'Net', files: list, bytes: list.reduce((s, f) => s + f.size, 0),
    };
  });
  const manifest = {
    format: 'windows-deployment-builder/driver-bundle',
    formatVersion: 1,
    bundleId: 'b1d2c3e4f5a60000',
    folderName: DRIVER_BUNDLE_FOLDER,
    createdUtc: '2026-10-22T12:00:00.0000000Z',
    tool: { name: 'DriverEngine.ps1', version: '1.0.0' },
    source: { kind: 'driverStoreExport', manufacturer: 'Contoso', model: 'Workstation 7', osBuild: '26100', architecture: 'amd64' },
    packages,
    refused: [],
    totals: { packages: packages.length, files: packages.reduce((s, p) => s + p.files.length, 0), bytes: packages.reduce((s, p) => s + p.bytes, 0) },
    notice: 'INF driver packages only.',
  };
  const mBytes = utf8(JSON.stringify(manifest, null, 2) + '\n');
  writeFileSync(join(bundleRoot, 'drivers-manifest.json'), mBytes);
  const attached = importDriverBundleManifest(mBytes);
  if (!attached.ok) throw new Error(`fixture driver bundle is invalid: ${attached.errors.join('; ')}`);

  const p = ownerDefaults();
  p.accounts.personName = 'Alex';
  p.drivers.bundle = attached.reference!;
  p.drivers.verifiedPackages = [
    { id: 'contoso-nic', name: 'Contoso NIC driver', vendor: 'Contoso', url: 'https://download.microsoft.com/download/contoso/nic.cab', sha256: 'A'.repeat(64), format: 'cab', hardwareIds: ['PCI\\VEN_1D6A&DEV_07B1'], deviceClass: 'Net', version: '3.1.0.0', architecture: 'amd64' },
  ];
  const r = generate(p);
  if (!r.ok) throw new Error(`drivers fixture profile is invalid: ${JSON.stringify(r.issues)}`);
  const pkg = buildDeploymentPackage(p, r);
  const usb = join(dir, 'usb');
  for (const e of readZip(pkg.zip)) {
    const target = join(usb, ...e.path.split('/'));
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, e.data);
  }
  writeFileSync(join(dir, 'package.zip'), pkg.zip);
  return { packageId: pkg.manifest.packageId, manifestSha256: attached.reference!.manifestSha256 };
}
