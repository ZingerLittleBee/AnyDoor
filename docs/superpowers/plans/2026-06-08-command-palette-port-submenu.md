# Command Palette Port Manager Submenu Implementation Plan

> **For agentic workers:** Steps use checkbox (`- [ ]`) syntax for tracking. TDD: write the failing test, watch it fail, implement, watch it pass, commit.

**Goal:** Make Port Manager a drill-in option parent in the command palette and remove the hidden numeric-only port search.

**Architecture:** Extend the existing `CommandPaletteOptions` second-level pattern with a `portOptions(records:)` builder; route `.portManager` through `isOptionParent`/`shouldListInPalette`/`options(for:)`; broaden second-level search to the subtitle; then delete the now-dead root numeric path, the `PanelEntry.Source.portRecord` case, and the orphaned section string.

**Tech Stack:** Swift 6.2, SwiftUI/AppKit, XCTest.

Build/test commands: `swift build`, `swift test --filter CommandPaletteOptionsTests`, `swift test`.

---

### Task 1: Port Manager as an option parent

**Files:**
- Modify: `Sources/AnyDoor/Services/CommandPaletteOptions.swift`
- Test: `Tests/AnyDoorTests/CommandPaletteOptionsTests.swift`

- [ ] **Step 1: Failing tests** — add to `CommandPaletteOptionsTests`:

```swift
@MainActor
func testIsOptionParentIncludesPortManager() {
    XCTAssertTrue(CommandPaletteOptions.isOptionParent(.portManager))
}

@MainActor
func testPortOptionsSortedWithKillAffordance() {
    let previous = LocalizationManager.shared.preference
    LocalizationManager.shared.preference = .en
    defer { LocalizationManager.shared.preference = previous }

    let records = [
        PortRecord(port: 8080, pid: 43, processName: "java",
                   executablePath: nil, commandLine: nil,
                   binds: [PortBind(address: "*", family: .ipv4)]),
        PortRecord(port: 3000, pid: 42, processName: "node",
                   executablePath: nil, commandLine: nil,
                   binds: [PortBind(address: "*", family: .ipv4)]),
    ]
    let options = CommandPaletteOptions.portOptions(records: records)
    XCTAssertEqual(options.map(\.id), ["port.42.3000", "port.43.8080"])
    XCTAssertEqual(options.map(\.title), ["node", "java"])
    XCTAssertEqual(options.first?.subtitle, "Port :3000 · PID 42")
    XCTAssertEqual(options.first?.symbol, "xmark.circle.fill")
    XCTAssertFalse(options.contains { $0.role == .destructive })
}

@MainActor
func testPortOptionsEmptyWhenNoRecords() {
    XCTAssertTrue(CommandPaletteOptions.portOptions(records: []).isEmpty)
}
```

- [ ] **Step 2: Run, expect fail** — `swift test --filter CommandPaletteOptionsTests` fails to compile (`portOptions` missing).

- [ ] **Step 3: Implement** in `CommandPaletteOptions.swift`:
  - `isOptionParent`: add `.portManager` to the `true` case.
  - `shouldListInPalette`: add `case .portManager: return true`.
  - `options(for:)`: add
    ```swift
    case .portManager:
        await PortInventory.shared.refresh()
        return portOptions(records: PortInventory.shared.records)
    ```
  - Add the builder + sort:
    ```swift
    /// One option per listening port (sorted by port, then process, then pid).
    /// Selecting a row kills the owning process and shows the standard toast.
    static func portOptions(records: [PortRecord]) -> [CommandPaletteOption] {
        records.sorted(by: portSort).map { record in
            CommandPaletteOption(
                id: "port.\(record.pid).\(record.port)",
                title: record.processName,
                subtitle: L(.commandPalettePortSubtitle, String(record.port), String(record.pid)),
                symbol: "xmark.circle.fill",
                perform: {
                    let result = await PortInventory.shared.kill(pid: record.pid)
                    ToastPresenter.shared.show(
                        CommandPalettePortKillToast.style(for: record, result: result)
                    )
                }
            )
        }
    }

    private static func portSort(_ lhs: PortRecord, _ rhs: PortRecord) -> Bool {
        if lhs.port != rhs.port { return lhs.port < rhs.port }
        let nameOrder = lhs.processName.localizedCaseInsensitiveCompare(rhs.processName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.pid < rhs.pid
    }
    ```

