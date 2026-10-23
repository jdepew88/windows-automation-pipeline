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

// This suite covers Advanced Configuration (every section) with the detailed catalog list, as
// before Phase 4.3; Quick Deployment and the other catalog layouts are covered in quick.spec.ts.
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
  await page.getByRole('button', { name: 'Advanced', exact: true }).click();
  await expect(radio(page, 'bloatware.Clipchamp', 'remove')).toBeChecked();
  await expect(radio(page, 'bloatware.Calculator', 'keep')).toBeChecked();
  await expect(radio(page, 'bloatware.Cortana', 'untouched')).toBeChecked();
  await expect(radio(page, 'bloatware.WindowsBackup', 'remove')).toBeDisabled();
  await go(page, 'accounts');
  // Phase 4.3: a one-line pointer on the account page; the full warning is in the considerations.
  await expect(page.getByTestId('autologon-note')).toBeVisible();
  await go(page, 'review');
  await expect(page.locator('[data-testid="advanced-considerations"] [data-consideration="autologon-admin"]')).toContainText('physical access');
});

test('starts with "owner"; an emptied name is required again; username and computer name derive live', async ({ page }) => {
  // Phase 5: new deployments are prefilled with the local username "owner".
  await go(page, 'accounts');
  await expect(page.locator('input[name="accounts.personName"]')).toHaveValue('owner');
  await expect(page.getByTestId('identity')).toContainText('Username: owner');
  await setName(page, '');
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

  await page.getByRole('button', { name: 'Advanced', exact: true }).click();
  await expect(field(page, 'scripts.system')).toBeVisible();
  await go(page, 'system');
  await checkbox(page, 'system.enableLongPaths').check();
  await go(page, 'taskbar');
  await radio(page, 'taskbar.search', 'hide').check();

  await page.getByRole('button', { name: 'Basic', exact: true }).click();
  await expect(field(page, 'system.enableLongPaths')).toBeHidden();
  await page.getByRole('button', { name: 'Advanced', exact: true }).click();
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
  await page.getByRole('button', { name: 'Advanced', exact: true }).click();
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
  await page.getByRole('button', { name: 'Advanced', exact: true }).click();
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
  await expect(page.locator('input[name="accounts.personName"]')).toHaveValue('owner');
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
  await page.getByRole('button', { name: 'Advanced', exact: true }).click();
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
  // Phase 9: new deployments let Windows Update offer compatible drivers.
  await expect(page.getByTestId('summary')).toContainText('On: drivers included, feature updates skipped');
  await expect(preview(page)).toContainText('WindowsUpdate\\Install-UpdateEngine.ps1');

  const assets = page.getByTestId('assets');
  await go(page, 'review');
  // 4 engine files + orchestration.json (the application assets of Core Essentials are a separate group since Phase 4.2).
  await expect(assets.locator('[data-asset-group="windows-update"] [data-asset]')).toHaveCount(4);
  await expect(assets.locator('[data-asset-group="orchestration"] [data-asset]')).toHaveCount(1);
  const [dl] = await Promise.all([page.waitForEvent('download'), assets.locator('[data-asset="config.json"] [data-action="download-asset"]').click()]);
  expect(dl.suggestedFilename()).toBe('config.json');
  const config = JSON.parse(await readFile((await dl.path())!, 'utf8'));
  expect(config).toMatchObject({ drivers: 'include', featureUpdates: 'skip', maxReboots: 10 });

  await page.getByRole('button', { name: 'Advanced', exact: true }).click();
  await go(page, 'windowsUpdate');
  await page.locator('input[name="windowsUpdate.maxReboots"]').fill('3');
  await page.locator('input[name="windowsUpdate.excludedKbs"]').fill('KB5034441');
  await go(page, 'review');
  const [dl2] = await Promise.all([page.waitForEvent('download'), assets.locator('[data-asset="config.json"] [data-action="download-asset"]').click()]);
  expect(JSON.parse(await readFile((await dl2.path())!, 'utf8'))).toMatchObject({ maxReboots: 3, excludedKbs: ['KB5034441'] });

  // The conflict with a policy that withholds drivers (an older profile's or an organization's choice).
  await go(page, 'updates');
  await checkbox(page, 'updates.excludeDrivers').check();
  await go(page, 'windowsUpdate');
  await radio(page, 'windowsUpdate.drivers', 'include').check();
  await expect(field(page, 'windowsUpdate.drivers').locator('.issues .error')).toContainText('conflicts');
  await expect(page.getByTestId('status')).toContainText('Cannot generate');
  await radio(page, 'windowsUpdate.drivers', 'followPolicy').check();
  await go(page, 'updates');
  await checkbox(page, 'updates.excludeDrivers').uncheck();
  await go(page, 'windowsUpdate');

  await checkbox(page, 'windowsUpdate.enabled').uncheck();
  await expect(field(page, 'windowsUpdate.drivers')).toBeHidden();
  await expect(assets).toContainText('None');
  // The engine is not embedded. (The orchestrator, present for Core Essentials, still lists the
  // stage as "enabled": false in its manifest and mentions it in its documentation comment.)
  await expect(preview(page)).not.toContainText('WindowsUpdate\\Install-UpdateEngine.ps1');
  await expect(preview(page)).not.toContainText('WindowsUpdateEngine.ps1"');
  await expect(page.getByTestId('summary')).toContainText('Off');
});

