# Upstream attribution and provenance

## Reference revision

- Repository: <https://github.com/cschneegans/unattend-generator>
- Revision used: `27237f82e9a8498d9c5bab7d398dc34b7682a1e8` (2026-10-11, "Add built-in script to ask for computer name via an interactive prompt #281")
- License: MIT, `LICENSE.txt`, "Copyright (c) 2024-2025 Christoph Schneegans". The full text is in `THIRD_PARTY_NOTICES.md`.

## What the repository does and does not contain

The repository holds the **C# library only**: `Main.cs`, `modifier/*.cs`, and `resource/*` (JSON data,
PowerShell/VBScript snippets, scheduled-task XML, XSD schemas). It does **not** contain the HTML,
JavaScript or CSS of the live site at <https://schneegans.de/windows/unattend-generator/>, and the MIT
license does not cover those website assets. **This project copies nothing from the website.** I viewed
the live form only to cross-check option labels and semantics against the library. The UI here is
original.

## Used from upstream

| Kind | Upstream source | Where here | How |
|---|---|---|---|
| Reference data | `resource/{ImageLanguage,UserLocale,KeyboardIdentifier,GeoId,TimeOffset,WindowsEdition,DesktopIcon,StartFolder,Component}.json` | `src/data/upstream/*.json` | Copied; only re-formatted (BOM removed) |
| Script/task resources | `resource/{ShowAllTrayIcons.ps1,.xml, UnlockStartLayout.vbs,.xml, MoveActiveHours.xml, VBoxGuestAdditions.ps1, VMwareTools.ps1, VirtIoGuestTools.ps1, ParallelsTools.ps1, TurnOffSystemSounds.ps1, MakeEdgeUninstallable.ps1, SetStartPins.ps1, RemoveBloatware.ps1}` | `src/engine/resources/upstream.ts` | Copied verbatim into string constants (generated) |
| Extraction script | `resource/ExtractScripts.ps1` | `EXTRACT_SCRIPT` in `src/engine/context.ts` | Copied verbatim |
| Base answer file | `resource/autounattend.xml` | `createBaseDocument()` in `src/engine/context.ts` | Reimplemented as a typed tree; the `Extensions` namespace was changed to this project's URN |
| Engine design | `Main.cs` (`CommandBuilder`, `PowerShellSequence`, `EmbedFile`, modifier order), `modifier/{Order,EmptyElements,ProcessorArchitecture,Components}.cs` | `src/engine/stages/*`, `src/engine/pipeline.ts`, `src/engine/context.ts` | Reimplemented in TypeScript |
| Feature mappings | `modifier/{Bypass,ProductKey,Locales,ComputerName,Users,Lockout,PasswordExpiration,ExpressSettings,Wifi,Optimizations,Bloatware,Script,AppLocker,TimeZone,Accessibility,Delete,Specialize,DefaultUser,UserOnce,FirstLogon}.cs` | `src/features/*` | Reimplemented; the registry values, commands and XML paths come from upstream |
| Bloatware identifiers | `resource/Bloatware.json` | `src/features/bloatware/catalog.ts` | Selectors and applicability copied. Entries were split or relabelled for the owner's list (see below) |
| Validation rules | `Account.ValidateUsername`, `CustomComputerNameSettings`, `ProductKey`, `CustomLockoutSettings`, Wi-Fi profile logic | `src/engine/naming.ts`, `src/features/*/index.ts` | Reimplemented |

## Not copied

- **XSD schemas** (`autounattend.xsd`, `AppLocker.xsd`, `WLAN_profile_v1.xsd`, `TaskbarLayout.xsd`).
  They are probably Microsoft-derived and their provenance is unclear, so they were not
  redistributed. Instead, structure is checked by `src/engine/validation/xml-structure.ts` and the
  feature validators. Authoritative validation stays with WSIM (see `docs/testing.md`).
- Upstream's PE-stage `.cmd`/diskpart generation (`modifier/Disk.cs`). Disk automation is out of scope by design.
- Upstream's commit-hash `Build` extension element.

## Deviations from upstream (deliberate)

| Area | Upstream | Here | Why |
|---|---|---|---|
| Auto-logon | Logs on once (`LogonCount=1`, then `AutoLogonCount=0`) | Adds a "persistent" mode: removes `AutoLogonCount` and restates the Winlogon values. Allowed only with an empty password | Owner requirement. **Unverified on hardware** |
| Bloatware | Removes for all Windows 10/11 builds | Removal scripts exit unless build ≥ 22000 and ProductType = 1 (client) | Spec: no removal without platform detection |
| Xbox | One "Xbox Apps" entry | Split into app & services, Game Bar and Identity Provider | Owner's per-app decisions |
| Windows Backup, Teams personal, Microsoft Pay, Media Player naming | n/a or different labels | Windows Backup: no removal mechanism (Keep/Untouched only). Microsoft Pay → `Microsoft.Wallet`; Teams personal → `MicrosoftTeams`/`MSTeams` | Map owner wording to real package identities only where one exists |
| Windows Update | "Disable Windows Update" (pause task) offered | Not offered. Adds notify modes (AUOptions 2/3) and driver exclusion (documented policies) | Spec: do not fully disable Windows Update |
| UAC | Only "Disable UAC" | Five levels including the owner's "no dim" (5/0) | Owner requirement |
| Privacy | App suggestions, Bing results, Copilot policy | Adds documented policies for telemetry level, advertising ID, tailored experiences, inking/typing, location, Recall | Owner requirement |
| System Restore | Disable only | Enable / default / disable | Owner wants it enabled |
| Shortcut arrows | n/a | `Shell Icons\29` tweak | Owner requirement. **Undocumented, unverified** |
| Advanced XML components | Replaces an existing component's content silently | Rejects overlap with generator-owned components; checks names/passes against `Component.json`; forbids disk elements and foreign namespaces | Spec: reject conflicting insertions |
| Output | `Extensions` namespace `https://schneegans.de/…` | `urn:windows-deployment-builder:extensions:v1` | Don't present our output as upstream's |
