import { expect, test, type Page } from '@playwright/test';
import { readFile } from 'node:fs/promises';

/** Phase 7: the Prepare Installation USB entry point (the drive work itself happens in the local assistant). */

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

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    if (!sessionStorage.getItem('e2e-init')) {
      localStorage.setItem('wdb.mode', 'advanced');
      sessionStorage.setItem('e2e-init', '1');
    }
  });
  await page.goto('/');
});

test('Prepare Installation USB: explains the local workflows, states the media requirements, offers the assistant', async ({ page }) => {
  await go(page, 'usb-prep');
  const card = page.locator('.usb-prep-card');
  await expect(card).toContainText('this website never sees or changes a disk');
  await expect(card).toContainText('ERASES the USB flash drive you pick');
  await expect(card).toContainText('It does not mean the drive was booted');
  await expect(page.getByTestId('usb-requirements')).toContainText('Windows 11 Pro (EditionId Professional) for amd64');
  await expect(page.getByTestId('usb-backup-note')).toContainText('No settings backup is needed');
  await expect(card.getByRole('link', { name: 'official Microsoft download' })).toHaveAttribute('href', 'https://www.microsoft.com/software-download/windows11');
  // The existing manual route stays available.
  await expect(page.locator('[data-action="download-package"]').first()).toBeVisible();
  const [dl] = await Promise.all([page.waitForEvent('download'), page.locator('[data-action="download-usb-assistant"]').click()]);
  expect(dl.suggestedFilename()).toBe('usb-preparation-assistant.zip');
  const zip = await readFile((await dl.path())!);
  for (const name of ['WdbMediaAssistant.ps1', 'WdbMigration.ps1', 'Prepare-InstallationUSB.cmd', 'windows-releases.json', 'README-USB-Assistant.txt']) expect(zip.includes(Buffer.from(`usb-preparation-assistant/${name}`)), name).toBe(true);
  // The edition shown follows the configuration.
  await go(page, 'section-setup');
  await page.locator('select[name="setup.editionId"]').selectOption('home');
  await go(page, 'usb-prep');
  await expect(page.getByTestId('usb-requirements')).toContainText('Windows 11 Home (EditionId Core)');
});

test('Prepare Installation USB: readable in light and dark themes without horizontal scrolling', async ({ page }, info) => {
  for (const theme of ['Light', 'Dark']) {
    await page.getByRole('button', { name: `${theme} appearance` }).click();
    await go(page, 'usb-prep');
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    expect(overflow, theme).toBeLessThanOrEqual(1);
    const card = page.locator('.usb-prep-card');
    await card.scrollIntoViewIfNeeded();
    await info.attach(`usb-prep-${theme.toLowerCase()}`, { body: await card.screenshot(), contentType: 'image/png' });
    await card.screenshot({ path: info.outputPath(`usb-prep-${theme.toLowerCase()}.png`) });
  }
});
