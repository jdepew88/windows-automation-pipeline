import { expect, test, type Locator, type Page } from '@playwright/test';
import { readFile } from 'node:fs/promises';

/**
 * Quick Deployment application review (profile previews, combined selection, Final Review summary)
 * and the Advanced catalog scroll regression: ticking an app below the top of the catalog used to
 * re-create every tile, which removed the browser's scroll anchor and made the page jump upwards.
 */

const wiz = (page: Page) => page.getByTestId('wizard');
const card = (page: Page, id: string) => wiz(page).locator(`[data-type="${id}"]`);
const viewBtn = (page: Page, id: string) => wiz(page).locator(`[data-view-apps="${id}"]`);
const preview = (page: Page, id: string) => wiz(page).getByTestId(`preview-${id}`);
const summary = (page: Page) => wiz(page).getByTestId('review-app-summary');

async function next(page: Page) {
  await wiz(page).locator('[data-wiz="top-next"]').click();
}

async function toType(page: Page) {
  await wiz(page).getByTestId('wiz-username').fill('Sam');
  await next(page);
  await expect(wiz(page)).toHaveAttribute('data-step', 'type');
}

async function toReview(page: Page) {
  await wiz(page).locator('[data-wiz="go-review"]').click();
  await expect(wiz(page)).toHaveAttribute('data-step', 'review');
}

async function adv(page: Page, target: string) {
  const menu = page.locator('.menu-btn.in-bar');
  if ((await menu.isVisible()) && (await menu.getAttribute('aria-expanded')) !== 'true') await menu.click();
  await page.locator(`.sidebar a.nav-item[data-target="${target}"]`).click();
  await expect(page.locator(`#${target}`)).toBeVisible();
}

const names = (list: Locator) => list.locator('.app-sum-name').allTextContents();

async function readConfig(page: Page) {
  for (const box of await wiz(page).locator('[data-ack]').all()) await box.check();
  const [dl] = await Promise.all([page.waitForEvent('download'), wiz(page).locator('[data-action="wiz-generate"]').click()]);
  const { readZip } = await import('../../src/engine/deployment/zip');
  const entries = readZip(new Uint8Array(await readFile((await dl.path())!)));
  const text = new TextDecoder().decode(entries.find((e) => e.path === 'WindowsDeployment/scripts/applications/applications-config.json')!.data);
  return JSON.parse(text) as { packages: { key: string; displayName: string }[]; manual: { key: string; displayName: string }[] };
}

test.beforeEach(async ({ page }) => {
  await page.goto('/');
});

