import type { GenerateResult } from '../engine/pipeline';
import { ownerDefaults } from '../engine/profiles';
import { diffProfiles, displayValue } from '../engine/profiles/diff';
import type { Profile } from '../engine/schema/profile';
import { resolveIdentity } from '../engine/naming';
import { lookup } from '../data';
import { SETTINGS_BY_PATH } from '../features';
import { isEffective, PHASES } from '../features/scripts';
import { resolveDrivers, type DeploymentAsset } from '../engine/windows-update';
import { resolveSelection } from '../engine/applications/selection';
import { clear, download, h } from './dom';

function labelFor(path: string): string {
  const exact = SETTINGS_BY_PATH.get(path);
  if (exact) return exact.label;
  // Map entries (bloatware.X, desktop.icons.X) and list items fall back to their parent setting.
  const parts = path.split('.');
  for (let i = parts.length - 1; i > 0; i--) {
    const parent = SETTINGS_BY_PATH.get(parts.slice(0, i).join('.'));
    if (parent) return `${parent.label} › ${parts.slice(i).join('.')}`;
  }
  return path;
}

function summaryRows(p: Profile): [string, string][] {
  const id = resolveIdentity(p.accounts);
  const scripts = PHASES.map((ph) => `${ph.title.replace(' scripts', '')}: ${p.scripts[ph.phase].filter(isEffective).length}`).join(', ');
  const removed = Object.values(p.bloatware).filter((v) => v === 'remove').length;
  const edition =
    p.setup.editionMode === 'genericKey'
      ? `Windows 11 ${lookup.edition(p.setup.editionId)?.DisplayName ?? p.setup.editionId} (generic installation key: selects the edition, does not activate)`
      : p.setup.editionMode;
  return [
    ['Edition', edition],
    ['Language', p.setup.languageMode === 'unattended' ? `${p.setup.imageLanguage}, locale ${p.setup.userLocale}, keyboard ${lookup.keyboard(p.setup.keyboard)?.DisplayName ?? p.setup.keyboard}` : 'Chosen interactively'],
    ['Disk', 'Interactive: you choose and format the partition in Windows Setup'],
    [
      'Account',
      p.accounts.accountMode === 'unattendedLocal'
        ? `Local ${p.accounts.accountGroup === 'Administrators' ? 'administrator' : 'standard user'} "${id.username || '?'}" (${id.displayName || '?'}), password ${p.accounts.password ? 'set' : 'empty'}`
        : p.accounts.accountMode === 'interactiveLocal'
          ? 'Local account created interactively'
          : 'Microsoft account (interactive)',
    ],
    ['Automatic sign-in', p.accounts.accountMode === 'unattendedLocal' ? p.accounts.autoLogon : 'n/a'],
    ['Computer name', id.computerName ?? 'Random (Windows-generated)'],
    ['UAC', p.security.uacLevel],
    ['Windows Update', `${p.updates.mode}${p.updates.excludeDrivers ? ', drivers excluded' : ''}`],
    [
      'Update automation',
      p.windowsUpdate.enabled
        ? `On: drivers ${resolveDrivers(p) === 'include' ? 'included' : 'excluded'}, feature updates ${p.windowsUpdate.featureUpdates === 'install' ? 'installed' : 'skipped'}, at most ${p.windowsUpdate.maxReboots} restarts / ${p.windowsUpdate.maxRuntimeHours} h`
        : 'Off',
    ],
    ['Applications', applicationsSummary(p)],
    ['Additional software', p.additionalSoftware.items.length ? `${p.additionalSoftware.items.length} installer(s), listed for manual follow-up` : 'None'],
    ['Wi-Fi', p.wifi.mode],
    ['Apps removed', String(removed)],
    ['Custom scripts', scripts],
    ['Extra components', String(p.advancedXml.components.filter((c) => c.enabled && c.markup.trim()).length)],
    ['File name', p.output.answerFileName],
  ];
}

function applicationsSummary(p: Profile): string {
  if (!p.applications.enabled) return 'Off';
  const r = resolveSelection(p.applications.selection);
  const ok = r.packages.filter((x) => x.resolution !== 'unresolved').length;
  if (r.packages.length === 0) return 'On, nothing selected (nothing is generated)';
  const profiles = p.applications.selection.selectedProfiles.map((id) => p.applications.selection.profiles.find((x) => x.id === id)?.name ?? id);
  return `${ok} package(s) via WinGet${profiles.length ? ` from ${profiles.join(' + ')}` : ''}${r.packages.length > ok ? `, ${r.packages.length - ok} unresolved` : ''}; installed after Windows Update as the signed-in user`;
}

const GROUP_TITLES: Record<DeploymentAsset['group'], string> = {
  'windows-update': 'Windows Update engine',
  applications: 'Application provisioning',
  orchestration: 'Orchestration',
};

export interface ReviewHandle {
  el: HTMLElement;
  update(p: Profile, result: GenerateResult): void;
}

