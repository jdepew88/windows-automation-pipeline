import type { AppProfile, ApplicationsSelection, Devices, PackageRef } from '../engine/schema/applications';
import { BUILTIN_PROFILES, UNIVERSAL_PROFILES, isSelectableProfile } from '../engine/applications/builtin';
import {
  CATALOG,
  CATALOG_CATEGORIES,
  CATALOG_EXCLUDED,
  CATALOG_UPDATED,
  CONFLICT_GROUPS,
  catalogRef,
  entryKey,
  isManual,
  methodOf,
  searchCatalog,
  type CatalogCategory,
  type CatalogEntry,
  type InstallMethod,
} from '../engine/applications/catalog';
import { MSSTORE_ID, VERSION, WINGET_ID, normalizeId, packageKey } from '../engine/applications/ids';
import { ADDED, REQUIRED, allProfiles, effectiveDevices, installable, resolveSelection, type PlannedPackage, type SelectionResult } from '../engine/applications/selection';
import {
  addPackage,
  deleteProfile,
  describeProfile,
  duplicateProfile,
  exportAppProfiles,
  importAppProfiles,
  pruneDetached,
  removePackage,
  renameProfile,
  resetOverrides,
  resetSelection,
  restorePackage,
  restoreProfileDefaults,
  saveAsNewProfile,
  toggleProfile,
  updateProfileFromSelection,
} from '../engine/applications/profiles';
import { exportWinGetJson } from '../engine/applications/winget-json';
import { planPreview, wingetArguments } from '../engine/applications';
import { clear, download, h, patchChildren, render as patch, uid } from './dom';
import { appLogo } from './app-icon';
import { loadCatalogView, renderTile, saveCatalogView, viewSwitcher, type CatalogView, type ItemModel } from './catalog-view';
import { customShell, type CustomRenderer } from './form';
import { icon, type IconName } from './icons';
import { profileLibrary } from './library';

/**
 * Application provisioning editor (Phase 4.2): profiles, device answers, one checkbox per catalog
 * application and the resulting installation plan. Every control edits the deployment's
 * selection (profiles ticked, devices, individual additions/removals); built-in profiles are
 * never edited.
 */

type Filter = 'relevant' | 'selected' | 'defaults' | 'recommended' | 'deselected' | 'all' | 'manual' | 'excluded';
const FILTERS: [Filter, string][] = [
  ['relevant', 'Suggested'],
  ['selected', 'Selected'],
  ['defaults', 'Profile defaults'],
  ['recommended', 'Recommended'],
  ['deselected', 'Unticked by you'],
  ['all', 'All apps'],
  ['manual', 'Manual follow-up'],
  ['excluded', 'Not offered'],
];

const METHOD_LABEL: Record<InstallMethod, [string, string, string]> = {
  winget: ['WinGet', 'muted', 'Installed silently with winget install --id … --exact --source winget.'],
  msstore: ['Microsoft Store', 'info', 'Installed from the Microsoft Store through WinGet (msstore source); no Microsoft account is needed for free apps.'],
  portable: ['Portable', 'info', 'WinGet portable package: downloaded from the publisher, SHA-256 checked, installed machine-wide, with a Start menu shortcut. Never run by the deployment.'],
  vendor: ['Manual follow-up', 'warn', 'Not installed automatically: listed with official download instructions.'],
  manual: ['Manual follow-up', 'warn', 'Not installed automatically: listed with official download instructions.'],
};

const PROFILE_ICONS: Record<string, IconName> = {
  core: 'star',
  everyday: 'home',
  gaming: 'gamepad',
  developer: 'code',
  network: 'globe',
  music: 'package',
  devices: 'laptop',
  laptop: 'laptop',
  touch: 'pen',
  custom: 'sliders',
};

const fileSafe = (s: string) => s.replace(/[^\w.-]+/g, '-').replace(/^-+|-+$/g, '') || 'profile';

function badge(text: string, kind = '', title?: string): HTMLElement {
  return h('span', { class: `badge${kind ? ` ${kind}` : ''}`, title }, text);
}

/** Initials tile; the colour follows the category so related apps look related. */
function avatar(name: string, category?: string): HTMLElement {
  const initials = name.replace(/[^\p{L}\p{N} ]/gu, ' ').split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0]!.toUpperCase()).join('') || '?';
  return h('span', { class: 'avatar', 'data-cat': category ?? 'other', 'aria-hidden': 'true' }, initials);
}

const btn = (label: string, ico: IconName | null, attrs: Record<string, string | boolean | ((e: Event) => void)>) => h('button', { type: 'button', class: 'btn', ...attrs }, ico ? icon(ico) : null, label);
const link = (label: string, action: string, onclick: () => void, extra: Record<string, string | boolean> = {}) => h('button', { type: 'button', class: 'linkish', 'data-action': action, onclick, ...extra }, label);

/** Display name of a profile id (built-in or custom). */
const profileName = (sel: ApplicationsSelection, id: string) => allProfiles(sel).find((p) => p.id === id)?.name ?? id;

