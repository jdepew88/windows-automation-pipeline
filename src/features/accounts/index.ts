import type { GenContext } from '../../engine/context';
import type { SettingDef } from '../../engine/settings/types';
import type { Profile } from '../../engine/schema/profile';
import type { Issue } from '../../engine/validation/issues';
import { computerNameProblem, resolveIdentity, usernameProblem } from '../../engine/naming';
import { NS, append, child, el, leaf, remove, setAttr, type XElement } from '../../engine/xml/tree';

const unattended = (p: Profile) => p.accounts.accountMode === 'unattendedLocal';

export const AUTOLOGON_WARNING =
  'An Administrator account with an empty password that signs in automatically gives anyone with physical access a full administrator session. BitLocker/device encryption does not prevent this, because Windows unlocks the drive and signs in without asking for anything.';

export const settings: SettingDef[] = [
  {
    path: 'accounts.accountMode',
    section: 'accounts',
    label: 'Account creation',
    control: 'radio',
    choices: [
      { value: 'unattendedLocal', label: 'Create a local account from this answer file (no Microsoft account)' },
      { value: 'interactiveLocal', label: 'Create a local account interactively during OOBE' },
      { value: 'interactiveMicrosoft', label: 'Sign in with a Microsoft account interactively during OOBE' },
    ],
    description:
      'With an answer-file account, OOBE skips account creation, so network availability does not change which account is created. Verify this on your target build; Microsoft changes OOBE frequently.',
    applicability: 'Windows 11 Pro (verify per build)',
    stages: ['oobeSystem'],
    mapping: 'oobeSystem › Microsoft-Windows-Shell-Setup › UserAccounts/LocalAccounts/LocalAccount (wcm:action="add")',
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'accounts.personName',
    section: 'accounts',
    label: "Person's name",
    control: 'text',
    placeholder: 'e.g. Alex',
    description: 'Used as the account display name. The local username and the "<Name>-Computer" computer name are derived from it.',
    applicability: 'All',
    stages: ['oobeSystem', 'specialize'],
    mapping: 'LocalAccount/DisplayName; derived LocalAccount/Name, AutoLogon/Username; derived specialize › Shell-Setup › ComputerName',
    advanced: false,
    visibleWhen: unattended,
    verification: 'documented',
  },
  {
    path: 'accounts.usernameMode',
    section: 'accounts',
    label: 'Local username',
    control: 'radio',
    choices: [
      { value: 'derived', label: "Derive from the person's name" },
      { value: 'custom', label: 'Enter a username' },
    ],
    description: 'Derivation removes accents, spaces and characters Windows forbids. It truncates to 20 characters and appends "1" to built-in account names.',
    applicability: 'All',
    stages: ['oobeSystem'],
    mapping: 'LocalAccount/Name and AutoLogon/Username',
    advanced: true,
    visibleWhen: unattended,
    verification: 'documented',
  },
  {
    path: 'accounts.customUsername',
    section: 'accounts',
    label: 'Username',
    control: 'text',
    description: 'At most 20 characters; no / \\ [ ] : ; | = , + * ? < > " %; no trailing period.',
    applicability: 'All',
    stages: ['oobeSystem'],
    mapping: 'LocalAccount/Name',
    advanced: true,
    visibleWhen: (p) => unattended(p) && p.accounts.usernameMode === 'custom',
    verification: 'documented',
  },
  {
    path: 'accounts.accountGroup',
    section: 'accounts',
    label: 'Account group',
    control: 'radio',
    choices: [
      { value: 'Administrators', label: 'Administrators' },
      { value: 'Users', label: 'Users (standard account)' },
    ],
    description: 'The owner default is a local administrator, with UAC still enabled.',
    applicability: 'All',
    stages: ['oobeSystem'],
    mapping: 'LocalAccount/Group',
    advanced: true,
    visibleWhen: unattended,
    verification: 'upstream-tested',
  },
  {
    path: 'accounts.noInitialPassword',
    section: 'accounts',
    label: 'Create the account without an initial password',
    control: 'checkbox',
    description:
      'The answer file contains no password value (an empty plain-text Password element, as Windows Setup requires for an account without one). Automatic sign-in can only be "once" (for first-logon provisioning) or off; set a password in Windows afterwards.',
    applicability: 'Windows 10/11',
    risk: 'Until a password is set, anyone with physical access can sign in to this account.',
    stages: ['oobeSystem'],
    mapping: 'LocalAccount/Password and AutoLogon/Password: empty Value, PlainText=true (never Base64-encoded)',
    advanced: true,
    visibleWhen: unattended,
    verification: 'documented',
  },
  {
    path: 'accounts.password',
    section: 'accounts',
    label: 'Password',
    control: 'password',
    description: 'The owner default is an empty password. Passwords are never included in exported profiles unless you choose to include them.',
    applicability: 'All',
    risk: 'Answer-file passwords can be recovered from the file and from C:\\Windows\\Panther. Base64 "obscuring" is not encryption.',
    stages: ['oobeSystem'],
    mapping: 'LocalAccount/Password/Value (+ AutoLogon/Password/Value)',
    advanced: true,
    visibleWhen: (p) => unattended(p) && !p.accounts.noInitialPassword,
    verification: 'upstream-tested',
  },
  {
    path: 'accounts.autoLogon',
    section: 'accounts',
    label: 'Automatic sign-in',
    control: 'radio',
    choices: [
      { value: 'persistent', label: 'Sign in automatically at every start (owner default)' },
      { value: 'firstLogonOnly', label: 'Sign in automatically once, for first-logon setup only' },
      { value: 'none', label: 'Do not sign in automatically' },
    ],
    description:
      'This is the initial desktop auto-login. It is separate from "Disable automatic sign-on of last user after a restart" (Windows Update restart sign-on) under System.',
    applicability: 'Windows 10/11. Persistent mode requires an empty password in M1.',
    // Phase 4.3: the full explanation (AUTOLOGON_WARNING) is shown in Final Review & Considerations.
    risk: 'With an Administrator account and no password, anyone with physical access gets an administrator session. See Final Review & Considerations.',
    stages: ['oobeSystem', 'firstLogon'],
    mapping:
      'oobeSystem › Shell-Setup › AutoLogon (Username, Enabled, LogonCount=1, Password). FirstLogon.ps1: firstLogonOnly sets Winlogon\\AutoLogonCount=0; persistent removes AutoLogonCount and sets AutoAdminLogon=1, DefaultUserName and an empty DefaultPassword.',
    advanced: false,
    visibleWhen: unattended,
    verification: 'unverified',
  },
  {
    path: 'accounts.obscurePasswords',
    section: 'accounts',
    label: 'Obscure passwords with Base64 (PlainText=false)',
    control: 'checkbox',
    description: 'Same encoding as WSIM: Base64 of UTF-16LE(password + element name). This prevents casual reading only.',
    applicability: 'All',
    stages: ['oobeSystem'],
    mapping: '…/Password/PlainText = false and an encoded Value',
    advanced: true,
    visibleWhen: (p) => unattended(p) && !p.accounts.noInitialPassword,
    verification: 'upstream-tested',
  },
  {
    path: 'accounts.hideOnlineAccountScreens',
    section: 'accounts',
    label: 'Hide Microsoft account sign-in screens in OOBE',
    control: 'checkbox',
    description:
      'Belt-and-braces with an answer-file local account: tells OOBE not to show online account pages even when connected to the Internet.',
    applicability: 'Windows 10/11 (OOBE behaviour varies by build)',
    stages: ['oobeSystem'],
    mapping: 'oobeSystem › Shell-Setup › OOBE/HideOnlineAccountScreens',
    advanced: true,
    visibleWhen: unattended,
    verification: 'documented',
  },
  {
    path: 'accounts.computerNameMode',
    section: 'accounts',
    label: 'Computer name',
    control: 'radio',
    choices: [
      { value: 'derived', label: 'Derive "<Name>-Computer" from the person\'s name' },
      { value: 'custom', label: 'Enter a computer name' },
      { value: 'random', label: 'Let Windows generate a random name' },
    ],
    description: 'Derived names keep "-Computer" and shorten the name part so the total is at most 15 characters (NetBIOS limit).',
    applicability: 'All',
    stages: ['specialize'],
    mapping: 'specialize › Microsoft-Windows-Shell-Setup › ComputerName',
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'accounts.customComputerName',
    section: 'accounts',
    label: 'Computer name',
    control: 'text',
    description: 'At most 15 characters, letters, digits and hyphens, not all digits.',
    applicability: 'All',
    stages: ['specialize'],
    mapping: 'specialize › Shell-Setup › ComputerName',
    advanced: true,
    visibleWhen: (p) => p.accounts.computerNameMode === 'custom',
    verification: 'upstream-tested',
  },
  {
    path: 'accounts.lockoutMode',
    section: 'accounts',
    label: 'Account lockout policy',
    control: 'radio',
    choices: [
      { value: 'default', label: 'Windows default' },
      { value: 'disabled', label: 'Disable account lockout' },
      { value: 'custom', label: 'Custom policy' },
    ],
    description: 'Windows 11 default: lock for 10 minutes after 10 failed attempts.',
    applicability: 'Windows 10/11 local accounts',
    stages: ['specialize'],
    mapping: 'Specialize.ps1: net.exe accounts /lockoutthreshold /lockoutduration /lockoutwindow',
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'accounts.lockoutThreshold',
    section: 'accounts',
    label: 'Lockout threshold (failed attempts, 0–999)',
    control: 'number',
    description: '0 disables lockout.',
    applicability: 'Windows 10/11',
    stages: ['specialize'],
    mapping: 'net.exe accounts /lockoutthreshold',
    advanced: true,
    visibleWhen: (p) => p.accounts.lockoutMode === 'custom',
    verification: 'upstream-tested',
  },
  {
    path: 'accounts.lockoutDuration',
    section: 'accounts',
    label: 'Lockout duration (minutes, 1–99999)',
    control: 'number',
    description: '',
    applicability: 'Windows 10/11',
    stages: ['specialize'],
    mapping: 'net.exe accounts /lockoutduration',
    advanced: true,
    visibleWhen: (p) => p.accounts.lockoutMode === 'custom',
    verification: 'upstream-tested',
  },
  {
    path: 'accounts.lockoutWindow',
    section: 'accounts',
    label: 'Reset counter after (minutes, 1–99999, ≤ duration)',
    control: 'number',
    description: '',
    applicability: 'Windows 10/11',
    stages: ['specialize'],
    mapping: 'net.exe accounts /lockoutwindow',
    advanced: true,
    visibleWhen: (p) => p.accounts.lockoutMode === 'custom',
    verification: 'upstream-tested',
  },
  {
    path: 'accounts.passwordExpirationMode',
    section: 'accounts',
    label: 'Password expiration',
    control: 'radio',
    choices: [
      { value: 'default', label: 'Windows default (42 days for local accounts)' },
      { value: 'unlimited', label: 'Passwords never expire' },
      { value: 'custom', label: 'Custom maximum age' },
    ],
    description: 'Applies to local accounts with passwords.',
    applicability: 'Windows 10/11',
    stages: ['specialize'],
    mapping: 'Specialize.ps1: net.exe accounts /maxpwage',
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'accounts.maxPasswordAge',
    section: 'accounts',
    label: 'Maximum password age (days, 1–999)',
    control: 'number',
    description: '',
    applicability: 'Windows 10/11',
    stages: ['specialize'],
    mapping: 'net.exe accounts /maxpwage:<days>',
    advanced: true,
    visibleWhen: (p) => p.accounts.passwordExpirationMode === 'custom',
    verification: 'upstream-tested',
  },
];

