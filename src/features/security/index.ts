import type { GenContext } from '../../engine/context';
import type { SettingDef } from '../../engine/settings/types';
import type { Profile } from '../../engine/schema/profile';
import type { Issue } from '../../engine/validation/issues';
import { parseXml } from '../../engine/xml/parse';
import { HKLM_POLICIES, HKU_DEFAULT, regAdd } from '../shared';

const UAC_KEY = 'HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System';

export const settings: SettingDef[] = [
  {
    path: 'security.uacLevel',
    section: 'security',
    label: 'User Account Control level',
    control: 'radio',
    choices: [
      { value: 'alwaysNotify', label: 'Always notify' },
      { value: 'windowsDefault', label: 'Notify only when apps make changes (Windows default, dims desktop)' },
      { value: 'noDim', label: 'Notify only when apps make changes, do not dim the desktop (owner default)' },
      { value: 'neverNotify', label: 'Never notify (UAC still enabled)' },
      { value: 'disabled', label: 'Disable UAC entirely (EnableLUA=0)' },
    ],
    description:
      'Owner default is the second-lowest slider position: EnableLUA=1, ConsentPromptBehaviorAdmin=5, PromptOnSecureDesktop=0. Set in specialize, so it is active after the reboot into OOBE.',
    applicability: 'Windows 10/11',
    risk: 'Without the secure desktop, other programs in the session can see or interfere with the prompt. "Disabled" also breaks Store apps and is strongly discouraged.',
    stages: ['specialize'],
    mapping: `Specialize.ps1: ${UAC_KEY} EnableLUA, ConsentPromptBehaviorAdmin, PromptOnSecureDesktop (DWORD)`,
    advanced: false,
    verification: 'documented',
  },
  {
    path: 'security.disableSmartScreen',
    section: 'security',
    label: 'Disable SmartScreen in Windows and Edge',
    control: 'checkbox',
    description: 'Owner default keeps SmartScreen enabled.',
    applicability: 'Windows 10/11',
    risk: 'Removes reputation-based protection against malicious downloads and sites.',
    stages: ['specialize', 'defaultUser'],
    mapping: 'HKLM …\\Explorer\\SmartScreenEnabled=Off; WTDS\\Components; Edge SmartScreen (default user hive)',
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'security.disableSmartAppControl',
    section: 'security',
    label: 'Disable Smart App Control',
    control: 'checkbox',
    description: 'Owner default leaves SAC in its Windows-managed state (evaluation on clean installs, where supported).',
    applicability: 'Windows 11 22H2+ clean installs',
    risk: 'SAC cannot be re-enabled without reinstalling Windows.',
    stages: ['specialize'],
    mapping: 'HKLM\\SYSTEM\\CurrentControlSet\\Control\\CI\\Policy\\VerifiedAndReputablePolicyState = 0',
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'security.systemRestore',
    section: 'security',
    label: 'System Restore (System Protection on C:)',
    control: 'radio',
    choices: [
      { value: 'enable', label: 'Turn on for C: at first logon' },
      { value: 'windowsDefault', label: 'Windows default' },
      { value: 'disable', label: 'Turn off for C:' },
    ],
    description: 'Windows does not always enable System Protection on fresh installs. The owner default enables it explicitly.',
    applicability: 'Windows 10/11 (Windows PowerShell 5.1 cmdlets)',
    stages: ['firstLogon'],
    mapping: "FirstLogon.ps1: Enable-ComputerRestore / Disable-ComputerRestore -Drive 'C:\\'",
    advanced: false,
    verification: 'unverified',
  },
  {
    path: 'security.preventDeviceEncryption',
    section: 'security',
    label: 'Prevent automatic device encryption (BitLocker)',
    control: 'checkbox',
    description: 'Owner default keeps device encryption support. BitLocker can be managed later.',
    applicability: 'Windows 11 24H2+ device encryption',
    risk: 'Leaves the disk unencrypted unless BitLocker is enabled manually.',
    stages: ['specialize'],
    mapping: 'HKLM\\SYSTEM\\CurrentControlSet\\Control\\BitLocker\\PreventDeviceEncryption = 1',
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'security.enableRemoteDesktop',
    section: 'security',
    label: 'Enable Remote Desktop',
    control: 'checkbox',
    description: 'Owner default: disabled (Windows default).',
    applicability: 'Windows 11 Pro and higher (not Home)',
    risk: 'Exposes the machine to network logons. Never combine with an empty password.',
    stages: ['specialize'],
    mapping: 'netsh advfirewall Remote Desktop rule group; HKLM\\…\\Terminal Server\\fDenyTSConnections = 0',
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'security.processAudit',
    section: 'security',
    label: 'Audit process creation',
    control: 'radio',
    choices: [
      { value: 'disabled', label: 'Off (Windows default)' },
      { value: 'enabled', label: 'Log process creation events (4688)' },
      { value: 'enabledWithCommandLine', label: 'Log process creation including command lines' },
    ],
    description: 'Useful for forensics. Command lines may contain secrets.',
    applicability: 'Windows 10/11',
    stages: ['specialize'],
    mapping: 'auditpol.exe /set /subcategory:{0CCE922B-…} ; …\\Policies\\System\\Audit\\ProcessCreationIncludeCmdLine_Enabled',
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'security.disableInsiderBuilds',
    section: 'security',
    label: 'Prevent Windows Insider enrollment',
    control: 'checkbox',
    description: 'Fresh installs are not enrolled. This policy also hides the option to join.',
    applicability: 'Windows 10/11 Pro+ (Group Policy "Toggle user control over Insider builds")',
    stages: ['specialize'],
    mapping: `${HKLM_POLICIES}\\Windows\\PreviewBuilds\\AllowBuildPreview = 0`,
    advanced: true,
    verification: 'documented',
  },
  {
    path: 'security.appLockerMode',
    section: 'security',
    label: 'AppLocker',
    control: 'radio',
    choices: [
      { value: 'none', label: 'Do not configure (owner default)' },
      { value: 'policy', label: 'Apply this AppLocker policy XML' },
    ],
    description: 'AppLocker enforcement requires the Application Identity service, which this option sets to Automatic.',
    applicability: 'Microsoft documents AppLocker for Enterprise/Education. Enforcement on Pro has varied between builds, so verify on your target build.',
    risk: 'A wrong policy can block Explorer or setup scripts. Test in a VM.',
    stages: ['specialize'],
    mapping: 'Embedded AppLockerPolicy.xml; Specialize.ps1: Set-Service AppIDSvc Automatic; Set-AppLockerPolicy -XmlPolicy',
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'security.appLockerPolicyXml',
    section: 'security',
    label: 'AppLocker policy XML',
    control: 'textarea',
    placeholder: '<AppLockerPolicy Version="1"> … </AppLockerPolicy>',
    description: 'Export from secpol.msc or Get-AppLockerPolicy -Xml. Checked for well-formedness and structure; not schema-validated in the browser.',
    applicability: 'See AppLocker',
    stages: ['specialize'],
    mapping: 'C:\\Windows\\Setup\\Scripts\\AppLockerPolicy.xml',
    advanced: true,
    visibleWhen: (p) => p.security.appLockerMode === 'policy',
    verification: 'upstream-tested',
  },
];

