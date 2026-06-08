# Command Palette Second-Level Menu — Design

Status: Draft (approved direction, pending spec review)
Date: 2026-06-08
Author: AnyDoor

## Overview

Today, selecting an "option-bearing" command in the command palette either acts
with a hard-coded default (Keep Awake / Scheduled Shutdown toggle on with their
default duration) or does nothing at all (`.submenu` / `.brightnessControl`
kinds fall through to `break` in `CommandPaletteWindowController.commit`). The
menu-bar panel exposes those options through a trailing-accessory menu (duration
presets) or a hover popover (brightness slider, hosts profiles), but the command
palette has no equivalent.

This feature adds a **second-level drill-down** to the command palette. Selecting
an option-bearing command pushes a second level that lists that command's
options (Raycast/Spotlight-style push navigation); selecting an option runs it
and closes the palette. The drill-down is keyboard-first, reuses the existing row
rendering and Liquid Glass surface, and keeps all business logic in the existing
services.

The design is a **generic framework**: a single `CommandPaletteOptions` builder
maps an option-bearing `BuiltinItem` to its option list, and the palette's
navigation/rendering is item-agnostic. Adding a new option-bearing command later
costs one builder branch.

## Goals

- Selecting an option-bearing command in the palette opens a second-level list
  of its options instead of acting with a default.
- Cover four option parents: **Keep Awake**, **Scheduled Shutdown**,
  **Brightness**, **Hosts**.
- Inline drill-down (push) navigation: a back header with the parent's name,
  `Esc` / empty-query `Backspace` / clicking the header returns to the root, and
  the second level is itself searchable.
- Reuse the existing presets/services so the palette and the panel never drift
  (`PanelStore.setKeepAwakeDuration` / `setScheduledShutdownDuration`,
  `DisplayBrightnessService.setBrightness`, `HostsManager.setActive`).
- Keyboard-first throughout (arrow keys + Return), with mouse parity (click to
  drill / commit / go back).
- Unit-testable option building and navigation state.

## Non-Goals (v1)

- Converting the already-flattened, directly-searchable commands (App Shortcuts,
  Window Layout, Ports) into drill-downs. They stay as flat sections — drill-down
  would *cost* searchability there, not add it.
- Per-display brightness selection (a "pick display → pick level" third level). A
  chosen brightness level applies to **all external DDC displays** at once.
- A continuous brightness slider inside the palette. Brightness is expressed as
  discrete steps (0 / 25 / 50 / 75 / 100 %).
- Deeper-than-two-level navigation (no third level for any item in v1).
- Creating / deleting / reordering hosts profiles from the palette (only toggling
  a profile active, plus an "Edit hosts…" entry that opens the editor window).

## Option Parents and Their Second-Level Content

An item is an **option parent** iff it is one of this fixed set. `collectSections`
adds Brightness (only when ≥1 external display exists) and Hosts into the
"Commands" section; Keep Awake and Scheduled Shutdown are already there as
`.toggle`-kind rows.

| Parent | Second-level options | Delegate |
|---|---|---|
| `keepAwake` | Indefinite · 15 / 30 / 60 / 120 min · (when on) **Turn Off** | `PanelStore.setKeepAwakeDuration(_:)` |
| `scheduledShutdown` | 15 / 30 / 60 / 120 min · (when armed) **Cancel** | `PanelStore.setScheduledShutdownDuration(_:)` |
| `brightness` | 0 / 25 / 50 / 75 / 100 % | `DisplayBrightnessService.setBrightness(_:for:)` applied to every external display |
| `hostsManager` | each profile (checkmark = `isActive`, selecting toggles) · **Edit hosts…** | `HostsManager.setActive(_:_:)` / open `HostsEditorWindowController` |

Notes:

- **Keep Awake / Scheduled Shutdown** mirror the panel's trailing menu exactly,
  including the conditional last entry (Turn Off only when on; Cancel only when
  armed). Timed presets carry no checkmark (the panel relies on the subtitle's
  live end-time, and the palette closes on commit anyway).