export function validate(p: Profile, issues: Issue[]): void {
  const a = p.accounts;
  const id = resolveIdentity(a);
  const err = (path: string, message: string) => issues.push({ severity: 'error', path, message });

  if (a.accountMode === 'unattendedLocal') {
    if (a.personName.trim() === '' && a.usernameMode === 'derived') {
      err('accounts.personName', "Enter a name for the local account (the person's name). The username and computer name are derived from it.");
    } else {
      const problem = usernameProblem(id.username);
      if (problem) err(a.usernameMode === 'custom' ? 'accounts.customUsername' : 'accounts.personName', problem);
    }
    if (a.autoLogon !== 'none' && a.accountGroup !== 'Administrators') {
      err('accounts.autoLogon', 'Automatic sign-in requires the account to be an administrator. First-logon commands need administrative rights.');
    }
    if (a.noInitialPassword && a.autoLogon === 'persistent') {
      err('accounts.autoLogon', 'An account created without a password cannot keep automatic sign-in on. Choose "Sign in automatically once" (first-logon provisioning still runs) or "Do not sign in automatically".');
    } else if (a.autoLogon === 'persistent' && a.password !== '') {
      err(
        'accounts.autoLogon',
        'Persistent automatic sign-in with a password would require storing the password in plain text in the registry. Use "once" or an empty password.',
      );
    }
    if (id.computerName && id.username && id.computerName.toLowerCase() === id.username.toLowerCase()) {
      err('accounts.customComputerName', 'The computer name must differ from the account name.');
    }
    if (!p.setup.keepSensitiveFiles && a.autoLogon === 'none') {
      err('setup.keepSensitiveFiles', 'Deleting sensitive files needs a first logon with administrative rights. Enable automatic sign-in or keep sensitive files.');
    }
  }

  if (a.computerNameMode !== 'random') {
    if (a.computerNameMode === 'derived' && a.personName.trim() === '') {
      if (a.accountMode !== 'unattendedLocal') err('accounts.computerNameMode', 'A derived computer name needs a person\'s name. Choose "custom" or "random".');
    } else if (id.computerName !== undefined) {
      const problem = computerNameProblem(id.computerName);
      if (problem) err(a.computerNameMode === 'custom' ? 'accounts.customComputerName' : 'accounts.personName', problem);
    }
  }

  if (a.lockoutMode === 'custom') {
    const range = (path: string, v: number, min: number, max: number) => {
      if (v < min || v > max) err(path, `Must be between ${min} and ${max}.`);
    };
    range('accounts.lockoutThreshold', a.lockoutThreshold, 0, 999);
    range('accounts.lockoutDuration', a.lockoutDuration, 1, 99_999);
    range('accounts.lockoutWindow', a.lockoutWindow, 1, 99_999);
    if (a.lockoutWindow > a.lockoutDuration) err('accounts.lockoutWindow', 'The reset window must be less than or equal to the lockout duration.');
  }
  if (a.passwordExpirationMode === 'custom' && (a.maxPasswordAge < 1 || a.maxPasswordAge > 999)) {
    err('accounts.maxPasswordAge', 'Must be between 1 and 999 days.');
  }
}