export function validate(p: Profile, issues: Issue[]): void {
  if (p.security.appLockerMode === 'policy') {
    const path = 'security.appLockerPolicyXml';
    if (p.security.appLockerPolicyXml.trim() === '') {
      issues.push({ severity: 'error', path, message: 'Paste an AppLocker policy or choose "Do not configure".' });
      return;
    }
    const r = parseXml(p.security.appLockerPolicyXml);
    if (!r.root) {
      issues.push({ severity: 'error', path, message: `AppLocker policy XML is not well-formed: ${r.errors[0]}` });
    } else if (r.root.name !== 'AppLockerPolicy' || r.root.ns !== '') {
      issues.push({ severity: 'error', path, message: 'Root element must be <AppLockerPolicy> without a namespace.' });
    } else if (!r.root.attrs.some((a) => a.name === 'Version')) {
      issues.push({ severity: 'error', path, message: '<AppLockerPolicy> must have a Version attribute.' });
    }
  }
}

export function modify(ctx: GenContext): void {
  const s = ctx.profile.security;
  const sp = ctx.seq.specialize;

  if (s.disableSmartAppControl) sp.append(regAdd('HKLM\\SYSTEM\\CurrentControlSet\\Control\\CI\\Policy', 'VerifiedAndReputablePolicyState', 0));

  if (s.disableSmartScreen) {
    sp.append(
      [
        regAdd('HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer', 'SmartScreenEnabled', 'Off', 'REG_SZ'),
        regAdd('HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WTDS\\Components', 'ServiceEnabled', 0),
        regAdd('HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WTDS\\Components', 'NotifyMalicious', 0),
        regAdd('HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WTDS\\Components', 'NotifyPasswordReuse', 0),
        regAdd('HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WTDS\\Components', 'NotifyUnsafeApp', 0),
        regAdd(`${HKLM_POLICIES}\\Windows Defender Security Center\\Systray`, 'HideSystray', 1),
      ].join('\n'),
    );
    ctx.seq.defaultUser.append(
      [
        `reg.exe add "${HKU_DEFAULT}\\Software\\Microsoft\\Edge\\SmartScreenEnabled" /ve /t REG_DWORD /d 0 /f;`,
        `reg.exe add "${HKU_DEFAULT}\\Software\\Microsoft\\Edge\\SmartScreenPuaEnabled" /ve /t REG_DWORD /d 0 /f;`,
        regAdd(`${HKU_DEFAULT}\\Software\\Microsoft\\Windows\\CurrentVersion\\AppHost`, 'EnableWebContentEvaluation', 0),
        regAdd(`${HKU_DEFAULT}\\Software\\Microsoft\\Windows\\CurrentVersion\\AppHost`, 'PreventOverride', 0),
      ].join('\n'),
    );
  }

  switch (s.uacLevel) {
    case 'alwaysNotify':
      sp.append([regAdd(UAC_KEY, 'EnableLUA', 1), regAdd(UAC_KEY, 'ConsentPromptBehaviorAdmin', 2), regAdd(UAC_KEY, 'PromptOnSecureDesktop', 1)].join('\n'));
      break;
    case 'noDim':
      sp.append([regAdd(UAC_KEY, 'EnableLUA', 1), regAdd(UAC_KEY, 'ConsentPromptBehaviorAdmin', 5), regAdd(UAC_KEY, 'PromptOnSecureDesktop', 0)].join('\n'));
      break;
    case 'neverNotify':
      sp.append([regAdd(UAC_KEY, 'EnableLUA', 1), regAdd(UAC_KEY, 'ConsentPromptBehaviorAdmin', 0), regAdd(UAC_KEY, 'PromptOnSecureDesktop', 0)].join('\n'));
      break;
    case 'disabled':
      sp.append(regAdd(UAC_KEY, 'EnableLUA', 0));
      break;
    case 'windowsDefault':
      break;
  }

  if (s.enableRemoteDesktop) {
    sp.append(`netsh.exe advfirewall firewall set rule group="@FirewallAPI.dll,-28752" new enable=Yes;
${regAdd('HKLM\\SYSTEM\\CurrentControlSet\\Control\\Terminal Server', 'fDenyTSConnections', 0)}`);
  }

  if (s.processAudit !== 'disabled') {
    sp.append('auditpol.exe /set /subcategory:"{0CCE922B-69AE-11D9-BED3-505054503030}" /success:enable /failure:enable;');
    if (s.processAudit === 'enabledWithCommandLine') {
      sp.append(regAdd(`${UAC_KEY}\\Audit`, 'ProcessCreationIncludeCmdLine_Enabled', 1));
    }
  }

  if (s.preventDeviceEncryption) sp.append(regAdd('HKLM\\SYSTEM\\CurrentControlSet\\Control\\BitLocker', 'PreventDeviceEncryption', 1));

  if (s.disableInsiderBuilds) sp.append(regAdd(`${HKLM_POLICIES}\\Windows\\PreviewBuilds`, 'AllowBuildPreview', 0));

  if (s.systemRestore === 'enable') ctx.seq.firstLogon.append("Enable-ComputerRestore -Drive 'C:\\';");
  if (s.systemRestore === 'disable') ctx.seq.firstLogon.append("Disable-ComputerRestore -Drive 'C:\\';");
}

/** AppLocker runs after the optimizations, matching upstream modifier order. */
export function modifyAppLocker(ctx: GenContext): void {
  const s = ctx.profile.security;
  if (s.appLockerMode !== 'policy') return;
  const file = ctx.embedFile('AppLockerPolicy.xml', s.appLockerPolicyXml.trim());
  ctx.seq.specialize.append(`Get-Service -Name 'AppIDSvc' | Set-Service -StartupType 'Automatic';
Get-Service -Name 'AppIDSvc' | Start-Service;
Set-AppLockerPolicy -XmlPolicy '${file}';`);
}
