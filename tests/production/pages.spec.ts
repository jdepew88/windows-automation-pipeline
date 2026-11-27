import { expect, test, type Page } from '@playwright/test';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';

/**
 * The production build as Cloudflare Pages serves it (playwright.production.config.ts): security
 * headers, no Content-Security-Policy violations, no requests to other origins, and the main
 * browser features working under that policy.
 */

const wiz = (page: Page) => page.getByTestId('wizard');

/** Records CSP violations (the event and the console report) and every request to another origin. */
function watch(page: Page, base: string) {
  const violations: string[] = [];
  const external: string[] = [];
  page.on('console', (m) => {
    if (/Content Security Policy|Refused to/i.test(m.text())) violations.push(m.text());
  });
  page.on('request', (r) => {
    const u = new URL(r.url());
    if (!['blob:', 'data:', 'about:'].includes(u.protocol) && u.origin !== new URL(base).origin) external.push(r.url());
  });
  return { violations, external };
}

test.beforeEach(async ({ page }) => {
  // Every frame reports violations into the console, where watch() sees them (also the health preview's srcdoc frame).
  await page.addInitScript(() => {
    document.addEventListener('securitypolicyviolation', (e) => console.error(`Refused to load: CSP ${e.violatedDirective} ${e.blockedURI} ${e.sourceFile}:${e.lineNumber}`));
  });
});

async function adv(page: Page, target: string) {
  if ((await page.locator('.mode-switch [data-mode="advanced"]').getAttribute('aria-pressed')) !== 'true') await page.locator('.mode-switch [data-mode="advanced"]').click();
  const menu = page.locator('.menu-btn.in-bar');
  if ((await menu.isVisible()) && (await menu.getAttribute('aria-expanded')) !== 'true') await menu.click();
  await page.locator(`.sidebar a.nav-item[data-target="${target}"]`).click();
  await expect(page.locator(`#${target}`)).toBeVisible();
}

test('security headers on pages, assets and downloads; source maps and _headers are not served', async ({ request }) => {
  const page = await request.get('/');
  expect(page.status()).toBe(200);
  const h = page.headers();
  const csp = h['content-security-policy']!;
  expect(csp).toContain("default-src 'self'");
  expect(csp).toContain("frame-ancestors 'none'");
  expect(csp).toContain("object-src 'none'");
  expect(csp).not.toMatch(/unsafe-inline|unsafe-eval|ws:|https?:|\*/);
  expect(h).toMatchObject({
    'x-content-type-options': 'nosniff',
    'x-frame-options': 'DENY',
    'referrer-policy': 'no-referrer',
    'cross-origin-opener-policy': 'same-origin',
  });
  expect(h['permissions-policy']).toContain('usb=()');
  expect(h['strict-transport-security']).toContain('max-age=');
  // The <meta> policy in the built page is the same as the header (minus frame-ancestors).
  const html = await page.text();
  const meta = /Content-Security-Policy" content="([^"]+)"/.exec(html)![1]!;
  expect(`${meta}; frame-ancestors 'none'`).toBe(csp);
  // Content-hashed assets are cached for good; the page itself is revalidated.
  const asset = /src="\.\/(assets\/[^"]+\.js)"/.exec(html)![1]!;
  const a = await request.get(`/${asset}`);
  expect(a.status()).toBe(200);
  expect(a.headers()['cache-control']).toContain('immutable');
  expect(h['cache-control'] ?? '').not.toContain('immutable');
  expect((await request.get(`/${asset}.map`)).status()).toBe(404);
  expect((await request.get('/_headers')).status()).toBe(404);
  // The standalone Windows Update recovery download (engine 2.0.0) is served with the same headers.
  const kit = await request.get('/downloads/windows-update-recovery.zip');
  expect(kit.status()).toBe(200);
  expect(kit.headers()['x-content-type-options']).toBe('nosniff');
  const missing = await request.get('/no-such-page');
  expect(missing.status()).toBe(404);
  expect(await missing.text()).toContain('Page not found');
});

