import AppKit
import Foundation
import ImageIO
import LocalAuthentication
import Security
import UniformTypeIdentifiers
import XCTest
import os

@testable import ClipboardHistory

final class ClipboardHistoryModuleTests: XCTestCase {
    @MainActor
    func testWhitespaceOnlyTextIsCapturedWhileZeroLengthTextIsAbsent()
        async throws
    {
        let fixture = try TemporaryStore()
        let module = makeReadyModule(in: fixture)
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("dev.bybee.AnyDoor.tests.\(UUID().uuidString)")
        )

        pasteboard.clearContents()
        let whitespaceItem = NSPasteboardItem()
        whitespaceItem.setString(" \t\r\n ", forType: .string)
        XCTAssertTrue(pasteboard.writeObjects([whitespaceItem]))
        let whitespaceCapture = try await module.capture(
            ClipboardHistoryPasteboardCaptureRequest(pasteboard: pasteboard),
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: nil,
                displayName: nil
            )
        )
        guard case .captured(let captured) = whitespaceCapture else {
            return XCTFail("Expected whitespace-only text to be captured")
        }
        let materialized = try await module.materialize(
            ClipboardHistoryMaterializationRequest(
                entryID: captured.entryID,
                purpose: .plainTextPaste
            )
        )
        XCTAssertEqual(
            materialized.items[0].representations,
            [
                .text(
                    typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                    value: " \t\r\n "
                )
            ]
        )

        pasteboard.clearContents()
        let emptyItem = NSPasteboardItem()
        emptyItem.setString("", forType: .string)
        XCTAssertTrue(pasteboard.writeObjects([emptyItem]))
        let emptyCapture = try await module.capture(
            ClipboardHistoryPasteboardCaptureRequest(pasteboard: pasteboard),
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: nil,
                displayName: nil
            )
        )
        XCTAssertEqual(emptyCapture, .skipped(.unsupportedItem))
        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries.count, 1)
    }

    @MainActor
    func testPlainTextMaterializationRejectsMixedEntryWithoutExactTextOnEveryItem()
        async throws
    {
        let fixture = try TemporaryStore()
        let module = makeReadyModule(in: fixture)
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("dev.bybee.AnyDoor.tests.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        let textItem = NSPasteboardItem()
        textItem.setString("first", forType: .string)
        let imageItem = NSPasteboardItem()
        imageItem.setData(try makeOrientedWideGamutPNG(), forType: .png)
        XCTAssertTrue(pasteboard.writeObjects([textItem, imageItem]))
        let capture = try await module.capture(
            ClipboardHistoryPasteboardCaptureRequest(pasteboard: pasteboard),
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: nil,
                displayName: nil
            )
        )
        guard case .captured(let captured) = capture else {
            return XCTFail("Expected mixed content capture")
        }

        do {
            _ = try await module.materialize(
                ClipboardHistoryMaterializationRequest(
                    entryID: captured.entryID,
                    purpose: .plainTextPaste
                )
            )
            XCTFail("Expected incomplete plain-text materialization to fail")
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryModuleError,
                .operationUnavailable
            )
        }
    }

    func testExplicitFirstPartyCapturesKeepProvenanceWithoutRecursiveFacetInference()
        async throws
    {
        let fixture = try TemporaryStore()
        let module = makeReadyModule(in: fixture)
        let source = ClipboardHistoryCaptureSource(
            bundleIdentifier: "dev.bybee.AnyDoor",
            displayName: "AnyDoor"
        )

        let ocr = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: source,
                content: .ocr("https://ocr.example")
            )
        )
        let qr = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: source,
                content: .qrCode("#FF00FF")
            )
        )
        let color = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: source,
                content: .color("Color(red: 0.1, green: 0.2, blue: 0.3)")
            )
        )

        let page = try await module.page(ClipboardHistoryQuery())
        let byID = Dictionary(uniqueKeysWithValues: page.entries.map {
            ($0.id, $0.facets)
        })
        XCTAssertEqual(byID[ocr.entryID], [.text])
        XCTAssertEqual(byID[qr.entryID], [.text, .qrCode])
        XCTAssertEqual(byID[color.entryID], [.text, .color])

        let preview = try await module.materialize(
            ClipboardHistoryMaterializationRequest(
                entryID: qr.entryID,
                purpose: .preview
            )
        )
        XCTAssertEqual(
            preview.items[0].representations,
            [
                .text(
                    typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                    value: "#FF00FF"
                )
            ]
        )
    }

    @MainActor
    func testAggregateByteAndPixelSafetyLimitsCommitNoEntryOrPayload()
        async throws
    {
        let fixture = try TemporaryStore()
        let module = makeReadyModule(in: fixture)

        do {
            let pasteboard = NSPasteboard(
                name: NSPasteboard.Name(
                    "dev.bybee.AnyDoor.tests.\(UUID().uuidString)"
                )
            )
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setData(
                Data(repeating: 0x41, count: 128 * 1_024 * 1_024 + 1),
                forType: .html
            )
            XCTAssertTrue(pasteboard.writeObjects([item]))
            let outcome = try await module.capture(
                ClipboardHistoryPasteboardCaptureRequest(
                    pasteboard: pasteboard
                ),
                source: ClipboardHistoryCaptureSource(
                    bundleIdentifier: nil,
                    displayName: nil
                )
            )
            XCTAssertEqual(outcome, .skipped(.contentTooLarge))
        }

        do {
            let pasteboard = NSPasteboard(
                name: NSPasteboard.Name(
                    "dev.bybee.AnyDoor.tests.\(UUID().uuidString)"
                )
            )
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setData(
                try makeOversizedPixelPNG(),
                forType: .png
            )
            XCTAssertTrue(pasteboard.writeObjects([item]))
            let outcome = try await module.capture(
                ClipboardHistoryPasteboardCaptureRequest(
                    pasteboard: pasteboard
                ),
                source: ClipboardHistoryCaptureSource(
                    bundleIdentifier: nil,
                    displayName: nil
                )
            )
            XCTAssertEqual(outcome, .skipped(.imageTooLarge))
        }

        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries, [])
        XCTAssertEqual(try fixture.payloadFiles(), [])
        XCTAssertEqual(try fixture.stagingFiles(), [])
    }

    @MainActor
    func testStandardColorPreservesRawRepresentationAndOverlapsExactTextFacet()
        async throws
    {
        let fixture = try TemporaryStore()
        let module = makeReadyModule(in: fixture)
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("dev.bybee.AnyDoor.tests.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        let color = NSColor(
            displayP3Red: 0.25,
            green: 0.5,
            blue: 0.75,
            alpha: 0.5
        )
        let colorData = try XCTUnwrap(
            color.pasteboardPropertyList(forType: .color) as? Data
        )
        item.setData(colorData, forType: .color)
        item.setString("original color label", forType: .string)
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let capture = try await module.capture(
            ClipboardHistoryPasteboardCaptureRequest(pasteboard: pasteboard),
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: "dev.bybee.colors",
                displayName: "Colors"
            )
        )
        guard case .captured(let captured) = capture else {
            return XCTFail("Expected the standard color to be captured")
        }

        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries[0].facets, [.text, .color])
        let materialized = try await module.materialize(
            ClipboardHistoryMaterializationRequest(
                entryID: captured.entryID,
                purpose: .normalPaste
            )
        )
        XCTAssertEqual(
            materialized.items[0].representations,
            [
                .text(
                    typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                    value: "original color label"
                ),
                .data(
                    typeIdentifier: NSPasteboard.PasteboardType.color.rawValue,
                    colorData
                ),
            ]
        )
    }

    @MainActor
    func testSnapshotRejectsMarkersUnsupportedItemsAndGenerationChangesAtomically()
        async throws
    {
        let fixture = try TemporaryStore()
        let module = makeReadyModule(in: fixture)
        let privateType = NSPasteboard.PasteboardType("dev.bybee.tests.private")
        let markerType = NSPasteboard.PasteboardType(
            "org.nspasteboard.ConcealedType"
        )

        let markerPasteboard = NSPasteboard(
            name: NSPasteboard.Name("dev.bybee.AnyDoor.tests.\(UUID().uuidString)")
        )
        markerPasteboard.clearContents()
        let markedItem = NSPasteboardItem()
        let markerProvider = TestPasteboardDataProvider(
            action: .provide("must not be read")
        )
        markedItem.setDataProvider(markerProvider, forTypes: [.string])
        markedItem.setData(Data(), forType: markerType)
        XCTAssertTrue(markerPasteboard.writeObjects([markedItem]))
        let markerRequest = ClipboardHistoryPasteboardCaptureRequest(
            pasteboard: markerPasteboard
        )
        XCTAssertEqual(markerProvider.callCount, 0)
        let markerOutcome = try await module.capture(
            markerRequest,
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: nil,
                displayName: nil
            )
        )
        XCTAssertEqual(markerOutcome, .skipped(.excluded))

        let unsupportedPasteboard = NSPasteboard(
            name: NSPasteboard.Name("dev.bybee.AnyDoor.tests.\(UUID().uuidString)")
        )
        unsupportedPasteboard.clearContents()
        let supported = NSPasteboardItem()
        supported.setString("supported first item", forType: .string)
        supported.setData(Data("ignored private".utf8), forType: privateType)
        let unsupported = NSPasteboardItem()
        unsupported.setData(Data("private".utf8), forType: privateType)
        XCTAssertTrue(unsupportedPasteboard.writeObjects([supported, unsupported]))
        let unsupportedRequest = ClipboardHistoryPasteboardCaptureRequest(
            pasteboard: unsupportedPasteboard
        )
        let unsupportedOutcome = try await module.capture(
            unsupportedRequest,
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: nil,
                displayName: nil
            )
        )
        XCTAssertEqual(unsupportedOutcome, .skipped(.unsupportedItem))

        let changingPasteboard = NSPasteboard(
            name: NSPasteboard.Name("dev.bybee.AnyDoor.tests.\(UUID().uuidString)")
        )
        changingPasteboard.clearContents()
        let changingItem = NSPasteboardItem()
        let changingProvider = TestPasteboardDataProvider(
            action: .replaceGeneration(
                provided: "old generation",
                replacement: "new generation"
            )
        )
        changingItem.setDataProvider(changingProvider, forTypes: [.string])
        XCTAssertTrue(changingPasteboard.writeObjects([changingItem]))
        let changingRequest = ClipboardHistoryPasteboardCaptureRequest(
            pasteboard: changingPasteboard
        )
        let changingOutcome = try await module.capture(
            changingRequest,
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: nil,
                displayName: nil
            )
        )
        XCTAssertEqual(changingOutcome, .skipped(.generationChanged))

        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries, [])
        XCTAssertEqual(try fixture.payloadFiles(), [])
    }

    @MainActor
    func testFileCaptureUsesAtomicBookmarksWithoutCopyingOrPathFallback()
        async throws
    {
        let fixture = try TemporaryStore()
        let files = try TemporaryFileReferences()
        let first = try files.create(name: "first.png", contents: "not image data")
        let second = try files.create(name: "second.txt", contents: "second")
        let missing = files.url.appendingPathComponent("missing.txt")
        let module = makeReadyModule(in: fixture)

        let invalidPasteboard = makeFilePasteboard([first, missing])
        let invalid = try await module.capture(
            ClipboardHistoryPasteboardCaptureRequest(
                pasteboard: invalidPasteboard
            ),
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: "com.apple.finder",
                displayName: "Finder"
            )
        )
        XCTAssertEqual(invalid, .skipped(.invalidFileReference))
        let pageAfterInvalid = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(pageAfterInvalid.entries, [])

        let pasteboard = makeFilePasteboard([first, second])
        let capture = try await module.capture(
            ClipboardHistoryPasteboardCaptureRequest(pasteboard: pasteboard),
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: "com.apple.finder",
                displayName: "Finder"
            )
        )
        guard case .captured(let captured) = capture else {
            return XCTFail("Expected concrete file URLs to be captured")
        }
        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries[0].facets, [.file, .image])
        XCTAssertEqual(try fixture.payloadFiles(), [])

        let movedFirst = files.url.appendingPathComponent("moved.png")
        try FileManager.default.moveItem(at: first, to: movedFirst)
        let materialized = try await module.materialize(
            ClipboardHistoryMaterializationRequest(
                entryID: captured.entryID,
                purpose: .normalPaste
            )
        )
        XCTAssertEqual(
            materialized.items.compactMap { item -> String? in
                guard item.representations.count == 1,
                    case .file(let reference) = item.representations[0]
                else {
                    return nil
                }
                return reference.currentURL.lastPathComponent
            },
            ["moved.png", "second.txt"]
        )

        try FileManager.default.removeItem(at: second)
        try Data("replacement".utf8).write(to: second)
        do {
            _ = try await module.materialize(
                ClipboardHistoryMaterializationRequest(
                    entryID: captured.entryID,
                    purpose: .normalPaste
                )
            )
            XCTFail("Expected the original bookmark to remain unavailable")
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryModuleError,
                .fileReferencesUnavailable(captured.entryID, count: 1)
            )
        }
    }

    @MainActor
    func testCanonicalBitmapAppliesOrientationAndPreservesDepthAlphaProfileAndProvenance()
        async throws
    {
        let sourcePNG = try makeOrientedWideGamutPNG()
        let fixture = try TemporaryStore()
        let module = makeReadyModule(in: fixture)
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("dev.bybee.AnyDoor.tests.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(sourcePNG, forType: .png)
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let externalCapture = try await module.capture(
            ClipboardHistoryPasteboardCaptureRequest(pasteboard: pasteboard),
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: "com.apple.screencapture",
                displayName: "Screenshot"
            )
        )
        guard case .captured(let external) = externalCapture else {
            return XCTFail("Expected the external bitmap to be captured")
        }
        let externalPage = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(externalPage.entries[0].facets, [.image])

        let materialized = try await module.materialize(
            ClipboardHistoryMaterializationRequest(
                entryID: external.entryID,
                purpose: .normalPaste
            )
        )
        let canonical = try XCTUnwrap(materialized.singleDataRepresentation)
        let canonicalSource = try XCTUnwrap(
            CGImageSourceCreateWithData(canonical as CFData, nil)
        )
        let canonicalProperties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(canonicalSource, 0, nil)
                as? [CFString: Any]
        )
        let canonicalImage = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(canonicalSource, 0, nil)
        )
        XCTAssertEqual(canonicalImage.width, 3)
        XCTAssertEqual(canonicalImage.height, 2)
        XCTAssertEqual(canonicalImage.bitsPerComponent, 16)
        XCTAssertNotEqual(canonicalImage.alphaInfo, .none)
        XCTAssertEqual(canonicalImage.colorSpace?.name, CGColorSpace.displayP3)
        XCTAssertEqual(
            canonicalProperties[kCGImagePropertyOrientation] as? Int,
            nil
        )

        let firstParty = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: ClipboardHistoryCaptureSource(
                    bundleIdentifier: "dev.bybee.AnyDoor",
                    displayName: "AnyDoor"
                ),
                content: .bitmap(
                    sourcePNG,
                    provenance: .anyDoorScreenshot
                )
            )
        )
        let screenshotPage = try await module.page(
            ClipboardHistoryQuery(facet: .screenshot)
        )
        XCTAssertEqual(screenshotPage.entries.map(\.id), [firstParty.entryID])
    }

    @MainActor
    func testExactTextDerivesClosedOverlappingFacetsWithoutRewritingPayload()
        async throws
    {
        let cases: [(String, Set<ClipboardHistoryFacet>)] = [
            (" \thttps://example.com/path?q=1\r\n", [.text, .link]),
            ("person@example.com", [.text, .email]),
            ("mailto:person@example.com", [.text, .link, .email]),
            ("#1a2B3c", [.text, .color]),
            ("file:///tmp/reference.txt", [.text, .file]),
            ("See https://example.com in prose", [.text]),
            ("javascript://example.com", [.text]),
        ]

        for (text, expectedFacets) in cases {
            let fixture = try TemporaryStore()
            let module = makeReadyModule(in: fixture)
            let pasteboard = NSPasteboard(
                name: NSPasteboard.Name("dev.bybee.AnyDoor.tests.\(UUID().uuidString)")
            )
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)

            let capture = try await module.capture(
                ClipboardHistoryPasteboardCaptureRequest(
                    pasteboard: pasteboard
                ),
                source: ClipboardHistoryCaptureSource(
                    bundleIdentifier: nil,
                    displayName: nil
                )
            )
            guard case .captured(let captured) = capture else {
                return XCTFail("Expected \(text) to be captured")
            }
            let page = try await module.page(ClipboardHistoryQuery())
            let entry = try XCTUnwrap(page.entries.first)
            XCTAssertEqual(entry.id, captured.entryID)
            XCTAssertEqual(entry.facets, expectedFacets, "Unexpected facets for \(text)")

            let materialized = try await module.materialize(
                ClipboardHistoryMaterializationRequest(
                    entryID: captured.entryID,
                    purpose: .normalPaste
                )
            )
            XCTAssertEqual(
                materialized.items[0].representations[0],
                .text(
                    typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                    value: text
                )
            )
        }
    }

    @MainActor
    func testNamedPasteboardCapturePreservesItemOrderAndEveryStandardTextRepresentation()
        async throws
    {
        let fixture = try TemporaryStore()
        let module = makeReadyModule(in: fixture)
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("dev.bybee.AnyDoor.tests.\(UUID().uuidString)")
        )
        pasteboard.clearContents()

        let exactText = " \tfirst line\r\nsecond line "
        let rtf = Data(#"{\rtf1\ansi first}"#.utf8)
        let rtfd = Data("flat rtfd fixture".utf8)
        let html = Data("<p>first<br>second</p>".utf8)
        let first = NSPasteboardItem()
        first.setString(exactText, forType: .string)
        first.setData(rtf, forType: .rtf)
        first.setData(
            rtfd,
            forType: NSPasteboard.PasteboardType("com.apple.flat-rtfd")
        )
        first.setData(html, forType: .html)

        let second = NSPasteboardItem()
        second.setString("https://example.com/path", forType: .URL)
        second.setString("Example link", forType: .string)
        XCTAssertTrue(pasteboard.writeObjects([first, second]))

        let capture = try await module.capture(
            ClipboardHistoryPasteboardCaptureRequest(pasteboard: pasteboard),
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: "dev.bybee.tests",
                displayName: "Tests"
            )
        )
        guard case .captured(let captured) = capture else {
            return XCTFail("Expected a captured pasteboard generation")
        }

        let materialized = try await module.materialize(
            ClipboardHistoryMaterializationRequest(
                entryID: captured.entryID,
                purpose: .normalPaste
            )
        )

        XCTAssertEqual(
            materialized,
            ClipboardHistoryMaterialization(items: [
                ClipboardHistoryMaterializedItem(representations: [
                    .text(
                        typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                        value: exactText
                    ),
                    .data(
                        typeIdentifier: NSPasteboard.PasteboardType.rtf.rawValue,
                        rtf
                    ),
                    .data(
                        typeIdentifier: "com.apple.flat-rtfd",
                        rtfd
                    ),
                    .data(
                        typeIdentifier: NSPasteboard.PasteboardType.html.rawValue,
                        html
                    ),
                ]),
                ClipboardHistoryMaterializedItem(representations: [
                    .text(
                        typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                        value: "Example link"
                    ),
                    .text(
                        typeIdentifier: NSPasteboard.PasteboardType.URL.rawValue,
                        value: "https://example.com/path"
                    ),
                ]),
            ])
        )

        let plainText = try await module.materialize(
            ClipboardHistoryMaterializationRequest(
                entryID: captured.entryID,
                purpose: .plainTextPaste
            )
        )
        XCTAssertEqual(
            plainText.items,
            [
                ClipboardHistoryMaterializedItem(representations: [
                    .text(
                        typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                        value: exactText
                    )
                ]),
                ClipboardHistoryMaterializedItem(representations: [
                    .text(
                        typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                        value: "Example link"
                    )
                ]),
            ]
        )
    }

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

    func testEncryptedStoreAppliesVersionedMigrationsAndPassesIntegrityChecks()
        async throws
    {
        let fixture = try TemporaryDatabase()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key
        )

        let diagnostics = try await module.storageDiagnostics()

        XCTAssertEqual(
            diagnostics.appliedMigrations,
            [
                "v1_foundation",
                "v2_encrypted_store",
                "v3_file_reference_identity",
                "v4_capture_source_provenance",
                "v5_indexed_search",
                "v6_retention_and_mutations",
                "v7_derived_indexing",
                "v8_legacy_migration",
                "v9_retention_delete_index",
                "v10_recency_paging_index",
            ]
        )
        XCTAssertEqual(diagnostics.journalMode, "wal")
        XCTAssertTrue(diagnostics.foreignKeysEnabled)
        XCTAssertEqual(diagnostics.autoVacuumMode, 2)
        XCTAssertTrue(diagnostics.secureDeleteEnabled)
        XCTAssertTrue(diagnostics.databaseIntegrityOK)
        XCTAssertTrue(diagnostics.foreignKeyIntegrityOK)
        XCTAssertTrue(diagnostics.cipherIntegrityOK)
    }

    func testExistingFoundationStoreMigratesThroughEveryVersion() async throws {
        let fixture = try TemporaryDatabase()
        try ClipboardHistoryModule.createFoundationStoreForTesting(
            at: fixture.url,
            databaseKey: fixture.key
        )

        let recognizer = MigrationVisionRecognizer()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.url,
            databaseKey: fixture.key,
            visionRecognizer: recognizer
        )

        let diagnostics = try await module.storageDiagnostics()
        XCTAssertEqual(
            diagnostics.appliedMigrations,
            [
                "v1_foundation",
                "v2_encrypted_store",
                "v3_file_reference_identity",
                "v4_capture_source_provenance",
                "v5_indexed_search",
                "v6_retention_and_mutations",
                "v7_derived_indexing",
                "v8_legacy_migration",
                "v9_retention_delete_index",
                "v10_recency_paging_index",
            ]
        )
        XCTAssertTrue(diagnostics.databaseIntegrityOK)
        XCTAssertTrue(diagnostics.foreignKeyIntegrityOK)
        XCTAssertTrue(diagnostics.cipherIntegrityOK)

        let migratedSetting =
            try await module.isAutomaticImageTextIndexingEnabled()
        XCTAssertFalse(migratedSetting)
        let capture = try await module.capture(
            bitmapRequest(Data("migration behavior".utf8))
        )
        await module.awaitDerivedJobsForTesting()
        let derived = try await module.derivedIndexingDiagnostics(
            for: capture.entryID
        )
        XCTAssertEqual(
            derived.jobs,
            [
                ClipboardHistoryDerivedJobDiagnostics(
                    kind: .qr,
                    state: .succeeded,
                    attemptCount: 1,
                    eligibleGeneration: 1
                )
            ]
        )
        let recognizedKinds = await recognizer.recognizedKinds()
        XCTAssertEqual(recognizedKinds, [.qr])
    }

    func testVersionedHKDFDerivesIndependentDatabaseAndPayloadKeys() throws {
        let masterKey = Data(0..<32)

        let keys = ClipboardHistoryKeyDerivation.deriveV1(from: masterKey)

        XCTAssertEqual(
            keys.databaseKey.hexString,
            "754c14af5ed606dbbb4cd2a3760c521bc99fd10d98a7086eaaf332ae31b6a99c"
        )
        XCTAssertEqual(
            keys.payloadKey.hexString,
            "2f8879437cd71a799eb39c1b29abc8f8b5f8dc3748937b8f11383db4ab27c33e"
        )
        XCTAssertNotEqual(keys.databaseKey, keys.payloadKey)
        XCTAssertEqual(keys.version, 1)
    }

    func testProductionKeychainPolicyIsFixedDeviceOnlyAndAllowsACLPrompt() {
        XCTAssertEqual(
            ClipboardHistoryKeychainStore.service,
            "dev.bybee.AnyDoor.ClipboardHistory"
        )
        XCTAssertEqual(
            ClipboardHistoryKeychainStore.account,
            "device-master-key-v1"
        )

        let addAttributes = ClipboardHistoryKeychainStore.addAttributes(
            key: Data(repeating: 0xA5, count: 32)
        )
        XCTAssertEqual(
            addAttributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        XCTAssertEqual(
            addAttributes[kSecAttrSynchronizable as String] as? Bool,
            false
        )

        let readQuery = ClipboardHistoryKeychainStore.readQuery
        let context = try? XCTUnwrap(
            readQuery[kSecUseAuthenticationContext as String] as? LAContext
        )
        XCTAssertEqual(context?.interactionNotAllowed, false)
    }

    func testLockedKeychainPausesWithoutCreatingStoreAndRetryResumes() async throws {
        let fixture = try TemporaryStore()
        let masterKey = Data(repeating: 0x31, count: 32)
        let keyStore = TestMasterKeyStore(loadResult: .locked)
        let module = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: keyStore
        )

        let lockedStatus = await module.status()
        XCTAssertEqual(
            lockedStatus,
            ClipboardHistoryStatus(
                availability: .paused,
                reason: .keychainLocked,
                isMonitoring: false
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
        XCTAssertEqual(keyStore.createCallCount, 0)

        keyStore.loadResult = .key(masterKey)
        await module.retry()

        let resumedStatus = await module.status()
        XCTAssertEqual(resumedStatus.availability, .ready)
        XCTAssertNil(resumedStatus.reason)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.url.appendingPathComponent("history.sqlite").path
            )
        )
    }

    func testMissingKeyNeverCreatesReplacementForExistingStore() async throws {
        let fixture = try TemporaryStore()
        let masterKey = Data(repeating: 0x42, count: 32)
        let keyStore = TestMasterKeyStore(
            loadResult: .missing,
            keyToCreate: masterKey
        )
        let original = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: keyStore
        )
        let originalStatus = await original.status()
        XCTAssertEqual(originalStatus.availability, .ready)
        try await original.closeStoreForTesting()

        let databaseURL = fixture.url.appendingPathComponent("history.sqlite")
        let bytesBefore = try Data(contentsOf: databaseURL)
        keyStore.loadResult = .missing

        let reopened = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: keyStore
        )

        let reopenedStatus = await reopened.status()
        XCTAssertEqual(
            reopenedStatus,
            ClipboardHistoryStatus(
                availability: .unavailable,
                reason: .missingKey,
                isMonitoring: false
            )
        )
        XCTAssertEqual(keyStore.createCallCount, 1)
        XCTAssertEqual(try Data(contentsOf: databaseURL), bytesBefore)
    }

    func testWrongExistingKeyReportsAuthenticationFailureWithoutReset() async throws {
        let fixture = try TemporaryStore()
        let keyStore = TestMasterKeyStore(
            loadResult: .missing,
            keyToCreate: Data(repeating: 0x53, count: 32)
        )
        let original = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: keyStore
        )
        try await original.closeStoreForTesting()
        let databaseURL = fixture.url.appendingPathComponent("history.sqlite")
        let resourceBefore = try databaseURL.resourceValues(
            forKeys: [.fileResourceIdentifierKey]
        ).fileResourceIdentifier

        keyStore.loadResult = .key(Data(repeating: 0xA9, count: 32))
        let reopened = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: keyStore
        )

        let reopenedStatus = await reopened.status()
        XCTAssertEqual(reopenedStatus.reason, .databaseAuthenticationFailed)
        let resourceAfter = try databaseURL.resourceValues(
            forKeys: [.fileResourceIdentifierKey]
        ).fileResourceIdentifier
        XCTAssertEqual(
            String(describing: resourceAfter),
            String(describing: resourceBefore)
        )
        XCTAssertEqual(keyStore.createCallCount, 1)
    }

    func testIntegrityFailureReportsPersistentUnavailableWithoutReset() async throws {
        let fixture = try TemporaryStore()
        let keyStore = TestMasterKeyStore(
            loadResult: .missing,
            keyToCreate: Data(repeating: 0xB6, count: 32)
        )
        let original = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: keyStore
        )
        try await original.damageSchemaForIntegrityTesting()
        try await original.closeStoreForTesting()

        let reopened = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: keyStore
        )

        let status = await reopened.status()
        XCTAssertEqual(status.availability, .unavailable)
        XCTAssertEqual(status.reason, .databaseCorrupt)
        XCTAssertEqual(keyStore.createCallCount, 1)
        XCTAssertEqual(keyStore.deleteCallCount, 0)
    }

    func testFailedForeignKeyIntegrityCheckReportsTypedUnavailable() async throws {
        let fixture = try TemporaryStore()
        let keyStore = TestMasterKeyStore(
            loadResult: .missing,
            keyToCreate: Data(repeating: 0xD8, count: 32)
        )
        let original = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: keyStore
        )
        try await original.damageForeignKeysForIntegrityTesting()
        try await original.closeStoreForTesting()

        let reopened = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: keyStore
        )

        let status = await reopened.status()
        XCTAssertEqual(status.availability, .unavailable)
        XCTAssertEqual(status.reason, .databaseIntegrityFailed)
        XCTAssertEqual(keyStore.createCallCount, 1)
        XCTAssertEqual(keyStore.deleteCallCount, 0)
    }

    func testProductionKeychainCrossIdentityACLBoundary() throws {
        if ProcessInfo.processInfo.environment[
            KeychainCrossIdentityHarness.childModeEnvironment
        ] != nil {
            throw XCTSkip("Parent-only cross-identity orchestration test")
        }

        let harness = try KeychainCrossIdentityHarness(
            testBundle: Bundle(for: Self.self).bundleURL,
            xctestExecutable: URL(
                fileURLWithPath: ProcessInfo.processInfo.arguments[0]
            ).resolvingSymlinksInPath()
        )
        XCTAssertNotEqual(
            harness.developmentDesignatedRequirement,
            harness.installedDesignatedRequirement
        )

        let allowsInteraction =
            ProcessInfo.processInfo.environment[
                "ANYDOOR_RUN_INTERACTIVE_KEYCHAIN_ACL"
            ] == "1"
        for order in [
            (harness.developmentExecutable, harness.installedExecutable),
            (harness.installedExecutable, harness.developmentExecutable),
        ] {
            let fixture = try TemporaryCrossIdentityFixture()
            let creator = try harness.run(
                executable: order.0,
                mode: .create,
                fixture: fixture,
                allowsInteraction: false
            )
            XCTAssertEqual(creator.masterKeyResult, .key)
            XCTAssertEqual(creator.availability, "ready")
            XCTAssertEqual(creator.entryCount, 1)

            let databaseURL = fixture.storeRoot.appendingPathComponent(
                "history.sqlite"
            )
            let databaseBefore = try Data(contentsOf: databaseURL)
            let accessor = try harness.run(
                executable: order.1,
                mode: .access,
                fixture: fixture,
                allowsInteraction: allowsInteraction
            )
            if allowsInteraction {
                XCTAssertEqual(accessor.masterKeyResult, .key)
                XCTAssertEqual(accessor.availability, "ready")
                XCTAssertEqual(accessor.entryCount, 1)
            } else {
                XCTAssertTrue(accessor.keychainWasUnlocked)
                XCTAssertEqual(
                    accessor.masterKeyResult,
                    .accessDenied
                )
                XCTAssertEqual(accessor.availability, "unavailable")
                XCTAssertEqual(accessor.reason, "keyAccessDenied")
                XCTAssertEqual(accessor.entryCount, 0)
                XCTAssertEqual(
                    try Data(contentsOf: databaseURL),
                    databaseBefore
                )
            }
        }
    }

    func testProductionKeychainCrossIdentityChildProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let modeValue = environment[
                KeychainCrossIdentityHarness.childModeEnvironment
            ],
            let mode = KeychainCrossIdentityHarness.Mode(rawValue: modeValue),
            let keychainPath = environment[
                KeychainCrossIdentityHarness.keychainPathEnvironment
            ],
            let keychainPassword = environment[
                KeychainCrossIdentityHarness.keychainPasswordEnvironment
            ],
            let storePath = environment[
                KeychainCrossIdentityHarness.storePathEnvironment
            ],
            let resultPath = environment[
                KeychainCrossIdentityHarness.resultPathEnvironment
            ]
        else {
            throw XCTSkip("Child-only cross-identity probe")
        }

        try CommandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: [
                "unlock-keychain",
                "-p",
                keychainPassword,
                keychainPath,
            ]
        )
        let keyStore = ClipboardHistoryKeychainStore(
            testingKeychainPath: keychainPath,
            allowsInteraction: environment[
                KeychainCrossIdentityHarness.interactionEnvironment
            ] == "1"
        )
        let module = ClipboardHistoryModule(
            testingStoreRoot: URL(fileURLWithPath: storePath),
            keyStore: keyStore
        )
        if mode == .create {
            _ = try await module.capture(
                ClipboardHistoryCaptureRequest(
                    source: ClipboardHistoryCaptureSource(
                        bundleIdentifier: "dev.bybee.AnyDoor.keychain-harness",
                        displayName: "Keychain Harness"
                    ),
                    content: .text("cross-identity encrypted store")
                )
            )
        }
        let status = await module.status()
        let entries: Int
        if status.availability == .ready {
            entries = try await module.page(ClipboardHistoryQuery()).entries.count
            try await module.closeStoreForTesting()
        } else {
            entries = 0
        }
        let result = KeychainCrossIdentityProbeResult(
            masterKeyResult: KeychainCrossIdentityProbeResult.MasterKeyResult(
                keyStore.load()
            ),
            availability: status.availability.harnessValue,
            reason: status.reason?.harnessValue,
            entryCount: entries,
            keychainWasUnlocked: true
        )
        try JSONEncoder().encode(result).write(
            to: URL(fileURLWithPath: resultPath),
            options: .atomic
        )
    }

    func testBitmapAndThumbnailPublishEncryptedBeforeReferenceAndMaterializeInMemory() async throws
    {
        let fixture = try TemporaryStore()
        let module = makeReadyModule(in: fixture)
        let plaintext = Data("private bitmap payload".utf8)

        let outcome = try await module.capture(
            bitmapRequest(plaintext)
        )

        let payloadFiles = try fixture.payloadFiles()
        XCTAssertEqual(payloadFiles.count, 2)
        XCTAssertEqual(try fixture.stagingFiles().count, 0)
        for file in payloadFiles {
            let encrypted = try Data(contentsOf: file)
            XCTAssertNil(encrypted.range(of: plaintext))
            let attributes = try FileManager.default.attributesOfItem(
                atPath: file.path
            )
            let permissions = (attributes[.posixPermissions] as? NSNumber)?
                .intValue
            XCTAssertEqual(permissions.map { $0 & 0o777 }, 0o600)
        }

        let normal = try await module.materialize(
            ClipboardHistoryMaterializationRequest(
                entryID: outcome.entryID,
                purpose: .normalPaste
            )
        )
        let preview = try await module.materialize(
            ClipboardHistoryMaterializationRequest(
                entryID: outcome.entryID,
                purpose: .preview
            )
        )
        XCTAssertNotNil(
            normal.singleDataRepresentation.flatMap {
                CGImageSourceCreateWithData($0 as CFData, nil)
            }
        )
        XCTAssertNotNil(
            preview.singleDataRepresentation.flatMap {
                CGImageSourceCreateWithData($0 as CFData, nil)
            }
        )
    }

    func testPayloadAuthenticationFaultDisablesOnlyThatPayloadAction() async throws {
        let fixture = try TemporaryStore()
        let keyStore = TestMasterKeyStore(
            loadResult: .missing,
            keyToCreate: Data(repeating: 0x62, count: 32)
        )
        let writer = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: keyStore
        )
        let plaintext = Data("authenticated bitmap".utf8)
        let outcome = try await writer.capture(bitmapRequest(plaintext))
        try await writer.closeStoreForTesting()

        let module = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: keyStore,
            faultInjector: ClipboardHistoryFaultInjector(
                points: [.payloadAuthentication]
            )
        )

        do {
            _ = try await module.materialize(
                ClipboardHistoryMaterializationRequest(
                    entryID: outcome.entryID,
                    purpose: .normalPaste
                )
            )
            XCTFail("Expected payload authentication failure")
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryModuleError,
                .payloadAuthenticationFailed(outcome.entryID)
            )
        }

        let page = try await module.page(ClipboardHistoryQuery())
        let status = await module.status()
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(status.availability, .ready)
    }

    func testCorruptBitmapDisablesOnlyThatPayloadAction() async throws {
        let fixture = try TemporaryStore()
        let module = makeReadyModule(in: fixture)
        let plaintext = Data("authenticated bitmap".utf8)
        let outcome = try await module.capture(bitmapRequest(plaintext))
        let bitmap = try XCTUnwrap(
            fixture.payloadFiles().first(where: {
                (try? Data(contentsOf: $0)[9])
                    == ClipboardHistoryPayloadKind.bitmap.rawValue
            })
        )
        var corrupt = try Data(contentsOf: bitmap)
        corrupt[corrupt.index(before: corrupt.endIndex)] ^= 0xFF
        try corrupt.write(to: bitmap)

        do {
            _ = try await module.materialize(
                ClipboardHistoryMaterializationRequest(
                    entryID: outcome.entryID,
                    purpose: .normalPaste
                )
            )
            XCTFail("Expected payload authentication failure")
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryModuleError,
                .payloadAuthenticationFailed(outcome.entryID)
            )
        }

        let preview = try await module.materialize(
            ClipboardHistoryMaterializationRequest(
                entryID: outcome.entryID,
                purpose: .preview
            )
        )
        XCTAssertNotNil(
            preview.singleDataRepresentation.flatMap {
                CGImageSourceCreateWithData($0 as CFData, nil)
            }
        )
        let page = try await module.page(ClipboardHistoryQuery())
        let status = await module.status()
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(status.availability, .ready)
    }

    func testPayloadWriteDurabilityAndPublicationFailuresCommitNothing() async throws {
        for point in [
            ClipboardHistoryFaultPoint.payloadWrite,
            .payloadDurability,
            .payloadPublication,
        ] {
            let fixture = try TemporaryStore()
            let module = makeReadyModule(in: fixture, faults: [point])

            do {
                _ = try await module.capture(
                    bitmapRequest(Data("fault boundary".utf8))
                )
                XCTFail("Expected injected \(point) failure")
            } catch {
                XCTAssertEqual(
                    error as? ClipboardHistoryModuleError,
                    .storageFailure
                )
            }

            let page = try await module.page(ClipboardHistoryQuery())
            XCTAssertEqual(page.entries, [])
            XCTAssertEqual(try fixture.payloadFiles().count, 0)
            XCTAssertEqual(try fixture.stagingFiles().count, 0)
        }
    }

    func testDatabaseFailureLeavesOnlyEncryptedOrphansForReconciliation() async throws {
        let fixture = try TemporaryStore()
        let module = makeReadyModule(in: fixture, faults: [.databaseTransaction])
        let plaintext = Data("transaction orphan plaintext".utf8)

        do {
            _ = try await module.capture(bitmapRequest(plaintext))
            XCTFail("Expected database transaction failure")
        } catch {
            XCTAssertEqual(error as? ClipboardHistoryModuleError, .storageFailure)
        }

        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries, [])
        let orphans = try fixture.payloadFiles()
        XCTAssertEqual(orphans.count, 2)
        for orphan in orphans {
            XCTAssertNil(try Data(contentsOf: orphan).range(of: plaintext))
        }

        let report = try await module.performMaintenance(orphanGracePeriod: 0)
        XCTAssertEqual(report.reclaimedPayloadCount, 2)
        XCTAssertEqual(try fixture.payloadFiles().count, 0)
    }

    func testDeletionCommitsBeforeFailedPhysicalReclamation() async throws {
        let fixture = try TemporaryStore()
        let module = makeReadyModule(in: fixture, faults: [.payloadDeletion])
        let outcome = try await module.capture(
            bitmapRequest(Data("deletion ordering".utf8))
        )

        let deletion = try await module.apply(.delete(outcome.entryID))
        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(deletion, .deleted)
        XCTAssertEqual(page.entries, [])
        XCTAssertEqual(try fixture.payloadFiles().count, 2)

        let reclamation = await module.awaitPendingReclamation()
        XCTAssertEqual(reclamation.attemptedPayloadCount, 2)
        XCTAssertEqual(reclamation.reclaimedPayloadCount, 0)
        XCTAssertEqual(reclamation.failedPayloadCount, 2)
        XCTAssertEqual(try fixture.payloadFiles().count, 2)

        let report = try await module.performMaintenance(orphanGracePeriod: 0)
        XCTAssertEqual(report.reclaimedPayloadCount, 2)
        XCTAssertEqual(try fixture.payloadFiles().count, 0)
    }

    func testOrphanReconciliationFailureIsRetryable() async throws {
        let fixture = try TemporaryStore()
        let keyStore = TestMasterKeyStore(
            loadResult: .missing,
            keyToCreate: Data(repeating: 0x73, count: 32)
        )
        let transactionFailure = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: keyStore,
            faultInjector: ClipboardHistoryFaultInjector(
                points: [.databaseTransaction]
            )
        )
        _ = try? await transactionFailure.capture(
            bitmapRequest(Data("reconcile retry".utf8))
        )
        try await transactionFailure.closeStoreForTesting()
        XCTAssertEqual(try fixture.payloadFiles().count, 2)

        let failedReconciliation = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: keyStore,
            faultInjector: ClipboardHistoryFaultInjector(
                points: [.orphanReconciliation]
            )
        )
        do {
            _ = try await failedReconciliation.performMaintenance(
                orphanGracePeriod: 0
            )
            XCTFail("Expected reconciliation failure")
        } catch {
            XCTAssertEqual(error as? ClipboardHistoryModuleError, .storageFailure)
        }
        XCTAssertEqual(try fixture.payloadFiles().count, 2)
        try await failedReconciliation.closeStoreForTesting()

        let retry = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: keyStore
        )
        let report = try await retry.performMaintenance(orphanGracePeriod: 0)
        XCTAssertEqual(report.reclaimedPayloadCount, 2)
        XCTAssertEqual(try fixture.payloadFiles().count, 0)
    }

    func testMaintenanceCheckpointsEncryptedWALBeforeRecordingSuccess() async throws {
        let fixture = try TemporaryStore()
        let module = makeReadyModule(in: fixture)
        let plaintext = "wal plaintext sentinel"
        _ = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: ClipboardHistoryCaptureSource(
                    bundleIdentifier: "dev.bybee.tests",
                    displayName: "Tests"
                ),
                content: .text(plaintext)
            )
        )
        let walURL = fixture.url.appendingPathComponent("history.sqlite-wal")
        let walBefore = try Data(contentsOf: walURL)
        XCTAssertFalse(walBefore.isEmpty)
        XCTAssertNil(walBefore.range(of: Data(plaintext.utf8)))

        let report = try await module.performMaintenance(orphanGracePeriod: 0)

        let walAfter = try Data(contentsOf: walURL)
        XCTAssertLessThan(walAfter.count, walBefore.count)
        XCTAssertNil(walAfter.range(of: Data(plaintext.utf8)))
        XCTAssertGreaterThan(report.storageBytes, 0)
        let databaseBytes = try Data(
            contentsOf: fixture.url.appendingPathComponent("history.sqlite")
        )
        XCTAssertNil(databaseBytes.range(of: Data(plaintext.utf8)))
    }

    func testConfirmedResetDeletesUnreadableStoreAndOldKeyBeforeRecreating() async throws {
        let fixture = try TemporaryStore()
        let firstKey = Data(repeating: 0x84, count: 32)
        let secondKey = Data(repeating: 0x95, count: 32)
        let keyStore = TestMasterKeyStore(
            loadResult: .missing,
            keysToCreate: [firstKey, secondKey]
        )
        let module = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: keyStore
        )
        _ = try await module.capture(
            bitmapRequest(Data("history to reset".utf8))
        )
        let databaseURL = fixture.url.appendingPathComponent("history.sqlite")
        try await module.reset(confirmation: .confirmed)

        XCTAssertEqual(keyStore.deleteCallCount, 1)
        XCTAssertEqual(keyStore.createCallCount, 2)
        XCTAssertEqual(try fixture.payloadFiles().count, 0)
        let page = try await module.page(ClipboardHistoryQuery())
        let status = await module.status()
        XCTAssertEqual(page.entries, [])
        XCTAssertEqual(status.availability, .ready)

        try await module.closeStoreForTesting()
        let oldDatabaseKey =
            ClipboardHistoryKeyDerivation
            .deriveV1(from: firstKey).databaseKey
        XCTAssertThrowsError(
            try ClipboardHistoryModule(
                testingDatabaseURL: databaseURL,
                databaseKey: oldDatabaseKey
            )
        )
        let newDatabaseKey =
            ClipboardHistoryKeyDerivation
            .deriveV1(from: secondKey).databaseKey
        _ = try ClipboardHistoryModule(
            testingDatabaseURL: databaseURL,
            databaseKey: newDatabaseKey
        )
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

