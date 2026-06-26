import XCTest
import SwiftData
@testable import AnyDoor

/// An ActionProvider whose first `run()` re-enters `PanelStore.shared.run(.ocr)`
/// while it is itself still in-flight. The in-flight guard must drop that
/// re-entrant call, leaving `runCount == 1`. Without the guard the re-entrant
/// call invokes `run()` a second time and `runCount` reaches 2.
actor ReentrantProbeProvider: ActionProvider {
    let itemKey: BuiltinItem = .ocr
    var permission: PermissionStatus { .notRequired }

    private(set) var runCount = 0

    func run() async throws {
        runCount += 1
        if runCount == 1 {
            await PanelStore.shared.run(.ocr)
        }
    }
}

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

        // hiddenHotkey items (brightnessUp/brightnessDown) are seeded but
        // filtered out of topLevelEntries — they own a hotkey, not a row.
        // Window-layout children are partitioned into windowLayoutChildren, not topLevelEntries.
        let windowChildKeys: Set<BuiltinItem> = [
            .windowLeftHalf, .windowRightHalf, .windowMaximize, .windowCenter,
            .windowTopHalf, .windowBottomHalf,
            .windowTopLeftQuarter, .windowTopRightQuarter,
            .windowBottomLeftQuarter, .windowBottomRightQuarter,
            .windowLeftThird, .windowCenterThird, .windowRightThird,
            .windowLeftTwoThirds, .windowRightTwoThirds,
            .windowMoveNextDisplay, .windowMovePreviousDisplay,
        ]
        let expectedVisible = BuiltinItem.allCases.filter {
            $0.kind != .hiddenHotkey && !windowChildKeys.contains($0)
        }
        XCTAssertEqual(store.topLevelEntries.count, expectedVisible.count)
        // Window children should appear in windowLayoutChildren instead
        XCTAssertEqual(store.windowLayoutChildren.count, windowChildKeys.count)
        // After group-aware sort, .general entries (group index 0) come first;
        // .appShortcuts has the lowest defaultOrder among general items (200).
        let firstSource = store.topLevelEntries.first?.source
        XCTAssertEqual(firstSource, .builtin(.appShortcuts))
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

    @MainActor
    func testRunDropsOverlappingCallForSameItem() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: KeyBinding.self, BuiltinPreference.self,
            configurations: config
        )
        let provider = ReentrantProbeProvider()
        let store = PanelStore.shared
        store.bootstrap(modelContainer: container, providers: [provider])

        // The provider re-enters store.run(.ocr) while its first run is in-flight.
        await store.run(.ocr)

        let count = await provider.runCount
        XCTAssertEqual(count, 1, "a run re-entered while the same item is in-flight must be dropped")
    }

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
}
