import XCTest
@testable import AnyDoor

final class BackupCodecTests: XCTestCase {

    func testSettingValueEncodesAndDecodesEachCase() throws {
        let values: [SettingValue] = [
            .bool(true),
            .int(42),
            .string("hi"),
            .stringArray(["com.apple.Safari", "com.apple.finder"]),
        ]
        let data = try JSONEncoder().encode(values)
        let decoded = try JSONDecoder().decode([SettingValue].self, from: data)
        XCTAssertEqual(decoded, values)
    }

    private func sampleSnapshot() -> BackupSnapshot {
        BackupSnapshot(
            schemaVersion: BackupSnapshot.currentSchemaVersion,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "1.2.3",
            deviceName: "Test-Mac",
            appShortcuts: [
                AppShortcutDTO(appBundleID: "com.apple.Safari", appName: "Safari",
                               keyCode: 4, modifierFlags: 256,
                               isEnabled: true, isVisible: true, displayOrder: 100)
            ],
            builtinPreferences: [
                BuiltinPreferenceDTO(itemKey: "darkMode", isVisible: true,
                                     displayOrder: 200, keyCode: 2, modifierFlags: 256)
            ],
            settings: ["menuBar.iconVisible": .bool(true)]
        )
    }

    func testSnapshotRoundTrips() throws {
        let original = sampleSnapshot()
        let data = try BackupCodec.encode(original)
        let decoded = try BackupCodec.decode(data)
        XCTAssertEqual(decoded, original)
    }

    func testDecodeRejectsUnsupportedSchemaVersion() throws {
        var future = sampleSnapshot()
        future.schemaVersion = 999
        let data = try BackupCodec.encode(future)
        XCTAssertThrowsError(try BackupCodec.decode(data)) { error in
            XCTAssertEqual(error as? BackupCodecError, .unsupportedSchemaVersion(999))
        }
    }

    func testDecodeRejectsGarbage() {
        let garbage = Data("not json".utf8)
        XCTAssertThrowsError(try BackupCodec.decode(garbage))
    }

    func testLocalFileBackendUploadThenDownload() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydoor-backup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = LocalFileBackend(url: url)
        let payload = Data("hello".utf8)
        try await backend.upload(payload)
        let read = try await backend.download()
        XCTAssertEqual(read, payload)
    }

    func testLocalFileBackendDownloadReturnsNilWhenMissing() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydoor-missing-\(UUID().uuidString).json")
        let backend = LocalFileBackend(url: url)
        let read = try await backend.download()
        XCTAssertNil(read)
    }
}
