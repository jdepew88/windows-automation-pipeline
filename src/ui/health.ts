import type { Profile } from '../engine/schema/profile';
import { renderHealthTemplate, sampleHealthReport } from '../engine/health';
import { effectiveApps } from '../engine/applications/preview';
import { clear, h } from './dom';
import { customShell, type CustomRenderer } from './form';
import { icon } from './icons';

/**
 * Phase 9: Deployment Verification & Health (Advanced Configuration). The website never knows the
 * target computer's state: the previews below use clearly labelled sample data and the same
 * report template the installed computer fills with its verified results.
 */

/** Selected applications that may be missing at delivery (ReadyWithWarnings instead of NeedsAttention). */
export const healthOptionalAppsEditor: CustomRenderer = (def, store) => {
  const list = h('div', { class: 'health-apps', 'data-testid': 'health-optional-apps' });
  const el = customShell(def, list);
  const sync = (p: Profile) => {
    const apps = effectiveApps(p.applications.selection, p.applications.enabled);
    const additional = p.additionalSoftware.items.filter((i) => i.execution === 'automatic');
    const rows = [
      ...apps.automatic.map((x) => ({ key: x.key, name: x.displayName })),
      ...additional.map((i) => ({ key: `additional:${i.id.toLowerCase()}`, name: `${i.name || i.fileName} (Additional Software)` })),
    ];
    clear(list);
    if (!rows.length) {
      list.append(h('p', { class: 'empty' }, p.applications.enabled ? 'No application is installed automatically, so nothing can block delivery here.' : 'Application provisioning is off.'));
      return;
    }
    const chosen = new Set(p.health.optionalApps);
    list.append(
      h('p', { class: 'desc' }, `${chosen.size ? `${[...chosen].filter((k) => rows.some((r) => r.key === k)).length} of ${rows.length}` : `None of ${rows.length}`} marked optional. Unticked applications are required for "Ready".`),
      h(
        'ul',
        { class: 'health-app-list' },
        rows.map((r) =>
          h(
            'li',
            {},
            h(
              'label',
              { class: 'check' },
              h('input', {
                type: 'checkbox',
                'data-health-app': r.key,
                checked: chosen.has(r.key),
                onchange: (e: Event) => {
                  const on = (e.target as HTMLInputElement).checked;
                  store.update((q) => {
                    q.health.optionalApps = on ? [...new Set([...q.health.optionalApps, r.key])] : q.health.optionalApps.filter((k) => k !== r.key);
                  }, true);
                },
              }),
              h('span', {}, r.name),
            ),
          ),
        ),
      ),
    );
  };
  return { el, sync };
};

/** Technician notes for the customer report, and previews of both reports with sample data. */
export const healthNotesEditor: CustomRenderer = (def, store) => {
  const area = h('textarea', {
    rows: 4,
    maxlength: 2000,
    'aria-label': def.label,
    'data-testid': 'health-notes',
    placeholder: 'For example: "Your files were copied to Documents\\Old computer. Call us on 555-0100 with any question."',
    oninput: (e: Event) => store.update((q) => (q.health.customerNotes = (e.target as HTMLTextAreaElement).value)),
  });
  const region = h('div', { class: 'health-preview', id: 'health-preview', role: 'region', 'aria-label': 'Report preview with sample data', hidden: true, 'data-testid': 'health-preview' });
  let mode: 'technician' | 'customer' | null = null;
  const buttons = (['technician', 'customer'] as const).map((m) =>
    h(
      'button',
      {
        type: 'button',
        class: 'btn',
        'data-preview': m,
        'aria-controls': 'health-preview',
        'aria-expanded': 'false',
        onclick: () => {
          mode = mode === m ? null : m;
          draw(store.get());
        },
      },
      icon(m === 'technician' ? 'shieldCheck' : 'user'),
      m === 'technician' ? 'Preview technician report' : 'Preview customer report',
    ),
  );
  const draw = (p: Profile) => {
    for (const b of buttons) b.setAttribute('aria-expanded', String(b.dataset.preview === mode));
    clear(region);
    region.hidden = !mode;
    if (!mode) return;
    region.append(
      h('p', { class: 'health-sample-note', 'data-testid': 'health-sample-note' }, icon('info'), 'Sample data. This shows what the report looks like; the real report is written on the installed computer from what it verifies there. This website cannot know the target computer’s drivers, applications or security.'),
      h('iframe', { title: `${mode === 'technician' ? 'Technician' : 'Customer'} report preview (sample data)`, sandbox: 'allow-scripts', srcdoc: renderHealthTemplate(sampleHealthReport(mode, p.health.customerNotes)), 'data-testid': 'health-preview-frame' }),
    );
  };
  const el = customShell(def, h('div', {}, area, h('div', { class: 'health-preview-actions' }, ...buttons), region));
  const sync = (p: Profile) => {
    if (document.activeElement !== area && area.value !== p.health.customerNotes) area.value = p.health.customerNotes;
  };
  return { el, sync };
};
