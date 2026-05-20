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

final class BuiltinPreferenceSeederTests: XCTestCase {
    @MainActor
    func testSeedsAllItemsOnEmptyStore() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BuiltinPreference.self, configurations: config)
        let context = ModelContext(container)

        BuiltinPreferenceSeeder.seedIfNeeded(in: context)

        let rows = try context.fetch(FetchDescriptor<BuiltinPreference>())
        XCTAssertEqual(rows.count, BuiltinItem.allCases.count)

        let keys = Set(rows.map(\.itemKey))
        for item in BuiltinItem.allCases {
            XCTAssertTrue(keys.contains(item.rawValue), "missing \(item.rawValue)")
        }
    }

    @MainActor
    func testSeedingIsIdempotent() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BuiltinPreference.self, configurations: config)
        let context = ModelContext(container)

        BuiltinPreferenceSeeder.seedIfNeeded(in: context)
        BuiltinPreferenceSeeder.seedIfNeeded(in: context)

        let rows = try context.fetch(FetchDescriptor<BuiltinPreference>())
        XCTAssertEqual(rows.count, BuiltinItem.allCases.count)
    }

    @MainActor
    func testSeedingAppendsNewItemsAtEnd() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BuiltinPreference.self, configurations: config)
        let context = ModelContext(container)

        // Pre-populate with one item to simulate prior state
        context.insert(BuiltinPreference(itemKey: BuiltinItem.keepAwake.rawValue,
                                          isVisible: true,
                                          displayOrder: 50))
        try context.save()

        BuiltinPreferenceSeeder.seedIfNeeded(in: context)

        let rows = try context.fetch(FetchDescriptor<BuiltinPreference>())
            .sorted { $0.displayOrder < $1.displayOrder }

        // Pre-existing row should still be at order 50
        XCTAssertEqual(rows.first?.itemKey, BuiltinItem.keepAwake.rawValue)
        XCTAssertEqual(rows.first?.displayOrder, 50)
        // New rows should all have order > 50
        for row in rows.dropFirst() {
            XCTAssertGreaterThan(row.displayOrder, 50)
        }
    }
}
