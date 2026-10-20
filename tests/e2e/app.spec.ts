import { expect, test, type Page } from '@playwright/test';
import { readFile } from 'node:fs/promises';

const field = (page: Page, path: string) => page.locator(`[data-path="${path}"]`);
const radio = (page: Page, path: string, value: string) => page.locator(`input[type=radio][name="${path}"][value="${value}"]`);
const checkbox = (page: Page, path: string) => page.locator(`input[type=checkbox][name="${path}"]`);
const preview = (page: Page) => page.getByTestId('xml-preview');

async function setName(page: Page, name: string) {
  await page.locator('input[name="accounts.personName"]').fill(name);
}

test.beforeEach(async ({ page }) => {
  await page.goto('/');
});

test('loads the owner profile into the exact controls', async ({ page }) => {
  await expect(page.getByRole('heading', { name: 'Windows Deployment Builder' })).toBeVisible();
  await expect(radio(page, 'setup.editionMode', 'genericKey')).toBeChecked();
  await expect(radio(page, 'security.uacLevel', 'noDim')).toBeChecked();
  await expect(radio(page, 'privacy.expressSettings', 'disableAll')).toBeChecked();
  await expect(radio(page, 'updates.mode', 'notifyInstall')).toBeChecked();
  await expect(radio(page, 'taskbar.search', 'icon')).toBeChecked();
  await expect(radio(page, 'wifi.mode', 'interactive')).toBeChecked();
  await expect(radio(page, 'accounts.autoLogon', 'persistent')).toBeChecked();
  await expect(checkbox(page, 'explorer.showFileExtensions')).toBeChecked();
  await expect(checkbox(page, 'system.disableFastStartup')).toBeChecked();
  await expect(checkbox(page, 'taskbar.hideTaskView')).not.toBeChecked();
  await expect(checkbox(page, 'desktop.icons.RecycleBin')).toBeChecked();
  await expect(checkbox(page, 'desktop.icons.ThisPC')).not.toBeChecked();
  await expect(checkbox(page, 'start.folders.Downloads')).toBeChecked();
  await expect(checkbox(page, 'start.folders.Documents')).not.toBeChecked();
  await page.getByRole('button', { name: 'Advanced' }).click();
  await expect(radio(page, 'bloatware.Clipchamp', 'remove')).toBeChecked();
  await expect(radio(page, 'bloatware.Calculator', 'keep')).toBeChecked();
  await expect(radio(page, 'bloatware.Cortana', 'untouched')).toBeChecked();
  await expect(radio(page, 'bloatware.WindowsBackup', 'remove')).toBeDisabled();
  await expect(page.getByTestId('autologon-warning')).toBeVisible();
});

test('requires a name, then derives username and computer name live', async ({ page }) => {
  await expect(page.getByTestId('status')).toContainText('Cannot generate');
  await expect(field(page, 'accounts.personName').locator('.issues .error')).toContainText("person's name");
  await expect(page.getByRole('button', { name: 'Download answer file' })).toBeDisabled();

  await setName(page, 'Alex');
  await expect(page.getByTestId('identity')).toContainText('Username: Alex');
  await expect(page.getByTestId('identity')).toContainText('Computer name: Alex-Computer');
  await expect(page.getByTestId('status')).toContainText('Ready');
  await expect(preview(page)).toContainText('<ComputerName>Alex-Computer</ComputerName>');
  await expect(preview(page)).toContainText('<Name>Alex</Name>');

  await setName(page, 'Zoë Christopher');
  await expect(page.getByTestId('identity')).toContainText('Computer name: ZoeChr-Computer');
  await expect(preview(page)).toContainText('<Username>ZoeChristopher</Username>');
  await expect(preview(page)).toContainText('<DisplayName>Zo&#xEB; Christopher</DisplayName>');
});