- **Brightness** appears in the palette only when `DisplayBrightnessService`
  reports ≥1 external display; otherwise the option list is `nil` and the
  command is omitted. Selecting a step applies it to all external displays via a
  `setBrightness` call per display.
- **Hosts** toggling a profile triggers a privileged `/etc/hosts` write; when the
  helper is not enabled this surfaces the existing AppleScript admin-password
  prompt and error toast — same path as toggling in the panel popover. The "Edit
  hosts…" entry closes the palette and opens the editor window. The second level
  is never empty (the Edit entry is always present), so an account with no
  profiles still drills in.

## Architecture

Five units, four of them edits to existing files plus one new file.

### `CommandPaletteOption` (new value type)

```swift
struct CommandPaletteOption: Identifiable {
    let id: String                         // stable, unique within a parent
    let title: String                      // already localized
    let subtitle: String?
    let symbol: String                     // SF Symbol
    let role: Role                         // .normal | .destructive
    let isChecked: Bool                    // trailing checkmark (hosts)
    let perform: @MainActor () async -> Void

    enum Role { case normal, destructive }
}
```

The `perform` closure keeps the option self-contained and keeps business logic
out of the view. Because it is not `Sendable`, options live only on the
MainActor (held by `CommandPaletteState`), never inside the value-typed
`PanelEntry`.

### `CommandPaletteOptions` (new, `@MainActor`)

```swift
enum CommandPaletteOptions {
    /// Options for an option-bearing builtin, or nil if the item has none
    /// (including brightness with no external display).
    static func options(for item: BuiltinItem) async -> [CommandPaletteOption]?
}
```

It reads current state from the shared services to compute checkmarks and
conditional entries, and each option's `perform` calls the matching existing
service method. This is the single source of truth for which commands are option
parents — `collectSections` and `commit` both consult it.

### `PanelEntry.Source` (edit) — `+ case paletteOption(id: String)`

`PanelEntry.Source` is the nested `Hashable` enum in `PanelEntry.swift`. The
second level reuses the existing list/row machinery by mapping each
`CommandPaletteOption` to a synthetic `PanelEntry` whose source carries only the
option `id` (a `String`), preserving the enum's `Hashable` value semantics (a
`String` payload stays trivially `Hashable`). The action is looked up by id at
commit time.

### `CommandPaletteState` (edit) — navigation stack

```swift
enum Level: Equatable { case root; case options(parentTitle: String) }

private(set) var level: Level = .root
private var optionsByID: [String: CommandPaletteOption] = [:]
private var optionEntries: [PanelEntry] = []

func enterOptions(parentTitle: String, _ options: [CommandPaletteOption])
func popToRoot()
func option(id: String) -> CommandPaletteOption?   // commit looks up the action
var isAtRoot: Bool { level == .root }
```

`filteredSections` / `flatEntries` become level-aware:

- `.root` → today's behavior (Commands / Window Layout / Applications + dynamic
  Ports / Calculator sections).
- `.options` → a single unnamed section of the option entries, filtered by
  `query`.

Entering or leaving a level resets `query` to empty and `selectedIndex` to 0.
The dynamic Ports/Calculator sections are suppressed while not at root.

### `CommandPalettePicker` (edit) — back header

When `!state.isAtRoot`, render a back bar above the search field: a "‹" affordance
plus the parent title, using the same adaptive surface as the section headers.
Clicking it (or the parent title) calls back into the controller to pop. The
search placeholder switches to a generic "filter options" string.

### `CommandPaletteRow` (edit) — option rendering

Add a `.paletteOption` branch: render the option's SF Symbol, optional subtitle,
a trailing checkmark when `isChecked`, and `.destructive` options in red. App
icon resolution is skipped (no `iconPath`).

### `CommandPaletteWindowController` (edit)

