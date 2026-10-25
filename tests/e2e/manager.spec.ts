import { expect, test, type Page, type Route } from '@playwright/test';
import { readFile } from 'node:fs/promises';

/**
 * Phase 10: the Application Manager page (manager.html) against a mock of the local agent. The
 * mock follows AppManager.ps1's API (the agent itself is tested in tests/powershell/AppManager.Tests.ps1
 * with a simulated WinGet); nothing here runs WinGet.
 */

const TOKEN = 'a'.repeat(64);

interface Mock {
  online: boolean;
  dryRun: boolean;
  installed: Record<string, string>;
  available: Record<string, string>;
  agreements: string[];
  fail: string[];
  updates: { id: string; name: string; installed: string; available: string; eligible: boolean; reason: string; explicit?: boolean }[] | null;
  validation: Record<string, { status: string; version?: string; agreements?: boolean; detail: string }>;
  batch: null | { id: string; action: string; dryRun: boolean; startedUtc: string; jobs: { id: string; packageId: string; name: string; action: string; state: string; record: unknown }[] };
  history: Record<string, unknown>[];
  profiles: unknown;
  operations: { action: string; confirm: string; items: Record<string, unknown>[] }[];
  scans: string[];
  validated: string[];
}

function newMock(over: Partial<Mock> = {}): Mock {
  return {
    online: true, dryRun: false,
    installed: { 'Google.Chrome': '130.0.1', 'VideoLAN.VLC': '3.0.20', 'Microsoft.VCRedist.2015+.x64': '14.40', 'Contoso.Tool': '1.0', 'PrivateInternetAccess.PrivateInternetAccess': '3.6' },
    available: { 'Google.Chrome': '131.0', 'VideoLAN.VLC': '3.0.21', 'Valve.Steam': '2.10', 'Parsec.Parsec': '150-97', 'Git.Git': '2.47.0', 'Discord.Discord': '1.0.9', 'Spotify.Spotify': '1.2' },
    agreements: ['Spotify.Spotify'], fail: [],
    updates: null, validation: {}, batch: null, history: [], profiles: null, operations: [], scans: [], validated: [],
    ...over,
  };
}

const record = (m: Mock, job: { id: string; packageId: string; name: string; action: string }, batchId: string) => {
  const ok = !m.fail.includes(job.packageId);
  const r = {
    format: 'windows-deployment-builder/app-manager-operation', version: 1, operationId: job.id, batchId, requestedBy: 'PC\\owner', startedUtc: '2026-10-25T12:00:00Z', finishedUtc: '2026-10-25T12:01:00Z',
    action: job.action, packageId: job.packageId, source: 'winget', name: job.name, catalogId: '', scope: '', priorVersion: m.installed[job.packageId] ?? '', resultVersion: '',
    exitCode: ok ? '0x00000000' : '0x8A150008', symbol: ok ? 'Installed.' : 'Download failed (DOWNLOAD_FAILED).', failureClass: ok ? 'Success' : 'Network',
    result: m.dryRun ? 'Simulated' : ok ? 'Succeeded' : 'Failed', verification: m.dryRun ? 'Simulated' : ok ? 'Verified' : 'NotVerified', restartRequired: false, manualAction: '',
    retryable: !m.dryRun && !ok, attempt: 1, retryOf: '', dryRun: m.dryRun, command: `winget ${job.action} --id ${job.packageId} --exact --source winget --silent --disable-interactivity`, output: '',
  };
  if (!m.dryRun && ok) {
    if (job.action === 'uninstall') delete m.installed[job.packageId];
    else m.installed[job.packageId] = r.resultVersion = m.available[job.packageId] ?? '1.0';
  }
  return r;
};

