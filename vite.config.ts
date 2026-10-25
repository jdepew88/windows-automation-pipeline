import { defineConfig } from 'vitest/config';

export default defineConfig({
  base: './',
  // Two pages: the builder, and the Phase 10 Application Manager (also packaged for the local agent by scripts/build-manager.ts).
  build: { outDir: 'dist', sourcemap: true, rollupOptions: { input: { main: 'index.html', manager: 'manager.html' } } },
  test: {
    include: ['tests/unit/**/*.test.ts'],
    environment: 'node',
  },
});
