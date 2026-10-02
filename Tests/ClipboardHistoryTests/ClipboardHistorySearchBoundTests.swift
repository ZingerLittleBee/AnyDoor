import AppKit
import Foundation
import GRDB
import XCTest
import ClipboardHistoryTestSupport

@testable import ClipboardHistory

/// Pins the search field bound (ADR-0021, amendment of 2026-10-01). A search
/// field stores and indexes at most `searchFieldByteLimit` UTF-8 bytes of its
/// value and of its normalized value, so a long text is searchable by its
/// beginning only, while the entry's representations, and so its preview and
/// paste, stay whole. Also pins search index version 2: the one-time upgrade
/// that brings a history indexed by version 1 under the bound.
final class ClipboardHistorySearchBoundTests: XCTestCase {
    private static let limit = ClipboardHistoryModule.searchFieldByteLimit
    /// The search index version the bound arrived with. Its in-place stamp
    /// only ever upgrades version 1, so these tests name it outright.
    private static let upgradedVersion = 2
    private static let plainTextType =
        NSPasteboard.PasteboardType.string.rawValue

    // MARK: Bounding

    func testBoundingCutsUTF8BytesOnUnicodeScalarBoundaries() {
        let limit = Self.limit
        func bound(_ value: String) -> (value: String, normalizedValue: String) {
            ClipboardHistoryModule.boundedSearchField(value)
        }

        // Within the bound, raw and normalized, nothing is cut.
        let short = bound("Short Value")
        XCTAssertEqual(short.value, "Short Value")
        XCTAssertEqual(short.normalizedValue, "short value")
        let exact = String(repeating: "x", count: limit)
        XCTAssertEqual(bound(exact).value, exact)
        XCTAssertEqual(bound(exact).normalizedValue, exact)

        // Latin: one byte per scalar, so the cut lands on the limit.
        let latin = bound(String(repeating: "x", count: limit + 1))
        XCTAssertEqual(latin.value, exact)
        XCTAssertEqual(latin.normalizedValue, exact)

        // CJK: three bytes per scalar, cut back to the last whole one.
        let cjk = bound(String(repeating: "剪", count: limit / 3 + 1))
        XCTAssertEqual(cjk.value, String(repeating: "剪", count: limit / 3))
        XCTAssertEqual(cjk.value.utf8.count, limit - 1)
        XCTAssertEqual(cjk.normalizedValue, cjk.value)

        // Emoji: four bytes per scalar.
        let emoji = bound("a" + String(repeating: "🚀", count: limit / 4))
        XCTAssertEqual(
            emoji.value,
            "a" + String(repeating: "🚀", count: limit / 4 - 1)
        )
        XCTAssertEqual(emoji.value.utf8.count, limit - 3)
        XCTAssertEqual(emoji.normalizedValue, emoji.value)

        // Combining marks: the whole value is one grapheme cluster, so the
        // only boundaries near the limit are scalar ones. Folding then drops
        // the marks from the normalized value.
        let stacked = "a" + String(repeating: "\u{301}", count: limit)
        XCTAssertEqual(stacked.count, 1)
        let marks = bound(stacked)
        XCTAssertEqual(marks.value.utf8.count, limit - 1)
        XCTAssertTrue(
            stacked.unicodeScalars.starts(with: marks.value.unicodeScalars)
        )
        XCTAssertEqual(marks.normalizedValue, "a")

        // Korean: a syllable decomposes into three jamo, tripling its bytes,
        // so a value within the bound can normalize past it.
        let korean = String(repeating: "한", count: 10_000)
        let normalizedKorean = ClipboardHistoryModule.normalizeSearchText(
            korean
        )
        XCTAssertLessThan(korean.utf8.count, limit)
        XCTAssertGreaterThan(normalizedKorean.utf8.count, limit)
        let decomposed = bound(korean)
        XCTAssertEqual(decomposed.value, korean)
        XCTAssertEqual(decomposed.normalizedValue.utf8.count, limit - 1)
        XCTAssertTrue(
            normalizedKorean.unicodeScalars.starts(
                with: decomposed.normalizedValue.unicodeScalars
            )
        )
        let longKorean = bound(
            String(repeating: "한", count: limit / 3 + 1)
        )
        XCTAssertEqual(
            longKorean.value,
            String(repeating: "한", count: limit / 3)
        )
        XCTAssertEqual(longKorean.normalizedValue.utf8.count, limit - 1)

        // A ligature that decomposes into eighteen scalars: normalization
        // expands a small value far past the bound.
        let ligatures = String(repeating: "\u{FDFA}", count: 3_000)
        let normalizedLigatures = ClipboardHistoryModule.normalizeSearchText(
            ligatures
        )
        XCTAssertGreaterThan(normalizedLigatures.utf8.count, limit)
        let expanded = bound(ligatures)
        XCTAssertEqual(expanded.value, ligatures)
        XCTAssertLessThanOrEqual(expanded.normalizedValue.utf8.count, limit)
        XCTAssertGreaterThan(expanded.normalizedValue.utf8.count, limit - 4)
        XCTAssertTrue(
            normalizedLigatures.unicodeScalars.starts(
                with: expanded.normalizedValue.unicodeScalars
            )
        )
    }

    // MARK: Write paths

    func testALongTextIsSearchableByItsBeginningWhilePasteReturnsItWhole()
        async throws
    {
        let fixture = try SearchBoundTemporaryDatabase(in: self)
        let module = try fixture.open()
        let text = Self.longText(head: "zqxheadmarker", tail: "zqxtailmarker")
        let entry = try await Self.capture(text, in: module)

        try await Self.assertSearch("zqxheadmarker", in: module, finds: [entry])
        try await Self.assertSearch("zqxtailmarker", in: module, finds: [])
        for purpose in [
            ClipboardHistoryMaterializationPurpose.normalPaste,
            .plainTextPaste,
            .preview,
            .fullPreview,
        ] {
            let materialized = try await module.materialize(
                ClipboardHistoryMaterializationRequest(
                    entryID: entry,
                    purpose: purpose
                )
            )
            XCTAssertTrue(
                materialized.items.map(\.representations)
                    == [[.text(typeIdentifier: Self.plainTextType, value: text)]],
                "\(purpose) must return the whole text"
            )
        }
        let fields = try await Self.storedSearchFields(of: entry, in: module)
        XCTAssertEqual(fields, [Self.boundedField("exactText")])
        try await Self.assertSearchIndexesAreConsistent(in: module)
    }

