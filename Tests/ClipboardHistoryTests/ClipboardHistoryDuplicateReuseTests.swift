import AppKit
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import ClipboardHistory

final class ClipboardHistoryDuplicateReuseTests: XCTestCase {
    func testIdenticalExactTextCaptureReusesEntry() async throws {
        let fixture = try DuplicateReuseTemporaryStore()
        let firstTime = Date(timeIntervalSince1970: 1_000)
        let secondTime = Date(timeIntervalSince1970: 2_000)
        let clock = TestCaptureClock(firstTime)
        let module = makeDuplicateReuseModule(in: fixture, clock: clock)

        let first = try await module.capture(
            textRequest(
                "exact \ttext\r\n",
                sourceBundleID: "dev.bybee.first",
                sourceName: "First"
            )
        )
        clock.now = secondTime
        let second = try await module.capture(
            textRequest(
                "exact \ttext\r\n",
                sourceBundleID: "dev.bybee.second",
                sourceName: "Second"
            )
        )

        XCTAssertEqual(second.entryID, first.entryID)
        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries.map(\.id), [first.entryID])
        XCTAssertEqual(page.entries[0].capturedAt, secondTime)
    }

    func testForcedFingerprintCollisionStillCreatesIndependentEntry()
        async throws
    {
        let fixture = try DuplicateReuseTemporaryStore()
        let module = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: DuplicateReuseMasterKeyStore(),
            fingerprintDigest: { _ in Data(repeating: 0xCC, count: 32) }
        )

        let first = try await module.capture(textRequest("alpha"))
        let second = try await module.capture(textRequest("bravo"))

        XCTAssertNotEqual(second.entryID, first.entryID)
        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(Set(page.entries.map(\.id)), [first.entryID, second.entryID])
    }

    @MainActor
    func testExactTextItemBoundariesAndOrderRemainDistinct() async throws {
        let fixture = try DuplicateReuseTemporaryStore()
        let module = makeDuplicateReuseModule(in: fixture)

        let whitespace = try await module.capture(textRequest("line one\r\n "))
        let changedWhitespace = try await module.capture(
            textRequest("line one\n ")
        )
        XCTAssertNotEqual(changedWhitespace.entryID, whitespace.entryID)

        let first = try await captureTextItems(
            ["a", "bc"],
            with: module
        )
        let same = try await captureTextItems(["a", "bc"], with: module)
        let changedBoundary = try await captureTextItems(
            ["ab", "c"],
            with: module
        )
        let changedOrder = try await captureTextItems(
            ["bc", "a"],
            with: module
        )

        XCTAssertEqual(same.entryID, first.entryID)
        XCTAssertNotEqual(changedBoundary.entryID, first.entryID)
        XCTAssertNotEqual(changedOrder.entryID, first.entryID)
    }

    @MainActor
    func testRepresentationAdvertisementOrderDoesNotChangeIdentityButFormattingDoes()
        async throws
    {
        let fixture = try DuplicateReuseTemporaryStore()
        let module = makeDuplicateReuseModule(in: fixture)
        let bold = Data("<b>same</b>".utf8)
        let italic = Data("<i>same</i>".utf8)

        let first = try await captureRichItem(
            text: "same",
            html: bold,
            htmlFirst: false,
            with: module
        )
        let reordered = try await captureRichItem(
            text: "same",
            html: bold,
            htmlFirst: true,
            with: module
        )
        let reformatted = try await captureRichItem(
            text: "same",
            html: italic,
            htmlFirst: true,
            with: module
        )

        XCTAssertEqual(reordered.entryID, first.entryID)
        XCTAssertNotEqual(reformatted.entryID, first.entryID)
    }

    @MainActor
    func testEquivalentBitmapEncodingsReuseAuthenticatedCanonicalPayload()
        async throws
    {
        let fixture = try DuplicateReuseTemporaryStore()
        let module = makeDuplicateReuseModule(in: fixture)
        let encodings = try makeEquivalentBitmapEncodings()

        let first = try await captureBitmap(
            encodings.png,
            type: .png,
            with: module
        )
        let second = try await captureBitmap(
            encodings.tiff,
            type: .tiff,
            with: module
        )

        XCTAssertEqual(second.entryID, first.entryID)
        XCTAssertEqual(try fixture.payloadFiles().count, 2)

        let differentPixels = try makeEquivalentBitmapEncodings(
            components: [0.75, 0.5, 0.25, 1]
        )
        let different = try await captureBitmap(
            differentPixels.png,
            type: .png,
            with: module
        )
        XCTAssertNotEqual(different.entryID, first.entryID)
    }

    @MainActor
    func testFileIdentityUsesStandardizedCapturePathsAndPreservesOrder()
        async throws
    {
        let fixture = try DuplicateReuseTemporaryStore()
        let files = try DuplicateReuseFileFixture()
        let firstURL = try files.create("first.txt")
        let secondURL = try files.create("second.txt")
        let module = makeDuplicateReuseModule(in: fixture)

        let first = try await captureFiles(
            [firstURL, secondURL],
            with: module
        )
        let same = try await captureFiles(
            [firstURL, secondURL],
            with: module
        )
        let reordered = try await captureFiles(
            [secondURL, firstURL],
            with: module
        )

        XCTAssertEqual(same.entryID, first.entryID)
        XCTAssertNotEqual(reordered.entryID, first.entryID)
    }

    @MainActor
    func testURLAndColorUseTheirCanonicalRepresentationValues()
        async throws
    {
        let fixture = try DuplicateReuseTemporaryStore()
        let module = makeDuplicateReuseModule(in: fixture)

        let firstURL = try await captureTypedText(
            "https://example.com/A",
            type: .URL,
            with: module
        )
        let sameURL = try await captureTypedText(
            "https://example.com/A",
            type: .URL,
            with: module
        )
        let differentURL = try await captureTypedText(
            "https://example.com/a",
            type: .URL,
            with: module
        )
        XCTAssertEqual(sameURL.entryID, firstURL.entryID)
        XCTAssertNotEqual(differentURL.entryID, firstURL.entryID)

        let firstColor = try await captureColor(
            NSColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 1),
            with: module
        )
        let sameColor = try await captureColor(
            NSColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 1),
            with: module
        )
        let differentColor = try await captureColor(
            NSColor(srgbRed: 0.25, green: 0.5, blue: 0.5, alpha: 1),
            with: module
        )
        XCTAssertEqual(sameColor.entryID, firstColor.entryID)
        XCTAssertNotEqual(differentColor.entryID, firstColor.entryID)
    }

    func testReuseUpdatesOnlyCaptureMetadataAndRefreshesExistingBitmapJobs()
        async throws
    {
        let fixture = try DuplicateReuseTemporaryStore()
        let firstTime = Date(timeIntervalSince1970: 10_000)
        let secondTime = Date(timeIntervalSince1970: 20_000)
        let editTime = Date(timeIntervalSince1970: 5_000)
        let retryTime = Date(timeIntervalSince1970: 15_000)
        let clock = TestCaptureClock(firstTime)
        let module = makeDuplicateReuseModule(in: fixture, clock: clock)
        let bitmap = try makeEquivalentBitmapEncodings().png

        let first = try await module.capture(
            bitmapRequest(
                bitmap,
                sourceBundleID: "dev.bybee.first",
                sourceName: "First"
            )
        )
        try await module.prepareDuplicateReuseMetadataForTesting(
            entryID: first.entryID,
            isFavorite: true,
            tags: ["important", "project"],
            editedAt: editTime,
            jobs: [
                .init(
                    kind: "ocr",
                    state: "failed",
                    attemptCount: 3,
                    eligibleGeneration: 7,
                    nextAttemptAt: retryTime
                ),
                .init(
                    kind: "qr",
                    state: "succeeded",
                    attemptCount: 1,
                    eligibleGeneration: 9,
                    nextAttemptAt: nil
                ),
            ]
        )
        await module.setAutomaticImageTextIndexingForTesting(true)
        let beforeValue = try await module.duplicateReuseDiagnosticsForTesting(
            first.entryID
        )
        let before = try XCTUnwrap(beforeValue)

        clock.now = secondTime
        let second = try await module.capture(
            bitmapRequest(
                bitmap,
                sourceBundleID: "dev.bybee.second",
                sourceName: "Second"
            )
        )

        XCTAssertEqual(second.entryID, first.entryID)
        let afterValue = try await module.duplicateReuseDiagnosticsForTesting(
            first.entryID
        )
        let after = try XCTUnwrap(afterValue)
        XCTAssertEqual(after.capturedAt, secondTime)
        XCTAssertEqual(after.lastCapturedAt, secondTime)
        XCTAssertEqual(after.sourceBundleID, "dev.bybee.second")
        XCTAssertEqual(after.sourceDisplayName, "Second")
        XCTAssertEqual(after.retentionStartedAt, secondTime)
        XCTAssertTrue(after.isFavorite)
        XCTAssertTrue(after.isProtected)
        XCTAssertEqual(after.tags, ["important", "project"])
        XCTAssertEqual(after.editedAt, editTime)
        XCTAssertEqual(after.payloadIDs, before.payloadIDs)
        XCTAssertEqual(
            after.jobs,
            [
                .init(
                    kind: "ocr",
                    state: "pending",
                    attemptCount: 0,
                    eligibleGeneration: 8,
                    nextAttemptAt: nil
                ),
                .init(
                    kind: "qr",
                    state: "pending",
                    attemptCount: 0,
                    eligibleGeneration: 10,
                    nextAttemptAt: nil
                ),
            ]
        )
        XCTAssertEqual(try fixture.payloadFiles().count, 2)
    }

    func testSeveralMatchingLegacyRowsReuseNewestWithoutMergingOthers()
        async throws
    {
        let fixture = try DuplicateReuseTemporaryStore()
        let keyStore = DuplicateReuseMasterKeyStore()
        let clock = TestCaptureClock(Date(timeIntervalSince1970: 1_000))
        let legacyWriter = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: keyStore,
            now: { clock.now },
            duplicateReuseEnabled: false
        )
        let first = try await legacyWriter.capture(textRequest("legacy same"))
        clock.now = Date(timeIntervalSince1970: 2_000)
        let newest = try await legacyWriter.capture(textRequest("legacy same"))
        XCTAssertNotEqual(newest.entryID, first.entryID)
        try await legacyWriter.closeStoreForTesting()

        clock.now = Date(timeIntervalSince1970: 3_000)
        let module = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: keyStore,
            now: { clock.now }
        )
        let recaptured = try await module.capture(
            textRequest(
                "legacy same",
                sourceBundleID: "dev.bybee.latest",
                sourceName: "Latest"
            )
        )

        XCTAssertEqual(recaptured.entryID, newest.entryID)
        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries.map(\.id), [newest.entryID, first.entryID])
        let untouchedValue =
            try await module.duplicateReuseDiagnosticsForTesting(
                first.entryID
            )
        let untouched = try XCTUnwrap(
            untouchedValue
        )
        XCTAssertEqual(
            untouched.capturedAt,
            Date(timeIntervalSince1970: 1_000)
        )
    }

    func testReuseMetadataAndRetentionUpdateRollBackTogether() async throws {
        let fixture = try DuplicateReuseTemporaryStore()
        let keyStore = DuplicateReuseMasterKeyStore()
        let clock = TestCaptureClock(Date(timeIntervalSince1970: 1_000))
        let writer = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: keyStore,
            now: { clock.now }
        )
        let original = try await writer.capture(
            textRequest(
                "transactional reuse",
                sourceBundleID: "dev.bybee.original",
                sourceName: "Original"
            )
        )
        try await writer.closeStoreForTesting()

        clock.now = Date(timeIntervalSince1970: 2_000)
        let failing = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: keyStore,
            faultInjector: ClipboardHistoryFaultInjector(
                points: [.databaseTransaction]
            ),
            now: { clock.now }
        )
        do {
            _ = try await failing.capture(
                textRequest(
                    "transactional reuse",
                    sourceBundleID: "dev.bybee.failed",
                    sourceName: "Failed"
                )
            )
            XCTFail("Expected the reuse transaction to fail")
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryModuleError,
                .storageFailure
            )
        }

        let stateValue =
            try await failing.duplicateReuseDiagnosticsForTesting(
                original.entryID
            )
        let state = try XCTUnwrap(stateValue)
        XCTAssertEqual(
            state.capturedAt,
            Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(
            state.retentionStartedAt,
            Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(state.sourceBundleID, "dev.bybee.original")
        XCTAssertEqual(state.sourceDisplayName, "Original")
    }

    func testExpiredEntryOutsideLiveSetIsNeverReused() async throws {
        let fixture = try DuplicateReuseTemporaryStore()
        let module = makeDuplicateReuseModule(in: fixture)
        let first = try await module.capture(textRequest("expired candidate"))
        try await module.markEntryExpiredForTesting(first.entryID)

        let second = try await module.capture(textRequest("expired candidate"))

        XCTAssertNotEqual(second.entryID, first.entryID)
    }

    func testMaterializationDoesNotInvokeDuplicateReuseOrExtendRetention()
        async throws
    {
        let fixture = try DuplicateReuseTemporaryStore()
        let clock = TestCaptureClock(Date(timeIntervalSince1970: 1_000))
        let module = makeDuplicateReuseModule(in: fixture, clock: clock)
        let capture = try await module.capture(textRequest("self write"))
        let beforeValue = try await module.duplicateReuseDiagnosticsForTesting(
            capture.entryID
        )
        let before = try XCTUnwrap(beforeValue)
        clock.now = Date(timeIntervalSince1970: 9_000)

        _ = try await module.materialize(
            ClipboardHistoryMaterializationRequest(
                entryID: capture.entryID,
                purpose: .normalPaste
            )
        )

        let afterValue = try await module.duplicateReuseDiagnosticsForTesting(
            capture.entryID
        )
        let after = try XCTUnwrap(afterValue)
        XCTAssertEqual(after, before)
    }

    func testMissingOwnedPayloadPreventsReuse() async throws {
        let fixture = try DuplicateReuseTemporaryStore()
        let module = makeDuplicateReuseModule(in: fixture)
        let bitmap = try makeEquivalentBitmapEncodings().png
        let first = try await module.capture(bitmapRequest(bitmap))
        let payload = try XCTUnwrap(try fixture.bitmapPayloadFile())
        try FileManager.default.removeItem(at: payload)

        let second = try await module.capture(bitmapRequest(bitmap))

        XCTAssertNotEqual(second.entryID, first.entryID)
    }

    func testUnauthenticatedOwnedPayloadPreventsReuse() async throws {
        let fixture = try DuplicateReuseTemporaryStore()
        let module = makeDuplicateReuseModule(in: fixture)
        let bitmap = try makeEquivalentBitmapEncodings().png
        let first = try await module.capture(bitmapRequest(bitmap))
        let payload = try XCTUnwrap(try fixture.bitmapPayloadFile())
        var corrupt = try Data(contentsOf: payload)
        corrupt[corrupt.index(before: corrupt.endIndex)] ^= 0xFF
        try corrupt.write(to: payload)

        let second = try await module.capture(bitmapRequest(bitmap))

        XCTAssertNotEqual(second.entryID, first.entryID)
    }
}