/** Why a selected or removed package is in the plan, in words. */
export function explainOrigin(sel: ApplicationsSelection, x: PlannedPackage, r: SelectionResult): string {
  const profiles = x.origins.filter((o) => o !== ADDED && o !== REQUIRED);
  if (x.removedBy) {
    const from = profiles.length ? ` (default in ${profiles.map((o) => profileName(sel, o)).join(', ')})` : '';
    return x.removedBy === 'user' ? `Unticked by you${from}` : `Left out by saved profile "${profileName(sel, x.removedBy)}"${from}`;
  }
  const parts: string[] = [];
  // Universal profiles (Core Essentials) first, then the others, as "Selected by …".
  const ordered = [...profiles.filter((o) => UNIVERSAL_PROFILES.includes(o)), ...profiles.filter((o) => !UNIVERSAL_PROFILES.includes(o))];
  if (ordered.length) parts.push(`Selected by ${ordered.map((o) => profileName(sel, o)).join(', ')}`);
  const via = sel.addedWith?.[x.key];
  if (x.origins.includes(ADDED)) parts.push(via?.length ? `Ticked by you (recommended by ${via.map((o) => profileName(sel, o)).join(', ')})` : 'Added by you');
  if (x.origins.includes(REQUIRED)) {
    const by = x.requiredBy.map((k) => r.packages.find((p) => p.key === k)?.displayName ?? k);
    parts.push(`Required by ${by.join(', ')}`);
  }
  return parts.join(' · ') || 'Selected';
}

function methodBadge(method: InstallMethod): HTMLElement {
  const [label, kind, title] = METHOD_LABEL[method];
  return badge(label, kind, title);
}

export interface EditorOptions {
  /** Which blocks to show (all by default). The wizard shows the catalog and the plan only. */
  profiles?: boolean;
  devices?: boolean;
  plan?: boolean;
  troubleshooting?: boolean;
  /** Initial filter: the wizard opens on the whole catalog. */
  filter?: Filter;
}

export const applicationsEditor: CustomRenderer = (def, store) => createApplicationsEditor(def, store, {});

