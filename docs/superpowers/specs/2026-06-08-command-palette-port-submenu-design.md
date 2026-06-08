# Command Palette Port Manager Submenu — Design

**Goal:** Make Port Manager a first-class, browsable command in the command palette by drilling into a second-level list of listening ports, replacing the hidden numeric-only search path.

## Background

The command palette never showed a "Port Manager" row. Ports surfaced only through a hidden affordance: typing a numeric query (`3000` / `:3000`) built an ad-hoc "Ports" section listing matching listening processes, and Return killed the selected one. The `portManager` builtin (`kind == .submenu`) was filtered out of the Commands section entirely, so the feature was undiscoverable.

The recently shipped second-level menu (`CommandPaletteOptions` + `PanelEntry.Source.paletteOption(id:)` + `CommandPaletteState` root⇄options stack) gives us the right pattern: option-bearing builtins drill into a searchable second level instead of acting with a default.

## Decision

Port Manager becomes an **option parent**, consistent with Keep Awake / Scheduled Shutdown / Brightness / Hosts. Selecting it drills into a second level listing every listening TCP port; Return kills that port's process. The hidden root-level numeric search path is **removed** — the drill-in is the single, discoverable entry point. Its second-level search matches the port number (via the subtitle), so no capability is lost.

## Behavior

- A "端口管理" (Port Manager) row appears in the palette's Commands section, always listed (like Hosts).
- Selecting it refreshes `PortInventory` and drills into a second level: one row per listening port, sorted by port ascending (then process name, then pid).
  - Title: process name. Subtitle: `端口 :<port> · PID <pid>` (existing `commandPalette.port.subtitle`). Symbol: `xmark.circle.fill`.
  - Return runs `PortInventory.shared.kill(pid:)` and shows the existing kill toast (`CommandPalettePortKillToast`), then dismisses the palette.
- Second-level search filters by process name **or** subtitle, so typing a port number (e.g. `3000`) narrows the list.
- An empty port list still drills in and shows the standard empty state (rather than the palette silently closing).
- Esc / empty-query Backspace / the back header return to root, exactly as for the other option parents.

## Architecture

- `CommandPaletteOptions.isOptionParent` and `.shouldListInPalette` both return `true` for `.portManager`.
- `CommandPaletteOptions.options(for: .portManager)` awaits `PortInventory.shared.refresh()`, then returns `portOptions(records: PortInventory.shared.records)`.
- New pure builder `portOptions(records:) -> [CommandPaletteOption]`: sorts records and maps each to an option whose `perform` kills the pid and shows the toast. Pure over its input (testable without singletons), mirroring the other builders. Option id `port.<pid>.<port>` is unique because `PortRecord` identity is `(pid, port)`.
- `CommandPaletteState.filteredOptionEntries` matches `title` OR `subtitle`.
- `commit(_:)` drills into any non-nil options array (`if let options` instead of `if let options, !options.isEmpty`), so an empty port list shows the empty state instead of closing. Brightness (the only `nil` producer) is unaffected and is already gated out of the list when it has no options.

## Removals (dead after the change)

- Root numeric port search in `CommandPaletteState`: `portInventory`, `portRefreshTask`, `refreshPortsIfNeeded()`, `portSection(matching:)`, `portSearchNeedle(from:)`, `sortPorts`, `portEntry(for:)`, the port-section insertion in `filteredSections`, and the `refreshPortsIfNeeded()` call in the query `onChange`. The `portInventory:` init parameter is dropped.
- `PanelEntry.Source.portRecord` and every switch arm referencing it (`PanelEntry.id(for:)`, `localizedTitle()`, `CommandPalettePicker.iconPath`/`showsSubtitle`, `CommandPaletteWindowController` prewarm + `commit`, `PanelSettingsView`). The kill+toast logic moves into `portOptions`' `perform`.
- The now-unused `commandPalette.section.ports` localization key (`L10n.Key.commandPaletteSectionPorts` + its `.xcstrings` entry). `commandPalette.port.subtitle` stays — `portOptions` still uses it.

## Tests

- Update `CommandPaletteTests`: remove `testEmptyQueryDoesNotShowPortProcesses` and `testPortNumberQueryShowsMatchingPortProcess` (they exercise the removed path and the dropped `portInventory:` parameter). Keep both `CommandPalettePortKillToast` tests — that helper is still used.
- Extend `CommandPaletteOptionsTests`:
  - `isOptionParent(.portManager)` is true.
  - `portOptions(records:)` over two unsorted records yields options sorted by port, with the expected ids/titles/subtitles and `xmark.circle.fill` symbol.
  - `portOptions(records: [])` is empty.
  - Second-level subtitle search: `enterOptions` with port options, set query to a port number, assert only the matching option remains.

## Out of scope

- No change to the menu-bar Port Manager popover, `PortScanner`, or `PortInventory` internals beyond reading `records`.
- Placeholder text ("搜索命令、应用、端口") is left as-is: Port Manager is still reachable as a searchable command.
