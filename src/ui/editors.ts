import type { Architecture, BloatwareAction, ComponentEntry, Pass, Profile, Script, ScriptPhase, ScriptType } from '../engine/schema/profile';
import { BLOATWARE, BLOATWARE_GROUP_LABELS, appliesToWindows11, type BloatwareGroup } from '../features/bloatware/catalog';
import { PHASES } from '../features/scripts';
import { COMPONENTS } from '../data';
import { clear, h, uid } from './dom';
import { icon } from './icons';
import { choicesOf, customShell, type CustomRenderer } from './form';
import { additionalSoftwareEditor, applicationsEditor } from './applications';

const newId = () => (globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random()}`).slice(0, 36);

/** Checkbox group over a record of booleans (desktop icons, Start folders). */
function booleanMap(get: (p: Profile) => Record<string, boolean>): CustomRenderer {
  return (def, store) => {
    const rows = choicesOf(def).map((c) => {
      const id = uid('m');
      const input = h('input', {
        type: 'checkbox',
        id,
        name: `${def.path}.${c.value}`,
        onchange: () => store.update((p) => (get(p)[c.value] = input.checked)),
      });
      return { key: c.value, input, row: h('div', { class: 'check' }, input, h('label', { for: id }, c.label)) };
    });
    const el = customShell(def, h('div', { class: 'grid-checks' }, rows.map((r) => r.row)));
    return { el, sync: (p) => rows.forEach((r) => (r.input.checked = Boolean(get(p)[r.key]))) };
  };
}

const architectures: CustomRenderer = (def, store) => {
  const rows = choicesOf(def).map((c) => {
    const id = uid('a');
    const input = h('input', {
      type: 'checkbox',
      id,
      name: `${def.path}.${c.value}`,
      onchange: () =>
        store.update((p) => {
          const set = new Set(p.setup.processorArchitectures);
          if (input.checked) set.add(c.value as Architecture);
          else set.delete(c.value as Architecture);
          p.setup.processorArchitectures = (['amd64', 'arm64', 'x86'] as Architecture[]).filter((a) => set.has(a));
        }),
    });
    return { key: c.value, input, row: h('div', { class: 'check' }, input, h('label', { for: id }, c.label)) };
  });
  const el = customShell(def, h('div', { class: 'grid-checks' }, rows.map((r) => r.row)));
  return { el, sync: (p) => rows.forEach((r) => (r.input.checked = p.setup.processorArchitectures.includes(r.key as Architecture))) };
};

const ACTIONS: { value: BloatwareAction; label: string }[] = [
  { value: 'keep', label: 'Keep' },
  { value: 'remove', label: 'Remove' },
  { value: 'untouched', label: 'Leave untouched' },
];

const bloatware: CustomRenderer = (def, store) => {
  const groups = new Map<BloatwareGroup, typeof BLOATWARE>();
  for (const b of BLOATWARE) groups.set(b.group, [...(groups.get(b.group) ?? []), b]);
  const inputs: { id: string; action: BloatwareAction; input: HTMLInputElement }[] = [];
  const body = h(
    'div',
    { class: 'bloat' },
    [...groups].map(([group, entries]) =>
      h(
        'section',
        { class: 'bloat-group' },
        h('h4', {}, BLOATWARE_GROUP_LABELS[group]),
        h(
          'table',
          {},
          h('thead', {}, h('tr', {}, h('th', { scope: 'col' }, 'App'), ...ACTIONS.map((a) => h('th', { scope: 'col' }, a.label)))),
          h(
            'tbody',
            {},
            entries.map((b) => {
              const name = `bloatware.${b.id}`;
              const selectors = b.steps.filter((s) => s.selector).map((s) => `${s.selector} (${s.appliesTo.join(', ')})`);
              return h(
                'tr',
                { 'data-app': b.id },
                h(
                  'th',
                  { scope: 'row' },
                  b.label,
                  b.steps.length > 0 && !appliesToWindows11(b) ? h('span', { class: 'tag' }, 'Windows 10 only') : null,
                  b.note ? h('span', { class: 'choice-desc' }, b.note) : null,
                  selectors.length ? h('span', { class: 'ids' }, selectors.join('; ')) : null,
                ),
                ...ACTIONS.map((a) => {
                  const disabled = a.value === 'remove' && !b.removable;
                  const input = h('input', {
                    type: 'radio',
                    name,
                    value: a.value,
                    'aria-label': `${a.label}: ${b.label}`,
                    disabled,
                    onchange: () => input.checked && store.update((p) => (p.bloatware[b.id] = a.value)),
                  });
                  inputs.push({ id: b.id, action: a.value, input });
                  return h('td', {}, input);
                }),
              );
            }),
          ),
        ),
      ),
    ),
  );
  const el = customShell(def, body);
  return { el, sync: (p) => inputs.forEach((i) => (i.input.checked = (p.bloatware[i.id] ?? 'untouched') === i.action)) };
};

const TYPE_LABELS: Record<ScriptType, string> = { ps1: 'PowerShell (.ps1)', cmd: 'Batch (.cmd)', reg: 'Registry (.reg)', vbs: 'VBScript (.vbs)' };

function scriptList(phase: ScriptPhase): CustomRenderer {
  const info = PHASES.find((x) => x.phase === phase)!;
  return (def, store) => {
    const list = h('div', { class: 'list' });
    const mutate = (fn: (items: Script[]) => void) => store.update((p) => fn(p.scripts[phase]), true);
    const add = h(
      'button',
      {
        type: 'button',
        class: 'btn',
        'data-action': `add-script-${phase}`,
        onclick: () => mutate((items) => items.push({ id: newId(), name: '', type: 'ps1', enabled: true, content: '' })),
      },
      icon('plus'),
      `Add ${info.title.replace(/ scripts$/, '')} script`,
    );
    const el = customShell(def, h('div', {}, h('p', { class: 'context' }, h('strong', {}, 'When and how it runs: '), info.context), list, add));

    const render = (p: Profile) => {
      clear(list);
      const items = p.scripts[phase];
      if (items.length === 0) list.append(h('p', { class: 'empty' }, 'No scripts. Nothing will run in this stage.'));
      items.forEach((s, i) => {
        const nameId = uid('sn');
        const typeId = uid('st');
        const enId = uid('se');
        const contentId = uid('sc');
        list.append(
          h(
            'div',
            { class: 'item', 'data-script-index': i },
            h(
              'div',
              { class: 'item-head' },
              h('label', { for: nameId, class: 'sr-only' }, 'Script name'),
              h('input', { id: nameId, placeholder: `Script ${i + 1} name (optional)`, value: s.name, oninput: (e: Event) => store.update((q) => (q.scripts[phase][i]!.name = (e.target as HTMLInputElement).value)) }),
              h('label', { for: typeId, class: 'sr-only' }, 'Script type'),
              h(
                'select',
                { id: typeId, onchange: (e: Event) => mutate((it) => (it[i]!.type = (e.target as HTMLSelectElement).value as ScriptType)) },
                info.allowedTypes.map((t) => h('option', { value: t, selected: t === s.type }, TYPE_LABELS[t])),
              ),
              h('span', { class: 'check' }, h('input', { type: 'checkbox', id: enId, checked: s.enabled, onchange: (e: Event) => mutate((it) => (it[i]!.enabled = (e.target as HTMLInputElement).checked)) }), h('label', { for: enId }, 'Enabled')),
              h('button', { type: 'button', class: 'icon-btn', title: 'Move up', 'aria-label': 'Move up', disabled: i === 0, onclick: () => mutate((it) => it.splice(i - 1, 0, ...it.splice(i, 1))) }, icon('chevronUp')),
              h('button', { type: 'button', class: 'icon-btn', title: 'Move down', 'aria-label': 'Move down', disabled: i === items.length - 1, onclick: () => mutate((it) => it.splice(i + 1, 0, ...it.splice(i, 1))) }, icon('chevronDown')),
              h('button', { type: 'button', class: 'icon-btn danger', title: 'Delete', 'aria-label': 'Delete script', onclick: () => mutate((it) => it.splice(i, 1)) }, icon('trash')),
            ),
            h('label', { for: contentId, class: 'sr-only' }, 'Script content'),
            h('textarea', {
              id: contentId,
              rows: 6,
              spellcheck: 'false',
              placeholder: 'Script content. It is stored in the answer file and never run in this browser.',
              oninput: (e: Event) => store.update((q) => (q.scripts[phase][i]!.content = (e.target as HTMLTextAreaElement).value)),
            }, s.content),
            h('div', { class: 'issues', 'data-issues-for': `scripts.${phase}.${i}` }),
          ),
        );
      });
    };
    // sync runs only for structural changes (never while typing), so re-rendering keeps focus.
    return { el, sync: render };
  };
}

const PASS_OPTIONS: Pass[] = ['windowsPE', 'offlineServicing', 'generalize', 'specialize', 'auditSystem', 'auditUser', 'oobeSystem'];

const components: CustomRenderer = (def, store) => {
  const list = h('div', { class: 'list' });
  const datalistId = uid('cl');
  const datalist = h('datalist', { id: datalistId }, COMPONENTS.map((c) => h('option', { value: c.Id })));
  const mutate = (fn: (items: ComponentEntry[]) => void) => store.update((p) => fn(p.advancedXml.components), true);
  const add = h(
    'button',
    { type: 'button', class: 'btn', 'data-action': 'add-component', onclick: () => mutate((it) => it.push({ id: newId(), enabled: true, component: '', pass: 'specialize', markup: '' })) },
    icon('plus'),
    'Add component',
  );
  const el = customShell(def, h('div', {}, datalist, list, add));
  const render = (p: Profile) => {
    clear(list);
    const items = p.advancedXml.components;
    if (items.length === 0) list.append(h('p', { class: 'empty' }, 'No additional components.'));
    items.forEach((c, i) => {
      const nameId = uid('cn');
      const passId = uid('cp');
      const enId = uid('ce');
      const markupId = uid('cm');
      list.append(
        h(
          'div',
          { class: 'item', 'data-component-index': i },
          h(
            'div',
            { class: 'item-head' },
            h('label', { for: nameId, class: 'sr-only' }, 'Component name'),
            h('input', { id: nameId, list: datalistId, placeholder: 'Microsoft-Windows-…', value: c.component, oninput: (e: Event) => store.update((q) => (q.advancedXml.components[i]!.component = (e.target as HTMLInputElement).value)) }),
            h('label', { for: passId, class: 'sr-only' }, 'Pass'),
            h('select', { id: passId, onchange: (e: Event) => mutate((it) => (it[i]!.pass = (e.target as HTMLSelectElement).value as Pass)) }, PASS_OPTIONS.map((ps) => h('option', { value: ps, selected: ps === c.pass }, ps))),
            h('span', { class: 'check' }, h('input', { type: 'checkbox', id: enId, checked: c.enabled, onchange: (e: Event) => mutate((it) => (it[i]!.enabled = (e.target as HTMLInputElement).checked)) }), h('label', { for: enId }, 'Enabled')),
            h('button', { type: 'button', class: 'icon-btn danger', 'aria-label': 'Delete component', title: 'Delete', onclick: () => mutate((it) => it.splice(i, 1)) }, icon('trash')),
          ),
          h('label', { for: markupId, class: 'sr-only' }, 'Inner XML markup'),
          h('textarea', {
            id: markupId,
            rows: 6,
            spellcheck: 'false',
            placeholder: '<SettingName>value</SettingName>  (inner markup only; wcm: prefix available)',
            oninput: (e: Event) => store.update((q) => (q.advancedXml.components[i]!.markup = (e.target as HTMLTextAreaElement).value)),
          }, c.markup),
          h('div', { class: 'issues', 'data-issues-for': `advancedXml.components.${i}` }),
        ),
      );
    });
  };
  return { el, sync: render };
};

export const CUSTOM_RENDERERS: Record<string, CustomRenderer> = {
  'setup.processorArchitectures': architectures,
  'desktop.icons': booleanMap((p) => p.desktop.icons),
  'start.folders': booleanMap((p) => p.start.folders),
  bloatware,
  'scripts.firstLogon': scriptList('firstLogon'),
  'scripts.system': scriptList('system'),
  'scripts.defaultUser': scriptList('defaultUser'),
  'scripts.userOnce': scriptList('userOnce'),
  'advancedXml.components': components,
  'applications.selection': applicationsEditor,
  'additionalSoftware.items': additionalSoftwareEditor,
};
