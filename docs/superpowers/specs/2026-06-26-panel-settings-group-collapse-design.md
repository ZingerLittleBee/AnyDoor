# Panel Settings: Group & Collapse Design

Date: 2026-06-26
Status: Approved
Scope: Settings window → "Panel" tab (`PanelSettingsView`) reorganization

## Problem

The Panel settings tab renders ~60 built-in items plus app shortcuts and window
layout children as a single flat list. It is hard to scan and navigate ("过余散乱").
We want to organize it into collapsible, themed groups — reusing the same grouping
concept already shipped in the command palette ("themed sections").

## Goals

- Group the Panel settings list into themed, collapsible sections.
- Reuse the command palette's group taxonomy as the single source of truth.
- Preserve all existing capabilities: per-row visibility toggle, hotkey recording,
  drag-to-reorder, app-shortcut children + "add app" row, window-layout children,
  brightness recorder row, type badges, delete (app shortcuts only).
- Let the grouped view be "what you see is what you get": the menu-bar panel order
  reflects the grouped order without breaking existing data.

## Non-Goals

- The menu-bar panel (`MenuBarView`) is **not** redesigned. It shows no section
  headers and no collapse chrome. Only its item *order* changes (see Model B), as a
  natural consequence of the new sort key.
- Items cannot be moved between groups. Group membership is code-defined.
- The command palette's appearance is not changed in this work (it keeps its current
  4 themed sections + "Commands"). Only the *location* of the group definitions moves
  (extraction/refactor), behavior stays identical.

## Decisions (locked)

1. **Scope**: Settings page only. (The panel reflects new ordering but gains no
   header/collapse UI.)
2. **Reorder model**: within-group drag **and** group drag. Group membership is
   **code-defined** — no cross-group dragging.
3. **Taxonomy**: reuse the command palette's groups. The four themed sets
   (Toggles & Appearance / Power & Session / Screenshot / Translation) plus a
   catch-all "General". Anything not claimed by a themed set falls into General.
4. **Order model = Model B (WYSIWYG), no data migration**: the menu-bar panel and the
   settings page both sort `topLevelEntries` by `(groupOrderIndex, displayOrder)`.
   Existing `displayOrder` values remain valid as *within-group* order (they are still
   monotonic inside each group), so **no `displayOrder` rewrite / SwiftData migration
   is required**. Only the sort comparator changes, plus a new persisted group order.
5. **General group is headerless**: it is the fallback bucket, so it renders with **no
   section header**, is **not collapsible**, **not group-draggable**, and is **pinned
   first** (acts as the "main list"). Items inside General are still drag-reorderable
   among General members.
6. **Themed groups**: collapsible (default **expanded**, state remembered),
   group-draggable, show a **count badge**, header uses **uppercase small caps** to
   match the command palette section header.
7. **Parent-row child collapse**: parent rows that own children — `appShortcuts`
   (app children + "add app" row) and `windowLayout` (window children) — get their
   own disclosure chevron to collapse/expand their children, independent of the themed
   group collapse, because they can hold many rows. State is remembered.

## Group Taxonomy

Default group order (user-reorderable for themed groups; General stays first):

| Order | Group ID | Title (zh) | Members |
|------:|----------|-----------|---------|
| 0 | `general` | (no header) | everything not claimed below — `appShortcuts`(+children), `clipboardWall`, `clipboardMonitoring`, `clearClipboard`, `ocr`, `pickColor`, `qrcode`, `windowLayout`(+children), `hostsManager`, `portManager`, `bluetoothBattery`, `emptyTrash`, `restartFinder`, `restartDock`, `restartMenuBar`, `flushDNS` |
| 1 | `togglesAppearance` | 开关与外观 | `keepAwake`*, `muteAudio`, `microphoneMute`, `darkMode`, `hideDock`, `autoHideMenuBar`, `hideDesktopIcons`, `showHiddenFiles`, `keyboardLock`, `brightness`(+recorder row) |
| 2 | `powerSession` | 电源与会话 | `lockScreen`, `displaySleep`, `systemSleep`, `scheduledShutdown`, `keepAwake`* |
| 3 | `screenshot` | 截图 | `screenshot`, `captureWindow`, `captureFullscreen`, `captureTimer`, `captureModeBar`, `recordScreen`, `captureScrolling` |
| 4 | `translation` | 翻译 | `translate`, `screenshotTranslate`, `translateSelection` |

