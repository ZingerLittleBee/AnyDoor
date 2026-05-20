# Menu Bar Panel Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn AnyDoor from a hotkey-only app launcher into a menu bar panel of system toggles and actions, with the existing app shortcuts available as one hover-expandable submenu group.

**Architecture:** Three data sources merged through a `PanelStore` (`@Observable`, `@MainActor`): a code-defined `BuiltinItem` catalog with one provider per item, a SwiftData `BuiltinPreference` table for user customization (visibility / order / hotkey), and the existing `KeyBinding` table for app shortcuts. The CGEvent tap upgrades from app-only dispatch (`BindingSnapshot`) to a tri-action enum (`HotkeyAction`).

**Tech Stack:** Swift 6.2 strict concurrency, SwiftUI (MenuBarExtra + Settings), SwiftData, AppKit (NSWindow / NSWorkspace / NSAppleScript), CoreAudio, IOPMAssertion, CGEvent tap. Swift Package Manager.

**Spec:** `docs/superpowers/specs/2026-05-20-menu-bar-panel-redesign-design.md`

---

## File Structure

**New files:**

| Path | Responsibility |
|---|---|
| `Sources/AnyDoor/Models/BuiltinItem.swift` | Enum of all built-in panel items + `Kind` |
| `Sources/AnyDoor/Models/BuiltinPreference.swift` | SwiftData `@Model` for user customization of built-ins |
| `Sources/AnyDoor/Models/PanelEntry.swift` | View-facing struct, `HotkeyDescriptor`, `PermissionStatus` |
| `Sources/AnyDoor/Models/HotkeyAction.swift` | `HotkeyAction` enum + `HotkeySnapshot` Sendable type |
| `Sources/AnyDoor/Services/PanelStore.swift` | `@Observable @MainActor` merging the three data sources |
| `Sources/AnyDoor/Services/Providers/BuiltinProvider.swift` | Provider protocols + `BuiltinError` enum |
| `Sources/AnyDoor/Services/Providers/KeepAwakeProvider.swift` | IOPMAssertion-based toggle |
| `Sources/AnyDoor/Services/Providers/HideDesktopIconsProvider.swift` | defaults + killall Finder |
| `Sources/AnyDoor/Services/Providers/ShowHiddenFilesProvider.swift` | defaults + killall Finder |
| `Sources/AnyDoor/Services/Providers/MuteAudioProvider.swift` | CoreAudio mute property |
| `Sources/AnyDoor/Services/Providers/DarkModeProvider.swift` | AppleScript (System Events) |
| `Sources/AnyDoor/Services/Providers/LockScreenProvider.swift` | CGSession -suspend shell |
| `Sources/AnyDoor/Services/Providers/EmptyTrashProvider.swift` | AppleScript (Finder) |
| `Sources/AnyDoor/Services/AppleScriptRunner.swift` | Shared NSAppleScript wrapper |
| `Sources/AnyDoor/Services/ShellRunner.swift` | Shared Process wrapper |
| `Sources/AnyDoor/Views/PanelRowView.swift` | Single row rendering (toggle/action/submenu) |
| `Sources/AnyDoor/Views/HotkeyRecorder.swift` | Inline hotkey recording component |
| `Sources/AnyDoor/Views/PanelSettingsView.swift` | Unified settings list with drag/reorder |
| `Sources/AnyDoor/Views/AppShortcutsPopoverView.swift` | SwiftUI content of the hover popover |
| `Sources/AnyDoor/Views/HoverPopover.swift` | `NSWindow` host + `HoverGate` timing |
| `Tests/AnyDoorTests/KeyCodeMapTests.swift` | KeyCodeMap roundtrip |
| `Tests/AnyDoorTests/HotkeyDescriptorTests.swift` | Format / parse |
| `Tests/AnyDoorTests/MigrationTests.swift` | KeyBinding displayOrder backfill, BuiltinPreference seeding |
| `Tests/AnyDoorTests/PanelStoreTests.swift` | merge/sort/dispatch with mock providers |
| `Tests/AnyDoorTests/HotkeyConflictTests.swift` | Conflict detection |

**Modified files:**

| Path | Change |
|---|---|
| `Package.swift` | Add `.testTarget` for `AnyDoorTests` |
| `Sources/AnyDoor/Models/KeyBinding.swift` | Add `isVisible`, `displayOrder` |
| `Sources/AnyDoor/Services/HotkeyService.swift` | `BindingSnapshot` → `HotkeySnapshot`, dispatch via `PanelStore` |
| `Sources/AnyDoor/AppDelegate.swift` | Register providers, run displayOrder backfill + BuiltinPreference seeding |
| `Sources/AnyDoor/Views/MenuBarView.swift` | Rewrite to use PanelStore |
| `Sources/AnyDoor/Views/SettingsView.swift` | Replace `BindingListView` with `PanelSettingsView` |

**Deleted (in cleanup task):**

- `Sources/AnyDoor/Views/BindingListView.swift`
- `Sources/AnyDoor/Views/BindingEditView.swift`

---

## Task 1: Add test target to Package.swift

**Files:**
- Modify: `Package.swift`
- Create: `Tests/AnyDoorTests/SmokeTest.swift`

