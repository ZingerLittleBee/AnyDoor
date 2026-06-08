# Command Palette Port-Kill Confirmation — Design

**Goal:** Guard the command palette's port-kill actions behind a Raycast-style in-palette confirmation card, so a stray Return can't terminate a process by accident.

## Background

Two command-palette paths kill a listening process on commit, with no guard:
- **Root numeric search** — typing a port number surfaces a "Ports" section; Return on a row (`PanelEntry.Source.portRecord`) kills the process in `CommandPaletteWindowController.commit`.
- **Port Manager drill-in** — selecting a port option (`CommandPaletteOption` from `CommandPaletteOptions.portOptions`) runs its `perform`, which kills the process.

Both are one keystroke from an irreversible kill. The fix mirrors Raycast's `confirmAlert`: an in-window confirmation card (not a system `NSAlert`, which would steal key focus and trip `windowDidResignKey` → close). Both paths get the guard.

## Behavior

- Committing a port-kill target does **not** kill. It shows a confirmation card overlaid on the palette (dimmed backdrop), with a warning title, a message naming the process/port/pid, and two buttons: **取消** (Esc) and a destructive **结束** (Return).
- While the card is up: Return confirms (kills, then dismisses the palette), Esc cancels (card closes, the list/query is preserved), every other key is swallowed (no stray typing into the hidden search field). The buttons are also clickable.
- Because the card is in-window, the palette stays key — no `NSAlert` focus/close problems.
- Non-port options (Keep Awake durations, Scheduled Shutdown, Brightness, Hosts) are unaffected: they have no confirmation and run immediately as before.

## Architecture

- **`CommandPaletteConfirmation`** (new, `Equatable`, in `CommandPaletteOptions.swift`): `{ title, message, confirmLabel }` — pure display text.
- **`CommandPaletteOption`** gains `let confirmation: CommandPaletteConfirmation?` (default `nil`). `CommandPaletteOptions.portOptions` sets it on every port option via a shared `portKillConfirmation(for: PortRecord)` builder; all other builders leave it `nil`.
- **`CommandPaletteState`** gains a pending-confirmation slot (held on the MainActor, like `CommandPaletteOption`, because it carries a non-Sendable perform closure):
  ```swift
  struct PendingConfirmation { let confirmation: CommandPaletteConfirmation; let perform: @MainActor () async -> Void }
  private(set) var pendingConfirmation: PendingConfirmation?
  var isConfirming: Bool { pendingConfirmation != nil }
  func requestConfirmation(_:perform:)   // sets the slot
  func cancelConfirmation()              // clears it
  ```
- **`CommandPaletteWindowController.commit`** routes the two port paths into confirmation instead of killing:
  - `.portRecord(record)` → `state.requestConfirmation(CommandPaletteOptions.portKillConfirmation(for: record)) { kill(pid) + toast }`, no close.
  - `.paletteOption(id)` whose option has a `confirmation` → `state.requestConfirmation(option.confirmation) { option.perform() }`, no close. Options without a confirmation run-and-close as today.
- **`handle(keyCode:)`** checks `state.isConfirming` first: Return → `confirmPending()` (read perform, close, run); Esc → `cancelConfirmation()`; all other keys swallowed (`return true`).
- **`CommandPalettePicker`** overlays a `confirmCard` when `state.isConfirming`: dimmed backdrop + centered material card (title, message, 取消 / 结束 buttons). Cancel calls `state.cancelConfirmation()`; confirm calls a new `onConfirm` closure bound by the controller to `confirmPending()`.

## Localization (new keys)

- `commandPalette.portKill.confirmTitle` — "结束进程？" / "Kill process?"
- `commandPalette.portKill.confirmMessage` — "%@（端口 :%@ · PID %@）将被结束。" / "%@ (port :%@ · PID %@) will be terminated." (args: process, port, pid)
- `commandPalette.portKill.confirmButton` — "结束" / "Kill"
- `commandPalette.confirm.cancel` — "取消" / "Cancel"

## Tests

- `portKillConfirmation(for:)` returns the expected title/message/button (en, with port + pid interpolated).
- `portOptions(records:)` options each carry a non-nil `confirmation`; the existing non-port builders (`keepAwakeOptions`, etc.) carry `nil`.
- `CommandPaletteState`: `requestConfirmation` sets `isConfirming` + stores the descriptor; `cancelConfirmation` clears it; the existing flows are unaffected when not confirming.

## Out of scope

- No confirmation for non-destructive options or the panel/popover port manager (only the command palette, both kill paths).
- No multi-button focus cycling — Return is the destructive default, Esc cancels (matches the mockup).