test('Basic/Advanced toggle hides rare settings without resetting values', async ({ page }) => {
  await setName(page, 'Kim');
  await expect(field(page, 'scripts.firstLogon')).toBeVisible();
  await expect(field(page, 'scripts.system')).toBeHidden();
  await expect(field(page, 'advancedXml.components')).toBeHidden();

  await page.getByRole('button', { name: 'Advanced' }).click();
  await expect(field(page, 'scripts.system')).toBeVisible();
  await checkbox(page, 'system.enableLongPaths').check();
  await radio(page, 'taskbar.search', 'hide').check();

  await page.getByRole('button', { name: 'Basic' }).click();
  await expect(field(page, 'system.enableLongPaths')).toBeHidden();
  await page.getByRole('button', { name: 'Advanced' }).click();
  await expect(checkbox(page, 'system.enableLongPaths')).toBeChecked();
  await expect(radio(page, 'taskbar.search', 'hide')).toBeChecked();
  await expect(page.locator('input[name="accounts.personName"]')).toHaveValue('Kim');
  await expect(page.getByTestId('diff')).toContainText('system.enableLongPaths');
});

test('FirstLogon script is escaped into the XML; blank scripts add nothing', async ({ page }) => {
  await setName(page, 'Alex');
  const before = await preview(page).textContent();
  await page.locator('[data-action="add-script-firstLogon"]').click();
  await expect(page.getByTestId('status')).toContainText('warning');
  expect(await preview(page).textContent()).toBe(before);

  await field(page, 'scripts.firstLogon').locator('textarea').fill(`Write-Host "Tom & Jerry <3"`);
  await expect(preview(page)).toContainText('Write-Host "Tom &amp; Jerry &lt;3"');
  await expect(preview(page)).toContainText('unattend-01.ps1');
});

test('validation errors are shown at the field and block output', async ({ page }) => {
  await setName(page, 'Alex');
  await page.getByRole('button', { name: 'Advanced' }).click();
  await radio(page, 'wifi.mode', 'parameters').check();
  await page.locator('input[name="wifi.ssid"]').fill('Home');
  await page.locator('input[name="wifi.password"]').fill('short');
  await expect(field(page, 'wifi.password').locator('.issues .error')).toContainText('8–63');
  await expect(page.getByTestId('status')).toContainText('Cannot generate');
  await expect(page.getByRole('button', { name: 'Download answer file' })).toBeDisabled();
  await expect(preview(page)).toHaveText('No XML is shown while there are errors.');
  await page.locator('input[name="wifi.password"]').fill('long enough');
  await expect(page.getByTestId('status')).toContainText('Ready');
});

test('downloads autounattend.xml matching the preview', async ({ page }) => {
  await setName(page, 'Alex');
  const [dl] = await Promise.all([page.waitForEvent('download'), page.getByRole('button', { name: 'Download answer file' }).click()]);
  expect(dl.suggestedFilename()).toBe('autounattend.xml');
  const content = await readFile((await dl.path())!, 'utf8');
  expect(content.replace(/\r\n/g, '\n').trim()).toBe((await preview(page).textContent())!.replace(/\r\n/g, '\n').trim());
  expect(content).not.toMatch(/DiskConfiguration|WillWipeDisk/);
});

test('export → change → import round-trips; reset restores owner defaults', async ({ page }) => {
  await setName(page, 'Alex');
  await page.getByRole('button', { name: 'Advanced' }).click();
  await radio(page, 'taskbar.search', 'label').check();
  await radio(page, 'bloatware.Calculator', 'remove').check();
  const [dl] = await Promise.all([page.waitForEvent('download'), page.locator('[data-action="export"]').click()]);
  const json = await readFile((await dl.path())!, 'utf8');
  expect(JSON.parse(json).taskbar.search).toBe('label');

  page.once('dialog', (d) => d.accept());
  await page.locator('[data-action="reset"]').click();
  await expect(radio(page, 'taskbar.search', 'icon')).toBeChecked();
  await expect(radio(page, 'bloatware.Calculator', 'keep')).toBeChecked();
  await expect(page.locator('input[name="accounts.personName"]')).toHaveValue('');
  await expect(page.getByTestId('diff')).toContainText('No changes');

  await page.getByTestId('import-input').setInputFiles({ name: 'p.json', mimeType: 'application/json', buffer: Buffer.from(json) });
  await expect(page.getByTestId('notice')).toContainText('Imported p.json');
  await expect(radio(page, 'taskbar.search', 'label')).toBeChecked();
  await expect(radio(page, 'bloatware.Calculator', 'remove')).toBeChecked();
  await expect(page.locator('input[name="accounts.personName"]')).toHaveValue('Alex');
});