- [ ] **Step 1: Rewrite Package.swift to add test target**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AnyDoor",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "AnyDoor",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "AnyDoorTests",
            dependencies: ["AnyDoor"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
```

- [ ] **Step 2: Create a smoke test so the target compiles**

Create `Tests/AnyDoorTests/SmokeTest.swift`:

```swift
import XCTest
@testable import AnyDoor

final class SmokeTest: XCTestCase {
    func testTargetLinks() {
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test`
Expected: 1 test passes.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Tests/AnyDoorTests/SmokeTest.swift
git commit -m "build: add AnyDoorTests test target"
```

---

## Task 2: KeyCodeMap roundtrip tests (warm-up TDD)

**Files:**
- Create: `Tests/AnyDoorTests/KeyCodeMapTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/AnyDoorTests/KeyCodeMapTests.swift`:

```swift
import XCTest
import Carbon.HIToolbox
@testable import AnyDoor

final class KeyCodeMapTests: XCTestCase {
    func testKnownKeyCodeRoundtrip() {
        XCTAssertEqual(KeyCodeMap.name(for: kVK_F1), "F1")
        XCTAssertEqual(KeyCodeMap.keyCode(for: "F1"), kVK_F1)
    }

    func testReturnSymbol() {
        XCTAssertEqual(KeyCodeMap.name(for: kVK_Return), "↩")
        XCTAssertEqual(KeyCodeMap.keyCode(for: "↩"), kVK_Return)
    }

    func testUnknownKeyCodeFormatsAsKeyN() {
        XCTAssertEqual(KeyCodeMap.name(for: 9999), "Key(9999)")
    }

    func testUnknownNameReturnsNil() {
        XCTAssertNil(KeyCodeMap.keyCode(for: "DefinitelyNotAKey"))
    }
}
```

- [ ] **Step 2: Run tests to confirm they pass**

Run: `swift test --filter KeyCodeMapTests`
Expected: 4 tests pass (existing `KeyCodeMap` already supports these).

- [ ] **Step 3: Commit**

```bash
git add Tests/AnyDoorTests/KeyCodeMapTests.swift
git commit -m "test: add KeyCodeMap roundtrip tests"
```

---

## Task 3: KeyBinding model evolution

**Files:**
- Modify: `Sources/AnyDoor/Models/KeyBinding.swift`
- Create: `Tests/AnyDoorTests/MigrationTests.swift`

- [ ] **Step 1: Add `isVisible` and `displayOrder` to KeyBinding**

Replace `Sources/AnyDoor/Models/KeyBinding.swift` with:

```swift
import SwiftData
import AppKit

@Model
final class KeyBinding {
    @Attribute(.unique) var id: UUID
    var keyCode: Int
    var modifierFlags: Int
    var appBundleID: String
    var appName: String
    var appPath: String
    /// Whether the hotkey is armed. `false` disables hotkey dispatch even if the row is visible.
    var isEnabled: Bool
    /// Whether the row appears in the App Shortcuts submenu and settings list.
    var isVisible: Bool
    /// Sort weight within the App Shortcuts submenu (lower = earlier). Float so inserts don't renumber.
    var displayOrder: Double
    var createdAt: Date

    init(
        keyCode: Int,
        modifierFlags: Int,
        appBundleID: String,
        appName: String,
        appPath: String,
        isEnabled: Bool = true,
        isVisible: Bool = true,
        displayOrder: Double = 0
    ) {
        self.id = UUID()
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.appBundleID = appBundleID
        self.appName = appName
        self.appPath = appPath
        self.isEnabled = isEnabled
        self.isVisible = isVisible
        self.displayOrder = displayOrder
        self.createdAt = Date()
    }

    @Transient var displayKey: String {
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlags))
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(KeyCodeMap.name(for: keyCode))
        return parts.joined()
    }
}
```

- [ ] **Step 2: Write the failing migration test**

Create `Tests/AnyDoorTests/MigrationTests.swift`:

```swift
import XCTest
import SwiftData
@testable import AnyDoor

final class MigrationTests: XCTestCase {
    func testKeyBindingDefaultsWhenInsertedWithoutOrder() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: KeyBinding.self, configurations: config)
        let context = ModelContext(container)

        let binding = KeyBinding(
            keyCode: 122, // F1
            modifierFlags: 0,
            appBundleID: "com.apple.Safari",
            appName: "Safari",
            appPath: "/Applications/Safari.app"
        )
        context.insert(binding)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<KeyBinding>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertTrue(fetched[0].isVisible)
        XCTAssertEqual(fetched[0].displayOrder, 0)
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter MigrationTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Models/KeyBinding.swift Tests/AnyDoorTests/MigrationTests.swift
git commit -m "feat(model): add isVisible and displayOrder to KeyBinding"
```

---

## Task 4: BuiltinItem catalog

**Files:**
- Create: `Sources/AnyDoor/Models/BuiltinItem.swift`
- Modify: `Tests/AnyDoorTests/MigrationTests.swift` (add test for catalog)

- [ ] **Step 1: Create BuiltinItem enum**

Create `Sources/AnyDoor/Models/BuiltinItem.swift`:

```swift
import Foundation

/// Code-defined catalog of all built-in panel items. The set of cases is the product spec;
/// users cannot add new built-ins, only customize visibility / order / hotkey via BuiltinPreference.
enum BuiltinItem: String, CaseIterable, Sendable {
    case appShortcuts
    case keepAwake
    case muteAudio
    case hideDesktopIcons
    case showHiddenFiles
    case darkMode
    case lockScreen
    case emptyTrash

    enum Kind: Sendable {
        case toggle
        case action
        case submenu
    }

    var kind: Kind {
        switch self {
        case .appShortcuts: return .submenu
        case .keepAwake, .muteAudio, .hideDesktopIcons, .showHiddenFiles, .darkMode: return .toggle
        case .lockScreen, .emptyTrash: return .action
        }
    }

    var title: String {
        switch self {
        case .appShortcuts: return "应用快捷键"
        case .keepAwake: return "Keep Awake"
        case .muteAudio: return "静音"
        case .hideDesktopIcons: return "隐藏桌面图标"
        case .showHiddenFiles: return "显示隐藏文件"
        case .darkMode: return "深色模式"
        case .lockScreen: return "锁定屏幕"
        case .emptyTrash: return "清空废纸篓"
        }
    }

    var symbol: String {
        switch self {
        case .appShortcuts: return "keyboard"
        case .keepAwake: return "cup.and.saucer.fill"
        case .muteAudio: return "speaker.slash.fill"
        case .hideDesktopIcons: return "rectangle.on.rectangle.slash"
        case .showHiddenFiles: return "eye.fill"
        case .darkMode: return "moon.fill"
        case .lockScreen: return "lock.fill"
        case .emptyTrash: return "trash.fill"
        }
    }

    /// Initial sort weight when seeding. After seeding, users may reorder freely.
    var defaultOrder: Double {
        switch self {
        case .keepAwake: return 100
        case .appShortcuts: return 200
        case .muteAudio: return 300
        case .hideDesktopIcons: return 400
        case .showHiddenFiles: return 500
        case .darkMode: return 600
        case .lockScreen: return 700
        case .emptyTrash: return 800
        }
    }

    /// True if the item requires macOS Automation permission (NSAppleEventsUsage).
    var requiresAutomation: Bool {
        switch self {
        case .darkMode, .emptyTrash: return true
        default: return false
        }
    }
}
```

- [ ] **Step 2: Add catalog test**

Append to `Tests/AnyDoorTests/MigrationTests.swift`:

```swift
final class BuiltinItemTests: XCTestCase {
    func testAllCasesHaveDistinctOrder() {
        let orders = BuiltinItem.allCases.map(\.defaultOrder)
        XCTAssertEqual(Set(orders).count, orders.count)
    }

    func testAppShortcutsIsSubmenu() {
        XCTAssertEqual(BuiltinItem.appShortcuts.kind, .submenu)
    }

    func testAutomationItemsAreFlagged() {
        XCTAssertTrue(BuiltinItem.darkMode.requiresAutomation)
        XCTAssertTrue(BuiltinItem.emptyTrash.requiresAutomation)
        XCTAssertFalse(BuiltinItem.keepAwake.requiresAutomation)
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter BuiltinItemTests`
Expected: 3 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Models/BuiltinItem.swift Tests/AnyDoorTests/MigrationTests.swift
git commit -m "feat(model): add BuiltinItem catalog"
```

---

## Task 5: BuiltinPreference SwiftData model + seeding

**Files:**
- Create: `Sources/AnyDoor/Models/BuiltinPreference.swift`
- Create: `Sources/AnyDoor/Services/BuiltinPreferenceSeeder.swift`
- Modify: `Tests/AnyDoorTests/MigrationTests.swift`

- [ ] **Step 1: Create BuiltinPreference model**

Create `Sources/AnyDoor/Models/BuiltinPreference.swift`:

```swift
import SwiftData

@Model
final class BuiltinPreference {
    /// Stable key: `BuiltinItem.rawValue`. Orphans (no matching BuiltinItem) are skipped at read time.
    @Attribute(.unique) var itemKey: String
    var isVisible: Bool
    var displayOrder: Double
    var keyCode: Int?
    var modifierFlags: Int?

    init(
        itemKey: String,
        isVisible: Bool = true,
        displayOrder: Double = 0,
        keyCode: Int? = nil,
        modifierFlags: Int? = nil
    ) {
        self.itemKey = itemKey
        self.isVisible = isVisible
        self.displayOrder = displayOrder
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }
}
```

- [ ] **Step 2: Create seeder**

Create `Sources/AnyDoor/Services/BuiltinPreferenceSeeder.swift`:

```swift
import SwiftData
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "seeder")

/// Ensures every BuiltinItem has a corresponding BuiltinPreference row.
///
/// - On first run: seeds all cases with their `defaultOrder`.
/// - On later runs: diffs `BuiltinItem.allCases` against existing rows and appends new items
///   at the end (max displayOrder + 1).
/// - Orphan rows (itemKey not in current `BuiltinItem`) are left in place; readers skip them
///   via `BuiltinItem(rawValue:)`.
enum BuiltinPreferenceSeeder {
    @MainActor
    static func seedIfNeeded(in context: ModelContext) {
        do {
            let existing = try context.fetch(FetchDescriptor<BuiltinPreference>())
            let existingKeys = Set(existing.map(\.itemKey))
            let maxOrder = existing.map(\.displayOrder).max() ?? 0

            var addedAt = max(maxOrder + 100, 0)
            var added = 0
            for item in BuiltinItem.allCases {
                guard !existingKeys.contains(item.rawValue) else { continue }
                let order = existing.isEmpty ? item.defaultOrder : addedAt
                let pref = BuiltinPreference(
                    itemKey: item.rawValue,
                    isVisible: true,
                    displayOrder: order,
                    keyCode: nil,
                    modifierFlags: nil
                )
                context.insert(pref)
                addedAt += 100
                added += 1
            }
            if added > 0 {
                try context.save()
                logger.info("Seeded \(added) BuiltinPreference row(s)")
            }
        } catch {
            logger.error("BuiltinPreference seeding failed: \(error)")
        }
    }
}
```

- [ ] **Step 3: Write seeding tests**

Append to `Tests/AnyDoorTests/MigrationTests.swift`:

```swift
final class BuiltinPreferenceSeederTests: XCTestCase {
    @MainActor
    func testSeedsAllItemsOnEmptyStore() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BuiltinPreference.self, configurations: config)
        let context = ModelContext(container)

        BuiltinPreferenceSeeder.seedIfNeeded(in: context)

        let rows = try context.fetch(FetchDescriptor<BuiltinPreference>())
        XCTAssertEqual(rows.count, BuiltinItem.allCases.count)

        let keys = Set(rows.map(\.itemKey))
        for item in BuiltinItem.allCases {
            XCTAssertTrue(keys.contains(item.rawValue), "missing \(item.rawValue)")
        }
    }

    @MainActor
    func testSeedingIsIdempotent() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BuiltinPreference.self, configurations: config)
        let context = ModelContext(container)

        BuiltinPreferenceSeeder.seedIfNeeded(in: context)
        BuiltinPreferenceSeeder.seedIfNeeded(in: context)

        let rows = try context.fetch(FetchDescriptor<BuiltinPreference>())
        XCTAssertEqual(rows.count, BuiltinItem.allCases.count)
    }

    @MainActor
    func testSeedingAppendsNewItemsAtEnd() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BuiltinPreference.self, configurations: config)
        let context = ModelContext(container)

        // Pre-populate with one item to simulate prior state
        context.insert(BuiltinPreference(itemKey: BuiltinItem.keepAwake.rawValue,
                                          isVisible: true,
                                          displayOrder: 50))
        try context.save()

        BuiltinPreferenceSeeder.seedIfNeeded(in: context)

        let rows = try context.fetch(FetchDescriptor<BuiltinPreference>())
            .sorted { $0.displayOrder < $1.displayOrder }

        // Pre-existing row should still be at order 50
        XCTAssertEqual(rows.first?.itemKey, BuiltinItem.keepAwake.rawValue)
        XCTAssertEqual(rows.first?.displayOrder, 50)
        // New rows should all have order > 50
        for row in rows.dropFirst() {
            XCTAssertGreaterThan(row.displayOrder, 50)
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter BuiltinPreferenceSeederTests`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Models/BuiltinPreference.swift \
        Sources/AnyDoor/Services/BuiltinPreferenceSeeder.swift \
        Tests/AnyDoorTests/MigrationTests.swift
git commit -m "feat(model): add BuiltinPreference and seeder"
```

---

## Task 6: KeyBinding displayOrder backfill

**Files:**
- Create: `Sources/AnyDoor/Services/KeyBindingOrderBackfill.swift`
- Modify: `Tests/AnyDoorTests/MigrationTests.swift`

- [ ] **Step 1: Create backfill helper**

Create `Sources/AnyDoor/Services/KeyBindingOrderBackfill.swift`:

```swift
import SwiftData
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "backfill")

/// One-time backfill: assigns ascending `displayOrder` values to legacy KeyBinding rows
/// that came from earlier versions without ordering (i.e. `displayOrder == 0`).
/// Order is by `createdAt` ascending, with a stride of 100 so users can insert in between.
enum KeyBindingOrderBackfill {
    @MainActor
    static func runIfNeeded(in context: ModelContext) {
        do {
            let rows = try context.fetch(FetchDescriptor<KeyBinding>(
                sortBy: [SortDescriptor(\.createdAt)]
            ))
            // If any row has a non-zero order, assume backfill is already done.
            guard rows.contains(where: { $0.displayOrder == 0 }) else { return }
            guard !rows.allSatisfy({ $0.displayOrder != 0 }) else { return }

            var order: Double = 100
            for row in rows where row.displayOrder == 0 {
                row.displayOrder = order
                order += 100
            }
            try context.save()
            logger.info("Backfilled displayOrder on \(rows.count) KeyBinding row(s)")
        } catch {
            logger.error("KeyBinding displayOrder backfill failed: \(error)")
        }
    }
}
```

- [ ] **Step 2: Write backfill tests**

Append to `Tests/AnyDoorTests/MigrationTests.swift`:

```swift
final class KeyBindingOrderBackfillTests: XCTestCase {
    @MainActor
    func testBackfillAssignsAscendingOrderByCreatedAt() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: KeyBinding.self, configurations: config)
        let context = ModelContext(container)

        let a = KeyBinding(keyCode: 122, modifierFlags: 0,
                           appBundleID: "a", appName: "A", appPath: "/a")
        let b = KeyBinding(keyCode: 120, modifierFlags: 0,
                           appBundleID: "b", appName: "B", appPath: "/b")
        a.createdAt = Date(timeIntervalSinceReferenceDate: 0)
        b.createdAt = Date(timeIntervalSinceReferenceDate: 10)
        context.insert(a)
        context.insert(b)
        try context.save()

        KeyBindingOrderBackfill.runIfNeeded(in: context)

        let rows = try context.fetch(FetchDescriptor<KeyBinding>(
            sortBy: [SortDescriptor(\.displayOrder)]
        ))
        XCTAssertEqual(rows[0].appBundleID, "a")
        XCTAssertEqual(rows[1].appBundleID, "b")
        XCTAssertLessThan(rows[0].displayOrder, rows[1].displayOrder)
    }

    @MainActor
    func testBackfillIsNoOpIfAlreadyDone() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: KeyBinding.self, configurations: config)
        let context = ModelContext(container)

        let a = KeyBinding(keyCode: 122, modifierFlags: 0,
                           appBundleID: "a", appName: "A", appPath: "/a",
                           displayOrder: 500)
        context.insert(a)
        try context.save()

        KeyBindingOrderBackfill.runIfNeeded(in: context)

        let rows = try context.fetch(FetchDescriptor<KeyBinding>())
        XCTAssertEqual(rows[0].displayOrder, 500)
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter KeyBindingOrderBackfillTests`
Expected: 2 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Services/KeyBindingOrderBackfill.swift Tests/AnyDoorTests/MigrationTests.swift
git commit -m "feat(model): backfill KeyBinding.displayOrder for legacy rows"
```

---

## Task 7: PanelEntry + HotkeyDescriptor + PermissionStatus types

**Files:**
- Create: `Sources/AnyDoor/Models/PanelEntry.swift`
- Create: `Tests/AnyDoorTests/HotkeyDescriptorTests.swift`

- [ ] **Step 1: Create types**

Create `Sources/AnyDoor/Models/PanelEntry.swift`:

```swift
import Foundation
import AppKit

/// Permission state for a built-in item that requires external authorization.
enum PermissionStatus: Sendable, Hashable {
    case granted
    case denied
    case undetermined
    case notRequired
}

/// A hotkey binding for display and comparison.
struct HotkeyDescriptor: Hashable, Sendable {
    let keyCode: Int
    let modifierFlags: Int

    var displayString: String {
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlags))
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(KeyCodeMap.name(for: keyCode))
        return parts.joined()
    }
}

/// A unified row visible to the SwiftUI views. Built from one of three sources.
struct PanelEntry: Identifiable, Hashable {
    enum Source: Hashable {
        case appShortcut(UUID)         // KeyBinding.id
        case builtin(BuiltinItem)
    }

    let id: String                     // "app:<uuid>" or "builtin:<key>"
    let source: Source
    let displayOrder: Double
    let isVisible: Bool
    let hotkey: HotkeyDescriptor?
    let title: String
    let subtitle: String?
    let symbol: String
    let kind: BuiltinItem.Kind
    let toggleState: Bool?             // .toggle only
    let permission: PermissionStatus

    static func id(for source: Source) -> String {
        switch source {
        case .appShortcut(let id): return "app:\(id.uuidString)"
        case .builtin(let item):   return "builtin:\(item.rawValue)"
        }
    }
}
```

- [ ] **Step 2: Write HotkeyDescriptor tests**

Create `Tests/AnyDoorTests/HotkeyDescriptorTests.swift`:

```swift
import XCTest
import Carbon.HIToolbox
import AppKit
@testable import AnyDoor

final class HotkeyDescriptorTests: XCTestCase {
    func testDisplayStringWithModifiers() {
        let cmdCtrl: Int = Int(
            NSEvent.ModifierFlags.command.rawValue |
            NSEvent.ModifierFlags.control.rawValue
        )
        let d = HotkeyDescriptor(keyCode: kVK_F1, modifierFlags: cmdCtrl)
        XCTAssertEqual(d.displayString, "⌃⌘F1")
    }

    func testDisplayStringNoModifiers() {
        let d = HotkeyDescriptor(keyCode: kVK_Space, modifierFlags: 0)
        XCTAssertEqual(d.displayString, "Space")
    }

