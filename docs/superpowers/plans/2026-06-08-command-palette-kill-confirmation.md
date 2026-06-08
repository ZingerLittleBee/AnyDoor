# Command Palette Port-Kill Confirmation Implementation Plan

> TDD: failing test → watch fail → implement → watch pass → commit. Steps use `- [ ]`.

**Goal:** Guard both command-palette port-kill paths behind an in-palette confirmation card.

**Architecture:** `CommandPaletteConfirmation` descriptor + `CommandPaletteOption.confirmation` + a `pendingConfirmation` slot on `CommandPaletteState`; the controller routes port commits into `requestConfirmation` and Return/Esc through a confirming branch; the picker overlays a confirm card.

Commands: `swift build`, `swift test --filter CommandPaletteOptionsTests`, `swift test`.

---

### Task 1: Localization keys

**Files:** `Sources/AnyDoor/Utilities/L10n.swift`, `Sources/AnyDoor/Resources/Localizable.xcstrings`

- [ ] Add 4 `L10n.Key` cases: `commandPalettePortKillConfirmTitle = "commandPalette.portKill.confirmTitle"`, `commandPalettePortKillConfirmMessage = "commandPalette.portKill.confirmMessage"`, `commandPalettePortKillConfirmButton = "commandPalette.portKill.confirmButton"`, `commandPaletteConfirmCancel = "commandPalette.confirm.cancel"`.
- [ ] Add matching `.xcstrings` entries (Xcode style):
  - confirmTitle: en "Kill process?" / zh-Hans "结束进程？"
  - confirmMessage: en "%@ (port :%@ · PID %@) will be terminated." / zh-Hans "%@（端口 :%@ · PID %@）将被结束。"
  - confirmButton: en "Kill" / zh-Hans "结束"
  - confirm.cancel: en "Cancel" / zh-Hans "取消"
- [ ] `swift build`; `swift test --filter LocalizationCoverageTests`. Commit: `feat(l10n): add command-palette kill-confirmation strings`.

---

### Task 2: Confirmation descriptor on options

**Files:** `Sources/AnyDoor/Services/CommandPaletteOptions.swift`, `Tests/AnyDoorTests/CommandPaletteOptionsTests.swift`

- [ ] **Failing tests:**

```swift
@MainActor
func testPortKillConfirmationText() {
    let previous = LocalizationManager.shared.preference
    LocalizationManager.shared.preference = .en
    defer { LocalizationManager.shared.preference = previous }
    let record = PortRecord(port: 3000, pid: 42, processName: "node",
                            executablePath: nil, commandLine: nil,
                            binds: [PortBind(address: "*", family: .ipv4)])
    let c = CommandPaletteOptions.portKillConfirmation(for: record)
    XCTAssertEqual(c.title, "Kill process?")
    XCTAssertEqual(c.message, "node (port :3000 · PID 42) will be terminated.")
    XCTAssertEqual(c.confirmLabel, "Kill")
}

@MainActor
func testPortOptionsCarryConfirmationOthersDoNot() {
    let record = PortRecord(port: 3000, pid: 42, processName: "node",
                            executablePath: nil, commandLine: nil,
                            binds: [PortBind(address: "*", family: .ipv4)])
    XCTAssertNotNil(CommandPaletteOptions.portOptions(records: [record]).first?.confirmation)
    XCTAssertNil(CommandPaletteOptions.keepAwakeOptions(isOn: false).first?.confirmation)
}
```

- [ ] **Implement:**
  - Add the descriptor type (top of file):
    ```swift
    struct CommandPaletteConfirmation: Equatable {
        let title: String
        let message: String
        let confirmLabel: String
    }
    ```
  - Add `let confirmation: CommandPaletteConfirmation?` to `CommandPaletteOption`, with `confirmation: CommandPaletteConfirmation? = nil` in `init` (placed before `perform`), assigned in the body.
  - Add the builder to `CommandPaletteOptions`:
    ```swift
    static func portKillConfirmation(for record: PortRecord) -> CommandPaletteConfirmation {
        CommandPaletteConfirmation(
            title: L(.commandPalettePortKillConfirmTitle),
            message: L(.commandPalettePortKillConfirmMessage,
                       record.processName, String(record.port), String(record.pid)),
            confirmLabel: L(.commandPalettePortKillConfirmButton)
        )
    }
    ```
  - In `portOptions(records:)`, pass `confirmation: portKillConfirmation(for: record)` to each `CommandPaletteOption`.
- [ ] `swift test --filter CommandPaletteOptionsTests`. Commit: `feat(command-palette): attach kill confirmation to port options`.

---

### Task 3: Pending-confirmation state

**Files:** `Sources/AnyDoor/Views/CommandPalettePicker.swift`, `Tests/AnyDoorTests/CommandPaletteOptionsTests.swift`

- [ ] **Failing tests:**

