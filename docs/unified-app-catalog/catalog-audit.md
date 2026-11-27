# Application catalog audit (2026-11-27)

Every WinGet entry of `src/data/apps/catalog.json` was checked against its newest manifest in the WinGet community repository (`microsoft/winget-pkgs` at `a549889c7fd9dbbba0c84097c003b21850d9b58b`, 2026-11-27): the version folder, the `.installer.yaml` (installers merged with their root defaults) and the `.locale.en-US.yaml`. Every Microsoft Store entry was checked with `winget show --id <id> --exact --source msstore` (read-only). Nothing was installed, upgraded or removed on any computer. The machine-readable result, one record per entry with the manifest facts, derived silent/scope/verification evidence, problems and the decision, is [`catalog-audit.json`](catalog-audit.json); it is produced by `scripts/audit-catalog.ts` (`fetch`, `audit`, `apply`), which starts from the catalog of commit `b9ddf63` and caches every response under `node_modules/.cache/catalog-audit/`.

**Policy.** An entry stays automated (WinGet, Store or WinGet portable) only if its package resolves, installs unattended and can be verified. Otherwise it becomes a manual follow-up with the official https download, or it is removed: moved to `excluded` with its name, identifier, a precise reason and `removed: { date, formerId }`, so a saved profile that selected it loads with a compatibility warning and the app is neither installed nor substituted.

**Silent** means: `InstallModes` lists `silent`, or the installer type is one WinGet runs silently itself (msi, wix, msix, appx, burn, inno, nullsoft, portable, or a zip with such a nested type), or an `exe` with an explicit `Silent` switch.

## Counts

| | Before | After |
| --- | ---: | ---: |
| Catalog entries | 289 | 287 |
| Automated (WinGet / Store / portable) | 282 (267 / 11 / 4) | 279 (263 / 12 / 4) |
| Manual follow-ups | 7 | 8 |
| Excluded (of which removed by this audit) | 23 | 25 (2) |
| Automated entries with `interaction` silent / mayPrompt / unknown | 0 / 17 / 265 | 263 / 16 / 0 |
| Entries with a `verify` block | 0 | 91 |

Audit status of the 289 starting entries: 279 verified, 2 unverified (Battle.net, Amazon Music: no unattended installer), 1 missing (Whiteboard), 7 manual. Every WinGet identifier of the catalog was found at its exact path (no renamed or moved package); 269 of the 271 WinGet packages have silent evidence.

## Every change

**Removed** (now `excluded` with a removal record):

| Former id | Identifier | Reason |
| --- | --- | --- |
| `whiteboard` | `9MSPC6MP8FM4` (Store) | The Store product no longer resolves (`winget show --exact` and `winget search --id`: no package, while other Store ids resolved in the same session); no Whiteboard in the Store search and no `manifests/m/Microsoft/Whiteboard` in winget-pkgs. |
| `amazon-music` | `Amazon.Music` | Plain `exe` without a silent switch or silent mode; manifest stale (9.4.0.2386, committed 2023-01-23) and without any publisher URL; Amazon Music is not in the Microsoft Store. |

