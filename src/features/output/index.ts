import type { SettingDef } from '../../engine/settings/types';

export const settings: SettingDef[] = [
  {
    path: 'output.answerFileName',
    section: 'output',
    label: 'Answer file name',
    control: 'radio',
    choices: [
      { value: 'autounattend.xml', label: 'autounattend.xml (found automatically on USB media)' },
      { value: 'notautounattend.xml', label: 'notautounattend.xml (not picked up automatically; for archiving or manual use)' },
    ],
    description:
      'Windows Setup only searches removable media for "autounattend.xml". Copy the file to the root of the installation USB drive yourself; this app never writes to boot media or ISOs.',
    applicability: 'All',
    stages: ['none'],
    mapping: 'Download filename only',
    advanced: true,
    verification: 'documented',
  },
];

export const deferredSettings: SettingDef[] = [
  {
    path: 'deferred.installPowerShell7',
    section: 'deferred',
    label: 'Install PowerShell 7 (planned)',
    control: 'checkbox',
    description:
      'Recorded only; nothing is generated for this switch. To install PowerShell 7, add "PowerShell 7" (Microsoft.PowerShell) under Application provisioning.',
    applicability: 'Recorded for the deployment bundle milestone',
    stages: ['deferred'],
    mapping: 'None (recorded in profile JSON)',
    advanced: false,
    verification: 'documented',
  },
];
