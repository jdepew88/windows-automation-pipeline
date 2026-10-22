# Phase 4.3 architecture: Quick Deployment and Advanced Configuration

## Audit of the starting point (Phase 4.2, `06cfecf`)

* **One configuration object.** `Profile` (`src/engine/schema/profile.ts`, schema version 4) holds
  every setting, grouped by section (`setup`, `accounts`, `security`, `privacy`, `updates`,
  `windowsUpdate`, `applications`, `additionalSoftware`, `system`, `explorer`, `taskbar`,
  `desktop`, `start`, `personalization`, `bloatware`, `virtualization`, `wifi`, `scripts`,
  `advancedXml`, `output`, `deferred`). 144 settings are registered in `src/features/*`
  (`docs/settings-mapping.md`).
* **UI state.** `src/ui/store.ts` keeps the one `Profile` in memory (never persisted). Each setting
  renders through `src/ui/form.ts`; `src/main.ts` builds one page per section, the sidebar
  (`src/ui/layout.ts`), Basic/Advanced visibility, routing by `#section-<id>`, and runs
  `generate()` on every change.
* **Saved data.** Only application profiles saved with "Save as new profile…" are kept in
  `localStorage` (`wdb.appProfiles`, `src/ui/library.ts`); the theme and the Basic/Advanced view
  are preferences. Full configurations are exported/imported as JSON (`exportProfile`, passwords
  left out unless "Include passwords" is ticked).
* **Generated artifacts.** `generate(profile)` → `autounattend.xml` (every script embedded);
  `buildDeploymentPackage(profile, result)` → `windows-deployment-package.zip` (answer file, the
  `WindowsDeployment` folder with manifest, orchestrator, both engines, configs, profiles, docs).
* **Relationship.** UI controls → `Profile` → `generate()` / `buildManifest()` → files. Saved
  application profiles are a part of `Profile.applications.selection`; the manifest and
  `applications-config.json` are derived from the same `resolveSelection()` the UI shows.

Findings that shaped Phase 4.3:

* Windows 11 Pro (`setup.editionId = pro`, generic key) and x64 (`processorArchitectures = [amd64]`)
  were already the owner defaults; nothing needed to change there.
* The ongoing Windows Update policy (`updates.mode`, `AUOptions`) was written during **specialize**,
  i.e. before the initial update engine ran. The request requires it to follow the initial
  updates (see [windows-update.md](windows-update.md)).
* SSID/password Wi-Fi was a real implementation (embedded `Wifi.xml`, `netsh wlan add profile`
  during specialize) but had no adapter/driver check, no result, no retry, and rejected SSIDs with
  double quotes (see [wifi.md](wifi.md)).
* Device answers use one "primary phone" field plus three extra-device switches; the wizard keeps
  that model (Android phone + iPad still recommends Apple Devices).

## Two modes, one configuration

```text
          Quick Deployment (src/ui/wizard.ts)      Advanced Configuration (src/main.ts pages)
                       \                                   /
                        +------ Store (one Profile) ------+
                                       |
                 generate() / buildManifest() / buildDeploymentPackage()
                                       |
               autounattend.xml + WindowsDeployment\ (ZIP), Final Review summary
```

* The header's **Quick Deployment | Advanced Configuration** switch changes which editor is in the
  document; both read and write the same `Store`. There is no wizard state object: the wizard keeps
  only the open step and the risks acknowledged in this session.
* All wizard logic that touches settings is in `src/engine/quick.ts` (pure functions, unit tested):
  customer types, username/computer-name mapping, the update selector, step status, blocking
  steps, considerations and the review summary.
* Only one editor is mounted at a time (the wizard is detached in Advanced mode; the Advanced pages
  are hidden in Quick mode) so ids and test ids stay unique. Switching never resets anything.
* The mode is a per-browser preference (`wdb.mode`); a link to an Advanced page (`#section-…`,
  `#app-…`) opens Advanced. New visitors start in Quick Deployment.

### Advanced Configuration is unchanged

Every section, sidebar entry, Basic/Advanced toggle, control, description and technical-details
panel is still there. The only visible changes in Advanced are: the Account page uses a two-column
field/explanation layout and shows a one-line pointer instead of the long administrator warning;
SSID and password are visible in Basic view as soon as "Configure a network from SSID and password"
is chosen; the catalog has four layouts and logos; the Review page gains a
"Security & licensing considerations" card.

## Wizard flow

