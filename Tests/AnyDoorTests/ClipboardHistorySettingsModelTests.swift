import Foundation
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardHistorySettingsModelTests: XCTestCase {
    func testClearDefaultsToUnprotectedAndRefreshesStaleCount()
        async throws
    {
        let fixture = try SettingsFixture()
        let first = try await fixture.module.capture(
            request("first")
        )
        let protected = try await fixture.module.capture(
            request("protected")
        )
        _ = try await fixture.module.apply(
            .setFavorite(protected.entryID, true)
        )
        let model = fixture.model

        await model.beginClearHistory()

        XCTAssertFalse(model.clearIncludesProtected)
        XCTAssertEqual(model.clearConfirmation?.preview.affectedCount, 1)

        await model.setClearIncludesProtected(true)
        XCTAssertEqual(model.clearConfirmation?.preview.affectedCount, 2)
        await model.setClearIncludesProtected(false)
        XCTAssertEqual(model.clearConfirmation?.preview.affectedCount, 1)

        _ = try await fixture.module.capture(request("new"))
        await model.confirmClearHistory()

        XCTAssertEqual(
            model.clearConfirmation?.preview.affectedCount,
            2,
            "A changed revision must refresh instead of deleting"
        )
        var page = try await fixture.module.page(
            ClipboardHistoryQuery()
        )
        XCTAssertEqual(page.entries.count, 3)

        await model.confirmClearHistory()
        page = try await fixture.module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries.map(\.id), [protected.entryID])
        XCTAssertFalse(page.entries.contains { $0.id == first.entryID })
    }

    func testClearIncludingProtectedPreservesTagDefinitions()
        async throws
    {
        let fixture = try SettingsFixture()
        let entry = try await fixture.module.capture(request("tagged"))
        let assignment = try await fixture.module.createTagDefinition(
            named: "Keep Definition",
            assigningTo: entry.entryID
        )
        let model = fixture.model

        await model.beginClearHistory()
        await model.setClearIncludesProtected(true)
        await model.confirmClearHistory()

        let definitions = try await fixture.module.tagDefinitions()
        XCTAssertEqual(definitions, [assignment.definition])
        let page = try await fixture.module.page(
            ClipboardHistoryQuery()
        )
        XCTAssertTrue(page.entries.isEmpty)
    }

    func testRefreshReadsThirtyDayAndOCRDefaults() async throws {
        let fixture = try SettingsFixture()

        await fixture.model.refresh()

        XCTAssertEqual(fixture.model.retention, .thirtyDays)
        XCTAssertFalse(
            fixture.model.automaticImageTextIndexingEnabled
        )
        XCTAssertGreaterThan(fixture.model.storageBytes, 0)
    }

    private func request(
        _ text: String
    ) -> ClipboardHistoryCaptureRequest {
        ClipboardHistoryCaptureRequest(
            source: .unknown,
            content: .text(text)
        )
    }
}

@MainActor
private struct SettingsFixture {
    let module: ClipboardHistoryModule
    let defaults: UserDefaults
    let lifecycle: ClipboardHistoryLifecycle
    let model: ClipboardHistorySettingsModel

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        module = try ClipboardHistoryModule(
            testingDatabaseURL:
                directory.appendingPathComponent("history.sqlite"),
            databaseKey: Data(repeating: 0x31, count: 32)
        )
        let suite = "ClipboardHistorySettingsModelTests-\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        lifecycle = ClipboardHistoryLifecycle(
            module: module,
            defaults: defaults,
            migrationRequest: {
                ClipboardHistoryLegacyMigrationRequest(
                    transfer: ClipboardHistoryLegacyTransfer(
                        entries: [],
                        tags: [],
                        categoryOrder: [],
                        retentionPeriod: .thirtyDays
                    ),
                    payloadDirectory: directory
                )
            }
        )
        model = ClipboardHistorySettingsModel(
            module: module,
            lifecycle: lifecycle,
            defaults: defaults
        )
    }
}
