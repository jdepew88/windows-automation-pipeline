# Security and sensitive-data handling

## Never collected or exported

Passwords, account tokens, API keys, SSH and PuTTY private keys, certificates, credential stores
(Credential Manager, DPAPI-protected data), browser profiles, cookies and sessions, Docker
credentials, whole AppData folders, caches, user documents. Uninstall command lines are not read
into the inventory. User names and private paths are replaced by tokens (`%APPDATA%`,
`%USERNAME%`); the inventory and the manifest contain no computer name.

## Secret detection (backup)

Every text item, after filtering, is scanned. Rules: private key headers (PEM, PuTTY key file),
credentials in URLs (`scheme://user:pass@`), named secrets (`password`, `passphrase`, `secret`,
`api_key`, `access_token`, `auth_token`, `client_secret`, `private_key` with a value), known token
formats (GitHub, GitLab, Slack, AWS access key ids, Google API keys, OpenAI/Anthropic keys) and
`$env:…KEY|TOKEN|SECRET|PASSWORD = "…"` in scripts. A file with a hit is **left out** and the
preview reports the rule and line number, never the value. It is included only when named
explicitly with `-IncludeFlagged <adapter>/<item>` after review. Registry values whose name contains
*password* or *passphrase* are dropped at backup **and** refused at restore, so a crafted backup
cannot write them either.

Detection is a safety net, not a guarantee: settings can hold personal data without matching a
rule. Treat every backup as personal data and keep it on a drive you control. There is no
"include secrets" option and no reversible obfuscation.

## Untrusted input

| Input | Controls |
|---|---|
| Inventory file (website) | 5 MB limit; strict schema (unknown members rejected); id, version and name patterns; no control characters; paths without `..`; remotes without credentials; duplicate ids rejected; review decisions must refer to listed apps and are re-validated. Nothing in it is executed or passed to a command line; installable identifiers pass the same WinGet/Store patterns as every other package. |
| Backup manifest (website) | 1 MB, strict UTF-8 JSON schema, item paths must be `data/<adapter>/<logical>` and logical names must be ones the adapter restores; the SHA-256 is computed by the website over the exact bytes. |
| Backup folder or ZIP (collector, engine, recovery tool) | validated as in [backup-format.md](backup-format.md) before anything is staged or restored; with a deployment, the manifest must match the pinned hash. Links, traversal, unexpected entries and bombs are refused. |
| Restore destinations | from the adapter definitions only, resolved under the user's folders and checked not to leave them or cross a link (`Resolve-WdbTarget`). Registry writes are HKCU only, value types String/DWORD only, key and value names pattern-checked. |
| Scripts in a backup | never executed. PowerShell profiles are restored to a review folder; Git shell aliases and editor commands are not restored. Windows Terminal profiles and OpenSSH `ProxyCommand` lines are restored as written (they run only when you open that profile or host) and are mentioned in the adapter limitations. |
| VS Code extensions | ids must match `publisher.name`; the CLI is run with fixed arguments through `cmd.exe /d /c` only after the argument check (`Invoke-WdbProcess` refuses anything else). |

## Where data goes

- The website runs in the browser. The inventory and the review stay in the tab; the profile keeps
  only the summary, the decisions and the backup reference (export them deliberately). The backup
  itself never reaches the website, the Cloudflare Worker or the generated ZIP.
- On the new computer the backup is staged under `C:\ProgramData\WindowsDeploymentBuilder\Backup`
  with SYSTEM, Administrators and the deployment user only. Originals replaced by `restoreBackup` are
  kept next to the file (`.wdb-before-restore`) or as JSON under the staged backup.
- No cloud account is needed; nothing is uploaded.

## Privileges

The collector needs no administrator rights. Restore runs as the deployment user inside the
elevated application task (it writes that user's profile and HKCU). The recovery tool's
`RestoreSettings` requires administrator rights and uses the restore library of the verified staged
package, never one supplied with the backup.
