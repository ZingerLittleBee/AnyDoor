import ClipboardHistory
import Foundation
import GRDB
import SwiftData
import XCTest
import os

@testable import AnyDoor

/// The reader hand-writes SQL against Core Data's private table layout, which
/// no compiler checks. Current-schema fixtures use real SwiftData to catch
/// layout changes; frozen SQL fixtures preserve the columns of older releases.
@MainActor
final class ClipboardHistoryLegacyStoreReaderTests: XCTestCase {
    func testPrePasteStyleSchemaKeepsHistoryWithoutLaterMetadataColumns() throws {
        let storeURL = try makeHistoricalStore()
        let entry = try XCTUnwrap(ClipboardHistoryLegacyStoreReader.readEntries(at: storeURL).first)
        XCTAssertEqual(entry.id, UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        XCTAssertEqual(entry.kind, .ocr)
        XCTAssertEqual(entry.text, "historic text")
        XCTAssertEqual(entry.previewText, "Historic preview")
        XCTAssertEqual(entry.capturedAt, Date(timeIntervalSinceReferenceDate: 12_345))
        XCTAssertNil(entry.richData)
        XCTAssertNil(entry.richType)
        XCTAssertNil(entry.source.bundleIdentifier)
        XCTAssertNil(entry.source.displayName)
        XCTAssertFalse(entry.isFavorite)
        XCTAssertTrue(entry.tagIDs.isEmpty)
    }

    func testPreTagSchemaPreservesRichMetadataAndFileManifest() throws {
        let storeURL = try makeHistoricalStore(extraColumns: """
            , ZRICHDATA BLOB, ZRICHTYPE TEXT, ZSOURCEBUNDLEID TEXT,
            ZSOURCEAPPNAME TEXT, ZISFAVORITE INTEGER, ZFILESMANIFEST BLOB
            """)
        let manifest = try JSONEncoder().encode([
            ClipboardFileEntry(storedName: "owned", originalName: "Note.txt", originalPath: "/tmp/Note.txt")
        ])
        let queue = try DatabaseQueue(path: storeURL.path)
        try queue.write { database in
            try database.execute(sql: """
                UPDATE ZCLIPBOARDHISTORYITEM SET ZKIND = 'file', ZRICHDATA = ?,
                    ZRICHTYPE = 'public.rtf', ZSOURCEBUNDLEID = 'com.example.old',
                    ZSOURCEAPPNAME = 'Old App', ZISFAVORITE = 1, ZFILESMANIFEST = ?
                """, arguments: [Data("rich".utf8), manifest])
        }
        let entry = try XCTUnwrap(ClipboardHistoryLegacyStoreReader.readEntries(at: storeURL).first)
        XCTAssertEqual(entry.kind, .file)
        XCTAssertEqual(entry.richData, Data("rich".utf8))
        XCTAssertEqual(entry.richType, "public.rtf")
        XCTAssertEqual(entry.source.bundleIdentifier, "com.example.old")
        XCTAssertEqual(entry.source.displayName, "Old App")
        XCTAssertTrue(entry.isFavorite)
        XCTAssertTrue(entry.tagIDs.isEmpty)
        XCTAssertEqual(entry.files.count, 1)
        XCTAssertEqual(entry.files.first?.storedName, "owned")
        XCTAssertEqual(entry.files.first?.originalName, "Note.txt")
    }

    func testMissingRequiredHistoricalColumnStillFailsMigration() throws {
        let storeURL = try makeHistoricalStore()
        let queue = try DatabaseQueue(path: storeURL.path)
        try queue.write { database in
            try database.execute(sql: "ALTER TABLE ZCLIPBOARDHISTORYITEM DROP COLUMN ZID")
        }
        XCTAssertThrowsError(try ClipboardHistoryLegacyStoreReader.readEntries(at: storeURL))
    }

    private func makeHistoricalStore(extraColumns: String = "") throws -> URL {
        let storeURL = try makeDirectory().appendingPathComponent("AnyDoor.store")
        let queue = try DatabaseQueue(path: storeURL.path)
        try queue.write { database in
            // Base columns shipped in v1.2-v1.7; do not let today's SwiftData migrate the fixture.
            try database.execute(sql: """
                CREATE TABLE ZCLIPBOARDHISTORYITEM (
                    Z_PK INTEGER PRIMARY KEY, ZID BLOB, ZKIND TEXT, ZTEXT TEXT,
                    ZFILENAME TEXT, ZCOLORHEX TEXT, ZPREVIEWTITLE TEXT,
                    ZPREVIEWSUBTITLE TEXT, ZCREATEDAT REAL \(extraColumns)
                );
                INSERT INTO ZCLIPBOARDHISTORYITEM
                    (Z_PK, ZID, ZKIND, ZTEXT, ZPREVIEWTITLE, ZCREATEDAT)
                VALUES (1, X'00112233445566778899AABBCCDDEEFF', 'ocr',
                    'historic text', 'Historic preview', 12345);
                """)
        }
        return storeURL
    }

    func testEveryLegacyKindSurvivesTheRawRead() throws {
        // The v1 schema is frozen. New presentation kinds must not extend
        // the set of values accepted by its migration reader.
        let legacyKinds: [(ClipboardHistoryKind, ClipboardHistoryLegacyKind)] = [
            (.text, .text), (.color, .color), (.qrcode, .qrCode),
            (.ocr, .ocr), (.image, .image), (.screenshot, .screenshot),
            (.file, .file),
        ]
        let manifest = try JSONEncoder().encode([
            ClipboardFileEntry(
                storedName: "stored",
                originalName: "Document.txt",
                originalPath: "/Users/example/Document.txt"
            )
        ])
        var expected: [UUID: ClipboardHistoryLegacyKind] = [:]
        let storeURL = try makeStore { context in
            for (index, pair) in legacyKinds.enumerated() {
                let (kind, legacyKind) = pair
                let id = UUID()
                expected[id] = legacyKind
                context.insert(
                    ClipboardHistoryItem(
                        id: id,
                        kind: kind,
                        previewTitle: "Row \(index)",
                        createdAt: Date(
                            timeIntervalSince1970: TimeInterval(index)
                        ),
                        filesManifest: kind == .file ? manifest : nil
                    )
                )
            }
        }

        let entries = try ClipboardHistoryLegacyStoreReader.readEntries(
            at: storeURL
        )

        XCTAssertEqual(entries.count, legacyKinds.count)
        for entry in entries {
            XCTAssertEqual(entry.kind, expected[entry.id])
        }
    }

    func testEveryPersistedFieldRoundTripsThroughTheRawRead() throws {
        let id = UUID()
        // Deliberately before Core Data's 2001 reference date, so a reader that
        // confused it with the Unix epoch cannot pass by accident.
        let capturedAt = Date(timeIntervalSince1970: 1_234_567)
        let storeURL = try makeStore { context in
            context.insert(
                ClipboardHistoryItem(
                    id: id,
                    kind: .color,
                    text: "text value",
                    fileName: "Name.txt",
                    colorHex: "#FF0000",
                    previewTitle: "Preview",
                    createdAt: capturedAt,
                    richData: Data("rich".utf8),
                    richType: "public.rtf",
                    sourceBundleID: "com.example.source",
                    sourceAppName: "Source",
                    isFavorite: true,
                    tagIDs: ["work", "later"]
                )
            )
        }

        let entry = try XCTUnwrap(
            ClipboardHistoryLegacyStoreReader.readEntries(at: storeURL).first
        )

        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.kind, .color)
        XCTAssertEqual(entry.text, "text value")
        XCTAssertEqual(entry.fileName, "Name.txt")
        XCTAssertEqual(entry.colorHex, "#FF0000")
        XCTAssertEqual(entry.previewText, "Preview")
        XCTAssertEqual(entry.capturedAt, capturedAt)
        XCTAssertEqual(entry.richData, Data("rich".utf8))
        XCTAssertEqual(entry.richType, "public.rtf")
        XCTAssertEqual(entry.source.bundleIdentifier, "com.example.source")
        XCTAssertEqual(entry.source.displayName, "Source")
        XCTAssertEqual(entry.source.provenance, .legacy)
        XCTAssertTrue(entry.isFavorite)
        XCTAssertEqual(entry.tagIDs, ["work", "later"])
    }