- [ ] **Step 4: Run, expect pass** — `swift test --filter CommandPaletteOptionsTests`.

- [ ] **Step 5: Commit** — `feat(command-palette): add port manager option builder`.

---

### Task 2: Second-level search matches subtitle

**Files:**
- Modify: `Sources/AnyDoor/Views/CommandPalettePicker.swift`
- Test: `Tests/AnyDoorTests/CommandPaletteOptionsTests.swift`

- [ ] **Step 1: Failing test**:

```swift
@MainActor
func testSecondLevelSearchMatchesSubtitle() {
    let state = CommandPaletteState(sections: [], hyperFlags: 0)
    state.enterOptions(parentTitle: "Ports", [
        CommandPaletteOption(id: "port.42.3000", title: "node",
                             subtitle: "Port :3000 · PID 42", symbol: "xmark.circle.fill", perform: {}),
        CommandPaletteOption(id: "port.43.8080", title: "java",
                             subtitle: "Port :8080 · PID 43", symbol: "xmark.circle.fill", perform: {}),
    ])
    state.query = "3000"
    XCTAssertEqual(state.flatEntries.map(\.id), ["option:port.42.3000"])
}
```

- [ ] **Step 2: Run, expect fail** — only title is matched today, so `3000` matches nothing → empty, assertion fails.

- [ ] **Step 3: Implement** — in `CommandPaletteState.filteredOptionEntries`:

```swift
return optionEntries.filter {
    $0.title.localizedCaseInsensitiveContains(trimmed)
        || ($0.subtitle?.localizedCaseInsensitiveContains(trimmed) ?? false)
}
```

- [ ] **Step 4: Run, expect pass** — `swift test --filter CommandPaletteOptionsTests`.

- [ ] **Step 5: Commit** — `feat(command-palette): match option subtitle in second-level search`.

---

### Task 3: Drill into an empty options array

**Files:**
- Modify: `Sources/AnyDoor/Views/CommandPaletteWindowController.swift`

- [ ] **Step 1: Implement** — in `commit(_:)`, the option-parent branch:

```swift
guard let state = self.state, self.window?.isVisible == true else { return }
if let options {
    state.enterOptions(parentTitle: L(item.titleKey), options)
} else {
    self.close() // not an option parent right now (brightness lost its display)
}
```

(Changes `if let options, !options.isEmpty` to `if let options` so an empty port list drills into the empty state instead of silently closing. Brightness returns `nil` when it has no options and is already gated out of the list.)

- [ ] **Step 2: Build** — `swift build` succeeds.

- [ ] **Step 3: Commit** — `feat(command-palette): drill into empty option lists instead of closing`.

---

### Task 4: Remove the root numeric port search

**Files:**
- Modify: `Sources/AnyDoor/Views/CommandPalettePicker.swift`
- Modify: `Tests/AnyDoorTests/CommandPaletteTests.swift`

- [ ] **Step 1: Delete tests** — remove `testEmptyQueryDoesNotShowPortProcesses` and `testPortNumberQueryShowsMatchingPortProcess` from `CommandPaletteTests` (they construct `CommandPaletteState(... portInventory:)` and assert the removed behavior). Keep the `StubScanner`, `isolatedDefaults`, and `portRecord` helpers only if still referenced; otherwise delete the now-unused ones.

