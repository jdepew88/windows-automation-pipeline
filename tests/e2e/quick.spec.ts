import { expect, test, type Locator, type Page } from '@playwright/test';
import { readFile } from 'node:fs/promises';

/**
 * Phase 4.3: Quick Deployment, its synchronisation with Advanced Configuration, the four catalog
 * layouts and Final Review. Every journey ends with the real ZIP, read back and checked.
 */

const wiz = (page: Page) => page.getByTestId('wizard');
const tile = (page: Page, id: string): Locator => wiz(page).locator(`[data-app="${id}"] input`);
const step = (page: Page, id: string) => wiz(page).locator(`.wiz-step[data-step="${id}"]`);

/** Opens an Advanced section through the sidebar (through the navigation drawer on narrow screens). */
async function adv(page: Page, target: string) {
  const menu = page.locator('.menu-btn.in-bar');
  if ((await menu.isVisible()) && (await menu.getAttribute('aria-expanded')) !== 'true') await menu.click();
  await page.locator(`.sidebar a.nav-item[data-target="${target}"]`).click();
  await expect(page.locator(`#${target}`)).toBeVisible();
}

async function next(page: Page, where: 'top' | 'bottom' = 'top') {
  await wiz(page).locator(`[data-wiz="${where}-next"]`).click();
}

async function readPackage(page: Page) {
  const [dl] = await Promise.all([page.waitForEvent('download'), wiz(page).locator('[data-action="wiz-generate"]').click()]);
  expect(dl.suggestedFilename()).toBe('windows-deployment-package.zip');
  const { readZip } = await import('../../src/engine/deployment/zip');
  const entries = readZip(new Uint8Array(await readFile((await dl.path())!)));
  const text = (path: string) => new TextDecoder().decode(entries.find((e) => e.path === path)!.data);
  const json = (path: string) => JSON.parse(text(path));
  return { entries, text, json, config: json('WindowsDeployment/scripts/applications/applications-config.json'), manifest: json('WindowsDeployment/deployment-manifest.json'), xml: text('autounattend.xml') };
}

const ids = (list: { packageIdentifier: string }[]) => list.map((p) => p.packageIdentifier);

async function ackAll(page: Page) {
  for (const box of await wiz(page).locator('[data-ack]').all()) await box.check();
}

async function noHorizontalScroll(page: Page) {
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBe(true);
}

test.beforeEach(async ({ page }) => {
  await page.goto('/');
});

test('opens in Quick Deployment with Windows 11 Pro, x64 and the owner update preference; Advanced stays one click away', async ({ page }) => {
  await expect(wiz(page)).toBeVisible();
  await expect(page.locator('.mode-switch [data-mode="quick"]')).toHaveAttribute('aria-pressed', 'true');
  await expect(wiz(page).getByTestId('wizard-count')).toHaveText('Step 1 of 5 · 4 remaining');
  await expect(wiz(page).getByText('Local account username', { exact: true })).toBeVisible();
  // Phase 5: new deployments start with the local username "owner"; the computer name follows until edited.
  await expect(wiz(page).getByTestId('wiz-username')).toHaveValue('owner');
  await expect(wiz(page).getByTestId('wiz-computername')).toHaveValue('owner-Computer');
  await wiz(page).locator('[data-testid="wiz-windows"] summary').click();
  await expect(wiz(page).getByTestId('wiz-edition')).toHaveValue('pro');
  await expect(wiz(page).getByTestId('wiz-arch')).toHaveText(/^x64/);
  await expect(wiz(page).getByTestId('wiz-region')).toBeChecked();
  await expect(wiz(page).getByTestId('wiz-update-notify')).toBeChecked();
  await expect(wiz(page).getByTestId('wiz-privacy')).toContainText('Owner privacy defaults');
  // Every Advanced section is still there.
  await page.locator('.mode-switch [data-mode="advanced"]').click();
  await expect(page.locator('#section-setup')).toBeVisible();
  await expect(page.locator('.sidebar a.nav-item')).toHaveCount(await page.locator('.sidebar a.nav-item').count());
  expect(await page.locator('.sidebar a.nav-item').count()).toBeGreaterThanOrEqual(24);
  await expect(page.getByTestId('wizard')).toHaveCount(0);
});

