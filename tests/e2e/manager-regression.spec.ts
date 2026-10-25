import { expect, test, type Page } from '@playwright/test';

/**
 * Phase 10 fixes, from the first real-world test of the Application Manager (2026-10-25):
 *   Bug 1: every available update appeared in the Source column and was refused.
 *   Bug 2: the ~592 other installed programs appeared, then vanished on the next background refresh
 *          (the page re-render removed the "open" state of their <details>, and drew only 500).
 * A mock agent serves the states the fixed agent produces (its parser is tested in
 * tests/powershell/AppManager.Tests.ps1 against WinGet's real layout).
 */

const TOKEN = 'c'.repeat(64);

type Item = { id: string; name: string; installed: string; available: string; source: string; eligible: boolean; reason: string; explicit?: boolean; truncated?: boolean; problem?: string };
interface Agent {
  inventory: unknown;
  updates: unknown;
  scanning: boolean;
  /** Responses to /api/state are computed when the request arrives and may be delayed. */
  delayMs: number;
  stateRequests: number;
}

const program = (name: string, i = 0) => ({ name, version: `1.${i}`, publisher: 'Publisher', scope: 'machine' });
const inventory = (programs: { name: string; version: string; publisher: string; scope: string }[], packages: [string, string][] = [['7zip.7zip', '25.01'], ['Google.Chrome', '155.0.8059.86']], scannedUtc = '2026-10-25T11:33:47Z') => ({
  parser: 2, scannedUtc, method: 'winget export', note: '', listing: 'ok',
  packages: packages.map(([id, version]) => ({ id, version, source: 'winget' })),
  listed: packages.map(([id, version]) => ({ name: id === '7zip.7zip' ? '7-Zip 25.01 (x64)' : id, id, version, source: 'winget', truncated: false })),
  programs: [program('7-Zip 25.01 (x64)'), ...programs],
});
const updates = (items: Item[], status = 'ok', note = '', problems: string[] = []) => ({ parser: 2, checkedUtc: 'c', finishedUtc: '2026-10-25T11:35:44Z', status, exitCode: '0x00000000', note, problems, items: items.map((i) => ({ explicit: false, truncated: false, problem: '', ...i })) });

function state(a: Agent) {
  return {
    agent: { version: '1.0.1', started: '', user: 'PC\\owner', elevated: false, winget: 'C:\\winget.exe', online: true },
    settings: { dryRun: true, forcedDryRun: false, acceptSourceAgreements: false },
    busy: a.scanning, running: a.scanning ? 'inventory' : '', scanning: a.scanning, checking: false,
    inventory: a.inventory, updates: a.updates, validation: {}, batch: null, messages: [],
  };
}

async function open(page: Page, a: Agent) {
  await page.route('**/api/**', async (route) => {
    const url = new URL(route.request().url());
    const json = (v: unknown) => route.fulfill({ status: 200, contentType: 'application/json; charset=utf-8', body: JSON.stringify(v) });
    if (url.pathname === '/api/state') {
      a.stateRequests++;
      const body = state(a);
      const wait = a.delayMs;
      if (wait) await new Promise((r) => setTimeout(r, wait));
      return json(body);
    }
    if (url.pathname === '/api/profiles') return json({ profiles: null });
    return json({ ok: true });
  });
  await page.goto(`/manager.html#${TOKEN}`);
  await expect(page.getByTestId('mgr-conn')).toHaveText(/Connected/);
}

const realRows: Item[] = [
  { id: '7zip.7zip', name: '7-Zip 25.01 (x64)', installed: '25.01', available: '26.05', source: 'winget', eligible: true, reason: '' },
  { id: 'VideoLAN.VLC', name: 'VLC media player', installed: '3.0.21', available: '3.0.24', source: 'winget', eligible: true, reason: '' },
  { id: 'Google.Chrome', name: 'Google Chrome', installed: '155.0.8059.86', available: '156.0.8078.48', source: 'winget', eligible: true, reason: '' },
  { id: 'WiresharkFoundation.Wireshark', name: 'Wireshark 4.4.3 x64', installed: '4.4.3', available: '4.6.9', source: 'winget', eligible: true, reason: '' },
  { id: 'Ubisoft.Connect', name: 'Ubisoft Connect', installed: '< 174.2.0.13389', available: '174.2.0.13389', source: 'winget', eligible: false, reason: 'The installed version is unknown to WinGet; it is never updated in bulk.' },
  { id: 'Discord.Discord', name: 'Discord', installed: '1.0.9259', available: '1.0.9265', source: 'winget', eligible: false, reason: 'The publisher asks for this package to be updated only on its own.', explicit: true },
];
const row = (page: Page, id: string) => page.getByTestId('mgr-updates').locator(`[data-update="${id}"]`);