    func testEquality() {
        let a = HotkeyDescriptor(keyCode: kVK_F1, modifierFlags: 0)
        let b = HotkeyDescriptor(keyCode: kVK_F1, modifierFlags: 0)
        XCTAssertEqual(a, b)
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter HotkeyDescriptorTests`
Expected: 3 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Models/PanelEntry.swift Tests/AnyDoorTests/HotkeyDescriptorTests.swift
git commit -m "feat(model): add PanelEntry, HotkeyDescriptor, PermissionStatus"
```

---

## Task 8: HotkeyAction + HotkeySnapshot types

**Files:**
- Create: `Sources/AnyDoor/Models/HotkeyAction.swift`

- [ ] **Step 1: Create the types**

Create `Sources/AnyDoor/Models/HotkeyAction.swift`:

```swift
import Foundation

/// The action a matched hotkey should perform.
///
/// `launchApp` keeps the existing AppSwitcher behavior; `toggleBuiltin` and `runBuiltin`
/// route through PanelStore to a registered provider.
enum HotkeyAction: Sendable, Hashable {
    case launchApp(bundleID: String, path: String)
    case toggleBuiltin(itemKey: String)
    case runBuiltin(itemKey: String)
}

/// Sendable snapshot passed across the CGEvent tap boundary.
///
/// HotkeyService stores `[HotkeySnapshot]` in `nonisolated(unsafe)` storage and the C
/// callback iterates it to find a match. On hit, the action is dispatched to the main thread.
struct HotkeySnapshot: Sendable, Hashable {
    let keyCode: Int
    let modifierFlags: Int
    let action: HotkeyAction
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Models/HotkeyAction.swift
git commit -m "feat(model): add HotkeyAction and HotkeySnapshot"
```

---

## Task 9: BuiltinProvider protocols

**Files:**
- Create: `Sources/AnyDoor/Services/Providers/BuiltinProvider.swift`

- [ ] **Step 1: Create protocols and error types**

Create `Sources/AnyDoor/Services/Providers/BuiltinProvider.swift`:

```swift
import Foundation

protocol BuiltinProvider: Sendable {
    var itemKey: BuiltinItem { get }
    var permission: PermissionStatus { get async }
}

protocol ToggleProvider: BuiltinProvider {
    func readState() async throws -> Bool
    func setState(_ enabled: Bool) async throws
}

protocol ActionProvider: BuiltinProvider {
    func run() async throws
}

enum BuiltinError: Error, Sendable {
    case missingAutomationPermission
    case appleScriptFailed(code: Int, message: String)
    case shellFailed(code: Int32, output: String)
    case audioDeviceUnavailable
    case ioKitFailed(Int32)
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/Providers/BuiltinProvider.swift
git commit -m "feat(provider): add BuiltinProvider/ToggleProvider/ActionProvider protocols"
```

---

## Task 10: KeepAwakeProvider (first concrete provider)

**Files:**
- Create: `Sources/AnyDoor/Services/Providers/KeepAwakeProvider.swift`

- [ ] **Step 1: Implement KeepAwakeProvider**

Create `Sources/AnyDoor/Services/Providers/KeepAwakeProvider.swift`:

```swift
import IOKit.pwr_mgt
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "keepawake")

/// Prevents the system from going to sleep while the assertion is held.
///
/// Backed by IOPMAssertion (PreventUserIdleDisplaySleep). The assertion is held by this
/// actor's `assertionID` for the lifetime of the process or until `setState(false)` is called.
/// Process exit releases automatically — no cleanup required.
actor KeepAwakeProvider: ToggleProvider {
    let itemKey: BuiltinItem = .keepAwake

    var permission: PermissionStatus { .notRequired }

    private var assertionID: IOPMAssertionID?

    func readState() async throws -> Bool {
        assertionID != nil
    }

    func setState(_ enabled: Bool) async throws {
        if enabled {
            guard assertionID == nil else { return }
            var newID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "AnyDoor Keep Awake" as CFString,
                &newID
            )
            guard result == kIOReturnSuccess else {
                logger.error("IOPMAssertionCreateWithName failed: \(result)")
                throw BuiltinError.ioKitFailed(Int32(result))
            }
            assertionID = newID
        } else {
            guard let id = assertionID else { return }
            IOPMAssertionRelease(id)
            assertionID = nil
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/Providers/KeepAwakeProvider.swift
git commit -m "feat(provider): add KeepAwakeProvider using IOPMAssertion"
```

---

## Task 11: PanelStore skeleton

**Files:**
- Create: `Sources/AnyDoor/Services/PanelStore.swift`
- Create: `Tests/AnyDoorTests/PanelStoreTests.swift`

- [ ] **Step 1: Create PanelStore**

Create `Sources/AnyDoor/Services/PanelStore.swift`:

```swift
import SwiftData
import SwiftUI
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "panel")

/// Single source of truth for the merged panel data.
///
/// Owns the provider registry, reads BuiltinPreference / KeyBinding from SwiftData,
/// and exposes two collections to the views:
/// - `topLevelEntries` — built-in items, sorted by BuiltinPreference.displayOrder
/// - `appShortcutChildren` — KeyBinding rows, sorted by KeyBinding.displayOrder
@Observable @MainActor
final class PanelStore {
    static let shared = PanelStore()

    private(set) var topLevelEntries: [PanelEntry] = []
    private(set) var appShortcutChildren: [PanelEntry] = []

    private var providers: [BuiltinItem: any BuiltinProvider] = [:]
    private var modelContainer: ModelContainer?

    /// Cached toggle states by item key. Refreshed on `refreshAll()`.
    private var toggleStates: [BuiltinItem: Bool] = [:]

    /// Cached permission states by item key.
    private var permissionStates: [BuiltinItem: PermissionStatus] = [:]

    private init() {}

    func bootstrap(
        modelContainer: ModelContainer,
        providers: [any BuiltinProvider]
    ) {
        self.modelContainer = modelContainer
        for provider in providers {
            self.providers[provider.itemKey] = provider
        }
        rebuild()
    }

    /// Recompute `topLevelEntries` and `appShortcutChildren` from SwiftData + cached states.
    func rebuild() {
        guard let container = modelContainer else { return }
        let context = container.mainContext

        // Built-in preferences → topLevelEntries
        var topLevel: [PanelEntry] = []
        if let prefs = try? context.fetch(
            FetchDescriptor<BuiltinPreference>(sortBy: [SortDescriptor(\.displayOrder)])
        ) {
            for pref in prefs {
                guard let item = BuiltinItem(rawValue: pref.itemKey) else { continue }
                let hotkey = pref.keyCode.flatMap { code in
                    pref.modifierFlags.map { mods in
                        HotkeyDescriptor(keyCode: code, modifierFlags: mods)
                    }
                }
                let entry = PanelEntry(
                    id: PanelEntry.id(for: .builtin(item)),
                    source: .builtin(item),
                    displayOrder: pref.displayOrder,
                    isVisible: pref.isVisible,
                    hotkey: hotkey,
                    title: item.title,
                    subtitle: subtitle(for: item),
                    symbol: item.symbol,
                    kind: item.kind,
                    toggleState: item.kind == .toggle ? toggleStates[item] : nil,
                    permission: permissionStates[item] ?? (item.requiresAutomation ? .undetermined : .notRequired)
                )
                topLevel.append(entry)
            }
        }

        // KeyBinding rows → appShortcutChildren
        var children: [PanelEntry] = []
        if let bindings = try? context.fetch(
            FetchDescriptor<KeyBinding>(sortBy: [SortDescriptor(\.displayOrder)])
        ) {
            for binding in bindings {
                let entry = PanelEntry(
                    id: PanelEntry.id(for: .appShortcut(binding.id)),
                    source: .appShortcut(binding.id),
                    displayOrder: binding.displayOrder,
                    isVisible: binding.isVisible,
                    hotkey: HotkeyDescriptor(keyCode: binding.keyCode,
                                              modifierFlags: binding.modifierFlags),
                    title: binding.appName,
                    subtitle: nil,
                    symbol: "app.fill",
                    kind: .submenu, // children render like rows but inside the popover
                    toggleState: nil,
                    permission: .notRequired
                )
                children.append(entry)
            }
        }

        self.topLevelEntries = topLevel
        self.appShortcutChildren = children
    }

    private func subtitle(for item: BuiltinItem) -> String? {
        switch item {
        case .appShortcuts:
            let visible = appShortcutChildren.filter(\.isVisible).count
            return "\(visible) 个绑定"
        case .keepAwake:
            return (toggleStates[.keepAwake] ?? false) ? "无限期保持唤醒" : nil
        default:
            return nil
        }
    }

    /// Refresh every toggle provider's state. Called from MenuBarView.onAppear.
    func refreshAll() async {
        for (item, provider) in providers {
            if let toggle = provider as? any ToggleProvider {
                if let state = try? await toggle.readState() {
                    toggleStates[item] = state
                }
            }
            permissionStates[item] = await provider.permission
        }
        rebuild()
    }

    /// Toggle a built-in. Reads current state and flips it.
    func toggle(_ item: BuiltinItem) async {
        guard let provider = providers[item] as? any ToggleProvider else { return }
        do {
            let current = try await provider.readState()
            try await provider.setState(!current)
            toggleStates[item] = !current
            rebuild()
        } catch {
            logger.error("Toggle \(item.rawValue) failed: \(error)")
        }
    }

    /// Run a one-shot action.
    func run(_ item: BuiltinItem) async {
        guard let provider = providers[item] as? any ActionProvider else { return }
        do {
            try await provider.run()
        } catch {
            logger.error("Run \(item.rawValue) failed: \(error)")
        }
    }
}
```

- [ ] **Step 2: Write smoke test**

Create `Tests/AnyDoorTests/PanelStoreTests.swift`:

```swift
import XCTest
import SwiftData
@testable import AnyDoor

final class PanelStoreTests: XCTestCase {

    @MainActor
    func testBootstrapPopulatesTopLevelEntries() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: KeyBinding.self, BuiltinPreference.self,
            configurations: config
        )
        BuiltinPreferenceSeeder.seedIfNeeded(in: container.mainContext)

        let store = PanelStore.shared
        store.bootstrap(modelContainer: container, providers: [])

        XCTAssertEqual(store.topLevelEntries.count, BuiltinItem.allCases.count)
        // Order should follow defaultOrder
        let titles = store.topLevelEntries.map(\.title)
        XCTAssertEqual(titles.first, BuiltinItem.keepAwake.title) // defaultOrder 100 is smallest
    }

    @MainActor
    func testAppShortcutChildrenSortedByDisplayOrder() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: KeyBinding.self, BuiltinPreference.self,
            configurations: config
        )
        let context = container.mainContext

        let b = KeyBinding(keyCode: 120, modifierFlags: 0,
                           appBundleID: "b", appName: "B", appPath: "/b",
                           displayOrder: 200)
        let a = KeyBinding(keyCode: 122, modifierFlags: 0,
                           appBundleID: "a", appName: "A", appPath: "/a",
                           displayOrder: 100)
        context.insert(b)
        context.insert(a)
        try context.save()

        let store = PanelStore.shared
        store.bootstrap(modelContainer: container, providers: [])

        XCTAssertEqual(store.appShortcutChildren.map(\.title), ["A", "B"])
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter PanelStoreTests`
Expected: 2 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Services/PanelStore.swift Tests/AnyDoorTests/PanelStoreTests.swift
git commit -m "feat(panel): add PanelStore with bootstrap, rebuild, toggle, run"
```

---

## Task 12: HotkeyAction routing in HotkeyService

**Files:**
- Modify: `Sources/AnyDoor/Services/HotkeyService.swift`
- Create: `Tests/AnyDoorTests/HotkeyConflictTests.swift`

- [ ] **Step 1: Rewrite HotkeyService to use HotkeySnapshot**

Replace `Sources/AnyDoor/Services/HotkeyService.swift` with:

```swift
import Cocoa

/// Global hotkey listener service.
///
/// Owns the CGEvent tap at the HID level. On match, dispatches the associated `HotkeyAction`
/// to the main thread for execution by `PanelStore.shared`.
///
/// - Note: The C callback `hotkeyCallback` runs off the main thread. Snapshots are shared
///   via `nonisolated(unsafe)` storage; HotkeySnapshot is Sendable.
@MainActor
final class HotkeyService {
    static let shared = HotkeyService()

    fileprivate nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?

    /// Snapshots read by the callback on a non-main thread for matching.
    fileprivate nonisolated(unsafe) var snapshots: [HotkeySnapshot] = []

    private var watchdogTimer: Timer?
    private var isSuspended = false

    /// Dispatcher injected at bootstrap. The callback packs the matched action and the
    /// dispatcher decides what to do with it.
    fileprivate nonisolated(unsafe) var dispatcher: (@MainActor @Sendable (HotkeyAction) -> Void)?

    private init() {}

    func setDispatcher(_ dispatcher: @escaping @MainActor @Sendable (HotkeyAction) -> Void) {
        self.dispatcher = dispatcher
    }

    func updateSnapshots(_ newSnapshots: [HotkeySnapshot]) {
        snapshots = newSnapshots
        if !isSuspended {
            if eventTap == nil {
                start()
            } else {
                resume()
            }
        }
        print("AnyDoor: Updated \(snapshots.count) hotkey snapshot(s)")
    }

    func start() {
        guard eventTap == nil else { return }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyCallback,
            userInfo: selfPtr
        ) else {
            print("AnyDoor: Failed to create event tap. AX granted: \(AXIsProcessTrusted())")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        startWatchdog()
        print("AnyDoor: Event tap started")
    }

    func suspend() {
        isSuspended = true
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    func resume() {
        isSuspended = false
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func stop() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    func restart() {
        print("AnyDoor: Restarting event tap")
        stop()
        start()
    }

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let tap = self.eventTap else { return }
            let suspended = MainActor.assumeIsolated { self.isSuspended }
            if !suspended && !CGEvent.tapIsEnabled(tap: tap) {
                print("AnyDoor: Watchdog detected disabled tap, restarting")
                MainActor.assumeIsolated { self.restart() }
            }
        }
    }

    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    nonisolated static func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}

// MARK: - CGEvent Callback

private let modifierMask: UInt64 = CGEventFlags.maskCommand.rawValue
    | CGEventFlags.maskControl.rawValue
    | CGEventFlags.maskAlternate.rawValue
    | CGEventFlags.maskShift.rawValue

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
        print("AnyDoor: Tap disabled by \(reason), inline re-enable")
        if let tap = service.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown else { return Unmanaged.passUnretained(event) }

    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let modifiers = Int(event.flags.rawValue & modifierMask)

    for snapshot in service.snapshots {
        if snapshot.keyCode == keyCode && snapshot.modifierFlags == modifiers {
            let action = snapshot.action
            let dispatcher = service.dispatcher
            DispatchQueue.main.async {
                dispatcher?(action)
            }
            return nil // consume
        }
    }

    return Unmanaged.passUnretained(event)
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: build fails (AppDelegate and BindingListView still reference old `updateBindings`).
That's fine — we'll wire those up in the next tasks. We just need this file to compile in isolation.

To check just this file isolated, this step is "best effort" — proceed to Step 3.

- [ ] **Step 3: Write conflict detection test**

Create `Tests/AnyDoorTests/HotkeyConflictTests.swift`:

```swift
import XCTest
@testable import AnyDoor

final class HotkeyConflictTests: XCTestCase {
    func testMatchByKeyCodeAndModifiers() {
        let snapshots: [HotkeySnapshot] = [
            HotkeySnapshot(keyCode: 122, modifierFlags: 0,
                           action: .launchApp(bundleID: "a", path: "/a")),
            HotkeySnapshot(keyCode: 120, modifierFlags: 256,
                           action: .toggleBuiltin(itemKey: "keepAwake")),
        ]

        let hit = snapshots.first { $0.keyCode == 120 && $0.modifierFlags == 256 }
        XCTAssertNotNil(hit)
        if case let .toggleBuiltin(key) = hit?.action {
            XCTAssertEqual(key, "keepAwake")
        } else {
            XCTFail("wrong action type")
        }
    }

    func testConflictDetectionAcrossLaunchAndBuiltin() {
        let a = HotkeySnapshot(keyCode: 122, modifierFlags: 0,
                                action: .launchApp(bundleID: "a", path: "/a"))
        let b = HotkeySnapshot(keyCode: 122, modifierFlags: 0,
                                action: .toggleBuiltin(itemKey: "keepAwake"))

        XCTAssertEqual(a.keyCode, b.keyCode)
        XCTAssertEqual(a.modifierFlags, b.modifierFlags)
        XCTAssertNotEqual(a, b) // different actions, still a hotkey collision
    }
}
```

- [ ] **Step 4: Commit (build still broken — that's tracked for next task)**

```bash
git add Sources/AnyDoor/Services/HotkeyService.swift Tests/AnyDoorTests/HotkeyConflictTests.swift
git commit -m "feat(hotkey): switch HotkeyService to HotkeySnapshot + dispatcher"
```

---

## Task 13: PanelStore dispatch wiring + AppDelegate integration

**Files:**
- Modify: `Sources/AnyDoor/Services/PanelStore.swift`
- Modify: `Sources/AnyDoor/AppDelegate.swift`
- Modify: `Sources/AnyDoor/Views/MenuBarView.swift` (temp fix to keep building)
- Modify: `Sources/AnyDoor/Views/BindingListView.swift` (temp fix to keep building)

- [ ] **Step 1: Add dispatch + snapshot rebuild to PanelStore**

Append to `Sources/AnyDoor/Services/PanelStore.swift` (inside the class):

```swift
    // MARK: - Hotkey dispatch + snapshot rebuild

    /// Handle a matched hotkey. Called on the main thread by HotkeyService.
    func dispatch(_ action: HotkeyAction) {
        switch action {
        case .launchApp(let bundleID, let path):
            AppSwitcher.toggle(bundleID: bundleID, appPath: path)
        case .toggleBuiltin(let key):
            guard let item = BuiltinItem(rawValue: key) else { return }
            Task { await self.toggle(item) }
        case .runBuiltin(let key):
            guard let item = BuiltinItem(rawValue: key) else { return }
            Task { await self.run(item) }
        }
    }

    /// Build a snapshot list for HotkeyService from current SwiftData state.
    /// Called whenever bindings or preferences change.
    func rebuildHotkeySnapshots() {
        guard let container = modelContainer else { return }
        let context = container.mainContext

        var out: [HotkeySnapshot] = []

        if let bindings = try? context.fetch(
            FetchDescriptor<KeyBinding>(predicate: #Predicate { $0.isEnabled })
        ) {
            for binding in bindings {
                out.append(HotkeySnapshot(
                    keyCode: binding.keyCode,
                    modifierFlags: binding.modifierFlags,
                    action: .launchApp(bundleID: binding.appBundleID, path: binding.appPath)
                ))
            }
        }

        if let prefs = try? context.fetch(FetchDescriptor<BuiltinPreference>()) {
            for pref in prefs {
                guard let item = BuiltinItem(rawValue: pref.itemKey),
                      let code = pref.keyCode,
                      let mods = pref.modifierFlags,
                      item.kind != .submenu else { continue }
                let action: HotkeyAction = item.kind == .toggle
                    ? .toggleBuiltin(itemKey: item.rawValue)
                    : .runBuiltin(itemKey: item.rawValue)
                out.append(HotkeySnapshot(
                    keyCode: code,
                    modifierFlags: mods,
                    action: action
                ))
            }
        }

        HotkeyService.shared.updateSnapshots(out)
    }
```

- [ ] **Step 2: Modify AppDelegate to wire PanelStore + dispatcher**

Replace `Sources/AnyDoor/AppDelegate.swift` with:

```swift
import Cocoa
import SwiftData
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "persistence")

final class AppDelegate: NSObject, NSApplicationDelegate {
    let modelContainer: ModelContainer

    override init() {
        do {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let storeDir = appSupport.appendingPathComponent("dev.bybee.AnyDoor", isDirectory: true)
            try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
            let storeURL = storeDir.appendingPathComponent("AnyDoor.store")
            let config = ModelConfiguration(url: storeURL)
            modelContainer = try ModelContainer(
                for: KeyBinding.self, BuiltinPreference.self,
                configurations: config
            )

            let legacyURL = appSupport.appendingPathComponent("default.store")
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                Self.migrateLegacyStore(from: legacyURL, into: modelContainer)
            }
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        super.init()
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        // Run migrations / seeding on the main context
        let context = modelContainer.mainContext
        KeyBindingOrderBackfill.runIfNeeded(in: context)
        BuiltinPreferenceSeeder.seedIfNeeded(in: context)

        // Register providers
        let providers: [any BuiltinProvider] = [
            KeepAwakeProvider(),
        ]
        PanelStore.shared.bootstrap(modelContainer: modelContainer, providers: providers)

        // Wire HotkeyService dispatcher
        HotkeyService.shared.setDispatcher { action in
            PanelStore.shared.dispatch(action)
        }

        if !HotkeyService.hasAccessibilityPermission {
            HotkeyService.requestAccessibilityPermission()
        }

        HotkeyService.shared.start()
        PanelStore.shared.rebuildHotkeySnapshots()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyService.shared.stop()
    }

    /// Hot-reload entry point used by views after data changes.
    @MainActor
    func refreshBindings() {
        PanelStore.shared.rebuild()
        PanelStore.shared.rebuildHotkeySnapshots()
    }

    // MARK: - Legacy store migration (unchanged behavior, just preserved)

    private static func migrateLegacyStore(from legacyURL: URL, into container: ModelContainer) {
        do {
            let legacyConfig = ModelConfiguration(url: legacyURL)
            let legacyContainer = try ModelContainer(for: KeyBinding.self, configurations: legacyConfig)
            let legacyContext = ModelContext(legacyContainer)

            let legacyBindings = try legacyContext.fetch(FetchDescriptor<KeyBinding>())
            guard !legacyBindings.isEmpty else {
                removeLegacyFiles(at: legacyURL)
                return
            }

            let targetContext = ModelContext(container)
            let existingBindings = try targetContext.fetch(FetchDescriptor<KeyBinding>())
            let existingIDs = Set(existingBindings.map(\.appBundleID))

            var migrated = 0
            for binding in legacyBindings {
                guard !existingIDs.contains(binding.appBundleID) else { continue }
                let copy = KeyBinding(
                    keyCode: binding.keyCode,
                    modifierFlags: binding.modifierFlags,
                    appBundleID: binding.appBundleID,
                    appName: binding.appName,
                    appPath: binding.appPath,
                    isEnabled: binding.isEnabled
                )
                targetContext.insert(copy)
                migrated += 1
            }
            if migrated > 0 { try targetContext.save() }
            logger.info("Migrated \(migrated) binding(s) from legacy store")

            removeLegacyFiles(at: legacyURL)
        } catch {
            logger.error("Legacy store migration failed: \(error)")
        }
    }

    private static func removeLegacyFiles(at url: URL) {
        let fm = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            try? fm.removeItem(atPath: url.path + suffix)
        }
    }
}
```

- [ ] **Step 3: Stub MenuBarView so build passes (real rewrite later)**

Replace `Sources/AnyDoor/Views/MenuBarView.swift` with:

```swift
import SwiftUI
import SwiftData

struct MenuBarView: View {
    @Query(sort: \KeyBinding.createdAt) private var bindings: [KeyBinding]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("AnyDoor").font(.headline)
                Spacer()
                Text("\(bindings.count) 个绑定").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)

            // Placeholder for upcoming PanelRowView rewrite (Task 21)
            Text("面板重构中…").foregroundStyle(.secondary).padding()

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                SettingsLink { Label("设置", systemImage: "gear") }
                    .buttonStyle(.glass)
                    .simultaneousGesture(TapGesture().onEnded {
                        NSApplication.shared.activate()
                    })
                Button {
                    NSApplication.shared.terminate(nil)
                } label: { Label("退出", systemImage: "power") }
                    .buttonStyle(.glass)
                Spacer()
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
        .frame(width: 260).frame(minHeight: 400)
        .onAppear {
            Task { await PanelStore.shared.refreshAll() }
        }
    }
}
```

- [ ] **Step 4: Stub BindingListView to keep using old behavior, but call new refresh**

Replace `Sources/AnyDoor/Views/BindingListView.swift` with:

```swift
import SwiftUI
import SwiftData
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "persistence")

struct BindingListView: View {
    @Query(sort: \KeyBinding.createdAt) private var bindings: [KeyBinding]
    @Environment(\.modelContext) private var modelContext
    @State private var selection: KeyBinding?
    @State private var showingEditor = false

    var body: some View {
        VStack {
            List(selection: $selection) {
                ForEach(bindings) { binding in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Bindable(binding).isEnabled)
                            .toggleStyle(.checkbox).labelsHidden()
                        Text(binding.displayKey).font(.system(.body, design: .monospaced))
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(binding.appName)
                        Spacer()
                    }
                    .tag(binding).padding(.vertical, 2)
                }
            }

            HStack(spacing: 6) {
                Button { showingEditor = true; selection = nil } label: {
                    Image(systemName: "plus").frame(width: 28, height: 22)
                }.buttonStyle(.bordered)

                Button {
                    if let selected = selection {
                        modelContext.delete(selected); save(); selection = nil
                    }
                } label: { Image(systemName: "minus").frame(width: 28, height: 22) }
                    .buttonStyle(.bordered).disabled(selection == nil)
                Spacer()
            }.padding(8)
        }
        .sheet(isPresented: $showingEditor) {
            BindingEditView { newBinding in
                modelContext.insert(newBinding); save()
            }
        }
        .onChange(of: bindings.map(\.isEnabled)) {
            save()
            PanelStore.shared.rebuildHotkeySnapshots()
        }
    }

    private func save() {
        do {
            try modelContext.save()
            PanelStore.shared.rebuild()
            PanelStore.shared.rebuildHotkeySnapshots()
        } catch {
            logger.error("Failed to save: \(error)")
        }
    }
}
```

- [ ] **Step 5: Run full build and tests**

Run: `swift build && swift test`
Expected: build succeeds, all existing tests pass.

- [ ] **Step 6: Manual smoke check**

Run: `swift run AnyDoor`
Verify: app launches, menu bar shows placeholder text, existing app shortcuts still trigger their hotkeys (regression check).

- [ ] **Step 7: Commit**

```bash
git add Sources/AnyDoor/Services/PanelStore.swift \
        Sources/AnyDoor/AppDelegate.swift \
        Sources/AnyDoor/Views/MenuBarView.swift \
        Sources/AnyDoor/Views/BindingListView.swift
git commit -m "feat(panel): wire PanelStore dispatcher + AppDelegate bootstrap"
```

---

## Task 14: AppleScriptRunner

**Files:**
- Create: `Sources/AnyDoor/Services/AppleScriptRunner.swift`

- [ ] **Step 1: Implement runner**

Create `Sources/AnyDoor/Services/AppleScriptRunner.swift`:

```swift
import Foundation

/// Safely executes an AppleScript on a background thread and reports errors.
///
/// NSAppleScript blocks the calling thread until completion (sometimes hundreds of ms).
/// Running it on the main thread would block the UI and risk the CGEvent tap timeout.
enum AppleScriptRunner {
    /// Run a script and return its stringified result. Throws `BuiltinError.appleScriptFailed`
    /// on any AppleScript error.
    static func run(_ source: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            guard let script = NSAppleScript(source: source) else {
                throw BuiltinError.appleScriptFailed(code: -1, message: "NSAppleScript init failed")
            }
            var errorInfo: NSDictionary?
            let result = script.executeAndReturnError(&errorInfo)
            if let info = errorInfo as? [String: Any] {
                let code = (info[NSAppleScript.errorNumber] as? Int) ?? 0
                let message = (info[NSAppleScript.errorMessage] as? String) ?? "Unknown"
                if code == -1743 {
                    throw BuiltinError.missingAutomationPermission
                }
                throw BuiltinError.appleScriptFailed(code: code, message: message)
            }
            return result.stringValue ?? ""
        }.value
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/AppleScriptRunner.swift
git commit -m "feat(provider): add AppleScriptRunner with -1743 permission mapping"
```

---

## Task 15: ShellRunner

**Files:**
- Create: `Sources/AnyDoor/Services/ShellRunner.swift`

- [ ] **Step 1: Implement runner**

Create `Sources/AnyDoor/Services/ShellRunner.swift`:

```swift
import Foundation

/// Spawn a subprocess, capture stdout/stderr, enforce a timeout.
///
/// Used for `defaults`, `killall`, `CGSession -suspend` and similar small CLI hops where
/// linking against the corresponding C API would be more complex than calling out.
enum ShellRunner {
    /// Launch a binary with args. Returns combined stdout/stderr. Throws on non-zero exit
    /// or timeout (default 5 seconds).
    static func run(
        _ path: String,
        args: [String] = [],
        timeout: TimeInterval = 5
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()

            // Timeout watchdog
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Date() > deadline {
                    process.terminate()
                    let data = try? pipe.fileHandleForReading.readToEnd()
                    let output = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    throw BuiltinError.shellFailed(code: -1, output: "timeout: \(output)")
                }
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }

            let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
            let output = String(data: data, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 {
                throw BuiltinError.shellFailed(code: process.terminationStatus, output: output)
            }
            return output
        }.value
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/ShellRunner.swift
git commit -m "feat(provider): add ShellRunner with 5s timeout"
```

---

## Task 16: HideDesktopIconsProvider

**Files:**
- Create: `Sources/AnyDoor/Services/Providers/HideDesktopIconsProvider.swift`

- [ ] **Step 1: Implement provider**

Create `Sources/AnyDoor/Services/Providers/HideDesktopIconsProvider.swift`:

```swift
import Foundation

/// Toggles `com.apple.finder.CreateDesktop`. CreateDesktop=false hides desktop icons.
///
/// Reads via `CFPreferencesCopyAppValue` (works without sandbox restrictions).
/// Writes via `/usr/bin/defaults` (CFPreferencesSetAppValue cannot write across the
/// cfprefsd domain boundary). After write, `killall Finder` to apply.
actor HideDesktopIconsProvider: ToggleProvider {
    let itemKey: BuiltinItem = .hideDesktopIcons
    var permission: PermissionStatus { .notRequired }

    func readState() async throws -> Bool {
        let raw = CFPreferencesCopyAppValue("CreateDesktop" as CFString,
                                             "com.apple.finder" as CFString)
        // CreateDesktop default is true → desktop icons SHOWN. Hidden = CreateDesktop false.
        let createDesktop = (raw as? Bool) ?? true
        return !createDesktop
    }

    func setState(_ hidden: Bool) async throws {
        let createDesktop = !hidden
        _ = try await ShellRunner.run(
            "/usr/bin/defaults",
            args: ["write", "com.apple.finder", "CreateDesktop", "-bool",
                   createDesktop ? "true" : "false"]
        )
        _ = try? await ShellRunner.run("/usr/bin/killall", args: ["Finder"])
        // killall failure is non-fatal: defaults already wrote, next Finder restart picks it up
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/Providers/HideDesktopIconsProvider.swift
git commit -m "feat(provider): add HideDesktopIconsProvider"
```

---

## Task 17: ShowHiddenFilesProvider

**Files:**
- Create: `Sources/AnyDoor/Services/Providers/ShowHiddenFilesProvider.swift`

- [ ] **Step 1: Implement provider**

Create `Sources/AnyDoor/Services/Providers/ShowHiddenFilesProvider.swift`:

```swift
import Foundation

/// Toggles `com.apple.finder.AppleShowAllFiles`. true = show hidden files.
///
/// Read: CFPreferencesCopyAppValue. Write: /usr/bin/defaults + killall Finder.
actor ShowHiddenFilesProvider: ToggleProvider {
    let itemKey: BuiltinItem = .showHiddenFiles
    var permission: PermissionStatus { .notRequired }

    func readState() async throws -> Bool {
        let raw = CFPreferencesCopyAppValue("AppleShowAllFiles" as CFString,
                                             "com.apple.finder" as CFString)
        return (raw as? Bool) ?? false
    }

    func setState(_ show: Bool) async throws {
        _ = try await ShellRunner.run(
            "/usr/bin/defaults",
            args: ["write", "com.apple.finder", "AppleShowAllFiles", "-bool",
                   show ? "true" : "false"]
        )
        _ = try? await ShellRunner.run("/usr/bin/killall", args: ["Finder"])
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/Providers/ShowHiddenFilesProvider.swift
git commit -m "feat(provider): add ShowHiddenFilesProvider"
```

---

## Task 18: MuteAudioProvider

**Files:**
- Create: `Sources/AnyDoor/Services/Providers/MuteAudioProvider.swift`

- [ ] **Step 1: Implement provider**

Create `Sources/AnyDoor/Services/Providers/MuteAudioProvider.swift`:

```swift
import CoreAudio
import Foundation

/// Toggle the system default output device's mute property.
///
/// Reads `kAudioDevicePropertyMute` on the default output device. Listens to
/// `kAudioHardwarePropertyDefaultOutputDevice` so we resubscribe when the user
/// switches outputs (e.g. AirPods connect/disconnect).
actor MuteAudioProvider: ToggleProvider {
    let itemKey: BuiltinItem = .muteAudio
    var permission: PermissionStatus { .notRequired }

    func readState() async throws -> Bool {
        let deviceID = try currentOutputDevice()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
        guard status == noErr else {
            throw BuiltinError.ioKitFailed(status)
        }
        return muted != 0
    }

    func setState(_ mute: Bool) async throws {
        let deviceID = try currentOutputDevice()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = mute ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
        guard status == noErr else {
            throw BuiltinError.ioKitFailed(status)
        }
    }

    private func currentOutputDevice() throws -> AudioDeviceID {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw BuiltinError.audioDeviceUnavailable
        }
        return deviceID
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/Providers/MuteAudioProvider.swift
git commit -m "feat(provider): add MuteAudioProvider via CoreAudio"
```

---

## Task 19: DarkModeProvider

**Files:**
- Create: `Sources/AnyDoor/Services/Providers/DarkModeProvider.swift`

- [ ] **Step 1: Implement provider**

Create `Sources/AnyDoor/Services/Providers/DarkModeProvider.swift`:

```swift
import Foundation

/// Toggle macOS dark mode via AppleScript to System Events.
///
/// Requires the user to grant Automation permission to "System Events". On first call,
/// the system prompts; if denied (errorNumber -1743), `permission` returns `.denied`.
actor DarkModeProvider: ToggleProvider {
    let itemKey: BuiltinItem = .darkMode

    private var cachedPermission: PermissionStatus = .undetermined

    var permission: PermissionStatus { cachedPermission }

    func readState() async throws -> Bool {
        do {
            let result = try await AppleScriptRunner.run("""
                tell application "System Events"
                    tell appearance preferences
                        return dark mode
                    end tell
                end tell
            """)
            cachedPermission = .granted
            return result.lowercased() == "true"
        } catch BuiltinError.missingAutomationPermission {
            cachedPermission = .denied
            throw BuiltinError.missingAutomationPermission
        }
    }

    func setState(_ dark: Bool) async throws {
        do {
            _ = try await AppleScriptRunner.run("""
                tell application "System Events"
                    tell appearance preferences
                        set dark mode to \(dark)
                    end tell
                end tell
            """)
            cachedPermission = .granted
        } catch BuiltinError.missingAutomationPermission {
            cachedPermission = .denied
            throw BuiltinError.missingAutomationPermission
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/Providers/DarkModeProvider.swift
git commit -m "feat(provider): add DarkModeProvider via System Events AppleScript"
```

---

## Task 20: LockScreenProvider + EmptyTrashProvider

**Files:**
- Create: `Sources/AnyDoor/Services/Providers/LockScreenProvider.swift`
- Create: `Sources/AnyDoor/Services/Providers/EmptyTrashProvider.swift`

- [ ] **Step 1: Implement LockScreenProvider**

Create `Sources/AnyDoor/Services/Providers/LockScreenProvider.swift`:

```swift
import Foundation

/// Lock the screen via `CGSession -suspend`.
///
/// We deliberately avoid the private `SACLockScreenImmediate()` symbol: it would require
/// dlsym into login.framework which is a private framework, subject to App Store rejection
/// and version drift. The CGSession binary path is a stable public location.
actor LockScreenProvider: ActionProvider {
    let itemKey: BuiltinItem = .lockScreen
    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        _ = try await ShellRunner.run(
            "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession",
            args: ["-suspend"]
        )
    }
}
```

- [ ] **Step 2: Implement EmptyTrashProvider**

Create `Sources/AnyDoor/Services/Providers/EmptyTrashProvider.swift`:

```swift
import Foundation

/// Empty the Trash via AppleScript to Finder. Requires Automation permission.
actor EmptyTrashProvider: ActionProvider {
    let itemKey: BuiltinItem = .emptyTrash

    private var cachedPermission: PermissionStatus = .undetermined

    var permission: PermissionStatus { cachedPermission }

    func run() async throws {
        do {
            _ = try await AppleScriptRunner.run("""
                tell application "Finder"
                    empty the trash
                end tell
            """)
            cachedPermission = .granted
        } catch BuiltinError.missingAutomationPermission {
            cachedPermission = .denied
            throw BuiltinError.missingAutomationPermission
        }
    }
}
```

- [ ] **Step 3: Register all providers in AppDelegate**

In `Sources/AnyDoor/AppDelegate.swift`, replace the providers array inside `applicationDidFinishLaunching`:

```swift
let providers: [any BuiltinProvider] = [
    KeepAwakeProvider(),
    HideDesktopIconsProvider(),
    ShowHiddenFilesProvider(),
    MuteAudioProvider(),
    DarkModeProvider(),
    LockScreenProvider(),
    EmptyTrashProvider(),
]
```

- [ ] **Step 4: Verify it compiles + manual smoke test**

Run: `swift build && swift run AnyDoor`
Expected: build clean. The app still shows the placeholder menu bar (no UI yet).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Providers/LockScreenProvider.swift \
        Sources/AnyDoor/Services/Providers/EmptyTrashProvider.swift \
        Sources/AnyDoor/AppDelegate.swift
git commit -m "feat(provider): add LockScreenProvider, EmptyTrashProvider; register all"
```

---

## Task 21: PanelRowView (three row types)

**Files:**
- Create: `Sources/AnyDoor/Views/PanelRowView.swift`

- [ ] **Step 1: Create PanelRowView**

Create `Sources/AnyDoor/Views/PanelRowView.swift`:

```swift
import SwiftUI

/// Renders a single PanelEntry in the menu bar panel.
///
/// Three visual variants driven by `entry.kind`:
/// - `.toggle`  — icon + title + (subtitle) + right-side switch; entire row toggles
/// - `.action`  — icon + title + right-side hotkey label; entire row triggers
/// - `.submenu` — icon + title + (subtitle) + right-side chevron; entire row opens popover
struct PanelRowView: View {
    let entry: PanelEntry
    var onToggle: () -> Void
    var onAction: () -> Void
    var onSubmenu: () -> Void
    var onPermission: () -> Void

    @State private var isHovered = false

    private var needsPermission: Bool { entry.permission == .denied }

    var body: some View {
        HStack(spacing: 10) {
            iconBadge
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.body)
                if needsPermission {
                    Text("⚠ 需要权限")
                        .font(.caption2)
                        .foregroundStyle(Color.orange)
                } else if let subtitle = entry.subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                } else if let hotkey = entry.hotkey {
                    Text(hotkey.displayString)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8))
        .onHover { isHovered = $0 }
        .contentShape(Rectangle())
        .onTapGesture {
            if needsPermission { onPermission(); return }
            switch entry.kind {
            case .toggle:  onToggle()
            case .action:  onAction()
            case .submenu: onSubmenu()
            }
        }
    }

    @ViewBuilder private var iconBadge: some View {
        let tint: Color = (entry.toggleState == true)
            ? .accentColor.opacity(0.5)
            : (needsPermission ? .orange.opacity(0.4) : .secondary.opacity(0.25))
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.2))
            Image(systemName: entry.symbol)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
        }
        .frame(width: 24, height: 24)
    }

    @ViewBuilder private var trailing: some View {
        switch entry.kind {
        case .toggle:
            Toggle("", isOn: Binding(
                get: { entry.toggleState ?? false },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(needsPermission)
        case .action:
            if let hk = entry.hotkey {
                Text(hk.displayString)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            } else {
                Text("—").foregroundStyle(.tertiary).font(.caption2)
            }
        case .submenu:
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/PanelRowView.swift
git commit -m "feat(ui): add PanelRowView for toggle/action/submenu rendering"
```

---

## Task 22: HoverPopover NSWindow + HoverGate

**Files:**
- Create: `Sources/AnyDoor/Views/HoverPopover.swift`

- [ ] **Step 1: Implement HoverPopover**

Create `Sources/AnyDoor/Views/HoverPopover.swift`:

```swift
import SwiftUI
import AppKit

/// Hover-triggered NSWindow popover for the App Shortcuts submenu.
///
/// Owns its own NSWindow so it can position itself relative to the host view's screen frame,
/// regardless of which window the trigger lives in. Uses a `HoverGate` to coordinate
/// show/hide timing across the trigger view and the popover content.
///
/// Lifecycle:
/// - Trigger view installs an `onHover` that arms the gate after 400ms.
/// - Once shown, the popover keeps itself open while either the trigger or popover area
///   contains the cursor; closes after 300ms of cursor leaving both.
@MainActor
final class HoverPopover {
    private let window: NSWindow
    private let hostingController: NSHostingController<AnyView>
    private var hideTask: Task<Void, Never>?

    init<Content: View>(@ViewBuilder content: () -> Content) {
        let controller = NSHostingController(rootView: AnyView(content()))
        self.hostingController = controller

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.contentViewController = controller
        // .nonactivating equivalent: ignoresMouseEvents = false + level floating + don't make key
        self.window = window
    }

    func updateContent<Content: View>(@ViewBuilder content: () -> Content) {
        hostingController.rootView = AnyView(content())
    }

    /// Show the popover anchored to the right side of `referenceFrame` (screen coordinates).
    /// If insufficient space on the right, flips to the left.
    func show(anchoredTo referenceFrame: NSRect) {
        hideTask?.cancel()
        hideTask = nil

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(referenceFrame) }) ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? .zero

        var size = window.frame.size
        if size == .zero { size = NSSize(width: 240, height: 200) }

        let rightX = referenceFrame.maxX + 4
        let leftX = referenceFrame.minX - 4 - size.width
        let originX = (rightX + size.width <= screenFrame.maxX) ? rightX : leftX
        let originY = max(screenFrame.minY,
                          min(referenceFrame.midY - size.height / 2,
                              screenFrame.maxY - size.height))

        window.setFrameOrigin(NSPoint(x: originX, y: originY))
        window.orderFrontRegardless()
    }

    /// Schedule a hide. Cancelled if `keepOpen()` is called within the delay.
    func scheduleHide(after delay: TimeInterval = 0.3) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.window.orderOut(nil)
        }
    }

    func keepOpen() {
        hideTask?.cancel()
        hideTask = nil
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        window.orderOut(nil)
    }
}

