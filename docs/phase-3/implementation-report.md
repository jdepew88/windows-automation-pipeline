# Implementation report: Phase 3 (WinGet provisioning and application profiles)

Branch: `feature/phase-3-winget-provisioning`, based on `feature/phase-2-windows-updates`
(`a20a8f4`). Phase 2 is **not** merged into `main`, so Phase 3 builds on the Phase 2 branch and
keeps its history. `main` and the deployed Cloudflare Worker are unchanged.

Related: `profile-format.md`, `orchestration.md`, `testing.md`.

## Plan (as carried out)

1. **Model:**
   - WinGet JSON import, validation and export against Microsoft's `packages.schema.2.0.json`;
   - a data-only catalog;
   - composable profiles in a separate, versioned format;
   - a resolver that de-duplicates by source + identifier and orders the queue;
   - profile schema v3 with migrations that keep Milestone 1 and Phase 2 output unchanged.
2. **Engines (PowerShell 5.1, no third-party code):**
   - a WinGet bootstrap that uses only Microsoft's documented procedures;
   - an application engine that runs as the signed-in user;
   - an installer that registers a per-user task;
   - one coordination block shared with the Phase 2 engine.
3. **UI:** Application provisioning and Additional Software sections, review summary rows, and
   grouped deployment assets.
4. **Contracts:** results schema, `orchestration.json`, and the Phase 4 driver interface.
5. **Tests and documentation.**

## Built

### Model and data (`src/engine/applications`, `src/engine/schema/applications.ts`)

- **WinGet JSON** (`winget-json.ts`):
  - validates every rule of the official schema;
  - normalises into `PackageRef`s, keeping `PackageIdentifier`, the source and its
    `SourceDetails` separate from the display name;
  - recognises Microsoft's `winget` and `msstore` sources only by their exact details. A source
    that just borrows the name becomes "unverified" and is never installed;
  - drops installer override arguments and channels with a warning;
  - enforces 5 MB and 2000-package limits;
  - exports schema-valid lists grouped by source;
  - `winget import` 1.29.250 accepted a generated file (see `testing.md`).
- **Identifier rules** (`ids.ts`): strict patterns for winget and Microsoft Store identifiers and
  for versions, so only safe characters ever reach a command line. All 165 identifiers in a real
  `winget export` pass.
- **Catalog** (`src/data/apps/catalog.json`, `catalog.ts`): 48 manually maintained entries in 11
  categories, validated at load. Each entry records:
  - display name, identifier, source, category, description, website and licence;
  - architectures and scope where known (mostly "unknown", rather than guessed);
  - dependencies, interaction, account sign-in and restart notes;
  - **validation status with date and method**: 47 verified with `winget show` on 2026-10-19, and
    `LaunchBox` **unresolved**, with no identifier rather than a guessed one.

  Being listed selects nothing. Entries can be edited without changing any engine.
- **Profiles** (`selection.ts`, `profiles.ts`):
  - six built-in profiles (Everyday Essentials, Gaming, Developer / Power User, Laptop,
    Touchscreen / 2-in-1, Custom), **all empty**;
  - custom profiles, inheritance with cycle detection, combining profiles, individual additions
    and removals;
  - create, duplicate, rename, delete and "save selection into a profile";
  - import and export in the builder format, plus native WinGet import into a new profile.

  Imports never overwrite existing profiles or selections. The builder format is strict, so
  credentials cannot be carried.
- **Schema v3:** `applications` and `additionalSoftware` sections are added. The migrations:
  - v2 profiles get an empty selection, so Phase 2 output is unchanged;
  - Milestone 1's record-only `deferred.wingetPackages` moves into an **unselected** profile, so
    the answer file is unchanged.

### Engines (`src/engine/applications/scripts`)

