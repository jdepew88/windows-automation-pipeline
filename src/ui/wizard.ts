import type { GenerateResult } from '../engine/pipeline';
import type { Profile } from '../engine/schema/profile';
import type { Issue } from '../engine/validation/issues';
import type { Devices } from '../engine/schema/applications';
import { EDITIONS } from '../data';
import { resolveIdentity, MAX_COMPUTER_NAME, MAX_USERNAME } from '../engine/naming';
import { BUILTIN_PROFILES } from '../engine/applications/builtin';
import { allProfiles, resolveSelection, type SelectionResult } from '../engine/applications/selection';
import { deploymentChecklist, effectiveApps, profilePreview, type ChecklistItem } from '../engine/applications/preview';
import { addPackage, adoptCurrentProfiles, pruneDetached, removePackage, usesEarlierProfiles } from '../engine/applications/profiles';
import { CATALOG } from '../engine/applications/catalog';
import { SETTINGS_BY_PATH } from '../features';
import { BYPASSES, targetsWindows11 } from '../features/setup';
import {
  LAPTOP_PROFILE,
  STEPS,
  ackKey,
  blockingStep,
  computerNameInput,
  considerations,
  customerTypesFor,
  customizedSettings,
  isTypeSelected,
  locationAllowed,
  reviewSummary,
  setComputerNameInput,
  setCustomerType,
  setLocationAllowed,
  setUpdateChoice,
  setUsernameInput,
  stepErrors,
  stepOfIssue,
  stepStatus,
  updateChoice,
  usernameInput,
  type Consideration,
  type StepId,
  type StepStatus,
} from '../engine/quick';
import { appLogo } from './app-icon';
import { createApplicationsEditor, type ApplicationsEditor } from './app-selection';
import { profilePreviewView, selectedAppsSummary } from './app-summary';
import { currentPackage, downloadPackage } from './deployment';
import { clear, h, patchChildren, render as patch, uid } from './dom';
import { icon, type IconName } from './icons';
import type { Store } from './store';

/**
 * Quick Deployment (Phase 4.3): a guided path through the settings that change between
 * customers. It edits the same Store as the Advanced Configuration pages; it has no state of its
 * own except which step is open and which risks were acknowledged in this session.
 */

export interface WizardContext {
  store: Store;
  /** Switches to Advanced Configuration at a section (or a field path). */
  openAdvanced(target: string): void;
  /** Acknowledged risks (ackKey), shared with the Advanced download buttons. */
  acks: Set<string>;
}

export interface WizardHandle {
  el: HTMLElement;
  update(p: Profile, result: GenerateResult): void;
  go(step: StepId): void;
  current(): StepId;
}

const STATUS_LABEL: Record<StepStatus, string> = {
  complete: 'Complete',
  defaults: 'Using defaults',
  customized: 'Customized',
  incomplete: 'Incomplete',
  attention: 'Needs attention',
};
const STATUS_ICON: Record<StepStatus, IconName> = { complete: 'checkCircle', defaults: 'check', customized: 'sliders', incomplete: 'info', attention: 'alert' };
const TYPE_ICON: Record<string, IconName> = { everyday: 'home', gaming: 'gamepad', developer: 'code', 'network-engineer': 'globe', music: 'package', 'student-office': 'file', creator: 'pen', 'remote-support': 'monitor', laptop: 'laptop', touch: 'pen' };

function issueList(issues: Issue[], testid?: string): HTMLElement {
  return h(
    'div',
    { class: 'issues', 'aria-live': 'polite', 'data-testid': testid },
    issues.map((i) => h('p', { class: i.severity, 'data-severity': i.severity }, icon(i.severity === 'error' ? 'xCircle' : i.severity === 'warning' ? 'alert' : 'info'), h('span', {}, i.message))),
  );
}

const customizedNote = (text: string, target: string, ctx: WizardContext) =>
  h('p', { class: 'customized-note', 'data-testid': 'customized-note' }, icon('sliders'), h('span', {}, text, ' '), h('button', { type: 'button', class: 'linkish', 'data-advanced': target, onclick: () => ctx.openAdvanced(target) }, 'Customized in Advanced Settings'));