private final class TemporaryStore {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-ClipboardHistoryModuleTests-\(UUID().uuidString)"
            )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func payloadFiles() throws -> [URL] {
        try files(in: url.appendingPathComponent("payloads"))
            .filter { $0.pathExtension == "payload" }
    }

    func stagingFiles() throws -> [URL] {
        try files(in: url.appendingPathComponent("staging"))
            .filter { $0.pathExtension == "staging" }
    }

    private func files(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
    }
}

private final class TemporaryFileReferences {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnyDoor-FileReferences-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func create(name: String, contents: String) throws -> URL {
        let file = url.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        return file
    }
}

private final class TestPasteboardDataProvider: NSObject,
    NSPasteboardItemDataProvider
{
    enum Action {
        case provide(String)
        case replaceGeneration(provided: String, replacement: String)
    }

    nonisolated(unsafe) private(set) var callCount = 0
    private let action: Action

    init(action: Action) {
        self.action = action
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard let pasteboard else { return }
        callCount += 1
        switch action {
        case .provide(let value):
            item.setString(value, forType: type)
        case .replaceGeneration(let provided, let replacement):
            pasteboard.clearContents()
            pasteboard.setString(replacement, forType: .string)
            item.setString(provided, forType: type)
        }
    }
}

private struct KeychainCrossIdentityProbeResult: Codable, Equatable {
    enum MasterKeyResult: String, Codable {
        case key
        case missing
        case locked
        case interactionRequired
        case accessDenied
        case failure