test('Quick Deployment end to end under the production policy: live counts, Final Review and a correct ZIP', async ({ page, baseURL }) => {
  const seen = watch(page, baseURL!);
  await page.goto('/');
  await page.locator('.mode-switch [data-mode="quick"]').click();
  await wiz(page).getByTestId('wiz-username').fill('Sam');
  await wiz(page).locator('[data-wiz="top-next"]').click();
  await expect(wiz(page)).toHaveAttribute('data-step', 'type');
  // Step 2 lists the combined selection with one checkbox per application and a live count.
  const developer = wiz(page).locator('[data-type="developer"] input');
  const list = wiz(page).getByTestId('wiz-checklist-list');
  const count = wiz(page).getByTestId('wiz-app-count');
  const row = (key: string) => list.locator(`li[data-key="${key}"]`);
  const ticked = () => list.locator('li[data-selected="true"]').evaluateAll((els) => els.map((e) => e.getAttribute('data-key')!).sort());
  const base = await ticked();
  await expect(count).toHaveAttribute('data-count', String(base.length));
  await developer.check();
  await expect(row('winget:git.git')).toHaveAttribute('data-selected', 'true');
  const withDev = await ticked();
  expect(withDev.length).toBeGreaterThan(base.length);
  await expect(count).toHaveAttribute('data-count', String(withDev.length));
  await developer.uncheck();
  await expect(count).toHaveAttribute('data-count', String(base.length));
  await expect(row('winget:git.git')).toHaveCount(0);
  expect(await ticked()).toEqual(base);
  // An application unticked by hand stays out, also when its profile is unticked and ticked again.
  await developer.check();
  await list.locator('input[data-check-app="winget:microsoft.visualstudiocode"]').uncheck();
  await expect(row('winget:microsoft.visualstudiocode')).toHaveAttribute('data-selected', 'false');
  await developer.uncheck();
  await developer.check();
  await expect(row('winget:microsoft.visualstudiocode')).toHaveAttribute('data-selected', 'false');
  const step2 = await ticked();
  expect(step2).toEqual(withDev.filter((k) => k !== 'winget:microsoft.visualstudiocode'));
  await expect(count).toHaveAttribute('data-count', String(step2.length));
  // Final Review shows exactly the step 2 selection.
  await wiz(page).locator('[data-wiz="go-review"]').click();
  await expect(wiz(page)).toHaveAttribute('data-step', 'review');
  const review = wiz(page).getByTestId('review-app-summary');
  await expect(review).toHaveAttribute('data-total', String(step2.length));
  expect((await review.locator('li[data-key]').evaluateAll((els) => els.map((e) => e.getAttribute('data-key')!))).sort()).toEqual(step2);
  for (const box of await wiz(page).locator('[data-ack]').all()) await box.check();
  const [dl] = await Promise.all([page.waitForEvent('download'), wiz(page).locator('[data-action="wiz-generate"]').click()]);
  expect(dl.suggestedFilename()).toMatch(/\.zip$/);
  const { readZip } = await import('../../src/engine/deployment/zip');
  const entries = readZip(new Uint8Array(await readFile((await dl.path())!)));
  const paths = entries.map((e) => e.path);
  // Ready to extract to the root of a Windows installation USB: the answer file at the root, the package beside it.
  expect(paths).toContain('autounattend.xml');
  expect(paths.filter((p) => !p.includes('/'))).toEqual(['autounattend.xml']);
  expect(paths.every((p) => p === 'autounattend.xml' || p.startsWith('WindowsDeployment/'))).toBe(true);
  const manifest = JSON.parse(new TextDecoder().decode(entries.find((e) => e.path === 'WindowsDeployment/deployment-manifest.json')!.data)) as { files: { path: string; sha256: string }[] };
  for (const f of manifest.files) {
    const e = entries.find((x) => x.path === f.path || x.path === `WindowsDeployment/${f.path}`);
    expect(e, f.path).toBeTruthy();
    expect(createHash('sha256').update(e!.data).digest('hex').toUpperCase(), f.path).toBe(f.sha256.toUpperCase());
  }
  // Windows Update engine 2.0.0 (the 0x80131508 fix) and Retry Windows Update ship in the package.
  const wuEngine = new TextDecoder().decode(entries.find((e) => e.path === 'WindowsDeployment/scripts/windows-update/WindowsUpdateEngine.ps1')!.data);
  expect(wuEngine).toContain("$script:EngineVersion = '2.0.0'");
  expect(wuEngine).toContain('return , $coll');
  expect(paths).toContain('WindowsDeployment/scripts/windows-update/Invoke-WindowsUpdateRetry.ps1');
  // The package's application manifest is the step 2 selection, nothing more or less.
  expect(paths).toContain('WindowsDeployment/scripts/applications/applications-config.json');
  const cfg = JSON.parse(new TextDecoder().decode(entries.find((e) => e.path.endsWith('applications-config.json'))!.data)) as { packages: { key: string }[]; manual: { key: string }[] };
  expect([...cfg.packages, ...cfg.manual].map((x) => x.key).sort()).toEqual(step2);
  expect(cfg.packages.map((x) => x.key)).toContain('winget:git.git');
  expect(cfg.packages.map((x) => x.key)).not.toContain('winget:microsoft.visualstudiocode');
  expect(seen.violations).toEqual([]);
  expect(seen.external).toEqual([]);
});

