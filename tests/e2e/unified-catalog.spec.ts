import { expect, test, type Page } from '@playwright/test';
import { readFile } from 'node:fs/promises';

/**
 * Unified application catalog (2026-11-26): the whole shared catalog is discoverable from the
 * Deployment Builder (Quick Deployment too), profiles are additive and show where each app comes
 * from, manual installations are never presented as automatic, and an older saved deployment keeps
 * its applications until the technician adopts the new profile defaults.
 */

const CATALOG_SIZE = 289;
const wiz = (page: Page) => page.getByTestId('wizard');
const next = (page: Page) => wiz(page).locator('[data-wiz="top-next"]').click();
const catalog = (page: Page) => wiz(page).getByTestId('app-catalog');

async function readPackage(page: Page) {
  const [dl] = await Promise.all([page.waitForEvent('download'), wiz(page).locator('[data-action="wiz-generate"]').click()]);
  const { readZip } = await import('../../src/engine/deployment/zip');
  const entries = readZip(new Uint8Array(await readFile((await dl.path())!)));
  const json = (path: string) => JSON.parse(new TextDecoder().decode(entries.find((e) => e.path === path)!.data));
  return { config: json('WindowsDeployment/scripts/applications/applications-config.json'), native: json('WindowsDeployment/scripts/applications/winget-packages.json') };
}

test.beforeEach(async ({ page }) => {
  await page.goto('/');
  await wiz(page).getByTestId('wiz-username').fill('Alex');
  await next(page);
});

test('profiles are additive: ticking several updates the combined list at once and shows which profile selected each app', async ({ page }) => {
  const types = wiz(page).getByTestId('wiz-types');
  for (const t of ['Student / Office', 'Content Creator', 'Remote Support', 'IT Technician / Network Engineer']) await expect(types).toContainText(t);
  const count = wiz(page).getByTestId('wiz-app-count');
  const before = Number(await count.getAttribute('data-count'));
  expect(before).toBe(9); // Core Essentials
  await wiz(page).locator('[data-type="gaming"] input').check();
  await expect(count).toHaveAttribute('data-count', String(before + 7));
  await wiz(page).locator('[data-type="music"] input').check();
  await wiz(page).locator('[data-type="creator"] input').check();
  const list = wiz(page).getByTestId('wiz-checklist-list');
  // Audacity is a default of Music Lover and Content Creator: listed once, with both origins.
  await expect(list.locator('[data-key="winget:audacity.audacity"]')).toHaveCount(1);
  await expect(list.locator('[data-key="winget:audacity.audacity"]')).toContainText('Music Lover');
  await expect(list.locator('[data-key="winget:audacity.audacity"]')).toContainText('Content Creator');
  await expect(list.locator('[data-key="winget:valve.steam"]')).toContainText('Gamer');
  // Unticking a profile removes only its own apps, immediately.
  await wiz(page).locator('[data-type="creator"] input').uncheck();
  await expect(list.locator('[data-key="winget:obsproject.obsstudio"]')).toHaveCount(0);
  await expect(list.locator('[data-key="winget:audacity.audacity"]')).toHaveCount(1);
});

test('the whole catalog is one click away in Quick Deployment: browse, search by publisher, filter by category and status', async ({ page }) => {
  await wiz(page).locator('[data-wiz="browse-all-apps"]').click();
  await expect(wiz(page)).toHaveAttribute('data-step', 'apps');
  await expect(wiz(page).locator('[data-filter="all"]')).toHaveAttribute('aria-pressed', 'true');
  await expect(wiz(page).locator('[data-filter-count="all"]')).toHaveText(String(CATALOG_SIZE));
  await expect(catalog(page).locator('[data-app]')).toHaveCount(CATALOG_SIZE);
  // Search by publisher.
  await wiz(page).getByTestId('app-search').fill('Krzysztof');
  await expect(catalog(page).locator('[data-app]')).toHaveCount(1);
  await expect(catalog(page).locator('[data-app="sumatrapdf"]')).toBeVisible();
  // Search by category name, then the category filter.
  await wiz(page).getByTestId('app-search').fill('remote access');
  await expect(catalog(page).locator('[data-app="teamviewer"]')).toBeVisible();
  await expect(catalog(page).locator('[data-app="rustdesk"]')).toBeVisible();
  await wiz(page).getByTestId('app-search').fill('');
  await wiz(page).getByTestId('app-category').selectOption('gaming');
  await expect(catalog(page).locator('[data-app="heroic"]')).toBeVisible();
  await expect(catalog(page).locator('[data-app="teamviewer"]')).toHaveCount(0);
  await wiz(page).getByTestId('app-category').selectOption('');
  // Status filters: Selected, Recommended, Available, Manual installation.
  await wiz(page).locator('[data-filter="selected"]').click();
  await expect(catalog(page).locator('[data-app]')).toHaveCount(9);
  await wiz(page).locator('[data-filter="available"]').click();
  await expect(catalog(page).locator('[data-app="chrome"]')).toHaveCount(0);
  await expect(catalog(page).locator('[data-app="krita"]')).toHaveCount(1);
  await expect(catalog(page).locator('[data-app="rustdesk"]')).toHaveCount(0);
  await wiz(page).locator('[data-filter="manual"]').click();
  await expect(catalog(page).locator('[data-app="rustdesk"]')).toHaveCount(1);
  await expect(catalog(page).locator('[data-app="teamviewer"]')).toHaveCount(0);
});

