import ClipboardHistory
import Foundation
import SwiftData
import XCTest

@testable import AnyDoor

/// The reader hand-writes SQL against Core Data's private table layout, which
/// no compiler checks. These tests build the input with real SwiftData, so a
/// toolchain that changed a column name or an encoding fails here instead of
/// silently dropping the user's history on their first v2 launch.
@MainActor
final class ClipboardHistoryLegacyStoreReaderTests: XCTestCase {
    func testEveryLegacyKindSurvivesTheRawRead() throws {
        let manifest = try JSONEncoder().encode([
            ClipboardFileEntry(
                storedName: "stored",
                originalName: "Document.txt",
                originalPath: "/Users/example/Document.txt"
            )
        ])
        var expected: [UUID: ClipboardHistoryLegacyKind] = [:]
        let storeURL = try makeStore { context in
            // CaseIterable keeps this exhaustive: a new v1 kind cannot be
            // added without deciding how the reader maps it.
            for (index, kind) in ClipboardHistoryKind.allCases.enumerated() {
                let id = UUID()
                expected[id] = Self.expectedLegacyKind(for: kind)
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

        XCTAssertEqual(entries.count, ClipboardHistoryKind.allCases.count)
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

    func testAStoreWithoutTheLegacyEntityReadsAsEmpty() throws {
        // An install that predates clipboard history entirely: the file is a
        // valid store, it just has no such table. That is nothing to migrate,
        // not a failure that would block every launch.
        let directory = try makeDirectory()
        let storeURL = directory.appendingPathComponent("AnyDoor.store")
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

        XCTAssertEqual(
            try ClipboardHistoryLegacyStoreReader.readEntries(at: storeURL)
                .count,
            0
        )
    }

    private static func expectedLegacyKind(
        for kind: ClipboardHistoryKind
    ) -> ClipboardHistoryLegacyKind {
        switch kind {
        case .text: .text
        case .color: .color
        case .qrcode: .qrCode
        case .ocr: .ocr
        case .image: .image
        case .screenshot: .screenshot
        case .file: .file
        }
    }

    private func makeStore(
        _ populate: (ModelContext) throws -> Void
    ) throws -> URL {
        let storeURL = try makeDirectory()
            .appendingPathComponent("AnyDoor.store")
        let container = try ModelContainer(
            for: ClipboardHistoryItem.self,
            configurations: ModelConfiguration(url: storeURL)
        )
        try populate(container.mainContext)
        try container.mainContext.save()
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