test('top and bottom Next share one validation; the Applications shortcut cannot skip a missing username', async ({ page }) => {
  await expect(step(page, 'identity')).toHaveAttribute('data-status', 'complete');
  await wiz(page).getByTestId('wiz-username').fill('');
  await expect(step(page, 'identity')).toHaveAttribute('data-status', 'incomplete');
  for (const b of ['top-next', 'bottom-next', 'go-apps', 'go-review']) {
    await wiz(page).locator(`[data-wiz="${b}"]`).click();
    await expect(wiz(page).getByTestId('wizard-blocked')).toBeVisible();
    await expect(wiz(page)).toHaveAttribute('data-step', 'identity');
  }
  await expect(wiz(page).getByTestId('wiz-username-issues')).toContainText('Enter a name for the local account');
  await wiz(page).getByTestId('wiz-username').fill('Alex');
  await expect(wiz(page).getByTestId('wiz-computername')).toHaveValue('Alex-Computer');
  await expect(step(page, 'identity')).toHaveAttribute('data-status', 'complete');
  await next(page, 'bottom');
  await expect(wiz(page)).toHaveAttribute('data-step', 'type');
  await expect(wiz(page).getByTestId('wizard-count')).toHaveText('Step 2 of 5 · 3 remaining');
  await wiz(page).locator('[data-wiz="top-back"]').click();
  await expect(wiz(page)).toHaveAttribute('data-step', 'identity');
  await wiz(page).locator('[data-wiz="go-apps"]').click();
  await expect(wiz(page)).toHaveAttribute('data-step', 'apps');
  await expect(step(page, 'type')).toHaveAttribute('data-status', 'defaults');
  await expect(step(page, 'network')).toHaveAttribute('data-status', 'defaults');
  // An invalid computer name blocks too, and is reported at the exact field.
  await step(page, 'identity').locator('button').click();
  await wiz(page).getByTestId('wiz-computername').fill('12345');
  await expect(step(page, 'identity')).toHaveAttribute('data-status', 'attention');
  await wiz(page).locator('[data-wiz="go-review"]').click();
  await expect(wiz(page)).toHaveAttribute('data-step', 'identity');
  await expect(wiz(page).getByTestId('wiz-computername-issues')).toContainText('digits only');
  await wiz(page).locator('[data-action="wiz-computer-default"]').click();
  await expect(wiz(page).getByTestId('wiz-computername')).toHaveValue('Alex-Computer');
});

test('Journey A: ordinary home user, defaults throughout, exact ZIP', async ({ page }) => {
  await wiz(page).getByTestId('wiz-username').fill('Alex');
  await next(page);
  await next(page);
  await expect(wiz(page).getByTestId('wiz-wifi-interactive')).toBeChecked();
  await next(page);
  await expect(tile(page, 'chrome')).toBeChecked();
  await next(page);
  const review = wiz(page).getByTestId('final-review');
  await expect(review.getByTestId('review-computer')).toContainText('Alex-Computer');
  await expect(review.getByTestId('review-computer')).toContainText('Windows 11 Pro');
  await expect(review.getByTestId('review-network')).toContainText('Not configured');
  await expect(review.getByTestId('review-updates')).toContainText('ask before installing');
  // Phase 10: RustDesk is a Core Essentials recommendation, not a default.
  await expect(review.getByTestId('review-apps')).not.toContainText('RustDesk');
  await expect(review.locator('[data-consideration="generic-key"]')).toContainText('does not license or activate');
  await expect(review.locator('[data-consideration="wifi-secret"]')).toHaveCount(0);
  // The empty-password administrator needs one confirmation.
  await expect(review.locator('[data-action="wiz-generate"]')).toBeDisabled();
  await expect(step(page, 'review')).toHaveAttribute('data-status', 'incomplete');
  await review.locator('[data-ack="autologon-admin"]').check();
  await expect(step(page, 'review')).toHaveAttribute('data-status', 'complete');
  const zip = await readPackage(page);
  expect(zip.xml).toContain('<ComputerName>Alex-Computer</ComputerName>');
  expect(zip.xml).toContain('VK7JG-NPHTM-C97JM-9MPGT-3V66T'); // Windows 11 Pro generic key
  expect(zip.manifest.windows.architectures).toEqual(['amd64']);
  expect(zip.manifest.updatePolicy.values).toEqual({ NoAutoUpdate: 0, AUOptions: 3 });
  expect(ids(zip.config.packages)).toEqual(expect.arrayContaining(['Google.Chrome', 'VideoLAN.VLC', '7zip.7zip', 'CodeSector.TeraCopy', 'Bitwarden.Bitwarden', 'Microsoft.VCRedist.2015+.x64', 'Microsoft.VCRedist.2015+.x86']));
  expect(zip.config.manual).toEqual([]);
  expect(zip.xml).not.toMatch(/<File path="[^"]*(Wifi\.xml|Add-WifiProfile\.ps1)"/);
  // The acknowledgement is remembered for this session.
  await wiz(page).locator('[data-wiz="top-back"]').click();
  await next(page);
  await expect(wiz(page).locator('[data-ack="autologon-admin"]')).toBeChecked();
});

