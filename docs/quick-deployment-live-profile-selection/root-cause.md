# Quick Deployment: unticking a profile left its applications selected

Branch `fix/quick-deployment-live-profile-selection`, from `main` `15fc2d5`. Not merged, not
deployed.

## Symptom

In Quick Deployment, ticking a computer type added its applications, but unticking it did not
reliably remove them: the count and the installation list kept applications of profiles that were
no longer selected.

## Reproduction (before the fix)

1. Step 2: tick **Developer** (Core Essentials + General Developer).
2. Step 4, Applications: tick **Docker Desktop** and **Wireshark**, two of Developer's
   recommendations. Docker Desktop brings **Windows Subsystem for Linux** as a dependency.
3. Back to step 2: untick **Developer**.

Git, VS Code, Python and Node.js leave, but Docker Desktop, WSL and Wireshark stay, labelled "Added
by you". They stay in Final Review and in the generated `applications-config.json`,
`winget-packages.json` and plan. Unticking a profile without any ticked recommendation worked: the
problem was the applications the user had ticked while the profile was active.

## Root cause

The selection is already derived, not stored as a list: `resolveSelection` computes it from the
ticked profiles, the device answers, the individual additions (`added`) and the removals
(`removed`), and the package, Final Review and every count use it.

The fault was in what `added` meant:

- Ticking any app that no active profile selects stored it in `added`, including a recommendation
  shown under the profile that offered it.
- `added` is, by design, the user's own additions, which survive profile changes.
- So a recommendation ticked "for Developer" became indistinguishable from an app the user added
  themselves, and unticking Developer could not tell that it belonged to it.

Step 2 also had no per-application control: the only way to drop one app was the Applications step.

## Fix

### Selection state

One new optional field, `addedWith` (package key → profile ids). Everything else is unchanged, and
there is still one derived selection:

- **Ticking an app (`addPackage`):** if an active profile recommends it, the addition is linked to
  the profiles that recommend it, including inherited ones (Network Engineer → General Developer)
  and device profiles. Any other app (found by search, or added by identifier) is the user's own
  addition, with no link, as before.
- **Resolution (`resolveSelection` → `attachedAdditions`):** a linked addition counts only while at
  least one of its profiles is active.
- **Cleanup (`pruneDetached`):** when a profile is unticked or deleted, or a device answer changes,
  additions whose profiles are all inactive are removed from `added`. Re-ticking the profile offers
  them again, unticked.
- **Saving a profile:** a saved profile absorbs the additions as before, and the links are cleared.
  Unticking, removing, "Restore defaults" and "Undo my changes" also clear the link.
- **Unchanged:** removals (`removed`) are still remembered, so an app you unticked stays unticked
  when a profile that selects it is ticked again. Step 2 shows it unticked, "Unticked by you", so
  it can be ticked again there.
- **Compatibility:** profiles without `addedWith` (all existing exports) import unchanged, and
  their additions behave as the user's own.

### Step 2

"Applications in this deployment" is now listed directly under the profile choices:

- Every selected app has a checkbox. Apps an active profile selects but this deployment leaves out
  are listed unticked, struck through.
- Each app is listed once with its origin: the profiles that select it, "Required by Docker
  Desktop", "Recommended by General Developer, ticked by you", or "Added by you".
- **Unticking an app:** the same removal as in Applications; the profile stays ticked.
- **Ticking it again:** restores it.
- **Count and headline:** they update on every change.
- **Order:** rows are sorted by name, so ticking never moves a row, and focus stays on the
  checkbox.
- **Dependency and antivirus warnings** are shown under the list. Additional Software installers
  are listed without a checkbox; they are changed in Advanced.

This replaces the "View the combined selection" toggle. The per-profile "View applications"
previews are unchanged.

### Files

| File | Change |
|---|---|
| `src/engine/schema/applications.ts` | Optional `addedWith` on the selection |
| `src/engine/applications/selection.ts` | `activeClosure`, `attachedAdditions`; the resolver ignores detached additions |
| `src/engine/applications/profiles.ts` | Linking in `addPackage`; `pruneDetached` in `toggleProfile` and `deleteProfile`; links cleared by remove/restore/reset/save |
| `src/engine/applications/preview.ts` | `deploymentChecklist` (read-only, from `resolveSelection`); origin text for linked additions |
| `src/ui/wizard.ts` | Step 2 checklist; pruning on device changes |
| `src/ui/app-selection.ts` | Pruning on device changes; origin text |
| `src/styles.css` | Checklist styles (3, 2 or 1 columns by width) |

## Tests

- **`tests/unit/live-profile-selection.test.ts`** (13 tests):
  - adding and removing profiles;
  - shared apps;
  - exclusions and restoring;
  - own additions surviving unrelated changes;
  - linked recommendations, including shared, inherited and device ones;
  - repeated toggling returning to the same state;
  - the checklist equal to the plan;
  - `applications-config.json`, `winget-packages.json` and the plan equal to the ticked apps;
  - saved profiles, and deployment-profile export and import with and without the field.
- **`tests/unit/app-profiles.test.ts`:** one existing test asserted the old behaviour (a ticked
  Gaming recommendation surviving untick and re-tick of Gaming). It now asserts the new rule, and
  that an own addition (GIMP) survives.
- **`tests/e2e/live-profile-selection.spec.ts`** (8 tests × desktop, tablet, Pixel 7):
  - live counts;
  - Core + Developer, and unticking Developer;
  - shared apps with Network Engineer;
  - unticking and re-ticking one app;
  - the reproduction above;
  - repeated toggling;
  - navigation, Final Review and the downloaded ZIP equal to step 2;
  - saved profiles;
  - the keyboard.
- **`tests/e2e/app-review.spec.ts`:** the two tests that opened the removed toggle now read the
  checklist.
- **Check that the tests catch the bug:** with the link check and the pruning disabled, 5 unit
  tests and the reproduction browser test fail; with the fix they pass.