- `collectSections()`: after building the Commands list, append Brightness (when
  `CommandPaletteOptions.options(for: .brightness)` is non-nil) and Hosts as
  command rows.
- `commit(entry)`:
  - root + `.builtin(item)` that has options → `Task { let opts = await
    CommandPaletteOptions.options(for: item); if let opts { state.enterOptions(...) } }`
    and **do not close**. If `opts` is nil (shouldn't happen for a listed
    parent), fall back to today's toggle/run.
  - `.paletteOption(id)` → run `state.option(id)?.perform()`, then `close()`
    (and any service-owned toast fires as usual).
  - all other sources → unchanged.
- key monitor: `Esc` (53) → pop to root when not at root, else `cancel()`;
  `Backspace` (51) when `query` is empty and not at root → pop to root.

## Data Flow

```
root: select option parent (Return / click)
  → controller.commit → CommandPaletteOptions.options(for:)  (async)
  → state.enterOptions(parentTitle:, options)                (panel stays open)
  → picker re-renders with back header + option rows

options: select an option (Return / click)
  → controller.commit → option.perform()                    (delegates to service)
  → controller.close()

options: Esc / empty-query Backspace / click back header
  → state.popToRoot()                                        (query + selection reset)
```

## Error Handling

- Brightness with no external display → option list `nil` → command omitted from
  the palette; nothing to fail at commit.
- Hosts activation failure / authorization → handled by `HostsManager`'s existing
  `lastError` + toast + admin-password prompt; the palette only calls `setActive`
  and closes.
- A brightness `setBrightness` to a display lacking DDC → handled by the existing
  `DisplayBrightnessService` / controller retry; no extra handling.
- Async option building leaves the panel open until options arrive; a missing
  list (nil for a listed parent) falls back to the legacy toggle/run path so a
  selection is never silently dropped.

## Testing

XCTest, `@MainActor`, mirroring the existing palette/service tests.

- **`CommandPaletteOptions.options(for:)`** — for each parent and state, assert
  the option ids / titles / `isChecked` / conditional trailing entry:
  - Keep Awake off → no "Turn Off"; on → "Turn Off" present and `.destructive`.
  - Scheduled Shutdown not armed → no "Cancel"; armed → "Cancel" present.
  - Brightness: nil with zero injected displays; the five steps with displays
    injected via `injectDisplaysForTesting`.
  - Hosts: one option per profile with `isChecked == isActive`, plus the always-
    present "Edit hosts…" entry; works with zero profiles.
- **`CommandPaletteState` navigation** — `enterOptions` sets `.options` and the
  option entries; `popToRoot` restores `.root`; `query` and `selectedIndex` reset
  on each transition; `flatEntries` reflects the active level; second-level
  filtering matches by title.

## Localization

- Reuse existing keys: `keepAwakeDuration*`, `scheduledShutdownDuration*`,
  `keepAwakeDurationTurnOff`, `scheduledShutdownDurationCancel`,
  `keepAwakeDurationIndefinite`.
- New keys (en + zh-Hans): the back-header / option search placeholder, the
  brightness step labels (a "%" format reused for 0/25/50/75/100), and
  "Edit hosts…". Hosts profile rows use the profile's own `name` (not a catalog
  string).

## File-Level Summary

- New: `Sources/AnyDoor/Services/CommandPaletteOptions.swift` (+ the
  `CommandPaletteOption` value type, co-located).
- Edit: `Sources/AnyDoor/Models/PanelEntry.swift` (source case),
  `Sources/AnyDoor/Views/CommandPalettePicker.swift` (state + back header + row),
  `Sources/AnyDoor/Views/CommandPaletteWindowController.swift` (collect + commit
  + keys), `Sources/AnyDoor/Utilities/L10n.swift` +
  `Resources/Localizable.xcstrings` (new keys).
- New test: `Tests/AnyDoorTests/CommandPaletteOptionsTests.swift` (+ navigation
  cases, possibly a separate `CommandPaletteStateTests.swift`).