// Phase 3 ----------------------------------------------------------------------------------------

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

const appBox = (page: Page, id: string) => page.locator(`[data-app="${id}"] input[type=checkbox]`);
const showAll = (page: Page) => page.getByTestId('app-filter').locator('[data-filter="all"]').click();
const planIds = async (page: Page) => page.getByTestId('app-order').locator('li[data-package]').evaluateAll((els) => els.map((e) => e.getAttribute('data-package')));

test('application provisioning: Core Essentials by default; RustDesk is an honest manual follow-up', async ({ page }) => {
  await setName(page, 'Alex');
  await go(page, 'applications');
  await expect(checkbox(page, 'applications.enabled')).toBeChecked();
  await expect(checkbox(page, 'applications.profile.core')).toBeChecked();
  for (const id of ['everyday', 'gaming', 'developer', 'network-engineer', 'music', 'laptop', 'touch']) await expect(checkbox(page, `applications.profile.${id}`)).not.toBeChecked();
  await expect(page.getByTestId('app-count')).toHaveText('7 to install, 1 manual');
  for (const id of ['chrome', 'vlc', '7zip', 'teracopy', 'bitwarden', 'vcredist-x64', 'vcredist-x86']) await expect(appBox(page, id)).toBeChecked();
  await expect(page.locator('[data-app="rustdesk"]')).toContainText('Manual follow-up');
  await expect(page.getByTestId('app-manual-list')).toContainText('RustDesk');
  await expect(page.getByTestId('summary')).toContainText('7 package(s) via WinGet from Core Essentials, 1 manual follow-up');
  await expect(preview(page)).toContainText('Applications\\Install-ApplicationEngine.ps1');
});

test('quick start: Gaming, untick a launcher, add a PDF reader, download the USB package with exactly that plan', async ({ page }) => {
  await setName(page, 'Alex');
  await go(page, 'applications');
  await checkbox(page, 'applications.profile.gaming').check();
  await expect(appBox(page, 'steam')).toBeChecked();
  await expect(appBox(page, 'epic')).toBeChecked();
  await expect(appBox(page, 'battlenet')).not.toBeChecked();
  await appBox(page, 'epic').uncheck();
  await expect(page.locator('[data-app="epic"]')).toContainText('Unticked by you (default in Gaming)');
  await page.getByTestId('app-search').fill('pdf');
  await appBox(page, 'acrobat-reader').check();
  await page.getByTestId('app-search').fill('');
  await expect(page.getByTestId('app-removed')).toContainText('Epic Games Launcher');
  const ids = await planIds(page);
  expect(ids).toContain('winget:valve.steam');
  expect(ids).toContain('winget:adobe.acrobat.reader.64-bit');
  expect(ids).not.toContain('winget:epicgames.epicgameslauncher');

  await go(page, 'deployment');
  const [dl] = await Promise.all([page.waitForEvent('download'), page.locator('[data-action="download-package"]').first().click()]);
  const { readZip } = await import('../../src/engine/deployment/zip');
  const entry = readZip(new Uint8Array(await readFile((await dl.path())!))).find((e) => e.path === 'WindowsDeployment/scripts/applications/applications-config.json')!;
  const cfg = JSON.parse(new TextDecoder().decode(entry.data));
  expect(cfg.packages.map((p: { packageIdentifier: string }) => p.packageIdentifier)).toEqual(expect.arrayContaining(['Valve.Steam', 'Adobe.Acrobat.Reader.64-bit', 'Google.Chrome']));
  expect(cfg.packages.map((p: { packageIdentifier: string }) => p.packageIdentifier)).not.toContain('EpicGames.EpicGamesLauncher');
  expect(cfg.deselected.map((p: { packageIdentifier: string }) => p.packageIdentifier)).toEqual(['EpicGames.EpicGamesLauncher']);
  expect(cfg.manual.map((m: { key: string }) => m.key)).toEqual(['catalog:rustdesk']);
  expect(cfg.packages.map((p: { key: string }) => p.key)).toEqual(ids);
});

