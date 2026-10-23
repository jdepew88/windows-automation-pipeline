import type { Profile } from './schema/profile';
import type { Issue } from './validation/issues';
import { lookup } from '../data';
import { resolveIdentity } from './naming';
import { ownerDefaults, hasSecrets } from './profiles';
import { diffProfiles } from './profiles/diff';
import { AUTOLOGON_WARNING } from '../features/accounts';
import { SETTINGS_BY_PATH } from '../features';
import { BUILTIN_PROFILES, UNIVERSAL_PROFILES } from './applications/builtin';
import { installable, resolveSelection, type SelectionResult } from './applications/selection';
import { toggleProfile } from './applications/profiles';
import { applicationsActive, isReviewed } from './applications';
import { ongoingPolicyDeferred, resolveDrivers } from './windows-update';
import { deploymentActive } from './deployment';
import { HEALTH_SHORTCUT, healthActive } from './health';
import { migrationActive, settingsRestoreActive } from './migration/plan';

/**
 * Phase 4.3 Quick Deployment: a second way to edit the SAME Profile the Advanced Configuration
 * pages edit. Nothing here keeps its own copy of a setting; every helper reads or mutates the
 * profile, so both modes, the review and the generated files always agree.
 */

// ------------------------------------------------------------------------------------------------
// Customer / computer types: the Phase 4.2 built-in profiles, not a second set of presets.
// ------------------------------------------------------------------------------------------------

export interface CustomerType {
  /** Built-in application profile id (src/data/apps/profiles.json). */
  profile: string;
  label: string;
  hint: string;
}

export const CUSTOMER_TYPES: readonly CustomerType[] = [
  { profile: 'everyday', label: 'Everyday home user', hint: 'PDF reader; email, calls and cloud storage to choose from' },
  { profile: 'gaming', label: 'Gamer', hint: 'Steam and Epic Games Launcher; other launchers and Discord to choose from' },
  { profile: 'developer', label: 'Developer', hint: 'Git, Visual Studio Code, Python and Node.js LTS' },
  { profile: 'network-engineer', label: 'Network Engineer / Developer / Technician', hint: 'The full power-user workstation (includes Developer)' },
  { profile: 'music', label: 'Music Enthusiast', hint: 'MusicBee library manager; players and editors to choose from' },
  { profile: 'laptop', label: 'Laptop', hint: 'Battery check tool; location services can be allowed' },
  { profile: 'touch', label: 'Touchscreen / 2-in-1', hint: 'Handwritten notes and PDF annotation' },
];

for (const t of CUSTOMER_TYPES) if (!BUILTIN_PROFILES.some((p) => p.id === t.profile)) throw new Error(`Customer type refers to unknown profile ${t.profile}`);

export const LAPTOP_PROFILE = 'laptop';

export const isTypeSelected = (p: Profile, profile: string) => p.applications.selection.selectedProfiles.includes(profile);

/** Ticks or unticks a customer type: exactly the Advanced profile checkbox (individual overrides are kept). */
export function setCustomerType(p: Profile, profile: string, on: boolean): void {
  toggleProfile(p.applications.selection, profile, on);
}

/** Location is only offered for laptops; it maps onto the existing privacy setting. */
export const locationAllowed = (p: Profile) => !p.privacy.disableLocation;
export function setLocationAllowed(p: Profile, allowed: boolean): void {
  p.privacy.disableLocation = !allowed;
}

// ------------------------------------------------------------------------------------------------
// Identity: the two wizard fields map onto the existing account settings.
// ------------------------------------------------------------------------------------------------

/** The value the "Local account username" field shows. */
export const usernameInput = (p: Profile) => (p.accounts.usernameMode === 'custom' ? p.accounts.customUsername : p.accounts.personName);

export function setUsernameInput(p: Profile, value: string): void {
  if (p.accounts.usernameMode === 'custom') p.accounts.customUsername = value;
  else p.accounts.personName = value;
}

