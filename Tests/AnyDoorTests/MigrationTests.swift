import XCTest
import SwiftData
@testable import AnyDoor

final class MigrationTests: XCTestCase {
    func testKeyBindingDefaultsWhenInsertedWithoutOrder() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: KeyBinding.self, configurations: config)
        let context = ModelContext(container)

        let binding = KeyBinding(
            keyCode: 122, // F1
            modifierFlags: 0,
            appBundleID: "com.apple.Safari",
            appName: "Safari",
            appPath: "/Applications/Safari.app"
        )
        context.insert(binding)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<KeyBinding>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertTrue(fetched[0].isVisible)
        XCTAssertEqual(fetched[0].displayOrder, 0)
    }
}

final class BuiltinItemTests: XCTestCase {
    func testAllCasesHaveDistinctOrder() {
        let orders = BuiltinItem.allCases.map(\.defaultOrder)
        XCTAssertEqual(Set(orders).count, orders.count)
    }

    func testAppShortcutsIsSubmenu() {
        XCTAssertEqual(BuiltinItem.appShortcuts.kind, .submenu)
    }

    func testAutomationItemsAreFlagged() {
        XCTAssertTrue(BuiltinItem.darkMode.requiresAutomation)
        XCTAssertTrue(BuiltinItem.emptyTrash.requiresAutomation)
        XCTAssertFalse(BuiltinItem.keepAwake.requiresAutomation)
    }
}