test('Journey B: gaming customer; untick Epic, add Discord, survive a trip to Advanced', async ({ page }) => {
  await wiz(page).getByTestId('wiz-username').fill('Sam');
  await next(page);
  await wiz(page).locator('[data-type="gaming"] input').check();
  await expect(step(page, 'type')).toHaveAttribute('data-status', 'customized');
  await next(page);
  await next(page);
  await expect(tile(page, 'steam')).toBeChecked();
  await expect(tile(page, 'epic')).toBeChecked();
  await wiz(page).locator('[data-app="epic"]').click();
  await expect(tile(page, 'epic')).not.toBeChecked();
  await wiz(page).getByTestId('app-search').fill('discord');
  await wiz(page).locator('[data-app="discord"]').click();
  await expect(tile(page, 'discord')).toBeChecked();
  await page.locator('.mode-switch [data-mode="advanced"]').click();
  await adv(page, 'section-applications');
  await expect(page.locator('#section-applications [data-app="epic"] input')).not.toBeChecked();
  await expect(page.locator('#section-applications [data-app="discord"] input')).toBeChecked();
  await page.locator('.mode-switch [data-mode="quick"]').click();
  await expect(wiz(page)).toHaveAttribute('data-step', 'apps');
  await wiz(page).getByTestId('app-search').fill('');
  await expect(tile(page, 'steam')).toBeChecked();
  await expect(tile(page, 'epic')).not.toBeChecked();
  await expect(tile(page, 'discord')).toBeChecked();
  await expect(wiz(page).locator('[data-app="epic"]')).toHaveAttribute('title', /Unticked by you/);
  await next(page);
  await ackAll(page);
  const zip = await readPackage(page);
  expect(ids(zip.config.packages)).toEqual(expect.arrayContaining(['Valve.Steam', 'Discord.Discord']));
  expect(ids(zip.config.packages)).not.toContain('EpicGames.EpicGamesLauncher');
  expect(ids(zip.config.deselected)).toEqual(['EpicGames.EpicGamesLauncher']);
});