test('Advanced pages, the package page and the health report preview work under the policy', async ({ page, baseURL }) => {
  const seen = watch(page, baseURL!);
  await page.goto('/');
  await adv(page, 'section-applications');
  await page.locator('#section-applications [data-testid="app-filter"] [data-filter="all"]').click();
  await page.locator('#section-applications [data-app="gimp"]').click();
  await expect(page.locator('#section-applications [data-app="gimp"] input')).toBeChecked();
  // Logos load from the site itself.
  await expect(page.locator('#section-applications [data-app="gimp"] img').first()).toHaveJSProperty('complete', true);
  await adv(page, 'section-health');
  await page.locator('[data-preview="technician"]').click();
  const frame = page.frameLocator('[data-testid="health-preview-frame"]');
  // The template's hashed script ran (it builds the dashboard) and its hashed style applied.
  await expect(frame.getByTestId('overall')).toContainText('Ready with warnings');
  await expect(frame.locator('h1')).not.toHaveCSS('font-family', /Times/);
  await adv(page, 'section-deployment');
  const [dl] = await Promise.all([page.waitForEvent('download'), page.locator('#section-deployment [data-action="download-package"]').click()]);
  expect(dl.suggestedFilename()).toMatch(/\.zip$/);
  // The package tree is indented without inline styles.
  await expect(page.locator('#section-deployment .pkg-tree li[data-depth="2"]').first()).toBeVisible();
  const [xml] = await Promise.all([page.waitForEvent('download'), page.locator('[data-action="download-xml-only"]').click()]);
  expect(xml.suggestedFilename()).toBe('autounattend.xml');
  expect(await readFile((await xml.path())!, 'utf8')).toContain('<unattend');
  expect(seen.violations).toEqual([]);
  expect(seen.external).toEqual([]);
});

test('refresh and back/forward keep the page; a deep link opens its section', async ({ page }) => {
  await page.goto('/#section-applications');
  await expect(page.locator('#section-applications')).toBeVisible();
  await page.reload();
  await expect(page.locator('#section-applications')).toBeVisible();
  await adv(page, 'section-health');
  await page.goBack();
  await expect(page.locator('#section-applications')).toBeVisible();
  await page.goForward();
  await expect(page.locator('#section-health')).toBeVisible();
});

test('the hosted Application Manager page says it cannot install and offers the download', async ({ page, request, baseURL }) => {
  const seen = watch(page, baseURL!);
  await page.goto('/');
  await page.locator('[data-action="open-manager"]').click();
  await expect(page).toHaveURL(/\/manager(\.html)?$/);
  await expect(page.getByTestId('mgr-not-connected')).toContainText('a website cannot install software');
  const href = (await page.getByTestId('mgr-download').getAttribute('href'))!;
  const zip = await request.get(new URL(href, page.url()).toString());
  expect(zip.status()).toBe(200);
  expect(zip.headers()['content-type']).toContain('zip');
  // Without the local agent no operation can start.
  await expect(page.locator('[data-action="mgr-review-install"]')).toHaveCount(await page.locator('[data-action="mgr-review-install"][disabled]').count());
  expect(seen.violations).toEqual([]);
  expect(seen.external).toEqual([]);
});
