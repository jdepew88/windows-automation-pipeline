import './styles.css';
import { generate, type GenerateResult } from './engine/pipeline';
import { exportProfile, hasSecrets, importProfile, ownerDefaults } from './engine/profiles';
import { resolveIdentity } from './engine/naming';
import type { Profile } from './engine/schema/profile';
import type { SettingDef } from './engine/settings/types';
import type { Issue } from './engine/validation/issues';
import { ALL_SETTINGS, SECTIONS, SETTINGS_BY_PATH } from './features';
import { CUSTOM_RENDERERS } from './ui/editors';
import { clear, download, h } from './ui/dom';
import { renderField, type FieldHandle } from './ui/form';
import { icon, type IconName } from './ui/icons';
import { FIELD_GROUPS, NAV_GROUPS, PAGE_ICONS, type NavItem, type PageId } from './ui/layout';
import { renderReview } from './ui/review';
import { renderDeploymentPage } from './ui/deployment';
import { Store } from './ui/store';
import { profileLibrary } from './ui/library';
import { renderWizard } from './ui/wizard';
import { ackKey, isEmptyPasswordAutoAdmin, wifiSecretEmbedded } from './engine/quick';

type View = 'basic' | 'advanced';
type Theme = 'dark' | 'light' | 'system';
/** Phase 4.3: Quick Deployment (wizard) or Advanced Configuration (every section). */
type Mode = 'quick' | 'advanced';
const VIEW_KEY = 'wdb.view';
const THEME_KEY = 'wdb.theme';
const MODE_KEY = 'wdb.mode';

// View and appearance are per-browser conveniences; configuration itself is never stored.
function loadPref(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

function savePref(key: string, value: string): void {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* storage unavailable: preferences are only a convenience */
  }
}

const store = new Store();
const fields: { def: SettingDef; handle: FieldHandle }[] = [];
const review = renderReview();
const deploymentPage = renderDeploymentPage();
const app = document.getElementById('app')!;

// Notice -----------------------------------------------------------------------------------------
const notice = h('div', { class: 'notice', role: 'status', 'aria-live': 'polite', 'data-testid': 'notice', hidden: true });
function showNotice(kind: 'info' | 'error', title: string, lines: string[] = []): void {
  clear(notice);
  notice.hidden = false;
  notice.className = `notice ${kind}`;
  notice.append(
    icon(kind === 'error' ? 'xCircle' : 'info'),
    h('div', { class: 'notice-body' }, h('strong', {}, title), ...(lines.length > 0 ? [h('ul', {}, lines.map((l) => h('li', {}, l)))] : [])),
    h('button', { type: 'button', class: 'icon-btn', 'aria-label': 'Dismiss', onclick: () => (notice.hidden = true) }, icon('x')),
  );
  window.scrollTo({ top: 0 });
}

// Header -----------------------------------------------------------------------------------------
const fileInput = h('input', {
  type: 'file',
  accept: '.json,application/json',
  class: 'sr-only',
  tabindex: -1,
  'data-testid': 'import-input',
  onchange: async () => {
    const file = fileInput.files?.[0];
    fileInput.value = '';
    if (!file) return;
    const r = importProfile(await file.text());
    if (!r.profile) {
      showNotice('error', `Could not import ${file.name}`, r.errors.map((e) => (e.path ? `${e.path}: ${e.message}` : e.message)));
      return;
    }
    store.replace(r.profile);
    showNotice('info', `Imported ${file.name}`, r.warnings);
  },
});

const includeSecrets = h('input', { type: 'checkbox', id: 'include-secrets', 'data-testid': 'include-secrets' });

const modeSwitch = h('div', { class: 'seg mode-switch', role: 'group', 'aria-label': 'Configuration mode', 'data-testid': 'mode-switch' });
for (const [m, label, ico] of [['quick', 'Quick Deployment', 'zap'], ['advanced', 'Advanced Configuration', 'sliders']] as [Mode, string, IconName][]) {
  modeSwitch.append(h('button', { type: 'button', 'data-mode': m, 'aria-pressed': 'false', onclick: () => setMode(m) }, icon(ico), h('span', {}, label)));
}

