import type { SectionDef, SettingDef } from '../engine/settings/types';
import type { Profile } from '../engine/schema/profile';
import type { Issue } from '../engine/validation/issues';
import * as setup from './setup';
import * as accounts from './accounts';
import * as security from './security';
import * as privacy from './privacy';
import * as updates from './updates';
import * as windowsUpdate from './windows-update';
import * as applications from './applications';
import * as additionalSoftware from './additional-software';
import * as migration from './migration';
import * as system from './system';
import * as explorer from './explorer';
import * as taskbar from './taskbar';
import * as desktop from './desktop';
import * as start from './start';
import * as personalization from './personalization';
import * as bloatware from './bloatware';
import * as virtualization from './virtualization';
import * as wifi from './wifi';
import * as scripts from './scripts';
import * as advancedXml from './advanced-xml';
import * as output from './output';

export const SECTIONS: SectionDef[] = [
  { id: 'setup', title: 'Setup, region & edition', intro: 'English (United States), US keyboard, Windows 11 Pro. Disk selection always stays interactive.' },
  { id: 'accounts', title: 'Account & computer name', intro: 'One local administrator account, created by the answer file. No Microsoft account.' },
  { id: 'security', title: 'Security' },
  { id: 'privacy', title: 'Privacy', intro: 'Maximum practical privacy for Windows 11 Pro. Required diagnostic data cannot be turned off on Pro.' },
  { id: 'updates', title: 'Windows Update' },
  {
    id: 'windowsUpdate',
    title: 'Windows Update automation',
    intro: 'Installs all applicable updates after setup, restarting and resuming until none remain. Uses only built-in Windows components.',
  },
  {
    id: 'applications',
    title: 'Application provisioning',
    intro: 'Choose applications to install with WinGet after Windows Update has finished. Core Essentials is selected for every new deployment; add profiles, device recommendations and individual apps. Each package is installed once.',
  },
  {
    id: 'additionalSoftware',
    title: 'Additional Software',
    intro: 'Installers that WinGet does not cover. Recorded with their official source and checksum; this version lists them for manual follow-up and never downloads anything.',
  },
  {
    id: 'migration',
    title: 'Application Backup & Restore',
    intro: 'Reconstruct an existing computer: inventory its applications with the local collector, review what to reinstall, save it as a named profile, and restore supported settings after installation. Not every program, setting or licence can be restored; anything unsupported is listed with the reason.',
  },
  { id: 'system', title: 'System tweaks' },
  { id: 'explorer', title: 'File Explorer' },
  { id: 'taskbar', title: 'Taskbar' },
  { id: 'desktop', title: 'Desktop' },
  { id: 'start', title: 'Start menu' },
  { id: 'personalization', title: 'Personalization & accessibility' },
  { id: 'bloatware', title: 'App removal' },
  { id: 'virtualization', title: 'Virtualization (hosts & guests)' },
  { id: 'wifi', title: 'Wi-Fi' },
  { id: 'scripts', title: 'Custom scripts' },
  { id: 'advancedXml', title: 'Additional XML components' },
  { id: 'output', title: 'Output' },
  { id: 'deferred', title: 'Later milestones (recorded only)' },
];

export const ALL_SETTINGS: SettingDef[] = [
  ...setup.settings,
  ...accounts.settings,
  ...security.settings,
  ...privacy.settings,
  ...updates.settings,
  ...windowsUpdate.settings,
  ...applications.settings,
  ...additionalSoftware.settings,
  ...migration.settings,
  ...system.settings,
  ...explorer.settings,
  ...taskbar.settings,
  ...desktop.settings,
  ...start.settings,
  ...personalization.settings,
  ...bloatware.settings,
  ...virtualization.settings,
  ...wifi.settings,
  ...scripts.settings,
  ...advancedXml.settings,
  ...output.settings,
  ...output.deferredSettings,
];

export const SETTINGS_BY_PATH: ReadonlyMap<string, SettingDef> = new Map(ALL_SETTINGS.map((s) => [s.path, s]));

export const VALIDATORS: ((p: Profile, issues: Issue[]) => void)[] = [
  setup.validate,
  accounts.validate,
  security.validate,
  updates.validate,
  windowsUpdate.validate,
  applications.validate,
  additionalSoftware.validate,
  migration.validate,
  desktop.validate,
  start.validate,
  bloatware.validate,
  wifi.validate,
  scripts.validate,
  advancedXml.validate,
];

export { setup, accounts, security, privacy, updates, windowsUpdate, applications, additionalSoftware, migration, system, explorer, taskbar, desktop, start, personalization, bloatware, virtualization, wifi, scripts, advancedXml, output };
