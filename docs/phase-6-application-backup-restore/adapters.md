# Settings adapters

Ten adapters are implemented (nine restore automatically, one restores for review only). Each is a
fixed definition in `WdbMigration.ps1` (`$script:WdbAdapters`) with application identity, scope
(current user), backup and restore locations, the items included, what is never included,
prerequisites, compatibility checks, verification and limitations. The website mirror
(`adapters.ts`) is compared with the script by tests.

Formats were checked against the applications' documented or well-known storage (VS Code/Cursor user
folder and `extensions.json`, Windows Terminal packaged `LocalState`, Git INI syntax, OpenSSH
`~/.ssh`, PuTTY and WinSCP registry storage, Notepad++ `%APPDATA%` XML files, PowerShell profile
paths, WinGet `settings.json`). **Restores were exercised only on simulated profiles and a simulated
registry**; see the bare-metal checklist.

| Adapter | Items (where) | Never included | Restore conditions | Verification |
|---|---|---|---|---|
| `vscode` Visual Studio Code | `settings.json`, `keybindings.json`, `snippets\*.json|*.code-snippets` (`%APPDATA%\Code\User`); extension list (`%USERPROFILE%\.vscode\extensions\extensions.json`) | globalStorage, workspaceStorage, `state.vscdb` (sign-in tokens), caches, extension folders | after VS Code is installed; extensions reinstalled with `code --install-extension` (documented CLI) when ticked, otherwise listed | SHA-256 per file; `code --list-extensions` |
| `cursor` Cursor | same files under `%APPDATA%\Cursor\User`; extension list | as VS Code, plus AI session state | after Cursor is installed; extensions are a **manual list** (unattended install not verified) | SHA-256 |
| `windows-terminal` Windows Terminal | `settings.json` in `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState` | `state.json`, fragments | the package folder exists (else WaitingForUser: open it once) | SHA-256 |
| `git` Git global configuration | `%USERPROFILE%\.gitconfig`, **filtered** to portable keys (user, init, pull/push/fetch/merge/diff/rebase defaults, colours, plain aliases) | credential helpers, `http.*`, `url.*`, include/includeIf, safe.directory, hooks, signing keys, ssh/gpg programs; shell aliases and core.editor/pager listed for manual re-entry | none (takes effect when Git is installed); waits for Git when Git is in the plan | SHA-256 |
| `openssh-client` OpenSSH client | `%USERPROFILE%\.ssh\config`, `known_hosts` | every key file (`id_*`, `*.pem`, `*.ppk`), `authorized_keys` | none | SHA-256 |
| `putty` PuTTY sessions | `HKCU\Software\SimonTatham\PuTTY\Sessions\*`, `SshHostKeys` | values named *password*/*passphrase* (ProxyPassword); key files (PublicKeyFile is reported) | PuTTY installed; existing sessions kept unless restoreBackup | every value read back |
| `winscp` WinSCP sites | `HKCU\Software\Martin Prikryl\WinSCP 2\Sessions\*` | Password, TunnelPassword, ProxyPassword, passphrases (reversible obfuscation), master password; INI storage unsupported | WinSCP installed, registry storage | every value read back |
| `notepadpp` Notepad++ | `config.xml` (**recent files and search history removed**), `shortcuts.xml`, `contextMenu.xml`, `stylers.xml`, `userDefineLangs\*.xml`, `themes\*.xml` | `session.xml`, `backup\` (unsaved documents), plugins | installed and **not running** (else WaitingForUser) | SHA-256 |
| `powershell-profile` PowerShell profiles | the four profile scripts under Documents | profiles that look like they contain a secret; modules (listed in the inventory) | **review only**: restored to `Documents\WindowsDeploymentBuilder\Restored settings\…`, never into the live profile; ManualActionRequired | SHA-256 of the review copy |
| `winget-settings` WinGet settings | `settings.json` in `%LOCALAPPDATA%\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState` | sources, pins, package database | App Installer registered; restored after all installs | SHA-256 |

XML is parsed with DTDs prohibited and no resolver (no external entities). JSON with comments
(VS Code, Terminal) is copied as written and checked only for size and secrets.

## Not supported (listed in previews and in the website)

| Application | Reason |
|---|---|
| Docker Desktop | machine-bound settings (VM, WSL, disk paths), credentials in helpers; images, containers and volumes are data |
| Browsers (Chrome, Edge, Firefox) | profiles hold passwords, cookies and sessions; use browser sync |
| WireGuard | tunnels contain private keys |
| Tailscale | device identity; sign in again |
| FileZilla | stores site passwords in sitemanager.xml |
| Game launchers | account sessions and large libraries |
| Office, Teams, Slack, Zoom | settings follow the account |

Everything not listed has no adapter: its settings are not backed up, and the review says so only
through the absence of an adapter (the inventory's `settings` list shows which adapters found data).