const viewSwitch = h('div', { class: 'seg', role: 'group', 'aria-label': 'Settings view' });
let view: View = loadPref(VIEW_KEY) === 'advanced' ? 'advanced' : 'basic';
for (const v of ['basic', 'advanced'] as View[]) {
  viewSwitch.append(h('button', { type: 'button', 'data-view': v, 'aria-pressed': 'false', onclick: () => setView(v) }, v === 'basic' ? 'Basic' : 'Advanced'));
}

const THEMES: [Theme, IconName, string][] = [
  ['light', 'sun', 'Light'],
  ['dark', 'moon', 'Dark'],
  ['system', 'monitor', 'System'],
];
const themeSwitch = h('div', { class: 'seg seg-icons', role: 'group', 'aria-label': 'Appearance' });
let theme: Theme = ((t) => (t === 'light' || t === 'system' ? t : 'dark'))(loadPref(THEME_KEY));
for (const [t, ico, label] of THEMES) {
  themeSwitch.append(h('button', { type: 'button', 'data-theme-choice': t, 'aria-pressed': 'false', 'aria-label': `${label} appearance`, title: `${label} appearance`, onclick: () => setTheme(t) }, icon(ico)));
}
function setTheme(t: Theme): void {
  theme = t;
  document.documentElement.dataset.theme = t;
  savePref(THEME_KEY, t);
  for (const b of themeSwitch.querySelectorAll<HTMLButtonElement>('button')) b.setAttribute('aria-pressed', String(b.dataset.themeChoice === t));
}

const menuButton = (cls: string) =>
  h('button', { type: 'button', class: `icon-btn menu-btn ${cls}`, 'aria-controls': 'sidebar', 'aria-expanded': 'false', 'aria-label': 'Open section navigation', onclick: () => setDrawer(!document.body.classList.contains('nav-open')) }, icon('menu'));

const header = h(
  'header',
  { class: 'app-header' },
  h(
    'div',
    { class: 'brand' },
    h('div', { class: 'logo' }, icon('windows')),
    h(
      'div',
      { class: 'brand-text' },
      h('h1', {}, 'Windows Deployment Builder'),
      h(
        'p',
        { class: 'tagline' },
        h('span', {}, 'Answer file, Windows Update and WinGet provisioning for Windows 11 Pro'),
        h('span', { class: 'offline-pill', title: 'Everything is generated in this browser. Nothing is uploaded.' }, h('span', { class: 'dot' }), 'Runs entirely offline'),
      ),
    ),
  ),
  h(
    'div',
    { class: 'toolbar' },
    h('div', { class: 'tool-group' }, modeSwitch),
    h('div', { class: 'tool-group view-tool' }, viewSwitch),
    h(
      'div',
      { class: 'tool-group' },
      h('button', { type: 'button', class: 'btn', 'data-action': 'import', 'aria-label': 'Import profile…', title: 'Import a profile JSON file', onclick: () => fileInput.click() }, icon('importIcon'), h('span', { class: 'btn-text' }, 'Import profile…')),
      fileInput,
      h(
        'button',
        {
          type: 'button',
          class: 'btn',
          'data-action': 'export',
          'aria-label': 'Export profile…',
          title: 'Export this configuration as a profile JSON file',
          onclick: () => {
            const p = store.get();
            download(`${(p.profileName || 'profile').replace(/[^\w.-]+/g, '-')}.json`, exportProfile(p, { includeSecrets: includeSecrets.checked }), 'application/json');
            if (!includeSecrets.checked && hasSecrets(p)) showNotice('info', 'Exported without passwords', ['Account and Wi-Fi passwords were left out. Tick "Include passwords" to keep them.']);
          },
        },
        icon('exportIcon'),
        h('span', { class: 'btn-text' }, 'Export profile…'),
      ),
      h('label', { class: 'check-inline', for: 'include-secrets' }, includeSecrets, h('span', {}, 'Include passwords')),
    ),
    h(
      'div',
      { class: 'tool-group' },
      themeSwitch,
      h(
        'button',
        {
          type: 'button',
          class: 'btn',
          'data-action': 'reset',
          'aria-label': 'Reset to owner defaults',
          title: 'Reset every setting to the owner defaults',
          onclick: () => {
            if (confirm('Reset every setting to the owner defaults? Unsaved changes are lost.')) {
              store.replace(ownerDefaults());
              showNotice('info', 'Reset to owner defaults');
            }
          },
        },
        icon('reset'),
        h('span', { class: 'btn-text' }, 'Reset to owner defaults'),
      ),
    ),
  ),
);

