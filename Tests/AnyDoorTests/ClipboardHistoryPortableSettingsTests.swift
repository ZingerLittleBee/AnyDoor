import Foundation
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardHistoryPortableSettingsTests: XCTestCase {
    func testPersistsDefinitionsWithoutMembership() async throws {
        let fixture = try Fixture()
        let module = fixture.module
        let entry = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: .unknown,
                content: .text("private membership")
            )
        )
        let assignment = try await module.createTagDefinition(
            named: "Work",
            assigningTo: entry.entryID
        )

        try ClipboardHistoryPortableSettings.persist(
            await module.tagDefinitions(),
            to: fixture.defaults
        )

        let json = try XCTUnwrap(
            fixture.defaults.string(
                forKey: ClipboardTagStore.defaultsKey
            )
        )
        XCTAssertTrue(json.contains(assignment.definition.id))
        XCTAssertTrue(json.contains("Work"))
        XCTAssertFalse(json.contains(entry.entryID.value.uuidString))
        XCTAssertFalse(json.contains("private membership"))
    }

    func testImportedDefinitionsReplaceOrderAndDropOnlyRemovedMembership()
        async throws
    {
        let fixture = try Fixture()
        let module = fixture.module
        let entry = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: .unknown,
                content: .text("local")
            )
        )
        _ = try await module.createTagDefinition(
            named: "Local",
            assigningTo: entry.entryID
        )
        let imported = [
            ClipboardTag(id: "second", name: "Second"),
            ClipboardTag(id: "first", name: "First"),
        ]
        let data = try JSONEncoder().encode(imported)
        fixture.defaults.set(
            String(decoding: data, as: UTF8.self),
            forKey: ClipboardTagStore.defaultsKey
        )

        try await ClipboardHistoryPortableSettings.reconcile(
            module: module,
            defaults: fixture.defaults
        )

        let definitions = try await module.tagDefinitions()
        XCTAssertEqual(
            definitions,
            [
                ClipboardHistoryTagDefinition(
                    id: "second",
                    displayName: "Second"
                ),
                ClipboardHistoryTagDefinition(
                    id: "first",
                    displayName: "First"
                ),
            ]
        )
        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries.first?.tagIDs, [])
    }
}

private struct Fixture {
    let directory: URL
    let defaults: UserDefaults
    let module: ClipboardHistoryModule

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let suite = "ClipboardHistoryPortableSettingsTests-\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        module = try ClipboardHistoryModule(
            testingDatabaseURL:
                directory.appendingPathComponent("history.sqlite"),
            databaseKey: Data(repeating: 0x42, count: 32)
        )
    }
}