        init(_ result: ClipboardHistoryMasterKeyResult) {
            switch result {
            case .key:
                self = .key
            case .missing:
                self = .missing
            case .locked:
                self = .locked
            case .interactionRequired:
                self = .interactionRequired
            case .accessDenied:
                self = .accessDenied
            case .failure:
                self = .failure
            }
        }
    }

    let masterKeyResult: MasterKeyResult
    let availability: String
    let reason: String?
    let entryCount: Int
    let keychainWasUnlocked: Bool
}

private final class TemporaryCrossIdentityFixture {
    let root: URL
    let storeRoot: URL
    let keychainURL: URL
    let keychainPassword = "AnyDoor-ClipboardHistory-Test-Keychain"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AnyDoor-KeychainCrossIdentity-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        storeRoot = root.appendingPathComponent("ClipboardHistory")
        keychainURL = root.appendingPathComponent("integration.keychain-db")
        try CommandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: [
                "create-keychain",
                "-p",
                keychainPassword,
                keychainURL.path,
            ]
        )
        try CommandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: [
                "set-keychain-settings",
                "-lut",
                "21600",
                keychainURL.path,
            ]
        )
    }

    deinit {
        _ = try? CommandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["delete-keychain", keychainURL.path]
        )
        try? FileManager.default.removeItem(at: root)
    }
}