test.describe('Quick Deployment: profile previews', () => {
  test('View applications expands and collapses without selecting the profile', async ({ page }) => {
    await toType(page);
    const gaming = card(page, 'gaming').locator('input');
    await expect(gaming).not.toBeChecked();
    await expect(viewBtn(page, 'gaming')).toHaveAttribute('aria-expanded', 'false');
    await expect(viewBtn(page, 'gaming')).toHaveText(/View applications \(2\)/);
    await viewBtn(page, 'gaming').click();
    await expect(viewBtn(page, 'gaming')).toHaveAttribute('aria-expanded', 'true');
    await expect(viewBtn(page, 'gaming')).toHaveAttribute('aria-controls', 'wiz-preview-gaming');
    await expect(preview(page, 'gaming')).toHaveAttribute('role', 'region');
    expect(await names(preview(page, 'gaming'))).toEqual(['Steam', 'Epic Games Launcher']);
    await expect(preview(page, 'gaming')).toContainText('Viewing does not select it');
    await expect(gaming).not.toBeChecked();
    await expect(wiz(page).locator('.wiz-step[data-step="type"]')).not.toHaveAttribute('data-status', 'customized');
    await viewBtn(page, 'gaming').click();
    await expect(preview(page, 'gaming')).toHaveCount(0);
    await expect(viewBtn(page, 'gaming')).toHaveAttribute('aria-expanded', 'false');
    await expect(gaming).not.toBeChecked();
  });

  test('keyboard: Enter opens a preview, Space selects; focus stays on the control', async ({ page }) => {
    await toType(page);
    await viewBtn(page, 'developer').focus();
    await page.keyboard.press('Enter');
    await expect(preview(page, 'developer')).toBeVisible();
    await expect(viewBtn(page, 'developer')).toBeFocused();
    await expect(card(page, 'developer').locator('input')).not.toBeChecked();
    await card(page, 'developer').locator('input').focus();
    await page.keyboard.press('Space');
    await expect(card(page, 'developer').locator('input')).toBeChecked();
    await expect(card(page, 'developer').locator('input')).toBeFocused();
    // Selecting it keeps the preview open and now describes it as part of the deployment.
    await expect(preview(page, 'developer')).toContainText('4 apps from this profile');
  });

  test('switching and combining profiles; shared apps counted once in the combined selection', async ({ page }) => {
    await toType(page);
    await viewBtn(page, 'gaming').click();
    await viewBtn(page, 'network-engineer').click();
    await expect(preview(page, 'gaming')).toBeVisible();
    await expect(preview(page, 'network-engineer')).toContainText('Git');
    await expect(preview(page, 'network-engineer').locator('[data-key="winget:git.git"]')).toHaveAttribute('title', /From General Developer/);
    await expect(preview(page, 'network-engineer').locator('[data-key="winget:microsoft.wsl"]')).toHaveAttribute('title', /Required by Docker Desktop/);
    await card(page, 'developer').locator('input').check();
    await card(page, 'network-engineer').locator('input').check();
    await card(page, 'gaming').locator('input').check();
    await wiz(page).locator('[data-action="view-combined"]').click();
    const combined = wiz(page).getByTestId('wiz-combined');
    const all = await names(combined);
    expect(all.filter((n) => n === 'Git')).toHaveLength(1);
    expect(new Set(all).size).toBe(all.length);
    // Core Essentials + Gaming + Network Engineer (incl. Developer and WSL). RustDesk is only recommended (Phase 10).
    await expect(combined).toHaveAttribute('data-total', String(7 + 2 + 29));
    await expect(combined).not.toContainText('RustDesk');
    await expect(combined.locator('[data-key="winget:git.git"]')).toHaveAttribute('title', /General Developer, Network Engineer/);
    // Unticking a profile updates the combined view immediately.
    await card(page, 'gaming').locator('input').uncheck();
    await expect(combined).toHaveAttribute('data-total', String(7 + 29));
    await expect(combined).not.toContainText('Steam');
  });

  test('an app unticked in Applications is shown as left out, never as included', async ({ page }) => {
    await toType(page);
    await card(page, 'gaming').locator('input').check();
    await next(page);
    await next(page);
    await wiz(page).locator('[data-app="steam"] input').uncheck();
    await wiz(page).locator('[data-wiz="top-back"]').click();
    await wiz(page).locator('[data-wiz="top-back"]').click();
    await viewBtn(page, 'gaming').click();
    const steam = preview(page, 'gaming').locator('[data-key="winget:valve.steam"]');
    await expect(steam).toHaveAttribute('data-status', 'excluded');
    await expect(steam).toHaveAttribute('title', /Unticked in this deployment/);
    await expect(preview(page, 'gaming')).toContainText('1 app from this profile, 1 left out of this deployment');
    await toReview(page);
    await expect(summary(page)).not.toContainText('Steam');
    await expect(summary(page)).toContainText('Epic Games Launcher');
  });

  test('saved (custom) profiles have previews too', async ({ page }) => {
    await page.locator('.mode-switch [data-mode="advanced"]').click();
    await adv(page, 'section-applications');
    const section = page.locator('#section-applications');
    await section.locator('[data-profile="gaming"] input').check();
    await section.locator('[data-testid="app-filter"] [data-filter="all"]').click();
    await section.locator('[data-app="epic"]').click();
    await expect(section.locator('[data-app="epic"] input')).not.toBeChecked();
    page.once('dialog', (d) => d.accept('Aunt Computer'));
    await section.locator('[data-action="app-save-new"]').click();
    await section.locator('[data-profile="gaming"] input').uncheck();
    await page.locator('.mode-switch [data-mode="quick"]').click();
    await toType(page);
    const saved = wiz(page).locator('.type-item', { hasText: 'Aunt Computer' });
    const btn = saved.locator('[data-action="view-apps"]');
    await btn.click();
    const region = saved.locator('.type-preview');
    await expect(region).toContainText('Steam');
    await expect(region.locator('.app-sum-grid')).not.toContainText('Epic Games Launcher');
    await expect(region).toContainText('Leaves out: Epic Games Launcher');
    // It is ticked (Save as new profile ticks it); viewing did not change that.
    await expect(saved.locator('.type-card input')).toBeChecked();
  });
});