// Pages ------------------------------------------------------------------------------------------
const identity = h('p', { class: 'identity', 'data-testid': 'identity' });
// Phase 4.3: the detailed risk explanation lives in Final Review & Considerations; the data-entry
// page keeps only this one-line pointer when the risky combination is selected.
const autologonBanner = h(
  'p',
  { class: 'risk-note', role: 'note', 'data-testid': 'autologon-note' },
  icon('alert'),
  h('span', {}, 'Administrator without a password, signing in automatically. '),
  h('a', { href: '#section-review', 'data-review-link': 'true' }, 'See the security considerations'),
);

interface GroupCard {
  el: HTMLElement;
  members: { def: SettingDef; handle: FieldHandle }[];
}
const groupCards: GroupCard[] = [];
const pages = new Map<PageId, HTMLElement>();
const pagers = new Map<PageId, HTMLElement>();
const pagesEl = h('div', { class: 'pages' });

for (const section of SECTIONS) {
  const defs = ALL_SETTINGS.filter((s) => s.section === section.id);
  if (defs.length === 0) continue;
  const allAdvanced = defs.every((d) => d.advanced);
  const pageEl = h(
    'section',
    { class: `page${allAdvanced ? ' advanced' : ''}`, id: `section-${section.id}`, 'data-page': section.id, 'aria-labelledby': `title-${section.id}`, hidden: true },
    h(
      'header',
      { class: 'page-head' },
      h('div', { class: 'page-icon' }, icon(PAGE_ICONS[section.id] ?? 'gear')),
      h('div', {}, h('h2', { id: `title-${section.id}`, tabindex: -1 }, section.title), section.intro ? h('p', { class: 'intro' }, section.intro) : null),
    ),
    section.id === 'accounts' ? identity : null,
    section.id === 'accounts' ? autologonBanner : null,
  );
  const groups = FIELD_GROUPS[section.id] ?? [{ title: '', paths: defs.map((d) => d.path) }];
  for (const g of groups) {
    const body = h('div', { class: 'group-body' });
    const el = h(
      'section',
      { class: `group-card${g.paths.every((p) => SETTINGS_BY_PATH.get(p)?.advanced) ? ' advanced' : ''}` },
      g.title ? h('header', { class: 'group-head' }, h('h3', {}, g.title), g.description ? h('p', {}, g.description) : null) : null,
      body,
    );
    const card: GroupCard = { el, members: [] };
    for (const def of defs.filter((d) => g.paths.includes(d.path))) {
      const handle = renderField(def, store, CUSTOM_RENDERERS);
      handle.el.id = `field-${def.path}`;
      fields.push({ def, handle });
      card.members.push({ def, handle });
      body.append(handle.el);
    }
    groupCards.push(card);
    pageEl.append(el);
  }
  const pager = h('nav', { class: 'pager', 'aria-label': 'Previous and next section' });
  pageEl.append(pager);
  pagers.set(section.id, pager);
  pages.set(section.id, pageEl);
  pagesEl.append(pageEl);
}
const deploymentPager = h('nav', { class: 'pager', 'aria-label': 'Previous and next section' });
deploymentPage.el.append(deploymentPager);
pagers.set('deployment', deploymentPager);
pages.set('deployment', deploymentPage.el);
pagesEl.append(deploymentPage.el);
review.el.hidden = true;
const reviewPager = h('nav', { class: 'pager', 'aria-label': 'Previous and next section' });
review.el.append(reviewPager);
pagers.set('review', reviewPager);
pages.set('review', review.el);
pagesEl.append(review.el);

