# Phase 4.3 testing

## Automated results (2026-10-21, this branch)

| Check | Result |
|---|---|
| `npm run typecheck`, `npm run lint`, `npm run build` | clean |
| Vitest (`npm test`) | 378 passed in 17 files (Phase 4.2: 355 in 16); includes the four PowerShell suites run from `powershell.test.ts` |
| Windows Update engine (`Engine.Tests.ps1`) | 25/25 (unchanged) |
| Application engine (`Applications.Tests.ps1`) | 57/57 (unchanged) |
| Deployment orchestrator (`Deployment.Tests.ps1`, real generated package) | 32/32 (25 Phase 4 + 7 new) |
| Wi-Fi script (`Wifi.Tests.ps1`, generator's real `Wifi.xml` and script) | 10/10 (new) |
| Playwright, desktop 1280×720, tablet 820×1180, mobile Pixel 7 | 121 passed, 2 skipped (the mobile-only drawer test on desktop and tablet, as in Phase 4.2): 28 Phase 4.2 tests and 13 new Quick Deployment tests per size |

No assertion of an existing test was weakened. Existing tests changed only where Phase 4.3
deliberately changed behaviour or wording:

* `generate.test.ts`: the owner default no longer writes `AUOptions` during specialize (it now
  asserts that, and that `Set-UpdatePolicy.ps1` is embedded); the Wi-Fi test asserts the new
  `Add-WifiProfile.ps1` calls, the safe profile label and that the first-sign-in retry runs before
  `Wifi.xml` is deleted. Three snapshots were updated after checking that the diff is exactly the
  removed `AUOptions` lines, the new embedded script and the two orchestrator additions.
* `app.spec.ts` (Phase 4.2 browser suite) now starts explicitly in Advanced Configuration with the
  detailed list (its previous screen); the view-toggle locators use `exact: true` because the header
  gained an "Advanced Configuration" button; the account page asserts the one-line pointer plus the
  full warning in the Review page's considerations; "Default in iPhone / iPad" became
  "Selected by iPhone / iPad".
* `powershell.test.ts` runs the long suites asynchronously: run synchronously, the longer deployment
  suite blocked the Vitest worker past its RPC heartbeat ("Timeout calling onTaskUpdate", exit 1 with
  all tests passing).

## Coverage of the requested behaviour

| Requirement | Tests |
|---|---|
| Shared wizard/advanced state | `quick.test.ts` (helpers edit the one profile), `quick.spec.ts` Journeys B, E, "Wi-Fi in Advanced" |
| Top and bottom navigation, required-field validation | `quick.spec.ts` "top and bottom Next share one validation", `quick.test.ts` blocking steps |
| Default edition and architecture, Core Essentials and profile defaults | `quick.test.ts` "Phase 4.3 defaults", `quick.spec.ts` "opens in Quick Deployment" |
| Region setup behaviour, laptop location | `quick.spec.ts` "region pages and laptop location", Journey D (`DisableLocation` absent) |
| Wi-Fi: wizard and Advanced entry, masking, empty SSID/password, hidden network, special characters, Unicode, XML escaping, no logs, no browser persistence, no export, consent, missing driver/hardware, failed import, skipped Wi-Fi | `Wifi.Tests.ps1` (10 scenarios), `quick.test.ts` Wi-Fi block, `generate.test.ts`, `quick.spec.ts` Journeys A and D, "Wi-Fi in Advanced" |
| Update policy ordering and validation | `Deployment.Tests.ps1` (not during updates or across a restart, once after the stage is final, Offline, deadline, Home, domain/MDM/WSUS, existing values, write failure, report), `quick.test.ts` (engine on/off, modes) |
| Logo fallback, four layouts, selection retention | `quick.spec.ts` "catalog: logos …", Journeys C and F, `quick.test.ts` logo provenance |
| Profile overrides, browser persistence | Journeys B and C (save, reload, load), Journey F (layout preference) |
| Final review summaries, security warnings | `quick.test.ts` considerations and summary, Journeys A, D, E |
| Generated package accuracy | every journey reads the downloaded ZIP (answer file, manifest, `applications-config.json`) |
| No horizontal scroll, keyboard | `quick.spec.ts` (every wizard step and layout, Space on a focused tile), `app.spec.ts` (every Advanced section) |

## Regression against Phase 4.2 (`06cfecf`)

Generated with both source trees for six profiles:

* Both engines off: `autounattend.xml` **byte-identical** (so Milestone 1 output is unchanged).
* Applications only, or Windows Update with Windows' default policy: only the two orchestrator
  scripts embedded in the answer file differ (the monitor's policy hook, the report's policy and
  Wi-Fi sections).
* Owner default and Gaming + iPhone: additionally `AUOptions`/`NoAutoUpdate` move from specialize to
  the embedded `Set-UpdatePolicy.ps1`, and the manifest gains `updatePolicy`.
* Wi-Fi from SSID/password: additionally the inline `netsh` lines are replaced by `Add-WifiProfile.ps1`.
* The application plan, package identifiers and engine configs are unchanged.

## Screenshot review

Reviewed in dark and light themes at 1440×900, 820×1180 and 390×844: every wizard step, the four
catalog layouts, Final Review, and the Advanced account page. One defect was found and fixed (the
Final Review overflowed horizontally on phones because of the Generate button's file name). Tests
check the absence of horizontal scrolling at every step and layout.

## Not tested: needs a disposable VM (status: UNVERIFIED)

Use the Phase 4 and 4.2 checklists for the base deployment, then:

1. **Quick path:** generate with Quick Deployment (name, Gamer + Laptop, defaults) and install.
   - [ ] Setup shows no language/region/keyboard page (predefined region) and stops at disk selection.
2. **Ongoing update policy (Windows 11 Pro, Internet):**
   - [ ] While the update engine runs, `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU`
         has no `AUOptions`.
   - [ ] After `Updates\result.json` is final: `NoAutoUpdate=0`, `AUOptions=3`;
         `Updates\policy-result.json` says `Applied`; the report lists it.
   - [ ] Settings › Windows Update downloads updates and offers "Install now"; it says some settings
         are managed by your organization. Defender intelligence updates still arrive.
   - [ ] Windows 11 Home media: the report says `Unsupported`, nothing written.
3. **Wi-Fi (a VM with a USB Wi-Fi adapter, or a laptop):**
   - [ ] With a supported adapter: `Network\wifi-result.json` `Added`/`ConnectRequested`, the network
         is listed under Wi-Fi and connects; `C:\Windows\Setup\Scripts\Wifi.xml` is gone after the
         first sign-in; `wifi.log` contains no password.
   - [ ] Hidden network and WPA3 (if the adapter supports it).
   - [ ] A VM without Wi-Fi: `NoWirelessAdapter` after the first sign-in, follow-up in the report,
         the deployment otherwise normal.
4. **Laptop location:** with "Allow location services" the location policy is absent and the user can
   turn location on in Settings; the other privacy settings are unchanged.

Record the results in `docs/validation-log.md`.
