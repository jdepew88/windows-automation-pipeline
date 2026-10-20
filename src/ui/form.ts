import type { Choice, SettingDef } from '../engine/settings/types';
import type { Profile } from '../engine/schema/profile';
import { h, uid } from './dom';
import { icon } from './icons';
import { getPath, setPath, type Store } from './store';

export interface FieldHandle {
  el: HTMLElement;
  /** Re-reads values from the profile (after imports, resets, structural edits). */
  sync(p: Profile): void;
}

export type CustomRenderer = (def: SettingDef, store: Store) => FieldHandle;

const STAGE_LABELS: Record<string, string> = {
  windowsPE: 'windowsPE',
  specialize: 'specialize',
  oobeSystem: 'oobeSystem',
  defaultUser: 'DefaultUser',
  userOnce: 'UserOnce',
  firstLogon: 'FirstLogon',
  deferred: 'deferred (not applied in M1)',
  none: 'no generated action',
};

export const choicesOf = (def: SettingDef): Choice[] => (typeof def.choices === 'function' ? def.choices() : (def.choices ?? []));

function meta(def: SettingDef): HTMLElement {
  return h(
    'details',
    { class: 'meta' },
    h('summary', {}, icon('info'), 'Technical details'),
    h(
      'dl',
      {},
      h('dt', {}, 'Stage'),
      h('dd', {}, def.stages.map((s) => STAGE_LABELS[s] ?? s).join(', ')),
      h('dt', {}, 'Mapping'),
      h('dd', {}, h('code', {}, def.mapping)),
      h('dt', {}, 'Applies to'),
      h('dd', {}, def.applicability),
      def.verification ? h('dt', {}, 'Mechanism status') : null,
      def.verification ? h('dd', {}, def.verification === 'upstream-tested' ? 'Used by upstream generator' : def.verification === 'documented' ? 'Documented Microsoft setting' : 'Unverified, needs VM confirmation') : null,
    ),
  );
}

/** Layout of a field: toggles and inline controls sit beside their text, the rest below it. */
const LAYOUT: Record<SettingDef['control'], 'toggle' | 'inline' | 'stack'> = {
  checkbox: 'toggle',
  select: 'inline',
  number: 'inline',
  text: 'inline',
  password: 'inline',
  radio: 'stack',
  textarea: 'stack',
  custom: 'stack',
};

function shell(def: SettingDef, control: HTMLElement, labelFor?: string): HTMLElement {
  const isGroup = def.control === 'radio' || def.control === 'custom';
  const layout = LAYOUT[def.control];
  const title = isGroup ? h('legend', { class: 'field-label' }, def.label) : h('label', { class: 'field-label', for: labelFor }, def.label);
  const text = h('div', { class: 'field-text' }, title, def.description ? h('p', { class: 'desc' }, def.description) : null);
  const wrap = h(
    isGroup ? 'fieldset' : 'div',
    { class: `field field-${def.control} layout-${layout}${def.advanced ? ' advanced' : ''}`, 'data-path': def.path },
    layout === 'stack' ? [isGroup ? title : null, isGroup ? h('div', { class: 'field-text' }, def.description ? h('p', { class: 'desc' }, def.description) : null) : text, control] : h('div', { class: 'field-main' }, text, h('div', { class: 'field-control' }, control)),
    def.risk ? h('p', { class: 'risk' }, icon('alert'), h('span', {}, h('strong', {}, 'Caveat: '), def.risk)) : null,
    h('div', { class: 'issues', 'data-issues-for': def.path, 'aria-live': 'polite' }),
    meta(def),
  );
  return wrap;
}

export function renderField(def: SettingDef, store: Store, custom: Record<string, CustomRenderer>): FieldHandle {
  const renderer = custom[def.path];
  const handle = renderer ? renderer(def, store) : renderStandard(def, store);
  const base = handle.sync;
  return {
    el: handle.el,
    sync(p) {
      handle.el.hidden = def.visibleWhen ? !def.visibleWhen(p) : false;
      base(p);
    },
  };
}

function renderStandard(def: SettingDef, store: Store): FieldHandle {
  const id = uid('f');
  const set = (value: unknown, structural = true) => store.update((p) => setPath(p, def.path, value), structural);

  switch (def.control) {
    case 'checkbox': {
      const input = h('input', { type: 'checkbox', class: 'switch', role: 'switch', id, name: def.path, onchange: () => set(input.checked) });
      const el = shell(def, input, id);
      return { el, sync: (p) => (input.checked = Boolean(getPath(p, def.path))) };
    }
    case 'radio': {
      const inputs = choicesOf(def).map((c) => {
        const rid = uid('r');
        const input = h('input', { type: 'radio', id: rid, name: def.path, value: c.value, onchange: () => input.checked && set(c.value) });
        return { input, row: h('label', { class: 'choice', for: rid }, input, h('span', { class: 'choice-text' }, h('span', { class: 'choice-label' }, c.label), c.description ? h('span', { class: 'choice-desc' }, c.description) : null)) };
      });
      const el = shell(def, h('div', { class: 'choices', role: 'radiogroup' }, inputs.map((i) => i.row)));
      return { el, sync: (p) => inputs.forEach((i) => (i.input.checked = i.input.value === getPath(p, def.path))) };
    }
    case 'select': {
      const select = h('select', { id, name: def.path, onchange: () => set(select.value) }, choicesOf(def).map((c) => h('option', { value: c.value }, c.label)));
      const el = shell(def, select, id);
      return { el, sync: (p) => (select.value = String(getPath(p, def.path))) };
    }
    case 'number': {
      const input = h('input', { type: 'number', id, name: def.path, inputmode: 'numeric', oninput: () => set(input.value === '' ? 0 : Math.trunc(Number(input.value)), false) });
      const el = shell(def, input, id);
      return { el, sync: (p) => (input.value = String(getPath(p, def.path))) };
    }
    case 'textarea': {
      const ta = h('textarea', { id, name: def.path, rows: 8, spellcheck: 'false', placeholder: def.placeholder, oninput: () => set(ta.value, false) });
      const el = shell(def, ta, id);
      return { el, sync: (p) => (ta.value = String(getPath(p, def.path) ?? '')) };
    }
    case 'text':
    case 'password': {
      const input = h('input', {
        type: def.control,
        id,
        name: def.path,
        autocomplete: 'off',
        spellcheck: 'false',
        placeholder: def.placeholder,
        oninput: () => set(input.value, false),
      });
      const el = shell(def, input, id);
      return { el, sync: (p) => (input.value = String(getPath(p, def.path) ?? '')) };
    }
    default:
      throw new Error(`No renderer for ${def.path} (${def.control})`);
  }
}

/** Shared wrapper for custom editors, so they get the same label, notes and issue slot. */
export function customShell(def: SettingDef, body: HTMLElement): HTMLElement {
  return shell(def, body);
}
