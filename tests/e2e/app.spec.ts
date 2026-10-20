import { expect, test, type Page } from '@playwright/test';
import { readFile } from 'node:fs/promises';

const field = (page: Page, path: string) => page.locator(`[data-path="${path}"]`);
const radio = (page: Page, path: string, value: string) => page.locator(`input[type=radio][name="${path}"][value="${value}"]`);
const checkbox = (page: Page, path: string) => page.locator(`input[type=checkbox][name="${path}"]`);
const preview = (page: Page) => page.getByTestId('xml-preview');

/** Opens a section through the sidebar (through the navigation drawer on narrow screens). */
async function go(page: Page, id: string) {
  const target = id.startsWith('section-') || id.includes('-') ? id : `section-${id}`;
  const link = page.locator(`.sidebar a.nav-item[data-target="${target}"]`);
  const menu = page.locator('.menu-btn.in-bar');
  if ((await menu.isVisible()) && (await menu.getAttribute('aria-expanded')) !== 'true') {
    await menu.click();
    await expect(page.locator('body')).toHaveClass(/nav-open/);
  }
  await link.click();
  await expect(page.locator(`#${target}`)).toBeVisible();
}

async function setName(page: Page, name: string) {
  await go(page, 'accounts');
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
  await go(page, 'accounts');
  await expect(page.getByTestId('autologon-warning')).toBeVisible();
});

test('requires a name, then derives username and computer name live', async ({ page }) => {
  await expect(page.getByTestId('status')).toContainText('Cannot generate');
  await expect(field(page, 'accounts.personName').locator('.issues .error')).toContainText("person's name");
  await go(page, 'review');
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
  await go(page, 'scripts');
  await expect(field(page, 'scripts.firstLogon')).toBeVisible();
  await expect(field(page, 'scripts.system')).toBeHidden();
  await expect(field(page, 'advancedXml.components')).toBeHidden();
  await expect(page.locator('.sidebar a.nav-item[data-target="section-advancedXml"]')).toBeHidden();

  await page.getByRole('button', { name: 'Advanced' }).click();
  await expect(field(page, 'scripts.system')).toBeVisible();
  await go(page, 'system');
  await checkbox(page, 'system.enableLongPaths').check();
  await go(page, 'taskbar');
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
  await go(page, 'scripts');
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
  await go(page, 'wifi');
  await radio(page, 'wifi.mode', 'parameters').check();
  await page.locator('input[name="wifi.ssid"]').fill('Home');
  await page.locator('input[name="wifi.password"]').fill('short');
  await expect(field(page, 'wifi.password').locator('.issues .error')).toContainText('8–63');
  await expect(page.getByTestId('status')).toContainText('Cannot generate');
  // The sidebar flags the section and the overall state.
  await expect(page.locator('.sidebar a.nav-item[data-target="section-wifi"] .nav-badge.err')).toHaveText('1');
  await expect(page.getByTestId('nav-status')).toContainText('1 problem to fix');
  await go(page, 'review');
  await expect(page.getByRole('button', { name: 'Download answer file' })).toBeDisabled();
  await expect(preview(page)).toHaveText('No XML is shown while there are errors.');
  // The error links straight back to the field.
  await page.getByTestId('status').getByRole('link', { name: 'Wi-Fi password' }).click();
  await expect(page.locator('input[name="wifi.password"]')).toBeVisible();
  await page.locator('input[name="wifi.password"]').fill('long enough');
  await expect(page.getByTestId('status')).toContainText('Ready');
  await expect(page.locator('.sidebar a.nav-item[data-target="section-wifi"] .nav-badge.err')).toHaveCount(0);
});

test('downloads autounattend.xml matching the preview', async ({ page }) => {
  await setName(page, 'Alex');
  await go(page, 'review');
  const [dl] = await Promise.all([page.waitForEvent('download'), page.getByRole('button', { name: 'Download answer file' }).click()]);
  expect(dl.suggestedFilename()).toBe('autounattend.xml');
  const content = await readFile((await dl.path())!, 'utf8');
  expect(content.replace(/\r\n/g, '\n').trim()).toBe((await preview(page).textContent())!.replace(/\r\n/g, '\n').trim());
  expect(content).not.toMatch(/DiskConfiguration|WillWipeDisk/);
});

