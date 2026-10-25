import { expect, test } from '@playwright/test';
import { spawn, type ChildProcess } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * Phase 10: the packaged Application Manager end to end. The ZIP the website offers is extracted,
 * its real agent (AppManager.ps1) is started on 127.0.0.1, and the built page is used in the
 * browser. Only WinGet is replaced: -WinGet points at tests/powershell/FakeWinGet.cmd, which keeps
 * "installed" packages in a JSON file. Nothing is installed or changed on this computer.
 */

test.skip(process.platform !== 'win32', 'Windows PowerShell is needed');
test.describe.configure({ mode: 'serial' });

const fakeWinGet = fileURLToPath(new URL('../powershell/FakeWinGet.cmd', import.meta.url));
let dir = '';
let agent: ChildProcess | null = null;
let url = '';
let token = '';
const statePath = () => join(dir, 'winget-state.json');
const wingetState = () => JSON.parse(readFileSync(statePath(), 'utf8').replace(/^\uFEFF/, '')) as { installed: Record<string, string>; calls: string[] };

test.beforeAll(async ({ request }) => {
  // One agent run is enough: the page itself is tested at every width in manager.spec.ts.
  test.skip(test.info().project.name !== 'desktop-chromium', 'desktop only');
  test.setTimeout(90_000);
  dir = mkdtempSync(join(tmpdir(), 'wam-e2e-'));
  const res = await request.get('/downloads/windows-deployment-app-manager.zip');
  expect(res.status()).toBe(200);
  const { readZip } = await import('../../src/engine/deployment/zip');
  for (const e of readZip(new Uint8Array(await res.body()))) {
    const to = join(dir, ...e.path.split('/'));
    mkdirSync(dirname(to), { recursive: true });
    writeFileSync(to, e.data);
  }
  writeFileSync(statePath(), JSON.stringify({ installed: { 'Google.Chrome': '130.0.1', 'VideoLAN.VLC': '3.0.21' }, available: { 'Google.Chrome': '131.0.2', 'VideoLAN.VLC': '3.0.21', 'Git.Git': '2.47.0' }, names: { 'Google.Chrome': 'Google Chrome', 'VideoLAN.VLC': 'VLC media player' }, calls: [] }));
  agent = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', join(dir, 'AppManager', 'AppManager.ps1'), '-NoBrowser', '-IdleMinutes', '5', '-DataRoot', join(dir, 'data'), '-WinGet', fakeWinGet], {
    env: { ...process.env, WDB_FAKE_WINGET_STATE: statePath() },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let out = '';
  agent.stdout!.on('data', (d) => (out += String(d)));
  agent.stderr!.on('data', (d) => (out += String(d)));
  await expect.poll(() => /Open: (http:\/\/127\.0\.0\.1:\d+\/manager\.html)#([0-9a-f]{64})/.test(out), { timeout: 60_000, message: out }).toBe(true);
  const m = /Open: (http:\/\/127\.0\.0\.1:\d+\/manager\.html)#([0-9a-f]{64})/.exec(out)!;
  url = m[1]!;
  token = m[2]!;
});

test.afterAll(async () => {
  if (agent && agent.exitCode === null) {
    try {
      await fetch(url.replace(/manager\.html$/, 'api/shutdown'), { method: 'POST', headers: { 'X-WDB-Token': token } });
    } catch {
      /* already stopped */
    }
    await new Promise((r) => setTimeout(r, 1500));
    agent.kill();
  }
  if (dir) rmSync(dir, { recursive: true, force: true });
});

test('the packaged manager: served by its agent with a strict CSP, scans, installs (after turning simulation off) and verifies', async ({ page }) => {
  test.setTimeout(120_000);
  const problems: string[] = [];
  page.on('console', (m) => { if (m.type() === 'error') problems.push(m.text()); });
  page.on('pageerror', (e) => problems.push(e.message));
  const res = await page.goto(`${url}#${token}`);
  expect(res!.headers()['content-security-policy']).toContain("default-src 'self'");
  await expect(page.getByTestId('mgr-conn')).toHaveText(/Connected/, { timeout: 20_000 });
  // Simulation is on for a new user.
  await expect(page.getByTestId('mgr-sim-banner')).toBeVisible();
  // The first connection scans (winget export); Chrome is reported with its version.
  await expect(page.locator('.mgr-app[data-app="chrome"]')).toContainText('Installed 130.0.1', { timeout: 30_000 });
  await page.getByTestId('mgr-search').fill('git');
  await page.locator('.mgr-app[data-app="git"] input').check();
  await page.locator('[data-action="mgr-review-install"]').click();
  await expect(page.locator('[data-queue="Git.Git"] [data-testid="mgr-availability"]')).toHaveText('Available', { timeout: 30_000 });
  // A simulated run first: nothing reaches WinGet.
  await page.locator('[data-action="mgr-confirm-install"]').click();
  await expect(page.getByTestId('mgr-batch').locator('[data-job="Git.Git"]')).toHaveAttribute('data-result', 'Simulated', { timeout: 20_000 });
  expect(wingetState().calls.filter((c) => c.startsWith('install'))).toEqual([]);
  // Now for real (against the fake WinGet).
  await page.getByTestId('mgr-dryrun').uncheck();
  await expect(page.getByTestId('mgr-sim-banner')).toHaveCount(0);
  await page.locator('[data-action="mgr-review-install"]').click();
  await page.locator('[data-action="mgr-confirm-install"]').click();
  const job = page.getByTestId('mgr-batch').locator('[data-job="Git.Git"]');
  await expect(job).toHaveAttribute('data-result', 'Succeeded', { timeout: 60_000 });
  await expect(job).toContainText('now 2.47.0');
  await expect(job).toContainText('Verified');
  expect(wingetState().calls).toContain('install --id Git.Git --exact --source winget --silent --no-upgrade --disable-interactivity');
  expect(wingetState().installed['Git.Git']).toBe('2.47.0');
  // Update check: read-only, Chrome listed with both versions.
  await page.locator('.mgr-tab[data-tab="updates"]').click();
  await page.locator('[data-action="mgr-check-updates"]').click();
  // Phase 10 fix: "winget upgrade --source winget" prints no Source column; the new version is read as Available.
  const chrome = page.getByTestId('mgr-updates').locator('[data-update="Google.Chrome"]');
  await expect(chrome.locator('[data-col="available"]')).toHaveText('131.0.2', { timeout: 60_000 });
  await expect(chrome.locator('[data-col="installed"]')).toHaveText('130.0.1');
  await expect(chrome.locator('[data-col="source"]')).toHaveText('winget');
  await expect(chrome).toHaveAttribute('data-eligible', 'true');
  await expect(page.locator('[data-action="mgr-update-all"]')).toHaveText('Update All Eligible Applications (1)…');
  expect(wingetState().calls).toContain('upgrade --source winget --disable-interactivity');
  // Installed: WinGet packages with their names from "winget list", and this computer's other programs (read-only).
  await page.locator('.mgr-tab[data-tab="installed"]').click();
  await expect(page.getByTestId('mgr-installed').locator('tr[data-installed="Google.Chrome"]')).toHaveAttribute('data-kind', 'catalog');
  await expect(page.getByTestId('mgr-installed').locator('tr[data-installed="Git.Git"]')).toHaveAttribute('data-kind', 'catalog');
  await expect(page.getByTestId('mgr-inst-count')).toHaveText(/^Showing (\d+) of \1\.$/);
  expect(wingetState().calls).toContain('list --disable-interactivity');
  await page.locator('.mgr-tab[data-tab="updates"]').click();
  expect(wingetState().calls.filter((c) => /^upgrade --id/.test(c))).toEqual([]);
  // The history has both operations.
  await page.locator('.mgr-tab[data-tab="history"]').click();
  await expect(page.getByTestId('mgr-history').locator('tr[data-result="Succeeded"]')).toContainText('Git.Git');
  await expect(page.getByTestId('mgr-history').locator('tr[data-result="Simulated"]')).toContainText('Git.Git');
  expect(problems).toEqual([]);
});

test('the agent refuses requests from other origins and without the session key', async ({ request }) => {
  const api = url.replace(/manager\.html$/, 'api/state');
  expect((await request.get(api)).status()).toBe(401);
  expect((await request.get(api, { headers: { 'X-WDB-Token': token, Origin: 'https://example.com' } })).status()).toBe(403);
  expect((await request.get(api, { headers: { 'X-WDB-Token': token } })).status()).toBe(200);
});
