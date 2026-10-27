import { defineConfig, type Plugin } from 'vitest/config';
import { contentSecurityPolicy } from './scripts/security-headers';

const CSP_META = /(<meta http-equiv="Content-Security-Policy" content=")[^"]*(")/;

/**
 * The source pages carry the development policy (the Vite dev server needs inline styles and a
 * WebSocket); built pages get the production policy, the same one public/_headers sends.
 */
const productionCsp = (): Plugin => ({
  name: 'wdb-production-csp',
  apply: 'build',
  transformIndexHtml(html, ctx) {
    if (!CSP_META.test(html)) throw new Error(`${ctx.filename}: Content-Security-Policy <meta> not found`);
    return html.replace(CSP_META, (_m, a: string, b: string) => `${a}${contentSecurityPolicy('production')}${b}`);
  },
});

export default defineConfig({
  base: './',
  plugins: [productionCsp()],
  // Two pages: the builder, and the Phase 10 Application Manager (also packaged for the local agent by scripts/build-manager.ts).
  // Source maps contain the full source; they are only written when asked for (WDB_SOURCEMAP=1), so a
  // static host never publishes them.
  build: { outDir: 'dist', sourcemap: process.env.WDB_SOURCEMAP === '1', rollupOptions: { input: { main: 'index.html', manager: 'manager.html' } } },
  test: {
    include: ['tests/unit/**/*.test.ts'],
    environment: 'node',
  },
});
