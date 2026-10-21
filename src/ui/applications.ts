import type { AdditionalItem } from '../engine/schema/applications';
import { clear, h, uid } from './dom';
import { customShell, type CustomRenderer } from './form';
import { icon, type IconName } from './icons';

export { applicationsEditor } from './app-selection';

const newId = () => (globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random()}`).slice(0, 36);

/** Initials tile. */
function avatar(name: string, category?: string): HTMLElement {
  const initials = name.replace(/[^\p{L}\p{N} ]/gu, ' ').split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0]!.toUpperCase()).join('') || '?';
  return h('span', { class: 'avatar', 'data-cat': category ?? 'other', 'aria-hidden': 'true' }, initials);
}

// Additional Software -----------------------------------------------------------------------------

const INSTALLER_TYPES: AdditionalItem['installerType'][] = ['exe', 'msi', 'msix', 'zip', 'other'];

export const additionalSoftwareEditor: CustomRenderer = (def, store) => {
  const list = h('div', { class: 'addl-list' });
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
    icon('plus'),
    'Add installer',
  );
  const el = customShell(
    def,
    h(
      'div',
      { class: 'addl' },
      h(
        'div',
        { class: 'addl-callout', role: 'note' },
        icon('info'),
        h(
          'div',
          {},
          h('strong', {}, 'Not installed automatically. '),
          'Entries are recorded as a manual follow-up checklist. URLs are recorded, never downloaded. Silent switches are never guessed: enter only switches the publisher documents. Automatic execution is limited to reviewed installers, and there are none yet.',
        ),
      ),
      list,
      add,
    ),
  );

  const render = (items: AdditionalItem[]) => {
    clear(list);
    if (items.length === 0) list.append(h('div', { class: 'empty-state' }, icon('boxPlus'), h('p', { class: 'empty' }, 'No additional installers.')));
    items.forEach((it, i) => {
      const text = (key: keyof AdditionalItem, label: string, placeholder = '', type = 'text', wide = false) => {
        const id = uid('ad');
        return h(
          'div',
          { class: `mini-field${wide ? ' wide' : ''}` },
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
      const part = (title: string, ico: IconName, ...children: HTMLElement[]) => h('div', { class: 'addl-part' }, h('h5', {}, icon(ico), title), h('div', { class: 'mini-grid' }, ...children));
      const supplyId = uid('ad');
      list.append(
        h(
          'div',
          { class: 'item addl-item', 'data-additional-index': i },
          h(
            'div',
            { class: 'item-head' },
            avatar(it.name || `Installer ${i + 1}`),
            h('div', { class: 'addl-title' }, h('strong', {}, it.name || `Installer ${i + 1}`), h('span', { class: 'choice-desc' }, it.publisher || 'Publisher not set')),
            h('span', { class: `tag ${it.execution === 'automatic' ? 'warn' : 'manual'}` }, it.execution === 'automatic' ? 'automatic (reviewed only)' : 'manual follow-up'),
            h('button', { type: 'button', class: 'icon-btn danger', 'aria-label': 'Delete installer', title: 'Delete', onclick: () => mutate((xs) => xs.splice(i, 1)) }, icon('trash')),
          ),
          part('Application', 'package', text('name', 'Name'), text('publisher', 'Publisher (official source)'), text('license', 'Licence'), select('redistribution', 'Redistribution', [
            ['unknown', 'Unknown'],
            ['allowed', 'Allowed'],
            ['restricted', 'Restricted'],
          ])),
          part(
            'Installer source',
            'globe',
            text('downloadUrl', 'Official installer URL', 'https://…', 'url', true),
            select('installerType', 'Installer type', INSTALLER_TYPES.map((t) => [t, t.toUpperCase()])),
            text('fileName', 'Supplied file name', 'setup.exe'),
            text('sha256', 'Expected SHA-256 checksum', '64 hex characters', 'text', true),
          ),
          part(
            'Installation',
            'terminal',
            text('silentArgs', 'Silent arguments (documented by the publisher)', 'e.g. /S'),
            text('prerequisites', 'Prerequisites'),
            select('interaction', 'Interaction', [
              ['unknown', 'Unknown'],
              ['none', 'None (fully silent)'],
              ['required', 'Required'],
            ]),
            select('execution', 'Execution', [
              ['manual', 'Manual follow-up'],
              ['automatic', 'Automatic (reviewed installers only)'],
            ]),
          ),
          part(
            'Manual follow-up',
            'list',
            h(
              'div',
              { class: 'mini-field check' },
              h('input', { type: 'checkbox', id: supplyId, checked: it.manualSupply, onchange: (e: Event) => mutate((xs) => (xs[i]!.manualSupply = (e.target as HTMLInputElement).checked)) }),
              h('label', { for: supplyId }, 'Installer must be supplied manually'),
            ),
            text('notes', 'Notes for the follow-up task', '', 'text', true),
          ),
          h('div', { class: 'issues', 'data-issues-for': `additionalSoftware.items.${i}` }),
        ),
      );
    });
  };
  return { el, sync: (p) => render(p.additionalSoftware.items) };
};
