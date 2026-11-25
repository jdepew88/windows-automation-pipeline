import { expect, test, type Page } from '@playwright/test';
import { readFile } from 'node:fs/promises';

/**
 * Phase 9: Deployment Verification & Health in the website. The website only writes the
 * verification plan; results exist only on the installed computer, so every preview is labelled as
 * sample data. Every check reads back what the website really produces (the deployment ZIP).
 */

const wiz = (page: Page) => page.getByTestId('wizard');
const field = (page: Page, path: string) => page.locator(`.field[data-path="${path}"]`);

async function adv(page: Page, target: string) {
  if (await page.locator('.mode-switch [data-mode="advanced"]').getAttribute('aria-pressed') !== 'true') await page.locator('.mode-switch [data-mode="advanced"]').click();
  const menu = page.locator('.menu-btn.in-bar');
  if ((await menu.isVisible()) && (await menu.getAttribute('aria-expanded')) !== 'true') await menu.click();
  await page.locator(`.sidebar a.nav-item[data-target="${target}"]`).click();
  await expect(page.locator(`#${target}`)).toBeVisible();
}

async function quickReview(page: Page) {
  await page.locator('.mode-switch [data-mode="quick"]').click();
  await wiz(page).getByTestId('wiz-username').fill('Sam');
  await wiz(page).locator('[data-wiz="top-next"]').click();
  await wiz(page).locator('[data-wiz="go-review"]').click();
  await expect(wiz(page)).toHaveAttribute('data-step', 'review');
}

async function zip(page: Page) {
  for (const box of await wiz(page).locator('[data-ack]').all()) await box.check();
  const [dl] = await Promise.all([page.waitForEvent('download'), wiz(page).locator('[data-action="wiz-generate"]').click()]);
  const { readZip } = await import('../../src/engine/deployment/zip');
  const entries = readZip(new Uint8Array(await readFile((await dl.path())!)));
  const json = (path: string) => {
    const e = entries.find((x) => x.path === path);
    return e ? JSON.parse(new TextDecoder().decode(e.data)) : undefined;
  };
  return { entries, json };
}

async function addAdditional(page: Page, name: string) {
  await adv(page, 'section-additionalSoftware');
  const add = field(page, 'additionalSoftware.items');
  await page.locator('[data-action="add-additional"]').click();
  await add.locator('input[name="additionalSoftware.items.0.name"]').fill(name);
  await add.locator('input[name="additionalSoftware.items.0.downloadUrl"]').fill('https://contoso.example/setup.exe');
}

test.beforeEach(async ({ page }) => {
  await page.goto('/');
});

test('Advanced: Verification & Health is on by default, read-only, and its choices reach the package', async ({ page }) => {
  await adv(page, 'section-health');
  const section = page.locator('#section-health');
  await expect(section).toContainText('A script that exited without an error is never taken as proof');
  await expect(section).toContainText('cannot be turned off');
  await expect(field(page, 'health.enabled').locator('input')).toBeChecked();
  await expect(field(page, 'health.technicianReport').locator('input')).toBeChecked();
  await expect(field(page, 'health.customerReport').locator('input')).toBeChecked();
  await field(page, 'health.customerReport').locator('input').uncheck();
  // Optional applications: only what is installed automatically is offered.
  const optional = page.getByTestId('health-optional-apps');
  await expect(optional.locator('[data-health-app="winget:google.chrome"]')).toBeVisible();
  await expect(optional.locator('[data-health-app="catalog:rustdesk"]')).toHaveCount(0);
  await optional.locator('[data-health-app="winget:videolan.vlc"]').check();
  await page.getByTestId('health-notes').fill('Your files are in Documents.');
  await quickReview(page);
  const { json } = await zip(page);
  const cfg = json('WindowsDeployment/scripts/health/health-config.json');
  expect(cfg.options).toMatchObject({ technicianReport: true, customerReport: false });
  expect(cfg.customerNotes).toBe('Your files are in Documents.');
  const items = cfg.applications.items as { key: string; required: boolean }[];
  expect(items.find((x) => x.key === 'winget:videolan.vlc')!.required).toBe(false);
  expect(items.find((x) => x.key === 'winget:google.chrome')!.required).toBe(true);
  expect(json('WindowsDeployment/deployment-manifest.json').verification).toMatchObject({ enabled: true, readOnly: true });
});

