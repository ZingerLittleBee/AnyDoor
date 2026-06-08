# Command Palette Second-Level Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a keyboard-first second-level drill-down to the command palette so option-bearing commands (Keep Awake, Scheduled Shutdown, Brightness, Hosts) expose their options instead of acting with a default.

**Architecture:** A new `CommandPaletteOptions` builder maps an option-bearing `BuiltinItem` to a list of `CommandPaletteOption` value types (pure per-item builders that take already-fetched state, so they unit-test without singletons). `CommandPaletteState` gains a root⇄options navigation stack; option rows reuse the existing list/row rendering via a new `PanelEntry.Source.paletteOption(id:)` case that carries only a `String` (preserving `Hashable` value semantics), with the real action looked up by id on the MainActor. `CommandPaletteWindowController` lists Brightness (when an external DDC display exists) and Hosts, drills into option parents on commit, runs an option then closes, and handles Esc / empty-query Backspace to pop.

**Tech Stack:** Swift 6.2 (strict concurrency), SwiftUI + AppKit (`NSPanel`), XCTest, `.xcstrings` catalog compiled by `XCStringsCompilerPlugin`.

---

## File Structure

- **Create** `Sources/AnyDoor/Services/CommandPaletteOptions.swift` — the `CommandPaletteOption` value type and the `CommandPaletteOptions` builder (pure per-item builders + `options(for:)` + `isOptionParent` + `shouldListInPalette`). Owns "which commands have options and what they are."
- **Modify** `Sources/AnyDoor/Models/PanelEntry.swift` — add `Source.paletteOption(id:)`, extend `id(for:)` and `localizedTitle()`.
- **Modify** `Sources/AnyDoor/Views/CommandPalettePicker.swift` — `CommandPaletteState` navigation stack; back header + flat option list in `CommandPalettePicker`; `.paletteOption` rendering (checkmark + destructive color) in `CommandPaletteRow`.
- **Modify** `Sources/AnyDoor/Views/CommandPaletteWindowController.swift` — list Brightness/Hosts in `collectSections`; drill/option/back routing in `commit` + key monitor.
- **Modify** `Sources/AnyDoor/Utilities/L10n.swift` + `Sources/AnyDoor/Resources/Localizable.xcstrings` — 4 new keys (option search placeholder, back, brightness level format, edit hosts).
- **Create** `Tests/AnyDoorTests/CommandPaletteOptionsTests.swift` — builder + navigation unit tests.
- **Modify** `CHANGELOG.md`, `CLAUDE.md`, `AGENTS.md` — feature note + architecture note.

---

## Task 1: Localization keys

**Files:**
- Modify: `Sources/AnyDoor/Utilities/L10n.swift:251` (append cases before the closing migration comment)
- Modify: `Sources/AnyDoor/Resources/Localizable.xcstrings`
- Test: `Tests/AnyDoorTests/LocalizationCoverageTests.swift` (existing — must pass)

- [ ] **Step 1: Add the four `L10n.Key` cases**

In `Sources/AnyDoor/Utilities/L10n.swift`, immediately before the line
`        // Migration tasks append cases here. Keep alphabetical by raw value.`
(currently line 251), insert:

```swift
        case commandPaletteOptionBack = "commandPalette.option.back"
        case commandPaletteOptionSearchPlaceholder = "commandPalette.option.searchPlaceholder"
        case commandPaletteBrightnessLevel = "commandPalette.brightness.level"
        case commandPaletteHostsEdit = "commandPalette.hosts.edit"
```

- [ ] **Step 2: Add the matching xcstrings entries**

Open `Sources/AnyDoor/Resources/Localizable.xcstrings`. Inside the top-level
`"strings"` object, add these four members (JSON — mind the commas; the object is
not order-sensitive, the compiler tolerates any key order):

```json
    "commandPalette.brightness.level" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "%d%%" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "%d%%" } }
      }
    },
    "commandPalette.hosts.edit" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Edit hosts…" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "编辑 hosts…" } }
      }
    },
    "commandPalette.option.back" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Back" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "返回" } }
      }
    },
    "commandPalette.option.searchPlaceholder" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Filter options" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "筛选选项" } }
      }
    },
```

- [ ] **Step 3: Verify the JSON parses and the coverage test passes**