\* `keepAwake` is in the command palette's `powerItems` set. The membership tables in
this spec mirror the command palette sets exactly; the extraction (below) makes them
the single source of truth, so any single-membership questions are resolved by the
existing command palette definitions, not re-decided here.

The hidden-hotkey items `brightnessUp` / `brightnessDown` are not standalone rows; they
live on the brightness recorder sub-row (unchanged behavior).

> Note (acknowledged trade-off): the General bucket is sizable (~16 entries). This is
> intentional to stay faithful to "group like the command palette". If General later
> feels too dense, the shared taxonomy can be extended with more themed sets — which
> would enrich the command palette too. Out of scope for this change.

## Architecture

### 1. Shared group catalog (single source of truth)

Extract the four `Set<BuiltinItem>` definitions and their `L10n.Key` section titles
that currently live in `CommandPaletteWindowController` into a shared type (working
name `BuiltinGroup`). Provide:

- `BuiltinGroup` cases: `.general`, `.togglesAppearance`, `.powerSession`,
  `.screenshot`, `.translation` (mirrors the command palette sets + general).
- `members: Set<BuiltinItem>` per themed group; `.general` is "the rest".
- `static func group(for: BuiltinItem) -> BuiltinGroup` — total function over all
  cases (every `BuiltinItem` maps to exactly one group).
- `titleKey: L10n.Key?` — `nil` for `.general` (headerless), the existing command
  palette section keys for themed groups.
- `defaultOrderIndex` — default ordering matching the command palette section order.

`CommandPaletteWindowController` is refactored to consume `BuiltinGroup` instead of its
private static sets. Its on-screen behavior must stay byte-for-byte identical (same
sections, same order, same titles). This is the only command-palette-touching change
and it is a pure refactor.

### 2. Persistence (UserDefaults — no SwiftData schema change)

- `panel.groupOrder`: `[String]` of themed group IDs in display order. Default = command
  palette order. `general` is implicit and always first (not stored / not reorderable).
- `panel.collapsedGroups`: `[String]` of collapsed themed group IDs. Default empty =
  all expanded.
- `panel.collapsedParents`: `[String]` of collapsed parent-row ids (`appShortcuts`,
  `windowLayout`). Default empty = expanded.

Wrap these behind a small `PanelGroupingStore` (`@MainActor`, `@Observable` or plain)
so the view observes changes and the keys are centralized.

### 3. `PanelStore` changes

- `rebuild()`: sort `topLevelEntries` by `(BuiltinGroup.orderIndex(for: item),
  displayOrder)` instead of `displayOrder` alone. This makes both `MenuBarView` and the
  settings page render group-contiguous order (Model B) with no stored-data migration.
  App-shortcut entries that live under `appShortcuts` and window children under
  `windowLayout` keep their existing partitioning; only the top-level ordering key
  changes.
- `reorderTopLevel(within group: BuiltinGroup, by items: [BuiltinItem])`: reassign
  `displayOrder` (stride 100) **only** among that group's items. Cross-group order is
  unaffected because `orderIndex` dominates the sort. Saves SwiftData, `rebuild()`, and
  `rebuildHotkeySnapshots()` per existing PanelStore contract.
- `reorderGroups(by ids: [String])`: persist `panel.groupOrder`, then `rebuild()`. No
  hotkey snapshot rebuild needed (ordering does not change bindings).
