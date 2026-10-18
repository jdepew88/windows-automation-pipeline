import type { GenContext } from '../../engine/context';
import type { SettingDef } from '../../engine/settings/types';
import type { Profile } from '../../engine/schema/profile';
import type { Issue } from '../../engine/validation/issues';
import { EDITIONS, GEO_LOCATIONS, IMAGE_LANGUAGES, KEYBOARDS, TIME_ZONES, USER_LOCALES, lookup } from '../../data';
import { child, remove } from '../../engine/xml/tree';

const unattendedLang = (p: Profile) => p.setup.languageMode === 'unattended';

export const settings: SettingDef[] = [
  {
    path: 'setup.languageMode',
    section: 'setup',
    label: 'Language settings',
    control: 'radio',
    choices: [
      { value: 'unattended', label: 'Set language, region and keyboard in the answer file' },
      { value: 'interactive', label: 'Choose language settings interactively during Setup' },
    ],
    description: 'Unattended language settings skip the language pages in Windows Setup and OOBE.',
    applicability: 'Windows 10/11, all editions. The display language must exist in the installation image.',
    stages: ['windowsPE', 'oobeSystem'],
    mapping: 'windowsPE › Microsoft-Windows-International-Core-WinPE › UILanguage; oobeSystem › Microsoft-Windows-International-Core › InputLocale/SystemLocale/UILanguage/UserLocale. Interactive removes both components.',
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'setup.imageLanguage',
    section: 'setup',
    label: 'Windows display language',
    control: 'select',
    choices: () => IMAGE_LANGUAGES.map((l) => ({ value: l.Id, label: `${l.DisplayName} (${l.Id})` })),
    description: 'Must match a language contained in the install.wim of your media.',
    applicability: 'Windows 10/11',
    stages: ['windowsPE', 'oobeSystem'],
    mapping: 'International-Core-WinPE/UILanguage and International-Core/UILanguage',
    advanced: true,
    visibleWhen: unattendedLang,
    verification: 'upstream-tested',
  },
  {
    path: 'setup.userLocale',
    section: 'setup',
    label: 'Format and region (user locale)',
    control: 'select',
    choices: () => USER_LOCALES.map((l) => ({ value: l.Id, label: l.DisplayName })),
    description: 'Date, time, number and currency formats. Also used as the system locale.',
    applicability: 'Windows 10/11',
    stages: ['oobeSystem'],
    mapping: 'International-Core/SystemLocale and /UserLocale; LCID used in InputLocale',
    advanced: true,
    visibleWhen: unattendedLang,
    verification: 'upstream-tested',
  },
  {
    path: 'setup.keyboard',
    section: 'setup',
    label: 'Keyboard layout',
    control: 'select',
    choices: () => KEYBOARDS.map((k) => ({ value: k.Id, label: `${k.DisplayName}${k.Type === 'IME' ? ' (IME)' : ''}` })),
    description: 'Input method paired with the user locale.',
    applicability: 'Windows 10/11',
    stages: ['oobeSystem'],
    mapping: 'International-Core/InputLocale = "<LCID>:<keyboard id>"',
    advanced: true,
    visibleWhen: unattendedLang,
    verification: 'upstream-tested',
  },
  {
    path: 'setup.geoLocation',
    section: 'setup',
    label: 'Home location',
    control: 'select',
    choices: () => GEO_LOCATIONS.map((g) => ({ value: g.Id, label: g.DisplayName })),
    description: 'Country/region used by Store and regional content.',
    applicability: 'Windows 10/11',
    stages: ['userOnce'],
    mapping: 'Only when it differs from the locale default: UserOnce › Set-WinHomeLocation -GeoId <id>',
    advanced: true,
    visibleWhen: unattendedLang,
    verification: 'upstream-tested',
  },
  {
    path: 'setup.editionMode',
    section: 'setup',
    label: 'Edition and setup key',
    control: 'radio',
    choices: [
      { value: 'genericKey', label: 'Install the selected edition using its generic installation key' },
      { value: 'interactive', label: 'Choose edition interactively during Setup' },
      { value: 'firmware', label: 'Use the product key stored in BIOS/UEFI firmware' },
      { value: 'customKey', label: 'Enter a product key' },
    ],
    description:
      'Generic installation keys only select which edition is installed. They do not license or activate Windows.',
    applicability: 'Windows 11 retail/OEM media containing the chosen edition',
    risk: 'A generic key is not a license. Windows stays unactivated until a valid license or digital entitlement applies.',
    stages: ['windowsPE', 'specialize'],
    mapping:
      'windowsPE › Microsoft-Windows-Setup › UserData/ProductKey/Key + WillShowUI (OnError; Always with 00000-… for interactive; Never and no Key for firmware). A custom key is also written to specialize › Microsoft-Windows-Shell-Setup › ProductKey.',
    advanced: false,
    verification: 'upstream-tested',
  },
  {
    path: 'setup.editionId',
    section: 'setup',
    label: 'Edition',
    control: 'select',
    choices: () => EDITIONS.filter((e) => e.Visible).map((e) => ({ value: e.Id, label: `Windows 11 ${e.DisplayName}` })),
    description: 'Windows 11 Pro is the owner default.',
    applicability: 'Media must contain the edition',
    stages: ['windowsPE'],
    mapping: 'Generic key for the edition (upstream resource/WindowsEdition.json)',
    advanced: false,
    visibleWhen: (p) => p.setup.editionMode === 'genericKey',
    verification: 'upstream-tested',
  },
  {
    path: 'setup.customProductKey',
    section: 'setup',
    label: 'Product key',
    control: 'text',
    placeholder: 'XXXXX-XXXXX-XXXXX-XXXXX-XXXXX',
    description: 'Stored in plain text in the answer file. Do not commit answer files that contain a real key.',
    applicability: 'Windows 10/11',
    risk: 'Secret-like data: the key appears in the answer file and in C:\\Windows\\Panther until it is deleted.',
    stages: ['windowsPE', 'specialize'],
    mapping: 'UserData/ProductKey/Key and specialize › Shell-Setup › ProductKey',
    advanced: true,
    visibleWhen: (p) => p.setup.editionMode === 'customKey',
    verification: 'upstream-tested',
  },
  {
    path: 'setup.diskMode',
    section: 'setup',
    label: 'Disk selection and partitioning',
    control: 'radio',
    choices: [{ value: 'interactive', label: 'Interactive. You select, create and format the target partition in Windows Setup.' }],
    description:
      'The answer file contains no DiskConfiguration, ImageInstall/InstallTo or WillWipeDisk elements, so Windows Setup always stops at the disk page. Automatic disk preparation is deliberately not offered.',
    applicability: 'All',
    stages: ['none'],
    mapping: 'Absence of windowsPE › Microsoft-Windows-Setup › DiskConfiguration / ImageInstall (asserted by tests)',
    advanced: false,
    verification: 'documented',
  },
  {
    path: 'setup.bypassRequirementsCheck',
    section: 'setup',
    label: 'Bypass Windows 11 hardware requirements check (TPM, Secure Boot, RAM)',
    control: 'checkbox',
    description: 'Only for VMs or unsupported hardware. Unsupported devices may not receive updates.',
    applicability: 'Windows 11 Setup (windowsPE)',
    risk: 'Microsoft does not support Windows 11 on hardware that fails these checks.',
    stages: ['windowsPE'],
    mapping: 'windowsPE RunSynchronous: reg.exe add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck|BypassSecureBootCheck|BypassRAMCheck = 1',
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'setup.bypassNetworkCheck',
    section: 'setup',
    label: 'Allow OOBE to proceed without an Internet connection (BypassNRO)',
    control: 'checkbox',
    description:
      'Not needed when the local account is created by this answer file. Relevant only for interactive account modes. Microsoft has been removing this switch from newer builds.',
    applicability: 'Windows 11 builds that still honor BypassNRO',
    stages: ['specialize'],
    mapping: 'Specialize.ps1: reg.exe add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1',
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'setup.processorArchitectures',
    section: 'setup',
    label: 'Processor architectures',
    control: 'custom',
    choices: [
      { value: 'amd64', label: 'Intel/AMD 64-bit (amd64)' },
      { value: 'arm64', label: 'Arm64' },
      { value: 'x86', label: 'Intel/AMD 32-bit (x86, Windows 10 only)' },
    ],
    description: 'Every component is emitted once per selected architecture. Windows Setup ignores components that do not match.',
    applicability: 'Windows 11 has no x86 edition',
    stages: ['windowsPE', 'specialize', 'oobeSystem'],
    mapping: 'component/@processorArchitecture (component duplicated per architecture)',
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'setup.timeZoneMode',
    section: 'setup',
    label: 'Time zone',
    control: 'radio',
    choices: [
      { value: 'implicit', label: 'Let Windows determine the time zone' },
      { value: 'explicit', label: 'Set the time zone explicitly' },
    ],
    description: 'If the time zone is not set, Windows derives it from region settings and location (location is disabled by owner privacy defaults).',
    applicability: 'Windows 10/11',
    stages: ['specialize'],
    mapping: 'specialize › Microsoft-Windows-Shell-Setup › TimeZone',
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'setup.timeZone',
    section: 'setup',
    label: 'Time zone ID',
    control: 'select',
    choices: () => TIME_ZONES.map((t) => ({ value: t.Id, label: t.DisplayName })),
    description: 'Windows time zone identifier.',
    applicability: 'Windows 10/11',
    stages: ['specialize'],
    mapping: 'specialize › Microsoft-Windows-Shell-Setup › TimeZone',
    advanced: true,
    visibleWhen: (p) => p.setup.timeZoneMode === 'explicit',
    verification: 'upstream-tested',
  },
  {
    path: 'setup.useConfigurationSet',
    section: 'setup',
    label: 'Use a configuration set / distribution share ($OEM$ folders)',
    control: 'checkbox',
    description: 'Lets Setup copy $OEM$ folders from the media. Leave off unless you prepared a configuration set.',
    applicability: 'Windows 10/11',
    stages: ['windowsPE'],
    mapping: 'windowsPE › Microsoft-Windows-Setup › UseConfigurationSet = true',
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'setup.useNarrator',
    section: 'setup',
    label: 'Start Narrator during Setup and for new users',
    control: 'checkbox',
    description: 'Accessibility aid for blind or low-vision installers.',
    applicability: 'Windows 10/11',
    stages: ['windowsPE', 'specialize', 'userOnce'],
    mapping: 'windowsPE RunSynchronous: start X:\\Windows\\System32\\Narrator.exe; specialize + UserOnce: Accessibility\\Configuration = narrator',
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'setup.hidePowerShellWindows',
    section: 'setup',
    label: 'Hide PowerShell windows while setup scripts run',
    control: 'checkbox',
    description: 'Hidden windows are quieter but make it harder to see progress or failures.',
    applicability: 'All',
    stages: ['specialize', 'firstLogon'],
    mapping: 'powershell.exe -WindowStyle Hidden instead of Normal',
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'setup.keepSensitiveFiles',
    section: 'setup',
    label: 'Keep sensitive files after setup',
    control: 'checkbox',
    description:
      'By default, the first logon deletes C:\\Windows\\Panther\\unattend.xml, unattend-original.xml and the staged Wi-Fi profile, because they can contain passwords and keys.',
    applicability: 'All',
    risk: 'Keeping them leaves account/Wi-Fi data readable on disk.',
    stages: ['firstLogon'],
    mapping: 'FirstLogon.ps1: Remove-Item C:\\Windows\\Panther\\unattend.xml, unattend-original.xml, C:\\Windows\\Setup\\Scripts\\Wifi.xml',
    advanced: true,
    verification: 'upstream-tested',
  },
];

