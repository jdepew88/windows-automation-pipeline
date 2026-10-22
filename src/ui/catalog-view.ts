import type { CatalogEntry, InstallMethod } from '../engine/applications/catalog';
import { CATALOG_CATEGORIES } from '../engine/applications/catalog';
import { appLogo } from './app-icon';
import { h, uid } from './dom';
import { icon } from './icons';

/**
 * The four catalog layouts (Phase 4.3). A layout only changes how an app is drawn: every one of
 * them is a real checkbox bound to the same selection, so switching layouts, searching or
 * filtering never changes what is installed.
 */

export type CatalogView = 'logos' | 'grid' | 'compact' | 'detailed';
export const CATALOG_VIEWS: readonly { id: CatalogView; label: string; hint: string }[] = [
  { id: 'logos', label: 'Logos', hint: 'Logo grid' },
  { id: 'grid', label: 'Grid', hint: 'Logos with names (default)' },
  { id: 'compact', label: 'Compact', hint: 'Compact list' },
  { id: 'detailed', label: 'Detailed', hint: 'Detailed list' },
];

const VIEW_KEY = 'wdb.catalogView';
const isView = (v: unknown): v is CatalogView => CATALOG_VIEWS.some((x) => x.id === v);

/** A per-browser display preference (never part of the configuration). */
export function loadCatalogView(): CatalogView {
  try {
    const v = localStorage.getItem(VIEW_KEY);
    return isView(v) ? v : 'grid';
  } catch {
    return 'grid';
  }
}

export function saveCatalogView(v: CatalogView): void {
  try {
    localStorage.setItem(VIEW_KEY, v);
  } catch {
    /* preference only */
  }
}

export type ItemState = 'selected' | 'deselected' | 'recommended' | 'available' | 'unavailable';

/** Everything a layout needs to draw one catalog app. */
export interface ItemModel {
  entry: CatalogEntry;
  state: ItemState;
  /** Why it is (not) selected, in words: "Selected by Core Essentials", "Unticked by you", … */
  reason: string;
  checked: boolean;
  disabled: boolean;
  /** Shown when the app cannot be ticked (antivirus conflict, no package). */
  blockedText: string;
  method: InstallMethod;
  manual: boolean;
}

/** Segmented control for the four layouts. */
export function viewSwitcher(current: CatalogView, onChange: (v: CatalogView) => void): HTMLElement {
  return h(
    'div',
    { class: 'seg view-switch', role: 'group', 'aria-label': 'Catalog layout', 'data-testid': 'catalog-view' },
    CATALOG_VIEWS.map((v) =>
      h('button', { type: 'button', 'data-view-mode': v.id, 'aria-pressed': String(v.id === current), title: v.hint, onclick: () => onChange(v.id) }, icon(v.id === 'logos' ? 'grid' : v.id === 'grid' ? 'layers' : v.id === 'compact' ? 'list' : 'file'), h('span', { class: 'view-label' }, v.label)),
    ),
  );
}

const STATE_TEXT: Record<ItemState, string> = {
  selected: 'selected',
  deselected: 'not selected (unticked by you)',
  recommended: 'not selected (recommended)',
  available: 'not selected',
  unavailable: 'unavailable',
};

/**
 * One app as a tile (logos / grid) or a compact row. The detailed layout is drawn by the caller
 * (app-selection.ts) because it carries the technical metadata.
 */
export function renderTile(view: Exclude<CatalogView, 'detailed'>, m: ItemModel, onToggle: (on: boolean) => void): HTMLElement {
  const e = m.entry;
  const id = uid('tile');
  const tip = [e.displayName, m.reason, m.blockedText, m.manual ? 'Manual follow-up: not installed automatically' : ''].filter(Boolean).join('\n');
  const input = h('input', {
    type: 'checkbox',
    id,
    class: view === 'compact' ? undefined : 'tile-check',
    checked: m.checked,
    disabled: m.disabled,
    'aria-label': view === 'compact' ? undefined : e.displayName,
    'aria-describedby': `${id}-d`,
    onchange: (ev: Event) => onToggle((ev.target as HTMLInputElement).checked),
  });
  const desc = h('span', { class: 'sr-only', id: `${id}-d` }, `${STATE_TEXT[m.state]}. ${m.reason}${m.blockedText ? `. ${m.blockedText}` : ''}${m.manual ? '. Manual follow-up' : ''}. ${CATALOG_CATEGORIES[e.category]}.`);
  const flags = h(
    'span',
    { class: 'tile-flags', 'aria-hidden': 'true' },
    m.manual ? h('span', { class: 'tile-flag manual', title: 'Manual follow-up' }, icon('hand')) : null,
    e.conflictGroup ? h('span', { class: 'tile-flag warn', title: 'Only one real-time antivirus' }, icon('shield')) : null,
    m.disabled ? h('span', { class: 'tile-flag muted', title: m.blockedText }, icon('lock')) : null,
  );
  if (view === 'compact') {
    return h(
      'label',
      { class: `app-row-compact${m.checked ? ' on' : ''}${m.disabled ? ' disabled' : ''}`, for: id, 'data-app': e.id, 'data-state': m.state, title: tip },
      input,
      appLogo(e.id, e.displayName, e.category, 'sm'),
      h('span', { class: 'compact-name' }, e.displayName),
      flags,
      desc,
    );
  }
  return h(
    'label',
    { class: `app-tile${m.checked ? ' on' : ''}${m.disabled ? ' disabled' : ''}${m.state === 'recommended' ? ' rec' : ''}`, for: id, 'data-app': e.id, 'data-state': m.state, title: tip },
    input,
    h('span', { class: 'tile-mark', 'aria-hidden': 'true' }, icon('check')),
    appLogo(e.id, e.displayName, e.category, view === 'logos' ? 'lg' : 'md'),
    view === 'grid' ? h('span', { class: 'tile-name' }, e.displayName) : h('span', { class: 'sr-only' }, e.displayName),
    flags,
    desc,
  );
}
