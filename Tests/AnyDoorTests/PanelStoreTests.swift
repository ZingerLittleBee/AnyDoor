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

        XCTAssertEqual(store.topLevelEntries.count, BuiltinItem.allCases.count)
        // Order should follow defaultOrder — first entry should be keepAwake (defaultOrder 100)
        let firstSource = store.topLevelEntries.first?.source
        XCTAssertEqual(firstSource, .builtin(.keepAwake)) // defaultOrder 100 is smallest
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
}