```swift
@MainActor
func testRequestAndCancelConfirmation() {
    let state = CommandPaletteState(sections: [], hyperFlags: 0)
    XCTAssertFalse(state.isConfirming)
    let c = CommandPaletteConfirmation(title: "T", message: "M", confirmLabel: "Kill")
    state.requestConfirmation(c, perform: {})
    XCTAssertTrue(state.isConfirming)
    XCTAssertEqual(state.pendingConfirmation?.confirmation, c)
    state.cancelConfirmation()
    XCTAssertFalse(state.isConfirming)
    XCTAssertNil(state.pendingConfirmation)
}
```

- [ ] **Implement** in `CommandPaletteState`:
  ```swift
  struct PendingConfirmation {
      let confirmation: CommandPaletteConfirmation
      let perform: @MainActor () async -> Void
  }
  private(set) var pendingConfirmation: PendingConfirmation?
  var isConfirming: Bool { pendingConfirmation != nil }

  func requestConfirmation(_ confirmation: CommandPaletteConfirmation,
                           perform: @escaping @MainActor () async -> Void) {
      pendingConfirmation = PendingConfirmation(confirmation: confirmation, perform: perform)
  }
  func cancelConfirmation() { pendingConfirmation = nil }
  ```
- [ ] `swift test --filter CommandPaletteOptionsTests`. Commit: `feat(command-palette): add pending-confirmation state`.

---

### Task 4: Controller routing + key handling

**Files:** `Sources/AnyDoor/Views/CommandPaletteWindowController.swift`

- [ ] In `handle(keyCode:)`, before the existing `switch`, add:
  ```swift
  if state.isConfirming {
      switch keyCode {
      case 36, 76: confirmPending()       // Return
      case 53: state.cancelConfirmation() // Esc
      default: break                       // swallow other keys
      }
      return true
  }
  ```
- [ ] Add:
  ```swift
  private func confirmPending() {
      guard let perform = state?.pendingConfirmation?.perform else { return }
      close()
      Task { await perform() }
  }
  ```
- [ ] In `commit(_:)`, move the port paths ahead of `close()`:
  - Replace the `.paletteOption` block with one that confirms when the option has a confirmation:
    ```swift
    if case .paletteOption(let id) = entry.source {
        guard let option = state?.option(id: id) else { close(); return }
        if let confirmation = option.confirmation {
            state?.requestConfirmation(confirmation, perform: option.perform)
        } else {
            close(); Task { await option.perform() }
        }
        return
    }
    ```
  - Add a pre-close `.portRecord` branch:
    ```swift
    if case .portRecord(let record) = entry.source {
        let confirmation = CommandPaletteOptions.portKillConfirmation(for: record)
        state?.requestConfirmation(confirmation) {
            let result = await PortInventory.shared.kill(pid: record.pid)
            ToastPresenter.shared.show(CommandPalettePortKillToast.style(for: record, result: result))
        }
        return
    }
    ```
  - In the post-`close()` switch, reduce `.portRecord` to `break` (handled above).
- [ ] `swift build`. Commit: `feat(command-palette): confirm port kills before executing`.

---

### Task 5: Confirm card overlay

**Files:** `Sources/AnyDoor/Views/CommandPalettePicker.swift`

- [ ] Add `var onConfirm: () -> Void` to `CommandPalettePicker` (after `onCancel`).
- [ ] Overlay the card on the root `VStack` (after `.clipShape`):
  ```swift
  .overlay {
      if let pending = state.pendingConfirmation {
          confirmCard(pending.confirmation)
      }
  }
  ```
- [ ] Add `confirmCard(_:)`: a dimmed backdrop (`Color.black.opacity(0.35)`, `ignoresSafeArea`) plus a centered material card with an `exclamationmark.triangle` + title, the message, and an HStack of two buttons — 取消 (`state.cancelConfirmation()`) and a red 结束 (`onConfirm()`) showing `Esc` / `↵` hints. Use `.adaptivePanelSurface` / `RoundedRectangle` consistent with the palette.
- [ ] In `CommandPaletteWindowController.show()`, bind `onConfirm: { [weak self] in self?.confirmPending() }` on the `CommandPalettePicker`.
- [ ] `swift build`. Commit: `feat(command-palette): render port-kill confirmation card`.

---

### Task 6: Docs + verify

**Files:** `CHANGELOG.md`, `CLAUDE.md`, `AGENTS.md`

- [ ] CHANGELOG: under `## [Unreleased]`, note that command-palette port kills now ask for confirmation (both the numeric search and the Port Manager drill-in), Raycast-style in-palette card, Return confirms / Esc cancels.
- [ ] CLAUDE.md / AGENTS.md: extend the command-palette note — port kills (both paths) route through `CommandPaletteState.pendingConfirmation` + an in-palette confirm card; `CommandPaletteOption.confirmation` marks options needing it; the key monitor's confirming branch maps Return→confirm, Esc→cancel.
- [ ] `swift test` all green. Commit: `docs: document command-palette port-kill confirmation`.

---

## Self-Review

- Spec coverage: L10n (T1), descriptor+options (T2), state (T3), controller routing+keys (T4), card UI (T5), docs (T6). ✓
- Type consistency: `CommandPaletteConfirmation` used by option/state/controller; `portKillConfirmation(for:)` shared by `portOptions` and the `.portRecord` commit. ✓
- No placeholders. ✓