test('Advanced: the deployment monitor is on and local-only by default; LAN access and the port reach the package', async ({ page }) => {
  await adv(page, 'section-health');
  const section = page.locator('#section-health');
  await expect(section.getByText('Following the deployment', { exact: true })).toBeVisible();
  await expect(section).toContainText('opens by itself at every sign-in');
  await expect(field(page, 'monitoring.enabled').locator('input')).toBeChecked();
  await expect(field(page, 'monitoring.lanAccess').locator('input')).not.toBeChecked();
  await field(page, 'monitoring.lanAccess').locator('input').check();
  // The port is an Advanced-view setting.
  await expect(field(page, 'monitoring.port')).toBeHidden();
  await page.getByRole('button', { name: 'Advanced', exact: true }).click();
  await field(page, 'monitoring.port').locator('input').fill('80');
  await expect(field(page, 'monitoring.port')).toContainText(/1024 to 65535/);
  await field(page, 'monitoring.port').locator('input').fill('8890');
  await quickReview(page);
  const { entries, json } = await zip(page);
  expect(entries.some((e) => e.path === 'WindowsDeployment/scripts/monitor/DeploymentStatusServer.ps1')).toBe(true);
  const manifest = json('WindowsDeployment/deployment-manifest.json');
  expect(manifest.monitor).toMatchObject({ enabled: true, port: 8890, lanAccess: true, refreshSeconds: 7, readOnly: true, firewall: { profile: 'Private', remoteAddress: 'LocalSubnet' } });
  expect(manifest.progress).toMatchObject({ refreshSeconds: 7, opensAtSignIn: true });
});

test('Advanced: turning verification off removes the engine from the package; notes with a password are refused', async ({ page }) => {
  await adv(page, 'section-health');
  await page.getByTestId('health-notes').fill('Wi-Fi password: hunter22');
  await expect(page.locator('[data-issues-for="health.customerNotes"], .field[data-path="health.customerNotes"] .issues')).toContainText(/password/i);
  await page.getByTestId('health-notes').fill('');
  await field(page, 'health.enabled').locator('input').uncheck();
  await expect(field(page, 'health.technicianReport')).toBeHidden();
  await quickReview(page);
  await expect(wiz(page).getByTestId('review-verification')).toContainText('Off: no health report');
  const { entries, json } = await zip(page);
  expect(entries.some((e) => e.path.includes('scripts/health/'))).toBe(false);
  expect(json('WindowsDeployment/deployment-manifest.json').verification).toBeUndefined();
});

test('report previews use the real template with clearly labelled sample data, and are keyboard accessible', async ({ page }) => {
  await adv(page, 'section-health');
  await page.getByTestId('health-notes').fill('Call us on 555-0100.');
  const tech = page.locator('[data-preview="technician"]');
  await expect(tech).toHaveAttribute('aria-expanded', 'false');
  await tech.focus();
  await page.keyboard.press('Enter');
  await expect(tech).toHaveAttribute('aria-expanded', 'true');
  const region = page.getByTestId('health-preview');
  await expect(region).toBeVisible();
  await expect(region).toHaveAttribute('role', 'region');
  await expect(page.getByTestId('health-sample-note')).toContainText('Sample data');
  await expect(page.getByTestId('health-sample-note')).toContainText('cannot know the target computer');
  const frame = page.frameLocator('[data-testid="health-preview-frame"]');
  await expect(frame.locator('.sample')).toContainText('SAMPLE DATA');
  await expect(frame.locator('h1')).toHaveText('Deployment health report');
  await expect(frame.getByTestId('overall')).toContainText('Ready with warnings');
  // The searchable application list of the dashboard.
  await frame.getByTestId('app-search').fill('rust');
  await expect(frame.getByTestId('apps').locator('tbody tr')).toHaveCount(1);
  await expect(frame.getByTestId('apps')).toContainText('RustDesk');
  const customer = page.locator('[data-preview="customer"]');
  await customer.click();
  await expect(customer).toHaveAttribute('aria-expanded', 'true');
  await expect(tech).toHaveAttribute('aria-expanded', 'false');
  await expect(frame.locator('h1')).toHaveText('Your computer');
  await expect(frame.locator('body')).toContainText('Call us on 555-0100.');
  await expect(frame.locator('.sample')).toContainText('SAMPLE DATA');
  await customer.press('Space');
  await expect(region).toBeHidden();
});

