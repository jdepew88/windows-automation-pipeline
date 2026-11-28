import { expect, test, type Page } from '@playwright/test';
import { readFile } from 'node:fs/promises';

/**
 * Quick Deployment step 2 recalculates the application selection on every profile change, lists
 * it with one checkbox per application, and step 2, Final Review and the generated package agree.
 * Counts are read from the page, never hard-coded, except where a test states its own arithmetic.
 */

const wiz = (page: Page) => page.getByTestId('wizard');
const typeBox = (page: Page, id: string) => wiz(page).locator(`[data-type="${id}"] input`);
const list = (page: Page) => wiz(page).getByTestId('wiz-checklist-list');
const count = (page: Page) => wiz(page).getByTestId('wiz-app-count');
const row = (page: Page, key: string) => list(page).locator(`li[data-key="${key}"]`);
const box = (page: Page, key: string) => list(page).locator(`input[data-check-app="${key}"]`);
const appsPanel = (page: Page) => wiz(page).locator('.wiz-panel[data-step="apps"]');

const GIT = 'winget:git.git';
const VSCODE = 'winget:microsoft.visualstudiocode';
const DOCKER = 'winget:docker.dockerdesktop';
const WSL = 'winget:microsoft.wsl';
const MUSICBEE = 'msstore:9p4clt2rj1rs';
const AUDACITY = 'winget:audacity.audacity';

async function toType(page: Page) {
  await page.goto('/');
  await wiz(page).getByTestId('wiz-username').fill('Sam');
  await wiz(page).locator('[data-wiz="top-next"]').click();
  await expect(wiz(page)).toHaveAttribute('data-step', 'type');
}

const total = async (page: Page) => Number(await count(page).getAttribute('data-count'));
/** The keys ticked in step 2, in order. */
const ticked = (page: Page) => list(page).locator('li[data-selected="true"]').evaluateAll((els) => els.map((e) => e.getAttribute('data-key')!));
const all = (page: Page) => list(page).locator('li').evaluateAll((els) => els.map((e) => e.getAttribute('data-key')!));

async function goStep(page: Page, step: 'type' | 'apps' | 'review') {
  if (step === 'apps') await wiz(page).locator('[data-wiz="go-apps"]').click();
  else if (step === 'review') await wiz(page).locator('[data-wiz="go-review"]').click();
  else await wiz(page).locator('.wiz-progress [data-step="type"] button').click();
  await expect(wiz(page)).toHaveAttribute('data-step', step);
}

async function readPackage(page: Page) {
  for (const b of await wiz(page).locator('[data-ack]').all()) await b.check();
  const [dl] = await Promise.all([page.waitForEvent('download'), wiz(page).locator('[data-action="wiz-generate"]').click()]);
  const { readZip } = await import('../../src/engine/deployment/zip');
  const entries = readZip(new Uint8Array(await readFile((await dl.path())!)));
  const text = (end: string) => new TextDecoder().decode(entries.find((e) => e.path.endsWith(end))!.data);
  const cfg = JSON.parse(text('scripts/applications/applications-config.json')) as { packages: { key: string }[]; manual: { key: string }[] };
  const winget = JSON.parse(text('scripts/applications/winget-packages.json')) as { Sources: { Packages: { PackageIdentifier: string }[] }[] };
  return {
    keys: [...cfg.packages, ...cfg.manual].map((x) => x.key).sort(),
    winget: winget.Sources.flatMap((s) => s.Packages.map((x) => x.PackageIdentifier.toLowerCase())).sort(),
    plan: text('scripts/applications/applications-plan.txt'),
  };
}