/** The value the "Computer name" field shows: the derived one until someone types their own. */
export function computerNameInput(p: Profile): string {
  return resolveIdentity(p.accounts).computerName ?? '';
}

/** Typing a computer name makes it custom; an empty field returns to the derived name. */
export function setComputerNameInput(p: Profile, value: string): void {
  if (p.accounts.computerNameMode === 'random') return;
  const derived = resolveIdentity({ ...p.accounts, computerNameMode: 'derived' }).computerName ?? '';
  if (value.trim() === '' || value === derived) {
    p.accounts.computerNameMode = 'derived';
    p.accounts.customComputerName = '';
  } else {
    p.accounts.computerNameMode = 'custom';
    p.accounts.customComputerName = value;
  }
}

// ------------------------------------------------------------------------------------------------
// Wizard steps
// ------------------------------------------------------------------------------------------------

export type StepId = 'identity' | 'type' | 'network' | 'apps' | 'review';
export type StepStatus = 'complete' | 'defaults' | 'customized' | 'incomplete' | 'attention';

export const STEPS: readonly { id: StepId; title: string; short: string }[] = [
  { id: 'identity', title: 'Computer & local account', short: 'Account' },
  { id: 'type', title: 'Computer & customer type', short: 'Type' },
  { id: 'network', title: 'Network', short: 'Network' },
  { id: 'apps', title: 'Applications', short: 'Apps' },
  { id: 'review', title: 'Final Review & Considerations', short: 'Review' },
];

/** Which settings each step is responsible for (issues on these paths belong to the step). */
const STEP_PATHS: Record<Exclude<StepId, 'review'>, string[]> = {
  identity: ['accounts.personName', 'accounts.customUsername', 'accounts.customComputerName', 'accounts.computerNameMode', 'accounts.usernameMode', 'setup.editionId', 'setup.editionMode', 'setup.languageMode', 'updates.'],
  type: ['applications.selection.selectedProfiles', 'applications.selection.devices', 'privacy.disableLocation'],
  network: ['wifi.'],
  apps: ['applications.'],
};

const matches = (path: string, prefixes: string[]) => prefixes.some((x) => (x.endsWith('.') ? path.startsWith(x) : path === x || path.startsWith(`${x}.`)));

/** The step whose fields an issue belongs to, or null when it belongs to Advanced only. */
export function stepOfIssue(issue: Pick<Issue, 'path'>): Exclude<StepId, 'review'> | null {
  for (const id of ['identity', 'type', 'network'] as const) if (matches(issue.path, STEP_PATHS[id])) return id;
  if (matches(issue.path, STEP_PATHS.apps)) return 'apps';
  return null;
}

export function stepErrors(issues: Issue[], step: StepId): Issue[] {
  if (step === 'review') return issues.filter((i) => i.severity === 'error');
  return issues.filter((i) => i.severity === 'error' && stepOfIssue(i) === step);
}

/**
 * Status of a step for the progress bar. "defaults": valid and unchanged from the owner defaults;
 * "customized": valid with changes; "complete": required input given; "incomplete": required
 * input missing; "attention": an error to fix.
 */
export function stepStatus(p: Profile, issues: Issue[], step: StepId, acknowledged: (id: string) => boolean = () => false): StepStatus {
  const errors = stepErrors(issues, step);
  const base = ownerDefaults();
  switch (step) {
    case 'identity':
      if (resolveIdentity(p.accounts).username.trim() === '' && p.accounts.accountMode === 'unattendedLocal') return 'incomplete';
      return errors.length ? 'attention' : 'complete';
    case 'type': {
      if (errors.length) return 'attention';
      const s = p.applications.selection;
      const same = JSON.stringify(s.selectedProfiles) === JSON.stringify(base.applications.selection.selectedProfiles) && JSON.stringify(s.devices) === JSON.stringify(base.applications.selection.devices);
      return same ? 'defaults' : 'customized';
    }
    case 'network':
      if (errors.length) return p.wifi.mode === 'parameters' && (p.wifi.ssid === '' || p.wifi.password === '') ? 'incomplete' : 'attention';
      return p.wifi.mode === base.wifi.mode ? 'defaults' : 'customized';
    case 'apps': {
      if (errors.length) return 'attention';
      const s = p.applications.selection;
      return s.added.length || s.removed.length || !p.applications.enabled ? 'customized' : 'defaults';
    }
    case 'review': {
      if (errors.length) return 'attention';
      return considerations(p).some((c) => c.ack && !acknowledged(ackKey(p, c.id))) ? 'incomplete' : 'complete';
    }
  }
}

