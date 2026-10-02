import AppKit
import Foundation
import GRDB
import os
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

    /// `prepareSearchIndexState` must not persist `indexing` for a healthy
    /// ready index. FTS integrity-check is an INSERT, so a `DatabasePool`
    /// reader cannot run it; a swallowed `SQLITE_READONLY` is not
    /// index-only corruption and must not change search state.
    func testPrepareSearchIndexStateLeavesAHealthyReadyIndexUntouched()
        async throws
    {
        let fixture = try SearchTemporaryDatabase()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        let entry = try await Self.capture(
            "healthy integrity searchable",
            in: module
        )
        let database = try await module.requiredDatabase()
        let generation = try await database.read {
            try ClipboardHistoryModule.searchIndexGeneration(in: $0)
        }
        try await Self.assertSearchIntegrity(module)

        try ClipboardHistoryModule.prepareSearchIndexState(in: database)

        let status = try await database.read {
            try ClipboardHistoryModule.searchIndexStatus(in: $0)
        }
        XCTAssertEqual(status, .ready)
        let page = try await module.page(
            ClipboardHistoryQuery(text: "integrity")
        )
        XCTAssertEqual(page.state, .ready)
        XCTAssertEqual(page.entries.map(\.id), [entry])
        let generationAfterPrepare = try await database.read {
            try ClipboardHistoryModule.searchIndexGeneration(in: $0)
        }
        XCTAssertEqual(generationAfterPrepare, generation)
        try await Self.assertSearchIntegrity(module)
    }

    /// Opening a healthy captured store must keep search ready. A reader
    /// integrity-check that maps `SQLITE_READONLY` to corruption would mark
    /// `indexing` and start a rebuild. Do not await that rebuild: waiting
    /// hides the false positive, and an index-generation bump is the
    /// race-free signal that one ran.
    func testReopeningAHealthyStoreKeepsSearchReadyWithoutRebuild()
        async throws
    {
        let fixture = try SearchTemporaryDatabase()
        let original = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        let entry = try await Self.capture(
            "healthy reopen searchable",
            in: original
        )
        let originalDatabase = try await original.requiredDatabase()
        let originalGeneration = try await originalDatabase.read {
            try ClipboardHistoryModule.searchIndexGeneration(in: $0)
        }
        let readyBeforeClose = try await original.page(
            ClipboardHistoryQuery(text: "reopen")
        )
        XCTAssertEqual(readyBeforeClose.state, .ready)
        XCTAssertEqual(readyBeforeClose.entries.map(\.id), [entry])
        try await original.closeStoreForTesting()

        let reopened = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        let status = await reopened.status()
        XCTAssertEqual(status.searchIndex, .ready)
        let page = try await reopened.page(
            ClipboardHistoryQuery(text: "reopen")
        )
        XCTAssertEqual(page.state, .ready)
        XCTAssertEqual(page.entries.map(\.id), [entry])
        let browsing = try await reopened.page(ClipboardHistoryQuery())
        XCTAssertEqual(browsing.entries.map(\.id), [entry])
        let reopenedDatabase = try await reopened.requiredDatabase()
        let reopenedGeneration = try await reopenedDatabase.read {
            try ClipboardHistoryModule.searchIndexGeneration(in: $0)
        }
        XCTAssertEqual(reopenedGeneration, originalGeneration)
        try await Self.assertSearchIntegrity(reopened)
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

    func testRebuildFailurePersistsAndTheNextOpenRetriesIt()
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

        // The cause is gone by the next launch, whose open retries the
        // rebuild without anyone asking.
        let reopened = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
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
        // With the automatic retries spent, opening leaves the index failed
        // and only the explicit retry below rebuilds it.
        try await Self.spendSearchRebuildRetries(of: fixture)

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

    /// Opens retry a failed rebuild, but only until
    /// `searchIndexRebuildFailureLimit` rebuilds have failed in a row: a
    /// cause that persists must not cost a full rebuild at every launch.
    /// After that only an explicit retry rebuilds the index.
    func testOpensRetryAFailedRebuildOnlyUpToTheFailureLimit()
        async throws
    {
        let fixture = try SearchTemporaryDatabase()
        let entry = try await Self.makeStoreNeedingASearchRebuild(
            "retry limit value",
            fixture: fixture
        )
        let limit = ClipboardHistoryModule.searchIndexRebuildFailureLimit
        let rebuilds = SearchRebuildFailures()
        // The first open rebuilds because the index is out of date, each
        // later one because the rebuild before it failed.
        for attempt in 1...limit {
            let status = try await Self.openAndClose(
                fixture,
                faultInjector: rebuilds.faultInjector
            )
            XCTAssertEqual(status, .failed(.rebuildFailed))
            XCTAssertEqual(rebuilds.count, attempt)
        }

        let spent = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key,
            faultInjector: rebuilds.faultInjector
        )
        await spent.awaitSearchIndexRebuildForTesting()
        XCTAssertEqual(rebuilds.count, limit)
        let failedSearch = try await spent.page(
            ClipboardHistoryQuery(text: "limit")
        )
        XCTAssertEqual(failedSearch.state, .failed(.rebuildFailed))
        let browsing = try await spent.page(ClipboardHistoryQuery())
        XCTAssertEqual(browsing.entries.map(\.id), [entry])
        try await spent.closeStoreForTesting()

        // Not even an open where the rebuild would succeed retries it.
        let retrying = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        await retrying.awaitSearchIndexRebuildForTesting()
        let stillFailed = await retrying.status()
        XCTAssertEqual(stillFailed.searchIndex, .failed(.rebuildFailed))
        let retryState = try await retrying.retrySearchIndex()
        XCTAssertEqual(retryState, .indexing)
        await retrying.awaitSearchIndexRebuildForTesting()
        let rebuilt = try await retrying.page(
            ClipboardHistoryQuery(text: "limit")
        )
        XCTAssertEqual(rebuilt.state, .ready)
        XCTAssertEqual(rebuilt.entries.map(\.id), [entry])
    }

    /// Publishing an index ends the run of failures, so a later run gets
    /// the whole budget again.
    func testAPublishedIndexRestartsTheRetryBudget() async throws {
        let fixture = try SearchTemporaryDatabase()
        _ = try await Self.makeStoreNeedingASearchRebuild(
            "published budget value",
            fixture: fixture
        )
        let limit = ClipboardHistoryModule.searchIndexRebuildFailureLimit
        let rebuilds = SearchRebuildFailures()
        for _ in 1..<limit {
            try await Self.openAndClose(
                fixture,
                faultInjector: rebuilds.faultInjector
            )
        }
        XCTAssertEqual(rebuilds.count, limit - 1)

        let recovered = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        await recovered.awaitSearchIndexRebuildForTesting()
        let ready = await recovered.status()
        XCTAssertEqual(ready.searchIndex, .ready)
        try await Self.markSearchIndexOutdated(in: recovered)
        try await recovered.closeStoreForTesting()

        for attempt in 1...limit {
            let status = try await Self.openAndClose(
                fixture,
                faultInjector: rebuilds.faultInjector
            )
            XCTAssertEqual(status, .failed(.rebuildFailed))
            XCTAssertEqual(rebuilds.count, limit - 1 + attempt)
        }
    }

    /// An explicit retry starts the run over too: when it fails as well,
    /// the opens that follow retry again.
    func testAnExplicitRetryRestartsTheRetryBudget() async throws {
        let fixture = try SearchTemporaryDatabase()
        _ = try await Self.makeStoreNeedingASearchRebuild(
            "explicit budget value",
            fixture: fixture
        )
        let limit = ClipboardHistoryModule.searchIndexRebuildFailureLimit
        let rebuilds = SearchRebuildFailures()
        for _ in 1...limit {
            try await Self.openAndClose(
                fixture,
                faultInjector: rebuilds.faultInjector
            )
        }

        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key,
            faultInjector: rebuilds.faultInjector
        )
        await module.awaitSearchIndexRebuildForTesting()
        XCTAssertEqual(rebuilds.count, limit)
        let retryState = try await module.retrySearchIndex()
        XCTAssertEqual(retryState, .indexing)
        await module.awaitSearchIndexRebuildForTesting()
        XCTAssertEqual(rebuilds.count, limit + 1)
        let failed = await module.status()
        XCTAssertEqual(failed.searchIndex, .failed(.rebuildFailed))
        try await module.closeStoreForTesting()

        let status = try await Self.openAndClose(
            fixture,
            faultInjector: rebuilds.faultInjector
        )
        XCTAssertEqual(status, .failed(.rebuildFailed))
        XCTAssertEqual(rebuilds.count, limit + 2)
    }

    /// The budget belongs to one app build. An update gets all of it again,
    /// since it may have fixed whatever made every rebuild fail.
    func testANewAppBuildGetsTheWholeRetryBudgetAgain() async throws {
        let fixture = try SearchTemporaryDatabase()
        let entry = try await Self.makeStoreNeedingASearchRebuild(
            "app build budget value",
            fixture: fixture
        )
        let limit = ClipboardHistoryModule.searchIndexRebuildFailureLimit
        let rebuilds = SearchRebuildFailures()
        let installed = "4.2.699"
        let unfixed = "4.2.799"
        let fixed = "4.2.899"
        for _ in 1...limit {
            try await Self.openAndClose(
                fixture,
                faultInjector: rebuilds.faultInjector,
                appBuild: installed
            )
        }
        // Spent for this build: opening it again rebuilds nothing.
        try await Self.openAndClose(
            fixture,
            faultInjector: rebuilds.faultInjector,
            appBuild: installed
        )
        XCTAssertEqual(rebuilds.count, limit)

        // An update that did not fix the cause spends a budget of its own.
        for attempt in 1...limit {
            let status = try await Self.openAndClose(
                fixture,
                faultInjector: rebuilds.faultInjector,
                appBuild: unfixed
            )
            XCTAssertEqual(status, .failed(.rebuildFailed))
            XCTAssertEqual(rebuilds.count, limit + attempt)
        }
        // Spent for this build: opening it again rebuilds nothing.
        try await Self.openAndClose(
            fixture,
            faultInjector: rebuilds.faultInjector,
            appBuild: unfixed
        )
        XCTAssertEqual(rebuilds.count, 2 * limit)

        // One that did recovers search on its first launch.
        let updated = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key,
            appBuild: fixed
        )
        await updated.awaitSearchIndexRebuildForTesting()
        let page = try await updated.page(
            ClipboardHistoryQuery(text: "budget")
        )
        XCTAssertEqual(page.state, .ready)
        XCTAssertEqual(page.entries.map(\.id), [entry])
    }

    /// Opens retry only a rebuild failure. An index marked failed with no
    /// reason, or one this build does not know, was marked by another build,
    /// and nothing says a rebuild clears it, so only an explicit retry
    /// rebuilds it.
    func testOpensLeaveAnIndexFailedForAnotherReasonUntilRetried()
        async throws
    {
        for reason in [nil, "unknownReason"] as [String?] {
            let fixture = try SearchTemporaryDatabase()
            let original = try ClipboardHistoryModule(
                testingDatabaseURL: fixture.url,
                databaseKey: fixture.key
            )
            let entry = try await Self.capture(
                "other reason value",
                in: original
            )
            let database = try await original.requiredDatabase()
            try await Self.markSearchIndexFailed(reason: reason, in: database)
            let generation = try await database.read {
                try ClipboardHistoryModule.searchIndexGeneration(in: $0)
            }
            try await original.closeStoreForTesting()

            let reopened = try ClipboardHistoryModule(
                testingDatabaseURL: fixture.url,
                databaseKey: fixture.key
            )
            await reopened.awaitSearchIndexRebuildForTesting()
            let status = await reopened.status()
            XCTAssertEqual(status.searchIndex, .failed(.stateUnavailable))
            let reopenedDatabase = try await reopened.requiredDatabase()
            let untouched = try await reopenedDatabase.read {
                try ClipboardHistoryModule.searchIndexGeneration(in: $0)
            }
            XCTAssertEqual(untouched, generation)

            let retryState = try await reopened.retrySearchIndex()
            XCTAssertEqual(retryState, .indexing)
            await reopened.awaitSearchIndexRebuildForTesting()
            let page = try await reopened.page(
                ClipboardHistoryQuery(text: "reason")
            )
            XCTAssertEqual(page.state, .ready)
            XCTAssertEqual(page.entries.map(\.id), [entry])
            try await reopened.closeStoreForTesting()
        }
    }

    /// Another process writing to the store while it opens costs search
    /// nothing. Deciding whether to rebuild only reads a healthy index, so
    /// it is not marked failed, and a retry the other writer keeps from
    /// starting is neither counted nor lost: the next open starts it.
    func testAnotherWriterDuringAnOpenNeitherFailsNorSpendsTheIndex()
        async throws
    {
        let fixture = try SearchTemporaryDatabase()
        let opened = try ClipboardHistoryModule.openDatabase(
            at: fixture.url,
            databaseKey: fixture.key
        )
        let other = try ClipboardHistoryModule.openDatabase(
            at: fixture.url,
            databaseKey: fixture.key
        )

        let readyRebuild = try Self.makeSearchIndexRebuildTask(
            for: opened,
            whileWritingOn: other
        )
        XCTAssertNil(readyRebuild)
        let ready = try await opened.read {
            try ClipboardHistoryModule.searchIndexStatus(in: $0)
        }
        XCTAssertEqual(ready, .ready)

        try await Self.markSearchIndexFailed(
            reason: "rebuildFailed",
            in: opened
        )
        let blockedRetry = try Self.makeSearchIndexRebuildTask(
            for: opened,
            whileWritingOn: other
        )
        XCTAssertNil(blockedRetry)
        let failed = try await opened.read {
            try ClipboardHistoryModule.searchIndexStatus(in: $0)
        }
        XCTAssertEqual(failed, .failed(.rebuildFailed))
        let failures = try await opened.read { database in
            try Int.fetchOne(
                database,
                sql: """
                    SELECT integer_value
                    FROM clipboard_maintenance_metadata
                    WHERE key = 'searchIndexRebuildFailures'
                    """
            )
        }
        XCTAssertNil(failures)

        let retry = ClipboardHistoryModule.makeSearchIndexRebuildTask(
            for: opened,
            faultInjector: ClipboardHistoryFaultInjector(),
            appBuild: ClipboardHistoryModule.unversionedAppBuild
        )
        let outcome = await retry?.value
        XCTAssertEqual(outcome, .ready)
        let rebuilt = try await opened.read {
            try ClipboardHistoryModule.searchIndexStatus(in: $0)
        }
        XCTAssertEqual(rebuilt, .ready)
    }

    /// A rebuild holds the writer for one long transaction. Writes issued on
    /// the module meanwhile must wait for it without parking the actor, or
    /// every history read queued behind them stalls until the rebuild
    /// commits. The derived-job scheduler's startup write is pending here
    /// too, since every open starts the scheduler.
    func testHistoryReadsStayServedWhileWritesWaitForAHeldRebuild()
        async throws
    {
        let fixture = try SearchTemporaryDatabase()
        let original = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        let existing = try await Self.capture("existing entry", in: original)
        let hold = SearchRebuildHold()
        defer { hold.release() }
        let module = try await Self.reopenWithHeldRebuild(
            original,
            fixture: fixture,
            hold: hold
        )

        // Bounded, so a module stuck behind the rebuild fails the test
        // instead of hanging it.
        let served = expectation(description: "served during the rebuild")
        // Named rather than `Self`: a `Self` reference makes the closure
        // capture the test case's dynamic type, which Swift 6.3's region
        // checker cannot analyze in the `sending` closure `Task.init` takes.
        // The other tasks in this file's nonisolated tests do the same.
        let whileHeld = Task {
            let capture = await ClipboardHistorySearchTests.startCapture(
                "captured during rebuild",
                on: module
            )
            let recent = try await module.page(ClipboardHistoryQuery())
            let textFacet = try await module.page(
                ClipboardHistoryQuery(facet: .text)
            )
            let search = try await module.page(
                ClipboardHistoryQuery(text: "existing")
            )
            served.fulfill()
            return (capture, recent, textFacet, search)
        }
        await fulfillment(of: [served], timeout: 10)
        hold.release()

        let (capture, recent, textFacet, search) = try await whileHeld.value
        XCTAssertEqual(recent.entries.map(\.id), [existing])
        XCTAssertEqual(textFacet.entries.map(\.id), [existing])
        XCTAssertEqual(search.state, .indexing)
        let captured = try await capture.value.entryID
        let afterRelease = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(afterRelease.entries.map(\.id), [captured, existing])
        let searched = try await module.page(
            ClipboardHistoryQuery(text: "during rebuild")
        )
        XCTAssertEqual(searched.state, .ready)
        XCTAssertEqual(searched.entries.map(\.id), [captured])
        try await Self.assertSearchIntegrity(module)
    }

    /// Everything waiting on a task resumes in no particular order once it
    /// finishes, so writes that queue up behind a rebuild need an explicit
    /// order to still commit in the order they were issued. The favorite and
    /// tag writes whose order is checked here write synchronously within
    /// their turn; the edit's asynchronous write may still be overtaken by
    /// the writes after it, which the independent text column tolerates.
    func testWritesQueuedBehindAHeldRebuildCommitInArrivalOrder()
        async throws
    {
        let fixture = try SearchTemporaryDatabase()
        let original = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        let entry = try await Self.capture("original text", in: original)
        _ = try await original.replaceTagDefinitions(with: ["first", "second"])
        let hold = SearchRebuildHold()
        defer { hold.release() }
        let module = try await Self.reopenWithHeldRebuild(
            original,
            fixture: fixture,
            hold: hold
        )

        let queued = expectation(description: "queued during the rebuild")
        let whileHeld = Task {
            let mutations = await ClipboardHistorySearchTests.startMutations(
                [
                    .editText(entry, "edited text"),
                    .setFavorite(entry, true),
                    .setTags(entry, ["first"]),
                    .setFavorite(entry, false),
                    .setTags(entry, ["second"]),
                    .setFavorite(entry, true),
                    .setTags(entry, ["first", "second"]),
                    .setFavorite(entry, false),
                ],
                on: module
            )
            // Served after the mutations reached the module, so all of
            // them are waiting behind the rebuild when it is released.
            let page = try await module.page(ClipboardHistoryQuery())
            queued.fulfill()
            return (mutations, page)
        }
        await fulfillment(of: [queued], timeout: 10)
        hold.release()

        let (mutations, page) = try await whileHeld.value
        XCTAssertEqual(page.entries.map(\.previewText), ["original text"])
        for mutation in mutations {
            _ = try await mutation.value
        }
        let settled = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(settled.entries.map(\.id), [entry])
        XCTAssertEqual(settled.entries.map(\.previewText), ["edited text"])
        XCTAssertEqual(settled.entries.map(\.isFavorite), [false])
        XCTAssertEqual(settled.entries.map(\.tagIDs), [["first", "second"]])
    }

    /// A passive capture that passed its entry check before a clear began,
    /// but only gets its write turn once the clear is under way, holds
    /// pasteboard content the clear is discarding, so it must not land
    /// afterwards.
    @MainActor
    func testPassiveCaptureQueuedBehindAClearDuringARebuildIsDropped()
        async throws
    {
        let fixture = try SearchTemporaryDatabase()
        let original = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        _ = try await Self.capture("cleared entry", in: original)
        let hold = SearchRebuildHold()
        defer { hold.release() }
        let module = try await Self.reopenWithHeldRebuild(
            original,
            fixture: fixture,
            hold: hold
        )
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "dev.bybee.AnyDoor.search-tests.\(UUID().uuidString)"
            )
        )
        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.setString("copied before the clear", forType: .string)
        )
        let request = ClipboardHistoryPasteboardCaptureRequest(
            pasteboard: pasteboard
        )

        let queued = expectation(description: "queued during the rebuild")
        let whileHeld = Task {
            let preview = try await module.previewClearHistory(
                scope: .includingProtected
            )
            let started = await Self.startClearThenCapture(
                preview.token,
                request,
                on: module
            )
            // Served after both reached the module, so the capture already
            // passed its entry check when the rebuild is released.
            _ = try await module.page(ClipboardHistoryQuery())
            queued.fulfill()
            return (preview.affectedCount, started)
        }
        await fulfillment(of: [queued], timeout: 10)
        hold.release()

        let (affectedCount, (confirmation, capture)) = try await whileHeld
            .value
        XCTAssertEqual(affectedCount, 1)
        let cleared = try await confirmation.value
        XCTAssertEqual(cleared, .applied(deletedCount: 1))
        let captured = try await capture.value
        XCTAssertEqual(captured, .skipped(.generationChanged))
        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries, [])
    }

    /// A reset deletes the store and opens a new one, so a write still
    /// waiting for its turn behind a rebuild when the reset began belongs to
    /// the discarded history and must stay out of the new store. Whether the
    /// reset or the capture resumes first once the rebuild finishes is up to
    /// the runtime: the capture either lands in the old store just before it
    /// is deleted, or is refused once the new store is open.
    func testExplicitCaptureQueuedBeforeAResetStaysOutOfTheNewStore()
        async throws
    {
        let fixture = try SearchTemporaryDatabase()
        let hold = SearchRebuildHold()
        defer { hold.release() }
        let module = try await Self.makeResettableModuleWithHeldRebuild(
            fixture: fixture,
            hold: hold
        )

        let queued = expectation(description: "queued during the rebuild")
        let whileHeld = Task {
            let started =
                await ClipboardHistorySearchTests.startCaptureThenReset(
                    "captured before the reset",
                    on: module
                )
            // Served after both reached the module, so the capture is
            // already waiting for its turn when the rebuild is released.
            _ = try await module.page(ClipboardHistoryQuery())
            queued.fulfill()
            return started
        }
        await fulfillment(of: [queued], timeout: 10)
        hold.release()

        let (capture, reset) = try await whileHeld.value
        try await reset.value
        do {
            _ = try await capture.value
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryModuleError,
                .storeUnavailable
            )
        }
        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries, [])
    }

    /// A passive capture that arrives while a reset waits for the rebuild
    /// read the pasteboard before the reset discarded the history, so it
    /// must stay out of the new store too, whichever of the two resumes
    /// first.
    @MainActor
    func testPassiveCaptureArrivingDuringAResetStaysOutOfTheNewStore()
        async throws
    {
        let fixture = try SearchTemporaryDatabase()
        let hold = SearchRebuildHold()
        defer { hold.release() }
        let module = try await Self.makeResettableModuleWithHeldRebuild(
            fixture: fixture,
            hold: hold
        )
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "dev.bybee.AnyDoor.search-tests.\(UUID().uuidString)"
            )
        )
        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.setString("copied before the reset", forType: .string)
        )
        let request = ClipboardHistoryPasteboardCaptureRequest(
            pasteboard: pasteboard
        )

        let queued = expectation(description: "queued during the rebuild")
        let whileHeld = Task {
            let started = await Self.startResetThenCapture(
                request,
                on: module
            )
            // Served after both reached the module, so the capture is
            // already waiting for its turn when the rebuild is released.
            _ = try await module.page(ClipboardHistoryQuery())
            queued.fulfill()
            return started
        }
        await fulfillment(of: [queued], timeout: 10)
        hold.release()

        let (reset, capture) = try await whileHeld.value
        try await reset.value
        let outcome = try await capture.value
        switch outcome {
        case .captured, .skipped(.generationChanged):
            break
        case .skipped:
            XCTFail("Unexpected capture outcome \(outcome)")
        }
        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries, [])
    }

    /// Previewing a file entry that also stored an image answers with the
    /// stored thumbnail and writes nothing, so unlike resolving the entry's
    /// file references it is served while a rebuild holds the writer.
    @MainActor
    func testThumbnailPreviewOfAFileEntryIsServedDuringAHeldRebuild()
        async throws
    {
        let fixture = try SearchTemporaryDatabase()
        let original = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        let png = try Self.makePNG()
        let fileURL = fixture.directory.appendingPathComponent("image.png")
        try png.write(to: fileURL)
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "dev.bybee.AnyDoor.search-tests.\(UUID().uuidString)"
            )
        )
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(fileURL.absoluteString, forType: .fileURL)
        item.setData(png, forType: .png)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let outcome = try await original.capture(
            ClipboardHistoryPasteboardCaptureRequest(pasteboard: pasteboard),
            source: .unknown
        )
        guard case .captured(let captured) = outcome else {
            return XCTFail("Expected the file and its image to be captured")
        }
        let stored = try await original.page(ClipboardHistoryQuery())
        XCTAssertEqual(
            stored.entries.first?.facets.isSuperset(of: [.file, .image]),
            true
        )
        let hold = SearchRebuildHold()
        defer { hold.release() }
        let module = try await Self.reopenWithHeldRebuild(
            original,
            fixture: fixture,
            hold: hold
        )

        let served = expectation(description: "served during the rebuild")
        let whileHeld = Task {
            let preview = try await module.materialize(
                ClipboardHistoryMaterializationRequest(
                    entryID: captured.entryID,
                    purpose: .preview
                )
            )
            served.fulfill()
            return preview
        }
        await fulfillment(of: [served], timeout: 10)
        hold.release()

        let preview = try await whileHeld.value
        XCTAssertEqual(preview.items.count, 1)
        guard
            case .data(let typeIdentifier, let thumbnail) =
                preview.items.first?.representations.first
        else {
            return XCTFail("Expected the stored thumbnail")
        }
        XCTAssertEqual(typeIdentifier, "public.png")
        XCTAssertFalse(thumbnail.isEmpty)
        await module.awaitDerivedJobsForTesting()
    }

    /// Stopping the maintenance loop cancels it and then waits for it, so a
    /// pass cancelled while it waits for its write turn behind a rebuild must
    /// not start once the rebuild finishes.
    func testMaintenanceCancelledBehindAHeldRebuildDoesNotRun()
        async throws
    {
        let fixture = try SearchTemporaryDatabase()
        let original = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        _ = try await Self.capture("existing entry", in: original)
        let hold = SearchRebuildHold()
        defer { hold.release() }
        let module = try await Self.reopenWithHeldRebuild(
            original,
            fixture: fixture,
            hold: hold
        )
        let before = try await Self.lastMaintenanceSuccess(in: module)

        let queued = expectation(description: "queued during the rebuild")
        let whileHeld = Task {
            let maintenance =
                await ClipboardHistorySearchTests.startMaintenance(on: module)
            // Served after the pass reached the module, so it is already
            // waiting for its turn when it is cancelled.
            _ = try await module.page(ClipboardHistoryQuery())
            queued.fulfill()
            return maintenance
        }
        await fulfillment(of: [queued], timeout: 10)
        let maintenance = try await whileHeld.value
        maintenance.cancel()
        hold.release()

        do {
            _ = try await maintenance.value
            XCTFail("A cancelled maintenance pass must not run")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let after = try await Self.lastMaintenanceSuccess(in: module)
        XCTAssertEqual(after, before)
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

    /// Closes `original` with its search index marked stale and reopens the
    /// store, returning once the rebuild that triggers is held open.
    private static func reopenWithHeldRebuild(
        _ original: ClipboardHistoryModule,
        fixture: SearchTemporaryDatabase,
        hold: SearchRebuildHold
    ) async throws -> ClipboardHistoryModule {
        let database = try await original.requiredDatabase()
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
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key,
            faultInjector: hold.faultInjector
        )
        await hold.waitUntilReached()
        return module
    }

    /// A module over a store it can reset, holding one entry, returned once
    /// a search index rebuild it started is held open.
    private static func makeResettableModuleWithHeldRebuild(
        fixture: SearchTemporaryDatabase,
        hold: SearchRebuildHold
    ) async throws -> ClipboardHistoryModule {
        let module = ClipboardHistoryModule(
            testingStoreRoot: fixture.directory,
            keyStore: SearchMasterKeyStore(),
            faultInjector: hold.faultInjector
        )
        _ = try await capture("entry before the reset", in: module)
        // The scheduler that capture started must be done. One still waiting
        // for a write turn would make the reset wait for it too, and a
        // capture queued behind it would then always go before the reset.
        await module.awaitDerivedJobsForTesting()
        let database = try await module.requiredDatabase()
        try await database.write { database in
            try database.execute(
                sql: """
                    UPDATE clipboard_maintenance_metadata
                    SET text_value = 'failed'
                    WHERE key = 'searchIndexState'
                    """
            )
        }
        let state = try await module.retrySearchIndex()
        XCTAssertEqual(state, .indexing)
        await hold.waitUntilReached()
        return module
    }

    /// A store holding one entry with `text`, whose search index the next
    /// open rebuilds.
    private static func makeStoreNeedingASearchRebuild(
        _ text: String,
        fixture: SearchTemporaryDatabase
    ) async throws -> ClipboardHistoryEntryID {
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )
        let entry = try await capture(text, in: module)
        try await markSearchIndexOutdated(in: module)
        try await module.closeStoreForTesting()
        return entry
    }

    /// Marks the search index an older version, which the next open
    /// rebuilds.
    private static func markSearchIndexOutdated(
        in module: ClipboardHistoryModule
    ) async throws {
        let database = try await module.requiredDatabase()
        try await database.write { database in
            try database.execute(
                sql: """
                    UPDATE clipboard_maintenance_metadata
                    SET integer_value = 0
                    WHERE key = 'searchIndexVersion'
                    """
            )
        }
    }

    /// Opens the store, waits for any search index rebuild the open started,
    /// and closes it again. Returns the search index status it left.
    @discardableResult
    private static func openAndClose(
        _ fixture: SearchTemporaryDatabase,
        faultInjector: ClipboardHistoryFaultInjector =
            ClipboardHistoryFaultInjector(),
        appBuild: String = ClipboardHistoryModule.unversionedAppBuild
    ) async throws -> ClipboardHistorySearchIndexStatus? {
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key,
            faultInjector: faultInjector,
            appBuild: appBuild
        )
        await module.awaitSearchIndexRebuildForTesting()
        let status = await module.status()
        try await module.closeStoreForTesting()
        return status.searchIndex
    }

    /// Marks the search index failed, for `reason` or for none.
    private static func markSearchIndexFailed(
        reason: String?,
        in database: DatabasePool
    ) async throws {
        try await database.write { database in
            try database.execute(
                sql: """
                    UPDATE clipboard_maintenance_metadata
                    SET text_value = 'failed'
                    WHERE key = 'searchIndexState'
                    """
            )
            try database.execute(
                sql: """
                    DELETE FROM clipboard_maintenance_metadata
                    WHERE key = 'searchIndexFailure'
                    """
            )
            if let reason {
                try database.execute(
                    sql: """
                        INSERT INTO clipboard_maintenance_metadata(
                            key,
                            text_value
                        ) VALUES ('searchIndexFailure', ?)
                        """,
                    arguments: [reason]
                )
            }
        }
    }

    /// What opening `database` starts for its search index while `other`,
    /// a second connection to the same store as another process would hold,
    /// keeps a write transaction open.
    private static func makeSearchIndexRebuildTask(
        for database: DatabasePool,
        whileWritingOn other: DatabasePool
    ) throws
        -> Task<ClipboardHistoryModule.SearchIndexRebuildOutcome, Never>?
    {
        let writing = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? other.write { _ in
                writing.signal()
                release.wait()
            }
            finished.signal()
        }
        defer {
            release.signal()
            _ = finished.wait(timeout: .now() + 10)
        }
        // Bounded, so a writer that never starts fails the test instead of
        // hanging it.
        guard writing.wait(timeout: .now() + 10) == .success else {
            throw ClipboardHistoryModuleError.storageFailure
        }
        return ClipboardHistoryModule.makeSearchIndexRebuildTask(
            for: database,
            faultInjector: ClipboardHistoryFaultInjector(),
            appBuild: ClipboardHistoryModule.unversionedAppBuild
        )
    }

    /// Opens the store with every rebuild failing until no open retries
    /// one any more.
    private static func spendSearchRebuildRetries(
        of fixture: SearchTemporaryDatabase
    ) async throws {
        let failing = ClipboardHistoryFaultInjector(
            points: [.searchRebuildBeforePublish]
        )
        for _ in 0..<ClipboardHistoryModule.searchIndexRebuildFailureLimit {
            try await openAndClose(fixture, faultInjector: failing)
        }
    }

    private static func lastMaintenanceSuccess(
        in module: ClipboardHistoryModule
    ) async throws -> Double? {
        let database = try await module.requiredDatabase()
        return try await database.read { database in
            try Double.fetchOne(
                database,
                sql: """
                    SELECT real_value
                    FROM clipboard_maintenance_metadata
                    WHERE key = 'lastMaintenanceSucceededAt'
                    """
            )
        }
    }

    private static func makePNG() throws -> Data {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 16,
                pixelsHigh: 16,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw ClipboardHistoryModuleError.storageFailure
        }
        return png
    }

    // A task created on an actor is enqueued there as it is created, so the
    // operations started below reach the module in order, and ahead of
    // anything the caller asks the module afterwards.

    private static func startCapture(
        _ value: String,
        on module: isolated ClipboardHistoryModule
    ) -> Task<ClipboardHistoryCaptureOutcome, Error> {
        Task {
            try await module.capture(
                ClipboardHistoryCaptureRequest(
                    source: .unknown,
                    content: .text(value)
                )
            )
        }
    }

    private static func startMutations(
        _ mutations: [ClipboardHistoryMutation],
        on module: isolated ClipboardHistoryModule
    ) -> [Task<ClipboardHistoryMutationOutcome, Error>] {
        mutations.map { mutation in
            Task { try await module.apply(mutation) }
        }
    }

    private static func startMaintenance(
        on module: isolated ClipboardHistoryModule
    ) -> Task<ClipboardHistoryMaintenanceReport, Error> {
        Task { try await module.performMaintenance() }
    }

    private static func startClearThenCapture(
        _ token: ClipboardHistoryConfirmationToken,
        _ request: ClipboardHistoryPasteboardCaptureRequest,
        on module: isolated ClipboardHistoryModule
    ) -> (
        confirmation: Task<ClipboardHistoryDestructiveApplyOutcome, Error>,
        capture: Task<ClipboardHistoryPasteboardCaptureOutcome, Error>
    ) {
        let confirmation = Task { try await module.confirm(token) }
        let capture = Task {
            try await module.capture(request, source: .unknown)
        }
        return (confirmation, capture)
    }

    private static func startCaptureThenReset(
        _ value: String,
        on module: isolated ClipboardHistoryModule
    ) -> (
        capture: Task<ClipboardHistoryCaptureOutcome, Error>,
        reset: Task<Void, Error>
    ) {
        let capture = startCapture(value, on: module)
        let reset = Task { try await module.reset(confirmation: .confirmed) }
        return (capture, reset)
    }

    private static func startResetThenCapture(
        _ request: ClipboardHistoryPasteboardCaptureRequest,
        on module: isolated ClipboardHistoryModule
    ) -> (
        reset: Task<Void, Error>,
        capture: Task<ClipboardHistoryPasteboardCaptureOutcome, Error>
    ) {
        let reset = Task { try await module.reset(confirmation: .confirmed) }
        let capture = Task {
            try await module.capture(request, source: .unknown)
        }
        return (reset, capture)
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

/// Holds a search index rebuild open inside its write transaction, just
/// before it publishes, until the test releases it.
private final class SearchRebuildHold: Sendable {
    private let reached: AsyncStream<Void>
    private let reachedContinuation: AsyncStream<Void>.Continuation
    private let gate = DispatchSemaphore(value: 0)

    init() {
        (reached, reachedContinuation) = AsyncStream.makeStream()
    }

    /// Runs on the rebuild's thread, which it blocks until `release()`.
    var faultInjector: ClipboardHistoryFaultInjector {
        ClipboardHistoryFaultInjector { [self] point in
            if point == .searchRebuildBeforePublish {
                reachedContinuation.yield()
                gate.wait()
            }
            return false
        }
    }

    func waitUntilReached() async {
        for await _ in reached {
            return
        }
    }

    func release() {
        gate.signal()
    }
}

/// Fails every search index rebuild just before it publishes, and counts
/// the rebuilds that got that far.
private final class SearchRebuildFailures: Sendable {
    private let attempts = OSAllocatedUnfairLock(initialState: 0)

    var count: Int {
        attempts.withLock { $0 }
    }

    /// Runs on the rebuild's thread.
    var faultInjector: ClipboardHistoryFaultInjector {
        ClipboardHistoryFaultInjector { [attempts] point in
            guard point == .searchRebuildBeforePublish else {
                return false
            }
            attempts.withLock { $0 += 1 }
            return true
        }
    }
}

/// An in-memory master key: a reset's delete reports it gone, and the store
/// the reset opens next reuses it.
private struct SearchMasterKeyStore: ClipboardHistoryMasterKeyStoring {
    let key = Data(repeating: 0x85, count: 32)

    func load() -> ClipboardHistoryMasterKeyResult {
        .key(key)
    }

    func create() -> ClipboardHistoryMasterKeyResult {
        .key(key)
    }

    func delete() -> ClipboardHistoryMasterKeyResult {
        .missing
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