function state(m: Mock) {
  return {
    agent: { version: '1.0.0', started: '2026-10-25T12:00:00Z', user: 'PC\\owner', elevated: false, winget: 'C:\\winget.exe', online: m.online },
    settings: { dryRun: m.dryRun, forcedDryRun: false, acceptSourceAgreements: false },
    busy: false, running: '',
    inventory: { scannedUtc: '2026-10-25T12:00:00Z', method: 'winget export', note: '', packages: Object.entries(m.installed).map(([id, version]) => ({ id, version, source: 'winget' })), programs: [{ name: 'Contoso Field Tool', version: '4.1', publisher: 'Contoso', scope: 'machine' }] },
    updates: m.updates ? { checkedUtc: 'c', finishedUtc: '2026-10-25T12:05:00Z', status: m.online ? 'ok' : 'networkUnavailable', exitCode: '0x00000000', note: m.online ? '' : 'No network: updates cannot be checked now. Installed applications are not affected.', items: m.updates.map((u) => ({ source: 'winget', explicit: false, truncated: false, ...u })) } : null,
    validation: m.validation, batch: m.batch, messages: [],
  };
}

async function mockAgent(page: Page, m: Mock) {
  await page.route('**/api/**', async (route: Route) => {
    const req = route.request();
    const url = new URL(req.url());
    if (req.headers()['x-wdb-token'] !== TOKEN) return route.fulfill({ status: 401, contentType: 'application/json', body: '{"error":"Missing or wrong session token."}' });
    const body = req.postData() ? JSON.parse(req.postData()!) : {};
    const json = (status: number, v: unknown) => route.fulfill({ status, contentType: 'application/json; charset=utf-8', body: JSON.stringify(v) });
    const key = `${req.method()} ${url.pathname}`;
    switch (key) {
      case 'GET /api/state': return json(200, state(m));
      case 'POST /api/scan':
        m.scans.push(body.kind);
        if (body.kind === 'updates') m.updates = Object.entries(m.installed).filter(([id, v]) => m.available[id] && m.available[id] !== v).map(([id, v]) => ({ id, name: id.split('.').pop()!, installed: v, available: m.available[id]!, eligible: id !== 'Parsec.Parsec', explicit: id === 'Parsec.Parsec', reason: id === 'Parsec.Parsec' ? 'The publisher asks for this package to be updated only on its own.' : '' }));
        return json(202, { ok: true });
      case 'POST /api/validate':
        for (const it of body.items) {
          m.validated.push(it.id);
          m.validation[`${it.source}:${it.id}`.toLowerCase()] = !m.online ? { status: 'networkUnavailable', detail: 'No network: availability cannot be checked now.' } : m.available[it.id] ? { status: 'available', version: m.available[it.id], agreements: m.agreements.includes(it.id), detail: '' } : { status: 'notFound', detail: 'Not found in this source now.' };
        }
        return json(202, { ok: true });
      case 'POST /api/operations': {
        m.operations.push(body);
        if (body.action === 'uninstall' && body.confirm !== 'REMOVE') return json(400, { ok: false, error: 'Removal needs the confirmation word REMOVE.' });
        const id = `b${m.operations.length}`;
        const jobs = body.items.map((it: { id: string; name: string }, i: number) => ({ id: `${id}-${i}`, packageId: it.id, name: it.name, action: body.action, state: 'Done', record: null as unknown }));
        for (const j of jobs) {
          j.record = record(m, j, id);
          m.history.push(j.record as Record<string, unknown>);
        }
        m.batch = { id, action: body.action, dryRun: m.dryRun, startedUtc: '2026-10-25T12:00:00Z', jobs };
        return json(202, { ok: true, batchId: id, dryRun: m.dryRun, commands: [] });
      }
      case 'POST /api/settings': if ('dryRun' in body) m.dryRun = body.dryRun; return json(200, { ok: true });
      case 'POST /api/cancel': return json(200, { ok: true, cancelled: 0 });
      case 'GET /api/profiles': return json(200, { profiles: m.profiles });
      case 'PUT /api/profiles': m.profiles = body; return json(200, { ok: true });
      case 'GET /api/history': return json(200, { records: m.history });
      case 'GET /api/report':
        if (url.searchParams.get('format') === 'csv') return route.fulfill({ status: 200, contentType: 'text/csv; charset=utf-8', body: 'finishedUtc,action,name,packageId\r\n' + m.history.map((r) => `${r.finishedUtc},${r.action},${r.name},${r.packageId}`).join('\r\n') });
        return json(200, { format: 'windows-deployment-builder/app-manager-history', version: 1, records: m.history });
    }
    return json(404, { error: 'Unknown API.' });
  });
}