test('Journey C: technician workstation; logo grid, detailed list, search, override, save, reload, load', async ({ page }) => {
  await wiz(page).getByTestId('wiz-username').fill('Joe');
  await next(page);
  await wiz(page).locator('[data-type="network-engineer"] input').check();
  await next(page);
  await next(page);
  await wiz(page).locator('[data-view-mode="logos"]').click();
  await expect(wiz(page).locator('.app-items.view-logos').first()).toBeVisible();
  await expect(wiz(page).locator('[data-app="wireshark"] .tile-name')).toHaveCount(0);
  await expect(tile(page, 'wireshark')).toHaveAttribute('aria-label', 'Wireshark');
  await wiz(page).locator('[data-view-mode="detailed"]').click();
  await wiz(page).getByTestId('app-search').fill('Wireshark');
  await expect(wiz(page).locator('[data-app="wireshark"]')).toContainText('Selected by Network Engineer / Technician');
  await tile(page, 'wireshark').uncheck();
  await wiz(page).getByTestId('app-search').fill('nmap');
  await tile(page, 'nmap').check();
  await wiz(page).getByTestId('app-search').fill('');
  const before = (await wiz(page).locator('[data-testid="app-order"] li[data-package]').evaluateAll((els) => els.map((e) => e.getAttribute('data-package') ?? ''))).sort();
  expect(before).toContain('winget:insecure.nmap');
  expect(before).not.toContain('winget:wiresharkfoundation.wireshark');
  page.once('dialog', (d) => d.accept('Tech Bench'));
  await wiz(page).locator('[data-action="app-save-new"]').click();
  await page.reload();
  await expect(wiz(page)).toBeVisible();
  await wiz(page).getByTestId('wiz-username').fill('Joe');
  await next(page);
  const saved = wiz(page).locator('.type-card', { hasText: 'Tech Bench' });
  await saved.locator('input').check();
  await next(page);
  await next(page);
  const after = (await wiz(page).locator('[data-testid="app-order"] li[data-package]').evaluateAll((els) => els.map((e) => e.getAttribute('data-package') ?? ''))).sort();
  expect(after).toEqual(before);
  await next(page);
  await ackAll(page);
  const zip = await readPackage(page);
  expect(zip.config.packages.map((p: { key: string }) => p.key).sort()).toEqual(before.filter((k) => !k.startsWith('catalog:')).sort());
  expect(ids(zip.config.packages)).toContain('Insecure.Nmap');
  expect(ids(zip.config.packages)).not.toContain('WiresharkFoundation.Wireshark');
});

test('Journey D: laptop with Android phone and iPad, location allowed, Wi-Fi configured with consent', async ({ page }) => {
  await wiz(page).getByTestId('wiz-username').fill('Riley');
  await next(page);
  await wiz(page).locator('[data-type="laptop"] input').check();
  await wiz(page).locator('[data-device="phone-android"]').check();
  await wiz(page).locator('[data-device="ipad"]').check();
  await expect(wiz(page).getByTestId('wiz-device-note')).toContainText('iPhone / iPad');
  await expect(wiz(page).getByTestId('wiz-device-note')).toContainText('Android');
  await wiz(page).getByTestId('wiz-location-toggle').check();
  await next(page);
  await wiz(page).getByTestId('wiz-wifi-parameters').check();
  await next(page);
  // Missing SSID and password are reported and block the next step.
  await expect(wiz(page)).toHaveAttribute('data-step', 'network');
  await expect(wiz(page).getByTestId('wiz-ssid-issues')).toContainText('SSID');
  await expect(wiz(page).getByTestId('wiz-wifi-password-issues')).toContainText('password');
  const ssid = 'Café "Guest" & <5G>';
  await wiz(page).getByTestId('wiz-ssid').fill(ssid);
  await wiz(page).getByTestId('wiz-wifi-password').fill('p@ss&<word>"1');
  await expect(wiz(page).getByTestId('wiz-wifi-password')).toHaveAttribute('type', 'password');
  await wiz(page).getByTestId('wiz-wifi-show').click();
  await expect(wiz(page).getByTestId('wiz-wifi-password')).toHaveAttribute('type', 'text');
  await wiz(page).getByTestId('wiz-wifi-show').click();
  await expect(wiz(page).getByTestId('wiz-wifi-password')).toHaveAttribute('type', 'password');
  await wiz(page).locator('.wifi-more summary').click();
  await wiz(page).getByTestId('wiz-wifi-hidden').check();
  await next(page);
  await expect(tile(page, 'apple-devices')).toBeChecked();
  await expect(tile(page, 'batteryinfoview')).toBeChecked();
  await next(page);
  const review = wiz(page).getByTestId('final-review');
  await expect(review.getByTestId('review-network')).toContainText(ssid);
  await expect(review.getByTestId('review-network')).toContainText('Password entered (not shown)');
  await expect(review.getByTestId('review-network')).not.toContainText('p@ss');
  await expect(review.getByTestId('review-privacy')).toContainText('Allowed');
  await expect(review.locator('[data-consideration="wifi-secret"]')).toContainText('plain text');
  await review.locator('[data-ack="autologon-admin"]').check();
  await expect(review.locator('[data-action="wiz-generate"]')).toBeDisabled();
  await review.locator('[data-ack="wifi-secret"]').check();
  const zip = await readPackage(page);
  expect(zip.xml).toContain('Add-WifiProfile.ps1');
  expect(zip.xml).toContain('&lt;nonBroadcast&gt;true&lt;/nonBroadcast&gt;');
  expect(zip.xml).not.toContain('DisableLocation');
  expect(ids(zip.config.packages)).toEqual(expect.arrayContaining(['9NP83LWLPZ9K', 'NirSoft.BatteryInfoView']));
  // The password is in the answer file only: not in the exported settings, not in browser storage.
  expect(zip.text('WindowsDeployment/profiles/windows-settings.json')).not.toContain('p@ss');
  expect(await page.evaluate(() => JSON.stringify({ ...localStorage }))).not.toContain('p@ss');
  expect(zip.manifest.answerFile.containsSecrets).toBe(true);
});

