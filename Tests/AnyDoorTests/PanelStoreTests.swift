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
        // Flat displayOrder sort: keepAwake has the lowest defaultOrder (100).
        let firstSource = store.topLevelEntries.first?.source
        XCTAssertEqual(firstSource, .builtin(.keepAwake))
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
    func testAppShortcutPathsMapBindingIDToAppPath() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: KeyBinding.self, BuiltinPreference.self,
            configurations: config
        )
        let context = container.mainContext
        let a = KeyBinding(keyCode: 122, modifierFlags: 0,
                           appBundleID: "a", appName: "A", appPath: "/Applications/A.app",
                           displayOrder: 100)
        context.insert(a)
        try context.save()

        let store = PanelStore.shared
        store.bootstrap(modelContainer: container, providers: [])

        // The path map lets settings rows resolve the Finder icon by path with
        // no per-render SwiftData fetch.
        XCTAssertEqual(store.appShortcutPaths[a.id], "/Applications/A.app")
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
    func testTopLevelEntriesSortedByDisplayOrder() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: KeyBinding.self, BuiltinPreference.self, configurations: config
        )
        BuiltinPreferenceSeeder.seedIfNeeded(in: container.mainContext)

        let store = PanelStore.shared
        store.bootstrap(modelContainer: container, providers: [])

        // The Panel settings page is an ungrouped flat list: top-level entries
        // are ordered purely by displayOrder.
        let orders = store.topLevelEntries.map(\.displayOrder)
        XCTAssertEqual(orders, orders.sorted(), "top-level entries must be sorted by displayOrder")
    }

    @MainActor
    func testReorderTopLevelPersistsFlatOrder() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: KeyBinding.self, BuiltinPreference.self, configurations: config
        )
        BuiltinPreferenceSeeder.seedIfNeeded(in: container.mainContext)
        let store = PanelStore.shared
        store.bootstrap(modelContainer: container, providers: [])

        func topItems() -> [BuiltinItem] {
            store.topLevelEntries.compactMap { entry in
                if case .builtin(let item) = entry.source { return item }
                return nil
            }
        }
        let before = topItems()
        XCTAssertGreaterThan(before.count, 2)
        // Move the first item to the end of the flat list.
        var reordered = before
        let moved = reordered.removeFirst()
        reordered.append(moved)
        store.reorderTopLevel(by: reordered)

        XCTAssertEqual(topItems(), reordered, "top-level order must reflect the flat reorder")
    }
}
