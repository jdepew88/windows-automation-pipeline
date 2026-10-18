import type { GenContext } from '../../engine/context';
import type { SettingDef } from '../../engine/settings/types';
import { UPSTREAM_RESOURCES } from '../../engine/resources/upstream';
import { HKLM_POLICIES, HKU_DEFAULT, regAdd } from '../shared';

type Toggle = Omit<SettingDef, 'section' | 'control' | 'stages'> & { stages: SettingDef['stages'] };
const toggle = (t: Toggle): SettingDef => ({ ...t, section: 'system', control: 'checkbox' });

export const settings: SettingDef[] = [
  toggle({
    path: 'system.disableFastStartup',
    label: 'Turn off Fast Startup',
    description: 'Shut down performs a full shutdown. Hibernation stays available, because this does not run powercfg /hibernate off.',
    applicability: 'Windows 10/11',
    stages: ['specialize'],
    mapping: 'HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Power\\HiberbootEnabled = 0',
    advanced: false,
    verification: 'upstream-tested',
  }),
  toggle({
    path: 'system.disableErrorReporting',
    label: 'Turn off Windows Error Reporting',
    description: 'Crash reports are no longer sent to Microsoft, so Microsoft-provided fixes and diagnostics for crashes are unavailable.',
    applicability: 'Windows 10/11 (Group Policy "Disable Windows Error Reporting")',
    risk: 'Harder to diagnose recurring application crashes.',
    stages: ['specialize'],
    mapping: `${HKLM_POLICIES}\\Windows\\Windows Error Reporting\\Disabled = 1`,
    advanced: false,
    verification: 'documented',
  }),
  {
    path: 'system.powerShellExecutionPolicy',
    section: 'system',
    label: 'PowerShell execution policy (LocalMachine)',
    control: 'radio',
    choices: [
      { value: 'remoteSigned', label: 'RemoteSigned (owner default)' },
      { value: 'windowsDefault', label: 'Windows default (Restricted on Windows client)' },
    ],
    description: 'Applies to Windows PowerShell 5.1. Generated setup scripts always run with a process-scoped bypass and do not depend on this.',
    applicability: 'Windows 10/11',
    stages: ['specialize'],
    mapping: "Specialize.ps1: Set-ExecutionPolicy -Scope 'LocalMachine' -ExecutionPolicy 'RemoteSigned' -Force",
    advanced: false,
    verification: 'upstream-tested',
  },
  toggle({
    path: 'system.hardenSystemDriveAcl',
    label: 'Harden ACLs of the system drive',
    description: 'Removes the "Authenticated Users" modify permission on C:\\.',
    applicability: 'Windows 10/11',
    risk: 'Some installers that write to C:\\ root may fail.',
    stages: ['specialize'],
    mapping: 'icacls.exe C:\\ /remove:g "*S-1-5-11"',
    advanced: true,
    verification: 'upstream-tested',
  }),
  toggle({
    path: 'system.enableLongPaths',
    label: 'Enable long paths (> 260 characters)',
    description: 'Apps must also opt in to long paths.',
    applicability: 'Windows 10 1607+/11',
    stages: ['specialize'],
    mapping: 'HKLM\\SYSTEM\\CurrentControlSet\\Control\\FileSystem\\LongPathsEnabled = 1',
    advanced: true,
    verification: 'upstream-tested',
  }),
  toggle({
    path: 'system.deleteJunctions',
    label: 'Delete hidden compatibility junction points',
    description: 'Removes legacy junctions such as "Documents and Settings" and "Application Data".',
    applicability: 'Windows 10/11',
    risk: 'Old software relying on these paths may break.',
    stages: ['firstLogon', 'userOnce'],
    mapping: 'FirstLogon.ps1/UserOnce.ps1: Remove-Item on ReparsePoint entries in C:\\, C:\\Users, Default, Public, ProgramData, user profile',
    advanced: true,
    verification: 'upstream-tested',
  }),
  toggle({
    path: 'system.disableLastAccess',
    label: 'Do not update NTFS last-access timestamps',
    description: 'Windows default is system-managed, which is already off on most large volumes.',
    applicability: 'Windows 10/11',
    stages: ['specialize'],
    mapping: 'fsutil.exe behavior set disableLastAccess 1',
    advanced: true,
    verification: 'upstream-tested',
  }),
  toggle({
    path: 'system.turnOffSystemSounds',
    label: 'Turn off system sounds',
    description: 'Owner default keeps Windows sounds, including the device connect/disconnect sounds.',
    applicability: 'Windows 10/11',
    stages: ['defaultUser', 'userOnce', 'specialize'],
    mapping: 'TurnOffSystemSounds.ps1 on the default hive; HKCU\\AppEvents\\Schemes = .None; DisableStartupSound',
    advanced: true,
    verification: 'upstream-tested',
  }),
  toggle({
    path: 'system.deleteWindowsOld',
    label: 'Delete empty C:\\Windows.old folder',
    description: 'Only removes the folder if empty (rmdir without /s).',
    applicability: 'Windows 10/11',
    stages: ['firstLogon'],
    mapping: 'FirstLogon.ps1: cmd.exe /c "rmdir C:\\Windows.old"',
    advanced: true,
    verification: 'upstream-tested',
  }),
  toggle({
    path: 'system.disableAutomaticRestartSignOn',
    label: 'Disable automatic sign-on of the last user after an update restart (ARSO)',
    description: 'Not the same as the initial automatic sign-in configured under Accounts. Owner default leaves it at Windows default.',
    applicability: 'Windows 10/11',
    stages: ['specialize'],
    mapping: 'HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\System\\DisableAutomaticRestartSignOn = 1',
    advanced: true,
    verification: 'upstream-tested',
  }),
  toggle({
    path: 'system.disableWpbt',
    label: 'Ignore the Windows Platform Binary Table (WPBT)',
    description: 'Prevents firmware-supplied executables (OEM agents) from running at boot.',
    applicability: 'Windows 10/11',
    risk: 'Some anti-theft/OEM tools rely on WPBT.',
    stages: ['specialize'],
    mapping: 'HKLM\\System\\CurrentControlSet\\Control\\Session Manager\\DisableWpbtExecution = 1',
    advanced: true,
    verification: 'upstream-tested',
  }),
  toggle({
    path: 'system.preventDeviceApps',
    label: 'Prevent hardware-triggered app installs (device metadata / co-installers)',
    description: 'Stops Windows from downloading vendor apps when devices are connected. Drivers still install.',
    applicability: 'Windows 10/11',
    stages: ['specialize'],
    mapping: 'HKLM\\…\\Device Metadata\\PreventDeviceMetadataFromNetwork = 1; …\\Device Installer\\DisableCoInstallers = 1',
    advanced: false,
    verification: 'upstream-tested',
  }),
  toggle({
    path: 'system.disablePointerPrecision',
    label: 'Turn off "Enhance pointer precision" (mouse acceleration)',
    description: 'Applied to the default user profile.',
    applicability: 'Windows 10/11',
    stages: ['defaultUser'],
    mapping: `${HKU_DEFAULT}\\Control Panel\\Mouse\\MouseSpeed, MouseThreshold1, MouseThreshold2 = "0"`,
    advanced: false,
    verification: 'upstream-tested',
  }),
  toggle({
    path: 'system.hideEdgeFirstRun',
    label: 'Suppress the Microsoft Edge first-run experience',
    description: 'Edge opens without the welcome/sign-in wizard.',
    applicability: 'Microsoft Edge (Chromium) policy',
    stages: ['specialize'],
    mapping: `${HKLM_POLICIES}\\Edge\\HideFirstRunExperience = 1`,
    advanced: false,
    verification: 'upstream-tested',
  }),
  toggle({
    path: 'system.disableEdgeStartupBoost',
    label: 'Disable Edge Startup Boost and background mode',
    description: 'Recommended (user-changeable) policies, so users can turn them back on in Edge settings.',
    applicability: 'Microsoft Edge policy',
    stages: ['specialize'],
    mapping: `${HKLM_POLICIES}\\Edge\\Recommended\\StartupBoostEnabled = 0, BackgroundModeEnabled = 0`,
    advanced: false,
    verification: 'upstream-tested',
  }),
  toggle({
    path: 'system.makeEdgeUninstallable',
    label: 'Make Edge uninstallable via Settings',
    description: 'Owner default: off. Edge is neither removed nor made uninstallable.',
    applicability: 'Windows 11 in EEA regions (policy file edit)',
    risk: 'Edits C:\\Windows\\System32\\IntegratedServicesRegionPolicySet.json. Effect depends on build and region.',
    stages: ['specialize'],
    mapping: 'MakeEdgeUninstallable.ps1 (upstream)',
    advanced: true,
    verification: 'upstream-tested',
  }),
];

