import XCTest
@testable import AnyDoor

final class MenuBarIconTests: XCTestCase {
    func testDefaultNameIsSelectable() {
        XCTAssertTrue(
            MenuBarIcon.options.contains(MenuBarIcon.defaultName),
            "Default icon must appear in the offered options so the picker can show it as selected"
        )
    }

    func testOptionsHaveNoDuplicates() {
        XCTAssertEqual(
            Set(MenuBarIcon.options).count,
            MenuBarIcon.options.count,
            "Icon options must be unique"
        )
    }

    func testStorageKeysAreDistinct() {
        XCTAssertNotEqual(MenuBarIcon.visibilityKey, MenuBarIcon.nameKey)
    }
}
