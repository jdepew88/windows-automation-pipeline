import { expect, test, type Page } from '@playwright/test';
import { readFile } from 'node:fs/promises';

/**
 * Phase 8: Hardware & Drivers. The website only holds the driver policy, the pinned offline bundle
 * and an optional pre-installation inventory taken on the computer itself; detection happens on
 * the installed computer. Every check reads back what the website really produces.
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

const file = (name: string, v: unknown) => ({ name, mimeType: 'application/json', buffer: Buffer.from(typeof v === 'string' ? v : JSON.stringify(v, null, 2)) });
const field = (page: Page, path: string) => page.locator(`.field[data-path="${path}"]`);

/** A shareable inventory as DriverEngine.ps1 -Mode Inspect writes it (a Contoso desktop with an NVIDIA GPU). */
function inventory() {
  const dev = (key: string, name: string, category: string, cls: string, vendor: [string, string, string], state: string, action: string, reasons: string[], driver: Record<string, unknown> | null, extra: Record<string, unknown> = {}) => ({
    key, name, category, class: cls, vendor: { id: vendor[0], name: vendor[1], vendorId: vendor[2] }, instanceId: `PCI\\VEN_${vendor[2]}&DEV_0001\\#1a2b3c4d`, hardwareIds: [`PCI\\VEN_${vendor[2]}&DEV_2484&SUBSYS_146B10DE`, `PCI\\VEN_${vendor[2]}&DEV_2484`],
    compatibleIds: ['PCI\\CC_0300'], problemCode: 0, driver, oemCustomized: false, state, action, confidence: 'high', reasons, setupCritical: false, networkCritical: false, ...extra,
  });
  return {
    format: 'windows-deployment-builder/hardware-inventory', formatVersion: 1, inventoryId: '00112233445566aa', collectedUtc: '2026-10-21T10:00:00Z', tool: { name: 'DriverEngine.ps1', version: '1.0.0' },
    system: { manufacturer: 'Contoso', model: 'Workstation 7', family: '', boardManufacturer: 'Contoso', boardProduct: 'B760', biosVersion: '1.0', portable: false, virtual: false, architecture: 'amd64', osCaption: 'Microsoft Windows 11 Pro', osBuild: '26200', processors: ['Intel(R) Core(TM) i7-13700'], oem: '' },
    devices: [
      dev('dev-aaaaaaaaaaaa', 'Intel(R) Ethernet Controller I225-V', 'networkWired', 'Net', ['intel', 'Intel', '8086'], 'Healthy', 'Keep', ["Working with Windows' own driver (e2f.inf); kept."], { provider: 'Microsoft', version: '2.1.3.15', date: '2024-01-01', inf: 'e2f.inf', inbox: true }),
      dev('dev-bbbbbbbbbbbb', 'Microsoft Basic Display Adapter', 'display', 'Display', ['nvidia', 'NVIDIA', '10DE'], 'BasicDriver', 'InstallRecommended', ['Working, but with Microsoft Basic Display Adapter: a fallback with limited resolution and no hardware acceleration.'], { provider: 'Microsoft', version: '10.0.26100.1', date: '2006-06-21', inf: 'display.inf', inbox: true }),
      dev('dev-cccccccccccc', 'Realtek High Definition Audio', 'audio', 'MEDIA', ['realtek', 'Realtek', '10EC'], 'Healthy', 'Keep', ['Working with Realtek Semiconductor Corp. 6.0.9600.1; kept.'], { provider: 'Realtek Semiconductor Corp.', version: '6.0.9600.1', date: '2025-01-01', inf: 'oem9.inf', inbox: false }),
      dev('dev-dddddddddddd', 'Base System Device', 'unknown', '', ['unknown', 'Unknown vendor (PCI VEN_1D17)', '1D17'], 'DriverMissing', 'InstallRecommended', ['No driver is installed (Code 28 (drivers not installed)).'], null, { problemCode: 28, confidence: 'low' }),
    ],
    summary: { devices: 4, healthy: 2, basicDriver: 1, driverMissing: 1 },
    setupCritical: [],
    optionalApplications: [{ name: 'NVIDIA App', vendor: 'NVIDIA', purpose: 'Game settings and driver notifications. Optional; not installed because a GPU is present.', required: false, installed: 'not by the driver stage (the application profile decides)' }],
    notice: 'Collected on this computer by a read-only scan.',
  };
}

