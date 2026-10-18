import './styles.css';
import { generate, type GenerateResult } from './engine/pipeline';
import { exportProfile, hasSecrets, importProfile, ownerDefaults } from './engine/profiles';
import { resolveIdentity } from './engine/naming';
import type { Profile } from './engine/schema/profile';
import type { Issue } from './engine/validation/issues';
import { ALL_SETTINGS, SECTIONS } from './features';
import { AUTOLOGON_WARNING } from './features/accounts';
import { CUSTOM_RENDERERS } from './ui/editors';
import { clear, download, h } from './ui/dom';
import { renderField, type FieldHandle } from './ui/form';
import { renderReview } from './ui/review';
import { Store } from './ui/store';

type View = 'basic' | 'advanced';
const VIEW_KEY = 'wdb.view';

function loadView(): View {
  try {
    return localStorage.getItem(VIEW_KEY) === 'advanced' ? 'advanced' : 'basic';
  } catch {
    return 'basic';
  }
}

function saveView(v: View): void {
  try {
    localStorage.setItem(VIEW_KEY, v);
  } catch {
    /* storage unavailable: view preference is only a convenience */
  }
}

const store = new Store();
const fields: FieldHandle[] = [];
const review = renderReview();
const app = document.getElementById('app')!;

// Header ---------------------------------------------------------------------------------------
const notice = h('div', { class: 'notice', role: 'status', 'aria-live': 'polite', 'data-testid': 'notice', hidden: true });
function showNotice(kind: 'info' | 'error', title: string, lines: string[] = []): void {
  clear(notice);
  notice.hidden = false;
  notice.className = `notice ${kind}`;
  notice.append(
    h('strong', {}, title),
    ...(lines.length > 0 ? [h('ul', {}, lines.map((l) => h('li', {}, l)))] : []),
    h('button', { type: 'button', class: 'icon', 'aria-label': 'Dismiss', onclick: () => (notice.hidden = true) }, '✕'),
  );
}

const fileInput = h('input', {
  type: 'file',
  accept: '.json,application/json',
  class: 'sr-only',
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
    const extra = r.profile.deferred.wingetPackages.length ? [`${r.profile.deferred.wingetPackages.length} WinGet package(s) kept for this session only (not used by M1).`] : [];
    showNotice('info', `Imported ${file.name}`, [...r.warnings, ...extra]);
  },
});

const includeSecrets = h('input', { type: 'checkbox', id: 'include-secrets', 'data-testid': 'include-secrets' });
const viewSwitch = h('div', { class: 'view-switch', role: 'radiogroup', 'aria-label': 'View' });
let view: View = loadView();
function setView(v: View): void {
  view = v;
  document.body.dataset.view = v;
  saveView(v);
  for (const b of viewSwitch.querySelectorAll('button')) b.setAttribute('aria-pressed', String(b.dataset.view === v));
}
for (const v of ['basic', 'advanced'] as View[]) {
  viewSwitch.append(h('button', { type: 'button', 'data-view': v, 'aria-pressed': 'false', onclick: () => setView(v) }, v === 'basic' ? 'Basic' : 'Advanced'));
}

const header = h(
  'header',
  { class: 'top' },
  h('div', { class: 'brand' }, h('h1', {}, 'Windows Deployment Builder'), h('p', {}, 'autounattend.xml generator for Windows 11 Pro · Milestone 1 · runs entirely offline in this browser')),
  h(
    'div',
    { class: 'toolbar' },
    viewSwitch,
    h('button', { type: 'button', class: 'btn', 'data-action': 'import', onclick: () => fileInput.click() }, 'Import profile…'),
    fileInput,
    h(
      'span',
      { class: 'export' },
      h(
        'button',
        {
          type: 'button',
          class: 'btn',
          'data-action': 'export',
          onclick: () => {
            const p = store.get();
            download(`${(p.profileName || 'profile').replace(/[^\w.-]+/g, '-')}.json`, exportProfile(p, { includeSecrets: includeSecrets.checked }), 'application/json');
            if (!includeSecrets.checked && hasSecrets(p)) showNotice('info', 'Exported without passwords', ['Account and Wi-Fi passwords were left out. Tick "include passwords" to keep them.']);
          },
        },
        'Export profile',
      ),
      h('span', { class: 'check' }, includeSecrets, h('label', { for: 'include-secrets' }, 'include passwords')),
    ),
    h(
      'button',
      {
        type: 'button',
        class: 'btn',
        'data-action': 'reset',
        onclick: () => {
          if (confirm('Reset every setting to the owner defaults? Unsaved changes are lost.')) {
            store.replace(ownerDefaults());
            showNotice('info', 'Reset to owner defaults');
          }
        },
      },
      'Reset to owner defaults',
    ),
  ),
  notice,
);