    func testEditingAnEntryToALongTextBoundsItsSearchField() async throws {
        let fixture = try SearchBoundTemporaryDatabase(in: self)
        let module = try fixture.open()
        let entry = try await Self.capture("short zqxoriginal text", in: module)
        let edited = Self.longText(head: "zqxeditedhead", tail: "zqxeditedtail")
        guard case .updated = try await module.apply(.editText(entry, edited))
        else {
            return XCTFail("Expected the edit to update the entry")
        }

        try await Self.assertSearch("zqxeditedhead", in: module, finds: [entry])
        try await Self.assertSearch("zqxeditedtail", in: module, finds: [])
        try await Self.assertSearch("zqxoriginal", in: module, finds: [])
        let pasted = try await module.materialize(
            ClipboardHistoryMaterializationRequest(
                entryID: entry,
                purpose: .normalPaste
            )
        )
        XCTAssertTrue(
            pasted.items.map(\.representations)
                == [[.text(typeIdentifier: Self.plainTextType, value: edited)]],
            "paste must return the whole edited text"
        )
        let fields = try await Self.storedSearchFields(of: entry, in: module)
        XCTAssertEqual(fields, [Self.boundedField("exactText")])
        try await Self.assertSearchIndexesAreConsistent(in: module)
    }

    /// Text recognized in an image lives only in its search fields, so the
    /// bound applies to it as to copied text: explicit OCR and QR captures,
    /// and values the derived jobs recognize in a captured bitmap.
    func testRecognizedTextIsBoundedLikeCopiedText() async throws {
        let fixture = try SearchBoundTemporaryDatabase(in: self)
        let recognizer = SearchBoundVisionRecognizer(
            results: [
                .ocr: [Self.longText(head: "zqxdocrhead", tail: "zqxdocrtail")],
                .qr: [Self.longText(head: "zqxdqrhead", tail: "zqxdqrtail")],
            ]
        )
        let module = try fixture.open(visionRecognizer: recognizer)
        let recognized = Self.longText(head: "zqxocrhead", tail: "zqxocrtail")
        let ocr = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: .anyDoor,
                content: .ocr(recognized)
            )
        ).entryID
        let qr = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: .anyDoor,
                content: .qrCode(
                    Self.longText(head: "zqxqrhead", tail: "zqxqrtail")
                )
            )
        ).entryID
        try await module.setAutomaticImageTextIndexingEnabled(true)
        let image = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: .unknown,
                content: .bitmap(try Self.makePNG(), provenance: .image)
            )
        ).entryID
        await module.awaitDerivedJobsForTesting()

        let ocrFields = try await Self.storedSearchFields(of: ocr, in: module)
        XCTAssertEqual(ocrFields, [Self.boundedField("ocr")])
        let qrFields = try await Self.storedSearchFields(of: qr, in: module)
        XCTAssertEqual(qrFields, [Self.boundedField("qr")])
        let imageFields = try await Self.storedSearchFields(
            of: image,
            in: module
        )
        XCTAssertEqual(
            imageFields,
            [Self.boundedField("ocr"), Self.boundedField("qr")]
        )
        for (head, tail, entry) in [
            ("zqxocrhead", "zqxocrtail", ocr),
            ("zqxqrhead", "zqxqrtail", qr),
            ("zqxdocrhead", "zqxdocrtail", image),
            ("zqxdqrhead", "zqxdqrtail", image),
        ] {
            try await Self.assertSearch(head, in: module, finds: [entry])
            try await Self.assertSearch(tail, in: module, finds: [])
        }
        let pasted = try await module.materialize(
            ClipboardHistoryMaterializationRequest(
                entryID: ocr,
                purpose: .normalPaste
            )
        )
        XCTAssertTrue(
            pasted.items.map(\.representations)
                == [[
                    .text(typeIdentifier: Self.plainTextType, value: recognized)
                ]],
            "paste must return the whole recognized text"
        )
        try await Self.assertSearchIndexesAreConsistent(in: module)
    }

    /// One copy carrying plain text, HTML and RTF becomes three search
    /// fields, the rich ones derived from their documents. Each is bounded
    /// on its own, and the representations stay whole.
    func testARichTextCopyBoundsEachOfItsSearchFields() async throws {
        let fixture = try SearchBoundTemporaryDatabase(in: self)
        let module = try fixture.open()
        let plain = Self.longText(head: "zqxplainhead", tail: "zqxplaintail")
        let html = Data(
            (
                "<p>"
                    + Self.longText(head: "zqxhtmlhead", tail: "zqxhtmltail")
                    + "</p>"
            ).utf8
        )
        let rtf = try Self.rtfData(
            Self.longText(head: "zqxrtfhead", tail: "zqxrtftail")
        )
        let entry = try await Self.capturePasteboardItems(
            [[.string: Data(plain.utf8), .html: html, .rtf: rtf]],
            in: module
        )

        let fields = try await Self.storedSearchFields(of: entry, in: module)
        XCTAssertEqual(
            fields,
            [
                Self.boundedField("exactText"),
                Self.boundedField("richText"),
                Self.boundedField("richText"),
            ]
        )
        for (head, tail) in [
            ("zqxplainhead", "zqxplaintail"),
            ("zqxhtmlhead", "zqxhtmltail"),
            ("zqxrtfhead", "zqxrtftail"),
        ] {
            try await Self.assertSearch(head, in: module, finds: [entry])
            try await Self.assertSearch(tail, in: module, finds: [])
        }
        let pasted = try await module.materialize(
            ClipboardHistoryMaterializationRequest(
                entryID: entry,
                purpose: .normalPaste
            )
        )
        XCTAssertTrue(
            pasted.items.map(\.representations)
                == [[
                    .text(typeIdentifier: Self.plainTextType, value: plain),
                    .data(
                        typeIdentifier:
                            NSPasteboard.PasteboardType.rtf.rawValue,
                        rtf
                    ),
                    .data(
                        typeIdentifier:
                            NSPasteboard.PasteboardType.html.rawValue,
                        html
                    ),
                ]],
            "paste must return every representation whole"
        )
        try await Self.assertSearchIndexesAreConsistent(in: module)
    }

    /// The regression the bound fixes: version 1 indexed whole texts, so a
    /// 2 MB copy grew the store by more than four times its size. Bounded,
    /// it costs about its own size plus the 64 KB fields and their index
    /// entries.
    func testALargeTextGrowsStorageByLittleMoreThanItsOwnSize() async throws {
        let fixture = try SearchBoundTemporaryDatabase(in: self)
        let module = try fixture.open()
        await module.awaitDerivedJobsForTesting()
        _ = try await module.performMaintenance(orphanGracePeriod: 0)
        let baseline = try await module.storageUsage()
        let text = String(
            repeating: "lorem ipsum dolor sit amet ",
            count: 80_000
        )
        _ = try await Self.capture(text, in: module)
        await module.awaitDerivedJobsForTesting()
        _ = try await module.performMaintenance(orphanGracePeriod: 0)
        let usage = try await module.storageUsage()
        let grown = Double(usage) - Double(baseline)

        XCTAssertLessThan(
            grown,
            Double(text.utf8.count) * 1.6,
            "A \(text.utf8.count)-byte text grew storage by \(Int(grown)) bytes"
        )
    }

    // MARK: Search index version 2

    /// The one-time upgrade of a history version 1 indexed whole: one
    /// rebuild bounds every oversized field inside its own transaction,
    /// returns the space they held, and publishes version 2. The fixtures
    /// are the ones ADR-0021 asks of a search index migration (CJK, Latin,
    /// combining-mark, full-width, emoji, punctuation, long-text and
    /// multi-item), and one- and two-character CJK queries still return
    /// complete results afterwards.
    func testAVersionOneStoreWithOversizedFieldsIsBoundedByOneRebuild()
        async throws
    {
        let fixture = try SearchBoundTemporaryDatabase(in: self)
        let writer = try fixture.open()
        var fixtures: [String: ClipboardHistoryEntryID] = [:]
        for value in [
            "剪贴板历史",
            "历史记录 Clipboard",
            "Clipboard History",
            "Cafe\u{301} Society",
            "Ｆｕｌｌ－Ｗｉｄｔｈ 历史",
            "Launch 🚀 now",
            "literal [brackets] + punctuation",
        ] {
            fixtures[value] = try await Self.capture(value, in: writer)
        }
        let multiItem = try await Self.capturePasteboardItems(
            [
                [.string: Data("alpha 历史".utf8)],
                [.string: Data("beta item".utf8)],
            ],
            in: writer
        )
        // Version 1 kept both of these whole: a long text, and a short one
        // whose normalized form outgrows the bound.
        let longText = "历史开头 "
            + Self.longText(
                head: "zqxheadmarker",
                tail: "zqxtailmarker",
                fillerCount: 15_000
            )
        let long = try await Self.capture(longText, in: writer)
        let expandingText = "zqxkoreanhead "
            + String(repeating: "한", count: 10_000)
            + " zqxkoreantail"
        let expanding = try await Self.capture(expandingText, in: writer)
        try await Self.rewindToVersionOne(
            [long: longText, expanding: expandingText],
            in: writer
        )
        try await Self.assertSearch("zqxtailmarker", in: writer, finds: [long])
        try await Self.assertSearch(
            "zqxkoreantail",
            in: writer,
            finds: [expanding]
        )
        let before = try await Self.storeMetrics(of: writer)
        XCTAssertEqual(before.version, 1)
        try await writer.closeStoreForTesting()

        let module = try fixture.open()
        await module.awaitSearchIndexRebuildForTesting()
        let after = try await Self.storeMetrics(of: module)
        XCTAssertEqual(after.version, Self.upgradedVersion)
        XCTAssertEqual(after.generation, before.generation + 1)
        let status = await module.status()
        XCTAssertEqual(status.searchIndex, .ready)
        try await Self.assertStoredBounded(longText, for: long, in: module)
        try await Self.assertStoredBounded(
            expandingText,
            for: expanding,
            in: module
        )
        try await Self.assertNoOversizedFields(in: module)
        try await Self.assertSearchIndexesAreConsistent(in: module)
        // The pages the whole values held went back to the file system.
        XCTAssertLessThanOrEqual(after.freelistCount, 16)
        XCTAssertLessThan(
            after.byteCount + longText.utf8.count,
            before.byteCount,
            "The upgrade left \(after.byteCount) of \(before.byteCount) bytes"
        )

        try await Self.assertSearch("zqxheadmarker", in: module, finds: [long])
        try await Self.assertSearch("zqxtailmarker", in: module, finds: [])
        try await Self.assertSearch(
            "zqxkoreanhead",
            in: module,
            finds: [expanding]
        )
        try await Self.assertSearch("zqxkoreantail", in: module, finds: [])
        let cjkEntries = Set(
            [
                "剪贴板历史",
                "历史记录 Clipboard",
                "Ｆｕｌｌ－Ｗｉｄｔｈ 历史",
            ].compactMap { fixtures[$0] } + [multiItem, long]
        )
        XCTAssertEqual(cjkEntries.count, 5)
        for query in ["史", "历史"] {
            try await Self.assertSearch(query, in: module, finds: cjkEntries)
        }
        for (query, values) in [
            ("clipboard history", ["Clipboard History"]),
            ("clipboard", ["Clipboard History", "历史记录 Clipboard"]),
            ("café society", ["Cafe\u{301} Society"]),
            ("full-width", ["Ｆｕｌｌ－Ｗｉｄｔｈ 历史"]),
            ("🚀", ["Launch 🚀 now"]),
            ("[brackets] +", ["literal [brackets] + punctuation"]),
        ] {
            let expected = Set(values.compactMap { fixtures[$0] })
            XCTAssertEqual(expected.count, values.count)
            try await Self.assertSearch(query, in: module, finds: expected)
        }
        try await Self.assertSearch("beta item", in: module, finds: [multiItem])

        // Rebuilt once: reopening finds version 2 and publishes nothing new.
        let published = try await Self.storeMetrics(of: module)
        try await module.closeStoreForTesting()
        let reopened = try fixture.open()
        await reopened.awaitSearchIndexRebuildForTesting()
        let again = try await Self.storeMetrics(of: reopened)
        XCTAssertEqual(again.version, Self.upgradedVersion)
        XCTAssertEqual(again.generation, published.generation)
    }

    /// Version 2 changes nothing for a store whose fields all fit the
    /// bound, so opening one stamps the new version in place.
    func testAVersionOneStoreWithoutOversizedFieldsIsStampedWithoutARebuild()
        async throws
    {
        let fixture = try SearchBoundTemporaryDatabase(in: self)
        let writer = try fixture.open()
        let entry = try await Self.capture(
            "ordinary 剪贴板 zqxmarker entry",
            in: writer
        )
        try await Self.writeSearchIndexMetadata(version: 1, in: writer)
        let before = try await Self.storeMetrics(of: writer)
        try await writer.closeStoreForTesting()

        let module = try fixture.open()
        let opened = await module.status()
        XCTAssertEqual(opened.searchIndex, .ready)
        // A rebuild bumps the generation by the time it is awaited, so
        // awaiting first keeps the comparison free of races.
        await module.awaitSearchIndexRebuildForTesting()
        let after = try await Self.storeMetrics(of: module)
        XCTAssertEqual(after.version, Self.upgradedVersion)
        XCTAssertEqual(after.generation, before.generation)
        try await Self.assertSearch("zqxmarker", in: module, finds: [entry])
        try await Self.assertSearch("剪", in: module, finds: [entry])
        try await Self.assertSearchIndexesAreConsistent(in: module)
    }

    /// A failed index is never stamped on open, even when every field fits
    /// the bound. The open retries its rebuild instead, which publishes
    /// version 2 as a new generation.
    func testAFailedVersionOneIndexIsRebuiltRatherThanStamped()
        async throws
    {
        let fixture = try SearchBoundTemporaryDatabase(in: self)
        let writer = try fixture.open()
        let entry = try await Self.capture("failed zqxmarker value", in: writer)
        try await Self.writeSearchIndexMetadata(
            version: 1,
            state: "failed",
            failure: "rebuildFailed",
            in: writer
        )
        let before = try await Self.storeMetrics(of: writer)
        try await writer.closeStoreForTesting()

        let module = try fixture.open()
        await module.awaitSearchIndexRebuildForTesting()
        let after = try await Self.storeMetrics(of: module)
        XCTAssertEqual(after.version, Self.upgradedVersion)
        XCTAssertEqual(after.generation, before.generation + 1)
        let status = await module.status()
        XCTAssertEqual(status.searchIndex, .ready)
        try await Self.assertSearch("zqxmarker", in: module, finds: [entry])
        try await Self.assertSearchIndexesAreConsistent(in: module)
        try await module.closeStoreForTesting()
    }

    /// Once opens have spent their retries on a failed index, they leave it
    /// failed and unstamped; only an explicit retry rebuilds it.
    func testAFailedVersionOneIndexOutOfRetriesStaysUnstampedUntilRetried()
        async throws
    {
        let fixture = try SearchBoundTemporaryDatabase(in: self)
        let writer = try fixture.open()
        let entry = try await Self.capture("failed zqxmarker value", in: writer)
        try await Self.writeSearchIndexMetadata(
            version: 1,
            state: "failed",
            failure: "rebuildFailed",
            in: writer
        )
        let before = try await Self.storeMetrics(of: writer)
        try await writer.closeStoreForTesting()
        try await Self.spendRebuildRetries(of: fixture)

        let module = try fixture.open()
        await module.awaitSearchIndexRebuildForTesting()
        let failed = try await module.page(
            ClipboardHistoryQuery(text: "zqxmarker")
        )
        XCTAssertEqual(failed.state, .failed(.rebuildFailed))
        XCTAssertEqual(failed.entries, [])
        let untouched = try await Self.storeMetrics(of: module)
        XCTAssertEqual(untouched.version, 1)
        XCTAssertEqual(untouched.generation, before.generation)

        let retry = try await module.retrySearchIndex()
        XCTAssertEqual(retry, .indexing)
        await module.awaitSearchIndexRebuildForTesting()
        let rebuilt = try await Self.storeMetrics(of: module)
        XCTAssertEqual(
            rebuilt.version,
            Self.upgradedVersion
        )
        XCTAssertEqual(rebuilt.generation, before.generation + 1)
        try await Self.assertSearch("zqxmarker", in: module, finds: [entry])
        try await module.closeStoreForTesting()
    }

    /// A failed rebuild rolls its whole transaction back, bounding writes
    /// included: the store stays a consistent version 1 store, marked failed,
    /// until the next open retries the upgrade.
    func testAFailedUpgradeRebuildLeavesTheVersionOneStoreIntact()
        async throws
    {
        let fixture = try SearchBoundTemporaryDatabase(in: self)
        let text = Self.longText(head: "zqxheadmarker", tail: "zqxtailmarker")
        let writer = try fixture.open()
        let long = try await Self.capture(text, in: writer)
        try await Self.rewindToVersionOne([long: text], in: writer)
        let before = try await Self.storeMetrics(of: writer)
        try await writer.closeStoreForTesting()

        let failing = try fixture.open(
            faultInjector: ClipboardHistoryFaultInjector(
                points: [.searchRebuildBeforePublish]
            )
        )
        await failing.awaitSearchIndexRebuildForTesting()
        let failedStatus = await failing.status()
        XCTAssertEqual(failedStatus.searchIndex, .failed(.rebuildFailed))
        try await Self.assertStoredWhole(text, for: long, in: failing)
        try await Self.assertSearchIndexesAreConsistent(in: failing)
        let failedMetrics = try await Self.storeMetrics(of: failing)
        XCTAssertEqual(failedMetrics.version, 1)
        XCTAssertEqual(failedMetrics.generation, before.generation)
        try await failing.closeStoreForTesting()

        let reopened = try fixture.open()
        await reopened.awaitSearchIndexRebuildForTesting()
        let status = await reopened.status()
        XCTAssertEqual(status.searchIndex, .ready)
        let upgraded = try await Self.storeMetrics(of: reopened)
        XCTAssertEqual(
            upgraded.version,
            Self.upgradedVersion
        )
        XCTAssertEqual(upgraded.generation, before.generation + 1)
        try await Self.assertStoredBounded(text, for: long, in: reopened)
        try await Self.assertSearch("zqxheadmarker", in: reopened, finds: [long])
        try await Self.assertSearch("zqxtailmarker", in: reopened, finds: [])
        try await Self.assertSearchIndexesAreConsistent(in: reopened)
    }

    func testAVersionOneIndexLeftIndexingIsRebuiltRatherThanStamped()
        async throws
    {
        let fixture = try SearchBoundTemporaryDatabase(in: self)
        let writer = try fixture.open()
        let entry = try await Self.capture("indexing zqxmarker value", in: writer)
        try await Self.writeSearchIndexMetadata(
            version: 1,
            state: "indexing",
            in: writer
        )
        let before = try await Self.storeMetrics(of: writer)
        try await writer.closeStoreForTesting()

        let module = try fixture.open()
        await module.awaitSearchIndexRebuildForTesting()
        let after = try await Self.storeMetrics(of: module)
        XCTAssertEqual(after.version, Self.upgradedVersion)
        XCTAssertEqual(after.generation, before.generation + 1)
        let status = await module.status()
        XCTAssertEqual(status.searchIndex, .ready)
        try await Self.assertSearch("zqxmarker", in: module, finds: [entry])
        try await Self.assertSearchIndexesAreConsistent(in: module)
    }

    /// Stamping skips only the rebuild version 2 needs. It still runs the
    /// integrity check every open runs, so a corrupt index is rebuilt.
    func testAStampedIndexThatFailsItsIntegrityCheckIsStillRebuilt()
        async throws
    {
        let fixture = try SearchBoundTemporaryDatabase(in: self)
        let writer = try fixture.open()
        let entry = try await Self.capture(
            "authoritative zqxmarker value",
            in: writer
        )
        let writerDatabase = try await writer.requiredDatabase()
        try await writerDatabase.write { database in
            let field = try XCTUnwrap(
                Row.fetchOne(
                    database,
                    sql: """
                        SELECT id, normalized_value
                        FROM clipboard_search_fields
                        WHERE entry_id = ?
                        """,
                    arguments: [SearchBoundStore.storedID(entry)]
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
            try SearchBoundStore.writeSearchIndexVersion(1, in: database)
        }
        let consistent = try await writerDatabase.write {
            try ClipboardHistoryModule.searchIndexesPassIntegrityCheck(in: $0)
        }
        XCTAssertFalse(consistent)
        let before = try await Self.storeMetrics(of: writer)
        try await writer.closeStoreForTesting()

        let module = try fixture.open()
        await module.awaitSearchIndexRebuildForTesting()
        let after = try await Self.storeMetrics(of: module)
        XCTAssertEqual(after.version, Self.upgradedVersion)
        XCTAssertEqual(after.generation, before.generation + 1)
        try await Self.assertSearch("authoritative", in: module, finds: [entry])
        try await Self.assertSearch("stale", in: module, finds: [])
        try await Self.assertSearchIndexesAreConsistent(in: module)
    }

    /// A clear of 512 entries or more drops both search indexes and indexes
    /// the surviving fields again in the same transaction. That must leave
    /// the indexes agreeing with the fields on a version 1 store the upgrade
    /// has not reached (here, one whose index had failed), queued behind the
    /// upgrade rebuild, and after it.
    func testBulkDeletionStaysConsistentBeforeDuringAndAfterTheUpgrade()
        async throws
    {
        let fixture = try SearchBoundTemporaryDatabase(in: self)
        let text = Self.longText(head: "zqxheadmarker", tail: "zqxtailmarker")
        let writer = try fixture.open()
        let kept = try await Self.capture(text, in: writer)
        guard case .updated = try await writer.apply(.setFavorite(kept, true))
        else {
            return XCTFail("Expected the favorite to protect the entry")
        }
        try await Self.rewindToVersionOne([kept: text], in: writer)
        try await Self.writeSearchIndexMetadata(
            version: 1,
            state: "failed",
            failure: "rebuildFailed",
            in: writer
        )
        try await Self.insertUnprotectedEntries(520, in: writer)
        try await writer.closeStoreForTesting()
        try await Self.spendRebuildRetries(of: fixture)

        // Before: the failed version 1 index, out of automatic retries, is
        // left alone, and the clear indexes the surviving whole value again.
        let before = try fixture.open()
        try await Self.clearUnprotectedEntries(expecting: 520, in: before)
        try await Self.assertStoredWhole(text, for: kept, in: before)
        try await Self.assertSearchIndexesAreConsistent(in: before)
        let tailCandidates = try await Self.trigramCandidateCount(
            "zqxtailmarker",
            in: before
        )
        XCTAssertEqual(tailCandidates, 1)
        let beforeMetrics = try await Self.storeMetrics(of: before)
        XCTAssertEqual(beforeMetrics.version, 1)
        try await Self.insertUnprotectedEntries(520, in: before)
        try await Self.writeSearchIndexMetadata(
            version: 1,
            state: "ready",
            in: before
        )
        try await before.closeStoreForTesting()

        // During: the clear waits for the upgrade rebuild, then lands on the
        // bounded fields.
        let hold = SearchBoundRebuildHold()
        defer { hold.release() }
        let during = try fixture.open(
            faultInjector: hold.faultInjector,
            beforeClosing: { hold.release() }
        )
        await waitUntilHeld(hold)
        let preview = try await during.previewClearHistory(
            scope: .unprotectedOnly
        )
        XCTAssertEqual(preview.affectedCount, 520)
        let queued = expectation(description: "clear queued behind the rebuild")
        // Named rather than `Self`: a `Self` reference makes the closure
        // capture the test case's dynamic type, which Swift 6.3's region
        // checker cannot analyze in the `sending` closure `Task.init` takes.
        // The other tasks in this file's nonisolated tests do the same.
        let whileHeld = Task {
            let confirmation =
                await ClipboardHistorySearchBoundTests.startConfirmation(
                    preview.token,
                    on: during
                )
            let recent = try await during.page(ClipboardHistoryQuery())
            queued.fulfill()
            return (confirmation, recent)
        }
        await fulfillment(of: [queued], timeout: 10)
        hold.release()
        let (confirmation, recent) = try await whileHeld.value
        XCTAssertEqual(recent.entries.count, 100)
        let cleared = try await confirmation.value
        XCTAssertEqual(cleared, .applied(deletedCount: 520))
        await during.awaitSearchIndexRebuildForTesting()
        let duringMetrics = try await Self.storeMetrics(of: during)
        XCTAssertEqual(
            duringMetrics.version,
            Self.upgradedVersion
        )
        try await Self.assertStoredBounded(text, for: kept, in: during)
        try await Self.assertSearchIndexesAreConsistent(in: during)
        try await Self.assertSearch("zqxheadmarker", in: during, finds: [kept])
        try await Self.assertSearch("zqxtailmarker", in: during, finds: [])
        let survivors = try await during.page(ClipboardHistoryQuery())
        XCTAssertEqual(survivors.entries.map(\.id), [kept])

        // After: a clear on the upgraded store.
        try await Self.insertUnprotectedEntries(520, in: during)
        try await Self.clearUnprotectedEntries(expecting: 520, in: during)
        try await Self.assertStoredBounded(text, for: kept, in: during)
        try await Self.assertSearchIndexesAreConsistent(in: during)
        try await Self.assertSearch("zqxheadmarker", in: during, finds: [kept])
        let remaining = try await during.page(ClipboardHistoryQuery())
        XCTAssertEqual(remaining.entries.map(\.id), [kept])
    }

    /// The upgrade rebuild holds the writer for one long transaction.
    /// Browsing must stay served meanwhile, with a capture waiting for its
    /// write turn rather than parking the module's actor on the writer.
    func testBrowsingIsServedWhileTheUpgradeRebuildIsHeld() async throws {
        let fixture = try SearchBoundTemporaryDatabase(in: self)
        let text = Self.longText(head: "zqxheadmarker", tail: "zqxtailmarker")
        let writer = try fixture.open()
        let long = try await Self.capture(text, in: writer)
        try await Self.rewindToVersionOne([long: text], in: writer)
        try await writer.closeStoreForTesting()

        let hold = SearchBoundRebuildHold()
        defer { hold.release() }
        let module = try fixture.open(
            faultInjector: hold.faultInjector,
            beforeClosing: { hold.release() }
        )
        await waitUntilHeld(hold)

        // Bounded, so a module stuck behind the rebuild fails the test
        // instead of hanging it.
        let served = expectation(description: "browsing served while held")
        let whileHeld = Task {
            let capture = await ClipboardHistorySearchBoundTests.startCapture(
                "captured during the upgrade",
                on: module
            )
            let recent = try await module.page(ClipboardHistoryQuery())
            let search = try await module.page(
                ClipboardHistoryQuery(text: "zqxheadmarker")
            )
            served.fulfill()
            return (capture, recent, search)
        }
        await fulfillment(of: [served], timeout: 10)
        hold.release()

        let (capture, recent, search) = try await whileHeld.value
        XCTAssertEqual(recent.entries.map(\.id), [long])
        XCTAssertEqual(search.state, .indexing)
        let captured = try await capture.value.entryID
        await module.awaitSearchIndexRebuildForTesting()
        let metrics = try await Self.storeMetrics(of: module)
        XCTAssertEqual(
            metrics.version,
            Self.upgradedVersion
        )
        let status = await module.status()
        XCTAssertEqual(status.searchIndex, .ready)
        try await Self.assertStoredBounded(text, for: long, in: module)
        try await Self.assertSearch(
            "captured during",
            in: module,
            finds: [captured]
        )
        try await Self.assertSearch("zqxheadmarker", in: module, finds: [long])
        try await Self.assertSearch("zqxtailmarker", in: module, finds: [])
        try await Self.assertSearchIndexesAreConsistent(in: module)
        let settled = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(settled.entries.map(\.id), [captured, long])
    }

    // MARK: Helpers

    /// A lowercase ASCII text, about three times the bound by default, whose
    /// head marker falls inside the bound and whose tail marker falls past
    /// it. Normalizing it changes nothing, so both stored values are cut at
    /// exactly the limit.
    private static func longText(
        head: String,
        tail: String,
        fillerCount: Int = 7_500
    ) -> String {
        "\(head) "
            + String(repeating: "lorem ipsum dolor sit amet ", count: fillerCount)
            + " \(tail)"
    }

    private static func boundedField(_ kind: String) -> StoredSearchField {
        StoredSearchField(
            kind: kind,
            valueBytes: limit,
            normalizedBytes: limit
        )
    }

    private static func capture(
        _ value: String,
        in module: ClipboardHistoryModule
    ) async throws -> ClipboardHistoryEntryID {
        try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: .unknown,
                content: .text(value)
            )
        ).entryID
    }

    /// Copies one pasteboard item per element, each holding the given data
    /// per type, and captures the copy.
    @MainActor
    private static func capturePasteboardItems(
        _ items: [[NSPasteboard.PasteboardType: Data]],
        in module: ClipboardHistoryModule
    ) async throws -> ClipboardHistoryEntryID {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "dev.bybee.AnyDoor.search-bound-tests.\(UUID().uuidString)"
            )
        )
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let pasteboardItems = items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: type)
            }
            return item
        }
        guard pasteboard.writeObjects(pasteboardItems) else {
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

    // A task created on an actor is enqueued there as it is created, so the
    // operations started below reach the module ahead of anything the caller
    // asks the module afterwards.

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

    private static func startConfirmation(
        _ token: ClipboardHistoryConfirmationToken,
        on module: isolated ClipboardHistoryModule
    ) -> Task<ClipboardHistoryDestructiveApplyOutcome, Error> {
        Task { try await module.confirm(token) }
    }

    /// Returns once `hold` holds a rebuild open, and fails the test instead
    /// of hanging it when no rebuild starts.
    private func waitUntilHeld(_ hold: SearchBoundRebuildHold) async {
        let held = expectation(description: "a rebuild reached its hold")
        Task {
            await hold.waitUntilReached()
            held.fulfill()
        }
        await fulfillment(of: [held], timeout: 10)
    }

    private static func assertSearch(
        _ text: String,
        in module: ClipboardHistoryModule,
        finds expected: Set<ClipboardHistoryEntryID>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let page = try await module.page(ClipboardHistoryQuery(text: text))
        XCTAssertEqual(page.state, .ready, text, file: file, line: line)
        XCTAssertEqual(
            page.entries.count,
            expected.count,
            text,
            file: file,
            line: line
        )
        XCTAssertEqual(
            Set(page.entries.map(\.id)),
            expected,
            text,
            file: file,
            line: line
        )
    }

    private static func storedSearchFields(
        of entry: ClipboardHistoryEntryID,
        in module: ClipboardHistoryModule
    ) async throws -> [StoredSearchField] {
        let database = try await module.requiredDatabase()
        return try await database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT field_kind,
                           octet_length(value) AS value_bytes,
                           octet_length(normalized_value) AS normalized_bytes
                    FROM clipboard_search_fields
                    WHERE entry_id = ?
                    ORDER BY field_kind, field_index
                    """,
                arguments: [SearchBoundStore.storedID(entry)]
            ).map { row in
                StoredSearchField(
                    kind: row["field_kind"],
                    valueBytes: row["value_bytes"],
                    normalizedBytes: row["normalized_bytes"]
                )
            }
        }
    }

    private static func storedSearchValues(
        of entry: ClipboardHistoryEntryID,
        in module: ClipboardHistoryModule
    ) async throws -> [StoredSearchValues] {
        let database = try await module.requiredDatabase()
        return try await database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT value, normalized_value
                    FROM clipboard_search_fields
                    WHERE entry_id = ?
                    ORDER BY field_kind, field_index
                    """,
                arguments: [SearchBoundStore.storedID(entry)]
            ).map { row in
                StoredSearchValues(
                    value: row["value"],
                    normalizedValue: row["normalized_value"]
                )
            }
        }
    }

    /// The entry's one search field holds exactly what writing `text`
    /// stores now.
    private static func assertStoredBounded(
        _ text: String,
        for entry: ClipboardHistoryEntryID,
        in module: ClipboardHistoryModule,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let bounded = ClipboardHistoryModule.boundedSearchField(text)
        let stored = try await storedSearchValues(of: entry, in: module)
        XCTAssertTrue(
            stored == [
                StoredSearchValues(
                    value: bounded.value,
                    normalizedValue: bounded.normalizedValue
                )
            ],
            "the stored field is not the bounded form of the text",
            file: file,
            line: line
        )
    }

    /// The entry's one search field holds `text` whole, as version 1 stored
    /// it.
    private static func assertStoredWhole(
        _ text: String,
        for entry: ClipboardHistoryEntryID,
        in module: ClipboardHistoryModule,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let stored = try await storedSearchValues(of: entry, in: module)
        XCTAssertTrue(
            stored == [
                StoredSearchValues(
                    value: text,
                    normalizedValue: ClipboardHistoryModule
                        .normalizeSearchText(text)
                )
            ],
            "the stored field is not the whole text",
            file: file,
            line: line
        )
    }

    private static func assertNoOversizedFields(
        in module: ClipboardHistoryModule,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let database = try await module.requiredDatabase()
        let oversized = try await database.read { database in
            try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*)
                    FROM clipboard_search_fields
                    WHERE octet_length(value) > ?
                       OR octet_length(normalized_value) > ?
                    """,
                arguments: [
                    ClipboardHistoryModule.searchFieldByteLimit,
                    ClipboardHistoryModule.searchFieldByteLimit,
                ]
            )
        }
        XCTAssertEqual(oversized, 0, file: file, line: line)
    }

    /// FTS5's integrity check compares both indexes against the stored
    /// normalized values. It is an INSERT, so it needs the writer.
    private static func assertSearchIndexesAreConsistent(
        in module: ClipboardHistoryModule,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let database = try await module.requiredDatabase()
        let consistent = try await database.write {
            try ClipboardHistoryModule.searchIndexesPassIntegrityCheck(in: $0)
        }
        XCTAssertTrue(consistent, file: file, line: line)
    }

    /// How many fields the trigram index offers as candidates for `text`.
    private static func trigramCandidateCount(
        _ text: String,
        in module: ClipboardHistoryModule
    ) async throws -> Int {
        let database = try await module.requiredDatabase()
        return try await database.read { database in
            try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*)
                    FROM clipboard_search_trigram
                    WHERE clipboard_search_trigram MATCH ?
                    """,
                arguments: [ClipboardHistoryModule.ftsLiteral(text)]
            ) ?? 0
        }
    }

    private static func storeMetrics(
        of module: ClipboardHistoryModule
    ) async throws -> SearchBoundStoreMetrics {
        let database = try await module.requiredDatabase()
        return try await database.read { database in
            SearchBoundStoreMetrics(
                version: try Int.fetchOne(
                    database,
                    sql: """
                        SELECT integer_value
                        FROM clipboard_maintenance_metadata
                        WHERE key = 'searchIndexVersion'
                        """
                ),
                generation: try ClipboardHistoryModule.searchIndexGeneration(
                    in: database
                ),
                pageCount: try Int.fetchOne(
                    database,
                    sql: "PRAGMA page_count"
                ) ?? 0,
                pageSize: try Int.fetchOne(
                    database,
                    sql: "PRAGMA page_size"
                ) ?? 0,
                freelistCount: try Int.fetchOne(
                    database,
                    sql: "PRAGMA freelist_count"
                ) ?? 0
            )
        }
    }

    private static func writeSearchIndexMetadata(
        version: Int,
        state: String? = nil,
        failure: String? = nil,
        in module: ClipboardHistoryModule
    ) async throws {
        let database = try await module.requiredDatabase()
        try await database.write { database in
            try SearchBoundStore.writeSearchIndexVersion(version, in: database)
            if let state {
                try SearchBoundStore.writeSearchIndexState(
                    state,
                    failure: failure,
                    in: database
                )
            }
        }
    }

    /// Opens the store with every rebuild failing until no open retries
    /// one any more. Each failed rebuild leaves the store as it found it.
    private static func spendRebuildRetries(
        of fixture: SearchBoundTemporaryDatabase
    ) async throws {
        for _ in 0..<ClipboardHistoryModule.searchIndexRebuildFailureLimit {
            let failing = try fixture.open(
                faultInjector: ClipboardHistoryFaultInjector(
                    points: [.searchRebuildBeforePublish]
                )
            )
            await failing.awaitSearchIndexRebuildForTesting()
            try await failing.closeStoreForTesting()
        }
    }

    /// Rewrites each entry's one search field to what version 1 stored for
    /// its whole text, the whole value and its whole normalized form, indexed
    /// as such, and marks the index version 1.
    private static func rewindToVersionOne(
        _ wholeTexts: [ClipboardHistoryEntryID: String],
        in module: ClipboardHistoryModule
    ) async throws {
        let database = try await module.requiredDatabase()
        try await database.write { database in
            for (entry, text) in wholeTexts {
                try SearchBoundStore.storeWhole(text, for: entry, in: database)
            }
            try SearchBoundStore.writeSearchIndexVersion(1, in: database)
        }
    }

    /// Inserts small unprotected entries directly, a faster path to a bulk
    /// deletion than capturing each.
    private static func insertUnprotectedEntries(
        _ count: Int,
        in module: ClipboardHistoryModule
    ) async throws {
        let database = try await module.requiredDatabase()
        try await database.write { database in
            let now = Date().timeIntervalSince1970
            for index in 0..<count {
                let id = UUID().uuidString.lowercased()
                let text = "bulk entry \(index)"
                try database.execute(
                    sql: """
                        INSERT INTO clipboard_entries(
                            id, captured_at, last_captured_at, preview_text
                        ) VALUES (?, ?, ?, ?)
                        """,
                    arguments: [id, now, now, text]
                )
                try ClipboardHistoryModule.insertSearchField(
                    value: text,
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
                    arguments: [id, now]
                )
            }
            try ClipboardHistoryModule.bumpSearchIndexGeneration(in: database)
        }
    }

    private static func clearUnprotectedEntries(
        expecting count: Int,
        in module: ClipboardHistoryModule,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let preview = try await module.previewClearHistory(
            scope: .unprotectedOnly
        )
        XCTAssertEqual(preview.affectedCount, count, file: file, line: line)
        let outcome = try await module.confirm(preview.token)
        XCTAssertEqual(
            outcome,
            .applied(deletedCount: count),
            file: file,
            line: line
        )
    }

    private static func rtfData(_ text: String) throws -> Data {
        let attributed = NSAttributedString(string: text)
        return try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.rtf
            ]
        )
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
}

