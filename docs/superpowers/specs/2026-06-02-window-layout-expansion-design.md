# Window Layout Expansion — Design

Date: 2026-06-02

## Problem

The window-layout submenu currently offers four actions: `leftHalf`,
`rightHalf`, `maximize`, `center`. Competing tools (Rectangle, Magnet) ship a
much wider tiling vocabulary — top/bottom halves, quarter corners, thirds and
two-thirds columns, and multi-display movement. AnyDoor already has the AX
write pipeline (`WindowLayoutService`), the pure-geometry layer
(`WindowLayoutGeometry`), and the submenu plumbing (`PanelStore`
`windowLayoutChildren`) in place; the missing piece is the action vocabulary
itself.

## Goal

Add 13 new window-layout actions as discrete, individually hotkey-bindable
`BuiltinItem`s inside the existing Window Layout submenu:

| Group | Actions | Geometry |
| --- | --- | --- |
| Half completion | `topHalf`, `bottomHalf` | pure rect |
| Quarters | `topLeftQuarter`, `topRightQuarter`, `bottomLeftQuarter`, `bottomRightQuarter` | pure rect |
| Thirds | `leftThird`, `centerThird`, `rightThird` | pure rect |
| Two-thirds | `leftTwoThirds`, `rightTwoThirds` | pure rect |
| Cross-display | `moveToNextDisplay`, `moveToPreviousDisplay` | proportional remap |

Together with the existing four this brings the submenu to 17 actions.

## Non-goals

- Restore-previous-size / undo. (Requires per-window state tracking.)
- Rectangle-style cycle behavior (repeat a hotkey to cycle sizes).
- Custom grid / drag-snap / window stash.
- Changing how the submenu renders, how hotkeys are recorded, or how
  visibility/order are edited — all existing mechanisms are reused unchanged.

## Design

The change threads one new action vocabulary through the existing pipeline.
No new architectural layers are introduced. Each numbered unit below has a
single responsibility and a stable interface to the next.

### 1. `WindowLayoutAction` (Services/WindowLayoutService.swift)

Add the 13 new cases to the enum. Add one computed property to let the service
branch between the two geometry strategies:

```swift
var movesDisplay: Bool {
    switch self {
    case .moveToNextDisplay, .moveToPreviousDisplay: return true
    default: return false
    }
}
```

Add a `symbol` for each new case (used only if the action surfaces an SF
Symbol directly; `BuiltinItem.symbol` is the panel source of truth — keep the
two in sync). Update the doc comment that currently says thirds/multi-display
are "intentionally out of scope".

### 2. `WindowLayoutGeometry` (pure, unit-tested)

**Pure-rect cases** — extend `targetRect(action:windowFrame:visibleFrame:)`
with explicit cases. Use the same `floor()`-to-avoid-overlap discipline the
existing halves use, applied to both axes:

- `topHalf` / `bottomHalf`: full width, `floor(height/2)`, anchored top/bottom.
- Quarters: `floor(width/2)` × `floor(height/2)`, anchored to the named corner.
  The right column starts at `maxX - floor(width/2)`; the bottom row starts at
  `maxY - floor(height/2)` (mirrors the existing rightHalf maxX trick so the
  two halves meet without a gap or overlap).
- Thirds: column width `floor(width/3)`. Left starts at `minX`; right ends at
  `maxX`; center is the remaining middle band (`minX + leftWidth` to
  `maxX - rightWidth`) so the three columns tile the full width exactly with no
  cumulative rounding gap.
- Two-thirds: `leftTwoThirds` = left edge to `minX + floor(width*2/3)`;
  `rightTwoThirds` = `maxX - floor(width*2/3)` to right edge. Full height.

The `movesDisplay` cases are **not** handled here — `targetRect` keeps its
single-screen signature. Add a precondition comment that callers must route
display-moving actions through `rectMovingToDisplay` instead. (A
`movesDisplay` action reaching `targetRect` is a programming error; the
`switch` will need a case — return `visibleFrame` as a harmless fallback and
document that the service never calls it on this path.)

**Cross-display remap** — new pure function:

```swift
static func rectMovingToDisplay(
    windowFrame: CGRect,    // AX coords, on the source display
    fromVisible: CGRect,    // source display visibleFrame, AX coords
    toVisible: CGRect       // destination display visibleFrame, AX coords
) -> CGRect
```

