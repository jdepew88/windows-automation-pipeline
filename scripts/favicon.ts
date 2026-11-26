import { deflateSync } from 'node:zlib';

/**
 * The site icon: four flat blue panes in a 2x2 grid, after the Windows 11 logo. One geometry, in
 * 16 units, drives every file, so the SVG and the bitmaps match:
 *
 *   margin 1, pane 6, gap 2 (1 + 6 + 2 + 6 + 1 = 16): every edge falls on a whole pixel at 16, 32
 *   and 48 pixels, so the icon stays sharp in a browser tab, a bookmark and Windows shortcuts.
 *
 * One diagonal gradient (two close blues) spans the whole icon, not each pane. No other detail
 * would survive at 16 pixels. scripts/write-favicon.ts writes the files and
 * tests/unit/favicon.test.ts checks that the committed files match this module.
 */

const UNITS = 16;
const PANES = [1, 9].flatMap((y) => [1, 9].map((x) => ({ x, y, size: 6 })));
const RADIUS = 0.6;
const LIGHT = [0x3c, 0xa8, 0xff] as const; // top left
const DARK = [0x0a, 0x6c, 0xd8] as const; // bottom right
/** The site's dark background (src/styles.css --bg): behind the icon on phone home screens, which do not keep transparency. */
const TILE = [0x0a, 0x10, 0x1c] as const;

const hex = (c: readonly number[]) => `#${c.map((v) => v.toString(16).padStart(2, '0')).join('').toUpperCase()}`;

export function faviconSvg(): string {
  const rects = PANES.map((p) => `<rect x="${p.x}" y="${p.y}" width="${p.size}" height="${p.size}" rx="${RADIUS}"/>`).join('');
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${UNITS} ${UNITS}">` +
    `<defs><linearGradient id="g" gradientUnits="userSpaceOnUse" x1="1" y1="1" x2="15" y2="15">` +
    `<stop offset="0" stop-color="${hex(LIGHT)}"/><stop offset="1" stop-color="${hex(DARK)}"/></linearGradient></defs>` +
    `<g fill="url(#g)">${rects}</g></svg>\n`
  );
}

/** How much of the point (x, y), in icon units, lies inside a pane: 0 or 1. */
function inside(x: number, y: number): boolean {
  for (const p of PANES) {
    const cx = Math.min(Math.max(x, p.x + RADIUS), p.x + p.size - RADIUS);
    const cy = Math.min(Math.max(y, p.y + RADIUS), p.y + p.size - RADIUS);
    if (x >= p.x && x <= p.x + p.size && y >= p.y && y <= p.y + p.size && (x - cx) ** 2 + (y - cy) ** 2 <= RADIUS ** 2) return true;
  }
  return false;
}

/**
 * Renders the icon as RGBA pixels, 8x8 samples per pixel. With `tile`, the icon is drawn on the
 * site's background at `scale` of the bitmap's width; otherwise it fills a transparent bitmap.
 */
function render(size: number, tile = false, scale = 1): Uint8Array {
  const out = new Uint8Array(size * size * 4);
  const iconPx = size * scale;
  const offset = (size - iconPx) / 2;
  const SS = 8;
  for (let py = 0; py < size; py++) {
    for (let px = 0; px < size; px++) {
      let hits = 0;
      for (let sy = 0; sy < SS; sy++) {
        for (let sx = 0; sx < SS; sx++) {
          const ux = ((px + (sx + 0.5) / SS - offset) / iconPx) * UNITS;
          const uy = ((py + (sy + 0.5) / SS - offset) / iconPx) * UNITS;
          if (inside(ux, uy)) hits++;
        }
      }
      const coverage = hits / (SS * SS);
      const ux = ((px + 0.5 - offset) / iconPx) * UNITS;
      const uy = ((py + 0.5 - offset) / iconPx) * UNITS;
      const t = Math.min(Math.max(((ux - 1) + (uy - 1)) / 28, 0), 1);
      const color = LIGHT.map((l, i) => l + (DARK[i]! - l) * t);
      const i = (py * size + px) * 4;
      if (tile) {
        for (let c = 0; c < 3; c++) out[i + c] = Math.round(TILE[c]! + (color[c]! - TILE[c]!) * coverage);
        out[i + 3] = 255;
      } else {
        for (let c = 0; c < 3; c++) out[i + c] = Math.round(color[c]!);
        out[i + 3] = Math.round(coverage * 255);
      }
    }
  }
  return out;
}

const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
function crc32(data: Uint8Array): number {
  let c = 0xffffffff;
  for (const b of data) c = CRC_TABLE[(c ^ b) & 0xff]! ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type: string, data: Uint8Array): Uint8Array {
  const out = new Uint8Array(12 + data.length);
  const view = new DataView(out.buffer);
  view.setUint32(0, data.length);
  out.set(new TextEncoder().encode(type), 4);
  out.set(data, 8);
  view.setUint32(8 + data.length, crc32(out.subarray(4, 8 + data.length)));
  return out;
}

/** A minimal PNG (8-bit RGBA, no filtering) of RGBA pixels. */
function png(size: number, rgba: Uint8Array): Uint8Array {
  const header = new Uint8Array(13);
  const hv = new DataView(header.buffer);
  hv.setUint32(0, size);
  hv.setUint32(4, size);
  header.set([8, 6, 0, 0, 0], 8);
  const raw = new Uint8Array(size * (size * 4 + 1));
  for (let y = 0; y < size; y++) raw.set(rgba.subarray(y * size * 4, (y + 1) * size * 4), y * (size * 4 + 1) + 1);
  const parts = [new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', header), chunk('IDAT', deflateSync(raw, { level: 9 })), chunk('IEND', new Uint8Array())];
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

/** favicon.ico: 16, 32 and 48 pixel PNG images (the ICO format has allowed PNG images since Windows Vista). */
export function faviconIco(): Uint8Array {
  const images = [16, 32, 48].map((s) => ({ size: s, data: png(s, render(s)) }));
  const out = new Uint8Array(6 + 16 * images.length + images.reduce((n, i) => n + i.data.length, 0));
  const view = new DataView(out.buffer);
  view.setUint16(2, 1, true);
  view.setUint16(4, images.length, true);
  let offset = 6 + 16 * images.length;
  images.forEach((img, n) => {
    const e = 6 + 16 * n;
    out[e] = img.size;
    out[e + 1] = img.size;
    view.setUint16(e + 4, 1, true);
    view.setUint16(e + 6, 32, true);
    view.setUint32(e + 8, img.data.length, true);
    view.setUint32(e + 12, offset, true);
    out.set(img.data, offset);
    offset += img.data.length;
  });
  return out;
}

/** apple-touch-icon.png: 180 pixels, the icon on the site's dark background (phones show it on the home screen). */
export function appleTouchIcon(): Uint8Array {
  return png(180, render(180, true, 112 / 180));
}