test('rejects an invalid profile import with messages', async ({ page }) => {
  await page.getByTestId('import-input').setInputFiles({ name: 'bad.json', mimeType: 'application/json', buffer: Buffer.from('{"schemaVersion":1,"taskbar":{"search":"giant"}}') });
  await expect(page.getByTestId('notice')).toContainText('Could not import bad.json');
  await expect(page.getByTestId('notice')).toContainText('taskbar.search');
  await expect(radio(page, 'taskbar.search', 'icon')).toBeChecked();
});

test('no horizontal page scroll', async ({ page }) => {
  await setName(page, 'Alex');
  await page.getByRole('button', { name: 'Advanced' }).click();
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(overflow).toBeLessThanOrEqual(0);
});

test('Windows Update automation: on by default, assets downloadable, policy conflicts shown', async ({ page }) => {
  await setName(page, 'Alex');
  await expect(checkbox(page, 'windowsUpdate.enabled')).toBeChecked();
  await expect(radio(page, 'windowsUpdate.drivers', 'followPolicy')).toBeChecked();
  await expect(radio(page, 'windowsUpdate.featureUpdates', 'skip')).toBeChecked();
  await expect(page.getByTestId('summary')).toContainText('On: drivers excluded, feature updates skipped');
  await expect(preview(page)).toContainText('WindowsUpdate\\Install-UpdateEngine.ps1');

  const assets = page.getByTestId('assets');
  await expect(assets.locator('[data-asset]')).toHaveCount(5); // 4 engine files + orchestration.json
  const [dl] = await Promise.all([page.waitForEvent('download'), assets.locator('[data-asset="config.json"] [data-action="download-asset"]').click()]);
  expect(dl.suggestedFilename()).toBe('config.json');
  const config = JSON.parse(await readFile((await dl.path())!, 'utf8'));
  expect(config).toMatchObject({ drivers: 'exclude', featureUpdates: 'skip', maxReboots: 10 });

  await page.getByRole('button', { name: 'Advanced' }).click();
  await page.locator('input[name="windowsUpdate.maxReboots"]').fill('3');
  await page.locator('input[name="windowsUpdate.excludedKbs"]').fill('KB5034441');
  const [dl2] = await Promise.all([page.waitForEvent('download'), assets.locator('[data-asset="config.json"] [data-action="download-asset"]').click()]);
  expect(JSON.parse(await readFile((await dl2.path())!, 'utf8'))).toMatchObject({ maxReboots: 3, excludedKbs: ['KB5034441'] });

  await radio(page, 'windowsUpdate.drivers', 'include').check();
  await expect(field(page, 'windowsUpdate.drivers').locator('.issues .error')).toContainText('conflicts');
  await expect(page.getByTestId('status')).toContainText('Cannot generate');
  await radio(page, 'windowsUpdate.drivers', 'followPolicy').check();

  await checkbox(page, 'windowsUpdate.enabled').uncheck();
  await expect(field(page, 'windowsUpdate.drivers')).toBeHidden();
  await expect(assets).toContainText('None');
  await expect(preview(page)).not.toContainText('Install-UpdateEngine');
  await expect(page.getByTestId('summary')).toContainText('Off');
});

// Phase 3 ----------------------------------------------------------------------------------------

