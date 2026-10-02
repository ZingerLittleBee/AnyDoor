import XCTest
import SwiftData
import PluginInterface
@testable import AnyDoor

/// The retired Capture Menu built-in (`captureModeBar`) ran the same region
/// capture as `.screenshot`. The one-shot launch migration merges its row's
/// hotkey and visibility into Screenshot's, then deletes the orphan row.
final class CaptureModeBarMergeTests: XCTestCase {
    private let flagKey = "captureModeBarMerged_v1"
    /// Command+Shift, as `CGEventFlags` raw bits.
    private let commandShift = 0x12_0000
    /// Command+Option, as `CGEventFlags` raw bits.
    private let commandOption = 0x18_0000
    private let schema = Schema([KeyBinding.self, BuiltinPreference.self])

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = makeTemporaryDefaults()
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    private func makeInMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, allowsSave: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    private func insertPair(
        in context: ModelContext,
        screenshot: BuiltinPreference,
        captureModeBar: BuiltinPreference
    ) throws {
        context.insert(screenshot)
        context.insert(captureModeBar)
        try context.save()
    }

    private func rowsByKey(in context: ModelContext) throws -> [String: BuiltinPreference] {
        let rows = try context.fetch(FetchDescriptor<BuiltinPreference>())
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.itemKey, $0) })
    }

    @MainActor
    func testMovesTheHotkeyToAnUnboundScreenshotAndDeletesTheRow() throws {
        let ctx = try makeInMemoryContext()
        try insertPair(
            in: ctx,
            screenshot: BuiltinPreference(itemKey: "screenshot", displayOrder: 900),
            captureModeBar: BuiltinPreference(
                itemKey: "captureModeBar", displayOrder: 920,
                keyCode: 21, modifierFlags: commandShift
            )
        )

        BuiltinPreferenceSeeder.applyCaptureModeBarMergeIfNeeded(in: ctx, defaults: defaults)

        let rows = try ctx.fetch(FetchDescriptor<BuiltinPreference>())
        XCTAssertEqual(rows.map(\.itemKey), ["screenshot"])
        XCTAssertEqual(rows.first?.displayOrder, 900)
        XCTAssertFalse(ctx.hasChanges, "the merge must be saved")
        XCTAssertTrue(defaults.bool(forKey: flagKey))
        // The moved hotkey now runs Screenshot; the orphan's would never compile.
        XCTAssertEqual(
            HotkeyCoordinator.compile(bindings: [], prefs: rows, quicklinks: [], paletteHotkey: nil),
            [HotkeySnapshot(keyCode: 21, modifierFlags: commandShift,
                            action: .runBuiltin(itemKey: "screenshot"))]
        )
    }

    @MainActor
    func testScreenshotKeepsItsOwnHotkeyWhenBothAreBound() throws {
        let ctx = try makeInMemoryContext()
        try insertPair(
            in: ctx,
            screenshot: BuiltinPreference(
                itemKey: "screenshot", displayOrder: 900,
                keyCode: 20, modifierFlags: commandShift
            ),
            captureModeBar: BuiltinPreference(
                itemKey: "captureModeBar", displayOrder: 920,
                keyCode: 21, modifierFlags: commandOption
            )
        )

        BuiltinPreferenceSeeder.applyCaptureModeBarMergeIfNeeded(in: ctx, defaults: defaults)

        let byKey = try rowsByKey(in: ctx)
        XCTAssertNil(byKey["captureModeBar"])
        XCTAssertEqual(byKey["screenshot"]?.keyCode, 20)
        XCTAssertEqual(byKey["screenshot"]?.modifierFlags, commandShift)
        XCTAssertTrue(defaults.bool(forKey: flagKey))
    }

    @MainActor
    func testVisibleCaptureModeBarMakesAHiddenScreenshotVisible() throws {
        // (screenshot visible, captureModeBar visible) -> screenshot visible after.
        let cases: [(Bool, Bool, Bool)] = [
            (false, true, true),
            (false, false, false),
            (true, false, true),
            (true, true, true),
        ]
        for (screenshotVisible, captureModeBarVisible, expected) in cases {
            let ctx = try makeInMemoryContext()
            let caseDefaults = makeTemporaryDefaults()
            try insertPair(
                in: ctx,
                screenshot: BuiltinPreference(
                    itemKey: "screenshot", isVisible: screenshotVisible, displayOrder: 900
                ),
                captureModeBar: BuiltinPreference(
                    itemKey: "captureModeBar", isVisible: captureModeBarVisible, displayOrder: 920
                )
            )

            BuiltinPreferenceSeeder.applyCaptureModeBarMergeIfNeeded(in: ctx, defaults: caseDefaults)

            let byKey = try rowsByKey(in: ctx)
            XCTAssertNil(byKey["captureModeBar"])
            XCTAssertEqual(
                byKey["screenshot"]?.isVisible, expected,
                "screenshot \(screenshotVisible), captureModeBar \(captureModeBarVisible)"
            )
        }
    }

    @MainActor
    func testMergeIsIdempotentAndOneShot() throws {
        let ctx = try makeInMemoryContext()
        try insertPair(
            in: ctx,
            screenshot: BuiltinPreference(itemKey: "screenshot", isVisible: false, displayOrder: 900),
            captureModeBar: BuiltinPreference(
                itemKey: "captureModeBar", displayOrder: 920,
                keyCode: 21, modifierFlags: commandShift
            )
        )

        BuiltinPreferenceSeeder.applyCaptureModeBarMergeIfNeeded(in: ctx, defaults: defaults)
        BuiltinPreferenceSeeder.applyCaptureModeBarMergeIfNeeded(in: ctx, defaults: defaults)
        // Even without the flag, a second pass finds nothing left to merge.
        let unflaggedDefaults = makeTemporaryDefaults("unflagged")
        BuiltinPreferenceSeeder.applyCaptureModeBarMergeIfNeeded(in: ctx, defaults: unflaggedDefaults)

        var byKey = try rowsByKey(in: ctx)
        XCTAssertEqual(Set(byKey.keys), ["screenshot"])
        XCTAssertEqual(byKey["screenshot"]?.keyCode, 21)
        XCTAssertEqual(byKey["screenshot"]?.modifierFlags, commandShift)
        XCTAssertEqual(byKey["screenshot"]?.isVisible, true)

        // Once flagged, the merge does not run again, even if the row reappears.
        ctx.insert(BuiltinPreference(
            itemKey: "captureModeBar", displayOrder: 1_000,
            keyCode: 22, modifierFlags: commandOption
        ))
        try ctx.save()
        BuiltinPreferenceSeeder.applyCaptureModeBarMergeIfNeeded(in: ctx, defaults: defaults)

        byKey = try rowsByKey(in: ctx)
        XCTAssertNotNil(byKey["captureModeBar"])
        XCTAssertEqual(byKey["screenshot"]?.keyCode, 21)
    }

    @MainActor
    func testFlagIsSetOnlyAfterTheSaveSucceeds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureModeBarMergeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("AnyDoor.store")

        do {
            let writable = try ModelContainer(
                for: schema, configurations: [ModelConfiguration(url: storeURL)]
            )
            try insertPair(
                in: ModelContext(writable),
                screenshot: BuiltinPreference(itemKey: "screenshot", displayOrder: 900),
                captureModeBar: BuiltinPreference(
                    itemKey: "captureModeBar", displayOrder: 920,
                    keyCode: 21, modifierFlags: commandShift
                )
            )
        }

        // A store that refuses writes makes the save throw.
        do {
            let readOnly = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(url: storeURL, allowsSave: false)]
            )
            BuiltinPreferenceSeeder.applyCaptureModeBarMergeIfNeeded(
                in: ModelContext(readOnly), defaults: defaults
            )
            XCTAssertFalse(defaults.bool(forKey: flagKey), "a failed save must leave the flag unset")
        }

        // The next launch retries and completes the merge.
        let writable = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(url: storeURL)]
        )
        let ctx = ModelContext(writable)
        XCTAssertNotNil(try rowsByKey(in: ctx)["captureModeBar"], "nothing was persisted by the failed attempt")
        BuiltinPreferenceSeeder.applyCaptureModeBarMergeIfNeeded(in: ctx, defaults: defaults)

        let byKey = try rowsByKey(in: ctx)
        XCTAssertNil(byKey["captureModeBar"])
        XCTAssertEqual(byKey["screenshot"]?.keyCode, 21)
        XCTAssertTrue(defaults.bool(forKey: flagKey))
    }

    @MainActor
    func testFreshInstallHasNothingToMergeAndSetsTheFlag() throws {
        let ctx = try makeInMemoryContext()
        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)

        BuiltinPreferenceSeeder.applyCaptureModeBarMergeIfNeeded(in: ctx, defaults: defaults)

        let byKey = try rowsByKey(in: ctx)
        XCTAssertEqual(byKey.count, BuiltinItem.allCases.count)
        XCTAssertNil(byKey["captureModeBar"])
        XCTAssertEqual(byKey["screenshot"]?.isVisible, true)
        XCTAssertNil(byKey["screenshot"]?.keyCode)
        XCTAssertTrue(defaults.bool(forKey: flagKey))
    }

    @MainActor
    func testLaunchSeedingRunsTheMerge() throws {
        // The launch entry point uses the standard defaults.
        UserDefaults.standard.removeObject(forKey: flagKey)
        defer { UserDefaults.standard.removeObject(forKey: flagKey) }
        let ctx = try makeInMemoryContext()
        try insertPair(
            in: ctx,
            screenshot: BuiltinPreference(itemKey: "screenshot", displayOrder: 900),
            captureModeBar: BuiltinPreference(
                itemKey: "captureModeBar", displayOrder: 920,
                keyCode: 21, modifierFlags: commandShift
            )
        )

        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)

        let byKey = try rowsByKey(in: ctx)
        XCTAssertNil(byKey["captureModeBar"])
        XCTAssertEqual(byKey["screenshot"]?.keyCode, 21)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: flagKey))
    }
}