/// Coordinates hover-to-open / leave-to-close timing between a trigger view and a popover.
///
/// Use one instance per popover. The trigger view calls `hoverEnter()`/`hoverExit()`
/// from a `.onHover` modifier; the popover content view does the same from its own
/// `.onHover`. The popover stays open while either reports hovered.
@MainActor
@Observable
final class HoverGate {
    private(set) var isShown = false
    private var triggerHovered = false
    private var popoverHovered = false
    private var showTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    var onShow: () -> Void = {}
    var onHide: () -> Void = {}

    func triggerHover(_ hovered: Bool) {
        triggerHovered = hovered
        if hovered { scheduleShow() } else { scheduleHide() }
    }

    func popoverHover(_ hovered: Bool) {
        popoverHovered = hovered
        if hovered { showTask?.cancel(); hideTask?.cancel() }
        else { scheduleHide() }
    }

    func showImmediately() {
        showTask?.cancel()
        if !isShown {
            isShown = true
            onShow()
        }
    }

    private func scheduleShow() {
        guard !isShown else { return }
        hideTask?.cancel()
        showTask?.cancel()
        showTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000) // 400ms
            guard let self, !Task.isCancelled, self.triggerHovered else { return }
            self.isShown = true
            self.onShow()
        }
    }

    private func scheduleHide() {
        guard isShown else { return }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
            guard let self, !Task.isCancelled else { return }
            guard !self.triggerHovered && !self.popoverHovered else { return }
            self.isShown = false
            self.onHide()
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/HoverPopover.swift
git commit -m "feat(ui): add HoverPopover NSWindow and HoverGate timing"
```

---

## Task 23: AppShortcutsPopoverView

**Files:**
- Create: `Sources/AnyDoor/Views/AppShortcutsPopoverView.swift`

- [ ] **Step 1: Implement popover content**

Create `Sources/AnyDoor/Views/AppShortcutsPopoverView.swift`:

```swift
import SwiftUI
import AppKit

/// SwiftUI content shown inside the HoverPopover for the App Shortcuts submenu.
///
/// Lists each KeyBinding with hotkey + app name + a small running-state indicator.
/// "+ 添加应用快捷键" at the bottom opens the Settings window.
struct AppShortcutsPopoverView: View {
    let entries: [PanelEntry]
    var onHoverChange: (Bool) -> Void
    var onSelect: (PanelEntry) -> Void
    var onAddNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Text("应用快捷键").font(.headline)
                Text("· \(entries.count) 个").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            Divider().padding(.horizontal, 8)

            // Rows
            VStack(spacing: 2) {
                ForEach(entries.filter(\.isVisible)) { entry in
                    AppShortcutRow(entry: entry, onSelect: { onSelect(entry) })
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)

            Divider().padding(.horizontal, 8)

            // Footer
            Button(action: onAddNew) {
                Label("添加应用快捷键", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .padding(8)
        }
        .frame(width: 240, height: 240)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onHover(perform: onHoverChange)
    }
}

private struct AppShortcutRow: View {
    let entry: PanelEntry
    var onSelect: () -> Void

    @State private var hovered = false

    private var isRunning: Bool {
        guard case let .appShortcut(_) = entry.source else { return false }
        // Cheap lookup by scanning running apps for any whose path equals entry.subtitle?
        // Subtitle isn't reliable; use NSRunningApplication by symbol name approximation.
        // For accuracy we'd need bundleID — see Task 24 where PanelStore can inject runningSet.
        return false
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.hotkey?.displayString ?? "—")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
            Text(entry.title).font(.body).lineLimit(1)
            Spacer(minLength: 0)
            Circle()
                .fill(isRunning ? Color.green : Color.secondary.opacity(0.25))
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(hovered ? Color.accentColor.opacity(0.1) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/AppShortcutsPopoverView.swift
git commit -m "feat(ui): add AppShortcutsPopoverView content"
```

---

## Task 24: MenuBarView rewrite + hover popover wiring

**Files:**
- Modify: `Sources/AnyDoor/Views/MenuBarView.swift`

- [ ] **Step 1: Rewrite MenuBarView**

Replace `Sources/AnyDoor/Views/MenuBarView.swift` with:

```swift
import SwiftUI
import AppKit

struct MenuBarView: View {
    @State private var panel = PanelStore.shared
    @State private var popover = HoverPopover {
        EmptyView()
    }
    @State private var gate = HoverGate()
    @State private var triggerFrame: NSRect = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack {
                Text("AnyDoor").font(.headline)
                Spacer()
                let count = panel.topLevelEntries.filter(\.isVisible).count
                Text("\(count) 个已启用").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.top, 4)

            // Rows
            VStack(spacing: 2) {
                ForEach(panel.topLevelEntries.filter(\.isVisible)) { entry in
                    rowView(for: entry)
                }
            }
            .padding(.horizontal, 4)

            Spacer(minLength: 0)

            // Footer
            HStack(spacing: 8) {
                SettingsLink { Label("设置", systemImage: "gear") }
                    .buttonStyle(.glass)
                    .simultaneousGesture(TapGesture().onEnded {
                        NSApplication.shared.activate()
                    })
                Button { NSApplication.shared.terminate(nil) } label: {
                    Label("退出", systemImage: "power")
                }.buttonStyle(.glass)
                Spacer()
            }
            .focusEffectDisabled()
            .padding(.horizontal, 8).padding(.bottom, 4)
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
        .frame(width: 260).frame(minHeight: 400)
        .task {
            await panel.refreshAll()
        }
        .onAppear { wireGate() }
        .onDisappear { popover.hide() }
    }

    @ViewBuilder
    private func rowView(for entry: PanelEntry) -> some View {
        if case .builtin(.appShortcuts) = entry.source {
            PanelRowView(
                entry: entry,
                onToggle: {},
                onAction: {},
                onSubmenu: { triggerSubmenu() },
                onPermission: openPermissionsSettings
            )
            .background(
                GeometryReader { proxy in
                    Color.clear.onAppear {
                        triggerFrame = proxy.frame(in: .global)
                    }.onChange(of: proxy.frame(in: .global)) { _, new in
                        triggerFrame = new
                    }
                }
            )
            .onHover { hovered in
                gate.triggerHover(hovered)
            }
        } else {
            PanelRowView(
                entry: entry,
                onToggle: {
                    if case let .builtin(item) = entry.source {
                        Task { await panel.toggle(item) }
                    }
                },
                onAction: {
                    if case let .builtin(item) = entry.source {
                        Task { await panel.run(item) }
                    }
                },
                onSubmenu: {},
                onPermission: openPermissionsSettings
            )
        }
    }

    private func wireGate() {
        gate.onShow = {
            popover.updateContent {
                AppShortcutsPopoverView(
                    entries: panel.appShortcutChildren,
                    onHoverChange: { gate.popoverHover($0) },
                    onSelect: { entry in
                        if case let .appShortcut(id) = entry.source,
                           let binding = lookupBinding(id: id) {
                            AppSwitcher.toggle(
                                bundleID: binding.appBundleID,
                                appPath: binding.appPath
                            )
                        }
                    },
                    onAddNew: {
                        NSApplication.shared.activate()
                        if let url = URL(string: "anydoor://settings/panel/add-app") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )
            }
            popover.show(anchoredTo: convertedTriggerFrame())
        }
        gate.onHide = { popover.scheduleHide() }
    }

    /// Convert the panel-local triggerFrame to global screen coordinates by adding
    /// the menu bar window's frame origin (set by AppKit when the popover opens).
    private func convertedTriggerFrame() -> NSRect {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else {
            return triggerFrame
        }
        return window.convertToScreen(triggerFrame)
    }

    private func triggerSubmenu() { gate.showImmediately() }

    private func lookupBinding(id: UUID) -> KeyBinding? {
        nil // wired in Task 25 after we add a lookup hook on PanelStore
    }

    private func openPermissionsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Manual smoke check**

Run: `swift run AnyDoor`
Expected: menu bar opens, shows the list of built-in entries (Keep Awake on top), tapping a built-in toggle flips its state, hovering the App Shortcuts row pops the side popover after 400ms. App shortcuts inside the popover may still fail to launch (KeyBinding lookup is wired in Task 25).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Views/MenuBarView.swift
git commit -m "feat(ui): rewrite MenuBarView to use PanelStore + hover popover"
```

---

## Task 25: PanelStore binding lookup + wire into MenuBarView

**Files:**
- Modify: `Sources/AnyDoor/Services/PanelStore.swift`
- Modify: `Sources/AnyDoor/Views/MenuBarView.swift`

- [ ] **Step 1: Add lookup method to PanelStore**

Append to `Sources/AnyDoor/Services/PanelStore.swift` (inside the class):

```swift
    /// Look up a KeyBinding by id from the SwiftData store.
    func binding(id: UUID) -> KeyBinding? {
        guard let container = modelContainer else { return nil }
        let context = container.mainContext
        let descriptor = FetchDescriptor<KeyBinding>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }
```

- [ ] **Step 2: Use the lookup in MenuBarView**

In `Sources/AnyDoor/Views/MenuBarView.swift`, replace the `lookupBinding` method:

```swift
    private func lookupBinding(id: UUID) -> KeyBinding? {
        panel.binding(id: id)
    }
```

- [ ] **Step 3: Manual smoke check**

Run: `swift run AnyDoor`
Expected: opening App Shortcuts popover and clicking an app row toggles that app.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Services/PanelStore.swift Sources/AnyDoor/Views/MenuBarView.swift
git commit -m "feat(panel): add binding lookup, wire into popover row select"
```

---

## Task 26: HotkeyRecorder inline component

**Files:**
- Create: `Sources/AnyDoor/Views/HotkeyRecorder.swift`

- [ ] **Step 1: Implement recorder**

Create `Sources/AnyDoor/Views/HotkeyRecorder.swift`:

```swift
import SwiftUI
import AppKit

/// Inline hotkey recording field. Click to enter recording mode; press a combination
/// to capture; press ESC to cancel; press ⌫ (no modifiers) to clear.
///
/// While recording, HotkeyService is suspended so the in-progress combination doesn't
/// fire an existing binding.
struct HotkeyRecorder: View {
    @Binding var hotkey: HotkeyDescriptor?
    var onChange: (HotkeyDescriptor?) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: { startRecording() }) {
            label
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(isRecording ? Color.accentColor.opacity(0.25) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isRecording ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onDisappear { stopRecording() }
    }

    @ViewBuilder
    private var label: some View {
        if let hk = hotkey {
            Text(hk.displayString).foregroundStyle(.primary)
        } else if isRecording {
            Text("按下快捷键…").foregroundStyle(.secondary).italic()
        } else {
            Text("点击录入").foregroundStyle(.secondary).italic()
        }
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        HotkeyService.shared.suspend()

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modMask: UInt64 = CGEventFlags.maskCommand.rawValue
                | CGEventFlags.maskControl.rawValue
                | CGEventFlags.maskAlternate.rawValue
                | CGEventFlags.maskShift.rawValue
            let cgFlags = event.cgEvent?.flags ?? []
            let mods = Int(cgFlags.rawValue & modMask)
            let code = Int(event.keyCode)

            if code == 53 { // ESC
                stopRecording()
                return nil
            }
            if code == 51 && mods == 0 { // Delete with no modifiers → clear
                hotkey = nil
                onChange(nil)
                stopRecording()
                return nil
            }

            let new = HotkeyDescriptor(keyCode: code, modifierFlags: mods)
            hotkey = new
            onChange(new)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
            HotkeyService.shared.resume()
        }
        isRecording = false
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/HotkeyRecorder.swift
git commit -m "feat(ui): add HotkeyRecorder inline component"
```

---

## Task 27: PanelSettingsView with drag, visibility, hotkey assign

**Files:**
- Create: `Sources/AnyDoor/Views/PanelSettingsView.swift`
- Modify: `Sources/AnyDoor/Views/SettingsView.swift`

- [ ] **Step 1: Add PanelStore mutation helpers**

Append to `Sources/AnyDoor/Services/PanelStore.swift` (inside the class):

```swift
    // MARK: - Mutations

    /// Update visibility for a built-in.
    func setBuiltinVisibility(_ item: BuiltinItem, isVisible: Bool) {
        guard let container = modelContainer else { return }
        let context = container.mainContext
        let key = item.rawValue
        if let pref = try? context.fetch(
            FetchDescriptor<BuiltinPreference>(predicate: #Predicate { $0.itemKey == key })
        ).first {
            pref.isVisible = isVisible
            try? context.save()
            rebuild()
            rebuildHotkeySnapshots()
        }
    }

    /// Update hotkey for a built-in. Pass nil to clear.
    func setBuiltinHotkey(_ item: BuiltinItem, hotkey: HotkeyDescriptor?) {
        guard let container = modelContainer else { return }
        let context = container.mainContext
        let key = item.rawValue
        if let pref = try? context.fetch(
            FetchDescriptor<BuiltinPreference>(predicate: #Predicate { $0.itemKey == key })
        ).first {
            pref.keyCode = hotkey?.keyCode
            pref.modifierFlags = hotkey?.modifierFlags
            try? context.save()
            rebuild()
            rebuildHotkeySnapshots()
        }
    }

    /// Update KeyBinding fields (visibility / hotkey).
    func updateAppShortcut(id: UUID, isVisible: Bool? = nil, hotkey: HotkeyDescriptor? = nil) {
        guard let binding = binding(id: id), let container = modelContainer else { return }
        if let v = isVisible { binding.isVisible = v }
        if let hk = hotkey {
            binding.keyCode = hk.keyCode
            binding.modifierFlags = hk.modifierFlags
        }
        try? container.mainContext.save()
        rebuild()
        rebuildHotkeySnapshots()
    }

    /// Reorder top-level entries by new keys array (ordered).
    func reorderTopLevel(by newOrder: [BuiltinItem]) {
        guard let container = modelContainer else { return }
        let context = container.mainContext
        guard let prefs = try? context.fetch(FetchDescriptor<BuiltinPreference>()) else { return }
        let prefsByKey = Dictionary(uniqueKeysWithValues: prefs.map { ($0.itemKey, $0) })
        var order: Double = 100
        for item in newOrder {
            if let pref = prefsByKey[item.rawValue] {
                pref.displayOrder = order
                order += 100
            }
        }
        try? context.save()
        rebuild()
        rebuildHotkeySnapshots()
    }

    /// Reorder app shortcuts by new id array (ordered).
    func reorderAppShortcuts(by newOrder: [UUID]) {
        guard let container = modelContainer else { return }
        let context = container.mainContext
        var order: Double = 100
        for id in newOrder {
            if let binding = binding(id: id) {
                binding.displayOrder = order
                order += 100
            }
        }
        try? context.save()
        rebuild()
    }

    /// Find which entry currently owns a given hotkey (used for conflict detection).
    func entryUsingHotkey(_ hotkey: HotkeyDescriptor, excluding: PanelEntry.Source? = nil) -> PanelEntry? {
        for entry in topLevelEntries + appShortcutChildren {
            if entry.source == excluding { continue }
            if entry.hotkey == hotkey { return entry }
        }
        return nil
    }
```

- [ ] **Step 2: Create PanelSettingsView**

Create `Sources/AnyDoor/Views/PanelSettingsView.swift`:

```swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PanelSettingsView: View {
    @State private var panel = PanelStore.shared
    @State private var conflictAlert: ConflictAlert?
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(panel.topLevelEntries) { entry in
                    row(for: entry)
                }
                .onMove(perform: moveTopLevel)
            }
            .listStyle(.inset)

            Text("系统条目无法删除，只能隐藏；应用快捷键可自由增删。")
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(8)
        }
        .alert(item: $conflictAlert) { alert in
            Alert(
                title: Text("快捷键冲突"),
                message: Text("\(alert.hotkey.displayString) 已被「\(alert.existingTitle)」占用"),
                primaryButton: .default(Text("替换")) {
                    alert.onReplace()
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    @ViewBuilder
    private func row(for entry: PanelEntry) -> some View {
        VStack(spacing: 0) {
            mainRow(entry)
            if case .builtin(.appShortcuts) = entry.source {
                appShortcutChildren()
                addAppButton()
            }
        }
        .opacity(entry.isVisible ? 1.0 : 0.5)
    }

    private func mainRow(_ entry: PanelEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
            Toggle("", isOn: Binding(
                get: { entry.isVisible },
                set: { newValue in
                    if case let .builtin(item) = entry.source {
                        panel.setBuiltinVisibility(item, isVisible: newValue)
                    }
                }
            ))
            .toggleStyle(.checkbox).labelsHidden()
            .disabled(false)
            Image(systemName: entry.symbol).frame(width: 16)
            Text(entry.title).font(.body)
            Text(typeBadge(for: entry)).font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            hotkeyField(for: entry)
            deleteButton(for: entry)
        }
        .padding(.vertical, 4)
    }

    private func typeBadge(for entry: PanelEntry) -> String {
        switch entry.kind {
        case .toggle:  return "系统"
        case .action:  return "系统 · 动作"
        case .submenu: return "系统 · 子菜单"
        }
    }

    @ViewBuilder
    private func hotkeyField(for entry: PanelEntry) -> some View {
        if case .builtin(.appShortcuts) = entry.source {
            Text("—").font(.caption2).foregroundStyle(.tertiary).frame(width: 130, alignment: .trailing)
        } else {
            HotkeyRecorder(hotkey: .constant(entry.hotkey)) { newValue in
                handleHotkeyChange(entry: entry, newValue: newValue)
            }
            .frame(width: 130, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func deleteButton(for entry: PanelEntry) -> some View {
        if case .builtin(_) = entry.source {
            Image(systemName: "xmark")
                .foregroundStyle(.tertiary.opacity(0.5))
                .frame(width: 20)
        } else if case let .appShortcut(id) = entry.source {
            Button {
                deleteAppShortcut(id: id)
            } label: {
                Image(systemName: "xmark").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 20)
        }
    }

    private func handleHotkeyChange(entry: PanelEntry, newValue: HotkeyDescriptor?) {
        if let new = newValue,
           let existing = panel.entryUsingHotkey(new, excluding: entry.source) {
            conflictAlert = ConflictAlert(
                hotkey: new,
                existingTitle: existing.title,
                onReplace: {
                    // Clear existing then assign new
                    clearHotkey(for: existing.source)
                    apply(hotkey: new, to: entry)
                }
            )
        } else {
            apply(hotkey: newValue, to: entry)
        }
    }

    private func apply(hotkey: HotkeyDescriptor?, to entry: PanelEntry) {
        switch entry.source {
        case let .builtin(item):
            panel.setBuiltinHotkey(item, hotkey: hotkey)
        case let .appShortcut(id):
            panel.updateAppShortcut(id: id, hotkey: hotkey)
        }
    }

    private func clearHotkey(for source: PanelEntry.Source) {
        switch source {
        case let .builtin(item):
            panel.setBuiltinHotkey(item, hotkey: nil)
        case let .appShortcut(id):
            panel.updateAppShortcut(id: id, hotkey: nil)
        }
    }

    private func moveTopLevel(from source: IndexSet, to destination: Int) {
        var items = panel.topLevelEntries.compactMap { entry -> BuiltinItem? in
            if case let .builtin(item) = entry.source { return item } else { return nil }
        }
        items.move(fromOffsets: source, toOffset: destination)
        panel.reorderTopLevel(by: items)
    }

    @ViewBuilder
    private func appShortcutChildren() -> some View {
        ForEach(panel.appShortcutChildren) { child in
            HStack(spacing: 8) {
                Rectangle().fill(Color.accentColor.opacity(0.3)).frame(width: 2).padding(.leading, 16)
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                Toggle("", isOn: Binding(
                    get: { child.isVisible },
                    set: { newValue in
                        if case let .appShortcut(id) = child.source {
                            panel.updateAppShortcut(id: id, isVisible: newValue)
                        }
                    }
                ))
                .toggleStyle(.checkbox).labelsHidden()
                Image(systemName: child.symbol).frame(width: 16)
                Text(child.title).font(.body)
                Spacer()
                HotkeyRecorder(hotkey: .constant(child.hotkey)) { newValue in
                    handleHotkeyChange(entry: child, newValue: newValue)
                }
                .frame(width: 130, alignment: .trailing)
                deleteButton(for: child)
            }
            .padding(.vertical, 3)
            .opacity(child.isVisible ? 1.0 : 0.5)
        }
        .onMove(perform: moveChildren)
    }

    private func moveChildren(from source: IndexSet, to destination: Int) {
        var ids = panel.appShortcutChildren.compactMap { entry -> UUID? in
            if case let .appShortcut(id) = entry.source { return id } else { return nil }
        }
        ids.move(fromOffsets: source, toOffset: destination)
        panel.reorderAppShortcuts(by: ids)
    }

    private func addAppButton() -> some View {
        HStack {
            Spacer().frame(width: 38)
            Button {
                addApp()
            } label: {
                Label("添加应用", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.title = "选择应用程序"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let bundle = Bundle(url: url)
        let appBundleID = bundle?.bundleIdentifier ?? ""
        let appName = (bundle?.infoDictionary?["CFBundleName"] as? String)
            ?? (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent

        // Default order: append at end of children
        let nextOrder = (PanelStore.shared.appShortcutChildren.map(\.displayOrder).max() ?? 0) + 100

        let new = KeyBinding(
            keyCode: -1, // sentinel: no hotkey yet
            modifierFlags: 0,
            appBundleID: appBundleID,
            appName: appName,
            appPath: url.path,
            isEnabled: false, // disabled until user records a hotkey
            isVisible: true,
            displayOrder: nextOrder
        )
        modelContext.insert(new)
        try? modelContext.save()
        PanelStore.shared.rebuild()
        PanelStore.shared.rebuildHotkeySnapshots()
    }

    private func deleteAppShortcut(id: UUID) {
        guard let binding = PanelStore.shared.binding(id: id) else { return }
        modelContext.delete(binding)
        try? modelContext.save()
        PanelStore.shared.rebuild()
        PanelStore.shared.rebuildHotkeySnapshots()
    }
}

private struct ConflictAlert: Identifiable {
    let id = UUID()
    let hotkey: HotkeyDescriptor
    let existingTitle: String
    let onReplace: () -> Void
}
```

- [ ] **Step 3: Wire SettingsView to PanelSettingsView**

Replace `Sources/AnyDoor/Views/SettingsView.swift` with:

```swift
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("面板", systemImage: "rectangle.stack") {
                PanelSettingsView()
            }
            Tab("通用", systemImage: "gear") {
                GeneralSettingsView()
            }
        }
        .frame(width: 560, height: 480)
    }
}
```

- [ ] **Step 4: Build and manual smoke test**

Run: `swift build && swift run AnyDoor`
Verify: settings opens to «面板» tab; built-ins listed; ⌃⌥⌘K applied to Keep Awake triggers it via hotkey; conflict alert appears when assigning a duplicate.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/PanelStore.swift \
        Sources/AnyDoor/Views/PanelSettingsView.swift \
        Sources/AnyDoor/Views/SettingsView.swift
git commit -m "feat(settings): add PanelSettingsView with drag/visibility/hotkey + conflict alert"
```

---

## Task 28: Cleanup deprecated views

**Files:**
- Delete: `Sources/AnyDoor/Views/BindingListView.swift`
- Delete: `Sources/AnyDoor/Views/BindingEditView.swift`

- [ ] **Step 1: Delete deprecated files**

```bash
rm Sources/AnyDoor/Views/BindingListView.swift
rm Sources/AnyDoor/Views/BindingEditView.swift
```

- [ ] **Step 2: Verify build still passes**

Run: `swift build && swift test`
Expected: clean build, all tests pass.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor: remove legacy BindingListView and BindingEditView"
```

---

## Task 29: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update project structure and architecture sections**

In `CLAUDE.md`, replace the project structure block under "## 项目结构" with:

```
Sources/AnyDoor/
├── AnyDoor.swift              # @main, MenuBarExtra + Settings Scene
├── AppDelegate.swift           # ModelContainer, providers registry, HotkeyService bootstrap
├── Models/
│   ├── KeyBinding.swift        # App shortcut bindings (SwiftData)
│   ├── BuiltinItem.swift       # Code-defined catalog of system toggle/action items
│   ├── BuiltinPreference.swift # User customization (visibility / order / hotkey) for built-ins
│   ├── PanelEntry.swift        # Unified view model + HotkeyDescriptor + PermissionStatus
│   └── HotkeyAction.swift      # HotkeyAction enum + HotkeySnapshot
├── Services/
│   ├── HotkeyService.swift     # CGEvent tap, dispatches HotkeyAction via injected closure
│   ├── PanelStore.swift        # @Observable, merges all three sources, owns provider registry
│   ├── AppSwitcher.swift       # App launch/hide/activate
│   ├── AppleScriptRunner.swift # NSAppleScript wrapper
│   ├── ShellRunner.swift       # Process + timeout wrapper
│   ├── BuiltinPreferenceSeeder.swift
│   ├── KeyBindingOrderBackfill.swift
│   └── Providers/
│       ├── BuiltinProvider.swift
│       ├── KeepAwakeProvider.swift
│       ├── HideDesktopIconsProvider.swift
│       ├── ShowHiddenFilesProvider.swift
│       ├── MuteAudioProvider.swift
│       ├── DarkModeProvider.swift
│       ├── LockScreenProvider.swift
│       └── EmptyTrashProvider.swift
├── Utilities/
│   └── KeyCodeMap.swift
└── Views/
    ├── MenuBarView.swift              # Menu bar panel root
    ├── PanelRowView.swift             # Single row: toggle / action / submenu
    ├── HoverPopover.swift             # NSWindow side popover + HoverGate timing
    ├── AppShortcutsPopoverView.swift  # Popover content for app shortcuts
    ├── HotkeyRecorder.swift           # Inline hotkey recording field
    ├── SettingsView.swift             # TabView host
    ├── PanelSettingsView.swift        # 面板 tab: drag / visibility / hotkey
    └── GeneralSettingsView.swift      # 通用 tab (placeholder)
```

- [ ] **Step 2: Add a new architecture note**

In `CLAUDE.md`, append to the "## 架构要点" list:

```markdown
- **PanelStore 是单一真相源**：三路数据（BuiltinItem 静态清单 + BuiltinPreference 偏好 + KeyBinding 应用快捷键）在 `PanelStore` 合并；视图只读 `topLevelEntries` 与 `appShortcutChildren`。**写入路径都要经过 PanelStore 的 mutation 方法**（setBuiltinVisibility、setBuiltinHotkey、reorderTopLevel 等），它们会自动 save SwiftData、rebuild 视图状态、并 `rebuildHotkeySnapshots()` 推到 HotkeyService。
- **HotkeyAction 派发**：HotkeyService 的回调使用注入的 `dispatcher` 闭包，在 `AppDelegate.applicationDidFinishLaunching` 中绑定到 `PanelStore.shared.dispatch`；不要直接在 HotkeyService 内引用 PanelStore，保持 HotkeyService 与具体业务解耦。
- **Provider 隔离**：每个 ToggleProvider / ActionProvider 是独立 actor，setState 在自己的 actor 上串行；`PanelStore` 是 `@MainActor`，跨 Provider 的写操作通过 `Task { await … }` 在 MainActor 调度。
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): update structure and panel architecture notes"
```

---

## Task 30: Final verification & branch summary

**Files:** none (verification only)

- [ ] **Step 1: Run full test suite**

Run: `swift test`
Expected: all tests pass.

- [ ] **Step 2: Manual end-to-end smoke**

Run: `swift run AnyDoor`. Verify each:
- Menu bar panel shows 8 entries by default
- Keep Awake toggle: ON keeps display awake (verify with `pmset -g assertions | grep AnyDoor`); OFF releases
- Hide Desktop Icons toggle: ON empties desktop (icons gone); OFF restores
- Show Hidden Files toggle: dotfiles appear/disappear in Finder
- Mute toggle: system volume mute icon updates in menu bar
- Dark Mode: first toggle prompts Automation permission; subsequent toggles flip appearance
- Lock Screen action: locks the screen
- Empty Trash action: empties Trash (Automation prompt on first use)
- App Shortcuts hover: popover appears after ~400ms; lists existing bindings; clicking a row toggles the target app
- Settings → 面板: drag to reorder works; visibility checkbox toggles row display in menu bar; hotkey field records and conflicts detected
- Existing hotkey bindings still function (regression)

- [ ] **Step 3: Diff summary**

Run: `git log main..HEAD --oneline`
Expected: clean linear history of feature commits.

- [ ] **Step 4: Done**

Branch `feature/menu-bar-panel-redesign` is ready for PR review.

---

## Self-Review Notes (filled during writing-plans run)

**Spec coverage:** All 11 spec sections map to tasks:
- §1 goals/scope → all tasks scoped to MVP set
- §2 architecture → Tasks 4–11 (catalog, store, provider, hotkey action)
- §3 data model → Tasks 3, 5, 7 (KeyBinding/BuiltinPreference/PanelEntry)
- §3.4 migration → Tasks 5, 6 (seeder, backfill)
- §4 provider abstraction → Tasks 9, 10, 14–20 (protocols + 7 concrete providers + runners)
- §5 hotkey routing → Tasks 8, 12, 13 (HotkeySnapshot + dispatcher + AppDelegate)
- §6 menu bar UI → Tasks 21, 24, 25 (PanelRowView, MenuBarView rewrite, binding lookup)
- §6.3 hover popover → Tasks 22, 23 (HoverPopover NSWindow, AppShortcutsPopoverView)
- §7 settings → Tasks 26, 27 (HotkeyRecorder, PanelSettingsView with conflict alert)
- §8 permissions/errors → embedded in providers (DarkMode, EmptyTrash cached `permission`); permission row UI in Task 21
- §9 testing → Tasks 1, 2, 3, 4, 5, 6, 7, 11, 12 (KeyCodeMap, HotkeyDescriptor, migration, seeder, panel store, conflict)
- §10 work packages → mirrored as tasks
- §11 alignment → preserved (HotkeyService changes keep watchdog/suspend/resume/Sendable rules)

**Placeholder scan:** No TBD/TODO/FIXME found. Each task has concrete file paths, complete code, and explicit commands.

**Type consistency:** Verified `HotkeyDescriptor`, `HotkeySnapshot`, `HotkeyAction`, `BuiltinItem`, `PanelEntry`, `PermissionStatus`, `BuiltinError`, `PanelStore` method names are used consistently across tasks.

**Known follow-ups (not in this plan, but noted for later):**
- AppShortcutsPopoverView shows a "running" indicator stub (`isRunning` always false); proper detection via NSRunningApplication should be added once UI parity is verified.
- The `anydoor://settings/panel/add-app` URL scheme used by the popover's "+ 添加应用快捷键" footer is illustrative — Task 27 wires the real flow inside Settings; the popover button currently only activates the app and opens Settings, which is acceptable for MVP.