Run: `swift test --filter LocalizationCoverageTests`
Expected: PASS (the new keys resolve in both `en` and `zh-Hans`; a malformed JSON
edit or a missing language would fail here).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings
git commit -m "feat(command-palette): add localization keys for option drill-down"
```

---

## Task 2: `PanelEntry.Source.paletteOption` case

**Files:**
- Modify: `Sources/AnyDoor/Models/PanelEntry.swift:47-90`
- Test: `Tests/AnyDoorTests/CommandPaletteOptionsTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/AnyDoorTests/CommandPaletteOptionsTests.swift`:

```swift
import XCTest
@testable import AnyDoor

final class CommandPaletteOptionsTests: XCTestCase {
    @MainActor
    func testPaletteOptionSourceMakesStableID() {
        let source = PanelEntry.Source.paletteOption(id: "keepAwake.15")
        XCTAssertEqual(PanelEntry.id(for: source), "option:keepAwake.15")
    }

    @MainActor
    func testPaletteOptionLocalizedTitleReturnsStoredTitle() {
        let entry = PanelEntry(
            id: "option:x",
            source: .paletteOption(id: "x"),
            displayOrder: 0,
            isVisible: true,
            hotkey: nil,
            title: "30 minutes",
            subtitle: nil,
            symbol: "clock",
            kind: .action,
            toggleState: nil,
            permission: .notRequired
        )
        XCTAssertEqual(entry.localizedTitle(), "30 minutes")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CommandPaletteOptionsTests`
Expected: FAIL to compile — `Source` has no member `paletteOption`.

- [ ] **Step 3: Add the case and wire it into `id(for:)` and `localizedTitle()`**

In `Sources/AnyDoor/Models/PanelEntry.swift`, add the case to `enum Source`
(after the `.calcResult` case, line 52):

```swift
        case paletteOption(id: String)                 // Command-palette-only: a drilled-in second-level option
```

Extend `static func id(for:)` (add before the closing `}` of the switch, line 73-74):

```swift
        case .paletteOption(let id):              return "option:\(id)"
```

Extend `localizedTitle()`'s switch (after the `.calcResult` case, line 87):

```swift
        case .paletteOption: return title
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CommandPaletteOptionsTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Models/PanelEntry.swift Tests/AnyDoorTests/CommandPaletteOptionsTests.swift
git commit -m "feat(command-palette): add paletteOption entry source"
```

---

## Task 3: `CommandPaletteOption` + `CommandPaletteOptions` builders

**Files:**
- Create: `Sources/AnyDoor/Services/CommandPaletteOptions.swift`
- Test: `Tests/AnyDoorTests/CommandPaletteOptionsTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AnyDoorTests/CommandPaletteOptionsTests.swift` (inside the class):

```swift
    @MainActor
    func testKeepAwakeOptionsOffHasNoTurnOff() {
        let options = CommandPaletteOptions.keepAwakeOptions(isOn: false)
        XCTAssertEqual(options.map(\.id),
                       ["keepAwake.indefinite", "keepAwake.15", "keepAwake.30",
                        "keepAwake.60", "keepAwake.120"])
        XCTAssertFalse(options.contains { $0.role == .destructive })
    }

    @MainActor
    func testKeepAwakeOptionsOnAppendsTurnOff() {
        let options = CommandPaletteOptions.keepAwakeOptions(isOn: true)
        XCTAssertEqual(options.last?.id, "keepAwake.off")
        XCTAssertEqual(options.last?.role, .destructive)
        XCTAssertEqual(options.count, 6)
    }

    @MainActor
    func testScheduledShutdownOptionsArmedAppendsCancel() {
        XCTAssertEqual(CommandPaletteOptions.scheduledShutdownOptions(isArmed: false).count, 4)
        let armed = CommandPaletteOptions.scheduledShutdownOptions(isArmed: true)
        XCTAssertEqual(armed.count, 5)
        XCTAssertEqual(armed.last?.id, "scheduledShutdown.cancel")
        XCTAssertEqual(armed.last?.role, .destructive)
    }

    @MainActor
    func testBrightnessOptionsNilWithoutDDCDisplay() {
        XCTAssertNil(CommandPaletteOptions.brightnessOptions(displays: []))
        let noDDC = [DisplayInfo(id: 1, name: "A", supportsDDC: false)]
        XCTAssertNil(CommandPaletteOptions.brightnessOptions(displays: noDDC))
    }