private final class KeychainCrossIdentityHarness {
    enum Mode: String {
        case create
        case access
    }

    static let childModeEnvironment =
        "ANYDOOR_KEYCHAIN_CROSS_IDENTITY_CHILD_MODE"
    static let keychainPathEnvironment =
        "ANYDOOR_KEYCHAIN_CROSS_IDENTITY_KEYCHAIN_PATH"
    static let keychainPasswordEnvironment =
        "ANYDOOR_KEYCHAIN_CROSS_IDENTITY_KEYCHAIN_PASSWORD"
    static let storePathEnvironment =
        "ANYDOOR_KEYCHAIN_CROSS_IDENTITY_STORE_PATH"
    static let resultPathEnvironment =
        "ANYDOOR_KEYCHAIN_CROSS_IDENTITY_RESULT_PATH"
    static let interactionEnvironment =
        "ANYDOOR_KEYCHAIN_CROSS_IDENTITY_ALLOW_INTERACTION"

    let developmentExecutable: URL
    let installedExecutable: URL
    let developmentDesignatedRequirement: String
    let installedDesignatedRequirement: String

    private let root: URL
    private let testBundle: URL

    init(testBundle: URL, xctestExecutable: URL) throws {
        self.testBundle = testBundle
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AnyDoor-XCTestIdentities-\(UUID().uuidString)"
        )
        let sourceLibraryRoot =
            xctestExecutable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceDeveloperRoot = sourceLibraryRoot.deletingLastPathComponent()
        let identityDirectory = root.appendingPathComponent(
            "Developer/Library/Xcode/Agents"
        )
        try FileManager.default.createDirectory(
            at: identityDirectory,
            withIntermediateDirectories: true
        )
        let libraryRoot = root.appendingPathComponent("Developer/Library")
        for directory in ["Frameworks", "PrivateFrameworks"] {
            let source = sourceLibraryRoot.appendingPathComponent(directory)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.createSymbolicLink(
                    at: libraryRoot.appendingPathComponent(directory),
                    withDestinationURL: source
                )
            }
        }
        let developerUSR = root.appendingPathComponent("Developer/usr")
        try FileManager.default.createDirectory(
            at: developerUSR,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: developerUSR.appendingPathComponent("lib"),
            withDestinationURL: sourceDeveloperRoot.appendingPathComponent(
                "usr/lib"
            )
        )

        developmentExecutable = identityDirectory.appendingPathComponent(
            "clipboard-keychain-development"
        )
        installedExecutable = identityDirectory.appendingPathComponent(
            "clipboard-keychain-installed"
        )
        try FileManager.default.copyItem(
            at: xctestExecutable,
            to: developmentExecutable
        )
        try FileManager.default.copyItem(
            at: xctestExecutable,
            to: installedExecutable
        )
        try Self.sign(
            developmentExecutable,
            identifier:
                "dev.bybee.AnyDoor.KeychainHarness.Development"
        )
        try Self.sign(
            installedExecutable,
            identifier: "dev.bybee.AnyDoor.KeychainHarness.Installed"
        )
        developmentDesignatedRequirement = try Self.designatedRequirement(
            developmentExecutable
        )
        installedDesignatedRequirement = try Self.designatedRequirement(
            installedExecutable
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func run(
        executable: URL,
        mode: Mode,
        fixture: TemporaryCrossIdentityFixture,
        allowsInteraction: Bool
    ) throws -> KeychainCrossIdentityProbeResult {
        let resultURL = fixture.root.appendingPathComponent(
            "\(UUID().uuidString).json"
        )
        var environment = ProcessInfo.processInfo.environment
        environment[Self.childModeEnvironment] = mode.rawValue
        environment[Self.keychainPathEnvironment] = fixture.keychainURL.path
        environment[Self.keychainPasswordEnvironment] =
            fixture.keychainPassword
        environment[Self.storePathEnvironment] = fixture.storeRoot.path
        environment[Self.resultPathEnvironment] = resultURL.path
        environment[Self.interactionEnvironment] =
            allowsInteraction ? "1" : "0"
        try CommandRunner.run(
            executable: executable,
            arguments: [
                "-XCTest",
                "ClipboardHistoryModuleTests/"
                    + "testProductionKeychainCrossIdentityChildProbe",
                testBundle.path,
            ],
            environment: environment
        )
        return try JSONDecoder().decode(
            KeychainCrossIdentityProbeResult.self,
            from: Data(contentsOf: resultURL)
        )
    }

    private static func sign(_ executable: URL, identifier: String) throws {
        try CommandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: [
                "--force",
                "--sign",
                "-",
                "--identifier",
                identifier,
                executable.path,
            ]
        )
    }

    private static func designatedRequirement(
        _ executable: URL
    ) throws -> String {
        try CommandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--display", "--requirements", "-", executable.path]
        )
    }
}

