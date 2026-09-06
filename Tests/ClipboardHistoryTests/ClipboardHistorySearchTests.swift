import AppKit
import Foundation
import GRDB
import XCTest

@testable import ClipboardHistory

final class ClipboardHistorySearchTests: XCTestCase {
    func testSearchMatchesUnicodeExactPrefixAndSubstringForms() async throws {
        let fixture = try SearchTemporaryDatabase()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        let values = [
            "剪贴板历史",
            "Clipboard History",
            "Cafe\u{301} Society",
            "Ｆｕｌｌ－Ｗｉｄｔｈ",
            "Launch 🚀 now",
            "literal [brackets] + punctuation",
        ]
        for value in values {
            _ = try await module.capture(
                ClipboardHistoryCaptureRequest(
                    source: .unknown,
                    content: .text(value)
                )
            )
        }

        for (query, expected) in [
            ("剪贴板历史", "剪贴板历史"),
            ("剪贴", "剪贴板历史"),
            ("贴板历", "剪贴板历史"),
            ("clipboard history", "Clipboard History"),
            ("clip", "Clipboard History"),
            ("board hist", "Clipboard History"),
            ("café society", "Cafe\u{301} Society"),
            ("full-width", "Ｆｕｌｌ－Ｗｉｄｔｈ"),
            ("🚀", "Launch 🚀 now"),
            ("[brackets] +", "literal [brackets] + punctuation"),
        ] {
            let page = try await module.page(
                ClipboardHistoryQuery(text: query)
            )
            XCTAssertEqual(
                page.entries.map(\.previewText),
                [expected],
                "Unexpected results for \(query)"
            )
        }

        for (expected, queries) in [
            (
                "Cafe\u{301} Society",
                ["café society", "cafe", "fé soci"]
            ),
            (
                "Ｆｕｌｌ－Ｗｉｄｔｈ",
                ["full-width", "full", "ll-wid"]
            ),
            (
                "Launch 🚀 now",
                ["launch 🚀 now", "launch 🚀", "🚀 no"]
            ),
            (
                "literal [brackets] + punctuation",
                [
                    "literal [brackets] + punctuation",
                    "literal [brackets]",
                    "[brackets] +",
                ]
            ),
        ] {
            for query in queries {
                let page = try await module.page(
                    ClipboardHistoryQuery(text: query)
                )
                XCTAssertEqual(
                    page.entries.map(\.previewText),
                    [expected],
                    "Unexpected match class for \(query)"
                )
            }
        }
    }

