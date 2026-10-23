/**
 * Inline SVG icons drawn for this app (24×24 grid, stroked). Bundled with the page, so they work
 * offline and need no icon font or CDN. Markup is constant; nothing user-supplied reaches it.
 */

const SVG_NS = 'http://www.w3.org/2000/svg';

/** Gear outline with eight teeth, computed instead of hand-written. */
function gearPath(): string {
  const pts: string[] = [];
  const teeth = 8;
  for (let i = 0; i < teeth * 4; i++) {
    const a = (i / (teeth * 4)) * Math.PI * 2 - Math.PI / (teeth * 4);
    const r = i % 4 < 2 ? 9.2 : 7.2;
    pts.push(`${(12 + r * Math.cos(a)).toFixed(2)} ${(12 + r * Math.sin(a)).toFixed(2)}`);
  }
  return `<path d="M${pts.join('L')}Z"/><circle cx="12" cy="12" r="3"/>`;
}

const ICONS = {
  windows: '<path d="M3 5.5 10.5 4.4v7.1H3zM12 4.2 21 3v8.5h-9zM3 13h7.5v7.1L3 19zM12 13h9v8l-9-1.2z" fill="currentColor" stroke="none"/>',
  gear: gearPath(),
  user: '<circle cx="12" cy="8" r="4"/><path d="M4 21c0-4.2 3.6-6.5 8-6.5s8 2.3 8 6.5"/>',
  shield: '<path d="M12 3 20 6v6c0 4.8-3.4 8-8 9-4.6-1-8-4.2-8-9V6z"/>',
  shieldCheck: '<path d="M12 3 20 6v6c0 4.8-3.4 8-8 9-4.6-1-8-4.2-8-9V6z"/><path d="m8.5 12 2.5 2.5 4.5-5"/>',
  lock: '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
  eye: '<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/>',
  refresh: '<path d="M20 11a8 8 0 0 0-14.6-4.4L4 8"/><path d="M4 3.5V8h4.5"/><path d="M4 13a8 8 0 0 0 14.6 4.4L20 16"/><path d="M20 20.5V16h-4.5"/>',
  cloudDown: '<path d="M7 18.5a4.5 4.5 0 0 1-.6-8.96A6 6 0 0 1 17.8 8.6 4.2 4.2 0 0 1 17.5 17"/><path d="M12 11v9m-3-3 3 3 3-3"/>',
  sliders: '<path d="M4 6h9m4 0h3M4 12h3m4 0h9M4 18h11m4 0h1"/><circle cx="15" cy="6" r="2"/><circle cx="9" cy="12" r="2"/><circle cx="17" cy="18" r="2"/>',
  folder: '<path d="M3 7a2 2 0 0 1 2-2h4.2l2 2H19a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
  taskbar: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 16h18M9 18h.01M12 18h.01M15 18h.01"/>',
  monitor: '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8.5 20h7M12 16v4"/>',
  grid: '<rect x="4" y="4" width="6.5" height="6.5" rx="1.2"/><rect x="13.5" y="4" width="6.5" height="6.5" rx="1.2"/><rect x="4" y="13.5" width="6.5" height="6.5" rx="1.2"/><rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.2"/>',
  palette: '<path d="M12 3a9 9 0 1 0 0 18c1 0 1.6-.8 1.6-1.6 0-.9-.7-1.3-.7-2.1 0-.9.7-1.6 1.7-1.6H17a4 4 0 0 0 4-4C21 6.9 17 3 12 3z"/><circle cx="7.5" cy="11" r="1"/><circle cx="10" cy="7" r="1"/><circle cx="15" cy="7.5" r="1"/>',
  trash: '<path d="M4 7h16M9.5 7V4.5h5V7M6 7l1 13h10l1-13M10 11v5.5M14 11v5.5"/>',
  server: '<rect x="4" y="4" width="16" height="7" rx="1.5"/><rect x="4" y="13" width="16" height="7" rx="1.5"/><path d="M8 7.5h.01M8 16.5h.01"/>',
  wifi: '<path d="M2.5 9a14 14 0 0 1 19 0M5.5 12.5a9.5 9.5 0 0 1 13 0M8.8 16a5 5 0 0 1 6.4 0"/><circle cx="12" cy="19.3" r=".9" fill="currentColor"/>',
  package: '<path d="M12 3 20 7.5v9L12 21l-8-4.5v-9z"/><path d="M4 7.5 12 12l8-4.5M12 12v9M8 5.3l8 4.5"/>',
  layers: '<path d="M12 3 21 8l-9 5-9-5z"/><path d="m3 12.5 9 5 9-5M3 16.5l9 5 9-5"/>',
  boxPlus: '<rect x="3.5" y="3.5" width="17" height="17" rx="3"/><path d="M12 8v8M8 12h8"/>',
  terminal: '<path d="m4.5 6.5 5 5-5 5M12 18h7.5"/>',
  code: '<path d="m8 7-5 5 5 5M16 7l5 5-5 5M13.5 4l-3 16"/>',
  file: '<path d="M6 3h8l5 5v13H6z"/><path d="M14 3v5h5M9 13h6M9 17h6"/>',
  fileCode: '<path d="M6 3h8l5 5v13H6z"/><path d="M14 3v5h5M10.5 12.5 8.5 14.5l2 2M13.5 12.5l2 2-2 2"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3.2 2"/>',
  download: '<path d="M12 4v11M7 10.5l5 5 5-5M5 20h14"/>',
  importIcon: '<path d="M12 3v11.5M7.5 10l4.5 4.5 4.5-4.5M4 15v3.5A1.5 1.5 0 0 0 5.5 20h13a1.5 1.5 0 0 0 1.5-1.5V15"/>',
  exportIcon: '<path d="M12 15V3.5M7.5 8 12 3.5 16.5 8M4 15v3.5A1.5 1.5 0 0 0 5.5 20h13a1.5 1.5 0 0 0 1.5-1.5V15"/>',
  archive: '<rect x="3" y="4" width="18" height="5" rx="1"/><path d="M5 9v9.5A1.5 1.5 0 0 0 6.5 20h11a1.5 1.5 0 0 0 1.5-1.5V9M10 13h4"/>',
  check: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
  checkCircle: '<circle cx="12" cy="12" r="9"/><path d="m8 12.3 2.8 2.8L16.2 9.5"/>',
  alert: '<path d="M12 3.5 22 20H2z"/><path d="M12 10v4.5M12 17.3h.01"/>',
  xCircle: '<circle cx="12" cy="12" r="9"/><path d="m9 9 6 6m0-6-6 6"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5.5M12 7.8h.01"/>',
  copy: '<rect x="8.5" y="8.5" width="12" height="12" rx="2"/><path d="M15.5 8.5V5.5a2 2 0 0 0-2-2h-8a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h3"/>',
  reset: '<path d="M3.5 12a8.5 8.5 0 1 0 2.6-6.1L3.5 8.5"/><path d="M3.5 3.5v5h5"/>',
  chevronRight: '<path d="m9.5 6 6 6-6 6"/>',
  chevronLeft: '<path d="m14.5 6-6 6 6 6"/>',
  chevronUp: '<path d="m6 14.5 6-6 6 6"/>',
  chevronDown: '<path d="m6 9.5 6 6 6-6"/>',
  menu: '<path d="M4 6.5h16M4 12h16M4 17.5h16"/>',
  x: '<path d="m6 6 12 12M18 6 6 18"/>',
  search: '<circle cx="11" cy="11" r="6.5"/><path d="m16 16 4.5 4.5"/>',
  globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.5 2.6 3.7 5.6 3.7 9s-1.2 6.4-3.7 9c-2.5-2.6-3.7-5.6-3.7-9S9.5 5.6 12 3z"/>',
  disk: '<path d="M3 14.5 6 6h12l3 8.5"/><rect x="3" y="14" width="18" height="6" rx="1.5"/><path d="M16.5 17h.01"/>',
  login: '<path d="M14 4h4a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-4M3.5 12H15m-4-4.5L15.5 12 11 16.5"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  external: '<path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>',
  home: '<path d="m3.5 11 8.5-7 8.5 7"/><path d="M5.5 9.5V20h13V9.5M10 20v-5.5h4V20"/>',
  gamepad: '<path d="M7 7h10a4 4 0 0 1 4 4.4l-.5 4.6a2.7 2.7 0 0 1-4.8 1.4L14 15h-4l-1.7 2.4a2.7 2.7 0 0 1-4.8-1.4L3 11.4A4 4 0 0 1 7 7z"/><path d="M7.5 10.5v3M6 12h3M15.5 11h.01M17.5 13h.01"/>',
  laptop: '<rect x="4.5" y="5" width="15" height="10" rx="1.5"/><path d="M2.5 19h19l-1.5-4H4z"/>',
  pen: '<path d="m15 4.5 4.5 4.5L9 19.5 3.5 20.5 4.5 15z"/><path d="m13 6.5 4.5 4.5"/>',
  star: '<path d="m12 3.5 2.6 5.3 5.9.9-4.3 4.1 1 5.8L12 16.9l-5.2 2.7 1-5.8-4.3-4.1 5.9-.9z"/>',
  wifiOff: '<path d="M3 3l18 18M8.8 16a5 5 0 0 1 6.4 0M5.5 12.5a9.5 9.5 0 0 1 4-2.2M2.5 9a14 14 0 0 1 5-3M14 7.3a14 14 0 0 1 7.5 1.7M18.5 12.5a9.5 9.5 0 0 0-1.4-1.1"/><circle cx="12" cy="19.3" r=".9" fill="currentColor"/>',
  hash: '<path d="M5 9h15M4 15h15M10 4 8 20M16 4l-2 16"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M4.6 4.6 6 6M18 18l1.4 1.4M2.5 12h2M19.5 12h2M4.6 19.4 6 18M18 6l1.4-1.4"/>',
  moon: '<path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z"/>',
  chip: '<rect x="6" y="6" width="12" height="12" rx="1.5"/><rect x="9.5" y="9.5" width="5" height="5"/><path d="M9 2.5V6M15 2.5V6M9 18v3.5M15 18v3.5M2.5 9H6M2.5 15H6M18 9h3.5M18 15h3.5"/>',
  usb: '<path d="M8.5 2.5h7v5h-7z"/><rect x="6.5" y="7.5" width="11" height="14" rx="2"/><path d="M10.5 4.8h.01M13.5 4.8h.01M12 12v5M10 15l2 2 2-2"/>',
  list: '<path d="M9 6h11M9 12h11M9 18h11M4.5 6h.01M4.5 12h.01M4.5 18h.01"/>',
  hand: '<path d="M8 13V5.5a1.5 1.5 0 0 1 3 0V11m0-6.5a1.5 1.5 0 0 1 3 0V11m0-4.5a1.5 1.5 0 0 1 3 0V12m0-3.5a1.5 1.5 0 0 1 3 0V15a6 6 0 0 1-6 6h-1.2a6 6 0 0 1-4.6-2.2L4.6 15.6a1.5 1.5 0 0 1 2.3-1.9L8 15"/>',
  eyeOff: '<path d="M3 3l18 18"/><path d="M10.6 5.6A8.6 8.6 0 0 1 12 5.5C18 5.5 21.5 12 21.5 12a17 17 0 0 1-3.1 3.9M6.6 6.6C3.9 8.3 2.5 12 2.5 12S6 18.5 12 18.5a8.7 8.7 0 0 0 4.3-1.1"/><path d="M9.9 9.9a3 3 0 0 0 4.2 4.2"/>',
  zap: '<path d="M13 2.5 4.5 13.5H12l-1 8 8.5-11H12l1-8z"/>',
  flag: '<path d="M5 21V4m0 0h11l-2 4 2 4H5"/>',
} as const;

export type IconName = keyof typeof ICONS;

export function icon(name: IconName, cls = ''): SVGSVGElement {
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '1.75');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  svg.setAttribute('aria-hidden', 'true');
  svg.setAttribute('focusable', 'false');
  svg.setAttribute('class', `ico${cls ? ` ${cls}` : ''}`);
  svg.innerHTML = ICONS[name];
  return svg;
}
