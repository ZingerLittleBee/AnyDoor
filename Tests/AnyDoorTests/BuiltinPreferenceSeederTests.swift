import XCTest
import SwiftData
@testable import AnyDoor

@MainActor
final class BuiltinPreferenceSeederTests: XCTestCase {
    private func makeInMemoryContext() throws -> ModelContext {
        let schema = Schema([
            KeyBinding.self,
            BuiltinPreference.self,
            ClipboardHistoryItem.self,
        ])
        let config = ModelConfiguration(
            isStoredInMemoryOnly: true,
            allowsSave: true
        )
        let container = try ModelContainer(for: schema, configurations: [config])
        return container.mainContext
    }

    func testHiddenHotkeyItemsAreSeededInvisible() throws {
        let ctx = try makeInMemoryContext()
        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)

        let prefs = try ctx.fetch(FetchDescriptor<BuiltinPreference>())
        let up = try XCTUnwrap(prefs.first { $0.itemKey == "brightnessUp" })
        let down = try XCTUnwrap(prefs.first { $0.itemKey == "brightnessDown" })
        XCTAssertFalse(up.isVisible)
        XCTAssertFalse(down.isVisible)
    }

    func testRegularItemsAreSeededVisible() throws {
        let ctx = try makeInMemoryContext()
        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)

        let prefs = try ctx.fetch(FetchDescriptor<BuiltinPreference>())
        let brightness = try XCTUnwrap(prefs.first { $0.itemKey == "brightness" })
        let keepAwake = try XCTUnwrap(prefs.first { $0.itemKey == "keepAwake" })
        XCTAssertTrue(brightness.isVisible)
        XCTAssertTrue(keepAwake.isVisible)
    }

    func testSeederIsIdempotent() throws {
        let ctx = try makeInMemoryContext()
        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)
        let first = try ctx.fetch(FetchDescriptor<BuiltinPreference>()).count
        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)
        let second = try ctx.fetch(FetchDescriptor<BuiltinPreference>()).count
        XCTAssertEqual(first, second)
    }
}