test('mobile devices: Android phone plus iPad recommends Apple Devices; it can be unticked; Apple Music stays optional', async ({ page }) => {
  await setName(page, 'Alex');
  await go(page, 'applications');
  await page.locator('[data-device="phone-android"]').check();
  await expect(page.getByTestId('app-device-note')).toContainText('Android');
  await expect(page.locator('[data-app="apple-devices"]')).toHaveCount(0);
  await page.locator('[data-device="ipad"]').check();
  await expect(appBox(page, 'apple-devices')).toBeChecked();
  await expect(page.locator('[data-app="apple-devices"]')).toContainText('Selected by iPhone / iPad');
  await expect(appBox(page, 'apple-music')).not.toBeChecked();
  await expect(page.locator('[data-app="icloud"]')).toContainText('Recommended by iPhone / iPad');
  await appBox(page, 'icloud').check();
  await expect(page.locator('[data-app="icloud"] .app-warning')).toContainText('very large amounts of data');
  await appBox(page, 'apple-devices').uncheck();
  await expect(appBox(page, 'apple-devices')).not.toBeChecked();
  await page.locator('[data-device="ipad"]').uncheck();
  await page.locator('[data-device="ipad"]').check();
  await expect(appBox(page, 'apple-devices')).not.toBeChecked();
});

test('antivirus: a second real-time antivirus cannot be ticked; Malwarebytes can, with a warning', async ({ page }) => {
  await setName(page, 'Alex');
  await go(page, 'applications');
  await showAll(page);
  await page.getByTestId('app-category').selectOption('security');
  await appBox(page, 'avast').check();
  await expect(appBox(page, 'avg')).toBeDisabled();
  await expect(appBox(page, 'avira')).toBeDisabled();
  await expect(page.locator('[data-app="avg"]')).toContainText('Cannot be combined with Avast One Free Antivirus');
  await appBox(page, 'malwarebytes').check();
  await expect(page.getByTestId('app-warnings')).toContainText('Malwarebytes and Avast One Free Antivirus are both selected');
  await expect(page.getByTestId('status')).toContainText('Ready');
});

test('antivirus conflicts imported from a profile file block generation with a clear message', async ({ page }) => {
  await setName(page, 'Alex');
  await go(page, 'applications');
  const file = JSON.stringify({
    format: 'windows-deployment-builder/app-profiles',
    formatVersion: 2,
    profiles: [{ id: 'two-av', name: 'Two AV', category: 'custom', description: '', builtin: false, inherits: [], packages: [
      { packageIdentifier: 'XPDNZJFNCR1B07', source: 'msstore', displayName: 'Avast', version: '', scope: '' },
      { packageIdentifier: 'XP8BX2DWV7TF50', source: 'msstore', displayName: 'AVG', version: '', scope: '' },
    ] }],
  });
  await page.getByTestId('app-import-input').setInputFiles({ name: 'two-av.json', mimeType: 'application/json', buffer: Buffer.from(file) });
  await expect(page.getByTestId('app-warnings').locator('[data-kind="conflict-group"]')).toContainText('keep only one');
  await expect(field(page, 'applications.selection').locator('.issues .error')).toContainText('real-time antivirus');
  await expect(page.getByTestId('status')).not.toContainText('Ready');
});