Algorithm (Rectangle-default proportional remap):

1. Compute the window's normalized position/size within `fromVisible`:
   `fx = (windowFrame.minX - fromVisible.minX) / fromVisible.width`, likewise
   `fy`, and normalized size `fw = windowFrame.width / fromVisible.width`,
   `fh = windowFrame.height / fromVisible.height`.
2. Project onto `toVisible`: `x = toVisible.minX + fx * toVisible.width`, etc.;
   `width = fw * toVisible.width`, `height = fh * toVisible.height`.
3. Clamp the result inside `toVisible`: size capped to `toVisible` dimensions,
   then origin shifted so the rect stays fully within `toVisible`.
4. Guard `fromVisible.width/height > 0` to avoid division by zero (degenerate
   screens fall back to placing the window at `toVisible.origin` with its
   original, clamped size).

### 3. `WindowLayoutService.apply(_:)` (AX bridge, @MainActor)

Branch on `action.movesDisplay` after the existing permission / frontmost /
focused-window / not-full-screen guards (those apply to both paths):

- **Single-screen path** (unchanged): `targetRect` → write position → size.
- **Cross-display path**:
  1. Read current window frame (existing `readFrame`).
  2. Determine the **source** screen via the existing largest-overlap logic.
     Factor the screen-picking out of `visibleFrameInAXCoords` into a helper
     `sourceScreen(containing:) -> NSScreen` so both paths share it.
  3. Build the ordered screen list: all `NSScreen.screens` sorted by
     `visibleFrame.minX`, ties broken by `visibleFrame.minY` (left-to-right,
     then top-to-bottom). Convert each to AX coords as needed.
  4. If `screens.count < 2`, throw `WindowLayoutError.singleDisplay`.
  5. Find the source screen's index in the ordered list; destination =
     `(index ± 1) mod count` (wrap-around; `+1` for next, `-1` for previous).
  6. `rectMovingToDisplay(windowFrame:fromVisible:toVisible:)` with both
     visibleFrames in AX coords → write position → size.

Add `case singleDisplay` to `WindowLayoutError`.

### 4. `WindowLayoutProvider` (unchanged behavior, one new message)

