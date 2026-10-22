import type { GenContext } from '../../engine/context';
import type { SettingDef } from '../../engine/settings/types';
import type { Profile } from '../../engine/schema/profile';
import type { Issue } from '../../engine/validation/issues';
import {
  APP_INSTALLER_FILE,
  APP_LIMITS,
  APP_MARKER,
  APP_RESULT_FILE,
  APP_STAGING_DIR,
  APP_TASK_NAME,
  EMBEDDED_APP_FILES,
  embeddedAppFiles,
  applicationAssets,
  applicationsActive,
} from '../../engine/applications';
import { isKnownSource } from '../../engine/applications/ids';
import { isBuiltinProfile, isSelectableProfile } from '../../engine/applications/builtin';
import { allProfiles, expandProfile, resolveSelection } from '../../engine/applications/selection';
import { TASK_PATH } from '../../engine/windows-update';

const on = (p: Profile) => p.applications.enabled;
const APPLIES = 'Windows 10 1809+ / Windows 11 with Microsoft App Installer (WinGet); Windows PowerShell 5.1';

function limit(path: keyof typeof APP_LIMITS, label: string, description: string): SettingDef {
  const [min, max] = APP_LIMITS[path];
  return {
    path: `applications.${path}`,
    section: 'applications',
    label: `${label} (${min}-${max})`,
    control: 'number',
    description,
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: `applications-config.json › ${path}`,
    advanced: true,
    visibleWhen: on,
    verification: 'unverified',
  };
}

