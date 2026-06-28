# Panel Settings: Group & Collapse Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize the Settings → "Panel" tab into themed, collapsible groups (reusing the command palette's grouping), with within-group and group-level drag reordering, so the long flat list becomes scannable.

**Architecture:** A shared `BuiltinGroup` catalog becomes the single source of truth for grouping (the command palette is refactored to consume it). A `PanelGroupingStore` persists themed-group order + collapse state in UserDefaults. `PanelStore.rebuild()` sorts `topLevelEntries` by `(groupOrderIndex, displayOrder)` so both the menu-bar panel and the settings page render group-contiguous order with no SwiftData migration. The settings view renders one flat `List` (so app/window children stay individually draggable) with injected section-header rows and per-group/per-parent collapse, routing drags through the existing `PanelReorder.localMove`.

**Tech Stack:** Swift 6.2 (strict concurrency, `.v6`), SwiftUI + AppKit, SwiftData, swift-testing (`Testing`) for pure logic + XCTest for `@MainActor` store tests, SPM (`swift build` / `swift test`).

## Global Constraints

- Swift 6 strict concurrency mode; new shared mutable state must be `@MainActor` or `Sendable`.
- All code comments in English; all UI-facing copy in Chinese via `LocalizationManager` / `L10n` — do not hardcode user-facing strings.
- All writes to panel data go through `PanelStore` mutation methods (they `save()` SwiftData, `rebuild()`, and `rebuildHotkeySnapshots()`); views must not call `modelContext.save()` directly.
- Do NOT change the pinned ModelContainer store path or the 5-type schema. This feature adds NO SwiftData fields — group order/collapse live in UserDefaults only.
- The command palette's on-screen output (sections, order, titles) must stay byte-for-byte identical after the Task 2 refactor.
- The menu-bar panel (`MenuBarView`) gains NO header/collapse UI; only item order changes as a side effect of the new sort key.
- Reuse existing `commandPalette.section.*` L10n keys for themed-group titles; add no new catalog strings.
- Commit after each task. Conventional Commits, English, no `Co-Authored-By` / generation signatures, no `@` characters in messages.

---

### Task 1: `BuiltinGroup` shared catalog

**Files:**
- Create: `Sources/AnyDoor/Models/BuiltinGroup.swift`
- Test: `Tests/AnyDoorTests/BuiltinGroupTests.swift`

**Interfaces:**
- Produces:
  - `enum BuiltinGroup: String, CaseIterable, Sendable, Hashable { case general, togglesAppearance, powerSession, screenshot, translation }`
  - `static let BuiltinGroup.themedDefaultOrder: [BuiltinGroup]` (themed groups only, in default display order)
  - `var BuiltinGroup.members: Set<BuiltinItem>` (`.general` → `[]`)
  - `var BuiltinGroup.titleKey: L10n.Key?` (`.general` → `nil`)
  - `static func BuiltinGroup.group(for: BuiltinItem) -> BuiltinGroup`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnyDoorTests/BuiltinGroupTests.swift
import Foundation
import Testing
@testable import AnyDoor

/// `BuiltinGroup` is the single source of truth for command grouping, shared by
/// the command palette and the Panel settings page. These tests pin totality
/// (every BuiltinItem maps to exactly one group), disjointness of themed sets,
/// and that the themed member sets still equal the command palette's prior
/// hardcoded sets (regression guard so the palette is unchanged).
struct BuiltinGroupTests {

    @Test func everyItemMapsToExactlyOneGroup() {
        for item in BuiltinItem.allCases {
            let owning = BuiltinGroup.themedDefaultOrder.filter { $0.members.contains(item) }
            #expect(owning.count <= 1, "\(item) is claimed by multiple themed groups: \(owning)")
            let g = BuiltinGroup.group(for: item)
            if owning.isEmpty {
                #expect(g == .general)
            } else {
                #expect(g == owning[0])
            }
        }
    }

    @Test func themedSetsAreDisjoint() {
        var seen = Set<BuiltinItem>()
        for group in BuiltinGroup.themedDefaultOrder {
            for item in group.members {
                #expect(seen.insert(item).inserted, "\(item) appears in more than one themed group")
            }
        }
    }