test('Journey E: Advanced first; privacy, edition and update policy changes are shown in Quick and never reset', async ({ page }) => {
  await page.locator('.mode-switch [data-mode="advanced"]').click();
  await adv(page, 'section-privacy');
  await page.locator('input[type=checkbox][name="privacy.disableAdvertisingId"]').uncheck();
  await adv(page, 'section-setup');
  await page.locator('select[name="setup.editionId"]').selectOption('pro_workstations');
  await adv(page, 'section-updates');
  await page.locator('input[type=radio][name="updates.mode"][value="windowsDefault"]').check();
  await adv(page, 'section-accounts');
  await page.locator('input[name="accounts.personName"]').fill('Kim');
  await page.locator('.mode-switch [data-mode="quick"]').click();
  await expect(wiz(page).getByTestId('wiz-username')).toHaveValue('Kim');
  await wiz(page).locator('[data-testid="wiz-windows"] summary').click();
  await expect(wiz(page).getByTestId('wiz-edition')).toHaveValue('pro_workstations');
  await expect(wiz(page).getByTestId('wiz-update-recommended')).toBeChecked();
  await expect(wiz(page).getByTestId('wiz-windows')).toContainText('Customized in Advanced Settings');
  await wiz(page).locator('[data-wiz="go-review"]').click();
  await expect(wiz(page).getByTestId('review-privacy')).toContainText('advertising ID');
  await expect(wiz(page).getByTestId('review-computer')).toContainText('Pro for Workstations');
  await expect(wiz(page).getByTestId('review-updates')).toContainText('Windows recommended defaults');
  await expect(wiz(page).locator('[data-consideration="update-approval"]')).toHaveCount(0);
  await page.locator('.mode-switch [data-mode="advanced"]').click();
  await adv(page, 'section-privacy');
  await expect(page.locator('input[type=checkbox][name="privacy.disableAdvertisingId"]')).not.toBeChecked();
  await adv(page, 'section-setup');
  await expect(page.locator('select[name="setup.editionId"]')).toHaveValue('pro_workstations');
  await adv(page, 'section-updates');
  await expect(page.locator('input[type=radio][name="updates.mode"][value="windowsDefault"]')).toBeChecked();
});