export const settings: SettingDef[] = [
  {
    path: 'applications.enabled',
    section: 'applications',
    label: 'Install the selected applications after setup',
    control: 'checkbox',
    description:
      'After Windows Update has finished, a scheduled task running as the signed-in user installs every selected package with WinGet, one at a time, and records a result for each. Nothing is generated while the selection below is empty.',
    applicability: APPLIES,
    risk: 'Installers run with administrator rights. Only select software you trust. Not yet validated in a VM.',
    stages: ['specialize', 'firstLogon'],
    mapping: `Embeds ${EMBEDDED_APP_FILES.join(', ')} in ${APP_STAGING_DIR}. At the first sign-in the deployment orchestrator (Initialize-Deployment.ps1) verifies the files and runs ${APP_INSTALLER_FILE} once as that user, which registers ${TASK_PATH}${APP_TASK_NAME} for the signed-in user (highest privileges, at sign-in + hourly). Result: ${APP_RESULT_FILE}; marker: ${APP_MARKER}.`,
    advanced: false,
    verification: 'unverified',
  },
  {
    path: 'applications.selection',
    section: 'applications',
    label: 'Applications',
    control: 'custom',
    description:
      'Core Essentials is selected for every new deployment. Combine more profiles, answer the device questions, then tick or untick individual applications; your changes survive profile switches and never alter a profile. Packages are identified by PackageIdentifier and source, never by name, and appear once even when several profiles contain them.',
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: 'winget-packages.json (Microsoft packages schema 2.0) + applications-config.json › packages',
    advanced: false,
    visibleWhen: on,
    verification: 'documented',
  },
  {
    path: 'applications.coordination',
    section: 'applications',
    label: 'Coordination with Windows Update',
    control: 'radio',
    choices: [
      {
        value: 'updatesFirst',
        label: 'Updates first (conservative)',
        description: 'Preparation runs in parallel; applications install after the Windows Update stage is final. A shared install lock keeps either side from restarting during the other one\'s installation.',
      },
    ],
    description: 'Interleaved policies are planned for later; they will use the same install lock.',
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: 'applications-config.json › coordination; orchestration.json',
    advanced: true,
    visibleWhen: on,
    verification: 'unverified',
  },
  {
    path: 'applications.restartPolicy',
    section: 'applications',
    label: 'Restarts for applications',
    control: 'radio',
    choices: [
      { value: 'whenRequired', label: 'Restart when a package requires it (owner default)', description: 'With a warning; installation resumes after sign-in and the package is verified.' },
      { value: 'never', label: 'Never restart', description: 'Packages that need a restart are reported as RequiresRestart.' },
    ],
    description: 'Restarts are scheduled only while holding the install lock, never during a Windows Update installation.',
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: 'applications-config.json › restartPolicy, maxReboots',
    advanced: true,
    visibleWhen: on,
    verification: 'unverified',
  },
  {
    path: 'applications.registerAppInstaller',
    section: 'applications',
    label: 'Register App Installer if WinGet is not available yet',
    control: 'checkbox',
    description: 'Microsoft\'s documented step: Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe. Runs only when WinGet does not work.',
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: 'applications-config.json › registerAppInstaller',
    advanced: true,
    visibleWhen: on,
    verification: 'documented',
  },
  {
    path: 'applications.onlineRepair',
    section: 'applications',
    label: 'Allow online repair from the PowerShell Gallery',
    control: 'checkbox',
    description: 'Last resort when registration and offline packages fail: installs Microsoft\'s Microsoft.WinGet.Client module and runs Repair-WinGetPackageManager.',
    applicability: APPLIES,
    risk: 'Downloads and installs a PowerShell module and the NuGet provider from the internet.',
    stages: ['firstLogon'],
    mapping: 'applications-config.json › onlineRepair',
    advanced: true,
    visibleWhen: on,
    verification: 'documented',
  },
  limit('maxReboots', 'Maximum restarts for applications', 'The application stage never restarts more often than this.'),
  {
    path: 'applications.recovery.automaticRetry',
    section: 'applications',
    label: 'Retry temporary failures automatically',
    control: 'checkbox',
    description:
      'Download, network, timeout and "installer busy" failures are retried up to the attempt limit below, waiting 1 minute, then 2, 4 ... (at most 15 minutes, with a little randomness). Hash mismatches, policy blocks, missing packages and cancelled installers are never retried automatically. Off: one attempt per application; failures can still be retried later with the recovery tool.',
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: 'applications-config.json › retry.automatic, retry.baseDelaySeconds, retry.maxDelaySeconds, retry.jitterRatio',
    advanced: true,
    visibleWhen: on,
    verification: 'unverified',
  },
  limit('maxAttemptsPerPackage', 'Maximum attempts per application', 'Automatic attempts for one application (the first one included). A lost network connection does not use them up: the application waits for the network instead.'),
  {
    path: 'applications.recovery.continueAfterFailure',
    section: 'applications',
    label: 'Continue with other applications after a failure',
    control: 'checkbox',
    description:
      'On (owner default): a failed application never blocks independent ones; only applications that depend on it wait. Off: the queue stops at the first failure and the rest stays outstanding for the recovery tool.',
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: 'applications-config.json › retry.continueAfterFailure',
    advanced: true,
    visibleWhen: on,
    verification: 'unverified',
  },
  {
    path: 'applications.recovery.includeRecoveryTool',
    section: 'applications',
    label: 'Include the technician recovery tool',
    control: 'checkbox',
    description:
      'Adds DeploymentRecovery.ps1 and a "Deployment recovery" desktop shortcut: status, retry failed applications (one or all), resume interrupted provisioning, pending actions and a diagnostics ZIP without passwords. Progress is always kept on the computer, so recovery never needs the USB drive or a new installation.',
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: 'WindowsDeployment\\scripts\\recovery\\DeploymentRecovery.ps1 (embedded in the answer file, staged to the package folder)',
    advanced: true,
    verification: 'unverified',
  },
  limit('packageTimeoutMinutes', 'Timeout per installation in minutes', 'A WinGet call that takes longer is stopped and counted as a failed attempt.'),
  limit('networkWaitMinutes', 'Network wait per start in minutes', 'Without a connection the engine tries again at the next sign-in and every hour.'),
  limit('maxRuntimeHours', 'Maximum installation time in hours', 'Counted from the first installation; afterwards the stage ends as Failed.'),
  limit('waitForUpdatesHours', 'Maximum wait for Windows Update in hours', 'If Windows Update is still not finished after this, applications are installed anyway.'),
  limit('rebootWarningSeconds', 'Restart warning in seconds', 'Time between the on-screen warning and the restart.'),
];

