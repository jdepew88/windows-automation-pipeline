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

/**
 * Builds the fixture Deployment.Tests.ps1 runs against: the real deployment ZIP produced by the
 * generator, extracted into <dir>\usb exactly as a user would put it on a USB drive. The profile
 * is owner defaults (Windows Update on, Core Essentials, which includes the manual RustDesk entry)
 * plus an iPhone (Apple Devices from the Microsoft Store), the portable Rufus, Git, and a test-only
 * identifier with a non-ASCII name (exercises the code-page path of the answer-file extraction).
 * So the package carries every installation method: WinGet, Store, portable and manual.
 */
export function writeDeploymentFixture(dir: string): { packageId: string; files: number } {
  const p = ownerDefaults();
  p.accounts.personName = 'Alex';
  p.applications.selection.devices.phone = 'iphone';
  p.applications.selection.added.push(catalogRef(catalogEntryById('rufus')!)!);
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
  return { packageId: pkg.manifest.packageId, files: pkg.manifest.files.length };
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