test.describe('Bug 1: available updates', () => {
  test('the reported packages show their new version under Available, the source under Source, and are eligible', async ({ page }) => {
    await open(page, { inventory: inventory([]), updates: updates(realRows), scanning: false, delayMs: 0, stateRequests: 0 });
    await page.locator('.mgr-tab[data-tab="updates"]').click();
    for (const [id, inst, avail] of [['7zip.7zip', '25.01', '26.05'], ['VideoLAN.VLC', '3.0.21', '3.0.24'], ['Google.Chrome', '155.0.8059.86', '156.0.8078.48'], ['WiresharkFoundation.Wireshark', '4.4.3', '4.6.9']]) {
      await expect(row(page, id!).locator('[data-col="installed"]')).toHaveText(inst!);
      await expect(row(page, id!).locator('[data-col="available"]')).toHaveText(avail!);
      await expect(row(page, id!).locator('[data-col="source"]')).toHaveText('winget');
      await expect(row(page, id!)).toHaveAttribute('data-eligible', 'true');
    }
    await expect(row(page, 'Ubisoft.Connect')).toHaveAttribute('data-eligible', 'false');
    await expect(row(page, 'Discord.Discord')).toContainText('Only on its own');
    await expect(page.locator('[data-action="mgr-update-all"]')).toHaveText('Update All Eligible Applications (4)…');
    await page.locator('[data-action="mgr-update-all"]').click();
    const review = page.getByTestId('mgr-review-upgrade');
    await expect(review.locator('[data-upgrade]')).toHaveCount(4);
    await expect(review.locator('[data-upgrade="7zip.7zip"]')).toContainText('25.01 → 26.05');
    await expect(review.locator('[data-upgrade="7zip.7zip"] .mgr-cmd')).toHaveText('winget upgrade --id 7zip.7zip --exact --source winget --silent --disable-interactivity');
    await expect(page.getByTestId('mgr-upgrade-excluded')).toContainText('Ubisoft Connect');
    await expect(page.getByTestId('mgr-upgrade-excluded')).toContainText('Discord');
  });

  test('rows in the shape the first agent produced (new version under Source) are refused as unreadable, never offered in bulk', async ({ page }) => {
    const broken = realRows.slice(0, 4).map((r) => ({ ...r, available: '', source: r.available, eligible: false, reason: 'No newer version is listed.' }));
    await open(page, { inventory: inventory([]), updates: updates(broken), scanning: false, delayMs: 0, stateRequests: 0 });
    await page.locator('.mgr-tab[data-tab="updates"]').click();
    await expect(row(page, '7zip.7zip')).toHaveAttribute('data-readable', 'false');
    await expect(row(page, '7zip.7zip')).toContainText('Could not read');
    await expect(row(page, '7zip.7zip')).toContainText('"26.05" was read as a source');
    await expect(row(page, '7zip.7zip').locator('input')).toBeDisabled();
    await expect(page.locator('[data-action="mgr-update-all"]')).toBeDisabled();
  });

  test('output the agent could not read is reported with its problems, and nothing is eligible', async ({ page }) => {
    const rows = [{ ...realRows[0]!, eligible: false, problem: "'winget' was read as a version", reason: 'x' }];
    await open(page, { inventory: inventory([]), updates: updates(rows, 'parseError', "WinGet's output could not be read reliably, so nothing from it is eligible for updating.", ["7zip.7zip: 'winget' was read as a version"]), scanning: false, delayMs: 0, stateRequests: 0 });
    await page.locator('.mgr-tab[data-tab="updates"]').click();
    await expect(page.getByTestId('mgr-updates-status')).toContainText('could not be read reliably');
    await expect(page.getByTestId('mgr-updates-status')).toContainText("7zip.7zip: 'winget' was read as a version");
    await expect(page.locator('[data-action="mgr-update-all"]')).toBeDisabled();
  });
});