test('Journey F: long names in every layout; selections never change when the layout does', async ({ page }) => {
  await wiz(page).getByTestId('wiz-username').fill('Lee');
  await wiz(page).locator('[data-wiz="go-apps"]').click();
  await wiz(page).locator('[data-filter="all"]').click();
  await expect(wiz(page).locator('[data-app="vcredist-x64"]')).toHaveAttribute('title', /Visual C\+\+ Redistributable 2015-2026 \(x64\)/);
  await wiz(page).locator('[data-app="temurin-25-jdk"]').click();
  await wiz(page).locator('[data-app="dell-command-update"]').click();
  await wiz(page).locator('[data-app="vlc"]').click();
  const state = async () => Object.fromEntries(await wiz(page).locator('[data-app]').evaluateAll((els) => els.map((e) => [e.getAttribute('data-app'), (e.querySelector('input') as HTMLInputElement).checked])));
  const reference = await state();
  expect(reference['temurin-25-jdk']).toBe(true);
  expect(reference['dell-command-update']).toBe(true);
  expect(reference.vlc).toBe(false);
  for (const v of ['compact', 'detailed', 'logos', 'grid']) {
    await wiz(page).locator(`[data-view-mode="${v}"]`).click();
    await expect(wiz(page).locator(`.app-items.view-${v}`).first()).toBeVisible();
    expect(await state()).toEqual(reference);
    await noHorizontalScroll(page);
  }
  // A long name wraps to two lines in the grid instead of stretching the tile.
  const box = await wiz(page).locator('[data-app="temurin-25-jdk"]').boundingBox();
  const small = await wiz(page).locator('[data-app="git"]').boundingBox();
  expect(Math.abs(box!.width - small!.width)).toBeLessThan(2);
  // Layout is a remembered display preference, not configuration.
  await wiz(page).locator('[data-view-mode="compact"]').click();
  await page.reload();
  await wiz(page).getByTestId('wiz-username').fill('Lee');
  await wiz(page).locator('[data-wiz="go-apps"]').click();
  await expect(wiz(page).locator('[data-view-mode="compact"]')).toHaveAttribute('aria-pressed', 'true');
});

test('catalog: logos load from bundled files and fall back to an initials tile; keyboard selection works', async ({ page }) => {
  await page.route('**/app-icons/steam.svg', (r) => r.abort());
  await wiz(page).getByTestId('wiz-username').fill('Ari');
  await wiz(page).locator('[data-wiz="go-apps"]').click();
  await wiz(page).locator('[data-filter="all"]').click();
  await expect(wiz(page).locator('[data-app="chrome"] img')).toHaveAttribute('src', /app-icons\/chrome\.svg$/);
  await wiz(page).locator('[data-app="steam"]').scrollIntoViewIfNeeded();
  await expect(wiz(page).locator('[data-app="steam"] [data-logo="fallback"]')).toHaveText('S');
  await expect(wiz(page).locator('[data-app="teracopy"] [data-logo="fallback"]')).toHaveText('T');
  await tile(page, 'git').focus();
  await page.keyboard.press('Space');
  await expect(tile(page, 'git')).toBeChecked();
  await expect(wiz(page).locator('[data-app="git"]')).toHaveClass(/\bon\b/);
  await expect(wiz(page).getByTestId('app-selected')).toContainText('selected');
  await expect(wiz(page).getByTestId('app-catalog-size')).toContainText('190');
  await expect(wiz(page).getByTestId('app-manual-count')).toContainText('0');
});

test('region pages and laptop location map onto the Advanced settings', async ({ page }) => {
  await wiz(page).getByTestId('wiz-username').fill('Alex');
  await wiz(page).locator('[data-testid="wiz-windows"] summary').click();
  await wiz(page).getByTestId('wiz-region').uncheck();
  await next(page);
  await expect(wiz(page).getByTestId('wiz-location')).toBeEmpty();
  await wiz(page).locator('[data-type="laptop"] input').check();
  await expect(wiz(page).getByTestId('wiz-location-toggle')).not.toBeChecked();
  await wiz(page).getByTestId('wiz-location-toggle').check();
  await wiz(page).locator('[data-type="laptop"] input').uncheck();
  await expect(wiz(page).getByTestId('wiz-location')).toContainText('Customized in Advanced Settings');
  await page.locator('.mode-switch [data-mode="advanced"]').click();
  await adv(page, 'section-setup');
  await expect(page.locator('input[type=radio][name="setup.languageMode"][value="interactive"]')).toBeChecked();
  await adv(page, 'section-privacy');
  await expect(page.locator('input[type=checkbox][name="privacy.disableLocation"]')).not.toBeChecked();
});