private enum CommandRunner {
    struct Failure: Error, CustomStringConvertible {
        let command: String
        let status: Int32
        let output: String

        var description: String {
            "\(command) exited \(status): \(output)"
        }
    }

    @discardableResult
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Failure(
                command: ([executable.path] + arguments)
                    .joined(separator: " "),
                status: process.terminationStatus,
                output: text
            )
        }
        return text
    }
}

extension ClipboardHistoryStatus.Availability {
    fileprivate var harnessValue: String {
        switch self {
        case .ready:
            "ready"
        case .paused:
            "paused"
        case .unavailable:
            "unavailable"
        }
    }
}

extension ClipboardHistoryStatus.AvailabilityReason {
    fileprivate var harnessValue: String {
        switch self {
        case .keychainLocked:
            "keychainLocked"
        case .missingKey:
            "missingKey"
        case .keyAccessDenied:
            "keyAccessDenied"
        case .keychainFailure:
            "keychainFailure"
        case .databaseAuthenticationFailed:
            "databaseAuthenticationFailed"
        case .databaseCorrupt:
            "databaseCorrupt"
        case .databaseIntegrityFailed:
            "databaseIntegrityFailed"
        case .searchIndexUnavailable:
            "searchIndexUnavailable"
        case .storeIOFailure:
            "storeIOFailure"
        }
    }
}

