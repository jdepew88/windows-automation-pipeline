import ICONS from '../data/apps/icons.json';
import { h } from './dom';

/**
 * Application logos (Phase 4.3). Files are bundled in public/app-icons (scripts/build-app-icons.mjs
 * records the source and license of each); nothing is fetched from a third party at run time.
 * An app without a logo, or whose file fails to load, gets the initials tile in its category
 * colour, so every tile has the same size and nothing is drawn to look like someone's brand.
 */

interface IconInfo {
  file: string;
  kind: 'app' | 'publisher';
  title: string;
  source: string;
  license: string;
}

const MAP = (ICONS as { icons: Record<string, IconInfo> }).icons;

export const hasLogo = (id: string | undefined) => !!id && id in MAP;
export const logoInfo = (id: string): IconInfo | undefined => MAP[id];

export function initials(name: string): string {
  return (
    name
      .replace(/[^\p{L}\p{N} ]/gu, ' ')
      .split(/\s+/)
      .filter(Boolean)
      .slice(0, 2)
      .map((w) => w[0]!.toUpperCase())
      .join('') || '?'
  );
}

function fallback(name: string, category: string | undefined, size: string): HTMLElement {
  return h('span', { class: `app-logo avatar ${size}`, 'data-cat': category ?? 'other', 'data-logo': 'fallback', 'aria-hidden': 'true' }, initials(name));
}

/**
 * The logo of a catalog app, decorative (the accessible name is always on the control). Images
 * load lazily and asynchronously, so they never delay a checkbox.
 */
export function appLogo(id: string | undefined, name: string, category?: string, size: 'sm' | 'md' | 'lg' = 'md'): HTMLElement {
  const info = id ? MAP[id] : undefined;
  if (!info) return fallback(name, category, size);
  const wrap = h('span', { class: `app-logo ${size}${info.file.endsWith('.png') || id === 'sabnzbd' ? ' plain' : ''}`, 'data-logo': id, 'aria-hidden': 'true' });
  const img = h('img', { src: `${import.meta.env.BASE_URL}${info.file}`, alt: '', loading: 'lazy', decoding: 'async', draggable: 'false' });
  img.addEventListener('error', () => wrap.replaceWith(fallback(name, category, size)), { once: true });
  wrap.append(img);
  return wrap;
}
