/**
 * Phase 6: the settings adapters, as the website shows them. The definitions that actually back up
 * and restore are in scripts/WdbMigration.ps1 ($script:WdbAdapters); this mirror carries what a
 * person needs to decide (what is included, what never is, prerequisites, limitations), and
 * tests/unit/migration.test.ts checks that both lists agree (ids, restore mode, application keys,
 * items and their locations).
 */

export type RestoreMode = 'automatic' | 'review';

export interface AdapterItem {
  /** Name inside the backup ("settings.json", "snippets" for a folder of files). */
  logical: string;
  kind: 'file' | 'folder' | 'gitconfig' | 'xmlsanitized' | 'registryTree' | 'registryValues' | 'extensions' | 'review';
  /** Where it lives on the computer, e.g. %APPDATA%\Code\User\settings.json or HKCU\Software\… */
  location: string;
}

export interface SettingsAdapter {
  id: string;
  name: string;
  restoreMode: RestoreMode;
  /** The application must be installed before its settings are restored. */
  requiresApp: boolean;
  /** Package keys of the application ("winget:microsoft.visualstudiocode"); settings wait for these. */
  appKeys: string[];
  items: AdapterItem[];
  excluded: string[];
  prerequisites: string;
  verification: string;
  limitations: string;
  /** VS Code: extensions can be reinstalled with its documented command line. */
  extensionsCli: boolean;
}

const f = (logical: string, location: string, kind: AdapterItem['kind'] = 'file'): AdapterItem => ({ logical, kind, location });

