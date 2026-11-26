import { expect, test, type Page } from '@playwright/test';
import { readFile } from 'node:fs/promises';

/**
 * Schema 9: Microsoft Office LTSC on the Applications page (Basic and Advanced) and the activation
 * preferences (Advanced only). Every check reads back what the website really produces.
 */

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

const field = (page: Page, path: string) => page.locator(`.field[data-path="${path}"]`);
const radio = (page: Page, path: string, value: string) => page.locator(`input[type=radio][name="${path}"][value="${value}"]`);
const view = (page: Page, v: 'Basic' | 'Advanced') => page.getByRole('button', { name: v, exact: true }).click();

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    if (!sessionStorage.getItem('e2e-init')) {
      localStorage.setItem('wdb.mode', 'advanced');
      sessionStorage.setItem('e2e-init', '1');
    }
  });
  await page.goto('/');
  await go(page, 'section-applications');
});

test('Basic view: Office is optional (off by default), 2024 is the current LTSC, 2021 carries a legacy notice; no activation controls', async ({ page }) => {
  await view(page, 'Basic');
  await expect(field(page, 'office.product')).toBeVisible();
  await expect(radio(page, 'office.product', 'none')).toBeChecked();
  await expect(field(page, 'office.product')).toContainText('Office LTSC Professional Plus 2024 (current LTSC)');
  await expect(field(page, 'office.product')).toContainText('October 13, 2026');
  for (const path of ['activation.windows', 'activation.office', 'office.removeMsiOffice']) await expect(field(page, path)).toBeHidden();
  await radio(page, 'office.product', 'ltsc2024ProPlus').check();
  await expect(field(page, 'activation.windows')).toBeHidden();
});

test('Advanced view: activation is off by default, independent for Windows and Office, and never switched on by choosing Office', async ({ page }) => {
  await view(page, 'Advanced');
  await expect(radio(page, 'activation.windows', 'none')).toBeChecked();
  // No Office: no Office activation control.
  await expect(field(page, 'activation.office')).toBeHidden();
  await radio(page, 'office.product', 'ltsc2021Standard').check();
  await expect(field(page, 'activation.office')).toBeVisible();
  await expect(radio(page, 'activation.office', 'none')).toBeChecked();
  await expect(radio(page, 'activation.windows', 'none')).toBeChecked();
  // Methods appear only for Microsoft activation; the KMS host only for KMS.
  await expect(field(page, 'activation.officeMethod')).toBeHidden();
  await radio(page, 'activation.office', 'microsoft').check();
  await expect(field(page, 'activation.officeMethod')).toBeVisible();
  await expect(field(page, 'activation.officeKmsHost')).toBeVisible();
  await radio(page, 'activation.officeMethod', 'mak').check();
  await expect(field(page, 'activation.officeKmsHost')).toBeHidden();
  await expect(field(page, 'activation.windowsMethod')).toBeHidden();
  await radio(page, 'activation.windows', 'manual').check();
  await expect(field(page, 'activation.windowsMethod')).toBeHidden();
  await go(page, 'section-review');
  await expect(page.locator('#section-review')).toContainText('Office LTSC Standard 2021');
  await expect(page.locator('#section-review')).toContainText('Windows: Technician activates manually');
  await expect(page.locator('#section-review')).toContainText('Office: Microsoft activation (MAK, entered by the technician)');
});

test('Office activation without Office blocks the package', async ({ page }) => {
  await view(page, 'Advanced');
  await radio(page, 'office.product', 'ltsc2024Standard').check();
  await radio(page, 'activation.office', 'microsoft').check();
  await radio(page, 'office.product', 'none').check();
  await go(page, 'section-deployment');
  await expect(page.locator('#section-deployment [data-action="download-package"]')).toBeDisabled();
  await go(page, 'section-review');
  await expect(page.locator('#section-review')).toContainText('no Office edition is installed by this deployment');
});

test('package: Office LTSC 2024 Professional Plus with Microsoft activation ships only the 2024 configuration, the pinned installer, no key and no third-party tool', async ({ page }) => {
  await view(page, 'Advanced');
  await radio(page, 'office.product', 'ltsc2024ProPlus').check();
  await radio(page, 'activation.windows', 'microsoft').check();
  await radio(page, 'activation.office', 'microsoft').check();
  await go(page, 'section-deployment');
  await expect(page.getByTestId('package-contents')).toContainText('WindowsDeployment/scripts/office/Install_Office.ps1');
  const [dl] = await Promise.all([page.waitForEvent('download'), page.locator('#section-deployment [data-action="download-package"]').click()]);
  const { readZip } = await import('../../src/engine/deployment/zip');
  const entries = readZip(new Uint8Array(await readFile((await dl.path())!)));
  const files = new Map(entries.map((e) => [e.path, new TextDecoder().decode(e.data)]));
  expect(files.has('WindowsDeployment/scripts/office/config_ProPlus.xml')).toBe(true);
  expect([...files.keys()].filter((k) => /config.*\.xml$/.test(k) && k.includes('/office/'))).toEqual(['WindowsDeployment/scripts/office/config_ProPlus.xml']);
  const manifest = JSON.parse(files.get('WindowsDeployment/deployment-manifest.json')!);
  expect(manifest.office).toMatchObject({ productId: 'ProPlus2024Volume', channel: 'PerpetualVL2024', activates: false });
  expect(manifest.office.source.installer.commit).toBe('3e2817194aaef0856c5ce8653763c77e24cb3e72');
  expect(manifest.activation).toMatchObject({ windows: { action: 'microsoft', method: 'digitalLicense' }, office: { action: 'microsoft', method: 'kms' }, containsSecrets: false });
  expect(manifest.stages.map((s: { id: string }) => s.id)).toEqual(['staging', 'windowsUpdate', 'applications', 'drivers', 'office', 'finalization']);
  for (const [path, text] of files) {
    expect(text, path).not.toMatch(/massgrave|get\.activated\.win/i);
    if (/office|activation|manifest/.test(path)) expect(text, path).not.toMatch(/\b[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}\b/);
  }
});