/** WSIM-compatible password obscuring: Base64(UTF-16LE(password + elementName)). */
export function obscurePassword(password: string, elementName: string): string {
  const s = password + elementName;
  let binary = '';
  for (let i = 0; i < s.length; i++) {
    const code = s.charCodeAt(i);
    binary += String.fromCharCode(code & 0xff, code >> 8);
  }
  return btoa(binary);
}

function passwordElement(parent: XElement, name: string, password: string, obscure: boolean, none = false): void {
  // No password: an empty plain-text value. Base64 would encode the element name as if it were a password.
  if (none) return void append(parent, el(name, NS.unattend, [leaf('Value', ''), leaf('PlainText', 'true')]));
  append(
    parent,
    el(name, NS.unattend, [leaf('Value', obscure ? obscurePassword(password, name) : password), leaf('PlainText', obscure ? 'false' : 'true')]),
  );
}

export function modifyComputerName(ctx: GenContext): void {
  if (ctx.identity.computerName !== undefined) {
    ctx.setValue('specialize', 'Microsoft-Windows-Shell-Setup', 'ComputerName', ctx.identity.computerName);
  }
}

export function modify(ctx: GenContext): void {
  const a = ctx.profile.accounts;
  const shell = ctx.component('oobeSystem', 'Microsoft-Windows-Shell-Setup');
  const autoLogon = child(shell, 'AutoLogon')!;
  const userAccounts = child(shell, 'UserAccounts')!;
  const hideOnline = child(child(shell, 'OOBE')!, 'HideOnlineAccountScreens')!;

  if (a.accountMode !== 'unattendedLocal') {
    remove(shell, autoLogon);
    remove(shell, userAccounts);
    if (a.accountMode === 'interactiveLocal') hideOnline.children = [{ kind: 'text', value: 'true' }];
    return;
  }

  hideOnline.children = [{ kind: 'text', value: String(a.hideOnlineAccountScreens) }];
  const { username, displayName } = ctx.identity;

  if (a.autoLogon !== 'none') {
    autoLogon.children.push(leaf('Username', username), leaf('Enabled', 'true'), leaf('LogonCount', '1'));
    passwordElement(autoLogon, 'Password', a.password, a.obscurePasswords, a.noInitialPassword);
    const winlogon = "'Registry::HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon'";
    if (a.autoLogon === 'firstLogonOnly') {
      ctx.seq.firstLogon.append(`Set-ItemProperty -LiteralPath ${winlogon} -Name 'AutoLogonCount' -Type 'DWord' -Force -Value 0;`);
    } else {
      // Persistent: Windows decrements AutoLogonCount and disables auto-logon at zero. Removing the
      // counter and restating the Winlogon values keeps it on. Only allowed with an empty password,
      // so DefaultPassword never holds a secret.
      ctx.seq.firstLogon.append(`Remove-ItemProperty -LiteralPath ${winlogon} -Name 'AutoLogonCount' -Force -ErrorAction 'SilentlyContinue';
Set-ItemProperty -LiteralPath ${winlogon} -Name 'AutoAdminLogon' -Type 'String' -Value '1' -Force;
Set-ItemProperty -LiteralPath ${winlogon} -Name 'DefaultUserName' -Type 'String' -Value '${username.replace(/'/g, "''")}' -Force;
Set-ItemProperty -LiteralPath ${winlogon} -Name 'DefaultDomainName' -Type 'String' -Value $env:COMPUTERNAME -Force;
Set-ItemProperty -LiteralPath ${winlogon} -Name 'DefaultPassword' -Type 'String' -Value '' -Force;`);
    }
  }

  const local = el('LocalAccount');
  setAttr(local, 'action', 'add', NS.wcm, 'wcm');
  local.children.push(leaf('Name', username), leaf('DisplayName', displayName), leaf('Group', a.accountGroup));
  passwordElement(local, 'Password', a.password, a.obscurePasswords, a.noInitialPassword);
  append(userAccounts, el('LocalAccounts', NS.unattend, [local]));
}