const apps = (page: Page) => field(page, 'applications.selection');
const catalogAdd = (page: Page, id: string) => page.locator(`[data-catalog="${id}"] [data-action="app-add"]`);
const wingetExport = JSON.stringify({
  $schema: 'https://aka.ms/winget-packages.schema.2.0.json',
  CreationDate: '2026-10-19T09:41:12.512-00:00',
  WinGetVersion: '1.29.250',
  Sources: [
    {
      SourceDetails: { Name: 'winget', Identifier: 'Microsoft.Winget.Source_8wekyb3d8bbwe', Argument: 'https://cdn.winget.microsoft.com/cache', Type: 'Microsoft.PreIndexed.Package' },
      Packages: [{ PackageIdentifier: 'Git.Git' }, { PackageIdentifier: 'VideoLAN.VLC' }, { PackageIdentifier: 'Not A Valid Id' }],
    },
  ],
});

test('application provisioning: empty by default, nothing generated until something is selected', async ({ page }) => {
  await setName(page, 'Alex');
  await expect(checkbox(page, 'applications.enabled')).toBeChecked();
  await expect(apps(page).locator('[data-profile]')).toHaveCount(6);
  for (const id of ['everyday', 'gaming', 'developer', 'laptop', 'touch', 'custom']) {
    await expect(apps(page).locator(`[data-profile="${id}"]`)).toContainText('Empty');
  }
  await expect(page.getByTestId('app-count')).toHaveText('0 selected');
  await expect(page.getByTestId('summary')).toContainText('On, nothing selected');
  await expect(preview(page)).not.toContainText('Install-ApplicationEngine');
  await expect(page.getByTestId('assets').locator('[data-asset-group="applications"]')).toHaveCount(0);
});

test('application provisioning (Basic): search, filter, add, remove, count, duplicates and generated assets', async ({ page }) => {
  await setName(page, 'Alex');
  await page.getByTestId('app-search').fill('pdf');
  await expect(page.getByTestId('app-catalog').locator('[data-catalog="sumatrapdf"]')).toBeVisible();
  await expect(page.getByTestId('app-catalog').locator('[data-catalog="steam"]')).toHaveCount(0);
  await catalogAdd(page, 'sumatrapdf').click();
  await expect(page.getByTestId('app-count')).toHaveText('1 selected');
  await expect(catalogAdd(page, 'sumatrapdf')).toBeDisabled();

  await page.getByTestId('app-search').fill('');
  await page.getByTestId('app-category').selectOption('gaming');
  await expect(page.getByTestId('app-catalog').locator('[data-catalog="git"]')).toHaveCount(0);
  await catalogAdd(page, 'steam').click();
  await expect(catalogAdd(page, 'launchbox')).toBeDisabled();
  await expect(page.locator('[data-catalog="launchbox"]')).toContainText('unresolved');

  // Populate the empty Gaming profile explicitly, then combine it: Steam is selected twice but installed once.
  await page.getByTestId('app-target').selectOption('gaming');
  await catalogAdd(page, 'steam').click();
  await catalogAdd(page, 'playnite').click();
  await checkbox(page, 'applications.profile.gaming').check();
  await expect(apps(page).locator('[data-profile="gaming"]')).toContainText('2 packages');
  await expect(page.getByTestId('app-count')).toHaveText('3 selected');
  await expect(page.getByTestId('app-warnings').locator('[data-kind="duplicate"]')).toContainText('Steam');

  await apps(page).locator('[data-package="winget:sumatrapdf.sumatrapdf"] [data-action="app-remove"]').click();
  await expect(page.getByTestId('app-count')).toHaveText('2 selected');

  await expect(page.getByTestId('summary')).toContainText('2 package(s) via WinGet from Gaming');
  await expect(preview(page)).toContainText('Applications\\Install-ApplicationEngine.ps1');
  const group = page.getByTestId('assets').locator('[data-asset-group="applications"]');
  await expect(group.locator('[data-asset]')).toHaveCount(9);
  const [dl] = await Promise.all([page.waitForEvent('download'), group.locator('[data-asset="winget-packages.json"] [data-action="download-asset"]').click()]);
  const native = JSON.parse(await readFile((await dl.path())!, 'utf8'));
  expect(native.Sources[0].Packages.map((p: { PackageIdentifier: string }) => p.PackageIdentifier)).toEqual(['Valve.Steam', 'Playnite.Playnite']);
});