    @Test func themedMembersMatchCommandPaletteSets() {
        #expect(BuiltinGroup.togglesAppearance.members == [
            .muteAudio, .microphoneMute, .darkMode, .hideDock, .autoHideMenuBar,
            .hideDesktopIcons, .showHiddenFiles, .keyboardLock, .brightness,
        ])
        #expect(BuiltinGroup.powerSession.members == [
            .lockScreen, .displaySleep, .systemSleep, .scheduledShutdown, .keepAwake,
        ])
        #expect(BuiltinGroup.screenshot.members == [
            .screenshot, .captureWindow, .captureFullscreen, .captureTimer,
            .captureModeBar, .recordScreen, .captureScrolling,
        ])
        #expect(BuiltinGroup.translation.members == [
            .translate, .screenshotTranslate, .translateSelection,
        ])
    }

    @Test func defaultOrderMatchesPaletteAndExcludesGeneral() {
        #expect(BuiltinGroup.themedDefaultOrder == [
            .togglesAppearance, .powerSession, .screenshot, .translation,
        ])
        #expect(BuiltinGroup.general.titleKey == nil)
        #expect(BuiltinGroup.screenshot.titleKey == .commandPaletteSectionCapture)
    }

    @Test func appShortcutsAndWindowLayoutFallIntoGeneral() {
        #expect(BuiltinGroup.group(for: .appShortcuts) == .general)
        #expect(BuiltinGroup.group(for: .windowLayout) == .general)
        #expect(BuiltinGroup.group(for: .hostsManager) == .general)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BuiltinGroupTests`
Expected: FAIL to compile — `cannot find 'BuiltinGroup' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AnyDoor/Models/BuiltinGroup.swift
import Foundation

/// Single source of truth for how built-in commands are grouped into themed
/// sections. Shared by the command palette (`CommandPaletteWindowController`)
/// and the Panel settings page. `.general` is the implicit, headerless,
/// always-first bucket: every `BuiltinItem` not claimed by a themed group.
enum BuiltinGroup: String, CaseIterable, Sendable, Hashable {
    case general
    case togglesAppearance
    case powerSession
    case screenshot
    case translation

    /// Themed groups in default display order. `.general` is intentionally
    /// excluded — it is the implicit first bucket and is never reordered.
    static let themedDefaultOrder: [BuiltinGroup] = [
        .togglesAppearance, .powerSession, .screenshot, .translation,
    ]

    /// Section header title, or `nil` for `.general` (rendered without a header).
    var titleKey: L10n.Key? {
        switch self {
        case .general:           return nil
        case .togglesAppearance: return .commandPaletteSectionToggles
        case .powerSession:      return .commandPaletteSectionPower
        case .screenshot:        return .commandPaletteSectionCapture
        case .translation:       return .commandPaletteSectionTranslation
        }
    }

    /// Explicit members of each themed group. Mirrors the command palette's
    /// prior hardcoded sets exactly (regression-guarded in BuiltinGroupTests).
    /// `.general` has no explicit list — it is "the rest".
    var members: Set<BuiltinItem> {
        switch self {
        case .general:
            return []
        case .togglesAppearance:
            return [.muteAudio, .microphoneMute, .darkMode, .hideDock, .autoHideMenuBar,
                    .hideDesktopIcons, .showHiddenFiles, .keyboardLock, .brightness]
        case .powerSession:
            return [.lockScreen, .displaySleep, .systemSleep, .scheduledShutdown, .keepAwake]
        case .screenshot:
            return [.screenshot, .captureWindow, .captureFullscreen, .captureTimer,
                    .captureModeBar, .recordScreen, .captureScrolling]
        case .translation:
            return [.translate, .screenshotTranslate, .translateSelection]
        }
    }

    /// The owning group of an item: the first themed group that claims it, else
    /// `.general`.
    static func group(for item: BuiltinItem) -> BuiltinGroup {
        for group in themedDefaultOrder where group.members.contains(item) {
            return group
        }
        return .general
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BuiltinGroupTests`
Expected: PASS (all 5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Models/BuiltinGroup.swift Tests/AnyDoorTests/BuiltinGroupTests.swift
git commit -m "feat(panel): add shared BuiltinGroup catalog"
```

---

### Task 2: Refactor command palette to consume `BuiltinGroup`

**Files:**
- Modify: `Sources/AnyDoor/Views/CommandPaletteWindowController.swift:8-25` (remove the four private static sets) and `:196-201` (build `groups` from `BuiltinGroup`).
- Test: existing `Tests/AnyDoorTests/CommandPaletteTests.swift` is the regression guard (no new test needed; behavior must be unchanged).

**Interfaces:**
- Consumes: `BuiltinGroup.themedDefaultOrder`, `BuiltinGroup.members`, `BuiltinGroup.titleKey` (Task 1).
- Produces: no new public surface; pure internal refactor.

- [ ] **Step 1: Delete the four private static sets**

Remove lines 8-25 of `CommandPaletteWindowController.swift` (the `captureItems`, `translationItems`, `powerItems`, `toggleAppearanceItems` declarations and their doc comments). Leave the `private var state:` declaration that follows.

- [ ] **Step 2: Rebuild the `groups` array from `BuiltinGroup`**

In `collectSections(installedApps:)`, replace the hardcoded `groups` array (currently lines 196-201):

```swift
        let groups: [(L10n.Key, Set<BuiltinItem>)] = [
            (.commandPaletteSectionToggles, Self.toggleAppearanceItems),
            (.commandPaletteSectionPower, Self.powerItems),
            (.commandPaletteSectionCapture, Self.captureItems),
            (.commandPaletteSectionTranslation, Self.translationItems),
        ]
```

with:

```swift
        // Source the themed sub-groups from the shared BuiltinGroup catalog so
        // the palette and the Panel settings page never drift. Order and titles
        // are unchanged: themedDefaultOrder is [toggles, power, capture, translation].
        let groups: [(L10n.Key, Set<BuiltinItem>)] = BuiltinGroup.themedDefaultOrder.map { group in
            (group.titleKey!, group.members)
        }
```

(The force-unwrap is safe: `themedDefaultOrder` never contains `.general`, the only case whose `titleKey` is `nil`.)

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: builds with no reference to the deleted `Self.captureItems` etc.

- [ ] **Step 4: Run the command palette regression tests**

Run: `swift test --filter CommandPaletteTests`
Expected: PASS — section grouping output is unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Views/CommandPaletteWindowController.swift
git commit -m "refactor(command-palette): source group sets from BuiltinGroup"
```

---

### Task 3: `PanelGroupingStore` (UserDefaults persistence)

**Files:**
- Create: `Sources/AnyDoor/Services/PanelGroupingStore.swift`
- Test: `Tests/AnyDoorTests/PanelGroupingStoreTests.swift`

**Interfaces:**
- Consumes: `BuiltinGroup` (Task 1).
- Produces (all `@MainActor`):
  - `final class PanelGroupingStore` with `static let shared` and `init(defaults: UserDefaults = .standard)`.
  - `private(set) var themedOrder: [BuiltinGroup]` (reconciled, never contains `.general`)
  - `private(set) var collapsedGroups: Set<BuiltinGroup>`
  - `private(set) var collapsedParents: Set<BuiltinItem>`
  - `func setThemedOrder(_ groups: [BuiltinGroup])`
  - `func setCollapsed(_ group: BuiltinGroup, _ collapsed: Bool)`
  - `func isCollapsed(_ group: BuiltinGroup) -> Bool`
  - `func setParentCollapsed(_ item: BuiltinItem, _ collapsed: Bool)`
  - `func isParentCollapsed(_ item: BuiltinItem) -> Bool`
  - `func orderIndex(for group: BuiltinGroup) -> Int` (general → 0, themed → 1-based user order)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnyDoorTests/PanelGroupingStoreTests.swift
import XCTest
@testable import AnyDoor

/// `PanelGroupingStore` persists the Panel settings group order + collapse
/// state in UserDefaults. These tests use an isolated suite so they never
/// touch real preferences, and pin reconcile/default behavior.
final class PanelGroupingStoreTests: XCTestCase {

    private func makeStore(_ name: String) -> (PanelGroupingStore, UserDefaults) {
        let suite = "PanelGroupingStoreTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (PanelGroupingStore(defaults: defaults), defaults)
    }

    @MainActor
    func testDefaultsToThemedDefaultOrderAllExpanded() {
        let (store, _) = makeStore(#function)
        XCTAssertEqual(store.themedOrder, BuiltinGroup.themedDefaultOrder)
        XCTAssertTrue(store.collapsedGroups.isEmpty)
        XCTAssertTrue(store.collapsedParents.isEmpty)
        // General is always first; themed groups follow 1-based.
        XCTAssertEqual(store.orderIndex(for: .general), 0)
        XCTAssertEqual(store.orderIndex(for: .togglesAppearance), 1)
        XCTAssertEqual(store.orderIndex(for: .translation), 4)
    }

    @MainActor
    func testReorderPersistsAndReindexes() {
        let (store, defaults) = makeStore(#function)
        store.setThemedOrder([.translation, .screenshot, .powerSession, .togglesAppearance])
        XCTAssertEqual(store.orderIndex(for: .translation), 1)
        XCTAssertEqual(store.orderIndex(for: .togglesAppearance), 4)
        // A fresh store reading the same defaults sees the persisted order.
        let reloaded = PanelGroupingStore(defaults: defaults)
        XCTAssertEqual(reloaded.themedOrder.first, .translation)
    }

    @MainActor
    func testCollapseTogglesPersist() {
        let (store, defaults) = makeStore(#function)
        store.setCollapsed(.screenshot, true)
        XCTAssertTrue(store.isCollapsed(.screenshot))
        XCTAssertFalse(store.isCollapsed(.powerSession))
        // General can never be collapsed.
        store.setCollapsed(.general, true)
        XCTAssertFalse(store.isCollapsed(.general))
        let reloaded = PanelGroupingStore(defaults: defaults)
        XCTAssertTrue(reloaded.isCollapsed(.screenshot))
    }

    @MainActor
    func testParentCollapsePersists() {
        let (store, _) = makeStore(#function)
        XCTAssertFalse(store.isParentCollapsed(.appShortcuts))
        store.setParentCollapsed(.appShortcuts, true)
        XCTAssertTrue(store.isParentCollapsed(.appShortcuts))
        store.setParentCollapsed(.appShortcuts, false)
        XCTAssertFalse(store.isParentCollapsed(.appShortcuts))
    }

    @MainActor
    func testReconcileDropsUnknownAndAppendsMissing() {
        let (_, defaults) = makeStore(#function)
        // Persist a malformed order: an unknown id, general (must be dropped),
        // a duplicate, and one missing themed group (powerSession).
        defaults.set(["bogus", "general", "translation", "translation", "screenshot", "togglesAppearance"],
                     forKey: "panel.groupOrder")
        let store = PanelGroupingStore(defaults: defaults)
        // Unknown + general + duplicate dropped; missing powerSession appended last.
        XCTAssertEqual(store.themedOrder,
                       [.translation, .screenshot, .togglesAppearance, .powerSession])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PanelGroupingStoreTests`
Expected: FAIL to compile — `cannot find 'PanelGroupingStore' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AnyDoor/Services/PanelGroupingStore.swift
import Foundation
import Observation

/// Persists the Panel settings page's themed-group order and collapse state in
/// UserDefaults (no SwiftData involvement). `@Observable` so the settings view
/// re-renders when order/collapse change. `.general` is the implicit,
/// headerless, always-first bucket: it is never stored in the order array and
/// can never be collapsed.
@MainActor
@Observable
final class PanelGroupingStore {
    static let shared = PanelGroupingStore()

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let order = "panel.groupOrder"
        static let collapsed = "panel.collapsedGroups"
        static let collapsedParents = "panel.collapsedParents"
    }

    private(set) var themedOrder: [BuiltinGroup]
    private(set) var collapsedGroups: Set<BuiltinGroup>
    private(set) var collapsedParents: Set<BuiltinItem>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.themedOrder = Self.reconcile(defaults.array(forKey: Keys.order) as? [String] ?? [])
        self.collapsedGroups = Set(
            (defaults.array(forKey: Keys.collapsed) as? [String] ?? [])
                .compactMap(BuiltinGroup.init(rawValue:))
                .filter { $0 != .general }
        )
        self.collapsedParents = Set(
            (defaults.array(forKey: Keys.collapsedParents) as? [String] ?? [])
                .compactMap(BuiltinItem.init(rawValue:))
        )
    }

    /// Drop unknown ids, `.general`, and duplicates; append any themed group
    /// missing from the stored order in default order. Never crashes on
    /// malformed input.
    private static func reconcile(_ stored: [String]) -> [BuiltinGroup] {
        var result: [BuiltinGroup] = []
        var seen = Set<BuiltinGroup>()
        for raw in stored {
            guard let group = BuiltinGroup(rawValue: raw),
                  group != .general,
                  BuiltinGroup.themedDefaultOrder.contains(group),
                  seen.insert(group).inserted else { continue }
            result.append(group)
        }
        for group in BuiltinGroup.themedDefaultOrder where !seen.contains(group) {
            result.append(group)
        }
        return result
    }

    func setThemedOrder(_ groups: [BuiltinGroup]) {
        themedOrder = Self.reconcile(groups.map(\.rawValue))
        defaults.set(themedOrder.map(\.rawValue), forKey: Keys.order)
    }

    func isCollapsed(_ group: BuiltinGroup) -> Bool {
        group != .general && collapsedGroups.contains(group)
    }

    func setCollapsed(_ group: BuiltinGroup, _ collapsed: Bool) {
        guard group != .general else { return }
        if collapsed { collapsedGroups.insert(group) } else { collapsedGroups.remove(group) }
        defaults.set(collapsedGroups.map(\.rawValue), forKey: Keys.collapsed)
    }

    func isParentCollapsed(_ item: BuiltinItem) -> Bool {
        collapsedParents.contains(item)
    }

    func setParentCollapsed(_ item: BuiltinItem, _ collapsed: Bool) {
        if collapsed { collapsedParents.insert(item) } else { collapsedParents.remove(item) }
        defaults.set(collapsedParents.map(\.rawValue), forKey: Keys.collapsedParents)
    }

    /// Sort index used by `PanelStore.rebuild()`: `.general` is 0 (always first),
    /// themed groups follow in user order starting at 1.
    func orderIndex(for group: BuiltinGroup) -> Int {
        guard group != .general else { return 0 }
        return themedOrder.firstIndex(of: group).map { $0 + 1 } ?? Int.max
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PanelGroupingStoreTests`
Expected: PASS (all 5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/PanelGroupingStore.swift Tests/AnyDoorTests/PanelGroupingStoreTests.swift
git commit -m "feat(panel): add PanelGroupingStore for group order and collapse"
```

---

### Task 4: `PanelStore` group-aware sort + reorder methods

**Files:**
- Modify: `Sources/AnyDoor/Services/PanelStore.swift` — `rebuild()` (sort `topLevelEntries`, ~line 150), replace `reorderTopLevel(by:)` (lines 517-533) with `reorderTopLevel(within:by:)`, add `reorderThemedGroups(by:)`, add a private `group(of:)` helper.
- Test: `Tests/AnyDoorTests/PanelStoreTests.swift` (append cases).

**Interfaces:**
- Consumes: `BuiltinGroup` (Task 1), `PanelGroupingStore.shared` (Task 3).
- Produces:
  - `func reorderTopLevel(within group: BuiltinGroup, by newOrder: [BuiltinItem])`
  - `func reorderThemedGroups(by newOrder: [BuiltinGroup])`
  - `topLevelEntries` now ordered by `(PanelGroupingStore.shared.orderIndex(for: group(of:)), displayOrder)`.
- Note: the old `reorderTopLevel(by:)` is removed; its only caller is `PanelSettingsView.move()` (updated in Task 7).

- [ ] **Step 1: Write the failing test (append to PanelStoreTests.swift)**

```swift
    @MainActor
    func testTopLevelEntriesAreGroupContiguous() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: KeyBinding.self, BuiltinPreference.self, configurations: config
        )
        BuiltinPreferenceSeeder.seedIfNeeded(in: container.mainContext)
        // Ensure default group order for a deterministic assertion.
        PanelGroupingStore.shared.setThemedOrder(BuiltinGroup.themedDefaultOrder)

        let store = PanelStore.shared
        store.bootstrap(modelContainer: container, providers: [])

        // Map each top-level entry to its group order index; the sequence of
        // indices must be non-decreasing (every group forms a contiguous block).
        let indices = store.topLevelEntries.compactMap { entry -> Int? in
            guard case .builtin(let item) = entry.source else { return nil }
            return PanelGroupingStore.shared.orderIndex(for: BuiltinGroup.group(for: item))
        }
        XCTAssertEqual(indices, indices.sorted(), "top-level entries must be grouped contiguously")
        // General (index 0) leads, so the first entry belongs to .general.
        let firstItem: BuiltinItem? = {
            if case .builtin(let item) = store.topLevelEntries.first?.source { return item }
            return nil
        }()
        XCTAssertEqual(firstItem.map(BuiltinGroup.group(for:)), .general)
    }

    @MainActor
    func testReorderWithinGroupOnlyTouchesThatGroup() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: KeyBinding.self, BuiltinPreference.self, configurations: config
        )
        BuiltinPreferenceSeeder.seedIfNeeded(in: container.mainContext)
        PanelGroupingStore.shared.setThemedOrder(BuiltinGroup.themedDefaultOrder)
        let store = PanelStore.shared
        store.bootstrap(modelContainer: container, providers: [])

        func powerItems() -> [BuiltinItem] {
            store.topLevelEntries.compactMap { entry in
                guard case .builtin(let item) = entry.source,
                      BuiltinGroup.group(for: item) == .powerSession else { return nil }
                return item
            }
        }
        let before = powerItems()
        XCTAssertGreaterThan(before.count, 1)
        // Move the first power item to the end of the power group.
        var reordered = before
        let moved = reordered.removeFirst()
        reordered.append(moved)
        store.reorderTopLevel(within: .powerSession, by: reordered)

        XCTAssertEqual(powerItems(), reordered, "power group should reflect the new within-group order")
        // The translation group's relative order is unaffected.
        let translation = store.topLevelEntries.compactMap { entry -> BuiltinItem? in
            guard case .builtin(let item) = entry.source,
                  BuiltinGroup.group(for: item) == .translation else { return nil }
            return item
        }
        XCTAssertEqual(translation, [.translate, .screenshotTranslate, .translateSelection])
    }

    @MainActor
    func testReorderThemedGroupsChangesSectionOrder() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: KeyBinding.self, BuiltinPreference.self, configurations: config
        )
        BuiltinPreferenceSeeder.seedIfNeeded(in: container.mainContext)
        let store = PanelStore.shared
        store.bootstrap(modelContainer: container, providers: [])

        store.reorderThemedGroups(by: [.translation, .togglesAppearance, .powerSession, .screenshot])
        // After reorder, translation (now index 1) precedes togglesAppearance (index 2).
        func firstIndexOfGroup(_ g: BuiltinGroup) -> Int? {
            store.topLevelEntries.firstIndex {
                guard case .builtin(let item) = $0.source else { return false }
                return BuiltinGroup.group(for: item) == g
            }
        }
        XCTAssertNotNil(firstIndexOfGroup(.translation))
        XCTAssertLessThan(firstIndexOfGroup(.translation)!, firstIndexOfGroup(.togglesAppearance)!)

        // Restore default order so later tests are deterministic.
        store.reorderThemedGroups(by: BuiltinGroup.themedDefaultOrder)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PanelStoreTests`
Expected: FAIL to compile — `reorderTopLevel(within:by:)` / `reorderThemedGroups(by:)` do not exist.

- [ ] **Step 3a: Sort `topLevelEntries` by group in `rebuild()`**

In `PanelStore.rebuild()`, change the assignment at line 150 from:

```swift
        self.topLevelEntries = topLevel
```

to:

```swift
        // Sort by (group order index, displayOrder) so both this settings page
        // and the menu-bar panel render group-contiguous blocks. Existing
        // displayOrder values stay valid as within-group order — no migration.
        let grouping = PanelGroupingStore.shared
        self.topLevelEntries = topLevel.sorted { lhs, rhs in
            let li = grouping.orderIndex(for: group(of: lhs))
            let ri = grouping.orderIndex(for: group(of: rhs))
            if li != ri { return li < ri }
            return lhs.displayOrder < rhs.displayOrder
        }
```

Add this private helper near `rebuild()` (e.g. right after the method):

```swift
    /// The themed group an entry belongs to. Non-builtin top-level entries (none
    /// today) fall into `.general`.
    private func group(of entry: PanelEntry) -> BuiltinGroup {
        if case .builtin(let item) = entry.source { return BuiltinGroup.group(for: item) }
        return .general
    }
```

- [ ] **Step 3b: Replace `reorderTopLevel(by:)` and add `reorderThemedGroups(by:)`**

Replace the whole `reorderTopLevel(by:)` method (lines 517-533) with:

```swift
    /// Reorder the top-level entries inside a single group. Reassigns
    /// `displayOrder` (stride 100) for that group's items only; cross-group
    /// order is unaffected because the group order index dominates the sort in
    /// `rebuild()`, so per-group displayOrder need only be monotonic.
    func reorderTopLevel(within group: BuiltinGroup, by newOrder: [BuiltinItem]) {
        guard let container = modelContainer else { return }
        let context = container.mainContext
        guard let prefs = try? context.fetch(FetchDescriptor<BuiltinPreference>()) else { return }
        let prefsByKey = Dictionary(uniqueKeysWithValues: prefs.map { ($0.itemKey, $0) })
        var order: Double = 100
        for item in newOrder where BuiltinGroup.group(for: item) == group {
            if let pref = prefsByKey[item.rawValue] {
                pref.displayOrder = order
                order += 100
            }
        }
        try? context.save()
        rebuild()
        rebuildHotkeySnapshots()
    }

    /// Reorder the themed sections themselves. Persists the new order in
    /// `PanelGroupingStore` and rebuilds; bindings are unchanged so no hotkey
    /// snapshot rebuild is needed.
    func reorderThemedGroups(by newOrder: [BuiltinGroup]) {
        PanelGroupingStore.shared.setThemedOrder(newOrder)
        rebuild()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PanelStoreTests`
Expected: PASS — including the three new cases and the pre-existing ones.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/PanelStore.swift Tests/AnyDoorTests/PanelStoreTests.swift
git commit -m "feat(panel): sort top-level entries by group and add group-scoped reorder"
```

---

### Task 5: Parameterize `PanelDragGroup` + add group-header drag

**Files:**
- Modify: `Sources/AnyDoor/Views/PanelReorder.swift` (the `PanelDragGroup` enum; `localMove` logic is unchanged).
- Modify: `Tests/AnyDoorTests/PanelReorderTests.swift` (update `groups` fixture to the parameterized cases; add a group-header case).

**Interfaces:**
- Consumes: `BuiltinGroup` (Task 1).
- Produces:
  - `enum PanelDragGroup: Equatable { case topLevel(BuiltinGroup); case groupHeader; case appChild; case windowChild; case fixed }`
  - `PanelReorder.localMove(groups:from:to:)` unchanged signature; now naturally confines a `.topLevel(group)` drag to its own group and a `.groupHeader` drag to the header row sequence.

- [ ] **Step 1: Update the test fixture and add a header test (edit PanelReorderTests.swift)**

Replace the `groups` fixture (lines 25-34) so top-level rows carry their group and a themed header row exists:

```swift
    /// A representative flattened Panel list (general bucket first, then a
    /// themed section with a header):
    ///   0  topLevel(.general)  appShortcuts (parent)
    ///   1  appChild            Codex
    ///   2  appChild            ChatGPT
    ///   3  fixed               add-app button
    ///   4  topLevel(.general)  clipboard
    ///   5  topLevel(.general)  windowLayout (parent)
    ///   6  windowChild         left half
    ///   7  windowChild         right half
    ///   8  groupHeader         "Toggles & Appearance"
    ///   9  topLevel(.togglesAppearance) brightness
    ///  10  fixed               brightness recorders
    ///  11  topLevel(.togglesAppearance) muteAudio
    ///  12  groupHeader         "Power & Session"
    ///  13  topLevel(.powerSession) lockScreen
    private let groups: [PanelDragGroup] = [
        .topLevel(.general),
        .appChild, .appChild,
        .fixed,
        .topLevel(.general),
        .topLevel(.general),
        .windowChild, .windowChild,
        .groupHeader,
        .topLevel(.togglesAppearance),
        .fixed,
        .topLevel(.togglesAppearance),
        .groupHeader,
        .topLevel(.powerSession),
    ]

    @Test func movesAppChildToFrontOfItsGroup() {
        // Drag ChatGPT (flat 2) before Codex (insertion index 1).
        let result = PanelReorder.localMove(groups: groups, from: IndexSet(integer: 2), to: 1)
        #expect(result?.group == .appChild)
        #expect(result?.from == 1)
        #expect(result?.to == 0)
    }

    @Test func topLevelDragIsConfinedToItsOwnGroup() {
        // Drag muteAudio (flat 11, the 2nd toggles item) above brightness
        // (insertion index 9). Only the two togglesAppearance rows count.
        let result = PanelReorder.localMove(groups: groups, from: IndexSet(integer: 11), to: 9)
        #expect(result?.group == .topLevel(.togglesAppearance))
        #expect(result?.from == 1)
        #expect(result?.to == 0)
    }

    @Test func generalTopLevelDragSkipsChildrenAndOtherGroups() {
        // Drag windowLayout (flat 5, the 3rd general row) to the very top.
        // General flat indices are [0,4,5]; windowLayout is local index 2.
        let result = PanelReorder.localMove(groups: groups, from: IndexSet(integer: 5), to: 0)
        #expect(result?.group == .topLevel(.general))
        #expect(result?.from == 2)
        #expect(result?.to == 0)
    }

    @Test func draggingAHeaderReordersAmongHeaders() {
        // Drag the "Power & Session" header (flat 12) above the
        // "Toggles & Appearance" header (insertion index 8). Header flat
        // indices are [8,12]; the dragged one is local index 1.
        let result = PanelReorder.localMove(groups: groups, from: IndexSet(integer: 12), to: 8)
        #expect(result?.group == .groupHeader)
        #expect(result?.from == 1)
        #expect(result?.to == 0)
    }

    @Test func reordersWindowChildren() {
        // Drag the second window child (flat 7) before the first (insertion index 6).
        let result = PanelReorder.localMove(groups: groups, from: IndexSet(integer: 7), to: 6)
        #expect(result?.group == .windowChild)
        #expect(result?.from == 1)
        #expect(result?.to == 0)
    }

    @Test func fixedRowsAreNotReorderable() {
        // The add-app button (flat 3) and brightness recorders (flat 10) never move.
        #expect(PanelReorder.localMove(groups: groups, from: IndexSet(integer: 3), to: 0) == nil)
        #expect(PanelReorder.localMove(groups: groups, from: IndexSet(integer: 10), to: 0) == nil)
    }

    @Test func emptyOrOutOfRangeSourceReturnsNil() {
        #expect(PanelReorder.localMove(groups: groups, from: IndexSet(), to: 0) == nil)
        #expect(PanelReorder.localMove(groups: groups, from: IndexSet(integer: 99), to: 0) == nil)
    }
```

(Delete the old `movesAppChildTowardEndOfItsGroup`, `dropOutsideTheGroupClampsToTheGroupEnd`, and `reordersTopLevelSkippingInterspersedChildren` tests — the new cases above supersede them against the parameterized fixture.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PanelReorderTests`
Expected: FAIL to compile — `.topLevel` now needs an argument; `.groupHeader` undefined.

- [ ] **Step 3: Update the enum**

In `PanelReorder.swift`, replace the `PanelDragGroup` enum:

```swift
enum PanelDragGroup: Equatable {
    /// A top-level built-in row, tagged with its themed group so a drag is
    /// confined to siblings in the same group (cross-group dragging is rejected
    /// because `.topLevel(.a) != .topLevel(.b)`).
    case topLevel(BuiltinGroup)
    /// A themed section header row; dragging one reorders the themed groups.
    case groupHeader
    case appChild
    case windowChild
    /// Non-draggable adornment rows (the "add app" button, brightness recorders).
    case fixed
}
```

The body of `localMove` needs NO change: it groups rows by `==` and excludes only `.fixed`, so `.topLevel(group)` confines per group and `.groupHeader` confines to headers automatically.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PanelReorderTests`
Expected: PASS (all 7 cases).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Views/PanelReorder.swift Tests/AnyDoorTests/PanelReorderTests.swift
git commit -m "feat(panel): tag top-level drags by group and add group-header drag"
```

---

### Task 6: Pure row builder for the grouped settings list

**Files:**
- Create: `Sources/AnyDoor/Views/PanelSettingsRowBuilder.swift`
- Test: `Tests/AnyDoorTests/PanelSettingsRowBuilderTests.swift`

**Interfaces:**
- Consumes: `PanelEntry`, `BuiltinItem`, `BuiltinGroup` (Task 1), `PanelDragGroup` (Task 5).
- Produces:
  - `struct PanelSettingsRow: Identifiable { let id: String; let content: Content; let group: PanelDragGroup; let opacity: Double }`
  - `enum PanelSettingsRow.Content { case entry(PanelEntry); case header(BuiltinGroup); case addApp; case brightnessRecorders }`
  - `enum PanelSettingsRowBuilder { static func build(topLevel:appChildren:windowChildren:themedOrder:collapsedGroups:collapsedParents:) -> [PanelSettingsRow] }`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnyDoorTests/PanelSettingsRowBuilderTests.swift
import Foundation
import Testing
@testable import AnyDoor

/// `PanelSettingsRowBuilder` flattens grouped Panel entries into one ordered
/// list of rows (with injected section headers + collapse handling) that the
/// settings `List` renders. These tests pin header placement and the two
/// collapse behaviors without spinning up SwiftUI.
struct PanelSettingsRowBuilderTests {

    private func entry(_ item: BuiltinItem, visible: Bool = true) -> PanelEntry {
        PanelEntry(
            id: PanelEntry.id(for: .builtin(item)),
            source: .builtin(item),
            displayOrder: item.defaultOrder,
            isVisible: visible,
            hotkey: nil,
            title: "",
            subtitle: nil,
            symbol: item.symbol,
            kind: item.kind,
            toggleState: nil,
            permission: .notRequired
        )
    }

    private func appChild(_ name: String) -> PanelEntry {
        PanelEntry(
            id: "appChild:\(name)",
            source: .appShortcut(UUID()),
            displayOrder: 100,
            isVisible: true,
            hotkey: nil,
            title: name,
            subtitle: nil,
            symbol: "app.fill",
            kind: .submenu,
            toggleState: nil,
            permission: .notRequired
        )
    }

    /// general: appShortcuts, clipboardWall ; togglesAppearance: brightness, muteAudio
    private func sampleTopLevel() -> [PanelEntry] {
        [entry(.appShortcuts), entry(.clipboardWall), entry(.brightness), entry(.muteAudio)]
    }

    @Test func generalEntriesLeadWithoutAHeader() {
        let rows = PanelSettingsRowBuilder.build(
            topLevel: sampleTopLevel(),
            appChildren: [],
            windowChildren: [],
            themedOrder: [.togglesAppearance],
            collapsedGroups: [],
            collapsedParents: []
        )
        // First row is the general appShortcuts entry, not a header.
        guard case .entry(let first) = rows.first?.content else {
            Issue.record("first row should be an entry"); return
        }
        #expect(first.source == .builtin(.appShortcuts))
        #expect(rows.first?.group == .topLevel(.general))
        // Exactly one header exists, for togglesAppearance.
        let headers = rows.compactMap { row -> BuiltinGroup? in
            if case .header(let g) = row.content { return g } else { return nil }
        }
        #expect(headers == [.togglesAppearance])
    }

    @Test func collapsedThemedGroupEmitsHeaderOnly() {
        let rows = PanelSettingsRowBuilder.build(
            topLevel: sampleTopLevel(),
            appChildren: [],
            windowChildren: [],
            themedOrder: [.togglesAppearance],
            collapsedGroups: [.togglesAppearance],
            collapsedParents: []
        )
        // The header is present but neither brightness nor muteAudio rows follow.
        #expect(rows.contains { if case .header(.togglesAppearance) = $0.content { return true } else { return false } })
        let toggleEntries = rows.contains { row in
            if case .entry(let e) = row.content, case .builtin(let i) = e.source {
                return BuiltinGroup.group(for: i) == .togglesAppearance
            }
            return false
        }
        #expect(!toggleEntries)
    }

    @Test func collapsedAppShortcutsParentHidesChildrenAndAddRow() {
        let expanded = PanelSettingsRowBuilder.build(
            topLevel: [entry(.appShortcuts)],
            appChildren: [appChild("Codex"), appChild("Warp")],
            windowChildren: [],
            themedOrder: [],
            collapsedGroups: [],
            collapsedParents: []
        )
        // Expanded: parent + 2 app children + add-app row.
        #expect(expanded.contains { $0.group == .appChild })
        #expect(expanded.contains { if case .addApp = $0.content { return true } else { return false } })

        let collapsed = PanelSettingsRowBuilder.build(
            topLevel: [entry(.appShortcuts)],
            appChildren: [appChild("Codex"), appChild("Warp")],
            windowChildren: [],
            themedOrder: [],
            collapsedGroups: [],
            collapsedParents: [.appShortcuts]
        )
        // Collapsed: only the parent entry remains.
        #expect(!collapsed.contains { $0.group == .appChild })
        #expect(!collapsed.contains { if case .addApp = $0.content { return true } else { return false } })
        #expect(collapsed.contains { if case .entry(let e) = $0.content { return e.source == .builtin(.appShortcuts) } else { return false } })
    }

    @Test func brightnessRecordersFollowBrightnessInThemedGroup() {
        let rows = PanelSettingsRowBuilder.build(
            topLevel: [entry(.brightness)],
            appChildren: [],
            windowChildren: [],
            themedOrder: [.togglesAppearance],
            collapsedGroups: [],
            collapsedParents: []
        )
        let recorderIndex = rows.firstIndex { if case .brightnessRecorders = $0.content { return true } else { return false } }
        let brightnessIndex = rows.firstIndex { if case .entry(let e) = $0.content { return e.source == .builtin(.brightness) } else { return false } }
        #expect(recorderIndex != nil && brightnessIndex != nil)
        #expect(recorderIndex! == brightnessIndex! + 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PanelSettingsRowBuilderTests`
Expected: FAIL to compile — `PanelSettingsRowBuilder` / `PanelSettingsRow` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AnyDoor/Views/PanelSettingsRowBuilder.swift
import Foundation

/// A single flat row in the Panel settings list: a themed section header, a
/// top-level / child entry, or a non-draggable adornment.
struct PanelSettingsRow: Identifiable {
    enum Content {
        case header(BuiltinGroup)
        case entry(PanelEntry)
        case addApp
        case brightnessRecorders
    }
    let id: String
    let content: Content
    let group: PanelDragGroup
    let opacity: Double
}

/// Pure flattening of grouped Panel entries into the ordered row list rendered
/// by `PanelSettingsView`. Kept separate from the view so the grouping +
/// collapse logic is unit-testable without SwiftUI.
///
/// Order: the headerless `.general` bucket first, then each themed group in
/// `themedOrder` preceded by a `.header` row. App-shortcut children + the
/// "add app" row follow the `appShortcuts` parent; window children follow the
/// `windowLayout` parent; brightness recorders follow the `brightness` row.
/// A collapsed themed group emits only its header; a collapsed parent emits the
/// parent row without its children.
enum PanelSettingsRowBuilder {
    static func build(
        topLevel: [PanelEntry],
        appChildren: [PanelEntry],
        windowChildren: [PanelEntry],
        themedOrder: [BuiltinGroup],
        collapsedGroups: Set<BuiltinGroup>,
        collapsedParents: Set<BuiltinItem>
    ) -> [PanelSettingsRow] {
        var rows: [PanelSettingsRow] = []

        func builtin(_ entry: PanelEntry) -> BuiltinItem? {
            if case .builtin(let item) = entry.source { return item }
            return nil
        }
        func isVisible(_ item: BuiltinItem) -> Bool {
            topLevel.first { $0.source == .builtin(item) }?.isVisible ?? true
        }

        // Emit one top-level entry plus any adornments/children that hang off it.
        func emit(_ entry: PanelEntry, dragGroup: PanelDragGroup) {
            rows.append(PanelSettingsRow(
                id: "top:\(entry.id)",
                content: .entry(entry),
                group: dragGroup,
                opacity: entry.isVisible ? 1.0 : 0.5
            ))
            switch entry.source {
            case .builtin(.appShortcuts):
                guard !collapsedParents.contains(.appShortcuts) else { return }
                let parentVisible = isVisible(.appShortcuts)
                for child in appChildren {
                    let visible = parentVisible && child.isVisible
                    rows.append(PanelSettingsRow(
                        id: "appChild:\(child.id)",
                        content: .entry(child),
                        group: .appChild,
                        opacity: visible ? 1.0 : 0.5
                    ))
                }
                rows.append(PanelSettingsRow(
                    id: "addApp",
                    content: .addApp,
                    group: .fixed,
                    opacity: parentVisible ? 1.0 : 0.5
                ))
            case .builtin(.windowLayout):
                guard !collapsedParents.contains(.windowLayout) else { return }
                let parentVisible = isVisible(.windowLayout)
                for child in windowChildren {
                    rows.append(PanelSettingsRow(
                        id: "windowChild:\(child.id)",
                        content: .entry(child),
                        group: .windowChild,
                        opacity: parentVisible ? 1.0 : 0.5
                    ))
                }
            case .builtin(.brightness):
                rows.append(PanelSettingsRow(
                    id: "brightnessRecorders",
                    content: .brightnessRecorders,
                    group: .fixed,
                    opacity: isVisible(.brightness) ? 1.0 : 0.5
                ))
            default:
                break
            }
        }

        // General bucket first, no header. topLevel is already sorted
        // group-contiguously by PanelStore, so filtering preserves order.
        for entry in topLevel where (builtin(entry).map(BuiltinGroup.group(for:)) ?? .general) == .general {
            emit(entry, dragGroup: .topLevel(.general))
        }

        // Themed sections, each preceded by a header row.
        for group in themedOrder {
            rows.append(PanelSettingsRow(
                id: "header:\(group.rawValue)",
                content: .header(group),
                group: .groupHeader,
                opacity: 1.0
            ))
            guard !collapsedGroups.contains(group) else { continue }
            for entry in topLevel where builtin(entry).map(BuiltinGroup.group(for:)) == group {
                emit(entry, dragGroup: .topLevel(group))
            }
        }

        return rows
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PanelSettingsRowBuilderTests`
Expected: PASS (all 4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Views/PanelSettingsRowBuilder.swift Tests/AnyDoorTests/PanelSettingsRowBuilderTests.swift
git commit -m "feat(panel): add pure row builder for grouped settings list"
```

---

### Task 7: Wire grouped rendering into `PanelSettingsView`

**Files:**
- Modify: `Sources/AnyDoor/Views/PanelSettingsView.swift` — replace the private `PanelListRow` type + `displayRows` with the Task 6 builder, add `headerRow` + parent-collapse chevron, and rewrite `move(...)` to route the new drag groups.

**Interfaces:**
- Consumes: `PanelSettingsRowBuilder` / `PanelSettingsRow` (Task 6), `PanelGroupingStore.shared` (Task 3), `PanelStore.reorderTopLevel(within:by:)` / `reorderThemedGroups(by:)` (Task 4), `PanelDragGroup` (Task 5).
- Produces: no testable surface (SwiftUI view); verified by build + manual run.

- [ ] **Step 1: Observe the grouping store and replace `displayRows`**

At the top of `PanelSettingsView`, add the store alongside the existing `@State`:

```swift
    @State private var panel = PanelStore.shared
    @State private var grouping = PanelGroupingStore.shared
```

Delete the private `struct PanelListRow { … }` (lines 55-65) and the `displayRows` computed property (lines 70-122). Replace `displayRows` with a call into the builder:

```swift
    private var displayRows: [PanelSettingsRow] {
        PanelSettingsRowBuilder.build(
            topLevel: panel.topLevelEntries,
            appChildren: panel.appShortcutChildren,
            windowChildren: panel.windowLayoutChildren,
            themedOrder: grouping.themedOrder,
            collapsedGroups: grouping.collapsedGroups,
            collapsedParents: grouping.collapsedParents
        )
    }
```

The `body`'s `ForEach(displayRows)` loop and `.moveDisabled(row.group == .fixed)` keep working unchanged (the new `PanelSettingsRow` has the same `id` / `group` / `opacity` shape).

- [ ] **Step 2: Route header rows in `rowView` and add the header view**

Replace `rowView(_:)` (lines 128-142) so it handles the new `.header` content and tags the app-shortcuts / window-layout parent rows for child collapse:

```swift
    @ViewBuilder
    private func rowView(_ row: PanelSettingsRow) -> some View {
        switch row.content {
        case let .header(group):
            headerRow(group)
        case let .entry(entry):
            switch row.group {
            case .appChild:    appChildRow(entry)
            case .windowChild: windowChildRow(entry)
            default:           mainRow(entry)
            }
        case .addApp:
            addAppButton()
        case .brightnessRecorders:
            brightnessHotkeyRecorders()
        }
    }

    /// A themed section header: a drag handle, a collapse chevron, the uppercase
    /// localized title, and a count of the group's top-level entries.
    private func headerRow(_ group: BuiltinGroup) -> some View {
        let count = panel.topLevelEntries.filter {
            if case .builtin(let item) = $0.source { return BuiltinGroup.group(for: item) == group }
            return false
        }.count
        let collapsed = grouping.isCollapsed(group)
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            if let titleKey = group.titleKey {
                LocalizedText(titleKey)
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
            }
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
            Spacer()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { grouping.setCollapsed(group, !collapsed) }
    }
```

- [ ] **Step 3: Add a child-collapse chevron to the `appShortcuts` / `windowLayout` parent rows**

In `mainRow(_:)` (lines 189-211), insert a disclosure chevron right after the drag handle for the two parent rows that own children. Replace the opening of `mainRow`:

```swift
    private func mainRow(_ entry: PanelEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
            parentDisclosure(for: entry)
            Toggle("", isOn: Binding(
```

…and add the helper:

```swift
    /// A collapse chevron for parent rows that own children (`appShortcuts`,
    /// `windowLayout`). Other rows get an equal-width spacer so columns align.
    @ViewBuilder
    private func parentDisclosure(for entry: PanelEntry) -> some View {
        if case let .builtin(item) = entry.source, item == .appShortcuts || item == .windowLayout {
            let collapsed = grouping.isParentCollapsed(item)
            Button {
                grouping.setParentCollapsed(item, !collapsed)
            } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 12)
        } else {
            Color.clear.frame(width: 12)
        }
    }
```

- [ ] **Step 4: Rewrite `move(...)` to route the new drag groups**

Replace `move(from:to:)` (lines 301-331) with:

```swift
    private func move(from source: IndexSet, to destination: Int) {
        let rows = displayRows
        guard let decision = PanelReorder.localMove(
            groups: rows.map(\.group), from: source, to: destination
        ) else { return }

        switch decision.group {
        case let .topLevel(group):
            var items = rows.compactMap { row -> BuiltinItem? in
                guard row.group == .topLevel(group), case let .entry(entry) = row.content,
                      case let .builtin(item) = entry.source else { return nil }
                return item
            }
            items.move(fromOffsets: IndexSet(integer: decision.from), toOffset: decision.to)
            panel.reorderTopLevel(within: group, by: items)
        case .groupHeader:
            var order = grouping.themedOrder
            order.move(fromOffsets: IndexSet(integer: decision.from), toOffset: decision.to)
            panel.reorderThemedGroups(by: order)
        case .appChild:
            var ids = panel.appShortcutChildren.compactMap { entry -> UUID? in
                if case let .appShortcut(id) = entry.source { return id } else { return nil }
            }
            ids.move(fromOffsets: IndexSet(integer: decision.from), toOffset: decision.to)
            panel.reorderAppShortcuts(by: ids)
        case .windowChild:
            var items = panel.windowLayoutChildren.compactMap { entry -> BuiltinItem? in
                if case let .builtin(item) = entry.source { return item } else { return nil }
            }
            items.move(fromOffsets: IndexSet(integer: decision.from), toOffset: decision.to)
            panel.reorderWindowChildren(by: items)
        case .fixed:
            break
        }
    }
```

- [ ] **Step 5: Build, run the full test suite, and verify in the app**

Run: `swift build`
Expected: compiles cleanly.

Run: `swift test`
Expected: PASS — all suites including BuiltinGroupTests, PanelGroupingStoreTests, PanelStoreTests, PanelReorderTests, PanelSettingsRowBuilderTests, CommandPaletteTests.

Run: `swift run AnyDoor`, open Settings → Panel, and confirm:
- General entries (app shortcuts, clipboard, window layout, hosts, ports…) lead with no header.
- Themed sections ("开关与外观", "电源与会话", "截图", "翻译") show headers with a chevron + count.
- Clicking a header collapses/expands its rows; state survives reopening Settings.
- The `appShortcuts` / `windowLayout` parent chevron collapses just their children.
- Dragging a row reorders within its group only; dragging a header reorders sections; the menu-bar panel reflects the new group-contiguous order.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Views/PanelSettingsView.swift
git commit -m "feat(panel): render Panel settings as collapsible themed groups"
```

---

## Self-Review Notes

- **Spec coverage:** shared taxonomy (Task 1) + palette refactor (Task 2); UserDefaults persistence for order/collapse/parent-collapse (Task 3); Model B sort + group-scoped reorder + group reorder (Task 4); group-scoped + header drag groups (Task 5); headerless General, themed headers, count badge, collapse, parent-collapse (Tasks 6-7). General-is-first and never collapsible enforced in `PanelGroupingStore` + builder. No SwiftData migration (sort-key-only Model B) per spec.
- **Type consistency:** `reorderTopLevel(within:by:)`, `reorderThemedGroups(by:)`, `PanelGroupingStore.themedOrder/collapsedGroups/collapsedParents/orderIndex(for:)`, `PanelDragGroup.topLevel(BuiltinGroup)` / `.groupHeader`, `PanelSettingsRow(.header/.entry/.addApp/.brightnessRecorders)`, and `PanelSettingsRowBuilder.build(...)` are used with identical signatures across the tasks that define and consume them.
- **No new L10n keys:** themed headers reuse `commandPaletteSectionToggles/Power/Capture/Translation`; the count badge is a numeral.
