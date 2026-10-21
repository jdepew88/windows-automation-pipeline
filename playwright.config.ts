import { defineConfig, devices } from '@playwright/test';

// E2E_BASE_URL runs the suite against a deployed site (e.g. the Cloudflare Worker) instead of a local preview.
const remote = process.env.E2E_BASE_URL;

export default defineConfig({
  testDir: 'tests/e2e',
  timeout: 30_000,
  use: { baseURL: remote ?? 'http://localhost:5179', acceptDownloads: true },
  webServer: remote
    ? undefined
    : {
        command: 'npm run build && npx vite preview --port 5179 --strictPort',
        url: 'http://localhost:5179',
        reuseExistingServer: false,
        timeout: 120_000,
      },
  projects: [
    { name: 'desktop-chromium', use: { ...devices['Desktop Chrome'] } },
    // Tablet portrait width (iPad Air class), Chromium with touch.
    { name: 'tablet-chromium', use: { ...devices['Desktop Chrome'], viewport: { width: 820, height: 1180 }, hasTouch: true } },
    { name: 'mobile-chromium', use: { ...devices['Pixel 7'] } },
  ],
});