/** The first step before `target` that blocks moving on (required data missing or invalid). */
export function blockingStep(p: Profile, issues: Issue[], target: StepId): StepId | null {
  for (const s of STEPS) {
    if (s.id === target) return null;
    if (stepErrors(issues, s.id).length || stepStatus(p, issues, s.id) === 'incomplete') return s.id;
  }
  return null;
}

// ------------------------------------------------------------------------------------------------
// "Customized in Advanced Settings"
// ------------------------------------------------------------------------------------------------

/** Settings of these sections that differ from the owner defaults (labels for people). */
export function customizedSettings(p: Profile, prefixes: string[]): { path: string; label: string }[] {
  return diffProfiles(ownerDefaults(), p)
    .filter((c) => prefixes.some((x) => c.path.startsWith(x)))
    .map((c) => {
      const parts = c.path.split('.');
      let def = undefined;
      for (let i = parts.length; i > 0 && !def; i--) def = SETTINGS_BY_PATH.get(parts.slice(0, i).join('.'));
      return { path: c.path, label: def?.label ?? c.path };
    })
    .filter((x, i, all) => all.findIndex((y) => y.label === x.label) === i);
}

// ------------------------------------------------------------------------------------------------
// Ongoing Windows Update policy (the Quick selector for updates.mode)
// ------------------------------------------------------------------------------------------------

export type UpdateChoice = 'recommended' | 'notify' | 'custom';

export function updateChoice(p: Profile): UpdateChoice {
  if (p.updates.mode === 'windowsDefault' && !p.updates.preventAutomaticReboot) return 'recommended';
  if (p.updates.mode === 'notifyInstall') return 'notify';
  return 'custom';
}

export function setUpdateChoice(p: Profile, c: Exclude<UpdateChoice, 'custom'>): void {
  p.updates.mode = c === 'recommended' ? 'windowsDefault' : 'notifyInstall';
  if (c === 'notify') p.updates.preventAutomaticReboot = false;
}

export function ongoingPolicyText(p: Profile): string {
  switch (p.updates.mode) {
    case 'windowsDefault':
      return p.updates.preventAutomaticReboot ? 'Windows default (automatic), with restarts deferred while someone is signed in' : 'Windows recommended defaults: updates download and install automatically, with normal restart protections';
    case 'notifyInstall':
      return 'Download automatically; ask before installing (Configure Automatic Updates = 3)';
    case 'notifyDownload':
      return 'Ask before downloading and installing (Configure Automatic Updates = 2)';
  }
}

export function ongoingPolicyTiming(p: Profile): string {
  if (p.updates.mode === 'windowsDefault') return 'No policy is written; Windows keeps its own behaviour.';
  return ongoingPolicyDeferred(p)
    ? 'Applied after the initial Windows Update stage has finished (including its restarts), by the deployment monitor. Not applied on Windows Home, and never over domain, MDM or WSUS policy; the deployment report says what happened.'
    : 'Written during Windows Setup (specialize), because the initial update automation is off.';
}

// ------------------------------------------------------------------------------------------------
// Considerations: the risk and licensing notes of Final Review, only when relevant.
// ------------------------------------------------------------------------------------------------