test('export → change → import round-trips; reset restores owner defaults', async ({ page }) => {
  await setName(page, 'Alex');
  await page.getByRole('button', { name: 'Advanced' }).click();
  await go(page, 'taskbar');
  await radio(page, 'taskbar.search', 'label').check();
  await go(page, 'bloatware');
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

test('no horizontal page scroll on any section', async ({ page }) => {
  await setName(page, 'Alex');
  await page.getByRole('button', { name: 'Advanced' }).click();
  const targets = await page.locator('.sidebar a.nav-item').evaluateAll((as) => as.map((a) => (a as HTMLElement).dataset.target!));
  expect(targets.length).toBeGreaterThanOrEqual(20);
  for (const t of targets) {
    await go(page, t);
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    expect(overflow, t).toBeLessThanOrEqual(0);
  }
});

test('Windows Update automation: on by default, assets downloadable, policy conflicts shown', async ({ page }) => {
  await setName(page, 'Alex');
  await expect(checkbox(page, 'windowsUpdate.enabled')).toBeChecked();
  await expect(radio(page, 'windowsUpdate.drivers', 'followPolicy')).toBeChecked();
  await expect(radio(page, 'windowsUpdate.featureUpdates', 'skip')).toBeChecked();
  await expect(page.getByTestId('summary')).toContainText('On: drivers excluded, feature updates skipped');
  await expect(preview(page)).toContainText('WindowsUpdate\\Install-UpdateEngine.ps1');

  const assets = page.getByTestId('assets');
  await go(page, 'review');
  await expect(assets.locator('[data-asset]')).toHaveCount(5); // 4 engine files + orchestration.json
  const [dl] = await Promise.all([page.waitForEvent('download'), assets.locator('[data-asset="config.json"] [data-action="download-asset"]').click()]);
  expect(dl.suggestedFilename()).toBe('config.json');
  const config = JSON.parse(await readFile((await dl.path())!, 'utf8'));
  expect(config).toMatchObject({ drivers: 'exclude', featureUpdates: 'skip', maxReboots: 10 });

  await page.getByRole('button', { name: 'Advanced' }).click();
  await go(page, 'windowsUpdate');
  await page.locator('input[name="windowsUpdate.maxReboots"]').fill('3');
  await page.locator('input[name="windowsUpdate.excludedKbs"]').fill('KB5034441');
  await go(page, 'review');
  const [dl2] = await Promise.all([page.waitForEvent('download'), assets.locator('[data-asset="config.json"] [data-action="download-asset"]').click()]);
  expect(JSON.parse(await readFile((await dl2.path())!, 'utf8'))).toMatchObject({ maxReboots: 3, excludedKbs: ['KB5034441'] });

  await go(page, 'windowsUpdate');
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
  await expect(preview(page)).not.toContainText('Applications\\Install-ApplicationEngine.ps1');
  await expect(page.getByTestId('assets').locator('[data-asset-group="applications"]')).toHaveCount(0);
});

test('application provisioning (Basic): search, filter, add, remove, count, duplicates and generated assets', async ({ page }) => {
  await setName(page, 'Alex');
  await go(page, 'applications');
  await page.getByTestId('app-search').fill('pdf');
  await expect(page.getByTestId('app-catalog').locator('[data-catalog="sumatrapdf"]')).toBeVisible();
  await expect(page.getByTestId('app-catalog').locator('[data-catalog="steam"]')).toHaveCount(0);
  await catalogAdd(page, 'sumatrapdf').click();
  await expect(page.getByTestId('app-count')).toHaveText('1 selected');
  await expect(catalogAdd(page, 'sumatrapdf')).toBeDisabled();

  await page.getByTestId('app-search').fill('');
  await page.getByTestId('app-category').locator('[data-category="gaming"]').click();
  await expect(page.getByTestId('app-category').locator('[data-category="gaming"]')).toHaveAttribute('aria-pressed', 'true');
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
  await go(page, 'review');
  const group = page.getByTestId('assets').locator('[data-asset-group="applications"]');
  await expect(group.locator('[data-asset]')).toHaveCount(9);
  const [dl] = await Promise.all([page.waitForEvent('download'), group.locator('[data-asset="winget-packages.json"] [data-action="download-asset"]').click()]);
  const native = JSON.parse(await readFile((await dl.path())!, 'utf8'));
  expect(native.Sources[0].Packages.map((p: { PackageIdentifier: string }) => p.PackageIdentifier)).toEqual(['Valve.Steam', 'Playnite.Playnite']);
});

test('application provisioning: WinGet import adds a profile without overwriting, export is valid WinGet JSON', async ({ page }) => {
  await setName(page, 'Alex');
  await go(page, 'applications');
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
  await go(page, 'applications');

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

  await go(page, 'accounts');
  await radio(page, 'accounts.accountGroup', 'Users').check();
  await expect(field(page, 'applications.enabled').locator('.issues .error')).toContainText('administrator account');
  await expect(page.locator('.sidebar a.nav-item[data-target="section-applications"] .nav-badge.err')).toBeVisible();
  await radio(page, 'accounts.accountGroup', 'Administrators').check();
  await go(page, 'review');

  const [dl] = await Promise.all([page.waitForEvent('download'), page.getByTestId('assets').locator('[data-asset="applications-config.json"] [data-action="download-asset"]').click()]);
  const cfg = JSON.parse(await readFile((await dl.path())!, 'utf8'));
  expect(cfg).toMatchObject({ restartPolicy: 'never', maxAttemptsPerPackage: 3 });
  expect(cfg.packages.map((p: { packageIdentifier: string }) => p.packageIdentifier)).toEqual(['Microsoft.WSL', 'Docker.DockerDesktop', 'Microsoft.VisualStudioCode']);
});

test('application selection survives Basic/Advanced switches, profile export/import, and reset', async ({ page }) => {
  await setName(page, 'Alex');
  await go(page, 'applications');
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
  await go(page, 'additionalSoftware');
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

// UI redesign: navigation, state across pages, themes, code viewer ------------------------------

test('sections are separate pages: current section highlighted, Previous/Next, values kept across navigation', async ({ page }) => {
  await expect(page.locator('#section-setup')).toBeVisible();
  await expect(page.locator('#section-accounts')).toBeHidden();
  await expect(page.locator('.sidebar a.nav-item[aria-current="page"]')).toHaveAttribute('data-target', 'section-setup');

  await page.locator('#section-setup [data-pager="next"]').click();
  await expect(page.locator('#section-accounts')).toBeVisible();
  await expect(page.locator('.sidebar a.nav-item[aria-current="page"]')).toHaveAttribute('data-target', 'section-accounts');
  await page.locator('input[name="accounts.personName"]').fill('Robin');

  await go(page, 'privacy');
  await checkbox(page, 'privacy.disableLocation').uncheck();
  await page.locator('#section-privacy [data-pager="prev"]').click();
  await expect(page.locator('#section-security')).toBeVisible();
  await page.goBack();
  await expect(page.locator('#section-privacy')).toBeVisible();
  await expect(checkbox(page, 'privacy.disableLocation')).not.toBeChecked();

  // Basic/Advanced never changes values, and a page hidden in Basic falls back to a visible one.
  await page.getByRole('button', { name: 'Advanced' }).click();
  await go(page, 'bloatware');
  await page.getByRole('button', { name: 'Basic' }).click();
  await expect(page.locator('#section-setup')).toBeVisible();
  await go(page, 'accounts');
  await expect(page.locator('input[name="accounts.personName"]')).toHaveValue('Robin');
  await expect(checkbox(page, 'privacy.disableLocation')).not.toBeChecked();

  // Sub-anchors open their page at the right place.
  await go(page, 'app-profiles');
  await expect(page.locator('#section-applications')).toBeVisible();
  await go(page, 'deployment-assets');
  await expect(page.locator('#section-review')).toBeVisible();
  await expect(page.getByTestId('summary')).toContainText('Robin-Computer');
});

test('appearance: dark by default, Light and System selectable and remembered', async ({ page }) => {
  const html = page.locator('html');
  await expect(html).toHaveAttribute('data-theme', 'dark');
  const bg = () => page.evaluate(() => getComputedStyle(document.body).backgroundColor);
  const dark = await bg();
  await page.getByRole('button', { name: 'Light appearance' }).click();
  await expect(html).toHaveAttribute('data-theme', 'light');
  expect(await bg()).not.toBe(dark);
  await page.reload();
  await expect(html).toHaveAttribute('data-theme', 'light');
  await page.getByRole('button', { name: 'System appearance' }).click();
  await expect(html).toHaveAttribute('data-theme', 'system');
  await page.getByRole('button', { name: 'Dark appearance' }).click();
  expect(await bg()).toBe(dark);
});

test('XML preview shows exactly the generated text, with line numbers kept outside it', async ({ page }) => {
  await setName(page, 'Alex');
  await go(page, 'review');
  const text = (await preview(page).textContent())!;
  expect(text.startsWith('<?xml')).toBe(true);
  await expect(preview(page).locator('.x-tag').first()).toBeVisible();
  const gutter = (await page.locator('.code-view .gutter').textContent())!;
  expect(gutter.split('\n').length).toBe(text.replace(/\r?\n$/, '').split(/\r?\n/).length);
  expect(text).not.toMatch(/^1\s*</);
});

test('mobile navigation drawer opens, navigates and closes without covering the form', async ({ page, isMobile }) => {
  test.skip(!isMobile, 'drawer is used on narrow screens only');
  const menu = page.locator('.menu-btn.in-bar');
  await expect(page.locator('.sidebar')).toBeHidden();
  await menu.click();
  await expect(menu).toHaveAttribute('aria-expanded', 'true');
  await expect(page.locator('.sidebar')).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(page.locator('.sidebar')).toBeHidden();
  await expect(menu).toHaveAttribute('aria-expanded', 'false');
  await go(page, 'wifi');
  await expect(page.locator('.sidebar')).toBeHidden();
  await expect(page.locator('.mobile-title')).toHaveText('Wi-Fi');
  await radio(page, 'wifi.mode', 'interactive').check();
});

test('Windows 11 requirement bypass controls are present (Advanced), off by default, and drive the XML', async ({ page }) => {
  await setName(page, 'Alex');
  await expect(checkbox(page, 'setup.bypassRequirementsCheck')).not.toBeChecked();
  await expect(checkbox(page, 'setup.bypassNetworkCheck')).not.toBeChecked();
  await expect(preview(page)).not.toContainText('LabConfig');
  await page.getByRole('button', { name: 'Advanced' }).click();
  await go(page, 'setup');
  await checkbox(page, 'setup.bypassRequirementsCheck').check();
  for (const v of ['BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck']) await expect(preview(page)).toContainText(v);
  await checkbox(page, 'setup.bypassNetworkCheck').check();
  await expect(preview(page)).toContainText('BypassNRO');
  await checkbox(page, 'setup.bypassRequirementsCheck').uncheck();
  await expect(preview(page)).not.toContainText('LabConfig');
});

// Phase 4: deployment package -----------------------------------------------------------------

test('deployment package: ZIP built offline in the browser, answer file at the root, exact selection, verified manifest', async ({ page, context }) => {
  const { readZip } = await import('../../src/engine/deployment/zip');
  await setName(page, 'Alex');
  await go(page, 'applications');
  await catalogAdd(page, 'git').click();
  await catalogAdd(page, '7zip').click();
  await apps(page).locator('[data-package="winget:7zip.7zip"] [data-action="app-remove"]').click();
  await context.setOffline(true);
  await go(page, 'deployment');
  await expect(page.getByTestId('package-status')).toContainText('Ready: windows-deployment-package.zip');
  await expect(page.getByTestId('package-contents')).toContainText('WindowsDeployment/setup.cmd');
  await expect(page.getByTestId('package-contents')).toContainText('WindowsDeployment/scripts/bootstrap/Initialize-Deployment.ps1');
  await expect(page.getByTestId('package-stages').locator('[data-stage="drivers"]')).toContainText('Not implemented');
  await expect(page.getByTestId('package-stages').locator('[data-stage="applications"]')).toContainText('signed-in user');

  const [dl] = await Promise.all([page.waitForEvent('download'), page.locator('#section-deployment [data-action="download-package"]').click()]);
  expect(dl.suggestedFilename()).toBe('windows-deployment-package.zip');
  const entries = readZip(new Uint8Array(await readFile((await dl.path())!)));
  const files = new Map(entries.map((e) => [e.path, new TextDecoder().decode(e.data)]));
  expect(entries[0]!.path).toBe('autounattend.xml');
  const manifest = JSON.parse(files.get('WindowsDeployment/deployment-manifest.json')!);
  expect(manifest.applications.packages.map((x: { packageIdentifier: string }) => x.packageIdentifier)).toEqual(['Git.Git']);
  expect(JSON.parse(files.get('WindowsDeployment/scripts/applications/winget-packages.json')!).Sources[0].Packages).toEqual([{ PackageIdentifier: 'Git.Git' }]);
  for (const f of manifest.files) expect(files.has(`WindowsDeployment/${f.path}`), f.path).toBe(true);

  await go(page, 'review');
  expect(files.get('autounattend.xml')!.replace(/\r\n/g, '\n').trim()).toBe((await preview(page).textContent())!.replace(/\r\n/g, '\n').trim());
  await expect(page.locator('#section-review [data-action="download-package"]')).toBeEnabled();
  await context.setOffline(false);
});

test('deployment package is blocked while the configuration has errors', async ({ page }) => {
  await go(page, 'deployment');
  await expect(page.getByTestId('package-status')).toContainText('Package blocked');
  await expect(page.locator('#section-deployment [data-action="download-package"]')).toBeDisabled();
  await setName(page, 'Alex');
  await go(page, 'deployment');
  await expect(page.locator('#section-deployment [data-action="download-package"]')).toBeEnabled();
});
