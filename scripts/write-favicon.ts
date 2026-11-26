import { mkdirSync, writeFileSync } from 'node:fs';
import { appleTouchIcon, faviconIco, faviconSvg } from './favicon';

/**
 * Writes the site icon from scripts/favicon.ts:
 *
 *   src/assets/favicon/  favicon.svg, favicon.ico, apple-touch-icon.png: linked from index.html
 *                        and manager.html; Vite copies them into dist/assets/ with hashed names,
 *                        so the packaged Application Manager (which serves only /assets/*) gets them too.
 *   public/favicon.ico   the same ICO at the site root, for browsers and bookmark tools that ask for
 *                        /favicon.ico without reading the page (and for public/404.html).
 *
 * Usage: npm run favicon
 */
const dir = new URL('../src/assets/favicon/', import.meta.url);
mkdirSync(dir, { recursive: true });
writeFileSync(new URL('favicon.svg', dir), faviconSvg());
writeFileSync(new URL('favicon.ico', dir), faviconIco());
writeFileSync(new URL('apple-touch-icon.png', dir), appleTouchIcon());
writeFileSync(new URL('../public/favicon.ico', import.meta.url), faviconIco());
console.log('Wrote src/assets/favicon/ (favicon.svg, favicon.ico, apple-touch-icon.png) and public/favicon.ico');
