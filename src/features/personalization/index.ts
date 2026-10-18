import type { GenContext } from '../../engine/context';
import type { SettingDef } from '../../engine/settings/types';
import { HKU_DEFAULT } from '../shared';

/** Upstream `Effect` enum names = HKLM …\VisualEffects\<name> subkeys. */
const EFFECTS = [
  'ControlAnimations',
  'AnimateMinMax',
  'TaskbarAnimations',
  'DWMAeroPeekEnabled',
  'MenuAnimation',
  'TooltipAnimation',
  'SelectionFade',
  'DWMSaveThumbnailEnabled',
  'CursorShadow',
  'ListviewShadow',
  'ThumbnailsOrIcon',
  'ListviewAlphaSelect',
  'DragFullWindows',
  'ComboBoxAnimation',
  'FontSmoothing',
  'ListBoxSmoothScrolling',
  'DropShadow',
];

export const settings: SettingDef[] = [
  {
    path: 'personalization.visualEffects',
    section: 'personalization',
    label: 'Visual effects',
    control: 'radio',
    choices: [
      { value: 'default', label: 'Windows default (owner default)' },
      { value: 'bestAppearance', label: 'Adjust for best appearance' },
      { value: 'bestPerformance', label: 'Adjust for best performance' },
    ],
    description: 'A per-effect custom matrix is deferred to a later milestone.',
    applicability: 'Windows 10/11',
    stages: ['specialize', 'userOnce'],
    mapping: 'HKLM\\…\\Explorer\\VisualEffects\\<Effect>\\DefaultValue; UserOnce: HKCU\\…\\VisualEffects\\VisualFXSetting = 1|2',
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'personalization.stickyKeys',
    section: 'personalization',
    label: 'Sticky Keys',
    control: 'radio',
    choices: [
      { value: 'default', label: 'Windows default (owner default)' },
      { value: 'disabled', label: 'Disable Sticky Keys and its Shift×5 shortcut' },
    ],
    description: 'Lock keys, colors, wallpaper and lock-screen image always use the Windows default in M1.',
    applicability: 'Windows 10/11',
    stages: ['defaultUser', 'specialize'],
    mapping: `${HKU_DEFAULT}\\Control Panel\\Accessibility\\StickyKeys\\Flags and HKU\\.DEFAULT (logon screen) = "10"`,
    advanced: true,
    verification: 'upstream-tested',
  },
];

export function modifyEffects(ctx: GenContext): void {
  const mode = ctx.profile.personalization.visualEffects;
  if (mode === 'default') return;
  const on = mode === 'bestAppearance';
  ctx.seq.specialize.append(
    EFFECTS.map(
      (e) =>
        `Set-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects\\${e}" -Name 'DefaultValue' -Value ${on ? 1 : 0} -Type 'DWord' -Force;`,
    ).join('\n'),
  );
  ctx.seq.userOnce.append(
    `Set-ItemProperty -LiteralPath 'Registry::HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects' -Name 'VisualFXSetting' -Type 'DWord' -Value ${on ? 1 : 2} -Force;`,
  );
}

export function modifyStickyKeys(ctx: GenContext): void {
  if (ctx.profile.personalization.stickyKeys !== 'disabled') return;
  // SKF_AVAILABLE | SKF_CONFIRMHOTKEY without SKF_HOTKEYACTIVE (upstream DisabledStickyKeysSettings).
  const flags = 0x2 | 0x8;
  ctx.seq.defaultUser.append(`reg.exe add "${HKU_DEFAULT}\\Control Panel\\Accessibility\\StickyKeys" /v Flags /t REG_SZ /d ${flags} /f;`);
  ctx.seq.specialize.append(`reg.exe add "HKU\\.DEFAULT\\Control Panel\\Accessibility\\StickyKeys" /v Flags /t REG_SZ /d ${flags} /f;`);
}