test('Network Engineer profile: the full workstation, dependency added, portable tools shown as portable', async ({ page }) => {
  await setName(page, 'Alex');
  await go(page, 'applications');
  await checkbox(page, 'applications.profile.network-engineer').check();
  for (const id of ['git', 'vscode', 'python-314', 'nodejs-lts', 'claude-code', 'claude-desktop', 'chatgpt', 'docker-desktop', 'wireshark', 'tailscale', 'wireguard', 'wiztree', 'hwinfo', 'rufus', 'ventoy', 'qbittorrent', 'sabnzbd', 'syncthing']) {
    await expect(appBox(page, id), id).toBeChecked();
  }
  await expect(page.locator('[data-app="wsl"]')).toContainText('Required by Docker Desktop');
  await expect(page.locator('[data-app="rufus"]')).toContainText('Portable');
  await expect(page.locator('[data-app="chatgpt"]')).toContainText('Microsoft Store');
  await expect(page.locator('[data-app="filezilla"]')).toContainText('Manual follow-up');
  await expect(appBox(page, 'quicklook')).not.toBeChecked();
  await expect(appBox(page, 'freefilesync')).not.toBeChecked();
  await page.getByTestId('app-filter').locator('[data-filter="excluded"]').click();
  await expect(page.getByTestId('app-catalog')).toContainText('WinDirStat');
});

test('Save as new profile: survives a page reload, re-applies exactly, can be renamed, exported and deleted', async ({ page }) => {
  await setName(page, 'Alex');
  await go(page, 'applications');
  await checkbox(page, 'applications.profile.gaming').check();
  await appBox(page, 'epic').uncheck();
  await page.locator('[data-device="phone-iphone"]').check();
  const before = (await planIds(page)).sort();
  page.once('dialog', (d) => d.accept("Aunt's Computer"));
  await page.locator('[data-action="app-save-new"]').click();
  await expect(checkbox(page, 'applications.profile.aunt-s-computer')).toBeChecked();
  expect((await planIds(page)).sort()).toEqual(before);

  await page.reload();
  await go(page, 'applications');
  const card = page.getByTestId('app-custom-profiles').locator('[data-profile="aunt-s-computer"]');
  await expect(card).toContainText("Aunt's Computer");
  await expect(checkbox(page, 'applications.profile.aunt-s-computer')).not.toBeChecked();
  await checkbox(page, 'applications.profile.core').uncheck();
  await checkbox(page, 'applications.profile.aunt-s-computer').check();
  expect((await planIds(page)).sort()).toEqual(before);

  page.once('dialog', (d) => d.accept('Customer Laptop'));
  await card.locator('[data-action="app-rename-profile"]').click();
  await expect(card).toContainText('Customer Laptop');
  const [dl] = await Promise.all([page.waitForEvent('download'), card.locator('[data-action="app-export-profile"]').click()]);
  const exported = JSON.parse(await readFile((await dl.path())!, 'utf8'));
  expect(exported).toMatchObject({ format: 'windows-deployment-builder/app-profiles', formatVersion: 2 });
  expect(exported.profiles[0]).toMatchObject({ name: 'Customer Laptop', inherits: ['core', 'gaming'], excluded: ['winget:epicgames.epicgameslauncher'], devices: { phone: 'iphone' } });
  expect(JSON.stringify(exported)).not.toMatch(/password|Alex/i);

  page.once('dialog', (d) => d.accept());
  await card.locator('[data-action="app-delete-profile"]').click();
  await expect(card).toHaveCount(0);
  await page.reload();
  await go(page, 'applications');
  await expect(page.getByTestId('app-custom-profiles').locator('[data-profile]')).toHaveCount(0);
  // Built-in templates are untouched.
  await expect(page.locator('[data-profile="gaming"]')).toContainText('2 apps');
});

