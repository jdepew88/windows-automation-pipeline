import type { AdditionalItem, ApplicationsSelection } from '../engine/schema/applications';
import { effectiveApps, type AppSummaryItem, type EffectiveApps, type ProfilePreview } from '../engine/applications/preview';
import type { SelectionResult } from '../engine/applications/selection';
import { appLogo } from './app-icon';
import { h } from './dom';
import { icon } from './icons';

/**
 * Compact, read-only application lists for Quick Deployment (Final Review, profile previews and
 * the combined selection). They draw what src/engine/applications/preview.ts computes from the
 * shared selection; nothing here selects or deselects anything.
 */

const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

function grid(items: AppSummaryItem[], note: (x: AppSummaryItem) => string, testid: string, extra: (x: AppSummaryItem) => Record<string, string> = () => ({})): HTMLElement {
  return h(
    'ul',
    { class: 'app-sum-grid', 'data-testid': testid },
    items.map((x) =>
      h(
        'li',
        { class: `app-sum-item kind-${x.kind}`, 'data-key': x.key, 'data-kind': x.kind, title: [x.displayName, note(x)].filter(Boolean).join(': '), ...extra(x) },
        appLogo(x.catalogId, x.displayName, x.category, 'sm'),
        h('span', { class: 'app-sum-text' }, h('span', { class: 'app-sum-name' }, x.displayName), note(x) ? h('span', { class: 'app-sum-note' }, note(x)) : null),
        x.kind === 'manual' ? h('span', { class: 'app-sum-flag', title: 'Manual follow-up: not installed automatically' }, icon('hand')) : null,
      ),
    ),
  );
}

const group = (title: string, items: AppSummaryItem[], testid: string, note: (x: AppSummaryItem) => string, hint?: string) =>
  items.length
    ? h(
        'div',
        { class: 'app-sum-group', 'data-key': `group-${testid}` },
        h('h4', { class: 'app-sum-head' }, title, h('span', { class: 'chip-count' }, String(items.length)), hint ? h('span', { class: 'app-sum-hint' }, hint) : null),
        grid(items, note, testid),
      )
    : null;

/** The applications of the effective selection: automatic installs, manual follow-ups, unresolved. */
export function effectiveAppsView(apps: EffectiveApps, opts: { testid: string; origins?: boolean }): HTMLElement {
  const note = (x: AppSummaryItem) => (opts.origins ? x.origin : '');
  const headline = !apps.enabled
    ? 'Application provisioning is off: no applications are installed.'
    : apps.total === 0
      ? 'No applications are selected.'
      : `${plural(apps.total, 'application')} selected: ${apps.automatic.length} installed automatically${apps.manual.length ? `, ${apps.manual.length} manual follow-up` : ''}${apps.unresolved.length ? `, ${apps.unresolved.length} cannot be installed` : ''}${apps.additional.length ? `, ${apps.additional.length} Additional Software` : ''}.`;
  return h(
    'div',
    { class: 'app-sum', 'data-testid': opts.testid, 'data-total': String(apps.total) },
    h('p', { class: `app-sum-count${apps.total ? '' : ' empty'}`, 'data-testid': `${opts.testid}-count` }, headline),
    group('Installed automatically', apps.automatic, `${opts.testid}-auto`, note),
    group('Manual follow-up', apps.manual, `${opts.testid}-manual`, note, 'Listed with official download instructions; never reported as installed.'),
    group('Cannot be installed', apps.unresolved, `${opts.testid}-unresolved`, note, 'Fix or remove them in Applications.'),
    group('Additional Software', apps.additional, `${opts.testid}-additional`, (x) => (opts.origins ? x.origin : x.kind === 'manual' ? 'Manual follow-up' : 'Installed from the supplied installer'), 'Installers WinGet does not cover; each is checked by the final verification.'),
  );
}

/** Final Review: only what the deployment installs or lists. */
export function selectedAppsSummary(sel: ApplicationsSelection, enabled: boolean, r: SelectionResult, additional: readonly AdditionalItem[] = []): HTMLElement {
  return effectiveAppsView(effectiveApps(sel, enabled, r, additional), { testid: 'review-app-summary' });
}

/** The list a profile's "View applications" opens. */
export function profilePreviewView(pv: ProfilePreview, regionId: string): HTMLElement {
  const note = (x: AppSummaryItem) => {
    const i = pv.items.find((y) => y.key === x.key)!;
    return [i.excludedBy ?? '', i.viaText, i.alsoIn.length ? `Also in ${i.alsoIn.join(', ')}` : ''].filter(Boolean).join(' · ');
  };
  const shown = pv.items;
  const excluded = shown.filter((x) => x.status === 'excluded').length;
  const already = shown.filter((x) => x.status === 'included').length;
  const lead = pv.selected
    ? `${plural(pv.count, 'app')} from this profile${excluded ? `, ${excluded} left out of this deployment` : ''}.`
    : `Ticking it adds ${plural(shown.filter((x) => x.status === 'wouldAdd').length, 'app')}${already ? ` (${already} already selected)` : ''}${excluded ? `; ${excluded} stay left out` : ''}. Viewing does not select it.`;
  return h(
    'div',
    { class: 'type-preview', id: regionId, role: 'region', 'aria-label': `Applications in ${pv.name}`, 'data-testid': `preview-${pv.id}`, 'data-count': String(pv.count) },
    h('p', { class: 'app-sum-count' }, lead),
    shown.length
      ? grid(shown, note, `preview-${pv.id}-list`, (x) => ({ 'data-status': pv.items.find((y) => y.key === x.key)!.status }))
      : h('p', { class: 'desc' }, 'This profile has no default applications.'),
    pv.optional ? h('p', { class: 'desc' }, `${plural(pv.optional, 'more app')} ${pv.optional === 1 ? 'is' : 'are'} recommended but not selected; tick them in the Applications step.`) : null,
    pv.leftOut.length ? h('p', { class: 'desc' }, `Leaves out: ${pv.leftOut.join(', ')}.`) : null,
  );
}