test('application provisioning: WinGet import adds a profile without overwriting, export is valid WinGet JSON', async ({ page }) => {
  await setName(page, 'Alex');
  await catalogAdd(page, '7zip').click();
  await page.getByTestId('app-import-input').setInputFiles({ name: 'office.json', mimeType: 'application/json', buffer: Buffer.from(wingetExport) });
  await expect(page.getByTestId('app-import-status')).toContainText('Imported office.json as profile "Imported: office"');
  await expect(page.getByTestId('app-import-status')).toContainText('Not A Valid Id');
  await expect(checkbox(page, 'applications.profile.imported-office')).toBeChecked();
  await expect(page.getByTestId('app-count')).toHaveText('3 selected');
  await expect(apps(page).locator('[data-package="winget:7zip.7zip"]')).toBeVisible();

  const [dl] = await Promise.all([page.waitForEvent('download'), page.locator('[data-action="app-export-winget"]').click()]);
  expect(dl.suggestedFilename()).toBe('winget-packages.json');
  const out = JSON.parse(await readFile((await dl.path())!, 'utf8'));
  expect(out.$schema).toBe('https://aka.ms/winget-packages.schema.2.0.json');
  expect(out.Sources[0].SourceDetails.Identifier).toBe('Microsoft.Winget.Source_8wekyb3d8bbwe');
  expect(out.Sources[0].Packages.map((p: { PackageIdentifier: string }) => p.PackageIdentifier).sort()).toEqual(['7zip.7zip', 'Git.Git', 'VideoLAN.VLC']);

  await page.getByTestId('app-import-input').setInputFiles({ name: 'evil.json', mimeType: 'application/json', buffer: Buffer.from('{"Sources":[{"SourceDetails":{"Name":"winget"},"Packages":[]}]}') });
  await expect(page.getByTestId('app-import-status')).toContainText('Could not import evil.json');
  await expect(page.getByTestId('app-count')).toHaveText('3 selected');
});

test('application provisioning (Advanced): profiles, manual IDs, order preview, policies and validation', async ({ page }) => {
  await setName(page, 'Alex');
  await expect(page.getByTestId('app-order')).toBeHidden();
  await page.getByRole('button', { name: 'Advanced' }).click();

  page.once('dialog', (d) => d.accept('Family PC'));
  await page.locator('[data-action="app-new-profile"]').click();
  await expect(checkbox(page, 'applications.profile.family-pc')).toBeChecked();
  await expect(page.getByTestId('app-target')).toHaveValue('family-pc');
  await catalogAdd(page, 'docker-desktop').click();
  await catalogAdd(page, 'wsl').click();
  await expect(page.getByTestId('app-order').locator('li').first()).toContainText('Windows Subsystem for Linux');
  await expect(page.getByTestId('app-order')).toContainText('winget install --id Docker.DockerDesktop --exact --source winget --silent');

  page.once('dialog', (d) => d.accept('Kids PC'));
  await apps(page).locator('[data-profile="family-pc"] [data-action="app-rename-profile"]').click();
  await expect(apps(page).locator('[data-profile="family-pc"]')).toContainText('Kids PC');
  await apps(page).locator('[data-profile="family-pc"] [data-action="app-duplicate-profile"]').click();
  await expect(apps(page).locator('[data-profile]')).toHaveCount(8);
  await expect(apps(page).locator('[data-profile="gaming"] [data-action="app-delete-profile"]')).toHaveCount(0);

  await page.getByText('Add by package identifier').click();
  await page.getByTestId('app-manual-id').fill('Foo Bar');
  await page.locator('[data-action="app-add-manual"]').click();
  await expect(page.getByTestId('app-manual-message')).toContainText('Not a valid winget identifier');
  await page.getByTestId('app-manual-id').fill('Microsoft.VisualStudioCode');
  await page.getByTestId('app-manual-version').fill('1.95.0');
  await page.locator('[data-action="app-add-manual"]').click();
  await expect(page.getByTestId('app-manual-message')).toContainText('Added');
  await expect(page.getByTestId('app-order')).toContainText('--version 1.95.0');

  await radio(page, 'applications.restartPolicy', 'never').check();
  await page.locator('input[name="applications.maxAttemptsPerPackage"]').fill('9');
  await expect(field(page, 'applications.maxAttemptsPerPackage').locator('.issues .error')).toContainText('between 1 and 5');
  await page.locator('input[name="applications.maxAttemptsPerPackage"]').fill('3');
  await expect(page.getByTestId('status')).toContainText('Ready');

  await radio(page, 'accounts.accountGroup', 'Users').check();
  await expect(field(page, 'applications.enabled').locator('.issues .error')).toContainText('administrator account');
  await radio(page, 'accounts.accountGroup', 'Administrators').check();

  const [dl] = await Promise.all([page.waitForEvent('download'), page.getByTestId('assets').locator('[data-asset="applications-config.json"] [data-action="download-asset"]').click()]);
  const cfg = JSON.parse(await readFile((await dl.path())!, 'utf8'));
  expect(cfg).toMatchObject({ restartPolicy: 'never', maxAttemptsPerPackage: 3 });
  expect(cfg.packages.map((p: { packageIdentifier: string }) => p.packageIdentifier)).toEqual(['Microsoft.WSL', 'Docker.DockerDesktop', 'Microsoft.VisualStudioCode']);
});