private struct StoredSearchField: Equatable, Sendable {
    let kind: String
    let valueBytes: Int
    let normalizedBytes: Int
}

private struct StoredSearchValues: Equatable, Sendable {
    let value: String
    let normalizedValue: String
}

private struct SearchBoundStoreMetrics: Sendable {
    let version: Int?
    let generation: Int64
    let pageCount: Int
    let pageSize: Int
    let freelistCount: Int

    var byteCount: Int { pageCount * pageSize }
}

private enum SearchBoundTestError: Error {
    case unexpectedSearchFieldCount(Int)
}

/// Writes to a store directly, inside a transaction the caller opened.
private enum SearchBoundStore {
    static func storedID(_ entry: ClipboardHistoryEntryID) -> String {
        entry.value.uuidString.lowercased()
    }

    /// Replaces the entry's one search field with `text` whole, and both of
    /// its index entries with ones for its whole normalized form.
    static func storeWhole(
        _ text: String,
        for entry: ClipboardHistoryEntryID,
        in database: Database
    ) throws {
        let fields = try Row.fetchAll(
            database,
            sql: """
                SELECT id, normalized_value
                FROM clipboard_search_fields
                WHERE entry_id = ?
                """,
            arguments: [storedID(entry)]
        )
        guard fields.count == 1 else {
            throw SearchBoundTestError.unexpectedSearchFieldCount(fields.count)
        }
        let normalized = ClipboardHistoryModule.normalizeSearchText(text)
        for field in fields {
            let fieldID: Int64 = field["id"]
            try ClipboardHistoryModule.deleteSearchIndexEntries(
                fieldID: fieldID,
                normalizedValue: field["normalized_value"],
                from: database
            )
            try database.execute(
                sql: """
                    UPDATE clipboard_search_fields
                    SET value = ?, normalized_value = ?
                    WHERE id = ?
                    """,
                arguments: [text, normalized, fieldID]
            )
            try ClipboardHistoryModule.insertSearchIndexEntries(
                fieldID: fieldID,
                normalizedValue: normalized,
                into: database
            )
        }
    }