/** A bundle manifest as the bundle tool writes it (one display, one storage package). */
function bundle() {
  const pkg = (id: string, n: number, base: string, cls: string, provider: string, version: string, setupCritical: boolean) => ({
    id, folder: `packages/00${n}-${base}`, inf: `${base}.inf`, class: cls, classGuid: '{4d36e968-e325-11ce-bfc1-08002be10318}', provider, version, date: '2026-09-15', catalog: `${base}.cat`,
    targets: [{ arch: 'amd64', minBuild: 22000 }], hardwareIds: ['PCI\\VEN_10DE&DEV_2484'], signature: { status: 'Valid', signer: 'Microsoft Windows Hardware Compatibility Publisher', whql: true },
    setupCritical, networkDriver: false, files: [{ path: `${base}.inf`, size: 10, sha256: 'A'.repeat(64) }, { path: `${base}.cat`, size: 10, sha256: 'B'.repeat(64) }], bytes: 20,
  });
  return {
    format: 'windows-deployment-builder/driver-bundle', formatVersion: 1, bundleId: '0123456789abcdef', folderName: 'WDB-Drivers-20261022-120000-abc123', createdUtc: '2026-10-22T12:00:00Z',
    tool: { name: 'DriverEngine.ps1', version: '1.0.0' }, source: { kind: 'driverStoreExport', manufacturer: 'Contoso', model: 'Workstation 7', osBuild: '26200', architecture: 'amd64' },
    packages: [pkg('pkg-0000000000a1', 1, 'nvdisp', 'Display', 'NVIDIA', '32.0.15.8100', false), pkg('pkg-0000000000a3', 2, 'iastorvd', 'SCSIAdapter', 'Intel Corporation', '20.1.0.1032', true)],
    refused: [], totals: { packages: 2, files: 4, bytes: 40 }, notice: 'INF driver packages only.',
  };
}

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    if (!sessionStorage.getItem('e2e-init')) {
      localStorage.setItem('wdb.mode', 'advanced');
      sessionStorage.setItem('e2e-init', '1');
    }
  });
  await page.goto('/');
});

test('Hardware & Drivers: safe defaults on; the website says it cannot see the hardware; the tool is read-only', async ({ page }) => {
  await go(page, 'section-drivers');
  const section = page.locator('#section-drivers');
  await expect(section).toContainText('Hardware is detected on the installed computer, not here');
  for (const p of ['drivers.enabled', 'drivers.useWindowsUpdate', 'drivers.resolveMissing', 'drivers.includeOfflinePackages', 'drivers.reportUnresolved']) await expect(field(page, p).locator('input[type="checkbox"]'), p).toBeChecked();
  await expect(field(page, 'drivers.optionalReplacements').locator('input[value="never"]')).toBeChecked();
  await expect(page.getByTestId('drv-no-inventory')).toContainText('the deployment always identifies the hardware itself');
  const [dl] = await Promise.all([page.waitForEvent('download'), page.getByTestId('drv-download-tool').click()]);
  expect(dl.suggestedFilename()).toBe('hardware-driver-tool.zip');
  const zip = await readFile((await dl.path())!);
  for (const name of ['DriverEngine.ps1', 'driver-sources.json', 'Inspect-Hardware.cmd', 'README-Hardware-Driver-Tool.txt']) expect(zip.includes(Buffer.from(`hardware-driver-tool/${name}`)), name).toBe(true);
});

test('Hardware & Drivers: an imported inventory is shown exactly as collected, attention first, with advanced details', async ({ page }) => {
  await go(page, 'section-drivers');
  await page.getByTestId('drv-inventory-input').setInputFiles(file('hardware-inventory.json', inventory()));
  await expect(page.getByTestId('drv-import-status')).toContainText('Imported hardware-inventory.json: 4 device(s)');
  await expect(page.getByTestId('drv-banner')).toContainText('Pre-installation information: collected on Contoso Workstation 7');
  await expect(page.getByTestId('drv-banner')).toContainText('The deployment inspects the hardware again on the installed computer');
  const rows = page.getByTestId('drv-review').locator('details.drv-tr');
  await expect(rows).toHaveCount(4);
  await expect(rows.nth(0)).toContainText('Microsoft Basic Display Adapter');
  await expect(rows.nth(0)).toContainText('Compatible driver recommended');
  await expect(rows.nth(1)).toContainText('Unknown vendor (PCI VEN_1D17)');
  await expect(rows.nth(3)).toContainText('Keep existing');
  await rows.nth(0).locator('summary').click();
  await expect(rows.nth(0)).toContainText('PCI\\VEN_10DE&DEV_2484&SUBSYS_146B10DE');
  await expect(rows.nth(0)).toContainText('display.inf');
  await expect(page.getByTestId('drv-optional-apps')).toContainText('never installed by the driver stage');
  // Something that is not a hardware inventory is refused.
  await page.getByTestId('drv-inventory-input').setInputFiles(file('bad.json', { format: 'something-else' }));
  await expect(page.getByTestId('drv-import-status')).toContainText('Could not import bad.json');
});