// Sidebar ----------------------------------------------------------------------------------------
const navLinks: { item: NavItem; a: HTMLAnchorElement; badge: HTMLElement }[] = [];
const sidebarStatus = h('a', { class: 'sidebar-status', href: '#section-review', 'data-testid': 'nav-status' });
const sidebar = h(
  'aside',
  { class: 'sidebar', id: 'sidebar', 'aria-label': 'Sections' },
  h(
    'div',
    { class: 'sidebar-head' },
    h('span', {}, 'Sections'),
    h('button', { type: 'button', class: 'icon-btn', 'aria-label': 'Close section navigation', onclick: () => setDrawer(false) }, icon('x')),
  ),
  h(
    'nav',
    { 'aria-label': 'Sections' },
    NAV_GROUPS.map((g) =>
      h(
        'div',
        { class: 'nav-group' },
        h('p', { class: 'nav-title' }, g.title),
        h(
          'ul',
          {},
          g.items
            .filter((item) => pages.has(item.page))
            .map((item) => {
              const badge = h('span', { class: 'nav-badge', hidden: true });
              const a = h('a', { class: 'nav-item', href: `#${item.target}`, 'data-target': item.target }, icon(item.icon), h('span', { class: 'nav-label' }, item.label), badge);
              navLinks.push({ item, a, badge });
              return h('li', { class: pages.get(item.page)!.classList.contains('advanced') ? 'advanced' : undefined }, a);
            }),
        ),
      ),
    ),
  ),
  sidebarStatus,
);
const backdrop = h('div', { class: 'backdrop', onclick: () => setDrawer(false) });

const mobileTitle = h('span', { class: 'mobile-title' });
const mobileStatus = h('a', { class: 'mobile-status', href: '#section-review', 'aria-label': 'Review & download' });
const mobileBar = h('div', { class: 'mobile-bar' }, menuButton('in-bar'), mobileTitle, mobileStatus);

const main = h('main', { id: 'main', tabindex: -1 }, notice, pagesEl);

// Quick Deployment -------------------------------------------------------------------------------
/** Risks confirmed in this session (shared by Final Review and the Advanced download buttons). */
const acks = new Set<string>();
const wizard = renderWizard({ store, acks, openAdvanced: (target) => openAdvanced(target) });
const wizardShell = h('div', { class: 'wizard-shell', id: 'quick' });
let mode: Mode = 'quick';

function setMode(m: Mode, opts: { route?: boolean } = {}): void {
  mode = m;
  document.body.dataset.mode = m;
  savePref(MODE_KEY, m);
  for (const b of modeSwitch.querySelectorAll<HTMLButtonElement>('button')) b.setAttribute('aria-pressed', String(b.dataset.mode === m));
  // Only one of the two editors is in the document at a time, so ids and test ids stay unique;
  // both edit the same store, so nothing is lost by switching.
  if (m === 'quick') {
    if (!wizardShell.contains(wizard.el)) wizardShell.append(wizard.el);
    wizard.update(store.get(), generate(store.get()));
    if (location.hash.startsWith('#section-') || location.hash.startsWith('#app-') || location.hash === '#deployment-assets') history.replaceState(null, '', '#quick');
    window.scrollTo({ top: 0 });
  } else {
    wizard.el.remove();
    if (opts.route !== false) route(location.hash.startsWith('#section-') || location.hash.startsWith('#app-') ? location.hash : '#section-setup');
  }
}

/** Opens Advanced Configuration at a page (section-…, app-…) or at a setting path. */
function openAdvanced(target: string): void {
  setMode('advanced', { route: false });
  if (/^(section-|app-|deployment-assets)/.test(target)) {
    history.pushState(null, '', `#${target}`);
    route(`#${target}`, true);
    return;
  }
  const field = document.getElementById(`field-${target}`) ?? document.querySelector(`[data-issues-for^="${CSS.escape(target)}"]`);
  const pageEl = field?.closest<HTMLElement>('[data-page]');
  if (!field || !pageEl) {
    history.pushState(null, '', '#section-review');
    route('#section-review', true);
    return;
  }
  if (field.closest('.advanced') && view === 'basic') setView('advanced');
  history.pushState(null, '', `#${pageEl.id}`);
  showPage(pageEl.dataset.page as PageId);
  field.scrollIntoView({ block: 'center' });
  field.querySelector<HTMLElement>('input, select, textarea, button')?.focus({ preventScroll: true });
}

