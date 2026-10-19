# Architecture

```
profiles/owner-default.json      ← single source of owner defaults (validated at load)
src/
  engine/                        ← framework-agnostic; runs in Node and the browser, no DOM
    schema/profile.ts            Zod schema, SCHEMA_VERSION, types
    profiles/                    owner defaults, import/export, secret stripping, migrations, diff
    naming.ts                    deterministic username / "<Name>-Computer" derivation + rules
    xml/                         typed element tree, namespace-aware ASCII-safe serializer, parser
    stages/                      command builders, PowerShell sequences (Specialize/DefaultUser/UserOnce/FirstLogon)
    context.ts                   GenContext: base document, component helpers, command appenders, embedded files
    pipeline.ts                  generate(profile) → { ok, issues, xml, fileName, embeddedFiles, assets }
    validation/                  validate.ts (schema + cross-field), xml-structure.ts (post-build checks)
    settings/types.ts            SettingDef: the declarative metadata contract
    resources/upstream.ts        verbatim upstream script/task resources (generated)
    windows-update/              Phase 2 update engine: config.json builder, downloadable assets
      scripts/*.ps1              WindowsUpdateEngine.ps1 + Install-UpdateEngine.ps1 (static, tested directly)
  features/<section>/index.ts    settings: SettingDef[]  +  validate(profile, issues)  +  modify(ctx)
  data/                          upstream reference data (locales, keyboards, editions, components, …)
  ui/                            vanilla-TS DOM UI rendered from the registry
  main.ts                        app shell (header actions, sections, issue routing, review)
tests/unit, tests/e2e            Vitest and Playwright
tests/powershell                 engine scenarios against a simulated Windows Update Agent (run by Vitest on Windows)
scripts/                         sample generator, settings-doc generator
```

## Data flow

1. The **UI** edits one in-memory `Profile` (`ui/store.ts`). The profile is never saved
   automatically. Only the Basic/Advanced view choice goes to `localStorage`.
2. Every change calls **`generate(profile)`**:
   1. `validateProfile`: Zod schema (types, enums, unknown keys), XML-representable characters,
      then each feature's `validate` (cross-field rules). Each issue carries a dotted `path`, and the
      UI shows it next to that field. **Any error stops generation.** No XML is produced or shown.
   2. `build`: `GenContext` creates the base document. Feature modifiers then run in upstream's
      order (see `pipeline.ts`). Modifiers change XML only through context helpers
      (`component`, `setValue`, `appendCommand`, `embedFile`) or append PowerShell to one of the four
      **sequences**.
   3. `emitSequences`: each non-empty sequence becomes an embedded `.ps1`:
      - Specialize → `RunSynchronous` (specialize, SYSTEM)
      - DefaultUser → `reg load HKU\DefaultUser` / run / `reg unload` (specialize)
      - UserOnce → a `RunOnce` value written into the default hive
      - FirstLogon → `FirstLogonCommands` (oobeSystem)
   4. Advanced components are parsed and inserted. Overlap with generator-owned components is an error.
   5. `<Order>` and `wcm:action="add"` are added to generated command lists. Components are fanned
      out per architecture.
   6. `checkStructure`: passes, component identity attributes, unique component/pass/arch, sequential
      `Order`, and **no disk automation elements**.
   7. `serialize`: CRLF, tabs, and non-ASCII written as character references (Windows Setup only
      handles ASCII reliably).

## Staging scripts without network or media