- **`WinGetBootstrap.ps1`:** user-context check (refuses SYSTEM); probe via the App Execution
  Alias; documented `Add-AppxPackage -RegisterByFamilyName`; offline packages (Microsoft signature
  required); optional `Repair-WinGetPackageManager`; never reinstalls a healthy WinGet; a clear
  failure message with every step logged. `-Mode Check` is read-only.
- **`ApplicationEngine.ps1`:**
  - single instance; atomic state; preparation in parallel with Windows Update, then the
    `updatesFirst` gate;
  - per package, under the shared install lock: `winget list`, then `winget install --id --exact
    --source --silent --no-upgrade …` built from validated tokens only;
  - exit-code mapping to the nine statuses; retries, a timeout and attempt limits;
  - restarts by policy, then verification; recovery after a crash; dependency-aware skipping;
  - Additional Software; `result.json`, `follow-up.txt`, events, a completion marker and task
    removal;
  - `-Mode Plan` is a read-only dry run.
- **`Install-ApplicationEngine.ps1`:** refuses SYSTEM and needs elevation; locks down the data
  folder with ACLs; archives the previous run; registers `\WindowsDeploymentBuilder\Applications`
  for the current user (interactive, highest privileges, at sign-in and hourly, no stored password);
  starts it and waits for it to check in.
- **Phase 2 engine 1.0.0 → 1.1.0:** installs updates and restarts only while holding the shared
  install lock, writes the restart marker, and adds `lockWaitMinutes`. It gains two non-final
  outcomes: `WaitingForLock` and `RebootDeferred`. **Final statuses, marker and limits are
  unchanged**, the 22 original scenarios pass unchanged, and 3 new scenarios cover the changes.

### Answer file and assets

- With applications (or Additional Software entries) selected:
  - the three scripts, `applications-config.json` and the native `winget-packages.json` are
    embedded and extracted to `C:\Windows\Setup\Scripts\Applications`;
  - the application installer becomes the **last** FirstLogon command, after the Windows Update
    installer;
  - with nothing selected, nothing is generated.
- **Deployment assets** (Review & download, grouped by Windows Update engine, Application
  provisioning and Orchestration; built in the browser, works offline, no backend):
  - `ApplicationEngine.ps1`, `WinGetBootstrap.ps1`, `Install-ApplicationEngine.ps1`;
  - `applications-config.json`;
  - `winget-packages.json` (also usable with `winget import`);
  - `application-profile.json`;
  - `applications-plan.txt` (execution preview with the exact commands);
  - `applications-results.schema.json`;
  - `README-Applications.txt`;
  - `orchestration.json` (stages, order, locks, result files, and the Phase 4 driver hand-off).

  All of them are reproducible and carry no timestamps, ready for the future ZIP bundle.
- Samples: `docs/samples/applications/`, generated from a labelled **illustrative** selection, not
  from owner defaults.

### UI

- **Application provisioning section.** Basic view:
  - six profile cards with tick boxes and package counts;
  - New profile, Import WinGet or profile JSON, Export selection as WinGet JSON;
  - the selected applications with a count, badges (verified, not in catalog, unresolved, Store,
    needs interaction, sign-in after install, may restart) and remove buttons, plus restore for
    removed packages;
  - duplicate, conflict and unresolved warnings;
  - catalog search, category filter and an "Add to" target (this deployment or a profile).
- **Advanced view adds:**
  - per-profile Save selection here, Duplicate, Rename, Delete, Export and contents;
  - package identifiers and sources, and where each package comes from;
  - Add by package identifier (validated);
  - the installation-order preview with exact commands and the full plan;
  - troubleshooting notes;
  - coordination and restart policy, App Installer registration, online repair and the seven
    limits.
- **Additional Software section:** structured entries with all metadata fields and field-level
  validation.
- **Review:** "Applications" and "Additional software" summary rows, and grouped assets.
- The same tokens and components as the rest of the app. Screenshots were checked on desktop and
  mobile, with no horizontal scroll.

### Contracts