export type ConsiderationSeverity = 'critical' | 'warning' | 'info';

export interface Consideration {
  id: string;
  severity: ConsiderationSeverity;
  title: string;
  detail: string;
  /** Needs an explicit confirmation before the package is generated (once per session). */
  ack?: string;
  /** Where to change it: a wizard step or an Advanced section id. */
  edit: { step?: StepId; section?: string };
}

export const isEmptyPasswordAutoAdmin = (p: Profile) =>
  p.accounts.accountMode === 'unattendedLocal' && p.accounts.accountGroup === 'Administrators' && p.accounts.password === '' && p.accounts.autoLogon !== 'none';

export const wifiSecretEmbedded = (p: Profile) =>
  (p.wifi.mode === 'parameters' && p.wifi.authentication !== 'open' && p.wifi.password !== '') || (p.wifi.mode === 'profileXml' && /keyMaterial/i.test(p.wifi.profileXml));

export function considerations(p: Profile, sel: SelectionResult = resolveSelection(p.applications.selection)): Consideration[] {
  const out: Consideration[] = [];
  const a = p.accounts;
  if (isEmptyPasswordAutoAdmin(p)) {
    out.push({
      id: 'autologon-admin',
      severity: 'critical',
      title: 'Administrator account with no password signs in automatically',
      detail: `${AUTOLOGON_WARNING} ${a.autoLogon === 'persistent' ? 'Automatic sign-in stays on after setup.' : 'Automatic sign-in happens once, at the first sign-in.'} To reduce the risk, set a password and choose "once" or "none" under Advanced › Account & computer name.`,
      ack: 'I understand that anyone with physical access to this computer gets an administrator session.',
      edit: { section: 'accounts' },
    });
  } else if (a.accountMode === 'unattendedLocal' && a.password !== '' && a.autoLogon === 'persistent') {
    out.push({ id: 'autologon-password', severity: 'warning', title: 'The account password is stored for automatic sign-in', detail: 'Persistent automatic sign-in keeps the password readable by administrators in the registry (Winlogon DefaultPassword), and the answer file contains it until it is deleted at the first sign-in.', edit: { section: 'accounts' } });
  }
  if (p.setup.editionMode === 'genericKey') {
    const ed = lookup.edition(p.setup.editionId)?.DisplayName ?? p.setup.editionId;
    out.push({ id: 'generic-key', severity: 'info', title: 'Generic setup keys are not licenses', detail: `The generic key only tells Setup to install Windows 11 ${ed}. It does not license or activate Windows: activation needs a valid license or the computer's digital entitlement.`, edit: { section: 'setup' } });
  } else if (p.setup.editionMode === 'customKey') {
    out.push({ id: 'product-key', severity: 'warning', title: 'A product key is stored in the answer file', detail: 'The key is written in plain text to autounattend.xml and C:\\Windows\\Panther until it is deleted. Keep the USB drive and the ZIP private.', edit: { section: 'setup' } });
  }
  if (wifiSecretEmbedded(p)) {
    out.push({
      id: 'wifi-secret',
      severity: 'critical',
      title: 'The Wi-Fi password is embedded in the installation media',
      detail: 'The Wi-Fi password is stored in plain text in autounattend.xml inside the ZIP and on the USB drive (it is not encrypted). Anyone with the ZIP or the drive can read it. On the installed computer it is deleted at the first sign-in unless "Keep sensitive files" is on. Delete the ZIP and the answer file from the drive after installing.',
      ack: 'I understand the ZIP and the USB drive contain the Wi-Fi password and must be kept private.',
      edit: { step: 'network', section: 'wifi' },
    });
  }
  if (p.wifi.mode === 'parameters' || p.wifi.mode === 'profileXml') {
    out.push({ id: 'wifi-driver', severity: 'info', title: 'Wi-Fi needs a supported adapter and driver', detail: 'The profile is added during setup if Windows has a driver for the Wi-Fi adapter, otherwise once more at the first sign-in. Without a working adapter it is reported in the deployment report and must be connected by hand later.', edit: { step: 'network', section: 'wifi' } });
  }
  if (p.updates.mode !== 'windowsDefault') {
    out.push({ id: 'update-approval', severity: 'warning', title: 'Updates wait for someone to approve them', detail: `${ongoingPolicyText(p)}. Security fixes are delayed until someone installs them from Settings › Windows Update. ${ongoingPolicyTiming(p)}`, edit: { step: 'identity', section: 'updates' } });
  }
  if (applicationsActive(p)) {
    const manual = sel.packages.filter((x) => x.resolution === 'manual');
    if (manual.length) out.push({ id: 'manual-apps', severity: 'warning', title: `${manual.length} application${manual.length === 1 ? '' : 's'} must be installed by hand`, detail: `${manual.map((x) => x.displayName).join(', ')}: no WinGet or Microsoft Store package exists, so the deployment lists ${manual.length === 1 ? 'it' : 'them'} as a follow-up with the official download link and never reports ${manual.length === 1 ? 'it' : 'them'} as installed.`, edit: { step: 'apps' } });
    const prompts = installable(sel).filter((x) => x.interaction === 'mayPrompt' || x.interaction === 'required');
    if (prompts.length) out.push({ id: 'interactive-apps', severity: 'info', title: 'Some installers may ask questions', detail: `${prompts.map((x) => x.displayName).join(', ')} may prompt or offer extra products; check them after the deployment.`, edit: { step: 'apps' } });
    const signIn = installable(sel).filter((x) => x.accountSignIn);
    if (signIn.length) out.push({ id: 'sign-in-apps', severity: 'info', title: 'Accounts are not configured', detail: `${signIn.map((x) => x.displayName).join(', ')} install unattended; the customer signs in to them afterwards.`, edit: { step: 'apps' } });
  }
  if (p.setup.bypassRequirementsCheck) out.push({ id: 'bypass', severity: 'warning', title: 'Windows 11 hardware checks are bypassed', detail: 'Microsoft does not support Windows 11 on hardware that fails TPM, Secure Boot or RAM checks, and such devices may not receive updates.', edit: { section: 'setup' } });
  if (hasSecrets(p) && p.setup.keepSensitiveFiles) out.push({ id: 'keep-sensitive', severity: 'warning', title: 'Sensitive files are kept on the installed computer', detail: '"Keep sensitive files" leaves the answer file and the Wi-Fi profile (with passwords) on the installed system.', edit: { section: 'setup' } });
  return out;
}

