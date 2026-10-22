# Inventory schema and matching logic

## Inventory file (`windows-deployment-builder/app-inventory`, format version 1)

Written by `WdbMigration.ps1 -Mode Inventory`; read by `importInventory` (strict: unknown members
are rejected). It is not Microsoft's `winget export` format (the importer recognises a native list
and points to the right import) and not the builder's application profile.

| Member | Content |
|---|---|
| `format`, `formatVersion`, `inventoryId` (16 hex), `exportedUtc` | identity |
| `collector` | `name`, `version`, `powershell`, `wingetMethod` (`Microsoft.WinGet.Client`, `winget export`, `unavailable`, `skipped`) |
| `source` | `osName`, `osVersion`, `osBuild`, `displayVersion`, `architecture`. No computer name, no user name. |
| `applications[]` | see below (≤ 3000) |
| `excludedCounts` | system components, updates/hotfixes, frameworks, resource packages, entries without a name |
| `devEnvironment` | Git, VS Code and Cursor extension ids, PowerShell modules (name, versions, scope, repository), Python registrations and managers, Node.js version and managers (nvm-windows, fnm, volta), Docker presence, Claude Code install method, opt-in repositories (name, tokenised root, remote without credentials) |
| `settings[]` | per adapter: application detected, settings present, item count and size (nothing is read) |
| `warnings[]` | e.g. names missing because Microsoft.WinGet.Client is not installed |
| `backup` | `null`, or the reference written by `-Mode Backup -InventoryPath`: `backupId`, `manifestSha256`, `folderName`, `createdUtc`, adapter item counts |
| `review` (optional) | added by the website's "Export reviewed inventory": decisions (with confirmation), mappings and recommendations as computed then, unresolved ids. Decisions are re-applied on import only where still valid; mappings are always recomputed. |

### Application record

| Field | Notes |
|---|---|
| `inventoryId` | `app-` + 12 hex of SHA-256 of the record's primary identity (stable across runs on the same computer) |
| `displayName`, `publisher`, `version` | as reported |
| `source` | primary evidence: `winget`, `msstore`, `registry`, `appx`, `portable`, `devtool` |
| `packageIdentifier`, `packageSource` | only when WinGet reported the installed package from a source |
| `scope` | `machine` (HKLM), `user` (HKCU, Store), `unknown` |
| `architecture` | `x86` (32-bit registry view), `x64`, `arm64`, `neutral`, `unknown` |
| `installLocation` | tokenised (`%PROGRAMFILES%\Git\`); informational only |
| `detection[]` | every source that saw it (`registry`, `winget`, `appx`, …) |
| `kind` | `application`, `runtime`, `framework`, `system`, `driver`, `devtool`, `portable` |
| `hardware` | hardware-specific software (drivers, OEM and peripheral utilities) |
| `storeIdentity` | MSIX package family name |
| `notes[]` | why something is as it is |

Never present: uninstall commands, passwords, tokens, user names, computer names.

## Discovery sources and de-duplication (collector)

| Source | How | Kept out |
|---|---|---|
| WinGet | `Get-WinGetPackage` (Microsoft.WinGet.Client) when installed: names, ids, versions, sources; otherwise `winget export --include-versions` (ids and versions of packages from a source) | — |
| Uninstall records | HKLM 64-bit and 32-bit views, HKCU; values are read, never run | no `DisplayName`, `SystemComponent=1`, `ParentKeyName`, `ReleaseType` update/hotfix, `KB…` keys |
| Store / MSIX | `Get-AppxPackage` (current user) | frameworks, resource packages; inbox Microsoft packages are marked `system` |
| Portable | only folders named with `-PortablePath`, two levels: a PortableApps.com `App\AppInfo\appinfo.ini`, or an `.exe` whose version resource has product and company names | installers, uninstallers, updaters; folders without credible metadata; links |
| Development tools | files and registry only (`.gitconfig` present, `extensions.json`, PEP 514, version-manager folders, module folders) | nothing is executed |

Overlaps are merged: WinGet `ARP\Machine|User\X64|X86\<key>` ids are the uninstall record with that
key; `MSIX\<full name>` ids are that Store package; a WinGet package from a source is joined with the
uninstall record of the same normalised name (and version), and a Store package with the MSIX package
whose name contains it. In the website, records that resolve to the same package are merged again.

## Matching (website)

| Classification | When | Confidence | Default decision |
|---|---|---|---|
| In the curated catalog | WinGet/Store id equals a catalog entry | exact | restore |
| Verified WinGet package (outside the catalog) | WinGet reported an installed package with a valid id from `winget` | exact | restore (optional if deliberately excluded from the catalog) |
| Microsoft Store application | id from `msstore` (installable), or an MSIX package without a product id | exact / exact-identity | restore / manual |
| Supported portable application | name matches a catalog portable entry | strong or possible | optional / manual |
| Manual installation required | name matches a catalog manual entry (e.g. RustDesk) | strong or possible | manual (catalog follow-up) |
| Verified vendor installer | reserved (no reviewed vendor installers exist yet) | — | — |
| Unknown or unsupported | anything else, ids from other sources, invalid ids | none | exclude (manual possible) |

Name matching normalises case, trademarks, architecture and locale suffixes and trailing versions,
and also compares with the name WinGet reported when the catalog entry was verified.
**Strong** needs the same name (a trailing version is allowed: "PuTTY release 0.83") **and** an
agreeing publisher. **Possible** is a name match without publisher confirmation, or the catalog
name followed by other words ("Microsoft Teams Meeting Add-in"). A possible match can be set to
"restore" only after the technician ticks "This is …"; `applyMigration` refuses otherwise.

Always excluded: hardware-specific software (left to Phase 8 hardware-aware drivers) and Windows
components/frameworks (shown under "Windows components"). Arm64 targets get a note when a catalog
entry has no Arm64 build.

## Decisions

| Decision | Effect |
|---|---|
| Restore automatically | added to the new profile (unless the base already selects it) |
| Include, install manually | catalog manual entry → its follow-up; anything else → Additional Software manual entry |
| Keep as optional | unticked recommendation of the new profile |
| Exclude from this migration | not installed; a base application is recorded in the profile's `excluded` |

Every decision is recorded in the deployment profile (`migration.decisions`) and reported per
application in `restoration.json`.