export function validate(p: Profile, issues: Issue[]): void {
  const s = p.setup;
  if (s.languageMode === 'unattended') {
    if (!lookup.imageLanguage(s.imageLanguage)) issues.push({ severity: 'error', path: 'setup.imageLanguage', message: `Unknown display language "${s.imageLanguage}".` });
    if (!lookup.userLocale(s.userLocale)) issues.push({ severity: 'error', path: 'setup.userLocale', message: `Unknown user locale "${s.userLocale}".` });
    if (!lookup.keyboard(s.keyboard)) issues.push({ severity: 'error', path: 'setup.keyboard', message: `Unknown keyboard layout "${s.keyboard}".` });
    if (!lookup.geo(s.geoLocation)) issues.push({ severity: 'error', path: 'setup.geoLocation', message: `Unknown home location "${s.geoLocation}".` });
  }
  if (s.editionMode === 'genericKey' && !lookup.edition(s.editionId)) {
    issues.push({ severity: 'error', path: 'setup.editionId', message: `Unknown edition "${s.editionId}".` });
  }
  if (s.editionMode === 'customKey' && !/^([A-Z0-9]{5}-){4}[A-Z0-9]{5}$/i.test(s.customProductKey)) {
    issues.push({ severity: 'error', path: 'setup.customProductKey', message: 'Product key must have the form XXXXX-XXXXX-XXXXX-XXXXX-XXXXX.' });
  }
  if (s.processorArchitectures.length === 0) {
    issues.push({ severity: 'error', path: 'setup.processorArchitectures', message: 'Select at least one processor architecture.' });
  }
  if (new Set(s.processorArchitectures).size !== s.processorArchitectures.length) {
    issues.push({ severity: 'error', path: 'setup.processorArchitectures', message: 'Each processor architecture may be listed only once.' });
  }
  if (s.timeZoneMode === 'explicit' && !lookup.timeZone(s.timeZone)) {
    issues.push({ severity: 'error', path: 'setup.timeZone', message: `Unknown time zone "${s.timeZone}".` });
  }
}