/** Acknowledgments are remembered per session for the same risk (not per page visit). */
export function ackKey(p: Profile, id: string): string {
  if (id === 'autologon-admin') return `${id}:${resolveIdentity(p.accounts).username}:${p.accounts.autoLogon}`;
  if (id === 'wifi-secret') return `${id}:${p.wifi.mode}:${p.wifi.ssid}`;
  return id;
}

// ------------------------------------------------------------------------------------------------
// Final Review: the effective configuration in words.
// ------------------------------------------------------------------------------------------------

const ARCH_LABEL: Record<string, string> = { amd64: 'x64', arm64: 'Arm64', x86: 'x86 (Windows 10 only)' };

export function reviewSummary(p: Profile, sel: SelectionResult = resolveSelection(p.applications.selection)) {
  const id = resolveIdentity(p.accounts);
  const unattendedLang = p.setup.languageMode === 'unattended';
  const edition = p.setup.editionMode === 'genericKey' ? `Windows 11 ${lookup.edition(p.setup.editionId)?.DisplayName ?? p.setup.editionId}` : p.setup.editionMode === 'interactive' ? 'Chosen during Setup' : p.setup.editionMode === 'firmware' ? 'From the firmware product key' : 'From the entered product key';
  const types = CUSTOMER_TYPES.filter((t) => isTypeSelected(p, t.profile)).map((t) => t.label);
  const privacyChanges = customizedSettings(p, ['privacy.']);
  const securityChanges = customizedSettings(p, ['security.']);
  const queue = installable(sel);
  const manual = sel.packages.filter((x) => x.resolution === 'manual');
  const profileName = (pid: string) => [...BUILTIN_PROFILES, ...p.applications.selection.profiles].find((x) => x.id === pid)?.name ?? pid;
  return {
    computer: {
      computerName: id.computerName ?? 'Random name chosen by Windows',
      username: p.accounts.accountMode === 'unattendedLocal' ? id.username : p.accounts.accountMode === 'interactiveLocal' ? 'Created during setup (interactive)' : 'Microsoft account (interactive)',
      accountType: p.accounts.accountGroup === 'Administrators' ? 'Administrator' : 'Standard user',
      signIn: p.accounts.autoLogon === 'persistent' ? 'Automatic (stays on)' : p.accounts.autoLogon === 'firstLogonOnly' ? 'Automatic once' : 'Password required',
      password: p.accounts.password === '' ? 'No password' : 'Password set (not shown)',
      edition,
      architecture: p.setup.processorArchitectures.map((x) => ARCH_LABEL[x] ?? x).join(', '),
      locale: unattendedLang ? `${lookup.userLocale(p.setup.userLocale)?.DisplayName ?? p.setup.userLocale} · display language ${p.setup.imageLanguage}` : 'Chosen during Setup',
      keyboard: unattendedLang ? (lookup.keyboard(p.setup.keyboard)?.DisplayName ?? p.setup.keyboard) : 'Chosen during Setup',
      regionScreens: unattendedLang ? 'Skipped: the predefined region and keyboard are used' : 'Shown during Setup',
      timeZone: p.setup.timeZoneMode === 'explicit' ? p.setup.timeZone : 'Determined by Windows',
      computerTypes: types.length ? types : ['Core Essentials only'],
    },
    networking: {
      wired: 'Ethernet works automatically when Windows has a driver for the adapter',
      wifi: p.wifi.mode === 'parameters' ? 'Configured from SSID and password' : p.wifi.mode === 'profileXml' ? 'Configured from a WLAN profile XML' : p.wifi.mode === 'skip' ? 'Skipped (the Wi-Fi page is hidden during setup)' : 'Not configured: Windows shows its own network page during setup if needed',
      ssid: p.wifi.mode === 'parameters' ? p.wifi.ssid : null,
      hidden: p.wifi.mode === 'parameters' ? p.wifi.nonBroadcast : null,
      security: p.wifi.mode === 'parameters' ? { open: 'Open (no password)', WPA2PSK: 'WPA2-Personal', WPA3SAE: 'WPA3-Personal' }[p.wifi.authentication] : null,
      password: p.wifi.mode === 'parameters' && p.wifi.authentication !== 'open' ? (p.wifi.password ? 'Password entered (not shown)' : 'Password missing') : null,
    },
    updates: {
      initial: p.windowsUpdate.enabled ? `Automatic after the first sign-in: every applicable update, restarts and resumes (at most ${p.windowsUpdate.maxReboots} restarts, ${p.windowsUpdate.maxRuntimeHours} h); feature updates ${p.windowsUpdate.featureUpdates === 'skip' ? 'skipped' : 'installed'}` : 'Off: Windows updates itself on its own schedule',
      ongoing: ongoingPolicyText(p),
      timing: ongoingPolicyTiming(p),
    },
    drivers: {
      summary: p.drivers.enabled
        ? 'Windows will identify hardware, use compatible existing or Windows Update drivers, and report any missing drivers.'
        : 'Off: the deployment does not install or change drivers.',
      detail: p.drivers.enabled
        ? `Detected on the installed computer, not by this website.${p.windowsUpdate.enabled && p.updates.excludeDrivers && p.windowsUpdate.drivers === 'followPolicy' ? ' Windows Update is set not to install drivers, so missing ones come from the Windows driver store or approved offline packages, or are reported.' : p.windowsUpdate.enabled && p.drivers.useWindowsUpdate && resolveDrivers(p) === 'include' ? ' Windows Update goes first and may supply compatible drivers; the driver stage handles only what is still missing.' : ''}`
        : null,
      offline: p.drivers.enabled && p.drivers.bundle && p.drivers.includeOfflinePackages ? `Offline bundle ${p.drivers.bundle.folderName} (${p.drivers.bundle.packages.length} package(s))` : null,
    },
    privacy: { usesDefaults: privacyChanges.length === 0, changes: privacyChanges, securityChanges, location: p.privacy.disableLocation ? 'Off (policy)' : 'Allowed: the user can turn it on in Settings › Privacy & security › Location' },
    applications: {
      enabled: applicationsActive(p),
      toInstall: queue.length,
      manual: manual.map((x) => x.displayName),
      store: queue.filter((x) => x.ref.source === 'msstore').map((x) => x.displayName),
      unticked: sel.removed.length,
      added: p.applications.selection.added.length,
      profiles: sel.activeProfiles.map(profileName),
      universal: UNIVERSAL_PROFILES.filter((u) => sel.activeProfiles.includes(u)).map(profileName),
      conflicts: sel.groupConflicts.map((g) => g.message),
      dependencies: sel.packages.filter((x) => x.origins.includes('required')).map((x) => x.displayName),
      // Phase 9: installers WinGet does not cover, so they are visible before deployment too.
      additional: p.additionalSoftware.items.map((i) => `${i.name || i.fileName || 'Unnamed installer'} (${i.execution === 'automatic' && isReviewed(i) ? 'installed from the supplied file' : 'manual follow-up'})`),
      // Phase 5: how failures are handled (configured in Advanced > Applications > Reliability & recovery).
      recovery: `${p.applications.recovery.automaticRetry ? `Temporary failures retried automatically (up to ${p.applications.maxAttemptsPerPackage} attempts, growing wait); a lost connection pauses instead of failing` : 'No automatic retry (one attempt each)'}. ${p.applications.recovery.includeRecoveryTool ? 'Failed apps can be retried later with the "Deployment recovery" tool, without reinstalling Windows.' : 'No recovery tool in the package.'}`,
    },
    verification: {
      final: healthActive(p)
        ? 'Automatic and read-only: when the deployment finishes, the computer checks the edition, account, updates, selected applications, drivers, security and storage against Windows itself, and again after a pending restart'
        : p.health.enabled
          ? 'Nothing runs after installation, so there is nothing to verify'
          : 'Off: no health report (the deployment report is still written)',
      reports: healthActive(p) ? [p.health.technicianReport ? 'technician dashboard' : '', p.health.customerReport ? 'customer handoff' : '', 'machine-readable JSON'].filter(Boolean).join(', ') + ` on the installed computer ("${HEALTH_SHORTCUT}")` : null,
      restoration: settingsRestoreActive(p) ? `Settings restored from backup ${p.migration.backup!.folderName} (put it on the USB drive); verified per application` : migrationActive(p) ? 'Applications from the inventory review; no settings backup' : 'No backup restoration',
    },
    package: {
      starts: deploymentActive(p),
      media: `Official Windows 11 ${ARCH_LABEL[p.setup.processorArchitectures[0] ?? 'amd64'] ?? ''} installation media that contains ${edition === 'Chosen during Setup' ? 'the edition you will choose' : edition}. A multi-edition ISO (Media Creation Tool) contains Home and Pro; the answer file cannot add an edition the image does not contain.`,
      answerFile: p.output.answerFileName,
      secrets: hasSecrets(p),
    },
  };
}

export type ReviewSummary = ReturnType<typeof reviewSummary>;