test('Hardware & Drivers: a pinned bundle reaches the package and the USB card; storage drivers are Setup-critical', async ({ page }) => {
  await go(page, 'section-drivers');
  await page.locator('[data-action="drv-attach-bundle"]').click();
  await page.getByTestId('drv-bundle-input').setInputFiles(file('drivers-manifest.json', bundle()));
  await expect(page.getByTestId('drv-bundle-status')).toContainText('Attached bundle WDB-Drivers-20261022-120000-abc123: 2 driver package(s)');
  await expect(page.getByTestId('drv-bundle-hash')).toHaveText(/^[0-9A-F]{64}$/);
  await expect(page.getByTestId('drv-setup-pkg-0000000000a3')).toBeChecked();
  await expect(page.getByTestId('drv-setup-pkg-0000000000a1')).not.toBeChecked();
  await go(page, 'usb-prep');
  await expect(page.getByTestId('usb-drivers-note')).toContainText('give the assistant that folder (-Drivers)');
  await expect(page.getByTestId('usb-drivers-note')).toContainText('$WinPEDriver$');
  await expect(page.getByTestId('package-stages').locator('[data-stage="drivers"]')).toContainText('On');
  const [dl] = await Promise.all([page.waitForEvent('download'), page.locator('#section-deployment [data-action="download-package"]').click()]);
  const { readZip } = await import('../../src/engine/deployment/zip');
  const entries = readZip(new Uint8Array(await readFile((await dl.path())!)));
  const json = (path: string) => JSON.parse(new TextDecoder().decode(entries.find((e) => e.path === path)!.data));
  const manifest = json('WindowsDeployment/deployment-manifest.json');
  expect(manifest.media.drivers).toMatchObject({ bundle: { folderName: 'WDB-Drivers-20261022-120000-abc123' }, setupCritical: { packages: ['pkg-0000000000a3'] }, required: true });
  expect(json('WindowsDeployment/scripts/drivers/drivers-config.json').bundle.folderName).toBe('WDB-Drivers-20261022-120000-abc123');
  expect(entries.some((e) => /\.sys$|\.cat$|drivers-manifest/.test(e.path))).toBe(false);
});

test('Quick Deployment states what happens to drivers without implying the website sees the hardware', async ({ page }) => {
  await page.evaluate(() => localStorage.setItem('wdb.mode', 'quick'));
  await page.reload();
  const wiz = page.getByTestId('wizard');
  await wiz.getByTestId('wiz-username').fill('Alex');
  for (let i = 0; i < 4; i++) await wiz.locator('[data-wiz="top-next"]').click();
  const r = wiz.getByTestId('final-review').getByTestId('review-drivers');
  await expect(r).toContainText('Windows will identify hardware, use compatible existing or Windows Update drivers, and report any missing drivers.');
  await expect(r).toContainText('Detected on the installed computer, not by this website.');
});

test('Hardware & Drivers: readable in light and dark themes without horizontal scrolling', async ({ page }, info) => {
  await go(page, 'section-drivers');
  await page.getByTestId('drv-inventory-input').setInputFiles(file('hardware-inventory.json', inventory()));
  await page.getByTestId('drv-review').locator('details.drv-tr').first().locator('summary').click();
  for (const theme of ['Light', 'Dark']) {
    await page.getByRole('button', { name: `${theme} appearance` }).click();
    await go(page, 'section-drivers');
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    expect(overflow, theme).toBeLessThanOrEqual(1);
    const table = page.getByTestId('drv-hardware');
    await table.scrollIntoViewIfNeeded();
    await info.attach(`drivers-${theme.toLowerCase()}`, { body: await table.screenshot(), contentType: 'image/png' });
    await table.screenshot({ path: info.outputPath(`drivers-${theme.toLowerCase()}.png`) });
  }
});