No structural change — still one provider instance per action. Map the new
`WindowLayoutError.singleDisplay` to a localized toast in `message(for:)`
(e.g. `toastWindowLayoutSingleDisplay`, zh "只有一个显示器" / en "Only one
display"). All other errors reuse existing toast strings.

### 5. `BuiltinItem` (Models/BuiltinItem.swift)

Add the 13 cases. For each, extend every `switch` that is exhaustive over the
enum:

- `kind` → `.action`.
- `symbol` → SF Symbol per action (final names verified against the SF Symbols
  app at implementation time; fall back to a generic `macwindow` if a chosen
  name is unavailable on macOS 14). Candidate symbols:
  - `topHalf` `rectangle.tophalf.filled`, `bottomHalf`
    `rectangle.bottomhalf.filled`
  - quarters `rectangle.inset.topleft.filled` / `.topright` / `.bottomleft` /
    `.bottomright` (verify; else `square.split.2x2`)
  - thirds `rectangle.leftthird.inset.filled` / `rectangle.center.inset.filled`
    / `rectangle.rightthird.inset.filled` (verify; else `rectangle.split.3x1`)
  - two-thirds `rectangle.lefthalf.inset.filled` /
    `rectangle.righthalf.inset.filled` (verify)
  - cross-display `rectangle.on.rectangle` (next) / `rectangle.on.rectangle`
    with distinct localized label (prev), or `arrow.right`/`arrow.left`
    variants.
- `localizationKey` → new `L10n` keys (section 7).
- `defaultOrder` → spaced in-popover ordering (section 6).
- `defaultVisibility` → `true` (see section 6).
- Any other exhaustive switch (e.g. history-kind classification) gets the
  non-history branch, matching the existing window cases.

### 6. Visibility & ordering

New items are **visible in the submenu by default** (parity with the existing
four; the submenu is itself opt-in via hover, so 17 scrollable rows is
acceptable). No default hotkeys.

`defaultOrder` (in-popover sort; existing four are 2010–2040):

| Action | order | | Action | order |
| --- | --- | --- | --- | --- |
| windowLeftHalf | 2010 | | leftThird | 2110 |
| windowRightHalf | 2020 | | centerThird | 2120 |
| topHalf | 2030 | | rightThird | 2130 |
| bottomHalf | 2040 | | leftTwoThirds | 2140 |
| topLeftQuarter | 2050 | | rightTwoThirds | 2150 |
| topRightQuarter | 2060 | | windowMaximize | 2160 |
| bottomLeftQuarter | 2070 | | windowCenter | 2170 |
| bottomRightQuarter | 2080 | | moveToNextDisplay | 2180 |
|  |  | | moveToPreviousDisplay | 2190 |

Note this reorders `windowMaximize`/`windowCenter` after the new tiling
actions. The existing one-shot `applyWindowLayoutBackfillIfNeeded` flag
(`windowLayoutDefaultsApplied_v1`) already pinned the old four to 2010–2040 for
upgrading users. To re-pin all 17 to the table above, add a **new** one-shot
backfill keyed `windowLayoutDefaultsApplied_v2` that rewrites every window
child's `displayOrder` to its table value. Fresh installs get the values via
`defaultOrder` directly (the seeder uses `defaultOrder` only when the prefs
table is empty); the v2 backfill covers existing installs whose four rows were
seeded before the new items existed. The new 13 items themselves arrive through
the seeder's "append new items at maxOrder+100" path on upgrade, then get
corrected to their table slots by the v2 backfill.

### 7. Localization (`L10n` + `LocalizationManager` tables)

Add a `builtin.*` key + zh/en strings for each new action. Proposed Chinese
labels: 上半屏 / 下半屏 / 左上角 / 右上角 / 左下角 / 右下角 / 左三分之一 /
中三分之一 / 右三分之一 / 左三分之二 / 右三分之二 / 移到下一显示器 /
移到上一显示器. Add `toastWindowLayoutSingleDisplay`. The existing
`LocalizationCoverageTests` / `BuiltinItemLocalizationTests` enforce that every
`BuiltinItem` has a key in every language — they will fail until all strings
are added, which is the intended guard.

### 8. Provider registration (AppDelegate)

Append 13 `WindowLayoutProvider(item:action:)` rows to the provider registry
list, alongside the existing four.

### 9. `PanelStore.windowLayoutChildKeys`

Add the 13 new `BuiltinItem`s to the set so they partition into
`windowLayoutChildren` (submenu) rather than `topLevelEntries`. Reordering /
visibility / hotkey-snapshot rebuild all flow through existing code unchanged.

## Testing

- **`WindowLayoutGeometryTests`** (extend): one assertion per new pure-rect
  case against the existing `visible = (0,25,1440,875)` fixture — verifying
  exact frames and the tile-completeness invariants (left+right thirds + center
  exactly cover the width; quarters meet with no gap/overlap; top+bottom halves
  cover the height).
- **`rectMovingToDisplay`** (new tests): same-size displays (identity-ish
  remap), different-resolution displays (proportional scaling), oversized
  window clamped into destination, and the zero-dimension guard.
- **`BuiltinItemLocalizationTests` / `LocalizationCoverageTests`**: pass once
  all new keys exist (no new test code needed — they iterate `allCases`).
- **Seeder backfill** (`WindowLayoutSeederBackfillTests`, extend): assert the
  v2 backfill rewrites all 17 window children to their table `displayOrder` and
  is one-shot (idempotent on a second run).
- AX-bridge cross-display path is exercised manually (consistent with the
  existing "AX bridge requires real windows" testing note); the pure remap math
  it depends on is fully covered above.

## Risks / notes

- **SF Symbol availability on macOS 14.** Corner/third inset symbols vary by
  OS version. Verify each at implementation time; fall back to a generic
  `macwindow` rather than shipping a broken (empty) glyph.
- **Thirds rounding.** Width not divisible by 3 must still tile exactly —
  the center-band-is-remainder approach (rather than three independent
  `floor(width/3)` columns) guarantees this; the test enforces it.
- **Display ordering stability.** `visibleFrame.minX` ordering matches user
  spatial intuition; using `NSScreen.screens` array order instead would be
  unpredictable across reconnects. Wrap-around keeps next/previous always
  actionable with 2+ displays.
- **Coordinate space.** All geometry stays in AX coords (top-left origin);
  cross-display remap operates entirely on already-converted AX rects, so the
  existing `toAXCoords` conversion is the only bridge — no new coordinate
  handling.