private final class TestMasterKeyStore: ClipboardHistoryMasterKeyStoring, Sendable {
    private struct State: Sendable {
        var loadResult: ClipboardHistoryMasterKeyResult
        var keysToCreate: [Data]
        var createCallCount = 0
        var deleteCallCount = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    var loadResult: ClipboardHistoryMasterKeyResult {
        get { state.withLock { $0.loadResult } }
        set { state.withLock { $0.loadResult = newValue } }
    }

    var createCallCount: Int {
        state.withLock { $0.createCallCount }
    }

    var deleteCallCount: Int {
        state.withLock { $0.deleteCallCount }
    }

    init(
        loadResult: ClipboardHistoryMasterKeyResult,
        keyToCreate: Data? = nil
    ) {
        state = OSAllocatedUnfairLock(
            initialState: State(
                loadResult: loadResult,
                keysToCreate: keyToCreate.map { [$0] } ?? []
            )
        )
    }

    init(
        loadResult: ClipboardHistoryMasterKeyResult,
        keysToCreate: [Data]
    ) {
        state = OSAllocatedUnfairLock(
            initialState: State(
                loadResult: loadResult,
                keysToCreate: keysToCreate
            )
        )
    }

    func load() -> ClipboardHistoryMasterKeyResult {
        state.withLock { $0.loadResult }
    }