async function open(page: Page, m: Mock) {
  await mockAgent(page, m);
  await page.goto(`/manager.html#${TOKEN}`);
  await expect(page.getByTestId('mgr-conn')).toHaveText(/Connected/);
}

const tab = (page: Page, id: string) => page.locator(`.mgr-tab[data-tab="${id}"]`);
const app = (page: Page, id: string) => page.locator(`.mgr-app[data-app="${id}"]`);
const action = (page: Page, a: string) => page.locator(`[data-action="${a}"]`);

test('without the local agent: a read-only catalog, no operations, a download link for the manager', async ({ page }) => {
  await page.goto('/manager.html');
  await expect(page.getByTestId('mgr-conn')).toHaveText('Not connected');
  await expect(page.getByTestId('mgr-not-connected')).toContainText('a website cannot install software');
  const href = await page.getByTestId('mgr-download').getAttribute('href');
  expect(href).toBe('downloads/windows-deployment-app-manager.zip');
  const res = await page.request.get(`/${href}`);
  expect(res.status()).toBe(200);
  const { readZip } = await import('../../src/engine/deployment/zip');
  const names = readZip(new Uint8Array(await res.body())).map((e) => e.path);
  for (const f of ['AppManager/AppManager.ps1', 'AppManager/Install-AppManager.ps1', 'AppManager/Start-AppManager.cmd', 'AppManager/catalog-policy.json', 'AppManager/files.json', 'AppManager/lib/ApplicationEngine.ps1', 'AppManager/ui/manager.html']) expect(names).toContain(f);
  expect(names.some((n) => /^AppManager\/ui\/assets\/manager-.*\.js$/.test(n))).toBe(true);
  expect(names.some((n) => n.endsWith('.map'))).toBe(false);
  // Browsing works; statuses are "not scanned", never "not installed".
  await expect(app(page, 'chrome')).toContainText('Not scanned yet');
  await app(page, 'chrome').locator('input').check();
  await action(page, 'mgr-review-install').click();
  await expect(action(page, 'mgr-confirm-install')).toBeDisabled();
});

test('the builder links to the Application Manager', async ({ page }) => {
  await page.goto('/');
  await page.locator('[data-action="open-manager"]').click();
  await expect(page).toHaveURL(/\/manager\.html$/);
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Windows Deployment — Application Manager');
});

test('a wrong session key is refused and nothing is shown as installed', async ({ page }) => {
  await mockAgent(page, newMock());
  await page.goto(`/manager.html#${'b'.repeat(64)}`);
  await expect(page.getByTestId('mgr-not-connected')).toContainText('session key was not accepted');
  // The key is removed from the address bar.
  expect(new URL(page.url()).hash).toBe('');
});

test('browse: categories, search, publisher and status filters; installed versions; nothing selected by default', async ({ page }) => {
  const m = newMock();
  await open(page, m);
  await expect(page.getByTestId('mgr-plan-count')).toHaveText(/^0 selected/);
  await expect(app(page, 'chrome')).toContainText('Installed 130.0.1');
  await page.getByTestId('mgr-category').selectOption('gaming');
  await expect(page.locator('.mgr-group')).toHaveCount(1);
  await expect(page.locator('.mgr-group h2')).toContainText('Gaming Platforms & Tools');
  await page.getByTestId('mgr-category').selectOption('');
  await page.getByTestId('mgr-search').fill('wireshark');
  await expect(page.locator('.mgr-app')).toHaveCount(1);
  await expect(app(page, 'wireshark')).toContainText('WiresharkFoundation.Wireshark');
  await page.getByTestId('mgr-search').fill('');
  await page.getByTestId('mgr-status-filter').selectOption('installed');
  await expect(app(page, 'vlc')).toBeVisible();
  await expect(app(page, 'steam')).toHaveCount(0);
  await page.getByTestId('mgr-status-filter').selectOption('manual');
  await expect(app(page, 'vmware-workstation')).toContainText('Manual installer');
  await page.getByTestId('mgr-status-filter').selectOption('all');
  await page.getByTestId('mgr-publisher').selectOption('Valve Corporation');
  await expect(page.locator('.mgr-app')).toHaveCount(1);
  expect(m.operations).toHaveLength(0);
});

