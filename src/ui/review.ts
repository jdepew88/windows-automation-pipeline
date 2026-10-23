import type { GenerateResult } from '../engine/pipeline';
import { ownerDefaults } from '../engine/profiles';
import { diffProfiles, displayValue } from '../engine/profiles/diff';
import type { Profile } from '../engine/schema/profile';
import { resolveIdentity } from '../engine/naming';
import { lookup } from '../data';
import { SETTINGS_BY_PATH } from '../features';
import { isEffective, PHASES } from '../features/scripts';
import { resolveDrivers, type DeploymentAsset } from '../engine/windows-update';
import { allProfiles, installable, resolveSelection } from '../engine/applications/selection';
import type { Issue } from '../engine/validation/issues';
import { clear, download, h } from './dom';
import { icon, type IconName } from './icons';
import { codeView } from './code-view';
import { choicesOf } from './form';
import { PACKAGE_FILE_NAME } from '../engine/deployment';
import { currentPackage, downloadPackage } from './deployment';
import { considerations } from '../engine/quick';

export function labelFor(path: string): string {
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

/** Label of the chosen option, straight from the setting definition. */
function choice(path: string, value: unknown): string {
  const def = SETTINGS_BY_PATH.get(path);
  const label = def ? choicesOf(def).find((c) => c.value === value)?.label : undefined;
  return (label ?? String(value)).replace(/\s*\(owner default\)$/, '');
}

type Tone = 'ok' | 'info' | 'warn' | 'err' | 'muted';

interface Tile {
  key: string;
  label: string;
  icon: IconName;
  value: string;
  detail?: string;
  badge?: [string, Tone];
}

function summaryTiles(p: Profile, result: GenerateResult): Tile[] {
  const id = resolveIdentity(p.accounts);
  const counts = PHASES.map((ph) => [ph.title.replace(' scripts', ''), p.scripts[ph.phase].filter(isEffective).length] as const);
  const scriptTotal = counts.reduce((s, [, n]) => s + n, 0);
  const removed = Object.values(p.bloatware).filter((v) => v === 'remove').length;
  const components = p.advancedXml.components.filter((c) => c.enabled && c.markup.trim()).length;
  const unattended = p.accounts.accountMode === 'unattendedLocal';
  const edition = lookup.edition(p.setup.editionId)?.DisplayName ?? p.setup.editionId;
  const apps = applicationsSummary(p);
  const privacyOff = [p.privacy.disableLocation && 'location', p.privacy.disableAdvertisingId && 'advertising ID', p.privacy.disableCopilot && 'Copilot', p.privacy.disableRecall && 'Recall'].filter(Boolean);

  return [
    {
      key: 'edition',
      label: 'Windows edition',
      icon: 'windows',
      value: p.setup.editionMode === 'genericKey' ? `Windows 11 ${edition}` : choice('setup.editionMode', p.setup.editionMode),
      detail: p.setup.editionMode === 'genericKey' ? 'Generic installation key: selects the edition, does not activate' : undefined,
      badge: [p.setup.editionMode === 'genericKey' ? 'Selected' : p.setup.editionMode === 'interactive' ? 'Interactive' : 'Key', 'ok'],
    },
    {
      key: 'language',
      label: 'Language & region',
      icon: 'globe',
      value: p.setup.languageMode === 'unattended' ? (lookup.imageLanguage(p.setup.imageLanguage)?.DisplayName ?? p.setup.imageLanguage) : 'Chosen interactively',
      detail: p.setup.languageMode === 'unattended' ? `Locale ${p.setup.userLocale}, keyboard ${lookup.keyboard(p.setup.keyboard)?.DisplayName ?? p.setup.keyboard}` : undefined,
      badge: p.setup.languageMode === 'unattended' ? [p.setup.userLocale.split('-').pop() ?? p.setup.userLocale, 'info'] : ['Interactive', 'muted'],
    },
    {
      key: 'disk',
      label: 'Disk configuration',
      icon: 'disk',
      value: 'Interactive (manual)',
      detail: 'You choose and format the partition in Windows Setup',
      badge: ['Interactive', 'ok'],
    },
    {
      key: 'account',
      label: 'Account',
      icon: 'user',
      value: unattended ? `Local ${p.accounts.accountGroup === 'Administrators' ? 'administrator' : 'standard user'}` : p.accounts.accountMode === 'interactiveLocal' ? 'Local account created interactively' : 'Microsoft account (interactive)',
      detail: unattended ? `Username: ${id.username || '?'} (${id.displayName || '?'}) · Password: ${p.accounts.password ? 'set' : 'empty'}` : undefined,
      badge: unattended ? (p.accounts.accountGroup === 'Administrators' ? ['Admin', 'ok'] : ['Standard', 'info']) : ['Interactive', 'muted'],
    },
    {
      key: 'autologon',
      label: 'Automatic sign-in',
      icon: 'login',
      value: unattended ? choice('accounts.autoLogon', p.accounts.autoLogon) : 'n/a',
      badge: unattended ? (p.accounts.autoLogon === 'none' ? ['Off', 'muted'] : ['On', 'ok']) : undefined,
    },
    {
      key: 'computer',
      label: 'Computer name',
      icon: 'monitor',
      value: id.computerName ?? 'Random (Windows-generated)',
      badge: [p.accounts.computerNameMode === 'derived' ? 'Auto' : p.accounts.computerNameMode === 'custom' ? 'Custom' : 'Random', 'info'],
    },
    {
      key: 'uac',
      label: 'User Account Control',
      icon: 'shield',
      value: choice('security.uacLevel', p.security.uacLevel),
    },
    {
      key: 'privacy',
      label: 'Privacy & telemetry',
      icon: 'lock',
      value: choice('privacy.diagnosticData', p.privacy.diagnosticData),
      detail: privacyOff.length ? `Off: ${privacyOff.join(', ')}` : undefined,
      badge: p.privacy.diagnosticData === 'required' ? ['Private', 'ok'] : ['Default', 'muted'],
    },
    {
      key: 'updates',
      label: 'Windows Update',
      icon: 'refresh',
      value: choice('updates.mode', p.updates.mode),
      detail: p.updates.excludeDrivers ? 'Drivers excluded from quality updates' : 'Drivers included with quality updates',
      badge: ['Configured', 'ok'],
    },
    {
      key: 'automation',
      label: 'Update automation',
      icon: 'cloudDown',
      value: p.windowsUpdate.enabled
        ? `On: drivers ${resolveDrivers(p) === 'include' ? 'included' : 'excluded'}, feature updates ${p.windowsUpdate.featureUpdates === 'install' ? 'installed' : 'skipped'}, at most ${p.windowsUpdate.maxReboots} restarts / ${p.windowsUpdate.maxRuntimeHours} h`
        : 'Off',
      badge: p.windowsUpdate.enabled ? ['On', 'ok'] : ['Off', 'muted'],
    },
    {
      key: 'drivers',
      label: 'Hardware & drivers',
      icon: 'chip',
      value: p.drivers.enabled
        ? `On: inspects the hardware on the installed computer, keeps working drivers, ${p.drivers.useWindowsUpdate && p.windowsUpdate.enabled ? 'waits for Windows Update, ' : ''}${p.drivers.resolveMissing ? 'installs only verified drivers where one is missing' : 'reports missing drivers'}`
        : 'Off',
      detail: p.drivers.enabled && p.drivers.bundle && p.drivers.includeOfflinePackages ? `Offline bundle ${p.drivers.bundle.folderName}, ${p.drivers.bundle.packages.length} package(s)` : undefined,
      badge: p.drivers.enabled ? ['On', 'ok'] : ['Off', 'muted'],
    },
    {
      key: 'applications',
      label: 'Applications',
      icon: 'package',
      value: apps.value,
      detail: apps.detail,
      badge: apps.badge,
    },
    {
      key: 'additional',
      label: 'Additional software',
      icon: 'boxPlus',
      value: p.additionalSoftware.items.length ? `${p.additionalSoftware.items.length} installer(s), listed for manual follow-up` : 'None',
      badge: [String(p.additionalSoftware.items.length), p.additionalSoftware.items.length ? 'warn' : 'muted'],
    },
    { key: 'wifi', label: 'Wi-Fi', icon: 'wifi', value: choice('wifi.mode', p.wifi.mode) },
    {
      key: 'bloatware',
      label: 'Apps removed',
      icon: 'trash',
      value: `${removed} app${removed === 1 ? '' : 's'}`,
      detail: 'Built-in apps set to Remove',
      badge: [String(removed), 'muted'],
    },
    {
      key: 'scripts',
      label: 'Custom scripts',
      icon: 'terminal',
      value: scriptTotal ? `${scriptTotal} script(s)` : 'None',
      detail: counts.map(([n, c]) => `${n}: ${c}`).join(' · '),
      badge: [scriptTotal ? String(scriptTotal) : 'None', 'muted'],
    },
    { key: 'components', label: 'Extra components', icon: 'code', value: components ? `${components} component(s)` : 'None', badge: [String(components), 'muted'] },
    {
      key: 'file',
      label: 'File name',
      icon: 'file',
      value: p.output.answerFileName,
      badge: result.ok ? ['Ready', 'ok'] : ['Blocked', 'err'],
    },
  ];
}

function applicationsSummary(p: Profile): { value: string; detail?: string; badge: [string, Tone] } {
  if (!p.applications.enabled) return { value: 'Off', badge: ['Off', 'muted'] };
  const r = resolveSelection(p.applications.selection);
  const ok = installable(r).length;
  const manual = r.packages.filter((x) => x.resolution === 'manual').length;
  const unresolved = r.packages.filter((x) => x.resolution === 'unresolved').length;
  if (r.packages.length === 0) return { value: 'On, nothing selected (nothing is generated)', badge: ['0', 'muted'] };
  const profiles = r.activeProfiles.map((id) => allProfiles(p.applications.selection).find((x) => x.id === id)?.name ?? id);
  return {
    value: `${ok} package(s) via WinGet${profiles.length ? ` from ${profiles.join(' + ')}` : ''}${manual ? `, ${manual} manual follow-up` : ''}${unresolved ? `, ${unresolved} unresolved` : ''}`,
    detail: 'Installed after Windows Update as the signed-in user',
    badge: [String(ok), manual + unresolved ? 'warn' : 'ok'],
  };
}

const ASSET_CATEGORIES: { group: DeploymentAsset['group']; title: string; icon: IconName; empty: string }[] = [
  { group: 'windows-update', title: 'Windows Update scripts & configuration', icon: 'cloudDown', empty: 'None. Windows Update automation is off.' },
  { group: 'drivers', title: 'Hardware & driver engine', icon: 'chip', empty: 'None. Hardware-aware driver provisioning is off.' },
  { group: 'applications', title: 'WinGet provisioning scripts & JSON', icon: 'package', empty: 'None. No applications or Additional Software are selected.' },
  { group: 'orchestration', title: 'Orchestration contracts', icon: 'layers', empty: 'None. Generated with the engines.' },
];

export interface ReviewHandle {
  el: HTMLElement;
  update(p: Profile, result: GenerateResult): void;
}

function flash(btn: HTMLButtonElement, text: string): void {
  const label = btn.querySelector('.btn-label');
  if (!label) return;
  const before = label.textContent;
  label.textContent = text;
  setTimeout(() => (label.textContent = before), 1500);
}

function copy(text: string, btn: HTMLButtonElement): void {
  navigator.clipboard?.writeText(text).then(
    () => flash(btn, 'Copied'),
    () => flash(btn, 'Copy failed'),
  );
}

const card = (cls: string, ...children: (Node | null)[]) => h('section', { class: `card ${cls}` }, ...children);
const cardHead = (title: string, ico: IconName | null, desc: string | null, ...extra: (Node | null)[]) =>
  h('div', { class: 'card-head' }, h('div', { class: 'card-title' }, ico ? icon(ico) : null, h('h3', {}, title)), ...extra, desc ? h('p', { class: 'card-desc' }, desc) : null);

function issueLine(i: Issue): HTMLElement {
  return h(
    'li',
    { class: i.severity },
    icon(i.severity === 'error' ? 'xCircle' : 'alert'),
    h('span', {}, h('a', { href: `#field-${i.path || 'top'}`, 'data-jump': i.path }, labelFor(i.path) || 'Document'), ': ', i.message),
  );
}

export function renderReview(): ReviewHandle {
  const status = h('div', { class: 'status-card', 'data-testid': 'status', 'aria-live': 'polite' });
  const considerationsList = h('ul', { class: 'considerations', 'data-testid': 'advanced-considerations' });
  const summary = h('div', { class: 'summary-grid', 'data-testid': 'summary' });
  const diff = h('div', { class: 'diff', 'data-testid': 'diff' });
  const xml = codeView({ 'data-testid': 'xml-preview', 'aria-label': 'Generated answer file' });
  const files = h('div', { class: 'files' });
  const assets = h('div', { class: 'asset-cats', 'data-testid': 'assets' });
  const issuesList = h('ul', { class: 'issue-list' });
  const issuesCount = h('span', { class: 'pill muted' });
  const issuesTitle = h('h3', {}, 'Warnings');
  const steps = h('ol', { class: 'steps' });
  const assetCount = h('a', { href: '#deployment-assets', class: 'asset-link' });
  let current: GenerateResult | undefined;
  let currentProfile: Profile | undefined;
  let summaryText = '';

  const fileNameLabel = h('span', { class: 'btn-sub' });
  const downloadBtn = h(
    'button',
    {
      type: 'button',
      class: 'btn wide stacked',
      'data-action': 'download-xml',
      onclick: () => current?.ok && current.xml && download(current.fileName, current.xml, 'application/xml'),
    },
    icon('download'),
    h('span', { class: 'btn-stack' }, h('span', { class: 'btn-label' }, 'Download answer file'), fileNameLabel),
  );
  const packageBtn = h(
    'button',
    {
      type: 'button',
      class: 'btn primary hero',
      'data-action': 'download-package',
      onclick: () => {
        const pkg = current && currentProfile ? currentPackage(currentProfile, current) : null;
        if (pkg) downloadPackage(pkg);
      },
    },
    icon('archive'),
    h('span', { class: 'btn-stack' }, h('span', { class: 'btn-label' }, 'Download deployment package'), h('span', { class: 'btn-sub' }, PACKAGE_FILE_NAME)),
  );
  const copyBtn = h('button', { type: 'button', class: 'btn wide', onclick: () => current?.xml && copy(current.xml, copyBtn) }, icon('copy'), h('span', { class: 'btn-label' }, 'Copy XML to clipboard'));
  const copySummaryBtn = h('button', { type: 'button', class: 'btn sm', onclick: () => copy(summaryText, copySummaryBtn) }, icon('copy'), h('span', { class: 'btn-label' }, 'Copy summary'));
  const copyXmlSmall = h('button', { type: 'button', class: 'btn sm ghost', onclick: () => current?.xml && copy(current.xml, copyXmlSmall) }, icon('copy'), h('span', { class: 'btn-label' }, 'Copy'));
  const expandBtn = h(
    'button',
    {
      type: 'button',
      class: 'btn sm ghost',
      'aria-expanded': 'false',
      onclick: () => {
        const open = xml.el.classList.toggle('expanded');
        expandBtn.setAttribute('aria-expanded', String(open));
        expandBtn.querySelector('.btn-label')!.textContent = open ? 'Collapse' : 'Expand';
      },
    },
    h('span', { class: 'btn-label' }, 'Expand'),
    icon('chevronDown'),
  );

  const el = h(
    'section',
    { class: 'page review', id: 'section-review', 'data-page': 'review', 'aria-labelledby': 'review-title' },
    h(
      'header',
      { class: 'page-head' },
      h('div', { class: 'page-icon' }, icon('download')),
      h('div', {}, h('h2', { id: 'review-title' }, 'Review & download'), h('p', { class: 'intro' }, 'Review the configuration, check the validation result and download the answer file and deployment assets.')),
    ),
    h(
      'div',
      { class: 'review-grid' },
      h(
        'div',
        { class: 'review-main' },
        status,
        card('considerations-card', cardHead('Security & licensing considerations', 'shield', 'Risks that apply to this configuration. Quick Deployment asks for confirmation of the critical ones in its Final Review.'), considerationsList),
        card('summary-card', cardHead('Configuration summary', null, 'The settings that matter most, as they will be generated.', copySummaryBtn), summary),
      ),
      h(
        'aside',
        { class: 'review-side' },
        card(
          'actions-card',
          cardHead('Actions', null, 'The deployment package is everything for a USB installation; the answer file alone also works.'),
          h('div', { class: 'action-stack' }, packageBtn, downloadBtn, copyBtn),
          h('a', { href: '#section-deployment', class: 'asset-link' }, icon('usb'), h('span', {}, 'Package contents and USB instructions'), icon('chevronRight')),
          assetCount,
        ),
        card('issues-card', h('div', { class: 'card-head', id: 'review-issues' }, h('div', { class: 'card-title' }, icon('alert'), issuesTitle), issuesCount), issuesList),
        card('steps-card', cardHead('Next steps', null, null), steps),
      ),
    ),
    card(
      'xml-card',
      h(
        'div',
        { class: 'card-head row' },
        h('div', { class: 'card-title' }, icon('code'), h('h3', {}, 'XML preview')),
        h(
          'p',
          { class: 'card-desc' },
          'Well-formed XML that passes these checks still needs testing: validate it with Windows System Image Manager and run a disposable VM installation before using it on real hardware. Copy the file to the root of your installation USB drive manually.',
        ),
        h('div', { class: 'card-tools' }, copyXmlSmall, expandBtn),
      ),
      xml.el,
    ),
    card(
      'assets-card',
      h(
        'div',
        { class: 'card-head', id: 'deployment-assets' },
        h('div', { class: 'card-title' }, icon('archive'), h('h3', {}, 'Deployment assets')),
        h(
          'p',
          { class: 'card-desc' },
          'The engine scripts and their configuration are already embedded in the answer file and installed automatically. Download them to inspect, to run an engine by hand on an installed PC (see each README), or for the future deployment bundle.',
        ),
      ),
      assets,
    ),
    card('diff-card advanced', cardHead('Changes from owner defaults', 'list', null), diff),
    card('files-card advanced', cardHead('Embedded files', 'fileCode', 'Extracted to disk during specialize.'), files),
  );

  return {
    el,
    update(p, result) {
      current = result;
      currentProfile = p;
      clear(considerationsList);
      const cons = considerations(p);
      if (!cons.length) considerationsList.append(h('li', { class: 'empty' }, 'Nothing to consider for this configuration.'));
      for (const c of cons) considerationsList.append(h('li', { class: `consideration ${c.severity}`, 'data-consideration': c.id }, icon(c.severity === 'info' ? 'info' : 'alert'), h('div', {}, h('strong', {}, c.title), h('p', {}, c.detail))));
      const tiles = summaryTiles(p, result);
      clear(summary);
      for (const t of tiles) {
        summary.append(
          h(
            'div',
            { class: 'tile', 'data-summary': t.key },
            h('div', { class: 'tile-icon' }, icon(t.icon)),
            h(
              'div',
              { class: 'tile-body' },
              h('div', { class: 'tile-label' }, t.label),
              h('div', { class: 'tile-value' }, t.value),
              t.detail ? h('div', { class: 'tile-detail' }, t.detail) : null,
            ),
            t.badge ? h('span', { class: `pill ${t.badge[1]}` }, t.badge[0]) : null,
          ),
        );
      }
      summaryText = tiles.map((t) => `${t.label}: ${t.value}${t.detail ? ` (${t.detail})` : ''}`).join('\n');

      clear(diff);
      const changes = diffProfiles(ownerDefaults(), p).filter((c) => c.path !== 'profileName');
      diff.append(
        changes.length === 0
          ? h('p', { class: 'empty' }, 'No changes. This is exactly the owner-default profile.')
          : h(
              'div',
              { class: 'table-wrap' },
              h(
                'table',
                {},
                h('thead', {}, h('tr', {}, h('th', {}, 'Setting'), h('th', {}, 'Owner default'), h('th', {}, 'Current'))),
                h('tbody', {}, changes.map((c) => h('tr', { 'data-diff-path': c.path }, h('td', {}, labelFor(c.path), h('code', { class: 'path' }, c.path)), h('td', {}, displayValue(c.path, c.from)), h('td', {}, displayValue(c.path, c.to))))),
              ),
            ),
      );

      const errors = result.issues.filter((i) => i.severity === 'error');
      const warnings = result.issues.filter((i) => i.severity === 'warning');
      clear(status);
      const tone = !result.ok ? 'error' : warnings.length ? 'warn' : 'ok';
      status.className = `status-card ${tone}`;
      const chip = warnings.length
        ? h('a', { class: 'pill warn chip-link', href: '#review-issues' }, icon('alert'), `${warnings.length} warning${warnings.length === 1 ? '' : 's'}`)
        : null;
      if (result.ok) {
        status.append(
          h('div', { class: 'status-icon' }, icon('check')),
          h(
            'div',
            { class: 'status-body' },
            h('div', { class: 'status-title' }, h('strong', {}, `Ready: ${result.fileName} generated`), chip),
            h('p', {}, warnings.length ? 'The configuration is valid. Review the warnings before you download.' : 'Your configuration is valid and ready to download.'),
            warnings.length ? h('ul', { class: 'status-list' }, warnings.slice(0, 3).map(issueLine)) : null,
          ),
        );
      } else {
        status.append(
          h('div', { class: 'status-icon' }, icon('x')),
          h(
            'div',
            { class: 'status-body' },
            h('div', { class: 'status-title' }, h('strong', {}, `Cannot generate: ${errors.length} problem(s) to fix`), chip),
            h('p', {}, 'Nothing can be downloaded until these settings are fixed. Select one to go to it.'),
            h('ul', { class: 'status-list' }, errors.map(issueLine)),
          ),
        );
      }

      clear(issuesList);
      const all = [...errors, ...warnings];
      issuesTitle.textContent = errors.length ? 'Problems' : 'Warnings';
      issuesCount.textContent = String(all.length);
      issuesCount.className = `pill ${errors.length ? 'err' : warnings.length ? 'warn' : 'ok'}`;
      if (all.length === 0) issuesList.append(h('li', { class: 'none' }, icon('checkCircle'), h('span', {}, 'No warnings.')));
      else issuesList.append(...all.map(issueLine));

      downloadBtn.disabled = !result.ok;
      packageBtn.disabled = !result.ok;
      copyBtn.disabled = !result.ok;
      copyXmlSmall.disabled = !result.ok;
      fileNameLabel.textContent = result.fileName;
      if (result.ok) xml.set(result.xml!, { highlight: true });
      else xml.set('No XML is shown while there are errors.', { placeholder: true });

      clear(steps);
      const engines = [p.windowsUpdate.enabled && 'Windows updates', result.assets.some((a) => a.group === 'applications') && 'the selected applications'].filter(Boolean);
      const stepList: [string, string][] = [
        ['Download the deployment package', `Extract it to the root of your Windows 11 installation USB drive (${result.fileName} next to setup.exe), or let the USB Preparation Assistant place and verify it (Deployment package › Prepare Installation USB).`],
        ['Boot from the installation media', 'Use Windows 11 installation media and start Setup.'],
        ['Choose the disk', 'Setup stops at disk selection: select, create and format the partition yourself.'],
        ...(engines.length ? [['After the first sign-in', `${engines.join(' and ')} install automatically. Logs and results are described in the README files under Deployment assets.`] as [string, string]] : []),
        ['Optional: validate', 'Test the file with Windows System Image Manager (WSIM) or in a disposable VM first.'],
      ];
      stepList.forEach(([title, text], i) => steps.append(h('li', {}, h('span', { class: 'step-num' }, String(i + 1)), h('div', {}, h('strong', {}, title), h('span', {}, text)))));

      clear(assetCount);
      assetCount.append(icon('archive'), h('span', {}, result.ok ? `${result.assets.length} deployment asset${result.assets.length === 1 ? '' : 's'}` : 'Deployment assets'), icon('chevronRight'));

      clear(assets);
      if (!result.ok) {
        assets.append(h('p', { class: 'empty' }, 'Available once the errors above are fixed.'));
      } else {
        if (result.assets.length === 0) assets.append(h('p', { class: 'empty wide' }, 'None. Turn on Windows Update automation or select applications to get the engine scripts.'));
        assets.append(
          h(
            'div',
            { class: 'asset-cat' },
            h('div', { class: 'asset-cat-head' }, icon('fileCode'), h('h4', {}, 'Windows answer file')),
            h(
              'ul',
              { class: 'asset-list' },
              h(
                'li',
                { 'data-answer-file': result.fileName },
                h(
                  'div',
                  { class: 'asset-head' },
                  h('code', {}, result.fileName),
                  h('span', { class: 'asset-size' }, `${Math.ceil(result.xml!.length / 1024)} KB`),
                  h('button', { type: 'button', class: 'btn sm', onclick: () => download(result.fileName, result.xml!, 'application/xml') }, icon('download'), 'Download'),
                ),
                h('span', { class: 'choice-desc' }, 'The answer file shown in the XML preview. Contains the embedded engine files.'),
              ),
            ),
          ),
        );
        for (const cat of ASSET_CATEGORIES) {
          const items = result.assets.filter((a) => a.group === cat.group);
          assets.append(
            h(
              'div',
              { class: 'asset-cat' },
              h('div', { class: 'asset-cat-head' }, icon(cat.icon), h('h4', {}, cat.title), items.length ? h('span', { class: 'pill muted' }, String(items.length)) : null),
              items.length
                ? h(
                    'ul',
                    { class: 'asset-list', 'data-asset-group': cat.group },
                    items.map((a) =>
                      h(
                        'li',
                        { 'data-asset': a.name },
                        h(
                          'div',
                          { class: 'asset-head' },
                          h('code', {}, a.name),
                          h('span', { class: 'asset-size' }, `${Math.max(1, Math.ceil(a.content.length / 1024))} KB`),
                          h('button', { type: 'button', class: 'btn sm', 'data-action': 'download-asset', onclick: () => download(a.name, a.content, a.mime) }, icon('download'), 'Download'),
                        ),
                        h('span', { class: 'choice-desc' }, a.description),
                        h('details', {}, h('summary', {}, 'Preview'), h('pre', { class: 'preview small' }, a.content)),
                      ),
                    ),
                  )
                : h('p', { class: 'empty' }, cat.empty),
            ),
          );
          if (cat.group === 'applications') {
            const n = p.additionalSoftware.items.length;
            assets.append(
              h(
                'div',
                { class: 'asset-cat addl' },
                h('div', { class: 'asset-cat-head' }, icon('boxPlus'), h('h4', {}, 'Additional Software metadata'), n ? h('span', { class: 'pill warn' }, String(n)) : null),
                h(
                  'p',
                  { class: n ? 'choice-desc' : 'empty' },
                  n
                    ? `${n} entr${n === 1 ? 'y is' : 'ies are'} recorded in applications-config.json and listed in applications-plan.txt. No separate file is generated, nothing is downloaded, and every entry becomes a manual follow-up task on the device.`
                    : 'None. Additional Software entries are recorded in applications-config.json when present.',
                ),
              ),
            );
          }
        }
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