export function modify(ctx: GenContext): void {
  const s = ctx.profile.system;
  const sp = ctx.seq.specialize;

  if (s.hardenSystemDriveAcl) sp.append('icacls.exe C:\\ /remove:g "*S-1-5-11";');
  if (s.enableLongPaths) sp.append(regAdd('HKLM\\SYSTEM\\CurrentControlSet\\Control\\FileSystem', 'LongPathsEnabled', 1));
  if (s.deleteJunctions) {
    ctx.seq.firstLogon.append(`@(
	Get-ChildItem -LiteralPath 'C:\\' -Force;
	Get-ChildItem -LiteralPath 'C:\\Users' -Force;
	Get-ChildItem -LiteralPath 'C:\\Users\\Default' -Force -Recurse -Depth 2;
	Get-ChildItem -LiteralPath 'C:\\Users\\Public' -Force -Recurse -Depth 2;
	Get-ChildItem -LiteralPath 'C:\\ProgramData' -Force;
) | Where-Object -FilterScript {
	$_.Attributes.HasFlag( [System.IO.FileAttributes]::ReparsePoint );
} | Remove-Item -Force -Recurse -Verbose;`);
    ctx.seq.userOnce.append(`@(
  Get-ChildItem -LiteralPath $env:USERPROFILE -Force -Recurse -Depth 2;
) | Where-Object -FilterScript {
	$_.Attributes.HasFlag( [System.IO.FileAttributes]::ReparsePoint );
} | Remove-Item -Force -Recurse -Verbose;`);
  }
  if (s.powerShellExecutionPolicy === 'remoteSigned') sp.append("Set-ExecutionPolicy -Scope 'LocalMachine' -ExecutionPolicy 'RemoteSigned' -Force;");
  if (s.disableLastAccess) sp.append('fsutil.exe behavior set disableLastAccess 1;');
  if (s.disableFastStartup) sp.append(regAdd('HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Power', 'HiberbootEnabled', 0));
  if (s.disableErrorReporting) sp.append(regAdd(`${HKLM_POLICIES}\\Windows\\Windows Error Reporting`, 'Disabled', 1));
  if (s.turnOffSystemSounds) {
    const ps1 = ctx.embedFile('TurnOffSystemSounds.ps1', UPSTREAM_RESOURCES['TurnOffSystemSounds.ps1']);
    ctx.seq.defaultUser.invokeFile(ps1);
    ctx.seq.userOnce.append("Set-ItemProperty -LiteralPath 'Registry::HKCU\\AppEvents\\Schemes' -Name '(Default)' -Type 'String' -Value '.None';");
    sp.append(
      [
        regAdd('HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Authentication\\LogonUI\\BootAnimation', 'DisableStartupSound', 1),
        regAdd('HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\EditionOverrides', 'UserSetting_DisableStartupSound', 1),
      ].join('\n'),
    );
  }
  if (s.hideEdgeFirstRun) sp.append(regAdd(`${HKLM_POLICIES}\\Edge`, 'HideFirstRunExperience', 1));
  if (s.disableEdgeStartupBoost) {
    sp.append([regAdd(`${HKLM_POLICIES}\\Edge\\Recommended`, 'BackgroundModeEnabled', 0), regAdd(`${HKLM_POLICIES}\\Edge\\Recommended`, 'StartupBoostEnabled', 0)].join('\n'));
  }
  if (s.makeEdgeUninstallable) sp.invokeFile(ctx.embedFile('MakeEdgeUninstallable.ps1', UPSTREAM_RESOURCES['MakeEdgeUninstallable.ps1']));
  if (s.deleteWindowsOld) ctx.seq.firstLogon.append(`${ctx.cmd.shell('rmdir C:\\Windows.old')};`);
  if (s.disablePointerPrecision) {
    ctx.seq.defaultUser.append(`$params = @{
  LiteralPath = 'Registry::${HKU_DEFAULT}\\Control Panel\\Mouse';
  Type = 'String';
  Value = 0;
  Force = $true;
};
Set-ItemProperty @params -Name 'MouseSpeed';
Set-ItemProperty @params -Name 'MouseThreshold1';
Set-ItemProperty @params -Name 'MouseThreshold2';`);
  }
  if (s.disableAutomaticRestartSignOn) {
    sp.append(regAdd('HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\System', 'DisableAutomaticRestartSignOn', 1));
  }
  if (s.disableWpbt) sp.append(regAdd('HKLM\\System\\CurrentControlSet\\Control\\Session Manager', 'DisableWpbtExecution', 1));
  if (s.preventDeviceApps) {
    sp.append(
      [
        regAdd('HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Device Metadata', 'PreventDeviceMetadataFromNetwork', 1),
        regAdd('HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Device Installer', 'DisableCoInstallers', 1),
      ].join('\n'),
    );
  }
}