test('application provisioning: WinGet import adds a profile without overwriting, export is valid WinGet JSON', async ({ page }) => {
  await setName(page, 'Alex');
  await go(page, 'applications');
  await page.getByTestId('app-import-input').setInputFiles({ name: 'office.json', mimeType: 'application/json', buffer: Buffer.from(wingetExport) });
  await expect(page.getByTestId('app-import-status')).toContainText('Imported office.json as profile "Imported: office"');
  await expect(page.getByTestId('app-import-status')).toContainText('Not A Valid Id');
  await expect(checkbox(page, 'applications.profile.imported-office')).toBeChecked();
  await expect(checkbox(page, 'applications.profile.core')).toBeChecked();
  // Git is new; VLC was already in Core Essentials and is installed once.
  await expect(page.getByTestId('app-count')).toHaveText('8 to install, 1 manual');

  const [dl] = await Promise.all([page.waitForEvent('download'), page.locator('[data-action="app-export-winget"]').click()]);
  expect(dl.suggestedFilename()).toBe('winget-packages.json');
  const out = JSON.parse(await readFile((await dl.path())!, 'utf8'));
  expect(out.$schema).toBe('https://aka.ms/winget-packages.schema.2.0.json');
  expect(out.Sources[0].SourceDetails.Identifier).toBe('Microsoft.Winget.Source_8wekyb3d8bbwe');
  const ids = out.Sources[0].Packages.map((p: { PackageIdentifier: string }) => p.PackageIdentifier);
  expect(ids).toEqual(expect.arrayContaining(['Git.Git', 'VideoLAN.VLC', 'Google.Chrome']));
  expect(ids).not.toContain('rustdesk');

  await page.getByTestId('app-import-input').setInputFiles({ name: 'evil.json', mimeType: 'application/json', buffer: Buffer.from('{"Sources":[{"SourceDetails":{"Name":"winget"},"Packages":[]}]}') });
  await expect(page.getByTestId('app-import-status')).toContainText('Could not import evil.json');
  await expect(page.getByTestId('app-count')).toHaveText('8 to install, 1 manual');
});

test('application provisioning (Advanced): package IDs, install order with dependencies, custom IDs, policies and validation', async ({ page }) => {
  await setName(page, 'Alex');
  await page.getByRole('button', { name: 'Advanced', exact: true }).click();
  await go(page, 'applications');
  await showAll(page);
  await appBox(page, 'docker-desktop').check();
  const ids = await planIds(page);
  expect(ids.indexOf('winget:microsoft.wsl')).toBeLessThan(ids.indexOf('winget:docker.dockerdesktop'));
  await expect(page.getByTestId('app-order')).toContainText('winget install --id Docker.DockerDesktop --exact --source winget --silent');
  await expect(page.locator('[data-app="rufus"] .ids')).toContainText('winget: Rufus.Rufus');

  await page.getByTestId('app-custom-id').locator('summary').click();
  await page.getByTestId('app-manual-id').fill('Foo Bar');
  await page.locator('[data-action="app-add-manual"]').click();
  await expect(page.getByTestId('app-manual-message')).toContainText('Not a valid winget identifier');
  await page.getByTestId('app-manual-id').fill('Microsoft.VisualStudioCode');
  await page.getByTestId('app-manual-version').fill('1.95.0');
  await page.locator('[data-action="app-add-manual"]').click();
  await expect(page.getByTestId('app-manual-message')).toContainText('Added');
  await expect(page.getByTestId('app-order')).toContainText('--version 1.95.0');
  // Adding an excluded app by exact ID is allowed and explained.
  await page.getByTestId('app-manual-id').fill('Brave.Brave');
  await page.getByTestId('app-manual-version').fill('');
  await page.locator('[data-action="app-add-manual"]').click();
  await expect(page.getByTestId('app-warnings')).toContainText('Brave.Brave is not in the curated catalog');

  await radio(page, 'applications.restartPolicy', 'never').check();
  await page.locator('input[name="applications.maxAttemptsPerPackage"]').fill('9');
  await expect(field(page, 'applications.maxAttemptsPerPackage').locator('.issues .error')).toContainText('between 1 and 5');
  await page.locator('input[name="applications.maxAttemptsPerPackage"]').fill('4');
  await expect(page.getByTestId('status')).toContainText('Ready');

  await go(page, 'accounts');
  await radio(page, 'accounts.accountGroup', 'Users').check();
  await expect(field(page, 'applications.enabled').locator('.issues .error')).toContainText('administrator account');
  await expect(page.locator('.sidebar a.nav-item[data-target="section-applications"] .nav-badge.err')).toBeVisible();
  await radio(page, 'accounts.accountGroup', 'Administrators').check();
  await go(page, 'review');

  const [dl] = await Promise.all([page.waitForEvent('download'), page.getByTestId('assets').locator('[data-asset="applications-config.json"] [data-action="download-asset"]').click()]);
  const cfg = JSON.parse(await readFile((await dl.path())!, 'utf8'));
  expect(cfg).toMatchObject({ restartPolicy: 'never', maxAttemptsPerPackage: 4 });
  const pk = cfg.packages.map((p: { packageIdentifier: string }) => p.packageIdentifier);
  expect(pk.indexOf('Microsoft.WSL')).toBeLessThan(pk.indexOf('Docker.DockerDesktop'));
  expect(cfg.packages.find((p: { packageIdentifier: string }) => p.packageIdentifier === 'Microsoft.VisualStudioCode').version).toBe('1.95.0');
});

