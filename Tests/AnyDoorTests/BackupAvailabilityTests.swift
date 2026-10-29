import ClipboardHistoryTestSupport
import Foundation
import SwiftData
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class BackupAvailabilityTests: XCTestCase {
    func testUnavailableHistoryExportsIndependentConfigurationWithTagOmission() async throws {
        let fixture = try makeFixture()
        let entry = try await fixture.module.capture(.init(source: .unknown, content: .text("Retained history")))
        _ = try await fixture.module.createTagDefinition(named: "Private tag", assigningTo: entry.entryID)
        fixture.context.insert(KeyBinding(keyCode: 4, modifierFlags: 256,
            appBundleID: "com.example.Backup", appName: "Backup", appPath: "",
            isEnabled: true, isVisible: true, displayOrder: 1))
        fixture.context.insert(Quicklink(name: "Documentation", link: "https://example.com/docs", displayOrder: 1))
        try fixture.context.save()
        fixture.defaults.set("en", forKey: "dev.bybee.AnyDoor.language")
        fixture.defaults.set("stale plaintext mirror", forKey: ClipboardHistoryPortableKeys.customTags)
        let service = BackupService(context: fixture.context, defaults: fixture.defaults,
            appPathResolver: { _ in nil }, currentClipboardTags: { try await fixture.module.tagDefinitions() })
        try await fixture.module.closeStoreForTesting()

        let snapshot = try await service.exportCurrentSnapshot()
        let data = try BackupCodec.encode(snapshot)
        let decoded = try BackupCodec.decode(data)
        XCTAssertEqual(decoded.appShortcuts.map(\.appBundleID), ["com.example.Backup"])
        XCTAssertEqual(decoded.quicklinks.map(\.link), ["https://example.com/docs"])
        XCTAssertEqual(decoded.settings["dev.bybee.AnyDoor.language"], .string("en"))
        XCTAssertNil(decoded.settings[ClipboardHistoryPortableKeys.customTags])
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(file["omittedSections"] as? [String], ["clipboardTags"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("stale plaintext mirror"))
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("backup-availability-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        removeClipboardHistoryDirectoryAfterTest(directory)
        let module = try trackClipboardHistoryModule(ClipboardHistoryModule(
            testingDatabaseURL: directory.appendingPathComponent("history.sqlite"),
            databaseKey: Data(repeating: 0x42, count: 32)))
        let container = try ModelContainer(for: Schema([KeyBinding.self, BuiltinPreference.self, Quicklink.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return Fixture(directory: directory, module: module, container: container,
            defaults: makeTemporaryDefaults())
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let module: ClipboardHistoryModule
        let container: ModelContainer
        let defaults: UserDefaults
        var context: ModelContext { container.mainContext }
    }
}