| Step | Edits | Status shown |
|---|---|---|
| 1 Computer & local account | `accounts.personName` (or `customUsername`), computer name (`computerNameMode`/`customComputerName`); collapsed "Windows settings": edition, predefined region and keyboard (`setup.languageMode`), ongoing update policy (`updates.mode`), privacy summary | Incomplete until a valid username exists |
| 2 Computer & customer type | Built-in profiles (`selectedProfiles`), saved profiles, devices, laptop location (`privacy.disableLocation`) | Using defaults / Customized |
| 3 Network | `wifi.mode`, SSID, password (masked, show/hide), security, hidden network, connect automatically | Using defaults / Customized / Incomplete |
| 4 Applications | The Phase 4.2 editor (catalog + plan, Save as new profile, import/export) | Using defaults / Customized / Needs attention |
| 5 Final Review & Considerations | Acknowledgements (session only), Generate Deployment ZIP | Incomplete until critical risks are acknowledged |

* **Navigation.** Top: Previous, *Go to Applications*, *Final Review*, *Advanced Configuration*,
  Next. Bottom: Back, Next (on the last step: Generate Deployment ZIP). Every button calls the same
  `go()`: moving forward runs `blockingStep()` over every earlier step; if one has an error or
  missing required input, the wizard stops at that step, says why and focuses the field. The
  progress bar lets you jump to any step under the same rule.
* **Quick path.** Name → type → *Go to Applications* → adjust → *Final Review* → Generate. Steps
  left at their defaults are marked "Using defaults" and need not be opened.
* Nothing is fabricated: an empty username is an error, never a placeholder name.

## Defaults

Unchanged owner defaults: Windows 11 Pro (generic key), x64, English (United States) with the
predefined region and keyboard, Core Essentials, owner privacy settings, Windows Update automation
on, ongoing policy "download automatically, notify before installing". Wi-Fi defaults to
**Skip Wi-Fi configuration** (`wifi.mode = interactive`: nothing stored; Windows shows its own
network page only if it needs one). The Advanced choice "Skip Wi-Fi setup" (`skip`, hides that
page) is still available and shown in the wizard as "Customized in Advanced Settings".

## Customer types and profile composition

Customer types are exactly the Phase 4.2 built-in profiles (`everyday`, `gaming`, `developer`,
`network-engineer`, `music`, `laptop`, `touch`) plus Core Essentials; ticking one is the same
operation as the Advanced profile checkbox (`toggleProfile`). Individual ticks and unticks
(`added`/`removed`) survive ticking or unticking types and switching layouts or modes; built-in
definitions are never edited. Saved profiles appear in step 2 next to the built-in types.

"Customized in Advanced Settings" appears when a value the wizard summarises differs from what the
wizard itself sets (edition from a product key, non-x64 architectures, a custom update policy,
changed privacy settings, location allowed without Laptop, a Wi-Fi mode the wizard does not offer).

## Region and language

"Use the deployment's predefined region and keyboard settings" is `setup.languageMode`:
unattended (the existing validated `imageLanguage`, `userLocale`, `keyboard`, `geoLocation`, which
skips Setup's language and keyboard pages) or interactive. No new locale values were introduced;
every regional setting stays in Advanced › Setup, region & edition. Whether every build skips every
regional page has not been validated in a VM.

## Final Review & Considerations

`reviewSummary()` describes the effective configuration (computer, networking, Windows Update,
privacy, applications, package) and `considerations()` lists only what applies:

| Id | When | Confirmation |
|---|---|---|
| `autologon-admin` | local Administrator, empty password, automatic sign-in | required (once per session per username/mode) |
| `autologon-password` | password set with persistent automatic sign-in | – |
| `generic-key` | generic setup key: not a license | – |
| `product-key` | product key in the answer file | – |
| `wifi-secret` | Wi-Fi password (or key material in a profile XML) embedded | required (once per session per SSID) |
| `wifi-driver` | Wi-Fi configured | – |
| `update-approval` | a notify policy delays security fixes | – |
| `manual-apps`, `interactive-apps`, `sign-in-apps` | manual follow-ups, installers that may prompt, apps needing a sign-in | – |
| `bypass`, `keep-sensitive` | hardware checks bypassed, sensitive files kept | – |

Validation errors block generation in both modes. In Advanced, the download buttons keep their
behaviour; embedding a Wi-Fi password asks for the same one-time confirmation.

## Persistence and compatibility

* No schema change: Phase 4.3 uses schema version 4 as is, so every saved or exported profile
  (v1–v4) imports exactly as before.
* New browser keys are preferences only: `wdb.mode` and `wdb.catalogView`. Passwords are never
  stored in the browser: the store is in memory, saved application profiles contain no account or
  Wi-Fi data, and exports leave passwords out unless "Include passwords" is ticked.