    func testOneAndTwoCodePointTermsReturnIndexedMatches() async throws {
        let fixture = try SearchTemporaryDatabase()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        _ = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: .unknown,
                content: .text("甲乙丙丁")
            )
        )

        let one = try await module.page(ClipboardHistoryQuery(text: "乙"))
        let two = try await module.page(ClipboardHistoryQuery(text: "乙丙"))

        XCTAssertEqual(one.entries.map(\.previewText), ["甲乙丙丁"])
        XCTAssertEqual(two.entries.map(\.previewText), ["甲乙丙丁"])
    }

    func testSourceSummariesRemainAuthoritativeAcrossSearches() async throws {
        let fixture = try SearchTemporaryDatabase()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        let safari = ClipboardHistoryCaptureSource(
            bundleIdentifier: "com.apple.Safari",
            displayName: "Safari"
        )
        let notes = ClipboardHistoryCaptureSource(
            bundleIdentifier: "com.apple.Notes",
            displayName: "Notes"
        )
        let removable = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: safari,
                content: .text("alpha searchable")
            )
        )
        _ = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: safari,
                content: .text("beta")
            )
        )
        _ = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: notes,
                content: .text("gamma")
            )
        )
        _ = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: .unknown,
                content: .text("anonymous")
            )
        )
        _ = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: .universalClipboard,
                content: .text("remote")
            )
        )

        _ = try await module.page(
            ClipboardHistoryQuery(text: "searchable")
        )
        let initialSummaries = try await module.sourceSummaries()
        XCTAssertEqual(
            initialSummaries.reduce(0) { $0 + $1.count },
            5,
            "source summaries must include Unknown and Universal Clipboard"
        )
        XCTAssertEqual(
            initialSummaries,
            [
                ClipboardHistorySourceSummary(
                    bundleIdentifier: "com.apple.Notes",
                    displayName: "Notes",
                    count: 1
                ),
                ClipboardHistorySourceSummary(
                    bundleIdentifier: "com.apple.Safari",
                    displayName: "Safari",
                    count: 2
                ),
                ClipboardHistorySourceSummary(
                    id: .universalClipboard,
                    displayName: nil,
                    count: 1
                ),
                ClipboardHistorySourceSummary(
                    id: .unknown,
                    displayName: nil,
                    count: 1
                ),
            ]
        )
        let universalPage = try await module.page(
            ClipboardHistoryQuery(sourceID: .universalClipboard)
        )
        XCTAssertEqual(universalPage.entries.map(\.previewText), ["remote"])
        let unknownPage = try await module.page(
            ClipboardHistoryQuery(sourceID: .unknown)
        )
        XCTAssertEqual(unknownPage.entries.map(\.previewText), ["anonymous"])

        _ = try await module.apply(.delete(removable.entryID))
        let updatedSummaries = try await module.sourceSummaries()
        XCTAssertEqual(
            updatedSummaries,
            [
                ClipboardHistorySourceSummary(
                    bundleIdentifier: "com.apple.Notes",
                    displayName: "Notes",
                    count: 1
                ),
                ClipboardHistorySourceSummary(
                    bundleIdentifier: "com.apple.Safari",
                    displayName: "Safari",
                    count: 1
                ),
                ClipboardHistorySourceSummary(
                    id: .universalClipboard,
                    displayName: nil,
                    count: 1
                ),
                ClipboardHistorySourceSummary(
                    id: .unknown,
                    displayName: nil,
                    count: 1
                ),
            ]
        )
    }

    @MainActor
    func testMultiTermSearchCombinesFieldsAcrossOrderedItems() async throws {
        let fixture = try SearchTemporaryDatabase()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "dev.bybee.AnyDoor.search-tests.\(UUID().uuidString)"
            )
        )
        pasteboard.clearContents()
        let first = NSPasteboardItem()
        first.setString("alpha visible", forType: .string)
        let second = NSPasteboardItem()
        second.setString("beta item", forType: .string)
        XCTAssertTrue(pasteboard.writeObjects([first, second]))
        let outcome = try await module.capture(
            ClipboardHistoryPasteboardCaptureRequest(pasteboard: pasteboard),
            source: .unknown
        )
        guard case .captured(let captured) = outcome else {
            return XCTFail("Expected a mixed-item capture")
        }

        let page = try await module.page(
            ClipboardHistoryQuery(text: "alpha beta")
        )

        XCTAssertEqual(page.entries.map(\.id), [captured.entryID])
        for query in [
            "alpha visible",
            "alpha vis",
            "pha visi",
            "beta item",
            "beta it",
            "eta ite",
        ] {
            let classPage = try await module.page(
                ClipboardHistoryQuery(text: query)
            )
            XCTAssertEqual(classPage.entries.map(\.id), [captured.entryID])
        }
    }

    @MainActor
    func testRankingPrefersCompleteMatchClassFieldPriorityAndPhrase()
        async throws
    {
        let fixture = try SearchTemporaryDatabase()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        _ = try await Self.capture("needle", in: module)
        _ = try await Self.capture("needle prefix", in: module)
        _ = try await Self.capture("a needle substring", in: module)

        let ranked = try await module.page(
            ClipboardHistoryQuery(text: "needle")
        )
        XCTAssertEqual(
            ranked.entries.map(\.previewText),
            ["needle", "needle prefix", "a needle substring"]
        )

        _ = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: ClipboardHistoryCaptureSource(
                    bundleIdentifier: "dev.bybee.visible",
                    displayName: "Visible"
                ),
                content: .text("priority token visible")
            )
        )
        _ = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: ClipboardHistoryCaptureSource(
                    bundleIdentifier: "dev.bybee.ocr",
                    displayName: "OCR"
                ),
                content: .ocr("priority token ocr")
            )
        )
        let fieldPriority = try await module.page(
            ClipboardHistoryQuery(text: "priority token")
        )
        XCTAssertEqual(
            fieldPriority.entries.map(\.source.bundleIdentifier),
            ["dev.bybee.visible", "dev.bybee.ocr"]
        )
        let database = try await module.requiredDatabase()
        let fieldKinds = try await database.read { database in
            try String.fetchAll(
                database,
                sql: """
                    SELECT field.field_kind
                    FROM clipboard_search_fields AS field
                    JOIN clipboard_entries AS entry
                      ON entry.id = field.entry_id
                    WHERE field.normalized_value LIKE 'priority token%'
                    ORDER BY entry.last_captured_at
                    """
            )
        }
        XCTAssertEqual(fieldKinds, ["exactText", "ocr"])

        let phrase = try await Self.capture(
            "inside alpha beta phrase",
            in: module
        )
        let split = try await Self.captureMixedTextItems(
            ["alpha only", "beta only"],
            in: module
        )
        let phraseResults = try await module.page(
            ClipboardHistoryQuery(text: "alpha beta")
        )
        let phraseIDs = phraseResults.entries.map(\.id)
        XCTAssertLessThan(
            try XCTUnwrap(phraseIDs.firstIndex(of: phrase)),
            try XCTUnwrap(phraseIDs.firstIndex(of: split))
        )
    }

    func testTypedFiltersCombineWithoutBecomingSearchText() async throws {
        let fixture = try SearchTemporaryDatabase()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        let source = ClipboardHistoryCaptureSource(
            bundleIdentifier: "dev.bybee.filtered",
            displayName: "Filtered"
        )
        let wanted = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: source,
                content: .text("https://needle.example")
            )
        )
        _ = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: ClipboardHistoryCaptureSource(
                    bundleIdentifier: "dev.bybee.other",
                    displayName: "Other"
                ),
                content: .text("https://needle.example/other")
            )
        )
        await module.awaitSearchIndexRebuildForTesting()
        let allEntries = try await module.page(ClipboardHistoryQuery()).entries
        let captured = try XCTUnwrap(
            allEntries.first { $0.id == wanted.entryID }
        )
        let database = try await module.requiredDatabase()
        try await database.write { database in
            let id = wanted.entryID.value.uuidString.lowercased()
            try database.execute(
                sql: "UPDATE clipboard_entries SET is_favorite = 1 WHERE id = ?",
                arguments: [id]
            )
            try database.execute(
                sql: """
                    INSERT INTO clipboard_entry_tags(entry_id, tag_id)
                    VALUES (?, 'important')
                    """,
                arguments: [id]
            )
            try ClipboardHistoryModule.bumpSearchIndexGeneration(in: database)
        }

        let page = try await module.page(
            ClipboardHistoryQuery(
                text: "needle",
                facet: .link,
                sourceID: .application("dev.bybee.filtered"),
                tagID: "important",
                favoritesOnly: true,
                capturedAfter: captured.capturedAt.addingTimeInterval(-1),
                capturedBefore: captured.capturedAt.addingTimeInterval(1)
            )
        )

        XCTAssertEqual(page.entries.map(\.id), [wanted.entryID])
        let filterWords = try await module.page(
            ClipboardHistoryQuery(text: "important filtered favorite link")
        )
        XCTAssertEqual(filterWords.entries, [])
    }

    func testCandidateVerificationRejectsStaleLongAndShortIndexTokens()
        async throws
    {
        let fixture = try SearchTemporaryDatabase()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        _ = try await Self.capture("authoritative value", in: module)
        let database = try await module.requiredDatabase()
        try await database.write { database in
            let field = try XCTUnwrap(
                Row.fetchOne(
                    database,
                    sql: """
                        SELECT id, normalized_value
                        FROM clipboard_search_fields
                        """
                )
            )
            let fieldID: Int64 = field["id"]
            let oldValue: String = field["normalized_value"]
            try ClipboardHistoryModule.deleteSearchIndexEntries(
                fieldID: fieldID,
                normalizedValue: oldValue,
                from: database
            )
            try ClipboardHistoryModule.insertSearchIndexEntries(
                fieldID: fieldID,
                normalizedValue: "stale 假",
                into: database
            )
        }

        let long = try await module.page(
            ClipboardHistoryQuery(text: "stale")
        )
        let short = try await module.page(
            ClipboardHistoryQuery(text: "假")
        )

        XCTAssertEqual(long.entries, [])
        XCTAssertEqual(short.entries, [])
    }

    func testCommittedDeletionRemovesBothIndexCandidates() async throws {
        let fixture = try SearchTemporaryDatabase()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        let outcome = try await Self.capture(
            "delete 搜索 searchable",
            in: module
        )

        let deletion = try await module.apply(.delete(outcome))
        XCTAssertEqual(deletion, .deleted)

        let longResults = try await module.page(
            ClipboardHistoryQuery(text: "searchable")
        )
        XCTAssertEqual(longResults.entries, [])
        let shortResults = try await module.page(
            ClipboardHistoryQuery(text: "搜")
        )
        XCTAssertEqual(shortResults.entries, [])
        let database = try await module.requiredDatabase()
        let integrity = try await database.write { database in
            try ClipboardHistoryModule.searchIndexesPassIntegrityCheck(
                in: database
            )
        }
        XCTAssertTrue(integrity)
    }

    func testFTSTablesUseSecureDeleteAndIndexedMatchPlans() async throws {
        let fixture = try SearchTemporaryDatabase()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        _ = try await Self.capture("indexed 搜索 value", in: module)
        let database = try await module.requiredDatabase()

        let diagnostics = try await database.write { database in
            let trigramSecureDelete = try Int.fetchOne(
                database,
                sql: """
                    SELECT v
                    FROM clipboard_search_trigram_config
                    WHERE k = 'secure-delete'
                    """
            )
            let shortSecureDelete = try Int.fetchOne(
                database,
                sql: """
                    SELECT v
                    FROM clipboard_search_short_grams_config
                    WHERE k = 'secure-delete'
                    """
            )
            let shortPlan = try Row.fetchAll(
                database,
                sql: """
                    EXPLAIN QUERY PLAN
                    SELECT field.entry_id
                    FROM clipboard_search_short_grams AS candidate
                    JOIN clipboard_search_fields AS field
                      ON field.id = candidate.rowid
                    WHERE clipboard_search_short_grams MATCH ?
                    """,
                arguments: [
                    ClipboardHistoryModule.ftsLiteral(
                        try XCTUnwrap(
                            ClipboardHistoryModule.encodedShortTerm("搜")
                        )
                    )
                ]
            ).map { $0["detail"] as String }
            let longPlan = try Row.fetchAll(
                database,
                sql: """
                    EXPLAIN QUERY PLAN
                    SELECT field.entry_id
                    FROM clipboard_search_trigram AS candidate
                    JOIN clipboard_search_fields AS field
                      ON field.id = candidate.rowid
                    WHERE clipboard_search_trigram MATCH ?
                    """,
                arguments: [ClipboardHistoryModule.ftsLiteral("indexed")]
            ).map { $0["detail"] as String }
            let integrity =
                try ClipboardHistoryModule.searchIndexesPassIntegrityCheck(
                    in: database
                )
            return (
                trigramSecureDelete,
                shortSecureDelete,
                shortPlan,
                longPlan,
                integrity
            )
        }

        XCTAssertEqual(diagnostics.0, 1)
        XCTAssertEqual(diagnostics.1, 1)
        XCTAssertTrue(diagnostics.2.contains {
            $0.contains("VIRTUAL TABLE INDEX")
        })
        XCTAssertTrue(diagnostics.3.contains {
            $0.contains("VIRTUAL TABLE INDEX")
        })
        XCTAssertFalse(diagnostics.2.contains {
            $0.contains("SCAN clipboard_search_fields")
        })
        XCTAssertFalse(diagnostics.3.contains {
            $0.contains("SCAN clipboard_search_fields")
        })
        XCTAssertTrue(diagnostics.4)
    }

    func testKeysetPagesHaveNoCapDuplicatesAndRestartOnChangedInputs()
        async throws
    {
        let fixture = try SearchTemporaryDatabase()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        await module.awaitSearchIndexRebuildForTesting()
        let database = try await module.requiredDatabase()
        try await database.write { database in
            for index in 0..<205 {
                let id = UUID().uuidString.lowercased()
                let source = index.isMultiple(of: 2) ? "source-a" : "source-b"
                let timestamp = Double(index + 1)
                try database.execute(
                    sql: """
                        INSERT INTO clipboard_entries(
                            id, captured_at, last_captured_at,
                            source_bundle_id, source_display_name,
                            source_provenance, preview_text
                        ) VALUES (?, ?, ?, ?, ?, 'declared', ?)
                        """,
                    arguments: [
                        id,
                        timestamp,
                        timestamp,
                        source,
                        source,
                        "bulk-token \(index)",
                    ]
                )
                try ClipboardHistoryModule.insertSearchField(
                    value: "bulk-token \(index)",
                    kind: "exactText",
                    index: 0,
                    rankingGroup: 0,
                    entryID: id,
                    into: database
                )
                try database.execute(
                    sql: """
                        INSERT INTO clipboard_retention_state(
                            entry_id, retention_started_at, is_protected
                        ) VALUES (?, ?, 0)
                        """,
                    arguments: [
                        id,
                        Date().timeIntervalSince1970,
                    ]
                )
            }
            try ClipboardHistoryModule.bumpSearchIndexGeneration(in: database)
        }

        let query = ClipboardHistoryQuery(text: "bulk-token")
        var cursor: ClipboardHistoryCursor?
        var pageSizes: [Int] = []
        var dispositions: [ClipboardHistoryCursorDisposition] = []
        var identifiers: [ClipboardHistoryEntryID] = []
        repeat {
            let page = try await module.page(query, after: cursor)
            pageSizes.append(page.entries.count)
            dispositions.append(page.cursorDisposition)
            identifiers += page.entries.map(\.id)
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(pageSizes, [100, 100, 5])
        XCTAssertEqual(dispositions, [.initial, .continued, .continued])
        XCTAssertEqual(identifiers.count, 205)
        XCTAssertEqual(Set(identifiers).count, 205)

        let first = try await module.page(query)
        let sourceRestart = try await module.page(
            ClipboardHistoryQuery(
                text: "bulk-token",
                sourceID: .application("source-a")
            ),
            after: first.nextCursor
        )
        let expectedSourceFirst = try await module.page(
            ClipboardHistoryQuery(
                text: "bulk-token",
                sourceID: .application("source-a")
            )
        )
        // The restart returns the first page, but says so instead of passing
        // for a continuation — everything except the disposition matches.
        XCTAssertEqual(sourceRestart.entries, expectedSourceFirst.entries)
        XCTAssertEqual(
            sourceRestart.nextCursor,
            expectedSourceFirst.nextCursor
        )
        XCTAssertEqual(sourceRestart.state, expectedSourceFirst.state)
        XCTAssertEqual(sourceRestart.cursorDisposition, .restarted)
        XCTAssertEqual(expectedSourceFirst.cursorDisposition, .initial)

        let changedQuery = try await module.page(
            ClipboardHistoryQuery(text: "bulk-token 10"),
            after: first.nextCursor
        )
        let expectedChangedQuery = try await module.page(
            ClipboardHistoryQuery(text: "bulk-token 10")
        )
        XCTAssertEqual(changedQuery.entries, expectedChangedQuery.entries)
        XCTAssertEqual(
            changedQuery.nextCursor,
            expectedChangedQuery.nextCursor
        )
        XCTAssertEqual(changedQuery.state, expectedChangedQuery.state)
        XCTAssertEqual(changedQuery.cursorDisposition, .restarted)
        XCTAssertEqual(expectedChangedQuery.cursorDisposition, .initial)

        let newEntry = try await Self.capture(
            "bulk-token newest",
            in: module
        )
        let generationRestart = try await module.page(
            query,
            after: first.nextCursor
        )
        XCTAssertEqual(generationRestart.entries.first?.id, newEntry)
        XCTAssertEqual(generationRestart.entries.count, 100)
        XCTAssertEqual(generationRestart.cursorDisposition, .restarted)
    }

    /// Browsing keysets off the same binding as searching, and the caller
    /// cannot tell an honored cursor from a dropped one by looking at the
    /// entries: a capture that bumps the index generation silently hands back
    /// the first page. The disposition is the only signal.
    func testBrowsePagesReportWhetherTheCursorWasHonored() async throws {
        let fixture = try SearchTemporaryDatabase()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        await module.awaitSearchIndexRebuildForTesting()
        let database = try await module.requiredDatabase()
        try await database.write { database in
            for index in 0..<150 {
                let id = UUID().uuidString.lowercased()
                let source = index.isMultiple(of: 2) ? "source-a" : "source-b"
                let timestamp = Double(index + 1)
                try database.execute(
                    sql: """
                        INSERT INTO clipboard_entries(
                            id, captured_at, last_captured_at,
                            source_bundle_id, source_display_name,
                            source_provenance, preview_text
                        ) VALUES (?, ?, ?, ?, ?, 'declared', ?)
                        """,
                    arguments: [
                        id,
                        timestamp,
                        timestamp,
                        source,
                        source,
                        "browse-token \(index)",
                    ]
                )
                try database.execute(
                    sql: """
                        INSERT INTO clipboard_retention_state(
                            entry_id, retention_started_at, is_protected
                        ) VALUES (?, ?, 0)
                        """,
                    arguments: [
                        id,
                        Date().timeIntervalSince1970,
                    ]
                )
            }
        }

        let first = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(first.cursorDisposition, .initial)
        XCTAssertEqual(first.entries.count, 100)
        let cursor = try XCTUnwrap(first.nextCursor)

        let second = try await module.page(
            ClipboardHistoryQuery(),
            after: cursor
        )
        XCTAssertEqual(second.cursorDisposition, .continued)
        XCTAssertEqual(second.entries.count, 50)
        XCTAssertNil(second.nextCursor)

        let filterRestart = try await module.page(
            ClipboardHistoryQuery(sourceID: .application("source-a")),
            after: cursor
        )
        let expectedFilterFirst = try await module.page(
            ClipboardHistoryQuery(sourceID: .application("source-a"))
        )
        XCTAssertEqual(filterRestart.entries, expectedFilterFirst.entries)
        XCTAssertEqual(
            filterRestart.nextCursor,
            expectedFilterFirst.nextCursor
        )
        XCTAssertEqual(filterRestart.cursorDisposition, .restarted)
        XCTAssertEqual(expectedFilterFirst.cursorDisposition, .initial)

        let newEntry = try await Self.capture("browse newest", in: module)
        let generationRestart = try await module.page(
            ClipboardHistoryQuery(),
            after: cursor
        )
        XCTAssertEqual(generationRestart.cursorDisposition, .restarted)
        XCTAssertEqual(generationRestart.entries.first?.id, newEntry)
        XCTAssertEqual(generationRestart.entries.count, 100)
    }

    func testIndexingStateKeepsBrowsingAndVersionMismatchRebuilds()
        async throws
    {
        let fixture = try SearchTemporaryDatabase()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        let entry = try await Self.capture("rebuild searchable", in: module)
        let database = try await module.requiredDatabase()
        let oldGeneration = try await database.read {
            try ClipboardHistoryModule.searchIndexGeneration(in: $0)
        }
        try await database.write { database in
            try database.execute(
                sql: """
                    UPDATE clipboard_maintenance_metadata
                    SET text_value = 'indexing'
                    WHERE key = 'searchIndexState'
                    """
            )
        }

        let indexing = try await module.page(
            ClipboardHistoryQuery(text: "rebuild")
        )
        XCTAssertEqual(indexing.state, .indexing)
        XCTAssertEqual(indexing.entries, [])
        XCTAssertEqual(indexing.cursorDisposition, .initial)
        let browsing = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(browsing.entries.map(\.id), [entry])
        try await database.write { database in
            try database.execute(
                sql: """
                    UPDATE clipboard_maintenance_metadata
                    SET integer_value = 0
                    WHERE key = 'searchIndexVersion'
                    """
            )
        }
        try await module.closeStoreForTesting()

        let reopened = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        await reopened.awaitSearchIndexRebuildForTesting()
        let rebuilt = try await reopened.page(
            ClipboardHistoryQuery(text: "rebuild")
        )
        XCTAssertEqual(rebuilt.state, .ready)
        XCTAssertEqual(rebuilt.entries.map(\.id), [entry])
        let reopenedDatabase = try await reopened.requiredDatabase()
        let newGeneration = try await reopenedDatabase.read {
            try ClipboardHistoryModule.searchIndexGeneration(in: $0)
        }
        XCTAssertGreaterThan(newGeneration, oldGeneration)
    }

    func testIndexOnlyCorruptionRebuildsFromAuthoritativeFields()
        async throws
    {
        let fixture = try SearchTemporaryDatabase()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        let entry = try await Self.capture(
            "authoritative rebuild value",
            in: module
        )
        let database = try await module.requiredDatabase()
        try await database.write { database in
            let field = try XCTUnwrap(
                Row.fetchOne(
                    database,
                    sql: """
                        SELECT id, normalized_value
                        FROM clipboard_search_fields
                        WHERE entry_id = ?
                        """,
                    arguments: [entry.value.uuidString.lowercased()]
                )
            )
            try ClipboardHistoryModule.deleteSearchIndexEntries(
                fieldID: field["id"],
                normalizedValue: field["normalized_value"],
                from: database
            )
            try ClipboardHistoryModule.insertSearchIndexEntries(
                fieldID: field["id"],
                normalizedValue: "stale corruption",
                into: database
            )
        }
        let isConsistent = try await database.write {
            try ClipboardHistoryModule.searchIndexesPassIntegrityCheck(in: $0)
        }
        XCTAssertFalse(isConsistent)
        try await module.closeStoreForTesting()

        let reopened = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        await reopened.awaitSearchIndexRebuildForTesting()
        let authoritative = try await reopened.page(
            ClipboardHistoryQuery(text: "authoritative")
        )
        let stale = try await reopened.page(
            ClipboardHistoryQuery(text: "stale")
        )
        XCTAssertEqual(authoritative.entries.map(\.id), [entry])
        XCTAssertEqual(stale.entries, [])
        try await Self.assertSearchIntegrity(reopened)
    }

    func testRebuildFailurePersistsAndExplicitRetryPublishesReadyState()
        async throws
    {
        let fixture = try SearchTemporaryDatabase()
        let original = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        let entry = try await Self.capture(
            "retry authoritative value",
            in: original
        )
        let database = try await original.requiredDatabase()
        let originalGeneration = try await database.read {
            try ClipboardHistoryModule.searchIndexGeneration(in: $0)
        }
        try await database.write { database in
            try database.execute(
                sql: """
                    UPDATE clipboard_maintenance_metadata
                    SET integer_value = 0
                    WHERE key = 'searchIndexVersion'
                    """
            )
        }
        try await original.closeStoreForTesting()

        let failing = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key,
            faultInjector: ClipboardHistoryFaultInjector(
                points: [.searchRebuildBeforePublish]
            )
        )
        await failing.awaitSearchIndexRebuildForTesting()

        let failedSearch = try await failing.page(
            ClipboardHistoryQuery(text: "authoritative")
        )
        XCTAssertEqual(
            failedSearch.state,
            .failed(.rebuildFailed)
        )
        XCTAssertEqual(failedSearch.entries, [])
        let browsing = try await failing.page(ClipboardHistoryQuery())
        XCTAssertEqual(browsing.entries.map(\.id), [entry])
        let failedStatus = await failing.status()
        XCTAssertEqual(
            failedStatus.searchIndex,
            .failed(.rebuildFailed)
        )
        let failedDatabase = try await failing.requiredDatabase()
        let failedGeneration = try await failedDatabase.read {
            try ClipboardHistoryModule.searchIndexGeneration(in: $0)
        }
        XCTAssertEqual(failedGeneration, originalGeneration)
        try await failing.closeStoreForTesting()

        let reopened = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        let persistedFailure = try await reopened.page(
            ClipboardHistoryQuery(text: "authoritative")
        )
        XCTAssertEqual(
            persistedFailure.state,
            .failed(.rebuildFailed)
        )
        let reopenedFailedStatus = await reopened.status()
        XCTAssertEqual(
            reopenedFailedStatus.searchIndex,
            .failed(.rebuildFailed)
        )

        let retryState = try await reopened.retrySearchIndex()
        XCTAssertEqual(retryState, .indexing)
        await reopened.awaitSearchIndexRebuildForTesting()

        let rebuilt = try await reopened.page(
            ClipboardHistoryQuery(text: "authoritative")
        )
        XCTAssertEqual(rebuilt.state, .ready)
        XCTAssertEqual(rebuilt.entries.map(\.id), [entry])
        let readyStatus = await reopened.status()
        XCTAssertEqual(readyStatus.searchIndex, .ready)
        let reopenedDatabase = try await reopened.requiredDatabase()
        let rebuiltGeneration = try await reopenedDatabase.read {
            try ClipboardHistoryModule.searchIndexGeneration(in: $0)
        }
        XCTAssertGreaterThan(rebuiltGeneration, originalGeneration)
    }

    func testClosingDuringExplicitRetryWaitsForOneCompletePublication()
        async throws
    {
        let fixture = try SearchTemporaryDatabase()
        let original = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        let entry = try await Self.capture("close retry value", in: original)
        let database = try await original.requiredDatabase()
        let originalGeneration = try await database.read {
            try ClipboardHistoryModule.searchIndexGeneration(in: $0)
        }
        try await database.write { database in
            try database.execute(
                sql: """
                    UPDATE clipboard_maintenance_metadata
                    SET integer_value = 0
                    WHERE key = 'searchIndexVersion'
                    """
            )
        }
        try await original.closeStoreForTesting()

        let failing = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key,
            faultInjector: ClipboardHistoryFaultInjector(
                points: [.searchRebuildBeforePublish]
            )
        )
        await failing.awaitSearchIndexRebuildForTesting()
        try await failing.closeStoreForTesting()

        let retrying = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        let retryState = try await retrying.retrySearchIndex()
        XCTAssertEqual(retryState, .indexing)
        try await retrying.closeStoreForTesting()

        let reopened = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        await reopened.awaitSearchIndexRebuildForTesting()
        let page = try await reopened.page(
            ClipboardHistoryQuery(text: "close retry")
        )
        XCTAssertEqual(page.state, .ready)
        XCTAssertEqual(page.entries.map(\.id), [entry])
        let reopenedDatabase = try await reopened.requiredDatabase()
        let generation = try await reopenedDatabase.read {
            try ClipboardHistoryModule.searchIndexGeneration(in: $0)
        }
        XCTAssertGreaterThan(generation, originalGeneration)
        try await Self.assertSearchIntegrity(reopened)
    }

    func testMissingFTS5OrTrigramIsAnInvalidRuntime() throws {
        XCTAssertThrowsError(
            try ClipboardHistoryModule.requireSearchRuntimeCapabilities(
                hasFTS5: false,
                hasTrigramTokenizer: true
            )
        ) {
            XCTAssertEqual(
                $0 as? ClipboardHistoryModule.StoreOpenError,
                .unsupportedSearchIndex
            )
        }
        XCTAssertThrowsError(
            try ClipboardHistoryModule.requireSearchRuntimeCapabilities(
                hasFTS5: true,
                hasTrigramTokenizer: false
            )
        ) {
            XCTAssertEqual(
                $0 as? ClipboardHistoryModule.StoreOpenError,
                .unsupportedSearchIndex
            )
        }
    }

    func testSearchFieldInsertUpdateAndDeleteRollBackAtEveryBoundary()
        async throws
    {
        for point in [
            ClipboardHistoryFaultPoint.searchInsertAfterField,
            .searchInsertAfterTrigram,
            .searchInsertAfterShortGrams,
        ] {
            let fixture = try SearchTemporaryDatabase()
            let module = try ClipboardHistoryModule(
                testingDatabaseURL: fixture.url,
                databaseKey: fixture.key,
                faultInjector: ClipboardHistoryFaultInjector(points: [point])
            )
            do {
                _ = try await Self.capture("insert rollback", in: module)
                XCTFail("Expected insert fault at \(point)")
            } catch {
                XCTAssertEqual(
                    error as? ClipboardHistoryModuleError,
                    .storageFailure
                )
            }
            try await module.closeStoreForTesting()
            let reopened = try ClipboardHistoryModule(
                testingDatabaseURL: fixture.url,
                databaseKey: fixture.key
            )
            let rows = try await reopened.page(ClipboardHistoryQuery())
            XCTAssertEqual(rows.entries, [])
            try await Self.assertSearchIntegrity(reopened)
        }

        for point in [
            ClipboardHistoryFaultPoint.searchUpdateAfterOldTrigram,
            .searchUpdateAfterOldShortGrams,
            .searchUpdateAfterField,
            .searchUpdateAfterNewTrigram,
            .searchUpdateAfterNewShortGrams,
        ] {
            let fixture = try SearchTemporaryDatabase()
            let module = try ClipboardHistoryModule(
                testingDatabaseURL: fixture.url,
                databaseKey: fixture.key
            )
            let entry = try await Self.capture(
                "old 搜索 value",
                in: module
            )
            let database = try await module.requiredDatabase()
            do {
                try await database.write { database in
                    try ClipboardHistoryModule.replaceSearchField(
                        entryID: entry.value.uuidString.lowercased(),
                        kind: "exactText",
                        index: 0,
                        value: "new 更新 value",
                        rankingGroup: 0,
                        in: database,
                        faultInjector: ClipboardHistoryFaultInjector(
                            points: [point]
                        )
                    )
                }
                XCTFail("Expected update fault at \(point)")
            } catch {}
            let oldResults = try await module.page(
                ClipboardHistoryQuery(text: "old 搜索")
            )
            XCTAssertEqual(oldResults.entries.map(\.id), [entry])
            let newResults = try await module.page(
                ClipboardHistoryQuery(text: "new 更新")
            )
            XCTAssertEqual(newResults.entries, [])
            try await Self.assertSearchIntegrity(module)
        }

        do {
            let fixture = try SearchTemporaryDatabase()
            let module = try ClipboardHistoryModule(
                testingDatabaseURL: fixture.url,
                databaseKey: fixture.key
            )
            let entry = try await Self.capture(
                "old committed 搜索",
                in: module
            )
            let database = try await module.requiredDatabase()
            try await database.write { database in
                try ClipboardHistoryModule.replaceSearchField(
                    entryID: entry.value.uuidString.lowercased(),
                    kind: "exactText",
                    index: 0,
                    value: "new committed 更新",
                    rankingGroup: 0,
                    in: database
                )
                try ClipboardHistoryModule.bumpSearchIndexGeneration(
                    in: database
                )
            }
            let oldResults = try await module.page(
                ClipboardHistoryQuery(text: "old 搜索")
            )
            let newResults = try await module.page(
                ClipboardHistoryQuery(text: "new 更新")
            )
            XCTAssertEqual(oldResults.entries, [])
            XCTAssertEqual(newResults.entries.map(\.id), [entry])
            try await Self.assertSearchIntegrity(module)
        }

        for point in [
            ClipboardHistoryFaultPoint.searchDeleteAfterTrigram,
            .searchDeleteAfterShortGrams,
        ] {
            let fixture = try SearchTemporaryDatabase()
            let writer = try ClipboardHistoryModule(
                testingDatabaseURL: fixture.url,
                databaseKey: fixture.key
            )
            let entry = try await Self.capture(
                "delete 删除 rollback",
                in: writer
            )
            try await writer.closeStoreForTesting()
            let deleting = try ClipboardHistoryModule(
                testingDatabaseURL: fixture.url,
                databaseKey: fixture.key,
                faultInjector: ClipboardHistoryFaultInjector(points: [point])
            )
            await deleting.awaitSearchIndexRebuildForTesting()
            do {
                _ = try await deleting.apply(.delete(entry))
                XCTFail("Expected delete fault at \(point)")
            } catch {}
            let results = try await deleting.page(
                ClipboardHistoryQuery(text: "delete 删除")
            )
            XCTAssertEqual(results.entries.map(\.id), [entry])
            try await Self.assertSearchIntegrity(deleting)
        }
    }

    private static func assertSearchIntegrity(
        _ module: ClipboardHistoryModule
    ) async throws {
        let database = try await module.requiredDatabase()
        let result = try await database.write {
            try ClipboardHistoryModule.searchIndexesPassIntegrityCheck(in: $0)
        }
        XCTAssertTrue(result)
    }

    private static func capture(
        _ value: String,
        in module: ClipboardHistoryModule
    ) async throws -> ClipboardHistoryEntryID {
        let entryID = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: .unknown,
                content: .text(value)
            )
        ).entryID
        await module.awaitSearchIndexRebuildForTesting()
        return entryID
    }

    @MainActor
    private static func captureMixedTextItems(
        _ values: [String],
        in module: ClipboardHistoryModule
    ) async throws -> ClipboardHistoryEntryID {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "dev.bybee.AnyDoor.search-tests.\(UUID().uuidString)"
            )
        )
        pasteboard.clearContents()
        let items = values.map { value in
            let item = NSPasteboardItem()
            item.setString(value, forType: .string)
            return item
        }
        guard pasteboard.writeObjects(items) else {
            throw ClipboardHistoryModuleError.storageFailure
        }
        let outcome = try await module.capture(
            ClipboardHistoryPasteboardCaptureRequest(pasteboard: pasteboard),
            source: .unknown
        )
        guard case .captured(let captured) = outcome else {
            throw ClipboardHistoryModuleError.storageFailure
        }
        return captured.entryID
    }

    /// `count` and `page` answer the same question through two separate
    /// statements, so they can drift apart silently. Every existing count test
    /// passes an empty query, which never reaches the search path at all.
    func testCountAgreesWithPagedResultsForTextQueries() async throws {
        let fixture = try SearchTemporaryDatabase()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        let values = [
            "swift actor isolation",
            "swift concurrency",
            "actor reentrancy",
            "clipboard history search",
            "SWIFT ACTOR",
            "剪贴板 swift",
            "unrelated entry",
        ]
        for value in values {
            _ = try await Self.capture(value, in: module)
        }

        for text in [
            "swift",
            "actor",
            "swift actor",
            "actor swift",
            "剪贴板",
            "sw",
            "s",
            "nothingmatchesthis",
        ] {
            let query = ClipboardHistoryQuery(text: text)
            let counted = try await module.count(query)
            var paged = 0
            var cursor: ClipboardHistoryCursor?
            repeat {
                let page = try await module.page(query, after: cursor)
                paged += page.entries.count
                cursor = page.nextCursor
            } while cursor != nil
            XCTAssertEqual(counted, paged, "count/page disagree for \(text)")
        }
    }

    /// The count path applies the same typed filters as the page path; a
    /// filtered count that ignored them would read as a plausible number.
    func testCountRespectsFiltersAlongsideTheTextQuery() async throws {
        let fixture = try SearchTemporaryDatabase()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        let favoriteID = try await Self.capture(
            "swift favorite entry",
            in: module
        )
        _ = try await Self.capture("swift plain entry", in: module)

        let query = ClipboardHistoryQuery(text: "swift")
        let unfiltered = try await module.count(query)
        XCTAssertEqual(unfiltered, 2)

        _ = try await module.apply(.setFavorite(favoriteID, true))
        var favoritesOnly = query
        favoritesOnly.favoritesOnly = true
        let filtered = try await module.count(favoritesOnly)
        XCTAssertEqual(filtered, 1)
        let page = try await module.page(favoritesOnly)
        XCTAssertEqual(page.entries.map(\.id), [favoriteID])
    }

    /// Ranking packs `matchClass * radix + rankingGroup` into one integer so
    /// SQL's `MIN` can pick a single winning field. A ranking group that
    /// reached the radix would carry into the match class and silently
    /// reorder results, so the bound is pinned rather than assumed.
    func testRankingGroupsStayBelowThePackingRadix() {
        let kinds = [
            "text", "ocr", "capturedPath", "currentPath", "qr", "url",
            "unrecognizedKindFromALaterBuild",
        ]
        for kind in kinds {
            let group = ClipboardHistoryModule.searchRankingGroup(for: kind)
            XCTAssertGreaterThanOrEqual(group, 0, kind)
            XCTAssertLessThan(
                group,
                ClipboardHistoryModule.rankingGroupRadix,
                kind
            )
        }
    }
}

private final class SearchTemporaryDatabase {
    let directory: URL
    let url: URL
    let key = Data(repeating: 0x84, count: 32)

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-ClipboardHistorySearchTests-\(UUID().uuidString)"
            )
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