    func testRowsSharingATimestampKeepAStableOrderAcrossReads() throws {
        let shared = Date(timeIntervalSince1970: 500)
        let storeURL = try makeStore { context in
            for index in 0..<20 {
                context.insert(
                    ClipboardHistoryItem(
                        kind: .text,
                        text: "row \(index)",
                        previewTitle: "Row \(index)",
                        createdAt: shared
                    )
                )
            }
        }

        // `recency_order` is assigned from this sequence, so a tie must not
        // reshuffle between the read that migrates and any read that retries.
        let first = try ClipboardHistoryLegacyStoreReader.readEntries(
            at: storeURL
        )
        let second = try ClipboardHistoryLegacyStoreReader.readEntries(
            at: storeURL
        )
        XCTAssertEqual(first.count, 20)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    func testUnmappableRowsAreReportedAndSkipped() throws {
        let keptID = UUID()
        let unknownKindID = UUID()
        let brokenManifestID = UUID()
        let storeURL = try makeStore { context in
            context.insert(
                ClipboardHistoryItem(
                    id: keptID,
                    kind: .text,
                    text: "keep me",
                    previewTitle: "Keep",
                    createdAt: Date(timeIntervalSince1970: 300)
                )
            )
            let unknownKind = ClipboardHistoryItem(
                id: unknownKindID,
                kind: .text,
                previewTitle: "Unknown kind",
                createdAt: Date(timeIntervalSince1970: 200)
            )
            context.insert(unknownKind)
            unknownKind.kind = "kindFromAnotherBuild"
            context.insert(
                ClipboardHistoryItem(
                    id: brokenManifestID,
                    kind: .file,
                    previewTitle: "Broken manifest",
                    createdAt: Date(timeIntervalSince1970: 100),
                    filesManifest: Data("not json".utf8)
                )
            )
        }

        var skipped: [ClipboardHistoryLegacyStoreReader.SkippedRow] = []
        let entries = try ClipboardHistoryLegacyStoreReader.readEntries(
            at: storeURL
        ) { skipped.append($0) }

        XCTAssertEqual(entries.map(\.id), [keptID])
        XCTAssertEqual(
            skipped,
            [
                ClipboardHistoryLegacyStoreReader.SkippedRow(
                    id: unknownKindID,
                    reason: .unknownKind("kindFromAnotherBuild")
                ),
                ClipboardHistoryLegacyStoreReader.SkippedRow(
                    id: brokenManifestID,
                    reason: .unreadableFileManifest
                ),
            ]
        )
    }

    func testATransientLockIsWaitedOutInsteadOfFailingTheTransfer() throws {
        let id = UUID()
        let storeURL = try makeStore { context in
            context.insert(
                ClipboardHistoryItem(
                    id: id,
                    kind: .text,
                    text: "survives the lock",
                    previewTitle: "Locked",
                    createdAt: Date(timeIntervalSince1970: 42)
                )
            )
        }

        // SQLITE_BUSY is transient by definition: the snapshot is copied with
        // its -wal/-shm sidecars, and whoever last wrote it may still be
        // checkpointing. Failing on the first busy reply would cost the user
        // every row in their history, so the reader has to wait.
        let locked = DispatchSemaphore(value: 0)
        let mayRelease = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        let outcome = OSAllocatedUnfairLock<Result<Void, Error>?>(initialState: nil)
        enum LockFailure: Error { case timedOut }
        defer { mayRelease.signal() }
        DispatchQueue.global().async {
            defer { locked.signal(); released.signal() }
            let result = Result<Void, Error> {
                var configuration = Configuration()
                configuration.busyMode = .timeout(5)
                let holder = try DatabaseQueue(
                    path: storeURL.path,
                    configuration: configuration
                )
                try holder.writeWithoutTransaction { database in
                    // An exclusive locking mode blocks readers too, which a WAL
                    // write transaction on its own would not.
                    try database.execute(sql: "PRAGMA locking_mode = EXCLUSIVE")
                    try database.execute(sql: "BEGIN IMMEDIATE")
                    locked.signal()
                    guard mayRelease.wait(timeout: .now() + 10) == .success else {
                        throw LockFailure.timedOut
                    }
                    try database.execute(sql: "COMMIT")
                    try database.execute(sql: "PRAGMA locking_mode = NORMAL")
                    // SQLite keeps the excess locking until the connection next
                    // touches the file, so drop it here rather than leaving the
                    // reader waiting on this connection's deallocation.
                    _ = try Int.fetchOne(
                        database,
                        sql: "SELECT count(*) FROM sqlite_master"
                    )
                }
            }
            outcome.withLock { $0 = result }
        }
        guard locked.wait(timeout: .now() + 10) == .success else { throw LockFailure.timedOut }
        if let result = outcome.withLock({ $0 }) { try result.get() }
        var probeConfiguration = Configuration()
        probeConfiguration.readonly = true
        probeConfiguration.busyMode = .immediateError
        XCTAssertThrowsError(try DatabaseQueue(path: storeURL.path, configuration: probeConfiguration).read {
            try Int.fetchOne($0, sql: "SELECT count(*) FROM ZCLIPBOARDHISTORYITEM")
        }) { error in
            XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_BUSY)
        }
        // Release on a timer rather than after the read: the read is what
        // blocks, so it cannot be the thing that lets go.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            mayRelease.signal()
        }