test.describe('Quick Deployment: Final Review application summary', () => {
  test('lists only the selected apps, with accurate counts and the automatic/manual split, matching the ZIP', async ({ page }) => {
    await toType(page);
    await card(page, 'gaming').locator('input').check();
    await toReview(page);
    const s = summary(page);
    await expect(s).toBeVisible();
    await expect(wiz(page).getByTestId('review-app-summary-count')).toHaveText('9 applications selected: 9 installed automatically.');
    expect(await names(wiz(page).getByTestId('review-app-summary-manual'))).toEqual([]);
    const auto = await names(wiz(page).getByTestId('review-app-summary-auto'));
    expect(auto).toHaveLength(9);
    expect(auto).toEqual(expect.arrayContaining(['Google Chrome', 'Steam', 'Epic Games Launcher']));
    // Never the whole catalog: unselected apps are absent.
    expect(auto).not.toContain('Discord');
    await expect(s.locator('.app-sum-item')).toHaveCount(9);
    await expect(wiz(page).locator('[data-testid="review-apps"] [data-action="review-edit"]')).toBeVisible();
    const cfg = await readConfig(page);
    expect(cfg.packages.map((x) => x.displayName).sort()).toEqual([...auto].sort());
    expect(cfg.manual).toEqual([]);
  });

  test('changes made in Advanced reach the summary through the shared selection', async ({ page }) => {
    await page.locator('.mode-switch [data-mode="advanced"]').click();
    await adv(page, 'section-applications');
    const section = page.locator('#section-applications');
    await section.getByTestId('app-search').fill('docker');
    await section.locator('[data-app="docker-desktop"] input').check();
    await section.getByTestId('app-search').fill('chrome');
    await section.locator('[data-app="chrome"] input').uncheck();
    await page.locator('.mode-switch [data-mode="quick"]').click();
    await toType(page);
    await toReview(page);
    const auto = await names(wiz(page).getByTestId('review-app-summary-auto'));
    expect(auto).toEqual(expect.arrayContaining(['Docker Desktop', 'Windows Subsystem for Linux']));
    expect(auto).not.toContain('Google Chrome');
  });

  test('an empty selection is stated plainly', async ({ page }) => {
    await toType(page);
    await card(page, 'core').locator('input').uncheck();
    await toReview(page);
    await expect(wiz(page).getByTestId('review-app-summary-count')).toHaveText('No applications are selected.');
    await expect(summary(page).locator('.app-sum-item')).toHaveCount(0);
  });
});

// Advanced catalog: scroll position must not move when an app is ticked or unticked -------------

const VIEWS = ['logos', 'grid', 'compact', 'detailed'] as const;
// Spread through the catalog; GIMP and WhatsApp jumped the page before the fix.
const APPS = ['whatsapp', 'gimp', 'notepadpp', 'virtualbox'];

async function openCatalog(page: Page, view: string) {
  await page.evaluate((v) => localStorage.setItem('wdb.catalogView', v), view);
  await page.reload();
  await page.locator('.mode-switch [data-mode="advanced"]').click();
  await adv(page, 'section-applications');
  await page.locator('#section-applications [data-testid="app-filter"] [data-filter="all"]').click();
}

/**
 * Clicks an app well below the top of the catalog (where the user clicks: the tile, row or the
 * detailed list's checkbox) and checks that it stays where it was on screen (the bug moved it by
 * hundreds of pixels). window.scrollY alone is not the measure: when content above the list
 * changes height (the statistics wrap to a second line), the browser scrolls by exactly that much
 * to keep the app in place.
 */