export function modify(ctx: GenContext): void {
  const s = ctx.profile.setup;

  // Accessibility (upstream AccessibilityModifier) runs first so Narrator starts early in PE.
  if (s.useNarrator) {
    ctx.appendCommand('windowsPE', ctx.cmd.shell('start X:\\Windows\\System32\\Narrator.exe'));
    ctx.seq.specialize.append(`& 'C:\\Windows\\System32\\Narrator.exe';
reg.exe ADD "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Accessibility" /v Configuration /t REG_SZ /d narrator /f;`);
    ctx.seq.userOnce.append(`& 'C:\\Windows\\System32\\Narrator.exe';
reg.exe ADD "HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Accessibility" /v Configuration /t REG_SZ /d narrator /f;`);
  }

  // Bypass (upstream BypassModifier).
  if (s.bypassRequirementsCheck) {
    for (const value of ['BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck']) {
      ctx.appendCommand('windowsPE', ctx.cmd.registry(`add "HKLM\\SYSTEM\\Setup\\LabConfig" /v ${value} /t REG_DWORD /d 1 /f`));
    }
  }
  if (s.bypassNetworkCheck) {
    ctx.seq.specialize.append('reg.exe add "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f;');
  }

  // Product key (upstream ProductKeyModifier).
  const productKey = child(ctx.componentChild('windowsPE', 'Microsoft-Windows-Setup', 'UserData'), 'ProductKey')!;
  const key = child(productKey, 'Key')!;
  const ui = child(productKey, 'WillShowUI')!;
  const set = (k: string | undefined, show: string) => {
    if (k === undefined) remove(productKey, key);
    else key.children = [{ kind: 'text', value: k }];
    ui.children = [{ kind: 'text', value: show }];
  };
  switch (s.editionMode) {
    case 'genericKey':
      set(lookup.edition(s.editionId)!.ProductKey, 'OnError');
      break;
    case 'customKey':
      set(s.customProductKey.toUpperCase(), 'OnError');
      ctx.setValue('specialize', 'Microsoft-Windows-Shell-Setup', 'ProductKey', s.customProductKey.toUpperCase());
      break;
    case 'interactive':
      set('00000-00000-00000-00000-00000', 'Always');
      break;
    case 'firmware':
      set(undefined, 'Never');
      break;
  }

  // Locales (upstream LocalesModifier).
  const pe = ctx.findComponent('windowsPE', 'Microsoft-Windows-International-Core-WinPE')!;
  const oobe = ctx.findComponent('oobeSystem', 'Microsoft-Windows-International-Core')!;
  if (s.languageMode === 'interactive') {
    remove(ctx.settings('windowsPE'), pe);
    remove(ctx.settings('oobeSystem'), oobe);
  } else {
    const locale = lookup.userLocale(s.userLocale)!;
    const keyboard = lookup.keyboard(s.keyboard)!;
    let lcid = locale.LCID;
    if (lcid === '1000') {
      // Locales without their own LCID borrow the display language's (upstream behaviour).
      const replacement =
        lookup.userLocale(s.imageLanguage) ??
        (s.imageLanguage === 'zh-CN' ? lookup.userLocale('zh') : s.imageLanguage === 'zh-TW' ? lookup.userLocale('zh-Hant') : undefined);
      lcid = replacement?.LCID ?? lcid;
    }
    const inputLocale = keyboard.Type === 'IME' ? keyboard.Id : `${lcid}:${keyboard.Id}`;
    const setText = (comp: typeof pe, name: string, value: string) => {
      child(comp, name)!.children = [{ kind: 'text', value }];
    };
    setText(pe, 'UILanguage', s.imageLanguage);
    setText(oobe, 'InputLocale', inputLocale);
    setText(oobe, 'SystemLocale', locale.Id);
    setText(oobe, 'UILanguage', s.imageLanguage);
    setText(oobe, 'UserLocale', locale.Id);
    if (s.geoLocation !== locale.GeoLocation) {
      ctx.seq.userOnce.append(`Set-WinHomeLocation -GeoId ${s.geoLocation};`);
    }
  }

  if (s.useConfigurationSet) {
    child(ctx.component('windowsPE', 'Microsoft-Windows-Setup'), 'UseConfigurationSet')!.children = [{ kind: 'text', value: 'true' }];
  }
}

/** Applied late, mirroring upstream TimeZoneModifier's position after the optimizations. */
export function modifyTimeZone(ctx: GenContext): void {
  const s = ctx.profile.setup;
  if (s.timeZoneMode === 'explicit') {
    ctx.setValue('specialize', 'Microsoft-Windows-Shell-Setup', 'TimeZone', lookup.timeZone(s.timeZone)!.Id);
  }
}
