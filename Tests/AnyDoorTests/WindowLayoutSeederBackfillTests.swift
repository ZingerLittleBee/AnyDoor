import XCTest
import SwiftData
@testable import AnyDoor

final class WindowLayoutSeederBackfillTests: XCTestCase {
    private let flagKey = "windowLayoutDefaultsApplied_v1"
    private let flagKeyV2 = "windowLayoutDefaultsApplied_v2"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: flagKey)
        UserDefaults.standard.removeObject(forKey: flagKeyV2)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: flagKey)
        UserDefaults.standard.removeObject(forKey: flagKeyV2)
        super.tearDown()
    }

    private func makeInMemoryContext() throws -> ModelContext {
        let schema = Schema([
            KeyBinding.self,
            BuiltinPreference.self,
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
        // v1 pins the four to 2010-2040; v2 then reorders maximize/center after
        // the new tiling actions. Final state is v2's.
        XCTAssertEqual(byKey["windowLeftHalf"],  2010)
        XCTAssertEqual(byKey["windowRightHalf"], 2020)
        XCTAssertEqual(byKey["windowMaximize"],  2160)
        XCTAssertEqual(byKey["windowCenter"],    2170)
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

    @MainActor
    func testV2BackfillReordersAllWindowChildren() throws {
        let ctx = try makeInMemoryContext()

        // Simulate an upgrade: the four legacy children exist with v1 orders,
        // and the 13 new children were just appended by the seeder at large
        // arbitrary orders. Pre-set the v1 flag so only v2 runs here.
        UserDefaults.standard.set(true, forKey: flagKey)
        let seeded: [(String, Double)] = [
            ("windowLeftHalf", 2010), ("windowRightHalf", 2020),
            ("windowMaximize", 2030), ("windowCenter", 2040),
            ("windowTopHalf", 9000), ("windowBottomHalf", 9100),
            ("windowMoveNextDisplay", 9200),
        ]
        for (key, order) in seeded {
            ctx.insert(BuiltinPreference(itemKey: key, isVisible: true, displayOrder: order))
        }
        try ctx.save()

        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)

        let rows = try ctx.fetch(FetchDescriptor<BuiltinPreference>())
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.itemKey, $0.displayOrder) })
        XCTAssertEqual(byKey["windowTopHalf"], 2030)
        XCTAssertEqual(byKey["windowBottomHalf"], 2040)
        XCTAssertEqual(byKey["windowMaximize"], 2160)
        XCTAssertEqual(byKey["windowCenter"], 2170)
        XCTAssertEqual(byKey["windowMoveNextDisplay"], 2180)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: flagKeyV2))
    }

    @MainActor
    func testV2BackfillIsOneShot() throws {
        let ctx = try makeInMemoryContext()
        ctx.insert(BuiltinPreference(itemKey: "windowMaximize", isVisible: true, displayOrder: 2160))
        try ctx.save()
        UserDefaults.standard.set(true, forKey: flagKey)
        UserDefaults.standard.set(true, forKey: flagKeyV2)

        // Manually corrupt the order; backfill must NOT run again.
        let row = try ctx.fetch(FetchDescriptor<BuiltinPreference>()).first { $0.itemKey == "windowMaximize" }
        row?.displayOrder = 5
        try ctx.save()

        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)

        let after = try ctx.fetch(FetchDescriptor<BuiltinPreference>()).first { $0.itemKey == "windowMaximize" }
        XCTAssertEqual(after?.displayOrder, 5, "v2 backfill must be one-shot")
    }
}
