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
  await expect(assets.locator('[data-asset]')).toHaveCount(4);
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
