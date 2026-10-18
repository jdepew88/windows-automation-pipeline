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
      'Recorded for a later milestone only. An XML-only answer file cannot install PowerShell 7 without staged installers or network downloads, so M1 generates nothing for this.',
    applicability: 'Later milestone (WinGet / staged installers)',
    stages: ['deferred'],
    mapping: 'None in M1 (recorded in profile JSON)',
    advanced: false,
    verification: 'documented',
  },
  {
    path: 'deferred.wingetPackages',
    section: 'deferred',
    label: 'WinGet packages (planned)',
    control: 'custom',
    description:
      'Empty by default. Lists from imported profiles live in memory for this session only and are never saved automatically. M1 does not install, search for or validate packages.',
    applicability: 'Later milestone',
    stages: ['deferred'],
    mapping: 'None in M1',
    advanced: true,
    verification: 'documented',
  },
];