export function validate(p: Profile, issues: Issue[]): void {
  const a = p.applications;
  const sel = a.selection;
  const err = (path: string, message: string) => issues.push({ severity: 'error', path, message });
  const warn = (path: string, message: string) => issues.push({ severity: 'warning', path, message });
  const path = 'applications.selection';

  const custom = sel.profiles.map((x) => x.id);
  const dup = custom.filter((id, i) => custom.indexOf(id) !== i || isBuiltinProfile(id));
  if (dup.length) err(path, `Duplicate profile id: ${[...new Set(dup)].join(', ')}.`);
  if (sel.profiles.some((x) => x.builtin)) err(path, 'Built-in profiles are templates and cannot be stored in a deployment; duplicate one to edit it.');
  const profiles = allProfiles(sel);
  const ids = profiles.map((x) => x.id);
  for (const id of sel.selectedProfiles) {
    if (!ids.includes(id)) err(path, `Selected profile "${id}" does not exist.`);
    else if (!isSelectableProfile(id)) err(path, `"${id}" is a device profile; it follows the device answers and cannot be ticked.`);
  }
  for (const prof of sel.profiles) {
    for (const i of prof.inherits) if (!ids.includes(i)) err(path, `Profile "${prof.name}" inherits "${i}", which does not exist.`);
    const cycles: string[] = [];
    expandProfile(prof.id, profiles, cycles);
    if (cycles.length) err(path, `Profile "${prof.name}" inherits itself: ${cycles[0]}.`);
  }
  if (!a.enabled) return;

  for (const [key, [min, max]] of Object.entries(APP_LIMITS) as [keyof typeof APP_LIMITS, readonly [number, number]][]) {
    const v = a[key];
    if (v < min || v > max) err(`applications.${key}`, `Must be between ${min} and ${max}.`);
  }

  const r = resolveSelection(sel);
  for (const x of r.packages.filter((x) => x.resolution === 'unresolved')) {
    if (isKnownSource(x.ref.source.toLowerCase())) err(path, `${x.displayName}: ${x.reason} Remove it or correct the identifier.`);
    else warn(path, `${x.displayName}: ${x.reason}`);
  }
  for (const c of r.conflicts) warn(path, c.message);
  for (const g of r.groupConflicts) err(path, `${g.message} Untick all but one.`);
  for (const n of r.notices) (n.kind === 'error' ? err : warn)(path, n.message);
  const manual = r.packages.filter((x) => x.resolution === 'manual');
  if (manual.length) warn(path, `${manual.map((x) => x.displayName).join(', ')}: no unattended installation is available; listed as a manual follow-up with the official download (never reported as installed).`);
  const interactive = r.packages.filter((x) => x.interaction === 'required' && x.resolution !== 'manual');
  if (interactive.length) warn(path, `${interactive.map((x) => x.displayName).join(', ')} need interaction and will be listed for manual follow-up instead of being installed.`);

  if (!applicationsActive(p)) return;
  if (p.accounts.accountMode === 'unattendedLocal' && p.accounts.accountGroup === 'Users') {
    err('applications.enabled', 'Application installation needs an administrator account (the task runs with highest privileges). Choose Administrators under "Account & computer name" or turn application provisioning off.');
  }
  if (p.accounts.accountMode !== 'unattendedLocal') {
    warn('applications.enabled', 'The installation task is registered for whoever signs in first, and only runs while that person is signed in.');
  } else if (p.accounts.autoLogon === 'none') {
    warn('applications.enabled', 'Without automatic sign-in, applications are installed only after someone signs in (and continue after each sign-in).');
  }
  if (p.bloatware.Store === 'remove' && r.packages.some((x) => x.ref.source.toLowerCase() === 'msstore')) {
    err(path, 'Microsoft Store packages are selected, but "App removal" removes the Microsoft Store. Keep the Store or remove the msstore packages.');
  }
}

/**
 * Embeds the engine files. The deployment orchestrator (Initialize-Deployment.ps1, the last
 * FirstLogon command, src/engine/deployment) runs APP_INSTALLER_FILE from its verified package copy.
 */
export function modify(ctx: GenContext): void {
  if (!applicationsActive(ctx.profile)) return;
  for (const asset of applicationAssets(ctx.profile)) {
    if (embeddedAppFiles(ctx.profile).includes(asset.name)) ctx.embedFile(`${APP_STAGING_DIR}\\${asset.name}`, asset.content);
  }
}