test('profiles stack without duplicates; the selection is saved through the agent; built-in profiles stay unchanged', async ({ page }) => {
  const m = newMock();
  await open(page, m);
  await tab(page, 'profiles').click();
  await page.locator('[data-profile-toggle="gaming"]').check();
  await page.locator('[data-profile-toggle="creator"]').check();
  const combined = page.getByTestId('mgr-combined');
  await expect(combined.locator('[data-combined="winget:obsproject.obsstudio"]')).toHaveCount(1);
  await expect(combined.locator('[data-combined="winget:obsproject.obsstudio"]')).toContainText('Content Creator');
  await tab(page, 'browse').click();
  await expect(app(page, 'steam')).toContainText('Selected by Gaming');
  await app(page, 'steam').locator('input').uncheck();
  await expect(app(page, 'steam')).toContainText('Unticked by you');
  await expect.poll(() => JSON.stringify(m.profiles)).toContain('"removed":["winget:valve.steam"]');
  await tab(page, 'profiles').click();
  await page.getByTestId('mgr-new-profile').fill('Den PC');
  await action(page, 'mgr-profile-save').click();
  await expect(page.getByTestId('mgr-notice')).toContainText('Saved "Den PC"');
  await expect(page.locator('[data-profile-toggle="gaming"]')).not.toBeChecked();
  await expect(page.locator('.mgr-profile[data-profile="gaming"]')).toContainText('selected');
  await expect.poll(() => JSON.stringify(m.profiles)).toContain('Den PC');
  // Reload: the saved selection comes back from the agent.
  await page.reload();
  await page.goto(`/manager.html#${TOKEN}`);
  await tab(page, 'profiles').click();
  await expect(page.locator('[data-profile-toggle="den-pc"]')).toBeChecked();
  expect(m.operations).toHaveLength(0);
});

test('install: the queue is validated in the source first, licences are never accepted for the user, failures do not hide successes', async ({ page }) => {
  const m = newMock({ fail: ['Discord.Discord'] });
  await open(page, m);
  for (const id of ['git', 'discord', 'spotify', 'chrome', 'vmware-workstation']) {
    await page.getByTestId('mgr-search').fill(id === 'vmware-workstation' ? 'vmware' : id);
    await app(page, id).locator('input').check();
  }
  await page.getByTestId('mgr-search').fill('');
  await expect(page.getByTestId('mgr-plan-count')).toContainText('5 selected: 3 to install, 1 already installed, 1 manual');
  await action(page, 'mgr-review-install').click();
  const review = page.getByTestId('mgr-review-install');
  await expect(review.locator('[data-queue="Git.Git"] [data-testid="mgr-availability"]')).toHaveText('Available');
  await expect(review.locator('[data-queue="Git.Git"] .mgr-cmd')).toHaveText('winget install --id Git.Git --exact --source winget --silent --no-upgrade --disable-interactivity');
  await expect(page.getByTestId('mgr-review-installed')).toContainText('Google Chrome 130.0.1');
  await expect(page.getByTestId('mgr-review-manual')).toContainText('support.broadcom.com');
  // Spotify declares a licence agreement: confirm stays disabled until the user accepts it.
  await expect(action(page, 'mgr-confirm-install')).toBeDisabled();
  await review.locator('[data-accept="Spotify.Spotify"]').check();
  await expect(review.locator('[data-queue="Spotify.Spotify"] .mgr-cmd')).toContainText('--accept-package-agreements');
  // Nothing overlaps the buttons, at any width (the long manual instructions wrap).
  expect(await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)).toBeLessThanOrEqual(1);
  await action(page, 'mgr-confirm-install').click();
  const batch = page.getByTestId('mgr-batch');
  await expect(batch).toContainText('Installation: finished');
  await expect(batch.locator('[data-job="Git.Git"]')).toHaveAttribute('data-result', 'Succeeded');
  await expect(batch.locator('[data-job="Discord.Discord"]')).toHaveAttribute('data-result', 'Failed');
  await expect(page.getByTestId('mgr-batch-summary')).toHaveText('2 done, 1 failed, 0 need attention.');
  const op = m.operations[0]!;
  expect(op.action).toBe('install');
  expect(op.items.map((i) => i.id)).toEqual(['Git.Git', 'Discord.Discord', 'Spotify.Spotify']);
  expect(op.items.find((i) => i.id === 'Spotify.Spotify')!.acceptPackageAgreements).toBe(true);
  expect(op.items.find((i) => i.id === 'Git.Git')!.acceptPackageAgreements).toBe(false);
  // Only identifiers go to the agent, never a command line.
  expect(JSON.stringify(op)).not.toContain('winget install');
  await action(page, 'mgr-retry').click();
  expect(m.operations[1]!.items).toEqual([expect.objectContaining({ id: 'Discord.Discord', attempt: 2 })]);
});