test('application selection survives Basic/Advanced switches, profile export/import, and reset', async ({ page }) => {
  await setName(page, 'Alex');
  await catalogAdd(page, 'git').click();
  await page.getByRole('button', { name: 'Advanced' }).click();
  await page.getByRole('button', { name: 'Basic' }).click();
  await expect(page.getByTestId('app-count')).toHaveText('1 selected');

  const [dl] = await Promise.all([page.waitForEvent('download'), page.locator('[data-action="export"]').click()]);
  const json = await readFile((await dl.path())!, 'utf8');
  expect(JSON.parse(json).applications.selection.added[0].packageIdentifier).toBe('Git.Git');

  page.once('dialog', (d) => d.accept());
  await page.locator('[data-action="reset"]').click();
  await expect(page.getByTestId('app-count')).toHaveText('0 selected');

  await page.getByTestId('import-input').setInputFiles({ name: 'p.json', mimeType: 'application/json', buffer: Buffer.from(json) });
  await expect(page.getByTestId('app-count')).toHaveText('1 selected');
});

test('Additional Software: recorded as manual follow-up; unsafe entries are rejected', async ({ page }) => {
  await setName(page, 'Alex');
  const add = field(page, 'additionalSoftware.items');
  await page.locator('[data-action="add-additional"]').click();
  await add.locator('input[name="additionalSoftware.items.0.name"]').fill('Vendor Tool');
  await add.locator('input[name="additionalSoftware.items.0.downloadUrl"]').fill('http://vendor.example/setup.exe');
  await expect(add.locator('.issues .error').filter({ hasText: 'https://' })).toBeVisible();
  await add.locator('input[name="additionalSoftware.items.0.downloadUrl"]').fill('https://vendor.example/setup.exe');
  await add.locator('input[name="additionalSoftware.items.0.silentArgs"]').fill('/S & calc');
  await expect(add.locator('.issues .error').filter({ hasText: 'must not contain &' })).toBeVisible();
  await add.locator('input[name="additionalSoftware.items.0.silentArgs"]').fill('/S');
  await add.locator('select[name="additionalSoftware.items.0.execution"]').selectOption('automatic');
  await expect(add.locator('.issues .error').filter({ hasText: 'reviewed list' })).toBeVisible();
  await add.locator('select[name="additionalSoftware.items.0.execution"]').selectOption('manual');
  await expect(page.getByTestId('status')).toContainText('Ready');
  await expect(page.getByTestId('summary')).toContainText('1 installer(s), listed for manual follow-up');
  await expect(page.getByTestId('assets').locator('[data-asset="applications-plan.txt"]')).toContainText('Vendor Tool: manual follow-up');
});
