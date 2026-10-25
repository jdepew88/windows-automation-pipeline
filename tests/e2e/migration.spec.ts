import { expect, test, type Page } from '@playwright/test';
import { createHash } from 'node:crypto';

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- free-form JSON fixtures, mutated to build hostile input
type Loose = any;

/** Phase 6: Application Backup & Restore (Advanced Configuration). Synthetic inventories only. */

async function go(page: Page, target: string) {
  const link = page.locator(`.sidebar a.nav-item[data-target="${target}"]`);
  const menu = page.locator('.menu-btn.in-bar');
  if ((await menu.isVisible()) && (await menu.getAttribute('aria-expanded')) !== 'true') {
    await menu.click();
    await expect(page.locator('body')).toHaveClass(/nav-open/);
  }
  await link.click();
  await expect(page.locator(`#${target}`)).toBeVisible();
}

let n = 0;
const app = (displayName: string, extra: Record<string, unknown> = {}) => ({
  inventoryId: `app-${(++n).toString(16).padStart(12, '0')}`,
  displayName,
  publisher: '',
  version: '1.0',
  source: 'registry',
  packageIdentifier: '',
  packageSource: '',
  scope: 'machine',
  architecture: 'x64',
  installLocation: '',
  detection: ['registry'],
  kind: 'application',
  hardware: false,
  storeIdentity: '',
  notes: [],
  ...extra,
});
const wg = (displayName: string, id: string) => app(displayName, { source: 'winget', packageIdentifier: id, packageSource: 'winget', detection: ['winget', 'registry'] });

const inventory = () => ({
  format: 'windows-deployment-builder/app-inventory',
  formatVersion: 1,
  inventoryId: '0123456789abcdef',
  exportedUtc: '2026-10-21T11:00:00Z',
  collector: { name: 'WdbMigration.ps1', version: '1.0.0', powershell: '5.1.26100.1', wingetMethod: 'Microsoft.WinGet.Client' },
  source: { osName: 'Microsoft Windows 11 Pro', osVersion: '10.0.26100', osBuild: '26100', displayVersion: '24H2', architecture: 'x64' },
  applications: [
    wg('Git', 'Git.Git'),
    wg('Example Tool', 'Example.Tool'),
    app('PuTTY', { publisher: 'Someone Else' }),
    app('Contoso Field Tool', { publisher: 'Contoso' }),
    app('NVIDIA Graphics Driver', { publisher: 'NVIDIA Corporation', kind: 'driver', hardware: true }),
  ],
  excludedCounts: { systemComponents: 4, updates: 2, frameworks: 1, resourcePackages: 0, withoutName: 0 },
  devEnvironment: {
    git: { installed: true, version: '2.51.0', globalConfig: true },
    vscodeExtensions: [],
    cursorExtensions: [],
    powershellModules: [],
    python: [],
    pythonManagers: [],
    node: { version: '', managers: [{ name: 'nvm-windows', versions: ['v22.20.0'] }] },
    docker: { installed: false, settingsPresent: false },
    claudeCode: { installed: false, method: '' },
    repositories: [],
  },
  settings: [],
  warnings: [],
  backup: null,
});

const manifest = () => {
  const text = '[user]\n\tname = Alex\n';
  return {
    format: 'windows-deployment-builder/app-backup',
    formatVersion: 1,
    backupId: 'a1b2c3d4e5f60718',
    folderName: 'WDB-AppBackup-20261021-120000-a1b2c3',
    createdUtc: '2026-10-21T12:00:00Z',
    collector: { name: 'WdbMigration.ps1', version: '1.0.0' },
    source: { osName: 'Microsoft Windows 11 Pro', osBuild: '26100', architecture: 'x64' },
    inventoryId: '0123456789abcdef',
    adapters: [{ id: 'git', name: 'Git (global configuration)', adapterVersion: 1, restoreMode: 'automatic', items: [{ logical: 'gitconfig', kind: 'gitconfig', path: 'data/git/gitconfig', size: Buffer.byteLength(text), sha256: createHash('sha256').update(text).digest('hex').toUpperCase() }], excluded: [], notes: [] }],
    unsupported: [],
    totals: { files: 1, bytes: Buffer.byteLength(text) },
    notice: 'Application settings only.',
  };
};

const file = (name: string, v: unknown) => ({ name, mimeType: 'application/json', buffer: Buffer.from(typeof v === 'string' ? v : JSON.stringify(v, null, 2)) });

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    if (!sessionStorage.getItem('e2e-init')) {
      localStorage.setItem('wdb.mode', 'advanced');
      localStorage.setItem('wdb.catalogView', 'detailed');
      sessionStorage.setItem('e2e-init', '1');
    }
  });
  await page.goto('/');
});

test('the application catalog offers "Import applications from an existing computer"', async ({ page }) => {
  await go(page, 'section-applications');
  await page.locator('[data-action="app-import-computer"]').click();
  await expect(page.locator('#section-migration')).toBeVisible();
  await expect(page.getByTestId('mig-download-collector')).toBeVisible();
});

