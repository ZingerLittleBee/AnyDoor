import Foundation
import XCTest

@testable import ClipboardHistory

final class ClipboardHistoryModuleTests: XCTestCase {
    func testEncryptedStoreReturnsEmptyFirstPage() async throws {
        let fixture = try TemporaryDatabase()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )

        let page = try await module.page(ClipboardHistoryQuery())

        XCTAssertEqual(page.entries, [])
        XCTAssertNil(page.nextCursor)
    }

    func testEncryptedStoreRejectsWrongKeyAndHidesSQLiteHeader() async throws {
        let fixture = try TemporaryDatabase()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        _ = try await module.page(ClipboardHistoryQuery())

        let header = try Data(contentsOf: fixture.url).prefix(16)
        XCTAssertNotEqual(String(data: header, encoding: .utf8), "SQLite format 3\u{0}")

        XCTAssertThrowsError(
            try ClipboardHistoryModule(
                testingDatabaseURL: fixture.url,
                databaseKey: Data(repeating: 0x5A, count: 32)
            )
        )
    }

    func testRuntimeProvidesPinnedSQLCipherAndRequiredFTSFeatures() async throws {
        let fixture = try TemporaryDatabase()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )

        let capabilities = try await module.foundationRuntimeCapabilities()

        XCTAssertEqual(capabilities.sqlCipherVersion, "4.17.0 community")
        XCTAssertTrue(capabilities.hasFTS5)
        XCTAssertTrue(capabilities.hasTrigramTokenizer)
    }
}

private final class TemporaryDatabase {
    let directory: URL
    let url: URL
    let key = Data(repeating: 0xA5, count: 32)

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnyDoor-ClipboardHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        url = directory.appendingPathComponent("history.sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