// Embedding a Wi-Fi password in the package needs a one-time confirmation in Advanced too.
document.addEventListener(
  'click',
  (e) => {
    const b = (e.target as Element).closest<HTMLElement>('[data-action="download-package"], [data-action="download-xml-only"], [data-action="download-xml"]');
    if (!b) return;
    const p = store.get();
    if (!wifiSecretEmbedded(p) || acks.has(ackKey(p, 'wifi-secret'))) return;
    if (confirm('The answer file and the ZIP will contain the Wi-Fi password in plain text. Anyone with the ZIP or the USB drive can read it.\n\nGenerate it anyway?')) {
      acks.add(ackKey(p, 'wifi-secret'));
      return;
    }
    e.preventDefault();
    e.stopImmediatePropagation();
  },
  true,
);
const footer = h(
  'footer',
  { class: 'app-footer' },
  h('p', {}, 'Based on the option model and XML patterns of ', h('a', { href: 'https://github.com/cschneegans/unattend-generator', rel: 'noopener' }, 'cschneegans/unattend-generator'), ' (MIT), reimplemented in TypeScript. Not affiliated with Christoph Schneegans or Microsoft.'),
);

app.append(header, mobileBar, wizardShell, h('div', { class: 'shell' }, sidebar, backdrop, h('div', { class: 'content' }, main, footer)));

// Navigation -------------------------------------------------------------------------------------
const PAGE_ORDER: PageId[] = NAV_GROUPS.flatMap((g) => g.items.filter((i) => i.target === `section-${i.page}`).map((i) => i.page)).filter((p) => pages.has(p));
let activePage: PageId = 'setup';

const pageTitle = (id: PageId) => NAV_GROUPS.flatMap((g) => g.items).find((i) => i.target === `section-${id}`)?.label ?? id;
const pageVisible = (id: PageId) => view === 'advanced' || !pages.get(id)!.classList.contains('advanced');

function renderPagers(): void {
  const visible = PAGE_ORDER.filter(pageVisible);
  for (const [id, pager] of pagers) {
    clear(pager);
    const i = visible.indexOf(id);
    const prev = i > 0 ? visible[i - 1] : undefined;
    const next = i >= 0 && i < visible.length - 1 ? visible[i + 1] : undefined;
    pager.append(
      prev
        ? h('a', { class: 'pager-link prev', href: `#section-${prev}`, 'data-pager': 'prev' }, icon('chevronLeft'), h('span', {}, h('small', {}, 'Previous'), pageTitle(prev)))
        : h('span', {}),
      next ? h('a', { class: 'pager-link next', href: `#section-${next}`, 'data-pager': 'next' }, h('span', {}, h('small', {}, 'Next'), pageTitle(next)), icon('chevronRight')) : h('span', {}),
    );
  }
}

function setDrawer(open: boolean): void {
  document.body.classList.toggle('nav-open', open);
  for (const b of document.querySelectorAll('.menu-btn')) b.setAttribute('aria-expanded', String(open));
  if (open) requestAnimationFrame(() => sidebar.querySelector<HTMLElement>('.nav-item[aria-current]')?.focus());
}

function showPage(id: PageId, opts: { navTarget?: string; scrollTo?: Element | null; focus?: boolean } = {}): void {
  activePage = id;
  for (const [pid, el] of pages) el.hidden = pid !== id;
  const navTarget = opts.navTarget && navLinks.some((l) => l.item.target === opts.navTarget) ? opts.navTarget : `section-${id}`;
  for (const { item, a } of navLinks) {
    if (item.target === navTarget) a.setAttribute('aria-current', 'page');
    else a.removeAttribute('aria-current');
  }
  mobileTitle.textContent = pageTitle(id);
  setDrawer(false);
  if (opts.scrollTo) opts.scrollTo.scrollIntoView({ block: 'start' });
  else window.scrollTo({ top: 0 });
  if (opts.focus) pages.get(id)!.querySelector<HTMLElement>('h2')?.focus({ preventScroll: true });
}