    @MainActor
    func testBrightnessOptionsLabelsAndIDs() throws {
        let previous = LocalizationManager.shared.preference
        LocalizationManager.shared.preference = .en
        defer { LocalizationManager.shared.preference = previous }

        let options = try XCTUnwrap(
            CommandPaletteOptions.brightnessOptions(
                displays: [DisplayInfo(id: 1, name: "A", supportsDDC: true)]
            )
        )
        XCTAssertEqual(options.map(\.id),
                       ["brightness.0", "brightness.25", "brightness.50",
                        "brightness.75", "brightness.100"])
        XCTAssertEqual(options.map(\.title),
                       ["0%", "25%", "50%", "75%", "100%"])
    }

    @MainActor
    func testHostsOptionsCheckmarkAndEditAlwaysPresent() {
        let previous = LocalizationManager.shared.preference
        LocalizationManager.shared.preference = .en
        defer { LocalizationManager.shared.preference = previous }

        let active = HostProfile(name: "Dev", isActive: true)
        let inactive = HostProfile(name: "Prod", isActive: false)
        let options = CommandPaletteOptions.hostsOptions(profiles: [active, inactive])

        XCTAssertEqual(options.count, 3)
        XCTAssertEqual(options[0].title, "Dev")
        XCTAssertTrue(options[0].isChecked)
        XCTAssertEqual(options[1].title, "Prod")
        XCTAssertFalse(options[1].isChecked)
        XCTAssertEqual(options.last?.id, "hosts.edit")

        XCTAssertEqual(CommandPaletteOptions.hostsOptions(profiles: []).map(\.id),
                       ["hosts.edit"])
    }

    @MainActor
    func testIsOptionParent() {
        XCTAssertTrue(CommandPaletteOptions.isOptionParent(.keepAwake))
        XCTAssertTrue(CommandPaletteOptions.isOptionParent(.scheduledShutdown))
        XCTAssertTrue(CommandPaletteOptions.isOptionParent(.brightness))
        XCTAssertTrue(CommandPaletteOptions.isOptionParent(.hostsManager))
        XCTAssertFalse(CommandPaletteOptions.isOptionParent(.muteAudio))
        XCTAssertFalse(CommandPaletteOptions.isOptionParent(.windowLayout))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CommandPaletteOptionsTests`
Expected: FAIL to compile — `CommandPaletteOption` / `CommandPaletteOptions` undefined.

- [ ] **Step 3: Create the builder file**

Create `Sources/AnyDoor/Services/CommandPaletteOptions.swift`:

```swift
import Foundation
import AppKit

/// One selectable entry on the command palette's second level. `perform` runs the
/// action (delegating to the relevant service); it is not `Sendable`, so options
/// live only on the MainActor (held by `CommandPaletteState`), never inside the
/// value-typed `PanelEntry`.
struct CommandPaletteOption: Identifiable {
    enum Role { case normal, destructive }

    let id: String
    let title: String
    let subtitle: String?
    let symbol: String
    let role: Role
    let isChecked: Bool
    let perform: @MainActor () async -> Void

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        symbol: String,
        role: Role = .normal,
        isChecked: Bool = false,
        perform: @escaping @MainActor () async -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.role = role
        self.isChecked = isChecked
        self.perform = perform
    }
}

/// Source of truth for which commands expose a second-level menu and what those
/// options are. Pure per-item builders take already-fetched state so they unit
/// test without singletons; `options(for:)` gathers that state on the MainActor
/// and dispatches.
@MainActor
enum CommandPaletteOptions {

    /// Items that drill into a second level instead of acting directly.
    static func isOptionParent(_ item: BuiltinItem) -> Bool {
        switch item {
        case .keepAwake, .scheduledShutdown, .brightness, .hostsManager: return true
        default: return false
        }
    }

    /// Whether the command palette should list `item` as a row. Brightness only
    /// appears when an external DDC display exists; the other parents are always
    /// listed (Keep Awake / Scheduled Shutdown are already listed as toggles, so
    /// this gate matters for Brightness and Hosts, which `collectSections` adds).
    static func shouldListInPalette(_ item: BuiltinItem, hasExternalDDC: Bool) -> Bool {
        switch item {
        case .brightness: return hasExternalDDC
        case .hostsManager: return true
        default: return false
        }
    }

