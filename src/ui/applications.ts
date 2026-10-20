import type { AdditionalItem, AppProfile, ApplicationsSelection, PackageRef } from '../engine/schema/applications';
import { CATALOG, CATALOG_CATEGORIES, CATALOG_UPDATED, searchCatalog, type CatalogCategory, type CatalogEntry } from '../engine/applications/catalog';
import { MSSTORE_ID, VERSION, WINGET_ID, normalizeId, packageKey } from '../engine/applications/ids';
import { ADDED, resolveSelection, type PlannedPackage } from '../engine/applications/selection';
import {
  addPackage,
  createProfile,
  deleteProfile,
  duplicateProfile,
  exportAppProfiles,
  importAppProfiles,
  removeFromProfile,
  removePackage,
  renameProfile,
  restorePackage,
  saveSelectionToProfile,
  toggleProfile,
} from '../engine/applications/profiles';
import { exportWinGetJson } from '../engine/applications/winget-json';
import { planPreview, wingetArguments } from '../engine/applications';
import { clear, download, h, uid } from './dom';
import { customShell, type CustomRenderer } from './form';

const newId = () => (globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random()}`).slice(0, 36);
const fileSafe = (s: string) => s.replace(/[^\w.-]+/g, '-').replace(/^-+|-+$/g, '') || 'profile';

function badge(text: string, kind = '', title?: string): HTMLElement {
  return h('span', { class: `badge${kind ? ` ${kind}` : ''}`, title }, text);
}

function refFromCatalog(e: CatalogEntry): PackageRef {
  return { packageIdentifier: e.packageIdentifier!, source: e.source, displayName: e.displayName, version: '', scope: '' };
}

function packageBadges(x: PlannedPackage): HTMLElement[] {
  const out: HTMLElement[] = [];
  if (x.resolution === 'verified') out.push(badge('verified ID', 'ok', `Identifier checked with winget show on ${x.catalog?.validation.checkedAt}`));
  else if (x.resolution === 'unverified') out.push(badge('not in catalog', 'warn', 'Well-formed identifier; availability is checked on the device before installing.'));
  else out.push(badge('unresolved', 'err', x.reason));
  if (x.ref.source === 'msstore') out.push(badge('Microsoft Store'));
  if (x.interaction === 'required') out.push(badge('needs interaction', 'warn'));
  if (x.interaction === 'mayPrompt') out.push(badge('may prompt', 'warn'));
  if (x.accountSignIn) out.push(badge('sign-in after install'));
  if (x.reboot === 'mayRequire') out.push(badge('may restart'));
  if (x.origins.length > 1) out.push(badge(`in ${x.origins.length} sources`, '', 'Selected through more than one profile or addition; installed once.'));
  return out;
}

export const applicationsEditor: CustomRenderer = (def, store) => {
  // Local view state (never stored in the profile).
  let query = '';
  let category: CatalogCategory | '' = '';
  let target = ADDED;

  const mutate = (fn: (sel: ApplicationsSelection) => void) => store.update((p) => fn(p.applications.selection), true);
  const status = h('div', { class: 'app-status', 'data-testid': 'app-import-status', 'aria-live': 'polite' });
  const say = (kind: 'info' | 'error', title: string, lines: string[] = []) => {
    clear(status);
    status.className = `app-status notice ${kind}`;
    status.append(h('strong', {}, title));
    if (lines.length) status.append(h('ul', {}, lines.slice(0, 12).map((l) => h('li', {}, l)), lines.length > 12 ? h('li', {}, `… and ${lines.length - 12} more`) : null));
    status.append(h('button', { type: 'button', class: 'icon', 'aria-label': 'Dismiss', onclick: () => clear(status) }, '✕'));
  };

  // Profiles --------------------------------------------------------------------------------------
  const profileGrid = h('div', { class: 'profile-grid', 'data-testid': 'app-profiles' });
  const fileInput = h('input', {
    type: 'file',
    accept: '.json,application/json',
    class: 'sr-only',
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
        'Added to your selection; nothing you had selected was changed or removed. Untick the profile to leave it out.',
        ...r.warnings,
      ]);
    },
  });
  const profileActions = h(
    'div',
    { class: 'actions' },
    h(
      'button',
      {
        type: 'button',
        class: 'btn',
        'data-action': 'app-new-profile',
        onclick: () => {
          const name = prompt('Name of the new profile:', 'My applications');
          if (!name?.trim()) return;
          mutate((sel) => {
            const p = createProfile(sel, name);
            toggleProfile(sel, p.id, true);
            target = p.id;
          });
        },
      },
      'New profile…',
    ),
    h('button', { type: 'button', class: 'btn', 'data-action': 'app-import', onclick: () => fileInput.click() }, 'Import WinGet or profile JSON…'),
    fileInput,
    h(
      'button',
      {
        type: 'button',
        class: 'btn',
        'data-action': 'app-export-winget',
        onclick: () => download('winget-packages.json', exportWinGetJson(resolveSelection(store.get().applications.selection).packages.map((x) => x.ref)), 'application/json'),
      },
      'Export selection as WinGet JSON',
    ),
    h(
      'button',
      {
        type: 'button',
        class: 'btn advanced',
        'data-action': 'app-export-profiles',
        onclick: () => download('application-profiles.json', exportAppProfiles(store.get().applications.selection.profiles), 'application/json'),
      },
      'Export all profiles',
    ),
  );

  function profileCard(p: AppProfile, sel: ApplicationsSelection, counts: Map<string, number>): HTMLElement {
    const id = uid('ap');
    const checked = sel.selectedProfiles.includes(p.id);
    const n = counts.get(p.id) ?? 0;
    const btn = (label: string, action: string, onclick: () => void, extra: Record<string, string | boolean> = {}) =>
      h('button', { type: 'button', class: 'linkish', 'data-action': action, onclick, ...extra }, label);
    return h(
      'div',
      { class: `profile-card${checked ? ' on' : ''}`, 'data-profile': p.id },
      h(
        'div',
        { class: 'check' },
        h('input', { type: 'checkbox', id, name: `applications.profile.${p.id}`, checked, onchange: (e: Event) => mutate((s) => toggleProfile(s, p.id, (e.target as HTMLInputElement).checked)) }),
        h('label', { for: id }, h('strong', {}, p.name), h('span', { class: 'choice-desc' }, n === 0 ? 'Empty' : `${n} package${n === 1 ? '' : 's'}`)),
      ),
      p.description ? h('p', { class: 'choice-desc' }, p.description) : null,
      h(
        'div',
        { class: 'card-actions advanced' },
        btn('Save selection here', 'app-save-to-profile', () => {
          if (confirm(`Replace the packages of "${p.name}" with the ${resolveSelection(sel).packages.length} currently selected application(s)?`)) mutate((s) => saveSelectionToProfile(s, p.id));
        }),
        btn('Duplicate', 'app-duplicate-profile', () => mutate((s) => duplicateProfile(s, p.id))),
        p.builtin
          ? null
          : btn('Rename', 'app-rename-profile', () => {
              const name = prompt('New name:', p.name);
              if (name?.trim()) mutate((s) => renameProfile(s, p.id, name));
            }),
        p.builtin ? null : btn('Delete', 'app-delete-profile', () => confirm(`Delete the profile "${p.name}"?`) && mutate((s) => deleteProfile(s, p.id)), { class: 'linkish danger' }),
        btn('Export', 'app-export-profile', () => download(`${fileSafe(p.name)}.app-profile.json`, exportAppProfiles([p]), 'application/json')),
      ),
      p.packages.length
        ? h(
            'details',
            { class: 'advanced' },
            h('summary', {}, 'Contents'),
            h(
              'ul',
              { class: 'ids-list' },
              p.packages.map((r) =>
                h(
                  'li',
                  {},
                  `${r.displayName || r.packageIdentifier} `,
                  h('code', {}, `${r.source}:${r.packageIdentifier}`),
                  ' ',
                  h('button', { type: 'button', class: 'linkish danger', 'aria-label': `Remove ${r.displayName} from ${p.name}`, onclick: () => mutate((s) => removeFromProfile(s, p.id, packageKey(r))) }, 'remove'),
                ),
              ),
            ),
          )
        : null,
    );
  }

  // Selected applications -------------------------------------------------------------------------
  const count = h('span', { class: 'count', 'data-testid': 'app-count' });
  const warnings = h('div', { class: 'app-warnings', 'data-testid': 'app-warnings' });
  const selected = h('div', { class: 'app-rows', 'data-testid': 'app-selected' });
  const removedBox = h('div', { class: 'app-removed' });

  // Catalog ---------------------------------------------------------------------------------------
  const searchId = uid('as');
  const catId = uid('ac');
  const targetId = uid('at');
  const search = h('input', {
    type: 'search',
    id: searchId,
    placeholder: 'Search by name, purpose or identifier',
    'data-testid': 'app-search',
    autocomplete: 'off',
    oninput: () => {
      query = search.value;
      renderCatalog();
    },
  });
  const categorySelect = h(
    'select',
    {
      id: catId,
      'data-testid': 'app-category',
      onchange: () => {
        category = categorySelect.value as CatalogCategory | '';
        renderCatalog();
      },
    },
    h('option', { value: '' }, 'All categories'),
    (Object.entries(CATALOG_CATEGORIES) as [CatalogCategory, string][]).map(([k, v]) => h('option', { value: k }, v)),
  );
  const targetSelect = h('select', {
    id: targetId,
    'data-testid': 'app-target',
    onchange: () => {
      target = targetSelect.value;
      renderCatalog();
    },
  });
  const catalogList = h('ul', { class: 'catalog-list', 'data-testid': 'app-catalog' });

  const manualId = h('input', { type: 'text', placeholder: 'Publisher.Package or 9XXXXXXXXXXX', 'aria-label': 'Package identifier', 'data-testid': 'app-manual-id', autocomplete: 'off', spellcheck: 'false' });
  const manualSource = h('select', { 'aria-label': 'Source', 'data-testid': 'app-manual-source' }, h('option', { value: 'winget' }, 'winget'), h('option', { value: 'msstore' }, 'msstore'));
  const manualName = h('input', { type: 'text', placeholder: 'Display name (optional)', 'aria-label': 'Display name', 'data-testid': 'app-manual-name', autocomplete: 'off' });
  const manualVersion = h('input', { type: 'text', placeholder: 'Version (empty = latest)', 'aria-label': 'Version', 'data-testid': 'app-manual-version', autocomplete: 'off', spellcheck: 'false' });
  const manualScope = h('select', { 'aria-label': 'Scope' }, h('option', { value: '' }, 'Default scope'), h('option', { value: 'machine' }, 'Machine'), h('option', { value: 'user' }, 'User'));
  const manualMsg = h('p', { class: 'issues', 'data-testid': 'app-manual-message' });
  const manual = h(
    'details',
    { class: 'advanced manual-add' },
    h('summary', {}, 'Add by package identifier'),
    h('p', { class: 'desc' }, 'For packages that are not in the catalog. The identifier must be exact (check it with "winget show --id <id> --exact"); it is validated again on the device before installing.'),
    h('div', { class: 'app-controls' }, manualId, manualSource, manualName, manualVersion, manualScope),
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
          const ref: PackageRef = { packageIdentifier: id, source, displayName: manualName.value.trim() || id, version, scope: manualScope.value as PackageRef['scope'] };
          let added = false;
          mutate((sel) => (added = addPackage(sel, ref, target)));
          manualMsg.append(h('p', { class: added ? 'ok' : 'warning' }, added ? `Added ${ref.displayName}.` : `${ref.displayName} is already there.`));
          if (added) manualId.value = manualName.value = manualVersion.value = '';
        },
      },
      'Add package',
    ),
    manualMsg,
  );

  // Order preview / troubleshooting --------------------------------------------------------------
  const order = h('ol', { class: 'app-order', 'data-testid': 'app-order' });
  const planText = h('pre', { class: 'preview small', 'data-testid': 'app-plan' });

  const body = h(
    'div',
    { class: 'apps' },
    status,
    h('h4', {}, 'Profiles'),
    h('p', { class: 'desc' }, 'Tick one or more profiles to combine them. Every profile starts empty; fill one by adding applications below with "Add to" set to that profile, or with "Save selection here" (Advanced).'),
    profileGrid,
    profileActions,
    h('h4', {}, 'Selected applications ', count),
    warnings,
    selected,
    removedBox,
    h('h4', {}, 'Add applications'),
    h(
      'div',
      { class: 'app-controls' },
      h('label', { for: searchId, class: 'sr-only' }, 'Search the catalog'),
      search,
      h('label', { for: catId, class: 'sr-only' }, 'Category'),
      categorySelect,
      h('span', { class: 'inline-label' }, h('label', { for: targetId }, 'Add to'), targetSelect),
    ),
    h('p', { class: 'desc' }, `Catalog of ${CATALOG.length} applications, identifiers checked on ${CATALOG_UPDATED}. Being listed here installs nothing.`),
    catalogList,
    manual,
    h('h4', { class: 'advanced' }, 'Installation order preview'),
    h('p', { class: 'desc advanced' }, 'The engine installs in this order, one package at a time, after checking with "winget list" whether each one is already installed.'),
    h('div', { class: 'advanced' }, order, h('details', {}, h('summary', {}, 'Full plan with every command (applications-plan.txt)'), planText)),
    h(
      'details',
      { class: 'advanced troubleshooting' },
      h('summary', {}, 'Troubleshooting'),
      h(
        'ul',
        {},
        h('li', {}, 'On the PC, run ', h('code', {}, 'ApplicationEngine.ps1 -Mode Plan'), ' (read-only) to see WinGet\'s state and what would be installed.'),
        h('li', {}, h('code', {}, 'WinGetBootstrap.ps1 -Mode Check'), ' reports whether WinGet works for the signed-in user. WinGet does not work as SYSTEM.'),
        h('li', {}, 'Logs: ', h('code', {}, 'C:\\ProgramData\\WindowsDeploymentBuilder\\Applications\\logs'), ' (engine.log, and the WinGet output per package under packages\\).'),
        h('li', {}, 'Results: ', h('code', {}, 'Applications\\result.json'), ' and ', h('code', {}, 'follow-up.txt'), ' list every package with its status and exit code.'),
      ),
    ),
  );

  let current: ApplicationsSelection | undefined;
  function renderCatalog(): void {
    clear(catalogList);
    const sel = current!;
    const inSelection = new Set(resolveSelection(sel).packages.map((x) => x.key));
    const targetProfile = target === ADDED ? undefined : sel.profiles.find((p) => p.id === target);
    const inTarget = new Set((targetProfile ? targetProfile.packages : sel.added).map(packageKey));
    const results = searchCatalog(query, category);
    if (results.length === 0) catalogList.append(h('li', { class: 'empty' }, 'No catalog entry matches. Use "Add by package identifier" (Advanced) for other packages.'));
    for (const e of results) {
      const key = e.packageIdentifier ? packageKey({ source: e.source, packageIdentifier: e.packageIdentifier }) : '';
      const unresolved = e.validation.status === 'unresolved' || !e.packageIdentifier;
      const there = key !== '' && (targetProfile ? inTarget.has(key) : inSelection.has(key));
      catalogList.append(
        h(
          'li',
          { class: 'catalog-item', 'data-catalog': e.id },
          h(
            'div',
            { class: 'catalog-main' },
            h('strong', {}, e.displayName),
            ' ',
            badge(CATALOG_CATEGORIES[e.category], 'muted'),
            unresolved ? badge('unresolved', 'err', 'No verified WinGet identifier; cannot be installed.') : null,
            e.source === 'msstore' ? badge('Microsoft Store') : null,
            e.accountSignIn ? badge('sign-in after install') : null,
            e.interaction === 'mayPrompt' ? badge('may prompt', 'warn') : null,
            h('span', { class: 'choice-desc' }, e.description, e.notes ? ` ${e.notes}` : ''),
            h(
              'span',
              { class: 'ids advanced' },
              unresolved ? 'No identifier' : `${e.source}: ${e.packageIdentifier}`,
              ` · ${e.license}`,
              e.website ? h('span', {}, ' · ', h('a', { href: e.website, rel: 'noopener noreferrer', target: '_blank' }, 'website')) : null,
            ),
          ),
          h(
            'button',
            {
              type: 'button',
              class: 'btn',
              'data-action': 'app-add',
              disabled: unresolved || there,
              'aria-label': `${there ? 'Added' : 'Add'} ${e.displayName}`,
              onclick: () => mutate((s) => addPackage(s, refFromCatalog(e), target)),
            },
            unresolved ? 'Unavailable' : there ? 'Added ✓' : 'Add',
          ),
        ),
      );
    }
  }

  function render(selection: ApplicationsSelection): void {
    current = selection;
    const r = resolveSelection(selection);
    const counts = new Map(selection.profiles.map((p) => [p.id, resolveSelection({ profiles: selection.profiles, selectedProfiles: [p.id], added: [], removed: [] }).packages.length]));

    clear(profileGrid);
    for (const p of selection.profiles) profileGrid.append(profileCard(p, selection, counts));

    if (!selection.profiles.some((p) => p.id === target)) target = ADDED;
    clear(targetSelect);
    targetSelect.append(h('option', { value: ADDED, selected: target === ADDED }, 'This deployment only'), ...selection.profiles.map((p) => h('option', { value: p.id, selected: target === p.id }, `Profile: ${p.name}`)));

    const installableCount = r.packages.filter((x) => x.resolution !== 'unresolved').length;
    count.textContent = `${installableCount} selected${r.packages.length > installableCount ? `, ${r.packages.length - installableCount} unresolved` : ''}`;

    clear(warnings);
    const notes: HTMLElement[] = [];
    for (const d of r.duplicates) notes.push(h('p', { class: 'info', 'data-kind': 'duplicate' }, `${d.displayName} is in ${d.origins.map((o) => (o === ADDED ? 'your additions' : (selection.profiles.find((p) => p.id === o)?.name ?? o))).join(' and ')}; it is installed once.`));
    for (const c of r.conflicts) notes.push(h('p', { class: 'warning', 'data-kind': 'conflict' }, c.message));
    for (const x of r.packages.filter((p) => p.resolution === 'unresolved')) notes.push(h('p', { class: 'error', 'data-kind': 'unresolved' }, `${x.displayName}: ${x.reason}`));
    for (const id of r.missingProfiles) notes.push(h('p', { class: 'error', 'data-kind': 'missing' }, `Selected profile "${id}" does not exist.`));
    warnings.append(...notes);

    clear(selected);
    if (r.packages.length === 0) {
      selected.append(h('p', { class: 'empty' }, selection.selectedProfiles.length ? 'The selected profiles are empty. Add applications below.' : 'No applications selected. Tick a profile or add applications below.'));
    }
    r.packages.forEach((x, i) => {
      selected.append(
        h(
          'div',
          { class: `app-row${x.resolution === 'unresolved' ? ' unresolved' : ''}`, 'data-package': x.key },
          h('span', { class: 'app-index' }, String(i + 1)),
          h(
            'div',
            { class: 'app-name' },
            h('strong', {}, x.displayName),
            ' ',
            ...packageBadges(x),
            h('span', { class: 'ids advanced' }, `${x.ref.source}: ${x.ref.packageIdentifier}${x.ref.version ? ` · version ${x.ref.version}` : ''}${x.ref.scope ? ` · ${x.ref.scope} scope` : ''}`),
            h('span', { class: 'choice-desc advanced' }, `From: ${x.origins.map((o) => (o === ADDED ? 'added individually' : (selection.profiles.find((p) => p.id === o)?.name ?? o))).join(', ')}`),
          ),
          h('button', { type: 'button', class: 'icon danger', 'data-action': 'app-remove', 'aria-label': `Remove ${x.displayName}`, title: 'Remove from the selection', onclick: () => mutate((s) => removePackage(s, x.key)) }, '✕'),
        ),
      );
    });

    clear(removedBox);
    if (r.removed.length) {
      removedBox.append(
        h('p', { class: 'desc' }, 'Removed from the selected profiles (the profiles themselves are unchanged):'),
        h(
          'ul',
          { class: 'ids-list' },
          r.removed.map((x) => h('li', { 'data-removed': x.key }, `${x.displayName} `, h('button', { type: 'button', class: 'linkish', 'data-action': 'app-restore', onclick: () => mutate((s) => restorePackage(s, x.key)) }, 'restore'))),
        ),
      );
    }

    clear(order);
    const installableList = r.packages.filter((x) => x.resolution !== 'unresolved');
    if (installableList.length === 0) order.append(h('li', { class: 'empty' }, 'Nothing to install.'));
    for (const x of installableList) {
      order.append(
        h(
          'li',
          {},
          h('strong', {}, x.displayName),
          x.interaction === 'required' ? ' (manual follow-up, not attempted)' : '',
          x.after.length ? ` (after ${x.after.join(', ')})` : '',
          h('code', { class: 'cmd' }, `winget ${wingetArguments('install', x.ref).join(' ')}`),
        ),
      );
    }
    planText.textContent = planPreview(store.get());
    renderCatalog();
  }

  const el = customShell(def, body);
  return { el, sync: (p) => render(p.applications.selection) };
};

// Additional Software -----------------------------------------------------------------------------

const INSTALLER_TYPES: AdditionalItem['installerType'][] = ['exe', 'msi', 'msix', 'zip', 'other'];

export const additionalSoftwareEditor: CustomRenderer = (def, store) => {
  const list = h('div', { class: 'list' });
  const mutate = (fn: (items: AdditionalItem[]) => void) => store.update((p) => fn(p.additionalSoftware.items), true);
  const add = h(
    'button',
    {
      type: 'button',
      class: 'btn',
      'data-action': 'add-additional',
      onclick: () =>
        mutate((items) =>
          items.push({
            id: newId(),
            name: '',
            publisher: '',
            downloadUrl: '',
            installerType: 'exe',
            fileName: '',
            sha256: '',
            silentArgs: '',
            prerequisites: '',
            interaction: 'unknown',
            manualSupply: true,
            license: '',
            redistribution: 'unknown',
            execution: 'manual',
            notes: '',
          }),
        ),
    },
    'Add installer',
  );
  const el = customShell(
    def,
    h(
      'div',
      {},
      h('p', { class: 'context' }, h('strong', {}, 'Safety: '), 'URLs are recorded, never downloaded. Silent switches are never guessed: enter only switches the publisher documents. Automatic execution is limited to reviewed installers (none yet), so every entry becomes a manual follow-up task.'),
      list,
      add,
    ),
  );

  const render = (items: AdditionalItem[]) => {
    clear(list);
    if (items.length === 0) list.append(h('p', { class: 'empty' }, 'No additional installers.'));
    items.forEach((it, i) => {
      const text = (key: keyof AdditionalItem, label: string, placeholder = '', type = 'text') => {
        const id = uid('ad');
        return h(
          'div',
          { class: 'mini-field' },
          h('label', { for: id }, label),
          h('input', {
            id,
            type,
            value: String(it[key]),
            placeholder,
            autocomplete: 'off',
            spellcheck: 'false',
            name: `additionalSoftware.items.${i}.${key}`,
            oninput: (e: Event) => store.update((q) => ((q.additionalSoftware.items[i] as Record<string, unknown>)[key] = (e.target as HTMLInputElement).value)),
          }),
        );
      };
      const select = <K extends keyof AdditionalItem>(key: K, label: string, options: [string, string][]) => {
        const id = uid('ad');
        return h(
          'div',
          { class: 'mini-field' },
          h('label', { for: id }, label),
          h(
            'select',
            { id, name: `additionalSoftware.items.${i}.${key}`, onchange: (e: Event) => mutate((xs) => ((xs[i] as Record<string, unknown>)[key] = (e.target as HTMLSelectElement).value)) },
            options.map(([v, l]) => h('option', { value: v, selected: String(it[key]) === v }, l)),
          ),
        );
      };
      const supplyId = uid('ad');
      list.append(
        h(
          'div',
          { class: 'item', 'data-additional-index': i },
          h(
            'div',
            { class: 'item-head' },
            h('strong', {}, it.name || `Installer ${i + 1}`),
            h('span', { class: 'tag' }, it.execution === 'automatic' ? 'automatic (reviewed only)' : 'manual follow-up'),
            h('button', { type: 'button', class: 'icon danger', 'aria-label': 'Delete installer', title: 'Delete', onclick: () => mutate((xs) => xs.splice(i, 1)) }, '✕'),
          ),
          h(
            'div',
            { class: 'mini-grid' },
            text('name', 'Name'),
            text('publisher', 'Publisher'),
            text('downloadUrl', 'Official download URL', 'https://…', 'url'),
            select('installerType', 'Installer type', INSTALLER_TYPES.map((t) => [t, t.toUpperCase()])),
            text('fileName', 'Supplied file name', 'setup.exe'),
            text('sha256', 'Expected SHA-256', '64 hex characters'),
            text('silentArgs', 'Silent arguments (documented by the publisher)', 'e.g. /S'),
            text('prerequisites', 'Prerequisites'),
            select('interaction', 'Interaction', [
              ['unknown', 'Unknown'],
              ['none', 'None (fully silent)'],
              ['required', 'Required'],
            ]),
            text('license', 'Licence'),
            select('redistribution', 'Redistribution', [
              ['unknown', 'Unknown'],
              ['allowed', 'Allowed'],
              ['restricted', 'Restricted'],
            ]),
            select('execution', 'Execution', [
              ['manual', 'Manual follow-up'],
              ['automatic', 'Automatic (reviewed installers only)'],
            ]),
            h(
              'div',
              { class: 'mini-field check' },
              h('input', { type: 'checkbox', id: supplyId, checked: it.manualSupply, onchange: (e: Event) => mutate((xs) => (xs[i]!.manualSupply = (e.target as HTMLInputElement).checked)) }),
              h('label', { for: supplyId }, 'Installer must be supplied manually'),
            ),
            text('notes', 'Notes'),
          ),
          h('div', { class: 'issues', 'data-issues-for': `additionalSoftware.items.${i}` }),
        ),
      );
    });
  };
  return { el, sync: (p) => render(p.additionalSoftware.items) };
};