function route(hash: string, focus = false): void {
  if (hash === '#quick') {
    if (mode !== 'quick') setMode('quick');
    return;
  }
  if (mode === 'quick' && hash && hash !== '#main') setMode('advanced', { route: false });
  const id = decodeURIComponent(hash.replace(/^#/, '')) || 'section-setup';
  const target = document.getElementById(id);
  const pageEl = target?.closest<HTMLElement>('[data-page]');
  if (!target || !pageEl) {
    if (target) target.focus();
    else showPage('setup');
    return;
  }
  if (pageEl.classList.contains('advanced') && view === 'basic') setView('advanced');
  showPage(pageEl.dataset.page as PageId, { navTarget: id, scrollTo: target === pageEl ? null : target, focus });
}

document.addEventListener('click', (e) => {
  if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey) return;
  const jump = (e.target as Element).closest<HTMLAnchorElement>('a[data-jump]');
  if (jump) {
    const path = jump.dataset.jump ?? '';
    const target = document.getElementById(`field-${path}`) ?? document.querySelector(`[data-issues-for^="${CSS.escape(path)}"]`);
    const pageEl = target?.closest<HTMLElement>('[data-page]');
    if (!target || !pageEl) return;
    e.preventDefault();
    if (target.closest('.advanced') && view === 'basic') setView('advanced');
    history.pushState(null, '', `#${pageEl.id}`);
    showPage(pageEl.dataset.page as PageId);
    target.scrollIntoView({ block: 'center' });
    target.querySelector<HTMLElement>('input, select, textarea, button')?.focus({ preventScroll: true });
    return;
  }
  const a = (e.target as Element).closest<HTMLAnchorElement>('a[href^="#"]');
  if (!a) return;
  const hash = a.getAttribute('href')!;
  if (hash === '#main') return;
  e.preventDefault();
  if (hash !== location.hash) history.pushState(null, '', hash);
  route(hash, true);
});
window.addEventListener('popstate', () => route(location.hash));
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && document.body.classList.contains('nav-open')) {
    setDrawer(false);
    document.querySelector<HTMLElement>('.menu-btn.in-bar')?.focus();
  }
});

// Keeps the sticky offsets right when the header wraps onto more lines.
new ResizeObserver(() => document.documentElement.style.setProperty('--header-h', `${header.offsetHeight}px`)).observe(header);

function setView(v: View): void {
  view = v;
  document.body.dataset.view = v;
  savePref(VIEW_KEY, v);
  for (const b of viewSwitch.querySelectorAll('button')) b.setAttribute('aria-pressed', String(b.dataset.view === v));
  updateGroups();
  renderPagers();
  if (!pageVisible(activePage)) {
    history.replaceState(null, '', '#section-setup');
    showPage('setup');
  }
}

/** A card disappears when none of its settings is visible in the current view and state. */
function updateGroups(): void {
  for (const g of groupCards) g.el.hidden = !g.members.some((m) => !m.handle.el.hidden && (view === 'advanced' || !m.def.advanced));
}

// Issues -----------------------------------------------------------------------------------------
function pageOf(path: string): PageId {
  const parts = path.split('.');
  for (let i = parts.length; i > 0; i--) {
    const def = SETTINGS_BY_PATH.get(parts.slice(0, i).join('.'));
    if (def) return def.section;
  }
  return 'review';
}

