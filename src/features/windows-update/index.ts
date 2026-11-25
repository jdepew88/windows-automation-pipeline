import type { GenContext } from '../../engine/context';
import type { SettingDef } from '../../engine/settings/types';
import type { Profile } from '../../engine/schema/profile';
import type { Issue } from '../../engine/validation/issues';
import {
  CONFIG_FILE,
  COMPLETION_MARKER,
  EMBEDDED_UPDATE_FILES,
  ENGINE_FILE,
  INSTALLER_FILE,
  LIMITS,
  RESULT_FILE,
  STAGING_DIR,
  TASK_NAME,
  TASK_PATH,
  parseKbList,
  updateEngineAssets,
} from '../../engine/windows-update';

const on = (p: Profile) => p.windowsUpdate.enabled;
const APPLIES = 'Windows 10/11 (Windows PowerShell 5.1, Windows Update Agent API)';

function limit(path: keyof typeof LIMITS, label: string, description: string): SettingDef {
  const [min, max] = LIMITS[path];
  return {
    path: `windowsUpdate.${path}`,
    section: 'windowsUpdate',
    label: `${label} (${min}-${max})`,
    control: 'number',
    description,
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: `config.json › ${path}`,
    advanced: true,
    visibleWhen: on,
    verification: 'unverified',
  };
}

export const settings: SettingDef[] = [
  {
    path: 'windowsUpdate.enabled',
    section: 'windowsUpdate',
    label: 'Install all applicable Windows updates after setup',
    control: 'checkbox',
    description:
      'After FirstLogon, a SYSTEM scheduled task waits for the network, installs updates, restarts when needed and resumes after each restart until nothing applicable remains, then removes itself. Progress and the final result are logged; see "Deployment assets" under Review & download.',
    applicability: APPLIES,
    risk:
      'The computer restarts on its own, even while someone is signed in (they get a warning first). With automatic sign-in this repeats until updating is finished. Unsaved work in that session can be lost. Not yet validated in a VM.',
    stages: ['specialize', 'firstLogon'],
    mapping: `Embeds ${ENGINE_FILE}, ${INSTALLER_FILE} and ${CONFIG_FILE} in ${STAGING_DIR}. At the first sign-in the deployment orchestrator (Initialize-Deployment.ps1) verifies the files and runs ${INSTALLER_FILE} once, which registers the task ${TASK_PATH}${TASK_NAME} (SYSTEM, at startup + hourly). Result: ${RESULT_FILE}; completion marker: ${COMPLETION_MARKER}.`,
    advanced: false,
    verification: 'unverified',
  },
  {
    path: 'windowsUpdate.drivers',
    section: 'windowsUpdate',
    label: 'Drivers',
    control: 'radio',
    choices: [
      { value: 'followPolicy', label: 'Follow the Windows Update driver setting above (owner default)', description: 'Excluded while "Do not include drivers with Windows quality updates" is on.' },
      { value: 'exclude', label: 'Never install drivers' },
      { value: 'include', label: 'Install drivers too', description: 'Needs the driver exclusion policy turned off; otherwise Windows Update offers no drivers.' },
    ],
    description: 'Drivers are recognised by their Windows Update type, not by title.',
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: "config.json › drivers. exclude adds Type='Software' to the search criteria.",
    advanced: false,
    visibleWhen: on,
    verification: 'documented',
  },
  {
    path: 'windowsUpdate.featureUpdates',
    section: 'windowsUpdate',
    label: 'Feature updates (new Windows versions, e.g. 24H2 to 25H2)',
    control: 'radio',
    choices: [
      { value: 'skip', label: 'Skip (owner default)' },
      { value: 'install', label: 'Install when offered' },
    ],
    description: 'Recognised by the documented "Upgrades" update category, not by title.',
    applicability: APPLIES,
    risk: 'Small "enablement packages" that switch versions may arrive as regular updates and install even with Skip. Confirm on your build.',
    stages: ['firstLogon'],
    mapping: 'config.json › featureUpdates (category 3689bdc8-b205-4af4-8d4b-a63924c5e9d5)',
    advanced: false,
    visibleWhen: on,
    verification: 'unverified',
  },
  {
    path: 'windowsUpdate.optionalUpdates',
    section: 'windowsUpdate',
    label: 'Optional and preview updates',
    control: 'radio',
    choices: [
      { value: 'skip', label: 'Skip' },
      { value: 'install', label: 'Install (owner default)' },
    ],
    description:
      'Updates Windows Update lists as optional (BrowseOnly): optional cumulative previews and optional driver updates (for example chipset drivers). Windows still decides what is applicable and signed; feature updates and Insider builds are never included here. Optional drivers also need "Drivers from Windows Update" to include drivers.',
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: 'config.json › optionalUpdates (IUpdate.BrowseOnly)',
    advanced: true,
    visibleWhen: on,
    verification: 'documented',
  },
  {
    path: 'windowsUpdate.microsoftUpdate',
    section: 'windowsUpdate',
    label: 'Also update other Microsoft products (Microsoft Update)',
    control: 'checkbox',
    description: 'Registers the Microsoft Update service so Office and other Microsoft products are updated too.',
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: 'config.json › microsoftUpdate (service 7971f918-a847-4430-9279-4a52d1efe18d)',
    advanced: true,
    visibleWhen: on,
    verification: 'documented',
  },
  limit('maxReboots', 'Maximum restarts', 'The engine stops with status Failed instead of restarting more often than this.'),
  limit('maxAttemptsPerUpdate', 'Attempts per update', 'An update that fails (or keeps being offered again) this many times is given up and reported.'),
  limit('maxRuntimeHours', 'Maximum total runtime in hours', 'Counted from the first start. Afterwards the engine finishes as Failed, or Offline if it never had a network connection.'),
  limit('networkWaitMinutes', 'Network wait per start in minutes', 'Without a connection the engine tries again at the next startup and every hour, until the runtime limit.'),
  limit('confirmationScans', 'Confirmation scans', 'Extra scans, one minute apart, after a scan finds nothing, before declaring success.'),
  {
    path: 'windowsUpdate.resetComponentsOnce',
    section: 'windowsUpdate',
    label: 'Reset Windows Update components once if updates keep failing',
    control: 'checkbox',
    description: 'Microsoft-documented repair: stops the update services and renames SoftwareDistribution and catroot2. Runs at most once per deployment, then gives each failing update one more try.',
    applicability: APPLIES,
    risk: 'Clears the update history shown in Settings.',
    stages: ['firstLogon'],
    mapping: 'config.json › resetComponentsOnce',
    advanced: true,
    visibleWhen: on,
    verification: 'documented',
  },
  limit('rebootWarningSeconds', 'Restart warning in seconds', 'Time between the on-screen warning and the restart (shutdown.exe /r /t).'),
  {
    path: 'windowsUpdate.excludedKbs',
    section: 'windowsUpdate',
    label: 'Never install these KB numbers',
    control: 'text',
    placeholder: 'e.g. KB5034441, KB5005463',
    description: 'Separate with commas or spaces. Excluded updates are reported as skipped, not as failures.',
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: 'config.json › excludedKbs',
    advanced: true,
    visibleWhen: on,
    verification: 'documented',
  },
];