        let entries = try ClipboardHistoryLegacyStoreReader.readEntries(
            at: storeURL
        )

        XCTAssertEqual(entries.map(\.id), [id])
        guard released.wait(timeout: .now() + 10) == .success else { throw LockFailure.timedOut }
        try XCTUnwrap(outcome.withLock { $0 }).get()
    }

    func testAStoreWithoutTheLegacyEntityReadsAsEmpty() throws {
        // An install that predates clipboard history entirely: the file is a
        // valid store, it just has no such table. That is nothing to migrate,
        // not a failure that would block every launch.
        let directory = try makeDirectory()
        let storeURL = directory.appendingPathComponent("AnyDoor.store")
        try autoreleasepool {
            let container = try ModelContainer(
                for: KeyBinding.self,
                configurations: ModelConfiguration(url: storeURL)
            )
            container.mainContext.insert(
                KeyBinding(
                    keyCode: 122,
                    modifierFlags: 0,
                    appBundleID: "com.apple.finder",
                    appName: "Finder",
                    appPath: "/System/Library/CoreServices/Finder.app"
                )
            )
            try container.mainContext.save()
        }

        XCTAssertEqual(
            try ClipboardHistoryLegacyStoreReader.readEntries(at: storeURL)
                .count,
            0
        )
    }

    private func makeStore(
        _ populate: (ModelContext) throws -> Void
    ) throws -> URL {
        let storeURL = try makeDirectory()
            .appendingPathComponent("AnyDoor.store")
        // Drain the pool so Core Data closes the store before the reader opens
        // the same file. Releasing the container alone is not enough: its
        // connection survives in the autorelease pool, keeping a lock on the
        // store and its -wal sidecar that the reader then meets as
        // SQLITE_BUSY.
        try autoreleasepool {
            let container = try ModelContainer(
                for: ClipboardHistoryItem.self,
                configurations: ModelConfiguration(url: storeURL)
            )
            try populate(container.mainContext)
            try container.mainContext.save()
        }
        return storeURL
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-LegacyReader-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