async function toggleStable(page: Page, id: string, expected: boolean) {
  const item = page.locator(`#section-applications [data-app="${id}"]`);
  await item.scrollIntoViewIfNeeded();
  const input = item.locator('input');
  const before = await page.evaluate(() => window.scrollY);
  const top = (await item.boundingBox())!.y;
  expect(before).toBeGreaterThan(300);
  await ((await item.evaluate((e) => e.tagName)) === 'LABEL' ? item : input).click();
  await expect(input).toBeChecked({ checked: expected });
  await page.waitForTimeout(50);
  expect(Math.abs((await item.boundingBox())!.y - top)).toBeLessThanOrEqual(1);
  await expect(input).toBeFocused();
}

test.describe('Advanced catalog keeps the scroll position', () => {
  for (const view of VIEWS) {
    test(`${view}: select and deselect after scrolling down`, async ({ page }) => {
      await openCatalog(page, view);
      await expect(page.locator(`#section-applications .app-items.view-${view}`).first()).toBeVisible();
      for (const id of APPS) {
        await toggleStable(page, id, true);
        await toggleStable(page, id, false);
      }
      // The view mode and filter are unchanged.
      await expect(page.locator(`#section-applications [data-view-mode="${view}"]`)).toHaveAttribute('aria-pressed', 'true');
      await expect(page.locator('#section-applications [data-filter="all"]')).toHaveAttribute('aria-pressed', 'true');
    });
  }

  test('dependencies update without moving the page; search and category stay', async ({ page }) => {
    await openCatalog(page, 'grid');
    await toggleStable(page, 'docker-desktop', true);
    await expect(page.locator('#section-applications [data-app="wsl"]')).toHaveAttribute('data-state', 'selected');
    await toggleStable(page, 'docker-desktop', false);
    await expect(page.locator('#section-applications [data-app="wsl"]')).not.toHaveAttribute('data-state', 'selected');
    const section = page.locator('#section-applications');
    await section.getByTestId('app-category').selectOption('media');
    await section.getByTestId('app-search').fill('a');
    const first = section.locator('.app-items [data-app]').first();
    const id = (await first.getAttribute('data-app'))!;
    await first.click();
    await expect(section.getByTestId('app-search')).toHaveValue('a');
    await expect(section.getByTestId('app-category')).toHaveValue('media');
    await expect(section.locator(`[data-app="${id}"] input`)).toBeChecked();
  });

  test('keyboard: Space ticks the focused app, focus and scroll stay', async ({ page }) => {
    await openCatalog(page, 'compact');
    const item = page.locator('#section-applications [data-app="gimp"]');
    await item.scrollIntoViewIfNeeded();
    const input = item.locator('input');
    await input.focus();
    const before = await page.evaluate(() => window.scrollY);
    await page.keyboard.press('Space');
    await expect(input).toBeChecked();
    await expect(input).toBeFocused();
    expect(Math.abs((await page.evaluate(() => window.scrollY)) - before)).toBeLessThanOrEqual(1);
    // Tab moves on to the next app, as before the change.
    const nextId = await page.evaluate(() => {
      const inputs = [...document.querySelectorAll<HTMLInputElement>('#section-applications .app-list input:not([disabled])')];
      return inputs[inputs.findIndex((i) => i.closest<HTMLElement>('[data-app]')?.dataset.app === 'gimp') + 1]?.closest<HTMLElement>('[data-app]')?.dataset.app;
    });
    expect(nextId).toBeTruthy();
    await page.keyboard.press('Tab');
    await expect(page.locator(`#section-applications [data-app="${nextId}"] input`)).toBeFocused();
  });

  test('antivirus conflicts are still enforced', async ({ page }) => {
    await openCatalog(page, 'grid');
    await toggleStable(page, 'avast', true);
    await expect(page.locator('#section-applications [data-app="avg"] input')).toBeDisabled();
    await toggleStable(page, 'avast', false);
    await expect(page.locator('#section-applications [data-app="avg"] input')).toBeEnabled();
  });
});

test('no horizontal scroll with previews and the summary open', async ({ page }) => {
  await toType(page);
  await viewBtn(page, 'network-engineer').click();
  await wiz(page).locator('[data-action="view-combined"]').click();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBe(true);
  await toReview(page);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBe(true);
});
