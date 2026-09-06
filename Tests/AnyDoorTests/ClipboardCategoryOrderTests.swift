import XCTest
@testable import AnyDoor

final class ClipboardCategoryOrderTests: XCTestCase {
    private let defaultOrder: [ClipboardWallCategory] = [
        .all, .favorites, .tag("t1"), .kind(.text), .kind(.image),
    ]

    func testEmptyPersistedKeepsDefaultOrder() {
        XCTAssertEqual(ClipboardCategoryOrder.merge(persistedIDs: [], available: defaultOrder),
                       defaultOrder)
    }

    func testPersistedOrderWins() {
        let merged = ClipboardCategoryOrder.merge(
            persistedIDs: ["kind:text", "tag:t1", "all", "favorites", "kind:image"],
            available: defaultOrder
        )
        XCTAssertEqual(merged, [.kind(.text), .tag("t1"), .all, .favorites, .kind(.image)])
    }

    func testStaleIDsDropAndUnknownCategoriesAppendInDefaultOrder() {
        // "tag:gone" was deleted; tag "t2" and the kinds were created/added
        // after the order was saved.
        let available: [ClipboardWallCategory] = [
            .all, .favorites, .tag("t1"), .tag("t2"), .kind(.text), .kind(.image),
        ]
        let merged = ClipboardCategoryOrder.merge(
            persistedIDs: ["tag:t1", "tag:gone", "all", "favorites"],
            available: available
        )
        XCTAssertEqual(merged, [.tag("t1"), .all, .favorites, .tag("t2"), .kind(.text), .kind(.image)])
    }

    @MainActor
    func testLinkAndEmailAppendAfterASavedPreUpgradeOrder() {
        // An order saved before the Link/Email categories existed keeps the
        // user's arrangement; the new categories append at the end, and their
        // ids round-trip through the persisted form.
        let available = ClipboardWallState.order(tags: [])
        let preUpgradeIDs = available
            .filter { $0 != .link && $0 != .email }
            .map(\.persistentID)
        let merged = ClipboardCategoryOrder.merge(
            persistedIDs: preUpgradeIDs,
            available: available
        )
        XCTAssertEqual(merged.suffix(2), [.link, .email])
        XCTAssertEqual(
            ClipboardCategoryOrder.merge(
                persistedIDs: merged.map(\.persistentID),
                available: available
            ),
            merged
        )
    }

    func testDuplicatePersistedIDsAreIgnored() {
        let merged = ClipboardCategoryOrder.merge(
            persistedIDs: ["favorites", "favorites", "all"],
            available: [.all, .favorites]
        )
        XCTAssertEqual(merged, [.favorites, .all])
    }

    func testSaveLoadRoundTrip() throws {
        let suite = "ClipboardCategoryOrderTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)

        XCTAssertEqual(ClipboardCategoryOrder.load(from: defaults), [])
        ClipboardCategoryOrder.save([.favorites, .tag("t1"), .all], to: defaults)
        XCTAssertEqual(ClipboardCategoryOrder.load(from: defaults),
                       ["favorites", "tag:t1", "all"])
        XCTAssertEqual(ClipboardCategoryOrder.apply(to: defaultOrder, defaults: defaults),
                       [.favorites, .tag("t1"), .all, .kind(.text), .kind(.image)])
    }

    func testCorruptJSONFallsBackToDefaultOrder() throws {
        let suite = "ClipboardCategoryOrderTests.corrupt"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("not json", forKey: ClipboardCategoryOrder.defaultsKey)

        XCTAssertEqual(ClipboardCategoryOrder.load(from: defaults), [])
        XCTAssertEqual(ClipboardCategoryOrder.apply(to: defaultOrder, defaults: defaults),
                       defaultOrder)
    }
}
