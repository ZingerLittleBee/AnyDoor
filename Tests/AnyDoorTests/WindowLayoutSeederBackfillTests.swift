import XCTest
import SwiftData
@testable import AnyDoor

final class WindowLayoutSeederBackfillTests: XCTestCase {
    private let flagKey = "windowLayoutDefaultsApplied_v1"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: flagKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: flagKey)
        super.tearDown()
    }

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
    func testBackfillRewritesLegacyWindowChildOrder() throws {
        let ctx = try makeInMemoryContext()

        // Simulate legacy state: four window children with the old top-level
        // orders that shipped before windowLayout existed.
        for (key, order) in [
            ("windowLeftHalf",  2000.0),
            ("windowRightHalf", 2010.0),
            ("windowMaximize",  2020.0),
            ("windowCenter",    2030.0),
        ] {
            ctx.insert(BuiltinPreference(itemKey: key,
                                         isVisible: true,
                                         displayOrder: order))
        }
        try ctx.save()

        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)

        let rows = try ctx.fetch(FetchDescriptor<BuiltinPreference>())
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.itemKey, $0.displayOrder) })
        XCTAssertEqual(byKey["windowLeftHalf"],  2010)
        XCTAssertEqual(byKey["windowRightHalf"], 2020)
        XCTAssertEqual(byKey["windowMaximize"],  2030)
        XCTAssertEqual(byKey["windowCenter"],    2040)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: flagKey))
    }

    @MainActor
    func testBackfillRunsOnlyOnce() throws {
        let ctx = try makeInMemoryContext()

        // First run on an empty store seeds defaults AND sets the flag.
        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: flagKey))

        // User reorders inside the popover: simulate by writing a custom value.
        let rows = try ctx.fetch(FetchDescriptor<BuiltinPreference>())
        if let row = rows.first(where: { $0.itemKey == "windowLeftHalf" }) {
            row.displayOrder = 999
        }
        try ctx.save()

        // Second seeder call must not touch the user's custom value.
        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)
        let after = try ctx.fetch(FetchDescriptor<BuiltinPreference>())
        let left = try XCTUnwrap(after.first { $0.itemKey == "windowLeftHalf" })
        XCTAssertEqual(left.displayOrder, 999)
    }
}