    /// Options for an option-bearing builtin, or nil if it has none right now
    /// (brightness with no external DDC display).
    static func options(for item: BuiltinItem) async -> [CommandPaletteOption]? {
        switch item {
        case .keepAwake:
            return keepAwakeOptions(isOn: PanelStore.shared.keepAwakeState.isOn)
        case .scheduledShutdown:
            return scheduledShutdownOptions(isArmed: ScheduledShutdownService.shared.state.isArmed)
        case .brightness:
            return brightnessOptions(displays: DisplayBrightnessService.shared.displays)
        case .hostsManager:
            HostsManager.shared.reload()
            return hostsOptions(profiles: HostsManager.shared.profiles)
        default:
            return nil
        }
    }

    // MARK: - Pure per-item builders

    static func keepAwakeOptions(isOn: Bool) -> [CommandPaletteOption] {
        var options: [CommandPaletteOption] = [
            CommandPaletteOption(
                id: "keepAwake.indefinite", title: L(.keepAwakeDurationIndefinite),
                symbol: "infinity",
                perform: { await PanelStore.shared.setKeepAwakeDuration(.indefinite) }
            ),
            keepAwakeDuration(id: "keepAwake.15", minutes: 15, titleKey: .keepAwakeDuration15Min),
            keepAwakeDuration(id: "keepAwake.30", minutes: 30, titleKey: .keepAwakeDuration30Min),
            keepAwakeDuration(id: "keepAwake.60", minutes: 60, titleKey: .keepAwakeDuration1Hour),
            keepAwakeDuration(id: "keepAwake.120", minutes: 120, titleKey: .keepAwakeDuration2Hour),
        ]
        if isOn {
            options.append(CommandPaletteOption(
                id: "keepAwake.off", title: L(.keepAwakeDurationTurnOff),
                symbol: "xmark.circle", role: .destructive,
                perform: { await PanelStore.shared.setKeepAwakeDuration(nil) }
            ))
        }
        return options
    }

    private static func keepAwakeDuration(id: String, minutes: Int, titleKey: L10n.Key) -> CommandPaletteOption {
        CommandPaletteOption(
            id: id, title: L(titleKey), symbol: "clock",
            perform: { await PanelStore.shared.setKeepAwakeDuration(.minutes(minutes)) }
        )
    }

    static func scheduledShutdownOptions(isArmed: Bool) -> [CommandPaletteOption] {
        var options: [CommandPaletteOption] = [
            shutdownDuration(id: "scheduledShutdown.15", minutes: 15, titleKey: .scheduledShutdownDuration15Min),
            shutdownDuration(id: "scheduledShutdown.30", minutes: 30, titleKey: .scheduledShutdownDuration30Min),
            shutdownDuration(id: "scheduledShutdown.60", minutes: 60, titleKey: .scheduledShutdownDuration1Hour),
            shutdownDuration(id: "scheduledShutdown.120", minutes: 120, titleKey: .scheduledShutdownDuration2Hour),
        ]
        if isArmed {
            options.append(CommandPaletteOption(
                id: "scheduledShutdown.cancel", title: L(.scheduledShutdownDurationCancel),
                symbol: "xmark.circle", role: .destructive,
                perform: { await PanelStore.shared.setScheduledShutdownDuration(nil) }
            ))
        }
        return options
    }

    private static func shutdownDuration(id: String, minutes: Int, titleKey: L10n.Key) -> CommandPaletteOption {
        CommandPaletteOption(
            id: id, title: L(titleKey), symbol: "clock",
            perform: { await PanelStore.shared.setScheduledShutdownDuration(.minutes(minutes)) }
        )
    }

    /// Discrete brightness steps applied to every external DDC display. Returns
    /// nil when no such display exists so the command is omitted from the palette.
    static func brightnessOptions(displays: [DisplayInfo]) -> [CommandPaletteOption]? {
        guard displays.contains(where: \.supportsDDC) else { return nil }
        return [0, 25, 50, 75, 100].map { percent in
            CommandPaletteOption(
                id: "brightness.\(percent)",
                title: L(.commandPaletteBrightnessLevel, percent),
                symbol: "sun.max",
                perform: {
                    let level = Float(percent) / 100
                    for display in DisplayBrightnessService.shared.displays where display.supportsDDC {
                        DisplayBrightnessService.shared.setBrightness(level, for: display.id)
                    }
                }
            )
        }
    }