test('manual installations are labelled as such; ticked apps reach the ZIP exactly, a manual one as a follow-up only', async ({ page }) => {
  await wiz(page).locator('[data-type="remote-support"] input').check();
  await wiz(page).locator('[data-wiz="browse-all-apps"]').click();
  await wiz(page).locator('[data-view-mode="detailed"]').click();
  await wiz(page).getByTestId('app-search').fill('rustdesk');
  const rustdesk = catalog(page).locator('[data-app="rustdesk"]');
  await expect(rustdesk).toContainText('Manual follow-up');
  await expect(rustdesk).toContainText('Recommended by Remote Support');
  await rustdesk.locator('input').check();
  // Two remote-support tools are allowed when deliberate; the plan says so.
  await expect(wiz(page).getByTestId('app-warnings')).toContainText('TeamViewer and RustDesk are all remote-support tools');
  await wiz(page).getByTestId('app-search').fill('krita');
  const selected = wiz(page).getByTestId('app-selected').locator('strong');
  const n = Number(await selected.textContent());
  await catalog(page).locator('[data-app="krita"] input').check();
  await expect(selected).toHaveText(String(n + 1));
  await expect(wiz(page).getByTestId('app-count')).toContainText('1 manual');
  await next(page);
  for (const box of await wiz(page).locator('[data-ack]').all()) await box.check();
  const zip = await readPackage(page);
  const ids = zip.config.packages.map((p: { packageIdentifier: string }) => p.packageIdentifier);
  expect(ids).toEqual(expect.arrayContaining(['TeamViewer.TeamViewer', 'KDE.Krita', 'SumatraPDF.SumatraPDF']));
  expect(ids).not.toContain('rustdesk');
  expect(zip.config.manual.map((m: { displayName?: string; name?: string }) => m.displayName ?? m.name)).toEqual(['RustDesk']);
  const native = zip.native.Sources.flatMap((s: { Packages: { PackageIdentifier: string }[] }) => s.Packages.map((p) => p.PackageIdentifier));
  expect([...native].sort()).toEqual([...ids].sort());
});

test('an older saved deployment keeps its applications until the new profile defaults are adopted', async ({ page }) => {
  // The owner default as an older (schema 9) export: no profile revision, Core + Gaming ticked.
  const old = JSON.parse(await readFile(new URL('../../profiles/owner-default.json', import.meta.url), 'utf8'));
  old.schemaVersion = 9;
  delete old.applications.selection.profileRevision;
  old.applications.selection.selectedProfiles = ['core', 'gaming'];
  await page.locator('.mode-switch [data-mode="advanced"]').click();
  await page.getByTestId('import-input').setInputFiles({ name: 'older.json', mimeType: 'application/json', buffer: Buffer.from(JSON.stringify(old)) });
  await expect(page.getByTestId('notice')).toContainText('Use the new profile defaults');
  await page.locator('.mode-switch [data-mode="quick"]').click();
  await wiz(page).locator('[data-wiz="go-apps"]').click();
  await expect(wiz(page).getByTestId('app-legacy-profiles')).toBeVisible();
  const list = catalog(page);
  await wiz(page).locator('[data-filter="selected"]').click();
  await expect(list.locator('[data-app="epic"]')).toHaveCount(1);
  await expect(list.locator('[data-app="teracopy"]')).toHaveCount(1);
  await expect(list.locator('[data-app="discord"]')).toHaveCount(0);
  page.once('dialog', (d) => d.accept());
  await wiz(page).locator('[data-action="adopt-profile-defaults"]').click();
  await expect(wiz(page).getByTestId('app-legacy-profiles')).toBeHidden();
  await expect(list.locator('[data-app="discord"]')).toHaveCount(1);
  await expect(list.locator('[data-app="sumatrapdf"]')).toHaveCount(1);
});
