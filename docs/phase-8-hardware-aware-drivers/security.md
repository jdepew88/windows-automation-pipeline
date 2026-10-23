# Security

The driver engine runs as SYSTEM and installs kernel code; it is treated as security-sensitive.

| Never | How it is enforced |
|---|---|
| disable signature enforcement, Secure Boot, Defender, firewall | no such call exists (static test: no `bcdedit`, `testsigning`, `nointegritychecks`, `Set-MpPreference`, firewall cmdlets, registry writes) |
| install unsigned or non-WHQL kernel drivers | catalog `Get-AuthenticodeSignature` = Valid and signer "Microsoft Windows Hardware Compatibility Publisher", checked when a bundle is built, when it is staged and again on use; Windows checks catalog membership of every file when the package is added |
| trust a file name | packages are identified by manifest SHA-256 (bundle), per-file SHA-256, the INF's own models and the catalog |
| download from search results or guessed URLs | only technician-entered exact HTTPS URLs on an allowlist of official hosts (`downloadHosts`), no credentials or ports; SHA-256 must match or the file is deleted (`Integrity`, never retried) |
| run vendor executables | only `pnputil.exe` (/add-driver, /scan-devices, /export-driver), `expand.exe`, `shutdown.exe`, `icacls.exe` (installer) are ever started (static test of every call site); ZIP/CAB archives are extracted with path checks; INF files are parsed, never executed |
| delete, remove, disable or roll back drivers | `Invoke-WdvPnpUtil` refuses `/delete-driver`, `/remove-device`, `/disable-device`, `/force`, `/uninstall`, `/reboot` before anything runs |
| flash BIOS or firmware | not implemented; reported as a manufacturer task |
| force a downgrade or replace a working driver | candidate filter; replacements need an explicit approval per package and hardware ID |
| inject incompatible storage drivers / modify images | `$WinPEDriver$` with pinned, verified packages only; boot.wim/install.wim are never touched |
| override managed-device policy | Device Installation Restrictions are read; when set nothing is installed (`Policy`) |
| continue after validation fails | bundle, package, download, candidate and signature failures stop that operation; a modified staged package is `Integrity` |

Paths: the configuration is validated (data root, bundle folder pattern, package ids, SHA-256, URLs);
bundle and archive paths must be plain relative paths (no root, drive, `..`, reserved names); links are
refused; staged copies live in the Administrators/SYSTEM-only data root. Inspection needs no elevation;
everything that installs runs from the SYSTEM task or an elevated technician session. Shared files
(inventory, drivers.json) carry no serial numbers, UUIDs, MAC addresses, user or computer names, and
instance IDs are hashed.