Answer-file commands are limited to one command line each, so larger scripts are embedded as
`<Extensions><File path="C:\Windows\Setup\Scripts\…">`. The first `RunSynchronous` command in
specialize loads `C:\Windows\Panther\unattend.xml` (Setup's own copy of the answer file) and runs the
embedded extraction script, which writes every file to disk. This is upstream's tested pattern.
FirstLogon then runs from local disk, independent of network or USB media. A FirstLogon step deletes
the Panther copies afterwards unless "Keep sensitive files" is on.

## Windows Update engine (Phase 2)

Enabled by `windowsUpdate.enabled` (owner default: on). The design review, including the AutoPatch
licence assessment, is in `docs/phase-2/review.md`.

```
specialize   extract WindowsUpdateEngine.ps1, Install-UpdateEngine.ps1, config.json
             → C:\Windows\Setup\Scripts\WindowsUpdate\  (Administrators-only)
FirstLogon   …all M1 steps (FirstLogon.ps1)… → LAST command: Install-UpdateEngine.ps1
               secure C:\ProgramData\WindowsDeploymentBuilder (SYSTEM/Admins full, Users read)
               copy engine + config to …\Updates, archive any previous run
               register task \WindowsDeploymentBuilder\WindowsUpdate (SYSTEM; at startup +2 min; hourly)
               start it and wait for the engine to check in (status.json)
engine       mutex → state.json → limits → wait for network → wait while installer busy
             loop: search (WUA) → plan (policy, exclusions, given-up) → download → install
                   → reboot (shutdown /r /t N) and exit; the task resumes it after boot
             nothing left (after confirmation scans) → result.json, event, marker, remove task
```

- **Only documented interfaces**: `Microsoft.Update.Session`/`Searcher`/`Downloader`/`Installer`,
  `Microsoft.Update.SystemInfo`, `Microsoft.Update.ServiceManager` (only when Microsoft Update is on),
  the inbox `ScheduledTasks` module and `shutdown.exe`. No third-party modules, no downloads.
- **Policy**: drivers by update `Type`, feature updates by the `Upgrades` category GUID, optional
  updates by `BrowseOnly`, updates that need user input are never attempted, KB exclusions.
- **Loop protection**: each update's attempts are counted *before* acting (so crashes count too).
  An update is given up after `maxAttemptsPerUpdate`. That also covers updates that report success
  but keep being offered. A one-time component reset grants one more attempt. Further hard stops:
  `maxReboots`, `maxRuntimeHours`, `maxErrors` (unexpected exceptions) and 50 passes per start.
- **Outcomes**: `Succeeded`, `CompletedWithFailures`, `Failed`, `Offline` in `result.json`, plus
  Application events 1100–1103. The orchestrator contract is the marker file
  `C:\ProgramData\WindowsDeploymentBuilder\state\windows-update.done`, written only for `Succeeded`
  and `CompletedWithFailures`.
- **Testability**: everything that touches the system is a small adapter function. The scenario tests
  dot-source the engine (which defines functions without running) and replace the adapters with a
  simulation, including time.
- With the engine **off**, the answer file is byte-identical to Milestone 1. This is enforced by
  `tests/unit/windows-update.test.ts` against a frozen fixture.

## Extension points for later milestones

- `profile.deferred` (`installPowerShell7`, `wingetPackages`) is recorded and round-tripped.
  Nothing reads it during generation.
- A future `bundle/` module can call `generate()` and use `embeddedFiles` plus the profile to build
  `Windows-Deployment.zip` (`setup.ps1`, WinGet JSON, README) without changes to the engine.
- New settings: add a schema field, an owner default, a `SettingDef` and a `modify`/`validate`
  function. `tests/unit/registry.test.ts` fails if the registry and schema drift apart.
- Schema changes: bump `SCHEMA_VERSION` and register a step in `profiles/migrations.ts`. v1→v2 adds
  `windowsUpdate` with the engine **off**, so profiles exported by Milestone 1 keep producing the
  same answer file.
- A Phase 3 orchestrator waits for `windows-update.done` (or reads `result.json`) before installing
  applications. The engine needs no changes for that.

## Key decisions

- **Own XML tree instead of XMLBuilder2.** It gives exact control over namespaces, prefixes, ASCII
  escaping and layout, needs no dependency, and is easy to snapshot. Parsing user markup uses
  `@xmldom/xmldom`, then converts into the same tree, so user input is never concatenated as a string.
- **Vanilla TS UI.** The UI is generated from `SettingDef`s, so a framework added little. Custom
  editors cover lists and tables.
- **Flat "mode + fields" sections.** Switching a mode keeps sibling values, so toggling views or
  modes never discards input.
