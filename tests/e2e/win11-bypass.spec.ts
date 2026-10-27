import { expect, test, type Page } from '@playwright/test';
import { readFile } from 'node:fs/promises';

/**
 * Quick Deployment step 1 › Windows settings: the three Windows 11 hardware-check bypasses sit
 * directly below the edition, start off, survive Back/Next and reach the downloaded answer file.
 * Advanced › Account: a local account without an initial password.
 */

const wiz = (page: Page) => page.getByTestId('wizard');
const BOXES = ['bypassTpmCheck', 'bypassCpuCheck', 'bypassSecureBootCheck'] as const;
const box = (page: Page, key: (typeof BOXES)[number]) => wiz(page).getByTestId(`wiz-${key}`);

async function openWindows(page: Page) {
  const details = wiz(page).getByTestId('wiz-windows');
  if ((await details.getAttribute('open')) === null) await details.locator('summary').click();
}

async function readXml(page: Page) {
  for (const b of await wiz(page).locator('[data-ack]').all()) await b.check();
  const [dl] = await Promise.all([page.waitForEvent('download'), wiz(page).locator('[data-action="wiz-generate"]').click()]);
  const { readZip } = await import('../../src/engine/deployment/zip');
  const entries = readZip(new Uint8Array(await readFile((await dl.path())!)));
  return new TextDecoder().decode(entries.find((e) => e.path === 'autounattend.xml')!.data);
}

test.beforeEach(async ({ page }) => {
  await page.goto('/');
});

test('the three bypasses sit directly below the edition and start off', async ({ page }) => {
  await openWindows(page);
  const edition = wiz(page).getByTestId('wiz-edition');
  const group = wiz(page).getByTestId('wiz-bypass');
  await expect(group).toBeVisible();
  // Same field as the edition picker, right after it.
  await expect(edition.locator('xpath=..').getByTestId('wiz-bypass')).toHaveCount(1);
  await expect(group.locator('label')).toHaveText(['Bypass TPM 2.0 requirement', 'Bypass unsupported CPU check', 'Bypass Secure Boot requirement']);
  const e = (await edition.boundingBox())!;
  const g = (await group.boundingBox())!;
  expect(g.y).toBeGreaterThan(e.y + e.height - 1);
  for (const k of BOXES) await expect(box(page, k)).not.toBeChecked();
});

test('each bypass is independent, survives Back/Next, and the ZIP carries exactly the ticked ones', async ({ page }) => {
  await openWindows(page);
  await box(page, 'bypassTpmCheck').check();
  await box(page, 'bypassSecureBootCheck').check();
  await expect(box(page, 'bypassCpuCheck')).not.toBeChecked();
  await wiz(page).locator('[data-wiz="top-next"]').click();
  await expect(wiz(page)).toHaveAttribute('data-step', 'type');
  await wiz(page).locator('[data-wiz="top-back"]').click();
  await expect(wiz(page)).toHaveAttribute('data-step', 'identity');
  await openWindows(page);
  await expect(box(page, 'bypassTpmCheck')).toBeChecked();
  await expect(box(page, 'bypassCpuCheck')).not.toBeChecked();
  await expect(box(page, 'bypassSecureBootCheck')).toBeChecked();
  // The same values in Advanced.
  await page.locator('.mode-switch [data-mode="advanced"]').click();
  await expect(page.locator('input[type=checkbox][name="setup.bypassTpmCheck"]')).toBeChecked();
  await expect(page.locator('input[type=checkbox][name="setup.bypassCpuCheck"]')).not.toBeChecked();
  await page.locator('.mode-switch [data-mode="quick"]').click();
  await wiz(page).locator('[data-wiz="go-review"]').click();
  await expect(wiz(page)).toHaveAttribute('data-step', 'review');
  await expect(wiz(page)).toContainText('Windows 11 hardware checks are bypassed');
  const xml = await readXml(page);
  expect(xml).toContain('reg.exe add "HKLM\\SYSTEM\\Setup\\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f');
  expect(xml).toContain('reg.exe add "HKLM\\SYSTEM\\Setup\\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f');
  expect(xml).not.toContain('BypassCPUCheck');
});

test('all three together reach the answer file; with none ticked there is no LabConfig', async ({ page }) => {
  await openWindows(page);
  for (const k of BOXES) await box(page, k).check();
  await wiz(page).locator('[data-wiz="go-review"]').click();
  const xml = await readXml(page);
  for (const v of ['BypassTPMCheck', 'BypassCPUCheck', 'BypassSecureBootCheck']) expect(xml).toContain(`/v ${v} /t REG_DWORD /d 1 /f`);
  await page.goto('/');
  await wiz(page).locator('[data-wiz="go-review"]').click();
  expect(await readXml(page)).not.toContain('LabConfig');
});

test('Advanced: a local account without an initial password has no encoded password and no persistent sign-in', async ({ page }) => {
  await page.locator('.mode-switch [data-mode="advanced"]').click();
  // The Advanced view shows the advanced fields.
  await page.getByRole('button', { name: 'Advanced', exact: true }).click();
  const menu = page.locator('.menu-btn.in-bar');
  if ((await menu.isVisible()) && (await menu.getAttribute('aria-expanded')) !== 'true') await menu.click();
  await page.locator('.sidebar a.nav-item[data-target="section-accounts"]').click();
  const section = page.locator('#section-accounts');
  const none = section.locator('input[type=checkbox][name="accounts.noInitialPassword"]');
  await expect(none).not.toBeChecked();
  await expect(section.locator('[data-path="accounts.password"]')).toBeVisible();
  await none.check();
  await expect(section.locator('[data-path="accounts.password"]')).toBeHidden();
  // Persistent sign-in (the owner default) is refused until "once" or "none" is chosen.
  await expect(section).toContainText('cannot keep automatic sign-in on');
  await section.locator('input[type=radio][name="accounts.autoLogon"][value="firstLogonOnly"]').check();
  await expect(section).not.toContainText('cannot keep automatic sign-in on');
  const xml = page.getByTestId('xml-preview');
  await expect(xml).toContainText('<PlainText>true</PlainText>');
  await expect(xml).not.toContainText('<PlainText>false</PlainText>');
  await expect(xml).not.toContainText('UABhAHMAcwB3AG8AcgBkAA==');
  await expect(xml).toContainText('<LogonCount>1</LogonCount>');
});