test.describe('Quick Deployment step 2: live profile selection', () => {
  test('ticking and unticking a profile updates the count and list immediately', async ({ page }) => {
    await toType(page);
    const base = await total(page);
    const baseKeys = await ticked(page);
    expect(base).toBe(baseKeys.length);
    await typeBox(page, 'music').check();
    await expect(row(page, MUSICBEE)).toHaveAttribute('data-selected', 'true');
    const withMusic = await total(page);
    expect(withMusic).toBeGreaterThan(base);
    expect(await ticked(page)).toHaveLength(withMusic);
    await typeBox(page, 'music').uncheck();
    await expect(row(page, MUSICBEE)).toHaveCount(0);
    await expect(count(page)).toHaveAttribute('data-count', String(base));
    expect(await ticked(page)).toEqual(baseKeys);
  });

  test('Core + Developer, untick Developer: exactly its unique apps leave; a shared app stays with the other profile', async ({ page }) => {
    await toType(page);
    const base = await ticked(page);
    await typeBox(page, 'developer').check();
    const dev = await ticked(page);
    const unique = dev.filter((k) => !base.includes(k));
    expect(unique).toEqual(expect.arrayContaining([GIT, VSCODE]));
    await expect(count(page)).toHaveAttribute('data-count', String(base.length + unique.length));
    await typeBox(page, 'developer').uncheck();
    await expect(count(page)).toHaveAttribute('data-count', String(base.length));
    for (const k of unique) await expect(row(page, k)).toHaveCount(0);
    // Shared: Audacity is a default of Music Lover and of Content Creator.
    await typeBox(page, 'music').check();
    await typeBox(page, 'creator').check();
    await expect(list(page).locator(`li[data-key="${AUDACITY}"]`)).toHaveCount(1);
    await typeBox(page, 'music').uncheck();
    await expect(row(page, AUDACITY)).toHaveAttribute('data-selected', 'true');
    await expect(row(page, AUDACITY).locator('label')).toHaveAttribute('title', /Content Creator/);
  });

  test('a single app can be unticked without unticking its profile, and ticked again', async ({ page }) => {
    await toType(page);
    await typeBox(page, 'developer').check();
    const before = await total(page);
    await box(page, VSCODE).uncheck();
    await expect(count(page)).toHaveAttribute('data-count', String(before - 1));
    await expect(row(page, VSCODE)).toHaveAttribute('data-selected', 'false');
    await expect(row(page, VSCODE)).toContainText('Unticked by you');
    await expect(typeBox(page, 'developer')).toBeChecked();
    await expect(box(page, VSCODE)).toBeFocused();
    await expect(box(page, GIT)).toBeChecked();
    // Final Review and the package leave it out too.
    await goStep(page, 'review');
    await expect(wiz(page).getByTestId('review-app-summary')).not.toContainText('Visual Studio Code');
    await wiz(page).locator('[data-wiz="top-back"]').click();
    await goStep(page, 'type');
    await box(page, VSCODE).check();
    await expect(count(page)).toHaveAttribute('data-count', String(before));
    await expect(row(page, VSCODE)).toHaveAttribute('data-selected', 'true');
  });

  test('recommendations ticked in Applications leave with their profile; an own addition stays', async ({ page }) => {
    await toType(page);
    const base = await ticked(page);
    await typeBox(page, 'developer').check();
    await goStep(page, 'apps');
    await appsPanel(page).locator('[data-app="docker-desktop"]').click();
    await appsPanel(page).locator('[data-testid="app-filter"] [data-filter="all"]').click();
    await appsPanel(page).getByTestId('app-search').fill('gimp');
    await appsPanel(page).locator('[data-app="gimp"]').click();
    await expect(appsPanel(page).locator('[data-app="gimp"] input')).toBeChecked();
    await goStep(page, 'type');
    await expect(row(page, DOCKER)).toHaveAttribute('data-selected', 'true');
    await expect(row(page, DOCKER).locator('label')).toHaveAttribute('title', /Recommended by Developer, ticked by you/);
    await expect(row(page, WSL).locator('label')).toHaveAttribute('title', /Required by Docker Desktop/);
    await typeBox(page, 'developer').uncheck();
    for (const k of [DOCKER, WSL, GIT, VSCODE]) await expect(row(page, k)).toHaveCount(0);
    await expect(row(page, 'winget:gimp.gimp.3')).toHaveAttribute('data-selected', 'true');
    expect((await ticked(page)).sort()).toEqual([...base, 'winget:gimp.gimp.3'].sort());
    // Re-ticking Developer does not bring Docker Desktop back.
    await typeBox(page, 'developer').check();
    await expect(row(page, DOCKER)).toHaveCount(0);
  });

  test('repeated toggling never duplicates an app', async ({ page }) => {
    await toType(page);
    const base = await ticked(page);
    for (let i = 0; i < 3; i++) {
      for (const id of ['developer', 'network-engineer', 'music', 'gaming']) await typeBox(page, id).check();
      const keys = await all(page);
      expect(new Set(keys).size).toBe(keys.length);
      await expect(count(page)).toHaveAttribute('data-count', String(keys.length));
      for (const id of ['gaming', 'developer', 'music', 'network-engineer']) await typeBox(page, id).uncheck();
      await expect(count(page)).toHaveAttribute('data-count', String(base.length));
    }
    expect(await ticked(page)).toEqual(base);
  });

  test('navigation keeps the selection; Final Review and the generated package match step 2 exactly', async ({ page }) => {
    await toType(page);
    await typeBox(page, 'developer').check();
    await typeBox(page, 'music').check();
    await box(page, GIT).uncheck();
    await typeBox(page, 'music').uncheck();
    const step2 = (await ticked(page)).sort();
    const n = await total(page);
    expect(step2).not.toContain(GIT);
    expect(step2).not.toContain(MUSICBEE);
    // Forward, back and forward again: nothing stale comes back.
    await wiz(page).locator('[data-wiz="top-next"]').click();
    await goStep(page, 'apps');
    await wiz(page).locator('[data-wiz="top-back"]').click();
    await goStep(page, 'type');
    expect((await ticked(page)).sort()).toEqual(step2);
    await expect(box(page, GIT)).not.toBeChecked();
    await goStep(page, 'review');
    const review = wiz(page).getByTestId('review-app-summary');
    await expect(review).toHaveAttribute('data-total', String(n));
    const reviewKeys = (await review.locator('li[data-key]').evaluateAll((els) => els.map((e) => e.getAttribute('data-key')!))).sort();
    expect(reviewKeys).toEqual(step2);
    const pkg = await readPackage(page);
    expect(pkg.keys).toEqual(step2);
    expect(pkg.winget).toContain('microsoft.visualstudiocode');
    expect(pkg.winget).not.toContain('git.git');
    expect(pkg.winget).not.toContain('9p4clt2rj1rs');
    expect(pkg.plan).not.toContain('MusicBee');
  });

  test('a saved profile works in step 2: unticking it removes its apps, ticking restores them', async ({ page }) => {
    await page.goto('/');
    await page.locator('.mode-switch [data-mode="advanced"]').click();
    const menu = page.locator('.menu-btn.in-bar');
    if ((await menu.isVisible()) && (await menu.getAttribute('aria-expanded')) !== 'true') await menu.click();
    await page.locator('.sidebar a.nav-item[data-target="section-applications"]').click();
    const section = page.locator('#section-applications');
    await section.locator('[data-profile="gaming"] input').check();
    page.once('dialog', (d) => d.accept('Game Night'));
    await section.locator('[data-action="app-save-new"]').click();
    await page.locator('.mode-switch [data-mode="quick"]').click();
    await wiz(page).getByTestId('wiz-username').fill('Sam');
    await wiz(page).locator('[data-wiz="top-next"]').click();
    const saved = wiz(page).locator('.type-item', { hasText: 'Game Night' }).locator('.type-card input');
    await expect(saved).toBeChecked();
    await expect(row(page, 'winget:valve.steam')).toHaveAttribute('data-selected', 'true');
    const withIt = await total(page);
    await saved.uncheck();
    await expect(row(page, 'winget:valve.steam')).toHaveCount(0);
    await expect(count(page)).toHaveAttribute('data-count', '0');
    await saved.check();
    await expect(count(page)).toHaveAttribute('data-count', String(withIt));
  });

  test('keyboard: Space toggles an app checkbox and focus stays', async ({ page }) => {
    await toType(page);
    await typeBox(page, 'developer').check();
    const before = await total(page);
    await box(page, GIT).focus();
    await page.keyboard.press('Space');
    await expect(box(page, GIT)).not.toBeChecked();
    await expect(box(page, GIT)).toBeFocused();
    await expect(count(page)).toHaveAttribute('data-count', String(before - 1));
    await page.keyboard.press('Space');
    await expect(box(page, GIT)).toBeChecked();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBe(true);
  });
});