export function createApplicationsEditor(def: Parameters<CustomRenderer>[0], store: Parameters<CustomRenderer>[1], opts: EditorOptions): ReturnType<CustomRenderer> {
  const show = { profiles: opts.profiles ?? true, devices: opts.devices ?? true, plan: opts.plan ?? true, troubleshooting: opts.troubleshooting ?? true };
  // Local view state (never stored in the profile).
  let query = '';
  let category: CatalogCategory | '' = '';
  let filter: Filter = opts.filter ?? 'relevant';
  let view: CatalogView = loadCatalogView();

  const mutate = (fn: (sel: ApplicationsSelection) => void) => store.update((p) => fn(p.applications.selection), true);
  const status = h('div', { class: 'app-status', 'data-testid': 'app-import-status', 'aria-live': 'polite' });
  const say = (kind: 'info' | 'error', title: string, lines: string[] = []) => {
    clear(status);
    status.className = `app-status notice ${kind}`;
    status.append(
      icon(kind === 'error' ? 'xCircle' : 'info'),
      h('div', { class: 'notice-body' }, h('strong', {}, title), lines.length ? h('ul', {}, lines.slice(0, 12).map((l) => h('li', {}, l)), lines.length > 12 ? h('li', {}, `… and ${lines.length - 12} more`) : null) : null),
      h('button', { type: 'button', class: 'icon-btn', 'aria-label': 'Dismiss', onclick: () => clear(status) }, icon('x')),
    );
  };
  if (profileLibrary.warnings.length) say('error', 'Saved profiles in this browser', profileLibrary.warnings);

  // Toolbar -------------------------------------------------------------------------------------
  const stats = h('div', { class: 'app-stats', 'data-testid': 'app-stats', 'aria-live': 'polite', 'aria-atomic': 'true' });
  const fileInput = h('input', {
    type: 'file',
    accept: '.json,application/json',
    class: 'sr-only',
    tabindex: -1,
    'data-testid': 'app-import-input',
    onchange: async () => {
      const file = fileInput.files?.[0];
      fileInput.value = '';
      if (!file) return;
      const text = await file.text();
      const r = importAppProfiles(text, store.get().applications.selection.profiles, file.name);
      if (!r.ok) {
        say('error', `Could not import ${file.name}`, r.errors);
        return;
      }
      mutate((sel) => {
        sel.profiles.push(...r.profiles);
        for (const p of r.profiles) toggleProfile(sel, p.id, true);
      });
      const n = r.profiles.reduce((s, p) => s + p.packages.length, 0);
      say('info', `Imported ${file.name} as ${r.profiles.length === 1 ? `profile "${r.profiles[0]!.name}"` : `${r.profiles.length} profiles`} (${n} package(s))`, [
        'Saved as custom profile(s) in this browser and ticked; nothing you had selected was changed or removed. Untick a profile to leave it out.',
        ...r.warnings,
      ]);
    },
  });
  const toolbar = h(
    'div',
    { class: 'app-toolbar' },
    stats,
    h(
      'div',
      { class: 'app-actions' },
      btn('Save as new profile…', 'plus', {
        'data-action': 'app-save-new',
        onclick: () => {
          const name = prompt('Name for the new profile (for example "Aunt\'s Computer"):', '');
          if (!name?.trim()) return;
          let created: AppProfile | undefined;
          mutate((sel) => (created = saveAsNewProfile(sel, name)));
          if (created) say('info', `Saved "${created.name}"`, ['It is ticked now and reproduces exactly this selection. It is stored in this browser; export it as JSON for a backup.']);
        },
      }),
      h('a', { class: 'btn', href: '#section-migration', 'data-action': 'app-import-computer', title: 'Inventory an existing Windows computer and choose which of its applications to reinstall' }, icon('monitor'), 'Import applications from an existing computer'),
      btn('Import JSON…', 'importIcon', { 'data-action': 'app-import', title: 'A Windows Deployment Builder profile file or a native "winget export" file', onclick: () => fileInput.click() }),
      fileInput,
      btn('Export as WinGet JSON', 'exportIcon', {
        'data-action': 'app-export-winget',
        title: "Microsoft's package list format (winget import). Manual follow-ups are not part of it.",
        onclick: () => download('winget-packages.json', exportWinGetJson(installable(resolveSelection(store.get().applications.selection)).map((x) => x.ref)), 'application/json'),
      }),
      btn('Undo my changes', 'reset', {
        'data-action': 'app-reset-overrides',
        title: 'Clears every app you ticked or unticked individually; the ticked profiles and devices stay.',
        onclick: () => confirm('Undo every individual tick and untick? The ticked profiles and device answers stay.') && mutate(resetOverrides),
      }),
      btn('Reset applications', 'reset', {
        class: 'btn advanced',
        'data-action': 'app-reset-selection',
        title: 'Core Essentials only, no devices, no individual changes. Saved profiles are kept.',
        onclick: () => confirm('Reset the application selection to Core Essentials only? Your saved profiles are kept.') && mutate(resetSelection),
      }),
    ),
  );

  // Profiles ------------------------------------------------------------------------------------
  const builtinGrid = h('div', { class: 'profile-grid', 'data-testid': 'app-profiles' });
  const customGrid = h('div', { class: 'profile-grid', 'data-testid': 'app-custom-profiles' });
  const storageNote = h('p', { class: 'desc', 'data-testid': 'app-storage-note' });

  function profileCard(p: AppProfile, sel: ApplicationsSelection, r: SelectionResult): HTMLElement {
    const id = uid('ap');
    const checked = sel.selectedProfiles.includes(p.id);
    const defaults = p.packages.length;
    const optional = p.optional?.length ?? 0;
    const universal = UNIVERSAL_PROFILES.includes(p.id);
    const defaultKeys = new Set(p.packages.map(packageKey));
    const overridden = sel.removed.some((k) => defaultKeys.has(k)) || sel.added.some((a) => (p.optional ?? []).some((o) => packageKey(o) === packageKey(a)));
    const parents = p.inherits.map((i) => profileName(sel, i));
    const summary = [
      `${defaults} app${defaults === 1 ? '' : 's'}`,
      optional ? `${optional} optional` : '',
      parents.length ? `includes ${parents.join(', ')}` : '',
      p.excluded?.length ? `${p.excluded.length} left out` : '',
    ].filter(Boolean).join(' · ');
    return h(
      'div',
      { class: `profile-card${checked ? ' on' : ''}`, 'data-profile': p.id },
      h(
        'label',
        { class: 'profile-main', for: id },
        h('span', { class: 'profile-icon' }, icon(PROFILE_ICONS[p.category] ?? 'layers')),
        h('span', { class: 'profile-text' }, h('strong', {}, p.name), h('span', { class: 'choice-desc' }, summary)),
        h('input', { type: 'checkbox', id, name: `applications.profile.${p.id}`, checked, onchange: (e: Event) => mutate((s) => toggleProfile(s, p.id, (e.target as HTMLInputElement).checked)) }),
      ),
      universal ? h('div', { class: 'badges' }, badge('Universal: every new deployment', 'ok')) : null,
      p.description ? h('p', { class: 'choice-desc profile-desc' }, p.description) : null,
      h(
        'div',
        { class: 'card-actions' },
        p.builtin && overridden && checked ? link('Restore defaults', 'app-restore-profile', () => mutate((s) => restoreProfileDefaults(s, p.id)), { title: `Ticks ${p.name}'s defaults again and unticks its recommendations` }) : null,
        !p.builtin
          ? link('Update from selection', 'app-update-profile', () => {
              if (!confirm(`Replace "${p.name}" with the current selection (${r.packages.length} app(s))?`)) return;
              let ok = false;
              mutate((s) => (ok = updateProfileFromSelection(s, p.id)));
              say(ok ? 'info' : 'error', ok ? `Updated "${p.name}"` : `"${p.name}" could not reproduce the selection exactly`);
            })
          : null,
        !p.builtin
          ? link('Rename', 'app-rename-profile', () => {
              const name = prompt('New name:', p.name);
              if (name?.trim()) mutate((s) => renameProfile(s, p.id, name));
            })
          : null,
        !p.builtin
          ? link('Description', 'app-describe-profile', () => {
              const text = prompt('Description:', p.description);
              if (text !== null) mutate((s) => describeProfile(s, p.id, text));
            }, { class: 'linkish advanced' })
          : null,
        link('Duplicate', 'app-duplicate-profile', () => mutate((s) => duplicateProfile(s, p.id)), { title: p.builtin ? 'Make an editable copy of this built-in profile' : 'Copy this profile' }),
        link('Export', 'app-export-profile', () => download(`${fileSafe(p.name)}.app-profile.json`, exportAppProfiles([p]), 'application/json')),
        !p.builtin
          ? link(
              'Delete',
              'app-delete-profile',
              () => {
                if (!confirm(`Delete the profile "${p.name}" from this browser? Export it first if you want to keep a copy.`)) return;
                profileLibrary.remove(p.id);
                mutate((s) => deleteProfile(s, p.id));
              },
              { class: 'linkish danger' },
            )
          : null,
      ),
    );
  }

  // Devices -------------------------------------------------------------------------------------
  const devicesBox = h('div', { class: 'devices', 'data-testid': 'app-devices' });
  const deviceNote = h('div', { class: 'device-note', 'data-testid': 'app-device-note', 'aria-live': 'polite' });
  const setDevices = (fn: (d: Devices) => void) =>
    mutate((s) => {
      fn(s.devices);
      pruneDetached(s);
    });
  function renderDevices(sel: ApplicationsSelection, r: SelectionResult): void {
    const phoneName = uid('ph');
    const radio = (value: Devices['phone'], label: string) => {
      const id = uid('ph');
      return h(
        'label',
        { class: 'device-choice', for: id },
        h('input', { type: 'radio', id, name: phoneName, value, 'data-device': `phone-${value}`, checked: sel.devices.phone === value, onchange: () => setDevices((d) => (d.phone = value)) }),
        label,
      );
    };
    const check = (key: 'ipad' | 'extraIphone' | 'androidTablet', label: string) => {
      const id = uid('dv');
      return h(
        'label',
        { class: 'device-choice', for: id },
        h('input', { type: 'checkbox', id, 'data-device': key, checked: sel.devices[key], onchange: (e: Event) => setDevices((d) => (d[key] = (e.target as HTMLInputElement).checked)) }),
        label,
      );
    };
    patchChildren(devicesBox, [
      h('fieldset', { class: 'device-group' }, h('legend', {}, 'What type of smartphone does the customer use?'), h('div', { class: 'device-row' }, radio('iphone', 'iPhone'), radio('android', 'Android'), radio('none', 'Other / none'))),
      h('fieldset', { class: 'device-group' }, h('legend', {}, 'Other devices (tick all that apply)'), h('div', { class: 'device-row' }, check('ipad', 'iPad'), check('extraIphone', 'Additional iPhone'), check('androidTablet', 'Android tablet'))),
    ]);
    const eff = effectiveDevices(sel);
    const savedOnly = JSON.stringify(eff) !== JSON.stringify(sel.devices);
    patch(deviceNote, (into) => {
      if (r.deviceProfiles.length === 0) into.append(h('p', { class: 'desc' }, 'No device recommendations. Only the kind of device is recorded: no names, serial numbers or accounts.'));
      for (const id of r.deviceProfiles) {
        const p = BUILTIN_PROFILES.find((x) => x.id === id);
        if (!p) continue;
        into.append(h('p', { class: 'info', 'data-device-profile': id }, icon('info'), h('span', {}, h('strong', {}, `${p.name}: `), p.description)));
      }
      if (savedOnly) into.append(h('p', { class: 'desc' }, 'A ticked saved profile adds its own device answers too.'));
    });
  }

  // Applications list ---------------------------------------------------------------------------
  const searchId = uid('as');
  const catId = uid('ac');
  const search = h('input', {
    type: 'search',
    id: searchId,
    placeholder: 'Search by name, purpose or identifier',
    'data-testid': 'app-search',
    autocomplete: 'off',
    oninput: () => {
      query = search.value;
      if (query && filter === 'relevant') filter = 'all';
      renderList();
    },
  });
  const catSelect = h(
    'select',
    {
      id: catId,
      'data-testid': 'app-category',
      onchange: () => {
        category = catSelect.value as CatalogCategory | '';
        if (category && filter === 'relevant') filter = 'all';
        renderList();
      },
    },
    h('option', { value: '' }, `All categories (${CATALOG.length})`),
    ...(Object.entries(CATALOG_CATEGORIES) as [CatalogCategory, string][]).map(([v, l]) => h('option', { value: v }, `${l} (${CATALOG.filter((e) => e.category === v).length})`)),
  );
  const filterChips = h('div', { class: 'chips', role: 'group', 'aria-label': 'Show', 'data-testid': 'app-filter' });
  const viewBox = h('div', { class: 'view-box' });
  const renderViewSwitch = () => {
    patchChildren(viewBox, [
      viewSwitcher(view, (v) => {
        view = v;
        saveCatalogView(v);
        renderViewSwitch();
        renderList();
        viewBox.querySelector<HTMLElement>(`[data-view-mode="${v}"]`)?.focus({ preventScroll: true });
      }),
    ]);
  };
  const list = h('div', { class: 'app-list', 'data-testid': 'app-catalog' });

  const manualId = h('input', { type: 'text', placeholder: 'Publisher.Package or 9XXXXXXXXXXX', 'aria-label': 'Package identifier', 'data-testid': 'app-manual-id', autocomplete: 'off', spellcheck: 'false' });
  const manualSource = h('select', { 'aria-label': 'Source', 'data-testid': 'app-manual-source' }, h('option', { value: 'winget' }, 'winget'), h('option', { value: 'msstore' }, 'msstore'));
  const manualName = h('input', { type: 'text', placeholder: 'Display name (optional)', 'aria-label': 'Display name', 'data-testid': 'app-manual-name', autocomplete: 'off' });
  const manualVersion = h('input', { type: 'text', placeholder: 'Version (empty = latest)', 'aria-label': 'Version', 'data-testid': 'app-manual-version', autocomplete: 'off', spellcheck: 'false' });
  const manualScope = h('select', { 'aria-label': 'Scope' }, h('option', { value: '' }, 'Default scope'), h('option', { value: 'machine' }, 'Machine'), h('option', { value: 'user' }, 'User'));
  const manualMsg = h('div', { class: 'issues', 'data-testid': 'app-manual-message' });
  const manualAdd = h(
    'details',
    { class: 'manual-add', 'data-testid': 'app-custom-id' },
    h('summary', {}, icon('hash'), 'Add a package by WinGet or Store ID'),
    h('p', { class: 'desc' }, 'For software that is not in the catalog. The identifier must be exact (check it with "winget show --id <id> --exact"). It is treated as data only: it is validated here and again on the device, and never becomes part of a script.'),
    h('div', { class: 'manual-grid' }, manualId, manualSource, manualName, manualVersion, manualScope),
    h(
      'button',
      {
        type: 'button',
        class: 'btn',
        'data-action': 'app-add-manual',
        onclick: () => {
          clear(manualMsg);
          const source = manualSource.value;
          const id = normalizeId(source, manualId.value);
          const version = manualVersion.value.trim();
          const ok = source === 'msstore' ? MSSTORE_ID.test(id) : WINGET_ID.test(id);
          if (!ok) {
            manualMsg.append(h('p', { class: 'error' }, source === 'msstore' ? 'Not a Microsoft Store product ID (12 or 14 characters, such as 9NBLGGH4NNS1).' : 'Not a valid winget identifier. Use the exact PackageIdentifier, such as Git.Git (letters, digits, . _ + -).'));
            return;
          }
          if (version && !VERSION.test(version)) {
            manualMsg.append(h('p', { class: 'error' }, 'The version contains characters that are not allowed.'));
            return;
          }
          const ref: PackageRef = { packageIdentifier: id, source, displayName: manualName.value.trim().slice(0, 200) || id, version, scope: manualScope.value as PackageRef['scope'] };
          let added = false;
          mutate((sel) => (added = addPackage(sel, ref)));
          manualMsg.append(h('p', { class: added ? 'ok' : 'warning' }, added ? `Added ${ref.displayName}.` : `${ref.displayName} is already selected.`));
          if (added) manualId.value = manualName.value = manualVersion.value = '';
        },
      },
      icon('plus'),
      'Add package',
    ),
    manualMsg,
  );

  // Plan ----------------------------------------------------------------------------------------
  const count = h('span', { class: 'count', 'data-testid': 'app-count' });
  const warnings = h('div', { class: 'app-warnings', 'data-testid': 'app-warnings' });
  const order = h('ol', { class: 'app-order', 'data-testid': 'app-order' });
  const manualBox = h('div', { class: 'app-manual', 'data-testid': 'app-manual-list' });
  const removedBox = h('div', { class: 'app-removed', 'data-testid': 'app-removed' });
  const planText = h('pre', { class: 'preview small', 'data-testid': 'app-plan' });

  const body = h(
    'div',
    { class: 'apps' },
    status,
    toolbar,
    !show.profiles ? null : h(
      'div',
      { class: 'apps-block', id: 'app-profiles' },
      h(
        'div',
        { class: 'block-head' },
        h('h4', {}, icon('layers'), 'Profiles'),
        h('p', { class: 'desc' }, 'Tick one or more profiles; their apps are combined and each is installed once. Built-in profiles are fixed templates: your ticks and unticks below change only this deployment, and "Duplicate" makes an editable copy.'),
      ),
      builtinGrid,
      h('div', { class: 'block-head saved-head' }, h('h4', {}, icon('folder'), 'Saved profiles'), storageNote),
      customGrid,
    ),
    !show.devices ? null : h(
      'div',
      { class: 'apps-block', id: 'app-devices' },
      h('div', { class: 'block-head' }, h('h4', {}, icon('laptop'), 'Mobile devices & ecosystem'), h('p', { class: 'desc' }, 'Answer for every device the customer owns; Apple and Android can be combined.')),
      devicesBox,
      deviceNote,
    ),
    h(
      'div',
      { class: `apps-split${show.plan ? '' : ' no-plan'}` },
      h(
        'section',
        { class: 'panel catalog-panel', 'aria-label': 'Applications' },
        h('div', { class: 'panel-head' }, h('h4', {}, icon('package'), 'Applications'), h('span', { class: 'panel-meta' }, `${CATALOG.length} in the catalog · checked ${CATALOG_UPDATED}`)),
        h(
          'div',
          { class: 'catalog-controls' },
          h('label', { for: searchId, class: 'sr-only' }, 'Search the catalog'),
          h('div', { class: 'search-box' }, icon('search'), search),
          h('div', { class: 'inline-label' }, h('label', { for: catId }, 'Category'), catSelect),
          viewBox,
        ),
        filterChips,
        list,
        manualAdd,
      ),
      !show.plan ? null : h(
        'section',
        { class: 'panel selected-panel', 'aria-label': 'Installation plan' },
        h('div', { class: 'panel-head' }, h('h4', {}, icon('check'), 'Installation plan'), count),
        warnings,
        order,
        manualBox,
        removedBox,
        h('details', { class: 'advanced' }, h('summary', {}, 'Full plan with every command (applications-plan.txt)'), planText),
      ),
    ),
    !show.troubleshooting ? null : h(
      'details',
      { class: 'advanced troubleshooting' },
      h('summary', {}, icon('info'), 'Troubleshooting'),
      h(
        'ul',
        {},
        h('li', {}, 'On the PC, run ', h('code', {}, 'ApplicationEngine.ps1 -Mode Plan'), " (read-only) to see WinGet's state and what would be installed."),
        h('li', {}, h('code', {}, 'WinGetBootstrap.ps1 -Mode Check'), ' reports whether WinGet works for the signed-in user. WinGet does not work as SYSTEM.'),
        h('li', {}, 'Logs: ', h('code', {}, 'C:\\ProgramData\\WindowsDeploymentBuilder\\Applications\\logs'), ' (engine.log, and the WinGet output per package under packages\\).'),
        h('li', {}, 'Results: ', h('code', {}, 'Applications\\result.json'), ' and ', h('code', {}, 'follow-up.txt'), ' list every app with its status: Succeeded, AlreadyInstalled, SkippedByUser, RequiresInteraction (manual action), Failed, Unavailable.'),
      ),
    ),
  );

  let current: ApplicationsSelection | undefined;
  let result: SelectionResult | undefined;

  /** Ticks or unticks one app. Unticking a profile default records a removal; the profile stays unchanged. */
  const setApp = (e: CatalogEntry, on: boolean) => {
    const ref = catalogRef(e);
    if (!ref) return;
    mutate((s) => (on ? addPackage(s, ref) : removePackage(s, packageKey(ref))));
  };

  function itemModel(e: CatalogEntry, sel: ApplicationsSelection, r: SelectionResult): ItemModel & { planned: boolean; removed: boolean; stateKind: string } {
    const key = entryKey(e);
    const planned = r.packages.find((p) => p.key === key);
    const removed = r.removed.find((p) => p.key === key);
    const rec = r.recommended.find((p) => p.key === key);
    const unresolved = !key;
    const rivals = e.conflictGroup ? r.packages.filter((p) => p.key !== key && p.catalog?.conflictGroup === e.conflictGroup) : [];
    const blocked = !planned && rivals.length > 0;
    const reason = planned
      ? explainOrigin(sel, planned, r)
      : removed
        ? explainOrigin(sel, removed, r)
        : rec
          ? `Recommended by ${rec.origins.map((o) => profileName(sel, o)).join(', ')}`
          : unresolved
            ? 'Unavailable: no verified package'
            : 'Available';
    return {
      entry: e,
      state: planned ? 'selected' : removed ? 'deselected' : rec ? 'recommended' : unresolved ? 'unavailable' : 'available',
      reason,
      checked: !!planned,
      disabled: unresolved || blocked,
      blockedText: blocked ? `Cannot be combined with ${rivals.map((p) => p.displayName).join(', ')} (${CONFLICT_GROUPS[e.conflictGroup!]}: keep only one). Untick it first.` : '',
      method: methodOf(e),
      manual: isManual(e),
      planned: !!planned,
      removed: !!removed,
      stateKind: planned ? 'ok' : removed ? 'warn' : rec ? 'info' : 'muted',
    };
  }

  function appRow(e: CatalogEntry, sel: ApplicationsSelection, r: SelectionResult): HTMLElement {
    const m = itemModel(e, sel, r);
    const planned = m.planned;
    const removed = m.removed;
    const method = m.method;
    const unresolved = m.state === 'unavailable';
    const id = uid('app');
    const state = m.reason;
    const stateKind = m.stateKind;
    const conflictText = m.blockedText;
    return h(
      'div',
      { class: `app-item${planned ? ' on' : ''}${removed ? ' removed' : ''}${unresolved ? ' unresolved' : ''}`, 'data-app': e.id, 'data-state': m.state === 'unavailable' ? 'available' : m.state },
      h('input', {
        type: 'checkbox',
        id,
        checked: m.checked,
        disabled: m.disabled,
        'aria-describedby': `${id}-d`,
        onchange: (ev: Event) => setApp(e, (ev.target as HTMLInputElement).checked),
      }),
      appLogo(e.id, e.displayName, e.category, 'sm'),
      h(
        'div',
        { class: 'app-main' },
        h(
          'div',
          { class: 'row-title' },
          h('label', { for: id }, h('strong', {}, e.displayName)),
          badge(state, stateKind),
          methodBadge(method),
          e.conflictGroup ? badge(CONFLICT_GROUPS[e.conflictGroup], 'warn', 'Only one real-time antivirus can be selected.') : null,
          e.accountSignIn ? badge('sign-in after install', '', 'Installation is unattended; the customer signs in later. No account is configured.') : null,
          e.interaction === 'mayPrompt' ? badge('may prompt', 'warn', 'The installer is known to prompt or bundle offers in some versions.') : null,
          e.reboot === 'mayRequire' ? badge('may restart') : null,
          h('span', { class: 'badge muted cat-badge' }, CATALOG_CATEGORIES[e.category]),
        ),
        h('span', { class: 'choice-desc', id: `${id}-d` }, e.description, conflictText ? ` ${conflictText}` : ''),
        e.selectionWarning && planned ? h('span', { class: 'app-warning' }, icon('alert'), e.selectionWarning) : null,
        isManual(e) && e.manual ? h('span', { class: 'choice-desc' }, `Manual follow-up: ${e.manual.instructions}`) : null,
        h(
          'span',
          { class: 'ids advanced' },
          h('code', {}, isManual(e) ? 'no package (manual)' : unresolved ? 'No identifier' : `${e.source}: ${e.packageIdentifier}`),
          ` · ${e.installerType}`,
          e.architectures.length ? ` · ${e.architectures.join('/')}` : '',
          ` · ${e.license}`,
          e.notes ? h('span', {}, ` · ${e.notes}`) : null,
          e.website || e.manual?.url ? h('span', {}, ' · ', h('a', { href: (e.manual?.url ?? e.website)!, rel: 'noopener noreferrer', target: '_blank' }, isManual(e) ? 'official download' : 'website')) : null,
        ),
      ),
    );
  }

  function customRow(x: PlannedPackage, sel: ApplicationsSelection, r: SelectionResult, removed: boolean): HTMLElement {
    const id = uid('app');
    return h(
      'div',
      { class: `app-item${removed ? ' removed' : ' on'}${x.resolution === 'unresolved' ? ' unresolved' : ''}`, 'data-package': x.key, 'data-state': removed ? 'deselected' : 'selected' },
      h('input', { type: 'checkbox', id, checked: !removed, disabled: x.resolution === 'unresolved' && removed, onchange: (ev: Event) => mutate((s) => ((ev.target as HTMLInputElement).checked ? restorePackage(s, x.key) : removePackage(s, x.key))) }),
      appLogo(undefined, x.displayName, undefined, 'sm'),
      h(
        'div',
        { class: 'app-main' },
        h('div', { class: 'row-title' }, h('label', { for: id }, h('strong', {}, x.displayName)), badge(explainOrigin(sel, removed ? { ...x, removedBy: x.removedBy ?? 'user' } : x, r), removed ? 'warn' : 'ok'), methodBadge(x.method), x.resolution === 'unresolved' ? badge('unresolved', 'err', x.reason) : badge('not in catalog', 'warn', 'Availability is checked on the device before installing.')),
        h('span', { class: 'ids' }, h('code', {}, `${x.ref.source}: ${x.ref.packageIdentifier}`), x.ref.version ? ` · version ${x.ref.version}` : '', x.ref.scope ? ` · ${x.ref.scope} scope` : '', x.excludedFromCatalog ? ` · not in the curated catalog: ${x.excludedFromCatalog.reason}` : ''),
      ),
    );
  }

  function renderList(): void {
    const sel = current!;
    const r = result!;
    const chips: HTMLElement[] = [];
    for (const [value, label] of FILTERS) {
      chips.push(
        h(
          'button',
          {
            type: 'button',
            class: 'chip',
            'data-filter': value,
            'aria-pressed': String(value === filter),
            onclick: () => {
              filter = value;
              renderList();
            },
          },
          label,
        ),
      );
    }
    patchChildren(filterChips, chips);
    list.dataset.view = view;
    // Built detached, then patched into the list: the tiles already shown are updated in place, never
    // re-created (re-creating them removed the browser's scroll anchor and made the page jump).
    patch(list, (out) => fillList(out, sel, r));
  }

  function fillList(list: HTMLElement, sel: ApplicationsSelection, r: SelectionResult): void {
    if (filter === 'excluded') {
      list.append(h('p', { class: 'desc' }, 'Deliberately left out of the curated catalog. If a customer really needs one, add it with its exact WinGet ID below; it is then installed like any other package.'));
      for (const x of CATALOG_EXCLUDED) list.append(h('div', { class: 'app-item excluded', 'data-excluded': x.name }, avatar(x.name), h('div', { class: 'app-main' }, h('div', { class: 'row-title' }, h('strong', {}, x.name), badge('not offered', 'muted')), h('span', { class: 'choice-desc' }, x.reason))));
      return;
    }
    const keys = {
      selected: new Set(r.packages.map((p) => p.key)),
      removed: new Set(r.removed.map((p) => p.key)),
      recommended: new Set(r.recommended.map((p) => p.key)),
      // Defaults of the active profiles, whether still ticked or unticked by you.
      defaults: new Set([...r.packages, ...r.removed].filter((p) => p.origins.some((o) => o !== ADDED && o !== REQUIRED)).map((p) => p.key)),
    };
    const show = (e: CatalogEntry) => {
      const k = entryKey(e);
      switch (filter) {
        case 'relevant':
          return keys.selected.has(k) || keys.removed.has(k) || keys.recommended.has(k);
        case 'selected':
          return keys.selected.has(k);
        case 'defaults':
          return keys.defaults.has(k);
        case 'recommended':
          return keys.recommended.has(k);
        case 'deselected':
          return keys.removed.has(k);
        case 'manual':
          return isManual(e) || !k;
        default:
          return true;
      }
    };
    const entries = searchCatalog(query, category).filter(show);
    const groups = new Map<CatalogCategory, CatalogEntry[]>();
    for (const e of entries) groups.set(e.category, [...(groups.get(e.category) ?? []), e]);
    for (const [cat, items] of [...groups].sort((a, b) => Object.keys(CATALOG_CATEGORIES).indexOf(a[0]) - Object.keys(CATALOG_CATEGORIES).indexOf(b[0]))) {
      const drawn = view === 'detailed' ? items.map((e) => appRow(e, sel, r)) : items.map((e) => renderTile(view as Exclude<CatalogView, 'detailed'>, itemModel(e, sel, r), (on) => setApp(e, on)));
      list.append(h('h5', { class: 'app-group', 'data-key': `group-${cat}` }, CATALOG_CATEGORIES[cat], h('span', { class: 'chip-count' }, String(items.length))), h('div', { class: `app-items view-${view}`, 'data-key': `items-${cat}` }, drawn));
    }
    // Packages added by custom ID (not in the catalog).
    if (!query && !category && filter !== 'recommended' && filter !== 'manual' && filter !== 'defaults') {
      const custom = [...(filter === 'deselected' ? [] : r.packages.filter((p) => !p.catalog)), ...(filter === 'selected' ? [] : r.removed.filter((p) => !p.catalog))];
      if (custom.length) list.append(h('h5', { class: 'app-group', 'data-key': 'group-custom' }, 'Added by ID', h('span', { class: 'chip-count' }, String(custom.length))), ...custom.map((x) => customRow(x, sel, r, !!x.removedBy)));
    }
    if (!list.childElementCount) {
      list.append(h('div', { class: 'empty-state' }, icon('package'), h('p', { class: 'empty' }, filter === 'relevant' ? 'Nothing selected or recommended yet. Tick a profile, or choose "All apps".' : 'No application matches. Try "All apps", another category, or add a package by ID below.')));
    }
  }

  function renderPlan(sel: ApplicationsSelection, r: SelectionResult): void {
    const queue = installable(r);
    const manual = r.packages.filter((p) => p.resolution === 'manual');
    const unresolved = r.packages.filter((p) => p.resolution === 'unresolved');
    count.textContent = `${queue.length} to install${manual.length ? `, ${manual.length} manual` : ''}${unresolved.length ? `, ${unresolved.length} unresolved` : ''}`;

    const stat = (n: number, label: string, tone = '', testid = '') => h('div', { class: `stat${tone ? ` ${tone}` : ''}`, 'data-testid': testid || undefined }, h('strong', {}, String(n)), h('span', {}, label));
    const deps = r.packages.filter((x) => x.origins.length === 1 && x.origins[0] === REQUIRED).length;
    const chosen = r.packages.length - deps;
    const warningCount = r.groupConflicts.length + r.conflicts.length + r.notices.filter((n) => n.kind !== 'info').length + unresolved.length;
    patchChildren(stats, [
      stat(CATALOG.length, 'in the catalog', '', 'app-catalog-size'),
      stat(chosen, deps ? `selected (+${deps} required)` : 'selected', chosen ? 'ok' : '', 'app-selected'),
      stat(queue.length, 'to install', queue.length ? 'ok' : '', 'app-total'),
      stat(manual.length, 'manual follow-up', manual.length ? 'warn' : '', 'app-manual-count'),
      stat(warningCount, warningCount === 1 ? 'warning or conflict' : 'warnings or conflicts', r.groupConflicts.length ? 'err' : warningCount ? 'warn' : '', 'app-warning-count'),
      stat(r.removed.length, 'unticked by you'),
      stat(r.activeProfiles.length, `profile${r.activeProfiles.length === 1 ? '' : 's'} active`),
    ]);

    patch(warnings, (into) => {
      for (const g of r.groupConflicts) into.append(h('p', { class: 'error', 'data-kind': 'conflict-group' }, g.message));
      for (const x of unresolved) into.append(h('p', { class: 'error', 'data-kind': 'unresolved' }, `${x.displayName}: ${x.reason}`));
      for (const n of r.notices) into.append(h('p', { class: n.kind === 'info' ? 'info' : n.kind, 'data-kind': 'notice' }, n.message));
      for (const c of r.conflicts) into.append(h('p', { class: 'warning', 'data-kind': 'conflict' }, c.message));
      for (const id of r.missingProfiles) into.append(h('p', { class: 'error', 'data-kind': 'missing' }, `Selected profile "${id}" does not exist.`));
    });

    const rows: HTMLElement[] = [];
    if (queue.length === 0) rows.push(h('li', { class: 'empty' }, 'Nothing to install.'));
    for (const x of queue) {
      rows.push(
        h(
          'li',
          { 'data-package': x.key },
          h('strong', {}, x.displayName),
          ' ',
          methodBadge(x.method),
          x.interaction === 'required' ? ' (needs interaction: listed for follow-up, not attempted)' : '',
          x.origins.includes(REQUIRED) ? h('span', { class: 'choice-desc' }, ` · ${explainOrigin(sel, x, r)}`) : null,
          h('code', { class: 'cmd advanced' }, `winget ${wingetArguments('install', x.ref).join(' ')}`),
        ),
      );
    }
    patchChildren(order, rows);

    clear(manualBox);
    if (manual.length) {
      manualBox.append(
        h('h5', {}, 'Manual follow-up (never reported as installed)'),
        h('ul', { class: 'ids-list' }, manual.map((x) => h('li', { 'data-manual': x.key }, h('span', {}, x.displayName, ': ', x.catalog?.manual?.instructions ?? ''), x.catalog?.manual?.url ? h('a', { href: x.catalog.manual.url, rel: 'noopener noreferrer', target: '_blank' }, 'download') : null))),
      );
    }

    clear(removedBox);
    if (r.removed.length) {
      removedBox.append(
        h('h5', {}, 'Unticked (recorded as SkippedByUser; profiles unchanged)'),
        h(
          'ul',
          { class: 'ids-list' },
          r.removed.map((x) => h('li', { 'data-removed': x.key }, h('span', {}, x.displayName), x.removedBy === 'user' ? h('button', { type: 'button', class: 'linkish', 'data-action': 'app-restore', onclick: () => mutate((s) => restorePackage(s, x.key)) }, 'tick again') : h('span', { class: 'choice-desc' }, `left out by "${profileName(sel, x.removedBy ?? '')}"`))),
        ),
      );
    }
    planText.textContent = planPreview(store.get(), r);
  }

  function render(selection: ApplicationsSelection): void {
    // Keep keyboard focus on the same control across re-renders.
    const active = document.activeElement as HTMLElement | null;
    const focusApp = active?.closest<HTMLElement>('[data-app]')?.dataset.app;
    const focusProfile = active?.closest<HTMLElement>('[data-profile]')?.dataset.profile;
    const focusDevice = active?.getAttribute('data-device');
    current = selection;
    result = resolveSelection(selection);
    view = loadCatalogView();
    renderViewSwitch();
    const r = result;

    patchChildren(builtinGrid, BUILTIN_PROFILES.filter((x) => isSelectableProfile(x.id)).map((p) => profileCard(p, selection, r)));
    patchChildren(customGrid, selection.profiles.length ? selection.profiles.map((p) => profileCard(p, selection, r)) : [h('p', { class: 'empty' }, 'No saved profiles yet. Set up the selection, then "Save as new profile…".')]);
    storageNote.textContent = profileLibrary.available
      ? 'Saved profiles are kept in this browser only (local storage). That is not a backup: clearing site data removes them, and other browsers or computers do not see them. Use Export for a portable copy.'
      : 'This browser does not allow local storage here, so saved profiles last only until the page is closed. Use Export to keep them.';

    if (show.devices) renderDevices(selection, r);
    renderPlan(selection, r);
    renderList();

    const target = focusApp
      ? body.querySelector<HTMLElement>(`[data-app="${CSS.escape(focusApp)}"] input`)
      : focusProfile
        ? body.querySelector<HTMLElement>(`[data-profile="${CSS.escape(focusProfile)}"] input`)
        : focusDevice
          ? body.querySelector<HTMLElement>(`[data-device="${CSS.escape(focusDevice)}"]`)
          : null;
    target?.focus({ preventScroll: true });
  }

  const el = customShell(def, body);
  return { el, sync: (p) => render(p.applications.selection) };
}