test('application selection survives navigation, Basic/Advanced switches, profile export/import, and reset', async ({ page }) => {
  await setName(page, 'Alex');
  await go(page, 'applications');
  await appBox(page, 'chrome').uncheck();
  await checkbox(page, 'applications.profile.music').check();
  await go(page, 'review');
  await go(page, 'applications');
  await page.getByRole('button', { name: 'Advanced', exact: true }).click();
  await page.getByRole('button', { name: 'Basic', exact: true }).click();
  await expect(appBox(page, 'chrome')).not.toBeChecked();
  await expect(appBox(page, 'musicbee')).toBeChecked();
  // Adding another profile does not tick Chrome again.
  await checkbox(page, 'applications.profile.everyday').check();
  await expect(appBox(page, 'chrome')).not.toBeChecked();

  const [dl] = await Promise.all([page.waitForEvent('download'), page.locator('[data-action="export"]').click()]);
  const json = await readFile((await dl.path())!, 'utf8');
  expect(JSON.parse(json).applications.selection).toMatchObject({ selectedProfiles: ['core', 'music', 'everyday'], removed: ['winget:google.chrome'] });

  page.once('dialog', (d) => d.accept());
  await page.locator('[data-action="reset"]').click();
  await go(page, 'applications');
  await expect(appBox(page, 'chrome')).toBeChecked();
  await expect(checkbox(page, 'applications.profile.music')).not.toBeChecked();

  await page.getByTestId('import-input').setInputFiles({ name: 'p.json', mimeType: 'application/json', buffer: Buffer.from(json) });
  await go(page, 'applications');
  await expect(appBox(page, 'chrome')).not.toBeChecked();
  await expect(appBox(page, 'musicbee')).toBeChecked();
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
  await page.getByRole('button', { name: 'Advanced', exact: true }).click();
  await go(page, 'bloatware');
  await page.getByRole('button', { name: 'Basic', exact: true }).click();
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
  await page.getByRole('button', { name: 'Advanced', exact: true }).click();
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
  await checkbox(page, 'applications.profile.core').uncheck();
  await showAll(page);
  await appBox(page, 'git').check();
  await appBox(page, '7zip').check();
  await appBox(page, '7zip').uncheck();
  await context.setOffline(true);
  await go(page, 'deployment');
  await expect(page.getByTestId('package-status')).toContainText('Ready: windows-deployment-package.zip');
  await expect(page.getByTestId('package-contents')).toContainText('WindowsDeployment/setup.cmd');
  await expect(page.getByTestId('package-contents')).toContainText('WindowsDeployment/scripts/bootstrap/Initialize-Deployment.ps1');
  // Phase 8: the driver stage is part of new deployments.
  await expect(page.getByTestId('package-stages').locator('[data-stage="drivers"]')).toContainText('On');
  await expect(page.getByTestId('package-stages').locator('[data-stage="drivers"]')).toContainText('Runs as SYSTEM');
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
  await setName(page, '');
  await go(page, 'deployment');
  await expect(page.getByTestId('package-status')).toContainText('Package blocked');
  await expect(page.locator('#section-deployment [data-action="download-package"]')).toBeDisabled();
  await setName(page, 'Alex');
  await go(page, 'deployment');
  await expect(page.locator('#section-deployment [data-action="download-package"]')).toBeEnabled();
});

