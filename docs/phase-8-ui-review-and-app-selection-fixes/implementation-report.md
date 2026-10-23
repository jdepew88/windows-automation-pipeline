# Quick Deployment application review and the Advanced selection fix

Branch `feature/phase-8-ui-review-and-app-selection-fixes`, from Phase 8 `1e82c86` (verified
locally and on GitHub). Not merged, not deployed. Phase 9 is not started. Nothing on this computer
was changed.

## Changes

1. **The Advanced catalog no longer jumps up when an app is ticked.**
   See [advanced-scroll-root-cause.md](advanced-scroll-root-cause.md).
2. **Final Review › Applications lists the selected applications.** The compact grid uses logos
   where they exist and gives the count. It splits the apps into "Installed automatically", "Manual
   follow-up" and (if any) "Cannot be installed".
3. **"View applications" on every computer type and saved profile in step 2.**
   - It opens a list of the profile's default applications in place.
   - Opening it never ticks or unticks the profile.
   - "View the combined selection" shows the whole deployment after every profile, device answer
     and individual change.

## One source of truth

`src/engine/applications/preview.ts` is read-only and has no selection logic of its own. It calls
`resolveSelection`, the same function that writes `applications-config.json`:

- **`effectiveApps`**:
  - "automatic" is `installable(r)` (= `applications-config.json` `packages`);
  - "manual" is `manualItems(r)` (= its `manual`);
  - "unresolved" lists what cannot be installed;
  - each app appears once, whichever profiles select it;
  - an app explicitly unticked, or left out by a saved profile, is never listed.
- **`profilePreview`**:
  - Resolves the profile on its own: its defaults, the profiles it includes (Network Engineer
    includes General Developer), a saved profile's device answers and exclusions, and dependencies.
  - Annotates each app with how it gets there: direct, "From General Developer", "Required by
    Docker Desktop", or "Also in Core Essentials".
  - Gives each app's status in this deployment, computed as if the profile were ticked:
    - **included:** already selected, possibly by another profile;
    - **wouldAdd:** ticking the profile adds it;
    - **excluded:** shown struck through with the reason. A remembered untick keeps the app out
      even if the profile is ticked again, so the preview never shows an excluded app as included.
  - Counts optional recommendations only as a number. The catalog is never listed.

Unit tests (`tests/unit/app-preview.test.ts`) check:

- the summary equals the generated configuration's `packages` and `manual`;
- an app shared by several profiles appears once;
- exclusions are respected;
- previews of selected, unselected and saved profiles are correct;
- previewing does not change the selection;
- a saved profile's "would add" apps are exactly what ticking it produces.

## Accessibility

- **Preview button:** a real button with `aria-expanded`, `aria-controls` and an accessible name
  (for example "View the applications of Gamer (2)").
- **Preview content:** each preview is a labelled `region`.
- **Kept focus:** focus stays on the button or checkbox you used, because elements are no longer
  replaced on re-render.
- **Narrow layouts:** the grid has 3 columns where there is room (container width ≥ 520 px), 2
  from 340 px, and 1 on narrow screens. Long names are truncated, with the full name and origin in
  the tooltip.

## Files

| Status | Files |
|---|---|
| Added | `src/engine/applications/preview.ts`, `src/ui/app-summary.ts`, `tests/unit/app-preview.test.ts`, `tests/e2e/app-review.spec.ts`, this folder |
| Changed | `src/ui/dom.ts` (`patchChildren`/`render`, listener registry in `h`), `src/ui/app-selection.ts` (patched re-render), `src/ui/wizard.ts` (previews, combined selection, Final Review summary, patched re-render), `src/ui/app-icon.ts` (remember failed logos), `src/styles.css` |

## Tests

See [the testing section of the root-cause note](advanced-scroll-root-cause.md#regression-tests)
for the scroll tests. `tests/e2e/app-review.spec.ts` (16 tests × desktop, tablet, Pixel 7) also
covers:

- **Preview behaviour:** open and close; previewing an unselected profile leaves it unselected;
  keyboard Enter/Space.
- **Several profiles:** switching between them, combining them with deduplication (Git once), and
  live updates when a profile is unticked.
- **Previews of saved profiles**, and an app unticked in Applications shown as left out in both the
  preview and Final Review.
- **Final Review accuracy:** exact counts and the automatic/manual split, compared with the
  generated ZIP's `applications-config.json`.
- **Shared state:** changes made in Advanced appear in Quick.
- **Edge cases:** an empty selection, and no horizontal scroll.

## Limitations

- The Final Review summary covers WinGet/Store applications and manual follow-ups. Additional
  Software installers (Advanced) are not listed in this grid.
- Previews show default applications; optional recommendations are given only as a count, by
  design. They are ticked in the Applications step.
- The fix was verified in Chromium, which is what the Playwright projects run. Firefox also
  implements scroll anchoring; Safari's support has varied. Keeping elements in place is correct
  for any browser, but neither Firefox nor Safari was tested.