test('import an inventory, review matches, confirm a guess, and save a named profile on Network Engineer', async ({ page }) => {
  await go(page, 'section-migration');
  await page.getByTestId('mig-inventory-input').setInputFiles(file('inventory.json', inventory()));
  await expect(page.getByTestId('mig-import-status')).toContainText('Imported inventory.json: 5 application record(s)');
  await expect(page.getByTestId('mig-counts')).toContainText('2 In the curated catalog');
  await expect(page.getByTestId('mig-counts')).toContainText('2 Unknown or unsupported');
  const row = (name: string) => page.getByTestId('mig-row').filter({ hasText: name }).first();
  await expect(row('Git').getByTestId('mig-decision')).toHaveValue('restore');
  await expect(row('Example Tool')).toContainText('Verified WinGet package (outside the catalog)');
  await expect(row('PuTTY')).toContainText('Possible match: confirm before installing');
  await expect(row('Contoso Field Tool').getByTestId('mig-decision').locator('option')).toHaveText(['Include, install manually', 'Exclude from this migration']);
  await expect(row('NVIDIA Graphics Driver')).toContainText('Hardware-specific (Phase 8)');
  // A possible match set to "restore" blocks the profile until it is confirmed.
  await row('PuTTY').getByTestId('mig-decision').selectOption('restore');
  await expect(row('PuTTY')).toContainText('Confirm the match first');
  await expect(page.getByTestId('mig-create')).toBeDisabled();
  await row('PuTTY').getByTestId('mig-confirm').check();
  await expect(page.getByTestId('mig-create')).toBeEnabled();
  await row('Contoso Field Tool').getByTestId('mig-decision').selectOption('manual');
  await expect(page.getByTestId('mig-base')).toHaveValue('network-engineer');
  await page.getByTestId('mig-profile-name').fill('Alex Workstation');
  await page.getByTestId('mig-create').click();
  await expect(page.getByTestId('mig-review-status')).toContainText('Created profile "Alex Workstation" and ticked it');
  await expect(page.getByTestId('mig-review-status')).toContainText('The base profile itself is unchanged.');
  await expect(page.getByTestId('mig-followups')).toContainText('nvm-windows');
  await expect(page.locator('input[name="migration.enabled"]')).toBeChecked();
  await go(page, 'section-applications');
  await expect(page.locator('[data-profile]').filter({ hasText: 'Alex Workstation' })).toBeVisible();
  await expect(page.locator('input[name="applications.profile.network-engineer"]')).not.toBeChecked();
  await go(page, 'section-additionalSoftware');
  await expect(page.locator('[data-additional-index]').filter({ hasText: 'Contoso Field Tool' })).toBeVisible();
});

test('invalid or hostile inventories are rejected with a message and change nothing', async ({ page }) => {
  await go(page, 'section-migration');
  await page.getByTestId('mig-inventory-input').setInputFiles(file('bad.json', 'not json'));
  await expect(page.getByTestId('mig-import-status')).toContainText('Could not import bad.json');
  const evil = inventory() as Record<string, unknown>;
  (evil.applications as Record<string, unknown>[])[0]!.uninstallString = 'cmd /c format c:';
  await page.getByTestId('mig-inventory-input').setInputFiles(file('evil.json', evil));
  await expect(page.getByTestId('mig-import-status')).toContainText('Could not import evil.json');
  await page.getByTestId('mig-inventory-input').setInputFiles(file('winget.json', { Sources: [] }));
  await expect(page.getByTestId('mig-import-status')).toContainText('native "winget export"');
  await expect(page.getByTestId('mig-review')).toContainText('Import an inventory to review its applications.');
});

test('attach a backup manifest: settings to restore with a conflict policy; the hash is pinned; export the review', async ({ page }) => {
  await go(page, 'section-migration');
  await page.getByTestId('mig-inventory-input').setInputFiles(file('inventory.json', inventory()));
  await page.locator('[data-action="mig-attach-backup"]').click();
  await page.getByTestId('mig-backup-input').setInputFiles(file('backup-manifest.json', manifest()));
  await expect(page.getByTestId('mig-backup-status')).toContainText('Attached backup a1b2c3d4e5f60718');
  await expect(page.getByTestId('mig-backup-hash')).toHaveText(/^[0-9A-F]{64}$/);
  await expect(page.getByTestId('mig-backup')).toContainText('WindowsDeployment\\backups\\WDB-AppBackup-20261021-120000-a1b2c3');
  const git = page.locator('.mig-adapter[data-adapter="git"]');
  await expect(git.getByTestId('mig-adapter-enabled')).toBeChecked();
  await git.getByTestId('mig-adapter-conflict').selectOption('restoreBackup');
  await expect(git.getByTestId('mig-adapter-conflict')).toHaveValue('restoreBackup');
  await expect(page.getByTestId('mig-settings')).toContainText('Not backed up by design');
  const tampered = manifest() as Loose;
  tampered.adapters[0].items[0].path = 'data/git/../../evil';
  await page.getByTestId('mig-backup-input').setInputFiles(file('tampered.json', tampered));
  await expect(page.getByTestId('mig-backup-status')).toContainText('Could not attach tampered.json');
  const [dl] = await Promise.all([page.waitForEvent('download'), page.getByTestId('mig-export').click()]);
  expect(dl.suggestedFilename()).toBe('reviewed-inventory.json');
  const text = await (await dl.createReadStream())!.toArray().then((c) => Buffer.concat(c).toString('utf8'));
  const reviewed = JSON.parse(text);
  expect(reviewed.review.decisions).toHaveLength(5);
  expect(reviewed.review.mappings.find((m: { packageKey: string }) => m.packageKey === 'winget:git.git')).toMatchObject({ classification: 'catalog', confidence: 'exact' });
});
