import { defineConfig, devices } from '@playwright/test';

/**
 * Production checks: the real build in dist/ served the way Cloudflare Pages serves it
 * (`wrangler pages dev`, a local emulator: _headers, pretty URLs, 404.html; it needs no Cloudflare
 * account and contacts nothing). `npm run test:e2e:production`.
 *
 * The whole regular suite can also run against it: start `npm run preview:pages` and run
 * `E2E_BASE_URL=http://127.0.0.1:8788 npm run test:e2e`.
 */
export default defineConfig({
  testDir: 'tests/production',
  timeout: 45_000,
  use: { baseURL: 'http://127.0.0.1:8788', acceptDownloads: true },
  webServer: {
    command: 'npm run build && npm run preview:pages',
    url: 'http://127.0.0.1:8788',
    reuseExistingServer: false,
    timeout: 180_000,
    env: { WRANGLER_SEND_METRICS: 'false' },
  },
  projects: [
    { name: 'production-desktop', use: { ...devices['Desktop Chrome'] } },
    { name: 'production-mobile', use: { ...devices['Pixel 7'] } },
  ],
  reporter: [['list']],
});