// Phase 5: reliability and recovery ---------------------------------------------------------------

test('Phase 5: Reliability & recovery settings have safe defaults and shape the package', async ({ page }) => {
  const { readZip } = await import('../../src/engine/deployment/zip');
  const download = async () => {
    await go(page, 'deployment');
    const [dl] = await Promise.all([page.waitForEvent('download'), page.locator('#section-deployment [data-action="download-package"]').click()]);
    return new Map(readZip(new Uint8Array(await readFile((await dl.path())!))).map((e) => [e.path, new TextDecoder().decode(e.data)]));
  };
  const tool = 'WindowsDeployment/scripts/recovery/DeploymentRecovery.ps1';
  // The group is part of the Advanced view (the Basic view keeps the safe defaults out of sight).
  await page.getByRole('button', { name: 'Advanced', exact: true }).click();
  await go(page, 'applications');
  await expect(page.locator('#section-applications').getByText('Reliability & recovery', { exact: true })).toBeVisible();
  for (const p of ['applications.recovery.automaticRetry', 'applications.recovery.continueAfterFailure', 'applications.recovery.includeRecoveryTool']) await expect(checkbox(page, p)).toBeChecked();
  await expect(page.locator('input[name="applications.maxAttemptsPerPackage"]')).toHaveValue('3');

  let files = await download();
  expect(files.has(tool)).toBe(true);
  expect(files.get('autounattend.xml')).toContain('C:\\Windows\\Setup\\Scripts\\Deployment\\scripts\\recovery\\DeploymentRecovery.ps1');
  let cfg = JSON.parse(files.get('WindowsDeployment/scripts/applications/applications-config.json')!);
  expect(cfg).toMatchObject({ engineVersion: '1.3.0', maxAttemptsPerPackage: 3, retry: { automatic: true, continueAfterFailure: true, baseDelaySeconds: 60, maxDelaySeconds: 900 } });
  let manifest = JSON.parse(files.get('WindowsDeployment/deployment-manifest.json')!);
  expect(manifest.recovery).toMatchObject({ tool: 'scripts/recovery/DeploymentRecovery.ps1', automaticRetry: true, maxAttemptsPerPackage: 3 });
  expect(files.get('WindowsDeployment/README.txt')).toContain('Manual recovery');

  await go(page, 'applications');
  await checkbox(page, 'applications.recovery.automaticRetry').uncheck();
  await checkbox(page, 'applications.recovery.continueAfterFailure').uncheck();
  await checkbox(page, 'applications.recovery.includeRecoveryTool').uncheck();
  // The choices survive a round trip through Quick Deployment (one shared configuration).
  await page.locator('.mode-switch [data-mode="quick"]').click();
  await page.locator('.mode-switch [data-mode="advanced"]').click();
  await go(page, 'applications');
  await expect(checkbox(page, 'applications.recovery.includeRecoveryTool')).not.toBeChecked();

  files = await download();
  expect(files.has(tool)).toBe(false);
  // Not embedded (the other scripts only check whether it exists).
  expect(files.get('autounattend.xml')).not.toContain('<File path="C:\\Windows\\Setup\\Scripts\\Deployment\\scripts\\recovery\\DeploymentRecovery.ps1"');
  cfg = JSON.parse(files.get('WindowsDeployment/scripts/applications/applications-config.json')!);
  expect(cfg.retry).toMatchObject({ automatic: false, continueAfterFailure: false });
  manifest = JSON.parse(files.get('WindowsDeployment/deployment-manifest.json')!);
  expect(manifest.recovery).toMatchObject({ tool: null, automaticRetry: false, maxAttemptsPerPackage: 1 });
  for (const f of manifest.files) expect(files.has(`WindowsDeployment/${f.path}`), f.path).toBe(true);
});
