# Phase 4.3 implementation report: Quick Deployment wizard, Advanced Configuration, catalog UX

Branch `feature/phase-4-3-quick-deployment-wizard`, based on Phase 4.2 (`06cfecf`, working tree
clean at the start). Not merged into `main`; not deployed to Cloudflare. No driver, PXE or Ventoy
media work. Nothing was installed, formatted or run as Windows Setup on the development computer.

## What was built

| Area | Files |
|---|---|
| Wizard model (customer types, identity mapping, step status and blocking, update selector, considerations, review summary) | `src/engine/quick.ts` |
| Wizard UI (five steps, top/bottom navigation, progress, Final Review, acknowledgements, ZIP) | `src/ui/wizard.ts` |
| Mode switch, single mounted editor, Advanced links, Wi-Fi consent on Advanced downloads, account-page pointer | `src/main.ts` |
| Catalog layouts and logos | `src/ui/catalog-view.ts`, `src/ui/app-icon.ts`, `src/ui/app-selection.ts` (factory, layouts, counters, "Selected by …", Profile defaults filter), `scripts/build-app-icons.mjs`, `public/app-icons/`, `src/data/apps/icons.json` |
| Considerations card in Advanced › Review | `src/ui/review.ts` |
| Ongoing update policy after the initial updates | `src/engine/deployment/scripts/Set-UpdatePolicy.ps1`, `Complete-Deployment.ps1`, `DeploymentOrchestrator.ps1`, `src/engine/deployment/index.ts`, `src/engine/windows-update/index.ts`, `src/features/updates/index.ts` |
| Wi-Fi provisioning | `src/features/wifi/Add-WifiProfile.ps1`, `src/features/wifi/index.ts` |
| Styles (wizard, two-column account layout, tiles, review, responsive, reduced motion) | `src/styles.css`, `src/ui/icons.ts` |
| Tests | `tests/unit/quick.test.ts`, `tests/e2e/quick.spec.ts`, `tests/powershell/Wifi.Tests.ps1`, `wifi-fixture.ts`, `make-wifi-fixture.ts`, new scenarios in `Deployment.Tests.ps1`; updates listed in [testing.md](testing.md) |
| Docs | this folder, `README.md`, `docs/architecture.md`, `docs/roadmap.md`, `docs/testing.md`, regenerated `docs/settings-mapping.md` and `docs/samples` |

## Windows configuration changes (runtime)

Only two runtime behaviours changed, both explicitly requested:

1. **Ongoing Windows Update policy.** With the initial update engine on and a notify policy, the
   answer file no longer writes `AUOptions` during specialize; the SYSTEM deployment monitor applies
   `NoAutoUpdate=0`, `AUOptions=3` (or 2) once the update stage is final, reads it back, refuses on
   Home and under domain/MDM/WSUS management or existing values, and records the outcome.
   Details: [windows-update.md](windows-update.md). The update engine itself is unchanged.
2. **Wi-Fi.** The inline `netsh` lines were replaced by `Add-WifiProfile.ps1`: adapter/driver check,
   a first-sign-in retry before `Wifi.xml` is deleted, a key-free result file and report entry,
   support for SSIDs with quotes and non-ASCII names, and 64-digit hex keys. Details: [wifi.md](wifi.md).

Everything else (orchestrator stages, application engine, staging, restarts, disk selection) is
unchanged. With both engines off the answer file is byte-identical to Phase 4.2.

Also changed (text only): the empty-name validation message ("Enter a name for the local account …")
and the automatic sign-in caveat (now a one-line pointer to Final Review).

## Known limitations

* **No VM or hardware validation** of anything in this phase: the policy timing and effect on a
  current Windows 11 Pro build, Wi-Fi with a real adapter, skipping Setup's regional pages.
* Wi-Fi is not retried after a Wi-Fi driver arrives later (Windows Update or vendor driver); the
  report asks for a manual connection. The password is plain text on the media by design of
  unattended Windows Setup.
* During the initial updates Windows' own automatic updating runs in its default mode (that is the
  price of applying the notify policy afterwards).
* "Allow location services" removes the blocking policy; it does not switch location on. The user
  does that in Settings (Windows requires consent), so the review says "Allowed".
* 50 of 115 apps have no logo (initials tile), including every Microsoft product.
* The wizard shows the account name as "Local account username"; the underlying setting remains the
  person's name from which username, display name and computer name are derived (Advanced offers a
  custom username).
* Acknowledgements last for the browser session only (by design, never stored).
* The main bundle exceeds Vite's 500 kB advisory size, as before Phase 4.3.

## Items deferred

Ventoy multi-image media, manufacturer drivers, PXE: out of scope as instructed. Committing UI
screenshots: the project has no convention for it; they were reviewed locally (see testing.md).

## Recommended next step

Run the VM checklist in [testing.md](testing.md) together with the Phase 4 and 4.2 checklists, then
move on to manufacturer drivers.