test('install: an identifier not found in the source, or no network, blocks the queue instead of claiming removal', async ({ page }) => {
  const m = newMock();
  delete m.available['Git.Git'];
  await open(page, m);
  await page.getByTestId('mgr-search').fill('git');
  await app(page, 'git').locator('input').check();
  await action(page, 'mgr-review-install').click();
  await expect(page.locator('[data-queue="Git.Git"] [data-testid="mgr-availability"]')).toHaveText('Not found in source');
  await expect(page.getByTestId('mgr-not-ready')).toBeVisible();
  await expect(action(page, 'mgr-confirm-install')).toBeDisabled();
  m.online = false;
  m.available['Git.Git'] = '2.47.0';
  await action(page, 'mgr-revalidate').click();
  await expect(page.locator('[data-queue="Git.Git"] [data-testid="mgr-availability"]')).toHaveText('Network unavailable');
  await expect(page.getByTestId('mgr-offline')).toBeVisible();
  await expect(action(page, 'mgr-confirm-install')).toBeDisabled();
  expect(m.operations).toHaveLength(0);
});

test('simulation mode: clearly shown, and the batch is recorded as simulated', async ({ page }) => {
  const m = newMock({ dryRun: true });
  await open(page, m);
  await expect(page.getByTestId('mgr-sim-banner')).toContainText('nothing is installed');
  await page.getByTestId('mgr-search').fill('steam');
  await app(page, 'steam').locator('input').check();
  await action(page, 'mgr-review-install').click();
  await expect(action(page, 'mgr-confirm-install')).toHaveText('Simulate 1 installation(s)');
  await action(page, 'mgr-confirm-install').click();
  await expect(page.getByTestId('mgr-batch')).toContainText('(simulated)');
  await expect(page.getByTestId('mgr-batch').locator('[data-job="Valve.Steam"]')).toHaveAttribute('data-result', 'Simulated');
  await page.getByTestId('mgr-dryrun').uncheck();
  await expect(page.getByTestId('mgr-sim-banner')).toHaveCount(0);
});