**Converted to manual:** `battlenet` (`Blizzard.BattleNet` 2.0.0.4232): plain `exe`, no `Silent` switch, no silent `InstallModes` (only `Custom: --lang=enUS`), unversioned URL. The Store listing `XPDM5VSMTKQLBJ` (Blizzard Entertainment Inc.) serves the same `Battle.net-Setup.exe` (identical SHA-256) without switches. Manual download: `https://download.battle.net/en-us/desktop` (the manifest's PackageUrl). `Blizzard.BattleNet` stays an alternate id (recognised when installed, never installed).

**Switched to the Microsoft Store** (same entry id, WinGet id kept as an alternate id):

- `sysinternals`: `Microsoft.Sysinternals.Suite` → `9P7KNL5RWT25`. See below.
- `aimp`: `AIMP.AIMP` → `9PCLLLH15SMT`. The WinGet package has one version, 5.10.2418, committed 2023-01-04 (unmaintained, years-old build). Store: AIMP, publisher Artem Izmaylov (the same publisher as the manifest), publisher URL aimp.ru, Installer Type msstore.

**Corrected from the manifests** (all automated entries): `installerType` (53 entries, mostly packages that also ship a zip/portable, msix or msi installer), `scope` (106, from `Scope`, or `InstallationMetadata.DefaultInstallLocation`; portable installers without a scope count as per user, WinGet's default; the four portable-method entries are machine, as WDB installs them), `architectures` (4: Google Drive gains arm64; OBS Studio and RealVNC Server lose arm64/x86; TeamViewer gains arm64; installers marked unsupported on both x64 and arm64 are ignored), `license`, `reboot` (`mayRequire` where the manifest declares 3010/1641 or a reboot return code), `interaction` (`silent` from the evidence above; the 16 remaining earlier `mayPrompt` entries keep it (the 17th, Battle.net, is now manual): bundled offers, Npcap, the PostgreSQL password, WSL first run, Store-hosted antivirus exe installers), `validation` (status, `checkedAt: 2026-11-27`, the manifest path read) and a `verify` block where the manifest gives evidence: `uninstall` = AppsAndFeatures DisplayName prefixes without the version or locale (and without the architecture suffix when one package has an installer per architecture), `appx` = the name part of `PackageFamilyName` (17 entries), `perUser` for user-scope installers and Store packages. 176 WinGet entries have no manifest evidence beyond WinGet's own installation record; `detectNames` are kept and merged by `verifySpec()`.

**Category:** `joplin` touch → documents (a note-taking app; the Touchscreen profile still recommends it).

## The apps from the physical deployment

- **Sysinternals Suite** (reported "Installer hash mismatch"): the manifest (`2026-10-15`, a single version folder) is a zip of portables downloaded from the unversioned `https://download.sysinternals.com/files/SysinternalsSuite.zip`. Its SHA-256 is stale from the moment Microsoft updates the zip until a new manifest is merged, so a refresh-and-retry only helps once the repository has caught up, and WDB never ignores the hash. `winget search "Sysinternals Suite" --source msstore` finds `9P7KNL5RWT25`; `winget show`: Sysinternals Suite, publisher Microsoft Corporation, publisher URL https://www.sysinternals.com, licence live.sysinternals.com/Eula.txt, Installer Type msstore. The entry now installs the Store edition (updated by the Store, no hash window); `Microsoft.Sysinternals.Suite` is an alternate id. Its AppX package name is not shown by the Store, so `verify.appx` is not set (perUser only).
- **FileZilla, FreeFileSync**: still manual. No `manifests/t/TimKosse`, no FileZilla or FreeFileSync folder under `manifests/f`, `manifests/t`, no Zenju folder under `manifests/z`; nothing in the Store search.
- **Sublime Text 4** (`SublimeHQ.SublimeText.4` 4.0.0.421500, build 4215: the 4.x edition): an inno installer (Scope machine, `DefaultInstallLocation %ProgramFiles%\Sublime Text`, AppsAndFeatures "Sublime Text") and a zip/portable ("Sublime Text (Portable)") whose nested files name `sublime_text.exe`; InstallModes silent. Scope either; verify: the existing detect names plus `%ProgramFiles%\Sublime Text\sublime_text.exe` (inno location + executable name; the portable installation is matched by the uninstall prefix).
- **ChatGPT** (`9PLM9XGG6VKS`): resolves, publisher OpenAI, Installer Type msstore. AppX name not exposed: `appx` left unset (not guessed); perUser.
- **Claude Desktop** (`Anthropic.Claude` 6.28899.6): MSIX installers first (`PackageFamilyName Claude_pzs8sxrjxfjjc`, x64/arm64) plus per-user exe installers (Scope user, `--silent`, ProductCode `AnthropicClaude`). verify: appx `Claude`, perUser. The manifest has no display name or path, and nothing indicates completion only at first launch, so no uninstall name, no `%LocalAppData%` file, no `after`.
- **Node.js (LTS)** (`OpenJS.NodeJS.LTS` 26.13.1): wix, Scope machine, x64/arm64, Commands node/npm/npx/corepack, no AppsAndFeatures entry. The same nodejs.org MSI family records DisplayName "Node.js" (publisher Node.js Foundation) in `OpenJS.NodeJS` 26.0.0-26.5.0, so `verify.uninstall` is "Node.js". `%ProgramFiles%\nodejs\node.exe` appears in no manifest, so no file evidence is written; PATH is never used. `OpenJS.NodeJS` (Current, 26.12.1) is a distinct package and not in the catalog.
- **Adobe Acrobat Reader (64-bit)** (26.003.22110): exe, Scope machine, `Silent: -sfx_nu /sAll /rs /msi`, AppsAndFeatures DisplayName "Adobe Acrobat (64-bit)" (confirms the detect name), ProductCode `{AC76BA86-1033-FF00-7760-BC15014EA700}`, reboot may be required (3010/1641).

## Visual C++

Each family keeps one entry per architecture (x86 is never redundant on 64-bit Windows: 32-bit programs load the x86 runtime) and the descriptions say so. 2015-2026 (v14, burn, machine): `verify.registry` Microsoft's documented runtime keys, `HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64` `Installed` = 1 (64-bit view) and `...\Runtimes\X86` `Installed` = 1 (32-bit view, i.e. WOW6432Node); the manifests carry no display name. 2013 and 2012: uninstall prefixes "Microsoft Visual C++ 2013/2012 Redistributable (x64|x86)" from AppsAndFeaturesEntries. 2010: the manifests name only the MSI ProductCode (no display name), so verification is WinGet's own record. The `Microsoft.VCRedist.2015+.x64` manifest also lists an x86-architecture copy of the x64 installer marked unsupported on x64 and arm64; it is ignored.

## Duplicates and other findings

No true duplicates: no two entries share a package, and no alternate id is another entry's package. Same-publisher pairs are distinct products or channels (Thunderbird / Thunderbird ESR, Chrome / Chrome Canary, Python 3.12-3.14, Temurin JRE 21/25 and JDK 25, each VC++ family and architecture).

Recorded as problems, not changed: 74 packages download from an unversioned URL (their published hash goes stale whenever the publisher replaces the file; the engine retries after a source refresh, never ignores the hash); `guiformat` uses an `http://` URL (integrity rests on the hash) and its manifest dates from 2023, like `hidhide`, `win32diskimager` and `ubuntu-2404` (2024), which are the newest versions in the repository and install silently.

## Profiles

Revision 2 (`profiles.json`): `amazon-music` removed from Music Lover's recommendations and `whiteboard` from Touchscreen's (its description no longer mentions Whiteboard). Battle.net stays a Gamer default as a manual follow-up. Revision 1 (`profiles-v1.json`, frozen) still lists `whiteboard` (Touchscreen); the profile loader must resolve it to the removal record instead of rejecting the file.
