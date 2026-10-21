# Phase 4.2 implementation report: application catalog, profiles and device ecosystems

Branch `feature/phase-4-2-application-profiles`, based on Phase 4 (`6f59166`). Not merged into
`main`; not deployed to Cloudflare. No driver or PXE work.

## Audit of the starting point (Phase 3/4)

* Catalog of 48 apps (`src/data/apps/catalog.json`), WinGet and Store sources only, every
  architecture "not recorded", one unresolved entry (LaunchBox).
* Six built-in profiles (Everyday, Gaming, Developer / Power User, Laptop, Touchscreen, Custom), all
  **empty**, stored inside each deployment profile and editable; nothing selected by default.
* Composition by profiles + additions + removals (`selection.ts`), identity source + identifier,
  inheritance with cycle detection, catalog dependencies used for ordering only.
* Builder profile JSON (format version 1) and native WinGet import/export; Additional Software as
  manual follow-ups; engine 1.0.0 handled WinGet and Store packages only.
* No browser persistence besides view and theme.

## What was added

| Area | Files |
|---|---|
| Catalog v2 (115 apps, methods, conflicts, warnings, exclusions) | `src/data/apps/catalog.json`, `src/engine/applications/catalog.ts`, `scripts/catalog-source.mjs`, `verification-2026-10-21.json` |
| Built-in profiles as templates, device profiles | `src/data/apps/profiles.json`, `src/engine/applications/builtin.ts` |
| Selection rules: devices, dependencies, exclusions, recommendations, antivirus group, notices | `src/engine/applications/selection.ts` |
| Save as new / update / duplicate / restore / reset, format version 2, browser library loader | `src/engine/applications/profiles.ts` |
| Schema version 4 (devices, profile fields) and migration from 3 | `src/engine/schema/applications.ts`, `src/engine/profiles/migrations.ts`, `profiles/owner-default.json` |
| Engine config: methods, portable shortcuts, manual and deselected entries; escaped non-ASCII | `src/engine/applications/index.ts`, `results.ts` (`SkippedByUser`) |
| Engine 1.1.0 (targeted) | `src/engine/applications/scripts/ApplicationEngine.ps1` |
| Validation (antivirus conflicts block, notices warn) | `src/features/applications/index.ts` |
| Manifest: method, provenance, devices | `src/engine/deployment/index.ts` |
| UI: profiles, devices, one checkbox per app, filters, plan | `src/ui/app-selection.ts`, `src/ui/library.ts`, `src/ui/applications.ts`, `src/ui/review.ts`, `src/ui/layout.ts`, `src/main.ts`, `src/styles.css` |

Catalog changes compared with Phase 3/4 (48 entries): 42 kept, 73 added (115 total); Brave,
LibreOffice, SumatraPDF, IrfanView, Greenshot and Krita removed (owner exclusions). Of the kept
entries, LaunchBox changed from "unresolved" to a manual follow-up and six moved to the new
categories (VLC, 7-Zip, Bitwarden → Everyday Essentials; Everything → File Management; Sysinternals
→ System utilities; PuTTY → Remote Access); no kept identifier changed. `python-313` is kept and
`python-314` added. Every entry was re-verified, with architectures recorded. Details and the verification method: [catalog.md](catalog.md).

## Engine 1.1.0 (targeted changes only)

Nothing in the Windows Update engine, the WinGet bootstrap, the coordination lock, restart handling,
retries, timeouts or the USB staging/orchestrator changed. In `ApplicationEngine.ps1`:

* Reads the optional `method` and `portable` of each package (configs without them behave as 1.0.0).
* Portable packages: validated pattern/name/scope, installed with `--scope machine`, then
  `Set-WdaPortableShortcut` (finder restricted to WinGet's package folder, no links, no paths).
* `manual` entries → `RequiresInteraction` with "Manual action required: …" and the official URL.
* `deselected` entries → new terminal status `SkippedByUser` (counted, not a follow-up, does not
  affect the final status).
* Plan mode shows portable, manual and deselected rows.

Outcome vocabulary as requested: Installed = `Succeeded`; Already installed = `AlreadyInstalled`;
Skipped by user = `SkippedByUser`; Pending = `Pending`; Failed = `Failed`; Manual action required =
`RequiresInteraction`; Unsupported = `Unavailable` (not in the source, unsupported system, invalid or
unresolved). Store restrictions (`MSSTORE_BLOCKED_BY_POLICY`, …), missing Internet, unavailable sources
and agreements map to the existing reported failures. Result schema version stays 1; `counts` gains
`skippedByUser`.

## ZIP integration

The ZIP's `scripts/applications/applications-config.json` is the plan shown in the UI: WinGet, Store
and portable packages in install order (dependencies first) with method, scope and shortcut,
`manual` follow-ups, `deselected` apps, interaction flags and limits. `winget-packages.json` holds the
WinGet/Store part; `profiles/applications.json` the flattened selection; the manifest adds method,
origins (which profile or "added"/"required"), device profiles and devices. Every field in the config
is read by the engine (unit-tested). Verified by unit tests, by Playwright on the downloaded ZIP, and
by the Phase 4 deployment suite on a generated ZIP with every method.

## Known limitations

* **Physical installation not validated**: no VM or hardware run (see [testing.md](testing.md)).
* **RustDesk is in Core Essentials but has no WinGet or Store package**, so every default deployment
  ends `CompletedWithFollowUp` with a manual step. Also manual: FileZilla, FreeFileSync, Spybot,
  LaunchBox, .NET Framework 3.5. A reviewed vendor-installer path (hash-pinned) could automate
  RustDesk later; it was not added because the hash changes with every release.
* Store listings of Avast, AVG and Avira and the Battle.net/Nmap installers may prompt or offer extra
  products; marked "may prompt", not verified silently.
* Malwarebytes cannot be forced into on-demand-only mode; documented warning only.
* Antivirus conflicts are detected among catalog entries; an antivirus added by custom ID is not
  recognised as one.
* Portable shortcut target is chosen by file name; if a future WinGet manifest renames the file, the
  package still installs and the shortcut is reported for follow-up.
* Larger default answer file: the owner default now embeds the application engine (sample: ≈259 KB).
* Saved profiles live in one browser's `localStorage`; the unsaved current selection is not persisted.
* Most `interaction`, `scope` and `reboot` values remain "unknown" where WinGet does not report them.

## Recommended next step

Run the VM checklist in [testing.md](testing.md) together with the Phase 4 checklist (Media
Creation Tool media, owner default plus the Network Engineer profile, one run without Internet), fix
what it finds, then move on to the manufacturer-driver stage.
