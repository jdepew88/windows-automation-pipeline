import type { GenContext } from '../../engine/context';
import type { SettingDef } from '../../engine/settings/types';
import type { Profile } from '../../engine/schema/profile';
import type { Issue } from '../../engine/validation/issues';
import { DESKTOP_ICONS } from '../../data';

export const settings: SettingDef[] = [
  {
    path: 'desktop.deleteEdgeShortcut',
    section: 'desktop',
    label: 'Remove the Microsoft Edge desktop shortcut',
    control: 'checkbox',
    description: 'Edge itself stays installed.',
    applicability: 'Windows 10/11',
    stages: ['specialize', 'userOnce'],
    mapping: "Remove-Item 'C:\\Users\\Public\\Desktop\\Microsoft Edge.lnk' (specialize) and '%USERPROFILE%\\Desktop\\Microsoft Edge.lnk' (UserOnce)",
    advanced: false,
    verification: 'upstream-tested',
  },
  {
    path: 'desktop.iconsMode',
    section: 'desktop',
    label: 'Desktop icons',
    control: 'radio',
    choices: [
      { value: 'default', label: 'Windows default' },
      { value: 'custom', label: 'Show only the icons selected below' },
    ],
    description: 'The This PC desktop icon is independent of "Open File Explorer to This PC".',
    applicability: 'Windows 10/11',
    stages: ['userOnce'],
    mapping: 'UserOnce.ps1: HKCU\\…\\Explorer\\HideDesktopIcons\\{ClassicStartMenu,NewStartPanel}\\<GUID> = 0 (show) | 1 (hide); restart Explorer',
    advanced: false,
    verification: 'upstream-tested',
  },
  {
    path: 'desktop.icons',
    section: 'desktop',
    label: 'Icons shown on the desktop',
    control: 'custom',
    choices: () => DESKTOP_ICONS.map((i) => ({ value: i.Id, label: i.DisplayName })),
    description: 'Owner default: Recycle Bin only.',
    applicability: 'Windows 10/11 (Gallery and Home: Windows 11)',
    stages: ['userOnce'],
    mapping: 'HideDesktopIcons GUIDs from upstream resource/DesktopIcon.json',
    advanced: false,
    visibleWhen: (p) => p.desktop.iconsMode === 'custom',
    verification: 'upstream-tested',
  },
];

export function validate(p: Profile, issues: Issue[]): void {
  const known = new Set(DESKTOP_ICONS.map((i) => i.Id));
  for (const id of Object.keys(p.desktop.icons)) {
    if (!known.has(id)) issues.push({ severity: 'error', path: 'desktop.icons', message: `Unknown desktop icon "${id}".` });
  }
}

export function modify(ctx: GenContext): void {
  const d = ctx.profile.desktop;
  if (d.deleteEdgeShortcut) {
    ctx.seq.specialize.append("Remove-Item -LiteralPath 'C:\\Users\\Public\\Desktop\\Microsoft Edge.lnk' -ErrorAction 'SilentlyContinue' -Verbose;");
    ctx.seq.userOnce.append('Remove-Item -LiteralPath "${env:USERPROFILE}\\Desktop\\Microsoft Edge.lnk" -ErrorAction \'SilentlyContinue\' -Verbose;');
  }
}

/** Applied after visual effects, as in upstream. Icons sorted by ID for deterministic output. */
export function modifyIcons(ctx: GenContext): void {
  const d = ctx.profile.desktop;
  if (d.iconsMode !== 'custom') return;
  const icons = [...DESKTOP_ICONS].sort((a, b) => (a.Id < b.Id ? -1 : 1));
  const lines: string[] = [];
  for (const key of ['ClassicStartMenu', 'NewStartPanel']) {
    const path = `Registry::HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\HideDesktopIcons\\${key}`;
    lines.push(`New-Item -Path '${path}' -Force;`);
    for (const icon of icons) {
      const show = d.icons[icon.Id] ?? false;
      lines.push(`Set-ItemProperty -Path '${path}' -Name '${icon.Guid}' -Value ${show ? 0 : 1} -Type 'DWord';`);
    }
  }
  ctx.seq.userOnce.append(lines.join('\n'));
  ctx.seq.userOnce.requestExplorerRestart();
}