export function renderWizard(ctx: WizardContext): WizardHandle {
  const { store } = ctx;
  let step: StepId = 'identity';
  let issues: Issue[] = [];
  let resultRef: GenerateResult | undefined;
  const visited = new Set<StepId>(['identity']);
  const mutate = (fn: (p: Profile) => void, structural = true) => store.update(fn, structural);

  // Frame ----------------------------------------------------------------------------------------
  const stepCounter = h('p', { class: 'wiz-count', 'data-testid': 'wizard-count', 'aria-live': 'polite' });
  const titleEl = h('h2', { id: 'wizard-title', tabindex: -1 });
  const blockedMsg = h('div', { class: 'wiz-blocked', 'data-testid': 'wizard-blocked', role: 'alert', hidden: true });
  const progress = h('ol', { class: 'wiz-progress', 'data-testid': 'wizard-progress' });
  const panels = new Map<StepId, HTMLElement>();
  const body = h('div', { class: 'wiz-body' });

  const navButtons = (where: 'top' | 'bottom') => {
    const prev = h('button', { type: 'button', class: 'btn', 'data-wiz': `${where}-back`, onclick: () => go(prevStep()!) }, icon('chevronLeft'), h('span', {}, where === 'top' ? 'Previous' : 'Back'));
    const next = h('button', { type: 'button', class: 'btn primary', 'data-wiz': `${where}-next`, onclick: () => go(nextStep()!) }, h('span', {}, 'Next'), icon('chevronRight'));
    return { prev, next };
  };
  const top = navButtons('top');
  const bottom = navButtons('bottom');
  const appsShortcut = h('button', { type: 'button', class: 'btn ghost', 'data-wiz': 'go-apps', title: 'Skip the remaining defaults and choose applications', onclick: () => go('apps') }, icon('zap'), h('span', {}, 'Go to Applications'));
  const reviewShortcut = h('button', { type: 'button', class: 'btn ghost', 'data-wiz': 'go-review', onclick: () => go('review') }, icon('flag'), h('span', {}, 'Final Review'));
  const advancedLink = h('button', { type: 'button', class: 'btn ghost', 'data-wiz': 'open-advanced', onclick: () => ctx.openAdvanced(advancedTargetFor(step)) }, icon('sliders'), h('span', {}, 'Advanced Configuration'));
  const generateBottom = h('button', { type: 'button', class: 'btn primary', 'data-wiz': 'bottom-generate', onclick: () => generate() }, icon('archive'), h('span', {}, 'Generate Deployment ZIP'));

  const el = h(
    'section',
    { class: 'wizard', 'data-testid': 'wizard', 'aria-labelledby': 'wizard-title' },
    h(
      'header',
      { class: 'wiz-head' },
      h('div', { class: 'wiz-heading' }, h('p', { class: 'wiz-kicker' }, icon('zap'), 'Quick Deployment'), titleEl, stepCounter),
      h('nav', { class: 'wiz-topnav', 'aria-label': 'Wizard navigation (top)' }, top.prev, appsShortcut, reviewShortcut, advancedLink, top.next),
    ),
    progress,
    blockedMsg,
    body,
    h('nav', { class: 'wiz-bottomnav', 'aria-label': 'Wizard navigation (bottom)' }, bottom.prev, h('span', { class: 'spacer' }), bottom.next, generateBottom),
  );

  const index = (s: StepId) => STEPS.findIndex((x) => x.id === s);
  const prevStep = () => STEPS[index(step) - 1]?.id;
  const nextStep = () => STEPS[index(step) + 1]?.id;
  const advancedTargetFor = (s: StepId) => ({ identity: 'section-accounts', type: 'app-profiles', network: 'section-wifi', apps: 'section-applications', review: 'section-review' })[s];

  /** One navigation function for every button: forward moves validate every step before the target. */
  function go(target: StepId, focus = true): void {
    const p = store.get();
    blockedMsg.hidden = true;
    if (index(target) > index(step) || target === 'review') {
      const blocking = blockingStep(p, issues, target);
      if (blocking && index(blocking) <= index(target) && blocking !== target) {
        const info = STEPS.find((s) => s.id === blocking)!;
        clear(blockedMsg);
        blockedMsg.append(icon('alert'), h('span', {}, h('strong', {}, `${info.title} needs attention. `), stepErrors(issues, blocking)[0]?.message ?? 'Fill in the required fields first.'));
        blockedMsg.hidden = false;
        target = blocking;
      }
    }
    step = target;
    visited.add(target);
    render(focus);
    if (!blockedMsg.hidden) panels.get(step)?.querySelector<HTMLElement>('.has-error input, [aria-invalid="true"]')?.focus();
  }

  // Step 1: computer and local account ----------------------------------------------------------
  const userId = uid('wu');
  const pcId = uid('wc');
  const userInput = h('input', { type: 'text', id: userId, class: 'big-input', autocomplete: 'off', spellcheck: 'false', maxlength: 64, 'data-testid': 'wiz-username', 'aria-describedby': `${userId}-h`, oninput: () => mutate((p) => setUsernameInput(p, userInput.value), false) });
  const pcInput = h('input', { type: 'text', id: pcId, class: 'big-input', autocomplete: 'off', spellcheck: 'false', maxlength: 64, 'data-testid': 'wiz-computername', 'aria-describedby': `${pcId}-h`, oninput: () => mutate((p) => setComputerNameInput(p, pcInput.value), false) });
  const userIssues = h('div', {});
  const pcIssues = h('div', {});
  const userDerived = h('p', { class: 'derived', id: `${userId}-h`, 'data-testid': 'wiz-identity' });
  const pcDerived = h('p', { class: 'derived', id: `${pcId}-h` });
  const pcReset = h('button', { type: 'button', class: 'linkish', 'data-action': 'wiz-computer-default', onclick: () => mutate((p) => setComputerNameInput(p, '')) }, 'Use the default name');
  const winSummary = h('span', { class: 'win-summary', 'data-testid': 'wiz-windows-summary' });
  const winBox = h('div', { class: 'win-box' });

  const identityPanel = h(
    'div',
    { class: 'wiz-panel', 'data-step': 'identity' },
    h(
      'div',
      { class: 'form-2col' },
      h('div', { class: 'f-field' }, h('label', { for: userId, class: 'f-label' }, 'Local account username'), userInput, userDerived, userIssues),
      h('div', { class: 'f-help' }, h('strong', {}, 'The Windows sign-in account'), h('p', {}, `The local account this answer file creates and signs in to. It is also shown as the display name. Up to ${MAX_USERNAME} characters are used; letters, digits, period, hyphen and underscore are kept.`)),
      h('div', { class: 'f-field' }, h('label', { for: pcId, class: 'f-label' }, 'Computer name'), pcInput, pcDerived, pcReset, pcIssues),
      h('div', { class: 'f-help' }, h('strong', {}, 'How the PC appears on the network'), h('p', {}, `At most ${MAX_COMPUTER_NAME} characters: letters, digits and hyphens, not only digits. By default it is derived from the account name (Name-Computer).`)),
    ),
    h('details', { class: 'win-defaults', 'data-testid': 'wiz-windows' }, h('summary', {}, icon('windows'), h('span', {}, h('strong', {}, 'Windows settings'), ' ', winSummary)), winBox),
  );
  panels.set('identity', identityPanel);

  function renderWindowsBox(p: Profile): void {
    clear(winBox);
    const editionSel = uid('we');
    const editions = EDITIONS.filter((e) => e.Visible);
    const choice = updateChoice(p);
    const priv = customizedSettings(p, ['privacy.']);
    const radio = (value: 'recommended' | 'notify', label: string, desc: string) => {
      const rid = uid('wr');
      return h(
        'label',
        { class: 'choice', for: rid },
        h('input', { type: 'radio', id: rid, name: 'wiz-update', value, 'data-testid': `wiz-update-${value}`, checked: choice === value, onchange: () => mutate((q) => setUpdateChoice(q, value)) }),
        h('span', { class: 'choice-text' }, h('span', { class: 'choice-label' }, label), h('span', { class: 'choice-desc' }, desc)),
      );
    };
    const customRid = uid('wr');
    winBox.append(
      h(
        'div',
        { class: 'win-grid' },
        h(
          'div',
          { class: 'f-field' },
          h('label', { for: editionSel, class: 'f-label' }, 'Windows edition'),
          p.setup.editionMode === 'genericKey'
            ? h('select', { id: editionSel, 'data-testid': 'wiz-edition', onchange: (e: Event) => mutate((q) => (q.setup.editionId = (e.target as HTMLSelectElement).value)) }, editions.map((e) => h('option', { value: e.Id, selected: e.Id === p.setup.editionId }, `Windows 11 ${e.DisplayName}`)))
            : customizedNote(p.setup.editionMode === 'interactive' ? 'Chosen during Setup.' : 'From a product key.', 'setup.editionMode', ctx),
          h('p', { class: 'desc' }, 'The edition must be on your installation media; an answer file cannot add one the ISO does not contain.'),
          targetsWindows11(p)
            ? h(
                'fieldset',
                { class: 'wiz-bypass', 'data-testid': 'wiz-bypass' },
                h('legend', { class: 'f-label' }, 'Windows 11 hardware checks'),
                BYPASSES.map(([path, label]) => {
                  const key = path.slice('setup.'.length) as 'bypassTpmCheck' | 'bypassCpuCheck' | 'bypassSecureBootCheck';
                  return h(
                    'label',
                    { class: 'check-row' },
                    h('input', { type: 'checkbox', 'data-testid': `wiz-${key}`, 'data-path': path, checked: p.setup[key], onchange: (e: Event) => mutate((q) => (q.setup[key] = (e.target as HTMLInputElement).checked)) }),
                    h('span', {}, label),
                  );
                }),
                h('p', { class: 'desc' }, 'Off by default. Only for VMs or unsupported hardware: Microsoft does not support Windows 11 on devices that fail these checks, and they may not receive updates.'),
              )
            : null,
        ),
        h(
          'div',
          { class: 'f-field' },
          h('span', { class: 'f-label' }, 'Architecture'),
          h('p', { class: 'static-value', 'data-testid': 'wiz-arch' }, p.setup.processorArchitectures.map((a) => (a === 'amd64' ? 'x64 (64-bit Intel/AMD)' : a === 'arm64' ? 'Arm64' : 'x86')).join(', ')),
          JSON.stringify(p.setup.processorArchitectures) === '["amd64"]' ? h('p', { class: 'desc' }, 'Windows 11 is 64-bit only. 32-bit programs still run; the x86 Visual C++ runtime stays in Core Essentials for them.') : customizedNote('Not the x64 default.', 'setup.processorArchitectures', ctx),
        ),
        h(
          'div',
          { class: 'f-field span-2' },
          h(
            'label',
            { class: 'check-row' },
            h('input', { type: 'checkbox', 'data-testid': 'wiz-region', checked: p.setup.languageMode === 'unattended', onchange: (e: Event) => mutate((q) => (q.setup.languageMode = (e.target as HTMLInputElement).checked ? 'unattended' : 'interactive')) }),
            h('span', {}, h('strong', {}, "Use the deployment's predefined region and keyboard settings"), h('span', { class: 'choice-desc' }, p.setup.languageMode === 'unattended' ? ` ${reviewSummary(p).computer.locale}; ${reviewSummary(p).computer.keyboard}. Setup skips the region and keyboard pages. Change them in Advanced › Setup, region & edition.` : ' Off: Windows Setup asks for language, region and keyboard.')),
          ),
        ),
        h(
          'fieldset',
          { class: 'f-field span-2' },
          h('legend', { class: 'f-label' }, 'Windows Update after the deployment'),
          h('p', { class: 'desc' }, 'The initial updates during the deployment are automatic either way (Update automation). This is what Windows does afterwards.'),
          h(
            'div',
            { class: 'choices' },
            radio('notify', 'Download automatically; notify before installing', 'Owner preference. Applied once the initial updates have finished. Security fixes wait until someone installs them.'),
            radio('recommended', 'Windows recommended defaults', 'Automatic security updates with normal restart protections.'),
            h(
              'label',
              { class: 'choice', for: customRid },
              h('input', { type: 'radio', id: customRid, name: 'wiz-update', value: 'custom', 'data-testid': 'wiz-update-custom', checked: choice === 'custom', onchange: () => ctx.openAdvanced('section-updates') }),
              h('span', { class: 'choice-text' }, h('span', { class: 'choice-label' }, 'Advanced / custom policy'), h('span', { class: 'choice-desc' }, choice === 'custom' ? 'In use: set in Advanced › Windows Update.' : 'Opens the Windows Update page in Advanced Configuration.')),
            ),
          ),
        ),
        h(
          'div',
          { class: 'f-field span-2' },
          h('span', { class: 'f-label' }, 'Privacy'),
          priv.length === 0 ? h('p', { class: 'static-value', 'data-testid': 'wiz-privacy' }, 'Owner privacy defaults (required diagnostic data only; advertising ID, tailored experiences, suggestions, Copilot and Recall off).') : customizedNote(`${priv.length} setting${priv.length === 1 ? '' : 's'} changed: ${priv.map((x) => x.label).join('; ')}.`, 'section-privacy', ctx),
        ),
      ),
    );
    const s = reviewSummary(p);
    winSummary.textContent = `${s.computer.edition} · ${s.computer.architecture} · ${p.setup.languageMode === 'unattended' ? (s.computer.locale.split(' · ')[0] ?? '') : 'region chosen in Setup'} · updates: ${choice === 'notify' ? 'download, ask to install' : choice === 'recommended' ? 'Windows defaults' : 'custom'}`;
  }

  function updateIdentity(p: Profile): void {
    if (document.activeElement !== userInput) userInput.value = usernameInput(p);
    if (document.activeElement !== pcInput) pcInput.value = computerNameInput(p);
    pcInput.disabled = p.accounts.computerNameMode === 'random';
    const id = resolveIdentity(p.accounts);
    userDerived.textContent = p.accounts.accountMode === 'unattendedLocal' ? `Username: ${id.username || '—'} · Display name: ${id.displayName || '—'}` : 'The account is created interactively during setup (Advanced › Account & computer name).';
    pcDerived.textContent = p.accounts.computerNameMode === 'random' ? 'Random name chosen by Windows (Advanced › Account & computer name).' : p.accounts.computerNameMode === 'custom' ? 'Your own name.' : `Default: derived from the account name.`;
    pcReset.hidden = p.accounts.computerNameMode !== 'custom';
    const uIss = issues.filter((i) => ['accounts.personName', 'accounts.customUsername', 'accounts.usernameMode'].includes(i.path));
    const cIss = issues.filter((i) => ['accounts.customComputerName', 'accounts.computerNameMode'].includes(i.path));
    clear(userIssues);
    userIssues.append(issueList(uIss, 'wiz-username-issues'));
    clear(pcIssues);
    pcIssues.append(issueList(cIss, 'wiz-computername-issues'));
    userInput.setAttribute('aria-invalid', String(uIss.some((i) => i.severity === 'error')));
    pcInput.setAttribute('aria-invalid', String(cIss.some((i) => i.severity === 'error')));
    userInput.closest('.f-field')!.classList.toggle('has-error', uIss.some((i) => i.severity === 'error'));
    pcInput.closest('.f-field')!.classList.toggle('has-error', cIss.some((i) => i.severity === 'error'));
    if (!winBox.contains(document.activeElement)) renderWindowsBox(p);
  }

  // Step 2: computer and customer type ----------------------------------------------------------
  const typeGrid = h('div', { class: 'type-grid', 'data-testid': 'wiz-types' });
  const typeLegacy = h('div', { class: 'callout', 'data-testid': 'wiz-legacy-profiles', hidden: true });
  const deviceBox = h('div', { class: 'devices wiz-devices', 'data-testid': 'wiz-devices' });
  const deviceNote = h('div', { class: 'device-note', 'aria-live': 'polite', 'data-testid': 'wiz-device-note' });
  const locationBox = h('div', { 'data-testid': 'wiz-location' });
  const checklistBox = h('section', { class: 'app-checklist', 'data-testid': 'wiz-checklist', 'aria-labelledby': 'wiz-checklist-title' });
  // Which profile previews are open (view state of this session only, never part of the profile).
  const openPreviews = new Set<string>();
  panels.set(
    'type',
    h(
      'div',
      { class: 'wiz-panel', 'data-step': 'type' },
      h('p', { class: 'wiz-lead' }, 'Tick every profile that fits: their applications are combined and each is installed once. Review the combined list below, untick what is not needed, or browse the whole catalog to add more. Built-in profiles are never changed.'),
      typeLegacy,
      typeGrid,
      checklistBox,
      locationBox,
      h('h3', { class: 'wiz-sub' }, icon('laptop'), 'Phones and tablets'),
      h('p', { class: 'desc' }, 'Apple and Android can be combined. Only the kind of device is recorded.'),
      deviceBox,
      deviceNote,
    ),
  );

  function renderType(p: Profile): void {
    const focusKey = (document.activeElement as HTMLElement | null)?.dataset?.wizKey;
    const sel = p.applications.selection;
    const r = resolveSelection(sel);
    const profiles = allProfiles(sel);
    const core = profiles.find((x) => x.id === 'core')!;
    // Selecting (the checkbox) and viewing (the button) are separate controls: viewing a profile's
    // applications never ticks or unticks it.
    const card = (profile: string, label: string, hint: string, ico: IconName) => {
      const id = uid('wt');
      const on = isTypeSelected(p, profile);
      const pv = profilePreview(sel, profile, r);
      const open = !!pv && openPreviews.has(profile);
      const regionId = `wiz-preview-${profile}`;
      return h(
        'div',
        { class: `type-item${on ? ' on' : ''}${open ? ' open' : ''}`, 'data-key': `type-item-${profile}` },
        h(
          'label',
          { class: `type-card${on ? ' on' : ''}`, for: id, 'data-type': profile },
          h('input', { type: 'checkbox', id, checked: on, 'data-wiz-key': `type-${profile}`, onchange: (e: Event) => mutate((q) => setCustomerType(q, profile, (e.target as HTMLInputElement).checked)) }),
          h('span', { class: 'type-icon' }, icon(ico)),
          h('span', { class: 'type-text' }, h('strong', {}, label), h('span', { class: 'choice-desc' }, hint)),
          h('span', { class: 'tile-mark', 'aria-hidden': 'true' }, icon('check')),
        ),
        pv
          ? h(
              'button',
              {
                type: 'button',
                class: 'linkish type-view',
                'data-action': 'view-apps',
                'data-view-apps': profile,
                'data-wiz-key': `view-${profile}`,
                'aria-expanded': String(open),
                'aria-controls': open ? regionId : undefined,
                'aria-label': `${open ? 'Hide' : 'View'} the applications of ${label} (${pv.count})`,
                onclick: () => {
                  if (openPreviews.has(profile)) openPreviews.delete(profile);
                  else openPreviews.add(profile);
                  renderType(store.get());
                },
              },
              icon(open ? 'chevronUp' : 'chevronDown'),
              open ? 'Hide applications' : `View applications (${pv.count})`,
            )
          : null,
        open && pv ? profilePreviewView(pv, regionId) : null,
      );
    };
    const cards: HTMLElement[] = [];
    cards.push(card('core', 'Core Essentials (every computer)', `${core.packages.map((x) => x.displayName.replace(/ \(.*\)$/, '')).filter((v, i, a) => a.indexOf(v) === i).slice(0, 6).join(', ')} and the Visual C++ runtimes`, 'star'));
    for (const t of customerTypesFor(sel)) cards.push(card(t.profile, t.label, t.hint, TYPE_ICON[t.profile] ?? 'layers'));
    // Saved profiles (this browser's library or imported) are offered next to the built-in types.
    const saved = sel.profiles;
    if (saved.length) {
      cards.push(h('h3', { class: 'wiz-sub span-all', 'data-key': 'saved-head' }, icon('folder'), 'Saved profiles'));
      for (const c of saved) cards.push(card(c.id, c.name, c.description || `Saved profile · ${c.packages.length} app${c.packages.length === 1 ? '' : 's'}`, 'folder'));
    }
    // Patched, not rebuilt: the cards stay the same elements, so the page keeps its scroll position.
    patchChildren(typeGrid, cards);
    renderTypeLegacy(p);

    // The combined selection after every ticked profile, device answer and individual change, one
    // checkbox per application. Unticking keeps the profile; it is the same removal as in Applications.
    renderChecklist(p, r);

    const laptop = isTypeSelected(p, LAPTOP_PROFILE);
    const loc: HTMLElement[] = [];
    if (laptop) {
      loc.push(
        h(
          'label',
          { class: 'check-row callout' },
          h('input', { type: 'checkbox', 'data-testid': 'wiz-location-toggle', 'data-wiz-key': 'location', checked: locationAllowed(p), onchange: (e: Event) => mutate((q) => setLocationAllowed(q, (e.target as HTMLInputElement).checked)) }),
          h('span', {}, h('strong', {}, 'Allow location services on this laptop'), h('span', { class: 'choice-desc' }, ' Useful when the laptop travels: Find my device, maps, weather and automatic time zone. This removes the "turn off location" policy only; the user turns location on in Settings › Privacy & security › Location, and Windows still asks before apps use it. The other privacy settings stay as they are.')),
        ),
      );
    } else if (locationAllowed(p)) {
      loc.push(customizedNote('Location services are allowed.', 'privacy.disableLocation', ctx));
    }
    patchChildren(locationBox, loc);

    const d = p.applications.selection.devices;
    const setDev = (fn: (x: Devices) => void) =>
      mutate((q) => {
        fn(q.applications.selection.devices);
        pruneDetached(q.applications.selection);
      });
    const phone = (value: Devices['phone'], label: string) => {
      const id = uid('wp');
      return h('label', { class: 'device-choice', for: id }, h('input', { type: 'radio', id, name: 'wiz-phone', 'data-device': `phone-${value}`, 'data-wiz-key': `phone-${value}`, checked: d.phone === value, onchange: () => setDev((x) => (x.phone = value)) }), label);
    };
    const extra = (key: 'ipad' | 'extraIphone' | 'androidTablet', label: string) => {
      const id = uid('wd');
      return h('label', { class: 'device-choice', for: id }, h('input', { type: 'checkbox', id, 'data-device': key, 'data-wiz-key': key, checked: d[key], onchange: (e: Event) => setDev((x) => (x[key] = (e.target as HTMLInputElement).checked)) }), label);
    };
    patchChildren(deviceBox, [
      h('fieldset', { class: 'device-group' }, h('legend', {}, 'Smartphone'), h('div', { class: 'device-row' }, phone('iphone', 'iPhone'), phone('android', 'Android phone'), phone('none', 'Other / none'))),
      h('fieldset', { class: 'device-group' }, h('legend', {}, 'Other devices'), h('div', { class: 'device-row' }, extra('ipad', 'iPad'), extra('extraIphone', 'Additional iPhone'), extra('androidTablet', 'Android tablet'))),
    ]);
    patch(deviceNote, (into) => {
      if (r.deviceProfiles.length === 0) into.append(h('p', { class: 'desc' }, 'No device recommendations.'));
      for (const id of r.deviceProfiles) {
        const dp = BUILTIN_PROFILES.find((x) => x.id === id);
        if (dp) into.append(h('p', { class: 'info', 'data-device-profile': id }, icon('info'), h('span', {}, h('strong', {}, `${dp.name}: `), dp.description)));
      }
    });
    if (focusKey) el.querySelector<HTMLElement>(`[data-wiz-key="${CSS.escape(focusKey)}"]`)?.focus({ preventScroll: true });
  }

  function renderChecklist(p: Profile, r: SelectionResult): void {
    const sel = p.applications.selection;
    const apps = effectiveApps(sel, p.applications.enabled, r, p.additionalSoftware.items);
    const list = deploymentChecklist(sel, r);
    // Ticking again restores what this deployment left out; it never ticks or unticks a profile.
    const toggle = (x: ChecklistItem, on: boolean) =>
      mutate((q) => {
        const s = q.applications.selection;
        if (!on) return removePackage(s, x.key);
        const ref = resolveSelection(s).removed.find((y) => y.key === x.key)?.ref;
        if (ref) addPackage(s, ref);
        pruneDetached(s);
      });
    const row = (x: ChecklistItem) => {
      const id = `wiz-app-${x.key.replace(/[^a-z0-9]+/gi, '-')}`;
      const note = !x.selected
        ? `${x.excludedBy} · ${x.origin}`
        : [x.origin, x.kind === 'manual' ? 'Manual follow-up' : x.kind === 'unresolved' ? 'Cannot be installed' : ''].filter(Boolean).join(' · ');
      return h(
        'li',
        { class: `app-check kind-${x.kind}${x.selected ? '' : ' off'}`, 'data-key': x.key, 'data-kind': x.kind, 'data-selected': String(x.selected) },
        h(
          'label',
          { for: id, title: `${x.displayName}: ${note}` },
          h('input', {
            type: 'checkbox',
            id,
            checked: x.selected,
            'data-check-app': x.key,
            'data-wiz-key': `app-${x.key}`,
            'aria-describedby': `${id}-n`,
            onchange: (e: Event) => toggle(x, (e.target as HTMLInputElement).checked),
          }),
          appLogo(x.catalogId, x.displayName, x.category, 'sm'),
          h('span', { class: 'app-sum-text' }, h('span', { class: 'app-sum-name' }, x.displayName), h('span', { class: 'app-sum-note', id: `${id}-n` }, note)),
          x.kind === 'manual' ? h('span', { class: 'app-sum-flag', title: 'Manual follow-up: not installed automatically' }, icon('hand')) : null,
        ),
      );
    };
    const warnings = [...r.groupConflicts.map((c) => c.message), ...r.notices.filter((n) => n.kind === 'warning').map((n) => n.message)];
    const headline = !apps.enabled
      ? 'Application provisioning is off: nothing is installed, whatever is ticked. Turn it on in Advanced › Applications.'
      : apps.total === 0
        ? 'No applications are selected.'
        : `${apps.total} application${apps.total === 1 ? '' : 's'} selected: ${apps.automatic.length} installed automatically${apps.manual.length ? `, ${apps.manual.length} manual follow-up` : ''}${apps.unresolved.length ? `, ${apps.unresolved.length} cannot be installed` : ''}${apps.additional.length ? `, ${apps.additional.length} Additional Software` : ''}.`;
    patchChildren(checklistBox, [
      h(
        'h3',
        { class: 'wiz-sub', id: 'wiz-checklist-title', 'data-key': 'checklist-title' },
        icon('layers'),
        'Applications in this deployment',
        h('span', { class: 'chip-count', 'data-testid': 'wiz-app-count', 'data-count': String(apps.total) }, String(apps.total)),
      ),
      h('p', { class: `app-sum-count${apps.total ? '' : ' empty'}`, 'data-testid': 'wiz-checklist-count', 'aria-live': 'polite', 'data-key': 'checklist-count' }, headline),
      h('p', { class: 'desc', 'data-key': 'checklist-desc' }, 'Every ticked profile and device answer together; an app several profiles select is listed and installed once. Untick an app to leave it out without unticking its profile.'),
      list.items.length ? h('ul', { class: 'app-check-grid', 'data-testid': 'wiz-checklist-list', 'aria-label': 'Applications in this deployment' }, list.items.map(row)) : null,
      apps.additional.length
        ? h(
            'ul',
            { class: 'app-check-grid', 'data-testid': 'wiz-checklist-additional', 'aria-label': 'Additional Software' },
            apps.additional.map((x) =>
              h(
                'li',
                { class: `app-check kind-${x.kind}`, 'data-key': x.key, 'data-kind': x.kind },
                h('span', { class: 'app-check-static' }, appLogo(undefined, x.displayName, undefined, 'sm'), h('span', { class: 'app-sum-text' }, h('span', { class: 'app-sum-name' }, x.displayName), h('span', { class: 'app-sum-note' }, `${x.origin} · change it in Advanced`))),
              ),
            ),
          )
        : null,
      warnings.length ? h('div', { class: 'issues', 'data-testid': 'wiz-checklist-warnings', 'data-key': 'checklist-warnings' }, warnings.map((m) => h('p', { class: 'warning' }, icon('alert'), h('span', {}, m)))) : null,
      list.recommended
        ? h(
            'p',
            { class: 'desc', 'data-key': 'checklist-more' },
            `${list.recommended} more app${list.recommended === 1 ? ' is' : 's are'} recommended by these profiles. `,
            h('button', { type: 'button', class: 'linkish', 'data-wiz': 'checklist-apps', onclick: () => go('apps') }, 'Choose them in Applications'),
          )
        : null,
      // The whole shared catalog is always one click away, in Quick Deployment too.
      h(
        'p',
        { class: 'desc', 'data-key': 'checklist-browse' },
        h('button', { type: 'button', class: 'btn sm', 'data-wiz': 'browse-all-apps', onclick: () => { go('apps'); editor.showAll(); } }, icon('search'), `Browse all ${CATALOG.length} applications`),
        ' Search by name, publisher or category and tick any app to add it.',
      ),
    ]);
  }

  /** An older deployment keeps the earlier built-in profile defaults until the technician adopts the new ones. */
  function renderTypeLegacy(p: Profile): void {
    const legacy = usesEarlierProfiles(p.applications.selection);
    typeLegacy.hidden = !legacy;
    patchChildren(
      typeLegacy,
      legacy
        ? [
            icon('info'),
            h(
              'span',
              { 'data-key': 'legacy-text' },
              'This deployment uses the earlier profile defaults, so its profiles select exactly what they did when it was saved. ',
              h('button', { type: 'button', class: 'btn sm', 'data-wiz': 'adopt-profile-defaults', 'data-key': 'legacy-adopt', onclick: () => mutate((q) => adoptCurrentProfiles(q.applications.selection)) }, 'Use the new profile defaults'),
            ),
          ]
        : [],
    );
  }

  // Step 3: network ------------------------------------------------------------------------------
  const ssidId = uid('ws');
  const pwId = uid('wpw');
  const ssidInput = h('input', { type: 'text', id: ssidId, class: 'big-input', autocomplete: 'off', spellcheck: 'false', 'data-testid': 'wiz-ssid', oninput: () => mutate((p) => (p.wifi.ssid = ssidInput.value), false) });
  const pwInput = h('input', { type: 'password', id: pwId, class: 'big-input', autocomplete: 'new-password', spellcheck: 'false', 'data-testid': 'wiz-wifi-password', 'data-private': 'true', oninput: () => mutate((p) => (p.wifi.password = pwInput.value), false) });
  const pwToggle = h(
    'button',
    {
      type: 'button',
      class: 'btn sm pw-toggle',
      'aria-controls': pwId,
      'aria-pressed': 'false',
      'data-testid': 'wiz-wifi-show',
      onclick: () => {
        const show = pwInput.type === 'password';
        pwInput.type = show ? 'text' : 'password';
        pwToggle.setAttribute('aria-pressed', String(show));
        clear(pwToggle);
        pwToggle.append(icon(show ? 'eyeOff' : 'eye'), h('span', {}, show ? 'Hide' : 'Show'));
      },
    },
    icon('eye'),
    h('span', {}, 'Show'),
  );
  const netChoices = h('div', { class: 'choices', role: 'radiogroup', 'aria-label': 'Wi-Fi', 'data-testid': 'wiz-wifi-mode' });
  const wifiForm = h('div', { class: 'wifi-form', 'data-testid': 'wiz-wifi-form' });
  const wifiOptions = h('div', {});
  const ssidIssues = h('div', {});
  const pwIssues = h('div', {});
  wifiForm.append(
    h(
      'div',
      { class: 'form-2col' },
      h('div', { class: 'f-field' }, h('label', { for: ssidId, class: 'f-label' }, 'Wi-Fi network name (SSID)'), ssidInput, ssidIssues),
      h('div', { class: 'f-help' }, h('p', {}, 'Exactly as the router broadcasts it. Spaces, quotes and non-Latin characters are fine.')),
      h('div', { class: 'f-field' }, h('label', { for: pwId, class: 'f-label' }, 'Wi-Fi password'), h('div', { class: 'pw-row' }, pwInput, pwToggle), pwIssues),
      h('div', { class: 'f-help' }, h('p', {}, 'Masked here and never saved in this browser or in exported profiles. It is written in plain text into the package; see Final Review.')),
    ),
    wifiOptions,
  );
  panels.set(
    'network',
    h(
      'div',
      { class: 'wiz-panel', 'data-step': 'network' },
      h('p', { class: 'wiz-lead' }, 'Ethernet needs nothing here. Configure Wi-Fi only when the computer should join a wireless network by itself. Other network options are in Advanced › Wi-Fi.'),
      netChoices,
      wifiForm,
    ),
  );

  function renderNetworkChoices(p: Profile): void {
    clear(netChoices);
    const opt = (mode: Profile['wifi']['mode'], label: string, desc: string) => {
      const id = uid('wn');
      return h(
        'label',
        { class: `choice${p.wifi.mode === mode ? ' on' : ''}`, for: id },
        h('input', { type: 'radio', id, name: 'wiz-wifi', value: mode, 'data-testid': `wiz-wifi-${mode}`, checked: p.wifi.mode === mode, onchange: () => mutate((q) => (q.wifi.mode = mode)) }),
        h('span', { class: 'choice-text' }, h('span', { class: 'choice-label' }, label), h('span', { class: 'choice-desc' }, desc)),
      );
    };
    netChoices.append(
      opt('interactive', 'Skip Wi-Fi configuration (default)', 'Nothing is stored. If no network is connected, Windows shows its own Wi-Fi page during setup.'),
      opt('parameters', 'Configure a Wi-Fi network', 'Enter the network name and password now; the computer joins it during setup when it has a Wi-Fi driver.'),
    );
    if (p.wifi.mode === 'skip' || p.wifi.mode === 'profileXml') netChoices.append(opt(p.wifi.mode, p.wifi.mode === 'skip' ? 'Hide the Wi-Fi page during setup' : 'WLAN profile XML', 'Customized in Advanced Settings (Advanced › Wi-Fi).'));
    wifiForm.hidden = p.wifi.mode !== 'parameters';
    if (!wifiForm.hidden && !wifiOptions.contains(document.activeElement)) {
      clear(wifiOptions);
      const sec = uid('wsec');
      wifiOptions.append(
        h(
          'details',
          { class: 'wifi-more', open: p.wifi.authentication !== 'WPA2PSK' || p.wifi.nonBroadcast ? true : undefined },
          h('summary', {}, 'More Wi-Fi options'),
          h(
            'div',
            { class: 'win-grid' },
            h('div', { class: 'f-field' }, h('label', { for: sec, class: 'f-label' }, 'Security'), h('select', { id: sec, 'data-testid': 'wiz-wifi-auth', onchange: (e: Event) => mutate((q) => (q.wifi.authentication = (e.target as HTMLSelectElement).value as Profile['wifi']['authentication'])) }, [['WPA2PSK', 'WPA2-Personal (AES)'], ['WPA3SAE', 'WPA3-Personal (with WPA2 transition)'], ['open', 'Open (no password)']].map(([v, l]) => h('option', { value: v, selected: p.wifi.authentication === v }, l!)))),
            h('label', { class: 'check-row' }, h('input', { type: 'checkbox', 'data-testid': 'wiz-wifi-hidden', checked: p.wifi.nonBroadcast, onchange: (e: Event) => mutate((q) => (q.wifi.nonBroadcast = (e.target as HTMLInputElement).checked)) }), h('span', {}, h('strong', {}, 'Hidden network'), h('span', { class: 'choice-desc' }, ' Connect even if the network does not broadcast its name.'))),
            h('label', { class: 'check-row' }, h('input', { type: 'checkbox', 'data-testid': 'wiz-wifi-auto', checked: p.wifi.connectAutomatically, onchange: (e: Event) => mutate((q) => (q.wifi.connectAutomatically = (e.target as HTMLInputElement).checked)) }), h('span', {}, h('strong', {}, 'Connect automatically'), h('span', { class: 'choice-desc' }, ' Join the network as soon as the profile is added.'))),
          ),
        ),
      );
    }
  }

  function updateNetwork(p: Profile): void {
    if (!netChoices.contains(document.activeElement)) renderNetworkChoices(p);
    else wifiForm.hidden = p.wifi.mode !== 'parameters';
    if (document.activeElement !== ssidInput) ssidInput.value = p.wifi.ssid;
    if (document.activeElement !== pwInput) pwInput.value = p.wifi.password;
    pwInput.closest<HTMLElement>('.f-field')!.hidden = p.wifi.authentication === 'open';
    const sIss = issues.filter((i) => i.path === 'wifi.ssid');
    const pIss = issues.filter((i) => i.path === 'wifi.password');
    clear(ssidIssues);
    ssidIssues.append(issueList(sIss, 'wiz-ssid-issues'));
    clear(pwIssues);
    pwIssues.append(issueList(pIss, 'wiz-wifi-password-issues'));
    ssidInput.setAttribute('aria-invalid', String(sIss.length > 0));
    pwInput.setAttribute('aria-invalid', String(pIss.length > 0));
    ssidInput.closest('.f-field')!.classList.toggle('has-error', sIss.length > 0);
    pwInput.closest('.f-field')!.classList.toggle('has-error', pIss.length > 0);
  }

  // Step 4: applications (the Phase 4.2 editor, catalog and plan only) --------------------------
  const appDef = SETTINGS_BY_PATH.get('applications.selection')!;
  const editor: ApplicationsEditor = createApplicationsEditor(appDef, store, { profiles: false, devices: false, troubleshooting: false, filter: 'relevant' });
  editor.el.querySelector('.meta')?.remove();
  editor.el.querySelector(':scope > .field-label, :scope > legend')?.remove();
  for (const slot of editor.el.querySelectorAll('[data-issues-for]')) slot.removeAttribute('data-issues-for');
  const appsHeader = h('div', { class: 'apps-context', 'data-testid': 'wiz-apps-context' });
  const appsOff = h('div', { class: 'callout', hidden: true });
  const appIssues = h('div', {});
  panels.set('apps', h('div', { class: 'wiz-panel', 'data-step': 'apps' }, appsHeader, appsOff, appIssues, editor.el));

  function updateApps(p: Profile): void {
    clear(appsHeader);
    const r = resolveSelection(p.applications.selection);
    const names = r.activeProfiles.map((id) => allProfiles(p.applications.selection).find((x) => x.id === id)?.name ?? id);
    appsHeader.append(
      h('span', { class: 'desc' }, 'Profiles: '),
      ...names.map((n) => h('span', { class: 'chip static' }, n)),
      h('button', { type: 'button', class: 'linkish', onclick: () => go('type') }, 'Change profiles'),
      h('button', { type: 'button', class: 'linkish', 'data-wiz': 'apps-browse-all', onclick: () => editor.showAll() }, `Browse all ${CATALOG.length} applications`),
      h('button', { type: 'button', class: 'linkish', onclick: () => ctx.openAdvanced('app-profiles') }, 'Saved profiles & import'),
    );
    appsOff.hidden = p.applications.enabled;
    clear(appsOff);
    if (!p.applications.enabled) appsOff.append(icon('info'), h('span', {}, 'Application provisioning is off, so nothing below is installed. '), h('button', { type: 'button', class: 'btn sm', onclick: () => mutate((q) => (q.applications.enabled = true)) }, 'Turn it on'));
    clear(appIssues);
    appIssues.append(issueList(issues.filter((i) => stepOfIssue(i) === 'apps' && i.severity === 'error'), 'wiz-app-issues'));
    editor.sync(p);
  }

  // Step 5: Final Review & Considerations --------------------------------------------------------
  const reviewEl = h('div', { class: 'wiz-panel review-final', 'data-step': 'review', 'data-testid': 'final-review' });
  panels.set('review', reviewEl);

  const section = (title: string, ico: IconName, edit: { label: string; run: () => void }, rows: [string, string | HTMLElement | null][], extra: (HTMLElement | null)[] = [], testid?: string) =>
    h(
      'section',
      { class: 'card review-sec', 'data-testid': testid },
      h('div', { class: 'card-head' }, h('div', { class: 'card-title' }, icon(ico), h('h3', {}, title)), h('button', { type: 'button', class: 'btn sm', 'data-action': 'review-edit', onclick: edit.run }, icon('pen'), edit.label)),
      h('dl', { class: 'kv' }, rows.filter(([, v]) => v !== null && v !== '').flatMap(([k, v]) => [h('dt', {}, k), h('dd', {}, v!)])),
      ...extra,
    );

  function considerationEl(c: Consideration, p: Profile): HTMLElement {
    const key = ackKey(p, c.id);
    const ackId = uid('ack');
    return h(
      'li',
      { class: `consideration ${c.severity}`, 'data-consideration': c.id },
      icon(c.severity === 'critical' ? 'alert' : c.severity === 'warning' ? 'alert' : 'info'),
      h(
        'div',
        {},
        h('strong', {}, c.title),
        h('p', {}, c.detail),
        c.ack
          ? h(
              'label',
              { class: 'check-row ack', for: ackId },
              h('input', {
                type: 'checkbox',
                id: ackId,
                'data-ack': c.id,
                checked: ctx.acks.has(key),
                onchange: (e: Event) => {
                  if ((e.target as HTMLInputElement).checked) ctx.acks.add(key);
                  else ctx.acks.delete(key);
                  mutate(() => undefined, false);
                  el.querySelector<HTMLElement>(`[data-ack="${c.id}"]`)?.focus({ preventScroll: true });
                },
              }),
              h('span', {}, c.ack),
            )
          : null,
        h('button', { type: 'button', class: 'linkish', onclick: () => (c.edit.step ? go(c.edit.step) : ctx.openAdvanced(c.edit.section ?? 'section-review')) }, c.edit.step ? 'Change' : 'Change in Advanced'),
      ),
    );
  }

  function renderReview(p: Profile, result: GenerateResult): void {
    const sel = resolveSelection(p.applications.selection);
    const s = reviewSummary(p, sel);
    const cons = considerations(p, sel);
    const errors = issues.filter((i) => i.severity === 'error');
    const pendingAcks = cons.filter((c) => c.ack && !ctx.acks.has(ackKey(p, c.id)));
    const pkg = result.ok && errors.length === 0 ? currentPackage(p, result) : null;
    const ready = !!pkg && pendingAcks.length === 0;
    const status = h(
      'div',
      { class: `status-card ${errors.length ? 'error' : pendingAcks.length ? 'pending' : 'ok'}`, 'data-testid': 'review-status' },
      h('div', { class: 'status-icon' }, icon(errors.length ? 'x' : pendingAcks.length ? 'alert' : 'check')),
      h(
        'div',
        { class: 'status-body' },
        h('div', { class: 'status-title' }, h('strong', {}, errors.length ? `${errors.length} problem${errors.length === 1 ? '' : 's'} to fix before the ZIP can be generated` : pendingAcks.length ? `Confirm ${pendingAcks.length} consideration${pendingAcks.length === 1 ? '' : 's'} below to generate the ZIP` : 'Configuration valid: the deployment ZIP can be generated')),
        errors.length
          ? h(
              'ul',
              { class: 'status-list' },
              errors.map((i) => {
                const st = stepOfIssue(i);
                return h('li', { class: 'error' }, icon('xCircle'), h('span', {}, i.message, ' '), h('button', { type: 'button', class: 'linkish', 'data-fix': i.path, onclick: () => (st ? go(st) : ctx.openAdvanced(i.path)) }, st ? `Fix in ${STEPS.find((x) => x.id === st)!.title}` : 'Fix in Advanced'));
              }),
            )
          : h('p', {}, 'Validation passed. This does not install Windows or prepare a USB drive: the ZIP still has to be extracted onto official Windows 11 installation media.'),
      ),
    );
    const c = s.computer;
    const n = s.networking;
    const a = s.applications;
    const consList = cons.length ? h('ul', { class: 'considerations', 'data-testid': 'considerations' }, cons.map((x) => considerationEl(x, p))) : h('p', { class: 'desc' }, 'Nothing to consider for this configuration.');
    const files = pkg ? pkg.entries.length : 0;
    patchChildren(reviewEl, [
      status,
      h('div', { class: 'review-cols' },
        h('div', { class: 'review-col' },
          section('Computer', 'monitor', { label: 'Edit', run: () => go('identity') }, [
            ['Computer name', c.computerName],
            ['Local account', c.username],
            ['Account type', c.accountType],
            ['Sign-in', `${c.signIn} · ${c.password}`],
            ['Edition', c.edition],
            ['Architecture', c.architecture],
            ['Region', c.locale],
            ['Keyboard', c.keyboard],
            ['Setup region pages', c.regionScreens],
            ['Computer type', c.computerTypes.join(', ')],
          ], [], 'review-computer'),
          section('Networking', 'wifi', { label: 'Edit', run: () => go('network') }, [
            ['Ethernet', n.wired],
            ['Wi-Fi', n.wifi],
            ['Network (SSID)', n.ssid],
            ['Security', n.security ?? null],
            ['Hidden network', n.hidden === null ? null : n.hidden ? 'Yes' : 'No'],
            ['Wi-Fi password', n.password ? h('span', { class: n.password.includes('missing') ? 'err-text' : '' }, n.password) : null],
          ], [], 'review-network'),
          section('Windows Update', 'refresh', { label: 'Edit', run: () => { go('identity'); (identityPanel.querySelector('details.win-defaults') as HTMLDetailsElement).open = true; } }, [
            ['During deployment', s.updates.initial],
            ['Afterwards', s.updates.ongoing],
            ['When it applies', s.updates.timing],
          ], [], 'review-updates'),
          section('Hardware & drivers', 'chip', { label: 'Edit in Advanced', run: () => ctx.openAdvanced('section-drivers') }, [
            ['Drivers', s.drivers.summary],
            ['How', s.drivers.detail],
            ['Offline drivers', s.drivers.offline],
          ], [], 'review-drivers'),
          section('Privacy', 'lock', { label: 'Edit in Advanced', run: () => ctx.openAdvanced('section-privacy') }, [
            ['Privacy settings', s.privacy.usesDefaults ? 'Owner defaults' : `${s.privacy.changes.length} change${s.privacy.changes.length === 1 ? '' : 's'} from the owner defaults`],
            ['Changed', s.privacy.changes.length ? s.privacy.changes.map((x) => x.label).join('; ') : null],
            ['Location', s.privacy.location],
            ['Security changes', s.privacy.securityChanges.length ? s.privacy.securityChanges.map((x) => x.label).join('; ') : null],
          ], [], 'review-privacy'),
        ),
        h('div', { class: 'review-col' },
          section('Applications', 'package', { label: 'Edit', run: () => go('apps') }, [
            ['Provisioning', a.enabled ? 'On' : 'Off'],
            ['To install automatically', `${a.toInstall}`],
            ['Profiles', a.profiles.join(', ') || 'None'],
            ['Manual follow-up', a.manual.length ? a.manual.join(', ') : 'None'],
            ['Microsoft Store', a.store.length ? a.store.join(', ') : null],
            ['Added by dependency', a.dependencies.length ? a.dependencies.join(', ') : null],
            ['Additional Software', a.additional.length ? a.additional.join(', ') : null],
            ['Your changes', `${a.added} added · ${a.unticked} unticked`],
            ['If something fails', a.enabled ? a.recovery : null],
            ['Conflicts', a.conflicts.length ? h('span', { class: 'err-text' }, a.conflicts.join(' ')) : null],
          ], [selectedAppsSummary(p.applications.selection, p.applications.enabled, sel, p.additionalSoftware.items)], 'review-apps'),
          section('Verification & handoff', 'shieldCheck', { label: 'Edit in Advanced', run: () => ctx.openAdvanced('section-health') }, [
            ['Final verification', s.verification.final],
            ['Reports', s.verification.reports],
            ['Backup & restore', s.verification.restoration],
          ], [], 'review-verification'),
          section('Deployment package', 'usb', { label: 'Advanced', run: () => ctx.openAdvanced('section-deployment') }, [
            ['Installation media', s.package.media],
            ['Answer file', `${s.package.answerFile} at the root of the USB drive`],
            ['After installation', s.package.starts ? 'Windows Update, then applications, then a deployment report' : 'Nothing runs after installation'],
            ['Contains passwords', s.package.secrets ? h('span', { class: 'warn-text' }, 'Yes: keep the ZIP and the USB drive private') : 'No'],
            ['Generated files', pkg ? `${files} files: ${pkg.fileName}` : 'Available once the configuration is valid'],
            ['Validation', errors.length ? h('span', { class: 'err-text' }, `${errors.length} error(s)`) : 'Passed'],
          ], [], 'review-package'),
          h('section', { class: 'card review-sec' }, h('div', { class: 'card-head' }, h('div', { class: 'card-title' }, icon('shield'), h('h3', {}, 'Security & licensing considerations'))), consList),
        ),
      ),
      h(
        'div',
        { class: 'generate-box' },
        h('button', { type: 'button', class: 'btn primary hero', 'data-action': 'wiz-generate', disabled: !ready, onclick: () => generate() }, icon('archive'), h('span', { class: 'btn-stack' }, h('span', { class: 'btn-label' }, 'Generate Deployment ZIP'), h('span', { class: 'btn-sub' }, pkg ? `${pkg.fileName} · ${files} files` : 'Fix the problems above first'))),
        h('p', { class: 'desc' }, 'Built in this browser; nothing is uploaded. Extract it to the root of a Windows 11 installation USB drive. Downloading it does not install Windows or write to any drive.'),
      ),
    ]);
    generateBottom.disabled = !ready;
  }

  function generate(): void {
    const p = store.get();
    if (!resultRef || !resultRef.ok) return go('review');
    const pending = considerations(p).filter((c) => c.ack && !ctx.acks.has(ackKey(p, c.id)));
    if (pending.length) {
      go('review');
      reviewEl.querySelector<HTMLElement>(`[data-ack="${pending[0]!.id}"]`)?.focus();
      return;
    }
    const pkg = currentPackage(p, resultRef);
    if (pkg) downloadPackage(pkg);
  }

  // Rendering ------------------------------------------------------------------------------------
  function renderProgress(p: Profile): void {
    clear(progress);
    STEPS.forEach((s, i) => {
      const st = stepStatus(p, issues, s.id, (k) => ctx.acks.has(k));
      const current = s.id === step;
      progress.append(
        h(
          'li',
          { class: `wiz-step st-${st}${current ? ' current' : ''}`, 'data-step': s.id, 'data-status': st },
          h(
            'button',
            { type: 'button', 'aria-current': current ? 'step' : undefined, onclick: () => go(s.id) },
            h('span', { class: 'wiz-num' }, String(i + 1)),
            h('span', { class: 'wiz-step-text' }, h('span', { class: 'wiz-step-title' }, s.title), h('span', { class: 'wiz-step-status' }, icon(STATUS_ICON[st]), STATUS_LABEL[st])),
          ),
        ),
      );
    });
  }

  function render(focus = false): void {
    const p = store.get();
    const i = index(step);
    const info = STEPS[i]!;
    titleEl.textContent = info.title;
    const remaining = STEPS.length - 1 - i;
    stepCounter.textContent = `Step ${i + 1} of ${STEPS.length} · ${remaining === 0 ? 'last step' : `${remaining} remaining`}`;
    clear(body);
    body.append(panels.get(step)!);
    top.prev.disabled = bottom.prev.disabled = i === 0;
    top.next.hidden = bottom.next.hidden = step === 'review';
    generateBottom.hidden = step !== 'review';
    appsShortcut.hidden = step === 'apps' || step === 'review';
    reviewShortcut.hidden = step === 'review';
    el.dataset.step = step;
    update(p);
    if (focus) {
      titleEl.focus({ preventScroll: true });
      el.scrollIntoView({ block: 'start' });
    }
  }

  function update(p: Profile): void {
    renderProgress(p);
    switch (step) {
      case 'identity':
        updateIdentity(p);
        break;
      case 'type':
        renderType(p);
        break;
      case 'network':
        updateNetwork(p);
        break;
      case 'apps':
        updateApps(p);
        break;
      case 'review':
        if (resultRef) renderReview(p, resultRef);
        break;
    }
  }

  return {
    el,
    update(p, result) {
      resultRef = result;
      issues = result.issues;
      if (!body.firstChild) render();
      else update(p);
    },
    go: (s) => go(s),
    current: () => step,
  };
}
