import type { SectionId } from '../engine/settings/types';
import type { IconName } from './icons';

/**
 * Presentation-only layout: sidebar grouping, icons and the cards that group related settings on
 * each page. Nothing here changes a setting, its value or what is generated.
 */

export type PageId = SectionId | 'review';

export interface NavItem {
  /** Element id the link targets: a page (`section-<id>`) or an anchor inside one. */
  target: string;
  page: PageId;
  label: string;
  icon: IconName;
}

const page = (id: PageId, label: string, icon: IconName): NavItem => ({ target: `section-${id}`, page: id, label, icon });

export const NAV_GROUPS: { title: string; items: NavItem[] }[] = [
  {
    title: 'Windows Setup',
    items: [page('setup', 'Setup, region & edition', 'gear'), page('accounts', 'Account & computer name', 'user')],
  },
  {
    title: 'Configuration',
    items: [
      page('security', 'Security', 'shield'),
      page('privacy', 'Privacy', 'lock'),
      page('updates', 'Windows Update', 'refresh'),
      page('windowsUpdate', 'Update automation', 'cloudDown'),
      page('system', 'System tweaks', 'sliders'),
      page('explorer', 'File Explorer', 'folder'),
      page('taskbar', 'Taskbar', 'taskbar'),
      page('desktop', 'Desktop', 'monitor'),
      page('start', 'Start menu', 'grid'),
      page('personalization', 'Personalization', 'palette'),
      page('bloatware', 'App removal', 'trash'),
      page('virtualization', 'Virtualization', 'server'),
      page('wifi', 'Wi-Fi', 'wifi'),
    ],
  },
  {
    title: 'Application Provisioning',
    items: [
      page('applications', 'WinGet applications', 'package'),
      { target: 'app-profiles', page: 'applications', label: 'Application profiles', icon: 'layers' },
      page('additionalSoftware', 'Additional Software', 'boxPlus'),
    ],
  },
  {
    title: 'Automation & Output',
    items: [
      page('scripts', 'Custom scripts', 'terminal'),
      page('advancedXml', 'XML components', 'code'),
      page('output', 'Output', 'file'),
      page('deferred', 'Later milestones', 'clock'),
      { target: 'deployment-assets', page: 'review', label: 'Deployment assets', icon: 'archive' },
      page('review', 'Review & download', 'download'),
    ],
  },
];

export const PAGE_ICONS: Record<PageId, IconName> = Object.fromEntries(
  NAV_GROUPS.flatMap((g) => g.items.filter((i) => i.target === `section-${i.page}`).map((i) => [i.page, i.icon])),
) as Record<PageId, IconName>;

export interface FieldGroup {
  title: string;
  description?: string;
  paths: string[];
}

/**
 * Cards per page. Sections not listed render as one card. Every setting of a listed section must
 * belong to exactly one group (checked by tests/unit/ui-layout.test.ts).
 */