export function renderReview(): ReviewHandle {
  const summary = h('table', { class: 'summary', 'data-testid': 'summary' });
  const diff = h('div', { class: 'diff advanced', 'data-testid': 'diff' });
  const status = h('div', { class: 'status', 'data-testid': 'status', 'aria-live': 'polite' });
  const preview = h('pre', { class: 'preview', 'data-testid': 'xml-preview', tabindex: 0 });
  const files = h('div', { class: 'files advanced' });
  const assets = h('div', { class: 'assets', 'data-testid': 'assets' });
  let current: GenerateResult | undefined;

  const downloadBtn = h(
    'button',
    {
      type: 'button',
      class: 'btn primary',
      'data-action': 'download-xml',
      onclick: () => current?.ok && current.xml && download(current.fileName, current.xml, 'application/xml'),
    },
    'Download answer file',
  );
  const copyBtn = h(
    'button',
    { type: 'button', class: 'btn', onclick: () => current?.xml && navigator.clipboard?.writeText(current.xml) },
    'Copy XML',
  );

  const el = h(
    'section',
    { class: 'section review', id: 'section-review', 'aria-labelledby': 'review-title' },
    h('h2', { id: 'review-title' }, 'Review & download'),
    status,
    h('h3', {}, 'Summary'),
    summary,
    h('h3', { class: 'advanced' }, 'Changes from owner defaults'),
    diff,
    h('h3', {}, 'XML preview'),
    h(
      'p',
      { class: 'desc' },
      'Well-formed XML that passes these checks still needs testing: validate it with Windows System Image Manager and run a disposable VM installation before using it on real hardware. Copy the file to the root of your installation USB drive manually.',
    ),
    h('div', { class: 'actions' }, downloadBtn, copyBtn),
    preview,
    h('h3', {}, 'Deployment assets'),
    assets,
    h('h3', { class: 'advanced' }, 'Embedded files (extracted to disk during specialize)'),
    files,
  );

  return {
    el,
    update(p, result) {
      current = result;
      clear(summary);
      for (const [k, v] of summaryRows(p)) summary.append(h('tr', {}, h('th', { scope: 'row' }, k), h('td', {}, v)));

      clear(diff);
      const changes = diffProfiles(ownerDefaults(), p).filter((c) => c.path !== 'profileName');
      diff.append(
        changes.length === 0
          ? h('p', { class: 'empty' }, 'No changes. This is exactly the owner-default profile.')
          : h(
              'table',
              {},
              h('thead', {}, h('tr', {}, h('th', {}, 'Setting'), h('th', {}, 'Owner default'), h('th', {}, 'Current'))),
              h('tbody', {}, changes.map((c) => h('tr', { 'data-diff-path': c.path }, h('td', {}, labelFor(c.path), h('code', { class: 'path' }, c.path)), h('td', {}, displayValue(c.path, c.from)), h('td', {}, displayValue(c.path, c.to))))),
            ),
      );

      clear(status);
      const errors = result.issues.filter((i) => i.severity === 'error');
      const warnings = result.issues.filter((i) => i.severity === 'warning');
      if (result.ok) {
        status.className = 'status ok';
        status.append(h('strong', {}, `Ready: ${result.fileName} generated`), warnings.length ? ` with ${warnings.length} warning(s)` : '', '.');
      } else {
        status.className = 'status error';
        status.append(
          h('strong', {}, `Cannot generate: ${errors.length} problem(s) to fix`),
          h('ul', {}, errors.map((e) => h('li', {}, h('a', { href: `#field-${e.path || 'top'}`, 'data-jump': e.path }, labelFor(e.path) || 'Document'), ': ', e.message))),
        );
      }
      if (warnings.length) status.append(h('ul', { class: 'warnings' }, warnings.map((w) => h('li', {}, labelFor(w.path), ': ', w.message))));

      downloadBtn.disabled = !result.ok;
      copyBtn.disabled = !result.ok;
      preview.textContent = result.ok ? result.xml! : 'No XML is shown while there are errors.';

      clear(assets);
      if (!result.ok) {
        assets.append(h('p', { class: 'empty' }, 'Available once the errors above are fixed.'));
      } else if (result.assets.length === 0) {
        assets.append(h('p', { class: 'empty' }, 'None. Turn on Windows Update automation or select applications to get the engine scripts.'));
      } else {
        assets.append(
          h(
            'p',
            { class: 'desc' },
            'The engine scripts and their configuration are already embedded in the answer file and installed automatically. Download them to inspect, to run an engine by hand on an installed PC (see each README), or for the future deployment bundle.',
          ),
          ...(Object.keys(GROUP_TITLES) as DeploymentAsset['group'][]).filter((g) => result.assets.some((a) => a.group === g)).flatMap((g) => [
          h('h4', { class: 'asset-group' }, GROUP_TITLES[g]),
          h(
            'ul',
            { class: 'asset-list', 'data-asset-group': g },
            result.assets.filter((a) => a.group === g).map((a) =>
              h(
                'li',
                { 'data-asset': a.name },
                h('div', { class: 'asset-head' }, h('code', {}, a.name), h('button', { type: 'button', class: 'btn', 'data-action': 'download-asset', onclick: () => download(a.name, a.content, a.mime) }, 'Download')),
                h('span', { class: 'choice-desc' }, a.description),
                h('details', {}, h('summary', {}, 'Preview'), h('pre', { class: 'preview small' }, a.content)),
              ),
            ),
          ),
          ]),
        );
      }

      clear(files);
      if (result.ok) {
        for (const f of result.embeddedFiles) {
          files.append(h('details', {}, h('summary', {}, h('code', {}, f.path)), h('pre', { class: 'preview small' }, f.content)));
        }
      }
    },
  };
}
