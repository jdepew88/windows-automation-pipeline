import { expect, test, type Page } from '@playwright/test';

/**
 * Windows Update engine 2.0.0: the standalone recovery download on the Deployment package page.
 * Reads back what the website really serves.
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

test('the Windows Update recovery download is offered and contains engine 2.0.0 and Retry Windows Update', async ({ page }) => {
  await page.addInitScript(() => {
    if (!sessionStorage.getItem('e2e-init')) {
      localStorage.setItem('wdb.mode', 'advanced');
      sessionStorage.setItem('e2e-init', '1');
    }
  });
  await page.goto('/');
  await go(page, 'section-deployment');
  const option = page.getByTestId('update-recovery-download');
  await expect(option).toContainText('0x80131508');
  await expect(option.locator('a')).toHaveAttribute('href', 'downloads/windows-update-recovery.zip');
  const res = await page.request.get('/downloads/windows-update-recovery.zip');
  expect(res.status()).toBe(200);
  const { readZip } = await import('../../src/engine/deployment/zip');
  const entries = readZip(new Uint8Array(await res.body()));
  expect(entries.map((e) => e.path).sort()).toEqual(
    ['README.txt', 'files.json', 'Invoke-WindowsUpdateRetry.ps1', 'WindowsUpdateEngine.ps1'].map((f) => `WDB-WindowsUpdate/${f}`).sort(),
  );
  const engine = new TextDecoder().decode(entries.find((e) => e.path.endsWith('WindowsUpdateEngine.ps1'))!.data);
  expect(engine).toContain("$script:EngineVersion = '2.0.0'");
  expect(engine).toContain('return , $coll');
});