    /// One option per profile (checkmark = active, selecting toggles), plus an
    /// always-present "Edit hosts…" entry that opens the editor window.
    static func hostsOptions(profiles: [HostProfile]) -> [CommandPaletteOption] {
        var options: [CommandPaletteOption] = profiles.map { profile in
            CommandPaletteOption(
                id: "hosts.\(profile.id.uuidString)",
                title: profile.name,
                symbol: "list.bullet.rectangle",
                isChecked: profile.isActive,
                perform: { await HostsManager.shared.setActive(profile, !profile.isActive) }
            )
        }
        options.append(CommandPaletteOption(
            id: "hosts.edit", title: L(.commandPaletteHostsEdit), symbol: "pencil",
            perform: { HostsEditorWindowController.shared.show() }
        ))
        return options
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CommandPaletteOptionsTests`
Expected: PASS (all builder + isOptionParent tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/CommandPaletteOptions.swift Tests/AnyDoorTests/CommandPaletteOptionsTests.swift
git commit -m "feat(command-palette): add option builders for drill-down"
```

---

## Task 4: `CommandPaletteState` navigation stack

**Files:**
- Modify: `Sources/AnyDoor/Views/CommandPalettePicker.swift:14-150`
- Test: `Tests/AnyDoorTests/CommandPaletteOptionsTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AnyDoorTests/CommandPaletteOptionsTests.swift` (inside the class):

```swift
    @MainActor
    private func sampleOptions() -> [CommandPaletteOption] {
        [
            CommandPaletteOption(id: "a", title: "Alpha", symbol: "clock", perform: {}),
            CommandPaletteOption(id: "b", title: "Beta", symbol: "clock", perform: {}),
        ]
    }

    @MainActor
    func testEnterOptionsSwitchesLevelAndResetsQuery() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "stale"
        state.selectedIndex = 3

        state.enterOptions(parentTitle: "Keep Awake", sampleOptions())

        XCTAssertFalse(state.isAtRoot)
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.selectedIndex, 0)
        XCTAssertEqual(state.flatEntries.map(\.id), ["option:a", "option:b"])
        XCTAssertTrue(state.filteredSections.isEmpty) // dynamic sections suppressed off-root
        XCTAssertEqual(state.option(id: "a")?.title, "Alpha")
    }

    @MainActor
    func testSecondLevelSearchFilters() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.enterOptions(parentTitle: "Keep Awake", sampleOptions())
        state.query = "bet"
        XCTAssertEqual(state.flatEntries.map(\.id), ["option:b"])
    }

    @MainActor
    func testPopToRootRestoresRoot() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.enterOptions(parentTitle: "Keep Awake", sampleOptions())
        state.query = "x"
        state.selectedIndex = 1

        state.popToRoot()

        XCTAssertTrue(state.isAtRoot)
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.selectedIndex, 0)
        XCTAssertNil(state.option(id: "a"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CommandPaletteOptionsTests`
Expected: FAIL to compile — `enterOptions` / `popToRoot` / `isAtRoot` / `option(id:)` undefined.

- [ ] **Step 3: Add the navigation stack to `CommandPaletteState`**

In `Sources/AnyDoor/Views/CommandPalettePicker.swift`, add to `CommandPaletteState`
(after the stored properties, around line 17-18 `var query` / `var selectedIndex`):

```swift
    enum Level: Equatable { case root; case options(parentTitle: String) }

    private(set) var level: Level = .root
    private var optionsByID: [String: CommandPaletteOption] = [:]
    private var optionEntries: [PanelEntry] = []

    var isAtRoot: Bool { level == .root }

    /// Push a second level built from `options`; resets the search + selection.
    func enterOptions(parentTitle: String, _ options: [CommandPaletteOption]) {
        optionsByID = Dictionary(uniqueKeysWithValues: options.map { ($0.id, $0) })
        optionEntries = options.enumerated().map { index, option in
            PanelEntry(
                id: PanelEntry.id(for: .paletteOption(id: option.id)),
                source: .paletteOption(id: option.id),
                displayOrder: Double(index),
                isVisible: true,
                hotkey: nil,
                title: option.title,
                subtitle: option.subtitle,
                symbol: option.symbol,
                kind: .action,
                toggleState: nil,
                permission: .notRequired
            )
        }
        level = .options(parentTitle: parentTitle)
        query = ""
        selectedIndex = 0
    }

    /// Return to the root level, clearing the option state + search + selection.
    func popToRoot() {
        level = .root
        optionsByID = [:]
        optionEntries = []
        query = ""
        selectedIndex = 0
    }

    func option(id: String) -> CommandPaletteOption? { optionsByID[id] }

    /// Option entries filtered by the second-level query.
    var filteredOptionEntries: [PanelEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return optionEntries }
        return optionEntries.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }
```

- [ ] **Step 4: Make `filteredSections` and `flatEntries` level-aware**

In the same file, change `filteredSections` so it is empty off-root (this also
suppresses the Ports / Calculator dynamic sections at the second level). Add this
guard as the first line of `var filteredSections` (currently line 36-37):

```swift
        guard isAtRoot else { return [] }
```

Replace `var flatEntries` (currently lines 78-80):

```swift
    var flatEntries: [PanelEntry] {
        switch level {
        case .root:    return filteredSections.flatMap(\.entries)
        case .options: return filteredOptionEntries
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter CommandPaletteOptionsTests`
Expected: PASS (navigation + earlier builder tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Views/CommandPalettePicker.swift Tests/AnyDoorTests/CommandPaletteOptionsTests.swift
git commit -m "feat(command-palette): add root/options navigation stack"
```

---

## Task 5: Picker back header + option list + row rendering

**Files:**
- Modify: `Sources/AnyDoor/Views/CommandPalettePicker.swift:152-451`
- Verification: `swift build` + existing `CommandPaletteTests` (no new unit test — SwiftUI view wiring is build-verified; the navigation logic it drives is already covered in Task 4).

- [ ] **Step 1: Add a back header and switch list type by level**

In `CommandPalettePicker.body` (currently lines 159-195), replace the top of the
`VStack`:

```swift
        VStack(spacing: 0) {
            if !state.isAtRoot { backHeader }

            searchField

            Divider().opacity(0.4)

            if state.flatEntries.isEmpty {
                emptyState
            } else if state.isAtRoot {
                entryList
            } else {
                optionList
            }
        }
```

- [ ] **Step 2: Add the `backHeader` and `optionList` views**

In `CommandPalettePicker`, add these computed views (place after `searchField`,
around line 224):

```swift
    private var backHeader: some View {
        Button {
            state.popToRoot()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                if case let .options(parentTitle) = state.level {
                    Text(parentTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                Spacer()
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 2)
        .help(L(.commandPaletteOptionBack))
    }

    private var optionList: some View {
        ScrollViewReader { proxy in
            let entries = state.flatEntries
            let selectedID: String? = entries.indices.contains(state.selectedIndex)
                ? entries[state.selectedIndex].id
                : nil
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        CommandPaletteRow(
                            entry: entry,
                            hyperFlags: state.hyperFlags,
                            isSelected: entry.id == selectedID,
                            option: optionForEntry(entry),
                            onSelect: { onSelect(entry) }
                        )
                        .id(entry.id)
                        .legacyMaterialBackground()
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 8) }
            .frame(minHeight: 320, maxHeight: .infinity)
            .onChange(of: state.selectedIndex) { _, newIndex in
                guard entries.indices.contains(newIndex) else { return }
                proxy.scrollTo(entries[newIndex].id)
            }
        }
    }

    /// Resolve the option backing a `.paletteOption` entry so the row can render
    /// its checkmark / destructive styling.
    private func optionForEntry(_ entry: PanelEntry) -> CommandPaletteOption? {
        guard case let .paletteOption(id) = entry.source else { return nil }
        return state.option(id: id)
    }
```

- [ ] **Step 3: Switch the search placeholder by level**

In `searchField` (line 202), replace the `TextField` placeholder argument:

```swift
            TextField(L(state.isAtRoot ? .commandPaletteSearchPlaceholder : .commandPaletteOptionSearchPlaceholder), text: $state.query)
```

- [ ] **Step 4: Render option rows in `CommandPaletteRow`**

In `private struct CommandPaletteRow`, add the stored property (after `let onSelect`,
line 322):

```swift
    var option: CommandPaletteOption? = nil
```

In `CommandPaletteRow.body`, replace the trailing hotkey block so options show a
checkmark instead (the `if let hotkey = entry.hotkey { … }` block, lines 333-343):

```swift
            if let option, option.isChecked {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else if let hotkey = entry.hotkey {
                Text(hotkey.displayString(hyperFlags: hyperFlags))
                    .font(.system(size: 12, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
                    .foregroundStyle(.secondary)
            }
```

In `titleBlock` (line 370-382), tint a destructive option's title red. Replace the
title `Text`:

```swift
            Text(entry.localizedTitle())
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(option?.role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .lineLimit(1)
```

In `iconPath` (line 412-421), add `.paletteOption` to the symbol (nil-path) branch:

```swift
        case .builtin, .portRecord, .calcResult, .paletteOption:
            return nil
```

In `showsSubtitle` (line 425-430), show option subtitles:

```swift
        case .portRecord, .calcResult, .paletteOption: return true
```

- [ ] **Step 5: Build and verify the existing palette tests still pass**

Run: `swift build`
Expected: builds (only the pre-existing XCStringsCompiler plugin deprecation
warnings).

Run: `swift test --filter CommandPaletteTests`
Expected: PASS (the root-level behavior is unchanged).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Views/CommandPalettePicker.swift
git commit -m "feat(command-palette): render second-level back header and option rows"
```

---

## Task 6: Window controller — list parents, drill in, run, go back

**Files:**
- Modify: `Sources/AnyDoor/Views/CommandPaletteWindowController.swift:99-217`
- Verification: `swift build` + manual smoke (no unit test — `NSPanel` + `NSEvent` monitor are not unit-testable; the decisions they call (`isOptionParent`, `shouldListInPalette`, builders, navigation) are all covered in Tasks 3-4).

- [ ] **Step 1: List Brightness and Hosts in `collectSections`**

In `collectSections()`, replace the `commands` filter (currently lines 103-109)
so it also admits Brightness (gated on an external DDC display) and Hosts:

```swift
        let hasExternalDDC = DisplayBrightnessService.shared.displays.contains(where: \.supportsDDC)
        let commands = store.topLevelEntries.filter { entry in
            guard entry.isVisible else { return false }
            guard case .builtin(let item) = entry.source else { return false }
            switch item.kind {
            case .toggle, .action:
                return true
            case .brightnessControl, .submenu:
                // Only the option parents the palette drills into; App Shortcuts,
                // Window Layout and Port Manager keep their own flat sections.
                return CommandPaletteOptions.shouldListInPalette(item, hasExternalDDC: hasExternalDDC)
            case .hiddenHotkey:
                return false
            }
        }
```

- [ ] **Step 2: Route commit for option parents and options**

In `commit(_ entry:)` (currently lines 219-252), replace the method so option
parents drill in (without closing) and options run then close. Keep the existing
`.appShortcut` / `.installedApp` / `.portRecord` / `.builtin` (non-parent) /
`.calcResult` handling unchanged:

```swift
    private func commit(_ entry: PanelEntry) {
        // Option parents drill into a second level instead of closing.
        if case .builtin(let item) = entry.source, CommandPaletteOptions.isOptionParent(item) {
            Task { @MainActor [weak self] in
                guard let self, let state = self.state else { return }
                if let options = await CommandPaletteOptions.options(for: item), !options.isEmpty {
                    state.enterOptions(parentTitle: L(item.titleKey), options)
                } else {
                    self.close() // nothing to drill into (e.g. brightness lost its display)
                }
            }
            return
        }

        // A second-level option runs its action, then dismisses.
        if case .paletteOption(let id) = entry.source {
            let option = state?.option(id: id)
            close()
            if let option { Task { await option.perform() } }
            return
        }

        close()
        switch entry.source {
        case .appShortcut(let id):
            guard let binding = PanelStore.shared.binding(id: id) else { return }
            AppSwitcher.toggle(bundleID: binding.appBundleID, appPath: binding.appPath)
        case .installedApp(let bundleID, let path):
            AppSwitcher.toggle(bundleID: bundleID, appPath: path)
        case .portRecord(let record):
            Task {
                let result = await PortInventory.shared.kill(pid: record.pid)
                ToastPresenter.shared.show(
                    CommandPalettePortKillToast.style(for: record, result: result)
                )
            }
        case .builtin(let item):
            switch item.kind {
            case .toggle:
                Task { await PanelStore.shared.toggle(item) }
            case .action:
                Task { await PanelStore.shared.run(item) }
            case .submenu, .brightnessControl, .hiddenHotkey:
                break
            }
        case .calcResult(let result):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(result.copyText, forType: .string)
            ClipboardWatcher.shared?.noteSelfWrite(changeCount: pasteboard.changeCount)
            ToastPresenter.shared.show(.success(L(.toastCalcCopied, result.display)))
        case .paletteOption:
            break // handled above
        }
    }
```

- [ ] **Step 3: Handle Esc / Backspace for back navigation**

In `handle(keyCode:)` (currently lines 195-217), replace the `Esc` case and add a
`Backspace` case so the second level pops:

```swift
        switch keyCode {
        case 125:
            state.moveDown()
            return true
        case 126:
            state.moveUp()
            return true
        case 36, 76:
            if let entry = state.commitSelection() {
                commit(entry)
            }
            return true
        case 51: // Delete/Backspace: pop the second level only when the query is empty
            if !state.isAtRoot, state.query.isEmpty {
                state.popToRoot()
                return true
            }
            return false // otherwise let the search field delete a character
        case 53: // Esc: pop to root from the second level, else dismiss
            if state.isAtRoot {
                cancel()
            } else {
                state.popToRoot()
            }
            return true
        default:
            return false
        }
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds (only pre-existing XCStringsCompiler plugin deprecation warnings).

- [ ] **Step 5: Full test run**

Run: `swift test`
Expected: PASS (all suites; the new `CommandPaletteOptionsTests` plus the existing
ones).

- [ ] **Step 6: Manual smoke (document, do not block on automation)**

Run: `swift run AnyDoor`, summon the command palette (its hotkey), and verify:
- Selecting **Keep Awake** / **Scheduled Shutdown** shows duration options with a
  back header; picking one arms it and closes; `Esc` returns to root.
- **Brightness** appears only with an external DDC display; picking a step changes
  brightness.
- **Hosts** lists profiles (checkmark = active) and "Edit hosts…"; selecting a
  profile toggles it (may prompt for admin password); "Edit hosts…" opens the
  editor.
- At the second level, typing filters options; `Backspace` on an empty query pops.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnyDoor/Views/CommandPaletteWindowController.swift
git commit -m "feat(command-palette): drill into option parents and run second-level options"
```

---

## Task 7: Documentation

**Files:**
- Modify: `CHANGELOG.md` (under `## [Unreleased]`)
- Modify: `CLAUDE.md` (command-palette note)
- Modify: `AGENTS.md` (mirror the CLAUDE.md note)

- [ ] **Step 1: Add a CHANGELOG entry**

Under the `## [Unreleased]` heading in `CHANGELOG.md`, add a bullet (match the
file's existing list style):

```markdown
- Command palette: option-bearing commands (Keep Awake, Scheduled Shutdown, Brightness, Hosts) now open a keyboard-navigable second-level menu instead of acting with a default.
```

- [ ] **Step 2: Add an architecture note to `CLAUDE.md` and `AGENTS.md`**

In both `CLAUDE.md` and `AGENTS.md`, in the command-palette / Views area, add an
equivalent sentence (English, per repo doc rules):

```markdown
- **Command palette second-level menu**: option-bearing commands drill into a second level. `CommandPaletteOptions` (`@MainActor`) is the single source of truth for which builtins are option parents (`keepAwake` / `scheduledShutdown` / `brightness` / `hostsManager`) and their options; pure per-item builders take fetched state so they unit-test without singletons. `CommandPaletteState` holds a `.root` ⇄ `.options` stack; option rows reuse `PanelEntry` via `Source.paletteOption(id:)` (only a `String`, action looked up by id on the MainActor). The window controller lists Brightness (only with an external DDC display) and Hosts, drills in on commit, and pops on `Esc` / empty-query `Backspace`.
```

- [ ] **Step 3: Verify docs reference real symbols**

Run: `swift build`
Expected: builds (sanity that nothing in the docs step touched code).

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md CLAUDE.md AGENTS.md
git commit -m "docs(command-palette): document second-level option menu"
```

---

## Completion

After Task 7, hand off to **superpowers:finishing-a-development-branch**: verify
`swift test` is green, then present merge / PR / keep / discard options for branch
`feat/command-palette-submenu`.
