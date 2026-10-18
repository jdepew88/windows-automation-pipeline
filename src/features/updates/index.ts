import type { GenContext } from '../../engine/context';
import type { SettingDef } from '../../engine/settings/types';
import type { Profile } from '../../engine/schema/profile';
import type { Issue } from '../../engine/validation/issues';
import { UPSTREAM_RESOURCES } from '../../engine/resources/upstream';
import { HKLM_POLICIES, regAdd } from '../shared';

const WU = `${HKLM_POLICIES}\\Windows\\WindowsUpdate`;
const AU = `${WU}\\AU`;

export const settings: SettingDef[] = [
  {
    path: 'updates.mode',
    section: 'updates',
    label: 'Windows Update installation',
    control: 'radio',
    choices: [
      { value: 'notifyInstall', label: 'Download automatically, notify to install (owner default)' },
      { value: 'notifyDownload', label: 'Notify before download and install' },
      { value: 'windowsDefault', label: 'Fully automatic (Windows default)' },
    ],
    description:
      'Uses the "Configure Automatic Updates" policy. Windows Update stays enabled. Security intelligence (Defender) and Store app updates are not governed by this policy, and Settings will show "Some settings are managed by your organization".',
    applicability: 'Windows 10/11 Pro and higher. Microsoft may still enforce installation of some quality updates.',
    risk: 'Manual install modes delay security fixes if nobody acts on the notifications.',
    stages: ['specialize'],
    mapping: `${AU}\\NoAutoUpdate = 0, AUOptions = 3 (notify install) or 2 (notify download)`,
    advanced: false,
    verification: 'documented',
  },
  {
    path: 'updates.excludeDrivers',
    section: 'updates',
    label: 'Do not include drivers with Windows quality updates',
    control: 'checkbox',
    description: 'Drivers can still be installed from Device Manager, OEM tools or optional updates.',
    applicability: 'Windows 10/11 Pro and higher',
    stages: ['specialize'],
    mapping: `${WU}\\ExcludeWUDriversInQualityUpdate = 1`,
    advanced: false,
    verification: 'documented',
  },
  {
    path: 'updates.preventAutomaticReboot',
    section: 'updates',
    label: 'Prevent Windows Update from rebooting while a user is signed in',
    control: 'checkbox',
    description:
      'Upstream workaround: forces AUOptions=4 with NoAutoRebootWithLoggedOnUsers=1 and a scheduled task that keeps moving active hours. Not part of the owner default.',
    applicability: 'Windows 10/11',
    risk: 'Relies on a recurring scheduled task. Can only be combined with fully automatic updates.',
    stages: ['specialize'],
    mapping: `${AU}\\AUOptions = 4, NoAutoRebootWithLoggedOnUsers = 1; scheduled task MoveActiveHours`,
    advanced: true,
    verification: 'upstream-tested',
  },
];

export function validate(p: Profile, issues: Issue[]): void {
  if (p.updates.preventAutomaticReboot && p.updates.mode !== 'windowsDefault') {
    issues.push({
      severity: 'error',
      path: 'updates.preventAutomaticReboot',
      message: 'Preventing automatic reboots sets AUOptions=4 (automatic) and conflicts with the selected notify mode. Choose fully automatic updates or turn this off.',
    });
  }
}

export function modify(ctx: GenContext): void {
  const u = ctx.profile.updates;
  const sp = ctx.seq.specialize;
  if (u.mode === 'notifyInstall' || u.mode === 'notifyDownload') {
    sp.append([regAdd(AU, 'NoAutoUpdate', 0), regAdd(AU, 'AUOptions', u.mode === 'notifyInstall' ? 3 : 2)].join('\n'));
  }
  if (u.excludeDrivers) sp.append(regAdd(WU, 'ExcludeWUDriversInQualityUpdate', 1));
  if (u.preventAutomaticReboot) {
    sp.append([regAdd(AU, 'AUOptions', 4), regAdd(AU, 'NoAutoRebootWithLoggedOnUsers', 1)].join('\n'));
    const xml = ctx.embedFile('MoveActiveHours.xml', UPSTREAM_RESOURCES['MoveActiveHours.xml']);
    sp.append(`Register-ScheduledTask -TaskName 'MoveActiveHours' -Xml $( Get-Content -LiteralPath '${xml}' -Raw );`);
  }
}