- `results.ts`: package and final status vocabularies, a Zod schema, the published JSON Schema
  and the exit-code table. The TypeScript and PowerShell copies are checked for equality.
- `orchestration.ts`: stages, the `updatesFirst` coordination, `install.lock` and
  `restart-pending.json`.
- `drivers/contract.ts`: Phase 4 inventory, plan and result types, with selection rules. Interface
  only.

## Tested

See `testing.md`:

| Check | Result |
|---|---|
| Typecheck, lint | Clean |
| Vitest | 268 tests in 13 files |
| `Engine.Tests.ps1` | 25/25 |
| `Applications.Tests.ps1` | 45/45 |
| Playwright | 32/32 (desktop and mobile) |
| Build | Passes |
| Milestone 1 XML | Byte-identical with both engines off |
| Phase 2 profiles | A v2 profile imports with an empty selection and produces the same XML as today's owner defaults. Against the Phase 2 snapshots, the only differences are the WU engine 1.1.0 text and `lockWaitMinutes` in its config. |

Read-only checks on real Windows:
- WinGet check: Healthy.
- Engine plan for 5 packages: correct installed/available state and commands, nothing written.
- `winget import` accepted a generated file.
- A real 165-package export imported without rejections.

Tests found and fixed these defects:
- A source that only claimed the name "winget" could merge with the real package.
- Changing "Add to" did not refresh the catalog buttons.
- Migrated legacy IDs were de-duplicated case-sensitively.
- `splitArgs` split `/D="C:\Program Files\X"` wrongly.

## Not tested / requires real Windows validation

Nothing was installed or restarted. Everything that installs or restarts has only run against
simulations. See the VM checklist in `testing.md`.

- WinGet availability and registration timing in the first sign-in session; the per-user task
  (interactive, highest privileges) as created from FirstLogon.
- Real installers: silent behaviour, exit codes, scope (`user` packages from an elevated context),
  Store installs without a Microsoft account, restart-requiring packages.
- Lock and marker hand-over between SYSTEM (Windows Update) and the user's elevated process on a
  real machine (both write in `C:\ProgramData\WindowsDeploymentBuilder\state`, which allows
  Administrators full control).
- Offline App Installer bundles and online repair from the PowerShell Gallery.
- Still pending from earlier phases: the Milestone 1 VM runs and the Phase 2 VM checks.

## Known limitations

- Only the `updatesFirst` policy. Interleaving is designed for (same lock and marker) but not
  implemented.
- Sources other than `winget` and `msstore` are kept but not installed; adding sources on the
  device is out of scope.
- The application stage needs an administrator account, and it runs only while that user is
  signed in. Without automatic sign-in it waits for the next sign-in.
- Additional Software never runs automatically in this release: the reviewed list is empty and no
  downloads happen. Entries become a follow-up checklist.
- Catalog metadata such as architectures, scope and interaction is mostly "unknown". Only
  identifiers were verified, on 2026-10-19 with winget 1.29.250, and they need re-verifying over
  time.
- A package that WinGet reports as installed but `winget list` cannot see (some portable or Store
  packages) is still reported as `Succeeded`, with a note.
- JSON files extracted from the answer file are written in the system ANSI code page (the existing
  Milestone 1 extraction script). Identifiers are ASCII, but non-ASCII display names may appear
  garbled in logs.

## For Phase 4 and later

- Manufacturer drivers: implement `drivers/contract.ts` (inventory, plan, install, validate) as
  stage 3 in `orchestration.json`.
- Deployment ZIP and `setup.ps1` orchestrator: bundle the grouped assets, read
  `orchestration.json`, wait for markers and summarise all results.
- Optional: a reviewed Additional Software list, a configurable interleaved coordination policy,
  catalog re-verification tooling, and PowerShell 7 through the catalog (`Microsoft.PowerShell`)
  in place of the `deferred.installPowerShell7` switch.
