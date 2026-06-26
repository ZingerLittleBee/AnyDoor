import XCTest
@testable import AnyDoor

/// `PanelGroupingStore` persists the Panel settings group order + collapse
/// state in UserDefaults. These tests use an isolated suite so they never
/// touch real preferences, and pin reconcile/default behavior.
final class PanelGroupingStoreTests: XCTestCase {

    @MainActor
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