function showIssues(issues: Issue[]): void {
  for (const slot of document.querySelectorAll<HTMLElement>('[data-issues-for]')) {
    clear(slot);
    slot.closest('.field, .item')?.classList.remove('has-error');
  }
  for (const issue of issues) {
    let path = issue.path;
    let slot: HTMLElement | null = null;
    while (path && !(slot = document.querySelector<HTMLElement>(`[data-issues-for="${CSS.escape(path)}"]`))) {
      path = path.includes('.') ? path.slice(0, path.lastIndexOf('.')) : '';
    }
    if (!slot) continue;
    slot.append(h('p', { class: issue.severity, 'data-severity': issue.severity }, icon(issue.severity === 'error' ? 'xCircle' : issue.severity === 'warning' ? 'alert' : 'info'), h('span', {}, issue.message)));
    if (issue.severity === 'error') slot.closest('.field, .item')?.classList.add('has-error');
  }

  const perPage = new Map<PageId, { errors: number; warnings: number }>();
  for (const i of issues) {
    const page = pageOf(i.path);
    const c = perPage.get(page) ?? { errors: 0, warnings: 0 };
    if (i.severity === 'error') c.errors++;
    else if (i.severity === 'warning') c.warnings++;
    perPage.set(page, c);
  }
  for (const { item, badge } of navLinks) {
    if (item.target !== `section-${item.page}`) {
      badge.hidden = true;
      continue;
    }
    const c = item.page === 'review' ? { errors: issues.filter((i) => i.severity === 'error').length, warnings: 0 } : perPage.get(item.page);
    badge.hidden = !c || (c.errors === 0 && c.warnings === 0);
    if (!c) continue;
    badge.className = `nav-badge ${c.errors ? 'err' : 'warn'}`;
    badge.textContent = String(c.errors || c.warnings);
    badge.title = c.errors ? `${c.errors} error(s)` : `${c.warnings} warning(s)`;
  }

  const errors = issues.filter((i) => i.severity === 'error').length;
  const warnings = issues.filter((i) => i.severity === 'warning').length;
  clear(sidebarStatus);
  sidebarStatus.className = `sidebar-status ${errors ? 'err' : warnings ? 'warn' : 'ok'}`;
  sidebarStatus.append(
    icon(errors ? 'xCircle' : warnings ? 'alert' : 'checkCircle'),
    h('span', {}, h('strong', {}, errors ? `${errors} problem${errors === 1 ? '' : 's'} to fix` : 'Ready to generate'), h('small', {}, warnings ? `${warnings} warning${warnings === 1 ? '' : 's'}` : errors ? 'Download is blocked' : 'No warnings')),
  );
  clear(mobileStatus);
  mobileStatus.className = `mobile-status ${errors ? 'err' : warnings ? 'warn' : 'ok'}`;
  mobileStatus.append(icon(errors ? 'xCircle' : warnings ? 'alert' : 'checkCircle'), h('span', {}, errors ? String(errors) : 'Ready'));
}

// Update cycle -----------------------------------------------------------------------------------
function refresh(p: Profile, structural: boolean): void {
  if (structural) {
    for (const f of fields) f.handle.sync(p);
    updateGroups();
  }
  const id = resolveIdentity(p.accounts);
  identity.hidden = p.accounts.accountMode !== 'unattendedLocal';
  identity.textContent = `Username: ${id.username || '—'} · Display name: ${id.displayName || '—'} · Computer name: ${id.computerName ?? 'random'}`;
  autologonBanner.hidden = !isEmptyPasswordAutoAdmin(p);
  const result: GenerateResult = generate(p);
  showIssues(result.issues);
  deploymentPage.update(p, result);
  review.update(p, result);
  if (mode === 'quick') wizard.update(p, result);
}

// Saved application profiles: restored from this browser at start-up and after a reset or an
// import, and every custom profile is saved back when it changes (src/ui/library.ts).
let syncingLibrary = false;
store.subscribe((p, structural) => {
  if (!structural || syncingLibrary) return;
  syncingLibrary = true;
  try {
    if (profileLibrary.list().some((x) => !p.applications.selection.profiles.some((y) => y.id === x.id))) {
      store.update((q) => profileLibrary.restoreInto(q.applications.selection), true);
    }
    profileLibrary.saveFrom(store.get().applications.selection);
  } finally {
    syncingLibrary = false;
  }
});
profileLibrary.restoreInto(store.get().applications.selection);
store.subscribe(refresh);
setTheme(theme);
setView(view);
refresh(store.get(), true);
const startHash = location.hash;
if (startHash && startHash !== '#quick' && startHash !== '#main') setMode('advanced');
else setMode(loadPref(MODE_KEY) === 'advanced' ? 'advanced' : 'quick');