export const FIELD_GROUPS: Partial<Record<SectionId, FieldGroup[]>> = {
  setup: [
    { title: 'Edition & product key', paths: ['setup.editionMode', 'setup.editionId', 'setup.customProductKey'] },
    {
      title: 'Language, region & time',
      paths: ['setup.languageMode', 'setup.imageLanguage', 'setup.userLocale', 'setup.keyboard', 'setup.geoLocation', 'setup.timeZoneMode', 'setup.timeZone'],
    },
    { title: 'Disk & hardware', paths: ['setup.diskMode', 'setup.bypassRequirementsCheck', 'setup.bypassNetworkCheck', 'setup.processorArchitectures'] },
    { title: 'Setup behaviour', paths: ['setup.useConfigurationSet', 'setup.useNarrator', 'setup.hidePowerShellWindows', 'setup.keepSensitiveFiles'] },
  ],
  accounts: [
    {
      title: 'Local account',
      paths: [
        'accounts.accountMode',
        'accounts.personName',
        'accounts.usernameMode',
        'accounts.customUsername',
        'accounts.accountGroup',
        'accounts.password',
        'accounts.obscurePasswords',
        'accounts.hideOnlineAccountScreens',
      ],
    },
    { title: 'Sign-in', paths: ['accounts.autoLogon'] },
    { title: 'Computer name', paths: ['accounts.computerNameMode', 'accounts.customComputerName'] },
    {
      title: 'Lockout & password policy',
      paths: ['accounts.lockoutMode', 'accounts.lockoutThreshold', 'accounts.lockoutDuration', 'accounts.lockoutWindow', 'accounts.passwordExpirationMode', 'accounts.maxPasswordAge'],
    },
  ],
  security: [
    { title: 'User Account Control', paths: ['security.uacLevel'] },
    { title: 'Protection & recovery', paths: ['security.systemRestore', 'security.disableSmartScreen', 'security.disableSmartAppControl', 'security.preventDeviceEncryption'] },
    { title: 'Access & auditing', paths: ['security.enableRemoteDesktop', 'security.processAudit', 'security.disableInsiderBuilds', 'security.appLockerMode', 'security.appLockerPolicyXml'] },
  ],
  privacy: [
    { title: 'Setup screens', paths: ['privacy.expressSettings'] },
    { title: 'Diagnostic data', paths: ['privacy.diagnosticData', 'privacy.disableTailoredExperiences', 'privacy.disableInkingTypingCollection'] },
    { title: 'Advertising & suggestions', paths: ['privacy.disableAdvertisingId', 'privacy.disableAppSuggestions', 'privacy.disableBingResults'] },
    { title: 'Location & AI features', paths: ['privacy.disableLocation', 'privacy.disableCopilot', 'privacy.disableRecall'] },
  ],
  windowsUpdate: [
    {
      title: 'Automation',
      description: 'A scheduled task installs updates after the first sign-in, restarts when needed and resumes until nothing applicable remains.',
      paths: ['windowsUpdate.enabled'],
    },
    {
      title: 'What to install',
      description: 'Drivers and feature updates change the most on a new installation. Driver inclusion must agree with the Windows Update policy page.',
      paths: ['windowsUpdate.drivers', 'windowsUpdate.featureUpdates', 'windowsUpdate.optionalUpdates', 'windowsUpdate.microsoftUpdate', 'windowsUpdate.excludedKbs'],
    },
    {
      title: 'Restarts',
      description: 'Restarts are scheduled only while holding the shared install lock, so they never interrupt an application installation.',
      paths: ['windowsUpdate.maxReboots', 'windowsUpdate.rebootWarningSeconds'],
    },
    {
      title: 'Network',
      description: 'Without a connection the engine waits this long at each start, then retries at the next start or within the hour. It ends as Offline only if no network appears before the runtime limit.',
      paths: ['windowsUpdate.networkWaitMinutes'],
    },
    {
      title: 'Retries & limits',
      description: 'These limits stop an unattended run from looping. Updates that keep failing are given up and reported.',
      paths: ['windowsUpdate.maxAttemptsPerUpdate', 'windowsUpdate.maxRuntimeHours', 'windowsUpdate.confirmationScans'],
    },
    { title: 'Recovery', paths: ['windowsUpdate.resetComponentsOnce'] },
  ],
  applications: [
    { title: 'Provisioning', paths: ['applications.enabled'] },
    { title: '', paths: ['applications.selection'] },
    {
      title: 'Coordination & restarts',
      description: 'Applications install after Windows Update has finished, one at a time, as the signed-in user.',
      paths: ['applications.coordination', 'applications.waitForUpdatesHours', 'applications.restartPolicy', 'applications.maxReboots', 'applications.rebootWarningSeconds'],
    },
    {
      title: 'WinGet availability',
      description: 'WinGet ships with App Installer and is not supported as SYSTEM, so the engine runs as the signed-in user.',
      paths: ['applications.registerAppInstaller', 'applications.onlineRepair'],
    },
    {
      title: 'Retries & limits',
      paths: ['applications.maxAttemptsPerPackage', 'applications.packageTimeoutMinutes', 'applications.networkWaitMinutes', 'applications.maxRuntimeHours'],
    },
  ],
  system: [
    { title: 'Startup & sign-in', paths: ['system.disableFastStartup', 'system.disableAutomaticRestartSignOn', 'system.deleteWindowsOld'] },
    { title: 'PowerShell', paths: ['system.powerShellExecutionPolicy'] },
    { title: 'File system', paths: ['system.hardenSystemDriveAcl', 'system.enableLongPaths', 'system.deleteJunctions', 'system.disableLastAccess'] },
    { title: 'Hardware & input', paths: ['system.disableWpbt', 'system.preventDeviceApps', 'system.disablePointerPrecision'] },
    { title: 'Microsoft Edge', paths: ['system.hideEdgeFirstRun', 'system.disableEdgeStartupBoost', 'system.makeEdgeUninstallable'] },
    { title: 'Sounds & error reporting', paths: ['system.disableErrorReporting', 'system.turnOffSystemSounds'] },
  ],
  explorer: [
    { title: 'Files & folders', paths: ['explorer.showFileExtensions', 'explorer.hiddenFiles', 'explorer.launchToThisPC'] },
    { title: 'Menus & overlays', paths: ['explorer.classicContextMenu', 'explorer.hideInfoTip', 'explorer.removeShortcutArrows', 'explorer.showEndTask'] },
  ],
  taskbar: [
    { title: 'Layout', paths: ['taskbar.leftAlign', 'taskbar.search', 'taskbar.hideTaskView', 'taskbar.disableWidgets'] },
    { title: 'Icons', paths: ['taskbar.showAllTrayIcons', 'taskbar.icons'] },
  ],
  wifi: [
    { title: 'Connection during setup', paths: ['wifi.mode'] },
    { title: 'Network details', paths: ['wifi.ssid', 'wifi.authentication', 'wifi.password', 'wifi.nonBroadcast', 'wifi.connectAutomatically', 'wifi.profileXml'] },
  ],
  scripts: [
    { title: 'FirstLogon', paths: ['scripts.firstLogon'] },
    { title: 'Other stages', paths: ['scripts.system', 'scripts.defaultUser', 'scripts.userOnce', 'scripts.restartExplorer'] },
  ],
};
