# Implementation Plan — Windows Deployment Builder, Milestone 1

Upstream reference: `cschneegans/unattend-generator` @ `27237f82e9a8498d9c5bab7d398dc34b7682a1e8`
(2026-10-11, MIT). The repo holds the C# library only. The live site's HTML/JS/CSS is **not** in it, so
the UI here is original work and uses only the library's data model and XML patterns.

## 1. Architecture decisions

| Decision | Choice | Reason |
|---|---|---|
| Build/UI | Vite + vanilla TypeScript DOM rendering | Small, offline, no framework lock-in; UI generated from a settings registry |
| Schema | Zod, `schemaVersion` + migration chain | Field-level errors, typed profile, import safety |
| XML model | Own typed element tree + serializer (`src/engine/xml`) | Namespace-exact output, ASCII-safe escaping (Windows Setup only reliably handles ASCII, as upstream notes), deterministic snapshots |
| XML parsing (user input, tests) | `@xmldom/xmldom` | Works in browser and Node; reports well-formedness errors |
| Tests | Vitest (unit, snapshot), Playwright (browser smoke) | As specified |
| Lint | ESLint + typescript-eslint, `tsc --noEmit` | Acceptance criterion |

`/src/engine` stays framework-agnostic: it has no DOM and can be imported in Node.

## 2. Engine pipeline (mirrors the upstream modifier order)

`generate(profile) → { ok, issues[], xml?, fileName }`

1. `validateProfile` (Zod plus cross-field rules). Any **error** stops generation and returns the issues.
2. Build the base document: `windowsPE`, `specialize`, `oobeSystem` settings and the `Extensions` element.
3. Run the feature modifiers in order: setup (bypass, product key, locales) → accounts → bloatware →
   express settings → Wi-Fi → empty-element pruning → lockout/password → system/privacy/explorer/
   taskbar/desktop/start/personalization/virtualization → time zone → AppLocker → custom scripts →
   Specialize/UserOnce/DefaultUser/FirstLogon sequence emission → advanced XML components → `Order`
   numbering → architecture fan-out.
4. Run structural self-checks on the result: valid passes, required component attributes, unique
   component/pass/architecture, no `DiskConfiguration`/`WillWipeDisk`/`InstallTo`, `Order` sequence.
5. Serialize: CRLF, tab indent, non-ASCII written as character references.

Script staging follows upstream's tested pattern. Generated `.ps1/.cmd/.reg/.vbs` files are embedded as
`<Extensions><File path=…>`. One specialize `RunSynchronousCommand` extracts them from
`C:\Windows\Panther\unattend.xml` into `C:\Windows\Setup\Scripts`. These four sequences are then invoked:

- **System** → specialize `RunSynchronous` (SYSTEM account, before any user exists)
- **DefaultUser** → specialize, with `HKU\DefaultUser` loaded from `C:\Users\Default\NTUSER.DAT`
- **UserOnce** → a `RunOnce` value in the default hive (runs once for every new user)
- **FirstLogon** → oobeSystem `FirstLogonCommands` (runs once, first logon, admin context)

## 3. Settings registry

Every leaf setting has a central `SettingDef` with these fields: path, section, label, control,
choices, description, applicability, risk/caveat, stage(s), XML/registry/policy mapping, and a
Basic/Advanced flag. Default values come from **one** source, `profiles/owner-default.json`. The UI
renders from the registry. `docs/settings-mapping.md` is generated from the registry
(`npm run docs:settings`). A test checks that the registry and the schema cover exactly the same paths.

## 4. Feature modules (`src/features/*`)

setup, accounts, privacy, system, explorer, taskbar, desktop, start, bloatware, virtualization, wifi,
personalization, scripts, advanced-xml. Each exports its `SettingDef[]` and a `modify(ctx)` function.

## 5. Implemented vs deferred in M1

Implemented:
- Language/locale (unattended en-US or interactive, plus upstream data lists)
- Edition/key (generic key, interactive, firmware, custom key)
- Interactive disk only
- One unattended local account with derived username and `Name-Computer` hostname
- Auto-logon modes, lockout, password expiry
- Privacy policies, UAC level, Windows Update mode and driver exclusion
- All upstream system tweaks except "Disable Windows Update" (the spec forbids it)
- Explorer, taskbar, desktop icons, Start folders, Start pins
- Visual effects, sticky keys
- Tri-state bloatware
- Core isolation, VM guest tools
- Wi-Fi: interactive, skip, parameters, XML profile
- Express settings
- Four script stages
- AppLocker policy
- Advanced XML components
- Answer-file name
- Preview, download, JSON import/export, reset to owner defaults, Basic/Advanced review with diff

Deferred, with documented extension points only:
- WinGet lists/import/export, PowerShell 7 install (recorded as an intent flag only)
- ZIP bundle, `setup.ps1` orchestrator, update-check notifications
- Wallpaper, lock screen, color theme, lock keys, custom visual-effects matrix
- Script-based computer name, Windows 10 Start tiles, custom taskbar XML
- ISO/boot media editing and any disk automation

## 6. Tests

- Unit: naming derivation, escaping, serializer, each feature's mapping, validation rules, migrations,
  import/export round trip, secret stripping, components merge/conflict/malformed input, the four
  script stages and empty lists
- Snapshots: owner-default XML plus variations (interactive language, Wi-Fi profile, scripts, components,
  other editions, arm64)
- Structural XML assertions: passes, architecture, no disk-wipe nodes, interactive disk path
- Playwright: load, owner controls, Basic/Advanced toggle keeps values, name → hostname update,
  validation message, preview/download, import/export, reset

## 7. Verification limits (to be reported honestly)

WSIM/ADK catalog validation and VM install tests (with and without Internet) cannot run in this
environment. `docs/testing.md` gives the exact procedure. Those items stay **unverified**.