// Sections -------------------------------------------------------------------------------------
const identity = h('p', { class: 'identity', 'data-testid': 'identity' });
const autologonBanner = h(
  'div',
  { class: 'hazard', role: 'note', 'data-testid': 'autologon-warning' },
  h('strong', {}, 'Security warning: '),
  AUTOLOGON_WARNING,
  ' This is the requested owner default. Choose a password and "once" or "none" under Advanced for a safer setup. Initial auto-login is separate from the Windows Update restart sign-on setting under System tweaks.',
);

const nav = h('nav', { class: 'toc', 'aria-label': 'Sections' });
const main = h('main', { id: 'main' });

for (const section of SECTIONS) {
  const defs = ALL_SETTINGS.filter((s) => s.section === section.id);
  if (defs.length === 0) continue;
  const allAdvanced = defs.every((d) => d.advanced);
  const sectionEl = h(
    'section',
    { class: `section${allAdvanced ? ' advanced' : ''}`, id: `section-${section.id}`, 'aria-labelledby': `title-${section.id}` },
    h('h2', { id: `title-${section.id}` }, section.title),
    section.intro ? h('p', { class: 'intro' }, section.intro) : null,
    section.id === 'accounts' ? identity : null,
    section.id === 'accounts' ? autologonBanner : null,
  );
  for (const def of defs) {
    const field = renderField(def, store, CUSTOM_RENDERERS);
    field.el.id = `field-${def.path}`;
    fields.push(field);
    sectionEl.append(field.el);
  }
  main.append(sectionEl);
  nav.append(h('a', { href: `#section-${section.id}`, class: allAdvanced ? 'advanced' : undefined }, section.title));
}
main.append(review.el);
nav.append(h('a', { href: '#section-review' }, 'Review & download'));

const footer = h(
  'footer',
  {},
  h('p', {}, 'Based on the option model and XML patterns of ', h('a', { href: 'https://github.com/cschneegans/unattend-generator', rel: 'noopener' }, 'cschneegans/unattend-generator'), ' (MIT), reimplemented in TypeScript. Not affiliated with Christoph Schneegans or Microsoft.'),
);

app.append(header, h('div', { class: 'layout' }, nav, main), footer);

// Issues ---------------------------------------------------------------------------------------
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
    slot.append(h('p', { class: issue.severity, 'data-severity': issue.severity }, issue.message));
    if (issue.severity === 'error') slot.closest('.field, .item')?.classList.add('has-error');
  }
}

document.addEventListener('click', (e) => {
  const a = (e.target as Element).closest<HTMLAnchorElement>('a[data-jump]');
  if (!a) return;
  const target = document.getElementById(`field-${a.dataset.jump}`) ?? document.querySelector(`[data-issues-for^="${CSS.escape(a.dataset.jump ?? '')}"]`);
  if (target?.closest('.advanced') && view === 'basic') setView('advanced');
  if (target) {
    e.preventDefault();
    target.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }
});

// Update cycle ---------------------------------------------------------------------------------
function refresh(p: Profile, structural: boolean): void {
  if (structural) for (const f of fields) f.sync(p);
  const id = resolveIdentity(p.accounts);
  identity.hidden = p.accounts.accountMode !== 'unattendedLocal';
  identity.textContent = `Username: ${id.username || '—'} · Display name: ${id.displayName || '—'} · Computer name: ${id.computerName ?? 'random'}`;
  autologonBanner.hidden = !(p.accounts.accountMode === 'unattendedLocal' && p.accounts.autoLogon !== 'none' && p.accounts.accountGroup === 'Administrators');
  const result: GenerateResult = generate(p);
  showIssues(result.issues);
  review.update(p, result);
}

store.subscribe(refresh);
setView(view);
refresh(store.get(), true);