/** Lockout and password-expiration policies (upstream LockoutModifier, PasswordExpirationModifier). */
export function modifyPolicies(ctx: GenContext): void {
  const a = ctx.profile.accounts;
  if (a.lockoutMode === 'disabled') ctx.seq.specialize.append('net.exe accounts /lockoutthreshold:0;');
  if (a.lockoutMode === 'custom') {
    ctx.seq.specialize.append(`net.exe accounts /lockoutthreshold:${a.lockoutThreshold} /lockoutduration:${a.lockoutDuration} /lockoutwindow:${a.lockoutWindow};`);
  }
  if (a.passwordExpirationMode === 'unlimited') ctx.seq.specialize.append('net.exe accounts /maxpwage:UNLIMITED;');
  if (a.passwordExpirationMode === 'custom') ctx.seq.specialize.append(`net.exe accounts /maxpwage:${a.maxPasswordAge};`);
}

/** Deletes files that may hold secrets at first logon (upstream DeleteModifier). */
export function modifyDeleteSensitive(ctx: GenContext): void {
  if (ctx.profile.setup.keepSensitiveFiles) return;
  ctx.seq.firstLogon.append(`Remove-Item -LiteralPath @(
	'C:\\Windows\\Panther\\unattend.xml';
	'C:\\Windows\\Panther\\unattend-original.xml';
	'C:\\Windows\\Setup\\Scripts\\Wifi.xml';
) -Force -ErrorAction 'SilentlyContinue' -Verbose;`);
}