    func create() -> ClipboardHistoryMasterKeyResult {
        state.withLock {
            $0.createCallCount += 1
            guard !$0.keysToCreate.isEmpty else {
                return .failure(errSecAllocate)
            }
            let key = $0.keysToCreate.removeFirst()
            $0.loadResult = .key(key)
            return .key(key)
        }
    }

    func delete() -> ClipboardHistoryMasterKeyResult {
        state.withLock {
            $0.deleteCallCount += 1
            $0.loadResult = .missing
            return .missing
        }
    }
}

private actor MigrationVisionRecognizer:
    ClipboardHistoryVisionRecognizing
{
    private var kinds: [ClipboardHistoryDerivedJobKind] = []

    func recognize(
        _ kind: ClipboardHistoryDerivedJobKind,
        in bitmaps: [Data]
    ) async throws -> [String] {
        XCTAssertFalse(bitmaps.isEmpty)
        kinds.append(kind)
        return []
    }

    func recognizedKinds() -> [ClipboardHistoryDerivedJobKind] {
        kinds
    }
}

extension Data {
    fileprivate var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

extension ClipboardHistoryModuleTests {
    fileprivate func makeOversizedPixelPNG() throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 8_001,
                height: 8_000,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        )
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @MainActor
    fileprivate func makeFilePasteboard(_ urls: [URL]) -> NSPasteboard {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("dev.bybee.AnyDoor.tests.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        let items = urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        XCTAssertTrue(pasteboard.writeObjects(items))
        return pasteboard
    }

    fileprivate func makeOrientedWideGamutPNG() throws -> Data {
        let colorSpace = try XCTUnwrap(
            CGColorSpace(name: CGColorSpace.displayP3)
        )
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 2,
                height: 3,
                bitsPerComponent: 16,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder16Little.rawValue
            )
        )
        context.setFillColor(
            CGColor(
                colorSpace: colorSpace,
                components: [1, 0.25, 0.5, 0.5]
            )!
        )
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImagePropertyOrientation: 6] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    fileprivate func makeReadyModule(
        in fixture: TemporaryStore,
        faults: Set<ClipboardHistoryFaultPoint> = []
    ) -> ClipboardHistoryModule {
        ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: TestMasterKeyStore(
                loadResult: .missing,
                keyToCreate: Data(repeating: 0x62, count: 32)
            ),
            faultInjector: ClipboardHistoryFaultInjector(points: faults)
        )
    }

    fileprivate func bitmapRequest(_ data: Data) -> ClipboardHistoryCaptureRequest {
        let bitmapData: Data
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0
        {
            bitmapData = data
        } else {
            bitmapData = Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )!
        }
        return ClipboardHistoryCaptureRequest(
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: "dev.bybee.tests",
                displayName: "Tests"
            ),
            content: .bitmap(bitmapData, provenance: .image)
        )
    }
}

extension ClipboardHistoryMaterialization {
    fileprivate var singleDataRepresentation: Data? {
        guard items.count == 1,
            items[0].representations.count == 1,
            case .data(_, let data) = items[0].representations[0]
        else {
            return nil
        }
        return data
    }
}