extension ClipboardHistoryModule {
    struct DuplicateReuseDiagnostics: Equatable {
        struct DerivedJob: Equatable {
            let kind: String
            let state: String
            let attemptCount: Int
            let eligibleGeneration: Int
            let nextAttemptAt: Date?
        }

        let capturedAt: Date
        let lastCapturedAt: Date
        let sourceBundleID: String?
        let sourceDisplayName: String?
        let isFavorite: Bool
        let editedAt: Date?
        let tags: Set<String>
        let retentionStartedAt: Date
        let isProtected: Bool
        let payloadIDs: Set<String>
        let jobs: [DerivedJob]
    }

    func prepareDuplicateReuseMetadataForTesting(
        entryID: ClipboardHistoryEntryID,
        isFavorite: Bool,
        tags: Set<String>,
        editedAt: Date?,
        jobs: [DuplicateReuseDiagnostics.DerivedJob] = []
    ) throws {
        let database = try requiredDatabase()
        let storedID = entryID.value.uuidString.lowercased()
        try database.write { database in
            try database.execute(
                sql: """
                    UPDATE clipboard_entries
                    SET is_favorite = ?, edited_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    isFavorite,
                    editedAt?.timeIntervalSince1970,
                    storedID,
                ]
            )
            try database.execute(
                sql: "DELETE FROM clipboard_entry_tags WHERE entry_id = ?",
                arguments: [storedID]
            )
            for tag in tags {
                try database.execute(
                    sql: """
                        INSERT INTO clipboard_entry_tags(entry_id, tag_id)
                        VALUES (?, ?)
                        """,
                    arguments: [storedID, tag]
                )
            }
            try database.execute(
                sql: """
                    UPDATE clipboard_retention_state
                    SET is_protected = ?
                    WHERE entry_id = ?
                    """,
                arguments: [isFavorite || !tags.isEmpty, storedID]
            )
            for job in jobs {
                try database.execute(
                    sql: """
                        INSERT INTO clipboard_derived_jobs(
                            entry_id, kind, state, attempt_count,
                            eligible_generation, next_attempt_at
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        storedID,
                        job.kind,
                        job.state,
                        job.attemptCount,
                        job.eligibleGeneration,
                        job.nextAttemptAt?.timeIntervalSince1970,
                    ]
                )
            }
        }
    }

    func markEntryExpiredForTesting(
        _ entryID: ClipboardHistoryEntryID
    ) throws {
        let database = try requiredDatabase()
        try database.write { database in
            try database.execute(
                sql: """
                    DELETE FROM clipboard_retention_state
                    WHERE entry_id = ?
                    """,
                arguments: [entryID.value.uuidString.lowercased()]
            )
        }
    }

    func setAutomaticImageTextIndexingForTesting(_ enabled: Bool) {
        automaticImageTextIndexingEnabled = enabled
    }

    func duplicateReuseDiagnosticsForTesting(
        _ entryID: ClipboardHistoryEntryID
    ) throws -> DuplicateReuseDiagnostics? {
        let database = try requiredDatabase()
        let storedID = entryID.value.uuidString.lowercased()
        return try database.read { database in
            guard
                let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT entry.captured_at, entry.last_captured_at,
                               entry.source_bundle_id, entry.source_display_name,
                               entry.is_favorite, entry.edited_at,
                               retention.retention_started_at,
                               retention.is_protected
                        FROM clipboard_entries AS entry
                        JOIN clipboard_retention_state AS retention
                          ON retention.entry_id = entry.id
                        WHERE entry.id = ?
                        """,
                    arguments: [storedID]
                )
            else {
                return nil
            }
            let payloadIDs = try Set(
                String.fetchAll(
                    database,
                    sql: """
                        SELECT payload_id
                        FROM clipboard_representations
                        WHERE entry_id = ? AND payload_id IS NOT NULL
                        UNION
                        SELECT thumbnail_payload_id
                        FROM clipboard_entries
                        WHERE id = ? AND thumbnail_payload_id IS NOT NULL
                        """,
                    arguments: [storedID, storedID]
                )
            )
            let jobs = try Row.fetchAll(
                database,
                sql: """
                    SELECT kind, state, attempt_count, eligible_generation,
                           next_attempt_at
                    FROM clipboard_derived_jobs
                    WHERE entry_id = ?
                    ORDER BY kind
                    """,
                arguments: [storedID]
            ).map { job in
                DuplicateReuseDiagnostics.DerivedJob(
                    kind: job["kind"],
                    state: job["state"],
                    attemptCount: job["attempt_count"],
                    eligibleGeneration: job["eligible_generation"],
                    nextAttemptAt: (job["next_attempt_at"] as Double?).map {
                        Date(timeIntervalSince1970: $0)
                    }
                )
            }
            return DuplicateReuseDiagnostics(
                capturedAt: Date(
                    timeIntervalSince1970: row["captured_at"]
                ),
                lastCapturedAt: Date(
                    timeIntervalSince1970: row["last_captured_at"]
                ),
                sourceBundleID: row["source_bundle_id"],
                sourceDisplayName: row["source_display_name"],
                isFavorite: row["is_favorite"],
                editedAt: (row["edited_at"] as Double?).map {
                    Date(timeIntervalSince1970: $0)
                },
                tags: Set(
                    try String.fetchAll(
                        database,
                        sql: """
                            SELECT tag_id
                            FROM clipboard_entry_tags
                            WHERE entry_id = ?
                            """,
                        arguments: [storedID]
                    )
                ),
                retentionStartedAt: Date(
                    timeIntervalSince1970: row["retention_started_at"]
                ),
                isProtected: row["is_protected"],
                payloadIDs: payloadIDs,
                jobs: jobs
            )
        }
    }
}

private final class DuplicateReuseTemporaryStore {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-ClipboardHistoryDuplicateTests-\(UUID().uuidString)"
            )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func payloadFiles() throws -> [URL] {
        let directory = url.appendingPathComponent("payloads")
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "payload" }
    }

    func bitmapPayloadFile() throws -> URL? {
        try payloadFiles().first { url in
            let envelope = try Data(contentsOf: url)
            return envelope.count > 9
                && envelope[9] == ClipboardHistoryPayloadKind.bitmap.rawValue
        }
    }
}

private final class TestCaptureClock: @unchecked Sendable {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private final class DuplicateReuseFileFixture {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AnyDoor-ClipboardDuplicateFiles-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func create(_ name: String) throws -> URL {
        let file = url.appendingPathComponent(name)
        try Data(name.utf8).write(to: file)
        return file
    }
}

extension ClipboardHistoryDuplicateReuseTests {
    fileprivate func makeDuplicateReuseModule(
        in fixture: DuplicateReuseTemporaryStore,
        clock: TestCaptureClock = TestCaptureClock(Date())
    ) -> ClipboardHistoryModule {
        ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: DuplicateReuseMasterKeyStore(),
            now: { clock.now }
        )
    }

    fileprivate func textRequest(
        _ value: String,
        sourceBundleID: String = "dev.bybee.tests",
        sourceName: String = "Tests"
    ) -> ClipboardHistoryCaptureRequest {
        ClipboardHistoryCaptureRequest(
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: sourceBundleID,
                displayName: sourceName
            ),
            content: .text(value)
        )
    }

    fileprivate func bitmapRequest(
        _ value: Data,
        sourceBundleID: String = "dev.bybee.tests",
        sourceName: String = "Tests"
    ) -> ClipboardHistoryCaptureRequest {
        ClipboardHistoryCaptureRequest(
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: sourceBundleID,
                displayName: sourceName
            ),
            content: .bitmap(value, provenance: .image)
        )
    }

    @MainActor
    fileprivate func captureTextItems(
        _ values: [String],
        with module: ClipboardHistoryModule
    ) async throws -> ClipboardHistoryCaptureOutcome {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "dev.bybee.AnyDoor.duplicate-tests.\(UUID().uuidString)"
            )
        )
        pasteboard.clearContents()
        let items = values.map { value in
            let item = NSPasteboardItem()
            item.setString(value, forType: .string)
            return item
        }
        XCTAssertTrue(pasteboard.writeObjects(items))
        let result = try await module.capture(
            ClipboardHistoryPasteboardCaptureRequest(pasteboard: pasteboard),
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: "dev.bybee.tests",
                displayName: "Tests"
            )
        )
        guard case .captured(let outcome) = result else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        return outcome
    }

    @MainActor
    fileprivate func captureRichItem(
        text: String,
        html: Data,
        htmlFirst: Bool,
        with module: ClipboardHistoryModule
    ) async throws -> ClipboardHistoryCaptureOutcome {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "dev.bybee.AnyDoor.duplicate-tests.\(UUID().uuidString)"
            )
        )
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        if htmlFirst {
            item.setData(html, forType: .html)
            item.setString(text, forType: .string)
        } else {
            item.setString(text, forType: .string)
            item.setData(html, forType: .html)
        }
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let result = try await module.capture(
            ClipboardHistoryPasteboardCaptureRequest(pasteboard: pasteboard),
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: "dev.bybee.tests",
                displayName: "Tests"
            )
        )
        guard case .captured(let outcome) = result else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        return outcome
    }

    @MainActor
    fileprivate func captureBitmap(
        _ data: Data,
        type: NSPasteboard.PasteboardType,
        with module: ClipboardHistoryModule
    ) async throws -> ClipboardHistoryCaptureOutcome {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "dev.bybee.AnyDoor.duplicate-tests.\(UUID().uuidString)"
            )
        )
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(data, forType: type)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let result = try await module.capture(
            ClipboardHistoryPasteboardCaptureRequest(pasteboard: pasteboard),
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: "dev.bybee.tests",
                displayName: "Tests"
            )
        )
        guard case .captured(let outcome) = result else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        return outcome
    }

    @MainActor
    fileprivate func captureFiles(
        _ urls: [URL],
        with module: ClipboardHistoryModule
    ) async throws -> ClipboardHistoryCaptureOutcome {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "dev.bybee.AnyDoor.duplicate-tests.\(UUID().uuidString)"
            )
        )
        pasteboard.clearContents()
        let items = urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        XCTAssertTrue(pasteboard.writeObjects(items))
        let result = try await module.capture(
            ClipboardHistoryPasteboardCaptureRequest(pasteboard: pasteboard),
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: "com.apple.finder",
                displayName: "Finder"
            )
        )
        guard case .captured(let outcome) = result else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        return outcome
    }

    @MainActor
    fileprivate func captureTypedText(
        _ value: String,
        type: NSPasteboard.PasteboardType,
        with module: ClipboardHistoryModule
    ) async throws -> ClipboardHistoryCaptureOutcome {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "dev.bybee.AnyDoor.duplicate-tests.\(UUID().uuidString)"
            )
        )
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(value, forType: type)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let result = try await module.capture(
            ClipboardHistoryPasteboardCaptureRequest(pasteboard: pasteboard),
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: "dev.bybee.tests",
                displayName: "Tests"
            )
        )
        guard case .captured(let outcome) = result else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        return outcome
    }

    @MainActor
    fileprivate func captureColor(
        _ color: NSColor,
        with module: ClipboardHistoryModule
    ) async throws -> ClipboardHistoryCaptureOutcome {
        let data = try XCTUnwrap(
            color.pasteboardPropertyList(forType: .color) as? Data
        )
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "dev.bybee.AnyDoor.duplicate-tests.\(UUID().uuidString)"
            )
        )
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(data, forType: .color)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let result = try await module.capture(
            ClipboardHistoryPasteboardCaptureRequest(pasteboard: pasteboard),
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: "dev.bybee.tests",
                displayName: "Tests"
            )
        )
        guard case .captured(let outcome) = result else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        return outcome
    }

    fileprivate func makeEquivalentBitmapEncodings(
        components: [CGFloat] = [0.25, 0.5, 0.75, 1]
    ) throws -> (png: Data, tiff: Data) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(
            CGColor(
                colorSpace: colorSpace,
                components: components
            )!
        )
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try XCTUnwrap(context.makeImage())

        func encode(_ type: UTType) throws -> Data {
            let data = NSMutableData()
            let destination = try XCTUnwrap(
                CGImageDestinationCreateWithData(
                    data,
                    type.identifier as CFString,
                    1,
                    nil
                )
            )
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return data as Data
        }
        return (try encode(.png), try encode(.tiff))
    }
}

private final class DuplicateReuseMasterKeyStore:
    ClipboardHistoryMasterKeyStoring,
    @unchecked Sendable
{
    private var key: Data?

    func load() -> ClipboardHistoryMasterKeyResult {
        key.map(ClipboardHistoryMasterKeyResult.key) ?? .missing
    }

    func create() -> ClipboardHistoryMasterKeyResult {
        let key = Data(repeating: 0x82, count: 32)
        self.key = key
        return .key(key)
    }

    func delete() -> ClipboardHistoryMasterKeyResult {
        key = nil
        return .missing
    }
}