test('Final Review lists Additional Software with the selected applications and states the final verification', async ({ page }) => {
  await addAdditional(page, 'Contoso Field Tool');
  await quickReview(page);
  const summary = wiz(page).getByTestId('review-app-summary');
  await expect(summary.getByTestId('review-app-summary-additional')).toContainText('Contoso Field Tool');
  await expect(wiz(page).getByTestId('review-app-summary-count')).toContainText('1 Additional Software');
  await expect(wiz(page).getByTestId('review-apps')).toContainText('Contoso Field Tool (manual follow-up)');
  const v = wiz(page).getByTestId('review-verification');
  await expect(v).toContainText('Automatic and read-only');
  await expect(v).toContainText('technician dashboard, customer handoff');
  await expect(v).toContainText('No backup restoration');
  await expect(wiz(page).getByTestId('review-drivers')).toContainText('Windows Update goes first and may supply compatible drivers');
  // What the review lists is what the package verifies.
  const shown = await summary.locator('.app-sum-item').evaluateAll((els) => els.map((e) => e.getAttribute('data-key')!).sort());
  const { json } = await zip(page);
  const planned = (json('WindowsDeployment/scripts/health/health-config.json').applications.items as { key: string }[]).map((x) => x.key).sort();
  expect(planned).toEqual(shown);
  expect(planned).toContain('additional:' + (json('WindowsDeployment/scripts/applications/applications-config.json').additionalSoftware[0].id as string).toLowerCase());
  // Edit opens the Advanced section.
  await wiz(page).getByTestId('review-verification').getByRole('button', { name: 'Edit in Advanced' }).click();
  await expect(page.locator('#section-health')).toBeVisible();
});

test('Verification & Health is readable in light and dark themes without horizontal scrolling', async ({ page }, info) => {
  await adv(page, 'section-health');
  await page.locator('[data-preview="technician"]').click();
  for (const theme of ['Light', 'Dark']) {
    await page.getByRole('button', { name: `${theme} appearance` }).click();
    await adv(page, 'section-health');
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    expect(overflow, theme).toBeLessThanOrEqual(1);
    const section = page.locator('#section-health');
    await expect(page.frameLocator('[data-testid="health-preview-frame"]').getByTestId('overall')).toBeVisible();
    await info.attach(`health-${theme.toLowerCase()}`, { body: await section.screenshot(), contentType: 'image/png' });
    await section.screenshot({ path: info.outputPath(`health-${theme.toLowerCase()}.png`) });
  }
  // The sandboxed preview cannot be captured in place (headless Chromium): render the same template
  // and sample data in a page of its own, in both colour schemes, for review.
  for (const mode of ['technician', 'customer'] as const) {
    if ((await page.locator(`[data-preview="${mode}"]`).getAttribute('aria-expanded')) !== 'true') await page.locator(`[data-preview="${mode}"]`).click();
    const srcdoc = (await page.getByTestId('health-preview-frame').getAttribute('srcdoc'))!;
    for (const scheme of ['light', 'dark'] as const) {
      const p = await page.context().newPage();
      await p.emulateMedia({ colorScheme: scheme });
      await p.setContent(srcdoc);
      await expect(p.locator('.sample')).toContainText('SAMPLE DATA');
      expect(await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth), `${mode} ${scheme}`).toBeLessThanOrEqual(1);
      await p.screenshot({ path: info.outputPath(`report-${mode}-${scheme}.png`), fullPage: true });
      await p.close();
    }
  }
  await quickReview(page);
  const review = wiz(page).getByTestId('review-verification');
  await review.scrollIntoViewIfNeeded();
  await review.screenshot({ path: info.outputPath('review-verification.png') });
  expect(await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)).toBeLessThanOrEqual(1);
});