- [ ] **Step 2: Delete the path** in `CommandPalettePicker.swift`:
  - In `filteredSections`, drop the `if let ports = portSection(matching: trimmed) { sections.insert(ports, at: 0) }` block.
  - Delete `portInventory`, `portRefreshTask`, `refreshPortsIfNeeded()`, `portSection(matching:)`, `portSearchNeedle(from:)`, `sortPorts(_:_:)`, `portEntry(for:)`, and the `portInventory:` init parameter (and its stored assignment).
  - In `.onChange(of: state.query)`, drop `state.refreshPortsIfNeeded()` (keep `state.selectedIndex = 0`).

- [ ] **Step 3: Build + test** — `swift build`; `swift test --filter CommandPaletteTests`.

- [ ] **Step 4: Commit** — `refactor(command-palette): remove hidden numeric port search`.

---

### Task 5: Remove the dead `PanelEntry.Source.portRecord` case

**Files:**
- Modify: `Sources/AnyDoor/Models/PanelEntry.swift`
- Modify: `Sources/AnyDoor/Views/CommandPaletteWindowController.swift`
- Modify: `Sources/AnyDoor/Views/CommandPalettePicker.swift`
- Modify: `Sources/AnyDoor/Views/PanelSettingsView.swift`

- [ ] **Step 1: Delete the case + arms**:
  - `PanelEntry.swift`: remove `case portRecord(PortRecord)`, its `id(for:)` arm (`"port:\(record.pid):\(record.port)"`), and its `localizedTitle()` arm.
  - `CommandPaletteWindowController.swift`: drop `.portRecord` from the prewarm switch (line ~61) and remove the whole `.portRecord` block from `commit(_:)`.
  - `CommandPalettePicker.swift`: drop `.portRecord` from `iconPath` and from `showsSubtitle`.
  - `PanelSettingsView.swift`: drop `.portRecord` from both switches (lines ~198, ~210).

- [ ] **Step 2: Build + test** — `swift build`; `swift test`.

- [ ] **Step 3: Commit** — `refactor(command-palette): drop unused portRecord panel source`.

---

### Task 6: Remove the orphaned section string

**Files:**
- Modify: `Sources/AnyDoor/Utilities/L10n.swift`
- Modify: `Sources/AnyDoor/Resources/Localizable.xcstrings`

- [ ] **Step 1: Delete** `case commandPaletteSectionPorts = "commandPalette.section.ports"` from `L10n.Key`, and the matching `"commandPalette.section.ports"` object from `Localizable.xcstrings`. Leave `commandPalette.port.subtitle` (still used by `portOptions`).

- [ ] **Step 2: Build + test** — `swift build`; `swift test` (LocalizationCoverageTests still green with one fewer key).

- [ ] **Step 3: Commit** — `chore(l10n): drop unused command-palette ports section key`.

---

### Task 7: Docs + changelog

**Files:**
- Modify: `CHANGELOG.md`, `CLAUDE.md`, `AGENTS.md`

- [ ] **Step 1: CHANGELOG** — under `## [Unreleased]`, extend the command-palette second-level entry (or add a `### Changed`/`### Added` line) noting Port Manager now drills into a searchable list of listening ports and the hidden numeric search was replaced.

- [ ] **Step 2: CLAUDE.md / AGENTS.md** — update the "Command palette second-level menu" note: Port Manager is now an option parent (`keepAwake` / `scheduledShutdown` / `brightness` / `hostsManager` / `portManager`); second-level search matches title + subtitle; the numeric port search is gone.

- [ ] **Step 3: Full suite** — `swift test` all green.

- [ ] **Step 4: Commit** — `docs: document port manager command-palette submenu`.

---

## Self-Review

- Spec coverage: option parent (T1), subtitle search (T2), empty drill-in (T3), numeric removal (T4), `portRecord` removal (T5), section-string removal (T6), docs (T7). ✓
- Type consistency: `portOptions(records:)`, `portSort`, option id `port.<pid>.<port>` used consistently; `PortRecord` initializer matches the model (`port/pid/processName/executablePath/commandLine/binds`). ✓
- No placeholders. ✓
