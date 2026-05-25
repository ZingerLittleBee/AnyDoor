# Window Layout Submenu — Design

Date: 2026-05-25

## Problem

The menu bar panel currently lists four window-layout actions as separate
top-level rows: `windowLeftHalf`, `windowRightHalf`, `windowMaximize`,
`windowCenter`. They occupy four consecutive slots and visually compete with
unrelated toggles/actions, which makes the panel feel cluttered.

## Goal

Collapse the four window-layout actions into one top-level submenu entry whose
hover popover reveals the four children. Individual hotkeys continue to fire as
they do today.

## Non-goals

- Adding new window-layout actions (e.g. top half, quarter tiling).
- Showing a chord/keyboard navigation overlay when the popover opens.
- Allowing the user to hide individual window-layout children from the popover.

## Design

### Data model

Add one new case to `BuiltinItem`:

- `case windowLayout` — `kind = .submenu`, symbol `macwindow`,
  `defaultOrder = 2000`, title key `builtinWindowLayout` (zh "窗口布局" / en
  "Window Layout").

The existing four cases (`windowLeftHalf`, `windowRightHalf`,
`windowMaximize`, `windowCenter`) stay in the enum. Their `kind`, hotkey
support, and `BuiltinPreference` rows are unchanged. What changes is where
`PanelStore` places them in the rebuilt view tree.

`defaultOrder` for the four children is repurposed to control their order
*inside the popover*, not the top-level list:

- `windowLeftHalf` → 100
- `windowRightHalf` → 200
- `windowMaximize` → 300
- `windowCenter` → 400

(Existing `BuiltinPreference.displayOrder` values seeded prior to this change
will be overwritten by the seeder's "ensure defaults" pass; see Migration.)

### PanelStore

- Add `private(set) var windowLayoutChildren: [PanelEntry] = []` alongside
  `appShortcutChildren`.
- In `rebuildEntries()`:
  - Filter the four window cases out of `topLevelEntries`.
  - Build `windowLayoutChildren` from the four window cases, sorted by their
    `BuiltinPreference.displayOrder`. Each entry's `kind` stays `.action`.
  - Force `isVisible = true` for window children regardless of the stored
    preference (since per-child visibility is not user-facing). The stored
    preference value is left untouched — we simply override at read time.
- Add `func reorderWindowChildren(newOrder: [BuiltinItem])`:
  - Validates that `newOrder` is a permutation of the four window cases.
  - Rewrites `BuiltinPreference.displayOrder` for each, save, rebuild, and
    `rebuildHotkeySnapshots()`.

`rebuildHotkeySnapshots()` already iterates over all `BuiltinPreference`
records, so child hotkeys keep working even when the parent row is hidden.

### MenuBarView (hover popover)

- Extend `HoverPopoverTarget.submenu` to recognize `.windowLayout` in
  `mountPopoverContent(for:)`.
- New view `WindowLayoutPopoverView`:
  - Reads `panel.windowLayoutChildren` from the injected `PanelStore`.
  - Renders rows via the existing `PanelRowView` with the action handler
    wired to `panel.dispatch(.builtin(item))`.
  - No "Add" button (children are fixed).
  - No drag-to-reorder inside the popover; reordering lives in Settings.

### PanelSettingsView

- In `row(for:)`, add an inline-expansion branch:
  ```
  if case .builtin(.windowLayout) = entry.source {
      windowLayoutChildren()
  }
  ```
- `windowLayoutChildren()` renders four child rows under the parent row,
  indented to match the existing `appShortcutChildren()` styling:
  - Drag handle (`line.3.horizontal`) supporting reorder of the four items.
  - SF Symbol + localized title.
  - `HotkeyRecorder` bound to `PanelStore.hotkeyForBuiltin(...)`, with the
    standard conflict-alert flow already used by other built-ins.
  - **No visibility toggle**.
- Drag uses SwiftUI's `.onMove` on a `ForEach` over
  `PanelStore.shared.windowLayoutChildren`, calling
  `PanelStore.shared.reorderWindowChildren(newOrder:)`.

### Seeder

`BuiltinPreferenceSeeder` already creates one `BuiltinPreference` per
`BuiltinItem.allCases`. With the new case it will:

- Seed `windowLayout` with `isVisible = true`, `displayOrder =
  windowLayout.defaultOrder`.
- For existing users, the four child cases already have stored preferences.
  Add a one-shot backfill in the seeder (gated on a `UserDefaults` flag
  `windowLayoutDefaultsApplied_v1`) that resets the four children's
  `displayOrder` to the new in-popover defaults (100/200/300/400).
- Run this backfill **before** rebuilding entries so the popover order is
  predictable on first launch.

### Localization

Add to `Localizable.xcstrings`:
- `builtin.windowLayout` → zh "窗口布局", en "Window Layout".

Add `case builtinWindowLayout = "builtin.windowLayout"` to `L10n.Key`.

### Hotkey behaviour

Unchanged. `HotkeyService` continues to dispatch per-child `HotkeyAction`s;
the parent row has no hotkey, no `HotkeySnapshot`.

## Architecture summary

```
topLevelEntries:  [..., windowLayout (.submenu), ...]
                                │ hover
                                ▼
                  WindowLayoutPopoverView
                  ├ windowLeftHalf    (.action)
                  ├ windowRightHalf   (.action)
                  ├ windowMaximize    (.action)
                  └ windowCenter      (.action)

PanelSettingsView (drag list)
├ ... (other top-level rows, draggable) ...
├ windowLayout (parent row, draggable)
│   ├ windowLeftHalf    [drag][SF][title]              [HotkeyRecorder]
│   ├ windowRightHalf   [drag][SF][title]              [HotkeyRecorder]
│   ├ windowMaximize    [drag][SF][title]              [HotkeyRecorder]
│   └ windowCenter      [drag][SF][title]              [HotkeyRecorder]
└ ...
```

## Migration

- SwiftData schema: no field changes; `BuiltinPreference` already supports
  arbitrary `BuiltinItem` raw values. No store migration needed.
- One-shot order backfill flag: `windowLayoutDefaultsApplied_v1` in
  `UserDefaults.standard`. After backfill, the flag is set and subsequent
  launches honor the user's reorder.

## Testing

- Build with `swift build` and run `swift run AnyDoor`; verify:
  - Panel shows a single "窗口布局" row with chevron, no top-level half/max/center.
  - Hovering the row opens a popover with the four items in the seeded order.
  - Clicking each item performs the layout action.
  - Pre-existing per-item hotkeys still fire (test at least one).
  - Settings → 面板 tab shows windowLayout with four expanded children;
    drag-reordering a child updates the popover order live.
  - Hiding the parent row's panel visibility hides the row in the menu bar,
    but child hotkeys still fire.
- Manual regression: confirm `appShortcuts` and `portManager` popovers still
  open as before (shared codepath).

## Open questions

None at design time. All decisions confirmed during brainstorming:
- Children keep individual hotkeys.
- Children are reorderable in Settings.
- Children are always visible when parent is visible (no per-child toggle).
- Parent row does not bind a hotkey (hover-only, like appShortcuts).