test('Wi-Fi in Advanced: SSID and password on the same page, masked, consent before the package', async ({ page }) => {
  await page.locator('.mode-switch [data-mode="advanced"]').click();
  await adv(page, 'section-accounts');
  await page.locator('input[name="accounts.personName"]').fill('Alex');
  await adv(page, 'section-wifi');
  await page.locator('input[type=radio][name="wifi.mode"][value="parameters"]').check();
  await expect(page.locator('input[name="wifi.ssid"]')).toBeVisible();
  await expect(page.locator('input[name="wifi.password"]')).toHaveAttribute('type', 'password');
  await page.locator('input[name="wifi.ssid"]').fill('Office');
  await page.locator('input[name="wifi.password"]').fill('advanced-secret-1');
  await page.locator('.mode-switch [data-mode="quick"]').click();
  await wiz(page).locator('[data-wiz-step], .wiz-step[data-step="network"] button').first().click();
  await expect(wiz(page).getByTestId('wiz-ssid')).toHaveValue('Office');
  await expect(wiz(page).getByTestId('wiz-wifi-password')).toHaveValue('advanced-secret-1');
  await page.locator('.mode-switch [data-mode="advanced"]').click();
  await adv(page, 'section-deployment');
  let asked = 0;
  page.on('dialog', (d) => {
    asked++;
    expect(d.message()).toContain('Wi-Fi password in plain text');
    void (asked === 1 ? d.dismiss() : d.accept());
  });
  await page.locator('#section-deployment [data-action="download-package"]').click();
  expect(asked).toBe(1);
  const [dl] = await Promise.all([page.waitForEvent('download'), page.locator('#section-deployment [data-action="download-package"]').click()]);
  expect(dl.suggestedFilename()).toBe('windows-deployment-package.zip');
  expect(asked).toBe(2);
  // Confirmed once per session: no third question.
  await Promise.all([page.waitForEvent('download'), page.locator('#section-deployment [data-action="download-xml-only"]').click()]);
  expect(asked).toBe(2);
  // Exports leave the password out unless explicitly included.
  const [ex] = await Promise.all([page.waitForEvent('download'), page.locator('[data-action="export"]').click()]);
  expect(await readFile((await ex.path())!, 'utf8')).not.toContain('advanced-secret-1');
});

test('no horizontal scroll on any wizard step', async ({ page }) => {
  await wiz(page).getByTestId('wiz-username').fill('Alexandria-Long');
  for (const s of ['identity', 'type', 'network', 'apps', 'review']) {
    await step(page, s).locator('button').click();
    await expect(wiz(page)).toHaveAttribute('data-step', s);
    await noHorizontalScroll(page);
  }
});

test('catalog filters: profile defaults include unticked defaults; selections survive search and category filters', async ({ page }) => {
  await wiz(page).getByTestId('wiz-username').fill('Alex');
  await next(page);
  await wiz(page).locator('[data-type="gaming"] input').check();
  await wiz(page).locator('[data-wiz="go-apps"]').click();
  await wiz(page).locator('[data-app="epic"]').click();
  await wiz(page).locator('[data-filter="defaults"]').click();
  await expect(wiz(page).locator('[data-app="steam"]')).toBeVisible();
  await expect(wiz(page).locator('[data-app="epic"]')).toHaveAttribute('data-state', 'deselected');
  await expect(wiz(page).locator('[data-app="discord"]')).toHaveCount(0);
  await wiz(page).locator('[data-filter="recommended"]').click();
  await expect(wiz(page).locator('[data-app="discord"]')).toHaveAttribute('data-state', 'recommended');
  await wiz(page).locator('[data-filter="all"]').click();
  await wiz(page).getByTestId('app-category').selectOption('gaming');
  await expect(tile(page, 'steam')).toBeChecked();
  await expect(tile(page, 'epic')).not.toBeChecked();
  await wiz(page).getByTestId('app-category').selectOption('');
  await expect(tile(page, 'chrome')).toBeChecked();
  await expect(tile(page, 'epic')).not.toBeChecked();
});