export function validate(p: Profile, issues: Issue[]): void {
  const w = p.windowsUpdate;
  if (!w.enabled) return;
  const err = (path: string, message: string) => issues.push({ severity: 'error', path, message });
  for (const [key, [min, max]] of Object.entries(LIMITS) as [keyof typeof LIMITS, readonly [number, number]][]) {
    const v = w[key];
    if (v < min || v > max) err(`windowsUpdate.${key}`, `Must be between ${min} and ${max}.`);
  }
  if (w.drivers === 'include' && p.updates.excludeDrivers) {
    err(
      'windowsUpdate.drivers',
      'Installing drivers conflicts with "Do not include drivers with Windows quality updates": that policy hides drivers from Windows Update. Turn the policy off or choose another driver option.',
    );
  }
  const { invalid } = parseKbList(w.excludedKbs);
  if (invalid.length > 0) err('windowsUpdate.excludedKbs', `Not a KB number: ${invalid.slice(0, 5).join(', ')}. Use the form KB5034441.`);
}

/**
 * Embeds the engine files. The deployment orchestrator (Initialize-Deployment.ps1, the last
 * FirstLogon command, src/engine/deployment) runs INSTALLER_FILE from its verified package copy.
 */
export function modify(ctx: GenContext): void {
  if (!ctx.profile.windowsUpdate.enabled) return;
  for (const asset of updateEngineAssets(ctx.profile)) {
    if (EMBEDDED_UPDATE_FILES.includes(asset.name)) ctx.embedFile(`${STAGING_DIR}\\${asset.name}`, asset.content);
  }
}