test.describe('Bug 2: installed programs', () => {
  test('594 other programs stay listed through repeated background refreshes, with stable counts', async ({ page }) => {
    test.setTimeout(60_000);
    const a: Agent = { inventory: inventory(Array.from({ length: 594 }, (_, i) => program(`Program ${String(i).padStart(3, '0')}`, i))), updates: null, scanning: false, delayMs: 0, stateRequests: 0 };
    await open(page, a);
    await page.locator('.mgr-tab[data-tab="installed"]').click();
    const other = page.getByTestId('mgr-installed').locator('tr[data-kind="other"]');
    await expect(other).toHaveCount(594);
    await expect(page.getByTestId('mgr-inst-count')).toHaveText('Showing 596 of 596.');
    await expect(page.locator('[data-inst-group="other"]')).toHaveText('Other programs (594)');
    // Several polls later (every 4 s while idle), nothing has disappeared.
    const seen = a.stateRequests;
    await expect.poll(() => a.stateRequests, { timeout: 15_000 }).toBeGreaterThanOrEqual(seen + 2);
    await expect(other).toHaveCount(594);
    await expect(other.last()).toBeVisible();
    await expect(page.getByTestId('mgr-inst-count')).toHaveText('Showing 596 of 596.');
    // Group and search are kept across refreshes too.
    await page.locator('[data-inst-group="other"]').click();
    await page.getByTestId('mgr-inst-search').fill('Program 59');
    await expect(page.getByTestId('mgr-inst-count')).toHaveText('Showing 4 of 596.');
    await expect.poll(() => a.stateRequests, { timeout: 10_000 }).toBeGreaterThanOrEqual(seen + 3);
    await expect(page.getByTestId('mgr-inst-count')).toHaveText('Showing 4 of 596.');
    await expect(page.getByTestId('mgr-inst-search')).toHaveValue('Program 59');
    // The three kinds are told apart; only WinGet packages can be selected for removal.
    await page.locator('[data-inst-group="all"]').click();
    await page.getByTestId('mgr-inst-search').fill('');
    await expect(page.getByTestId('mgr-installed').locator('tr[data-kind="catalog"]')).toHaveCount(2);
    await expect(page.getByTestId('mgr-installed').locator('tr[data-kind="other"] input')).toHaveCount(0);
    await expect(page.getByTestId('mgr-inv-summary')).toContainText('Only WinGet packages can be updated or removed here');
    // 7-Zip is listed once (with its package), not again as a Windows program.
    await expect(page.getByTestId('mgr-installed').locator('tr', { hasText: '7-Zip' })).toHaveCount(1);
  });

  test('while a new scan runs, the last list stays on screen and the scan is shown', async ({ page }) => {
    const a: Agent = { inventory: inventory([program('Contoso Field Tool')]), updates: null, scanning: true, delayMs: 0, stateRequests: 0 };
    await open(page, a);
    await page.locator('.mgr-tab[data-tab="installed"]').click();
    await expect(page.getByTestId('mgr-inv-rescanning')).toContainText('this list stays');
    await expect(page.getByTestId('mgr-installed')).toContainText('Contoso Field Tool');
    await expect(page.locator('[data-action="mgr-scan"]')).toBeDisabled();
    a.inventory = inventory([program('Contoso Field Tool'), program('Newer Program')], undefined, '2026-10-25T12:00:00Z');
    a.scanning = false;
    await expect(page.getByTestId('mgr-installed')).toContainText('Newer Program', { timeout: 10_000 });
    await expect(page.getByTestId('mgr-inv-rescanning')).toHaveCount(0);
  });

  test('an older response that arrives late never replaces a newer one', async ({ page }) => {
    test.setTimeout(60_000);
    const a: Agent = { inventory: inventory([program('Old Program')]), updates: null, scanning: false, delayMs: 0, stateRequests: 0 };
    await open(page, a);
    await page.locator('.mgr-tab[data-tab="installed"]').click();
    await expect(page.getByTestId('mgr-installed')).toContainText('Old Program');
    // The next poll is slow: it was asked before the scan finished and still describes the old list.
    a.delayMs = 3000;
    const before = a.stateRequests;
    await expect.poll(() => a.stateRequests, { timeout: 10_000 }).toBeGreaterThan(before);
    // Meanwhile a scan completes and the page asks again: the new list arrives first.
    a.delayMs = 0;
    a.inventory = inventory([program('New Program')], undefined, '2026-10-25T12:10:00Z');
    await page.locator('[data-action="mgr-scan"]').click();
    await expect(page.getByTestId('mgr-installed')).toContainText('New Program');
    // The slow, older response lands now and must be ignored.
    await page.waitForTimeout(3500);
    await expect(page.getByTestId('mgr-installed')).toContainText('New Program');
    await expect(page.getByTestId('mgr-installed')).not.toContainText('Old Program');
  });

  test('1,200 programs: every row drawn, filtering stays responsive', async ({ page }) => {
    test.setTimeout(60_000);
    await open(page, { inventory: inventory(Array.from({ length: 1200 }, (_, i) => program(`Program ${String(i).padStart(4, '0')}`, i))), updates: null, scanning: false, delayMs: 0, stateRequests: 0 });
    await page.locator('.mgr-tab[data-tab="installed"]').click();
    await expect(page.getByTestId('mgr-installed').locator('tr[data-kind="other"]')).toHaveCount(1200);
    const ms = await page.evaluate(() => {
      const t = performance.now();
      (document.querySelector('[data-inst-group="winget"]') as HTMLButtonElement).click();
      (document.querySelector('[data-inst-group="all"]') as HTMLButtonElement).click();
      return performance.now() - t;
    });
    expect(ms).toBeLessThan(1500);
    await expect(page.getByTestId('mgr-inst-count')).toHaveText('Showing 1202 of 1202.');
  });
});
