import XCTest
@testable import AnyDoor

/// `PanelGroupingStore` persists the Panel settings parent-row collapse state in
/// UserDefaults. These tests use an isolated suite so they never touch real
/// preferences.
final class PanelGroupingStoreTests: XCTestCase {

    @MainActor
    private func makeStore(_ name: String) -> (PanelGroupingStore, UserDefaults) {
        let suite = "PanelGroupingStoreTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (PanelGroupingStore(defaults: defaults), defaults)
    }

    @MainActor
    func testDefaultsToAllExpanded() {
        let (store, _) = makeStore(#function)
        XCTAssertTrue(store.collapsedParents.isEmpty)
        XCTAssertFalse(store.isParentCollapsed(.appShortcuts))
        XCTAssertFalse(store.isParentCollapsed(.windowLayout))
    }

    @MainActor
    func testParentCollapsePersists() {
        let (store, defaults) = makeStore(#function)
        store.setParentCollapsed(.appShortcuts, true)
        XCTAssertTrue(store.isParentCollapsed(.appShortcuts))
        XCTAssertFalse(store.isParentCollapsed(.windowLayout))
        // A fresh store reading the same defaults sees the persisted state.
        let reloaded = PanelGroupingStore(defaults: defaults)
        XCTAssertTrue(reloaded.isParentCollapsed(.appShortcuts))

        store.setParentCollapsed(.appShortcuts, false)
        XCTAssertFalse(store.isParentCollapsed(.appShortcuts))
    }
}