test('updates: read-only check, preview, Update All Eligible excludes packages that must be updated on their own', async ({ page }) => {
  const m = newMock();
  m.installed['Parsec.Parsec'] = '150-93';
  await open(page, m);
  await tab(page, 'updates').click();
  await expect(page.locator('.mgr-explain')).toContainText('WinGet is not APT');
  await action(page, 'mgr-check-updates').click();
  const table = page.getByTestId('mgr-updates');
  await expect(table.locator('[data-update="Google.Chrome"]')).toContainText('130.0.1');
  await expect(table.locator('[data-update="Google.Chrome"]')).toContainText('131.0');
  await expect(table.locator('[data-update="Parsec.Parsec"]')).toHaveAttribute('data-eligible', 'false');
  expect(m.operations).toHaveLength(0);
  await action(page, 'mgr-update-all').click();
  const review = page.getByTestId('mgr-review-upgrade');
  await expect(review.locator('[data-upgrade]')).toHaveCount(2);
  await expect(review.locator('[data-upgrade="Google.Chrome"] .mgr-cmd')).toHaveText('winget upgrade --id Google.Chrome --exact --source winget --silent --disable-interactivity');
  await expect(page.getByTestId('mgr-upgrade-excluded')).toContainText('Parsec');
  await action(page, 'mgr-confirm-upgrade').click();
  await expect(page.getByTestId('mgr-batch')).toContainText('Update: finished');
  expect(m.operations[0]!.action).toBe('upgrade');
  expect(m.operations[0]!.items.map((i) => i.id).sort()).toEqual(['Google.Chrome', 'VideoLAN.VLC']);
  expect(m.operations[0]!.items.find((i) => i.id === 'Google.Chrome')!.installedVersion).toBe('130.0.1');
});

test('updates: one package can be chosen on its own, including one the publisher wants updated individually', async ({ page }) => {
  const m = newMock();
  m.installed['Parsec.Parsec'] = '150-93';
  await open(page, m);
  await tab(page, 'updates').click();
  await action(page, 'mgr-check-updates').click();
  await page.locator('[data-update-pick="Parsec.Parsec"]').check();
  await action(page, 'mgr-update-selected').click();
  await expect(page.getByTestId('mgr-review-upgrade').locator('[data-upgrade]')).toHaveCount(1);
  await action(page, 'mgr-confirm-upgrade').click();
  expect(m.operations[0]!.items.map((i) => i.id)).toEqual(['Parsec.Parsec']);
});

test('installed and removal: runtimes are protected, security software is removed only on its own, REMOVE is required, data is kept', async ({ page }) => {
  const m = newMock();
  await open(page, m);
  await tab(page, 'installed').click();
  const t = page.getByTestId('mgr-installed');
  await expect(t.locator('[data-installed="Contoso.Tool"]')).toContainText('Extra confirmation');
  await expect(t.locator('[data-remove-pick="Microsoft.VCRedist.2015+.x64"]')).toBeDisabled();
  await expect(t.locator('[data-installed="Microsoft.VCRedist.2015+.x64"]')).toContainText('Protected');
  await expect(page.getByTestId('mgr-programs')).toContainText('Contoso Field Tool');
  // Bulk: VLC with a VPN is refused.
  await t.locator('[data-remove-pick="VideoLAN.VLC"]').check();
  await t.locator('[data-remove-pick="PrivateInternetAccess.PrivateInternetAccess"]').check();
  await action(page, 'mgr-review-remove').click();
  await expect(page.getByTestId('mgr-not-bulk')).toContainText('Private Internet Access');
  await page.getByTestId('mgr-remove-word').fill('REMOVE');
  await expect(action(page, 'mgr-confirm-remove')).toBeDisabled();
  await action(page, 'mgr-back').click();
  await t.locator('[data-remove-pick="PrivateInternetAccess.PrivateInternetAccess"]').uncheck();
  await action(page, 'mgr-review-remove').click();
  const review = page.getByTestId('mgr-review-uninstall');
  await expect(review).toContainText('documents, settings and application data are not deleted');
  await expect(review.locator('[data-remove="VideoLAN.VLC"] .mgr-cmd')).toHaveText('winget uninstall --id VideoLAN.VLC --exact --source winget --silent --disable-interactivity');
  await expect(action(page, 'mgr-confirm-remove')).toBeDisabled();
  await page.getByTestId('mgr-remove-word').fill('remove');
  await expect(action(page, 'mgr-confirm-remove')).toBeDisabled();
  await page.getByTestId('mgr-remove-word').fill('REMOVE');
  await action(page, 'mgr-confirm-remove').click();
  await expect(page.getByTestId('mgr-batch')).toContainText('Removal: finished');
  expect(m.operations).toEqual([expect.objectContaining({ action: 'uninstall', confirm: 'REMOVE', items: [expect.objectContaining({ id: 'VideoLAN.VLC' })] })]);
  // A caution package alone needs its own acknowledgement.
  await tab(page, 'installed').click();
  await t.locator('[data-remove-pick="PrivateInternetAccess.PrivateInternetAccess"]').check();
  await action(page, 'mgr-review-remove').click();
  await page.getByTestId('mgr-remove-word').fill('REMOVE');
  await expect(action(page, 'mgr-confirm-remove')).toBeDisabled();
  await page.locator('[data-caution="PrivateInternetAccess.PrivateInternetAccess"]').check();
  await action(page, 'mgr-confirm-remove').click();
  expect(m.operations[1]!.items[0]!.confirmCaution).toBe(true);
});