    static func writeSearchIndexVersion(
        _ version: Int,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                UPDATE clipboard_maintenance_metadata
                SET integer_value = ?
                WHERE key = 'searchIndexVersion'
                """,
            arguments: [version]
        )
    }

    static func writeSearchIndexState(
        _ state: String,
        failure: String?,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                UPDATE clipboard_maintenance_metadata
                SET text_value = ?
                WHERE key = 'searchIndexState'
                """,
            arguments: [state]
        )
        if let failure {
            try database.execute(
                sql: """
                    INSERT INTO clipboard_maintenance_metadata(key, text_value)
                    VALUES ('searchIndexFailure', ?)
                    ON CONFLICT(key) DO UPDATE SET
                        text_value = excluded.text_value
                    """,
                arguments: [failure]
            )
        } else {
            try database.execute(
                sql: """
                    DELETE FROM clipboard_maintenance_metadata
                    WHERE key = 'searchIndexFailure'
                    """
            )
        }
    }
}

/// Holds a search index rebuild open inside its write transaction, just
/// before it publishes, until the test releases it.
private final class SearchBoundRebuildHold: Sendable {
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

private actor SearchBoundVisionRecognizer: ClipboardHistoryVisionRecognizing {
    private let results: [ClipboardHistoryDerivedJobKind: [String]]

    init(results: [ClipboardHistoryDerivedJobKind: [String]]) {
        self.results = results
    }

    func recognize(
        _ kind: ClipboardHistoryDerivedJobKind,
        in bitmaps: [Data]
    ) async throws -> [String] {
        results[kind] ?? []
    }
}

private final class SearchBoundTemporaryDatabase {
    private let testCase: XCTestCase
    let directory: URL
    let url: URL
    let key = Data(repeating: 0x89, count: 32)

    init(in testCase: XCTestCase) throws {
        self.testCase = testCase
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-ClipboardHistorySearchBoundTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        url = directory.appendingPathComponent("history.sqlite")
        testCase.removeClipboardHistoryDirectoryAfterTest(directory)
    }

    func open(
        faultInjector: ClipboardHistoryFaultInjector =
            ClipboardHistoryFaultInjector(),
        visionRecognizer: any ClipboardHistoryVisionRecognizing =
            ClipboardHistoryVisionRecognizer(),
        beforeClosing: @escaping @Sendable () async -> Void = {}
    ) throws -> ClipboardHistoryModule {
        try testCase.trackClipboardHistoryModule(ClipboardHistoryModule(
            testingDatabaseURL: url,
            databaseKey: key,
            faultInjector: faultInjector,
            visionRecognizer: visionRecognizer
        ), beforeClosing: beforeClosing)
    }
}
