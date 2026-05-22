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
        XCTAssertEqual(MenuBarIcon.visibilityKey, "menuBar.iconVisible")
        XCTAssertEqual(MenuBarIcon.nameKey, "menuBar.iconName")
    }

    func testIsVisibleDefaultsToTrueWhenUnset() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: MenuBarIcon.visibilityKey)
        defaults.removeObject(forKey: MenuBarIcon.visibilityKey)
        defer { if let original { defaults.set(original, forKey: MenuBarIcon.visibilityKey) } }

        XCTAssertTrue(MenuBarIcon.isVisible, "Unset visibility must read as true")
    }

    func testCurrentNameFallsBackToDefaultWhenUnset() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: MenuBarIcon.nameKey)
        defaults.removeObject(forKey: MenuBarIcon.nameKey)
        defer { if let original { defaults.set(original, forKey: MenuBarIcon.nameKey) } }

        XCTAssertEqual(MenuBarIcon.currentName, MenuBarIcon.defaultName)
    }
}
