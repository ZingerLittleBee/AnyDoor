import XCTest
import SwiftData
import PluginInterface
@testable import AnyDoor

final class BuiltinPreferenceSeederTranslateTests: XCTestCase {
    private func makeInMemoryContext() throws -> ModelContext {
        let schema = Schema([
            KeyBinding.self,
            BuiltinPreference.self,
            ClipboardHistoryItem.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true, allowsSave: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    @MainActor
    func testTranslateItemsAreSeededVisibleOnEmptyStore() throws {
        let ctx = try makeInMemoryContext()
        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)

        let prefs = try ctx.fetch(FetchDescriptor<BuiltinPreference>())
        for key in ["translate", "screenshotTranslate", "translateSelection"] {
            let row = try XCTUnwrap(prefs.first { $0.itemKey == key }, "missing \(key)")
            XCTAssertTrue(row.isVisible, "\(key) should seed visible")
        }
    }

    @MainActor
    func testTranslateItemsAppendedOnUpgrade() throws {
        let ctx = try makeInMemoryContext()

        // Simulate an existing install that predates the translate items.
        ctx.insert(BuiltinPreference(itemKey: BuiltinItem.keepAwake.rawValue,
                                     isVisible: true,
                                     displayOrder: 50))
        try ctx.save()

        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)

        let prefs = try ctx.fetch(FetchDescriptor<BuiltinPreference>())
        for key in ["translate", "screenshotTranslate", "translateSelection"] {
            let row = try XCTUnwrap(prefs.first { $0.itemKey == key }, "missing \(key)")
            XCTAssertGreaterThan(row.displayOrder, 50, "\(key) should append after existing rows")
        }
    }
}
