import type { GenContext } from '../../engine/context';
import type { SettingDef } from '../../engine/settings/types';
import { HKU_DEFAULT, regAdd } from '../shared';

const ADVANCED = `${HKU_DEFAULT}\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced`;

export const settings: SettingDef[] = [
  {
    path: 'explorer.showFileExtensions',
    section: 'explorer',
    label: 'Always show file extensions',
    control: 'checkbox',
    description: 'Helps spot disguised files such as "invoice.pdf.exe".',
    applicability: 'Windows 10/11',
    stages: ['defaultUser'],
    mapping: `${ADVANCED}\\HideFileExt = 0`,
    advanced: false,
    verification: 'upstream-tested',
  },
  {
    path: 'explorer.hiddenFiles',
    section: 'explorer',
    label: 'Hidden files',
    control: 'radio',
    choices: [
      { value: 'hideAll', label: 'Hide hidden and protected operating system files (Windows default)' },
      { value: 'showHidden', label: 'Show hidden files, hide protected OS files' },
      { value: 'showAll', label: 'Show all files' },
    ],
    description: '',
    applicability: 'Windows 10/11',
    stages: ['defaultUser'],
    mapping: `${ADVANCED}\\Hidden = 1 (show) and ShowSuperHidden = 1 (show protected)`,
    advanced: false,
    verification: 'upstream-tested',
  },
  {
    path: 'explorer.launchToThisPC',
    section: 'explorer',
    label: 'Open File Explorer to This PC',
    control: 'checkbox',
    description: 'Affects where File Explorer opens. This is separate from the This PC desktop icon.',
    applicability: 'Windows 10/11',
    stages: ['userOnce'],
    mapping: 'UserOnce.ps1: HKCU\\…\\Explorer\\Advanced\\LaunchTo = 1',
    advanced: false,
    verification: 'upstream-tested',
  },
  {
    path: 'explorer.classicContextMenu',
    section: 'explorer',
    label: 'Use the classic (Windows 10) context menu',
    control: 'checkbox',
    description: 'Owner default keeps the native Windows 11 context menu.',
    applicability: 'Windows 11',
    stages: ['userOnce'],
    mapping: 'UserOnce.ps1: HKCU\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\\InprocServer32 (empty default); restart Explorer',
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'explorer.hideInfoTip',
    section: 'explorer',
    label: 'Hide pop-up descriptions for folder and desktop items',
    control: 'checkbox',
    description: '',
    applicability: 'Windows 10/11',
    stages: ['defaultUser'],
    mapping: `${ADVANCED}\\ShowInfoTip = 0`,
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'explorer.removeShortcutArrows',
    section: 'explorer',
    label: 'Remove shortcut arrow overlays',
    control: 'checkbox',
    description:
      'Undocumented shell tweak: replaces shell icon index 29 (shortcut overlay) with a blank icon from imageres.dll. Not part of upstream. Some builds show black squares instead; verify in a VM. Thumbnail overlays are unchanged.',
    applicability: 'Windows 10/11 (undocumented)',
    risk: 'Not a supported Microsoft setting and may stop working or render incorrectly after feature updates. Undo by deleting the "29" value.',
    stages: ['specialize'],
    mapping: 'HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Shell Icons\\29 = "%SystemRoot%\\System32\\imageres.dll,-17" (REG_EXPAND_SZ)',
    advanced: false,
    verification: 'unverified',
  },
  {
    path: 'explorer.showEndTask',
    section: 'explorer',
    label: 'Show "End task" in taskbar right-click menu',
    control: 'checkbox',
    description: '',
    applicability: 'Windows 11 23H2+',
    stages: ['defaultUser'],
    mapping: `${ADVANCED}\\TaskbarDeveloperSettings\\TaskbarEndTask = 1`,
    advanced: true,
    verification: 'upstream-tested',
  },
];

export function modify(ctx: GenContext): void {
  const e = ctx.profile.explorer;
  const du = ctx.seq.defaultUser;
  if (e.showFileExtensions) du.append(regAdd(ADVANCED, 'HideFileExt', 0));
  if (e.hiddenFiles === 'showAll') du.append([regAdd(ADVANCED, 'Hidden', 1), regAdd(ADVANCED, 'ShowSuperHidden', 1)].join('\n'));
  if (e.hiddenFiles === 'showHidden') du.append(regAdd(ADVANCED, 'Hidden', 1));
  if (e.classicContextMenu) {
    ctx.seq.userOnce.append('reg.exe add "HKCU\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\\InprocServer32" /ve /f;');
    ctx.seq.userOnce.requestExplorerRestart();
  }
  if (e.launchToThisPC) {
    ctx.seq.userOnce.append("Set-ItemProperty -LiteralPath 'Registry::HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced' -Name 'LaunchTo' -Type 'DWord' -Value 1;");
  }
  if (e.showEndTask) du.append(regAdd(`${ADVANCED}\\TaskbarDeveloperSettings`, 'TaskbarEndTask', 1));
  if (e.hideInfoTip) du.append(regAdd(ADVANCED, 'ShowInfoTip', 0));
  if (e.removeShortcutArrows) {
    ctx.seq.specialize.append(regAdd('HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Shell Icons', '29', '%SystemRoot%\\System32\\imageres.dll,-17', 'REG_EXPAND_SZ'));
  }
}
