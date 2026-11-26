import { existsSync, readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { appleTouchIcon, faviconIco, faviconSvg } from '../../scripts/favicon';

/**
 * The site icon comes from scripts/favicon.ts; `npm run favicon` writes the files. Both pages link
 * it once, through Vite (so the built files land in dist/assets/, which the packaged Application
 * Manager also serves), and the site root keeps a /favicon.ico for clients that never read the page.
 */

const file = (rel: string) => new URL(`../../${rel}`, import.meta.url);
const read = (rel: string) => readFileSync(file(rel));
const PNG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

describe('favicon', () => {
  it('the committed files are up to date (run `npm run favicon` after changing scripts/favicon.ts)', () => {
    expect(read('src/assets/favicon/favicon.svg').toString('utf8')).toBe(faviconSvg());
    expect(new Uint8Array(read('src/assets/favicon/favicon.ico'))).toEqual(faviconIco());
    expect(new Uint8Array(read('src/assets/favicon/apple-touch-icon.png'))).toEqual(appleTouchIcon());
    expect(new Uint8Array(read('public/favicon.ico'))).toEqual(faviconIco());
  });

  it('the SVG is a small, self-contained image (no scripts, links or embedded bitmaps)', () => {
    const svg = faviconSvg();
    expect(svg.length).toBeLessThan(1024);
    expect(svg).toMatch(/^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg" viewBox="0 0 16 16">/);
    expect(svg).not.toMatch(/<script|<image|href=|on\w+=|data:/i);
    expect(svg.match(/<rect /g)).toHaveLength(4);
  });

  it('the ICO holds 16, 32 and 48 pixel PNG images that fit the file', () => {
    const ico = faviconIco();
    const view = new DataView(ico.buffer, ico.byteOffset, ico.byteLength);
    expect([view.getUint16(0, true), view.getUint16(2, true), view.getUint16(4, true)]).toEqual([0, 1, 3]);
    const sizes: number[] = [];
    for (let n = 0; n < 3; n++) {
      const e = 6 + 16 * n;
      const length = view.getUint32(e + 8, true);
      const offset = view.getUint32(e + 12, true);
      expect(offset + length).toBeLessThanOrEqual(ico.length);
      const image = ico.subarray(offset, offset + length);
      expect([...image.subarray(0, 8)]).toEqual(PNG);
      const width = new DataView(image.buffer, image.byteOffset + 16, 4).getUint32(0);
      expect(width).toBe(ico[e]);
      sizes.push(width);
    }
    expect(sizes).toEqual([16, 32, 48]);
  });

  it('the apple touch icon is a 180 pixel PNG', () => {
    const png = appleTouchIcon();
    expect([...png.subarray(0, 8)]).toEqual(PNG);
    const view = new DataView(png.buffer, png.byteOffset, png.byteLength);
    expect([view.getUint32(16), view.getUint32(20)]).toEqual([180, 180]);
  });

  it('the builder and the Application Manager link each icon exactly once, to files that exist', () => {
    for (const page of ['index.html', 'manager.html']) {
      const html = read(page).toString('utf8');
      const links = [...html.matchAll(/<link rel="(icon|apple-touch-icon)" href="([^"]+)"([^>]*)>/g)].map((m) => ({ rel: m[1]!, href: m[2]!, rest: m[3]! }));
      expect(links.map((l) => l.href), page).toEqual(['/src/assets/favicon/favicon.ico', '/src/assets/favicon/favicon.svg', '/src/assets/favicon/apple-touch-icon.png']);
      expect(links.map((l) => l.rel), page).toEqual(['icon', 'icon', 'apple-touch-icon']);
      expect(links[0]!.rest, page).toContain('sizes="32x32"');
      expect(links[1]!.rest, page).toContain('type="image/svg+xml"');
      expect(html.match(/rel="(shortcut )?icon"/g), page).toHaveLength(2);
      for (const l of links) expect(existsSync(file(l.href.slice(1))), `${page}: ${l.href}`).toBe(true);
    }
    const notFound = read('public/404.html').toString('utf8');
    expect(notFound.match(/<link rel="icon" href="\/favicon\.ico" sizes="32x32" \/>/g)).toHaveLength(1);
  });
});