- The existing `reorderAppShortcuts` / `reorderWindowChildren` are unchanged.

All writes continue to flow through `PanelStore` mutation methods (no direct
`modelContext.save()` in views), per the project's PanelStore-is-single-source rule.

### 4. Settings UI (`PanelSettingsView`)

Render order:

1. **General block** (headerless, pinned first): its top-level entries as rows. The
   `appShortcuts` and `windowLayout` parent rows show a disclosure chevron that
   collapses their children (children + "add app" row for app shortcuts; window children
   for window layout). Child rows keep their own `appChild` / `windowChild` drag groups.
2. **Themed sections** in `panel.groupOrder`: each with a header
   (`⠿` drag handle + chevron + uppercase title + count badge) and, when expanded, its
   rows. The brightness recorder sub-row stays under the brightness row in
   `togglesAppearance`.

Drag groups (extends `PanelDragGroup`):

- `.topLevel` is refined to be **group-scoped**: a row can only be reordered among
  siblings in the same `BuiltinGroup` (General members among themselves; each themed
  group among its own members). Dropping outside the source group is rejected.
- New `.groupHeader` drag group: reorder themed section headers → `reorderGroups`.
- `.appChild`, `.windowChild`, `.fixed` unchanged.

Collapse interactions:

- Themed header chevron toggles `panel.collapsedGroups`.
- Parent-row chevron toggles `panel.collapsedParents`.
- Collapsed themed group shows only its header row (drag handle, chevron, title, count).

### 5. Localization

- New header strings (zh / en / system) for themed group titles reuse the existing
  command palette section L10n keys (`commandPalette.section.*`) where the wording fits,
  or add `panel.section.*` keys if the Panel tab needs distinct copy. Prefer reuse to
  avoid duplication; add new keys only where copy must differ. All UI copy stays Chinese;
  comments/keys English.

## Data Flow

```
BuiltinItem catalog ─┐
BuiltinPreference ───┼─► PanelStore.rebuild()
KeyBinding ──────────┘        │  sort by (BuiltinGroup.orderIndex, displayOrder)
                              ▼
                     topLevelEntries (group-contiguous)
                       │                         │
                       ▼                         ▼
                 MenuBarView            PanelSettingsView
                 (flat, no chrome)      (grouped sections + collapse)
                                              │ drag / collapse
                                              ▼
                          PanelStore.reorderTopLevel(within:) / reorderGroups()
                          PanelGroupingStore (UserDefaults: order + collapse)
```

## Error Handling / Edge Cases

- Empty themed group (all members hidden or none present): hide the section entirely
  (do not render an empty header), matching command palette behavior.
- A `panel.groupOrder` array that is missing newly-added group IDs or contains stale
  IDs: reconcile on read — append missing themed groups in default order, drop unknown
  IDs. Never crash on malformed defaults.
- General is never collapsible and never appears in `panel.groupOrder`.
- Within-group reorder must not collide displayOrder across groups in a way that breaks
  the sort — it cannot, because `orderIndex` is the primary key; document this in the
  reorder method.

## Testing

- `BuiltinGroup.group(for:)` is total: a test iterates `BuiltinItem.allCases` and
  asserts each maps to exactly one group; themed sets are disjoint; General = the rest.
- `BuiltinGroup` members exactly equal the command palette's previous private sets
  (regression guard so the palette is unchanged).
- `PanelGroupingStore`: default order = palette order; reorder persists; collapse
  toggle persists; malformed/missing/stale `groupOrder` reconciles.
- `PanelStore` sort: produces group-contiguous `topLevelEntries`; within-group reorder
  changes only that group's `displayOrder` and leaves other groups' relative order
  intact; `reorderGroups` changes section order without touching `displayOrder`.

## Rollout

No migration step. On first launch after the change, defaults populate
(`groupOrder` = palette order, nothing collapsed), and the new sort key reorganizes the
existing panel into group-contiguous blocks using current `displayOrder` values.
