import XCTest
import SwiftData
import PluginInterface
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

/// A switch that only counts its reads. Registered for the two items whose
/// state `refreshAll` takes from their owners, it must never be read.
private actor ReadCountingToggleProvider: ToggleProvider {
    let itemKey: BuiltinItem
    private(set) var readCount = 0

    init(_ itemKey: BuiltinItem) {
        self.itemKey = itemKey
    }

    var permission: PermissionStatus { .notRequired }

    func readState() async throws -> Bool {
        readCount += 1
        return false
    }

    func setState(_ enabled: Bool) async throws {}
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
    func testHotkeyMutationUsesBootstrappedRefreshHandler() throws {
        let container = try ModelContainer(
            for: KeyBinding.self, BuiltinPreference.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        BuiltinPreferenceSeeder.seedIfNeeded(in: container.mainContext)
        var refreshCount = 0
        let store = PanelStore()
        store.bootstrap(
            modelContainer: container,
            providers: [],
            refreshHotkeys: { refreshCount += 1 }
        )

        store.setBuiltinHotkey(
            .keepAwake,
            hotkey: HotkeyDescriptor(keyCode: 40, modifierFlags: 1)
        )

        XCTAssertEqual(refreshCount, 1)
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

    // MARK: - Keep Awake and Scheduled Shutdown state

    @MainActor
    func testRefreshAllReadsNeitherKeepAwakeNorShutdownProvider() async throws {
        // Both rows take their state from the owner after the provider loop,
        // so their boolean `readState` is skipped.
        let shutdown = makeShutdownService()
        shutdown.arm(.minutes(30))   // before bootstrap, so only refreshAll reads it
        defer { shutdown.cancel() }
        let keepAwakeSpy = ReadCountingToggleProvider(.keepAwake)
        let shutdownSpy = ReadCountingToggleProvider(.scheduledShutdown)
        let store = try makePanelLaneTestStore(
            rows: [.keepAwake, .scheduledShutdown],
            providers: [keepAwakeSpy, shutdownSpy],
            scheduledShutdown: shutdown
        )

        await store.refreshAll()

        let keepAwakeReads = await keepAwakeSpy.readCount
        let shutdownReads = await shutdownSpy.readCount
        XCTAssertEqual(keepAwakeReads, 0)
        XCTAssertEqual(shutdownReads, 0)
        // Behavior preservation: the row still shows the service's schedule.
        XCTAssertEqual(row(.scheduledShutdown, in: store)?.toggleState, true)
        XCTAssertNotNil(row(.scheduledShutdown, in: store)?.subtitle)
    }

    @MainActor
    func testRefreshAllShowsATimedKeepAwakeAsOnWithItsEndTime() async throws {
        // Behavior preservation: the switch and the subtitle agree.
        let provider = KeepAwakeProvider(backend: MockKeepAwakeBackend())
        try await provider.apply(.minutes(30))
        addTeardownBlock { try? await provider.apply(nil) }
        let store = try makePanelLaneTestStore(rows: [.keepAwake], providers: [provider])

        await store.refreshAll()

        if case .timed = store.keepAwakeState {} else {
            XCTFail("expected a timed state, got \(store.keepAwakeState)")
        }
        XCTAssertEqual(row(.keepAwake, in: store)?.toggleState, true)
        XCTAssertNotNil(row(.keepAwake, in: store)?.subtitle)
    }

    @MainActor
    func testScheduledShutdownToggleReachesTheRowThroughTheServicePush() async throws {
        // Behavior preservation: with the read-back gone, the push that
        // `bootstrap` subscribes is what updates the row.
        let shutdown = makeShutdownService()
        let store = try makePanelLaneTestStore(rows: [.scheduledShutdown], scheduledShutdown: shutdown)

        await store.toggle(.scheduledShutdown)

        XCTAssertTrue(shutdown.state.isArmed)
        XCTAssertEqual(store.scheduledShutdownState, shutdown.state)
        XCTAssertEqual(row(.scheduledShutdown, in: store)?.toggleState, true)
        XCTAssertNotNil(row(.scheduledShutdown, in: store)?.subtitle)

        await store.toggle(.scheduledShutdown)

        XCTAssertEqual(shutdown.state, .off)
        XCTAssertEqual(store.scheduledShutdownState, .off)
        XCTAssertEqual(row(.scheduledShutdown, in: store)?.toggleState, false)
        XCTAssertNil(row(.scheduledShutdown, in: store)?.subtitle)
    }

    @MainActor
    func testScheduledShutdownDurationReachesTheRowThroughTheServicePush() async throws {
        // Behavior preservation for the clock menu and palette presets.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let shutdown = makeShutdownService(now: now)
        let store = try makePanelLaneTestStore(rows: [.scheduledShutdown], scheduledShutdown: shutdown)

        await store.setScheduledShutdownDuration(.minutes(15))

        XCTAssertEqual(store.scheduledShutdownState, .armed(fireDate: now.addingTimeInterval(15 * 60)))
        XCTAssertEqual(row(.scheduledShutdown, in: store)?.toggleState, true)

        await store.setScheduledShutdownDuration(nil)

        XCTAssertEqual(store.scheduledShutdownState, .off)
        XCTAssertEqual(row(.scheduledShutdown, in: store)?.toggleState, false)
    }

    @MainActor
    func testBootstrapSubscribesTheRowToServiceTransitions() async throws {
        // Transitions PanelStore does not start (a fire, a wake re-anchor, the
        // warning's Cancel, a backup reload) reach the row only through the
        // `onChange` subscription that `bootstrap` makes.
        let shutdown = makeShutdownService()
        let store = try makePanelLaneTestStore(rows: [.scheduledShutdown], scheduledShutdown: shutdown)

        shutdown.arm(.minutes(30))
        XCTAssertEqual(row(.scheduledShutdown, in: store)?.toggleState, true)

        shutdown.cancel()
        XCTAssertEqual(row(.scheduledShutdown, in: store)?.toggleState, false)
    }

    // MARK: - Helpers

    /// A service with a mock executor and warning, a temporary defaults suite,
    /// and a fixed clock, so arming it never reaches a real shutdown or the
    /// shared service. Tests that arm it end disarmed, which also invalidates
    /// its warning timer.
    @MainActor
    private func makeShutdownService(
        now: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> ScheduledShutdownService {
        ScheduledShutdownService(
            executor: MockShutdownExecutor(),
            warning: MockShutdownWarning(),
            defaults: makeTemporaryDefaults(),
            now: { now }
        )
    }

    @MainActor
    private func row(_ item: BuiltinItem, in store: PanelStore) -> PanelEntry? {
        store.topLevelEntries.first { $0.source == .builtin(item) }
    }
}
