# Advanced catalog: the page jumped up when some apps were ticked

## Symptom

In Advanced Configuration › WinGet applications, ticking an app near the top of the catalog behaved
normally, but ticking one further down moved the page up, sometimes by more than a screen. The tick
itself was applied. Every catalog layout was affected (logos, grid, compact, detailed).

## Reproduction (before the fix)

A Playwright script opened the catalog at 1440×900, chose "All apps", scrolled each of the 115 apps
into view and clicked it, comparing `window.scrollY` and the app's on-screen position before and
after:

| Layout | Apps whose click moved the page |
|---|---|
| Grid | 100 of 115 |
| Logos | 100 of 115 |
| Compact | 100 of 115 |
| Detailed | 108 of 115 |

Example (grid): GIMP sat at y = 470 in the viewport with `scrollY` 2183; after the click `scrollY` was
1518 and GIMP was at y = 1135, off screen. The apps that did not jump were the first few, while the
top edge of the list was still visible.

## What it was not

The handlers were instrumented for every `focus`, `scrollIntoView`, `scrollTo`/`scrollBy` call and
every layout read during the click; none of these caused it:

- There is no `<form>`, so nothing can submit; every button already had `type="button"`.
- There are no `href="#"` links in the catalog, and the hash did not change.
- There are no nested interactive elements: one checkbox per tile, inside its label.
- The focus restore already used `preventScroll: true`, and the page had moved before it ran.
- The catalog order does not depend on what is selected.

## Root cause

1. Every tick is a structural store update. The applications editor re-rendered by calling
   `clear(list)` and building every group header and tile from scratch, and did the same for the
   profile cards, filter chips and statistics.
2. Chrome's [scroll anchoring](https://developer.mozilla.org/docs/Web/CSS/overflow-anchor) keeps
   content steady by remembering an anchor node near the top of the viewport and correcting the
   scroll position when that node moves.
3. Once the list's top edge is scrolled off screen, the anchor is a tile or group header inside the
   list. The rebuild deletes it, and the browser's correction lands on the rebuilt list instead: the
   page jumps up.
4. Near the top of the catalog the anchor is a control above the list, which survives the rebuild,
   so nothing moves. That explains why it happened with "certain" apps only.

Evidence:

- With `overflow-anchor: none` on the page, no click moved it.
- Disabling anchoring on `.app-list *` alone also removed the jump.
- Disabling it on the side panel, the profiles or the toolbar did not.

## Fix

Re-rendering no longer replaces elements that are already on screen.

- **`patchChildren`** (`src/ui/dom.ts`) builds the new content detached, then updates the existing
  elements in place:
  - It matches them by key (`data-app`, `data-key`, …) or by position and tag.
  - It syncs attributes and the `checked`/`value` properties.
  - It swaps the listeners `h()` registered.
  - Only elements that really appear or disappear are inserted or removed.
- **Effect:** the anchor, focus and loaded logos survive a tick, and the browser keeps the clicked app
  where it was. When content above the list changes height (the statistics wrap to a second line),
  the browser now scrolls by exactly that amount and the app stays put.
- **Where it is used:**
  - the Advanced catalog, filter chips, layout switch, statistics, plan, profile cards and device
    answers;
  - the Quick Deployment computer-type step;
  - Final Review, whose acknowledgment checkboxes had the same problem.
- **Logos:** `appLogo` remembers logo files that failed to load, so a re-render does not request them
  again.

Selection logic, conflicts, dependencies, filters, search, layouts and keyboard behaviour are
unchanged; the same `resolveSelection` result is drawn.

## Regression tests

`tests/e2e/app-review.spec.ts`, describe "Advanced catalog keeps the scroll position", run at
desktop, tablet and mobile sizes:

- **All four layouts:** WhatsApp, GIMP, Notepad++ and VirtualBox (spread through the catalog; GIMP
  and WhatsApp jumped before the fix) are ticked and unticked after scrolling down. Each must keep
  its on-screen position (±1 px), keep focus, and leave the layout and filter unchanged.
- **Dependencies:** Docker Desktop is ticked, WSL joins as a dependency, then both are removed. The
  search and category are kept.
- **Keyboard:** Space ticks an app, focus stays, and Tab moves to the next app.
- **Conflicts:** the antivirus conflict still disables AVG while Avast is ticked.

As a check, `patchChildren` was temporarily reverted to clear-and-rebuild: all 7 of these desktop
tests then failed. With the fix they pass.
