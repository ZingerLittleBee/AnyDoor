import XCTest
import SwiftData
@testable import AnyDoor

final class BuiltinPreferenceSeederTests: XCTestCase {
    private let backfillFlagKey = "windowLayoutDefaultsApplied_v1"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: backfillFlagKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: backfillFlagKey)
        super.tearDown()
    }

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
        return ModelContext(container)
    }

    @MainActor
    func testHiddenHotkeyItemsAreSeededInvisible() throws {
        let ctx = try makeInMemoryContext()
        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)

        let prefs = try ctx.fetch(FetchDescriptor<BuiltinPreference>())
        let up = try XCTUnwrap(prefs.first { $0.itemKey == "brightnessUp" })
        let down = try XCTUnwrap(prefs.first { $0.itemKey == "brightnessDown" })
        XCTAssertFalse(up.isVisible)
        XCTAssertFalse(down.isVisible)
    }

    @MainActor
    func testRegularItemsAreSeededVisible() throws {
        let ctx = try makeInMemoryContext()
        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)

        let prefs = try ctx.fetch(FetchDescriptor<BuiltinPreference>())
        let brightness = try XCTUnwrap(prefs.first { $0.itemKey == "brightness" })
        let keepAwake = try XCTUnwrap(prefs.first { $0.itemKey == "keepAwake" })
        XCTAssertTrue(brightness.isVisible)
        XCTAssertTrue(keepAwake.isVisible)
    }

    @MainActor
    func testSeederIsIdempotent() throws {
        let ctx = try makeInMemoryContext()
        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)
        let first = try ctx.fetch(FetchDescriptor<BuiltinPreference>()).count
        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)
        let second = try ctx.fetch(FetchDescriptor<BuiltinPreference>()).count
        XCTAssertEqual(first, second)
    }

    @MainActor
    func testSeedsAllItemsOnEmptyStore() throws {
        let ctx = try makeInMemoryContext()
        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)

        let rows = try ctx.fetch(FetchDescriptor<BuiltinPreference>())
        XCTAssertEqual(rows.count, BuiltinItem.allCases.count)

        let keys = Set(rows.map(\.itemKey))
        for item in BuiltinItem.allCases {
            XCTAssertTrue(keys.contains(item.rawValue), "missing \(item.rawValue)")
        }
    }

    @MainActor
    func testSeedingAppendsNewItemsAtEnd() throws {
        let ctx = try makeInMemoryContext()

        // Pre-populate with one item to simulate prior state.
        ctx.insert(BuiltinPreference(itemKey: BuiltinItem.keepAwake.rawValue,
                                     isVisible: true,
                                     displayOrder: 50))
        try ctx.save()

        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)

        let rows = try ctx.fetch(FetchDescriptor<BuiltinPreference>())
            .sorted { $0.displayOrder < $1.displayOrder }

        // Pre-existing row should still be at order 50.
        XCTAssertEqual(rows.first?.itemKey, BuiltinItem.keepAwake.rawValue)
        XCTAssertEqual(rows.first?.displayOrder, 50)
        // New rows should all have order > 50.
        for row in rows.dropFirst() {
            XCTAssertGreaterThan(row.displayOrder, 50)
        }
    }
}