test('unticking an application in a profile never removes it', async ({ page }) => {
  const m = newMock();
  await open(page, m);
  await tab(page, 'profiles').click();
  await page.locator('[data-profile-toggle="core"]').check();
  await page.locator('[data-profile-toggle="core"]').uncheck();
  await tab(page, 'browse').click();
  await page.getByTestId('mgr-search').fill('vlc');
  await app(page, 'vlc').locator('input').check();
  await app(page, 'vlc').locator('input').uncheck();
  await expect(app(page, 'vlc')).toContainText('Installed 3.0.20');
  expect(m.operations).toHaveLength(0);
});

test('history and reports: every operation listed; CSV and JSON exports', async ({ page }) => {
  const m = newMock();
  await open(page, m);
  await page.getByTestId('mgr-search').fill('steam');
  await app(page, 'steam').locator('input').check();
  await action(page, 'mgr-review-install').click();
  await action(page, 'mgr-confirm-install').click();
  await tab(page, 'history').click();
  await expect(page.getByTestId('mgr-history').locator('tr[data-result="Succeeded"]')).toContainText('Valve.Steam');
  const [csv] = await Promise.all([page.waitForEvent('download'), action(page, 'mgr-report-csv').click()]);
  expect(csv.suggestedFilename()).toBe('application-manager-history.csv');
  expect(await readFile((await csv.path())!, 'utf8')).toContain('Valve.Steam');
  const [json] = await Promise.all([page.waitForEvent('download'), action(page, 'mgr-report-json').click()]);
  expect(JSON.parse(await readFile((await json.path())!, 'utf8')).format).toBe('windows-deployment-builder/app-manager-history');
});

test('offline: installed applications, the last update check, profiles and history stay available', async ({ page }) => {
  const m = newMock({ online: false, updates: [{ id: 'Google.Chrome', name: 'Chrome', installed: '130.0.1', available: '131.0', eligible: true, reason: '' }] });
  await open(page, m);
  await expect(page.getByTestId('mgr-offline')).toContainText('still shown');
  await tab(page, 'installed').click();
  await expect(page.getByTestId('mgr-installed')).toContainText('Google Chrome');
  await tab(page, 'updates').click();
  await expect(page.getByTestId('mgr-updates-status')).toContainText('No network');
  await expect(page.getByTestId('mgr-updates').locator('[data-update="Google.Chrome"]')).toBeVisible();
});

test('accessible tabs and no horizontal scrolling at phone width', async ({ page }) => {
  await open(page, newMock());
  await expect(page.getByRole('tablist')).toBeVisible();
  await expect(page.getByRole('tab', { name: 'Browse applications' })).toHaveAttribute('aria-selected', 'true');
  await page.getByRole('tab', { name: 'Updates' }).click();
  await expect(page.getByRole('tab', { name: 'Updates' })).toHaveAttribute('aria-selected', 'true');
  for (const t of ['browse', 'installed', 'updates', 'profiles', 'history']) {
    await tab(page, t).click();
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    expect(overflow, t).toBeLessThanOrEqual(1);
  }
  // Every checkbox has an accessible name.
  await tab(page, 'browse').click();
  const unnamed = await page.locator('input[type="checkbox"]').evaluateAll((els) => els.filter((e) => !e.getAttribute('aria-label') && !(e as HTMLInputElement).labels?.length).length);
  expect(unnamed).toBe(0);
});