export const SETTINGS_ADAPTERS: readonly SettingsAdapter[] = [
  {
    id: 'vscode',
    name: 'Visual Studio Code',
    restoreMode: 'automatic',
    requiresApp: true,
    appKeys: ['winget:microsoft.visualstudiocode'],
    items: [f('settings.json', '%APPDATA%\\Code\\User\\settings.json'), f('keybindings.json', '%APPDATA%\\Code\\User\\keybindings.json'), f('snippets', '%APPDATA%\\Code\\User\\snippets', 'folder'), f('extensions.json', '%USERPROFILE%\\.vscode\\extensions\\extensions.json', 'extensions')],
    excluded: ['globalStorage and workspaceStorage (machine and workspace state)', 'state.vscdb (holds sign-in tokens)', 'History, CachedData, logs and sync folders (caches)', 'extension folders (reinstalled from the Marketplace instead)'],
    prerequisites: 'Visual Studio Code is installed (settings are restored after its installation).',
    verification: 'Every restored file is compared with the backup by SHA-256; extensions are checked with "code --list-extensions".',
    limitations: 'Settings Sync, if you sign in, can overwrite restored settings. Extensions need the Internet. Extension data in globalStorage is not restored.',
    extensionsCli: true,
  },
  {
    id: 'cursor',
    name: 'Cursor',
    restoreMode: 'automatic',
    requiresApp: true,
    appKeys: ['winget:anysphere.cursor'],
    items: [f('settings.json', '%APPDATA%\\Cursor\\User\\settings.json'), f('keybindings.json', '%APPDATA%\\Cursor\\User\\keybindings.json'), f('snippets', '%APPDATA%\\Cursor\\User\\snippets', 'folder'), f('extensions.json', '%USERPROFILE%\\.cursor\\extensions\\extensions.json', 'extensions')],
    excluded: ['globalStorage and workspaceStorage', 'state.vscdb (holds sign-in tokens and AI session state)', 'caches and logs', 'extension folders'],
    prerequisites: 'Cursor is installed.',
    verification: 'Every restored file is compared with the backup by SHA-256.',
    limitations: 'Cursor extensions are listed as a manual follow-up: an unattended extension installation for Cursor is not verified. Account sign-in is manual.',
    extensionsCli: false,
  },
  {
    id: 'windows-terminal',
    name: 'Windows Terminal',
    restoreMode: 'automatic',
    requiresApp: true,
    appKeys: ['winget:microsoft.windowsterminal'],
    items: [f('settings.json', '%LOCALAPPDATA%\\Packages\\Microsoft.WindowsTerminal_8wekyb3d8bbwe\\LocalState\\settings.json')],
    excluded: ['state.json (window positions)', 'fragments and dynamic profiles generated on the new computer'],
    prerequisites: 'Windows Terminal is installed (included in Windows 11) and registered for the user.',
    verification: 'settings.json is compared with the backup by SHA-256.',
    limitations: 'Profiles that start programs which are not installed on the new computer show an error when opened. Profiles for WSL distributions appear once the distributions are installed.',
    extensionsCli: false,
  },
  {
    id: 'git',
    name: 'Git (global configuration)',
    restoreMode: 'automatic',
    requiresApp: false,
    appKeys: ['winget:git.git'],
    items: [f('gitconfig', '%USERPROFILE%\\.gitconfig', 'gitconfig')],
    excluded: [
      'credential helpers and stored credentials',
      'http.* (proxies, extra headers that can carry tokens) and url.* rewrites',
      'include/includeIf, safe.directory, hooks and other machine paths',
      'signing keys and gpg/ssh program paths',
      'shell aliases (!...) and core.editor/core.pager commands: listed for manual re-entry',
    ],
    prerequisites: 'None; Git reads the file once it is installed.',
    verification: 'The restored file is compared with the filtered backup by SHA-256.',
    limitations: 'Only portable keys are kept (identity, defaults, aliases without shell commands, colours). Repositories are never cloned.',
    extensionsCli: false,
  },
  {
    id: 'openssh-client',
    name: 'OpenSSH client (config and known hosts)',
    restoreMode: 'automatic',
    requiresApp: false,
    appKeys: [],
    items: [f('config', '%USERPROFILE%\\.ssh\\config'), f('known_hosts', '%USERPROFILE%\\.ssh\\known_hosts')],
    excluded: ['private and public keys (id_*, *.pem, *.ppk, *.key): copy keys yourself, never through a backup', 'authorized_keys', 'agent sockets'],
    prerequisites: 'None (the OpenSSH client is part of Windows 11).',
    verification: 'Each file is compared with the backup by SHA-256.',
    limitations: 'IdentityFile entries still point to keys that you must copy yourself. ProxyCommand lines are restored as written; review them.',
    extensionsCli: false,
  },
  {
    id: 'putty',
    name: 'PuTTY saved sessions',
    restoreMode: 'automatic',
    requiresApp: true,
    appKeys: ['winget:putty.putty'],
    items: [f('Sessions.json', 'HKCU\\Software\\SimonTatham\\PuTTY\\Sessions', 'registryTree'), f('SshHostKeys.json', 'HKCU\\Software\\SimonTatham\\PuTTY\\SshHostKeys', 'registryValues')],
    excluded: ['ProxyPassword and every other value whose name contains "password" or "passphrase"', 'private key files (.ppk) referenced by PublicKeyFile', 'Pageant keys'],
    prerequisites: 'PuTTY is installed.',
    verification: 'Every restored registry value is read back and compared with the backup.',
    limitations: 'Sessions that use a private key need the key copied by hand; their PublicKeyFile path is reported.',
    extensionsCli: false,
  },
  {
    id: 'winscp',
    name: 'WinSCP sites (without passwords)',
    restoreMode: 'automatic',
    requiresApp: true,
    appKeys: ['winget:winscp.winscp'],
    items: [f('Sessions.json', 'HKCU\\Software\\Martin Prikryl\\WinSCP 2\\Sessions', 'registryTree')],
    excluded: ['stored passwords, tunnel and proxy passwords, passphrases (WinSCP obfuscation is reversible, so they are never copied)', 'master password settings', 'WinSCP.ini storage (not supported by this version)'],
    prerequisites: 'WinSCP is installed and uses the registry for its configuration (the default).',
    verification: 'Every restored registry value is read back and compared with the backup.',
    limitations: 'Passwords must be entered again. A WinSCP.ini (portable) configuration is reported as unsupported.',
    extensionsCli: false,
  },
  {
    id: 'notepadpp',
    name: 'Notepad++',
    restoreMode: 'automatic',
    requiresApp: true,
    appKeys: ['winget:notepad++.notepad++'],
    items: [
      f('config.xml', '%APPDATA%\\Notepad++\\config.xml', 'xmlsanitized'),
      f('shortcuts.xml', '%APPDATA%\\Notepad++\\shortcuts.xml'),
      f('contextMenu.xml', '%APPDATA%\\Notepad++\\contextMenu.xml'),
      f('stylers.xml', '%APPDATA%\\Notepad++\\stylers.xml'),
      f('userDefineLangs', '%APPDATA%\\Notepad++\\userDefineLangs', 'folder'),
      f('themes', '%APPDATA%\\Notepad++\\themes', 'folder'),
    ],
    excluded: ['session.xml (open files of the old computer)', 'backup\\ (contents of unsaved documents)', 'recent files and search history inside config.xml', 'plugins and their configuration'],
    prerequisites: 'Notepad++ is installed and not running (it rewrites config.xml when it closes).',
    verification: 'Every restored file is compared with the backup by SHA-256.',
    limitations: 'A portable Notepad++ (doLocalConf.xml) keeps its settings next to the program and is not covered. Plugins are not reinstalled.',
    extensionsCli: false,
  },
  {
    id: 'powershell-profile',
    name: 'PowerShell profiles (for review)',
    restoreMode: 'review',
    requiresApp: false,
    appKeys: [],
    items: [
      f('WindowsPowerShell/Microsoft.PowerShell_profile.ps1', '%DOCUMENTS%\\WindowsPowerShell\\Microsoft.PowerShell_profile.ps1', 'review'),
      f('WindowsPowerShell/profile.ps1', '%DOCUMENTS%\\WindowsPowerShell\\profile.ps1', 'review'),
      f('PowerShell/Microsoft.PowerShell_profile.ps1', '%DOCUMENTS%\\PowerShell\\Microsoft.PowerShell_profile.ps1', 'review'),
      f('PowerShell/profile.ps1', '%DOCUMENTS%\\PowerShell\\profile.ps1', 'review'),
    ],
    excluded: ['installed modules (listed in the inventory with the command to install them)', 'profiles that look like they contain a secret (API keys, tokens)'],
    prerequisites: 'None.',
    verification: 'The review copies are compared with the backup by SHA-256.',
    limitations: 'Profiles are scripts, so they are never put back into the live profile location: they are restored to Documents\\WindowsDeploymentBuilder\\Restored settings for review and copied into place by hand.',
    extensionsCli: false,
  },
  {
    id: 'winget-settings',
    name: 'WinGet settings',
    restoreMode: 'automatic',
    requiresApp: false,
    appKeys: [],
    items: [f('settings.json', '%LOCALAPPDATA%\\Packages\\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\\LocalState\\settings.json')],
    excluded: ['sources, pins and the installed package database (machine state)'],
    prerequisites: 'App Installer (WinGet) is registered for the user.',
    verification: 'settings.json is compared with the backup by SHA-256.',
    limitations: 'Restored after the applications are installed, so it does not change how this deployment installs them.',
    extensionsCli: false,
  },
];

/** Applications whose settings are deliberately not backed up (same list as $script:WdbUnsupported). */
export const UNSUPPORTED_SETTINGS: Readonly<Record<string, string>> = {
  'docker-desktop': 'Docker Desktop settings are machine-bound (VM, WSL and disk paths) and its credentials live in credential helpers; containers, images and volumes are data, not settings.',
  browsers: "Browser profiles (Chrome, Edge, Firefox) hold passwords, cookies and signed-in sessions; use the browser's own sync instead.",
  wireguard: 'WireGuard tunnels contain private keys.',
  tailscale: 'Tailscale state is a device identity; sign in again instead.',
  filezilla: 'FileZilla stores site passwords in sitemanager.xml.',
  'game-launchers': 'Game launchers keep account sessions and large libraries; sign in and let them download again.',
  'office-and-chat': 'Office, Teams, Slack and Zoom settings follow the account and are restored after sign-in.',
};

export const adapterById = (id: string) => SETTINGS_ADAPTERS.find((a) => a.id === id);
